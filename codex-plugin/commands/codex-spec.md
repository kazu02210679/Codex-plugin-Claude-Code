---
description: Turn a request into a Codex task packet (requirements, scope, acceptance criteria, file allowlist).
argument-hint: <what you want built>
---

You are the orchestrator in the Claude ⇄ Codex division of labor. Do NOT write
production code yourself in this step.

Use the `codex-orchestration` skill, Phases 1–3.

Request from the user:

$ARGUMENTS

Produce two files:

**`.codex-instructions/<short-task-name>.md`** — the task packet. It must
include: the top-level requirement, in/out of scope, a **verifiable acceptance
checklist**, the test policy, and the stuck-protocol line. Model the precision
on `docs/multi_agent_driving_mvp_spec.md` if present.

**`.codex-instructions/<short-task-name>.allowlist`** — the files this task may
touch, one glob per line (`#` comments allowed). `codex_run.sh` picks it up
automatically by name and fails the run if anything outside it changes. Derive
it from the in-scope section you just wrote: if a path is not needed to satisfy
the requirement, leave it out. Patterns match with `*` also matching `/`, so
`src/foo/*` covers a subtree. Include test paths the task is expected to add to.

Before writing, ask the user about any genuine ambiguity in requirements or
scope. When done, show the acceptance checklist and the allowlist, and tell the
user they can run `/codex-run` next.
