param([int]$LaunchTimeoutSeconds = 600, [switch]$PrepareOnly, [switch]$NoDll)
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Mode = if ($NoDll) { 'no-dll' } else { 'native' }
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
# Isolate leftover MK1212 test packs temporarily; retain verified backups.
$Data = Join-Path $GameRoot 'data'
$oldProbes = @(Get-ChildItem -LiteralPath $Data -File | Where-Object {
    $_.Name -like '*mk1212*twdll*probe*.pack' -or
    $_.Name -eq 'mk1212_pr45_runtime_scripts.pack'
})
$Stamp = $Mode + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$RunId = [guid]::NewGuid().ToString('N')
$Backup = Join-Path $Here ('backup-' + $Stamp)
$Evidence = Join-Path $Here ('evidence-' + $Stamp)
New-Item -ItemType Directory -Path $Backup,$Evidence | Out-Null
$Patched = Join-Path $Backup 'patched.pack'
$Original = Join-Path $Backup 'original.pack'
Copy-Item $Workshop $Original
Copy-Item $Workshop $Patched
# Build an overlay from the user's Workshop bootstrap, never the repo gameplay modules.
$Baseline = Join-Path $Backup 'workshop-lua'
$Overlay = Join-Path $Backup 'minimal-overlay'
$Verified = Join-Path $Backup 'verified-payload'
New-Item -ItemType Directory -Path $Baseline,$Overlay,$Verified | Out-Null
foreach ($folder in @('campaigns','lua_scripts','script')) {
    & $Rpfm --game attila pack extract --pack-path $Original -F ($folder + ';' + $Baseline)
    if ($LASTEXITCODE -ne 0) { throw "Cannot extract original scripts: $folder; game unchanged" }
}
$MainRelative = 'campaigns/main_attila/common/main.lua'
$MainPath = Join-Path $Baseline $MainRelative
$Utf8 = New-Object System.Text.UTF8Encoding($false, $true)
$Main = [IO.File]::ReadAllText($MainPath, $Utf8)
if ([regex]::Matches($Main, 'function\s+Common_Initializer\s*\(\s*\)').Count -ne 1 -or
    $Main -match 'MKMP_Runtime|MKMP_Debug|Probe_Trace') {
    throw 'Unsupported or already instrumented Workshop bootstrap; game unchanged'
}
# Prefix/suffix leave every byte of the original decoded Lua body intact.
$Prefix = @'
local probe_lines = 0;
local function Probe_Trace(message)
    if probe_lines >= 128 then return; end
    probe_lines = probe_lines + 1;
    pcall(function()
        if not io or not io.open then return; end
        local f = io.open("PR45_RUNTIME_TRACE.txt", "ab");
        if not f then return; end
        local size = f:seek("end");
        local safe = string.sub(tostring(message),1,512):gsub("[\r\n\t]", " "):gsub("%c", "?");
        local line = "schema=2 source_sha=SOURCE_SHA run_id=RUN_ID "..safe.."\n";
        if size and size + #line <= 65536 then f:write(line); end
        f:close();
    end);
