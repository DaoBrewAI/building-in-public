#!/usr/bin/env bash
# Coordinator-owned risk-tiered gate before merge and before archive.
set -uo pipefail

MISSION_DIR=""
STAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mission-dir) MISSION_DIR="${2:-}"; shift 2 ;;
    --stage) STAGE="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$MISSION_DIR" || ! -d "$MISSION_DIR" || ( "$STAGE" != premerge && "$STAGE" != final ) ]]; then
  echo "usage: alignment-gate.sh --mission-dir <dir> --stage premerge|final" >&2
  exit 2
fi

ERRORS=()
add() { ERRORS+=("$1"); }

standalone_html() {
  local FILE="$1" LABEL="$2"
  if [[ ! -s "$FILE" ]]; then
    add "$LABEL is missing or empty"
    return
  fi
  if ! grep -Eiq '<!doctype[[:space:]]+html' "$FILE" || ! grep -Eiq '<html([[:space:]>])' "$FILE"; then
    add "$LABEL must be durable standalone HTML, not a fragment"
  fi
}

MISSION="$MISSION_DIR/MISSION.md"
RISK=""
if [[ ! -f "$MISSION" ]]; then
  add "MISSION.md is missing"
elif grep -Eiq '^- \*\*Risk class:\*\*[[:space:]]*material([[:space:]]|$)' "$MISSION"; then
  RISK=material
elif grep -Eiq '^- \*\*Risk class:\*\*[[:space:]]*routine([[:space:]]|$)' "$MISSION"; then
  RISK=routine
else
  add "MISSION.md must classify risk as routine or material"
fi

[[ -s "$MISSION_DIR/commits.txt" ]] || add "commits.txt is missing or empty"
standalone_html "$MISSION_DIR/status-truth-premerge.html" "status-truth-premerge.html"

if [[ "$RISK" == material ]]; then
  standalone_html "$MISSION_DIR/change-walkthrough.html" "change-walkthrough.html"
  ACCEPTANCE="$MISSION_DIR/coordinator-acceptance.md"
  if [[ ! -s "$ACCEPTANCE" ]]; then
    add "coordinator-acceptance.md is missing or empty"
    add "Walkthrough quiz pass is not recorded"
    add "Merge approval is not recorded"
  else
    grep -Eiq '^Walkthrough quiz:[[:space:]]*passed' "$ACCEPTANCE" || add "Walkthrough quiz pass is not recorded"
    grep -Eiq '^Merge approval:[[:space:]]*approved' "$ACCEPTANCE" || add "Merge approval is not recorded"
  fi
fi

if [[ "$STAGE" == final ]]; then
  [[ -s "$MISSION_DIR/coordinator-acceptance.md" ]] || add "coordinator-acceptance.md is missing or empty"
  standalone_html "$MISSION_DIR/status-truth.html" "status-truth.html"
  NEXT="$MISSION_DIR/NEXT-STEPS.md"
  if [[ ! -s "$NEXT" ]]; then
    add "NEXT-STEPS.md is missing or empty"
  elif grep -qF '{{' "$NEXT"; then
    add "NEXT-STEPS.md still contains template placeholders"
  elif ! grep -Eiq '^[[:space:]]*(none|[-*][[:space:]]+none)[[:space:]]*$' "$NEXT" &&
       ! awk -F'|' '
         BEGIN { seen = 0; bad = 0 }
         /^[[:space:]]*\|/ {
           status = $2
           gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
           if (tolower(status) == "status" || status ~ /^-+$/) next
           if (status == "ready" || status == "decision-needed" || status == "deferred") seen = 1
           else bad = 1
         }
         END { exit (!seen || bad) }
       ' "$NEXT"; then
    add "NEXT-STEPS.md must classify every follow-up as ready, decision-needed, deferred, or None"
  fi
fi

if [[ "${#ERRORS[@]}" -gt 0 ]]; then
  printf '[alignment gate] %s blocked:\n' "$STAGE" >&2
  printf ' - %s\n' "${ERRORS[@]}" >&2
  exit 1
fi

echo "[alignment gate] $STAGE passed ($RISK)"
