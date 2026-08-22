#!/usr/bin/env bash
# Durable Codex coordinator continuation adapter.
#
# Hook mode consumes Codex lifecycle JSON on stdin. Coordinator mode records
# manual requests, provisional attempts, rejection receipts, and one verified
# accepted continuation. It never creates a task itself and never reads the
# unstable transcript contents.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
BINDING_HELPER="$SCRIPT_DIR/codex-continuation-binding.py"

die() {
  echo "codex-continuation: $*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool is unavailable: $1"
}

strict_scalar() {
  local value="$1"
  [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]]
}

canonical_dir() {
  local path="$1" physical
  [[ "$path" = /* ]] || return 1
  [[ -d "$path" && ! -L "$path" ]] || return 1
  physical="$(cd -P -- "$path" && pwd -P)" || return 1
  [[ "$physical" = "$path" ]] || return 1
  printf '%s\n' "$physical"
}

find_hub() {
  local dir="$1"
  dir="$(canonical_dir "$dir")" || return 1
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/.orchestrator" && ! -L "$dir/.orchestrator" ]]; then
      printf '%s\n' "$dir/.orchestrator"
      return 0
    fi
    dir="$(dirname -- "$dir")"
  done
  return 1
}

fsync_paths() {
  python3 - "$@" <<'PY'
import os
import stat
import sys

for raw in sys.argv[1:]:
    path = os.path.realpath(raw)
    flags = os.O_RDONLY
    if os.path.isdir(path) and hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
}

publish_no_clobber() {
  local candidate="$1" destination="$2" parent
  parent="$(dirname -- "$destination")"
  fsync_paths "$candidate"
  if ln "$candidate" "$destination" 2>/dev/null; then
    fsync_paths "$destination" "$parent"
    rm -f -- "$candidate"
    return 0
  fi
  if [[ -e "$destination" ]] \
    && python3 "$BINDING_HELPER" compare --left "$candidate" --right "$destination" >/dev/null 2>&1; then
    rm -f -- "$candidate"
    return 0
  fi
  rm -f -- "$candidate"
  return 1
}

replace_durable() {
  local candidate="$1" destination="$2"
  if [[ -e "$destination" ]] \
    && python3 "$BINDING_HELPER" compare --left "$candidate" --right "$destination" >/dev/null 2>&1; then
    rm -f -- "$candidate"
    fsync_paths "$destination" "$(dirname -- "$destination")"
    return 0
  fi
  python3 - "$candidate" "$destination" <<'PY'
import os
import sys

source, destination = sys.argv[1:]
if os.path.lexists(destination) and os.path.islink(destination):
    raise SystemExit("refusing symlink destination")
with open(source, "rb") as handle:
    os.fsync(handle.fileno())
os.replace(source, destination)
directory = os.path.dirname(destination)
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
descriptor = os.open(directory, flags)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

sha256_file() {
  python3 "$BINDING_HELPER" file-sha --path "$1"
}

session_classification() {
  local hub="$1" session_id="$2"
  python3 "$BINDING_HELPER" classify --hub "$hub" --session-id "$session_id"
}

PROTOCOL_LOCK_FILE=""
PROTOCOL_LOCK_OWNER=""

release_protocol_lock() {
  if [[ -n "$PROTOCOL_LOCK_FILE" && -n "$PROTOCOL_LOCK_OWNER" ]] \
    && [[ -f "$PROTOCOL_LOCK_FILE" && ! -L "$PROTOCOL_LOCK_FILE" ]] \
    && [[ "$PROTOCOL_LOCK_FILE" -ef "$PROTOCOL_LOCK_OWNER" ]]; then
    rm -f -- "$PROTOCOL_LOCK_FILE"
    fsync_paths "$(dirname -- "$PROTOCOL_LOCK_FILE")" 2>/dev/null || true
  fi
  [[ -n "$PROTOCOL_LOCK_OWNER" ]] && rm -f -- "$PROTOCOL_LOCK_OWNER"
  PROTOCOL_LOCK_FILE=""
  PROTOCOL_LOCK_OWNER=""
  trap - EXIT INT TERM HUP
}

acquire_protocol_lock() {
  local hub="$1" request_id="$2" wait_mode="${3:-fail}" store host token candidate
  local lock_status owner_pid owner_dead recover_rc attempt=0 max_attempts=3
  store="$hub/control/continuations/requests"
  [[ "$wait_mode" = wait ]] && max_attempts=150
  [[ "$request_id" =~ ^[0-9a-f]{64}$ ]] || die "invalid protocol lock request id"
  host="$(hostname)"
  while (( attempt < max_attempts )); do
    attempt=$((attempt + 1))
    candidate="$(mktemp "$store/.protocol-lock.XXXXXX")"
    token="$(printf '%s\n%s\n%s\n%s\n' "$$" "$host" "$candidate" "$request_id" \
      | shasum -a 256 | awk '{print $1}')"
    printf '%s\t%s\t%s\t%s\n' "$$" "$host" "$token" "$request_id" > "$candidate"
    fsync_paths "$candidate"
    PROTOCOL_LOCK_FILE="$store/$request_id.protocol.lock"
    if ln "$candidate" "$PROTOCOL_LOCK_FILE" 2>/dev/null; then
      PROTOCOL_LOCK_OWNER="$candidate"
      fsync_paths "$PROTOCOL_LOCK_FILE" "$store"
      trap release_protocol_lock EXIT
      trap 'release_protocol_lock; exit 130' INT HUP
      trap 'release_protocol_lock; exit 143' TERM
      return 0
    fi
    rm -f -- "$candidate"
    if ! lock_status="$(python3 "$BINDING_HELPER" lock-status \
      --path "$PROTOCOL_LOCK_FILE" --request-id "$request_id" --host "$host" 2>/dev/null)"; then
      [[ ! -e "$PROTOCOL_LOCK_FILE" ]] && continue
      die "protocol lock is unsafe"
    fi
    owner_pid="$(printf '%s' "$lock_status" | jq -r '.pid')"
    owner_dead="$(printf '%s' "$lock_status" | jq -r '.dead')"
    if [[ "$owner_dead" = false ]]; then
      if [[ "$wait_mode" = wait ]]; then
        sleep 0.02
        continue
      fi
      die "protocol transition is already active"
    fi
    [[ "$owner_dead" = true && "$owner_pid" =~ ^[0-9]+$ ]] \
      || die "protocol lock status is malformed"
    set +e
    python3 "$BINDING_HELPER" recover-lock --path "$PROTOCOL_LOCK_FILE" \
      --expected "$lock_status" >/dev/null 2>&1
    recover_rc=$?
    set -e
    if [[ "$recover_rc" -eq 0 || "$recover_rc" -eq 2 ]]; then
      continue
    fi
    [[ ! -e "$PROTOCOL_LOCK_FILE" ]] && continue
    die "protocol stale-lock recovery failed closed"
  done
  die "could not acquire protocol lock"
}

publish_request() {
  local hub="$1" session_id="$2" event="$3" trigger="$4"
  local store request_id carryover carryover_sha destination receipt latest_candidate result_json
  result_json="$(python3 "$BINDING_HELPER" snapshot-request --hub "$hub" \
    --session-id "$session_id" --event "$event" --trigger "$trigger")" \
    || die "could not publish one exact continuation snapshot"
  request_id="$(printf '%s' "$result_json" | jq -r '.request_id // empty')"
  destination="$(printf '%s' "$result_json" | jq -r '.request_path // empty')"
  carryover="$(printf '%s' "$result_json" | jq -r '.carryover_path // empty')"
  [[ "$request_id" =~ ^[0-9a-f]{64}$ && -n "$destination" && -n "$carryover" ]] \
    || die "snapshot helper returned invalid publication authority"
  store="$hub/control/continuations/requests"
  receipt="$store/$request_id.binding.json"
  acquire_protocol_lock "$hub" "$request_id" wait
  python3 "$BINDING_HELPER" validate --hub "$hub" --request-file "$destination" \
    --receipt-file "$receipt" --request-id "$request_id" --expected-session "$session_id" \
    >/dev/null || die "published continuation request failed exact validation"
  if terminal_request_state "$hub" "$request_id" "$request_id"; then
    [[ "$TERMINAL_STATE" = accepted || "$TERMINAL_STATE" = failed ]] || die "invalid terminal state"
    release_protocol_lock
    return 0
  fi
  publish_event_receipt "$hub" "$request_id" "$session_id" "$event" "$trigger"
  carryover_sha="$(sha256_file "$carryover")"
  latest_candidate="$(mktemp "$hub/.CARRYOVER.latest.XXXXXX")"
  {
    printf '# Latest Orchestrator Codex carryover pointer\n\n'
    printf -- '- Request: `%s`\n' "$request_id"
    printf -- '- Immutable carryover: `%s`\n' "$carryover"
    printf -- '- Carryover SHA-256: `%s`\n' "$carryover_sha"
  } > "$latest_candidate"
  replace_durable "$latest_candidate" "$hub/CARRYOVER.md"
  chmod 0600 "$hub/CARRYOVER.md"
  fsync_paths "$hub/CARRYOVER.md" "$hub"
  release_protocol_lock
  printf '%s\t%s\n' "$request_id" "$destination"
}

REQUEST_PATH=""
REQUEST_BINDING_SHA=""
REQUEST_CARRYOVER_PATH=""
VALIDATED_REQUEST_JSON=""
load_request_authority() {
  local hub="$1" request_id="$2" coordinator_session_id="${3:-}" receipt
  try_load_request_authority "$hub" "$request_id" "$coordinator_session_id" \
    || die "request authority failed exact validation: $request_id"
}

try_load_request_authority() {
  local hub="$1" request_id="$2" coordinator_session_id="${3:-}" receipt
  [[ "$request_id" =~ ^[0-9a-f]{64}$ ]] || die "invalid request id"
  REQUEST_PATH="$hub/control/continuations/requests/$request_id.json"
  receipt="$hub/control/continuations/requests/$request_id.binding.json"
  if [[ -n "$coordinator_session_id" ]]; then
    VALIDATED_REQUEST_JSON="$(python3 "$BINDING_HELPER" validate --hub "$hub" --request-file "$REQUEST_PATH" \
      --receipt-file "$receipt" --request-id "$request_id" \
      --expected-session "$coordinator_session_id")" || return 1
  else
    VALIDATED_REQUEST_JSON="$(python3 "$BINDING_HELPER" validate --hub "$hub" --request-file "$REQUEST_PATH" \
      --receipt-file "$receipt" --request-id "$request_id")" || return 1
  fi
  REQUEST_BINDING_SHA="$(printf '%s' "$VALIDATED_REQUEST_JSON" | jq -r '.binding_sha256')"
  REQUEST_CARRYOVER_PATH="$(printf '%s' "$VALIDATED_REQUEST_JSON" | jq -r '.binding.carryover.path')"
}

write_small_json() {
  local destination="$1"
  shift
  local store candidate
  store="$(dirname -- "$destination")"
  candidate="$(mktemp "$store/.record.XXXXXX")"
  jq -cS -n "$@" > "$candidate"
  publish_no_clobber "$candidate" "$destination"
}

validate_record_file() {
  local kind="$1" path="$2" request_id="$3" binding_sha="$4" thread_id="${5:-}"
  local args
  args=(record --kind "$kind" --path "$path" --request-id "$request_id" --binding-sha256 "$binding_sha")
  [[ -n "$thread_id" ]] && args+=(--thread-id "$thread_id")
  python3 "$BINDING_HELPER" "${args[@]}" >/dev/null
}

VALIDATED_RECORD_JSON=""
load_record_file() {
  local kind="$1" path="$2" request_id="$3" binding_sha="$4" thread_id="${5:-}"
  local args
  args=(record --kind "$kind" --path "$path" --request-id "$request_id" --binding-sha256 "$binding_sha")
  [[ -n "$thread_id" ]] && args+=(--thread-id "$thread_id")
  VALIDATED_RECORD_JSON="$(python3 "$BINDING_HELPER" "${args[@]}")"
}

TERMINAL_STATE=""
TERMINAL_THREAD=""
TERMINAL_REASON=""
terminal_request_state() {
  local hub="$1" request_id="$2" binding_sha="$3" store accepted attempt_two failed_two
  local has_accepted=0 has_failed=0
  TERMINAL_STATE=""
  TERMINAL_THREAD=""
  TERMINAL_REASON=""
  store="$hub/control/continuations/requests"
  accepted="$store/$request_id.accepted.json"
  attempt_two="$store/$request_id.attempt-2.json"
  failed_two="$store/$request_id.attempt-2.failed.json"
  if [[ -e "$accepted" ]]; then
    [[ -f "$accepted" && ! -L "$accepted" ]] || die "accepted receipt is unsafe"
    load_record_file accepted "$accepted" "$request_id" "$binding_sha" \
      || die "accepted receipt is malformed or stale"
    TERMINAL_THREAD="$(printf '%s' "$VALIDATED_RECORD_JSON" | jq -r '.thread_id')"
    has_accepted=1
  fi
  if [[ -e "$failed_two" ]]; then
    [[ -f "$attempt_two" && ! -L "$attempt_two" && -f "$failed_two" && ! -L "$failed_two" ]] \
      || die "terminal failure authority is unsafe"
    load_record_file attempt "$attempt_two" "$request_id" "$binding_sha" \
      || die "terminal attempt authority is malformed"
    TERMINAL_THREAD="$(printf '%s' "$VALIDATED_RECORD_JSON" | jq -r '.thread_id')"
    load_record_file failed "$failed_two" "$request_id" "$binding_sha" \
      || die "terminal failure receipt is malformed"
    TERMINAL_REASON="$(printf '%s' "$VALIDATED_RECORD_JSON" | jq -r '.reason')"
    has_failed=1
  fi
  (( has_accepted + has_failed <= 1 )) || die "conflicting terminal continuation receipts"
  (( has_accepted == 1 )) && { TERMINAL_STATE=accepted; return 0; }
  (( has_failed == 1 )) && { TERMINAL_STATE=failed; return 0; }
  return 1
}

publish_event_receipt() {
  local hub="$1" request_id="$2" session_id="$3" event="$4" trigger="$5"
  local store candidate digest destination
  store="$hub/control/continuations/requests"
  candidate="$(mktemp "$store/.event.XXXXXX")"
  jq -cS -n --arg event "$event" --arg request "$request_id" --arg session "$session_id" \
    --arg trigger "$trigger" \
    '{event:$event,request_id:$request,source_session_id:$session,trigger:$trigger}' \
    > "$candidate"
  digest="$(sha256_file "$candidate")"
  destination="$store/$request_id.event-$digest.json"
  publish_no_clobber "$candidate" "$destination" || die "conflicting event provenance receipt"
  chmod 0600 "$destination"
  fsync_paths "$destination" "$store"
}

record_attempt() {
  local hub="$1" request_id="$2" thread_id="$3" coordinator_session_id="$4" request store binding_sha
  local attempt_one attempt_two failed_one failed_two existing destination number
  strict_scalar "$thread_id" || die "invalid provisional thread id"
  strict_scalar "$coordinator_session_id" || die "invalid coordinator session id"
  python3 "$BINDING_HELPER" preflight --hub "$hub" >/dev/null || die "hub preflight failed"
  acquire_protocol_lock "$hub" "$request_id"
  load_request_authority "$hub" "$request_id" "$coordinator_session_id"
  request="$REQUEST_PATH"
  store="$(dirname -- "$request")"
  binding_sha="$REQUEST_BINDING_SHA"
  [[ "$binding_sha" = "$request_id" ]] || die "request binding digest mismatch"
  if terminal_request_state "$hub" "$request_id" "$binding_sha"; then
    release_protocol_lock
    return 0
  fi
  attempt_one="$store/$request_id.attempt-1.json"
  attempt_two="$store/$request_id.attempt-2.json"
  failed_one="$store/$request_id.attempt-1.failed.json"
  failed_two="$store/$request_id.attempt-2.failed.json"
  if [[ ! -e "$attempt_one" ]]; then
    destination="$attempt_one"
    number=1
  else
    load_record_file attempt "$attempt_one" "$request_id" "$binding_sha" \
      || die "attempt one authority is malformed"
    existing="$(printf '%s' "$VALIDATED_RECORD_JSON" | jq -r '.thread_id')"
    [[ "$existing" = "$thread_id" ]] && return 0
    [[ -f "$failed_one" && ! -L "$failed_one" ]] \
      || die "first attempt is unresolved; duplicate continuation refused"
    load_record_file failed "$failed_one" "$request_id" "$binding_sha" \
      || die "attempt one failure authority is malformed"
    if [[ ! -e "$attempt_two" ]]; then
      destination="$attempt_two"
      number=2
    else
      load_record_file attempt "$attempt_two" "$request_id" "$binding_sha" \
        || die "attempt two authority is malformed"
      existing="$(printf '%s' "$VALIDATED_RECORD_JSON" | jq -r '.thread_id')"
      [[ "$existing" = "$thread_id" ]] && return 0
      if [[ -f "$failed_two" && ! -L "$failed_two" ]]; then
        load_record_file failed "$failed_two" "$request_id" "$binding_sha" \
          || die "attempt two failure authority is malformed"
        die "replacement limit reached"
      fi
      die "replacement attempt is unresolved; duplicate continuation refused"
    fi
  fi
  write_small_json "$destination" \
    --arg binding "$binding_sha" --arg request "$request_id" --arg thread "$thread_id" \
    --argjson attempt "$number" \
    '{attempt:$attempt,binding_sha256:$binding,request_id:$request,status:"provisional",thread_id:$thread}' \
    || die "concurrent continuation attempt won"
  fsync_paths "$destination" "$store"
  release_protocol_lock
}

attempt_number_for() {
  local hub="$1" request_id="$2" thread_id="$3" binding_sha="$4" store number path
  store="$hub/control/continuations/requests"
  for number in 1 2; do
    path="$store/$request_id.attempt-$number.json"
    if [[ -f "$path" && ! -L "$path" ]]; then
      load_record_file attempt "$path" "$request_id" "$binding_sha" \
        || die "attempt authority is malformed"
    fi
    if [[ -f "$path" && "$(printf '%s' "$VALIDATED_RECORD_JSON" | jq -r '.thread_id')" = "$thread_id" ]]; then
      printf '%s\n' "$number"
      return 0
    fi
  done
  return 1
}

reject_attempt() {
  local hub="$1" request_id="$2" thread_id="$3" coordinator_session_id="$4" reason="$5"
  local request number destination binding_sha store recorded_thread recorded_reason
  if ! strict_scalar "$thread_id" || ! strict_scalar "$reason"; then
    die "invalid rejection authority"
  fi
  strict_scalar "$coordinator_session_id" || die "invalid coordinator session id"
  python3 "$BINDING_HELPER" preflight --hub "$hub" >/dev/null || die "hub preflight failed"
  acquire_protocol_lock "$hub" "$request_id"
  load_request_authority "$hub" "$request_id" "$coordinator_session_id"
  request="$REQUEST_PATH"
  store="$(dirname -- "$request")"
  binding_sha="$REQUEST_BINDING_SHA"
  if terminal_request_state "$hub" "$request_id" "$binding_sha"; then
    if [[ "$TERMINAL_STATE" = accepted ]]; then
      release_protocol_lock
      return 0
    fi
    destination="$store/$request_id.attempt-2.failed.json"
    recorded_thread="$TERMINAL_THREAD"
    recorded_reason="$TERMINAL_REASON"
    [[ "$recorded_thread" = "$thread_id" && "$recorded_reason" = "$reason" ]] \
      || die "terminal reject replay conflicts with durable receipt"
    release_protocol_lock
    return 0
  fi
  number="$(attempt_number_for "$hub" "$request_id" "$thread_id" "$binding_sha")" \
    || die "provisional continuation attempt not found"
  destination="$store/$request_id.attempt-$number.failed.json"
  if [[ -e "$destination" ]]; then
    load_record_file failed "$destination" "$request_id" "$binding_sha" "$thread_id" \
      || die "failure receipt is malformed"
    recorded_reason="$(printf '%s' "$VALIDATED_RECORD_JSON" | jq -r '.reason')"
    [[ "$recorded_reason" = "$reason" ]] || die "reject replay reason conflicts with durable receipt"
    release_protocol_lock
    return 0
  fi
  write_small_json "$destination" \
    --arg binding "$binding_sha" --arg request "$request_id" --arg thread "$thread_id" --arg reason "$reason" \
    --argjson attempt "$number" \
    '{attempt:$attempt,binding_sha256:$binding,reason:$reason,request_id:$request,status:"failed",thread_id:$thread}' \
    || die "conflicting rejection receipt"
  fsync_paths "$destination" "$store"
  release_protocol_lock
}

accept_attempt() {
  local hub="$1" request_id="$2" thread_id="$3" coordinator_session_id="$4" health="$5"
  local request store number failed accepted binding_sha candidate health_candidate health_copy
  local health_sha health_stat health_device health_inode health_size receipt receipt_sha
  strict_scalar "$coordinator_session_id" || die "invalid coordinator session id"
  python3 "$BINDING_HELPER" preflight --hub "$hub" >/dev/null || die "hub preflight failed"
  acquire_protocol_lock "$hub" "$request_id"
  load_request_authority "$hub" "$request_id" "$coordinator_session_id"
  request="$REQUEST_PATH"
  store="$(dirname -- "$request")"
  binding_sha="$REQUEST_BINDING_SHA"
  [[ "$binding_sha" = "$request_id" ]] || die "request binding digest mismatch"
  if terminal_request_state "$hub" "$request_id" "$binding_sha"; then
    release_protocol_lock
    return 0
  fi
  [[ -f "$health" && ! -L "$health" ]] || die "health evidence is missing or unsafe"
  number="$(attempt_number_for "$hub" "$request_id" "$thread_id" "$binding_sha")" \
    || die "provisional continuation attempt not found"
  failed="$store/$request_id.attempt-$number.failed.json"
  if [[ -e "$failed" ]]; then
    [[ -f "$failed" && ! -L "$failed" ]] || die "failure receipt is unsafe"
    validate_record_file failed "$failed" "$request_id" "$binding_sha" "$thread_id" \
      || die "failure receipt is malformed"
    die "failed continuation attempt cannot be accepted"
  fi
  health_candidate="$(mktemp "$store/.health-copy.XXXXXX")"
  rm -f -- "$health_candidate"
  health_sha="$(python3 "$BINDING_HELPER" health-copy --path "$health" \
    --output "$health_candidate" --request-id "$request_id" --thread-id "$thread_id" \
    --binding-sha256 "$binding_sha")" \
    || die "continuation health evidence is incomplete or mismatched"
  health_copy="$store/$request_id.attempt-$number.health.json"
  publish_no_clobber "$health_candidate" "$health_copy" \
    || die "conflicting immutable health evidence"
  chmod 0600 "$health_copy"
  fsync_paths "$health_copy" "$store"
  health_stat="$(stat -f '%d %i %z' "$health_copy")" || die "could not stat health authority"
  read -r health_device health_inode health_size <<< "$health_stat"
  receipt="$store/$request_id.binding.json"
  receipt_sha="$(sha256_file "$receipt")"
  accepted="$store/$request_id.accepted.json"
  candidate="$(mktemp "$store/.accepted.XXXXXX")"
  jq -cS -n --arg binding "$binding_sha" --arg health_path "$health_copy" \
    --arg health_sha "$health_sha" --arg receipt_sha "$receipt_sha" \
    --arg request "$request_id" --arg thread "$thread_id" \
    --argjson attempt "$number" --argjson health_device "$health_device" \
    --argjson health_inode "$health_inode" --argjson health_size "$health_size" \
    '{attempt:$attempt,binding_sha256:$binding,health_evidence_device:$health_device,health_evidence_inode:$health_inode,health_evidence_path:$health_path,health_evidence_sha256:$health_sha,health_evidence_size:$health_size,health_verified:true,request_binding_receipt_sha256:$receipt_sha,request_id:$request,status:"accepted",thread_id:$thread}' \
    > "$candidate"
  publish_no_clobber "$candidate" "$accepted" || die "concurrent acceptance conflict"
  fsync_paths "$accepted" "$store"
  validate_record_file accepted "$accepted" "$request_id" "$binding_sha" "$thread_id" \
    || die "accepted receipt failed exact validation"
  release_protocol_lock
}

promotion_boundary() {
  local phase="$1"
  if [[ "${ORC_CONTINUATION_TEST_PROMOTION_SIGNAL_PHASE:-}" = "$phase" ]]; then
    kill -TERM "$$"
  fi
  if [[ "${ORC_CONTINUATION_TEST_PROMOTION_FAIL_PHASE:-}" = "$phase" ]]; then
    die "injected promotion failure at $phase"
  fi
}

promote_coordinator() {
  local hub="$1" request_id="$2" old_session="$3" new_session="$4"
  local request store binding_sha coordinators staged intent intent_candidate commit
  local new_hash new_authority old_hash superseded superseded_candidate
  local promotion promotion_candidate
  if ! strict_scalar "$old_session" || ! strict_scalar "$new_session"; then
    die "invalid coordinator promotion identity"
  fi
  python3 "$BINDING_HELPER" preflight --hub "$hub" >/dev/null || die "hub preflight failed"
  acquire_protocol_lock "$hub" "$request_id"
  load_request_authority "$hub" "$request_id" "$old_session"
  request="$REQUEST_PATH"
  store="$(dirname -- "$request")"
  binding_sha="$REQUEST_BINDING_SHA"
  terminal_request_state "$hub" "$request_id" "$binding_sha" \
    || die "promotion requires an accepted terminal request"
  [[ "$TERMINAL_STATE" = accepted ]] || die "failed request cannot promote a coordinator"
  [[ "$TERMINAL_THREAD" = "$new_session" ]] \
    || die "promotion thread is not the exact accepted continuation"
  coordinators="$hub/control/coordinators"
  [[ -d "$coordinators" && ! -L "$coordinators" ]] || die "coordinator store is unsafe"
  staged="$(python3 "$BINDING_HELPER" promotion-stage --hub "$hub" \
    --request-id "$request_id" --new-session "$new_session")" \
    || die "could not publish staged coordinator authority"
  promotion_boundary after_stage
  intent="$store/$request_id.promotion-intent.json"
  intent_candidate="$(mktemp "$store/.promotion-intent.XXXXXX")"
  rm -f -- "$intent_candidate"
  python3 "$BINDING_HELPER" promotion-commit --hub "$hub" --request-id "$request_id" \
    --old-session "$old_session" --new-session "$new_session" \
    --staged-authority "$staged" --output "$intent_candidate" \
    || die "could not build exact promotion intent"
  publish_no_clobber "$intent_candidate" "$intent" \
    || die "conflicting promotion intent"
  chmod 0600 "$intent"
  fsync_paths "$intent" "$store"
  promotion_boundary after_intent
  commit="$coordinators/$request_id.promotion-commit.json"
  if ! ln "$intent" "$commit" 2>/dev/null; then
    [[ -f "$commit" && ! -L "$commit" && "$intent" -ef "$commit" ]] \
      || die "conflicting promotion commit marker"
  fi
  chmod 0600 "$commit"
  fsync_paths "$commit" "$coordinators"
  python3 "$BINDING_HELPER" preflight --hub "$hub" >/dev/null \
    || die "promotion commit marker failed exact validation"
  promotion_boundary after_commit

  # Post-commit compatibility artifacts never control eligibility.
  new_hash="$(printf '%s\n' "$new_session" | shasum -a 256 | awk '{print $1}')"
  new_authority="$coordinators/$new_hash.session-id"
  if ! ln "$staged" "$new_authority" 2>/dev/null; then
    if [[ ! -f "$new_authority" || -L "$new_authority" ]] \
      || ! python3 "$BINDING_HELPER" compare --left "$staged" --right "$new_authority" >/dev/null 2>&1; then
      die "conflicting promoted coordinator authority"
    fi
  fi
  chmod 0600 "$new_authority"
  fsync_paths "$new_authority" "$coordinators"
  promotion_boundary after_new_authority
  old_hash="$(printf '%s\n' "$old_session" | shasum -a 256 | awk '{print $1}')"
  superseded="$coordinators/$old_hash.superseded.json"
  superseded_candidate="$(mktemp "$coordinators/.superseded.XXXXXX")"
  jq -cS -n --arg new "$new_session" --arg old "$old_session" --arg request "$request_id" \
    '{new_coordinator:$new,old_coordinator:$old,request_id:$request,status:"superseded"}' \
    > "$superseded_candidate"
  publish_no_clobber "$superseded_candidate" "$superseded" \
    || die "conflicting coordinator supersession receipt"
  chmod 0600 "$superseded"
  fsync_paths "$superseded" "$coordinators"
  promotion_boundary after_supersession
  promotion="$store/$request_id.promotion.json"
  promotion_candidate="$(mktemp "$store/.promotion.XXXXXX")"
  jq -cS -n --arg authority "$new_authority" --arg binding "$binding_sha" \
    --arg commit "$commit" --arg old "$old_session" --arg receipt "$promotion" \
    --arg request "$request_id" --arg staged "$staged" --arg superseded "$superseded" \
    --arg thread "$new_session" \
    '{authority_path:$authority,binding_sha256:$binding,commit_marker:$commit,old_coordinator:$old,promotion_receipt:$receipt,request_id:$request,staged_authority:$staged,status:"promoted",supersession_receipt:$superseded,thread_id:$thread}' \
    > "$promotion_candidate"
  publish_no_clobber "$promotion_candidate" "$promotion" \
    || die "conflicting coordinator promotion receipt"
  chmod 0600 "$promotion"
  fsync_paths "$new_authority" "$superseded" "$promotion" "$coordinators" "$store"
  promotion_boundary after_receipt
  release_protocol_lock
  jq -cS -n --arg authority "$new_authority" --arg receipt "$promotion" \
    --arg request "$request_id" --arg thread "$new_session" \
    '{authority_path:$authority,promotion_receipt:$receipt,request_id:$request,status:"promoted",thread_id:$thread}'
}

hook_mode() {
  local input event cwd hub session_id source result request_id request_path carryover classification
  local store path candidate_id matched_id="" binding_sha
  input="$(cat)"
  event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty')"
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
  session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
  strict_scalar "$cwd" && strict_scalar "$session_id" || exit 0
  hub="$(find_hub "$cwd" 2>/dev/null || true)"
  [[ -n "$hub" ]] || exit 0
  if ! classification="$(session_classification "$hub" "$session_id" 2>/dev/null)"; then
    if [[ "$event" = PreCompact ]]; then
      jq -nc '{continue:false,stopReason:"Orchestrator continuation authority is unsafe.",systemMessage:"Compaction stopped because durable coordinator authority could not be validated."}'
    fi
    exit 0
  fi
  [[ "$classification" = eligible ]] || exit 0
  case "$event" in
    PreCompact)
      source="$(printf '%s' "$input" | jq -r '.trigger // empty')"
      [[ "$source" = manual || "$source" = auto ]] || exit 0
      if ! result="$(publish_request "$hub" "$session_id" PreCompact "$source" 2>/dev/null)"; then
        jq -nc '{continue:false,stopReason:"Orchestrator continuation durability failed.",systemMessage:"Compaction stopped because carryover, request, or binding receipt durability was not proven."}'
        exit 0
      fi
      [[ -n "$result" ]] || exit 0
      request_id="${result%%$'\t'*}"
      jq -nc --arg message "Orchestrator durable carryover and exact continuation request $request_id were recorded before compaction. Do not create or resume any child from this hook." \
        '{continue:true,systemMessage:$message}'
      ;;
    SessionStart)
      source="$(printf '%s' "$input" | jq -r '.source // empty')"
      [[ "$source" = compact ]] || exit 0
      store="$hub/control/continuations/requests"
      [[ -d "$store" && ! -L "$store" ]] || exit 0
      for path in "$store"/*.json; do
        [[ -f "$path" && ! -L "$path" ]] || continue
        candidate_id="$(basename -- "$path" .json)"
        [[ "$candidate_id" =~ ^[0-9a-f]{64}$ ]] || continue
        if try_load_request_authority "$hub" "$candidate_id" "$session_id" 2>/dev/null; then
          request_path="$REQUEST_PATH"
          [[ -z "$matched_id" ]] || {
            jq -nc '{continue:false,stopReason:"Ambiguous Orchestrator continuation authority.",systemMessage:"Session continuation stopped because multiple exact requests matched."}'
            exit 0
          }
          matched_id="$candidate_id"
        fi
      done
      [[ -n "$matched_id" ]] || exit 0
      request_id="$matched_id"
      acquire_protocol_lock "$hub" "$request_id"
      load_request_authority "$hub" "$request_id" "$session_id"
      request_path="$REQUEST_PATH"
      binding_sha="$REQUEST_BINDING_SHA"
      if terminal_request_state "$hub" "$request_id" "$binding_sha"; then
        release_protocol_lock
        exit 0
      fi
      carryover="$REQUEST_CARRYOVER_PATH"
      release_protocol_lock
      jq -nc --arg context "Codex compacted this coordinator task. Read $carryover and request $request_id. Append any in-context-only knowledge before task creation; revalidate the exact mission/task generation/state snapshot; record one provisional fresh project-local Codex task through the adapter; apply the full continuation health check; then publish the accepted receipt. Never restart, resume, or duplicate an active child. If automatic task creation is unavailable, use the documented manual coordinator boundary." \
        '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$context}}'
      ;;
    *)
      exit 0
      ;;
  esac
}

manual_request() {
  local hub="$1" session_id="$2" canonical result request_id request_path classification
  canonical="$(canonical_dir "$hub")" || die "manual hub is missing or unsafe"
  [[ "$(basename -- "$canonical")" = .orchestrator ]] || die "manual hub must end in .orchestrator"
  strict_scalar "$session_id" || die "invalid manual source session id"
  classification="$(session_classification "$canonical" "$session_id")" \
    || die "manual coordinator authority is unsafe"
  [[ "$classification" = eligible ]] || die "session is not an eligible exact coordinator"
  result="$(publish_request "$canonical" "$session_id" manual unavailable)" \
    || die "no durable mission state is available"
  [[ -n "$result" ]] || return 0
  request_id="${result%%$'\t'*}"
  request_path="${result#*$'\t'}"
  jq -nc --arg request "$request_id" --arg path "$request_path" \
    '{request_id:$request,request_path:$path,status:"pending"}'
}

require_tool jq
require_tool python3
require_tool shasum

MODE=hook
HUB=""
SESSION_ID=""
REQUEST_ID=""
THREAD_ID=""
REASON=""
HEALTH=""
COORDINATOR_SESSION_ID=""

if [[ $# -gt 0 ]]; then
  MODE="$1"
  shift
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hub) HUB="${2:-}"; shift 2 ;;
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --request-id) REQUEST_ID="${2:-}"; shift 2 ;;
    --thread-id) THREAD_ID="${2:-}"; shift 2 ;;
    --coordinator-session-id) COORDINATOR_SESSION_ID="${2:-}"; shift 2 ;;
    --reason) REASON="${2:-}"; shift 2 ;;
    --health-evidence) HEALTH="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$MODE" in
  hook) hook_mode ;;
  --manual) manual_request "$HUB" "$SESSION_ID" ;;
  --record-attempt) record_attempt "$(canonical_dir "$HUB")" "$REQUEST_ID" "$THREAD_ID" "$COORDINATOR_SESSION_ID" ;;
  --reject-attempt) reject_attempt "$(canonical_dir "$HUB")" "$REQUEST_ID" "$THREAD_ID" "$COORDINATOR_SESSION_ID" "$REASON" ;;
  --accept) accept_attempt "$(canonical_dir "$HUB")" "$REQUEST_ID" "$THREAD_ID" "$COORDINATOR_SESSION_ID" "$HEALTH" ;;
  --promote-coordinator) promote_coordinator "$(canonical_dir "$HUB")" "$REQUEST_ID" "$COORDINATOR_SESSION_ID" "$THREAD_ID" ;;
  *) die "unknown mode: $MODE" ;;
esac
