---
description: Independently verify a Codex run against the acceptance criteria and give a pass/fail delivery judgment.
argument-hint: [task packet] [codex run outdir]
allowed-tools: Bash, Read, Grep, Glob
---

You are the reviewer in the Claude ⇄ Codex division of labor. Run the delivery
judgment from the `codex-orchestration` skill, Phase 5.

Arguments: `$ARGUMENTS`
- Optional first token: the task packet (for the acceptance checklist).
- Optional second token: the Codex run outdir (contains `report.md`,
  `events.jsonl`, `meta.json`).

Do this:

1. Extract the acceptance checklist from the task packet.
2. For each item, **run the actual check** (tests, lint, type check, build,
   smoke command) and record the real result. Do not accept Codex's `report.md`
   as evidence — it is a claim, not a verification.
3. Read the diff for scope creep (features not in the packet) and for anything
   that bypasses stated safety/guardrails.
4. Output a table: each acceptance item → PASS/FAIL with the command run and its
   outcome. Give an overall verdict: DELIVER or SEND BACK (with the specific
   failing items, so `/codex-run` can continue from there).
