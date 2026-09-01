#!/usr/bin/env bash
# Task 8 end-to-end contract for the mission DAG, two-level GC, and rework loop.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="$ROOT/scripts/validate-task-dag.sh"
LIFECYCLE="$ROOT/scripts/task-worktree.sh"
HEALTH="$ROOT/scripts/native-task-health.py"
OUTCOME="$ROOT/scripts/task-outcome.py"
BROKER="$ROOT/scripts/commit-broker.sh"
INTEGRATE="$ROOT/scripts/integrate-task.sh"
GC="$ROOT/scripts/orchestrator-gc.sh"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
TASK_REF="$ROOT/skills/orchestrating/references/task-execution.md"
CLEANUP_REF="$ROOT/skills/orchestrating/references/cleanup-and-rework.md"
README="$ROOT/README.md"
CODEX_MANIFEST="$ROOT/.codex-plugin/plugin.json"
CLAUDE_MANIFEST="$ROOT/.claude-plugin/plugin.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/orc-e2e-test.XXXXXX")"
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

archive_child_thread() {
  local task_control="$1" thread_id="$2" fail="${3:-0}"
  [[ "$(cat "$task_control/accepted-thread-id" 2>/dev/null)" = "$thread_id" ]] || return 1
  if ! ORC_E2E_ARCHIVE_FAIL="$fail" task_api archive "$thread_id"; then
    : > "$task_control/task-window-archive-pending"
    printf 'cleanup_pending\n' > "$task_control/state"
    return 75
  fi
  rm -f "$task_control/task-window-archive-pending"
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
printf 'fable-opus\n' > "$MISSION/planning-backend"
printf 'fable-opus\n' > "$CONTROL/planning-backend"
printf 'session_id: fable-session\nbackend: claude-headless\nmodel: claude-fable-5\nstage: plan\n' > "$MISSION/session.txt"
printf 'fable-session\n' > "$CONTROL/planning-session-id"

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

chmod a-w "$CONTROL/approved.sha256" "$CONTROL/approved-design.md"

run_child_generation() {
  local task_id="$1"
  local task_dir="$TMP/$task_id"
  local child="$TMP/$task_id-worktree"
  local parent_tip child_tip generation nonce ready_input completed_input title
  parent_tip="$(git -C "$PARENT" rev-parse HEAD)"
  title="ORC mission · $task_id Native E2E"
  mkdir -p "$task_dir"
  git -C "$REPO" worktree add -q --detach "$child" "$parent_tip" || return 1
  "$HEALTH" begin --control-dir "$CONTROL" --task-dir "$task_dir" \
    --task-id "$task_id" --project-id project-e2e \
    --source-thread-id coordinator-e2e --title "$title" \
    --repo "$REPO" --schedule-base "$parent_tip" >/dev/null || return 1
  task_api create "thread-$task_id" list-visible || return 1
  "$HEALTH" observe --control-dir "$CONTROL" --task-id "$task_id" \
    --provisional-id "thread-$task_id" --thread-id "thread-$task_id" \
    --list-visible true --observed-title "$title" \
    --bootstrap-state completed --task-state idle --cwd "$child" --tip "$parent_tip" \
    --observed-project-id project-e2e \
    --observed-source-thread-id coordinator-e2e >/dev/null || return 1
  ORC_TASK_WORKTREE_TESTING=1 ORC_TASK_WORKTREE_TEST_FIXTURE_ROOT="$TMP" \
    "$LIFECYCLE" adopt --create-mode test-fixture --mission-dir "$MISSION" \
      --control-dir "$CONTROL" --task-dir "$task_dir" \
      --mission mission --task-id "$task_id" --repo "$REPO" \
      --parent-worktree "$PARENT" --worktree "$child" \
      --thread-id "thread-$task_id" >/dev/null || return 1
  printf 'running\n' > "$CONTROL/tasks/$task_id/state"
  printf 'running\n' > "$task_dir/state"
  printf '%s\n' "$task_id" > "$child/$task_id.txt"
  generation="$(cat "$CONTROL/tasks/$task_id/generation")"
  nonce="$(cat "$CONTROL/tasks/$task_id/outcome-nonce")"
  ready_input="$TMP/$task_id-ready.json"
  jq -nc --arg task_id "$task_id" --argjson generation "$generation" \
    --arg thread "thread-$task_id" --arg nonce "$nonce" \
    --arg base "$parent_tip" --arg head "$(git -C "$child" rev-parse HEAD)" \
    --arg file "$task_id.txt" --arg message "$task_id completion" \
    '{protocol_version:1,kind:"ready_for_commit",task_id:$task_id,
      generation:$generation,accepted_thread_id:$thread,outcome_nonce:$nonce,
      base_sha:$base,head_sha:$head,changed_files:[$file],
      commit_message:$message,
      verification:[{command:("test -f " + $file),exit_code:0,output:"passed"}],
      deviations:[],risks:[]}' > "$ready_input"
  "$OUTCOME" record --control-dir "$CONTROL" --task-dir "$task_dir" \
    --task-id "$task_id" --turn-id "turn-$task_id-ready" \
    --outcome-file "$ready_input" >/dev/null || return 1
  "$BROKER" --mission-dir "$task_dir" \
    --control-dir "$CONTROL/tasks/$task_id" --once >/dev/null || return 1
  child_tip="$(git -C "$child" rev-parse HEAD)"
  printf '%s\n' "$child_tip" > "$CONTROL/tasks/$task_id/coordinator-verification.sha"
  printf 'coordinator verified %s\n' "$child_tip" > "$CONTROL/tasks/$task_id/coordinator-verification.md"
  completed_input="$TMP/$task_id-completed.json"
  jq -nc --arg task_id "$task_id" --argjson generation "$generation" \
    --arg thread "thread-$task_id" --arg nonce "$nonce" \
    --arg base "$parent_tip" --arg commit "$child_tip" --arg file "$task_id.txt" \
    '{protocol_version:1,kind:"completed",task_id:$task_id,
      generation:$generation,accepted_thread_id:$thread,outcome_nonce:$nonce,
      base_sha:$base,commit_sha:$commit,changed_files:[$file],
      verification:[{command:("test -f " + $file),exit_code:0,output:"passed"}],
      deviations:[],risks:[]}' > "$completed_input"
  "$OUTCOME" record --control-dir "$CONTROL" --task-dir "$task_dir" \
    --task-id "$task_id" --turn-id "turn-$task_id-completed" \
    --outcome-file "$completed_input" >/dev/null || return 1
  printf '%s\n' "$parent_tip" > "$CONTROL/tasks/$task_id/parent-verification.sha"
  "$INTEGRATE" --control-dir "$CONTROL" --task-dir "$task_dir" \
    --mission mission --task-id "$task_id" --parent-worktree "$PARENT" \
    --expected-parent-tip "$parent_tip" >/dev/null || return 1
  [[ "$(cat "$CONTROL/tasks/$task_id/state")" = integrated && -d "$child" ]] || return 1
}

