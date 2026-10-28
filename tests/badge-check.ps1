# Fetches every badge image in README.md and asserts it renders a real value.
#
#   powershell -NoProfile -File tests/badge-check.ps1
#
# This is the only test that talks to the network, so CI runs it with
# continue-on-error: a shields.io outage must not fail a pull request. It exists
# because a badge can keep showing "no releases" or "failing" from a cache long
# after the thing it describes is true, and nobody notices.
#
# The actions badge is checked twice: the workflow file it names must exist in
# .github/workflows, and the image must not say the workflow is missing.

param(
    [string]$Root = '',
    [int]$TimeoutSec = 20
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path

$readmePath = Join-Path $Root 'README.md'
if (-not (Test-Path -LiteralPath $readmePath)) { throw "no README.md under $Root" }
$readme = Get-Content -LiteralPath $readmePath -Raw

$urls = New-Object System.Collections.ArrayList
foreach ($m in [regex]::Matches($readme, '!\[[^\]]*\]\(([^)\s]+)\)')) {
    $u = $m.Groups[1].Value
    if (-not $urls.Contains($u)) { [void]$urls.Add($u) }
}

if ($urls.Count -eq 0) { throw 'no badge images found in README.md' }

$failed = 0
foreach ($url in $urls) {
    $label = $url -replace '^https://(img\.shields\.io|github\.com)/', ''

    # Static half: a workflow badge for a file that does not exist is a 404 no
    # matter what the CDN says.
    $wf = [regex]::Match($url, 'actions/workflows/([^/]+)/badge\.svg')
    if ($wf.Success) {
        $wfPath = Join-Path (Join-Path (Join-Path $Root '.github') 'workflows') $wf.Groups[1].Value
        if (-not (Test-Path -LiteralPath $wfPath)) {
            Write-Host "  FAIL  $label  (no .github/workflows/$($wf.Groups[1].Value))" -ForegroundColor Red
            $failed++
            continue
        }
    }

    $title = ''
    $lastError = ''
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec
            $m = [regex]::Match($r.Content, '<title>(.*?)</title>')
            if ($m.Success) { $title = $m.Groups[1].Value }
            if ($r.StatusCode -ne 200) { $lastError = "HTTP $($r.StatusCode)"; continue }
            $lastError = ''
            break
        } catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt 2) { Start-Sleep -Seconds 2 }
        }
    }

    if ($lastError) {
        Write-Host "  FAIL  $label  ($lastError)" -ForegroundColor Red
        $failed++
        continue
    }
    if ($title -match '(?i)no releases|not found|invalid|unknown|error') {
        Write-Host "  FAIL  $label  -> '$title'" -ForegroundColor Red
        $failed++
        continue
    }

    Write-Host ("  ok    {0}" -f $title) -ForegroundColor Green
}

if ($failed -gt 0) {
    Write-Host "$failed of $($urls.Count) badges did not render" -ForegroundColor Red
    exit 1
}
Write-Host "$($urls.Count) badges rendered" -ForegroundColor Green
exit 0
