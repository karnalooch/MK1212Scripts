[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PackageRootPath)

# Actual delivered installer helpers and package bytes. No Attila/Sandboxie launch.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Installer validation requires Windows; no native checks may silently skip.' }
$PackageRootPath = [System.IO.Path]::GetFullPath($PackageRootPath).TrimEnd('\')
. (Join-Path $PackageRootPath 'scripts/runtime/goldberg_setup.ps1')
Set-StrictMode -Version Latest
$script:SetupChecks = 0
$script:SetupFailures = New-Object 'System.Collections.Generic.List[string]'

function Assert-SetupTrue {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-SetupEqual {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) { throw ('{0}: expected [{1}], received [{2}]' -f $Message, $Expected, $Actual) }
}

function Assert-SetupThrows {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action | Out-Null }
    catch { return }
    throw ('Expected rejection: ' + $Message)
}

function Invoke-SetupCheck {
    param([string]$Name, [scriptblock]$Action)
    $script:SetupChecks++
    try { & $Action | Out-Null; Write-Host ('PASS: ' + $Name) }
    catch {
        $message = $Name + ': ' + $_.Exception.Message
        [void]$script:SetupFailures.Add($message)
        Write-Host ('FAIL: ' + $message)
    }
}

function Write-SetupFixture {
    param([string]$Path, [AllowEmptyString()][string]$Text)
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-SetupJson {
    param([string]$Path, $Value)
    Write-SetupFixture -Path $Path -Text ($Value | ConvertTo-Json -Depth 14)
}

function Write-SetupIni {
    param([string]$Path, [hashtable]$Values)
    $lines = @('[MK1212]')
    foreach ($key in @('GameRoot', 'HostGameRoot', 'ClientGameRoot', 'ModsRoot', 'ToolkitRoot', 'SandboxieRoot')) {
        if ($Values.ContainsKey($key)) { $lines += ($key + '=' + [string]$Values[$key]) }
    }
    Write-SetupFixture -Path $Path -Text ($lines -join "`r`n")
}

function Get-SetupHashes {
    param([string]$Root)
    $result = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $Root -Recurse -Force -File)) {
        $relative = $file.FullName.Substring($Root.TrimEnd('\').Length).TrimStart('\')
        $result[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $result
}

function Assert-SetupHashes {
    param([hashtable]$Actual, [hashtable]$Expected, [string]$Message)
    Assert-SetupEqual $Actual.Count $Expected.Count ($Message + ' file count')
    foreach ($key in $Expected.Keys) {
        Assert-SetupTrue ($Actual.ContainsKey($key)) ($Message + ': missing ' + $key)
        Assert-SetupEqual $Actual[$key] $Expected[$key] ($Message + ': ' + $key)
    }
}

function New-SetupFixture {
    param([string]$Name)
    $sourceBase = Join-Path $setupTemp $Name
    $destinationBase = Join-Path $setupDriveTemp $Name
    $values = @{
        GameRoot = (Join-Path $sourceBase 'Original Attila [source]')
        ModsRoot = (Join-Path $sourceBase 'Original Workshop [mods]')
        HostGameRoot = (Join-Path $sourceBase 'Owned HOST/game')
        ClientGameRoot = (Join-Path $destinationBase 'Owned CLIENT/game')
        ToolkitRoot = (Join-Path $destinationBase 'Launcher')
        SandboxieRoot = ''
    }
    Write-SetupFixture (Join-Path $values.GameRoot 'Attila.exe') 'SYNTHETIC-EXE-NOT-EXECUTABLE'
    Write-SetupFixture (Join-Path $values.GameRoot 'steam_api.dll') 'SYNTHETIC-API-NOT-EXECUTABLE'
    Write-SetupFixture (Join-Path $values.GameRoot 'data/base.pack') 'ORIGINAL-GAME-DATA'
    Write-SetupFixture (Join-Path $values.ModsRoot '1001/selected.pack') 'ORIGINAL-WORKSHOP-DATA'
    $paths = Get-GoldbergSetupPaths -Values $values
    return [pscustomobject]@{ source_base = $sourceBase; destination_base = $destinationBase; values = $values; paths = $paths }
}

function New-SetupInstalledFixture {
    param($Paths)
    New-GoldbergSetupMarker -Paths $Paths -Package $setupPackage | Out-Null
    $manifestRecord = [pscustomobject]@{ path = 'package_manifest.json'; bytes = $setupPackage.manifest_bytes; sha256 = $setupPackage.manifest_sha256 }
    Copy-GoldbergSetupFile -SourceRoot $PackageRootPath -DestinationRoot $Paths.ToolkitRoot -Record $manifestRecord
    foreach ($record in $setupPackage.records) { Copy-GoldbergSetupFile -SourceRoot $PackageRootPath -DestinationRoot $Paths.ToolkitRoot -Record $record }
    return (Get-GoldbergSetupPackage -Root $Paths.ToolkitRoot)
}

$setupPackage = Get-GoldbergSetupPackage -Root $PackageRootPath
Import-Module (Join-Path $PackageRootPath 'scripts/runtime/dual_client_lab_core.psm1') -Force -DisableNameChecking
$packageBefore = Get-SetupHashes -Root $PackageRootPath
$setupTemp = Join-Path ([System.IO.Path]::GetTempPath()) ('mk1212-installer-tests-' + [Guid]::NewGuid().ToString('N'))
$setupDriveTemp = Join-Path ([System.IO.Path]::GetDirectoryName($PackageRootPath)) ('synthetic-installer-tests-' + [Guid]::NewGuid().ToString('N'))
if ([System.IO.Path]::GetPathRoot($setupDriveTemp).TrimEnd('\') -ieq [Environment]::GetEnvironmentVariable('SystemDrive')) { throw 'The exact package fixture must be on the non-system Windows CI drive.' }
[void][System.IO.Directory]::CreateDirectory($setupTemp)
[void][System.IO.Directory]::CreateDirectory($setupDriveTemp)

try {
    Invoke-SetupCheck 'The exact delivered package includes the pinned archive and every installer/runtime file' {
        Assert-SetupEqual $setupPackage.records.Count 15 'fixed delivered toolkit file count'
        Assert-SetupTrue ($setupPackage.source_sha -cmatch '^[0-9a-f]{40}$') 'exact source revision is recorded'
        foreach ($name in @('RUN-INSTALLED-GOLDBERG.cmd', 'scripts/runtime/goldberg_setup.ps1', 'scripts/runtime/goldberg_client_lab.ps1', 'third_party/nsis/LICENSE.txt', 'third_party/nsis/UPSTREAM.md')) {
            Assert-SetupEqual (@($setupPackage.records | Where-Object { $_.path -ceq $name }).Count) 1 ('required delivered file: ' + $name)
        }
        $archive = @($setupPackage.records | Where-Object { $_.path -ceq 'third_party/goldberg/goldberg-original-475342f0.zip' })[0]
        Assert-SetupEqual $archive.bytes 19360188 'official original archive bytes'
        Assert-SetupEqual $archive.sha256 '8465984b01b42a75f5faea8f2d884bbd6085a695c40c2b90eb0385f0a5081266' 'official original archive SHA256'
    }

    Invoke-SetupCheck 'Installer INI preserves Unicode and literal path text while rejecting ambiguous input' {
        $fixture = New-SetupFixture 'ini'
        $iniPath = Join-Path $fixture.source_base 'installer-input.ini'
        $values = $fixture.values.Clone()
        $values.HostGameRoot = 'C:\Literal [HOST] & ' + [char]0x0141 + 'odz'
        Write-SetupIni -Path $iniPath -Values $values
        $utf8 = Read-GoldbergSetupIni -Path $iniPath
        Assert-SetupEqual $utf8.HostGameRoot $values.HostGameRoot 'UTF8 literal input is not interpreted as a command'
        $iniText = [System.IO.File]::ReadAllText($iniPath)
        [System.IO.File]::WriteAllText($iniPath, $iniText, [System.Text.Encoding]::Unicode)
        Assert-SetupEqual (Read-GoldbergSetupIni -Path $iniPath).HostGameRoot $values.HostGameRoot 'NSIS UTF16LE input round trip'
        foreach ($invalid in @(
            ($iniText + "`r`nGameRoot=C:\different"),
            ($iniText + "`r`nUnknownKey=C:\different"),
            ($iniText + "`r`n[MK1212]"),
            $iniText.Replace('[MK1212]', '[Other]'),
            ('GameRoot=C:\outside' + "`r`n" + $iniText),
            $iniText.Replace('ToolkitRoot=', 'UnknownRoot=')
        )) {
            Write-SetupFixture $iniPath $invalid
            Assert-SetupThrows { Read-GoldbergSetupIni -Path $iniPath } 'malformed/duplicate/unknown installer input'
        }
        Write-SetupFixture $iniPath ('x' * 65537)
        Assert-SetupThrows { Read-GoldbergSetupIni -Path $iniPath } 'bounded installer input'
    }

    Invoke-SetupCheck 'Installer paths permit C: HOST and D: CLIENT while protecting source and toolkit trees' {
        $fixture = New-SetupFixture 'paths'
        $paths = $fixture.paths
        Assert-SetupEqual ([System.IO.Path]::GetPathRoot($paths.HostGameRoot).TrimEnd('\')) ([Environment]::GetEnvironmentVariable('SystemDrive')) 'HOST uses the system drive'
        Assert-SetupTrue ([System.IO.Path]::GetPathRoot($paths.HostGameRoot) -ine [System.IO.Path]::GetPathRoot($paths.ClientGameRoot)) 'CLIENT uses the other CI drive'
        Assert-SetupEqual $paths.LabRoot (Join-Path $paths.ToolkitRoot 'lab') 'owned lab path is derived from the toolkit'
        foreach ($replacement in @($paths.GameRoot, (Join-Path $paths.GameRoot 'copy'), $paths.ModsRoot, $paths.ClientGameRoot, (Join-Path $paths.ToolkitRoot 'HOST'), 'C:\', 'C:\unsafe%ROOT%', 'C:\unsafe\NUL')) {
            $bad = $fixture.values.Clone(); $bad.HostGameRoot = $replacement
            Assert-SetupThrows { Get-GoldbergSetupPaths -Values $bad } 'unsafe or overlapping HOST target'
        }
        Assert-SetupTrue (-not (Test-Path -LiteralPath $paths.ToolkitRoot)) 'path validation never creates toolkit directories'
        Assert-SetupTrue (-not (Test-Path -LiteralPath $paths.HostGameRoot)) 'path validation never creates game directories'
    }

    Invoke-SetupCheck 'Installer ownership rejects unowned data and preserves its original marker on retries' {
        $fixture = New-SetupFixture 'ownership'
        $paths = $fixture.paths
        Assert-GoldbergSetupOwnership -Paths $paths -Package $setupPackage | Out-Null
        $marker = New-GoldbergSetupMarker -Paths $paths -Package $setupPackage
        $markerPath = Join-Path $paths.ToolkitRoot 'installer-settings.json'
        $markerBefore = [System.IO.File]::ReadAllText($markerPath)
        Assert-SetupEqual (Assert-GoldbergSetupOwnership -Paths $paths -Package $setupPackage).installation_id $marker.installation_id 'exact marker can be reused'
        Assert-SetupThrows { New-GoldbergSetupMarker -Paths $paths -Package $setupPackage } 'marker cannot be replaced by a retry'
        Assert-SetupEqual ([System.IO.File]::ReadAllText($markerPath)) $markerBefore 'original owner survives marker collision'
        $changed = $fixture.values.Clone(); $changed.HostGameRoot = Join-Path $fixture.source_base 'Another HOST'
        $changedPaths = Get-GoldbergSetupPaths -Values $changed
        Assert-SetupThrows { Assert-GoldbergSetupOwnership -Paths $changedPaths -Package $setupPackage } 'saved role roots cannot be redirected'
        $unknown = $markerBefore | ConvertFrom-Json; $unknown.schema = 999
        Write-SetupJson $markerPath $unknown
        Assert-SetupThrows { Assert-GoldbergSetupOwnership -Paths $paths -Package $setupPackage } 'unknown ownership schema'
        Assert-SetupEqual (Read-GoldbergSetupJson -Path $markerPath).schema 999 'unsupported owner data is not rewritten'
        $unowned = New-SetupFixture 'unowned'
        Write-SetupFixture (Join-Path $unowned.paths.ToolkitRoot 'keep.txt') 'USER-DATA'
        Assert-SetupThrows { Assert-GoldbergSetupOwnership -Paths $unowned.paths -Package $setupPackage } 'unowned nonempty toolkit directory'
        Assert-SetupEqual ([System.IO.File]::ReadAllText((Join-Path $unowned.paths.ToolkitRoot 'keep.txt'))) 'USER-DATA' 'unowned data is retained'
    }

    Invoke-SetupCheck 'Toolkit copying preserves existing bytes and refuses destinations outside its fixed file set' {
        $destination = Join-Path $setupDriveTemp 'copy-files'
        $record = @($setupPackage.records | Where-Object { $_.path -ceq 'README.md' })[0]
        Copy-GoldbergSetupFile -SourceRoot $PackageRootPath -DestinationRoot $destination -Record $record
        $target = Join-Path $destination $record.path
        $before = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        Copy-GoldbergSetupFile -SourceRoot $PackageRootPath -DestinationRoot $destination -Record $record
        Assert-SetupEqual ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) $before 'matching toolkit copy is unchanged'
        Write-SetupFixture $target 'KEEP-EXISTING-CONTENT'
        Assert-SetupThrows { Copy-GoldbergSetupFile -SourceRoot $PackageRootPath -DestinationRoot $destination -Record $record } 'different retained toolkit file'
        Assert-SetupEqual ([System.IO.File]::ReadAllText($target)) 'KEEP-EXISTING-CONTENT' 'copy conflict is never overwritten'
        $escape = [pscustomobject]@{ path = '../escaped.txt'; bytes = $record.bytes; sha256 = $record.sha256 }
        Assert-SetupThrows { Copy-GoldbergSetupFile -SourceRoot $PackageRootPath -DestinationRoot $destination -Record $escape } 'direct crafted file record escapes the allowlist'
        Assert-SetupTrue (-not (Test-Path -LiteralPath (Join-Path $setupDriveTemp 'escaped.txt'))) 'no file escaped its toolkit root'
    }

    Invoke-SetupCheck 'Package verification rejects same-size tampering even when missing files are permitted for uninstall' {
        $fixture = New-SetupFixture 'tamper'
        $installed = New-SetupInstalledFixture -Paths $fixture.paths
        Assert-SetupEqual $installed.manifest_sha256 $setupPackage.manifest_sha256 'copied package identity matches delivery'
        $target = Join-Path $fixture.paths.ToolkitRoot 'scripts/runtime/goldberg_client_lab.ps1'
        $originalBytes = [System.IO.File]::ReadAllBytes($target)
        $stream = [System.IO.File]::Open($target, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try { $first = $stream.ReadByte(); $stream.Position = 0; $stream.WriteByte([byte]($first -bxor 1)) } finally { $stream.Dispose() }
        $tamperedBefore = Get-SetupHashes -Root $fixture.paths.ToolkitRoot
        Assert-SetupThrows { Get-GoldbergSetupPackage -Root $fixture.paths.ToolkitRoot } 'same-size runtime tamper'
        Assert-SetupThrows { Get-GoldbergSetupPackage -Root $fixture.paths.ToolkitRoot -AllowMissing } 'present modified files cannot masquerade as missing files'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ToolkitRoot) $tamperedBefore 'failed package verification preserves all bytes'
        [System.IO.File]::Delete($target)
        Assert-SetupThrows { Get-GoldbergSetupPackage -Root $fixture.paths.ToolkitRoot } 'incomplete package is not accepted for install or launch'
        $partial = Get-GoldbergSetupPackage -Root $fixture.paths.ToolkitRoot -AllowMissing
        Assert-SetupEqual $partial.manifest_sha256 $setupPackage.manifest_sha256 'missing-file uninstall retry keeps the fixed original package identity'
        [System.IO.File]::WriteAllBytes($target, $originalBytes)
    }

    Invoke-SetupCheck 'Uninstall checks a changed manifest before deleting any toolkit, game or evidence file' {
        $fixture = New-SetupFixture 'uninstall-manifest-race'
        $cachedPackage = New-SetupInstalledFixture -Paths $fixture.paths
        Write-SetupFixture (Join-Path $fixture.paths.LabRoot 'evidence/keep.json') '{"preserve":true}'
        $manifestPath = Join-Path $fixture.paths.ToolkitRoot 'package_manifest.json'
        $manifest = [System.IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        $manifest.source_sha = 'f' * 40
        Write-SetupJson $manifestPath $manifest
        $before = Get-SetupHashes -Root $fixture.paths.ToolkitRoot
        Assert-SetupThrows { Remove-GoldbergSetupFiles -Paths $fixture.paths -Package $cachedPackage } 'manifest changed after its earlier verification'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ToolkitRoot) $before 'rejected uninstall removes no previously valid files'
    }

    Invoke-SetupCheck 'Actual installed helper uninstall removes only owned toolkit files and keeps game data and reports' {
        $fixture = New-SetupFixture 'uninstall-preservation'
        $paths = $fixture.paths
        New-SetupInstalledFixture -Paths $paths | Out-Null
        $preserved = @{
            (Join-Path $paths.ToolkitRoot 'user-notes.txt') = 'KEEP-USER-NOTES'
            (Join-Path $paths.LabRoot 'save_games/turn_0123.save') = 'KEEP-LONG-CAMPAIGN'
            (Join-Path $paths.LabRoot 'evidence/report.json') = '{"multiplayer":"NOT_RUN"}'
            (Join-Path $paths.HostGameRoot 'data/selected.pack') = 'KEEP-HOST-COPY'
            (Join-Path $paths.ClientGameRoot 'data/selected.pack') = 'KEEP-CLIENT-COPY'
        }
        foreach ($path in $preserved.Keys) { Write-SetupFixture $path $preserved[$path] }
        $sourceBefore = Get-SetupHashes -Root $paths.GameRoot
        $modsBefore = Get-SetupHashes -Root $paths.ModsRoot
        $shellExecutable = (Get-Process -Id $PID).Path
        $result = Invoke-LabNative -Executable $shellExecutable -TimeoutSeconds 45 -Arguments @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $paths.ToolkitRoot 'scripts/runtime/goldberg_setup.ps1'),
            '-Mode', 'Uninstall', '-SettingsPath', (Join-Path $paths.ToolkitRoot 'installer-settings.json')
        )
        Assert-SetupEqual $result.ExitCode 0 'actual installed helper uninstall exit code'
        Assert-SetupTrue ($result.Output -match 'MK1212_SETUP_STATUS=UNINSTALLED_TOOLKIT_FILES') 'actual uninstall reports its limited scope'
        foreach ($record in $setupPackage.records) { Assert-SetupTrue (-not (Test-Path -LiteralPath (Join-Path $paths.ToolkitRoot $record.path))) ('owned toolkit file removed: ' + $record.path) }
        Assert-SetupTrue (-not (Test-Path -LiteralPath (Join-Path $paths.ToolkitRoot 'installer-settings.json'))) 'owned installer marker is removed'
        foreach ($path in $preserved.Keys) { Assert-SetupEqual ([System.IO.File]::ReadAllText($path)) $preserved[$path] ('preserved output: ' + $path) }
        foreach ($directory in @($paths.ToolkitRoot, $paths.LabRoot, $paths.HostGameRoot, $paths.ClientGameRoot)) { Assert-SetupTrue (Test-Path -LiteralPath $directory -PathType Container) 'all user/game/lab directories are preserved' }
        Assert-SetupHashes (Get-SetupHashes -Root $paths.GameRoot) $sourceBefore 'uninstall preserves the original installation'
        Assert-SetupHashes (Get-SetupHashes -Root $paths.ModsRoot) $modsBefore 'uninstall preserves original Workshop files'
    }

    Invoke-SetupCheck 'Actual Install entry blocks a missing original game before writing any destination' {
        $fixture = New-SetupFixture 'missing-source'
        $values = $fixture.values.Clone()
        $values.GameRoot = Join-Path $fixture.source_base 'Missing original game'
        $iniPath = Join-Path $fixture.source_base 'setup-input.ini'
        Write-SetupIni -Path $iniPath -Values $values
        $sourceBefore = Get-SetupHashes -Root $fixture.paths.GameRoot
        $modsBefore = Get-SetupHashes -Root $fixture.paths.ModsRoot
        $shellExecutable = (Get-Process -Id $PID).Path
        $result = Invoke-LabNative -Executable $shellExecutable -TimeoutSeconds 45 -Arguments @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PackageRootPath 'scripts/runtime/goldberg_setup.ps1'),
            '-Mode', 'Install', '-SettingsPath', $iniPath
        )
        Assert-SetupEqual $result.ExitCode 2 'missing-source install exit code'
        Assert-SetupTrue ($result.Output -match 'MK1212_SETUP_STATUS=BLOCKED') 'missing source is not reported as installed'
        foreach ($destination in @($values.ToolkitRoot, $values.HostGameRoot, $values.ClientGameRoot)) { Assert-SetupTrue (-not (Test-Path -LiteralPath $destination)) 'blocked install creates no toolkit or game destination' }
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.GameRoot) $sourceBefore 'failed install preserves original game bytes'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ModsRoot) $modsBefore 'failed install preserves original Workshop bytes'
    }

    Invoke-SetupCheck 'All installer checks preserve the original delivered package' {
        Assert-SetupHashes (Get-SetupHashes -Root $PackageRootPath) $packageBefore 'delivered package remains unchanged'
    }
}
finally {
    if (Test-Path -LiteralPath $setupTemp) { Remove-Item -LiteralPath $setupTemp -Recurse -Force }
    if (Test-Path -LiteralPath $setupDriveTemp) { Remove-Item -LiteralPath $setupDriveTemp -Recurse -Force }
}

Write-Host ('Goldberg installer checks: {0} run, {1} failed. Game preparation and multiplayer NOT_RUN.' -f $script:SetupChecks, $script:SetupFailures.Count)
if ($script:SetupFailures.Count -gt 0) { throw ($script:SetupFailures -join [Environment]::NewLine) }
