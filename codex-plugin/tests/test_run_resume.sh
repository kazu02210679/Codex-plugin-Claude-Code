#!/usr/bin/env bash
# codex_run.sh / codex_resume.sh — preflight, prompt assembly, CLI invocation,
# attempt isolation, and the metadata integrity check.
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "== git preflight =="
R="$(new_repo run1)"; P="$(new_plan "$R" auth)"
git -C "$R" checkout -q main
out=$("$S/codex_run.sh" "$P/T1.md" "$R" 2>&1); rc=$?
check "refuses the default branch" "$rc" "2"
has "says which branch" "$out" "default branch"
git -C "$R" checkout -q work

echo dirt >>"$R/src/a.py"
out=$("$S/codex_run.sh" "$P/T1.md" "$R" 2>&1); rc=$?
check "refuses a dirty product tree" "$rc" "2"
has "lists the offending file" "$out" "src/a.py"
git -C "$R" checkout -- .

# The plan itself is untracked when /codex-spec has just written it. Holding it
# to the dirty check would mean the first task could never start.
out=$(FAKE_CODEX_TOUCH="src/a.py" "$S/codex_run.sh" "$P/T1.md" "$R" 2>&1); rc=$?
check "untracked plan does not block the first run" "$rc" "0"
has "scope reported" "$out" "scope: OK"

echo "== artifacts =="
RD="$(rundir_of "$R")"
for f in attempt-1/report.md attempt-1/events.jsonl attempt-1/stderr.log \
         attempt-1/meta.json attempt-1/scope.txt base_commit allowlist \
         thread_id .gitignore; do
  [ -f "$RD/$f" ] && ok "artifact $f" || bad "missing $f"
done
check "thread id captured" "$(cat "$RD/thread_id")" "thr-abc123"
hasnt "run dir hidden from git" "$(git -C "$R" status --porcelain)" "codex-runs"

echo "== interfaces are injected into the prompt =="
R="$(new_repo run2)"; P="$(new_plan "$R" auth)"
LOG="$TMPROOT/argv1"; : >"$LOG"
FAKE_CODEX_LOG="$LOG" FAKE_CODEX_TOUCH="src/a.py" "$S/codex_run.sh" "$P/T1.md" "$R" >/dev/null 2>&1
hasnt "nothing injected when interfaces.md is absent" "$(cat "$LOG")" "Verified interfaces"

printf 'get_token(user_id: str) -> Token\n' >"$P/interfaces.md"
git -C "$R" checkout -- . 2>/dev/null; git -C "$R" clean -qfd src 2>/dev/null
LOG="$TMPROOT/argv2"; : >"$LOG"
FAKE_CODEX_LOG="$LOG" FAKE_CODEX_TOUCH="src/a.py" "$S/codex_run.sh" "$P/T2.md" "$R" >/dev/null 2>&1
has "interfaces section injected" "$(cat "$LOG")" "Verified interfaces from completed tasks"
has "interface content injected" "$(cat "$LOG")" "get_token(user_id: str)"
has "task packet still present" "$(cat "$LOG")" "Do the next thing"

echo "== stdin is closed =="
# With a prompt argument present, Codex appends piped stdin to the prompt, so
# an inherited pipe would silently corrupt the task.
R="$(new_repo run3)"; P="$(new_plan "$R" auth)"
SL="$TMPROOT/stdin1"; : >"$SL"
printf 'LEAKED CONTENT\n' | FAKE_CODEX_STDIN_LOG="$SL" FAKE_CODEX_TOUCH="src/a.py" \
  "$S/codex_run.sh" "$P/T1.md" "$R" >/dev/null 2>&1
hasnt "caller stdin does not reach Codex" "$(cat "$SL")" "LEAKED CONTENT"

echo "== every hash backend produces a real digest =="
# `openssl dgst -sha256` prints `SHA2-256(stdin)= <hash>`, so taking the first
# field yields a constant — every file would hash alike and the integrity
# checks would wave anything through. Each backend is exercised separately,
# and against a known vector, because a backend that always agrees with itself
# still passes a same-tool comparison.
KNOWN=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
printf abc >"$TMPROOT/abc"; printf xyz >"$TMPROOT/xyz"
for backend in "sha256sum" "shasum -a 256" "openssl dgst -sha256 -r"; do
  tool="${backend%% *}"
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '  SKIP  %s not installed\n' "$tool"; continue
  fi
  a="$(CODEX_HASH_CMD="$backend" bash -c '. "$0"; codex_hash_file "$1"' "$S/codex_lib.sh" "$TMPROOT/abc")"
  b="$(CODEX_HASH_CMD="$backend" bash -c '. "$0"; codex_hash_file "$1"' "$S/codex_lib.sh" "$TMPROOT/xyz")"
  check "$tool matches the known vector" "$a" "$KNOWN"
  [ "$a" != "$b" ] && ok "$tool distinguishes different files" \
                   || bad "$tool returns the same value for different files"
