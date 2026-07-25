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
#   codex_commit.sh <taskdir> <task_id> <workdir> <rundir>
#
# Args:
#   taskdir   The plan directory written by /codex-spec. Supplies the task
#             packet and the test commands.
#   task_id   e.g. T1. Recorded with the plan id as commit trailers so
#             codex_status.sh can reconstruct progress from git history alone.
#   workdir   The repository to test and commit in.
#   rundir    The run directory from codex_run.sh. Required, not optional: it
#             holds the pre-run commit and the frozen allowlist, without which
#             two of the three gates below cannot run at all.
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
#   CODEX_TEST_TIMEOUT    seconds per test command (default 900, 0 = off)
#
# Exit codes:
#   0  committed
#   1  tests failed, or nothing changed — no commit was made
#   2  usage / environment error
#   3  changed files outside the task's allowlist — no commit was made
#   5  HEAD moved during the task: something else committed — no commit made
#   6  the plan changed between the run and this commit — no commit was made
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex_lib.sh
. "$SCRIPT_DIR/codex_lib.sh"

die() { printf 'codex_commit: %s\n' "$1" >&2; exit 2; }
say() { printf 'codex_commit: %s\n' "$1" >&2; }

[ "$#" -ge 4 ] || die "usage: codex_commit.sh <taskdir> <task_id> <workdir> <rundir>"

TASKDIR="$1"
TASK_ID="$2"
WORKDIR="$3"
RUNDIR="$4"

[ -d "$TASKDIR" ] || die "task directory not found: $TASKDIR"
[ -d "$WORKDIR" ] || die "workdir not found: $WORKDIR"
[ -d "$RUNDIR" ]  || die "run directory not found: $RUNDIR"
git -C "$WORKDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not a git repository: $WORKDIR"

codex_require_hash || exit 2

TASK_MD="$TASKDIR/$TASK_ID.md"
[ -f "$TASK_MD" ] || die "task packet not found: $TASK_MD"

# Everything the task is judged against comes from the frozen copies taken
# before the run, never the plan's live files. Codex can reach the plan
# directory on disk; a task judged against an allowlist or a test command it
# could rewrite would not be judged at all.
ALLOWLIST="$RUNDIR/allowlist"
[ -f "$ALLOWLIST" ] || die "no frozen allowlist at $ALLOWLIST. codex_run.sh writes it — pass the run directory it printed, and give the task an allowlist."

PLAN_ID="$(codex_plan_id "$TASKDIR")"
CODEX_TEST_TIMEOUT="${CODEX_TEST_TIMEOUT:-900}"

# --- did the contract move between the run and this commit? -----------------
# The run-scoped fingerprint only covers Codex's execution. Nothing stops the
# plan being edited afterwards — which would commit work under a gate that is
# not the one it was run against.
drift=()
[ "$(codex_hash_file "$TASK_MD")" = "$(codex_hash_file "$RUNDIR/task.md")" ] \
  || drift+=("$TASK_ID.md")
[ "$(codex_hash_file "$TASKDIR/$TASK_ID.allowlist")" = "$(codex_hash_file "$ALLOWLIST")" ] \
  || drift+=("$TASK_ID.allowlist")
LIVE_TEST="$(codex_test_file "$TASKDIR" "$TASK_ID")"
[ "$(codex_hash_file "$LIVE_TEST")" = "$(codex_hash_file "$RUNDIR/test")" ] \
  || drift+=("test commands")

if [ "${#drift[@]}" -gt 0 ]; then
  say "the plan changed since this task was run: ${drift[*]}"
  say "Committing now would record the work under a different gate than the one it ran against. Re-run the task so the contract and the result match."
  exit 6
fi

# --- did anything else commit while the task ran? ---------------------------
# The whole point is one task, one commit. If Codex ran `git commit` itself, or
# a stray process did, HEAD has moved past the baseline and the diff this gate
# is about to judge is no longer the task's full change.
BASE_COMMIT=""
[ -f "$RUNDIR/base_commit" ] && BASE_COMMIT="$(tr -d '[:space:]' <"$RUNDIR/base_commit")"
CURRENT_HEAD="$(git -C "$WORKDIR" rev-parse HEAD 2>/dev/null || echo '')"
if [ -n "$BASE_COMMIT" ] && [ "$CURRENT_HEAD" != "$BASE_COMMIT" ]; then
  say "HEAD moved during $TASK_ID: expected $BASE_COMMIT, found $CURRENT_HEAD"
  say "Something committed mid-task — Codex must not create commits. Inspect the history and reset to the baseline before retrying."
  exit 5
fi

