param([int]$LaunchTimeoutSeconds = 600, [switch]$PrepareOnly)
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Manifest = Get-Content (Join-Path $Here 'payload-manifest.json') -Raw | ConvertFrom-Json
if ($Manifest.schema -ne 1 -or $Manifest.source_sha -notmatch '^[0-9a-f]{40}$') { throw 'Invalid probe manifest' }
$ExpectedSourceSha = $Manifest.source_sha
if (Get-Process -Name Attila -ErrorAction SilentlyContinue) { throw 'Exit Attila before starting the probe' }
$ModData = Join-Path $env:APPDATA 'The Creative Assembly\Launcher\20190104-moddata.dat'
# Assign the JSON array directly: PowerShell 5.1 emits it as one pipeline object.
$mods = Get-Content -LiteralPath $ModData -Raw | ConvertFrom-Json
$scriptMods = @($mods | Where-Object { $_.uuid -eq '1-1212scripts.pack' })
if ($scriptMods.Count -ne 1 -or -not $scriptMods[0].active) { throw 'Exactly one active Workshop scripts pack is required' }
$Workshop = [string]$scriptMods[0].packfile
$normalized = $Workshop.Replace('/', '\')
$token = '\steamapps\workshop\content\325610\'
$idx = $normalized.ToLowerInvariant().IndexOf($token)
if ($idx -lt 0) { throw "Unrecognized Workshop scripts path: $Workshop" }
if (!(Test-Path -LiteralPath $Workshop -PathType Leaf)) { throw "Workshop scripts file does not exist: $Workshop" }
$GameRoot = Join-Path ($normalized.Substring(0, $idx + '\steamapps'.Length)) 'common\Total War Attila'
$Exe = Join-Path $GameRoot 'Attila.exe'
if (!(Test-Path $Exe)) { throw 'Attila.exe not found' }
$Rpfm = Join-Path $Here 'tools\rpfm_cli.exe'
$DllSource = Join-Path $Here 'payload\twdll.dll'
function Hash($Path) { (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
if ((Hash $DllSource) -ne $Manifest.dll_sha256 -or (Hash $Rpfm) -ne $Manifest.rpfm_sha256) { throw 'Probe binary hash mismatch' }
$PatchRoot = Join-Path $Here 'payload\patch-src'
if (@(Get-ChildItem $PatchRoot -Recurse -File).Count -ne @($Manifest.files).Count) { throw 'Unexpected files in patch payload' }
foreach ($entry in $Manifest.files) {
    if ($entry.path -notmatch '^campaigns/main_attila/[A-Za-z0-9_/]+\.lua$') { throw 'Invalid payload path' }
    if ((Hash (Join-Path $PatchRoot $entry.path)) -ne $entry.sha256) { throw "Payload hash mismatch: $($entry.path)" }
}
# Refuse previous probe contamination rather than accepting ambiguous evidence.
$Data = Join-Path $GameRoot 'data'
$oldProbes = @(Get-ChildItem $Data -Filter '*twdll*probe*.pack')
if ($oldProbes.Count -gt 0 -or (Test-Path (Join-Path $Data 'mk1212_pr45_runtime_scripts.pack'))) {
    throw 'Previous probe packs remain in data; remove them before this isolated test'
}
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$Backup = Join-Path $Here ('backup-' + $Stamp)
$Evidence = Join-Path $Here ('evidence-' + $Stamp)
New-Item -ItemType Directory -Path $Backup,$Evidence | Out-Null
$Patched = Join-Path $Backup 'patched.pack'
$Original = Join-Path $Backup 'original.pack'
Copy-Item $Workshop $Original
Copy-Item $Workshop $Patched
# Complete require closure, not only the two changed PR45 files.
& $Rpfm --game attila pack add --pack-path $Patched -F ($PatchRoot + ';')
if ($LASTEXITCODE -ne 0) { throw 'RPFM failed before installation; game files are unchanged' }
$Verified = Join-Path $Backup 'verified-payload'
New-Item -ItemType Directory -Path $Verified | Out-Null
& $Rpfm --game attila pack extract --pack-path $Patched -F ("campaigns/main_attila/common;" + $Verified)
if ($LASTEXITCODE -ne 0) { throw 'RPFM readback failed before installation' }
foreach ($entry in $Manifest.files) {
    if ((Hash (Join-Path $Verified $entry.path)) -ne $entry.sha256) { throw "Patched pack readback mismatch: $($entry.path)" }
}
$OriginalHash = Hash $Original
$PatchedHash = Hash $Patched
$NativeLog = Join-Path $GameRoot 'twdll.log'
$DebugLog = Join-Path $GameRoot 'MK1212_mp_debug.log'
$Trace = Join-Path $GameRoot 'PR45_RUNTIME_TRACE.txt'
$Dll = Join-Path $GameRoot 'twdll.dll'
$DllAttila = Join-Path $GameRoot 'twdll_attila.dll'
$Managed = @($Dll,$DllAttila,$NativeLog,$DebugLog,$Trace)
$States = @()
foreach ($path in $Managed) {
    $exists = Test-Path $path
    $state = @{ path=$path; existed=$exists; attributes=$null }
    if ($exists) {
        $state.attributes = (Get-Item $path).Attributes
        Copy-Item $path (Join-Path $Backup ([IO.Path]::GetFileName($path)))
    }
    $States += $state
}
$WorkshopAttributes = (Get-Item $Workshop).Attributes
$Installed = $false
$RunError = $null
$RestoreErrors = @()
$Result = [ordered]@{ schema=1; source_sha=$ExpectedSourceSha; bootstrap_enter=$false; initializer_enter=$false; native_ready=$false; debug_ready=$false; pack_preserved=$false; rollback_ok=$false; run_error=$null }
try {
    if ((Hash $Workshop) -ne $OriginalHash) { throw 'Workshop pack changed during preparation' }
    $Installed = $true
    (Get-Item $Workshop).IsReadOnly = $false
    Copy-Item $Patched $Workshop -Force
    foreach ($path in $Managed) {
        if (Test-Path $path) { (Get-Item $path).IsReadOnly = $false; Remove-Item $path -Force }
    }
    Copy-Item $DllSource $Dll
    Copy-Item $DllSource $DllAttila
    $provenance = [ordered]@{
        schema=1; source_sha=$ExpectedSourceSha; started_at=(Get-Date).ToString('o')
        game_root=$GameRoot; workshop_scripts_pack=$Workshop
        workshop_scripts_original_sha256=$OriginalHash; workshop_scripts_patched_sha256=$PatchedHash
        attila_sha256=(Hash $Exe); empire_retail_sha256=(Hash (Join-Path $GameRoot 'empire.retail.dll'))
        twdll_sha256=(Hash $Dll); payload=$Manifest.files
    }
    $provenance | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $Evidence 'manifest.json')
    Copy-Item $ModData (Join-Path $Evidence 'moddata.used.json')
    Write-Host 'Start/load SINGLE PLAYER, reach the campaign map, wait 10 seconds, then exit normally.' -ForegroundColor Yellow
    if ($PrepareOnly) { throw 'Preparation-only rollback test' }
    Start-Process 'steam://rungameid/325610'
    $deadline = (Get-Date).AddSeconds($LaunchTimeoutSeconds)
    $proc = $null
    while (-not $proc) {
        $proc = Get-Process -Name Attila -ErrorAction SilentlyContinue | Select-Object -First 1
        if ((Get-Date) -gt $deadline -and -not $proc) { throw 'Attila launch timeout' }
        if (-not $proc) { Start-Sleep -Seconds 1 }
    }
    Wait-Process -Id $proc.Id
    $Result.pack_preserved = (Hash $Workshop) -eq $PatchedHash
} catch {
    $RunError = $_.Exception.Message
} finally {
    foreach ($path in @($NativeLog,$DebugLog,$Trace,(Join-Path $GameRoot 'MK1212_log.txt'))) {
        if (Test-Path $path) {
            try { Copy-Item $path (Join-Path $Evidence ([IO.Path]::GetFileName($path))) -Force } catch { $RunError = "Evidence copy failed: $_" }
        }
    }
    # Evaluate copies from this run before restoring old logs.
    $traceCopy = Join-Path $Evidence 'PR45_RUNTIME_TRACE.txt'
    if (Test-Path $traceCopy) {
        $txt = [string](Get-Content $traceCopy -Raw)
        $Result.bootstrap_enter = $txt.Contains("source_sha=$ExpectedSourceSha bootstrap_enter")
        $Result.initializer_enter = $txt.Contains("source_sha=$ExpectedSourceSha initializer_enter")
    }
    $nativeCopy = Join-Path $Evidence 'twdll.log'
    if (Test-Path $nativeCopy) { $Result.native_ready = ([string](Get-Content $nativeCopy -Raw)).Contains("[MKMP][RUNTIME] ready game=Attila twdll_sha=$ExpectedSourceSha") }
    $debugCopy = Join-Path $Evidence 'MK1212_mp_debug.log'
    if (Test-Path $debugCopy) {
        $Result.debug_ready = @((Get-Content $debugCopy) | Where-Object { $_.Contains('event=runtime') -and $_.Contains('available=true') -and $_.Contains('reason=ready') -and $_.Contains("twdll_sha=$ExpectedSourceSha") }).Count -gt 0
    }
    if ($Installed) {
        try {
            # Preserve a concurrent Workshop update instead of silently overwriting it.
            $current = Hash $Workshop
            if ($current -ne $OriginalHash -and $current -ne $PatchedHash) { throw 'Workshop changed externally; original backup retained' }
            Copy-Item $Original $Workshop -Force
            (Get-Item $Workshop).Attributes = $WorkshopAttributes
            if ((Hash $Workshop) -ne $OriginalHash) { throw 'Workshop restore hash mismatch' }
        } catch { $RestoreErrors += "Workshop: $_" }
        foreach ($state in $States) {
            try {
                if (Test-Path $state.path) { (Get-Item $state.path).IsReadOnly = $false; Remove-Item $state.path -Force }
                if ($state.existed) {
                    Copy-Item (Join-Path $Backup ([IO.Path]::GetFileName($state.path))) $state.path
                    (Get-Item $state.path).Attributes = $state.attributes
                }
            } catch { $RestoreErrors += "$($state.path): $_" }
        }
    }
    $Result.rollback_ok = $RestoreErrors.Count -eq 0
    $Result.run_error = $RunError
    $Result.restore_errors = $RestoreErrors
    $Result.pass = $Result.bootstrap_enter -and $Result.initializer_enter -and $Result.native_ready -and $Result.debug_ready -and $Result.pack_preserved -and $Result.rollback_ok -and -not $RunError
    $Result | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $Evidence 'result.json')
    $zip = Join-Path $Here ('MK1212-PR45-SP-EVIDENCE-' + $Stamp + '.zip')
    Compress-Archive -Path "$Evidence\*" -DestinationPath $zip
    Write-Host "Evidence: $zip"
    Write-Host "PASS: $($Result.pass); rollback: $($Result.rollback_ok)"
    if ($RestoreErrors.Count -gt 0) { Write-Warning "Restore errors: $RestoreErrors. Backups retained at $Backup" }
}
if (-not $Result.pass) { exit 1 }
