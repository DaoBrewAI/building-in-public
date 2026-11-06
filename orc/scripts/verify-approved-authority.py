#!/usr/bin/env python3
"""Verify the one frozen four-file Orchestrator approval authority."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any


EXPECTED_FILES = {
    "approved-design.md",
    "approved-plan.md",
    "brief-exec.md",
    "approved-task-dag.json",
}
HASH_LINE_RE = re.compile(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)")
TASK_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")


class ApprovalError(RuntimeError):
    pass


def regular_bytes(path: Path, label: str) -> bytes:
    try:
        before = path.lstat()
    except FileNotFoundError as error:
        raise ApprovalError(f"{label} is missing") from error
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise ApprovalError(f"{label} is unsafe")
    data = path.read_bytes()
    after = path.lstat()
    if (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
    ) != (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
    ):
        raise ApprovalError(f"{label} changed while being read")
    return data


def control_directory(raw: str) -> Path:
    path = Path(raw)
    if not path.is_absolute() or not path.is_dir() or path.is_symlink():
        raise ApprovalError("control-dir is missing, relative, or symlinked")
    physical = Path(os.path.realpath(path))
    if physical != path:
        raise ApprovalError("control-dir is not canonical")
    return path


def validate_dag(raw: bytes) -> dict[str, Any]:
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ApprovalError("approved task DAG is invalid JSON") from error
    if not isinstance(value, dict) or value.get("version") != 1:
        raise ApprovalError("approved task DAG schema/version is invalid")
    tasks = value.get("tasks")
    if not isinstance(tasks, list):
        raise ApprovalError("approved task DAG tasks are invalid")
    seen: set[str] = set()
    for task in tasks:
        if not isinstance(task, dict):
            raise ApprovalError("approved task DAG node is invalid")
        task_id = task.get("id")
        files = task.get("files")
        if (
            not isinstance(task_id, str)
            or TASK_ID_RE.fullmatch(task_id) is None
            or task_id in seen
            or not isinstance(files, list)
            or any(not isinstance(item, str) or not item for item in files)
            or len(files) != len(set(files))
        ):
            raise ApprovalError("approved task DAG node identity/files are invalid")
        seen.add(task_id)
    return value


def load(control: Path) -> dict[str, Any]:
    manifest_raw = regular_bytes(control / "approved.sha256", "approved hash manifest")
    try:
        lines = manifest_raw.decode("ascii").splitlines()
    except UnicodeDecodeError as error:
        raise ApprovalError("approved hash manifest is not ASCII") from error
    if len(lines) != len(EXPECTED_FILES) or not manifest_raw.endswith(b"\n"):
        raise ApprovalError("approved hash manifest must contain exactly four entries")
    entries: dict[str, str] = {}
    for line in lines:
        match = HASH_LINE_RE.fullmatch(line)
        if match is None or match.group(2) in entries:
            raise ApprovalError("approved hash manifest is malformed or duplicated")
        entries[match.group(2)] = match.group(1)
    if set(entries) != EXPECTED_FILES:
        raise ApprovalError("approved hash manifest file set is not exact")
    contents: dict[str, bytes] = {}
    for name in sorted(EXPECTED_FILES):
        raw = regular_bytes(control / name, f"approved artifact {name}")
        if hashlib.sha256(raw).hexdigest() != entries[name]:
            raise ApprovalError(f"approved artifact hash mismatch: {name}")
        contents[name] = raw
    return validate_dag(contents["approved-task-dag.json"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control-dir", required=True)
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--task-files")
    output.add_argument("--task-ids", action="store_true")
    output.add_argument("--dag-json", action="store_true")
    args = parser.parse_args()
    try:
        dag = load(control_directory(args.control_dir))
        if args.task_files is not None:
            matches = [task for task in dag["tasks"] if task["id"] == args.task_files]
            if len(matches) != 1 or not matches[0]["files"]:
                raise ApprovalError("approved DAG lacks one task with non-empty file scope")
            print(json.dumps(matches[0]["files"], ensure_ascii=False, separators=(",", ":")))
        elif args.task_ids:
            for task_id in sorted(task["id"] for task in dag["tasks"]):
                print(task_id)
        elif args.dag_json:
            print(json.dumps(dag, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
        return 0
    except (ApprovalError, OSError) as error:
        print(f"verify-approved-authority: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
