#!/usr/bin/env bash
# Behavioral contract for exact parent mission reconcile GC and archive safety.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GC="$ROOT/scripts/orchestrator-gc.sh"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
CLEANUP_REF="$ROOT/skills/orchestrating/references/cleanup-and-rework.md"
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
  local name="$1" merged="${2:-yes}"
  FIXTURE="$TMP/$name"
  HUB="$FIXTURE/.orchestrator"
  MISSION="$HUB/missions/mission"
  CONTROL="$HUB/control/mission"
  ARCHIVE="$HUB/archive/mission"
  REPO="$FIXTURE/repo"
  REMOTE="$FIXTURE/remote.git"
  PARENT="$FIXTURE/parent"
  BRANCH="orc/mission"
  TARGET="main"
  mkdir -p "$MISSION" "$CONTROL" "$HUB/archive"
  git init -q --bare "$REMOTE"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t
  git -C "$REPO" config user.name t
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" remote add origin "$REMOTE"
  printf 'base\n' > "$REPO/base.txt"
  git -C "$REPO" add base.txt
  git -C "$REPO" commit -qm base
  git -C "$REPO" branch -M main
  git -C "$REPO" push -q -u origin main
  git -C "$REPO" worktree add -qb "$BRANCH" "$PARENT" main >/dev/null
  printf 'mission\n' > "$PARENT/mission.txt"
  git -C "$PARENT" add mission.txt
  git -C "$PARENT" commit -qm mission
  PARENT_TIP="$(git -C "$PARENT" rev-parse HEAD)"
  git -C "$PARENT" push -q -u origin "$BRANCH"
  if [[ "$merged" == yes ]]; then
    git -C "$REPO" merge -q --no-ff --no-edit "$PARENT_TIP"
  fi
  PARENT="$(cd "$PARENT" && pwd -P)"
  REPO="$(cd "$REPO" && pwd -P)"
  printf 'accepted\n' > "$MISSION/state"
  printf 'resolved\n' > "$CONTROL/review-resolution"
  printf 'ready\n' > "$CONTROL/parent-cleanup-state"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$PARENT" "$BRANCH" "$PARENT_TIP" "$REPO" "$TARGET" \
    > "$CONTROL/parent-cleanup-manifest.txt"
  printf 'design artifact\n' > "$MISSION/design.md"
  printf 'plan artifact\n' > "$MISSION/plan.md"
  printf '<html>plan review artifact</html>\n' > "$MISSION/plan-review.html"
  printf '<html>status truth artifact</html>\n' > "$MISSION/status-truth.html"
  printf 'decision artifact\n' > "$CONTROL/decisions.md"
  printf 'report artifact\n## Code review\nresolved\n## Verification\nverified\n' > "$MISSION/report.md"
  printf '{"version":1,"mission":"mission","tasks":[]}\n' > "$CONTROL/approved-task-dag.json"
  printf 'verification artifact\n' > "$CONTROL/verification.md"
  printf '{"version":1,"site_url":"https://example.openai.site/mission"}\n' > "$CONTROL/sites-delivery.json"
  printf 'request\n' > "$MISSION/request.md"
  printf 'Briefs: brief.md, brief-exec.md\n' > "$MISSION/MISSION.md"
  printf 'session_id: fable-session\nbackend: claude-headless\nmodel: claude-fable-5\nstage: review\n' > "$MISSION/session.txt"
  printf 'approved design\n' > "$CONTROL/approved-design.md"
  printf 'approved plan\n' > "$CONTROL/approved-plan.md"
  printf 'approved brief\n' > "$CONTROL/brief-exec.md"
  printf '0.4.0\n' > "$CONTROL/pipeline-version"
  printf 'fable-opus\n' > "$MISSION/planning-backend"
  printf 'fable-opus\n' > "$CONTROL/planning-backend"
  printf 'fable-session\n' > "$CONTROL/planning-session-id"
  mkdir -p "$CONTROL/tasks"
  (cd "$CONTROL" && shasum -a 256 approved-design.md approved-plan.md \
    brief-exec.md approved-task-dag.json > approved.sha256)
}

add_archived_child_authority() {
  local task="$CONTROL/tasks/task-a"
  mkdir -p "$task"
  printf 'collected\n' > "$task/state"
  printf '01a0accepted-child\n' > "$task/accepted-thread-id"
  printf 'archived\n' > "$task/task-window-state"
  printf '{"version":1,"mission":"mission","tasks":[{"id":"task-a","depends_on":[],"files":[],"contracts":[],"verification":["true"],"state":"ready"}]}\n' \
    > "$CONTROL/approved-task-dag.json"
  (cd "$CONTROL" && shasum -a 256 approved-design.md approved-plan.md \
    brief-exec.md approved-task-dag.json > approved.sha256)
}

check_parent_preserved_after_gc() {
  local label="$1" rc
  "$GC" --hub "$HUB" --clean >/dev/null 2>&1
  rc=$?
  check "$label" bash -c \
    '[[ "$1" -ne 0 && "$(cat "$2/parent-cleanup-state")" = cleanup_pending && -d "$3" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5" && git --git-dir "$6" show-ref --verify --quiet "refs/heads/$5"' \
    _ "$rc" "$CONTROL" "$PARENT" "$REPO" "$BRANCH" "$REMOTE"
}

inode_id() {
  python3 - "$1" <<'PY'
import os
import sys
value = os.lstat(sys.argv[1])
print("%s:%s" % (value.st_dev, value.st_ino))
PY
}

pending_marker_binds() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json
import sys
marker, manifest_hash, manifest_inode, manifest_size, state_hash, state_inode = sys.argv[1:]
with open(marker, encoding="utf-8") as handle:
    value = json.load(handle)
manifest_device, manifest_inode_value = [int(item) for item in manifest_inode.split(":", 1)]
device, inode = [int(item) for item in state_inode.split(":", 1)]
valid = (
    value.get("version") == 1 and
    value.get("manifest_sha256") == manifest_hash and
    value.get("manifest_dev") == manifest_device and
    value.get("manifest_ino") == manifest_inode_value and
    value.get("manifest_size") == int(manifest_size) and
    value.get("state_sha256") == state_hash and
    value.get("state_dev") == device and
    value.get("state_ino") == inode and
    value.get("observed_state") in ("ready", "cleanup_pending") and
    "lifecycle mutation lock" in value.get("reason", "")
)
raise SystemExit(0 if valid else 1)
PY
}
export -f pending_marker_binds

