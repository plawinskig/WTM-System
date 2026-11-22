# EXPLAIN, indeksy i weryfikacja zapytań – zajęcia 6

Plany wykonania zapytań z zajęć 5 (`sql/03_reports copy.sql`) w PostgreSQL 17, wybór indeksów i porównanie planów przed dodaniem indeksów i po nim.

| Plik | Zawartość |
|---|---|
| `sql/04_indexes.sql` | 9 indeksów wydajnościowych, uzasadnienie w komentarzach |
| `sql/05_explain.sql` | `EXPLAIN (ANALYZE, BUFFERS)` zapytań 7, 8, 9, 10, 14, 15 i 16, warianty A i B (inne sformułowanie zapytań), statystyki użycia indeksów |
| `sql/explain/before.txt`, `sql/explain/after.txt` | pełny wynik `05_explain.sql` bez nowych indeksów i z nimi |

## Uruchomienie

Baza musi być wypełniona generatorem ([README.md](../README.md), [generator/README.md](../generator/README.md)). Z katalogu głównego repozytorium:

```bash
DC="docker compose exec -T postgres psql -X -U projektowaniebazdanych -d ewidencja_czasu_pracy"
echo 'ANALYZE;' | $DC                                  # 1. świeże statystyki, tylko raz
$DC < sql/05_explain.sql > sql/explain/before.txt      # 2. plany bez indeksów
$DC -v ON_ERROR_STOP=1 < sql/04_indexes.sql            # 3. indeksy
$DC < sql/05_explain.sql > sql/explain/after.txt       # 4. plany z indeksami
```

`ANALYZE` uruchamia się raz, przed pierwszym pomiarem, a nie przed każdym. Bierze losową próbkę wierszy, więc samo ponowne uruchomienie może zmienić plan. Tak było w pierwszej próbie pomiaru, w której skrypt robił `ANALYZE` przy każdym uruchomieniu. Zapytanie o pary współpracowników zwolniło wtedy z 733 do 1108 ms (`\timing`), choć nie używa żadnego nowego indeksu: `EXPLAIN ANALYZE` z indeksami i bez nich dawał ten sam plan i ok. 1,3 s. Po nowej próbce statystyk planer wybrał Memoize z Nested Loop zamiast Parallel Hash Join; z `SET enable_memoize = off` zapytanie trwało 807 ms.

Powrót do stanu „przed”:

```sql
DROP INDEX IF EXISTS work_time.ix_assignment_employee, work_time.ix_registration_employee,
    work_time.ix_absence_employee, work_time.ix_availability_employee, work_time.ix_employee_team,
    work_time.ix_shift_schedule, work_time.ix_contract_employee_start, work_time.ix_shift_start_time,
    work_time.ix_registration_pending;
```

Czasy wszystkich 23 zapytań (sekcja 3.1) zmierzono przez `\timing` w psql, w 3 przebiegach; podano minimum:

```bash
(echo 'SET search_path TO work_time, public;'; echo '\timing on'; echo '\o /dev/null'; cat "sql/03_reports copy.sql") | $DC -q | grep 'Time:'
```

Środowisko: 2026-11-22, PostgreSQL 17.11 w Dockerze z `compose.yaml`, ustawienia domyślne (`work_mem` 4 MB, `shared_buffers` 128 MB, JIT włączony). Dane z generatora z 2026-11-08: Registration 629 202 wiersze, Assignment 374 247, Shift 71 159, Contract 16 125, Employee 6 200. Wszystkie strony były w pamięci podręcznej (w planach jest tylko `shared hit`, bez `read`), więc czasy pokazują pracę procesora, a nie dysku.

## 1. EXPLAIN w PostgreSQL

### 1.1. Co pokazuje

`EXPLAIN zapytanie` pokazuje plan wybrany przez planer, bez wykonania zapytania. `EXPLAIN (ANALYZE)` wykonuje zapytanie i dopisuje wartości rzeczywiste, a `BUFFERS` dodaje liczbę stron (po 8 kB), które zapytanie odczytało. Plan to drzewo węzłów: każdy węzeł pobiera wiersze od węzłów wciętych głębiej i przekazuje wynik wyżej.

