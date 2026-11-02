# -*- coding: utf-8 -*-
"""
generate_data.py - fills the ewidencja_czasu_pracy database with random data.

HOW TO RUN
    1. docker compose up -d and load sql/01_schema.sql   (see README.md)
    2. pip install -r requirements.txt                    (first time only)
    3. python generate_data.py

WHAT THE SCRIPT DOES (step by step)
    1. connects to the database and deletes old data from all tables,
    2. writes the reference data: roles, permissions, contract types... (reference_data.py),
    3. creates branches, departments, teams, zones and days off,
    4. creates employees together with their accounts and contracts,
    5. creates schedules and shifts,
    6. draws absences (leave, sick leave...) and availability declarations,
    7. assigns employees to shifts,
    8. creates work time registrations (work start, breaks, work end),
    9. adds entries to the change log (Audit),
   10. saves everything to the database and shows how many rows each table has.

The data differ on every run, because the random draws start from a different
number (the so-called seed). The seed is printed on the screen. If you put it in
SEED, you get exactly the same data again.

Libraries:
    SQLAlchemy - ORM: instead of writing INSERTs we create Python objects (models.py),
    Faker      - random but realistic first names, last names and addresses.
"""
import hashlib
import random
import sys
from datetime import date, datetime, timedelta
from decimal import Decimal
from pathlib import Path

from faker import Faker
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL
from sqlalchemy.orm import Session

import reference_data
from models import (Absence, AbsenceType, Account, Annex, Assignment, Audit,
                    Availability, Branch, Contract, ContractType, DayOff, Department,
                    Employee, Permission, Position, Registration, Role, Schedule,
                    Shift, Team, Zone)

# =============================================================================
# SETTINGS - these values can be changed
# =============================================================================
EMPLOYEE_COUNT = 100          # including the CEO, directors and managers
BRANCH_COUNT = 2              # the first branch is always the headquarters
MONTHS_BACK = 2               # how many full months before the current one get schedules
SEED = None                   # None = different data every time, e.g. 1234 = always the same

# database connection (as in compose.yaml); the password is read from the .env file
DB_HOST = "127.0.0.1"
DB_PORT = 55432
DB_USER = "projektowaniebazdanych"
DB_NAME = "ewidencja_czasu_pracy"

TEST_PASSWORD = "Test123!"    # password for all generated accounts
EMAIL_DOMAIN = "firma.pl"
SHIFT_HOURS = 8               # every shift lasts 8 hours

# table order - used when truncating and in the summary
TABLE_NAMES = ["Branch", "Department", "Team", "Position", "Zone", "ContractType",
               "AbsenceType", "DayOff", "Role", "Permission", "Employee", "Account",
               "AccountRole", "RolePermission", "BranchDayOff", "Contract", "Annex",
               "Schedule", "Shift", "Assignment", "Availability", "Absence",
               "Registration", "Audit"]

MANAGEMENT_POSITIONS = ["Prezes zarządu", "Dyrektor oddziału", "Kierownik działu",
                        "Lider zespołu"]

# generator of random personal data in Polish
fake = Faker("pl_PL")

# e-mails and logins already used (they must not repeat)
used_emails = set()
used_logins = set()


# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
def read_db_password():
    """Looks for the .env file and returns the password stored as POSTGRES_PASSWORD=..."""
    script_folder = Path(__file__).parent
    candidate_files = [Path(".env"), script_folder / ".env", script_folder.parent / ".env"]
    for env_file in candidate_files:
        if env_file.exists():
            for line in env_file.read_text(encoding="utf-8").splitlines():
                if line.startswith("POSTGRES_PASSWORD="):
                    return line.replace("POSTGRES_PASSWORD=", "").strip()
    print("Could not find a .env file with the password (POSTGRES_PASSWORD=...).")
    print("Copy .env.example to .env in the repository root and set the password there.")
    sys.exit(1)


def random_date(start, end):
    """A random day between start and end (both included)."""
    day_count = (end - start).days
    return start + timedelta(days=random.randint(0, day_count))


def next_month(first_day):
    """For the 1st day of a month returns the 1st day of the next month."""
    if first_day.month == 12:
        return date(first_day.year + 1, 1, 1)
    return date(first_day.year, first_day.month + 1, 1)


def previous_month(first_day):
    """For the 1st day of a month returns the 1st day of the previous month."""
    if first_day.month == 1:
        return date(first_day.year - 1, 12, 1)
    return date(first_day.year, first_day.month - 1, 1)


