
WITH params AS (
    SELECT CURRENT_DATE AS report_date
),
current_terms AS (
    SELECT contract.employee_id,
           COALESCE(an.employment_fraction, contract.employment_fraction) AS employment_fraction
    FROM "Contract" contract
    CROSS JOIN params
    LEFT JOIN "Annex" an
           ON an.contract_id = contract.contract_id
          AND an.effective_from <= params.report_date
          AND NOT EXISTS (
                SELECT 1
                FROM "Annex" later
                WHERE later.contract_id = an.contract_id
                  AND later.effective_from <= params.report_date
                  AND later.effective_from > an.effective_from
            )
    WHERE contract.start_date <= params.report_date
      AND (CASE WHEN an.annex_id IS NULL THEN contract.end_date ELSE an.end_date END IS NULL
           OR CASE WHEN an.annex_id IS NULL THEN contract.end_date ELSE an.end_date END >= params.report_date)
)
SELECT CASE WHEN GROUPING(branch.name) = 1 THEN 'ALL BRANCHES' 
            ELSE branch.name END AS branch,
       CASE WHEN GROUPING(branch.name) = 1 THEN ''
            WHEN GROUPING(department.name) = 1 THEN 'branch total'
            ELSE department.name END AS department,
       CASE WHEN GROUPING(department.name) = 1 THEN ''
            WHEN GROUPING(team.name) = 1 THEN 'department total'
            ELSE team.name END AS team,
       COUNT(*) AS employee_count,
       COUNT(ct.employee_id) AS employed_today,
       SUM(ct.employment_fraction) AS fte,
       COUNT(*) FILTER (WHERE ct.employment_fraction < 1) AS part_time_count
FROM "Employee" employee
JOIN "Team" team             ON team.team_id = employee.team_id
JOIN "Department" department ON department.department_id = team.department_id
JOIN "Branch" branch         ON branch.branch_id = department.branch_id
LEFT JOIN current_terms ct ON ct.employee_id = employee.employee_id
WHERE employee.archived = FALSE
GROUP BY ROLLUP (branch.name, department.name, team.name)
ORDER BY GROUPING(branch.name), branch.name, GROUPING(department.name), department.name, GROUPING(team.name), team.name;


WITH RECURSIVE params AS (
    SELECT 'G%' AS last_name_pattern
),
current_position AS (
    SELECT contract.employee_id, pos.name AS position_name
    FROM "Contract" contract
    LEFT JOIN "Annex" an
           ON an.contract_id = contract.contract_id
          AND NOT EXISTS (
                SELECT 1
                FROM "Annex" later
                WHERE later.contract_id = an.contract_id
                  AND later.effective_from > an.effective_from)
    JOIN "Position" pos ON pos.position_id = COALESCE(an.position_id, contract.position_id)
    WHERE NOT EXISTS (
            SELECT 1
            FROM "Contract" newer
            WHERE newer.employee_id = contract.employee_id
              AND newer.start_date > contract.start_date)
),
chain AS (
    SELECT employee.employee_id, employee.manager_id AS superior_id, 1 AS level
    FROM "Employee" employee
    CROSS JOIN params
    WHERE employee.manager_id IS NOT NULL
      AND (params.last_name_pattern IS NULL OR employee.last_name ILIKE params.last_name_pattern)
    UNION ALL
    SELECT ch.employee_id, manager.manager_id, ch.level + 1
    FROM chain ch
    JOIN "Employee" manager ON manager.employee_id = ch.superior_id
    WHERE manager.manager_id IS NOT NULL
      AND ch.level < 20
)
SELECT employee.first_name || ' ' || employee.last_name AS employee,
       ep.position_name AS position,
       COUNT(*) AS superior_count,
       string_agg(sup.first_name || ' ' || sup.last_name || ' (' || sp.position_name || ')',
                  ' -> ' ORDER BY ch.level) AS chain_of_command
FROM chain ch
JOIN "Employee" employee ON employee.employee_id = ch.employee_id
JOIN "Employee" sup      ON sup.employee_id = ch.superior_id
LEFT JOIN current_position ep ON ep.employee_id = employee.employee_id
LEFT JOIN current_position sp ON sp.employee_id = sup.employee_id
GROUP BY employee.employee_id, employee.first_name, employee.last_name, ep.position_name
ORDER BY superior_count, chain_of_command, employee;


