#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLASSIFIER="$ROOT/scripts/classify-mission-version.sh"
TEST_TMP_BASE="${TMPDIR:-/tmp}"
TEST_TMP_BASE="${TEST_TMP_BASE%/}"
TMP="$(mktemp -d "$TEST_TMP_BASE/orc-native-version.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT

N=0
OK=0
check() {
  local label="$1"
  shift
  N=$((N + 1))
  if "$@" >/dev/null 2>&1; then OK=$((OK + 1)); else echo "  case $N failed: $label"; fi
}

make_shape() {
  local root="$1" version="${2:-0.4.0}" state="${3:-planned}"
  mkdir -p "$root/hub/missions/demo" "$root/hub/control/demo"
  printf 'request\n' > "$root/hub/missions/demo/request.md"
  printf 'Briefs: brief.md, brief-exec.md\n' > "$root/hub/missions/demo/MISSION.md"
  printf '%s\n' "$state" > "$root/hub/missions/demo/state"
  printf 'session_id: fable-session\nbackend: claude-headless\nmodel: claude-fable-5\nstage: plan\n' > "$root/hub/missions/demo/session.txt"
  printf '%s\n' "$version" > "$root/hub/control/demo/pipeline-version"
  printf 'fable-opus\n' > "$root/hub/missions/demo/planning-backend"
  printf 'fable-opus\n' > "$root/hub/control/demo/planning-backend"
  printf 'fable-session\n' > "$root/hub/control/demo/planning-session-id"
}

classifies_native() {
  [[ "$($CLASSIFIER --mission-dir "$1/hub/missions/demo" --control-dir "$1/hub/control/demo")" == native-0.4 ]]
}

make_shape "$TMP/valid"
check "exact native authority classifies" classifies_native "$TMP/valid"

make_shape "$TMP/with-dag"
mkdir -p "$TMP/with-dag/hub/control/demo/tasks"
printf '{}\n' > "$TMP/with-dag/hub/control/demo/approved-task-dag.json"
check "native authority permits matching DAG and task registry" classifies_native "$TMP/with-dag"

make_shape "$TMP/v03" 0.3.0
check "0.3 marker is unsupported" test ! -n "$($CLASSIFIER --mission-dir "$TMP/v03/hub/missions/demo" --control-dir "$TMP/v03/hub/control/demo" 2>/dev/null)"

make_shape "$TMP/unmarked"
rm "$TMP/unmarked/hub/control/demo/pipeline-version"
check "unmarked mission is unsupported" test ! -n "$($CLASSIFIER --mission-dir "$TMP/unmarked/hub/missions/demo" --control-dir "$TMP/unmarked/hub/control/demo" 2>/dev/null)"

make_shape "$TMP/bad-session"
printf 'backend: codex-exec\nworker_pid: 123\n' > "$TMP/bad-session/hub/missions/demo/session.txt"
check "single-executor session authority is rejected" test ! -n "$($CLASSIFIER --mission-dir "$TMP/bad-session/hub/missions/demo" --control-dir "$TMP/bad-session/hub/control/demo" 2>/dev/null)"

make_shape "$TMP/partial-dag"
printf '{}\n' > "$TMP/partial-dag/hub/control/demo/approved-task-dag.json"
check "partial DAG authority is rejected" test ! -n "$($CLASSIFIER --mission-dir "$TMP/partial-dag/hub/missions/demo" --control-dir "$TMP/partial-dag/hub/control/demo" 2>/dev/null)"

make_shape "$TMP/missing-request"
rm "$TMP/missing-request/hub/missions/demo/request.md"
check "missing request authority is rejected" test ! -n "$($CLASSIFIER --mission-dir "$TMP/missing-request/hub/missions/demo" --control-dir "$TMP/missing-request/hub/control/demo" 2>/dev/null)"

make_shape "$TMP/bad-state" 0.4.0 unknown
check "unsupported state is rejected" test ! -n "$($CLASSIFIER --mission-dir "$TMP/bad-state/hub/missions/demo" --control-dir "$TMP/bad-state/hub/control/demo" 2>/dev/null)"

make_shape "$TMP/missing-planning-backend"
rm "$TMP/missing-planning-backend/hub/control/demo/planning-backend"
check "one-sided planning backend authority is rejected" test ! -n "$($CLASSIFIER --mission-dir "$TMP/missing-planning-backend/hub/missions/demo" --control-dir "$TMP/missing-planning-backend/hub/control/demo" 2>/dev/null)"

make_shape "$TMP/mismatched-planning-backend"
printf 'codex-ultra\n' > "$TMP/mismatched-planning-backend/hub/control/demo/planning-backend"
check "mismatched planning backend authority is rejected" test ! -n "$($CLASSIFIER --mission-dir "$TMP/mismatched-planning-backend/hub/missions/demo" --control-dir "$TMP/mismatched-planning-backend/hub/control/demo" 2>/dev/null)"