run_child_generation task-a
TASK_A_FIRST_RC=$?
TASK_A_FIRST_MERGE="$(cat "$CONTROL/tasks/task-a/integrated_sha" 2>/dev/null || true)"
check "ready child integrates while its window worktree and branch remain visible" bash -c \
  '[[ "$1" -eq 0 && -n "$2" && "$(git -C "$3" rev-list --parents -n 1 "$2" | awk "{print NF}")" -eq 3 && "$(cat "$4/state")" = integrated && "$(cat "$4/task-window-state")" = unarchived && -d "$5" ]] && git -C "$3" show-ref --verify --quiet refs/heads/orc-task/mission/task-a' \
  _ "$TASK_A_FIRST_RC" "$TASK_A_FIRST_MERGE" "$REPO" "$CONTROL/tasks/task-a" "$TMP/task-a-worktree"

"$GC" --hub "$HUB" --mission mission --clean >/dev/null 2>&1
EARLY_GC_RC=$?
check "batch GC refuses early collection while any approved task is unfinished" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/state")" = integrated && -d "$3" ]] && git -C "$4" show-ref --verify --quiet refs/heads/orc-task/mission/task-a' \
  _ "$EARLY_GC_RC" "$CONTROL/tasks/task-a" "$TMP/task-a-worktree" "$REPO"

run_child_generation task-b
TASK_B_RC=$?
check "dependent child runs after predecessor integration without predecessor GC" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = integrated && "$(cat "$3/state")" = integrated && -d "$4" && -d "$5" ]]' \
  _ "$TASK_B_RC" "$CONTROL/tasks/task-a" "$CONTROL/tasks/task-b" "$TMP/task-a-worktree" "$TMP/task-b-worktree"

