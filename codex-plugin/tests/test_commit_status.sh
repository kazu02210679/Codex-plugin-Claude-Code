#!/usr/bin/env bash
# codex_commit.sh / codex_status.sh — the commit gate and git-derived progress.
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# run_task <repo> <plan> <task> [touch] — a full delegate step, returning RUNDIR.
run_task() {
  FAKE_CODEX_TOUCH="${4:-src/a.py}" "$S/codex_run.sh" "$2/$3.md" "$1" >/dev/null 2>&1
  rundir_of "$1"
}

echo "== the gate refuses =="
# The plan is fixed before the run, because the commit gate judges against the
# contract frozen at run time. Each case gets its own repo so a refused commit
# does not leave the next one starting from a dirty tree.
R="$(new_repo c1a)"; P="$(new_plan "$R" auth)"
RD="$(run_task "$R" "$P" T1)"
# The plan directory is untracked for the whole first task, so "did anything
# happen?" has to be judged on product files alone.
git -C "$R" checkout -- src 2>/dev/null
out=$("$S/codex_commit.sh" "$P" T1 "$R" "$RD" 2>&1); rc=$?
check "no product change" "$rc" "1"
has "explains why" "$out" "changed no product files"

R="$(new_repo c1b)"; P="$(new_plan "$R" auth)"
RD="$(run_task "$R" "$P" T1 "docs/d.md")"
before=$(ncommits "$R")
out=$("$S/codex_commit.sh" "$P" T1 "$R" "$RD" 2>&1); rc=$?
check "out of scope" "$rc" "3"
check "no commit made" "$(ncommits "$R")" "$before"

R="$(new_repo c1c)"; P="$(new_plan "$R" auth)"
printf 'false\n' >"$P/test"
RD="$(run_task "$R" "$P" T1)"
before=$(ncommits "$R")
out=$("$S/codex_commit.sh" "$P" T1 "$R" "$RD" 2>&1); rc=$?
check "tests red" "$rc" "1"
check "no commit made" "$(ncommits "$R")" "$before"
has "explains why" "$out" "test gate failed"

echo "== the gate commits =="
R="$(new_repo c1d)"; P="$(new_plan "$R" auth)"
RD="$(run_task "$R" "$P" T1)"
before=$(ncommits "$R")
out=$("$S/codex_commit.sh" "$P" T1 "$R" "$RD" 2>&1); rc=$?
check "commits when green" "$rc" "0"
check "exactly one new commit" "$(ncommits "$R")" "$((before + 1))"
body="$(git -C "$R" log -1 --format=%B)"
has "task trailer" "$body" "Codex-Task: T1"
has "plan trailer" "$body" "Codex-Plan: auth"
has "subject from the task heading" "$(git -C "$R" log -1 --format=%s)" "Add the token model"
[ -s "$RD/commit.log" ] && ok "commit.log written" || bad "no commit.log"
check "worktree clean afterwards" "$(git -C "$R" status --porcelain)" ""
# Hints and interfaces belong with the task that produced them.
files="$(git -C "$R" show --name-only --format= HEAD)"
has "product change committed" "$files" "src/a.py"

echo "== scope is re-checked after the tests run =="
# A test that writes coverage.xml would otherwise be swept in by `git add -A`,
# because the only scope check happened before the test ran.
R="$(new_repo c2)"; P="$(new_plan "$R" auth)"
printf 'echo cov > coverage.xml\n' >"$P/test"
RD="$(run_task "$R" "$P" T1)"
before=$(ncommits "$R")
out=$("$S/codex_commit.sh" "$P" T1 "$R" "$RD" 2>&1); rc=$?
check "test-generated file caught" "$rc" "3"
has "flags it as post-test" "$out" "after tests"
check "no commit made" "$(ncommits "$R")" "$before"
rm -f "$R/coverage.xml"