# --- is there anything to commit? -------------------------------------------
# A task that changed no product files means the run silently did nothing.
# Committing that would mark it done and move the loop on. Metadata is not
# counted: the plan directory is untracked for the whole first task, so a check
# over the whole worktree would never report an empty change.
if [ -z "$(codex_dirty_product "$WORKDIR" HEAD)" ]; then
  say "$TASK_ID changed no product files — refusing to record it as done"
  exit 1
fi

scope_gate() {
  local when="$1"
  if ! "$SCRIPT_DIR/codex_scope_check.sh" "$ALLOWLIST" "$WORKDIR" "$BASE_COMMIT" >&2; then
    say "$TASK_ID is out of scope ($when) — not committing"
    exit 3
  fi
}

scope_gate "before tests"

# --- resolve test commands --------------------------------------------------
# The frozen copy, matched against the live file above.
TESTFILE=""
[ -f "$RUNDIR/test" ] && TESTFILE="$RUNDIR/test"

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
    die "no test commands for $TASK_ID (codex_run.sh looked for $TASKDIR/$TASK_ID.test, then $TASKDIR/test). A commit gate with no tests is not a gate — add one and re-run the task, or set CODEX_ALLOW_NO_TESTS=1 if it genuinely has nothing to run."
  fi
  say "warning: committing $TASK_ID with no test gate (CODEX_ALLOW_NO_TESTS=1)"
fi

# --- test gate --------------------------------------------------------------
LOG="$RUNDIR/commit.log"
: >"$LOG"

record() { printf '%s\n' "$1" >>"$LOG"; printf '%s\n' "$1" >&2; }

TIMEOUT_CMD=()
while IFS= read -r t; do [ -n "$t" ] && TIMEOUT_CMD+=("$t"); done < <(codex_timeout_prefix "$CODEX_TEST_TIMEOUT")

if [ "${#commands[@]}" -gt 0 ]; then
  OUT="$(mktemp)"
  trap 'rm -f "$OUT"' EXIT
  for cmd in "${commands[@]}"; do
    record "--- $cmd"
    set +e
    ( cd "$WORKDIR" && "${TIMEOUT_CMD[@]}" bash -c "$cmd" ) >"$OUT" 2>&1 </dev/null
    RC=$?
    set -e
    cat "$OUT" >>"$LOG"
    tail -n 40 "$OUT" >&2
    if [ "$RC" -ne 0 ]; then
      [ "$RC" -eq 124 ] && record "TIMED OUT after ${CODEX_TEST_TIMEOUT}s: $cmd"
      record "FAILED (exit $RC): $cmd"
      say "test gate failed for $TASK_ID — not committing. Full output: $LOG"
      exit 1
    fi
  done
fi

# Tests routinely write files: coverage reports, snapshots, generated configs.
# Checking scope only before the run would let `git add -A` sweep those into
# the commit, so the gate runs again on the post-test tree.
scope_gate "after tests"

# --- commit -----------------------------------------------------------------
SUBJECT="${CODEX_COMMIT_MESSAGE:-}"
if [ -z "$SUBJECT" ]; then
  SUBJECT="$(grep -m1 '^# ' "$TASK_MD" 2>/dev/null | sed 's/^# *//' || true)"
  [ -n "$SUBJECT" ] || SUBJECT="$TASK_ID"
fi

# Stage exactly two things: the product files the scope gate just cleared, and
# this task's own plan directory. A repo-wide `git add -A` would contradict the
# gate — metadata is excluded from the scope check, so any OTHER plan's
# uncommitted files would be invisible to every check here and still land in
# this commit. Pathspecs with -A still catch deletions.
stage=()
while IFS= read -r f; do
  [ -n "$f" ] && stage+=("$f")
done < <(codex_dirty_product "$WORKDIR" HEAD)

WD_ABS="$(cd -- "$WORKDIR" && pwd)"
TD_ABS="$(cd -- "$TASKDIR" && pwd)"
case "$TD_ABS" in
  "$WD_ABS") ;;
  "$WD_ABS"/*) stage+=("${TD_ABS#"$WD_ABS"/}") ;;
  *) say "note: $TASKDIR is outside the repository — the plan will not be committed with the task" ;;
esac

git -C "$WORKDIR" add -A -- "${stage[@]}"
git -C "$WORKDIR" commit -q -F - <<EOF
$SUBJECT

Codex-Plan: $PLAN_ID
Codex-Task: $TASK_ID
Codex-Tests: ${#commands[@]} command(s) passed
EOF

SHA="$(git -C "$WORKDIR" rev-parse --short HEAD)"
say "$TASK_ID committed as $SHA (${#commands[@]} test command(s) green)"
printf '%s\n' "$SHA"
