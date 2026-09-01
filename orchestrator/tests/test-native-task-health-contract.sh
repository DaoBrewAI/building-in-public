#!/usr/bin/env bash
# Durable native child bootstrap health, bounded replacement, and frozen schedule-base authority.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEALTH="$ROOT/scripts/native-task-health.py"
LIFECYCLE="$ROOT/scripts/task-worktree.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/orc-native-health.XXXXXX")"
TMP="$(cd -P "$TMP" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT

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

setup_case() {
  local root="$1"
  REPO="$root/repo"
  PARENT="$root/parent"
  CHILD="$root/native-child"
  CONTROL="$root/hub/control/mission"
  MISSION_DIR="$root/hub/missions/mission"
  TASK_DIR="$root/task-state"
  TITLE="ORC mission · task-a Native health"
  mkdir -p "$REPO" "$CONTROL" "$MISSION_DIR" "$TASK_DIR"
  git init -q "$REPO"
  git -C "$REPO" config user.email native-health@example.invalid
  git -C "$REPO" config user.name native-health
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" commit -q --allow-empty -m base
  git -C "$REPO" worktree add -qb orc/mission "$PARENT"
  printf 'scheduled\n' > "$PARENT/scheduled.txt"
  git -C "$PARENT" add scheduled.txt
  git -C "$PARENT" commit -qm scheduled
  SCHEDULE_BASE="$(git -C "$PARENT" rev-parse HEAD)"
  git -C "$REPO" worktree add -q --detach "$CHILD" "$SCHEDULE_BASE"
  printf 'request\n' > "$MISSION_DIR/request.md"
  printf 'Briefs: brief.md, brief-exec.md\n' > "$MISSION_DIR/MISSION.md"
  printf 'planned\n' > "$MISSION_DIR/state"
  printf 'backend: hybrid\nstage: plan\n' > "$MISSION_DIR/session.txt"
}

begin_health() {
  "$HEALTH" begin --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
    --task-id task-a --project-id project-1 --source-thread-id source-1 \
    --title "$TITLE" --repo "$REPO" --schedule-base "$SCHEDULE_BASE"
}

observe_health() {
  local provisional="$1" thread="$2"
  shift 2
  "$HEALTH" observe --control-dir "$CONTROL" --task-id task-a \
    --provisional-id "$provisional" --thread-id "$thread" \
    --list-visible true --observed-title "$TITLE" \
    --bootstrap-state completed --task-state idle \
    --cwd "$CHILD" --tip "$SCHEDULE_BASE" \
    --observed-project-id project-1 "$@"
}

write_archive_receipt() {
  local path="$1" provisional="$2" thread="$3" digest
  digest="$(shasum -a 256 "$CONTROL/tasks/task-a/native-health/request.json" | awk '{print $1}')"
  jq -cS -n --arg provisional "$provisional" --arg thread "$thread" \
    --arg digest "$digest" \
    '{protocol_version:1,provisional_id:$provisional,request_digest:$digest,
      status:"archived",thread_id:$thread}' > "$path"
  chmod 0600 "$path"
}

BASE="$TMP/base"
setup_case "$BASE"
check "native task health helper is packaged and executable" test -x "$HEALTH"
begin_health >/dev/null 2>&1
BEGIN_RC=$?
check "begin publishes durable request and task-state-dir authority" bash -c \
  '[[ "$1" -eq 0 && -s "$2/tasks/task-a/native-health/request.json" && "$(cat "$2/tasks/task-a/task-state-dir")" = "$3" ]]' \
  _ "$BEGIN_RC" "$CONTROL" "$(cd "$TASK_DIR" && pwd -P)"
check "health authority has private modes" bash -c \
  '[[ "$(stat -f %Lp "$1/tasks/task-a/native-health")" = 700 && "$(stat -f %Lp "$1/tasks/task-a/native-health/request.json")" = 600 && "$(stat -f %Lp "$1/tasks/task-a/task-state-dir")" = 600 ]]' \
  _ "$CONTROL"
begin_health >/dev/null 2>&1
check "exact begin replay is idempotent" test "$?" -eq 0
check "conflicting begin cannot replace frozen request" bash -c \
  '! "$1" begin --control-dir "$2" --task-dir "$3" --task-id task-a --project-id other-project --source-thread-id source-1 --title "$4" --repo "$5" --schedule-base "$6"' \
  _ "$HEALTH" "$CONTROL" "$TASK_DIR" "$TITLE" "$REPO" "$SCHEDULE_BASE"

observe_health provisional-a thread-a >/dev/null 2>&1
OBSERVE_RC=$?
RECEIPT="$CONTROL/tasks/task-a/native-health/accepted.json"
check "healthy bootstrap with exact project and absent source projection is accepted" bash -c \
  '[[ "$1" -eq 0 && -s "$2" ]]' _ "$OBSERVE_RC" "$RECEIPT"
