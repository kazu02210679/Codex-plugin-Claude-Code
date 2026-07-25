---
name: codex-orchestration
description: Delegate implementation to OpenAI Codex while Claude Code stays the orchestrator. Use when the user wants Claude to handle requirements, design direction, acceptance criteria and delivery judgment, and to hand the actual coding, testing and technical design off to Codex — including stepping back in with guidance when Codex gets stuck. Triggers on "let Codex implement this", "use the codex plugin", "have Codex do X and you check it".
---

# Claude ⇄ Codex orchestration

You (Claude) are the **orchestrator and reviewer**. Codex is the **implementer**.
You do not write the production code yourself — you specify, delegate, and judge.
Codex does code investigation, implementation design, coding, tests, and reporting.

Work is split into tasks, and each task is delegated, verified, and committed
before the next one starts. That is what keeps your side of the deal possible:
you have to verify every diff yourself, and a plan-sized diff is not something
anyone verifies honestly.

Roles:

| Phase | Owner | Output |
|---|---|---|
| Requirements | Claude | unambiguous requirement list |
| Design direction + acceptance criteria | Claude | verifiable acceptance checklist |
| Task split + plan | Claude | `.codex-instructions/<plan>/` |
| File scope per task | Claude | `T<N>.allowlist` |
| Code investigation / design / implementation / tests | Codex | code + `report.md` |
| Delivery judgment | Claude | pass/fail against the acceptance checklist |
| Unblock when stuck | Claude → Codex | hint file, then resume |
| Commit the task | gate script | one commit, tests green |

Plugin scripts live at `${CLAUDE_PLUGIN_ROOT}/scripts/`.

Most of the rules here are enforced by scripts rather than by your good
intentions: `codex_run.sh` refuses to start on the default branch or from a
dirty tree; `codex_scope_check.sh` fails a run whose diff leaves the allowlist;
`codex_commit.sh` refuses to commit when the tests are not green, or when
something committed mid-task; `codex_resume.sh` refuses past the attempt cap;
and `codex_status.sh` reads progress back out of git rather than out of your
memory of it. The scope check reads the worktree and does not care who made the
edit, so it holds you to "Claude does not write the production code" exactly as
it holds Codex to its declared scope.

**Two kinds of file, two different rules.** *Product* files are what Codex is
asked to change — governed by the allowlist, and the subject of the diff you
review. *Orchestration metadata* is the plan directory and the run artifacts:
you write there constantly as the loop runs, so it is exempt from the dirty
preflight and from the scope gate. Codex is kept out of it a different way — a
fingerprint taken across every run, which fails the run (exit 4) if Codex
edited the plan. An allowlist Codex can widen would not be a constraint, so
the gate reads the frozen copy in the run directory, never the live file.

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

## Phase 3 — Split into tasks and write the plan (Claude)

Create `.codex-instructions/<plan>/`:

```
packet.md      plan-level requirement, scope, acceptance checklist, test policy
test           default test commands, one per line — the pre-commit gate
interfaces.md  contracts established by completed tasks (starts empty)
T1.md          instructions to Codex for task 1
T1.allowlist   the files task 1 may touch
T1.test        optional per-task test override (e.g. a fast subset)
T2.md, T2.allowlist, ...
```

A task is correctly sized when three things hold: it is **independently
committable** (applying it leaves the repo working), **something can be run to
prove it**, and **its diff is reviewable in one sitting**. If T2 must land for
T1 to make sense, they are one task. Do not split past that — each task is a
separate `codex exec` with its own startup cost.

Prefer a first task that establishes the shape the others build on: types,
module boundaries, the interface everything calls. Later tasks can then be
checked against a contract rather than a guess.

Every `T<N>.md` MUST contain:

1. The requirement for **this task**, and a line telling Codex **not to add
   what this packet did not ask for**.
2. In scope / out of scope.
3. The acceptance checklist for this task.
4. Test policy (TDD; cover boundary values, timeouts, NaN/inf, invalid state,
   seed reproducibility where relevant).
5. A stuck-protocol line: "If you hit a blocker or a spec/API conflict, do NOT
   make large unrequested changes — document the problem, the cause, and the
   minimal alternative in your report, then stop."
6. A hands-off line: "Do not create or amend commits, switch branches, rebase,
   reset, or otherwise modify git history, and do not edit anything under
   `.codex-instructions/`." Both are enforced — `codex_commit.sh` exits 5 if
   HEAD moved during the task, and the run fails with exit 4 if the plan
   directory changed — but Codex should be told, not just caught.

Every `T<N>.allowlist` is one glob per line, derived from that task's in-scope
section. This is the executable half of rule 1 — the packet asks Codex to stay
in scope, the allowlist proves whether it did. An allowlist that is too
generous silently removes the guard.

You do not need to quote `interfaces.md` into the packets. `codex_run.sh`
appends it to the prompt at run time, so the packets stay stable and the plan
does not have to be rewritten mid-loop.

