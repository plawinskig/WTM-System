# Generator danych – `generator/`

Skrypt w Pythonie wypełnia bazę **ewidencja_czasu_pracy** (schemat `work_time`) losowymi danymi. Przy ustawieniach domyślnych w bazie pojawia się ok. **18–21 tys. rekordów**. Każde uruchomienie daje inne dane.

## Pliki

| Plik | Co zawiera |
|---|---|
| `generate_data.py` | główny skrypt – kolejne kroki to osobne, opisane funkcje |
| `models.py` | opis 24 tabel dla SQLAlchemy (ORM) – jedna klasa = jedna tabela |
| `reference_data.py` | dane wpisane ręcznie: role, uprawnienia, typy umów i nieobecności, stanowiska, działy, strefy, święta |
| `check_data.sql` | liczba rekordów w tabelach + 21 testów poprawności danych |
| `requirements.txt` | potrzebne biblioteki |

## Uruchomienie

Najpierw uruchom bazę i utwórz schemat – zob. [README.md](../README.md) w katalogu głównym. Hasło do bazy skrypt odczytuje z pliku `.env` w katalogu głównym repozytorium.

```bash
cd generator
python3 -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python generate_data.py
```

Środowisko wirtualne (`.venv`) jest potrzebne, bo systemowy Python (np. w Ubuntu) blokuje globalne `pip install`. Przy kolejnych uruchomieniach wystarczy je aktywować i uruchomić `python generate_data.py`.

Na początku pliku `generate_data.py` są **ustawienia** (sekcja `SETTINGS`):

| Ustawienie | Domyślnie | Znaczenie |
|---|---|---|
| `EMPLOYEE_COUNT` | 100 | liczba pracowników razem z kadrą kierowniczą |
| `BRANCH_COUNT` | 2 | pierwszy oddział to centrala |
| `MONTHS_BACK` | 2 | ile miesięcy przed bieżącym ma grafiki (dochodzi bieżący i następny) |
| `SEED` | `None` | `None` = za każdym razem inne dane; liczba = zawsze te same dane |

Skrypt najpierw **usuwa stare dane** ze wszystkich tabel, a potem tworzy nowe. Wszystko odbywa się w jednej transakcji, więc jeśli wystąpi błąd, baza zostanie bez zmian.

## Jak działa (w skrócie)

1. **Słowniki** są przepisywane z pliku `reference_data.py` (nie są losowane).
2. **Struktura firmy:** centrala (Administracja, Kadry i płace, Księgowość, IT + jeden dział operacyjny) i oddziały (2 działy operacyjne). W każdym dziale są 2 zespoły. Strefy pracy należą do oddziałów.
3. **Pracownicy:** prezes → dyrektorzy → kierownicy działów → liderzy zespołów → pracownicy. Przełożony powstaje zawsze przed podwładnym, więc w hierarchii nie ma cykli. Każdy pracownik ma konto z rolami i ciąg umów (próbna → określona → nieokreślona). Ok. 6% to byli pracownicy z nieaktywnym kontem.
4. **Grafiki:** jeden na dział i miesiąc. Minione miesiące i bieżący są opublikowane (czasem z archiwalną wersją 1), a następny jest roboczy. Zmiany trwają 8 h i nie ma ich w niedziele ani w dni wolne oddziału.
5. **Przydziały** – każdy pracownik:
   - pracuje tylko w swoim dziale i w strefach swojego oddziału,
   - przez cały tydzień chodzi na tę samą zmianę, co daje co najmniej 11 h odpoczynku,
   - pracuje najwyżej 5 × etat dni w tygodniu,
   - nie dostaje zmian bez umowy, w czasie nieobecności ani w dniu zgłoszonej niedostępności.

   Liczba osób w strefie nie przekracza jej pojemności. Gdy w strefach brakuje miejsc, skrypt pomija część przydziałów i wypisuje ich liczbę („skipped … assignments”).
6. **Rejestracje czasu:** wejście, czasem przerwa, wyjście. Spóźnienia powyżej 10 min mają status `needs_explanation`.
7. **Audit:** publikacje grafików, nowe umowy, odejścia pracowników, wykryte spóźnienia.

## Sprawdzenie danych

Z katalogu głównego repozytorium:

```bash
docker compose exec -T postgres psql -X -U projektowaniebazdanych -d ewidencja_czasu_pracy < generator/check_data.sql
```

Z lokalnym klientem `psql`: `psql -h 127.0.0.1 -p 55432 -U projektowaniebazdanych -d ewidencja_czasu_pracy -f generator/check_data.sql`.

Plik zawiera tylko proste zapytania: `SELECT`, `JOIN`, `LEFT JOIN`, `WHERE`, `GROUP BY`, `HAVING`, `UNION ALL`. Działa też w pgAdmin. Każdy test szuka błędnych wierszy, więc poprawny wynik to **0 wierszy**.

Hasło do wszystkich wygenerowanych kont: **`Test123!`**