def to_ascii_letters(name):
    """'Łukasz Żak' -> 'lukaszzak' (for e-mails and logins)."""
    replacements = {"ą": "a", "ć": "c", "ę": "e", "ł": "l", "ń": "n",
                    "ó": "o", "ś": "s", "ź": "z", "ż": "z"}
    result = ""
    for char in name.lower():
        if char in replacements:
            result = result + replacements[char]
        elif char in "abcdefghijklmnopqrstuvwxyz":
            result = result + char
        # other characters (spaces, hyphens) are skipped
    return result


def hash_test_password():
    """Hash of the test password. Each account gets its own 'salt', so the hashes differ."""
    salt = ""
    for i in range(8):
        salt = salt + random.choice("abcdefghijklmnopqrstuvwxyz0123456789")
    digest = hashlib.sha256((salt + TEST_PASSWORD).encode("utf-8")).hexdigest()
    return "sha256$" + salt + "$" + digest


def employment_fraction_on(employee, day):
    """Employment fraction of the employee on a given day, or None without a contract that day."""
    for contract in employee.contracts:
        contract_active = (contract.start_date <= day
                           and (contract.end_date is None or day <= contract.end_date))
        if contract_active:
            fraction = contract.employment_fraction
            # an annex changes the fraction from its effective_from day
            for annex in contract.annexes:
                if annex.effective_from <= day:
                    fraction = annex.employment_fraction
            return fraction
    return None


def at_time(day, hour, minute=0):
    """Combines a day (date) and a time into a date with a time (datetime)."""
    return datetime(day.year, day.month, day.day, hour, minute)


# =============================================================================
# STEP 0: the period we generate data for
# =============================================================================
def determine_period(session):
    """Returns a dictionary with the most important dates.

    The current time comes from the database server, so it matches NOW() in SQL queries.
    """
    now = session.execute(text("SELECT LOCALTIMESTAMP(0)")).scalar()
    today = now.date()

    current_month = date(today.year, today.month, 1)
    start = current_month
    for i in range(MONTHS_BACK):
        start = previous_month(start)
    upcoming_month = next_month(current_month)
    end = next_month(upcoming_month) - timedelta(days=1)

    return {
        "now": now,                            # date and time
        "today": today,
        "start": start,                        # first day with a schedule
        "upcoming_month": upcoming_month,      # month with a draft schedule
        "end": end,                            # last day with a schedule
    }


# =============================================================================
# STEP 1: truncating tables
# =============================================================================
def truncate_tables(session):
    """Deletes all data from the 24 tables. RESTART IDENTITY makes the id numbers
    start from 1 again, and CASCADE allows deleting data linked by foreign keys."""
    table_list = []
    for name in TABLE_NAMES:
        table_list.append('work_time."' + name + '"')
    statement = "TRUNCATE TABLE " + ", ".join(table_list) + " RESTART IDENTITY CASCADE"
    session.execute(text(statement))


# =============================================================================
# STEP 2: reference data (written by hand in reference_data.py)
# =============================================================================
def add_reference_data(session):
    """Saves the reference data to the database and returns it as: name -> object."""
    positions = {}
    for name, description in reference_data.POSITIONS.items():
        positions[name] = Position(name=name, description=description)
        session.add(positions[name])

    contract_types = {}
    for name, description in reference_data.CONTRACT_TYPES.items():
        contract_types[name] = ContractType(name=name, description=description)
        session.add(contract_types[name])

    absence_types = {}
    for name in reference_data.ABSENCE_TYPES:
        absence_types[name] = AbsenceType(name=name)
        session.add(absence_types[name])

    permissions = {}
    for name, description in reference_data.PERMISSIONS.items():
        permissions[name] = Permission(permission_name=name, description=description)
        session.add(permissions[name])

    roles = {}
    for role_name in reference_data.ROLES:
        role = Role(role_name=role_name)
        # adding a permission to a role = a new row in the RolePermission table
        for permission_name in reference_data.ROLE_PERMISSIONS[role_name]:
            role.permissions.append(permissions[permission_name])
        roles[role_name] = role
        session.add(role)

    return {"positions": positions, "contract_types": contract_types,
            "absence_types": absence_types, "roles": roles}


