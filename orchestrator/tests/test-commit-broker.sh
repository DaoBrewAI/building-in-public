#!/usr/bin/env bash
# Tests for scripts/commit-broker.sh — the exec-stage proxy-commit protocol.
set -uo pipefail
BROKER="$(cd "$(dirname "$0")/.." && pwd)/scripts/commit-broker.sh"
LIFECYCLE_LOCK="$(cd "$(dirname "$0")/.." && pwd)/scripts/coordinator_lifecycle_lock.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TASK_ID="task-a"; GENERATION=1; ACCEPTED_THREAD_ID="thread-task-a"
OUTCOME_NONCE="nonce-task-a-generation-1"
MD_ROOT="$TMP/mission"; MD="$MD_ROOT/tasks/$TASK_ID"; WT="$TMP/wt"
CONTROL_ROOT="$TMP/control"; CONTROL_DIR="$CONTROL_ROOT/tasks/$TASK_ID"
mkdir -p "$MD" "$CONTROL_DIR"
git init -q "$WT"
GITC=(git -C "$WT" -c user.email=t@t -c user.name=t -c commit.gpgsign=false)
"${GITC[@]}" commit -q --allow-empty -m base
git -C "$WT" checkout -q -b orc/test-mission
BASE_SHA="$(git -C "$WT" rev-parse HEAD)"
printf '%s\t%s\t%s\t%s\n' "$WT" "orc/test-mission" "$BASE_SHA" "$WT" > "$MD/worktrees.txt"
cp "$MD/worktrees.txt" "$CONTROL_DIR/worktrees.txt"
printf '%s\n' "$GENERATION" > "$CONTROL_DIR/generation"
printf '%s\n' "$ACCEPTED_THREAD_ID" > "$CONTROL_DIR/accepted-thread-id"
printf '%s\n' "$OUTCOME_NONCE" > "$CONTROL_DIR/outcome-nonce"
printf '%s\n' "$MD" > "$CONTROL_DIR/task-state-dir"
printf '%s\n' '{"version":1,"mission":"test-mission","tasks":[{"id":"task-a","depends_on":[],"files":["a.txt","attack.txt","b.txt","branch.txt","c.txt","x",".claude/settings.json",".claude/settings.local.json"],"contracts":[],"verification":["true"],"state":"ready"}]}' > "$CONTROL_ROOT/approved-task-dag.json"
printf 'design\n' > "$CONTROL_ROOT/approved-design.md"
printf 'plan\n' > "$CONTROL_ROOT/approved-plan.md"
printf 'brief\n' > "$CONTROL_ROOT/brief-exec.md"
(cd "$CONTROL_ROOT" && shasum -a 256 approved-design.md approved-plan.md brief-exec.md approved-task-dag.json > approved.sha256)
# Broker commits with the repo's config — pin identity/signing for the test repo.
git -C "$WT" config user.email t@t
git -C "$WT" config user.name t
git -C "$WT" config commit.gpgsign false

authorize_broker_for() {
  local mission="$1" control="$2" request="" candidate digest suffix
  for candidate in "$mission"/COMMIT-REQUEST-*.json; do
    [[ -e "$candidate" ]] || continue
    suffix="${candidate##*COMMIT-REQUEST-}"; suffix="${suffix%.json}"
    [[ -e "$mission/COMMIT-DONE-$suffix.json" || -e "$mission/COMMIT-REJECTED-$suffix.json" ]] && continue
    request="$candidate"
  done
  [[ -n "$request" ]] || return 0
  digest="$(jq -r '.outcome_digest // "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$request" 2>/dev/null || printf '%s' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"
  printf 'ready_for_commit\n' > "$control/state"
  printf 'ready_for_commit\n' > "$mission/state"
  printf '%s\n' "$digest" > "$control/latest-outcome"
}

run_broker() {
  authorize_broker_for "$MD" "$CONTROL_DIR"
  "$BROKER" --mission-dir "$MD" --control-dir "$CONTROL_DIR" --once >/dev/null 2>&1
}
run_broker_for() {
  authorize_broker_for "$1" "$2"
  if [[ "${ORC_COMMIT_BROKER_TEST_DEBUG:-}" == 1 ]]; then
    "$BROKER" --mission-dir "$1" --control-dir "$2" --once
  else
    "$BROKER" --mission-dir "$1" --control-dir "$2" --once >/dev/null 2>&1
  fi
}

[[ -x "$LIFECYCLE_LOCK" ]] || {
  echo "  case 1 failed: shared coordinator lifecycle lock helper is installed"
  exit 1
}
grep -Fq 'coordinator_lifecycle_lock.py' "$BROKER" || {
  echo "  case 1 failed: commit broker requests use the shared coordinator lifecycle lock"
  exit 1
}

# protocol v1 binds the request to coordinator-owned task authority and to the
# exact bytes currently present at every requested path. The digest stream is:
# sorted UTF-8 path, NUL, file|deleted, NUL, Git mode, NUL,
# file SHA-256 (empty if deleted), LF.
diff_sha256() {
  python3 - "$1" "$2" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sys

root = Path(sys.argv[1])
paths = sorted(json.loads(sys.argv[2]))
payload = bytearray()
for relative in paths:
    target = root / relative
    if target.is_file() and not target.is_symlink():
        state = b"file"
        mode = b"100755" if os.lstat(target).st_mode & 0o111 else b"100644"
        digest = hashlib.sha256(target.read_bytes()).hexdigest().encode("ascii")
    elif not os.path.lexists(target):
        state = b"deleted"
        mode = b"000000"
        digest = b""
    else:
        raise SystemExit(1)
    payload.extend(relative.encode("utf-8"))
    payload.extend(b"\0" + state + b"\0" + mode + b"\0" + digest + b"\n")
print(hashlib.sha256(payload).hexdigest())
PY
}

