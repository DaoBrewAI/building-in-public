#!/usr/bin/env bash
# Task 8 migration contract for deterministic 0.2/0.3/0.4 mission routing.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLASSIFIER="$ROOT/scripts/classify-mission-version.sh"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/orc-version-test.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
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

make_hybrid_shape() {
  local root="$1" state="${2:-planned}" slug="${3:-demo}"
  mkdir -p "$root/hub/missions/$slug" "$root/hub/control/$slug"
  printf 'request\n' > "$root/hub/missions/$slug/request.md"
  printf 'Briefs: brief.md, brief-exec.md\n' > "$root/hub/missions/$slug/MISSION.md"
  printf '%s\n' "$state" > "$root/hub/missions/$slug/state"
  printf 'backend: hybrid\nstage: plan\n' > "$root/hub/missions/$slug/session.txt"
}

classifies_as() {
  local expected="$1" root="$2" slug="${3:-demo}"
  [[ -x "$CLASSIFIER" ]] && \
    [[ "$($CLASSIFIER \
      --mission-dir "$root/hub/missions/$slug" \
      --control-dir "$root/hub/control/$slug")" = "$expected" ]]
}

make_hybrid_shape "$TMP/v03-planned"
check "unmarked in-flight Hybrid planned mission remains 0.3" \
  classifies_as hybrid-0.3 "$TMP/v03-planned"

make_hybrid_shape "$TMP/v03-running" running
printf 'codex_thread_id: thread-v03\nstage: exec\n' >> \
  "$TMP/v03-running/hub/missions/demo/session.txt"
check "unmarked Hybrid mission with a recorded Codex thread remains 0.3" \
  classifies_as hybrid-0.3 "$TMP/v03-running"

make_hybrid_shape "$TMP/v03-marked-prego" pending
printf '0.3.0\n' > "$TMP/v03-marked-prego/hub/control/demo/pipeline-version"
rm "$TMP/v03-marked-prego/hub/missions/demo/session.txt"
check "coordinator marker recovers a valid pre-plan 0.3 mission without stage history" \
  classifies_as hybrid-0.3 "$TMP/v03-marked-prego"

make_hybrid_shape "$TMP/v03-marked-legacy-conflict" pending
printf '0.3.0\n' > \
  "$TMP/v03-marked-legacy-conflict/hub/control/demo/pipeline-version"
printf 'backend: codex-exec\nworker_pid: 123\n' > \
  "$TMP/v03-marked-legacy-conflict/hub/missions/demo/session.txt"
check "0.3 marker cannot override contradictory legacy session authority" bash -c \
  '! "$1" --mission-dir "$2/hub/missions/demo" --control-dir "$2/hub/control/demo"' \
  _ "$CLASSIFIER" "$TMP/v03-marked-legacy-conflict"

make_hybrid_shape "$TMP/v03-marked-native-conflict" pending
printf '0.3.0\n' > \
  "$TMP/v03-marked-native-conflict/hub/control/demo/pipeline-version"
printf '{"version":1,"mission":"m","tasks":[]}\n' > \
  "$TMP/v03-marked-native-conflict/hub/control/demo/approved-task-dag.json"
mkdir -p "$TMP/v03-marked-native-conflict/hub/control/demo/tasks"
check "0.3 marker cannot coexist with native DAG and task authority" bash -c \
  '! "$1" --mission-dir "$2/hub/missions/demo" --control-dir "$2/hub/control/demo"' \
  _ "$CLASSIFIER" "$TMP/v03-marked-native-conflict"

make_hybrid_shape "$TMP/unmarked-prego" pending
rm "$TMP/unmarked-prego/hub/missions/demo/session.txt"
check "unmarked pre-go authority without stage history fails closed" bash -c \
  '! "$1" --mission-dir "$2/hub/missions/demo" --control-dir "$2/hub/control/demo"' \
  _ "$CLASSIFIER" "$TMP/unmarked-prego"

make_hybrid_shape "$TMP/v04-prego"
printf '0.4.0\n' > "$TMP/v04-prego/hub/control/demo/pipeline-version"
rm "$TMP/v04-prego/hub/missions/demo/session.txt"
check "minimum request MISSION and state authority identifies pre-go 0.4 without a session" \
  classifies_as hybrid-0.4 "$TMP/v04-prego"

