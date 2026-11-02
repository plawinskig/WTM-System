# Prosty generator danych – `generator_prosty/`

Skrypt w Pythonie wypełnia bazę **ewidencja_czasu_pracy** (schemat `work_time`) losowymi danymi. Przy ustawieniach domyślnych w bazie pojawia się ok. **17–20 tys. rekordów**. Każde uruchomienie daje inne dane.

## Pliki

| Plik | Co zawiera |
|---|---|
| `generuj_dane_prosty.py` | główny skrypt – kolejne kroki to osobne, opisane funkcje |
| `modele.py` | opis 24 tabel dla SQLAlchemy (ORM) – jedna klasa = jedna tabela |
| `slowniki.py` | dane wpisane ręcznie: role, uprawnienia, typy umów i nieobecności, stanowiska, działy, święta |
| `sprawdz_dane_prosty.sql` | liczba rekordów w tabelach + 21 testów poprawności danych |
| `requirements.txt` | potrzebne biblioteki |

## Uruchomienie

Folder `generator_prosty` umieść w katalogu projektu, obok `compose.yaml` i `.env` (skrypt sam odczyta hasło z `.env`).

```bash
docker compose up -d
cd generator_prosty
pip install -r requirements.txt
python generuj_dane_prosty.py
```

Na początku pliku `generuj_dane_prosty.py` są **USTAWIENIA**:

| Ustawienie | Domyślnie | Znaczenie |
|---|---|---|
| `LICZBA_PRACOWNIKOW` | 100 | liczba pracowników razem z kadrą kierowniczą |
| `LICZBA_ODDZIALOW` | 2 | pierwszy oddział to centrala |
| `MIESIECY_WSTECZ` | 2 | ile miesięcy przed bieżącym ma grafiki (dochodzi bieżący i następny) |
| `ZIARNO` | `None` | `None` = za każdym razem inne dane; liczba = zawsze te same dane |

Skrypt najpierw **usuwa stare dane** ze wszystkich tabel, a potem tworzy nowe. Wszystko odbywa się w jednej transakcji, więc jeśli wystąpi błąd, baza zostanie bez zmian.

## Jak działa (w skrócie)

1. **Słowniki** są przepisywane z pliku `slowniki.py` (nie są losowane).
2. **Struktura firmy:** centrala (Administracja, Kadry i płace, Księgowość, IT + jeden dział operacyjny) i oddziały (2 działy operacyjne). W każdym dziale są 2 zespoły. Strefy pracy należą do oddziałów.
3. **Pracownicy:** prezes → dyrektorzy → kierownicy działów → liderzy zespołów → pracownicy. Przełożony powstaje zawsze przed podwładnym, więc w hierarchii nie ma cykli. Każdy pracownik ma konto z rolami i ciąg umów (próbna → określona → nieokreślona). Ok. 6% to byli pracownicy z nieaktywnym kontem.
4. **Grafiki:** jeden na dział i miesiąc. Miniony i bieżący miesiąc są opublikowane (czasem z archiwalną wersją 1), a następny jest roboczy. Zmiany trwają 8 h i nie ma ich w niedziele ani w dni wolne oddziału.
5. **Przydziały** – każdy pracownik:
   - pracuje tylko w swoim dziale i w strefach swojego oddziału,
   - przez cały tydzień chodzi na tę samą zmianę, co daje co najmniej 11 h odpoczynku,
   - pracuje najwyżej 5 × etat dni w tygodniu,
   - nie dostaje zmian bez umowy, w czasie nieobecności ani w dniu zgłoszonej niedostępności.

   Liczba osób w strefie nie przekracza jej pojemności.
6. **Rejestracje czasu:** wejście, czasem przerwa, wyjście. Spóźnienia powyżej 10 min mają status `needs_explanation`.
7. **Audit:** publikacje grafików, nowe umowy, odejścia pracowników, wykryte spóźnienia.

## Sprawdzenie danych

```bash
psql -h 127.0.0.1 -p 55432 -U projektowaniebazdanych -d ewidencja_czasu_pracy -f sprawdz_dane_prosty.sql
```

Plik zawiera tylko proste zapytania: `SELECT`, `JOIN`, `LEFT JOIN`, `WHERE`, `GROUP BY`, `HAVING`, `UNION ALL`. Działa też w pgAdmin. Każdy test szuka błędnych wierszy, więc poprawny wynik to **0 wierszy**.

Hasło do wszystkich wygenerowanych kont: **`Test123!`**
