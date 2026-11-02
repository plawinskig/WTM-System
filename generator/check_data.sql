SET search_path TO work_time;

SELECT 'Branch' AS table_name, COUNT(*) AS row_count FROM "Branch"
UNION ALL SELECT 'Department',     COUNT(*) FROM "Department"
UNION ALL SELECT 'Team',           COUNT(*) FROM "Team"
UNION ALL SELECT 'Position',       COUNT(*) FROM "Position"
UNION ALL SELECT 'Zone',           COUNT(*) FROM "Zone"
UNION ALL SELECT 'ContractType',   COUNT(*) FROM "ContractType"
UNION ALL SELECT 'AbsenceType',    COUNT(*) FROM "AbsenceType"
UNION ALL SELECT 'DayOff',         COUNT(*) FROM "DayOff"
UNION ALL SELECT 'Role',           COUNT(*) FROM "Role"
UNION ALL SELECT 'Permission',     COUNT(*) FROM "Permission"
UNION ALL SELECT 'Employee',       COUNT(*) FROM "Employee"
UNION ALL SELECT 'Account',        COUNT(*) FROM "Account"
UNION ALL SELECT 'AccountRole',    COUNT(*) FROM "AccountRole"
UNION ALL SELECT 'RolePermission', COUNT(*) FROM "RolePermission"
UNION ALL SELECT 'BranchDayOff',   COUNT(*) FROM "BranchDayOff"
UNION ALL SELECT 'Contract',       COUNT(*) FROM "Contract"
UNION ALL SELECT 'Annex',          COUNT(*) FROM "Annex"
UNION ALL SELECT 'Schedule',       COUNT(*) FROM "Schedule"
UNION ALL SELECT 'Shift',          COUNT(*) FROM "Shift"
UNION ALL SELECT 'Assignment',     COUNT(*) FROM "Assignment"
UNION ALL SELECT 'Availability',   COUNT(*) FROM "Availability"
UNION ALL SELECT 'Absence',        COUNT(*) FROM "Absence"
UNION ALL SELECT 'Registration',   COUNT(*) FROM "Registration"
UNION ALL SELECT 'Audit',          COUNT(*) FROM "Audit";

SELECT a.employee_id, b.employee_id
FROM "Employee" a
JOIN "Employee" b ON a.manager_id = b.employee_id
WHERE b.manager_id = a.employee_id;

SELECT a.employee_id, b.employee_id, c.employee_id
FROM "Employee" a
JOIN "Employee" b ON a.manager_id = b.employee_id
JOIN "Employee" c ON b.manager_id = c.employee_id
WHERE c.manager_id = a.employee_id;

SELECT a1.employee_id, s1.start_time, s2.start_time
FROM "Assignment" a1
JOIN "Shift" s1      ON s1.shift_id = a1.shift_id
JOIN "Assignment" a2 ON a2.employee_id = a1.employee_id
JOIN "Shift" s2      ON s2.shift_id = a2.shift_id
WHERE a1.assignment_id < a2.assignment_id
  AND s1.start_time < s2.end_time
  AND s2.start_time < s1.end_time;

SELECT a1.employee_id, s1.end_time AS shift_end, s2.start_time AS next_shift_start
FROM "Assignment" a1
JOIN "Shift" s1      ON s1.shift_id = a1.shift_id
JOIN "Assignment" a2 ON a2.employee_id = a1.employee_id
JOIN "Shift" s2      ON s2.shift_id = a2.shift_id
WHERE s2.start_time >= s1.end_time
  AND s2.start_time < s1.end_time + INTERVAL '11 hours';

SELECT a.employee_id, s.start_time, ab.start_date, ab.end_date
FROM "Assignment" a
JOIN "Shift" s    ON s.shift_id = a.shift_id
JOIN "Absence" ab ON ab.employee_id = a.employee_id
WHERE ab.status = 'registered'
  AND CAST(s.start_time AS DATE) BETWEEN ab.start_date AND ab.end_date;

SELECT a.employee_id, s.start_time, av.available_from, av.available_to
FROM "Assignment" a
JOIN "Shift" s         ON s.shift_id = a.shift_id
JOIN "Availability" av ON av.employee_id = a.employee_id
WHERE av.available = FALSE
  AND s.start_time < av.available_to
  AND av.available_from < s.end_time;

SELECT a.employee_id, s.start_time
FROM "Assignment" a
JOIN "Shift" s ON s.shift_id = a.shift_id
LEFT JOIN "Contract" c
       ON c.employee_id = a.employee_id
      AND c.start_date <= CAST(s.start_time AS DATE)
      AND (c.end_date IS NULL OR c.end_date >= CAST(s.start_time AS DATE))
WHERE c.contract_id IS NULL;