end
Probe_Trace("bootstrap_enter");
-- Diagnostic-only early load experiment. Preserve gameplay on every failure.
Probe_Trace("early_native_begin");
local early_ok, early_err = pcall(function()
    require("common/mkmp_runtime");
    MKMP_Runtime_Initialize();
end);
Probe_Trace("early_native_result state="..(early_ok and "complete" or "failed"));
if not early_ok then Probe_Trace("early_native_error text="..tostring(early_err)); end
'@
$Suffix = @'
Probe_Trace("bootstrap_complete");
local probe_world_samples = 0;
local probe_listener_registered = false;
local probe_init_seq = 0;
local function Probe_World(phase)
    if probe_world_samples >= 5 then return; end
    probe_world_samples = probe_world_samples + 1;
    local ok, err = pcall(function()
        if type(MKMP_Runtime_Diagnostic_Parity) == "function" then
            local ok_parity, parity = pcall(MKMP_Runtime_Diagnostic_Parity);
            if ok_parity and type(parity) == "table" then
                Probe_Trace("faction_parity phase="..phase.." lua_state="..tostring(parity.lua_state).." lua_count="..tostring(parity.lua_count).." native_state="..tostring(parity.native_state).." native_count="..tostring(parity.native_count).." result="..tostring(parity.parity));
            else
                Probe_Trace("faction_parity phase="..phase.." result=query_failed");
            end
        else
            Probe_Trace("faction_parity phase="..phase.." result=capability_missing");
        end
        local runtime = MKMP_RUNTIME;
        local world = runtime and runtime.module and runtime.module.world;
        if not world then Probe_Trace("world phase="..phase.." state=module_unavailable"); return; end
        if type(world.GetMemoryAddress) ~= "function" or type(world.GetFactionCount) ~= "function" then
            Probe_Trace("world phase="..phase.." state=capability_missing"); return;
        end
        if type(world.GetCaptureStatus) == "function" then
            local ok_capture, capture = pcall(world.GetCaptureStatus);
            if ok_capture and type(capture) == "table" then
                Probe_Trace("world_capture phase="..phase.." generation="..tostring(capture.generation).." hits="..tostring(capture.constructor_hits).." clears="..tostring(capture.clear_count).." enabled="..tostring(capture.hook_enabled).." cached="..tostring(capture.world_cached));
            else
                Probe_Trace("world_capture phase="..phase.." state=query_failed");
            end
        else
            Probe_Trace("world_capture phase="..phase.." state=capability_missing");
        end
        -- Never log or use raw addresses as gameplay authority.
        local present = world.GetMemoryAddress() ~= nil;
        local count = world.GetFactionCount();
        local state = "count_unavailable";
        if not present then state = "world_not_captured";
        elseif type(count) == "number" and count >= 0 and count == math.floor(count) then state = "ready"; end
        Probe_Trace("world phase="..phase.." state="..state.." factions="..tostring(count));
    end);
    if not ok then Probe_Trace("world phase="..phase.." state=query_failed error="..tostring(err)); end
end
local Probe_Original_Initializer = Common_Initializer;
function Common_Initializer(...)
    probe_init_seq = probe_init_seq + 1;
    Probe_Trace("initializer_enter seq="..probe_init_seq);
    Probe_Original_Initializer(...);
    Probe_Trace("gameplay_initializer_complete seq="..probe_init_seq);
    local ok, err = pcall(function()
        require("common/mkmp_debug");
        require("common/mkmp_runtime");
        MKMP_Debug_Initialize();
        -- Adapter may already be initialized before the Workshop body.
        -- Re-emit the runtime identity after the debug logger becomes available.
        local early_status = MKMP_Runtime_Status();
        if MKMP_Debug_Log then
            pcall(MKMP_Debug_Log, "runtime", {
                available = early_status.available,
                reason = early_status.reason,
                twdll_sha = early_status.twdll_sha,
                load_candidate = early_status.load_candidate,
                message = "early_bootstrap_status"
            });
        end
        Probe_Trace("native_initialize_begin");
        MKMP_Runtime_Initialize();
        local status = MKMP_Runtime_Status();
        local reason = tostring(status.reason);
        local reason_code = "unknown";
        if status.available == true and reason == "ready" then reason_code = "ready";
        elseif status.available == false and reason:sub(1, 15) == "dll_unavailable" then reason_code = "dll_unavailable"; end
        Probe_Trace("runtime_status seq="..probe_init_seq.." available="..tostring(status.available).." reason_code="..reason_code.." luaopen_calls="..tostring(status.luaopen_calls));
        if reason_code ~= "ready" then Probe_Trace("runtime_error_detail text="..reason); end
        -- Separate read-only V1 turn observations from bounded WORLD samples.
        local turn_samples = 0;
        local function Probe_Turn(phase, context)
            if turn_samples >= 64 then return; end
            turn_samples = turn_samples + 1;
            local ok_turn, observation = pcall(function()
                if type(MKMP_Runtime_Get_Turn_Observation_Event_V1) ~= "function" then return nil; end
                return MKMP_Runtime_Get_Turn_Observation_Event_V1(phase);
            end);
            if not ok_turn or type(observation) ~= "table" then
                Probe_Trace("turn_v1 event="..phase.." status=unavailable reason=query_failed");
                return;
            end
            local faction_name = "unknown";
            if context then
                pcall(function()
                    if type(context.faction) == "function" then
                        local faction = context:faction();
                        if faction and type(faction.name) == "function" then
                            local name = faction:name();
                            if type(name) == "string" and name:match("^[%w_]+$") then faction_name = name; end
                        end
                    end
                end);
            end
            Probe_Trace("turn_v1 event="..phase..
                " status="..(observation.available and "partial" or "unavailable")..
                " turn="..tostring(observation.turn_number)..
                " multiplayer="..tostring(observation.multiplayer)..
                " event_faction="..faction_name..
                " active_faction="..tostring(observation.active_faction)..
                " local_faction="..tostring(observation.local_faction)..
                " phase="..tostring(observation.phase)..
                " reason="..tostring(observation.reason));
        end
        Probe_Turn("initializer", nil);
        Probe_World("initializer");
        if not probe_listener_registered then
            Probe_Trace("listener_register_attempt");
            local receiver = cm;
            if not receiver or type(receiver.add_listener) ~= "function" then
                Probe_Trace("listener_register_result state=receiver_missing");
            else
                local registered, registration_error = pcall(function()
                    receiver:add_listener("PR45_World_Probe", "FactionTurnStart", true, function(context)
                        if turn_samples >= 32 then return; end
                        Probe_Trace("listener_callback_enter phase=faction_turn_start");
                        Probe_Turn("faction_turn_start", context);
                        Probe_World("faction_turn_start");
                        if turn_samples >= 32 then
                            local removed, remove_error = pcall(function() receiver:remove_listener("PR45_World_Probe"); end);
                            Probe_Trace("listener_remove_result state="..(removed and "ok" or "failed"));
                            if not removed then Probe_Trace("listener_remove_detail text="..tostring(remove_error)); end
                        end
                    end, true);
                end);
                if registered then
                    probe_listener_registered = true;
                    Probe_Trace("listener_register_result state=registered");
                else
                    Probe_Trace("listener_register_result state=failed error="..tostring(registration_error));
                end
            end
        end
    end);
    if not ok then Probe_Trace("diagnostics_failed error="..tostring(err)); end