## Phase 4 — Delegate one task

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/codex_status.sh" <plan_dir> <workdir>   # what is next?
"${CLAUDE_PLUGIN_ROOT}/scripts/codex_run.sh" <plan_dir>/T<N>.md <workdir>
```

`codex_run.sh` picks up `T<N>.allowlist` by name and prints `RUNDIR` plus the
`REPORT`, `EVENTS` and `META` paths for `<RUNDIR>/attempt-1/`. Optional env
before the call: `CODEX_MODEL`, `CODEX_SANDBOX` (default `workspace-write`;
also `read-only` or `danger-full-access`), `CODEX_ALLOWLIST`.

Exit codes: `0` clean, `2` preflight refusal (nothing ran), `3` Codex succeeded
but went outside the allowlist, `4` Codex edited the plan directory, anything
else is Codex's own code.

A preflight refusal is information, not an obstacle. Running on the default
branch or over uncommitted work is what makes an unattended agent expensive to
undo, and a dirty tree also makes the scope check meaningless because
pre-existing edits look exactly like Codex's. Only *product* changes count, so
the plan you just wrote never blocks the first task. After the first task a
dirty tree means the previous task never committed — so the refusal is telling
you the loop is off the rails, not that the check is in your way. Fix the
branch or tree state; reach for `CODEX_ALLOW_DIRTY` /
`CODEX_ALLOW_DEFAULT_BRANCH` only when you have a specific reason and tell the
user you did.

Exit 4 is different: it means the run edited the plan, the allowlist or the
hints. Do not retry it — read the diff first and find out what Codex was
trying to change about its own instructions.

`codex exec` is non-interactive, so there is no approval prompt — the
`--sandbox` mode bounds what Codex may touch. `workspace-write` lets it edit and
run commands within the workspace; use `danger-full-access` only inside an
isolated/container environment.

## Phase 5 — Delivery judgment (Claude)

1. Read the latest attempt's `report.md`.
2. **Verify this task's acceptance checklist yourself.** Do not trust the
   report — actually run the tests, lint, and type checks. Read the diff.
3. Read `scope.txt` (or re-run `codex_scope_check.sh`). An out-of-scope diff is
   a failure even when every acceptance item passes: the packet's scope is part
   of the contract, and exit code 3 exists so a green test run cannot hide it.
4. Decide:
   - All acceptance items pass and scope is clean → Phase 7.
   - Any item fails, scope is violated, or `report.md`/exit code signals
     "blocked" → Phase 6.

## Phase 6 — Step in when Codex is stuck (Claude → Codex)

1. Diagnose from `events.jsonl`, `stderr.log`, and the failing test output —
   find the actual cause.
2. Write a hint file `<plan_dir>/T<N>.hint-M.md` containing: the root cause,
   concrete guidance, and the **minimal** path forward (not a redesign).
3. Continue Codex with the hint:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex_resume.sh" <plan_dir>/T<N>.hint-M.md <workdir> <RUNDIR>
   ```

   This opens `<RUNDIR>/attempt-M+1/`. Earlier attempts are never overwritten,
   which is what makes the escalation in step 4 possible. The hint continues
   the exact session the run recorded, not whatever session the machine saw
   last — so a second agent working in the same repository cannot receive your
   hint by accident.

4. Return to Phase 5. The loop caps at **3** attempts per task; the script
   refuses the fourth rather than trusting you to count. When you hit it, stop
   and escalate to the user with: what is failing, what you tried, and your
   recommendation. Cite the attempts — they are all still on disk.

## Phase 7 — Record the interfaces, commit, then the next task

**First**, append to `<plan_dir>/interfaces.md` what this task established that
a later task will call: signatures, types, endpoints, config keys, file paths.
The next run injects it automatically.

Do this *before* committing, not after. The commit stages this task's plan
directory along with its code, so an interfaces entry written afterwards lands
one commit late — attributed to the next task, and for the last task in a plan
never committed at all, leaving the tree dirty when the work is supposedly
finished.

**Then** commit:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/codex_commit.sh" <plan_dir> T<N> <workdir> <RUNDIR>
```

The run directory is required, not optional: it holds the pre-run commit and
the frozen contract, and without them most of the gates cannot run.

It checks that the plan has not changed since the run, checks scope, runs the
tests, checks scope **again** — tests write coverage files and snapshots, and a
gate that only looked beforehand would let them into the commit — then stages
this task's product files and plan directory, and nothing else, and makes
exactly one commit. Refusals: `1` tests failed or nothing changed, `3` out of
scope, `6` the plan was edited between the run and the commit, `5` HEAD moved
during the task (something committed mid-run; Codex must not). A refusal means
the task is not done — go back to Phase 6 rather than looking for a way around
it.

Then back to Phase 4 for the next task.

When `codex_status.sh` reports every task committed, run the **plan-level**
acceptance checklist from `packet.md` against the finished branch — the full
suite, not the per-task subset. Per-task gates prove each step in isolation;
only this proves they compose. Then summarize what changed, task by task, and
deliver.

## Guardrails

- Never let Codex's report substitute for your own verification.
- Progress lives in git, not in your context. `codex_status.sh` reconstructs it
  from the `Codex-Task:` trailers, so a compaction or a restart costs you
  nothing — start a resumed session by asking it where the plan stands rather
  than inferring from what you remember.
- Keep the plan directory under version control — packets, allowlists, tests,
  `interfaces.md`, hints. That is the contract, and what makes the hand-offs
  auditable later. Run artifacts under `.codex-runs/` stay local: they are
  evidence for one run, and committing an event stream would bury the diff you
  have to review. The run directory ignores itself for that reason.
- Small jobs may be cheaper to do directly — delegating spends tokens on both
  sides, and a one-task plan is mostly ceremony. Delegate when the work is
  sizeable or benefits from Codex's coding.
