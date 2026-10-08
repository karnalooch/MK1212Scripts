# A bounded marker write to discover Sandboxie's physical Attila profile mapping.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{32}$')][string]$Nonce,
    [Parameter(Mandatory = $true)][ValidateSet('HOST', 'CLIENT')][string]$Role,
    [Parameter(Mandatory = $true)][ValidateSet('MK1212LabHost', 'MK1212LabClient')][string]$BoxName
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try {
    $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    if ([string]::IsNullOrWhiteSpace($appData)) { throw 'ApplicationData is unavailable.' }
    $profile = Join-Path $appData 'The Creative Assembly\Attila'
    [void][System.IO.Directory]::CreateDirectory($profile)
    $markerPath = Join-Path $profile ('mk1212-dual-probe-' + $Nonce + '.json')
    $marker = [ordered]@{
        schema = 1; owner = 'MK1212Scripts.dual-client-lab'; nonce = $Nonce
        role = $Role; requested_box = $BoxName; process_id = $PID
        created_utc = [DateTime]::UtcNow.ToString('o')
        app_data = $appData; profile_logical = $profile
        status = 'MARKER_WRITTEN'; note = 'Physical sandbox membership is verified by the host-side collector.'
    }
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
    $bytes = $encoding.GetBytes(($marker | ConvertTo-Json -Depth 4))
    $stream = New-Object System.IO.FileStream -ArgumentList $markerPath, ([System.IO.FileMode]::CreateNew), ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
    finally { $stream.Dispose() }
    exit 0
} catch {
    Write-Error -Message ('Profile probe failed: ' + $_.Exception.Message) -ErrorAction Continue
    exit 2
}