end
'@
$OverlayCommon = Join-Path $Overlay 'campaigns/main_attila/common'
New-Item -ItemType Directory -Path $OverlayCommon -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $Overlay $MainRelative),
    $Prefix.Replace('SOURCE_SHA', $ExpectedSourceSha).Replace('RUN_ID', $RunId) + "`n" + $Main + "`n" + $Suffix + "`n", $Utf8)
$Allowed = @($MainRelative,'campaigns/main_attila/common/mkmp_debug.lua','campaigns/main_attila/common/mkmp_runtime.lua')
foreach ($relative in $Allowed[1..2]) {
    if (Test-Path (Join-Path $Baseline $relative)) { throw "Workshop already contains $relative; game unchanged" }
    Copy-Item -LiteralPath (Join-Path $PatchRoot $relative) -Destination (Join-Path $Overlay $relative)
}
$Applied = @($Allowed | ForEach-Object { @{ path=$_; sha256=(Hash (Join-Path $Overlay $_)) } })
& $Rpfm --game attila pack add --pack-path $Patched -F ($Overlay + ';')
if ($LASTEXITCODE -ne 0) { throw 'RPFM failed before installation; game files unchanged' }
foreach ($folder in @('campaigns','lua_scripts','script')) {
    & $Rpfm --game attila pack extract --pack-path $Patched -F ($folder + ';' + $Verified)
    if ($LASTEXITCODE -ne 0) { throw "RPFM readback failed: $folder" }
}
foreach ($entry in $Applied) {
    if ((Hash (Join-Path $Verified $entry.path)) -ne $entry.sha256) { throw "Overlay readback mismatch: $($entry.path)" }
}
$Preserved = 0
foreach ($file in Get-ChildItem $Baseline -Recurse -File -Filter '*.lua') {
    $relative = $file.FullName.Substring($Baseline.Length + 1).Replace('\','/')
    if ($relative -eq $MainRelative) { continue }
    if ((Hash (Join-Path $Verified $relative)) -ne (Hash $file.FullName)) { throw "Unrelated Workshop Lua changed: $relative" }
    $Preserved++
}
@{ schema=1; mode='workshop-preserving'; original_main_sha256=(Hash $MainPath); applied=$Applied; preserved_lua_count=$Preserved; harness_sha256=(Hash $MyInvocation.MyCommand.Path) } |
    ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $Evidence 'overlay.json')