printf 'executed\n' > "$MISSION/state"
"$GC" --hub "$HUB" --mission mission --clean >/dev/null 2>&1
PRE_REVIEW_GC_RC=$?
check "all integrated children remain visible through selected-backend review" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/state")" = integrated && "$(cat "$3/state")" = integrated && -d "$4" && -d "$5" ]]' \
  _ "$PRE_REVIEW_GC_RC" "$CONTROL/tasks/task-a" "$CONTROL/tasks/task-b" "$TMP/task-a-worktree" "$TMP/task-b-worktree"

record_final_review "$CONTROL" pending >/dev/null 2>&1
PENDING_REVIEW_RC=$?
check "unresolved final review cannot publish cleanup authority" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2/review-resolution" ]]' \
  _ "$PENDING_REVIEW_RC" "$CONTROL"
record_final_review "$CONTROL" resolved
printf 'accepted\n' > "$MISSION/state"

mkdir "$CONTROL/tasks/not-approved"
printf 'integrated\n' > "$CONTROL/tasks/not-approved/state"
"$GC" --hub "$HUB" --mission mission --clean >/dev/null 2>&1
UNAPPROVED_GC_RC=$?
check "batch GC refuses a task registry that differs from the approved DAG" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/state")" = integrated && "$(cat "$3/state")" = integrated && -d "$4" && -d "$5" ]]' \
  _ "$UNAPPROVED_GC_RC" "$CONTROL/tasks/task-a" "$CONTROL/tasks/task-b" "$TMP/task-a-worktree" "$TMP/task-b-worktree"
rm -f "$CONTROL/tasks/not-approved/state"
rmdir "$CONTROL/tasks/not-approved"

archive_child_thread "$CONTROL/tasks/task-a" thread-task-a 1 >/dev/null 2>&1
ARCHIVE_FAIL_RC=$?
archive_child_thread "$CONTROL/tasks/task-b" thread-task-b 0
"$GC" --hub "$HUB" --mission mission --clean >/dev/null 2>&1
PARTIAL_ARCHIVE_GC_RC=$?
check "batch archive failure is retriable and prevents any Git collection" bash -c \
  '[[ "$1" -ne 0 && "$2" -ne 0 && "$(cat "$3/state")" = cleanup_pending && -f "$3/task-window-archive-pending" && "$(cat "$4/task-window-state")" = archived && -d "$5" && -d "$6" ]]' \
  _ "$ARCHIVE_FAIL_RC" "$PARTIAL_ARCHIVE_GC_RC" "$CONTROL/tasks/task-a" "$CONTROL/tasks/task-b" "$TMP/task-a-worktree" "$TMP/task-b-worktree"
archive_child_thread "$CONTROL/tasks/task-a" thread-task-a 0
check "batch archive retry converges every exact accepted window" bash -c \
  '[[ "$(cat "$1/task-window-state")" = archived && "$(cat "$2/task-window-state")" = archived ]]' \
  _ "$CONTROL/tasks/task-a" "$CONTROL/tasks/task-b"

"$GC" --hub "$HUB" --mission mission --clean >/dev/null
BATCH_GC_RC=$?
check "one post-review batch collects every child only after every native window archives" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = collected && "$(cat "$3/state")" = collected && ! -e "$4" && ! -e "$5" ]]' \
  _ "$BATCH_GC_RC" "$CONTROL/tasks/task-a" "$CONTROL/tasks/task-b" "$TMP/task-a-worktree" "$TMP/task-b-worktree"

# Dirty child work is never integrated. This fixture is removed before parent-GC eligibility.
DIRTY_DIR="$TMP/dirty-task"
DIRTY_CHILD="$TMP/dirty-worktree"
DIRTY_PARENT_TIP="$(git -C "$PARENT" rev-parse HEAD)"
ORC_TASK_WORKTREE_TESTING=1 ORC_TASK_WORKTREE_TEST_FIXTURE_ROOT="$TMP" \
"$LIFECYCLE" create --create-mode test-fixture --mission-dir "$MISSION" \
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
printf '%s\n' "$DIRTY_TIP" > "$CONTROL/tasks/dirty/coordinator-verification.sha"
printf 'coordinator verified %s\n' "$DIRTY_TIP" > "$CONTROL/tasks/dirty/coordinator-verification.md"
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
printf 'ready\n' > "$CONTROL/parent-cleanup-state"
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$(cd "$PARENT" && pwd -P)" orc/mission "$PARENT_TIP" \
  "$(cd "$REPO" && pwd -P)" main > "$CONTROL/parent-cleanup-manifest.txt"
