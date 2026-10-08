# MK1212 dual-client laboratory helpers. PowerShell 5.1 and 7; no game code.
Set-StrictMode -Version 2.0

function ConvertTo-LabWindowsArgument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.IndexOf([char]0) -ge 0) { throw 'A command argument contains NUL.' }
    # Start.exe parses switches directly from GetCommandLine, before normal argv
    # decoding; quoting a simple /box:Name token prevents it seeing the slash.
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (2 * $slashes + 1)))
            [void]$builder.Append('"')
        } else {
            [void]$builder.Append(('\' * $slashes))
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    [void]$builder.Append(('\' * (2 * $slashes)))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-LabWindowsArguments {
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Arguments = @())
    return (@($Arguments | ForEach-Object { ConvertTo-LabWindowsArgument -Value $_ }) -join ' ')
}

function ConvertFrom-LabPidList {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $lines = @($Text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { throw 'Sandboxie returned no PID enumeration output.' }
    foreach ($line in $lines) {
        if ($line.Trim() -notmatch '^\d+$') { throw 'Malformed Sandboxie PID enumeration.' }
    }
    [uint32]$count = 0
    if (-not [uint32]::TryParse($lines[0].Trim(), [ref]$count)) { throw 'Invalid PID count.' }
    if ($count -gt 4096 -or ($lines.Count - 1) -ne $count) { throw 'Sandboxie PID count does not match its output.' }
    $ids = New-Object 'System.Collections.Generic.List[uint32]'
    $seen = New-Object 'System.Collections.Generic.HashSet[uint32]'
    for ($index = 1; $index -lt $lines.Count; $index++) {
        [uint32]$processId = 0
        if (-not [uint32]::TryParse($lines[$index].Trim(), [ref]$processId) -or $processId -eq 0) {
            throw 'Invalid process identifier in Sandboxie output.'
        }
        if (-not $seen.Add($processId)) { throw 'Duplicate process identifier in Sandboxie output.' }
        $ids.Add($processId)
    }
    return ,($ids.ToArray())
}

function Test-LabPathContained {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Path)
    try {
        $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
        $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
        $comparison = [StringComparison]::Ordinal
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $comparison = [StringComparison]::OrdinalIgnoreCase }
        return $fullPath.Equals($rootPath, $comparison) -or $fullPath.StartsWith(($rootPath + [System.IO.Path]::DirectorySeparatorChar), $comparison)
    } catch { return $false }
}

function Assert-LabNoReparsePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $cursor = [System.IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ('Reparse point is outside the lab file contract: ' + $cursor)
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($cursor.TrimEnd([char[]]@('\', '/')))
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Get-LabFilesBounded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [ValidateRange(1, 100000)][int]$MaxEntries = 20000,
        [ValidateRange(1, 40)][int]$MaxDepth = 18
    )
    Assert-LabNoReparsePath -Path $Root
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw ('Directory is missing: ' + $Root) }
    $rootPath = [System.IO.Path]::GetFullPath($Root)
    $files = New-Object 'System.Collections.Generic.List[object]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    $queue.Enqueue([pscustomobject]@{ Path = $rootPath; Depth = 0 })
    $entries = 0
    $truncated = $false
    while ($queue.Count -gt 0 -and -not $truncated) {
        $current = $queue.Dequeue()
        $enumerator = $null
        try {
            Assert-LabNoReparsePath -Path $current.Path
            $directory = New-Object System.IO.DirectoryInfo -ArgumentList $current.Path
            $enumerator = $directory.EnumerateFileSystemInfos().GetEnumerator()
            while ($enumerator.MoveNext()) {
                if ($entries -ge $MaxEntries) { $truncated = $true; break }
                $entries++
                $item = $enumerator.Current
                if (-not (Test-LabPathContained -Root $rootPath -Path $item.FullName)) { throw 'Traversal escaped its root.' }
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $warnings.Add('SKIPPED_REPARSE: ' + $item.FullName)
                    continue
                }
                if (($item.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                    if ($current.Depth -ge $MaxDepth) { $warnings.Add('DEPTH_LIMIT: ' + $item.FullName); continue }
                    $queue.Enqueue([pscustomobject]@{ Path = $item.FullName; Depth = ($current.Depth + 1) })
                } else { $files.Add($item) }
            }
        } catch { $warnings.Add('SCAN_ERROR: ' + $current.Path + ': ' + $_.Exception.Message) }
        finally { if ($null -ne $enumerator -and $enumerator -is [IDisposable]) { $enumerator.Dispose() } }
    }
    return [pscustomobject]@{ Files = @($files.ToArray()); EntriesScanned = $entries; Truncated = $truncated; Warnings = @($warnings.ToArray()) }
}

function Copy-LabEvidenceFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [ValidateRange(1, 67108864)][long]$MaxBytes = 16777216
    )
    if (-not (Test-LabPathContained -Root $SourceRoot -Path $Source)) { throw 'Evidence source escaped its owned root.' }
    if (-not (Test-LabPathContained -Root $DestinationRoot -Path $Destination)) { throw 'Evidence destination escaped its capture root.' }
    Assert-LabNoReparsePath -Path $Source
    Assert-LabNoReparsePath -Path $Destination
    $before = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    if ($before.PSIsContainer) { throw 'Evidence source must be a file.' }
    if ($before.Length -gt $MaxBytes) {
        return [pscustomobject]@{ status = 'SKIPPED_LIMIT'; source = $Source; source_bytes = $before.Length; max_bytes = $MaxBytes }
    }
    if (Test-Path -LiteralPath $Destination) { throw 'An evidence snapshot cannot be overwritten.' }
    $parent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Destination))
    [void][System.IO.Directory]::CreateDirectory($parent)
    Assert-LabNoReparsePath -Path $parent
    $temporary = $Destination + '.partial-' + [guid]::NewGuid().ToString('N')
    $inputFile = $null
    $outputFile = $null
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $inputFile = New-Object System.IO.FileStream -ArgumentList $Source, ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::Read), $share
        $bytes = $inputFile.Length
        if ($bytes -gt $MaxBytes) { throw 'Evidence file grew beyond its byte limit before capture.' }
        $outputFile = New-Object System.IO.FileStream -ArgumentList $temporary, ([System.IO.FileMode]::CreateNew), ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::None)
        $buffer = New-Object byte[] 65536
        $remaining = $bytes
        while ($remaining -gt 0) {
            $wanted = [int][Math]::Min($remaining, $buffer.Length)
            $read = $inputFile.Read($buffer, 0, $wanted)
            if ($read -eq 0) { throw 'Evidence source was truncated during capture.' }
            $outputFile.Write($buffer, 0, $read)
            $remaining -= $read
        }
        $outputFile.Flush()
        $outputFile.Dispose(); $outputFile = $null
        $inputFile.Dispose(); $inputFile = $null
        $after = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
        $changed = $before.Length -ne $after.Length -or $before.LastWriteTimeUtc.Ticks -ne $after.LastWriteTimeUtc.Ticks
        [System.IO.File]::Move($temporary, $Destination)
        return [pscustomobject]@{
            status = 'CAPTURED'; source = $Source; destination = $Destination
            source_bytes = $before.Length; captured_bytes = $bytes; source_changed_during_copy = $changed
            sha256 = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        }
    } finally {
        if ($null -ne $outputFile) { $outputFile.Dispose() }
        if ($null -ne $inputFile) { $inputFile.Dispose() }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Test-LabSettingValues {
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Expected = @(), [AllowEmptyCollection()][string[]]$Actual = @())
    if ($Expected.Count -ne $Actual.Count) { return $false }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if (-not $Expected[$index].Trim().Equals($Actual[$index].Trim(), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Get-LabVdfValue {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text, [Parameter(Mandatory = $true)][string]$Key)
    $pattern = '"' + [regex]::Escape($Key) + '"\s*"((?:\\.|[^"\\])*)"'
    $values = @([regex]::Matches($Text, $pattern) | ForEach-Object {
        $_.Groups[1].Value.Replace('\\', '\').Replace('\"', '"')
    })
    return ,$values
}

function Read-LabTextBounded {
    param([Parameter(Mandatory = $true)][string]$Path, [long]$MaxBytes = 2097152)
    Assert-LabNoReparsePath -Path $Path
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -gt $MaxBytes) { throw ('Text file exceeds its read contract: ' + $Path) }
    return [System.IO.File]::ReadAllText($item.FullName)
}

function Get-LabLibraryRoots {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SteamRoot)
    $roots = New-Object 'System.Collections.Generic.List[string]'
    $roots.Add([System.IO.Path]::GetFullPath($SteamRoot))
    $vdfPath = Join-Path $SteamRoot 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdfPath -PathType Leaf) {
        $text = Read-LabTextBounded -Path $vdfPath
        $candidates = Get-LabVdfValue -Text $text -Key 'path'
        foreach ($match in [regex]::Matches($text, '"\d+"\s*"((?:\\.|[^"\\])*)"')) {
            $candidates += $match.Groups[1].Value.Replace('\\', '\')
        }
        foreach ($candidate in $candidates) {
            if ([string]::IsNullOrWhiteSpace($candidate) -or -not [System.IO.Path]::IsPathRooted($candidate)) { continue }
            $full = [System.IO.Path]::GetFullPath($candidate)
            if (-not $roots.Contains($full)) { $roots.Add($full) }
        }
    }
    return ,($roots.ToArray())
}

function Invoke-LabNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 20
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    if ($WorkingDirectory) {
        if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) { throw 'Command working directory is missing.' }
        $startInfo.WorkingDirectory = [System.IO.Path]::GetFullPath($WorkingDirectory)
    }
    $startInfo.Arguments = Join-LabWindowsArguments -Arguments $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw ('Could not start ' + $Executable) }
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            throw ('Command timed out without termination; close any prompt manually: ' + [System.IO.Path]::GetFileName($Executable))
        }
        if (-not $outputTask.Wait(1000) -or -not $errorTask.Wait(1000)) { throw 'Command output remained open after process exit.' }
        $output = $outputTask.Result
        $errorOutput = $errorTask.Result
        if ($output.Length -gt 1048576 -or $errorOutput.Length -gt 1048576) { throw 'Tool output exceeded its limit.' }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output; Error = $errorOutput }
    } finally { $process.Dispose() }
}

