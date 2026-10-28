# Weekly follow-up report.
#
# Answers "did tuning help?" without remembering two commands. It finds the
# newest baseline-*.csv in the state directory, runs audit.ps1 against it and
# stats.ps1 over the last N days, and writes the combined report to
# state/tuner/weekly-YYYY-MM-DD.txt.
#
#   powershell -NoProfile -File weekly.ps1
#   powershell -NoProfile -File weekly.ps1 -Days 14
#   powershell -NoProfile -File weekly.ps1 -Baseline .\baseline.csv
#   powershell -NoProfile -File weekly.ps1 -NoFile
#
# Run it a week after tuning, not the same day: peak context and cache read need
# real sessions to move.

param(
    [int]$Days = 7,
    [int]$Recent = 20,
    # Use a specific baseline instead of the newest baseline-*.csv.
    [string]$Baseline = '',
    # Print only; do not write the report file.
    [switch]$NoFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

if ([string]::IsNullOrWhiteSpace($Baseline)) {
    $candidates = @(Get-ChildItem -LiteralPath $script:TunerState -Filter 'baseline-*.csv' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -gt 0) { $Baseline = $candidates[0].FullName }
}

# Run the child scripts with the interpreter that is running this one, so the
# report is identical under Windows PowerShell 5.1 and pwsh.
$Interpreter = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
$ExePrefix = @('-NoProfile')
if ($script:OnWindows) { $ExePrefix += @('-ExecutionPolicy', 'Bypass') }

$lines = New-Object System.Collections.ArrayList
function Add-Line { param([string]$Text = '') [void]$script:lines.Add($Text) }

Add-Line "opus-tuner weekly report - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Add-Line ''
if ($Baseline) {
    Add-Line "baseline: $(Split-Path -Leaf $Baseline)"
} else {
    Add-Line 'baseline: none found'
    Add-Line '  capture one before the next tuning change: audit.ps1 -Csv baseline.csv'
}
Add-Line ''

$auditArgs = @('-File', (Join-Path $PSScriptRoot 'audit.ps1'), '-Recent', "$Recent")
if ($Baseline) { $auditArgs += @('-Baseline', $Baseline) }
Add-Line ((& $Interpreter @ExePrefix @auditArgs 2>&1) -join "`n")
Add-Line ''

Add-Line ((& $Interpreter @ExePrefix -File (Join-Path $PSScriptRoot 'stats.ps1') -Days $Days 2>&1) -join "`n")

$text = ($lines -join "`n") + "`n"
Write-Host $text

if ($NoFile) { exit 0 }

if (-not (Test-Path -LiteralPath $script:TunerState)) {
    New-Item -ItemType Directory -Force -Path $script:TunerState | Out-Null
}
$report = Join-Path $script:TunerState ("weekly-" + (Get-Date -Format 'yyyy-MM-dd') + '.txt')
[System.IO.File]::WriteAllText($report, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "written: $report" -ForegroundColor Green
exit 0
