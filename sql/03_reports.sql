
WITH params AS (
    SELECT CURRENT_DATE AS report_date
),
current_terms AS (
    SELECT c.employee_id,
           COALESCE(an.employment_fraction, c.employment_fraction) AS employment_fraction
    FROM "Contract" c
    CROSS JOIN params p
    LEFT JOIN "Annex" an
           ON an.contract_id = c.contract_id
          AND an.effective_from <= p.report_date
          AND NOT EXISTS (
                SELECT 1
                FROM "Annex" later
                WHERE later.contract_id = an.contract_id
                  AND later.effective_from <= p.report_date
                  AND later.effective_from > an.effective_from
            )
    WHERE c.start_date <= p.report_date
      AND (CASE WHEN an.annex_id IS NULL THEN c.end_date ELSE an.end_date END IS NULL
           OR CASE WHEN an.annex_id IS NULL THEN c.end_date ELSE an.end_date END >= p.report_date)
)
SELECT CASE WHEN GROUPING(b.name) = 1 THEN 'ALL BRANCHES' 
            ELSE b.name END AS branch,
       CASE WHEN GROUPING(b.name) = 1 THEN ''
            WHEN GROUPING(d.name) = 1 THEN 'branch total'
            ELSE d.name END AS department,
       CASE WHEN GROUPING(d.name) = 1 THEN ''
            WHEN GROUPING(t.name) = 1 THEN 'department total'
            ELSE t.name END AS team,
       COUNT(*) AS employee_count,
       COUNT(ct.employee_id) AS employed_today,
       SUM(ct.employment_fraction) AS fte,
       COUNT(*) FILTER (WHERE ct.employment_fraction < 1) AS part_time_count
FROM "Employee" e
JOIN "Team" t       ON t.team_id = e.team_id
JOIN "Department" d ON d.department_id = t.department_id
JOIN "Branch" b     ON b.branch_id = d.branch_id
LEFT JOIN current_terms ct ON ct.employee_id = e.employee_id
WHERE e.archived = FALSE
GROUP BY ROLLUP (b.name, d.name, t.name)
ORDER BY GROUPING(b.name), b.name, GROUPING(d.name), d.name, GROUPING(t.name), t.name;


WITH RECURSIVE params AS (
    SELECT 'G%' AS last_name_pattern
),
current_position AS (
    SELECT c.employee_id, pos.name AS position_name
    FROM "Contract" c
    LEFT JOIN "Annex" an
           ON an.contract_id = c.contract_id
          AND NOT EXISTS (
                SELECT 1
                FROM "Annex" later
                WHERE later.contract_id = an.contract_id
                  AND later.effective_from > an.effective_from)
    JOIN "Position" pos ON pos.position_id = COALESCE(an.position_id, c.position_id)
    WHERE NOT EXISTS (
            SELECT 1
            FROM "Contract" newer
            WHERE newer.employee_id = c.employee_id
              AND newer.start_date > c.start_date)
),
chain AS (
    SELECT e.employee_id, e.manager_id AS superior_id, 1 AS level
    FROM "Employee" e
    CROSS JOIN params p
    WHERE e.manager_id IS NOT NULL
      AND (p.last_name_pattern IS NULL OR e.last_name ILIKE p.last_name_pattern)
    UNION ALL
    SELECT ch.employee_id, m.manager_id, ch.level + 1
    FROM chain ch
    JOIN "Employee" m ON m.employee_id = ch.superior_id
    WHERE m.manager_id IS NOT NULL
      AND ch.level < 20
)
SELECT e.first_name || ' ' || e.last_name AS employee,
       ep.position_name AS position,
       COUNT(*) AS superior_count,
       string_agg(sup.first_name || ' ' || sup.last_name || ' (' || sp.position_name || ')',
                  ' -> ' ORDER BY ch.level) AS chain_of_command
FROM chain ch
JOIN "Employee" e    ON e.employee_id = ch.employee_id
JOIN "Employee" sup  ON sup.employee_id = ch.superior_id
LEFT JOIN current_position ep ON ep.employee_id = e.employee_id
LEFT JOIN current_position sp ON sp.employee_id = sup.employee_id
GROUP BY e.employee_id, e.first_name, e.last_name, ep.position_name
ORDER BY superior_count, chain_of_command, employee;

\echo '=== 3. Employment terms in force on a given day (contract or latest annex) ==='
WITH params AS (
    SELECT CURRENT_DATE AS report_date,
           CAST(NULL AS VARCHAR) AS team_name
),
terms AS (
    SELECT c.employee_id, c.contract_type_id, c.start_date,
           COALESCE(an.position_id, c.position_id) AS position_id,
           COALESCE(an.employment_fraction, c.employment_fraction) AS employment_fraction,
           CASE WHEN an.annex_id IS NULL THEN c.end_date ELSE an.end_date END AS valid_until,
           CASE WHEN an.annex_id IS NULL THEN 'contract'
                ELSE 'annex #' || an.annex_number || ' from ' || an.effective_from END AS terms_source
    FROM "Contract" c
    CROSS JOIN params p
    LEFT JOIN "Annex" an
           ON an.contract_id = c.contract_id
          AND an.effective_from <= p.report_date
          AND NOT EXISTS (
                SELECT 1
                FROM "Annex" later
                WHERE later.contract_id = an.contract_id
                  AND later.effective_from <= p.report_date
                  AND later.effective_from > an.effective_from)
    WHERE c.start_date <= p.report_date
)
SELECT t.name AS team,
       e.first_name || ' ' || e.last_name AS employee,
       ctype.name AS contract_type,
       pos.name AS position,
       tr.employment_fraction,
       tr.start_date AS contract_start,
       tr.valid_until,
       tr.terms_source
