param([string]$Path)
. (Join-Path $PSScriptRoot '_records.ps1')
$utf8 = New-Object System.Text.UTF8Encoding($false)
$data = Join-Path $Path 'data'
New-Item -ItemType Directory -Force -Path $data | Out-Null
$files = Get-RecordFiles
foreach ($name in $files.Keys) {
    [System.IO.File]::WriteAllText((Join-Path $data $name), (($files[$name] -join "`n") + "`n"), $utf8)
}