WITH params AS (
    SELECT CURRENT_DATE AS report_date,
           CAST(NULL AS VARCHAR) AS team_name
),
terms AS (
    SELECT contract.employee_id, contract.contract_type_id, contract.start_date,
           COALESCE(an.position_id, contract.position_id) AS position_id,
           COALESCE(an.employment_fraction, contract.employment_fraction) AS employment_fraction,
           CASE WHEN an.annex_id IS NULL THEN contract.end_date ELSE an.end_date END AS valid_until,
           CASE WHEN an.annex_id IS NULL THEN 'contract'
                ELSE 'annex #' || an.annex_number || ' from ' || an.effective_from END AS terms_source
    FROM "Contract" contract
    CROSS JOIN params
    LEFT JOIN "Annex" an
           ON an.contract_id = contract.contract_id
          AND an.effective_from <= params.report_date
          AND NOT EXISTS (
                SELECT 1
                FROM "Annex" later
                WHERE later.contract_id = an.contract_id
                  AND later.effective_from <= params.report_date
                  AND later.effective_from > an.effective_from)
    WHERE contract.start_date <= params.report_date
)
SELECT team.name AS team,
       employee.first_name || ' ' || employee.last_name AS employee,
       ctype.name AS contract_type,
       pos.name AS position,
       tr.employment_fraction,
       tr.start_date AS contract_start,
       tr.valid_until,
       tr.terms_source
FROM terms tr
CROSS JOIN params
JOIN "Employee" employee  ON employee.employee_id = tr.employee_id
JOIN "Team" team          ON team.team_id = employee.team_id
JOIN "ContractType" ctype ON ctype.contract_type_id = tr.contract_type_id
JOIN "Position" pos       ON pos.position_id = tr.position_id
WHERE (tr.valid_until IS NULL OR tr.valid_until >= params.report_date)
  AND (params.team_name IS NULL OR team.name = params.team_name)
ORDER BY team.name, employee;

\echo '=== 4. Employment structure by contract type ==='
WITH current_contracts AS (
    SELECT contract.contract_id, contract.employee_id, contract.contract_type_id
    FROM "Contract" contract
    WHERE contract.start_date <= CURRENT_DATE
      AND (contract.end_date IS NULL OR contract.end_date >= CURRENT_DATE)
),
employment_start AS (
    SELECT contract.employee_id, MIN(contract.start_date) AS first_contract_start
    FROM "Contract" contract
    GROUP BY contract.employee_id
)
SELECT ctype.name AS contract_type,
       COUNT(cc.contract_id) AS contract_count,
       ROUND(100.0 * COUNT(cc.contract_id) / (SELECT COUNT(*) FROM current_contracts), 1) AS share_pct,
       ROUND(AVG(CURRENT_DATE - es.first_contract_start) / 365.25, 1) AS avg_seniority_years,
       ROUND(MIN(CURRENT_DATE - es.first_contract_start) / 365.25, 1) AS min_seniority_years,
       ROUND(MAX(CURRENT_DATE - es.first_contract_start) / 365.25, 1) AS max_seniority_years,
       COUNT(cc.contract_id) FILTER (
           WHERE es.first_contract_start > CURRENT_DATE - 365) AS hired_last_12_months
FROM "ContractType" ctype
LEFT JOIN current_contracts cc ON cc.contract_type_id = ctype.contract_type_id
LEFT JOIN employment_start es  ON es.employee_id = cc.employee_id
GROUP BY ctype.contract_type_id, ctype.name
ORDER BY contract_count DESC, ctype.name;

\echo '=== 5. Contracts ending within N days and their follow-up contracts ==='
WITH params AS (
    SELECT CURRENT_DATE AS today,
           90 AS days_ahead
),
final_terms AS (
    SELECT contract.contract_id, contract.employee_id, contract.contract_type_id,
           CASE WHEN an.annex_id IS NULL THEN contract.end_date ELSE an.end_date END AS end_date
    FROM "Contract" contract
    LEFT JOIN "Annex" an
           ON an.contract_id = contract.contract_id
          AND NOT EXISTS (
                SELECT 1
                FROM "Annex" later
                WHERE later.contract_id = an.contract_id
                  AND later.effective_from > an.effective_from)
)
SELECT employee.first_name || ' ' || employee.last_name AS employee,
       ctype.name AS contract_type,
       ft.end_date,
       ft.end_date - params.today AS days_left,
       manager.first_name || ' ' || manager.last_name AS notify_manager,
       COALESCE(next_type.name, 'none') AS follow_up_contract
FROM final_terms ft
CROSS JOIN params
JOIN "Employee" employee     ON employee.employee_id = ft.employee_id
JOIN "ContractType" ctype    ON ctype.contract_type_id = ft.contract_type_id
LEFT JOIN "Employee" manager ON manager.employee_id = employee.manager_id
LEFT JOIN "Contract" nxt
       ON nxt.employee_id = ft.employee_id
      AND nxt.start_date = ft.end_date + 1
