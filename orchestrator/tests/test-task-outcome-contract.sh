#!/usr/bin/env bash
# Coordinator-owned import of one accepted native task's structured outcome.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTCOME="$ROOT/scripts/task-outcome.py"
BROKER="$ROOT/scripts/commit-broker.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/orc-task-outcome.XXXXXX")"
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

check "coordinator task-outcome helper is installed" test -x "$OUTCOME"
check "task outcome record and reopen use the shared coordinator lifecycle lock" \
  grep -Fq 'acquire_lifecycle_lock' "$OUTCOME"
if [[ ! -x "$OUTCOME" ]]; then
  echo "  task-outcome: $OK/$N"
  exit 1
fi

setup_case() {
  local root="$1"
  REPO="$root/repo"
  CHILD="$root/child"
  CONTROL="$root/control"
  TASK_DIR="$root/task-state"
  INPUT="$root/outcome.json"
  TASK_ID="task-a"
  THREAD_ID="thread-task-a"
  TURN_ID="turn-task-a-1"
  NONCE="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  mkdir -p "$REPO" "$CONTROL/tasks/$TASK_ID" "$TASK_DIR"
  git init -q "$REPO"
  git -C "$REPO" config user.email task-outcome@example.invalid
  git -C "$REPO" config user.name task-outcome
  git -C "$REPO" config commit.gpgsign false
  printf 'root\n' > "$REPO/root.txt"
  git -C "$REPO" add root.txt
  git -C "$REPO" commit -qm root
  ROOT_SHA="$(git -C "$REPO" rev-parse HEAD)"
  printf 'base\n' > "$REPO/base.txt"
  git -C "$REPO" add base.txt
  git -C "$REPO" commit -qm base
  BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" worktree add -qb orc-task/mission/$TASK_ID "$CHILD" "$BASE_SHA"
  printf '%s\t%s\t%s\t%s\n' \
    "$CHILD" "orc-task/mission/$TASK_ID" "$BASE_SHA" "$REPO" \
    > "$CONTROL/tasks/$TASK_ID/worktrees.txt"
  cp "$CONTROL/tasks/$TASK_ID/worktrees.txt" "$TASK_DIR/worktrees.txt"
  printf '%s\n' "$THREAD_ID" > "$CONTROL/tasks/$TASK_ID/accepted-thread-id"
  printf '1\n' > "$CONTROL/tasks/$TASK_ID/generation"
  printf '%s\n' "$NONCE" > "$CONTROL/tasks/$TASK_ID/outcome-nonce"
  printf '%s\n' "$TASK_DIR" > "$CONTROL/tasks/$TASK_ID/task-state-dir"
  printf 'running\n' > "$CONTROL/tasks/$TASK_ID/state"
  printf 'running\n' > "$TASK_DIR/state"
  printf '%s\n' '{"version":1,"mission":"mission","tasks":[{"id":"task-a","depends_on":[],"files":["feature.txt"],"contracts":[],"verification":["test -f feature.txt"],"state":"ready"}]}' > "$CONTROL/approved-task-dag.json"
  printf 'design\n' > "$CONTROL/approved-design.md"
  printf 'plan\n' > "$CONTROL/approved-plan.md"
  printf 'brief\n' > "$CONTROL/brief-exec.md"
  (cd "$CONTROL" && shasum -a 256 approved-design.md approved-plan.md brief-exec.md approved-task-dag.json > approved.sha256)
  TIP_SHA="$BASE_SHA"
}

