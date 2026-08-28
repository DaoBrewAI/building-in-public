#!/usr/bin/env bash
# RED contract for the approved mission-internal task DAG.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/templates/task-dag.json"
VALIDATOR="$ROOT/scripts/validate-task-dag.sh"
CLASSIFIER="$ROOT/scripts/classify-mission-version.sh"
BRIEF="$ROOT/templates/brief-codex.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

cat > "$TMP/valid.json" <<'JSON'
{
  "version": 1,
  "mission": "contract-test",
  "tasks": [
    {
      "id": "task-a",
      "depends_on": [],
      "files": ["src/a.txt"],
      "contracts": ["contract-a"],
      "verification": ["bash tests/a.sh"],
      "state": "ready"
    },
    {
      "id": "task-b",
      "depends_on": ["task-a"],
      "files": ["src/b.txt"],
      "contracts": ["contract-b"],
      "verification": ["bash tests/b.sh"],
      "state": "pending"
    }
  ]
}
JSON

cat > "$TMP/duplicate.json" <<'JSON'
{"version":1,"mission":"m","tasks":[
  {"id":"same","depends_on":[],"files":["a"],"contracts":[],"verification":["true"],"state":"ready"},
  {"id":"same","depends_on":[],"files":["b"],"contracts":[],"verification":["true"],"state":"ready"}
]}
JSON

cat > "$TMP/cycle.json" <<'JSON'
{"version":1,"mission":"m","tasks":[
  {"id":"a","depends_on":["b"],"files":["a"],"contracts":[],"verification":["true"],"state":"pending"},
  {"id":"b","depends_on":["a"],"files":["b"],"contracts":[],"verification":["true"],"state":"pending"}
]}
JSON

cat > "$TMP/overlap.json" <<'JSON'
{"version":1,"mission":"m","tasks":[
  {"id":"a","depends_on":[],"files":["shared"],"contracts":["api"],"verification":["true"],"state":"ready"},
  {"id":"b","depends_on":[],"files":["shared"],"contracts":["api"],"verification":["true"],"state":"ready"}
]}
JSON

cat > "$TMP/incomplete.json" <<'JSON'
{"version":1,"mission":"m","tasks":[
  {"id":"a","depends_on":[],"files":[],"contracts":[],"state":"ready"}
]}
JSON

cat > "$TMP/bad-state.json" <<'JSON'
{"version":1,"mission":"m","tasks":[
  {"id":"a","depends_on":[],"files":["a"],"contracts":[],"verification":["true"],"state":"invented"}
]}
JSON

python3 - "$TMP" <<'PY'
import copy
import json
import os
import sys

tmp = sys.argv[1]
base = {
    "version": 1,
    "mission": "valid-mission_1.0",
    "tasks": [{
        "id": "valid-task_1.0",
        "depends_on": [],
        "files": ["src/a.txt"],
        "contracts": [],
        "verification": ["true"],
        "state": "ready",
    }],
}

invalid_paths = {
    "absolute": "/src/a.txt",
    "leading-dot": "./src/a.txt",
    "dot-segment": "src/./a.txt",
    "dotdot-segment": "src/../a.txt",
}
for name, value in invalid_paths.items():
    fixture = copy.deepcopy(base)
    fixture["tasks"][0]["files"] = [value]
    with open(os.path.join(tmp, "bad-path-%s.json" % name), "w") as handle:
        json.dump(fixture, handle)

invalid_identities = {
    "mission-whitespace": ("bad mission", "valid-task"),
    "mission-newline": ("bad\nmission", "valid-task"),
    "task-slash": ("valid-mission", "bad/task"),
    "task-unicode": ("valid-mission", "t\u00e2che"),
    "task-dot": ("valid-mission", "."),
    "task-dotdot": ("valid-mission", ".."),
}
for name, values in invalid_identities.items():
    fixture = copy.deepcopy(base)
    fixture["mission"], fixture["tasks"][0]["id"] = values
    with open(os.path.join(tmp, "bad-identity-%s.json" % name), "w") as handle:
        json.dump(fixture, handle)

