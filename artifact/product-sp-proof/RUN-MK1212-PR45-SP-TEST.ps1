param(
    [string] $ExpectedSourceSha = "13ba7dc5965c43b252de88f7fd4cefe75f1f82b1"
)

$ErrorActionPreference = "Stop"

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Payload = Join-Path $Here "payload"
$Rpfm = Join-Path $Here "tools\rpfm_cli.exe"

$LauncherDir = Join-Path $env:APPDATA "The Creative Assembly\Launcher"
$ModData = Join-Path $LauncherDir "20190104-moddata.dat"
$LauncherLog = Join-Path $LauncherDir "launcher.log"

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Backup = Join-Path $Here ("backup-" + $Stamp)
$Evidence = Join-Path $Here ("evidence-" + $Stamp)
$Working = Join-Path $Here ("working-" + $Stamp)
New-Item -ItemType Directory -Force -Path $Backup, $Evidence, $Working | Out-Null

$BackupReady = $false
$runError = $null
$result = [ordered]@{
    source_sha = $ExpectedSourceSha
    native_ready = $false
    debug_ready = $false
    runtime_module_loaded = $false
    common_initializer_entered = $false
    absolute_runtime_ready = $false
    workshop_pack_preserved_during_launch = $false
    run_error = $null
}

$probeNames = @(
    "mk1212_twdll_sp_probe.pack",
    "zzz_mk1212_twdll_sp_probe_v2.pack",
    "zzz_mk1212_twdll_sp_probe_v3.pack",
    "000_mk1212_twdll_sp_probe_v4_movie.pack"
)

function Restore-MK1212Environment {
    if (-not $script:BackupReady) {
        return
    }

    Write-Host "Restoring Workshop scripts pack and local Attila files..." -ForegroundColor Cyan

    try {
        $savedWorkshop = Join-Path $Backup "1-1212scripts.pack.original"
        if ($WorkshopScripts -and (Test-Path $savedWorkshop)) {
            Copy-Item $savedWorkshop $WorkshopScripts -Force
        }

        foreach ($p in @($Twdll, $TwdllAttila, $NativeLog, $DebugLog)) {
            if ($p) {
                Remove-Item $p -Force -ErrorAction SilentlyContinue
            }
        }

        foreach ($name in @(
            "twdll.dll",
            "twdll_attila.dll",
            "twdll.log",
            "MK1212_mp_debug.log"
        )) {
            $saved = Join-Path $Backup $name
            if (Test-Path $saved) {
                Copy-Item $saved (Join-Path $GameRoot $name) -Force
            }
        }

        foreach ($name in $probeNames) {
            $saved = Join-Path $Backup $name
            if (Test-Path $saved) {
                Copy-Item $saved (Join-Path $Data $name) -Force
            }
        }
    } catch {
        Write-Warning ("Environment restore encountered an error: " + $_.Exception.Message)
    }
}

if (!(Test-Path $ModData)) {
    throw "CA Launcher mod data not found: $ModData"
}
if (!(Test-Path $Rpfm)) {
    throw "Bundled rpfm_cli.exe missing: $Rpfm"
}

# The CA Launcher file is a JSON array with uuid/packfile/order/active.
# Windows PowerShell 5.1 may preserve the top-level JSON array as a nested
# Object[] in pipeline contexts, so flatten it explicitly before filtering.
$parsedModData = Get-Content $ModData -Raw | ConvertFrom-Json
$mods = New-Object System.Collections.ArrayList

if ($parsedModData -is [System.Array]) {
    foreach ($entry in $parsedModData) {
        if ($entry -is [System.Array]) {
            foreach ($inner in $entry) {
                [void]$mods.Add($inner)
            }
        } else {
            [void]$mods.Add($entry)
        }
    }
} else {
    [void]$mods.Add($parsedModData)
}

$scriptCandidates = New-Object System.Collections.ArrayList

