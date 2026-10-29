# Shared helpers for opus-tuner. Dot-source this from hook scripts.
# Keep everything here allocation-light: these run on every tool call.

$ErrorActionPreference = 'Stop'

# Follow Claude Code's own config-dir relocation when it is set. A sandboxed
# install (CLAUDE_CONFIG_DIR=C:\temp\sandbox) then reads its own config and
# state instead of the real ones, which is what makes the test suite safe.
#
# One codebase, three platforms. Windows PowerShell 5.1 and pwsh 7 differ in two
# places only: where home is, and how paths are joined. Resolve both here so no
# hook has to care.
$script:OnWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
$script:HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE }
                  elseif ($env:HOME) { $env:HOME }
                  else { [System.Environment]::GetFolderPath('UserProfile') }
$script:TunerRoot   = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $script:HomeDir '.claude' }
$script:TunerState  = Join-Path (Join-Path $script:TunerRoot 'state') 'tuner'
$script:TunerConfig = Join-Path $script:TunerRoot 'tuner.config.json'
# Tests and experiments can point at a different config without touching the live
# one. Nothing else reads this, and unset behaves exactly as before.
if ($env:OPUS_TUNER_CONFIG) { $script:TunerConfig = $env:OPUS_TUNER_CONFIG }
if ($env:OPUS_TUNER_STATE)  { $script:TunerState  = $env:OPUS_TUNER_STATE }

function ConvertTo-Hashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string]) { return $InputObject }
    if ($InputObject -is [ValueType]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[[string]$k] = ConvertTo-Hashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $out = New-Object System.Collections.ArrayList
        foreach ($i in $InputObject) { [void]$out.Add((ConvertTo-Hashtable $i)) }
        return , $out
    }
    $h = @{}
    foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
    return $h
}

function Get-TunerConfig {
    param([switch]$Defaults)
    $cfg = @{
        mode                  = 'advise'
        routineTokens         = 150000
        deepTokens            = 250000
        graceTokens           = 25000
        nudgeAt               = 0.7
        maxTurnsPerSession    = 2
        minCtxForDownshift    = 100000
        downshiftRequiresBulk = $true
        hardWrap              = $true
        logDecisions          = $true
        downshift             = $true
        profile               = 'dev'
        profileNote           = ''
        deepPatterns          = 'refactor|architect|root cause|race condition|deadlock|migrat|redesign|why does|why is|why did|flaky|intermittent|investigate|prove|optimi[sz]|memory leak|performance|concurren|thread-safe|vulnerab|rewrite|overhaul|regression'
        mechanicalPatterns    = 'rename|format|lint|prettier|eslint|typo|bump|commit|git status|run tests|run the tests|npm test|chmod|move file|copy file|list files|add header|add license'
        bulkPatterns          = '\ball\b|every|across|each file|multiple files|whole repo|whole project|codebase|batch|bulk|throughout'
    }
    if (-not $Defaults -and (Test-Path -LiteralPath $script:TunerConfig)) {
        try {
            $raw = Get-Content -LiteralPath $script:TunerConfig -Raw -Encoding UTF8
            $parsed = ConvertTo-Hashtable ($raw | ConvertFrom-Json)
            if ($parsed -is [System.Collections.IDictionary]) {
                foreach ($k in $parsed.Keys) { $cfg[$k] = $parsed[$k] }
            }
        } catch { }
    }

    # The active profile is applied last, so switching it always changes
    # behaviour even when the same knob is also set at the top level. To tune a
    # profile, override it under "profiles": { "<name>": { ... } }.
    $profiles = Get-TunerProfiles
    $name = ([string]$cfg['profile']).Trim().ToLowerInvariant()
    if (-not $profiles.Contains($name)) {
        if ($name) { $cfg['profileInvalid'] = $name }
        $name = 'dev'
    }
    $cfg['profile'] = $name
    foreach ($k in $profiles[$name].Keys) { $cfg[$k] = $profiles[$name][$k] }
    $custom = $cfg['profiles']
    if ($custom -is [System.Collections.IDictionary] -and $custom[$name] -is [System.Collections.IDictionary]) {
        foreach ($k in $custom[$name].Keys) { $cfg[$k] = $custom[$name][$k] }
    }
    return $cfg
}

# Two named profiles. Dev is the defaults above, unchanged. Creative is for
# writing and ideation, where the code-shaped rules misfire:
#   - no downshift to gear-low, whose "no plan, no preamble" is wrong for prose;
#   - no gear-max, because extra thinking buys little for prose quality;
#   - the deep tier escalates on long-form vocabulary, since a draft legitimately
#     needs more context than a code task does;
#   - one short note tells the model what changed. It is the only text a profile
#     adds to the context, and `profile.ps1 show` prints it verbatim.
function Get-TunerProfiles {
    return @{
        dev      = @{}
        creative = @{
            downshift          = $false
            maxTurnsPerSession = 0
            deepPatterns       = 'rewrite|restructure|overhaul|outline|story arc|plot|worldbuild|chapter|manuscript|long-form|screenplay|style guide|series'
            profileNote        = '[tuner] profile=creative: this session is writing or ideation, not code. Drafts, options and full prose are the work: write at the length the piece needs, offer distinct alternatives when exploring, and keep the user''s voice unless asked to change it. Tool rules (batch calls, grep before read) still apply when you use tools. Do not restate the brief or paste back unchanged text; quote only what changed.'
        }
    }
}

