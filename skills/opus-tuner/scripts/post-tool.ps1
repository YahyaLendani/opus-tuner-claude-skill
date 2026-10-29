# PostToolUse / PostToolUseFailure hook: track the cheap signals the router uses.
# Achieved: repair-loop depth (consecutive failures) and edit breadth (distinct files).
#
# This is the hottest hook in the bundle - it runs on every tool call - so it
# writes state only when a signal actually changed. A Read or a Grep changes
# nothing, and rewriting an identical file on each of them is pure waste.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

try {
    # mode: off is documented as silent, which includes not writing state.
    if ((Get-TunerConfig)['mode'] -eq 'off') { exit 0 }

    $in = Get-HookInput
    $sid = [string]$in['session_id']
    if ([string]::IsNullOrWhiteSpace($sid)) { exit 0 }

    $state = Read-State $sid
    $tool = [string]$in['tool_name']
    $evt = [string]$in['hook_event_name']
    $dirty = $false

    if ($evt -eq 'PostToolUseFailure') {
        $state['fails'] = [Math]::Min(9, [int]$state['fails'] + 1)
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

    if ($dirty) { Write-State $sid $state }
} catch { }
exit 0
