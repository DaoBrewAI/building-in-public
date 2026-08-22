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
import sys
import time
from pathlib import Path
from typing import Any, Optional


ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
COORDINATOR_FILE_RE = re.compile(r"^([0-9a-f]{64})\.session-id$")
SUPERSEDED_FILE_RE = re.compile(r"^([0-9a-f]{64})\.superseded\.json$")
PROMOTION_COMMIT_RE = re.compile(r"^([0-9a-f]{64})\.promotion-commit\.json$")
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
        scalar_record(os.path.join(mission_dir, "state"), "mission state", mission_dir)
        control_mission = os.path.join(control_root, mission)
        safe_directory(control_mission, "control mission", control_root, allow_missing=True)
        if not os.path.lexists(control_mission):
            continue
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
            accepted = os.path.join(task_dir, "accepted-thread-id")
            if os.path.lexists(accepted):
                scalar_record(accepted, "accepted thread", task_dir)
    return hub


def build_missions(hub: str) -> list[dict[str, Any]]:
    missions_root = os.path.join(hub, "missions")
    control_root = os.path.join(hub, "control")
    missions: list[dict[str, Any]] = []
    for mission in direct_directories(missions_root, "missions root"):
        mission_dir = os.path.join(missions_root, mission)
        tasks: list[dict[str, Any]] = []
        tasks_root = os.path.join(control_root, mission, "tasks")
        if os.path.isdir(tasks_root):
            for task in direct_directories(tasks_root, "tasks root"):
                task_dir = os.path.join(tasks_root, task)
                accepted_path = os.path.join(task_dir, "accepted-thread-id")
                accepted = (
                    scalar_record(accepted_path, "accepted thread", task_dir)
                    if os.path.lexists(accepted_path)
                    else None
                )
                tasks.append(
                    {
                        "accepted_thread": accepted,
                        "generation": scalar_record(
                            os.path.join(task_dir, "generation"), "task generation", task_dir
                        ),
                        "path": task_dir,
                        "state": scalar_record(os.path.join(task_dir, "state"), "task state", task_dir),
                        "task": task,
                    }
                )
        missions.append(
            {
                "mission": mission,
                "path": mission_dir,
                "state": scalar_record(os.path.join(mission_dir, "state"), "mission state", mission_dir),
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
        if not any(mission["state"]["value"] in ELIGIBLE_MISSION_STATES for mission in missions):
            return "terminal"
        return "eligible"
    expected = sha256_bytes((session_id + "\n").encode("utf-8")) + ".session-id"
    path = os.path.join(coordinators, expected)
    if not os.path.lexists(path):
        return "unrelated"
    coordinator_authority(hub, session_id)
    missions = build_missions(hub)
    if not any(mission["state"]["value"] in ELIGIBLE_MISSION_STATES for mission in missions):
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
    if not any(mission["state"]["value"] in ELIGIBLE_MISSION_STATES for mission in missions):
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
        for task in mission["tasks"]:
            accepted = task["accepted_thread"]["value"] if task["accepted_thread"] else ""
            lines.append(
                "\t".join(
                    (
                        "task",
                        mission["mission"],
                        task["task"],
                        task["generation"]["value"],
                        task["state"]["value"],
                        accepted,
                    )
                )
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
        exact_keys(mission, {"mission", "path", "state", "tasks"}, "mission")
        mission_names.append(strict_text(mission["mission"], "mission id"))
        strict_text(mission["path"], "mission path")
        validate_file_shape(mission["state"], True, "mission state")
        if not isinstance(mission["tasks"], list):
            raise AuthorityError("invalid task list")
        task_names: list[str] = []
        for task in mission["tasks"]:
            exact_keys(
                task,
                {"accepted_thread", "generation", "path", "state", "task"},
                "task",
            )
            task_names.append(strict_text(task["task"], "task id"))
            strict_text(task["path"], "task path")
            validate_file_shape(task["generation"], True, "task generation")
            if not task["generation"]["value"].isdigit():
                raise AuthorityError("non-numeric task generation")
            validate_file_shape(task["state"], True, "task state")
            if task["accepted_thread"] is not None:
                validate_file_shape(task["accepted_thread"], True, "accepted thread")
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
