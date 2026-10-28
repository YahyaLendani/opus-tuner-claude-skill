# Fails when a relative Markdown link points at a file that does not exist.
#
#   powershell -NoProfile -File tests/link-check.ps1
#
# Absolute URLs are not fetched here: that is tests/badge-check.ps1. Fenced code
# blocks are skipped, so an example link inside a fence is not treated as a
# target, and anchors are ignored because heading slugs change for good reasons.

param(
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path

$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.md |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })

$checked = 0
$broken = New-Object System.Collections.ArrayList
$sep = [System.IO.Path]::DirectorySeparatorChar

foreach ($file in $files) {
    $dir = Split-Path -Parent $file.FullName
    $shown = $file.FullName.Replace($Root + $sep, '')
    $inFence = $false
    $lineNo = 0

    foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
        $lineNo++
        if ($line -match '^\s*(```|~~~)') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }

        foreach ($m in [regex]::Matches($line, '\]\(<?([^)>\s]+)>?\)')) {
            $target = $m.Groups[1].Value

            # Not a local file: external URL, mail link, same-page anchor.
            if ($target -match '^(https?:|mailto:|#|//)') { continue }
            if ($target -match '^/') { continue }

            $path = ($target -split '#')[0]
            if (-not $path) { continue }
            $path = [System.Uri]::UnescapeDataString($path)
            $checked++

            if (-not (Test-Path -LiteralPath (Join-Path $dir $path))) {
                [void]$broken.Add("${shown}:${lineNo} -> $target")
            }
        }
    }
}

if ($broken.Count -gt 0) {
    Write-Host "broken relative links: $($broken.Count)" -ForegroundColor Red
    foreach ($b in $broken) { Write-Host "  $b" -ForegroundColor Red }
    exit 1
}

Write-Host "links ok: $checked relative links across $($files.Count) files" -ForegroundColor Green
exit 0
