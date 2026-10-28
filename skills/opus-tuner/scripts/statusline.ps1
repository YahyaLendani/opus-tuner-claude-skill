# Status line: live context, tier, effort, and rate-limit windows.
# Runs on every assistant message, so it does no transcript parsing: the status
# line JSON already carries context_window, effort, and rate_limits.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$esc = [char]27
$dim = "$esc[2m"; $grn = "$esc[32m"; $yel = "$esc[33m"; $red = "$esc[31m"; $cyn = "$esc[36m"; $rst = "$esc[0m"

try {
    $in = Get-HookInput
    if (-not ($in -is [System.Collections.IDictionary]) -or $in.Count -eq 0) { Write-Output 'tuner: no input'; exit 0 }

    $cfg = Get-TunerConfig
    $state = Read-State ([string]$in['session_id'])
    $tier = [string]$state['tier']
    if ($tier -ne 'deep') { $tier = 'routine' }
    $ceiling = Get-Ceiling $cfg $tier

    $model = 'opus'
    if ($in['model'] -is [System.Collections.IDictionary] -and $in['model']['display_name']) {
        $model = [string]$in['model']['display_name']
    }

    $ctx = [int64]0
    if ($in['context_window'] -is [System.Collections.IDictionary]) {
        $t = $in['context_window']['total_input_tokens']
        if ($t) { $ctx = [int64]$t }
    }

    $effort = ''
    if ($in['effort'] -is [System.Collections.IDictionary] -and $in['effort']['level']) {
        $effort = [string]$in['effort']['level']
    }

    $pct = 0
    if ($ceiling -gt 0) { $pct = [Math]::Min(100, [int][Math]::Round(100.0 * $ctx / $ceiling)) }

    $bar = ''
    $width = 10
    $filled = [int][Math]::Floor($pct * $width / 100)
    if ($filled -gt $width) { $filled = $width }
    $bar = ('#' * $filled) + ('.' * ($width - $filled))

    $color = $grn
    if ($pct -ge 90) { $color = $red } elseif ($pct -ge 70) { $color = $yel }

    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add("$cyn$model$rst")
    if ($effort) { [void]$parts.Add("$dim$effort$rst") }
    [void]$parts.Add("$color[$bar]$rst $(Format-Tokens $ctx)/$(Format-Tokens $ceiling) $pct%")
    [void]$parts.Add("$dim$tier$rst")

    if ($in['rate_limits'] -is [System.Collections.IDictionary]) {
        $rl = $in['rate_limits']
        if ($rl['five_hour'] -is [System.Collections.IDictionary] -and $null -ne $rl['five_hour']['used_percentage']) {
            [void]$parts.Add(("5h {0:0}%" -f [double]$rl['five_hour']['used_percentage']))
        }
        if ($rl['seven_day'] -is [System.Collections.IDictionary] -and $null -ne $rl['seven_day']['used_percentage']) {
            [void]$parts.Add(("7d {0:0}%" -f [double]$rl['seven_day']['used_percentage']))
        }
    }

    Write-Output ($parts -join " $dim|$rst ")

    if ($pct -ge 100) {
        Write-Output "$red-> ceiling reached: /wrap then /clear$rst"
    } elseif ($pct -ge 70) {
        Write-Output "$yel-> finish this unit, then /wrap$rst"
    }
} catch { }
exit 0