# Get-TunerConfig fails open to the defaults, which is correct for a hook but
# leaves a typo invisible: a user who writes "routineTokens": "150k" silently
# runs on defaults. This returns a warning string for SessionStart to show once.
function Get-TunerConfigIssue {
    if (-not (Test-Path -LiteralPath $script:TunerConfig)) { return '' }
    try {
        $raw = Get-Content -LiteralPath $script:TunerConfig -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'empty' }
        $null = $raw | ConvertFrom-Json
        return ''
    } catch {
        return "tuner.config.json is not valid JSON, so every setting is running on its default. Fix or delete $($script:TunerConfig)"
    }
}

function Get-HookInput {
    try {
        $raw = [Console]::In.ReadToEnd()
    } catch { return @{} }
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    try {
        $o = ConvertTo-Hashtable ($raw | ConvertFrom-Json)
        if ($o -is [System.Collections.IDictionary]) { return $o }
        return @{}
    } catch { return @{} }
}

function Write-HookJson {
    param($Object)
    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    [Console]::Out.Write($json)
    [Console]::Out.Flush()
}

function Get-StatePath {
    param([string]$SessionId)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { $SessionId = 'default' }
    $safe = ($SessionId -replace '[^A-Za-z0-9_-]', '_')
    if (-not (Test-Path -LiteralPath $script:TunerState)) {
        New-Item -ItemType Directory -Force -Path $script:TunerState | Out-Null
    }
    return (Join-Path $script:TunerState "$safe.json")
}

function New-State {
    return @{
        tier    = 'routine'
        gear    = 'high'
        files   = @()
        fails   = 0
        maxUses = 0
        nudged  = @{ soft = $false; ceiling = $false; escalated = $false; hardWrap = $false; compact = $false; routeCeiling = $false }
        updated = ''
    }
}

function Read-State {
    param([string]$SessionId)
    $p = Get-StatePath $SessionId
    if (-not (Test-Path -LiteralPath $p)) { return (New-State) }
    try {
        $s = ConvertTo-Hashtable (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
        if (-not ($s -is [System.Collections.IDictionary])) { return (New-State) }
        $d = New-State
        foreach ($k in $d.Keys) {
            if (-not $s.Contains($k)) { $s[$k] = $d[$k] }
        }
        if (-not ($s['nudged'] -is [System.Collections.IDictionary])) {
            $s['nudged'] = @{ soft = $false; ceiling = $false; escalated = $false; hardWrap = $false; compact = $false; routeCeiling = $false }
        }
        foreach ($k in @('soft', 'ceiling', 'escalated', 'hardWrap', 'compact', 'routeCeiling')) {
            if (-not $s['nudged'].Contains($k)) { $s['nudged'][$k] = $false }
        }
        return $s
    } catch { return (New-State) }
}

function Write-State {
    param([string]$SessionId, $State)
    $State['updated'] = (Get-Date).ToString('o')
    $p = Get-StatePath $SessionId
    $json = $State | ConvertTo-Json -Depth 8 -Compress
    # post-tool.ps1 runs async and several tool calls can finish at once, so a
    # concurrent writer can hold the file for a few milliseconds. Retrying beats
    # silently dropping the counter update.
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            [System.IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding($false)))
            return
        } catch {
            if ($attempt -lt 2) { Start-Sleep -Milliseconds 20 }
        }
    }
}

# Reads only the tail of a transcript. Transcripts reach 100+ MB; reading the
# whole file on every hook would cost more than the tokens we are saving.
function Read-FileTail {
    param([string]$Path, [int]$Bytes = 524288)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        $len = $fs.Length
        if ($len -le 0) { return '' }
        $start = [Math]::Max([int64]0, $len - $Bytes)
        $fs.Position = $start
        $count = [int]($len - $start)
        $buf = New-Object byte[] $count
        $read = $fs.Read($buf, 0, $count)
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        if ($start -gt 0) {
            $idx = $text.IndexOf("`n")
            if ($idx -ge 0) { $text = $text.Substring($idx + 1) }
        }
        return $text
    } catch { return $null }
    finally { if ($fs) { $fs.Dispose() } }
}

