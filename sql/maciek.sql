SET search_path TO work_time, public;

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