FROM terms tr
CROSS JOIN params p
JOIN "Employee" e         ON e.employee_id = tr.employee_id
JOIN "Team" t             ON t.team_id = e.team_id
JOIN "ContractType" ctype ON ctype.contract_type_id = tr.contract_type_id
JOIN "Position" pos       ON pos.position_id = tr.position_id
WHERE (tr.valid_until IS NULL OR tr.valid_until >= p.report_date)
  AND (p.team_name IS NULL OR t.name = p.team_name)
ORDER BY t.name, employee;

\echo '=== 4. Employment structure by contract type ==='
WITH current_contracts AS (
    SELECT c.contract_id, c.employee_id, c.contract_type_id
    FROM "Contract" c
    WHERE c.start_date <= CURRENT_DATE
      AND (c.end_date IS NULL OR c.end_date >= CURRENT_DATE)
),
employment_start AS (
    SELECT c.employee_id, MIN(c.start_date) AS first_contract_start
    FROM "Contract" c
    GROUP BY c.employee_id
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
    SELECT c.contract_id, c.employee_id, c.contract_type_id,
           CASE WHEN an.annex_id IS NULL THEN c.end_date ELSE an.end_date END AS end_date
    FROM "Contract" c
    LEFT JOIN "Annex" an
           ON an.contract_id = c.contract_id
          AND NOT EXISTS (
                SELECT 1
                FROM "Annex" later
                WHERE later.contract_id = an.contract_id
                  AND later.effective_from > an.effective_from)
)
SELECT e.first_name || ' ' || e.last_name AS employee,
       ctype.name AS contract_type,
       ft.end_date,
       ft.end_date - p.today AS days_left,
       m.first_name || ' ' || m.last_name AS notify_manager,
       COALESCE(next_type.name, 'none') AS follow_up_contract
FROM final_terms ft
CROSS JOIN params p
JOIN "Employee" e         ON e.employee_id = ft.employee_id
JOIN "ContractType" ctype ON ctype.contract_type_id = ft.contract_type_id
LEFT JOIN "Employee" m    ON m.employee_id = e.manager_id
LEFT JOIN "Contract" nxt
       ON nxt.employee_id = ft.employee_id
      AND nxt.start_date = ft.end_date + 1
LEFT JOIN "ContractType" next_type ON next_type.contract_type_id = nxt.contract_type_id
WHERE e.archived = FALSE
  AND ft.end_date >= p.today
  AND ft.end_date < p.today + p.days_ahead
ORDER BY ft.end_date, employee;

\echo '=== 6. Roster for a given day with attendance status ==='
WITH params AS (
    SELECT (SELECT MAX(CAST(s.start_time AS DATE))
            FROM "Shift" s
            WHERE s.start_time <= LOCALTIMESTAMP) AS roster_date,
           CAST(NULL AS VARCHAR) AS department_name,
           INTERVAL '10 minutes' AS late_tolerance
)
SELECT d.name AS department,
       to_char(s.start_time, 'HH24:MI') || '-' || to_char(s.end_time, 'HH24:MI') AS shift,
       z.name AS zone,
       e.first_name || ' ' || e.last_name AS employee,
       CASE WHEN s.start_time > LOCALTIMESTAMP THEN 'upcoming'
            WHEN ws.registration_id IS NULL THEN 'no_registration'
            WHEN we.registration_id IS NULL THEN 'in_progress'
            WHEN ws.event_time > s.start_time + p.late_tolerance THEN 'late'
            ELSE 'on_time' END AS attendance_status,
       to_char(ws.event_time, 'HH24:MI') AS clock_in,
       to_char(we.event_time, 'HH24:MI') AS clock_out
FROM params p
JOIN "Shift" s
  ON s.start_time >= p.roster_date
 AND s.start_time < p.roster_date + 1
JOIN "Schedule" sch
  ON sch.schedule_id = s.schedule_id
 AND sch.status = 'published'
JOIN "Department" d ON d.department_id = sch.department_id
JOIN "Assignment" a ON a.shift_id = s.shift_id
JOIN "Employee" e   ON e.employee_id = a.employee_id
JOIN "Zone" z       ON z.zone_id = a.zone_id
LEFT JOIN "Registration" ws
       ON ws.shift_id = a.shift_id
      AND ws.employee_id = a.employee_id
      AND ws.event_type = 'work_start'
LEFT JOIN "Registration" we
       ON we.shift_id = a.shift_id
      AND we.employee_id = a.employee_id
      AND we.event_type = 'work_end'
WHERE p.department_name IS NULL OR d.name = p.department_name
ORDER BY d.name, s.start_time, z.name, employee;

