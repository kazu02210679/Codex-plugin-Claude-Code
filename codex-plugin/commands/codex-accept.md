---
description: Independently verify a finished Codex plan against its acceptance criteria, scope gate and commit history.
argument-hint: [plan dir] [workdir]
allowed-tools: Bash, Read, Grep, Glob
---

You are the reviewer in the Claude ⇄ Codex division of labor. Run the delivery
judgment from the `codex-orchestration` skill, Phase 5 — for the plan as a
whole.

Arguments: `$ARGUMENTS`
- Optional first token: the plan directory (`packet.md`, `T<N>.md`,
  `T<N>.allowlist`).
- Optional second token: the workdir (default: repo root).

Run artifacts for each task are under `<workdir>/.codex-runs/*/attempt-N/`
(`report.md`, `events.jsonl`, `scope.txt`, `meta.json`, `commit.log`).

Do this:

1. Establish what was supposed to happen and what did:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex_status.sh" <plan_dir> <workdir>
   ```
   Every task must be committed. A pending task means the plan is unfinished,
   whatever the tests say.

2. Extract the **plan-level** acceptance checklist from `packet.md`. For each
   item, run the actual check (tests, lint, type check, build, smoke command)
   against the finished branch and record the real result. Do not accept
   Codex's `report.md` as evidence — it is a claim, not a verification. Per-task
   gates prove each step in isolation; this is the only thing that proves they
   compose.

3. Check the shape of the history, not just its content:
   ```bash
   git -C <workdir> log --format='%h %s%n%b' <base>..HEAD
   ```
   Expect one commit per task, each carrying its `Codex-Task:` trailer. Several
   commits for one task, one commit spanning several, or a task commit with no
   trailer all mean the gate was bypassed somewhere — say so.

4. Re-run the scope gate per task rather than eyeballing the diffs, since
   spotting an unrequested file in a large diff is exactly what reading misses:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex_scope_check.sh" <plan_dir>/T<N>.allowlist <workdir> <that task's parent commit>
   ```
   A violation is a FAIL on its own. Then read the diffs for what the gate
   cannot see: disabled or weakened tests, and anything that bypasses stated
   guardrails.

5. Output a table: each acceptance item → PASS/FAIL with the command run and
   its outcome, plus rows for task completeness, history shape, and the scope
   gate. Give an overall verdict: DELIVER, or SEND BACK naming the specific
   failing items and the task they belong to, so `/codex-run` can pick up from
   that task.
