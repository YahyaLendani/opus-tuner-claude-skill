---
name: wrap
description: Write the handoff brief so the session can be cleared and resumed in a fresh context.
---

# Wrap

Use at a task boundary, or when context is near its ceiling.

1. Run the brief writer — it derives the facts from the transcript, not from memory:

   ```
   # Windows
   powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\opus-tuner\scripts\brief.ps1"

   # macOS / Linux
   pwsh -NoProfile -File "$HOME/.claude/skills/opus-tuner/scripts/brief.ps1"
   ```

   If `CLAUDE_CONFIG_DIR` is set, substitute it for `~/.claude` in that path.

2. Read `.claude/handoff.md` and replace the four placeholder sections:
   - **Decisions** — what was chosen and why
   - **Dead ends** — what was tried and failed, so it is not retried
   - **Unverified assumptions** — believed but not proven
   - **Next step** — one concrete action

   Keep the whole file under ~600 words. It is re-injected verbatim into the new
   session, so every line costs tokens there.

3. Tell the user, in one line:

   > Brief written. Run `/clear` — I will pick up from it automatically.

Do **not** run `/compact` instead. A handoff replaces the conversation at a task
boundary with no summarization pass; `/compact` costs a full read of the context.
