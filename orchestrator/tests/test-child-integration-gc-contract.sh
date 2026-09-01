#!/usr/bin/env bash
# Behavioral contract for verified child integration and post-batch child GC.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INTEGRATE="$ROOT/scripts/integrate-task.sh"
OUTCOME="$ROOT/scripts/task-outcome.py"
GC="$ROOT/scripts/orchestrator-gc.sh"
LIFECYCLE="$ROOT/scripts/task-worktree.sh"
VALIDATOR="$ROOT/scripts/validate-task-dag.sh"
SKILL="$ROOT/skills/orchestrating/references/cleanup-and-rework.md"
SHARED_LOCK="$ROOT/scripts/coordinator_lifecycle_lock.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

N=0
OK=0
check() {
  local label="$1"
  shift
  N=$((N + 1))
  if "$@" >/dev/null 2>&1; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}

setup_fixture() {
  local name="$1"
  FIXTURE="$TMP/$name"
  HUB="$FIXTURE/.orchestrator"
  CONTROL="$HUB/control/mission"
  TASK_DIR="$FIXTURE/task"
  REPO="$FIXTURE/repo"
  REMOTE="$FIXTURE/remote.git"
  PARENT="$FIXTURE/parent"
  CHILD="$FIXTURE/child"
  BRANCH="orc-task/mission/task-a"
  mkdir -p "$CONTROL" "$TASK_DIR" "$HUB/missions"
  MISSION_DIR="$HUB/missions/mission"
  mkdir -p "$MISSION_DIR"
  printf 'request\n' > "$MISSION_DIR/request.md"
  printf 'Briefs: brief.md, brief-exec.md\n' > "$MISSION_DIR/MISSION.md"
  printf 'planned\n' > "$MISSION_DIR/state"
  printf 'session_id: fable-session\nbackend: claude-headless\nmodel: claude-fable-5\nstage: plan\n' > "$MISSION_DIR/session.txt"
  printf '0.4.0\n' > "$CONTROL/pipeline-version"
  printf 'fable-opus\n' > "$MISSION_DIR/planning-backend"
  printf 'fable-opus\n' > "$CONTROL/planning-backend"
  printf 'fable-session\n' > "$CONTROL/planning-session-id"
  printf 'design\n' > "$CONTROL/approved-design.md"
  printf 'plan\n' > "$CONTROL/approved-plan.md"
  printf 'brief\n' > "$CONTROL/brief-exec.md"
  printf '{"version":1,"mission":"mission","tasks":[{"id":"task-a","depends_on":[],"files":["child.txt"],"contracts":[],"verification":["true"],"state":"ready"}]}\n' > "$CONTROL/approved-task-dag.json"
  (cd "$CONTROL" && shasum -a 256 approved-design.md approved-plan.md brief-exec.md approved-task-dag.json > approved.sha256)
  git init -q --bare "$REMOTE"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t
  git -C "$REPO" config user.name t
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" remote add origin "$REMOTE"
  printf 'base\n' > "$REPO/shared.txt"
  git -C "$REPO" add shared.txt
  git -C "$REPO" commit -qm base
  git -C "$REPO" branch -M main
  git -C "$REPO" push -q -u origin main
  git -C "$REPO" worktree add -qb orc/mission "$PARENT" main >/dev/null
  PARENT_BASE="$(git -C "$PARENT" rev-parse HEAD)"
  ORC_TASK_WORKTREE_TESTING=1 ORC_TASK_WORKTREE_TEST_FIXTURE_ROOT="$FIXTURE" \
    "$LIFECYCLE" create --create-mode test-fixture --mission-dir "$MISSION_DIR" \
      --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
      --mission mission --task-id task-a --repo "$REPO" \
      --parent-worktree "$PARENT" --worktree "$CHILD" >/dev/null
  printf '%s\n' "$(cd "$TASK_DIR" && pwd -P)" \
    > "$CONTROL/tasks/task-a/task-state-dir"
  printf 'thread-task-a\n' > "$CONTROL/tasks/task-a/accepted-thread-id"
  printf 'thread-task-a\n' > "$TASK_DIR/accepted-thread-id"
  printf '%s\n' \
    0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    > "$CONTROL/tasks/task-a/outcome-nonce"
  printf 'archived\n' > "$CONTROL/tasks/task-a/task-window-state"
  printf 'child\n' > "$CHILD/child.txt"
  git -C "$CHILD" add child.txt
  git -C "$CHILD" commit -qm child
  CHILD_TIP="$(git -C "$CHILD" rev-parse HEAD)"
  printf 'completed\n' > "$TASK_DIR/state"
  printf 'task-a verified at %s\n' "$CHILD_TIP" > "$TASK_DIR/report.md"
  printf '%s\n' "$CHILD_TIP" > "$TASK_DIR/verification.sha"
  printf '%s\n' "$CHILD_TIP" > "$CONTROL/tasks/task-a/coordinator-verification.sha"
  printf 'coordinator verified %s\n' "$CHILD_TIP" > "$CONTROL/tasks/task-a/coordinator-verification.md"
  printf '%s\n' "$PARENT_BASE" > "$CONTROL/tasks/task-a/parent-verification.sha"
}

integrate_fixture() {
  local rc
  "$INTEGRATE" --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
    --mission mission --task-id task-a --parent-worktree "$PARENT" \
    --expected-parent-tip "$1"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    # Most GC fixtures model the post-review acceptance boundary. Individual
    # tests override this state to prove earlier phases cannot collect.
    printf 'accepted\n' > "$MISSION_DIR/state"
    printf 'resolved\n' > "$CONTROL/review-resolution"
  fi
  return "$rc"
}

unchanged_parent() {
  [[ "$(git -C "$PARENT" rev-parse HEAD)" == "$1" && \
    "$(tr -d '[:space:]' < "$TASK_DIR/state")" == completed ]]
}

check "child integration script exists and is executable" test -x "$INTEGRATE"
check "shared coordinator lifecycle lock helper is installed" test -x "$SHARED_LOCK"
check "integration acquires the shared lifecycle lock before its task lock" \
  grep -Fq 'coordinator_lifecycle_lock.py' "$INTEGRATE"
check "mission cleanup acquires the shared lifecycle lock before its GC lock" \
  grep -Fq 'coordinator_lifecycle_lock.py' "$GC"

setup_fixture happy
OLD_PARENT="$PARENT_BASE"
integrate_fixture "$OLD_PARENT" >/dev/null 2>&1
HAPPY_RC=$?
INTEGRATED_SHA="$(cat "$CONTROL/tasks/task-a/integrated_sha" 2>/dev/null || true)"
check "completed child integrates from exact manifest branch/base and parent tip" bash -c \
  '[[ "$1" -eq 0 && -n "$2" && "$2" = "$(git -C "$3" rev-parse HEAD)" && "$(cat "$4")" = integrated && "$(cat "$5")" = integrated ]]' \
  _ "$HAPPY_RC" "$INTEGRATED_SHA" "$PARENT" "$TASK_DIR/state" "$CONTROL/tasks/task-a/state"
check "integration preserves both histories with a merge commit" bash -c \
  '[[ "$(git -C "$1" rev-list --parents -n 1 "$2" | awk "{print NF}")" -eq 3 ]] && git -C "$1" merge-base --is-ancestor "$3" "$2" && git -C "$1" merge-base --is-ancestor "$4" "$2"' \
  _ "$REPO" "$INTEGRATED_SHA" "$OLD_PARENT" "$CHILD_TIP"

setup_fixture missing-coordinator-verification
rm "$CONTROL/tasks/task-a/coordinator-verification.sha" \
  "$CONTROL/tasks/task-a/coordinator-verification.md"
MISSING_COORDINATOR_VERIFICATION_PARENT="$PARENT_BASE"
integrate_fixture "$MISSING_COORDINATOR_VERIFICATION_PARENT" >/dev/null \
  2>"$FIXTURE/missing-coordinator-verification.err"
MISSING_COORDINATOR_VERIFICATION_RC=$?
check "integration requires coordinator-owned exact-tip child verification" bash -c \
  '[[ "$1" -ne 0 && "$(git -C "$2" rev-parse HEAD)" = "$3" && "$(cat "$4")" = completed ]] && grep -Fq "coordinator verification" "$5"' \
  _ "$MISSING_COORDINATOR_VERIFICATION_RC" "$PARENT" \
  "$MISSING_COORDINATOR_VERIFICATION_PARENT" "$TASK_DIR/state" \
  "$FIXTURE/missing-coordinator-verification.err"

