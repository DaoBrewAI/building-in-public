#!/usr/bin/env bash
# Task 7 contract: durable, deduplicated Codex coordinator continuation.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_JSON="$ROOT/hooks/hooks.json"
ADAPTER="$ROOT/hooks/codex-continuation.sh"
BINDING_HELPER="$ROOT/hooks/codex-continuation-binding.py"
TEMPLATE="$ROOT/templates/continuation.md"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
CONTINUATION_REF="$ROOT/skills/orchestrating/references/continuation.md"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/orc-continuation-test.XXXXXX")"
TMP="$(cd -P "$TMP" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT

N=0
OK=0
check() {
  local label="$1"
  shift
  N=$((N + 1))
  if "$@"; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}

contains() {
  local file="$1" literal="$2"
  [[ -f "$file" ]] && grep -Fqi -- "$literal" "$file"
}

not_contains() {
  local file="$1" literal="$2"
  [[ -f "$file" ]] && ! grep -Fq -- "$literal" "$file"
}

json_expr() {
  local file="$1" expression="$2"
  [[ -f "$file" ]] && jq -e "$expression" "$file" >/dev/null
}

request_count() {
  local hub="$1"
  request_ids "$hub" | wc -l | tr -d ' '
}

request_file() {
  local hub="$1" request_id
  request_id="$(request_ids "$hub" | head -n 1)"
  [[ -n "$request_id" ]] && printf '%s/control/continuations/requests/%s.json\n' "$hub" "$request_id"
}

request_ids() {
  local hub="$1"
  find "$hub/control/continuations/requests" -maxdepth 1 -type f -name '*.json' \
    2>/dev/null | sed -n 's#.*/\([0-9a-f]\{64\}\)\.json$#\1#p' | sort
}

event_count() {
  local hub="$1" request_id="$2"
  find "$hub/control/continuations/requests" -maxdepth 1 -type f \
    -name "$request_id.event-*.json" 2>/dev/null | wc -l | tr -d ' '
}

store_fingerprint() {
  local hub="$1"
  find "$hub/control/continuations/requests" -maxdepth 1 -type f -print 2>/dev/null \
    | sort | while IFS= read -r path; do shasum -a 256 "$path"; done
}

wait_for_marker() {
  local marker="$1" count=0
  while (( count < 100 )); do
    [[ -f "$marker" ]] && return 0
    sleep 0.02
    count=$((count + 1))
  done
  return 1
}

make_request_fixture() {
  local name="$1" session_id="${2:-coordinator-review}"
  FIX_REPO="$TMP/$name"
  mkdir -p "$FIX_REPO"
  make_hub "$FIX_REPO"
  FIX_HUB="$FIX_REPO/.orchestrator"
  authorize_coordinator "$FIX_HUB" "$session_id"
  FIX_COORDINATOR="$session_id"
  "$ADAPTER" --manual --hub "$FIX_HUB" --session-id "$session_id" > "$FIX_REPO/manual.json"
  FIX_ID="$(jq -r .request_id "$FIX_REPO/manual.json")"
  FIX_REQUEST="$FIX_HUB/control/continuations/requests/$FIX_ID.json"
}

mutate_request() {
  local expression="$1" replacement
  replacement="$(mktemp "$FIX_HUB/control/continuations/requests/.mutation.XXXXXX")"
  jq -cS "$expression" "$FIX_REQUEST" > "$replacement"
  mv -f -- "$replacement" "$FIX_REQUEST"
}

record_attempt_fails() {
  ! "$ADAPTER" --record-attempt --hub "$FIX_HUB" --request-id "$FIX_ID" \
    --thread-id forged-continuation --coordinator-session-id "$FIX_COORDINATOR" >/dev/null 2>&1
}

request_digest() {
  jq -r '.binding_sha256 // .state_sha256 // empty' "$1"
}

write_health() {
  local path="$1" request_id="$2" thread_id="$3" digest="$4" status="${5:-inProgress}"
  jq -cS -n --arg request "$request_id" --arg thread "$thread_id" \
    --arg digest "$digest" --arg status "$status" '{
      binding_sha256: $digest, created: true, first_turn_exists: true,
      request_id: $request, settings_recorded: true, startup_evidence: true,
      state_sha256: $digest, status: $status, thread_id: $thread,
      title_verified: true, visible: true
    }' > "$path"
  chmod 0600 "$path"
}

classification() {
  python3 "$BINDING_HELPER" classify --hub "$1" --session-id "$2" 2>/dev/null
}

make_accepted_fixture() {
  local name="$1" old_session="$2" new_session="$3"
  make_request_fixture "$name" "$old_session"
  PROMO_REPO="$FIX_REPO"
  PROMO_HUB="$FIX_HUB"
  PROMO_ID="$FIX_ID"
  PROMO_OLD="$old_session"
  PROMO_NEW="$new_session"
  PROMO_REQUEST="$FIX_REQUEST"
  PROMO_DIGEST="$(request_digest "$PROMO_REQUEST")"
  "$ADAPTER" --record-attempt --hub "$PROMO_HUB" --request-id "$PROMO_ID" \
    --thread-id "$PROMO_NEW" --coordinator-session-id "$PROMO_OLD"
  write_health "$PROMO_REPO/health.json" "$PROMO_ID" "$PROMO_NEW" "$PROMO_DIGEST"
  "$ADAPTER" --accept --hub "$PROMO_HUB" --request-id "$PROMO_ID" \
    --thread-id "$PROMO_NEW" --coordinator-session-id "$PROMO_OLD" \
    --health-evidence "$PROMO_REPO/health.json"
}

sole_eligible_is() {
  local hub="$1" old_session="$2" new_session="$3" expected="$4" old_state new_state
  old_state="$(classification "$hub" "$old_session")" || return 1
  new_state="$(classification "$hub" "$new_session")" || return 1
  if [[ "$expected" = old ]]; then
    [[ "$old_state" = eligible && "$new_state" = unrelated ]]
  else
    [[ "$old_state" = unrelated && "$new_state" = eligible ]]
  fi
}

promotion_retry_fails_with_old_owner() {
  local hub="$1" request_id="$2" old_session="$3" new_session="$4"
  ! "$ADAPTER" --promote-coordinator --hub "$hub" --request-id "$request_id" \
    --coordinator-session-id "$old_session" --thread-id "$new_session" \
    >/dev/null 2>&1 \
    && sole_eligible_is "$hub" "$old_session" "$new_session" old
}

classifications_fail_closed() {
  local hub="$1" old_session="$2" new_session="$3"
  ! classification "$hub" "$old_session" >/dev/null 2>&1 \
    && ! classification "$hub" "$new_session" >/dev/null 2>&1
}

make_hub() {
  local repo="$1" hub
  hub="$repo/.orchestrator"
  mkdir -p "$hub/missions/mission-a" "$hub/control/mission-a/tasks/task-a"
  printf 'running\n' > "$hub/missions/mission-a/state"
  printf 'fable-opus\n' > "$hub/missions/mission-a/planning-backend"
  printf 'fable-opus\n' > "$hub/control/mission-a/planning-backend"
  printf 'session_id: fable-session\nbackend: claude-headless\nmodel: claude-fable-5\nstage: plan\n' > "$hub/missions/mission-a/session.txt"
  printf 'fable-session\n' > "$hub/control/mission-a/planning-session-id"
  printf 'running\n' > "$hub/control/mission-a/tasks/task-a/state"
  printf '3\n' > "$hub/control/mission-a/tasks/task-a/generation"
  printf 'child-thread-1\n' > "$hub/control/mission-a/tasks/task-a/accepted-thread-id"
}

authorize_coordinator() {
  local hub="$1" session_id="$2" digest
  digest="$(printf '%s\n' "$session_id" | shasum -a 256 | awk '{print $1}')"
  mkdir -p "$hub/control/coordinators"
  printf '%s\n' "$session_id" > "$hub/control/coordinators/$digest.session-id"
  chmod 0700 "$hub/control/coordinators"
  chmod 0600 "$hub/control/coordinators/$digest.session-id"
}

precompact_input() {
  local repo="$1" session_id="$2"
  jq -nc --arg cwd "$repo" --arg session "$session_id" '{
    cwd: $cwd,
    hook_event_name: "PreCompact",
    model: "gpt-5.6-sol",
    session_id: $session,
    transcript_path: null,
    trigger: "auto",
    turn_id: "turn-1"
  }'
}

session_start_input() {
  local repo="$1" session_id="$2"
  jq -nc --arg cwd "$repo" --arg session "$session_id" '{
    cwd: $cwd,
    hook_event_name: "SessionStart",
    model: "gpt-5.6-sol",
    permission_mode: "default",
    session_id: $session,
    source: "compact",
    transcript_path: null
  }'
}

check "Codex plugin bundles the documented default hooks manifest" test -f "$HOOKS_JSON"
check "hooks manifest is valid JSON" json_expr "$HOOKS_JSON" '.'
check "PreCompact invokes the Codex continuation adapter" \
  json_expr "$HOOKS_JSON" '.hooks.PreCompact[0].hooks[0].command | contains("${PLUGIN_ROOT}/hooks/codex-continuation.sh")'
check "SessionStart matches only the supported compact source" \
  json_expr "$HOOKS_JSON" '.hooks.SessionStart[0].matcher == "^compact$"'
check "SessionStart invokes the same continuation adapter" \
  json_expr "$HOOKS_JSON" '.hooks.SessionStart[0].hooks[0].command | contains("${PLUGIN_ROOT}/hooks/codex-continuation.sh")'
check "continuation adapter exists and is executable" test -x "$ADAPTER"
check "binding helper declares Python 3.9 compatible syntax" \
  sh -c '! grep -Eq "[[:alnum:]_\\]] \\| None|None \\|" "$1"' sh "$BINDING_HELPER"
check "fresh-task continuation template exists" test -f "$TEMPLATE"
check "template binds mission generation and durable state" contains "$TEMPLATE" '{{STATE_SHA256}}'
check "template requires a fresh task rather than a fork" contains "$TEMPLATE" 'fresh project-local Codex task'
check "template requires health-check acceptance" contains "$TEMPLATE" 'health check'
check "template names the explicit coordinator promotion operation" contains "$TEMPLATE" '--promote-coordinator'
check "template documents inactive staging and the atomic promotion commit" contains "$TEMPLATE" 'promotion-commit'
check "Codex continuation files do not claim an exact 65 percent threshold" \
  sh -c '! grep -Eiq "(^|[^0-9])65%|sixty-five" "$1" "$2" "$3"' sh "$HOOKS_JSON" "$ADAPTER" "$TEMPLATE"
