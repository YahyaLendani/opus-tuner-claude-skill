# Measuring

The bundle is only worth its hook latency if it does something you can measure.
`audit.ps1` reports what your transcripts recorded; run it before you tune
anything, then again later. It can show that numbers changed, not why: for a
controlled comparison of equivalent tasks, see [benchmarks/](../benchmarks/README.md).

## Capture a baseline first

```powershell
powershell -NoProfile -File skills\opus-tuner\scripts\audit.ps1 -Recent 20 -Csv baseline.csv
```

Do this **before** installing, or at least before changing a ceiling. Without a
baseline you can only tell that a number is large, not that it changed.

`-Recent 0` audits every transcript under `~/.claude/projects`; that can take a
while on a large history. `-Project <folder>` restricts it to one project.

## What it counts

One row per transcript, from the assistant records in it:

| Column | Meaning |
|---|---|
| `Requests` | distinct requests that reported usage |
| `CacheReadM` | millions of cache-read tokens |
| `CacheWrM` | millions of cache-write tokens |
| `OutputK` | thousands of output tokens (thinking included) |
| `PeakCtxK` | thousands of tokens sent on the largest main-thread request |
| `Models` | each model that served a request, with its request count |
| `CostUSD` | API-equivalent estimate, summed per request |
| `UnknownRequests` | requests whose price the table cannot give |
| `AssumedWriteTokens` | cache writes priced on an assumption (below) |
| `ModelMismatches` | requests served by a different model than requested |
| `Effort` | the effort each request's transcript record reports |
| `PricingVersion` | the table those costs came from |

`PeakCtxK` is `cache_read + cache_write + input` for the largest request. That is
the number the tier ceiling is about. Subagent requests count toward cost, but not
toward the peak, because they are not this session's context.

The CSV and `-Json` keep full precision. Only the printed table rounds.

## What the cost figure is

`CostUSD` is an **API-equivalent estimate**: what those requests would cost at list
price. It is not your bill, and it says nothing about your subscription limits. On
a subscription you do not pay per token, and Anthropic does not publish how usage
maps onto a plan's limits, so it cannot predict either one.

Each request is priced at the model that served it, so a session that mixes models
is not priced at its most-used one. The price also follows that request's cache
lifetime, prompt length where a model prices by it, fast mode, and the US inference
premium where the model has one.

Prices live in [`references/pricing.json`](../skills/opus-tuner/references/pricing.json),
which records the date and the page they were taken from. Prices change, so check
that date against the
[pricing page](https://platform.claude.com/docs/en/about-claude/pricing). To use
another table, pass `-Pricing path.json` or set `pricingFile` in the config.

Three things keep the estimate honest, and the report states each when it applies:

- **Unknown models are not guessed.** A model the table does not name gets no price,
  even if it looks like one that does, and the total is then labelled a lower bound.
  The same goes for fast mode on a model with no fast rate.
- **A missing or broken table gives no cost.** Token counts still print. It does not
  fall back to different prices, or report zero.
- **Cache writes with no breakdown are assumed to be 5-minute writes.** That is the
  cheaper rate, so the assumption can only undercount. They are counted in
  `AssumedWriteTokens`.

## How records are read

Each line is parsed as JSON, and only an assistant record's own `message.usage`
counts. So JSON spacing and field order make no difference, and neither do usage
objects nested inside it, in a `toolUseResult`, or quoted in message text.

**Repeated records count once.** One assistant message spans several transcript
lines that each repeat its usage, and a resumed session copies old lines into a
new file. Records are matched on `message.id`, then `requestId`, then `uuid`. A
copy stays with the oldest transcript in the audit. Streamed copies can differ, so
each count keeps its largest value. A replayed record is only recognised if the
original's transcript is in the audited set, so a narrow `-Recent` can count it in
the newer file.

A line that looks like usage but will not parse, such as one still being written,
is reported as unreadable and left out.

Check one session against `/cost` if you doubt a figure, keeping in mind that it is
Claude Code's own estimate and may differ.

## Reading the report

The percentage split shows where tokens went, and the cost split shows where the
estimate went. They differ because cache reads are cheap per token. Neither one
shows that a change helped: a week with harder work costs more.

For a before and after, look at:

1. **PeakCtxK**: how large sessions got, compared with your tier ceiling.
2. **CacheReadM**: tracks context size and how many requests were made.
3. **Cost per request**: also moves with model mix, cache writes and output, so
   read it alongside `Models`.

Do not read a fall in these as a saving on its own. Stopping earlier and starting a
fresh session has its own cost in writing the handoff and rebuilding context, and
that cost lands in other sessions and requests.

## What the router decided

```powershell
powershell -NoProfile -File skills\opus-tuner\scripts\stats.ps1 -Days 7
```

This is the shape of the report, with made-up numbers:

```
decisions: 34

by action:
gear-low           12  ctx avg   142k  min   101k  max   210k
escalate-prompt     9  ctx avg    48k  min    12k  max    96k
hard-wrap           2  ctx avg   253k  min   251k  max   255k
compact-auto        1  ctx avg   300k  min   300k  max   300k

requested gear -> effort Claude Code reported:
low -> low                 12
high -> high                9
```

- Many `gear-low` rows at small context: `minCtxForDownshift` is too low.
- `hard-wrap` rows are one-time Stop prompts at the ceiling, which only guard mode
  with `hardWrap` can issue. They show when a session reached it, not whether
  stopping there saved anything.
- No rows at all: the router is silent because nothing crossed a threshold, which
  is the normal case for short sessions.

The log records **decisions**, not prompts, so its row count is not a prompt
count.

**Requested and effective effort are separate columns.** `gear` is what the router
asked for by suggesting a `/gear-*` skill. `effective_effort` is what Claude Code
reported for that turn, from the hook input's `effort.level` or `CLAUDE_EFFORT`,
and is blank when it reported nothing. The log has no evidence of an effort that
was never reported, so a blank is not a failure. Rows from before this column
stay as they were.

## Comparing later

```powershell
powershell -NoProfile -File skills\opus-tuner\scripts\audit.ps1 -Recent 20 -Baseline baseline.csv
```

The report appends a before/after table: sessions, requests, cache read, median
peak context, cost, and cost per request.

1. Run the same command against the same `-Recent` window.
2. Compare `PeakCtxK` and cost per request, not raw token totals: a week with
   more work should cost more.
3. Keep the CSV. Two snapshots beat one report.

**A baseline from before 0.7 is not comparable.** It priced whole sessions at one
model's rate using out-of-date prices and counted repeated records, so its figures
run higher than today's for the same work. The report warns about this, and about a
baseline that used a different pricing version. To compare fairly across versions,
re-run the audit on the same transcripts.

## One command a week

`weekly.ps1` does the two commands above without you having to remember either
of them. It picks the newest `baseline-*.csv` in the state directory, runs
`audit.ps1 -Recent 20 -Baseline` against it, runs `stats.ps1 -Days 7`, prints the
combined report, and writes it to `state/tuner/weekly-YYYY-MM-DD.txt`.

```powershell
# Windows
powershell -NoProfile -File skills\opus-tuner\scripts\weekly.ps1
```

```sh
# macOS / Linux
pwsh -NoProfile -File skills/opus-tuner/scripts/weekly.ps1
```

`-Days 14` widens the decision window, `-Baseline path.csv` overrides the
auto-pick, and `-NoFile` prints without writing. Run it a week after the change,
not the same day, so that there are real sessions to compare.

A report that says "no decisions logged yet" is not an error — the router logs a
row only when it changes something (tier or gear), so a quiet week means the
thresholds were not crossed, not that the hooks are dead.