alias_pairs = {
    "case": ("src/Feature.swift", "src/feature.swift"),
    "unicode": ("src/caf\u00e9.swift", "src/cafe\u0301.swift"),
}
for name, paths in alias_pairs.items():
    fixture = copy.deepcopy(base)
    fixture["tasks"] = [
        {
            "id": "task-a",
            "depends_on": [],
            "files": [paths[0]],
            "contracts": [],
            "verification": ["true"],
            "state": "ready",
        },
        {
            "id": "task-b",
            "depends_on": [],
            "files": [paths[1]],
            "contracts": [],
            "verification": ["true"],
            "state": "ready",
        },
    ]
    with open(os.path.join(tmp, "alias-path-%s.json" % name), "w") as handle:
        json.dump(fixture, handle)
PY

accepts() { [[ -x "$VALIDATOR" ]] && "$VALIDATOR" "$1"; }
rejects() { [[ -x "$VALIDATOR" ]] && ! "$VALIDATOR" "$1"; }
rejects_each() {
  local fixture
  for fixture in "$@"; do
    rejects "$fixture" || return 1
  done
}
make_control() {
  local control="$1"
  mkdir -p "$control"
  printf 'approved design\n' > "$control/approved-design.md"
  printf 'approved plan\n' > "$control/approved-plan.md"
  printf 'approved brief\n' > "$control/brief-exec.md"
  (cd "$control" && shasum -a 256 approved-design.md approved-plan.md brief-exec.md > approved.sha256)
}
make_native_mission() {
  local root="$1"
  local mission="$root/hub/missions/contract-test"
  local control="$root/hub/control/contract-test"
  mkdir -p "$mission" "$control"
  make_control "$control"
  printf '0.4.0\n' > "$control/pipeline-version"
  printf 'request\n' > "$mission/request.md"
  printf 'Briefs: brief.md, brief-exec.md\n' > "$mission/MISSION.md"
  printf 'planned\n' > "$mission/state"
  printf 'backend: hybrid\nstage: plan\n' > "$mission/session.txt"
}
freeze_initializes_classifiable_empty_registry() {
  local root="$TMP/classifiable-freeze"
  local mission control
  mkdir -p "$root"
  root="$(cd "$root" && pwd -P)"
  mission="$root/hub/missions/contract-test"
  control="$root/hub/control/contract-test"
  make_native_mission "$root"
  "$VALIDATOR" --freeze "$TMP/valid.json" "$control" || return 1
  [[ -d "$control/tasks" && ! -L "$control/tasks" ]] || return 1
  [[ -z "$(find "$control/tasks" -mindepth 1 -print -quit)" ]] || return 1
  [[ "$($CLASSIFIER --mission-dir "$mission" --control-dir "$control")" == native-0.4 ]]
}
completed_freeze_retry_initializes_registry() {
  local root="$TMP/completed-registry-retry"
  local mission control
  mkdir -p "$root"
  root="$(cd "$root" && pwd -P)"
  mission="$root/hub/missions/contract-test"
  control="$root/hub/control/contract-test"
  make_native_mission "$root"
  cp "$TMP/valid.json" "$control/approved-task-dag.json"
  (cd "$control" && shasum -a 256 approved-task-dag.json >> approved.sha256)
  [[ ! -e "$control/tasks" && ! -L "$control/tasks" ]] || return 1
  "$VALIDATOR" --freeze "$TMP/valid.json" "$control" || return 1
  [[ -d "$control/tasks" && ! -L "$control/tasks" ]] || return 1
  [[ -z "$(find "$control/tasks" -mindepth 1 -print -quit)" ]] || return 1
  (cd "$control" && shasum -a 256 -c approved.sha256 >/dev/null) || return 1
  [[ "$($CLASSIFIER --mission-dir "$mission" --control-dir "$control")" == native-0.4 ]]
}
existing_task_registry_is_preserved() {
  local root="$TMP/existing-registry"
  local control="$root/hub/control/contract-test"
  make_native_mission "$root"
  mkdir "$control/tasks"
  mkdir "$control/tasks/task-a"
  printf 'integrated\n' > "$control/tasks/task-a/state"
  "$VALIDATOR" --freeze "$TMP/valid.json" "$control" || return 1
  [[ "$(cat "$control/tasks/task-a/state")" == integrated ]]
}
incompatible_task_registry_is_rejected() {
  local file_control="$TMP/file-registry-control"
  local link_control="$TMP/link-registry-control"
  local link_target="$TMP/link-registry-target"
  local file_manifest="$TMP/file-registry-approved.sha256"
  local link_manifest="$TMP/link-registry-approved.sha256"
  make_control "$file_control"
  printf 'occupied\n' > "$file_control/tasks"
  cp "$file_control/approved.sha256" "$file_manifest"
  if "$VALIDATOR" --freeze "$TMP/valid.json" "$file_control"; then
    return 1
  fi
  [[ "$(cat "$file_control/tasks")" == occupied ]] || return 1
  [[ ! -e "$file_control/approved-task-dag.json" ]] || return 1
  cmp -s "$file_manifest" "$file_control/approved.sha256" || return 1

  make_control "$link_control"
  mkdir "$link_target"
  ln -s "$link_target" "$link_control/tasks"
  cp "$link_control/approved.sha256" "$link_manifest"
  if "$VALIDATOR" --freeze "$TMP/valid.json" "$link_control"; then
    return 1
  fi
  [[ -L "$link_control/tasks" && "$(readlink "$link_control/tasks")" == "$link_target" ]] || return 1
  [[ ! -e "$link_control/approved-task-dag.json" ]] || return 1
  cmp -s "$link_manifest" "$link_control/approved.sha256"
}
freezes() {
  local control="$TMP/control"
  make_control "$control"
  "$VALIDATOR" --freeze "$TMP/valid.json" "$control" || return 1
  [[ -s "$control/approved-task-dag.json" ]] || return 1
  grep -Fq 'approved-task-dag.json' "$control/approved.sha256" || return 1
  (cd "$control" && shasum -a 256 -c approved.sha256 >/dev/null)
}
freezes_staged_snapshot() {
  local control="$TMP/snapshot-control"
  local mutable="$TMP/mutable.json"
  local original="$TMP/original.json"
  local wrapper="$TMP/snapshot-bin"
  local real_python
  make_control "$control"
  cp "$TMP/valid.json" "$mutable"
  cp "$TMP/valid.json" "$original"
  mkdir -p "$wrapper"
  real_python="$(command -v python3)"
  cat > "$wrapper/python3" <<'SH'
#!/bin/sh
"$ORC_TEST_REAL_PYTHON" "$@"
rc="$?"
case "${2:-}" in
  */.approved-task-dag.json.*) staged_validation=1 ;;
  *) staged_validation=0 ;;
