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
        mode                  = 'assist'
        routineTokens         = 150000
        deepTokens            = 250000
        graceTokens           = 25000
        nudgeAt               = 0.7
        maxTurnsPerSession    = 2
        minCtxForDownshift    = 100000
        downshiftRequiresBulk = $true
        hardWrap              = $false
        blockManualCompact    = $false
        logDecisions          = $true
        downshift             = $true
        bigOutputTokens       = 6000
        bigOutputWarnings     = 3
        weeklyDigest          = $true
        autoTune              = $true
        profile               = 'dev'
        profileNote           = ''
        deepPatterns          = 'refactor|architect|root cause|race condition|deadlock|migrat|redesign|flaky|intermittent|memory leak|concurren|thread-safe|vulnerab|rewrite|overhaul|regression'
        # Words that also turn up in ordinary questions. On their own they do
        # not escalate: the deep tier is escalate-only, so a false positive
        # carries the 250k ceiling for the rest of the session.
        weakDeepPatterns      = 'why does|why is|why did|investigate|prove|optimi[sz]|performance'
        mechanicalPatterns    = 'rename|format|lint|prettier|eslint|typo|bump|commit|git status|run tests|run the tests|npm test|chmod|move file|copy file|list files|add header|add license'
        bulkPatterns          = '\ball\b|every|across|each file|multiple files|whole repo|whole project|codebase|batch|bulk|throughout'
    }
    $named = @{}
    if (-not $Defaults -and (Test-Path -LiteralPath $script:TunerConfig)) {
        try {
            $raw = Get-Content -LiteralPath $script:TunerConfig -Raw -Encoding UTF8
            $parsed = ConvertTo-Hashtable ($raw | ConvertFrom-Json)
            if ($parsed -is [System.Collections.IDictionary]) {
                foreach ($k in $parsed.Keys) {
                    $cfg[$k] = $parsed[$k]
                    $named[$k] = $true
                }
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
        foreach ($k in $custom[$name].Keys) {
            $cfg[$k] = $custom[$name][$k]
            $named[$k] = $true
        }
    }

    # monitor shows numbers, assist also advises, guard also fires the interruptions
    # its keys turn on. advise and enforce are the names from before 0.7, and enforce
    # also meant both interruptions, which were then on unless switched off.
    $modeName = ([string]$cfg['mode']).Trim().ToLowerInvariant()
    if ($modeName -eq 'advise') {
        $modeName = 'assist'
    } elseif ($modeName -eq 'enforce') {
        $modeName = 'guard'
        foreach ($k in @('hardWrap', 'blockManualCompact')) {
            if (-not $named.ContainsKey($k)) { $cfg[$k] = $true }
        }
    } elseif (@('off', 'monitor', 'assist', 'guard') -notcontains $modeName) {
        if ($modeName) { $cfg['modeInvalid'] = $modeName }
        $modeName = 'assist'
    }
    $cfg['mode'] = $modeName

    # An automatic switch-off from Update-AutoTune, applied last and only while
    # it lasts. It only ever turns the low gear off, never a ceiling down.
    if (-not $Defaults -and [bool]$cfg['autoTune']) {
        $auto = Read-AutoTune
        if ($auto) { $cfg['downshift'] = $false; $cfg['autoDownshiftOffUntil'] = $auto['until'] }
    }
    return $cfg
}

# Whether a one-time interruption may fire. It takes guard mode and a real JSON
# true: PowerShell would read the string "false" as true.
function Test-Interruption {
    param($Config, [string]$Key)
    return ([string]$Config['mode'] -eq 'guard' -and $Config[$Key] -is [bool] -and $Config[$Key])
}

function Get-AutoTunePath { return (Join-Path $script:TunerState 'autotune.json') }

# The active automatic override, or $null when there is none or it expired.
function Read-AutoTune {
    $p = Get-AutoTunePath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $a = ConvertTo-Hashtable (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
        $until = [datetime]::MinValue
        if ($a -is [System.Collections.IDictionary] -and [bool]$a['downshiftOff'] -and
            [datetime]::TryParse([string]$a['until'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$until) -and
            $until -gt (Get-Date)) { return $a }
    } catch { }
    return $null
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
            weakDeepPatterns   = ''
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

# Two files per session, because they have different owners. <sid>.json is control
# state: the tier, the one-time flags and the effort limit decide whether a hook
# interrupts anyone, so it only moves forward, and only under its lock.
# <sid>.diag.json holds the counters the tool hooks collect. Those hooks run async
# and can finish in any order, so a late one can lose a counter but can never
# touch control state.
$script:ControlKeys = @('tier', 'gear', 'maxUses', 'nudged', 'recovered', 'updated')
$script:DiagKeys = @('files', 'fails', 'bigWarned', 'lowFailed')
$script:NudgeFlags = @('soft', 'ceiling', 'escalated', 'hardWrap', 'compact', 'routeCeiling')

function Get-DiagPath {
    param([string]$SessionId)
    return [System.IO.Path]::ChangeExtension((Get-StatePath $SessionId), 'diag.json')
}

function New-State {
    $nudged = @{}
    foreach ($k in $script:NudgeFlags) { $nudged[$k] = $false }
    return @{
        tier    = 'routine'
        gear    = 'high'
        files   = @()
        fails   = 0
        maxUses = 0
        bigWarned = 0
        lowFailed = $false
        recovered = $false
        nudged  = $nudged
        updated = ''
    }
}

# What a damaged control file reads as. Its flags are unknowable, so assume every
# one-time interruption already fired and every limit is spent: a repeated prompt
# is the failure this file exists to prevent, and a missed one costs nothing.
function New-RecoveredState {
    $s = New-State
    $s['tier'] = 'deep'
    $s['maxUses'] = 99
    $s['recovered'] = $true
    foreach ($k in $script:NudgeFlags) { $s['nudged'][$k] = $true }
    return $s
}

# status: ok, missing, bad (not a JSON object), busy (would not open). The name
# gets a second look because a replace on Windows can hide it for an instant, and
# "missing" is what a brand new session looks like.
function Read-StateFile {
    param([string]$Path)
    $text = $null
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        if (-not [System.IO.File]::Exists($Path)) {
            if ($attempt -ge 1) { return @{ status = 'missing' } }
            Start-Sleep -Milliseconds 5
            continue
        }
        try {
            $text = Read-SharedText $Path
            break
        } catch { Start-Sleep -Milliseconds 15 }
    }
    if ($null -eq $text) { return @{ status = 'busy' } }
    try { $data = ConvertTo-Hashtable ($text | ConvertFrom-Json) } catch { return @{ status = 'bad' } }
    if (-not ($data -is [System.Collections.IDictionary])) { return @{ status = 'bad' } }
    return @{ status = 'ok'; data = $data }
}

# Fills in what an older file lacks. $null when the flags cannot be trusted. Other
# keys carry through: a session that spans the upgrade has its counters in here.
function ConvertTo-ControlState {
    param($Data)
    $s = New-State
    foreach ($k in $Data.Keys) { $s[$k] = $Data[$k] }
    if (-not ($s['nudged'] -is [System.Collections.IDictionary])) { return $null }
    $limit = 0
    if (-not [int]::TryParse([string]$s['maxUses'], [ref]$limit)) { return $null }
    foreach ($k in $script:NudgeFlags) {
        if (-not $s['nudged'].Contains($k)) { $s['nudged'][$k] = $false }
    }
    return $s
}

function Add-Diagnostics {
    param($View, [string]$SessionId)
    $d = Read-StateFile (Get-DiagPath $SessionId)
    if ($d['status'] -ne 'missing') {
        $defaults = New-State
        foreach ($k in $script:DiagKeys) {
            if ($d['status'] -eq 'ok' -and $d['data'].Contains($k)) { $View[$k] = $d['data'][$k] } else { $View[$k] = $defaults[$k] }
        }
    }
    # A counter that is not a number would make every hook reading it throw, and
    # hooks fail silently, so the session would just stop being tracked.
    foreach ($k in @('fails', 'bigWarned')) {
        $n = 0
        if (-not [int]::TryParse([string]$View[$k], [ref]$n)) { $View[$k] = 0 }
    }
}

# One session's state as a read-only view. Atomic replaces make this safe without
# the lock; changing anything goes through Update-State.
function Read-State {
    param([string]$SessionId)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return (New-State) }
    $r = Read-StateFile (Get-StatePath $SessionId)
    $view = $null
    if ($r['status'] -eq 'missing') { $view = New-State }
    elseif ($r['status'] -eq 'ok') { $view = ConvertTo-ControlState $r['data'] }
    if ($null -eq $view) { $view = New-RecoveredState }
    Add-Diagnostics $view $SessionId
    return $view
}

# Test seams, inert unless the overlap tests set OPUS_TUNER_TEST_BARRIER. They make
# the interleavings in tests/state-test.ps1 deterministic rather than a matter of
# timing: 'waiting' reports a contended lock, and the barrier parks an update
# between its read and its write.
function Set-TestSignal {
    param([string]$Name)
    if ($env:OPUS_TUNER_TEST_BARRIER) { [System.IO.File]::WriteAllText("$($env:OPUS_TUNER_TEST_BARRIER).$Name", '') }
}

function Wait-TestBarrier {
    if (-not $env:OPUS_TUNER_TEST_BARRIER) { return }
    Set-TestSignal 'reached'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not [System.IO.File]::Exists("$($env:OPUS_TUNER_TEST_BARRIER).go") -and $sw.ElapsedMilliseconds -lt 15000) {
        Start-Sleep -Milliseconds 10
    }
}

