#!/usr/bin/env bash
#
# codex_resume.sh — feed Codex a follow-up hint when it got stuck.
#
# This is the "Claude steps in with an opinion" step. Claude reads Codex's
# previous report + failing logs, writes a hint file (root cause + concrete
# guidance + a minimal path forward), and calls this script to continue.
#
# Each call lands in a NEW attempt directory under the same <rundir>, so the
# evidence from the attempt being fixed survives. When the loop gives up and
# escalates, every attempt is still on disk to explain what was tried.
#
# Continuation mode is decided BEFORE spending a run:
#   auto   (default) probe `codex exec resume --help`; use native session
#          continuation when the installed CLI supports it, otherwise fresh.
#   resume force native continuation; a failure is reported as-is.
#   fresh  run a fresh `codex exec` whose prompt carries the previous report
#          and the hint — portable, no session state needed.
#
# Usage:
#   codex_resume.sh <hint_file> <workdir> <rundir> [prev_report]
#
# Args:
#   hint_file    Root cause + minimal guidance, written by the orchestrator.
#   workdir      Repository/directory Codex may modify.
#   rundir       The run directory printed by codex_run.sh (contains attempt-N).
#   prev_report  Override the report fed back to Codex. Default: the previous
#                attempt's report.md.
#
# Env:
#   CODEX_RESUME_MODE  auto|resume|fresh  (default: auto)
#   plus the same overrides as codex_run.sh (CODEX_MODEL, CODEX_SANDBOX,
#   CODEX_ALLOWLIST, ...).
#
# Exit codes: same contract as codex_run.sh (0 ok, 2 usage, 3 out of scope,
# otherwise Codex's own exit code).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'codex_resume: %s\n' "$1" >&2; exit 2; }

[ "$#" -ge 3 ] || die "usage: codex_resume.sh <hint_file> <workdir> <rundir> [prev_report]"

HINT="$1"
WORKDIR="$2"
RUNDIR="$3"

command -v codex >/dev/null 2>&1 || die "the 'codex' CLI is not installed or not on PATH."
[ -f "$HINT" ]    || die "hint file not found: $HINT"
[ -d "$WORKDIR" ] || die "workdir not found: $WORKDIR"
[ -d "$RUNDIR" ]  || die "run directory not found: $RUNDIR (pass the RUNDIR printed by codex_run.sh)"

# --- locate the previous attempt, open the next one -------------------------
LAST_N=0
for d in "$RUNDIR"/attempt-*; do
  [ -d "$d" ] || continue
  n="${d##*/attempt-}"
  case "$n" in ''|*[!0-9]*) continue ;; esac
  [ "$n" -gt "$LAST_N" ] && LAST_N="$n"
done
[ "$LAST_N" -gt 0 ] || die "no attempt-N directory under $RUNDIR — run codex_run.sh first"

PREV="$RUNDIR/attempt-$LAST_N"
N=$((LAST_N + 1))
ATTEMPT="$RUNDIR/attempt-$N"
PREV_REPORT="${4:-$PREV/report.md}"
mkdir -p "$ATTEMPT"

# The scope baseline is the pre-run commit of attempt 1: scope is judged over
# the whole task, not just this attempt's incremental edits.
BASE_COMMIT=""
[ -f "$RUNDIR/base_commit" ] && BASE_COMMIT="$(cat "$RUNDIR/base_commit")"

ALLOWLIST="${CODEX_ALLOWLIST:-}"
if [ -z "$ALLOWLIST" ] && [ -f "$RUNDIR/allowlist" ]; then
  ALLOWLIST="$RUNDIR/allowlist"
fi

CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}"
CODEX_RESUME_MODE="${CODEX_RESUME_MODE:-auto}"

common=(--cd "$WORKDIR" --sandbox "$CODEX_SANDBOX"
        --output-last-message "$ATTEMPT/report.md" --json)
[ -n "${CODEX_MODEL:-}" ] && common+=(-m "$CODEX_MODEL")

run_resume() {
  codex exec resume --last "${common[@]}" "$(cat "$HINT")"
}

run_fresh() {
  local prompt
  prompt="You are continuing a task you did not finish. Before doing anything,
re-read your previous report and the failing logs, then apply the guidance below.

## Your previous report
$( [ -f "$PREV_REPORT" ] && cat "$PREV_REPORT" || echo '(none)')

## Guidance from the orchestrator
$(cat "$HINT")

Do not restart from scratch or make large unrequested changes. Make the minimal
change that unblocks the task, re-run the tests, and report what you did."
  codex exec "${common[@]}" "$prompt"
}

# --- pick the mode up front -------------------------------------------------
# Deciding by probing the CLI (rather than pattern-matching stderr after a
# failed run) keeps a plain task failure from being misread as "resume is
# unsupported" and silently charged for a second, redundant run.
case "$CODEX_RESUME_MODE" in
  fresh)  MODE=fresh ;;
  resume) MODE=resume ;;
  auto)
    if codex exec resume --help >/dev/null 2>&1; then
      MODE=resume
    else
      MODE=fresh
      printf 'codex_resume: this Codex CLI has no `exec resume` — using fresh mode\n' >&2
    fi
    ;;
  *) die "unknown CODEX_RESUME_MODE: '$CODEX_RESUME_MODE' (expected auto|resume|fresh)" ;;
esac

printf 'codex_resume: continuing from attempt-%s\n  hint    : %s\n  mode    : %s\n  attempt : %s\n  scope   : %s\n' \
  "$LAST_N" "$HINT" "$MODE" "$ATTEMPT" "${ALLOWLIST:-(none)}" >&2

set +e
if [ "$MODE" = "fresh" ]; then
  run_fresh  >"$ATTEMPT/events.jsonl" 2>"$ATTEMPT/stderr.log"
else
  run_resume >"$ATTEMPT/events.jsonl" 2>"$ATTEMPT/stderr.log"
fi
RC=$?
set -e

[ -f "$ATTEMPT/report.md" ] || printf '(no final message captured; see stderr.log)\n' >"$ATTEMPT/report.md"

# --- scope gate -------------------------------------------------------------
SCOPE_RC=0
if [ -n "$ALLOWLIST" ] && git -C "$WORKDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  set +e
  "$SCRIPT_DIR/codex_scope_check.sh" "$ALLOWLIST" "$WORKDIR" "$BASE_COMMIT" \
    >"$ATTEMPT/scope.txt" 2>&1
  SCOPE_RC=$?
  set -e
  cat "$ATTEMPT/scope.txt" >&2
fi

cat >"$ATTEMPT/meta.json" <<JSON
{
  "hint": "$HINT",
  "workdir": "$WORKDIR",
  "rundir": "$RUNDIR",
  "attempt": $N,
  "resumed_from": $LAST_N,
  "mode": "$MODE",
  "base_commit": "$BASE_COMMIT",
  "allowlist": "${ALLOWLIST:-}",
  "scope_ok": $([ "$SCOPE_RC" -eq 0 ] && echo true || echo false),
  "sandbox": "$CODEX_SANDBOX",
  "model": "${CODEX_MODEL:-default}",
  "exit_code": $RC,
  "finished_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

printf 'codex_resume: done (exit=%s)\n  REPORT: %s\n  EVENTS: %s\n  META  : %s\n' \
  "$RC" "$ATTEMPT/report.md" "$ATTEMPT/events.jsonl" "$ATTEMPT/meta.json" >&2

if [ "$RC" -eq 0 ] && [ "$SCOPE_RC" -ne 0 ]; then
  exit 3
fi
exit "$RC"
