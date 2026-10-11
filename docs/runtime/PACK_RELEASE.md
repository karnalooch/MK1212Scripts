# MK1212 — paczka skryptów i instalacja

Status: **REPO-OBSERVED / kandydat do testu w grze**. Wygenerowanie poprawnego
archiwum i przejście testów Lua nie potwierdzają synchronizacji dwóch kopii Attili.

## Co instalujesz

Paczka jest kompletną nakładką na **skrypty znajdujące się w tym repozytorium**.
Zawiera wszystkie zapisane w wybranym commicie pliki `.lua` z `campaigns/`,
`lua_scripts/` i `script/`, w ich oryginalnych ścieżkach. Obejmuje bootstrap,
mechaniki, populację, moduły debugowania i adapter runtime. Nie powstaje z listy
plików zmienionych w ostatnim PR.

Nadal potrzebujesz zainstalowanej Attili i całego wymaganego zestawu MK1212.
Oryginalna paczka skryptowa MK1212 może zawierać także dane, UI i filmy —
ta nakładka ich nie zastępuje. Pozostaw bazowe paczki moda aktywne.
Generator nie pakuje filmów, plików gry, osobnej DLL ani niekompilowanych tabel TSV.

W źródłach upstream są dwa pliki Lua z zakodowanymi pomocniczymi programami
moda: `change_capital_binaries.lua` oraz `slots_binaries.lua`. Pozostają bez
zmian, ponieważ istniejące skrypty SP odwołują się do nich. Nie są to binaria
Attili. Ta paczka nie odblokowuje tych funkcji w multiplayerze.

## Wybierz jeden wariant

| Wariant | Zachowanie | Zastosowanie |
| --- | --- | --- |
| `baseline` | Zachowuje wyłączone bramki eksperymentalne z commitu. | Próba kontrolna aktualnych skryptów i diagnostyki. |
| `full-experimental` | Ustawia w pakowanej kopii rejestru `enabled = true` i `all_experimental = true`. | Zamówiony pełny eksperyment funkcji podłączonych do rejestru, na nowej kampanii testowej. |

Obydwa warianty zawierają aktualne poprawki wspólnego kodu. W MP poprawione
skryptowe efekty zależne od trudności korzystają z jednej wartości **0
(normalna)** zamiast poziomu lokalnego gracza. Dotyczy to również `baseline`.
Nie zmienia to poziomu wybranego w interfejsie ani ustawień trudności silnika.

**Obydwa warianty są wzajemnie wykluczające.** Na jednym komputerze aktywuj
tylko jeden. HOST i CLIENT mają dostać ten sam plik `.pack` z tą samą SHA256.
Nie wybieraj funkcji osobno na każdym komputerze i nie łącz tej nakładki
z poprzednimi poprawkami skryptów, które nadpisują te same ścieżki.

`full-experimental` nie oznacza, że każda funkcja SP została naprawiona i
sprawdzona w MP. Włącza znane bramki rejestru; nie usuwa wyłączeń Ironmana,
Change Capital ani starego helpera sieciowego. Pełny stan funkcji i ograniczeń
opisuje [eksperyment SP → MP](../research/MP_SP_PARITY_EXPERIMENT.md).
Używaj nowej kampanii, której utrata nie zabierze właściwej rozgrywki.

W transzy N0–N4 rejestr akcji **blokuje skryptowe efekty lokalnych kliknięć w MP**
do czasu wykazania natywnego dostarczenia i bezpiecznej fazy wykonania. Dotyczy
decyzji i pożyczki papieskiej, państw buforowych, handlu regionami, rozpoczynania
i anulowania aneksji oraz objętych zmianą akcji Population. Wariant pełny może
pokazać ich interfejs, ale jego przełącznik nie otwiera tej granicy. Natywny
przycisk gry może nadal wykonać własną operację. Nie traktuj tego wydania jako
gotowej kampanii z kompletnym parytetem SP/MP.

W SP niejednoznaczne zdarzenie wyszkolenia jednostki zachowuje rezerwacje
Population i blokuje dalsze niepotwierdzone rozliczenia tej kolejki; nie zgaduje,
która z identycznych jednostek została wyszkolona. Dodatkowe metadane właścicieli
akcji wymagają kopii zapisu sprzed **tej** aktualizacji także przy cofnięciu do
wcześniejszego wydania używającego wspólnego schematu 3.

