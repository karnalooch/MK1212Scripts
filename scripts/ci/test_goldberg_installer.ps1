# Executes the actual compiled NSIS EXE against bounded fixture inputs.
# No Sandboxie service, ATTILA process or original user directory is touched.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$InstallerPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../runtime/dual_client_lab_core.psm1') -Force -DisableNameChecking
$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$root = Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../build'))) ('installer-boundary-' + [guid]::NewGuid().ToString('N'))
$systemRoleRoot = Join-Path ([IO.Path]::GetTempPath()) ('mk1212-installer-inert-host-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)

function Invoke-CompiledGoldbergFixture {
    param([string]$Settings)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $installer; $start.UseShellExecute = $false
    # The NSIS parser requires a raw switch and a separately quoted value.
    $start.Arguments = '/S /SETTINGS=' + (Join-LabWindowsArguments -Arguments @($Settings))
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Compiled installer process did not start.' }
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'Compiled installer exceeded the bounded fixture deadline.' }
        if ($process.ExitCode -ne 2) { throw ('Expected installer BLOCKED exit 2, got ' + $process.ExitCode) }
    } finally { $process.Dispose() }
}

function Get-CompiledFixtureHashes {
    param([string]$Path)
    $hashes = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $Path -File -Recurse)) {
        $hashes[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $hashes
}

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
        Invoke-CompiledGoldbergFixture -Settings $settings
        foreach ($path in @($toolkit, $hostCopy, $clientCopy, $source, $mods)) {
            if (Test-Path -LiteralPath $path) { throw ('Invalid fixture unexpectedly wrote a directory: ' + $path) }
        }
        if ((Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash -cne $before) { throw 'Installer modified its input INI.' }
        Write-Host ('PASS compiled NSIS refusal/source-preservation: ' + $name)
    }

    # These are text files with EXE/DLL suffixes, never executable fixtures.
    # Setup may inspect their existence. Main must reject Attila's DOS header
    # before lab initialization, service lookup or any Sandboxie/game invocation.
    $caseRoot = Join-Path $root ('controller ' + [char]0x0142)
    $source = Join-Path $caseRoot 'inert-original'
    $mods = Join-Path $caseRoot 'inert-mods'
    $sandboxie = Join-Path $caseRoot 'inert-sandboxie'
    $toolkit = Join-Path $caseRoot 'installed-launcher'
    $clientCopy = Join-Path $caseRoot 'not-created-client'
    $lab = Join-Path $toolkit 'lab'
    foreach ($directory in @((Join-Path $source 'data'), $mods, $sandboxie)) { [void][IO.Directory]::CreateDirectory($directory) }
    foreach ($file in @((Join-Path $source 'Attila.exe'), (Join-Path $source 'steam_api.dll'), (Join-Path $sandboxie 'Start.exe'), (Join-Path $sandboxie 'SbieIni.exe'))) { [IO.File]::WriteAllText($file, 'INERT FIXTURE - NOT A PE') }
    [IO.File]::WriteAllText((Join-Path $mods 'inert.pack'), 'INERT SELECTED PACK')
    $settings = Join-Path $caseRoot 'valid-controller-input.ini'
    $text = @('[MK1212]', "ToolkitRoot=$toolkit", "GameRoot=$source", "ModsRoot=$mods", "HostGameRoot=$systemRoleRoot", "ClientGameRoot=$clientCopy", "SandboxieRoot=$sandboxie", '') -join [Environment]::NewLine
    [IO.File]::WriteAllText($settings, $text, [Text.Encoding]::Unicode)
    $beforeSources = Get-CompiledFixtureHashes -Path $caseRoot
    Invoke-CompiledGoldbergFixture -Settings $settings

    $markerPath = Join-Path $toolkit 'installer-settings.json'
    $manifestPath = Join-Path $toolkit 'package_manifest.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Compiled controller did not create its marker and install the verified payload.' }
    $marker = [IO.File]::ReadAllText($markerPath) | ConvertFrom-Json
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($marker.schema -ne 1 -or $marker.owner -cne 'MK1212Scripts.goldberg-installer' -or $marker.installation_id -notmatch '^[0-9a-f]{32}$') { throw 'Compiled controller wrote an invalid ownership marker.' }
    $expectedPaths = [ordered]@{ ToolkitRoot = $toolkit; GameRoot = $source; ModsRoot = $mods; HostGameRoot = $systemRoleRoot; ClientGameRoot = $clientCopy; LabRoot = $lab; SandboxieRoot = $sandboxie }
    foreach ($key in $expectedPaths.Keys) { if ([string]$marker.$key -ine [string]$expectedPaths[$key]) { throw ('Compiled controller marker path mismatch: ' + $key) } }
    if ($manifest.schema -ne 1 -or $manifest.package -cne 'mk1212-goldberg-client-lab' -or $manifest.files.Count -ne 15 -or $marker.source_sha -cne $manifest.source_sha -or $marker.package_manifest_sha256 -cne (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Installed payload identity does not match the controller marker.' }
    foreach ($record in $manifest.files) {
        $installedFile = Join-Path $toolkit $record.path
        if (-not (Test-LabPathContained -Root $toolkit -Path $installedFile)) { throw 'Installed manifest escaped its toolkit directory.' }
        $item = Get-Item -LiteralPath $installedFile -ErrorAction Stop
        if ($item.PSIsContainer -or $item.Length -ne $record.bytes -or (Get-FileHash -LiteralPath $installedFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $record.sha256) { throw ('Compiled controller installed an incomplete or different payload: ' + $record.path) }
    }
    foreach ($path in @($lab, $systemRoleRoot, $clientCopy, (Join-Path $toolkit 'Uninstall.exe'))) { if (Test-Path -LiteralPath $path) { throw ('Blocked controller unexpectedly initialized or launched a lab path: ' + $path) } }
    foreach ($path in $beforeSources.Keys) { if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $beforeSources[$path]) { throw ('Compiled controller modified its inert source/input: ' + $path) } }
    foreach ($directory in @($source, $mods, $sandboxie)) {
        foreach ($path in (Get-CompiledFixtureHashes -Path $directory).Keys) { if (-not $beforeSources.ContainsKey($path)) { throw ('Compiled controller added a source file: ' + $path) } }
    }
    Write-Host 'PASS compiled NSIS controller: exit 2, correct marker, exact installed payload, source preservation and no lab/game destinations. NSIS detail-log reason: NOT_CAPTURED.'

    # Independently capture the installed bridge's actual child invocation.
    # This message is not attributed to the preceding NSIS detail log.
    $powershell = Join-Path ([Environment]::GetEnvironmentVariable('SystemRoot')) 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $bridge = Invoke-LabNative -Executable $powershell -WorkingDirectory $toolkit -TimeoutSeconds 60 -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $toolkit 'scripts/runtime/goldberg_setup.ps1'), '-Mode', 'Run', '-SettingsPath', $markerPath)
    if ($bridge.ExitCode -ne 2 -or $bridge.Output -notmatch 'Missing DOS executable header') { throw ('Installed bridge did not reach the expected inert-PE refusal: ' + $bridge.Output) }
    foreach ($path in @($lab, $systemRoleRoot, $clientCopy)) { if (Test-Path -LiteralPath $path) { throw 'Installed bridge created a lab/game destination after invalid PE input.' } }
    foreach ($path in $beforeSources.Keys) { if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $beforeSources[$path]) { throw 'Installed bridge modified an inert source/input.' } }
    Write-Host 'PASS installed bridge child boundary: exact DOS-header refusal captured; Sandboxie/game execution and multiplayer: NOT_RUN.'
    Write-Host 'Compiled NSIS boundary: 3 passed, 0 failed; separate installed bridge boundary: 1 passed. Successful ATTILA setup/launch/lobby: NOT_RUN.'
} finally {
    # Both roots are unique synthetic fixture paths created by this test only.
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    if (Test-Path -LiteralPath $systemRoleRoot) { Remove-Item -LiteralPath $systemRoleRoot -Recurse -Force }
}
