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
failure = os.environ.get("ORC_FAKE_APP_SERVER_FAIL", "")

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
        elif method == "thread/start":
            if failure == "thread-start":
                emit({"id": request_id, "error": {"code": -32000, "message": "injected thread failure"}})
                break
            emit({"id": request_id, "result": {"thread": {"id": "thr_visible", "sessionId": "thr_visible", "ephemeral": False}}})
            emit({"method": "thread/started", "params": {"thread": {"id": "thr_visible"}}})
        elif method == "thread/resume":
            emit({"id": request_id, "result": {"thread": {"id": message["params"]["threadId"], "ephemeral": False}}})
        elif method == "thread/name/set":
            emit({"id": request_id, "result": {}})
        elif method == "turn/start":
            emit({"id": request_id, "result": {"turn": {"id": "turn_1", "status": "inProgress"}}})
            emit({"method": "turn/started", "params": {"threadId": message["params"]["threadId"], "turn": {"id": "turn_1", "status": "inProgress"}}})
            emit({"method": "item/agentMessage/delta", "params": {"threadId": message["params"]["threadId"], "turnId": "turn_1", "delta": "started"}})
            emit({"method": "turn/completed", "params": {"threadId": message["params"]["threadId"], "turn": {"id": "turn_1", "status": "completed"}}})
            break
PY
chmod +x "$FAKE"

WORKTREE="$TMP/worktree"
TASK_DIR="$TMP/task-state"
mkdir -p "$WORKTREE" "$TASK_DIR"
WORKTREE="$(cd "$WORKTREE" && pwd -P)"
TASK_DIR="$(cd "$TASK_DIR" && pwd -P)"
printf 'Read the frozen task brief and do no broader work.\n' > "$TMP/prompt.md"

CREATE_LOG="$TMP/create.log"
CREATE_OUT="$TMP/create.out"
ORC_CODEX_APP_SERVER_COMMAND="$FAKE" \
ORC_FAKE_APP_SERVER_LOG="$CREATE_LOG" \
  python3 "$CLIENT" create \
    --cwd "$WORKTREE" \
    --task-dir "$TASK_DIR" \
    --project-id project-visible \
    --title 'ORC Visible Task' \
    --model gpt-5.6-sol \
    --effort high \
    --prompt-file "$TMP/prompt.md" > "$CREATE_OUT" 2> "$TMP/create.err"
CREATE_RC=$?

check "create client exits successfully" test "$CREATE_RC" -eq 0
check "create emits the durable visible thread id" \
  grep -Fq '"type":"thread.started","thread_id":"thr_visible"' "$CREATE_OUT"
check "create emits normal turn completion" \
  grep -Fq '"type":"turn.completed","thread_id":"thr_visible","turn_id":"turn_1","status":"completed"' "$CREATE_OUT"
check "create performs initialize before thread start" python3 - "$CREATE_LOG" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
methods = [row.get("method") for row in rows]
raise SystemExit(0 if methods[:3] == ["initialize", "initialized", "thread/start"] else 1)
PY
check "App Server client identifies the 0.4.4 plugin release" python3 - "$CREATE_LOG" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
params = next(row["params"] for row in rows if row.get("method") == "initialize")
raise SystemExit(0 if params.get("clientInfo", {}).get("version") == "0.4.4" else 1)
PY
check "thread start binds exact project cwd roots model and visible source" python3 - "$CREATE_LOG" "$WORKTREE" "$TASK_DIR" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
params = next(row["params"] for row in rows if row.get("method") == "thread/start")
expected = {
    "cwd": sys.argv[2],
    "projectId": "project-visible",
    "runtimeWorkspaceRoots": [sys.argv[2], sys.argv[3]],
    "model": "gpt-5.6-sol",
    "sandbox": "workspace-write",
    "threadSource": "orchestrator-child",
    "historyMode": "paginated",
}
raise SystemExit(0 if all(params.get(key) == value for key, value in expected.items()) else 1)
PY
check "thread title is set before the implementation turn" python3 - "$CREATE_LOG" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
methods = [row.get("method") for row in rows]
name = next(row["params"] for row in rows if row.get("method") == "thread/name/set")
ok = name == {"threadId": "thr_visible", "name": "ORC Visible Task"}
ok = ok and methods.index("thread/name/set") < methods.index("turn/start")
raise SystemExit(0 if ok else 1)
PY
check "turn start carries high effort prompt and exact workspace-write policy" python3 - "$CREATE_LOG" "$WORKTREE" "$TASK_DIR" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
params = next(row["params"] for row in rows if row.get("method") == "turn/start")
policy = params.get("sandboxPolicy", {})
ok = params.get("threadId") == "thr_visible"
ok = ok and params.get("cwd") == sys.argv[2]
ok = ok and params.get("runtimeWorkspaceRoots") == [sys.argv[2], sys.argv[3]]
ok = ok and params.get("model") == "gpt-5.6-sol" and params.get("effort") == "high"
ok = ok and params.get("input") == [{"type": "text", "text": "Read the frozen task brief and do no broader work.\n"}]
ok = ok and policy == {
    "type": "workspaceWrite",
    "writableRoots": [sys.argv[3]],
    "networkAccess": False,
    "excludeSlashTmp": True,
    "excludeTmpdirEnvVar": True,
}
raise SystemExit(0 if ok else 1)
PY

