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
#   <rundir>/task.md                  ┐ the frozen contract — the gates read
#   <rundir>/allowlist                ├ THESE, never the plan's live files
#   <rundir>/test                     ┘
#   <rundir>/plan_dir                 which plan this run belongs to
#   <rundir>/thread_id                session id for a targeted resume
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
#   CODEX_INTERFACES  -> contracts file injected into the prompt. Default:
#                        interfaces.md beside the instruction file. Set to the
#                        empty string to inject nothing.
#   CODEX_TIMEOUT     -> seconds before Codex is killed. Default 3600, 0 = off.
#   CODEX_META_DIR    -> orchestration metadata, workdir-relative.
#                        Default .codex-instructions.
#   CODEX_ALLOW_DIRTY=1           -> skip the uncommitted-changes preflight.
#   CODEX_ALLOW_DEFAULT_BRANCH=1  -> allow running on the default branch.
#
# Exit codes:
#   0   Codex succeeded and stayed inside the allowlist
#   2   usage / preflight error (Codex was never started)
#   3   Codex succeeded but changed files outside the allowlist
#   4   Codex modified orchestration metadata (it must never do this)
#   *   otherwise, Codex's own exit code
#
# NOTE ON CODEX CLI FLAGS: `codex exec` is non-interactive, so there is no
# approval prompt; what Codex may read/write/run is governed entirely by
# `--sandbox`. This wrapper needs four things from the CLI: a prompt, a working
# directory, a sandbox level, and a way to capture the final message + JSON.
# Flags verified against codex-cli 0.144.6 — if your installed version's
# `codex exec --help` disagrees, adjust the flags below to match.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex_lib.sh
. "$SCRIPT_DIR/codex_lib.sh"

die() { printf 'codex_run: %s\n' "$1" >&2; exit 2; }

[ "$#" -ge 2 ] || die "usage: codex_run.sh <instruction_file> <workdir> [rundir]"

INSTRUCTION="$1"
WORKDIR="$2"
RUNDIR="${3:-}"

command -v codex >/dev/null 2>&1 || die "the 'codex' CLI is not installed or not on PATH. Install it and authenticate (OPENAI_API_KEY or 'codex login') first."
codex_require_hash || exit 2
[ -f "$INSTRUCTION" ] || die "instruction file not found: $INSTRUCTION"
[ -d "$WORKDIR" ]     || die "workdir not found: $WORKDIR"

CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}"
CODEX_TIMEOUT="${CODEX_TIMEOUT:-3600}"
PLAN_DIR="$(cd -- "$(dirname -- "$INSTRUCTION")" && pwd)"

