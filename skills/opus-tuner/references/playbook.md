# opus-tuner playbook

Detailed tactics. Load only when the summary in `SKILL.md` is not enough.

## Why the model stays fixed mid-session

The prompt cache is keyed per model. A switch writes the whole context to the new
model's cache at its cache-write rate, and only later requests read it at the
cache-read rate. Whether that repays depends on the two models and how many requests
follow; `references/pricing.json` has the rates to work it out.

So the rule is: choose the model at a **session boundary**, never per prompt. The
two places with no cache to lose are the handoff (`/clear` starts fresh) and a
**subagent**, whose context starts small.

## What subagents change

Grunt work in the main thread re-reads the whole main context on every request. A
subagent's requests read only its own context, and its tool output stays out of the
main thread. The price is its report in your context, and rework if the report is
wrong.

Delegate when the work is *broad*: locate files, read many files, run a suite,
apply a fully-specified mechanical change. Do not delegate judgement.

## Why effort is not a straight cost lever

Effort changes thinking tokens, which are billed as output. How much that matters
depends on how large output is next to cache reads in the session.

Two rules keep it honest:

- **Downshift** only when the turn is mechanical *and* the context is already large
  enough that the extra routing request is small next to the thinking saved.
- **Upshift** when a wrong answer would cost a full turn. If `max` would not avoid
  at least one turn, stay on `high`.

## Tool-output discipline

| Instead of | Do |
|---|---|
| `Read` a 2,000-line file | `Grep` the symbol, then `Read` with `offset`/`limit` |
| `Get-ChildItem -Recurse` | `Glob` with a specific pattern |
| Full `git diff` on a big change | `git diff --stat`, then the specific file |
| Re-reading a file you just edited | Trust the edit result |
| Pasting a whole failing log | The last 20 lines, or the first error |

## Handoff timing

Offer a handoff when:

- the current unit of work is finished,
- the context is past ~70% of the tier ceiling and the user wants to keep going,
- or the next step is a different task.

Do not hand off mid-edit. The brief cannot capture a half-applied change as well as
the conversation can. The user decides whether to continue in a fresh session, and
running `/clear` is their step.

A fresh session starts without the history, so it re-reads less, but it has to
rebuild whatever the handoff leaves out. Write the handoff for that reader.

## Reading the audit

```
# Windows
powershell -NoProfile -File "$env:USERPROFILE\.claude\skills\opus-tuner\scripts\audit.ps1" -Recent 20

# macOS / Linux
pwsh -NoProfile -File "$HOME/.claude/skills/opus-tuner/scripts/audit.ps1" -Recent 20
```

If `CLAUDE_CONFIG_DIR` is set, substitute it for `~/.claude` in that path.

Three numbers, in this order:

1. **PeakCtxK**: how large sessions get.
2. **CacheReadM**: how much of that was re-read.
3. **CostUSD**: an API-equivalent estimate per request, not a bill or a subscription
   limit.

If peak context falls but the estimate per request does not, the session is doing
more work per turn.