# An exclusive handle on a lock file, or $null after the timeout. The OS releases
# it when the holder dies, so a crashed hook cannot wedge a session. The file stays
# after use: deleting it would let two processes each hold "the" lock.
function Enter-StateLock {
    param([string]$Path, [int]$TimeoutMs = 2000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $signalled = $false
    while ($true) {
        try {
            return (New-Object System.IO.FileStream($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None))
        } catch {
            if (-not $signalled) {
                Set-TestSignal 'waiting'
                $signalled = $true
            }
            if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { return $null }
            Start-Sleep -Milliseconds 15
        }
    }
}

# Comparable text for one file's worth of keys, to skip writes that change nothing.
function Get-StateSnapshot {
    param($State, [string[]]$Keys)
    $o = [ordered]@{}
    foreach ($k in $Keys) {
        if ($k -eq 'updated') { continue }
        $v = $State[$k]
        if ($v -is [System.Collections.IDictionary]) {
            $n = [ordered]@{}
            foreach ($x in @($v.Keys | Sort-Object)) { $n[$x] = $v[$x] }
            $v = $n
        }
        $o[$k] = $v
    }
    return ($o | ConvertTo-Json -Depth 6 -Compress)
}

# The whole read-modify-write of one file, under that file's lock. $Action receives
# the merged view and changes it in place; only the keys this file owns are saved.
# Returns $true when the result is safely on disk. On $false nothing may be
# announced as done: there was no session, no lock or no write, and a caller that
# interrupted anyway could do so again next time.
#
# Scriptblocks see their caller's variables by name, so the st prefix below keeps
# these locals from shadowing what an $Action reads.
function Update-State {
    param([string]$SessionId, [scriptblock]$Action, [switch]$Diagnostics)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $false }
    $stFile = if ($Diagnostics) { Get-DiagPath $SessionId } else { Get-StatePath $SessionId }
    $stLock = Enter-StateLock ([System.IO.Path]::ChangeExtension($stFile, 'lock'))
    if (-not $stLock) { return $false }

    $stSaved = $false
    $stRecovered = $false
    try {
        if ($Diagnostics) {
            $stKeys = $script:DiagKeys
            $stOut = @{}
            $stView = Read-State $SessionId
        } else {
            $stKeys = $script:ControlKeys
            $stOut = @{}
            $stRead = Read-StateFile $stFile
            if ($stRead['status'] -eq 'busy') { return $false }
            $stView = $null
            if ($stRead['status'] -eq 'missing') { $stView = New-State }
            elseif ($stRead['status'] -eq 'ok') {
                $stView = ConvertTo-ControlState $stRead['data']
                foreach ($k in $stRead['data'].Keys) { $stOut[$k] = $stRead['data'][$k] }
            }
            if ($null -eq $stView) {
                $stView = New-RecoveredState
                $stRecovered = $true
            }
            Add-Diagnostics $stView $SessionId
        }

        $stBefore = Get-StateSnapshot $stView $stKeys
        $stDeep = ([string]$stView['tier'] -eq 'deep')
        $stMax = [int]$stView['maxUses']
        $stFlags = @{}
        foreach ($k in $script:NudgeFlags) { $stFlags[$k] = [bool]$stView['nudged'][$k] }

        $null = & $Action $stView

        # Control state only moves forward. Reset-State is the one way back.
        if ($stDeep) { $stView['tier'] = 'deep' }
        if ([int]$stView['maxUses'] -lt $stMax) { $stView['maxUses'] = $stMax }
        foreach ($k in $script:NudgeFlags) {
            if ($stFlags[$k]) { $stView['nudged'][$k] = $true }
        }

        Wait-TestBarrier

        if (-not $stRecovered -and (Get-StateSnapshot $stView $stKeys) -ceq $stBefore) {
            $stSaved = $true
        } else {
            foreach ($k in $stKeys) { $stOut[$k] = $stView[$k] }
            if (-not $Diagnostics) { $stOut['updated'] = (Get-Date).ToString('o') }
            $stSaved = Write-AtomicText $stFile ($stOut | ConvertTo-Json -Depth 8 -Compress)
        }
    } finally { $stLock.Dispose() }

    if ($stRecovered -and $stSaved) { Write-Decision (Get-TunerConfig) $SessionId 0 'deep' 'high' 'state-recovered' }
    return $stSaved
}