setup_fixture integration-scope-escape
printf 'outside frozen task scope\n' > "$CHILD/outside.txt"
git -C "$CHILD" add outside.txt
git -C "$CHILD" commit -qm 'escape frozen task scope'
SCOPE_ESCAPE_TIP="$(git -C "$CHILD" rev-parse HEAD)"
printf 'task-a forged verification at %s\n' "$SCOPE_ESCAPE_TIP" > "$TASK_DIR/report.md"
printf '%s\n' "$SCOPE_ESCAPE_TIP" > "$TASK_DIR/verification.sha"
SCOPE_ESCAPE_PARENT="$PARENT_BASE"
integrate_fixture "$SCOPE_ESCAPE_PARENT" >/dev/null 2>"$FIXTURE/scope-escape.err"
SCOPE_ESCAPE_RC=$?
check "integration independently rejects committed paths outside approved task DAG" bash -c \
  '[[ "$1" -ne 0 && "$(git -C "$2" rev-parse HEAD)" = "$3" && "$(cat "$4")" = completed ]] && grep -Fq "approved task DAG" "$5"' \
  _ "$SCOPE_ESCAPE_RC" "$PARENT" "$SCOPE_ESCAPE_PARENT" "$TASK_DIR/state" "$FIXTURE/scope-escape.err"

setup_fixture happy-after-scope
OLD_PARENT="$PARENT_BASE"
integrate_fixture "$OLD_PARENT" >/dev/null 2>&1
HAPPY_RC=$?
INTEGRATED_SHA="$(cat "$CONTROL/tasks/task-a/integrated_sha" 2>/dev/null || true)"
integrate_fixture "$INTEGRATED_SHA" >/dev/null 2>&1
check "repeated integration is an idempotent no-op" bash -c \
  '[[ "$1" -eq 0 && "$(git -C "$2" rev-parse HEAD)" = "$3" && "$(cat "$4")" = "$3" ]]' \
  _ "$?" "$PARENT" "$INTEGRATED_SHA" "$CONTROL/tasks/task-a/integrated_sha"
printf 'collected\n' > "$CONTROL/tasks/task-a/state"
printf 'collected\n' > "$TASK_DIR/state"
integrate_fixture "$INTEGRATED_SHA" >/dev/null 2>&1
check "integration retry never downgrades collected state" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2")" = collected && "$(cat "$3")" = collected ]]' \
  _ "$?" "$CONTROL/tasks/task-a/state" "$TASK_DIR/state"
printf 'cleanup_pending\n' > "$CONTROL/tasks/task-a/state"
printf 'cleanup_pending\n' > "$TASK_DIR/state"
integrate_fixture "$INTEGRATED_SHA" >/dev/null 2>&1
check "integration retry preserves cleanup_pending state" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2")" = cleanup_pending && "$(cat "$3")" = cleanup_pending ]]' \
  _ "$?" "$CONTROL/tasks/task-a/state" "$TASK_DIR/state"

setup_fixture state-directory
integrate_fixture "$PARENT_BASE" >/dev/null
STATE_DIRECTORY_PARENT="$(git -C "$PARENT" rev-parse HEAD)"
rm -f "$TASK_DIR/state"
mkdir "$TASK_DIR/state"
integrate_fixture "$STATE_DIRECTORY_PARENT" >/dev/null 2>&1
STATE_DIRECTORY_RC=$?
check "integration state publication refuses a directory destination without mutation" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && -z "$(find "$2" -mindepth 1 -maxdepth 1 -print -quit)" ]]' \
  _ "$STATE_DIRECTORY_RC" "$TASK_DIR/state"

setup_fixture state-symlink
integrate_fixture "$PARENT_BASE" >/dev/null
STATE_SYMLINK_PARENT="$(git -C "$PARENT" rev-parse HEAD)"
STATE_SYMLINK_OUTSIDE="$FIXTURE/outside-state"
printf 'outside-sentinel\n' > "$STATE_SYMLINK_OUTSIDE"
rm -f "$TASK_DIR/state"
ln -s "$STATE_SYMLINK_OUTSIDE" "$TASK_DIR/state"
integrate_fixture "$STATE_SYMLINK_PARENT" >/dev/null 2>&1
STATE_SYMLINK_RC=$?
check "integration state publication refuses a symlink destination" bash -c \
  '[[ "$1" -ne 0 && -L "$2" && "$(cat "$3")" = outside-sentinel ]]' \
  _ "$STATE_SYMLINK_RC" "$TASK_DIR/state" "$STATE_SYMLINK_OUTSIDE"

setup_fixture state-race
integrate_fixture "$PARENT_BASE" >/dev/null
STATE_RACE_PARENT="$(git -C "$PARENT" rev-parse HEAD)"
STATE_RACE_OUTSIDE="$FIXTURE/race-outside-state"
printf 'race-sentinel\n' > "$STATE_RACE_OUTSIDE"
ORC_ATOMIC_REPLACE_TEST_TARGET="$(cd "$TASK_DIR" && pwd -P)/state" \
  ORC_ATOMIC_REPLACE_TEST_MODE=symlink \
  ORC_ATOMIC_REPLACE_TEST_LINK_TARGET="$STATE_RACE_OUTSIDE" \
  integrate_fixture "$STATE_RACE_PARENT" >/dev/null 2>&1
STATE_RACE_RC=$?
check "integration detects a deterministic regular-to-symlink publication race" bash -c \
  '[[ "$1" -ne 0 && -L "$2" && "$(cat "$3")" = race-sentinel ]]' \
  _ "$STATE_RACE_RC" "$TASK_DIR/state" "$STATE_RACE_OUTSIDE"

setup_fixture interrupted-integration
ORC_INTEGRATE_TEST_FAIL_AFTER_MERGE=1 integrate_fixture "$PARENT_BASE" >/dev/null 2>&1
INTERRUPTED_RC=$?
MERGED_BUT_UNRECORDED="$(git -C "$PARENT" rev-parse HEAD)"
INTENT_SURVIVED=0
[[ -f "$CONTROL/tasks/task-a/integration-intent" ]] && INTENT_SURVIVED=1
printf '%s\n' "$MERGED_BUT_UNRECORDED" > "$CONTROL/tasks/task-a/parent-verification.sha"
integrate_fixture "$MERGED_BUT_UNRECORDED" >/dev/null 2>&1
RECOVERY_RC=$?
check "post-merge interruption leaves durable intent and returns failure" bash -c \
  '[[ "$1" -ne 0 && "$2" -eq 1 && "$3" != "$4" ]]' \
  _ "$INTERRUPTED_RC" "$INTENT_SURVIVED" "$MERGED_BUT_UNRECORDED" "$PARENT_BASE"
check "retry adopts only the exact intent merge without another merge" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2")" = "$3" && "$(cat "$4")" = integrated && ! -e "$5" && "$(git -C "$6" rev-list --parents -n 1 "$3" | awk "{print NF}")" -eq 3 ]]' \
  _ "$RECOVERY_RC" "$CONTROL/tasks/task-a/integrated_sha" "$MERGED_BUT_UNRECORDED" "$CONTROL/tasks/task-a/state" "$CONTROL/tasks/task-a/integration-intent" "$REPO"

setup_fixture interrupted-after-ref-cas
ORC_INTEGRATE_TEST_FAIL_AFTER_REF_UPDATE=1 integrate_fixture "$PARENT_BASE" >/dev/null 2>&1
REF_CAS_INTERRUPTED_RC=$?
REF_CAS_TIP="$(git -C "$PARENT" rev-parse HEAD)"
REF_CAS_DIRTY="$(git -C "$PARENT" status --porcelain --untracked-files=all)"
REF_CAS_INTENT_SURVIVED=0
[[ -f "$CONTROL/tasks/task-a/integration-intent" ]] && REF_CAS_INTENT_SURVIVED=1
REF_CAS_CONTROL_BEFORE="$(cat "$CONTROL/tasks/task-a/state")"
printf '%s\n' "$REF_CAS_TIP" > "$CONTROL/tasks/task-a/parent-verification.sha"
integrate_fixture "$REF_CAS_TIP" >/dev/null 2>&1
REF_CAS_RECOVERY_RC=$?
check "post-ref-CAS interruption leaves exact intent and no false completion" bash -c \
  '[[ "$1" -ne 0 && "$2" != "$3" && "$4" -eq 1 && "$5" != integrated ]]' \
  _ "$REF_CAS_INTERRUPTED_RC" "$REF_CAS_TIP" "$PARENT_BASE" "$REF_CAS_INTENT_SURVIVED" "$REF_CAS_CONTROL_BEFORE"