# =============================================================================
# STEP 3: branches, departments, teams, zones, days off
# =============================================================================
def add_company(session):
    """Creates the company structure. Returns the 'company' dictionary, to which
    the next steps add their data (employees, managers etc.)."""
    company = {"branches": [], "departments": [], "teams": [], "board_team": None}

    cities = random.sample(reference_data.CITIES, BRANCH_COUNT)
    for number, city in enumerate(cities):
        if number == 0:
            branch_name = "Centrala - " + city
            department_names = (reference_data.HEADQUARTERS_DEPARTMENTS
                                + [random.choice(reference_data.OPERATIONAL_DEPARTMENTS)])
        else:
            branch_name = "Oddział " + city
            department_names = random.sample(reference_data.OPERATIONAL_DEPARTMENTS, 2)

        address = fake.street_address() + ", " + fake.postcode() + " " + city
        branch = Branch(name=branch_name, city=city, address=address)
        session.add(branch)
        company["branches"].append(branch)

        zone_names = []
        for department_name in department_names:
            department = Department(name=department_name, branch=branch)
            session.add(department)
            company["departments"].append(department)

            # the headquarters' Administracja department also has a "Zarząd" team for the CEO
            if number == 0 and department_name == "Administracja":
                board = Team(name="Zarząd", department=department)
                session.add(board)
                company["board_team"] = board

            # two random teams in each department
            profile = reference_data.DEPARTMENT_PROFILES[department_name]
            for team_name in random.sample(profile["teams"], 2):
                team = Team(name=team_name, department=department)
                session.add(team)
                company["teams"].append(team)

            # remember the zones this department needs (without duplicates)
            for zone_name in profile["zones"]:
                if zone_name not in zone_names:
                    zone_names.append(zone_name)

        # zones belong to the branch, not to the department
        for zone_name in zone_names:
            min_capacity, max_capacity = reference_data.ZONE_CAPACITY.get(zone_name, (3, 8))
            zone = Zone(name=zone_name, capacity=random.randint(min_capacity, max_capacity),
                        branch=branch)
            session.add(zone)

    return company


def add_days_off(session, company, period):
    """Public holidays (off everywhere) and one company integration day (only in
    some of the branches). Remembers which days are off in each branch."""
    days_off = {}                      # branch -> set of dates
    for branch in company["branches"]:
        days_off[branch] = set()

    # 1. public holidays from reference_data.py that fall within our period
    for date_text, name in reference_data.PUBLIC_HOLIDAYS:
        day = date.fromisoformat(date_text)
        if period["start"] <= day <= period["end"]:
            holiday = DayOff(date=day, name=name)
            session.add(holiday)
            for branch in company["branches"]:
                branch.days_off.append(holiday)      # new row in BranchDayOff
                days_off[branch].add(day)

    # 2. company integration day - a random Friday that is not a holiday
    fridays = []
    day = period["start"]
    while day <= period["end"]:
        if day.weekday() == 4 and day not in days_off[company["branches"][0]]:
            fridays.append(day)
        day = day + timedelta(days=1)
    friday = random.choice(fridays)
    integration_day = DayOff(date=friday, name="Dzień integracji firmy")
    session.add(integration_day)
    branch_count = random.randint(1, len(company["branches"]))
    for branch in random.sample(company["branches"], branch_count):
        branch.days_off.append(integration_day)
        days_off[branch].add(friday)

    company["days_off"] = days_off


# =============================================================================
# STEP 4: employees, accounts, roles, contracts
# =============================================================================
def create_employee(session, ref, period, team, manager, position, role_names,
                    hire_date, leave_date=None):
    """Creates an employee together with an account, roles and contracts.
    leave_date - the day the employee left the company (None = still works here)."""
    # first and last name - Faker keeps the gender consistent (Kowalski / Kowalska)
    if random.random() < 0.5:
        first_name = fake.first_name_female()
        last_name = fake.last_name_female()
    else:
        first_name = fake.first_name_male()
        last_name = fake.last_name_male()

    # e-mail in the form firstname.lastname@firma.pl, without duplicates
    email_prefix = to_ascii_letters(first_name) + "." + to_ascii_letters(last_name)
    email = email_prefix + "@" + EMAIL_DOMAIN
    number = 2
    while email in used_emails:
        email = email_prefix + str(number) + "@" + EMAIL_DOMAIN
        number = number + 1
    used_emails.add(email)

    has_left = leave_date is not None
    employee = Employee(first_name=first_name, last_name=last_name, work_email=email,
                        team=team, manager=manager, archived=has_left)
    session.add(employee)

    # login: first letter of the first name + last name, e.g. jkowalski
    login_prefix = to_ascii_letters(first_name)[:1] + to_ascii_letters(last_name)
    login = login_prefix
    number = 2
    while login in used_logins:
        login = login_prefix + str(number)
        number = number + 1
    used_logins.add(login)

    # a former employee's account is inactive
    account = Account(employee=employee, login=login, password_hash=hash_test_password(),
                      active=not has_left)
    session.add(account)

    # roles: every added role = a new row in the AccountRole table
    if team.department.name == "Kadry i płace":
        role_names = role_names + ["Kadry"]
    for role_name in role_names:
        account.roles.append(ref["roles"][role_name])

    add_contracts(session, ref, period, employee, position, hire_date, leave_date)
    return employee