# A session start is the one thing allowed to move control state back. A compaction
# is the same session with a smaller context, so -KeepLimits keeps the once-per-session
# limits: otherwise the manual /compact refusal and the gear-max ration would re-arm.
function Reset-State {
    param([string]$SessionId, [switch]$KeepLimits)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $false }
    $file = Get-StatePath $SessionId
    $lock = Enter-StateLock ([System.IO.Path]::ChangeExtension($file, 'lock'))
    if (-not $lock) { return $false }
    try {
        $fresh = New-State
        if ($KeepLimits) {
            $read = Read-StateFile $file
            $old = $null
            if ($read['status'] -eq 'missing') { $old = New-State }
            elseif ($read['status'] -eq 'ok') { $old = ConvertTo-ControlState $read['data'] }
            if ($null -eq $old) { $old = New-RecoveredState }
            $fresh['maxUses'] = [int]$old['maxUses']
            $fresh['recovered'] = [bool]$old['recovered']
            $fresh['nudged']['compact'] = [bool]$old['nudged']['compact']
        }
        $out = @{}
        foreach ($k in $script:ControlKeys) { $out[$k] = $fresh[$k] }
        $out['updated'] = (Get-Date).ToString('o')
        if (-not (Write-AtomicText $file ($out | ConvertTo-Json -Depth 8 -Compress))) { return $false }
    } finally { $lock.Dispose() }

    $diag = Get-DiagPath $SessionId
    $diagLock = Enter-StateLock ([System.IO.Path]::ChangeExtension($diag, 'lock'))
    if ($diagLock) {
        try {
            if ([System.IO.File]::Exists($diag)) { [System.IO.File]::Delete($diag) }
        } catch { } finally { $diagLock.Dispose() }
    }
    return $true
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