echo "== HEAD must not move during a task =="
R="$(new_repo c3)"; P="$(new_plan "$R" auth)"
RD="$(run_task "$R" "$P" T1)"
git -C "$R" add -A && git -C "$R" commit -qm "codex committed on its own"
echo more >>"$R/src/a.py"
out=$("$S/codex_commit.sh" "$P" T1 "$R" "$RD" 2>&1); rc=$?
check "detects a mid-task commit" "$rc" "5"
has "names the expectation" "$out" "HEAD moved"

echo "== test-gate policy =="
R="$(new_repo c4)"; P="$(new_plan "$R" auth)"; rm "$P/test"
RD="$(run_task "$R" "$P" T1)"
out=$("$S/codex_commit.sh" "$P" T1 "$R" "$RD" 2>&1); rc=$?
check "a missing test file is an error" "$rc" "2"
has "explains the stance" "$out" "not a gate"
out=$(CODEX_ALLOW_NO_TESTS=1 "$S/codex_commit.sh" "$P" T1 "$R" "$RD" 2>&1); rc=$?
check "override commits" "$rc" "0"

R="$(new_repo c5)"; P="$(new_plan "$R" auth)"
printf 'false\n' >"$P/test"; printf 'true\n' >"$P/T1.test"
RD="$(run_task "$R" "$P" T1)"
out=$("$S/codex_commit.sh" "$P" T1 "$R" "$RD" 2>&1); rc=$?
check "per-task test overrides the default" "$rc" "0"

R="$(new_repo c6)"; P="$(new_plan "$R" auth)"
printf 'true\ntrue\nfalse\n' >"$P/test"
RD="$(run_task "$R" "$P" T1)"
out=$("$S/codex_commit.sh" "$P" T1 "$R" "$RD" 2>&1); rc=$?
check "a later failing command still blocks" "$rc" "1"

R="$(new_repo c6b)"; P="$(new_plan "$R" auth)"
printf 'true # trailing\n\n# whole line\ntrue\n' >"$P/test"
RD="$(run_task "$R" "$P" T1)"
out=$("$S/codex_commit.sh" "$P" T1 "$R" "$RD" 2>&1); rc=$?
check "comments and blanks ignored" "$rc" "0"
has "counts real commands" "$(git -C "$R" log -1 --format=%B)" "Codex-Tests: 2 command"

echo "== staging is limited to this task's files =="
# Metadata is excluded from the scope gate, so a repo-wide `git add -A` would
# commit any OTHER plan's uncommitted files with nothing having checked them.
R="$(new_repo c8)"; P="$(new_plan "$R" auth)"
OTHER="$R/.codex-instructions/other-plan"; mkdir -p "$OTHER"
echo "unrelated work in progress" >"$OTHER/scratch.md"
RD="$(run_task "$R" "$P" T1)"
out=$("$S/codex_commit.sh" "$P" T1 "$R" "$RD" 2>&1); rc=$?
check "commits" "$rc" "0"
files="$(git -C "$R" show --name-only --format= HEAD)"
has "this task's product file" "$files" "src/a.py"
has "this task's plan" "$files" ".codex-instructions/auth/T1.md"
hasnt "another plan's files stay out" "$files" "other-plan"
has "the other plan is still uncommitted" "$(git -C "$R" status --porcelain)" "other-plan"

echo "== the contract cannot change between run and commit =="
R="$(new_repo c9)"; P="$(new_plan "$R" auth)"
RD="$(run_task "$R" "$P" T1)"
printf 'src/*\ndocs/*\n' >"$P/T1.allowlist"
before=$(ncommits "$R")
out=$("$S/codex_commit.sh" "$P" T1 "$R" "$RD" 2>&1); rc=$?
check "widened allowlist refused" "$rc" "6"
has "names what moved" "$out" "T1.allowlist"
check "no commit made" "$(ncommits "$R")" "$before"
printf 'src/*\n' >"$P/T1.allowlist"