LEFT JOIN "ContractType" next_type ON next_type.contract_type_id = nxt.contract_type_id
WHERE employee.archived = FALSE
  AND ft.end_date >= params.today
  AND ft.end_date < params.today + params.days_ahead
ORDER BY ft.end_date, employee;

\echo '=== 6. Roster for a given day with attendance status ==='
WITH params AS (
    SELECT (SELECT MAX(CAST(shift.start_time AS DATE))
            FROM "Shift" shift
            WHERE shift.start_time <= LOCALTIMESTAMP) AS roster_date,
           CAST(NULL AS VARCHAR) AS department_name,
           INTERVAL '10 minutes' AS late_tolerance
)
SELECT department.name AS department,
       to_char(shift.start_time, 'HH24:MI') || '-' || to_char(shift.end_time, 'HH24:MI') AS shift,
       zone.name AS zone,
       employee.first_name || ' ' || employee.last_name AS employee,
       CASE WHEN shift.start_time > LOCALTIMESTAMP THEN 'upcoming'
            WHEN ws.registration_id IS NULL THEN 'no_registration'
            WHEN we.registration_id IS NULL THEN 'in_progress'
            WHEN ws.event_time > shift.start_time + params.late_tolerance THEN 'late'
            ELSE 'on_time' END AS attendance_status,
       to_char(ws.event_time, 'HH24:MI') AS clock_in,
       to_char(we.event_time, 'HH24:MI') AS clock_out
FROM params
JOIN "Shift" shift
  ON shift.start_time >= params.roster_date
 AND shift.start_time < params.roster_date + 1
JOIN "Schedule" sch
  ON sch.schedule_id = shift.schedule_id
 AND sch.status = 'published'
JOIN "Department" department ON department.department_id = sch.department_id
JOIN "Assignment" assignment ON assignment.shift_id = shift.shift_id
JOIN "Employee" employee     ON employee.employee_id = assignment.employee_id
JOIN "Zone" zone             ON zone.zone_id = assignment.zone_id
LEFT JOIN "Registration" ws
       ON ws.shift_id = assignment.shift_id
      AND ws.employee_id = assignment.employee_id
      AND ws.event_type = 'work_start'
LEFT JOIN "Registration" we
       ON we.shift_id = assignment.shift_id
      AND we.employee_id = assignment.employee_id
      AND we.event_type = 'work_end'
WHERE params.department_name IS NULL OR department.name = params.department_name
ORDER BY department.name, shift.start_time, zone.name, employee;

\echo '=== 7. Zone utilisation in the current month ==='
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

\echo '=== 8. Can each employee of a department be assigned on a given day? ==='
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

\echo '=== 9. Readiness of next month draft schedules ==='
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

\echo '=== 10. Monthly time sheet of one employee (previous month) ==='
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

\echo '=== 11. Planned vs registered time: employees above the deviation threshold (previous month) ==='
WITH params AS (
    SELECT date_trunc('month', LOCALTIMESTAMP) - INTERVAL '1 month' AS period_from,
           date_trunc('month', LOCALTIMESTAMP) AS period_to,
           INTERVAL '15 minutes' AS paid_break,
           INTERVAL '2 hours' AS threshold
),
planned AS (
    SELECT assignment.employee_id,
           COUNT(*) AS planned_shifts,
           SUM(shift.end_time - shift.start_time) AS planned_time
    FROM "Assignment" assignment
    JOIN "Shift" shift  ON shift.shift_id = assignment.shift_id
    JOIN "Schedule" sch ON sch.schedule_id = shift.schedule_id
    CROSS JOIN params
    WHERE sch.status = 'published'
      AND shift.start_time >= params.period_from
      AND shift.start_time < params.period_to
    GROUP BY assignment.employee_id
),
shift_events AS (
    SELECT registration.employee_id, registration.shift_id,
           MIN(registration.event_time) FILTER (WHERE registration.event_type = 'work_start') AS work_start,
           MAX(registration.event_time) FILTER (WHERE registration.event_type = 'work_end') AS work_end,
           MIN(registration.event_time) FILTER (WHERE registration.event_type = 'break_start') AS break_start,
           MAX(registration.event_time) FILTER (WHERE registration.event_type = 'break_end') AS break_end
    FROM "Registration" registration
    JOIN "Shift" shift ON shift.shift_id = registration.shift_id
    CROSS JOIN params
    WHERE shift.start_time >= params.period_from
      AND shift.start_time < params.period_to
    GROUP BY registration.employee_id, registration.shift_id
),
worked AS (
    SELECT se.employee_id,
           (se.work_end - se.work_start)
           - GREATEST(COALESCE(se.break_end - se.break_start, INTERVAL '0') - params.paid_break,
                      INTERVAL '0') AS worked_time
    FROM shift_events se
    CROSS JOIN params
    WHERE se.work_start IS NOT NULL
      AND se.work_end IS NOT NULL
)
SELECT employee.first_name || ' ' || employee.last_name AS employee,
       department.name AS department,
       pl.planned_shifts,
       COUNT(worked.worked_time) AS registered_shifts,
       ROUND(EXTRACT(EPOCH FROM pl.planned_time) / 3600, 1) AS planned_hours,
       ROUND(EXTRACT(EPOCH FROM COALESCE(SUM(worked.worked_time), INTERVAL '0')) / 3600, 1) AS registered_hours,
       ROUND(EXTRACT(EPOCH FROM COALESCE(SUM(worked.worked_time), INTERVAL '0') - pl.planned_time) / 3600, 1)
           AS difference_hours,
       ROUND(100.0 * EXTRACT(EPOCH FROM COALESCE(SUM(worked.worked_time), INTERVAL '0') - pl.planned_time)
             / EXTRACT(EPOCH FROM pl.planned_time), 1) AS difference_pct
