# Real Steam clients in two standard Sandboxie boxes; operator-run experiment.
[CmdletBinding()]
param(
    [ValidateSet('Preflight', 'Setup', 'LaunchHost', 'LaunchClient', 'Collect')][string]$Mode = 'Preflight',
    [string]$LabRoot = 'D:\MK1212-DualClientLab',
    [string]$SteamRoot,
    [string]$GameRoot,
    [string]$SandboxieRoot,
    [ValidateRange(1, 100000)][int]$MaxEntries = 20000,
    [ValidateRange(1, 67108864)][long]$MaxFileBytes = 16777216,
    [ValidateRange(1, 120)][int]$ProbeTimeoutSeconds = 30
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'dual_client_lab_core.psm1') -Force -DisableNameChecking

$script:LabOwner = 'MK1212Scripts.dual-client-lab'
$script:LabState = $null
$script:LabStatePath = $null
$script:HostAttilaProfile = $null
$script:CaptureDirectory = $null
$script:OperationLock = $null
$script:ToolPaths = $null
$script:SbieIniExe = $null
$script:SbieStartExe = $null
$report = [ordered]@{
    schema = 1; owner = $script:LabOwner; mode = $Mode; created_utc = [DateTime]::UtcNow.ToString('o')
    status = 'BLOCKED'; reasons = @(); warnings = @(); source = $null; tools = $null; tool_identities = @()
    lab_root = $LabRoot; lab_id = $null; game_identity = $null; peers = @()
    multiplayer = 'NOT_RUN'; lobby = 'NOT_RUN'; campaign_turns = 'NOT_RUN'; accounts = 'NOT_VERIFIED'
    report_path = $null; evidence_directory = $null
}

function Save-LabState {
    Write-LabJson -Path $script:LabStatePath -Value $script:LabState -ReplaceOwned
}

function Assert-LabState {
    if ($script:LabState.schema -ne 1 -or $script:LabState.owner -ne $script:LabOwner -or $script:LabState.lab_id -notmatch '^[0-9a-f]{32}$') {
        throw 'Lab ownership state has an unsupported schema or owner.'
    }
    if ($script:LabState.lab_root -ine $LabRoot -or $script:LabState.host_profile_directory -ine $script:HostAttilaProfile) {
        throw 'Lab state belongs to a different root or Windows profile.'
    }
    if (@($script:LabState.boxes).Count -ne 2) { throw 'Lab state must contain exactly the two supported boxes.' }
    $expected = @{ HOST = 'MK1212LabHost'; CLIENT = 'MK1212LabClient' }
    $roles = @()
    foreach ($box in $script:LabState.boxes) {
        if (-not $expected.ContainsKey([string]$box.role) -or $roles -contains $box.role -or $box.name -cne $expected[$box.role]) { throw 'Unexpected box identity in lab state.' }
        $roles += $box.role
        $expectedRoot = Join-Path (Join-Path $LabRoot 'sandboxes') $box.name
        if ($box.root -ine $expectedRoot -or -not (Test-LabPathContained -Root $LabRoot -Path $box.root)) { throw 'Unexpected box root in ownership state.' }
        if ($null -ne $box.profile_physical -and -not (Test-LabPathContained -Root $box.root -Path $box.profile_physical)) { throw 'Saved profile mapping escaped its box.' }
    }
}