function Get-LabBoxNames {
    param([Parameter(Mandatory = $true)][string]$SbieIniExe, [switch]$EnabledOnly)
    $arguments = @('query', '*')
    if ($EnabledOnly) { $arguments = @('query', '/boxes', '*') }
    $result = Invoke-LabNative -Executable $SbieIniExe -Arguments $arguments
    if ($result.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($result.Error)) { throw 'Sandboxie box enumeration failed.' }
    $names = @($result.Output -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    # The all-sections query also returns unrelated user/template sections.
    # Their names are opaque; only this lab's own two names are constrained.
    foreach ($name in $names) { if ($name.Length -gt 512 -or $name -match '[\x00-\x1f\x7f]') { throw 'Sandboxie returned a malformed section name.' } }
    if (-not $EnabledOnly -and $names -notcontains 'GlobalSettings') { throw 'Sandboxie returned no valid configuration enumeration.' }
    return ,$names
}

function Get-LabSetting {
    param([string]$SbieIniExe, [string]$BoxName, [string]$Setting, [switch]$Expand)
    $verb = 'query'
    if ($Expand) { $verb = 'queryex' }
    $result = Invoke-LabNative -Executable $SbieIniExe -Arguments @($verb, $BoxName, $Setting)
    if ($result.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($result.Error)) { throw ('Cannot query Sandboxie setting ' + $Setting) }
    return ,@($result.Output -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
}

function Set-LabVerifiedSetting {
    param([string]$SbieIniExe, [string]$BoxName, [string]$Setting, [string]$Value)
    $result = Invoke-LabNative -Executable $SbieIniExe -Arguments @('set', $BoxName, $Setting, $Value)
    if ($result.ExitCode -ne 0) { throw ('Sandboxie rejected setting ' + $Setting) }
    $actual = Get-LabSetting -SbieIniExe $SbieIniExe -BoxName $BoxName -Setting $Setting
    if (-not (Test-LabSettingValues -Expected @($Value) -Actual $actual)) { throw ('Sandboxie setting did not persist: ' + $Setting) }
}

function Write-LabJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value, [switch]$ReplaceOwned)
    Assert-LabNoReparsePath -Path $Path
    if ((Test-Path -LiteralPath $Path) -and -not $ReplaceOwned) { throw ('Refusing to overwrite JSON output: ' + $Path) }
    $temporary = $Path + '.partial-' + [guid]::NewGuid().ToString('N')
    try {
        $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
        $stream = New-Object System.IO.FileStream -ArgumentList $temporary, ([System.IO.FileMode]::CreateNew), ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::None)
        try {
            $bytes = $encoding.GetBytes(($Value | ConvertTo-Json -Depth 14))
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } finally { $stream.Dispose() }
        if ($ReplaceOwned -and (Test-Path -LiteralPath $Path)) { [System.IO.File]::Replace($temporary, $Path, $null) }
        else { [System.IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } }
}