FROM planned pl
JOIN "Employee" employee     ON employee.employee_id = pl.employee_id
JOIN "Team" team             ON team.team_id = employee.team_id
JOIN "Department" department ON department.department_id = team.department_id
LEFT JOIN worked             ON worked.employee_id = pl.employee_id
GROUP BY employee.employee_id, employee.first_name, employee.last_name, department.name, pl.planned_shifts, pl.planned_time
HAVING ABS(EXTRACT(EPOCH FROM COALESCE(SUM(worked.worked_time), INTERVAL '0') - pl.planned_time))
       > EXTRACT(EPOCH FROM (SELECT threshold FROM params))
ORDER BY difference_hours DESC;

\echo '=== 12. Late arrivals by department in the last 90 days ==='
WITH params AS (
    SELECT LOCALTIMESTAMP - INTERVAL '90 days' AS period_from,
           LOCALTIMESTAMP AS period_to,
           INTERVAL '10 minutes' AS late_tolerance
),
arrivals AS (
    SELECT sch.department_id,
           registration.verification_status,
           registration.event_time > shift.start_time + params.late_tolerance AS is_late,
           EXTRACT(EPOCH FROM registration.event_time - shift.start_time) / 60 AS minutes_after_start
    FROM "Registration" registration
    JOIN "Shift" shift  ON shift.shift_id = registration.shift_id
    JOIN "Schedule" sch ON sch.schedule_id = shift.schedule_id
    CROSS JOIN params
    WHERE registration.event_type = 'work_start'
      AND shift.start_time >= params.period_from
      AND shift.start_time < params.period_to
)
SELECT branch.name AS branch,
       department.name AS department,
       COUNT(*) AS arrivals,
       COUNT(*) FILTER (WHERE ar.is_late) AS late_arrivals,
       ROUND(100.0 * COUNT(*) FILTER (WHERE ar.is_late) / COUNT(*), 1) AS late_pct,
       ROUND(AVG(ar.minutes_after_start) FILTER (WHERE ar.is_late), 1) AS avg_minutes_late,
       ROUND(CAST(percentile_cont(0.5) WITHIN GROUP (ORDER BY ar.minutes_after_start)
                  FILTER (WHERE ar.is_late) AS NUMERIC), 1) AS median_minutes_late,
       ROUND(MAX(ar.minutes_after_start), 1) AS max_minutes_late,
       COUNT(*) FILTER (WHERE ar.verification_status = 'needs_explanation') AS needs_explanation
FROM arrivals ar
JOIN "Department" department ON department.department_id = ar.department_id
JOIN "Branch" branch         ON branch.branch_id = department.branch_id
GROUP BY branch.name, department.name
ORDER BY late_pct DESC, branch.name, department.name;

