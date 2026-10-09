[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackageRootPath,
    [Parameter(Mandatory = $true)][string[]]$PreviousPackageRoots
)

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

function New-SetupPreviousInstalledFixture {
    param($Fixture, $PreviousPackage)
    New-GoldbergSetupMarker -Paths $Fixture.paths -Package $PreviousPackage | Out-Null
    $manifestRecord = [pscustomobject]@{ path = 'package_manifest.json'; bytes = $PreviousPackage.manifest_bytes; sha256 = $PreviousPackage.manifest_sha256 }
    Copy-GoldbergSetupFile -SourceRoot $PreviousPackage.root -DestinationRoot $Fixture.paths.ToolkitRoot -Record $manifestRecord
    foreach ($record in $PreviousPackage.records) { Copy-GoldbergSetupFile -SourceRoot $PreviousPackage.root -DestinationRoot $Fixture.paths.ToolkitRoot -Record $record }
    # A real previous Install acquired this lock before copying and invoking Prepare.
    Write-SetupFixture (Join-Path $Fixture.paths.ToolkitRoot '.goldberg-setup.lock') ''
    return (Assert-GoldbergSetupOwnership -Paths $Fixture.paths -Package $PreviousPackage)
}

function Add-SetupSandboxieFixture {
    param($Fixture)
    $root = Join-Path $Fixture.source_base 'Sandboxie [resolver only]'
    # Discovery checks these files; the test never executes either fixture.
    Write-SetupFixture (Join-Path $root 'Start.exe') 'INERT-SANDBOXIE-DISCOVERY-FIXTURE'
    Write-SetupFixture (Join-Path $root 'SbieIni.exe') 'INERT-SANDBOXIE-DISCOVERY-FIXTURE'
    $Fixture.values.SandboxieRoot = $root
    $Fixture.paths = Get-GoldbergSetupPaths -Values $Fixture.values
}

function Invoke-SetupInstallFixture {
    param($Fixture, [string]$InputPath, [int]$PreparationExitCode = 0,
        [ValidateSet('None', 'AfterBackup', 'AfterStagingData', 'AfterUpgradeFile')][string]$RecoveryFault = 'None', [string]$LateFilePath)
    $token = [Guid]::NewGuid().ToString('N')
    $driverPath = Join-Path $Fixture.source_base ('test-only-install-driver-' + $token + '.ps1')
    $tracePath = Join-Path $Fixture.source_base ('test-only-preparation-boundary-' + $token + '.json')
    # This driver exists only in test-owned temporary storage. The exact helper,
    # Sandboxie discovery/module import, ownership checks and copying stay real.
    # Game preparation is substituted; requested recovery faults run after the
    # original exclusive metadata writer and never change the delivered helper.
    $driver = @'
[CmdletBinding()]
param([string]$ExactPackageRoot, [string]$FixtureInputPath, [string]$FixtureTracePath, [int]$FixturePreparationExit,
    [string]$FixtureRecoveryFault = 'None', [string]$FixtureLateFilePath)
. (Join-Path $ExactPackageRoot 'scripts/runtime/goldberg_setup.ps1')
if (@('AfterBackup', 'AfterStagingData') -contains $FixtureRecoveryFault) {
    $script:FixtureOriginalExclusiveWrite = (Get-Command Write-GoldbergSetupExclusiveBytes -CommandType Function).ScriptBlock
    function Write-GoldbergSetupExclusiveBytes {
        param([string]$Path, [byte[]]$Bytes)
        # Retain the real exclusive write and fail only after its bytes exist.
        & $script:FixtureOriginalExclusiveWrite -Path $Path -Bytes $Bytes
        $leaf = [IO.Path]::GetFileName($Path)
        if ($FixtureRecoveryFault -eq 'AfterBackup' -and $leaf -cmatch '^installer-settings\.recovered-7f66f06a-[0-9a-f]{32}\.json$') {
            throw 'TEST_ONLY_RECOVERY_FAILURE_AFTER_BACKUP'
        }
        if ($FixtureRecoveryFault -eq 'AfterStagingData' -and $leaf -cmatch '^\.installer-recovery-[0-9a-f]{32}\.tmp$') {
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($FixtureLateFilePath))
            $late = New-Object IO.FileStream -ArgumentList $FixtureLateFilePath, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
            try {
                $content = [Text.Encoding]::UTF8.GetBytes('TEST-OWNED-NEW-DATA-MUST-SURVIVE')
                $late.Write($content, 0, $content.Length)
            } finally { $late.Dispose() }
            [Console]::Out.WriteLine('TEST_ONLY_NEW_DESTINATION_DATA_AFTER_STAGING')
        }
    }
}
if ($FixtureRecoveryFault -eq 'AfterUpgradeFile') {
    $script:FixtureOriginalUpgradeWrite = (Get-Command Set-GoldbergSetupUpgradeFile -CommandType Function).ScriptBlock
    function Set-GoldbergSetupUpgradeFile {
        param($SourceRoot, $StagedRoot, $DestinationRoot, $OldRecord, $NewRecord)
        $changed = & $script:FixtureOriginalUpgradeWrite -SourceRoot $SourceRoot -StagedRoot $StagedRoot -DestinationRoot $DestinationRoot -OldRecord $OldRecord -NewRecord $NewRecord
        if ($changed -and $NewRecord.path -ceq 'scripts/runtime/goldberg_client_lab_core.psm1') {
            throw 'TEST_ONLY_UPGRADE_FAILURE_AFTER_RUNTIME_REPLACEMENT'
        }
        return $changed
    }
}
function Invoke-GoldbergSetupMain {
    param($Paths, [string]$MainMode)
    if ([IO.File]::Exists($FixtureTracePath)) { throw 'Test-only preparation boundary was invoked more than once.' }
    $trace = [ordered]@{
        boundary = 'TEST_ONLY_GAME_PREPARATION_STUB'
        attila_and_sandboxie_execution = 'NOT_RUN'
        main_mode = $MainMode
        helper_payload_root = $script:GoldSetupRoot
        paths = $Paths
        returned_exit_code = $FixturePreparationExit
    }
    [IO.File]::WriteAllText($FixtureTracePath, ($trace | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    [Console]::Out.WriteLine('TEST_ONLY_GAME_PREPARATION_STUB; Attila/Sandboxie execution NOT_RUN.')
    return $FixturePreparationExit
}
exit (Invoke-GoldbergSetup -Mode Install -SettingsPath $FixtureInputPath)
'@
    Write-SetupFixture -Path $driverPath -Text $driver
    $shellExecutable = (Get-Process -Id $PID).Path
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $driverPath,
        '-ExactPackageRoot', $PackageRootPath, '-FixtureInputPath', $InputPath,
        '-FixtureTracePath', $tracePath, '-FixturePreparationExit', ([string]$PreparationExitCode),
        '-FixtureRecoveryFault', $RecoveryFault
    )
    if ($LateFilePath) { $arguments += @('-FixtureLateFilePath', $LateFilePath) }
    $result = Invoke-LabNative -Executable $shellExecutable -TimeoutSeconds 60 -Arguments $arguments
    $trace = $null
    if (Test-Path -LiteralPath $tracePath -PathType Leaf) { $trace = Read-GoldbergSetupJson -Path $tracePath }
    return [pscustomobject]@{ process = $result; trace = $trace; trace_path = $tracePath }
}