function Read-LabJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Read-LabTextBounded -Path $Path -MaxBytes 131072 | ConvertFrom-Json -ErrorAction Stop)
}

function Get-LabToolPaths {
    param([string]$SteamRoot, [string]$GameRoot, [string]$SandboxieRoot)
    $steamCandidates = New-Object 'System.Collections.Generic.List[string]'
    if ($SteamRoot) { $steamCandidates.Add($SteamRoot) }
    else {
        foreach ($registryPath in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
            $registry = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
            if ($null -ne $registry) {
                foreach ($property in @('SteamPath', 'InstallPath')) {
                    if ($null -ne $registry.PSObject.Properties[$property] -and $registry.$property) { $steamCandidates.Add([string]$registry.$property) }
                }
            }
        }
        foreach ($base in @([Environment]::GetEnvironmentVariable('ProgramFiles(x86)'), [Environment]::GetEnvironmentVariable('ProgramFiles'), 'D:\')) {
            if ($base) { $steamCandidates.Add((Join-Path $base 'Steam')) }
        }
    }
    $foundSteam = $null
    foreach ($candidate in $steamCandidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'steam.exe') -PathType Leaf) { $foundSteam = [System.IO.Path]::GetFullPath($candidate); break }
    }
    $sandboxCandidates = New-Object 'System.Collections.Generic.List[string]'
    if ($SandboxieRoot) { $sandboxCandidates.Add($SandboxieRoot) }
    else {
        foreach ($registryPath in @('HKLM:\SOFTWARE\Sandboxie', 'HKLM:\SOFTWARE\WOW6432Node\Sandboxie')) {
            $registry = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
            if ($null -ne $registry -and $null -ne $registry.PSObject.Properties['Home'] -and $registry.Home) { $sandboxCandidates.Add([string]$registry.Home) }
        }
        $serviceRegistry = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\SbieSvc' -ErrorAction SilentlyContinue
        if ($null -ne $serviceRegistry -and $null -ne $serviceRegistry.PSObject.Properties['ImagePath']) {
            $match = [regex]::Match([Environment]::ExpandEnvironmentVariables([string]$serviceRegistry.ImagePath), '^\s*(?:"([^"]+)"|([^\s]+))')
            if ($match.Success) {
                $serviceExe = $match.Groups[1].Value
                if (-not $serviceExe) { $serviceExe = $match.Groups[2].Value }
                $sandboxCandidates.Add([System.IO.Path]::GetDirectoryName($serviceExe))
            }
        }
        foreach ($base in @([Environment]::GetEnvironmentVariable('ProgramFiles'), [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'), 'D:\')) {
            if ($base) { foreach ($leaf in @('Sandboxie-Plus', 'Sandboxie')) { $sandboxCandidates.Add((Join-Path $base $leaf)) } }
        }
    }
    $foundSandbox = $null
    foreach ($candidate in $sandboxCandidates) {
        if ((Test-Path -LiteralPath (Join-Path $candidate 'Start.exe') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $candidate 'SbieIni.exe') -PathType Leaf)) {
            $foundSandbox = [System.IO.Path]::GetFullPath($candidate); break
        }
    }
    $foundGame = $null
    $manifest = $null
    $buildId = $null
    if ($GameRoot) {
        if (Test-Path -LiteralPath (Join-Path $GameRoot 'Attila.exe') -PathType Leaf) { $foundGame = [System.IO.Path]::GetFullPath($GameRoot) }
    } elseif ($foundSteam) {
        foreach ($library in (Get-LabLibraryRoots -SteamRoot $foundSteam)) {
            $candidateManifest = Join-Path $library 'steamapps\appmanifest_325610.acf'
            if (-not (Test-Path -LiteralPath $candidateManifest -PathType Leaf)) { continue }
            $manifestText = Read-LabTextBounded -Path $candidateManifest
            $appId = Get-LabVdfValue -Text $manifestText -Key 'appid'
            $installDir = Get-LabVdfValue -Text $manifestText -Key 'installdir'
            if ($appId.Count -ne 1 -or $appId[0] -ne '325610' -or $installDir.Count -ne 1 -or $installDir[0] -match '[\\/:]|^\.{1,2}$') { continue }
            $candidateGame = Join-Path (Join-Path $library 'steamapps\common') $installDir[0]
            if (Test-Path -LiteralPath (Join-Path $candidateGame 'Attila.exe') -PathType Leaf) {
                $foundGame = [System.IO.Path]::GetFullPath($candidateGame); $manifest = $candidateManifest
                $builds = Get-LabVdfValue -Text $manifestText -Key 'buildid'
                if ($builds.Count -eq 1) { $buildId = $builds[0] }
                break
            }
        }
    }
    return [pscustomobject]@{ steam_root = $foundSteam; game_root = $foundGame; sandboxie_root = $foundSandbox; app_manifest = $manifest; game_build_id = $buildId }
}

