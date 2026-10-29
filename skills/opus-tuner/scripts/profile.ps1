# Switch between the dev and creative profiles, or show the active one.
#
#   profile.ps1             swap dev <-> creative
#   profile.ps1 creative    set a profile by name (dev, creative)
#   profile.ps1 show        print the active profile without changing it
#
# The choice is stored as "profile" in tuner.config.json, so it persists across
# sessions and every hook picks it up on its next run. Only that one key is
# edited: the rest of the file, including its formatting, is left alone.
#
# The output is written for the model as much as for the user: the /profile
# skill runs this script, and the text it prints is what tells the model that
# the rules changed mid-session.

param([Parameter(Position = 0)][string]$Name = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

function Write-Profile {
    param($Cfg)
    $p = [string]$Cfg['profile']
    $down = if ([bool]$Cfg['downshift']) { 'on' } else { 'off' }
    Write-Output "opus-tuner profile: $p"
    Write-Output "  gear-low downshift : $down"
    Write-Output "  gear-max turns     : $([int]$Cfg['maxTurnsPerSession']) per session"
    Write-Output "  ceilings           : $(Format-Tokens $Cfg['routineTokens']) routine, $(Format-Tokens $Cfg['deepTokens']) deep"
    Write-Output "  deep tier on       : $($Cfg['deepPatterns'])"
    $note = [string]$Cfg['profileNote']
    if ($note) {
        Write-Output ''
        Write-Output 'Instruction in effect (also added at the start of every new session):'
        Write-Output $note
    } else {
        Write-Output ''
        Write-Output 'Instruction in effect: none. This profile adds nothing to the context.'
    }
}

$profiles = Get-TunerProfiles
$want = $Name.Trim().ToLowerInvariant()
if ($want -eq 'swap' -or $want -eq 'toggle') { $want = '' }
if ($want -ne '' -and $want -ne 'show' -and -not $profiles.Contains($want)) {
    Write-Output "Unknown profile '$Name'. Use: dev, creative, show, or no argument to swap."
    exit 1
}

$current = Get-TunerConfig
if ($want -eq 'show') {
    Write-Profile $current
    exit 0
}

$from = [string]$current['profile']
$target = $want
if (-not $target) { $target = if ($from -eq 'creative') { 'dev' } else { 'creative' } }

# Never overwrite a file we cannot read: a typo would be replaced by a config
# that silently drops every other setting the user had.
$path = $script:TunerConfig
$text = ''
if (Test-Path -LiteralPath $path) {
    $issue = Get-TunerConfigIssue
    if ($issue) {
        Write-Output $issue
        Write-Output 'Profile not changed.'
        exit 1
    }
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if (-not ((ConvertTo-Hashtable ($text | ConvertFrom-Json)) -is [System.Collections.IDictionary])) {
        Write-Output "$path is not a JSON object. Profile not changed."
        exit 1
    }
}

$entry = '"profile": "' + $target + '"'
$new = $null
if ([string]::IsNullOrWhiteSpace($text)) {
    $new = "{`n  $entry`n}`n"
} else {
    $rx = [regex]'"profile"\s*:\s*"[^"]*"'
    if ($rx.IsMatch($text)) {
        $new = $rx.Replace($text, $entry, 1)
    } elseif ($text -match '^\s*\{\s*\}\s*$') {
        $new = "{`n  $entry`n}`n"
    } else {
        $new = ([regex]'\{').Replace($text, "{`n  $entry,", 1)
    }
}

# Verify the edit parses and lands on the intended profile; if the targeted edit
# missed (an unusual layout), fall back to a full rewrite of the same data.
$ok = $false
try {
    $check = ConvertTo-Hashtable ($new | ConvertFrom-Json)
    $ok = ($check -is [System.Collections.IDictionary]) -and ([string]$check['profile'] -eq $target)
} catch { $ok = $false }
if (-not $ok) {
    $data = if ($text) { ConvertTo-Hashtable ($text | ConvertFrom-Json) } else { @{} }
    $data['profile'] = $target
    $new = ($data | ConvertTo-Json -Depth 10) + "`n"
}

$dir = Split-Path -Parent $path
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
[System.IO.File]::WriteAllText($path, $new, (New-Object System.Text.UTF8Encoding($false)))

$cfg = Get-TunerConfig
if ($from -eq $target) {
    Write-Output "Already on $target; nothing changed."
} else {
    Write-Output "Switched from $from to $target."
    if ($target -eq 'dev') {
        Write-Output 'The creative instruction no longer applies for the rest of this session; follow the default rules.'
    }
}
Write-Output ''
Write-Profile $cfg
exit 0