function Initialize-LabRoot {
    if ($LabRoot -notmatch '^[A-Za-z]:\\' -or $LabRoot -match '[%\r\n]' -or $LabRoot.StartsWith('\\')) { throw 'LabRoot must be a local absolute Windows drive path without expansion characters.' }
    $fullRoot = [System.IO.Path]::GetFullPath($LabRoot).TrimEnd('\')
    $driveRoot = [System.IO.Path]::GetPathRoot($fullRoot)
    if (-not (Test-Path -LiteralPath $driveRoot -PathType Container)) { throw ('Lab drive is unavailable: ' + $driveRoot) }
    if ($driveRoot.TrimEnd('\') -ieq [Environment]::GetEnvironmentVariable('SystemDrive')) { throw 'Choose a lab location outside the Windows system drive; the default is D:\MK1212-DualClientLab.' }
    if ($fullRoot -eq $driveRoot.TrimEnd('\')) { throw 'A whole drive cannot be a lab root.' }
    Set-Variable -Name LabRoot -Value $fullRoot -Scope Script
    Assert-LabNoReparsePath -Path $LabRoot
    $script:LabStatePath = Join-Path $LabRoot '.mk1212-dual-client-lab.json'
    if (-not (Test-Path -LiteralPath $script:LabStatePath -PathType Leaf)) {
        if (Test-Path -LiteralPath $LabRoot) {
            if (-not (Test-Path -LiteralPath $LabRoot -PathType Container)) { throw 'LabRoot is not a directory.' }
            $existing = @(Get-ChildItem -LiteralPath $LabRoot -Force -ErrorAction Stop | Select-Object -First 1)
            if ($existing.Count -gt 0) { throw 'Refusing to adopt a nonempty directory without lab ownership state.' }
        } else { [void][System.IO.Directory]::CreateDirectory($LabRoot) }
        $boxes = @()
        foreach ($role in @('HOST', 'CLIENT')) {
            $name = $(if ($role -eq 'HOST') { 'MK1212LabHost' } else { 'MK1212LabClient' })
            $boxes += [pscustomobject]@{
                role = $role; name = $name; root = (Join-Path (Join-Path $LabRoot 'sandboxes') $name)
                setup_started = $false; setup_complete = $false; profile_physical = $null
                profile_marker = $null; profile_nonce = $null
            }
        }
        $script:LabState = [pscustomobject]@{
            schema = 1; owner = $script:LabOwner; lab_id = [guid]::NewGuid().ToString('N')
            created_utc = [DateTime]::UtcNow.ToString('o'); lab_root = $LabRoot
            host_profile_directory = $script:HostAttilaProfile; boxes = $boxes
        }
        Write-LabJson -Path $script:LabStatePath -Value $script:LabState
    }
    # Validate ownership before creating even the operation-lock file in an existing root.
    $script:LabState = Read-LabJson -Path $script:LabStatePath
    Assert-LabState
    $lockPath = Join-Path $LabRoot '.lab-operation.lock'
    Assert-LabNoReparsePath -Path $lockPath
    $script:OperationLock = New-Object System.IO.FileStream -ArgumentList $lockPath, ([System.IO.FileMode]::OpenOrCreate), ([System.IO.FileAccess]::ReadWrite), ([System.IO.FileShare]::None)
    $script:LabState = Read-LabJson -Path $script:LabStatePath
    Assert-LabState
    $captureParent = Join-Path $LabRoot 'evidence'
    Assert-LabNoReparsePath -Path $captureParent
    [void][System.IO.Directory]::CreateDirectory($captureParent)
    $captureLeaf = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + $Mode.ToLowerInvariant() + '-' + [guid]::NewGuid().ToString('N')
    $script:CaptureDirectory = Join-Path $captureParent $captureLeaf
    [void][System.IO.Directory]::CreateDirectory($script:CaptureDirectory)
    $report.lab_root = $LabRoot
    $report.lab_id = $script:LabState.lab_id
    $report.evidence_directory = $script:CaptureDirectory
    $report.report_path = Join-Path $script:CaptureDirectory 'report.json'
}

function Get-ExpectedBoxSettings {
    param($Box)
    return [ordered]@{
        Enabled = 'y'; FileRootPath = $Box.root; SeparateUserFolders = 'y'
        WriteFilePath = $script:HostAttilaProfile
        Comment = ('MK1212 dual-client lab ' + $script:LabState.lab_id + ' ' + $Box.role)
    }
}

function Assert-BoxOwnership {
    param($Box, [string[]]$ExistingNames)
    $rootExists = Test-Path -LiteralPath $Box.root
    $boxExists = $ExistingNames -contains $Box.name
    if ($rootExists) {
        Assert-LabNoReparsePath -Path $Box.root
        $markerPath = Join-Path $Box.root '.mk1212-lab-box.json'
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { throw ('Refusing existing unowned box directory: ' + $Box.root) }
        $marker = Read-LabJson -Path $markerPath
        if ($marker.schema -ne 1 -or $marker.owner -ne $script:LabOwner -or $marker.lab_id -ne $script:LabState.lab_id -or $marker.box -cne $Box.name -or $marker.role -cne $Box.role) {
            throw ('Box directory ownership does not match: ' + $Box.name)
        }
    }
    if ($boxExists -and (-not $Box.setup_started -or -not $rootExists)) { throw ('Refusing existing unowned Sandboxie box: ' + $Box.name) }
    if ($Box.setup_complete -and (-not $rootExists -or -not $boxExists)) { throw ('Previously configured lab box is missing: ' + $Box.name) }
}

function Assert-BoxSettings {
    param($Box)
    $expected = Get-ExpectedBoxSettings -Box $Box
    foreach ($setting in $expected.Keys) {
        $actual = Get-LabSetting -SbieIniExe $script:SbieIniExe -BoxName $Box.name -Setting $setting
        if (-not (Test-LabSettingValues -Expected @($expected[$setting]) -Actual $actual)) { throw ('Lab box settings changed or are incomplete: ' + $Box.name + '/' + $setting) }
    }
    $enabled = Get-LabBoxNames -SbieIniExe $script:SbieIniExe -EnabledOnly
    if ($enabled -notcontains $Box.name) { throw ('Lab box is not enabled for this Windows user: ' + $Box.name) }
}

function Assert-ProfileMapping {
    param($Box)
    if (-not $Box.profile_physical -or -not $Box.profile_marker -or $Box.profile_nonce -notmatch '^[0-9a-f]{32}$') { throw ('Profile mapping is missing: ' + $Box.name) }
    if (-not (Test-LabPathContained -Root $Box.root -Path $Box.profile_physical) -or -not (Test-LabPathContained -Root $Box.profile_physical -Path $Box.profile_marker)) { throw 'Profile mapping escaped its box.' }
    Assert-LabNoReparsePath -Path $Box.profile_marker
    $marker = Read-LabJson -Path $Box.profile_marker
    if ($marker.schema -ne 1 -or $marker.owner -ne $script:LabOwner -or $marker.nonce -cne $Box.profile_nonce -or $marker.role -cne $Box.role -or $marker.requested_box -cne $Box.name -or $marker.profile_logical -ine $script:HostAttilaProfile) {
        throw ('Profile marker is invalid: ' + $Box.name)
    }
    $hostMarker = Join-Path $script:HostAttilaProfile ([System.IO.Path]::GetFileName($Box.profile_marker))
    if (Test-Path -LiteralPath $hostMarker) { throw ('Profile marker also exists outside the sandbox: ' + $Box.name) }
}

function Invoke-ProfileProbe {
    param($Box)
    $nonce = [guid]::NewGuid().ToString('N')
    $markerName = 'mk1212-dual-probe-' + $nonce + '.json'
    $hostMarker = Join-Path $script:HostAttilaProfile $markerName
    if (Test-Path -LiteralPath $hostMarker) { throw 'Unexpected profile-probe marker collision.' }
    $powershellExe = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) { throw 'Windows PowerShell is unavailable for the isolated profile probe.' }
    $probePath = Join-Path $PSScriptRoot 'dual_client_probe.ps1'
    $result = Invoke-LabNative -Executable $script:SbieStartExe -TimeoutSeconds $ProbeTimeoutSeconds -Arguments @(
        ('/box:' + $Box.name), '/wait', $powershellExe, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $probePath,
        '-Nonce', $nonce, '-Role', $Box.role, '-BoxName', $Box.name
    )
    if ($result.ExitCode -ne 0) { throw ('Boxed profile probe failed: ' + $Box.name + '. Check script policy or the Sandboxie message log.') }
    if (Test-Path -LiteralPath $hostMarker) { throw ('Profile isolation failed: marker appeared in the Windows host profile for ' + $Box.name) }
    $scan = Get-LabFilesBounded -Root $Box.root -MaxEntries $MaxEntries
    if ($scan.Truncated -or $scan.Warnings.Count -gt 0) { throw ('Cannot completely inspect the fresh profile probe within traversal limits: ' + $Box.name) }
    $markers = @($scan.Files | Where-Object { $_.Name -ceq $markerName })
    if ($markers.Count -ne 1) { throw ('Expected one physical boxed profile marker, found ' + $markers.Count + ': ' + $Box.name) }
    $Box.profile_physical = $markers[0].DirectoryName
    $Box.profile_marker = $markers[0].FullName
    $Box.profile_nonce = $nonce
    Assert-ProfileMapping -Box $Box
}

function Initialize-LabBox {
    param($Box)
    $names = Get-LabBoxNames -SbieIniExe $script:SbieIniExe
    Assert-BoxOwnership -Box $Box -ExistingNames $names
    if ($Box.setup_complete) {
        Assert-BoxSettings -Box $Box
        Assert-ProfileMapping -Box $Box
        return
    }
    if ($names -contains $Box.name) {
        $enumeration = Invoke-LabNative -Executable $script:SbieStartExe -Arguments @('/silent', ('/box:' + $Box.name), '/listpids')
        if ($enumeration.ExitCode -ne 0) { throw ('Cannot inspect the incomplete box: ' + $Box.name) }
        $processIds = ConvertFrom-LabPidList -Text $enumeration.Output
        if ($processIds.Count -gt 0) { throw ('Close programs in the incomplete box before retrying Setup: ' + $Box.name) }
    }
    $Box.setup_started = $true
    Save-LabState
    if (-not (Test-Path -LiteralPath $Box.root)) {
        Assert-LabNoReparsePath -Path $Box.root
        [void][System.IO.Directory]::CreateDirectory($Box.root)
        Write-LabJson -Path (Join-Path $Box.root '.mk1212-lab-box.json') -Value ([ordered]@{
            schema = 1; owner = $script:LabOwner; lab_id = $script:LabState.lab_id; box = $Box.name; role = $Box.role
        })
    }
    $settings = Get-ExpectedBoxSettings -Box $Box
    foreach ($key in $settings.Keys) { Set-LabVerifiedSetting -SbieIniExe $script:SbieIniExe -BoxName $Box.name -Setting $key -Value $settings[$key] }
    $reload = Invoke-LabNative -Executable $script:SbieStartExe -Arguments @('/reload')
    if ($reload.ExitCode -ne 0) { throw 'Sandboxie configuration reload failed.' }
    Assert-BoxSettings -Box $Box
    Invoke-ProfileProbe -Box $Box
    $Box.setup_complete = $true
    Save-LabState
}

function Get-PeerEvidence {
    param($Box)
    Assert-BoxSettings -Box $Box
    Assert-ProfileMapping -Box $Box
    $processResult = Get-LabAttilaProcesses -SbieStartExe $script:SbieStartExe -BoxName $Box.name
    $allowlist = @('MK1212_mp_debug.log', 'twdll.log', 'MK1212_log.txt', 'PR45_RUNTIME_TRACE.txt', 'preferences.script.txt', 'user.script.txt')
    $scan = Get-LabFilesBounded -Root $Box.root -MaxEntries $MaxEntries
    $candidates = @($scan.Files | Where-Object { $allowlist -contains $_.Name -and $_.FullName -notmatch '[\\/](?:save_games|saves)[\\/]' } | Sort-Object FullName)
    $captured = @()
    $warnings = @($scan.Warnings) + @($processResult.warnings)
    $totalBytes = 0L
    $fileCount = 0
    $peerDirectory = Join-Path $script:CaptureDirectory $Box.role
    [void][System.IO.Directory]::CreateDirectory($peerDirectory)
    foreach ($file in $candidates) {
        if ($fileCount -ge 32) { $warnings += 'FILE_COUNT_LIMIT: maximum 32 evidence files per peer.'; break }
        $fileCount++
        if ($totalBytes -ge 67108864 -or $totalBytes + $file.Length -gt 67108864) {
            $captured += [pscustomobject]@{ status = 'SKIPPED_TOTAL_LIMIT'; source = $file.FullName; source_bytes = $file.Length }
            continue
        }
        $relative = $file.FullName.Substring($Box.root.TrimEnd('\').Length).TrimStart('\', '/')
        $destination = Join-Path $peerDirectory $relative
        try {
            $remainingBudget = [Math]::Min($MaxFileBytes, (67108864 - $totalBytes))
            $snapshot = Copy-LabEvidenceFile -Source $file.FullName -Destination $destination -SourceRoot $Box.root -DestinationRoot $peerDirectory -MaxBytes $remainingBudget
            $captured += $snapshot
            if ($snapshot.status -eq 'CAPTURED') { $totalBytes += $snapshot.captured_bytes }
        } catch { $captured += [pscustomobject]@{ status = 'BLOCKED'; source = $file.FullName; reason = $_.Exception.Message } }
    }
    $foundNames = @($candidates | ForEach-Object { $_.Name })
    $missing = @($allowlist | Where-Object { $foundNames -notcontains $_ })
    if ($scan.Truncated) { $warnings += 'ENTRY_LIMIT: some owned box paths were not inspected.' }
    return [pscustomobject]@{
        role = $Box.role; box = $Box.name; profile_physical = $Box.profile_physical
        process_observation = $processResult; files = @($captured); missing_files = @($missing)
        entries_scanned = $scan.EntriesScanned; scan_limited = $scan.Truncated
        captured_bytes = $totalBytes; warnings = @($warnings)
    }
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This operator experiment requires Windows and an installed Sandboxie service. No runtime test ran.' }
    $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    if ([string]::IsNullOrWhiteSpace($appData)) { throw 'The current Windows ApplicationData directory is unavailable.' }
    $script:HostAttilaProfile = Join-Path $appData 'The Creative Assembly\Attila'
    Initialize-LabRoot
    $report.source = Get-LabSourceIdentity -ScriptDirectory $PSScriptRoot
    $script:ToolPaths = Get-LabToolPaths -SteamRoot $SteamRoot -GameRoot $GameRoot -SandboxieRoot $SandboxieRoot
    $report.tools = $script:ToolPaths
    foreach ($requirement in @('steam_root', 'game_root', 'sandboxie_root')) {
        if (-not $script:ToolPaths.$requirement) { $report.reasons += ('Missing ' + $requirement + '; install separately or pass the corresponding explicit directory parameter.') }
    }
    $service = Get-Service -Name SbieSvc -ErrorAction SilentlyContinue
    if ($null -eq $service -or $service.Status -ne 'Running') { $report.reasons += 'Sandboxie service SbieSvc is not running. Install/start it separately; this toolkit does not install or elevate.' }
    if ($report.reasons.Count -gt 0) { throw 'Preconditions are incomplete.' }
    $script:SbieIniExe = Join-Path $script:ToolPaths.sandboxie_root 'SbieIni.exe'
    $script:SbieStartExe = Join-Path $script:ToolPaths.sandboxie_root 'Start.exe'
    foreach ($toolExecutable in @($script:SbieIniExe, $script:SbieStartExe, (Join-Path $script:ToolPaths.steam_root 'steam.exe'))) {
        $report.tool_identities += Get-LabFileIdentity -Path $toolExecutable
    }
    $report.game_identity = [ordered]@{
        steam_app_id = '325610'; steam_manifest = $script:ToolPaths.app_manifest; steam_build_id = $script:ToolPaths.game_build_id
        executable = (Get-LabFileIdentity -Path (Join-Path $script:ToolPaths.game_root 'Attila.exe'))
        note = 'Game executable identity is separate from toolkit source_sha and is not Steam authentication proof.'
    }
    $names = Get-LabBoxNames -SbieIniExe $script:SbieIniExe
    foreach ($box in $script:LabState.boxes) {
        Assert-BoxOwnership -Box $box -ExistingNames $names
        if ($box.setup_complete) { Assert-BoxSettings -Box $box; Assert-ProfileMapping -Box $box }
    }
    if ($Mode -eq 'Preflight') {
        $report.status = 'READY'
        foreach ($box in $script:LabState.boxes) {
            $report.peers += [pscustomobject]@{ role = $box.role; box = $box.name; setup = $(if ($box.setup_complete) { 'COMPLETE' } else { 'NOT_RUN' }); profile_physical = $box.profile_physical }
        }
        $report.warnings += 'READY covers installed prerequisites only. Sandboxie/Attila compatibility, account identity and multiplayer remain untested.'
    } elseif ($Mode -eq 'Setup') {
        foreach ($box in $script:LabState.boxes) {
            Initialize-LabBox -Box $box
            $report.peers += [pscustomobject]@{ role = $box.role; box = $box.name; setup = 'COMPLETE'; profile_physical = $box.profile_physical; profile_mapping = 'NONCE_OBSERVED_IN_OWNED_BOX' }
        }
        if ($script:LabState.boxes[0].profile_physical -ieq $script:LabState.boxes[1].profile_physical) { throw 'The two profile mappings unexpectedly coincide.' }
        $report.status = 'SETUP_COMPLETE'
    } else {
        foreach ($box in $script:LabState.boxes) { if (-not $box.setup_complete) { throw ('Run Setup before ' + $Mode + '; incomplete box: ' + $box.name) } }
        if ($Mode -eq 'Collect') {
            foreach ($box in $script:LabState.boxes) { $report.peers += Get-PeerEvidence -Box $box }
            $hostIds = @($report.peers[0].process_observation.processes | ForEach-Object { $_.process_id })
            $clientIds = @($report.peers[1].process_observation.processes | ForEach-Object { $_.process_id })
            if (@($hostIds | Where-Object { $clientIds -contains $_ }).Count -gt 0) {
                $report['process_identity_conflict'] = 'SAME_PID_IN_BOTH_PEERS'
                throw 'Contradictory Sandboxie membership: the same Attila PID appeared in both peer roles.'
            }
            $identities = @()
            foreach ($peer in $report.peers) {
                foreach ($gameProcess in $peer.process_observation.processes) {
                    if ($gameProcess.executable.status -eq 'OBSERVED') { $identities += $gameProcess.executable.sha256 }
                }
            }
            $report['executable_comparison'] = 'NOT_AVAILABLE'
            if ($report.peers[0].process_observation.processes_observed -eq 1 -and $report.peers[1].process_observation.processes_observed -eq 1 -and $identities.Count -eq 2) {
                $report.executable_comparison = $(if ($identities[0] -ceq $identities[1]) { 'MATCH' } else { 'MISMATCH' })
            }
            $report.status = 'COLLECTED'
            $report.warnings += 'Collected files are immutable snapshots. Missing optional logs are listed per peer; no gameplay or synchronization verdict is inferred.'
        } else {
            $role = $(if ($Mode -eq 'LaunchHost') { 'HOST' } else { 'CLIENT' })
            $box = @($script:LabState.boxes | Where-Object { $_.role -eq $role })[0]
            Assert-BoxSettings -Box $box
            Assert-ProfileMapping -Box $box
            $launch = Invoke-LabNative -Executable $script:SbieStartExe -Arguments @(('/box:' + $box.name), (Join-Path $script:ToolPaths.steam_root 'steam.exe'))
            if ($launch.ExitCode -ne 0) { throw ('Steam launch request failed in ' + $box.name) }
            $report.peers += [pscustomobject]@{ role = $role; box = $box.name; steam_launch = 'REQUESTED'; account = 'INTERACTIVE_LOGIN_REQUIRED'; game_launch = 'MANUAL_FROM_STEAM_LIBRARY'; profile_physical = $box.profile_physical }
            $report.status = 'LAUNCH_REQUESTED'
            $report.warnings += ('Sign in interactively to the intended ' + $role + ' Steam account, then start Attila from that Steam window. The accounts require separate available game copies.')
        }
    }
} catch {
    $report.status = 'BLOCKED'
    $report.reasons += $_.Exception.Message
} finally {
    if ($script:CaptureDirectory) {
        try { Write-LabJson -Path $report.report_path -Value $report }
        catch { $report.status = 'BLOCKED'; $report.reasons += ('Report could not be saved: ' + $_.Exception.Message); $report.report_path = $null }
    }
    if ($null -ne $script:OperationLock) { $script:OperationLock.Dispose() }
}
$report | ConvertTo-Json -Depth 14
if ($report.report_path) { Write-Host ('Report: ' + $report.report_path) }
if ($report.evidence_directory) { Write-Host ('Evidence directory: ' + $report.evidence_directory) }
if ($report.status -eq 'BLOCKED') { exit 2 }
exit 0
