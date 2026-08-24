#!/usr/bin/env bash
# Task 8 end-to-end contract for the mission DAG, two-level GC, and rework loop.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="$ROOT/scripts/validate-task-dag.sh"
LIFECYCLE="$ROOT/scripts/task-worktree.sh"
INTEGRATE="$ROOT/scripts/integrate-task.sh"
GC="$ROOT/scripts/orchestrator-gc.sh"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
README="$ROOT/README.md"
CODEX_MANIFEST="$ROOT/.codex-plugin/plugin.json"
CLAUDE_MANIFEST="$ROOT/.claude-plugin/plugin.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/orc-e2e-test.XXXXXX")"
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

contains() {
  local file="$1" literal="$2"
  [[ -f "$file" ]] && grep -Fqi -- "$literal" "$file"
}

# Deterministic external task/review API fixture. The coordinator transitions
# below consume only API results and durable authority, never chat contents.
TASK_API="$TMP/task-api.sh"
TASK_API_STATE="$TMP/task-api-state"
TASK_API_LOG="$TMP/task-api.log"
mkdir -p "$TASK_API_STATE"
cat > "$TASK_API" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
operation="$1"
identity="$2"
detail="${3:-}"
printf '%s\t%s\t%s\n' "$operation" "$identity" "$detail" >> "$ORC_E2E_TASK_API_LOG"
case "$operation" in
  create)
    [[ "$detail" = list-visible ]] || exit 1
    printf 'visible\n' > "$ORC_E2E_TASK_API_STATE/$identity"
    ;;
  archive)
    [[ "$(cat "$ORC_E2E_TASK_API_STATE/$identity" 2>/dev/null)" = visible ]] || exit 1
    [[ "${ORC_E2E_ARCHIVE_FAIL:-0}" != 1 ]] || exit 75
    printf 'archived\n' > "$ORC_E2E_TASK_API_STATE/$identity"
    ;;
  unarchive)
    [[ "$(cat "$ORC_E2E_TASK_API_STATE/$identity" 2>/dev/null)" = archived ]] || exit 1
    printf 'visible\n' > "$ORC_E2E_TASK_API_STATE/$identity"
    ;;
  review)
    [[ "$detail" = resolved ]] || exit 1
    ;;
  *) exit 64 ;;
esac
SH
chmod +x "$TASK_API"

task_api() {
  ORC_E2E_TASK_API_STATE="$TASK_API_STATE" \
    ORC_E2E_TASK_API_LOG="$TASK_API_LOG" "$TASK_API" "$@"
}

accept_child_thread() {
  local control="$1" task_dir="$2" task_id="$3" thread_id="$4" health="$5"
  local task_control="$control/tasks/$task_id" attempts=0
  mkdir -p "$task_control" "$task_dir"
  [[ ! -e "$task_control/accepted-thread-id" ]] || return 1
  [[ -f "$task_control/thread-health-attempts" ]] && \
    attempts="$(cat "$task_control/thread-health-attempts")"
  [[ "$attempts" = 0 || "$attempts" = 1 ]] || return 1
  attempts=$((attempts + 1))
  printf '%s\n' "$attempts" > "$task_control/thread-health-attempts"
  if ! task_api create "$thread_id" "$health"; then
    printf 'stale\t%s\n' "$thread_id" > "$task_control/provisional-thread-$attempts"
    if [[ "$attempts" -eq 2 ]]; then
      printf 'second provisional thread failed health check\n' > \
        "$task_control/BLOCKED-thread-health.md"
    fi
    return 1
  fi
  printf '%s\n' "$thread_id" > "$task_control/accepted-thread-id"
  printf '%s\n' "$thread_id" > "$task_dir/accepted-thread-id"
  printf 'unarchived\n' > "$task_control/task-window-state"
}

archive_child_thread() {
  local task_control="$1" thread_id="$2" fail="${3:-0}"
  [[ "$(cat "$task_control/accepted-thread-id" 2>/dev/null)" = "$thread_id" ]] || return 1
  if ! ORC_E2E_ARCHIVE_FAIL="$fail" task_api archive "$thread_id"; then
    : > "$task_control/task-window-archive-pending"
    printf 'cleanup_pending\n' > "$task_control/state"
    return 75
  fi
  rm -f "$task_control/task-window-archive-pending"
  printf 'collected\n' > "$task_control/state"
  printf 'archived\n' > "$task_control/task-window-state"
}

