# Write the handoff brief. Facts come from the transcript in code; the soft
# sections are left as placeholders for the model to fill before /clear.
#
#   powershell -NoProfile -File brief.ps1 -Cwd (Get-Location).Path

param(
    [string]$Cwd = '',
    [string]$Transcript = '',
    [int]$TailBytes = 2000000
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

function Get-UniqueFromTail {
    param([string]$Text, [string]$Pattern, [int]$Max = 15)
    $seen = New-Object System.Collections.ArrayList
    $out = New-Object System.Collections.ArrayList
    $ms = [regex]::Matches($Text, $Pattern)
    for ($i = $ms.Count - 1; $i -ge 0 -and $out.Count -lt $Max; $i--) {
        $v = $ms[$i].Groups[1].Value
        $v = $v -replace '\\\\', '\' -replace '\\"', '"'
        if ($v.Length -gt 160) { $v = $v.Substring(0, 157) + '...' }
        if ($v -and ($seen -notcontains $v)) {
            [void]$seen.Add($v)
            [void]$out.Add($v)
        }
    }
    return $out
}

try {
    if ([string]::IsNullOrWhiteSpace($Cwd)) { $Cwd = (Get-Location).Path }
    if ([string]::IsNullOrWhiteSpace($Transcript)) { $Transcript = Get-NewestTranscript }

    $info = Get-ContextInfo -TranscriptPath $Transcript
    $text = Read-FileTail -Path $Transcript -Bytes $TailBytes
    if (-not $text) { $text = '' }

    $files = Get-UniqueFromTail -Text $text -Pattern '"file_path"\s*:\s*"((?:[^"\\]|\\.)*)"' -Max 20
    $cmds = Get-UniqueFromTail -Text $text -Pattern '"command"\s*:\s*"((?:[^"\\]|\\.)*)"' -Max 12

    $branch = ''
    $dirty = @()
    try {
        Push-Location -LiteralPath $Cwd
        $branch = (& git rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)
        $dirty = @(& git status --porcelain 2>$null | Select-Object -First 15)
        Pop-Location
    } catch { try { Pop-Location } catch { } }

    $statePath = Join-Path $script:TunerState 'latest.json'
    $tier = 'routine'
    $stateFiles = Get-ChildItem -LiteralPath $script:TunerState -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($stateFiles) {
        try {
            $s = ConvertTo-Hashtable (Get-Content -LiteralPath $stateFiles.FullName -Raw | ConvertFrom-Json)
            if ($s -is [System.Collections.IDictionary] -and $s.Contains('tier')) { $tier = [string]$s['tier'] }
        } catch { }
    }

    $outDir = Join-Path $Cwd '.claude'
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    $outPath = Join-Path $outDir 'handoff.md'

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# Handoff - $(Split-Path -Leaf $Cwd)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Written $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Continue from **Next step**; do not re-explore what this file records.")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Facts')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- project: ``$Cwd``")
    [void]$sb.AppendLine("- model: $($info.model)   tier: $tier   ctx at handoff: $(Format-Tokens $info.ctx)")
    if ($branch) { [void]$sb.AppendLine("- git branch: $branch") }
    if ($dirty.Count -gt 0) {
        [void]$sb.AppendLine('- uncommitted:' )
        foreach ($d in $dirty) { [void]$sb.AppendLine("  - ``$d``") }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Files touched')
    [void]$sb.AppendLine('')
    if ($files.Count -gt 0) { foreach ($f in $files) { [void]$sb.AppendLine("- ``$f``") } } else { [void]$sb.AppendLine('- none recorded') }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Commands run')
    [void]$sb.AppendLine('')
    if ($cmds.Count -gt 0) { foreach ($c in $cmds) { [void]$sb.AppendLine("- ``$c``") } } else { [void]$sb.AppendLine('- none recorded') }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Decisions')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('_(fill: 3-6 bullets, what was chosen and why)_')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Dead ends')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('_(fill: what was tried and did not work, so it is not retried)_')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Unverified assumptions')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('_(fill: what is believed but not yet proven)_')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Next step')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('_(fill: one concrete action)_')

    Set-Content -LiteralPath $outPath -Value $sb.ToString() -Encoding UTF8

    "brief written: $outPath"
    "facts: $($files.Count) files, $($cmds.Count) commands, ctx $(Format-Tokens $info.ctx), tier $tier"
    "next: fill Decisions / Dead ends / Unverified assumptions / Next step, then tell the user to run /clear"
} catch {
    "brief failed: $($_.Exception.Message)"
}
exit 0
