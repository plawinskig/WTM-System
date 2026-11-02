ROLES = ["Administrator", "Kierownik", "Planista grafiku", "Kadry", "Pracownik"]

PERMISSIONS = {
    "employees.read": "Przeglądanie danych pracowników",
    "employees.edit": "Dodawanie i edycja danych pracowników",
    "contracts.read": "Przeglądanie umów i aneksów",
    "contracts.edit": "Rejestrowanie umów i aneksów",
    "schedules.read": "Przeglądanie grafików",
    "schedules.edit": "Tworzenie i zmiana grafików",
    "schedules.publish": "Publikowanie grafików",
    "assignments.edit": "Przydzielanie pracowników do zmian",
    "availability.own": "Zgłaszanie własnej dostępności",
    "absences.own": "Zgłaszanie własnych nieobecności",
    "absences.manage": "Rejestrowanie nieobecności pracowników",
    "registrations.own": "Rejestrowanie własnego czasu pracy",
    "registrations.verify": "Sprawdzanie rejestracji czasu pracy",
    "reports.work_time": "Raporty czasu pracy",
    "accounts.manage": "Zarządzanie kontami i rolami",
    "audit.read": "Przeglądanie dziennika zmian",
}

ROLE_PERMISSIONS = {
    "Administrator": list(PERMISSIONS.keys()),
    "Kierownik": ["employees.read", "contracts.read", "schedules.read", "assignments.edit",
                  "absences.manage", "registrations.verify", "reports.work_time"],
    "Planista grafiku": ["schedules.read", "schedules.edit", "schedules.publish",
                         "assignments.edit"],
    "Kadry": ["employees.read", "employees.edit", "contracts.read", "contracts.edit",
              "absences.manage", "reports.work_time"],
    "Pracownik": ["schedules.read", "availability.own", "absences.own",
                  "registrations.own"],
}

CONTRACT_TYPES = {
    "Umowa o pracę na okres próbny": "Umowa o pracę na maksymalnie 3 miesiące",
    "Umowa o pracę na czas określony": "Umowa o pracę do wskazanej daty",
    "Umowa o pracę na czas nieokreślony": "Umowa o pracę bez daty zakończenia",
    "Umowa o pracę na zastępstwo": "Umowa na czas nieobecności innego pracownika",
    "Umowa zlecenie": "Umowa cywilnoprawna",
}

ABSENCE_TYPES = {
    "Urlop wypoczynkowy": (1, 10, 40),
    "Zwolnienie lekarskie (L4)": (2, 10, 25),
    "Urlop na żądanie": (1, 1, 10),
    "Opieka nad dzieckiem": (1, 2, 5),
    "Szkolenie": (1, 3, 8),
    "Delegacja służbowa": (1, 4, 6),
    "Urlop okolicznościowy": (1, 2, 4),
    "Urlop bezpłatny": (3, 7, 2),
}

POSITIONS = {
    "Prezes zarządu": "Kierowanie firmą",
    "Dyrektor oddziału": "Zarządzanie oddziałem",
    "Kierownik działu": "Kierowanie działem i układanie grafików",
    "Lider zespołu": "Koordynacja pracy zespołu",
    "Magazynier": "Przyjęcia i wydania towaru",
    "Operator wózka widłowego": "Obsługa wózka widłowego",
    "Kompletujący zamówienia": "Kompletowanie zamówień",
    "Operator maszyn": "Obsługa linii produkcyjnej",
    "Pracownik produkcji": "Prace pomocnicze na produkcji",
    "Kontroler jakości": "Kontrola jakości wyrobów",
    "Sprzedawca": "Obsługa klientów na sali sprzedaży",
    "Kasjer": "Obsługa kasy",
    "Konsultant infolinii": "Obsługa klientów przez telefon",
    "Spedytor": "Organizacja transportu",
    "Kierowca": "Przewóz towarów",
    "Referent administracyjny": "Obsługa biura",
    "Recepcjonista": "Obsługa recepcji",
    "Specjalista ds. kadr": "Dokumentacja pracownicza",
    "Specjalista ds. płac": "Naliczanie wynagrodzeń",
    "Księgowy": "Prowadzenie księgowości",
    "Specjalista IT": "Pomoc techniczna dla pracowników",
    "Programista": "Tworzenie programów",
}

EMPLOYMENT_FRACTIONS = ["1.00", "1.00", "1.00", "1.00", "1.00", "1.00", "1.00",
                        "0.75", "0.50", "0.50"]