setup_fixture report-only
add_archived_child_authority
REPORT="$($GC --hub "$HUB" 2>/dev/null)"
check "report-only reconcile identifies exact parent without mutation" bash -c \
  '[[ "$1" == *"$2"* && -d "$3" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$2"' \
  _ "$REPORT" "$BRANCH" "$PARENT" "$REPO"

setup_fixture happy
add_archived_child_authority
UNRELATED_BRANCH=keep-unrelated
git -C "$REPO" branch "$UNRELATED_BRANCH" main
$GC --hub "$HUB" --mission mission --clean >"$FIXTURE/happy.out" 2>"$FIXTURE/happy.err"
HAPPY_RC=$?
if [[ "$HAPPY_RC" -ne 0 ]]; then
  sed 's/^/  happy diagnostic: /' "$FIXTURE/happy.err"
fi
check "exact merged parent cleanup removes only its worktree and local and remote refs" bash -c \
  '[[ "$1" -eq 0 && ! -e "$2" ]] && ! git -C "$3" show-ref --verify --quiet "refs/heads/$4" && ! git --git-dir "$5" show-ref --verify --quiet "refs/heads/$4" && git -C "$3" show-ref --verify --quiet "refs/heads/$6"' \
  _ "$HAPPY_RC" "$PARENT" "$REPO" "$BRANCH" "$REMOTE" "$UNRELATED_BRANCH"
check "successful parent cleanup records collected and durable journal state" bash -c \
  '[[ "$(cat "$1/parent-cleanup-state")" = collected && -s "$1/parent-cleanup-journal.log" && -s "$2/cleanup-journal.log" ]] && grep -Fq "$3" "$2/cleanup-journal.log"' \
  _ "$CONTROL" "$ARCHIVE" "$PARENT_TIP"
if ! [[ "$(cat "$ARCHIVE/design.md" 2>/dev/null)" == "design artifact" && \
  "$(cat "$ARCHIVE/plan.md" 2>/dev/null)" == "plan artifact" && \
  "$(cat "$ARCHIVE/DECISIONS.md" 2>/dev/null)" == "decision artifact" && \
  "$(cat "$ARCHIVE/verification.md" 2>/dev/null)" == "verification artifact" ]] || \
  ! grep -Fq '"mission":"mission"' "$ARCHIVE/approved-task-dag.json" 2>/dev/null || \
  ! grep -Fq "report artifact" "$ARCHIVE/report.md" 2>/dev/null; then
  find "$ARCHIVE" -maxdepth 1 -type f -print | sed 's/^/  archive diagnostic: /'
fi
check "archive preserves plan/status HTML, Sites receipt, and existing evidence" bash -c \
  '[[ "$(cat "$1/design.md")" = "design artifact" && "$(cat "$1/plan.md")" = "plan artifact" && "$(cat "$1/DECISIONS.md")" = "decision artifact" && "$(cat "$1/verification.md")" = "verification artifact" ]] && grep -Fq "plan review artifact" "$1/plan-review.html" && grep -Fq "status truth artifact" "$1/status-truth.html" && grep -Fq "https://example.openai.site/mission" "$1/sites-delivery.json" && grep -Fq "\"mission\":\"mission\"" "$1/approved-task-dag.json" && grep -Fq "report artifact" "$1/report.md"' \
  _ "$ARCHIVE"
$GC --hub "$HUB" --clean >/dev/null 2>&1
check "repeated exact parent cleanup is an idempotent no-op" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/parent-cleanup-state")" = collected && ! -e "$3" ]]' \
  _ "$?" "$CONTROL" "$PARENT"

setup_fixture unresolved-review
printf 'pending\n' > "$CONTROL/review-resolution"
$GC --hub "$HUB" --clean >/dev/null 2>&1
check "unresolved final review preserves exact parent resources" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/parent-cleanup-state")" = cleanup_pending && -d "$3" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5" && git --git-dir "$6" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$?" "$CONTROL" "$PARENT" "$REPO" "$BRANCH" "$REMOTE"

setup_fixture unmerged no
printf '%s\t%s\tmerged\tpr-123\t%s\n' "$REPO" "$TARGET" "$PARENT_TIP" \
  > "$CONTROL/pr-merge-metadata"
$GC --hub "$HUB" --clean >/dev/null 2>&1
check "PR metadata never substitutes for target-branch containment proof" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/parent-cleanup-state")" = cleanup_pending ]] && [[ -d "$3" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$?" "$CONTROL" "$PARENT" "$REPO" "$BRANCH"

setup_fixture invalid-pr-metadata
TARGET_TIP="$(git -C "$REPO" rev-parse "$TARGET")"
printf '%s\t%s\topen\tpr-456\t%s\n' "$REPO" "$TARGET" "$TARGET_TIP" \
  > "$CONTROL/pr-merge-metadata"
$GC --hub "$HUB" --clean >/dev/null 2>&1
check "available PR metadata must itself verify as merged additional evidence" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/parent-cleanup-state")" = cleanup_pending && -d "$3" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$?" "$CONTROL" "$PARENT" "$REPO" "$BRANCH"

setup_fixture unrelated-pr-merge
UNRELATED_PR_MERGE="$(git -C "$REPO" rev-parse "${PARENT_TIP}^")"
printf '%s\t%s\tmerged\tpr-unrelated\t%s\n' \
  "$REPO" "$TARGET" "$UNRELATED_PR_MERGE" > "$CONTROL/pr-merge-metadata"
check_parent_preserved_after_gc \
  "PR merge evidence must contain the exact recorded parent tip"

setup_fixture dirty
printf 'dirty\n' > "$PARENT/dirty.txt"
$GC --hub "$HUB" --clean >/dev/null 2>&1
check "dirty exact parent worktree becomes cleanup_pending and is preserved" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/parent-cleanup-state")" = cleanup_pending && -n "$(git -C "$3" status --porcelain --untracked-files=all)" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$?" "$CONTROL" "$PARENT" "$REPO" "$BRANCH"

setup_fixture changed-tip
printf 'late change\n' > "$PARENT/late.txt"
git -C "$PARENT" add late.txt
git -C "$PARENT" commit -qm late-change
$GC --hub "$HUB" --clean >/dev/null 2>&1
check "parent tip differing from exact manifest authority is preserved" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/parent-cleanup-state")" = cleanup_pending && -d "$3" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$?" "$CONTROL" "$PARENT" "$REPO" "$BRANCH"

setup_fixture malformed
printf '\n' >> "$CONTROL/parent-cleanup-manifest.txt"
$GC --hub "$HUB" --clean >/dev/null 2>&1
check "malformed parent cleanup manifest fails closed" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/parent-cleanup-state")" = cleanup_pending && -d "$3" ]]' \
  _ "$?" "$CONTROL" "$PARENT"

