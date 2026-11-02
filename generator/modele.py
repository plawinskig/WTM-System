# -*- coding: utf-8 -*-
"""
modele.py - opis tabel bazy danych dla biblioteki SQLAlchemy (ORM).

Każda klasa poniżej odpowiada jednej tabeli ze skryptu sql/01_pelny_schemat.sql.
Dzięki temu w programie zamiast pisać INSERT-y tworzymy zwykłe obiekty Pythona, np.:

    oddzial = Branch(name="Oddział Kraków", city="Kraków", address="ul. Długa 1")

a SQLAlchemy sam zamienia je na polecenia INSERT.

relationship() opisuje powiązanie między tabelami. Dzięki niemu można napisać
    dzial.branch = oddzial
zamiast ręcznie przepisywać numer branch_id - SQLAlchemy uzupełni go sam.
"""
from sqlalchemy import (Boolean, Column, Date, DateTime, ForeignKey, Integer,
                        MetaData, Numeric, String, Table, Text)
from sqlalchemy.orm import DeclarativeBase, relationship

# wszystkie tabele leżą w schemacie work_time
SCHEMAT = "work_time"


class Base(DeclarativeBase):
    """Klasa bazowa - po niej dziedziczą wszystkie tabele."""
    metadata = MetaData(schema=SCHEMAT)


# -----------------------------------------------------------------------------
# Tabele łącznikowe (związki wiele-do-wielu). Mają tylko dwa klucze obce,
# więc opisujemy je krócej - jako obiekt Table, a nie jako klasę.
# -----------------------------------------------------------------------------
AccountRole = Table(
    "AccountRole", Base.metadata,
    Column("account_id", Integer, ForeignKey("work_time.Account.account_id"), primary_key=True),
    Column("role_id", Integer, ForeignKey("work_time.Role.role_id"), primary_key=True),
)

RolePermission = Table(
    "RolePermission", Base.metadata,
    Column("role_id", Integer, ForeignKey("work_time.Role.role_id"), primary_key=True),
    Column("permission_id", Integer, ForeignKey("work_time.Permission.permission_id"),
           primary_key=True),
)

BranchDayOff = Table(
    "BranchDayOff", Base.metadata,
    Column("branch_id", Integer, ForeignKey("work_time.Branch.branch_id"), primary_key=True),
    Column("day_off_id", Integer, ForeignKey("work_time.DayOff.day_off_id"), primary_key=True),
)


# -----------------------------------------------------------------------------
# Struktura firmy
# -----------------------------------------------------------------------------
class Branch(Base):
    """Oddział firmy."""
    __tablename__ = "Branch"
    branch_id = Column(Integer, primary_key=True)
    name = Column(String(100), nullable=False)
    city = Column(String(100), nullable=False)
    address = Column(String(200), nullable=False)

    departments = relationship("Department", back_populates="branch")
    zones = relationship("Zone", back_populates="branch")
    # secondary = przez tabelę łącznikową BranchDayOff (wiele-do-wielu)
    days_off = relationship("DayOff", secondary=BranchDayOff, back_populates="branches")


class Department(Base):
    """Dział w oddziale."""
    __tablename__ = "Department"
    department_id = Column(Integer, primary_key=True)
    branch_id = Column(Integer, ForeignKey("work_time.Branch.branch_id"), nullable=False)
    name = Column(String(100), nullable=False)

    branch = relationship("Branch", back_populates="departments")
    teams = relationship("Team", back_populates="department")


class Team(Base):
    """Zespół w dziale."""
    __tablename__ = "Team"
    team_id = Column(Integer, primary_key=True)
    department_id = Column(Integer, ForeignKey("work_time.Department.department_id"),
                           nullable=False)
    name = Column(String(100), nullable=False)

    department = relationship("Department", back_populates="teams")
    employees = relationship("Employee", back_populates="team")


class Position(Base):
    """Stanowisko pracy (słownik)."""
    __tablename__ = "Position"
    position_id = Column(Integer, primary_key=True)
    name = Column(String(100), nullable=False)
    description = Column(Text)


class Zone(Base):
    """Strefa pracy w oddziale, np. rampa, hala, biuro."""
    __tablename__ = "Zone"
    zone_id = Column(Integer, primary_key=True)
    branch_id = Column(Integer, ForeignKey("work_time.Branch.branch_id"), nullable=False)
    name = Column(String(100), nullable=False)
    capacity = Column(Integer, nullable=False)

    branch = relationship("Branch", back_populates="zones")


