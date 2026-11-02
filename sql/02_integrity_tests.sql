-- Testy dla skryptu z rozdzialu 8; uruchamiac po nowym DDL LUB po migracji.
-- Uruchomienie: psql -X -v ON_ERROR_STOP=1 -d ewidencja_czasu_pracy -f 04_testy_wiezow_integralnosci.sql
-- Wszystkie dodane rekordy sa usuwane przez ROLLBACK (IDENTITY/SEQUENCE nie jest cofany).
\set ON_ERROR_STOP on
\echo '=== 1. Przeglad ograniczen CHECK / FK / PK / UNIQUE ==='
SELECT c.contype AS typ, COUNT(*) AS liczba
FROM pg_constraint c
WHERE c.connamespace = 'work_time'::regnamespace
  AND c.contype IN ('c','f','p','u')
GROUP BY c.contype ORDER BY c.contype;

\echo '=== 2. Dzialania referencyjne ON DELETE i ON UPDATE ==='
SELECT c.conrelid::regclass AS tabela, c.conname AS klucz_obcy,
       CASE c.confdeltype WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT'
                          WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL'
                          WHEN 'd' THEN 'SET DEFAULT' END AS on_delete,
       CASE c.confupdtype WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT'
                          WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL'
                          WHEN 'd' THEN 'SET DEFAULT' END AS on_update
FROM pg_constraint c
WHERE c.connamespace = 'work_time'::regnamespace AND c.contype = 'f'
ORDER BY c.conrelid::regclass::text, c.conname;

\echo '=== 3. Testy transakcyjne: oczekiwane komunikaty NOTICE OK ==='
BEGIN;
SET LOCAL search_path TO work_time, public;

DO $$
DECLARE
    v_tag TEXT := 'test_integralnosc_' || txid_current()::TEXT;
    v_branch INT;
    v_department INT;
    v_team INT;
    v_zone INT;
    v_manager INT;
    v_employee INT;
    v_account INT;
    v_role INT;
    v_role_new INT;
    v_permission INT;
    v_dayoff INT;
    v_position INT;
    v_contract_type INT;
    v_schedule INT;
    v_shift INT;
    v_assignment INT;
    v_counter INT;
