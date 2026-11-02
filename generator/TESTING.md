# Uruchomienie i test seedera

Procedura uruchomienia i sprawdzenia generatora danych (seedera) od zera, np. przed oddaniem projektu. Polecenia uruchamiaj z katalogu głównego repozytorium, chyba że krok mówi inaczej.

Potrzebne są Docker z Compose, Python 3 (sprawdzone na 3.12) i Git. Lokalny klient `psql` nie jest wymagany, bo polecenia uruchamiają go w kontenerze.

> **Windows:** uruchamiaj polecenia w Git Bash. Zamiast `python3` wpisz `python`, a venv aktywuj przez `source .venv/Scripts/activate`.

## 1. Konfiguracja (tylko za pierwszym razem)

```bash
cp .env.example .env
```

W pliku `.env` ustaw własne hasło w `POSTGRES_PASSWORD`.

## 2. Baza danych ze świeżym schematem

```bash
docker compose up -d --wait
docker compose exec -T postgres psql -U projektowaniebazdanych -d ewidencja_czasu_pracy -c 'DROP SCHEMA IF EXISTS work_time CASCADE;'
docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U projektowaniebazdanych -d ewidencja_czasu_pracy < sql/01_schema.sql
```

`DROP SCHEMA` usuwa schemat razem ze wszystkimi danymi, więc test zaczyna się od pustej bazy. Na nowej bazie to polecenie niczego nie usuwa.

## 3. Uruchomienie seedera

```bash
cd generator
python3 -m venv .venv               # tylko za pierwszym razem
source .venv/bin/activate
pip install -r requirements.txt     # tylko za pierwszym razem
python generate_data.py
cd ..
```

Seeder wypisuje ziarno losowania, kroki 1–10 i liczbę rekordów w 24 tabelach. `TOTAL` wynosi ok. 17–21 tys. Linia „skipped … assignments” nie jest błędem: to przydziały pominięte, bo w strefach zabrakło miejsc.

## 4. Test poprawności danych

```bash
docker compose exec -T postgres psql -X -U projektowaniebazdanych -d ewidencja_czasu_pracy < generator/check_data.sql
```

Najpierw pojawia się liczba rekordów w tabelach, potem 21 testów (22 zapytania). Każdy test szuka błędnych wierszy, więc każde zapytanie ma zwrócić `(0 rows)`.

Szybka kontrola – wynik ma wynosić **22**:

```bash
docker compose exec -T postgres psql -X -U projektowaniebazdanych -d ewidencja_czasu_pracy < generator/check_data.sql | grep -c '(0 rows)'
```

## 5. Test „za każdym razem inne dane”

Uruchom seeder jeszcze raz (krok 3) i po każdym uruchomieniu wyświetl kilku pracowników:

```bash
docker compose exec -T postgres psql -U projektowaniebazdanych -d ewidencja_czasu_pracy -c 'SELECT first_name, last_name, work_email FROM work_time."Employee" ORDER BY employee_id LIMIT 5;'
```

Każde uruchomienie ma inne ziarno, inne nazwiska i nieco inną liczbę rekordów.

Opcjonalnie możesz sprawdzić powtarzalność: ustaw `SEED = 1234` w `generator/generate_data.py`, a dwa uruchomienia dadzą identyczne dane. **Przed oddaniem przywróć `SEED = None`.**

## Co pokazać prowadzącemu (zajęcia 4)

| Wymaganie | Jak to pokazać |
|---|---|
| kilkanaście tysięcy rekordów | `TOTAL` w podsumowaniu seedera; najwięcej rekordów mają `Registration`, `Assignment` i `Shift` |
| mniejsze tabele wprowadzone ręcznie | [`reference_data.py`](reference_data.py): role, uprawnienia, typy umów i nieobecności, stanowiska, święta |
| za każdym razem inne dane | dwa uruchomienia z kroku 5 |
| obsługa powiązań między encjami | baza przyjęła wszystkie wstawienia mimo kluczy obcych, a 21 testów z [`check_data.sql`](check_data.sql) sprawdza m.in. hierarchię, umowy, grafiki i strefy |
| biblioteka ORM | SQLAlchemy – klasy tabel w [`models.py`](models.py) |

## Gdy coś nie działa

| Komunikat | Co zrobić |
|---|---|
| `Could not find a .env file` | krok 1 |
| `Could not connect to the database` … `Connection refused` | kontener nie działa: `docker compose up -d --wait` |
| `password authentication failed` | hasło ustawia się tylko przy pierwszym utworzeniu bazy. Po zmianie hasła w `.env` uruchom `docker compose down -v` (kasuje dane) i zacznij od kroku 2 |
| `relation "work_time.Branch" does not exist` | brak schematu: krok 2 |
| `externally-managed-environment` przy `pip install` | venv nie jest aktywny: `source .venv/bin/activate` |
