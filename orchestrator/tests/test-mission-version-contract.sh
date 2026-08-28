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
  printf 'backend: claude-headless\nstage: plan\n' > "$root/hub/missions/demo/session.txt"
  printf '%s\n' "$version" > "$root/hub/control/demo/pipeline-version"
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

echo "  mission-version-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
