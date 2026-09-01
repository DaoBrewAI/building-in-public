#!/usr/bin/env bash
# Coordinator-owned import of Codex-Ultra planning artifacts from its native worktree.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMPORTER="$ROOT/scripts/planning-output.py"
LIFECYCLE_LOCK="$ROOT/scripts/coordinator_lifecycle_lock.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/orc-planning-output.XXXXXX")"
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

check "coordinator planning-output importer is installed" test -x "$IMPORTER"
check "planning begin and import use the shared coordinator lifecycle lock" \
  grep -Fq 'acquire_lifecycle_lock' "$IMPORTER"
check "shared coordinator lifecycle lock helper is installed" test -x "$LIFECYCLE_LOCK"
if [[ ! -x "$IMPORTER" ]]; then
  echo "  planning-output-contract: $OK/$N"
  exit 1
fi

setup_case() {
  local root="$1"
  REPO="$root/repo"
  WORKTREE="$root/planning-worktree"
  MISSION="$root/hub/missions/mission"
  CONTROL="$root/hub/control/mission"
  THREAD_ID="planning-thread-1"
  mkdir -p "$REPO" "$MISSION" "$CONTROL"
  git init -q "$REPO"
  git -C "$REPO" config user.email planning-output@example.invalid
  git -C "$REPO" config user.name planning-output
  git -C "$REPO" config commit.gpgsign false
  printf 'product baseline\n' > "$REPO/product.txt"
  git -C "$REPO" add product.txt
  git -C "$REPO" commit -qm baseline
  TIP="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" worktree add -q --detach "$WORKTREE" "$TIP"
  WORKTREE="$(cd "$WORKTREE" && pwd -P)"
  STAGING="$WORKTREE/.orchestrator-planning-output"
  printf '%s\n' "$THREAD_ID" > "$CONTROL/planning-thread-id"
  printf 'codex-ultra\n' > "$CONTROL/planning-backend"
  printf 'running\n' > "$MISSION/state"
  STAGE_NONCE=""
}

begin_stage() {
  local stage="$1" expected_state="${2:-$(cat "$MISSION/state")}" output
  output="$(python3 "$IMPORTER" begin \
    --mission-dir "$MISSION" --control-dir "$CONTROL" \
    --worktree "$WORKTREE" --expected-tip "$TIP" --stage "$stage" \
    --expected-state "$expected_state")" || return 1
  STAGE_NONCE="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["stage_nonce"])' <<< "$output")"
  [[ "$STAGE_NONCE" =~ ^[0-9a-f]{64}$ ]]
}

artifact_contents() {
  case "$1" in
    design.md) printf '# Imported design\n' ;;
    plan.md) printf '# Imported plan\n' ;;
    plan-review.html) printf '<!doctype html><title>Imported plan</title>\n' ;;
    task-dag.json) printf '{"mission":"mission","tasks":[],"version":1}\n' ;;
    report.md) printf '# Imported review\n\nVerdict: clean\n' ;;
    BLOCKED-1.md) printf 'kind: brainstorm-clarification\nQuestion: Which contract?\nRecommendation: A\n' ;;
    *) return 1 ;;
  esac
}

write_output() {
  local stage="$1" kind="$2"
  shift 2
  local artifact
  mkdir -p "$STAGING"
  for artifact in "$@"; do
    artifact_contents "$artifact" > "$STAGING/$artifact" || return 1
  done
  python3 - "$STAGING/manifest.json" "$stage" "$kind" "$THREAD_ID" \
    "$WORKTREE" "$TIP" "$STAGE_NONCE" "$@" <<'PY'
import json
import sys

path, stage, kind, thread, worktree, tip, stage_nonce, *artifacts = sys.argv[1:]
payload = {
    "protocol_version": 1,
    "stage": stage,
    "kind": kind,
    "accepted_thread_id": thread,
    "worktree": worktree,
    "tip": tip,
    "stage_nonce": stage_nonce,
    "artifacts": artifacts,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
}

import_output() {
  local stage="$1"
  python3 "$IMPORTER" import \
    --mission-dir "$MISSION" --control-dir "$CONTROL" \
    --worktree "$WORKTREE" --expected-tip "$TIP" --stage "$stage"
}

PLAN="$TMP/plan"
setup_case "$PLAN"
begin_stage plan running
write_output plan planned design.md plan.md plan-review.html task-dag.json
PLAN_BEFORE_PRODUCT="$(cat "$WORKTREE/product.txt")"
import_output plan > "$PLAN/import.out" 2> "$PLAN/import.err"
PLAN_RC=$?
check "plan stage imports its exact artifact set and derived state" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = planned ]] &&
   grep -Fq "Imported design" "$2/design.md" &&
   grep -Fq "Imported plan" "$2/plan.md" &&
   grep -Fq "Imported plan" "$2/plan-review.html" &&
   grep -Fq "\"mission\":\"mission\"" "$2/task-dag.json"' \
  _ "$PLAN_RC" "$MISSION"
