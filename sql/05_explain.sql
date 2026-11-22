-- EXPLAIN of selected report queries (class 6). Run this file before and after
-- sql/04_indexes.sql and compare the plans; the analysis is in sql/EXPLAIN.md.
-- Query texts are copied verbatim from "sql/03_reports copy.sql" (same numbering).
-- Run ANALYZE once before the first run, not in this file: ANALYZE samples rows at
-- random, so re-running it between "before" and "after" can change plans by itself.
\set ON_ERROR_STOP on
SET search_path TO work_time, public;

\echo '=== Query 7: zone utilisation in the current month ==='
EXPLAIN (ANALYZE, BUFFERS)
WITH params AS (
    SELECT date_trunc('month', LOCALTIMESTAMP) AS period_from,
           date_trunc('month', LOCALTIMESTAMP) + INTERVAL '1 month' AS period_to
),
zone_slots AS (
    SELECT assignment.zone_id, shift.start_time, COUNT(*) AS people_count
    FROM "Assignment" assignment
    JOIN "Shift" shift  ON shift.shift_id = assignment.shift_id
    JOIN "Schedule" sch ON sch.schedule_id = shift.schedule_id
    CROSS JOIN params
    WHERE sch.status = 'published'
      AND shift.start_time >= params.period_from
      AND shift.start_time < params.period_to
    GROUP BY assignment.zone_id, shift.start_time
)
SELECT branch.name AS branch,
       zone.name AS zone,
       zone.capacity,
       COUNT(zs.start_time) AS used_slots,
       ROUND(AVG(zs.people_count), 1) AS avg_people,
       MAX(zs.people_count) AS max_people,
       ROUND(100.0 * AVG(zs.people_count) / zone.capacity, 1) AS avg_utilisation_pct,
       COUNT(*) FILTER (WHERE zs.people_count = zone.capacity) AS full_slots
FROM "Zone" zone
JOIN "Branch" branch ON branch.branch_id = zone.branch_id
LEFT JOIN zone_slots zs ON zs.zone_id = zone.zone_id
GROUP BY branch.name, zone.zone_id, zone.name, zone.capacity
ORDER BY avg_utilisation_pct DESC NULLS LAST, branch.name, zone.name;

\echo '=== Query 8: can an employee of the department be assigned on a given day ==='
EXPLAIN (ANALYZE, BUFFERS)
WITH params AS (
    SELECT department.department_id,
           (SELECT MIN(CAST(shift.start_time AS DATE))
            FROM "Shift" shift
            JOIN "Schedule" sch ON sch.schedule_id = shift.schedule_id
            WHERE sch.department_id = department.department_id
              AND sch.status <> 'archived'
              AND shift.start_time >= CAST(LOCALTIMESTAMP AS DATE) + 1) AS check_date
    FROM "Department" department
    WHERE department.department_id = (
            SELECT team.department_id
            FROM "Employee" employee
            JOIN "Team" team ON team.team_id = employee.team_id
            WHERE employee.archived = FALSE
            GROUP BY team.department_id
            ORDER BY COUNT(*) DESC, team.department_id
            LIMIT 1)
),
employee_facts AS (
    SELECT employee.employee_id,
           EXISTS (
               SELECT 1
               FROM "Contract" contract
               WHERE contract.employee_id = employee.employee_id
                 AND contract.start_date <= params.check_date
                 AND (contract.end_date IS NULL OR contract.end_date >= params.check_date)) AS has_contract,
           (SELECT abt.name
            FROM "Absence" ab
            JOIN "AbsenceType" abt ON abt.absence_type_id = ab.absence_type_id
            WHERE ab.employee_id = employee.employee_id
              AND ab.status = 'registered'
              AND params.check_date BETWEEN ab.start_date AND ab.end_date
            LIMIT 1) AS absence_type,
           EXISTS (
               SELECT 1
               FROM "Availability" av
               WHERE av.employee_id = employee.employee_id
                 AND av.available = FALSE
                 AND av.available_from < params.check_date + 1
                 AND av.available_to > params.check_date) AS declared_unavailable,
           EXISTS (
               SELECT 1
               FROM "Availability" av
               WHERE av.employee_id = employee.employee_id
                 AND av.available = TRUE
                 AND av.available_from < params.check_date + 1
                 AND av.available_to > params.check_date) AS declared_available,
           (SELECT to_char(shift.start_time, 'HH24:MI') || '-' || to_char(shift.end_time, 'HH24:MI')
            FROM "Assignment" assignment
            JOIN "Shift" shift  ON shift.shift_id = assignment.shift_id
            JOIN "Schedule" sch ON sch.schedule_id = shift.schedule_id
            WHERE assignment.employee_id = employee.employee_id
              AND sch.status <> 'archived'
              AND shift.start_time >= params.check_date
              AND shift.start_time < params.check_date + 1
            LIMIT 1) AS assigned_shift
    FROM "Employee" employee
    JOIN "Team" team ON team.team_id = employee.team_id
    JOIN params      ON params.department_id = team.department_id
    WHERE employee.archived = FALSE
)
SELECT department.name AS department,
       params.check_date,
       employee.first_name || ' ' || employee.last_name AS employee,
       CASE WHEN NOT ef.has_contract THEN 'no_contract'
            WHEN ef.absence_type IS NOT NULL THEN 'absent: ' || ef.absence_type
            WHEN ef.declared_unavailable THEN 'declared_unavailable'
            WHEN ef.assigned_shift IS NOT NULL THEN 'already_assigned ' || ef.assigned_shift
            WHEN ef.declared_available THEN 'declared_available'
            ELSE 'no_declaration' END AS assignment_status
