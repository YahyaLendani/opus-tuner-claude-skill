# Design decisions

Short records of the choices that shaped the bundle, and what they cost. They are
here so a future change can argue with the reasoning instead of rediscovering it.

## 1. Optimise context, not response length

**Context.** In a measured workload, cache reads were 98.7% of tokens and 78% of
API-equivalent cost; output was 0.3% of tokens. Asking the model to "be concise"
barely moves the bill.

**Decision.** Every feature targets context size or turn count. There is no
prompt-level "be brief" instruction beyond the `CLAUDE.md` block, and no output
token cap.

**Consequence.** The largest lever is wrapping earlier. Features that save a few
hundred tokens per turn are not worth their complexity.

## 2. Tiers escalate only

**Context.** `UserPromptSubmit` also fires for subagent reports and scheduled
tasks. A classifier that could downgrade would knock a deep session back to the
routine ceiling after one innocuous prompt.

**Decision.** The tier only moves up during a session. A reset happens only at
`SessionStart`, where there is no prompt cache to invalidate.

**Consequence.** A wrongly-escalated session carries the deep ceiling until it
ends. That is the cheaper failure: deep only removes a warning, it does not
change the model or spend anything by itself.

## 3. Test grace before the ceiling

**Context.** The grace band exists so a task that is 5k from done is not cut off
at the line. The first implementation tested the ceiling first, which returned
early and made grace unreachable dead code.

**Decision.** Both `route.ps1` and `stop.ps1` check the grace band before the
ceiling. Order is part of the contract, and the self-test asserts it.

**Consequence.** A session between `routineTokens` and `+graceTokens` steps up to
deep instead of being asked to wrap. Beyond the band, the ceiling wins.

## 4. Hard wrap once, and never clear the session

**Context.** A banner is easy to ignore; a session that runs to 900k pays for it
on every subsequent request. But an unattended `/clear` would throw away work the
user may still be reading.

**Decision.** At the ceiling the `Stop` hook returns `decision: "block"` with a
reason that asks for `/wrap`. It fires at most once per crossing
(`nudged.hardWrap`), never when `stop_hook_active` is set, and Claude Code's
eight-continuation cap is a second backstop. Hooks cannot invoke slash commands,
so `/clear` stays a human action.

**Consequence.** The ceiling is a gate, not a wall. A model that ignores the
reason can still finish; it just cannot do so silently. `hardWrap: false` restores
banner-only behaviour.

## 5. Handoff instead of compaction

**Context.** `/compact` pays a full read of the context to produce a summary, and
the summary is then re-read on every later request.

**Decision.** `/wrap` writes a brief from transcript facts, then the user runs
`/clear`. A new session starts at roughly 500 tokens.

**Consequence.** A boundary costs one extra human action. In exchange the new
context is small and the old one is gone, which is the point.

## 6. Never switch the model mid-session

**Context.** The prompt cache is keyed per model. Switching forces a full context
re-write at 1.25× input price; at 150k that costs more than several cached
requests.

**Decision.** Model choice belongs at a session boundary or in a subagent, whose
context starts small. The bundle never changes `model` or persisted effort during
a session.

**Consequence.** Breadth work goes to a subagent rather than to a cheaper main
model. That is also better for the main thread: tool output stays out of it.

## 7. Per-model effort, not a global default

**Context.** A top-level `effortLevel` does not apply to Opus 5.5; the per-model
`modelSettings` entry does. A global setting silently did nothing.

**Decision.** Set `modelSettings["claude-opus-5-5"].effortLevel`. A gear's
`effort:` frontmatter applies to that turn only.

**Consequence.** Effort is predictable across sessions and can still be lowered
for one mechanical turn without persisting.

## 8. Hooks fail open

**Context.** A hook runs on the critical path of every prompt. An exception that
propagates can strand a session or block a tool call.

**Decision.** Every hook body is wrapped in `try { } catch { }` and ends with
`exit 0`. The only intentional block is the hard wrap.

**Consequence.** Bugs can be silent. The self-test asserts output shape and
content rather than relying on exit codes.

## 9. Log decisions, not prompts

**Context.** The end effect of the tuner is only visible in cost, weeks later.
Without instrumentation, "the gears fired 40 times and none paid" is unanswerable.

**Decision.** One CSV row per decision — tier change, gear change, ceiling
crossing — with the context size at that moment. Rotates at 1 MB.

**Consequence.** The log answers whether a threshold is calibrated. It does not
answer whether a specific prompt was classified well; that needs the transcript.

## 10. Windows PowerShell 5.1, no dependencies

**Context.** Hooks pay process startup on every prompt. On the development
machine, 5.1 starts faster than `pwsh` 7, and 5.1 is already installed on every
supported Windows box.

**Decision.** Target 5.1, use only the standard library, and do not add a build
step. Keep the scripts parseable by both so `pwsh` remains an option.

**Consequence.** No Pester, no modules, no package manager. The test suites are
plain PowerShell and run in CI on `windows-latest`.
