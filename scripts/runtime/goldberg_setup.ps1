# Current-user installer bridge. It never edits the original game or removes lab data.
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Run', 'Collect', 'Uninstall', 'Validate')][string]$Mode = 'Validate',
    [string]$SettingsPath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:GoldSetupOwner = 'MK1212Scripts.goldberg-installer'
$script:GoldSetupRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:GoldSetupFiles = @(
    'README.md', 'RUN-GOLDBERG-LAB.cmd', 'RUN-INSTALLED-GOLDBERG.cmd',
    'scripts/runtime/goldberg_setup.ps1', 'scripts/runtime/goldberg_client_lab.ps1',
    'scripts/runtime/goldberg_client_lab_core.psm1', 'scripts/runtime/dual_client_lab_core.psm1',
    'scripts/runtime/dual_client_probe.ps1', 'third_party/goldberg/lock.json',
    'third_party/goldberg/UPSTREAM.md', 'third_party/goldberg/LICENSE.LGPL-3.0.txt',
    'third_party/goldberg/LICENSE.GPL-3.0.txt', 'third_party/goldberg/goldberg-original-475342f0.zip',
    'third_party/nsis/LICENSE.txt', 'third_party/nsis/UPSTREAM.md'
)
$script:GoldSetupPathKeys = @('GameRoot', 'HostGameRoot', 'ClientGameRoot', 'ModsRoot', 'ToolkitRoot', 'LabRoot', 'SandboxieRoot')
$script:GoldSetupLegacySource = '7f66f06afddc53fda220f22d1940242ebd87e4ab'
$script:GoldSetupLegacyManifest = '6437e64419ff4337bf43ae2f62976f503e3878571f876ba09a4ec4d4c744f435'

function Assert-GoldbergSetupNoReparse {
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw ('Reparse points are not allowed: ' + $current) }
        }
        $parent = [IO.Path]::GetDirectoryName($current.TrimEnd([char[]]@('\', '/')))
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Read-GoldbergSetupBytes {
    param([string]$Path, [long]$MaxBytes = 131072)
    Assert-GoldbergSetupNoReparse -Path $Path
    $stream = New-Object IO.FileStream -ArgumentList $Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
    try {
        if ($stream.Length -gt $MaxBytes) { throw ('Input exceeds its size limit: ' + $Path) }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -eq 0) { throw ('Input changed during reading: ' + $Path) }
            $offset += $read
        }
        return ,$bytes
    } finally { $stream.Dispose() }
}

function Read-GoldbergSetupJson {
    param([string]$Path)
    $bytes = Read-GoldbergSetupBytes -Path $Path
    $encoding = New-Object Text.UTF8Encoding -ArgumentList $false, $true
    return ($encoding.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop)
}

function Read-GoldbergSetupIni {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = Read-GoldbergSetupBytes -Path $Path -MaxBytes 65536
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {
        $encoding = New-Object Text.UnicodeEncoding -ArgumentList $false, $true, $true
        $text = $encoding.GetString($bytes, 2, $bytes.Length - 2)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) {
        $encoding = New-Object Text.UnicodeEncoding -ArgumentList $true, $true, $true
        $text = $encoding.GetString($bytes, 2, $bytes.Length - 2)
    } else {
        $encoding = New-Object Text.UTF8Encoding -ArgumentList $false, $true
        try { $text = $encoding.GetString($bytes).TrimStart([char]0xFEFF) }
        catch { $text = [Text.Encoding]::Default.GetString($bytes) }
    }
    $values = @{}; $sectionSeen = $false
    $keys = @('GameRoot', 'HostGameRoot', 'ClientGameRoot', 'ModsRoot', 'ToolkitRoot', 'SandboxieRoot')
    foreach ($line in ($text -split '\r?\n')) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -match '^\[') {
            if ($sectionSeen -or $trimmed -cne '[MK1212]') { throw 'Expected exactly one [MK1212] INI section.' }
            $sectionSeen = $true; continue
        }
        $match = [regex]::Match($line, '^\s*([A-Za-z]+)\s*=(.*)$')
        if (-not $sectionSeen -or -not $match.Success) { throw 'Malformed installer INI input.' }
        $key = $match.Groups[1].Value
        if ($keys -cnotcontains $key -or $values.ContainsKey($key)) { throw ('Unknown or duplicate INI key: ' + $key) }
        $value = $match.Groups[2].Value.Trim()
        if ($value.Length -gt 4096 -or $value -match '[\x00-\x1f]') { throw ('Invalid INI value: ' + $key) }
        $values[$key] = $value
    }
    foreach ($key in $keys | Where-Object { $_ -ne 'SandboxieRoot' }) {
        if (-not $values.ContainsKey($key) -or -not $values[$key]) { throw ('Missing installer path: ' + $key) }
    }
    return $values
}