def add_contracts(session, ref, period, employee, position, hire_date, leave_date):
    """Contracts follow one another:
         probation (90 days) -> fixed term (1 year) -> permanent.
    Every tenth regular employee has a single civil-law contract (umowa zlecenie) instead."""
    if position in MANAGEMENT_POSITIONS:
        fraction = Decimal("1.00")
    else:
        fraction = Decimal(random.choice(reference_data.EMPLOYMENT_FRACTIONS))

    probation_start = hire_date
    probation_end = probation_start + timedelta(days=89)
    fixed_term_start = probation_end + timedelta(days=1)
    fixed_term_end = fixed_term_start + timedelta(days=364)
    permanent_start = fixed_term_end + timedelta(days=1)

    if position not in MANAGEMENT_POSITIONS and random.random() < 0.1:
        contract_plan = [["Umowa zlecenie", hire_date, None]]
    else:
        contract_plan = [
            ["Umowa o pracę na okres próbny", probation_start, probation_end],
            ["Umowa o pracę na czas określony", fixed_term_start, fixed_term_end],
            ["Umowa o pracę na czas nieokreślony", permanent_start, None],
        ]

    last_contract = None
    for contract_type, start, end in contract_plan:
        # contracts that would only start after our period do not exist yet
        if start > period["end"]:
            break
        # the employee left before this contract would start
        if leave_date is not None and start > leave_date:
            break
        # the employee left during this contract - it ends on the leaving day
        if leave_date is not None and (end is None or end > leave_date):
            end = leave_date

        # a contract is signed a few days before it starts (but not in the future)
        signed = start - timedelta(days=random.randint(1, 14))
        if signed > period["today"]:
            signed = period["today"]

        contract = Contract(employee=employee, contract_type=ref["contract_types"][contract_type],
                            position=ref["positions"][position], conclusion_date=signed,
                            start_date=start, end_date=end, employment_fraction=fraction)
        session.add(contract)
        last_contract = contract

    # annex: every fourth open-ended contract running for half a year changes the fraction
    if last_contract is None or position in MANAGEMENT_POSITIONS:
        return
    half_year_ago = period["today"] - timedelta(days=180)
    if last_contract.end_date is None and last_contract.start_date < half_year_ago:
        if random.random() < 0.25:
            effective_from = random_date(last_contract.start_date + timedelta(days=90),
                                         period["today"])
            new_fraction = Decimal(random.choice(["1.00", "0.75", "0.50"]))
            annex = Annex(contract=last_contract, annex_number=1,
                          signed_date=effective_from - timedelta(days=7),
                          effective_from=effective_from,
                          position=last_contract.position, employment_fraction=new_fraction,
                          end_date=None)
            session.add(annex)


def add_employees(session, ref, company, period):
    """Creates the hierarchy: CEO -> directors -> department managers -> team leaders
    -> regular employees. A manager is always created before their subordinates,
    so the hierarchy cannot contain a cycle (A is B's manager, B is A's manager)."""
    today = period["today"]
    year = timedelta(days=365)

    # --- CEO (at the headquarters, in the "Zarząd" team) ---
    ceo = create_employee(session, ref, period, company["board_team"], None, "Prezes zarządu",
                          ["Pracownik", "Kierownik", "Administrator"],
                          random_date(today - 10 * year, today - 6 * year))
    company["executives"] = [ceo]       # the CEO and the directors do not work shifts

    # --- branch directors (the CEO runs the headquarters) ---
    directors = {company["branches"][0]: ceo}
    for branch in company["branches"][1:]:
        first_team = branch.departments[0].teams[0]
        director = create_employee(session, ref, period, first_team, ceo, "Dyrektor oddziału",
                                   ["Pracownik", "Kierownik"],
                                   random_date(today - 8 * year, today - 3 * year))
        directors[branch] = director
        company["executives"].append(director)

    # --- a manager for each department ---
    company["department_managers"] = {}       # department -> manager
    for department in company["departments"]:
        team = department.teams[-1]           # last team (certainly not "Zarząd")
        roles = ["Pracownik", "Kierownik", "Planista grafiku"]
        if department.name == "IT":
            roles.append("Administrator")
        manager = create_employee(session, ref, period, team, directors[department.branch],
                                  "Kierownik działu", roles,
                                  random_date(today - 7 * year, today - 2 * year))
        company["department_managers"][department] = manager

    # --- a leader for each team ---
    leaders = {}                              # team -> leader
    for team in company["teams"]:
        leader = create_employee(session, ref, period, team,
                                 company["department_managers"][team.department],
                                 "Lider zespołu", ["Pracownik", "Kierownik"],
                                 random_date(today - 6 * year, today - 2 * year))
        leaders[team] = leader

    # --- regular employees ---
    # more people go to departments with 3 shifts (warehouse, production) than to offices
    weights = []
    for team in company["teams"]:
        profile = reference_data.DEPARTMENT_PROFILES[team.department.name]
        weights.append(len(profile["shift_start_hours"]))

    # the management already exists: CEO, directors, department managers, leaders
    existing_count = (len(company["executives"]) + len(company["departments"])
                      + len(company["teams"]))
    for i in range(EMPLOYEE_COUNT - existing_count):
        # random.choices draws with weights (higher weight = more often); [0] is the drawn team
        team = random.choices(company["teams"], weights=weights)[0]
        profile = reference_data.DEPARTMENT_PROFILES[team.department.name]
        position = random.choice(profile["positions"])

        draw = random.random()
        leave_date = None
        if draw < 0.06:
            # former employee - left within the last year
            hire_date = random_date(today - 4 * year, today - year)
            leave_date = random_date(today - timedelta(days=300), today - timedelta(days=1))
        elif draw < 0.16:
            # new person - hired within our period (sometimes only from next month)
            hire_date = random_date(period["start"], period["end"] - timedelta(days=14))
        else:
            # has worked here for a long time
            hire_date = random_date(today - 7 * year, period["start"] - timedelta(days=1))

        create_employee(session, ref, period, team, leaders[team], position, ["Pracownik"],
                        hire_date, leave_date)

    # HR department accounts - their owners enter e.g. sick leaves
    company["hr_accounts"] = []
    for department in company["departments"]:
        if department.name == "Kadry i płace":
            for team in department.teams:
                for employee in team.employees:
                    if not employee.archived:
                        company["hr_accounts"].append(employee.account)