setup_fixture remote-drift
REMOTE_DRIFT="$(printf 'remote drift\n' | git -C "$REPO" commit-tree "$(git -C "$REPO" rev-parse "${PARENT_TIP}^{tree}")" -p "$PARENT_TIP")"
git -C "$REPO" push -q --force-with-lease="refs/heads/$BRANCH:$PARENT_TIP" \
  origin "$REMOTE_DRIFT:refs/heads/$BRANCH"
$GC --hub "$HUB" --clean >/dev/null 2>&1
check "changed remote parent tip is preserved instead of pattern-deleted" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/parent-cleanup-state")" = cleanup_pending && -d "$3" ]] && [[ "$(git --git-dir "$4" rev-parse "refs/heads/$5")" = "$6" ]]' \
  _ "$?" "$CONTROL" "$PARENT" "$REMOTE" "$BRANCH" "$REMOTE_DRIFT"

setup_fixture transient-network
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
PATH="$WRAP:$PATH" ORC_TEST_REAL_GIT="$REAL_GIT" \
  "$GC" --hub "$HUB" --clean >/dev/null 2>&1
NETWORK_RC=$?
check "transient remote failure records cleanup_pending without partial deletion" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/parent-cleanup-state")" = cleanup_pending && -d "$3" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5" && git --git-dir "$6" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$NETWORK_RC" "$CONTROL" "$PARENT" "$REPO" "$BRANCH" "$REMOTE"
$GC --hub "$HUB" --clean >"$FIXTURE/retry.out" 2>"$FIXTURE/retry.err"
RETRY_RC=$?
if [[ "$RETRY_RC" -ne 0 ]]; then
  sed 's/^/  retry diagnostic: /' "$FIXTURE/retry.err"
fi
check "cleanup_pending parent retry finishes from retained exact authority" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/parent-cleanup-state")" = collected && ! -e "$3" ]] && ! git -C "$4" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$RETRY_RC" "$CONTROL" "$PARENT" "$REPO" "$BRANCH"

setup_fixture parent-ref-as-target
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$PARENT" "$BRANCH" "$PARENT_TIP" "$REPO" "$BRANCH" \
  > "$CONTROL/parent-cleanup-manifest.txt"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
PARENT_TARGET_ALIAS_RC=$?
check "parent cleanup target cannot alias the mission-owned parent ref" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && "$(cat "$3/parent-cleanup-state")" = cleanup_pending && ! -e "$3/parent-cleanup-intent" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5" && git --git-dir "$6" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$PARENT_TARGET_ALIAS_RC" "$PARENT" "$CONTROL" "$REPO" "$BRANCH" "$REMOTE"
printf 'ready\n' > "$CONTROL/parent-cleanup-state"
git -C "$REPO" symbolic-ref refs/heads/parent-target-alias "refs/heads/$BRANCH"
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$PARENT" "$BRANCH" "$PARENT_TIP" "$REPO" parent-target-alias \
  > "$CONTROL/parent-cleanup-manifest.txt"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
SYMBOLIC_PARENT_TARGET_RC=$?
check "normalized symbolic target alias cannot hide the mission-owned parent ref" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && "$(cat "$3/parent-cleanup-state")" = cleanup_pending ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5" && git --git-dir "$6" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$SYMBOLIC_PARENT_TARGET_RC" "$PARENT" "$CONTROL" "$REPO" "$BRANCH" "$REMOTE"

setup_fixture dual-stale-gc
DUAL_LOCK="$CONTROL/.task-worktree.lock"
DUAL_GUARD="$DUAL_LOCK.guard"
mkdir "$DUAL_GUARD"
printf '999994\tdeadgcguard\n' > "$DUAL_GUARD/owner"
printf '999993\tdeadgclock\n' > "$DUAL_LOCK.999993.deadgclock"
ln "$DUAL_LOCK.999993.deadgclock" "$DUAL_LOCK"
( "$GC" --hub "$HUB" --clean >/dev/null 2>&1; echo "$?" > "$FIXTURE/dual-a.rc" ) &
DUAL_GC_A=$!
( "$GC" --hub "$HUB" --clean >/dev/null 2>&1; echo "$?" > "$FIXTURE/dual-b.rc" ) &
DUAL_GC_B=$!
wait "$DUAL_GC_A" 2>/dev/null || true
wait "$DUAL_GC_B" 2>/dev/null || true
check "two GC stale recoverers serialize one collection and preserve the target ref" bash -c \
  '[[ "$(cat "$1/parent-cleanup-state")" = collected && ! -e "$2" && ! -e "$3" && ! -e "$4" && "$(grep -c "parent cleanup collected:" "$1/parent-cleanup-journal.log")" -eq 1 ]] && git -C "$5" show-ref --verify --quiet "refs/heads/$6"' \
  _ "$CONTROL" "$PARENT" "$DUAL_LOCK" "$DUAL_GUARD" "$REPO" "$TARGET"

setup_fixture ownerless-guard
OWNERLESS_GUARD="$CONTROL/.task-worktree.lock.guard"
mkdir "$OWNERLESS_GUARD"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
OWNERLESS_GC_RC=$?
check "parent GC recovers a half-published ownerless guard without permanent lockout" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/parent-cleanup-state")" = collected && ! -e "$3" && ! -e "$4" ]] && git -C "$5" show-ref --verify --quiet "refs/heads/$6"' \
  _ "$OWNERLESS_GC_RC" "$CONTROL" "$PARENT" "$OWNERLESS_GUARD" "$REPO" "$TARGET"

