# WTM-System – ewidencja czasu pracy

Projekt z przedmiotu „Projektowanie baz danych”: relacyjna baza danych systemu zarządzania czasem pracy pracowników (PostgreSQL 17, baza `ewidencja_czasu_pracy`, schemat `work_time`, 24 tabele) oraz generator danych testowych w Pythonie.

## Struktura repozytorium

| Ścieżka | Zawartość |
|---|---|
| `docs/` | dokumentacja projektu: rozdziały 1–5 (`project_chapters_1-5.pdf`), rozdziały 6–8 (`project_chapters_6-8.docx` i `.pdf`), diagram relacji (`relational_diagram.png`), wymagania prowadzącego (`course_requirements.pdf`) |
| `sql/` | schemat bazy, testy więzów integralności, migracja starszej wersji schematu |
| `sql/archive/` | schemat i testy sprzed rozdziału 8 – punkt wyjścia dla migracji |
| `generator/` | generator danych (SQLAlchemy + Faker) i testy poprawności danych – [opis](generator/README.md) |
| `compose.yaml`, `.env.example` | PostgreSQL w Dockerze |

## Szybki start

Potrzebny jest Docker z Compose. Lokalny klient `psql` nie jest wymagany – poniższe polecenia uruchamiają go w kontenerze.

1. Skopiuj `.env.example` do `.env` i ustaw w nim hasło:
   ```bash
   cp .env.example .env
   ```
2. Uruchom bazę (nasłuchuje tylko na `127.0.0.1:55432`):
   ```bash
   docker compose up -d --wait
   ```
3. Utwórz schemat:
   ```bash
   docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U projektowaniebazdanych -d ewidencja_czasu_pracy < sql/01_schema.sql
   ```
4. Opcjonalnie sprawdź więzy integralności – to samo polecenie z plikiem `sql/02_integrity_tests.sql`. Każdy test wypisuje `NOTICE:  OK: …`, a dane testowe są na końcu wycofywane.
5. Wypełnij bazę danymi – zob. [generator/README.md](generator/README.md).

Z lokalnym klientem `psql` zamiast `docker compose exec`:

```bash
psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 55432 -U projektowaniebazdanych -d ewidencja_czasu_pracy -f sql/01_schema.sql
```

Schemat tworzy się na pustej bazie. Aby utworzyć go od nowa, najpierw usuń stary (to usuwa wszystkie dane):

```sql
DROP SCHEMA IF EXISTS work_time CASCADE;
```

## Skrypty SQL

| Plik | Kiedy uruchamiać |
|---|---|
| `sql/01_schema.sql` | na pustej bazie – pełny schemat z kluczami, ograniczeniami `CHECK`, akcjami referencyjnymi i indeksami |
| `sql/02_integrity_tests.sql` | po `01_schema.sql` albo po migracji – testy `CHECK`, kluczy obcych i kaskad w transakcji zakończonej `ROLLBACK`. Wymaga `psql` (używa `\set` i `\echo`); w pgAdmin pomiń linie zaczynające się od `\` |
| `sql/migrate_integrity_constraints.sql` | tylko na bazie utworzonej z `sql/archive/schema_before_migration.sql` – dodaje akcje referencyjne bez utraty danych. Na bazie z `01_schema.sql` nie jest potrzebna |
| `sql/archive/` | `schema_before_migration.sql` i `tests_before_migration.sql` – stan sprzed rozdziału 8 |

Schemat ma 24 tabele, 31 kluczy obcych i 16 ograniczeń `CHECK`. Akcje referencyjne: 6 × `ON DELETE CASCADE` (tabele łącznikowe), 1 × `ON DELETE SET NULL` (`Employee.manager_id`), 3 × `ON DELETE RESTRICT` (dane historyczne pracownika); pozostałe klucze obce mają domyślne `NO ACTION`.

## Nazwy plików w dokumentacji

Dokumentacja w `docs/` powstała przed uporządkowaniem repozytorium i używa dawnych nazw plików:

| W dokumentacji | W repozytorium |
|---|---|
| `Bazy projekt-2.pdf` | `docs/project_chapters_1-5.pdf` |
| `baza_postgresql_z_integralnoscia.sql` | `sql/01_schema.sql` |
| `04_testy_wiezow_integralnosci.sql` | `sql/02_integrity_tests.sql` |
| `03_migracja_wiezow_integralnosci.sql` | `sql/migrate_integrity_constraints.sql` |
| `01_schema_postgresql.sql`, `baza_postgresql.sql` | `sql/archive/schema_before_migration.sql` |
| `02_weryfikacja_i_testy.sql` | `sql/archive/tests_before_migration.sql` |

Polecenia z rozdziału 7 zakładają lokalnego użytkownika `postgres`. W kontenerze z `compose.yaml` użytkownikiem jest `projektowaniebazdanych` – zob. „Szybki start”.