| Element | Znaczenie |
|---|---|
| nazwa węzła | dostęp do tabeli (`Seq Scan`, `Index Scan`, `Index Only Scan`, `Bitmap Index Scan` + `Bitmap Heap Scan`), złączenie (`Nested Loop`, `Hash Join`, `Merge Join`), agregacja (`HashAggregate`, `GroupAggregate`), sortowanie (`Sort`, `Incremental Sort`), `SubPlan` (podzapytanie skorelowane), `InitPlan` (podzapytanie liczone raz), `CTE Scan`, `Gather` (praca równoległa), `Memoize` (pamięć podręczna wyników) |
| `cost=0.00..247.16` | szacowany koszt w umownych jednostkach: do zwrócenia pierwszego wiersza i do zwrócenia wszystkich. Jednostki wynikają z parametrów (`seq_page_cost` = 1, `random_page_cost` = 4, `cpu_tuple_cost` = 0,01…). Koszt węzła zawiera koszt jego dzieci |
| `rows`, `width` | szacowana liczba wierszy i średni rozmiar wiersza w bajtach |
| `actual time=0.396..0.396` | rzeczywisty czas w ms do pierwszego i do ostatniego wiersza, **średnio na jedno wykonanie węzła** |
| `rows=0 loops=37` | rzeczywista liczba wierszy (średnio na wykonanie) i liczba wykonań. Łączny czas węzła to czas × loops |
| `Filter`, `Rows Removed by Filter` | warunek sprawdzany po odczytaniu wiersza i liczba odrzuconych wierszy. Duża liczba przy dużej tabeli oznacza zwykle brak indeksu |
| `Index Cond`, `Recheck Cond` | warunek obsłużony przez indeks; przy skanie bitmapowym warunek sprawdzany ponownie na stronie tabeli |
| `Buffers: shared hit=2701 read=…` | strony z pamięci podręcznej PostgreSQL (`hit`) i spoza niej (`read`). `temp read/written` to pliki tymczasowe: sortowanie albo tablica haszująca nie zmieściły się w `work_mem` |
| `Sort Method: external merge Disk: 10208kB` | sortowanie na dysku zamiast `quicksort` w pamięci |
| `Heap Fetches` | przy `Index Only Scan`: ile razy trzeba było zajrzeć do tabeli, bo strona nie była oznaczona jako widoczna dla wszystkich (mapa widoczności, `VACUUM`) |
| `Planning Time`, `Execution Time` | czas planowania i wykonania |
| `JIT:` | kompilacja wyrażeń do kodu maszynowego (LLVM): liczba funkcji i czas kompilacji |

`EXPLAIN ANALYZE` mierzy czas każdego węzła, co samo spowalnia wykonanie. Dlatego czasy w sekcji 3.2 są wyższe niż w 3.1.

### 1.2. Jak czytać – przykład z zapytania 8

Zapytanie 8 sprawdza, kogo z działu można przydzielić do zmiany w danym dniu. Fragment planu bez indeksów, podzapytanie o deklarację niedostępności:

```
SubPlan 7
  ->  Seq Scan on "Availability" av  (cost=0.00..247.16 rows=1 width=0) (actual time=0.396..0.396 rows=0 loops=37)
        Filter: ((NOT available) AND (available_to > params_1.check_date) AND (employee_id = employee_1.employee_id) AND (available_from < (params_1.check_date + 1)))
        Rows Removed by Filter: 8708
        Buffers: shared hit=2701
```

- `SubPlan` to podzapytanie skorelowane, wykonywane osobno dla każdego wiersza zapytania zewnętrznego. `loops=37` oznacza 37 wykonań.
- Każde wykonanie czyta całą tabelę Availability (`Rows Removed by Filter: 8708`), żeby znaleźć najwyżej jeden wiersz jednego pracownika. Łącznie to 37 × 8708 ≈ 322 tys. odrzuconych wierszy i 2701 stron.
- Warunek `employee_id = …` jest w `Filter`, a nie w `Index Cond`, bo kolumna `Availability.employee_id` nie ma indeksu.

Ten sam fragment po dodaniu `ix_availability_employee`:

```
SubPlan 7
  ->  Bitmap Heap Scan on "Availability" av  (cost=4.30..11.35 rows=1 width=0) (actual time=0.003..0.003 rows=0 loops=37)
        Recheck Cond: (employee_id = employee_1.employee_id)
        Filter: ((NOT available) AND (available_to > params_1.check_date) AND (available_from < (params_1.check_date + 1)))
        Rows Removed by Filter: 1
        Buffers: shared hit=101
        ->  Bitmap Index Scan on ix_availability_employee  (cost=0.00..4.30 rows=2 width=0) (actual time=0.002..0.002 rows=1 loops=37)
              Index Cond: (employee_id = employee_1.employee_id)
```

Indeks znajduje wiersze pracownika (`Index Cond`), a filtr sprawdza już tylko daty. Koszt jednego wykonania spadł z 247 do 11 jednostek, czas z 0,396 do 0,003 ms, odczyty z 2701 do 101 stron. Podobnie zmieniły się pozostałe podzapytania i całe zapytanie 8 przyspieszyło z 211 do 14 ms (sekcja 3.2).