function ConvertTo-GoldbergSetupPath {
    param([string]$Value, [string]$Name)
    if (-not $Value -or $Value.Length -gt 4096 -or $Value -notmatch '^[A-Za-z]:[\\/]' -or $Value -match '[\x00-\x1f"<>|?*%]' -or $Value.Substring(2).Contains(':')) {
        throw ($Name + ' must be a literal local Windows drive path without expansion or wildcard characters.')
    }
    $full = [IO.Path]::GetFullPath($Value.Replace('/', '\')).TrimEnd('\')
    if ($full.Length -le 2) { throw ($Name + ' must be a directory below the drive root.') }
    foreach ($component in $full.Substring(3).Split('\')) {
        if ($component -match '[ .]$' -or $component -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw ('Unsupported Windows path component in ' + $Name) }
    }
    Assert-GoldbergSetupNoReparse -Path $full
    return $full
}

function Test-GoldbergSetupOverlap {
    param([string]$Left, [string]$Right)
    return $Left.Equals($Right, [StringComparison]::OrdinalIgnoreCase) -or $Left.StartsWith(($Right + '\'), [StringComparison]::OrdinalIgnoreCase) -or $Right.StartsWith(($Left + '\'), [StringComparison]::OrdinalIgnoreCase)
}

function Get-GoldbergSetupPaths {
    param([Parameter(Mandatory = $true)]$Values, [switch]$SkipSourceChecks)
    $paths = [ordered]@{}
    foreach ($key in @('GameRoot', 'HostGameRoot', 'ClientGameRoot', 'ModsRoot', 'ToolkitRoot')) {
        $paths[$key] = ConvertTo-GoldbergSetupPath -Value ([string]$Values.$key) -Name $key
    }
    $paths['LabRoot'] = Join-Path $paths.ToolkitRoot 'lab'
    $sandboxieValue = $null
    if ($Values -is [Collections.IDictionary]) { if ($Values.Contains('SandboxieRoot')) { $sandboxieValue = [string]$Values.SandboxieRoot } }
    elseif ($null -ne $Values.PSObject.Properties['SandboxieRoot']) { $sandboxieValue = [string]$Values.SandboxieRoot }
    $paths['SandboxieRoot'] = $(if ($sandboxieValue) { ConvertTo-GoldbergSetupPath -Value $sandboxieValue -Name 'SandboxieRoot' } else { '' })
    $mutable = @($paths.ToolkitRoot, $paths.HostGameRoot, $paths.ClientGameRoot)
    for ($i = 0; $i -lt $mutable.Count; $i++) {
        for ($j = $i + 1; $j -lt $mutable.Count; $j++) { if (Test-GoldbergSetupOverlap $mutable[$i] $mutable[$j]) { throw 'Toolkit, HOST and CLIENT directories must not overlap.' } }
        foreach ($source in @($paths.GameRoot, $paths.ModsRoot)) { if (Test-GoldbergSetupOverlap $mutable[$i] $source) { throw 'Destination directories must not overlap the original game or source mods.' } }
    }
    $systemDrive = [Environment]::GetEnvironmentVariable('SystemDrive')
    if ($systemDrive -and [IO.Path]::GetPathRoot($paths.ToolkitRoot).TrimEnd('\') -ieq $systemDrive) { throw 'ToolkitRoot needs a non-system drive because its lab directory contains sandbox data; HOST may use C:.' }
    if (-not $SkipSourceChecks) {
        foreach ($key in @('GameRoot', 'ModsRoot')) { if (-not (Test-Path -LiteralPath $paths[$key] -PathType Container)) { throw ('Source directory does not exist: ' + $key + '=' + $paths[$key]) } }
        foreach ($leaf in @('Attila.exe', 'steam_api.dll')) {
            $path = Join-Path $paths.GameRoot $leaf
            Assert-GoldbergSetupNoReparse -Path $path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Original game file is missing: ' + $path) }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $paths.GameRoot 'data') -PathType Container)) { throw 'The original game data directory is missing.' }
        foreach ($destination in $mutable) { if (-not (Test-Path -LiteralPath ([IO.Path]::GetPathRoot($destination)) -PathType Container)) { throw ('Destination volume is unavailable: ' + $destination) } }
    }
    return [pscustomobject]$paths
}

function Test-GoldbergSetupEmpty {
    param([string]$Path)
    Assert-GoldbergSetupNoReparse -Path $Path
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw ('Expected a directory: ' + $Path) }
    $iterator = [IO.Directory]::EnumerateFileSystemEntries($Path).GetEnumerator()
    try { return -not $iterator.MoveNext() } finally { if ($iterator -is [IDisposable]) { $iterator.Dispose() } }
}

function Get-GoldbergSetupDigest {
    param([string]$Path, [long]$MaxBytes = 41943040)
    Assert-GoldbergSetupNoReparse -Path $Path
    $stream = New-Object IO.FileStream -ArgumentList $Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        if ($stream.Length -gt $MaxBytes) { throw ('File exceeds the toolkit limit: ' + $Path) }
        return [pscustomobject]@{ bytes = $stream.Length; sha256 = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    } finally { $sha.Dispose(); $stream.Dispose() }
}

function Assert-GoldbergSetupFile {
    param([string]$Root, $Record, [switch]$AllowMissing)
    if ($script:GoldSetupFiles -cnotcontains [string]$Record.path -and [string]$Record.path -cne 'package_manifest.json') { throw 'File operation is outside the fixed toolkit allowlist.' }
    $path = Join-Path $Root $Record.path
    Assert-GoldbergSetupNoReparse -Path $path
    if ($AllowMissing -and -not (Test-Path -LiteralPath $path)) { return }
    $actual = Get-GoldbergSetupDigest -Path $path
    if ($actual.bytes -ne [long]$Record.bytes -or $actual.sha256 -cne $Record.sha256) { throw ('Toolkit file changed; preserved: ' + $path) }
}

function Get-GoldbergSetupPackage {
    param([Parameter(Mandatory = $true)][string]$Root, [switch]$AllowMissing)
    $manifestPath = Join-Path $Root 'package_manifest.json'
    $manifest = Read-GoldbergSetupJson -Path $manifestPath
    if ($manifest.schema -ne 1 -or $manifest.package -cne 'mk1212-goldberg-client-lab' -or $manifest.source_sha -cnotmatch '^[0-9a-f]{40}$' -or $manifest.files.Count -ne $script:GoldSetupFiles.Count) { throw 'Unsupported or incomplete toolkit package manifest.' }
    $seen = @{}
    foreach ($record in $manifest.files) {
        if ($script:GoldSetupFiles -cnotcontains [string]$record.path -or $seen.ContainsKey([string]$record.path)) { throw 'Package file is outside the fixed installer allowlist, or duplicated.' }
        if ($record.sha256 -cnotmatch '^[0-9a-f]{64}$' -or ($record.bytes -isnot [int] -and $record.bytes -isnot [long]) -or $record.bytes -lt 1 -or $record.bytes -gt 41943040) { throw 'Invalid package file identity.' }
        $seen[[string]$record.path] = $true
        Assert-GoldbergSetupFile -Root $Root -Record $record -AllowMissing:$AllowMissing
    }
    $archive = @($manifest.files | Where-Object { $_.path -ceq 'third_party/goldberg/goldberg-original-475342f0.zip' })[0]
    if ($archive.bytes -ne 19360188 -or $archive.sha256 -cne '8465984b01b42a75f5faea8f2d884bbd6085a695c40c2b90eb0385f0a5081266') { throw 'The package does not contain the pinned original Goldberg archive.' }
    $identity = Get-GoldbergSetupDigest -Path $manifestPath -MaxBytes 131072
    return [pscustomobject]@{ root = $Root; manifest = $manifest; records = @($manifest.files); source_sha = $manifest.source_sha; manifest_sha256 = $identity.sha256; manifest_bytes = $identity.bytes }
}

function Assert-GoldbergSetupOwnership {
    param($Paths, $Package)
    $markerPath = Join-Path $Paths.ToolkitRoot 'installer-settings.json'
    if (-not (Test-Path -LiteralPath $markerPath)) {
        if (-not (Test-GoldbergSetupEmpty -Path $Paths.ToolkitRoot)) { throw 'ToolkitRoot is not empty and has no installer ownership marker; all files were preserved.' }
        return $null
    }
    $marker = Read-GoldbergSetupJson -Path $markerPath
    if ($marker.schema -ne 1 -or $marker.owner -cne $script:GoldSetupOwner -or $marker.installation_id -cnotmatch '^[0-9a-f]{32}$' -or $marker.source_sha -cne $Package.source_sha -or $marker.package_manifest_sha256 -cne $Package.manifest_sha256) { throw 'Installer ownership/package identity does not match; changing an existing installation in place is not supported.' }
    foreach ($key in $script:GoldSetupPathKeys) {
        if ([string]$marker.$key -ine [string]$Paths.$key) {
            $details = [ordered]@{ path_key = $key; saved_value = [string]$marker.$key; requested_value = [string]$Paths.$key; marker_path = $markerPath }
            throw ('Owned installation path differs: ' + $key + '; ' + ($details | ConvertTo-Json -Compress))
        }
    }
    return $marker
}

function Assert-GoldbergSetupLegacyPartial {
    param($Paths, $Marker, [string[]]$RecoveryFiles = @())
    $markerPath = Join-Path $Paths.ToolkitRoot 'installer-settings.json'
    foreach ($key in @('owner', 'installation_id', 'source_sha', 'package_manifest_sha256', 'created_utc')) {
        if ($null -eq $Marker.PSObject.Properties[$key] -or $Marker.$key -isnot [string]) { throw ('Previous marker has an invalid identity type: ' + $key) }
    }
    if (($Marker.schema -isnot [int] -and $Marker.schema -isnot [long]) -or $Marker.schema -ne 1 -or $Marker.owner -cne $script:GoldSetupOwner -or $Marker.installation_id -cnotmatch '^[0-9a-f]{32}$' -or $Marker.source_sha -cne $script:GoldSetupLegacySource -or $Marker.package_manifest_sha256 -cne $script:GoldSetupLegacyManifest -or $Marker.created_utc -isnot [string]) {
        throw 'Previous partial-install recovery requires the exact supported owner, schema, identifier and released package identity.'
    }
    foreach ($key in $script:GoldSetupPathKeys) {
        if ($null -eq $Marker.PSObject.Properties[$key] -or $Marker.$key -isnot [string]) { throw ('Previous marker has an invalid path type: ' + $key) }
    }
    $recorded = Get-GoldbergSetupPaths -Values $Marker -SkipSourceChecks
    $recordedLab = ConvertTo-GoldbergSetupPath -Value $Marker.LabRoot -Name 'RecordedLabRoot'
    if ($recordedLab -ine $recorded.LabRoot) { throw 'Recorded LabRoot must derive from its recorded ToolkitRoot; all data was preserved.' }
    foreach ($key in @('GameRoot', 'ModsRoot', 'HostGameRoot', 'ClientGameRoot', 'SandboxieRoot')) {
        if ([string]$recorded.$key -ine [string]$Paths.$key) {
            $details = [ordered]@{ path_key = $key; saved_value = [string]$Marker.$key; requested_value = [string]$Paths.$key; marker_path = $markerPath }
            throw ('Previous partial-install paths differ: ' + $key + '; ' + ($details | ConvertTo-Json -Compress))
        }
    }
    if ($recorded.ToolkitRoot -ine $Paths.ToolkitRoot -and -not (Test-GoldbergSetupEmpty -Path $recorded.ToolkitRoot)) {
        $details = [ordered]@{ saved_value = $recorded.ToolkitRoot; requested_value = $Paths.ToolkitRoot; marker_path = $markerPath }
        throw ('The recorded ToolkitRoot still contains files; existing installations cannot be relocated; ' + ($details | ConvertTo-Json -Compress))
    }
    foreach ($root in @($recorded.LabRoot, $Paths.LabRoot, $Paths.HostGameRoot, $Paths.ClientGameRoot)) {
        if (-not (Test-GoldbergSetupEmpty -Path $root)) { throw ('Previous partial-install recovery requires empty lab/game destinations; preserved: ' + $root) }
    }
    Assert-GoldbergSetupNoReparse -Path $Paths.ToolkitRoot
    if ($RecoveryFiles.Count -gt 2) { throw 'Unexpected recovery inventory.' }
    foreach ($leaf in $RecoveryFiles) {
        if ($leaf -cnotmatch '^(?:installer-settings\.recovered-7f66f06a-[0-9a-f]{32}\.json|\.installer-recovery-[0-9a-f]{32}\.tmp)$') { throw 'Unexpected recovery metadata filename.' }
    }
    $entryCount = 0
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Paths.ToolkitRoot)) {
        $entryCount++
        $leaf = [IO.Path]::GetFileName($entry)
        Assert-GoldbergSetupNoReparse -Path $entry
        if ($entryCount -gt (2 + $RecoveryFiles.Count) -or (@('installer-settings.json', '.goldberg-setup.lock') -cnotcontains $leaf -and $RecoveryFiles -cnotcontains $leaf) -or -not [IO.File]::Exists($entry)) { throw ('Previous partial-install recovery found another file or directory; all files were preserved: ' + $entry) }
        if ($leaf -ceq '.goldberg-setup.lock' -and (Get-Item -LiteralPath $entry -Force).Length -ne 0) { throw 'The previous setup lock is not empty; all files were preserved.' }
    }
    return $recorded
}

function Write-GoldbergSetupExclusiveBytes {
    param([string]$Path, [byte[]]$Bytes)
    if ($Bytes.Length -gt 131072) { throw 'Installer metadata exceeds its size bound.' }
    Assert-GoldbergSetupNoReparse -Path $Path
    $stream = New-Object IO.FileStream -ArgumentList $Path, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
}

function Repair-GoldbergSetupLegacyMarker {
    param($Paths, $Package)
    $markerPath = Join-Path $Paths.ToolkitRoot 'installer-settings.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }
    $oldBytes = Read-GoldbergSetupBytes -Path $markerPath
    $encoding = New-Object Text.UTF8Encoding -ArgumentList $false, $true
    $oldText = $encoding.GetString($oldBytes).TrimStart([char]0xFEFF)
    $marker = $oldText | ConvertFrom-Json -ErrorAction Stop
    if ($marker.source_sha -cne $script:GoldSetupLegacySource -or $marker.package_manifest_sha256 -cne $script:GoldSetupLegacyManifest -or $Package.source_sha -ceq $script:GoldSetupLegacySource) { return $false }
    # PS7 may deserialize ISO timestamps as DateTime. Recover the exact timestamp
    # string written by the previous release rather than serialize a converted date.
    $created = [regex]::Matches($oldText, '"created_utc"\s*:\s*"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z)"')
    if ($created.Count -ne 1) { throw 'The previous marker needs one authentic UTC creation timestamp.' }
    [void][DateTime]::ParseExact($created[0].Groups[1].Value, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    $marker.created_utc = $created[0].Groups[1].Value
    [void](Assert-GoldbergSetupLegacyPartial -Paths $Paths -Marker $marker)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $before = [pscustomobject]@{ bytes = $oldBytes.Length; sha256 = ([BitConverter]::ToString($sha.ComputeHash($oldBytes))).Replace('-', '').ToLowerInvariant() } }
    finally { $sha.Dispose() }
    $lockPath = Join-Path $Paths.ToolkitRoot '.goldberg-setup.lock'
    Assert-GoldbergSetupNoReparse -Path $lockPath
    $recoveryLock = New-Object IO.FileStream -ArgumentList $lockPath, ([IO.FileMode]::OpenOrCreate), ([IO.FileAccess]::ReadWrite), ([IO.FileShare]::None)
    $temporary = $null; $backupPath = $null; $markerReplaced = $false
    try {
        if ($recoveryLock.Length -ne 0) { throw 'The previous setup lock is not empty.' }
        $locked = Get-GoldbergSetupDigest -Path $markerPath -MaxBytes 131072
        if ($locked.sha256 -cne $before.sha256 -or $locked.bytes -ne $before.bytes) { throw 'The previous marker changed before recovery; all files were preserved.' }
        $recorded = Assert-GoldbergSetupLegacyPartial -Paths $Paths -Marker $marker
        $backupLeaf = 'installer-settings.recovered-7f66f06a-' + [guid]::NewGuid().ToString('N') + '.json'
        $backupPath = Join-Path $Paths.ToolkitRoot $backupLeaf
        # The exclusive backup write cannot replace any existing user's file.
        Write-GoldbergSetupExclusiveBytes -Path $backupPath -Bytes $oldBytes
        $backup = Get-GoldbergSetupDigest -Path $backupPath -MaxBytes 131072
        if ($backup.bytes -ne $before.bytes -or $backup.sha256 -cne $before.sha256) { throw 'Previous marker backup verification failed; the current marker was not replaced.' }
        $replacement = [ordered]@{
            schema = 1; owner = $script:GoldSetupOwner; installation_id = $marker.installation_id
            source_sha = $Package.source_sha; package_manifest_sha256 = $Package.manifest_sha256; created_utc = $marker.created_utc
            recovery = [ordered]@{
                schema = 1; source_sha = $script:GoldSetupLegacySource; package_manifest_sha256 = $script:GoldSetupLegacyManifest
                marker_sha256 = $before.sha256; backup_file = $backupLeaf
                recorded_toolkit_root = $recorded.ToolkitRoot; recorded_lab_root = $recorded.LabRoot
                recovered_utc = [DateTime]::UtcNow.ToString('o')
            }
        }
        foreach ($key in $script:GoldSetupPathKeys) { $replacement[$key] = [string]$Paths.$key }
        $encoding = New-Object Text.UTF8Encoding -ArgumentList $false
        $newBytes = $encoding.GetBytes(($replacement | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
        $temporary = Join-Path $Paths.ToolkitRoot ('.installer-recovery-' + [guid]::NewGuid().ToString('N') + '.tmp')
        Write-GoldbergSetupExclusiveBytes -Path $temporary -Bytes $newBytes
        $newMarker = Read-GoldbergSetupJson -Path $temporary
        if ($newMarker.source_sha -cne $Package.source_sha -or $newMarker.package_manifest_sha256 -cne $Package.manifest_sha256 -or $newMarker.installation_id -cne $marker.installation_id) { throw 'Replacement marker verification failed.' }
        foreach ($key in $script:GoldSetupPathKeys) { if ([string]$newMarker.$key -ine [string]$Paths.$key) { throw ('Replacement marker path verification failed: ' + $key) } }
        # Recheck destination state after staging, admitting only our two exact metadata leaves.
        [void](Assert-GoldbergSetupLegacyPartial -Paths $Paths -Marker $marker -RecoveryFiles @($backupLeaf, [IO.Path]::GetFileName($temporary)))
        $current = Get-GoldbergSetupDigest -Path $markerPath -MaxBytes 131072
        if ($current.sha256 -cne $before.sha256 -or $current.bytes -ne $before.bytes) { throw 'The previous marker changed during recovery; it was preserved.' }
        # Only owned metadata is replaced. Game, mod, lab and source files are never moved or removed.
        [IO.File]::Replace($temporary, $markerPath, $null)
        $markerReplaced = $true
        [void](Assert-GoldbergSetupOwnership -Paths $Paths -Package $Package)
        [Console]::Out.WriteLine('MK1212_SETUP_RECOVERY=PREVIOUS_MARKER_ONLY; preserved backup: ' + $backupPath)
        return $true
    } finally {
        if (-not $markerReplaced -and $backupPath -and [IO.File]::Exists($backupPath)) {
            # A failed attempt is retryable only when both old marker and our backup
            # still contain the original bytes. A changed marker keeps its backup.
            try {
                $retained = Get-GoldbergSetupDigest -Path $markerPath -MaxBytes 131072
                $backup = Get-GoldbergSetupDigest -Path $backupPath -MaxBytes 131072
                if ($retained.bytes -eq $before.bytes -and $retained.sha256 -ceq $before.sha256 -and $backup.bytes -eq $before.bytes -and $backup.sha256 -ceq $before.sha256) { [IO.File]::Delete($backupPath) }
            } catch { [Console]::Out.WriteLine('Recovery backup retained because the old marker/backup could not be reverified: ' + $backupPath) }
        }
        try { if ($temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
        finally { $recoveryLock.Dispose() }
    }
}

function Assert-GoldbergSetupDestinations {
    param($Paths)
    $statePath = Join-Path $Paths.LabRoot '.mk1212-goldberg-lab.json'
    $state = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = Read-GoldbergSetupJson -Path $statePath
        if (@(1, 2) -notcontains $state.schema -or $state.owner -cne 'MK1212Scripts.goldberg-client-lab' -or $state.lab_id -cnotmatch '^[0-9a-f]{32}$' -or $state.lab_root -ine $Paths.LabRoot -or $state.source_game_root -ine $Paths.GameRoot) { throw 'Existing lab is not owned by this installation layout.' }
    } elseif (-not (Test-GoldbergSetupEmpty -Path $Paths.LabRoot)) { throw 'LabRoot is nonempty without a matching lab marker.' }
    foreach ($role in @('HOST', 'CLIENT')) {
        $root = $(if ($role -eq 'HOST') { $Paths.HostGameRoot } else { $Paths.ClientGameRoot })
        if (Test-GoldbergSetupEmpty -Path $root) { continue }
        $marker = Read-GoldbergSetupJson -Path (Join-Path $root '.mk1212-goldberg-copy.json')
        if ($null -eq $state -or $marker.schema -ne 1 -or $marker.owner -cne 'MK1212Scripts.goldberg-client-lab' -or $marker.lab_id -cne $state.lab_id -or $marker.role -cne $role) { throw ('Existing ' + $role + ' directory is not an owned copy for this lab.') }
    }
}

function Copy-GoldbergSetupFile {
    param([string]$SourceRoot, [string]$DestinationRoot, $Record)
    $source = Join-Path $SourceRoot $Record.path; $destination = Join-Path $DestinationRoot $Record.path
    Assert-GoldbergSetupFile -Root $SourceRoot -Record $Record
    Assert-GoldbergSetupNoReparse -Path $destination
    if (Test-Path -LiteralPath $destination) { Assert-GoldbergSetupFile -Root $DestinationRoot -Record $Record; return }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
    $temporary = $destination + '.install-' + [guid]::NewGuid().ToString('N')
    try {
        $inputFile = New-Object IO.FileStream -ArgumentList $source, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
        try {
            if ($inputFile.Length -ne [long]$Record.bytes) { throw ('Source size changed before copy: ' + $Record.path) }
            $outputFile = New-Object IO.FileStream -ArgumentList $temporary, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
            try { $inputFile.CopyTo($outputFile); $outputFile.Flush() } finally { $outputFile.Dispose() }
        } finally { $inputFile.Dispose() }
        $actual = Get-GoldbergSetupDigest -Path $temporary
        if ($actual.bytes -ne $Record.bytes -or $actual.sha256 -cne $Record.sha256) { throw ('Copy verification failed: ' + $Record.path) }
        [IO.File]::Move($temporary, $destination)
        Assert-GoldbergSetupFile -Root $DestinationRoot -Record $Record
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function New-GoldbergSetupMarker {
    param($Paths, $Package)
    $marker = [ordered]@{ schema = 1; owner = $script:GoldSetupOwner; installation_id = [guid]::NewGuid().ToString('N'); source_sha = $Package.source_sha; package_manifest_sha256 = $Package.manifest_sha256; created_utc = [DateTime]::UtcNow.ToString('o') }
    foreach ($key in $script:GoldSetupPathKeys) { $marker[$key] = [string]$Paths.$key }
    $path = Join-Path $Paths.ToolkitRoot 'installer-settings.json'
    $temporary = Join-Path $Paths.ToolkitRoot ('.installer-settings-' + [guid]::NewGuid().ToString('N') + '.tmp')
    Assert-GoldbergSetupNoReparse -Path $path
    [void][IO.Directory]::CreateDirectory($Paths.ToolkitRoot)
    try {
        $stream = New-Object IO.FileStream -ArgumentList $temporary, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
        try {
            $encoding = New-Object Text.UTF8Encoding -ArgumentList $false
            $bytes = $encoding.GetBytes(($marker | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
            $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
        } finally { $stream.Dispose() }
        # No replace: another install winning this race keeps its original marker.
        [IO.File]::Move($temporary, $path)
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    return (Assert-GoldbergSetupOwnership -Paths $Paths -Package $Package)
}

function Resolve-GoldbergSetupSandboxie {
    param($Paths, [string]$VerifiedRoot)
    Import-Module (Join-Path $VerifiedRoot 'scripts/runtime/dual_client_lab_core.psm1') -Force -DisableNameChecking
    $tools = Get-LabToolPaths -GameRoot $Paths.GameRoot -SandboxieRoot $Paths.SandboxieRoot
    if (-not $tools.sandboxie_root) { throw 'Sandboxie Plus is required and was not found. Install it from https://sandboxie-plus.com/downloads/ and rerun setup; this helper does not install drivers or request elevation.' }
    $Paths.SandboxieRoot = ConvertTo-GoldbergSetupPath -Value $tools.sandboxie_root -Name 'SandboxieRoot'
    foreach ($leaf in @('Start.exe', 'SbieIni.exe')) { Assert-GoldbergSetupNoReparse -Path (Join-Path $Paths.SandboxieRoot $leaf) }
}

function Invoke-GoldbergSetupMain {
    param($Paths, [ValidateSet('Prepare', 'Run', 'Collect')][string]$MainMode)
    $parameters = [ordered]@{ Mode = $MainMode; GameRoot = $Paths.GameRoot; LabRoot = $Paths.LabRoot; HostGameRoot = $Paths.HostGameRoot; ClientGameRoot = $Paths.ClientGameRoot; ModsRoot = $Paths.ModsRoot; SandboxieRoot = $Paths.SandboxieRoot; GoldbergArchive = (Join-Path $Paths.ToolkitRoot 'third_party/goldberg/goldberg-original-475342f0.zip') }
    $executable = Join-Path ([Environment]::GetEnvironmentVariable('SystemRoot')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Windows PowerShell is unavailable.' }
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Paths.ToolkitRoot 'scripts/runtime/goldberg_client_lab.ps1'))
    foreach ($key in $parameters.Keys) { $arguments += ('-' + $key); $arguments += [string]$parameters[$key] }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $executable; $start.UseShellExecute = $false
    $start.Arguments = Join-LabWindowsArguments -Arguments $arguments
    $start.WorkingDirectory = $Paths.ToolkitRoot
    # Child stdout/stderr stay attached to the installer/launcher console.
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try { if (-not $process.Start()) { throw 'The lab process did not start.' }; $process.WaitForExit(); return $process.ExitCode }
    finally { $process.Dispose() }
}

function Remove-GoldbergSetupFiles {
    param($Paths, $Package)
    [void](Assert-GoldbergSetupOwnership -Paths $Paths -Package $Package)
    # Verify every present file before deleting any; missing files allow retry.
    $manifestRecord = [pscustomobject]@{ path = 'package_manifest.json'; bytes = $Package.manifest_bytes; sha256 = $Package.manifest_sha256 }
    Assert-GoldbergSetupFile -Root $Paths.ToolkitRoot -Record $manifestRecord
    foreach ($record in $Package.records) { Assert-GoldbergSetupFile -Root $Paths.ToolkitRoot -Record $record -AllowMissing }
    foreach ($record in $Package.records) {
        $path = Join-Path $Paths.ToolkitRoot $record.path
        if (Test-Path -LiteralPath $path) { Assert-GoldbergSetupFile -Root $Paths.ToolkitRoot -Record $record; [IO.File]::Delete($path) }
    }
    Assert-GoldbergSetupFile -Root $Paths.ToolkitRoot -Record $manifestRecord
    [IO.File]::Delete((Join-Path $Paths.ToolkitRoot 'package_manifest.json'))
    [IO.File]::Delete((Join-Path $Paths.ToolkitRoot 'installer-settings.json'))
}

function Invoke-GoldbergSetup {
    param([ValidateSet('Install', 'Run', 'Collect', 'Uninstall', 'Validate')][string]$Mode, [string]$SettingsPath)
    $operationLock = $null; $lockPath = $null; $removeLock = $false; $setupStage = 'ReadInput'
    try {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This installer helper requires Windows.' }
        if (-not $SettingsPath) { throw 'SettingsPath is required; use the installer or the installed launcher.' }
        $isIni = [IO.Path]::GetExtension($SettingsPath) -ieq '.ini'
        if ($isIni -and @('Install', 'Validate') -notcontains $Mode) { throw 'This mode requires the installed installer-settings.json.' }
        if (-not $isIni -and $Mode -eq 'Install') { throw 'Install requires the private installer INI input.' }
        $values = $(if ($isIni) { Read-GoldbergSetupIni -Path $SettingsPath } else { Read-GoldbergSetupJson -Path $SettingsPath })
        $setupStage = 'ValidatePaths'
        $paths = Get-GoldbergSetupPaths -Values $values -SkipSourceChecks:($Mode -eq 'Uninstall')
        if (-not $isIni -and ([IO.Path]::GetFullPath($SettingsPath) -ine (Join-Path $paths.ToolkitRoot 'installer-settings.json') -or $script:GoldSetupRoot.TrimEnd('\') -ine $paths.ToolkitRoot)) { throw 'Run the helper from its own installed toolkit with its own settings marker.' }
        $packageRoot = $(if ($isIni) { $script:GoldSetupRoot } else { $paths.ToolkitRoot })
        $setupStage = 'VerifyPackage'
        $package = Get-GoldbergSetupPackage -Root $packageRoot -AllowMissing:($Mode -eq 'Uninstall')
        if ($isIni -and (Test-GoldbergSetupOverlap -Left $packageRoot.TrimEnd('\') -Right $paths.ToolkitRoot)) { throw 'The private payload and installed toolkit must not overlap.' }
        $setupStage = 'ResolveSandboxie'
        if ($Mode -ne 'Uninstall') { Resolve-GoldbergSetupSandboxie -Paths $paths -VerifiedRoot $packageRoot }
        $setupStage = 'RecoverPreviousPartialMarker'
        if ($Mode -eq 'Install') { [void](Repair-GoldbergSetupLegacyMarker -Paths $paths -Package $package) }
        $setupStage = 'CheckOwnership'
        $marker = Assert-GoldbergSetupOwnership -Paths $paths -Package $package
        if (-not $isIni -and $null -eq $marker) { throw 'An installed ownership marker is required.' }
        $setupStage = 'CheckDestinations'
        if ($Mode -ne 'Uninstall') { Assert-GoldbergSetupDestinations -Paths $paths }
        if ($Mode -eq 'Validate') { [Console]::Out.WriteLine('MK1212_SETUP_STATUS=VALIDATED; package and directory preconditions checked; game preparation/launch NOT_RUN.'); return 0 }
        $setupStage = 'CreateOwnershipMarker'
        if ($Mode -eq 'Install' -and $null -eq $marker) { $marker = New-GoldbergSetupMarker -Paths $paths -Package $package }
        $lockPath = Join-Path $paths.ToolkitRoot '.goldberg-setup.lock'
        Assert-GoldbergSetupNoReparse -Path $lockPath
        $operationLock = New-Object IO.FileStream -ArgumentList $lockPath, ([IO.FileMode]::OpenOrCreate), ([IO.FileAccess]::ReadWrite), ([IO.FileShare]::None)
        $setupStage = 'RecheckOwnershipUnderLock'
        [void](Assert-GoldbergSetupOwnership -Paths $paths -Package $package)
        if ($Mode -eq 'Uninstall') {
            $setupStage = 'UninstallToolkitFiles'
            Remove-GoldbergSetupFiles -Paths $paths -Package $package
            $removeLock = $true
            [Console]::Out.WriteLine('MK1212_SETUP_STATUS=UNINSTALLED_TOOLKIT_FILES; lab, game copies, profiles, saves, evidence and all directories were preserved.')
            return 0
        }
        if ($Mode -eq 'Install') {
            $setupStage = 'CopyToolkitFiles'
            $manifestRecord = [pscustomobject]@{ path = 'package_manifest.json'; bytes = $package.manifest_bytes; sha256 = $package.manifest_sha256 }
            Copy-GoldbergSetupFile -SourceRoot $packageRoot -DestinationRoot $paths.ToolkitRoot -Record $manifestRecord
            foreach ($record in $package.records) { Copy-GoldbergSetupFile -SourceRoot $packageRoot -DestinationRoot $paths.ToolkitRoot -Record $record }
            [void](Get-GoldbergSetupPackage -Root $paths.ToolkitRoot)
        }
        $mainMode = $(if ($Mode -eq 'Install') { 'Prepare' } else { $Mode })
        $setupStage = 'InvokeMain:' + $mainMode
        $code = Invoke-GoldbergSetupMain -Paths $paths -MainMode $mainMode
        [Console]::Out.WriteLine('Installed settings: ' + (Join-Path $paths.ToolkitRoot 'installer-settings.json'))
        if ($code -ne 0) { [Console]::Out.WriteLine('MK1212_SETUP_STATUS=BLOCKED; ' + $mainMode + ' returned ' + $code + '. See the lab reason/report above; all prepared data was preserved.'); return $code }
        $status = $(if ($Mode -eq 'Install') { 'INSTALLED_PREPARED' } elseif ($Mode -eq 'Collect') { 'COLLECTED' } else { 'RUN_COMPLETED' })
        [Console]::Out.WriteLine('MK1212_SETUP_STATUS=' + $status + '; multiplayer success has not been inferred.')
        return 0
    } catch {
        [Console]::Out.WriteLine('MK1212_SETUP_STATUS=BLOCKED; stage=' + $setupStage + '; ' + $_.Exception.Message)
        return 2
    } finally {
        if ($null -ne $operationLock) { $operationLock.Dispose() }
        if ($removeLock -and $lockPath -and [IO.File]::Exists($lockPath)) { [IO.File]::Delete($lockPath) }
    }
}

if ($MyInvocation.InvocationName -ne '.') { exit (Invoke-GoldbergSetup -Mode $Mode -SettingsPath $SettingsPath) }