check "post-ref-CAS retry reconciles the original hook-free merge and publishes once" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/integrated_sha")" = "$3" && "$(cat "$2/state")" = integrated && ! -e "$2/integration-intent" && -z "$(git -C "$4" status --porcelain --untracked-files=all)" ]]' \
  _ "$REF_CAS_RECOVERY_RC" "$CONTROL/tasks/task-a" "$REF_CAS_TIP" "$PARENT"

setup_fixture merge-hooks-bypassed
HOOKS_DIR="$(git -C "$REPO" rev-parse --absolute-git-dir)/hooks"
mkdir -p "$HOOKS_DIR"
HOOK_MARKER="$FIXTURE/merge-hook-ran"
REF_HOOK_MARKER="$FIXTURE/reference-transaction-hook-ran"
cat > "$HOOKS_DIR/pre-merge-commit" <<SH
#!/bin/sh
printf 'hook outside scope\n' > '$PARENT/outside-hook.txt'
git -C '$PARENT' add -- outside-hook.txt
printf 'ran\n' > '$HOOK_MARKER'
SH
chmod +x "$HOOKS_DIR/pre-merge-commit"
cat > "$HOOKS_DIR/reference-transaction" <<SH
#!/bin/sh
printf 'ran\n' > '$REF_HOOK_MARKER'
SH
chmod +x "$HOOKS_DIR/reference-transaction"
integrate_fixture "$PARENT_BASE" >/dev/null 2>&1
HOOK_FREE_RC=$?
check "integration uses a verified tree and never runs mutating merge hooks" bash -c \
  '[[ "$1" -eq 0 && ! -e "$2" && ! -e "$3" && ! -e "$4/outside-hook.txt" && -z "$(git -C "$4" status --porcelain --untracked-files=all)" && "$(cat "$5/state")" = integrated ]]' \
  _ "$HOOK_FREE_RC" "$HOOK_MARKER" "$REF_HOOK_MARKER" "$PARENT" "$CONTROL/tasks/task-a"

setup_fixture immutable-child-tip
IMMUTABLE_PARENT="$PARENT_BASE"
MALICIOUS_TIP="$(printf 'ref advance\n' | git -C "$REPO" commit-tree "$(git -C "$REPO" rev-parse "${CHILD_TIP}^{tree}")" -p "$CHILD_TIP")"
REF_ADVANCE_BIN="$FIXTURE/ref-advance-bin"
REF_ADVANCE_MARKER="$FIXTURE/ref-advanced"
REAL_GIT="$(command -v git)"
mkdir -p "$REF_ADVANCE_BIN"
cat > "$REF_ADVANCE_BIN/git" <<'SH'
#!/usr/bin/env bash
set -u
if [[ " $* " == *" update-ref -m orchestrator integrate "* && ! -e "$ORC_REF_ADVANCE_MARKER" ]]; then
  "$ORC_REF_ADVANCE_REAL_GIT" -C "$ORC_REF_ADVANCE_REPO" update-ref \
    "refs/heads/$ORC_REF_ADVANCE_BRANCH" "$ORC_REF_ADVANCE_TIP" "$ORC_REF_ATTESTED_TIP" || exit 90
  : > "$ORC_REF_ADVANCE_MARKER"
fi
exec "$ORC_REF_ADVANCE_REAL_GIT" "$@"
SH
chmod +x "$REF_ADVANCE_BIN/git"
PATH="$REF_ADVANCE_BIN:$PATH" ORC_REF_ADVANCE_REAL_GIT="$REAL_GIT" \
  ORC_REF_ADVANCE_REPO="$REPO" ORC_REF_ADVANCE_BRANCH="$BRANCH" \
  ORC_REF_ADVANCE_TIP="$MALICIOUS_TIP" ORC_REF_ATTESTED_TIP="$CHILD_TIP" \
  ORC_REF_ADVANCE_MARKER="$REF_ADVANCE_MARKER" \
  integrate_fixture "$IMMUTABLE_PARENT" >/dev/null 2>&1
REF_ADVANCE_RC=$?
REF_ADVANCE_PARENT="$(git -C "$PARENT" rev-parse HEAD)"
REF_ADVANCE_SECOND_PARENT="$(git -C "$PARENT" rev-parse "${REF_ADVANCE_PARENT}^2" 2>/dev/null || true)"
check "branch ref advance cannot make integration consume an unattested child tip" bash -c \
  '[[ -e "$1" && "$(git -C "$2" rev-parse "refs/heads/$3")" = "$4" ]] && { [[ "$5" -eq 0 && "$6" = "$7" ]] || [[ "$5" -ne 0 && "$8" = "$9" ]]; }' \
  _ "$REF_ADVANCE_MARKER" "$REPO" "$BRANCH" "$MALICIOUS_TIP" "$REF_ADVANCE_RC" "$REF_ADVANCE_SECOND_PARENT" "$CHILD_TIP" "$REF_ADVANCE_PARENT" "$IMMUTABLE_PARENT"

setup_fixture wrong-task-state-dir
mkdir -p "$FIXTURE/other-task-state"
printf '%s\n' "$FIXTURE/other-task-state" > "$CONTROL/tasks/task-a/task-state-dir"
WRONG_TASK_STATE_PARENT="$PARENT_BASE"
integrate_fixture "$WRONG_TASK_STATE_PARENT" >/dev/null 2>&1
WRONG_TASK_STATE_RC=$?
check "integration refuses a task directory outside coordinator task-state-dir authority" bash -c \
  '[[ "$1" -ne 0 && "$(git -C "$2" rev-parse HEAD)" = "$3" && "$(cat "$4/state")" = completed ]]' \
  _ "$WRONG_TASK_STATE_RC" "$PARENT" "$WRONG_TASK_STATE_PARENT" "$TASK_DIR"

setup_fixture wrong-state
printf 'running\n' > "$TASK_DIR/state"
BEFORE="$PARENT_BASE"
integrate_fixture "$BEFORE" >/dev/null 2>&1
RC=$?
check "running child is preserved and cannot integrate" bash -c \
  '[[ "$1" -ne 0 && "$(git -C "$2" rev-parse HEAD)" = "$3" && -d "$4" ]]' \
  _ "$RC" "$PARENT" "$BEFORE" "$CHILD"

setup_fixture integration-lock
LOCK_PATH="$CONTROL/.task-integration.lock"
LOCK_READY="$FIXTURE/lock-ready"
LOCK_RELEASE="$FIXTURE/lock-release"
: > "$LOCK_PATH"
chmod 0400 "$LOCK_PATH"
mkfifo "$LOCK_RELEASE"
python3 - "$LOCK_PATH" "$LOCK_READY" "$LOCK_RELEASE" <<'PY' &
import fcntl, pathlib, sys
with open(sys.argv[1], "rb") as handle:
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).write_text("ready\n")
    with open(sys.argv[3], "r") as release:
        release.readline()
PY
LOCK_HOLDER=$!
ATTEMPTS=0
while [[ ! -e "$LOCK_READY" && "$ATTEMPTS" -lt 200 ]]; do
  ATTEMPTS=$((ATTEMPTS + 1))
  sleep 0.01
done
BEFORE="$PARENT_BASE"
integrate_fixture "$BEFORE" >/dev/null 2>&1
LOCKED_RC=$?
AFTER_LOCKED="$(git -C "$PARENT" rev-parse HEAD)"
printf 'release\n' > "$LOCK_RELEASE"
wait "$LOCK_HOLDER"
printf '%s\n' "$AFTER_LOCKED" > "$CONTROL/tasks/task-a/parent-verification.sha"
integrate_fixture "$AFTER_LOCKED" >/dev/null 2>&1
LOCK_RETRY_RC=$?
check "held coordinator integration lock prevents parent mutation" bash -c \
  '[[ "$1" -ne 0 && "$2" = "$3" ]]' _ "$LOCKED_RC" "$AFTER_LOCKED" "$BEFORE"