unarchive_child_thread() {
  local task_control="$1" thread_id="$2"
  [[ "$(cat "$task_control/accepted-thread-id" 2>/dev/null)" = "$thread_id" ]] || return 1
  task_api unarchive "$thread_id" || return 1
  printf 'unarchived\n' > "$task_control/task-window-state"
}

record_final_review() {
  local control="$1" verdict="$2"
  task_api review mission "$verdict" || return 1
  printf 'resolved\n' > "$control/review-resolution"
}

REPO="$TMP/repo"
REMOTE="$TMP/remote.git"
PARENT="$TMP/parent"
HUB="$TMP/.orchestrator"
MISSION="$HUB/missions/mission"
CONTROL="$HUB/control/mission"
mkdir -p "$MISSION" "$CONTROL" "$HUB/archive"

git init -q --bare "$REMOTE"
git init -q "$REPO"
git -C "$REPO" config user.email task8@example.invalid
git -C "$REPO" config user.name task8
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" remote add origin "$REMOTE"
printf 'base\n' > "$REPO/base.txt"
git -C "$REPO" add base.txt
git -C "$REPO" commit -qm base
git -C "$REPO" branch -M main
git -C "$REPO" push -q -u origin main
git -C "$REPO" worktree add -qb orc/mission "$PARENT" main >/dev/null

printf 'task-DAG lifecycle request\n' > "$MISSION/request.md"
cat > "$MISSION/MISSION.md" <<'EOF'
# Mission: task-DAG lifecycle
Briefs: coordinator-owned Hybrid pipeline
EOF
printf 'planned\n' > "$MISSION/state"

cat > "$MISSION/task-dag.json" <<'JSON'
{
  "version": 1,
  "mission": "mission",
  "tasks": [
    {
      "id": "task-a",
      "depends_on": [],
      "files": ["task-a.txt"],
      "contracts": ["task-a-contract"],
      "verification": ["test -f task-a.txt"],
      "state": "ready"
    },
    {
      "id": "task-b",
      "depends_on": ["task-a"],
      "files": ["task-b.txt"],
      "contracts": ["task-b-contract"],
      "verification": ["test -f task-b.txt"],
      "state": "pending"
    },
    {
      "id": "dirty",
      "depends_on": ["task-b"],
      "files": ["dirty.txt"],
      "contracts": ["dirty-fixture"],
      "verification": ["test -f dirty.txt"],
      "state": "pending"
    }
  ]
}
JSON

printf 'approved design\n' > "$CONTROL/approved-design.md"
printf 'approved plan\n' > "$CONTROL/approved-plan.md"
printf 'approved brief\n' > "$CONTROL/brief-exec.md"
printf '0.4.0\n' > "$CONTROL/pipeline-version"
(cd "$CONTROL" && shasum -a 256 approved-design.md approved-plan.md brief-exec.md > approved.sha256)

check "go gate invokes the validator freeze operation" contains "$SKILL" "validate-task-dag.sh --freeze"
check "approved DAG freezes into coordinator-owned hash authority" \
  "$VALIDATOR" --freeze "$MISSION/task-dag.json" "$CONTROL"
check "initial ready set contains only the dependency root" bash -c \
  '[[ "$(jq -r '\''[.tasks[] | select(.state == "ready") | .id] | join(" ")'\'' "$1")" = task-a ]]' \
  _ "$CONTROL/approved-task-dag.json"

chmod u+w "$CONTROL/approved.sha256" "$CONTROL/approved-design.md"
printf '%064d  unexpected\n' 0 >> "$CONTROL/approved.sha256"
"$LIFECYCLE" create --create-mode native-0.4 --mission-dir "$MISSION" \
  --control-dir "$CONTROL" --task-dir "$TMP/noncanonical-authority-task" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$TMP/noncanonical-authority-worktree" \
  >/dev/null 2>&1
NONCANONICAL_AUTHORITY_RC=$?
(cd "$CONTROL" && shasum -a 256 approved-design.md approved-plan.md \
  brief-exec.md approved-task-dag.json > approved.sha256)
check "production create rejects any noncanonical fifth approved-manifest entry" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" && ! -e "$3/tasks/task-a" ]] && ! git -C "$4" show-ref --verify --quiet refs/heads/orc-task/mission/task-a' \
  _ "$NONCANONICAL_AUTHORITY_RC" "$TMP/noncanonical-authority-worktree" "$CONTROL" "$REPO"

printf 'tampered design\n' > "$CONTROL/approved-design.md"
"$LIFECYCLE" create --create-mode native-0.4 --mission-dir "$MISSION" \
  --control-dir "$CONTROL" --task-dir "$TMP/hash-mismatch-task" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$TMP/hash-mismatch-worktree" \
  >/dev/null 2>&1