check "successful plan import removes staging without product drift" bash -c \
  '[[ ! -e "$1" && "$(git -C "$2" rev-parse HEAD)" = "$3" &&
     -z "$(git -C "$2" status --porcelain --untracked-files=all)" &&
     "$(cat "$2/product.txt")" = "$4" ]]' \
  _ "$STAGING" "$WORKTREE" "$TIP" "$PLAN_BEFORE_PRODUCT"
check "successful plan import consumes authority and leaves a durable receipt" bash -c \
  '[[ ! -e "$1/planning-stage-authority.json" &&
     ! -e "$1/planning-stage-import-intent.json" &&
     -s "$1/planning-stage-receipt-$2.json" ]]' \
  _ "$CONTROL" "$STAGE_NONCE"
check "Codex planning flow creates no external writable-root receipt" bash -c \
  '[[ ! -e "$1/planning-writable-root-receipt" &&
     ! -e "$2/planning-writable-root-receipt" &&
     ! -e "$3/planning-writable-root-receipt" ]]' \
  _ "$MISSION" "$CONTROL" "$WORKTREE"

REVIEW="$TMP/review"
setup_case "$REVIEW"
begin_stage review running
write_output review review report.md
import_output review > "$REVIEW/import.out" 2> "$REVIEW/import.err"
REVIEW_RC=$?
check "review stage imports only report and derived review state" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = review && ! -e "$2/design.md" &&
     ! -e "$3" ]] && grep -Fq "Verdict: clean" "$2/report.md"' \
  _ "$REVIEW_RC" "$MISSION" "$STAGING"

BLOCKED="$TMP/blocked"
setup_case "$BLOCKED"
begin_stage plan running
write_output plan blocked BLOCKED-1.md
import_output plan > "$BLOCKED/import.out" 2> "$BLOCKED/import.err"
BLOCKED_RC=$?
check "blocked planning output imports only BLOCKED evidence and derived state" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = blocked && ! -e "$2/design.md" &&
     ! -e "$3" ]] && grep -Fq "Which contract?" "$2/BLOCKED-1.md"' \
  _ "$BLOCKED_RC" "$MISSION" "$STAGING"

SCHEMA="$TMP/schema"
setup_case "$SCHEMA"
begin_stage plan running
write_output plan planned design.md plan.md plan-review.html task-dag.json
python3 - "$STAGING/manifest.json" <<'PY'
import json
import sys
path = sys.argv[1]
payload = json.load(open(path, encoding="utf-8"))
payload["unexpected"] = True
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
import_output plan > "$SCHEMA/import.out" 2> "$SCHEMA/import.err"
SCHEMA_RC=$?
check "extra manifest schema field is rejected without consuming staging" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && ! -e "$3/design.md" && "$(cat "$3/state")" = running ]]' \
  _ "$SCHEMA_RC" "$STAGING" "$MISSION"

STAGE_MISMATCH="$TMP/stage-mismatch"
setup_case "$STAGE_MISMATCH"
begin_stage plan running
write_output plan planned design.md plan.md plan-review.html task-dag.json
import_output review > "$STAGE_MISMATCH/import.out" 2> "$STAGE_MISMATCH/import.err"
STAGE_MISMATCH_RC=$?
check "requested stage must exactly match the canonical manifest" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && ! -e "$3/design.md" ]]' \
  _ "$STAGE_MISMATCH_RC" "$STAGING" "$MISSION"