function Get-LabFileIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.PSIsContainer -or $item.Length -gt 536870912) { throw 'Identity file exceeds its size contract.' }
        return [pscustomobject]@{ path = $item.FullName; bytes = $item.Length; sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant(); file_version = $item.VersionInfo.FileVersion; status = 'OBSERVED' }
    } catch { return [pscustomobject]@{ path = $Path; status = 'BLOCKED'; reason = $_.Exception.Message } }
}

function Get-LabSourceIdentity {
    param([Parameter(Mandatory = $true)][string]$ScriptDirectory)
    $source = [ordered]@{ source_sha = 'unknown'; kind = 'unknown'; working_tree = 'NOT_CHECKED'; integrity = 'NOT_VERIFIED'; files = @() }
    $toolLeaves = @('dual_client_lab.ps1', 'dual_client_lab_core.psm1', 'dual_client_probe.ps1')
    foreach ($leaf in $toolLeaves) { $source.files += Get-LabFileIdentity -Path (Join-Path $ScriptDirectory $leaf) }
    $directory = $ScriptDirectory
    for ($depth = 0; $depth -le 2; $depth++) {
        $manifestPath = Join-Path $directory 'package_manifest.json'
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $manifest = Read-LabJson -Path $manifestPath
            if ($null -eq $manifest.PSObject.Properties['schema'] -or $manifest.schema -ne 1 -or $null -eq $manifest.PSObject.Properties['source_sha'] -or $manifest.source_sha -notmatch '^[0-9a-fA-F]{40}$') {
                throw 'Package manifest has an unsupported schema or source identity.'
            }
            if ($null -eq $manifest.PSObject.Properties['files']) { throw 'Package manifest is missing its file identity list.' }
            foreach ($leaf in $toolLeaves) {
                $fixedRelative = 'scripts/runtime/' + $leaf
                $matches = @($manifest.files | Where-Object { $null -ne $_.PSObject.Properties['path'] -and $_.path -ceq $fixedRelative })
                if ($matches.Count -ne 1) { throw ('Package manifest must contain exactly one identity for ' + $fixedRelative) }
                $record = $matches[0]
                if ($null -eq $record.PSObject.Properties['sha256'] -or $record.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or $null -eq $record.PSObject.Properties['bytes'] -or [string]$record.bytes -notmatch '^\d+$') {
                    throw ('Invalid package file identity for ' + $fixedRelative)
                }
                $fixedPath = [System.IO.Path]::GetFullPath((Join-Path $directory $fixedRelative))
                $runningPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptDirectory $leaf))
                if ($fixedPath -ine $runningPath) { throw 'Package manifest does not describe this runtime script location.' }
                $actual = @($source.files | Where-Object { $_.path -ieq $runningPath })
                if ($actual.Count -ne 1 -or $actual[0].status -ne 'OBSERVED' -or $actual[0].sha256 -ine $record.sha256 -or $actual[0].bytes -ne [long]$record.bytes) {
                    throw ('Package integrity mismatch: ' + $fixedRelative)
                }
            }
            $source.source_sha = $manifest.source_sha.ToLowerInvariant(); $source.kind = 'package_manifest'; $source.integrity = 'MANIFEST_FILES_MATCH'; break
        }
        $parent = [System.IO.Path]::GetDirectoryName($directory)
        if (-not $parent) { break }
        $directory = $parent
    }
    if ($source.kind -eq 'unknown') {
        $gitCommand = Get-Command git -ErrorAction SilentlyContinue
        if ($null -ne $gitCommand) {
            try {
                $revision = Invoke-LabNative -Executable $gitCommand.Source -Arguments @('-C', $ScriptDirectory, 'rev-parse', 'HEAD')
                if ($revision.ExitCode -eq 0 -and $revision.Output.Trim() -match '^[0-9a-fA-F]{40}$') {
                    $source.source_sha = $revision.Output.Trim().ToLowerInvariant(); $source.kind = 'git'
                    $dirty = Invoke-LabNative -Executable $gitCommand.Source -Arguments @('-C', $ScriptDirectory, 'status', '--porcelain')
                    if ($dirty.ExitCode -eq 0) { $source.working_tree = $(if ($dirty.Output.Trim()) { 'DIRTY' } else { 'CLEAN' }) }
                }
            } catch { $source.kind = 'unknown'; $source.source_sha = 'unknown' }
        }
    }
    return [pscustomobject]$source
}