foreach ($m in $mods) {
    $uuid = [string]($m.uuid)
    $packfile = [string]($m.packfile)
    $normalizedPack = $packfile.Replace("\\", "/").ToLowerInvariant()

    if (
        $uuid -eq "1-1212scripts.pack" -or
        $normalizedPack.EndsWith("/1-1212scripts.pack")
    ) {
        [void]$scriptCandidates.Add($m)
    }
}

if ($scriptCandidates.Count -ne 1) {
    $sample = @(
        $mods |
            Select-Object -First 5 |
            ForEach-Object {
                "uuid=" + [string]($_.uuid) + "; packfile=" + [string]($_.packfile)
            }
    )

    throw (
        "Expected exactly one MK1212 scripts record, found " +
        $scriptCandidates.Count +
        ". Parsed records=" +
        $mods.Count +
        ". Sample: " +
        ($sample -join " || ")
    )
}

$scriptMod = $scriptCandidates[0]
$uuidScalar = [string]($scriptMod.uuid)
$orderScalar = [string]($scriptMod.order)
$activeScalar = [string]($scriptMod.active)
$WorkshopScripts = [string]($scriptMod.packfile)

if (
    $uuidScalar -ne "1-1212scripts.pack" -or
    $WorkshopScripts -match "\\.pack\\s+" -or
    $WorkshopScripts -match "\\s+[A-Za-z]:/"
) {
    throw (
        "Launcher scripts record did not normalize to scalar fields. " +
        "uuid=" + $uuidScalar +
        "; order=" + $orderScalar +
        "; active=" + $activeScalar +
        "; packfile=" + $WorkshopScripts
    )
}

if ([string]::IsNullOrWhiteSpace($WorkshopScripts)) {
    throw "MK1212 scripts record has an empty packfile field"
}
if (!(Test-Path $WorkshopScripts)) {
    throw "Workshop scripts pack not found: $WorkshopScripts"
}

