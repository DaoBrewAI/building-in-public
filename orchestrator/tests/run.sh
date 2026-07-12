#!/usr/bin/env bash
# Runs every tests/test-*.sh; a test passes iff it exits 0.
set -uo pipefail
cd "$(dirname "$0")"
FAIL=0
for T in test-*.sh; do
  if bash "$T"; then
    echo "PASS $T"
  else
    echo "FAIL $T"
    FAIL=1
  fi
done
exit "$FAIL"
