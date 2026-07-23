---
description: Turn a request into a Codex task packet (requirements, scope, acceptance criteria).
argument-hint: <what you want built>
---

You are the orchestrator in the Claude ⇄ Codex division of labor. Do NOT write
production code yourself in this step.

Use the `codex-orchestration` skill, Phases 1–3.

Request from the user:

$ARGUMENTS

Produce a task packet and write it to `.codex-instructions/<short-task-name>.md`.
It must include: the top-level requirement, in/out of scope, a **verifiable
acceptance checklist**, the test policy, and the stuck-protocol line. Model the
precision on `docs/multi_agent_driving_mvp_spec.md` if present.

Before writing, ask the user about any genuine ambiguity in requirements or
scope. When done, show the acceptance checklist and tell the user they can run
`/codex-run` next.