# A reader that never stands in the way of an atomic replace: a writer swapping
# the file in only needs Delete sharing from everyone holding it open.
function Read-SharedText {
    param([string]$Path)
    $share = [System.IO.FileShare]'ReadWrite,Delete'
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        return $reader.ReadToEnd()
    } finally { $fs.Dispose() }
}

# Temp file in the same directory, flushed to disk, then swapped in. A crash at
# any point leaves either the old file or the new one, never half of either. The
# swap retries because on Windows a scanner or indexer can hold the target for a
# moment. Returns $false when the swap never succeeded.
function Write-AtomicText {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Path.$PID.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    try {
        $fs = New-Object System.IO.FileStream($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush($true)
        } finally { $fs.Dispose() }
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            try {
                if ([System.IO.File]::Exists($Path)) {
                    [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
                } else {
                    [System.IO.File]::Move($tmp, $Path)
                }
                return $true
            } catch {
                Start-Sleep -Milliseconds (10 + 5 * $attempt)
            }
        }
        return $false
    } finally {
        if ([System.IO.File]::Exists($tmp)) { try { [System.IO.File]::Delete($tmp) } catch { } }
    }
}

# Masks credentials before text is saved or injected. Deliberately eager: a
# masked word in a handoff costs a re-read, a leaked key costs a rotation. The
# word "tokens" stays readable, because this bundle talks about it constantly.
function Protect-Sensitive {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $t = $Text
    $t = [regex]::Replace($t, '-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|\z)', '[REDACTED:private-key]')
    $t = [regex]::Replace($t, '\b([a-zA-Z][a-zA-Z0-9+.-]*://)[^/\s:@''"]+:[^/\s@''"]+@', '$1[REDACTED]@')
    $t = [regex]::Replace($t, '(?i)\b((?:proxy-)?authorization)(["'']?\s*[:=]\s*["'']?)(?:(?:bearer|basic|token|digest)\s+)?[^\s"'',;]+', '$1$2[REDACTED]')
    $t = [regex]::Replace($t, '(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{8,}', '$1 [REDACTED]')
    $secretWords = 'password|passwd|pwd|passphrase|secret|token(?!s\b)|api[_-]?key|access[_-]?key|private[_-]?key|session[_-]?key|credential'
    $t = [regex]::Replace($t, '(?i)(?<![a-z0-9-])(--?[a-z0-9-]*(?:' + $secretWords + ')[a-z0-9-]*)(=|\s+)("[^"]*"|''[^'']*''|\S+)', '$1$2[REDACTED]')
    $t = [regex]::Replace($t, '(?i)(\b[a-z0-9_.-]*(?:' + $secretWords + ')[a-z0-9_.-]*["'']?)(\s*[:=]\s*)("[^"]*"|''[^'']*''|[^\s,;&''"]+)', '$1$2[REDACTED]')
    foreach ($shape in @(
        '\bsk-[A-Za-z0-9_-]{16,}',
        '\bgh[pousr]_[A-Za-z0-9]{20,}',
        '\bgithub_pat_[A-Za-z0-9_]{20,}',
        '\b(?:AKIA|ASIA)[A-Z0-9]{12,}\b',
        '\bxox[abeoprs]-[A-Za-z0-9-]{10,}',
        '\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}',
        '\bAIza[0-9A-Za-z_-]{30,}',
        '\bglpat-[A-Za-z0-9_-]{16,}',
        '\bnpm_[A-Za-z0-9]{30,}'
    )) {
        $t = [regex]::Replace($t, $shape, '[REDACTED]')
    }
    return $t
}

