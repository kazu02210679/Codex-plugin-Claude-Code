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
#   codex_run.sh <instruction_file> <workdir> [rundir]
#
# Args:
#   instruction_file  Markdown/plain-text task packet written by Claude.
#   workdir           Repository/directory Codex is allowed to modify.
#   rundir            Where to store this task's artifacts. Default: a
#                     timestamped directory under <workdir>/.codex-runs/.
#
# Layout — every attempt gets its own directory, so the hint loop never
# overwrites the evidence from the attempt it is trying to fix:
#
#   <rundir>/attempt-1/report.md      Codex's final message == its result report
#   <rundir>/attempt-1/events.jsonl   full JSONL event stream
#   <rundir>/attempt-1/stderr.log     standard error
#   <rundir>/attempt-1/meta.json      run metadata (exit code, paths, commit)
#   <rundir>/attempt-1/scope.txt      allowlist verdict, when one applies
#   <rundir>/base_commit              pre-run commit; the scope-check baseline
#   <rundir>/allowlist                frozen copy of the allowlist for this task
#
# `codex_resume.sh` adds attempt-2, attempt-3, ... to the same <rundir>.
#
# Env overrides (all optional):
#   CODEX_MODEL       -> passed as `-m` (e.g. o4-mini, gpt-5-codex).
#   CODEX_SANDBOX     -> `--sandbox` value: read-only | workspace-write |
#                        danger-full-access. Default: workspace-write.
#   CODEX_EXTRA_ARGS  -> extra raw args appended to `codex exec`.
#   CODEX_ALLOWLIST   -> path to the file-scope allowlist. Default: the
#                        instruction file with .md replaced by .allowlist,
#                        when that file exists.
#   CODEX_ALLOW_DIRTY=1           -> skip the uncommitted-changes preflight.
#   CODEX_ALLOW_DEFAULT_BRANCH=1  -> allow running on the default branch.
#
# Exit codes:
#   0   Codex succeeded and stayed inside the allowlist
#   2   usage / preflight error (Codex was never started)
#   3   Codex succeeded but changed files outside the allowlist
#   *   otherwise, Codex's own exit code
#
# NOTE: `codex exec` is non-interactive, so there is no approval prompt; what
# Codex may read/write/run is governed entirely by `--sandbox`. The flag names
# below match the OpenAI Codex CLI as of this writing (verified against
# codex-cli 0.144.x). If your installed Codex differs, run `codex exec --help`
# and adjust. The four things this wrapper needs are: (1) a prompt, (2) a
# working directory, (3) sandbox level, (4) a way to capture the final
# message + JSON.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'codex_run: %s\n' "$1" >&2; exit 2; }

[ "$#" -ge 2 ] || die "usage: codex_run.sh <instruction_file> <workdir> [rundir]"

INSTRUCTION="$1"
WORKDIR="$2"
RUNDIR="${3:-"$WORKDIR/.codex-runs/$(date +%Y%m%d-%H%M%S)"}"

command -v codex >/dev/null 2>&1 || die "the 'codex' CLI is not installed or not on PATH. Install it and authenticate (OPENAI_API_KEY or 'codex login') first."
[ -f "$INSTRUCTION" ] || die "instruction file not found: $INSTRUCTION"
[ -d "$WORKDIR" ]     || die "workdir not found: $WORKDIR"

CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}"

# --- git preflight ----------------------------------------------------------
# Codex runs unattended with write access. Two states make that unsafe, and
# both also defeat the scope check, which diffs the worktree against the
# pre-run commit: working directly on the default branch, and starting from a
# dirty tree (pre-existing edits cannot be told apart from Codex's).
IS_GIT=0
BASE_COMMIT=""
BRANCH=""
if git -C "$WORKDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IS_GIT=1
  BRANCH="$(git -C "$WORKDIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"

  DEFAULT_BRANCH="$(git -C "$WORKDIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
  if [ -z "$DEFAULT_BRANCH" ]; then
    case "$BRANCH" in main|master) DEFAULT_BRANCH="$BRANCH" ;; *) DEFAULT_BRANCH="" ;; esac
  fi
  if [ -n "$DEFAULT_BRANCH" ] && [ "$BRANCH" = "$DEFAULT_BRANCH" ] \
     && [ "${CODEX_ALLOW_DEFAULT_BRANCH:-0}" != "1" ]; then
    die "refusing to run Codex on the default branch ('$BRANCH'). Create a work branch first, or set CODEX_ALLOW_DEFAULT_BRANCH=1."
  fi

  if [ -n "$(git -C "$WORKDIR" status --porcelain)" ] && [ "${CODEX_ALLOW_DIRTY:-0}" != "1" ]; then
    die "workdir has uncommitted changes. The scope check diffs against the pre-run commit, so pre-existing edits cannot be told apart from Codex's. Commit or stash first, or set CODEX_ALLOW_DIRTY=1."
  fi

  BASE_COMMIT="$(git -C "$WORKDIR" rev-parse HEAD 2>/dev/null || echo '')"