NO_PROJECT_LOG="$TMP/no-project.log"
ORC_CODEX_APP_SERVER_COMMAND="$FAKE" \
ORC_FAKE_APP_SERVER_LOG="$NO_PROJECT_LOG" \
  python3 "$CLIENT" create \
    --cwd "$WORKTREE" \
    --task-dir "$TASK_DIR" \
    --title 'ORC Visible Task Without Host Project ID' \
    --model gpt-5.6-sol \
    --effort high \
    --prompt-file "$TMP/prompt.md" > "$TMP/no-project.out" 2> "$TMP/no-project.err"
NO_PROJECT_RC=$?
check "create permits cwd-based visibility when no App Server project id exists" \
  test "$NO_PROJECT_RC" -eq 0
check "cwd-based creation does not invent a project id" python3 - "$NO_PROJECT_LOG" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
params = next(row["params"] for row in rows if row.get("method") == "thread/start")
raise SystemExit(0 if "projectId" not in params else 1)
PY

RESUME_LOG="$TMP/resume.log"
RESUME_OUT="$TMP/resume.out"
ORC_CODEX_APP_SERVER_COMMAND="$FAKE" \
ORC_FAKE_APP_SERVER_LOG="$RESUME_LOG" \
  python3 "$CLIENT" resume \
    --thread-id thr_visible \
    --cwd "$WORKTREE" \
    --task-dir "$TASK_DIR" \
    --model gpt-5.6-sol \
    --effort high \
    --prompt-file "$TMP/prompt.md" > "$RESUME_OUT" 2> "$TMP/resume.err"
RESUME_RC=$?
check "resume client exits successfully" test "$RESUME_RC" -eq 0
check "resume uses the exact accepted thread and never starts a replacement" python3 - "$RESUME_LOG" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
methods = [row.get("method") for row in rows]
resume = next(row["params"] for row in rows if row.get("method") == "thread/resume")
ok = resume.get("threadId") == "thr_visible"
ok = ok and "thread/start" not in methods
raise SystemExit(0 if ok else 1)
PY

FAIL_LOG="$TMP/fail.log"
ORC_CODEX_APP_SERVER_COMMAND="$FAKE" \
ORC_FAKE_APP_SERVER_LOG="$FAIL_LOG" \
ORC_FAKE_APP_SERVER_FAIL=thread-start \
  python3 "$CLIENT" create \
    --cwd "$WORKTREE" \
    --task-dir "$TASK_DIR" \
    --project-id project-visible \
    --title 'ORC Failed Task' \
    --model gpt-5.6-sol \
    --effort high \
    --prompt-file "$TMP/prompt.md" > "$TMP/fail.out" 2> "$TMP/fail.err"
FAIL_RC=$?
check "JSON-RPC thread creation failure fails closed" test "$FAIL_RC" -ne 0
check "failed creation never emits an accepted thread id" \
  bash -c '! grep -Fq '"'"'"type":"thread.started"'"'"' "$1"' _ "$TMP/fail.out"

printf 'codex task client: %s/%s passed\n' "$OK" "$N"
[[ "$OK" -eq "$N" ]]