HASH_MISMATCH_RC=$?
printf 'approved design\n' > "$CONTROL/approved-design.md"
(cd "$CONTROL" && shasum -a 256 approved-design.md approved-plan.md \
  brief-exec.md approved-task-dag.json > approved.sha256)
chmod a-w "$CONTROL/approved.sha256" "$CONTROL/approved-design.md"
check "production create rejects approved artifact bytes that differ from the frozen hash" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" && ! -e "$3/tasks/task-a" ]] && ! git -C "$4" show-ref --verify --quiet refs/heads/orc-task/mission/task-a' \
  _ "$HASH_MISMATCH_RC" "$TMP/hash-mismatch-worktree" "$CONTROL" "$REPO"

PROBE_CONTROL="$TMP/thread-probe-control"
PROBE_TASK="$TMP/thread-probe-task"
accept_child_thread "$PROBE_CONTROL" "$PROBE_TASK" probe stale-provisional read-only >/dev/null 2>&1
PROBE_STALE_RC=$?
accept_child_thread "$PROBE_CONTROL" "$PROBE_TASK" probe accepted-replacement list-visible >/dev/null 2>&1
PROBE_REPLACEMENT_RC=$?
accept_child_thread "$PROBE_CONTROL" "$PROBE_TASK" probe duplicate-owner list-visible >/dev/null 2>&1
PROBE_DUPLICATE_RC=$?
check "stale provisional ID permits exactly one healthy replacement" bash -c \
  '[[ "$1" -ne 0 && "$2" -eq 0 && "$3" -ne 0 && "$(cat "$4/tasks/probe/accepted-thread-id")" = accepted-replacement ]]' \
  _ "$PROBE_STALE_RC" "$PROBE_REPLACEMENT_RC" "$PROBE_DUPLICATE_RC" "$PROBE_CONTROL"

BLOCKED_CONTROL="$TMP/thread-blocked-control"
BLOCKED_TASK="$TMP/thread-blocked-task"
accept_child_thread "$BLOCKED_CONTROL" "$BLOCKED_TASK" blocked stale-one read-only >/dev/null 2>&1
BLOCKED_FIRST_RC=$?
accept_child_thread "$BLOCKED_CONTROL" "$BLOCKED_TASK" blocked stale-two read-only >/dev/null 2>&1
BLOCKED_SECOND_RC=$?
check "a second unhealthy provisional child records durable BLOCKED" bash -c \
  '[[ "$1" -ne 0 && "$2" -ne 0 && -s "$3/tasks/blocked/BLOCKED-thread-health.md" && ! -e "$3/tasks/blocked/accepted-thread-id" ]]' \
  _ "$BLOCKED_FIRST_RC" "$BLOCKED_SECOND_RC" "$BLOCKED_CONTROL"

run_child_generation() {
  local task_id="$1"
  local archive_fail="${2:-0}"
  local task_dir="$TMP/$task_id"
  local child="$TMP/$task_id-worktree"
  local parent_tip child_tip
  parent_tip="$(git -C "$PARENT" rev-parse HEAD)"
  "$LIFECYCLE" create --create-mode native-0.4 --mission-dir "$MISSION" \
    --control-dir "$CONTROL" --task-dir "$task_dir" \
    --mission mission --task-id "$task_id" --repo "$REPO" \
    --parent-worktree "$PARENT" --worktree "$child" >/dev/null || return 1
  accept_child_thread "$CONTROL" "$task_dir" "$task_id" "thread-$task_id" list-visible || return 1
  printf 'running\n' > "$CONTROL/tasks/$task_id/state"
  printf 'running\n' > "$task_dir/state"
  printf '%s\n' "$task_id" > "$child/$task_id.txt"
  git -C "$child" add "$task_id.txt"
  git -C "$child" commit -qm "$task_id completion"
  child_tip="$(git -C "$child" rev-parse HEAD)"
  printf 'completed\n' > "$task_dir/state"
  printf '%s completed and verified at %s\n' "$task_id" "$child_tip" > "$task_dir/report.md"
  printf '%s\n' "$child_tip" > "$task_dir/verification.sha"
  printf '%s\n' "$parent_tip" > "$CONTROL/tasks/$task_id/parent-verification.sha"
  "$INTEGRATE" --control-dir "$CONTROL" --task-dir "$task_dir" \
    --mission mission --task-id "$task_id" --parent-worktree "$PARENT" \
    --expected-parent-tip "$parent_tip" >/dev/null || return 1
  "$GC" --hub "$HUB" --clean >/dev/null || return 1
  [[ "$(cat "$CONTROL/tasks/$task_id/state")" = collected && ! -e "$child" ]] || return 1
  if ! archive_child_thread "$CONTROL/tasks/$task_id" "thread-$task_id" "$archive_fail"; then
    [[ "$archive_fail" = 1 ]] || return 1
  fi
}

