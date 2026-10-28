---
name: opus-tuner
description: Token-budget discipline for long sessions - context size, session limits, compaction, handoff, tier and gear routing.
---

# opus-tuner

Cost in this setup is **context size x number of turns**, not verbosity. Output is
under 1% of tokens. On a measured session, cache read was 98.7% of tokens and 78% of
the API-equivalent price; cache write 10%; output 12%.

So the rules below are about *how much gets re-read* and *how many turns pay for it*.

## The five rules

1. **Batch independent tool calls.** Every turn re-reads the whole context. Four
   greps in one message cost one context read; four separate messages cost four.
   This is the largest lever available inside a turn.
2. **Grep before read, and bound every read.** `Read` with no `limit`, or above 400
   lines, only when you are certain. Otherwise `offset`/`limit`, or search first.
   Never recursive-scan a repo to find one symbol.
3. **Never trade verification for tokens.** A "saving" that causes rework is a loss:
   one wrong turn at 150k costs more than ten careful greps.
4. **Delegate breadth, not judgement.** Exploration, mechanical multi-file edits and
   test runs go to a Sonnet subagent (`scout`, `hand`). Its context is discarded when
   it returns; yours is re-read every turn.
5. **Wrap at a boundary, not mid-task.** `/wrap` writes the brief, then `/clear`
   gives a fresh ~500-token context. That is cheaper than `/compact`, which pays a
   full read of the context to summarize it.

## Tiers

| Tier | Ceiling | Use |
|---|---|---|
| routine | 150k | default |
| deep | 250k | refactors, hard debugging, architecture |

The tier escalates automatically on prompt vocabulary, a repair loop (2+ consecutive
failures), breadth (6+ files edited), plan mode, or crossing the routine ceiling while
still inside the 25k grace band. It never auto-downgrades mid-session; a reset happens
only at session start.

At the ceiling the Stop hook **blocks once** and refuses to end the turn until the brief
exists, so the ceiling is a gate rather than a suggestion. It fires once per crossing:
if the model ignores it, the next stop is allowed and only a banner is shown.

Ask with `ctx.ps1`:

```
powershell -NoProfile -File "$env:USERPROFILE\.claude\skills\opus-tuner\scripts\ctx.ps1"
```

If `CLAUDE_CONFIG_DIR` is set, substitute it for `~/.claude` in that path.

## Gears

Session default is **high** and needs no skill. A gear costs one extra request, so
the router only asks for one when it pays for itself.

| Gear | When |
|---|---|
| `gear-low` | mechanical, bulk, and context already large |
| `gear-medium` | light edits, docs |
| *(high)* | default |
| `gear-xhigh` | hard reasoning, or a failed attempt |
| `gear-max` | a wrong answer costs more than a full turn; capped per session |

If the router injects `[tuner] gear=X`, invoke `/gear-X` as your first action.

## What not to do

- Do not `/compact` at a task boundary; use `/wrap` + `/clear`.
- Do not switch the main-thread model mid-session. It invalidates the prompt cache.
- Do not read a large file "to get context". Grep for the symbol.
- Do not restate the plan back to the user before acting on a mechanical turn.

Full tactics: `references/playbook.md`.
