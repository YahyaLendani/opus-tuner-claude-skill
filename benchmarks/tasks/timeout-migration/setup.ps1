param([string]$Path)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$src = Join-Path $Path 'src'
$vendor = Join-Path $src 'vendor'
New-Item -ItemType Directory -Force -Path $vendor | Out-Null

[System.IO.File]::WriteAllText((Join-Path $Path 'config.json'), '{"timeoutSec":30}', $utf8)
[System.IO.File]::WriteAllText((Join-Path $src 'settings.ps1'), @'
function Get-Setting {
    param([string]$Name)
    $file = Join-Path (Split-Path -Parent $PSScriptRoot) 'config.json'
    return ([System.IO.File]::ReadAllText($file) | ConvertFrom-Json).$Name
}
'@, $utf8)
[System.IO.File]::WriteAllText((Join-Path $src 'legacy.ps1'), @'
function Read-LegacyTimeout { return 30 }
'@, $utf8)
[System.IO.File]::WriteAllText((Join-Path $vendor 'client.ps1'), @'
# Third-party. Do not edit.
function Invoke-VendorCall { $timeout = Read-LegacyTimeout; return "vendor:$timeout" }
'@, $utf8)
foreach ($m in @('api', 'cache', 'db', 'jobs', 'mail', 'search')) {
    $title = $m.Substring(0, 1).ToUpper() + $m.Substring(1)
    [System.IO.File]::WriteAllText((Join-Path $src "$m.ps1"), @"
function Invoke-$title {
    `$timeout = Read-LegacyTimeout
    return "${m}:`$timeout"
}
"@, $utf8)
}
