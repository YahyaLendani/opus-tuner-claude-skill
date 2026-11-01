# Print one session's context size. Reads only the tail of its transcript.
#   powershell -NoProfile -File ctx.ps1 -SessionId <id>        # human line
#   powershell -NoProfile -File ctx.ps1 -Transcript <path>     # that file
#   powershell -NoProfile -File ctx.ps1 -SessionId <id> -Json  # machine readable
#
# Without either, it uses the id Claude Code exports to its shell tools. When the
# session cannot be identified it says so and exits 1 rather than reporting the
# most recently touched transcript, which may be another project's.

param(
    [string]$Transcript = '',
    [string]$SessionId = '',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

function Stop-Ctx {
    param([string]$Why)
    if ($Json) { Write-HookJson @{ context = $null; error = $Why } }
    else { "ctx unknown: $Why" }
    exit 1
}

try {
    $cfg = Get-TunerConfig
    $sid = Resolve-SessionId $SessionId
    if ($sid -and -not (Test-SessionId $sid)) { Stop-Ctx 'that session id is not valid.' }
    if ($Transcript -and -not $sid) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($Transcript)
        if (Test-SessionId $base) { $sid = $base }
    } elseif (-not $sid) {
        Stop-Ctx 'the session is not identified. Pass -SessionId or -Transcript.'
    }
    if ($SessionId -or -not $Transcript) {
        $resolved = Resolve-SessionTranscript -SessionId $sid -Transcript $Transcript
        if (-not $resolved['ok']) { Stop-Ctx $resolved['error'] }
        $Transcript = $resolved['transcript']
    } elseif (-not (Test-Path -LiteralPath $Transcript)) {
        Stop-Ctx "transcript not found: $Transcript"
    }

    $info = Get-ContextInfo -TranscriptPath $Transcript
    $tier = 'routine'
    if ($sid) { $tier = [string](Read-State $sid)['tier'] }
    $ceiling = Get-Ceiling $cfg $tier
    $pct = 0
    if ($ceiling -gt 0) { $pct = [Math]::Round(100.0 * $info.ctx / $ceiling) }

    if ($Json) {
        Write-HookJson @{
            context    = [int64]$info.ctx
            tier       = $tier
            ceiling    = [int64]$ceiling
            percent    = $pct
            model      = $info.model
            transcript = $Transcript
            session    = $sid
        }
    } else {
        $modelNote = if ([string]::IsNullOrWhiteSpace($info.model)) { 'model=unknown (no assistant message yet)' } else { "model=$($info.model)" }
        "ctx {0} / {1} ({2}%)  tier={3}  {4}" -f (Format-Tokens $info.ctx), (Format-Tokens $ceiling), $pct, $tier, $modelNote
    }
} catch {
    Stop-Ctx $_.Exception.Message
}
exit 0
