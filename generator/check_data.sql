-- =============================================================================
-- sprawdz_dane_prosty.sql
-- Sprawdzenie danych wygenerowanych przez generuj_dane_prosty.py.
--
-- Część 1 pokazuje liczbę rekordów w każdej tabeli.
-- Część 2 to testy. Każde zapytanie szuka BŁĘDNYCH wierszy, więc
-- poprawny wynik każdego testu to: (0 rows) / (0 wierszy).
--
-- Uruchomienie (lub wklejenie do pgAdmin):
--   psql -h 127.0.0.1 -p 55432 -U projektowaniebazdanych -d ewidencja_czasu_pracy -f sprawdz_dane_prosty.sql
-- =============================================================================

SET search_path TO work_time;


-- =============================================================================
-- CZĘŚĆ 1. Liczba rekordów w tabelach
-- =============================================================================
SELECT 'Branch' AS tabela, COUNT(*) AS rekordow FROM "Branch"
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


-- =============================================================================
-- CZĘŚĆ 2. Testy - każde zapytanie powinno zwrócić 0 wierszy
-- =============================================================================

-- Test 1. Cykl w hierarchii: A jest przełożonym B, a B jest przełożonym A.
SELECT a.employee_id, b.employee_id
FROM "Employee" a
JOIN "Employee" b ON a.manager_id = b.employee_id
WHERE b.manager_id = a.employee_id;

-- Test 2. Cykl z trzech osób: A -> B -> C -> A.
SELECT a.employee_id, b.employee_id, c.employee_id
FROM "Employee" a
JOIN "Employee" b ON a.manager_id = b.employee_id
JOIN "Employee" c ON b.manager_id = c.employee_id
WHERE c.manager_id = a.employee_id;

-- Test 3. Pracownik ma dwie zmiany, które trwają w tym samym czasie.
SELECT a1.employee_id, s1.start_time, s2.start_time
FROM "Assignment" a1
JOIN "Shift" s1      ON s1.shift_id = a1.shift_id
JOIN "Assignment" a2 ON a2.employee_id = a1.employee_id
JOIN "Shift" s2      ON s2.shift_id = a2.shift_id
WHERE a1.assignment_id < a2.assignment_id
  AND s1.start_time < s2.end_time
  AND s2.start_time < s1.end_time;

-- Test 4. Między końcem jednej zmiany a początkiem następnej jest mniej niż 11 godzin.
SELECT a1.employee_id, s1.end_time AS koniec_zmiany, s2.start_time AS nastepna_zmiana
FROM "Assignment" a1
JOIN "Shift" s1      ON s1.shift_id = a1.shift_id
JOIN "Assignment" a2 ON a2.employee_id = a1.employee_id
JOIN "Shift" s2      ON s2.shift_id = a2.shift_id
WHERE s2.start_time >= s1.end_time
  AND s2.start_time < s1.end_time + INTERVAL '11 hours';

-- Test 5. Przydział do zmiany w dniu, w którym pracownik ma nieobecność.
SELECT a.employee_id, s.start_time, ab.start_date, ab.end_date
FROM "Assignment" a
JOIN "Shift" s    ON s.shift_id = a.shift_id
JOIN "Absence" ab ON ab.employee_id = a.employee_id
WHERE ab.status = 'registered'
  AND CAST(s.start_time AS DATE) BETWEEN ab.start_date AND ab.end_date;

-- Test 6. Przydział w czasie, w którym pracownik zgłosił, że nie może pracować.
SELECT a.employee_id, s.start_time, av.available_from, av.available_to
FROM "Assignment" a
JOIN "Shift" s         ON s.shift_id = a.shift_id
JOIN "Availability" av ON av.employee_id = a.employee_id
WHERE av.available = FALSE
  AND s.start_time < av.available_to
  AND av.available_from < s.end_time;

-- Test 7. Przydział do zmiany w dniu, w którym pracownik nie miał umowy.
--         (LEFT JOIN szuka pasującej umowy; jeśli jej nie ma, contract_id jest pusty)
SELECT a.employee_id, s.start_time
FROM "Assignment" a
JOIN "Shift" s ON s.shift_id = a.shift_id
LEFT JOIN "Contract" c
       ON c.employee_id = a.employee_id
      AND c.start_date <= CAST(s.start_time AS DATE)
      AND (c.end_date IS NULL OR c.end_date >= CAST(s.start_time AS DATE))
WHERE c.contract_id IS NULL;

-- Test 8. W strefie jest więcej osób, niż wynosi jej pojemność.
SELECT z.name AS strefa, s.start_time, z.capacity, COUNT(*) AS liczba_osob
FROM "Assignment" a
JOIN "Shift" s ON s.shift_id = a.shift_id
JOIN "Zone" z  ON z.zone_id = a.zone_id
GROUP BY z.zone_id, z.name, z.capacity, s.start_time
HAVING COUNT(*) > z.capacity;

-- Test 9. Pracownik ma więcej niż 5 zmian w jednym tygodniu.
SELECT a.employee_id,
       EXTRACT(YEAR FROM s.start_time) AS rok,
       EXTRACT(WEEK FROM s.start_time) AS tydzien,
       COUNT(*) AS liczba_zmian