\echo '=== 13. Top 3 latecomers in each department (last 90 days) ==='
WITH params AS (
    SELECT LOCALTIMESTAMP - INTERVAL '90 days' AS period_from,
           LOCALTIMESTAMP AS period_to,
           INTERVAL '10 minutes' AS late_tolerance
),
late_arrivals AS (
    SELECT sch.department_id,
           registration.employee_id,
           EXTRACT(EPOCH FROM registration.event_time - shift.start_time) / 60 AS minutes_late
    FROM "Registration" registration
    JOIN "Shift" shift  ON shift.shift_id = registration.shift_id
    JOIN "Schedule" sch ON sch.schedule_id = shift.schedule_id
    CROSS JOIN params
    WHERE registration.event_type = 'work_start'
      AND registration.event_time > shift.start_time + params.late_tolerance
      AND shift.start_time >= params.period_from
      AND shift.start_time < params.period_to
),
ranking AS (
    SELECT department_id,
           employee_id,
           COUNT(*) AS late_count,
           SUM(minutes_late) AS total_minutes_late,
           RANK() OVER (PARTITION BY department_id
                        ORDER BY COUNT(*) DESC, SUM(minutes_late) DESC) AS rank_in_department
    FROM late_arrivals
    GROUP BY department_id, employee_id
)
SELECT branch.name AS branch,
       department.name AS department,
       rk.rank_in_department,
       employee.first_name || ' ' || employee.last_name AS employee,
       rk.late_count,
       ROUND(rk.total_minutes_late) AS total_minutes_late,
       manager.first_name || ' ' || manager.last_name AS manager
FROM ranking rk
JOIN "Department" department ON department.department_id = rk.department_id
JOIN "Branch" branch         ON branch.branch_id = department.branch_id
JOIN "Employee" employee     ON employee.employee_id = rk.employee_id
LEFT JOIN "Employee" manager ON manager.employee_id = employee.manager_id
WHERE rk.rank_in_department <= 3
ORDER BY branch.name, department.name, rk.rank_in_department, employee;

\echo '=== 14. Distribution of clock-in and clock-out deviations from shift times ==='
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

\echo '=== 15. Registration event sequences per shift: complete, in progress or invalid ==='
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

\echo '=== 16. Registration verification queue by direct manager ==='
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

\echo '=== 17. Monthly work time summary for payroll by branch and department ==='
WITH params AS (
    SELECT date_trunc('month', LOCALTIMESTAMP) - INTERVAL '2 months' AS period_from,
           LOCALTIMESTAMP AS period_to,
           INTERVAL '15 minutes' AS paid_break,
           INTERVAL '10 minutes' AS late_tolerance
),
shift_events AS (
    SELECT registration.employee_id, registration.shift_id,
           MIN(registration.event_time) FILTER (WHERE registration.event_type = 'work_start') AS work_start,
           MAX(registration.event_time) FILTER (WHERE registration.event_type = 'work_end') AS work_end,
           MIN(registration.event_time) FILTER (WHERE registration.event_type = 'break_start') AS break_start,
           MAX(registration.event_time) FILTER (WHERE registration.event_type = 'break_end') AS break_end
    FROM "Registration" registration
    JOIN "Shift" shift ON shift.shift_id = registration.shift_id
    CROSS JOIN params
    WHERE shift.start_time >= params.period_from
      AND shift.start_time < params.period_to
    GROUP BY registration.employee_id, registration.shift_id
),
worked_shifts AS (
    SELECT se.employee_id,
           sch.department_id,
           shift.start_time,
           EXTRACT(EPOCH FROM
               (se.work_end - se.work_start)
               - GREATEST(COALESCE(se.break_end - se.break_start, INTERVAL '0') - params.paid_break,
                          INTERVAL '0')) / 3600 AS worked_hours,
           se.work_start > shift.start_time + params.late_tolerance AS is_late
    FROM shift_events se
    JOIN "Shift" shift  ON shift.shift_id = se.shift_id
    JOIN "Schedule" sch ON sch.schedule_id = shift.schedule_id
    CROSS JOIN params
    WHERE se.work_start IS NOT NULL
      AND se.work_end IS NOT NULL
)
SELECT to_char(ws.start_time, 'YYYY-MM') AS month,
       branch.name AS branch,
       department.name AS department,
       COUNT(DISTINCT ws.employee_id) AS employees_worked,
       COUNT(*) AS shifts_worked,
       ROUND(SUM(ws.worked_hours), 1) AS worked_hours,
       ROUND(COALESCE(SUM(ws.worked_hours) FILTER (
           WHERE EXTRACT(HOUR FROM ws.start_time) >= 22
              OR EXTRACT(HOUR FROM ws.start_time) < 6), 0), 1) AS night_shift_hours,
       ROUND(COALESCE(SUM(ws.worked_hours) FILTER (
           WHERE EXTRACT(ISODOW FROM ws.start_time) = 6), 0), 1) AS saturday_hours,
       COUNT(*) FILTER (WHERE ws.is_late) AS late_arrivals
FROM worked_shifts ws
JOIN "Department" department ON department.department_id = ws.department_id
JOIN "Branch" branch         ON branch.branch_id = department.branch_id
GROUP BY to_char(ws.start_time, 'YYYY-MM'), branch.name, department.name
ORDER BY month, branch, department;

