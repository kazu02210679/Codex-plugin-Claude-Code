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
| Delegation sizing | Claude | risk class + task split |
| Requirements | Claude | unambiguous requirement list |
| Design direction + acceptance criteria | Claude | verifiable acceptance checklist |
| Assumption probe (high risk only) | Claude or Codex | one runnable proof of the key assumption |
| Task packet (instructions to Codex) | Claude | `.codex-instructions/<task>.md` |
| Code investigation / design / implementation / tests | Codex | code + `report.md` |
| Delivery judgment | Claude | pass/fail **re-run by Claude**, not read from the report |
| Unblock when stuck | Claude → Codex | diagnosed cause, hint file, then resume |

Plugin scripts live at `${CLAUDE_PLUGIN_ROOT}/scripts/`.

## Phase 0 — Size the delegation before writing anything

Do not size a task by file count or line count. Size it by how many independent
failure sources it couples.

Treat a task as **high risk** when it depends on two or more of:

- operating-system process resolution (which executable actually runs)
- shell versus direct execution paths
- Git remotes or any mutation that leaves the working tree
- network mutation
- command shims, wrappers, proxies, or mocks used as an audit boundary
- concurrent subprocesses
- behavioral evaluation performed by another model
- cross-platform behavior (Windows vs POSIX) that the task assumes is uniform

For a high-risk task:

1. **Split investigation from implementation.** Delegate the investigation first
   and get an answer, then delegate the implementation.
2. **Split the implementation by independently verifiable invariant, not by
   deliverable.** "Build the fixture builder" is a deliverable and hides its own
   failures. "Prove that direct exec and shell exec are both recorded in
   `calls.log`" is an invariant — it passes or it does not.
3. Require the Phase 2.5 probe before any full harness is built.

A task that is only high risk because it is long is not high risk. A task that
is three files but crosses process resolution and Git mutation is.

## Phase 1 — Requirements (Claude)

Turn the user's request into requirements with no ambiguity. Ask when unclear.
State explicitly what is **in scope** and **out of scope**. Do not expand scope
on your own.

Name the target platforms explicitly (Windows / macOS / Linux) whenever the task
touches processes, paths, or executables. "It works on Linux" is not a platform
decision, it is an untested assumption.

## Phase 2 — Design direction + acceptance criteria (Claude)

- Confirm the target repo's constraints (language, build, test, lint, deps).
- Lock a **verifiable acceptance checklist**. Each item must name:
  - the exact command to run,
  - the expected exit code,
  - the expected counts where the command reports them (tests passed / failed).

  An item that cannot be stated that way is not an acceptance item yet — sharpen
  it until it can.
- Mark which acceptance items are **safety-critical** — the ones that establish
  that a guardrail, audit trail, or interception boundary actually holds. These
  are blocking: if a safety-critical item fails, the task is not done, no matter
  how many other items pass.
- `docs/multi_agent_driving_mvp_spec.md` in this repo is a worked example of a
  good task packet (see its §0 instructions, §22 acceptance criteria, §25 first
  steps). Match that level of precision.

## Phase 2.5 — Probe the key assumption before building on it (high risk only)

Before implementing any platform-dependent or interception-dependent mechanism,
prove the assumption it rests on with the smallest runnable thing.

- Test the assumption on the **actual target platform**, not by reasoning about it.
- Test **every execution path separately** that the design claims to cover —
  shell execution and direct execution are different paths and must be proven
  independently.
- Do not build the full harness until the probe succeeds.

For an audit boundary (shim, wrapper, mock, proxy), the rule is stronger:

> Before running any candidate work, measure that each audited execution path
> actually reaches the shim. Verify the shell path and the direct-exec path
> separately. If any path cannot be audited, **stop and produce no result** —
> fail closed. An unaudited pass is not a pass.

Keep the probe in the repo as a permanent self-test, not as throwaway scratch
work. The mechanism that proves interception works must run before the thing
that depends on it.

## Phase 3 — Write the task packet (Claude)

Create `.codex-instructions/<task>.md`. It MUST contain:

1. The top-level requirement, and a line telling Codex **not to add features
   not in this packet** on its own.
2. In scope / out of scope, and the target platforms.
3. The acceptance checklist from Phase 2 — commands, expected exit codes,
   expected counts, and which items are safety-critical.
4. Test policy (TDD; cover boundary values, timeouts, NaN/inf, invalid state,
   seed reproducibility where relevant).