Zasady czytania planu:
1. Czytaj od węzłów najbardziej wciętych w stronę korzenia. Czas węzła zawiera czas dzieci, więc najdroższy jest węzeł, którego czas najbardziej przewyższa sumę czasów dzieci.
2. Mnóż `actual time` przez `loops`. Mały czas wykonany tysiące razy daje duży koszt.
3. Porównuj szacowane `rows` z rzeczywistymi. Rozbieżność o rząd wielkości oznacza, że planer decydował na podstawie złych danych (zapytanie 9, sekcja 3.2).
4. Szukaj `Seq Scan` z dużym `Rows Removed by Filter` na dużej tabeli, sortowania na dysku i długiej kompilacji JIT.

### 1.3. Specyfika PostgreSQL

- **Planer kosztowy bez podpowiedzi.** PostgreSQL wybiera plan o najniższym szacowanym koszcie i nie ma wskazówek dla planera (hints), jakie są w Oracle albo w MySQL (`FORCE INDEX`). Na plan wpływają indeksy, statystyki, treść zapytania i parametry (`work_mem`, `random_page_cost`, `enable_seqscan`…).
- **Statystyki** (`pg_stats`) zbiera `ANALYZE`, ręcznie albo automatycznie (autovacuum), z próbki 30 000 wierszy: najczęstsze wartości, histogram, liczba różnych wartości, korelacja z fizyczną kolejnością wierszy. Na tej podstawie planer liczy `rows`.
- **`EXPLAIN ANALYZE` naprawdę wykonuje zapytanie.** `INSERT`, `UPDATE` i `DELETE` trzeba w tym celu zamknąć w `BEGIN … ROLLBACK`.
- **Praca równoległa:** węzły `Gather` i `Gather Merge` oraz `Workers Launched` pokazują, że część planu wykonują procesy pomocnicze (domyślnie do 2).
- **JIT** (od PG 11, domyślnie włączony od PG 12) kompiluje wyrażenia, gdy szacowany koszt przekracza `jit_above_cost` (100 000). Powyżej 500 000 dodatkowo optymalizuje kod i wstawia funkcje inline. Czas kompilacji wlicza się do pierwszego węzła, który użył skompilowanego kodu. W zapytaniu 9 jest to `Seq Scan on "Branch"`: 124 wiersze w 336 ms.
- **CTE wstawiane inline** (od PG 12): CTE bez słowa `MATERIALIZED`, użyte raz, staje się częścią zapytania. Użyte kilka razy jest liczone raz i czytane węzłem `CTE Scan` (zapytanie 14).
- **Memoize** (od PG 14) zapamiętuje wyniki wewnętrznej strony `Nested Loop` dla powtarzających się kluczy. `Hits` i `Misses` pokazują, czy to się opłaciło.
- **Incremental Sort** (od PG 13) dosortowuje dane już częściowo posortowane, np. odczytane w kolejności indeksu (zapytanie 15, sekcja 3.3).

### 1.4. Na czym polega optymalizacja zapytań

Optymalizator przekształca zapytanie (wstawia CTE i podzapytania, przenosi warunki bliżej tabel), dla każdej tabeli rozważa sposób dostępu (skan sekwencyjny, indeksowy, bitmapowy), kolejność i metodę złączeń oraz sposób agregacji. Koszt każdego wariantu szacuje ze statystyk i wybiera najtańszy. Przy więcej niż 12 tabelach (`geqo_threshold`) zamiast przeszukiwać wszystkie kolejności złączeń używa algorytmu genetycznego.

Po stronie projektanta bazy optymalizacja to:
- **indeksy** na kolumnach, przez które zapytania wybierają albo łączą małą część dużej tabeli (sekcja 2),
- **aktualne statystyki**, bo zły szacunek daje zły plan (zapytanie 9),
- **treść zapytania**, którą planer może dobrze wykorzystać: warunek na samej kolumnie, a nie na funkcji od niej (wariant A), bez wielokrotnego czytania tych samych danych (wariant B),
- **parametry serwera**, np. `work_mem`: zapytanie 11 sortuje 10 MB na dysku, a z `SET work_mem = '64MB'` używa `HashAggregate` w pamięci i trwa 299 ms zamiast 376 ms,
- **sprawdzenie** każdej zmiany przez `EXPLAIN ANALYZE`, bo szacowany koszt to nie czas (sekcja 3.3).

## 2. Indeksy

### 2.1. Typy indeksów w PostgreSQL

