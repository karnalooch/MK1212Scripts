[CmdletBinding()]
param(
    [string]$RuntimeDirectory = (Join-Path $PSScriptRoot '../runtime'),
    [string]$GoldbergArchivePath = $env:GOLDBERG_ARCHIVE_PATH,
    [string]$LockPath = (Join-Path $PSScriptRoot '../../third_party/goldberg/lock.json')
)

# Repository/tool behavior only. These tests never launch Attila or Sandboxie.
# The authentic pinned emulator archive is a required fixture, not a game asset.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $RuntimeDirectory 'dual_client_lab_core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $RuntimeDirectory 'goldberg_client_lab_core.psm1') -Force -DisableNameChecking

$script:GoldbergChecks = 0
$script:GoldbergFailures = New-Object 'System.Collections.Generic.List[string]'

function Assert-GoldTrue {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-GoldEqual {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) { throw ('{0}: expected [{1}], received [{2}]' -f $Message, $Expected, $Actual) }
}

function Assert-GoldThrows {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action | Out-Null }
    catch { return }
    throw ('Expected rejection: ' + $Message)
}

function Invoke-GoldCheck {
    param([string]$Name, [scriptblock]$Action)
    $script:GoldbergChecks++
    try {
        & $Action | Out-Null
        Write-Host ('PASS: ' + $Name)
    }
    catch {
        $message = $Name + ': ' + $_.Exception.Message
        [void]$script:GoldbergFailures.Add($message)
        Write-Host ('FAIL: ' + $message)
    }
}