check "integration retries after the advisory lock is released" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2")" = integrated ]]' \
  _ "$LOCK_RETRY_RC" "$CONTROL/tasks/task-a/state"

setup_fixture lifecycle-integration-vs-gc
LIFECYCLE_HOOK="$FIXTURE/lifecycle-hook"
mkdir -p "$LIFECYCLE_HOOK"
LIFECYCLE_HOOK="$(cd "$LIFECYCLE_HOOK" && pwd -P)"
ORC_COORDINATOR_LIFECYCLE_TEST_HOOK_DIR="$LIFECYCLE_HOOK" \
  ORC_COORDINATOR_LIFECYCLE_TEST_PARTICIPANT=integration \
  "$INTEGRATE" --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
    --mission mission --task-id task-a --parent-worktree "$PARENT" \
    --expected-parent-tip "$PARENT_BASE" > "$FIXTURE/integration.out" \
    2> "$FIXTURE/integration.err" &
LIFECYCLE_INTEGRATION_PID=$!
LIFECYCLE_ATTEMPTS=0
while [[ ! -e "$LIFECYCLE_HOOK/entered-integration" && \
         "$LIFECYCLE_ATTEMPTS" -lt 200 ]]; do
  LIFECYCLE_ATTEMPTS=$((LIFECYCLE_ATTEMPTS + 1))
  sleep 0.01
done
LIFECYCLE_INTEGRATION_ENTERED=0
LIFECYCLE_GC_WAITED=0
LIFECYCLE_INTEGRATION_RC=127
LIFECYCLE_GC_RC=127
if [[ -e "$LIFECYCLE_HOOK/entered-integration" ]]; then
  LIFECYCLE_INTEGRATION_ENTERED=1
  "$GC" --hub "$HUB" --mission mission --clean > "$FIXTURE/gc.out" \
    2> "$FIXTURE/gc.err" &
  LIFECYCLE_GC_PID=$!
  sleep 0.2
  if kill -0 "$LIFECYCLE_GC_PID" 2>/dev/null; then
    LIFECYCLE_GC_WAITED=1
  fi
  : > "$LIFECYCLE_HOOK/continue-integration"
  wait "$LIFECYCLE_INTEGRATION_PID"
  LIFECYCLE_INTEGRATION_RC=$?
  wait "$LIFECYCLE_GC_PID"
  LIFECYCLE_GC_RC=$?
else
  wait "$LIFECYCLE_INTEGRATION_PID"
  LIFECYCLE_INTEGRATION_RC=$?
fi
check "integration and mission GC serialize on one coordinator lifecycle epoch" bash -c \
  '[[ "$1" -eq 1 && "$2" -eq 1 && "$3" -eq 0 && "$4" -ne 0 &&
     "$(cat "$5/state")" = integrated && -d "$6" &&
     "$(git -C "$7" rev-parse HEAD)" != "$8" ]]' \
  _ "$LIFECYCLE_INTEGRATION_ENTERED" "$LIFECYCLE_GC_WAITED" \
  "$LIFECYCLE_INTEGRATION_RC" "$LIFECYCLE_GC_RC" \
  "$CONTROL/tasks/task-a" "$CHILD" "$PARENT" "$PARENT_BASE"

setup_fixture lifecycle-reopen-vs-gc
integrate_fixture "$PARENT_BASE" >/dev/null 2>&1
printf 'unarchived\n' > "$CONTROL/tasks/task-a/task-window-state"
printf '%s\n' \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  > "$CONTROL/tasks/task-a/latest-outcome"
REOPEN_LIFECYCLE_HOOK="$FIXTURE/reopen-lifecycle-hook"
mkdir -p "$REOPEN_LIFECYCLE_HOOK"
REOPEN_LIFECYCLE_HOOK="$(cd "$REOPEN_LIFECYCLE_HOOK" && pwd -P)"
ORC_COORDINATOR_LIFECYCLE_TEST_HOOK_DIR="$REOPEN_LIFECYCLE_HOOK" \
  ORC_COORDINATOR_LIFECYCLE_TEST_PARTICIPANT=reopen \
  "$OUTCOME" reopen --control-dir "$(cd "$CONTROL" && pwd -P)" \
    --task-dir "$(cd "$TASK_DIR" && pwd -P)" --task-id task-a \
    --parent-worktree "$(cd "$PARENT" && pwd -P)" --expected-generation 1 \
    > "$FIXTURE/reopen.out" 2> "$FIXTURE/reopen.err" &
REOPEN_LIFECYCLE_PID=$!
REOPEN_LIFECYCLE_ATTEMPTS=0
while [[ ! -e "$REOPEN_LIFECYCLE_HOOK/entered-reopen" && \
         "$REOPEN_LIFECYCLE_ATTEMPTS" -lt 200 ]]; do
  REOPEN_LIFECYCLE_ATTEMPTS=$((REOPEN_LIFECYCLE_ATTEMPTS + 1))
  sleep 0.01
done
REOPEN_LIFECYCLE_ENTERED=0
REOPEN_GC_WAITED=0
REOPEN_LIFECYCLE_RC=127
REOPEN_GC_RC=127
if [[ -e "$REOPEN_LIFECYCLE_HOOK/entered-reopen" ]]; then
  REOPEN_LIFECYCLE_ENTERED=1
  "$GC" --hub "$HUB" --mission mission --clean > "$FIXTURE/reopen-gc.out" \
    2> "$FIXTURE/reopen-gc.err" &
  REOPEN_GC_PID=$!
  sleep 0.2
  if kill -0 "$REOPEN_GC_PID" 2>/dev/null; then
    REOPEN_GC_WAITED=1
  fi
  : > "$REOPEN_LIFECYCLE_HOOK/continue-reopen"
  wait "$REOPEN_LIFECYCLE_PID"
  REOPEN_LIFECYCLE_RC=$?
  wait "$REOPEN_GC_PID"
  REOPEN_GC_RC=$?
else
  wait "$REOPEN_LIFECYCLE_PID"
  REOPEN_LIFECYCLE_RC=$?
fi
check "reopen and mission GC serialize before either changes the task epoch" bash -c \
  '[[ "$1" -eq 1 && "$2" -eq 1 && "$3" -eq 0 && "$4" -ne 0 &&
     "$(cat "$5/state")" = ready && "$(cat "$6/state")" = ready &&
     "$(cat "$5/generation")" = 2 && -d "$7" ]]' \
  _ "$REOPEN_LIFECYCLE_ENTERED" "$REOPEN_GC_WAITED" \
  "$REOPEN_LIFECYCLE_RC" "$REOPEN_GC_RC" "$CONTROL/tasks/task-a" \
  "$TASK_DIR" "$CHILD"

setup_fixture wrong-branch
python3 - "$CONTROL/tasks/task-a/worktrees.txt" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
parts = p.read_text().rstrip("\n").split("\t")
parts[1] = "orc-task/mission/not-task-a"
p.write_text("\t".join(parts) + "\n")
PY
BEFORE="$PARENT_BASE"
integrate_fixture "$BEFORE" >/dev/null 2>&1
RC=$?
check "manifest branch mismatch fails closed before parent mutation" bash -c \
  '[[ "$1" -ne 0 && "$(git -C "$2" rev-parse HEAD)" = "$3" && -d "$4" ]]' \
  _ "$RC" "$PARENT" "$BEFORE" "$CHILD"

setup_fixture wrong-base
python3 - "$CONTROL/tasks/task-a/worktrees.txt" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
parts = p.read_text().rstrip("\n").split("\t")
parts[2] = "0000000000000000000000000000000000000000"
p.write_text("\t".join(parts) + "\n")
PY
BEFORE="$PARENT_BASE"
integrate_fixture "$BEFORE" >/dev/null 2>&1
RC=$?
check "manifest base mismatch preserves the parent" unchanged_parent "$BEFORE"
check "manifest base mismatch returns failure" test "$RC" -ne 0