function New-SetupLegacyMarkerFixture {
    param($Fixture, [string]$RecordedToolkitRoot)
    if (-not $RecordedToolkitRoot) { $RecordedToolkitRoot = $Fixture.paths.ToolkitRoot }
    $marker = [ordered]@{
        schema = 1
        owner = 'MK1212Scripts.goldberg-installer'
        installation_id = [Guid]::NewGuid().ToString('N')
        source_sha = '7f66f06afddc53fda220f22d1940242ebd87e4ab'
        package_manifest_sha256 = '6437e64419ff4337bf43ae2f62976f503e3878571f876ba09a4ec4d4c744f435'
        created_utc = '2026-10-08T10:11:12.1234567Z'
    }
    foreach ($key in @('GameRoot', 'ModsRoot', 'HostGameRoot', 'ClientGameRoot', 'SandboxieRoot')) { $marker[$key] = [string]$Fixture.paths.$key }
    $marker.ToolkitRoot = $RecordedToolkitRoot
    $marker.LabRoot = Join-Path $RecordedToolkitRoot 'lab'
    $markerPath = Join-Path $Fixture.paths.ToolkitRoot 'installer-settings.json'
    Write-SetupJson -Path $markerPath -Value $marker
    return [pscustomobject]@{ marker = $marker; path = $markerPath; recorded_toolkit_root = $RecordedToolkitRoot; recorded_lab_root = $marker.LabRoot }
}