done

echo "== metadata tampering is fatal =="
R="$(new_repo run4)"; P="$(new_plan "$R" auth)"
out=$(FAKE_CODEX_TOUCH=".codex-instructions/auth/T1.allowlist" \
  "$S/codex_run.sh" "$P/T1.md" "$R" 2>&1); rc=$?
check "Codex widening its own allowlist fails the run" "$rc" "4"
has "explains the risk" "$out" "widen its own scope"

# Scoped to the plan being run: a second agent working another plan in the same
# repository must not be reported as Codex tampering with this one.
R="$(new_repo run4b)"; P="$(new_plan "$R" auth)"; new_plan "$R" billing >/dev/null
out=$(FAKE_CODEX_TOUCH="src/a.py .codex-instructions/billing/T1.md" \
  "$S/codex_run.sh" "$P/T1.md" "$R" 2>&1); rc=$?
check "another plan changing underfoot is not tampering" "$rc" "0"
hasnt "no false alarm" "$out" "modified the plan directory"

echo "== run directories cannot collide =="
# The default name used to be a timestamp to the second, so two tasks started
# in the same second shared one directory and the second overwrote the first's
# frozen contract and attempt-1 while both were still in use.
R="$(new_repo run4c)"; P="$(new_plan "$R" auth)"
RD1="$(do_run "$R" "$P/T1.md")"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm t1 >/dev/null 2>&1
RD2="$(do_run "$R" "$P/T2.md")"
[ -n "$RD1" ] && [ -n "$RD2" ] && ok "both runs reported a directory" || bad "missing RUNDIR output"
[ "$RD1" != "$RD2" ] && ok "same-second runs get distinct directories" \
                     || bad "collision: both used $RD1"
check "first run's contract survives" "$(cat "$RD1/task.md")" "$(cat "$P/T1.md")"
check "second run's contract is its own" "$(cat "$RD2/task.md")" "$(cat "$P/T2.md")"

git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm t2 >/dev/null 2>&1
out=$("$S/codex_run.sh" "$P/T1.md" "$R" "$RD1" 2>&1); rc=$?
check "reusing a populated run directory is refused" "$rc" "2"
has "explains why" "$out" "already exists and is not empty"
out=$(FAKE_CODEX_TOUCH="src/a.py" "$S/codex_run.sh" "$P/T1.md" "$R" "$R/.codex-runs/fresh" 2>&1); rc=$?
check "an unused explicit path is accepted" "$rc" "0"

echo "== scope gate uses the frozen allowlist =="
R="$(new_repo run5)"; P="$(new_plan "$R" auth)"
FAKE_CODEX_TOUCH="src/a.py" "$S/codex_run.sh" "$P/T1.md" "$R" >/dev/null 2>&1
RD="$(rundir_of "$R")"
printf 'src/*\n' >"$P/T1.allowlist.check"
check "frozen copy matches the plan at run time" \
  "$(cat "$RD/allowlist")" "$(cat "$P/T1.allowlist")"

echo "== non-git workdir =="
PLAIN="$TMPROOT/plain"; mkdir -p "$PLAIN"
out=$("$S/codex_run.sh" "$P/T1.md" "$PLAIN" 2>&1); rc=$?
check "refuses a scoped task without git" "$rc" "2"
has "explains the gate needs git" "$out" "scope gate needs git"
NOAL="$TMPROOT/noal.md"; printf 'do a thing\n' >"$NOAL"
out=$(FAKE_CODEX_TOUCH="q.txt" "$S/codex_run.sh" "$NOAL" "$PLAIN" 2>&1); rc=$?
check "unscoped task runs without git" "$rc" "0"
has "warns" "$out" "not a git repository"

echo "== resume: attempt isolation =="
R="$(new_repo res1)"; P="$(new_plan "$R" auth)"
FAKE_CODEX_TOUCH="src/a.py" "$S/codex_run.sh" "$P/T1.md" "$R" >/dev/null 2>&1
RD="$(rundir_of "$R")"
r1="$(cat "$RD/attempt-1/report.md")"; e1="$(cat "$RD/attempt-1/events.jsonl")"
printf 'root cause: foo\n' >"$P/T1.hint-1.md"
out=$(FAKE_CODEX_TOUCH="src/a.py" "$S/codex_resume.sh" "$P/T1.hint-1.md" "$R" "$RD" 2>&1); rc=$?
check "resume succeeds" "$rc" "0"
[ -d "$RD/attempt-2" ] && ok "attempt-2 created" || bad "no attempt-2"
check "attempt-1 report intact" "$(cat "$RD/attempt-1/report.md")" "$r1"
check "attempt-1 events intact" "$(cat "$RD/attempt-1/events.jsonl")" "$e1"

