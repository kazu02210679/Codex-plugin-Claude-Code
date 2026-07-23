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
requirements ─▶ acceptance criteria ─▶ task packet
                                            │
                          scripts/codex_run.sh  (codex exec, headless)
                                            │
                                        report.md + events.jsonl
                                            │
                    Claude verifies the acceptance checklist itself
                                            │
                    pass ─▶ deliver   |   stuck ─▶ hint ─▶ codex_resume.sh ─▶ …
```

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
| `/codex-spec <what you want>` | Draft the task packet: requirements, scope, **verifiable acceptance criteria**. Writes `.codex-instructions/<task>.md`. |
| `/codex-run <task packet> [workdir]` | Delegate to Codex, then verify the result and run the stuck→hint→resume loop. |
| `/codex-accept [packet] [outdir]` | Independent pass/fail delivery judgment against the acceptance criteria. |

Or just ask in natural language — the `codex-orchestration` skill triggers on
requests like "let Codex implement this and you review it."

### Scripts (called by the skill/commands)

```bash
# delegate
scripts/codex_run.sh <instruction_file> <workdir> [outdir]

# unblock a stuck run with a hint
scripts/codex_resume.sh <hint_file> <workdir> <outdir> [prev_report]
```

Env overrides: `CODEX_MODEL`, `CODEX_SANDBOX` (`read-only` | `workspace-write`
| `danger-full-access`, default `workspace-write`), `CODEX_EXTRA_ARGS`,
`CODEX_RESUME_MODE` (`resume` | `fresh`).

## Safety notes

- `codex exec` runs non-interactively (no approval prompts); the `--sandbox`
  mode is what bounds Codex. The default `workspace-write` lets it edit files
  and run commands within the workspace. Use `read-only` to trial without
  writes, and avoid `danger-full-access` outside an isolated/container env.
- Claude **always re-verifies** the acceptance criteria by actually running the
  checks; Codex's `report.md` is treated as a claim, not proof.
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
├── scripts/             # codex_run.sh, codex_resume.sh
└── README.md
```
