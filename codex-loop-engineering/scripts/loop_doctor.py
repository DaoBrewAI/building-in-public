#!/usr/bin/env python3
"""Inspect repo-local Codex loop files.

This is a read-only helper. It summarizes the loop docs so the agent can orient
quickly before reading the files in full.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

from execution_manifest import inspect_file


THREAD_ID_RE = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")
CHECKBOX_RE = re.compile(r"^\s*-\s+\[(?P<status>[ xX~!])\]\s+(?P<text>.+?)\s*$")
KEY_LINE_RE = re.compile(
    r"(?i)(current checkpoint|current next action|next checkpoint|last checkpoint|auto_chain_next_session|created continuation thread|next checkpoint thread)\s*:?\s*(?P<value>.*)"
)
ACTIVE_METADATA_RE = re.compile(
    r"^(mode|execution_authorized|auto_chain_next_session):\s*(?P<value>[^\n]+?)\s*$"
)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def find_key_lines(text: str) -> list[str]:
    lines: list[str] = []
    for line in text.splitlines():
        if KEY_LINE_RE.search(line):
            lines.append(line.strip())
    return lines


def find_checkboxes(text: str) -> list[dict[str, str]]:
    items: list[dict[str, str]] = []
    for line in text.splitlines():
        match = CHECKBOX_RE.match(line)
        if match:
            items.append({"status": match.group("status"), "text": match.group("text")})
    return items


def active_preamble(text: str) -> str:
    return re.split(r"(?m)^##\s", text, maxsplit=1)[0]


def active_metadata(text: str) -> tuple[dict[str, str], set[str]]:
    values: dict[str, str] = {}
    conflicts: set[str] = set()
    fence: str | None = None
    for line in active_preamble(text).splitlines():
        stripped = line.lstrip()
        marker = "```" if stripped.startswith("```") else "~~~" if stripped.startswith("~~~") else None
        if marker:
            if fence is None:
                fence = marker
            elif fence == marker:
                fence = None
            continue
        if fence is not None:
            continue
        match = ACTIVE_METADATA_RE.fullmatch(line)
        if not match:
            continue
        key = match.group(1)
        value = match.group("value").strip().strip("\"'")
        if key in values and values[key] != value:
            conflicts.add(key)
        else:
            values[key] = value
    return values, conflicts


def active_auto_chain_enabled(handoff: str) -> bool:
    metadata, conflicts = active_metadata(handoff)
    return "auto_chain_next_session" not in conflicts and metadata.get("auto_chain_next_session", "").lower() == "true"


def summarize(loop_dir: Path) -> dict:
    files = {
        "goal": loop_dir / "goal.md",
        "tracker": loop_dir / "tracker.md",
        "constraints": loop_dir / "constraints.md",
        "handoff": loop_dir / "handoff.md",
    }
    contents = {name: read(path) for name, path in files.items()}
    missing = [str(path) for path in files.values() if not path.exists()]
    all_text = "\n".join(contents.values())
    checkboxes = find_checkboxes(contents["tracker"])
    unchecked = [item for item in checkboxes if item["status"] == " "]
    blocked = [item for item in checkboxes if item["status"] == "!"]

    result = {
        "loop_dir": str(loop_dir),
        "ok": not missing,
        "missing_files": missing,
        "key_lines": {
            name: find_key_lines(text)
            for name, text in contents.items()
            if text
        },
        "tracker_counts": {
            "total_checkboxes": len(checkboxes),
            "unchecked": len(unchecked),
            "blocked": len(blocked),
        },
        "next_unchecked": unchecked[0]["text"] if unchecked else None,
        "blocked_items": [item["text"] for item in blocked],
        "auto_chain_enabled": active_auto_chain_enabled(contents["handoff"]),
        "thread_ids": sorted(set(THREAD_ID_RE.findall(all_text))),
        "stale_markers": [
            line.strip()
            for line in all_text.splitlines()
            if re.search(r"(?i)\b(stale|pending re-creation|unreadable|unopenable|not visible|not found)\b", line)
        ],
    }
    manifest = loop_dir / "execution.json"
    if manifest.exists():
        result["execution"] = inspect_file(manifest)
        execution = result["execution"]
        for name in ("goal", "handoff"):
            # Only active preamble metadata, not historical sections/examples.
            metadata, conflicts = active_metadata(contents[name])
            for key in sorted(conflicts & {"mode", "execution_authorized"}):
                execution["errors"].append(f"{name}.md has conflicting active {key} values")
                execution["ok"] = False
                execution["dispatchable"] = []
            for key, value in metadata.items():
                if key not in {"mode", "execution_authorized"} or key in conflicts:
                    continue
                expected = execution.get(key)
                if key == "execution_authorized":
                    value = {"true": True, "false": False}.get(value.lower(), value)
                if value != expected:
                    execution["errors"].append(f"{name}.md {key} conflicts with execution.json")
                    execution["ok"] = False
                    execution["dispatchable"] = []
        result["ok"] = result["ok"] and result["execution"]["ok"]
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--loop-dir", default="docs/loop", help="Loop directory to inspect.")
    parser.add_argument("--json", action="store_true", help="Print JSON.")
    args = parser.parse_args()

    result = summarize(Path(args.loop_dir))
    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print(f"Loop dir: {result['loop_dir']}")
        print(f"OK: {result['ok']}")
        if result["missing_files"]:
            print("Missing:")
            for item in result["missing_files"]:
                print(f"- {item}")
        print(f"Next unchecked: {result['next_unchecked']}")
        print(f"Auto-chain: {result['auto_chain_enabled']}")
        if "execution" in result:
            print(f"DAG dispatch candidates: {', '.join(result['execution']['dispatchable']) or '(none)'}")
            for error in result["execution"]["errors"]:
                print(f"Policy error: {error}")
        print(f"Thread IDs: {', '.join(result['thread_ids']) or '(none)'}")
        if result["stale_markers"]:
            print("Stale markers:")
            for item in result["stale_markers"]:
                print(f"- {item}")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
