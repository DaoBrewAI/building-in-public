#!/usr/bin/env python3
"""Validate and durably import one app-native child task outcome.

The child returns a bounded JSON envelope through its accepted native turn.
This coordinator-run helper is the only writer of durable task outcome state.
It never writes into the child worktree.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Mapping, NoReturn, Optional, Sequence, Set, Tuple

from coordinator_lifecycle_lock import (
    LifecycleLockError,
    acquire_lifecycle_lock,
    release_lifecycle_lock,
)


PROTOCOL_VERSION = 1
MAX_INPUT_BYTES = 1024 * 1024
IDENTITY_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,511}\Z")
TASK_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
SHA_RE = re.compile(r"[0-9a-f]{40,64}\Z")
DIGEST_RE = re.compile(r"[0-9a-f]{64}\Z")
EVENT_NAME_RE = re.compile(r"([0-9a-f]{64})\.json\Z")
BROKER_DONE_RE = re.compile(r"COMMIT-DONE-([A-Za-z0-9._-]+)\.json\Z")

REWORK_INTENT_KEYS = {
    "accepted_thread_id",
    "branch",
    "manifest_base",
    "manifest_sha256",
    "new_generation",
    "new_outcome_nonce",
    "old_generation",
    "old_outcome_nonce",
    "parent_tip",
    "parent_worktree",
    "previous_latest",
    "prior_child_tip",
    "prior_integrated_sha",
    "protocol_version",
    "repo",
    "task_id",
    "task_state_dir",
    "worktree",
}
REWORK_COMPLETION_KEYS = {
    "accepted_thread_id",
    "intent_sha256",
    "kind",
    "new_generation",
    "old_generation",
    "outcome_nonce",
    "prior_child_tip",
    "prior_integrated_sha",
    "previous_latest",
    "protocol_version",
    "task_id",
}

COMMON_KEYS = {
    "protocol_version",
    "kind",
    "task_id",
    "generation",
    "accepted_thread_id",
    "outcome_nonce",
}
KIND_KEYS = {
    "ready_for_commit": {
        "base_sha",
        "head_sha",
        "changed_files",
        "commit_message",
        "verification",
        "deviations",
        "risks",
    },
    "blocked": {"work_in_progress", "question", "options", "recommendation"},
    "failed": {"error", "work_in_progress"},
    "completed": {
        "base_sha",
        "commit_sha",
        "changed_files",
        "verification",
        "deviations",
        "risks",
    },
}

ALLOWED_TRANSITIONS = {
    "ready": {"ready_for_commit", "blocked", "failed"},
    "running": {"ready_for_commit", "blocked", "failed"},
    "ready_for_commit": {"ready_for_commit", "completed", "blocked", "failed"},
    "blocked": {"blocked", "ready_for_commit", "failed"},
    "completed": set(),
    "failed": set(),
}


class OutcomeError(RuntimeError):
    """A fail-closed outcome validation or publication error."""


def fail(message: str) -> NoReturn:
    raise OutcomeError(message)


def ensure_string(value: Any, label: str, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str):
        fail(f"{label} must be a string")
    if "\x00" in value or "\r" in value:
        fail(f"{label} contains unsafe characters")
    if not allow_empty and not value.strip():
        fail(f"{label} must not be empty")
    return value


def canonical_directory(raw: str, label: str) -> Path:
    if not os.path.isabs(raw):
        fail(f"{label} must be absolute")
    lexical = os.path.abspath(raw)
    physical = os.path.realpath(raw)
    if lexical != physical:
        fail(f"{label} must be a canonical path without symlinks")
    try:
        metadata = os.lstat(physical)
    except OSError as exc:
        fail(f"{label} is unavailable: {exc}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        fail(f"{label} must be a real directory")
    return Path(physical)


def canonical_regular_file(raw: str, label: str) -> Path:
    if not os.path.isabs(raw):
        fail(f"{label} must be absolute")
    lexical = os.path.abspath(raw)
    physical = os.path.realpath(raw)
    if lexical != physical:
        fail(f"{label} must be a canonical path without symlinks")
    path = Path(physical)
    try:
        metadata = os.lstat(path)
    except OSError as exc:
        fail(f"{label} is unavailable: {exc}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} must be a regular file")
    return path


def path_contains(parent: Path, child: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def paths_overlap(left: Path, right: Path) -> bool:
    return path_contains(left, right) or path_contains(right, left)


def open_regular(path: Path, *, max_bytes: Optional[int] = None) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(str(path), flags)
    except OSError as exc:
        fail(f"cannot safely open {path}: {exc}")
    try:
        opened = os.fstat(descriptor)
        current = os.lstat(path)
        if (
            not stat.S_ISREG(opened.st_mode)
            or stat.S_ISLNK(current.st_mode)
            or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)
        ):
            fail(f"unsafe regular file: {path}")
        if max_bytes is not None and opened.st_size > max_bytes:
            fail(f"file is too large: {path}")
        initial = (
            opened.st_dev,
            opened.st_ino,
            stat.S_IFMT(opened.st_mode),
            opened.st_size,
            opened.st_mtime_ns,
            opened.st_ctime_ns,
        )
        chunks: List[bytes] = []
        remaining = opened.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 65536))
            if not chunk:
                fail(f"short read from {path}")
            chunks.append(chunk)
            remaining -= len(chunk)
        final_fd = os.fstat(descriptor)
        final_path = os.lstat(path)
        final = (
            final_fd.st_dev,
            final_fd.st_ino,
            stat.S_IFMT(final_fd.st_mode),
            final_fd.st_size,
            final_fd.st_mtime_ns,
            final_fd.st_ctime_ns,
        )
        if final != initial or (final_path.st_dev, final_path.st_ino) != (
            final_fd.st_dev,
            final_fd.st_ino,
        ):
            fail(f"file changed while it was read: {path}")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def read_scalar(path: Path, label: str) -> str:
    raw = open_regular(path, max_bytes=4096)
    try:
        value = raw.decode("utf-8")
    except UnicodeDecodeError:
        fail(f"{label} is not UTF-8")
    if not value.endswith("\n") or value.count("\n") != 1:
        fail(f"{label} must be exactly one line")
    result = value[:-1]
    if not result:
        fail(f"{label} must not be empty")
    return result


def fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(str(path), flags)
    try:
        opened = os.fstat(descriptor)
        current = os.lstat(path)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or stat.S_ISLNK(current.st_mode)
            or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)
        ):
            fail(f"unsafe directory changed during fsync: {path}")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_replace(path: Path, data: bytes, mode: int = 0o600) -> None:
    parent = path.parent
    if not parent.is_dir() or parent.is_symlink():
        fail(f"unsafe publication directory: {parent}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(parent))
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        written = 0
        while written < len(data):
            written += os.write(descriptor, data[written:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    try:
        if os.path.lexists(path):
            metadata = os.lstat(path)
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                fail(f"refusing to replace unsafe path: {path}")
        os.replace(temporary, path)
        published = os.lstat(path)
        if stat.S_ISLNK(published.st_mode) or not stat.S_ISREG(published.st_mode):
            fail(f"publication produced an unsafe path: {path}")
        fsync_directory(parent)
    except BaseException:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise


def publish_immutable(path: Path, data: bytes, mode: int = 0o600) -> None:
    parent = path.parent
    if os.path.lexists(path):
        if open_regular(path, max_bytes=MAX_INPUT_BYTES) != data:
            fail(f"immutable artifact conflicts with existing content: {path}")
        return
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(parent))
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        written = 0
        while written < len(data):
            written += os.write(descriptor, data[written:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    try:
        try:
            os.link(temporary, path, follow_symlinks=False)
        except FileExistsError:
            if open_regular(path, max_bytes=MAX_INPUT_BYTES) != data:
                fail(f"immutable artifact publication raced: {path}")
        published = os.lstat(path)
        if stat.S_ISLNK(published.st_mode) or not stat.S_ISREG(published.st_mode):
            fail(f"immutable artifact is unsafe: {path}")
        fsync_directory(parent)
    finally:
        temporary.unlink(missing_ok=True)


def ensure_directory(path: Path) -> None:
    if os.path.lexists(path):
        metadata = os.lstat(path)
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            fail(f"unsafe directory authority: {path}")
        return
    os.mkdir(path, 0o700)
    fsync_directory(path.parent)


def canonical_json(value: Mapping[str, Any]) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def read_exact_json(path: Path, expected_keys: Set[str], label: str) -> Dict[str, Any]:
    raw = open_regular(path, max_bytes=65536)
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail(f"{label} is malformed")
    if not isinstance(value, dict) or set(value) != expected_keys:
        fail(f"{label} schema is invalid")
    if canonical_json(value) != raw:
        fail(f"{label} is not canonical JSON")
    return value


def clear_regular(path: Path, label: str) -> None:
    if not os.path.lexists(path):
        return
    metadata = os.lstat(path)
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} became unsafe")
    path.unlink()
    fsync_directory(path.parent)


def run_git(cwd: Path, arguments: Sequence[str], *, text: bool = True) -> Any:
    try:
        result = subprocess.run(
            ["git", "-C", str(cwd), *arguments],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = ""
        if isinstance(exc, subprocess.CalledProcessError):
            detail = exc.stderr.decode("utf-8", "replace").strip()
        fail(f"Git validation failed: {detail or exc}")
    if text:
        try:
            return result.stdout.decode("utf-8").strip()
        except UnicodeDecodeError:
            fail("Git emitted a non-UTF-8 identity")
    return result.stdout


def decode_nul_paths(raw: bytes, label: str) -> Set[str]:
    if not raw:
        return set()
    if not raw.endswith(b"\0"):
        fail(f"{label} returned malformed NUL-delimited paths")
    result: Set[str] = set()
    for item in raw[:-1].split(b"\0"):
        try:
            value = item.decode("utf-8")
        except UnicodeDecodeError:
            fail(f"{label} contains a non-UTF-8 path")
        result.add(value)
    return result


def dirty_paths(worktree: Path) -> Set[str]:
    unstaged = decode_nul_paths(
        run_git(worktree, ["diff", "--name-only", "-z"], text=False), "unstaged diff"
    )
    staged = decode_nul_paths(
        run_git(worktree, ["diff", "--cached", "--name-only", "-z"], text=False),
        "staged diff",
    )
    untracked = decode_nul_paths(
        run_git(
            worktree,
            ["ls-files", "--others", "--exclude-standard", "-z"],
            text=False,
        ),
        "untracked files",
    )
    return unstaged | staged | untracked


def committed_paths(repo: Path, base: str, tip: str) -> Set[str]:
    return decode_nul_paths(
        run_git(repo, ["diff", "--name-only", "-z", f"{base}..{tip}"], text=False),
        "committed diff",
    )


def canonical_diff_digest(worktree: Path, paths: Sequence[str]) -> str:
    payload = bytearray()
    for relative in sorted(paths):
        target = worktree / relative
        if target.is_file() and not target.is_symlink():
            state = b"file"
            mode = b"100755" if os.lstat(target).st_mode & 0o111 else b"100644"
            digest = hashlib.sha256(open_regular(target)).hexdigest().encode("ascii")
        elif not os.path.lexists(target):
            state = b"deleted"
            mode = b"000000"
            digest = b""
        else:
            fail(f"changed path is not a regular file or deletion: {relative}")
        payload.extend(relative.encode("utf-8"))
        payload.extend(b"\0" + state + b"\0" + mode + b"\0" + digest + b"\n")
    return hashlib.sha256(payload).hexdigest()


def broker_request(
    envelope: Mapping[str, Any], worktree: Path, outcome_digest: str
) -> bytes:
    request = {
        "protocol_version": PROTOCOL_VERSION,
        "task_id": envelope["task_id"],
        "generation": envelope["generation"],
        "accepted_thread_id": envelope["accepted_thread_id"],
        "outcome_nonce": envelope["outcome_nonce"],
        "outcome_digest": outcome_digest,
        "base_sha": envelope["base_sha"],
        "diff_sha256": canonical_diff_digest(worktree, envelope["changed_files"]),
        "worktree": str(worktree),
        "paths": envelope["changed_files"],
        "message": envelope["commit_message"],
    }
    return (
        json.dumps(request, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def validate_relative_path(value: Any, label: str) -> str:
    path = ensure_string(value, label)
    if path.startswith("/") or "\n" in path or "\t" in path or "\\" in path:
        fail(f"{label} is not a safe worktree-relative path")
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        fail(f"{label} contains an unsafe path component")
    return path


def validate_string_list(value: Any, label: str) -> List[str]:
    if not isinstance(value, list):
        fail(f"{label} must be an array")
    result = [ensure_string(item, f"{label} item") for item in value]
    if len(result) != len(set(result)):
        fail(f"{label} must not contain duplicates")
    return result


def validate_changed_files(value: Any) -> List[str]:
    if not isinstance(value, list) or not value:
        fail("changed_files must be a non-empty array")
    result = [validate_relative_path(item, "changed_files item") for item in value]
    if result != sorted(set(result)):
        fail("changed_files must be sorted and unique")
    return result


def validate_verification(value: Any) -> List[Dict[str, Any]]:
    if not isinstance(value, list) or not value:
        fail("verification must be a non-empty array")
    result: List[Dict[str, Any]] = []
    for index, item in enumerate(value):
        if not isinstance(item, dict) or set(item) != {"command", "exit_code", "output"}:
            fail(f"verification item {index} has an invalid schema")
        command = ensure_string(item["command"], f"verification item {index} command")
        exit_code = item["exit_code"]
        if isinstance(exit_code, bool) or not isinstance(exit_code, int) or exit_code != 0:
            fail(f"verification item {index} must record exit_code 0")
        output = ensure_string(
            item["output"], f"verification item {index} output", allow_empty=True
        )
        result.append({"command": command, "exit_code": exit_code, "output": output})
    return result


def validate_envelope(raw: bytes) -> Dict[str, Any]:
    try:
        decoded = raw.decode("utf-8")
        value = json.loads(decoded)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"outcome envelope is not valid UTF-8 JSON: {exc}")
    if not isinstance(value, dict):
        fail("outcome envelope must be an object")
    kind = value.get("kind")
    if not isinstance(kind, str) or kind not in KIND_KEYS:
        fail("outcome kind is unsupported")
    expected_keys = COMMON_KEYS | KIND_KEYS[kind]
    if set(value) != expected_keys:
        fail("outcome envelope keys do not exactly match its kind")
    version = value["protocol_version"]
    if isinstance(version, bool) or not isinstance(version, int) or version != PROTOCOL_VERSION:
        fail("outcome protocol_version is unsupported")
    task_id = ensure_string(value["task_id"], "task_id")
    if not TASK_ID_RE.fullmatch(task_id):
        fail("task_id is invalid")
    generation = value["generation"]
    if isinstance(generation, bool) or not isinstance(generation, int) or generation <= 0:
        fail("generation must be a positive integer")
    accepted_thread = ensure_string(value["accepted_thread_id"], "accepted_thread_id")
    nonce = ensure_string(value["outcome_nonce"], "outcome_nonce")
    if not IDENTITY_RE.fullmatch(accepted_thread) or not IDENTITY_RE.fullmatch(nonce):
        fail("thread or outcome nonce identity is invalid")

    if kind in ("ready_for_commit", "completed"):
        base = ensure_string(value["base_sha"], "base_sha")
        if not SHA_RE.fullmatch(base):
            fail("base_sha is invalid")
        changed = validate_changed_files(value["changed_files"])
        value["changed_files"] = changed
        value["verification"] = validate_verification(value["verification"])
        value["deviations"] = validate_string_list(value["deviations"], "deviations")
        value["risks"] = validate_string_list(value["risks"], "risks")
        if kind == "ready_for_commit":
            head = ensure_string(value["head_sha"], "head_sha")
            if not SHA_RE.fullmatch(head):
                fail("head_sha is invalid")
            ensure_string(value["commit_message"], "commit_message")
        else:
            commit = ensure_string(value["commit_sha"], "commit_sha")
            if not SHA_RE.fullmatch(commit):
                fail("commit_sha is invalid")
    elif kind == "blocked":
        ensure_string(value["work_in_progress"], "work_in_progress")
        ensure_string(value["question"], "question")
        options = validate_string_list(value["options"], "options")
        if len(options) not in (2, 3):
            fail("blocked options must contain exactly two or three choices")
        recommendation = ensure_string(value["recommendation"], "recommendation")
        if recommendation not in options:
            fail("blocked recommendation must be one of the options")
    else:
        ensure_string(value["error"], "error")
        ensure_string(value["work_in_progress"], "work_in_progress")
    return value


def parse_manifest(path: Path, task_id: str) -> Tuple[Path, str, str, Path]:
    raw = open_regular(path, max_bytes=65536)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        fail("worktree manifest is not UTF-8")
    lines = text.splitlines()
    if len(lines) != 1:
        fail("worktree manifest must contain exactly one row")
    parts = lines[0].split("\t")
    if len(parts) != 4 or any(not part for part in parts):
        fail("worktree manifest row is malformed")
    worktree = canonical_directory(parts[0], "manifest worktree")
    branch = parts[1]
    base = parts[2]
    repo = canonical_directory(parts[3], "manifest repository")
    if not branch.endswith("/" + task_id) or not SHA_RE.fullmatch(base):
        fail("worktree manifest identity is invalid")
    return worktree, branch, base, repo


def validate_git_binding(
    envelope: Mapping[str, Any], worktree: Path, branch: str, manifest_base: str, repo: Path
) -> None:
    current_branch = run_git(worktree, ["symbolic-ref", "--quiet", "--short", "HEAD"])
    if current_branch != branch:
        fail("child worktree branch does not match coordinator authority")
    head = run_git(worktree, ["rev-parse", "--verify", "HEAD^{commit}"])
    repository_common_raw = run_git(repo, ["rev-parse", "--git-common-dir"])
    repository_common = os.path.realpath(
        repository_common_raw
        if os.path.isabs(repository_common_raw)
        else repo / repository_common_raw
    )
    worktree_common_raw = run_git(worktree, ["rev-parse", "--git-common-dir"])
    worktree_common = os.path.realpath(
        worktree_common_raw
        if os.path.isabs(worktree_common_raw)
        else worktree / worktree_common_raw
    )
    if repository_common != worktree_common:
        fail("child worktree belongs to a different Git repository")

    kind = envelope["kind"]
    if kind == "ready_for_commit":
        if envelope["base_sha"] != manifest_base or envelope["head_sha"] != head:
            fail("ready outcome base/head does not match coordinator Git authority")
        run_git(repo, ["merge-base", "--is-ancestor", manifest_base, head])
        if set(envelope["changed_files"]) != dirty_paths(worktree):
            fail("ready outcome changed_files does not match the child worktree")
    elif kind == "completed":
        commit = envelope["commit_sha"]
        if envelope["base_sha"] != manifest_base or commit != head:
            fail("completed outcome base/commit does not match coordinator Git authority")
        run_git(repo, ["merge-base", "--is-ancestor", manifest_base, commit])
        if dirty_paths(worktree):
            fail("completed child worktree is dirty")
        if set(envelope["changed_files"]) != committed_paths(repo, manifest_base, commit):
            fail("completed outcome changed_files does not match the committed diff")


def validate_broker_receipt(
    task_dir: Path,
    envelope: Mapping[str, Any],
    *,
    expected_branch: str,
) -> None:
    if envelope["kind"] != "completed":
        return
    expected_keys = {
        "protocol_version",
        "task_id",
        "generation",
        "accepted_thread_id",
        "outcome_nonce",
        "request_sha256",
        "hash",
        "branch",
    }
    matched = False
    for entry in os.scandir(task_dir):
        done_match = BROKER_DONE_RE.fullmatch(entry.name)
        if not done_match:
            continue
        if entry.is_symlink() or not entry.is_file(follow_symlinks=False):
            fail("broker DONE receipt is unsafe")
        raw = open_regular(Path(entry.path), max_bytes=65536)
        try:
            receipt = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            fail("broker DONE receipt is malformed")
        if not isinstance(receipt, dict) or set(receipt) != expected_keys:
            fail("broker DONE receipt schema is invalid")
        request_digest = receipt["request_sha256"]
        if not isinstance(request_digest, str) or not DIGEST_RE.fullmatch(request_digest):
            fail("broker DONE request digest is invalid")
        request_path = task_dir / f"COMMIT-REQUEST-{done_match.group(1)}.json"
        if not os.path.lexists(request_path):
            fail("broker DONE receipt has no matching coordinator request")
        request_raw = open_regular(request_path, max_bytes=MAX_INPUT_BYTES)
        if hashlib.sha256(request_raw).hexdigest() != request_digest:
            fail("broker DONE receipt request digest mismatch")
        if (
            receipt["protocol_version"] == PROTOCOL_VERSION
            and receipt["task_id"] == envelope["task_id"]
            and receipt["generation"] == envelope["generation"]
            and receipt["accepted_thread_id"] == envelope["accepted_thread_id"]
            and receipt["outcome_nonce"] == envelope["outcome_nonce"]
            and receipt["hash"] == envelope["commit_sha"]
            and receipt["branch"] == expected_branch
        ):
            matched = True
    if not matched:
        fail("completed outcome lacks an exact identity-bound broker DONE receipt")


def validate_coordinator_verification(
    task_control: Path, envelope: Mapping[str, Any]
) -> None:
    if envelope["kind"] != "completed":
        return
    verified_tip = read_scalar(
        task_control / "coordinator-verification.sha", "coordinator verification SHA"
    )
    if verified_tip != envelope["commit_sha"]:
        fail("coordinator verification does not attest the completed commit")
    evidence = open_regular(
        task_control / "coordinator-verification.md", max_bytes=MAX_INPUT_BYTES
    )
    if not evidence.strip():
        fail("coordinator verification evidence is empty")


def canonical_event(envelope: Mapping[str, Any], thread_id: str, turn_id: str) -> bytes:
    wrapper = {
        "accepted_thread_id": thread_id,
        "outcome": envelope,
        "turn_id": turn_id,
    }
    return (
        json.dumps(wrapper, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")


def read_events(outcomes: Path) -> List[Tuple[str, Dict[str, Any], bytes]]:
    result: List[Tuple[str, Dict[str, Any], bytes]] = []
    for entry in sorted(os.scandir(outcomes), key=lambda item: item.name):
        match = EVENT_NAME_RE.fullmatch(entry.name)
        if not match or entry.is_symlink() or not entry.is_file(follow_symlinks=False):
            fail("outcome ledger contains an unsafe or unexpected entry")
        raw = open_regular(Path(entry.path), max_bytes=MAX_INPUT_BYTES)
        digest = hashlib.sha256(raw).hexdigest()
        if digest != match.group(1):
            fail("outcome ledger content address is invalid")
        try:
            wrapper = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            fail("outcome ledger contains malformed JSON")
        if not isinstance(wrapper, dict) or set(wrapper) != {
            "accepted_thread_id",
            "outcome",
            "turn_id",
        }:
            fail("outcome ledger wrapper schema is invalid")
        if not isinstance(wrapper["outcome"], dict):
            fail("outcome ledger envelope is invalid")
        result.append((digest, wrapper, raw))
    return result


def render_blocked(envelope: Mapping[str, Any], number: int) -> bytes:
    options = "\n".join(f"- {item}" for item in envelope["options"])
    return (
        f"# BLOCKED {number} — {envelope['task_id']}\n\n"
        f"## Work in progress\n\n{envelope['work_in_progress']}\n\n"
        f"## Question\n\n{envelope['question']}\n\n"
        f"## Options\n\n{options}\n\n"
        f"## Recommendation\n\n{envelope['recommendation']}\n"
    ).encode("utf-8")


def render_failed(envelope: Mapping[str, Any]) -> bytes:
    return (
        f"# Task outcome — failed\n\n"
        f"Task: {envelope['task_id']}\n\n"
        f"## Error\n\n{envelope['error']}\n\n"
        f"## Work in progress\n\n{envelope['work_in_progress']}\n"
    ).encode("utf-8")


def render_completed(envelope: Mapping[str, Any]) -> bytes:
    files = "\n".join(f"- {item}" for item in envelope["changed_files"])
    verification_parts: List[str] = []
    for item in envelope["verification"]:
        verification_parts.append(
            f"### `{item['command']}`\n\nExit: {item['exit_code']}\n\n```text\n{item['output']}\n```"
        )
    deviations = "\n".join(f"- {item}" for item in envelope["deviations"]) or "- none"
    risks = "\n".join(f"- {item}" for item in envelope["risks"]) or "- none"
    return (
        f"# Task outcome — completed\n\n"
        f"Task: {envelope['task_id']}\n\n"
        f"Base: {envelope['base_sha']}\n\n"
        f"Commit: {envelope['commit_sha']}\n\n"
        f"## Changed files\n\n{files}\n\n"
        f"## Verification\n\n{chr(10).join(verification_parts)}\n\n"
        f"## Deviations\n\n{deviations}\n\n"
        f"## Risks\n\n{risks}\n"
    ).encode("utf-8")


def expected_artifacts(
    envelope: Mapping[str, Any], blocked_number: Optional[int]
) -> Dict[str, bytes]:
    kind = envelope["kind"]
    if kind == "blocked":
        if blocked_number is None:
            fail("blocked outcome lacks a deterministic sequence number")
        return {f"BLOCKED-{blocked_number}.md": render_blocked(envelope, blocked_number)}
    if kind == "failed":
        return {"report.md": render_failed(envelope)}
    if kind == "completed":
        return {
            "report.md": render_completed(envelope),
            "verification.sha": (envelope["commit_sha"] + "\n").encode("ascii"),
        }
    return {}


def current_latest(task_control: Path) -> Optional[str]:
    path = task_control / "latest-outcome"
    if not os.path.lexists(path):
        return None
    value = read_scalar(path, "latest-outcome")
    if not DIGEST_RE.fullmatch(value):
        fail("latest-outcome is not a SHA-256 digest")
    return value


def read_intent(task_control: Path) -> Optional[Dict[str, Any]]:
    path = task_control / ".outcome-intent.json"
    if not os.path.lexists(path):
        return None
    raw = open_regular(path, max_bytes=4096)
    try:
        intent = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("outcome intent is malformed")
    expected = {"digest", "previous_latest", "previous_state", "turn_id"}
    if not isinstance(intent, dict) or set(intent) != expected:
        fail("outcome intent schema is invalid")
    if not isinstance(intent["digest"], str) or not DIGEST_RE.fullmatch(intent["digest"]):
        fail("outcome intent digest is invalid")
    previous_latest = intent["previous_latest"]
    if previous_latest is not None and (
        not isinstance(previous_latest, str) or not DIGEST_RE.fullmatch(previous_latest)
    ):
        fail("outcome intent previous_latest is invalid")
    ensure_string(intent["previous_state"], "outcome intent previous_state")
    if not isinstance(intent["turn_id"], str) or not IDENTITY_RE.fullmatch(intent["turn_id"]):
        fail("outcome intent turn_id is invalid")
    return intent


def publish_intent(
    task_control: Path,
    *,
    digest: str,
    previous_latest: Optional[str],
    previous_state: str,
    turn_id: str,
) -> None:
    value = {
        "digest": digest,
        "previous_latest": previous_latest,
        "previous_state": previous_state,
        "turn_id": turn_id,
    }
    raw = (
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("ascii")
    publish_immutable(task_control / ".outcome-intent.json", raw)


def clear_intent(task_control: Path) -> None:
    path = task_control / ".outcome-intent.json"
    if not os.path.lexists(path):
        return
    metadata = os.lstat(path)
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail("outcome intent became unsafe")
    path.unlink()
    fsync_directory(task_control)


def acquire_lock(task_control: Path) -> int:
    path = task_control / ".task-outcome.lock"
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(str(path), flags, 0o600)
    opened = os.fstat(descriptor)
    current = os.lstat(path)
    if (
        not stat.S_ISREG(opened.st_mode)
        or stat.S_ISLNK(current.st_mode)
        or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)
    ):
        os.close(descriptor)
        fail("task outcome lock is unsafe")
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    return descriptor


def resolve_exact_commit(repo: Path, value: str, label: str) -> str:
    if not SHA_RE.fullmatch(value):
        fail(f"{label} is not a full commit SHA")
    resolved = run_git(repo, ["rev-parse", "--verify", f"{value}^{{commit}}"])
    if resolved != value:
        fail(f"{label} does not resolve exactly")
    return value


def git_common_directory(path: Path) -> str:
    raw = run_git(path, ["rev-parse", "--git-common-dir"])
    return os.path.realpath(raw if os.path.isabs(raw) else path / raw)


def validate_rework_intent(value: Mapping[str, Any]) -> None:
    if set(value) != REWORK_INTENT_KEYS or value["protocol_version"] != PROTOCOL_VERSION:
        fail("rework intent schema is invalid")
    if value["task_id"] is None or not TASK_ID_RE.fullmatch(
        ensure_string(value["task_id"], "rework intent task_id")
    ):
        fail("rework intent task_id is invalid")
    thread = ensure_string(value["accepted_thread_id"], "rework intent thread")
    if not IDENTITY_RE.fullmatch(thread):
        fail("rework intent thread is invalid")
    for name in ("old_outcome_nonce", "new_outcome_nonce", "manifest_sha256"):
        item = ensure_string(value[name], f"rework intent {name}")
        if not DIGEST_RE.fullmatch(item):
            fail(f"rework intent {name} is invalid")
    previous_latest = ensure_string(value["previous_latest"], "rework intent previous_latest")
    if not DIGEST_RE.fullmatch(previous_latest):
        fail("rework intent previous_latest is invalid")
    for name in ("manifest_base", "parent_tip", "prior_child_tip", "prior_integrated_sha"):
        item = ensure_string(value[name], f"rework intent {name}")
        if not SHA_RE.fullmatch(item):
            fail(f"rework intent {name} is invalid")
    old_generation = value["old_generation"]
    new_generation = value["new_generation"]
    if (
        isinstance(old_generation, bool)
        or not isinstance(old_generation, int)
        or old_generation <= 0
        or isinstance(new_generation, bool)
        or not isinstance(new_generation, int)
        or new_generation != old_generation + 1
    ):
        fail("rework intent generation is invalid")
    for name in ("branch", "repo", "task_state_dir", "worktree", "parent_worktree"):
        ensure_string(value[name], f"rework intent {name}")


def validate_rework_completion(
    value: Mapping[str, Any], *, task_id: str, expected_generation: int
) -> None:
    if set(value) != REWORK_COMPLETION_KEYS:
        fail("rework completion schema is invalid")
    if (
        value["protocol_version"] != PROTOCOL_VERSION
        or value["kind"] != "rework_reopened"
        or value["task_id"] != task_id
        or value["old_generation"] != expected_generation
        or value["new_generation"] != expected_generation + 1
    ):
        fail("rework completion identity is invalid")
    for name in ("intent_sha256", "outcome_nonce"):
        item = value[name]
        if not isinstance(item, str) or not DIGEST_RE.fullmatch(item):
            fail(f"rework completion {name} is invalid")
    previous_latest = value["previous_latest"]
    if not isinstance(previous_latest, str) or not DIGEST_RE.fullmatch(previous_latest):
        fail("rework completion previous_latest is invalid")
    thread = value["accepted_thread_id"]
    if not isinstance(thread, str) or not IDENTITY_RE.fullmatch(thread):
        fail("rework completion accepted thread is invalid")
    for name in ("prior_child_tip", "prior_integrated_sha"):
        item = value[name]
        if not isinstance(item, str) or not SHA_RE.fullmatch(item):
            fail(f"rework completion {name} is invalid")


def rework_completion_value(intent: Mapping[str, Any], intent_raw: bytes) -> Dict[str, Any]:
    return {
        "accepted_thread_id": intent["accepted_thread_id"],
        "intent_sha256": hashlib.sha256(intent_raw).hexdigest(),
        "kind": "rework_reopened",
        "new_generation": intent["new_generation"],
        "old_generation": intent["old_generation"],
        "outcome_nonce": intent["new_outcome_nonce"],
        "prior_child_tip": intent["prior_child_tip"],
        "prior_integrated_sha": intent["prior_integrated_sha"],
        "previous_latest": intent["previous_latest"],
        "protocol_version": PROTOCOL_VERSION,
        "task_id": intent["task_id"],
    }


def validate_reopen_resources(
    *,
    task_control: Path,
    task_dir: Path,
    task_id: str,
    parent: Path,
    expected_generation: int,
    recovering: Optional[Mapping[str, Any]] = None,
) -> Dict[str, Any]:
    state_authority = read_scalar(task_control / "task-state-dir", "task-state-dir")
    if state_authority != str(task_dir):
        fail("task-state-dir does not match the exact task directory")

    accepted_thread = read_scalar(
        task_control / "accepted-thread-id", "accepted-thread-id"
    )
    worker_thread = read_scalar(task_dir / "accepted-thread-id", "worker thread")
    if (
        accepted_thread != worker_thread
        or not IDENTITY_RE.fullmatch(accepted_thread)
    ):
        fail("retained accepted thread authority is inconsistent")
    if read_scalar(task_control / "task-window-state", "task-window-state") != "unarchived":
        fail("retained child thread must remain unarchived")

    generation_values = {
        read_scalar(task_control / "generation", "generation"),
        read_scalar(task_dir / "generation", "worker generation"),
    }
    state_values = {
        read_scalar(task_control / "state", "coordinator task state"),
        read_scalar(task_dir / "state", "task state"),
    }
    outcome_nonce = read_scalar(task_control / "outcome-nonce", "outcome-nonce")
    if not DIGEST_RE.fullmatch(outcome_nonce):
        fail("retained outcome nonce is invalid")
    if recovering is None:
        if generation_values != {str(expected_generation)}:
            fail("expected generation does not match retained authority")
        if state_values != {"integrated"}:
            fail("reopen requires matching integrated task state")
    else:
        validate_rework_intent(recovering)
        if generation_values - {
            str(recovering["old_generation"]),
            str(recovering["new_generation"]),
        }:
            fail("rework recovery generation has unrelated authority")
        if state_values - {"integrated", "ready"}:
            fail("rework recovery state has unrelated authority")
        if outcome_nonce not in {
            recovering["old_outcome_nonce"],
            recovering["new_outcome_nonce"],
        }:
            fail("rework recovery nonce has unrelated authority")

    control_manifest = task_control / "worktrees.txt"
    worker_manifest = task_dir / "worktrees.txt"
    control_manifest_raw = open_regular(control_manifest, max_bytes=65536)
    if open_regular(worker_manifest, max_bytes=65536) != control_manifest_raw:
        fail("coordinator and task worktree manifests disagree")
    worktree, branch, manifest_base, repo = parse_manifest(control_manifest, task_id)
    if paths_overlap(worktree, task_dir) or paths_overlap(worktree, task_control.parent.parent):
        fail("retained child worktree overlaps coordinator state")
    if paths_overlap(parent, task_dir) or paths_overlap(parent, worktree):
        fail("parent worktree overlaps retained child authority")
    if read_scalar(task_control / "sandbox-root", "sandbox-root") != str(worktree):
        fail("coordinator sandbox-root differs from the manifest")
    if read_scalar(task_dir / "sandbox-root", "worker sandbox-root") != str(worktree):
        fail("worker sandbox-root differs from the manifest")

    registrations = [
        os.path.realpath(line[len("worktree ") :])
        for line in run_git(repo, ["worktree", "list", "--porcelain"]).splitlines()
        if line.startswith("worktree ")
    ]
    if registrations.count(str(worktree)) != 1:
        fail("retained child worktree is not registered exactly once")
    if git_common_directory(worktree) != git_common_directory(repo):
        fail("retained child worktree belongs to a different repository")
    if git_common_directory(parent) != git_common_directory(repo):
        fail("parent worktree belongs to a different repository")
    if run_git(worktree, ["symbolic-ref", "--quiet", "--short", "HEAD"]) != branch:
        fail("retained child branch differs from the manifest")
    child_tip = run_git(worktree, ["rev-parse", "--verify", "HEAD^{commit}"])
    branch_tip = run_git(repo, ["rev-parse", "--verify", f"refs/heads/{branch}^{{commit}}"])
    if branch_tip != child_tip or dirty_paths(worktree):
        fail("retained child worktree is dirty or differs from its branch")

    branch_prefix = "orc-task/"
    branch_suffix = "/" + task_id
    if not branch.startswith(branch_prefix) or not branch.endswith(branch_suffix):
        fail("retained child branch cannot identify its mission")
    mission = branch[len(branch_prefix) : -len(branch_suffix)]
    if not mission or "/" in mission:
        fail("retained child mission identity is invalid")
    if run_git(parent, ["symbolic-ref", "--quiet", "--short", "HEAD"]) != f"orc/{mission}":
        fail("parent worktree is not on the retained mission branch")
    if dirty_paths(parent):
        fail("parent worktree is dirty before rework reopen")

    parent_authority = read_scalar(
        task_control / "parent-worktree", "parent-worktree"
    )
    if parent_authority != str(parent):
        fail("parent worktree differs from integration authority")
    parent_before = read_scalar(
        task_control / "parent_tip_before", "parent_tip_before"
    )
    prior_child_tip = read_scalar(task_control / "child_tip", "child_tip")
    integrated = read_scalar(task_control / "integrated_sha", "integrated_sha")
    parent_tip = run_git(parent, ["rev-parse", "--verify", "HEAD^{commit}"])
    resolve_exact_commit(repo, manifest_base, "manifest base")
    resolve_exact_commit(repo, parent_before, "pre-integration parent")
    resolve_exact_commit(repo, prior_child_tip, "recorded child tip")
    resolve_exact_commit(repo, integrated, "recorded integration")
    if child_tip != prior_child_tip:
        fail("retained child tip differs from integration authority")
    if run_git(repo, ["rev-parse", f"{integrated}^1"]) != parent_before:
        fail("recorded integration first parent is inconsistent")
    if run_git(repo, ["rev-parse", f"{integrated}^2"]) != prior_child_tip:
        fail("recorded integration does not bind the retained child tip")
    run_git(repo, ["merge-base", "--is-ancestor", manifest_base, prior_child_tip])
    run_git(repo, ["merge-base", "--is-ancestor", integrated, parent_tip])
    if os.path.lexists(task_control / "integration-intent"):
        fail("integration intent is unresolved before rework reopen")
    latest = current_latest(task_control)
    if recovering is None:
        if latest is None:
            fail("integrated task lacks a latest completed outcome before reopen")
        previous_latest = latest
    else:
        previous_latest = recovering["previous_latest"]
        if latest not in (None, previous_latest):
            fail("rework recovery latest-outcome differs from durable intent")

    result: Dict[str, Any] = {
        "accepted_thread_id": accepted_thread,
        "branch": branch,
        "manifest_base": manifest_base,
        "manifest_sha256": hashlib.sha256(control_manifest_raw).hexdigest(),
        "old_generation": expected_generation,
        "old_outcome_nonce": (
            outcome_nonce if recovering is None else recovering["old_outcome_nonce"]
        ),
        "parent_tip": parent_tip,
        "parent_worktree": str(parent),
        "prior_child_tip": prior_child_tip,
        "prior_integrated_sha": integrated,
        "previous_latest": previous_latest,
        "protocol_version": PROTOCOL_VERSION,
        "repo": str(repo),
        "task_id": task_id,
        "task_state_dir": str(task_dir),
        "worktree": str(worktree),
    }
    if recovering is not None:
        for name in REWORK_INTENT_KEYS - {"new_generation", "new_outcome_nonce"}:
            if result[name] != recovering[name]:
                fail(f"rework recovery {name} differs from durable intent")
    return result


def exact_reopen_replay(
    *,
    receipt_path: Path,
    task_control: Path,
    task_dir: Path,
    task_id: str,
    expected_generation: int,
) -> bool:
    if not os.path.lexists(receipt_path):
        return False
    receipt = read_exact_json(
        receipt_path, REWORK_COMPLETION_KEYS, "rework completion"
    )
    validate_rework_completion(
        receipt, task_id=task_id, expected_generation=expected_generation
    )
    if read_scalar(task_control / "generation", "generation") != str(
        expected_generation + 1
    ) or read_scalar(task_dir / "generation", "worker generation") != str(
        expected_generation + 1
    ):
        fail("rework completion no longer matches generation authority")
    if read_scalar(task_control / "outcome-nonce", "outcome-nonce") != receipt[
        "outcome_nonce"
    ]:
        fail("rework completion no longer matches nonce authority")
    if os.path.lexists(task_control / "latest-outcome"):
        fail("rework completion must leave latest-outcome clear for the new generation")
    if read_scalar(
        task_control / "accepted-thread-id", "accepted-thread-id"
    ) != receipt["accepted_thread_id"] or read_scalar(
        task_dir / "accepted-thread-id", "worker accepted-thread-id"
    ) != receipt["accepted_thread_id"]:
        fail("rework completion no longer matches accepted thread authority")
    return True


def reopen(args: argparse.Namespace) -> None:
    if not TASK_ID_RE.fullmatch(args.task_id):
        fail("task-id is invalid")
    if args.expected_generation <= 0:
        fail("expected-generation must be positive")
    control = canonical_directory(args.control_dir, "control-dir")
    task_dir = canonical_directory(args.task_dir, "task-dir")
    parent = canonical_directory(args.parent_worktree, "parent-worktree")
    task_control = canonical_directory(
        str(control / "tasks" / args.task_id), "coordinator task authority"
    )
    if paths_overlap(control, task_dir):
        fail("control-dir and task-dir must not overlap")
    authorized_task_dir = read_scalar(task_control / "task-state-dir", "task-state-dir")
    if os.path.realpath(authorized_task_dir) != str(task_dir) or authorized_task_dir != str(task_dir):
        fail("task-dir does not match coordinator task-state-dir authority")

    completion_path = task_control / f"rework-completion-{args.expected_generation + 1}.json"
    intent_path = task_control / ".rework-intent.json"
    lock_descriptor = acquire_lock(task_control)
    try:
        if not os.path.lexists(intent_path) and exact_reopen_replay(
            receipt_path=completion_path,
            task_control=task_control,
            task_dir=task_dir,
            task_id=args.task_id,
            expected_generation=args.expected_generation,
        ):
            return

        if os.path.lexists(intent_path):
            intent = read_exact_json(intent_path, REWORK_INTENT_KEYS, "rework intent")
            validate_rework_intent(intent)
            if (
                intent["task_id"] != args.task_id
                or intent["old_generation"] != args.expected_generation
                or intent["task_state_dir"] != str(task_dir)
                or intent["parent_worktree"] != str(parent)
            ):
                fail("rework recovery arguments differ from durable intent")
            snapshot = validate_reopen_resources(
                task_control=task_control,
                task_dir=task_dir,
                task_id=args.task_id,
                parent=parent,
                expected_generation=args.expected_generation,
                recovering=intent,
            )
            del snapshot
            intent_raw = canonical_json(intent)
        else:
            if os.path.lexists(task_control / ".outcome-intent.json"):
                fail("task outcome publication is unresolved before rework reopen")
            snapshot = validate_reopen_resources(
                task_control=task_control,
                task_dir=task_dir,
                task_id=args.task_id,
                parent=parent,
                expected_generation=args.expected_generation,
            )
            new_nonce = secrets.token_hex(32)
            if not DIGEST_RE.fullmatch(new_nonce):
                fail("generated rework outcome nonce is invalid")
            intent = {
                **snapshot,
                "new_generation": args.expected_generation + 1,
                "new_outcome_nonce": new_nonce,
            }
            validate_rework_intent(intent)
            intent_raw = canonical_json(intent)
            publish_immutable(intent_path, intent_raw)

        new_generation = (str(intent["new_generation"]) + "\n").encode("ascii")
        ready = b"ready\n"
        new_nonce_raw = (intent["new_outcome_nonce"] + "\n").encode("ascii")
        clear_regular(task_control / "latest-outcome", "latest outcome")
        atomic_replace(task_control / "outcome-nonce", new_nonce_raw)
        if os.environ.get("ORC_TASK_OUTCOME_TEST_FAIL_REOPEN_AFTER_FIRST_AUTHORITY") == "1":
            fail("injected interruption after first rework authority publication")
        atomic_replace(task_control / "generation", new_generation)
        atomic_replace(task_dir / "generation", new_generation)
        atomic_replace(task_control / "state", ready)
        atomic_replace(task_dir / "state", ready)
        completion = rework_completion_value(intent, intent_raw)
        publish_immutable(completion_path, canonical_json(completion))
        fsync_directory(task_control)
        fsync_directory(task_dir)
        clear_regular(intent_path, "rework intent")
    finally:
        fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        os.close(lock_descriptor)


def record(args: argparse.Namespace) -> None:
    if not TASK_ID_RE.fullmatch(args.task_id):
        fail("task-id is invalid")
    if not IDENTITY_RE.fullmatch(args.turn_id):
        fail("turn-id is invalid")
    control = canonical_directory(args.control_dir, "control-dir")
    task_dir = canonical_directory(args.task_dir, "task-dir")
    outcome_file = canonical_regular_file(args.outcome_file, "outcome-file")
    task_control = canonical_directory(
        str(control / "tasks" / args.task_id), "coordinator task authority"
    )
    if paths_overlap(control, task_dir):
        fail("control-dir and task-dir must not overlap")
    authorized_task_dir = read_scalar(task_control / "task-state-dir", "task-state-dir")
    if (
        os.path.realpath(authorized_task_dir) != str(task_dir)
        or authorized_task_dir != str(task_dir)
    ):
        fail("task-dir does not match coordinator task-state-dir authority")
    if os.path.lexists(task_control / ".rework-intent.json"):
        fail("rework authority transition is unresolved")

    accepted_thread = read_scalar(task_control / "accepted-thread-id", "accepted-thread-id")
    generation_raw = read_scalar(task_control / "generation", "generation")
    nonce = read_scalar(task_control / "outcome-nonce", "outcome-nonce")
    if not generation_raw.isdigit() or int(generation_raw) <= 0:
        fail("generation authority is invalid")
    generation = int(generation_raw)
    if not IDENTITY_RE.fullmatch(accepted_thread) or not IDENTITY_RE.fullmatch(nonce):
        fail("accepted thread or outcome nonce authority is invalid")

    envelope = validate_envelope(open_regular(outcome_file, max_bytes=MAX_INPUT_BYTES))
    if envelope["task_id"] != args.task_id:
        fail("outcome task does not match coordinator authority")
    if envelope["generation"] != generation:
        fail("outcome generation is stale")
    if envelope["accepted_thread_id"] != accepted_thread:
        fail("outcome accepted thread is stale")
    if envelope["outcome_nonce"] != nonce:
        fail("outcome nonce is stale")
    event_raw = canonical_event(envelope, accepted_thread, args.turn_id)
    digest = hashlib.sha256(event_raw).hexdigest()
    outcomes = task_control / "outcomes"
    lock_descriptor = acquire_lock(task_control)
    try:
        if os.path.lexists(task_control / ".rework-intent.json"):
            fail("rework authority transition is unresolved")
        if (
            read_scalar(task_control / "accepted-thread-id", "accepted-thread-id")
            != accepted_thread
            or read_scalar(task_control / "generation", "generation")
            != str(generation)
            or read_scalar(task_control / "outcome-nonce", "outcome-nonce") != nonce
        ):
            fail("task outcome authority changed before publication")
        events: List[Tuple[str, Dict[str, Any], bytes]] = []
        if os.path.lexists(outcomes):
            ensure_directory(outcomes)
            events = read_events(outcomes)
        for existing_digest, wrapper, stored_raw in events:
            stored_envelope = validate_envelope(
                (
                    json.dumps(
                        wrapper["outcome"],
                        ensure_ascii=False,
                        sort_keys=True,
                        separators=(",", ":"),
                    )
                    + "\n"
                ).encode("utf-8")
            )
            stored_turn = wrapper["turn_id"]
            stored_thread = wrapper["accepted_thread_id"]
            if not isinstance(stored_turn, str) or not IDENTITY_RE.fullmatch(stored_turn):
                fail("outcome ledger turn identity is invalid")
            if (
                stored_thread != stored_envelope["accepted_thread_id"]
                or stored_envelope["task_id"] != args.task_id
                or stored_envelope["generation"] > generation
                or canonical_event(stored_envelope, stored_thread, stored_turn) != stored_raw
            ):
                fail("outcome ledger authority is inconsistent")
            if hashlib.sha256(stored_raw).hexdigest() != existing_digest:
                fail("outcome ledger digest changed during validation")
        latest = current_latest(task_control)
        intent = read_intent(task_control)

        if intent is not None:
            if intent["digest"] != digest or intent["turn_id"] != args.turn_id:
                fail("a different task outcome publication is still unresolved")
            if latest not in (intent["previous_latest"], digest):
                fail("outcome intent no longer matches latest-outcome authority")

        for existing_digest, wrapper, _ in events:
            if wrapper["turn_id"] != args.turn_id:
                continue
            if existing_digest != digest:
                fail("the same native turn already has a conflicting outcome")
            if intent is None:
                # An exact historical or current replay is a no-op. Never move
                # latest-outcome backward or rewrite already durable artifacts.
                # This decision intentionally precedes every live worktree/Git
                # read because a broker or collector may already have advanced
                # or removed that mutable resource.
                return

        worktree, branch, manifest_base, repo = parse_manifest(
            task_control / "worktrees.txt", args.task_id
        )
        if paths_overlap(worktree, control) or paths_overlap(worktree, task_dir):
            fail("coordinator outcome destinations overlap the child worktree")

        # Revalidate Git only after serializing coordinator outcome mutation and
        # ruling out an immutable exact replay. The helper remains read-only
        # toward this worktree.
        validate_git_binding(envelope, worktree, branch, manifest_base, repo)
        validate_broker_receipt(task_dir, envelope, expected_branch=branch)
        validate_coordinator_verification(task_control, envelope)
        ensure_directory(outcomes)

        if intent is None:
            current_state = read_scalar(task_control / "state", "coordinator task state")
            task_state = read_scalar(task_dir / "state", "task state")
            if current_state != task_state:
                fail("coordinator and task state disagree")
            allowed = ALLOWED_TRANSITIONS.get(current_state)
            if allowed is None or envelope["kind"] not in allowed:
                fail(f"invalid task outcome transition: {current_state} -> {envelope['kind']}")
            publish_intent(
                task_control,
                digest=digest,
                previous_latest=latest,
                previous_state=current_state,
                turn_id=args.turn_id,
            )
        else:
            current_state = intent["previous_state"]

        prior_blocked = sum(
            1
            for existing_digest, wrapper, _ in events
            if existing_digest != digest
            and wrapper.get("outcome", {}).get("kind") == "blocked"
        )
        blocked_number = prior_blocked + 1 if envelope["kind"] == "blocked" else None
        artifacts = expected_artifacts(envelope, blocked_number)

        publish_immutable(outcomes / f"{digest}.json", event_raw)
        if envelope["kind"] == "ready_for_commit":
            publish_immutable(
                task_dir / f"COMMIT-REQUEST-{digest}.json",
                broker_request(envelope, worktree, digest),
            )
            if os.environ.get("ORC_TASK_OUTCOME_TEST_FAIL_AFTER_BROKER_REQUEST") == "1":
                fail("injected interruption after broker request publication")
        for name, data in artifacts.items():
            destination = task_dir / name
            if name.startswith("BLOCKED-"):
                publish_immutable(destination, data)
            else:
                atomic_replace(destination, data)
        state_data = (envelope["kind"] + "\n").encode("ascii")
        atomic_replace(task_dir / "state", state_data)
        atomic_replace(task_control / "state", state_data)
        atomic_replace(task_control / "latest-outcome", (digest + "\n").encode("ascii"))
        fsync_directory(task_dir)
        fsync_directory(task_control)
        clear_intent(task_control)
    finally:
        fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        os.close(lock_descriptor)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    record_parser = subparsers.add_parser("record")
    record_parser.add_argument("--control-dir", required=True)
    record_parser.add_argument("--task-dir", required=True)
    record_parser.add_argument("--task-id", required=True)
    record_parser.add_argument("--turn-id", required=True)
    record_parser.add_argument("--outcome-file", required=True)
    reopen_parser = subparsers.add_parser("reopen")
    reopen_parser.add_argument("--control-dir", required=True)
    reopen_parser.add_argument("--task-dir", required=True)
    reopen_parser.add_argument("--task-id", required=True)
    reopen_parser.add_argument("--parent-worktree", required=True)
    reopen_parser.add_argument("--expected-generation", required=True, type=int)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    control = canonical_directory(args.control_dir, "control-dir")
    try:
        lifecycle_descriptor = acquire_lifecycle_lock(control)
    except LifecycleLockError as error:
        fail(str(error))
    try:
        if args.operation == "record":
            record(args)
            return 0
        if args.operation == "reopen":
            reopen(args)
            return 0
        fail("unsupported operation")
    finally:
        release_lifecycle_lock(lifecycle_descriptor)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OutcomeError, OSError, UnicodeError, ValueError) as exc:
        sys.stderr.write(f"task-outcome: {exc}\n")
        raise SystemExit(1)