| Typ | Zalety | Wady | Kiedy używać | W projekcie |
|---|---|---|---|---|
| B-tree (domyślny) | `=`, `<`, `>`, `BETWEEN`, `IN`, `IS NULL`, `ORDER BY`, prefiks `LIKE 'abc%'` (z `text_pattern_ops`); unikalność; wiele kolumn; Index Only Scan; deduplikacja powtarzających się wartości (od PG 13) | warunek musi dotyczyć pierwszej kolumny indeksu; nie obsługuje zawierania ani podobieństwa | klucze główne i obce, daty, sortowanie – większość przypadków | wszystkie 9 nowych indeksów oraz PK i UNIQUE |
| Hash | tylko `=`; rozmiar niezależny od długości wartości (przechowuje 4-bajtowy skrót) | brak zakresów, sortowania, unikalności, wielu kolumn i Index Only Scan | równość na długich wartościach (adresy URL, tokeny) | nie: wyszukiwanie po loginie obsługuje unikalny B-tree ze schematu |
| GiST | szkielet dla danych wielowymiarowych: geometria, przedziały (`tsrange`), wyszukiwanie pełnotekstowe, najbliżsi sąsiedzi (`ORDER BY <->`), ograniczenia `EXCLUDE` | stratny (wymaga ponownego sprawdzenia), dla zwykłych wartości wolniejszy niż B-tree | nakładające się przedziały, dane przestrzenne | możliwy: `EXCLUDE USING gist` (z rozszerzeniem `btree_gist`) zablokowałby nakładające się deklaracje dostępności jednej osoby (F24), czego nie potrafi `CHECK` |
| SP-GiST | drzewa niezrównoważone: drzewo czwórkowe, k-d, trie | wąski zestaw operatorów | adresy IP (`inet`), punkty, prefiksy tekstu | nie |
| GIN | indeks odwrócony, wiele kluczy na wiersz: tablice, `jsonb`, `tsvector`, `pg_trgm` (`LIKE '%abc%'`, `ILIKE`) | wolny zapis, duży rozmiar, brak sortowania | zawieranie (`@>`), wyszukiwanie pełnotekstowe i rozmyte | możliwy dla `ILIKE` po nazwisku (zapytanie 2), ale przy 6 200 pracownikach Seq Scan trwa ułamek milisekundy |
| BRIN | bardzo mały (min/max dla zakresu stron), tani w utrzymaniu | działa tylko, gdy wartości rosną razem z fizyczną kolejnością wierszy; stratny | ogromne tabele dopisywane w kolejności czasu (logi, pomiary) | nie: korelacja z kolejnością fizyczną (`pg_stats.correlation`) wynosi dla `Shift.start_time` −0,001, `Registration.event_time` 0,010, `Audit.operation_time` 0,237, bo generator nie wstawia wierszy chronologicznie. W produkcyjnej tabeli `Audit`, dopisywanej na bieżąco, BRIN na `operation_time` miałby sens |

Warianty niezależne od typu:

| Wariant | Opis | W projekcie |
|---|---|---|
| wielokolumnowy | kolejność kolumn ma znaczenie: indeks (a, b) obsłuży warunek na a albo na a i b, ale nie na samym b | `ix_contract_employee_start`. Istniejący `uq_assignment_shift_employee` (shift_id, employee_id) **nie** pomaga w szukaniu po samym `employee_id`, dlatego powstał `ix_assignment_employee` |
| unikalny | wymusza unikalność wartości | PK i UNIQUE ze schematu |
| częściowy (`WHERE`) | obejmuje tylko wiersze spełniające warunek, więc jest mniejszy. Planer użyje go tylko wtedy, gdy z warunku zapytania wynika warunek indeksu | `ix_registration_pending`; w schemacie `uq_schedule_one_published_version` |
| wyrażeniowy | indeks na wyrażeniu, np. `lower(last_name)` albo `CAST(start_time AS DATE)` | nie: zapytania mają warunki na samej kolumnie (wariant A) |
| pokrywający (`INCLUDE`) | dodatkowe kolumny w liściach, więc zapytanie może się obejść bez czytania tabeli (Index Only Scan) | `ix_registration_pending` |

### 2.2. Koszty indeksów

- **Miejsce.** 9 nowych indeksów zajmuje 11 MB, przy 77 MB danych wszystkich tabel. Wszystkie indeksy Registration (21 MB) to 41% rozmiaru tej tabeli (51 MB), a indeksy Assignment (19 MB) są większe niż sama tabela (16 MB).
- **Zapis.** Każdy `INSERT` i `DELETE` aktualizuje wszystkie indeksy tabeli, a `UPDATE` kolumny objętej indeksem wyklucza aktualizację HOT. Dlatego indeksy zakłada się po załadowaniu danych: generator ładuje dane bez nich, a zbudowanie wszystkich 9 trwało 0,5 s.
- **Planowanie.** Każdy indeks to dodatkowy wariant do rozważenia: czas planowania zapytania 8 wzrósł z 1,5 do 2,9 ms.
- **Ryzyko gorszego planu.** Planer może wybrać indeks tam, gdzie skan sekwencyjny jest szybszy (zapytanie 15, sekcja 3.3).
- **Utrzymanie.** Indeks puchnie po wielu aktualizacjach (`REINDEX`), a Index Only Scan wymaga aktualnej mapy widoczności (`VACUUM`).