# =============================================================================
# STEP 5: schedules and shifts
# =============================================================================
def add_shifts(session, department, schedule, start, end, company, shifts):
    """Creates schedule shifts for every working day of the department.
    If a 'shifts' dictionary is given, stores every shift in it under the key
    (department, day, shift number) - used later when assigning employees."""
    profile = reference_data.DEPARTMENT_PROFILES[department.name]
    days_off = company["days_off"][department.branch]

    day = start
    while day <= end:
        # weekday(): 0 = Monday, 5 = Saturday, 6 = Sunday
        is_work_day = day.weekday() < profile["work_days"] and day not in days_off
        if is_work_day:
            shift_number = 0
            for hour in profile["shift_start_hours"]:
                shift_start = at_time(day, hour)
                shift_end = shift_start + timedelta(hours=SHIFT_HOURS)
                shift = Shift(schedule=schedule, start_time=shift_start, end_time=shift_end)
                session.add(shift)
                if shifts is not None:
                    shifts[(department, day, shift_number)] = shift
                shift_number = shift_number + 1
        day = day + timedelta(days=1)


def add_schedules(session, company, period):
    """Each department has a schedule for every month:
       - past months and the current month: published schedule,
         sometimes with an earlier, archived version 1,
       - next month: draft schedule."""
    shifts = {}            # (department, day, shift number) -> shift from the schedule in force
    for department in company["departments"]:
        month = period["start"]
        while month <= period["upcoming_month"]:
            month_end = next_month(month) - timedelta(days=1)

            if month == period["upcoming_month"]:
                schedule = Schedule(department=department, period_from=month,
                                    period_to=month_end, version_number=1, status="draft")
            elif random.random() < 0.25:
                # the schedule was revised: version 1 is archived, version 2 is in force
                old_schedule = Schedule(department=department, period_from=month,
                                        period_to=month_end, version_number=1,
                                        status="archived")
                session.add(old_schedule)
                add_shifts(session, department, old_schedule, month, month_end, company, None)
                schedule = Schedule(department=department, period_from=month,
                                    period_to=month_end, version_number=2,
                                    status="published")
            else:
                schedule = Schedule(department=department, period_from=month,
                                    period_to=month_end, version_number=1,
                                    status="published")

            session.add(schedule)
            add_shifts(session, department, schedule, month, month_end, company, shifts)
            month = next_month(month)
    return shifts


# =============================================================================
# STEP 6: absences and availability declarations
# =============================================================================
def all_employees(company):
    """List of all company employees (collected from the teams)."""
    employees = [company["executives"][0]]          # the CEO is in the "Zarząd" team
    for team in company["teams"]:
        for employee in team.employees:
            employees.append(employee)
    return employees


