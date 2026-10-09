# Build source-pinned Goldberg x86 trace ONLY in isolated D: directory.
[CmdletBinding()]
param(
 [string]$Source = 'D:\MK1212\diagnostics\steamworks-trace-src\instrumented',
 [string]$Protobuf = 'D:\vcpkg\installed\x86-windows-static',
 [string]$Output = 'D:\MK1212\diagnostics\steamworks-trace-x86'
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Output) { throw 'Output already exists: refusing overwrite' }
$manifest = Get-Content -LiteralPath (Join-Path $Source 'MK1212-STEAMWORKS-TRACE-SOURCE.json') -Raw | ConvertFrom-Json
if ($manifest.source_commit -cne '475342f0d8b2bd7eb0d93bd7cfdd61e3ae7cda24') { throw 'Unexpected pinned source' }
$protoc = Join-Path $Protobuf 'tools\protobuf\protoc.exe'
$pb = Join-Path $Protobuf 'lib\libprotobuf-lite.lib'
if (-not (Test-Path -LiteralPath $pb)) { $pb = Join-Path $Protobuf 'lib\libprotobuf.lib' }
foreach ($p in @($protoc,$pb,(Join-Path $Protobuf 'include\google\protobuf\message_lite.h'))) {
 if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Missing protobuf prerequisite: $p" }
}
$vswhere = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'Missing Visual Studio vswhere.exe' }
$vs = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
if (-not $vs) { throw 'MSVC x86 build tools unavailable' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars32.bat'
if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) { throw 'vcvars32.bat unavailable' }
foreach ($p in @($Source,$Protobuf,$Output,$vcvars)) {
 if ($p -match '["\r\n&|]') { throw 'Unsafe path characters' }
}
[void][IO.Directory]::CreateDirectory($Output)
$batch = Join-Path $Output 'build-x86.cmd'
$srcDll = Join-Path $Source 'dll'
$include = Join-Path $Protobuf 'include'
$dllOut = Join-Path $Output 'steam_api.dll'
$lines = @(
 '@echo off',
 'setlocal',
 ('call "'+$vcvars+'" >nul'),
 'if errorlevel 1 exit /b 11',
 ('"'+$protoc+'" -I"'+$srcDll+'" --cpp_out="'+$srcDll+'" "'+(Join-Path $srcDll 'net.proto')+'"'),
 'if errorlevel 1 exit /b 12',
 ('cd /d "'+$Output+'"'),
 ('cl /nologo "'+(Join-Path $srcDll 'rtlgenrandom.c')+'" "'+(Join-Path $srcDll 'rtlgenrandom.def')+'"'),
 'if errorlevel 1 exit /b 13',
 ('cl /nologo /LD /DEMU_RELEASE_BUILD /DNDEBUG /I"'+$include+'" '+(Join-Path $srcDll '*.cpp')+' '+(Join-Path $srcDll '*.cc')+' "'+$pb+'" Iphlpapi.lib Ws2_32.lib rtlgenrandom.lib Shell32.lib /EHsc /MP4 /Ox /link /OUT:"'+$dllOut+'"'),
 'if errorlevel 1 exit /b 14',
 'exit /b 0'
)
[IO.File]::WriteAllLines($batch,$lines,[Text.Encoding]::ASCII)
$proc = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d','/c', ('"' + $batch + '"')) -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) { throw "Build failed exit=$($proc.ExitCode). No game modified." }
if (-not (Test-Path -LiteralPath $dllOut -PathType Leaf)) { throw 'Missing compiler output DLL' }
$b = [IO.File]::ReadAllBytes($dllOut)
$offset = [BitConverter]::ToInt32($b,0x3c)
if ($offset -lt 64 -or $offset+24 -gt $b.Length -or [BitConverter]::ToUInt32($b,$offset) -ne 0x4550 -or [BitConverter]::ToUInt16($b,$offset+4) -ne 332) { throw 'Not a valid x86 DLL' }
$sha = (Get-FileHash -LiteralPath $dllOut -Algorithm SHA256).Hash
[IO.File]::WriteAllText((Join-Path $Output 'SHA256.txt'),($sha + '  steam_api.dll' + [Environment]::NewLine))
Write-Host "BUILT x86: $dllOut; SHA256=$sha" -ForegroundColor Green
Write-Host 'NOT INSTALLED into HOST or CLIENT.'
