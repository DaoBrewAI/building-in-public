#!/usr/bin/env python3
"""Build and validate content-addressed Orchestrator continuation authority."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Optional


ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
OUTCOME_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,511}$")
COORDINATOR_FILE_RE = re.compile(r"^([0-9a-f]{64})\.session-id$")
SUPERSEDED_FILE_RE = re.compile(r"^([0-9a-f]{64})\.superseded\.json$")
PROMOTION_COMMIT_RE = re.compile(r"^([0-9a-f]{64})\.promotion-commit\.json$")
BROKER_LIFECYCLE_RE = re.compile(
    r"^COMMIT-(?:REQUEST|INTENT|DONE|REJECTED)-[A-Za-z0-9._-]+\.json$"
)
PLANNING_RECEIPT_RE = re.compile(r"^planning-stage-receipt-[0-9a-f]{64}\.json$")
REWORK_COMPLETION_RE = re.compile(r"^rework-completion-[1-9][0-9]*\.json$")
BLOCKED_LIFECYCLE_RE = re.compile(r"^BLOCKED-[1-9][0-9]*\.md$")
ELIGIBLE_MISSION_STATES = {
    "blocked",
    "cleanup_pending",
    "executed",
    "pending",
    "planned",
    "review",
    "rework",
    "running",
}
MISSION_LIFECYCLE_FILES = {
    "approved-design.md",
    "approved-plan.md",
    "approved-task-dag.json",
    "approved.sha256",
    "brief-exec.md",
    "parent-cleanup-intent",
    "parent-cleanup-journal.log",
    "parent-cleanup-manifest.txt",
    "parent-cleanup-state",
    "parent-cleanup-targets.txt",
    "planning-stage-authority.json",
    "planning-stage-import-intent.json",
}
TASK_LIFECYCLE_FILES = {
    ".rework-intent.json",
    "child_tip",
    "cleanup-intent",
    "cleanup-journal.log",
    "coordinator-verification.md",
    "coordinator-verification.sha",
    "integrated_sha",
    "integration-intent",
    "parent-verification.sha",
    "task-state-dir",
    "task-window-archive-pending",
    "task-window-state",
    "unresolved-rework",
}
TASK_STATE_LIFECYCLE_FILES = {
    "accepted-thread-id", "generation", "report.md", "state",
    "verification.sha", "worktrees.txt",
}
NATIVE_HEALTH_FILES = {
    "request.json", "attempt-1.json", "attempt-1-archive.json", "attempt-2.json",
    "accepted.json", "blocked.json",
}
REQUEST_KEYS = {"binding", "binding_sha256", "request_id"}
BINDING_KEYS = {
    "carryover",
    "hub_path",
    "missions",
    "protocol_version",
    "requested_continuations",
    "source",
    "status",
}
FILE_KEYS = {"bytes_b64", "device", "inode", "path", "sha256", "size"}
SCALAR_KEYS = FILE_KEYS | {"value"}
OUTCOME_COMMON_KEYS = {
    "accepted_thread_id", "generation", "kind", "outcome_nonce",
    "protocol_version", "task_id",
}
OUTCOME_KIND_KEYS = {
    "ready_for_commit": {
        "base_sha", "changed_files", "commit_message", "deviations",
        "head_sha", "risks", "verification",
    },
    "blocked": {"options", "question", "recommendation", "work_in_progress"},
    "failed": {"error", "work_in_progress"},
    "completed": {
        "base_sha", "changed_files", "commit_sha", "deviations", "risks",
        "verification",
    },
}


class AuthorityError(RuntimeError):
    pass


class LockChangedError(AuthorityError):
    pass


def canonical_bytes(value: Any, newline: bool = False) -> bytes:
    rendered = json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return (rendered + ("\n" if newline else "")).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def strict_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or any(char in value for char in "\n\r\t\x00"):
        raise AuthorityError(f"invalid {label}")
    return value


def exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        raise AuthorityError(f"invalid {label} key set")
    return value


def canonical_absolute(path: str, label: str, must_exist: bool = True) -> str:
    strict_text(path, label)
    absolute = os.path.abspath(path)
    if absolute != path or os.path.realpath(path) != path:
        raise AuthorityError(f"noncanonical or escaped {label}")
    if must_exist and not os.path.lexists(path):
        raise AuthorityError(f"missing {label}")
    return path


def lexical_absolute(path: str, label: str) -> str:
    strict_text(path, label)
    if not path.startswith("/") or os.path.abspath(path) != path:
        raise AuthorityError(f"noncanonical or escaped {label}")
    return path


def open_absolute_directory(path: str, label: str) -> int:
    path = lexical_absolute(path, label)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open("/", flags)
    try:
        for component in (item for item in path.split("/") if item):
            next_descriptor = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        metadata = os.fstat(descriptor)
        if not stat.S_ISDIR(metadata.st_mode):
            raise AuthorityError(f"unsafe {label}")
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def safe_directory(path: str, label: str, parent: Optional[str] = None, allow_missing: bool = False) -> str:
    path = canonical_absolute(path, label, must_exist=not allow_missing)
    if parent is not None and os.path.dirname(path) != parent:
        raise AuthorityError(f"{label} is not a direct child")
    if not os.path.lexists(path):
        return path
    metadata = os.lstat(path)
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise AuthorityError(f"unsafe {label}")
    return path


def require_mode(metadata: os.stat_result, expected: int, label: str) -> None:
    actual = stat.S_IMODE(metadata.st_mode)
    if actual != expected:
        raise AuthorityError(f"unsafe {label} mode: {actual:04o}")


def safe_regular(
    path: str,
    label: str,
    parent: Optional[str] = None,
    expected_mode: Optional[int] = None,
) -> tuple[bytes, os.stat_result]:
    path = lexical_absolute(path, label)
    parent_path = os.path.dirname(path)
    if parent is not None and parent_path != parent:
        raise AuthorityError(f"{label} is not a direct child")
    parent_fd = open_absolute_directory(parent_path, f"{label} parent")
    leaf = os.path.basename(path)
    try:
        observed = os.stat(leaf, dir_fd=parent_fd, follow_symlinks=False)
        if stat.S_ISLNK(observed.st_mode) or not stat.S_ISREG(observed.st_mode):
            raise AuthorityError(f"unsafe {label}")
        marker_target = os.environ.get("ORC_CONTINUATION_TEST_SAFE_REGULAR_TARGET")
        if marker_target == path:
            wait_test_barrier("ORC_CONTINUATION_TEST_SAFE_REGULAR_MARKER")
        descriptor = os.open(
            leaf,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_fd,
        )
        try:
            before = os.fstat(descriptor)
            if not stat.S_ISREG(before.st_mode):
                raise AuthorityError(f"unsafe {label}")
            if before.st_dev != observed.st_dev or before.st_ino != observed.st_ino:
                raise AuthorityError(f"{label} epoch changed before open")
            if expected_mode is not None:
                require_mode(before, expected_mode, label)
            data = read_fd_all(descriptor)
            after = os.fstat(descriptor)
            if (
                after.st_dev != before.st_dev
                or after.st_ino != before.st_ino
                or after.st_size != before.st_size
                or after.st_mtime_ns != before.st_mtime_ns
            ):
                raise AuthorityError(f"{label} changed during read")
            return data, after
        finally:
            os.close(descriptor)
    finally:
        os.close(parent_fd)


def scalar_record(
    path: str, label: str, parent: str, expected_mode: Optional[int] = None
) -> dict[str, Any]:
    data, metadata = safe_regular(path, label, parent, expected_mode)
    if not data or not data.endswith(b"\n") or data.count(b"\n") != 1:
        raise AuthorityError(f"{label} is not a strict one-line authority")
    body = data[:-1]
    if not body or any(marker in body for marker in (b"\r", b"\t", b"\x00")):
        raise AuthorityError(f"invalid bytes in {label}")
    try:
        value = body.decode("utf-8")
    except UnicodeDecodeError as error:
        raise AuthorityError(f"invalid UTF-8 in {label}") from error
    return {
        "bytes_b64": base64.b64encode(data).decode("ascii"),
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "path": path,
        "sha256": sha256_bytes(data),
        "size": metadata.st_size,
        "value": value,
    }


def file_record(
    path: str, label: str, parent: str, expected_mode: Optional[int] = None
) -> dict[str, Any]:
    data, metadata = safe_regular(path, label, parent, expected_mode)
    return {
        "bytes_b64": base64.b64encode(data).decode("ascii"),
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "path": path,
        "sha256": sha256_bytes(data),
        "size": metadata.st_size,
    }


def optional_scalar_record(path: str, label: str, parent: str) -> Optional[dict[str, Any]]:
    return scalar_record(path, label, parent) if os.path.lexists(path) else None


def optional_file_record(path: str, label: str, parent: str) -> Optional[dict[str, Any]]:
    return file_record(path, label, parent) if os.path.lexists(path) else None


def strict_scalar_from_record(record: dict[str, Any], label: str) -> str:
    data = bound_bytes(record, label)
    if not data or not data.endswith(b"\n") or data.count(b"\n") != 1:
        raise AuthorityError(f"{label} is not a strict one-line authority")
    body = data[:-1]
    if not body or any(marker in body for marker in (b"\r", b"\t", b"\x00")):
        raise AuthorityError(f"invalid bytes in {label}")
    try:
        return body.decode("utf-8")
    except UnicodeDecodeError as error:
        raise AuthorityError(f"invalid UTF-8 in {label}") from error


def lifecycle_file(path: str, label: str, parent: str) -> dict[str, Any]:
    metadata = os.lstat(path)
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise AuthorityError(f"unsafe {label}")
    return file_record(path, label, parent)


def stage_lifecycle_records(
    root: str,
    label: str,
    directory_pattern: re.Pattern[str],
    allowed_names: set[str],
) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for entry in os.scandir(root):
        if directory_pattern.fullmatch(entry.name) is None:
            continue
        if entry.is_symlink() or not entry.is_dir(follow_symlinks=False):
            raise AuthorityError(f"unsafe {label} directory")
        directory = safe_directory(entry.path, label, root)
        for child in os.scandir(directory):
            if child.name not in allowed_names:
                raise AuthorityError(f"unexpected file in {label}: {child.name}")
            records.append(
                lifecycle_file(child.path, f"{label} {child.name}", directory)
            )
    return records


def mission_lifecycle_records(control_mission: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    approval_names = {
        "approved-design.md", "approved-plan.md", "approved-task-dag.json",
        "approved.sha256", "brief-exec.md",
    }
    present_approval = {
        name for name in approval_names if os.path.lexists(os.path.join(control_mission, name))
    }
    if present_approval:
        if present_approval != approval_names:
            raise AuthorityError("partial frozen approval authority")
        helper = os.path.join(
            os.path.dirname(os.path.dirname(os.path.realpath(__file__))),
            "scripts", "verify-approved-authority.py",
        )
        completed = subprocess.run(
            [helper, "--control-dir", control_mission],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if completed.returncode != 0:
            raise AuthorityError("frozen approval authority is invalid")
    for entry in os.scandir(control_mission):
        if (
            entry.name not in MISSION_LIFECYCLE_FILES
            and PLANNING_RECEIPT_RE.fullmatch(entry.name) is None
        ):
            continue
        records.append(
            lifecycle_file(entry.path, f"mission lifecycle {entry.name}", control_mission)
        )
    return sorted(records, key=lambda record: record["path"])


def task_lifecycle_records(task_dir: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    task_state_record: Optional[dict[str, Any]] = None
    for entry in os.scandir(task_dir):
        if (
            entry.name not in TASK_LIFECYCLE_FILES
            and BROKER_LIFECYCLE_RE.fullmatch(entry.name) is None
            and REWORK_COMPLETION_RE.fullmatch(entry.name) is None
        ):
            continue
        record = lifecycle_file(entry.path, f"task lifecycle {entry.name}", task_dir)
        records.append(record)
        if entry.name == "task-state-dir":
            task_state_record = record
    if task_state_record is not None:
        task_state_path = strict_scalar_from_record(task_state_record, "task state directory")
        task_state_path = safe_directory(task_state_path, "task state directory")
        for mirrored_name in ("state", "generation", "accepted-thread-id", "worktrees.txt"):
            control_path = os.path.join(task_dir, mirrored_name)
            worker_path = os.path.join(task_state_path, mirrored_name)
            control_exists = os.path.lexists(control_path)
            worker_exists = os.path.lexists(worker_path)
            if control_exists != worker_exists:
                raise AuthorityError(f"partial mirrored task authority: {mirrored_name}")
            if control_exists:
                control_raw, _ = safe_regular(
                    control_path, f"control mirrored {mirrored_name}", task_dir
                )
                worker_raw, _ = safe_regular(
                    worker_path, f"worker mirrored {mirrored_name}", task_state_path
                )
                if control_raw != worker_raw:
                    raise AuthorityError(f"mirrored task authority differs: {mirrored_name}")
        for entry in os.scandir(task_state_path):
            if (
                entry.name not in TASK_STATE_LIFECYCLE_FILES
                and BROKER_LIFECYCLE_RE.fullmatch(entry.name) is None
                and BLOCKED_LIFECYCLE_RE.fullmatch(entry.name) is None
            ):
                continue
            records.append(
                lifecycle_file(
                    entry.path, f"task state lifecycle {entry.name}", task_state_path
                )
            )
    native_health = os.path.join(task_dir, "native-health")
    if os.path.lexists(native_health):
        native_health = safe_directory(native_health, "native health", task_dir)
        for entry in os.scandir(native_health):
            if entry.name == ".lock":
                if entry.is_symlink() or not entry.is_file(follow_symlinks=False):
                    raise AuthorityError("unsafe native health lock")
                continue
            if entry.name not in NATIVE_HEALTH_FILES:
                raise AuthorityError(f"unexpected native health authority: {entry.name}")
            records.append(
                lifecycle_file(entry.path, f"native health {entry.name}", native_health)
            )
    return sorted(records, key=lambda record: record["path"])


def validate_lifecycle_bundle(
    records: Any,
    label: str,
    allowed_path: Any,
) -> None:
    if not isinstance(records, list):
        raise AuthorityError(f"invalid {label} bundle")
    paths: list[str] = []
    for record in records:
        validate_file_shape(record, False, label)
        path = lexical_absolute(record["path"], f"{label} path")
        if not allowed_path(path, records):
            raise AuthorityError(f"{label} path is outside the allowlist")
        paths.append(path)
    if paths != sorted(paths) or len(set(paths)) != len(paths):
        raise AuthorityError(f"noncanonical {label} ordering")


def mission_lifecycle_path_allowed(control_mission: str, path: str) -> bool:
    if os.path.dirname(path) != control_mission:
        return False
    name = os.path.basename(path)
    return name in MISSION_LIFECYCLE_FILES or PLANNING_RECEIPT_RE.fullmatch(name) is not None


def task_state_path_from_bundle(
    task_dir: str, records: list[dict[str, Any]]
) -> Optional[str]:
    expected = os.path.join(task_dir, "task-state-dir")
    matches = [record for record in records if record.get("path") == expected]
    if not matches:
        return None
    if len(matches) != 1:
        raise AuthorityError("duplicate task state directory authority")
    validate_file_shape(matches[0], False, "task state directory")
    value = strict_scalar_from_record(matches[0], "bound task state directory")
    return lexical_absolute(value, "bound task state directory")


def task_lifecycle_path_allowed(
    task_dir: str, path: str, records: list[dict[str, Any]]
) -> bool:
    if os.path.dirname(path) == task_dir:
        name = os.path.basename(path)
        return (
            name in TASK_LIFECYCLE_FILES
            or BROKER_LIFECYCLE_RE.fullmatch(name) is not None
            or REWORK_COMPLETION_RE.fullmatch(name) is not None
        )
    relative = os.path.relpath(path, task_dir)
    parts = relative.split(os.sep)
    if len(parts) == 2 and parts[0] == "native-health":
        return parts[1] in NATIVE_HEALTH_FILES
    task_state_path = task_state_path_from_bundle(task_dir, records)
    if task_state_path is None:
        return False
    relative = os.path.relpath(path, task_state_path)
    parts = relative.split(os.sep)
    if len(parts) == 1:
        return (
            parts[0] in TASK_STATE_LIFECYCLE_FILES
            or BROKER_LIFECYCLE_RE.fullmatch(parts[0]) is not None
            or BLOCKED_LIFECYCLE_RE.fullmatch(parts[0]) is not None
        )
    return False


def lifecycle_record_value(
    records: list[dict[str, Any]], name: str, label: str
) -> Optional[str]:
    matches = [record for record in records if os.path.basename(record["path"]) == name]
    if not matches:
        return None
    if len(matches) != 1:
        raise AuthorityError(f"ambiguous {label}")
    return strict_scalar_from_record(matches[0], label)


def validate_outcome_event(
    event: dict[str, Any], digest: str, accepted_thread: str,
    task_id: str, generation: int, nonce: str,
) -> None:
    raw = bound_bytes(event, "latest outcome event")
    if event.get("sha256") != digest or sha256_bytes(raw) != digest:
        raise AuthorityError("latest outcome event content address mismatch")
    try:
        wrapper = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AuthorityError("latest outcome event is invalid JSON") from error
    exact_keys(
        wrapper, {"accepted_thread_id", "outcome", "turn_id"},
        "latest outcome event wrapper",
    )
    if canonical_bytes(wrapper, newline=True) != raw:
        raise AuthorityError("latest outcome event is not canonical")
    if wrapper["accepted_thread_id"] != accepted_thread:
        raise AuthorityError("latest outcome event thread mismatch")
    if not isinstance(wrapper["turn_id"], str) or not OUTCOME_ID_RE.fullmatch(wrapper["turn_id"]):
        raise AuthorityError("latest outcome event turn id is invalid")
    outcome = wrapper["outcome"]
    if not isinstance(outcome, dict):
        raise AuthorityError("latest outcome envelope is invalid")
    kind = outcome.get("kind")
    expected_kind_keys = OUTCOME_KIND_KEYS.get(kind)
    if expected_kind_keys is None:
        raise AuthorityError("latest outcome kind is invalid")
    exact_keys(outcome, OUTCOME_COMMON_KEYS | expected_kind_keys, "latest outcome envelope")
    if (
        outcome["protocol_version"] != 1
        or outcome["accepted_thread_id"] != accepted_thread
        or outcome["task_id"] != task_id
        or outcome["generation"] != generation
        or outcome["outcome_nonce"] != nonce
    ):
        raise AuthorityError("latest outcome identity mismatch")


def validate_outcome_intent(record: dict[str, Any]) -> dict[str, Any]:
    raw = bound_bytes(record, "outcome intent")
    try:
        intent = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AuthorityError("outcome intent is invalid JSON") from error
    exact_keys(
        intent,
        {"digest", "previous_latest", "previous_state", "turn_id"},
        "outcome intent",
    )
    if not isinstance(intent["digest"], str) or not SHA_RE.fullmatch(intent["digest"]):
        raise AuthorityError("outcome intent digest is invalid")
    previous = intent["previous_latest"]
    if previous is not None and (
        not isinstance(previous, str) or not SHA_RE.fullmatch(previous)
    ):
        raise AuthorityError("outcome intent previous digest is invalid")
    strict_text(intent["previous_state"], "outcome intent previous state")
    if not isinstance(intent["turn_id"], str) or not OUTCOME_ID_RE.fullmatch(intent["turn_id"]):
        raise AuthorityError("outcome intent turn id is invalid")
    if canonical_bytes(intent, newline=True) != raw:
        raise AuthorityError("outcome intent is not canonical")
    return intent


def task_outcome_records(
    task_dir: str, task_id: str, generation: dict[str, Any],
    accepted_thread: Optional[dict[str, Any]],
) -> dict[str, Any]:
    nonce = optional_scalar_record(
        os.path.join(task_dir, "outcome-nonce"), "outcome nonce", task_dir
    )
    latest = optional_scalar_record(
        os.path.join(task_dir, "latest-outcome"), "latest outcome", task_dir
    )
    intent = optional_file_record(
        os.path.join(task_dir, ".outcome-intent.json"), "outcome intent", task_dir
    )
    if (accepted_thread is None) != (nonce is None):
        raise AuthorityError("accepted task thread and outcome nonce authority are incomplete")
    if accepted_thread is not None:
        if not OUTCOME_ID_RE.fullmatch(accepted_thread["value"]):
            raise AuthorityError("accepted task thread is invalid")
        if not OUTCOME_ID_RE.fullmatch(nonce["value"]):
            raise AuthorityError("outcome nonce is invalid")
    if latest is None:
        if intent is not None:
            if accepted_thread is None or nonce is None:
                raise AuthorityError("outcome intent lacks accepted task identity")
            validate_outcome_intent(intent)
        return {
            "latest_outcome": None,
            "latest_outcome_event": None,
            "outcome_intent": intent,
            "outcome_nonce": nonce,
        }
    if accepted_thread is None or nonce is None:
        raise AuthorityError("latest outcome lacks accepted task identity")
    digest = latest["value"]
    if not SHA_RE.fullmatch(digest):
        raise AuthorityError("latest outcome digest is invalid")
    outcomes = safe_directory(
        os.path.join(task_dir, "outcomes"), "task outcomes", task_dir
    )
    event = file_record(
        os.path.join(outcomes, digest + ".json"), "latest outcome event", outcomes
    )
    validate_outcome_event(
        event, digest, accepted_thread["value"], task_id,
        int(generation["value"]), nonce["value"],
    )
    if intent is not None:
        validate_outcome_intent(intent)
    return {
        "latest_outcome": latest,
        "latest_outcome_event": event,
        "outcome_intent": intent,
        "outcome_nonce": nonce,
    }


def validate_bound_scalar(record: dict[str, Any], label: str) -> str:
    validate_file_shape(record, True, label)
    value = strict_text(record["value"], label)
    if bound_bytes(record, label) != (value + "\n").encode("utf-8"):
        raise AuthorityError(f"bound {label} bytes contradict value")
    return value


def validate_bound_task_outcome(task: dict[str, Any]) -> None:
    accepted = task["accepted_thread"]
    nonce = task["outcome_nonce"]
    latest = task["latest_outcome"]
    event = task["latest_outcome_event"]
    intent = task["outcome_intent"]
    if (accepted is None) != (nonce is None):
        raise AuthorityError("bound accepted task thread and outcome nonce are incomplete")
    accepted_value = validate_bound_scalar(accepted, "accepted thread") if accepted else None
    nonce_value = validate_bound_scalar(nonce, "outcome nonce") if nonce else None
    if accepted_value is not None and (
        not OUTCOME_ID_RE.fullmatch(accepted_value)
        or not OUTCOME_ID_RE.fullmatch(nonce_value)
    ):
        raise AuthorityError("bound accepted task identity is invalid")
    if (latest is None) != (event is None):
        raise AuthorityError("partial bound latest outcome authority")
    if intent is not None:
        validate_file_shape(intent, False, "outcome intent")
        task_path = strict_text(task["path"], "task path")
        if intent["path"] != os.path.join(task_path, ".outcome-intent.json"):
            raise AuthorityError("bound outcome intent path is invalid")
        validate_outcome_intent(intent)
        if accepted_value is None or nonce_value is None:
            raise AuthorityError("bound outcome intent lacks accepted task identity")
    if latest is None:
        return
    if accepted_value is None or nonce_value is None:
        raise AuthorityError("bound latest outcome lacks accepted task identity")
    digest = validate_bound_scalar(latest, "latest outcome")
    if not SHA_RE.fullmatch(digest):
        raise AuthorityError("bound latest outcome digest is invalid")
    validate_file_shape(event, False, "latest outcome event")
    task_path = strict_text(task["path"], "task path")
    if latest["path"] != os.path.join(task_path, "latest-outcome"):
        raise AuthorityError("bound latest outcome path is invalid")
    expected_event_path = os.path.join(task_path, "outcomes", digest + ".json")
    if event["path"] != expected_event_path:
        raise AuthorityError("bound latest outcome event path is invalid")
    validate_outcome_event(
        event, digest, accepted_value, task["task"],
        int(task["generation"]["value"]), nonce_value,
    )


def bound_bytes(record: dict[str, Any], label: str) -> bytes:
    try:
        return base64.b64decode(record["bytes_b64"], validate=True)
    except (KeyError, ValueError) as error:
        raise AuthorityError(f"invalid bound bytes for {label}") from error


def planning_session_values(record: dict[str, Any], label: str) -> dict[str, list[str]]:
    try:
        text = bound_bytes(record, label).decode("utf-8")
    except UnicodeDecodeError as error:
        raise AuthorityError(f"invalid UTF-8 in {label}") from error
    values: dict[str, list[str]] = {}
    for key, value in re.findall(r"(?m)^([A-Za-z_]+): ([^\r\n]+)$", text):
        values.setdefault(key, []).append(value)
    return values


def one_planning_value(values: dict[str, list[str]], key: str, label: str) -> str:
    matches = values.get(key, [])
    if len(matches) != 1:
        raise AuthorityError(f"invalid {label} {key} authority")
    return strict_text(matches[0], f"{label} {key}")


def validate_codex_health(record: dict[str, Any], thread_id: str) -> None:
    try:
        health = json.loads(bound_bytes(record, "planning thread health"))
    except (TypeError, ValueError, UnicodeDecodeError) as error:
        raise AuthorityError("invalid planning thread health JSON") from error
    exact_keys(
        health,
        {
            "created", "visible", "title_verified", "first_turn_exists",
            "startup_evidence", "settings_recorded", "worktree_verified",
            "status", "thread_id", "model", "effort", "project_id", "cwd",
        },
        "planning thread health",
    )
    for key in (
        "created", "visible", "title_verified", "first_turn_exists",
        "startup_evidence", "settings_recorded", "worktree_verified",
    ):
        if health[key] is not True:
            raise AuthorityError("incomplete planning thread health")
    if (
        health["thread_id"] != thread_id
        or health["model"] != "gpt-5.6-sol"
        or health["effort"] != "ultra"
        or health["status"] not in {"inProgress", "completed", "idle"}
    ):
        raise AuthorityError("planning thread health contradicts session authority")
    strict_text(health["project_id"], "planning project id")
    strict_text(health["cwd"], "planning cwd")


def validate_quota_receipt(
    record: dict[str, Any], stage: str, session_id: str
) -> None:
    try:
        receipt = json.loads(bound_bytes(record, f"{stage} quota fallback"))
    except (TypeError, ValueError, UnicodeDecodeError) as error:
        raise AuthorityError("invalid quota fallback JSON") from error
    exact_keys(receipt, {"from", "session_id", "stage", "to"}, "quota fallback")
    if receipt != {
        "from": "claude-fable-5",
        "session_id": session_id,
        "stage": stage,
        "to": "claude-opus-5",
    }:
        raise AuthorityError("quota fallback contradicts planning session authority")


def planning_authority_records(
    mission_dir: str,
    control_mission: str,
    backend: str,
    state: str,
) -> dict[str, Any]:
    session = optional_file_record(
        os.path.join(mission_dir, "session.txt"), "planning session", mission_dir
    )
    planning_session = optional_scalar_record(
        os.path.join(control_mission, "planning-session-id"),
        "planning session id",
        control_mission,
    )
    planning_thread = optional_scalar_record(
        os.path.join(control_mission, "planning-thread-id"),
        "planning thread",
        control_mission,
    )
    planning_health = optional_file_record(
        os.path.join(control_mission, "planning-thread-health.json"),
        "planning thread health",
        control_mission,
    )
    quota_fallbacks = {
        stage: optional_file_record(
            os.path.join(control_mission, f"quota-fallback-{stage}.json"),
            f"{stage} quota fallback",
            control_mission,
        )
        for stage in ("plan", "review")
    }
    if backend == "fable-opus":
        if planning_thread is not None or planning_health is not None:
            raise AuthorityError("Fable/Opus mission has Codex planning-thread authority")
        if (session is None) != (planning_session is None):
            raise AuthorityError("partial Fable/Opus planning session authority")
        if state != "pending" and session is None:
            raise AuthorityError("active Fable/Opus mission lacks planning session authority")
        if session is None:
            if any(value is not None for value in quota_fallbacks.values()):
                raise AuthorityError("quota fallback exists without planning session authority")
        else:
            values = planning_session_values(session, "Fable/Opus planning session")
            session_id = one_planning_value(values, "session_id", "Fable/Opus planning session")
            if not ID_RE.fullmatch(session_id) or planning_session["value"] != session_id:
                raise AuthorityError("Fable/Opus planning session authority mismatch")
            if one_planning_value(values, "backend", "Fable/Opus planning session") != "claude-headless":
                raise AuthorityError("invalid Fable/Opus planning backend")
            if one_planning_value(values, "model", "Fable/Opus planning session") != "claude-fable-5":
                raise AuthorityError("invalid Fable/Opus initial planning model")
            stages = values.get("stage", [])
            if not stages or any(stage not in {"plan", "review"} for stage in stages):
                raise AuthorityError("invalid Fable/Opus planning stage")
            for stage, receipt in quota_fallbacks.items():
                if receipt is not None:
                    validate_quota_receipt(receipt, stage, session_id)
    elif backend == "codex-ultra":
        if planning_session is not None or any(
            value is not None for value in quota_fallbacks.values()
        ):
            raise AuthorityError("Codex Ultra mission has Claude planning authority")
        present = (session is not None, planning_thread is not None, planning_health is not None)
        if any(present) and not all(present):
            raise AuthorityError("partial Codex Ultra planning task authority")
        if state != "pending" and not all(present):
            raise AuthorityError("active Codex Ultra mission lacks planning task authority")
        if all(present):
            values = planning_session_values(session, "Codex Ultra planning session")
            if one_planning_value(values, "backend", "Codex Ultra planning session") != "codex-native":
                raise AuthorityError("invalid Codex Ultra planning backend")
            if one_planning_value(values, "model", "Codex Ultra planning session") != "gpt-5.6-sol":
                raise AuthorityError("invalid Codex Ultra planning model")
            if one_planning_value(values, "effort", "Codex Ultra planning session") != "ultra":
                raise AuthorityError("invalid Codex Ultra planning effort")
            thread_id = one_planning_value(values, "thread_id", "Codex Ultra planning session")
            if one_planning_value(values, "stage", "Codex Ultra planning session") not in {"plan", "review"}:
                raise AuthorityError("invalid Codex Ultra planning stage")
            if planning_thread["value"] != thread_id:
                raise AuthorityError("Codex Ultra planning thread authority mismatch")
            validate_codex_health(planning_health, thread_id)
    else:
        raise AuthorityError("unsupported planning backend")
    return {
        "planning_health": planning_health,
        "planning_session": planning_session,
        "planning_thread": planning_thread,
        "quota_fallbacks": quota_fallbacks,
        "session": session,
    }


def direct_directories(path: str, label: str) -> list[str]:
    result: list[str] = []
    for entry in os.scandir(path):
        if entry.is_symlink() or not entry.is_dir(follow_symlinks=False):
            raise AuthorityError(f"unsafe direct entry in {label}: {entry.name}")
        if not ID_RE.fullmatch(entry.name):
            raise AuthorityError(f"invalid direct entry name in {label}: {entry.name}")
        result.append(entry.name)
    return sorted(result)


def preflight_hub(hub: str) -> str:
    hub = safe_directory(hub, "hub")
    if os.path.basename(hub) != ".orchestrator":
        raise AuthorityError("hub must end in .orchestrator")
    missions_root = safe_directory(os.path.join(hub, "missions"), "missions root", hub)
    control_root = safe_directory(os.path.join(hub, "control"), "control root", hub)

    coordinators_root = os.path.join(control_root, "coordinators")
    safe_directory(coordinators_root, "coordinators root", control_root, allow_missing=True)
    if os.path.lexists(coordinators_root):
        require_mode(os.lstat(coordinators_root), 0o700, "coordinators root")
        for entry in os.scandir(coordinators_root):
            if entry.is_dir(follow_symlinks=False) and not entry.is_symlink():
                if entry.name != "promotion-staging":
                    raise AuthorityError(f"unsafe coordinator directory entry: {entry.name}")
                require_mode(os.stat(entry.path, follow_symlinks=False), 0o700, "promotion staging")
                continue
            if entry.is_symlink() or not entry.is_file(follow_symlinks=False):
                raise AuthorityError(f"unsafe coordinator authority entry: {entry.name}")
            matched = COORDINATOR_FILE_RE.fullmatch(entry.name)
            superseded = SUPERSEDED_FILE_RE.fullmatch(entry.name)
            committed = PROMOTION_COMMIT_RE.fullmatch(entry.name)
            if matched is not None:
                record = scalar_record(
                    entry.path, "coordinator session authority", coordinators_root, 0o600
                )
                if sha256_bytes(base64.b64decode(record["bytes_b64"])) != matched.group(1):
                    raise AuthorityError("coordinator authority filename hash mismatch")
            elif superseded is not None:
                marker, _, _ = read_canonical_json(entry.path, "coordinator supersession")
                exact_keys(
                    marker,
                    {"new_coordinator", "old_coordinator", "request_id", "status"},
                    "coordinator supersession",
                )
                if marker["status"] != "superseded" or not SHA_RE.fullmatch(marker["request_id"]):
                    raise AuthorityError("invalid coordinator supersession")
                strict_text(marker["new_coordinator"], "new coordinator")
                strict_text(marker["old_coordinator"], "old coordinator")
                expected_old = sha256_bytes((marker["old_coordinator"] + "\n").encode("utf-8"))
                if expected_old != superseded.group(1):
                    raise AuthorityError("coordinator supersession filename mismatch")
            elif committed is not None:
                validate_promotion_commit(hub, entry.path, committed.group(1))
            else:
                raise AuthorityError(f"invalid coordinator authority filename: {entry.name}")

    global_carryover = os.path.join(hub, "CARRYOVER.md")
    if os.path.lexists(global_carryover):
        safe_regular(global_carryover, "global carryover", hub, 0o600)

    continuation_root = os.path.join(control_root, "continuations")
    safe_directory(continuation_root, "continuation root", control_root, allow_missing=True)
    if os.path.lexists(continuation_root):
        require_mode(os.lstat(continuation_root), 0o700, "continuation root")
        for child in ("requests", "carryovers"):
            child_path = safe_directory(
                os.path.join(continuation_root, child),
                f"continuation {child}",
                continuation_root,
                allow_missing=True,
            )
            if os.path.lexists(child_path):
                require_mode(os.lstat(child_path), 0o700, f"continuation {child}")

    for mission in direct_directories(missions_root, "missions root"):
        mission_dir = safe_directory(os.path.join(missions_root, mission), "mission", missions_root)
        mission_state = scalar_record(
            os.path.join(mission_dir, "state"), "mission state", mission_dir
        )
        control_mission = os.path.join(control_root, mission)
        safe_directory(control_mission, "control mission", control_root, allow_missing=True)
        if not os.path.lexists(control_mission):
            continue
        mission_planning = scalar_record(
            os.path.join(mission_dir, "planning-backend"),
            "mission planning backend",
            mission_dir,
        )
        control_planning = scalar_record(
            os.path.join(control_mission, "planning-backend"),
            "control planning backend",
            control_mission,
        )
        if (
            mission_planning["value"] not in {"fable-opus", "codex-ultra"}
            or mission_planning["value"] != control_planning["value"]
        ):
            raise AuthorityError("planning backend authority mismatch")
        planning_authority_records(
            mission_dir,
            control_mission,
            mission_planning["value"],
            mission_state["value"],
        )
        mission_lifecycle_records(control_mission)
        tasks_root = os.path.join(control_mission, "tasks")
        safe_directory(tasks_root, "tasks root", control_mission, allow_missing=True)
        if not os.path.lexists(tasks_root):
            continue
        for task in direct_directories(tasks_root, "tasks root"):
            task_dir = safe_directory(os.path.join(tasks_root, task), "task", tasks_root)
            scalar_record(os.path.join(task_dir, "state"), "task state", task_dir)
            generation = scalar_record(os.path.join(task_dir, "generation"), "task generation", task_dir)
            if not generation["value"].isdigit():
                raise AuthorityError("task generation is not numeric")
            accepted_path = os.path.join(task_dir, "accepted-thread-id")
            accepted = (
                scalar_record(accepted_path, "accepted thread", task_dir)
                if os.path.lexists(accepted_path)
                else None
            )
            task_outcome_records(task_dir, task, generation, accepted)
            task_lifecycle_records(task_dir)
    return hub


def build_missions(hub: str) -> list[dict[str, Any]]:
    missions_root = os.path.join(hub, "missions")
    control_root = os.path.join(hub, "control")
    missions: list[dict[str, Any]] = []
    for mission in direct_directories(missions_root, "missions root"):
        mission_dir = os.path.join(missions_root, mission)
        tasks: list[dict[str, Any]] = []
        control_mission = os.path.join(control_root, mission)
        mission_planning = scalar_record(
            os.path.join(mission_dir, "planning-backend"),
            "mission planning backend",
            mission_dir,
        )
        control_planning = scalar_record(
            os.path.join(control_mission, "planning-backend"),
            "control planning backend",
            control_mission,
        )
        if (
            mission_planning["value"] not in {"fable-opus", "codex-ultra"}
            or mission_planning["value"] != control_planning["value"]
        ):
            raise AuthorityError("planning backend authority mismatch")
        mission_state = scalar_record(
            os.path.join(mission_dir, "state"), "mission state", mission_dir
        )
        planning = planning_authority_records(
            mission_dir,
            control_mission,
            mission_planning["value"],
            mission_state["value"],
        )
        lifecycle_files = mission_lifecycle_records(control_mission)
        tasks_root = os.path.join(control_mission, "tasks")
        if os.path.isdir(tasks_root):
            for task in direct_directories(tasks_root, "tasks root"):
                task_dir = os.path.join(tasks_root, task)
                generation = scalar_record(
                    os.path.join(task_dir, "generation"), "task generation", task_dir
                )
                if not generation["value"].isdigit():
                    raise AuthorityError("task generation is not numeric")
                accepted_path = os.path.join(task_dir, "accepted-thread-id")
                accepted = (
                    scalar_record(accepted_path, "accepted thread", task_dir)
                    if os.path.lexists(accepted_path)
                    else None
                )
                outcome = task_outcome_records(task_dir, task, generation, accepted)
                task_lifecycle = task_lifecycle_records(task_dir)
                tasks.append(
                    {
                        "accepted_thread": accepted,
                        "generation": generation,
                        "lifecycle_files": task_lifecycle,
                        **outcome,
                        "path": task_dir,
                        "state": scalar_record(os.path.join(task_dir, "state"), "task state", task_dir),
                        "task": task,
                    }
                )
        missions.append(
            {
                "mission": mission,
                "path": mission_dir,
                "planning_backend": {
                    "control": control_planning,
                    "mission": mission_planning,
                },
                "lifecycle_files": lifecycle_files,
                **planning,
                "state": mission_state,
                "tasks": tasks,
            }
        )
    if not missions:
        raise AuthorityError("no durable mission state")
    return missions


def coordinator_authority(hub: str, session_id: str) -> dict[str, Any]:
    strict_text(session_id, "coordinator session id")
    root = safe_directory(
        os.path.join(hub, "control", "coordinators"),
        "coordinators root",
        os.path.join(hub, "control"),
    )
    expected = sha256_bytes((session_id + "\n").encode("utf-8")) + ".session-id"
    path = os.path.join(root, expected)
    record = scalar_record(path, "coordinator session authority", root, 0o600)
    if record["value"] != session_id:
        raise AuthorityError("coordinator session authority mismatch")
    return record


def mission_is_continuation_eligible(mission: dict[str, Any]) -> bool:
    state = mission["state"]["value"]
    if state in ELIGIBLE_MISSION_STATES:
        return True
    if state != "accepted":
        return False
    parent_state = lifecycle_record_value(
        mission["lifecycle_files"], "parent-cleanup-state", "parent cleanup state"
    )
    if parent_state is not None and parent_state not in {
        "ready", "cleanup_pending", "collected"
    }:
        raise AuthorityError("invalid parent cleanup state")
    if parent_state != "collected":
        return True
    for task in mission["tasks"]:
        if task["state"]["value"] != "collected":
            return True
        window_state = lifecycle_record_value(
            task["lifecycle_files"], "task-window-state", "task window state"
        )
        if window_state != "archived":
            return True
        if any(
            os.path.basename(record["path"]) == "task-window-archive-pending"
            for record in task["lifecycle_files"]
        ):
            return True
    return False


def classify_session(hub: str, session_id: str) -> str:
    hub = preflight_hub(hub)
    strict_text(session_id, "coordinator session id")
    coordinators = os.path.join(hub, "control", "coordinators")
    promotions: dict[str, str] = {}
    promoted_to: dict[str, str] = {}
    for entry in os.scandir(coordinators):
        matched = PROMOTION_COMMIT_RE.fullmatch(entry.name)
        if matched is None:
            continue
        marker = validate_promotion_commit(hub, entry.path, matched.group(1))
        old = marker["old_coordinator"]
        new = marker["new_coordinator"]
        if old in promotions and promotions[old] != new:
            raise AuthorityError("coordinator has conflicting promotion commits")
        if new in promoted_to and promoted_to[new] != old:
            raise AuthorityError("coordinator has conflicting promotion predecessors")
        promotions[old] = new
        promoted_to[new] = old
    if session_id in promotions:
        return "unrelated"
    if session_id in promoted_to:
        missions = build_missions(hub)
        if not any(mission_is_continuation_eligible(mission) for mission in missions):
            return "terminal"
        return "eligible"
    expected = sha256_bytes((session_id + "\n").encode("utf-8")) + ".session-id"
    path = os.path.join(coordinators, expected)
    if not os.path.lexists(path):
        return "unrelated"
    coordinator_authority(hub, session_id)
    missions = build_missions(hub)
    if not any(mission_is_continuation_eligible(mission) for mission in missions):
        return "terminal"
    return "eligible"


def validate_provenance(session_id: str, event: str, trigger: str) -> None:
    strict_text(session_id, "coordinator thread id")
    if (event == "PreCompact" and trigger in {"manual", "auto"}) or (
        event == "manual" and trigger == "unavailable"
    ):
        return
    raise AuthorityError("invalid continuation source event or trigger")


def build_binding(hub: str, session_id: str, carryover: str) -> dict[str, Any]:
    hub = preflight_hub(hub)
    continuation_root = os.path.join(hub, "control", "continuations")
    carryovers_root = safe_directory(
        os.path.join(continuation_root, "carryovers"),
        "continuation carryovers",
        continuation_root,
    )
    carryover = canonical_absolute(carryover, "request carryover")
    if os.path.dirname(carryover) != carryovers_root:
        raise AuthorityError("request carryover is not a direct child of the carryover store")
    missions = build_missions(hub)
    if not any(mission_is_continuation_eligible(mission) for mission in missions):
        raise AuthorityError("no eligible nonterminal mission state")
    source = {
        "authority": coordinator_authority(hub, session_id),
        "coordinator_thread_id": session_id,
    }
    return {
        "carryover": file_record(carryover, "request carryover", carryovers_root, 0o600),
        "hub_path": hub,
        "missions": missions,
        "protocol_version": 2,
        "requested_continuations": 1,
        "source": source,
        "status": "pending",
    }


def wait_test_barrier(environment_key: str) -> None:
    marker = os.environ.get(environment_key)
    if not marker:
        return
    write_exclusive_bytes(marker, b"ready\n")
    deadline = time.monotonic() + 5.0
    while not os.path.isfile(marker + ".release"):
        if time.monotonic() >= deadline:
            raise AuthorityError(f"{environment_key} timed out")
        time.sleep(0.01)


def open_directory_at(
    parent_fd: int, name: str, create: bool, expected_mode: Optional[int] = 0o700
) -> int:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    if create:
        try:
            os.mkdir(name, 0o700, dir_fd=parent_fd)
            os.fsync(parent_fd)
        except FileExistsError:
            pass
    descriptor = os.open(name, flags, dir_fd=parent_fd)
    metadata = os.fstat(descriptor)
    if not stat.S_ISDIR(metadata.st_mode):
        os.close(descriptor)
        raise AuthorityError(f"unsafe store directory: {name}")
    if expected_mode is not None:
        require_mode(metadata, expected_mode, f"store directory {name}")
    return descriptor


def verify_fd_path(descriptor: int, path: str, label: str) -> None:
    metadata = os.lstat(path)
    opened = os.fstat(descriptor)
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise AuthorityError(f"unsafe {label} path")
    if metadata.st_dev != opened.st_dev or metadata.st_ino != opened.st_ino:
        raise AuthorityError(f"{label} path changed during transaction")


def secure_store_fds(hub: str) -> tuple[int, int, int, int]:
    hub = preflight_hub(hub)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    hub_fd = os.open(hub, flags)
    control_fd = open_directory_at(hub_fd, "control", False, None)
    continuation_fd = open_directory_at(control_fd, "continuations", True)
    wait_test_barrier("ORC_CONTINUATION_TEST_STORE_BEFORE_MKDIR_MARKER")
    requests_fd = open_directory_at(continuation_fd, "requests", True)
    carryovers_fd = open_directory_at(continuation_fd, "carryovers", True)
    continuation_path = os.path.join(hub, "control", "continuations")
    verify_fd_path(continuation_fd, continuation_path, "continuation store")
    verify_fd_path(requests_fd, os.path.join(continuation_path, "requests"), "request store")
    verify_fd_path(carryovers_fd, os.path.join(continuation_path, "carryovers"), "carryover store")
    os.close(hub_fd)
    return control_fd, continuation_fd, requests_fd, carryovers_fd


def read_fd_all(descriptor: int, limit: int = 1_048_576) -> bytes:
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = os.read(descriptor, min(65536, limit + 1 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        if total > limit:
            raise AuthorityError("authority file is oversized")
    return b"".join(chunks)


def parse_lock_authority(path: str, request_id: str, expected_host: str) -> dict[str, Any]:
    data, metadata = safe_regular(path, "protocol lock", expected_mode=0o600)
    if not data.endswith(b"\n") or data.count(b"\n") != 1:
        raise AuthorityError("protocol lock is not strict one-line authority")
    try:
        fields = data[:-1].decode("utf-8").split("\t")
    except UnicodeDecodeError as error:
        raise AuthorityError("protocol lock is not UTF-8") from error
    if len(fields) != 4:
        raise AuthorityError("protocol lock field count is invalid")
    pid_text, host, token, recorded_request = fields
    if not pid_text.isdigit() or int(pid_text) <= 0:
        raise AuthorityError("protocol lock pid is invalid")
    if host != expected_host or recorded_request != request_id or not SHA_RE.fullmatch(token):
        raise AuthorityError("protocol lock identity is invalid or remote")
    pid = int(pid_text)
    try:
        os.kill(pid, 0)
        dead = False
    except ProcessLookupError:
        dead = True
    except PermissionError:
        dead = False
    return {
        "bytes_b64": base64.b64encode(data).decode("ascii"),
        "dead": dead,
        "device": metadata.st_dev,
        "host": host,
        "inode": metadata.st_ino,
        "path": path,
        "pid": pid,
        "request_id": request_id,
        "sha256": sha256_bytes(data),
        "size": metadata.st_size,
        "token": token,
    }


def read_leaf_at(directory_fd: int, name: str, label: str) -> tuple[bytes, os.stat_result]:
    descriptor = os.open(
        name,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_fd,
    )
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise AuthorityError(f"unsafe {label}")
        require_mode(before, 0o600, label)
        data = read_fd_all(descriptor)
        after = os.fstat(descriptor)
        if (
            before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
        ):
            raise AuthorityError(f"{label} changed during read")
        return data, after
    finally:
        os.close(descriptor)


def lock_epoch_matches(data: bytes, metadata: os.stat_result, expected: dict[str, Any]) -> bool:
    return (
        metadata.st_dev == expected["device"]
        and metadata.st_ino == expected["inode"]
        and metadata.st_size == expected["size"]
        and sha256_bytes(data) == expected["sha256"]
        and base64.b64encode(data).decode("ascii") == expected["bytes_b64"]
    )


def recover_protocol_lock(path: str, expected_json: str) -> None:
    try:
        expected = json.loads(expected_json, object_pairs_hook=reject_duplicates)
    except json.JSONDecodeError as error:
        raise AuthorityError("invalid expected lock epoch") from error
    exact_keys(
        expected,
        {
            "bytes_b64",
            "dead",
            "device",
            "host",
            "inode",
            "path",
            "pid",
            "request_id",
            "sha256",
            "size",
            "token",
        },
        "expected lock epoch",
    )
    if expected["path"] != path or expected["dead"] is not True:
        raise AuthorityError("lock epoch is not the exact dead owner")
    parent = os.path.dirname(lexical_absolute(path, "protocol lock path"))
    leaf = os.path.basename(path)
    parent_fd = open_absolute_directory(parent, "protocol lock parent")
    guard = ".stale-lock-guard." + secrets.token_hex(16)
    guard_created = False
    try:
        wait_test_barrier("ORC_CONTINUATION_TEST_LOCK_GUARD_MARKER")
        os.link(
            leaf,
            guard,
            src_dir_fd=parent_fd,
            dst_dir_fd=parent_fd,
            follow_symlinks=False,
        )
        guard_created = True
        guard_data, guard_metadata = read_leaf_at(parent_fd, guard, "protocol lock guard")
        if not lock_epoch_matches(guard_data, guard_metadata, expected):
            raise LockChangedError("guard does not match validated stale lock epoch")
        current_data, current_metadata = read_leaf_at(parent_fd, leaf, "current protocol lock")
        if not lock_epoch_matches(current_data, current_metadata, expected):
            raise LockChangedError("current lock no longer matches validated stale epoch")
        final_metadata = os.stat(leaf, dir_fd=parent_fd, follow_symlinks=False)
        if (
            final_metadata.st_dev != expected["device"]
            or final_metadata.st_ino != expected["inode"]
            or final_metadata.st_size != expected["size"]
        ):
            raise LockChangedError("lock path changed before unlink")
        os.unlink(leaf, dir_fd=parent_fd)
        os.fsync(parent_fd)
    finally:
        if guard_created:
            try:
                os.unlink(guard, dir_fd=parent_fd)
                os.fsync(parent_fd)
            except FileNotFoundError:
                pass
        os.close(parent_fd)


def publish_private_at(directory_fd: int, name: str, data: bytes) -> os.stat_result:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(name, flags, 0o600, dir_fd=directory_fd)
    except FileExistsError:
        descriptor = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_fd,
        )
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                raise AuthorityError(f"unsafe existing authority: {name}")
            require_mode(metadata, 0o600, name)
            if read_fd_all(descriptor) != data:
                raise AuthorityError(f"conflicting existing authority: {name}")
            return metadata
        finally:
            os.close(descriptor)
    try:
        written = 0
        while written < len(data):
            count = os.write(descriptor, data[written:])
            if count <= 0:
                raise AuthorityError("short authority write")
            written += count
        os.fsync(descriptor)
        metadata = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    os.fsync(directory_fd)
    return metadata


def carryover_bytes(session_id: str, snapshot: dict[str, Any]) -> bytes:
    snapshot_sha = sha256_bytes(canonical_bytes(snapshot))
    lines = [
        "# Orchestrator Codex carryover",
        "",
        f"- Source coordinator task: `{session_id}`",
        f"- Durable state SHA-256: `{snapshot_sha}`",
        "- Boundary: supported Codex compaction lifecycle; exact automatic context percentage is unavailable.",
        "",
        "## Durable mission and task snapshot",
        "",
        "```text",
    ]
    for mission in snapshot["missions"]:
        lines.append(f"mission\t{mission['mission']}\t{mission['state']['value']}")
        lines.append(
            f"planning-backend\t{mission['mission']}\t"
            f"{mission['planning_backend']['control']['value']}\t"
            f"{mission['planning_thread']['value'] if mission['planning_thread'] else ''}"
        )
        for record in mission["lifecycle_files"]:
            name = os.path.basename(record["path"])
            if "intent" in name.lower() or name == "planning-stage-authority.json":
                lines.append(
                    f"active-intent\t{mission['mission']}\tmission\t"
                    f"{record['path']}\t{record['sha256']}"
                )
        for task in mission["tasks"]:
            accepted = task["accepted_thread"]["value"] if task["accepted_thread"] else ""
            nonce = task["outcome_nonce"]["value"] if task["outcome_nonce"] else ""
            latest = task["latest_outcome"]["value"] if task["latest_outcome"] else ""
            intent = (
                validate_outcome_intent(task["outcome_intent"])
                if task["outcome_intent"]
                else None
            )
            lines.append(
                "\t".join(
                    (
                        "task",
                        mission["mission"],
                        task["task"],
                        task["generation"]["value"],
                        task["state"]["value"],
                        accepted,
                        nonce,
                        latest,
                        intent["digest"] if intent else "",
                        intent["turn_id"] if intent else "",
                    )
                )
            )
            for record in task["lifecycle_files"]:
                name = os.path.basename(record["path"])
                if "intent" in name.lower() or name.endswith("pending"):
                    lines.append(
                        f"active-intent\t{mission['mission']}\t{task['task']}\t"
                        f"{record['path']}\t{record['sha256']}"
                    )
    lines.extend(
        (
            "```",
            "",
            "## Before creating the fresh coordinator task",
            "",
            "Append any still-relevant knowledge already represented by this exact durable snapshot; if authority changes, retire this request and record a new one.",
            "",
        )
    )
    return "\n".join(lines).encode("utf-8")


def snapshot_request(hub: str, session_id: str, event: str, trigger: str) -> dict[str, str]:
    validate_provenance(session_id, event, trigger)
    hub = preflight_hub(hub)
    classification = classify_session(hub, session_id)
    if classification != "eligible":
        raise AuthorityError("session is not an eligible exact coordinator")
    control_fd = continuation_fd = requests_fd = carryovers_fd = -1
    try:
        control_fd, continuation_fd, requests_fd, carryovers_fd = secure_store_fds(hub)
        snapshot = {
            "coordinator_authority": coordinator_authority(hub, session_id),
            "missions": build_missions(hub),
        }
        wait_test_barrier("ORC_CONTINUATION_TEST_SNAPSHOT_READ_MARKER")
        fresh = {
            "coordinator_authority": coordinator_authority(hub, session_id),
            "missions": build_missions(hub),
        }
        if canonical_bytes(fresh) != canonical_bytes(snapshot):
            raise AuthorityError("coordinator authority changed during snapshot")
        if os.environ.get("ORC_CONTINUATION_TEST_FAIL_DURABILITY") == "1":
            raise AuthorityError("injected continuation durability failure")
        rendered_carryover = carryover_bytes(session_id, snapshot)
        carryover_sha = sha256_bytes(rendered_carryover)
        carryover_name = carryover_sha + ".md"
        carryover_metadata = publish_private_at(carryovers_fd, carryover_name, rendered_carryover)
        carryover_path = os.path.join(hub, "control", "continuations", "carryovers", carryover_name)
        carryover_record = {
            "bytes_b64": base64.b64encode(rendered_carryover).decode("ascii"),
            "device": carryover_metadata.st_dev,
            "inode": carryover_metadata.st_ino,
            "path": carryover_path,
            "sha256": carryover_sha,
            "size": carryover_metadata.st_size,
        }
        binding = {
            "carryover": carryover_record,
            "hub_path": hub,
            "missions": snapshot["missions"],
            "protocol_version": 2,
            "requested_continuations": 1,
            "source": {
                "authority": snapshot["coordinator_authority"],
                "coordinator_thread_id": session_id,
            },
            "status": "pending",
        }
        request_id = sha256_bytes(canonical_bytes(binding))
        request = {"binding": binding, "binding_sha256": request_id, "request_id": request_id}
        request_bytes = canonical_bytes(request, newline=True)
        request_name = request_id + ".json"
        request_metadata = publish_private_at(requests_fd, request_name, request_bytes)
        request_path = os.path.join(hub, "control", "continuations", "requests", request_name)
        receipt = {
            "protocol_version": 1,
            "request_device": request_metadata.st_dev,
            "request_id": request_id,
            "request_inode": request_metadata.st_ino,
            "request_path": request_path,
            "request_sha256": sha256_bytes(request_bytes),
            "request_size": request_metadata.st_size,
        }
        publish_private_at(
            requests_fd,
            request_id + ".binding.json",
            canonical_bytes(receipt, newline=True),
        )
        verify_fd_path(
            continuation_fd,
            os.path.join(hub, "control", "continuations"),
            "continuation store",
        )
        return {
            "carryover_path": carryover_path,
            "request_id": request_id,
            "request_path": request_path,
        }
    finally:
        for descriptor in (carryovers_fd, requests_fd, continuation_fd, control_fd):
            if descriptor >= 0:
                os.close(descriptor)


def stage_promotion_authority(hub: str, request_id: str, new_session: str) -> str:
    hub = preflight_hub(hub)
    if not SHA_RE.fullmatch(request_id):
        raise AuthorityError("invalid promotion request id")
    strict_text(new_session, "new coordinator session")
    coordinators = os.path.join(hub, "control", "coordinators")
    coordinator_fd = open_absolute_directory(coordinators, "coordinator store")
    staging_fd = -1
    try:
        staging_fd = open_directory_at(coordinator_fd, "promotion-staging", True)
        name = request_id + ".session-id"
        publish_private_at(staging_fd, name, (new_session + "\n").encode("utf-8"))
        path = os.path.join(coordinators, "promotion-staging", name)
        verify_fd_path(
            staging_fd,
            os.path.join(coordinators, "promotion-staging"),
            "promotion staging",
        )
        return path
    finally:
        if staging_fd >= 0:
            os.close(staging_fd)
        os.close(coordinator_fd)
def write_exclusive(path: str, value: Any) -> None:
    data = canonical_bytes(value, newline=True)
    write_exclusive_bytes(path, data)


def write_exclusive_bytes(path: str, data: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        written = 0
        while written < len(data):
            count = os.write(descriptor, data[written:])
            if count <= 0:
                raise AuthorityError("short authority write")
            written += count
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise AuthorityError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_canonical_json(path: str, label: str) -> tuple[dict[str, Any], bytes, os.stat_result]:
    data, metadata = safe_regular(path, label, expected_mode=0o600)
    if not data.endswith(b"\n") or data.count(b"\n") != 1:
        raise AuthorityError(f"{label} is not canonical one-line JSON")
    try:
        value = json.loads(data, object_pairs_hook=reject_duplicates)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise AuthorityError(f"invalid {label} JSON") from error
    if not isinstance(value, dict) or canonical_bytes(value, newline=True) != data:
        raise AuthorityError(f"noncanonical {label} JSON")
    return value, data, metadata


def validate_file_shape(value: Any, scalar: bool, label: str) -> None:
    exact_keys(value, SCALAR_KEYS if scalar else FILE_KEYS, label)
    strict_text(value["path"], f"{label} path")
    if not SHA_RE.fullmatch(value["sha256"]):
        raise AuthorityError(f"invalid {label} hash")
    for key in ("device", "inode", "size"):
        if type(value[key]) is not int or value[key] < 0:
            raise AuthorityError(f"invalid {label} {key}")
    if not isinstance(value["bytes_b64"], str):
        raise AuthorityError(f"invalid {label} bytes")
    try:
        decoded = base64.b64decode(value["bytes_b64"], validate=True)
    except ValueError as error:
        raise AuthorityError(f"invalid {label} base64") from error
    if len(decoded) != value["size"] or sha256_bytes(decoded) != value["sha256"]:
        raise AuthorityError(f"self-inconsistent {label} bytes")
    if scalar:
        strict_text(value["value"], f"{label} value")
        if decoded != (value["value"] + "\n").encode("utf-8"):
            raise AuthorityError(f"self-inconsistent {label} scalar")


def validate_promotion_commit(hub: str, path: str, request_id: str) -> dict[str, Any]:
    marker, _, _ = read_canonical_json(path, "promotion commit marker")
    exact_keys(
        marker,
        {
            "accepted_receipt",
            "new_coordinator",
            "old_authority",
            "old_coordinator",
            "request",
            "request_binding_receipt",
            "request_id",
            "staged_authority",
            "status",
        },
        "promotion commit marker",
    )
    if marker["status"] != "committed" or marker["request_id"] != request_id:
        raise AuthorityError("promotion commit identity mismatch")
    old_session = strict_text(marker["old_coordinator"], "old coordinator")
    new_session = strict_text(marker["new_coordinator"], "new coordinator")
    coordinators = os.path.join(hub, "control", "coordinators")
    staging = os.path.join(coordinators, "promotion-staging")
    requests = os.path.join(hub, "control", "continuations", "requests")
    for key, scalar, parent in (
        ("old_authority", True, coordinators),
        ("staged_authority", True, staging),
        ("request", False, requests),
        ("request_binding_receipt", False, requests),
        ("accepted_receipt", False, requests),
    ):
        validate_file_shape(marker[key], scalar, key)
        current = (
            scalar_record(marker[key]["path"], key, parent, 0o600)
            if scalar
            else file_record(marker[key]["path"], key, parent, 0o600)
        )
        if canonical_bytes(current) != canonical_bytes(marker[key]):
            raise AuthorityError(f"promotion commit {key} epoch mismatch")
    if marker["old_authority"]["value"] != old_session:
        raise AuthorityError("promotion old authority mismatch")
    if marker["staged_authority"]["value"] != new_session:
        raise AuthorityError("promotion staged authority mismatch")
    if os.path.basename(marker["staged_authority"]["path"]) != request_id + ".session-id":
        raise AuthorityError("promotion staged authority filename mismatch")
    request = json.loads(base64.b64decode(marker["request"]["bytes_b64"]))
    accepted = json.loads(base64.b64decode(marker["accepted_receipt"]["bytes_b64"]))
    if request.get("request_id") != request_id or request.get("binding_sha256") != request_id:
        raise AuthorityError("promotion request binding mismatch")
    if accepted.get("request_id") != request_id or accepted.get("thread_id") != new_session:
        raise AuthorityError("promotion accepted thread mismatch")
    return marker


def build_promotion_commit(
    hub: str,
    request_id: str,
    old_session: str,
    new_session: str,
    staged_authority: str,
) -> dict[str, Any]:
    hub = preflight_hub(hub)
    requests = os.path.join(hub, "control", "continuations", "requests")
    coordinators = os.path.join(hub, "control", "coordinators")
    staging = os.path.join(coordinators, "promotion-staging")
    request_path = os.path.join(requests, request_id + ".json")
    receipt_path = os.path.join(requests, request_id + ".binding.json")
    accepted_path = os.path.join(requests, request_id + ".accepted.json")
    request = validate_request(
        hub, request_id, request_path, receipt_path, old_session
    )
    validate_record("accepted", accepted_path, request_id, new_session, request_id)
    old_hash = sha256_bytes((old_session + "\n").encode("utf-8"))
    old_authority_path = os.path.join(coordinators, old_hash + ".session-id")
    old_authority = scalar_record(
        old_authority_path, "old coordinator authority", coordinators, 0o600
    )
    staged = scalar_record(staged_authority, "staged coordinator authority", staging, 0o600)
    if old_authority["value"] != old_session or staged["value"] != new_session:
        raise AuthorityError("promotion coordinator authority mismatch")
    if request["binding_sha256"] != request_id:
        raise AuthorityError("promotion request digest mismatch")
    return {
        "accepted_receipt": file_record(
            accepted_path, "accepted promotion receipt", requests, 0o600
        ),
        "new_coordinator": new_session,
        "old_authority": old_authority,
        "old_coordinator": old_session,
        "request": file_record(request_path, "promotion request", requests, 0o600),
        "request_binding_receipt": file_record(
            receipt_path, "promotion request binding receipt", requests, 0o600
        ),
        "request_id": request_id,
        "staged_authority": staged,
        "status": "committed",
    }


def validate_binding_shape(binding: Any) -> None:
    exact_keys(binding, BINDING_KEYS, "binding")
    if binding["protocol_version"] != 2 or binding["requested_continuations"] != 1:
        raise AuthorityError("invalid binding protocol")
    if binding["status"] != "pending":
        raise AuthorityError("invalid binding status")
    strict_text(binding["hub_path"], "binding hub")
    source = exact_keys(
        binding["source"],
        {"authority", "coordinator_thread_id"},
        "source",
    )
    strict_text(source["coordinator_thread_id"], "coordinator thread id")
    validate_file_shape(source["authority"], True, "coordinator authority")
    validate_file_shape(binding["carryover"], False, "carryover")
    if not isinstance(binding["missions"], list) or not binding["missions"]:
        raise AuthorityError("invalid missions")
    mission_names: list[str] = []
    for mission in binding["missions"]:
        exact_keys(
            mission,
            {
                "lifecycle_files", "mission", "path", "planning_backend", "planning_health",
                "planning_session", "planning_thread", "quota_fallbacks",
                "session", "state", "tasks",
            },
            "mission",
        )
        mission_names.append(strict_text(mission["mission"], "mission id"))
        mission_path = strict_text(mission["path"], "mission path")
        validate_file_shape(mission["state"], True, "mission state")
        control_mission = os.path.join(
            os.path.dirname(os.path.dirname(mission_path)),
            "control",
            mission["mission"],
        )
        validate_lifecycle_bundle(
            mission["lifecycle_files"],
            "mission lifecycle",
            lambda path, _records: mission_lifecycle_path_allowed(control_mission, path),
        )
        planning = exact_keys(
            mission["planning_backend"],
            {"control", "mission"},
            "planning backend",
        )
        validate_file_shape(planning["mission"], True, "mission planning backend")
        validate_file_shape(planning["control"], True, "control planning backend")
        if (
            planning["mission"]["value"] not in {"fable-opus", "codex-ultra"}
            or planning["mission"]["value"] != planning["control"]["value"]
        ):
            raise AuthorityError("invalid planning backend authority")
        if (mission["planning_thread"] is None) != (mission["planning_health"] is None):
            raise AuthorityError("partial planning-thread binding")
        if mission["planning_thread"] is not None:
            validate_file_shape(mission["planning_thread"], True, "planning thread")
            validate_file_shape(mission["planning_health"], False, "planning health")
        if planning["mission"]["value"] == "fable-opus" and mission["planning_thread"] is not None:
            raise AuthorityError("Fable/Opus binding has Codex planning-thread authority")
        if mission["session"] is not None:
            validate_file_shape(mission["session"], False, "planning session")
        if mission["planning_session"] is not None:
            validate_file_shape(mission["planning_session"], True, "planning session id")
        fallbacks = exact_keys(
            mission["quota_fallbacks"], {"plan", "review"}, "quota fallbacks"
        )
        for stage, receipt in fallbacks.items():
            if receipt is not None:
                validate_file_shape(receipt, False, f"{stage} quota fallback")
        backend = planning["mission"]["value"]
        state = mission["state"]["value"]
        if backend == "fable-opus":
            if (mission["session"] is None) != (mission["planning_session"] is None):
                raise AuthorityError("partial Fable/Opus planning session binding")
            if state != "pending" and mission["session"] is None:
                raise AuthorityError("active Fable/Opus binding lacks planning session")
            if mission["session"] is None:
                if any(receipt is not None for receipt in fallbacks.values()):
                    raise AuthorityError("quota fallback binding lacks planning session")
            else:
                values = planning_session_values(
                    mission["session"], "bound Fable/Opus planning session"
                )
                session_id = one_planning_value(
                    values, "session_id", "bound Fable/Opus planning session"
                )
                if mission["planning_session"]["value"] != session_id:
                    raise AuthorityError("bound Fable/Opus planning session mismatch")
                if one_planning_value(
                    values, "backend", "bound Fable/Opus planning session"
                ) != "claude-headless":
                    raise AuthorityError("invalid bound Fable/Opus backend")
                if one_planning_value(
                    values, "model", "bound Fable/Opus planning session"
                ) != "claude-fable-5":
                    raise AuthorityError("invalid bound Fable/Opus model")
                for stage, receipt in fallbacks.items():
                    if receipt is not None:
                        validate_quota_receipt(receipt, stage, session_id)
        else:
            if mission["planning_session"] is not None or any(
                receipt is not None for receipt in fallbacks.values()
            ):
                raise AuthorityError("Codex Ultra binding has Claude planning authority")
            present = (
                mission["session"] is not None,
                mission["planning_thread"] is not None,
                mission["planning_health"] is not None,
            )
            if any(present) and not all(present):
                raise AuthorityError("partial Codex Ultra planning binding")
            if state != "pending" and not all(present):
                raise AuthorityError("active Codex Ultra binding lacks planning task")
            if all(present):
                values = planning_session_values(
                    mission["session"], "bound Codex Ultra planning session"
                )
                thread_id = one_planning_value(
                    values, "thread_id", "bound Codex Ultra planning session"
                )
                if (
                    one_planning_value(values, "backend", "bound Codex Ultra planning session")
                    != "codex-native"
                    or one_planning_value(values, "model", "bound Codex Ultra planning session")
                    != "gpt-5.6-sol"
                    or one_planning_value(values, "effort", "bound Codex Ultra planning session")
                    != "ultra"
                    or one_planning_value(values, "stage", "bound Codex Ultra planning session")
                    not in {"plan", "review"}
                    or mission["planning_thread"]["value"] != thread_id
                ):
                    raise AuthorityError("invalid bound Codex Ultra planning session")
                validate_codex_health(mission["planning_health"], thread_id)
        if not isinstance(mission["tasks"], list):
            raise AuthorityError("invalid task list")
        task_names: list[str] = []
        for task in mission["tasks"]:
            exact_keys(
                task,
                {
                    "accepted_thread", "generation", "latest_outcome",
                    "latest_outcome_event", "lifecycle_files", "outcome_intent", "outcome_nonce",
                    "path", "state", "task",
                },
                "task",
            )
            task_names.append(strict_text(task["task"], "task id"))
            task_path = strict_text(task["path"], "task path")
            validate_file_shape(task["generation"], True, "task generation")
            if not task["generation"]["value"].isdigit():
                raise AuthorityError("non-numeric task generation")
            validate_file_shape(task["state"], True, "task state")
            validate_lifecycle_bundle(
                task["lifecycle_files"],
                "task lifecycle",
                lambda path, records, task_path=task_path: task_lifecycle_path_allowed(
                    task_path, path, records
                ),
            )
            validate_bound_task_outcome(task)
        if task_names != sorted(task_names) or len(set(task_names)) != len(task_names):
            raise AuthorityError("noncanonical task ordering")
    if mission_names != sorted(mission_names) or len(set(mission_names)) != len(mission_names):
        raise AuthorityError("noncanonical mission ordering")


def validate_request(
    hub: str,
    request_id: str,
    request_file: str,
    receipt_file: str,
    expected_session: Optional[str] = None,
) -> dict[str, Any]:
    if not SHA_RE.fullmatch(request_id):
        raise AuthorityError("invalid request id")
    request, request_bytes, request_metadata = read_canonical_json(request_file, "request")
    exact_keys(request, REQUEST_KEYS, "request")
    if request["request_id"] != request_id or request["binding_sha256"] != request_id:
        raise AuthorityError("request id does not match wrapper")
    validate_binding_shape(request["binding"])
    digest = sha256_bytes(canonical_bytes(request["binding"]))
    if digest != request_id:
        raise AuthorityError("request binding digest mismatch")
    expected_name = request_id + ".json"
    if os.path.basename(request_file) != expected_name:
        raise AuthorityError("request filename mismatch")
    source = request["binding"]["source"]
    if expected_session is not None and source["coordinator_thread_id"] != expected_session:
        raise AuthorityError("request coordinator session mismatch")
    fresh = build_binding(
        hub,
        source["coordinator_thread_id"],
        request["binding"]["carryover"]["path"],
    )
    if canonical_bytes(fresh) != canonical_bytes(request["binding"]):
        raise AuthorityError("request differs from current canonical hub authority")

    receipt, receipt_bytes, _ = read_canonical_json(receipt_file, "binding receipt")
    exact_keys(
        receipt,
        {
            "protocol_version",
            "request_device",
            "request_id",
            "request_inode",
            "request_path",
            "request_sha256",
            "request_size",
        },
        "binding receipt",
    )
    if receipt["protocol_version"] != 1 or receipt["request_id"] != request_id:
        raise AuthorityError("binding receipt identity mismatch")
    if receipt["request_path"] != request_file:
        raise AuthorityError("binding receipt path mismatch")
    if receipt["request_sha256"] != sha256_bytes(request_bytes):
        raise AuthorityError("binding receipt content mismatch")
    if (
        receipt["request_device"] != request_metadata.st_dev
        or receipt["request_inode"] != request_metadata.st_ino
        or receipt["request_size"] != request_metadata.st_size
    ):
        raise AuthorityError("binding receipt epoch mismatch")
    if not receipt_bytes:
        raise AuthorityError("empty binding receipt")
    return request


def build_receipt(request_file: str, request_id: str) -> dict[str, Any]:
    request, request_bytes, metadata = read_canonical_json(request_file, "request")
    if request.get("request_id") != request_id:
        raise AuthorityError("request identity mismatch while building receipt")
    return {
        "protocol_version": 1,
        "request_device": metadata.st_dev,
        "request_id": request_id,
        "request_inode": metadata.st_ino,
        "request_path": request_file,
        "request_sha256": sha256_bytes(request_bytes),
        "request_size": metadata.st_size,
    }


def validate_health_value(health: dict[str, Any], request_id: str, thread_id: str, digest: str) -> None:
    expected = {
        "binding_sha256",
        "created",
        "first_turn_exists",
        "request_id",
        "settings_recorded",
        "startup_evidence",
        "state_sha256",
        "status",
        "thread_id",
        "title_verified",
        "visible",
    }
    exact_keys(health, expected, "health evidence")
    if (
        health["request_id"] != request_id
        or health["thread_id"] != thread_id
        or health["binding_sha256"] != digest
        or health["state_sha256"] != digest
        or health["status"] not in {"inProgress", "completed"}
    ):
        raise AuthorityError("health evidence identity or status mismatch")
    for key in (
        "created",
        "first_turn_exists",
        "settings_recorded",
        "startup_evidence",
        "title_verified",
        "visible",
    ):
        if health[key] is not True:
            raise AuthorityError(f"health evidence missing {key}")


def snapshot_health(path: str, output: str, request_id: str, thread_id: str, digest: str) -> str:
    health, data, _ = read_canonical_json(path, "health evidence")
    validate_health_value(health, request_id, thread_id, digest)
    marker = os.environ.get("ORC_CONTINUATION_TEST_HEALTH_READ_MARKER")
    if marker:
        write_exclusive_bytes(marker, b"health-read\n")
        deadline = time.monotonic() + 5.0
        while not os.path.isfile(marker + ".release"):
            if time.monotonic() >= deadline:
                raise AuthorityError("health read test barrier timed out")
            time.sleep(0.01)
    write_exclusive_bytes(output, data)
    return sha256_bytes(data)


def validate_record(
    kind: str,
    path: str,
    request_id: str,
    thread_id: Optional[str],
    binding_sha256: str,
) -> dict[str, Any]:
    value, _, _ = read_canonical_json(path, f"{kind} record")
    if kind == "attempt":
        exact_keys(
            value,
            {"attempt", "binding_sha256", "request_id", "status", "thread_id"},
            "attempt record",
        )
        if value["status"] != "provisional":
            raise AuthorityError("invalid attempt status")
    elif kind == "failed":
        exact_keys(
            value,
            {"attempt", "binding_sha256", "reason", "request_id", "status", "thread_id"},
            "failed record",
        )
        strict_text(value["reason"], "failure reason")
        if value["status"] != "failed":
            raise AuthorityError("invalid failed status")
    elif kind == "accepted":
        exact_keys(
            value,
            {
                "attempt",
                "binding_sha256",
                "health_evidence_device",
                "health_evidence_inode",
                "health_evidence_path",
                "health_evidence_sha256",
                "health_evidence_size",
                "health_verified",
                "request_binding_receipt_sha256",
                "request_id",
                "status",
                "thread_id",
            },
            "accepted record",
        )
        if value["status"] != "accepted" or value["health_verified"] is not True:
            raise AuthorityError("invalid accepted status")
        record_store = os.path.dirname(canonical_absolute(path, "accepted record path"))
        expected_health = os.path.join(
            record_store, f"{request_id}.attempt-{value['attempt']}.health.json"
        )
        if value["health_evidence_path"] != expected_health:
            raise AuthorityError("accepted health copy path mismatch")
        health_value, health_data, health_metadata = read_canonical_json(
            value["health_evidence_path"], "accepted health copy"
        )
        validate_health_value(health_value, request_id, value["thread_id"], binding_sha256)
        if (
            sha256_bytes(health_data) != value["health_evidence_sha256"]
            or health_metadata.st_dev != value["health_evidence_device"]
            or health_metadata.st_ino != value["health_evidence_inode"]
            or health_metadata.st_size != value["health_evidence_size"]
        ):
            raise AuthorityError("accepted health copy binding mismatch")
        if not SHA_RE.fullmatch(value["request_binding_receipt_sha256"]):
            raise AuthorityError("invalid request binding receipt hash")
        binding_receipt = os.path.join(record_store, f"{request_id}.binding.json")
        binding_bytes, _ = safe_regular(binding_receipt, "request binding receipt", record_store)
        if sha256_bytes(binding_bytes) != value["request_binding_receipt_sha256"]:
            raise AuthorityError("request binding receipt hash drift")
    else:
        raise AuthorityError("unknown record kind")
    if type(value["attempt"]) is not int or value["attempt"] not in {1, 2}:
        raise AuthorityError("invalid attempt number")
    if value["request_id"] != request_id or value["binding_sha256"] != binding_sha256:
        raise AuthorityError("record request binding mismatch")
    strict_text(value["thread_id"], "record thread id")
    if thread_id is not None and value["thread_id"] != thread_id:
        raise AuthorityError("record thread mismatch")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    preflight = subparsers.add_parser("preflight")
    preflight.add_argument("--hub", required=True)

    classify = subparsers.add_parser("classify")
    classify.add_argument("--hub", required=True)
    classify.add_argument("--session-id", required=True)

    build = subparsers.add_parser("build")
    build.add_argument("--hub", required=True)
    build.add_argument("--session-id", required=True)
    build.add_argument("--event", required=True)
    build.add_argument("--trigger", required=True)
    build.add_argument("--carryover", required=True)
    build.add_argument("--output", required=True)

    snapshot = subparsers.add_parser("snapshot-request")
    snapshot.add_argument("--hub", required=True)
    snapshot.add_argument("--session-id", required=True)
    snapshot.add_argument("--event", required=True)
    snapshot.add_argument("--trigger", required=True)

    promotion_commit = subparsers.add_parser("promotion-commit")
    promotion_commit.add_argument("--hub", required=True)
    promotion_commit.add_argument("--request-id", required=True)
    promotion_commit.add_argument("--old-session", required=True)
    promotion_commit.add_argument("--new-session", required=True)
    promotion_commit.add_argument("--staged-authority", required=True)
    promotion_commit.add_argument("--output", required=True)

    promotion_stage = subparsers.add_parser("promotion-stage")
    promotion_stage.add_argument("--hub", required=True)
    promotion_stage.add_argument("--request-id", required=True)
    promotion_stage.add_argument("--new-session", required=True)

    receipt = subparsers.add_parser("receipt")
    receipt.add_argument("--request-file", required=True)
    receipt.add_argument("--request-id", required=True)
    receipt.add_argument("--output", required=True)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--hub", required=True)
    validate.add_argument("--request-file", required=True)
    validate.add_argument("--receipt-file", required=True)
    validate.add_argument("--request-id", required=True)
    validate.add_argument("--expected-session")

    health = subparsers.add_parser("health")
    health.add_argument("--path", required=True)
    health.add_argument("--request-id", required=True)
    health.add_argument("--thread-id", required=True)
    health.add_argument("--binding-sha256", required=True)

    health_copy = subparsers.add_parser("health-copy")
    health_copy.add_argument("--path", required=True)
    health_copy.add_argument("--output", required=True)
    health_copy.add_argument("--request-id", required=True)
    health_copy.add_argument("--thread-id", required=True)
    health_copy.add_argument("--binding-sha256", required=True)

    raw = subparsers.add_parser("raw")
    raw.add_argument("--path", required=True)

    file_sha = subparsers.add_parser("file-sha")
    file_sha.add_argument("--path", required=True)

    compare = subparsers.add_parser("compare")
    compare.add_argument("--left", required=True)
    compare.add_argument("--right", required=True)

    lock_status = subparsers.add_parser("lock-status")
    lock_status.add_argument("--path", required=True)
    lock_status.add_argument("--request-id", required=True)
    lock_status.add_argument("--host", required=True)

    recover_lock = subparsers.add_parser("recover-lock")
    recover_lock.add_argument("--path", required=True)
    recover_lock.add_argument("--expected", required=True)

    record = subparsers.add_parser("record")
    record.add_argument("--kind", choices=("attempt", "failed", "accepted"), required=True)
    record.add_argument("--path", required=True)
    record.add_argument("--request-id", required=True)
    record.add_argument("--thread-id")
    record.add_argument("--binding-sha256", required=True)

    arguments = parser.parse_args()
    if arguments.command == "preflight":
        print(preflight_hub(arguments.hub))
    elif arguments.command == "classify":
        print(classify_session(arguments.hub, arguments.session_id))
    elif arguments.command == "build":
        validate_provenance(
            arguments.session_id,
            arguments.event,
            arguments.trigger,
        )
        binding = build_binding(
            arguments.hub,
            arguments.session_id,
            arguments.carryover,
        )
        digest = sha256_bytes(canonical_bytes(binding))
        wrapper = {"binding": binding, "binding_sha256": digest, "request_id": digest}
        write_exclusive(arguments.output, wrapper)
        print(digest)
    elif arguments.command == "snapshot-request":
        print(
            canonical_bytes(
                snapshot_request(
                    arguments.hub,
                    arguments.session_id,
                    arguments.event,
                    arguments.trigger,
                ),
                newline=True,
            ).decode("utf-8"),
            end="",
        )
    elif arguments.command == "promotion-commit":
        write_exclusive(
            arguments.output,
            build_promotion_commit(
                arguments.hub,
                arguments.request_id,
                arguments.old_session,
                arguments.new_session,
                arguments.staged_authority,
            ),
        )
    elif arguments.command == "promotion-stage":
        print(
            stage_promotion_authority(
                arguments.hub, arguments.request_id, arguments.new_session
            )
        )
    elif arguments.command == "receipt":
        write_exclusive(
            arguments.output,
            build_receipt(arguments.request_file, arguments.request_id),
        )
    elif arguments.command == "validate":
        request = validate_request(
            arguments.hub,
            arguments.request_id,
            arguments.request_file,
            arguments.receipt_file,
            arguments.expected_session,
        )
        print(canonical_bytes(request, newline=True).decode("utf-8"), end="")
    elif arguments.command == "health":
        health_value, _, _ = read_canonical_json(arguments.path, "health evidence")
        validate_health_value(
            health_value, arguments.request_id, arguments.thread_id, arguments.binding_sha256
        )
    elif arguments.command == "health-copy":
        print(
            snapshot_health(
                arguments.path,
                arguments.output,
                arguments.request_id,
                arguments.thread_id,
                arguments.binding_sha256,
            )
        )
    elif arguments.command == "raw":
        data, _ = safe_regular(arguments.path, "raw authority", expected_mode=0o600)
        sys.stdout.buffer.write(data)
    elif arguments.command == "file-sha":
        data, _ = safe_regular(arguments.path, "hashed authority", expected_mode=0o600)
        print(sha256_bytes(data))
    elif arguments.command == "compare":
        left, _ = safe_regular(arguments.left, "left authority", expected_mode=0o600)
        right, _ = safe_regular(arguments.right, "right authority", expected_mode=0o600)
        if left != right:
            raise AuthorityError("authority bytes differ")
    elif arguments.command == "lock-status":
        print(
            canonical_bytes(
                parse_lock_authority(
                    arguments.path, arguments.request_id, arguments.host
                ),
                newline=True,
            ).decode("utf-8"),
            end="",
        )
    elif arguments.command == "recover-lock":
        recover_protocol_lock(arguments.path, arguments.expected)
    elif arguments.command == "record":
        result = validate_record(
            arguments.kind,
            arguments.path,
            arguments.request_id,
            arguments.thread_id,
            arguments.binding_sha256,
        )
        print(canonical_bytes(result, newline=True).decode("utf-8"), end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except LockChangedError as error:
        print(f"codex-continuation-binding: {error}", file=sys.stderr)
        raise SystemExit(2)
    except (AuthorityError, OSError, ValueError) as error:
        print(f"codex-continuation-binding: {error}", file=sys.stderr)
        raise SystemExit(1)