setup_fixture stale-parent
printf 'parent advance\n' > "$PARENT/parent.txt"
git -C "$PARENT" add parent.txt
git -C "$PARENT" commit -qm parent-advance
ACTUAL_PARENT="$(git -C "$PARENT" rev-parse HEAD)"
integrate_fixture "$PARENT_BASE" >/dev/null 2>&1
RC=$?
check "stale expected parent tip is refused" bash -c \
  '[[ "$1" -ne 0 && "$(git -C "$2" rev-parse HEAD)" = "$3" ]]' \
  _ "$RC" "$PARENT" "$ACTUAL_PARENT"

setup_fixture dirty-child
printf 'dirty\n' >> "$CHILD/child.txt"
BEFORE="$PARENT_BASE"
integrate_fixture "$BEFORE" >/dev/null 2>&1
RC=$?
check "dirty child worktree is preserved and refused" bash -c \
  '[[ "$1" -ne 0 && -n "$(git -C "$2" status --porcelain --untracked-files=all)" && "$(git -C "$3" rev-parse HEAD)" = "$4" ]]' \
  _ "$RC" "$CHILD" "$PARENT" "$BEFORE"

setup_fixture unverified-child
printf '%s\n' "$PARENT_BASE" > "$TASK_DIR/verification.sha"
BEFORE="$PARENT_BASE"
integrate_fixture "$BEFORE" >/dev/null 2>&1
RC=$?
check "child verification must attest the exact child tip" unchanged_parent "$BEFORE"
check "wrong child verification returns failure" test "$RC" -ne 0

setup_fixture unverified-parent
printf '%s\n' "$CHILD_TIP" > "$CONTROL/tasks/task-a/parent-verification.sha"
BEFORE="$PARENT_BASE"
integrate_fixture "$BEFORE" >/dev/null 2>&1
RC=$?
check "parent verification must attest the expected parent tip" unchanged_parent "$BEFORE"
check "wrong parent verification returns failure" test "$RC" -ne 0

setup_fixture unresolved-rework
: > "$CONTROL/tasks/task-a/unresolved-rework"
BEFORE="$PARENT_BASE"
integrate_fixture "$BEFORE" >/dev/null 2>&1
RC=$?
check "unresolved rework preserves child resources" bash -c \
  '[[ "$1" -ne 0 && "$(git -C "$2" rev-parse HEAD)" = "$3" && -d "$4" ]]' \
  _ "$RC" "$PARENT" "$BEFORE" "$CHILD"

setup_fixture dirty-parent
printf 'dirty\n' > "$PARENT/dirty.txt"
BEFORE="$PARENT_BASE"
integrate_fixture "$BEFORE" >/dev/null 2>&1
RC=$?
check "dirty parent worktree is preserved and refused" bash -c \
  '[[ "$1" -ne 0 && -n "$(git -C "$2" status --porcelain --untracked-files=all)" && "$(git -C "$2" rev-parse HEAD)" = "$3" ]]' \
  _ "$RC" "$PARENT" "$BEFORE"

setup_fixture conflict
printf 'child conflict\n' > "$CHILD/shared.txt"
git -C "$CHILD" add shared.txt
git -C "$CHILD" commit -qm child-conflict
CHILD_TIP="$(git -C "$CHILD" rev-parse HEAD)"
printf '%s\n' "$CHILD_TIP" > "$TASK_DIR/verification.sha"
printf 'parent conflict\n' > "$PARENT/shared.txt"
git -C "$PARENT" add shared.txt
git -C "$PARENT" commit -qm parent-conflict
CURRENT_PARENT="$(git -C "$PARENT" rev-parse HEAD)"
printf '%s\n' "$CURRENT_PARENT" > "$CONTROL/tasks/task-a/parent-verification.sha"
integrate_fixture "$CURRENT_PARENT" >/dev/null 2>&1
RC=$?
check "merge conflict aborts without rewriting or advancing parent" bash -c \
  '[[ "$1" -ne 0 && "$(git -C "$2" rev-parse HEAD)" = "$3" && -z "$(git -C "$2" status --porcelain --untracked-files=all)" && "$(cat "$4")" = completed ]]' \
  _ "$RC" "$PARENT" "$CURRENT_PARENT" "$TASK_DIR/state"

setup_fixture pre-review-retained
integrate_fixture "$PARENT_BASE" >/dev/null
printf 'executed\n' > "$MISSION_DIR/state"
rm -f "$CONTROL/review-resolution"
"$GC" --hub "$HUB" --mission mission --clean >/dev/null 2>&1
PRE_REVIEW_GC_RC=$?
check "all integrated children remain intact before selected-backend review" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && "$(cat "$3/state")" = integrated ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$PRE_REVIEW_GC_RC" "$CHILD" "$CONTROL/tasks/task-a" "$REPO" "$BRANCH"
printf 'review\n' > "$MISSION_DIR/state"
printf 'resolved\n' > "$CONTROL/review-resolution"
"$GC" --hub "$HUB" --mission mission --clean >/dev/null 2>&1
REVIEW_STATE_GC_RC=$?
check "resolved review still retains children until mission acceptance" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && "$(cat "$3/state")" = integrated ]]' \
  _ "$REVIEW_STATE_GC_RC" "$CHILD" "$CONTROL/tasks/task-a"
printf 'accepted\n' > "$MISSION_DIR/state"
printf 'unarchived\n' > "$CONTROL/tasks/task-a/task-window-state"
"$GC" --hub "$HUB" --mission mission --clean >/dev/null 2>&1
UNARCHIVED_GC_RC=$?
check "accepted mission retains Git resources until native child archive succeeds" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && "$(cat "$3/state")" = integrated ]]' \
  _ "$UNARCHIVED_GC_RC" "$CHILD" "$CONTROL/tasks/task-a"

setup_fixture forged-cleanup-pending-sibling
integrate_fixture "$PARENT_BASE" >/dev/null
jq '.tasks += [{"id":"task-b","depends_on":[],"files":["other.txt"],"contracts":[],"verification":["true"],"state":"ready"}]' \
  "$CONTROL/approved-task-dag.json" > "$CONTROL/approved-task-dag.json.tmp"
mv "$CONTROL/approved-task-dag.json.tmp" "$CONTROL/approved-task-dag.json"
(cd "$CONTROL" && shasum -a 256 approved-design.md approved-plan.md brief-exec.md approved-task-dag.json > approved.sha256)
mkdir -p "$CONTROL/tasks/task-b"
printf 'cleanup_pending\n' > "$CONTROL/tasks/task-b/state"
printf 'thread-task-b\n' > "$CONTROL/tasks/task-b/accepted-thread-id"
printf 'archived\n' > "$CONTROL/tasks/task-b/task-window-state"
"$GC" --hub "$HUB" --mission mission --clean >/dev/null 2>&1
FORGED_SIBLING_GC_RC=$?
check "batch preflight refuses cleanup_pending sibling without integration authority before deleting any child" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && "$(cat "$3/state")" = integrated ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$FORGED_SIBLING_GC_RC" "$CHILD" "$CONTROL/tasks/task-a" "$REPO" "$BRANCH"

setup_fixture frozen-dag-drift-before-gc
integrate_fixture "$PARENT_BASE" >/dev/null
printf '\n' >> "$CONTROL/approved-task-dag.json"
"$GC" --hub "$HUB" --mission mission --clean >/dev/null 2>&1
DAG_DRIFT_GC_RC=$?
check "batch GC refuses DAG bytes that drift from frozen approval authority" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && "$(cat "$3/state")" = integrated ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$DAG_DRIFT_GC_RC" "$CHILD" "$CONTROL/tasks/task-a" "$REPO" "$BRANCH"

setup_fixture collect
git -C "$CHILD" push -q -u origin "$BRANCH"
integrate_fixture "$PARENT_BASE" >/dev/null
COLLECTED_SHA="$(cat "$CONTROL/tasks/task-a/integrated_sha")"
REPORT="$($GC --hub "$HUB")"
check "report-only GC identifies an integrated child without mutation" bash -c \
  'grep -Fq "$1" <<<"$2" && [[ -d "$3" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$1"' \
  _ "$BRANCH" "$REPORT" "$CHILD" "$REPO"
