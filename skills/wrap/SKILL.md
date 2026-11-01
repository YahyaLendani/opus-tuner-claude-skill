---
name: wrap
description: Prepare and verify a handoff for this session, so the user can continue in a fresh one.
---

# Wrap

Use at a task boundary, or when the user wants to continue in a fresh session.

1. Write the draft. Its facts come from this session's own transcript:

   ```
   # Windows
   powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/../opus-tuner/scripts/brief.ps1" -SessionId "${CLAUDE_SESSION_ID}" -Project "<project directory>"

   # macOS / Linux
   pwsh -NoProfile -File "${CLAUDE_SKILL_DIR}/../opus-tuner/scripts/brief.ps1" -SessionId "${CLAUDE_SESSION_ID}" -Project "<project directory>"
   ```

   If it reports that it cannot identify the session, tell the user what it said.
   Do not write the file by hand or point it at another transcript.

2. Read the file it names and replace the placeholders. Keep it under ~600 words;
   a new session receives it verbatim.
   - **Task goal**: the outcome the user asked for
   - **User constraints**: rules the user set that still apply
   - **Decisions**: what was chosen and why
   - **Unresolved problems**: what is still broken or undecided
   - **Verification results**: what was actually run and its result, and what was not verified
   - **Next step**: one concrete action
   - **Dead ends** (optional): what was tried and failed

   Write `None.` when a required section really has nothing to say.

3. Run the same command again with `-Verify` added. It checks the required sections,
   masks credentials and marks the handoff ready. If it reports anything missing,
   fix that and run it again.

4. Only after verification passes, ask the user to run `/clear` when they want to
   continue in a fresh session. Never try to run it yourself. The session that wrote
   the handoff is the one that picks it up.
