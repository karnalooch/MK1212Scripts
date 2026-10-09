# MK1212 — prepare isolated pinned Goldberg Steamworks trace source.
# Never touches game copies or source Steam installation.
[CmdletBinding()]
param(
    [string]$Archive = 'D:\MK1212\diagnostics\goldberg-original.zip',
    [string]$Output = 'D:\MK1212\diagnostics\steamworks-trace-src',
    [string]$Python = 'python'
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$commit = '475342f0d8b2bd7eb0d93bd7cfdd61e3ae7cda24'
$zipSha = '8465984b01b42a75f5faea8f2d884bbd6085a695c40c2b90eb0385f0a5081266'
$bundleSha = 'aa751fbc421cab0da4ad4edd2e5080d304cfb32794f92430db8a4cb0f291efbf'
$patcher = Join-Path $PSScriptRoot 'patch_goldberg_steamworks_trace.py'
if (-not (Test-Path -LiteralPath $patcher -PathType Leaf)) { throw "Missing patcher: $patcher" }
if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -ine $zipSha) {
    throw 'Wrong upstream archive SHA256. No source created.'
}
if (Test-Path -LiteralPath $Output) { throw 'Trace output exists; refusing to overwrite.' }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git.exe not found' }
if (-not (Get-Command $Python -ErrorAction SilentlyContinue)) { throw 'Python not found' }

$parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Output))
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    [void][IO.Directory]::CreateDirectory($parent)
}
[void][IO.Directory]::CreateDirectory($Output)
$bundle = Join-Path $Output 'source_code.bundle'
$source = Join-Path $Output 'original'
$instrumented = Join-Path $Output 'instrumented'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($Archive)
try {
    $entry=$zip.GetEntry('source_code/source_code.bundle')
    if ($null -eq $entry -or $entry.Length -gt 8388608) { throw 'Pinned source bundle missing or oversized.' }
    $inputStream=$entry.Open()
    try {
        $file=[IO.File]::Open($bundle,[IO.FileMode]::CreateNew)
        try { $inputStream.CopyTo($file) } finally { $file.Dispose() }
    } finally { $inputStream.Dispose() }
} finally { $zip.Dispose() }
if ((Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash -ine $bundleSha) {
    throw 'Bundle mismatch; output retained for inspection, no game file touched.'
}
& git clone --quiet -- "$bundle" "$source"
if ($LASTEXITCODE -ne 0) { throw 'Failed cloning pinned bundle' }
& git -C "$source" checkout --quiet --detach "$commit"
if ($LASTEXITCODE -ne 0) { throw 'Failed checking out pinned commit' }
$head=(& git -C "$source" rev-parse HEAD).Trim()
if ($head -ine $commit) { throw "Incorrect source HEAD $head" }
& $Python "$patcher" --source "$source" --output "$instrumented"
if ($LASTEXITCODE -ne 0) { throw 'Instrumentation failed; no game file changed.' }
Write-Host "Instrumented source prepared at $instrumented" -ForegroundColor Green
Write-Host 'NOT BUILT: compile an isolated x86 DLL before collecting API traces.'
