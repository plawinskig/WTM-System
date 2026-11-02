-- Integrity constraint tests (chapter 8); run after sql/01_schema.sql OR after the migration.
-- Run with psql (uses \set and \echo); commands are in README.md.
-- All inserted rows are removed by ROLLBACK (IDENTITY sequences are not rolled back).
\set ON_ERROR_STOP on
\echo '=== 1. Overview of CHECK / FK / PK / UNIQUE constraints ==='
SELECT c.contype AS constraint_type, COUNT(*) AS constraint_count
FROM pg_constraint c
WHERE c.connamespace = 'work_time'::regnamespace
  AND c.contype IN ('c','f','p','u')
GROUP BY c.contype ORDER BY c.contype;

\echo '=== 2. Referential actions ON DELETE and ON UPDATE ==='
SELECT c.conrelid::regclass AS table_name, c.conname AS foreign_key,
       CASE c.confdeltype WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT'
                          WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL'
                          WHEN 'd' THEN 'SET DEFAULT' END AS on_delete,
       CASE c.confupdtype WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT'
                          WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL'
                          WHEN 'd' THEN 'SET DEFAULT' END AS on_update
FROM pg_constraint c
WHERE c.connamespace = 'work_time'::regnamespace AND c.contype = 'f'
ORDER BY c.conrelid::regclass::text, c.conname;

\echo '=== 3. Transactional tests: expect NOTICE messages starting with OK ==='
BEGIN;
SET LOCAL search_path TO work_time, public;

