#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT="$ROOT/scripts/codex-task-client.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/orc-codex-task-client.XXXXXX")"
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

FAKE="$TMP/fake-app-server.py"
cat > "$FAKE" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

log_path = os.environ["ORC_FAKE_APP_SERVER_LOG"]
missing = os.environ.get("ORC_FAKE_THREAD_MISSING") == "1"
stale = os.environ.get("ORC_FAKE_STALE_OUTCOME") == "1"
running = os.environ.get("ORC_FAKE_THREAD_RUNNING") == "1"

def emit(payload):
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()

with open(log_path, "a", encoding="utf-8") as log:
    for raw in sys.stdin:
        message = json.loads(raw)
        log.write(json.dumps(message, sort_keys=True) + "\n")
        log.flush()
        method = message.get("method")
        request_id = message.get("id")
        if method == "initialize":
            emit({"id": request_id, "result": {"userAgent": "fake"}})
        elif method == "initialized":
            continue
        elif method == "thread/list":
            if message["params"].get("cursor") is None:
                emit({"id": request_id, "result": {"data": [{"id": "thr_other"}], "nextCursor": "page-2"}})
            else:
                data = [] if missing else [{"id": "thr_visible", "title": "ORC Visible Task"}]
                emit({"id": request_id, "result": {"data": data, "nextCursor": None}})
        elif method == "thread/read":
            final = 'ORC_TASK_OUTCOME_V1\n{"protocol_version":1,"kind":"blocked","task_id":"task-a","generation":1,"accepted_thread_id":"thr_visible","outcome_nonce":"nonce-task-a","work_in_progress":"parser done","question":"Choose mode?","options":["A","B"],"recommendation":"A"}'
            turns = [{"id": "turn_1", "status": "completed", "items": [{"type": "agentMessage", "text": "secret-child-transcript"}, {"type": "agentMessage", "text": final}]}] if message["params"].get("includeTurns") else []
            if stale and turns:
                turns.append({"id": "turn_2", "status": "completed", "items": [{"type": "agentMessage", "text": "newer turn without envelope"}]})
            thread_status = {"type": "inProgress" if running else "idle"}
            emit({"id": request_id, "result": {"thread": {"id": message["params"]["threadId"], "title": "ORC Visible Task", "cwd": "/native/worktree", "projectId": None, "status": thread_status, "turns": turns}}})
        elif method in ("thread/archive", "thread/unarchive"):
            emit({"id": request_id, "result": {"thread": {"id": message["params"]["threadId"]}}})
        elif method == "turn/interrupt":
            emit({"id": request_id, "result": {}})
PY
chmod +x "$FAKE"

for removed in create bind-project resume; do
  python3 "$CLIENT" "$removed" >/dev/null 2> "$TMP/$removed.err"
  check "$removed execution operation is absent" test "$?" -ne 0
done

for operation in inspect archive unarchive outcome; do
  operation_args=(--thread-id thr_visible)
  if [[ "$operation" == outcome ]]; then
    operation_args+=(--turn-id turn_1)
  fi
  ORC_CODEX_APP_SERVER_COMMAND="$FAKE" \
  ORC_FAKE_APP_SERVER_LOG="$TMP/$operation.log" \
    python3 "$CLIENT" "$operation" "${operation_args[@]}" \
      > "$TMP/$operation.out" 2> "$TMP/$operation.err"
  check "$operation lifecycle bridge succeeds" test "$?" -eq 0
done