write_outcome() {
  local path="$1" kind="$2"
  python3 - "$path" "$kind" "$TASK_ID" "$THREAD_ID" "$NONCE" \
    "$BASE_SHA" "$TIP_SHA" <<'PY'
import json
import sys

path, kind, task, thread, nonce, base, tip = sys.argv[1:]
common = {
    "protocol_version": 1,
    "kind": kind,
    "task_id": task,
    "generation": 1,
    "accepted_thread_id": thread,
    "outcome_nonce": nonce,
}
if kind == "ready_for_commit":
    common.update({
        "base_sha": base,
        "head_sha": tip,
        "changed_files": ["feature.txt"],
        "commit_message": "feat: add feature",
        "verification": [{"command": "test -f feature.txt", "exit_code": 0, "output": "ok"}],
        "deviations": [],
        "risks": [],
    })
elif kind == "blocked":
    common.update({
        "work_in_progress": "Implemented the parser but stopped before choosing persistence semantics.",
        "question": "Should empty input be rejected?",
        "options": ["Reject it", "Treat it as an empty document"],
        "recommendation": "Reject it",
    })
elif kind == "failed":
    common.update({
        "error": "Required compiler terminated unexpectedly.",
        "work_in_progress": "The failing test exists; no implementation was committed.",
    })
elif kind == "completed":
    common.update({
        "base_sha": base,
        "commit_sha": tip,
        "changed_files": ["feature.txt"],
        "verification": [{"command": "test -f feature.txt", "exit_code": 0, "output": "ok"}],
        "deviations": [],
        "risks": [],
    })
else:
    raise SystemExit("unsupported fixture kind")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(common, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
}

record_outcome() {
  python3 "$OUTCOME" record \
    --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
    --task-id "$TASK_ID" --turn-id "$TURN_ID" --outcome-file "$INPUT"
}

reopen_task() {
  python3 "$OUTCOME" reopen \
    --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
    --task-id "$TASK_ID" --parent-worktree "$PARENT" \
    --expected-generation 1
}

setup_reopen_case() {
  local root="$1"
  setup_case "$root"

  # Preserve one valid historical outcome so reopen must retain the immutable
  # ledger and rotate only the live generation/nonce authority.
  write_outcome "$INPUT" blocked
  record_outcome >/dev/null
  HISTORICAL_DIGEST="$(tr -d '\n' < "$CONTROL/tasks/$TASK_ID/latest-outcome")"
  HISTORICAL_EVENT="$CONTROL/tasks/$TASK_ID/outcomes/$HISTORICAL_DIGEST.json"
  HISTORICAL_SNAPSHOT="$(stat -f '%d:%i:%m:%z' "$HISTORICAL_EVENT")"

  printf 'feature\n' > "$CHILD/feature.txt"
  git -C "$CHILD" add feature.txt
  git -C "$CHILD" commit -qm 'task-a generation one'
  CHILD_TIP="$(git -C "$CHILD" rev-parse HEAD)"
  PARENT="$root/parent"
  git -C "$REPO" worktree add -qb orc/mission "$PARENT" "$BASE_SHA"
  git -C "$PARENT" merge -q --no-ff -m 'integrate task-a generation one' "$CHILD_TIP"
  INTEGRATED_SHA="$(git -C "$PARENT" rev-parse HEAD)"

  printf '%s\n' "$TASK_DIR" > "$CONTROL/tasks/$TASK_ID/task-state-dir"
  printf '%s\n' "$THREAD_ID" > "$TASK_DIR/accepted-thread-id"
  printf '1\n' > "$TASK_DIR/generation"
  printf '%s\n' "$CHILD" > "$CONTROL/tasks/$TASK_ID/sandbox-root"
  printf '%s\n' "$CHILD" > "$TASK_DIR/sandbox-root"
  printf 'unarchived\n' > "$CONTROL/tasks/$TASK_ID/task-window-state"
  printf '%s\n' "$PARENT" > "$CONTROL/tasks/$TASK_ID/parent-worktree"
  printf '%s\n' "$BASE_SHA" > "$CONTROL/tasks/$TASK_ID/parent_tip_before"
  printf '%s\n' "$CHILD_TIP" > "$CONTROL/tasks/$TASK_ID/child_tip"
  printf '%s\n' "$INTEGRATED_SHA" > "$CONTROL/tasks/$TASK_ID/integrated_sha"
  printf 'integrated\n' > "$CONTROL/tasks/$TASK_ID/state"
  printf 'integrated\n' > "$TASK_DIR/state"
}

READY="$TMP/ready"
setup_case "$READY"
printf 'feature\n' > "$CHILD/feature.txt"
write_outcome "$INPUT" ready_for_commit
BEFORE_STATUS="$(git -C "$CHILD" status --porcelain --untracked-files=all)"
record_outcome > "$READY/record.out" 2> "$READY/record.err"
READY_RC=$?
check "ready_for_commit is accepted from the exact thread generation and nonce" test "$READY_RC" -eq 0
check "ready_for_commit is persisted as one content-addressed coordinator event" python3 - \
  "$CONTROL/tasks/$TASK_ID" "$THREAD_ID" "$TURN_ID" <<'PY'
import hashlib, json, os, re, stat, sys
task, thread, turn = sys.argv[1:]
latest = os.path.join(task, "latest-outcome")
digest = open(latest, encoding="ascii").read()
ok = re.fullmatch(r"[0-9a-f]{64}\n", digest) is not None
digest = digest.rstrip("\n")
event = os.path.join(task, "outcomes", digest + ".json")
if ok:
    metadata = os.lstat(event)
    raw = open(event, "rb").read()
    wrapper = json.loads(raw)
    ok = stat.S_ISREG(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode)
    ok = ok and hashlib.sha256(raw).hexdigest() == digest
    ok = ok and set(wrapper) == {"accepted_thread_id", "outcome", "turn_id"}
    ok = ok and wrapper["accepted_thread_id"] == thread and wrapper["turn_id"] == turn
    ok = ok and wrapper["outcome"]["kind"] == "ready_for_commit"
raise SystemExit(0 if ok else 1)
PY
check "ready outcome advances matching coordinator and task states" bash -c \
  '[[ "$(cat "$1")" = ready_for_commit && "$(cat "$2")" = ready_for_commit ]]' \
  _ "$CONTROL/tasks/$TASK_ID/state" "$TASK_DIR/state"
check "ready outcome publishes one exact coordinator-bound broker request" python3 - \
  "$TASK_DIR" "$TASK_ID" "$THREAD_ID" "$NONCE" "$BASE_SHA" <<'PY'
import glob, json, os, re, sys
task_dir, task, thread, nonce, base = sys.argv[1:]
paths = glob.glob(os.path.join(task_dir, "COMMIT-REQUEST-*.json"))
ok = len(paths) == 1
if ok:
    request = json.load(open(paths[0], encoding="utf-8"))
    ok = set(request) == {
        "protocol_version", "task_id", "generation", "accepted_thread_id",
        "outcome_nonce", "outcome_digest", "base_sha", "diff_sha256", "worktree", "paths", "message",
    }
    ok = ok and request["protocol_version"] == 1 and request["task_id"] == task
    ok = ok and request["generation"] == 1 and request["accepted_thread_id"] == thread
    ok = ok and request["outcome_nonce"] == nonce and request["base_sha"] == base
    ok = ok and os.path.basename(paths[0]) == f"COMMIT-REQUEST-{request['outcome_digest']}.json"
    ok = ok and request["paths"] == ["feature.txt"]
    ok = ok and re.fullmatch(r"[0-9a-f]{64}", request["diff_sha256"]) is not None
raise SystemExit(0 if ok else 1)
PY
check "outcome import writes nothing into the child worktree" bash -c \
  '[[ "$1" = "$(git -C "$2" status --porcelain --untracked-files=all)" ]] &&
   [[ ! -e "$2/native-writable-root-receipt" && ! -e "$2/outcome.json" && ! -e "$2/.orchestrator" ]]' \
  _ "$BEFORE_STATUS" "$CHILD"

READY_DIGEST="$(tr -d '\n' < "$CONTROL/tasks/$TASK_ID/latest-outcome")"
READY_EVENT="$CONTROL/tasks/$TASK_ID/outcomes/$READY_DIGEST.json"
CONTROL_SNAPSHOT="$(stat -f '%d:%i:%m:%z' "$READY_EVENT")"
LATEST_SNAPSHOT="$(stat -f '%d:%i:%m:%z' "$CONTROL/tasks/$TASK_ID/latest-outcome")"
record_outcome > "$READY/replay.out" 2> "$READY/replay.err"
REPLAY_RC=$?
check "an exact outcome replay is idempotent" bash -c \
  '[[ "$1" -eq 0 && "$2" = "$(stat -f '\''%d:%i:%m:%z'\'' "$4")" && "$3" = "$(stat -f '\''%d:%i:%m:%z'\'' "$5")" && "$(find "$6" -type f | wc -l | tr -d " ")" = 1 ]]' \
  _ "$REPLAY_RC" "$CONTROL_SNAPSHOT" "$LATEST_SNAPSHOT" \
  "$READY_EVENT" "$CONTROL/tasks/$TASK_ID/latest-outcome" "$CONTROL/tasks/$TASK_ID/outcomes"