BEGIN
    INSERT INTO "Branch" ("name", "city", "address")
    VALUES (v_tag, 'Poznan', 'ul. Testowa 1') RETURNING "branch_id" INTO v_branch;

    INSERT INTO "Department" ("branch_id", "name")
    VALUES (v_branch, v_tag) RETURNING "department_id" INTO v_department;

    INSERT INTO "Team" ("department_id", "name")
    VALUES (v_department, v_tag) RETURNING "team_id" INTO v_team;

    INSERT INTO "Zone" ("branch_id", "name", "capacity")
    VALUES (v_branch, v_tag, 4) RETURNING "zone_id" INTO v_zone;

    INSERT INTO "Employee" ("first_name", "last_name", "team_id")
    VALUES ('Przelozony', 'Testowy', v_team) RETURNING "employee_id" INTO v_manager;

    INSERT INTO "Employee" ("first_name", "last_name", "team_id", "manager_id")
    VALUES ('Pracownik', 'Testowy', v_team, v_manager)
    RETURNING "employee_id" INTO v_employee;

    -- CHECK: dodatnia pojemnosc.
    BEGIN
        INSERT INTO "Zone" ("branch_id", "name", "capacity")
        VALUES (v_branch, v_tag || '_bledna', 0);
        RAISE EXCEPTION 'TEST NIEUDANY: brak ograniczenia CHECK pojemnosci';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: CHECK Zone.capacity > 0';
    END;

    -- CHECK: pracownik nie moze byc wlasnym przelozonym.
    BEGIN
        UPDATE "Employee" SET "manager_id" = v_employee
        WHERE "employee_id" = v_employee;
        RAISE EXCEPTION 'TEST NIEUDANY: samodzielne kierowanie soba dopuszczone';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: CHECK Employee.manager_id <> employee_id';
    END;

    -- SET NULL: po usunieciu przelozonego pracownik zachowuje rekord.
    DELETE FROM "Employee" WHERE "employee_id" = v_manager;
    SELECT COUNT(*) INTO v_counter FROM "Employee"
    WHERE "employee_id" = v_employee AND "manager_id" IS NULL;
    IF v_counter <> 1 THEN
        RAISE EXCEPTION 'TEST NIEUDANY: nie wykonano ON DELETE SET NULL';
    END IF;
    RAISE NOTICE 'OK: SET NULL po usunieciu przelozonego';

    -- Przygotowanie konta i ról.
    INSERT INTO "Account" ("employee_id", "login", "password_hash")
    VALUES (v_employee, v_tag, 'TEST_FAKE_HASH') RETURNING "account_id" INTO v_account;
    INSERT INTO "Role" ("role_name") VALUES (v_tag) RETURNING "role_id" INTO v_role;
    INSERT INTO "Permission" ("permission_name")
    VALUES (v_tag) RETURNING "permission_id" INTO v_permission;
    INSERT INTO "AccountRole" ("account_id", "role_id") VALUES (v_account, v_role);
    INSERT INTO "RolePermission" ("role_id", "permission_id") VALUES (v_role, v_permission);

    -- ON UPDATE CASCADE: zmiana PK roli przepina oba klucze obce.
    v_role_new := -v_role;
    IF EXISTS (SELECT 1 FROM "Role" WHERE "role_id" = v_role_new) THEN
        RAISE EXCEPTION 'Test wymaga wolnego ujemnego role_id';
    END IF;
    UPDATE "Role" SET "role_id" = v_role_new WHERE "role_id" = v_role;
    IF NOT EXISTS (SELECT 1 FROM "AccountRole"
                   WHERE "account_id" = v_account AND "role_id" = v_role_new)
       OR NOT EXISTS (SELECT 1 FROM "RolePermission"
                      WHERE "permission_id" = v_permission AND "role_id" = v_role_new) THEN
        RAISE EXCEPTION 'TEST NIEUDANY: nie wykonano ON UPDATE CASCADE';
    END IF;
    RAISE NOTICE 'OK: ON UPDATE CASCADE aktualizuje AccountRole i RolePermission';

    -- ON DELETE CASCADE: usuniecie roli usuwa jej wiazania, nie konto/uprawnienie.
    DELETE FROM "Role" WHERE "role_id" = v_role_new;
    IF EXISTS (SELECT 1 FROM "AccountRole" WHERE "account_id" = v_account)
       OR EXISTS (SELECT 1 FROM "RolePermission" WHERE "permission_id" = v_permission)
       OR NOT EXISTS (SELECT 1 FROM "Account" WHERE "account_id" = v_account)
       OR NOT EXISTS (SELECT 1 FROM "Permission" WHERE "permission_id" = v_permission) THEN
        RAISE EXCEPTION 'TEST NIEUDANY: kaskada dla roli';
    END IF;
    RAISE NOTICE 'OK: ON DELETE CASCADE usuwa same powiazania roli';

    INSERT INTO "DayOff" ("date", "name") VALUES (DATE '2037-01-01', v_tag)
    RETURNING "day_off_id" INTO v_dayoff;
    INSERT INTO "BranchDayOff" ("branch_id", "day_off_id") VALUES (v_branch, v_dayoff);
    DELETE FROM "DayOff" WHERE "day_off_id" = v_dayoff;
    IF EXISTS (SELECT 1 FROM "BranchDayOff" WHERE "branch_id" = v_branch) THEN
        RAISE EXCEPTION 'TEST NIEUDANY: kaskada dla Dnia Wolnego';
    END IF;
    RAISE NOTICE 'OK: ON DELETE CASCADE usuwa BranchDayOff';

    -- CHECK dla umowy, RESTRICT chroni historie zatrudnienia.
    INSERT INTO "Position" ("name") VALUES (v_tag) RETURNING "position_id" INTO v_position;
    INSERT INTO "ContractType" ("name") VALUES (v_tag) RETURNING "contract_type_id" INTO v_contract_type;
    BEGIN
        INSERT INTO "Contract" ("employee_id", "contract_type_id", "position_id",
                                "conclusion_date", "start_date", "employment_fraction")
        VALUES (v_employee, v_contract_type, v_position,
                DATE '2026-01-01', DATE '2026-01-01', 1.25);
        RAISE EXCEPTION 'TEST NIEUDANY: dopuszczono wymiar etatu 1.25';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: CHECK wymiar_etatu z przedzialu (0,1]';
    END;
    INSERT INTO "Contract" ("employee_id", "contract_type_id", "position_id",
                            "conclusion_date", "start_date", "employment_fraction")
    VALUES (v_employee, v_contract_type, v_position,
            DATE '2026-01-01', DATE '2026-01-01', 1.00);
    BEGIN
        DELETE FROM "Employee" WHERE "employee_id" = v_employee;
        RAISE EXCEPTION 'TEST NIEUDANY: usunieto pracownika z umowa';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'OK: ON DELETE RESTRICT chroni pracownika z umowa';
    END;

    -- CHECK grafiku i czasu zmiany, IDENTITY dla Assignment i UNIQUE na parze.
    BEGIN
        INSERT INTO "Schedule" ("department_id", "period_from", "period_to",
                                "version_number", "status")
        VALUES (v_department, DATE '2026-10-31', DATE '2026-10-01', 1, 'draft');
        RAISE EXCEPTION 'TEST NIEUDANY: odwrocona data grafiku';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: CHECK okresu grafiku';
    END;
    INSERT INTO "Schedule" ("department_id", "period_from", "period_to",
                            "version_number", "status")
    VALUES (v_department, DATE '2026-10-01', DATE '2026-10-31', 1, 'draft')
    RETURNING "schedule_id" INTO v_schedule;
    BEGIN
        INSERT INTO "Shift" ("schedule_id", "start_time", "end_time")
        VALUES (v_schedule, TIMESTAMP '2026-10-25 16:00', TIMESTAMP '2026-10-25 08:00');
        RAISE EXCEPTION 'TEST NIEUDANY: odwrocone godziny zmiany';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: CHECK poprawnej kolejnosci czasu zmiany';
    END;
    INSERT INTO "Shift" ("schedule_id", "start_time", "end_time")
    VALUES (v_schedule, TIMESTAMP '2026-10-25 08:00', TIMESTAMP '2026-10-25 16:00')
    RETURNING "shift_id" INTO v_shift;
    INSERT INTO "Assignment" ("shift_id", "employee_id", "zone_id")
    VALUES (v_shift, v_employee, v_zone) RETURNING "assignment_id" INTO v_assignment;
    IF v_assignment IS NULL THEN
        RAISE EXCEPTION 'TEST NIEUDANY: brak assignment_id';
    END IF;
    BEGIN
        INSERT INTO "Assignment" ("shift_id", "employee_id", "zone_id")
        VALUES (v_shift, v_employee, v_zone);
        RAISE EXCEPTION 'TEST NIEUDANY: dopuszczono drugi przydzial tej samej zmiany';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'OK: UNIQUE(shift_id, employee_id), PK=assignment_id';
    END;
    BEGIN
        INSERT INTO "Assignment" ("shift_id", "employee_id", "zone_id")
        VALUES (v_shift, -999999, v_zone);
        RAISE EXCEPTION 'TEST NIEUDANY: brak FOREIGN KEY';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'OK: FK blokuje przydzial nieistniejacego pracownika';
    END;
    RAISE NOTICE 'OK: zakonczono testy poprawnie (ROLLBACK usunie dane testowe)';
END $$;
ROLLBACK;
\echo '=== Koniec testow. W bazie nie pozostawiono rekordow testowych. ==='