function Get-LabAttilaProcesses {
    param([string]$SbieStartExe, [string]$BoxName)
    $first = Invoke-LabNative -Executable $SbieStartExe -Arguments @('/silent', ('/box:' + $BoxName), '/listpids')
    if ($first.ExitCode -ne 0) { throw ('Cannot enumerate processes in ' + $BoxName) }
    $firstIds = ConvertFrom-LabPidList -Text $first.Output
    $candidates = @()
    $warnings = @()
    foreach ($processId in $firstIds) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process -or $process.ProcessName -ine 'Attila') { continue }
        try {
            $path = $process.Path
            $birth = $process.StartTime.ToUniversalTime()
            if ([string]::IsNullOrWhiteSpace($path) -or [System.IO.Path]::GetFileName($path) -ine 'Attila.exe') { throw 'Executable path is unavailable or unexpected.' }
            $candidates += [pscustomobject]@{ process_id = $processId; path = $path; started_utc = $birth.ToString('o'); birth_ticks = $birth.Ticks }
        } catch { $warnings += ('PROCESS_UNVERIFIED: ' + $processId + ': ' + $_.Exception.Message) }
    }
    $second = Invoke-LabNative -Executable $SbieStartExe -Arguments @('/silent', ('/box:' + $BoxName), '/listpids')
    if ($second.ExitCode -ne 0) { throw ('Cannot recheck processes in ' + $BoxName) }
    $secondIds = ConvertFrom-LabPidList -Text $second.Output
    $observed = @()
    foreach ($candidate in $candidates) {
        if ($secondIds -notcontains $candidate.process_id) { $warnings += ('PROCESS_EXITED: ' + $candidate.process_id); continue }
        try {
            $current = Get-Process -Id $candidate.process_id -ErrorAction Stop
            if ($current.ProcessName -ine 'Attila' -or $current.StartTime.ToUniversalTime().Ticks -ne $candidate.birth_ticks -or $current.Path -ine $candidate.path) { throw 'Process identity changed between observations.' }
            $observed += [pscustomobject]@{ process_id = $candidate.process_id; box = $BoxName; path = $candidate.path; started_utc = $candidate.started_utc; membership = 'OBSERVED_TWICE'; executable = (Get-LabFileIdentity -Path $candidate.path) }
        } catch { $warnings += ('PROCESS_CHANGED: ' + $candidate.process_id + ': ' + $_.Exception.Message) }
    }
    return [pscustomobject]@{ processes_observed = $observed.Count; processes = @($observed); warnings = @($warnings); multiplayer = 'NOT_RUN'; accounts = 'NOT_VERIFIED' }
}

Export-ModuleMember -Function ConvertTo-LabWindowsArgument, Join-LabWindowsArguments, ConvertFrom-LabPidList, Test-LabPathContained, Assert-LabNoReparsePath, Get-LabFilesBounded, Copy-LabEvidenceFile, Test-LabSettingValues, Get-LabVdfValue, Read-LabTextBounded, Get-LabLibraryRoots, Invoke-LabNative, Get-LabBoxNames, Get-LabSetting, Set-LabVerifiedSetting, Write-LabJson, Read-LabJson, Get-LabToolPaths, Get-LabFileIdentity, Get-LabSourceIdentity, Get-LabAttilaProcesses
