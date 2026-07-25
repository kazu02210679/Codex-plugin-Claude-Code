#!/usr/bin/env bash
#
# codex_lib.sh — shared helpers. Sourced, never executed.
#
# The important idea here is the split between two kinds of file:
#
#   product files       what Codex is asked to change. Governed by the task's
#                       allowlist, and the thing the diff review is about.
#   orchestration meta  the plan, hints, interfaces, run artifacts. Written by
#                       the orchestrator, changes constantly during the loop,
#                       and is not part of the product diff.
#
# Holding both to one rule is what made "keep the plan in version control",
# "refuse to start from a dirty tree" and "write a hint file mid-loop"
# contradict each other. Meta paths are excluded from the dirty preflight and
# from the scope gate, and are instead protected by a fingerprint taken across
# each Codex run: the orchestrator may write there between runs, Codex may
# never write there at all.

# bash 4.4+: NUL-delimited mapfile (-d) and `declare -A` are both load-bearing.
if [ -z "${BASH_VERSINFO:-}" ] ||
   [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  printf 'codex: bash 4.4+ required, found %s. On macOS: brew install bash.\n' \
    "${BASH_VERSION:-unknown}" >&2
  exit 2
fi

# Workdir-relative paths that are orchestration metadata, never product.
CODEX_META_DIR="${CODEX_META_DIR:-.codex-instructions}"
CODEX_RUNS_DIR="${CODEX_RUNS_DIR:-.codex-runs}"

# codex_is_meta_path <path>
# True when a workdir-relative path is orchestration metadata.
codex_is_meta_path() {
  case "$1" in
    "$CODEX_META_DIR"/*|"$CODEX_META_DIR") return 0 ;;
    "$CODEX_RUNS_DIR"/*|"$CODEX_RUNS_DIR") return 0 ;;
    *) return 1 ;;
  esac
}

# codex_dirty_product <workdir> [base_ref]
# Changed PRODUCT paths, one per line — metadata excluded. Used both by the
# dirty preflight and by the "did this task actually do anything?" check, which
# have to agree: with the plan directory always untracked during a run, a check
# over the whole worktree can never see a clean tree and never sees a task that
# did nothing. Also used to build the staging list, which is why renames are
# expanded rather than detected: `--name-only` reports only a rename's
# destination, so staging from it would leave the source's deletion behind.
codex_dirty_product() {
  local wd="$1" base="${2:-HEAD}" f
  {
    git -C "$wd" diff --no-renames --name-only "$base" -- 2>/dev/null || true
    git -C "$wd" ls-files --others --exclude-standard 2>/dev/null || true
  } | LC_ALL=C sort -u | while IFS= read -r f; do
    [ -n "$f" ] || continue
    codex_is_meta_path "$f" && continue
    printf '%s\n' "$f"
  done
}

# codex_plan_id <plandir>
# The plan's stable identity. A directory name is a display label, not an id:
# deleting `.codex-instructions/auth/` and writing a new plan under the same
# name would otherwise inherit the old plan's task commits and report its
# first task as already finished. /codex-spec writes plan-id; the basename is
# only a fallback for plans made before that existed.
codex_plan_id() {
  local d="$1"
  if [ -s "$d/plan-id" ]; then
    tr -d '[:space:]' <"$d/plan-id"
  else
    basename "$(cd -- "$d" && pwd)"
  fi
}

# codex_test_file <plandir> <task_id>
# The test commands that gate this task's commit, or nothing. Per-task file
# wins over the plan default.
codex_test_file() {
  if   [ -f "$1/$2.test" ]; then printf '%s\n' "$1/$2.test"
  elif [ -f "$1/test" ];    then printf '%s\n' "$1/test"
  fi
}

# --- hashing ----------------------------------------------------------------
# sha256sum is GNU coreutils; macOS ships shasum instead. Resolve once, and
# fail loudly rather than silently skipping an integrity check.
#
# All three MUST print the digest as the first space-separated field. Plain
# `openssl dgst -sha256` prints `SHA2-256(stdin)= <hash>`, whose first field is
# a constant — every file would hash alike and the integrity checks would pass
# anything. `-r` switches it to coreutils order. Set CODEX_HASH_CMD to force a
# backend; the tests use it to exercise each one.
CODEX_HASH=()
if [ -n "${CODEX_HASH_CMD:-}" ]; then
  # shellcheck disable=SC2206  # deliberate word splitting: this is a command
  CODEX_HASH=(${CODEX_HASH_CMD})
elif command -v sha256sum >/dev/null 2>&1; then CODEX_HASH=(sha256sum)
elif command -v shasum >/dev/null 2>&1;    then CODEX_HASH=(shasum -a 256)
elif command -v openssl >/dev/null 2>&1;   then CODEX_HASH=(openssl dgst -sha256 -r)
fi

codex_require_hash() {
  [ "${#CODEX_HASH[@]}" -gt 0 ] && return 0
  printf 'codex: no SHA-256 tool found (looked for sha256sum, shasum, openssl).\n' >&2
  printf '  The plan-integrity check cannot run without one.\n' >&2
  return 1
}

# codex_hash_file <path> — hash of one file's contents, or the empty string.
codex_hash_file() {
  [ -f "$1" ] || { printf '\n'; return 0; }
  "${CODEX_HASH[@]}" <"$1" | cut -d' ' -f1
}

# codex_meta_fingerprint <plandir>
# A single hash over every file in ONE plan directory. Compared across a Codex
# run to prove Codex did not rewrite its own instructions — most importantly
# its own allowlist, which it could otherwise widen and then pass the scope
# gate.
#
# Scoped to the plan being run, not to all of .codex-instructions/: a second
# agent working a different plan in the same repository would otherwise trip
# this check, and reporting "Codex tampered with the plan" for someone else's
# hint file is a false alarm that trains you to ignore a real one.
codex_meta_fingerprint() {
  local d="$1"
  if [ ! -d "$d" ]; then printf 'absent\n'; return 0; fi
  # POSIX find + sort only: `sort -z` and `xargs -r` are GNU extensions that
  # macOS does not have, and silently producing a different fingerprint there
  # would turn the integrity check into noise.
  ( cd "$d" && find . -type f -exec "${CODEX_HASH[@]}" {} + 2>/dev/null \
      | LC_ALL=C sort | "${CODEX_HASH[@]}" | cut -d' ' -f1 )
}

# codex_thread_id <events.jsonl>
# Best-effort extraction of the session id a resume needs. Key names have
# changed across Codex releases, so several are tried; an empty result means
# the caller must fall back rather than guess.
codex_thread_id() {
  local f="$1" id=""
  [ -f "$f" ] || return 0
  local key
  for key in thread_id session_id conversation_id rollout_id; do
    id="$(grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]\+\"" "$f" 2>/dev/null \
          | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
    [ -n "$id" ] && { printf '%s\n' "$id"; return 0; }
  done
  return 0
}

# codex_timeout_prefix <seconds>
# Emits a `timeout` invocation when the coreutils binary is present, and
# nothing when it is not — an unattended run should not die on a missing tool,
# but it also should not hang forever when one is available.
codex_timeout_prefix() {
  local secs="$1"
  [ -n "$secs" ] && [ "$secs" != "0" ] || return 0
  if command -v timeout >/dev/null 2>&1; then
    printf 'timeout\n%s\n' "$secs"
  fi
}
