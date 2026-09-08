#!/usr/bin/env bash
set -euo pipefail

skill_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_NAME="${PROJECT_NAME:-$(basename "$PWD")}"
LOOP_DIR="${LOOP_DIR:-docs/loop}"
AUTO_CHAIN="${AUTO_CHAIN:-false}"
OVERWRITE="${OVERWRITE:-false}"
DAG_TEMPLATE="${DAG_TEMPLATE:-false}"

for value in "$AUTO_CHAIN" "$OVERWRITE" "$DAG_TEMPLATE"; do
  if [[ "$value" != true && "$value" != false ]]; then
    echo "AUTO_CHAIN, OVERWRITE and DAG_TEMPLATE must be true or false" >&2
    exit 2
  fi
done

python3 - "$skill_root" "$PROJECT_NAME" "$LOOP_DIR" "$AUTO_CHAIN" "$OVERWRITE" "$DAG_TEMPLATE" <<'PY'
from pathlib import Path
import sys

skill, project, loop, auto_chain, overwrite, dag = sys.argv[1:]
raw_target = Path(loop)
if not loop or loop != str(raw_target) or ".." in raw_target.parts:
    raise SystemExit(f"LOOP_DIR must be a canonical path without escapes: {loop!r}")

repo_root = Path.cwd().resolve(strict=True)
target = raw_target if raw_target.is_absolute() else repo_root / raw_target
resolved_target = target.resolve(strict=False)
if resolved_target != target:
    raise SystemExit(f"Refusing LOOP_DIR with symlink ancestry or a noncanonical target: {loop}")
try:
    target.relative_to(repo_root)
except ValueError:
    raise SystemExit(f"LOOP_DIR must stay inside the current repository: {loop}") from None

names = ["goal.md", "tracker.md", "constraints.md", "handoff.md"]
if dag == "true":
    names.append("execution.json")
for name in names:
    if (target / name).is_symlink():
        raise SystemExit(f"Refusing symlink target: {target / name}")
target.mkdir(parents=True, exist_ok=True)
for name in names:
    output = target / name
    if output.exists() and overwrite != "true":
        print(f"Skipped existing file: {output}")
        continue
    template = "execution.example.json" if name == "execution.json" else name
    text = (Path(skill) / "templates" / template).read_text(encoding="utf-8")
    text = text.replace("{{PROJECT_NAME}}", project).replace("{{LOOP_DIR}}", loop).replace("{{AUTO_CHAIN}}", auto_chain)
    output.write_text(text, encoding="utf-8")
    print(f"Wrote: {output}")
print(f"\nLoop scaffold installed at {target}. Fill the actual goal, acceptance and authorized scope before execution.")
print("Defaults: plan mode, no execution authority, Standard/non-Fast sessions.")
PY