check "accepted receipt binds strict health and null projection semantics" python3 - "$RECEIPT" <<'PY'
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
expected = {
    "attempt", "bootstrap_state", "cwd", "list_visible", "observed_project_id",
    "observed_source_thread_id", "observed_title", "project_id", "protocol_version",
    "provisional_id", "repo", "request_digest", "request_nonce", "schedule_base",
    "source_thread_id", "status", "task_id", "task_state", "task_state_dir",
    "thread_id", "tip", "title",
}
raise SystemExit(0 if set(r) == expected and r["status"] == "accepted" and
                 r["list_visible"] is True and r["bootstrap_state"] == "completed" and
                 r["task_state"] == "idle" and r["observed_project_id"] == "project-1" and
                 r["observed_source_thread_id"] is None else 1)
PY
check "accepted receipt has private mode" bash -c \
  '[[ "$(stat -f %Lp "$1")" = 600 ]]' _ "$RECEIPT"
VERIFIED_BASE="$("$HEALTH" verify-adoption --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --task-id task-a --thread-id thread-a --repo "$REPO" --worktree "$CHILD" \
  --live-parent-tip "$SCHEDULE_BASE" 2>/dev/null)"
check "adoption verification returns the frozen schedule base" test "$VERIFIED_BASE" = "$SCHEDULE_BASE"
check "adoption verification rejects another formal thread" bash -c \
  '! "$1" verify-adoption --control-dir "$2" --task-dir "$3" --task-id task-a --thread-id thread-b --repo "$4" --worktree "$5" --live-parent-tip "$6"' \
  _ "$HEALTH" "$CONTROL" "$TASK_DIR" "$REPO" "$CHILD" "$SCHEDULE_BASE"

MISSING_ATTEMPT="$TMP/missing-attempt"
setup_case "$MISSING_ATTEMPT"
begin_health >/dev/null 2>&1
observe_health provisional-missing-attempt thread-missing-attempt >/dev/null 2>&1
rm -f "$CONTROL/tasks/task-a/native-health/attempt-1.json"
check "adoption verification requires the receipt's matching durable attempt" bash -c \
  '! "$1" verify-adoption --control-dir "$2" --task-dir "$3" --task-id task-a --thread-id thread-missing-attempt --repo "$4" --worktree "$5" --live-parent-tip "$6"' \
  _ "$HEALTH" "$CONTROL" "$TASK_DIR" "$REPO" "$CHILD" "$SCHEDULE_BASE"

PARTIAL_BEGIN="$TMP/partial-begin"
setup_case "$PARTIAL_BEGIN"
mkdir -p "$CONTROL/tasks/task-a"
printf '%s\n' "$PARTIAL_BEGIN/other-task-state" > "$CONTROL/tasks/task-a/task-state-dir"
chmod 0600 "$CONTROL/tasks/task-a/task-state-dir"
begin_health >/dev/null 2>&1
PARTIAL_BEGIN_RC=$?
check "conflicting preexisting task-state authority cannot leave a partial request" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2/tasks/task-a/native-health/request.json" ]]' \
  _ "$PARTIAL_BEGIN_RC" "$CONTROL"

PROJECTED="$TMP/projected"
setup_case "$PROJECTED"
begin_health >/dev/null 2>&1
observe_health provisional-projected thread-projected --observed-project-id project-1 \
  --observed-source-thread-id source-1 >/dev/null 2>&1
check "matching non-null project and source projections are accepted" test "$?" -eq 0

MISSING_PROJECT="$TMP/missing-project"
setup_case "$MISSING_PROJECT"
begin_health >/dev/null 2>&1
"$HEALTH" observe --control-dir "$CONTROL" --task-id task-a \
  --provisional-id provisional-missing-project --thread-id thread-missing-project \
  --list-visible true --observed-title "$TITLE" --bootstrap-state completed \
  --task-state idle --cwd "$CHILD" --tip "$SCHEDULE_BASE" >/dev/null 2>&1
check "missing project projection is a durable rejected attempt" bash -c \
  '[[ "$1" -ne 0 && "$(jq -r .reason "$2/tasks/task-a/native-health/attempt-1.json")" = wrong_project ]]' \
  _ "$?" "$CONTROL"

WRONG_PROJECT="$TMP/wrong-project"
setup_case "$WRONG_PROJECT"
begin_health >/dev/null 2>&1
observe_health provisional-wrong-project thread-wrong-project --observed-project-id other-project >/dev/null 2>&1
check "explicit wrong project projection is a durable rejected attempt" bash -c \
  '[[ "$1" -ne 0 && "$(jq -r .reason "$2/tasks/task-a/native-health/attempt-1.json")" = wrong_project && ! -e "$2/tasks/task-a/native-health/accepted.json" ]]' \
  _ "$?" "$CONTROL"