# ---------- session identity ----------
#
# Nothing may be attributed to a session on a guess. An id comes from the caller,
# or from the variable Claude Code exports to its own shell tools. A literal
# "${CLAUDE_SESSION_ID}" is a skill whose substitution did not run, not an id.
function Resolve-SessionId {
    param([string]$Explicit = '')
    $id = $Explicit
    if ($id -match '^\$\{') { $id = '' }
    if ([string]::IsNullOrWhiteSpace($id)) { $id = [string]$env:CLAUDE_CODE_SESSION_ID }
    return $id.Trim()
}

function Test-SessionId {
    param([string]$Id)
    return ($Id -cmatch '^[A-Za-z0-9_-]{1,128}$')
}

# Returns @{ ok; transcript; error }. An explicit path must belong to the session;
# otherwise only the exact file name counts, in exactly one project folder.
function Resolve-SessionTranscript {
    param([string]$SessionId, [string]$Transcript = '')
    if ($Transcript) {
        if (-not (Test-Path -LiteralPath $Transcript)) { return @{ ok = $false; error = "transcript not found: $Transcript" } }
        $own = ([System.IO.Path]::GetFileNameWithoutExtension($Transcript) -ceq $SessionId)
        if (-not $own) {
            $tail = Read-FileTail -Path $Transcript -Bytes 131072
            $own = $tail -and ($tail -match ('"sessionId"\s*:\s*"' + [regex]::Escape($SessionId) + '"'))
        }
        if (-not $own) { return @{ ok = $false; error = "transcript does not belong to session ${SessionId}: $Transcript" } }
        return @{ ok = $true; transcript = $Transcript }
    }
    $root = Join-Path $script:TunerRoot 'projects'
    $hits = @()
    if (Test-Path -LiteralPath $root) {
        $hits = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "$SessionId.jsonl" } |
            Where-Object { Test-Path -LiteralPath $_ })
    }
    if ($hits.Count -eq 0) { return @{ ok = $false; error = "no transcript for session $SessionId under $root" } }
    if ($hits.Count -gt 1) { return @{ ok = $false; error = "session $SessionId has $($hits.Count) transcripts; pass -Transcript" } }
    return @{ ok = $true; transcript = $hits[0] }
}

# Every working directory the transcript's recent records report, newest last.
function Get-TranscriptCwds {
    param([string]$Path)
    $out = New-Object System.Collections.ArrayList
    $tail = Read-FileTail -Path $Path -Bytes 524288
    if (-not $tail) { return , $out }
    foreach ($m in [regex]::Matches($tail, '"cwd"\s*:\s*("(?:[^"\\]|\\.)*")')) {
        try { $v = [string]($m.Groups[1].Value | ConvertFrom-Json) } catch { continue }
        if ($v) {
            [void]$out.Remove($v)
            [void]$out.Add($v)
        }
    }
    return , $out
}