$setupPackage = Get-GoldbergSetupPackage -Root $PackageRootPath
Import-Module (Join-Path $PackageRootPath 'scripts/runtime/dual_client_lab_core.psm1') -Force -DisableNameChecking
$packageBefore = Get-SetupHashes -Root $PackageRootPath
$previousIdentities = @{
    '7f66f06afddc53fda220f22d1940242ebd87e4ab' = '6437e64419ff4337bf43ae2f62976f503e3878571f876ba09a4ec4d4c744f435'
    'f5158fa52138d87ef00fa154b3fb50b636dabc23' = '58dda3727415324429da1f5eccd11ae9d2674570d6198bda367bb51f3cff5837'
}
$previousPackages = @{}
$previousPackageHashes = @{}
foreach ($previousRoot in $PreviousPackageRoots) {
    $previous = Get-GoldbergSetupPackage -Root ([IO.Path]::GetFullPath($previousRoot).TrimEnd('\'))
    if (-not $previousIdentities.ContainsKey($previous.source_sha) -or $previous.manifest_sha256 -cne $previousIdentities[$previous.source_sha] -or $previousPackages.ContainsKey($previous.source_sha)) { throw 'Historical fixtures must be the two distinct authentic released payloads.' }
    $previousPackages[$previous.source_sha] = $previous
    $previousPackageHashes[$previous.source_sha] = Get-SetupHashes -Root $previous.root
}
if ($previousPackages.Count -ne 2) { throw 'Both historical released packages are required; upgrade checks may not skip.' }
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

    Invoke-SetupCheck 'Owned lab JSON state is atomically replaced and read back without modifying original game or Workshop files' {
        $fixture = New-SetupFixture 'owned-state-replacement'
        [void][IO.Directory]::CreateDirectory($fixture.paths.LabRoot)
        $path = Join-Path $fixture.paths.LabRoot '.test-owned-state.json'
        $sourceBefore = Get-SetupHashes -Root $fixture.paths.GameRoot
        $modsBefore = Get-SetupHashes -Root $fixture.paths.ModsRoot
        $labId = [Guid]::NewGuid().ToString('N')
        Write-LabJson -Path $path -Value ([ordered]@{ schema = 1; lab_id = $labId; revision = 0; status = 'INITIAL_SYNTHETIC_STATE' })
        $original = [IO.File]::ReadAllText($path)
        Write-LabJson -Path $path -ReplaceOwned -Value ([ordered]@{ schema = 1; lab_id = $labId; revision = 1; status = 'UPDATED_SYNTHETIC_STATE'; source_catalog_sha256 = ('a' * 64) })
        $updated = Read-LabJson -Path $path
        Assert-SetupEqual $updated.lab_id $labId 'owned state replacement preserves the lab identity'
        Assert-SetupEqual $updated.revision 1 'replacement revision is actually persisted'
        Assert-SetupEqual $updated.status 'UPDATED_SYNTHETIC_STATE' 'changed state reads back through the real helper'
        Assert-SetupEqual $updated.source_catalog_sha256 ('a' * 64) 'newly added state fields survive atomic replacement'
        Assert-SetupTrue ([IO.File]::ReadAllText($path) -cne $original) 'successful replacement changes the original state bytes'
        Assert-SetupEqual (@(Get-ChildItem -LiteralPath $fixture.paths.LabRoot -Force).Count) 1 'successful replacement leaves no temporary or backup file'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.GameRoot) $sourceBefore 'state replacement preserves original game bytes'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ModsRoot) $modsBefore 'state replacement preserves original Workshop bytes'
    }

    Invoke-SetupCheck 'Public Install resolves Sandboxie and creates a complete owned toolkit before the explicit game stub' {
        $fixture = New-SetupFixture ('public-install-' + [char]0x0142)
        Add-SetupSandboxieFixture -Fixture $fixture
        $inputPath = Join-Path $fixture.source_base ('settings ' + [char]0x0142 + '.ini')
        $values = $fixture.values.Clone()
        $values.ToolkitRoot += '\'
        Write-SetupIni -Path $inputPath -Values $values
        $sourceBefore = Get-SetupHashes -Root $fixture.paths.GameRoot
        $modsBefore = Get-SetupHashes -Root $fixture.paths.ModsRoot
        $sandboxieBefore = Get-SetupHashes -Root $fixture.paths.SandboxieRoot
        $inputBefore = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
        $first = Invoke-SetupInstallFixture -Fixture $fixture -InputPath $inputPath
        Assert-SetupEqual $first.process.ExitCode 0 ('public Install orchestration: ' + $first.process.Output)
        Assert-SetupTrue ($null -ne $first.trace) 'real Install reaches the explicit external game-preparation boundary'
        Assert-SetupEqual $first.trace.boundary 'TEST_ONLY_GAME_PREPARATION_STUB' 'only game preparation is substituted'
        Assert-SetupEqual $first.trace.attila_and_sandboxie_execution 'NOT_RUN' 'synthetic setup cannot prove game execution'
        Assert-SetupEqual $first.trace.main_mode 'Prepare' 'Install requests the preparation stage'
        Assert-SetupEqual ($first.trace.helper_payload_root.TrimEnd('\')) $PackageRootPath 'helper keeps its exact payload root after module import'
        foreach ($key in @('GameRoot', 'HostGameRoot', 'ClientGameRoot', 'ModsRoot', 'ToolkitRoot', 'LabRoot', 'SandboxieRoot')) {
            Assert-SetupEqual $first.trace.paths.$key $fixture.paths.$key ('resolved path passed to preparation: ' + $key)
        }
        $installed = Get-GoldbergSetupPackage -Root $fixture.paths.ToolkitRoot
        Assert-SetupEqual $installed.manifest_sha256 $setupPackage.manifest_sha256 'public Install copies the exact delivered package'
        $marker = Assert-GoldbergSetupOwnership -Paths $fixture.paths -Package $setupPackage
        Assert-SetupEqual $marker.ToolkitRoot $fixture.paths.ToolkitRoot 'new marker has the canonical requested ToolkitRoot'
        $installedBefore = Get-SetupHashes -Root $fixture.paths.ToolkitRoot
        $repeat = Invoke-SetupInstallFixture -Fixture $fixture -InputPath $inputPath
        Assert-SetupEqual $repeat.process.ExitCode 0 ('same-folder Install retry: ' + $repeat.process.Output)
        Assert-SetupTrue ($null -ne $repeat.trace) 'matching retry reaches the external preparation boundary'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ToolkitRoot) $installedBefore 'matching retry preserves marker and installed package bytes'
        $blocked = Invoke-SetupInstallFixture -Fixture $fixture -InputPath $inputPath -PreparationExitCode 19
        Assert-SetupEqual $blocked.process.ExitCode 19 'preparation failure exit code is propagated'
        Assert-SetupTrue ($blocked.process.Output -match 'MK1212_SETUP_STATUS=BLOCKED') 'preparation failure cannot report successful setup'
        Assert-SetupTrue ($blocked.process.Output -notmatch 'MK1212_SETUP_STATUS=INSTALLED_PREPARED') 'blocked boundary cannot emit prepared status'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ToolkitRoot) $installedBefore 'failed preparation preserves the usable toolkit for retry'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.GameRoot) $sourceBefore 'complete Install control flow preserves original game'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ModsRoot) $modsBefore 'complete Install control flow preserves Workshop files'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.SandboxieRoot) $sandboxieBefore 'resolution never executes or modifies inert Sandboxie fixtures'
        Assert-SetupEqual ((Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash) $inputBefore 'Install and retry preserve the input INI'
        foreach ($path in @($fixture.paths.HostGameRoot, $fixture.paths.ClientGameRoot, $fixture.paths.LabRoot)) { Assert-SetupTrue (-not (Test-Path -LiteralPath $path)) 'test boundary does not fabricate game copies or lab readiness' }
    }

    Invoke-SetupCheck 'Public Install upgrades both authentic previous toolkits, retaining exact backups, sources and matching retries' {
        foreach ($sha in @($previousIdentities.Keys | Sort-Object)) {
            $previous = $previousPackages[$sha]
            $fixture = New-SetupFixture ('full-upgrade-' + $sha.Substring(0, 8))
            Add-SetupSandboxieFixture -Fixture $fixture
            $oldMarker = New-SetupPreviousInstalledFixture -Fixture $fixture -PreviousPackage $previous
            $markerPath = Join-Path $fixture.paths.ToolkitRoot 'installer-settings.json'
            $oldMarkerBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($markerPath))
            $notePath = Join-Path $fixture.paths.ToolkitRoot 'user-notes.txt'
            Write-SetupFixture $notePath 'USER-NOTES-OUTSIDE-THE-TOOLKIT-FILE-LIST'
            $sourceBefore = Get-SetupHashes -Root $fixture.paths.GameRoot
            $modsBefore = Get-SetupHashes -Root $fixture.paths.ModsRoot
            $inputPath = Join-Path $fixture.source_base 'upgrade.ini'
            Write-SetupIni -Path $inputPath -Values $fixture.values
            $result = Invoke-SetupInstallFixture -Fixture $fixture -InputPath $inputPath
            Assert-SetupEqual $result.process.ExitCode 0 ('authentic prior toolkit upgrade: ' + $sha + '; ' + $result.process.Output)
            Assert-SetupTrue ($null -ne $result.trace) 'completed upgrade reaches the explicit test-only preparation boundary'
            Assert-SetupEqual $result.trace.attila_and_sandboxie_execution 'NOT_RUN' 'toolkit upgrade cannot claim game execution'
            Assert-SetupEqual (Get-GoldbergSetupPackage -Root $fixture.paths.ToolkitRoot).manifest_sha256 $setupPackage.manifest_sha256 'all installed current package files match delivery'
            $marker = Assert-GoldbergSetupOwnership -Paths $fixture.paths -Package $setupPackage
            Assert-SetupEqual $marker.installation_id $oldMarker.installation_id 'upgrade preserves installation identity'
            Assert-SetupEqual (([DateTimeOffset]$marker.created_utc).UtcDateTime.Ticks) (([DateTimeOffset]$oldMarker.created_utc).UtcDateTime.Ticks) 'upgrade preserves the original creation instant'
            Assert-SetupEqual $marker.upgrade.from_source_sha $sha 'marker identifies the authentic previous release'
            Assert-SetupEqual $marker.upgrade.from_manifest_sha256 $previous.manifest_sha256 'marker identifies the authentic previous manifest'
            $backupRoot = Join-Path $fixture.paths.ToolkitRoot ('.installer-upgrade-' + $setupPackage.source_sha + '.backup')
            Assert-SetupEqual (Get-GoldbergSetupPackage -Root $backupRoot).manifest_sha256 $previous.manifest_sha256 'backup retains every exact previous toolkit file'
            Assert-SetupEqual ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $backupRoot 'installer-settings.json')))) $oldMarkerBytes 'upgrade preserves the exact original settings bytes'
            Assert-SetupTrue (-not (Test-Path -LiteralPath (Join-Path $fixture.paths.ToolkitRoot 'installer-upgrade.json'))) 'completed upgrade leaves no active transaction journal'
            Assert-SetupEqual ([IO.File]::ReadAllText($notePath)) 'USER-NOTES-OUTSIDE-THE-TOOLKIT-FILE-LIST' 'upgrade preserves unrelated user notes'
            Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.GameRoot) $sourceBefore 'upgrade preserves source game bytes'
            Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ModsRoot) $modsBefore 'upgrade preserves Workshop bytes'
            $installedBefore = Get-SetupHashes -Root $fixture.paths.ToolkitRoot
            $repeat = Invoke-SetupInstallFixture -Fixture $fixture -InputPath $inputPath
            Assert-SetupEqual $repeat.process.ExitCode 0 ('current-version retry after upgrade: ' + $repeat.process.Output)
            Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ToolkitRoot) $installedBefore 'matching retry preserves current files, original backup and user notes'
            foreach ($path in @($fixture.paths.HostGameRoot, $fixture.paths.ClientGameRoot, $fixture.paths.LabRoot)) { Assert-SetupTrue (-not (Test-Path -LiteralPath $path)) 'toolkit upgrade at the stub boundary creates no game copy or lab' }
        }
    }

    Invoke-SetupCheck 'An interrupted real toolkit replacement resumes its fixed journal without manual cleanup or source changes' {
        $previous = $previousPackages['7f66f06afddc53fda220f22d1940242ebd87e4ab']
        $fixture = New-SetupFixture 'full-upgrade-interruption'
        Add-SetupSandboxieFixture -Fixture $fixture
        $oldMarker = New-SetupPreviousInstalledFixture -Fixture $fixture -PreviousPackage $previous
        $markerPath = Join-Path $fixture.paths.ToolkitRoot 'installer-settings.json'
        $oldMarkerBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($markerPath))
        $sourceBefore = Get-SetupHashes -Root $fixture.paths.GameRoot
        $modsBefore = Get-SetupHashes -Root $fixture.paths.ModsRoot
        $inputPath = Join-Path $fixture.source_base 'interrupted-upgrade.ini'
        Write-SetupIni -Path $inputPath -Values $fixture.values
        $failed = Invoke-SetupInstallFixture -Fixture $fixture -InputPath $inputPath -RecoveryFault AfterUpgradeFile
        Assert-SetupEqual $failed.process.ExitCode 2 ('injected toolkit replacement failure: ' + $failed.process.Output)
        Assert-SetupTrue ($failed.process.Output -match 'TEST_ONLY_UPGRADE_FAILURE_AFTER_RUNTIME_REPLACEMENT') 'failure occurs after the real changed runtime file replacement'
        Assert-SetupTrue ($null -eq $failed.trace) 'interrupted toolkit update never invokes preparation'
        $newRecord = @($setupPackage.records | Where-Object { $_.path -ceq 'scripts/runtime/goldberg_client_lab_core.psm1' })[0]
        Assert-SetupEqual ((Get-FileHash -LiteralPath (Join-Path $fixture.paths.ToolkitRoot $newRecord.path) -Algorithm SHA256).Hash.ToLowerInvariant()) $newRecord.sha256 'interrupted destination contains a genuinely replaced current runtime file'
        Assert-SetupEqual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($markerPath))) $oldMarkerBytes 'ownership marker commits only after toolkit files succeed'
        $journalPath = Join-Path $fixture.paths.ToolkitRoot 'installer-upgrade.json'
        $journal = Read-GoldbergSetupJson -Path $journalPath
        Assert-SetupEqual $journal.from_source_sha $previous.source_sha 'retained journal binds the exact old release'
        Assert-SetupEqual $journal.to_source_sha $setupPackage.source_sha 'retained journal binds the exact update target'
        $backupRoot = Join-Path $fixture.paths.ToolkitRoot $journal.backup_leaf
        Assert-SetupEqual (Get-GoldbergSetupPackage -Root $backupRoot).manifest_sha256 $previous.manifest_sha256 'all prior toolkit files are backed up before the first replacement'
        Assert-SetupEqual ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $backupRoot 'installer-settings.json')))) $oldMarkerBytes 'interrupted update retains the exact previous marker backup'
        # Do not delete journals, rewrite markers or reset any file before retry.
        $retry = Invoke-SetupInstallFixture -Fixture $fixture -InputPath $inputPath
        Assert-SetupEqual $retry.process.ExitCode 0 ('interrupted upgrade resumes without cleanup: ' + $retry.process.Output)
        Assert-SetupTrue ($null -ne $retry.trace) 'verified resume reaches the test-only preparation boundary'
        Assert-SetupEqual (Get-GoldbergSetupPackage -Root $fixture.paths.ToolkitRoot).manifest_sha256 $setupPackage.manifest_sha256 'resume finishes the complete current payload'
        Assert-SetupEqual (Assert-GoldbergSetupOwnership -Paths $fixture.paths -Package $setupPackage).installation_id $oldMarker.installation_id 'resumed update retains installation identity'
        Assert-SetupTrue (-not (Test-Path -LiteralPath $journalPath)) 'successful resume finalizes the active journal'
        Assert-SetupEqual (Get-GoldbergSetupPackage -Root $backupRoot).manifest_sha256 $previous.manifest_sha256 'resume preserves the complete previous payload backup'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.GameRoot) $sourceBefore 'interruption and resume preserve original game'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ModsRoot) $modsBefore 'interruption and resume preserve Workshop'
    }

    Invoke-SetupCheck 'Full toolkit upgrades refuse changed old files, populated destinations and changed paths while preserving existing data' {
        foreach ($case in @('changed-runtime', 'populated-lab', 'populated-host', 'changed-path')) {
            $previous = $previousPackages['f5158fa52138d87ef00fa154b3fb50b636dabc23']
            $fixture = New-SetupFixture ('full-upgrade-refused-' + $case)
            Add-SetupSandboxieFixture -Fixture $fixture
            $marker = New-SetupPreviousInstalledFixture -Fixture $fixture -PreviousPackage $previous
            switch ($case) {
                'changed-runtime' { Write-SetupFixture (Join-Path $fixture.paths.ToolkitRoot 'scripts/runtime/goldberg_client_lab_core.psm1') 'USER-CHANGED-RUNTIME-MUST-SURVIVE' }
                'populated-lab' { Write-SetupFixture (Join-Path $fixture.paths.LabRoot 'save_games/keep.save') 'KEEP-CAMPAIGN' }
                'populated-host' { Write-SetupFixture (Join-Path $fixture.paths.HostGameRoot 'data/keep.pack') 'KEEP-HOST-COPY' }
                'changed-path' { $marker.GameRoot = Join-Path $fixture.source_base 'Different source'; Write-SetupJson (Join-Path $fixture.paths.ToolkitRoot 'installer-settings.json') $marker }
            }
            $inputPath = Join-Path $fixture.source_base 'refused-upgrade.ini'
            Write-SetupIni -Path $inputPath -Values $fixture.values
            $destinationBefore = Get-SetupHashes -Root $fixture.destination_base
            $sourceBefore = Get-SetupHashes -Root $fixture.paths.GameRoot
            $modsBefore = Get-SetupHashes -Root $fixture.paths.ModsRoot
            $hostBefore = $null
            if (Test-Path -LiteralPath $fixture.paths.HostGameRoot) { $hostBefore = Get-SetupHashes -Root $fixture.paths.HostGameRoot }
            $result = Invoke-SetupInstallFixture -Fixture $fixture -InputPath $inputPath
            Assert-SetupEqual $result.process.ExitCode 2 ('ineligible full update must block: ' + $case + '; ' + $result.process.Output)
            Assert-SetupTrue ($null -eq $result.trace) ('ineligible update never reaches preparation: ' + $case)
            Assert-SetupHashes (Get-SetupHashes -Root $fixture.destination_base) $destinationBefore ('rejected update preserves all existing toolkit and lab bytes: ' + $case)
            Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.GameRoot) $sourceBefore ('rejected update preserves source game: ' + $case)
            Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ModsRoot) $modsBefore ('rejected update preserves Workshop: ' + $case)
            if ($null -ne $hostBefore) { Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.HostGameRoot) $hostBefore 'rejected update preserves existing HOST data' }
            else { Assert-SetupTrue (-not (Test-Path -LiteralPath $fixture.paths.HostGameRoot)) 'rejected update creates no HOST copy' }
        }
    }

    Invoke-SetupCheck 'Public Install safely recovers only the exact previous marker and preserves its bytes on same-folder and moved retries' {
        foreach ($moved in @($false, $true)) {
            $fixture = New-SetupFixture ('legacy-positive-' + [string]$moved)
            Add-SetupSandboxieFixture -Fixture $fixture
            $recordedRoot = $fixture.paths.ToolkitRoot
            if ($moved) { $recordedRoot = Join-Path $fixture.destination_base 'Previous empty Launcher' }
            $legacy = New-SetupLegacyMarkerFixture -Fixture $fixture -RecordedToolkitRoot $recordedRoot
            if ($moved) { Write-SetupFixture (Join-Path $fixture.paths.ToolkitRoot '.goldberg-setup.lock') '' }
            $oldBytes = [IO.File]::ReadAllBytes($legacy.path)
            $oldHash = (Get-FileHash -LiteralPath $legacy.path -Algorithm SHA256).Hash.ToLowerInvariant()
            $inputPath = Join-Path $fixture.source_base 'legacy-retry.ini'
            Write-SetupIni -Path $inputPath -Values $fixture.values
            $sourceBefore = Get-SetupHashes -Root $fixture.paths.GameRoot
            $modsBefore = Get-SetupHashes -Root $fixture.paths.ModsRoot
            $result = Invoke-SetupInstallFixture -Fixture $fixture -InputPath $inputPath
            Assert-SetupEqual $result.process.ExitCode 0 ('exact previous partial Install: ' + $result.process.Output)
            Assert-SetupTrue ($null -ne $result.trace) 'recovered Install reaches the explicit test-only preparation boundary'
            Assert-SetupEqual $result.trace.attila_and_sandboxie_execution 'NOT_RUN' 'recovery does not fabricate a game execution result'
            Assert-SetupTrue ($result.process.Output -match 'MK1212_SETUP_RECOVERY=PREVIOUS_MARKER_ONLY') 'public Install reports the precise recovery scope'
            $marker = Assert-GoldbergSetupOwnership -Paths $fixture.paths -Package $setupPackage
            Assert-SetupEqual $marker.installation_id $legacy.marker.installation_id 'recovery preserves the original installation ID'
            Assert-SetupEqual (([DateTimeOffset]$marker.created_utc).UtcDateTime.Ticks) (([DateTimeOffset]$legacy.marker.created_utc).UtcDateTime.Ticks) 'recovery preserves the original creation instant in both PowerShell versions'
            Assert-SetupEqual $marker.ToolkitRoot $fixture.paths.ToolkitRoot 'recovery records the canonical requested ToolkitRoot'
            Assert-SetupEqual $marker.LabRoot $fixture.paths.LabRoot 'recovery derives the canonical requested LabRoot'
            Assert-SetupEqual $marker.recovery.source_sha $legacy.marker.source_sha 'recovery identifies the exact previous release'
            Assert-SetupEqual $marker.recovery.package_manifest_sha256 $legacy.marker.package_manifest_sha256 'recovery identifies the exact previous package'
            Assert-SetupEqual $marker.recovery.marker_sha256 $oldHash 'recovery records the exact previous marker digest'
            Assert-SetupEqual $marker.recovery.recorded_toolkit_root $legacy.recorded_toolkit_root 'recovery retains the previous ToolkitRoot as evidence'
            Assert-SetupEqual $marker.recovery.recorded_lab_root $legacy.recorded_lab_root 'recovery retains the previous LabRoot as evidence'
            $backups = @(Get-ChildItem -LiteralPath $fixture.paths.ToolkitRoot -Filter 'installer-settings.recovered-7f66f06a-*.json' -File)
            Assert-SetupEqual $backups.Count 1 'exactly one previous marker backup is retained'
            Assert-SetupEqual $backups[0].Name $marker.recovery.backup_file 'recorded backup names the preserved file'
            Assert-SetupEqual ((Get-FileHash -LiteralPath $backups[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()) $oldHash 'preserved previous marker has its original hash'
            Assert-SetupEqual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($backups[0].FullName))) ([Convert]::ToBase64String($oldBytes)) 'backup preserves the original marker bytes exactly'
            Assert-SetupEqual (Get-GoldbergSetupPackage -Root $fixture.paths.ToolkitRoot).manifest_sha256 $setupPackage.manifest_sha256 'recovered Install copies the current verified payload'
            $installedBefore = Get-SetupHashes -Root $fixture.paths.ToolkitRoot
            $repeat = Invoke-SetupInstallFixture -Fixture $fixture -InputPath $inputPath
            Assert-SetupEqual $repeat.process.ExitCode 0 ('matching recovered Install retry: ' + $repeat.process.Output)
            Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ToolkitRoot) $installedBefore 'retry neither repeats recovery nor rewrites its evidence'
            Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.GameRoot) $sourceBefore 'legacy recovery preserves the source game'
            Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ModsRoot) $modsBefore 'legacy recovery preserves Workshop files'
            foreach ($path in @($fixture.paths.HostGameRoot, $fixture.paths.ClientGameRoot, $fixture.paths.LabRoot)) { Assert-SetupTrue (-not (Test-Path -LiteralPath $path)) 'recovery creates no game copies or lab readiness at the stub boundary' }
            if ($moved) { Assert-SetupTrue (-not (Test-Path -LiteralPath $recordedRoot)) 'the absent recorded toolkit is never created or relocated' }
        }
    }

    Invoke-SetupCheck 'A failure after writing the previous-marker backup preserves the original and permits recovery without manual cleanup' {
        $fixture = New-SetupFixture 'legacy-post-backup-failure'
        Add-SetupSandboxieFixture -Fixture $fixture
        $legacy = New-SetupLegacyMarkerFixture -Fixture $fixture
        $markerBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($legacy.path))
        $sourceBefore = Get-SetupHashes -Root $fixture.paths.GameRoot
        $modsBefore = Get-SetupHashes -Root $fixture.paths.ModsRoot
        $inputPath = Join-Path $fixture.source_base 'post-backup-retry.ini'
        Write-SetupIni -Path $inputPath -Values $fixture.values
        $failed = Invoke-SetupInstallFixture -Fixture $fixture -InputPath $inputPath -RecoveryFault AfterBackup
        Assert-SetupEqual $failed.process.ExitCode 2 ('injected failure after backup: ' + $failed.process.Output)
        Assert-SetupTrue ($failed.process.Output -match 'TEST_ONLY_RECOVERY_FAILURE_AFTER_BACKUP') 'fault is reached only after the real exclusive backup write'
        Assert-SetupTrue ($null -eq $failed.trace) 'post-backup failure never reaches preparation'
        Assert-SetupEqual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($legacy.path))) $markerBytes 'failed recovery leaves the original marker bytes intact'
        $leaves = @(Get-ChildItem -LiteralPath $fixture.paths.ToolkitRoot -Force)
        Assert-SetupEqual $leaves.Count 2 'failed recovery retains only the original marker and empty lock'
        foreach ($leaf in $leaves) { Assert-SetupTrue (@('installer-settings.json', '.goldberg-setup.lock') -ccontains $leaf.Name) 'verified failed-attempt metadata is removed' }
        Assert-SetupEqual (Get-Item -LiteralPath (Join-Path $fixture.paths.ToolkitRoot '.goldberg-setup.lock') -Force).Length 0 'failure leaves only an empty reusable lock'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.GameRoot) $sourceBefore 'post-backup failure preserves original game'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ModsRoot) $modsBefore 'post-backup failure preserves Workshop'
        # No fixture removal or marker rewrite is allowed between failure and retry.
        $retry = Invoke-SetupInstallFixture -Fixture $fixture -InputPath $inputPath
        Assert-SetupEqual $retry.process.ExitCode 0 ('recovery retry without manual cleanup: ' + $retry.process.Output)
        Assert-SetupTrue ($null -ne $retry.trace) 'clean retry reaches the explicit test-only preparation boundary'
        $marker = Assert-GoldbergSetupOwnership -Paths $fixture.paths -Package $setupPackage
        Assert-SetupEqual $marker.installation_id $legacy.marker.installation_id 'retry retains the original installation identity'
        $backups = @(Get-ChildItem -LiteralPath $fixture.paths.ToolkitRoot -Filter 'installer-settings.recovered-7f66f06a-*.json' -File)
        Assert-SetupEqual $backups.Count 1 'successful retry creates exactly one durable original-marker backup'
        Assert-SetupEqual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($backups[0].FullName))) $markerBytes 'retry backup still contains the exact original marker'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.GameRoot) $sourceBefore 'retry preserves original game'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ModsRoot) $modsBefore 'retry preserves Workshop'
    }

    Invoke-SetupCheck 'Recovery rechecks newly populated HOST and lab destinations after staging and preserves their new data' {
        foreach ($destination in @('HOST', 'LAB')) {
            $fixture = New-SetupFixture ('legacy-precommit-data-' + $destination)
            Add-SetupSandboxieFixture -Fixture $fixture
            $legacy = New-SetupLegacyMarkerFixture -Fixture $fixture
            $markerBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($legacy.path))
            $sourceBefore = Get-SetupHashes -Root $fixture.paths.GameRoot
            $modsBefore = Get-SetupHashes -Root $fixture.paths.ModsRoot
            $latePath = $(if ($destination -eq 'HOST') { Join-Path $fixture.paths.HostGameRoot 'data/new.pack' } else { Join-Path $fixture.paths.LabRoot 'save_games/new.save' })
            $inputPath = Join-Path $fixture.source_base 'precommit-data.ini'
            Write-SetupIni -Path $inputPath -Values $fixture.values
            $failed = Invoke-SetupInstallFixture -Fixture $fixture -InputPath $inputPath -RecoveryFault AfterStagingData -LateFilePath $latePath
            Assert-SetupEqual $failed.process.ExitCode 2 ('new destination data blocks precommit: ' + $destination + '; ' + $failed.process.Output)
            Assert-SetupTrue ($failed.process.Output -match 'TEST_ONLY_NEW_DESTINATION_DATA_AFTER_STAGING') 'new data appears after the real temporary marker is written'
            Assert-SetupTrue ($failed.process.Output -match 'requires empty lab/game destinations') 'the real final destination check rejects new data before replacement'
            Assert-SetupTrue ($null -eq $failed.trace) 'new destination data prevents preparation'
            Assert-SetupEqual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($legacy.path))) $markerBytes 'precommit refusal preserves the exact old marker'
            Assert-SetupEqual ([IO.File]::ReadAllText($latePath)) 'TEST-OWNED-NEW-DATA-MUST-SURVIVE' 'precommit refusal preserves newly appearing destination bytes'
            Assert-SetupEqual (@(Get-ChildItem -LiteralPath $fixture.paths.ToolkitRoot -Filter 'installer-settings.recovered-7f66f06a-*.json' -File).Count) 0 'verified failed-attempt backup is removed'
            Assert-SetupEqual (@(Get-ChildItem -LiteralPath $fixture.paths.ToolkitRoot -Filter '.installer-recovery-*.tmp' -Force -File).Count) 0 'failed-attempt temporary marker is removed'
            Assert-SetupTrue (-not (Test-Path -LiteralPath (Join-Path $fixture.paths.ToolkitRoot 'package_manifest.json'))) 'new data blocks recovery before payload installation'
            Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.GameRoot) $sourceBefore 'precommit refusal preserves original game'
            Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ModsRoot) $modsBefore 'precommit refusal preserves Workshop'
            $beforeRetry = Get-SetupHashes -Root $fixture.paths.ToolkitRoot
            $retry = Invoke-SetupInstallFixture -Fixture $fixture -InputPath $inputPath
            Assert-SetupEqual $retry.process.ExitCode 2 'existing new user data remains a blocker on an ordinary retry'
            Assert-SetupTrue ($null -eq $retry.trace) 'ordinary retry cannot bypass populated destination protection'
            Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ToolkitRoot) $beforeRetry 'ordinary retry preserves the marker and newly populated lab'
            Assert-SetupEqual ([IO.File]::ReadAllText($latePath)) 'TEST-OWNED-NEW-DATA-MUST-SURVIVE' 'ordinary retry still preserves the new data'
        }
    }

    Invoke-SetupCheck 'Previous-marker recovery blocks other releases, changed paths, populated destinations and a busy lock without changing existing bytes' {
        foreach ($case in @('source-version', 'manifest-version', 'source-path', 'extra-toolkit-file', 'recorded-lab', 'requested-lab', 'host-data', 'client-data', 'recorded-toolkit', 'lab-derivation', 'busy-lock')) {
            $fixture = New-SetupFixture ('legacy-refused-' + $case)
            Add-SetupSandboxieFixture -Fixture $fixture
            $recordedRoot = Join-Path $fixture.destination_base 'Previous Launcher'
            $legacy = New-SetupLegacyMarkerFixture -Fixture $fixture -RecordedToolkitRoot $recordedRoot
            switch ($case) {
                'source-version' { $legacy.marker.source_sha = 'f' * 40; Write-SetupJson $legacy.path $legacy.marker }
                'manifest-version' { $legacy.marker.package_manifest_sha256 = 'f' * 64; Write-SetupJson $legacy.path $legacy.marker }
                'source-path' { $legacy.marker.GameRoot = Join-Path $fixture.source_base 'Different original game'; Write-SetupJson $legacy.path $legacy.marker }
                'extra-toolkit-file' { Write-SetupFixture (Join-Path $fixture.paths.ToolkitRoot 'user-notes.txt') 'KEEP-USER-NOTES' }
                'recorded-lab' { Write-SetupFixture (Join-Path $legacy.recorded_lab_root 'evidence/report.json') 'KEEP-OLD-EVIDENCE' }
                'requested-lab' { Write-SetupFixture (Join-Path $fixture.paths.LabRoot 'save_games/turn.save') 'KEEP-CAMPAIGN' }
                'host-data' { Write-SetupFixture (Join-Path $fixture.paths.HostGameRoot 'data/selected.pack') 'KEEP-HOST-DATA' }
                'client-data' { Write-SetupFixture (Join-Path $fixture.paths.ClientGameRoot 'data/selected.pack') 'KEEP-CLIENT-DATA' }
                'recorded-toolkit' { Write-SetupFixture (Join-Path $recordedRoot 'existing-launcher.txt') 'KEEP-PREVIOUS-TOOLKIT' }
                'lab-derivation' { $legacy.marker.LabRoot = Join-Path $fixture.destination_base 'Unrelated lab'; Write-SetupJson $legacy.path $legacy.marker }
                'busy-lock' { Write-SetupFixture (Join-Path $fixture.paths.ToolkitRoot '.goldberg-setup.lock') '' }
            }
            $inputPath = Join-Path $fixture.source_base 'refused-retry.ini'
            Write-SetupIni -Path $inputPath -Values $fixture.values
            $destinationBefore = Get-SetupHashes -Root $fixture.destination_base
            $sourceBefore = Get-SetupHashes -Root $fixture.paths.GameRoot
            $modsBefore = Get-SetupHashes -Root $fixture.paths.ModsRoot
            $hostBefore = $null
            if (Test-Path -LiteralPath $fixture.paths.HostGameRoot) { $hostBefore = Get-SetupHashes -Root $fixture.paths.HostGameRoot }
            $lock = $null
            try {
                if ($case -eq 'busy-lock') { $lock = New-Object IO.FileStream -ArgumentList (Join-Path $fixture.paths.ToolkitRoot '.goldberg-setup.lock'), ([IO.FileMode]::Open), ([IO.FileAccess]::ReadWrite), ([IO.FileShare]::None) }
                $result = Invoke-SetupInstallFixture -Fixture $fixture -InputPath $inputPath
            } finally { if ($lock) { $lock.Dispose() } }
            Assert-SetupEqual $result.process.ExitCode 2 ('unsafe previous-marker retry must block: ' + $case + '; ' + $result.process.Output)
            Assert-SetupTrue ($null -eq $result.trace) ('rejected recovery never reaches preparation: ' + $case)
            Assert-SetupTrue ($result.process.Output -match 'MK1212_SETUP_STATUS=BLOCKED') ('rejected recovery is reported as blocked: ' + $case)
            Assert-SetupHashes (Get-SetupHashes -Root $fixture.destination_base) $destinationBefore ('refused recovery preserves all destination bytes: ' + $case)
            Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.GameRoot) $sourceBefore ('refused recovery preserves source game: ' + $case)
            Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.ModsRoot) $modsBefore ('refused recovery preserves Workshop: ' + $case)
            if ($null -ne $hostBefore) { Assert-SetupHashes (Get-SetupHashes -Root $fixture.paths.HostGameRoot) $hostBefore 'refused recovery preserves the populated C: HOST copy' }
            else { Assert-SetupTrue (-not (Test-Path -LiteralPath $fixture.paths.HostGameRoot)) ('refused recovery creates no HOST copy: ' + $case) }
            Assert-SetupEqual (@(Get-ChildItem -LiteralPath $fixture.paths.ToolkitRoot -Filter 'installer-settings.recovered-7f66f06a-*.json' -File).Count) 0 ('ineligible recovery creates no backup or replacement: ' + $case)
        }
    }

    Invoke-SetupCheck 'A current marker ToolkitRoot mismatch stays blocked and reports saved and requested paths with its stage' {
        $fixture = New-SetupFixture 'current-marker-path-diagnostic'
        Add-SetupSandboxieFixture -Fixture $fixture
        $marker = New-GoldbergSetupMarker -Paths $fixture.paths -Package $setupPackage
        $marker.ToolkitRoot = Join-Path $fixture.destination_base 'Different recorded ToolkitRoot'
        $marker.LabRoot = Join-Path $marker.ToolkitRoot 'lab'
        $markerPath = Join-Path $fixture.paths.ToolkitRoot 'installer-settings.json'
        Write-SetupJson -Path $markerPath -Value $marker
        $before = Get-SetupHashes -Root $fixture.destination_base
        $inputPath = Join-Path $fixture.source_base 'current-marker.ini'
        Write-SetupIni -Path $inputPath -Values $fixture.values
        $result = Invoke-SetupInstallFixture -Fixture $fixture -InputPath $inputPath
        Assert-SetupEqual $result.process.ExitCode 2 'current mismatched marker cannot use legacy recovery'
        Assert-SetupTrue ($null -eq $result.trace) 'mismatched current marker cannot reach preparation'
        Assert-SetupTrue ($result.process.Output -match 'stage=CheckOwnership; Owned installation path differs: ToolkitRoot;') 'diagnostic identifies the actual failing stage and path key'
        $line = @($result.process.Output -split "`r?`n" | Where-Object { $_ -match 'Owned installation path differs: ToolkitRoot;' })[0]
        $details = $line.Substring($line.IndexOf('{')) | ConvertFrom-Json
        Assert-SetupEqual $details.saved_value $marker.ToolkitRoot 'diagnostic exposes the precise saved path'
        Assert-SetupEqual $details.requested_value $fixture.paths.ToolkitRoot 'diagnostic exposes the precise requested path'
        Assert-SetupEqual $details.marker_path $markerPath 'diagnostic locates the preserved marker'
        Assert-SetupHashes (Get-SetupHashes -Root $fixture.destination_base) $before 'diagnostic refusal does not rewrite the current marker'
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
        foreach ($sha in $previousPackages.Keys) { Assert-SetupHashes (Get-SetupHashes -Root $previousPackages[$sha].root) $previousPackageHashes[$sha] ('authentic historical fixture remains unchanged: ' + $sha) }
    }
}
finally {
    if (Test-Path -LiteralPath $setupTemp) { Remove-Item -LiteralPath $setupTemp -Recurse -Force }
    if (Test-Path -LiteralPath $setupDriveTemp) { Remove-Item -LiteralPath $setupDriveTemp -Recurse -Force }
}

Write-Host ('Goldberg installer checks: {0} run, {1} failed. Game preparation and multiplayer NOT_RUN.' -f $script:SetupChecks, $script:SetupFailures.Count)
if ($script:SetupFailures.Count -gt 0) { throw ($script:SetupFailures -join [Environment]::NewLine) }