check "adapter does not parse unstable transcript contents" not_contains "$ADAPTER" 'transcript_path" | jq'
check "coordinator skill documents the Codex continuation boundary" contains "$CONTINUATION_REF" '# Durable coordinator continuation'
check "coordinator skill requires durable state before a request" contains "$CONTINUATION_REF" 'before recording'
check "coordinator skill binds continuation to mission generation and state" contains "$CONTINUATION_REF" 'mission/task paths'
check "coordinator skill keeps active child execution untouched" contains "$CONTINUATION_REF" 'Never restart, replace'
check "coordinator skill permits at most one replacement" contains "$CONTINUATION_REF" 'at most one'
check "coordinator skill accepts only a health-checked continuation" contains "$CONTINUATION_REF" 'accepted continuation receipt'
check "coordinator skill requires explicit accepted-thread promotion" contains "$CONTINUATION_REF" '--promote-coordinator'
check "coordinator skill makes staged promotion authority inactive" contains "$CONTINUATION_REF" 'staged authority is inactive'
check "coordinator skill declares Python 3.9 minimum" contains "$CONTINUATION_REF" 'Python 3.9'
check "coordinator skill documents the manual fallback boundary" contains "$CONTINUATION_REF" 'manual coordinator boundary'
check "coordinator skill denies an exact Codex context percentage" contains "$CONTINUATION_REF" 'exact Codex context percentage is unavailable'

if [[ -x "$ADAPTER" ]]; then
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  make_hub "$REPO"
  HUB="$REPO/.orchestrator"
  authorize_coordinator "$HUB" coordinator-thread-1

  precompact_input "$REPO" child-thread-1 | "$ADAPTER" > "$TMP/child.out"
  check "accepted child sessions never request coordinator continuation" \
    test "$(request_count "$HUB")" = 0

  MALFORMED="$TMP/malformed"
  mkdir -p "$MALFORMED"
  make_hub "$MALFORMED"
  authorize_coordinator "$MALFORMED/.orchestrator" malformed-coordinator
  printf 'running\nforged' > "$MALFORMED/.orchestrator/missions/mission-a/state"
  precompact_input "$MALFORMED" malformed-coordinator | "$ADAPTER" > "$TMP/malformed.out"
  check "multiline authority without a final newline fails closed" \
    test "$(request_count "$MALFORMED/.orchestrator")" = 0

  STORE_ESCAPE="$TMP/store-escape"
  STORE_OUTSIDE="$TMP/store-escape-outside"
  mkdir -p "$STORE_ESCAPE" "$STORE_OUTSIDE"
  make_hub "$STORE_ESCAPE"
  authorize_coordinator "$STORE_ESCAPE/.orchestrator" store-escape
  ln -s -- "$STORE_OUTSIDE" "$STORE_ESCAPE/.orchestrator/control/continuations"
  check "symlinked continuation-store ancestor is rejected before mutation" \
    sh -c '! "$1" --manual --hub "$2" --session-id store-escape >/dev/null 2>&1 && test ! -e "$3/requests"' \
      sh "$ADAPTER" "$STORE_ESCAPE/.orchestrator" "$STORE_OUTSIDE"

  CONTROL_ESCAPE="$TMP/control-escape"
  CONTROL_OUTSIDE="$TMP/control-escape-outside"
  mkdir -p "$CONTROL_ESCAPE/.orchestrator/missions/mission-a" \
    "$CONTROL_ESCAPE/.orchestrator/control" "$CONTROL_OUTSIDE/mission-a/tasks/task-a"
  printf 'running\n' > "$CONTROL_ESCAPE/.orchestrator/missions/mission-a/state"
  printf 'running\n' > "$CONTROL_OUTSIDE/mission-a/tasks/task-a/state"
  printf '3\n' > "$CONTROL_OUTSIDE/mission-a/tasks/task-a/generation"
  printf 'external-child\n' > "$CONTROL_OUTSIDE/mission-a/tasks/task-a/accepted-thread-id"
  authorize_coordinator "$CONTROL_ESCAPE/.orchestrator" control-escape
  ln -s -- "$CONTROL_OUTSIDE/mission-a" "$CONTROL_ESCAPE/.orchestrator/control/mission-a"
  check "symlinked control mission cannot import external tasks or mutate the store" \
    sh -c '! "$1" --manual --hub "$2" --session-id control-escape >/dev/null 2>&1 && test ! -e "$2/control/continuations"' \
      sh "$ADAPTER" "$CONTROL_ESCAPE/.orchestrator"

  CARRYOVER_ESCAPE="$TMP/carryover-escape"
  CARRYOVER_OUTSIDE="$TMP/carryover-outside.md"
  mkdir -p "$CARRYOVER_ESCAPE"
  make_hub "$CARRYOVER_ESCAPE"
  authorize_coordinator "$CARRYOVER_ESCAPE/.orchestrator" carryover-escape
  printf 'outside-original\n' > "$CARRYOVER_OUTSIDE"
  ln -s -- "$CARRYOVER_OUTSIDE" "$CARRYOVER_ESCAPE/.orchestrator/CARRYOVER.md"
  check "symlinked global carryover is rejected without changing its target" \
    sh -c '! "$1" --manual --hub "$2" --session-id carryover-escape >/dev/null 2>&1 && test "$(cat "$3")" = outside-original' \
      sh "$ADAPTER" "$CARRYOVER_ESCAPE/.orchestrator" "$CARRYOVER_OUTSIDE"

  precompact_input "$REPO" coordinator-thread-1 | "$ADAPTER" > "$TMP/precompact.out"
  REQ_FILE="$(request_file "$HUB")"
  REQ_ID="$(jq -r '.request_id // empty' "$REQ_FILE" 2>/dev/null)"
  check "PreCompact publishes exactly one durable request" test "$(request_count "$HUB")" = 1
  check "PreCompact returns supported JSON output" \
    json_expr "$TMP/precompact.out" '.continue == true and (.systemMessage | type == "string")'
  check "request has the exact canonical wrapper key set" \
    json_expr "$REQ_FILE" 'keys == ["binding","binding_sha256","request_id"]'
  check "request ID equals the complete binding digest" \
    json_expr "$REQ_FILE" '.request_id == .binding_sha256'
  check "request ID recomputes from canonical complete binding bytes" \
    python3 - "$REQ_FILE" <<'PY'
