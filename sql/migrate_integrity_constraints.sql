BEGIN;
SET LOCAL search_path TO work_time, public;

ALTER TABLE "AccountRole"
    DROP CONSTRAINT IF EXISTS "AccountRole_account_id_fkey",
    DROP CONSTRAINT IF EXISTS "fk_accountrole_account",
    ADD CONSTRAINT "fk_accountrole_account"
    FOREIGN KEY ("account_id") REFERENCES "Account" ("account_id")
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "AccountRole"
    DROP CONSTRAINT IF EXISTS "AccountRole_role_id_fkey",
    DROP CONSTRAINT IF EXISTS "fk_accountrole_role",
    ADD CONSTRAINT "fk_accountrole_role"
    FOREIGN KEY ("role_id") REFERENCES "Role" ("role_id")
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "RolePermission"
    DROP CONSTRAINT IF EXISTS "RolePermission_role_id_fkey",
    DROP CONSTRAINT IF EXISTS "fk_rolepermission_role",
    ADD CONSTRAINT "fk_rolepermission_role"
    FOREIGN KEY ("role_id") REFERENCES "Role" ("role_id")
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "RolePermission"
    DROP CONSTRAINT IF EXISTS "RolePermission_permission_id_fkey",
    DROP CONSTRAINT IF EXISTS "fk_rolepermission_permission",
    ADD CONSTRAINT "fk_rolepermission_permission"
    FOREIGN KEY ("permission_id") REFERENCES "Permission" ("permission_id")
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "BranchDayOff"
    DROP CONSTRAINT IF EXISTS "BranchDayOff_branch_id_fkey",
    DROP CONSTRAINT IF EXISTS "fk_branchdayoff_branch",
    ADD CONSTRAINT "fk_branchdayoff_branch"
    FOREIGN KEY ("branch_id") REFERENCES "Branch" ("branch_id")
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "BranchDayOff"
    DROP CONSTRAINT IF EXISTS "BranchDayOff_day_off_id_fkey",
    DROP CONSTRAINT IF EXISTS "fk_branchdayoff_dayoff",
    ADD CONSTRAINT "fk_branchdayoff_dayoff"
    FOREIGN KEY ("day_off_id") REFERENCES "DayOff" ("day_off_id")
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "Employee"
    DROP CONSTRAINT IF EXISTS "Employee_manager_id_fkey",
    DROP CONSTRAINT IF EXISTS "fk_employee_manager",
    ADD CONSTRAINT "fk_employee_manager"
    FOREIGN KEY ("manager_id") REFERENCES "Employee" ("employee_id")
    ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE "Contract"
    DROP CONSTRAINT IF EXISTS "Contract_employee_id_fkey",
    DROP CONSTRAINT IF EXISTS "fk_contract_employee",
    ADD CONSTRAINT "fk_contract_employee"
    FOREIGN KEY ("employee_id") REFERENCES "Employee" ("employee_id")
    ON DELETE RESTRICT ON UPDATE NO ACTION;

ALTER TABLE "Assignment"
    DROP CONSTRAINT IF EXISTS "Assignment_employee_id_fkey",
    DROP CONSTRAINT IF EXISTS "fk_assignment_employee",
    ADD CONSTRAINT "fk_assignment_employee"
    FOREIGN KEY ("employee_id") REFERENCES "Employee" ("employee_id")
    ON DELETE RESTRICT ON UPDATE NO ACTION;

ALTER TABLE "Registration"
    DROP CONSTRAINT IF EXISTS "Registration_employee_id_fkey",
    DROP CONSTRAINT IF EXISTS "fk_registration_employee",
    ADD CONSTRAINT "fk_registration_employee"
    FOREIGN KEY ("employee_id") REFERENCES "Employee" ("employee_id")
    ON DELETE RESTRICT ON UPDATE NO ACTION;

COMMIT;
