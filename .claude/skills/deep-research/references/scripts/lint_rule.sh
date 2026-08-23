#!/bin/bash
# lint_rule.sh — Multi-rule HARD-RULE lint dispatcher for the deep-research skill.
#
# Today supports rule_name = "colorblind" (accessibility rule: PASS=blue,
# NEVER green). Future rules slot in as additional case branches.
#
# Usage: lint_rule.sh <rule_name> <skill_root>
#   rule_name:   currently "colorblind" (only supported value)
#   skill_root:  directory to scan (e.g. path/to/deep-research)
# Exit:
#   0  PASS, no violations.
#   1  FAIL, one or more violations found.
#   2  Usage error.
#   3  Internal error (skill_root not a directory).
#
# Output: "VIOLATION: <relpath>:<lineno>:<text>" per match, then PASS/FAIL summary.

set -uo pipefail

RULE="${1:-}"
SKILL_ROOT_ARG="${2:-}"
if [[ -z "$RULE" || -z "$SKILL_ROOT_ARG" ]]; then
  echo "usage: $0 <rule_name> <skill_root>" >&2
  exit 2
fi
if [[ ! -d "$SKILL_ROOT_ARG" ]]; then
  echo "ERROR: not a directory: $SKILL_ROOT_ARG" >&2
  exit 3
fi
SKILL_ROOT="$(cd "$SKILL_ROOT_ARG" && pwd -P)"

case "$RULE" in
  colorblind)
    FORBID='\b(green|lime|forestgreen|seagreen|darkgreen)\b|#(00[8a-f][0-9a-f]00|0f0\b|00ff00\b)|rgb\([[:space:]]*0[[:space:]]*,[[:space:]]*(255|128)[[:space:]]*,[[:space:]]*0[[:space:]]*\)'
    ALLOWLIST_FILES=(
      "references/color_palette.md"
      "references/scripts/lint_rule.sh"
    )
    LINE_EXCLUDE='NEVER|forbid|colorblind|auto-fail|MUST NOT|accessibility'
    EXTENSIONS=("md" "sh" "py" "html" "css" "json" "yaml" "yml" "toml" "txt")
    ;;
  *)
    echo "ERROR: unknown rule '$RULE'. Supported: colorblind" >&2
    exit 2
    ;;
esac

INCLUDES=()
for ext in "${EXTENSIONS[@]}"; do INCLUDES+=("--include=*.${ext}"); done

is_allowlisted() {
  local rel="$1"
  local af
  for af in "${ALLOWLIST_FILES[@]}"; do
    [[ "$rel" == "$af" ]] && return 0
  done
  return 1
}

violations=0
while IFS= read -r match; do
  fp="${match%%:*}"
  rel="${fp#$SKILL_ROOT/}"
  if is_allowlisted "$rel"; then
    continue
  fi
  rest="${match#*:}"
  text_only="${rest#*:}"
  if echo "$text_only" | grep -iEq -- "$LINE_EXCLUDE"; then
    continue
  fi
  echo "VIOLATION: $rel:$rest"
  violations=$((violations + 1))
done < <(grep -rEni "$FORBID" "$SKILL_ROOT" "${INCLUDES[@]}" 2>/dev/null || true)

if [[ $violations -gt 0 ]]; then
  echo "FAIL: $violations $RULE violation(s)"
  exit 1
fi
echo "PASS: 0 $RULE violations"
exit 0