def add_absences(session, ref, company, period):
    """0-3 absences per employee. The absences of one person do not overlap.
    Returns: employee -> set of days on which they are absent."""
    absence_days = {}
    type_names = list(reference_data.ABSENCE_TYPES.keys())
    weights = []
    for name in type_names:
        weights.append(reference_data.ABSENCE_TYPES[name][2])

    for employee in all_employees(company):
        absence_days[employee] = set()
        for i in range(random.randint(0, 3)):
            # weighted draw: annual leave more often, unpaid leave less often
            type_name = random.choices(type_names, weights=weights)[0]
            shortest, longest, weight = reference_data.ABSENCE_TYPES[type_name]
            start = random_date(period["start"], period["end"])
            end = start + timedelta(days=random.randint(shortest, longest) - 1)

            # sick leave cannot be planned in advance
            if type_name == "Zwolnienie lekarskie (L4)" and start > period["today"]:
                continue
            # the absence must fall within a contract
            if (employment_fraction_on(employee, start) is None
                    or employment_fraction_on(employee, end) is None):
                continue
            # list of the days of this absence
            days = []
            day = start
            while day <= end:
                days.append(day)
                day = day + timedelta(days=1)
            # it must not overlap another absence of this person
            overlaps = False
            for day in days:
                if day in absence_days[employee]:
                    overlaps = True
            if overlaps:
                continue

            # sick leave is usually entered by HR, everything else by the employee
            entered_by = employee.account
            if type_name == "Zwolnienie lekarskie (L4)":
                entered_by = random.choice(company["hr_accounts"])

            # every tenth absence was cancelled
            if random.random() < 0.1:
                status = "cancelled"
            else:
                status = "registered"
                for day in days:
                    absence_days[employee].add(day)

            session.add(Absence(employee=employee,
                                absence_type=ref["absence_types"][type_name],
                                entered_by=entered_by, start_date=start, end_date=end,
                                status=status))
    return absence_days


def add_availability(session, company, period):
    """Employees declare for chosen days (06:00-22:00) whether they can work.
    Returns: employee -> set of days on which they CANNOT work."""
    unavailable_days = {}
    for employee in all_employees(company):
        unavailable_days[employee] = set()
        if employee.archived:
            continue
        chosen_days = set()
        for i in range(random.randint(0, 3)):
            day = random_date(period["today"] - timedelta(days=30), period["end"])
            if day in chosen_days:
                continue                   # one declaration per day
            chosen_days.add(day)

            can_work = random.random() < 0.4
            session.add(Availability(employee=employee, entered_by=employee.account,
                                     available_from=at_time(day, 6),
                                     available_to=at_time(day, 22),
                                     available=can_work))
            if not can_work:
                unavailable_days[employee].add(day)
    return unavailable_days


# =============================================================================
# STEP 7: assigning employees to shifts and zones
# =============================================================================
def find_free_zone(zones, shift, occupied_places):
    """Returns a random zone that still has a free place on this shift,
    or None when all of them are full."""
    order = list(zones)
    random.shuffle(order)
    for zone in order:
        key = (zone, shift.start_time)
        occupied = occupied_places.get(key, 0)
        if occupied < zone.capacity:
            occupied_places[key] = occupied + 1
            return zone
    return None


def add_assignments(session, company, shifts, absence_days, unavailable_days, period):
    """Assignment rules:
    - an employee works only in their own department and in their branch's zones,
    - for a whole week they work the same shift (e.g. 6-14), and the shift changes
      every week - thanks to that they always have at least 11 hours of rest,
    - in a week they work at most 5 x employment fraction days (full time = 5 days),
    - they do not work without a contract, during an absence or on a declared unavailable day,
    - a zone cannot hold more people than its capacity.
    Returns the list of assignments to shifts that have already started (for registrations)."""
    occupied_places = {}          # (zone, shift start) -> number of people
    past_assignments = []
    no_place_count = 0

    # Mondays of all weeks in the period
    mondays = []
    monday = period["start"] - timedelta(days=period["start"].weekday())
    while monday <= period["end"]:
        mondays.append(monday)
        monday = monday + timedelta(days=7)

    for department in company["departments"]:
        profile = reference_data.DEPARTMENT_PROFILES[department.name]
        shift_type_count = len(profile["shift_start_hours"])

        # zones where this department may work
        department_zones = []
        for zone in department.branch.zones:
            if zone.name in profile["zones"]:
                department_zones.append(zone)

        # employees of the department (without the CEO and the directors)
        department_employees = []
        for team in department.teams:
            for employee in team.employees:
                if employee not in company["executives"]:
                    department_employees.append(employee)

        week_number = 0
        for monday in mondays:
            employee_number = 0
            for employee in department_employees:
                # 1. which shift this person works this week (rotation).
                #    % is the remainder of division - with 3 shift types it gives
                #    0, 1, 2, 0, 1, 2 ... i.e. a different shift every week (6:00, 14:00, 22:00)
                shift_number = (employee_number + week_number) % shift_type_count
                employee_number = employee_number + 1

                # 2. days of the week on which the department has this shift
                days = []
                for i in range(7):
                    day = monday + timedelta(days=i)
                    if (department, day, shift_number) in shifts:
                        days.append(day)

                # 3. how many days they can work this week (by employment fraction)
                fraction = None
                for day in days:
                    fraction = employment_fraction_on(employee, day)
                    if fraction is not None:
                        break
                if fraction is None:
                    continue                # no contract this week
                day_limit = int(5 * fraction)   # 1.00 -> 5 days, 0.75 -> 3 days, 0.50 -> 2 days

                # 4. draw the working days from the possible ones
                random.shuffle(days)
                days_worked = 0
                for day in days:
                    if days_worked >= day_limit:
                        break
                    if employment_fraction_on(employee, day) is None:
                        continue            # no contract that day
                    if day in absence_days[employee]:
                        continue            # leave, sick leave ...
                    if day in unavailable_days[employee]:
                        continue            # declared they cannot work

                    shift = shifts[(department, day, shift_number)]
                    zone = find_free_zone(department_zones, shift, occupied_places)
                    if zone is None:
                        no_place_count = no_place_count + 1
                        continue

                    assignment = Assignment(shift=shift, employee=employee, zone=zone)
                    session.add(assignment)
                    days_worked = days_worked + 1
                    if shift.start_time < period["now"]:
                        past_assignments.append(assignment)
            week_number = week_number + 1

    if no_place_count > 0:
        print("   (skipped", no_place_count, "assignments - no free place in the zones)")
    return past_assignments