run_child_generation task-b >/dev/null 2>&1
PREMATURE_TASK_B_RC=$?
check "dependent child is refused before its predecessor is integrated" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" && ! -e "$3/tasks/task-b" ]] && ! git -C "$4" show-ref --verify --quiet refs/heads/orc-task/mission/task-b' \
  _ "$PREMATURE_TASK_B_RC" "$TMP/task-b-worktree" "$CONTROL" "$REPO"

run_child_generation task-a 1
TASK_A_FIRST_RC=$?
TASK_A_FIRST_MERGE="$(cat "$CONTROL/tasks/task-a/integrated_sha" 2>/dev/null || true)"
check "ready child completes, immutably integrates, and exactly collects Git resources" bash -c \
  '[[ "$1" -eq 0 && -n "$2" && "$(git -C "$3" rev-list --parents -n 1 "$2" | awk "{print NF}")" -eq 3 && "$(cat "$4/state")" = cleanup_pending && "$(cat "$4/task-window-state")" = unarchived && -f "$4/task-window-archive-pending" ]]' \
  _ "$TASK_A_FIRST_RC" "$TASK_A_FIRST_MERGE" "$REPO" "$CONTROL/tasks/task-a"

# Archive API failure is a post-GC cleanup overlay and cannot resurrect or delete resources.
"$GC" --hub "$HUB" --clean >/dev/null 2>&1
ARCHIVE_PENDING_RC=$?
check "task-window archive failure remains retriable after child resource GC" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = cleanup_pending && -f "$2/task-window-archive-pending" && ! -e "$3" ]]' \
  _ "$ARCHIVE_PENDING_RC" "$CONTROL/tasks/task-a" "$TMP/task-a-worktree"
run_child_generation task-b >/dev/null 2>&1
CLEANUP_PENDING_TASK_B_RC=$?
check "cleanup_pending predecessor is not dependency-ready" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" && ! -e "$3/tasks/task-b" ]] && ! git -C "$4" show-ref --verify --quiet refs/heads/orc-task/mission/task-b' \
  _ "$CLEANUP_PENDING_TASK_B_RC" "$TMP/task-b-worktree" "$CONTROL" "$REPO"
archive_child_thread "$CONTROL/tasks/task-a" thread-task-a 0
check "task-window archive retry records the exact accepted task as archived" bash -c \
  '[[ "$(cat "$1/state")" = collected && "$(cat "$1/task-window-state")" = archived && ! -e "$1/task-window-archive-pending" ]]' \
  _ "$CONTROL/tasks/task-a"

# A task-scoped review finding reuses the exact accepted thread and advances generation.
unarchive_child_thread "$CONTROL/tasks/task-a" thread-task-a
printf 'review correction base\n' > "$PARENT/review-base.txt"
git -C "$PARENT" add review-base.txt
git -C "$PARENT" commit -qm review-base
REWORK_BASE="$(git -C "$PARENT" rev-parse HEAD)"
"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TMP/task-a" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$TMP/task-a-worktree" \
  --expected-generation 1 >/dev/null
printf 'task-a rework\n' > "$TMP/task-a-worktree/task-a-rework.txt"
git -C "$TMP/task-a-worktree" add task-a-rework.txt
git -C "$TMP/task-a-worktree" commit -qm task-a-rework
REWORK_TIP="$(git -C "$TMP/task-a-worktree" rev-parse HEAD)"
printf 'completed\n' > "$TMP/task-a/state"
printf 'task-a rework verified\n' > "$TMP/task-a/report.md"
printf '%s\n' "$REWORK_TIP" > "$TMP/task-a/verification.sha"
printf '%s\n' "$REWORK_BASE" > "$CONTROL/tasks/task-a/parent-verification.sha"
"$INTEGRATE" --control-dir "$CONTROL" --task-dir "$TMP/task-a" \
  --mission mission --task-id task-a --parent-worktree "$PARENT" \
  --expected-parent-tip "$REWORK_BASE" >/dev/null