$GC --hub "$HUB" --clean >/dev/null 2>&1
GC_RC=$?
check "verified child GC removes exact worktree and local and remote branches" bash -c \
  '[[ "$1" -eq 0 && ! -e "$2" ]] && ! git -C "$3" show-ref --verify --quiet "refs/heads/$4" && ! git --git-dir "$5" show-ref --verify --quiet "refs/heads/$4" && git -C "$3" merge-base --is-ancestor "$6" "$(git -C "$7" rev-parse HEAD)"' \
  _ "$GC_RC" "$CHILD" "$REPO" "$BRANCH" "$REMOTE" "$CHILD_TIP" "$PARENT"
check "successful exact cleanup records collected state" bash -c \
  '[[ "$(cat "$1")" = collected && "$(cat "$2")" = collected && "$(cat "$3")" = "$4" ]]' \
  _ "$CONTROL/tasks/task-a/state" "$TASK_DIR/state" "$CONTROL/tasks/task-a/integrated_sha" "$COLLECTED_SHA"
integrate_fixture "$(git -C "$PARENT" rev-parse HEAD)" >/dev/null 2>&1
check "integration repeat remains idempotent after exact collection" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2")" = collected && "$(cat "$3")" = collected ]]' \
  _ "$?" "$CONTROL/tasks/task-a/state" "$TASK_DIR/state"
$GC --hub "$HUB" --clean >/dev/null 2>&1
check "repeated collection is an idempotent no-op" test "$?" -eq 0

setup_fixture dual-state-collected-crash
integrate_fixture "$PARENT_BASE" >/dev/null
ORC_GC_TEST_FAIL_AFTER_TASK_STATE_COLLECTED=1 \
  "$GC" --hub "$HUB" --mission mission --clean >/dev/null 2>&1
DUAL_STATE_INTERRUPTED_RC=$?
check "interruption between external and control collected states preserves recovery intent" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/state")" = integrated && "$(cat "$3/state")" = collected &&
     "$(cut -f1 "$2/cleanup-intent")" = resources_collected ]]' \
  _ "$DUAL_STATE_INTERRUPTED_RC" "$CONTROL/tasks/task-a" "$TASK_DIR"
"$GC" --hub "$HUB" --mission mission --clean >/dev/null 2>&1
DUAL_STATE_RECOVERY_RC=$?
check "exact retry converges the split collected state on both authority copies" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = collected && "$(cat "$3/state")" = collected && ! -e "$2/cleanup-intent" ]]' \
  _ "$DUAL_STATE_RECOVERY_RC" "$CONTROL/tasks/task-a" "$TASK_DIR"

setup_fixture remote-check-failure
git -C "$CHILD" push -q -u origin "$BRANCH"
integrate_fixture "$PARENT_BASE" >/dev/null
REAL_GIT="$(command -v git)"
WRAP="$FIXTURE/bin"
mkdir -p "$WRAP"
cat > "$WRAP/git" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *" ls-remote "* ]]; then
  exit 1
fi
exec "$ORC_TEST_REAL_GIT" "$@"
SH
chmod +x "$WRAP/git"
PATH="$WRAP:$PATH" ORC_TEST_REAL_GIT="$REAL_GIT" "$GC" --hub "$HUB" --clean >/dev/null 2>&1
REMOTE_FAIL_RC=$?
check "failed remote-state check records retriable cleanup_pending" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2")" = cleanup_pending && -d "$3" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5" && git --git-dir "$6" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$REMOTE_FAIL_RC" "$CONTROL/tasks/task-a/state" "$CHILD" "$REPO" "$BRANCH" "$REMOTE"
$GC --hub "$HUB" --clean >/dev/null 2>&1
RETRY_RC=$?
check "cleanup_pending retry finishes exact collection" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2")" = collected && ! -e "$3" ]] && ! git -C "$4" show-ref --verify --quiet "refs/heads/$5" && ! git --git-dir "$6" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$RETRY_RC" "$CONTROL/tasks/task-a/state" "$CHILD" "$REPO" "$BRANCH" "$REMOTE"

setup_fixture cleanup-intent-order
integrate_fixture "$PARENT_BASE" >/dev/null
INTENT_ORDER_BIN="$FIXTURE/intent-order-bin"
INTENT_ORDER_SEEN="$FIXTURE/intent-seen"
REAL_GIT="$(command -v git)"
mkdir -p "$INTENT_ORDER_BIN"
cat > "$INTENT_ORDER_BIN/git" <<'SH'
#!/usr/bin/env bash
set -u
if [[ " $* " == *" worktree remove "* ]]; then
  [[ -s "$ORC_INTENT_ORDER_CONTROL/cleanup-intent" ]] || exit 91
  grep -Fq 'cleanup prepared' "$ORC_INTENT_ORDER_CONTROL/cleanup-journal.log" || exit 92
  : > "$ORC_INTENT_ORDER_SEEN"
fi
exec "$ORC_INTENT_ORDER_REAL_GIT" "$@"
SH
chmod +x "$INTENT_ORDER_BIN/git"
PATH="$INTENT_ORDER_BIN:$PATH" ORC_INTENT_ORDER_REAL_GIT="$REAL_GIT" \
  ORC_INTENT_ORDER_CONTROL="$CONTROL/tasks/task-a" ORC_INTENT_ORDER_SEEN="$INTENT_ORDER_SEEN" \
  "$GC" --hub "$HUB" --clean >/dev/null 2>&1
INTENT_ORDER_RC=$?
check "destructive GC durably records cleanup intent and journal before deletion" bash -c \
  '[[ "$1" -eq 0 && -e "$2" && "$(cat "$3/state")" = collected && ! -e "$3/cleanup-intent" ]] && grep -Fq "resources collected" "$3/cleanup-journal.log"' \
  _ "$INTENT_ORDER_RC" "$INTENT_ORDER_SEEN" "$CONTROL/tasks/task-a"

setup_fixture cleanup-journal-retry
integrate_fixture "$PARENT_BASE" >/dev/null
JOURNAL_RETRY_CONTROL="$CONTROL/tasks/task-a"
mkdir "$JOURNAL_RETRY_CONTROL/cleanup-journal.log"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
JOURNAL_PREPARE_RC=$?
check "journal preparation failure leaves prepared intent and all resources" bash -c \
  '[[ "$1" -ne 0 && -s "$2/cleanup-intent" && -d "$2/cleanup-journal.log" && -d "$3" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$JOURNAL_PREPARE_RC" "$JOURNAL_RETRY_CONTROL" "$CHILD" "$REPO" "$BRANCH"
rmdir "$JOURNAL_RETRY_CONTROL/cleanup-journal.log"
JOURNAL_RETRY_BIN="$FIXTURE/journal-retry-bin"
JOURNAL_RETRY_SEEN="$FIXTURE/journal-retry-seen"
REAL_GIT="$(command -v git)"
mkdir -p "$JOURNAL_RETRY_BIN"
cat > "$JOURNAL_RETRY_BIN/git" <<'SH'
#!/usr/bin/env bash
set -u
if [[ " $* " == *" worktree remove "* ]]; then
  grep -Fq 'cleanup prepared' "$ORC_JOURNAL_RETRY_CONTROL/cleanup-journal.log" || exit 93
  : > "$ORC_JOURNAL_RETRY_SEEN"
fi
exec "$ORC_JOURNAL_RETRY_REAL_GIT" "$@"
SH
chmod +x "$JOURNAL_RETRY_BIN/git"
PATH="$JOURNAL_RETRY_BIN:$PATH" ORC_JOURNAL_RETRY_REAL_GIT="$REAL_GIT" \
  ORC_JOURNAL_RETRY_CONTROL="$JOURNAL_RETRY_CONTROL" \
  ORC_JOURNAL_RETRY_SEEN="$JOURNAL_RETRY_SEEN" \
  "$GC" --hub "$HUB" --clean >/dev/null 2>&1
JOURNAL_RETRY_RC=$?
check "retry journals an existing prepared intent before destructive cleanup" bash -c \
  '[[ "$1" -eq 0 && -e "$2" && "$(cat "$3/state")" = collected && ! -e "$3/cleanup-intent" && ! -e "$4" ]]' \
  _ "$JOURNAL_RETRY_RC" "$JOURNAL_RETRY_SEEN" "$JOURNAL_RETRY_CONTROL" "$CHILD"