# =============================================================================
# STEP 8: work time registration
# =============================================================================
def add_registration_event(session, assignment, event_type, event_time, status):
    """One card swipe: event_type is work_start, break_start, break_end or work_end."""
    employee = assignment.employee
    # the system saves the event a few seconds later
    entered_at = event_time + timedelta(seconds=random.randint(0, 5))
    session.add(Registration(employee=employee, shift=assignment.shift,
                             entered_by=employee.account, event_type=event_type,
                             event_time=event_time, entry_time=entered_at,
                             verification_status=status))


def add_registrations(session, past_assignments, period):
    """For every started shift: work start, sometimes a break, work end.
    Late arrivals of more than 10 minutes get the 'needs_explanation' status.
    Events from the last 7 days are not verified yet ('unverified')."""
    now = period["now"]
    week_ago = now - timedelta(days=7)

    for assignment in past_assignments:
        shift = assignment.shift
        if shift.end_time < week_ago:
            status = "valid"
        else:
            status = "unverified"

        # 1. work start - usually a few minutes early, sometimes late
        seconds = random.randint(0, 59)
        if random.random() < 0.05:
            work_start = shift.start_time + timedelta(minutes=random.randint(11, 40),
                                                      seconds=seconds)
            start_status = "needs_explanation"
        else:
            work_start = shift.start_time + timedelta(minutes=random.randint(-10, 2),
                                                      seconds=seconds)
            start_status = status
        if work_start > now:
            continue                    # the shift is only just starting
        add_registration_event(session, assignment, "work_start", work_start, start_status)

        # 2. break - roughly in the middle of the shift, recorded every other time
        if random.random() < 0.5:
            break_start = shift.start_time + timedelta(hours=4, minutes=random.randint(0, 30))
            break_end = break_start + timedelta(minutes=random.randint(15, 30))
            if break_end < now:
                add_registration_event(session, assignment, "break_start", break_start, status)
                add_registration_event(session, assignment, "break_end", break_end, status)

        # 3. work end - usually a few minutes after the end of the shift
        work_end = shift.end_time + timedelta(minutes=random.randint(-2, 15),
                                              seconds=random.randint(0, 59))
        if work_end < now:
            add_registration_event(session, assignment, "work_end", work_end, status)