python3 - "$INPUT" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["commit_message"] = "feat: conflicting replay"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
record_outcome > "$READY/conflict.out" 2> "$READY/conflict.err"
CONFLICT_RC=$?
check "a conflicting replay fails without replacing accepted authority" bash -c \
  '[[ "$1" -ne 0 && "$2" = "$(stat -f '\''%d:%i:%m:%z'\'' "$3")" && "$(cat "$4")" = "$5" && "$(find "$6" -type f | wc -l | tr -d " ")" = 1 ]]' \
  _ "$CONFLICT_RC" "$CONTROL_SNAPSHOT" "$READY_EVENT" \
  "$CONTROL/tasks/$TASK_ID/latest-outcome" "$READY_DIGEST" "$CONTROL/tasks/$TASK_ID/outcomes"

BROKER_RACE="$TMP/broker-race"
setup_case "$BROKER_RACE"
printf 'race-safe feature\n' > "$CHILD/feature.txt"
write_outcome "$INPUT" ready_for_commit
ORC_TASK_OUTCOME_TEST_FAIL_AFTER_BROKER_REQUEST=1 \
  record_outcome > "$BROKER_RACE/first.out" 2> "$BROKER_RACE/first.err"
BROKER_RACE_IMPORT_RC=$?
BROKER_RACE_BEFORE="$(git -C "$CHILD" rev-parse HEAD)"
"$BROKER" --mission-dir "$TASK_DIR" --control-dir "$CONTROL/tasks/$TASK_ID" --once \
  > "$BROKER_RACE/early-broker.out" 2> "$BROKER_RACE/early-broker.err"