Zakres, wersje zapisu i granice dowodu opisuje
[wdrożenie N0–N4](../research/MP_N0_N4_IMPLEMENTATION.md). Dodatkowy koordynator
i bufor są narzędziem eksperymentalnym; instrukcja jednego wspólnego przebiegu
po N4 znajduje się w [MP_HOST_COORDINATOR.md](MP_HOST_COORDINATOR.md).

## Instalacja na Windows — oba komputery

1. Zamknij grę. Zachowaj dotychczasowy działający zapis i jego zestaw modów.
   **Kopia sprzed aktualizacji jest potrzebna także dla `baseline`: wspólny
   zapis danych skryptowych przechodzi na schemat 3.** Stare formaty 0–2 są
   odczytywane przez nowy kod, ale cofnięcie do starszej paczki po zapisaniu
   stanu przez nową wersję wymaga przywrócenia kopii sprzed aktualizacji.
   Rozpakuj **jeden** wariant do osobnego katalogu, np. `D:\MK1212\full-test`.
2. Usuń zaznaczenie poprzednich nakładek skryptowych w menedżerze modów.
   Przenieś poprzednie `mk1212_scripts_*.pack` poza folder gry `data`.
   Dotyczy to również wcześniejszych nakładek `00_mk1212_spmp_*.pack`.
   Nie usuwaj paczek Workshop MK1212 ani plików gry.