setup_fixture nonterminal-child
mkdir -p "$CONTROL/tasks/task-a"
printf 'running\n' > "$CONTROL/tasks/task-a/state"
printf '01a0running-child\n' > "$CONTROL/tasks/task-a/accepted-thread-id"
printf 'visible\n' > "$CONTROL/tasks/task-a/task-window-state"
$GC --hub "$HUB" --clean >/dev/null 2>&1
check "nonterminal child task window and parent resources remain preserved" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/tasks/task-a/task-window-state")" = visible && -d "$3" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$?" "$CONTROL" "$PARENT" "$REPO" "$BRANCH"

setup_fixture terminal-visible-child
mkdir -p "$CONTROL/tasks/task-a"
printf 'collected\n' > "$CONTROL/tasks/task-a/state"
printf '01a0terminal-child\n' > "$CONTROL/tasks/task-a/accepted-thread-id"
printf 'visible\n' > "$CONTROL/tasks/task-a/task-window-state"
$GC --hub "$HUB" --clean >/dev/null 2>&1
check "terminal visible child blocks parent collection until coordinator archival" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/tasks/task-a/task-window-state")" = visible && -d "$3" ]]' \
  _ "$?" "$CONTROL" "$PARENT"

setup_fixture unresolved-child-rework
mkdir -p "$CONTROL/tasks/task-a"
printf 'collected\n' > "$CONTROL/tasks/task-a/state"
printf '01a0rework-child\n' > "$CONTROL/tasks/task-a/accepted-thread-id"
printf 'archived\n' > "$CONTROL/tasks/task-a/task-window-state"
: > "$CONTROL/tasks/task-a/unresolved-rework"
$GC --hub "$HUB" --clean >/dev/null 2>&1
check "unresolved child rework blocks parent collection and remains archived" bash -c \
  '[[ "$1" -ne 0 && -e "$2/tasks/task-a/unresolved-rework" && "$(cat "$2/tasks/task-a/task-window-state")" = archived && -d "$3" ]]' \
  _ "$?" "$CONTROL" "$PARENT"

setup_fixture symlinked-child-registry
OUTSIDE_TASK="$FIXTURE/outside-task"
mkdir -p "$CONTROL/tasks" "$OUTSIDE_TASK"
printf 'collected\n' > "$OUTSIDE_TASK/state"
printf '01a0outside-child\n' > "$OUTSIDE_TASK/accepted-thread-id"
printf 'archived\n' > "$OUTSIDE_TASK/task-window-state"
ln -s "$OUTSIDE_TASK" "$CONTROL/tasks/task-a"
check_parent_preserved_after_gc \
  "symlinked child registry entry outside coordinator control is refused"

setup_fixture missing-child-thread-id
mkdir -p "$CONTROL/tasks/task-a"
printf 'collected\n' > "$CONTROL/tasks/task-a/state"
printf 'archived\n' > "$CONTROL/tasks/task-a/task-window-state"
check_parent_preserved_after_gc \
  "collected child without an accepted thread identity is refused"

setup_fixture malformed-child-thread-id
mkdir -p "$CONTROL/tasks/task-a"
printf 'collected\n' > "$CONTROL/tasks/task-a/state"
printf 'bad\tthread\n' > "$CONTROL/tasks/task-a/accepted-thread-id"
printf 'archived\n' > "$CONTROL/tasks/task-a/task-window-state"
check_parent_preserved_after_gc \
  "collected child with malformed accepted thread identity is refused"

setup_fixture invalid-child-task-id
mkdir -p "$CONTROL/tasks/bad task"
printf 'collected\n' > "$CONTROL/tasks/bad task/state"
printf '01a0bad-task-child\n' > "$CONTROL/tasks/bad task/accepted-thread-id"
printf 'archived\n' > "$CONTROL/tasks/bad task/task-window-state"
check_parent_preserved_after_gc \
  "noncanonical direct child task identity is refused"

setup_fixture symlinked-child-thread-id
mkdir -p "$CONTROL/tasks/task-a"
printf 'collected\n' > "$CONTROL/tasks/task-a/state"
printf '01a0symlinked-child\n' > "$FIXTURE/outside-thread-id"
ln -s "$FIXTURE/outside-thread-id" "$CONTROL/tasks/task-a/accepted-thread-id"
printf 'archived\n' > "$CONTROL/tasks/task-a/task-window-state"
check_parent_preserved_after_gc \
  "symlinked accepted child thread authority is refused"

setup_fixture malformed-child-state
mkdir -p "$CONTROL/tasks/task-a"
printf 'collected\nextra\n' > "$CONTROL/tasks/task-a/state"
printf '01a0malformed-state-child\n' > "$CONTROL/tasks/task-a/accepted-thread-id"
printf 'archived\n' > "$CONTROL/tasks/task-a/task-window-state"
check_parent_preserved_after_gc \
  "multiline collected child state authority is refused"

setup_fixture symlinked-child-window-state
mkdir -p "$CONTROL/tasks/task-a"
printf 'collected\n' > "$CONTROL/tasks/task-a/state"
printf '01a0symlinked-state-child\n' > "$CONTROL/tasks/task-a/accepted-thread-id"
printf 'archived\n' > "$FIXTURE/outside-window-state"
ln -s "$FIXTURE/outside-window-state" "$CONTROL/tasks/task-a/task-window-state"
check_parent_preserved_after_gc \
  "symlinked child task-window state authority is refused"

setup_fixture symlinked-mission-entry
add_archived_child_authority
OUTSIDE_MISSION="$FIXTURE/outside-mission"
mv "$MISSION" "$OUTSIDE_MISSION"
ln -s "$OUTSIDE_MISSION" "$MISSION"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
MISSION_SYMLINK_RC=$?
check "symlinked mission entry outside the missions root is refused" bash -c \
  '[[ "$1" -ne 0 && -L "$2" && -d "$3" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5" && git --git-dir "$6" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$MISSION_SYMLINK_RC" "$MISSION" "$PARENT" "$REPO" "$BRANCH" "$REMOTE"

