[CmdletBinding()]
param(
    [string]$RuntimeDirectory = (Join-Path $PSScriptRoot '../runtime')
)

# Synthetic helper/preflight checks only. No Steam, Sandboxie or game is launched.
# Compatible with Windows PowerShell 5.1 and PowerShell 7; no Pester dependency.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $RuntimeDirectory 'dual_client_lab_core.psm1') -Force -ErrorAction Stop

$script:LabCheckCount = 0
$script:LabSkippedCount = 0
$script:LabFailures = New-Object 'System.Collections.Generic.List[string]'

function Assert-LabTrue {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-LabEqual {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) {
        throw ('{0}: expected [{1}], received [{2}]' -f $Message, $Expected, $Actual)
    }
}

function Assert-LabSequence {
    param(
        [AllowEmptyCollection()][object[]]$Actual,
        [AllowEmptyCollection()][object[]]$Expected,
        [string]$Message
    )
    Assert-LabEqual $Actual.Count $Expected.Count ($Message + ' count')
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-LabEqual $Actual[$index] $Expected[$index] ($Message + ' item ' + $index)
    }
}

function Assert-LabThrows {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action | Out-Null }
    catch { return }
    throw ('Expected rejection: ' + $Message)
}

function Invoke-LabCheck {
    param([string]$Name, [scriptblock]$Body)
    $script:LabCheckCount++
    try {
        & $Body | Out-Null
        Write-Host ('PASS: ' + $Name)
    }
    catch {
        $failure = '{0}: {1}' -f $Name, $_.Exception.Message
        [void]$script:LabFailures.Add($failure)
        Write-Host ('FAIL: ' + $failure)
    }
}

function Write-LabFixture {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding -ArgumentList $false))
}

