# -*- coding: utf-8 -*-
"""
slowniki.py - dane wpisane ręcznie.

Tabele słownikowe (role, uprawnienia, typy umów, typy nieobecności, stanowiska,
święta) mają mało rekordów i ich zawartość się nie zmienia, więc nie są losowane.
Generator przepisuje je do bazy w takiej postaci jak poniżej.
Można tu dopisywać własne pozycje.
"""

# ----------------------------------------------------------------------------
# Role i uprawnienia
# ----------------------------------------------------------------------------
ROLE = ["Administrator", "Kierownik", "Planista grafiku", "Kadry", "Pracownik"]

# nazwa uprawnienia: opis
UPRAWNIENIA = {
    "pracownicy.odczyt": "Przeglądanie danych pracowników",
    "pracownicy.edycja": "Dodawanie i edycja danych pracowników",
    "umowy.odczyt": "Przeglądanie umów i aneksów",
    "umowy.edycja": "Rejestrowanie umów i aneksów",
    "grafik.odczyt": "Przeglądanie grafików",
    "grafik.edycja": "Tworzenie i zmiana grafików",
    "grafik.publikacja": "Publikowanie grafików",
    "przydzialy.edycja": "Przydzielanie pracowników do zmian",
    "dostepnosc.wlasna": "Zgłaszanie własnej dostępności",
    "nieobecnosci.wlasne": "Zgłaszanie własnych nieobecności",
    "nieobecnosci.zarzadzanie": "Rejestrowanie nieobecności pracowników",
    "rejestracja.wlasna": "Rejestrowanie własnego czasu pracy",
    "rejestracja.weryfikacja": "Sprawdzanie rejestracji czasu pracy",
    "raporty.czas_pracy": "Raporty czasu pracy",
    "konta.zarzadzanie": "Zarządzanie kontami i rolami",
    "audyt.odczyt": "Przeglądanie dziennika zmian",
}

# rola: lista jej uprawnień
ROLE_UPRAWNIENIA = {
    "Administrator": list(UPRAWNIENIA.keys()),      # administrator ma wszystkie
    "Kierownik": ["pracownicy.odczyt", "umowy.odczyt", "grafik.odczyt", "przydzialy.edycja",
                  "nieobecnosci.zarzadzanie", "rejestracja.weryfikacja", "raporty.czas_pracy"],
    "Planista grafiku": ["grafik.odczyt", "grafik.edycja", "grafik.publikacja",
                         "przydzialy.edycja"],
    "Kadry": ["pracownicy.odczyt", "pracownicy.edycja", "umowy.odczyt", "umowy.edycja",
              "nieobecnosci.zarzadzanie", "raporty.czas_pracy"],
    "Pracownik": ["grafik.odczyt", "dostepnosc.wlasna", "nieobecnosci.wlasne",
                  "rejestracja.wlasna"],
}

# ----------------------------------------------------------------------------
# Umowy, nieobecności, stanowiska
# ----------------------------------------------------------------------------
# nazwa: opis
TYPY_UMOW = {
    "Umowa o pracę na okres próbny": "Umowa o pracę na maksymalnie 3 miesiące",
    "Umowa o pracę na czas określony": "Umowa o pracę do wskazanej daty",
    "Umowa o pracę na czas nieokreślony": "Umowa o pracę bez daty zakończenia",
    "Umowa o pracę na zastępstwo": "Umowa na czas nieobecności innego pracownika",
    "Umowa zlecenie": "Umowa cywilnoprawna",
}

# nazwa: (najkrótsza liczba dni, najdłuższa liczba dni, jak często losować)
TYPY_NIEOBECNOSCI = {
    "Urlop wypoczynkowy": (1, 10, 40),
    "Zwolnienie lekarskie (L4)": (2, 10, 25),
    "Urlop na żądanie": (1, 1, 10),
    "Opieka nad dzieckiem": (1, 2, 5),
    "Szkolenie": (1, 3, 8),
    "Delegacja służbowa": (1, 4, 6),
    "Urlop okolicznościowy": (1, 2, 4),
    "Urlop bezpłatny": (3, 7, 2),
}

