#!/usr/bin/env bash
#
# codex_commit.sh — close out one task: scope gate, test gate, then one commit.
#
# This is the gate that makes "one task, one commit, tests green before each
# one" mechanical instead of aspirational. It does not decide whether the task
# is done — the orchestrator does that by verifying the acceptance checklist.
# It decides whether the work is *committable*, and refuses when it is not.
#
# Nothing here runs Codex. It is called after codex_run.sh (and any hint loop)
# has left the worktree in the state the orchestrator wants to freeze.
#
# Usage:
#   codex_commit.sh <taskdir> <task_id> <workdir> [rundir]
#
# Args:
#   taskdir   The task directory written by /codex-spec. Supplies
#             <task_id>.allowlist, and the test commands (see below).
#   task_id   e.g. T1. Recorded as a `Codex-Task:` trailer so codex_status.sh
#             can reconstruct progress from git history alone.
#   workdir   The repository to test and commit in.
#   rundir    Optional. When given, the test output is saved to
#             <rundir>/commit.log as evidence for the review.
#
# Test commands, one per line, `#` comments ignored. First match wins:
#   <taskdir>/<task_id>.test   per-task override (e.g. a fast subset)
#   <taskdir>/test             the plan's default suite
# A commit gate with no tests is not a gate, so a missing file is an error.
# Set CODEX_ALLOW_NO_TESTS=1 for the genuinely untestable task (docs, config).
#
# Env:
#   CODEX_COMMIT_MESSAGE  override the subject line (default: the task's title)
#   CODEX_ALLOW_NO_TESTS=1  commit without a test gate
#
# Exit codes:
#   0  committed
#   1  tests failed, or nothing changed — no commit was made
#   2  usage / environment error
#   3  changed files outside the task's allowlist — no commit was made
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'codex_commit: %s\n' "$1" >&2; exit 2; }
say() { printf 'codex_commit: %s\n' "$1" >&2; }

[ "$#" -ge 3 ] || die "usage: codex_commit.sh <taskdir> <task_id> <workdir> [rundir]"

TASKDIR="$1"
TASK_ID="$2"
WORKDIR="$3"
RUNDIR="${4:-}"

[ -d "$TASKDIR" ] || die "task directory not found: $TASKDIR"
[ -d "$WORKDIR" ] || die "workdir not found: $WORKDIR"
git -C "$WORKDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not a git repository: $WORKDIR"

TASK_MD="$TASKDIR/$TASK_ID.md"
ALLOWLIST="$TASKDIR/$TASK_ID.allowlist"
[ -f "$TASK_MD" ]   || die "task packet not found: $TASK_MD"
[ -f "$ALLOWLIST" ] || die "allowlist not found: $ALLOWLIST"

# --- is there anything to commit? -------------------------------------------
# A task that changed nothing means the run silently did nothing. Committing an
# empty change would mark it done and move the loop on.
if [ -z "$(git -C "$WORKDIR" status --porcelain)" ]; then
  say "$TASK_ID changed nothing — refusing to record it as done"
  exit 1
fi

# --- scope gate -------------------------------------------------------------
# Re-checked here rather than trusted from codex_run.sh: the hint loop, and the
# orchestrator itself, may have touched the tree since.
BASE="$(git -C "$WORKDIR" rev-parse HEAD 2>/dev/null || echo '')"
if ! "$SCRIPT_DIR/codex_scope_check.sh" "$ALLOWLIST" "$WORKDIR" "$BASE" >&2; then
  say "$TASK_ID is out of scope — not committing"
  exit 3
fi

# --- resolve test commands --------------------------------------------------
TESTFILE=""
if   [ -f "$TASKDIR/$TASK_ID.test" ]; then TESTFILE="$TASKDIR/$TASK_ID.test"
elif [ -f "$TASKDIR/test" ];          then TESTFILE="$TASKDIR/test"
fi

commands=()
if [ -n "$TESTFILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    commands+=("$line")
  done <"$TESTFILE"
fi

if [ "${#commands[@]}" -eq 0 ]; then
  if [ "${CODEX_ALLOW_NO_TESTS:-0}" != "1" ]; then
    die "no test commands for $TASK_ID (looked for $TASKDIR/$TASK_ID.test, $TASKDIR/test). A commit gate with no tests is not a gate — add one, or set CODEX_ALLOW_NO_TESTS=1 if this task genuinely has nothing to run."
  fi
  say "warning: committing $TASK_ID with no test gate (CODEX_ALLOW_NO_TESTS=1)"
fi

# --- test gate --------------------------------------------------------------
LOG=""
if [ -n "$RUNDIR" ]; then
  mkdir -p "$RUNDIR"
  LOG="$RUNDIR/commit.log"
  : >"$LOG"
fi

record() {
  [ -n "$LOG" ] && printf '%s\n' "$1" >>"$LOG"
  printf '%s\n' "$1" >&2
}

if [ "${#commands[@]}" -gt 0 ]; then
  OUT="$(mktemp)"
  trap 'rm -f "$OUT"' EXIT
  for cmd in "${commands[@]}"; do
    record "--- $cmd"
    set +e
    ( cd "$WORKDIR" && bash -c "$cmd" ) >"$OUT" 2>&1
    RC=$?
    set -e
    [ -n "$LOG" ] && cat "$OUT" >>"$LOG"
    tail -n 40 "$OUT" >&2
    if [ "$RC" -ne 0 ]; then
      record "FAILED (exit $RC): $cmd"
      say "test gate failed for $TASK_ID — not committing.${LOG:+ Full output: $LOG}"
      exit 1
    fi
  done
fi

# --- commit -----------------------------------------------------------------
SUBJECT="${CODEX_COMMIT_MESSAGE:-}"
if [ -z "$SUBJECT" ]; then
  SUBJECT="$(grep -m1 '^# ' "$TASK_MD" 2>/dev/null | sed 's/^# *//' || true)"
  [ -n "$SUBJECT" ] || SUBJECT="$TASK_ID"
fi

# Scope is clean, so `-A` can only stage allowlisted paths — and it catches
# deletions, which an explicit add of the allowlist would miss.
git -C "$WORKDIR" add -A
git -C "$WORKDIR" commit -q -F - <<EOF
$SUBJECT

Codex-Task: $TASK_ID
Codex-Tests: ${#commands[@]} command(s) passed
EOF

SHA="$(git -C "$WORKDIR" rev-parse --short HEAD)"
say "$TASK_ID committed as $SHA (${#commands[@]} test command(s) green)"
printf '%s\n' "$SHA"
