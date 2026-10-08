# Instalator dwóch Attili — MK1212, HOST na C: i CLIENT na D:

**Uruchom `MK1212-Setup.exe`, wskaż grę oraz folder z modami i wybierz miejsca
na obie kopie.** Instalator przygotuje osobne katalogi gry, skopiuje wybrane
paczki oraz utworzy skrót do uruchamiania obu klientów. Nie musisz pobierać
ponownie Attili ani ręcznie podmieniać plików.

Zestaw zawiera przypięte oryginalne archiwum Goldberga z odpowiadającym mu kodem
źródłowym i licencjami. Pliki Attili i modów pochodzą z katalogów wskazanych na
Twoim komputerze. To nadal eksperyment z emulowanym LAN: poprawne kopiowanie
plików i testy instalatora nie dowodzą działania konkretnej kampanii MK1212.

## 1. Instalacja krok po kroku

1. Poczekaj na zakończenie pobierania gry i modów przez Steam. Jeżeli zmieniałeś
   ostatnio wybór modów, uruchom raz zwykłą Attilę z działającym MK1212, sprawdź
   menu i zamknij grę. Dzięki temu istniejąca lista modów odpowiada Twojemu wyborowi.
2. Uruchom **`MK1212-Setup.exe`**. Wybierz folder launchera; domyślnie jest to
   **`D:\MK1212\Launcher`**. Sam launcher jest mały, ale jego podfolder `lab`
   mieści także osobne profile, zapisy oraz raporty.
3. W kroku **„Gra Steam i mody”** wskaż folder z `Attila.exe`, a niżej
   **folder z modami**. Możesz użyć całego katalogu Workshop dla Attili albo
   własnego katalogu z paczkami. Przycisk **„Przeglądaj…”** otwiera wybór folderu.
4. Wybierz foldery obu kopii. Domyślne ustawienie odpowiada podziałowi C:/D:
   **HOST — `C:\MK1212\HOST`**, **CLIENT — `D:\MK1212\CLIENT`**.
