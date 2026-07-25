---
description: Work a Codex plan task by task — delegate, verify, commit — or delegate a single task packet.
argument-hint: <path to plan directory or task packet> [workdir]
allowed-tools: Bash, Read, Grep, Glob, Write
---

You are the orchestrator. Run the `codex-orchestration` skill, Phases 4–7.

You do NOT write production code in this command. `Write` is granted for two
things only: hint files and `interfaces.md`, both under `.codex-instructions/`.
Fixing the code yourself instead of sending a hint back to Codex defeats the
whole design — and the scope check will flag it, because it inspects the
worktree without caring who made the edit.

Arguments: `$ARGUMENTS`
- First token: a plan directory (`.codex-instructions/<plan>/`) — or a single
  task packet file, for a one-off delegation with no task loop.
- Second token (optional): workdir Codex may modify (default: repo root).

## Plan directory — the task loop

1. Ask where the plan stands. Do this first even in a session that just wrote
   the plan; it is also how you recover after a compaction or a restart:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex_status.sh" <plan_dir> <workdir>
   ```
   It reports each task as done (with its commit) or pending, and names the
   next one. Exit 0 means the plan is finished — skip to step 7.

2. Delegate the next task:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex_run.sh" <plan_dir>/T<N>.md <workdir>
   ```
   It picks up `T<N>.allowlist` by name. It also refuses to start on the
   default branch or from a dirty tree — after the first task that means the
   previous task committed cleanly, so a refusal here is real information.
   Note the printed `RUNDIR`.

3. Read `<RUNDIR>/attempt-1/report.md`.

4. **Verify this task's acceptance checklist yourself** — actually run the
   tests, lint and type checks it names; read the diff. Never pass on the
   report alone. Check `scope.txt` too: exit code 3 means Codex succeeded but
   edited files outside the allowlist, which is a failure even when the tests
   are green. Exit code 4 means Codex edited the plan directory — do not retry
   it, read the diff and find out what it was trying to change about its own
   instructions.

5. If anything fails, scope is violated, or Codex reports "blocked": diagnose
   from `events.jsonl` / `stderr.log` / the failing output, write
   `<plan_dir>/T<N>.hint-M.md` with the root cause and the **minimal** fix, and
   continue Codex:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex_resume.sh" <plan_dir>/T<N>.hint-M.md <workdir> <RUNDIR>
   ```
   Each call opens a new attempt directory; earlier attempts stay intact. Back
   to step 3. The script refuses a fourth attempt — when it does, stop and
   escalate to the user with every attempt's report and what you tried.

6. Close the task out:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex_commit.sh" <plan_dir> T<N> <workdir> <RUNDIR>
   ```
   It checks scope, runs the tests, checks scope again, and makes exactly one
   commit. Refusals: `1` tests failed or nothing changed, `3` out of scope, `5`
   HEAD moved during the task. A refusal is not something to work around: it
   means the task is not done, so go back to step 5.

   Then append to `<plan_dir>/interfaces.md` whatever this task established
   that a later one will call: function signatures, types, endpoints, config
   keys, file paths. The next task is a fresh Codex session and will not know
   any of it otherwise.

   Loop back to step 1.

7. When every task is committed, run the **plan-level** acceptance checklist
   from `packet.md` against the finished branch — the full suite, not the
   per-task subset. Per-task gates prove each step; only this proves they
   compose. Then summarize what changed, task by task, and deliver.

## Single task packet

Steps 2–5 only, with no commit gate. Use this for a one-off delegation that is
too small to plan.
