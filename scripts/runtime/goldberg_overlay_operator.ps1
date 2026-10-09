# MK1212 Goldberg experimental overlay sidecar.
# Owns ONLY two already prepared laboratory copies, never the Steam installation.
[CmdletBinding()]
param(
    [ValidateSet('Status','Enable','Launch','Restore')]
    [string]$Mode = 'Status',
    [string]$Archive = 'D:\MK1212\diagnostics\goldberg-original.zip',
    [string]$SandboxieStart = 'D:\Sandboxie-Plus\Start.exe',
    [string]$StateRoot = 'D:\MK1212\diagnostics\overlay-lab'
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$owner = 'MK1212Scripts.goldberg-client-lab'
$expectedOriginal = 'eaeaf26f60229ae4d1a9aae07d03ab4e93ea599dd883eb810d6adebcf0e52e14'
$expectedArchive = '8465984b01b42a75f5faea8f2d884bbd6085a695c40c2b90eb0385f0a5081266'
$roles = @(
    [pscustomobject]@{ role='HOST'; root='C:\MK1212\HOST'; box='MK1212GoldHost' },
    [pscustomobject]@{ role='CLIENT'; root='D:\MK1212\CLIENT'; box='MK1212GoldClient' }
)
$stateFile = Join-Path $StateRoot 'active.json'

function Hash-File([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}
function Need-Closed {
    if (@(Get-Process -Name Attila -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Close BOTH Attila processes before enabling or restoring the overlay.'
    }
}
function Assert-SafeFile([string]$path) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Unsafe file type or reparse point: $path"
    }
}
function Assert-OwnedCopy($r) {
    $root = $r.root
    foreach ($p in @($root, (Join-Path $root 'steam_settings'))) {
        $dir = Get-Item -LiteralPath $p -Force -ErrorAction Stop
        if (-not $dir.PSIsContainer -or ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Invalid owned game directory: $p"
        }
    }
    $copy = Join-Path $root '.mk1212-goldberg-copy.json'
    $settings = Join-Path $root '.mk1212-goldberg-settings.json'
    Assert-SafeFile $copy
    Assert-SafeFile $settings
    $a = Get-Content -LiteralPath $copy -Raw | ConvertFrom-Json
    $b = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
    if ($a.owner -cne $owner -or $b.owner -cne $owner -or
        $a.role -cne $r.role -or $b.role -cne $r.role -or
        $a.lab_id -cne $b.lab_id -or $a.lab_id -notmatch '^[0-9a-f]{32}$') {
        throw "Ownership mismatch: $root"
    }
    $dll = Join-Path $root 'steam_api.dll'
    Assert-SafeFile $dll
    $exe = Join-Path $root 'Attila.exe'
    Assert-SafeFile $exe
    return [string]$a.lab_id
}
function Read-ExperimentalDll {
    if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) {
        throw "Pinned Goldberg archive not found: $Archive. Supply -Archive path."
    }
    Assert-SafeFile $Archive
    if ((Hash-File $Archive) -ne $expectedArchive) { throw 'Goldberg ZIP SHA256 mismatch.' }
    Add-Type -AssemblyName System.IO.Compression
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $matches = @($zip.Entries | Where-Object {
            $_.FullName.Replace('\','/') -match '(?i)(^|/)experimental/(x86/)?steam_api[.]dll$'
        })
        if ($matches.Count -ne 1) {
            throw ("Expected one experimental x86 DLL in pinned ZIP, found " + $matches.Count + ". No files changed.")
        }
        if ($matches[0].Length -lt 65536 -or $matches[0].Length -gt 33554432) {
            throw 'Unexpected experimental DLL size.'
        }
        $inputStream = $matches[0].Open()
        try {
            $mem = New-Object IO.MemoryStream
            try { $inputStream.CopyTo($mem); $bytes = $mem.ToArray() }
            finally { $mem.Dispose() }
        } finally { $inputStream.Dispose() }
    } finally { $zip.Dispose() }
    if ($bytes.Length -lt 256 -or $bytes[0] -ne 77 -or $bytes[1] -ne 90) {
        throw 'Experimental DLL is not an MZ image.'
    }
    $pe = [BitConverter]::ToInt32($bytes,60)
    if ($pe -lt 64 -or $pe + 24 -gt $bytes.Length -or
        [BitConverter]::ToUInt32($bytes,$pe) -ne 0x4550 -or
        [BitConverter]::ToUInt16($bytes,$pe+4) -ne 0x14c) {
        throw 'Experimental DLL PE signature or machine is not x86.'
    }
    return ,$bytes
}
function Replace-Bytes([string]$dest,[byte[]]$bytes) {
    $temp = $dest + '.mk1212-overlay-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllBytes($temp,$bytes)
        # Atomic replacement on the same volume (PowerShell 5.1 compatible).
        [IO.File]::Replace($temp,$dest,[System.Management.Automation.Language.NullString]::Value)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}
