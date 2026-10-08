# Private, operator-run two-copy Goldberg experiment. No original game writes.
[CmdletBinding()]
param(
    [ValidateSet('Run', 'Preflight', 'Prepare', 'LaunchBoth', 'Collect')][string]$Mode = 'Run',
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\Total War Attila',
    [string]$LabRoot = 'D:\MK1212-GoldbergLab',
    [string]$SandboxieRoot,
    [string]$GoldbergArchive,
    [ValidatePattern('^[a-z_]{2,32}$')][string]$Language,
    [ValidateRange(1, 100000)][int]$MaxEntries = 100000,
    [ValidateRange(1, 214748364800)][long]$MaxGameBytes = 214748364800,
    [ValidateRange(0, 10737418240)][long]$ReserveBytes = 1073741824,
    [ValidateRange(5, 120)][int]$LaunchTimeoutSeconds = 45
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'dual_client_lab_core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'goldberg_client_lab_core.psm1') -Force -DisableNameChecking

$script:GoldOwner = 'MK1212Scripts.goldberg-client-lab'
$script:GoldState = $null; $script:GoldLock = $null; $script:GoldCapture = $null
$script:GoldStatePath = $null; $script:GoldToolkit = $null; $script:GoldTools = $null
$script:GoldInventory = $null; $script:GoldHostProfile = $null; $script:GoldInterfaces = @()
$script:GoldStart = $null; $script:GoldIni = $null
$report = [ordered]@{
    schema = 1; owner = $script:GoldOwner; mode = $Mode; status = 'BLOCKED'
    created_utc = [DateTime]::UtcNow.ToString('o'); reasons = @(); warnings = @()
    lab_root = $LabRoot; source_game_root = $GameRoot; lab_id = $null; source = $null
    tools = $null; goldberg = $null; source_game = $null; disk = $null; network = $null
    language = $null; peers = @(); report_path = $null; evidence_directory = $null
    multiplayer = 'NOT_RUN'; lobby = 'NOT_RUN'; campaign_turns = 'NOT_RUN'
    account_identity = 'LOCAL_EMULATED_IDS'; mod_status = 'MODS_NOT_CONFIGURED'
    game_data_hash_validation = 'NOT_RUN'
}

function Save-GoldState { Write-LabJson -Path $script:GoldStatePath -Value $script:GoldState -ReplaceOwned }

function Assert-GoldState {
    $state = $script:GoldState
    if ($state.schema -ne 1 -or $state.owner -cne $script:GoldOwner -or $state.lab_id -notmatch '^[0-9a-f]{32}$') { throw 'Unsupported Goldberg lab state schema or owner.' }
    if ($state.lab_root -ine $LabRoot -or $state.source_game_root -ine $GameRoot -or $state.host_profile -ine $script:GoldHostProfile -or $state.language -cne $Language) { throw 'Lab state belongs to another source, profile, language or root.' }
    if ($state.executable_sha256 -notmatch '^[0-9a-f]{64}$' -or $state.original_api_sha256 -notmatch '^[0-9a-f]{64}$' -or $state.roles.Count -ne 2) { throw 'Lab state identity is incomplete.' }
    $seen = @()
    foreach ($peer in $state.roles) {
        if (@('HOST', 'CLIENT') -cnotcontains $peer.role -or $seen -contains $peer.role) { throw 'Unexpected peer role in lab state.' }
        $seen += $peer.role
        $name = $(if ($peer.role -eq 'HOST') { 'MK1212GoldHost' } else { 'MK1212GoldClient' })
        if ($peer.box_name -cne $name -or $peer.game_root -ine (Join-Path (Join-Path $LabRoot 'games') $peer.role) -or $peer.box_root -ine (Join-Path (Join-Path $LabRoot 'sandboxes') $name)) { throw 'Unexpected peer path or box identity.' }
        $stagingParent = Join-Path $LabRoot 'staging'
        if (-not (Test-LabPathContained -Root $stagingParent -Path $peer.staging_root) -or [IO.Path]::GetFileName($peer.staging_root) -notmatch ('^' + $peer.role + '-[0-9a-f]{32}$')) { throw 'Invalid staging ownership path.' }
        if ($peer.profile_physical -and -not (Test-LabPathContained -Root $peer.box_root -Path $peer.profile_physical)) { throw 'Saved profile mapping escaped its sandbox.' }
    }
}

function Initialize-GoldLab {
    if ($LabRoot -notmatch '^[A-Za-z]:\\' -or $LabRoot -match '[%\r\n]') { throw 'LabRoot must be a local absolute Windows drive path without expansion characters.' }
    Set-Variable -Name LabRoot -Value ([IO.Path]::GetFullPath($LabRoot).TrimEnd('\')) -Scope Script
    $drive = [IO.Path]::GetPathRoot($LabRoot)
    if (-not (Test-Path -LiteralPath $drive -PathType Container) -or $drive.TrimEnd('\') -ieq [Environment]::GetEnvironmentVariable('SystemDrive') -or $LabRoot -eq $drive.TrimEnd('\')) { throw 'Use a non-system drive directory for the Goldberg lab, normally D:\MK1212-GoldbergLab.' }
    if (-not (Test-GoldbergRootsDisjoint -SourceRoot $GameRoot -LabRoot $LabRoot)) { throw 'The original installation and laboratory directories must not overlap.' }
    Assert-LabNoReparsePath -Path $LabRoot
    $script:GoldStatePath = Join-Path $LabRoot '.mk1212-goldberg-lab.json'
    if (Test-Path -LiteralPath $script:GoldStatePath -PathType Leaf) {
        $script:GoldState = Read-LabJson -Path $script:GoldStatePath
        Assert-GoldState
    } else {
        if (Test-Path -LiteralPath $LabRoot) {
            if (-not (Test-Path -LiteralPath $LabRoot -PathType Container) -or @(Get-ChildItem -LiteralPath $LabRoot -Force | Select-Object -First 1).Count -gt 0) { throw 'Refusing a nonempty directory without Goldberg lab ownership.' }
        } else { [void][IO.Directory]::CreateDirectory($LabRoot) }
        $roles = @()
        foreach ($role in @('HOST', 'CLIENT')) {
            $box = $(if ($role -eq 'HOST') { 'MK1212GoldHost' } else { 'MK1212GoldClient' })
            $roles += [pscustomobject]@{
                role = $role; box_name = $box; box_root = (Join-Path (Join-Path $LabRoot 'sandboxes') $box)
                game_root = (Join-Path (Join-Path $LabRoot 'games') $role)
                staging_root = (Join-Path (Join-Path $LabRoot 'staging') ($role + '-' + [guid]::NewGuid().ToString('N')))
                copy_complete = $false; copy_manifest_sha256 = $null; prepared = $false
                box_setup_started = $false; box_setup_complete = $false
                profile_physical = $null; profile_marker = $null; profile_nonce = $null
                mod_status = 'MODS_NOT_CONFIGURED'; profile_seed = @()
            }
        }
        $script:GoldState = [pscustomobject]@{
            schema = 1; owner = $script:GoldOwner; lab_id = [guid]::NewGuid().ToString('N')
            lab_root = $LabRoot; source_game_root = $GameRoot; host_profile = $script:GoldHostProfile
            language = $Language; executable_sha256 = $report.source_game.executable_sha256
            original_api_sha256 = $report.source_game.original_api_sha256
            source_catalog_sha256 = $null; roles = $roles
        }
        Write-LabJson -Path $script:GoldStatePath -Value $script:GoldState
    }
    $lockPath = Join-Path $LabRoot '.goldberg-operation.lock'
    Assert-LabNoReparsePath -Path $lockPath
    $script:GoldLock = New-Object IO.FileStream -ArgumentList $lockPath, ([IO.FileMode]::OpenOrCreate), ([IO.FileAccess]::ReadWrite), ([IO.FileShare]::None)
    $leaf = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + $Mode.ToLowerInvariant() + '-' + [guid]::NewGuid().ToString('N')
    $script:GoldCapture = Join-Path (Join-Path $LabRoot 'evidence') $leaf
    Assert-LabNoReparsePath -Path $script:GoldCapture
    [void][IO.Directory]::CreateDirectory($script:GoldCapture)
    $report.lab_root = $LabRoot; $report.lab_id = $script:GoldState.lab_id
    $report.evidence_directory = $script:GoldCapture; $report.report_path = Join-Path $script:GoldCapture 'report.json'
}

function Read-GoldManifest {
    param([string]$Path, [string]$ExpectedHash)
    if ($ExpectedHash -notmatch '^[0-9a-f]{64}$' -or (Get-GoldbergDigest -Path $Path -MaxBytes 67108864) -cne $ExpectedHash) { throw ('Owned manifest hash changed: ' + $Path) }
    return (Read-LabTextBounded -Path $Path -MaxBytes 67108864 | ConvertFrom-Json -ErrorAction Stop)
}

function Get-GoldPeerManifest {
    param($Peer)
    $path = Join-Path (Join-Path $LabRoot 'manifests') ($Peer.role + '.json')
    $manifest = Read-GoldManifest -Path $path -ExpectedHash $Peer.copy_manifest_sha256
    if ($manifest.schema -ne 1 -or $manifest.lab_id -cne $script:GoldState.lab_id -or $manifest.role -cne $Peer.role) { throw 'Peer copy manifest ownership mismatch.' }
    return $manifest
}

function Assert-GoldCatalog {
    param([switch]$Create)
    $path = Join-Path (Join-Path $LabRoot 'manifests') 'source-catalog.json'
    if (-not $script:GoldState.source_catalog_sha256) {
        if (-not $Create) { return }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        Write-LabJson -Path $path -Value ([ordered]@{ schema = 1; lab_id = $script:GoldState.lab_id; files = $script:GoldInventory.files })
        $script:GoldState.source_catalog_sha256 = Get-GoldbergDigest -Path $path -MaxBytes 67108864
        Save-GoldState
    }
    $catalog = Read-GoldManifest -Path $path -ExpectedHash $script:GoldState.source_catalog_sha256
    if ($catalog.schema -ne 1 -or $catalog.lab_id -cne $script:GoldState.lab_id -or $catalog.files.Count -ne $script:GoldInventory.files.Count) { throw 'The original game catalog changed; the existing copies were retained.' }
    $records = @{}
    foreach ($record in $catalog.files) { $records[[string]$record.relative_path] = $record }
    foreach ($record in $script:GoldInventory.files) {
        if (-not $records.ContainsKey($record.relative_path)) { throw 'Original game file set changed.' }
        $previous = $records[$record.relative_path]
        if ([long]$previous.bytes -ne $record.bytes -or [long]$previous.last_write_ticks -ne $record.last_write_ticks) { throw ('Original game metadata changed; review before reusing copies: ' + $record.relative_path) }
    }
}

function Get-GoldBoxSettings {
    param($Peer)
    return [ordered]@{
        Enabled = 'y'; FileRootPath = $Peer.box_root; SeparateUserFolders = 'y'
        WriteFilePath = $script:GoldHostProfile
        Comment = ('MK1212 Goldberg lab ' + $script:GoldState.lab_id + ' ' + $Peer.role)
    }
}

function Assert-GoldBox {
    param($Peer, [string[]]$Names, [switch]$RequireReady)
    $exists = $Names -contains $Peer.box_name
    $rootExists = Test-Path -LiteralPath $Peer.box_root
    if ($rootExists) {
        $marker = Read-LabJson -Path (Join-Path $Peer.box_root '.mk1212-goldberg-box.json')
        if ($marker.schema -ne 1 -or $marker.owner -cne $script:GoldOwner -or $marker.lab_id -cne $script:GoldState.lab_id -or $marker.role -cne $Peer.role -or $marker.box -cne $Peer.box_name) { throw 'Existing Goldberg box directory is not owned by this lab.' }
    }
    if ($exists -and (-not $rootExists -or -not $Peer.box_setup_started)) { throw ('Refusing an existing unowned Sandboxie box: ' + $Peer.box_name) }
    if ($Peer.box_setup_complete -or $RequireReady) {
        if (-not $exists -or -not $rootExists -or -not $Peer.box_setup_complete) { throw 'Prepared sandbox is incomplete or missing.' }
        $settings = Get-GoldBoxSettings -Peer $Peer
        foreach ($key in $settings.Keys) {
            if (-not (Test-LabSettingValues -Expected @($settings[$key]) -Actual (Get-LabSetting -SbieIniExe $script:GoldIni -BoxName $Peer.box_name -Setting $key))) { throw ('Sandboxie settings changed: ' + $Peer.box_name + '/' + $key) }
        }
        if ((Get-LabBoxNames -SbieIniExe $script:GoldIni -EnabledOnly) -notcontains $Peer.box_name) { throw 'Goldberg sandbox is not enabled for this user.' }
        Assert-GoldProfile -Peer $Peer
    }
}

function Assert-GoldProfile {
    param($Peer)
    if (-not $Peer.profile_physical -or -not $Peer.profile_marker -or $Peer.profile_nonce -notmatch '^[0-9a-f]{32}$' -or -not (Test-LabPathContained -Root $Peer.box_root -Path $Peer.profile_physical) -or -not (Test-LabPathContained -Root $Peer.profile_physical -Path $Peer.profile_marker)) { throw 'Goldberg profile mapping is invalid.' }
    $marker = Read-LabJson -Path $Peer.profile_marker
    if ($marker.schema -ne 1 -or $marker.owner -cne $script:GoldOwner -or $marker.nonce -cne $Peer.profile_nonce -or $marker.role -cne $Peer.role -or $marker.requested_box -cne $Peer.box_name -or $marker.profile_logical -ine $script:GoldHostProfile) { throw 'Sandbox profile nonce does not match.' }
    if (Test-Path -LiteralPath (Join-Path $script:GoldHostProfile ([IO.Path]::GetFileName($Peer.profile_marker)))) { throw 'Profile probe appeared outside Sandboxie; isolation is not established.' }
}

function Initialize-GoldBox {
    param($Peer)
    $names = Get-LabBoxNames -SbieIniExe $script:GoldIni
    Assert-GoldBox -Peer $Peer -Names $names
    if ($Peer.box_setup_complete) { return }
    if ($names -contains $Peer.box_name) {
        $result = Invoke-LabNative -Executable $script:GoldStart -Arguments @('/silent', ('/box:' + $Peer.box_name), '/listpids')
        if ($result.ExitCode -ne 0 -or (ConvertFrom-LabPidList -Text $result.Output).Count -gt 0) { throw 'Close programs in the incomplete owned sandbox before retrying preparation.' }
    }
    $Peer.box_setup_started = $true; Save-GoldState
    if (-not (Test-Path -LiteralPath $Peer.box_root)) {
        Assert-LabNoReparsePath -Path $Peer.box_root
        [void][IO.Directory]::CreateDirectory($Peer.box_root)
        Write-LabJson -Path (Join-Path $Peer.box_root '.mk1212-goldberg-box.json') -Value ([ordered]@{ schema = 1; owner = $script:GoldOwner; lab_id = $script:GoldState.lab_id; role = $Peer.role; box = $Peer.box_name })
    }
    $settings = Get-GoldBoxSettings -Peer $Peer
    foreach ($key in $settings.Keys) { Set-LabVerifiedSetting -SbieIniExe $script:GoldIni -BoxName $Peer.box_name -Setting $key -Value $settings[$key] }
    $reload = Invoke-LabNative -Executable $script:GoldStart -Arguments @('/reload')
    if ($reload.ExitCode -ne 0) { throw 'Sandboxie configuration reload failed.' }
    $Peer.profile_nonce = [guid]::NewGuid().ToString('N')
    $markerName = 'mk1212-dual-probe-' + $Peer.profile_nonce + '.json'
    $hostMarker = Join-Path $script:GoldHostProfile $markerName
    if (Test-Path -LiteralPath $hostMarker) { throw 'Unexpected profile nonce collision.' }
    $powershell = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
    $probe = Invoke-LabNative -Executable $script:GoldStart -WorkingDirectory $Peer.game_root -TimeoutSeconds 30 -Arguments @(
        ('/box:' + $Peer.box_name), '/wait', $powershell, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'dual_client_probe.ps1'), '-Nonce', $Peer.profile_nonce, '-Role', $Peer.role,
        '-BoxName', $Peer.box_name, '-Owner', $script:GoldOwner
    )
    if ($probe.ExitCode -ne 0 -or (Test-Path -LiteralPath $hostMarker)) { throw 'Sandbox profile probe failed; original profile was not adopted.' }
    $scan = Get-LabFilesBounded -Root $Peer.box_root -MaxEntries $MaxEntries
    if ($scan.Truncated -or $scan.Warnings.Count -gt 0) { throw 'Cannot fully resolve the bounded sandbox profile probe.' }
    $markers = @($scan.Files | Where-Object { $_.Name -ceq $markerName })
    if ($markers.Count -ne 1) { throw 'Expected exactly one physical profile marker in the owned box.' }
    $Peer.profile_physical = $markers[0].DirectoryName; $Peer.profile_marker = $markers[0].FullName
    Assert-GoldProfile -Peer $Peer
    $Peer.box_setup_complete = $true; Save-GoldState
    Assert-GoldBox -Peer $Peer -Names (Get-LabBoxNames -SbieIniExe $script:GoldIni) -RequireReady
}

function Seed-GoldProfile {
    param($Peer)
    Assert-GoldProfile -Peer $Peer
    $seeds = @()
    # user.script is executable configuration: retain the source only as evidence,
    # and generate the isolated profile from a narrow mod-directive allowlist.
    $sourceScript = Join-Path $script:GoldHostProfile 'scripts/user.script.txt'
    $evidenceRoot = Join-Path (Join-Path $script:GoldCapture $Peer.role) 'original-profile'
    $filtered = Get-GoldbergModScript -Text '' -SourceGameRoot $GameRoot -CopiedGameRoot $Peer.game_root
    $selectionSource = 'NO_RECOGNIZED_MOD_SELECTION'
    if (Test-Path -LiteralPath $sourceScript -PathType Leaf) {
        $snapshotPath = Join-Path $evidenceRoot 'user.script.txt'
        $snapshot = Copy-LabEvidenceFile -Source $sourceScript -Destination $snapshotPath -SourceRoot $script:GoldHostProfile -DestinationRoot $evidenceRoot -MaxBytes 1048576
        if ($snapshot.status -ne 'CAPTURED') { throw 'Original user script exceeds the evidence/import bound.' }
        $filtered = Get-GoldbergModScript -Text (Read-LabTextBounded -Path $snapshotPath -MaxBytes 1048576) -SourceGameRoot $GameRoot -CopiedGameRoot $Peer.game_root
        if ($filtered.recognized_directives -gt 0) { $selectionSource = 'USER_SCRIPT' }
        $seeds += [pscustomobject]@{ file = 'original-user.script.txt'; status = 'EVIDENCE_ONLY'; path = $snapshotPath; sha256 = $snapshot.sha256 }
    }
    $usedMods = Join-Path $GameRoot 'used_mods.txt'
    if (Test-Path -LiteralPath $usedMods -PathType Leaf) {
        $usedSnapshotPath = Join-Path $evidenceRoot 'used_mods.txt'
        $usedSnapshot = Copy-LabEvidenceFile -Source $usedMods -Destination $usedSnapshotPath -SourceRoot $GameRoot -DestinationRoot $evidenceRoot -MaxBytes 1048576
        if ($usedSnapshot.status -ne 'CAPTURED') { throw 'Original used_mods exceeds the evidence/import bound.' }
        $usedFiltered = Get-GoldbergModScript -Text (Read-LabTextBounded -Path $usedSnapshotPath -MaxBytes 1048576) -SourceGameRoot $GameRoot -CopiedGameRoot $Peer.game_root
        $seeds += [pscustomobject]@{ file = 'used_mods.txt'; status = 'EVIDENCE_WITH_FILTERED_IMPORT_CHECK'; capture = $usedSnapshot; importer = $usedFiltered.status; recognized_directives = $usedFiltered.recognized_directives; excluded_lines = $usedFiltered.excluded_lines; unresolved = $usedFiltered.unresolved }
        if ($filtered.unresolved.Count -gt 0 -or $usedFiltered.unresolved.Count -gt 0) {
            $filtered.text = ''; $filtered.status = 'MODS_NOT_CONFIGURED'
            $filtered.unresolved += @($usedFiltered.unresolved)
            $selectionSource = 'UNRESOLVED_NO_MOD_SCRIPT'
        } elseif ($filtered.recognized_directives -gt 0 -and $usedFiltered.recognized_directives -gt 0) {
            if ($filtered.text -cne $usedFiltered.text) {
                $filtered.text = ''; $filtered.status = 'MODS_NOT_CONFIGURED'
                $filtered.unresolved += 'Original user.script and used_mods selections conflict or cannot both be resolved.'
                $selectionSource = 'CONFLICT_NO_MOD_SCRIPT'
            } else { $selectionSource = 'USER_SCRIPT_AND_USED_MODS_AGREE' }
        } elseif ($usedFiltered.recognized_directives -gt 0) {
            $filtered = $usedFiltered; $selectionSource = 'USED_MODS'
        }
    }
    $filteredDestination = Join-Path $Peer.profile_physical 'scripts/user.script.txt'
    Write-GoldbergManagedText -Path $filteredDestination -Value $filtered.text -Root $Peer.profile_physical
    $seeds += [pscustomobject]@{ file = 'scripts/user.script.txt'; status = 'FILTERED_SEED'; importer = $filtered.status; selection_source = $selectionSource; recognized_directives = $filtered.recognized_directives; excluded_lines = $filtered.excluded_lines; unresolved = $filtered.unresolved }
    foreach ($relative in @('scripts/preferences.script.txt')) {
        $source = Join-Path $script:GoldHostProfile $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { $seeds += [pscustomobject]@{ file = $relative; status = 'SOURCE_MISSING' }; continue }
        $destination = Join-Path $Peer.profile_physical $relative
        try {
            $sourceHash = Get-GoldbergDigest -Path $source -MaxBytes 1048576
            if (Test-Path -LiteralPath $destination) {
                if ((Get-GoldbergDigest -Path $destination -MaxBytes 1048576) -cne $sourceHash) { throw 'Existing boxed profile differs and was preserved.' }
                $seeds += [pscustomobject]@{ file = $relative; status = 'VERIFIED_EXISTING'; sha256 = $sourceHash }
            } else {
                $snapshot = Copy-LabEvidenceFile -Source $source -Destination $destination -SourceRoot $script:GoldHostProfile -DestinationRoot $Peer.profile_physical -MaxBytes 1048576
                if ($snapshot.status -ne 'CAPTURED') { throw 'Profile seed exceeded its byte limit.' }
                $seeds += [pscustomobject]@{ file = $relative; status = 'COPIED'; sha256 = $snapshot.sha256 }
            }
        } catch { $seeds += [pscustomobject]@{ file = $relative; status = 'BLOCKED'; reason = $_.Exception.Message } }
    }
    $Peer.profile_seed = $seeds
    $Peer.mod_status = 'MODS_NOT_CONFIGURED'
    Save-GoldState
}

function Prepare-GoldPeers {
    Assert-GoldCatalog -Create
    $dllPath = Join-Path (Join-Path $LabRoot 'tools') 'steam_api.dll'
    $payload = Expand-GoldbergVerifiedDll -ArchivePath $script:GoldToolkit.archive -Lock $script:GoldToolkit.lock -DLLDestination $dllPath -DestinationRoot (Join-Path $LabRoot 'tools')
    $report.goldberg = $payload
    $expected = @{}; $fullyVerifiedThisRun = 0
    foreach ($peer in $script:GoldState.roles) {
        if (-not $peer.copy_complete) {
            if (Test-Path -LiteralPath $peer.game_root) { throw 'Final game directory exists before a completed copy manifest.' }
            Write-Host ('Preparing real ' + $peer.role + ' copy; original is read-only: ' + $peer.staging_root)
            $copy = Copy-GoldbergGameTree -SourceRoot $GameRoot -DestinationRoot $peer.staging_root -LabRoot $LabRoot -LabId $script:GoldState.lab_id -Role $peer.role -Inventory $script:GoldInventory -MaxEntries $MaxEntries -MaxTotalBytes $MaxGameBytes -ExpectedSourceHashes $expected
            $manifestPath = Join-Path (Join-Path $LabRoot 'manifests') ($peer.role + '.json')
            Write-LabJson -Path $manifestPath -Value ([ordered]@{ schema = 1; lab_id = $script:GoldState.lab_id; role = $peer.role; files = $copy.files; total_bytes = $copy.total_bytes })
            $peer.copy_manifest_sha256 = Get-GoldbergDigest -Path $manifestPath -MaxBytes 67108864
            $peer.copy_complete = $true; Save-GoldState
            $fullyVerifiedThisRun++
        }
        $manifest = Get-GoldPeerManifest -Peer $peer
        if ($manifest.files.Count -ne $script:GoldInventory.files.Count) { throw 'Copy manifest and original file set differ.' }
        foreach ($file in $manifest.files) {
            if ($expected.ContainsKey($file.relative_path) -and $expected[$file.relative_path] -cne $file.sha256) { throw 'HOST and CLIENT source hashes differ.' }
            $expected[$file.relative_path] = $file.sha256
        }
        if (-not $peer.prepared) {
            $currentRoot = $peer.staging_root
            if (-not (Test-Path -LiteralPath $currentRoot) -and (Test-Path -LiteralPath $peer.game_root)) { $currentRoot = $peer.game_root }
            [void](Install-GoldbergCopySettings -GameRoot $currentRoot -LabRoot $LabRoot -LabId $script:GoldState.lab_id -Role $peer.role -GoldbergDllPath $dllPath -OriginalDllHash $script:GoldState.original_api_sha256 -InterfaceLines $script:GoldInterfaces -Language $Language)
            Assert-GoldbergConfiguredCopy -GameRoot $currentRoot -LabId $script:GoldState.lab_id -Role $peer.role -ExecutableHash $script:GoldState.executable_sha256 -DllHash $script:GoldToolkit.lock.dll.sha256 -InterfaceLines $script:GoldInterfaces -Language $Language
            if ($currentRoot -ine $peer.game_root) {
                if (Test-Path -LiteralPath $peer.game_root) { throw 'Refusing to overwrite a final game copy.' }
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($peer.game_root))
                [IO.Directory]::Move($currentRoot, $peer.game_root)
            }
            $peer.prepared = $true; Save-GoldState
        }
        Assert-GoldbergConfiguredCopy -GameRoot $peer.game_root -LabId $script:GoldState.lab_id -Role $peer.role -ExecutableHash $script:GoldState.executable_sha256 -DllHash $script:GoldToolkit.lock.dll.sha256 -InterfaceLines $script:GoldInterfaces -Language $Language
        Initialize-GoldBox -Peer $peer
        if ($peer.profile_seed.Count -eq 0) { Seed-GoldProfile -Peer $peer }
    }
    $freshInventory = Get-GoldbergTreeInventory -SourceRoot $GameRoot -MaxEntries $MaxEntries -MaxTotalBytes $MaxGameBytes
    $script:GoldInventory = $freshInventory
    Assert-GoldCatalog
    if ((Get-GoldbergDigest -Path (Join-Path $GameRoot 'Attila.exe') -MaxBytes 536870912) -cne $script:GoldState.executable_sha256 -or (Get-GoldbergDigest -Path (Join-Path $GameRoot 'steam_api.dll') -MaxBytes 67108864) -cne $script:GoldState.original_api_sha256) { throw 'Original critical binaries changed while preparing copies.' }
    $report.game_data_hash_validation = $(if ($fullyVerifiedThisRun -eq 2) { 'BOTH_COPIES_VERIFIED_DURING_PREPARE' } else { 'COPY_MANIFESTS_MATCH_CRITICAL_BINARIES_RECHECKED' })
}

function Get-GoldPeerProcesses {
    param($Peer)
    $observation = Get-LabAttilaProcesses -SbieStartExe $script:GoldStart -BoxName $Peer.box_name
    if ($observation.warnings.Count -gt 0) { throw ('Cannot verify sandbox process identity: ' + ($observation.warnings -join '; ')) }
    $expectedExe = Join-Path $Peer.game_root 'Attila.exe'
    foreach ($process in $observation.processes) {
        if ($process.path -ine $expectedExe -or $process.executable.status -ne 'OBSERVED' -or $process.executable.sha256 -cne $script:GoldState.executable_sha256) { throw 'An unexpected Attila executable is running in the owned Goldberg box.' }
    }
    if ($observation.processes_observed -gt 1) { throw ('More than one Attila process is running in ' + $Peer.box_name + '; no extra process was launched.') }
    return $observation
}

function Launch-GoldPeer {
    param($Peer)
    Assert-GoldBox -Peer $Peer -Names (Get-LabBoxNames -SbieIniExe $script:GoldIni) -RequireReady
    Assert-GoldbergConfiguredCopy -GameRoot $Peer.game_root -LabId $script:GoldState.lab_id -Role $Peer.role -ExecutableHash $script:GoldState.executable_sha256 -DllHash $script:GoldToolkit.lock.dll.sha256 -InterfaceLines $script:GoldInterfaces -Language $Language
    $current = Get-GoldPeerProcesses -Peer $Peer
    $status = 'ALREADY_RUNNING'
    if ($current.processes_observed -eq 0) {
        $port = $(if ($Peer.role -eq 'HOST') { 47584 } else { 47585 })
        $network = Get-GoldbergNetworkObservation
        if (@($network.occupied_ports | Where-Object { $_.port -eq $port }).Count -gt 0) { throw ('Intended peer TCP/UDP port is already occupied: ' + $port) }
        Write-Host ('Starting ' + $Peer.role + ' Attila from its own directory: ' + $Peer.game_root)
        $request = Invoke-LabNative -Executable $script:GoldStart -WorkingDirectory $Peer.game_root -Arguments @(('/box:' + $Peer.box_name), (Join-Path $Peer.game_root 'Attila.exe'))
        if ($request.ExitCode -ne 0) { throw ('Sandboxie rejected the launch request for ' + $Peer.role) }
        $deadline = [DateTime]::UtcNow.AddSeconds($LaunchTimeoutSeconds)
        do {
            Start-Sleep -Milliseconds 750
            $current = Get-GoldPeerProcesses -Peer $Peer
        } while ($current.processes_observed -eq 0 -and [DateTime]::UtcNow -lt $deadline)
        if ($current.processes_observed -ne 1) { throw ('No verified copied Attila process appeared for ' + $Peer.role + '; no multiplayer success is inferred.') }
        $status = 'PROCESS_OBSERVED'
    }
    return [pscustomobject]@{ role = $Peer.role; box = $Peer.box_name; game_root = $Peer.game_root; launch = $status; process_observation = $current; profile_physical = $Peer.profile_physical; profile_seed = $Peer.profile_seed; mod_status = $Peer.mod_status }
}

function Collect-GoldPeer {
    param($Peer)
    Assert-GoldBox -Peer $Peer -Names (Get-LabBoxNames -SbieIniExe $script:GoldIni) -RequireReady
    $observation = Get-GoldPeerProcesses -Peer $Peer
    $allow = @('MK1212_mp_debug.log', 'twdll.log', 'MK1212_log.txt', 'PR45_RUNTIME_TRACE.txt', 'preferences.script.txt', 'user.script.txt', 'goldberg_log.txt', 'steam_api.log')
    $scan = Get-LabFilesBounded -Root $Peer.box_root -MaxEntries $MaxEntries
    $files = @(); [long]$bytes = 0; $count = 0; $limited = $scan.Truncated; $warnings = @($scan.Warnings)
    $destinationRoot = Join-Path $script:GoldCapture $Peer.role
    [void][IO.Directory]::CreateDirectory($destinationRoot)
    foreach ($file in ($scan.Files | Where-Object { $allow -contains $_.Name -and $_.FullName -notmatch '[\\/](?:save_games|saves)[\\/]' } | Sort-Object FullName)) {
        $count++
        if ($count -gt 128) { $limited = $true; $warnings += 'Evidence file count limit reached.'; break }
        $remaining = [long]67108864 - $bytes
        if ($remaining -le 0) { $limited = $true; $warnings += 'Evidence total byte limit reached.'; break }
        $relative = $file.FullName.Substring($Peer.box_root.TrimEnd('\').Length).TrimStart([char[]]@('\', '/'))
        try {
            $snapshot = Copy-LabEvidenceFile -Source $file.FullName -Destination (Join-Path $destinationRoot $relative) -SourceRoot $Peer.box_root -DestinationRoot $destinationRoot -MaxBytes ([Math]::Min([long]16777216, $remaining))
            $files += $snapshot
            if ($snapshot.status -eq 'CAPTURED') { $bytes += $snapshot.captured_bytes }
            elseif ($snapshot.status -eq 'SKIPPED_LIMIT') { $limited = $true; $warnings += ('Evidence file exceeded the per-file or remaining total byte limit: ' + $file.Name) }
        } catch {
            $reason = $_.Exception.Message
            if ($reason -match 'limit|budget') { $limited = $true; $warnings += ('Evidence capture reached a byte limit: ' + $file.Name) }
            $files += [pscustomobject]@{ source = $file.FullName; status = 'BLOCKED'; reason = $reason }
        }
    }
    return [pscustomobject]@{ role = $Peer.role; box = $Peer.box_name; game_root = $Peer.game_root; process_observation = $observation; profile_physical = $Peer.profile_physical; profile_seed = $Peer.profile_seed; mod_status = $Peer.mod_status; files = $files; captured_bytes = $bytes; scan_limited = $limited; warnings = $warnings; log_freshness = 'NOT_PROVEN' }
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This operator experiment requires Windows and Sandboxie; no game execution was attempted.' }
    $script:GoldToolkit = Get-GoldbergToolkitContext -ScriptDirectory $PSScriptRoot -GoldbergArchive $GoldbergArchive
    $report.source = $script:GoldToolkit.source
    $requestedGame = $GameRoot
    if (-not $PSBoundParameters.ContainsKey('GameRoot')) {
        if (Test-Path -LiteralPath (Join-Path $script:GoldToolkit.root 'Attila.exe') -PathType Leaf) { $requestedGame = $script:GoldToolkit.root }
        elseif (-not (Test-Path -LiteralPath (Join-Path $GameRoot 'Attila.exe') -PathType Leaf)) { $requestedGame = $null }
    }
    $script:GoldTools = Get-LabToolPaths -GameRoot $requestedGame -SandboxieRoot $SandboxieRoot
    $report.tools = $script:GoldTools
    if (-not $script:GoldTools.game_root) { throw 'Attila installation was not found. Pass -GameRoot with the existing folder containing Attila.exe.' }
    Set-Variable -Name GameRoot -Value ([IO.Path]::GetFullPath($script:GoldTools.game_root).TrimEnd('\')) -Scope Script
    Assert-LabNoReparsePath -Path $GameRoot
    $originalExe = Join-Path $GameRoot 'Attila.exe'; $originalApi = Join-Path $GameRoot 'steam_api.dll'
    if ((Get-GoldbergPeMachine -Path $originalExe) -ne 332 -or (Get-GoldbergPeMachine -Path $originalApi) -ne 332) { throw 'This locked Goldberg package requires x86 Attila and x86 steam_api.dll.' }
    $exeHash = Get-GoldbergDigest -Path $originalExe -MaxBytes 536870912
    $apiHash = Get-GoldbergDigest -Path $originalApi -MaxBytes 67108864
    if ($apiHash -ceq $script:GoldToolkit.lock.dll.sha256) { throw 'The selected original installation already contains the pinned Goldberg DLL; choose the unchanged owned source.' }
    $script:GoldInterfaces = Get-GoldbergInterfaces -OriginalDll $originalApi
    $rootAppId = Join-Path $GameRoot 'steam_appid.txt'
    if (Test-Path -LiteralPath $rootAppId -PathType Leaf) {
        if ((Read-LabTextBounded -Path $rootAppId -MaxBytes 128).Trim() -cne '325610') { throw 'Original root steam_appid.txt contradicts Attila app ID 325610.' }
    }
    $languageSource = 'EXPLICIT'
    if (-not $Language) {
        $languageSource = 'FALLBACK_ENGLISH'; $Language = 'english'
        $steamApps = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($GameRoot))
        $acf = Join-Path $steamApps 'appmanifest_325610.acf'
        if (Test-Path -LiteralPath $acf -PathType Leaf) {
            $values = Get-LabVdfValue -Text (Read-LabTextBounded -Path $acf) -Key 'language'
            if ($values.Count -eq 1 -and $values[0] -match '^[a-z_]{2,32}$') { $Language = $values[0]; $languageSource = 'INSTALLED_APP_MANIFEST' }
        }
    }
    $report.language = [pscustomobject]@{ value = $Language; source = $languageSource }
    $report.source_game_root = $GameRoot
    $report.source_game = [pscustomobject]@{ executable_sha256 = $exeHash; original_api_sha256 = $apiHash; interfaces = $script:GoldInterfaces; original_writes = 'NONE_BY_TOOLKIT' }
    $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    if (-not $appData) { throw 'Windows ApplicationData is unavailable.' }
    $script:GoldHostProfile = Join-Path $appData 'The Creative Assembly\Attila'
    Initialize-GoldLab
    if ($script:GoldState.executable_sha256 -cne $exeHash -or $script:GoldState.original_api_sha256 -cne $apiHash) { throw 'Original critical binaries changed since this lab was created; copies were preserved.' }
    if (-not $script:GoldTools.sandboxie_root) { $report.reasons += 'Missing Sandboxie Start.exe and SbieIni.exe; install Sandboxie separately or pass -SandboxieRoot.' }
    $service = Get-Service -Name SbieSvc -ErrorAction SilentlyContinue
    if ($null -eq $service -or $service.Status -ne 'Running') { $report.reasons += 'Sandboxie service SbieSvc is not running.' }
    $archive = Get-Item -LiteralPath $script:GoldToolkit.archive -ErrorAction SilentlyContinue
    if ($null -eq $archive -or $archive.PSIsContainer -or $archive.Length -ne [long]$script:GoldToolkit.lock.archive.bytes -or (Get-GoldbergDigest -Path $script:GoldToolkit.archive -MaxBytes 67108864) -cne $script:GoldToolkit.lock.archive.sha256) { $report.reasons += 'Packaged Goldberg archive is missing or does not match its locked hash.' }
    if ($report.reasons.Count -gt 0) { throw 'Goldberg lab prerequisites are incomplete; original installation was not modified.' }
    $script:GoldStart = Join-Path $script:GoldTools.sandboxie_root 'Start.exe'
    $script:GoldIni = Join-Path $script:GoldTools.sandboxie_root 'SbieIni.exe'
    $names = Get-LabBoxNames -SbieIniExe $script:GoldIni
    foreach ($peer in $script:GoldState.roles) { Assert-GoldBox -Peer $peer -Names $names }
    Write-Host 'Inspecting original game file inventory and required copy space...'
    $script:GoldInventory = Get-GoldbergTreeInventory -SourceRoot $GameRoot -MaxEntries $MaxEntries -MaxTotalBytes $MaxGameBytes
    Assert-GoldCatalog
    [long]$missing = 0
    foreach ($peer in $script:GoldState.roles) {
        if ($peer.copy_complete) { continue }
        foreach ($file in $script:GoldInventory.files) { if (-not (Test-Path -LiteralPath (Join-Path $peer.staging_root $file.relative_path))) { $missing += $file.bytes } }
    }
    $drive = New-Object IO.DriveInfo -ArgumentList ([IO.Path]::GetPathRoot($LabRoot))
    $required = Assert-GoldbergDiskBudget -MissingBytes $missing -AvailableBytes $drive.AvailableFreeSpace -ReserveBytes $ReserveBytes
    $report.disk = [pscustomobject]@{ missing_copy_bytes = $missing; reserve_bytes = $ReserveBytes; required_bytes = $required; free_bytes = $drive.AvailableFreeSpace; original_game_bytes = $script:GoldInventory.total_bytes }
    $report.network = Get-GoldbergNetworkObservation
    if ($Mode -ne 'Collect' -and $report.network.active_ipv4_adapters.Count -eq 0) { throw 'No active non-loopback IPv4 adapter was observed; this Goldberg build may skip custom broadcasts.' }
    if ($Mode -eq 'Preflight') {
        $report.status = 'READY'
        $report.peers = @($script:GoldState.roles | ForEach-Object { [pscustomobject]@{ role = $_.role; game_root = $_.game_root; copy_complete = $_.copy_complete; prepared = $_.prepared; box_setup_complete = $_.box_setup_complete } })
    } else {
        if ($Mode -eq 'Run' -or $Mode -eq 'Prepare') { Prepare-GoldPeers }
        foreach ($peer in $script:GoldState.roles) {
            if (-not $peer.prepared -or -not $peer.box_setup_complete) { throw ('Run Prepare before ' + $Mode + '; peer is incomplete: ' + $peer.role) }
        }
        if ($Mode -eq 'Prepare') { $report.status = 'PREPARED'; $report.peers = @($script:GoldState.roles) }
        elseif ($Mode -eq 'Collect') {
            foreach ($peer in $script:GoldState.roles) { $report.peers += Collect-GoldPeer -Peer $peer }
            $report.status = 'COLLECTED'
        } else {
            foreach ($peer in $script:GoldState.roles) { $report.peers += Launch-GoldPeer -Peer $peer }
            $report.status = 'CLIENTS_OBSERVED'
        }
        $ids = New-Object 'System.Collections.Generic.List[uint32]'
        foreach ($peer in $report.peers) {
            if ($null -eq $peer.PSObject.Properties['process_observation']) { continue }
            foreach ($process in $peer.process_observation.processes) { $ids.Add([uint32]$process.process_id) }
        }
        if ($ids.Count -gt 0) {
            $report.network = Get-GoldbergNetworkObservation -ProcessIds $ids.ToArray()
            $portChecks = @()
            foreach ($peer in $report.peers) {
                if ($null -eq $peer.PSObject.Properties['process_observation']) { continue }
                $expectedPort = $(if ($peer.role -eq 'HOST') { 47584 } else { 47585 })
                $peerIds = @($peer.process_observation.processes | ForEach-Object { [uint32]$_.process_id })
                foreach ($transport in @('TCP', 'UDP')) {
                    $listeners = @($report.network.process_endpoints | Where-Object { $peerIds -contains [uint32]$_.process_id -and $_.transport -eq $transport -and ($transport -eq 'UDP' -or $_.state -eq 'Listen') })
                    $ports = @($listeners | ForEach-Object { [int]$_.port } | Sort-Object -Unique)
                    $portChecks += [pscustomobject]@{
                        role = $peer.role; transport = $transport; intended_port = $expectedPort; observed_listener_ports = $ports
                        status = $(if ($report.network.endpoint_status -ne 'OBSERVED') { 'UNAVAILABLE' } elseif ($ports -contains $expectedPort) { 'INTENDED_PORT_OBSERVED' } elseif ($ports.Count -gt 0) { 'DIFFERENT_PORTS_OBSERVED' } else { 'NO_LISTENER_OBSERVED' })
                    }
                }
            }
            $report.network | Add-Member -NotePropertyName peer_port_observations -NotePropertyValue $portChecks
        }
    }
    if ($report.game_data_hash_validation -eq 'NOT_RUN') { $report.game_data_hash_validation = 'CRITICAL_BINARIES_CHECKED_DATA_HASHES_NOT_RECHECKED' }
    $report.warnings += 'Two observed processes do not prove LAN discovery, lobby connection, campaign progress, MK1212 load order or simultaneous turns.'
    $report.warnings += 'Existing user.script and used_mods selections require explicit pack/order verification; profile snapshots alone are not MK1212 readiness.'
} catch {
    $report.status = 'BLOCKED'; $report.reasons += $_.Exception.Message
} finally {
    if ($script:GoldCapture) {
        try { Write-LabJson -Path $report.report_path -Value $report }
        catch { $report.status = 'BLOCKED'; $report.reasons += ('Report could not be saved: ' + $_.Exception.Message); $report.report_path = $null }
    }
    if ($null -ne $script:GoldLock) { $script:GoldLock.Dispose() }
}
$report | ConvertTo-Json -Depth 14
if ($report.report_path) { Write-Host ('Report: ' + $report.report_path) }
if ($report.status -eq 'BLOCKED') { exit 2 }
exit 0
