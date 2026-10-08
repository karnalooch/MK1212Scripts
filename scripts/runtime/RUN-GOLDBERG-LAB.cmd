@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "GOLDBERG_LAB_SCRIPT=%~dp0scripts\runtime\goldberg_client_lab.ps1"
if not exist "%GOLDBERG_LAB_SCRIPT%" set "GOLDBERG_LAB_SCRIPT=%~dp0goldberg_client_lab.ps1"
if not exist "%GOLDBERG_LAB_SCRIPT%" (
  echo Cannot find goldberg_client_lab.ps1. Extract the complete package first.
  pause
  exit /b 1
)
echo.
echo MK1212 - Goldberg HOST + CLIENT experiment
echo First run copies your game twice to D:\MK1212-GoldbergLab.
echo Later runs use the prepared copies. Full instructions: README.md
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%GOLDBERG_LAB_SCRIPT%" %*
set "GOLDBERG_LAB_EXIT=%ERRORLEVEL%"
echo.
if not "%GOLDBERG_LAB_EXIT%"=="0" echo The lab stopped. Read the BLOCKED reason and report path above.
echo Keep this window until you have read the result.
pause
exit /b %GOLDBERG_LAB_EXIT%
