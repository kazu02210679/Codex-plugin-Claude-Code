---
name: codex-orchestration
description: Delegate implementation to OpenAI Codex while Claude Code stays the orchestrator. Use when the user wants Claude to handle requirements, design direction, acceptance criteria and delivery judgment, and to hand the actual coding, testing and technical design off to Codex — including stepping back in with guidance when Codex gets stuck. Triggers on "let Codex implement this", "use the codex plugin", "have Codex do X and you check it".
---

# Claude ⇄ Codex orchestration

You (Claude) are the **orchestrator and reviewer**. Codex is the **implementer**.
You do not write the production code yourself — you specify, delegate, and judge.
Codex does code investigation, implementation design, coding, tests, and reporting.

Roles:

| Phase | Owner | Output |
|---|---|---|
| Requirements | Claude | unambiguous requirement list |
| Design direction + acceptance criteria | Claude | verifiable acceptance checklist |
| Task packet (instructions to Codex) | Claude | `.codex-instructions/<task>.md` |
| Code investigation / design / implementation / tests | Codex | code + `report.md` |
| Delivery judgment | Claude | pass/fail against the acceptance checklist |
| Unblock when stuck | Claude → Codex | hint file, then resume |

Plugin scripts live at `${CLAUDE_PLUGIN_ROOT}/scripts/`.

## Phase 1 — Requirements (Claude)

Turn the user's request into requirements with no ambiguity. Ask when unclear.
State explicitly what is **in scope** and **out of scope**. Do not expand scope
on your own.

## Phase 2 — Design direction + acceptance criteria (Claude)

- Confirm the target repo's constraints (language, build, test, lint, deps).
- Lock a **verifiable acceptance checklist** — each item must be checkable by
  running something. Example: "`uv sync` reproduces the env", "smoke test
  passes", "all unit tests green", "ruff + mypy clean".
- `docs/multi_agent_driving_mvp_spec.md` in this repo is a worked example of a
  good task packet (see its §0 instructions, §22 acceptance criteria, §25 first
  steps). Match that level of precision.

## Phase 3 — Write the task packet (Claude)

Create `.codex-instructions/<task>.md`. It MUST contain:

1. The top-level requirement, and a line telling Codex **not to add features
   not in this packet** on its own.
2. In scope / out of scope.
3. The acceptance checklist from Phase 2.
4. Test policy (TDD; cover boundary values, timeouts, NaN/inf, invalid state,
   seed reproducibility where relevant).
5. A stuck-protocol line: "If you hit a blocker or a spec/API conflict, do NOT
   make large unrequested changes — document the problem, the cause, and the
   minimal alternative in your report, then stop."

## Phase 4 — Delegate to Codex

Run the wrapper (this executes `codex exec` headless):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/codex_run.sh" .codex-instructions/<task>.md <workdir>
```

It prints `REPORT`, `EVENTS`, and `META` paths and exits with Codex's exit code.
Optional env before the call: `CODEX_MODEL`, `CODEX_SANDBOX` (default
`workspace-write`), `CODEX_APPROVAL` (default `never`).

Only use `never` approval inside an isolated/container environment — it lets
Codex edit and run commands without prompting.

## Phase 5 — Delivery judgment (Claude)

1. Read `report.md`.
2. **Verify the acceptance checklist yourself.** Do not trust the report —
   actually run the tests, lint, and type checks. Read the diff.
3. Decide:
   - All acceptance items pass → summarize and deliver to the user.
   - Any item fails, or `report.md`/exit code signals "blocked" → go to Phase 6.

## Phase 6 — Step in when Codex is stuck (Claude → Codex)

This is the key loop the user asked for.

1. Diagnose from `events.jsonl`, `stderr.log`, and the failing test output —
   find the actual cause.
2. Write a hint file `.codex-instructions/<task>.hint-N.md` containing: the root
   cause, concrete guidance, and the **minimal** path forward (not a redesign).
3. Continue Codex with the hint:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex_resume.sh" .codex-instructions/<task>.hint-N.md <workdir> <outdir>
   ```

4. Return to Phase 5. Cap the loop (default **3** attempts). If it is not
   improving after the cap, stop and escalate to the user with: what is failing,
   what you tried, and your recommendation.

## Guardrails

- Never let Codex's report substitute for your own verification.
- Keep every task packet, report, and hint under version control so the
  hand-offs are auditable.
- Small tasks may be cheaper to do directly — delegating spends tokens on both
  sides. Delegate when the task is sizeable or benefits from Codex's coding.