# nazwa: opis
STANOWISKA = {
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

# Wymiar etatu - losujemy z tej listy. Im więcej razy wartość występuje,
# tym częściej będzie wylosowana (najczęściej pełny etat).
ETATY = ["1.00", "1.00", "1.00", "1.00", "1.00", "1.00", "1.00", "0.75", "0.50", "0.50"]

# ----------------------------------------------------------------------------
# Działy firmy
# ----------------------------------------------------------------------------
# Dla każdego rodzaju działu:
#   zespoly        - z tej listy losujemy nazwy zespołów
#   stanowiska     - stanowiska zwykłych pracowników działu
#   godziny_zmian  - o której zaczynają się zmiany (każda trwa 8 godzin)
#   dni_pracy      - 5 = od poniedziałku do piątku, 6 = od poniedziałku do soboty
#   strefy         - strefy pracy, w których pracują ludzie z tego działu
PROFILE_DZIALOW = {
    "Magazyn": {
        "zespoly": ["Przyjęcia towaru", "Wydania", "Kompletacja"],
        "stanowiska": ["Magazynier", "Operator wózka widłowego", "Kompletujący zamówienia"],
        "godziny_zmian": [6, 14, 22],
        "dni_pracy": 6,
        "strefy": ["Rampa załadunkowa", "Strefa kompletacji", "Regały wysokiego składowania"],
    },
    "Produkcja": {
        "zespoly": ["Linia 1", "Linia 2", "Kontrola jakości"],
        "stanowiska": ["Operator maszyn", "Pracownik produkcji", "Kontroler jakości"],
        "godziny_zmian": [6, 14, 22],
        "dni_pracy": 6,
        "strefy": ["Hala produkcyjna A", "Hala produkcyjna B", "Laboratorium"],
    },
    "Sprzedaż": {
        "zespoly": ["Sprzedaż detaliczna", "Kasy", "Ekspozycja"],
        "stanowiska": ["Sprzedawca", "Kasjer"],
        "godziny_zmian": [6, 14],
        "dni_pracy": 6,
        "strefy": ["Sala sprzedaży", "Strefa kas"],
    },
    "Obsługa klienta": {
        "zespoly": ["Infolinia", "Reklamacje", "Czat"],
        "stanowiska": ["Konsultant infolinii"],
        "godziny_zmian": [6, 14],
        "dni_pracy": 6,
        "strefy": ["Call center"],
    },
    "Logistyka": {
        "zespoly": ["Spedycja", "Transport", "Planowanie dostaw"],
        "stanowiska": ["Spedytor", "Kierowca"],
        "godziny_zmian": [6, 14],
        "dni_pracy": 6,
        "strefy": ["Biuro spedycji", "Plac manewrowy"],
    },
    "Administracja": {
        "zespoly": ["Sekretariat", "Zaopatrzenie"],
        "stanowiska": ["Referent administracyjny", "Recepcjonista"],
        "godziny_zmian": [8],
        "dni_pracy": 5,
        "strefy": ["Biuro - open space", "Recepcja"],
    },
    "Kadry i płace": {
        "zespoly": ["Kadry", "Płace"],
        "stanowiska": ["Specjalista ds. kadr", "Specjalista ds. płac"],
        "godziny_zmian": [8],
        "dni_pracy": 5,
        "strefy": ["Biuro - open space"],
    },
    "Księgowość": {
        "zespoly": ["Należności", "Zobowiązania"],
        "stanowiska": ["Księgowy"],
        "godziny_zmian": [8],
        "dni_pracy": 5,
        "strefy": ["Biuro - open space"],
    },
    "IT": {
        "zespoly": ["Helpdesk", "Rozwój aplikacji"],
        "stanowiska": ["Specjalista IT", "Programista"],
        "godziny_zmian": [8],
        "dni_pracy": 5,
        "strefy": ["Biuro - open space", "Serwerownia"],
    },
}

# działy, które ma każda centrala
DZIALY_CENTRALI = ["Administracja", "Kadry i płace", "Księgowość", "IT"]
# działy, które losujemy dla oddziałów
DZIALY_OPERACYJNE = ["Magazyn", "Produkcja", "Sprzedaż", "Obsługa klienta", "Logistyka"]

# Ile osób mieści się w strefie: (najmniej, najwięcej) - wartość jest losowana.
# Strefy, których tu nie ma, dostają pojemność od 3 do 8 osób.
POJEMNOSC_STREF = {
    "Biuro - open space": (25, 40),
    "Recepcja": (2, 3),
    "Serwerownia": (2, 4),
}

MIASTA = ["Warszawa", "Kraków", "Wrocław", "Poznań", "Gdańsk", "Łódź", "Katowice",
          "Lublin", "Szczecin", "Bydgoszcz", "Rzeszów", "Białystok", "Toruń", "Kielce"]

# ----------------------------------------------------------------------------
# Święta ustawowe w Polsce (data, nazwa) - wolne we wszystkich oddziałach.
# Jeśli skrypt będzie używany w innych latach, wystarczy dopisać kolejny rok.
# ----------------------------------------------------------------------------
SWIETA = [
    # --- 2025 ---
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
    # --- 2026 ---
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
    # --- 2027 ---
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