\echo '=== 7. Zone utilisation in the current month ==='
WITH params AS (
    SELECT date_trunc('month', LOCALTIMESTAMP) AS period_from,
           date_trunc('month', LOCALTIMESTAMP) + INTERVAL '1 month' AS period_to
),
zone_slots AS (
    SELECT a.zone_id, s.start_time, COUNT(*) AS people_count
    FROM "Assignment" a
    JOIN "Shift" s      ON s.shift_id = a.shift_id
    JOIN "Schedule" sch ON sch.schedule_id = s.schedule_id
    CROSS JOIN params p
    WHERE sch.status = 'published'
      AND s.start_time >= p.period_from
      AND s.start_time < p.period_to
    GROUP BY a.zone_id, s.start_time
)
SELECT b.name AS branch,
       z.name AS zone,
       z.capacity,
       COUNT(zs.start_time) AS used_slots,
       ROUND(AVG(zs.people_count), 1) AS avg_people,
       MAX(zs.people_count) AS max_people,
       ROUND(100.0 * AVG(zs.people_count) / z.capacity, 1) AS avg_utilisation_pct,
       COUNT(*) FILTER (WHERE zs.people_count = z.capacity) AS full_slots
FROM "Zone" z
JOIN "Branch" b ON b.branch_id = z.branch_id
LEFT JOIN zone_slots zs ON zs.zone_id = z.zone_id
GROUP BY b.name, z.zone_id, z.name, z.capacity
ORDER BY avg_utilisation_pct DESC NULLS LAST, b.name, z.name;

\echo '=== 8. Can each employee of a department be assigned on a given day? ==='
WITH params AS (
    SELECT d.department_id,
           (SELECT MIN(CAST(s.start_time AS DATE))
            FROM "Shift" s
            JOIN "Schedule" sch ON sch.schedule_id = s.schedule_id
            WHERE sch.department_id = d.department_id
              AND sch.status <> 'archived'
              AND s.start_time >= CAST(LOCALTIMESTAMP AS DATE) + 1) AS check_date
    FROM "Department" d
    WHERE d.department_id = (
            SELECT t.department_id
            FROM "Employee" e
            JOIN "Team" t ON t.team_id = e.team_id
            WHERE e.archived = FALSE
            GROUP BY t.department_id
            ORDER BY COUNT(*) DESC, t.department_id
            LIMIT 1)
),
employee_facts AS (
    SELECT e.employee_id,
           EXISTS (
               SELECT 1
               FROM "Contract" c
               WHERE c.employee_id = e.employee_id
                 AND c.start_date <= p.check_date
                 AND (c.end_date IS NULL OR c.end_date >= p.check_date)) AS has_contract,
           (SELECT abt.name
            FROM "Absence" ab
            JOIN "AbsenceType" abt ON abt.absence_type_id = ab.absence_type_id
            WHERE ab.employee_id = e.employee_id
              AND ab.status = 'registered'
              AND p.check_date BETWEEN ab.start_date AND ab.end_date
            LIMIT 1) AS absence_type,
           EXISTS (
               SELECT 1
               FROM "Availability" av
               WHERE av.employee_id = e.employee_id
                 AND av.available = FALSE
                 AND av.available_from < p.check_date + 1
                 AND av.available_to > p.check_date) AS declared_unavailable,
           EXISTS (
               SELECT 1
               FROM "Availability" av
               WHERE av.employee_id = e.employee_id
                 AND av.available = TRUE
                 AND av.available_from < p.check_date + 1
                 AND av.available_to > p.check_date) AS declared_available,
           (SELECT to_char(s.start_time, 'HH24:MI') || '-' || to_char(s.end_time, 'HH24:MI')
            FROM "Assignment" a
            JOIN "Shift" s      ON s.shift_id = a.shift_id
            JOIN "Schedule" sch ON sch.schedule_id = s.schedule_id
            WHERE a.employee_id = e.employee_id
              AND sch.status <> 'archived'
              AND s.start_time >= p.check_date
              AND s.start_time < p.check_date + 1
            LIMIT 1) AS assigned_shift
    FROM "Employee" e
    JOIN "Team" t ON t.team_id = e.team_id
    JOIN params p ON p.department_id = t.department_id
    WHERE e.archived = FALSE
)
SELECT d.name AS department,
       p.check_date,
       e.first_name || ' ' || e.last_name AS employee,
       CASE WHEN NOT ef.has_contract THEN 'no_contract'
            WHEN ef.absence_type IS NOT NULL THEN 'absent: ' || ef.absence_type
            WHEN ef.declared_unavailable THEN 'declared_unavailable'
            WHEN ef.assigned_shift IS NOT NULL THEN 'already_assigned ' || ef.assigned_shift
            WHEN ef.declared_available THEN 'declared_available'
            ELSE 'no_declaration' END AS assignment_status
FROM employee_facts ef
CROSS JOIN params p
JOIN "Employee" e   ON e.employee_id = ef.employee_id
JOIN "Department" d ON d.department_id = p.department_id
ORDER BY assignment_status, employee;