setup_fixture gc-state-directory
integrate_fixture "$PARENT_BASE" >/dev/null
rm -f "$CONTROL/tasks/task-a/state"
mkdir "$CONTROL/tasks/task-a/state"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
GC_STATE_DIRECTORY_RC=$?
check "GC refuses an unsafe directory state without deleting resources" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && -d "$3" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$GC_STATE_DIRECTORY_RC" "$CONTROL/tasks/task-a/state" "$CHILD" "$REPO" "$BRANCH"

setup_fixture gc-state-symlink
integrate_fixture "$PARENT_BASE" >/dev/null
GC_STATE_SYMLINK_OUTSIDE="$FIXTURE/gc-outside-state"
printf 'gc-outside-sentinel\n' > "$GC_STATE_SYMLINK_OUTSIDE"
rm -f "$CONTROL/tasks/task-a/state"
ln -s "$GC_STATE_SYMLINK_OUTSIDE" "$CONTROL/tasks/task-a/state"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
GC_STATE_SYMLINK_RC=$?
check "GC refuses an unsafe symlink state without deletion or traversal" bash -c \
  '[[ "$1" -ne 0 && -L "$2" && "$(cat "$3")" = gc-outside-sentinel && -d "$4" ]]' \
  _ "$GC_STATE_SYMLINK_RC" "$CONTROL/tasks/task-a/state" "$GC_STATE_SYMLINK_OUTSIDE" "$CHILD"

setup_fixture gc-state-race
integrate_fixture "$PARENT_BASE" >/dev/null
GC_STATE_RACE_CONTROL="$CONTROL/tasks/task-a"
GC_STATE_RACE_OUTSIDE="$FIXTURE/gc-race-outside"
GC_STATE_RACE_MARKER="$FIXTURE/gc-race-triggered"
printf 'gc-race-sentinel\n' > "$GC_STATE_RACE_OUTSIDE"
ORC_ATOMIC_REPLACE_TEST_TARGET="$(cd "$GC_STATE_RACE_CONTROL" && pwd -P)/state" \
  ORC_ATOMIC_REPLACE_TEST_MODE=symlink \
  ORC_ATOMIC_REPLACE_TEST_LINK_TARGET="$GC_STATE_RACE_OUTSIDE" \
  ORC_ATOMIC_REPLACE_TEST_MARKER="$GC_STATE_RACE_MARKER" \
  "$GC" --hub "$HUB" --clean >/dev/null 2>&1
GC_STATE_RACE_RC=$?
check "collected-state publication race leaves durable reconcile intent and no false success" bash -c \
  '[[ "$1" -ne 0 && -e "$2" && -L "$3/state" && "$(cat "$4")" = gc-race-sentinel && -s "$3/cleanup-intent" && ! -e "$5" ]] && ! git -C "$6" show-ref --verify --quiet "refs/heads/$7"' \
  _ "$GC_STATE_RACE_RC" "$GC_STATE_RACE_MARKER" "$GC_STATE_RACE_CONTROL" "$GC_STATE_RACE_OUTSIDE" "$CHILD" "$REPO" "$BRANCH"
rm -f "$GC_STATE_RACE_CONTROL/state"
printf 'cleanup_pending\n' > "$GC_STATE_RACE_CONTROL/state"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
GC_STATE_RECOVERY_RC=$?
check "retry reconciles already-collected resources after final state publication failure" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = collected && ! -e "$2/cleanup-intent" ]] && grep -Fq "resources collected" "$2/cleanup-journal.log"' \
  _ "$GC_STATE_RECOVERY_RC" "$GC_STATE_RACE_CONTROL"

setup_fixture remote-drift
git -C "$CHILD" push -q -u origin "$BRANCH"
integrate_fixture "$PARENT_BASE" >/dev/null
REMOTE_CLONE="$FIXTURE/remote-clone"
git clone -q "$REMOTE" "$REMOTE_CLONE"
git -C "$REMOTE_CLONE" config user.email t@t
git -C "$REMOTE_CLONE" config user.name t
git -C "$REMOTE_CLONE" config commit.gpgsign false
git -C "$REMOTE_CLONE" checkout -qb drift "origin/$BRANCH"
printf 'remote drift\n' > "$REMOTE_CLONE/drift.txt"
git -C "$REMOTE_CLONE" add drift.txt
git -C "$REMOTE_CLONE" commit -qm remote-drift
REMOTE_DRIFT_TIP="$(git -C "$REMOTE_CLONE" rev-parse HEAD)"
git -C "$REMOTE_CLONE" push -q origin "HEAD:$BRANCH"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
REMOTE_DRIFT_RC=$?
check "changed remote child tip is preserved instead of deleted" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2")" = cleanup_pending && -d "$3" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5" && [[ "$(git --git-dir "$6" rev-parse "refs/heads/$5")" = "$7" ]]' \
  _ "$REMOTE_DRIFT_RC" "$CONTROL/tasks/task-a/state" "$CHILD" "$REPO" "$BRANCH" "$REMOTE" "$REMOTE_DRIFT_TIP"

setup_fixture dirty-integrated
integrate_fixture "$PARENT_BASE" >/dev/null
printf 'dirty after integration\n' > "$CHILD/dirty.txt"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
DIRTY_GC_RC=$?
check "dirty integrated child becomes cleanup_pending and is preserved" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2")" = cleanup_pending && -d "$3" && -n "$(git -C "$3" status --porcelain --untracked-files=all)" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$DIRTY_GC_RC" "$CONTROL/tasks/task-a/state" "$CHILD" "$REPO" "$BRANCH"

setup_fixture unmerged-evidence
integrate_fixture "$PARENT_BASE" >/dev/null
printf '%s\n' "$PARENT_BASE" > "$CONTROL/tasks/task-a/integrated_sha"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
UNMERGED_GC_RC=$?
check "unmerged or inconsistent integration evidence preserves resources" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2")" = cleanup_pending && -d "$3" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$UNMERGED_GC_RC" "$CONTROL/tasks/task-a/state" "$CHILD" "$REPO" "$BRANCH"

setup_fixture rework-lifecycle
REWORK_CONTROL_TASK="$CONTROL/tasks/task-a"
REWORK_MANIFEST_WORKTREE="$(awk -F '\t' 'NR == 1 {print $1}' "$REWORK_CONTROL_TASK/worktrees.txt")"
check "initial child authority records generation one and exact sandbox root" bash -c \
  '[[ "$(cat "$1/generation" 2>/dev/null)" = 1 && "$(cat "$2/generation" 2>/dev/null)" = 1 && "$(cat "$1/sandbox-root" 2>/dev/null)" = "$3" && "$(cat "$2/sandbox-root" 2>/dev/null)" = "$3" ]]' \
  _ "$REWORK_CONTROL_TASK" "$TASK_DIR" "$REWORK_MANIFEST_WORKTREE"
printf '01a0exact-thread-id\n' > "$REWORK_CONTROL_TASK/accepted-thread-id"
printf '01a0exact-thread-id\n' > "$TASK_DIR/accepted-thread-id"
printf 'unarchived\n' > "$REWORK_CONTROL_TASK/task-window-state"
integrate_fixture "$PARENT_BASE" >/dev/null
FIRST_REWORK_INTEGRATION="$(cat "$REWORK_CONTROL_TASK/integrated_sha")"
FIRST_REWORK_CHILD_TIP="$(cat "$REWORK_CONTROL_TASK/child_tip")"
printf '%s\n' \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  > "$REWORK_CONTROL_TASK/latest-outcome"
printf 'parent after review\n' > "$PARENT/rework-parent.txt"
git -C "$PARENT" add rework-parent.txt
git -C "$PARENT" commit -qm rework-parent
REWORK_PARENT_TIP="$(git -C "$PARENT" rev-parse HEAD)"
printf 'rework\n' > "$MISSION_DIR/state"
rm -f "$CONTROL/review-resolution"
"$OUTCOME" reopen --control-dir "$(cd "$CONTROL" && pwd -P)" \
  --task-dir "$(cd "$TASK_DIR" && pwd -P)" --task-id task-a \
  --parent-worktree "$(cd "$PARENT" && pwd -P)" --expected-generation 1 \
  >"$FIXTURE/reopen.out" 2>"$FIXTURE/reopen.err"
