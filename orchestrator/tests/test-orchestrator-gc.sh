#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GC="$ROOT/scripts/orchestrator-gc.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
HUB="$TMP/.orchestrator"
mkdir -p "$HUB/missions" "$HUB/control" "$HUB/archive"

fail() { echo "  $1" >&2; exit 1; }

mkdir -p "$HUB/control/selected/tasks" "$HUB/missions/selected"
printf 'running\n' > "$HUB/missions/selected/state"
mkdir -p "$HUB/control/unrelated"
ln -s "$TMP/missing" "$HUB/control/unrelated/tasks"

REPORT="$($GC --hub "$HUB" 2>&1)" \
  || fail "report-only discovery must not fail on unrelated unsafe authority"
grep -Fq 'unrelated coordinator task registry is unsafe' <<<"$REPORT" \
  || fail "report-only discovery did not surface the unrelated warning"
grep -Fq 'report-only discovery completed with preserved cleanup warnings' <<<"$REPORT" \
  || fail "report-only discovery did not explain its nonblocking result"

SCOPED="$($GC --hub "$HUB" --mission selected 2>&1)" \
  || fail "mission-scoped report-only discovery failed"
if grep -Fq unrelated <<<"$SCOPED"; then
  fail "mission filter inspected unrelated authority"
fi

INVALID_RC=0
$GC --hub "$HUB" --mission '../selected' --clean >/dev/null 2>&1 || INVALID_RC=$?
[[ "$INVALID_RC" -ne 0 ]] || fail "unsafe mission filter was accepted"

[[ -d "$HUB/control/selected" && -L "$HUB/control/unrelated/tasks" ]] \
  || fail "report-only discovery mutated hub authority"

echo "  orchestrator-gc: report-only warnings are nonblocking and mission filters are exact"