$normalized = $WorkshopScripts.Replace("/", "\")
$token = "\steamapps\workshop\content\325610\"
$idx = $normalized.ToLowerInvariant().IndexOf($token)
if ($idx -lt 0) {
    throw "Cannot derive Steam library from Workshop path: $normalized"
}

$steamApps = $normalized.Substring(0, $idx + "\steamapps".Length)
$GameRoot = Join-Path $steamApps "common\Total War Attila"
$Data = Join-Path $GameRoot "data"
$Exe = Join-Path $GameRoot "Attila.exe"
$EmpireRetail = Join-Path $GameRoot "empire.retail.dll"

$Twdll = Join-Path $GameRoot "twdll.dll"
$TwdllAttila = Join-Path $GameRoot "twdll_attila.dll"
$NativeLog = Join-Path $GameRoot "twdll.log"
$DebugLog = Join-Path $GameRoot "MK1212_mp_debug.log"
$PatchedPack = Join-Path $Working "1-1212scripts.pack.patched"

if (!(Test-Path $Exe)) {
    throw "Attila.exe not found: $Exe"
}

Write-Host "=== MK1212 PR45 PRODUCT SP PROOF V4 ===" -ForegroundColor Cyan
Write-Host "Game root: $GameRoot"
Write-Host "Active Workshop scripts pack: $WorkshopScripts"
Write-Host "Launcher order: $($scriptMod.order); active: $($scriptMod.active)"
Write-Host "Exact source: $ExpectedSourceSha"
Write-Host ""

# Back up every file that this harness may mutate.
Copy-Item $WorkshopScripts (Join-Path $Backup "1-1212scripts.pack.original") -Force

foreach ($p in @($Twdll, $TwdllAttila, $NativeLog, $DebugLog)) {
    if (Test-Path $p) {
        Copy-Item $p (Join-Path $Backup ([IO.Path]::GetFileName($p))) -Force
    }
}

foreach ($name in $probeNames) {
    $p = Join-Path $Data $name
    if (Test-Path $p) {
        Copy-Item $p (Join-Path $Backup $name) -Force
    }
}

$BackupReady = $true

try {
    # Remove stale external probes only for this run. The launcher config is untouched.
    foreach ($name in $probeNames) {
        Remove-Item (Join-Path $Data $name) -Force -ErrorAction SilentlyContinue
    }

    # Clone the exact active Workshop scripts pack and inject absolute proof traces
    # into the two PR45 Lua files before replacing them. This makes evidence
    # independent of Attila's process working directory.
    $RuntimePatch = Join-Path $Working "runtime-patch"
    Copy-Item (Join-Path $Payload "patch-src") $RuntimePatch -Recurse -Force

    $tracePath = (Join-Path $Evidence "PR45_RUNTIME_TRACE.txt").Replace("\", "/")

    $mainPath = Join-Path $RuntimePatch "campaigns\main_attila\common\main.lua"
    $mainText = Get-Content $mainPath -Raw
    $mainPattern = 'function Common_Initializer\(\)\r?\n'
    $mainInjection = @"
function Common_Initializer()
	pcall(function()
		local proof = io.open([[$tracePath]], "a");
		if proof then
			proof:write("COMMON_INITIALIZER_ENTER\\n");
			proof:flush();
			proof:close();
		end
	end);
"@
    $mainText = [regex]::Replace($mainText, $mainPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $mainInjection }, 1)
    if (-not $mainText.Contains("COMMON_INITIALIZER_ENTER")) {
        throw "Failed to inject absolute Common_Initializer proof marker"
    }
    [System.IO.File]::WriteAllText($mainPath, $mainText, (New-Object System.Text.UTF8Encoding($false)))

    $runtimePath = Join-Path $RuntimePatch "campaigns\main_attila\common\mkmp_runtime.lua"
    $runtimeText = Get-Content $runtimePath -Raw
    $candidateMarker = 'local MKMP_RUNTIME_LOAD_CANDIDATES = {'
    $candidateStart = $runtimeText.IndexOf($candidateMarker)
    if ($candidateStart -lt 0) { throw "Runtime candidate marker not found" }
    $candidateEnd = $runtimeText.IndexOf('};', $candidateStart)
    if ($candidateEnd -lt 0) { throw "Runtime candidate block terminator not found" }
    $candidateEnd += 2

    $proofHelper = @"

local function MKMP_Runtime_Absolute_Proof(message)
	pcall(function()
		local proof = io.open([[$tracePath]], "a");
		if proof then
			proof:write(tostring(message));
			proof:write("\\n");
			proof:flush();
			proof:close();
		end
	end);
end

MKMP_Runtime_Absolute_Proof("RUNTIME_MODULE_LOADED");
"@
    $runtimeText = $runtimeText.Insert($candidateEnd, $proofHelper)

    $logPattern = 'local function MKMP_Runtime_Log_Internal\(message\)\r?\n'
    $logInjection = @"
local function MKMP_Runtime_Log_Internal(message)
	MKMP_Runtime_Absolute_Proof("RUNTIME:"..tostring(message));
"@
    $runtimeText = [regex]::Replace($runtimeText, $logPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $logInjection }, 1)

    if (-not $runtimeText.Contains("RUNTIME_MODULE_LOADED")) { throw "Failed to inject runtime module proof marker" }
    if (-not $runtimeText.Contains('MKMP_Runtime_Absolute_Proof("RUNTIME:"')) { throw "Failed to inject runtime log proof marker" }
    [System.IO.File]::WriteAllText($runtimePath, $runtimeText, (New-Object System.Text.UTF8Encoding($false)))

    Copy-Item $WorkshopScripts $PatchedPack -Force
    & $Rpfm --game attila pack add --pack-path $PatchedPack -F ($RuntimePatch + ";")
    if ($LASTEXITCODE -ne 0) {
        throw "RPFM failed to patch the cloned MK1212 scripts pack"
    }

    $patchedBytes = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($PatchedPack))
    if (-not $patchedBytes.Contains("MKMP_RUNTIME_EXPECTED_GAME")) {
        throw "Patched Workshop clone does not contain the PR45 runtime marker"
    }
    if (-not $patchedBytes.Contains("MKMP_Runtime_Initialize")) {
        throw "Patched Workshop clone does not contain the PR45 bootstrap marker"
    }
    if (-not $patchedBytes.Contains("RUNTIME_MODULE_LOADED")) {
        throw "Patched Workshop clone does not contain the absolute runtime proof marker"
    }
    if (-not $patchedBytes.Contains("COMMON_INITIALIZER_ENTER")) {
        throw "Patched Workshop clone does not contain the absolute common initializer proof marker"
    }

    $OriginalWorkshopSha = (Get-FileHash $WorkshopScripts -Algorithm SHA256).Hash.ToLower()
    $PatchedWorkshopSha = (Get-FileHash $PatchedPack -Algorithm SHA256).Hash.ToLower()

    # Temporarily replace the exact Workshop scripts payload that the launcher already has active.
    Copy-Item $PatchedPack $WorkshopScripts -Force

    $installedWorkshopSha = (Get-FileHash $WorkshopScripts -Algorithm SHA256).Hash.ToLower()
    if ($installedWorkshopSha -ne $PatchedWorkshopSha) {
        throw "Failed to install patched Workshop scripts pack byte-for-byte"
    }

    # Install exact native DLL built from the same PR head.
    Copy-Item (Join-Path $Payload "twdll.dll") $Twdll -Force
    Copy-Item (Join-Path $Payload "twdll_attila.dll") $TwdllAttila -Force

    # Fresh proof must not append to old runtime evidence.
    Remove-Item $NativeLog, $DebugLog -Force -ErrorAction SilentlyContinue

    $manifest = [ordered]@{
        source_sha = $ExpectedSourceSha
        started_at = (Get-Date).ToString("o")
        game_root = $GameRoot
        launcher_scripts_uuid = [string]$scriptMod.uuid
        launcher_scripts_order = $scriptMod.order
        launcher_scripts_active = $scriptMod.active
        workshop_scripts_pack = $WorkshopScripts
        workshop_scripts_original_sha256 = $OriginalWorkshopSha
        workshop_scripts_patched_sha256 = $PatchedWorkshopSha
        attila_sha256 = (Get-FileHash $Exe -Algorithm SHA256).Hash.ToLower()
        empire_retail_sha256 = if (Test-Path $EmpireRetail) {
            (Get-FileHash $EmpireRetail -Algorithm SHA256).Hash.ToLower()
        } else {
            $null
        }
        twdll_sha256 = (Get-FileHash $Twdll -Algorithm SHA256).Hash.ToLower()
    }
    $manifest | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $Evidence "manifest.json")

    Write-Host "Workshop pack replaced temporarily:" -ForegroundColor Yellow
    Write-Host "  original: $OriginalWorkshopSha"
    Write-Host "  patched : $PatchedWorkshopSha"
    Write-Host ""
    Write-Host "Opening Steam / CA Launcher..." -ForegroundColor Yellow
    Write-Host "Click PLAY. In MK1212 start/load SINGLE PLAYER, reach the campaign map, wait ~10 seconds, then exit Attila normally." -ForegroundColor Yellow

    Start-Process "steam://rungameid/325610"

    $deadline = (Get-Date).AddMinutes(10)
    $proc = $null

    while (-not $proc) {
        $proc = Get-Process -Name "Attila" -ErrorAction SilentlyContinue |
            Sort-Object StartTime -Descending |
            Select-Object -First 1

        if ($proc) {
            break
        }

        if ((Get-Date) -gt $deadline) {
            throw "Timed out waiting 10 minutes for Attila.exe. Close the launcher and rerun."
        }

        Start-Sleep -Seconds 1
    }

    # Detect Steam/launcher rewriting the Workshop file before the game test.
    $launchWorkshopSha = (Get-FileHash $WorkshopScripts -Algorithm SHA256).Hash.ToLower()
    $result.workshop_pack_preserved_during_launch = ($launchWorkshopSha -eq $PatchedWorkshopSha)

    if (-not $result.workshop_pack_preserved_during_launch) {
        throw (
            "Steam/launcher rewrote 1-1212scripts.pack before runtime proof. " +
            "Expected patched SHA $PatchedWorkshopSha, got $launchWorkshopSha"
        )
    }

    Write-Host "Detected Attila PID $($proc.Id); patched Workshop SHA still present. Waiting for game exit..." -ForegroundColor Cyan
    Wait-Process -Id $proc.Id
    Start-Sleep -Seconds 3
} catch {
    $runError = $_.Exception.Message
    Write-Warning ("Product runtime run did not complete cleanly: " + $runError)
} finally {
    # Capture proof before restoring original files.
    try {
        if (Test-Path $NativeLog) {
            Copy-Item $NativeLog (Join-Path $Evidence "twdll.log") -Force
        }

        if (Test-Path $DebugLog) {
            Copy-Item $DebugLog (Join-Path $Evidence "MK1212_mp_debug.log") -Force
        }

        if (Test-Path $LauncherLog) {
            Copy-Item $LauncherLog (Join-Path $Evidence "launcher.log") -Force -ErrorAction SilentlyContinue
        }

        foreach ($name in @("MK1212_log.txt", "MK1212_config.txt")) {
            $p = Join-Path $GameRoot $name
            if (Test-Path $p) {
                Copy-Item $p (Join-Path $Evidence $name) -Force
            }
        }

        if (Test-Path $NativeLog) {
            $txt = Get-Content $NativeLog -Raw
            $result.native_ready =
                $txt.Contains("[MKMP][RUNTIME] ready game=Attila twdll_sha=" + $ExpectedSourceSha)
        }

        if (Test-Path $DebugLog) {
            $dbg = Get-Content $DebugLog -Raw
            $result.debug_ready =
                $dbg.Contains("event=runtime") -and
                $dbg.Contains("available=true") -and
                $dbg.Contains("reason=ready") -and
                $dbg.Contains("twdll_sha=" + $ExpectedSourceSha)
        }

        $traceFile = Join-Path $Evidence "PR45_RUNTIME_TRACE.txt"
        if (Test-Path $traceFile) {
            $trace = Get-Content $traceFile -Raw
            $result.runtime_module_loaded = $trace.Contains("RUNTIME_MODULE_LOADED")
            $result.common_initializer_entered = $trace.Contains("COMMON_INITIALIZER_ENTER")
            $result.absolute_runtime_ready =
                $trace.Contains("RUNTIME:ready game=Attila twdll_sha=" + $ExpectedSourceSha)
        }

        $result.run_error = $runError
        $result | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $Evidence "result.json")
    } catch {
        Write-Warning ("Evidence capture encountered an error: " + $_.Exception.Message)
    }

    Restore-MK1212Environment

    try {
        $zip = Join-Path $Here ("MK1212-PR45-SP-EVIDENCE-" + $Stamp + ".zip")
        Compress-Archive -Path "$Evidence\*" -DestinationPath $zip -Force

        Write-Host ""
        if (
            $result.absolute_runtime_ready -and
            $result.runtime_module_loaded -and
            $result.common_initializer_entered -and
            $result.workshop_pack_preserved_during_launch
        ) {
            Write-Host "PRODUCT RUNTIME RESULT: PASS" -ForegroundColor Green
        } else {
            Write-Host "PRODUCT RUNTIME RESULT: NOT PROVEN - inspect PR45_RUNTIME_TRACE.txt" -ForegroundColor Red
        }

        if ($runError) {
            Write-Warning ("Run error: " + $runError)
        }

        Write-Host "Evidence ZIP: $zip"
        Write-Host "Original Workshop scripts pack, DLLs, probes and prior logs restored."
    } catch {
        Write-Warning ("Evidence ZIP creation failed: " + $_.Exception.Message)
    }
}