import hashlib
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    request = json.load(handle)
binding = json.dumps(request["binding"], ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()
raise SystemExit(0 if hashlib.sha256(binding).hexdigest() == request["request_id"] else 1)
PY
  check "request binds the exact source session" json_expr "$REQ_FILE" '.binding.source.coordinator_thread_id == "coordinator-thread-1"'
  check "request binds exact mission state" json_expr "$REQ_FILE" '.binding.missions[0].mission == "mission-a" and .binding.missions[0].state.value == "running"'
  check "request binds matching planning backend authority" json_expr "$REQ_FILE" '.binding.missions[0].planning_backend.mission.value == "fable-opus" and .binding.missions[0].planning_backend.control.value == "fable-opus"'
  check "request binds accepted planning session identity and session bytes" \
    json_expr "$REQ_FILE" '.binding.missions[0].planning_session.value == "fable-session" and (.binding.missions[0].session.sha256 | length) == 64 and .binding.missions[0].quota_fallbacks == {plan:null,review:null}'
  check "request binds exact task generation and state" \
    json_expr "$REQ_FILE" '.binding.missions[0].tasks[0].task == "task-a" and .binding.missions[0].tasks[0].generation.value == "3" and .binding.missions[0].tasks[0].state.value == "running"'
  BOUND_CARRYOVER="$(jq -r '.binding.carryover.path // .carryover_path' "$REQ_FILE")"
  check "carryover is published before and hash-bound by the request" \
    sh -c 'expected=$(jq -r .binding.carryover.sha256 "$1") && actual=$(shasum -a 256 "$2") && actual=${actual%% *} && test "$expected" = "$actual"' sh "$REQ_FILE" "$BOUND_CARRYOVER"

  FABLE_REDIRECT="$TMP/fable-session-redirect"
  mkdir -p "$FABLE_REDIRECT"
  make_hub "$FABLE_REDIRECT"
  authorize_coordinator "$FABLE_REDIRECT/.orchestrator" redirect-coordinator
  printf 'other-session\n' > "$FABLE_REDIRECT/.orchestrator/control/mission-a/planning-session-id"
  check "continuation rejects worker/session authority redirection" \
    sh -c '! "$1" --manual --hub "$2" --session-id redirect-coordinator >/dev/null 2>&1' \
      sh "$ADAPTER" "$FABLE_REDIRECT/.orchestrator"

  CODEX_UNBOUND="$TMP/codex-unbound"
  mkdir -p "$CODEX_UNBOUND"
  make_hub "$CODEX_UNBOUND"
  authorize_coordinator "$CODEX_UNBOUND/.orchestrator" codex-unbound-coordinator
  printf 'codex-ultra\n' > "$CODEX_UNBOUND/.orchestrator/missions/mission-a/planning-backend"
  printf 'codex-ultra\n' > "$CODEX_UNBOUND/.orchestrator/control/mission-a/planning-backend"
  rm "$CODEX_UNBOUND/.orchestrator/missions/mission-a/session.txt" \
    "$CODEX_UNBOUND/.orchestrator/control/mission-a/planning-session-id"
  check "continuation rejects a running Codex Ultra mission without accepted planning task" \
    sh -c '! "$1" --manual --hub "$2" --session-id codex-unbound-coordinator >/dev/null 2>&1' \
      sh "$ADAPTER" "$CODEX_UNBOUND/.orchestrator"

  CODEX_BOUND="$TMP/codex-bound"
  mkdir -p "$CODEX_BOUND"
  make_hub "$CODEX_BOUND"
  authorize_coordinator "$CODEX_BOUND/.orchestrator" codex-bound-coordinator
  printf 'codex-ultra\n' > "$CODEX_BOUND/.orchestrator/missions/mission-a/planning-backend"
  printf 'codex-ultra\n' > "$CODEX_BOUND/.orchestrator/control/mission-a/planning-backend"
  rm "$CODEX_BOUND/.orchestrator/control/mission-a/planning-session-id"
  printf 'backend: codex-native\nmodel: gpt-5.6-sol\neffort: ultra\nthread_id: planning-thread\nstage: plan\n' > "$CODEX_BOUND/.orchestrator/missions/mission-a/session.txt"
  printf 'planning-thread\n' > "$CODEX_BOUND/.orchestrator/control/mission-a/planning-thread-id"
  jq -cS -n --arg cwd "$CODEX_BOUND/planning-worktree" '{
    created:true, visible:true, title_verified:true, first_turn_exists:true,
    startup_evidence:true, settings_recorded:true, writable_root_verified:true,
    status:"completed", thread_id:"planning-thread", model:"gpt-5.6-sol",
    effort:"ultra", project_id:"project-1", cwd:$cwd
  }' > "$CODEX_BOUND/.orchestrator/control/mission-a/planning-thread-health.json"
  "$ADAPTER" --manual --hub "$CODEX_BOUND/.orchestrator" \
    --session-id codex-bound-coordinator > "$CODEX_BOUND/request.json"
  CODEX_BOUND_REQ="$(request_file "$CODEX_BOUND/.orchestrator")"
  check "continuation binds complete Codex Ultra task identity and health" \
    json_expr "$CODEX_BOUND_REQ" '.binding.missions[0].planning_thread.value == "planning-thread" and (.binding.missions[0].planning_health.sha256 | length) == 64 and .binding.missions[0].planning_session == null'

  FABLE_FALLBACK="$TMP/fable-fallback"
  mkdir -p "$FABLE_FALLBACK"
  make_hub "$FABLE_FALLBACK"
  authorize_coordinator "$FABLE_FALLBACK/.orchestrator" fallback-coordinator
  jq -cS -n '{from:"claude-fable-5",session_id:"fable-session",stage:"plan",to:"claude-opus-5"}' > "$FABLE_FALLBACK/.orchestrator/control/mission-a/quota-fallback-plan.json"
  "$ADAPTER" --manual --hub "$FABLE_FALLBACK/.orchestrator" \
    --session-id fallback-coordinator > "$FABLE_FALLBACK/request.json"
  FABLE_FALLBACK_REQ="$(request_file "$FABLE_FALLBACK/.orchestrator")"
  check "continuation binds the exact session-scoped Opus fallback receipt" \
    json_expr "$FABLE_FALLBACK_REQ" '(.binding.missions[0].quota_fallbacks.plan.sha256 | length) == 64 and .binding.missions[0].quota_fallbacks.review == null'

  UNRELATED="$TMP/unrelated-session"
  mkdir -p "$UNRELATED"
  make_hub "$UNRELATED"
  authorize_coordinator "$UNRELATED/.orchestrator" authorized-coordinator
  precompact_input "$UNRELATED" unrelated-session | "$ADAPTER" > "$UNRELATED/unrelated.out"
  check "unrelated non-child session cannot publish or emit continuation" \
    sh -c 'test ! -s "$1" && test "$(find "$2/control/continuations/requests" -type f 2>/dev/null | wc -l | tr -d " ")" = 0' \
      sh "$UNRELATED/unrelated.out" "$UNRELATED/.orchestrator"

  TERMINAL="$TMP/terminal-mission"
  mkdir -p "$TERMINAL"
  make_hub "$TERMINAL"
  authorize_coordinator "$TERMINAL/.orchestrator" terminal-coordinator
  printf 'accepted\n' > "$TERMINAL/.orchestrator/missions/mission-a/state"
  precompact_input "$TERMINAL" terminal-coordinator | "$ADAPTER" > "$TERMINAL/terminal.out"
  check "terminal accepted mission cannot publish or emit continuation" \
    sh -c 'test ! -s "$1" && test "$(find "$2/control/continuations/requests" -type f 2>/dev/null | wc -l | tr -d " ")" = 0' \
      sh "$TERMINAL/terminal.out" "$TERMINAL/.orchestrator"

  DURABILITY_FAIL="$TMP/durability-failure"
  mkdir -p "$DURABILITY_FAIL"
  make_hub "$DURABILITY_FAIL"
  authorize_coordinator "$DURABILITY_FAIL/.orchestrator" durability-coordinator
  precompact_input "$DURABILITY_FAIL" durability-coordinator \
    | ORC_CONTINUATION_TEST_FAIL_DURABILITY=1 "$ADAPTER" > "$DURABILITY_FAIL/hook.out"
  check "PreCompact durability failure returns a valid blocking response" \
    json_expr "$DURABILITY_FAIL/hook.out" '.continue == false and (.stopReason | type == "string") and (.systemMessage | type == "string")'
  check "PreCompact durability failure publishes no request" \
    test "$(request_count "$DURABILITY_FAIL/.orchestrator")" = 0

  precompact_input "$REPO" coordinator-thread-1 | "$ADAPTER" > "$TMP/precompact-duplicate.out"
  check "crash or retry reuses the exact durable request" test "$(request_count "$HUB")" = 1

  session_start_input "$REPO" coordinator-thread-1 | "$ADAPTER" > "$TMP/session-start.out"
  check "compact SessionStart injects the exact request into the immediate continuation" \
    jq -e --arg id "$REQ_ID" '.hookSpecificOutput.hookEventName == "SessionStart" and (.hookSpecificOutput.additionalContext | contains($id))' "$TMP/session-start.out" >/dev/null

  AUTO_MANUAL="$TMP/auto-then-manual"
  mkdir -p "$AUTO_MANUAL"
  make_hub "$AUTO_MANUAL"
  authorize_coordinator "$AUTO_MANUAL/.orchestrator" equivalent-coordinator
  precompact_input "$AUTO_MANUAL" equivalent-coordinator | "$ADAPTER" > "$AUTO_MANUAL/auto.out"
  AUTO_FIRST_ID="$(request_ids "$AUTO_MANUAL/.orchestrator" | head -n 1)"
  "$ADAPTER" --manual --hub "$AUTO_MANUAL/.orchestrator" --session-id equivalent-coordinator > "$AUTO_MANUAL/manual.out"
  request_ids "$AUTO_MANUAL/.orchestrator" > "$AUTO_MANUAL/ids.txt"
  check "auto then manual converges to one exact request ID" \
    sh -c 'test "$(wc -l < "$1" | tr -d " ")" = 1 && test "$(cat "$1")" = "$2"' \
      sh "$AUTO_MANUAL/ids.txt" "$AUTO_FIRST_ID"
  check "auto then manual records trigger provenance outside identity" \
    test "$(event_count "$AUTO_MANUAL/.orchestrator" "$AUTO_FIRST_ID")" = 2
  session_start_input "$AUTO_MANUAL" equivalent-coordinator | "$ADAPTER" > "$AUTO_MANUAL/session.out"
  check "auto then manual SessionStart emits the sole request" \
    jq -e --arg id "$AUTO_FIRST_ID" '.hookSpecificOutput.additionalContext | contains($id)' "$AUTO_MANUAL/session.out" >/dev/null

  MANUAL_AUTO="$TMP/manual-then-auto"
  mkdir -p "$MANUAL_AUTO"
  make_hub "$MANUAL_AUTO"
  authorize_coordinator "$MANUAL_AUTO/.orchestrator" reverse-coordinator
  "$ADAPTER" --manual --hub "$MANUAL_AUTO/.orchestrator" --session-id reverse-coordinator > "$MANUAL_AUTO/manual.out"
  MANUAL_FIRST_ID="$(jq -r .request_id "$MANUAL_AUTO/manual.out")"
  precompact_input "$MANUAL_AUTO" reverse-coordinator | "$ADAPTER" > "$MANUAL_AUTO/auto.out"
  request_ids "$MANUAL_AUTO/.orchestrator" > "$MANUAL_AUTO/ids.txt"
  check "manual then auto converges to one exact request ID" \
    sh -c 'test "$(wc -l < "$1" | tr -d " ")" = 1 && test "$(cat "$1")" = "$2"' \
      sh "$MANUAL_AUTO/ids.txt" "$MANUAL_FIRST_ID"
  check "manual then auto records trigger provenance outside identity" \
    test "$(event_count "$MANUAL_AUTO/.orchestrator" "$MANUAL_FIRST_ID")" = 2
  session_start_input "$MANUAL_AUTO" reverse-coordinator | "$ADAPTER" > "$MANUAL_AUTO/session.out"
  check "manual then auto SessionStart emits the sole request" \
    jq -e --arg id "$MANUAL_FIRST_ID" '.hookSpecificOutput.additionalContext | contains($id)' "$MANUAL_AUTO/session.out" >/dev/null

  EQUIVALENT_RACE="$TMP/equivalent-race"
  mkdir -p "$EQUIVALENT_RACE"
  make_hub "$EQUIVALENT_RACE"
  authorize_coordinator "$EQUIVALENT_RACE/.orchestrator" race-equivalent-coordinator
  precompact_input "$EQUIVALENT_RACE" race-equivalent-coordinator \
    | "$ADAPTER" > "$EQUIVALENT_RACE/auto.out" &
  EQUIVALENT_AUTO_PID=$!
  "$ADAPTER" --manual --hub "$EQUIVALENT_RACE/.orchestrator" \
    --session-id race-equivalent-coordinator > "$EQUIVALENT_RACE/manual.out" &
  EQUIVALENT_MANUAL_PID=$!
  wait "$EQUIVALENT_AUTO_PID" "$EQUIVALENT_MANUAL_PID"
  EQUIVALENT_ID="$(request_ids "$EQUIVALENT_RACE/.orchestrator" | head -n 1)"
  check "concurrent equivalent auto and manual calls publish one request" \
    test "$(request_ids "$EQUIVALENT_RACE/.orchestrator" | wc -l | tr -d ' ')" = 1
  check "concurrent equivalent calls preserve both provenance receipts" \
    test "$(event_count "$EQUIVALENT_RACE/.orchestrator" "$EQUIVALENT_ID")" = 2
  session_start_input "$EQUIVALENT_RACE" race-equivalent-coordinator | "$ADAPTER" > "$EQUIVALENT_RACE/session.out"
  check "concurrent equivalent calls leave SessionStart unambiguous" \
    jq -e --arg id "$EQUIVALENT_ID" '.hookSpecificOutput.additionalContext | contains($id)' "$EQUIVALENT_RACE/session.out" >/dev/null

  SNAPSHOT_SWAP="$TMP/snapshot-swap"
  mkdir -p "$SNAPSHOT_SWAP"
  make_hub "$SNAPSHOT_SWAP"
  authorize_coordinator "$SNAPSHOT_SWAP/.orchestrator" snapshot-coordinator
  SNAPSHOT_MARKER="$SNAPSHOT_SWAP/snapshot-read"
  (
    set +e
    ORC_CONTINUATION_TEST_SNAPSHOT_READ_MARKER="$SNAPSHOT_MARKER" \
      "$ADAPTER" --manual --hub "$SNAPSHOT_SWAP/.orchestrator" \
      --session-id snapshot-coordinator > "$SNAPSHOT_SWAP/manual.out" 2> "$SNAPSHOT_SWAP/manual.err"
    printf '%s\n' "$?" > "$SNAPSHOT_SWAP/manual.rc"
  ) &
  SNAPSHOT_PID=$!
  SNAPSHOT_READY=0
  if wait_for_marker "$SNAPSHOT_MARKER"; then SNAPSHOT_READY=1; fi
  printf '4\n' > "$SNAPSHOT_SWAP/.orchestrator/control/mission-a/tasks/task-a/generation"
  : > "$SNAPSHOT_MARKER.release"
  wait "$SNAPSHOT_PID"
  check "generation swap test reaches the single-snapshot barrier" test "$SNAPSHOT_READY" = 1
  check "generation swap fails or publishes internally exact carryover and binding" \
    python3 - "$SNAPSHOT_SWAP" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