\echo '=== 18. Planned daily headcount with a 7-day moving average ==='
WITH params AS (
    SELECT CAST(LOCALTIMESTAMP AS DATE) - 28 AS period_from,
           CAST(LOCALTIMESTAMP AS DATE) + 14 AS period_to
),
daily AS (
    SELECT CAST(shift.start_time AS DATE) AS work_date,
           COUNT(DISTINCT assignment.employee_id) AS people_planned,
           COUNT(DISTINCT sch.department_id) AS departments_working
    FROM "Assignment" assignment
    JOIN "Shift" shift  ON shift.shift_id = assignment.shift_id
    JOIN "Schedule" sch ON sch.schedule_id = shift.schedule_id
    CROSS JOIN params
    WHERE sch.status <> 'archived'
      AND shift.start_time >= params.period_from - 6
      AND shift.start_time < params.period_to
    GROUP BY CAST(shift.start_time AS DATE)
),
smoothed AS (
    SELECT work_date,
           departments_working,
           people_planned,
           AVG(people_planned) OVER (
               ORDER BY work_date
               RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW) AS moving_avg_7_days
    FROM daily
)
SELECT sm.work_date,
       to_char(sm.work_date, 'Dy') AS weekday,
       sm.departments_working,
       sm.people_planned,
       ROUND(sm.moving_avg_7_days, 1) AS moving_avg_7_days,
       ROUND(sm.people_planned - sm.moving_avg_7_days, 1) AS deviation_from_trend
FROM smoothed sm
CROSS JOIN params
WHERE sm.work_date >= params.period_from
ORDER BY sm.work_date;

\echo '=== 19. Absences in the current quarter by type ==='
WITH params AS (
    SELECT CAST(date_trunc('quarter', LOCALTIMESTAMP) AS DATE) AS period_from,
           CAST(date_trunc('quarter', LOCALTIMESTAMP) + INTERVAL '3 months' AS DATE) AS period_to
),
absences_in_period AS (
    SELECT ab.absence_id, ab.absence_type_id, ab.employee_id, ab.status, ab.start_date,
           ab.end_date - ab.start_date + 1 AS length_days,
           LEAST(ab.end_date, params.period_to - 1) - GREATEST(ab.start_date, params.period_from) + 1
               AS days_in_period
    FROM "Absence" ab
    CROSS JOIN params
    WHERE ab.start_date < params.period_to
      AND ab.end_date >= params.period_from
)
SELECT abt.name AS absence_type,
       COUNT(aip.absence_id) FILTER (WHERE aip.status = 'registered') AS registered_count,
       COUNT(aip.absence_id) FILTER (WHERE aip.status = 'cancelled') AS cancelled_count,
       COUNT(DISTINCT aip.employee_id) FILTER (WHERE aip.status = 'registered') AS employees_affected,
       COALESCE(SUM(aip.days_in_period) FILTER (WHERE aip.status = 'registered'), 0) AS days_in_period,
       ROUND(100.0 * COALESCE(SUM(aip.days_in_period) FILTER (WHERE aip.status = 'registered'), 0)
             / (SELECT SUM(days_in_period) FROM absences_in_period WHERE status = 'registered'), 1)
           AS share_of_days_pct,
       ROUND(AVG(aip.length_days) FILTER (WHERE aip.status = 'registered'), 1) AS avg_length_days,
       mode() WITHIN GROUP (ORDER BY trim(to_char(aip.start_date, 'Day')))
           FILTER (WHERE aip.status = 'registered') AS most_common_start_day
FROM "AbsenceType" abt
LEFT JOIN absences_in_period aip ON aip.absence_type_id = abt.absence_type_id
GROUP BY abt.absence_type_id, abt.name
ORDER BY days_in_period DESC, abt.name;