BROKER_RACE_EARLY_RC=$?
check "resident broker cannot consume a request while outcome intent is unresolved" bash -c \
  '[[ "$1" -ne 0 && "$2" -eq 0 && "$(git -C "$3" rev-parse HEAD)" = "$4" &&
     -s "$5/.outcome-intent.json" &&
     "$(find "$6" -maxdepth 1 \( -name "COMMIT-DONE-*.json" -o -name "COMMIT-REJECTED-*.json" \) | wc -l | tr -d " ")" = 0 ]]' \
  _ "$BROKER_RACE_IMPORT_RC" "$BROKER_RACE_EARLY_RC" "$CHILD" "$BROKER_RACE_BEFORE" \
  "$CONTROL/tasks/$TASK_ID" "$TASK_DIR"
record_outcome > "$BROKER_RACE/retry.out" 2> "$BROKER_RACE/retry.err"
BROKER_RACE_RETRY_RC=$?
"$BROKER" --mission-dir "$TASK_DIR" --control-dir "$CONTROL/tasks/$TASK_ID" --once \
  > "$BROKER_RACE/final-broker.out" 2> "$BROKER_RACE/final-broker.err"
BROKER_RACE_FINAL_RC=$?
check "outcome retry clears intent before broker commits the exact request" bash -c \
  '[[ "$1" -eq 0 && "$2" -eq 0 && "$(git -C "$3" rev-parse HEAD)" != "$4" &&
     ! -e "$5/.outcome-intent.json" && "$(cat "$5/state")" = ready_for_commit &&
     "$(find "$6" -maxdepth 1 -name "COMMIT-DONE-*.json" | wc -l | tr -d " ")" = 1 ]]' \
  _ "$BROKER_RACE_RETRY_RC" "$BROKER_RACE_FINAL_RC" "$CHILD" "$BROKER_RACE_BEFORE" \
  "$CONTROL/tasks/$TASK_ID" "$TASK_DIR"

BLOCKED="$TMP/blocked"
setup_case "$BLOCKED"
write_outcome "$INPUT" blocked
record_outcome > "$BLOCKED/record.out" 2> "$BLOCKED/record.err"
BLOCKED_RC=$?
check "blocked outcome becomes durable coordinator-owned BLOCKED evidence" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = blocked && "$(cat "$3/state")" = blocked ]] &&
   grep -Fq "Should empty input be rejected?" "$3/BLOCKED-1.md" &&
   grep -Fq "Reject it" "$3/BLOCKED-1.md"' \
  _ "$BLOCKED_RC" "$CONTROL/tasks/$TASK_ID" "$TASK_DIR"

TURN_ID="turn-task-a-2"
python3 - "$INPUT" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["question"] = "Should whitespace-only input be rejected?"
data["work_in_progress"] = "The empty-input answer is implemented; whitespace remains unresolved."
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
record_outcome > "$BLOCKED/round-2.out" 2> "$BLOCKED/round-2.err"
BLOCKED_2_RC=$?
check "a later blocked turn preserves both immutable rounds" bash -c \
  '[[ "$1" -eq 0 && "$(find "$2/outcomes" -type f | wc -l | tr -d " ")" = 2 ]] &&
   grep -Fq "Should empty input be rejected?" "$3/BLOCKED-1.md" &&
   grep -Fq "Should whitespace-only input be rejected?" "$3/BLOCKED-2.md"' \
  _ "$BLOCKED_2_RC" "$CONTROL/tasks/$TASK_ID" "$TASK_DIR"

FAILED="$TMP/failed"
setup_case "$FAILED"
write_outcome "$INPUT" failed
record_outcome > "$FAILED/record.out" 2> "$FAILED/record.err"
FAILED_RC=$?
check "failed outcome preserves the error and work in progress" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = failed && "$(cat "$3/state")" = failed ]] &&
   grep -Fq "Required compiler terminated unexpectedly." "$3/report.md" &&
   grep -Fq "The failing test exists" "$3/report.md"' \
  _ "$FAILED_RC" "$CONTROL/tasks/$TASK_ID" "$TASK_DIR"