5. Sprawdź wykryty folder **Sandboxie-Plus**. Jeśli programu brakuje, użyj
   odsyłacza w kreatorze do [oficjalnej strony](https://sandboxie-plus.com/downloads/),
   zainstaluj stabilną wersję x64 i wskaż jej folder. Instalacja sterownika może
   wymagać uprawnień administratora oraz restartu Windowsa. Zrób wymagany restart
   przed przygotowaniem kopii. Sandboxie nie jest dołączone do naszego EXE.
6. Kliknij **„Instaluj”**. Szczegóły pokażą sprawdzanie plików, miejsca,
   kopiowanie gry i modów oraz przygotowanie osobnych profili. Pierwszy przebieg
   może potrwać, zwłaszcza na HDD. Przy błędzie kreator zatrzyma się z komunikatem.
7. Po zakończeniu użyj skrótu **„MK1212 — uruchom obie Attile”** na pulpicie.
   Ścieżki są zapamiętane; nie trzeba wpisywać komend.

Dla instalacji znanej z wcześniejszych logów operatora:

| Pole w instalatorze | Wartość domyślna lub oczekiwana |
| --- | --- |
| Gra Steam | `D:\SteamLibrary\steamapps\common\Total War Attila` |
| Folder modów Workshop | `D:\SteamLibrary\steamapps\workshop\content\325610` |
| Kopia HOST | `C:\MK1212\HOST` |
| Kopia CLIENT | `D:\MK1212\CLIENT` |
| Launcher | `D:\MK1212\Launcher` |
| Sandboxie-Plus | Zwykle `C:\Program Files\Sandboxie-Plus`; wybierz faktyczny folder |

Folder Workshop powyżej wynika ze wskazanej biblioteki Steam; jego istnienie
jest sprawdzane na komputerze. Jeżeli paczki trzymasz gdzie indziej, wybierz ten
katalog. Instalator wymaga 64-bitowego Windowsa i działa w kontekście bieżącego
użytkownika, aby korzystać z jego wyboru modów i profilu.

## 2. Co zostanie skopiowane

HOST i CLIENT dostają **pełne, fizycznie niezależne kopie gry**. Pliki nie są
łączone hardlinkami. Wybrane paczki z Workshop są kopiowane do własnych katalogów
wewnątrz odpowiedniej kopii; zachowane są nazwy i oddzielne katalogi źródłowe.
Każda strona otrzymuje tę samą wybraną listę modów i te same sumy zawartości.

Instalator ustala wybór oraz kolejność z istniejących plików:

- `used_mods.txt` w katalogu gry;
- `scripts\user.script.txt` w profilu Attili, jeżeli zawiera wybór modów.

Wybór folderu z modami wskazuje **skąd brać paczki**. Kolejność nadal pochodzi
z działającej konfiguracji gry. Importer nie układa MK1212 alfabetycznie i nie
włącza wszystkich subskrypcji znalezionych w Workshop. W obrębie wybranych
katalogów zachowuje także towarzyszące pliki `.pack`, ponieważ paczki typu
Movie mogą być widoczne dla gry bez osobnego wpisu `mod`.

Jeżeli ścieżki w liście modów są nieaktualne, importer próbuje odszukać wskazane
paczki **wewnątrz wybranego folderu modów**, z ograniczeniem liczby przeglądanych
plików. Niejednoznaczny wynik, brak paczki, nieobsługiwana dyrektywa modów albo
sprzeczne listy zatrzymują przygotowanie. Nie następuje ciche uruchomienie
podstawowej gry zamiast żądanego MK1212.

Do nowych profili trafiają tylko rozpoznane polecenia modów; oryginały manifestów
zostają zachowane jako dowody. Polecenia automatycznego ładowania zapisu,
generowania kampanii lub wyjścia z gry nie są wykonywane przez importer.

Po udanym przygotowaniu raport zapisuje
`MODS_PREPARED_HASH_MATCHED_RUNTIME_UNVERIFIED`. Oznacza to zgodną przygotowaną
zawartość. **Menu MK1212 w obu oknach trzeba jeszcze sprawdzić w samej grze.**

## 3. Miejsce na C: i D:

Rozmiar jest obliczany z rzeczywistych plików. Na każdym dysku potrzebne jest
miejsce na przypadającą mu kopię gry, importowane paczki i rezerwę. Ścieżki
wskazujące ten sam wolumin współdzielą jeden budżet; program nie liczy tego
samego wolnego miejsca dwukrotnie.

HOST może znajdować się na systemowym C:. Launcher i jego dane robocze mają
pozostać na dysku niesystemowym, domyślnie D:. Jeśli na C: zostało za mało
miejsca, instalator poda wymaganie i zatrzyma kopiowanie. W takim przypadku
trzeba zwolnić miejsce albo wskazać inne miejsce dla HOST.

Pliki kopiowania powstają tymczasowo na tym samym woluminie co dany klient.
Po sprawdzeniu są przenoszone do katalogu docelowego bez dodatkowej pełnej kopii
między C: i D:. Oryginalne pliki Steam oraz źródłowe paczki modów są odczytywane;
zmiany API i konfiguracji dotyczą przygotowanych kopii.

## 4. Uruchomienie i krótki test

Skrót na pulpicie uruchamia obu klientów z zapamiętaną konfiguracją. Podczas
pierwszego testu:

1. Sprawdź, czy **obie** gry pokazują MK1212.
2. Włącz tryb okienkowy; dla wygodnego przełączania można zacząć od 1280 × 720
   i niższych ustawień grafiki.
3. W HOST utwórz lobby multiplayer/LAN, a w CLIENT odszukaj je i dołącz.
4. Potwierdź dwóch graczy o różnych nazwach.
5. Rozpocznij krótką kampanię: sprawdź przejście tury, zapis i ponowne wczytanie.
6. Z menu Start **„MK1212 — dwie Attile”** wybierz **„Zbierz raport”**,
   najlepiej przy nadal uruchomionych procesach.

Raporty trafiają domyślnie do
`D:\MK1212\Launcher\lab\evidence\<czas>-<tryb>-<identyfikator>\report.json`.
Stan laboratorium i dokładne ścieżki profili są zapisywane obok. Piaskownice
nazywają się `MK1212GoldHost` i `MK1212GoldClient`.

Start procesu, wykryte porty i przynależność do piaskownicy są raportowane
oddzielnie od działania lobby. Program nie rozpoznaje przebiegu kampanii na
ekranie. Do raportu dodaj krótko: czy oba okna pokazały MK1212, czy CLIENT
zobaczył HOST i na jakim kroku wystąpił problem.

## 5. Ponowienie instalacji i usuwanie launchera

Instalator zapisuje ścieżki w `installer-settings.json`. Normalne uruchamianie
ze skrótu korzysta z tego pliku. Jeżeli ponawiasz przerwaną instalację, podaj
te same foldery i użyj tego samego wydania instalatora. Kompletny plik jest
wykorzystywany ponownie dopiero po sprawdzeniu zawartości.

Nieznane katalogi, zmienione pliki i częściowe kopie są zachowywane. Program
nie nadpisuje ich w celu ukrycia błędu. Nowe wydanie instalatora nie przejmuje
po cichu istniejącej instalacji innej wersji. Poprzednie laboratoria i nazwy
piaskownic także mają przypisaną własność; przy takim konflikcie zachowaj raport.

Wydanie **0.2.1** ma ograniczone odzyskiwanie ustawień po przerwanym wydaniu
**0.2.0** z kodu `7f66f06afddc53fda220f22d1940242ebd87e4ab`. Dotyczy ono
wyłącznie sytuacji, w której pozostał sam rozpoznany `installer-settings.json`
(ewentualnie pusty plik blokady), a w folderach docelowych nie ma plików
narzędzia, gry ani laboratorium. Instalator zachowuje kopię poprzednich
ustawień przed ich zastąpieniem. Jeżeli zapisany folder launchera różni się od
wskazanego, poprzednia lokalizacja musi być pusta lub nie istnieć. Pozostałe
ścieżki muszą odpowiadać poprzedniemu wyborowi, a obie kopie i oba katalogi
laboratorium muszą być puste lub nie istnieć. Istniejące dane zatrzymują tę
naprawę. Nie jest to migracja gotowego laboratorium między folderami.

Przy `Owned installation path differs: ToolkitRoot` ponów instalację wydaniem
0.2.1, zachowując poprzedni wybór folderów. Szczegóły pokazują ścieżkę wybraną,
zapisaną oraz etap sprawdzania. Jeśli naprawa nie jest możliwa, zachowaj pełny
komunikat z tymi wartościami. Sam wiersz `Temp\\...\\payload` opisuje katalog
rozpakowania EXE, a nie miejsce kopii gry. Pierwotny krótki komunikat nie
wystarcza do rozstrzygnięcia, skąd wzięła się różnica ścieżek.

Opcja **„Odinstaluj launcher”** usuwa zweryfikowane pliki narzędzia, jego skróty
i wpis w aplikacjach Windowsa. **Kopie gier, mody w kopiach, profile, zapisy i
raporty pozostają na dyskach.** To pozwala zachować eksperyment i własne zapisy.

| Komunikat lub objaw | Dalszy krok |
| --- | --- |
| Brak źródłowego `Attila.exe` | Wskaż główny katalog zainstalowanej Attili. |
| Brak aktywnej listy modów | Uruchom raz zwykłą grę z wybranym MK1212, zamknij ją i ponów instalację. |
| Brakująca paczka | Zaczekaj na pobranie Workshop; sprawdź wybrany folder modów. |
| Sprzeczna lista albo powtarzająca się nazwa | Zachowaj komunikat i istniejące manifesty; trzeba rozstrzygnąć konkretny wybór. |
| Za mało miejsca | Sprawdź wskazany wolumin i liczbę wymaganych bajtów. |
| Brak `Start.exe`, `SbieIni.exe` lub usługi Sandboxie | Zainstaluj Sandboxie-Plus, wskaż folder i wykonaj wymagany restart. |
| `Owned installation path differs: ToolkitRoot` | Ponów wydaniem 0.2.1 z tymi samymi folderami; przy dalszej blokadzie zachowaj wartości zapisanej i wybranej ścieżki z komunikatu. |
| Obcy katalog lub istniejąca inna wersja | Zachowaj dane oraz raport; nie kasuj na ślepo plików ani piaskownic. |
| Brak menu MK1212 mimo przygotowania | Zbierz raport i podaj, co wyświetlają oba okna. |
| Steam otwiera się zamiast gry albo proces znika | Zbierz raport z wersją gry i sumami plików. Zgodność konkretnego builda wymaga sprawdzenia. |
| Lobby jest niewidoczne | Sprawdź obie gry, aktywną kartę Ethernet/Wi-Fi oraz raportowane porty i procesy. |

Goldberg korzysta z TCP/UDP i wyszukiwania LAN. Ustawienia zawierają porty
47584/47585 oraz wzajemne adresy `127.0.0.1`, ale upstream nadal używa również
broadcastu. Potrzebna jest aktywna karta sieciowa. Instalator nie zmienia globalnie
zapory ani uprawnień IPC. Jeśli Windows pyta o dostęp do sieci, sprawdź, czy
okno dotyczy rzeczywistej kopii HOST/CLIENT w Twojej prywatnej sieci.

## 6. Opcjonalny ZIP i polecenia diagnostyczne

Wydanie ZIP zachowuje ręczny launcher. Po wypakowaniu całej paczki można jawnie
wskazać wszystkie ścieżki:

```powershell
.\RUN-GOLDBERG-LAB.cmd -GameRoot "D:\SteamLibrary\steamapps\common\Total War Attila" -ModsRoot "D:\SteamLibrary\steamapps\workshop\content\325610" -HostGameRoot "C:\MK1212\HOST" -ClientGameRoot "D:\MK1212\CLIENT" -LabRoot "D:\MK1212-GoldbergLab"
```

Tryby `Preflight`, `Prepare`, `LaunchBoth` i `Collect` wybiera się przez `-Mode`.
Przy kolejnych wywołaniach zachowaj te same jawne ścieżki. Instalator EXE i jego
skróty robią to automatycznie. Język jest odczytywany z manifestu Steam; opcjonalny
`-Language polish` wybiera język zainstalowany w grze. Pierwszy katalog roboczy
ręcznego ZIP-a domyślnie różni się od instalacji EXE.

## 7. Wersja emulatora i licencja

Wybrano oryginalny projekt
[Mr_Goldberg/goldberg_emulator](https://mr_goldberg.gitlab.io/goldberg_emulator/),
commit `475342f0d8b2bd7eb0d93bd7cfdd61e3ae7cda24`.

- Archiwum: `third_party/goldberg/goldberg-original-475342f0.zip`.
- SHA-256 archiwum: `8465984b01b42a75f5faea8f2d884bbd6085a695c40c2b90eb0385f0a5081266`.
- Używany plik: główny `steam_api.dll`, PE32 x86; warianty `experimental` pozostają
  wyłącznie wewnątrz oryginalnego ZIP-a.
- Źródła: `source_code/source_code.bundle` w tym ZIP-ie.
- Licencja emulatora: LGPL 3 lub nowsza; pełne teksty i szczegóły pochodzenia
  znajdują się obok archiwum w `third_party/goldberg`.

Każdy klient ma inny lokalny identyfikator i osobny katalog zapisu emulatora.
Są to tożsamości emulatora. Konfiguracja nie wymaga podawania loginu ani hasła
do Steam. Pusty `DLC.txt` wyłącza domyślne odblokowywanie dodatków przez emulator.
Jeśli scenariusz potrzebuje konkretnego posiadanego DLC, trzeba to ustalić
oddzielnie na podstawie rzeczywistego scenariusza i zainstalowanych plików.

Szczegółowe źródła i ograniczenia:
[UPSTREAM.md](third_party/goldberg/UPSTREAM.md) w paczce albo
[repozytorium narzędzia](https://github.com/karnalooch/MK1212Scripts/issues/64).
`package_manifest.json` zapisuje dokładny commit skryptów i sumy rozprowadzanych
plików. Status prawdziwego runtime w paczce pozostaje `NOT_RUN` do czasu zebrania
dowodu z komputera operatora.

## Źródła dotyczące profilu i listy modów

- [Oficjalne ATTILA Environment Settings](https://wiki.totalwar.com/w/Total_War:_ATTILA_KIT_-_Environment_Settings) opisują katalog skryptów profilu i pliki ustawień.
- [TWPatcher — przykład dla Attili](https://github.com/Frodo45127/twpatcher) wykorzystuje istniejący `used_mods.txt`.
- [Przypięty generator listy modów Runchera](https://github.com/Frodo45127/runcher/blob/dd7e5393ffa0af89aee36ca003448babd7f54d45/runcher/src/mod_manager/load_order/mod.rs) zapisuje dyrektywy `add_working_directory` i `mod` w ustalonej kolejności. To źródło implementacji narzędzia społecznościowego, a nie dowód uruchomienia naszych dwóch klientów.