\echo '=== 20. Absenteeism rate by department (working days only) ==='
WITH params AS (
    SELECT CAST(date_trunc('month', LOCALTIMESTAMP) - INTERVAL '2 months' AS DATE) AS period_from,
           CURRENT_DATE AS period_to
),
working_days AS (
    SELECT DISTINCT sch.department_id, CAST(shift.start_time AS DATE) AS work_date
    FROM "Shift" shift
    JOIN "Schedule" sch ON sch.schedule_id = shift.schedule_id
    CROSS JOIN params
    WHERE sch.status = 'published'
      AND shift.start_time >= params.period_from
      AND shift.start_time < params.period_to
),
lost_days AS (
    SELECT team.department_id,
           abt.name AS absence_type,
           CAST(day AS DATE) AS absence_date
    FROM "Absence" ab
    JOIN "AbsenceType" abt   ON abt.absence_type_id = ab.absence_type_id
    JOIN "Employee" employee ON employee.employee_id = ab.employee_id
    JOIN "Team" team         ON team.team_id = employee.team_id
    CROSS JOIN params
    CROSS JOIN LATERAL generate_series(
        CAST(GREATEST(ab.start_date, params.period_from) AS TIMESTAMP),
        CAST(LEAST(ab.end_date, params.period_to - 1) AS TIMESTAMP),
        INTERVAL '1 day') AS day
    WHERE ab.status = 'registered'
      AND ab.start_date < params.period_to
      AND ab.end_date >= params.period_from
      AND EXISTS (
            SELECT 1
            FROM working_days wd
            WHERE wd.department_id = team.department_id
              AND wd.work_date = CAST(day AS DATE))
),
headcount AS (
    SELECT team.department_id, COUNT(*) AS employee_count
    FROM "Employee" employee
    JOIN "Team" team ON team.team_id = employee.team_id
    WHERE employee.archived = FALSE
    GROUP BY team.department_id
),
day_counts AS (
    SELECT department_id, COUNT(*) AS working_day_count
    FROM working_days
    GROUP BY department_id
),
loss_counts AS (
    SELECT department_id,
           COUNT(*) AS lost_person_days,
           COUNT(*) FILTER (WHERE absence_type = 'Zwolnienie lekarskie (L4)') AS sick_leave_days
    FROM lost_days
    GROUP BY department_id
)
SELECT branch.name AS branch,
       department.name AS department,
       hc.employee_count,
       dc.working_day_count,
       COALESCE(lc.lost_person_days, 0) AS lost_person_days,
       COALESCE(lc.sick_leave_days, 0) AS sick_leave_days,
       ROUND(100.0 * COALESCE(lc.lost_person_days, 0)
             / (hc.employee_count * dc.working_day_count), 2) AS absenteeism_pct
FROM "Department" department
JOIN "Branch" branch ON branch.branch_id = department.branch_id
JOIN headcount hc    ON hc.department_id = department.department_id
JOIN day_counts dc   ON dc.department_id = department.department_id
LEFT JOIN loss_counts lc ON lc.department_id = department.department_id
ORDER BY absenteeism_pct DESC, branch.name, department.name;

\echo '=== 21. Bradford factor ranking of short-notice absences (last 12 months) ==='
WITH params AS (
    SELECT CURRENT_DATE - 365 AS period_from,
           CURRENT_DATE AS period_to
),
spells AS (
    SELECT ab.employee_id,
           LEAST(ab.end_date, params.period_to) - ab.start_date + 1 AS spell_days
    FROM "Absence" ab
    JOIN "AbsenceType" abt ON abt.absence_type_id = ab.absence_type_id
    CROSS JOIN params
    WHERE ab.status = 'registered'
      AND abt.name IN ('Zwolnienie lekarskie (L4)', 'Urlop na żądanie')
      AND ab.start_date BETWEEN params.period_from AND params.period_to
)
SELECT employee.first_name || ' ' || employee.last_name AS employee,
       team.name AS team,
       COUNT(*) AS spell_count,
       SUM(sp.spell_days) AS total_days,
       COUNT(*) * COUNT(*) * SUM(sp.spell_days) AS bradford_factor,
       CASE WHEN COUNT(*) * COUNT(*) * SUM(sp.spell_days) >= 400 THEN 'action'
            WHEN COUNT(*) * COUNT(*) * SUM(sp.spell_days) >= 125 THEN 'review'
            WHEN COUNT(*) * COUNT(*) * SUM(sp.spell_days) >= 50 THEN 'monitor'
            ELSE 'no_concern' END AS assessment
FROM spells sp
JOIN "Employee" employee ON employee.employee_id = sp.employee_id
JOIN "Team" team         ON team.team_id = employee.team_id
GROUP BY employee.employee_id, employee.first_name, employee.last_name, team.name
ORDER BY bradford_factor DESC, spell_count DESC, employee;

\echo '=== 22. Accounts holding sensitive permissions ==='
WITH params AS (
    SELECT CAST(NULL AS VARCHAR) AS login_pattern
)
SELECT acc.login,
       employee.first_name || ' ' || employee.last_name AS employee,
       acc.active AS account_active,
       string_agg(DISTINCT role.role_name, ', ' ORDER BY role.role_name) AS roles,
       COUNT(DISTINCT perm.permission_id) AS permission_count,
       bool_or(perm.permission_name = 'accounts.manage') AS can_manage_accounts,
       bool_or(perm.permission_name = 'audit.read') AS can_read_audit,
       bool_or(perm.permission_name = 'contracts.edit') AS can_edit_contracts