WORKTREE_MISMATCH="$TMP/worktree-mismatch"
setup_case "$WORKTREE_MISMATCH"
begin_stage plan running
write_output plan planned design.md plan.md plan-review.html task-dag.json
python3 - "$STAGING/manifest.json" <<'PY'
import json
import sys
path = sys.argv[1]
payload = json.load(open(path, encoding="utf-8"))
payload["worktree"] = payload["worktree"] + "-redirected"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
import_output plan > "$WORKTREE_MISMATCH/import.out" 2> "$WORKTREE_MISMATCH/import.err"
WORKTREE_MISMATCH_RC=$?
check "manifest worktree identity cannot redirect import" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && ! -e "$3/design.md" ]]' \
  _ "$WORKTREE_MISMATCH_RC" "$STAGING" "$MISSION"

TIP_MISMATCH="$TMP/tip-mismatch"
setup_case "$TIP_MISMATCH"
begin_stage plan running
write_output plan planned design.md plan.md plan-review.html task-dag.json
python3 - "$STAGING/manifest.json" <<'PY'
import json
import sys
path = sys.argv[1]
payload = json.load(open(path, encoding="utf-8"))
payload["tip"] = "0" * 40
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
import_output plan > "$TIP_MISMATCH/import.out" 2> "$TIP_MISMATCH/import.err"
TIP_MISMATCH_RC=$?
check "manifest and live worktree must remain at the exact expected tip" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && ! -e "$3/design.md" ]]' \
  _ "$TIP_MISMATCH_RC" "$STAGING" "$MISSION"

LIVE_TIP="$TMP/live-tip"
setup_case "$LIVE_TIP"
begin_stage plan running
write_output plan planned design.md plan.md plan-review.html task-dag.json
printf 'later product commit\n' > "$REPO/later.txt"
git -C "$REPO" add later.txt
git -C "$REPO" commit -qm later
LATER_TIP="$(git -C "$REPO" rev-parse HEAD)"
git -C "$WORKTREE" reset -q --hard "$LATER_TIP"
import_output plan > "$LIVE_TIP/import.out" 2> "$LIVE_TIP/import.err"
LIVE_TIP_RC=$?
check "clean live planning worktree at a different tip is rejected" bash -c \
  '[[ "$1" -ne 0 && "$(git -C "$2" rev-parse HEAD)" = "$3" && "$3" != "$4" &&
     -d "$5" && ! -e "$6/design.md" ]]' \
  _ "$LIVE_TIP_RC" "$WORKTREE" "$LATER_TIP" "$TIP" "$STAGING" "$MISSION"

TRACKED="$TMP/tracked-drift"
setup_case "$TRACKED"
begin_stage plan running
write_output plan planned design.md plan.md plan-review.html task-dag.json
printf 'tracked drift\n' > "$WORKTREE/product.txt"
import_output plan > "$TRACKED/import.out" 2> "$TRACKED/import.err"
TRACKED_RC=$?
check "tracked product drift rejects the complete planning output" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && ! -e "$3/design.md" &&
     -n "$(git -C "$4" status --porcelain --untracked-files=all -- product.txt)" ]]' \
  _ "$TRACKED_RC" "$STAGING" "$MISSION" "$WORKTREE"

UNTRACKED="$TMP/untracked-drift"
setup_case "$UNTRACKED"
begin_stage plan running
write_output plan planned design.md plan.md plan-review.html task-dag.json
printf 'outside staging\n' > "$WORKTREE/rogue.txt"
import_output plan > "$UNTRACKED/import.out" 2> "$UNTRACKED/import.err"
UNTRACKED_RC=$?
check "untracked files outside exact staging reject import" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && ! -e "$3/design.md" && -f "$4/rogue.txt" ]]' \
  _ "$UNTRACKED_RC" "$STAGING" "$MISSION" "$WORKTREE"