# -----------------------------------------------------------------------------
# Słowniki
# -----------------------------------------------------------------------------
class ContractType(Base):
    """Rodzaj umowy (słownik)."""
    __tablename__ = "ContractType"
    contract_type_id = Column(Integer, primary_key=True)
    name = Column(String(100), nullable=False)
    description = Column(Text)


class AbsenceType(Base):
    """Rodzaj nieobecności (słownik)."""
    __tablename__ = "AbsenceType"
    absence_type_id = Column(Integer, primary_key=True)
    name = Column(String(100), nullable=False)


class DayOff(Base):
    """Dzień wolny (święto albo dzień wolny w firmie)."""
    __tablename__ = "DayOff"
    day_off_id = Column(Integer, primary_key=True)
    date = Column(Date, nullable=False)
    name = Column(String(100), nullable=False)

    branches = relationship("Branch", secondary=BranchDayOff, back_populates="days_off")


class Role(Base):
    """Rola użytkownika systemu (słownik)."""
    __tablename__ = "Role"
    role_id = Column(Integer, primary_key=True)
    role_name = Column(String(100), nullable=False)

    permissions = relationship("Permission", secondary=RolePermission)


class Permission(Base):
    """Uprawnienie w systemie (słownik)."""
    __tablename__ = "Permission"
    permission_id = Column(Integer, primary_key=True)
    permission_name = Column(String(100), nullable=False)
    description = Column(Text)


# -----------------------------------------------------------------------------
# Pracownicy i konta
# -----------------------------------------------------------------------------
class Employee(Base):
    """Pracownik."""
    __tablename__ = "Employee"
    employee_id = Column(Integer, primary_key=True)
    first_name = Column(String(100), nullable=False)
    last_name = Column(String(100), nullable=False)
    work_email = Column(String(100))
    team_id = Column(Integer, ForeignKey("work_time.Team.team_id"), nullable=False)
    manager_id = Column(Integer, ForeignKey("work_time.Employee.employee_id"))
    archived = Column(Boolean, nullable=False, default=False)

    team = relationship("Team", back_populates="employees")
    # przełożony to też pracownik - tabela jest powiązana sama ze sobą;
    # remote_side mówi, że employee_id jest po stronie przełożonego
    manager = relationship("Employee", remote_side=[employee_id])
    # uselist=False: pracownik ma jedno konto (a nie listę kont)
    account = relationship("Account", back_populates="employee", uselist=False)
    contracts = relationship("Contract", back_populates="employee")


class Account(Base):
    """Konto użytkownika (jedno na pracownika)."""
    __tablename__ = "Account"
    account_id = Column(Integer, primary_key=True)
    employee_id = Column(Integer, ForeignKey("work_time.Employee.employee_id"), nullable=False)
    login = Column(String(100), nullable=False)
    password_hash = Column(String(255), nullable=False)
    active = Column(Boolean, nullable=False, default=True)

    employee = relationship("Employee", back_populates="account")
    roles = relationship("Role", secondary=AccountRole)


# -----------------------------------------------------------------------------
# Umowy i aneksy
# -----------------------------------------------------------------------------
class Contract(Base):
    """Umowa pracownika."""
    __tablename__ = "Contract"
    contract_id = Column(Integer, primary_key=True)
    employee_id = Column(Integer, ForeignKey("work_time.Employee.employee_id"), nullable=False)
    contract_type_id = Column(Integer, ForeignKey("work_time.ContractType.contract_type_id"),
                              nullable=False)
    position_id = Column(Integer, ForeignKey("work_time.Position.position_id"), nullable=False)
    conclusion_date = Column(Date, nullable=False)
    start_date = Column(Date, nullable=False)
    end_date = Column(Date)
    employment_fraction = Column(Numeric(3, 2), nullable=False)

    employee = relationship("Employee", back_populates="contracts")
    contract_type = relationship("ContractType")
    position = relationship("Position")
    annexes = relationship("Annex", back_populates="contract")


class Annex(Base):
    """Aneks do umowy (np. zmiana wymiaru etatu)."""
    __tablename__ = "Annex"
    annex_id = Column(Integer, primary_key=True)
    contract_id = Column(Integer, ForeignKey("work_time.Contract.contract_id"), nullable=False)
    annex_number = Column(Integer, nullable=False)
    signed_date = Column(Date, nullable=False)
    effective_from = Column(Date, nullable=False)
    position_id = Column(Integer, ForeignKey("work_time.Position.position_id"), nullable=False)
    employment_fraction = Column(Numeric(3, 2), nullable=False)
    end_date = Column(Date)

    contract = relationship("Contract", back_populates="annexes")
    position = relationship("Position")


