---
name: opus-tuner
description: Token-budget discipline for long sessions - context size, session limits, compaction, handoff, tier and gear routing.
---

# opus-tuner

Every request re-reads the whole context, so these rules are about how much gets
re-read and how many requests read it.

## The five rules

1. **Batch independent tool calls.** Four greps in one message read the context
   once; four separate messages read it four times.
2. **Grep before read, and bound every read.** `Read` with no `limit`, or above 400
   lines, only when you are certain. Otherwise `offset`/`limit`, or search first.
   Never recursive-scan a repo to find one symbol.
3. **Never trade verification for tokens.** A "saving" that causes rework is a loss.
4. **Delegate breadth, not judgement.** Exploration, mechanical multi-file edits and
   test runs go to a subagent: the built-in `Explore` agent for finding code, a
   general-purpose one (Sonnet is enough) for mechanical edits and test runs. Its
   context is discarded when it returns; yours is re-read every turn.
5. **Hand off when the user asks.** Do it at a boundary, not mid-task, with `/wrap`.
   When the user wants to continue in a fresh session, prepare and verify a handoff. Ask them to run `/clear` afterward.
   Runtime hooks separately control any configured compaction interruption.

## Tiers

| Tier | Ceiling | Use |
|---|---|---|
| routine | 150k | default |
| deep | 250k | refactors, hard debugging, architecture |

The tier escalates automatically on prompt vocabulary, a repair loop (2+ consecutive
failures), breadth (6+ files edited), plan mode, or crossing the routine ceiling while
still inside the 25k grace band. It never auto-downgrades mid-session; a reset happens
only at session start.

A ceiling is a reference point, not a limit. If a hook message asks for a handoff and
work remains, follow it once with `/wrap`. If the work is done, say so.

Ask with `ctx.ps1`:

```
# Windows
powershell -NoProfile -File "$env:USERPROFILE\.claude\skills\opus-tuner\scripts\ctx.ps1"

# macOS / Linux
pwsh -NoProfile -File "$HOME/.claude/skills/opus-tuner/scripts/ctx.ps1"
```

If `CLAUDE_CONFIG_DIR` is set, substitute it for `~/.claude` in that path.

## Gears

Session default is **high** and needs no skill. A gear costs one extra request, so
the router only asks for one on a clear signal.

| Gear | When |
|---|---|
| `gear-low` | mechanical, bulk, and context already large |
| `gear-medium` | light edits, docs |
| *(high)* | default |
| `gear-xhigh` | hard reasoning, or a failed attempt |
| `gear-max` | a wrong answer would cost a full turn; capped per session |

If the router injects `[tuner] gear=X`, invoke `/gear-X` as your first action.

## What not to do

- Do not suggest switching the main-thread model mid-session. The new model starts
  without the prompt cache.
- Do not read a large file "to get context". Grep for the symbol.
- Do not restate the plan back to the user before acting on a mechanical turn.

Full tactics: `references/playbook.md`.