SYMLINK="$TMP/symlink"
setup_case "$SYMLINK"
begin_stage plan running
write_output plan planned design.md plan.md plan-review.html task-dag.json
printf 'outside\n' > "$SYMLINK/outside-plan.md"
rm -f "$STAGING/plan.md"
ln -s "$SYMLINK/outside-plan.md" "$STAGING/plan.md"
import_output plan > "$SYMLINK/import.out" 2> "$SYMLINK/import.err"
SYMLINK_RC=$?
check "symlinked planning artifact is rejected without external read or import" bash -c \
  '[[ "$1" -ne 0 && -L "$2/plan.md" && ! -e "$3/plan.md" ]]' \
  _ "$SYMLINK_RC" "$STAGING" "$MISSION"

STAGING_SYMLINK="$TMP/staging-symlink"
setup_case "$STAGING_SYMLINK"
begin_stage review running
write_output review review report.md
mv "$STAGING" "$STAGING_SYMLINK/redirected-output"
ln -s "$STAGING_SYMLINK/redirected-output" "$STAGING"
import_output review > "$STAGING_SYMLINK/import.out" 2> "$STAGING_SYMLINK/import.err"
STAGING_SYMLINK_RC=$?
check "symlinked exact staging directory is rejected without import" bash -c \
  '[[ "$1" -ne 0 && -L "$2" && ! -e "$3/report.md" ]]' \
  _ "$STAGING_SYMLINK_RC" "$STAGING" "$MISSION"

EXTRA="$TMP/extra"
setup_case "$EXTRA"
begin_stage review running
write_output review review report.md
printf 'not declared\n' > "$STAGING/extra.txt"
import_output review > "$EXTRA/import.out" 2> "$EXTRA/import.err"
EXTRA_RC=$?
check "extra staging output is rejected without partial import" bash -c \
  '[[ "$1" -ne 0 && -f "$2/extra.txt" && ! -e "$3/report.md" ]]' \
  _ "$EXTRA_RC" "$STAGING" "$MISSION"

ATOMIC="$TMP/atomic"
setup_case "$ATOMIC"
printf 'old design\n' > "$MISSION/design.md"
printf 'old plan\n' > "$MISSION/plan.md"
printf 'old html\n' > "$MISSION/plan-review.html"
printf 'old dag\n' > "$MISSION/task-dag.json"
begin_stage plan running
write_output plan planned design.md plan.md plan-review.html task-dag.json
ORC_PLANNING_OUTPUT_TEST_FAIL_PUBLISH_AFTER=2 import_output plan \
  > "$ATOMIC/import.out" 2> "$ATOMIC/import.err"
ATOMIC_RC=$?
check "interrupted batch import restores every prior mission artifact and state" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/design.md")" = "old design" &&
     "$(cat "$2/plan.md")" = "old plan" &&
     "$(cat "$2/plan-review.html")" = "old html" &&
     "$(cat "$2/task-dag.json")" = "old dag" &&
     "$(cat "$2/state")" = running && -d "$3" ]]' \
  _ "$ATOMIC_RC" "$MISSION" "$STAGING"

EXPECTED_STATE="$TMP/expected-state"
setup_case "$EXPECTED_STATE"
python3 "$IMPORTER" begin \
  --mission-dir "$MISSION" --control-dir "$CONTROL" \
  --worktree "$WORKTREE" --expected-tip "$TIP" --stage plan \
  --expected-state pending > "$EXPECTED_STATE/begin.out" 2> "$EXPECTED_STATE/begin.err"
EXPECTED_STATE_RC=$?
check "begin binds an explicit current mission state and rejects stale coordinator intent" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2/planning-stage-authority.json" &&
     "$(cat "$3/state")" = running ]]' \
  _ "$EXPECTED_STATE_RC" "$CONTROL" "$MISSION"

STATE_MOVED="$TMP/state-moved"
setup_case "$STATE_MOVED"
begin_stage plan running
write_output plan planned design.md plan.md plan-review.html task-dag.json
printf 'planned\n' > "$MISSION/state"
import_output plan > "$STATE_MOVED/import.out" 2> "$STATE_MOVED/import.err"
STATE_MOVED_RC=$?
check "import rejects a mission state that moved after stage authority was published" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && ! -e "$3/design.md" &&
     "$(cat "$3/state")" = planned ]]' \
  _ "$STATE_MOVED_RC" "$STAGING" "$MISSION"

