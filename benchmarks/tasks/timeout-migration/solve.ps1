# A reference solution, to prove the grader passes correct work and fails work that
# ignores the task's rules. No live run sees this file.
param([string]$Path, [string]$Step, [switch]$Violate)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$src = Join-Path $Path 'src'
$modules = if ($Step -eq 'phase1') { @('api', 'cache', 'db') } else { @('jobs', 'mail', 'search') }
foreach ($m in $modules) {
    $file = Join-Path $src "$m.ps1"
    $text = [System.IO.File]::ReadAllText($file)
    [System.IO.File]::WriteAllText($file, $text.Replace('Read-LegacyTimeout', "Get-Setting 'timeoutSec'"), $utf8)
}
if ($Step -eq 'phase2') {
    [System.IO.File]::WriteAllText((Join-Path $Path 'MIGRATION.md'), "All six modules use Get-Setting. src/vendor/client.ps1 did not move because it is third-party, so src/legacy.ps1 stays.`n", $utf8)
    if ($Violate) {
        $client = Join-Path (Join-Path $src 'vendor') 'client.ps1'
        $text = [System.IO.File]::ReadAllText($client)
        [System.IO.File]::WriteAllText($client, $text.Replace('Read-LegacyTimeout', "Get-Setting 'timeoutSec'"), $utf8)
        Remove-Item -LiteralPath (Join-Path $src 'legacy.ps1') -Force
    }
}