make_shape "$TMP/invalid-planning-backend"
printf 'automatic\n' > "$TMP/invalid-planning-backend/hub/missions/demo/planning-backend"
printf 'automatic\n' > "$TMP/invalid-planning-backend/hub/control/demo/planning-backend"
check "unknown planning backend authority is rejected" test ! -n "$($CLASSIFIER --mission-dir "$TMP/invalid-planning-backend/hub/missions/demo" --control-dir "$TMP/invalid-planning-backend/hub/control/demo" 2>/dev/null)"

make_shape "$TMP/fable-session-mismatch"
printf 'other-session\n' > "$TMP/fable-session-mismatch/hub/control/demo/planning-session-id"
check "worker-writable Fable session cannot redirect coordinator authority" test ! -n "$($CLASSIFIER --mission-dir "$TMP/fable-session-mismatch/hub/missions/demo" --control-dir "$TMP/fable-session-mismatch/hub/control/demo" 2>/dev/null)"

make_shape "$TMP/fable-valid-fallback"
jq -cS -n '{from:"claude-fable-5",session_id:"fable-session",stage:"plan",to:"claude-opus-5"}' > "$TMP/fable-valid-fallback/hub/control/demo/quota-fallback-plan.json"
check "session-bound Opus fallback authority classifies" classifies_native "$TMP/fable-valid-fallback"

make_shape "$TMP/fable-bad-fallback"
jq -cS -n '{from:"claude-fable-5",session_id:"other-session",stage:"plan",to:"claude-opus-5"}' > "$TMP/fable-bad-fallback/hub/control/demo/quota-fallback-plan.json"
check "Opus fallback for another planning session is rejected" test ! -n "$($CLASSIFIER --mission-dir "$TMP/fable-bad-fallback/hub/missions/demo" --control-dir "$TMP/fable-bad-fallback/hub/control/demo" 2>/dev/null)"

make_codex_shape() {
  local root="$1"
  make_shape "$root"
  printf 'codex-ultra\n' > "$root/hub/missions/demo/planning-backend"
  printf 'codex-ultra\n' > "$root/hub/control/demo/planning-backend"
  rm "$root/hub/control/demo/planning-session-id"
  printf 'backend: codex-native\nmodel: gpt-5.6-sol\neffort: ultra\nthread_id: planning-thread\nstage: plan\n' > "$root/hub/missions/demo/session.txt"
  printf 'planning-thread\n' > "$root/hub/control/demo/planning-thread-id"
  jq -cS -n '{
    created:true, visible:true, title_verified:true, first_turn_exists:true,
    startup_evidence:true, settings_recorded:true, worktree_verified:true,
    status:"completed", thread_id:"planning-thread", model:"gpt-5.6-sol",
    effort:"ultra", project_id:"project-1", cwd:"/tmp/planning-worktree"
  }' > "$root/hub/control/demo/planning-thread-health.json"
}

make_codex_shape "$TMP/codex-valid"
check "complete Codex Ultra planning authority classifies" classifies_native "$TMP/codex-valid"

make_codex_shape "$TMP/codex-missing-health"
rm "$TMP/codex-missing-health/hub/control/demo/planning-thread-health.json"
check "Codex Ultra session without health authority is rejected" test ! -n "$($CLASSIFIER --mission-dir "$TMP/codex-missing-health/hub/missions/demo" --control-dir "$TMP/codex-missing-health/hub/control/demo" 2>/dev/null)"

make_codex_shape "$TMP/codex-wrong-effort"
sed 's/effort: ultra/effort: high/' "$TMP/codex-wrong-effort/hub/missions/demo/session.txt" > "$TMP/codex-wrong-effort/hub/missions/demo/session.new"
mv "$TMP/codex-wrong-effort/hub/missions/demo/session.new" "$TMP/codex-wrong-effort/hub/missions/demo/session.txt"
check "Codex Ultra session with wrong effort is rejected" test ! -n "$($CLASSIFIER --mission-dir "$TMP/codex-wrong-effort/hub/missions/demo" --control-dir "$TMP/codex-wrong-effort/hub/control/demo" 2>/dev/null)"

make_shape "$TMP/codex-pending" 0.4.0 pending
printf 'codex-ultra\n' > "$TMP/codex-pending/hub/missions/demo/planning-backend"
printf 'codex-ultra\n' > "$TMP/codex-pending/hub/control/demo/planning-backend"
rm "$TMP/codex-pending/hub/missions/demo/session.txt" "$TMP/codex-pending/hub/control/demo/planning-session-id"
check "pending Codex Ultra selection may precede task launch" classifies_native "$TMP/codex-pending"

make_codex_shape "$TMP/codex-planned-without-task"
rm "$TMP/codex-planned-without-task/hub/missions/demo/session.txt" \
  "$TMP/codex-planned-without-task/hub/control/demo/planning-thread-id" \
  "$TMP/codex-planned-without-task/hub/control/demo/planning-thread-health.json"
check "non-pending Codex Ultra mission requires accepted task authority" test ! -n "$($CLASSIFIER --mission-dir "$TMP/codex-planned-without-task/hub/missions/demo" --control-dir "$TMP/codex-planned-without-task/hub/control/demo" 2>/dev/null)"

echo "  mission-version-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