function ConvertTo-ComparablePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path
    try { $p = [System.IO.Path]::GetFullPath($p) } catch { }
    $p = $p.TrimEnd('\', '/').Replace('\', '/')
    if ($script:OnWindows) { $p = $p.ToLowerInvariant() }
    return $p
}

function Test-SameProject {
    param([string]$A, [string]$B)
    $x = ConvertTo-ComparablePath $A
    return ($x -and $x -ceq (ConvertTo-ComparablePath $B))
}

# Same directory, or one inside the other: a session can cd within its project.
function Test-RelatedProject {
    param([string]$A, [string]$B)
    $x = ConvertTo-ComparablePath $A
    $y = ConvertTo-ComparablePath $B
    if (-not $x -or -not $y) { return $false }
    return ($x -ceq $y -or $x.StartsWith("$y/", [System.StringComparison]::Ordinal) -or $y.StartsWith("$x/", [System.StringComparison]::Ordinal))
}

# ---------- handoffs ----------
#
# One file per session, outside any repository, so a concurrent session can
# neither overwrite one nor pick it up. Required sections come first: truncating
# an oversize handoff at injection then only ever costs the derived facts.
$script:HandoffRequired = @('Task goal', 'User constraints', 'Decisions', 'Unresolved problems', 'Verification results', 'Next step')
$script:HandoffMaxChars = 6000

function Get-HandoffDir { return (Join-Path $script:TunerState 'handoffs') }

function Get-HandoffPath {
    param([string]$SessionId)
    return (Join-Path (Get-HandoffDir) "$($SessionId -replace '[^A-Za-z0-9_-]', '_').md")
}

# Returns the parsed file, or $null for anything that is not a handoff.
function Read-Handoff {
    param([string]$Path)
    try {
        $text = Read-SharedText $Path
        $m = [regex]::Match($text, '(?s)\A---\r?\n(.*?)\r?\n---\r?\n?(.*)\z')
        if (-not $m.Success) { return $null }
        $h = @{ path = $Path; body = $m.Groups[2].Value; session_id = ''; project = ''; transcript = ''; status = ''; written = '' }
        foreach ($line in ($m.Groups[1].Value -split "`r?`n")) {
            $kv = [regex]::Match($line, '^([a-z_]+):\s*(.*)$')
            if ($kv.Success) { $h[$kv.Groups[1].Value] = $kv.Groups[2].Value.Trim() }
        }
        return $h
    } catch { return $null }
}

function Get-HandoffAgeHours {
    param([string]$Path)
    return ((Get-Date) - (Get-Item -LiteralPath $Path).LastWriteTime).TotalHours
}

# The ready handoffs written in this project in the last 24 hours. An older one
# would resurrect work the project has moved past.
function Get-WaitingHandoffs {
    param([string]$Cwd)
    $out = New-Object System.Collections.ArrayList
    $dir = Get-HandoffDir
    if (-not (Test-Path -LiteralPath $dir)) { return , $out }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -ErrorAction SilentlyContinue)) {
        $h = Read-Handoff $f.FullName
        if (-not $h -or $h['status'] -ne 'ready') { continue }
        if (-not (Test-SameProject $h['project'] $Cwd)) { continue }
        if ((Get-HandoffAgeHours $f.FullName) -gt 24) { continue }
        [void]$out.Add($h)
    }
    return , $out
}

# Markers are what SessionEnd leaves behind: <sid>.claim when the session ran
# /clear, <sid>.ended whenever it ended at all.
function Set-HandoffMarker {
    param([string]$SessionId, [string]$Kind, [string]$Cwd)
    $path = [System.IO.Path]::ChangeExtension((Get-HandoffPath $SessionId), $Kind)
    $json = @{ session_id = $SessionId; cwd = $Cwd; time = (Get-Date).ToString('o') } | ConvertTo-Json -Compress
    [void](Write-AtomicText $path $json)
}

function Remove-HandoffMarkers {
    param([string]$SessionId)
    $base = Get-HandoffPath $SessionId
    foreach ($kind in @('claim', 'ended')) {
        $p = [System.IO.Path]::ChangeExtension($base, $kind)
        if (Test-Path -LiteralPath $p) { try { Remove-Item -LiteralPath $p -Force } catch { } }
    }
}