\echo '=== 9. Readiness of next month draft schedules ==='
WITH shift_staffing AS (
    SELECT s.schedule_id, s.shift_id, COUNT(a.assignment_id) AS staff_count
    FROM "Shift" s
    JOIN "Schedule" sch ON sch.schedule_id = s.schedule_id
    LEFT JOIN "Assignment" a ON a.shift_id = s.shift_id
    WHERE sch.status = 'draft'
    GROUP BY s.schedule_id, s.shift_id
)
SELECT b.name AS branch,
       d.name AS department,
       sch.period_from,
       sch.version_number,
       COUNT(*) AS shift_count,
       COUNT(*) FILTER (WHERE ss.staff_count = 0) AS unstaffed_shifts,
       MIN(ss.staff_count) AS min_staff,
       ROUND(AVG(ss.staff_count), 1) AS avg_staff,
       MAX(ss.staff_count) AS max_staff,
       (SELECT COUNT(*)
        FROM "Employee" e
        JOIN "Team" t ON t.team_id = e.team_id
        WHERE t.department_id = d.department_id
          AND e.archived = FALSE
          AND NOT EXISTS (
                SELECT 1
                FROM "Assignment" a
                JOIN "Shift" s ON s.shift_id = a.shift_id
                WHERE s.schedule_id = sch.schedule_id
                  AND a.employee_id = e.employee_id)) AS employees_without_shifts
FROM shift_staffing ss
JOIN "Schedule" sch ON sch.schedule_id = ss.schedule_id
JOIN "Department" d ON d.department_id = sch.department_id
JOIN "Branch" b     ON b.branch_id = d.branch_id
GROUP BY b.name, d.department_id, d.name, sch.schedule_id, sch.period_from, sch.version_number
ORDER BY unstaffed_shifts DESC, b.name, d.name;

\echo '=== 10. Monthly time sheet of one employee (previous month) ==='
WITH params AS (
    SELECT (SELECT r.employee_id
            FROM "Registration" r
            GROUP BY r.employee_id
            ORDER BY COUNT(*) DESC, r.employee_id
            LIMIT 1) AS employee_id,
           date_trunc('month', LOCALTIMESTAMP) - INTERVAL '1 month' AS period_from,
           date_trunc('month', LOCALTIMESTAMP) AS period_to,
           INTERVAL '15 minutes' AS paid_break,
           INTERVAL '10 minutes' AS late_tolerance
),
shift_events AS (
    SELECT r.shift_id,
           MIN(r.event_time) FILTER (WHERE r.event_type = 'work_start') AS work_start,
           MAX(r.event_time) FILTER (WHERE r.event_type = 'work_end') AS work_end,
           MIN(r.event_time) FILTER (WHERE r.event_type = 'break_start') AS break_start,
           MAX(r.event_time) FILTER (WHERE r.event_type = 'break_end') AS break_end,
           CASE WHEN bool_or(r.verification_status = 'needs_explanation') THEN 'needs_explanation'
                WHEN bool_or(r.verification_status = 'unverified') THEN 'unverified'
                ELSE 'valid' END AS verification_status
    FROM "Registration" r
    JOIN params p ON p.employee_id = r.employee_id
    GROUP BY r.shift_id
)
SELECT e.first_name || ' ' || e.last_name AS employee,
       CAST(s.start_time AS DATE) AS work_date,
       to_char(s.start_time, 'HH24:MI') || '-' || to_char(s.end_time, 'HH24:MI') AS planned_shift,
       to_char(se.work_start, 'HH24:MI') AS clock_in,
       to_char(se.work_end, 'HH24:MI') AS clock_out,
       COALESCE(ROUND(EXTRACT(EPOCH FROM se.break_end - se.break_start) / 60), 0) AS break_minutes,
       ROUND(EXTRACT(EPOCH FROM
           (se.work_end - se.work_start)
           - GREATEST(COALESCE(se.break_end - se.break_start, INTERVAL '0') - p.paid_break,
                      INTERVAL '0')) / 3600, 2) AS worked_hours,
       CASE WHEN se.work_start > s.start_time + p.late_tolerance
            THEN ROUND(EXTRACT(EPOCH FROM se.work_start - s.start_time) / 60) END AS minutes_late,
       se.verification_status
FROM params p
JOIN "Employee" e   ON e.employee_id = p.employee_id
JOIN "Assignment" a ON a.employee_id = p.employee_id
JOIN "Shift" s      ON s.shift_id = a.shift_id
JOIN "Schedule" sch ON sch.schedule_id = s.schedule_id
LEFT JOIN shift_events se ON se.shift_id = s.shift_id
WHERE sch.status = 'published'
  AND s.start_time >= p.period_from
  AND s.start_time < p.period_to
ORDER BY s.start_time;