setup_fixture symlinked-hub
add_archived_child_authority
REAL_HUB="$HUB"
HUB="$FIXTURE/hub-link"
ln -s "$REAL_HUB" "$HUB"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
HUB_SYMLINK_RC=$?
check "symlinked hub root is rejected before parent mutation" bash -c \
  '[[ "$1" -ne 0 && -d "$2" ]] && git -C "$3" show-ref --verify --quiet "refs/heads/$4" && git --git-dir "$5" show-ref --verify --quiet "refs/heads/$4"' \
  _ "$HUB_SYMLINK_RC" "$PARENT" "$REPO" "$BRANCH" "$REMOTE"

setup_fixture symlinked-hub-dot-alias
add_archived_child_authority
REAL_HUB="$HUB"
HUB_LINK="$FIXTURE/hub-link"
ln -s "$REAL_HUB" "$HUB_LINK"
"$GC" --hub "$HUB_LINK/." --clean >/dev/null 2>&1
HUB_DOT_ALIAS_RC=$?
check "symlinked hub dot alias is rejected before parent mutation" bash -c \
  '[[ "$1" -ne 0 && -d "$2" ]] && git -C "$3" show-ref --verify --quiet "refs/heads/$4" && git --git-dir "$5" show-ref --verify --quiet "refs/heads/$4"' \
  _ "$HUB_DOT_ALIAS_RC" "$PARENT" "$REPO" "$BRANCH" "$REMOTE"

setup_fixture symlinked-control-entry
add_archived_child_authority
OUTSIDE_CONTROL="$FIXTURE/outside-control"
mv "$CONTROL" "$OUTSIDE_CONTROL"
ln -s "$OUTSIDE_CONTROL" "$CONTROL"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
CONTROL_SYMLINK_RC=$?
check "symlinked coordinator control entry is refused without traversal" bash -c \
  '[[ "$1" -ne 0 && -L "$2" && -d "$3" ]] && git -C "$4" show-ref --verify --quiet "refs/heads/$5" && git --git-dir "$6" show-ref --verify --quiet "refs/heads/$5"' \
  _ "$CONTROL_SYMLINK_RC" "$CONTROL" "$PARENT" "$REPO" "$BRANCH" "$REMOTE"

setup_fixture symlinked-task-root
OUTSIDE_TASK_ROOT="$FIXTURE/outside-tasks"
mkdir -p "$OUTSIDE_TASK_ROOT/task-a"
printf 'collected\n' > "$OUTSIDE_TASK_ROOT/task-a/state"
printf '01a0outside-root-child\n' > "$OUTSIDE_TASK_ROOT/task-a/accepted-thread-id"
printf 'archived\n' > "$OUTSIDE_TASK_ROOT/task-a/task-window-state"
ln -s "$OUTSIDE_TASK_ROOT" "$CONTROL/tasks"
check_parent_preserved_after_gc \
  "symlinked coordinator tasks root is refused without traversal"

setup_fixture target-ref-rewind
add_archived_child_authority
TARGET_BEFORE="$(git -C "$REPO" rev-parse "refs/heads/$TARGET")"
TARGET_REWIND="$(git -C "$REPO" rev-parse "${PARENT_TIP}^")"
REAL_GIT="$(command -v git)"
RACE_BIN="$FIXTURE/target-race-bin"
RACE_MARKER="$FIXTURE/target-rewound"
mkdir -p "$RACE_BIN"
cat > "$RACE_BIN/git" <<'SH'
#!/usr/bin/env bash
set -u
if [[ " $* " == *" -C $ORC_TARGET_RACE_PARENT status --porcelain "* && \
  ! -e "$ORC_TARGET_RACE_MARKER" ]]; then
  "$ORC_TARGET_RACE_REAL_GIT" -C "$ORC_TARGET_RACE_REPO" update-ref \
    "refs/heads/$ORC_TARGET_RACE_TARGET" "$ORC_TARGET_RACE_REWIND" \
    "$ORC_TARGET_RACE_BEFORE" || exit 91
  : > "$ORC_TARGET_RACE_MARKER"
fi
exec "$ORC_TARGET_RACE_REAL_GIT" "$@"
SH
chmod +x "$RACE_BIN/git"
PATH="$RACE_BIN:$PATH" ORC_TARGET_RACE_REAL_GIT="$REAL_GIT" \
  ORC_TARGET_RACE_PARENT="$PARENT" ORC_TARGET_RACE_REPO="$REPO" \
  ORC_TARGET_RACE_TARGET="$TARGET" ORC_TARGET_RACE_REWIND="$TARGET_REWIND" \
  ORC_TARGET_RACE_BEFORE="$TARGET_BEFORE" ORC_TARGET_RACE_MARKER="$RACE_MARKER" \
  "$GC" --hub "$HUB" --clean >/dev/null 2>&1
TARGET_RACE_RC=$?
check "target rewind after precheck fails closed before parent resource mutation" bash -c \
  '[[ "$1" -ne 0 && -e "$2" && "$(cat "$3/parent-cleanup-state")" = cleanup_pending && -d "$4" && "$(git -C "$5" rev-parse "refs/heads/$6")" = "$7" ]] && git -C "$5" show-ref --verify --quiet "refs/heads/$8" && git --git-dir "$9" show-ref --verify --quiet "refs/heads/$8"' \
  _ "$TARGET_RACE_RC" "$RACE_MARKER" "$CONTROL" "$PARENT" "$REPO" \
  "$TARGET" "$TARGET_REWIND" "$BRANCH" "$REMOTE"

setup_fixture archive-short-write
add_archived_child_authority
ORC_ARCHIVE_TEST_MAX_WRITE=3 ORC_ARCHIVE_TEST_FAIL_AFTER_BYTES=3 \
  "$GC" --hub "$HUB" --clean >/dev/null 2>&1