### 2.3. Wybrane indeksy

PostgreSQL, w odróżnieniu od MySQL z InnoDB, nie tworzy indeksów na kluczach obcych automatycznie. Indeks dostała kolumna, przez którą zapytanie wybiera **małą część** dużej tabeli. Kolumna „Zapytania” podaje, w których z 23 zapytań planer go użył.

| Indeks | Kolumny | Rozmiar | Zapytania | Co zmienia w planie |
|---|---|---|---|---|
| `ix_assignment_employee` | Assignment (employee_id) | 2,6 MB | 8, 9, 10 | przydziały jednego pracownika przez Index Scan, zamiast przeglądania całego `uq_assignment_shift_employee`, w którym employee_id jest drugą kolumną |
| `ix_registration_employee` | Registration (employee_id) | 4,3 MB | 10 (i 15, ze szkodą) | 170 rejestracji pracownika zamiast skanu 629 202 wierszy |
| `ix_absence_employee` | Absence (employee_id) | 160 kB | 8 | nieobecności pracownika w podzapytaniu skorelowanym |
| `ix_availability_employee` | Availability (employee_id) | 176 kB | 8 | deklaracje pracownika w podzapytaniu skorelowanym |
| `ix_employee_team` | Employee (team_id) | 72 kB | 3, 8, 9 | pracownicy zespołu i działu |
| `ix_shift_schedule` | Shift (schedule_id) | 504 kB | 8, 9 | zmiany jednego grafiku |
| `ix_contract_employee_start` | Contract (employee_id, start_date), wielokolumnowy | 376 kB | 3, 8 | umowa obowiązująca w dniu: oba warunki w `Index Cond` |
| `ix_shift_start_time` | Shift (start_time) | 520 kB | 7, 8, 11, 18 | zmiany z dnia lub miesiąca przez Bitmap Index Scan |
| `ix_registration_pending` | Registration (employee_id) INCLUDE (verification_status, event_time) WHERE verification_status IN ('unverified', 'needs_explanation'), częściowy i pokrywający | 3,0 MB | 16 | Index Only Scan po 71 633 wierszach (11% tabeli) |

Wszystkie są typu B-tree i wszystkie zostały użyte (`idx_scan > 0` w `pg_stat_user_indexes` na końcu `after.txt`).

### 2.4. Czego nie indeksujemy

- **Słowniki i małe tabele** (Role, Permission, ContractType, Position, Branch, Department, Team, Zone; do 555 wierszy, 1–5 stron): skan sekwencyjny kosztuje mniej niż wejście w indeks.
- **Kolumny o niskiej selektywności:** `Registration.event_type` (4 wartości, każda w 17–33% wierszy), `Schedule.status` (3 wartości), `Employee.archived` (95% to `false`). Warunek, który zwraca dużą część tabeli, i tak kończy się Seq Scanem.
- **`Registration.shift_id`** (klucz obcy): raporty 11–15 łączą rejestracje z całego okresu, czyli 30–70% tabeli, więc najtańszy jest Hash Join ze skanem sekwencyjnym. Indeks byłby potrzebny przy usuwaniu zmian (sprawdzanie klucza obcego), czego system nie przewiduje.
- **`Employee.manager_id`:** rekurencyjne zapytanie o hierarchię trwa 17 ms na 6 200 wierszach.
- **Raporty z całego okresu** (11–15, 18, pary współpracowników) czytają większość wierszy, więc indeks im nie pomoże (zapytanie 14, sekcja 3.2).

## 3. Weryfikacja przed i po

### 3.1. Wszystkie zapytania z zajęć 5

Czas w ms: `\timing` w psql, minimum z 3 przebiegów, razem z planowaniem. Kolumna „Plan po” mówi, czy plan się zmienił, i podaje użyte nowe indeksy (porównanie `EXPLAIN (COSTS OFF)` z indeksami i bez nich).