\echo '=== 11. Planned vs registered time: employees above the deviation threshold (previous month) ==='
WITH params AS (
    SELECT date_trunc('month', LOCALTIMESTAMP) - INTERVAL '1 month' AS period_from,
           date_trunc('month', LOCALTIMESTAMP) AS period_to,
           INTERVAL '15 minutes' AS paid_break,
           INTERVAL '2 hours' AS threshold
),
planned AS (
    SELECT a.employee_id,
           COUNT(*) AS planned_shifts,
           SUM(s.end_time - s.start_time) AS planned_time
    FROM "Assignment" a
    JOIN "Shift" s      ON s.shift_id = a.shift_id
    JOIN "Schedule" sch ON sch.schedule_id = s.schedule_id
    CROSS JOIN params p
    WHERE sch.status = 'published'
      AND s.start_time >= p.period_from
      AND s.start_time < p.period_to
    GROUP BY a.employee_id
),
shift_events AS (
    SELECT r.employee_id, r.shift_id,
           MIN(r.event_time) FILTER (WHERE r.event_type = 'work_start') AS work_start,
           MAX(r.event_time) FILTER (WHERE r.event_type = 'work_end') AS work_end,
           MIN(r.event_time) FILTER (WHERE r.event_type = 'break_start') AS break_start,
           MAX(r.event_time) FILTER (WHERE r.event_type = 'break_end') AS break_end
    FROM "Registration" r
    JOIN "Shift" s ON s.shift_id = r.shift_id
    CROSS JOIN params p
    WHERE s.start_time >= p.period_from
      AND s.start_time < p.period_to
    GROUP BY r.employee_id, r.shift_id
),
worked AS (
    SELECT se.employee_id,
           (se.work_end - se.work_start)
           - GREATEST(COALESCE(se.break_end - se.break_start, INTERVAL '0') - p.paid_break,
                      INTERVAL '0') AS worked_time
    FROM shift_events se
    CROSS JOIN params p
    WHERE se.work_start IS NOT NULL
      AND se.work_end IS NOT NULL
)
SELECT e.first_name || ' ' || e.last_name AS employee,
       d.name AS department,
       pl.planned_shifts,
       COUNT(w.worked_time) AS registered_shifts,
       ROUND(EXTRACT(EPOCH FROM pl.planned_time) / 3600, 1) AS planned_hours,
       ROUND(EXTRACT(EPOCH FROM COALESCE(SUM(w.worked_time), INTERVAL '0')) / 3600, 1) AS registered_hours,
       ROUND(EXTRACT(EPOCH FROM COALESCE(SUM(w.worked_time), INTERVAL '0') - pl.planned_time) / 3600, 1)
           AS difference_hours,
       ROUND(100.0 * EXTRACT(EPOCH FROM COALESCE(SUM(w.worked_time), INTERVAL '0') - pl.planned_time)
             / EXTRACT(EPOCH FROM pl.planned_time), 1) AS difference_pct
FROM planned pl
JOIN "Employee" e   ON e.employee_id = pl.employee_id
JOIN "Team" t       ON t.team_id = e.team_id
JOIN "Department" d ON d.department_id = t.department_id
LEFT JOIN worked w  ON w.employee_id = pl.employee_id
GROUP BY e.employee_id, e.first_name, e.last_name, d.name, pl.planned_shifts, pl.planned_time
HAVING ABS(EXTRACT(EPOCH FROM COALESCE(SUM(w.worked_time), INTERVAL '0') - pl.planned_time))
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
           r.verification_status,
           r.event_time > s.start_time + p.late_tolerance AS is_late,
           EXTRACT(EPOCH FROM r.event_time - s.start_time) / 60 AS minutes_after_start
    FROM "Registration" r
    JOIN "Shift" s      ON s.shift_id = r.shift_id
    JOIN "Schedule" sch ON sch.schedule_id = s.schedule_id
    CROSS JOIN params p
    WHERE r.event_type = 'work_start'
      AND s.start_time >= p.period_from
      AND s.start_time < p.period_to
)
SELECT b.name AS branch,
       d.name AS department,
       COUNT(*) AS arrivals,
       COUNT(*) FILTER (WHERE ar.is_late) AS late_arrivals,
       ROUND(100.0 * COUNT(*) FILTER (WHERE ar.is_late) / COUNT(*), 1) AS late_pct,
       ROUND(AVG(ar.minutes_after_start) FILTER (WHERE ar.is_late), 1) AS avg_minutes_late,
       ROUND(CAST(percentile_cont(0.5) WITHIN GROUP (ORDER BY ar.minutes_after_start)
                  FILTER (WHERE ar.is_late) AS NUMERIC), 1) AS median_minutes_late,
       ROUND(MAX(ar.minutes_after_start), 1) AS max_minutes_late,
       COUNT(*) FILTER (WHERE ar.verification_status = 'needs_explanation') AS needs_explanation
FROM arrivals ar
JOIN "Department" d ON d.department_id = ar.department_id
JOIN "Branch" b     ON b.branch_id = d.branch_id
GROUP BY b.name, d.name
ORDER BY late_pct DESC, b.name, d.name;