FROM employee_facts ef
CROSS JOIN params
JOIN "Employee" employee     ON employee.employee_id = ef.employee_id
JOIN "Department" department ON department.department_id = params.department_id
ORDER BY assignment_status, employee;

\echo '=== Query 9: readiness of the draft schedules for next month ==='
EXPLAIN (ANALYZE, BUFFERS)
WITH shift_staffing AS (
    SELECT shift.schedule_id, shift.shift_id, COUNT(assignment.assignment_id) AS staff_count
    FROM "Shift" shift
    JOIN "Schedule" sch ON sch.schedule_id = shift.schedule_id
    LEFT JOIN "Assignment" assignment ON assignment.shift_id = shift.shift_id
    WHERE sch.status = 'draft'
    GROUP BY shift.schedule_id, shift.shift_id
)
SELECT branch.name AS branch,
       department.name AS department,
       sch.period_from,
       sch.version_number,
       COUNT(*) AS shift_count,
       COUNT(*) FILTER (WHERE ss.staff_count = 0) AS unstaffed_shifts,
       MIN(ss.staff_count) AS min_staff,
       ROUND(AVG(ss.staff_count), 1) AS avg_staff,
       MAX(ss.staff_count) AS max_staff,
       (SELECT COUNT(*)
        FROM "Employee" employee
        JOIN "Team" team ON team.team_id = employee.team_id
        WHERE team.department_id = department.department_id
          AND employee.archived = FALSE
          AND NOT EXISTS (
                SELECT 1
                FROM "Assignment" assignment
                JOIN "Shift" shift ON shift.shift_id = assignment.shift_id
                WHERE shift.schedule_id = sch.schedule_id
                  AND assignment.employee_id = employee.employee_id)) AS employees_without_shifts
FROM shift_staffing ss
JOIN "Schedule" sch          ON sch.schedule_id = ss.schedule_id
JOIN "Department" department ON department.department_id = sch.department_id
JOIN "Branch" branch         ON branch.branch_id = department.branch_id
GROUP BY branch.name, department.department_id, department.name, sch.schedule_id, sch.period_from, sch.version_number
ORDER BY unstaffed_shifts DESC, branch.name, department.name;