| Nr | Zapytanie | Przed | Po | Zmiana | Plan po |
|---|---|---:|---:|---:|---|
| 1 | Stan zatrudnienia (ROLLUP) | 13,0 | 15,0 | +15% | bez zmian |
| 2 | Łańcuch przełożonych | 17,5 | 18,2 | +4% | bez zmian |
| 3 | Warunki zatrudnienia w dniu | 4,0 | 4,2 | +5% | `ix_contract_employee_start`, `ix_employee_team` |
| 4 | Struktura wg typu umowy | 6,3 | 6,6 | +5% | bez zmian |
| 5 | Umowy kończące się | 5,0 | 6,7 | +34% | bez zmian |
| 7 | Wykorzystanie stref | 93,5 | 90,1 | −4% | `ix_shift_start_time` |
| 8 | Czy można przydzielić | 193,8 | 11,0 | **−94%** | 7 nowych indeksów |
| 9 | Gotowość grafiku | 788,9 | 451,9 | **−43%** | `ix_assignment_employee`, `ix_employee_team`, `ix_shift_schedule` |
| 10 | Karta czasu pracy | 66,3 | 39,0 | **−41%** | `ix_assignment_employee`, `ix_registration_employee` |
| 11 | Plan a rejestracje | 294,5 | 318,9 | +8% | `ix_shift_start_time` |
| 12 | Spóźnienia w działach | 312,7 | 343,3 | +10% | bez zmian |
| 13 | Top 3 spóźniających się | 62,5 | 66,3 | +6% | bez zmian |
| 14 | Histogram odchyleń | 426,8 | 466,9 | +9% | bez zmian |
| 15 | Sekwencje zdarzeń | 451,6 | 591,9 | **+31%** | `ix_registration_employee` |
| 16 | Kolejka weryfikacji | 67,0 | 65,7 | −2% | `ix_registration_pending` |
| 18 | Średnia krocząca | 98,3 | 102,0 | +4% | `ix_shift_start_time` |
| – | Ścieżka hierarchii | 16,8 | 17,0 | +1% | bez zmian |
| – | Nieobecności w miesiącu | 14,3 | 14,6 | +2% | bez zmian |
| – | Nieobecności kolidujące z przydziałem | 74,6 | 73,3 | −2% | bez zmian |
| – | Pary współpracowników | 727,5 | 763,2 | +5% | bez zmian |
| – | Staż a punktualność | 75,3 | 77,5 | +3% | bez zmian |
| – | Grafiki wg statusu | 1,3 | 1,3 | 0% | bez zmian |
| – | Deklaracje dostępności | 5,0 | 5,2 | +4% | bez zmian |

Zapytania o niezmienionym planie różnią się o −2…+15%, a najkrótsze (poniżej 10 ms) o 1–2 ms, czyli nawet o 34%. To szum pomiaru. Poza szumem są cztery zapytania: 8, 9 i 10 wyraźnie przyspieszyły, a 15 zwolniło. Plan zmienił się w 9 z 23 zapytań. Pozostałe 14 czyta duże części tabel albo małe tabele, więc nowych indeksów nie używa.

### 3.2. Analiza wybranych zapytań

Liczby z `EXPLAIN (ANALYZE, BUFFERS)` w `before.txt` i `after.txt`. Bufory to liczba stron (po 8 kB) z węzła głównego.

| Zapytanie | Przed [ms] | Po [ms] | Bufory przed → po | JIT przed → po [ms] |
|---|---:|---:|---|---|
| 7 | 130,4 | 120,6 | 2 502 → 2 424 | – |
| 8 | 211,4 | 14,4 | 86 101 → 11 332 | 33,1 → – |
| 9 | 941,8 | 512,5 | 177 044 → 68 772 | 337,7 → 367,7 |
| 10 | 105,5 | 51,0 | 14 511 → 6 938 | – |
| 14 | 511,8 | 528,3 | 7 036 → 7 036 | – |
| 15 | 580,0 | 723,0 | 7 036 → 162 901 | 8,7 → 10,6 |
| 16 | 80,1 | 80,4 | 7 186 → 1 958 | – |

**Zapytanie 8: czy pracownika można przydzielić.** Przed: pięć podzapytań skorelowanych wykonywanych dla każdego z 40 pracowników działu, każde z pełnym skanem tabeli (Contract 16 tys., Absence 7 tys., Availability 9 tys. wierszy, Shift 71 tys. wierszy). W planie jest ich siedem, bo dwa są zdublowane (zob. 3.4 C). Po: każde podzapytanie idzie indeksem po `employee_id` (`ix_contract_employee_start`, `ix_absence_employee`, `ix_availability_employee`, `ix_assignment_employee`), zmiany dnia przez `ix_shift_start_time`, a pracownicy działu przez `ix_employee_team`. Szacowany koszt spadł ze 173 tys. do 35 tys. jednostek, poniżej progu JIT (100 tys.), więc zniknęła też kompilacja (33 ms). Wynik: 211 → 14 ms, bufory −87%.

