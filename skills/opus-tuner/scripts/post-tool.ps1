# PostToolUse / PostToolUseFailure hook: track the cheap signals the router uses.
# Achieved: repair-loop depth (consecutive failures) and edit breadth (distinct files).
# Also flags a single oversized tool result, at most bigOutputWarnings per session.
#
# This is the hottest hook in the bundle - it runs on every tool call - so it
# writes state only when a signal actually changed. A Read or a Grep changes
# nothing, and rewriting an identical file on each of them is pure waste.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

# Characters of text a tool result carries. The shape differs per tool (Bash has
# stdout/stderr, Read a nested file object, MCP tools anything), so count every
# string leaf rather than knowing each schema.
function Measure-TextChars {
    param($Value, [int]$Depth = 0)
    if ($null -eq $Value -or $Depth -gt 8) { return 0 }
    if ($Value -is [string]) { return $Value.Length }
    $n = 0
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($v in $Value.Values) { $n += Measure-TextChars $v ($Depth + 1) }
    } elseif ($Value -is [System.Collections.IEnumerable]) {
        foreach ($v in $Value) { $n += Measure-TextChars $v ($Depth + 1) }
    }
    return $n
}

try {
    $cfg = Get-TunerConfig
    # mode: off is documented as silent, which includes not writing state.
    if ($cfg['mode'] -eq 'off') { exit 0 }

    $in = Get-HookInput
    $sid = [string]$in['session_id']
    if ([string]::IsNullOrWhiteSpace($sid)) { exit 0 }

    $state = Read-State $sid
    $tool = [string]$in['tool_name']
    $evt = [string]$in['hook_event_name']
    $dirty = $false

    if ($evt -eq 'PostToolUseFailure') {
        $state['fails'] = [Math]::Min(9, [int]$state['fails'] + 1)
        if ([string]$state['gear'] -eq 'low') { $state['lowFailed'] = $true }
        $dirty = $true
    } else {
        # 'PowerShell' is the shell tool on Windows; without it a successful
        # command would never clear the failure counter and the repair-loop signal
        # would stay latched, escalating every later turn.
        if ($tool -in @('Bash', 'PowerShell', 'Edit', 'Write', 'MultiEdit', 'NotebookEdit')) {
            if ([int]$state['fails'] -ne 0) {
                $state['fails'] = 0
                $dirty = $true
            }
        }
        if ($tool -in @('Edit', 'Write', 'MultiEdit', 'NotebookEdit')) {
            $ti = $in['tool_input']
            $fp = $null
            if ($ti -is [System.Collections.IDictionary]) {
                foreach ($k in @('file_path', 'notebook_path', 'path')) {
                    if ($ti.Contains($k) -and $ti[$k]) { $fp = [string]$ti[$k]; break }
                }
            }
            if ($fp) {
                $files = @($state['files'])
                if ($files -notcontains $fp) {
                    $files += $fp
                    if ($files.Count -gt 60) {
                        $files = $files[($files.Count - 60)..($files.Count - 1)]
                    }
                    $state['files'] = $files
                    $dirty = $true
                }
            }
        }
    }

    # Tool output is what grows the context between two of the model's
    # decisions, and every later request re-reads it. When one result is large,
    # say so once, right next to it, while the habit can still change: this hook
    # runs async, so Claude Code hands the note to the model on its next request.
    # Edit-family results are skipped: they echo the whole original file, which
    # the model never sees.
    $warning = ''
    $limit = [int]$cfg['bigOutputTokens']
    $editTools = @('Edit', 'Write', 'MultiEdit', 'NotebookEdit')
    if ($evt -ne 'PostToolUseFailure' -and $limit -gt 0 -and $tool -and $editTools -notcontains $tool -and
        [int]$state['bigWarned'] -lt [int]$cfg['bigOutputWarnings']) {
        $tokens = [int]((Measure-TextChars $in['tool_response']) / 4)
        if ($tokens -ge $limit) {
            $state['bigWarned'] = [int]$state['bigWarned'] + 1
            $dirty = $true
            $hint = switch -Regex ($tool) {
                '^Read$'               { 'grep for the symbol first, then Read with offset/limit'; break }
                '^(Bash|PowerShell)$'  { 'pipe through tail, head or grep -n, or use --stat / --quiet'; break }
                '^Grep$'               { 'narrow the pattern or path, or use files_with_matches first'; break }
                default                { 'ask for a narrower result, or hand the search to a subagent' }
            }
            $warning = "[tuner] That $tool result was ~$(Format-Tokens $tokens) tokens, and every later request re-reads it. Next time: $hint."
        }
    }

    if ($dirty) { Write-State $sid $state }
    if ($warning) {
        Write-HookJson @{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $warning } }
    }
} catch { }
exit 0