SHORT_WRITE_RC=$?
SHORT_WRITE_PRESERVED=0
if [[ -d "$PARENT" ]] && git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" && \
  git --git-dir "$REMOTE" show-ref --verify --quiet "refs/heads/$BRANCH" && \
  { [[ ! -e "$ARCHIVE/design.md" ]] || cmp -s "$MISSION/design.md" "$ARCHIVE/design.md"; } && \
  [[ -z "$(find "$ARCHIVE" -maxdepth 1 -name '.archive-item.*' -print -quit 2>/dev/null)" ]]; then
  SHORT_WRITE_PRESERVED=1
fi
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
SHORT_WRITE_RETRY_RC=$?
check "archive short write never publishes truncation and exact retry converges" bash -c \
  '[[ "$1" -ne 0 && "$2" -eq 1 && "$3" -eq 0 && ! -e "$4" && "$(cat "$5/parent-cleanup-state")" = collected ]] && cmp -s "$6/design.md" "$7/design.md" && grep -Fq "parent cleanup collected" "$7/cleanup-journal.log"' \
  _ "$SHORT_WRITE_RC" "$SHORT_WRITE_PRESERVED" "$SHORT_WRITE_RETRY_RC" \
  "$PARENT" "$CONTROL" "$MISSION" "$ARCHIVE"

setup_fixture stale-lock-replacement
LOCK_PATH="$CONTROL/.task-worktree.lock"
OLD_LOCK_PID=999997
OLD_LOCK_TOKEN=oldgcstale
OLD_LOCK_CANDIDATE="$LOCK_PATH.$OLD_LOCK_PID.$OLD_LOCK_TOKEN"
printf '%s\t%s\n' "$OLD_LOCK_PID" "$OLD_LOCK_TOKEN" > "$OLD_LOCK_CANDIDATE"
ln "$OLD_LOCK_CANDIDATE" "$LOCK_PATH"
sleep 30 &
NEW_LOCK_PID=$!
NEW_LOCK_TOKEN=newgclive
NEW_LOCK_CANDIDATE="$LOCK_PATH.$NEW_LOCK_PID.$NEW_LOCK_TOKEN"
NEW_LOCK_SOURCE="$CONTROL/.new-live-lock-source"
printf '%s\t%s\n' "$NEW_LOCK_PID" "$NEW_LOCK_TOKEN" > "$NEW_LOCK_SOURCE"
ln "$NEW_LOCK_SOURCE" "$NEW_LOCK_CANDIDATE"
LOCK_REPLACEMENT_MARKER="$FIXTURE/stale-lock-replaced"
ORC_GC_STALE_LOCK_TEST_FINAL_REPLACEMENT="$NEW_LOCK_SOURCE" \
  ORC_GC_STALE_LOCK_TEST_MARKER="$LOCK_REPLACEMENT_MARKER" \
  "$GC" --hub "$HUB" --clean >/dev/null 2>&1
LOCK_REPLACEMENT_RC=$?
check "parent GC stale recovery never removes an atomically replaced live lifecycle lock" bash -c \
  '[[ "$1" -ne 0 && -f "$2" && -f "$3" && "$2" -ef "$3" && -f "$4" && -f "$5" && -d "$6" && "$(cat "$7/parent-cleanup-state")" = ready ]] && git -C "$8" show-ref --verify --quiet "refs/heads/$9"' \
  _ "$LOCK_REPLACEMENT_RC" "$LOCK_PATH" "$NEW_LOCK_CANDIDATE" \
  "$LOCK_REPLACEMENT_MARKER" "$OLD_LOCK_CANDIDATE" "$PARENT" "$CONTROL" "$REPO" "$BRANCH"
kill "$NEW_LOCK_PID" >/dev/null 2>&1 || true
wait "$NEW_LOCK_PID" 2>/dev/null || true
rm -f -- "$OLD_LOCK_CANDIDATE"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
LOCK_REPLACEMENT_RETRY_RC=$?
check "parent GC exact retry converges after the replacement lock owner exits" bash -c \
  '[[ "$1" -eq 0 && ! -e "$2" && ! -e "$3" && ! -e "$4" && "$(cat "$5/parent-cleanup-state")" = collected ]]' \
  _ "$LOCK_REPLACEMENT_RETRY_RC" "$PARENT" "$LOCK_PATH" "$NEW_LOCK_CANDIDATE" "$CONTROL"

setup_fixture live-lifecycle-lock
LOCK_TOKEN=liveowner
LOCK_PATH="$CONTROL/.task-worktree.lock"
LOCK_CANDIDATE="$LOCK_PATH.$$.$LOCK_TOKEN"
printf '%s\t%s\n' "$$" "$LOCK_TOKEN" > "$LOCK_CANDIDATE"
ln "$LOCK_CANDIDATE" "$LOCK_PATH"
MANIFEST_BEFORE="$(shasum -a 256 "$CONTROL/parent-cleanup-manifest.txt" | awk '{print $1}')"
MANIFEST_INODE_BEFORE="$(inode_id "$CONTROL/parent-cleanup-manifest.txt")"
MANIFEST_SIZE_BEFORE="$(wc -c < "$CONTROL/parent-cleanup-manifest.txt" | tr -d ' ')"
STATE_BEFORE="$(shasum -a 256 "$CONTROL/parent-cleanup-state" | awk '{print $1}')"
STATE_INODE_BEFORE="$(inode_id "$CONTROL/parent-cleanup-state")"
PENDING_MARKER="$CONTROL/parent-cleanup-pending-request.json"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
LIVE_LOCK_RC=$?
MANIFEST_AFTER="$(shasum -a 256 "$CONTROL/parent-cleanup-manifest.txt" | awk '{print $1}')"
STATE_AFTER="$(shasum -a 256 "$CONTROL/parent-cleanup-state" | awk '{print $1}')"
STATE_INODE_AFTER="$(inode_id "$CONTROL/parent-cleanup-state")"
check "live lifecycle lock publishes bound pending marker without owner-state mutation" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/parent-cleanup-state")" = ready && "$3" = "$4" && "$5" = "$6" && "$7" = "$8" && -f "$9" && -f "${10}" && "$9" -ef "${10}" && -f "${11}" && -d "${12}" ]] && git -C "${13}" show-ref --verify --quiet "refs/heads/${14}" && git --git-dir "${15}" show-ref --verify --quiet "refs/heads/${14}"' \
  _ "$LIVE_LOCK_RC" "$CONTROL" "$MANIFEST_BEFORE" "$MANIFEST_AFTER" \
  "$STATE_BEFORE" "$STATE_AFTER" "$STATE_INODE_BEFORE" "$STATE_INODE_AFTER" \
  "$LOCK_PATH" "$LOCK_CANDIDATE" "$PENDING_MARKER" "$PARENT" \
  "$REPO" "$BRANCH" "$REMOTE"