**Zapytanie 9: gotowość roboczego grafiku.** Przed: podzapytanie `employees_without_shifts` (SubPlan 1) wykonywało się 251 razy i za każdym razem czytało całe tabele Shift (71 tys. wierszy) i Employee: 2,08 ms na wykonanie, razem 522 ms. Po: dzięki `ix_shift_schedule`, `ix_employee_team` i `ix_assignment_employee` jedno wykonanie trwa 0,21 ms, razem 53 ms. Całość trwa jednak 512 ms, z czego 368 ms to JIT. Przyczyna jest w szacunku: `GroupAggregate (… rows=71159 …) (actual … rows=251 …)`. Planer zakłada 71 159 grup (tyle, ile jest zmian) zamiast 251 (tyle, ile grafików roboczych), mnoży przez to koszt podzapytania i dostaje 11 mln jednostek, czyli ponad próg JIT z optymalizacją (500 tys.). Z `SET jit = off` to samo zapytanie po indeksach trwa 130 ms.

**Zapytanie 10: karta czasu pracy.** Przed: CTE `shift_events` czytało całą Registration (Seq Scan, 629 202 wiersze, 24 ms), żeby zostawić 170 rejestracji jednego pracownika, a przydziały szukało przez cały indeks `uq_assignment_shift_employee` (4,9 ms). Po: `Bitmap Index Scan on ix_registration_employee` (0,04 ms) i `Index Scan using ix_assignment_employee` (0,02 ms). Z pozostałych 51 ms aż 48 ms to podzapytanie w `params`, które wybiera pracownika z największą liczbą rejestracji przez `GROUP BY` całej tabeli (zob. 3.4 D).

**Zapytanie 7: wykorzystanie stref.** Zmiany bieżącego miesiąca (17 099 z 71 159, czyli 24%) są czytane przez `Bitmap Index Scan on ix_shift_start_time` w 2,2 ms zamiast 12,4 ms. Przydziały do nich to jednak 89 tys. z 374 tys. wierszy Assignment, więc Seq Scan z Hash Join pozostaje najtańszy, a najwięcej czasu zajmuje agregacja. Zysk: ok. 8%.

**Zapytanie 16: kolejka weryfikacji.** Indeks częściowy `ix_registration_pending` zawiera tylko rejestracje `unverified` i `needs_explanation` (71 633 z 629 202) razem z potrzebnymi kolumnami. Zamiast skanu całej tabeli jest więc `Index Only Scan`: 7,1 ms zamiast 19 ms w każdym z trzech procesów, bufory spadają z 7 186 do 1 958. Czas całości się nie zmienił, bo plan przestał być równoległy, a sortowanie 71 tys. wierszy w jednym procesie przekracza `work_mem` i idzie na dysk (`external merge Disk: 4920kB`). Indeks zmniejszył odczyty o 73%. Przy danych spoza pamięci podręcznej przełożyłoby się to na czas; tutaj wszystko było w pamięci.

**Zapytanie 14: histogram odchyleń.** Plan jest identyczny przed i po: Seq Scan na Registration (419 626 z 629 202 wierszy, 67%) i na Shift (51 630 z 71 159, 73%). Przy takiej części tabeli odczyt sekwencyjny jest tańszy niż sięganie przez indeks do każdego wiersza, więc planer słusznie pomija `ix_shift_start_time`. Różnica czasów to szum.

### 3.3. Gdy indeks szkodzi: zapytanie 15

Zapytanie 15 (poprawność sekwencji zdarzeń) grupuje wszystkie rejestracje według `(employee_id, shift_id)`. Bez indeksów: Seq Scan, Hash Join i sortowanie 629 tys. wierszy na dysku (`external merge Disk: 30856kB`), 580 ms. Z indeksami planer czyta całą tabelę przez `ix_registration_employee`, bo dostaje wtedy dane posortowane po `employee_id` i dosortowuje je tylko w obrębie pracownika (`Incremental Sort`, `Presorted Key: registration.employee_id`), bez sortowania na dysku. Szacunkowo jest taniej (koszt 105 tys. zamiast 108 tys.), a w rzeczywistości trwa 723 ms. Odczyt w kolejności indeksu skacze po stronach tabeli (korelacja `employee_id` z kolejnością fizyczną: 0,037), co widać w buforach: 162 901 odwiedzin stron zamiast 7 036. Do tego dochodzi 629 tys. wyszukiwań zmiany przez `Memoize`.

Indeks zostaje, bo karta czasu pracy (zapytanie 10) jest wyszukiwaniem wykonywanym często i dla każdego pracownika, a raport 15 powstaje okresowo. Regresję lepiej usunąć przez `work_mem`: z `SET work_mem = '64MB'` sortowanie mieści się w pamięci, planer wraca do Seq Scan i zapytanie trwa 507 ms, czyli mniej niż przed indeksami.

### 3.4. Czy można inaczej zdefiniować zapytania

