# Dwie Attile na jednym komputerze — Goldberg HOST + CLIENT

Ta paczka przygotowuje dwa oddzielne środowiska z Twojej istniejącej instalacji
Total War: ATTILA. Zawiera oryginalne archiwum Goldberga, jego kod źródłowy,
licencje oraz skrypt Windows. **Nie musisz pobierać drugiej kopii gry.**

To eksperyment z emulowanym połączeniem LAN. Testy skryptów na Windowsie nie są
dowodem, że konkretna wersja Attili wejdzie do lobby, rozegra turę albo poprawnie
wczyta zapis. Te kroki trzeba wykonać w obu oknach gry. Wyniki tego wariantu nie
potwierdzają automatycznie działania zwykłego multiplayera Steam.

## 1. Pierwsze uruchomienie

1. Zainstaluj **Sandboxie-Plus, stabilną wersję x64**, ze
   [strony projektu](https://sandboxie-plus.com/downloads/). Instalator sterownika
   może poprosić o uprawnienia administratora. Jeśli instalator wymaga ponownego
   uruchomienia Windowsa, zrób je przed uruchomieniem paczki.
2. Wypakuj **cały** `MK1212-GoldbergLab.zip` do nowego katalogu, na przykład
   **`D:\Goldberg-Attila-Start`**. Nie uruchamiaj skryptu z podglądu ZIP-a.
3. Jeśli wybór MK1212 w launcherze jest nieaktualny, uruchom raz zwykłą grę
   z działającym zestawem modów, sprawdź menu i zamknij ją. Zaczekaj też na
   koniec aktualizacji Steam. Skrypt potrzebuje stabilnych plików przy kopiowaniu.
4. Uruchom dwuklikiem **`RUN-GOLDBERG-LAB.cmd`**.
5. Przeczytaj wynik w otwartym oknie. Pierwszy start sprawdza instalację,
   przygotowuje dwie kopie i uruchamia oba okna. Następne starty korzystają
   z przygotowanego laboratorium.

Znana z wcześniejszych logów ścieżka instalacji operatora to:

```text
D:\SteamLibrary\steamapps\common\Total War Attila
```

Jeśli wykrywanie nie znajdzie właściwej instalacji, otwórz terminal w katalogu
wypakowanej paczki i podaj ją jawnie:

```powershell
.\RUN-GOLDBERG-LAB.cmd -GameRoot "D:\SteamLibrary\steamapps\common\Total War Attila"
```

Możesz również wskazać inne miejsce na oba duże katalogi gry:

```powershell
.\RUN-GOLDBERG-LAB.cmd -GameRoot "D:\SteamLibrary\steamapps\common\Total War Attila" -LabRoot "E:\MK1212-GoldbergLab"
```

`LabRoot` musi być oddzielony od oryginalnej instalacji.
Najwygodniej użyć nowego pustego katalogu obok wypakowanego narzędzia. Skrypt zatrzyma się przy nieznanym właścicielu,
nakładających się ścieżkach lub dowiązaniach katalogów.

## 2. Miejsce na dysku i zawartość laboratorium

Domyślnym katalogiem roboczym jest **`D:\MK1212-GoldbergLab`**. Pierwsze
przygotowanie wymaga miejsca na **dwie pełne kopie instalacji oraz rezerwę**.
Skrypt oblicza wymaganie z rzeczywistej zawartości gry. Nie zakłada stałego
rozmiaru Attili lub MK1212. Pierwsze kopiowanie i sprawdzanie sum plików może
potrwać, zwłaszcza na dysku HDD.

| Element | Położenie lub nazwa |
| --- | --- |
| Kopia HOST | `D:\MK1212-GoldbergLab\games\HOST` |
| Kopia CLIENT | `D:\MK1212-GoldbergLab\games\CLIENT` |
| Sandboxie HOST | `MK1212GoldHost` |
| Sandboxie CLIENT | `MK1212GoldClient` |
| Raporty | `D:\MK1212-GoldbergLab\evidence\<czas>-<tryb>-<identyfikator>\report.json` |
| Stan przygotowania | `D:\MK1212-GoldbergLab\.mk1212-goldberg-lab.json` |
| Zachowane oryginalne API z kopii | `D:\MK1212-GoldbergLab\backups\HOST` i `CLIENT` |

Pliki gry są fizycznie kopiowane, a ich zawartość sprawdzana. Każda kopia otrzymuje
osobny `steam_api.dll` i własne ustawienia. Własne profile Attili powstają wewnątrz
dwóch piaskownic; skrypt sprawdza ich rozdzielenie plikiem z jednorazowym znacznikiem.
Dokładne fizyczne ścieżki profili zapisuje raport, ponieważ układ katalogów
Sandboxie zależy od konfiguracji Windowsa.

Oryginalny katalog Steam służy jako źródło odczytu. Dotychczasowe ustawienia
Goldberga, jeśli już były w źródle, są zachowane w kopiach zapasowych laboratorium;
każdy klient otrzymuje znaną konfigurację do tego eksperymentu.

## 3. Co robi jeden dwuklik

Domyślny tryb `Run` wykonuje następujące kroki:

1. Weryfikuje pliki narzędzia, oryginalne archiwum Goldberga i jego bibliotekę x86.
2. Wyszukuje instalację gry oraz narzędzia zainstalowanego Sandboxie.
3. Sprawdza rozłączność ścieżek, ilość danych, miejsce na dysku i własność katalogów.
4. Kopiuje grę dla HOST i CLIENT, porównując zawartość obu kopii ze źródłem.
5. Zachowuje oryginalne `steam_api.dll` z kopii i umieszcza w nich zweryfikowanego
   Goldberga. Wydobywa wersje interfejsów z własnego oryginalnego DLL gry.
6. Tworzy osobne profile, sprawdza ich mapowanie i przygotowuje konfigurację.
7. Uruchamia skopiowane `Attila.exe` we właściwych piaskownicach, z katalogiem
   roboczym ustawionym na odpowiednią kopię gry.
8. Zapisuje zaobserwowane procesy, ścieżki, przynależność do piaskownic i diagnostykę.

Start procesu jest raportowany oddzielnie od działania lobby. Sam kod wyjścia
`Start.exe` nie oznacza sukcesu uruchomienia Attili. Skrypt sprawdza rzeczywiste
procesy. Przy ponownym wywołaniu uwzględnia już działających klientów.

Przerwane przygotowanie zachowuje częściowe pliki do sprawdzenia. Kompletny
plik może zostać ponownie wykorzystany po porównaniu z aktualnym źródłem.
Uszkodzony plik lub pozostawiona część kopiowania powodują `BLOCKED` i nie
są po cichu nadpisywane. Jeżeli poprzednie przygotowanie nie utworzyło jeszcze piaskownic, czysty ponowny
eksperyment można uruchomić z innym nowym `-LabRoot`, po sprawdzeniu wolnego
miejsca. Jeśli piaskownice już istnieją, zachowaj raport: ich stałe nazwy są
związane z poprzednim laboratorium i zmiana samego `-LabRoot` ich nie przejmuje.

## 4. Połączenie obu gier

Gdy zobaczysz oba okna, zacznij od najkrótszego testu:

1. W każdym oknie ustaw tryb okienkowy i ogranicz ustawienia graficzne. Na początek
   rozsądne jest 1280 × 720 oraz niski profil grafiki, aby wygodnie przełączać gry.
2. W oknie HOST otwórz multiplayer/LAN i utwórz lobby. Nazwy przycisków zależą
   od języka i wersji gry.
3. W oknie CLIENT otwórz przeglądarkę gier LAN i odszukaj lobby HOST.
4. Wejdź do lobby. Sprawdź, czy są widoczni obaj gracze o różnych nazwach.
5. Rozpocznij krótką rozgrywkę. Dla kampanii sprawdź wykonanie tury przez obie
   strony, zapis oraz ponowne wczytanie.
6. Uruchom zbieranie raportu, najlepiej zanim zamkniesz oba procesy:

```powershell
.\RUN-GOLDBERG-LAB.cmd -Mode Collect
```

Jeżeli użyłeś innego katalogu laboratorium, dodaj ten sam `-LabRoot`.
Raport nie odczytuje stanu lobby z ekranu, więc dołącz własną krótką notatkę:
czy oba okna wystartowały, czy CLIENT zobaczył HOST, na którym kroku pojawił
się problem oraz czy test dotyczył podstawowej gry czy MK1212.

## 5. MK1212 i kolejność modów

Bezpośredni start `Attila.exe` wymaga rzeczywistej konfiguracji modów. Wybór
w launcherze CA może być zapisany w `used_mods.txt` w katalogu gry, a ręczna
konfiguracja w `scripts\user.script.txt` profilu Attili. Nie można odtworzyć
Twojego wyboru modów z samej nazwy katalogu gry.

Skrypt porównuje rozpoznane dyrektywy z obu istniejących manifestów i zachowuje
ich kolejność. Do nowych profili wpisuje wyłącznie rozpoznane polecenia modów;
oryginały manifestów przechowuje osobno jako dowód. Polecenia automatycznego
wczytania zapisu, generowania kampanii czy wyjścia z gry są pomijane.

W obu rolach potrzebne są **te same paczki `.pack`, w tej samej kolejności**.
Importer obsługuje paczki znajdujące się już wewnątrz kopiowanej instalacji.
**Nie kopiuje zewnętrznych katalogów Workshop.** Gdy manifest wskazuje takie
pliki, niekompletną listę albo konflikt, zapisuje `MODS_NOT_CONFIGURED` i pustą
listę modów. Dwa okna mogą wtedy uruchomić podstawową grę; wymagają osobnego
przygotowania paczek MK1212, zanim zaczniemy testować mod. Zachowaj istniejący
manifest wyboru modów i sprawdź w raporcie wynik jego rozpoznania. Nie dopisuj
listy nazw paczek na podstawie przypadkowego poradnika.

Jeżeli raport nie potwierdza konfiguracji modów, potraktuj uruchomienie jako test
samego mechanizmu dwóch gier. Do ustalenia prawidłowego MK1212 przekaż istniejący
`used_mods.txt` i/lub `user.script.txt`, plus komunikat raportu o brakujących
paczkach. Nie zaczynaj porównywania kampanii, gdy jedna strona uruchomiła inną
listę modów. Skrypt nie pobiera modów ani nie ustala za Ciebie nowego load order.

## 6. Dodatkowe tryby

W terminalu otwartym w katalogu paczki:

```powershell
# Tylko kontrola warunków przed przygotowaniem.
.\RUN-GOLDBERG-LAB.cmd -Mode Preflight

# Przygotowanie kopii i profili bez uruchamiania gry.
.\RUN-GOLDBERG-LAB.cmd -Mode Prepare

# Uruchomienie już przygotowanych kopii.
.\RUN-GOLDBERG-LAB.cmd -Mode LaunchBoth

# Raport o bieżącym stanie i dostępnych logach.
.\RUN-GOLDBERG-LAB.cmd -Mode Collect
```

Można jawnie wskazać niestandardową instalację Sandboxie:

```powershell
.\RUN-GOLDBERG-LAB.cmd -SandboxieRoot "D:\Programy\Sandboxie-Plus"
```

Język jest odczytywany z manifestu zainstalowanej gry, gdy można go jednoznacznie
ustalić; w przeciwnym razie używany jest `english`, co pojawia się w raporcie.
Możesz wskazać język zainstalowany w Twojej grze, wspólny dla obu klientów:

```powershell
.\RUN-GOLDBERG-LAB.cmd -Language polish
```

Archiwum emulatora jest już w paczce. Opcjonalny `-GoldbergArchive` pozwala
wskazać ten sam oryginalny plik w innym miejscu; jego suma nadal musi odpowiadać
wersji zapisanej w `third_party\goldberg\lock.json`.

## 7. Gdy coś się zatrzyma

| Objaw | Co sprawdzić |
| --- | --- |
| Brak `Start.exe` lub `SbieIni.exe` | Czy Sandboxie-Plus jest zainstalowane i czy wskazano właściwy `-SandboxieRoot`. |
| Za mało miejsca | Wskazaną przez raport liczbę wymaganych bajtów; wybierz pusty `-LabRoot` na większym dysku. |
| Obcy katalog, istniejące ustawienia lub plik częściowy | Zachowaj raport. Sprawdź wskazany plik; można wybrać nowy katalog laboratorium. |
| Nie udało się udowodnić oddzielnych profili | Komunikat probe/Sandboxie. Nie kopiuj plików na ślepo do zwykłego AppData. |
| Attila otwiera Steam, natychmiast znika albo nie inicjalizuje API | Zbierz raport z dokładną wersją gry i hashem. Zgodność tego builda nie jest jeszcze potwierdzona. |
| Lobby się nie pojawia | Czy obie gry działają, czy karta Ethernet/Wi-Fi jest aktywna, czy porty 47584/47585 są wolne i czy raport widzi właściwe procesy. |
| Windows pyta o dostęp aplikacji do sieci | Sprawdź, czy ścieżka dotyczy kopii HOST/CLIENT. Dla testu korzystaj z własnej sieci prywatnej. |
| Brak MK1212 lub różne mody w obu oknach | Wynik rozpoznania manifestu i dostępność wskazanych paczek `.pack`. |

Goldberg w tej wersji wykorzystuje porty TCP/UDP i wyszukiwanie LAN. Konfiguracja
podaje dodatkowo adresy drugiego klienta na `127.0.0.1`, ale upstream nadal
korzysta również z broadcastu. Potrzebna jest aktywna zwykła karta sieciowa.
Zajęty port może spowodować wybranie innego portu przez emulator; zapisane
ustawienie nie jest dowodem zaobserwowanego połączenia.

## 8. Wersja emulatora i licencja

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
