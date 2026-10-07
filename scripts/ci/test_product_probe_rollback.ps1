param([Parameter(Mandatory=$true)][string]$ProbeRoot)
$ErrorActionPreference = 'Stop'
$ProbeRoot = (Resolve-Path $ProbeRoot).Path
$Rpfm = Join-Path $ProbeRoot 'tools/rpfm_cli.exe'
$OriginalAppData = $env:APPDATA
$Base = Join-Path $PWD 'build/rollback-fixtures'
function Hash($Path) { (Get-FileHash $Path -Algorithm SHA256).Hash }
try {
    foreach ($ExistingFiles in @($true,$false)) {
        $fixture = Join-Path $Base ([string]$ExistingFiles)
        $workshop = Join-Path $fixture 'steamapps/workshop/content/325610/1234/1-1212scripts.pack'
        $game = Join-Path $fixture 'steamapps/common/Total War Attila'
        $appdata = Join-Path $fixture 'appdata'
        $moddata = Join-Path $appdata 'The Creative Assembly/Launcher/20190104-moddata.dat'
        New-Item -ItemType Directory -Force -Path (Split-Path $workshop),(Join-Path $game 'data'),(Split-Path $moddata) | Out-Null
        & $Rpfm --game attila pack create --pack-path $workshop
        if ($LASTEXITCODE -ne 0) { throw 'Synthetic pack creation failed' }
        Set-Content (Join-Path $game 'Attila.exe') 'synthetic executable fingerprint; never launched'
        Set-Content (Join-Path $game 'empire.retail.dll') 'synthetic engine fingerprint'
        @(@{uuid='1-1212scripts.pack';active=$true;packfile=$workshop;order=2}) | ConvertTo-Json -Depth 8 | Set-Content $moddata
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
        $env:APPDATA = $appdata
        & pwsh -NoProfile -File (Join-Path $ProbeRoot 'RUN-MK1212-PR45-SP-TEST.ps1') -PrepareOnly
        if ($LASTEXITCODE -ne 1) { throw 'Preparation-only proof must not report runtime PASS' }
        $latest = Get-ChildItem $ProbeRoot -Directory -Filter 'evidence-*' | Sort-Object Name -Descending | Select-Object -First 1
        $result = Get-Content (Join-Path $latest.FullName 'result.json') -Raw | ConvertFrom-Json
        if (-not $result.rollback_ok -or $result.pass -or $result.run_error -ne 'Preparation-only rollback test') { throw 'Unexpected synthetic rollback result' }
        if ((Hash $workshop) -ne $beforePack -or (Hash $moddata) -ne $beforeMods) { throw 'Pack or launcher state was not preserved' }
        foreach ($name in $managedNames) {
            $p = Join-Path $game $name
            if ($ExistingFiles) {
                if ((Hash $p) -ne $hashes[$name] -or (Get-Item $p).Attributes -ne $attributes[$name]) { throw "Original file/attributes not restored: $name" }
            } elseif (Test-Path $p) { throw "Unexpected file survived rollback: $name" }
        }
        Write-Host "Synthetic rollback PASS: pre-existing files=$ExistingFiles"
    }
} finally {
    $env:APPDATA = $OriginalAppData
}
# The deliberate child exit=1 is expected evidence, not the parent test outcome.
$global:LASTEXITCODE = 0