\echo '=== 13. Top 3 latecomers in each department (last 90 days) ==='
WITH params AS (
    SELECT LOCALTIMESTAMP - INTERVAL '90 days' AS period_from,
           LOCALTIMESTAMP AS period_to,
           INTERVAL '10 minutes' AS late_tolerance
),
late_arrivals AS (
    SELECT sch.department_id,
           r.employee_id,
           EXTRACT(EPOCH FROM r.event_time - s.start_time) / 60 AS minutes_late
    FROM "Registration" r
    JOIN "Shift" s      ON s.shift_id = r.shift_id
    JOIN "Schedule" sch ON sch.schedule_id = s.schedule_id
    CROSS JOIN params p
    WHERE r.event_type = 'work_start'
      AND r.event_time > s.start_time + p.late_tolerance
      AND s.start_time >= p.period_from
      AND s.start_time < p.period_to
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
SELECT b.name AS branch,
       d.name AS department,
       rk.rank_in_department,
       e.first_name || ' ' || e.last_name AS employee,
       rk.late_count,
       ROUND(rk.total_minutes_late) AS total_minutes_late,
       m.first_name || ' ' || m.last_name AS manager
FROM ranking rk
JOIN "Department" d    ON d.department_id = rk.department_id
JOIN "Branch" b        ON b.branch_id = d.branch_id
JOIN "Employee" e      ON e.employee_id = rk.employee_id
LEFT JOIN "Employee" m ON m.employee_id = e.manager_id
WHERE rk.rank_in_department <= 3
ORDER BY b.name, d.name, rk.rank_in_department, employee;

\echo '=== 14. Distribution of clock-in and clock-out deviations from shift times ==='
WITH params AS (
    SELECT LOCALTIMESTAMP - INTERVAL '90 days' AS period_from,
           LOCALTIMESTAMP AS period_to
),
deviations AS (
    SELECT r.event_type,
           FLOOR(EXTRACT(EPOCH FROM
               CASE WHEN r.event_type = 'work_start' THEN r.event_time - s.start_time
                    ELSE r.event_time - s.end_time END) / 300) * 5 AS bucket_from
    FROM "Registration" r
    JOIN "Shift" s ON s.shift_id = r.shift_id
    CROSS JOIN params p
    WHERE r.event_type IN ('work_start', 'work_end')
      AND s.start_time >= p.period_from
      AND s.start_time < p.period_to
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
    SELECT r.employee_id,
           r.shift_id,
           MAX(s.end_time) AS shift_end,
           string_agg(r.event_type, ' > ' ORDER BY r.event_time) AS event_sequence
    FROM "Registration" r
    JOIN "Shift" s ON s.shift_id = r.shift_id
    GROUP BY r.employee_id, r.shift_id
)
SELECT sq.event_sequence,
       CASE WHEN sq.event_sequence IN ('work_start > work_end',
                                       'work_start > break_start > break_end > work_end')
                THEN 'complete'
            WHEN sq.shift_end > LOCALTIMESTAMP - p.clock_out_grace THEN 'shift_in_progress'
            ELSE 'invalid' END AS sequence_status,
       COUNT(*) AS shift_count,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM sequences), 2) AS share_pct,
       MAX(sq.shift_end) AS latest_shift_end
FROM sequences sq
CROSS JOIN params p
GROUP BY sq.event_sequence, sequence_status
ORDER BY shift_count DESC;

\echo '=== 16. Registration verification queue by direct manager ==='
SELECT m.first_name || ' ' || m.last_name AS manager,
       mt.name AS manager_team,
       COUNT(*) FILTER (WHERE r.verification_status = 'needs_explanation') AS needs_explanation,
       COUNT(*) FILTER (WHERE r.verification_status = 'unverified') AS unverified,
       COUNT(DISTINCT r.employee_id) AS employees,
       MIN(r.event_time) AS oldest_pending_event,
       CURRENT_DATE - CAST(MIN(r.event_time) AS DATE) AS days_waiting
FROM "Registration" r
JOIN "Employee" e      ON e.employee_id = r.employee_id
LEFT JOIN "Employee" m ON m.employee_id = e.manager_id
LEFT JOIN "Team" mt    ON mt.team_id = m.team_id
WHERE r.verification_status IN ('unverified', 'needs_explanation')
GROUP BY m.employee_id, m.first_name, m.last_name, mt.name
ORDER BY needs_explanation DESC, days_waiting DESC, manager;

\echo '=== 17. Monthly work time summary for payroll by branch and department ==='
WITH params AS (
    SELECT date_trunc('month', LOCALTIMESTAMP) - INTERVAL '2 months' AS period_from,
           LOCALTIMESTAMP AS period_to,
           INTERVAL '15 minutes' AS paid_break,
           INTERVAL '10 minutes' AS late_tolerance
),
shift_events AS (
    SELECT r.employee_id, r.shift_id,
           MIN(r.event_time) FILTER (WHERE r.event_type = 'work_start') AS work_start,
           MAX(r.event_time) FILTER (WHERE r.event_type = 'work_end') AS work_end,
           MIN(r.event_time) FILTER (WHERE r.event_type = 'break_start') AS break_start,
           MAX(r.event_time) FILTER (WHERE r.event_type = 'break_end') AS break_end
    FROM "Registration" r
    JOIN "Shift" s ON s.shift_id = r.shift_id
    CROSS JOIN params p
    WHERE s.start_time >= p.period_from
      AND s.start_time < p.period_to
    GROUP BY r.employee_id, r.shift_id
),
worked_shifts AS (
    SELECT se.employee_id,
           sch.department_id,
           s.start_time,
           EXTRACT(EPOCH FROM
               (se.work_end - se.work_start)
               - GREATEST(COALESCE(se.break_end - se.break_start, INTERVAL '0') - p.paid_break,
                          INTERVAL '0')) / 3600 AS worked_hours,
           se.work_start > s.start_time + p.late_tolerance AS is_late
    FROM shift_events se
    JOIN "Shift" s      ON s.shift_id = se.shift_id
    JOIN "Schedule" sch ON sch.schedule_id = s.schedule_id
    CROSS JOIN params p
    WHERE se.work_start IS NOT NULL
      AND se.work_end IS NOT NULL
)
SELECT to_char(ws.start_time, 'YYYY-MM') AS month,
       b.name AS branch,
       d.name AS department,
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
JOIN "Department" d ON d.department_id = ws.department_id
JOIN "Branch" b     ON b.branch_id = d.branch_id
GROUP BY to_char(ws.start_time, 'YYYY-MM'), b.name, d.name
ORDER BY month, branch, department;