write_request() { # file worktree paths-json message task generation thread nonce base [diff]
  local request="$1" worktree="$2" paths="$3" message="$4"
  local task="$5" generation="$6" thread="$7" nonce="$8" base="$9"
  local diff="${10:-}"
  local outcome_digest="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  [[ -n "$diff" ]] || diff="$(diff_sha256 "$worktree" "$paths")"
  jq -nc \
    --argjson protocol_version 1 \
    --arg task_id "$task" \
    --argjson generation "$generation" \
    --arg accepted_thread_id "$thread" \
    --arg outcome_nonce "$nonce" \
    --arg outcome_digest "$outcome_digest" \
    --arg base_sha "$base" \
    --arg diff_sha256 "$diff" \
    --arg worktree "$worktree" \
    --argjson paths "$paths" \
    --arg message "$message" \
    '{protocol_version:$protocol_version,task_id:$task_id,generation:$generation,accepted_thread_id:$accepted_thread_id,outcome_nonce:$outcome_nonce,outcome_digest:$outcome_digest,base_sha:$base_sha,diff_sha256:$diff_sha256,worktree:$worktree,paths:$paths,message:$message}' \
    > "$request"
}

write_current_request() { # file worktree paths-json message
  write_request "$1" "$2" "$3" "$4" "$TASK_ID" "$GENERATION" \
    "$ACCEPTED_THREAD_ID" "$OUTCOME_NONCE" "$BASE_SHA"
}

request_sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

response_matches_identity() { # response task generation thread nonce request-sha
  jq -e \
    --arg task_id "$2" \
    --argjson generation "$3" \
    --arg accepted_thread_id "$4" \
    --arg outcome_nonce "$5" \
    --arg request_sha256 "$6" \
    '.protocol_version == 1 and (.protocol_version | type) == "number" and
     .task_id == $task_id and (.task_id | type) == "string" and
     .generation == $generation and (.generation | type) == "number" and
     .accepted_thread_id == $accepted_thread_id and
     (.accepted_thread_id | type) == "string" and
     .outcome_nonce == $outcome_nonce and
     (.outcome_nonce | type) == "string" and
     .request_sha256 == $request_sha256 and
     (.request_sha256 | test("^[0-9a-f]{64}$")) and
     if has("hash") then
       keys == ["accepted_thread_id","branch","generation","hash","outcome_nonce",
                "protocol_version","request_sha256","task_id"] and
       (.hash | test("^[0-9a-f]{40}([0-9a-f]{24})?$")) and
       (.branch | type) == "string"
     else
       keys == ["accepted_thread_id","generation","outcome_nonce","protocol_version",
                "reason","request_sha256","task_id"] and
       (.reason | type) == "string" and (.reason | length) > 0
     end' \
    "$1" >/dev/null
}

reason_names_frozen_dag_scope() {
  local reason
  reason="$(jq -r '.reason // empty' "$1")"
  [[ "$reason" == *"approved task DAG"* || "$reason" == *"frozen DAG scope"* ]]
}

setup_hardened_fixture() { # label [tracked|tracked-outside]
  local label="$1" tracked="${2:-}"
  H_ROOT="$TMP/hardened-$label"
  H_TASK_ID="task-a"; H_GENERATION=1
  H_THREAD="thread-$label"; H_NONCE="nonce-$label"
  H_MD_ROOT="$H_ROOT/mission"; H_MD="$H_MD_ROOT/tasks/$H_TASK_ID"
  H_CONTROL_ROOT="$H_ROOT/control"; H_CONTROL="$H_CONTROL_ROOT/tasks/$H_TASK_ID"
  H_WT="$H_ROOT/wt"
  mkdir -p "$H_MD" "$H_CONTROL"
  git init -q "$H_WT"
  if [[ "$tracked" == "tracked" || "$tracked" == "tracked-outside" ]]; then
    printf 'tracked baseline\n' > "$H_WT/allowed.txt"
  fi
  if [[ "$tracked" == "tracked-outside" ]]; then
    printf 'outside tracked baseline\n' > "$H_WT/outside.txt"
  fi
  git -C "$H_WT" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
    add --all
  git -C "$H_WT" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
    commit -q --allow-empty -m base
  git -C "$H_WT" checkout -q -b "orc/hardened-$label"
  git -C "$H_WT" config user.email t@t
  git -C "$H_WT" config user.name t
  git -C "$H_WT" config commit.gpgsign false
  H_BASE="$(git -C "$H_WT" rev-parse HEAD)"
  printf '%s\t%s\t%s\t%s\n' "$H_WT" "orc/hardened-$label" "$H_BASE" "$H_WT" \
    > "$H_MD/worktrees.txt"
  cp "$H_MD/worktrees.txt" "$H_CONTROL/worktrees.txt"
  printf '%s\n' "$H_GENERATION" > "$H_CONTROL/generation"
  printf '%s\n' "$H_THREAD" > "$H_CONTROL/accepted-thread-id"
  printf '%s\n' "$H_NONCE" > "$H_CONTROL/outcome-nonce"
  printf '%s\n' "$H_MD" > "$H_CONTROL/task-state-dir"
  printf '%s\n' '{"version":1,"mission":"hardened","tasks":[{"id":"task-a","depends_on":[],"files":["allowed.txt","second.txt"],"contracts":[],"verification":["true"],"state":"ready"}]}' \
    > "$H_CONTROL_ROOT/approved-task-dag.json"
  printf 'design\n' > "$H_CONTROL_ROOT/approved-design.md"
  printf 'plan\n' > "$H_CONTROL_ROOT/approved-plan.md"
  printf 'brief\n' > "$H_CONTROL_ROOT/brief-exec.md"
  (cd "$H_CONTROL_ROOT" && shasum -a 256 approved-design.md approved-plan.md brief-exec.md approved-task-dag.json > approved.sha256)
}

write_hardened_request() { # file paths-json message [diff]
  write_request "$1" "$H_WT" "$2" "$3" "$H_TASK_ID" "$H_GENERATION" \
    "$H_THREAD" "$H_NONCE" "$H_BASE" "${4:-}"
}

