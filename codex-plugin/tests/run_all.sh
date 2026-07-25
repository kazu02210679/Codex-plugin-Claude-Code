#!/usr/bin/env bash
# Run every wrapper test. Exits non-zero if any file fails.
#
# The tests drive the real scripts against a fake `codex` on PATH
# (tests/fixtures/codex) and throwaway git repositories under a temp dir.
# Nothing here needs a real Codex CLI, an API key, or network access.
set -uo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 2

FAILED=()
for t in test_*.sh; do
  printf '\n### %s\n' "$t"
  bash "$t" || FAILED+=("$t")
done

printf '\n=========================================\n'
if [ "${#FAILED[@]}" -eq 0 ]; then
  printf 'all suites passed\n'
  exit 0
fi
printf 'FAILED: %s\n' "${FAILED[*]}"
exit 1