# -----------------------------------------------------------------------------
# Grafiki, zmiany i przydziały
# -----------------------------------------------------------------------------
class Schedule(Base):
    """Grafik działu na jeden miesiąc (może mieć kilka wersji)."""
    __tablename__ = "Schedule"
    schedule_id = Column(Integer, primary_key=True)
    department_id = Column(Integer, ForeignKey("work_time.Department.department_id"),
                           nullable=False)
    period_from = Column(Date, nullable=False)
    period_to = Column(Date, nullable=False)
    version_number = Column(Integer, nullable=False)
    status = Column(String(20), nullable=False)

    department = relationship("Department")


class Shift(Base):
    """Zmiana w grafiku (np. 06:00-14:00 w danym dniu)."""
    __tablename__ = "Shift"
    shift_id = Column(Integer, primary_key=True)
    schedule_id = Column(Integer, ForeignKey("work_time.Schedule.schedule_id"), nullable=False)
    start_time = Column(DateTime, nullable=False)
    end_time = Column(DateTime, nullable=False)

    schedule = relationship("Schedule")


class Assignment(Base):
    """Przydział pracownika do zmiany i strefy."""
    __tablename__ = "Assignment"
    assignment_id = Column(Integer, primary_key=True)
    shift_id = Column(Integer, ForeignKey("work_time.Shift.shift_id"), nullable=False)
    employee_id = Column(Integer, ForeignKey("work_time.Employee.employee_id"), nullable=False)
    zone_id = Column(Integer, ForeignKey("work_time.Zone.zone_id"), nullable=False)

    shift = relationship("Shift")
    employee = relationship("Employee")
    zone = relationship("Zone")


# -----------------------------------------------------------------------------
# Dostępność, nieobecności, rejestracja czasu pracy, audyt
# -----------------------------------------------------------------------------
class Availability(Base):
    """Deklaracja dostępności (available=True) lub niedostępności (False)."""
    __tablename__ = "Availability"
    availability_id = Column(Integer, primary_key=True)
    employee_id = Column(Integer, ForeignKey("work_time.Employee.employee_id"), nullable=False)
    entered_by_account_id = Column(Integer, ForeignKey("work_time.Account.account_id"),
                                   nullable=False)
    available_from = Column(DateTime, nullable=False)
    available_to = Column(DateTime, nullable=False)
    available = Column(Boolean, nullable=False)

    employee = relationship("Employee")
    entered_by = relationship("Account")


class Absence(Base):
    """Nieobecność pracownika (urlop, L4, ...)."""
    __tablename__ = "Absence"
    absence_id = Column(Integer, primary_key=True)
    employee_id = Column(Integer, ForeignKey("work_time.Employee.employee_id"), nullable=False)
    absence_type_id = Column(Integer, ForeignKey("work_time.AbsenceType.absence_type_id"),
                             nullable=False)
    entered_by_account_id = Column(Integer, ForeignKey("work_time.Account.account_id"),
                                   nullable=False)
    start_date = Column(Date, nullable=False)
    end_date = Column(Date, nullable=False)
    status = Column(String(20), nullable=False)

    employee = relationship("Employee")
    absence_type = relationship("AbsenceType")
    entered_by = relationship("Account")


class Registration(Base):
    """Zdarzenie rejestracji czasu pracy (wejście, przerwa, wyjście)."""
    __tablename__ = "Registration"
    registration_id = Column(Integer, primary_key=True)
    employee_id = Column(Integer, ForeignKey("work_time.Employee.employee_id"), nullable=False)
    shift_id = Column(Integer, ForeignKey("work_time.Shift.shift_id"))
    entered_by_account_id = Column(Integer, ForeignKey("work_time.Account.account_id"),
                                   nullable=False)
    event_type = Column(String(20), nullable=False)
    event_time = Column(DateTime, nullable=False)
    entry_time = Column(DateTime, nullable=False)
    verification_status = Column(String(24), nullable=False)

    employee = relationship("Employee")
    shift = relationship("Shift")
    entered_by = relationship("Account")


class Audit(Base):
    """Wpis w dzienniku zmian (kto, kiedy, co zmienił)."""
    __tablename__ = "Audit"
    audit_id = Column(Integer, primary_key=True)
    account_id = Column(Integer, ForeignKey("work_time.Account.account_id"))
    operation_time = Column(DateTime, nullable=False)
    operation_type = Column(String(100), nullable=False)
    object_type = Column(String(100), nullable=False)
    object_id = Column(Integer, nullable=False)
    field_name = Column(String(100))
    value_before = Column(Text)
    value_after = Column(Text)
    change_reason = Column(Text)

    account = relationship("Account")