DEPARTMENT_PROFILES = {
    "Magazyn": {
        "teams": ["Przyjęcia towaru", "Wydania", "Kompletacja"],
        "positions": ["Magazynier", "Operator wózka widłowego", "Kompletujący zamówienia"],
        "shift_start_hours": [6, 14, 22],
        "work_days": 6,
        "zones": ["Rampa załadunkowa", "Strefa kompletacji", "Regały wysokiego składowania"],
    },
    "Produkcja": {
        "teams": ["Linia 1", "Linia 2", "Kontrola jakości"],
        "positions": ["Operator maszyn", "Pracownik produkcji", "Kontroler jakości"],
        "shift_start_hours": [6, 14, 22],
        "work_days": 6,
        "zones": ["Hala produkcyjna A", "Hala produkcyjna B", "Laboratorium"],
    },
    "Sprzedaż": {
        "teams": ["Sprzedaż detaliczna", "Kasy", "Ekspozycja"],
        "positions": ["Sprzedawca", "Kasjer"],
        "shift_start_hours": [6, 14],
        "work_days": 6,
        "zones": ["Sala sprzedaży", "Strefa kas"],
    },
    "Obsługa klienta": {
        "teams": ["Infolinia", "Reklamacje", "Czat"],
        "positions": ["Konsultant infolinii"],
        "shift_start_hours": [6, 14],
        "work_days": 6,
        "zones": ["Call center"],
    },
    "Logistyka": {
        "teams": ["Spedycja", "Transport", "Planowanie dostaw"],
        "positions": ["Spedytor", "Kierowca"],
        "shift_start_hours": [6, 14],
        "work_days": 6,
        "zones": ["Biuro spedycji", "Plac manewrowy"],
    },
    "Administracja": {
        "teams": ["Sekretariat", "Zaopatrzenie"],
        "positions": ["Referent administracyjny", "Recepcjonista"],
        "shift_start_hours": [8],
        "work_days": 5,
        "zones": ["Biuro - open space", "Recepcja"],
    },
    "Kadry i płace": {
        "teams": ["Kadry", "Płace"],
        "positions": ["Specjalista ds. kadr", "Specjalista ds. płac"],
        "shift_start_hours": [8],
        "work_days": 5,
        "zones": ["Biuro - open space"],
    },
    "Księgowość": {
        "teams": ["Należności", "Zobowiązania"],
        "positions": ["Księgowy"],
        "shift_start_hours": [8],
        "work_days": 5,
        "zones": ["Biuro - open space"],
    },
    "IT": {
        "teams": ["Helpdesk", "Rozwój aplikacji"],
        "positions": ["Specjalista IT", "Programista"],
        "shift_start_hours": [8],
        "work_days": 5,
        "zones": ["Biuro - open space", "Serwerownia"],
    },
}

HEADQUARTERS_DEPARTMENTS = ["Administracja", "Kadry i płace", "Księgowość", "IT"]
OPERATIONAL_DEPARTMENTS = ["Magazyn", "Produkcja", "Sprzedaż", "Obsługa klienta", "Logistyka"]

ZONE_CAPACITY = {
    "Biuro - open space": (25, 40),
    "Recepcja": (2, 3),
    "Serwerownia": (2, 4),
}

CITIES = ["Warszawa", "Kraków", "Wrocław", "Poznań", "Gdańsk", "Łódź", "Katowice",
          "Lublin", "Szczecin", "Bydgoszcz", "Rzeszów", "Białystok", "Toruń", "Kielce"]

PUBLIC_HOLIDAYS = [
    ("2025-01-01", "Nowy Rok"),
    ("2025-01-06", "Święto Trzech Króli"),
    ("2025-04-20", "Wielkanoc"),
    ("2025-04-21", "Poniedziałek Wielkanocny"),
    ("2025-05-01", "Święto Pracy"),
    ("2025-05-03", "Święto Konstytucji 3 Maja"),
    ("2025-06-08", "Zielone Świątki"),
    ("2025-06-19", "Boże Ciało"),
    ("2025-08-15", "Wniebowzięcie Najświętszej Maryi Panny"),
    ("2025-11-01", "Wszystkich Świętych"),
    ("2025-11-11", "Narodowe Święto Niepodległości"),
    ("2025-12-24", "Wigilia Bożego Narodzenia"),
    ("2025-12-25", "Boże Narodzenie (pierwszy dzień)"),
    ("2025-12-26", "Boże Narodzenie (drugi dzień)"),
    ("2026-01-01", "Nowy Rok"),
    ("2026-01-06", "Święto Trzech Króli"),
    ("2026-04-05", "Wielkanoc"),
    ("2026-04-06", "Poniedziałek Wielkanocny"),
    ("2026-05-01", "Święto Pracy"),
    ("2026-05-03", "Święto Konstytucji 3 Maja"),
    ("2026-05-24", "Zielone Świątki"),
    ("2026-06-04", "Boże Ciało"),
    ("2026-08-15", "Wniebowzięcie Najświętszej Maryi Panny"),
    ("2026-11-01", "Wszystkich Świętych"),
    ("2026-11-11", "Narodowe Święto Niepodległości"),
    ("2026-12-24", "Wigilia Bożego Narodzenia"),
    ("2026-12-25", "Boże Narodzenie (pierwszy dzień)"),
    ("2026-12-26", "Boże Narodzenie (drugi dzień)"),
    ("2027-01-01", "Nowy Rok"),
    ("2027-01-06", "Święto Trzech Króli"),
    ("2027-03-28", "Wielkanoc"),
    ("2027-03-29", "Poniedziałek Wielkanocny"),
    ("2027-05-01", "Święto Pracy"),
    ("2027-05-03", "Święto Konstytucji 3 Maja"),
    ("2027-05-16", "Zielone Świątki"),
    ("2027-05-27", "Boże Ciało"),
    ("2027-08-15", "Wniebowzięcie Najświętszej Maryi Panny"),
    ("2027-11-01", "Wszystkich Świętych"),
    ("2027-11-11", "Narodowe Święto Niepodległości"),
    ("2027-12-24", "Wigilia Bożego Narodzenia"),
    ("2027-12-25", "Boże Narodzenie (pierwszy dzień)"),
    ("2027-12-26", "Boże Narodzenie (drugi dzień)"),
]