echo "== resume: targeted session, correct flag order =="
LOG="$TMPROOT/argv3"; : >"$LOG"
FAKE_CODEX_LOG="$LOG" FAKE_CODEX_TOUCH="src/a.py" \
  "$S/codex_resume.sh" "$P/T1.hint-1.md" "$R" "$RD" >/dev/null 2>&1
argv="$(grep '^ARGV:' "$LOG" | tail -1)"
has "resumes the recorded session, not --last" "$argv" "resume thr-abc123"
hasnt "does not fall back to --last" "$argv" "--last"
# `--cd` and `--sandbox` belong to `exec`; after the `resume` subcommand the
# CLI rejects them.
case "$argv" in
  *"exec --cd"*) ok "exec options precede the subcommand" ;;
  *) bad "options misplaced: $argv" ;;
esac
case "$argv" in
  *"--json resume"*) ok "resume comes after the options" ;;
  *) bad "subcommand misplaced: $argv" ;;
esac

echo "== resume: extra args are not dropped =="
# A fresh run directory: the attempt cap counts attempts per run, and the
# resumes above have already used this one up.
R="$(new_repo res1b)"; P="$(new_plan "$R" auth)"
FAKE_CODEX_TOUCH="src/a.py" "$S/codex_run.sh" "$P/T1.md" "$R" >/dev/null 2>&1
RD="$(rundir_of "$R")"; printf 'hint\n' >"$P/T1.hint-1.md"
LOG="$TMPROOT/argv4"; : >"$LOG"
FAKE_CODEX_LOG="$LOG" CODEX_EXTRA_ARGS="--config foo=bar" FAKE_CODEX_TOUCH="src/a.py" \
  "$S/codex_resume.sh" "$P/T1.hint-1.md" "$R" "$RD" >/dev/null 2>&1
has "CODEX_EXTRA_ARGS reaches resume" "$(grep '^ARGV:' "$LOG" | tail -1)" "--config foo=bar"

echo "== resume: mode selection =="
R="$(new_repo res2)"; P="$(new_plan "$R" auth)"
FAKE_CODEX_TOUCH="src/a.py" "$S/codex_run.sh" "$P/T1.md" "$R" >/dev/null 2>&1
RD="$(rundir_of "$R")"
printf 'hint\n' >"$P/T1.hint-1.md"
LOG="$TMPROOT/argv5"; : >"$LOG"
FAKE_CODEX_NO_RESUME=1 FAKE_CODEX_LOG="$LOG" FAKE_CODEX_TOUCH="src/a.py" \
  "$S/codex_resume.sh" "$P/T1.hint-1.md" "$R" "$RD" >/dev/null 2>&1
hasnt "old CLI falls back to fresh" "$(grep '^ARGV:' "$LOG" | tail -1)" " resume"
check "exactly one run charged" "$(grep -c '^ARGV:' "$LOG")" "1"

: >"$RD/thread_id"
LOG="$TMPROOT/argv6"; : >"$LOG"
FAKE_CODEX_LOG="$LOG" FAKE_CODEX_TOUCH="src/a.py" \
  "$S/codex_resume.sh" "$P/T1.hint-1.md" "$R" "$RD" >/dev/null 2>&1
hasnt "no session id means fresh, never --last" "$(grep '^ARGV:' "$LOG" | tail -1)" "--last"
out=$(CODEX_RESUME_MODE=resume "$S/codex_resume.sh" "$P/T1.hint-1.md" "$R" "$RD" 2>&1); rc=$?
check "explicit resume without an id is an error" "$rc" "2"
out=$(CODEX_RESUME_MODE=bogus "$S/codex_resume.sh" "$P/T1.hint-1.md" "$R" "$RD" 2>&1); rc=$?
check "unknown mode rejected" "$rc" "2"