# The test command is as much of the gate as the allowlist is.
printf 'true\n# harmless comment\n' >"$P/test"
out=$("$S/codex_commit.sh" "$P" T1 "$R" "$RD" 2>&1); rc=$?
check "swapped test commands refused" "$rc" "6"
has "names what moved" "$out" "test commands"
printf 'true\n' >"$P/test"
out=$("$S/codex_commit.sh" "$P" T1 "$R" "$RD" 2>&1); rc=$?
check "restoring the contract lets it through" "$rc" "0"

echo "== a run directory is required =="
R="$(new_repo c7)"; P="$(new_plan "$R" auth)"
out=$("$S/codex_commit.sh" "$P" T1 "$R" 2>&1); rc=$?
check "missing rundir rejected" "$rc" "2"
out=$("$S/codex_commit.sh" "$P" T9 "$R" "$TMPROOT" 2>&1); rc=$?
check "unknown task id rejected" "$rc" "2"

echo "== status: progress from git =="
R="$(new_repo s1)"; P="$(new_plan "$R" auth)"
out=$("$S/codex_status.sh" "$P" "$R" 2>&1); rc=$?
check "tasks remain" "$rc" "3"
has "T1 is next" "$out" "<- next"
has "counts" "$out" "0/2 committed"
has "names the plan" "$out" "[auth-"

RD="$(run_task "$R" "$P" T1)"
"$S/codex_commit.sh" "$P" T1 "$R" "$RD" >/dev/null 2>&1
out=$("$S/codex_status.sh" "$P" "$R" 2>&1); rc=$?
check "still remaining after T1" "$rc" "3"
has "T1 done" "$out" "T1   done"
has "counts" "$out" "1/2 committed"

RD="$(run_task "$R" "$P" T2)"
"$S/codex_commit.sh" "$P" T2 "$R" "$RD" >/dev/null 2>&1
out=$("$S/codex_status.sh" "$P" "$R" 2>&1); rc=$?
check "all done" "$rc" "0"
has "counts" "$out" "2/2 committed"

echo more >>"$R/src/a.py"
out=$("$S/codex_status.sh" "$P" "$R" 2>&1)
has "flags mid-flight work" "$out" "worktree dirty"
git -C "$R" checkout -- .

echo "== status: a second plan on the same branch =="
# Task ids restart at T1 for every plan, so matching the task trailer alone
# would report the new plan's T1 as already finished.
P2="$(new_plan "$R" billing)"
out=$("$S/codex_status.sh" "$P2" "$R" 2>&1); rc=$?
check "second plan starts from zero" "$rc" "3"
has "counts" "$out" "0/2 committed"
has "names the second plan" "$out" "[billing"

echo "== status: a plan directory reused under the same name =="
# A directory name is a display label. Rebuilding .codex-instructions/auth/ as
# a new plan must not inherit the finished plan's task commits.
rm -rf "$P"; P="$(new_plan "$R" auth)"
out=$("$S/codex_status.sh" "$P" "$R" 2>&1); rc=$?
check "rebuilt plan starts from zero" "$rc" "3"
has "counts" "$out" "0/2 committed"
hasnt "no task claimed as done" "$out" "done"

echo "== status: ordering and edges =="
R="$(new_repo s2)"; P="$(new_plan "$R" auth)"
for n in 3 10; do
  printf '# task %s\n' "$n" >"$P/T$n.md"
  printf 'src/*\n' >"$P/T$n.allowlist"
done
order=$("$S/codex_status.sh" "$P" "$R" 2>&1 | sed -n 's/^  \(T[0-9]*\) .*/\1/p' | tr '\n' ' ')
check "numeric order, not lexical" "$order" "T1 T2 T3 T10 "
rm -f "$P"/T*.md "$P"/T*.allowlist
out=$("$S/codex_status.sh" "$P" "$R" 2>&1); rc=$?
check "empty plan rejected" "$rc" "2"
out=$("$S/codex_status.sh" "$P" "$TMPROOT" 2>&1); rc=$?
check "non-git workdir rejected" "$rc" "2"

finish
