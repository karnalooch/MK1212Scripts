@echo off
setlocal
set "LAB_SCRIPT=%~dp0scripts\runtime\dual_client_lab.ps1"
if not exist "%LAB_SCRIPT%" set "LAB_SCRIPT=%~dp0dual_client_lab.ps1"
if not exist "%LAB_SCRIPT%" (
  echo Cannot find scripts\runtime\dual_client_lab.ps1. Extract the complete package first.
  pause
  exit /b 1
)
if not "%~1"=="" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LAB_SCRIPT%" %*
  exit /b
)

:menu
echo.
echo MK1212 - two-client experiment
echo Workspace: D:\MK1212-DualClientLab
echo.
echo 1 - Check prerequisites
echo 2 - Set up and verify isolated HOST / CLIENT profiles
echo 3 - Open HOST Steam
echo 4 - Open CLIENT Steam
echo 5 - Collect evidence
echo 0 - Exit
choice /C 123450 /N /M "Choose: "
if errorlevel 6 exit /b 0
if errorlevel 5 set "LAB_MODE=Collect"
if errorlevel 5 goto run
if errorlevel 4 set "LAB_MODE=LaunchClient"
if errorlevel 4 goto run
if errorlevel 3 set "LAB_MODE=LaunchHost"
if errorlevel 3 goto run
if errorlevel 2 set "LAB_MODE=Setup"
if errorlevel 2 goto run
set "LAB_MODE=Preflight"

:run
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LAB_SCRIPT%" -Mode %LAB_MODE%
echo.
echo Read the result and report path above. Game login and lobby steps are manual.
pause
goto menu