esac
if [ "$rc" -eq 0 ] && [ "$staged_validation" -eq 1 ] && \
    [ ! -e "$ORC_TEST_MUTATION_MARKER" ]; then
  printf '{}\n' > "$ORC_TEST_MUTATE_DAG"
  : > "$ORC_TEST_MUTATION_MARKER"
fi
exit "$rc"
SH
  chmod +x "$wrapper/python3"
  PATH="$wrapper:$PATH" \
    ORC_TEST_REAL_PYTHON="$real_python" \
    ORC_TEST_MUTATE_DAG="$mutable" \
    ORC_TEST_MUTATION_MARKER="$TMP/mutated" \
    "$VALIDATOR" --freeze "$mutable" "$control" || return 1
  cmp -s "$original" "$control/approved-task-dag.json" || return 1
  "$VALIDATOR" "$control/approved-task-dag.json"
}
freeze_failure_rolls_back() {
  local control="$TMP/rollback-control"
  local wrapper="$TMP/rollback-bin"
  local original_hash="$TMP/original-approved.sha256"
  make_control "$control"
  cp "$control/approved.sha256" "$original_hash"
  mkdir -p "$wrapper"
  cat > "$wrapper/mv" <<'SH'
#!/bin/sh
target=""
for argument in "$@"; do
  target="$argument"
done
if [ "${target##*/}" = "approved.sha256" ] && [ ! -e "$ORC_TEST_MV_FAILED" ]; then
  : > "$ORC_TEST_MV_FAILED"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$wrapper/mv"
  if PATH="$wrapper:$PATH" ORC_TEST_MV_FAILED="$TMP/mv-failed" \
      "$VALIDATOR" --freeze "$TMP/valid.json" "$control"; then
    return 1
  fi
  [[ ! -e "$control/approved-task-dag.json" ]] || return 1
  cmp -s "$original_hash" "$control/approved.sha256" || return 1
  "$VALIDATOR" --freeze "$TMP/valid.json" "$control"
}
post_verification_mutation_is_not_blessed() {
  local control="$TMP/verified-hash-race-control"
  local wrapper="$TMP/verified-hash-race-bin"
  local original_hash="$TMP/verified-hash-race.sha256"
  local real_python
  make_control "$control"
  cp "$control/approved.sha256" "$original_hash"
  mkdir -p "$wrapper"
  real_python="$(command -v python3)"
  cat > "$wrapper/python3" <<'SH'
#!/bin/sh
"$ORC_TEST_REAL_PYTHON" "$@"
rc="$?"
if [ "$rc" -eq 0 ] && [ "${4:-}" = "approved-design.md" ] && \
    [ -z "${7:-}" ] && [ ! -e "$ORC_TEST_MUTATION_MARKER" ]; then
  printf 'mutated after manifest verification\n' > "$ORC_TEST_APPROVED_DESIGN"
  : > "$ORC_TEST_MUTATION_MARKER"
fi
exit "$rc"
SH
  chmod +x "$wrapper/python3"
  if PATH="$wrapper:$PATH" \
      ORC_TEST_REAL_PYTHON="$real_python" \
      ORC_TEST_APPROVED_DESIGN="$control/approved-design.md" \
      ORC_TEST_MUTATION_MARKER="$TMP/verified-hash-mutated" \
      "$VALIDATOR" --freeze "$TMP/valid.json" "$control"; then
    return 1
  fi
  [[ -e "$TMP/verified-hash-mutated" ]] || return 1
  [[ ! -e "$control/approved-task-dag.json" ]] || return 1
  cmp -s "$original_hash" "$control/approved.sha256"
}
same_input_freeze_is_idempotent() {
  local control="$TMP/idempotent-control"
  local frozen_dag="$TMP/idempotent-approved-task-dag.json"
  local frozen_hash="$TMP/idempotent-approved.sha256"
  make_control "$control"
  "$VALIDATOR" --freeze "$TMP/valid.json" "$control" || return 1
  cp "$control/approved-task-dag.json" "$frozen_dag"
  cp "$control/approved.sha256" "$frozen_hash"
  "$VALIDATOR" --freeze "$TMP/valid.json" "$control" || return 1
  cmp -s "$frozen_dag" "$control/approved-task-dag.json" || return 1
  cmp -s "$frozen_hash" "$control/approved.sha256"
}
interrupted_freeze_recovers() {
  local control="$TMP/interrupted-control"
  local wrapper="$TMP/interrupted-bin"
  local original_hash="$TMP/interrupted-approved.sha256"
  make_control "$control"
  cp "$control/approved.sha256" "$original_hash"
  mkdir -p "$wrapper"
  cat > "$wrapper/mv" <<'SH'
#!/bin/sh
command_name="${0##*/}"
target=""
for argument in "$@"; do
  target="$argument"
done
if [ "${target##*/}" = "approved-task-dag.json" ] && \
    [ ! -e "$ORC_TEST_CRASH_MARKER" ]; then
  "/bin/$command_name" "$@" || exit "$?"
  : > "$ORC_TEST_CRASH_MARKER"
  kill -9 "$PPID"
  exit 137
fi
exec "/bin/$command_name" "$@"
SH
  cp "$wrapper/mv" "$wrapper/ln"
  chmod +x "$wrapper/mv"
  chmod +x "$wrapper/ln"
  PATH="$wrapper:$PATH" ORC_TEST_CRASH_MARKER="$TMP/interrupted-crashed" \
    "$VALIDATOR" --freeze "$TMP/valid.json" "$control" >/dev/null 2>&1
  [[ "$?" -ne 0 ]] || return 1
  [[ -e "$TMP/interrupted-crashed" ]] || return 1
  cmp -s "$TMP/valid.json" "$control/approved-task-dag.json" || return 1
  cmp -s "$original_hash" "$control/approved.sha256" || return 1
  "$VALIDATOR" --freeze "$TMP/valid.json" "$control" || return 1
  (cd "$control" && shasum -a 256 -c approved.sha256 >/dev/null)
}
conflicting_partial_freeze_is_preserved() {
  local control="$TMP/conflicting-partial-control"
  local original_dag="$TMP/conflicting-partial-dag.json"
  local original_hash="$TMP/conflicting-partial.sha256"
  make_control "$control"
  cp "$TMP/valid.json" "$control/approved-task-dag.json"
  printf '\n' >> "$control/approved-task-dag.json"
  cp "$control/approved-task-dag.json" "$original_dag"
  cp "$control/approved.sha256" "$original_hash"
  if "$VALIDATOR" --freeze "$TMP/valid.json" "$control"; then
    return 1
  fi
  cmp -s "$original_dag" "$control/approved-task-dag.json" || return 1
  cmp -s "$original_hash" "$control/approved.sha256"
}
start_inherited_fd_lock_holder() {
  local lock="$1"
  local holder="$2"
  local ready="$3"
  local release_fifo="$4"
  local attempts=0
  cat > "$holder" <<'SH'
#!/usr/bin/env bash
set -u
lock="$1"
ready="$2"
release_fifo="$3"
exec 8< "$lock"
python3 - "$lock" 8 <<'PY'
import fcntl
import os
import stat
import sys

path = sys.argv[1]
fd = int(sys.argv[2])
fd_stat = os.fstat(fd)
path_stat = os.lstat(path)
if not stat.S_ISREG(path_stat.st_mode):
    raise SystemExit(1)
if (fd_stat.st_dev, fd_stat.st_ino) != (path_stat.st_dev, path_stat.st_ino):
    raise SystemExit(1)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
PY
printf 'ready\n' > "$ready"
IFS= read -r ignored < "$release_fifo"
exec 8>&-
SH
  chmod +x "$holder"
  mkfifo "$release_fifo"
  "$holder" "$lock" "$ready" "$release_fifo" &
  LOCK_HOLDER_PID="$!"
  while [[ ! -e "$ready" && "$attempts" -lt 200 ]]; do
    kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || return 1
    attempts=$((attempts + 1))
    sleep 0.01
  done
  [[ -e "$ready" ]]
}
concurrent_freeze_lock_fails_closed() {
  local control="$TMP/lock-contention-control"
  local lock
  local holder="$TMP/lock-contention-holder.sh"
  local ready="$TMP/lock-contention-ready"
  local release_fifo="$TMP/lock-contention-release"
  local validator_rc=0
  make_control "$control"
  lock="$control/.task-dag-freeze.lock"
  : > "$lock"
  chmod 0400 "$lock"
  start_inherited_fd_lock_holder "$lock" "$holder" "$ready" "$release_fifo" || return 1
  "$VALIDATOR" --freeze "$TMP/valid.json" "$control" || validator_rc="$?"
  printf 'release\n' > "$release_fifo"
  wait "$LOCK_HOLDER_PID" || return 1
  [[ "$validator_rc" -ne 0 ]] || return 1
  [[ ! -e "$control/approved-task-dag.json" ]] || return 1
  [[ -f "$lock" && ! -L "$lock" ]]
}
sigkill_releases_inherited_fd_lock() {
  local control="$TMP/lock-sigkill-control"
  local lock
  local holder="$TMP/lock-sigkill-holder.sh"
  local ready="$TMP/lock-sigkill-ready"
  local release_fifo="$TMP/lock-sigkill-release"
  make_control "$control"
  lock="$control/.task-dag-freeze.lock"
  : > "$lock"
  chmod 0400 "$lock"
  start_inherited_fd_lock_holder "$lock" "$holder" "$ready" "$release_fifo" || return 1
  kill -9 "$LOCK_HOLDER_PID"
  wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
  "$VALIDATOR" --freeze "$TMP/valid.json" "$control" || return 1
  (cd "$control" && shasum -a 256 -c approved.sha256 >/dev/null)
}
empty_lock_after_create_is_recoverable() {
  local control="$TMP/empty-lock-create-control"
  local lock
  make_control "$control"
  lock="$control/.task-dag-freeze.lock"
  mkdir "$lock"
  "$VALIDATOR" --freeze "$TMP/valid.json" "$control" || return 1
  [[ -f "$lock" && ! -L "$lock" ]] || return 1
  (cd "$control" && shasum -a 256 -c approved.sha256 >/dev/null)
}
empty_lock_after_owner_removal_is_recoverable() {
  local control="$TMP/empty-lock-release-control"
  local lock
  make_control "$control"
  lock="$control/.task-dag-freeze.lock"
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/owner.pid"
  rm "$lock/owner.pid"
  "$VALIDATOR" --freeze "$TMP/valid.json" "$control" || return 1
  [[ -f "$lock" && ! -L "$lock" ]] || return 1
  (cd "$control" && shasum -a 256 -c approved.sha256 >/dev/null)
}
partial_recovery_secures_dag_mode() {
  local control="$TMP/partial-mode-control"
  make_control "$control"
  cp "$TMP/valid.json" "$control/approved-task-dag.json"
  chmod 0644 "$control/approved-task-dag.json"
  "$VALIDATOR" --freeze "$TMP/valid.json" "$control" || return 1
  [[ "$(stat -f '%Lp' "$control/approved-task-dag.json")" == "400" ]] || return 1
  (cd "$control" && shasum -a 256 -c approved.sha256 >/dev/null)
}
lacks_custom_reclaim_protocol() {
  ! grep -Fq -- '.reclaim' "$VALIDATOR"
}
destination_publication_is_no_clobber() {
  local control="$TMP/no-clobber-control"
  local wrapper="$TMP/no-clobber-bin"
  local unexpected="$TMP/unexpected-approved-task-dag.json"
  local original_hash="$TMP/no-clobber-approved.sha256"
  make_control "$control"
  cp "$control/approved.sha256" "$original_hash"
  mkdir -p "$wrapper"
  cat > "$wrapper/mv" <<'SH'
#!/bin/sh
command_name="${0##*/}"
target=""
for argument in "$@"; do
  target="$argument"
done
if [ "${target##*/}" = "approved-task-dag.json" ] && \
    [ ! -e "$ORC_TEST_DEST_RACE_MARKER" ]; then
  printf '{"unexpected":"writer"}\n' > "$target"
  cp "$target" "$ORC_TEST_UNEXPECTED_DAG"
  : > "$ORC_TEST_DEST_RACE_MARKER"
fi
exec "/bin/$command_name" "$@"
SH
  cp "$wrapper/mv" "$wrapper/ln"
  chmod +x "$wrapper/mv" "$wrapper/ln"
  if PATH="$wrapper:$PATH" \
      ORC_TEST_DEST_RACE_MARKER="$TMP/destination-raced" \
      ORC_TEST_UNEXPECTED_DAG="$unexpected" \
      "$VALIDATOR" --freeze "$TMP/valid.json" "$control"; then
    return 1
  fi
  [[ -e "$TMP/destination-raced" ]] || return 1
  cmp -s "$unexpected" "$control/approved-task-dag.json" || return 1
  cmp -s "$original_hash" "$control/approved.sha256"
}
rejects_inexact_manifests() {
  local control="$TMP/unrelated-control"
  make_control "$control"
  printf 'unrelated\n' > "$control/unrelated.txt"
  (cd "$control" && shasum -a 256 unrelated.txt > approved.sha256)
  rejects_freeze "$control" || return 1

  control="$TMP/alias-control"
  make_control "$control"
  (cd "$control" && {
    shasum -a 256 approved-design.md | sed 's#  approved-design.md#  ./approved-design.md#'
    shasum -a 256 approved-plan.md brief-exec.md
  } > approved.sha256)
  rejects_freeze "$control"
}
rejects_freeze() {
  local control="$1"
  ! "$VALIDATOR" --freeze "$TMP/valid.json" "$control" || return 1
  [[ ! -e "$control/approved-task-dag.json" ]]
}

