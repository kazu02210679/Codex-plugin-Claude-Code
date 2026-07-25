---
description: Delegate an implementation task to Codex, then verify the result against the acceptance criteria.
argument-hint: <path to task packet> [workdir]
allowed-tools: Bash, Read, Grep, Glob, Write
---

You are the orchestrator. Run the `codex-orchestration` skill, Phases 4–6.

You do NOT write production code in this command. `Write` is granted for one
purpose: creating hint files under `.codex-instructions/`. Fixing the code
yourself instead of sending a hint back to Codex defeats the whole design — and
the scope check in step 3 will flag it, because it inspects the worktree
without caring who made the edit.

Arguments: `$ARGUMENTS`
- First token: path to the task packet (default: the most recent file in
  `.codex-instructions/`).
- Second token (optional): workdir Codex may modify (default: repo root).

Steps:

1. Delegate to Codex:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex_run.sh" <task_packet> <workdir>
   ```
   The script refuses to start on the default branch or from a dirty tree —
   both make the run unsafe and the scope check meaningless. If it refuses,
   fix the branch/tree state rather than reaching for the override env vars.
   Note the printed `RUNDIR`; artifacts for this attempt are in
   `<RUNDIR>/attempt-1/`.
2. Read that attempt's `report.md`.
3. **Verify the acceptance checklist yourself** — actually run the tests, lint,
   and type checks named in the packet; read the diff. Never pass on the report
   alone. Check `scope.txt` too: exit code 3 means Codex succeeded but edited
   files outside the allowlist, which is a failure even when every test passes.
4. If anything fails, the scope check flags a violation, or Codex reports
   "blocked": diagnose from `events.jsonl` / `stderr.log` / failing output,
   write `.codex-instructions/<task>.hint-N.md` with the root cause + minimal
   fix guidance, and continue Codex:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex_resume.sh" <hint_file> <workdir> <RUNDIR>
   ```
   Each call opens `<RUNDIR>/attempt-N+1/`; earlier attempts stay intact, so
   read the one you just created. Loop back to step 2. Cap at 3 attempts, then
   escalate to the user with every attempt's report and what you tried.
5. When all acceptance items pass and the scope check is clean, summarize what
   changed and deliver.