$OriginalHash = Hash $Original
$PatchedHash = Hash $Patched
$NativeLog = Join-Path $GameRoot 'twdll.log'
$DebugLog = Join-Path $GameRoot 'MK1212_mp_debug.log'
$Trace = Join-Path $GameRoot 'PR45_RUNTIME_TRACE.txt'
$Dll = Join-Path $GameRoot 'twdll.dll'
$DllAttila = Join-Path $GameRoot 'twdll_attila.dll'
$DllBare = Join-Path $GameRoot 'twdll'
$Managed = @($Dll,$DllAttila,$DllBare,$NativeLog,$DebugLog,$Trace)
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
$ProbeBackup = Join-Path $Backup 'previous-probes'
New-Item -ItemType Directory -Path $ProbeBackup | Out-Null
$ProbeStates = @()
foreach ($probe in $oldProbes) {
    $saved = Join-Path $ProbeBackup $probe.Name
    $sha = Hash $probe.FullName
    Copy-Item -LiteralPath $probe.FullName -Destination $saved
    if ((Hash $saved) -ne $sha) { throw "Old probe backup hash mismatch: $($probe.Name)" }
    $ProbeStates += @{ path=$probe.FullName; backup=$saved; sha256=$sha; attributes=$probe.Attributes; touched=$false }
}
@($ProbeStates | ForEach-Object { @{ path=$_.path; backup=$_.backup; sha256=$_.sha256 } }) |
    ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 (Join-Path $Evidence 'previous-probes.json')
