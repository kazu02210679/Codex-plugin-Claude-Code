#!/usr/bin/env bash
#
# codex_scope_check.sh — mechanically verify that a run stayed inside its
# declared file scope.
#
# The orchestrator's instruction "do not add features not in this packet" is a
# text-level request. This script is the executable gate behind it: it diffs the
# worktree against the pre-run commit and fails if any changed file falls
# outside the task's allowlist.
#
# It is author-agnostic on purpose. It checks what the working tree looks like,
# not who edited it — so it catches the orchestrator quietly fixing production
# code just as well as it catches Codex wandering out of scope.
#
# Orchestration metadata (the plan directory, run artifacts) is excluded: it is
# written by the orchestrator throughout the loop and is not product. Codex is
# kept out of it by the fingerprint check in codex_run.sh, not by this gate.
#
# Usage:
#   codex_scope_check.sh <allowlist_file> <workdir> [base_ref]
#
# Args:
#   allowlist_file  One glob per line. Blank lines and `#` comments ignored.
#                   Pass the FROZEN copy under <rundir>/allowlist, not the
#                   plan's live file — see codex_run.sh.
#   workdir         Git repository to inspect.
#   base_ref        Commit to diff against. Default: HEAD. Pass the empty
#                   string only for a repository with no commits yet.
#
# Patterns are matched with bash `[[ str == glob ]]`, where `*` also matches
# `/`. So `src/*` covers the whole `src` subtree, and `*.py` covers every Python
# file in the repo. Anchor a pattern by writing the full path.
#
# Renames are checked on both sides. `git diff --name-only` reports only the
# destination of a rename, which would let `git mv out-of-scope/x.py allowed/y.py`
# delete an out-of-scope file invisibly; --name-status exposes both paths and
# both must be allowed.
#
# Exit codes:
#   0  every changed file is covered by the allowlist
#   1  at least one changed file is outside it
#   2  usage / environment error
set -euo pipefail

# shellcheck source=codex_lib.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/codex_lib.sh"

die() { printf 'codex_scope_check: %s\n' "$1" >&2; exit 2; }

[ "$#" -ge 2 ] || die "usage: codex_scope_check.sh <allowlist_file> <workdir> [base_ref]"

ALLOWLIST="$1"
WORKDIR="$2"
BASE="${3-HEAD}"

[ -f "$ALLOWLIST" ] || die "allowlist not found: $ALLOWLIST"
[ -d "$WORKDIR" ]   || die "workdir not found: $WORKDIR"
git -C "$WORKDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not a git repository: $WORKDIR"

# --- read the allowlist -----------------------------------------------------
patterns=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] || continue
  patterns+=("$line")
done <"$ALLOWLIST"

[ "${#patterns[@]}" -gt 0 ] || die "allowlist has no patterns: $ALLOWLIST"

# --- collect changed files --------------------------------------------------
# An empty base ref means "no commits yet", where every file is untracked and
# the diff half is genuinely unnecessary. Accepting an empty base in a
# repository that DOES have commits would silently skip every tracked-file
# edit and report a clean scope, so refuse it loudly instead.
if [ -z "$BASE" ]; then
  if git -C "$WORKDIR" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    die "empty base ref, but $WORKDIR has commits. Without a baseline this check would ignore every edit to a tracked file. Pass the pre-run commit (codex_run.sh records it in <rundir>/base_commit)."
  fi
  printf 'scope: note — no commits in %s yet; checking untracked files only\n' "$WORKDIR"
fi

TMPF=""; OTHERS=""
trap 'rm -f "$TMPF" "$OTHERS"' EXIT

raw=()
if [ -n "$BASE" ]; then
  # A safety gate that cannot tell must fail, not pass. A base ref that does
  # not resolve — a truncated base_commit, the wrong run directory, a reviewer
  # naming the wrong parent — makes `git diff` fail; swallowing that error
  # would leave only the untracked-file half running and report a clean scope
  # over an arbitrarily large tracked-file diff.
  git -C "$WORKDIR" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1 \
    || die "base ref does not resolve to a commit in $WORKDIR: '$BASE'. Refusing to report a scope verdict from an incomplete diff."

  # -M turns renames into R entries carrying both paths; -z keeps paths with
  # spaces or newlines intact.
  #
  # Via a temp file, not `$(...)`: bash cannot hold NUL in a variable, so
  # command substitution would silently strip every separator and collapse the
  # whole listing into one meaningless path. A pipeline would hide git's exit
  # status instead, which is the thing this gate must not do.
  TMPF="$(mktemp)"
  if ! git -C "$WORKDIR" diff -M --name-status -z "$BASE" -- >"$TMPF"; then
    die "git diff against '$BASE' failed in $WORKDIR"
  fi
  fields=()
  mapfile -d '' -t fields <"$TMPF"
  i=0
  while [ "$i" -lt "${#fields[@]}" ]; do
    st="${fields[$i]}"; i=$((i + 1))
    [ -n "$st" ] || continue
    case "$st" in
      R*|C*)
        # old path and new path: a rename out of scope is still a change to the
        # out-of-scope file.
        [ "$i" -lt "${#fields[@]}" ] && { raw+=("${fields[$i]}"); i=$((i + 1)); }
        [ "$i" -lt "${#fields[@]}" ] && { raw+=("${fields[$i]}"); i=$((i + 1)); }
        ;;
      *)
        [ "$i" -lt "${#fields[@]}" ] && { raw+=("${fields[$i]}"); i=$((i + 1)); }
        ;;
    esac
  done
fi

# New files Codex created. Gitignored paths (including the run directory) are
# excluded by --exclude-standard.
OTHERS="$(mktemp)"
if ! git -C "$WORKDIR" ls-files --others --exclude-standard -z >"$OTHERS"; then
  die "git ls-files failed in $WORKDIR"
fi
while IFS= read -r -d '' f; do
  [ -n "$f" ] && raw+=("$f")
done <"$OTHERS"

# Drop orchestration metadata and de-duplicate.
changed=()
if [ "${#raw[@]}" -gt 0 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && changed+=("$f")
  done < <(
    for f in "${raw[@]}"; do
      codex_is_meta_path "$f" && continue
      printf '%s\n' "$f"
    done | LC_ALL=C sort -u
  )
fi

if [ "${#changed[@]}" -eq 0 ]; then
  printf 'scope: OK — no product files changed\n'
  exit 0
fi

# --- match ------------------------------------------------------------------
violations=()
for f in "${changed[@]}"; do
  ok=0
  for p in "${patterns[@]}"; do
    # shellcheck disable=SC2053  # $p is an intentional glob
    if [[ "$f" == $p ]]; then ok=1; break; fi
  done
  [ "$ok" -eq 1 ] || violations+=("$f")
done

if [ "${#violations[@]}" -eq 0 ]; then
  printf 'scope: OK — %d changed file(s), all inside %s\n' "${#changed[@]}" "$ALLOWLIST"
  exit 0
fi

printf 'scope: VIOLATION — %d of %d changed file(s) outside %s\n\n' \
  "${#violations[@]}" "${#changed[@]}" "$ALLOWLIST"
printf 'out of scope:\n'
printf '  %s\n' "${violations[@]}"
printf '\nallowed patterns:\n'
printf '  %s\n' "${patterns[@]}"
exit 1
