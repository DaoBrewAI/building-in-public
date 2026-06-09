#!/usr/bin/env bash
# Install the 10x-engineer toolkit into a Claude Code config directory,
# making its skills, commands, agent, and session-start hook available
# globally (default: user-level ~/.claude) rather than scoped to one project.
#
# Usage:
#   ./install.sh              # install into ~/.claude (global, all projects)
#   ./install.sh /path/.claude  # install into a specific .claude dir
#
# Re-running is safe: it overwrites the toolkit's own files and merges its
# SessionStart hook into settings.json without disturbing other settings.

set -euo pipefail

# Directory containing this script (the packaged toolkit).
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Destination Claude config dir (default: global user-level config).
DEST="${1:-$HOME/.claude}"

echo "Installing 10x-engineer from: $SRC"
echo "                         into: $DEST"

mkdir -p "$DEST/skills" "$DEST/commands" "$DEST/agents" "$DEST/hooks"

# Skills, commands, agent. Each skill lives in its own subdirectory.
cp -r "$SRC/skills/." "$DEST/skills/"
cp -r "$SRC/commands/." "$DEST/commands/"
cp -r "$SRC/agents/." "$DEST/agents/"

# Session-start hook. Placed at <DEST>/hooks/ so the hook resolves its root
# as hooks/.. == <DEST> and finds <DEST>/skills/using-superpowers/SKILL.md.
cp "$SRC/hooks/session-start.sh" "$DEST/hooks/session-start.sh"
chmod +x "$DEST/hooks/session-start.sh"

# Merge the SessionStart hook into settings.json (create if absent), without
# clobbering existing settings or duplicating our own entry. Requires python3.
HOOK_CMD="$DEST/hooks/session-start.sh"
SETTINGS="$DEST/settings.json"
python3 - "$SETTINGS" "$HOOK_CMD" <<'PY'
import json, os, sys
settings_path, hook_cmd = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError:
            data = {}
hooks = data.setdefault("hooks", {})
ss = hooks.setdefault("SessionStart", [])
entry = {
    "matcher": "startup|resume|clear|compact",
    "hooks": [{"type": "command", "command": hook_cmd}],
}
# Drop any prior 10x-engineer entry pointing at our hook, then add a fresh one.
ss[:] = [
    e for e in ss
    if not any(h.get("command") == hook_cmd for h in e.get("hooks", []))
]
ss.append(entry)
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"Updated SessionStart hook in {settings_path}")
PY

echo
echo "Done. Installed:"
echo "  - $(find "$DEST/skills" -name SKILL.md | wc -l | tr -d ' ') skills"
echo "  - $(find "$DEST/commands" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ') commands"
echo "  - code-reviewer agent"
echo "  - SessionStart hook -> $HOOK_CMD"
echo
echo "Restart Claude Code (or start a new session) to load them."
