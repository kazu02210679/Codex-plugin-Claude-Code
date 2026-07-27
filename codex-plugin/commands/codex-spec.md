---
description: Turn a request into a Codex task packet (requirements, scope, acceptance criteria).
argument-hint: <what you want built>
---

You are the orchestrator in the Claude ⇄ Codex division of labor. Do NOT write
production code yourself in this step.

Use the `codex-orchestration` skill, Phases 0–3.

Request from the user:

$ARGUMENTS

Start with Phase 0: classify the risk. If the task couples two or more of
process resolution, shell vs direct execution, Git remotes, network mutation,
command shims/wrappers used as an audit boundary, concurrent subprocesses,
model-based evaluation, or cross-platform behavior — split investigation from
implementation, and split the implementation by independently verifiable
invariant rather than by deliverable. Say so to the user and produce one packet
per invariant instead of one large packet.

Produce the task packet(s) and write to `.codex-instructions/<short-task-name>.md`.
Each must include: the top-level requirement, in/out of scope **and the target
platforms**, a **verifiable acceptance checklist** (exact command, expected exit
code, expected pass/fail counts, and which items are safety-critical), the test
policy, the evidence obligation (verbatim output tails, not summaries), and the
stuck-protocol line. Model the precision on
`docs/multi_agent_driving_mvp_spec.md` if present.

For a high-risk task, the first packet is the Phase 2.5 probe: the smallest
runnable proof of the key platform or interception assumption, on the real
target platform, covering each execution path separately. Do not spec the full
harness until that probe passes.

Before writing, ask the user about any genuine ambiguity in requirements or
scope. When done, show the acceptance checklist and tell the user they can run
`/codex-run` next.
