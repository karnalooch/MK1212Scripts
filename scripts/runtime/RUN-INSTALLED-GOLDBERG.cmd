@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "MK1212_SETUP_SCRIPT=%~dp0scripts\runtime\goldberg_setup.ps1"
set "MK1212_SETUP_SETTINGS=%~dp0installer-settings.json"
set "MK1212_SETUP_MODE=Run"
if "%~1"=="" goto mode_ready
if /i "%~1"=="Run" goto mode_ready
if /i "%~1"=="Collect" (
  set "MK1212_SETUP_MODE=Collect"
  goto mode_ready
)
if /i "%~1"=="Validate" (
  set "MK1212_SETUP_MODE=Validate"
  goto mode_ready
)
echo Supported launcher modes: Run, Collect, Validate.
pause
exit /b 2
:mode_ready
if not "%~2"=="" (
  echo Additional arguments are not accepted. Use the installer to choose paths.
  pause
  exit /b 2
)
if not exist "%MK1212_SETUP_SCRIPT%" goto missing_install
if not exist "%MK1212_SETUP_SETTINGS%" goto missing_install
echo MK1212 - installed Goldberg HOST + CLIENT experiment
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%MK1212_SETUP_SCRIPT%" -Mode "%MK1212_SETUP_MODE%" -SettingsPath "%MK1212_SETUP_SETTINGS%"
set "MK1212_SETUP_EXIT=%ERRORLEVEL%"
echo.
if not "%MK1212_SETUP_EXIT%"=="0" echo The operation stopped. Read its BLOCKED reason and report path above.
pause
exit /b %MK1212_SETUP_EXIT%
:missing_install
echo The installed toolkit or its settings are missing. Run the MK1212 installer again.
pause
exit /b 2
