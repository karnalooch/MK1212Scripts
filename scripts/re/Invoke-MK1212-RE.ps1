# Static Attila PE analysis through a pinned, local Ghidra headless project.
[CmdletBinding()]
param(
    [string]$Binary = '',
    [string]$GameDirectory = '',
    [string]$Root = 'D:\MK1212\research',
    [string]$RepositorySha = '',
    [switch]$PlanOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'toolchain.lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$rootFull = [IO.Path]::GetFullPath($Root)

if (-not $Binary) {
    if (-not $GameDirectory) {
        throw 'Supply -Binary <full path to original Attila .dll/.exe> or -GameDirectory <game folder>. No binary is bundled.'
    }
    $Binary = Join-Path $GameDirectory 'empire.retail.dll'
}
if (-not (Test-Path -LiteralPath $Binary -PathType Leaf)) { throw "Attila binary not found: $Binary" }
$binaryFull = (Resolve-Path -LiteralPath $Binary).Path
$binaryName = Split-Path -Leaf $binaryFull
if ([IO.Path]::GetExtension($binaryName).ToLowerInvariant() -notin @('.dll','.exe')) {
    throw 'Expected an original .dll or .exe, not a dump of unknown format.'
}
$stream = [IO.File]::OpenRead($binaryFull)
try {
    $reader = New-Object IO.BinaryReader($stream)
    if ($stream.Length -lt 128 -or $reader.ReadUInt16() -ne 0x5a4d) { throw 'Not an MZ/PE file.' }
    $stream.Position = 0x3c
    $offset = $reader.ReadInt32()
    if ($offset -lt 64 -or ([long]$offset + 6) -gt $stream.Length) { throw 'Invalid PE header offset.' }
    $stream.Position = $offset
    if ($reader.ReadUInt32() -ne 0x00004550) { throw 'Invalid PE signature.' }
    $machine = $reader.ReadUInt16()
    if ($machine -notin @(0x014c, 0x8664)) {
        throw ('Unsupported PE machine 0x{0:x4}; expected x86/x64.' -f $machine)
    }
} finally { $reader.Dispose() }
$sha = (Get-FileHash -LiteralPath $binaryFull -Algorithm SHA256).Hash.ToLowerInvariant()

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $RepositorySha) {
    $originalPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $RepositorySha = ((& git -C $repoRoot rev-parse HEAD 2>$null) | Out-String).Trim() }
    catch { $RepositorySha = '' }
    finally { $ErrorActionPreference = $originalPreference }
}
if ($RepositorySha -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'Cannot establish exact MK1212 source commit. Use a Git checkout or pass -RepositorySha <40 hex digits>.'
}

$jdkHome = Join-Path (Join-Path $rootFull 'tools') $lock.jdk.folder
$ghidraHome = Join-Path (Join-Path $rootFull 'tools') $lock.ghidra.folder
$javaExe = Join-Path $jdkHome $lock.jdk.executable
$headless = Join-Path $ghidraHome $lock.ghidra.executable
$scriptDir = Join-Path $PSScriptRoot 'ghidra_scripts'
if (-not (Test-Path -LiteralPath $headless -PathType Leaf) -or
    -not (Test-Path -LiteralPath $javaExe -PathType Leaf)) {
    throw 'Portable Ghidra/JDK missing. Run Install-MK1212-RE.ps1 first.'
}
$projectsDir = Join-Path $rootFull 'projects'
$resultsDir = Join-Path $rootFull 'reports'
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + "-$PID"
$runDir = Join-Path (Join-Path $resultsDir $sha.Substring(0,16)) $runId
$projectName = 'mk1212_' + $sha.Substring(0,16)
$projectPath = Join-Path $projectsDir ($projectName + '.gpr')
$rawJson = Join-Path $runDir 'ghidra-leads.json'
$headlessLog = Join-Path $runDir 'ghidra.log'
$scriptLog = Join-Path $runDir 'ghidra-script.log'

$mode = '-import'
$target = $binaryFull
if (Test-Path -LiteralPath $projectPath -PathType Leaf) {
    $mode = '-process'
    $target = $binaryName
}
$headlessArgs = @(
    $projectsDir, $projectName,
    $mode, $target,
    '-scriptPath', $scriptDir,
    '-postScript', 'Mk1212Leads.java', $rawJson, $sha,
    '-analysisTimeoutPerFile', '600',
    '-max-cpu', '2',
    '-log', $headlessLog,
    '-scriptlog', $scriptLog
)
Write-Host "Attila PE: $binaryName (SHA256 $sha, machine 0x$('{0:x4}' -f $machine))"
Write-Host "Ghidra mode: $mode, project: $projectPath"
if ($PlanOnly) {
    Write-Host 'PLAN ONLY; nothing launched or written.'
    Write-Host ($headless + ' ' + ($headlessArgs -join ' '))
    return
}
foreach ($dir in @($projectsDir, $runDir, (Join-Path $rootFull 'tmp'))) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}
# These environment changes affect this invocation only; no global PATH modification.
$oldJava = $env:JAVA_HOME
$oldPath = $env:PATH
$oldTemp = $env:TEMP
$oldTmp = $env:TMP
try {
    $env:JAVA_HOME = $jdkHome
    $env:PATH = (Join-Path $jdkHome 'bin') + ';' + $oldPath
    $env:TEMP = Join-Path $rootFull 'tmp'
    $env:TMP = $env:TEMP
    & $headless @headlessArgs
    if ($LASTEXITCODE -ne 0) { throw "Ghidra headless failed with exit code $LASTEXITCODE. See $headlessLog" }
} finally {
    $env:JAVA_HOME = $oldJava
    $env:PATH = $oldPath
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
}
if (-not (Test-Path -LiteralPath $rawJson -PathType Leaf)) { throw 'Ghidra did not produce a findings file.' }
if ((Get-Item -LiteralPath $rawJson).Length -gt 1048576) { throw 'Ghidra findings file exceeds 1 MiB.' }
$leads = Get-Content -LiteralPath $rawJson -Raw -Encoding UTF8 | ConvertFrom-Json
if ($leads.schema_version -ne 1 -or $leads.tool -ne 'ghidra' -or
    $leads.binary_sha256 -ne $sha -or @($leads.findings).Count -gt 300) {
    throw 'Ghidra output schema/identity/size mismatch; not accepting report.'
}
$evidence = [ordered]@{
    schema_version = 1
    status = 'STATIC_CANDIDATE_ONLY'
    mk1212_source_sha = $RepositorySha.ToLowerInvariant()
    binary = [ordered]@{
        name = $binaryName
        sha256 = $sha
        machine = ('0x{0:x4}' -f $machine)
    }
    tool = [ordered]@{ name = 'Ghidra'; version = $lock.ghidra.version }
    finding_count = @($leads.findings).Count
    truncated = [bool]$leads.truncated
    findings = @($leads.findings)
}
$pending = Join-Path $runDir 'evidence.pending.json'
$final = Join-Path $runDir 'evidence.json'
$evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $pending -Encoding UTF8
Move-Item -LiteralPath $pending -Destination $final
Write-Host "STATIC CANDIDATES ONLY: $final"
Write-Host 'No runtime hooks, network messages or gameplay modifications were made.'