WRONG_SOURCE="$TMP/wrong-source"
setup_case "$WRONG_SOURCE"
begin_health >/dev/null 2>&1
observe_health provisional-wrong-source thread-wrong-source --observed-source-thread-id other-source >/dev/null 2>&1
check "explicit wrong source projection is a durable rejected attempt" bash -c \
  '[[ "$1" -ne 0 && "$(jq -r .reason "$2/tasks/task-a/native-health/attempt-1.json")" = wrong_source ]]' \
  _ "$?" "$CONTROL"

REPLACEMENT="$TMP/replacement"
setup_case "$REPLACEMENT"
begin_health >/dev/null 2>&1
"$HEALTH" observe --control-dir "$CONTROL" --task-id task-a \
  --provisional-id provisional-stale --list-visible false \
  --bootstrap-state failed --task-state failed >/dev/null 2>&1
FIRST_REJECT_RC=$?
"$HEALTH" observe --control-dir "$CONTROL" --task-id task-a \
  --provisional-id provisional-stale --list-visible false \
  --bootstrap-state failed --task-state failed >/dev/null 2>&1
REJECT_REPLAY_RC=$?
check "exact rejected observation replay does not consume the replacement" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2/tasks/task-a/native-health/attempt-2.json" ]]' \
  _ "$REJECT_REPLAY_RC" "$CONTROL"
REPLACEMENT_ARCHIVE="$REPLACEMENT/archive.json"
write_archive_receipt "$REPLACEMENT_ARCHIVE" provisional-stale provisional-stale
observe_health provisional-replacement thread-replacement >/dev/null 2>&1
check "replacement cannot start before rejected provisional archive receipt" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2/tasks/task-a/native-health/attempt-2.json" ]]' \
  _ "$?" "$CONTROL"
observe_health provisional-replacement thread-replacement \
  --previous-archive-receipt "$REPLACEMENT_ARCHIVE" >/dev/null 2>&1
REPLACEMENT_RC=$?
check "one derived native identity rejection plus archive receipt permits one replacement" bash -c \
  '[[ "$1" -ne 0 && "$2" -eq 0 && "$(jq -r .reason "$3/tasks/task-a/native-health/attempt-1.json")" = unreadable_identity && "$(jq -r .status "$3/tasks/task-a/native-health/attempt-2.json")" = accepted && -s "$3/tasks/task-a/native-health/attempt-1-archive.json" ]]' \
  _ "$FIRST_REJECT_RC" "$REPLACEMENT_RC" "$CONTROL"
check "accepted replacement remains an exact idempotent observation" bash -c \
  '"$1" observe --control-dir "$2" --task-id task-a --provisional-id provisional-replacement --thread-id thread-replacement --list-visible true --observed-title "$3" --bootstrap-state completed --task-state idle --cwd "$4" --tip "$5" --observed-project-id project-1' \
  _ "$HEALTH" "$CONTROL" "$TITLE" "$CHILD" "$SCHEDULE_BASE"
check "accepted health cannot be replaced by a third provisional task" bash -c \
  '! "$1" observe --control-dir "$2" --task-id task-a --provisional-id provisional-third --list-visible false --bootstrap-state failed --task-state failed' \
  _ "$HEALTH" "$CONTROL"

EXHAUSTED="$TMP/exhausted"
setup_case "$EXHAUSTED"
begin_health >/dev/null 2>&1
"$HEALTH" observe --control-dir "$CONTROL" --task-id task-a \
  --provisional-id provisional-1 --list-visible false \
  --bootstrap-state failed --task-state failed >/dev/null 2>&1
EXHAUSTED_ARCHIVE="$EXHAUSTED/archive.json"
write_archive_receipt "$EXHAUSTED_ARCHIVE" provisional-1 provisional-1
"$HEALTH" observe --control-dir "$CONTROL" --task-id task-a \
  --provisional-id provisional-2 --thread-id thread-2 --list-visible true \
  --observed-title "$TITLE" --observed-project-id project-1 \
  --bootstrap-state failed --task-state failed --cwd "$CHILD" --tip "$SCHEDULE_BASE" \
  --previous-archive-receipt "$EXHAUSTED_ARCHIVE" >/dev/null 2>&1
SECOND_REJECT_RC=$?
"$HEALTH" observe --control-dir "$CONTROL" --task-id task-a \
  --provisional-id provisional-3 --list-visible false \
  --bootstrap-state failed --task-state failed >/dev/null 2>&1