make_hybrid_shape "$TMP/v04-frozen" running
printf '0.4.0\n' > "$TMP/v04-frozen/hub/control/demo/pipeline-version"
printf '{"version":1,"mission":"m","tasks":[]}\n' > \
  "$TMP/v04-frozen/hub/control/demo/approved-task-dag.json"
mkdir -p "$TMP/v04-frozen/hub/control/demo/tasks"
check "matching version DAG and registry authority identifies 0.4" \
  classifies_as hybrid-0.4 "$TMP/v04-frozen"

mkdir -p "$TMP/v04-version-only/hub/missions/demo" \
  "$TMP/v04-version-only/hub/control/demo"
printf '0.4.0\n' > "$TMP/v04-version-only/hub/control/demo/pipeline-version"
check "pipeline version alone cannot classify a mission as 0.4" bash -c \
  '! "$1" --mission-dir "$2/hub/missions/demo" --control-dir "$2/hub/control/demo"' \
  _ "$CLASSIFIER" "$TMP/v04-version-only"

mkdir -p "$TMP/v04-legacy-conflict/hub/missions/demo" \
  "$TMP/v04-legacy-conflict/hub/control/demo"
printf '0.4.0\n' > "$TMP/v04-legacy-conflict/hub/control/demo/pipeline-version"
printf 'Brief: brief.md\nSession: gpt-5.6 (overrideable)\n' > \
  "$TMP/v04-legacy-conflict/hub/missions/demo/MISSION.md"
printf 'pending\n' > "$TMP/v04-legacy-conflict/hub/missions/demo/state"
printf 'backend: codex-exec\nworker_pid: 123\n' > \
  "$TMP/v04-legacy-conflict/hub/missions/demo/session.txt"
check "pipeline version cannot override contradictory legacy mission authority" bash -c \
  '! "$1" --mission-dir "$2/hub/missions/demo" --control-dir "$2/hub/control/demo"' \
  _ "$CLASSIFIER" "$TMP/v04-legacy-conflict"

make_hybrid_shape "$TMP/v04-v03-without-state"
printf '0.4.0\n' > "$TMP/v04-v03-without-state/hub/control/demo/pipeline-version"
rm "$TMP/v04-v03-without-state/hub/missions/demo/state"
check "pipeline version cannot promote a 0.3-shaped mission missing state authority" bash -c \
  '! "$1" --mission-dir "$2/hub/missions/demo" --control-dir "$2/hub/control/demo"' \
  _ "$CLASSIFIER" "$TMP/v04-v03-without-state"

make_hybrid_shape "$TMP/partial-dag"
printf '{"version":1,"mission":"m","tasks":[]}\n' > \
  "$TMP/partial-dag/hub/control/demo/approved-task-dag.json"
check "DAG without version and registry fails closed" bash -c \
  '! "$1" --mission-dir "$2/hub/missions/demo" --control-dir "$2/hub/control/demo"' \
  _ "$CLASSIFIER" "$TMP/partial-dag"

make_hybrid_shape "$TMP/partial-registry"
mkdir -p "$TMP/partial-registry/hub/control/demo/tasks"
check "task registry without version and DAG fails closed" bash -c \
  '! "$1" --mission-dir "$2/hub/missions/demo" --control-dir "$2/hub/control/demo"' \
  _ "$CLASSIFIER" "$TMP/partial-registry"

make_hybrid_shape "$TMP/bad-version"
printf '0.4.0\nextra\n' > "$TMP/bad-version/hub/control/demo/pipeline-version"
check "multiline version authority fails closed" bash -c \
  '! "$1" --mission-dir "$2/hub/missions/demo" --control-dir "$2/hub/control/demo"' \
  _ "$CLASSIFIER" "$TMP/bad-version"

make_hybrid_shape "$TMP/symlink-version"
printf '0.4.0\n' > "$TMP/symlink-version/outside-version"
ln -s "$TMP/symlink-version/outside-version" \
  "$TMP/symlink-version/hub/control/demo/pipeline-version"
