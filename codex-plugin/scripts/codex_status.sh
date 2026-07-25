#!/usr/bin/env bash
#
# codex_status.sh — where is this plan up to?
#
# Progress is read back out of git history, not from a status file. Every task
# commit carries `Codex-Plan:` and `Codex-Task:` trailers, so the commits
# themselves are the ledger: there is no second copy of the truth to drift, and
# the answer survives anything that happens to the orchestrator's context.
#
# Both trailers are matched, not just the task id. Task ids restart at T1 for
# every plan, so a branch that has already carried one plan would otherwise
# report the next plan's T1 as finished before it had started.
#
# Run this at the start of a resumed session, or any time you are unsure which
# task is next.
#
# Usage:
#   codex_status.sh <taskdir> <workdir>
#
# Exit codes:
#   0  every task in the plan is committed
#   2  usage / environment error
#   3  tasks remain
set -euo pipefail

# shellcheck source=codex_lib.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/codex_lib.sh"

die() { printf 'codex_status: %s\n' "$1" >&2; exit 2; }

[ "$#" -ge 2 ] || die "usage: codex_status.sh <taskdir> <workdir>"

TASKDIR="$1"
WORKDIR="$2"

[ -d "$TASKDIR" ] || die "task directory not found: $TASKDIR"
[ -d "$WORKDIR" ] || die "workdir not found: $WORKDIR"
git -C "$WORKDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not a git repository: $WORKDIR"

# --- enumerate tasks in numeric order ---------------------------------------
# Sorted by the number, not the string, so a plan does not silently reorder
# itself when it reaches T10.
ids=()
while IFS= read -r id; do
  [ -n "$id" ] && ids+=("$id")
done < <(
  for f in "$TASKDIR"/T*.md; do
    [ -f "$f" ] || continue
    b="$(basename "$f" .md)"
    n="${b#T}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    printf '%s\t%s\n' "$n" "$b"
  done | sort -n | cut -f2
)

[ "${#ids[@]}" -gt 0 ] || die "no T<N>.md task packets in $TASKDIR"

# --- scan this branch's commits for task trailers ---------------------------
# Limited to commits since the branch left the default branch, so re-running a
# plan does not match task commits from an earlier one.
RANGE=""
DEFAULT_BRANCH="$(git -C "$WORKDIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
if [ -n "$DEFAULT_BRANCH" ]; then
  BASE="$(git -C "$WORKDIR" merge-base HEAD "$DEFAULT_BRANCH" 2>/dev/null || true)"
  [ -n "$BASE" ] && RANGE="$BASE..HEAD"
fi

PLAN_ID="$(codex_plan_id "$TASKDIR")"

declare -A sha_of=()
declare -A subject_of=()
while IFS= read -r -d $'\x1e' rec; do
  rec="${rec#"${rec%%[![:space:]]*}"}"
  [ -n "$rec" ] || continue
  sha="${rec%%$'\x1f'*}"; rest="${rec#*$'\x1f'}"
  subj="${rest%%$'\x1f'*}"; body="${rest#*$'\x1f'}"
  plan="$(printf '%s\n' "$body" | sed -n 's/^Codex-Plan:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)"
  task="$(printf '%s\n' "$body" | sed -n 's/^Codex-Task:[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' | head -1)"
  [ -n "$task" ] || continue
  [ "$plan" = "$PLAN_ID" ] || continue
  # git log is newest-first; keep the newest commit for each task id.
  [ -n "${sha_of[$task]:-}" ] || { sha_of[$task]="$sha"; subject_of[$task]="$subj"; }
done < <(git -C "$WORKDIR" log --format="%h%x1f%s%x1f%b%x1e" ${RANGE:+"$RANGE"} 2>/dev/null || true)

# --- report -----------------------------------------------------------------
printf 'plan: %s [%s] (%d task(s))\n' "$TASKDIR" "$PLAN_ID" "${#ids[@]}"

done_count=0
next=""
for id in "${ids[@]}"; do
  title="$(grep -m1 '^# ' "$TASKDIR/$id.md" 2>/dev/null | sed 's/^# *//' || true)"
  if [ -n "${sha_of[$id]:-}" ]; then
    done_count=$((done_count + 1))
    printf '  %-4s done     %-9s %s\n' "$id" "${sha_of[$id]}" "${subject_of[$id]}"
  else
    if [ -z "$next" ]; then
      next="$id"
      printf '  %-4s pending  %-9s %s   <- next\n' "$id" "" "${title:-}"
    else
      printf '  %-4s pending  %-9s %s\n' "$id" "" "${title:-}"
    fi
  fi
done

DIRTY=""
[ -n "$(git -C "$WORKDIR" status --porcelain)" ] && DIRTY=" (worktree dirty — a task is mid-flight)"
printf '%d/%d committed%s\n' "$done_count" "${#ids[@]}" "$DIRTY"

[ "$done_count" -eq "${#ids[@]}" ] && exit 0
exit 3