\echo '=== Query 10: time card of one employee for the previous month ==='
EXPLAIN (ANALYZE, BUFFERS)
WITH params AS (
    SELECT (SELECT registration.employee_id
            FROM "Registration" registration
            GROUP BY registration.employee_id
            ORDER BY COUNT(*) DESC, registration.employee_id
            LIMIT 1) AS employee_id,
           date_trunc('month', LOCALTIMESTAMP) - INTERVAL '1 month' AS period_from,
           date_trunc('month', LOCALTIMESTAMP) AS period_to,
           INTERVAL '15 minutes' AS paid_break,
           INTERVAL '10 minutes' AS late_tolerance
),
shift_events AS (
    SELECT registration.shift_id,
           MIN(registration.event_time) FILTER (WHERE registration.event_type = 'work_start') AS work_start,
           MAX(registration.event_time) FILTER (WHERE registration.event_type = 'work_end') AS work_end,
           MIN(registration.event_time) FILTER (WHERE registration.event_type = 'break_start') AS break_start,
           MAX(registration.event_time) FILTER (WHERE registration.event_type = 'break_end') AS break_end,
           CASE WHEN bool_or(registration.verification_status = 'needs_explanation') THEN 'needs_explanation'
                WHEN bool_or(registration.verification_status = 'unverified') THEN 'unverified'
                ELSE 'valid' END AS verification_status
    FROM "Registration" registration
    JOIN params ON params.employee_id = registration.employee_id
    GROUP BY registration.shift_id
)
SELECT employee.first_name || ' ' || employee.last_name AS employee,
       CAST(shift.start_time AS DATE) AS work_date,
       to_char(shift.start_time, 'HH24:MI') || '-' || to_char(shift.end_time, 'HH24:MI') AS planned_shift,
       to_char(se.work_start, 'HH24:MI') AS clock_in,
       to_char(se.work_end, 'HH24:MI') AS clock_out,
       COALESCE(ROUND(EXTRACT(EPOCH FROM se.break_end - se.break_start) / 60), 0) AS break_minutes,
       ROUND(EXTRACT(EPOCH FROM
           (se.work_end - se.work_start)
           - GREATEST(COALESCE(se.break_end - se.break_start, INTERVAL '0') - params.paid_break,
                      INTERVAL '0')) / 3600, 2) AS worked_hours,
       CASE WHEN se.work_start > shift.start_time + params.late_tolerance
            THEN ROUND(EXTRACT(EPOCH FROM se.work_start - shift.start_time) / 60) END AS minutes_late,
       se.verification_status
FROM params
JOIN "Employee" employee     ON employee.employee_id = params.employee_id
JOIN "Assignment" assignment ON assignment.employee_id = params.employee_id
JOIN "Shift" shift           ON shift.shift_id = assignment.shift_id
JOIN "Schedule" sch          ON sch.schedule_id = shift.schedule_id
LEFT JOIN shift_events se ON se.shift_id = shift.shift_id
WHERE sch.status = 'published'
  AND shift.start_time >= params.period_from
  AND shift.start_time < params.period_to
ORDER BY shift.start_time;

\echo '=== Query 14: clock-in and clock-out deviation histogram (reads most of Registration) ==='
EXPLAIN (ANALYZE, BUFFERS)
WITH params AS (
    SELECT LOCALTIMESTAMP - INTERVAL '90 days' AS period_from,
           LOCALTIMESTAMP AS period_to
),
deviations AS (
    SELECT registration.event_type,
           FLOOR(EXTRACT(EPOCH FROM
               CASE WHEN registration.event_type = 'work_start' THEN registration.event_time - shift.start_time
                    ELSE registration.event_time - shift.end_time END) / 300) * 5 AS bucket_from
    FROM "Registration" registration
    JOIN "Shift" shift ON shift.shift_id = registration.shift_id
    CROSS JOIN params
    WHERE registration.event_type IN ('work_start', 'work_end')
      AND shift.start_time >= params.period_from
      AND shift.start_time < params.period_to
)
SELECT '[' || bucket_from || ', ' || (bucket_from + 5) || ') min' AS deviation_range,
       COUNT(*) FILTER (WHERE event_type = 'work_start') AS clock_ins,
       ROUND(100.0 * COUNT(*) FILTER (WHERE event_type = 'work_start')
             / (SELECT COUNT(*) FROM deviations WHERE event_type = 'work_start'), 1) AS clock_ins_pct,
       COUNT(*) FILTER (WHERE event_type = 'work_end') AS clock_outs,
       ROUND(100.0 * COUNT(*) FILTER (WHERE event_type = 'work_end')
             / (SELECT COUNT(*) FROM deviations WHERE event_type = 'work_end'), 1) AS clock_outs_pct
FROM deviations
GROUP BY bucket_from
ORDER BY bucket_from;

\echo '=== Query 15: correctness of registration event sequences (an index makes it slower) ==='
EXPLAIN (ANALYZE, BUFFERS)
WITH params AS (
    SELECT INTERVAL '1 hour' AS clock_out_grace
),
sequences AS (
    SELECT registration.employee_id,
           registration.shift_id,
           MAX(shift.end_time) AS shift_end,
           string_agg(registration.event_type, ' > ' ORDER BY registration.event_time) AS event_sequence
    FROM "Registration" registration
    JOIN "Shift" shift ON shift.shift_id = registration.shift_id
    GROUP BY registration.employee_id, registration.shift_id
)
SELECT sq.event_sequence,
       CASE WHEN sq.event_sequence IN ('work_start > work_end',
                                       'work_start > break_start > break_end > work_end')
                THEN 'complete'
            WHEN sq.shift_end > LOCALTIMESTAMP - params.clock_out_grace THEN 'shift_in_progress'
            ELSE 'invalid' END AS sequence_status,
       COUNT(*) AS shift_count,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM sequences), 2) AS share_pct,
       MAX(sq.shift_end) AS latest_shift_end