SELECT z.name AS zone_name, s.start_time, z.capacity, COUNT(*) AS people_count
FROM "Assignment" a
JOIN "Shift" s ON s.shift_id = a.shift_id
JOIN "Zone" z  ON z.zone_id = a.zone_id
GROUP BY z.zone_id, z.name, z.capacity, s.start_time
HAVING COUNT(*) > z.capacity;

SELECT a.employee_id,
       EXTRACT(YEAR FROM s.start_time) AS year_number,
       EXTRACT(WEEK FROM s.start_time) AS week_number,
       COUNT(*) AS shift_count
FROM "Assignment" a
JOIN "Shift" s ON s.shift_id = a.shift_id
GROUP BY a.employee_id, EXTRACT(YEAR FROM s.start_time), EXTRACT(WEEK FROM s.start_time)
HAVING COUNT(*) > 5;

SELECT a.assignment_id, z.name AS zone_name, d.name AS department_name
FROM "Assignment" a
JOIN "Zone" z       ON z.zone_id = a.zone_id
JOIN "Shift" s      ON s.shift_id = a.shift_id
JOIN "Schedule" sch ON sch.schedule_id = s.schedule_id
JOIN "Department" d ON d.department_id = sch.department_id
WHERE z.branch_id <> d.branch_id;

SELECT a.assignment_id, e.employee_id
FROM "Assignment" a
JOIN "Employee" e   ON e.employee_id = a.employee_id
JOIN "Team" t       ON t.team_id = e.team_id
JOIN "Shift" s      ON s.shift_id = a.shift_id
JOIN "Schedule" sch ON sch.schedule_id = s.schedule_id
WHERE t.department_id <> sch.department_id;

SELECT a.assignment_id, sch.schedule_id, sch.status
FROM "Assignment" a
JOIN "Shift" s      ON s.shift_id = a.shift_id
JOIN "Schedule" sch ON sch.schedule_id = s.schedule_id
WHERE sch.status = 'archived';

SELECT department_id, period_from, COUNT(*) AS published_count
FROM "Schedule"
WHERE status = 'published'
GROUP BY department_id, period_from
HAVING COUNT(*) > 1;

SELECT s.shift_id, s.start_time, doff.name
FROM "Shift" s
JOIN "Schedule" sch     ON sch.schedule_id = s.schedule_id
JOIN "Department" d     ON d.department_id = sch.department_id
JOIN "BranchDayOff" bdo ON bdo.branch_id = d.branch_id
JOIN "DayOff" doff      ON doff.day_off_id = bdo.day_off_id
WHERE doff.date = CAST(s.start_time AS DATE);

SELECT ab1.employee_id, ab1.start_date, ab1.end_date, ab2.start_date, ab2.end_date
FROM "Absence" ab1
JOIN "Absence" ab2 ON ab2.employee_id = ab1.employee_id
WHERE ab1.absence_id < ab2.absence_id
  AND ab1.status = 'registered' AND ab2.status = 'registered'
  AND ab1.start_date <= ab2.end_date
  AND ab2.start_date <= ab1.end_date;

SELECT c1.employee_id, c1.start_date, c1.end_date, c2.start_date, c2.end_date
FROM "Contract" c1
JOIN "Contract" c2 ON c2.employee_id = c1.employee_id
WHERE c1.contract_id < c2.contract_id
  AND (c1.end_date IS NULL OR c2.start_date <= c1.end_date)
  AND (c2.end_date IS NULL OR c1.start_date <= c2.end_date);

SELECT contract_id, conclusion_date, start_date
FROM "Contract"
WHERE conclusion_date > start_date;

SELECT an.annex_id, an.effective_from, c.start_date, c.end_date
FROM "Annex" an
JOIN "Contract" c ON c.contract_id = an.contract_id
WHERE an.effective_from < c.start_date
   OR (c.end_date IS NOT NULL AND an.effective_from > c.end_date)
   OR an.signed_date > an.effective_from;

SELECT acc.login, e.first_name, e.last_name
FROM "Account" acc
JOIN "Employee" e ON e.employee_id = acc.employee_id
WHERE e.archived = TRUE AND acc.active = TRUE;

SELECT r.registration_id, r.employee_id, r.shift_id
FROM "Registration" r
LEFT JOIN "Assignment" a
       ON a.shift_id = r.shift_id
      AND a.employee_id = r.employee_id
WHERE r.shift_id IS NOT NULL
  AND a.assignment_id IS NULL;

SELECT r.registration_id, r.employee_id, r.shift_id
FROM "Registration" r
LEFT JOIN "Registration" ws
       ON ws.employee_id = r.employee_id
      AND ws.shift_id = r.shift_id
      AND ws.event_type = 'work_start'
WHERE r.event_type = 'work_end'
  AND (ws.registration_id IS NULL OR ws.event_time > r.event_time);

SELECT registration_id, event_time, entry_time
FROM "Registration"
WHERE event_time > NOW()
   OR entry_time < event_time;
