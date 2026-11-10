
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
