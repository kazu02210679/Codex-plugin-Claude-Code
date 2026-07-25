#!/usr/bin/env bash
# Shared helpers for the wrapper tests. Sourced, never executed.

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # S is the scripts dir, used by every sourcing test
S="$(cd -- "$TESTS_DIR/../scripts" && pwd)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

export PATH="$TESTS_DIR/fixtures:$PATH"
chmod +x "$TESTS_DIR/fixtures/codex" 2>/dev/null || true

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 (want $3, got $2)"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — not found in: $(printf '%s' "$2" | head -c 300)" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 — unexpectedly found '$3'" ;; *) ok "$1" ;; esac; }

finish() {
  printf '\n==== %s: %d passed, %d failed ====\n' "${0##*/}" "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

# new_repo <name> — a git repo on a work branch with one commit.
# Returns its path on stdout.
new_repo() {
  local d="$TMPROOT/$1"
  rm -rf "$d"; mkdir -p "$d/src" "$d/docs"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  echo base >"$d/src/a.py"
  echo base >"$d/docs/d.md"
  git -C "$d" add -A
  git -C "$d" commit -qm init
  git -C "$d" checkout -qb work
  printf '%s' "$d"
}

# new_plan <repo> <name> — a plan directory inside the repo's meta dir.
new_plan() {
  local p="$1/.codex-instructions/$2"
  mkdir -p "$p"
  printf '%s-%s%s\n' "$2" "$(date +%s)" "$RANDOM" >"$p/plan-id"
  printf '# Add the token model\n\nDo the thing.\n' >"$p/T1.md"
  printf 'src/*\n'                                  >"$p/T1.allowlist"
  printf '# Wire the endpoint\n\nDo the next thing.\n' >"$p/T2.md"
  printf 'src/*\n'                                  >"$p/T2.allowlist"
  printf 'true\n'                                   >"$p/test"
  printf '%s' "$p"
}

# rundir_of <repo> — the newest run directory.
rundir_of() {
  local r
  r="$(ls -d "$1"/.codex-runs/*/ 2>/dev/null | sort | tail -1)"
  printf '%s' "${r%/}"
}

ncommits() { git -C "$1" rev-list --count HEAD; }