**A. Warunek na kolumnie, a nie na funkcji od niej.** Te same zmiany z jutrzejszego dnia zapisane na dwa sposoby, po dodaniu indeksów:

| Wariant | Warunek | Plan | Czas | Bufory |
|---|---|---|---:|---:|
| A1 | `CAST(shift.start_time AS DATE) = CURRENT_DATE + 1` | Seq Scan | 3,8 ms | 454 |
| A2 | `shift.start_time >= CURRENT_DATE + 1 AND shift.start_time < CURRENT_DATE + 2` | Index Only Scan on `ix_shift_start_time` | 0,12 ms | 4 |

Indeks B-tree przechowuje wartości `start_time`, a nie `CAST(start_time AS DATE)`, więc warunek A1 nie może z niego skorzystać. Potrzebny byłby osobny indeks wyrażeniowy. Dlatego zapytania 7, 8, 10, 11 i 18 zapisują okresy jako przedział półotwarty na samej kolumnie.

**B. Jedno przejście zamiast trzech (zapytanie 14).** Oryginał liczy udziały procentowe przez podzapytania `(SELECT COUNT(*) FROM deviations WHERE …)`. CTE `deviations` jest użyte trzy razy, więc PostgreSQL je materializuje (419 tys. wierszy) i czyta trzy razy. Wariant B liczy mianownik funkcją okna `SUM(COUNT(*) FILTER (…)) OVER ()`, więc CTE jest użyte raz i zostaje wstawione inline. Wynik jest identyczny (`EXCEPT` w obie strony daje 0 wierszy), a czas spada o 13%: 512 → 447 ms przed indeksami i 528 → 459 ms po. Planer wybrał tu sortowanie na dysku zamiast `HashAggregate`, bo nie umie oszacować liczby przedziałów wyrażenia `FLOOR(…) * 5`. Z większym `work_mem` byłoby jeszcze szybciej.

**C. `MATERIALIZED` w zapytaniu 8.** CTE `employee_facts` jest wstawione inline, a `CASE WHEN ef.assigned_shift IS NOT NULL THEN 'already_assigned ' || ef.assigned_shift` odwołuje się do podzapytania dwa razy. W planie są więc dwa identyczne SubPlany (8 i 9, podobnie 5 i 6). Zapis `WITH employee_facts AS MATERIALIZED (…)` liczy każde podzapytanie raz na pracownika: po indeksach czas spada z 11–15 ms do 8–10 ms (3 przebiegi), czyli o ok. 30%.

**D. Parametr zamiast podzapytania (zapytanie 10).** Wybór pracownika z największą liczbą rejestracji kosztuje pełny skan Registration (48 z 51 ms po indeksach). W aplikacji `employee_id` byłby parametrem z formularza i karta czasu pracy trwałaby kilka milisekund.

**E. JIT w zapytaniu 9.** Przez złą estymację liczby grup kompilacja JIT trwa dłużej niż samo wykonanie. Można wyłączyć JIT dla sesji raportowej (`SET jit = off`: 512 → 130 ms) albo podnieść `jit_above_cost`. W systemach z wieloma krótkimi zapytaniami JIT często wyłącza się globalnie.

## Wnioski

1. Indeksy dały największy zysk tam, gdzie zapytanie wielokrotnie wybiera mały podzbiór dużej tabeli: podzapytania skorelowane w zapytaniach 8 i 9 oraz wyszukiwanie po pracowniku w zapytaniu 10 (−94%, −43%, −41%). Najważniejsze okazały się indeksy na kluczach obcych, których PostgreSQL nie tworzy sam.
2. Raporty z całego okresu (11–15, 18, pary współpracowników) czytają 30–70% tabel. Skan sekwencyjny jest dla nich optymalny i indeksy ich nie przyspieszą; pomóc może większy `work_mem` albo agregaty liczone z wyprzedzeniem.
3. Indeks może zaszkodzić. Zapytanie 15 zwolniło o 25% (580 → 723 ms), bo planer wybrał odczyt całej tabeli przez indeks, żeby uniknąć sortowania na dysku. Każdy nowy indeks trzeba sprawdzić na wszystkich zapytaniach, nie tylko na tym, dla którego powstał.
4. Szacowany koszt to nie czas. Zła estymacja liczby grup w zapytaniu 9 włączyła JIT, który zajmuje 368 z 512 ms. Dlatego plan trzeba mierzyć przez `EXPLAIN ANALYZE` i porównywać szacowane `rows` z rzeczywistymi.
5. Sposób zapisu zapytania wpływa na plan nie mniej niż indeksy: warunek na samej kolumnie (wariant A: 3,8 → 0,12 ms), jedno przejście zamiast trzech (wariant B: −13%), `MATERIALIZED` (zapytanie 8: −30%).
