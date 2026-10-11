# MK1212 portable Ghidra/JDK bootstrap. Windows PowerShell 5.1+, no admin rights.
[CmdletBinding()]
param(
    [string]$Root = 'D:\MK1212\research',
    [switch]$VerifyOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'toolchain.lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($lock.schema_version -ne 1 -or $lock.purpose -ne 'local-static-analysis-only') {
    throw 'Unexpected MK1212 RE toolchain lock schema.'
}
$rootFull = [IO.Path]::GetFullPath($Root)
$toolsDir = Join-Path $rootFull 'tools'
$cacheDir = Join-Path $rootFull 'cache'
$stagingDir = Join-Path $rootFull 'staging'
foreach ($dir in @($rootFull, $toolsDir, $cacheDir, $stagingDir)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        if ($VerifyOnly) { throw "Missing toolchain directory: $dir" }
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-ArchiveHash([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing pinned archive: $Path"
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "SHA256 mismatch for $Path. Expected $Expected, got $actual; refusing extraction."
    }
}

function Assert-ZipPaths([string]$ArchivePath) {
    $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        if ($zip.Entries.Count -gt 70000) { throw 'Archive entry count exceeds bound.' }
        $unpacked = [long]0
        foreach ($entry in $zip.Entries) {
            $item = $entry.FullName.Replace('\', '/')
            if ($item.StartsWith('/') -or $item -match '^[A-Za-z]:' -or
                $item -match '(^|/)\.\.(/|$)' -or $item.Contains([char]0)) {
                throw "Unsafe ZIP entry path: $item"
            }
            $unpacked += $entry.Length
            if ($unpacked -gt 5GB) { throw 'Unpacked archive exceeds 5 GiB.' }
        }
    } finally { $zip.Dispose() }
}

foreach ($item in @($lock.jdk, $lock.ghidra)) {
    if ($item.sha256 -notmatch '^[0-9a-f]{64}$' -or
        $item.archive -notmatch '^[a-zA-Z0-9_.+-]+\.zip$' -or
        $item.folder -notmatch '^[a-zA-Z0-9_.+-]+$') {
        throw "Invalid pinned metadata for $($item.name)"
    }
    $archiveUri = [Uri]$item.url
    if ($archiveUri.Scheme -ne 'https' -or $archiveUri.Host -ne 'github.com' -or
        $archiveUri.AbsolutePath -notmatch '^/(NationalSecurityAgency/ghidra|adoptium/temurin25-binaries)/releases/download/') {
        throw "Refusing unapproved download URL for $($item.name)"
    }
    $destination = Join-Path $toolsDir $item.folder
    $binary = Join-Path $destination $item.executable
    $marker = Join-Path $destination '.mk1212-package.json'
    if (Test-Path -LiteralPath $destination) {
        if (-not (Test-Path -LiteralPath $binary -PathType Leaf) -or
            -not (Test-Path -LiteralPath $marker -PathType Leaf)) {
            throw "Existing tool install is incomplete: $destination. Do not overwrite it blindly."
        }
        $installed = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($installed.sha256 -ne $item.sha256 -or $installed.version -ne $item.version) {
            throw "Existing install metadata does not match the pinned tool: $destination"
        }
        Write-Host "Verified existing tool: $binary"
        continue
    }
    if ($VerifyOnly) { throw "Not installed: $($item.name) ($destination)" }

    $archivePath = Join-Path $cacheDir $item.archive
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        $partial = "$archivePath.partial.$PID"
        if (Test-Path -LiteralPath $partial) { throw "Stale partial download: $partial" }
        $client = New-Object Net.WebClient
        try {
            Write-Host ("Downloading {0} to {1}" -f $item.name, $archivePath)
            $client.DownloadFile($item.url, $partial)
            Assert-ArchiveHash $partial $item.sha256
            Move-Item -LiteralPath $partial -Destination $archivePath
        } finally { $client.Dispose() }
    }
    Assert-ArchiveHash $archivePath $item.sha256
    Assert-ZipPaths $archivePath

    $stage = Join-Path $stagingDir ("{0}-{1}" -f $item.folder, $PID)
    if (Test-Path -LiteralPath $stage) { throw "Staging directory exists: $stage" }
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        Expand-Archive -LiteralPath $archivePath -DestinationPath $stage
        $top = @(Get-ChildItem -LiteralPath $stage -Directory)
        if ($top.Count -ne 1) { throw "Unexpected ZIP layout for $($item.name)" }
        if (-not (Test-Path -LiteralPath (Join-Path $top[0].FullName $item.executable) -PathType Leaf)) {
            throw "Pinned archive lacks expected executable $($item.executable)"
        }
        if (Test-Path -LiteralPath $destination) { throw "Destination already exists: $destination" }
        Move-Item -LiteralPath $top[0].FullName -Destination $destination
        [ordered]@{
            name = $item.name
            version = $item.version
            sha256 = $item.sha256
            source = $item.url
        } | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
    Write-Host "Installed $($item.name): $binary"
}
Write-Host "MK1212 RE toolchain READY under $rootFull"
Write-Host 'Run Invoke-MK1212-RE.ps1 -Binary <original Attila DLL or EXE> to analyze.'