"$GC" --hub "$HUB" --clean >/dev/null
archive_child_thread "$CONTROL/tasks/task-a" thread-task-a 0
check "child-targeted rework unarchives, reprovisions, reintegrates, and rearchives the same thread" bash -c \
  '[[ "$(cat "$1/generation")" = 2 && "$(cat "$1/state")" = collected && "$(cat "$1/accepted-thread-id")" = thread-task-a && "$(cat "$1/task-window-state")" = archived && ! -e "$2" ]]' \
  _ "$CONTROL/tasks/task-a" "$TMP/task-a-worktree"

run_child_generation task-b
TASK_B_RC=$?
check "dependent child becomes runnable only after predecessor integration" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = collected && "$(cat "$3/state")" = collected ]]' \
  _ "$TASK_B_RC" "$CONTROL/tasks/task-a" "$CONTROL/tasks/task-b"

# Dirty child work is never integrated. This fixture is removed before parent-GC eligibility.
DIRTY_DIR="$TMP/dirty-task"
DIRTY_CHILD="$TMP/dirty-worktree"
DIRTY_PARENT_TIP="$(git -C "$PARENT" rev-parse HEAD)"
"$LIFECYCLE" create --create-mode native-0.4 --mission-dir "$MISSION" \
  --control-dir "$CONTROL" --task-dir "$DIRTY_DIR" \
  --mission mission --task-id dirty --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$DIRTY_CHILD" >/dev/null
printf 'committed\n' > "$DIRTY_CHILD/dirty.txt"
git -C "$DIRTY_CHILD" add dirty.txt
git -C "$DIRTY_CHILD" commit -qm dirty-fixture-base
DIRTY_TIP="$(git -C "$DIRTY_CHILD" rev-parse HEAD)"
printf 'completed\n' > "$DIRTY_DIR/state"
printf 'dirty fixture\n' > "$DIRTY_DIR/report.md"
printf '%s\n' "$DIRTY_TIP" > "$DIRTY_DIR/verification.sha"
printf '%s\n' "$DIRTY_PARENT_TIP" > "$CONTROL/tasks/dirty/parent-verification.sha"
printf 'uncommitted\n' >> "$DIRTY_CHILD/dirty.txt"
"$INTEGRATE" --control-dir "$CONTROL" --task-dir "$DIRTY_DIR" \
  --mission mission --task-id dirty --parent-worktree "$PARENT" \
  --expected-parent-tip "$DIRTY_PARENT_TIP" >/dev/null 2>&1
DIRTY_RC=$?
check "dirty child worktree fails closed before immutable integration" bash -c \
  '[[ "$1" -ne 0 && -n "$(git -C "$2" status --porcelain --untracked-files=all)" && "$(git -C "$3" rev-parse HEAD)" = "$4" ]]' \
  _ "$DIRTY_RC" "$DIRTY_CHILD" "$PARENT" "$DIRTY_PARENT_TIP"
git -C "$DIRTY_CHILD" reset -q --hard HEAD
git -C "$REPO" worktree remove "$DIRTY_CHILD"
git -C "$REPO" update-ref -d refs/heads/orc-task/mission/dirty
rm -rf -- "$DIRTY_DIR" "$CONTROL/tasks/dirty"

# Final review resolves before target merge; parent GC proves target containment itself.
PARENT_TIP="$(git -C "$PARENT" rev-parse HEAD)"
git -C "$PARENT" push -q -u origin orc/mission
printf 'accepted\n' > "$MISSION/state"
record_final_review "$CONTROL" pending >/dev/null 2>&1
PENDING_REVIEW_RC=$?
check "unresolved final review cannot publish merge authority" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2/review-resolution" ]]' \
  _ "$PENDING_REVIEW_RC" "$CONTROL"
record_final_review "$CONTROL" resolved
printf 'ready\n' > "$CONTROL/parent-cleanup-state"
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$(cd "$PARENT" && pwd -P)" orc/mission "$PARENT_TIP" \
  "$(cd "$REPO" && pwd -P)" main > "$CONTROL/parent-cleanup-manifest.txt"
printf 'design\n' > "$MISSION/design.md"
printf 'plan\n' > "$MISSION/plan.md"
printf 'report\n## Code review\nresolved\n## Verification\nverified\n' > "$MISSION/report.md"
printf 'decisions\n' > "$CONTROL/decisions.md"
printf 'verification\n' > "$CONTROL/verification.md"