check "machine-readable task DAG template exists" test -s "$TEMPLATE"
check "Bash validator exists and is executable" test -x "$VALIDATOR"
check "validator accepts a complete acyclic DAG" accepts "$TMP/valid.json"
check "validator rejects duplicate task IDs" rejects "$TMP/duplicate.json"
check "validator rejects dependency cycles" rejects "$TMP/cycle.json"
check "validator rejects parallel-ready file or contract overlap" rejects "$TMP/overlap.json"
check "validator requires declared verification commands" rejects "$TMP/incomplete.json"
check "validator rejects unknown task states" rejects "$TMP/bad-state.json"
check "Fable brief requires task-dag.json beside plan.md" grep -Fq -- 'task-dag.json' "$BRIEF"
check "validated DAG freezes into the approved hash contract" freezes
check "successful native freeze leaves an immediately classifiable empty task registry" \
  freeze_initializes_classifiable_empty_registry
check "retry from DAG-present registry-absent authority converges classification" \
  completed_freeze_retry_initializes_registry
check "successful freeze preserves an existing coordinator task registry" \
  existing_task_registry_is_preserved
check "freeze rejects file and symlink task registry authority without publication" \
  incompatible_task_registry_is_rejected
check "validator rejects non-canonical repo-relative file paths" rejects_each \
  "$TMP/bad-path-absolute.json" "$TMP/bad-path-leading-dot.json" \
  "$TMP/bad-path-dot-segment.json" "$TMP/bad-path-dotdot-segment.json"
