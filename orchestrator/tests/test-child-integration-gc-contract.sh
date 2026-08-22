#!/usr/bin/env bash
# Behavioral contract for verified child integration and immediate child GC.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INTEGRATE="$ROOT/scripts/integrate-task.sh"
GC="$ROOT/scripts/orchestrator-gc.sh"
LIFECYCLE_REAL="$ROOT/scripts/task-worktree.sh"
export ORC_TEST_LIFECYCLE_REAL="$LIFECYCLE_REAL"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LIFECYCLE="$TMP/task-worktree-legacy-wrapper.sh"
cat > "$LIFECYCLE" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == create ]]; then
  shift
  control=""
  previous=""
  for argument in "$@"; do
    if [[ "$previous" == --control-dir ]]; then control="$argument"; break; fi
    previous="$argument"
  done
  hub="${control%/control/mission}"
  mission_dir="$hub/missions/mission"
  mkdir -p "$mission_dir"
  printf 'request\n' > "$mission_dir/request.md"
  printf 'Briefs: brief.md, brief-exec.md\n' > "$mission_dir/MISSION.md"
  printf 'planned\n' > "$mission_dir/state"
  printf 'backend: hybrid\nstage: plan\n' > "$mission_dir/session.txt"
  exec "$ORC_TEST_LIFECYCLE_REAL" create --create-mode legacy --mission-dir "$mission_dir" "$@"
fi
exec "$ORC_TEST_LIFECYCLE_REAL" "$@"
SH
chmod +x "$LIFECYCLE"

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
  "$LIFECYCLE" create --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
    --mission mission --task-id task-a --repo "$REPO" \
    --parent-worktree "$PARENT" --worktree "$CHILD" >/dev/null
  printf 'child\n' > "$CHILD/child.txt"
  git -C "$CHILD" add child.txt
  git -C "$CHILD" commit -qm child
  CHILD_TIP="$(git -C "$CHILD" rev-parse HEAD)"
  printf 'completed\n' > "$TASK_DIR/state"
  printf 'task-a verified at %s\n' "$CHILD_TIP" > "$TASK_DIR/report.md"
  printf '%s\n' "$CHILD_TIP" > "$TASK_DIR/verification.sha"
  printf '%s\n' "$PARENT_BASE" > "$CONTROL/tasks/task-a/parent-verification.sha"
}

integrate_fixture() {
  "$INTEGRATE" --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
    --mission mission --task-id task-a --parent-worktree "$PARENT" \
    --expected-parent-tip "$1"
}

unchanged_parent() {
  [[ "$(git -C "$PARENT" rev-parse HEAD)" == "$1" && \
    "$(tr -d '[:space:]' < "$TASK_DIR/state")" == completed ]]
}

check "child integration script exists and is executable" test -x "$INTEGRATE"

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
if [[ " $* " == *" merge --no-ff --no-edit "* && ! -e "$ORC_REF_ADVANCE_MARKER" ]]; then
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
  '[[ "$(cat "$1")" = collected && "$(cat "$2")" = "$3" ]]' \
  _ "$CONTROL/tasks/task-a/state" "$CONTROL/tasks/task-a/integrated_sha" "$COLLECTED_SHA"
integrate_fixture "$(git -C "$PARENT" rev-parse HEAD)" >/dev/null 2>&1
check "integration repeat remains idempotent after exact collection" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2")" = collected && "$(cat "$3")" = collected ]]' \
  _ "$?" "$CONTROL/tasks/task-a/state" "$TASK_DIR/state"
$GC --hub "$HUB" --clean >/dev/null 2>&1
check "repeated collection is an idempotent no-op" test "$?" -eq 0

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
printf 'archived\n' > "$REWORK_CONTROL_TASK/task-window-state"
git -C "$CHILD" push -q -u origin "$BRANCH"
integrate_fixture "$PARENT_BASE" >/dev/null
"$GC" --hub "$HUB" --clean >/dev/null
printf 'parent after review\n' > "$PARENT/rework-parent.txt"
git -C "$PARENT" add rework-parent.txt
git -C "$PARENT" commit -qm rework-parent
REWORK_PARENT_TIP="$(git -C "$PARENT" rev-parse HEAD)"
printf 'unarchived\n' > "$REWORK_CONTROL_TASK/task-window-state"
"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 1 \
  >/dev/null 2>&1