rc = int((root / "manual.rc").read_text().strip())
if rc != 0:
    raise SystemExit(0)
result = json.loads((root / "manual.out").read_text())
request = json.loads(pathlib.Path(result["request_path"]).read_text())
generation = request["binding"]["missions"][0]["tasks"][0]["generation"]["value"]
carryover = pathlib.Path(request["binding"]["carryover"]["path"]).read_text()
needle = f"task\tmission-a\ttask-a\t{generation}\t"
raise SystemExit(0 if needle in carryover else 1)
PY

  STORE_SWAP="$TMP/store-mkdir-swap"
  STORE_SWAP_OUTSIDE="$TMP/store-mkdir-outside"
  mkdir -p "$STORE_SWAP" "$STORE_SWAP_OUTSIDE"
  make_hub "$STORE_SWAP"
  authorize_coordinator "$STORE_SWAP/.orchestrator" store-swap-coordinator
  STORE_MARKER="$STORE_SWAP/store-before-mkdir"
  (
    set +e
    ORC_CONTINUATION_TEST_STORE_BEFORE_MKDIR_MARKER="$STORE_MARKER" \
      "$ADAPTER" --manual --hub "$STORE_SWAP/.orchestrator" \
      --session-id store-swap-coordinator > "$STORE_SWAP/manual.out" 2> "$STORE_SWAP/manual.err"
    printf '%s\n' "$?" > "$STORE_SWAP/manual.rc"
  ) &
  STORE_SWAP_PID=$!
  STORE_SWAP_READY=0
  if wait_for_marker "$STORE_MARKER"; then
    STORE_SWAP_READY=1
    mv "$STORE_SWAP/.orchestrator/control/continuations" \
      "$STORE_SWAP/.orchestrator/control/continuations.original"
    ln -s "$STORE_SWAP_OUTSIDE" "$STORE_SWAP/.orchestrator/control/continuations"
  fi
  : > "$STORE_MARKER.release"
  wait "$STORE_SWAP_PID"
  check "store swap test reaches the dirfd mkdir barrier" test "$STORE_SWAP_READY" = 1
  check "store ancestor swap fails without external mutation" \
    sh -c 'test "$(cat "$1")" != 0 && test ! -e "$2/requests" && test ! -e "$2/carryovers"' \
      sh "$STORE_SWAP/manual.rc" "$STORE_SWAP_OUTSIDE"

  make_request_fixture mutate-mission
  mutate_request '.binding.missions[0].mission = "forged-mission"'
  check "mission identity mutation is rejected at record-attempt" record_attempt_fails

  make_request_fixture mutate-mission-path
  mutate_request '.binding.missions[0].path = "/forged/mission"'
  check "mission path mutation is rejected at record-attempt" record_attempt_fails

  make_request_fixture mutate-generation
  mutate_request '.binding.missions[0].tasks[0].generation.value = "4"'
  check "task generation mutation is rejected at record-attempt" record_attempt_fails

  make_request_fixture mutate-state-bytes
  mutate_request '.binding.missions[0].tasks[0].state.bytes_b64 = "Zm9yZ2VkCg=="'
  check "task state bytes mutation is rejected at record-attempt" record_attempt_fails

  make_request_fixture mutate-state-hash
  mutate_request '.binding.missions[0].tasks[0].state.sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
  check "task state hash mutation is rejected at record-attempt" record_attempt_fails

  make_request_fixture mutate-state-inode
  mutate_request '.binding.missions[0].tasks[0].state.inode += 1'
  check "task state inode mutation is rejected at record-attempt" record_attempt_fails

  make_request_fixture mutate-accepted-child
  mutate_request '.binding.missions[0].tasks[0].accepted_thread.value = "forged-child-thread"'
  check "accepted active-child identity mutation is rejected at record-attempt" record_attempt_fails

  make_request_fixture mutate-accepted-state
  mutate_request '.binding.missions[0].tasks[0].state.value = "completed"'
  check "accepted active-child state mutation is rejected at record-attempt" record_attempt_fails

  make_request_fixture mutate-carryover-path
  mutate_request '.binding.carryover.path = "/forged/CARRYOVER.md"'
  check "carryover path mutation is rejected at record-attempt" record_attempt_fails

  make_request_fixture mutate-carryover-hash
  mutate_request '.binding.carryover.sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
  check "carryover hash mutation is rejected at record-attempt" record_attempt_fails

  make_request_fixture mutate-trigger
  mutate_request '.binding.source.trigger = "forged"'
  check "trigger mutation is rejected at record-attempt" record_attempt_fails

  make_request_fixture mutate-source
  mutate_request '.binding.source.event = "forged"'
  check "source event mutation is rejected at record-attempt" record_attempt_fails

  make_request_fixture mutate-coordinator
  mutate_request '.binding.source.coordinator_thread_id = "forged-coordinator"'
  check "coordinator thread mutation is rejected at record-attempt" record_attempt_fails

  make_request_fixture multiline-request
  jq . "$FIX_REQUEST" > "$FIX_REPO/pretty-request.json"
  mv -f -- "$FIX_REPO/pretty-request.json" "$FIX_REQUEST"
  check "multiline request JSON is rejected" record_attempt_fails

  make_request_fixture malformed-request
  printf '{malformed\n' > "$FIX_REPO/malformed.json"
  mv -f -- "$FIX_REPO/malformed.json" "$FIX_REQUEST"
  check "malformed request JSON is rejected" record_attempt_fails

  make_request_fixture symlink-request
  mv -- "$FIX_REQUEST" "$FIX_REQUEST.target"
  ln -s -- "$FIX_REQUEST.target" "$FIX_REQUEST"
  check "symlink request is rejected" record_attempt_fails

  make_request_fixture stale-carryover
  FIX_BOUND_CARRYOVER="$(jq -r '.binding.carryover.path // .carryover_path' "$FIX_REQUEST")"
  chmod u+w "$FIX_BOUND_CARRYOVER"
  printf '\nforged carryover\n' >> "$FIX_BOUND_CARRYOVER"
  check "current carryover drift is rejected at record-attempt" record_attempt_fails

  make_request_fixture stale-hub
  printf '4\n' > "$FIX_HUB/control/mission-a/tasks/task-a/generation"
  check "current hub generation drift is rejected at record-attempt" record_attempt_fails

  make_request_fixture mutated-session-start session-review
  mutate_request '.binding.missions[0].tasks[0].accepted_thread.value = "forged-child-thread"'
  session_start_input "$FIX_REPO" session-review | "$ADAPTER" > "$FIX_REPO/session-start.out"
  check "SessionStart rejects a mutated exact-binding request" test ! -s "$FIX_REPO/session-start.out"

  make_request_fixture accept-child-mutation accept-child-coordinator
  ACCEPT_MUTATION_DIGEST="$(request_digest "$FIX_REQUEST")"
  "$ADAPTER" --record-attempt --hub "$FIX_HUB" --request-id "$FIX_ID" \
    --thread-id accept-child-thread --coordinator-session-id accept-child-coordinator
  write_health "$FIX_REPO/health.json" "$FIX_ID" accept-child-thread "$ACCEPT_MUTATION_DIGEST"
  mutate_request '.binding.missions[0].tasks[0].accepted_thread.value = "forged-child-thread"'
  check "accept rejects post-attempt accepted-child request mutation" \
    sh -c '! "$1" --accept --hub "$2" --request-id "$3" --thread-id accept-child-thread --coordinator-session-id accept-child-coordinator --health-evidence "$4" >/dev/null 2>&1 && test ! -e "$2/control/continuations/requests/$3.accepted.json"' \
      sh "$ADAPTER" "$FIX_HUB" "$FIX_ID" "$FIX_REPO/health.json"

  make_request_fixture accept-generation-mutation accept-generation-coordinator
  ACCEPT_MUTATION_DIGEST="$(request_digest "$FIX_REQUEST")"
  "$ADAPTER" --record-attempt --hub "$FIX_HUB" --request-id "$FIX_ID" \
    --thread-id accept-generation-thread --coordinator-session-id accept-generation-coordinator
  write_health "$FIX_REPO/health.json" "$FIX_ID" accept-generation-thread "$ACCEPT_MUTATION_DIGEST"
  mutate_request '.binding.missions[0].tasks[0].generation.value = "999"'
  check "accept rejects post-attempt generation request mutation" \
    sh -c '! "$1" --accept --hub "$2" --request-id "$3" --thread-id accept-generation-thread --coordinator-session-id accept-generation-coordinator --health-evidence "$4" >/dev/null 2>&1 && test ! -e "$2/control/continuations/requests/$3.accepted.json"' \
      sh "$ADAPTER" "$FIX_HUB" "$FIX_ID" "$FIX_REPO/health.json"

  make_request_fixture fd-safe-open fd-safe-coordinator
  FD_EXTERNAL="$FIX_REPO/external-request.json"
  cp "$FIX_REQUEST" "$FD_EXTERNAL"
  chmod 0600 "$FD_EXTERNAL"
  FD_MARKER="$FIX_REPO/safe-regular-open"
  (
    set +e
    ORC_CONTINUATION_TEST_SAFE_REGULAR_TARGET="$FIX_REQUEST" \
      ORC_CONTINUATION_TEST_SAFE_REGULAR_MARKER="$FD_MARKER" \
      "$ADAPTER" --record-attempt --hub "$FIX_HUB" --request-id "$FIX_ID" \
      --thread-id fd-safe-thread --coordinator-session-id fd-safe-coordinator \
      > "$FIX_REPO/fd-safe.out" 2> "$FIX_REPO/fd-safe.err"
    printf '%s\n' "$?" > "$FIX_REPO/fd-safe.rc"
  ) &
  FD_SAFE_PID=$!
  FD_SAFE_READY=0
  if wait_for_marker "$FD_MARKER"; then
    FD_SAFE_READY=1
    mv "$FIX_REQUEST" "$FIX_REQUEST.original"
    ln -s "$FD_EXTERNAL" "$FIX_REQUEST"
  fi
  : > "$FD_MARKER.release"
  wait "$FD_SAFE_PID"
  check "fd-safe authority read reaches the swap-at-open barrier" test "$FD_SAFE_READY" = 1
  check "fd-safe authority read rejects symlink swap without transition mutation" \
    sh -c 'test "$(cat "$1")" -ne 0 && test ! -e "$2/control/continuations/requests/$3.attempt-1.json"' \
      sh "$FIX_REPO/fd-safe.rc" "$FIX_HUB" "$FIX_ID"

  make_request_fixture exact-retry retry-coordinator
  RETRY_REQUEST_INODE="$(stat -f '%i' "$FIX_REQUEST")"
  RETRY_CARRYOVER="$(jq -r '.binding.carryover.path // .carryover_path' "$FIX_REQUEST")"
  RETRY_CARRYOVER_INODE="$(stat -f '%i' "$RETRY_CARRYOVER")"
  "$ADAPTER" --manual --hub "$FIX_HUB" --session-id retry-coordinator > "$FIX_REPO/manual-retry.json"
  check "exact publish retry reuses the request ID" \
    test "$(jq -r .request_id "$FIX_REPO/manual-retry.json")" = "$FIX_ID"
  check "exact publish retry preserves request and carryover inodes" \
    sh -c 'test "$1" = "$(stat -f %i "$3")" && test "$2" = "$(stat -f %i "$4")"' \
      sh "$RETRY_REQUEST_INODE" "$RETRY_CARRYOVER_INODE" "$FIX_REQUEST" "$RETRY_CARRYOVER"
  check "published request has a regular no-clobber binding receipt" \
    sh -c 'test -f "$1" && test ! -L "$1"' sh "$FIX_HUB/control/continuations/requests/$FIX_ID.binding.json"
  check "published request and binding receipt are private mode 0600" \
    sh -c 'test "$(stat -f %Lp "$1")" = 600 && test "$(stat -f %Lp "$2")" = 600' \
      sh "$FIX_REQUEST" "$FIX_HUB/control/continuations/requests/$FIX_ID.binding.json"
  check "continuation store directories are private mode 0700" \
    sh -c 'test "$(stat -f %Lp "$1")" = 700 && test "$(stat -f %Lp "$2")" = 700 && test "$(stat -f %Lp "$3")" = 700' \
      sh "$FIX_HUB/control/continuations" "$FIX_HUB/control/continuations/requests" \
      "$FIX_HUB/control/continuations/carryovers"
  check "request-scoped and latest carryover files are private mode 0600" \
    sh -c 'test "$(stat -f %Lp "$1")" = 600 && test "$(stat -f %Lp "$2")" = 600' \
      sh "$RETRY_CARRYOVER" "$FIX_HUB/CARRYOVER.md"

  UNSAFE_COORDINATOR="$TMP/unsafe-coordinator-mode"
  mkdir -p "$UNSAFE_COORDINATOR"
  make_hub "$UNSAFE_COORDINATOR"
  authorize_coordinator "$UNSAFE_COORDINATOR/.orchestrator" unsafe-mode-coordinator
  chmod 0644 "$UNSAFE_COORDINATOR/.orchestrator/control/coordinators/"*.session-id
  check "world-readable coordinator authority is rejected before store mutation" \
    sh -c '! "$1" --manual --hub "$2" --session-id unsafe-mode-coordinator >/dev/null 2>&1 && test ! -e "$2/control/continuations"' \
      sh "$ADAPTER" "$UNSAFE_COORDINATOR/.orchestrator"

  make_request_fixture stale-protocol-lock stale-lock-coordinator
  printf '99999999\t%s\t%s\t%s\n' "$(hostname)" \
    '0000000000000000000000000000000000000000000000000000000000000000' "$FIX_ID" \
    > "$FIX_HUB/control/continuations/requests/$FIX_ID.protocol.lock"
  chmod 0600 "$FIX_HUB/control/continuations/requests/$FIX_ID.protocol.lock"
  check "dead-owner protocol lock is recovered before exact retry" \
    "$ADAPTER" --record-attempt --hub "$FIX_HUB" --request-id "$FIX_ID" \
      --thread-id recovered-thread --coordinator-session-id stale-lock-coordinator
  check "recovered protocol transition leaves no stale lock" \
    test ! -e "$FIX_HUB/control/continuations/requests/$FIX_ID.protocol.lock"

  make_request_fixture stale-lock-guard-swap guard-swap-coordinator
  GUARD_LOCK="$FIX_HUB/control/continuations/requests/$FIX_ID.protocol.lock"
  printf '99999999\t%s\t%s\t%s\n' "$(hostname)" \
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$FIX_ID" \
    > "$GUARD_LOCK"
  chmod 0600 "$GUARD_LOCK"
  sleep 30 &
  LIVE_LOCK_PID=$!
  LIVE_LOCK_CANDIDATE="$FIX_REPO/live-lock"
  printf '%s\t%s\t%s\t%s\n' "$LIVE_LOCK_PID" "$(hostname)" \
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$FIX_ID" \
    > "$LIVE_LOCK_CANDIDATE"
  chmod 0600 "$LIVE_LOCK_CANDIDATE"
  LIVE_LOCK_INODE="$(stat -f '%i' "$LIVE_LOCK_CANDIDATE")"
  LIVE_LOCK_SHA="$(shasum -a 256 "$LIVE_LOCK_CANDIDATE" | awk '{print $1}')"
  GUARD_MARKER="$FIX_REPO/lock-before-guard"
  (
    set +e
    ORC_CONTINUATION_TEST_LOCK_GUARD_MARKER="$GUARD_MARKER" \
      "$ADAPTER" --record-attempt --hub "$FIX_HUB" --request-id "$FIX_ID" \
      --thread-id guard-swap-thread --coordinator-session-id guard-swap-coordinator \
      > "$FIX_REPO/guard-swap.out" 2> "$FIX_REPO/guard-swap.err"
    printf '%s\n' "$?" > "$FIX_REPO/guard-swap.rc"
  ) &
  GUARD_SWAP_PID=$!
  GUARD_SWAP_READY=0
  if wait_for_marker "$GUARD_MARKER"; then
    GUARD_SWAP_READY=1
    mv -f "$LIVE_LOCK_CANDIDATE" "$GUARD_LOCK"
  fi
  : > "$GUARD_MARKER.release"
  wait "$GUARD_SWAP_PID"
  check "stale lock recovery reaches the guard-publication swap barrier" \
    test "$GUARD_SWAP_READY" = 1
  check "guard swap preserves live B and publishes no transition" \
    sh -c 'test "$(cat "$1")" -ne 0 && kill -0 "$2" && test -f "$3" && test "$(stat -f %i "$3")" = "$4" && actual=$(shasum -a 256 "$3") && test "${actual%% *}" = "$5" && test ! -e "$6"' \
      sh "$FIX_REPO/guard-swap.rc" "$LIVE_LOCK_PID" "$GUARD_LOCK" \
      "$LIVE_LOCK_INODE" "$LIVE_LOCK_SHA" \
      "$FIX_HUB/control/continuations/requests/$FIX_ID.attempt-1.json"
  kill "$LIVE_LOCK_PID" 2>/dev/null || true
  wait "$LIVE_LOCK_PID" 2>/dev/null || true
  check "normal retry succeeds only after live replacement owner exits" \
    "$ADAPTER" --record-attempt --hub "$FIX_HUB" --request-id "$FIX_ID" \
      --thread-id guard-swap-thread --coordinator-session-id guard-swap-coordinator
  check "post-owner retry publishes one attempt and removes only stale lock" \
    sh -c 'test -f "$1" && test ! -e "$2"' sh \
      "$FIX_HUB/control/continuations/requests/$FIX_ID.attempt-1.json" "$GUARD_LOCK"

  make_request_fixture symlink-protocol-lock symlink-lock-coordinator
  printf 'outside-lock\n' > "$FIX_REPO/outside-lock"
  ln -s -- "$FIX_REPO/outside-lock" "$FIX_HUB/control/continuations/requests/$FIX_ID.protocol.lock"
  check "symlink protocol lock fails closed without an attempt receipt" \
    sh -c '! "$1" --record-attempt --hub "$2" --request-id "$3" --thread-id rejected-thread --coordinator-session-id symlink-lock-coordinator >/dev/null 2>&1 && test ! -e "$2/control/continuations/requests/$3.attempt-1.json"' \
      sh "$ADAPTER" "$FIX_HUB" "$FIX_ID"

  DUAL_REPO="$TMP/dual-coordinators"
  mkdir -p "$DUAL_REPO"
  make_hub "$DUAL_REPO"
  DUAL_HUB="$DUAL_REPO/.orchestrator"
  authorize_coordinator "$DUAL_HUB" coordinator-a
  authorize_coordinator "$DUAL_HUB" coordinator-b
  "$ADAPTER" --manual --hub "$DUAL_HUB" --session-id coordinator-a > "$DUAL_REPO/a.json"
  DUAL_A="$(jq -r .request_id "$DUAL_REPO/a.json")"
  DUAL_A_FILE="$DUAL_HUB/control/continuations/requests/$DUAL_A.json"
  DUAL_A_CARRYOVER="$(jq -r '.binding.carryover.path // .carryover_path' "$DUAL_A_FILE")"
  "$ADAPTER" --manual --hub "$DUAL_HUB" --session-id coordinator-b > "$DUAL_REPO/b.json"
  DUAL_B="$(jq -r .request_id "$DUAL_REPO/b.json")"
  DUAL_B_FILE="$DUAL_HUB/control/continuations/requests/$DUAL_B.json"
  DUAL_B_CARRYOVER="$(jq -r '.binding.carryover.path // .carryover_path' "$DUAL_B_FILE")"
  check "independent coordinators receive distinct request-scoped carryovers" \
    sh -c 'test "$1" != "$2" && test -f "$1" && test -f "$2"' sh "$DUAL_A_CARRYOVER" "$DUAL_B_CARRYOVER"
  "$ADAPTER" --record-attempt --hub "$DUAL_HUB" --request-id "$DUAL_A" --thread-id dual-a-thread --coordinator-session-id coordinator-a
  DUAL_A_DIGEST="$(request_digest "$DUAL_A_FILE")"
  write_health "$DUAL_REPO/a-health.json" "$DUAL_A" dual-a-thread "$DUAL_A_DIGEST"
  check "second coordinator publication cannot stale the first acceptance authority" \
    "$ADAPTER" --accept --hub "$DUAL_HUB" --request-id "$DUAL_A" --thread-id dual-a-thread --coordinator-session-id coordinator-a --health-evidence "$DUAL_REPO/a-health.json"

  CONCURRENT="$TMP/concurrent"
  mkdir -p "$CONCURRENT"
  make_hub "$CONCURRENT"
  authorize_coordinator "$CONCURRENT/.orchestrator" coordinator-concurrent
  for I in 1 2 3 4 5 6; do
    precompact_input "$CONCURRENT" coordinator-concurrent | "$ADAPTER" > "$TMP/concurrent-$I.out" &
  done
  wait
  check "concurrent hook invocations publish one no-clobber request" \
    test "$(request_count "$CONCURRENT/.orchestrator")" = 1

  MANUAL="$TMP/manual"
  mkdir -p "$MANUAL"
  make_hub "$MANUAL"
  authorize_coordinator "$MANUAL/.orchestrator" manual-coordinator
  "$ADAPTER" --manual --hub "$MANUAL/.orchestrator" --session-id manual-coordinator > "$TMP/manual.out"
  check "manual coordinator fallback publishes the same protocol" \
    test "$(request_count "$MANUAL/.orchestrator")" = 1
  check "manual fallback output does not invent a percentage" \
    sh -c '! grep -Eq "[0-9]+%" "$1"' sh "$TMP/manual.out"

  "$ADAPTER" --record-attempt --hub "$HUB" --request-id "$REQ_ID" --thread-id provisional-1 --coordinator-session-id coordinator-thread-1
  check "first provisional continuation attempt is durable" \
    test -f "$HUB/control/continuations/requests/$REQ_ID.attempt-1.json"
  check "a second thread is refused while attempt one is unresolved" \
    sh -c '! "$1" --record-attempt --hub "$2" --request-id "$3" --thread-id provisional-2 --coordinator-session-id coordinator-thread-1 >/dev/null 2>&1' sh "$ADAPTER" "$HUB" "$REQ_ID"
  "$ADAPTER" --reject-attempt --hub "$HUB" --request-id "$REQ_ID" --thread-id provisional-1 --coordinator-session-id coordinator-thread-1 --reason unreadable
  FAILED_ONE="$HUB/control/continuations/requests/$REQ_ID.attempt-1.failed.json"
  FAILED_ONE_SHA="$(shasum -a 256 "$FAILED_ONE" | awk '{print $1}')"
  check "reject replay with the exact durable reason is idempotent" \
    "$ADAPTER" --reject-attempt --hub "$HUB" --request-id "$REQ_ID" \
      --thread-id provisional-1 --coordinator-session-id coordinator-thread-1 --reason unreadable
  check "reject replay with a conflicting reason fails closed without mutation" \
    sh -c '! "$1" --reject-attempt --hub "$2" --request-id "$3" --thread-id provisional-1 --coordinator-session-id coordinator-thread-1 --reason conflicting >/dev/null 2>&1 && actual=$(shasum -a 256 "$5") && test "$4" = "${actual%% *}"' \
      sh "$ADAPTER" "$HUB" "$REQ_ID" "$FAILED_ONE_SHA" "$FAILED_ONE"
  "$ADAPTER" --record-attempt --hub "$HUB" --request-id "$REQ_ID" --thread-id provisional-2 --coordinator-session-id coordinator-thread-1
  check "one replacement is allowed only after durable rejection" \
    test -f "$HUB/control/continuations/requests/$REQ_ID.attempt-2.json"
  "$ADAPTER" --reject-attempt --hub "$HUB" --request-id "$REQ_ID" --thread-id provisional-2 --coordinator-session-id coordinator-thread-1 --reason unreadable
  check "replacement-exhausted third attempt replay is a terminal rc0 no-op" \
    sh -c '"$1" --record-attempt --hub "$2" --request-id "$3" --thread-id provisional-3 --coordinator-session-id coordinator-thread-1 >/dev/null 2>&1 && test ! -e "$2/control/continuations/requests/$3.attempt-3.json"' \
      sh "$ADAPTER" "$HUB" "$REQ_ID"

  ACCEPT_REPO="$TMP/accept"
  mkdir -p "$ACCEPT_REPO"
  make_hub "$ACCEPT_REPO"
  ACCEPT_HUB="$ACCEPT_REPO/.orchestrator"
  authorize_coordinator "$ACCEPT_HUB" accepting-coordinator
  "$ADAPTER" --manual --hub "$ACCEPT_HUB" --session-id accepting-coordinator > "$TMP/accept-request.out"
  ACCEPT_FILE="$(request_file "$ACCEPT_HUB")"
  ACCEPT_ID="$(jq -r .request_id "$ACCEPT_FILE")"
  STATE_SHA="$(request_digest "$ACCEPT_FILE")"
  "$ADAPTER" --record-attempt --hub "$ACCEPT_HUB" --request-id "$ACCEPT_ID" --thread-id verified-thread --coordinator-session-id accepting-coordinator
  write_health "$TMP/bad-health.json" "$ACCEPT_ID" verified-thread "$STATE_SHA" failed
  check "failed replacement health evidence cannot be accepted" \
    sh -c '! "$1" --accept --hub "$2" --request-id "$3" --thread-id verified-thread --coordinator-session-id accepting-coordinator --health-evidence "$4" >/dev/null 2>&1' sh "$ADAPTER" "$ACCEPT_HUB" "$ACCEPT_ID" "$TMP/bad-health.json"

  write_health "$TMP/good-health.json" "$ACCEPT_ID" verified-thread "$STATE_SHA"
  "$ADAPTER" --accept --hub "$ACCEPT_HUB" --request-id "$ACCEPT_ID" --thread-id verified-thread --coordinator-session-id accepting-coordinator --health-evidence "$TMP/good-health.json"
  check "healthy exact replacement publishes an accepted receipt" \
    json_expr "$ACCEPT_HUB/control/continuations/requests/$ACCEPT_ID.accepted.json" '.thread_id == "verified-thread" and .health_verified == true'
  check "health copy and accepted receipt are private mode 0600" \
    sh -c 'copy=$(jq -r .health_evidence_path "$1") && test "$(stat -f %Lp "$1")" = 600 && test "$(stat -f %Lp "$copy")" = 600' \
      sh "$ACCEPT_HUB/control/continuations/requests/$ACCEPT_ID.accepted.json"
  ACCEPT_TERMINAL_BEFORE="$(store_fingerprint "$ACCEPT_HUB")"
  check "accepted record-attempt replay is a terminal rc0 no-op" \
    "$ADAPTER" --record-attempt --hub "$ACCEPT_HUB" --request-id "$ACCEPT_ID" \
      --thread-id duplicate-thread --coordinator-session-id accepting-coordinator
  check "accepted reject replay is a terminal rc0 no-op" \
    "$ADAPTER" --reject-attempt --hub "$ACCEPT_HUB" --request-id "$ACCEPT_ID" \
      --thread-id verified-thread --coordinator-session-id accepting-coordinator --reason replay
  check "exact accepted continuation retry is idempotent" \
    "$ADAPTER" --accept --hub "$ACCEPT_HUB" --request-id "$ACCEPT_ID" --thread-id verified-thread --coordinator-session-id accepting-coordinator --health-evidence "$TMP/good-health.json"
  session_start_input "$ACCEPT_REPO" accepting-coordinator | "$ADAPTER" > "$TMP/accepted-session-start.out"
  check "accepted terminal request suppresses SessionStart replay" test ! -s "$TMP/accepted-session-start.out"
  "$ADAPTER" --manual --hub "$ACCEPT_HUB" --session-id accepting-coordinator > "$TMP/accepted-manual.out"
  check "accepted terminal request suppresses manual replay" test ! -s "$TMP/accepted-manual.out"
  precompact_input "$ACCEPT_REPO" accepting-coordinator | "$ADAPTER" > "$TMP/accepted-precompact.out"
  check "accepted terminal request suppresses PreCompact replay" test ! -s "$TMP/accepted-precompact.out"
  check "accepted terminal replays create no artifacts" \
    test "$(store_fingerprint "$ACCEPT_HUB")" = "$ACCEPT_TERMINAL_BEFORE"

  check "promotion rejects a thread that is not the exact accepted continuation" \
    sh -c '! "$1" --promote-coordinator --hub "$2" --request-id "$3" --coordinator-session-id accepting-coordinator --thread-id wrong-thread >/dev/null 2>&1' \
      sh "$ADAPTER" "$ACCEPT_HUB" "$ACCEPT_ID"
  "$ADAPTER" --promote-coordinator --hub "$ACCEPT_HUB" --request-id "$ACCEPT_ID" \
    --coordinator-session-id accepting-coordinator --thread-id verified-thread \
    > "$TMP/promotion.json"
  check "promotion publishes explicit accepted-thread authority and receipt" \
    jq -e '.status == "promoted" and .thread_id == "verified-thread"' "$TMP/promotion.json" >/dev/null
  PROMOTION_AUTHORITY="$(jq -r .authority_path "$TMP/promotion.json")"
  PROMOTION_RECEIPT="$(jq -r .promotion_receipt "$TMP/promotion.json")"
  check "promotion authority and receipt are private mode 0600" \
    sh -c 'test -f "$1" && test -f "$2" && test "$(stat -f %Lp "$1")" = 600 && test "$(stat -f %Lp "$2")" = 600' \
      sh "$PROMOTION_AUTHORITY" "$PROMOTION_RECEIPT"
  PROMOTION_FINGERPRINT="$(store_fingerprint "$ACCEPT_HUB")"
  "$ADAPTER" --promote-coordinator --hub "$ACCEPT_HUB" --request-id "$ACCEPT_ID" \
    --coordinator-session-id accepting-coordinator --thread-id verified-thread \
    > "$TMP/promotion-retry.json"
  check "promotion crash/retry is idempotent" \
    sh -c 'test "$(jq -r .promotion_receipt "$1")" = "$(jq -r .promotion_receipt "$2")" && test "$3" = "$4"' \
      sh "$TMP/promotion.json" "$TMP/promotion-retry.json" "$PROMOTION_FINGERPRINT" \
      "$(store_fingerprint "$ACCEPT_HUB")"
  precompact_input "$ACCEPT_REPO" accepting-coordinator | "$ADAPTER" > "$TMP/retired-coordinator.out"
  check "promoted workflow suppresses the retired coordinator" test ! -s "$TMP/retired-coordinator.out"
  NEXT_REQUESTS_BEFORE="$(request_ids "$ACCEPT_HUB" | wc -l | tr -d ' ')"
  precompact_input "$ACCEPT_REPO" verified-thread | "$ADAPTER" > "$TMP/promoted-precompact.out"
  NEXT_REQUESTS_AFTER="$(request_ids "$ACCEPT_HUB" | wc -l | tr -d ' ')"
  check "accepted then promoted coordinator creates exactly one next request" \
    test "$NEXT_REQUESTS_AFTER" -eq $((NEXT_REQUESTS_BEFORE + 1))
  NEXT_ID="$(request_ids "$ACCEPT_HUB" | grep -v "^$ACCEPT_ID$" | head -n 1)"
  session_start_input "$ACCEPT_REPO" verified-thread | "$ADAPTER" > "$TMP/promoted-session.out"
  check "promoted coordinator SessionStart emits its next request" \
    jq -e --arg id "$NEXT_ID" '.hookSpecificOutput.additionalContext | contains($id)' "$TMP/promoted-session.out" >/dev/null
  precompact_input "$ACCEPT_REPO" unrelated-after-promotion | "$ADAPTER" > "$TMP/unrelated-after-promotion.out"
  check "promotion does not authorize unrelated sessions" test ! -s "$TMP/unrelated-after-promotion.out"

  for PROMOTION_PHASE in after_stage after_intent after_commit after_new_authority after_supersession after_receipt; do
    make_accepted_fixture "promotion-crash-$PROMOTION_PHASE" \
      "old-$PROMOTION_PHASE" "new-$PROMOTION_PHASE"
    set +e
    ORC_CONTINUATION_TEST_PROMOTION_FAIL_PHASE="$PROMOTION_PHASE" \
      "$ADAPTER" --promote-coordinator --hub "$PROMO_HUB" --request-id "$PROMO_ID" \
      --coordinator-session-id "$PROMO_OLD" --thread-id "$PROMO_NEW" \
      > "$PROMO_REPO/promotion-fail.out" 2> "$PROMO_REPO/promotion-fail.err"
    PROMOTION_FAIL_RC=$?
    set -e
    check "promotion injection $PROMOTION_PHASE exits before success" \
      test "$PROMOTION_FAIL_RC" -ne 0
    case "$PROMOTION_PHASE" in
      after_stage|after_intent) EXPECTED_OWNER=old ;;
      *) EXPECTED_OWNER=new ;;
    esac
    check "promotion injection $PROMOTION_PHASE preserves exactly one eligible owner" \
      sole_eligible_is "$PROMO_HUB" "$PROMO_OLD" "$PROMO_NEW" "$EXPECTED_OWNER"
    "$ADAPTER" --promote-coordinator --hub "$PROMO_HUB" --request-id "$PROMO_ID" \
      --coordinator-session-id "$PROMO_OLD" --thread-id "$PROMO_NEW" \
      > "$PROMO_REPO/promotion-retry.out"
    check "promotion retry $PROMOTION_PHASE converges to the new sole owner" \
      sole_eligible_is "$PROMO_HUB" "$PROMO_OLD" "$PROMO_NEW" new
  done

  make_accepted_fixture promotion-term old-term-coordinator new-term-coordinator
  set +e
  ORC_CONTINUATION_TEST_PROMOTION_SIGNAL_PHASE=after_stage \
    "$ADAPTER" --promote-coordinator --hub "$PROMO_HUB" --request-id "$PROMO_ID" \
    --coordinator-session-id "$PROMO_OLD" --thread-id "$PROMO_NEW" \
    > "$PROMO_REPO/promotion-term.out" 2> "$PROMO_REPO/promotion-term.err"
  PROMOTION_TERM_RC=$?
  set -e
  check "TERM after staged authority exits nonzero" test "$PROMOTION_TERM_RC" -ne 0
  check "TERM before commit leaves old coordinator as sole owner" \
    sole_eligible_is "$PROMO_HUB" "$PROMO_OLD" "$PROMO_NEW" old
  "$ADAPTER" --promote-coordinator --hub "$PROMO_HUB" --request-id "$PROMO_ID" \
    --coordinator-session-id "$PROMO_OLD" --thread-id "$PROMO_NEW" \
    > "$PROMO_REPO/promotion-term-retry.out"
  check "TERM promotion retry converges" \
    sole_eligible_is "$PROMO_HUB" "$PROMO_OLD" "$PROMO_NEW" new

  make_accepted_fixture promotion-malformed-stage old-malformed-stage new-malformed-stage
  ORC_CONTINUATION_TEST_PROMOTION_FAIL_PHASE=after_stage \
    "$ADAPTER" --promote-coordinator --hub "$PROMO_HUB" --request-id "$PROMO_ID" \
    --coordinator-session-id "$PROMO_OLD" --thread-id "$PROMO_NEW" \
    >/dev/null 2>&1 || true
  PROMO_STAGE="$PROMO_HUB/control/coordinators/promotion-staging/$PROMO_ID.session-id"
  if [[ -f "$PROMO_STAGE" ]]; then
    printf 'forged-stage\n' > "$PROMO_REPO/forged-stage"
    chmod 0600 "$PROMO_REPO/forged-stage"
    mv -f "$PROMO_REPO/forged-stage" "$PROMO_STAGE"
  fi
  check "malformed staged authority fails closed with old sole owner" \
    promotion_retry_fails_with_old_owner "$PROMO_HUB" "$PROMO_ID" "$PROMO_OLD" "$PROMO_NEW"

  make_accepted_fixture promotion-symlink-stage old-symlink-stage new-symlink-stage
  ORC_CONTINUATION_TEST_PROMOTION_FAIL_PHASE=after_stage \
    "$ADAPTER" --promote-coordinator --hub "$PROMO_HUB" --request-id "$PROMO_ID" \
    --coordinator-session-id "$PROMO_OLD" --thread-id "$PROMO_NEW" \
    >/dev/null 2>&1 || true
  PROMO_STAGE="$PROMO_HUB/control/coordinators/promotion-staging/$PROMO_ID.session-id"
  if [[ -f "$PROMO_STAGE" ]]; then
    mv "$PROMO_STAGE" "$PROMO_STAGE.target"
    ln -s "$PROMO_STAGE.target" "$PROMO_STAGE"
  fi
  check "symlink staged authority fails closed with old sole owner" \
    promotion_retry_fails_with_old_owner "$PROMO_HUB" "$PROMO_ID" "$PROMO_OLD" "$PROMO_NEW"

  make_accepted_fixture promotion-malformed-commit old-malformed-commit new-malformed-commit
  ORC_CONTINUATION_TEST_PROMOTION_FAIL_PHASE=after_commit \
    "$ADAPTER" --promote-coordinator --hub "$PROMO_HUB" --request-id "$PROMO_ID" \
    --coordinator-session-id "$PROMO_OLD" --thread-id "$PROMO_NEW" \
    >/dev/null 2>&1 || true
  PROMO_COMMIT="$PROMO_HUB/control/coordinators/$PROMO_ID.promotion-commit.json"
  if [[ -f "$PROMO_COMMIT" ]]; then
    printf '{malformed\n' > "$PROMO_REPO/malformed-commit"
    chmod 0600 "$PROMO_REPO/malformed-commit"
    mv -f "$PROMO_REPO/malformed-commit" "$PROMO_COMMIT"
  fi
  check "malformed commit marker makes both classifications fail closed" \
    classifications_fail_closed "$PROMO_HUB" "$PROMO_OLD" "$PROMO_NEW"

  make_accepted_fixture promotion-symlink-commit old-symlink-commit new-symlink-commit
  ORC_CONTINUATION_TEST_PROMOTION_FAIL_PHASE=after_commit \
    "$ADAPTER" --promote-coordinator --hub "$PROMO_HUB" --request-id "$PROMO_ID" \
    --coordinator-session-id "$PROMO_OLD" --thread-id "$PROMO_NEW" \
    >/dev/null 2>&1 || true
  PROMO_COMMIT="$PROMO_HUB/control/coordinators/$PROMO_ID.promotion-commit.json"
  if [[ -f "$PROMO_COMMIT" ]]; then
    mv "$PROMO_COMMIT" "$PROMO_COMMIT.target"
    ln -s "$PROMO_COMMIT.target" "$PROMO_COMMIT"
  fi
  check "symlink commit marker makes both classifications fail closed" \
    classifications_fail_closed "$PROMO_HUB" "$PROMO_OLD" "$PROMO_NEW"

  make_accepted_fixture promotion-stale old-stale-promotion new-stale-promotion
  ORC_CONTINUATION_TEST_PROMOTION_FAIL_PHASE=after_stage \
    "$ADAPTER" --promote-coordinator --hub "$PROMO_HUB" --request-id "$PROMO_ID" \
    --coordinator-session-id "$PROMO_OLD" --thread-id "$PROMO_NEW" \
    >/dev/null 2>&1 || true
  printf '999\n' > "$PROMO_HUB/control/mission-a/tasks/task-a/generation"
  check "stale staged promotion cannot commit and leaves old sole owner" \
    promotion_retry_fails_with_old_owner "$PROMO_HUB" "$PROMO_ID" "$PROMO_OLD" "$PROMO_NEW"

  PROMOTION_ACCEPTED="$ACCEPT_HUB/control/continuations/requests/$ACCEPT_ID.accepted.json"
  jq -cS '.health_verified = false' "$PROMOTION_ACCEPTED" > "$TMP/malformed-accepted.json"
  chmod 0600 "$TMP/malformed-accepted.json"
  mv -f "$TMP/malformed-accepted.json" "$PROMOTION_ACCEPTED"
  check "malformed accepted receipt is rejected by promotion retry" \
    sh -c '! "$1" --promote-coordinator --hub "$2" --request-id "$3" --coordinator-session-id accepting-coordinator --thread-id verified-thread >/dev/null 2>&1' \
      sh "$ADAPTER" "$ACCEPT_HUB" "$ACCEPT_ID"

  FAILED_REPO="$TMP/failed-terminal"
  mkdir -p "$FAILED_REPO"
  make_hub "$FAILED_REPO"
  FAILED_HUB="$FAILED_REPO/.orchestrator"
  authorize_coordinator "$FAILED_HUB" failed-coordinator
  "$ADAPTER" --manual --hub "$FAILED_HUB" --session-id failed-coordinator > "$FAILED_REPO/request.json"
  FAILED_ID="$(jq -r .request_id "$FAILED_REPO/request.json")"
  "$ADAPTER" --record-attempt --hub "$FAILED_HUB" --request-id "$FAILED_ID" \
    --thread-id failed-thread-1 --coordinator-session-id failed-coordinator
  "$ADAPTER" --reject-attempt --hub "$FAILED_HUB" --request-id "$FAILED_ID" \
    --thread-id failed-thread-1 --coordinator-session-id failed-coordinator --reason first-failure
  "$ADAPTER" --record-attempt --hub "$FAILED_HUB" --request-id "$FAILED_ID" \
    --thread-id failed-thread-2 --coordinator-session-id failed-coordinator
  "$ADAPTER" --reject-attempt --hub "$FAILED_HUB" --request-id "$FAILED_ID" \
    --thread-id failed-thread-2 --coordinator-session-id failed-coordinator --reason second-failure
  FAILED_TERMINAL_BEFORE="$(store_fingerprint "$FAILED_HUB")"
  check "failed record-attempt replay is a terminal rc0 no-op" \
    "$ADAPTER" --record-attempt --hub "$FAILED_HUB" --request-id "$FAILED_ID" \
      --thread-id failed-thread-3 --coordinator-session-id failed-coordinator
  check "failed reject replay with exact reason is a terminal rc0 no-op" \
    "$ADAPTER" --reject-attempt --hub "$FAILED_HUB" --request-id "$FAILED_ID" \
      --thread-id failed-thread-2 --coordinator-session-id failed-coordinator --reason second-failure
  check "failed reject replay with conflicting reason fails closed" \
    sh -c '! "$1" --reject-attempt --hub "$2" --request-id "$3" --thread-id failed-thread-2 --coordinator-session-id failed-coordinator --reason conflicting >/dev/null 2>&1' \
      sh "$ADAPTER" "$FAILED_HUB" "$FAILED_ID"
  check "failed accept replay is a terminal rc0 no-op without health input" \
    "$ADAPTER" --accept --hub "$FAILED_HUB" --request-id "$FAILED_ID" \
      --thread-id failed-thread-2 --coordinator-session-id failed-coordinator \
      --health-evidence "$FAILED_REPO/missing-health.json"
  "$ADAPTER" --manual --hub "$FAILED_HUB" --session-id failed-coordinator > "$FAILED_REPO/manual-replay.out"
  check "failed terminal request suppresses manual replay" test ! -s "$FAILED_REPO/manual-replay.out"
  session_start_input "$FAILED_REPO" failed-coordinator | "$ADAPTER" > "$FAILED_REPO/session-replay.out"
  check "failed terminal request suppresses SessionStart replay" test ! -s "$FAILED_REPO/session-replay.out"
  precompact_input "$FAILED_REPO" failed-coordinator | "$ADAPTER" > "$FAILED_REPO/precompact-replay.out"
  check "failed terminal request suppresses PreCompact replay" test ! -s "$FAILED_REPO/precompact-replay.out"
  check "failed terminal replays create no artifacts" \
    test "$(store_fingerprint "$FAILED_HUB")" = "$FAILED_TERMINAL_BEFORE"

  SWAP_REPO="$TMP/health-swap"
  mkdir -p "$SWAP_REPO"
  make_hub "$SWAP_REPO"
  SWAP_HUB="$SWAP_REPO/.orchestrator"
  authorize_coordinator "$SWAP_HUB" swap-coordinator
  "$ADAPTER" --manual --hub "$SWAP_HUB" --session-id swap-coordinator > "$SWAP_REPO/request.json"
  SWAP_ID="$(jq -r .request_id "$SWAP_REPO/request.json")"
  SWAP_FILE="$SWAP_HUB/control/continuations/requests/$SWAP_ID.json"
  SWAP_DIGEST="$(request_digest "$SWAP_FILE")"
  "$ADAPTER" --record-attempt --hub "$SWAP_HUB" --request-id "$SWAP_ID" --thread-id swap-thread --coordinator-session-id swap-coordinator
  write_health "$SWAP_REPO/health.json" "$SWAP_ID" swap-thread "$SWAP_DIGEST"
  SWAP_MARKER="$SWAP_REPO/health-read"
  (
    set +e
    ORC_CONTINUATION_TEST_HEALTH_READ_MARKER="$SWAP_MARKER" \
      "$ADAPTER" --accept --hub "$SWAP_HUB" --request-id "$SWAP_ID" --thread-id swap-thread \
      --coordinator-session-id swap-coordinator --health-evidence "$SWAP_REPO/health.json" \
      2> "$SWAP_REPO/accept.err"
    printf '%s\n' "$?" > "$SWAP_REPO/accept.rc"
  ) &
  SWAP_PID=$!
  SWAP_READY=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [[ -f "$SWAP_MARKER" ]]; then SWAP_READY=1; break; fi
    sleep 0.05
  done
  write_health "$SWAP_REPO/health-bad.json" "$SWAP_ID" swap-thread "$SWAP_DIGEST" failed
  mv -f -- "$SWAP_REPO/health-bad.json" "$SWAP_REPO/health.json"
  : > "$SWAP_MARKER.release"
  wait "$SWAP_PID"
  check "health evidence swap test reached the post-read barrier" test "$SWAP_READY" = 1
  SWAP_ACCEPTED="$SWAP_HUB/control/continuations/requests/$SWAP_ID.accepted.json"
  check "accept binds the immutable validated health bytes despite source replacement" \
    sh -c 'test "$(cat "$1")" = 0 && copy=$(jq -r .health_evidence_path "$2") && test -f "$copy" && test "$(jq -r .status "$copy")" = inProgress && test "$(jq -r .status "$3")" = failed && expected=$(jq -r .health_evidence_sha256 "$2") && actual=$(shasum -a 256 "$copy") && test "$expected" = "${actual%% *}"' \
      sh "$SWAP_REPO/accept.rc" "$SWAP_ACCEPTED" "$SWAP_REPO/health.json"
  printf '4\n' > "$SWAP_HUB/control/mission-a/tasks/task-a/generation"
  check "stale hub generation is rejected by coordinator promotion" \
    sh -c '! "$1" --promote-coordinator --hub "$2" --request-id "$3" --coordinator-session-id swap-coordinator --thread-id swap-thread >/dev/null 2>&1' \
      sh "$ADAPTER" "$SWAP_HUB" "$SWAP_ID"

  RACE_REPO="$TMP/terminal-race"
  mkdir -p "$RACE_REPO"
  make_hub "$RACE_REPO"
  RACE_HUB="$RACE_REPO/.orchestrator"
  authorize_coordinator "$RACE_HUB" race-coordinator
  "$ADAPTER" --manual --hub "$RACE_HUB" --session-id race-coordinator > "$RACE_REPO/request.json"
  RACE_ID="$(jq -r .request_id "$RACE_REPO/request.json")"
  RACE_FILE="$RACE_HUB/control/continuations/requests/$RACE_ID.json"
  RACE_DIGEST="$(request_digest "$RACE_FILE")"
  "$ADAPTER" --record-attempt --hub "$RACE_HUB" --request-id "$RACE_ID" --thread-id race-thread --coordinator-session-id race-coordinator
  write_health "$RACE_REPO/health.json" "$RACE_ID" race-thread "$RACE_DIGEST"
  (
    set +e
    "$ADAPTER" --accept --hub "$RACE_HUB" --request-id "$RACE_ID" --thread-id race-thread --coordinator-session-id race-coordinator --health-evidence "$RACE_REPO/health.json" \
      2> "$RACE_REPO/accept.err"
    printf '%s\n' "$?" > "$RACE_REPO/accept.rc"
  ) &
  RACE_ACCEPT_PID=$!
  (
    set +e
    "$ADAPTER" --reject-attempt --hub "$RACE_HUB" --request-id "$RACE_ID" --thread-id race-thread --coordinator-session-id race-coordinator --reason race-rejected \
      2> "$RACE_REPO/reject.err"
    printf '%s\n' "$?" > "$RACE_REPO/reject.rc"
  ) &
  RACE_REJECT_PID=$!
  wait "$RACE_ACCEPT_PID" "$RACE_REJECT_PID"
  check "accept and reject terminal transition has one exact winner" \
    sh -c 'accepted=0; failed=0; test -f "$1" && accepted=1; test -f "$2" && failed=1; test $((accepted + failed)) -eq 1' \
      sh "$RACE_HUB/control/continuations/requests/$RACE_ID.accepted.json" \
      "$RACE_HUB/control/continuations/requests/$RACE_ID.attempt-1.failed.json"
fi

echo "  continuation-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
