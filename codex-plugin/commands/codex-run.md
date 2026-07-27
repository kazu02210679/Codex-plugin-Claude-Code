---
description: Delegate an implementation task to Codex, then verify the result against the acceptance criteria.
argument-hint: <path to task packet> [workdir]
allowed-tools: Bash, Read, Grep, Glob, Edit
---

You are the orchestrator. Run the `codex-orchestration` skill, Phases 4–6.

Arguments: `$ARGUMENTS`
- First token: path to the task packet (default: the most recent file in
  `.codex-instructions/`).
- Second token (optional): workdir Codex may modify (default: repo root).

Steps:

1. Delegate to Codex:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex_run.sh" <task_packet> <workdir>
   ```
2. Read the printed `report.md` — as a claim about the work, not as evidence.
3. **Verify the acceptance checklist yourself.** You re-run each declared
   command in the workspace; check each exit code; compare the actual pass/fail
   counts against the counts the report claims; read the diff. Inspect failures
   in safety-critical items first — one of those failing means not done, however
   many other items pass. If the report claimed success and your re-run
   disagrees, record the discrepancy explicitly and treat the delegate's
   self-reporting as unreliable for the next round.
4. If anything fails or Codex reports "blocked": first classify the failure as
   implementation / fixture / evaluator / environment, then diagnose from
   `events.jsonl` / `stderr.log` / failing output, write
   `.codex-instructions/<task>.hint-N.md` with the root cause + minimal fix
   guidance, and continue Codex:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex_resume.sh" <hint_file> <workdir> <outdir>
   ```
   Loop back to step 2. Cap at 3 attempts, then escalate to the user.

   Never resume without changing something you can name (smaller scope, newly
   identified cause, different layer). A timeout that produced no diff means the
   task was too large or the delegate was blocked — shrink it, supply the
   observed blocking condition, or take it back yourself. Do not re-issue the
   same packet with a longer timeout.
5. When all acceptance items pass, summarize what changed and deliver.