REPROVISION_RC=$?
REWORK_CONTROL_ROW="$(cat "$REWORK_CONTROL_TASK/worktrees.txt" 2>/dev/null || true)"
REWORK_WORKER_ROW="$(cat "$TASK_DIR/worktrees.txt" 2>/dev/null || true)"
check "collected task reprovisions exact path and branch from updated parent" bash -c \
  'IFS=$'"'"'\t'"'"' read -r worktree branch base repo extra <<< "$1"; [[ "$2" -eq 0 && -d "$3" && "$worktree" = "$4" && "$branch" = "$5" && "$base" = "$6" && "$repo" = "$7" && -z "$extra" && "$(git -C "$3" rev-parse HEAD)" = "$6" ]]' \
  _ "$REWORK_CONTROL_ROW" "$REPROVISION_RC" "$CHILD" "$REWORK_MANIFEST_WORKTREE" "$BRANCH" "$REWORK_PARENT_TIP" "$(cd "$REPO" && pwd -P)"
check "reprovision atomically advances generation and both authority copies" bash -c \
  '[[ "$1" = "$2" && "$(cat "$3/generation")" = 2 && "$(cat "$4/generation")" = 2 && "$(cat "$3/sandbox-root")" = "$5" && "$(cat "$4/sandbox-root")" = "$5" && "$(cat "$3/state")" = ready && "$(cat "$4/state")" = ready && "$(cat "$3/accepted-thread-id")" = "$6" ]]' \
  _ "$REWORK_CONTROL_ROW" "$REWORK_WORKER_ROW" "$REWORK_CONTROL_TASK" "$TASK_DIR" "$REWORK_MANIFEST_WORKTREE" 01a0exact-thread-id
"$LIFECYCLE" create --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" >/dev/null 2>&1
check "ordinary create never overwrites retained task ownership" test "$?" -ne 0
if [[ "$REPROVISION_RC" -eq 0 ]]; then
  printf 'rework child\n' > "$CHILD/rework.txt"
  git -C "$CHILD" add rework.txt
  git -C "$CHILD" commit -qm rework-child
  REWORK_CHILD_TIP="$(git -C "$CHILD" rev-parse HEAD)"
  printf 'completed\n' > "$TASK_DIR/state"
  printf 'task-a rework verified at %s\n' "$REWORK_CHILD_TIP" > "$TASK_DIR/report.md"
  printf '%s\n' "$REWORK_CHILD_TIP" > "$TASK_DIR/verification.sha"
  printf '%s\n' "$REWORK_PARENT_TIP" > "$REWORK_CONTROL_TASK/parent-verification.sha"
  integrate_fixture "$REWORK_PARENT_TIP" >/dev/null 2>&1
  REINTEGRATE_RC=$?
  "$GC" --hub "$HUB" --clean >/dev/null 2>&1
  RECOLLECT_RC=$?
else
  REWORK_CHILD_TIP=""
  REINTEGRATE_RC=127
  RECOLLECT_RC=127
fi
printf 'archived\n' > "$REWORK_CONTROL_TASK/task-window-state"
check "same task generation reintegrates and recollects after rework" bash -c \
  '[[ "$1" -eq 0 && "$2" -eq 0 && "$(cat "$3/state")" = collected && "$(cat "$3/generation")" = 2 && ! -e "$4" ]] && ! git -C "$5" show-ref --verify --quiet "refs/heads/$6"' \
  _ "$REINTEGRATE_RC" "$RECOLLECT_RC" "$REWORK_CONTROL_TASK" "$CHILD" "$REPO" "$BRANCH"
check "archive and unarchive lifecycle retains the exact accepted thread ID" bash -c \
  '[[ "$(cat "$1/accepted-thread-id")" = "$2" && "$(cat "$1/task-window-state")" = archived ]]' \
  _ "$REWORK_CONTROL_TASK" 01a0exact-thread-id

setup_fixture gc-reprovision-race
RACE_CONTROL_TASK="$CONTROL/tasks/task-a"
printf '01a0gc-race-thread\n' > "$RACE_CONTROL_TASK/accepted-thread-id"
printf '01a0gc-race-thread\n' > "$TASK_DIR/accepted-thread-id"
printf 'unarchived\n' > "$RACE_CONTROL_TASK/task-window-state"
integrate_fixture "$PARENT_BASE" >/dev/null
RACE_PARENT_TIP="$(git -C "$PARENT" rev-parse HEAD)"
RACE_BIN="$FIXTURE/gc-race-bin"
RACE_PAUSED="$FIXTURE/gc-paused"
RACE_RELEASE="$FIXTURE/gc-release"
REAL_GIT="$(command -v git)"
mkdir -p "$RACE_BIN"
mkfifo "$RACE_RELEASE"
cat > "$RACE_BIN/git" <<'SH'
#!/usr/bin/env bash
set -u
if [[ " $* " == *" update-ref -d refs/heads/$ORC_GC_RACE_BRANCH "* && ! -e "$ORC_GC_RACE_PAUSED" ]]; then
  "$ORC_GC_RACE_REAL_GIT" "$@" || exit "$?"
  : > "$ORC_GC_RACE_PAUSED"
  IFS= read -r _ < "$ORC_GC_RACE_RELEASE"
  exit 0