COMPLETED="$TMP/completed"
setup_case "$COMPLETED"
printf 'feature\n' > "$CHILD/feature.txt"
write_outcome "$INPUT" ready_for_commit
record_outcome > "$COMPLETED/ready.out" 2> "$COMPLETED/ready.err"
COMPLETED_READY_RC=$?
READY_DIGEST="$(tr -d '\n' < "$CONTROL/tasks/$TASK_ID/latest-outcome" 2>/dev/null || true)"
"$BROKER" --mission-dir "$TASK_DIR" \
  --control-dir "$CONTROL/tasks/$TASK_ID" --once >/dev/null 2>&1
BROKER_RC=$?
if ! compgen -G "$TASK_DIR/COMMIT-DONE-*.json" >/dev/null; then
  sed 's/^/  broker diagnostic: /' "$TASK_DIR"/COMMIT-REJECTED-*.json 2>/dev/null || true
fi
TIP_SHA="$(git -C "$CHILD" rev-parse HEAD)"
check "coordinator-generated request commits through the identity-bound broker" \
  test "$BROKER_RC" -eq 0
POST_BROKER_DIGEST="$(tr -d '\n' < "$CONTROL/tasks/$TASK_ID/latest-outcome")"
POST_BROKER_EVENT="$CONTROL/tasks/$TASK_ID/outcomes/$POST_BROKER_DIGEST.json"
POST_BROKER_EVENT_SNAPSHOT="$(stat -f '%d:%i:%m:%z' "$POST_BROKER_EVENT")"
record_outcome > "$COMPLETED/ready-replay-after-broker.out" \
  2> "$COMPLETED/ready-replay-after-broker.err"
POST_BROKER_REPLAY_RC=$?
check "exact ready outcome replay remains a no-op after broker commit" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = ready_for_commit &&
     "$(cat "$3/state")" = ready_for_commit && "$(cat "$2/latest-outcome")" = "$4" &&
     "$5" = "$(stat -f '\''%d:%i:%m:%z'\'' "$6")" &&
     "$(find "$2/outcomes" -type f | wc -l | tr -d " ")" = 1 ]]' \
  _ "$POST_BROKER_REPLAY_RC" "$CONTROL/tasks/$TASK_ID" "$TASK_DIR" \
  "$POST_BROKER_DIGEST" "$POST_BROKER_EVENT_SNAPSHOT" "$POST_BROKER_EVENT"
TURN_ID="turn-task-a-2"
write_outcome "$INPUT" completed
record_outcome > "$COMPLETED/unverified.out" 2> "$COMPLETED/unverified.err"
UNVERIFIED_COMPLETED_RC=$?
check "completed outcome requires coordinator-owned exact-tip verification" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/state")" = ready_for_commit && "$(cat "$3/state")" = ready_for_commit && "$(find "$2/outcomes" -type f | wc -l | tr -d " ")" = 1 ]]' \
  _ "$UNVERIFIED_COMPLETED_RC" "$CONTROL/tasks/$TASK_ID" "$TASK_DIR"
printf '%s\n' "$TIP_SHA" > "$CONTROL/tasks/$TASK_ID/coordinator-verification.sha"
printf 'coordinator reran frozen verification at %s\n' "$TIP_SHA" > "$CONTROL/tasks/$TASK_ID/coordinator-verification.md"
record_outcome > "$COMPLETED/record.out" 2> "$COMPLETED/record.err"
COMPLETED_RC=$?
check "completed outcome binds the exact brokered commit tip" bash -c \
  '[[ "$1" -eq 0 && "$2" -eq 0 && "$(cat "$3/state")" = completed && "$(cat "$4/state")" = completed && "$(cat "$4/verification.sha")" = "$5" ]]' \
  _ "$COMPLETED_READY_RC" "$COMPLETED_RC" "$CONTROL/tasks/$TASK_ID" "$TASK_DIR" "$TIP_SHA"
check "completed outcome renders durable report evidence" bash -c \
  'grep -Fq "$2" "$1/report.md" && grep -Fq "feature.txt" "$1/report.md" && grep -Fq "test -f feature.txt" "$1/report.md"' \
  _ "$TASK_DIR" "$TIP_SHA"
check "ready to completed transition advances latest without losing history" bash -c \
  '[[ -n "$1" && "$(cat "$2")" != "$1" && "$(find "$3" -type f | wc -l | tr -d " ")" = 2 ]]' \
  _ "$READY_DIGEST" "$CONTROL/tasks/$TASK_ID/latest-outcome" "$CONTROL/tasks/$TASK_ID/outcomes"

