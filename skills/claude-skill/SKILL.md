---
name: claude-skill
description: Portable token discipline for long conversations where hooks cannot run - Claude Desktop, claude.ai, or a locked-down machine. Use when a chat is getting long, when the user mentions context limits or cost, or when resuming from a handoff brief.
---

# claude-skill — portable token discipline

This is the advisory companion to opus-tuner. It needs no hooks, no scripts and no
filesystem: everything here is a habit the model can keep in any Claude client.
Where opus-tuner measures and enforces, this only reminds. Say so if the user
expects the automated version.

## The budget

Track the conversation against two soft ceilings:

| Tier | Ceiling | Meaning |
|---|---|---|
| routine | ~150k tokens | default; most work fits |
| deep | ~250k tokens | one hard problem, explicitly chosen |

At **70% of the ceiling**, finish the current unit and hand off. At the ceiling,
stop starting new work. A turn near the ceiling re-reads everything, so the last
10% of a long chat is the most expensive part of it.

## What actually costs tokens

Every request re-reads the whole conversation. That makes these the levers, in
order:

1. **Conversation length.** The dominant cost. A 300k chat costs roughly six
   times a 50k chat per turn, for the same answer.
2. **Output.** Small share of tokens, large share of price. Do not pad.
3. **Restating.** Repeating the plan, the diff, or the user's request back to
   them buys nothing and is re-read on every later turn.

## Rules

- **Answer the question asked.** No preamble, no summary of what you are about
  to do, no recap of what you just did unless it changed the plan.
- **Read narrowly.** Ask for the file, function, or error — not the repository.
  If you have tools, grep for the symbol before reading a whole file.
- **Batch.** One message with the independent questions, not five round trips.
- **Do not re-verify by re-reading.** If a fact is in the conversation, use it.
  Verification is for claims that could be wrong, not for memory.
- **Do not re-explain for the user's benefit.** They can scroll.
- **Never trade verification for tokens.** Skipping a test to save context is
  how a cheap session becomes an expensive debugging session.

## When to hand off

At a task boundary, or at 70% of the ceiling, whichever comes first. A handoff
is cheaper than compaction: compaction pays a full read to write a summary, and
that summary is then re-read on every later request.

Offer this, in one line, and let the user decide:

> This chat is long enough that the next turns get expensive. I can write a
> handoff brief for a fresh chat — say the word.

## Handoff brief

When asked, write exactly this, under ~400 words. Every line is re-read in the
new chat, so no filler:

```markdown
# Handoff — <task>

## Goal
<one sentence: what done looks like>

## State
<what exists now: files, decisions, what passes>

## Decisions
<what was chosen and why — only the non-obvious ones>

## Dead ends
<what was tried and failed, so it is not retried>

## Unverified
<believed but not proven>

## Next step
<one concrete action>

## Files
<the handful that matter, with paths>
```

Then tell the user: **start a new chat, paste this, and say "continue from Next
step"**. In a client with projects or memory, put it in the project instructions
instead of the first message.

## Resuming

When a message begins with a handoff brief:

1. Treat it as the working state. Do not re-explore what it already records.
2. Start from **Next step**.
3. Ask one question only if a decision it records is genuinely ambiguous.

## Limits, stated honestly

- No measurement: you cannot see the real token count, only estimate it.
- No enforcement: nothing stops a turn at the ceiling.
- No automatic re-seed: the user pastes the brief.

For measurement and enforcement, use opus-tuner in Claude Code:
<https://github.com/YahyaLendani/opus-tuner>
