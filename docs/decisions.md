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

## 11. Watch compaction, refuse only the manual one

**Context.** The bundle exists to replace compaction with a handoff, yet it had no
visibility into compaction at all: no `PreCompact` hook, so a session could
auto-compact at 300k and nothing recorded it. A tool that cannot see its own
failure mode is guessing.

**Decision.** Log every compaction with its context size, and refuse the **first**
manual `/compact` per session once, pointing at `/wrap` + `/clear`. Never block
automatic compaction.

**Consequence.** Auto-compaction stays unblocked because it can be the recovery
path for a context-limit error: refusing it there surfaces the error and fails the
request, which is worse than the compaction. `PreCompact` also discards
`systemMessage`, so a log row is the only way the event can be reported.
`blockManualCompact: false` keeps the logging without the block.

## 12. Warnings ride on systemMessage, never on context

**Context.** Two things are invisible until they are expensive: a malformed
`tuner.config.json` (silently reverts every knob to its default) and resuming a
300k session (the first request re-reads all of it). Both are easy to report and
both would cost tokens on every turn if injected as context.

**Decision.** `SessionStart` reports both through `systemMessage`, which never
enters the model's context, and combines them with the brief re-seed into a single
JSON object.

**Consequence.** The warnings are free but also invisible to the model, so they
cannot change its behaviour — only the user's. That is the right trade for a
message whose whole purpose is to inform a decision the model does not make.

## 13. `pwsh` 7 on macOS and Linux

**Context.** The bundle was Windows-only: `$env:USERPROFILE`, `'state\tuner'`
literals, `shell: "powershell"`, and `-ExecutionPolicy` in every command. Claude
Code on macOS and Linux starts command hooks with `sh`, so something has to name
an interpreter. The two options were a second implementation in bash, or one
PowerShell codebase with a runtime dependency.

**Decision.** Keep one codebase and require **PowerShell 7 (`pwsh`)** outside
Windows. Resolve the three differences — home directory, path separator,
interpreter — in `_common.ps1` and `install.ps1`, and write `pwsh -NoProfile -File
"<path>"` with `shell: "bash"` on POSIX. Ship a thin `install.sh` that checks for
`pwsh` and passes every switch through.

**Consequence.** macOS and Linux users install a 60 MB runtime before the bundle
works, and a missing `pwsh` makes hooks fail silently — so `doctor.ps1` checks for
it explicitly there. In exchange there is no second set of hooks to keep in sync,
and every fix lands on all three platforms at once. A bash rewrite was rejected
because it would duplicate the classifier, the context reader and the state
machine, and because it would add Shell to the repository's language bar for a
few hundred lines of wrapper. The POSIX path is validated only by CI; the
development machine has no `pwsh` by choice.

## 14. A portable skill, and an advisory install mode

**Context.** Two audiences cannot use the hooks: people on claude.ai or the plain
Desktop chat, where hooks do not exist, and people on managed machines where
`settings.json` cannot be modified. Both were told to "use Claude Code instead",
which is not an answer.

**Decision.** Ship two fallbacks that share the same rules as prose:

- `skills/claude-skill/SKILL.md` — a self-contained, advisory skill for any
  Claude client, installed alongside the others so it appears in `/skills` too;
- `install.ps1 -NoHooks` — installs the skills and the `CLAUDE.md` block, and
  never reads or writes `settings.json`.

**Consequence.** The fallbacks cannot measure or enforce anything, and they say so
in their own text rather than letting the model imply otherwise. `-NoHooks`
deliberately leaves an earlier hook install alone except for a warning, because
silently deleting wiring the user did not ask to remove is worse than a stale
hook. The portable skill is one more folder to keep aligned with the scripts; the
`CLAUDE.md` block and `SKILL.md` are the two places where a rules change must be
mirrored.
