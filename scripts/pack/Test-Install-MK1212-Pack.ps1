# Synthetic filesystem tests for Windows PowerShell 5.1 AND PowerShell 7.
# Never launches the fake Attila.exe or touches a real game/install/save.
[CmdletBinding()]
param(
    [string]$InstallerPath = (Join-Path $PSScriptRoot 'Install-MK1212-Pack.ps1')
)

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mk1212-installer-test-' + [guid]::NewGuid().ToString('N'))
$script:passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('ASSERTION FAILED: ' + $Message) }
}

function Assert-Throws([scriptblock]$Action, [string]$Expected) {
    $caught = $false
    try { & $Action } catch {
        $caught = $true
        if ($_.Exception.Message -notlike ('*' + $Expected + '*')) {
            throw ('Unexpected failure: ' + $_.Exception.Message + '; expected: ' + $Expected)
        }
    }
    Assert-True $caught ('Expected refusal: ' + $Expected)
}

function Pass([string]$Name) {
    $script:passed += 1
    Write-Host ('PASS: ' + $Name)
}

try {
    $bundlePath = Join-Path $testRoot 'bundle'
    $gamePath = Join-Path $testRoot 'game'
    $dataPath = Join-Path $gamePath 'data'
    [System.IO.Directory]::CreateDirectory($bundlePath) | Out-Null
    [System.IO.Directory]::CreateDirectory($dataPath) | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $gamePath 'Attila.exe'), [byte[]]@(77, 90))
    Copy-Item -LiteralPath $InstallerPath -Destination (Join-Path $bundlePath 'Install-MK1212-Pack.ps1')
    $underTest = Join-Path $bundlePath 'Install-MK1212-Pack.ps1'
    $packName = 'mk1212_scripts_baseline_aaaaaaaaaaaa.pack'
    $sourcePack = Join-Path $bundlePath $packName
    $targetPack = Join-Path $dataPath $packName
    # Minimal valid PFH4 fixture; payload is parsed by the separate Python tests.
    $bytes = [byte[]]@(
        80, 70, 72, 52, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 0, 0, 0, 17, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0
    ) + [System.Text.Encoding]::ASCII.GetBytes("script\a.lua`0return 1`n")
    [System.IO.File]::WriteAllBytes($sourcePack, $bytes)
    $sourceHash = (Get-FileHash -LiteralPath $sourcePack -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifestPath = Join-Path $bundlePath 'release.manifest.json'
    $manifest = [ordered]@{
        schema = 'mk1212-script-pack-v1'
        schema_version = 1
        source_commit_sha = ('a' * 40)
        profile = @{ name = 'baseline' }
        pack = @{ filename = $packName; sha256 = $sourceHash; size = $bytes.Length }
    }
    $validJson = $manifest | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($manifestPath, $validJson)
    $unrelated = Join-Path $dataPath '1-1212scripts.pack'
    [System.IO.File]::WriteAllText($unrelated, 'original fixture must survive')
    $originalHash = (Get-FileHash -LiteralPath $unrelated -Algorithm SHA256).Hash

    & $underTest -GameDirectory $gamePath
    Assert-True (Test-Path -LiteralPath $targetPack -PathType Leaf) 'pack was copied'
    Assert-True ((Get-FileHash -LiteralPath $targetPack -Algorithm SHA256).Hash.ToLowerInvariant() -eq $sourceHash) 'installed bytes match source'
    Assert-True ((Get-FileHash -LiteralPath $unrelated -Algorithm SHA256).Hash -eq $originalHash) 'base pack preserved'
    Pass 'verified copy preserves original pack'

    $stamp = (Get-Item -LiteralPath $targetPack).LastWriteTimeUtc.Ticks
    & $underTest -GameDirectory $gamePath
    Assert-True ((Get-Item -LiteralPath $targetPack).LastWriteTimeUtc.Ticks -eq $stamp) 'idempotent install did not rewrite identical pack'
    Pass 'same pack is idempotent'

    [System.IO.File]::WriteAllText($targetPack, 'preserve conflicting bytes')
    Assert-Throws { & $underTest -GameDirectory $gamePath } 'different file already occupies'
    Assert-True (([System.IO.File]::ReadAllText($targetPack)) -eq 'preserve conflicting bytes') 'conflicting destination was not overwritten'
    Remove-Item -LiteralPath $targetPack
    Pass 'different target bytes are refused and preserved'

    $oldPack = Join-Path $dataPath '00_mk1212_spmp_67_full_previous.pack'
    [System.IO.File]::WriteAllText($oldPack, 'previous PR67 overlay')
    Assert-Throws { & $underTest -GameDirectory $gamePath } 'Move the previous MK1212 overlays'
    Assert-True (-not (Test-Path -LiteralPath $targetPack)) 'legacy overlay conflict prevented copy'
    Assert-True (([System.IO.File]::ReadAllText($oldPack)) -eq 'previous PR67 overlay') 'legacy overlay preserved'
    Remove-Item -LiteralPath $oldPack
    Pass 'previous 00_mk1212_spmp overlay is refused'

    $otherProfile = Join-Path $dataPath 'mk1212_scripts_full_experimental_bbbbbbbbbbbb.pack'
    [System.IO.File]::WriteAllText($otherProfile, 'other profile')
    Assert-Throws { & $underTest -GameDirectory $gamePath } 'Move the previous MK1212 overlays'
    Assert-True (-not (Test-Path -LiteralPath $targetPack)) 'other profile prevented copy'
    Remove-Item -LiteralPath $otherProfile
    Pass 'other current profile is refused'

    [System.IO.File]::WriteAllText($sourcePack, 'damaged download')
    Assert-Throws { & $underTest -GameDirectory $gamePath } 'does not match its manifest'
    Assert-True (-not (Test-Path -LiteralPath $targetPack)) 'damaged source was not copied'
    [System.IO.File]::WriteAllBytes($sourcePack, $bytes)
    Pass 'damaged source is refused'

    $manifest.pack.filename = '..\unexpected.pack'
    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 10))
    Assert-Throws { & $underTest -GameDirectory $gamePath } 'Unexpected pack filename'
    [System.IO.File]::WriteAllText($manifestPath, $validJson)
    Pass 'unexpected filename is refused before copy'

    $manifest.pack.filename = $packName
    $manifest.profile.name = 'full-experimental'
    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 10))
    Assert-Throws { & $underTest -GameDirectory $gamePath } 'filename disagrees'
    [System.IO.File]::WriteAllText($manifestPath, $validJson)
    Pass 'filename/profile mismatch is refused'

    $extraManifest = Join-Path $bundlePath 'other.manifest.json'
    [System.IO.File]::WriteAllText($extraManifest, $validJson)
    Assert-Throws { & $underTest -GameDirectory $gamePath } 'exactly one release profile'
    Remove-Item -LiteralPath $extraManifest
    Pass 'mixed release folders are refused'

    $invalidGame = Join-Path $testRoot 'not-a-game'
    [System.IO.Directory]::CreateDirectory($invalidGame) | Out-Null
    Assert-Throws { & $underTest -GameDirectory $invalidGame } 'containing Attila.exe'
    Assert-True (-not (Test-Path -LiteralPath $targetPack)) 'invalid destination had no side effects'
    Pass 'invalid game folder is refused'

    Assert-True ((Get-FileHash -LiteralPath $unrelated -Algorithm SHA256).Hash -eq $originalHash) 'base pack survived all cases'
    Assert-True (@(Get-ChildItem -LiteralPath $dataPath -Filter 'mk1212-copy-*.tmp').Count -eq 0) 'no partial temporary packs remain'
    Write-Host ('PASS: ' + $script:passed + ' installer tests; PowerShell ' + $PSVersionTable.PSVersion.ToString())
} finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
