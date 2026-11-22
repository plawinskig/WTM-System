-- Performance indexes (class 6). Choice and EXPLAIN before/after: sql/EXPLAIN.md.
-- Run after the generator has filled the tables. The generator empties the tables
-- with TRUNCATE, which keeps the indexes, so they survive a new data generation.
BEGIN;
SET LOCAL search_path TO work_time, public;

-- PostgreSQL does not index foreign-key columns on its own. The reports look up
-- "all rows of one employee / one schedule / one team" in correlated subqueries,
-- which without these indexes means a sequential scan per outer row.
-- uq_assignment_shift_employee cannot serve employee_id lookups: employee_id is its
-- second column and a B-tree is searched from the first one.
CREATE INDEX IF NOT EXISTS "ix_assignment_employee"   ON "Assignment"   ("employee_id"); -- queries 8, 9, 10
CREATE INDEX IF NOT EXISTS "ix_absence_employee"      ON "Absence"      ("employee_id"); -- query 8
CREATE INDEX IF NOT EXISTS "ix_availability_employee" ON "Availability" ("employee_id"); -- query 8
CREATE INDEX IF NOT EXISTS "ix_employee_team"         ON "Employee"     ("team_id");     -- queries 3, 8, 9
CREATE INDEX IF NOT EXISTS "ix_shift_schedule"        ON "Shift"        ("schedule_id"); -- queries 8, 9

-- Speeds up query 10 (one employee's registrations), but query 15 also picks it to
-- read the whole table in employee order and gets slower: see sql/EXPLAIN.md, 3.3.
CREATE INDEX IF NOT EXISTS "ix_registration_employee" ON "Registration" ("employee_id");

-- Multicolumn: contracts of one employee that started by a given day,
-- both conditions answered by the index.
CREATE INDEX IF NOT EXISTS "ix_contract_employee_start"
    ON "Contract" ("employee_id", "start_date"); -- queries 3, 8

-- Range filter on the shift start: one day or one month written as
-- start_time >= :from AND start_time < :to.
CREATE INDEX IF NOT EXISTS "ix_shift_start_time" ON "Shift" ("start_time"); -- queries 7, 8, 11, 18

-- Partial and covering: only the ~11% of registrations still waiting for verification,
-- with every column query 16 needs, so it can be answered by an Index Only Scan.
CREATE INDEX IF NOT EXISTS "ix_registration_pending"
    ON "Registration" ("employee_id")
    INCLUDE ("verification_status", "event_time")
    WHERE "verification_status" IN ('unverified', 'needs_explanation'); -- query 16

COMMIT;