# Fresh claims for this directory whose handoff is still ready. SessionEnd runs
# moments before the matching SessionStart, so an old claim belongs to a start
# that never happened and must not be picked up by an unrelated one.
function Get-HandoffClaims {
    param([string]$Cwd, [int]$MaxAgeSeconds = 120)
    $out = New-Object System.Collections.ArrayList
    $dir = Get-HandoffDir
    if (-not (Test-Path -LiteralPath $dir)) { return , $out }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.claim' -ErrorAction SilentlyContinue)) {
        try {
            if (((Get-Date) - $f.LastWriteTime).TotalSeconds -gt $MaxAgeSeconds) { continue }
            $claim = ConvertTo-Hashtable (Read-SharedText $f.FullName | ConvertFrom-Json)
            if (-not (Test-SameProject ([string]$claim['cwd']) $Cwd)) { continue }
            $h = Read-Handoff ([System.IO.Path]::ChangeExtension($f.FullName, 'md'))
            if ($h -and $h['status'] -eq 'ready') { [void]$out.Add($h) }
        } catch { }
    }
    return , $out
}

# Whoever renames the handoff itself owns it, so racing starts cannot both inject
# it, whichever marker led them here. The copy kept for a while in case the pickup
# went wrong is scrubbed: the file may have been edited by hand since verification.
function Receive-Handoff {
    param($Handoff)
    $path = [string]$Handoff['path']
    $taken = "$path.$PID.taken"
    $moved = $false
    for ($attempt = 0; $attempt -lt 10 -and -not $moved; $attempt++) {
        if (-not [System.IO.File]::Exists($path)) { return $null }
        try {
            [System.IO.File]::Move($path, $taken)
            $moved = $true
        } catch { Start-Sleep -Milliseconds 20 }
    }
    if (-not $moved) { return $null }

    $fresh = Read-Handoff $taken
    if (-not $fresh) {
        try { [System.IO.File]::Move($taken, $path) } catch { }
        return $null
    }
    Remove-HandoffMarkers ([string]$Handoff['session_id'])
    $kept = Join-Path (Join-Path (Get-HandoffDir) 'consumed') (Split-Path -Leaf $path)
    try {
        [void](Write-AtomicText $kept (Protect-Sensitive (Read-SharedText $taken)))
        Remove-Item -LiteralPath $taken -Force
    } catch { }
    return $fresh
}

# What goes into the new session: the body, scrubbed again, because the file may
# have been edited by hand since verification.
function Get-HandoffInjection {
    param($Handoff)
    $text = Protect-Sensitive (([string]$Handoff['body']) -replace "`r`n", "`n")
    $text = $text.Trim()
    if ($text.Length -gt $script:HandoffMaxChars) {
        $cut = $text.LastIndexOf("`n", $script:HandoffMaxChars)
        if ($cut -lt 0) { $cut = $script:HandoffMaxChars }
        $text = $text.Substring(0, $cut) + "`n...[truncated]"
    }
    return $text
}

# Housekeeping for directories that otherwise only grow. Runs on fresh starts. Only
# files this bundle names: the decision log, baselines and reports are not touched.
function Remove-OldTunerFiles {
    $now = Get-Date
    if (Test-Path -LiteralPath $script:TunerState) {
        foreach ($f in @(Get-ChildItem -LiteralPath $script:TunerState -File -ErrorAction SilentlyContinue)) {
            $days = ($now - $f.LastWriteTime).TotalDays
            $old = switch -Regex ($f.Name) {
                '\.tmp$'               { $days -gt 1; break }
                '\.(lock|diag\.json)$' { $days -gt 30; break }
                default                { $false }
            }
            if ($old) { try { Remove-Item -LiteralPath $f.FullName -Force } catch { } }
        }
    }
    $dir = Get-HandoffDir
    if (-not (Test-Path -LiteralPath $dir)) { return }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue)) {
        $days = ($now - $f.LastWriteTime).TotalDays
        $old = switch -Regex ($f.Name) {
            '\.(tmp|taken)$'    { $days -gt 1; break }
            '\.(claim|ended)$'  { $days -gt 7; break }
            default             { $days -gt 30 }
        }
        if ($old) { try { Remove-Item -LiteralPath $f.FullName -Force } catch { } }
    }
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