COLLECTED_REPLAY="$TMP/collected-replay"
setup_case "$COLLECTED_REPLAY"
write_outcome "$INPUT" blocked
record_outcome > "$COLLECTED_REPLAY/record.out" 2> "$COLLECTED_REPLAY/record.err"
COLLECTED_INITIAL_RC=$?
COLLECTED_DIGEST="$(tr -d '\n' < "$CONTROL/tasks/$TASK_ID/latest-outcome")"
COLLECTED_EVENT="$CONTROL/tasks/$TASK_ID/outcomes/$COLLECTED_DIGEST.json"
COLLECTED_EVENT_SNAPSHOT="$(stat -f '%d:%i:%m:%z' "$COLLECTED_EVENT")"
git -C "$REPO" worktree remove --force "$CHILD" >/dev/null 2>&1
git -C "$REPO" branch -D "orc-task/mission/$TASK_ID" >/dev/null 2>&1
record_outcome > "$COLLECTED_REPLAY/replay.out" 2> "$COLLECTED_REPLAY/replay.err"
COLLECTED_REPLAY_RC=$?
check "exact historical outcome replay is a no-op after native worktree collection" bash -c \
  '[[ "$1" -eq 0 && "$2" -eq 0 && ! -e "$3" &&
     "$(cat "$4/state")" = blocked && "$(cat "$5/state")" = blocked &&
     "$(cat "$4/latest-outcome")" = "$6" &&
     "$7" = "$(stat -f '\''%d:%i:%m:%z'\'' "$8")" &&
     "$(find "$4/outcomes" -type f | wc -l | tr -d " ")" = 1 ]]' \
  _ "$COLLECTED_INITIAL_RC" "$COLLECTED_REPLAY_RC" "$CHILD" \
  "$CONTROL/tasks/$TASK_ID" "$TASK_DIR" "$COLLECTED_DIGEST" \
  "$COLLECTED_EVENT_SNAPSHOT" "$COLLECTED_EVENT"

stale_case() {
  local label="$1" field="$2" value="$3" root="$TMP/stale-$1"
  setup_case "$root"
  printf 'feature\n' > "$CHILD/feature.txt"
  write_outcome "$INPUT" ready_for_commit
  python3 - "$INPUT" "$field" "$value" <<'PY'
import json, sys
path, field, value = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
data[field] = int(value) if field == "generation" else value
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
  record_outcome > "$root/record.out" 2> "$root/record.err"
  local rc=$?
  check "$label is rejected before durable outcome publication" bash -c \
    '[[ "$1" -ne 0 && "$(cat "$2/state")" = running && "$(cat "$3/state")" = running && ! -e "$2/latest-outcome" && ! -e "$2/outcomes" ]]' \
    _ "$rc" "$CONTROL/tasks/$TASK_ID" "$TASK_DIR"
}

stale_case "stale accepted thread" accepted_thread_id thread-stale
stale_case "stale generation" generation 2
stale_case "stale outcome nonce" outcome_nonce nonce-stale-0123456789abcdef
stale_case "wrong base SHA" base_sha "$ROOT_SHA"
stale_case "wrong head SHA" head_sha 0000000000000000000000000000000000000000

MALFORMED="$TMP/malformed"
setup_case "$MALFORMED"
printf 'feature\n' > "$CHILD/feature.txt"
write_outcome "$INPUT" ready_for_commit
python3 - "$INPUT" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["unexpected"] = True
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
record_outcome > "$MALFORMED/record.out" 2> "$MALFORMED/record.err"
MALFORMED_RC=$?
check "unknown envelope keys fail closed" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2/latest-outcome" && ! -e "$2/outcomes" ]]' \
  _ "$MALFORMED_RC" "$CONTROL/tasks/$TASK_ID" "$TASK_DIR"

UNSAFE="$TMP/unsafe-path"
setup_case "$UNSAFE"
printf 'feature\n' > "$CHILD/feature.txt"
write_outcome "$INPUT" ready_for_commit
python3 - "$INPUT" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["changed_files"] = ["../escape"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
record_outcome > "$UNSAFE/record.out" 2> "$UNSAFE/record.err"
UNSAFE_RC=$?
check "unsafe changed-file paths fail closed" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2/latest-outcome" && ! -e "$2/outcomes" ]]' \
  _ "$UNSAFE_RC" "$CONTROL/tasks/$TASK_ID" "$TASK_DIR"

REOPEN="$TMP/reopen"
setup_reopen_case "$REOPEN"
OLD_NONCE="$NONCE"
OLD_CHILD_PATH="$CHILD"
OLD_CHILD_TIP="$CHILD_TIP"
OLD_BRANCH="$(git -C "$CHILD" symbolic-ref --quiet --short HEAD)"
reopen_task > "$REOPEN/reopen.out" 2> "$REOPEN/reopen.err"
REOPEN_RC=$?
if [[ "$REOPEN_RC" -ne 0 ]]; then
  sed 's/^/  reopen diagnostic: /' "$REOPEN/reopen.err"
fi
NEW_NONCE="$(tr -d '\n' < "$CONTROL/tasks/$TASK_ID/outcome-nonce" 2>/dev/null || true)"
check "integrated retained child reopens one generation on the same worktree branch and thread" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/generation")" = 2 && "$(cat "$3/generation")" = 2 &&
     "$(cat "$2/state")" = ready && "$(cat "$3/state")" = ready &&
     "$(cat "$2/accepted-thread-id")" = "$4" && "$(cat "$3/accepted-thread-id")" = "$4" &&
     "$(cat "$2/task-window-state")" = unarchived && "$(cat "$2/sandbox-root")" = "$5" &&
     "$(cat "$3/sandbox-root")" = "$5" && "$(git -C "$5" rev-parse HEAD)" = "$6" &&
     "$(git -C "$5" symbolic-ref --quiet --short HEAD)" = "$7" ]]' \
  _ "$REOPEN_RC" "$CONTROL/tasks/$TASK_ID" "$TASK_DIR" "$THREAD_ID" \
  "$OLD_CHILD_PATH" "$OLD_CHILD_TIP" "$OLD_BRANCH"
