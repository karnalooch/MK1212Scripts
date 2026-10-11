# Copies one verified MK1212 Lua overlay. Does not edit Workshop or game binaries.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GameDirectory
)

$ErrorActionPreference = 'Stop'
$manifests = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.manifest.json' -File)
if ($manifests.Count -ne 1) {
    throw 'Keep exactly one release profile in this folder (one manifest).'
}
$manifest = Get-Content -LiteralPath $manifests[0].FullName -Raw | ConvertFrom-Json
if ($manifest.schema -ne 'mk1212-script-pack-v1' -or $manifest.schema_version -ne 1) {
    throw 'Unknown release manifest schema.'
}
$packName = [string]$manifest.pack.filename
if ($packName -notmatch '^mk1212_scripts_(baseline|full_experimental)_[0-9a-f]{12}\.pack$') {
    throw 'Unexpected pack filename in manifest.'
}
$profileName = [string]$manifest.profile.name
$sourceCommit = [string]$manifest.source_commit_sha
if ($profileName -notin @('baseline', 'full-experimental') -or $sourceCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'Invalid release profile or source commit in manifest.'
}
$expectedName = 'mk1212_scripts_' + $profileName.Replace('-', '_') + '_' + $sourceCommit.Substring(0, 12) + '.pack'
if ($packName -cne $expectedName) {
    throw 'Pack filename disagrees with release profile/source commit.'
}
if ([string]$manifest.pack.sha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'Invalid pack SHA256 in manifest.'
}
$sourcePack = Join-Path $PSScriptRoot $packName
if (-not (Test-Path -LiteralPath $sourcePack -PathType Leaf)) {
    throw 'The pack listed in the manifest is missing.'
}
$sourceHash = (Get-FileHash -LiteralPath $sourcePack -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sourceHash -ne $manifest.pack.sha256 -or (Get-Item -LiteralPath $sourcePack).Length -ne $manifest.pack.size) {
    throw 'Source pack does not match its manifest. Nothing was installed.'
}
$gamePath = (Resolve-Path -LiteralPath $GameDirectory).ProviderPath
if (-not (Test-Path -LiteralPath (Join-Path $gamePath 'Attila.exe') -PathType Leaf)) {
    throw 'GameDirectory must be the licensed Attila install folder containing Attila.exe.'
}
$dataPath = Join-Path $gamePath 'data'
if (-not (Test-Path -LiteralPath $dataPath -PathType Container)) {
    throw 'Attila data directory does not exist.'
}
if (Get-Process -Name 'Attila' -ErrorAction SilentlyContinue) {
    throw 'Close Attila before changing the script pack.'
}
$otherPacks = @(Get-ChildItem -LiteralPath $dataPath -Filter '*.pack' -File |
    Where-Object {
        $_.Name -ne $packName -and
        ($_.Name -like 'mk1212_scripts_*.pack' -or $_.Name -like '00_mk1212_spmp_*.pack')
    })
if ($otherPacks.Count -gt 0) {
    throw ('Move the previous MK1212 overlays outside the game data folder first: ' +
        (($otherPacks | ForEach-Object { $_.Name }) -join ', '))
}
$targetPack = Join-Path $dataPath $packName
if (Test-Path -LiteralPath $targetPack) {
    if ((Get-FileHash -LiteralPath $targetPack -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceHash) {
        throw 'A different file already occupies the target name. It was preserved.'
    }
    Write-Host 'The identical pack is already installed.'
} else {
    $temporaryPack = Join-Path $dataPath ('mk1212-copy-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Copy-Item -LiteralPath $sourcePack -Destination $temporaryPack
        if ((Get-FileHash -LiteralPath $temporaryPack -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceHash) {
            throw 'The copied pack failed SHA256 verification.'
        }
        # File.Move refuses a concurrently created destination; never overwrite.
        [System.IO.File]::Move($temporaryPack, $targetPack)
    } finally {
        if (Test-Path -LiteralPath $temporaryPack -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPack
        }
    }
    Write-Host 'Pack copied and SHA256 verified.'
}
Write-Host ('Profile: ' + $manifest.profile.name)
Write-Host ('Source: ' + $manifest.source_commit_sha)
Write-Host ('SHA256: ' + $sourceHash)
Write-Host 'Activate ONLY this overlay in the mod manager, with priority over the original scripts.'
Write-Host 'Keep the required MK1212 base packs enabled. See INSTRUKCJA.md for load verification.'
Write-Host 'The installer did not launch a campaign or change saves/load-order configuration.'
