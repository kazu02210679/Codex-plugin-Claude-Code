---
description: Turn a request into a Codex plan — split into committable tasks, each with its own file allowlist.
argument-hint: <what you want built>
---

You are the orchestrator in the Claude ⇄ Codex division of labor. Do NOT write
production code yourself in this step.

Use the `codex-orchestration` skill, Phases 1–3.

Request from the user:

$ARGUMENTS

Write a plan directory `.codex-instructions/<short-plan-name>/`:

```
packet.md        the plan: requirement, in/out of scope, plan-level acceptance
                 checklist, test policy, stuck protocol
test             default test commands, one per line — the gate that runs
                 before every task commit
interfaces.md    contracts established by completed tasks (starts empty)
T1.md            instructions to Codex for task 1
T1.allowlist     the files task 1 may touch
T2.md, T2.allowlist, ...
```

## Splitting into tasks

The split is the point of this command, so spend the thought here. A task is
correctly sized when all three hold:

1. **It is independently committable.** Applying it leaves the repository
   working — tests green, nothing half-wired. If T2 must land for T1 to make
   sense, they are one task.
2. **Something can be run to prove it.** Name the check in the acceptance
   items. A task nothing can verify cannot pass a commit gate.
3. **Its diff is reviewable in one sitting.** This is the constraint the whole
   pipeline exists to protect: you have to verify each task's diff yourself,
   and that stops being real work above a few hundred lines.

Prefer a first task that establishes the shape others build on (types, module
boundaries, the interface everything calls) — later tasks can then be checked
against a contract instead of a guess.

Do not split further than that. Each task is a separate `codex exec` with its
own startup cost, and tasks that only make sense together are one task.

## Each `T<N>.md`

Same rules as any task packet: the requirement, a line telling Codex not to add
what the packet did not ask for, in/out of scope, the acceptance checklist for
*this task*, and the stuck-protocol line. Where the task depends on something
an earlier one built, quote the relevant part of `interfaces.md` — each task is
a fresh Codex session and inherits no memory of the last.

## Each `T<N>.allowlist`

One glob per line (`#` comments allowed), derived from that task's in-scope
section. `*` also matches `/`, so `src/api/*` covers a subtree. Include the
test paths the task is expected to add to. `codex_run.sh` and `codex_commit.sh`
both fail the task if anything outside it changes, so an allowlist that is too
generous silently removes the guard.

## Before writing

Ask the user about any genuine ambiguity in requirements or scope. When done,
show the task breakdown with each task's acceptance items and allowlist, and
tell the user they can run `/codex-run` next.
