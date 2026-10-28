# Measuring

The bundle is only worth its hook latency if the numbers move. `audit.ps1` is the
instrument; run it before you tune anything, then again after a week.

## Capture a baseline first

```powershell
powershell -NoProfile -File skills\opus-tuner\scripts\audit.ps1 -Recent 20 -Csv baseline.csv
```

Do this **before** installing, or at least before changing a ceiling. Without a
baseline you can only tell that a number is large, not that it changed.

`-Recent 0` audits every transcript under `~/.claude/projects`; that can take a
while on a large history. `-Project <folder>` restricts it to one project.

## What it counts

One usage block per assistant message, from the transcript:

| Column | Meaning |
|---|---|
| `Requests` | assistant messages that reported usage |
| `CacheReadM` | millions of cache-read tokens — the dominant line item |
| `CacheWrM` | millions of cache-write tokens |
| `OutputK` | thousands of output tokens (thinking included) |
| `PeakCtxK` | thousands of tokens sent on the largest request |
| `CostUSD` | API-equivalent cost at the price table in the script |

`PeakCtxK` is `cache_read + cache_write + input` for the largest request. That is
the number the tier ceiling is about. `CostUSD` is a **list-price equivalent**,
not your invoice: on a subscription plan you do not pay per token, but the same
weighting tells you where the quota goes.

Prices are hard-coded at the top of `audit.ps1` (Opus / Sonnet / Haiku, as of
2026). Edit them when they change; they are only used for the estimate.

## The trap that produced a wrong baseline

The first version of `audit.ps1` matched every `"usage"` occurrence with a
regex. A usage object nests `iterations`, which repeats the same counts, so every
figure came out exactly **2× too high** — and the error is invisible unless you
add the numbers up by hand.

The current parser reads one top-level usage block per assistant message and
sums only `input_tokens`, `cache_read_input_tokens`, and
`cache_creation_input_tokens` before the first nested object. If you write your
own audit, do the same, and sanity-check one session against `/cost`.

## Reading the report

Watch three numbers, in this order:

1. **PeakCtxK** — should fall toward the tier ceiling. This moves first.
2. **CacheReadM** — falls roughly in proportion to context.
3. **CostUSD per request** — falls last, because cache write and output do not
   scale with context the way cache read does.

If peak context falls but cost per request does not, the session is doing more
work per turn. That is the intended trade, not a failure.

The percentage split is more stable than the absolute numbers and is the part
worth comparing across machines:

```
cache read     : 98.7% of tokens
output         :  0.3% of tokens
cost split     : read 78% · write 10% · output 12%
```

That shape — from one heavy workload — is why the bundle targets context size
rather than response length. Your split will differ, but if cache read is not the
largest line, check the parser before tuning anything.

## What the router decided

```powershell
powershell -NoProfile -File skills\opus-tuner\scripts\stats.ps1 -Days 7
```

```
decisions: 34
by action:
  gear-low          12  ctx avg  142k  min  101k  max  210k
  escalate-prompt    9  ctx avg   48k  min   12k  max   96k
  hard-wrap          2  ctx avg  253k  min  251k  max  255k
  compact-auto       1  ctx avg  300k  min  300k  max  300k
```

- Many `gear-low` rows at small context: `minCtxForDownshift` is too low.
- Several `hard-wrap` rows in a day: the ceiling is being treated as a
  suggestion, or sessions are starting too large.
- No rows at all: the router is silent because nothing crossed a threshold, which
  is the normal case for short sessions.

The log records **decisions**, not prompts, so its row count is not a prompt
count.

## Comparing after a week

```powershell
powershell -NoProfile -File skills\opus-tuner\scripts\audit.ps1 -Recent 20 -Baseline baseline.csv
```

The report appends a before/after table: sessions, requests, cache read, median
peak context, cost, and cost per request.

1. Run the same command against the same `-Recent` window.
2. Compare `PeakCtxK` and `CostUSD` per request, not raw token totals: a week with
   more work should cost more.
3. Keep the CSV. Two snapshots beat one report, and the trend is the only signal
   that survives a change in what you were working on.

Only compare against a CSV written by the current parser. The first version of
`audit.ps1` double-counted every figure, so a baseline from it is exactly 2×
wrong and the deltas will be meaningless.