check "live-lock pending marker binds full manifest and state epochs" \
  pending_marker_binds "$PENDING_MARKER" "$MANIFEST_BEFORE" "$MANIFEST_INODE_BEFORE" \
  "$MANIFEST_SIZE_BEFORE" "$STATE_BEFORE" "$STATE_INODE_BEFORE"
rm -f -- "$LOCK_PATH" "$LOCK_CANDIDATE"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
LIVE_LOCK_RETRY_RC=$?
if [[ "$LIVE_LOCK_RETRY_RC" -ne 0 ]]; then
  echo "  live retry diagnostic: state=$(cat "$CONTROL/parent-cleanup-state" 2>/dev/null || true) lock=$([[ -e "$LOCK_PATH" ]] && echo present || echo absent) guard=$([[ -e "$LOCK_PATH.guard" ]] && echo present || echo absent)"
fi
check "released lifecycle lock retry converges exact parent collection" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/parent-cleanup-state")" = collected && ! -e "$3" && ! -e "$4" ]] && grep -Fqi "lifecycle mutation lock" "$5/cleanup-journal.log" && ! git -C "$6" show-ref --verify --quiet "refs/heads/$7" && ! git --git-dir "$8" show-ref --verify --quiet "refs/heads/$7"' \
  _ "$LIVE_LOCK_RETRY_RC" "$CONTROL" "$PARENT" "$PENDING_MARKER" "$ARCHIVE" \
  "$REPO" "$BRANCH" "$REMOTE"

setup_fixture live-lock-owner-state-race
LOCK_TOKEN=liveowner-race
LOCK_PATH="$CONTROL/.task-worktree.lock"
LOCK_CANDIDATE="$LOCK_PATH.$$.$LOCK_TOKEN"
printf '%s\t%s\n' "$$" "$LOCK_TOKEN" > "$LOCK_CANDIDATE"
ln "$LOCK_CANDIDATE" "$LOCK_PATH"
PENDING_MARKER="$CONTROL/parent-cleanup-pending-request.json"
MANIFEST_OBSERVED="$(shasum -a 256 "$CONTROL/parent-cleanup-manifest.txt" | awk '{print $1}')"
MANIFEST_INODE_OBSERVED="$(inode_id "$CONTROL/parent-cleanup-manifest.txt")"
MANIFEST_SIZE_OBSERVED="$(wc -c < "$CONTROL/parent-cleanup-manifest.txt" | tr -d ' ')"
STATE_OBSERVED="$(shasum -a 256 "$CONTROL/parent-cleanup-state" | awk '{print $1}')"
STATE_INODE_OBSERVED="$(inode_id "$CONTROL/parent-cleanup-state")"
OWNER_STATE="$CONTROL/.owner-newer-state"
printf 'cleanup_pending\n' > "$OWNER_STATE"
chmod 0600 "$OWNER_STATE"
OWNER_STATE_INODE="$(inode_id "$OWNER_STATE")"
OWNER_RACE_MARKER="$FIXTURE/owner-state-published"
ORC_PARENT_PENDING_TEST_REPLACE_STATE_WITH="$OWNER_STATE" \
  ORC_PARENT_PENDING_TEST_REPLACE_MARKER="$OWNER_RACE_MARKER" \
  "$GC" --hub "$HUB" --clean >/dev/null 2>&1
OWNER_RACE_RC=$?
OWNER_STATE_AFTER_INODE="$(inode_id "$CONTROL/parent-cleanup-state")"
check "owner state replacement wins pending-marker publication race" bash -c \
  '[[ "$1" -ne 0 && -e "$2" && "$(cat "$3/parent-cleanup-state")" = cleanup_pending && "$4" != "$5" && "$5" = "$6" && -f "$7" && -d "$8" ]] && git -C "$9" show-ref --verify --quiet "refs/heads/${10}" && git --git-dir "${11}" show-ref --verify --quiet "refs/heads/${10}"' \
  _ "$OWNER_RACE_RC" "$OWNER_RACE_MARKER" "$CONTROL" "$STATE_INODE_OBSERVED" \
  "$OWNER_STATE_AFTER_INODE" "$OWNER_STATE_INODE" "$PENDING_MARKER" "$PARENT" \
  "$REPO" "$BRANCH" "$REMOTE"
check "owner-state race marker binds the pre-race manifest and state epochs" \
  pending_marker_binds "$PENDING_MARKER" "$MANIFEST_OBSERVED" "$MANIFEST_INODE_OBSERVED" \
  "$MANIFEST_SIZE_OBSERVED" "$STATE_OBSERVED" "$STATE_INODE_OBSERVED"
rm -f -- "$LOCK_PATH" "$LOCK_CANDIDATE"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
OWNER_RACE_RETRY_RC=$?
check "owner-race pending marker is consumed under lock and retry converges" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/parent-cleanup-state")" = collected && ! -e "$3" && ! -e "$4" ]] && grep -Fqi "lifecycle mutation lock" "$5/cleanup-journal.log" && ! git -C "$6" show-ref --verify --quiet "refs/heads/$7" && ! git --git-dir "$8" show-ref --verify --quiet "refs/heads/$7"' \
  _ "$OWNER_RACE_RETRY_RC" "$CONTROL" "$PARENT" "$PENDING_MARKER" "$ARCHIVE" \
  "$REPO" "$BRANCH" "$REMOTE"