FROM "Assignment" a
JOIN "Shift" s ON s.shift_id = a.shift_id
GROUP BY a.employee_id, EXTRACT(YEAR FROM s.start_time), EXTRACT(WEEK FROM s.start_time)
HAVING COUNT(*) > 5;

-- Test 10. Strefa z innego oddziału niż dział, który ułożył grafik.
SELECT a.assignment_id, z.name AS strefa, d.name AS dzial
FROM "Assignment" a
JOIN "Zone" z       ON z.zone_id = a.zone_id
JOIN "Shift" s      ON s.shift_id = a.shift_id
JOIN "Schedule" g   ON g.schedule_id = s.schedule_id
JOIN "Department" d ON d.department_id = g.department_id
WHERE z.branch_id <> d.branch_id;

-- Test 11. Pracownik przydzielony do grafiku innego działu niż jego własny.
SELECT a.assignment_id, e.employee_id
FROM "Assignment" a
JOIN "Employee" e ON e.employee_id = a.employee_id
JOIN "Team" t     ON t.team_id = e.team_id
JOIN "Shift" s    ON s.shift_id = a.shift_id
JOIN "Schedule" g ON g.schedule_id = s.schedule_id
WHERE t.department_id <> g.department_id;

-- Test 12. Przydział do zmiany z archiwalnej (nieobowiązującej) wersji grafiku.
SELECT a.assignment_id, g.schedule_id, g.status
FROM "Assignment" a
JOIN "Shift" s    ON s.shift_id = a.shift_id
JOIN "Schedule" g ON g.schedule_id = s.schedule_id
WHERE g.status = 'archived';

-- Test 13. Dział ma więcej niż jeden opublikowany grafik na ten sam miesiąc.
SELECT department_id, period_from, COUNT(*) AS opublikowanych
FROM "Schedule"
WHERE status = 'published'
GROUP BY department_id, period_from
HAVING COUNT(*) > 1;

-- Test 14. Zmiana zaplanowana w dniu wolnym oddziału.
SELECT s.shift_id, s.start_time, dw.name
FROM "Shift" s
JOIN "Schedule" g       ON g.schedule_id = s.schedule_id
JOIN "Department" d     ON d.department_id = g.department_id
JOIN "BranchDayOff" bdw ON bdw.branch_id = d.branch_id
JOIN "DayOff" dw        ON dw.day_off_id = bdw.day_off_id
WHERE dw.date = CAST(s.start_time AS DATE);

-- Test 15. Dwie zarejestrowane nieobecności tej samej osoby nachodzą na siebie.
SELECT n1.employee_id, n1.start_date, n1.end_date, n2.start_date, n2.end_date
FROM "Absence" n1
JOIN "Absence" n2 ON n2.employee_id = n1.employee_id
WHERE n1.absence_id < n2.absence_id
  AND n1.status = 'registered' AND n2.status = 'registered'
  AND n1.start_date <= n2.end_date
  AND n2.start_date <= n1.end_date;

-- Test 16. Dwie umowy tej samej osoby obowiązują w tym samym czasie.
SELECT u1.employee_id, u1.start_date, u1.end_date, u2.start_date, u2.end_date
FROM "Contract" u1
JOIN "Contract" u2 ON u2.employee_id = u1.employee_id
WHERE u1.contract_id < u2.contract_id
  AND (u1.end_date IS NULL OR u2.start_date <= u1.end_date)
  AND (u2.end_date IS NULL OR u1.start_date <= u2.end_date);

-- Test 17. Umowa podpisana po dniu rozpoczęcia lub aneks spoza okresu umowy.
SELECT contract_id, conclusion_date, start_date
FROM "Contract"
WHERE conclusion_date > start_date;

SELECT an.annex_id, an.effective_from, u.start_date, u.end_date
FROM "Annex" an
JOIN "Contract" u ON u.contract_id = an.contract_id
WHERE an.effective_from < u.start_date
   OR (u.end_date IS NOT NULL AND an.effective_from > u.end_date)
   OR an.signed_date > an.effective_from;

-- Test 18. Aktywne konto osoby, która już nie pracuje (archived = true).
SELECT k.login, e.first_name, e.last_name
FROM "Account" k
JOIN "Employee" e ON e.employee_id = k.employee_id
WHERE e.archived = TRUE AND k.active = TRUE;

-- Test 19. Rejestracja czasu do zmiany, do której pracownik nie był przydzielony.
SELECT r.registration_id, r.employee_id, r.shift_id
FROM "Registration" r
LEFT JOIN "Assignment" a
       ON a.shift_id = r.shift_id
      AND a.employee_id = r.employee_id
WHERE r.shift_id IS NOT NULL
  AND a.assignment_id IS NULL;

-- Test 20. Wyjście z pracy (work_end) bez wcześniejszego wejścia (work_start).
SELECT r.registration_id, r.employee_id, r.shift_id
FROM "Registration" r
LEFT JOIN "Registration" wejscie
       ON wejscie.employee_id = r.employee_id
      AND wejscie.shift_id = r.shift_id
      AND wejscie.event_type = 'work_start'
WHERE r.event_type = 'work_end'
  AND (wejscie.registration_id IS NULL OR wejscie.event_time > r.event_time);

-- Test 21. Zdarzenie z przyszłości albo zapisane w systemie, zanim się wydarzyło.
SELECT registration_id, event_time, entry_time
FROM "Registration"
WHERE event_time > NOW()
   OR entry_time < event_time;