function Write-GoldFixture {
    param([string]$Path, [AllowEmptyString()][string]$Text)
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-GoldPeFixture {
    param([string]$Path, [int]$Machine = 332, [string]$Payload = '')
    $payloadBytes = [System.Text.Encoding]::ASCII.GetBytes($Payload)
    $bytes = New-Object byte[] (512 + $payloadBytes.Length)
    $bytes[0] = 0x4d; $bytes[1] = 0x5a
    [Array]::Copy([BitConverter]::GetBytes([int]128), 0, $bytes, 0x3c, 4)
    $bytes[128] = 0x50; $bytes[129] = 0x45
    [Array]::Copy([BitConverter]::GetBytes([uint16]$Machine), 0, $bytes, 132, 2)
    [Array]::Copy([BitConverter]::GetBytes([uint16]224), 0, $bytes, 148, 2)
    [Array]::Copy([BitConverter]::GetBytes([uint16]0x10b), 0, $bytes, 152, 2)
    [Array]::Copy($payloadBytes, 0, $bytes, 512, $payloadBytes.Length)
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function New-GoldSourceFixture {
    param([string]$Name)
    $fixtureRoot = Join-Path $goldTemp $Name
    $source = Join-Path $fixtureRoot 'Original Attila [source]'
    $lab = Join-Path $fixtureRoot 'owned-lab'
    [void][System.IO.Directory]::CreateDirectory($source)
    [void][System.IO.Directory]::CreateDirectory($lab)
    New-GoldPeFixture -Path (Join-Path $source 'Attila.exe')
    New-GoldPeFixture -Path (Join-Path $source 'steam_api.dll') -Payload "SteamUser017`0SteamUtils007`0STEAMAPPS_INTERFACE_VERSION006`0"
    Write-GoldFixture (Join-Path $source 'data/test.pack') 'PACK-ONE'
    Write-GoldFixture (Join-Path $source 'data/[extra].pack') 'PACK-TWO'
    return [pscustomobject]@{ root = $fixtureRoot; source = $source; lab = $lab; id = [Guid]::NewGuid().ToString('N') }
}

function Get-GoldFixtureHashes {
    param([string]$Root)
    $result = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $Root -Recurse -Force -File)) {
        $relative = $file.FullName.Substring($Root.TrimEnd('\', '/').Length).TrimStart('\', '/')
        $result[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $result
}

function Assert-GoldHashMaps {
    param([hashtable]$Actual, [hashtable]$Expected, [string]$Message)
    Assert-GoldEqual $Actual.Count $Expected.Count ($Message + ' file count')
    foreach ($key in $Expected.Keys) {
        Assert-GoldTrue ($Actual.ContainsKey($key)) ($Message + ': missing ' + $key)
        Assert-GoldEqual $Actual[$key] $Expected[$key] ($Message + ': ' + $key)
    }
}

if ([string]::IsNullOrWhiteSpace($GoldbergArchivePath) -or -not (Test-Path -LiteralPath $GoldbergArchivePath -PathType Leaf)) {
    throw 'The pinned archive fixture is required: set GOLDBERG_ARCHIVE_PATH or -GoldbergArchivePath. No emulator/game test ran.'
}
$goldLock = [System.IO.File]::ReadAllText($LockPath) | ConvertFrom-Json
$goldTemp = Join-Path ([System.IO.Path]::GetTempPath()) ('mk1212-goldberg-tests-' + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($goldTemp)

try {
    Invoke-GoldCheck 'Source and lab roots must be disjoint after normalization' {
        $source = Join-Path $goldTemp 'source'
        Assert-GoldTrue (Test-GoldbergRootsDisjoint -SourceRoot $source -LabRoot (Join-Path $goldTemp 'source-other')) 'sibling prefix is a distinct root'
        Assert-GoldTrue (-not (Test-GoldbergRootsDisjoint -SourceRoot $source -LabRoot $source)) 'identical root must be refused'
        Assert-GoldTrue (-not (Test-GoldbergRootsDisjoint -SourceRoot $source -LabRoot (Join-Path $source 'lab'))) 'lab cannot be copied recursively from source'
        Assert-GoldTrue (-not (Test-GoldbergRootsDisjoint -SourceRoot (Join-Path $source 'game') -LabRoot $source)) 'source cannot sit inside writable lab'
        Assert-GoldTrue (-not (Test-GoldbergRootsDisjoint -SourceRoot $source -LabRoot (Join-Path $source 'child/..'))) 'normalized equal paths must be refused'
    }

    Invoke-GoldCheck 'Disk reservation is inclusive and rejects shortages, negative sizes and overflow' {
        Assert-GoldEqual (Assert-GoldbergDiskBudget -MissingBytes 10 -AvailableBytes 15 -ReserveBytes 5) 15 'inclusive required disk bytes'
        Assert-GoldThrows { Assert-GoldbergDiskBudget -MissingBytes 10 -AvailableBytes 14 -ReserveBytes 5 } 'insufficient space'
        Assert-GoldThrows { Assert-GoldbergDiskBudget -MissingBytes -1 -AvailableBytes 100 -ReserveBytes 5 } 'negative missing bytes'
        Assert-GoldThrows { Assert-GoldbergDiskBudget -MissingBytes 1 -AvailableBytes -1 -ReserveBytes 5 } 'negative available bytes'
        Assert-GoldThrows { Assert-GoldbergDiskBudget -MissingBytes ([long]::MaxValue) -AvailableBytes ([long]::MaxValue) -ReserveBytes 1 } 'sum overflow'
    }

    Invoke-GoldCheck 'PE machine detection distinguishes x86 and x64 and rejects malformed files' {
        $x86 = Join-Path $goldTemp 'pe/x86.dll'
        $x64 = Join-Path $goldTemp 'pe/x64.dll'
        $bad = Join-Path $goldTemp 'pe/bad.dll'
        New-GoldPeFixture -Path $x86 -Machine 332
        New-GoldPeFixture -Path $x64 -Machine 34404
        Write-GoldFixture $bad 'not a PE image'
        Assert-GoldEqual (Get-GoldbergPeMachine -Path $x86) 332 'x86 machine'
        Assert-GoldEqual (Get-GoldbergPeMachine -Path $x64) 34404 'x64 machine'
        Assert-GoldThrows { Get-GoldbergPeMachine -Path $bad } 'missing DOS/PE headers'
        $corrupt = [System.IO.File]::ReadAllBytes($x86)
        [Array]::Copy([BitConverter]::GetBytes([int]2147483647), 0, $corrupt, 0x3c, 4)
        [System.IO.File]::WriteAllBytes($bad, $corrupt)
        Assert-GoldThrows { Get-GoldbergPeMachine -Path $bad } 'PE offset past file bounds'
    }

    Invoke-GoldCheck 'Original interface scan deduplicates versions and rejects ambiguous interfaces' {
        $path = Join-Path $goldTemp 'interfaces/original.dll'
        New-GoldPeFixture -Path $path -Payload "SteamUser017`0SteamUser017`0SteamUtils007`0STEAMAPPS_INTERFACE_VERSION006`0"
        $before = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $interfaces = Get-GoldbergInterfaces -OriginalDll $path
        Assert-GoldTrue ($interfaces -contains 'SteamUser017') 'original SteamUser interface retained'
        Assert-GoldTrue ($interfaces -contains 'SteamUtils007') 'original SteamUtils interface retained'
        Assert-GoldTrue ($interfaces -contains 'STEAMAPPS_INTERFACE_VERSION006') 'original SteamApps interface retained'
        Assert-GoldEqual (@($interfaces | Where-Object { $_ -eq 'SteamUser017' }).Count) 1 'identical duplicates collapse'
        Assert-GoldEqual ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) $before 'interface scan cannot modify original DLL'
        New-GoldPeFixture -Path $path -Payload "SteamUser017`0SteamUser018`0"
        Assert-GoldThrows { Get-GoldbergInterfaces -OriginalDll $path } 'two distinct versions of one interface'
    }

    Invoke-GoldCheck 'Peer configuration has distinct forced identities and explicit reciprocal TCP/UDP discovery ports' {
        $hostSettings = Get-GoldbergPeerSettings -Role HOST -InterfaceLines @('SteamUser017')
        $clientSettings = Get-GoldbergPeerSettings -Role CLIENT -InterfaceLines @('SteamUser017')
        foreach ($settings in @($hostSettings, $clientSettings)) {
            Assert-GoldEqual (([string]$settings['steam_settings/steam_appid.txt']).Trim()) '325610' 'Attila app ID'
            Assert-GoldEqual (([string]$settings['steam_settings/force_language.txt']).Trim()) 'english' 'matching language'
            Assert-GoldTrue ($settings.Contains('steam_settings/DLC.txt')) 'explicit DLC allowlist required'
            Assert-GoldEqual ([string]$settings['steam_settings/DLC.txt']) '' 'no implicit unlock-all DLC behavior'
            Assert-GoldTrue ($settings.Contains('steam_settings/disable_overlay.txt')) 'overlay disabled'
            Assert-GoldTrue (-not $settings.Contains('steam_settings/offline.txt')) 'offline mode must not disable LAN behavior'
            Assert-GoldTrue (-not $settings.Contains('steam_settings/disable_networking.txt')) 'networking must remain enabled'
            Assert-GoldTrue (-not [string]::IsNullOrWhiteSpace([string]$settings['local_save.txt'])) 'local save folder must be explicit'
            Assert-GoldTrue ([string]$settings['steam_settings/steam_interfaces.txt'] -match 'SteamUser017') 'original interface generation is retained'
        }
        Assert-GoldTrue ([string]$hostSettings['steam_settings/force_steamid.txt'] -ne [string]$clientSettings['steam_settings/force_steamid.txt']) 'HOST and CLIENT need different local IDs'
        Assert-GoldTrue ([string]$hostSettings['steam_settings/force_account_name.txt'] -ne [string]$clientSettings['steam_settings/force_account_name.txt']) 'roles need visible distinct names'
        Assert-GoldEqual (([string]$hostSettings['steam_settings/force_listen_port.txt']).Trim()) '47584' 'HOST port'
        Assert-GoldEqual (([string]$clientSettings['steam_settings/force_listen_port.txt']).Trim()) '47585' 'CLIENT port'
        Assert-GoldEqual (([string]$hostSettings['steam_settings/custom_broadcasts.txt']).Trim()) '127.0.0.1:47585' 'HOST targets CLIENT port'
        Assert-GoldEqual (([string]$clientSettings['steam_settings/custom_broadcasts.txt']).Trim()) '127.0.0.1:47584' 'CLIENT targets HOST port'
    }

    Invoke-GoldCheck 'Game inventory is bounded and preserves literal filenames' {
        $fixture = New-GoldSourceFixture 'inventory'
        $inventory = Get-GoldbergTreeInventory -SourceRoot $fixture.source
        Assert-GoldEqual $inventory.files.Count 4 'source file count'
        $expectedBytes = [long]0
        foreach ($file in (Get-ChildItem -LiteralPath $fixture.source -Recurse -File)) { $expectedBytes += $file.Length }
        Assert-GoldEqual $inventory.total_bytes $expectedBytes 'source byte total'
        Assert-GoldTrue (@($inventory.files | Where-Object { $_.relative_path -match '\[extra\]\.pack$' }).Count -eq 1) 'literal bracket filename'
        Assert-GoldThrows { Get-GoldbergTreeInventory -SourceRoot $fixture.source -MaxEntries 1 } 'entry budget'
        Assert-GoldThrows { Get-GoldbergTreeInventory -SourceRoot $fixture.source -MaxTotalBytes ($expectedBytes - 1) } 'byte budget'
    }

    Invoke-GoldCheck 'Profile importer retains ordered owned mod directives and excludes startup or unresolved commands' {
        $fixture = New-GoldSourceFixture 'mod-import'
        Write-GoldFixture (Join-Path $fixture.source 'extra_mods/second.pack') 'EXTRA-PACK'
        $destination = Join-Path $fixture.lab 'games/HOST'
        Copy-GoldbergGameTree -SourceRoot $fixture.source -DestinationRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST | Out-Null
        $inputScript = @(
            'campaign_load "do-not-load.save";',
            'mod "[extra].pack";',
            'startpos "do-not-start";',
            'add_working_directory "extra_mods";',
            'mod "second.pack";',
            'quit;',
            'mod "test.pack";'
        ) -join "`r`n"
        $imported = Get-GoldbergModScript -Text $inputScript -SourceGameRoot $fixture.source -CopiedGameRoot $destination
        $mapped = Join-Path $destination 'extra_mods'
        $expected = @('mod "[extra].pack";', ('add_working_directory "' + $mapped + '";'), 'mod "second.pack";', 'mod "test.pack";') -join "`r`n"
        Assert-GoldEqual $imported.status 'FILTERED_DIRECTIVES_READY_NOT_RUNTIME_VERIFIED' 'narrow import is not runtime proof'
        Assert-GoldEqual $imported.text $expected 'mod order and copied working-directory mapping'
        Assert-GoldEqual $imported.excluded_lines 3 'startup, load and quit directives excluded'
        $external = Join-Path $fixture.root 'external-mods'
        Write-GoldFixture (Join-Path $external 'test.pack') 'external pack'
        $invalidScripts = @(
            'mod "../test.pack";',
            'mod "missing.pack";',
            'mod "test.pack"; quit;',
            (('add_working_directory "' + $external.Replace('\', '/') + '";') + "`r`n" + 'mod "test.pack";')
        )
        foreach ($invalid in $invalidScripts) {
            $rejected = Get-GoldbergModScript -Text $invalid -SourceGameRoot $fixture.source -CopiedGameRoot $destination
            Assert-GoldEqual $rejected.status 'MODS_NOT_CONFIGURED' 'unresolved or unsupported mod input'
            Assert-GoldEqual $rejected.text '' 'no partial executable directives on unresolved input'
        }
        Write-GoldFixture (Join-Path $destination 'extra_mods/test.pack') 'duplicate basename'
        $ambiguous = Get-GoldbergModScript -Text ('add_working_directory "extra_mods";' + "`r`n" + 'mod "test.pack";') -SourceGameRoot $fixture.source -CopiedGameRoot $destination
        Assert-GoldEqual $ambiguous.status 'MODS_NOT_CONFIGURED' 'conflicting pack locations'
        Assert-GoldEqual $ambiguous.text '' 'ambiguous pack selection yields no executable directives'
    }

    Invoke-GoldCheck 'Copy ownership rejects unrelated and differently owned existing destinations' {
        $fixture = New-GoldSourceFixture 'ownership'
        $destination = Join-Path $fixture.lab 'games/HOST'
        Initialize-GoldbergCopyRoot -DestinationRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST
        $marker = Join-Path $destination '.mk1212-goldberg-copy.json'
        $originalMarker = [System.IO.File]::ReadAllText($marker)
        Initialize-GoldbergCopyRoot -DestinationRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST
        Assert-GoldEqual ([System.IO.File]::ReadAllText($marker)) $originalMarker 'repeated setup preserves marker'
        Assert-GoldThrows { Initialize-GoldbergCopyRoot -DestinationRoot $destination -LabRoot $fixture.lab -LabId ([Guid]::NewGuid().ToString('N')) -Role HOST } 'different owner ID'
        Assert-GoldThrows { Initialize-GoldbergCopyRoot -DestinationRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role CLIENT } 'different role'
        Assert-GoldEqual ([System.IO.File]::ReadAllText($marker)) $originalMarker 'rejections preserve original owner'
        $unowned = Join-Path $fixture.lab 'unowned'
        Write-GoldFixture (Join-Path $unowned 'keep.txt') 'existing user data'
        Assert-GoldThrows { Initialize-GoldbergCopyRoot -DestinationRoot $unowned -LabRoot $fixture.lab -LabId $fixture.id -Role HOST } 'nonempty unowned directory'
        Assert-GoldEqual ([System.IO.File]::ReadAllText((Join-Path $unowned 'keep.txt'))) 'existing user data' 'unowned content retained'
        Assert-GoldThrows { Initialize-GoldbergCopyRoot -DestinationRoot (Join-Path $fixture.root 'outside') -LabRoot $fixture.lab -LabId $fixture.id -Role HOST } 'destination outside lab'
        $unknown = $originalMarker | ConvertFrom-Json
        $unknown.schema = 999
        Write-GoldFixture $marker ($unknown | ConvertTo-Json -Depth 5)
        Assert-GoldThrows { Initialize-GoldbergCopyRoot -DestinationRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST } 'unknown ownership schema'
        Assert-GoldEqual (([System.IO.File]::ReadAllText($marker) | ConvertFrom-Json).schema) 999 'unknown state must not be rewritten'
    }

    Invoke-GoldCheck 'Two full game copies preserve every source byte and do not share mutable files' {
        $fixture = New-GoldSourceFixture 'two-copies'
        $sourceBefore = Get-GoldFixtureHashes -Root $fixture.source
        $hostRoot = Join-Path $fixture.lab 'games/HOST'
        $clientRoot = Join-Path $fixture.lab 'games/CLIENT'
        $first = Copy-GoldbergGameTree -SourceRoot $fixture.source -DestinationRoot $hostRoot -LabRoot $fixture.lab -LabId $fixture.id -Role HOST
        $second = Copy-GoldbergGameTree -SourceRoot $fixture.source -DestinationRoot $clientRoot -LabRoot $fixture.lab -LabId $fixture.id -Role CLIENT
        foreach ($result in @($first, $second)) {
            Assert-GoldEqual $result.status 'COPIED_VERIFIED' 'verified copy status'
            Assert-GoldEqual $result.files.Count $sourceBefore.Count 'verified copy file count'
        }
        foreach ($relative in $sourceBefore.Keys) {
            Assert-GoldEqual ((Get-FileHash -LiteralPath (Join-Path $hostRoot $relative) -Algorithm SHA256).Hash.ToLowerInvariant()) $sourceBefore[$relative] ('HOST copy ' + $relative)
            Assert-GoldEqual ((Get-FileHash -LiteralPath (Join-Path $clientRoot $relative) -Algorithm SHA256).Hash.ToLowerInvariant()) $sourceBefore[$relative] ('CLIENT copy ' + $relative)
        }
        # An in-place write exposes unsafe NTFS hardlink sharing, unlike replacement.
        $hostApi = Join-Path $hostRoot 'steam_api.dll'
        $stream = [System.IO.File]::Open($hostApi, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $stream.WriteByte(0x58); $stream.Flush() } finally { $stream.Dispose() }
        Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $fixture.source) $sourceBefore 'source unchanged after HOST in-place mutation'
        Assert-GoldEqual ((Get-FileHash -LiteralPath (Join-Path $clientRoot 'steam_api.dll') -Algorithm SHA256).Hash.ToLowerInvariant()) $sourceBefore['steam_api.dll'] 'CLIENT does not share HOST file storage'
    }

    Invoke-GoldCheck 'Owned copy resume accepts matching files and preserves a conflicting destination' {
        $fixture = New-GoldSourceFixture 'resume'
        $destination = Join-Path $fixture.lab 'games/HOST'
        Copy-GoldbergGameTree -SourceRoot $fixture.source -DestinationRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST | Out-Null
        $before = Get-GoldFixtureHashes -Root $destination
        $repeat = Copy-GoldbergGameTree -SourceRoot $fixture.source -DestinationRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST
        Assert-GoldEqual $repeat.status 'COPIED_VERIFIED' 'identical owned resume'
        Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $destination) $before 'matching resume leaves all bytes unchanged'
        $conflict = Join-Path $destination 'data/test.pack'
        Write-GoldFixture $conflict 'KEEP-ME!'
        Assert-GoldThrows { Copy-GoldbergGameTree -SourceRoot $fixture.source -DestinationRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST } 'conflicting owned destination'
        Assert-GoldEqual ([System.IO.File]::ReadAllText($conflict)) 'KEEP-ME!' 'existing different copy is not overwritten'
        Assert-GoldEqual ([System.IO.File]::ReadAllText((Join-Path $fixture.source 'data/test.pack'))) 'PACK-ONE' 'original source remains intact'
    }

    Invoke-GoldCheck 'Source changes between peers cannot produce a silently accepted second build' {
        $fixture = New-GoldSourceFixture 'between-peers'
        $hostRoot = Join-Path $fixture.lab 'games/HOST'
        $clientRoot = Join-Path $fixture.lab 'games/CLIENT'
        $first = Copy-GoldbergGameTree -SourceRoot $fixture.source -DestinationRoot $hostRoot -LabRoot $fixture.lab -LabId $fixture.id -Role HOST
        $expected = @{}
        foreach ($record in $first.files) { $expected[$record.relative_path] = $record.sha256 }
        Write-GoldFixture (Join-Path $fixture.source 'data/test.pack') 'EDIT-TWO'
        $changedSource = Get-GoldFixtureHashes -Root $fixture.source
        Assert-GoldThrows { Copy-GoldbergGameTree -SourceRoot $fixture.source -DestinationRoot $clientRoot -LabRoot $fixture.lab -LabId $fixture.id -Role CLIENT -ExpectedSourceHashes $expected } 'same-size source change between copies'
        Assert-GoldEqual ([System.IO.File]::ReadAllText((Join-Path $hostRoot 'data/test.pack'))) 'PACK-ONE' 'first copy remains the original snapshot'
        Assert-GoldTrue (-not (Test-Path -LiteralPath (Join-Path $clientRoot 'data/test.pack'))) 'mismatched second file cannot be published as complete'
        Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $fixture.source) $changedSource 'failed second copy does not rewrite changed source'
    }

    Invoke-GoldCheck 'Emulator installation backs up only copied files and preserves the original game and settings' {
        $fixture = New-GoldSourceFixture 'install-settings'
        Write-GoldFixture (Join-Path $fixture.source 'steam_settings/offline.txt') 'old source setting'
        Write-GoldFixture (Join-Path $fixture.source 'local_save.txt') 'original_save_folder'
        $before = Get-GoldFixtureHashes -Root $fixture.source
        $destination = Join-Path $fixture.lab 'games/HOST'
        Copy-GoldbergGameTree -SourceRoot $fixture.source -DestinationRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST | Out-Null
        $payloadRoot = Join-Path $fixture.lab 'tools'
        $payload = Join-Path $payloadRoot 'steam_api.dll'
        Expand-GoldbergVerifiedDll -ArchivePath $GoldbergArchivePath -Lock $goldLock -DLLDestination $payload -DestinationRoot $payloadRoot | Out-Null
        $interfaces = Get-GoldbergInterfaces -OriginalDll (Join-Path $fixture.source 'steam_api.dll')
        Assert-GoldThrows { Install-GoldbergCopySettings -GameRoot $fixture.source -LabRoot $fixture.lab -LabId $fixture.id -Role HOST -GoldbergDllPath $payload -OriginalDllHash $before['steam_api.dll'] -InterfaceLines $interfaces } 'original installation cannot be a configuration target'
        $settings = Install-GoldbergCopySettings -GameRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST -GoldbergDllPath $payload -OriginalDllHash $before['steam_api.dll'] -InterfaceLines $interfaces
        Assert-GoldEqual $settings.status 'CONFIGURED' 'owned copy configuration'
        Assert-GoldEqual ((Get-FileHash -LiteralPath (Join-Path $destination 'steam_api.dll') -Algorithm SHA256).Hash.ToLowerInvariant()) $goldLock.dll.sha256 'copied game uses pinned emulator'
        Assert-GoldEqual ((Get-FileHash -LiteralPath (Join-Path $fixture.lab 'backups/HOST/steam_api.dll') -Algorithm SHA256).Hash.ToLowerInvariant()) $before['steam_api.dll'] 'copied original API is backed up'
        Assert-GoldEqual ([System.IO.File]::ReadAllText((Join-Path $fixture.lab 'backups/HOST/steam_settings/offline.txt'))) 'old source setting' 'previous copied configuration retained'
        Assert-GoldTrue (-not (Test-Path -LiteralPath (Join-Path $destination 'steam_settings/offline.txt'))) 'old offline setting cannot leak into new config'
        Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $fixture.source) $before 'installation never modifies original game/settings'
        Assert-GoldbergConfiguredCopy -GameRoot $destination -LabId $fixture.id -Role HOST -ExecutableHash $before['Attila.exe'] -DllHash $goldLock.dll.sha256 -InterfaceLines $interfaces
        $configuredBefore = Get-GoldFixtureHashes -Root $destination
        Install-GoldbergCopySettings -GameRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST -GoldbergDllPath $payload -OriginalDllHash $before['steam_api.dll'] -InterfaceLines $interfaces | Out-Null
        Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $destination) $configuredBefore 'repeated configuration preserves existing bytes'
        Write-GoldFixture (Join-Path $destination 'steam_settings/disable_networking.txt') ''
        Assert-GoldThrows { Assert-GoldbergConfiguredCopy -GameRoot $destination -LabId $fixture.id -Role HOST -ExecutableHash $before['Attila.exe'] -DllHash $goldLock.dll.sha256 -InterfaceLines $interfaces } 'conflicting network flag prevents launch acceptance'
    }

    Invoke-GoldCheck 'Pinned archive extracts exactly the reviewed x86 DLL and preserves prior output' {
        Assert-GoldEqual ((Get-Item -LiteralPath $GoldbergArchivePath).Length) $goldLock.archive.bytes 'official ZIP length'
        Assert-GoldEqual ((Get-FileHash -LiteralPath $GoldbergArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()) $goldLock.archive.sha256 'official ZIP digest'
        $destinationRoot = Join-Path $goldTemp 'verified-payload'
        [void][System.IO.Directory]::CreateDirectory($destinationRoot)
        $destination = Join-Path $destinationRoot 'steam_api.dll'
        $result = Expand-GoldbergVerifiedDll -ArchivePath $GoldbergArchivePath -Lock $goldLock -DLLDestination $destination -DestinationRoot $destinationRoot
        Assert-GoldEqual $result.status 'EXTRACTED' 'first payload extraction'
        Assert-GoldEqual $result.bytes $goldLock.dll.bytes 'pinned DLL length'
        Assert-GoldEqual $result.sha256 $goldLock.dll.sha256 'pinned DLL digest'
        Assert-GoldEqual $result.machine 332 'pinned DLL is x86'
        Assert-GoldEqual (@(Get-ChildItem -LiteralPath $destinationRoot -Recurse -File).Count) 1 'only one reviewed DLL is extracted'
        $repeat = Expand-GoldbergVerifiedDll -ArchivePath $GoldbergArchivePath -Lock $goldLock -DLLDestination $destination -DestinationRoot $destinationRoot
        Assert-GoldEqual $repeat.status 'VERIFIED_EXISTING' 'identical payload can be reused'
        Write-GoldFixture $destination 'pre-existing different payload'
        Assert-GoldThrows { Expand-GoldbergVerifiedDll -ArchivePath $GoldbergArchivePath -Lock $goldLock -DLLDestination $destination -DestinationRoot $destinationRoot } 'different existing DLL'
        Assert-GoldEqual ([System.IO.File]::ReadAllText($destination)) 'pre-existing different payload' 'conflicting DLL retained'
    }

    Invoke-GoldCheck 'Archive corruption, an incorrect entry digest and path escape fail before producing a DLL' {
        $destinationRoot = Join-Path $goldTemp 'bad-payload'
        [void][System.IO.Directory]::CreateDirectory($destinationRoot)
        $corruptArchive = Join-Path $goldTemp 'corrupt-archive.zip'
        [System.IO.File]::Copy($GoldbergArchivePath, $corruptArchive, $false)
        $stream = [System.IO.File]::Open($corruptArchive, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try { $original = $stream.ReadByte(); $stream.Position = 0; $stream.WriteByte([byte]($original -bxor 1)) } finally { $stream.Dispose() }
        $destination = Join-Path $destinationRoot 'steam_api.dll'
        Assert-GoldThrows { Expand-GoldbergVerifiedDll -ArchivePath $corruptArchive -Lock $goldLock -DLLDestination $destination -DestinationRoot $destinationRoot } 'corrupted locked ZIP'
        Assert-GoldTrue (-not (Test-Path -LiteralPath $destination)) 'corrupt archive must not produce a DLL'
        $wrongLock = $goldLock | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $wrongLock.dll.sha256 = '0' * 64
        Assert-GoldThrows { Expand-GoldbergVerifiedDll -ArchivePath $GoldbergArchivePath -Lock $wrongLock -DLLDestination $destination -DestinationRoot $destinationRoot } 'incorrect locked DLL digest'
        Assert-GoldTrue (-not (Test-Path -LiteralPath $destination)) 'wrong entry digest must not produce a DLL'
        $outside = Join-Path $goldTemp 'escaped.dll'
        Assert-GoldThrows { Expand-GoldbergVerifiedDll -ArchivePath $GoldbergArchivePath -Lock $goldLock -DLLDestination $outside -DestinationRoot $destinationRoot } 'payload destination escape'
        Assert-GoldTrue (-not (Test-Path -LiteralPath $outside)) 'no escaped DLL write'
    }

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Invoke-GoldCheck 'An otherwise matching copied file cannot be resumed through a hardlink' {
            $fixture = New-GoldSourceFixture 'hardlink'
            $destination = Join-Path $fixture.lab 'games/HOST'
            Copy-GoldbergGameTree -SourceRoot $fixture.source -DestinationRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST | Out-Null
            $linked = Join-Path $destination 'steam_api.dll'
            $outside = Join-Path $fixture.root 'external-original.dll'
            [System.IO.File]::Copy($linked, $outside, $false)
            $before = (Get-FileHash -LiteralPath $outside -Algorithm SHA256).Hash
            Remove-Item -LiteralPath $linked -Force
            New-Item -ItemType HardLink -Path $linked -Target $outside | Out-Null
            Assert-GoldThrows { Copy-GoldbergGameTree -SourceRoot $fixture.source -DestinationRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST } 'hardlinked retained copy'
            Assert-GoldEqual ((Get-FileHash -LiteralPath $outside -Algorithm SHA256).Hash) $before 'external hardlink target is untouched'
        }

        Invoke-GoldCheck 'Junction source content and junction copy destinations are refused' {
            $fixture = New-GoldSourceFixture 'junction'
            $outside = Join-Path $fixture.root 'outside'
            Write-GoldFixture (Join-Path $outside 'keep.txt') 'outside tree'
            $sourceJunction = Join-Path $fixture.source 'external'
            New-Item -ItemType Junction -Path $sourceJunction -Target $outside | Out-Null
            try { Assert-GoldThrows { Get-GoldbergTreeInventory -SourceRoot $fixture.source } 'source junction' }
            finally { [System.IO.Directory]::Delete($sourceJunction) }
            $destination = Join-Path $fixture.lab 'linked-destination'
            New-Item -ItemType Junction -Path $destination -Target $outside | Out-Null
            try { Assert-GoldThrows { Initialize-GoldbergCopyRoot -DestinationRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST } 'destination junction' }
            finally { [System.IO.Directory]::Delete($destination) }
            Assert-GoldEqual ([System.IO.File]::ReadAllText((Join-Path $outside 'keep.txt'))) 'outside tree' 'junction target preserved'
        }

        Invoke-GoldCheck 'Native launch honors the copied-game working directory and raw Sandboxie switches' {
            $workingDirectory = Join-Path $goldTemp 'Game Copy [with spaces]'
            [void][System.IO.Directory]::CreateDirectory($workingDirectory)
            $shellExecutable = (Get-Process -Id $PID).Path
            $result = Invoke-LabNative -Executable $shellExecutable -WorkingDirectory $workingDirectory -Arguments @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Write([System.IO.Directory]::GetCurrentDirectory())')
            Assert-GoldEqual $result.ExitCode 0 'child shell exit code'
            Assert-GoldEqual $result.Output $workingDirectory 'actual child working directory'
            $launchArguments = Join-LabWindowsArguments -Arguments @('/box:MK1212GoldHost', (Join-Path $workingDirectory 'Attila.exe'))
            Assert-GoldTrue ($launchArguments.StartsWith('/box:MK1212GoldHost "')) 'Sandboxie switch raw, copied executable quoted'
        }

        Invoke-GoldCheck 'Actual missing-environment preflight preserves the source and cannot claim multiplayer' {
            $runtimeFullPath = [System.IO.Path]::GetFullPath($RuntimeDirectory)
            $runtimeDrive = [System.IO.Path]::GetPathRoot($runtimeFullPath).TrimEnd('\')
            if ($runtimeDrive -ieq [Environment]::GetEnvironmentVariable('SystemDrive')) { throw 'CLI fixture requires the Windows CI checkout outside the system drive.' }
            $cliBase = Join-Path $runtimeFullPath ('synthetic-goldberg-preflight-' + [Guid]::NewGuid().ToString('N'))
            $source = Join-Path $cliBase 'Original Attila'
            $lab = Join-Path $cliBase 'owned-lab'
            $missingSandboxie = Join-Path $cliBase 'missing-sandboxie'
            New-GoldPeFixture -Path (Join-Path $source 'Attila.exe')
            New-GoldPeFixture -Path (Join-Path $source 'steam_api.dll') -Payload "SteamUser017`0"
            Write-GoldFixture (Join-Path $source 'data/test.pack') 'original pack'
            $sourceBefore = Get-GoldFixtureHashes -Root $source
            try {
                $shellExecutable = (Get-Process -Id $PID).Path
                $result = Invoke-LabNative -Executable $shellExecutable -TimeoutSeconds 45 -Arguments @(
                    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $runtimeFullPath 'goldberg_client_lab.ps1'),
                    '-Mode', 'Preflight', '-GameRoot', $source, '-LabRoot', $lab,
                    '-SandboxieRoot', $missingSandboxie, '-GoldbergArchive', $GoldbergArchivePath
                )
                Assert-GoldEqual $result.ExitCode 2 'missing runtime dependency exit code'
                Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $source) $sourceBefore 'actual CLI cannot change source'
                $reports = @(Get-ChildItem -LiteralPath $lab -Recurse -File -Filter 'report.json' -ErrorAction SilentlyContinue)
                Assert-GoldEqual $reports.Count 1 'one explicit preflight report'
                $report = [System.IO.File]::ReadAllText($reports[0].FullName) | ConvertFrom-Json
                Assert-GoldEqual $report.status 'BLOCKED' 'missing Sandboxie status'
                Assert-GoldEqual $report.multiplayer 'NOT_RUN' 'no multiplayer inference'
                Assert-GoldTrue (-not (Test-Path -LiteralPath (Join-Path $lab 'games/HOST/Attila.exe'))) 'preflight cannot create a game copy'
                Assert-GoldTrue (-not (Test-Path -LiteralPath (Join-Path $lab 'games/CLIENT/Attila.exe'))) 'preflight cannot create a second game copy'
            }
            finally { if (Test-Path -LiteralPath $cliBase) { Remove-Item -LiteralPath $cliBase -Recurse -Force } }
        }
    }
    else { throw 'Goldberg operator tests require Windows PowerShell 5.1 or PowerShell 7 on Windows; no Windows checks may silently skip in CI.' }
}
finally {
    if (Test-Path -LiteralPath $goldTemp) { Remove-Item -LiteralPath $goldTemp -Recurse -Force }
}

Write-Host ('Goldberg client lab checks: {0} run, {1} failed. Attila/Goldberg multiplayer NOT RUN.' -f $script:GoldbergChecks, $script:GoldbergFailures.Count)
if ($script:GoldbergFailures.Count -gt 0) { throw ($script:GoldbergFailures -join [Environment]::NewLine) }