setup_fixture live-lock-owner-manifest-race
LOCK_TOKEN=liveowner-manifest-race
LOCK_PATH="$CONTROL/.task-worktree.lock"
LOCK_CANDIDATE="$LOCK_PATH.$$.$LOCK_TOKEN"
printf '%s\t%s\n' "$$" "$LOCK_TOKEN" > "$LOCK_CANDIDATE"
ln "$LOCK_CANDIDATE" "$LOCK_PATH"
PENDING_MARKER="$CONTROL/parent-cleanup-pending-request.json"
MANIFEST_OBSERVED="$(shasum -a 256 "$CONTROL/parent-cleanup-manifest.txt" | awk '{print $1}')"
MANIFEST_INODE_OBSERVED="$(inode_id "$CONTROL/parent-cleanup-manifest.txt")"
MANIFEST_SIZE_OBSERVED="$(wc -c < "$CONTROL/parent-cleanup-manifest.txt" | tr -d ' ')"
STATE_OBSERVED="$(shasum -a 256 "$CONTROL/parent-cleanup-state" | awk '{print $1}')"
STATE_INODE_OBSERVED="$(inode_id "$CONTROL/parent-cleanup-state")"
OWNER_MANIFEST="$CONTROL/.owner-newer-manifest"
cp "$CONTROL/parent-cleanup-manifest.txt" "$OWNER_MANIFEST"
chmod 0600 "$OWNER_MANIFEST"
OWNER_MANIFEST_INODE="$(inode_id "$OWNER_MANIFEST")"
OWNER_MANIFEST_RACE_MARKER="$FIXTURE/owner-manifest-published"
ORC_PARENT_PENDING_TEST_REPLACE_MANIFEST_WITH="$OWNER_MANIFEST" \
  ORC_PARENT_PENDING_TEST_REPLACE_MANIFEST_MARKER="$OWNER_MANIFEST_RACE_MARKER" \
  "$GC" --hub "$HUB" --clean >/dev/null 2>&1
MANIFEST_RACE_RC=$?
MANIFEST_AFTER_INODE="$(inode_id "$CONTROL/parent-cleanup-manifest.txt")"
STATE_AFTER_INODE="$(inode_id "$CONTROL/parent-cleanup-state")"
check "same-bytes owner manifest replacement wins pending-marker publication race" bash -c \
  '[[ "$1" -ne 0 && -e "$2" && "$3" != "$4" && "$4" = "$5" && "$6" = "$7" && "$(cat "$8/parent-cleanup-state")" = ready && -f "$9" && -d "${10}" ]] && git -C "${11}" show-ref --verify --quiet "refs/heads/${12}" && git --git-dir "${13}" show-ref --verify --quiet "refs/heads/${12}"' \
  _ "$MANIFEST_RACE_RC" "$OWNER_MANIFEST_RACE_MARKER" "$MANIFEST_INODE_OBSERVED" \
  "$MANIFEST_AFTER_INODE" "$OWNER_MANIFEST_INODE" "$STATE_INODE_OBSERVED" \
  "$STATE_AFTER_INODE" "$CONTROL" "$PENDING_MARKER" "$PARENT" "$REPO" "$BRANCH" "$REMOTE"
check "manifest-race marker binds the replaced pre-race manifest inode" \
  pending_marker_binds "$PENDING_MARKER" "$MANIFEST_OBSERVED" "$MANIFEST_INODE_OBSERVED" \
  "$MANIFEST_SIZE_OBSERVED" "$STATE_OBSERVED" "$STATE_INODE_OBSERVED"
rm -f -- "$LOCK_PATH" "$LOCK_CANDIDATE"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
MANIFEST_STALE_CONSUME_RC=$?
check "locked reconciliation consumes stale manifest marker without state or resource mutation" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" && "$(cat "$3/parent-cleanup-state")" = ready && "$4" = "$5" && -d "$6" ]] && grep -Fqi "pending-request-consumed" "$3/parent-cleanup-journal.log" && git -C "$7" show-ref --verify --quiet "refs/heads/$8" && git --git-dir "$9" show-ref --verify --quiet "refs/heads/$8"' \
  _ "$MANIFEST_STALE_CONSUME_RC" "$PENDING_MARKER" "$CONTROL" \
  "$STATE_INODE_OBSERVED" "$(inode_id "$CONTROL/parent-cleanup-state")" "$PARENT" \
  "$REPO" "$BRANCH" "$REMOTE"
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
MANIFEST_RACE_RETRY_RC=$?
check "post-stale-marker exact reconciliation converges collection" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/parent-cleanup-state")" = collected && ! -e "$3" && ! -e "$4" ]] && grep -Fqi "lifecycle mutation lock" "$5/cleanup-journal.log" && ! git -C "$6" show-ref --verify --quiet "refs/heads/$7" && ! git --git-dir "$8" show-ref --verify --quiet "refs/heads/$7"' \
  _ "$MANIFEST_RACE_RETRY_RC" "$CONTROL" "$PARENT" "$PENDING_MARKER" "$ARCHIVE" \
  "$REPO" "$BRANCH" "$REMOTE"

check "Phase 0 runs report-only reconciliation before new scheduling" bash -c \
  'tr "\n" " " < "$1" | sed "s/[[:space:]][[:space:]]*/ /g" | grep -Fqi -- "Run report-only discovery"' \
  _ "$SKILL"
check "Phase 0 never requires hub-wide destructive cleanup" bash -c \
  'tr "\n" " " < "$1" | sed "s/[[:space:]][[:space:]]*/ /g" | grep -Fqi -- "Never use hub-wide destructive cleanup here"' \
  _ "$SKILL"
check "Phase 0 reconciles terminal child task-window archival" \
  grep -Fqi -- "archive the exact accepted child" "$CLEANUP_REF"
check "coordinator preserves nonterminal and unresolved child windows" bash -c \
  'tr "\n" " " < "$1" | sed "s/[[:space:]][[:space:]]*/ /g" | grep -Fqi -- "Never archive running, blocked, review, or unresolved-rework tasks"' \
  _ "$CLEANUP_REF"
check "parent collection requires target containment independent of PR metadata" bash -c \
  'normalized="$(tr "\n" " " < "$1" | sed "s/[[:space:]][[:space:]]*/ /g")"; [[ "$normalized" == *"exact parent tip contained in the target"* && "$normalized" == *"PR metadata may corroborate but never replace ancestry"* ]]' \
  _ "$CLEANUP_REF"

echo "  parent-gc-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
