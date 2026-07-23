#!/usr/bin/env bash
#
# codex_run.sh — hand an implementation task to OpenAI Codex (headless).
#
# Claude Code (the orchestrator) writes an instruction file, then calls this
# script. Codex does the code investigation / design / implementation / tests
# and writes back a report. Nothing here is Claude-specific: it is a thin,
# auditable wrapper around `codex exec`.
#
# Usage:
#   codex_run.sh <instruction_file> <workdir> [outdir]
#
# Args:
#   instruction_file  Markdown/plain-text task packet written by Claude.
#   workdir           Repository/directory Codex is allowed to modify.
#   outdir            Where to store the run artifacts. Default: a timestamped
#                     directory under <workdir>/.codex-runs/.
#
# Outputs (inside outdir):
#   report.md     Codex's final message == its result report.
#   events.jsonl  Full JSONL event stream (for debugging / stuck-detection).
#   stderr.log    Standard error.
#   meta.json     Run metadata (exit code, paths, timestamps).
#
# Env overrides (all optional):
#   CODEX_MODEL      -> passed as `-m` (e.g. o4-mini, gpt-5-codex).
#   CODEX_SANDBOX    -> `--sandbox` value: read-only | workspace-write |
#                       danger-full-access. Default: workspace-write.
#   CODEX_EXTRA_ARGS -> extra raw args appended to `codex exec`.
#
# NOTE: `codex exec` is non-interactive, so there is no approval prompt; what
# Codex may read/write/run is governed entirely by `--sandbox`. The flag names
# below match the OpenAI Codex CLI as of this writing (verified against
# codex-cli 0.144.x). If your installed Codex differs, run `codex exec --help`
# and adjust. The four things this wrapper needs are: (1) a prompt, (2) a
# working directory, (3) sandbox level, (4) a way to capture the final
# message + JSON.
set -euo pipefail

die() { printf 'codex_run: %s\n' "$1" >&2; exit 2; }

[ "$#" -ge 2 ] || die "usage: codex_run.sh <instruction_file> <workdir> [outdir]"

INSTRUCTION="$1"
WORKDIR="$2"
OUTDIR="${3:-"$WORKDIR/.codex-runs/$(date +%Y%m%d-%H%M%S)"}"

command -v codex >/dev/null 2>&1 || die "the 'codex' CLI is not installed or not on PATH. Install it and authenticate (OPENAI_API_KEY or 'codex login') first."
[ -f "$INSTRUCTION" ] || die "instruction file not found: $INSTRUCTION"
[ -d "$WORKDIR" ]     || die "workdir not found: $WORKDIR"

CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}"

mkdir -p "$OUTDIR"

# Build args as an array so quoting is safe.
args=(exec
  --cd "$WORKDIR"
  --sandbox "$CODEX_SANDBOX"
  --output-last-message "$OUTDIR/report.md"
  --json
)
[ -n "${CODEX_MODEL:-}" ] && args+=(-m "$CODEX_MODEL")
# shellcheck disable=SC2206
[ -n "${CODEX_EXTRA_ARGS:-}" ] && args+=(${CODEX_EXTRA_ARGS})

printf 'codex_run: starting Codex\n  workdir : %s\n  sandbox : %s\n  outdir  : %s\n' \
  "$WORKDIR" "$CODEX_SANDBOX" "$OUTDIR" >&2

set +e
codex "${args[@]}" "$(cat "$INSTRUCTION")" \
  >"$OUTDIR/events.jsonl" 2>"$OUTDIR/stderr.log"
RC=$?
set -e

cat >"$OUTDIR/meta.json" <<JSON
{
  "instruction": "$INSTRUCTION",
  "workdir": "$WORKDIR",
  "sandbox": "$CODEX_SANDBOX",
  "model": "${CODEX_MODEL:-default}",
  "exit_code": $RC,
  "finished_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

[ -f "$OUTDIR/report.md" ] || printf '(no final message captured; see stderr.log)\n' >"$OUTDIR/report.md"

printf 'codex_run: done (exit=%s)\n  REPORT: %s\n  EVENTS: %s\n  META  : %s\n' \
  "$RC" "$OUTDIR/report.md" "$OUTDIR/events.jsonl" "$OUTDIR/meta.json" >&2

# Propagate Codex's exit code so the orchestrator can detect failure.
exit "$RC"
