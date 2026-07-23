#!/usr/bin/env bash
#
# codex_resume.sh — feed Codex a follow-up hint when it got stuck.
#
# This is the "Claude steps in with an opinion" step. Claude reads Codex's
# previous report + failing logs, writes a hint file (root cause + concrete
# guidance + a minimal path forward), and calls this script to continue.
#
# It first tries native session continuation (`codex exec resume --last`). If
# the installed Codex doesn't support that, set CODEX_RESUME_MODE=fresh to run
# a fresh `codex exec` whose prompt tells Codex to re-read its own prior report
# and the failing logs before continuing — portable, no session state needed.
#
# Usage:
#   codex_resume.sh <hint_file> <workdir> <outdir> [prev_report]
#
# Env:
#   CODEX_RESUME_MODE  resume|fresh  (default: resume, falls back to fresh)
#   plus the same overrides as codex_run.sh (CODEX_MODEL/SANDBOX/APPROVAL/...).
set -euo pipefail

die() { printf 'codex_resume: %s\n' "$1" >&2; exit 2; }

[ "$#" -ge 3 ] || die "usage: codex_resume.sh <hint_file> <workdir> <outdir> [prev_report]"

HINT="$1"
WORKDIR="$2"
OUTDIR="$3"
PREV_REPORT="${4:-$OUTDIR/report.md}"

command -v codex >/dev/null 2>&1 || die "the 'codex' CLI is not installed or not on PATH."
[ -f "$HINT" ]   || die "hint file not found: $HINT"
[ -d "$WORKDIR" ] || die "workdir not found: $WORKDIR"

CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}"
CODEX_APPROVAL="${CODEX_APPROVAL:-never}"
CODEX_RESUME_MODE="${CODEX_RESUME_MODE:-resume}"
mkdir -p "$OUTDIR"

common=(--cd "$WORKDIR" --sandbox "$CODEX_SANDBOX" --ask-for-approval "$CODEX_APPROVAL"
        --output-last-message "$OUTDIR/report.md" --json)
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

set +e
if [ "$CODEX_RESUME_MODE" = "fresh" ]; then
  run_fresh   >"$OUTDIR/events.jsonl" 2>"$OUTDIR/stderr.log"; RC=$?
else
  run_resume  >"$OUTDIR/events.jsonl" 2>"$OUTDIR/stderr.log"; RC=$?
  if [ "$RC" -ne 0 ] && grep -qiE 'resume|unrecognized|unexpected|no such' "$OUTDIR/stderr.log"; then
    printf 'codex_resume: native resume failed, falling back to fresh mode\n' >&2
    run_fresh >"$OUTDIR/events.jsonl" 2>>"$OUTDIR/stderr.log"; RC=$?
  fi
fi
set -e

[ -f "$OUTDIR/report.md" ] || printf '(no final message captured; see stderr.log)\n' >"$OUTDIR/report.md"
printf 'codex_resume: done (exit=%s)\n  REPORT: %s\n' "$RC" "$OUTDIR/report.md" >&2
exit "$RC"
