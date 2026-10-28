# opus-tuner playbook

Detailed tactics. Load only when the summary in `SKILL.md` is not enough.

## Why model switching mid-session loses

The prompt cache is keyed per model. Switching forces a full context re-write at
1.25x input price. At a 150k context on Opus (list prices at the time of writing:
input $15/M, output $75/M, cache read $1.50/M, cache write $18.75/M — edit the
table in `audit.ps1` if they change):

| Action | Cost |
|---|---|
| stay on Opus, one request | 150k x $1.50/M = $0.225 |
| switch to Sonnet (one cache write) | 150k x $3.75/M = $0.56 |
| each Sonnet request after | 150k x $0.30/M = $0.045 |
| break-even, one way | ~4 requests |
| break-even, there and back | ~19 requests |

So the rule is: choose the model at a **session boundary**, never per prompt. The
two free places to change it are the handoff (`/clear` starts with no cache to
invalidate) and a **subagent**, whose context starts small.

## Why subagents win

Ten requests of grunt work at a 150k main context costs 10 x $0.225 = $2.25.
The same work in a Sonnet subagent with a 10k context costs roughly $0.07. That is
about 30x cheaper, and it keeps the tool junk out of the main thread.

Delegate when the work is *broad*: locate files, read many files, run a suite,
apply a fully-specified mechanical change. Do not delegate judgement.

## Why effort is not a straight cost lever

Effort changes thinking tokens, which are billed as output. Once the context is
capped, the thinking share of price grows relative to cache reads, so the gear
matters more than it does in a long, uncapped session.

Two rules keep it honest:

- **Downshift** only when the turn is mechanical *and* the context is already large
  enough that the extra routing request is cheap relative to the thinking saved.
- **Upshift** when a wrong answer would cost a full turn. `max` must buy back at
  least one turn; otherwise `high` is cheaper.

## Tool-output discipline

| Instead of | Do |
|---|---|
| `Read` a 2,000-line file | `Grep` the symbol, then `Read` with `offset`/`limit` |
| `Get-ChildItem -Recurse` | `Glob` with a specific pattern |
| Full `git diff` on a big change | `git diff --stat`, then the specific file |
| Re-reading a file you just edited | Trust the edit result |
| Pasting a whole failing log | The last 20 lines, or the first error |

## Wrap timing

Wrap when:

- the current unit of work is finished,
- the context is past ~70% of the tier ceiling,
- or the next step is a different task.

Do not wrap mid-edit. The brief cannot capture a half-applied change as well as the
conversation can.

## Reading the audit

```
powershell -NoProfile -File "$env:USERPROFILE\.claude\skills\opus-tuner\scripts\audit.ps1" -Recent 20
```

If `CLAUDE_CONFIG_DIR` is set, substitute it for `~/.claude` in that path.

Watch three numbers, in this order:

1. **PeakCtxK** — should fall toward the tier ceiling.
2. **CacheReadM** — should fall roughly in proportion to context.
3. **CostUSD per request** — falls last, because cache write and output do not scale
   with context the way cache read does.

If peak context falls but cost per request does not, the session is simply doing more
work per turn; that is the intended trade.
