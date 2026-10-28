# Print the current context size. Reads only the tail of the transcript.
#   powershell -NoProfile -File ctx.ps1            # human line
#   powershell -NoProfile -File ctx.ps1 -Json      # machine readable

param(
    [string]$Transcript = '',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

try {
    $cfg = Get-TunerConfig
    if ([string]::IsNullOrWhiteSpace($Transcript)) { $Transcript = Get-NewestTranscript }
    $info = Get-ContextInfo -TranscriptPath $Transcript
    $statePath = Get-ChildItem -LiteralPath $script:TunerState -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $tier = 'routine'
    if ($statePath) {
        try {
            $s = ConvertTo-Hashtable (Get-Content -LiteralPath $statePath.FullName -Raw | ConvertFrom-Json)
            if ($s -is [System.Collections.IDictionary] -and $s.Contains('tier')) { $tier = [string]$s['tier'] }
        } catch { }
    }
    $ceiling = Get-Ceiling $cfg $tier
    $pct = 0
    if ($ceiling -gt 0) { $pct = [Math]::Round(100.0 * $info.ctx / $ceiling) }

    if ($Json) {
        Write-HookJson @{
            context   = [int64]$info.ctx
            tier      = $tier
            ceiling   = [int64]$ceiling
            percent   = $pct
            model     = $info.model
            transcript = $Transcript
        }
    } else {
        $modelNote = if ([string]::IsNullOrWhiteSpace($info.model)) { 'model=unknown (no assistant message yet)' } else { "model=$($info.model)" }
        "ctx {0} / {1} ({2}%)  tier={3}  {4}" -f (Format-Tokens $info.ctx), (Format-Tokens $ceiling), $pct, $tier, $modelNote
    }
} catch {
    if (-not $Json) { "ctx unknown" }
}
exit 0