check "reopen rotates a coordinator-only nonce, clears the current pointer, and retains the immutable outcome ledger" bash -c \
  '[[ "$1" =~ ^[0-9a-f]{64}$ && "$1" != "$2" && ! -e "$3/outcome-nonce" &&
     ! -e "$4/latest-outcome" && "$6" = "$(stat -f '\''%d:%i:%m:%z'\'' "$7")" &&
     "$(find "$4/outcomes" -type f | wc -l | tr -d " ")" = 1 ]]' \
  _ "$NEW_NONCE" "$OLD_NONCE" "$TASK_DIR" "$CONTROL/tasks/$TASK_ID" \
  "$HISTORICAL_DIGEST" "$HISTORICAL_SNAPSHOT" "$HISTORICAL_EVENT"
check "reopen publishes one durable generation-bound completion receipt" python3 - \
  "$CONTROL/tasks/$TASK_ID/rework-completion-2.json" "$THREAD_ID" "$NEW_NONCE" \
  "$INTEGRATED_SHA" "$CHILD_TIP" <<'PY'
import json, os, re, stat, sys
path, thread, nonce, integrated, child = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
ok = set(data) == {
    "accepted_thread_id", "intent_sha256", "kind", "new_generation",
    "old_generation", "outcome_nonce", "prior_child_tip",
    "prior_integrated_sha", "previous_latest", "protocol_version", "task_id",
}
ok = ok and data["protocol_version"] == 1 and data["kind"] == "rework_reopened"
ok = ok and data["old_generation"] == 1 and data["new_generation"] == 2
ok = ok and data["accepted_thread_id"] == thread and data["outcome_nonce"] == nonce
ok = ok and data["prior_integrated_sha"] == integrated and data["prior_child_tip"] == child
ok = ok and re.fullmatch(r"[0-9a-f]{64}", data["previous_latest"]) is not None
ok = ok and re.fullmatch(r"[0-9a-f]{64}", data["intent_sha256"]) is not None
metadata = os.lstat(path)
ok = ok and stat.S_ISREG(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode)
raise SystemExit(0 if ok else 1)
PY

REOPEN_SNAPSHOT="$(stat -f '%d:%i:%m:%z' "$CONTROL/tasks/$TASK_ID/rework-completion-2.json")"
reopen_task > "$REOPEN/replay.out" 2> "$REOPEN/replay.err"
REOPEN_REPLAY_RC=$?
check "exact reopen retry is an idempotent no-op" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/generation")" = 2 && "$(cat "$2/outcome-nonce")" = "$3" &&
     "$4" = "$(stat -f '\''%d:%i:%m:%z'\'' "$5")" && ! -e "$2/.rework-intent.json" ]]' \
  _ "$REOPEN_REPLAY_RC" "$CONTROL/tasks/$TASK_ID" "$NEW_NONCE" \
  "$REOPEN_SNAPSHOT" "$CONTROL/tasks/$TASK_ID/rework-completion-2.json"

# A delayed generation-one result from the same native child must fail after
# reopen; a generation-two result with the refreshed nonce remains valid.
TURN_ID="turn-task-a-delayed-generation-one"
write_outcome "$INPUT" blocked
record_outcome > "$REOPEN/stale.out" 2> "$REOPEN/stale.err"
STALE_REWORK_RC=$?
check "delayed pre-rework outcome is rejected by rotated generation authority" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/state")" = ready && "$(cat "$3/state")" = ready &&
     "$(find "$2/outcomes" -type f | wc -l | tr -d " ")" = 1 ]]' \
  _ "$STALE_REWORK_RC" "$CONTROL/tasks/$TASK_ID" "$TASK_DIR"