else
  printf 'codex_run: warning: %s is not a git repository — skipping branch, dirty-tree and scope checks\n' "$WORKDIR" >&2
fi

# --- resolve the allowlist --------------------------------------------------
ALLOWLIST="${CODEX_ALLOWLIST:-}"
if [ -z "$ALLOWLIST" ]; then
  CANDIDATE="${INSTRUCTION%.md}.allowlist"
  [ -f "$CANDIDATE" ] && ALLOWLIST="$CANDIDATE"
fi
[ -z "$ALLOWLIST" ] || [ -f "$ALLOWLIST" ] || die "allowlist not found: $ALLOWLIST"

ATTEMPT="$RUNDIR/attempt-1"
mkdir -p "$ATTEMPT"

# Make the run directory self-ignoring. Run artifacts are local evidence, not
# repository content — and an untracked .codex-runs/ would bury the very diff
# the orchestrator has to review.
printf '*\n' >"$RUNDIR/.gitignore"

printf '%s' "$BASE_COMMIT" >"$RUNDIR/base_commit"
[ -z "$ALLOWLIST" ] || cp "$ALLOWLIST" "$RUNDIR/allowlist"

# Build args as an array so quoting is safe.
args=(exec
  --cd "$WORKDIR"
  --sandbox "$CODEX_SANDBOX"
  --output-last-message "$ATTEMPT/report.md"
  --json
)
[ -n "${CODEX_MODEL:-}" ] && args+=(-m "$CODEX_MODEL")
# shellcheck disable=SC2206
[ -n "${CODEX_EXTRA_ARGS:-}" ] && args+=(${CODEX_EXTRA_ARGS})

printf 'codex_run: starting Codex\n  workdir : %s\n  branch  : %s\n  sandbox : %s\n  attempt : %s\n  scope   : %s\n' \
  "$WORKDIR" "${BRANCH:-n/a}" "$CODEX_SANDBOX" "$ATTEMPT" "${ALLOWLIST:-(none)}" >&2

set +e
codex "${args[@]}" "$(cat "$INSTRUCTION")" \
  >"$ATTEMPT/events.jsonl" 2>"$ATTEMPT/stderr.log"
RC=$?
set -e

[ -f "$ATTEMPT/report.md" ] || printf '(no final message captured; see stderr.log)\n' >"$ATTEMPT/report.md"

# --- scope gate -------------------------------------------------------------
SCOPE_RC=0
if [ -n "$ALLOWLIST" ] && [ "$IS_GIT" = "1" ]; then
  set +e
  "$SCRIPT_DIR/codex_scope_check.sh" "$ALLOWLIST" "$WORKDIR" "$BASE_COMMIT" \
    >"$ATTEMPT/scope.txt" 2>&1
  SCOPE_RC=$?
  set -e
  cat "$ATTEMPT/scope.txt" >&2
fi

cat >"$ATTEMPT/meta.json" <<JSON
{
  "instruction": "$INSTRUCTION",
  "workdir": "$WORKDIR",
  "rundir": "$RUNDIR",
  "attempt": 1,
  "branch": "$BRANCH",
  "base_commit": "$BASE_COMMIT",
  "allowlist": "${ALLOWLIST:-}",
  "scope_ok": $([ "$SCOPE_RC" -eq 0 ] && echo true || echo false),
  "sandbox": "$CODEX_SANDBOX",
  "model": "${CODEX_MODEL:-default}",
  "exit_code": $RC,
  "finished_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

printf 'codex_run: done (exit=%s)\n  RUNDIR: %s\n  REPORT: %s\n  EVENTS: %s\n  META  : %s\n' \
  "$RC" "$RUNDIR" "$ATTEMPT/report.md" "$ATTEMPT/events.jsonl" "$ATTEMPT/meta.json" >&2

# A clean Codex exit with an out-of-scope diff is still a failure — surface it
# distinctly so the orchestrator never reads exit 0 as "ready to accept".
if [ "$RC" -eq 0 ] && [ "$SCOPE_RC" -ne 0 ]; then
  exit 3
fi
exit "$RC"