$WorkshopAttributes = (Get-Item $Workshop).Attributes
$Installed = $false
$RunError = $null
$RestoreErrors = @()
$Result = [ordered]@{ schema=1; mode=$Mode; source_sha=$ExpectedSourceSha; run_id=$RunId; fallback_ready=$false; bootstrap_enter=$false; initializer_enter=$false; native_ready=$false; debug_ready=$false; pack_preserved=$false; rollback_ok=$false; run_error=$null }
try {
    if ((Hash $Workshop) -ne $OriginalHash) { throw 'Workshop pack changed during preparation' }
    foreach ($state in $ProbeStates) {
        if ((Hash $state.path) -ne $state.sha256) { throw "Old probe changed before isolation: $($state.path)" }
        $state.touched = $true
        (Get-Item -LiteralPath $state.path).IsReadOnly = $false
        Remove-Item -LiteralPath $state.path -Force
        if (Test-Path -LiteralPath $state.path) { throw "Old probe remains active: $($state.path)" }
    }
    Write-Host "Temporarily isolated $($ProbeStates.Count) previous probe pack(s). Backups: $ProbeBackup"
    $Installed = $true
    (Get-Item $Workshop).IsReadOnly = $false
    Copy-Item $Patched $Workshop -Force
    foreach ($path in $Managed) {
        if (Test-Path $path) { (Get-Item $path).IsReadOnly = $false; Remove-Item $path -Force }
    }
    if (-not $NoDll) {
        Copy-Item $DllSource $Dll
        Copy-Item $DllSource $DllAttila
    }
    $InstalledDllHash = if ($NoDll) { $null } else { Hash $Dll }
    $DllFilesAbsent = -not ((Test-Path $Dll) -or (Test-Path $DllAttila) -or (Test-Path $DllBare))
    $provenance = [ordered]@{
        schema=1; source_sha=$ExpectedSourceSha; run_id=$RunId; started_at=(Get-Date).ToString('o')
        game_root=$GameRoot; workshop_scripts_pack=$Workshop
        workshop_scripts_original_sha256=$OriginalHash; workshop_scripts_patched_sha256=$PatchedHash
        attila_sha256=(Hash $Exe); empire_retail_sha256=(Hash (Join-Path $GameRoot 'empire.retail.dll'))
        mode=$Mode; dll_files_absent=$DllFilesAbsent; twdll_sha256=$InstalledDllHash; payload=$Applied; overlay_mode='workshop-preserving'; isolated_probe_count=$ProbeStates.Count
    }
    $provenance | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $Evidence 'manifest.json')
    Copy-Item $ModData (Join-Path $Evidence 'moddata.used.json')
    Write-Host "Probe mode: $Mode"
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
    # Never let an evidence/parser exception skip rollback.
    try {
    $traceCopy = Join-Path $Evidence 'PR45_RUNTIME_TRACE.txt'
    if (Test-Path $traceCopy) {
        $txt = [string](Get-Content -LiteralPath $traceCopy -Raw)
        $prefix = "schema=2 source_sha=$ExpectedSourceSha run_id=$RunId "
        $records = @($txt -split "[`r`n]+" | Where-Object { $_.Length -gt 0 })
        $prefixValid = @($records | Where-Object { -not $_.StartsWith($prefix) }).Count -eq 0
        $events = @($records | Where-Object { $_.StartsWith($prefix) } | ForEach-Object { $_.Substring($prefix.Length) })
        $Result.bootstrap_enter = @($events | Where-Object { $_ -ceq 'bootstrap_enter' }).Count -gt 0
        $Result.trace_status_count = 0
        $Result.trace_invalid_status_count = 0
        $Result.fallback_ready = $false
        $Result.initializer_enter = $false
        $Result.gameplay_initializer_complete = $false
        $sequence = 0
        $bootstraps = 0
        $totalSegments = 0
        $sessionHasInitializer = $false
        $pending = $false
        $seenStatus = $false
        $segmentGameplayComplete = $false
        $validFallback = $true
        $validNative = $true
        foreach ($ev in $events) {
            if ($ev -ceq 'bootstrap_enter') {
                if ($pending -or ($bootstraps -gt 0 -and -not $sessionHasInitializer)) {
                    $validFallback = $false; $validNative = $false
                }
                $bootstraps++
                $sessionHasInitializer = $false
                $sequence = 0
                $seenStatus = $false
                $segmentGameplayComplete = $false
            } elseif ($ev -match '^initializer_enter seq=([0-9]+)$') {
                if ($pending -or [int]$Matches[1] -ne ($sequence + 1)) { $validFallback = $false; $validNative = $false }
                $sequence = [int]$Matches[1]
                $totalSegments++
                $sessionHasInitializer = $true
                $pending = $true
                $seenStatus = $false
                $segmentGameplayComplete = $false
                $Result.initializer_enter = $true
            } elseif ($ev -match '^gameplay_initializer_complete seq=([0-9]+)$') {
                if (-not $pending -or [int]$Matches[1] -ne $sequence) { $validFallback = $false; $validNative = $false }
                else { $Result.gameplay_initializer_complete = $true; $segmentGameplayComplete = $true }
            } elseif ($ev -match '^runtime_status(?: |$)') {
                $Result.trace_status_count++
                if ($ev -cnotmatch '^runtime_status seq=([0-9]+) available=(true|false) reason_code=([a-z_]+) luaopen_calls=([0-9]+)$') {
                    $Result.trace_invalid_status_count++
                    $validFallback = $false
                    $validNative = $false
                } else {
                    $seq = [int]$Matches[1]
                    $available = $Matches[2]
                    $reason = $Matches[3]
                    $calls = [int]$Matches[4]
                    if (-not $pending -or $seenStatus -or $seq -ne $sequence -or -not $segmentGameplayComplete) {
                        $validFallback = $false; $validNative = $false
                    }
                    if ($available -cne 'false' -or $reason -cne 'dll_unavailable' -or $calls -ne 0) { $validFallback = $false }
                    if ($available -cne 'true' -or $reason -cne 'ready' -or $calls -ne 1) { $validNative = $false }
                    $pending = $false
                    $seenStatus = $true
                }
            } elseif ($ev -match '^diagnostics_failed(?: |$)') {
                $validFallback = $false; $validNative = $false
            }
        }
        if ($pending -or -not $sessionHasInitializer -or $totalSegments -eq 0 -or $Result.trace_status_count -ne $totalSegments -or -not $prefixValid) {
            $validFallback = $false; $validNative = $false
        }
        $Result.fallback_ready = $validFallback -and $Result.bootstrap_enter
        $Result.trace_native_ready = $validNative -and $Result.bootstrap_enter
        $Result.trace_segments = $totalSegments
        $Result.trace_bootstraps = $bootstraps
        $Result.trace_prefix_valid = $prefixValid
    }
    $nativeCopy = Join-Path $Evidence 'twdll.log'
    if (Test-Path $nativeCopy) { $Result.native_ready = ([string](Get-Content $nativeCopy -Raw)).Contains("[MKMP][RUNTIME] ready game=Attila twdll_sha=$ExpectedSourceSha") }
    $debugCopy = Join-Path $Evidence 'MK1212_mp_debug.log'
    if (Test-Path $debugCopy) {
        $Result.debug_ready = @((Get-Content $debugCopy) | Where-Object { $_.Contains('event=runtime') -and $_.Contains('available=true') -and $_.Contains('reason=ready') -and $_.Contains("twdll_sha=$ExpectedSourceSha") }).Count -gt 0
    }
    } catch {
        $Result.evaluation_error = $_.Exception.Message
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
    # Restore isolated packs even if installation failed part-way through.
    foreach ($state in $ProbeStates) {
        if (-not $state.touched) { continue }
        try {
            if (Test-Path -LiteralPath $state.path) {
                if ((Hash $state.path) -ne $state.sha256) { throw 'Probe path changed externally; verified backup retained' }
            } else {
                Copy-Item -LiteralPath $state.backup -Destination $state.path
            }
            (Get-Item -LiteralPath $state.path).Attributes = $state.attributes
            if ((Hash $state.path) -ne $state.sha256) { throw 'Probe restore hash mismatch' }
        } catch { $RestoreErrors += "$($state.path): $_" }
    }
    $Result.isolated_probe_count = $ProbeStates.Count
    $Result.rollback_ok = $RestoreErrors.Count -eq 0
    $Result.run_error = $RunError
    $Result.restore_errors = $RestoreErrors
    $RuntimePass = $Result.native_ready -and $Result.debug_ready -and $Result.trace_native_ready
    if ($NoDll) { $RuntimePass = $DllFilesAbsent -and $Result.fallback_ready -and -not $Result.native_ready -and -not (Test-Path $nativeCopy) }
    $Result.pass = $Result.bootstrap_enter -and $Result.initializer_enter -and $Result.gameplay_initializer_complete -and $RuntimePass -and $Result.pack_preserved -and $Result.rollback_ok -and -not $RunError -and -not $Result.evaluation_error
    # Coverage is evidence accounting, NEVER a gameplay pass/fail gate.
    try {
        $coverage = [ordered]@{
            schema = 1
            source_sha = $ExpectedSourceSha
            mode = $Mode
            turn_v1_samples = 0
            turn_events = [ordered]@{ initializer = 0; faction_turn_start = 0 }
            available_turn_samples = 0
            resolved_event_factions = 0
            active_owner_proven = $false
            simultaneous_turns_proven = $false
            statuses = [ordered]@{
                runtime_bootstrap = 'NOT_OBSERVED'
                ai_turn_callback = 'NOT_OBSERVED'
                turn_number = 'NOT_OBSERVED'
                event_faction = 'NOT_OBSERVED'
                active_owner = 'UNKNOWN'
                save_load = 'NOT_OBSERVED'
                battle_return = 'NOT_OBSERVED'
                multiplayer_simultaneity = 'NOT_OBSERVED'
                rollback = 'NOT_OBSERVED'
            }
        }
        if ($Result.bootstrap_enter) { $coverage.statuses.runtime_bootstrap = 'OBSERVED' }
        if ($Result.rollback_ok) { $coverage.statuses.rollback = 'PASS' } else { $coverage.statuses.rollback = 'FAIL' }
        $traceCopy = Join-Path $Evidence 'PR45_RUNTIME_TRACE.txt'
        if (Test-Path -LiteralPath $traceCopy) {
            foreach ($line in @(Get-Content -LiteralPath $traceCopy)) {
                if ($line -match ' turn_v1 event=(initializer|faction_turn_start) status=(partial|unavailable) turn=([0-9]+|unknown) multiplayer=(true|false|unknown) event_faction=([A-Za-z0-9_]+) ') {
                    $eventName = $Matches[1]
                    $coverage.turn_v1_samples++
                    $coverage.turn_events[$eventName]++
                    if ($Matches[2] -eq 'partial') { $coverage.available_turn_samples++; $coverage.statuses.turn_number = 'OBSERVED' }
                    if ($Matches[5] -ne 'unknown') { $coverage.resolved_event_factions++; $coverage.statuses.event_faction = 'OBSERVED' }
                }
            }
        }
        if ($coverage.turn_events.faction_turn_start -gt 0) { $coverage.statuses.ai_turn_callback = 'OBSERVED_CALLBACK_ONLY' }
        $coverage | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $Evidence 'coverage.json')
    } catch {
        $Result.coverage_error = $_.Exception.Message
    }
    $Result | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $Evidence 'result.json')
    $zip = Join-Path $Here ('MK1212-PR45-SP-EVIDENCE-' + $Stamp + '.zip')
    Compress-Archive -Path "$Evidence\*" -DestinationPath $zip
    Write-Host "Evidence: $zip"
    Write-Host "PASS: $($Result.pass); rollback: $($Result.rollback_ok)"
    if ($RestoreErrors.Count -gt 0) { Write-Warning "Restore errors: $RestoreErrors. Backups retained at $Backup" }
}
if (-not $Result.pass) { exit 1 }
