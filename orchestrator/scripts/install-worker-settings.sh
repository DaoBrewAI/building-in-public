#!/usr/bin/env bash
# Install mission guard hooks in Claude's local project settings layer.
set -euo pipefail

usage() {
  echo "usage: install-worker-settings.sh --worktree <path> --template <path> --worktrees <colon-list> --mission-dir <path> --control-dir <path> --guard-script <path> --gate-script <path>" >&2
  exit 2
}

WORKTREE=""
TEMPLATE=""
WORKTREES=""
MISSION_DIR=""
CONTROL_DIR=""
GUARD_SCRIPT=""
GATE_SCRIPT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree) WORKTREE="${2:-}"; shift 2 ;;
    --template) TEMPLATE="${2:-}"; shift 2 ;;
    --worktrees) WORKTREES="${2:-}"; shift 2 ;;
    --mission-dir) MISSION_DIR="${2:-}"; shift 2 ;;
    --control-dir) CONTROL_DIR="${2:-}"; shift 2 ;;
    --guard-script) GUARD_SCRIPT="${2:-}"; shift 2 ;;
    --gate-script) GATE_SCRIPT="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

for required in WORKTREE TEMPLATE WORKTREES MISSION_DIR CONTROL_DIR GUARD_SCRIPT GATE_SCRIPT; do
  [[ -n "${!required}" ]] || usage
done

[[ -d "$WORKTREE" ]] || { echo "worktree does not exist: $WORKTREE" >&2; exit 1; }
WORKTREE="$(cd "$WORKTREE" && pwd -P)"
git -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "not a Git worktree: $WORKTREE" >&2
  exit 1
}
[[ -f "$TEMPLATE" && ! -L "$TEMPLATE" ]] || {
  echo "worker settings template must be a regular file: $TEMPLATE" >&2
  exit 1
}
[[ -d "$MISSION_DIR" ]] || { echo "mission directory does not exist: $MISSION_DIR" >&2; exit 1; }
[[ -d "$CONTROL_DIR" ]] || { echo "control directory does not exist: $CONTROL_DIR" >&2; exit 1; }
[[ -x "$GUARD_SCRIPT" ]] || { echo "guard script is not executable: $GUARD_SCRIPT" >&2; exit 1; }
[[ -x "$GATE_SCRIPT" ]] || { echo "gate script is not executable: $GATE_SCRIPT" >&2; exit 1; }

# The template places these values inside single-quoted shell arguments. Reject
# characters that could terminate that quoting or introduce another command.
for value in "$WORKTREES" "$MISSION_DIR" "$CONTROL_DIR" "$GUARD_SCRIPT" "$GATE_SCRIPT"; do
  case "$value" in
    *"'"*|*$'\n'*|*$'\r'*|*$'\t'*)
      echo "worker settings values cannot contain quotes, tabs, or newlines" >&2
      exit 1
      ;;
  esac
done

CLAUDE_DIR="$WORKTREE/.claude"
LOCAL_SETTINGS="$CLAUDE_DIR/settings.local.json"
SETTINGS_STAMP="$CONTROL_DIR/worker-settings.sha256"
if [[ -L "$CLAUDE_DIR" ]]; then
  echo "refusing symlinked Claude settings directory: $CLAUDE_DIR" >&2
  exit 1
fi
if [[ -e "$CLAUDE_DIR" && ! -d "$CLAUDE_DIR" ]]; then
  echo "Claude settings path is not a directory: $CLAUDE_DIR" >&2
  exit 1
fi
if [[ -e "$LOCAL_SETTINGS" || -L "$LOCAL_SETTINGS" ]]; then
  echo "refusing to overwrite existing local Claude settings: $LOCAL_SETTINGS" >&2
  exit 1
fi
if [[ -e "$SETTINGS_STAMP" || -L "$SETTINGS_STAMP" ]]; then
  echo "refusing to overwrite existing worker settings hash: $SETTINGS_STAMP" >&2
  exit 1
fi

mkdir -p "$CLAUDE_DIR"
umask 077
TMP_SETTINGS="$(mktemp "$CLAUDE_DIR/.settings.local.XXXXXX")"
TMP_STAMP="$(mktemp "$CONTROL_DIR/.worker-settings.sha256.XXXXXX")"
STAMP_INSTALLED=0
cleanup() {
  rm -f "$TMP_SETTINGS" "$TMP_STAMP"
  if [[ "$STAMP_INSTALLED" -eq 1 ]]; then
    rm -f "$SETTINGS_STAMP"
  fi
}
trap cleanup EXIT

jq \
  --arg worktrees "$WORKTREES" \
  --arg mission "$MISSION_DIR" \
  --arg control "$CONTROL_DIR" \
  --arg guard "$GUARD_SCRIPT" \
  --arg gate "$GATE_SCRIPT" \
  '
    def subst($from; $to): split($from) | join($to);
    def render:
      if type == "object" then with_entries(.value |= render)
      elif type == "array" then map(render)
      elif type == "string" then
        subst("{{WORKTREES}}"; $worktrees)
        | subst("{{MISSION_DIR}}"; $mission)
        | subst("{{CONTROL_DIR}}"; $control)
        | subst("{{GUARD_SCRIPT}}"; $guard)
        | subst("{{GATE_SCRIPT}}"; $gate)
      else . end;
    render
  ' "$TEMPLATE" > "$TMP_SETTINGS"

jq -e . "$TMP_SETTINGS" >/dev/null
if grep -Fq '{{' "$TMP_SETTINGS"; then
  echo "worker settings template contains an unresolved placeholder" >&2
  exit 1
fi

EXCLUDE_FILE="$(git -C "$WORKTREE" rev-parse --git-path info/exclude)"
case "$EXCLUDE_FILE" in
  /*) ;;
  *) EXCLUDE_FILE="$WORKTREE/$EXCLUDE_FILE" ;;
esac
mkdir -p "$(dirname "$EXCLUDE_FILE")"
touch "$EXCLUDE_FILE"
if ! grep -Fqx '.claude/settings.local.json' "$EXCLUDE_FILE"; then
  printf '%s\n' '.claude/settings.local.json' >> "$EXCLUDE_FILE"
fi

shasum -a 256 "$TMP_SETTINGS" | awk '{print $1}' > "$TMP_STAMP"
if ! ln "$TMP_STAMP" "$SETTINGS_STAMP"; then
  echo "refusing to overwrite worker settings hash: $SETTINGS_STAMP" >&2
  exit 1
fi
STAMP_INSTALLED=1
rm -f "$TMP_STAMP"

# A hard-link create is atomic and fails if a competing local settings file
# appeared after the preflight check. Unlike mv, it never clobbers that file.
if ! ln "$TMP_SETTINGS" "$LOCAL_SETTINGS"; then
  echo "refusing to overwrite local Claude settings created during provisioning: $LOCAL_SETTINGS" >&2
  exit 1
fi
rm -f "$TMP_SETTINGS"
STAMP_INSTALLED=0
trap - EXIT
echo "$LOCAL_SETTINGS"