check "inspect initializes the 0.5.4 lifecycle bridge" python3 - "$TMP/inspect.log" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
methods = [row.get("method") for row in rows]
params = next(row["params"] for row in rows if row.get("method") == "initialize")
ok = methods[:4] == ["initialize", "initialized", "thread/list", "thread/list"]
ok = ok and params.get("clientInfo", {}).get("version") == "0.5.4"
raise SystemExit(0 if ok else 1)
PY
check "inspect verifies list visibility before exact read" python3 - "$TMP/inspect.log" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
methods = [row.get("method") for row in rows]
lists = [row for row in rows if row.get("method") == "thread/list"]
read = next(row["params"] for row in rows if row.get("method") == "thread/read")
ok = len(lists) == 2 and lists[1]["params"].get("cursor") == "page-2"
ok = ok and methods.index("thread/list") < methods.index("thread/read")
ok = ok and read == {"threadId": "thr_visible", "includeTurns": False}
raise SystemExit(0 if ok else 1)
PY
check "inspect emits only bounded metadata without child turns" python3 - "$TMP/inspect.out" <<'PY'
import json, sys
data = json.loads(open(sys.argv[1], encoding="utf-8").read())
expected = {
    "type": "thread.inspected",
    "thread_id": "thr_visible",
    "title": "ORC Visible Task",
    "cwd": "/native/worktree",
    "status": {"type": "idle"},
    "project_id": None,
}
raise SystemExit(0 if data == expected and "secret-child-transcript" not in repr(data) else 1)
PY
check "archive bridge calls thread/archive" grep -Fq '"method": "thread/archive"' "$TMP/archive.log"
check "unarchive bridge calls thread/unarchive" grep -Fq '"method": "thread/unarchive"' "$TMP/unarchive.log"
check "outcome reads bounded terminal turns" python3 - "$TMP/outcome.log" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
read = next(row["params"] for row in rows if row.get("method") == "thread/read")
raise SystemExit(0 if read == {"threadId": "thr_visible", "includeTurns": True} else 1)
PY
check "outcome emits only the exact terminal envelope and turn identity" python3 - "$TMP/outcome.out" <<'PY'
import json, sys
data = json.loads(open(sys.argv[1], encoding="utf-8").read())
ok = data.get("type") == "task.outcome" and data.get("thread_id") == "thr_visible"
ok = ok and data.get("turn_id") == "turn_1" and data.get("outcome", {}).get("kind") == "blocked"
ok = ok and "secret-child-transcript" not in repr(data)
raise SystemExit(0 if ok else 1)
PY

ORC_CODEX_APP_SERVER_COMMAND="$FAKE" ORC_FAKE_STALE_OUTCOME=1 \
ORC_FAKE_APP_SERVER_LOG="$TMP/stale-outcome.log" \
  python3 "$CLIENT" outcome --thread-id thr_visible --turn-id turn_2 \
    >"$TMP/stale-outcome.out" 2>"$TMP/stale-outcome.err"
check "outcome never falls back to an older completed turn envelope" test "$?" -ne 0

ORC_CODEX_APP_SERVER_COMMAND="$FAKE" ORC_FAKE_STALE_OUTCOME=1 \
ORC_FAKE_APP_SERVER_LOG="$TMP/old-turn.log" \
  python3 "$CLIENT" outcome --thread-id thr_visible --turn-id turn_1 \
    >"$TMP/old-turn.out" 2>"$TMP/old-turn.err"
check "outcome rejects an explicitly requested turn when a newer turn exists" test "$?" -ne 0

ORC_CODEX_APP_SERVER_COMMAND="$FAKE" ORC_FAKE_THREAD_RUNNING=1 \
ORC_FAKE_APP_SERVER_LOG="$TMP/running-outcome.log" \
  python3 "$CLIENT" outcome --thread-id thr_visible --turn-id turn_1 \
    >"$TMP/running-outcome.out" 2>"$TMP/running-outcome.err"
check "outcome refuses a still-running thread" test "$?" -ne 0

ORC_CODEX_APP_SERVER_COMMAND="$FAKE" ORC_FAKE_APP_SERVER_LOG="$TMP/stop.log" \
  python3 "$CLIENT" stop --thread-id thr_visible --turn-id turn_1 \
    > "$TMP/stop.out" 2> "$TMP/stop.err"
check "stop bridge interrupts the exact turn" grep -Fq '"method": "turn/interrupt"' "$TMP/stop.log"

ORC_CODEX_APP_SERVER_COMMAND="$FAKE" ORC_FAKE_THREAD_MISSING=1 \
ORC_FAKE_APP_SERVER_LOG="$TMP/missing.log" \
  python3 "$CLIENT" inspect --thread-id thr_visible >/dev/null 2> "$TMP/missing.err"
check "inspect fails closed when task is not list-visible" test "$?" -ne 0

check "lifecycle bridge never starts resumes or executes a thread" python3 - "$TMP" <<'PY'
import json, pathlib, sys
forbidden = {"thread/start", "thread/resume", "turn/start", "project/list", "project/create"}
methods = set()
for path in pathlib.Path(sys.argv[1]).glob("*.log"):
    for line in path.read_text(encoding="utf-8").splitlines():
        methods.add(json.loads(line).get("method"))
raise SystemExit(0 if forbidden.isdisjoint(methods) else 1)
PY

printf 'codex task client: %s/%s passed\n' "$OK" "$N"
[[ "$OK" -eq "$N" ]]