DO $$
DECLARE
    v_tag TEXT := 'integrity_test_' || txid_current()::TEXT;
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

    -- CHECK: positive capacity.
    BEGIN
        INSERT INTO "Zone" ("branch_id", "name", "capacity")
        VALUES (v_branch, v_tag || '_bledna', 0);
        RAISE EXCEPTION 'TEST FAILED: missing CHECK constraint on capacity';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: CHECK Zone.capacity > 0';
    END;

    -- CHECK: an employee cannot be their own manager.
    BEGIN
        UPDATE "Employee" SET "manager_id" = v_employee
        WHERE "employee_id" = v_employee;
        RAISE EXCEPTION 'TEST FAILED: employee accepted as their own manager';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: CHECK Employee.manager_id <> employee_id';
    END;

    -- SET NULL: deleting the manager keeps the employee row.
    DELETE FROM "Employee" WHERE "employee_id" = v_manager;
    SELECT COUNT(*) INTO v_counter FROM "Employee"
    WHERE "employee_id" = v_employee AND "manager_id" IS NULL;
    IF v_counter <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED: ON DELETE SET NULL was not applied';
    END IF;
    RAISE NOTICE 'OK: SET NULL after deleting the manager';

    -- Account and role setup.
    INSERT INTO "Account" ("employee_id", "login", "password_hash")
    VALUES (v_employee, v_tag, 'TEST_FAKE_HASH') RETURNING "account_id" INTO v_account;
    INSERT INTO "Role" ("role_name") VALUES (v_tag) RETURNING "role_id" INTO v_role;
    INSERT INTO "Permission" ("permission_name")
    VALUES (v_tag) RETURNING "permission_id" INTO v_permission;
    INSERT INTO "AccountRole" ("account_id", "role_id") VALUES (v_account, v_role);
    INSERT INTO "RolePermission" ("role_id", "permission_id") VALUES (v_role, v_permission);

    -- ON UPDATE CASCADE: changing the role PK updates both foreign keys.
    v_role_new := -v_role;
    IF EXISTS (SELECT 1 FROM "Role" WHERE "role_id" = v_role_new) THEN
        RAISE EXCEPTION 'Test requires an unused negative role_id';
    END IF;
    UPDATE "Role" SET "role_id" = v_role_new WHERE "role_id" = v_role;
    IF NOT EXISTS (SELECT 1 FROM "AccountRole"
                   WHERE "account_id" = v_account AND "role_id" = v_role_new)
       OR NOT EXISTS (SELECT 1 FROM "RolePermission"
                      WHERE "permission_id" = v_permission AND "role_id" = v_role_new) THEN
        RAISE EXCEPTION 'TEST FAILED: ON UPDATE CASCADE was not applied';
    END IF;
    RAISE NOTICE 'OK: ON UPDATE CASCADE updates AccountRole and RolePermission';

    -- ON DELETE CASCADE: deleting a role removes its links, not the account/permission.
    DELETE FROM "Role" WHERE "role_id" = v_role_new;
    IF EXISTS (SELECT 1 FROM "AccountRole" WHERE "account_id" = v_account)
       OR EXISTS (SELECT 1 FROM "RolePermission" WHERE "permission_id" = v_permission)
       OR NOT EXISTS (SELECT 1 FROM "Account" WHERE "account_id" = v_account)
       OR NOT EXISTS (SELECT 1 FROM "Permission" WHERE "permission_id" = v_permission) THEN
        RAISE EXCEPTION 'TEST FAILED: role cascade';
    END IF;
    RAISE NOTICE 'OK: ON DELETE CASCADE removes only the role links';

    INSERT INTO "DayOff" ("date", "name") VALUES (DATE '2037-01-01', v_tag)
    RETURNING "day_off_id" INTO v_dayoff;
    INSERT INTO "BranchDayOff" ("branch_id", "day_off_id") VALUES (v_branch, v_dayoff);
    DELETE FROM "DayOff" WHERE "day_off_id" = v_dayoff;
    IF EXISTS (SELECT 1 FROM "BranchDayOff" WHERE "branch_id" = v_branch) THEN
        RAISE EXCEPTION 'TEST FAILED: DayOff cascade';
    END IF;
    RAISE NOTICE 'OK: ON DELETE CASCADE removes BranchDayOff';

    -- CHECK on contracts; RESTRICT protects the employment history.
    INSERT INTO "Position" ("name") VALUES (v_tag) RETURNING "position_id" INTO v_position;
    INSERT INTO "ContractType" ("name") VALUES (v_tag) RETURNING "contract_type_id" INTO v_contract_type;
    BEGIN
        INSERT INTO "Contract" ("employee_id", "contract_type_id", "position_id",
                                "conclusion_date", "start_date", "employment_fraction")
        VALUES (v_employee, v_contract_type, v_position,
                DATE '2026-01-01', DATE '2026-01-01', 1.25);
        RAISE EXCEPTION 'TEST FAILED: employment fraction 1.25 accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: CHECK employment_fraction in (0,1]';
    END;
    INSERT INTO "Contract" ("employee_id", "contract_type_id", "position_id",
                            "conclusion_date", "start_date", "employment_fraction")
    VALUES (v_employee, v_contract_type, v_position,
            DATE '2026-01-01', DATE '2026-01-01', 1.00);
    BEGIN
        DELETE FROM "Employee" WHERE "employee_id" = v_employee;
        RAISE EXCEPTION 'TEST FAILED: employee with a contract was deleted';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'OK: ON DELETE RESTRICT protects an employee with a contract';
    END;

    -- CHECK on schedule and shift times, IDENTITY for Assignment, UNIQUE on the pair.
    BEGIN
        INSERT INTO "Schedule" ("department_id", "period_from", "period_to",
                                "version_number", "status")
        VALUES (v_department, DATE '2026-10-31', DATE '2026-10-01', 1, 'draft');
        RAISE EXCEPTION 'TEST FAILED: reversed schedule dates accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: CHECK on the schedule period';
    END;
    INSERT INTO "Schedule" ("department_id", "period_from", "period_to",
                            "version_number", "status")
    VALUES (v_department, DATE '2026-10-01', DATE '2026-10-31', 1, 'draft')
    RETURNING "schedule_id" INTO v_schedule;
    BEGIN
        INSERT INTO "Shift" ("schedule_id", "start_time", "end_time")
        VALUES (v_schedule, TIMESTAMP '2026-10-25 16:00', TIMESTAMP '2026-10-25 08:00');
        RAISE EXCEPTION 'TEST FAILED: reversed shift times accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: CHECK on the shift time order';
    END;
    INSERT INTO "Shift" ("schedule_id", "start_time", "end_time")
    VALUES (v_schedule, TIMESTAMP '2026-10-25 08:00', TIMESTAMP '2026-10-25 16:00')
    RETURNING "shift_id" INTO v_shift;
    INSERT INTO "Assignment" ("shift_id", "employee_id", "zone_id")
    VALUES (v_shift, v_employee, v_zone) RETURNING "assignment_id" INTO v_assignment;
    IF v_assignment IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: missing assignment_id';
    END IF;
    BEGIN
        INSERT INTO "Assignment" ("shift_id", "employee_id", "zone_id")
        VALUES (v_shift, v_employee, v_zone);
        RAISE EXCEPTION 'TEST FAILED: second assignment to the same shift accepted';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'OK: UNIQUE(shift_id, employee_id), PK=assignment_id';
    END;
    BEGIN
        INSERT INTO "Assignment" ("shift_id", "employee_id", "zone_id")
        VALUES (v_shift, -999999, v_zone);
        RAISE EXCEPTION 'TEST FAILED: missing FOREIGN KEY';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'OK: FK blocks an assignment of a non-existent employee';
    END;
    RAISE NOTICE 'OK: all tests passed (ROLLBACK removes the test data)';
END $$;
ROLLBACK;
\echo '=== End of tests. No test rows were left in the database. ==='
