#!/usr/bin/env bash
# codex_scope_check.sh — allowlist matching, rename handling, metadata exemption.
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

R="$(new_repo scope)"
AL="$TMPROOT/al"; printf 'src/*\n# a comment\n\n' >"$AL"

echo "== basics =="
out=$("$S/codex_scope_check.sh" "$AL" "$R" HEAD 2>&1); rc=$?
check "clean tree passes" "$rc" "0"

echo edit >>"$R/src/a.py"
out=$("$S/codex_scope_check.sh" "$AL" "$R" HEAD 2>&1); rc=$?
check "in-scope edit passes" "$rc" "0"

echo edit >>"$R/docs/d.md"
out=$("$S/codex_scope_check.sh" "$AL" "$R" HEAD 2>&1); rc=$?
check "out-of-scope edit fails" "$rc" "1"
has "names the file" "$out" "docs/d.md"
git -C "$R" checkout -- .

echo new >"$R/src/new.py"
out=$("$S/codex_scope_check.sh" "$AL" "$R" HEAD 2>&1); rc=$?
check "in-scope untracked passes" "$rc" "0"
rm "$R/src/new.py"
echo new >"$R/oops.txt"
out=$("$S/codex_scope_check.sh" "$AL" "$R" HEAD 2>&1); rc=$?
check "out-of-scope untracked fails" "$rc" "1"
rm "$R/oops.txt"

echo "== renames must be checked on both sides =="
# git diff --name-only reports only a rename's destination, so moving a file
# out of the allowlist into it would otherwise delete the original invisibly.
git -C "$R" mv docs/d.md src/smuggled.md
out=$("$S/codex_scope_check.sh" "$AL" "$R" HEAD 2>&1); rc=$?
check "rename from out-of-scope fails" "$rc" "1"
has "names the source path" "$out" "docs/d.md"
git -C "$R" reset -q --hard HEAD

git -C "$R" mv src/a.py src/b.py
out=$("$S/codex_scope_check.sh" "$AL" "$R" HEAD 2>&1); rc=$?
check "rename inside scope passes" "$rc" "0"
git -C "$R" reset -q --hard HEAD

echo "== orchestration metadata is exempt =="
mkdir -p "$R/.codex-instructions/p"
echo hint >"$R/.codex-instructions/p/T1.hint-1.md"
out=$("$S/codex_scope_check.sh" "$AL" "$R" HEAD 2>&1); rc=$?
check "plan files do not violate scope" "$rc" "0"
mkdir -p "$R/.codex-runs/x"
echo log >"$R/.codex-runs/x/events.jsonl"
out=$("$S/codex_scope_check.sh" "$AL" "$R" HEAD 2>&1); rc=$?
check "run artifacts do not violate scope" "$rc" "0"
rm -rf "$R/.codex-instructions" "$R/.codex-runs"

echo "== base ref handling =="
echo edit >>"$R/docs/d.md"
out=$("$S/codex_scope_check.sh" "$AL" "$R" "" 2>&1); rc=$?
check "empty base in a repo with commits is refused" "$rc" "2"
has "explains why" "$out" "ignore every edit"
git -C "$R" checkout -- .

E="$TMPROOT/empty"; mkdir -p "$E/src"; git -C "$E" init -q -b main
echo z >"$E/src/n.py"; echo z >"$E/oops.txt"
out=$("$S/codex_scope_check.sh" "$AL" "$E" "" 2>&1); rc=$?
check "no-commits repo checks untracked only" "$rc" "1"
has "catches untracked violation" "$out" "oops.txt"

echo "== a gate that cannot tell must fail, not pass =="
# An unresolvable base makes `git diff` fail. Swallowing that error would leave
# only the untracked half running, and report a clean scope over an
# arbitrarily large tracked-file diff.
mkdir -p "$R/secret"; echo x >"$R/secret/keys.py"
git -C "$R" add -A; git -C "$R" commit -qm secret
echo TAMPERED >>"$R/secret/keys.py"
out=$("$S/codex_scope_check.sh" "$AL" "$R" HEAD 2>&1); rc=$?
check "tracked out-of-scope edit fails with a good base" "$rc" "1"
out=$("$S/codex_scope_check.sh" "$AL" "$R" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 2>&1); rc=$?
check "unresolvable base refuses to give a verdict" "$rc" "2"
hasnt "does not report OK" "$out" "scope: OK"
has "explains the refusal" "$out" "does not resolve"
out=$("$S/codex_scope_check.sh" "$AL" "$R" "not-a-ref" 2>&1); rc=$?
check "garbage base refused" "$rc" "2"
git -C "$R" checkout -- .

echo "== usage errors =="
: >"$TMPROOT/empty.allowlist"
out=$("$S/codex_scope_check.sh" "$TMPROOT/empty.allowlist" "$R" 2>&1); rc=$?
check "empty allowlist rejected" "$rc" "2"
out=$("$S/codex_scope_check.sh" "$TMPROOT/nope" "$R" 2>&1); rc=$?
check "missing allowlist rejected" "$rc" "2"
out=$("$S/codex_scope_check.sh" "$AL" "$TMPROOT" 2>&1); rc=$?
check "non-git workdir rejected" "$rc" "2"

finish