$labTemp = Join-Path ([System.IO.Path]::GetTempPath()) ('mk1212-dual-client-tests-' + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($labTemp)

try {
    # The Windows parser is an independent oracle; tests do not reimplement the
    # quoting algorithm. A fixed argv[0] avoids its separate parsing grammar.
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        if ($null -eq ('Mk1212LabTests.CommandLineOracle' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace Mk1212LabTests {
    public static class CommandLineOracle {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CommandLineToArgvW(string commandLine, out int count);
        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);
        public static string[] Parse(string commandLine) {
            int count;
            IntPtr memory = CommandLineToArgvW(commandLine, out count);
            if (memory == IntPtr.Zero) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            try {
                string[] result = new string[count];
                for (int index = 0; index < count; index++) {
                    result[index] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory, index * IntPtr.Size));
                }
                return result;
            }
            finally { LocalFree(memory); }
        }
    }
}
'@
        }
        Invoke-LabCheck 'Windows quoting preserves empty, quoted, Unicode and trailing-slash arguments' {
            $values = @(
                '', 'plain', 'two words', ('tab' + [char]9 + 'value'),
                'D:\Steam Games\', 'D:\one\two\\', 'embedded"quote',
                'slashes\\"then quote', ('za' + [char]0x017C + [char]0x00F3 + [char]0x0142 + [char]0x0107),
                '&|<>^%PATH%!literal!', '[brackets]', "apostrophe's value"
            )
            foreach ($value in $values) {
                $encoded = ConvertTo-LabWindowsArgument -Value $value
                $parsed = @([Mk1212LabTests.CommandLineOracle]::Parse('probe.exe ' + $encoded))
                Assert-LabSequence $parsed @('probe.exe', $value) 'single Windows argument'
            }
            $joined = Join-LabWindowsArguments -Arguments $values
            $parsed = @([Mk1212LabTests.CommandLineOracle]::Parse('probe.exe ' + $joined))
            Assert-LabSequence $parsed (@('probe.exe') + $values) 'joined Windows arguments'
        }
    }
    else {
        $script:LabSkippedCount++
        Write-Host 'SKIP: independent Windows quoting oracle requires Windows'
    }
    Invoke-LabCheck 'NUL arguments are refused and an empty argument list stays empty' {
        Assert-LabThrows { ConvertTo-LabWindowsArgument -Value ('before' + [char]0 + 'after') } 'embedded NUL'
        Assert-LabEqual (Join-LabWindowsArguments -Arguments @()) '' 'empty argument list'
    }
    Invoke-LabCheck 'Sandboxie raw slash switches precede the quoted child executable' {
        # Start.exe's Parse_Command_Line recognizes switches by the raw leading
        # slash, before normal child argv parsing; quoted switches are not equivalent.
        $commandLine = Join-LabWindowsArguments -Arguments @('/box:MK1212LabHost', '/wait', 'C:\Program Files\PowerShell\powershell.exe', '-NoProfile')
        Assert-LabTrue ($commandLine.StartsWith('/box:MK1212LabHost /wait "C:\Program Files\PowerShell\powershell.exe" ')) 'boxed launch must keep raw option prefixes'
        Assert-LabEqual (Join-LabWindowsArguments -Arguments @('/reload')) '/reload' 'raw reload option'
        Assert-LabEqual (Join-LabWindowsArguments -Arguments @('/silent', '/box:MK1212LabClient', '/listpids')) '/silent /box:MK1212LabClient /listpids' 'raw PID enumeration options'
    }

    Invoke-LabCheck 'PID count zero is a valid empty process list' {
        $processIds = ConvertFrom-LabPidList -Text "0`r`n"
        Assert-LabSequence $processIds @() 'zero process count'
    }
    Invoke-LabCheck 'PID list preserves singleton and counted decimal IDs' {
        $processIds = ConvertFrom-LabPidList -Text "1`r`n123`r`n"
        Assert-LabSequence $processIds @(123) 'one process'
        $processIds = ConvertFrom-LabPidList -Text "2`r`n123`r`n456`r`n"
        Assert-LabSequence $processIds @(123, 456) 'two processes'
    }
    Invoke-LabCheck 'PID parser rejects empty, malformed, duplicated and inconsistent output' {
        $invalidLists = @('', "`r`n", 'unavailable', "1`n", "0`n123", "2`n123", "1`n123`n456", "1`n0", "1`n-2", "1`n1.5", "1`n4294967296", "2`n123`n123", "1`n123 extra", "4097`n")
        foreach ($invalid in $invalidLists) {
            Assert-LabThrows { ConvertFrom-LabPidList -Text $invalid } ('PID output [' + $invalid + ']')
        }
    }

    Invoke-LabCheck 'Path containment rejects sibling prefixes and normalized traversal' {
        $ownedRoot = Join-Path $labTemp 'owned'
        [void][System.IO.Directory]::CreateDirectory($ownedRoot)
        Assert-LabTrue (Test-LabPathContained -Root $ownedRoot -Path (Join-Path $ownedRoot 'child/capture.log')) 'child path must be contained'
        Assert-LabTrue (-not (Test-LabPathContained -Root $ownedRoot -Path (Join-Path $labTemp 'owned-other/capture.log'))) 'sibling sharing prefix must be rejected'
        Assert-LabTrue (-not (Test-LabPathContained -Root $ownedRoot -Path (Join-Path $ownedRoot '../outside.log'))) 'parent traversal must be rejected'
        Assert-LabTrue (-not (Test-LabPathContained -Root ($ownedRoot + [System.IO.Path]::DirectorySeparatorChar) -Path (Join-Path $labTemp 'outside.log'))) 'trailing separator must not weaken containment'
    }
    Invoke-LabCheck 'Bounded enumeration returns files including literal bracket names' {
        $treeRoot = Join-Path $labTemp 'enumeration'
        Write-LabFixture (Join-Path $treeRoot 'a.log') 'A'
        $bracketPath = Join-Path $treeRoot 'nested/[capture].log'
        Write-LabFixture $bracketPath 'B'
        $scan = Get-LabFilesBounded -Root $treeRoot -MaxEntries 10 -MaxDepth 4
        Assert-LabEqual $scan.Files.Count 2 'enumerated file count'
        Assert-LabTrue (@($scan.Files.FullName) -contains [System.IO.Path]::GetFullPath($bracketPath)) 'literal bracket filename must survive scanning'
        Assert-LabTrue (-not $scan.Truncated) 'complete small scan must not be truncated'
        Assert-LabEqual $scan.Warnings.Count 0 'complete small scan warning count'
    }
    Invoke-LabCheck 'Entry budget reports truncation without overscanning' {
        $entryRoot = Join-Path $labTemp 'entry-limit'
        Write-LabFixture (Join-Path $entryRoot 'a.log') 'A'
        Write-LabFixture (Join-Path $entryRoot 'b.log') 'B'
        Write-LabFixture (Join-Path $entryRoot 'c.log') 'C'
        $scan = Get-LabFilesBounded -Root $entryRoot -MaxEntries 2 -MaxDepth 4
        Assert-LabTrue $scan.Truncated 'over-budget scan must declare truncation'
        Assert-LabEqual $scan.EntriesScanned 2 'entry budget'
        Assert-LabTrue ($scan.Files.Count -le 2) 'result cannot exceed entry budget'
    }
    Invoke-LabCheck 'Depth budget reports omitted subtrees and missing roots are rejected' {
        $depthRoot = Join-Path $labTemp 'depth-limit'
        Write-LabFixture (Join-Path $depthRoot 'a/b/c/d/e/capture.log') 'deep'
        $scan = Get-LabFilesBounded -Root $depthRoot -MaxEntries 20 -MaxDepth 2
        Assert-LabEqual $scan.Files.Count 0 'deep files must not be scanned'
        Assert-LabTrue (@($scan.Warnings | Where-Object { $_ -like 'DEPTH_LIMIT:*' }).Count -gt 0) 'depth cutoff must be explicit'
        Assert-LabThrows { Get-LabFilesBounded -Root (Join-Path $labTemp 'missing') } 'missing scan root'
    }

    $sourceRoot = Join-Path $labTemp 'source'
    $destinationRoot = Join-Path $labTemp 'capture'
    [void][System.IO.Directory]::CreateDirectory($sourceRoot)
    [void][System.IO.Directory]::CreateDirectory($destinationRoot)
    Invoke-LabCheck 'Evidence capture preserves exact bytes and SHA at the inclusive limit' {
        $source = Join-Path $sourceRoot '[sample].log'
        $destination = Join-Path $destinationRoot 'nested/[sample].log'
        Write-LabFixture $source 'ABCD'
        $copy = Copy-LabEvidenceFile -Source $source -Destination $destination -SourceRoot $sourceRoot -DestinationRoot $destinationRoot -MaxBytes 4
        Assert-LabEqual $copy.status 'CAPTURED' 'capture status'
        Assert-LabEqual $copy.captured_bytes 4 'captured bytes'
        Assert-LabEqual ([System.IO.File]::ReadAllText($destination)) 'ABCD' 'captured content'
        Assert-LabEqual $copy.sha256 ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()) 'source and snapshot digest'
        Assert-LabTrue (-not $copy.source_changed_during_copy) 'unchanged fixture provenance'
    }
    Invoke-LabCheck 'Existing evidence cannot be overwritten' {
        $source = Join-Path $sourceRoot 'overwrite.log'
        $destination = Join-Path $destinationRoot 'keep.log'
        Write-LabFixture $source 'new'
        Write-LabFixture $destination 'last-known-good'
        Assert-LabThrows { Copy-LabEvidenceFile -Source $source -Destination $destination -SourceRoot $sourceRoot -DestinationRoot $destinationRoot } 'existing snapshot'
        Assert-LabEqual ([System.IO.File]::ReadAllText($destination)) 'last-known-good' 'preserved evidence'
        Assert-LabEqual ([System.IO.File]::ReadAllText($source)) 'new' 'source is unchanged'
    }
    Invoke-LabCheck 'Oversized evidence is explicitly skipped without a destination or partial file' {
        $source = Join-Path $sourceRoot 'large.log'
        $destination = Join-Path $destinationRoot 'large.log'
        Write-LabFixture $source 'ABCDE'
        $copy = Copy-LabEvidenceFile -Source $source -Destination $destination -SourceRoot $sourceRoot -DestinationRoot $destinationRoot -MaxBytes 4
        Assert-LabEqual $copy.status 'SKIPPED_LIMIT' 'over-limit status'
        Assert-LabEqual $copy.source_bytes 5 'observed source size'
        Assert-LabTrue (-not (Test-Path -LiteralPath $destination)) 'over-limit snapshot must not be created'
        Assert-LabEqual @(Get-ChildItem -LiteralPath $destinationRoot -Filter 'large.log.partial-*' -Force).Count 0 'no abandoned partial capture'
    }
    Invoke-LabCheck 'Evidence source and destination escapes are rejected before writes' {
        $outsideSource = Join-Path $labTemp 'source-other/leak.log'
        $insideSource = Join-Path $sourceRoot 'inside.log'
        $insideDestination = Join-Path $destinationRoot 'leak.log'
        $outsideDestination = Join-Path $labTemp 'capture-other/leak.log'
        Write-LabFixture $outsideSource 'external'
        Write-LabFixture $insideSource 'inside'
        Assert-LabThrows { Copy-LabEvidenceFile -Source $outsideSource -Destination $insideDestination -SourceRoot $sourceRoot -DestinationRoot $destinationRoot } 'outside source'
        Assert-LabThrows { Copy-LabEvidenceFile -Source $insideSource -Destination $outsideDestination -SourceRoot $sourceRoot -DestinationRoot $destinationRoot } 'outside destination'
        Assert-LabThrows { Copy-LabEvidenceFile -Source $sourceRoot -Destination $insideDestination -SourceRoot $sourceRoot -DestinationRoot $destinationRoot } 'directory as evidence'
        Assert-LabTrue (-not (Test-Path -LiteralPath $insideDestination)) 'rejected source cannot leave evidence'
        Assert-LabTrue (-not (Test-Path -LiteralPath $outsideDestination)) 'rejected destination cannot be written'
    }
    Invoke-LabCheck 'An unreadable source leaves no completed or partial snapshot' {
        $source = Join-Path $sourceRoot 'locked.log'
        $destination = Join-Path $destinationRoot 'locked.log'
        Write-LabFixture $source 'locked'
        $heldFile = [System.IO.File]::Open($source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            Assert-LabThrows { Copy-LabEvidenceFile -Source $source -Destination $destination -SourceRoot $sourceRoot -DestinationRoot $destinationRoot } 'locked source'
        }
        finally { $heldFile.Dispose() }
        Assert-LabTrue (-not (Test-Path -LiteralPath $destination)) 'failed read cannot leave completed snapshot'
        Assert-LabEqual @(Get-ChildItem -LiteralPath $destinationRoot -Filter 'locked.log.partial-*' -Force).Count 0 'failed read cannot leave partial snapshot'
    }

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Invoke-LabCheck 'Junctions are not traversed or used to escape evidence ownership' {
            $outside = Join-Path $labTemp 'junction-target'
            Write-LabFixture (Join-Path $outside 'outside.log') 'not owned by source root'
            $junction = Join-Path $sourceRoot 'junction'
            New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
            try {
                $scan = Get-LabFilesBounded -Root $sourceRoot
                Assert-LabTrue (@($scan.Warnings | Where-Object { $_ -like 'SKIPPED_REPARSE:*' }).Count -gt 0) 'junction skip must be explicit'
                Assert-LabTrue (@($scan.Files.Name) -notcontains 'outside.log') 'junction target cannot be captured'
                Assert-LabThrows { Get-LabFilesBounded -Root $junction } 'junction scan root'
                Assert-LabThrows { Copy-LabEvidenceFile -Source (Join-Path $junction 'outside.log') -Destination (Join-Path $destinationRoot 'junction.log') -SourceRoot $sourceRoot -DestinationRoot $destinationRoot } 'source below junction'
            }
            finally { [System.IO.Directory]::Delete($junction) }
            Assert-LabEqual ([System.IO.File]::ReadAllText((Join-Path $outside 'outside.log'))) 'not owned by source root' 'junction target remains intact'
        }
    }
    else {
        $script:LabSkippedCount++
        Write-Host 'SKIP: Windows junction fixture requires Windows'
    }

    Invoke-LabCheck 'Settings validation rejects missing, extra, reordered and different values' {
        Assert-LabTrue (Test-LabSettingValues -Expected @() -Actual @()) 'empty settings'
        Assert-LabTrue (Test-LabSettingValues -Expected @('y', 'D:\Lab Path') -Actual @(' Y ', 'd:\lab path ')) 'documented case and edge-space normalization'
        Assert-LabTrue (-not (Test-LabSettingValues -Expected @('y') -Actual @())) 'missing setting'
        Assert-LabTrue (-not (Test-LabSettingValues -Expected @('y') -Actual @('y', 'y'))) 'extra setting'
        Assert-LabTrue (-not (Test-LabSettingValues -Expected @('first', 'second') -Actual @('second', 'first'))) 'changed order'
        Assert-LabTrue (-not (Test-LabSettingValues -Expected @('y') -Actual @('n'))) 'different setting'
    }
    Invoke-LabCheck 'VDF extraction preserves empty and duplicate values and treats keys literally' {
        $vdf = '"path" "D:\\Steam Library" "path" "E:\\Other" "empty" "" "a.b" "literal" "axb" "wrong" "label" "a\"b"'
        $values = Get-LabVdfValue -Text $vdf -Key 'path'
        Assert-LabSequence $values @('D:\Steam Library', 'E:\Other') 'VDF path escaping'
        $values = Get-LabVdfValue -Text $vdf -Key 'empty'
        Assert-LabSequence $values @('') 'VDF explicit empty value'
        $values = Get-LabVdfValue -Text $vdf -Key 'missing'
        Assert-LabSequence $values @() 'VDF missing key'
        $values = Get-LabVdfValue -Text $vdf -Key 'a.b'
        Assert-LabSequence $values @('literal') 'VDF regex-like key'
        $values = Get-LabVdfValue -Text $vdf -Key 'label'
        Assert-LabSequence $values @('a"b') 'VDF escaped quote'
    }
    Invoke-LabCheck 'Steam library discovery handles multiple modern roots, legacy entries and duplicates' {
        $steamRoot = Join-Path $labTemp 'Steam Root'
        $modernOne = Join-Path $labTemp 'modern-one'
        $modernTwo = Join-Path $labTemp 'modern-two'
        $legacyRoot = Join-Path $labTemp 'legacy'
        $encodedRoots = @($steamRoot, $modernOne, $modernTwo, $legacyRoot) | ForEach-Object { $_.Replace('\', '\\') }
        $vdf = '"libraryfolders" { "0" { "path" "' + $encodedRoots[0] + '" } "1" { "path" "' + $encodedRoots[1] + '" } "2" { "path" "' + $encodedRoots[2] + '" } "3" "' + $encodedRoots[3] + '" "4" { "path" "' + $encodedRoots[1] + '" } "5" "relative/not-a-library" }'
        Write-LabFixture (Join-Path $steamRoot 'steamapps/libraryfolders.vdf') $vdf
        $roots = Get-LabLibraryRoots -SteamRoot $steamRoot
        Assert-LabSequence $roots @($steamRoot, $modernOne, $modernTwo, $legacyRoot) 'library roots'
    }
    Invoke-LabCheck 'Steam library metadata respects its read limit' {
        $steamRoot = Join-Path $labTemp 'oversized-Steam'
        Write-LabFixture (Join-Path $steamRoot 'steamapps/libraryfolders.vdf') (' ' * 2097153)
        Assert-LabThrows { Get-LabLibraryRoots -SteamRoot $steamRoot } 'oversized VDF'
    }
    Invoke-LabCheck 'Manifest identity accepts matching files then rejects same-size tampering' {
        $packageRoot = Join-Path $labTemp 'synthetic-package'
        $packagedRuntime = Join-Path $packageRoot 'scripts/runtime'
        $records = @()
        foreach ($leaf in @('dual_client_lab.ps1', 'dual_client_lab_core.psm1', 'dual_client_probe.ps1')) {
            $filePath = Join-Path $packagedRuntime $leaf
            Write-LabFixture $filePath 'ABCD'
            $records += [pscustomobject]@{
                path = ('scripts/runtime/' + $leaf)
                bytes = 4
                sha256 = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
        Write-LabJson -Path (Join-Path $packageRoot 'package_manifest.json') -Value ([ordered]@{
            schema = 1; source_sha = ('a' * 40); files = $records
        })
        $identity = Get-LabSourceIdentity -ScriptDirectory $packagedRuntime
        Assert-LabEqual $identity.kind 'package_manifest' 'synthetic package source'
        Assert-LabEqual $identity.integrity 'MANIFEST_FILES_MATCH' 'matching three-file manifest'
        Write-LabFixture (Join-Path $packagedRuntime 'dual_client_probe.ps1') 'WXYZ'
        Assert-LabThrows { Get-LabSourceIdentity -ScriptDirectory $packagedRuntime } 'same-size content mismatch'
    }
    Invoke-LabCheck 'Immutable JSON survives existing-file rejection and a serialization-time collision' {
        $jsonDirectory = Join-Path $labTemp 'json-evidence'
        [void][System.IO.Directory]::CreateDirectory($jsonDirectory)
        $jsonPath = Join-Path $jsonDirectory 'report.json'
        Write-LabJson -Path $jsonPath -Value ([ordered]@{ schema = 1; status = 'SYNTHETIC_ORIGINAL' })
        $original = [System.IO.File]::ReadAllText($jsonPath)
        Assert-LabThrows { Write-LabJson -Path $jsonPath -Value @{ status = 'replacement' } } 'existing immutable JSON'
        Assert-LabEqual ([System.IO.File]::ReadAllText($jsonPath)) $original 'original JSON preserved'

        # A getter supplies a deterministic competing writer after the helper's
        # initial existence check. No timing-dependent thread or sleep is needed.
        $collisionPath = Join-Path $jsonDirectory 'collision.json'
        $racingValue = [pscustomobject]@{ schema = 1 }
        $collisionGetter = {
            [System.IO.File]::WriteAllText($collisionPath, 'concurrent writer owns this file')
            return 'synthetic serialization callback'
        }.GetNewClosure()
        Add-Member -InputObject $racingValue -MemberType ScriptProperty -Name during_serialization -Value $collisionGetter
        Assert-LabThrows { Write-LabJson -Path $collisionPath -Value $racingValue } 'destination appeared during serialization'
        Assert-LabEqual ([System.IO.File]::ReadAllText($collisionPath)) 'concurrent writer owns this file' 'competing evidence must not be replaced'
        Assert-LabEqual (@(Get-ChildItem -LiteralPath $jsonDirectory -Filter '*.partial-*' -Force).Count) 0 'JSON failures leave no partial files'
    }

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        # The actual CLI refuses the system drive. Windows CI checks out the
        # repository on a non-system drive; keep these fixtures beside it.
        $runtimeFullPath = [System.IO.Path]::GetFullPath($RuntimeDirectory)
        $runtimeDrive = [System.IO.Path]::GetPathRoot($runtimeFullPath).TrimEnd('\')
        if ($runtimeDrive -ieq [Environment]::GetEnvironmentVariable('SystemDrive')) {
            throw 'CLI preflight tests require a checkout outside the Windows system drive.'
        }
        $preflightBase = Join-Path $runtimeFullPath ('synthetic-preflight-' + [Guid]::NewGuid().ToString('N'))
        $preflightRoot = Join-Path $preflightBase 'owned-lab'
        $missingTools = Join-Path $preflightBase 'deliberately-missing-tools'
        $shellExecutable = (Get-Process -Id $PID -ErrorAction Stop).Path
        $cliPath = Join-Path $runtimeFullPath 'dual_client_lab.ps1'

        function Invoke-SyntheticPreflight {
            param([string]$OwnedPath)
            return Invoke-LabNative -Executable $shellExecutable -TimeoutSeconds 30 -Arguments @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $cliPath,
                '-Mode', 'Preflight', '-LabRoot', $OwnedPath,
                '-SteamRoot', $missingTools, '-GameRoot', $missingTools, '-SandboxieRoot', $missingTools
            )
        }

        try {
            Invoke-LabCheck 'Actual preflight reports missing prerequisites without setting up boxes' {
                $execution = Invoke-SyntheticPreflight -OwnedPath $preflightRoot
                Assert-LabEqual $execution.ExitCode 2 'missing prerequisite exit code'
                $reports = @(Get-ChildItem -LiteralPath (Join-Path $preflightRoot 'evidence') -Recurse -Filter 'report.json' -File)
                Assert-LabEqual $reports.Count 1 'one fresh preflight report'
                $reportData = [System.IO.File]::ReadAllText($reports[0].FullName) | ConvertFrom-Json
                Assert-LabEqual $reportData.schema 1 'preflight report schema'
                Assert-LabEqual $reportData.status 'BLOCKED' 'missing prerequisite status'
                Assert-LabEqual $reportData.multiplayer 'NOT_RUN' 'no multiplayer claim'
                Assert-LabEqual $reportData.lobby 'NOT_RUN' 'no lobby claim'
                Assert-LabEqual $reportData.campaign_turns 'NOT_RUN' 'no gameplay claim'
                Assert-LabEqual $reportData.accounts 'NOT_VERIFIED' 'no account claim'
                foreach ($tool in @('steam_root', 'game_root', 'sandboxie_root')) {
                    Assert-LabTrue (@($reportData.reasons | Where-Object { $_ -like ('Missing ' + $tool + ';*') }).Count -eq 1) ('missing prerequisite: ' + $tool)
                }
                $state = [System.IO.File]::ReadAllText((Join-Path $preflightRoot '.mk1212-dual-client-lab.json')) | ConvertFrom-Json
                Assert-LabEqual $state.boxes.Count 2 'planned peer count'
                foreach ($box in $state.boxes) {
                    Assert-LabTrue (-not $box.setup_started -and -not $box.setup_complete) 'preflight cannot set up a box'
                }
                Assert-LabTrue (-not (Test-Path -LiteralPath (Join-Path $preflightRoot 'sandboxes'))) 'missing tools cannot create box directories'
            }
            Invoke-LabCheck 'Repeated blocked preflight preserves earlier evidence and ownership' {
                $firstReports = @(Get-ChildItem -LiteralPath (Join-Path $preflightRoot 'evidence') -Recurse -Filter 'report.json' -File)
                Assert-LabEqual $firstReports.Count 1 'initial report count'
                $previousHash = (Get-FileHash -LiteralPath $firstReports[0].FullName -Algorithm SHA256).Hash
                $statePath = Join-Path $preflightRoot '.mk1212-dual-client-lab.json'
                $previousState = [System.IO.File]::ReadAllText($statePath)
                $execution = Invoke-SyntheticPreflight -OwnedPath $preflightRoot
                Assert-LabEqual $execution.ExitCode 2 'repeated missing prerequisite exit code'
                Assert-LabEqual @(Get-ChildItem -LiteralPath (Join-Path $preflightRoot 'evidence') -Recurse -Filter 'report.json' -File).Count 2 'two separate immutable reports'
                Assert-LabEqual (Get-FileHash -LiteralPath $firstReports[0].FullName -Algorithm SHA256).Hash $previousHash 'earlier evidence is unchanged'
                Assert-LabEqual ([System.IO.File]::ReadAllText($statePath)) $previousState 'ownership state is unchanged'
            }
            Invoke-LabCheck 'Actual preflight refuses to adopt a nonempty unowned directory' {
                $unownedRoot = Join-Path $preflightBase 'unowned'
                $sentinel = Join-Path $unownedRoot 'keep.txt'
                Write-LabFixture $sentinel 'existing user data'
                $execution = Invoke-SyntheticPreflight -OwnedPath $unownedRoot
                Assert-LabEqual $execution.ExitCode 2 'unowned directory exit code'
                $reportData = $execution.Output | ConvertFrom-Json
                Assert-LabEqual $reportData.status 'BLOCKED' 'unowned directory status'
                Assert-LabTrue (@($reportData.reasons | Where-Object { $_ -like '*nonempty directory without lab ownership*' }).Count -eq 1) 'ownership rejection must be explicit'
                Assert-LabEqual ([System.IO.File]::ReadAllText($sentinel)) 'existing user data' 'existing directory content preserved'
                Assert-LabTrue (-not (Test-Path -LiteralPath (Join-Path $unownedRoot '.mk1212-dual-client-lab.json'))) 'unowned directory must not be adopted'
                Assert-LabTrue (-not (Test-Path -LiteralPath (Join-Path $unownedRoot 'evidence'))) 'no evidence writes in unowned directory'
            }
        }
        finally {
            if (Test-Path -LiteralPath $preflightBase) { Remove-Item -LiteralPath $preflightBase -Recurse -Force }
        }
    }
    else {
        $script:LabSkippedCount += 3
        Write-Host 'SKIP: three actual preflight checks require a Windows checkout on a non-system drive'
    }
}
finally {
    # All fixtures are owned by this unique temporary directory.
    if (Test-Path -LiteralPath $labTemp) { Remove-Item -LiteralPath $labTemp -Recurse -Force }
}

Write-Host ('Synthetic dual-client lab checks: {0} run, {1} failed, {2} skipped. Attila multiplayer NOT PROVEN.' -f $script:LabCheckCount, $script:LabFailures.Count, $script:LabSkippedCount)
if ($script:LabFailures.Count -gt 0) { throw ($script:LabFailures -join [Environment]::NewLine) }