STALE_PLAN="$TMP/stale-plan"
setup_case "$STALE_PLAN"
begin_stage plan running
OLD_PLAN_NONCE="$STAGE_NONCE"
write_output plan planned design.md plan.md plan-review.html task-dag.json
import_output plan >/dev/null 2>&1
begin_stage plan planned
NEW_PLAN_NONCE="$STAGE_NONCE"
STAGE_NONCE="$OLD_PLAN_NONCE"
write_output plan planned design.md plan.md plan-review.html task-dag.json
import_output plan > "$STALE_PLAN/import.out" 2> "$STALE_PLAN/import.err"
STALE_PLAN_RC=$?
check "a delayed plan result cannot satisfy a newer plan round" bash -c \
  '[[ "$1" -ne 0 && "$2" != "$3" && -d "$4" &&
     "$(cat "$5/planning-stage-authority.json")" == *"$3"* ]]' \
  _ "$STALE_PLAN_RC" "$OLD_PLAN_NONCE" "$NEW_PLAN_NONCE" "$STAGING" "$CONTROL"

STALE_REVIEW="$TMP/stale-review"
setup_case "$STALE_REVIEW"
begin_stage review running
OLD_REVIEW_NONCE="$STAGE_NONCE"
write_output review rework report.md
import_output review >/dev/null 2>&1
printf 'running\n' > "$MISSION/state"
begin_stage review running
NEW_REVIEW_NONCE="$STAGE_NONCE"
STAGE_NONCE="$OLD_REVIEW_NONCE"
write_output review review report.md
import_output review > "$STALE_REVIEW/import.out" 2> "$STALE_REVIEW/import.err"
STALE_REVIEW_RC=$?
check "a delayed review result cannot satisfy a newer review round" bash -c \
  '[[ "$1" -ne 0 && "$2" != "$3" && -d "$4" &&
     "$(cat "$5/state")" = running ]]' \
  _ "$STALE_REVIEW_RC" "$OLD_REVIEW_NONCE" "$NEW_REVIEW_NONCE" "$STAGING" "$MISSION"

POST_PUBLISH_RECOVERY="$TMP/post-publish-recovery"
setup_case "$POST_PUBLISH_RECOVERY"
begin_stage review running
POST_PUBLISH_NONCE="$STAGE_NONCE"
write_output review review report.md
ORC_PLANNING_OUTPUT_TEST_FAIL_AFTER_PUBLISH=1 import_output review \
  > "$POST_PUBLISH_RECOVERY/first.out" 2> "$POST_PUBLISH_RECOVERY/first.err"
POST_PUBLISH_FIRST_RC=$?
check "post-publication interruption retains the exact staged result and import intent" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/state")" = review && -d "$3" &&
     -s "$4/planning-stage-import-intent.json" &&
     ! -e "$4/planning-stage-receipt-$5.json" ]]' \
  _ "$POST_PUBLISH_FIRST_RC" "$MISSION" "$STAGING" "$CONTROL" "$POST_PUBLISH_NONCE"
import_output review > "$POST_PUBLISH_RECOVERY/retry.out" 2> "$POST_PUBLISH_RECOVERY/retry.err"
POST_PUBLISH_RETRY_RC=$?
check "retry finalizes an already-published result without duplicate publication" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = review && ! -e "$3" &&
     ! -e "$4/planning-stage-authority.json" &&
     ! -e "$4/planning-stage-import-intent.json" &&
     -s "$4/planning-stage-receipt-$5.json" ]] &&
   grep -Fq "Verdict: clean" "$2/report.md"' \
  _ "$POST_PUBLISH_RETRY_RC" "$MISSION" "$STAGING" "$CONTROL" "$POST_PUBLISH_NONCE"

CLEANUP_RECOVERY="$TMP/cleanup-recovery"
setup_case "$CLEANUP_RECOVERY"
begin_stage plan running
RECOVERY_NONCE="$STAGE_NONCE"
write_output plan planned design.md plan.md plan-review.html task-dag.json
ORC_PLANNING_OUTPUT_TEST_FAIL_CLEANUP_AFTER=1 import_output plan \
  > "$CLEANUP_RECOVERY/first.out" 2> "$CLEANUP_RECOVERY/first.err"