python3 - "$INPUT" "$NEW_NONCE" <<'PY'
import json, sys
path, nonce = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
data["generation"] = 2
data["outcome_nonce"] = nonce
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
TURN_ID="turn-task-a-generation-two"
record_outcome > "$REOPEN/current.out" 2> "$REOPEN/current.err"
CURRENT_REWORK_RC=$?
check "same accepted thread can publish a refreshed generation-two outcome" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/state")" = blocked && "$(cat "$3/state")" = blocked &&
     "$(find "$2/outcomes" -type f | wc -l | tr -d " ")" = 2 ]]' \
  _ "$CURRENT_REWORK_RC" "$CONTROL/tasks/$TASK_ID" "$TASK_DIR"

REOPEN_CRASH="$TMP/reopen-crash"
setup_reopen_case "$REOPEN_CRASH"
OLD_NONCE="$NONCE"
ORC_TASK_OUTCOME_TEST_FAIL_REOPEN_AFTER_FIRST_AUTHORITY=1 \
  reopen_task > "$REOPEN_CRASH/first.out" 2> "$REOPEN_CRASH/first.err"
REOPEN_INTERRUPTED_RC=$?
TURN_ID="turn-task-a-during-rework-recovery"
write_outcome "$INPUT" blocked
record_outcome > "$REOPEN_CRASH/delayed.out" 2> "$REOPEN_CRASH/delayed.err"
UNRESOLVED_REWORK_OUTCOME_RC=$?
check "interrupted reopen preserves durable intent and blocks outcome publication" bash -c \
  '[[ "$1" -ne 0 && "$2" -ne 0 && -s "$3/.rework-intent.json" &&
     ! -e "$3/rework-completion-2.json" && "$(find "$3/outcomes" -type f | wc -l | tr -d " ")" = 1 ]] &&
   grep -Fq "rework" "$4"' \
  _ "$REOPEN_INTERRUPTED_RC" "$UNRESOLVED_REWORK_OUTCOME_RC" \
  "$CONTROL/tasks/$TASK_ID" "$REOPEN_CRASH/delayed.err"
reopen_task > "$REOPEN_CRASH/recovery.out" 2> "$REOPEN_CRASH/recovery.err"
REOPEN_RECOVERY_RC=$?
RECOVERED_NONCE="$(tr -d '\n' < "$CONTROL/tasks/$TASK_ID/outcome-nonce" 2>/dev/null || true)"
check "exact reopen retry recovers mixed authority to one generation and nonce" bash -c \
  '[[ "$1" -eq 0 && ! -e "$2/.rework-intent.json" && -s "$2/rework-completion-2.json" &&
     "$(cat "$2/generation")" = 2 && "$(cat "$3/generation")" = 2 &&
     "$(cat "$2/state")" = ready && "$(cat "$3/state")" = ready &&
     "$4" =~ ^[0-9a-f]{64}$ && "$4" != "$5" ]]' \
  _ "$REOPEN_RECOVERY_RC" "$CONTROL/tasks/$TASK_ID" "$TASK_DIR" \
  "$RECOVERED_NONCE" "$OLD_NONCE"

reopen_rejected_case() {
  local label="$1" mutation="$2" root="$TMP/reopen-reject-${1// /-}"
  setup_reopen_case "$root"
  eval "$mutation"
  reopen_task > "$root/reopen.out" 2> "$root/reopen.err"
  local rc=$?
  check "$label rejects reopen without rotating generation or nonce" bash -c \
    '[[ "$1" -ne 0 && "$(cat "$2/generation")" = 1 && "$(cat "$2/outcome-nonce")" = "$3" &&
       ! -e "$2/.rework-intent.json" && ! -e "$2/rework-completion-2.json" ]]' \
    _ "$rc" "$CONTROL/tasks/$TASK_ID" "$NONCE"
}

reopen_rejected_case "archived child window" \
  'printf "archived\n" > "$CONTROL/tasks/$TASK_ID/task-window-state"'
reopen_rejected_case "mismatched task-state directory" \
  'printf "%s\n" "$TMP/not-the-task-dir" > "$CONTROL/tasks/$TASK_ID/task-state-dir"'
reopen_rejected_case "dirty retained child" \
  'printf "dirty\n" > "$CHILD/uncommitted.txt"'
reopen_rejected_case "different worker thread" \
  'printf "thread-other\n" > "$TASK_DIR/accepted-thread-id"'
reopen_rejected_case "parent missing recorded integration" \
  'git -C "$PARENT" reset -q --hard "$BASE_SHA"'

echo "  task-outcome: $OK/$N"
[[ "$OK" -eq "$N" ]]