run_broker_with_hook() { # mission control hook-name mutation-function
  local mission="$1" control="$2" hook_name="$3" mutation="$4"
  local hook_dir="$H_ROOT/hook-$hook_name" pid attempt
  authorize_broker_for "$mission" "$control"
  mkdir -p "$hook_dir"
  ORC_COMMIT_BROKER_TEST_HOOK_DIR="$hook_dir" \
    ORC_COMMIT_BROKER_TEST_HOOK_NAME="$hook_name" \
    "$BROKER" --mission-dir "$mission" --control-dir "$control" --once \
    >/dev/null 2>&1 &
  pid=$!
  attempt=0
  while [[ ! -e "$hook_dir/reached-$hook_name" ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 1
    fi
    attempt=$((attempt + 1))
    if [[ "$attempt" -ge 500 ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 1
    fi
    sleep 0.01
  done
  "$mutation"
  : > "$hook_dir/continue-$hook_name"
  wait "$pid"
}
N=0; OK=0
check() {
  N=$((N + 1))
  if eval "$2"; then OK=$((OK + 1)); else echo "  case $N failed: $1"; fi
}

# 1. valid request -> commit created, DONE carries the hash
echo hello > "$WT/a.txt"
write_current_request "$MD/COMMIT-REQUEST-1.json" "$WT" '["a.txt"]' "task 1: a"
run_broker
H="$(git -C "$WT" rev-parse HEAD)"
check "valid commit" '[[ -f "$MD/COMMIT-DONE-1.json" && "$(jq -r .hash "$MD/COMMIT-DONE-1.json")" == "$H" && "$(git -C "$WT" log -1 --format=%s)" == "task 1: a" ]]'

# 2. unregistered worktree -> REJECTED
mkdir -p "$TMP/evil"
write_current_request "$MD/COMMIT-REQUEST-2.json" "$TMP/evil" '["x"]' "m"
run_broker
check "unregistered worktree" '[[ -f "$MD/COMMIT-REJECTED-2.json" && "$(jq -r .reason "$MD/COMMIT-REJECTED-2.json")" == *"not registered"* ]]'

# 3. shared and planted-local settings files -> REJECTED
mkdir -p "$WT/.claude"; echo '{}' > "$WT/.claude/settings.json"; echo '{}' > "$WT/.claude/settings.local.json"
write_current_request "$MD/COMMIT-REQUEST-3.json" "$WT" '[".claude/settings.json"]' "m"
run_broker
check "shared settings refused" '[[ -f "$MD/COMMIT-REJECTED-3.json" ]]'
write_current_request "$MD/COMMIT-REQUEST-3-local.json" "$WT" '[".claude/settings.local.json"]' "m"
run_broker
check "local settings refused" '[[ -f "$MD/COMMIT-REJECTED-3-local.json" ]]'
rm -rf "$WT/.claude"

# 4. path escaping the worktree -> REJECTED
write_current_request "$MD/COMMIT-REQUEST-4.json" "$WT" '["../escape.txt"]' "m"
run_broker
check "escape path" '[[ -f "$MD/COMMIT-REJECTED-4.json" && "$(jq -r .reason "$MD/COMMIT-REJECTED-4.json")" == *escape* ]]'

# 5. changes outside the request -> REJECTED, nothing committed
echo one > "$WT/b.txt"; echo two > "$WT/c.txt"
write_current_request "$MD/COMMIT-REQUEST-5.json" "$WT" '["b.txt"]' "only b"
BEFORE="$(git -C "$WT" rev-parse HEAD)"
run_broker
check "extra changes rejected" '[[ -f "$MD/COMMIT-REJECTED-5.json" && "$(git -C "$WT" rev-parse HEAD)" == "$BEFORE" ]]'

# 6. split correctly -> both commit
write_current_request "$MD/COMMIT-REQUEST-6.json" "$WT" '["b.txt","c.txt"]' "b and c"
run_broker
check "multi-path commit" '[[ -f "$MD/COMMIT-DONE-6.json" && -z "$(git -C "$WT" status --porcelain)" ]]'

# 7. answered requests are not reprocessed (DONE files stay stable)
D1="$(stat -f %m "$MD/COMMIT-DONE-1.json")"
run_broker
check "idempotent" '[[ "$(stat -f %m "$MD/COMMIT-DONE-1.json")" == "$D1" ]]'

# 8. invalid JSON older than the grace window -> REJECTED
printf 'not json' > "$MD/COMMIT-REQUEST-8.json"
touch -t 202601010000 "$MD/COMMIT-REQUEST-8.json"
run_broker
check "stale invalid json" '[[ -f "$MD/COMMIT-REJECTED-8.json" ]]'

# 9. A worker-controlled manifest rewrite never expands broker authority.
EVIL="$TMP/evil-repo"
git init -q "$EVIL"
git -C "$EVIL" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m base
echo attack > "$EVIL/attack.txt"
printf '%s\t%s\t%s\t%s\n' "$EVIL" evil "$(git -C "$EVIL" rev-parse HEAD)" "$EVIL" > "$MD/worktrees.txt"
write_current_request "$MD/COMMIT-REQUEST-9.json" "$EVIL" '["attack.txt"]' "escape authority"
EVIL_BEFORE="$(git -C "$EVIL" rev-parse HEAD)"
run_broker
check "mutable worker manifest cannot expand authority" '[[ -f "$MD/COMMIT-REJECTED-9.json" && "$(git -C "$EVIL" rev-parse HEAD)" == "$EVIL_BEFORE" && "$(jq -r .reason "$MD/COMMIT-REJECTED-9.json")" == *"control manifest"* ]]'

# Restore the worker copy for request-level authority checks.
cp "$CONTROL_DIR/worktrees.txt" "$MD/worktrees.txt"

# 10. A suffix of a registered absolute path is not an exact worktree identity.
mkdir -p "$TMP/wt"
write_current_request "$MD/COMMIT-REQUEST-10.json" "wt" '["a.txt"]' "relative suffix"
run_broker
check "relative suffix cannot match registered worktree" '[[ -f "$MD/COMMIT-REJECTED-10.json" && "$(jq -r .reason "$MD/COMMIT-REJECTED-10.json")" == *"absolute"* ]]'

# 11. Even the registered path is rejected if it is on another branch.
git -C "$WT" checkout -q -b attacker
echo branch > "$WT/branch.txt"
write_current_request "$MD/COMMIT-REQUEST-11.json" "$WT" '["branch.txt"]' "wrong branch"
BRANCH_BEFORE="$(git -C "$WT" rev-parse HEAD)"
run_broker
check "registered worktree branch is pinned" '[[ -f "$MD/COMMIT-REJECTED-11.json" && "$(git -C "$WT" rev-parse HEAD)" == "$BRANCH_BEFORE" && "$(jq -r .reason "$MD/COMMIT-REJECTED-11.json")" == *"branch"* ]]'

# 12. A complete v1 request commits untracked files and DONE is bound to the
# exact coordinator identity and request bytes. Paths are intentionally
# unsorted; diff_sha256 is canonical over sorted paths.
setup_hardened_fixture valid
printf 'allowed payload\n' > "$H_WT/allowed.txt"
printf 'second payload\n' > "$H_WT/second.txt"
VALID_REQ="$H_MD/COMMIT-REQUEST-valid.json"
write_hardened_request "$VALID_REQ" '["second.txt","allowed.txt"]' "valid hardened request"
VALID_REQ_SHA="$(request_sha256 "$VALID_REQ")"
VALID_BEFORE="$H_BASE"
run_broker_for "$H_MD" "$H_CONTROL"
VALID_AFTER="$(git -C "$H_WT" rev-parse HEAD)"
check "v1 DONE binds coordinator and request identity" \
  '[[ -f "$H_MD/COMMIT-DONE-valid.json" && ! -e "$H_MD/COMMIT-REJECTED-valid.json" && "$VALID_AFTER" != "$VALID_BEFORE" && -z "$(git -C "$H_WT" status --porcelain)" ]] && response_matches_identity "$H_MD/COMMIT-DONE-valid.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$VALID_REQ_SHA" && [[ "$(jq -r .hash "$H_MD/COMMIT-DONE-valid.json")" == "$VALID_AFTER" && "$(jq -r .branch "$H_MD/COMMIT-DONE-valid.json")" == "orc/hardened-valid" ]]'

# 13. Canonical request hashing represents a tracked deletion with state
# "deleted" and an empty digest field.
setup_hardened_fixture deletion tracked
rm "$H_WT/allowed.txt"
DELETE_REQ="$H_MD/COMMIT-REQUEST-delete.json"
write_hardened_request "$DELETE_REQ" '["allowed.txt"]' "delete allowed file"
DELETE_REQ_SHA="$(request_sha256 "$DELETE_REQ")"
run_broker_for "$H_MD" "$H_CONTROL"
DELETE_AFTER="$(git -C "$H_WT" rev-parse HEAD)"
check "tracked deletion uses canonical digest and identity-bound DONE" \
  '[[ -f "$H_MD/COMMIT-DONE-delete.json" && ! -e "$H_WT/allowed.txt" && "$DELETE_AFTER" != "$H_BASE" ]] && response_matches_identity "$H_MD/COMMIT-DONE-delete.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$DELETE_REQ_SHA"'

# 14. The request digest is a pre-commit integrity boundary: changing even an
# allowed file after request publication must reject without committing it.
setup_hardened_fixture stale-diff
printf 'before request\n' > "$H_WT/allowed.txt"
STALE_REQ="$H_MD/COMMIT-REQUEST-stale.json"
write_hardened_request "$STALE_REQ" '["allowed.txt"]' "stale diff"
STALE_REQ_SHA="$(request_sha256 "$STALE_REQ")"
printf 'after request\n' > "$H_WT/allowed.txt"
STALE_BEFORE="$H_BASE"
run_broker_for "$H_MD" "$H_CONTROL"
check "stale diff digest is rejected with request identity" \
  '[[ -f "$H_MD/COMMIT-REJECTED-stale.json" && ! -e "$H_MD/COMMIT-DONE-stale.json" && "$(git -C "$H_WT" rev-parse HEAD)" == "$STALE_BEFORE" ]] && response_matches_identity "$H_MD/COMMIT-REJECTED-stale.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$STALE_REQ_SHA"'

# 15. Child-supplied paths never expand the coordinator's frozen DAG scope.
setup_hardened_fixture requested-scope
printf 'outside frozen scope\n' > "$H_WT/outside.txt"
OUTSIDE_REQ="$H_MD/COMMIT-REQUEST-outside.json"
write_hardened_request "$OUTSIDE_REQ" '["outside.txt"]' "outside frozen scope"
OUTSIDE_REQ_SHA="$(request_sha256 "$OUTSIDE_REQ")"
OUTSIDE_BEFORE="$H_BASE"
run_broker_for "$H_MD" "$H_CONTROL"
check "requested path outside approved task DAG is rejected" \
  '[[ -f "$H_MD/COMMIT-REJECTED-outside.json" && ! -e "$H_MD/COMMIT-DONE-outside.json" && "$(git -C "$H_WT" rev-parse HEAD)" == "$OUTSIDE_BEFORE" && -n "$(git -C "$H_WT" status --porcelain -- outside.txt)" ]] && reason_names_frozen_dag_scope "$H_MD/COMMIT-REJECTED-outside.json" && response_matches_identity "$H_MD/COMMIT-REJECTED-outside.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$OUTSIDE_REQ_SHA"'

# 16. Actual dirty paths are checked against the frozen DAG as well as against
# the request. A safe requested file cannot hide an extra out-of-scope change.
setup_hardened_fixture dirty-scope
printf 'allowed dirty\n' > "$H_WT/allowed.txt"
printf 'outside dirty\n' > "$H_WT/outside.txt"
DIRTY_REQ="$H_MD/COMMIT-REQUEST-dirty.json"
write_hardened_request "$DIRTY_REQ" '["allowed.txt"]' "dirty scope"
DIRTY_REQ_SHA="$(request_sha256 "$DIRTY_REQ")"
DIRTY_BEFORE="$H_BASE"
run_broker_for "$H_MD" "$H_CONTROL"
check "actual dirty path outside approved task DAG is rejected" \
  '[[ -f "$H_MD/COMMIT-REJECTED-dirty.json" && ! -e "$H_MD/COMMIT-DONE-dirty.json" && "$(git -C "$H_WT" rev-parse HEAD)" == "$DIRTY_BEFORE" && -n "$(git -C "$H_WT" status --porcelain -- outside.txt)" ]] && reason_names_frozen_dag_scope "$H_MD/COMMIT-REJECTED-dirty.json" && response_matches_identity "$H_MD/COMMIT-REJECTED-dirty.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$DIRTY_REQ_SHA"'

# 17. Every coordinator-bound field is mandatory and exact. Rejections still
# carry the submitted task identity plus a digest of the exact request bytes.
setup_hardened_fixture authority
expect_authority_rejection() { # suffix description jq-filter
  local suffix="$1" description="$2" filter="$3"
  local request="$H_MD/COMMIT-REQUEST-$suffix.json" temporary="$H_MD/.request-$suffix.tmp"
  printf '%s\n' "$description" > "$H_WT/allowed.txt"
  write_hardened_request "$request" '["allowed.txt"]' "$description"
  jq "$filter" "$request" > "$temporary"
  mv "$temporary" "$request"
  local request_sha task generation thread nonce before
  request_sha="$(request_sha256 "$request")"
  task="$(jq -r '.task_id // empty' "$request")"
  generation="$(jq -r '.generation // 0' "$request")"
  thread="$(jq -r '.accepted_thread_id // empty' "$request")"
  nonce="$(jq -r '.outcome_nonce // empty' "$request")"
  before="$(git -C "$H_WT" rev-parse HEAD)"
  run_broker_for "$H_MD" "$H_CONTROL"
  check "$description" \
    '[[ -f "$H_MD/COMMIT-REJECTED-$suffix.json" && ! -e "$H_MD/COMMIT-DONE-$suffix.json" && "$(git -C "$H_WT" rev-parse HEAD)" == "$before" ]] && response_matches_identity "$H_MD/COMMIT-REJECTED-$suffix.json" "$task" "$generation" "$thread" "$nonce" "$request_sha"'
}

expect_authority_rejection missing-protocol "missing protocol_version is rejected" 'del(.protocol_version)'
expect_authority_rejection wrong-protocol "wrong protocol_version is rejected" '.protocol_version = 2'
expect_authority_rejection wrong-task "task_id must match task control" '.task_id = "other-task"'
expect_authority_rejection wrong-generation "generation must match coordinator authority" '.generation = 2'
expect_authority_rejection wrong-thread "accepted_thread_id must match coordinator authority" '.accepted_thread_id = "other-thread"'
expect_authority_rejection wrong-nonce "outcome_nonce must match coordinator authority" '.outcome_nonce = "other-nonce"'
expect_authority_rejection missing-base "base_sha is mandatory" 'del(.base_sha)'
expect_authority_rejection wrong-base "base_sha must match registered task base" '.base_sha = "0000000000000000000000000000000000000000"'
expect_authority_rejection missing-diff "diff_sha256 is mandatory" 'del(.diff_sha256)'

# 18. Allowed task paths must be regular files or tracked deletions. Hashing a
# symlink target does not bind the link blob that Git would actually stage.
setup_hardened_fixture outside-symlink
printf 'outside target bytes\n' > "$H_ROOT/outside-target.txt"
ln -s "$H_ROOT/outside-target.txt" "$H_WT/allowed.txt"
SYMLINK_REQ="$H_MD/COMMIT-REQUEST-symlink.json"
write_hardened_request "$SYMLINK_REQ" '["allowed.txt"]' "reject outside symlink"
SYMLINK_REQ_SHA="$(request_sha256 "$SYMLINK_REQ")"
SYMLINK_BEFORE="$H_BASE"
run_broker_for "$H_MD" "$H_CONTROL"
check "allowed path symlink to outside worktree is rejected" \
  '[[ -f "$H_MD/COMMIT-REJECTED-symlink.json" && ! -e "$H_MD/COMMIT-DONE-symlink.json" && "$(git -C "$H_WT" rev-parse HEAD)" == "$SYMLINK_BEFORE" ]] && response_matches_identity "$H_MD/COMMIT-REJECTED-symlink.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$SYMLINK_REQ_SHA"'

setup_hardened_fixture broken-symlink
ln -s "$H_ROOT/missing-target.txt" "$H_WT/allowed.txt"
BROKEN_REQ="$H_MD/COMMIT-REQUEST-broken-link.json"
write_hardened_request "$BROKEN_REQ" '["allowed.txt"]' "reject broken symlink"
BROKEN_REQ_SHA="$(request_sha256 "$BROKEN_REQ")"
BROKEN_BEFORE="$H_BASE"
run_broker_for "$H_MD" "$H_CONTROL"
check "broken symlink cannot masquerade as a deletion" \
  '[[ -f "$H_MD/COMMIT-REJECTED-broken-link.json" && ! -e "$H_MD/COMMIT-DONE-broken-link.json" && "$(git -C "$H_WT" rev-parse HEAD)" == "$BROKEN_BEFORE" ]] && response_matches_identity "$H_MD/COMMIT-REJECTED-broken-link.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$BROKEN_REQ_SHA"'

# 19. A tracked, already-staged out-of-DAG path must be rejected independently
# of the unstaged/untracked path checks.
setup_hardened_fixture staged-scope tracked-outside
printf 'allowed changed\n' > "$H_WT/allowed.txt"
printf 'outside staged change\n' > "$H_WT/outside.txt"
git -C "$H_WT" add -- outside.txt
STAGED_SCOPE_REQ="$H_MD/COMMIT-REQUEST-staged-scope.json"
write_hardened_request "$STAGED_SCOPE_REQ" '["allowed.txt"]' "reject staged outside scope"
STAGED_SCOPE_REQ_SHA="$(request_sha256 "$STAGED_SCOPE_REQ")"
STAGED_SCOPE_BEFORE="$H_BASE"
run_broker_for "$H_MD" "$H_CONTROL"
check "pre-staged tracked path outside approved task DAG is rejected" \
  '[[ -f "$H_MD/COMMIT-REJECTED-staged-scope.json" && ! -e "$H_MD/COMMIT-DONE-staged-scope.json" && "$(git -C "$H_WT" rev-parse HEAD)" == "$STAGED_SCOPE_BEFORE" ]] && reason_names_frozen_dag_scope "$H_MD/COMMIT-REJECTED-staged-scope.json" && response_matches_identity "$H_MD/COMMIT-REJECTED-staged-scope.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$STAGED_SCOPE_REQ_SHA"'

# 20. Deterministic hook seams prove the request, coordinator authority, and
# task manifest are revalidated after the initial content validation.
mutate_request_message() {
  jq '.message = "mutated after validation"' "$MUTATION_REQUEST" > "$MUTATION_REQUEST.tmp"
  mv "$MUTATION_REQUEST.tmp" "$MUTATION_REQUEST"
}
setup_hardened_fixture request-mutation
printf 'request mutation payload\n' > "$H_WT/allowed.txt"
MUTATION_REQUEST="$H_MD/COMMIT-REQUEST-request-mutation.json"
write_hardened_request "$MUTATION_REQUEST" '["allowed.txt"]' "original request"
MUTATION_REQ_SHA="$(request_sha256 "$MUTATION_REQUEST")"
MUTATION_BEFORE="$H_BASE"
run_broker_with_hook "$H_MD" "$H_CONTROL" after-validation mutate_request_message || true
check "request bytes mutated mid-validation are rejected" \
  '[[ -f "$H_MD/COMMIT-REJECTED-request-mutation.json" && ! -e "$H_MD/COMMIT-DONE-request-mutation.json" && "$(git -C "$H_WT" rev-parse HEAD)" == "$MUTATION_BEFORE" ]] && response_matches_identity "$H_MD/COMMIT-REJECTED-request-mutation.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$MUTATION_REQ_SHA"'

mutate_outcome_nonce() {
  printf 'nonce-mutated-after-validation\n' > "$H_CONTROL/outcome-nonce"
}
setup_hardened_fixture authority-mutation
printf 'authority mutation payload\n' > "$H_WT/allowed.txt"
AUTH_MUTATION_REQ="$H_MD/COMMIT-REQUEST-authority-mutation.json"
write_hardened_request "$AUTH_MUTATION_REQ" '["allowed.txt"]' "authority mutation"
AUTH_MUTATION_REQ_SHA="$(request_sha256 "$AUTH_MUTATION_REQ")"
AUTH_MUTATION_BEFORE="$H_BASE"
run_broker_with_hook "$H_MD" "$H_CONTROL" after-validation mutate_outcome_nonce || true
check "coordinator authority mutated mid-validation is rejected" \
  '[[ -f "$H_MD/COMMIT-REJECTED-authority-mutation.json" && ! -e "$H_MD/COMMIT-DONE-authority-mutation.json" && "$(git -C "$H_WT" rev-parse HEAD)" == "$AUTH_MUTATION_BEFORE" ]] && response_matches_identity "$H_MD/COMMIT-REJECTED-authority-mutation.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$AUTH_MUTATION_REQ_SHA"'

mutate_worker_manifest() {
  printf '# mutated after validation\n' >> "$H_MD/worktrees.txt"
}
setup_hardened_fixture manifest-mutation
printf 'manifest mutation payload\n' > "$H_WT/allowed.txt"
MANIFEST_MUTATION_REQ="$H_MD/COMMIT-REQUEST-manifest-mutation.json"
write_hardened_request "$MANIFEST_MUTATION_REQ" '["allowed.txt"]' "manifest mutation"
MANIFEST_MUTATION_REQ_SHA="$(request_sha256 "$MANIFEST_MUTATION_REQ")"
MANIFEST_MUTATION_BEFORE="$H_BASE"
run_broker_with_hook "$H_MD" "$H_CONTROL" after-validation mutate_worker_manifest || true
check "worker manifest mutated mid-validation is rejected" \
  '[[ -f "$H_MD/COMMIT-REJECTED-manifest-mutation.json" && ! -e "$H_MD/COMMIT-DONE-manifest-mutation.json" && "$(git -C "$H_WT" rev-parse HEAD)" == "$MANIFEST_MUTATION_BEFORE" ]] && response_matches_identity "$H_MD/COMMIT-REJECTED-manifest-mutation.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$MANIFEST_MUTATION_REQ_SHA"'

# 21. Mutating an allowed file after worktree digest validation but immediately
# before staging must be caught by validating the staged index bytes.
mutate_before_stage() {
  printf 'after validation, before staging\n' > "$H_WT/allowed.txt"
}
setup_hardened_fixture stage-mutation
printf 'validated worktree bytes\n' > "$H_WT/allowed.txt"
STAGE_MUTATION_REQ="$H_MD/COMMIT-REQUEST-stage-mutation.json"
write_hardened_request "$STAGE_MUTATION_REQ" '["allowed.txt"]' "stage mutation"
STAGE_MUTATION_REQ_SHA="$(request_sha256 "$STAGE_MUTATION_REQ")"
STAGE_MUTATION_BEFORE="$H_BASE"
run_broker_with_hook "$H_MD" "$H_CONTROL" before-stage mutate_before_stage || true
check "stage-time content mutation cannot change committed bytes" \
  '[[ -f "$H_MD/COMMIT-REJECTED-stage-mutation.json" && ! -e "$H_MD/COMMIT-DONE-stage-mutation.json" && "$(git -C "$H_WT" rev-parse HEAD)" == "$STAGE_MUTATION_BEFORE" ]] && response_matches_identity "$H_MD/COMMIT-REJECTED-stage-mutation.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$STAGE_MUTATION_REQ_SHA"'

# 22. Repository hooks must not be able to replace coordinator-verified index
# bytes between validation and commit creation.
setup_hardened_fixture hook-index-mutation tracked
printf 'coordinator-approved bytes\n' > "$H_WT/allowed.txt"
HOOK_MUTATION_REQ="$H_MD/COMMIT-REQUEST-hook-index-mutation.json"
write_hardened_request "$HOOK_MUTATION_REQ" '["allowed.txt"]' "verified tree commit"
HOOK_MUTATION_REQ_SHA="$(request_sha256 "$HOOK_MUTATION_REQ")"
HOOK_MARKER="$H_ROOT/pre-commit-ran"
REF_HOOK_MARKER="$H_ROOT/reference-transaction-ran"
mkdir -p "$H_WT/.git/hooks"
HOOK_PATH="$H_WT/.git/hooks/pre-commit"
apply_hook_fixture() {
  printf '%s\n' '#!/bin/sh' \
    "printf 'hook-substituted bytes\\n' > '$H_WT/allowed.txt'" \
    "git -C '$H_WT' add -- allowed.txt" \
    "printf 'ran\\n' > '$HOOK_MARKER'" > "$HOOK_PATH"
  chmod +x "$HOOK_PATH"
}
apply_hook_fixture
cat > "$H_WT/.git/hooks/reference-transaction" <<SH
#!/bin/sh
printf 'ran\n' > '$REF_HOOK_MARKER'
SH
chmod +x "$H_WT/.git/hooks/reference-transaction"
run_broker_for "$H_MD" "$H_CONTROL"
HOOK_MUTATION_AFTER="$(git -C "$H_WT" rev-parse HEAD)"
check "commit creation uses the verified index tree and cannot run mutating hooks" \
  '[[ -f "$H_MD/COMMIT-DONE-hook-index-mutation.json" && ! -e "$H_MD/COMMIT-REJECTED-hook-index-mutation.json" && "$HOOK_MUTATION_AFTER" != "$H_BASE" && "$(git -C "$H_WT" show "$HOOK_MUTATION_AFTER:allowed.txt")" = "coordinator-approved bytes" && ! -e "$HOOK_MARKER" && ! -e "$REF_HOOK_MARKER" ]] && response_matches_identity "$H_MD/COMMIT-DONE-hook-index-mutation.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$HOOK_MUTATION_REQ_SHA"'

# 23. Only one broker may own terminal-check through response publication for a
# task. A second broker must wait and then observe the first broker's DONE.
setup_hardened_fixture concurrent-brokers tracked
printf 'concurrent approved bytes\n' > "$H_WT/allowed.txt"
CONCURRENT_REQ="$H_MD/COMMIT-REQUEST-concurrent.json"
write_hardened_request "$CONCURRENT_REQ" '["allowed.txt"]' "single broker owner"
CONCURRENT_REQ_SHA="$(request_sha256 "$CONCURRENT_REQ")"
CONCURRENT_HOOK_ONE="$H_ROOT/hook-one"
CONCURRENT_HOOK_TWO="$H_ROOT/hook-two"
mkdir -p "$CONCURRENT_HOOK_ONE" "$CONCURRENT_HOOK_TWO"
authorize_broker_for "$H_MD" "$H_CONTROL"
ORC_COMMIT_BROKER_TEST_HOOK_DIR="$CONCURRENT_HOOK_ONE" \
  ORC_COMMIT_BROKER_TEST_HOOK_NAME=after-validation \
  "$BROKER" --mission-dir "$H_MD" --control-dir "$H_CONTROL" --once \
  >/dev/null 2>&1 &
CONCURRENT_PID_ONE=$!
CONCURRENT_WAIT=0
while [[ ! -e "$CONCURRENT_HOOK_ONE/reached-after-validation" && "$CONCURRENT_WAIT" -lt 500 ]]; do
  kill -0 "$CONCURRENT_PID_ONE" 2>/dev/null || break
  CONCURRENT_WAIT=$((CONCURRENT_WAIT + 1))
  sleep 0.01
done
ORC_COMMIT_BROKER_TEST_HOOK_DIR="$CONCURRENT_HOOK_TWO" \
  ORC_COMMIT_BROKER_TEST_HOOK_NAME=after-validation \
  "$BROKER" --mission-dir "$H_MD" --control-dir "$H_CONTROL" --once \
  >/dev/null 2>&1 &
CONCURRENT_PID_TWO=$!
CONCURRENT_WAIT=0
while [[ ! -e "$CONCURRENT_HOOK_TWO/reached-after-validation" && "$CONCURRENT_WAIT" -lt 100 ]]; do
  kill -0 "$CONCURRENT_PID_TWO" 2>/dev/null || break
  CONCURRENT_WAIT=$((CONCURRENT_WAIT + 1))
  sleep 0.01
done
CONCURRENT_SECOND_ENTERED=0
[[ -e "$CONCURRENT_HOOK_TWO/reached-after-validation" ]] && CONCURRENT_SECOND_ENTERED=1
: > "$CONCURRENT_HOOK_ONE/continue-after-validation"
[[ "$CONCURRENT_SECOND_ENTERED" -eq 0 ]] || : > "$CONCURRENT_HOOK_TWO/continue-after-validation"
wait "$CONCURRENT_PID_ONE" 2>/dev/null || true
wait "$CONCURRENT_PID_TWO" 2>/dev/null || true
CONCURRENT_AFTER="$(git -C "$H_WT" rev-parse HEAD)"
check "concurrent brokers serialize one request into one immutable terminal response" \
  '[[ "$CONCURRENT_SECOND_ENTERED" -eq 0 && -f "$H_MD/COMMIT-DONE-concurrent.json" && ! -e "$H_MD/COMMIT-REJECTED-concurrent.json" && "$CONCURRENT_AFTER" != "$H_BASE" && "$(git -C "$H_WT" rev-list --count "$H_BASE..$CONCURRENT_AFTER")" = 1 ]] && response_matches_identity "$H_MD/COMMIT-DONE-concurrent.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$CONCURRENT_REQ_SHA"'

# 24. File mode is part of the canonical request/tree digest. A chmod-only
# change is commit-worthy, and a mode race cannot reuse a content-only digest.
setup_hardened_fixture executable-mode tracked
git -C "$H_WT" config core.filemode true
chmod +x "$H_WT/allowed.txt"
MODE_REQ="$H_MD/COMMIT-REQUEST-executable-mode.json"
write_hardened_request "$MODE_REQ" '["allowed.txt"]' "make allowed executable"
MODE_REQ_SHA="$(request_sha256 "$MODE_REQ")"
run_broker_for "$H_MD" "$H_CONTROL"
MODE_AFTER="$(git -C "$H_WT" rev-parse HEAD)"
check "chmod-only change is bound and committed with its exact Git mode" \
  '[[ -f "$H_MD/COMMIT-DONE-executable-mode.json" && ! -e "$H_MD/COMMIT-REJECTED-executable-mode.json" && "$(git -C "$H_WT" ls-tree "$MODE_AFTER" -- allowed.txt | awk "{print \$1}")" = 100755 ]] && response_matches_identity "$H_MD/COMMIT-DONE-executable-mode.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$MODE_REQ_SHA"'

mutate_mode_before_stage() {
  chmod +x "$H_WT/allowed.txt"
}
setup_hardened_fixture mode-race tracked
git -C "$H_WT" config core.filemode true
printf 'same requested bytes, original mode\n' > "$H_WT/allowed.txt"
MODE_RACE_REQ="$H_MD/COMMIT-REQUEST-mode-race.json"
write_hardened_request "$MODE_RACE_REQ" '["allowed.txt"]' "reject changed mode"
MODE_RACE_REQ_SHA="$(request_sha256 "$MODE_RACE_REQ")"
run_broker_with_hook "$H_MD" "$H_CONTROL" before-stage mutate_mode_before_stage || true
check "mode mutation after validation is rejected before commit publication" \
  '[[ -f "$H_MD/COMMIT-REJECTED-mode-race.json" && ! -e "$H_MD/COMMIT-DONE-mode-race.json" && "$(git -C "$H_WT" rev-parse HEAD)" = "$H_BASE" ]] && response_matches_identity "$H_MD/COMMIT-REJECTED-mode-race.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$MODE_RACE_REQ_SHA"'

# 25. A crash after the branch CAS but before DONE publication is recovered
# from the immutable commit intent without creating a replacement commit.
setup_hardened_fixture post-cas-recovery tracked
printf 'post CAS durable bytes\n' > "$H_WT/allowed.txt"
POST_CAS_REQ="$H_MD/COMMIT-REQUEST-post-cas.json"
write_hardened_request "$POST_CAS_REQ" '["allowed.txt"]' "recover exact post CAS commit"
POST_CAS_REQ_SHA="$(request_sha256 "$POST_CAS_REQ")"
authorize_broker_for "$H_MD" "$H_CONTROL"
ORC_COMMIT_BROKER_TEST_FAIL_AFTER_UPDATE_REF=1 \
  "$BROKER" --mission-dir "$H_MD" --control-dir "$H_CONTROL" --once \
  >/dev/null 2>&1
POST_CAS_FIRST_RC=$?
POST_CAS_COMMIT="$(git -C "$H_WT" rev-parse HEAD)"
POST_CAS_COUNT="$(git -C "$H_WT" rev-list --count "$H_BASE..$POST_CAS_COMMIT")"
run_broker_for "$H_MD" "$H_CONTROL"
POST_CAS_RETRY_RC=$?
check "post-CAS retry proves the immutable intent and publishes the original DONE" \
  '[[ "$POST_CAS_FIRST_RC" -ne 0 && "$POST_CAS_RETRY_RC" -eq 0 && "$POST_CAS_COMMIT" != "$H_BASE" && "$POST_CAS_COUNT" = 1 && "$(git -C "$H_WT" rev-parse HEAD)" = "$POST_CAS_COMMIT" && -f "$H_MD/COMMIT-INTENT-post-cas.json" && -f "$H_MD/COMMIT-DONE-post-cas.json" && ! -e "$H_MD/COMMIT-REJECTED-post-cas.json" ]] && response_matches_identity "$H_MD/COMMIT-DONE-post-cas.json" "$H_TASK_ID" "$H_GENERATION" "$H_THREAD" "$H_NONCE" "$POST_CAS_REQ_SHA"'

setup_hardened_fixture wrong-task-state-dir tracked
printf 'authorized work only\n' > "$H_WT/allowed.txt"
WRONG_STATE_REQ="$H_MD/COMMIT-REQUEST-wrong-state-dir.json"
write_hardened_request "$WRONG_STATE_REQ" '["allowed.txt"]' "refuse wrong task state root"
mkdir -p "$H_ROOT/other-task-state"
printf '%s\n' "$H_ROOT/other-task-state" > "$H_CONTROL/task-state-dir"
WRONG_STATE_BEFORE="$(git -C "$H_WT" rev-parse HEAD)"
run_broker_for "$H_MD" "$H_CONTROL"
WRONG_STATE_RC=$?
check "broker refuses a mission-dir outside coordinator task-state-dir authority" \
  '[[ "$WRONG_STATE_RC" -ne 0 && "$(git -C "$H_WT" rev-parse HEAD)" = "$WRONG_STATE_BEFORE" && ! -e "$H_MD/COMMIT-DONE-wrong-state-dir.json" && ! -e "$H_MD/COMMIT-REJECTED-wrong-state-dir.json" ]]'

setup_hardened_fixture frozen-dag-drift tracked
printf 'drift candidate\n' > "$H_WT/allowed.txt"
DAG_DRIFT_REQ="$H_MD/COMMIT-REQUEST-dag-drift.json"
write_hardened_request "$DAG_DRIFT_REQ" '["allowed.txt"]' "refuse unfrozen DAG"
printf '\n' >> "$H_CONTROL_ROOT/approved-task-dag.json"
DAG_DRIFT_BEFORE="$(git -C "$H_WT" rev-parse HEAD)"
run_broker_for "$H_MD" "$H_CONTROL"
DAG_DRIFT_RC=$?
check "broker refuses approved DAG bytes that drift from frozen hash authority" \
  '[[ "$DAG_DRIFT_RC" -ne 0 && "$(git -C "$H_WT" rev-parse HEAD)" = "$DAG_DRIFT_BEFORE" && ! -e "$H_MD/COMMIT-DONE-dag-drift.json" && ! -e "$H_MD/COMMIT-REJECTED-dag-drift.json" ]]'

echo "  commit-broker: $OK/$N"
[[ "$OK" -eq "$N" ]]
