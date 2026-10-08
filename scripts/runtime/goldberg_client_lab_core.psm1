# Operator-only Goldberg laboratory helpers; PowerShell 5.1 and 7.
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'dual_client_lab_core.psm1') -DisableNameChecking

function Test-GoldbergRootsDisjoint {
    param([Parameter(Mandatory = $true)][string]$SourceRoot, [Parameter(Mandatory = $true)][string]$LabRoot)
    return (-not (Test-LabPathContained -Root $SourceRoot -Path $LabRoot)) -and (-not (Test-LabPathContained -Root $LabRoot -Path $SourceRoot))
}

function Assert-GoldbergLayout {
    param([string]$SourceRoot, [string]$LabRoot, [string]$HostGameRoot, [string]$ClientGameRoot)
    $paths = @($SourceRoot, $LabRoot, $HostGameRoot, $ClientGameRoot)
    foreach ($path in $paths) {
        if ($path -notmatch '^[A-Za-z]:[\\/]' -or $path -match '[%\r\n]') { throw 'Laboratory paths must be explicit local Windows drive paths.' }
        $full = [IO.Path]::GetFullPath($path).TrimEnd([char[]]@('\', '/'))
        if ($full -ieq [IO.Path]::GetPathRoot($full).TrimEnd('\')) { throw 'A whole drive cannot be used as a laboratory directory.' }
        Assert-LabNoReparsePath -Path $full
    }
    if (-not (Test-GoldbergRootsDisjoint -SourceRoot $SourceRoot -LabRoot $LabRoot)) { throw 'Original installation and laboratory metadata paths overlap.' }
    foreach ($roleRoot in @($HostGameRoot, $ClientGameRoot)) {
        if (-not (Test-GoldbergRootsDisjoint -SourceRoot $SourceRoot -LabRoot $roleRoot)) { throw 'An owned game copy overlaps the original installation.' }
        if (Test-LabPathContained -Root $roleRoot -Path $LabRoot) { throw 'A game copy cannot contain laboratory metadata.' }
        foreach ($systemPath in @([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows), [Environment]::GetFolderPath([Environment+SpecialFolder]::System))) {
            if ($systemPath -and (Test-LabPathContained -Root $systemPath -Path $roleRoot)) { throw 'A game copy cannot be placed in a Windows system directory.' }
        }
    }
    if (-not (Test-GoldbergRootsDisjoint -SourceRoot $HostGameRoot -LabRoot $ClientGameRoot)) { throw 'HOST and CLIENT game directories overlap.' }
}

function Get-GoldbergVolumeBudget {
    param([object[]]$Requirements, [object[]]$AvailableVolumes, [long]$ReserveBytes = 1073741824)
    if ($ReserveBytes -lt 0) { throw 'Invalid per-volume reserve.' }
    $byRoot = @{}; $groups = @{}
    foreach ($volume in $AvailableVolumes) {
        $root = [IO.Path]::GetPathRoot([string]$volume.root).ToUpperInvariant()
        if (-not $root -or -not $volume.volume_id -or [long]$volume.available_bytes -lt 0 -or $byRoot.ContainsKey($root)) { throw 'Ambiguous available-volume record.' }
        $byRoot[$root] = $volume
    }
    foreach ($requirement in $Requirements) {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath([string]$requirement.path)).ToUpperInvariant()
        if (-not $byRoot.ContainsKey($root) -or [long]$requirement.missing_bytes -lt 0) { throw 'Missing volume identity or invalid copy budget.' }
        $volume = $byRoot[$root]; $id = [string]$volume.volume_id
        if (-not $groups.ContainsKey($id)) { $groups[$id] = [pscustomobject]@{ volume_id = $id; roots = @(); missing_bytes = [long]0; reserve_bytes = $ReserveBytes; required_bytes = [long]0; available_bytes = [long]$volume.available_bytes } }
        $group = $groups[$id]
        if ($group.roots -notcontains $root) { $group.roots += $root }
        $group.available_bytes = [Math]::Min([long]$group.available_bytes, [long]$volume.available_bytes)
        if ($group.missing_bytes -gt ([long]::MaxValue - [long]$requirement.missing_bytes)) { throw 'Per-volume copy budget overflow.' }
        $group.missing_bytes += [long]$requirement.missing_bytes
    }
    foreach ($group in $groups.Values) { $group.required_bytes = Assert-GoldbergDiskBudget -MissingBytes $group.missing_bytes -AvailableBytes $group.available_bytes -ReserveBytes $ReserveBytes }
    return [pscustomobject]@{ volumes = @($groups.Values | Sort-Object volume_id) }
}

function Assert-GoldbergDiskBudget {
    param([long]$MissingBytes, [long]$AvailableBytes, [long]$ReserveBytes = 1073741824)
    if ($MissingBytes -lt 0 -or $AvailableBytes -lt 0 -or $ReserveBytes -lt 0 -or $MissingBytes -gt ([long]::MaxValue - $ReserveBytes)) { throw 'Invalid disk-space budget.' }
    $required = $MissingBytes + $ReserveBytes
    if ($AvailableBytes -lt $required) { throw ('Not enough free disk space: required ' + $required + ' bytes; available ' + $AvailableBytes + '.') }
    return $required
}

function Get-GoldbergDigest {
    param([Parameter(Mandatory = $true)][string]$Path, [long]$MaxBytes = 17179869184)
    Assert-LabNoReparsePath -Path $Path
    $info = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($info.PSIsContainer -or $info.Length -gt $MaxBytes) { throw ('File is outside the hashing contract: ' + $Path) }
    $stream = $null; $algorithm = $null
    try {
        $stream = New-Object System.IO.FileStream -ArgumentList $info.FullName, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
        if ($stream.Length -gt $MaxBytes) { throw 'File grew beyond the hashing limit.' }
        $algorithm = [Security.Cryptography.SHA256]::Create()
        $hash = $algorithm.ComputeHash($stream)
        return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($null -ne $algorithm) { $algorithm.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-GoldbergPeMachine {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-LabNoReparsePath -Path $Path
    $stream = $null; $reader = $null
    try {
        $stream = New-Object System.IO.FileStream -ArgumentList $Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
        $reader = New-Object System.IO.BinaryReader -ArgumentList $stream
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) { throw 'Missing DOS executable header.' }
        $stream.Position = 0x3c
        $offset = $reader.ReadUInt32()
        if ($offset -lt 64 -or $offset -gt ($stream.Length - 24)) { throw 'Invalid PE header offset.' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw 'Missing PE signature.' }
        return [int]$reader.ReadUInt16()
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-GoldbergPeerSettings {
    param([Parameter(Mandatory = $true)][ValidateSet('HOST', 'CLIENT')][string]$Role, [string[]]$InterfaceLines = @(), [ValidatePattern('^[a-z_]{2,32}$')][string]$Language = 'english')
    $isHost = $Role -eq 'HOST'
    $settings = [ordered]@{
        'local_save.txt' = 'goldberg_saves'
        'steam_settings/steam_appid.txt' = '325610'
        'steam_settings/force_account_name.txt' = ('MK1212_' + $Role)
        'steam_settings/force_steamid.txt' = $(if ($isHost) { '76561198000012121' } else { '76561198000012122' })
        'steam_settings/force_language.txt' = $Language
        'steam_settings/force_listen_port.txt' = $(if ($isHost) { '47584' } else { '47585' })
        'steam_settings/custom_broadcasts.txt' = $(if ($isHost) { '127.0.0.1:47585' } else { '127.0.0.1:47584' })
        'steam_settings/DLC.txt' = ''
        'steam_settings/disable_overlay.txt' = ''
    }
    if ($InterfaceLines.Count -gt 0) { $settings['steam_settings/steam_interfaces.txt'] = ($InterfaceLines -join [Environment]::NewLine) }
    return $settings
}

function Get-GoldbergInterfaces {
    param([Parameter(Mandatory = $true)][string]$OriginalDll)
    Assert-LabNoReparsePath -Path $OriginalDll
    $item = Get-Item -LiteralPath $OriginalDll -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -gt 67108864) { throw 'Original Steam API is outside the interface-scanning limit.' }
    $ascii = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($item.FullName))
    $prefixes = @('SteamClient', 'SteamGameServer', 'SteamGameServerStats', 'SteamUser', 'SteamFriends', 'SteamUtils', 'SteamMatchMaking', 'SteamMatchMakingServers', 'STEAMUSERSTATS_INTERFACE_VERSION', 'STEAMAPPS_INTERFACE_VERSION', 'SteamNetworking', 'STEAMREMOTESTORAGE_INTERFACE_VERSION', 'STEAMSCREENSHOTS_INTERFACE_VERSION', 'STEAMHTTP_INTERFACE_VERSION', 'STEAMUNIFIEDMESSAGES_INTERFACE_VERSION', 'STEAMUGC_INTERFACE_VERSION', 'STEAMAPPLIST_INTERFACE_VERSION', 'STEAMMUSIC_INTERFACE_VERSION', 'STEAMMUSICREMOTE_INTERFACE_VERSION', 'STEAMHTMLSURFACE_INTERFACE_VERSION_', 'STEAMINVENTORY_INTERFACE_V', 'SteamController', 'SteamMasterServerUpdater', 'STEAMVIDEO_INTERFACE_V', 'STEAMCONTROLLER_INTERFACE_VERSION')
    $found = New-Object 'System.Collections.Generic.List[string]'
    $controller = New-Object 'System.Collections.Generic.List[string]'
    foreach ($prefix in $prefixes) {
        $versions = @([regex]::Matches($ascii, ([regex]::Escape($prefix) + '[0-9]{3}(?![0-9])')) | ForEach-Object { $_.Value } | Sort-Object -Unique)
        if ($versions.Count -gt 1) { throw ('Conflicting original Steam interface versions: ' + $prefix) }
        if ($versions.Count -eq 1) {
            if ($prefix -eq 'SteamController' -or $prefix -eq 'STEAMCONTROLLER_INTERFACE_VERSION') { $controller.Add($versions[0]) }
            $found.Add($versions[0])
        }
    }
    if ($controller.Count -gt 1) { throw 'Conflicting controller interface families in original Steam API.' }
    if ($controller.Count -eq 0 -and $ascii.Contains('STEAMCONTROLLER_INTERFACE_VERSION')) { $found.Add('STEAMCONTROLLER_INTERFACE_VERSION') }
    if ($found.Count -eq 0) { throw 'No supported original Steam interface strings were observed; do not guess versions.' }
    return ,($found.ToArray())
}

function Get-GoldbergTreeInventory {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [ValidateRange(1, 100000)][int]$MaxEntries = 100000,
        [long]$MaxTotalBytes = 214748364800
    )
    if ($MaxTotalBytes -lt 1) { throw 'Invalid game byte budget.' }
    $root = [IO.Path]::GetFullPath($SourceRoot).TrimEnd([char[]]@('\', '/'))
    Assert-LabNoReparsePath -Path $root
    $scan = Get-LabFilesBounded -Root $root -MaxEntries $MaxEntries -MaxDepth 32
    if ($scan.Truncated -or $scan.Warnings.Count -gt 0) { throw ('Game tree is incomplete, unreadable or contains reparse points: ' + ($scan.Warnings -join '; ')) }
    $files = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [long]$total = 0
    foreach ($file in ($scan.Files | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($root.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
        if (-not $seen.Add($relative) -or $relative -eq '.mk1212-goldberg-copy.json' -or $relative -eq '.mk1212-goldberg-settings.json' -or $relative -match '^\.mk1212-(workshop|goldberg-backups)(/|$)') { throw 'Source tree has ambiguous or reserved laboratory paths.' }
        if ($file.Length -lt 0 -or $file.Length -gt 17179869184 -or $total -gt ($MaxTotalBytes - $file.Length)) { throw 'Game tree exceeds its byte budget.' }
        $total += $file.Length
        $files.Add([pscustomobject]@{ relative_path = $relative; source = $file.FullName; bytes = [long]$file.Length; last_write_ticks = $file.LastWriteTimeUtc.Ticks })
    }
    return [pscustomobject]@{ files = @($files.ToArray()); total_bytes = $total; entries = $scan.EntriesScanned }
}

function Initialize-GoldbergCopyRoot {
    param(
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][string]$LabRoot,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$LabId,
        [Parameter(Mandatory = $true)][ValidateSet('HOST', 'CLIENT')][string]$Role,
        [string]$RoleGameRoot
    )
    if ($RoleGameRoot) {
        $roleFull = [IO.Path]::GetFullPath($RoleGameRoot).TrimEnd([char[]]@('\', '/'))
        $destinationFull = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd([char[]]@('\', '/'))
        if ($destinationFull -ine $roleFull -and $destinationFull -ine ($roleFull + '.staging-' + $LabId)) { throw 'A game copy must use its exact authorized role or staging directory.' }
    } elseif (-not (Test-LabPathContained -Root $LabRoot -Path $DestinationRoot) -or [IO.Path]::GetFullPath($LabRoot) -eq [IO.Path]::GetFullPath($DestinationRoot)) { throw 'A game copy must be strictly inside its owned lab.' }
    Assert-LabNoReparsePath -Path $DestinationRoot
    $markerPath = Join-Path $DestinationRoot '.mk1212-goldberg-copy.json'
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        $marker = Read-LabJson -Path $markerPath
        if ($marker.schema -ne 1 -or $marker.owner -cne 'MK1212Scripts.goldberg-client-lab' -or $marker.lab_id -cne $LabId -or $marker.role -cne $Role) { throw 'Existing game-copy ownership does not match.' }
        return $marker
    }
    if (Test-Path -LiteralPath $DestinationRoot) {
        if (-not (Test-Path -LiteralPath $DestinationRoot -PathType Container) -or @(Get-ChildItem -LiteralPath $DestinationRoot -Force | Select-Object -First 1).Count -gt 0) { throw 'Refusing a nonempty game-copy directory without ownership.' }
    } else { [void][IO.Directory]::CreateDirectory($DestinationRoot) }
    $marker = [pscustomobject]@{ schema = 1; owner = 'MK1212Scripts.goldberg-client-lab'; lab_id = $LabId; role = $Role; created_utc = [DateTime]::UtcNow.ToString('o') }
    Write-LabJson -Path $markerPath -Value $marker
    return $marker
}

function Copy-GoldbergGameTree {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][string]$LabRoot,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$LabId,
        [Parameter(Mandatory = $true)][ValidateSet('HOST', 'CLIENT')][string]$Role,
        [ValidateRange(1, 100000)][int]$MaxEntries = 100000,
        [long]$MaxTotalBytes = 214748364800,
        $Inventory = $null,
        [hashtable]$ExpectedSourceHashes = @{},
        [string]$RoleGameRoot
    )
    if (-not (Test-GoldbergRootsDisjoint -SourceRoot $SourceRoot -LabRoot $LabRoot)) { throw 'The original game and lab paths overlap.' }
    if (-not (Test-GoldbergRootsDisjoint -SourceRoot $SourceRoot -LabRoot $DestinationRoot)) { throw 'Game-copy destination overlaps its source.' }
    [void](Initialize-GoldbergCopyRoot -DestinationRoot $DestinationRoot -LabRoot $LabRoot -LabId $LabId -Role $Role -RoleGameRoot $RoleGameRoot)
    if ($null -eq $Inventory) { $Inventory = Get-GoldbergTreeInventory -SourceRoot $SourceRoot -MaxEntries $MaxEntries -MaxTotalBytes $MaxTotalBytes }
    if ($Inventory.files.Count -gt $MaxEntries -or $Inventory.total_bytes -gt $MaxTotalBytes) { throw 'Inventory exceeds the copy budget.' }
    $results = New-Object 'System.Collections.Generic.List[object]'
    $allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$allowed.Add('.mk1212-goldberg-copy.json')
    [long]$actualTotal = 0
    [long]$progressBytes = 0
    $progressClock = [Diagnostics.Stopwatch]::StartNew()
    foreach ($record in $Inventory.files) {
        $relative = [string]$record.relative_path
        if ($relative -match '(^|[\\/])\.{1,2}([\\/]|$)|^[\\/]|^[A-Za-z]:') { throw 'Inventory contains a noncanonical relative path.' }
        $source = Join-Path $SourceRoot $relative
        $destination = Join-Path $DestinationRoot $relative
        if (-not (Test-LabPathContained -Root $SourceRoot -Path $source) -or -not (Test-LabPathContained -Root $DestinationRoot -Path $destination) -or -not $allowed.Add($relative.Replace('\', '/'))) { throw 'Inventory contains an unsafe or repeated relative path.' }
        Assert-LabNoReparsePath -Path $source
        Assert-LabNoReparsePath -Path $destination
        $sourceInfo = Get-Item -LiteralPath $source -Force -ErrorAction Stop
        if ($sourceInfo.PSIsContainer -or $sourceInfo.Length -ne [long]$record.bytes -or $sourceInfo.Length -gt 17179869184) { throw ('Source changed during preparation: ' + $relative) }
        if ($actualTotal -gt ($MaxTotalBytes - $sourceInfo.Length)) { throw 'Actual source bytes exceed the game-copy budget.' }
        $actualTotal += $sourceInfo.Length
        $parent = [IO.Path]::GetDirectoryName($destination)
        [void][IO.Directory]::CreateDirectory($parent)
        $leaf = [IO.Path]::GetFileName($destination)
        if (@([IO.Directory]::EnumerateFiles($parent, ($leaf + '.partial-*'))).Count -gt 0) { throw ('Retained partial copy requires review: ' + $destination) }
        if (Test-Path -LiteralPath $destination) {
            Assert-GoldbergSingleLinkFile -Path $destination
            $existing = Get-Item -LiteralPath $destination -Force -ErrorAction Stop
            if ($existing.PSIsContainer -or $existing.Length -ne $sourceInfo.Length) { throw ('Existing copy differs; preserved for review: ' + $destination) }
            if ($sourceInfo.Length -ge 1073741824) { Write-Host ('Verifying retained ' + $Role + ' file: ' + $relative) }
            $sourceHash = Get-GoldbergDigest -Path $source
            if ((Get-GoldbergDigest -Path $destination) -cne $sourceHash) { throw ('Existing copy hash differs; preserved for review: ' + $destination) }
            $copyStatus = 'VERIFIED_EXISTING'
        } else {
            $temporary = $destination + '.partial-' + [guid]::NewGuid().ToString('N')
            $inputFile = $null; $outputFile = $null; $algorithm = $null
            try {
                $inputFile = New-Object IO.FileStream -ArgumentList $source, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
                if ($inputFile.Length -ne $sourceInfo.Length) { throw 'Source changed before copying.' }
                $outputFile = New-Object IO.FileStream -ArgumentList $temporary, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
                $algorithm = [Security.Cryptography.SHA256]::Create()
                $buffer = New-Object byte[] 1048576
                [long]$copied = 0
                while (($read = $inputFile.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $copied += $read
                    if ($copied -gt $sourceInfo.Length) { throw 'Source grew during copying.' }
                    $outputFile.Write($buffer, 0, $read)
                    [void]$algorithm.TransformBlock($buffer, 0, $read, $buffer, 0)
                    $progressBytes += $read
                    if ($progressBytes -ge 1073741824 -or $progressClock.Elapsed.TotalSeconds -ge 10) {
                        Write-Host ('Copying ' + $Role + ': ' + $relative + ' (' + $copied + '/' + $sourceInfo.Length + ' bytes in this file)')
                        $progressBytes = 0; $progressClock.Restart()
                    }
                }
                [void]$algorithm.TransformFinalBlock((New-Object byte[] 0), 0, 0)
                if ($copied -ne $sourceInfo.Length) { throw 'Source truncated during copying.' }
                $sourceHash = ([BitConverter]::ToString($algorithm.Hash)).Replace('-', '').ToLowerInvariant()
                $outputFile.Flush(); $outputFile.Dispose(); $outputFile = $null
                if ((Get-GoldbergDigest -Path $temporary) -cne $sourceHash) { throw 'Copied file failed read-back hashing.' }
                if ($ExpectedSourceHashes.ContainsKey($relative) -and $ExpectedSourceHashes[$relative] -cne $sourceHash) { throw ('Source content changed between peers: ' + $relative) }
                [IO.File]::Move($temporary, $destination)
                $copyStatus = 'COPIED'
            } finally {
                if ($null -ne $algorithm) { $algorithm.Dispose() }
                if ($null -ne $outputFile) { $outputFile.Dispose() }
                if ($null -ne $inputFile) { $inputFile.Dispose() }
                # An interrupted .partial is intentionally retained, never adopted.
            }
        }
        if ($ExpectedSourceHashes.ContainsKey($relative) -and $ExpectedSourceHashes[$relative] -cne $sourceHash) { throw ('Source content changed between peers: ' + $relative) }
        $results.Add([pscustomobject]@{ relative_path = $relative.Replace('\', '/'); bytes = [long]$sourceInfo.Length; sha256 = $sourceHash; status = $copyStatus; source_last_write_ticks = $sourceInfo.LastWriteTimeUtc.Ticks })
    }
    $scan = Get-LabFilesBounded -Root $DestinationRoot -MaxEntries ([Math]::Min(100000, $MaxEntries + 4)) -MaxDepth 32
    if ($scan.Truncated -or $scan.Warnings.Count -gt 0) { throw 'Game copy could not be fully verified within traversal bounds.' }
    $destinationFull = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd([char[]]@('\', '/'))
    foreach ($file in $scan.Files) {
        $relative = $file.FullName.Substring($destinationFull.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
        if (-not $allowed.Contains($relative)) { throw ('Unexpected retained file prevents copy acceptance: ' + $relative) }
    }
    return [pscustomobject]@{ status = 'COPIED_VERIFIED'; total_bytes = $actualTotal; files = @($results.ToArray()) }
}

function Expand-GoldbergVerifiedDll {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)]$Lock,
        [Parameter(Mandatory = $true)][string]$DLLDestination,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )
    if ($Lock.schema -ne 1 -or $Lock.archive.sha256 -notmatch '^[0-9a-f]{64}$' -or $Lock.dll.sha256 -notmatch '^[0-9a-f]{64}$' -or $Lock.dll.entry -cne 'steam_api.dll' -or $Lock.dll.machine -ne 332) { throw 'Unsupported Goldberg lock.' }
    Assert-LabNoReparsePath -Path $ArchivePath
    $archiveInfo = Get-Item -LiteralPath $ArchivePath -ErrorAction Stop
    if ($archiveInfo.PSIsContainer -or $archiveInfo.Length -ne [long]$Lock.archive.bytes -or $archiveInfo.Length -gt 67108864 -or (Get-GoldbergDigest -Path $ArchivePath -MaxBytes 67108864) -cne $Lock.archive.sha256) { throw 'Goldberg archive failed its locked size or SHA256 check.' }
    if (-not (Test-LabPathContained -Root $DestinationRoot -Path $DLLDestination)) { throw 'Goldberg DLL destination escaped the owned tools directory.' }
    Assert-LabNoReparsePath -Path $DLLDestination
    if (Test-Path -LiteralPath $DLLDestination) {
        $item = Get-Item -LiteralPath $DLLDestination
        if ($item.PSIsContainer -or $item.Length -ne [long]$Lock.dll.bytes -or (Get-GoldbergDigest -Path $DLLDestination -MaxBytes 16777216) -cne $Lock.dll.sha256 -or (Get-GoldbergPeMachine -Path $DLLDestination) -ne 332) { throw 'Existing Goldberg DLL does not match the lock; it was preserved.' }
        return [pscustomobject]@{ path = $DLLDestination; bytes = $item.Length; sha256 = $Lock.dll.sha256; machine = 332; status = 'VERIFIED_EXISTING' }
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($DLLDestination))
    $zip = $null; $entryStream = $null; $output = $null
    $temporary = $DLLDestination + '.partial-' + [guid]::NewGuid().ToString('N')
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($archiveInfo.FullName)
        $entries = @($zip.Entries | Where-Object { $_.FullName -ceq $Lock.dll.entry })
        if ($entries.Count -ne 1 -or $entries[0].Length -ne [long]$Lock.dll.bytes -or $entries[0].Length -gt 16777216) { throw 'Goldberg ZIP has an ambiguous or invalid root x86 DLL entry.' }
        $entryStream = $entries[0].Open()
        $output = New-Object IO.FileStream -ArgumentList $temporary, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
        $buffer = New-Object byte[] 65536
        [long]$written = 0
        while (($read = $entryStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $written += $read
            if ($written -gt [long]$Lock.dll.bytes) { throw 'Goldberg DLL expanded beyond its locked size.' }
            $output.Write($buffer, 0, $read)
        }
        $output.Flush(); $output.Dispose(); $output = $null
        if ($written -ne [long]$Lock.dll.bytes -or (Get-GoldbergDigest -Path $temporary -MaxBytes 16777216) -cne $Lock.dll.sha256 -or (Get-GoldbergPeMachine -Path $temporary) -ne 332) { throw 'Extracted Goldberg DLL failed size, SHA256 or PE32 validation.' }
        [IO.File]::Move($temporary, $DLLDestination)
        return [pscustomobject]@{ path = $DLLDestination; bytes = $written; sha256 = $Lock.dll.sha256; machine = 332; status = 'EXTRACTED' }
    } finally {
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $entryStream) { $entryStream.Dispose() }
        if ($null -ne $zip) { $zip.Dispose() }
    }
}

function Get-GoldbergToolkitContext {
    param([Parameter(Mandatory = $true)][string]$ScriptDirectory, [string]$GoldbergArchive)
    $root = [IO.Path]::GetFullPath((Join-Path $ScriptDirectory '../..'))
    $fixed = @('scripts/runtime/goldberg_client_lab.ps1', 'scripts/runtime/goldberg_client_lab_core.psm1', 'scripts/runtime/dual_client_lab_core.psm1', 'scripts/runtime/dual_client_probe.ps1', 'scripts/runtime/goldberg_setup.ps1', 'third_party/goldberg/lock.json')
    $source = [ordered]@{ source_sha = 'unknown'; kind = 'local_files'; integrity = 'FILE_HASHES_ONLY'; files = @() }
    foreach ($relative in $fixed) {
        $path = Join-Path $root $relative
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        $source.files += [pscustomobject]@{ path = $relative; bytes = [long]$item.Length; sha256 = (Get-GoldbergDigest -Path $path -MaxBytes 4194304) }
    }
    $manifestPath = Join-Path $root 'package_manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Read-LabJson -Path $manifestPath
        if ($manifest.schema -ne 1 -or $manifest.source_sha -notmatch '^[0-9a-f]{40}$') { throw 'Unsupported Goldberg package manifest.' }
        foreach ($actual in $source.files) {
            $records = @($manifest.files | Where-Object { $_.path -ceq $actual.path })
            if ($records.Count -ne 1 -or $records[0].sha256 -cne $actual.sha256 -or [long]$records[0].bytes -ne $actual.bytes) { throw ('Toolkit manifest hash mismatch: ' + $actual.path) }
        }
        $source.source_sha = $manifest.source_sha; $source.kind = 'package_manifest'; $source.integrity = 'MANIFEST_FILES_MATCH'
    } else {
        $gitCommand = Get-Command git -ErrorAction SilentlyContinue
        if ($null -ne $gitCommand) {
            $revision = Invoke-LabNative -Executable $gitCommand.Source -Arguments @('-C', $root, 'rev-parse', 'HEAD')
            if ($revision.ExitCode -eq 0 -and $revision.Output.Trim() -match '^[0-9a-f]{40}$') { $source.source_sha = $revision.Output.Trim(); $source.kind = 'git_with_current_file_hashes' }
        }
    }
    $lock = Read-LabJson -Path (Join-Path $root 'third_party/goldberg/lock.json')
    if ($lock.schema -ne 1 -or $lock.source_commit -notmatch '^[0-9a-f]{40}$' -or $lock.archive.path -cne 'third_party/goldberg/goldberg-original-475342f0.zip') { throw 'Unsupported Goldberg distribution lock.' }
    $archive = $(if ($GoldbergArchive) { [IO.Path]::GetFullPath($GoldbergArchive) } else { Join-Path $root $lock.archive.path })
    return [pscustomobject]@{ root = $root; source = [pscustomobject]$source; lock = $lock; archive = $archive }
}

function Assert-GoldbergSingleLinkFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-LabNoReparsePath -Path $Path
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    if ($null -eq ('Mk1212GoldbergNative.LinkInfo' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Mk1212GoldbergNative {
    public static class LinkInfo {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInfo {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccess;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWrite;
            public uint Volume; public uint SizeHigh; public uint SizeLow;
            public uint Links; public uint IndexHigh; public uint IndexLow;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfo info);
        public static uint Count(SafeFileHandle handle) {
            FileInfo info;
            if (!GetFileInformationByHandle(handle, out info)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            return info.Links;
        }
    }
}
'@
    }
    $stream = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = New-Object IO.FileStream -ArgumentList $Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), $share
        if ([Mk1212GoldbergNative.LinkInfo]::Count($stream.SafeFileHandle) -ne 1) { throw ('Hardlinked game copies are not accepted: ' + $Path) }
    } finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Write-GoldbergManagedText {
    param([string]$Path, [AllowEmptyString()][string]$Value, [string]$Root)
    if (-not (Test-LabPathContained -Root $Root -Path $Path)) { throw 'Managed Goldberg setting escaped its game copy.' }
    Assert-LabNoReparsePath -Path $Path
    $encoding = New-Object Text.UTF8Encoding -ArgumentList $false
    $bytes = $encoding.GetBytes($Value)
    if ($bytes.Length -gt 65536) { throw 'Goldberg setting exceeds its byte budget.' }
    if (Test-Path -LiteralPath $Path) {
        Assert-GoldbergSingleLinkFile -Path $Path
        if ([IO.File]::ReadAllText($Path) -cne $Value -or (Get-Item -LiteralPath $Path).Length -ne $bytes.Length) { throw ('Existing owned setting differs; preserved for review: ' + $Path) }
        return
    }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $stream = New-Object IO.FileStream -ArgumentList $Path, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
    finally { $stream.Dispose() }
}

function Install-GoldbergCopySettings {
    param(
        [string]$GameRoot, [string]$LabRoot, [string]$LabId,
        [ValidateSet('HOST', 'CLIENT')][string]$Role,
        [string]$GoldbergDllPath, [string]$OriginalDllHash, [string[]]$InterfaceLines, [string]$Language = 'english', [string]$RoleGameRoot
    )
    [void](Initialize-GoldbergCopyRoot -DestinationRoot $GameRoot -LabRoot $LabRoot -LabId $LabId -Role $Role -RoleGameRoot $RoleGameRoot)
    $backup = $(if ($RoleGameRoot) { Join-Path $GameRoot '.mk1212-goldberg-backups' } else { Join-Path (Join-Path $LabRoot 'backups') $Role })
    Assert-LabNoReparsePath -Path $backup
    [void][IO.Directory]::CreateDirectory($backup)
    $api = Join-Path $GameRoot 'steam_api.dll'
    $originalBackup = Join-Path $backup 'steam_api.dll'
    $emulatorHash = Get-GoldbergDigest -Path $GoldbergDllPath -MaxBytes 16777216
    if (Test-Path -LiteralPath $originalBackup) {
        Assert-GoldbergSingleLinkFile -Path $originalBackup
        if ((Get-GoldbergDigest -Path $originalBackup -MaxBytes 67108864) -cne $OriginalDllHash) { throw 'Original copied Steam API backup changed.' }
    }
    if (Test-Path -LiteralPath $api) {
        Assert-GoldbergSingleLinkFile -Path $api
        $currentHash = Get-GoldbergDigest -Path $api -MaxBytes 67108864
        if ($currentHash -ceq $OriginalDllHash) {
            if (Test-Path -LiteralPath $originalBackup) { throw 'Both original DLL and backup exist; review the interrupted preparation.' }
            [IO.File]::Move($api, $originalBackup)
        } elseif ($currentHash -cne $emulatorHash -or -not (Test-Path -LiteralPath $originalBackup -PathType Leaf)) { throw 'Game-copy Steam API differs from both expected original and pinned emulator.' }
    }
    if (-not (Test-Path -LiteralPath $originalBackup -PathType Leaf)) { throw 'Cannot replace Steam API without its verified original copy backup.' }
    if (-not (Test-Path -LiteralPath $api)) { [IO.File]::Copy($GoldbergDllPath, $api, $false) }
    if ((Get-GoldbergDigest -Path $api -MaxBytes 16777216) -cne $emulatorHash) { throw 'Installed Goldberg DLL hash mismatch.' }

    $markerPath = Join-Path $GameRoot '.mk1212-goldberg-settings.json'
    $settingsDirectory = Join-Path $GameRoot 'steam_settings'
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        $marker = Read-LabJson -Path $markerPath
        if ($marker.schema -ne 1 -or $marker.owner -cne 'MK1212Scripts.goldberg-client-lab' -or $marker.lab_id -cne $LabId -or $marker.role -cne $Role -or $marker.original_api_sha256 -cne $OriginalDllHash) { throw 'Goldberg configuration ownership mismatch.' }
    } else {
        foreach ($leaf in @('steam_settings', 'local_save.txt')) {
            $original = Join-Path $GameRoot $leaf
            $saved = Join-Path $backup $leaf
            Assert-LabNoReparsePath -Path $original
            Assert-LabNoReparsePath -Path $saved
            if (Test-Path -LiteralPath $original) {
                if (Test-Path -LiteralPath $saved) { throw ('Ambiguous previous settings backup: ' + $leaf) }
                if ((Get-Item -LiteralPath $original).PSIsContainer) { [IO.Directory]::Move($original, $saved) }
                else { Assert-GoldbergSingleLinkFile -Path $original; [IO.File]::Move($original, $saved) }
            }
        }
        Write-LabJson -Path $markerPath -Value ([ordered]@{ schema = 1; owner = 'MK1212Scripts.goldberg-client-lab'; lab_id = $LabId; role = $Role; original_api_sha256 = $OriginalDllHash })
    }
    $settings = Get-GoldbergPeerSettings -Role $Role -InterfaceLines $InterfaceLines -Language $Language
    foreach ($relative in $settings.Keys) { Write-GoldbergManagedText -Path (Join-Path $GameRoot $relative) -Value $settings[$relative] -Root $GameRoot }
    $scan = Get-LabFilesBounded -Root $settingsDirectory -MaxEntries 128 -MaxDepth 2
    if ($scan.Truncated -or $scan.Warnings.Count -gt 0) { throw 'Goldberg settings scan is incomplete.' }
    foreach ($file in $scan.Files) {
        $relative = 'steam_settings/' + $file.Name
        if (-not $settings.Contains($relative) -or $file.DirectoryName -ine [IO.Path]::GetFullPath($settingsDirectory)) { throw ('Unexpected Goldberg setting is retained but blocks launch: ' + $file.FullName) }
    }
    return [pscustomobject]@{ status = 'CONFIGURED'; dll_sha256 = $emulatorHash; backup = $backup; settings = $settings }
}

function Assert-GoldbergConfiguredCopy {
    param([string]$GameRoot, [string]$LabId, [string]$Role, [string]$ExecutableHash, [string]$DllHash, [string[]]$InterfaceLines, [string]$Language = 'english')
    foreach ($leaf in @('.mk1212-goldberg-copy.json', '.mk1212-goldberg-settings.json')) {
        $marker = Read-LabJson -Path (Join-Path $GameRoot $leaf)
        if ($marker.schema -ne 1 -or $marker.owner -cne 'MK1212Scripts.goldberg-client-lab' -or $marker.lab_id -cne $LabId -or $marker.role -cne $Role) { throw 'Prepared game ownership marker changed.' }
    }
    foreach ($record in @(@('Attila.exe', $ExecutableHash), @('steam_api.dll', $DllHash))) {
        $path = Join-Path $GameRoot $record[0]
        Assert-GoldbergSingleLinkFile -Path $path
        if ((Get-GoldbergDigest -Path $path -MaxBytes 536870912) -cne $record[1] -or (Get-GoldbergPeMachine -Path $path) -ne 332) { throw ('Prepared executable changed: ' + $path) }
    }
    $settings = Get-GoldbergPeerSettings -Role $Role -InterfaceLines $InterfaceLines -Language $Language
    foreach ($relative in $settings.Keys) {
        $path = Join-Path $GameRoot $relative
        Assert-GoldbergSingleLinkFile -Path $path
        if ([IO.File]::ReadAllText($path) -cne $settings[$relative]) { throw ('Prepared Goldberg setting changed: ' + $relative) }
    }
    foreach ($leaf in @('offline.txt', 'disable_networking.txt', 'disable_lobby_creation.txt')) {
        if (Test-Path -LiteralPath (Join-Path (Join-Path $GameRoot 'steam_settings') $leaf)) { throw ('A conflicting networking setting blocks launch: ' + $leaf) }
    }
}

function Get-GoldbergPackType {
    param([string]$Path)
    $stream = $null; $reader = $null
    try {
        Assert-LabNoReparsePath -Path $Path
        $stream = New-Object IO.FileStream -ArgumentList $Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
        $reader = New-Object IO.BinaryReader -ArgumentList $stream
        if ($stream.Length -lt 8) { return -1 }
        $magic = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($magic.StartsWith('MFH')) {
            if ($stream.Length -lt 16) { return -1 }
            $stream.Position = 8; $magic = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        }
        if ($magic -notmatch '^PFH[0-9]$') { return -1 }
        return [int]($reader.ReadUInt32() -band [uint32]15)
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-GoldbergModCandidate {
    param([string]$Path, [string]$SourceGameRoot, [int]$MaxEntries, [long]$MaxBytes, [string]$ModsRoot, [object[]]$ModsFiles = @())
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = Read-LabTextBounded -Path $Path -MaxBytes 1048576
    $root = [IO.Path]::GetFullPath($SourceGameRoot).TrimEnd([char[]]@('\', '/'))
    $directories = @([pscustomobject]@{ source = (Join-Path $root 'data'); relative_path = 'data'; explicit = $false; external = $false })
    $names = @(); $excluded = 0; $ordinal = 0
    foreach ($line in [regex]::Split($text, '\r\n|\n|\r')) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('//') -or $trimmed.StartsWith('#')) { continue }
        $match = [regex]::Match($trimmed, '^(mod|add_working_directory)\s+"([^"\r\n\x00]+)"\s*;\s*$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) {
            if ($trimmed -match '^(mod|add_working_directory)\b') { throw ('Malformed active mod directive in ' + $Path) }
            $excluded++; continue
        }
        $value = $match.Groups[2].Value
        if ($match.Groups[1].Value -ieq 'mod') {
            if ($value -notmatch '^[^\\/:*?"<>|\x00]+\.pack$' -or $value.StartsWith('.') -or $names -contains $value) { throw 'Active mod directives require distinct plain pack filenames.' }
            $names += $value
        } else {
            if (-not [IO.Path]::IsPathRooted($value) -or $value -match '(^|[\\/])\.\.([\\/]|$)|[%\r\n]') { throw 'An active working directory must be an explicit absolute path without traversal.' }
            $directory = [IO.Path]::GetFullPath($value).TrimEnd([char[]]@('\', '/'))
            $external = -not (Test-LabPathContained -Root $root -Path $directory)
            if ($external -and $ModsRoot -and (-not (Test-LabPathContained -Root $ModsRoot -Path $directory) -or -not (Test-Path -LiteralPath $directory -PathType Container))) {
                $relocations = @()
                $workshopRelative = [regex]::Match($directory, '[\\/]content[\\/]325610[\\/](.+)$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($workshopRelative.Success) { $relocations += (Join-Path $ModsRoot $workshopRelative.Groups[1].Value) }
                $relocations += (Join-Path $ModsRoot ([IO.Path]::GetFileName($directory)))
                if ([IO.Path]::GetFileName($directory) -ieq [IO.Path]::GetFileName($ModsRoot)) { $relocations += $ModsRoot }
                $resolvedDirectories = @($relocations | Where-Object { (Test-LabPathContained -Root $ModsRoot -Path $_) -and (Test-Path -LiteralPath $_ -PathType Container) } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd([char[]]@('\', '/')) } | Sort-Object -Unique)
                if ($resolvedDirectories.Count -gt 1) { throw 'Moved Workshop directory has multiple possible destinations inside ModsRoot.' }
                if ($resolvedDirectories.Count -eq 1) { $directory = $resolvedDirectories[0] }
                else { $directory = 'UNRESOLVED:' + $directory }
            }
            if (-not $directory.StartsWith('UNRESOLVED:')) {
                Assert-LabNoReparsePath -Path $directory
                if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw ('Active mod working directory is missing: ' + $directory) }
            }
            if (@($directories | Where-Object { $_.source -ieq $directory }).Count -gt 0) { continue }
            $external = $directory.StartsWith('UNRESOLVED:') -or -not (Test-LabPathContained -Root $root -Path $directory)
            if ($external) { $ordinal++; $relative = ('.mk1212-workshop/{0:D4}' -f $ordinal) }
            else { $relative = $directory.Substring($root.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/') }
            $directories += [pscustomobject]@{ source = $directory; relative_path = $relative; explicit = $true; external = $external }
        }
        if ($names.Count + $directories.Count -gt 4096) { throw 'Active mod directive count exceeds its bound.' }
    }
    foreach ($directory in @($directories | Where-Object { $_.source.StartsWith('UNRESOLVED:') })) {
        $matchingDirectories = @($ModsFiles | Where-Object { $names -contains $_.Name } | ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)
        if ($matchingDirectories.Count -ne 1) { throw 'A declared moved mod directory cannot be mapped uniquely inside ModsRoot.' }
        $directory.source = $matchingDirectories[0]
    }
    $uniqueDirectories = @(); $seenDirectories = @{}
    foreach ($directory in $directories) {
        if ($seenDirectories.ContainsKey($directory.source)) { continue }
        $seenDirectories[$directory.source] = $true; $uniqueDirectories += $directory
    }
    $directories = $uniqueDirectories
    # The explicitly selected ModsRoot is the only allowed search fallback.
    # It resolves a missing named pack only when exactly one source exists.
    if ($ModsRoot) {
        foreach ($name in $names) {
            $declared = @($directories | Where-Object { Test-Path -LiteralPath (Join-Path $_.source $name) -PathType Leaf })
            if ($declared.Count -gt 0) { continue }
            $matchesInRoot = @($ModsFiles | Where-Object { $_.Name -ieq $name })
            if ($matchesInRoot.Count -ne 1) { throw ('Missing or ambiguous named pack inside selected ModsRoot: ' + $name) }
            $sourceDirectory = $matchesInRoot[0].DirectoryName
            if (@($directories | Where-Object { $_.source -ieq $sourceDirectory }).Count -eq 0) {
                $ordinal++
                $directories += [pscustomobject]@{ source = $sourceDirectory; relative_path = ('.mk1212-workshop/{0:D4}' -f $ordinal); explicit = $true; external = $true }
            }
        }
    }
    $mods = @(); $wanted = @{}; $visible = @{}; $scanned = 0
    foreach ($directory in $directories) {
        if (-not (Test-Path -LiteralPath $directory.source -PathType Container)) { continue }
        Assert-LabNoReparsePath -Path $directory.source
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory.source)) {
            $scanned++; if ($scanned -gt $MaxEntries) { throw 'Active mod directory inventory exceeds its entry bound.' }
            $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
            if ($item.PSIsContainer -or $item.Extension -ine '.pack') { continue }
            Assert-LabNoReparsePath -Path $item.FullName
            $key = $item.Name.ToLowerInvariant()
            if (-not $visible.ContainsKey($key)) { $visible[$key] = @() }
            $visible[$key] += [pscustomobject]@{ source = $item.FullName; directory = $directory; item = $item }
            # Every direct pack in an explicitly selected directory is retained:
            # Movie packs can be active without a mod directive.
            if ($directory.explicit -or (Get-GoldbergPackType -Path $item.FullName) -eq 4) { $wanted[$item.FullName] = [pscustomobject]@{ source = $item.FullName; directory = $directory; item = $item } }
        }
    }
    foreach ($name in $names) {
        $key = $name.ToLowerInvariant()
        if (-not $visible.ContainsKey($key)) { throw ('Active mod pack is missing from its declared directories: ' + $name) }
        $candidates = @($visible[$key])
        if ($candidates.Count -ne 1) { throw ('Active mod basename is ambiguous across visible directories: ' + $name) }
        $chosen = $candidates[0]; $wanted[$chosen.source] = $chosen
        $mods += [pscustomobject]@{ name = $name; source = $chosen.source; sha256 = $null }
    }
    $packs = @(); [long]$total = 0; $hashes = @{}
    foreach ($directory in $directories) {
        $records = @($wanted.Values | Where-Object { $_.directory.source -ieq $directory.source } | Sort-Object { $_.item.Name })
        foreach ($record in $records) {
            $item = $record.item
            if ($item.Length -gt 17179869184 -or $total -gt ($MaxBytes - $item.Length)) { throw 'Selected mod packs exceed their byte budget.' }
            $total += $item.Length
            if ($item.Length -ge 1073741824) { Write-Host ('Hashing selected mod source: ' + $item.FullName) }
            $digest = Get-GoldbergDigest -Path $item.FullName
            $relative = $(if ($directory.relative_path) { $directory.relative_path + '/' + $item.Name } else { $item.Name })
            $packs += [pscustomobject]@{ source = $item.FullName; source_root = $directory.source; relative_path = $relative; bytes = [long]$item.Length; sha256 = $digest; external = $directory.external }
            $hashes[$item.FullName] = $digest
        }
    }
    foreach ($mod in $mods) { $mod.sha256 = $hashes[$mod.source] }
    $semantic = [ordered]@{
        directories = @($directories | ForEach-Object { [ordered]@{ source = $_.source.ToLowerInvariant(); relative_path = $_.relative_path; explicit = $_.explicit } })
        mods = @($mods | ForEach-Object { [ordered]@{ name = $_.name.ToLowerInvariant(); source = $_.source.ToLowerInvariant(); sha256 = $_.sha256 } })
        packs = @($packs | ForEach-Object { [ordered]@{ source = $_.source.ToLowerInvariant(); relative_path = $_.relative_path.ToLowerInvariant(); bytes = $_.bytes; sha256 = $_.sha256 } })
    }
    $canonical = $semantic | ConvertTo-Json -Depth 8 -Compress
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
    return [pscustomobject]@{ status = 'SELECTED_RUNTIME_UNVERIFIED'; fingerprint = $fingerprint; packs = $packs; mods = $mods; directories = $directories; total_bytes = $total; path = [IO.Path]::GetFullPath($Path); manifest_sha256 = (Get-GoldbergDigest -Path $Path -MaxBytes 1048576); excluded_lines = $excluded; has_selection = ($names.Count -gt 0 -or @($directories | Where-Object { $_.explicit }).Count -gt 0) }
}

function Get-GoldbergActiveModSelection {
    param([string]$SourceGameRoot, [string]$UserScriptPath, [string]$UsedModsPath, [string]$ModsRoot, [ValidateRange(1, 100000)][int]$MaxEntries = 20000, [long]$MaxBytes = 107374182400)
    if ($MaxBytes -lt 1) { throw 'Invalid selected-mod byte budget.' }
    if (-not $UsedModsPath) { $UsedModsPath = Join-Path $SourceGameRoot 'used_mods.txt' }
    $candidates = @(); $modsFiles = @()
    if ($ModsRoot) {
        $ModsRoot = [IO.Path]::GetFullPath($ModsRoot).TrimEnd([char[]]@('\', '/'))
        Assert-LabNoReparsePath -Path $ModsRoot
        if (-not (Test-Path -LiteralPath $ModsRoot -PathType Container)) { throw 'Selected ModsRoot does not exist; choose the installed Workshop/custom mod folder.' }
        $scan = Get-LabFilesBounded -Root $ModsRoot -MaxEntries $MaxEntries -MaxDepth 18
        if ($scan.Truncated -or $scan.Warnings.Count -gt 0) { throw 'Selected ModsRoot search exceeds its bounds or contains unreadable/reparse paths.' }
        $modsFiles = @($scan.Files | Where-Object { $_.Extension -ieq '.pack' })
    }
    foreach ($path in @($UserScriptPath, $UsedModsPath)) {
        $candidate = Get-GoldbergModCandidate -Path $path -SourceGameRoot $SourceGameRoot -MaxEntries $MaxEntries -MaxBytes $MaxBytes -ModsRoot $ModsRoot -ModsFiles $modsFiles
        if ($null -ne $candidate) { $candidates += $candidate }
    }
    $selected = @($candidates | Where-Object { $_.has_selection })
    if ($selected.Count -eq 0) { throw 'No active mod manifest was resolved. Select the intended mods in the existing launcher first; vanilla fallback is disabled.' }
    $chosen = $selected[0]
    foreach ($candidate in $selected) { if ($candidate.fingerprint -cne $chosen.fingerprint) { throw 'user.script and used_mods select conflicting mod order, directories or files.' } }
    if ($chosen.packs.Count -eq 0) { throw 'The active manifest resolves to no pack files; vanilla fallback is disabled.' }
    return [pscustomobject]@{ schema = 1; status = 'SELECTED_RUNTIME_UNVERIFIED'; fingerprint = $chosen.fingerprint; packs = $chosen.packs; mods = $chosen.mods; directories = $chosen.directories; total_bytes = $chosen.total_bytes; manifest_sources = @($candidates | ForEach-Object { [pscustomobject]@{ path = $_.path; sha256 = $_.manifest_sha256; has_selection = $_.has_selection; excluded_lines = $_.excluded_lines } }) }
}

function Copy-GoldbergSelectedMods {
    param($Selection, [string]$GameRoot, [string]$LabRoot, [string]$LabId, [ValidateSet('HOST', 'CLIENT')][string]$Role, [string]$RoleGameRoot)
    if ($Selection.schema -ne 1 -or $Selection.fingerprint -notmatch '^[0-9a-f]{64}$' -or $Selection.packs.Count -lt 1 -or $Selection.packs.Count -gt 20000 -or [long]$Selection.total_bytes -lt 0 -or [long]$Selection.total_bytes -gt 214748364800) { throw 'Unsupported selected-mod manifest.' }
    [long]$manifestBytes = 0
    foreach ($pack in $Selection.packs) {
        if ([long]$pack.bytes -lt 0 -or [long]$pack.bytes -gt 17179869184 -or $manifestBytes -gt (214748364800 - [long]$pack.bytes)) { throw 'Selected-mod copy exceeds its total byte bound.' }
        $manifestBytes += [long]$pack.bytes
    }
    if ($manifestBytes -ne [long]$Selection.total_bytes) { throw 'Selected-mod manifest byte total is inconsistent.' }
    [void](Initialize-GoldbergCopyRoot -DestinationRoot $GameRoot -LabRoot $LabRoot -LabId $LabId -Role $Role -RoleGameRoot $RoleGameRoot)
    $results = @(); $seen = @{}
    foreach ($pack in $Selection.packs) {
        $relative = [string]$pack.relative_path
        if ($relative -match '(^|[\\/])\.{1,2}([\\/]|$)|^[\\/]|^[A-Za-z]:' -or $seen.ContainsKey($relative) -or [long]$pack.bytes -lt 0 -or [long]$pack.bytes -gt 17179869184 -or $pack.sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Invalid or colliding selected-pack destination.' }
        $seen[$relative] = $true
        $destination = Join-Path $GameRoot $relative
        if (-not (Test-LabPathContained -Root $GameRoot -Path $destination) -or (Test-LabPathContained -Root $GameRoot -Path $pack.source)) { throw 'Selected mod source/destination ownership overlaps.' }
        Assert-LabNoReparsePath -Path $pack.source
        Assert-LabNoReparsePath -Path $destination
        $sourceInfo = Get-Item -LiteralPath $pack.source -ErrorAction Stop
        if ($sourceInfo.PSIsContainer -or $sourceInfo.Length -ne [long]$pack.bytes) { throw 'Selected source pack changed size after selection.' }
        if (Test-Path -LiteralPath $destination) {
            Assert-GoldbergSingleLinkFile -Path $destination
            if ((Get-GoldbergDigest -Path $pack.source) -cne $pack.sha256 -or (Get-GoldbergDigest -Path $destination) -cne $pack.sha256) { throw ('Selected source or retained copied pack hash differs: ' + $relative) }
            $results += [pscustomobject]@{ relative_path = $relative; sha256 = $pack.sha256; bytes = $pack.bytes; status = 'VERIFIED_EXISTING' }
            continue
        }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        if (@([IO.Directory]::EnumerateFiles([IO.Path]::GetDirectoryName($destination), ([IO.Path]::GetFileName($destination) + '.partial-*'))).Count -gt 0) { throw 'An incomplete selected-mod copy is retained for review.' }
        $temporary = $destination + '.partial-' + [guid]::NewGuid().ToString('N')
        $inputFile = $null; $outputFile = $null; $algorithm = $null
        try {
            $inputFile = New-Object IO.FileStream -ArgumentList $pack.source, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
            if ($inputFile.Length -ne [long]$pack.bytes) { throw 'Selected source pack changed before copying.' }
            $outputFile = New-Object IO.FileStream -ArgumentList $temporary, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
            $algorithm = [Security.Cryptography.SHA256]::Create(); $buffer = New-Object byte[] 1048576
            [long]$copied = 0; [long]$progress = 0
            while (($read = $inputFile.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $copied += $read
                if ($copied -gt [long]$pack.bytes) { throw 'Selected source pack exceeded its copy bound.' }
                $outputFile.Write($buffer, 0, $read); [void]$algorithm.TransformBlock($buffer, 0, $read, $buffer, 0)
                $progress += $read
                if ($progress -ge 1073741824) { Write-Host ('Copying ' + $Role + ' selected mod: ' + $relative + ' (' + $copied + ' bytes)'); $progress = 0 }
            }
            [void]$algorithm.TransformFinalBlock((New-Object byte[] 0), 0, 0)
            $actualHash = ([BitConverter]::ToString($algorithm.Hash)).Replace('-', '').ToLowerInvariant()
            $outputFile.Flush(); $outputFile.Dispose(); $outputFile = $null
            if ($copied -ne [long]$pack.bytes -or $actualHash -cne $pack.sha256 -or (Get-GoldbergDigest -Path $temporary) -cne $pack.sha256) { throw 'Selected source changed after selection or copy hash differs.' }
            [IO.File]::Move($temporary, $destination)
        } finally {
            if ($null -ne $algorithm) { $algorithm.Dispose() }
            if ($null -ne $outputFile) { $outputFile.Dispose() }
            if ($null -ne $inputFile) { $inputFile.Dispose() }
        }
        $results += [pscustomobject]@{ relative_path = $relative; sha256 = $pack.sha256; bytes = $pack.bytes; status = 'COPIED' }
    }
    return [pscustomobject]@{ status = 'COPIED_VERIFIED'; fingerprint = $Selection.fingerprint; files = $results }
}

function Get-GoldbergSelectedModScript {
    param($Selection, [string]$GameRoot)
    $lines = @()
    foreach ($directory in $Selection.directories) {
        if (-not $directory.explicit) { continue }
        $mapped = $(if ($directory.relative_path) { Join-Path $GameRoot $directory.relative_path } else { $GameRoot })
        $lines += ('add_working_directory "' + $mapped + '";')
    }
    foreach ($mod in $Selection.mods) { $lines += ('mod "' + $mod.name + '";') }
    return ($lines -join "`r`n")
}

function Get-GoldbergModScript {
    param([AllowEmptyString()][string]$Text, [string]$SourceGameRoot, [string]$CopiedGameRoot)
    if ($Text.Length -gt 1048576) { throw 'Original user script exceeds the bounded importer limit.' }
    $sourceRoot = [IO.Path]::GetFullPath($SourceGameRoot).TrimEnd([char[]]@('\', '/'))
    $copyRoot = [IO.Path]::GetFullPath($CopiedGameRoot).TrimEnd([char[]]@('\', '/'))
    Assert-LabNoReparsePath -Path $sourceRoot
    Assert-LabNoReparsePath -Path $copyRoot
    $lines = @(); $directories = @((Join-Path $copyRoot 'data')); $unresolved = @(); $excluded = 0; $recognized = 0
    foreach ($line in [regex]::Split($Text, '\r\n|\n|\r')) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('//') -or $trimmed.StartsWith('#')) { continue }
        $match = [regex]::Match($trimmed, '^(mod|add_working_directory)\s+"([^"\r\n\x00]+)"\s*;\s*$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) {
            $excluded++
            if ($trimmed -match '^(mod|add_working_directory)\b') { $unresolved += 'Unsupported mod directive syntax.' }
            continue
        }
        $recognized++
        $directive = $match.Groups[1].Value.ToLowerInvariant(); $value = $match.Groups[2].Value
        if ($directive -eq 'add_working_directory') {
            try {
                if ($value -match '(^|[\\/])\.\.([\\/]|$)' -or $value -match '[%\r\n]') { throw 'Unresolved working-directory expansion or traversal.' }
                $originalDirectory = $(if ([IO.Path]::IsPathRooted($value)) { [IO.Path]::GetFullPath($value) } else { [IO.Path]::GetFullPath((Join-Path $sourceRoot $value)) })
                if (-not (Test-LabPathContained -Root $sourceRoot -Path $originalDirectory)) { throw 'External mod directory was not copied by this lab.' }
                $relative = $originalDirectory.Substring($sourceRoot.Length).TrimStart([char[]]@('\', '/'))
                $mapped = $(if ($relative) { Join-Path $copyRoot $relative } else { $copyRoot })
                Assert-LabNoReparsePath -Path $mapped
                if (-not (Test-Path -LiteralPath $mapped -PathType Container)) { throw 'Copied mod working directory is missing.' }
                if ($directories -notcontains $mapped) { $directories += $mapped }
                $lines += ('add_working_directory "' + $mapped + '";')
            } catch { $unresolved += $_.Exception.Message }
            continue
        }
        if ($value -notmatch '^[^\\/:*?"<>|\x00]+\.pack$' -or $value -match '^\.' -or $value -match '[\r\n]') { $unresolved += 'Mod reference is not a plain pack filename.'; continue }
        $packMatches = @()
        foreach ($directory in $directories) {
            $candidate = Join-Path $directory $value
            Assert-LabNoReparsePath -Path $candidate
            if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and $packMatches -notcontains $candidate) { $packMatches += $candidate }
        }
        if ($packMatches.Count -ne 1) { $unresolved += ('Mod pack is missing or ambiguous in owned copies: ' + $value); continue }
        $lines += ('mod "' + $value + '";')
    }
    $status = 'NO_MOD_DIRECTIVES'
    if ($unresolved.Count -gt 0) { $lines = @(); $status = 'MODS_NOT_CONFIGURED' }
    elseif ($lines.Count -gt 0) { $status = 'FILTERED_DIRECTIVES_READY_NOT_RUNTIME_VERIFIED' }
    return [pscustomobject]@{ text = ($lines -join "`r`n"); status = $status; recognized_directives = $recognized; excluded_lines = $excluded; unresolved = $unresolved }
}

function Get-GoldbergNetworkObservation {
    param([uint32[]]$ProcessIds = @())
    $network = [ordered]@{ intended_ports = @(47584, 47585); active_ipv4_adapters = @(); occupied_ports = @(); process_endpoints = @(); endpoint_status = 'NOT_OBSERVED' }
    foreach ($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($adapter.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up -or $adapter.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
        $addresses = @($adapter.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and -not [Net.IPAddress]::IsLoopback($_.Address) } | ForEach-Object { $_.Address.ToString() })
        if ($addresses.Count -gt 0) { $network.active_ipv4_adapters += [pscustomobject]@{ name = $adapter.Name; ipv4 = $addresses } }
    }
    $global = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    foreach ($transport in @('TCP', 'UDP')) {
        $listeners = $(if ($transport -eq 'TCP') { $global.GetActiveTcpListeners() } else { $global.GetActiveUdpListeners() })
        foreach ($listener in $listeners) {
            if (@(47584, 47585) -contains $listener.Port) { $network.occupied_ports += [pscustomobject]@{ transport = $transport; address = $listener.Address.ToString(); port = $listener.Port } }
        }
    }
    if ($ProcessIds.Count -gt 0) {
        try {
            $tcp = @(Get-NetTCPConnection -ErrorAction Stop | Where-Object { $ProcessIds -contains [uint32]$_.OwningProcess })
            $udp = @(Get-NetUDPEndpoint -ErrorAction Stop | Where-Object { $ProcessIds -contains [uint32]$_.OwningProcess })
            foreach ($item in $tcp) { $network.process_endpoints += [pscustomobject]@{ transport = 'TCP'; process_id = $item.OwningProcess; address = $item.LocalAddress; port = $item.LocalPort; state = [string]$item.State } }
            foreach ($item in $udp) { $network.process_endpoints += [pscustomobject]@{ transport = 'UDP'; process_id = $item.OwningProcess; address = $item.LocalAddress; port = $item.LocalPort } }
            $network.endpoint_status = 'OBSERVED'
        } catch { $network.endpoint_status = 'UNAVAILABLE: ' + $_.Exception.Message }
    }
    return [pscustomobject]$network
}

Export-ModuleMember -Function Test-GoldbergRootsDisjoint, Assert-GoldbergLayout, Get-GoldbergVolumeBudget, Assert-GoldbergDiskBudget, Get-GoldbergDigest, Get-GoldbergPeMachine, Get-GoldbergPeerSettings, Get-GoldbergInterfaces, Get-GoldbergTreeInventory, Initialize-GoldbergCopyRoot, Copy-GoldbergGameTree, Expand-GoldbergVerifiedDll, Get-GoldbergToolkitContext, Assert-GoldbergSingleLinkFile, Write-GoldbergManagedText, Install-GoldbergCopySettings, Assert-GoldbergConfiguredCopy, Get-GoldbergActiveModSelection, Copy-GoldbergSelectedMods, Get-GoldbergSelectedModScript, Get-GoldbergModScript, Get-GoldbergNetworkObservation
