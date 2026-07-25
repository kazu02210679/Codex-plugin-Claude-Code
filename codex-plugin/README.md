# codex-plugin

A Claude Code plugin that turns **Claude Code (or Fable) into the orchestrator**
and **OpenAI Codex into the implementer**.

- **Claude Code / Fable** — requirements, design direction, acceptance criteria,
  the instructions to Codex, and the final delivery judgment.
- **Codex** — code investigation, implementation design, implementation, tests,
  and result reporting.

Claude designs and directs; Codex implements (and does the technical design).
When Codex gets stuck, Claude diagnoses and feeds it a targeted hint, then
resumes it.

## How it works

Claude never becomes Codex. This plugin gives Claude a small, auditable way to
**shell out to `codex exec`** (Codex's headless mode) and get a report back:

```
requirements ─▶ acceptance criteria ─▶ plan: T1, T2, T3 (each with an allowlist)
                                            │
              ┌─────────────────────────────┴──────────────────────────────┐
              │  per task:                                                  │
              │    git preflight (branch, clean tree)                       │
              │    codex_run.sh          → attempt-1/report.md + events     │
              │    scope gate            → diff inside T<N>.allowlist?      │
              │    Claude verifies this task's acceptance checklist         │
              │    stuck ─▶ hint ─▶ codex_resume.sh ─▶ attempt-2 …  (cap 3) │
              │    codex_commit.sh       → tests green, then ONE commit     │
              └─────────────────────────────┬──────────────────────────────┘
                                            │
                        plan-level acceptance run on the finished branch
                                            │
                                         deliver
```

Work is split into tasks and committed one at a time because the orchestrator
has to verify every diff itself, and a plan-sized diff is not something anyone
verifies honestly. Small steps also mean a mistake surfaces while it is still
one commit deep.

Four gates are mechanical rather than advisory, because they guard the failures
a model reading a diff is worst at catching:

- **git preflight** — `codex_run.sh` refuses to start on the default branch or
  from a dirty tree. An unattended agent with write access is cheap to undo
  from a work branch and expensive to undo from `main`; and a dirty tree makes
  the scope gate meaningless, since pre-existing edits are indistinguishable
  from Codex's. Once the loop is running, a dirty tree also means the previous
  task never committed — the refusal says the loop is off the rails.
- **scope gate** — every changed file is matched against the task's allowlist.
  Exit code `3` means Codex succeeded but wandered outside it, so a green test
  run cannot hide an out-of-scope diff. The check reads the worktree and does
  not care who made the edit, so it also catches the orchestrator quietly
  fixing the code itself instead of sending a hint back.
- **commit gate** — `codex_commit.sh` runs the task's tests and refuses to
  commit unless they pass. One task, one commit; a task with no test command is
  an error rather than a free pass.
- **status from git** — progress is read back from `Codex-Task:` commit
  trailers, not from a status file or the orchestrator's memory. There is no
  second copy of the truth to drift, and a resumed session can ask where the
  plan stands instead of guessing.

## Install

This repo doubles as a Claude Code marketplace (see `.claude-plugin/marketplace.json`).

```
/plugin marketplace add kazu02210679/Codex-plugin-Claude-Code
/plugin install codex-plugin@kazu-drive
```

For local development you can instead point Claude Code at this directory
directly. After install, restart Claude Code so the commands/skill register.

## Prerequisites

- **Codex CLI** installed and on `PATH`, authenticated (`OPENAI_API_KEY` or
  `codex login`). Codex billing/auth is separate from Claude's.
- Verify flag names once with `codex exec --help`. The wrapper relies on:
  `--cd`, `--sandbox`, `--output-last-message`, `--json`, `-m`. If your version
  differs, adjust `scripts/codex_run.sh`. (`codex exec` is non-interactive, so
  there is no approval flag — the `--sandbox` mode governs what Codex may touch.)

## Usage

Slash commands (namespaced under the plugin):

| Command | Does |
|---|---|
| `/codex-spec <what you want>` | Draft the plan: requirements, scope, **verifiable acceptance criteria**, the task split, and a file allowlist per task. Writes `.codex-instructions/<plan>/`. |
| `/codex-run <plan dir> [workdir]` | Work the plan task by task: delegate → verify → stuck/hint/resume → commit. Also accepts a single packet file for a one-off. |
| `/codex-accept [plan] [rundir]` | Independent pass/fail delivery judgment against the acceptance criteria, the scope gate, and the commit history. |

Or just ask in natural language — the `codex-orchestration` skill triggers on
requests like "let Codex implement this and you review it."

### Scripts (called by the skill/commands)

```bash
# what is the next task? (reads git, not a status file)
scripts/codex_status.sh <plan_dir> <workdir>

# delegate one task
scripts/codex_run.sh <instruction_file> <workdir> [rundir]

# unblock a stuck run with a hint (adds attempt-N+1 to the same rundir)
scripts/codex_resume.sh <hint_file> <workdir> <rundir> [prev_report]

# test gate + scope gate + exactly one commit
scripts/codex_commit.sh <plan_dir> <task_id> <workdir> [rundir]

# check the diff against a task's allowlist (also runs standalone)
scripts/codex_scope_check.sh <allowlist_file> <workdir> [base_ref]
```

Exit codes: `0` clean, `2` usage/preflight error (nothing ran), `3` out of
scope — for `codex_run.sh`/`codex_resume.sh` anything else is Codex's own exit
code, and `codex_commit.sh` uses `1` for "tests failed or nothing changed, no
commit made". `codex_status.sh` returns `0` when the plan is finished and `3`
while tasks remain.

Env overrides: `CODEX_MODEL`, `CODEX_SANDBOX` (`read-only` | `workspace-write`
| `danger-full-access`, default `workspace-write`), `CODEX_EXTRA_ARGS`,
`CODEX_ALLOWLIST`, `CODEX_RESUME_MODE` (`auto` | `resume` | `fresh`, default
`auto`), `CODEX_ALLOW_DIRTY`, `CODEX_ALLOW_DEFAULT_BRANCH`.

### Run artifacts

```
<workdir>/.codex-runs/<timestamp>/
├── .gitignore          # `*` — run output is local evidence, not repo content
├── base_commit         # pre-run commit; the scope-check baseline
├── allowlist           # frozen copy of the task's allowlist
├── attempt-1/          # report.md, events.jsonl, stderr.log, meta.json, scope.txt
├── attempt-2/          # each hint→resume opens a new attempt
└── ...
```

Attempts are never overwritten. When the loop hits its cap and escalates, every
attempt's report and event stream is still on disk to explain what was tried —
which is the point of capping it at three rather than silently retrying.

### Plan directory

`/codex-spec` writes one of these; everything in it belongs in version control.

```
.codex-instructions/<plan>/
├── packet.md       plan-level requirement, scope, acceptance checklist
├── test            default test commands, one per line — the pre-commit gate
├── interfaces.md   contracts each finished task leaves for the next one
├── T1.md           instructions to Codex for task 1
├── T1.allowlist    the files task 1 may touch
├── T1.test         optional per-task test override (e.g. a fast subset)
├── T1.hint-1.md    written by the orchestrator when task 1 gets stuck
└── T2.md, T2.allowlist, ...
```

`interfaces.md` exists because each task is a separate `codex exec` with no
memory of the last one. When a task establishes a signature, type, endpoint,
config key or path that a later task will call, the orchestrator records it
there and quotes it into the later task's packet.

A task with no test command is refused rather than committed — a commit gate
with no tests is not a gate. Set `CODEX_ALLOW_NO_TESTS=1` for the genuinely
untestable task.

### Allowlist format

One glob per line; `#` comments and blank lines ignored. Patterns are matched
with bash `[[ str == glob ]]`, where `*` also matches `/` — so `src/api/*`
covers that whole subtree.

```
src/api/*
tests/test_api.py
# migrations are in scope for this task only
migrations/0007_*.py
```

## Safety notes

- `codex exec` runs non-interactively (no approval prompts); the `--sandbox`
  mode is what bounds Codex. The default `workspace-write` lets it edit files
  and run commands within the workspace. Use `read-only` to trial without
  writes, and avoid `danger-full-access` outside an isolated/container env.
  `--sandbox` bounds Codex at directory granularity; the allowlist is what
  bounds it at file granularity.
- Claude **always re-verifies** the acceptance criteria by actually running the
  checks; Codex's `report.md` is treated as a claim, not proof.
- `CODEX_ALLOW_DIRTY` and `CODEX_ALLOW_DEFAULT_BRANCH` exist for the cases the
  preflight cannot know about, not as the normal way past it. Reaching for
  either means the scope gate gets weaker or the blast radius gets wider.
- Delegating spends tokens on both Claude and Codex. Small tasks may be cheaper
  done directly.

## Optional: Codex as an MCP server

Codex can also run as an MCP server (`codex mcp`, experimental). You could add a
`.mcp.json` to expose it as a tool Claude calls directly. It is intentionally
left out of this plugin because non-interactive MCP tool approvals are currently
auto-cancelled in headless use, which makes the `codex exec` wrapper above the
more reliable path. Add it later if you want the tool-call ergonomics.

## Layout

```
codex-plugin/
├── .claude-plugin/plugin.json
├── commands/            # /codex-spec, /codex-run, /codex-accept
├── skills/codex-orchestration/SKILL.md
├── agents/codex-reviewer.md
├── scripts/             # run, resume, commit, status, scope_check
└── README.md
```

## Not covered

Branch creation, worktree isolation, push and PR opening are left to you. The
plugin refuses to run on the default branch but does not make the work branch
for you, and it commits per task but never pushes — so the finished branch is
yours to review before anything leaves the machine.