# =============================================================================
# STEP 9: change log (Audit)
# =============================================================================
def add_audit_entries(session, company, period):
    """Audit entries point to records by their id. The database assigns the ids
    when saving, which is why session.flush() is called before this step."""
    now = period["now"]
    year_ago = period["today"] - timedelta(days=365)

    # a) schedule publication (done by the department manager)
    for schedule in session.query(Schedule).all():
        manager_account = company["department_managers"][schedule.department].account
        if schedule.status == "published":
            when = at_time(schedule.period_from - timedelta(days=7), 10, random.randint(0, 59))
            session.add(Audit(account=manager_account, operation_time=when,
                              operation_type="UPDATE", object_type="Schedule",
                              object_id=schedule.schedule_id, field_name="status",
                              value_before="draft", value_after="published",
                              change_reason="Publikacja grafiku"))
        if schedule.status == "archived":
            when = at_time(schedule.period_from - timedelta(days=3), 9, random.randint(0, 59))
            session.add(Audit(account=manager_account, operation_time=when,
                              operation_type="UPDATE", object_type="Schedule",
                              object_id=schedule.schedule_id, field_name="status",
                              value_before="published", value_after="archived",
                              change_reason="Zastąpiony nowszą wersją"))

    # b) contracts concluded within the last year (entered by HR)
    for contract in session.query(Contract).all():
        if contract.conclusion_date >= year_ago:
            when = at_time(contract.conclusion_date, random.randint(8, 15), random.randint(0, 59))
            if when > now:
                when = now
            session.add(Audit(account=random.choice(company["hr_accounts"]), operation_time=when,
                              operation_type="INSERT", object_type="Contract",
                              object_id=contract.contract_id,
                              value_after=contract.contract_type.name + ", etat " +
                              str(contract.employment_fraction),
                              change_reason="Zawarcie umowy"))

    # c) employees who left the company
    for employee in session.query(Employee).filter(Employee.archived == True).all():
        last_contract = employee.contracts[-1]
        when = at_time(last_contract.end_date + timedelta(days=1), 8, random.randint(0, 59))
        if when > now:
            when = now
        session.add(Audit(account=random.choice(company["hr_accounts"]), operation_time=when,
                          operation_type="UPDATE", object_type="Employee",
                          object_id=employee.employee_id, field_name="archived",
                          value_before="false", value_after="true",
                          change_reason="Zakończenie współpracy"))

    # d) late arrivals detected automatically (no account - done by the system)
    to_explain = session.query(Registration).filter(
        Registration.verification_status == "needs_explanation").all()
    for registration in to_explain:
        when = registration.event_time + timedelta(hours=1)
        if when > now:
            when = now
        session.add(Audit(account=None, operation_time=when, operation_type="UPDATE",
                          object_type="Registration", object_id=registration.registration_id,
                          field_name="verification_status", value_before="unverified",
                          value_after="needs_explanation",
                          change_reason="Automatyczna kontrola: spóźnienie"))


# =============================================================================
# SUMMARY
# =============================================================================
def print_summary(session):
    print()
    print("Table                 Rows")
    print("--------------------------")
    total = 0
    for name in TABLE_NAMES:
        count = session.execute(text('SELECT COUNT(*) FROM work_time."' + name + '"')).scalar()
        total = total + count
        print(name.ljust(16), str(count).rjust(9))
    print("--------------------------")
    print("TOTAL".ljust(16), str(total).rjust(9))


# =============================================================================
# MAIN PROGRAM
# =============================================================================
def main():
    # 1. random seed - a new one on every run
    seed = SEED
    if seed is None:
        seed = random.randint(1, 1000000)
    random.seed(seed)
    fake.seed_instance(seed)
    print("Random seed:", seed, "(put it in SEED to generate the same data again)")

    # 2. database connection
    url = URL.create("postgresql+psycopg", username=DB_USER, password=read_db_password(),
                     host=DB_HOST, port=DB_PORT, database=DB_NAME)
    engine = create_engine(url)
    try:
        with engine.connect():
            pass
    except Exception as error:
        print("Could not connect to the database:")
        print(error)
        print("Check that the container is running (docker compose up -d)"
              " and that the password in .env is correct.")
        sys.exit(1)

    # 3. data generation. Everything happens in one transaction:
    #    if an error occurs along the way, nothing is saved to the database.
    with Session(engine) as session:
        period = determine_period(session)
        print("Data from", period["start"], "to", period["end"], "(today:", period["today"], ")")

        print(" 1. Truncating tables")
        truncate_tables(session)
        print(" 2. Reference data")
        ref = add_reference_data(session)
        print(" 3. Branches, departments, teams, zones, days off")
        company = add_company(session)
        add_days_off(session, company, period)
        print(" 4. Employees, accounts and contracts")
        add_employees(session, ref, company, period)
        print(" 5. Schedules and shifts")
        shifts = add_schedules(session, company, period)
        print(" 6. Absences and availability")
        absence_days = add_absences(session, ref, company, period)
        unavailable_days = add_availability(session, company, period)
        print(" 7. Shift assignments")
        past_assignments = add_assignments(session, company, shifts, absence_days,
                                           unavailable_days, period)
        print(" 8. Work time registrations")
        add_registrations(session, past_assignments, period)

        # flush() sends the objects created so far to the database (without committing),
        # so they get the id numbers needed in the audit log
        session.flush()
        print(" 9. Change log (Audit)")
        add_audit_entries(session, company, period)

        print("10. Saving to the database")
        session.commit()
        print_summary(session)

    print()
    print("Done. Password for all accounts:", TEST_PASSWORD)


if __name__ == "__main__":
    main()
