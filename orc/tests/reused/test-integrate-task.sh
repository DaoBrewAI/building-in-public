#!/usr/bin/env bash
# Behavioral contract for verified child integration.
# 从旧 orchestrator 的 test-child-integration-gc-contract.sh 取出 integrate-task.sh 的部分；
# GC、reopen（task-outcome.py）相关的检查留在旧测试里，这两个脚本 orc 不复用。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INTEGRATE="$ROOT/scripts/integrate-task.sh"
VALIDATOR="$ROOT/scripts/validate-task-dag.sh"
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

# 代替旧的 task-worktree.sh create --create-mode test-fixture：生成同样的子 worktree 和登记文件
create_child_fixture() {
  local child_real repo_real d
  git -C "$REPO" worktree add -q -b "$BRANCH" "$CHILD" "$PARENT_BASE" >/dev/null
  child_real="$(cd "$CHILD" && pwd -P)"; repo_real="$(cd "$REPO" && pwd -P)"
  for d in "$CONTROL/tasks/task-a" "$TASK_DIR"; do
    mkdir -p "$d"
    printf '1\n' > "$d/generation"
    printf '%s\n' "$child_real" > "$d/sandbox-root"
    printf 'ready\n' > "$d/state"
    printf '%s\t%s\t%s\t%s\n' "$child_real" "$BRANCH" "$PARENT_BASE" "$repo_real" > "$d/worktrees.txt"
  done
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
  create_child_fixture
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

echo "  integrate-task-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