3. Uruchom instalator z właściwą lokalizacją gry. Przykład:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\MK1212\full-test\Install-MK1212-Pack.ps1" -GameDirectory "D:\SteamLibrary\steamapps\common\Total War Attila"
   ```

   `ExecutionPolicy Bypass` dotyczy tylko tego procesu. Instalator sprawdza
   manifest i SHA256, kopiuje jeden plik do `data`, ponownie sprawdza kopię
   i odmawia nadpisania innej paczki. Nie zmienia Workshop, zapisów,
   `Attila.exe`, `Attila.dll` ani pliku kolejności ładowania modów.
4. W menedżerze modów włącz nową nakładkę z priorytetem nad bazowymi
   skryptami MK1212. Zachowaj identyczną kolejność pozostałych modów u obu graczy.
   Nie traktuj prefiksu nazwy pliku jako dowodu kolejności ładowania.
5. Sprawdź SHA256 zainstalowanego pliku na obu komputerach:

   ```powershell
   Get-FileHash -Algorithm SHA256 -LiteralPath "D:\SteamLibrary\steamapps\common\Total War Attila\data\NAZWA_Z_MANIFESTU.pack"
   ```

   Wynik musi zgadzać się z `SHA256SUMS.txt` i polem `pack.sha256` manifestu.
6. Uruchom nową kampanię i odszukaj w `MK1212_mp_debug.log` wpis
   **`event=content_identity`**. Pole `source` ma zawierać pełny SHA commitu
   z manifestu, `profile` wybrany wariant, a `save_schema` wartość `3`.
   Porównaj `source` i `profile` z wpisem drugiego gracza. Pakowany rejestr
   dostarcza je przez `MKMP_PACK_ID.source` oraz `MKMP_PACK_ID.profile`;
   są to wyłącznie metadane diagnostyczne.
   Brak oczekiwanego identyfikatora oznacza, że samo skopiowanie pliku nie
   potwierdziło załadowania właściwych skryptów. Sprawdź aktywne nakładki
   i priorytet w menedżerze modów przed oceną wyniku testu.

Nakładka ma typ **Mod (3)**, więc trzeba ją włączyć w menedżerze.
Otrzymane `1-1212scripts.pack` również ma typ **Mod (3)** — jest więc
odpowiednią bazą dla nakładki o wyższym priorytecie. Jego nagłówek,
komplet ścieżek i hash sprawdzono bez uruchamiania gry; rzeczywisty priorytet
potwierdza dopiero identyfikacja załadowanego kodu. Szczegóły pomiaru są niżej.

### Cofnięcie instalacji

Zamknij grę, wyłącz nakładkę i przenieś jej pojedynczy plik `.pack` poza
`data`. Przywróć wcześniejszy zestaw modów **i kopię zapisu sprzed aktualizacji**.
Wymóg kopii dotyczy także cofania wariantu `baseline`, ponieważ nowy wspólny
kodek zapisuje schemat 3; starszy kod nie jest jego zgodnym czytnikiem.
Nie kontynuuj zapisu z włączonym eksperymentem po przejściu na inny zestaw funkcji.

## Budowanie przez programistę

Wymagania: Python 3.10+ i Git. Nie jest potrzebna instalacja gry, Rust,
RPFM ani pobieranie zależności. Wskazany commit musi zawierać również
instalator i ten dokument, ponieważ wszystkie dostarczane pliki pochodzą z Git.

```bash
python scripts/pack/build_mk1212_pack.py build --ref FULL_COMMIT_SHA --profile baseline --output-dir /tmp/mk1212-baseline
python scripts/pack/build_mk1212_pack.py build --ref FULL_COMMIT_SHA --profile full-experimental --output-dir /tmp/mk1212-full
```

Folder docelowy musi być nowy. Generator weryfikuje wynik w katalogu
tymczasowym, a następnie publikuje kompletny katalog. Istniejące wydania
pozostają nienaruszone również przy błędzie kolejnej kompilacji.

Archiwum powstaje z `git ls-tree` i `git cat-file`, a nie z plików roboczych.
Różnice CRLF/LF, zmodyfikowany plik roboczy i nieśledzone pliki nie zmieniają
bajtów wejściowych. Jedyna modyfikacja pakowanego kodu dotyczy rejestru
parytetu: dodanie identyfikacji wydania oraz dwóch przełączników w wariancie
pełnego eksperymentu. Źródło w Git pozostaje z wyłączonymi eksperymentami.

Manifest zawiera pełny SHA commitu i drzewa, identyfikator bloba i SHA256
każdego źródła, SHA256 każdej pakowanej wersji, listę transformacji,
profil, raport zależności oraz hash generatora. Eksport instrukcji zamienia
lokalne odsyłacze na linki do tego samego commitu i zapisuje tę transformację.
Manifest nie zawiera czasu bieżącego,
ścieżki komputera ani nazwy użytkownika. Przy tych samych źródłach,
profilu i generatorze kolejne wyniki mają identyczne bajty.

Weryfikacja otrzymanego wydania:

```bash
python scripts/pack/build_mk1212_pack.py verify --pack /path/mk1212_scripts_PROFILE_SHA.pack --manifest /path/mk1212_scripts_PROFILE_SHA.manifest.json
python -m unittest discover -s scripts/ci -p "test_pack_*.py" -v
```

Syntetyczna kontrola instalatora na Windows (nie uruchamia gry):

```powershell
powershell.exe -NoProfile -File scripts/pack/Test-Install-MK1212-Pack.ps1
pwsh.exe -NoProfile -File scripts/pack/Test-Install-MK1212-Pack.ps1
```

Polecenie `verify` sprawdza nagłówek, granice indeksu i danych, brak
zduplikowanych ścieżek, SHA256 całej paczki i poszczególnych plików,
identyfikację i przełączniki profilu oraz zgodność raportu zależności.
Manifest jest dowodem odtwarzalności i wykrywa przypadkowe uszkodzenia;
nie jest podpisem kryptograficznym poświadczającym zaufanie do nadawcy.

## Kontrola kompletności Lua

Generator analizuje instrukcje `require` po rozpoznaniu komentarzy,
stringów i długich nawiasów Lua. Nie szuka zależności zwykłym grepem
obejmującym komentarze.

- Każdy stały import musi wskazywać plik w paczce albo istniejącą,
  dokładnie wskazaną parę moduł gry + plik wywołujący.
- Importy osiągnięć są sprawdzane względem całej deklaracji
  `ACHIEVEMENT_KEY_LIST`; brak jednego zadeklarowanego modułu zatrzymuje build.
- Istniejący dynamiczny loader frakcji pozostaje opcjonalny i chroniony przez
  `pcall`; wszystkie pliki frakcji obecne w repo trafiają do paczki.
- Jawne ścieżki `.lua` przekazywane do silnika, w tym wejście bitwy
  `battle_no_retreat.lua`, również muszą istnieć.
- Nowy, nierozpoznany import dynamiczny zatrzymuje build do czasu przeglądu.

Zależności dostarczane przez grę są jawnie wypisane w manifeście.
Lista wynika z obecnych odwołań repozytorium; nie oznacza inspekcji
każdej zainstalowanej wersji Attili. Przejście kontroli importów nie dowodzi
istnienia obiektów silnika ani synchronizacji zdarzeń w MP.

## Zmierzone pokrycie oryginalnej paczki

Źródło: dostarczone `1-1212scripts.pack`, **343 198 063 bajty**,
SHA256 `3ffe61270c953602783fcfde4723abf1d5bc698b958ef618f329d2e5b6369255`.
Dowód: [inwentaryzacja źródłowej paczki](evidence/base-script-pack-20261011.json).

| Pomiar | Wynik |
| --- | --- |
| Format / typ / flagi | PFH4 / Mod (3) / 0 |
| Pliki w oryginalnej paczce | 1589 |
| Skrypty Lua w oryginale | 154, łącznie 2 624 921 bajtów |
| Ścieżki Lua oryginału pokryte przez repozytorium | 154/154 |
| Brakujące ścieżki Lua | 0 |
| Filmy pozostające w bazie | 2 pliki, 293 566 585 bajtów |

Inwentaryzacja jest przypięta do sprawdzonego commitu źródłowego
`49db5e129d87f2fbdc1b1e02333873caddb00437`: miał 158 plików Lua,
w tym dodatkowe moduły debug, runtime i rejestr parytetu. Liczbę plików
bieżącego wydania określa jego manifest; kolejne moduły mogą ją zwiększyć.
Plik JSON zawiera hash każdego oryginalnego skryptu oraz mapowanie na
ścieżkę i hash w repozytorium. Nie zawiera filmów ani bajtów zasobów gry.

Ponowienie pomiaru dla kolejnego commitu, bez rozpakowywania zasobów:

```bash
python scripts/pack/build_mk1212_pack.py inspect-base --ref FULL_COMMIT_SHA --pack /path/1-1212scripts.pack --output /tmp/base-pack-evidence.json
```

Narzędzie odczytuje duży plik strumieniowo, weryfikuje granice indeksu
i danych oraz zapisuje tylko małą inwentaryzację. Nie zmienia oryginału.

## Format i wybór narzędzia

W istniejącym projekcie natywnym `native/twdll/tools/twdll.ps1` używa
`rpfm_cli --game attila pack ...` do swoich paczek testowych. Ten proces
pozostaje bez zmian. Dla wydania samych skryptów potrzebny jest mały,
powtarzalny build działający także w CI bez instalacji RPFM i gry.
Dlatego generator implementuje tylko nieskompresowany wariant PFH4 Mod;
nie jest edytorem ogólnego formatu `.pack`, kompilatorem DB ani zamiennikiem BOB.

Referencja formatu: **RPFM, commit
`64e4b8e25c7e6729f6742f88ed27d8d8649a0478`, licencja MIT**:

- [PFH4: odczyt i zapis](https://github.com/Frodo45127/rpfm/blob/64e4b8e25c7e6729f6742f88ed27d8d8649a0478/rpfm_lib/src/files/pack/pack_versions/pfh4.rs).
- [Przypisanie Attili do PFH4](https://github.com/Frodo45127/rpfm/blob/64e4b8e25c7e6729f6742f88ed27d8d8649a0478/rpfm_lib/src/games/supported_games.rs).
- [Typy paczek, w tym Mod = 3](https://github.com/Frodo45127/rpfm/blob/64e4b8e25c7e6729f6742f88ed27d8d8649a0478/rpfm_lib/src/games/pfh_file_type.rs).

Używany nagłówek ma 28 bajtów: `PFH4`, typ 3, zerowe liczniki zależności,
liczbę plików, długość indeksu i zerowy czas. Każdy wpis indeksu zawiera
rozmiar `uint32` i zakończoną NUL ścieżkę z ukośnikami odwrotnymi.
Dane następują w tej samej kolejności co wpisy. Sortowanie ścieżek jest
niezależne od systemu, według małych liter. Nie są ustawiane flagi
kompresji, szyfrowania, rozszerzonego nagłówka ani dat poszczególnych plików.

Testy odczytują wynik drugim parserem, sprawdzają ręcznie określoną
próbkę binarną oraz istniejącą paczkę testową Attili z repozytorium.
Kompilacja składni wszystkich emitowanych skryptów korzysta z Lua 5.1
z istniejących źródeł vendora. Dowód załadowania w Attili i dwustronny
test multiplayer pozostają osobnymi etapami.
