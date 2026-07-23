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
2. Read the printed `report.md`.
3. **Verify the acceptance checklist yourself** — actually run the tests, lint,
   and type checks named in the packet; read the diff. Never pass on the report
   alone.
4. If anything fails or Codex reports "blocked": diagnose from `events.jsonl` /
   `stderr.log` / failing output, write `.codex-instructions/<task>.hint-N.md`
   with the root cause + minimal fix guidance, and continue Codex:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex_resume.sh" <hint_file> <workdir> <outdir>
   ```
   Loop back to step 2. Cap at 3 attempts, then escalate to the user.
5. When all acceptance items pass, summarize what changed and deliver.