REOPEN_RC=$?
if [[ "$REOPEN_RC" -ne 0 ]]; then
  sed 's/^/  reopen diagnostic: /' "$FIXTURE/reopen.err"
fi
REWORK_CONTROL_ROW="$(cat "$REWORK_CONTROL_TASK/worktrees.txt" 2>/dev/null || true)"
REWORK_WORKER_ROW="$(cat "$TASK_DIR/worktrees.txt" 2>/dev/null || true)"
check "review reopens the retained exact worktree branch and native thread" bash -c \
  'IFS=$'"'"'\t'"'"' read -r worktree branch base repo extra <<< "$1"; [[ "$2" -eq 0 && "$1" = "$3" && -d "$4" && "$worktree" = "$5" && "$branch" = "$6" && "$base" = "$7" && "$repo" = "$8" && -z "$extra" && "$(git -C "$4" rev-parse HEAD)" = "$9" && "$(cat "${10}/accepted-thread-id")" = "${11}" && "$(cat "${10}/task-window-state")" = unarchived ]]' \
  _ "$REWORK_CONTROL_ROW" "$REOPEN_RC" "$REWORK_WORKER_ROW" "$CHILD" \
  "$REWORK_MANIFEST_WORKTREE" "$BRANCH" "$PARENT_BASE" "$(cd "$REPO" && pwd -P)" \
  "$FIRST_REWORK_CHILD_TIP" "$REWORK_CONTROL_TASK" 01a0exact-thread-id
check "reopen advances generation and nonce without replacing retained ownership" bash -c \
  '[[ "$(cat "$1/generation")" = 2 && "$(cat "$2/generation")" = 2 &&
     "$(cat "$1/state")" = ready && "$(cat "$2/state")" = ready &&
     "$(cat "$1/outcome-nonce")" =~ ^[0-9a-f]{64}$ &&
     "$(cat "$1/outcome-nonce")" != "$3" && -s "$1/rework-completion-2.json" &&
     "$(cat "$1/integrated_sha")" = "$4" ]]' \
  _ "$REWORK_CONTROL_TASK" "$TASK_DIR" \
  0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  "$FIRST_REWORK_INTEGRATION"
"$LIFECYCLE" create --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" >/dev/null 2>&1
check "ordinary create never overwrites retained task ownership" test "$?" -ne 0
if [[ "$REOPEN_RC" -eq 0 ]]; then
  printf 'rework child\n' >> "$CHILD/child.txt"
  git -C "$CHILD" add child.txt
  git -C "$CHILD" commit -qm rework-child
  REWORK_CHILD_TIP="$(git -C "$CHILD" rev-parse HEAD)"
  printf 'completed\n' > "$TASK_DIR/state"
  printf 'task-a rework verified at %s\n' "$REWORK_CHILD_TIP" > "$TASK_DIR/report.md"
  printf '%s\n' "$REWORK_CHILD_TIP" > "$TASK_DIR/verification.sha"
  printf '%s\n' "$REWORK_CHILD_TIP" > "$REWORK_CONTROL_TASK/coordinator-verification.sha"
  printf 'coordinator verified %s\n' "$REWORK_CHILD_TIP" > "$REWORK_CONTROL_TASK/coordinator-verification.md"
  printf '%s\n' "$REWORK_PARENT_TIP" > "$REWORK_CONTROL_TASK/parent-verification.sha"
  integrate_fixture "$REWORK_PARENT_TIP" >/dev/null 2>&1
  REINTEGRATE_RC=$?
else
  REWORK_CHILD_TIP=""
  REINTEGRATE_RC=127
fi
check "same retained child generation reintegrates before final review cleanup" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = integrated && "$(cat "$2/generation")" = 2 &&
     "$(cat "$2/accepted-thread-id")" = "$3" && "$(cat "$2/task-window-state")" = unarchived &&
     -d "$4" && "$(git -C "$4" rev-parse HEAD)" = "$5" ]]' \
  _ "$REINTEGRATE_RC" "$REWORK_CONTROL_TASK" 01a0exact-thread-id "$CHILD" "$REWORK_CHILD_TIP"
printf 'accepted\n' > "$MISSION_DIR/state"
printf 'resolved\n' > "$CONTROL/review-resolution"
printf 'archived\n' > "$REWORK_CONTROL_TASK/task-window-state"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
RECOLLECT_RC=$?
check "final accepted review archives then batch-collects the retained child" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = collected && "$(cat "$2/generation")" = 2 &&
     "$(cat "$2/accepted-thread-id")" = "$3" && "$(cat "$2/task-window-state")" = archived &&
     "$(cat "$4/state")" = collected && ! -e "$5" ]] && ! git -C "$6" show-ref --verify --quiet "refs/heads/$7"' \
  _ "$RECOLLECT_RC" "$REWORK_CONTROL_TASK" 01a0exact-thread-id "$TASK_DIR" "$CHILD" "$REPO" "$BRANCH"

for UNSAFE_STATE in running blocked failed review rework completed; do
  setup_fixture "unsafe-$UNSAFE_STATE"
  printf '%s\n' "$UNSAFE_STATE" > "$CONTROL/tasks/task-a/state"
  "$GC" --hub "$HUB" --clean >/dev/null 2>&1
  check "$UNSAFE_STATE child resources are preserved" bash -c \
    '[[ -d "$1" ]] && git -C "$2" show-ref --verify --quiet "refs/heads/$3" && [[ "$(cat "$4")" = "$5" ]]' \
    _ "$CHILD" "$REPO" "$BRANCH" "$CONTROL/tasks/task-a/state" "$UNSAFE_STATE"
done

setup_fixture archive-pending
integrate_fixture "$PARENT_BASE" >/dev/null
printf 'cleanup_pending\n' > "$CONTROL/tasks/task-a/state"
: > "$CONTROL/tasks/task-a/task-window-archive-pending"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
check "archive-only cleanup_pending blocks batch GC and is preserved for API retry" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2")" = cleanup_pending && -f "$3" && -d "$4" ]]' \
  _ "$?" "$CONTROL/tasks/task-a/state" "$CONTROL/tasks/task-a/task-window-archive-pending" "$CHILD"

check "coordinator documents full child lifecycle with retriable cleanup" \
  grep -Fq -- "ready -> running -> completed -> integrated -> collected" "$SKILL"
check "accepted child windows archive before exact residual collection" \
  grep -Fq -- "archive the exact accepted child thread" "$SKILL"
check "unsafe child windows remain visible" \
  grep -Fq -- "Never archive running, blocked, review, or unresolved-rework" "$SKILL"
check "archive failure becomes cleanup_pending and is retried" \
  grep -Fq -- "task-window archive failure" "$SKILL"
check "rework retains the exact unarchived accepted thread" \
  grep -Fq -- "task window still unarchived" "$SKILL"
check "coordinator invokes the retained-child reopen operation" \
  grep -Fq -- "task-outcome.py reopen" "$SKILL"
check "retained reopen requires monotonic generation authority" \
  grep -Fq -- "--expected-generation" "$SKILL"
check "retained reopen refreshes coordinator outcome authority" \
  grep -Fq -- "coordinator-owned outcome nonce" "$SKILL"
check "destructive GC revalidates generation and manifest epoch" \
  grep -Fq -- "revalidate the exact generation and manifest" "$SKILL"
check "interrupted reopen preserves durable recovery evidence" \
  grep -Fq -- "rework intent" "$SKILL"
check "exact retry recognizes one completed rework epoch" \
  grep -Fq -- "rework-completion-<N+1>.json" "$SKILL"
check "reopen durability converges both state and generation copies" \
  grep -Fq -- "generation and state" "$SKILL"
check "rework never archives or collects the retained child" \
  grep -Fq -- "Never collect, archive, unarchive" "$SKILL"
check "late outcomes cannot cross a rework epoch" \
  grep -Fq -- "old or delayed outcome" "$SKILL"
check "stale completion receipts cannot bless a newer epoch" \
  grep -Fq -- "stale receipt never authorizes" "$SKILL"

echo "  child-integration-gc-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
