# Write and verify a handoff for one identified session.
#
#   powershell -NoProfile -File brief.ps1 -SessionId <id> -Project <dir>
#   powershell -NoProfile -File brief.ps1 -SessionId <id> -Verify
#
# Writing derives the facts from that session's own transcript and leaves the
# rest as placeholders for the model. -Verify checks the required sections, masks
# credentials and marks the file ready; only then may the user be asked to /clear.
#
# Exits 1 when the session cannot be identified or the handoff is incomplete. It
# never guesses a session and never runs /clear.

param(
    [string]$SessionId = '',
    [string]$Transcript = '',
    [Alias('Cwd')][string]$Project = '',
    [switch]$Verify,
    [switch]$IncludeCommandArgs,
    [int]$TailBytes = 2000000
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

function Stop-Brief {
    param([string]$Why)
    "brief failed: $Why"
    'no handoff is ready. Tell the user what failed; do not ask them to /clear for a handoff.'
    exit 1
}

# The program names in a command line, with everything after them left out: the
# arguments are where credentials live. Quote-aware, and the first line only, so
# a heredoc body or a quoted string can never be mistaken for a program.
function Get-CommandPrograms {
    param([string]$Command)
    $line = ($Command -split "`r?`n", 2)[0]
    $segments = New-Object System.Collections.ArrayList
    $sb = New-Object System.Text.StringBuilder
    $quote = [char]0
    $esc = $false
    foreach ($c in $line.ToCharArray()) {
        if ($esc) { [void]$sb.Append($c); $esc = $false; continue }
        if ($quote -ne [char]0) {
            if ($c -eq '\' -and $quote -eq '"') { $esc = $true }
            elseif ($c -eq $quote) { $quote = [char]0 }
            [void]$sb.Append($c)
            continue
        }
        if ($c -eq '"' -or $c -eq "'") { $quote = $c; [void]$sb.Append($c); continue }
        if ($c -eq ';' -or $c -eq '|' -or $c -eq '&') {
            [void]$segments.Add($sb.ToString())
            [void]$sb.Clear()
            continue
        }
        [void]$sb.Append($c)
    }
    [void]$segments.Add($sb.ToString())

    $out = New-Object System.Collections.ArrayList
    foreach ($seg in $segments) {
        $rest = ([string]$seg).Trim()
        while ($rest) {
            $m = [regex]::Match($rest, '^(?:"([^"]*)"|''([^'']*)''|(\S+))\s*')
            if (-not $m.Success) { break }
            $rest = $rest.Substring($m.Length)
            # FOO=bar cmd: the assignment is an argument too, and a likely secret.
            if ($m.Groups[3].Success -and $m.Groups[3].Value -match '^[A-Za-z_][A-Za-z0-9_]*=') { continue }
            $token = "$($m.Groups[1].Value)$($m.Groups[2].Value)$($m.Groups[3].Value)"
            $name = ($token -split '[\\/]')[-1]
            if ($name -match '^[A-Za-z0-9_.+-]{1,32}$' -and (Protect-Sensitive $name) -ceq $name) { [void]$out.Add($name) }
            break
        }
    }
    return , $out
}

# Files and commands from the session's own tool calls, newest first. Parsed from
# tool_use blocks, so text that merely mentions a command is not recorded as one.
function Get-TranscriptActivity {
    param([string]$Path, [string]$Sid, [int]$Bytes, [int]$MaxFiles = 20, [int]$MaxCommands = 40)
    $files = New-Object System.Collections.ArrayList
    $commands = New-Object System.Collections.ArrayList
    $text = Read-FileTail -Path $Path -Bytes $Bytes
    if ($text) {
        $lines = $text -split "`n"
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($files.Count -ge $MaxFiles -and $commands.Count -ge $MaxCommands) { break }
            $line = $lines[$i]
            if ($line.IndexOf('"tool_use"') -lt 0) { continue }
            $o = $null
            try { $o = $line | ConvertFrom-Json } catch { continue }
            if ([string]$o.type -ne 'assistant' -or $o.isSidechain -eq $true) { continue }
            if ($o.sessionId -and [string]$o.sessionId -cne $Sid) { continue }
            foreach ($b in @($o.message.content)) {
                if ([string]$b.type -ne 'tool_use' -or -not $b.input) { continue }
                $fp = [string]$b.input.file_path
                if (-not $fp) { $fp = [string]$b.input.notebook_path }
                if ($fp -and $files.Count -lt $MaxFiles -and $files -notcontains $fp) { [void]$files.Add($fp) }
                if (@('Bash', 'PowerShell') -contains [string]$b.name -and $b.input.command -and $commands.Count -lt $MaxCommands) {
                    [void]$commands.Add([string]$b.input.command)
                }
            }
        }
    }
    return @{ files = $files; commands = $commands }
}

function Format-HandoffFile {
    param($Meta, [string]$Body)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("---`n")
    foreach ($k in @('session_id', 'project', 'transcript', 'status', 'written', 'verified')) {
        if ($Meta[$k]) { [void]$sb.Append("${k}: $($Meta[$k])`n") }
    }
    [void]$sb.Append("---`n")
    [void]$sb.Append($Body)
    return $sb.ToString()
}

# ---------- identity ----------
$sid = Resolve-SessionId $SessionId
if ([string]::IsNullOrWhiteSpace($sid)) { Stop-Brief 'the session is not identified. Pass -SessionId; no other session''s transcript is used instead.' }
if (-not (Test-SessionId $sid)) { Stop-Brief 'the session id contains characters a session id cannot have.' }

# ---------- verify ----------
if ($Verify) {
    $path = Get-HandoffPath $sid
    $h = Read-Handoff $path
    if (-not $h) { Stop-Brief "no handoff for session $sid at $path. Write the draft first." }
    if ($h['session_id'] -cne $sid) { Stop-Brief "$path belongs to session $($h['session_id'])." }
    if ($Project -and -not (Test-SameProject $h['project'] $Project)) { Stop-Brief "$path belongs to project $($h['project'])." }

    $body = ([string]$h['body']) -replace "`r`n", "`n"
    $headings = [regex]::Matches($body, '(?m)^## (.+?)[ \t]*$')
    $missing = New-Object System.Collections.ArrayList
    $requiredEnd = 0
    foreach ($title in $script:HandoffRequired) {
        $found = $false
        for ($i = 0; $i -lt $headings.Count; $i++) {
            if ($headings[$i].Groups[1].Value -ne $title) { continue }
            $found = $true
            $start = $headings[$i].Index + $headings[$i].Length
            $end = if ($i + 1 -lt $headings.Count) { $headings[$i + 1].Index } else { $body.Length }
            $content = ([regex]::Replace($body.Substring($start, $end - $start), '(?s)<!--.*?-->', '')).Trim()
            if (-not $content -or $content -match '_\(fill:') { [void]$missing.Add($title) }
            if ($end -gt $requiredEnd) { $requiredEnd = $end }
            break
        }
        if (-not $found) { [void]$missing.Add($title) }
    }

    if ($missing.Count -gt 0) {
        "handoff incomplete: $path"
        "missing: $($missing -join ', ')"
        'next: fill those sections and verify again. Do not recommend /clear yet.'
        exit 1
    }
    if ($requiredEnd -gt $script:HandoffMaxChars) {
        "handoff incomplete: $path"
        "the required sections are $requiredEnd characters, over the $($script:HandoffMaxChars) a new session can receive."
        'next: shorten them and verify again. Do not recommend /clear yet.'
        exit 1
    }

    # An optional section still holding its placeholder is noise in the new session.
    $body = [regex]::Replace($body, '(?ms)^## [^\n]*\n\s*_\(optional:[^\n]*\)_\s*(?=^## |\z)', '')
    $clean = Protect-Sensitive $body
    $h['status'] = 'ready'
    $h['verified'] = (Get-Date).ToString('o')
    if (-not (Write-AtomicText $path (Format-HandoffFile $h $clean))) { Stop-Brief "could not write $path" }

    "handoff ready: $path"
    if ($clean -cne $body) { 'sensitive values were redacted before saving.' }
    'next: when the user wants to continue in a fresh session, ask them to run /clear. Do not run it yourself.'
    exit 0
}

# ---------- draft ----------
$resolved = Resolve-SessionTranscript -SessionId $sid -Transcript $Transcript
if (-not $resolved['ok']) { Stop-Brief $resolved['error'] }
$Transcript = $resolved['transcript']

$cwds = Get-TranscriptCwds $Transcript
if ($Project) {
    $related = @($cwds | Where-Object { Test-RelatedProject $_ $Project })
    if ($cwds.Count -gt 0 -and $related.Count -eq 0) { Stop-Brief "session $sid did not run in $Project; its transcript reports $($cwds[$cwds.Count - 1])." }
} elseif ($cwds.Count -gt 0) {
    $Project = $cwds[$cwds.Count - 1]
} else {
    Stop-Brief "the project directory is unknown: the transcript names none. Pass -Project."
}

$info = Get-ContextInfo -TranscriptPath $Transcript
$activity = Get-TranscriptActivity -Path $Transcript -Sid $sid -Bytes $TailBytes
$tier = [string](Read-State $sid)['tier']

$branch = ''
$dirty = @()
try {
    Push-Location -LiteralPath $Project
    $branch = (& git rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)
    $dirty = @(& git status --porcelain 2>$null | Select-Object -First 15)
    Pop-Location
} catch { try { Pop-Location } catch { } }

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("# Handoff - $(Split-Path -Leaf $Project)`n`n")
[void]$sb.Append("Written $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Continue from **Next step**; do not re-explore what this file records.`n`n")
foreach ($s in @(
    @('Task goal', '_(fill: the outcome the user asked for)_'),
    @('User constraints', '_(fill: rules the user set that still apply, or None.)_'),
    @('Decisions', '_(fill: what was chosen and why, or None.)_'),
    @('Unresolved problems', '_(fill: what is still broken or undecided, or None.)_'),
    @('Verification results', '_(fill: what was actually run and its result, and what was not verified)_'),
    @('Next step', '_(fill: one concrete action)_'),
    @('Dead ends', '_(optional: what was tried and failed, so it is not retried)_')
)) {
    [void]$sb.Append("## $($s[0])`n`n$($s[1])`n`n")
}

[void]$sb.Append("## Facts`n`n")
[void]$sb.Append("- project: ``$Project```n")
[void]$sb.Append("- model: $($info.model)   tier: $tier   ctx at handoff: $(Format-Tokens $info.ctx)`n")
if ($branch) { [void]$sb.Append("- git branch: $branch`n") }
if ($dirty.Count -gt 0) {
    [void]$sb.Append("- uncommitted:`n")
    foreach ($d in $dirty) { [void]$sb.Append("  - ``$d```n") }
}
[void]$sb.Append("`n## Files touched`n`n")
if ($activity.files.Count -gt 0) { foreach ($f in $activity.files) { [void]$sb.Append("- ``$f```n") } } else { [void]$sb.Append("- none recorded`n") }

[void]$sb.Append("`n## Commands run`n`n")
if ($IncludeCommandArgs) {
    $seen = New-Object System.Collections.ArrayList
    foreach ($c in $activity.commands) {
        # Redact before flattening or cutting: a private key spans lines, and a
        # value cut in half no longer matches its pattern.
        $v = (Protect-Sensitive $c) -replace '\s*\r?\n\s*', ' '
        if ($v.Length -gt 160) { $v = $v.Substring(0, 157) + '...' }
        if ($seen -notcontains $v) { [void]$seen.Add($v) }
        if ($seen.Count -ge 12) { break }
    }
    if ($seen.Count -gt 0) { foreach ($v in $seen) { [void]$sb.Append("- ``$v```n") } } else { [void]$sb.Append("- none recorded`n") }
} else {
    $counts = [ordered]@{}
    foreach ($c in $activity.commands) {
        foreach ($p in (Get-CommandPrograms $c)) {
            if ($counts.Contains($p)) { $counts[$p]++ } else { $counts[$p] = 1 }
        }
    }
    if ($counts.Count -gt 0) {
        foreach ($p in $counts.Keys) { [void]$sb.Append("- $p ($($counts[$p]))`n") }
        [void]$sb.Append("`nArguments are omitted. brief.ps1 -IncludeCommandArgs adds them, redacted.`n")
    } else {
        [void]$sb.Append("- none recorded`n")
    }
}

$meta = @{ session_id = $sid; project = $Project; transcript = $Transcript; status = 'draft'; written = (Get-Date).ToString('o') }
$path = Get-HandoffPath $sid
if (-not (Write-AtomicText $path (Format-HandoffFile $meta (Protect-Sensitive $sb.ToString())))) { Stop-Brief "could not write $path" }

"handoff draft written: $path"
"facts: $($activity.files.Count) files, $($activity.commands.Count) commands, ctx $(Format-Tokens $info.ctx), tier $tier"
"next: fill $($script:HandoffRequired -join ' / ') in that file, then run this script again with -SessionId $sid -Verify."
exit 0