check "symlinked version authority fails closed" bash -c \
  '! "$1" --mission-dir "$2/hub/missions/demo" --control-dir "$2/hub/control/demo"' \
  _ "$CLASSIFIER" "$TMP/symlink-version"

mkdir -p "$TMP/v02/hub/missions/demo" "$TMP/v02/hub/control/demo"
printf 'Brief: brief.md\nSession: gpt-5.6 (overrideable)\n' > \
  "$TMP/v02/hub/missions/demo/MISSION.md"
printf 'pending\n' > "$TMP/v02/hub/missions/demo/state"
check "legacy pending single-Codex shape remains 0.2" \
  classifies_as legacy-0.2 "$TMP/v02"

make_hybrid_shape "$TMP/mismatched-slug" planned alpha
mkdir -p "$TMP/mismatched-slug/hub/control/bravo"
check "mission and control authority with different slugs fails closed" bash -c \
  '! "$1" --mission-dir "$2/hub/missions/alpha" --control-dir "$2/hub/control/bravo"' \
  _ "$CLASSIFIER" "$TMP/mismatched-slug"

make_hybrid_shape "$TMP/unrelated-hubs"
mkdir -p "$TMP/unrelated-hubs/other-hub/control/demo"
check "mission and control authority from unrelated hubs fails closed" bash -c \
  '! "$1" --mission-dir "$2/hub/missions/demo" --control-dir "$2/other-hub/control/demo"' \
  _ "$CLASSIFIER" "$TMP/unrelated-hubs"

mkdir -p "$TMP/symlink-parent/hub" "$TMP/symlink-parent/real-missions/demo" \
  "$TMP/symlink-parent/hub/control/demo"
printf 'request\n' > "$TMP/symlink-parent/real-missions/demo/request.md"
printf 'Briefs: brief.md, brief-exec.md\n' > \
  "$TMP/symlink-parent/real-missions/demo/MISSION.md"
printf 'backend: hybrid\nstage: plan\n' > \
  "$TMP/symlink-parent/real-missions/demo/session.txt"
ln -s "$TMP/symlink-parent/real-missions" "$TMP/symlink-parent/hub/missions"
check "symlinked missions parent fails closed" bash -c \
  '! "$1" --mission-dir "$2/hub/missions/demo" --control-dir "$2/hub/control/demo"' \
  _ "$CLASSIFIER" "$TMP/symlink-parent"

make_hybrid_shape "$TMP/noncanonical-path"
check "noncanonical dot-segment mission path fails closed" bash -c \
  '! "$1" --mission-dir "$2/hub/missions/../missions/demo" --control-dir "$2/hub/control/demo"' \
  _ "$CLASSIFIER" "$TMP/noncanonical-path"

changing_version_fails_closed() {
  local root="$1" pid="" attempt=0 ready=0
  make_hybrid_shape "$root"
  printf '0.4.0\n' > "$root/hub/control/demo/pipeline-version"
  printf '0.4.0\n' > "$root/external-version"

  trap 'ready=1' USR1
  ORC_CLASSIFIER_TEST_STOP_AFTER_OPEN=1 "$CLASSIFIER" \
    --mission-dir "$root/hub/missions/demo" \
    --control-dir "$root/hub/control/demo" \
    > "$root/classifier.out" 2> "$root/classifier.err" &
  pid=$!

  while [[ "$attempt" -lt 500 ]]; do
    [[ "$ready" -eq 1 ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.01
    attempt=$((attempt + 1))
  done
  trap - USR1
  if [[ "$ready" -ne 1 ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi

  mv "$root/hub/control/demo/pipeline-version" \
    "$root/hub/control/demo/pipeline-version.opened"
  ln -s "$root/external-version" "$root/hub/control/demo/pipeline-version"
  kill -CONT "$pid"
  if wait "$pid"; then
    return 1
  fi
  [[ "$(cat "$root/external-version")" = 0.4.0 ]]
}

check "authority replaced after descriptor validation fails closed" \
  changing_version_fails_closed "$TMP/changing-version"

check "coordinator requires the mission-version classifier" \
  grep -Fq -- 'classify-mission-version.sh' "$SKILL"
check "new mission records coordinator-owned 0.4 version authority" \
  grep -Fq -- 'pipeline-version' "$SKILL"

echo "  mission-version-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
