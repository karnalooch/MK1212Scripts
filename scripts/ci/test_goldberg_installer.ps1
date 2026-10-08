# Executes the actual compiled NSIS EXE against invalid fixture inputs.
# No Sandboxie service, ATTILA process or original user directory is touched.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$InstallerPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../runtime/dual_client_lab_core.psm1') -Force -DisableNameChecking
$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$root = Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../build'))) ('installer-boundary-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    foreach ($name in @('plain.ini', ('settings ' + [char]0x0142 + '.ini'))) {
        $settings = Join-Path $root $name
        $toolkit = Join-Path $root 'not-created-launcher'
        $hostCopy = Join-Path $root 'not-created-host'
        $clientCopy = Join-Path $root 'not-created-client'
        $source = Join-Path $root 'missing-original'
        $mods = Join-Path $root 'missing-mods'
        $text = @('[MK1212]', "ToolkitRoot=$toolkit", "GameRoot=$source", "ModsRoot=$mods", "HostGameRoot=$hostCopy", "ClientGameRoot=$clientCopy", 'SandboxieRoot=', '') -join [Environment]::NewLine
        [IO.File]::WriteAllText($settings, $text, [Text.Encoding]::Unicode)
        $before = (Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $installer
        $start.UseShellExecute = $false
        # NSIS GetOptions recognizes the unquoted switch and a quoted VALUE.
        # Quoting the whole /SETTINGS= argument would hide it from that parser.
        $start.Arguments = '/S /SETTINGS=' + (Join-LabWindowsArguments -Arguments @($settings))
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        try {
            if (-not $process.Start()) { throw 'Compiled installer process did not start.' }
            if (-not $process.WaitForExit(60000)) {
                $process.Kill()
                throw 'Compiled installer did not terminate after invalid fixture input.'
            }
            if ($process.ExitCode -ne 2) { throw ('Expected installer BLOCKED exit 2, got ' + $process.ExitCode) }
        } finally { $process.Dispose() }
        foreach ($path in @($toolkit, $hostCopy, $clientCopy, $source, $mods)) {
            if (Test-Path -LiteralPath $path) { throw ('Invalid fixture unexpectedly wrote a directory: ' + $path) }
        }
        if ((Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash -cne $before) { throw 'Installer modified its input INI.' }
        Write-Host ('PASS compiled NSIS refusal/source-preservation: ' + $name)
    }
    Write-Host 'Compiled NSIS boundary: 2 passed, 0 failed. Successful ATTILA setup/launch/lobby: NOT_RUN.'
} finally {
    # This GUID directory contains only the two input files made above.
    foreach ($file in [IO.Directory]::EnumerateFiles($root, '*.ini')) { [IO.File]::Delete($file) }
    [IO.Directory]::Delete($root, $false)
}