FROM "Account" acc
CROSS JOIN params
JOIN "Employee" employee ON employee.employee_id = acc.employee_id
JOIN "AccountRole" ar    ON ar.account_id = acc.account_id
JOIN "Role" role         ON role.role_id = ar.role_id
JOIN "RolePermission" rp ON rp.role_id = role.role_id
JOIN "Permission" perm   ON perm.permission_id = rp.permission_id
WHERE params.login_pattern IS NULL OR acc.login ILIKE params.login_pattern
GROUP BY acc.account_id, acc.login, employee.first_name, employee.last_name, acc.active
HAVING bool_or(perm.permission_name IN ('accounts.manage', 'audit.read', 'contracts.edit'))
ORDER BY account_active, permission_count DESC, acc.login;

\echo '=== 23. Who changed data: audit log activity in the last 90 days ==='
WITH params AS (
    SELECT LOCALTIMESTAMP - INTERVAL '90 days' AS period_from
)
SELECT COALESCE(employee.first_name || ' ' || employee.last_name, 'System (automatic)') AS performed_by,
       au.object_type,
       COUNT(*) AS operation_count,
       COUNT(*) FILTER (WHERE au.operation_type = 'INSERT') AS inserts,
       COUNT(*) FILTER (WHERE au.operation_type = 'UPDATE') AS updates,
       COUNT(*) FILTER (WHERE au.operation_type = 'DELETE') AS deletes,
       string_agg(DISTINCT au.change_reason, '; ') AS change_reasons,
       MIN(au.operation_time) AS first_operation,
       MAX(au.operation_time) AS last_operation
FROM "Audit" au
CROSS JOIN params
LEFT JOIN "Account" acc       ON acc.account_id = au.account_id
LEFT JOIN "Employee" employee ON employee.employee_id = acc.employee_id
WHERE au.operation_time >= params.period_from
GROUP BY acc.account_id, employee.first_name, employee.last_name, au.object_type
ORDER BY operation_count DESC, performed_by, au.object_type;

\echo '=== 24. Is seniority related to punctuality? (correlation and regression) ==='
WITH params AS (
    SELECT LOCALTIMESTAMP - INTERVAL '90 days' AS period_from,
           LOCALTIMESTAMP AS period_to,
           INTERVAL '10 minutes' AS late_tolerance,
           10 AS min_arrivals
),
punctuality AS (
    SELECT registration.employee_id,
           100.0 * COUNT(*) FILTER (WHERE registration.event_time > shift.start_time + params.late_tolerance) / COUNT(*)
               AS late_pct
    FROM "Registration" registration
    JOIN "Shift" shift ON shift.shift_id = registration.shift_id
    CROSS JOIN params
    WHERE registration.event_type = 'work_start'
      AND shift.start_time >= params.period_from
      AND shift.start_time < params.period_to
    GROUP BY registration.employee_id, params.min_arrivals
    HAVING COUNT(*) >= params.min_arrivals
),
seniority AS (
    SELECT contract.employee_id, (CURRENT_DATE - MIN(contract.start_date)) / 365.25 AS seniority_years
    FROM "Contract" contract
    GROUP BY contract.employee_id
),
observations AS (
    SELECT department.name || ' (' || branch.city || ')' AS scope, sn.seniority_years, pu.late_pct
    FROM punctuality pu
    JOIN seniority sn            ON sn.employee_id = pu.employee_id
    JOIN "Employee" employee     ON employee.employee_id = pu.employee_id
    JOIN "Team" team             ON team.team_id = employee.team_id
    JOIN "Department" department ON department.department_id = team.department_id
    JOIN "Branch" branch         ON branch.branch_id = department.branch_id
),
scoped AS (
    SELECT scope, seniority_years, late_pct FROM observations
    UNION ALL
    SELECT 'ALL DEPARTMENTS', seniority_years, late_pct FROM observations
)
SELECT scope,
       COUNT(*) AS employees,
       ROUND(AVG(seniority_years), 1) AS avg_seniority_years,
       ROUND(AVG(late_pct), 2) AS avg_late_pct,
       ROUND(CAST(stddev_samp(late_pct) AS NUMERIC), 2) AS stddev_late_pct,
       ROUND(CAST(corr(late_pct, seniority_years) AS NUMERIC), 3) AS correlation,
       ROUND(CAST(regr_slope(late_pct, seniority_years) AS NUMERIC), 3) AS late_pct_change_per_year,
       ROUND(CAST(regr_r2(late_pct, seniority_years) AS NUMERIC), 3) AS r_squared
FROM scoped
GROUP BY scope
ORDER BY scope = 'ALL DEPARTMENTS', scope;
