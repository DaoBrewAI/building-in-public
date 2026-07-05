#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-link}"
SKILL_NAME="finding-your-unknowns"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_ROOT="${CODEX_HOME:-$HOME/.codex}/skills"
DEST_DIR="$DEST_ROOT/$SKILL_NAME"

mkdir -p "$DEST_ROOT"

if [[ "$MODE" == "copy" ]]; then
  if [[ -e "$DEST_DIR" || -L "$DEST_DIR" ]]; then
    echo "Destination already exists: $DEST_DIR"
    echo "Move it aside or remove it before copy installing."
    exit 1
  fi
  cp -R "$SOURCE_DIR" "$DEST_DIR"
  echo "Installed copy: $DEST_DIR"
elif [[ "$MODE" == "link" ]]; then
  if [[ -e "$DEST_DIR" && ! -L "$DEST_DIR" ]]; then
    echo "Destination already exists and is not a symlink: $DEST_DIR"
    echo "Move it aside before link installing."
    exit 1
  fi
  ln -sfn "$SOURCE_DIR" "$DEST_DIR"
  echo "Installed symlink: $DEST_DIR -> $SOURCE_DIR"
else
  echo "Usage: $0 [link|copy]"
  exit 2
fi

echo "Restart or reload Codex to pick up the skill."
