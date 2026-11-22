# Raporty i funkcje wyszukiwania – `sql/03_reports.sql`

Zajęcia 5: 24 zapytania `SELECT` na bazie wypełnionej generatorem. Każde odpowiada na inną potrzebę informacyjną z rozdziału 1.2 dokumentacji (pytania **P1–P14** w `docs/project_chapters_1-5.pdf`) albo na wymagania funkcjonalne (**F15, F21, F25, F30–F32, F34–F36**). Osiem zapytań to raporty statystyczne. Plik niczego nie zmienia w bazie.

## Uruchomienie

Najpierw utwórz schemat i wypełnij bazę ([README.md](../README.md), [generator/README.md](../generator/README.md)). Potem z katalogu głównego repozytorium:

```bash
docker compose exec -T postgres psql -X -U projektowaniebazdanych -d ewidencja_czasu_pracy < sql/03_reports.sql
```

Przed każdym zapytaniem `psql` wypisuje nagłówek `=== N. … ===`. W pgAdmin pomiń linie zaczynające się od `\` (to polecenia `\echo`) i uruchamiaj zapytania pojedynczo.

**Dane muszą być świeże.** Generator tworzy dane od 2 miesięcy przed bieżącym do końca następnego, licząc od dnia uruchomienia, a zapytania liczą okresy względem dzisiejszej daty (`CURRENT_DATE`, `LOCALTIMESTAMP`). Przed prezentacją uruchom generator ponownie.

## Parametry

Zapytania wyszukujące zaczynają się od CTE `params`, na przykład:

```sql
WITH params AS (
    SELECT CURRENT_DATE AS report_date,
           CAST(NULL AS VARCHAR) AS team_name
)
```

Aby wyszukać coś innego, zmień wartość w `params`, np. `DATE '2026-06-30' AS report_date` albo `CAST('Kadry' AS VARCHAR) AS team_name`. Wartość `NULL` w filtrze tekstowym oznacza „bez filtru”. Domyślne wartości wybrano tak, żeby na losowych danych zapytanie zawsze coś zwracało: daty są względne, a gdzie potrzebny jest konkretny dział lub pracownik, wybiera go podzapytanie (np. dział z największą liczbą pracowników).

## Reguły wspólne dla raportów

| Pojęcie | Definicja w zapytaniach |
|---|---|
| Okres | Przedział półotwarty `[od, do)`, np. poprzedni miesiąc to `date_trunc('month', LOCALTIMESTAMP) - INTERVAL '1 month'` do `date_trunc('month', LOCALTIMESTAMP)`. Typ `timestamp without time zone` jest ten sam co w kolumnach, więc nie ma konwersji stref czasowych. |
| Obowiązujący grafik | Tylko grafiki `published`. Wersje `archived` są historią (F22), a `draft` to grafik w przygotowaniu. |
| Spóźnienie | Wejście (`work_start`) ponad 10 minut po początku zmiany. Tolerancja to parametr `late_tolerance` i odpowiada regule, według której system nadaje status `needs_explanation`. |
| Czas pracy zmiany | `work_end − work_start` minus przerwa, ale tylko jej część ponad 15 minut. Zgodnie z art. 134 Kodeksu pracy 15 minut przerwy wlicza się do czasu pracy. Parametr: `paid_break`. |
| Warunki zatrudnienia w dniu `d` (F15) | Umowa obowiązująca w dniu `d` i ostatni aneks z `effective_from <= d`. Ostatni oznacza taki, dla którego nie istnieje (`NOT EXISTS`) późniejszy aneks tej umowy. Jeśli aneks obowiązuje, jego stanowisko, etat i data końca zastępują warunki z umowy. |

## Przegląd

**[Z]** – jedno zapytanie z techniką zaawansowaną. Pozostałe używają `JOIN`, CTE, podzapytań, `EXISTS`, `GROUP BY`/`HAVING`, `CASE` i `FILTER`.

| Nr | Raport | Potrzeba | Główne techniki |
|---|---|---|---|
| 1 | Stan zatrudnienia i etaty (FTE) z sumami pośrednimi | P1, F10 | **[Z]** `ROLLUP`, `GROUPING()`, warunki z aneksem |
| 2 | Łańcuch przełożonych do prezesa | P2 | **[Z]** `WITH RECURSIVE`, `string_agg` |
| 3 | Warunki zatrudnienia w wybranym dniu | P14, F15 | `LEFT JOIN` aneksu, `NOT EXISTS`, `COALESCE` |
| 4 | Struktura zatrudnienia wg typu umowy | statystyka | `LEFT JOIN` słownika, `AVG`/`MIN`/`MAX`, udział % |
| 5 | Umowy kończące się w ciągu N dni i ich kontynuacja | F15, F34 | arytmetyka dat, self-join |
| 6 | Obsada dnia ze stanem obecności | P3, P4, F34 | wielokrotny `JOIN`, `LEFT JOIN` rejestracji, `CASE` |
| 7 | Wykorzystanie stref w bieżącym miesiącu | P5, F35 | agregacja dwupoziomowa, `FILTER` |
| 8 | Czy pracownika działu można przydzielić w danym dniu | P6, F25 | `EXISTS`, podzapytania skalarne, priorytet w `CASE` |
| 9 | Gotowość roboczego grafiku na następny miesiąc | F21 | `LEFT JOIN` + `COUNT`, skorelowane `NOT EXISTS` |
| 10 | Karta czasu pracy pracownika za poprzedni miesiąc | P9, F32 | agregacja warunkowa `MIN/MAX … FILTER`, `bool_or` |
| 11 | Czas planowany a zarejestrowany powyżej progu | P10, F35 | dwa CTE, `HAVING` |
| 12 | Spóźnienia – statystyka działów | P11 | **[Z]** `percentile_cont` (mediana) |
| 13 | Trzech najczęściej spóźniających się w każdym dziale | P11 | **[Z]** `RANK() OVER (PARTITION BY …)` |
| 14 | Rozkład odchyleń wejść i wyjść od godzin zmiany | statystyka, F35 | histogram (`FLOOR`), `COUNT … FILTER` |
| 15 | Poprawność sekwencji zdarzeń rejestracji | P11, F30 | `string_agg(… ORDER BY …)` |
| 16 | Kolejka weryfikacji rejestracji wg przełożonych | F31 | self-join, `COUNT(DISTINCT)`, `FILTER` |
| 17 | Zestawienie miesięczne dla księgowości | P12, F35 | `SUM … FILTER`, `COUNT(DISTINCT)` |
| 18 | Dzienna obsada i średnia krocząca 7 dni | statystyka | **[Z]** `AVG() OVER (RANGE …)` |
| 19 | Nieobecności w kwartale wg typu | P7 | przycinanie przedziałów, **[Z]** `mode()` |
| 20 | Wskaźnik absencji działów (tylko dni pracy) | P7, statystyka | **[Z]** `generate_series` w `LATERAL` |
| 21 | Ranking Bradforda (krótkie, częste absencje) | statystyka HR | `COUNT² × SUM`, progi w `CASE` |
| 22 | Konta z uprawnieniami wrażliwymi | P13 | `bool_or`, `string_agg(DISTINCT …)`, `HAVING` |
| 23 | Kto zmieniał dane – aktywność w audycie | P13, F36 | `LEFT JOIN`, `COALESCE`, `FILTER` |
| 24 | Czy staż wiąże się z punktualnością | statystyka | **[Z]** `corr`, `regr_slope`, `regr_r2`, `stddev_samp` |

## Pokrycie potrzeb informacyjnych z rozdziału 1.2

| Pytanie z dokumentacji | Zapytanie |
|---|---|
| P1. Którzy pracownicy należą do oddziału, działu lub zespołu? | 1 (liczebnie), 3 (imiennie, filtr `team_name`) |
| P2. Kto jest przełożonym pracownika i jakie zajmuje stanowisko? | 2 |
| P3. Kto ma zaplanowaną pracę w określonym terminie? | 6 |
| P4. Do jakich zmian i stref przypisano pracowników? | 6, 7 |
| P5. Ilu pracowników zaplanowano w strefie i czy nie przekroczono pojemności? | 7 |
| P6. Którzy pracownicy są dostępni w wybranym terminie? | 8 |
| P7. Kto ma nieobecności w okresie i jakiego typu? | 19, 20 |
| P8. Czy są konflikty między zmianami, dostępnością i nieobecnościami? | testy 3–7 w [`generator/check_data.sql`](../generator/check_data.sql); dla jednego dnia także 8 |
| P9. Ile czasu pracy wynika z rejestracji pracownika? | 10 |
| P10. Jakie są różnice między czasem planowanym a zarejestrowanym? | 11 |
| P11. Kto ma spóźnienia lub niekompletne rejestracje? | 12, 13, 15 |
| P12. Jakie zestawienia czasu pracy przygotować dla księgowości? | 17 |
| P13. Jakie role i uprawnienia ma użytkownik i kto zmieniał dane? | 22, 23 |
| P14. Jakie warunki zatrudnienia obowiązywały w wybranym dniu? | 3 |

## Funkcje agregujące

| Funkcja | Zapytania | Co pokazuje |
|---|---|---|
| `COUNT(*)`, `COUNT(kolumna)` | 1, 2, 4, 7, 9, 11–24 | `COUNT(kolumna)` po `LEFT JOIN` nie liczy `NULL`, dlatego typ umowy bez umów ma w zapytaniu 4 wartość 0 |
| `COUNT(DISTINCT …)` | 16, 17, 18, 19, 22 | osoby zamiast zdarzeń, np. liczba pracujących w miesiącu |
| `SUM` | 1, 11, 13, 17, 19, 21 | etaty, godziny, minuty spóźnień, dni nieobecności |
| `AVG` | 4, 7, 9, 12, 19, 24 | średnia obsada, średnia długość nieobecności, średni staż |
| `MIN`, `MAX` | 4, 7, 9, 10, 12, 15, 16, 23 | skrajne wartości, najstarsze oczekujące zdarzenie |
| `string_agg` | 2, 15, 22, 23 | ścieżka przełożonych, sekwencja zdarzeń, lista ról |
| `bool_or` | 10, 22 | „czy którakolwiek rola daje uprawnienie” |
| `percentile_cont` | 12 | mediana spóźnienia – odporna na pojedyncze skrajne wartości |
| `mode()` | 19 | najczęstszy dzień rozpoczęcia nieobecności |
| `stddev_samp` | 24 | rozrzut odsetka spóźnień |
| `corr`, `regr_slope`, `regr_r2` | 24 | korelacja i regresja liniowa |
| `GROUPING()` | 1 | odróżnia wiersz sumy od zwykłego wiersza |
| klauzula `FILTER (WHERE …)` | 1, 4, 7, 9, 10, 11, 12, 14, 16, 17, 19, 20, 23, 24 | kilka liczników z różnymi warunkami w jednym przebiegu |
| funkcje okna `RANK`, `AVG() OVER` | 13, 18 | ranking w grupie, średnia krocząca |

## Opis zapytań

### 1. Stan zatrudnienia i etaty (FTE) z sumami pośrednimi
**Pytanie:** ilu pracowników i ile etatów ma każdy zespół, dział i oddział?
**Parametry:** `report_date` (dziś).
**Jak działa:** CTE `current_terms` ustala dla każdego pracownika wymiar etatu obowiązujący w danym dniu, z uwzględnieniem aneksów. `GROUP BY ROLLUP (oddział, dział, zespół)` dokłada wiersze sum dla działu, oddziału i całej firmy. `GROUPING()` rozpoznaje te wiersze i zamienia `NULL` na etykiety „department total”, „branch total” i „ALL BRANCHES”.
**Wynik:** `employee_count` liczy rekordy niearchiwalne, a `employed_today` tylko osoby z umową obowiązującą dziś. Różnicę tworzą nowi pracownicy, których umowa zaczyna się w przyszłości.

### 2. Łańcuch przełożonych do prezesa
**Pytanie:** kto jest przełożonym pracownika, kto przełożonym przełożonego i jakie stanowiska zajmują (P2)?
**Parametry:** `last_name_pattern`, np. `'Kow%'`. `NULL` oznacza wszystkich.
**Jak działa:** rekurencyjne CTE `chain` zaczyna od pracownika i jego bezpośredniego przełożonego, a w każdym kroku przechodzi o poziom wyżej przez `manager_id`. Kończy się na prezesie, który nie ma przełożonego. Warunek `level < 20` chroni przed nieskończoną pętlą, gdyby w danych pojawił się cykl. `string_agg(… ORDER BY level)` składa ścieżkę w jeden tekst.

### 3. Warunki zatrudnienia w wybranym dniu
**Pytanie:** na jakiej umowie, stanowisku i etacie pracownik był zatrudniony w danym dniu (P14, F15)?
**Parametry:** `report_date`, `team_name`.
**Jak działa:** dla umowy obowiązującej w danym dniu dołącza ostatni aneks, który już wszedł w życie, i bierze z niego warunki (`COALESCE(aneks, umowa)`). Kolumna `terms_source` pokazuje, skąd pochodzą warunki. Data sprzed roku pokazuje np. umowy na okres próbny zamiast obecnych umów na czas nieokreślony.

### 4. Struktura zatrudnienia wg typu umowy
**Pytanie:** jak rozkłada się zatrudnienie na typy umów i jaki staż mają osoby na każdym typie?
**Jak działa:** `LEFT JOIN` od słownika `ContractType` pokazuje także typy bez żadnej umowy. Udział procentowy liczy podzapytanie skalarne. Staż liczy się od pierwszej umowy pracownika (CTE `employment_start`), a nie od obecnej, więc nie zeruje się przy przejściu z umowy na czas określony na nieokreślony.
**Wynik:** umowy próbne i na czas określony mają krótki staż i wysoki `hired_last_12_months`. Umowy na czas nieokreślony to pracownicy z najdłuższym stażem.

### 5. Umowy kończące się w ciągu N dni i ich kontynuacja
**Pytanie:** czyje umowy niedługo wygasają i czy jest już podpisana umowa następna?
**Parametry:** `days_ahead` (90).
**Jak działa:** data końca pochodzi z umowy albo z jej ostatniego aneksu (aneks może zmienić termin). Umowę następną wskazuje `LEFT JOIN` na umowę tego pracownika zaczynającą się dzień po końcu bieżącej. Jej brak (`none`) oznacza sprawę do załatwienia dla kadr. Kolumna `notify_manager` wskazuje bezpośredniego przełożonego.

### 6. Obsada dnia ze stanem obecności
**Pytanie:** kto pracuje w danym dniu, na której zmianie i w której strefie, i czy już przyszedł (P3, P4)?
**Parametry:** `roster_date` (domyślnie ostatni dzień ze zmianami do teraz), `department_name`.
**Jak działa:** zmiany z opublikowanych grafików z danego dnia łączy z przydziałami i strefami. Dwa `LEFT JOIN` do `Registration` pobierają wejście i wyjście. `CASE` nadaje status: `upcoming`, `no_registration`, `in_progress`, `late` albo `on_time`. Filtr dnia ma postać `start_time >= dzień AND start_time < dzień + 1`, a nie `CAST(start_time AS DATE) = dzień`, żeby na zajęciach 6 mógł zadziałać indeks na `start_time`.

### 7. Wykorzystanie stref w bieżącym miesiącu
**Pytanie:** ile osób pracuje w każdej strefie w stosunku do jej pojemności (P5)?
**Jak działa:** CTE `zone_slots` liczy osoby w strefie na każdy początek zmiany. Działy, które dzielą strefę (np. open space w centrali), sumują się, bo pojemność dotyczy strefy, a nie działu. Zapytanie zewnętrzne agreguje sloty: średnia i maksymalna obsada, średnie wykorzystanie % oraz liczba slotów pełnych (`FILTER`). Wykorzystanie liczy się tylko ze slotów, w których strefa była używana.

### 8. Czy pracownika działu można przydzielić w danym dniu
**Pytanie:** kogo z działu można postawić na zmianę w danym dniu, a kogo nie i dlaczego (P6, F25)?
**Parametry:** dział (domyślnie ten z największą liczbą pracowników), `check_date` (najbliższy dzień pracy działu od jutra).
**Jak działa:** CTE `employee_facts` zbiera dla każdego pracownika fakty: czy ma umowę, typ nieobecności, deklarację niedostępności lub dostępności i zmianę, na którą już jest przydzielony. `CASE` wybiera jeden status w kolejności ważności. Zgodnie z F25 odróżnia `declared_available`, `declared_unavailable` i `no_declaration`. Brak deklaracji nie blokuje przydziału.

### 9. Gotowość roboczego grafiku na następny miesiąc
**Pytanie:** czy grafiki robocze można już publikować (F21)?
**Jak działa:** CTE `shift_staffing` liczy obsadę każdej zmiany grafiku `draft`. `LEFT JOIN` sprawia, że zmiana bez przydziałów ma obsadę 0. Zapytanie zewnętrzne podaje dla działu liczbę zmian, zmiany bez obsady oraz minimalną, średnią i maksymalną obsadę. Skorelowane podzapytanie z `NOT EXISTS` liczy pracowników działu bez żadnej zmiany w tym grafiku. Są wśród nich zwykle prezes i dyrektorzy oddziałów, którzy nie pracują na zmiany.

### 10. Karta czasu pracy pracownika za poprzedni miesiąc
**Pytanie:** ile pracownik przepracował każdego dnia (P9, F32)?
**Parametry:** `employee_id` (domyślnie osoba z największą liczbą rejestracji), `paid_break`, `late_tolerance`.
**Jak działa:** CTE `shift_events` zamienia cztery wiersze zdarzeń jednej zmiany na jeden wiersz z kolumnami wejście, wyjście, początek i koniec przerwy (`MIN/MAX(event_time) FILTER (WHERE event_type = …)`). Status zmiany to najgorszy status jej zdarzeń (`bool_or`). Czas pracy liczy się według reguły art. 134 KP z tabeli reguł.

### 11. Czas planowany a zarejestrowany powyżej progu
**Pytanie:** u kogo czas zarejestrowany w poprzednim miesiącu różni się od planu o więcej niż próg (P10, F35 „potencjalne przekroczenia”)?
**Parametry:** `threshold` (2 h), `paid_break`.
**Jak działa:** CTE `planned` sumuje długość zaplanowanych zmian, a `worked` czas z kompletnych rejestracji. `HAVING ABS(zarejestrowany − planowany) > próg` zostawia tylko osoby z odchyleniem. Dodatnia różnica to możliwe nadgodziny, ujemna to braki lub niekompletne rejestracje.

### 12. Spóźnienia – statystyka działów
**Pytanie:** w których działach spóźnienia są najczęstsze i jak duże (P11)?
**Parametry:** okres (ostatnie 90 dni), `late_tolerance`.
**Jak działa:** dla każdego wejścia CTE `arrivals` liczy minuty od początku zmiany i flagę `is_late`. Zapytanie podaje liczbę i odsetek spóźnień, średnią, medianę (`percentile_cont(0.5) WITHIN GROUP`) i maksimum. Mediana jest mniej wrażliwa na pojedyncze bardzo długie spóźnienia niż średnia.
**Kontrola:** suma `late_arrivals` równa się liczbie rejestracji `needs_explanation` w tym okresie.

### 13. Trzech najczęściej spóźniających się w każdym dziale
**Pytanie:** kto w każdym dziale spóźnia się najczęściej (P11)?
**Jak działa:** po zgrupowaniu spóźnień na pracownika `RANK() OVER (PARTITION BY department_id ORDER BY liczba DESC, suma minut DESC)` numeruje osoby osobno w każdym dziale. Warunek `rank_in_department <= 3` daje „top 3 w grupie”, czego nie da się zrobić samym `LIMIT`. `RANK` daje ten sam numer przy remisie, więc w dziale może być więcej niż trzy osoby.

### 14. Rozkład odchyleń wejść i wyjść od godzin zmiany
**Pytanie:** jak punktualnie zaczyna się i kończy pracę? Kto przychodzi wcześniej, a kto zostaje po zmianie (F35)?
**Jak działa:** odchylenie wejścia od początku zmiany i wyjścia od jej końca trafia do przedziałów co 5 minut (`FLOOR(sekundy / 300) * 5`). Dwa liczniki `COUNT … FILTER` tworzą obok siebie dwa histogramy, a udziały liczą się osobno dla wejść i wyjść. Ujemne przedziały to przyjście lub wyjście przed czasem, dodatnie przy wyjściu to praca po zmianie.

### 15. Poprawność sekwencji zdarzeń rejestracji
**Pytanie:** ile zmian ma kompletną, poprawną rejestrację, a ile wymaga wyjaśnienia (P11, F30)?
**Jak działa:** `string_agg(event_type, ' > ' ORDER BY event_time)` zapisuje zdarzenia jednej zmiany w kolejności, np. `work_start > break_start > break_end > work_end`. Poprawne są dwie sekwencje. Niepełna sekwencja zmiany, która jeszcze trwa albo skończyła się mniej niż `clock_out_grace` (1 h) temu, to `shift_in_progress`, a pozostałe to `invalid`.

### 16. Kolejka weryfikacji rejestracji wg przełożonych
**Pytanie:** ile rejestracji czeka na sprawdzenie u każdego przełożonego i od kiedy (F31)?
**Jak działa:** rejestracje `unverified` i `needs_explanation` są grupowane według bezpośredniego przełożonego pracownika (self-join `Employee`). `COUNT(DISTINCT employee_id)` podaje, ilu podwładnych dotyczy kolejka, a `MIN(event_time)` – jak długo czeka najstarsza pozycja.

### 17. Zestawienie miesięczne dla księgowości
**Pytanie:** ile godzin przepracowano w każdym dziale i miesiącu, w tym w nocy i w soboty (P12, F35)?
**Parametry:** okres (2 pełne miesiące i bieżący do dziś), `paid_break`, `late_tolerance`.
**Jak działa:** czas każdej zmiany liczy się jak w zapytaniu 10, ale dla wszystkich pracowników. Wyniki są grupowane według miesiąca, oddziału i działu. `SUM(…) FILTER` wydziela godziny zmian nocnych (start o 22:00, przy założeniu, że pracodawca ustalił porę nocną na 22:00–6:00) i sobotnich – podstawę dodatków liczonych poza systemem.

### 18. Dzienna obsada i średnia krocząca 7 dni
**Pytanie:** jak zmienia się liczba osób na zmianach z dnia na dzień i jaki jest trend?
**Parametry:** okres (4 tygodnie wstecz i 2 tygodnie naprzód).
**Jak działa:** CTE `daily` liczy osoby na zmianach każdego dnia. `AVG(…) OVER (ORDER BY work_date RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW)` uśrednia ostatnie 7 dni kalendarzowych, a nie 7 wierszy, więc niedziele i święta bez zmian nie przesuwają okna. Dane wejściowe zaczynają się 6 dni przed okresem, żeby pierwsze dni raportu miały pełne okno. `deviation_from_trend` wyraźnie pokazuje soboty i dni świąteczne.

### 19. Nieobecności w kwartale wg typu
**Pytanie:** jakie nieobecności i ile dni przypadło na bieżący kwartał (P7)?
**Parametry:** okres (bieżący kwartał).
**Jak działa:** nieobecność częściowo poza kwartałem jest przycinana (`GREATEST` początku, `LEAST` końca), więc liczą się tylko dni w okresie. Liczniki z `FILTER` oddzielają nieobecności zarejestrowane od anulowanych (F27). `mode() WITHIN GROUP` podaje najczęstszy dzień tygodnia rozpoczęcia, np. czy urlop na żądanie zaczyna się zwykle w poniedziałek. Przy remisie wybiera pierwszą wartość alfabetycznie.

### 20. Wskaźnik absencji działów
**Pytanie:** jaki odsetek dni pracy działy straciły przez nieobecności (P7)?
**Parametry:** okres (od początku miesiąca sprzed dwóch miesięcy do dziś).
**Jak działa:** `generate_series` w `LATERAL` rozwija każdą nieobecność na pojedyncze dni. Liczą się tylko dni, w które dział miał zmiany w opublikowanym grafiku (`EXISTS`), więc niedziele, święta i soboty działów biurowych odpadają same, bez osobnego kalendarza. Wskaźnik = utracone osobodni / (liczba pracowników × dni pracy działu). Mianownik używa bieżącej liczby pracowników, więc to przybliżenie.

### 21. Ranking Bradforda
**Pytanie:** kto ma krótkie, częste nieobecności nieplanowane – najbardziej uciążliwe dla grafiku?
**Parametry:** okres (ostatnie 12 miesięcy).
**Jak działa:** dla zwolnień L4 i urlopów na żądanie liczy S – liczbę epizodów i D – łączną liczbę dni, a potem współczynnik Bradforda B = S² × D. Kwadrat sprawia, że pięć jednodniowych nieobecności (B = 125) waży więcej niż jedna pięciodniowa (B = 5). Progi 50, 125 i 400 to umowne wartości często spotykane w praktyce HR. Na danych testowych (najwyżej 3 nieobecności na osobę) wszyscy mieszczą się w `no_concern`.

### 22. Konta z uprawnieniami wrażliwymi
**Pytanie:** kto może zarządzać kontami, czytać dziennik zmian lub edytować umowy (P13)?
**Parametry:** `login_pattern`.
**Jak działa:** łączy konto, role i uprawnienia. `bool_or(permission_name = …)` mówi, czy którakolwiek rola konta daje dane uprawnienie, a `string_agg(DISTINCT role_name …)` wypisuje role. `HAVING bool_or(… IN (…))` zostawia tylko konta z co najmniej jednym uprawnieniem wrażliwym. Nieaktywne konta, które wciąż mają takie role, są na początku listy jako pierwsze do sprzątnięcia.

### 23. Kto zmieniał dane – aktywność w audycie
**Pytanie:** kto, kiedy i jakie obiekty zmieniał w ostatnich 90 dniach (P13, F36)?
**Jak działa:** `LEFT JOIN` przez `Account` do `Employee` zamienia konto na imię i nazwisko. Operacje automatyczne (`account_id IS NULL`) opisuje `COALESCE` jako `System (automatic)`. Dla każdej pary wykonawca × typ obiektu zapytanie liczy operacje według rodzaju, zbiera powody zmian i podaje pierwszą i ostatnią operację.

### 24. Czy staż wiąże się z punktualnością
**Pytanie:** czy dłużej zatrudnieni spóźniają się rzadziej?
**Parametry:** okres (90 dni), `late_tolerance`, `min_arrivals` (10 – mniej obserwacji daje niewiarygodny odsetek).
**Jak działa:** dla każdego pracownika CTE liczą staż w latach i odsetek spóźnień. `UNION ALL` dubluje obserwacje z etykietą „ALL DEPARTMENTS”, więc jedno `GROUP BY` daje wyniki dla działów i dla całej firmy. `corr` to współczynnik korelacji Pearsona (−1…1), `regr_slope` – o ile punktów procentowych zmienia się odsetek spóźnień na rok stażu, a `regr_r2` – jaką część zmienności wyjaśnia staż.
**Interpretacja:** generator losuje spóźnienia niezależnie od stażu, więc dla całej firmy korelacja wychodzi bliska 0, a R² bliskie 0. To poprawny wniosek: brak związku. Wysokie wartości w małych działach (kilka osób) to przypadek, dlatego wynik pokazuje też liczbę obserwacji.

## Co pokazać prowadzącemu (zajęcia 5)

| Wymaganie | Jak to pokazać |
|---|---|
| min. 20 nietrywialnych, zróżnicowanych zapytań | 24 zapytania w `03_reports.sql`. Tabela pokrycia pokazuje, że każde odpowiada na inne pytanie z rozdziału 1.2 lub wymaganie F |
| bez „podmieniania warunków w WHERE” | wartości wyszukiwania są w jednym miejscu (`params`), a nie w kopiach zapytania. Zapytania różnią się ziarnem grupowania i wynikiem |
| zapytania statystyczne | 4, 12, 14, 18, 19, 20, 21, 24: mediana, histogram, średnia krocząca, wskaźnik absencji, Bradford, korelacja i regresja |
| funkcje agregujące | tabela „Funkcje agregujące”, m.in. `FILTER`, `percentile_cont`, `mode`, `corr`, `GROUPING` |
| funkcje wyszukiwania | zapytania z parametrami: 2, 3, 5, 6, 8, 10, 22 |
| poprawność wyników | kontrole krzyżowe: suma spóźnień w 12 = liczba `needs_explanation`, plan w 11 = 8 h × liczba zmian, FTE w 1 ≤ liczba osób, udziały w 4, 14 i 19 sumują się do 100% |

Analiza `EXPLAIN` tych zapytań przed dodaniem indeksów i po nim (zajęcia 6): [EXPLAIN.md](EXPLAIN.md).