# Finds the last "usage" object in a block of text that reports a non-zero
# token count. Returns @{ sum; index } or $null.
#
# A usage object is not flat: it nests "server_tool_use" and "cache_creation",
# so a regex like \{.*?\} truncates it. Brute force instead: locate each
# `"usage":{`, then walk forward with a depth counter (string-aware, so a brace
# inside message text cannot unbalance it). Iterating backwards means the usual
# case stops at the first candidate.
function Find-LastUsage {
    param([string]$Text)
    if (-not $Text) { return $null }

    $starts = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Text, '"usage"\s*:\s*\{')) {
        [void]$starts.Add($m.Index + $m.Length - 1)
    }

    for ($k = $starts.Count - 1; $k -ge 0; $k--) {
        $start = [int]$starts[$k]
        $depth = 0
        $inStr = $false
        $esc = $false
        $end = -1

        for ($j = $start; $j -lt $Text.Length; $j++) {
            $c = $Text[$j]
            if ($inStr) {
                if ($esc) { $esc = $false }
                elseif ($c -ceq '\') { $esc = $true }
                elseif ($c -ceq '"') { $inStr = $false }
                continue
            }
            if ($c -ceq '"') { $inStr = $true; continue }
            if ($c -ceq '{') { $depth++ }
            elseif ($c -ceq '}') {
                $depth--
                if ($depth -eq 0) { $end = $j; break }
            }
        }
        if ($end -lt 0) { continue }

        $block = $Text.Substring($start, $end - $start + 1)

        # Only the top-level members count. A usage object repeats the same
        # numbers inside a nested "iterations" array, so summing every match
        # doubles the total. Every nested object begins at the first inner
        # brace, and the top-level token keys precede it.
        $cut = $block.IndexOf('{', 1)
        $flat = if ($cut -gt 0) { $block.Substring(0, $cut) } else { $block }

        $sum = [int64]0
        foreach ($key in @('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens')) {
            $km = [regex]::Match($flat, '"' + $key + '":(\d+)')
            if (-not $km.Success) { $km = [regex]::Match($block, '"' + $key + '":(\d+)') }
            if ($km.Success) { $sum += [int64]$km.Groups[1].Value }
        }
        if ($sum -gt 0) { return @{ sum = $sum; index = $start } }
    }
    return $null
}

# Context size = input + cache_read + cache_creation of the last assistant
# message. That sum is what the next request actually re-reads.
#
# Reads raw text rather than parsing lines as JSON: a single transcript line can
# be hundreds of KB, and ConvertFrom-Json on it costs ~200 ms on PowerShell 5.1.
# The window escalates because the newest lines in a transcript are bookkeeping,
# which can push the last usage block out of the first window.
function Get-ContextInfo {
    param([string]$TranscriptPath, [int]$Bytes = 524288)
    $result = @{ ctx = [int64]0; model = ''; found = $false }

    foreach ($window in @(131072, $Bytes, 4194304)) {
        $text = Read-FileTail -Path $TranscriptPath -Bytes $window
        if (-not $text) { continue }

        $hit = Find-LastUsage -Text $text
        if (-not $hit) { continue }

        $result.ctx = [int64]$hit.sum
        $result.found = $true

        $from = [Math]::Max(0, $hit.index - 4000)
        $head = $text.Substring($from, $hit.index - $from)
        $mm = [regex]::Matches($head, '"model":"([^"]+)"')
        if ($mm.Count -gt 0) { $result.model = $mm[$mm.Count - 1].Groups[1].Value }

        return $result
    }
    return $result
}

function Format-Tokens {
    param($N)
    $v = [double]$N
    if ($v -ge 1000000) { return ('{0:0.0}M' -f ($v / 1000000)) }
    if ($v -ge 1000) { return ('{0:0}k' -f ($v / 1000)) }
    return [string][int]$v
}

function Get-Ceiling {
    param($Config, [string]$Tier)
    if ($Tier -eq 'deep') { return [int64]$Config['deepTokens'] }
    return [int64]$Config['routineTokens']
}

function Get-NewestTranscript {
    $projects = Join-Path $script:TunerRoot 'projects'
    if (-not (Test-Path -LiteralPath $projects)) { return $null }
    $f = Get-ChildItem -LiteralPath $projects -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

# One line per decision, not per prompt. Without this the bundle can only be
# judged by its end effect on cost, weeks later; with it, "gears fired 40 times
# and none of them paid" is answerable from a file. Rotates at 1 MB, keeps one.
function Write-Decision {
    param($Config, [string]$SessionId, [int64]$Ctx, [string]$Tier, [string]$Gear, [string]$Action)
    if ($Config -and $Config.ContainsKey('logDecisions') -and -not [bool]$Config['logDecisions']) { return }
    try {
        $dir = $script:TunerState
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $log = Join-Path $dir 'decisions.csv'
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB) {
            Move-Item -LiteralPath $log -Destination ($log -replace '\.csv$', '.1.csv') -Force
        }
        $id = $SessionId
        if ($id.Length -gt 8) { $id = $id.Substring(0, 8) }
        $line = '{0},{1},{2},{3},{4},{5}' -f (Get-Date).ToString('o'), $id, $Ctx, $Tier, $Gear, $Action
        # One append, header included, instead of Test-Path plus two Add-Content
        # calls: this runs inside a blocking hook, and Add-Content costs ~17 ms a
        # call on Windows PowerShell. AppendAllText is ~1 ms.
        $enc = New-Object System.Text.UTF8Encoding($false)
        if (Test-Path -LiteralPath $log) {
            [System.IO.File]::AppendAllText($log, $line + "`r`n", $enc)
        } else {
            [System.IO.File]::AppendAllText($log, "time,session,ctx,tier,gear,action`r`n" + $line + "`r`n", $enc)
        }
    } catch { }
}

