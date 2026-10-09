@echo off
setlocal
set "SCRIPT=%~dp0goldberg_overlay_operator.ps1"
if not exist "%SCRIPT%" (
  echo Brak skryptu: %SCRIPT%
  pause
  exit /b 2
)
:MENU
echo.
echo === MK1212 Goldberg Experimental Overlay ===
echo S  Status
echo E  Wlacz experimental overlay ^(oba procesy Attila musza byc zamkniete^)
echo L  Uruchom HOST i CLIENT przez Sandboxie
echo R  Przywroc standardowe DLL i disable_overlay.txt
echo Q  Wyjscie
choice /C SELRQ /M "Wybierz"
if errorlevel 5 exit /b 0
if errorlevel 4 set "MODE=Restore" & goto RUN
if errorlevel 3 set "MODE=Launch" & goto RUN
if errorlevel 2 set "MODE=Enable" & goto RUN
if errorlevel 1 set "MODE=Status" & goto RUN
:RUN
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode %MODE%
echo.
if errorlevel 1 (
  echo BLAD: sprawdz komunikat powyzej. Nie usuwaj backupu ani active.json.
)
pause
goto MENU