# One line about the last 7 days of decisions, at most once per 7 days. Reads
# only the decision log (no transcripts), so it stays cheap at session start.
# Returns '' when it is not due, logging is off, or nothing happened.
function Get-WeeklyDigest {
    param($Config, [double]$CacheReadPerM = 1.50)
    try {
        if ($Config -and $Config.ContainsKey('logDecisions') -and -not [bool]$Config['logDecisions']) { return '' }
        if ($Config -and $Config.ContainsKey('weeklyDigest') -and -not [bool]$Config['weeklyDigest']) { return '' }
        $log = Join-Path $script:TunerState 'decisions.csv'
        $stampPath = Join-Path $script:TunerState 'digest.stamp'
        if (-not (Test-Path -LiteralPath $log)) { return '' }
        if ((Test-Path -LiteralPath $stampPath) -and ((Get-Date) - (Get-Item -LiteralPath $stampPath).LastWriteTime).TotalDays -lt 7) { return '' }

        $since = (Get-Date).AddDays(-7)
        $rows = @(Import-Csv -LiteralPath $log | Where-Object {
            $t = [datetime]::MinValue
            [datetime]::TryParse([string]$_.time, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$t) -and $t -ge $since
        })
        [System.IO.File]::WriteAllText($stampPath, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
        if ($rows.Count -eq 0) { return '' }

        # A gear switch is any prompt the router sent away from the default
        # gear: its own row ('gear-low'), or an escalation row that also chose one.
        $gearRows = @($rows | Where-Object { ($_.action -like 'gear-*') -or ($_.action -like 'escalate-*' -and $_.gear -and $_.gear -ne 'high') })
        $gearCost = 0.0
        foreach ($g in $gearRows) { $gearCost += ([double]$g.ctx / 1e6) * $CacheReadPerM }
        $escalations = @($rows | Where-Object { $_.action -like 'escalate-*' }).Count
        $wraps = @($rows | Where-Object { $_.action -eq 'hard-wrap' }).Count
        $compactions = @($rows | Where-Object { $_.action -eq 'compact-manual' -or $_.action -eq 'compact-auto' }).Count

        return ("opus-tuner, last 7 days: {0} gear switch(es) costing ~`${1:0.00} in extra context re-reads, {2} deep escalation(s), {3} hard wrap(s), {4} compaction(s). Full report: weekly.ps1." -f $gearRows.Count, $gearCost, $escalations, $wraps, $compactions)
    } catch { return '' }
}

# Switch the low gear off for 14 days when it keeps misfiring. Each low-gear
# turn logs 'low-ok' or 'low-failed' (a tool failure during it). With at least
# 5 such turns in the last 14 days and 40% or more failed, low effort is causing
# rework, which costs more than the gear saves, so the router stops choosing it.
# Only ever this direction: falling back to the default gear keeps the model at
# full strength. Runs at session start; returns a message for the user, or ''.
function Update-AutoTune {
    param($Config, [int]$Days = 14, [int]$MinTurns = 5, [double]$FailShare = 0.4)
    try {
        if (-not [bool]$Config['autoTune']) { return '' }
        if (Read-AutoTune) { return '' }
        $log = Join-Path $script:TunerState 'decisions.csv'
        if (-not (Test-Path -LiteralPath $log)) { return '' }
        $since = (Get-Date).AddDays(-$Days)
        $rows = @(Import-Csv -LiteralPath $log | Where-Object {
            ($_.action -eq 'low-ok' -or $_.action -eq 'low-failed') -and $(
                $t = [datetime]::MinValue
                [datetime]::TryParse([string]$_.time, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$t) -and $t -ge $since)
        })
        if ($rows.Count -lt $MinTurns) { return '' }
        $failed = @($rows | Where-Object { $_.action -eq 'low-failed' }).Count
        if (($failed / $rows.Count) -lt $FailShare) { return '' }

        $until = (Get-Date).AddDays($Days)
        $json = @{ downshiftOff = $true; until = $until.ToString('o'); reason = "$failed of $($rows.Count) low-gear turns hit a failure" } | ConvertTo-Json -Compress
        if (-not (Write-AtomicText (Get-AutoTunePath) $json)) { return '' }
        return ("opus-tuner switched the low-effort gear off until {0}: {1} of {2} low-gear turns in the last {3} days hit a failure, and rework costs more than the gear saves. Set ""autoTune"": false in tuner.config.json to keep it on." -f $until.ToString('yyyy-MM-dd'), $failed, $rows.Count, $Days)
    } catch { return '' }
}