THIRD_RC=$?
check "two enumerated native failures durably exhaust replacement" bash -c \
  '[[ "$1" -ne 0 && "$2" -ne 0 && -s "$3/tasks/task-a/native-health/blocked.json" && ! -e "$3/tasks/task-a/native-health/attempt-3.json" ]]' \
  _ "$SECOND_REJECT_RC" "$THIRD_RC" "$CONTROL"
rm -f "$CONTROL/tasks/task-a/native-health/blocked.json"
"$HEALTH" observe --control-dir "$CONTROL" --task-id task-a \
  --provisional-id provisional-3 --list-visible false \
  --bootstrap-state failed --task-state failed >/dev/null 2>&1
BLOCKED_RECOVERY_RC=$?
check "retry repairs a missing blocked receipt after two durable rejections" bash -c \
  '[[ "$1" -ne 0 && -s "$2/tasks/task-a/native-health/blocked.json" && ! -e "$2/tasks/task-a/native-health/attempt-3.json" ]]' \
  _ "$BLOCKED_RECOVERY_RC" "$CONTROL"
check "free-form failure reason is not an observe API and cannot consume an attempt" bash -c \
  '! "$1" observe --control-dir "$2" --task-id task-a --provisional-id provisional-4 --failure-reason permission_denied && [[ ! -e "$2/tasks/task-a/native-health/attempt-3.json" ]]' \
  _ "$HEALTH" "$CONTROL"

MISSING_TURN="$TMP/missing-turn"
setup_case "$MISSING_TURN"
begin_health >/dev/null 2>&1
"$HEALTH" observe --control-dir "$CONTROL" --task-id task-a \
  --provisional-id provisional-missing --thread-id thread-missing \
  --list-visible true --observed-title "$TITLE" --bootstrap-state missing \
  --task-state idle --cwd "$CHILD" --tip "$SCHEDULE_BASE" \
  --observed-project-id project-1 >/dev/null 2>&1
check "missing bootstrap turn is rejected with the enumerated reason" bash -c \
  '[[ "$1" -ne 0 && "$(jq -r .reason "$2/tasks/task-a/native-health/attempt-1.json")" = missing_first_turn ]]' \
  _ "$?" "$CONTROL"

WRONG_TIP="$TMP/wrong-tip"
setup_case "$WRONG_TIP"
begin_health >/dev/null 2>&1
observe_health provisional-tip thread-tip --tip 0000000000000000000000000000000000000000 >/dev/null 2>&1
check "reported wrong tip is rejected before adoption" bash -c \
  '[[ "$1" -ne 0 && "$(jq -r .reason "$2/tasks/task-a/native-health/attempt-1.json")" = wrong_tip ]]' \
  _ "$?" "$CONTROL"

NO_RECEIPT="$TMP/no-receipt"
setup_case "$NO_RECEIPT"
mkdir -p "$TASK_DIR"
ORC_TASK_WORKTREE_TESTING=1 ORC_TASK_WORKTREE_TEST_FIXTURE_ROOT="$NO_RECEIPT" \
  "$LIFECYCLE" adopt --create-mode test-fixture \
    --mission-dir "$MISSION_DIR" --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
    --mission mission --task-id task-a --repo "$REPO" --parent-worktree "$PARENT" \
    --worktree "$CHILD" --thread-id thread-a >/dev/null 2>&1
check "native adoption refuses a child without an accepted health receipt" test "$?" -ne 0

ADVANCED="$TMP/advanced-parent"
setup_case "$ADVANCED"
begin_health >/dev/null 2>&1
observe_health provisional-advance thread-advance >/dev/null 2>&1
printf 'sibling integrated\n' > "$PARENT/sibling.txt"
git -C "$PARENT" add sibling.txt
git -C "$PARENT" commit -qm sibling
LIVE_PARENT_TIP="$(git -C "$PARENT" rev-parse HEAD)"
ORC_TASK_WORKTREE_TESTING=1 ORC_TASK_WORKTREE_TEST_FIXTURE_ROOT="$ADVANCED" \
  "$LIFECYCLE" adopt --create-mode test-fixture \
    --mission-dir "$MISSION_DIR" --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
    --mission mission --task-id task-a --repo "$REPO" --parent-worktree "$PARENT" \
    --worktree "$CHILD" --thread-id thread-advance >/dev/null 2>&1
ADVANCED_RC=$?
check "adoption uses frozen schedule base while live parent only needs to descend it" bash -c \
  '[[ "$1" -eq 0 && "$(git -C "$2" rev-parse HEAD)" = "$3" && "$(cut -f3 "$4/tasks/task-a/worktrees.txt")" = "$3" && "$5" != "$3" ]]' \
  _ "$ADVANCED_RC" "$CHILD" "$SCHEDULE_BASE" "$CONTROL" "$LIVE_PARENT_TIP"

echo "  native-task-health-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
