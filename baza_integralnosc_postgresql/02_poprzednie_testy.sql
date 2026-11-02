-- Uruchomienie PO 01_schema_postgresql.sql
-- psql -X -v ON_ERROR_STOP=1 -d ewidencja_czasu_pracy -f 02_weryfikacja_i_testy.sql
-- Wyniki inspekcji katalogu pozostaja w bazie, dane testowe sa wycofywane.
\set ON_ERROR_STOP on
\echo '=== 1. Liczba tabel (oczekiwane: 24) ==='
SELECT COUNT(*) AS liczba_tabel
FROM information_schema.tables
WHERE table_schema = 'work_time' AND table_type = 'BASE TABLE';

\echo '=== 2. Klucze glowne i obce ==='
SELECT constraint_type, COUNT(*) AS liczba
FROM information_schema.table_constraints
WHERE table_schema = 'work_time'
  AND constraint_type IN ('PRIMARY KEY', 'FOREIGN KEY', 'UNIQUE', 'CHECK')
GROUP BY constraint_type
ORDER BY constraint_type;

\echo '=== 3. Klucz glowny Assignment (oczekiwane: assignment_id) ==='
SELECT kcu.column_name, kcu.ordinal_position
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_schema = kcu.constraint_schema
 AND tc.constraint_name = kcu.constraint_name
WHERE tc.table_schema = 'work_time'
  AND tc.table_name = 'Assignment'
  AND tc.constraint_type = 'PRIMARY KEY'
ORDER BY kcu.ordinal_position;

\echo '=== 4. Testy transakcyjne z przykladowymi danymi ==='
BEGIN;
SET LOCAL search_path TO work_time, public;

INSERT INTO "Branch" ("name", "city", "address")
VALUES ('Oddzial testowy', 'Poznan', 'ul. Przykladowa 1');
INSERT INTO "Department" ("branch_id", "name")
SELECT "branch_id", 'Produkcja' FROM "Branch" WHERE "name"='Oddzial testowy';
INSERT INTO "Team" ("department_id", "name")
SELECT "department_id", 'Zespol A' FROM "Department" WHERE "name"='Produkcja';
INSERT INTO "Zone" ("branch_id", "name", "capacity")
SELECT "branch_id", 'Hala A', 10 FROM "Branch" WHERE "name"='Oddzial testowy';
INSERT INTO "Position" ("name") VALUES ('Operator testowy');
INSERT INTO "ContractType" ("name") VALUES ('Umowa o prace - test');
INSERT INTO "Role" ("role_name") VALUES ('Kierownik - test');
INSERT INTO "Permission" ("permission_name") VALUES ('schedule.read.test');
INSERT INTO "Employee" ("first_name", "last_name", "team_id", "work_email")
SELECT 'Jan', 'Testowy', "team_id", 'jan.testowy@example.invalid'
FROM "Team" WHERE "name"='Zespol A';
INSERT INTO "Account" ("employee_id", "login", "password_hash")
SELECT "employee_id", 'jtest', 'TEST_ONLY_NOT_A_REAL_HASH'
FROM "Employee" WHERE "work_email"='jan.testowy@example.invalid';
INSERT INTO "AccountRole" ("account_id", "role_id")
SELECT a."account_id", r."role_id" FROM "Account" a CROSS JOIN "Role" r
WHERE a."login"='jtest' AND r."role_name"='Kierownik - test';
INSERT INTO "RolePermission" ("role_id", "permission_id")
SELECT r."role_id", p."permission_id" FROM "Role" r CROSS JOIN "Permission" p
WHERE r."role_name"='Kierownik - test' AND p."permission_name"='schedule.read.test';
INSERT INTO "Contract" ("employee_id", "contract_type_id", "position_id", "conclusion_date", "start_date", "employment_fraction")
SELECT e."employee_id", c."contract_type_id", p."position_id", DATE '2026-01-01', DATE '2026-01-01', 1.00
FROM "Employee" e CROSS JOIN "ContractType" c CROSS JOIN "Position" p
WHERE e."work_email"='jan.testowy@example.invalid'
  AND c."name"='Umowa o prace - test' AND p."name"='Operator testowy';
INSERT INTO "Schedule" ("department_id", "period_from", "period_to", "version_number", "status")
SELECT "department_id", DATE '2026-10-01', DATE '2026-10-31', 1, 'draft'
FROM "Department" WHERE "name"='Produkcja';
INSERT INTO "Shift" ("schedule_id", "start_time", "end_time")
SELECT "schedule_id", TIMESTAMP '2026-10-25 08:00:00', TIMESTAMP '2026-10-25 16:00:00'
FROM "Schedule" WHERE "version_number"=1 AND "status"='draft';
INSERT INTO "Assignment" ("shift_id", "employee_id", "zone_id")
SELECT s."shift_id", e."employee_id", z."zone_id"
FROM "Shift" s CROSS JOIN "Employee" e CROSS JOIN "Zone" z
WHERE e."work_email"='jan.testowy@example.invalid' AND z."name"='Hala A';

-- Nowo dodany przydzial musi miec automatycznie nadany assignment_id.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM "Assignment"
        WHERE "assignment_id" IS NOT NULL AND "assignment_id" > 0
    ) THEN
        RAISE EXCEPTION 'TEST NIEUDANY: brak automatycznego assignment_id';
    END IF;
    RAISE NOTICE 'OK: przydzial otrzymal assignment_id';
END $$;

-- Kazdy niepoprawny INSERT musi zostac odrzucony przez silnik.
DO $$
DECLARE employee_key INTEGER;
DECLARE shift_key INTEGER;
DECLARE zone_key INTEGER;
BEGIN
    SELECT "employee_id" INTO employee_key FROM "Employee" WHERE "work_email"='jan.testowy@example.invalid';
    SELECT "shift_id" INTO shift_key FROM "Shift" LIMIT 1;
    SELECT "zone_id" INTO zone_key FROM "Zone" WHERE "name"='Hala A';

    BEGIN
        INSERT INTO "Assignment" ("shift_id", "employee_id", "zone_id")
        VALUES (shift_key, employee_key, zone_key);
        RAISE EXCEPTION 'TEST NIEUDANY: dopuszczono duplikat Assignment';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'OK: UNIQUE(shift_id, employee_id) blokuje duplikat';
    END;

    BEGIN
        INSERT INTO "Zone" ("branch_id", "name", "capacity")
        SELECT "branch_id", 'Zla strefa', 0 FROM "Branch" WHERE "name"='Oddzial testowy';
        RAISE EXCEPTION 'TEST NIEUDANY: dopuszczono pojemnosc 0';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: CHECK blokuje pojemnosc 0';
    END;

    BEGIN
        INSERT INTO "Assignment" ("shift_id", "employee_id", "zone_id")
        VALUES (shift_key, -999999, zone_key);
        RAISE EXCEPTION 'TEST NIEUDANY: dopuszczono brakujacego pracownika';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'OK: FK blokuje nieistniejacego pracownika';
    END;
END $$;

SELECT a."assignment_id", e."first_name", e."last_name", sh."start_time", sh."end_time", z."name" AS strefa
FROM "Assignment" a
JOIN "Employee" e ON e."employee_id"=a."employee_id"
JOIN "Shift" sh ON sh."shift_id"=a."shift_id"
JOIN "Zone" z ON z."zone_id"=a."zone_id";

ROLLBACK;
\echo '=== 5. Liczba tabel po wycofaniu testow (oczekiwane: 24) ==='
SELECT COUNT(*) AS liczba_tabel
FROM information_schema.tables
WHERE table_schema='work_time' AND table_type='BASE TABLE';
