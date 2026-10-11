# MK1212 N4 launcher. No installs, elevation, firewall edits, or game hooks.
# All arguments are forwarded unchanged to the Python standard-library CLI.
$ErrorActionPreference = 'Stop'
$mkmpPython = Get-Command py.exe -ErrorAction SilentlyContinue
$mkmpPrefix = @('-3')
if (-not $mkmpPython) {
    $mkmpPython = Get-Command python.exe -ErrorAction SilentlyContinue
    $mkmpPrefix = @()
}
if (-not $mkmpPython) {
    [Console]::Error.WriteLine('Python 3.10 or newer is required. Install Python for Windows or run mkmp_coordinator.py with your existing Python executable.')
    exit 2
}
& $mkmpPython.Source @mkmpPrefix -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine('The selected Python is older than 3.10. Run mkmp_coordinator.py with Python 3.10 or newer.')
    exit 2
}
$mkmpEntry = Join-Path $PSScriptRoot 'mkmp_coordinator.py'
& $mkmpPython.Source @mkmpPrefix $mkmpEntry @args
exit $LASTEXITCODE