"$GC" --hub "$HUB" --clean >/dev/null 2>&1
UNMERGED_RC=$?
check "unmerged parent tip is preserved even after resolved final review" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && "$(cat "$3/parent-cleanup-state")" = cleanup_pending ]] && git -C "$4" show-ref --verify --quiet refs/heads/orc/mission' \
  _ "$UNMERGED_RC" "$PARENT" "$CONTROL" "$REPO"

git -C "$REPO" merge -q --no-ff --no-edit "$PARENT_TIP"
REAL_GIT="$(command -v git)"
NETWORK_BIN="$TMP/network-bin"
mkdir -p "$NETWORK_BIN"
cat > "$NETWORK_BIN/git" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *" ls-remote "* ]]; then
  exit 1
fi
exec "$ORC_E2E_REAL_GIT" "$@"
SH
chmod +x "$NETWORK_BIN/git"
PATH="$NETWORK_BIN:$PATH" ORC_E2E_REAL_GIT="$REAL_GIT" \
  "$GC" --hub "$HUB" --clean >/dev/null 2>&1
NETWORK_RC=$?
check "parent network failure retains exact resources and cleanup authority" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && "$(cat "$3/parent-cleanup-state")" = cleanup_pending ]] && git --git-dir "$4" show-ref --verify --quiet refs/heads/orc/mission' \
  _ "$NETWORK_RC" "$PARENT" "$CONTROL" "$REMOTE"

"$GC" --hub "$HUB" --clean >/dev/null
PARENT_GC_RC=$?
"$GC" --hub "$HUB" --clean >/dev/null
PARENT_REPEAT_RC=$?
check "target merge enables exact parent GC and repeated cleanup is idempotent" bash -c \
  '[[ "$1" -eq 0 && "$2" -eq 0 && ! -e "$3" && "$(cat "$4/parent-cleanup-state")" = collected ]] && ! git -C "$5" show-ref --verify --quiet refs/heads/orc/mission && ! git --git-dir "$6" show-ref --verify --quiet refs/heads/orc/mission' \
  _ "$PARENT_GC_RC" "$PARENT_REPEAT_RC" "$PARENT" "$CONTROL" "$REPO" "$REMOTE"
check "parent GC archives final review and verification evidence" bash -c \
  '[[ -s "$1/design.md" && -s "$1/plan.md" && -s "$1/approved-task-dag.json" && -s "$1/report.md" && -s "$1/verification.md" && -s "$1/cleanup-journal.log" ]]' \
  _ "$HUB/archive/mission"

# API-only thread transitions stay contractually fail-closed at the coordinator boundary.
check "duplicate child owners are excluded from the ready set" contains "$SKILL" "no active or completed owner"
check "stale provisional IDs are removed or marked stale before one replacement" contains "$SKILL" "remove or mark stale any provisional"
check "a second unhealthy provisional thread becomes BLOCKED" contains "$SKILL" "If that one replacement also fails"
check "archive failures are retriable and preserve exact task identity" contains "$SKILL" "task-window archive failure"
check "task API fixture observed create, archive failure/retry, unarchive/rearchive, and final review" bash -c \
  '[[ "$(awk -F '\''\t'\'' '\''$1 == "create" {c++} $1 == "archive" {a++} $1 == "unarchive" {u++} $1 == "review" {r++} END {print c ":" a ":" u ":" r}'\'' "$1")" = 6:4:1:2 ]]' \
  _ "$TASK_API_LOG"

# Task 8 documentation is part of the release contract.
check "Codex manifest declares the 0.4.1 feature release" bash -c \
  '[[ "$(jq -r .version "$1")" = 0.4.1 ]]' _ "$CODEX_MANIFEST"
check "Claude manifest declares the same 0.4.1 feature release" bash -c \
  '[[ "$(jq -r .version "$1")" = 0.4.1 && "$(jq -r .version "$1")" = "$(jq -r .version "$2")" ]]' \
  _ "$CLAUDE_MANIFEST" "$CODEX_MANIFEST"
check "README labels the Orchestrator 0.4.1 feature release" contains "$README" "Orchestrator 0.4.1"
check "README documents the mission-internal DAG lifecycle" contains "$README" "Mission-internal task DAG and two-level GC"
check "README includes child and parent state diagrams" contains "$README" "stateDiagram-v2"
check "README documents migration from the single executor" contains "$README" "Migration from the single executor"
check "README documents failure-safe compatibility behavior" contains "$README" "Failure and retry behavior"

echo "  end-to-end-lifecycle: $OK/$N"
[[ "$OK" -eq "$N" ]]
