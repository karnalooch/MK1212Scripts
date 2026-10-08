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

function New-GoldWorkshopFixture {
    param([string]$Name)
    $fixture = New-GoldSourceFixture $Name
    $workshop = Join-Path $fixture.root 'Steam Library [mods]/steamapps/workshop/content/325610'
    $firstDirectory = Join-Path $workshop '1001'
    $secondDirectory = Join-Path $workshop '1002'
    $firstPack = Join-Path $firstDirectory 'mk1212_z.pack'
    $secondPack = Join-Path $secondDirectory 'mk1212_a.pack'
    Write-GoldFixture $firstPack 'WORKSHOP-Z'
    Write-GoldFixture $secondPack 'WORKSHOP-A'
    Write-GoldFixture (Join-Path $firstDirectory 'visible_companion.pack') 'VISIBLE-COMPANION'
    Write-GoldFixture (Join-Path $workshop '1003/unselected.pack') 'UNSELECTED'
    $profile = Join-Path $fixture.root 'Original profile [user]/scripts'
    $userScript = Join-Path $profile 'user.script.txt'
    $usedMods = Join-Path $profile 'used_mods.txt'
    $scriptText = @(
        ('add_working_directory "' + $firstDirectory + '";'),
        ('add_working_directory "' + $secondDirectory + '";'),
        'mod "mk1212_z.pack";',
        'mod "test.pack";',
        'mod "mk1212_a.pack";'
    ) -join "`r`n"
    Write-GoldFixture $userScript $scriptText
    return [pscustomobject]@{
        fixture = $fixture; workshop = $workshop; profile = $profile
        first_directory = $firstDirectory; second_directory = $secondDirectory
        first_pack = $firstPack; second_pack = $secondPack
        user_script = $userScript; used_mods = $usedMods; script_text = $scriptText
    }
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

    Invoke-GoldCheck 'Role layout permits an owned copy on the system drive and rejects source or peer overlap' {
        $layoutFixture = New-GoldSourceFixture 'split-layout'
        $runtimeFullPath = [System.IO.Path]::GetFullPath($RuntimeDirectory)
        $layoutLab = Join-Path $runtimeFullPath ('synthetic-layout-' + [Guid]::NewGuid().ToString('N'))
        $hostRoot = Join-Path $layoutFixture.root 'HOST/game'
        $clientRoot = Join-Path $layoutLab 'games/CLIENT'
        Assert-GoldEqual ([System.IO.Path]::GetPathRoot($hostRoot).TrimEnd('\')) ([Environment]::GetEnvironmentVariable('SystemDrive')) 'HOST fixture exercises the Windows system drive'
        Assert-GoldbergLayout -SourceRoot $layoutFixture.source -LabRoot $layoutLab -HostGameRoot $hostRoot -ClientGameRoot $clientRoot | Out-Null
        Assert-GoldbergLayout -SourceRoot $layoutFixture.source -LabRoot $layoutLab -HostGameRoot (Join-Path $layoutLab 'games/HOST') -ClientGameRoot (Join-Path $layoutLab 'games/CLIENT') | Out-Null
        Assert-GoldThrows { Assert-GoldbergLayout -SourceRoot $layoutFixture.source -LabRoot $layoutLab -HostGameRoot $hostRoot -ClientGameRoot $hostRoot } 'identical role roots'
        Assert-GoldThrows { Assert-GoldbergLayout -SourceRoot $layoutFixture.source -LabRoot $layoutLab -HostGameRoot $hostRoot -ClientGameRoot (Join-Path $hostRoot 'nested-client') } 'nested role roots'
        Assert-GoldThrows { Assert-GoldbergLayout -SourceRoot $layoutFixture.source -LabRoot $layoutLab -HostGameRoot (Join-Path $layoutFixture.source 'HOST') -ClientGameRoot $clientRoot } 'copy inside source installation'
        Assert-GoldThrows { Assert-GoldbergLayout -SourceRoot $layoutFixture.source -LabRoot $layoutLab -HostGameRoot $layoutFixture.root -ClientGameRoot $clientRoot } 'copy root containing original installation'
        Assert-GoldThrows { Assert-GoldbergLayout -SourceRoot $layoutFixture.source -LabRoot $layoutLab -HostGameRoot $runtimeFullPath -ClientGameRoot $clientRoot } 'copy root containing laboratory metadata'
        Assert-GoldThrows { Assert-GoldbergLayout -SourceRoot $layoutFixture.source -LabRoot $layoutLab -HostGameRoot ([System.IO.Path]::GetPathRoot($hostRoot)) -ClientGameRoot $clientRoot } 'whole system drive cannot become an owned game copy'
    }

    Invoke-GoldCheck 'Disk space is reserved per physical volume without pooling free space or repeating its reserve' {
        $requirements = @(
            [pscustomobject]@{ path = 'C:\Host/game'; missing_bytes = [long]10 },
            [pscustomobject]@{ path = 'D:\Client/game'; missing_bytes = [long]20 }
        )
        $sameVolume = @(
            [pscustomobject]@{ root = 'C:\'; volume_id = 'fixture-shared'; available_bytes = [long]35 },
            [pscustomobject]@{ root = 'D:\'; volume_id = 'fixture-shared'; available_bytes = [long]35 }
        )
        $same = Get-GoldbergVolumeBudget -Requirements $requirements -AvailableVolumes $sameVolume -ReserveBytes 5
        Assert-GoldEqual $same.volumes.Count 1 'two drive roots on one physical volume share one budget'
        Assert-GoldEqual $same.volumes[0].missing_bytes 30 'same-volume copy bytes sum'
        Assert-GoldEqual $same.volumes[0].required_bytes 35 'same-volume reserve is added once'
        $separate = @(
            [pscustomobject]@{ root = 'C:\'; volume_id = 'fixture-c'; available_bytes = [long]15 },
            [pscustomobject]@{ root = 'D:\'; volume_id = 'fixture-d'; available_bytes = [long]25 }
        )
        $split = Get-GoldbergVolumeBudget -Requirements $requirements -AvailableVolumes $separate -ReserveBytes 5
        Assert-GoldEqual $split.volumes.Count 2 'separate volumes each have a budget'
        $hostBudget = @($split.volumes | Where-Object { $_.volume_id -eq 'fixture-c' })
        $clientBudget = @($split.volumes | Where-Object { $_.volume_id -eq 'fixture-d' })
        Assert-GoldEqual $hostBudget[0].required_bytes 15 'HOST volume exact inclusive boundary'
        Assert-GoldEqual $clientBudget[0].required_bytes 25 'CLIENT volume exact inclusive boundary'
        $separate[0].available_bytes = [long]1000000
        $separate[1].available_bytes = [long]24
        Assert-GoldThrows { Get-GoldbergVolumeBudget -Requirements $requirements -AvailableVolumes $separate -ReserveBytes 5 } 'spare HOST capacity cannot cover a CLIENT volume shortage'
        $extraOnHost = @($requirements) + @([pscustomobject]@{ path = 'C:\Lab/evidence'; missing_bytes = [long]1 })
        Assert-GoldThrows { Get-GoldbergVolumeBudget -Requirements $extraOnHost -AvailableVolumes $sameVolume -ReserveBytes 5 } 'all directories on a shared volume contribute to the required bytes'
        Assert-GoldThrows { Get-GoldbergVolumeBudget -Requirements @([pscustomobject]@{ path = 'E:\Unknown/game'; missing_bytes = [long]1 }) -AvailableVolumes $sameVolume -ReserveBytes 0 } 'unobserved volume cannot be assigned guessed free space'
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

    Invoke-GoldCheck 'Original interface scan follows the pinned generator order including repeated and multiple SteamClient versions' {
        $path = Join-Path $goldTemp 'interfaces/original.dll'
        # Upstream emits prefix groups, retaining every match in its byte order.
        # Its loader applies the last matching line, not the numerically highest.
        New-GoldPeFixture -Path $path -Payload "SteamUser017`0SteamClient020`0SteamUtils007`0SteamClient006`0SteamUser018`0SteamClient006`0STEAMAPPS_INTERFACE_VERSION006`0"
        $before = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $interfaces = Get-GoldbergInterfaces -OriginalDll $path
        $expected = @('SteamClient020', 'SteamClient006', 'SteamClient006', 'SteamUser017', 'SteamUser018', 'SteamUtils007', 'STEAMAPPS_INTERFACE_VERSION006')
        Assert-GoldEqual ($interfaces -join '|') ($expected -join '|') 'original generator prefix grouping, byte order and duplicates are retained exactly'
        $clientLines = @($interfaces | Where-Object { $_ -like 'SteamClient*' })
        Assert-GoldEqual $clientLines[-1] 'SteamClient006' 'last loader assignment remains lower than the largest observed version'
        $settings = Get-GoldbergPeerSettings -Role HOST -InterfaceLines $interfaces
        Assert-GoldEqual $settings['steam_settings/steam_interfaces.txt'] ($expected -join [Environment]::NewLine) 'generated configuration preserves upstream loader precedence'
        Assert-GoldEqual ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) $before 'interface scan cannot modify original DLL'
        New-GoldPeFixture -Path $path -Payload 'No supported Steam interface strings are present.'
        Assert-GoldThrows { Get-GoldbergInterfaces -OriginalDll $path } 'absent interface evidence still blocks rather than inventing versions'
    }

    Invoke-GoldCheck 'Controller interface precedence and unversioned fallback match the pinned upstream byte-string generator' {
        $path = Join-Path $goldTemp 'interfaces/controller.dll'
        New-GoldPeFixture -Path $path -Payload "STEAMCONTROLLER_INTERFACE_VERSION003`0SteamController005`0SteamClient0198`0STEAMCONTROLLER_INTERFACE_VERSION001`0STEAMCONTROLLER_INTERFACE_VERSION`0"
        $before = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $interfaces = Get-GoldbergInterfaces -OriginalDll $path
        $expected = @('SteamClient019', 'SteamController005', 'STEAMCONTROLLER_INTERFACE_VERSION003', 'STEAMCONTROLLER_INTERFACE_VERSION001')
        Assert-GoldEqual ($interfaces -join '|') ($expected -join '|') 'numbered uppercase controllers follow legacy controllers and suppress unversioned fallback'
        Assert-GoldEqual ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) $before 'numbered controller scan preserves original bytes'
        New-GoldPeFixture -Path $path -Payload "STEAMCONTROLLER_INTERFACE_VERSION`0SteamController005`0STEAMCONTROLLER_INTERFACE_VERSION`0"
        $before = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $fallback = Get-GoldbergInterfaces -OriginalDll $path
        Assert-GoldEqual ($fallback -join '|') 'SteamController005|STEAMCONTROLLER_INTERFACE_VERSION|STEAMCONTROLLER_INTERFACE_VERSION' 'all unversioned uppercase matches are emitted even when a legacy controller exists'
        Assert-GoldEqual ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) $before 'fallback scan preserves original bytes'
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

    Invoke-GoldCheck 'Active manifests preserve resolved Workshop order without searching unrelated subscriptions' {
        $modsFixture = New-GoldWorkshopFixture 'workshop-selection'
        $fixture = $modsFixture.fixture
        $sourceBefore = Get-GoldFixtureHashes -Root $fixture.source
        $workshopBefore = Get-GoldFixtureHashes -Root $modsFixture.workshop
        $profileBefore = Get-GoldFixtureHashes -Root $modsFixture.profile
        $selection = Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script
        Assert-GoldEqual $selection.status 'SELECTED_RUNTIME_UNVERIFIED' 'active mod selection is not game-runtime proof'
        Assert-GoldEqual (($selection.mods | ForEach-Object { $_.name }) -join '|') 'mk1212_z.pack|test.pack|mk1212_a.pack' 'resolved mod order is not alphabetically sorted'
        Assert-GoldEqual (@($selection.packs | Where-Object { $_.source -ieq $modsFixture.first_pack }).Count) 1 'first selected external Workshop pack is present'
        Assert-GoldEqual (@($selection.packs | Where-Object { $_.source -ieq $modsFixture.second_pack }).Count) 1 'second selected external Workshop pack is present'
        Assert-GoldEqual (@($selection.packs | Where-Object { [System.IO.Path]::GetFileName($_.source) -eq 'visible_companion.pack' }).Count) 1 'visible pack companions in a selected directory are retained'
        Assert-GoldEqual (@($selection.packs | Where-Object { [System.IO.Path]::GetFileName($_.source) -eq 'unselected.pack' }).Count) 0 'unreferenced Workshop item is not discovered by subscription guessing'
        Assert-GoldThrows { Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script -MaxEntries 1 } 'selected-directory scan obeys its entry budget'
        Assert-GoldThrows { Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script -MaxBytes 1 } 'selected Workshop bytes obey the copy budget'
        Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $fixture.source) $sourceBefore 'selection preserves original game'
        Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $modsFixture.workshop) $workshopBefore 'selection preserves Workshop files'
        Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $modsFixture.profile) $profileBefore 'selection preserves original manifest'
        Write-GoldFixture $modsFixture.used_mods $modsFixture.script_text
        $equivalent = Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script -UsedModsPath $modsFixture.used_mods
        Assert-GoldEqual (($equivalent.mods | ForEach-Object { $_.name }) -join '|') 'mk1212_z.pack|test.pack|mk1212_a.pack' 'equivalent active manifests agree'
        $lateDirectories = @(
            'mod "mk1212_z.pack";',
            ('add_working_directory "' + $modsFixture.first_directory + '";'),
            'mod "test.pack";',
            ('add_working_directory "' + $modsFixture.second_directory + '";'),
            'mod "mk1212_a.pack";'
        ) -join "`r`n"
        Write-GoldFixture $modsFixture.user_script $lateDirectories
        $late = Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script -UsedModsPath $modsFixture.used_mods
        Assert-GoldEqual (($late.mods | ForEach-Object { $_.name }) -join '|') 'mk1212_z.pack|test.pack|mk1212_a.pack' 'all declared directories are resolved before ordered mods'
    }

    Invoke-GoldCheck 'An explicitly selected ModsRoot relocates Workshop item directories without using old source paths' {
        $modsFixture = New-GoldWorkshopFixture 'workshop-relocation'
        $fixture = $modsFixture.fixture
        $oldRoot = Join-Path $fixture.root 'Unavailable Library/steamapps/workshop/content/325610'
        $movedRoot = Join-Path $fixture.root 'Moved Workshop/content/325610'
        foreach ($pair in @(@($modsFixture.first_directory, '1001'), @($modsFixture.second_directory, '1002'))) {
            $targetDirectory = Join-Path $movedRoot $pair[1]
            [void][System.IO.Directory]::CreateDirectory($targetDirectory)
            foreach ($file in (Get-ChildItem -LiteralPath $pair[0] -File)) { [System.IO.File]::Copy($file.FullName, (Join-Path $targetDirectory $file.Name), $false) }
        }
        $relocatedScript = @(
            ('add_working_directory "' + (Join-Path $oldRoot '1001') + '";'),
            ('add_working_directory "' + (Join-Path $oldRoot '1002') + '";'),
            'mod "mk1212_z.pack";',
            'mod "test.pack";',
            'mod "mk1212_a.pack";'
        ) -join "`r`n"
        Write-GoldFixture $modsFixture.user_script $relocatedScript
        $originalBefore = Get-GoldFixtureHashes -Root $modsFixture.workshop
        $movedBefore = Get-GoldFixtureHashes -Root $movedRoot
        Assert-GoldThrows { Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script } 'unavailable manifest directories require an explicit new mod root'
        $selection = Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script -ModsRoot $movedRoot
        Assert-GoldEqual (($selection.mods | ForEach-Object { $_.name }) -join '|') 'mk1212_z.pack|test.pack|mk1212_a.pack' 'relocation retains active load order'
        Assert-GoldEqual (@($selection.mods | Where-Object { $_.name -eq 'mk1212_z.pack' })[0].source) (Join-Path $movedRoot '1001/mk1212_z.pack') 'Workshop item ID maps the first pack into the selected root'
        Assert-GoldEqual (@($selection.mods | Where-Object { $_.name -eq 'mk1212_a.pack' })[0].source) (Join-Path $movedRoot '1002/mk1212_a.pack') 'Workshop item ID maps the second pack into the selected root'
        foreach ($pack in @($selection.packs | Where-Object { $_.external })) { Assert-GoldTrue (Test-LabPathContained -Root $movedRoot -Path $pack.source) 'all relocated external assets remain inside the selected ModsRoot' }
        Write-GoldFixture $modsFixture.user_script $modsFixture.script_text
        $explicitRoot = Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script -ModsRoot $movedRoot
        Assert-GoldEqual (@($explicitRoot.mods | Where-Object { $_.name -eq 'mk1212_z.pack' })[0].source) (Join-Path $movedRoot '1001/mk1212_z.pack') 'the selected root is honored even when the old Workshop folder still exists'
        Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $modsFixture.workshop) $originalBefore 'relocation preserves original Workshop files'
        Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $movedRoot) $movedBefore 'relocation reads selected files without modifying them'
    }

    Invoke-GoldCheck 'A custom ModsRoot permits only bounded unique resolution and preserves explicit directory authority' {
        $modsFixture = New-GoldWorkshopFixture 'custom-mod-root'
        $fixture = $modsFixture.fixture
        $customRoot = Join-Path $fixture.root 'User selected mods [custom]'
        $alpha = Join-Path $customRoot 'nested/alpha'
        $beta = Join-Path $customRoot 'nested/beta'
        Write-GoldFixture (Join-Path $alpha 'mk1212_z.pack') 'CUSTOM-Z'
        Write-GoldFixture (Join-Path $alpha 'companion.pack') 'CUSTOM-COMPANION'
        Write-GoldFixture (Join-Path $beta 'mk1212_a.pack') 'CUSTOM-A'
        $activeOrder = @('mod "mk1212_a.pack";', 'mod "mk1212_z.pack";', 'mod "test.pack";') -join "`r`n"
        Write-GoldFixture $modsFixture.user_script $activeOrder
        $selection = Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script -ModsRoot $customRoot
        Assert-GoldEqual (($selection.mods | ForEach-Object { $_.name }) -join '|') 'mk1212_a.pack|mk1212_z.pack|test.pack' 'unique custom-root discovery preserves manifest order'
        Assert-GoldEqual (@($selection.mods | Where-Object { $_.name -eq 'mk1212_z.pack' })[0].source) (Join-Path $alpha 'mk1212_z.pack') 'custom source is selected instead of another installed subscription'
        Assert-GoldEqual (@($selection.packs | Where-Object { [System.IO.Path]::GetFileName($_.source) -eq 'companion.pack' }).Count) 1 'custom-folder visible companions follow the selected pack'
        $copiedRoot = Join-Path $fixture.lab 'game'
        $scriptText = Get-GoldbergSelectedModScript -Selection $selection -GameRoot $copiedRoot
        Assert-GoldTrue (-not $scriptText.Contains($customRoot)) 'generated profile cannot point back to original custom mods'
        foreach ($directory in @($selection.directories | Where-Object { $_.explicit })) {
            Assert-GoldTrue ($scriptText.Contains(('add_working_directory "' + (Join-Path $copiedRoot $directory.relative_path) + '";'))) 'generated profile maps each active directory into the owned game copy'
        }
        Assert-GoldTrue ($scriptText.EndsWith($activeOrder)) 'generated profile retains the exact ordered mod directives'
        Assert-GoldThrows { Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script -ModsRoot $customRoot -MaxEntries 1 } 'recursive custom-root discovery obeys its entry bound'
        Assert-GoldThrows { Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script -ModsRoot (Join-Path $customRoot 'missing') } 'missing selected custom root'
        Write-GoldFixture (Join-Path $customRoot 'another/mk1212_z.pack') 'DUPLICATE-Z'
        $before = Get-GoldFixtureHashes -Root $customRoot
        Assert-GoldThrows { Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script -ModsRoot $customRoot } 'recursive discovery cannot choose the first duplicate basename'
        Write-GoldFixture $modsFixture.user_script (('add_working_directory "' + $alpha + '";') + "`r`n" + 'mod "mk1212_z.pack";')
        $declared = Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script -ModsRoot $customRoot
        Assert-GoldEqual $declared.mods[0].source (Join-Path $alpha 'mk1212_z.pack') 'an exact active directory resolves its pack despite an unrelated duplicate in ModsRoot'
        Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $customRoot) $before 'successful and blocked custom resolution preserve source assets'
    }

    Invoke-GoldCheck 'Missing, malformed and conflicting active manifests block instead of selecting vanilla' {
        $modsFixture = New-GoldWorkshopFixture 'workshop-invalid-manifests'
        $fixture = $modsFixture.fixture
        $missing = Join-Path $modsFixture.profile 'missing.txt'
        Assert-GoldThrows { Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $missing -UsedModsPath (Join-Path $modsFixture.profile 'also-missing.txt') } 'no active manifest exists'
        Write-GoldFixture $modsFixture.used_mods $modsFixture.script_text
        Write-GoldFixture $modsFixture.user_script 'mod "mk1212_z.pack"; quit;'
        Assert-GoldThrows { Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script -UsedModsPath $modsFixture.used_mods } 'malformed user script cannot be masked by valid used_mods'
        Write-GoldFixture $modsFixture.user_script $modsFixture.script_text
        $reverse = @(
            ('add_working_directory "' + $modsFixture.first_directory + '";'),
            ('add_working_directory "' + $modsFixture.second_directory + '";'),
            'mod "mk1212_a.pack";',
            'mod "test.pack";',
            'mod "mk1212_z.pack";'
        ) -join "`r`n"
        Write-GoldFixture $modsFixture.used_mods $reverse
        Assert-GoldThrows { Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script -UsedModsPath $modsFixture.used_mods } 'conflicting active load order'
        foreach ($text in @('mod "missing.pack";', 'mod "../test.pack";')) {
            Write-GoldFixture $modsFixture.user_script $text
            Assert-GoldThrows { Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script } 'missing or escaping selected pack'
        }
        Assert-GoldTrue (-not (Test-Path -LiteralPath (Join-Path $fixture.lab 'games'))) 'rejected selection cannot create game copies'
    }

    Invoke-GoldCheck 'Ambiguous pack basenames across data and selected Workshop directories are rejected' {
        $modsFixture = New-GoldWorkshopFixture 'workshop-collisions'
        $fixture = $modsFixture.fixture
        Write-GoldFixture (Join-Path $modsFixture.first_directory 'shared.pack') 'FIRST-CONTENT'
        Write-GoldFixture (Join-Path $modsFixture.second_directory 'shared.pack') 'OTHER-CONTENT'
        $ambiguous = @(
            ('add_working_directory "' + $modsFixture.first_directory + '";'),
            ('add_working_directory "' + $modsFixture.second_directory + '";'),
            'mod "shared.pack";'
        ) -join "`r`n"
        Write-GoldFixture $modsFixture.user_script $ambiguous
        $before = Get-GoldFixtureHashes -Root $modsFixture.workshop
        Assert-GoldThrows { Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script } 'same basename in two visible Workshop directories'
        Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $modsFixture.workshop) $before 'collision preserves both Workshop candidates'
        Write-GoldFixture (Join-Path $modsFixture.first_directory 'test.pack') 'WORKSHOP-DUPLICATE'
        Write-GoldFixture $modsFixture.user_script (('add_working_directory "' + $modsFixture.first_directory + '";') + "`r`n" + 'mod "test.pack";')
        Assert-GoldThrows { Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script } 'Workshop basename collides with an installed data pack'
    }

    Invoke-GoldCheck 'Selected Workshop files are independent physical copies with unchanged sources and peer parity' {
        $modsFixture = New-GoldWorkshopFixture 'workshop-copies'
        $fixture = $modsFixture.fixture
        $sourceBefore = Get-GoldFixtureHashes -Root $fixture.source
        $workshopBefore = Get-GoldFixtureHashes -Root $modsFixture.workshop
        $profileBefore = Get-GoldFixtureHashes -Root $modsFixture.profile
        $selection = Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script
        $copyLab = Join-Path ([System.IO.Path]::GetFullPath($RuntimeDirectory)) ('synthetic-workshop-copy-' + [Guid]::NewGuid().ToString('N'))
        $hostRoot = Join-Path $fixture.root 'HOST/game'
        $clientRoot = Join-Path $copyLab 'CLIENT/game'
        Assert-GoldTrue ([System.IO.Path]::GetPathRoot($hostRoot) -ine [System.IO.Path]::GetPathRoot($clientRoot)) 'physical copy fixture exercises two Windows drive roots'
        try {
            Assert-GoldbergLayout -SourceRoot $fixture.source -LabRoot $copyLab -HostGameRoot $hostRoot -ClientGameRoot $clientRoot | Out-Null
            Copy-GoldbergGameTree -SourceRoot $fixture.source -DestinationRoot $hostRoot -LabRoot $copyLab -LabId $fixture.id -Role HOST -RoleGameRoot $hostRoot | Out-Null
            Copy-GoldbergGameTree -SourceRoot $fixture.source -DestinationRoot $clientRoot -LabRoot $copyLab -LabId $fixture.id -Role CLIENT -RoleGameRoot $clientRoot | Out-Null
            $hostCopy = Copy-GoldbergSelectedMods -Selection $selection -GameRoot $hostRoot -LabRoot $copyLab -LabId $fixture.id -Role HOST -RoleGameRoot $hostRoot
            $clientCopy = Copy-GoldbergSelectedMods -Selection $selection -GameRoot $clientRoot -LabRoot $copyLab -LabId $fixture.id -Role CLIENT -RoleGameRoot $clientRoot
            foreach ($result in @($hostCopy, $clientCopy)) {
                Assert-GoldEqual $result.status 'COPIED_VERIFIED' 'selected Workshop copy verified'
                Assert-GoldEqual $result.fingerprint $selection.fingerprint 'both copies carry the same selected-mod identity'
            }
            foreach ($record in $selection.packs) {
                Assert-GoldEqual (Get-GoldbergDigest -Path (Join-Path $hostRoot $record.relative_path)) $record.sha256 ('HOST selected pack ' + $record.relative_path)
                Assert-GoldEqual (Get-GoldbergDigest -Path (Join-Path $clientRoot $record.relative_path)) $record.sha256 ('CLIENT selected pack ' + $record.relative_path)
            }
            Assert-GoldEqual (@(Get-ChildItem -LiteralPath $hostRoot -Recurse -File -Filter 'unselected.pack').Count) 0 'unselected Workshop item is not copied'
            Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $fixture.source) $sourceBefore 'Workshop copy preserves original installation'
            Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $modsFixture.workshop) $workshopBefore 'Workshop copy preserves original mod assets'
            Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $modsFixture.profile) $profileBefore 'Workshop copy preserves original load order'
            $firstRecord = @($selection.packs | Where-Object { $_.source -ieq $modsFixture.first_pack })[0]
            $hostPack = Join-Path $hostRoot $firstRecord.relative_path
            $stream = [System.IO.File]::Open($hostPack, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $stream.WriteByte(0x58); $stream.Flush() } finally { $stream.Dispose() }
            Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $modsFixture.workshop) $workshopBefore 'in-place HOST mutation cannot reach Workshop originals through hardlinks'
            Assert-GoldEqual (Get-GoldbergDigest -Path (Join-Path $clientRoot $firstRecord.relative_path)) $firstRecord.sha256 'CLIENT selected pack does not share HOST storage'
        }
        finally { if (Test-Path -LiteralPath $copyLab) { Remove-Item -LiteralPath $copyLab -Recurse -Force } }
    }

    Invoke-GoldCheck 'Workshop resume preserves conflicts and rejects a same-size source change after selection' {
        $modsFixture = New-GoldWorkshopFixture 'workshop-resume'
        $fixture = $modsFixture.fixture
        $selection = Get-GoldbergActiveModSelection -SourceGameRoot $fixture.source -UserScriptPath $modsFixture.user_script
        $destination = Join-Path $fixture.lab 'games/HOST'
        Copy-GoldbergGameTree -SourceRoot $fixture.source -DestinationRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST | Out-Null
        Copy-GoldbergSelectedMods -Selection $selection -GameRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST | Out-Null
        $before = Get-GoldFixtureHashes -Root $destination
        Copy-GoldbergSelectedMods -Selection $selection -GameRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST | Out-Null
        Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $destination) $before 'identical selected-mod resume leaves bytes unchanged'
        $record = @($selection.packs | Where-Object { $_.source -ieq $modsFixture.first_pack })[0]
        $conflict = Join-Path $destination $record.relative_path
        Write-GoldFixture $conflict 'KEEP-THIS-EXISTING-MOD'
        Assert-GoldThrows { Copy-GoldbergSelectedMods -Selection $selection -GameRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST } 'different retained Workshop copy'
        Assert-GoldEqual ([System.IO.File]::ReadAllText($conflict)) 'KEEP-THIS-EXISTING-MOD' 'conflicting destination remains available for review'
        $clientRoot = Join-Path $fixture.lab 'games/CLIENT'
        Copy-GoldbergGameTree -SourceRoot $fixture.source -DestinationRoot $clientRoot -LabRoot $fixture.lab -LabId $fixture.id -Role CLIENT | Out-Null
        Write-GoldFixture $modsFixture.first_pack ('X' * [int]$record.bytes)
        $changedSource = Get-GoldFixtureHashes -Root $modsFixture.workshop
        Assert-GoldThrows { Copy-GoldbergSelectedMods -Selection $selection -GameRoot $clientRoot -LabRoot $fixture.lab -LabId $fixture.id -Role CLIENT } 'selected Workshop bytes changed before second copy'
        Assert-GoldTrue (-not (Test-Path -LiteralPath (Join-Path $clientRoot $record.relative_path))) 'changed selected pack cannot be published as verified'
        Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $modsFixture.workshop) $changedSource 'failed CLIENT copy never rewrites the changed Workshop source'
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
        $destination = Join-Path $fixture.root 'Authorized HOST/game'
        Copy-GoldbergGameTree -SourceRoot $fixture.source -DestinationRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST -RoleGameRoot $destination | Out-Null
        $payloadRoot = Join-Path $fixture.lab 'tools'
        $payload = Join-Path $payloadRoot 'steam_api.dll'
        Expand-GoldbergVerifiedDll -ArchivePath $GoldbergArchivePath -Lock $goldLock -DLLDestination $payload -DestinationRoot $payloadRoot | Out-Null
        $interfaces = Get-GoldbergInterfaces -OriginalDll (Join-Path $fixture.source 'steam_api.dll')
        Assert-GoldThrows { Install-GoldbergCopySettings -GameRoot $fixture.source -LabRoot $fixture.lab -LabId $fixture.id -Role HOST -GoldbergDllPath $payload -OriginalDllHash $before['steam_api.dll'] -InterfaceLines $interfaces } 'original installation cannot be a configuration target'
        $settings = Install-GoldbergCopySettings -GameRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST -GoldbergDllPath $payload -OriginalDllHash $before['steam_api.dll'] -InterfaceLines $interfaces -RoleGameRoot $destination
        Assert-GoldEqual $settings.status 'CONFIGURED' 'owned copy configuration'
        Assert-GoldTrue (Test-LabPathContained -Root $destination -Path $settings.backup) 'explicit role backups remain on the copied-game volume'
        Assert-GoldEqual ((Get-FileHash -LiteralPath (Join-Path $destination 'steam_api.dll') -Algorithm SHA256).Hash.ToLowerInvariant()) $goldLock.dll.sha256 'copied game uses pinned emulator'
        Assert-GoldEqual ((Get-FileHash -LiteralPath (Join-Path $settings.backup 'steam_api.dll') -Algorithm SHA256).Hash.ToLowerInvariant()) $before['steam_api.dll'] 'copied original API is backed up'
        Assert-GoldEqual ([System.IO.File]::ReadAllText((Join-Path $settings.backup 'steam_settings/offline.txt'))) 'old source setting' 'previous copied configuration retained'
        Assert-GoldTrue (-not (Test-Path -LiteralPath (Join-Path $destination 'steam_settings/offline.txt'))) 'old offline setting cannot leak into new config'
        Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $fixture.source) $before 'installation never modifies original game/settings'
        Assert-GoldbergConfiguredCopy -GameRoot $destination -LabId $fixture.id -Role HOST -ExecutableHash $before['Attila.exe'] -DllHash $goldLock.dll.sha256 -InterfaceLines $interfaces
        $configuredBefore = Get-GoldFixtureHashes -Root $destination
        Install-GoldbergCopySettings -GameRoot $destination -LabRoot $fixture.lab -LabId $fixture.id -Role HOST -GoldbergDllPath $payload -OriginalDllHash $before['steam_api.dll'] -InterfaceLines $interfaces -RoleGameRoot $destination | Out-Null
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
            $hostRoot = Join-Path $goldTemp 'CLI HOST/game'
            $clientRoot = Join-Path $cliBase 'CLIENT/game'
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
                    '-HostGameRoot', $hostRoot, '-ClientGameRoot', $clientRoot,
                    '-SandboxieRoot', $missingSandboxie, '-GoldbergArchive', $GoldbergArchivePath
                )
                Assert-GoldEqual $result.ExitCode 2 'missing runtime dependency exit code'
                Assert-GoldHashMaps (Get-GoldFixtureHashes -Root $source) $sourceBefore 'actual CLI cannot change source'
                $reports = @(Get-ChildItem -LiteralPath $lab -Recurse -File -Filter 'report.json' -ErrorAction SilentlyContinue)
                Assert-GoldEqual $reports.Count 1 'one explicit preflight report'
                $report = [System.IO.File]::ReadAllText($reports[0].FullName) | ConvertFrom-Json
                Assert-GoldEqual $report.status 'BLOCKED' 'missing Sandboxie status'
                Assert-GoldEqual $report.multiplayer 'NOT_RUN' 'no multiplayer inference'
                Assert-GoldTrue (($report.reasons -join ' ') -match 'Sandboxie') 'preflight reaches the dependency check with the C:/D: role layout accepted'
                $state = [System.IO.File]::ReadAllText((Join-Path $lab '.mk1212-goldberg-lab.json')) | ConvertFrom-Json
                Assert-GoldEqual $state.schema 2 'explicit split roots use the versioned state schema'
                Assert-GoldEqual (@($state.roles | Where-Object { $_.role -eq 'HOST' })[0].game_root) $hostRoot 'saved HOST root is the explicitly authorized C: destination'
                Assert-GoldEqual (@($state.roles | Where-Object { $_.role -eq 'CLIENT' })[0].game_root) $clientRoot 'saved CLIENT root is the explicitly authorized D: destination'
                Assert-GoldTrue (-not (Test-Path -LiteralPath (Join-Path $hostRoot 'Attila.exe'))) 'preflight cannot create a game copy'
                Assert-GoldTrue (-not (Test-Path -LiteralPath (Join-Path $clientRoot 'Attila.exe'))) 'preflight cannot create a second game copy'
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