function Read-State {
    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
        throw "No overlay journal: $stateFile"
    }
    Assert-SafeFile $stateFile
    $s = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    if ($s.schema -ne 1 -or $s.owner -cne 'MK1212Scripts.goldberg-overlay-lab' -or
        @($s.roles).Count -ne 2 -or $s.experimental_sha -notmatch '^[0-9a-f]{64}$') {
        throw 'Invalid overlay journal.'
    }
    foreach ($i in 0..1) {
        if ($s.roles[$i].role -cne $roles[$i].role -or
            $s.roles[$i].root -ine $roles[$i].root -or
            $s.roles[$i].box -cne $roles[$i].box) { throw 'Unexpected journal paths.' }
    }
    return $s
}
function Assert-OverlayReady($s) {
    foreach ($r in $roles) {
        [void](Assert-OwnedCopy $r)
        if ((Hash-File (Join-Path $r.root 'steam_api.dll')) -ne $s.experimental_sha) {
            throw "$($r.role) is not running the expected experimental DLL."
        }
        if (Test-Path -LiteralPath (Join-Path $r.root 'steam_settings\disable_overlay.txt')) {
            throw "$($r.role) still disables overlay."
        }
    }
}

if ($Mode -eq 'Status') {
    foreach ($r in $roles) {
        $dll = Join-Path $r.root 'steam_api.dll'
        $present = Test-Path -LiteralPath $dll -PathType Leaf
        $hash = if ($present) { Hash-File $dll } else { 'MISSING' }
        $disabled = Test-Path -LiteralPath (Join-Path $r.root 'steam_settings\disable_overlay.txt')
        Write-Host "$($r.role): DLL SHA256=$hash; disable_overlay=$disabled"
    }
    Write-Host "Overlay journal: $(Test-Path -LiteralPath $stateFile)"
    if (Test-Path -LiteralPath $stateFile) {
        $s = Read-State
        Write-Host "Expected experimental DLL: $($s.experimental_sha)"
    }
    exit 0
}

