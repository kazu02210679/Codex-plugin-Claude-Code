---
description: Independently verify a Codex run against the acceptance criteria and give a pass/fail delivery judgment.
argument-hint: [task packet] [codex run rundir]
allowed-tools: Bash, Read, Grep, Glob
---

You are the reviewer in the Claude ⇄ Codex division of labor. Run the delivery
judgment from the `codex-orchestration` skill, Phase 5.

Arguments: `$ARGUMENTS`
- Optional first token: the task packet (for the acceptance checklist).
- Optional second token: the run directory (contains `attempt-N/` with
  `report.md`, `events.jsonl`, `scope.txt`, `meta.json`, plus `base_commit` and
  a frozen copy of the `allowlist`).

Do this:

1. Extract the acceptance checklist from the task packet.
2. For each item, **run the actual check** (tests, lint, type check, build,
   smoke command) and record the real result. Do not accept Codex's `report.md`
   as evidence — it is a claim, not a verification.
3. Run the scope gate rather than eyeballing the diff for scope creep:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex_scope_check.sh" <rundir>/allowlist <workdir> "$(cat <rundir>/base_commit)"
   ```
   A violation is a FAIL regardless of test results. Then read the diff for what
   the gate cannot see: weakened or disabled tests, and anything that bypasses
   stated safety/guardrails.
4. Output a table: each acceptance item → PASS/FAIL with the command run and its
   outcome, plus a row for the scope gate. Give an overall verdict: DELIVER or
   SEND BACK (with the specific failing items, so `/codex-run` can continue from
   there).