printf 'design\n' > "$MISSION/design.md"
printf 'plan\n' > "$MISSION/plan.md"
printf '<html>plan review</html>\n' > "$MISSION/plan-review.html"
printf '<html>status truth</html>\n' > "$MISSION/status-truth.html"
printf 'report\n## Code review\nresolved\n## Verification\nverified\n' > "$MISSION/report.md"
printf 'decisions\n' > "$CONTROL/decisions.md"
printf 'verification\n' > "$CONTROL/verification.md"
printf '{"version":1,"site_url":"https://example.openai.site/mission"}\n' > "$CONTROL/sites-delivery.json"

"$GC" --hub "$HUB" --mission mission --clean >/dev/null 2>&1
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
  "$GC" --hub "$HUB" --mission mission --clean >/dev/null 2>&1
NETWORK_RC=$?
check "parent network failure retains exact resources and cleanup authority" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && "$(cat "$3/parent-cleanup-state")" = cleanup_pending ]] && git --git-dir "$4" show-ref --verify --quiet refs/heads/orc/mission' \
  _ "$NETWORK_RC" "$PARENT" "$CONTROL" "$REMOTE"

"$GC" --hub "$HUB" --mission mission --clean >/dev/null
PARENT_GC_RC=$?
"$GC" --hub "$HUB" --mission mission --clean >/dev/null
PARENT_REPEAT_RC=$?
check "target merge enables exact parent GC and repeated cleanup is idempotent" bash -c \
  '[[ "$1" -eq 0 && "$2" -eq 0 && ! -e "$3" && "$(cat "$4/parent-cleanup-state")" = collected ]] && ! git -C "$5" show-ref --verify --quiet refs/heads/orc/mission && ! git --git-dir "$6" show-ref --verify --quiet refs/heads/orc/mission' \
  _ "$PARENT_GC_RC" "$PARENT_REPEAT_RC" "$PARENT" "$CONTROL" "$REPO" "$REMOTE"
check "parent GC archives final review and verification evidence" bash -c \
  '[[ -s "$1/design.md" && -s "$1/plan.md" && -s "$1/plan-review.html" && -s "$1/status-truth.html" && -s "$1/sites-delivery.json" && -s "$1/approved-task-dag.json" && -s "$1/report.md" && -s "$1/verification.md" && -s "$1/cleanup-journal.log" ]]' \
  _ "$HUB/archive/mission"

# API-only thread transitions stay contractually fail-closed at the coordinator boundary.
check "duplicate child owners are excluded from the ready set" contains "$TASK_REF" "accepted owner or approval blocker"
check "stale provisional IDs are stopped before one replacement" contains "$TASK_REF" "genuine native launch or identity health failure"
check "a second unhealthy provisional thread becomes BLOCKED" contains "$TASK_REF" "genuine native health failure is BLOCKED"
check "archive failures are retriable and preserve exact task identity" contains "$CLEANUP_REF" "task-window archive failure"
check "task API fixture observed native create, archive failure/retry, and final review" bash -c \
  '[[ "$(awk -F '\''\t'\'' '\''$1 == "create" {c++} $1 == "archive" {a++} $1 == "unarchive" {u++} $1 == "review" {r++} END {print c ":" a ":" u ":" r}'\'' "$1")" = 2:3::2 ]]' \
  _ "$TASK_API_LOG"

# Task 8 documentation is part of the release contract.
check "Codex manifest declares the 0.5.4 native-only release" bash -c \
  '[[ "$(jq -r .version "$1")" =~ ^0\.5\.4\+codex\.[A-Za-z0-9._-]+$ ]]' _ "$CODEX_MANIFEST"
check "Claude manifest declares the same 0.5.4 release" bash -c \
  'codex="$(jq -r .version "$2")"; [[ "$(jq -r .version "$1")" = 0.5.4 && "${codex%%+*}" = 0.5.4 ]]' \
  _ "$CLAUDE_MANIFEST" "$CODEX_MANIFEST"
check "README labels the Orchestrator 0.5.4 release" contains "$README" "Orchestrator 0.5.4"
check "README documents the native DAG lifecycle" contains "$README" "Visible Codex DAG execution"
check "README documents progressive disclosure" contains "$README" "Progressive disclosure"
check "README documents native-only authority" contains "$README" "supports only native mission-schema authority"
check "README documents mission-scoped GC" contains "$README" "--mission <mission> --clean"

echo "  end-to-end-lifecycle: $OK/$N"
[[ "$OK" -eq "$N" ]]