if ($Mode -eq 'Enable') {
    Need-Closed
    if (Test-Path -LiteralPath $stateFile) {
        throw 'Overlay journal already exists. Use -Mode Status / Restore first.'
    }
    $labIds = @()
    foreach ($r in $roles) {
        $labIds += Assert-OwnedCopy $r
        $dll = Join-Path $r.root 'steam_api.dll'
        if ((Hash-File $dll) -ne $expectedOriginal) { throw "Unexpected current $($r.role) DLL; refusing overwrite." }
        $toggle = Join-Path $r.root 'steam_settings\disable_overlay.txt'
        if (-not (Test-Path -LiteralPath $toggle -PathType Leaf)) {
            throw "Missing expected disable_overlay.txt for $($r.role); check installation."
        }
        Assert-SafeFile $toggle
    }
    if ($labIds[0] -cne $labIds[1]) { throw 'HOST and CLIENT are not the same owned laboratory.' }
    $bytes = Read-ExperimentalDll
    $sha = ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    if ($sha -eq $expectedOriginal) { throw 'The candidate experimental DLL equals the standard DLL.' }
    if (-not (Test-Path -LiteralPath $StateRoot)) {
        [void][IO.Directory]::CreateDirectory($StateRoot)
    }
    $stateDir = Get-Item -LiteralPath $StateRoot -Force
    if (($stateDir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Overlay state directory is a reparse point.' }
    $backupRoot = Join-Path $StateRoot ('backup-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($backupRoot)
    $saved = @()
    foreach ($r in $roles) {
        $dll = Join-Path $r.root 'steam_api.dll'
        $toggle = Join-Path $r.root 'steam_settings\disable_overlay.txt'
        $dllBackup = Join-Path $backupRoot ($r.role + '-steam_api.dll')
        $toggleBackup = Join-Path $backupRoot ($r.role + '-disable_overlay.txt')
        Copy-Item -LiteralPath $dll -Destination $dllBackup
        Copy-Item -LiteralPath $toggle -Destination $toggleBackup
        if ((Hash-File $dllBackup) -ne $expectedOriginal -or
            (Hash-File $toggleBackup) -ne (Hash-File $toggle)) { throw 'Backup verification failed.' }
        $saved += [pscustomobject]@{
            role=$r.role; root=$r.root; box=$r.box; lab_id=$labIds[0]
            dll_backup=$dllBackup; toggle_backup=$toggleBackup
            original_sha=$expectedOriginal; toggle_sha=(Hash-File $toggle)
        }
    }
    $journal = [pscustomobject]@{
        schema=1; owner='MK1212Scripts.goldberg-overlay-lab'
        experimental_sha=$sha; archive_sha=$expectedArchive
        created_utc=[DateTime]::UtcNow.ToString('o'); roles=$saved
    }
    # Journal precedes every change. Restore recovers an interrupted Enable.
    [IO.File]::WriteAllText($stateFile,($journal | ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
    foreach ($r in $roles) {
        $dll = Join-Path $r.root 'steam_api.dll'
        $toggle = Join-Path $r.root 'steam_settings\disable_overlay.txt'
        Replace-Bytes -dest $dll -bytes $bytes
        if ((Hash-File $dll) -ne $sha) { throw "DLL verification failed for $($r.role). Use Restore." }
        if ((Hash-File $toggle) -ne (@($saved | Where-Object { $_.role -eq $r.role })[0]).toggle_sha) {
            throw "Toggle changed during preparation for $($r.role). Use Restore."
        }
        Remove-Item -LiteralPath $toggle -Force
    }
    Write-Host 'Experimental overlay enabled. Use THIS script -Mode Launch; standard launcher will reject modified DLLs.'
    exit 0
}

if ($Mode -eq 'Restore') {
    Need-Closed
    $s = Read-State
    foreach ($i in 0..1) {
        $r = $roles[$i]; $j = $s.roles[$i]
        [void](Assert-OwnedCopy $r)
        $dll = Join-Path $r.root 'steam_api.dll'
        $toggle = Join-Path $r.root 'steam_settings\disable_overlay.txt'
        Assert-SafeFile $j.dll_backup
        Assert-SafeFile $j.toggle_backup
        if ((Hash-File $j.dll_backup) -ne $expectedOriginal -or
            (Hash-File $j.toggle_backup) -ne $j.toggle_sha) { throw 'Backup changed; refusing restore.' }
        $current = Hash-File $dll
        if ($current -ne $expectedOriginal -and $current -ne $s.experimental_sha) {
            throw "Unrecognized $($r.role) DLL. Restore stopped to protect an unknown modification."
        }
        if (Test-Path -LiteralPath $toggle) {
            Assert-SafeFile $toggle
            if ((Hash-File $toggle) -ne $j.toggle_sha) { throw 'Toggle changed; restore stopped.' }
        }
    }
    foreach ($i in 0..1) {
        $r = $roles[$i]; $j = $s.roles[$i]
        $dll = Join-Path $r.root 'steam_api.dll'
        $toggle = Join-Path $r.root 'steam_settings\disable_overlay.txt'
        if ((Hash-File $dll) -ne $expectedOriginal) {
            Replace-Bytes -dest $dll -bytes ([IO.File]::ReadAllBytes($j.dll_backup))
        }
        if (-not (Test-Path -LiteralPath $toggle)) {
            [IO.File]::Copy($j.toggle_backup,$toggle)
        }
        if ((Hash-File $dll) -ne $expectedOriginal -or
            (Hash-File $toggle) -ne $j.toggle_sha) { throw "Restore verification failed for $($r.role)." }
        Write-Host "$($r.role) restored."
    }
    Remove-Item -LiteralPath $stateFile
    Write-Host 'Rollback complete. Standard launcher may be used again. Backups retained.'
    exit 0
}

if ($Mode -eq 'Launch') {
    $s = Read-State
    Assert-OverlayReady $s
    if (-not (Test-Path -LiteralPath $SandboxieStart -PathType Leaf)) {
        throw "Sandboxie Start.exe not found: $SandboxieStart"
    }
    Assert-SafeFile $SandboxieStart
    foreach ($r in $roles) {
        $exe = Join-Path $r.root 'Attila.exe'
        Write-Host "Launching $($r.role) through Sandboxie box $($r.box)..."
        Push-Location $r.root
        try {
            & $SandboxieStart ('/box:' + $r.box) $exe
            if ($LASTEXITCODE -ne 0) { throw "Sandboxie launch returned $LASTEXITCODE for $($r.role)." }
        } finally { Pop-Location }
    }
    Write-Host 'Launch requests sent. Verify two game windows, then Shift+Tab. This does not prove lobby connectivity.'
}