\echo '=== 18. Planned daily headcount with a 7-day moving average ==='
WITH params AS (
    SELECT CAST(LOCALTIMESTAMP AS DATE) - 28 AS period_from,
           CAST(LOCALTIMESTAMP AS DATE) + 14 AS period_to
),
daily AS (
    SELECT CAST(s.start_time AS DATE) AS work_date,
           COUNT(DISTINCT a.employee_id) AS people_planned,
           COUNT(DISTINCT sch.department_id) AS departments_working
    FROM "Assignment" a
    JOIN "Shift" s      ON s.shift_id = a.shift_id
    JOIN "Schedule" sch ON sch.schedule_id = s.schedule_id
    CROSS JOIN params p
    WHERE sch.status <> 'archived'
      AND s.start_time >= p.period_from - 6
      AND s.start_time < p.period_to
    GROUP BY CAST(s.start_time AS DATE)
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
CROSS JOIN params p
WHERE sm.work_date >= p.period_from
ORDER BY sm.work_date;

\echo '=== 19. Absences in the current quarter by type ==='
WITH params AS (
    SELECT CAST(date_trunc('quarter', LOCALTIMESTAMP) AS DATE) AS period_from,
           CAST(date_trunc('quarter', LOCALTIMESTAMP) + INTERVAL '3 months' AS DATE) AS period_to
),
absences_in_period AS (
    SELECT ab.absence_id, ab.absence_type_id, ab.employee_id, ab.status, ab.start_date,
           ab.end_date - ab.start_date + 1 AS length_days,
           LEAST(ab.end_date, p.period_to - 1) - GREATEST(ab.start_date, p.period_from) + 1
               AS days_in_period
    FROM "Absence" ab
    CROSS JOIN params p
    WHERE ab.start_date < p.period_to
      AND ab.end_date >= p.period_from
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
    SELECT DISTINCT sch.department_id, CAST(s.start_time AS DATE) AS work_date
    FROM "Shift" s
    JOIN "Schedule" sch ON sch.schedule_id = s.schedule_id
    CROSS JOIN params p
    WHERE sch.status = 'published'
      AND s.start_time >= p.period_from
      AND s.start_time < p.period_to
),
lost_days AS (
    SELECT t.department_id,
           abt.name AS absence_type,
           CAST(day AS DATE) AS absence_date
    FROM "Absence" ab
    JOIN "AbsenceType" abt ON abt.absence_type_id = ab.absence_type_id
    JOIN "Employee" e      ON e.employee_id = ab.employee_id
    JOIN "Team" t          ON t.team_id = e.team_id
    CROSS JOIN params p
    CROSS JOIN LATERAL generate_series(
        CAST(GREATEST(ab.start_date, p.period_from) AS TIMESTAMP),
        CAST(LEAST(ab.end_date, p.period_to - 1) AS TIMESTAMP),
        INTERVAL '1 day') AS day
    WHERE ab.status = 'registered'
      AND ab.start_date < p.period_to
      AND ab.end_date >= p.period_from
      AND EXISTS (
            SELECT 1
            FROM working_days wd
            WHERE wd.department_id = t.department_id
              AND wd.work_date = CAST(day AS DATE))
),
headcount AS (
    SELECT t.department_id, COUNT(*) AS employee_count
    FROM "Employee" e
    JOIN "Team" t ON t.team_id = e.team_id
    WHERE e.archived = FALSE
    GROUP BY t.department_id
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
SELECT b.name AS branch,
       d.name AS department,
       hc.employee_count,
       dc.working_day_count,
       COALESCE(lc.lost_person_days, 0) AS lost_person_days,
       COALESCE(lc.sick_leave_days, 0) AS sick_leave_days,
       ROUND(100.0 * COALESCE(lc.lost_person_days, 0)
             / (hc.employee_count * dc.working_day_count), 2) AS absenteeism_pct
FROM "Department" d
JOIN "Branch" b     ON b.branch_id = d.branch_id
JOIN headcount hc   ON hc.department_id = d.department_id
JOIN day_counts dc  ON dc.department_id = d.department_id
LEFT JOIN loss_counts lc ON lc.department_id = d.department_id
ORDER BY absenteeism_pct DESC, b.name, d.name;

\echo '=== 21. Bradford factor ranking of short-notice absences (last 12 months) ==='
WITH params AS (
    SELECT CURRENT_DATE - 365 AS period_from,
           CURRENT_DATE AS period_to
),
spells AS (
    SELECT ab.employee_id,
           LEAST(ab.end_date, p.period_to) - ab.start_date + 1 AS spell_days
    FROM "Absence" ab
    JOIN "AbsenceType" abt ON abt.absence_type_id = ab.absence_type_id
    CROSS JOIN params p
    WHERE ab.status = 'registered'
      AND abt.name IN ('Zwolnienie lekarskie (L4)', 'Urlop na żądanie')
      AND ab.start_date BETWEEN p.period_from AND p.period_to
)
SELECT e.first_name || ' ' || e.last_name AS employee,
       t.name AS team,
       COUNT(*) AS spell_count,
       SUM(sp.spell_days) AS total_days,
       COUNT(*) * COUNT(*) * SUM(sp.spell_days) AS bradford_factor,
       CASE WHEN COUNT(*) * COUNT(*) * SUM(sp.spell_days) >= 400 THEN 'action'
            WHEN COUNT(*) * COUNT(*) * SUM(sp.spell_days) >= 125 THEN 'review'
            WHEN COUNT(*) * COUNT(*) * SUM(sp.spell_days) >= 50 THEN 'monitor'
            ELSE 'no_concern' END AS assessment
FROM spells sp
JOIN "Employee" e ON e.employee_id = sp.employee_id
JOIN "Team" t     ON t.team_id = e.team_id
GROUP BY e.employee_id, e.first_name, e.last_name, t.name
ORDER BY bradford_factor DESC, spell_count DESC, employee;

\echo '=== 22. Accounts holding sensitive permissions ==='
WITH params AS (
    SELECT CAST(NULL AS VARCHAR) AS login_pattern
)
SELECT acc.login,
       e.first_name || ' ' || e.last_name AS employee,
       acc.active AS account_active,
       string_agg(DISTINCT r.role_name, ', ' ORDER BY r.role_name) AS roles,
       COUNT(DISTINCT perm.permission_id) AS permission_count,
       bool_or(perm.permission_name = 'accounts.manage') AS can_manage_accounts,
       bool_or(perm.permission_name = 'audit.read') AS can_read_audit,
       bool_or(perm.permission_name = 'contracts.edit') AS can_edit_contracts
FROM "Account" acc
CROSS JOIN params p
JOIN "Employee" e         ON e.employee_id = acc.employee_id
JOIN "AccountRole" ar     ON ar.account_id = acc.account_id
JOIN "Role" r             ON r.role_id = ar.role_id
JOIN "RolePermission" rp  ON rp.role_id = r.role_id
JOIN "Permission" perm    ON perm.permission_id = rp.permission_id
WHERE p.login_pattern IS NULL OR acc.login ILIKE p.login_pattern
GROUP BY acc.account_id, acc.login, e.first_name, e.last_name, acc.active
HAVING bool_or(perm.permission_name IN ('accounts.manage', 'audit.read', 'contracts.edit'))
ORDER BY account_active, permission_count DESC, acc.login;

\echo '=== 23. Who changed data: audit log activity in the last 90 days ==='
WITH params AS (
    SELECT LOCALTIMESTAMP - INTERVAL '90 days' AS period_from
)
SELECT COALESCE(e.first_name || ' ' || e.last_name, 'System (automatic)') AS performed_by,
       au.object_type,
       COUNT(*) AS operation_count,
       COUNT(*) FILTER (WHERE au.operation_type = 'INSERT') AS inserts,
       COUNT(*) FILTER (WHERE au.operation_type = 'UPDATE') AS updates,
       COUNT(*) FILTER (WHERE au.operation_type = 'DELETE') AS deletes,
       string_agg(DISTINCT au.change_reason, '; ') AS change_reasons,
       MIN(au.operation_time) AS first_operation,
       MAX(au.operation_time) AS last_operation
FROM "Audit" au
CROSS JOIN params p
LEFT JOIN "Account" acc ON acc.account_id = au.account_id
LEFT JOIN "Employee" e  ON e.employee_id = acc.employee_id
WHERE au.operation_time >= p.period_from
GROUP BY acc.account_id, e.first_name, e.last_name, au.object_type
ORDER BY operation_count DESC, performed_by, au.object_type;

\echo '=== 24. Is seniority related to punctuality? (correlation and regression) ==='
WITH params AS (
    SELECT LOCALTIMESTAMP - INTERVAL '90 days' AS period_from,
           LOCALTIMESTAMP AS period_to,
           INTERVAL '10 minutes' AS late_tolerance,
           10 AS min_arrivals
),
punctuality AS (
    SELECT r.employee_id,
           100.0 * COUNT(*) FILTER (WHERE r.event_time > s.start_time + p.late_tolerance) / COUNT(*)
               AS late_pct
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
    JOIN seniority sn   ON sn.employee_id = pu.employee_id
    JOIN "Employee" e   ON e.employee_id = pu.employee_id
    JOIN "Team" t       ON t.team_id = e.team_id
    JOIN "Department" d ON d.department_id = t.department_id
    JOIN "Branch" b     ON b.branch_id = d.branch_id
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