FROM sequences sq
CROSS JOIN params
GROUP BY sq.event_sequence, sequence_status
ORDER BY shift_count DESC;

\echo '=== Query 16: verification queue by manager ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT manager.first_name || ' ' || manager.last_name AS manager,
       mt.name AS manager_team,
       COUNT(*) FILTER (WHERE registration.verification_status = 'needs_explanation') AS needs_explanation,
       COUNT(*) FILTER (WHERE registration.verification_status = 'unverified') AS unverified,
       COUNT(DISTINCT registration.employee_id) AS employees,
       MIN(registration.event_time) AS oldest_pending_event,
       CURRENT_DATE - CAST(MIN(registration.event_time) AS DATE) AS days_waiting
FROM "Registration" registration
JOIN "Employee" employee     ON employee.employee_id = registration.employee_id
LEFT JOIN "Employee" manager ON manager.employee_id = employee.manager_id
LEFT JOIN "Team" mt          ON mt.team_id = manager.team_id
WHERE registration.verification_status IN ('unverified', 'needs_explanation')
GROUP BY manager.employee_id, manager.first_name, manager.last_name, mt.name
ORDER BY needs_explanation DESC, days_waiting DESC, manager;

-- Alternative formulations: the same result written differently.

\echo '=== Variant A1: one day as a function of the column (an index on start_time cannot be used) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*) AS shifts_tomorrow
FROM "Shift" shift
WHERE CAST(shift.start_time AS DATE) = CURRENT_DATE + 1;

\echo '=== Variant A2: the same day as a range on the bare column (an index on start_time can be used) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*) AS shifts_tomorrow
FROM "Shift" shift
WHERE shift.start_time >= CURRENT_DATE + 1
  AND shift.start_time < CURRENT_DATE + 2;

\echo '=== Variant B: query 14 with window sums instead of two subqueries over the CTE ==='
EXPLAIN (ANALYZE, BUFFERS)
WITH params AS (
    SELECT LOCALTIMESTAMP - INTERVAL '90 days' AS period_from,
           LOCALTIMESTAMP AS period_to
),
deviations AS (
    SELECT registration.event_type,
           FLOOR(EXTRACT(EPOCH FROM
               CASE WHEN registration.event_type = 'work_start' THEN registration.event_time - shift.start_time
                    ELSE registration.event_time - shift.end_time END) / 300) * 5 AS bucket_from
    FROM "Registration" registration
    JOIN "Shift" shift ON shift.shift_id = registration.shift_id
    CROSS JOIN params
    WHERE registration.event_type IN ('work_start', 'work_end')
      AND shift.start_time >= params.period_from
      AND shift.start_time < params.period_to
)
SELECT '[' || bucket_from || ', ' || (bucket_from + 5) || ') min' AS deviation_range,
       COUNT(*) FILTER (WHERE event_type = 'work_start') AS clock_ins,
       ROUND(100.0 * COUNT(*) FILTER (WHERE event_type = 'work_start')
             / SUM(COUNT(*) FILTER (WHERE event_type = 'work_start')) OVER (), 1) AS clock_ins_pct,
       COUNT(*) FILTER (WHERE event_type = 'work_end') AS clock_outs,
       ROUND(100.0 * COUNT(*) FILTER (WHERE event_type = 'work_end')
             / SUM(COUNT(*) FILTER (WHERE event_type = 'work_end')) OVER (), 1) AS clock_outs_pct
FROM deviations
GROUP BY bucket_from
ORDER BY bucket_from;

\echo '=== Indexes of work_time: size and number of index scans since the statistics reset ==='
SELECT index_stats.relname AS table_name,
       index_stats.indexrelname AS index_name,
       pg_size_pretty(pg_relation_size(index_stats.indexrelid)) AS index_size,
       index_stats.idx_scan
FROM pg_stat_user_indexes index_stats
WHERE index_stats.schemaname = 'work_time'
ORDER BY index_stats.relname, index_stats.indexrelname;
