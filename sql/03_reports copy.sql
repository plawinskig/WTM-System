-- 1 stan zatrudnienia i etaty z sumami pośrednimi

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


-- 2 łańcuch przełożonych do prezesa
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

-- 3 warunki zatrudnienia w dniu wybranym
WITH params AS (
    SELECT CURRENT_DATE AS report_date,
           'Ekspozycja' AS team_name
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

-- 4 struktura zatrudnienia wg typu umowy
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

-- 5 umowy kończące się w ciągu N dni i kontynuacja
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


-- 7 wykorzystanie stref w bieżącym miesiącu
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

-- 8  czy pracownika dziąłu można przydzielić w danym dniu
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

-- 9 gotowość roboczego grafiku na nast miesiac
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

-- 10 karta czasu pracy pracownika za poprzedni miesiąc
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

-- 11 czas planowany a zarejestroawny
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

-- 12 spóźnienia statystyka działów
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

-- 13
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

-- 14
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

-- 15
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

-- 16
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

-- 18
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


-- Ścieżka hierarchii dla każdego pracownika
-- Założenie: Przełożeni na samym szczycie (niemający przełożonego) pokrywają przechodnio wszystkich pracowników
WITH RECURSIVE hierarchy AS (
    SELECT e."employee_id", e."manager_id",
           0 AS depth,
           ARRAY[e."employee_id"] AS path
    FROM "Employee" e
    WHERE e."manager_id" IS NULL

    UNION ALL

    SELECT e."employee_id", e."manager_id",
           h.depth + 1,
           h.path || e."employee_id"
    FROM hierarchy h
        JOIN "Employee" e
            ON e."manager_id" = h."employee_id"
    WHERE NOT e."employee_id" = ANY(h.path)
)
SELECT employee_id, path
FROM hierarchy
ORDER BY path;

-- Nowe nieobecności w miesiącu i zmiana miesięczna
WITH months AS (
    SELECT generate_series(DATE '2026-01-01', DATE '2026-12-01', INTERVAL '1 month')::date AS month
), stats AS (
    SELECT m.month, COUNT(a."absence_id") AS absence_starts,
        COUNT(DISTINCT a."employee_id") AS employees_count
    FROM months m
    LEFT JOIN "Absence" a ON a."start_date" >= m.month
        AND a."start_date" < (m.month + INTERVAL '1 month')::date
        AND a."status" = 'registered'
    GROUP BY m.month
), shifts AS (
    SELECT l.*, LAG(l.absence_starts) OVER (ORDER BY l.month) AS last_month_absence_starts
    FROM stats l
)
SELECT month, absence_starts, employees_count, last_month_absence_starts,
    ROUND(100.0 * (absence_starts - last_month_absence_starts)
        / NULLIF(last_month_absence_starts, 0), 2) AS percent_monthly_change
FROM shifts
ORDER BY month;

-- Zarejestrowane nieobecności kolidujące z przypisem (assignment)
SELECT e."employee_id", e."first_name", e."last_name",
    ab."absence_id", at."name" AS absence_type,
    ab."start_date", ab."end_date",
    sh."shift_id", sh."start_time", sh."end_time"
FROM "Absence" ab
    JOIN "AbsenceType" at ON at."absence_type_id" = ab."absence_type_id"
    JOIN "Employee" e ON e."employee_id" = ab."employee_id"
    JOIN "Assignment" a ON a."employee_id" = ab."employee_id"
    JOIN "Shift" sh ON sh."shift_id" = a."shift_id"
    JOIN "Schedule" sc ON sc."schedule_id" = sh."schedule_id"
WHERE ab."status" = 'registered'
    AND sc."status" = 'published'
    AND sh."start_time" < (ab."end_date" + 1)
    AND sh."end_time" > ab."start_date"
ORDER BY sh."start_time", e."employee_id";

-- Statystyka pracowników najczęściej ze sobą pracujących (dzielących zmianę)
SELECT a1."employee_id" AS employee_1_id,
    CONCAT_WS(' ', e1."first_name", e1."last_name") AS employee_1,
    a2."employee_id" AS employee_2_id,
    CONCAT_WS(' ', e2."first_name", e2."last_name") AS employee_2,
    COUNT(*) AS shared_shifts,
    ROUND(SUM(EXTRACT(EPOCH FROM (
        sh."end_time" - sh."start_time"
    )) / 3600), 2) AS shared_planned_hours
FROM "Assignment" a1
    JOIN "Assignment" a2 ON a1."shift_id" = a2."shift_id" AND a1."employee_id" < a2."employee_id"
    JOIN "Employee" e1 ON e1."employee_id" = a1."employee_id"
    JOIN "Employee" e2 ON e2."employee_id" = a2."employee_id"
    JOIN "Shift" sh ON sh."shift_id" = a1."shift_id"
    JOIN "Schedule" sc ON sc."schedule_id" = sh."schedule_id"
WHERE sc."status" = 'published'
GROUP BY a1."employee_id", e1."first_name", e1."last_name",
    a2."employee_id", e2."first_name", e2."last_name"
ORDER BY shared_shifts DESC, shared_planned_hours DESC, employee_1_id;

-- Statystyka korelacji stażu z punktualnością
WITH params AS (
    SELECT LOCALTIMESTAMP - INTERVAL '90 days' AS period_from,
        LOCALTIMESTAMP AS period_to,
        INTERVAL '10 minutes' AS late_tolerance,
        10 AS min_arrivals
),
    punctuality AS (
        SELECT r.employee_id,
           100.0 * COUNT(*) FILTER (WHERE r.event_time > s.start_time + p.late_tolerance) / COUNT(*) AS late_pct
        FROM "Registration" r
            JOIN "Shift" s ON s.shift_id = r.shift_id
            CROSS JOIN params p
        WHERE r.event_type = 'work_start'
            AND s.start_time >= p.period_from
            AND s.start_time < p.period_to
        GROUP BY r.employee_id, p.min_arrivals
        HAVING COUNT(*) >= p.min_arrivals
    ),
    seniority AS (
        SELECT c.employee_id, (CURRENT_DATE - MIN(c.start_date)) / 365.25 AS seniority_years
        FROM "Contract" c
        GROUP BY c.employee_id
    ),
    observations AS (
        SELECT d.name || ' (' || b.city || ')' AS scope, sn.seniority_years, pu.late_pct
        FROM punctuality pu
            JOIN seniority sn ON sn.employee_id = pu.employee_id
            JOIN "Employee" e ON e.employee_id = pu.employee_id
            JOIN "Team" t ON t.team_id = e.team_id
            JOIN "Department" d ON d.department_id = t.department_id
            JOIN "Branch" b ON b.branch_id = d.branch_id
    ),
    scoped AS (
        SELECT scope, seniority_years, late_pct FROM observations
        UNION ALL
        SELECT 'ALL DEPARTMENTS', seniority_years, late_pct FROM observations
    )
SELECT scope,
    COUNT(*) AS employees,
    ROUND(AVG(seniority_years), 3) AS avg_seniority_years,
    ROUND(AVG(late_pct), 3) AS avg_late_pct,
    ROUND(CAST(stddev_samp(late_pct) AS NUMERIC), 3) AS stddev_late_pct,
    ROUND(CAST(corr(late_pct, seniority_years) AS NUMERIC), 3) AS correlation,
    ROUND(CAST(regr_slope(late_pct, seniority_years) AS NUMERIC), 3) AS late_pct_change_per_year,
    ROUND(CAST(regr_r2(late_pct, seniority_years) AS NUMERIC), 3) AS r_squared
FROM scoped
GROUP BY scope
ORDER BY scope = 'ALL DEPARTMENTS' DESC, scope;

--- Ile grafików roboczych, opublikowanych i zarchiwizowanych
SELECT d.name || ' (' || b.city || ')' AS department,
    COUNT(*) AS count,
    COUNT(*) FILTER (WHERE s.status = 'draft') AS draft,
    COUNT(*) FILTER (WHERE s.status = 'published') AS published,
    COUNT(*) FILTER (WHERE s.status = 'archived') AS archived
FROM "Schedule" s
    JOIN "Department" d ON d.department_id = s.department_id
    JOIN "Branch" b ON b.branch_id = d.branch_id
GROUP BY d.department_id, d.name, b.city
ORDER BY department DESC;

--- Jaki procent pracowników złożył deklarację dostępności pokrywającą najbliższe 30 dni
WITH declarations AS (
    SELECT DISTINCT employee_id
    FROM "Availability"
    WHERE available_to > LOCALTIMESTAMP
    AND available_from < LOCALTIMESTAMP + INTERVAL '30 days'
)
SELECT d.name || ' (' || b.city || ')' AS department,
    COUNT(*) AS all_employees,
    COUNT(a.employee_id) AS declared_employees,
    ROUND(100.0 * COUNT(a.employee_id) / COUNT(*), 2) AS declaration_pct
FROM "Employee" e
    JOIN "Team" t ON t.team_id = e.team_id
    JOIN "Department" d ON d.department_id = t.department_id
    JOIN "Branch" b ON b.branch_id = d.branch_id
    LEFT JOIN declarations a ON a.employee_id = e.employee_id
WHERE NOT e.archived
GROUP BY d.department_id, d.name, b.city
ORDER BY declaration_pct;