check "validator enforces canonical ASCII mission and task identities" rejects_each \
  "$TMP/bad-identity-mission-whitespace.json" "$TMP/bad-identity-mission-newline.json" \
  "$TMP/bad-identity-task-slash.json" "$TMP/bad-identity-task-unicode.json" \
  "$TMP/bad-identity-task-dot.json" "$TMP/bad-identity-task-dotdot.json"
check "freeze validates and publishes one protected staged snapshot" freezes_staged_snapshot
check "failed freeze publication rolls back and remains retryable" freeze_failure_rolls_back
check "post-verification approved artifact mutation is not blessed" post_verification_mutation_is_not_blessed
check "same-input completed freeze is an idempotent no-op" same_input_freeze_is_idempotent
check "interrupted post-DAG freeze safely recovers" interrupted_freeze_recovers
check "conflicting partial freeze fails closed without mutation" conflicting_partial_freeze_is_preserved
check "concurrent freeze lock contention fails closed" concurrent_freeze_lock_fails_closed
check "SIGKILL releases inherited-FD advisory lock for retry" sigkill_releases_inherited_fd_lock
check "empty lock crash after create is recoverable" empty_lock_after_create_is_recoverable
check "empty lock crash during release is recoverable" empty_lock_after_owner_removal_is_recoverable
check "partial recovery secures the DAG to mode 0400" partial_recovery_secures_dag_mode
check "freeze lock has no custom reclaim protocol" lacks_custom_reclaim_protocol
check "DAG destination publication never clobbers an unexpected writer" destination_publication_is_no_clobber
check "parallel path overlap uses casefolded NFC collision keys" rejects_each \
  "$TMP/alias-path-case.json" "$TMP/alias-path-unicode.json"
check "freeze requires exact contained approved hash entries" rejects_inexact_manifests

echo "  task-dag-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