fi
exec "$ORC_GC_RACE_REAL_GIT" "$@"
SH
chmod +x "$RACE_BIN/git"
PATH="$RACE_BIN:$PATH" ORC_GC_RACE_REAL_GIT="$REAL_GIT" \
  ORC_GC_RACE_BRANCH="$BRANCH" ORC_GC_RACE_PAUSED="$RACE_PAUSED" \
  ORC_GC_RACE_RELEASE="$RACE_RELEASE" \
  "$GC" --hub "$HUB" --clean >"$FIXTURE/gc-race.out" 2>"$FIXTURE/gc-race.err" &
RACE_GC_PID=$!
RACE_WAIT=0
while [[ ! -e "$RACE_PAUSED" && "$RACE_WAIT" -lt 300 ]]; do
  kill -0 "$RACE_GC_PID" 2>/dev/null || break
  RACE_WAIT=$((RACE_WAIT + 1))
  sleep 0.01
done
"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 1 \
  >/dev/null 2>&1
PAUSED_REPROVISION_RC=$?
printf 'release\n' > "$RACE_RELEASE"
wait "$RACE_GC_PID"
RACE_GC_RC=$?
"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 1 \
  >/dev/null 2>&1
POST_GC_REPROVISION_RC=$?
check "paused generation-one GC excludes concurrent generation-two reprovision" bash -c \
  '[[ -e "$1" && "$2" -ne 0 && "$3" -eq 0 ]]' \
  _ "$RACE_PAUSED" "$PAUSED_REPROVISION_RC" "$RACE_GC_RC"
check "post-GC reprovision converges one exact generation-two authority" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/generation")" = 2 && "$(cat "$3/generation")" = 2 && "$(cat "$2/state")" = ready && "$(cat "$3/state")" = ready && -d "$4" && "$(git -C "$4" rev-parse HEAD)" = "$5" && ! -e "$2/cleanup-intent" ]] && git -C "$6" show-ref --verify --quiet "refs/heads/$7" && cmp -s "$2/worktrees.txt" "$3/worktrees.txt"' \
  _ "$POST_GC_REPROVISION_RC" "$RACE_CONTROL_TASK" "$TASK_DIR" "$CHILD" "$RACE_PARENT_TIP" "$REPO" "$BRANCH"

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
check "archive-only cleanup_pending is preserved for coordinator API retry" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2")" = cleanup_pending && -f "$3" && -d "$4" ]]' \
  _ "$?" "$CONTROL/tasks/task-a/state" "$CONTROL/tasks/task-a/task-window-archive-pending" "$CHILD"

check "coordinator documents full child lifecycle with retriable cleanup" \
  grep -Fq -- "ready -> running -> completed -> integrated -> collected" "$SKILL"
check "completed child windows archive only after exact collection" \
  grep -Fq -- "archive the exact accepted child thread" "$SKILL"
check "unsafe child windows remain visible" \
  grep -Fq -- "Never archive running, blocked, review, or unresolved-rework" "$SKILL"
check "archive failure becomes cleanup_pending and is retried" \
  grep -Fq -- "task-window archive failure" "$SKILL"
check "rework unarchives and later rearchives exact accepted thread" bash -c \
  'grep -Fq -- "unarchive the exact accepted child thread" "$1" && grep -Fq -- "Rearchive only after verified reintegration" "$1"' \
  _ "$SKILL"
check "coordinator invokes the exact-authority reprovision lifecycle operation" \
  grep -Fq -- "task-worktree.sh reprovision" "$SKILL"
check "rework reprovision requires monotonic generation authority" \
  grep -Fq -- "--expected-generation" "$SKILL"
check "GC and reprovision share one lifecycle mutation lock" \
  grep -Fq -- "shared coordinator lifecycle mutation lock" "$SKILL"
check "destructive GC revalidates generation and manifest epoch" \
  grep -Fq -- "revalidate the exact generation and manifest" "$SKILL"
check "incomplete reprovision rollback preserves recovery evidence" \
  grep -Fq -- "preserve reprovision-intent, staging, and backups" "$SKILL"
check "exact retry recognizes an already-converged reprovision epoch" \
  grep -Fq -- "already-converged reprovision epoch" "$SKILL"
check "reprovision durability fsyncs evidence before authority replacement" \
  grep -Fq -- "fsync intent, stage, and backup contents" "$SKILL"
check "ambiguous reprovision success requires an fsynced completion receipt" \
  grep -Fq -- "fsynced reprovision completion receipt" "$SKILL"
check "completion receipt requires strict one-row and scalar authority formats" \
  grep -Fq -- "strict one-row manifests and one-line scalar authorities" "$SKILL"
check "stale completion receipts cannot bless a newer epoch" \
  grep -Fq -- "stale receipt never authorizes a newer epoch" "$SKILL"

echo "  child-integration-gc-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