5. **Evidence obligation**: "Paste the verbatim tail of each verification
   command's output, including its exit code and pass/fail counts, into your
   report. Do not summarize a test run as 'passed'."
6. A stuck-protocol line: "If you hit a blocker or a spec/API conflict, do NOT
   make large unrequested changes — document the problem, the cause, and the
   minimal alternative in your report, then stop."

## Phase 4 — Delegate to Codex

Run the wrapper (this executes `codex exec` headless):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/codex_run.sh" .codex-instructions/<task>.md <workdir>
```

It prints `REPORT`, `EVENTS`, and `META` paths and exits with Codex's exit code.
Optional env before the call: `CODEX_MODEL`, `CODEX_SANDBOX` (default
`workspace-write`; also `read-only` or `danger-full-access`).

`codex exec` is non-interactive, so there is no approval prompt — the
`--sandbox` mode bounds what Codex may touch. `workspace-write` lets it edit and
run commands within the workspace; use `danger-full-access` only inside an
isolated/container environment.

## Phase 5 — Verify delegated work independently (Claude)

**Never accept a delegate's summary as evidence.** A report is a claim about the
work. Your own re-run is the evidence. After Codex reports completion:

1. Inspect the actual diff.
2. Re-run every declared verification command **yourself**, in the same
   workspace. You run them — not Codex, not a re-read of `report.md`.
3. Check each process's exit code.
4. Compare the reported pass/fail counts against your actual output. A report
   saying `64/64 passed` against your own `61 passed, 3 failed` is a discrepancy,
   not a rounding difference.
5. Inspect every failure in a safety-critical test before doing anything else.

Then decide:

- All acceptance items pass under your own re-run → summarize and deliver.
- Any safety-critical item fails → **not done**, regardless of the rest. Go to
  Phase 6.
- Any other item fails, or the exit code / report signals "blocked" → Phase 6.

If Codex reported success but your verification failed, record the discrepancy
explicitly in your hint file and in what you tell the user. Do not ask Codex to
simply retry the same task before you have identified **why its report was
wrong** — a delegate that misreports once will misreport the retry.

## Phase 6 — Step in when Codex is stuck (Claude → Codex)

This is the key loop the user asked for.

1. **Classify the failure before writing anything.** Which layer is broken:
   the implementation, the fixture/test setup, the evaluator/harness, or the
   environment (OS, PATH, process resolution)? A hint aimed at the wrong layer
   burns an attempt. If you cannot classify it, that itself is the next task —
   delegate a narrow diagnostic, not another implementation.
2. Diagnose from `events.jsonl`, `stderr.log`, and the failing test output —
   find the actual cause.
3. Write a hint file `.codex-instructions/<task>.hint-N.md` containing: the root
   cause, concrete guidance, and the **minimal** path forward (not a redesign).
4. Continue Codex with the hint:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex_resume.sh" .codex-instructions/<task>.hint-N.md <workdir> <outdir>
   ```

5. Return to Phase 5. Cap the loop (default **3** attempts). If it is not
   improving after the cap, stop and escalate to the user with: what is failing,
   what you tried, and your recommendation.

**Never re-run an identical attempt.** Each resume must change something you can
name: a smaller scope, a newly identified cause, or a different layer. If nothing
changed, the retry is guaranteed to fail the same way.

**A timeout with no diff is not an implementation failure to retry unchanged.**
It means the task was too large or the delegate was blocked on something it could
not resolve. Shrink the task, supply the observed blocking condition, or take the
task back yourself. Re-issuing the same packet with a longer timeout is not a fix.

## Guardrails

- Never let Codex's report substitute for your own verification. The orchestrator
  runs the commands.
- Fail closed: when the mechanism that would prove correctness cannot itself be
  verified, produce no verdict rather than an optimistic one.
- Keep every task packet, report, and hint under version control so the
  hand-offs are auditable.
- Small tasks may be cheaper to do directly — delegating spends tokens on both
  sides. Delegate when the task is sizeable or benefits from Codex's coding.

## Keeping this skill reusable

When a delegation fails, resist adding the specific incident as a new rule here
("always ignore `__pycache__`", "in case-09, delete the temp body"). Case-specific
rules accumulate into a changelog and stop being a procedure anyone can follow.

Add a rule here only if it generalizes to an abstraction like these:

- isolate side effects the tooling itself produced from the fixture under test
- measure the audit path before evaluating anything through it
- verify a delegate's report independently
- classify a failure as implementation / fixture / evaluator / environment
- change the cause before retrying the same failure

Everything narrower belongs in the task packet for that task, not in this skill.