CLEANUP_FIRST_RC=$?
TOMBSTONE="$WORKTREE/.orchestrator-planning-output.consumed-$RECOVERY_NONCE"
check "cleanup interruption occurs only after the mission result and receipt are durable" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/state")" = planned && ! -e "$3" &&
     -d "$4" && -s "$5/planning-stage-receipt-$6.json" &&
     -s "$5/planning-stage-import-intent.json" ]]' \
  _ "$CLEANUP_FIRST_RC" "$MISSION" "$STAGING" "$TOMBSTONE" "$CONTROL" "$RECOVERY_NONCE"
import_output plan > "$CLEANUP_RECOVERY/retry.out" 2> "$CLEANUP_RECOVERY/retry.err"
CLEANUP_RETRY_RC=$?
check "retry converges after partial staging cleanup without republishing or losing output" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = planned &&
     ! -e "$3" && ! -e "$4" &&
     ! -e "$5/planning-stage-authority.json" &&
     ! -e "$5/planning-stage-import-intent.json" &&
     -s "$5/planning-stage-receipt-$6.json" ]] &&
   grep -Fq "Imported design" "$2/design.md"' \
  _ "$CLEANUP_RETRY_RC" "$MISSION" "$STAGING" "$TOMBSTONE" "$CONTROL" "$RECOVERY_NONCE"

CONCURRENT_IMPORT="$TMP/concurrent-import"
setup_case "$CONCURRENT_IMPORT"
begin_stage review running
CONCURRENT_NONCE="$STAGE_NONCE"
write_output review review report.md
CONCURRENT_HOOK="$CONCURRENT_IMPORT/lifecycle-hook"
mkdir -p "$CONCURRENT_HOOK"
ORC_COORDINATOR_LIFECYCLE_TEST_HOOK_DIR="$CONCURRENT_HOOK" \
  ORC_COORDINATOR_LIFECYCLE_TEST_PARTICIPANT=planning-first \
  import_output review > "$CONCURRENT_IMPORT/first.out" \
    2> "$CONCURRENT_IMPORT/first.err" &
CONCURRENT_FIRST_PID=$!
CONCURRENT_ATTEMPTS=0
while [[ ! -e "$CONCURRENT_HOOK/entered-planning-first" && \
         "$CONCURRENT_ATTEMPTS" -lt 200 ]]; do
  CONCURRENT_ATTEMPTS=$((CONCURRENT_ATTEMPTS + 1))
  sleep 0.01
done
CONCURRENT_ENTERED=0
CONCURRENT_SECOND_WAITED=0
CONCURRENT_FIRST_RC=127
CONCURRENT_SECOND_RC=127
if [[ -e "$CONCURRENT_HOOK/entered-planning-first" ]]; then
  CONCURRENT_ENTERED=1
  import_output review > "$CONCURRENT_IMPORT/second.out" \
    2> "$CONCURRENT_IMPORT/second.err" &
  CONCURRENT_SECOND_PID=$!
  sleep 0.2
  if kill -0 "$CONCURRENT_SECOND_PID" 2>/dev/null; then
    CONCURRENT_SECOND_WAITED=1
  fi
  : > "$CONCURRENT_HOOK/continue-planning-first"
  wait "$CONCURRENT_FIRST_PID"
  CONCURRENT_FIRST_RC=$?
  wait "$CONCURRENT_SECOND_PID"
  CONCURRENT_SECOND_RC=$?
else
  wait "$CONCURRENT_FIRST_PID"
  CONCURRENT_FIRST_RC=$?
fi
check "duplicate planning imports serialize behind one mission lifecycle epoch" bash -c \
  '[[ "$1" -eq 1 && "$2" -eq 1 && "$3" -eq 0 && "$4" -ne 0 &&
     "$(cat "$5/state")" = review && ! -e "$6" &&
     "$(find "$7" -maxdepth 1 -name "planning-stage-receipt-*.json" -type f | wc -l | tr -d " ")" = 1 &&
     -s "$7/planning-stage-receipt-$8.json" ]]' \
  _ "$CONCURRENT_ENTERED" "$CONCURRENT_SECOND_WAITED" \
  "$CONCURRENT_FIRST_RC" "$CONCURRENT_SECOND_RC" "$MISSION" "$STAGING" \
  "$CONTROL" "$CONCURRENT_NONCE"

echo "  planning-output-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
