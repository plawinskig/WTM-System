# -*- coding: utf-8 -*-
"""
generuj_dane_prosty.py - wypełnia bazę ewidencja_czasu_pracy losowymi danymi.

JAK URUCHOMIĆ
    1. docker compose up -d                 (baza danych musi działać)
    2. pip install -r requirements.txt      (tylko za pierwszym razem)
    3. python generuj_dane_prosty.py

CO ROBI SKRYPT (krok po kroku)
    1. łączy się z bazą i usuwa stare dane ze wszystkich tabel,
    2. wpisuje słowniki: role, uprawnienia, typy umów... (plik slowniki.py),
    3. tworzy oddziały, działy, zespoły, strefy i dni wolne,
    4. tworzy pracowników razem z kontami i umowami,
    5. tworzy grafiki i zmiany,
    6. losuje nieobecności (urlopy, L4...) i deklaracje dostępności,
    7. przydziela pracowników do zmian,
    8. tworzy rejestracje czasu pracy (wejścia, przerwy, wyjścia),
    9. dopisuje wpisy do dziennika zmian (Audit),
   10. zapisuje wszystko w bazie i pokazuje, ile rekordów jest w tabelach.

Za każdym uruchomieniem dane są inne, bo losowanie zaczyna się od innej liczby
(tzw. ziarna). Ziarno jest wypisywane na ekranie. Jeśli wpiszesz je w ZIARNO,
dostaniesz dokładnie te same dane jeszcze raz.

Biblioteki:
    SQLAlchemy - ORM: zamiast pisać INSERT-y tworzymy obiekty Pythona (plik modele.py),
    Faker      - losowe, ale realistyczne imiona, nazwiska i adresy.
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

import slowniki
from modele import (Absence, AbsenceType, Account, Annex, Assignment, Audit,
                    Availability, Branch, Contract, ContractType, DayOff, Department,
                    Employee, Permission, Position, Registration, Role, Schedule,
                    Shift, Team, Zone)

# =============================================================================
# USTAWIENIA - te wartości można zmieniać
# =============================================================================
LICZBA_PRACOWNIKOW = 100      # razem z prezesem, dyrektorami i kierownikami
LICZBA_ODDZIALOW = 2          # pierwszy oddział to zawsze centrala
MIESIECY_WSTECZ = 2           # ile pełnych miesięcy przed bieżącym ma mieć grafiki
ZIARNO = None                 # None = za każdym razem inne dane, np. 1234 = zawsze te same

# połączenie z bazą (tak jak w compose.yaml); hasło jest czytane z pliku .env
HOST = "127.0.0.1"
PORT = 55432
UZYTKOWNIK = "projektowaniebazdanych"
NAZWA_BAZY = "ewidencja_czasu_pracy"

HASLO_TESTOWE = "Test123!"    # hasło do wszystkich wygenerowanych kont
DOMENA_EMAIL = "firma.pl"
DLUGOSC_ZMIANY = 8            # każda zmiana trwa 8 godzin

# kolejność tabel - używana przy czyszczeniu i w podsumowaniu
NAZWY_TABEL = ["Branch", "Department", "Team", "Position", "Zone", "ContractType",
               "AbsenceType", "DayOff", "Role", "Permission", "Employee", "Account",
               "AccountRole", "RolePermission", "BranchDayOff", "Contract", "Annex",
               "Schedule", "Shift", "Assignment", "Availability", "Absence",
               "Registration", "Audit"]

STANOWISKA_KIEROWNICZE = ["Prezes zarządu", "Dyrektor oddziału", "Kierownik działu",
                          "Lider zespołu"]

# generator losowych danych osobowych po polsku
fake = Faker("pl_PL")

# użyte już e-maile i loginy (nie mogą się powtarzać)
uzyte_emaile = set()
uzyte_loginy = set()


# =============================================================================
# FUNKCJE POMOCNICZE
# =============================================================================
def wczytaj_haslo():
    """Szuka pliku .env i zwraca hasło zapisane jako POSTGRES_PASSWORD=..."""
    folder_skryptu = Path(__file__).parent
    mozliwe_pliki = [Path(".env"), folder_skryptu / ".env", folder_skryptu.parent / ".env"]
    for plik in mozliwe_pliki:
        if plik.exists():
            for linia in plik.read_text(encoding="utf-8").splitlines():
                if linia.startswith("POSTGRES_PASSWORD="):
                    return linia.replace("POSTGRES_PASSWORD=", "").strip()
    print("Nie znaleziono pliku .env z hasłem (POSTGRES_PASSWORD=...).")
    print("Umieść plik .env w folderze projektu albo obok tego skryptu.")
    sys.exit(1)


def losowa_data(od, do):
    """Losowy dzień z przedziału od ... do (razem z końcami)."""
    liczba_dni = (do - od).days
    return od + timedelta(days=random.randint(0, liczba_dni))


def nastepny_miesiac(pierwszy_dzien):
    """Dla 1. dnia miesiąca zwraca 1. dzień następnego miesiąca."""
    if pierwszy_dzien.month == 12:
        return date(pierwszy_dzien.year + 1, 1, 1)
    return date(pierwszy_dzien.year, pierwszy_dzien.month + 1, 1)


def poprzedni_miesiac(pierwszy_dzien):
    """Dla 1. dnia miesiąca zwraca 1. dzień poprzedniego miesiąca."""
    if pierwszy_dzien.month == 1:
        return date(pierwszy_dzien.year - 1, 12, 1)
    return date(pierwszy_dzien.year, pierwszy_dzien.month - 1, 1)


def bez_polskich_znakow(tekst):
    """'Łukasz Żak' -> 'lukaszzak' (do e-maili i loginów)."""
    zamiana = {"ą": "a", "ć": "c", "ę": "e", "ł": "l", "ń": "n",
               "ó": "o", "ś": "s", "ź": "z", "ż": "z"}
    wynik = ""
    for znak in tekst.lower():
        if znak in zamiana:
            wynik = wynik + zamiana[znak]
        elif znak in "abcdefghijklmnopqrstuvwxyz":
            wynik = wynik + znak
        # pozostałe znaki (spacje, myślniki) pomijamy
    return wynik


def zaszyfruj_haslo():
    """Zwraca skrót hasła testowego. Każde konto ma inną 'sól', więc skróty są różne."""
    sol = ""
    for i in range(8):
        sol = sol + random.choice("abcdefghijklmnopqrstuvwxyz0123456789")
    skrot = hashlib.sha256((sol + HASLO_TESTOWE).encode("utf-8")).hexdigest()
    return "sha256$" + sol + "$" + skrot


def etat_w_dniu(pracownik, dzien):
    """Wymiar etatu pracownika w danym dniu albo None, gdy tego dnia nie ma umowy."""
    for umowa in pracownik.contracts:
        umowa_trwa = umowa.start_date <= dzien and (umowa.end_date is None or dzien <= umowa.end_date)
        if umowa_trwa:
            etat = umowa.employment_fraction
            # aneks zmienia etat od dnia effective_from
            for aneks in umowa.annexes:
                if aneks.effective_from <= dzien:
                    etat = aneks.employment_fraction
            return etat
    return None


def o_godzinie(dzien, godzina, minuta=0):
    """Zamienia dzień (date) i godzinę na datę z godziną (datetime)."""
    return datetime(dzien.year, dzien.month, dzien.day, godzina, minuta)


# =============================================================================
# KROK 0: okres, dla którego tworzymy dane
# =============================================================================
def ustal_okres(sesja):
    """Zwraca słownik z najważniejszymi datami.

    Aktualny czas bierzemy z serwera bazy, żeby zgadzał się z NOW() w zapytaniach SQL.
    """
    teraz = sesja.execute(text("SELECT LOCALTIMESTAMP(0)")).scalar()
    dzisiaj = teraz.date()

    biezacy_miesiac = date(dzisiaj.year, dzisiaj.month, 1)
    poczatek = biezacy_miesiac
    for i in range(MIESIECY_WSTECZ):
        poczatek = poprzedni_miesiac(poczatek)
    przyszly_miesiac = nastepny_miesiac(biezacy_miesiac)
    koniec = nastepny_miesiac(przyszly_miesiac) - timedelta(days=1)

    return {
        "teraz": teraz,                        # data i godzina
        "dzisiaj": dzisiaj,
        "poczatek": poczatek,                  # pierwszy dzień z grafikiem
        "przyszly_miesiac": przyszly_miesiac,  # miesiąc z grafikiem roboczym (draft)
        "koniec": koniec,                      # ostatni dzień z grafikiem
    }


# =============================================================================
# KROK 1: czyszczenie tabel
# =============================================================================
def wyczysc_tabele(sesja):
    """Usuwa wszystkie dane z 24 tabel. RESTART IDENTITY sprawia, że numery id
    znowu zaczną się od 1, a CASCADE pozwala usunąć dane powiązane kluczami obcymi."""
    lista_tabel = []
    for nazwa in NAZWY_TABEL:
        lista_tabel.append('work_time."' + nazwa + '"')
    polecenie = "TRUNCATE TABLE " + ", ".join(lista_tabel) + " RESTART IDENTITY CASCADE"
    sesja.execute(text(polecenie))


# =============================================================================
# KROK 2: słowniki (dane wpisane ręcznie w pliku slowniki.py)
# =============================================================================
def dodaj_slowniki(sesja):
    """Zapisuje słowniki do bazy i zwraca je w postaci: nazwa -> obiekt."""
    stanowiska = {}
    for nazwa, opis in slowniki.STANOWISKA.items():
        stanowiska[nazwa] = Position(name=nazwa, description=opis)
        sesja.add(stanowiska[nazwa])

    typy_umow = {}
    for nazwa, opis in slowniki.TYPY_UMOW.items():
        typy_umow[nazwa] = ContractType(name=nazwa, description=opis)
        sesja.add(typy_umow[nazwa])

    typy_nieobecnosci = {}
    for nazwa in slowniki.TYPY_NIEOBECNOSCI:
        typy_nieobecnosci[nazwa] = AbsenceType(name=nazwa)
        sesja.add(typy_nieobecnosci[nazwa])

    uprawnienia = {}
    for nazwa, opis in slowniki.UPRAWNIENIA.items():
        uprawnienia[nazwa] = Permission(permission_name=nazwa, description=opis)
        sesja.add(uprawnienia[nazwa])

    role = {}
    for nazwa_roli in slowniki.ROLE:
        rola = Role(role_name=nazwa_roli)
        # dopisanie uprawnienia do roli = nowy wiersz w tabeli RolePermission
        for nazwa_uprawnienia in slowniki.ROLE_UPRAWNIENIA[nazwa_roli]:
            rola.permissions.append(uprawnienia[nazwa_uprawnienia])
        role[nazwa_roli] = rola
        sesja.add(rola)

    return {"stanowiska": stanowiska, "typy_umow": typy_umow,
            "typy_nieobecnosci": typy_nieobecnosci, "role": role}


# =============================================================================
# KROK 3: oddziały, działy, zespoły, strefy, dni wolne
# =============================================================================
def dodaj_firme(sesja):
    """Tworzy strukturę firmy. Zwraca słownik 'firma', do którego kolejne kroki
    dopisują swoje dane (pracowników, kierowników itd.)."""
    firma = {"oddzialy": [], "dzialy": [], "zespoly": [], "zespol_zarzadu": None}

    miasta = random.sample(slowniki.MIASTA, LICZBA_ODDZIALOW)
    for numer, miasto in enumerate(miasta):
        if numer == 0:
            nazwa_oddzialu = "Centrala - " + miasto
            nazwy_dzialow = slowniki.DZIALY_CENTRALI + [random.choice(slowniki.DZIALY_OPERACYJNE)]
        else:
            nazwa_oddzialu = "Oddział " + miasto
            nazwy_dzialow = random.sample(slowniki.DZIALY_OPERACYJNE, 2)

        adres = fake.street_address() + ", " + fake.postcode() + " " + miasto
        oddzial = Branch(name=nazwa_oddzialu, city=miasto, address=adres)
        sesja.add(oddzial)
        firma["oddzialy"].append(oddzial)

        nazwy_stref = []
        for nazwa_dzialu in nazwy_dzialow:
            dzial = Department(name=nazwa_dzialu, branch=oddzial)
            sesja.add(dzial)
            firma["dzialy"].append(dzial)

            # w centrali, w Administracji, jest też zespół "Zarząd" dla prezesa
            if numer == 0 and nazwa_dzialu == "Administracja":
                zarzad = Team(name="Zarząd", department=dzial)
                sesja.add(zarzad)
                firma["zespol_zarzadu"] = zarzad

            # dwa losowe zespoły w każdym dziale
            profil = slowniki.PROFILE_DZIALOW[nazwa_dzialu]
            for nazwa_zespolu in random.sample(profil["zespoly"], 2):
                zespol = Team(name=nazwa_zespolu, department=dzial)
                sesja.add(zespol)
                firma["zespoly"].append(zespol)

            # zapamiętujemy strefy potrzebne temu działowi (bez powtórzeń)
            for nazwa_strefy in profil["strefy"]:
                if nazwa_strefy not in nazwy_stref:
                    nazwy_stref.append(nazwa_strefy)

        # strefy należą do oddziału, a nie do działu
        for nazwa_strefy in nazwy_stref:
            najmniej, najwiecej = slowniki.POJEMNOSC_STREF.get(nazwa_strefy, (3, 8))
            strefa = Zone(name=nazwa_strefy, capacity=random.randint(najmniej, najwiecej),
                          branch=oddzial)
            sesja.add(strefa)

    return firma


def dodaj_dni_wolne(sesja, firma, czas):
    """Święta (wolne wszędzie) i jeden dzień integracji (tylko w części oddziałów).
    Zapamiętuje, które dni są wolne w każdym oddziale."""
    dni_wolne = {}                     # oddział -> zbiór dat
    for oddzial in firma["oddzialy"]:
        dni_wolne[oddzial] = set()

    # 1. święta z pliku slowniki.py, które wypadają w naszym okresie
    for tekst_daty, nazwa in slowniki.SWIETA:
        dzien = date.fromisoformat(tekst_daty)
        if czas["poczatek"] <= dzien <= czas["koniec"]:
            swieto = DayOff(date=dzien, name=nazwa)
            sesja.add(swieto)
            for oddzial in firma["oddzialy"]:
                oddzial.days_off.append(swieto)      # nowy wiersz w BranchDayOff
                dni_wolne[oddzial].add(dzien)

    # 2. dzień integracji firmy - losowy piątek, który nie jest świętem
    piatki = []
    dzien = czas["poczatek"]
    while dzien <= czas["koniec"]:
        if dzien.weekday() == 4 and dzien not in dni_wolne[firma["oddzialy"][0]]:
            piatki.append(dzien)
        dzien = dzien + timedelta(days=1)
    piatek = random.choice(piatki)
    integracja = DayOff(date=piatek, name="Dzień integracji firmy")
    sesja.add(integracja)
    ile_oddzialow = random.randint(1, len(firma["oddzialy"]))
    for oddzial in random.sample(firma["oddzialy"], ile_oddzialow):
        oddzial.days_off.append(integracja)
        dni_wolne[oddzial].add(piatek)

    firma["dni_wolne"] = dni_wolne


# =============================================================================
# KROK 4: pracownicy, konta, role, umowy
# =============================================================================
def nowy_pracownik(sesja, sl, czas, zespol, przelozony, stanowisko, nazwy_rol,
                   zatrudniony, zwolniony=None):
    """Tworzy pracownika razem z kontem, rolami i umowami.
    zwolniony - data odejścia z firmy (None = nadal pracuje)."""
    # imię i nazwisko - Faker dba o zgodność płci (Kowalski / Kowalska)
    if random.random() < 0.5:
        imie = fake.first_name_female()
        nazwisko = fake.last_name_female()
    else:
        imie = fake.first_name_male()
        nazwisko = fake.last_name_male()

    # e-mail w postaci imie.nazwisko@firma.pl, bez powtórzeń
    poczatek_emaila = bez_polskich_znakow(imie) + "." + bez_polskich_znakow(nazwisko)
    email = poczatek_emaila + "@" + DOMENA_EMAIL
    numer = 2
    while email in uzyte_emaile:
        email = poczatek_emaila + str(numer) + "@" + DOMENA_EMAIL
        numer = numer + 1
    uzyte_emaile.add(email)

    odszedl = zwolniony is not None
    pracownik = Employee(first_name=imie, last_name=nazwisko, work_email=email,
                         team=zespol, manager=przelozony, archived=odszedl)
    sesja.add(pracownik)

    # login: pierwsza litera imienia + nazwisko, np. jkowalski
    poczatek_loginu = bez_polskich_znakow(imie)[:1] + bez_polskich_znakow(nazwisko)
    login = poczatek_loginu
    numer = 2
    while login in uzyte_loginy:
        login = poczatek_loginu + str(numer)
        numer = numer + 1
    uzyte_loginy.add(login)

    # konto byłego pracownika jest nieaktywne
    konto = Account(employee=pracownik, login=login, password_hash=zaszyfruj_haslo(),
                    active=not odszedl)
    sesja.add(konto)

    # role: każda dopisana rola = nowy wiersz w tabeli AccountRole
    if zespol.department.name == "Kadry i płace":
        nazwy_rol = nazwy_rol + ["Kadry"]
    for nazwa_roli in nazwy_rol:
        konto.roles.append(sl["role"][nazwa_roli])

    dodaj_umowy(sesja, sl, czas, pracownik, stanowisko, zatrudniony, zwolniony)
    return pracownik


def dodaj_umowy(sesja, sl, czas, pracownik, stanowisko, zatrudniony, zwolniony):
    """Umowy następują jedna po drugiej:
         okres próbny (90 dni) -> czas określony (1 rok) -> czas nieokreślony.
    Co dziesiąty zwykły pracownik ma zamiast tego jedną umowę zlecenie."""
    if stanowisko in STANOWISKA_KIEROWNICZE:
        etat = Decimal("1.00")
    else:
        etat = Decimal(random.choice(slowniki.ETATY))

    proba_od = zatrudniony
    proba_do = proba_od + timedelta(days=89)
    okreslona_od = proba_do + timedelta(days=1)
    okreslona_do = okreslona_od + timedelta(days=364)
    nieokreslona_od = okreslona_do + timedelta(days=1)

    if stanowisko not in STANOWISKA_KIEROWNICZE and random.random() < 0.1:
        plan_umow = [["Umowa zlecenie", zatrudniony, None]]
    else:
        plan_umow = [
            ["Umowa o pracę na okres próbny", proba_od, proba_do],
            ["Umowa o pracę na czas określony", okreslona_od, okreslona_do],
            ["Umowa o pracę na czas nieokreślony", nieokreslona_od, None],
        ]

    ostatnia_umowa = None
    for typ, od, do in plan_umow:
        # umowy, które zaczęłyby się dopiero po naszym okresie, jeszcze nie istnieją
        if od > czas["koniec"]:
            break
        # pracownik odszedł, zanim ta umowa by się zaczęła
        if zwolniony is not None and od > zwolniony:
            break
        # pracownik odszedł w trakcie tej umowy - kończy się w dniu odejścia
        if zwolniony is not None and (do is None or do > zwolniony):
            do = zwolniony

        # umowę podpisuje się kilka dni przed rozpoczęciem (ale nie w przyszłości)
        zawarta = od - timedelta(days=random.randint(1, 14))
        if zawarta > czas["dzisiaj"]:
            zawarta = czas["dzisiaj"]

        umowa = Contract(employee=pracownik, contract_type=sl["typy_umow"][typ],
                         position=sl["stanowiska"][stanowisko], conclusion_date=zawarta,
                         start_date=od, end_date=do, employment_fraction=etat)
        sesja.add(umowa)
        ostatnia_umowa = umowa

    # aneks: co czwarta trwająca od pół roku umowa bez końca zmienia wymiar etatu
    if ostatnia_umowa is None or stanowisko in STANOWISKA_KIEROWNICZE:
        return
    pol_roku_temu = czas["dzisiaj"] - timedelta(days=180)
    if ostatnia_umowa.end_date is None and ostatnia_umowa.start_date < pol_roku_temu:
        if random.random() < 0.25:
            od_kiedy = losowa_data(ostatnia_umowa.start_date + timedelta(days=90), czas["dzisiaj"])
            nowy_etat = Decimal(random.choice(["1.00", "0.75", "0.50"]))
            aneks = Annex(contract=ostatnia_umowa, annex_number=1,
                          signed_date=od_kiedy - timedelta(days=7), effective_from=od_kiedy,
                          position=ostatnia_umowa.position, employment_fraction=nowy_etat,
                          end_date=None)
            sesja.add(aneks)


def dodaj_pracownikow(sesja, sl, firma, czas):
    """Tworzy hierarchię: prezes -> dyrektorzy -> kierownicy działów -> liderzy
    -> zwykli pracownicy. Przełożony jest zawsze tworzony przed podwładnym,
    więc w hierarchii nie może powstać cykl (A szefem B, B szefem A)."""
    dzisiaj = czas["dzisiaj"]
    rok = timedelta(days=365)

    # --- prezes (w centrali, w zespole "Zarząd") ---
    prezes = nowy_pracownik(sesja, sl, czas, firma["zespol_zarzadu"], None, "Prezes zarządu",
                            ["Pracownik", "Kierownik", "Administrator"],
                            losowa_data(dzisiaj - 10 * rok, dzisiaj - 6 * rok))
    firma["kadra"] = [prezes]          # prezes i dyrektorzy nie pracują na zmianach

    # --- dyrektorzy oddziałów (centralą kieruje prezes) ---
    dyrektorzy = {firma["oddzialy"][0]: prezes}
    for oddzial in firma["oddzialy"][1:]:
        pierwszy_zespol = oddzial.departments[0].teams[0]
        dyrektor = nowy_pracownik(sesja, sl, czas, pierwszy_zespol, prezes, "Dyrektor oddziału",
                                  ["Pracownik", "Kierownik"],
                                  losowa_data(dzisiaj - 8 * rok, dzisiaj - 3 * rok))
        dyrektorzy[oddzial] = dyrektor
        firma["kadra"].append(dyrektor)

    # --- kierownik każdego działu ---
    firma["kierownicy"] = {}           # dział -> kierownik
    for dzial in firma["dzialy"]:
        zespol = dzial.teams[-1]       # ostatni zespół (na pewno nie "Zarząd")
        role = ["Pracownik", "Kierownik", "Planista grafiku"]
        if dzial.name == "IT":
            role.append("Administrator")
        kierownik = nowy_pracownik(sesja, sl, czas, zespol, dyrektorzy[dzial.branch],
                                   "Kierownik działu", role,
                                   losowa_data(dzisiaj - 7 * rok, dzisiaj - 2 * rok))
        firma["kierownicy"][dzial] = kierownik

    # --- lider każdego zespołu ---
    liderzy = {}                       # zespół -> lider
    for zespol in firma["zespoly"]:
        lider = nowy_pracownik(sesja, sl, czas, zespol, firma["kierownicy"][zespol.department],
                               "Lider zespołu", ["Pracownik", "Kierownik"],
                               losowa_data(dzisiaj - 6 * rok, dzisiaj - 2 * rok))
        liderzy[zespol] = lider

    # --- zwykli pracownicy ---
    # więcej osób trafia do działów z 3 zmianami (magazyn, produkcja) niż do biur
    wagi = []
    for zespol in firma["zespoly"]:
        profil = slowniki.PROFILE_DZIALOW[zespol.department.name]
        wagi.append(len(profil["godziny_zmian"]))

    # kadra kierownicza już istnieje: prezes, dyrektorzy, kierownicy działów, liderzy
    ilu_juz_jest = len(firma["kadra"]) + len(firma["dzialy"]) + len(firma["zespoly"])
    for i in range(LICZBA_PRACOWNIKOW - ilu_juz_jest):
        # random.choices losuje z wagami (większa waga = częściej); [0] to wylosowany zespół
        zespol = random.choices(firma["zespoly"], weights=wagi)[0]
        profil = slowniki.PROFILE_DZIALOW[zespol.department.name]
        stanowisko = random.choice(profil["stanowiska"])

        los = random.random()
        zwolniony = None
        if los < 0.06:
            # były pracownik - odszedł w ostatnim roku
            zatrudniony = losowa_data(dzisiaj - 4 * rok, dzisiaj - rok)
            zwolniony = losowa_data(dzisiaj - timedelta(days=300), dzisiaj - timedelta(days=1))
        elif los < 0.16:
            # nowa osoba - zatrudniona w naszym okresie (czasem dopiero od przyszłego miesiąca)
            zatrudniony = losowa_data(czas["poczatek"], czas["koniec"] - timedelta(days=14))
        else:
            # pracuje od dawna
            zatrudniony = losowa_data(dzisiaj - 7 * rok, czas["poczatek"] - timedelta(days=1))

        nowy_pracownik(sesja, sl, czas, zespol, liderzy[zespol], stanowisko, ["Pracownik"],
                       zatrudniony, zwolniony)

    # konta działu kadr - ich właściciele wpisują np. zwolnienia lekarskie
    firma["konta_kadr"] = []
    for dzial in firma["dzialy"]:
        if dzial.name == "Kadry i płace":
            for zespol in dzial.teams:
                for pracownik in zespol.employees:
                    if not pracownik.archived:
                        firma["konta_kadr"].append(pracownik.account)


# =============================================================================
# KROK 5: grafiki i zmiany
# =============================================================================
def dodaj_zmiany(sesja, dzial, grafik, od, do, firma, zmiany):
    """Tworzy zmiany w grafiku na każdy dzień pracy działu.
    Jeśli podano słownik 'zmiany', zapamiętuje w nim każdą zmianę pod kluczem
    (dział, dzień, numer zmiany) - przyda się przy przydzielaniu pracowników."""
    profil = slowniki.PROFILE_DZIALOW[dzial.name]
    dni_wolne = firma["dni_wolne"][dzial.branch]

    dzien = od
    while dzien <= do:
        # weekday(): 0 = poniedziałek, 5 = sobota, 6 = niedziela
        dzien_pracy = dzien.weekday() < profil["dni_pracy"] and dzien not in dni_wolne
        if dzien_pracy:
            numer_zmiany = 0
            for godzina in profil["godziny_zmian"]:
                poczatek = o_godzinie(dzien, godzina)
                koniec = poczatek + timedelta(hours=DLUGOSC_ZMIANY)
                zmiana = Shift(schedule=grafik, start_time=poczatek, end_time=koniec)
                sesja.add(zmiana)
                if zmiany is not None:
                    zmiany[(dzial, dzien, numer_zmiany)] = zmiana
                numer_zmiany = numer_zmiany + 1
        dzien = dzien + timedelta(days=1)


def dodaj_grafiki(sesja, firma, czas):
    """Każdy dział ma grafik na każdy miesiąc:
       - miesiące miniony i bieżący: grafik opublikowany (published),
         czasem z wcześniejszą, archiwalną wersją 1,
       - przyszły miesiąc: grafik roboczy (draft)."""
    zmiany = {}            # (dział, dzień, numer zmiany) -> zmiana z obowiązującego grafiku
    for dzial in firma["dzialy"]:
        miesiac = czas["poczatek"]
        while miesiac <= czas["przyszly_miesiac"]:
            koniec_miesiaca = nastepny_miesiac(miesiac) - timedelta(days=1)

            if miesiac == czas["przyszly_miesiac"]:
                grafik = Schedule(department=dzial, period_from=miesiac,
                                  period_to=koniec_miesiaca, version_number=1, status="draft")
            elif random.random() < 0.25:
                # grafik był poprawiany: wersja 1 jest w archiwum, obowiązuje wersja 2
                stary = Schedule(department=dzial, period_from=miesiac,
                                 period_to=koniec_miesiaca, version_number=1, status="archived")
                sesja.add(stary)
                dodaj_zmiany(sesja, dzial, stary, miesiac, koniec_miesiaca, firma, None)
                grafik = Schedule(department=dzial, period_from=miesiac,
                                  period_to=koniec_miesiaca, version_number=2,
                                  status="published")
            else:
                grafik = Schedule(department=dzial, period_from=miesiac,
                                  period_to=koniec_miesiaca, version_number=1,
                                  status="published")

            sesja.add(grafik)
            dodaj_zmiany(sesja, dzial, grafik, miesiac, koniec_miesiaca, firma, zmiany)
            miesiac = nastepny_miesiac(miesiac)
    return zmiany


# =============================================================================
# KROK 6: nieobecności i deklaracje dostępności
# =============================================================================
def wszyscy_pracownicy(firma):
    """Lista wszystkich pracowników firmy (zbierana z zespołów)."""
    lista = [firma["kadra"][0]]                 # prezes jest w zespole "Zarząd"
    for zespol in firma["zespoly"]:
        for pracownik in zespol.employees:
            lista.append(pracownik)
    return lista


def dodaj_nieobecnosci(sesja, sl, firma, czas):
    """0-3 nieobecności na pracownika. Nieobecności jednej osoby się nie nakładają.
    Zwraca: pracownik -> zbiór dni, w których jest nieobecny."""
    dni_nieobecnosci = {}
    nazwy_typow = list(slowniki.TYPY_NIEOBECNOSCI.keys())
    wagi = []
    for nazwa in nazwy_typow:
        wagi.append(slowniki.TYPY_NIEOBECNOSCI[nazwa][2])

    for pracownik in wszyscy_pracownicy(firma):
        dni_nieobecnosci[pracownik] = set()
        for i in range(random.randint(0, 3)):
            # losowanie z wagami: częściej urlop wypoczynkowy, rzadziej urlop bezpłatny
            nazwa_typu = random.choices(nazwy_typow, weights=wagi)[0]
            najkrotsza, najdluzsza, waga = slowniki.TYPY_NIEOBECNOSCI[nazwa_typu]
            poczatek = losowa_data(czas["poczatek"], czas["koniec"])
            koniec = poczatek + timedelta(days=random.randint(najkrotsza, najdluzsza) - 1)

            # zwolnienia lekarskiego nie da się zaplanować na przyszłość
            if nazwa_typu == "Zwolnienie lekarskie (L4)" and poczatek > czas["dzisiaj"]:
                continue
            # nieobecność musi przypadać w czasie trwania umowy
            if etat_w_dniu(pracownik, poczatek) is None or etat_w_dniu(pracownik, koniec) is None:
                continue
            # lista dni tej nieobecności
            dni = []
            dzien = poczatek
            while dzien <= koniec:
                dni.append(dzien)
                dzien = dzien + timedelta(days=1)
            # nie może nachodzić na inną nieobecność tej osoby
            koliduje = False
            for dzien in dni:
                if dzien in dni_nieobecnosci[pracownik]:
                    koliduje = True
            if koliduje:
                continue

            # L4 zwykle wpisuje dział kadr, resztę - sam pracownik
            kto_wpisal = pracownik.account
            if nazwa_typu == "Zwolnienie lekarskie (L4)":
                kto_wpisal = random.choice(firma["konta_kadr"])

            # co dziesiąta nieobecność została anulowana
            if random.random() < 0.1:
                status = "cancelled"
            else:
                status = "registered"
                for dzien in dni:
                    dni_nieobecnosci[pracownik].add(dzien)

            sesja.add(Absence(employee=pracownik,
                              absence_type=sl["typy_nieobecnosci"][nazwa_typu],
                              entered_by=kto_wpisal, start_date=poczatek, end_date=koniec,
                              status=status))
    return dni_nieobecnosci


def dodaj_dostepnosc(sesja, firma, czas):
    """Pracownicy deklarują na wybrane dni (w godz. 6-22), czy mogą pracować.
    Zwraca: pracownik -> zbiór dni, w których NIE mogą pracować."""
    dni_niedostepnosci = {}
    for pracownik in wszyscy_pracownicy(firma):
        dni_niedostepnosci[pracownik] = set()
        if pracownik.archived:
            continue
        wybrane_dni = set()
        for i in range(random.randint(0, 3)):
            dzien = losowa_data(czas["dzisiaj"] - timedelta(days=30), czas["koniec"])
            if dzien in wybrane_dni:
                continue                   # jedna deklaracja na dzień
            wybrane_dni.add(dzien)

            moze_pracowac = random.random() < 0.4
            sesja.add(Availability(employee=pracownik, entered_by=pracownik.account,
                                   available_from=o_godzinie(dzien, 6),
                                   available_to=o_godzinie(dzien, 22),
                                   available=moze_pracowac))
            if not moze_pracowac:
                dni_niedostepnosci[pracownik].add(dzien)
    return dni_niedostepnosci


# =============================================================================
# KROK 7: przydziały pracowników do zmian i stref
# =============================================================================
def znajdz_wolna_strefe(strefy, zmiana, zajete_miejsca):
    """Zwraca losową strefę, w której na tej zmianie jest jeszcze wolne miejsce,
    albo None, gdy wszystkie są pełne."""
    kolejnosc = list(strefy)
    random.shuffle(kolejnosc)
    for strefa in kolejnosc:
        klucz = (strefa, zmiana.start_time)
        zajete = zajete_miejsca.get(klucz, 0)
        if zajete < strefa.capacity:
            zajete_miejsca[klucz] = zajete + 1
            return strefa
    return None


def dodaj_przydzialy(sesja, firma, zmiany, dni_nieobecnosci, dni_niedostepnosci, czas):
    """Zasady przydzielania:
    - pracownik pracuje tylko w swoim dziale i w strefach swojego oddziału,
    - przez cały tydzień chodzi na tę samą zmianę (np. 6-14), a co tydzień zmiana
      się zmienia - dzięki temu ma zawsze co najmniej 11 godzin odpoczynku,
    - w tygodniu pracuje najwyżej 5 x etat dni (pełny etat = 5 dni),
    - nie pracuje bez umowy, w czasie nieobecności i w dni zgłoszonej niedostępności,
    - w strefie nie może być więcej osób, niż wynosi jej pojemność.
    Zwraca listę przydziałów do zmian, które już się zaczęły (do rejestracji czasu)."""
    zajete_miejsca = {}           # (strefa, początek zmiany) -> liczba osób
    minione_przydzialy = []
    brak_miejsca = 0

    # poniedziałki wszystkich tygodni w okresie
    poniedzialki = []
    poniedzialek = czas["poczatek"] - timedelta(days=czas["poczatek"].weekday())
    while poniedzialek <= czas["koniec"]:
        poniedzialki.append(poniedzialek)
        poniedzialek = poniedzialek + timedelta(days=7)

    for dzial in firma["dzialy"]:
        profil = slowniki.PROFILE_DZIALOW[dzial.name]
        liczba_rodzajow_zmian = len(profil["godziny_zmian"])

        # strefy, w których może pracować ten dział
        strefy_dzialu = []
        for strefa in dzial.branch.zones:
            if strefa.name in profil["strefy"]:
                strefy_dzialu.append(strefa)

        # pracownicy działu (bez prezesa i dyrektorów)
        pracownicy_dzialu = []
        for zespol in dzial.teams:
            for pracownik in zespol.employees:
                if pracownik not in firma["kadra"]:
                    pracownicy_dzialu.append(pracownik)

        numer_tygodnia = 0
        for poniedzialek in poniedzialki:
            numer_pracownika = 0
            for pracownik in pracownicy_dzialu:
                # 1. na którą zmianę ta osoba chodzi w tym tygodniu (rotacja).
                #    % to reszta z dzielenia - przy 3 rodzajach zmian wychodzi kolejno
                #    0, 1, 2, 0, 1, 2 ... czyli co tydzień inna zmiana (6:00, 14:00, 22:00)
                numer_zmiany = (numer_pracownika + numer_tygodnia) % liczba_rodzajow_zmian
                numer_pracownika = numer_pracownika + 1

                # 2. dni tygodnia, w których dział ma taką zmianę
                dni = []
                for i in range(7):
                    dzien = poniedzialek + timedelta(days=i)
                    if (dzial, dzien, numer_zmiany) in zmiany:
                        dni.append(dzien)

                # 3. ile dni może pracować w tym tygodniu (wg etatu)
                etat = None
                for dzien in dni:
                    etat = etat_w_dniu(pracownik, dzien)
                    if etat is not None:
                        break
                if etat is None:
                    continue                # w tym tygodniu nie ma umowy
                limit_dni = int(5 * etat)   # 1.00 -> 5 dni, 0.75 -> 3 dni, 0.50 -> 2 dni

                # 4. losujemy dni pracy spośród możliwych
                random.shuffle(dni)
                ile_dni = 0
                for dzien in dni:
                    if ile_dni >= limit_dni:
                        break
                    if etat_w_dniu(pracownik, dzien) is None:
                        continue            # tego dnia nie ma umowy
                    if dzien in dni_nieobecnosci[pracownik]:
                        continue            # urlop, L4 ...
                    if dzien in dni_niedostepnosci[pracownik]:
                        continue            # zgłosił, że nie może

                    zmiana = zmiany[(dzial, dzien, numer_zmiany)]
                    strefa = znajdz_wolna_strefe(strefy_dzialu, zmiana, zajete_miejsca)
                    if strefa is None:
                        brak_miejsca = brak_miejsca + 1
                        continue

                    przydzial = Assignment(shift=zmiana, employee=pracownik, zone=strefa)
                    sesja.add(przydzial)
                    ile_dni = ile_dni + 1
                    if zmiana.start_time < czas["teraz"]:
                        minione_przydzialy.append(przydzial)
            numer_tygodnia = numer_tygodnia + 1

    if brak_miejsca > 0:
        print("   (pominięto", brak_miejsca, "przydziałów - brak miejsca w strefach)")
    return minione_przydzialy


# =============================================================================
# KROK 8: rejestracja czasu pracy
# =============================================================================
def dodaj_zdarzenie(sesja, przydzial, rodzaj, kiedy, status):
    """Jedno odbicie karty: rodzaj to work_start, break_start, break_end lub work_end."""
    pracownik = przydzial.employee
    wpisano = kiedy + timedelta(seconds=random.randint(0, 5))   # system zapisuje po chwili
    sesja.add(Registration(employee=pracownik, shift=przydzial.shift,
                           entered_by=pracownik.account, event_type=rodzaj,
                           event_time=kiedy, entry_time=wpisano,
                           verification_status=status))


def dodaj_rejestracje(sesja, minione_przydzialy, czas):
    """Dla każdej rozpoczętej zmiany: wejście, czasem przerwa, wyjście.
    Spóźnienia powyżej 10 minut dostają status 'needs_explanation'.
    Zdarzenia z ostatnich 7 dni nie są jeszcze sprawdzone ('unverified')."""
    teraz = czas["teraz"]
    tydzien_temu = teraz - timedelta(days=7)

    for przydzial in minione_przydzialy:
        zmiana = przydzial.shift
        if zmiana.end_time < tydzien_temu:
            status = "valid"
        else:
            status = "unverified"

        # 1. wejście - zwykle kilka minut przed czasem, czasem spóźnienie
        sekundy = random.randint(0, 59)
        if random.random() < 0.05:
            wejscie = zmiana.start_time + timedelta(minutes=random.randint(11, 40), seconds=sekundy)
            status_wejscia = "needs_explanation"
        else:
            wejscie = zmiana.start_time + timedelta(minutes=random.randint(-10, 2), seconds=sekundy)
            status_wejscia = status
        if wejscie > teraz:
            continue                    # zmiana dopiero się zaczyna
        dodaj_zdarzenie(sesja, przydzial, "work_start", wejscie, status_wejscia)

        # 2. przerwa - mniej więcej w połowie zmiany, odbijana co drugi raz
        if random.random() < 0.5:
            przerwa_od = zmiana.start_time + timedelta(hours=4, minutes=random.randint(0, 30))
            przerwa_do = przerwa_od + timedelta(minutes=random.randint(15, 30))
            if przerwa_do < teraz:
                dodaj_zdarzenie(sesja, przydzial, "break_start", przerwa_od, status)
                dodaj_zdarzenie(sesja, przydzial, "break_end", przerwa_do, status)

        # 3. wyjście - zwykle kilka minut po końcu zmiany
        wyjscie = zmiana.end_time + timedelta(minutes=random.randint(-2, 15),
                                              seconds=random.randint(0, 59))
        if wyjscie < teraz:
            dodaj_zdarzenie(sesja, przydzial, "work_end", wyjscie, status)


# =============================================================================
# KROK 9: dziennik zmian (Audit)
# =============================================================================
def dodaj_audyt(sesja, firma, czas):
    """Wpisy audytu wskazują rekordy po ich numerze id. Numery id nadaje baza
    przy zapisie, dlatego przed tym krokiem wywołujemy sesja.flush()."""
    teraz = czas["teraz"]
    rok_temu = czas["dzisiaj"] - timedelta(days=365)

    # a) publikacja grafików (zrobił ją kierownik działu)
    for grafik in sesja.query(Schedule).all():
        konto_kierownika = firma["kierownicy"][grafik.department].account
        if grafik.status == "published":
            kiedy = o_godzinie(grafik.period_from - timedelta(days=7), 10, random.randint(0, 59))
            sesja.add(Audit(account=konto_kierownika, operation_time=kiedy,
                            operation_type="UPDATE", object_type="Schedule",
                            object_id=grafik.schedule_id, field_name="status",
                            value_before="draft", value_after="published",
                            change_reason="Publikacja grafiku"))
        if grafik.status == "archived":
            kiedy = o_godzinie(grafik.period_from - timedelta(days=3), 9, random.randint(0, 59))
            sesja.add(Audit(account=konto_kierownika, operation_time=kiedy,
                            operation_type="UPDATE", object_type="Schedule",
                            object_id=grafik.schedule_id, field_name="status",
                            value_before="published", value_after="archived",
                            change_reason="Zastąpiony nowszą wersją"))

    # b) umowy zawarte w ostatnim roku (wpisał je dział kadr)
    for umowa in sesja.query(Contract).all():
        if umowa.conclusion_date >= rok_temu:
            kiedy = o_godzinie(umowa.conclusion_date, random.randint(8, 15), random.randint(0, 59))
            if kiedy > teraz:
                kiedy = teraz
            sesja.add(Audit(account=random.choice(firma["konta_kadr"]), operation_time=kiedy,
                            operation_type="INSERT", object_type="Contract",
                            object_id=umowa.contract_id,
                            value_after=umowa.contract_type.name + ", etat " +
                            str(umowa.employment_fraction),
                            change_reason="Zawarcie umowy"))

    # c) pracownicy, którzy odeszli z firmy
    for pracownik in sesja.query(Employee).filter(Employee.archived == True).all():
        ostatnia_umowa = pracownik.contracts[-1]
        kiedy = o_godzinie(ostatnia_umowa.end_date + timedelta(days=1), 8, random.randint(0, 59))
        if kiedy > teraz:
            kiedy = teraz
        sesja.add(Audit(account=random.choice(firma["konta_kadr"]), operation_time=kiedy,
                        operation_type="UPDATE", object_type="Employee",
                        object_id=pracownik.employee_id, field_name="archived",
                        value_before="false", value_after="true",
                        change_reason="Zakończenie współpracy"))

    # d) spóźnienia wykryte automatycznie (bez konta - zrobił to system)
    do_wyjasnienia = sesja.query(Registration).filter(
        Registration.verification_status == "needs_explanation").all()
    for rejestracja in do_wyjasnienia:
        kiedy = rejestracja.event_time + timedelta(hours=1)
        if kiedy > teraz:
            kiedy = teraz
        sesja.add(Audit(account=None, operation_time=kiedy, operation_type="UPDATE",
                        object_type="Registration", object_id=rejestracja.registration_id,
                        field_name="verification_status", value_before="unverified",
                        value_after="needs_explanation",
                        change_reason="Automatyczna kontrola: spóźnienie"))


# =============================================================================
# PODSUMOWANIE
# =============================================================================
def wypisz_podsumowanie(sesja):
    print()
    print("Tabela            Rekordów")
    print("--------------------------")
    razem = 0
    for nazwa in NAZWY_TABEL:
        liczba = sesja.execute(text('SELECT COUNT(*) FROM work_time."' + nazwa + '"')).scalar()
        razem = razem + liczba
        print(nazwa.ljust(16), str(liczba).rjust(9))
    print("--------------------------")
    print("RAZEM".ljust(16), str(razem).rjust(9))


# =============================================================================
# PROGRAM GŁÓWNY
# =============================================================================
def main():
    # 1. ziarno losowania - nowe przy każdym uruchomieniu
    ziarno = ZIARNO
    if ziarno is None:
        ziarno = random.randint(1, 1000000)
    random.seed(ziarno)
    fake.seed_instance(ziarno)
    print("Ziarno losowania:", ziarno, "(wpisz je w ZIARNO, aby powtórzyć te same dane)")

    # 2. połączenie z bazą
    adres = URL.create("postgresql+psycopg", username=UZYTKOWNIK, password=wczytaj_haslo(),
                       host=HOST, port=PORT, database=NAZWA_BAZY)
    silnik = create_engine(adres)
    try:
        with silnik.connect():
            pass
    except Exception as blad:
        print("Nie udało się połączyć z bazą danych:")
        print(blad)
        print("Sprawdź, czy kontener działa (docker compose up -d) i czy hasło w .env jest dobre.")
        sys.exit(1)

    # 3. generowanie danych. Wszystko dzieje się w jednej transakcji:
    #    jeżeli po drodze wystąpi błąd, nic nie zostanie zapisane w bazie.
    with Session(silnik) as sesja:
        czas = ustal_okres(sesja)
        print("Dane od", czas["poczatek"], "do", czas["koniec"], "(dzisiaj:", czas["dzisiaj"], ")")

        print(" 1. Czyszczenie tabel")
        wyczysc_tabele(sesja)
        print(" 2. Słowniki")
        sl = dodaj_slowniki(sesja)
        print(" 3. Oddziały, działy, zespoły, strefy, dni wolne")
        firma = dodaj_firme(sesja)
        dodaj_dni_wolne(sesja, firma, czas)
        print(" 4. Pracownicy, konta i umowy")
        dodaj_pracownikow(sesja, sl, firma, czas)
        print(" 5. Grafiki i zmiany")
        zmiany = dodaj_grafiki(sesja, firma, czas)
        print(" 6. Nieobecności i dostępność")
        dni_nieobecnosci = dodaj_nieobecnosci(sesja, sl, firma, czas)
        dni_niedostepnosci = dodaj_dostepnosc(sesja, firma, czas)
        print(" 7. Przydziały do zmian")
        minione = dodaj_przydzialy(sesja, firma, zmiany, dni_nieobecnosci,
                                   dni_niedostepnosci, czas)
        print(" 8. Rejestracje czasu pracy")
        dodaj_rejestracje(sesja, minione, czas)

        # flush() wysyła dotychczasowe obiekty do bazy (jeszcze bez zatwierdzania),
        # dzięki czemu dostają numery id potrzebne w dzienniku audytu
        sesja.flush()
        print(" 9. Dziennik zmian (Audit)")
        dodaj_audyt(sesja, firma, czas)

        print("10. Zapisywanie w bazie")
        sesja.commit()
        wypisz_podsumowanie(sesja)

    print()
    print("Gotowe. Hasło do wszystkich kont:", HASLO_TESTOWE)


if __name__ == "__main__":
    main()
