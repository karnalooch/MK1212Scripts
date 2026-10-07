param([Parameter(Mandatory=$true)][string]$ProbeRoot)
$ErrorActionPreference = 'Stop'
$ProbeRoot = (Resolve-Path $ProbeRoot).Path
$Rpfm = Join-Path $ProbeRoot 'tools/rpfm_cli.exe'
$OriginalAppData = $env:APPDATA
$Base = Join-Path $PWD 'build/rollback-fixtures'
function Hash($Path) { (Get-FileHash $Path -Algorithm SHA256).Hash }
try {
    foreach ($Engine in @('powershell.exe', 'pwsh.exe')) {
    foreach ($ExistingFiles in @($true,$false)) {
        $fixture = Join-Path $Base ($Engine + '-' + [string]$ExistingFiles)
        $workshop = Join-Path $fixture 'steamapps/workshop/content/325610/1234/1-1212scripts.pack'
        $game = Join-Path $fixture 'steamapps/common/Total War Attila'
        $appdata = Join-Path $fixture 'appdata'
        $moddata = Join-Path $appdata 'The Creative Assembly/Launcher/20190104-moddata.dat'
        New-Item -ItemType Directory -Force -Path (Split-Path $workshop),(Join-Path $game 'data'),(Split-Path $moddata) | Out-Null
        & $Rpfm --game attila pack create --pack-path $workshop
        if ($LASTEXITCODE -ne 0) { throw 'Synthetic pack creation failed' }
        $seed = Join-Path $fixture 'seed'
        foreach ($folder in @('campaigns/main_attila/common','lua_scripts','script')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $seed $folder) | Out-Null
        }
        Set-Content (Join-Path $seed 'campaigns/main_attila/common/main.lua') 'function Common_Initializer() end'
        Set-Content (Join-Path $seed 'lua_scripts/frontend.lua') '-- frontend sentinel'
        Set-Content (Join-Path $seed 'script/sentinel.lua') '-- library sentinel'
        & $Rpfm --game attila pack add --pack-path $workshop -F ($seed + ';')
        if ($LASTEXITCODE -ne 0) { throw 'Synthetic Workshop seed failed' }
        Set-Content (Join-Path $game 'Attila.exe') 'synthetic executable fingerprint; never launched'
        Set-Content (Join-Path $game 'empire.retail.dll') 'synthetic engine fingerprint'
        @(
            @{uuid='unrelated-disabled.pack';active=$false;packfile='D:/missing/disabled.pack';order=1},
            @{uuid='1-1212scripts.pack';active=$true;packfile=$workshop.Replace('\','/');order=2},
            @{uuid='unrelated-active.pack';active=$true;packfile='D:/missing/active.pack';order=3}
        ) | ConvertTo-Json -Depth 8 | Set-Content $moddata
        $beforePack = Hash $workshop
        $beforeMods = Hash $moddata
        $managedNames = @('twdll.dll','twdll_attila.dll','twdll.log','MK1212_mp_debug.log','PR45_RUNTIME_TRACE.txt')
        $hashes = @{}
        $attributes = @{}
        if ($ExistingFiles) {
            foreach ($name in $managedNames) {
                $p = Join-Path $game $name
                Set-Content $p "Original $name"
                (Get-Item $p).IsReadOnly = $true
                $hashes[$name] = Hash $p
                $attributes[$name] = (Get-Item $p).Attributes
            }
        }
        $probeNames = @('mk1212_twdll_sp_probe.pack','zzz_mk1212_twdll_sp_probe_v2.pack','000_mk1212_twdll_sp_probe_v4_movie.pack','mk1212_pr45_runtime_scripts.pack')
        $probeHashes = @{}
        if ($ExistingFiles) {
            foreach ($name in $probeNames) {
                $p = Join-Path (Join-Path $game 'data') $name
                Set-Content $p "Old probe $name"
                (Get-Item $p).IsReadOnly = $true
                $probeHashes[$name] = Hash $p
            }
        }
        $unrelated = Join-Path (Join-Path $game 'data') 'unrelated.pack'
        Set-Content $unrelated 'Ordinary mod must remain untouched'
        $unrelatedHash = Hash $unrelated
        $env:APPDATA = $appdata
        $beforeEvidence = @(Get-ChildItem $ProbeRoot -Directory -Filter 'evidence-*').Count
        & $Engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ProbeRoot 'RUN-MK1212-PR45-SP-TEST.ps1') -PrepareOnly
        if ($LASTEXITCODE -ne 1) { throw 'Preparation-only proof must not report runtime PASS' }
        if (@(Get-ChildItem $ProbeRoot -Directory -Filter 'evidence-*').Count -ne $beforeEvidence + 1) { throw 'Harness did not produce fresh evidence' }
        $latest = Get-ChildItem $ProbeRoot -Directory -Filter 'evidence-*' | Sort-Object Name -Descending | Select-Object -First 1
        $provenance = Get-Content (Join-Path $latest.FullName 'manifest.json') -Raw | ConvertFrom-Json
        if ($provenance.game_root -ne $game.Replace('/', '\')) { throw 'Harness selected the wrong game path' }
        $result = Get-Content (Join-Path $latest.FullName 'result.json') -Raw | ConvertFrom-Json
        if (-not $result.rollback_ok -or $result.pass -or $result.run_error -ne 'Preparation-only rollback test') { throw 'Unexpected synthetic rollback result' }
        if ((Hash $workshop) -ne $beforePack -or (Hash $moddata) -ne $beforeMods) { throw 'Pack or launcher state was not preserved' }
        foreach ($name in $managedNames) {
            $p = Join-Path $game $name
            if ($ExistingFiles) {
                if ((Hash $p) -ne $hashes[$name] -or (Get-Item $p).Attributes -ne $attributes[$name]) { throw "Original file/attributes not restored: $name" }
            } elseif (Test-Path $p) { throw "Unexpected file survived rollback: $name" }
        }
        $expectedProbes = if ($ExistingFiles) { $probeNames.Count } else { 0 }
        if ($provenance.isolated_probe_count -ne $expectedProbes -or $result.isolated_probe_count -ne $expectedProbes) { throw 'Old probes were not isolated before preparation completed' }
        foreach ($name in $probeNames) {
            $p = Join-Path (Join-Path $game 'data') $name
            if ($ExistingFiles) {
                if ((Hash $p) -ne $probeHashes[$name] -or -not (Get-Item $p).IsReadOnly) { throw "Old probe not restored: $name" }
            } elseif (Test-Path $p) { throw "Unexpected probe created: $name" }
        }
        if ((Hash $unrelated) -ne $unrelatedHash) { throw 'Unrelated mod was modified' }
        Write-Host "Synthetic rollback PASS: engine=$Engine; pre-existing files=$ExistingFiles"
    }
    }
} finally {
    $env:APPDATA = $OriginalAppData
}
# The deliberate child exit=1 is expected evidence, not the parent test outcome.
$global:LASTEXITCODE = 0