echo "== resume: a task failure is not mistaken for an unsupported CLI =="
R="$(new_repo res3)"; P="$(new_plan "$R" auth)"
FAKE_CODEX_TOUCH="src/a.py" "$S/codex_run.sh" "$P/T1.md" "$R" >/dev/null 2>&1
RD="$(rundir_of "$R")"; printf 'hint\n' >"$P/T1.hint-1.md"
LOG="$TMPROOT/argv7"; : >"$LOG"
FAKE_CODEX_RC=1 FAKE_CODEX_LOG="$LOG" \
  "$S/codex_resume.sh" "$P/T1.hint-1.md" "$R" "$RD" >/dev/null 2>&1; rc=$?
check "propagates Codex's exit code" "$rc" "1"
check "no redundant second run" "$(grep -c '^ARGV:' "$LOG")" "1"

echo "== resume: the attempt cap is enforced, not just documented =="
R="$(new_repo res4)"; P="$(new_plan "$R" auth)"
FAKE_CODEX_TOUCH="src/a.py" "$S/codex_run.sh" "$P/T1.md" "$R" >/dev/null 2>&1
RD="$(rundir_of "$R")"; printf 'hint\n' >"$P/T1.hint-1.md"
FAKE_CODEX_TOUCH="src/a.py" "$S/codex_resume.sh" "$P/T1.hint-1.md" "$R" "$RD" >/dev/null 2>&1
FAKE_CODEX_TOUCH="src/a.py" "$S/codex_resume.sh" "$P/T1.hint-1.md" "$R" "$RD" >/dev/null 2>&1
out=$(FAKE_CODEX_TOUCH="src/a.py" "$S/codex_resume.sh" "$P/T1.hint-1.md" "$R" "$RD" 2>&1); rc=$?
check "fourth attempt refused" "$rc" "2"
has "tells the orchestrator to escalate" "$out" "escalate"
out=$(CODEX_MAX_ATTEMPTS=0 FAKE_CODEX_TOUCH="src/a.py" \
  "$S/codex_resume.sh" "$P/T1.hint-1.md" "$R" "$RD" 2>&1); rc=$?
check "cap can be lifted deliberately" "$rc" "0"

echo "== resume: a rejected call must not burn an attempt =="
# Attempts are counted by directory, so creating one before the mode checks
# pass would leave an empty attempt behind and consume a slot off the cap
# without Codex ever running.
R="$(new_repo res6)"; P="$(new_plan "$R" auth)"
FAKE_CODEX_TOUCH="src/a.py" "$S/codex_run.sh" "$P/T1.md" "$R" >/dev/null 2>&1
RD="$(rundir_of "$R")"; printf 'hint\n' >"$P/T1.hint-1.md"
: >"$RD/thread_id"
CODEX_RESUME_MODE=resume "$S/codex_resume.sh" "$P/T1.hint-1.md" "$R" "$RD" >/dev/null 2>&1
[ -d "$RD/attempt-2" ] && bad "empty attempt-2 left behind" || ok "no attempt left behind"
CODEX_RESUME_MODE=bogus "$S/codex_resume.sh" "$P/T1.hint-1.md" "$R" "$RD" >/dev/null 2>&1
[ -d "$RD/attempt-2" ] && bad "empty attempt-2 left behind" || ok "bad mode leaves nothing"
FAKE_CODEX_TOUCH="src/a.py" "$S/codex_resume.sh" "$P/T1.hint-1.md" "$R" "$RD" >/dev/null 2>&1
[ -d "$RD/attempt-2" ] && ok "a real resume still opens attempt-2" || bad "attempt-2 missing"

echo "== the contract is frozen at run time =="
R="$(new_repo res7)"; P="$(new_plan "$R" auth)"
printf 'pytest -q\n' >"$P/T1.test"
FAKE_CODEX_TOUCH="src/a.py" "$S/codex_run.sh" "$P/T1.md" "$R" >/dev/null 2>&1
RD="$(rundir_of "$R")"
for f in task.md allowlist test; do
  [ -f "$RD/$f" ] && ok "frozen $f" || bad "missing frozen $f"
done
check "per-task test file wins" "$(cat "$RD/test")" "pytest -q"
check "frozen packet matches" "$(cat "$RD/task.md")" "$(cat "$P/T1.md")"

echo "== resume: scope baseline stays the task's start =="
R="$(new_repo res5)"; P="$(new_plan "$R" auth)"
FAKE_CODEX_TOUCH="src/a.py" "$S/codex_run.sh" "$P/T1.md" "$R" >/dev/null 2>&1
RD="$(rundir_of "$R")"; printf 'hint\n' >"$P/T1.hint-1.md"
out=$(FAKE_CODEX_TOUCH="docs/d.md" "$S/codex_resume.sh" "$P/T1.hint-1.md" "$R" "$RD" 2>&1); rc=$?
check "cumulative violation caught" "$rc" "3"

finish