# The integrity check watches the plan directory — but only when the packet
# really lives in one. A one-off packet kept somewhere else has no plan to
# protect, and fingerprinting whatever directory it happens to sit in would
# hash unrelated files (possibly the workspace itself) and fail every run.
PLAN_WATCH=""
case "$PLAN_DIR" in
  "$(cd -- "$WORKDIR" && pwd)/$CODEX_META_DIR"|"$(cd -- "$WORKDIR" && pwd)/$CODEX_META_DIR"/*)
    PLAN_WATCH="$PLAN_DIR" ;;
esac

# --- resolve the allowlist --------------------------------------------------
ALLOWLIST="${CODEX_ALLOWLIST:-}"
if [ -z "$ALLOWLIST" ]; then
  CANDIDATE="${INSTRUCTION%.md}.allowlist"
  [ -f "$CANDIDATE" ] && ALLOWLIST="$CANDIDATE"
fi
[ -z "$ALLOWLIST" ] || [ -f "$ALLOWLIST" ] || die "allowlist not found: $ALLOWLIST"

# --- git preflight ----------------------------------------------------------
# Codex runs unattended with write access. Two states make that unsafe, and
# both also defeat the scope check, which diffs the worktree against the
# pre-run commit: working directly on the default branch, and starting from a
# dirty tree (pre-existing edits cannot be told apart from Codex's).
#
# Orchestration metadata is exempt. The plan, hints and interfaces file are
# written by the orchestrator as the loop runs — holding them to "commit before
# every task" would mean the very first task could never start.
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

  if [ "${CODEX_ALLOW_DIRTY:-0}" != "1" ]; then
    dirty=()
    while IFS= read -r f; do
      [ -n "$f" ] && dirty+=("$f")
    done < <(codex_dirty_product "$WORKDIR" HEAD)
    if [ "${#dirty[@]}" -gt 0 ]; then
      printf 'codex_run: uncommitted product changes:\n' >&2
      printf '  %s\n' "${dirty[@]}" >&2
      die "workdir has uncommitted product changes. The scope check diffs against the pre-run commit, so pre-existing edits cannot be told apart from Codex's. Commit or stash first, or set CODEX_ALLOW_DIRTY=1. (Changes under $CODEX_META_DIR/ are exempt and were ignored.)"
    fi
  fi

  BASE_COMMIT="$(git -C "$WORKDIR" rev-parse HEAD 2>/dev/null || echo '')"
else
  # Without git there is no scope gate and no commit gate. Fine for a one-off
  # experiment; not fine for a task that declared a scope it expects enforced.
  [ -z "$ALLOWLIST" ] || die "$WORKDIR is not a git repository, but this task has an allowlist ($ALLOWLIST). The scope gate needs git — initialise a repository, or drop the allowlist to acknowledge the task runs unguarded."
  printf 'codex_run: warning: %s is not a git repository — no branch, dirty-tree or scope checks\n' "$WORKDIR" >&2
fi

# --- open the run directory -------------------------------------------------
# A timestamp to the second is not a unique name. Two tasks started in the same
# second — or a stale directory passed back by mistake — would share one run
# directory, and the second run would overwrite the first's frozen contract and
# attempt-1 while both were still using them. `mktemp -d` keeps the sortable
# timestamp and makes the name collision-proof.
if [ -z "$RUNDIR" ]; then
  mkdir -p "$WORKDIR/.codex-runs"
  RUNDIR="$(mktemp -d "$WORKDIR/.codex-runs/$(date +%Y%m%d-%H%M%S)-XXXXXX")"
elif [ -e "$RUNDIR" ] && [ -n "$(ls -A "$RUNDIR" 2>/dev/null)" ]; then
  die "run directory already exists and is not empty: $RUNDIR. Starting here would overwrite that run's frozen contract and its attempts. Pass a new path, or omit the argument to get a fresh one."
fi

ATTEMPT="$RUNDIR/attempt-1"
mkdir -p "$ATTEMPT"

# Make the run directory self-ignoring. Run artifacts are local evidence, not
# repository content — and an untracked .codex-runs/ would bury the very diff
# the orchestrator has to review.
printf '*\n' >"$RUNDIR/.gitignore"

printf '%s' "$BASE_COMMIT" >"$RUNDIR/base_commit"

# --- freeze the contract ----------------------------------------------------
# The gates read these copies, never the plan's live files. Codex can reach the
# plan directory on disk, and a task judged against an allowlist or a test
# command it could rewrite mid-run is not judged at all. Freezing all three
# also lets codex_commit.sh detect the plan being edited between the run and
# the commit, which the run-scoped fingerprint below cannot see.
cp "$INSTRUCTION" "$RUNDIR/task.md"
[ -z "$ALLOWLIST" ] || cp "$ALLOWLIST" "$RUNDIR/allowlist"
# Recorded so codex_resume.sh fingerprints the same plan rather than guessing.
printf '%s' "$PLAN_DIR" >"$RUNDIR/plan_dir"

TASK_ID="$(basename "$INSTRUCTION" .md)"
FROZEN_TEST="$(codex_test_file "$PLAN_DIR" "$TASK_ID")"
if [ -n "$FROZEN_TEST" ]; then
  cp "$FROZEN_TEST" "$RUNDIR/test"
  printf '%s' "$FROZEN_TEST" >"$RUNDIR/test_source"
fi

# --- assemble the prompt ----------------------------------------------------
# Each task is a separate `codex exec` with no memory of the last one, so
# whatever earlier tasks established has to be handed over explicitly. Doing it
# here rather than by editing T<N>.md keeps the packets stable and avoids
# dirtying the plan mid-loop.
INTERFACES="${CODEX_INTERFACES-$PLAN_DIR/interfaces.md}"
PROMPT="$(cat "$INSTRUCTION")"
if [ -n "$INTERFACES" ] && [ -s "$INTERFACES" ]; then
  PROMPT="$PROMPT

## Verified interfaces from completed tasks

These are established contracts. Call them as written; do not redesign them,
and do not re-implement what they already provide.

$(cat "$INTERFACES")"
fi

META_BEFORE=""
[ -n "$PLAN_WATCH" ] && META_BEFORE="$(codex_meta_fingerprint "$PLAN_WATCH")"

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

TIMEOUT_CMD=()
while IFS= read -r t; do [ -n "$t" ] && TIMEOUT_CMD+=("$t"); done < <(codex_timeout_prefix "$CODEX_TIMEOUT")

printf 'codex_run: starting Codex\n  workdir : %s\n  branch  : %s\n  sandbox : %s\n  attempt : %s\n  scope   : %s\n  timeout : %s\n' \
  "$WORKDIR" "${BRANCH:-n/a}" "$CODEX_SANDBOX" "$ATTEMPT" "${ALLOWLIST:-(none)}" \
  "${TIMEOUT_CMD:+${CODEX_TIMEOUT}s}${TIMEOUT_CMD:-none}" >&2

# stdin is closed: with a prompt argument present, Codex appends anything piped
# on stdin to the prompt, so an inherited pipe would silently corrupt the task.
set +e
"${TIMEOUT_CMD[@]}" codex "${args[@]}" "$PROMPT" \
  >"$ATTEMPT/events.jsonl" 2>"$ATTEMPT/stderr.log" </dev/null
RC=$?
set -e
[ "$RC" -eq 124 ] && printf 'codex_run: Codex hit the %ss timeout\n' "$CODEX_TIMEOUT" >&2

[ -f "$ATTEMPT/report.md" ] || printf '(no final message captured; see stderr.log)\n' >"$ATTEMPT/report.md"

# Record the session id so the hint loop can resume THIS run rather than
# whatever session happened to be most recent on the machine.
codex_thread_id "$ATTEMPT/events.jsonl" >"$RUNDIR/thread_id"

# --- metadata integrity -----------------------------------------------------
META_OK=true
if [ -n "$PLAN_WATCH" ] && [ "$META_BEFORE" != "$(codex_meta_fingerprint "$PLAN_WATCH")" ]; then
  META_OK=false
  printf 'codex_run: FAIL — Codex modified the plan directory during the run:\n  %s\n' "$PLAN_DIR" >&2
  printf '  The plan, the allowlist and the hints are the contract Codex is judged against;\n' >&2
  printf '  a run that edits them can widen its own scope. Inspect the diff before continuing.\n' >&2
fi

# --- scope gate -------------------------------------------------------------
SCOPE_RC=0
if [ -n "$ALLOWLIST" ] && [ "$IS_GIT" = "1" ]; then
  set +e
  "$SCRIPT_DIR/codex_scope_check.sh" "$RUNDIR/allowlist" "$WORKDIR" "$BASE_COMMIT" \
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
  "interfaces_injected": $([ -n "$INTERFACES" ] && [ -s "$INTERFACES" ] && echo true || echo false),
  "meta_intact": $META_OK,
  "scope_ok": $([ "$SCOPE_RC" -eq 0 ] && echo true || echo false),
  "sandbox": "$CODEX_SANDBOX",
  "model": "${CODEX_MODEL:-default}",
  "exit_code": $RC,
  "finished_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

printf 'codex_run: done (exit=%s)\n  RUNDIR: %s\n  REPORT: %s\n  EVENTS: %s\n  META  : %s\n' \
  "$RC" "$RUNDIR" "$ATTEMPT/report.md" "$ATTEMPT/events.jsonl" "$ATTEMPT/meta.json" >&2

# Tampering outranks everything: if the contract moved, no other verdict here
# can be trusted.
[ "$META_OK" = "true" ] || exit 4
# A clean Codex exit with an out-of-scope diff is still a failure — surface it
# distinctly so the orchestrator never reads exit 0 as "ready to accept".
if [ "$RC" -eq 0 ] && [ "$SCOPE_RC" -ne 0 ]; then
  exit 3
fi
exit "$RC"
