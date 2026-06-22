#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-symlink}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
TARGET_DIR="$CODEX_HOME/skills"
TARGET="$TARGET_DIR/codex-loop-engineering"

mkdir -p "$TARGET_DIR"

case "$MODE" in
  symlink)
    if [[ -e "$TARGET" && ! -L "$TARGET" ]]; then
      echo "Refusing to replace existing non-symlink: $TARGET" >&2
      echo "Use '$0 copy' to replace it with a copied skill folder." >&2
      exit 1
    fi
    ln -sfn "$SKILL_DIR" "$TARGET"
    echo "Linked: $TARGET -> $SKILL_DIR"
    ;;
  copy)
    rm -rf "$TARGET"
    cp -R "$SKILL_DIR" "$TARGET"
    echo "Copied: $SKILL_DIR -> $TARGET"
    ;;
  *)
    echo "Usage: $0 [symlink|copy]" >&2
    exit 2
    ;;
esac

echo "Restart or reload Codex, then invoke: Use \$codex-loop-engineering to continue the loop."
