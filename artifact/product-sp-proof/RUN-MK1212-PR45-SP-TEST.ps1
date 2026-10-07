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
$AttilaApp = Join-Path $env:APPDATA "The Creative Assembly\Attila"
$ScriptDir = Join-Path $AttilaApp "scripts"
$UserScript = Join-Path $ScriptDir "user.script.txt"

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Backup = Join-Path $Here ("backup-" + $Stamp)
$Evidence = Join-Path $Here ("evidence-" + $Stamp)
New-Item -ItemType Directory -Force -Path $Backup, $Evidence, $ScriptDir | Out-Null

$BackupReady = $false
$UserScriptWasReadOnly = $false
$runError = $null
$result = [ordered]@{
    source_sha = $ExpectedSourceSha
    native_ready = $false
    debug_ready = $false
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

    Write-Host "Restoring local Attila/MK1212 environment..." -ForegroundColor Cyan

    try {
        if (Test-Path $UserScript) {
            try { (Get-Item $UserScript).IsReadOnly = $false } catch {}
        }

        $savedModData = Join-Path $Backup "20190104-moddata.dat"
        if (Test-Path $savedModData) {
            Copy-Item $savedModData $ModData -Force
        }

        if (Test-Path (Join-Path $Backup "user.script.txt")) {
            Copy-Item (Join-Path $Backup "user.script.txt") $UserScript -Force
            try { (Get-Item $UserScript).IsReadOnly = $UserScriptWasReadOnly } catch {}
        } else {
            Remove-Item $UserScript -Force -ErrorAction SilentlyContinue
        }

        foreach ($p in @($LocalPack, $Twdll, $TwdllAttila, $NativeLog, $DebugLog)) {
            if ($p) {
                Remove-Item $p -Force -ErrorAction SilentlyContinue
            }
        }

        foreach ($name in @(
            "mk1212_pr45_runtime_scripts.pack",
            "twdll.dll",
            "twdll_attila.dll",
            "twdll.log",
            "MK1212_mp_debug.log"
        )) {
            $saved = Join-Path $Backup $name
            if (Test-Path $saved) {
                if ($name -eq "mk1212_pr45_runtime_scripts.pack") {
                    $destination = $LocalPack
                } else {
                    $destination = Join-Path $GameRoot $name
                }
                Copy-Item $saved $destination -Force
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

$mods = @(Get-Content $ModData -Raw | ConvertFrom-Json)
$scriptMod = $mods |
    Where-Object { $_.uuid -eq "1-1212scripts.pack" } |
    Select-Object -First 1

if (-not $scriptMod) {
    throw "MK1212 Workshop scripts pack (1-1212scripts.pack) not found in launcher moddata"
}

$workshopScripts = [string] $scriptMod.packfile
if (!(Test-Path $workshopScripts)) {
    throw "Workshop scripts pack not found: $workshopScripts"
}

$normalized = $workshopScripts.Replace("/", "\")
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

$LocalPack = Join-Path $Data "mk1212_pr45_runtime_scripts.pack"
$Twdll = Join-Path $GameRoot "twdll.dll"
$TwdllAttila = Join-Path $GameRoot "twdll_attila.dll"
$NativeLog = Join-Path $GameRoot "twdll.log"
$DebugLog = Join-Path $GameRoot "MK1212_mp_debug.log"

if (!(Test-Path $Exe)) {
    throw "Attila.exe not found: $Exe"
}

Write-Host "=== MK1212 PR45 PRODUCT SP PROOF ===" -ForegroundColor Cyan
Write-Host "Game root: $GameRoot"
Write-Host "Workshop scripts: $workshopScripts"
Write-Host "Exact source: $ExpectedSourceSha"
Write-Host ""

# Back up every file/state surface that the harness may mutate.
Copy-Item $ModData (Join-Path $Backup "20190104-moddata.dat") -Force

if (Test-Path $UserScript) {
    $UserScriptWasReadOnly = (Get-Item $UserScript).IsReadOnly
    Copy-Item $UserScript (Join-Path $Backup "user.script.txt") -Force
}

foreach ($p in @($LocalPack, $Twdll, $TwdllAttila, $NativeLog, $DebugLog)) {
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
    # Remove stale probe packs for this run only.
    foreach ($name in $probeNames) {
        Remove-Item (Join-Path $Data $name) -Force -ErrorAction SilentlyContinue
    }

    # Clone the user's exact active Workshop scripts pack and replace only PR45 integration files.
    Copy-Item $workshopScripts $LocalPack -Force
    & $Rpfm --game attila pack add --pack-path $LocalPack -F ((Join-Path $Payload "patch-src") + ";")
    if ($LASTEXITCODE -ne 0) {
        throw "RPFM failed to patch the cloned MK1212 scripts pack"
    }

    # Install the exact native DLL built from the same PR head.
    Copy-Item (Join-Path $Payload "twdll.dll") $Twdll -Force
    Copy-Item (Join-Path $Payload "twdll_attila.dll") $TwdllAttila -Force

    # Fresh proof must not append to old runtime evidence.
    Remove-Item $NativeLog, $DebugLog -Force -ErrorAction SilentlyContinue

    # Keep all currently-active mods unchanged except the Workshop scripts component and old probes.
    foreach ($m in $mods) {
        if ($m.uuid -eq "1-1212scripts.pack") {
            $m.active = $false
        }
        if ($m.uuid -like "*twdll*probe*") {
            $m.active = $false
        }
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $modDataJson = $mods | ConvertTo-Json -Depth 8 -Compress
    [System.IO.File]::WriteAllText($ModData, $modDataJson, $utf8NoBom)

    # Force-load the cloned scripts pack from data. The Workshop scripts pack is disabled above.
    if (Test-Path $UserScript) {
        try { (Get-Item $UserScript).IsReadOnly = $false } catch {}
    }
    'mod "mk1212_pr45_runtime_scripts.pack";' | Set-Content -Encoding ASCII $UserScript
    (Get-Item $UserScript).IsReadOnly = $true

    # Record exact pre-launch provenance.
    $manifest = [ordered]@{
        source_sha = $ExpectedSourceSha
        started_at = (Get-Date).ToString("o")
        game_root = $GameRoot
        workshop_scripts_pack = $workshopScripts
        workshop_scripts_sha256 = (Get-FileHash $workshopScripts -Algorithm SHA256).Hash.ToLower()
        patched_scripts_sha256 = (Get-FileHash $LocalPack -Algorithm SHA256).Hash.ToLower()
        attila_sha256 = (Get-FileHash $Exe -Algorithm SHA256).Hash.ToLower()
        empire_retail_sha256 = if (Test-Path $EmpireRetail) {
            (Get-FileHash $EmpireRetail -Algorithm SHA256).Hash.ToLower()
        } else {
            $null
        }
        twdll_sha256 = (Get-FileHash $Twdll -Algorithm SHA256).Hash.ToLower()
    }
    $manifest | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $Evidence "manifest.json")
    Copy-Item $ModData (Join-Path $Evidence "moddata.used.json") -Force
    Copy-Item $UserScript (Join-Path $Evidence "user.script.used.txt") -Force

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

    Write-Host "Detected Attila PID $($proc.Id). Waiting for game exit..." -ForegroundColor Cyan
    Wait-Process -Id $proc.Id
    Start-Sleep -Seconds 3
} catch {
    $runError = $_.Exception.Message
    Write-Warning ("Product runtime run did not complete cleanly: " + $runError)
} finally {
    # Capture proof before any previous logs/files are restored.
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
                $dbg.Contains("reason=ready")
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
        if ($result.native_ready -and $result.debug_ready) {
            Write-Host "PRODUCT RUNTIME RESULT: PASS" -ForegroundColor Green
        } else {
            Write-Host "PRODUCT RUNTIME RESULT: NOT PROVEN - inspect evidence" -ForegroundColor Red
        }
        if ($runError) {
            Write-Warning ("Run error: " + $runError)
        }
        Write-Host "Evidence ZIP: $zip"
        Write-Host "Launcher moddata, user.script, DLLs, probes and prior logs restored."
    } catch {
        Write-Warning ("Evidence ZIP creation failed: " + $_.Exception.Message)
    }
}
