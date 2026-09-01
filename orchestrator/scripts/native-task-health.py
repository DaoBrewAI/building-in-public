#!/usr/bin/env python3
"""Coordinator-owned native child bootstrap health and schedule-base authority."""

from __future__ import annotations

import argparse
import contextlib
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
from typing import Any, Iterator


PROTOCOL_VERSION = 1
ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
SHA_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
NONCE_RE = re.compile(r"^[0-9a-f]{64}$")
REJECTION_REASONS = {
    "unresolved_identity",
    "unreadable_identity",
    "missing_first_turn",
    "launch_failed",
    "wrong_title",
    "wrong_source",
    "wrong_project",
    "wrong_cwd",
    "wrong_tip",
}
ARCHIVE_KEYS = {
    "protocol_version", "provisional_id", "request_digest", "status", "thread_id"
}
REQUEST_KEYS = {
    "project_id",
    "protocol_version",
    "repo",
    "request_nonce",
    "schedule_base",
    "source_thread_id",
    "task_id",
    "task_state_dir",
    "title",
}
RECEIPT_KEYS = {
    "attempt",
    "bootstrap_state",
    "cwd",
    "list_visible",
    "observed_project_id",
    "observed_source_thread_id",
    "observed_title",
    "project_id",
    "protocol_version",
    "provisional_id",
    "repo",
    "request_digest",
    "request_nonce",
    "schedule_base",
    "source_thread_id",
    "status",
    "task_id",
    "task_state",
    "task_state_dir",
    "thread_id",
    "tip",
    "title",
}
REJECTED_ATTEMPT_KEYS = RECEIPT_KEYS | {"reason"}
BLOCKED_KEYS = {
    "attempts",
    "protocol_version",
    "reason",
    "request_digest",
    "request_nonce",
    "status",
    "task_id",
}


class HealthError(RuntimeError):
    pass


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


def strict_text(value: str, label: str, *, identity: bool = False) -> str:
    if not isinstance(value, str) or not value or "\x00" in value or "\n" in value or "\r" in value:
        raise HealthError(f"{label} is invalid")
    if identity and not ID_RE.fullmatch(value):
        raise HealthError(f"{label} is invalid")
    return value


def safe_existing_dir(path: str, label: str) -> str:
    if not os.path.isabs(path) or os.path.islink(path) or not os.path.isdir(path):
        raise HealthError(f"{label} is missing, relative, or symlinked")
    return os.path.realpath(path)


def safe_child_dir(parent: str, name: str, label: str) -> str:
    if not ID_RE.fullmatch(name):
        raise HealthError(f"{label} name is invalid")
    path = os.path.join(parent, name)
    if os.path.lexists(path):
        if os.path.islink(path) or not os.path.isdir(path):
            raise HealthError(f"{label} is unsafe")
    else:
        os.mkdir(path, 0o700)
        fsync_dir(parent)
    os.chmod(path, 0o700)
    return path


def safe_file(path: str, label: str, mode: int = 0o600) -> bytes:
    try:
        info = os.lstat(path)
    except FileNotFoundError as error:
        raise HealthError(f"{label} is missing") from error
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise HealthError(f"{label} is unsafe")
    if stat.S_IMODE(info.st_mode) != mode:
        raise HealthError(f"{label} has unsafe mode")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
            raise HealthError(f"{label} changed during read")
        chunks = []
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def read_json(path: str, label: str, keys: set[str] | None = None) -> tuple[dict[str, Any], bytes]:
    raw = safe_file(path, label)
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise HealthError(f"{label} is invalid JSON") from error
    if not isinstance(value, dict) or (keys is not None and set(value) != keys):
        raise HealthError(f"{label} schema is invalid")
    if canonical_bytes(value) != raw:
        raise HealthError(f"{label} is not canonical")
    return value, raw


def fsync_dir(path: str) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def publish_exclusive(path: str, data: bytes) -> None:
    parent = os.path.dirname(path)
    descriptor, temporary = tempfile.mkstemp(prefix=".native-health.", dir=parent)
    try:
        os.fchmod(descriptor, 0o600)
        os.write(descriptor, data)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise HealthError(f"authority already exists: {os.path.basename(path)}") from error
        fsync_dir(parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def publish_or_match(path: str, data: bytes, label: str) -> None:
    if os.path.lexists(path):
        if safe_file(path, label) != data:
            raise HealthError(f"{label} conflicts with frozen authority")
        return
    publish_exclusive(path, data)


@contextlib.contextmanager
def health_lock(health_dir: str) -> Iterator[None]:
    path = os.path.join(health_dir, ".lock")
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
        os.fsync(descriptor)
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def run_git(repo: str, *arguments: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", "-C", repo, *arguments],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if check and result.returncode != 0:
        raise HealthError("Git authority validation failed")
    return result.stdout.strip()


def repo_common(path: str) -> str:
    common = run_git(path, "rev-parse", "--git-common-dir")
    if not os.path.isabs(common):
        common = os.path.join(path, common)
    return os.path.realpath(common)


def canonical_repo(path: str) -> str:
    physical = safe_existing_dir(path, "repository")
    repo_common(physical)
    return physical


def resolve_commit(repo: str, value: str, label: str) -> str:
    if not SHA_RE.fullmatch(value):
        raise HealthError(f"{label} is not a full commit SHA")
    resolved = run_git(repo, "rev-parse", "--verify", f"{value}^{{commit}}")
    if resolved != value:
        raise HealthError(f"{label} does not resolve exactly")
    return value


def authority_paths(control: str, task_id: str, *, create: bool) -> tuple[str, str, str]:
    control = safe_existing_dir(control, "control directory")
    tasks = os.path.join(control, "tasks")
    if create:
        if os.path.lexists(tasks):
            if os.path.islink(tasks) or not os.path.isdir(tasks):
                raise HealthError("tasks authority directory is unsafe")
        else:
            os.mkdir(tasks, 0o700)
            fsync_dir(control)
        os.chmod(tasks, 0o700)
        task = safe_child_dir(tasks, task_id, "task authority")
        health = safe_child_dir(task, "native-health", "native health authority")
    else:
        tasks = safe_existing_dir(tasks, "tasks authority directory")
        task = safe_existing_dir(os.path.join(tasks, task_id), "task authority")
        if os.path.dirname(task) != tasks:
            raise HealthError("task authority escapes tasks directory")
        health = safe_existing_dir(os.path.join(task, "native-health"), "native health authority")
        if os.path.dirname(health) != task:
            raise HealthError("native health authority escapes task directory")
    return task, health, control


def validate_request(request: dict[str, Any]) -> None:
    if set(request) != REQUEST_KEYS or request["protocol_version"] != PROTOCOL_VERSION:
        raise HealthError("native health request schema is invalid")
    strict_text(request["task_id"], "task id", identity=True)
    strict_text(request["project_id"], "project id")
    strict_text(request["source_thread_id"], "source thread id")
    strict_text(request["title"], "task title")
    strict_text(request["repo"], "repository path")
    strict_text(request["task_state_dir"], "task state directory")
    if not SHA_RE.fullmatch(request["schedule_base"]):
        raise HealthError("schedule base is invalid")
    if not NONCE_RE.fullmatch(request["request_nonce"]):
        raise HealthError("request nonce is invalid")


def load_request(control: str, task_id: str) -> tuple[dict[str, Any], bytes, str, str]:
    task, health, _ = authority_paths(control, task_id, create=False)
    request, raw = read_json(os.path.join(health, "request.json"), "native health request", REQUEST_KEYS)
    validate_request(request)
    state_raw = safe_file(os.path.join(task, "task-state-dir"), "task state directory authority")
    if state_raw != (request["task_state_dir"] + "\n").encode("utf-8"):
        raise HealthError("task state directory authority conflicts with request")
    return request, raw, task, health


def command_begin(args: argparse.Namespace) -> int:
    strict_text(args.task_id, "task id", identity=True)
    strict_text(args.project_id, "project id")
    strict_text(args.source_thread_id, "source thread id")
    strict_text(args.title, "task title")
    task_state = safe_existing_dir(args.task_dir, "task state directory")
    repo = canonical_repo(args.repo)
    schedule_base = resolve_commit(repo, args.schedule_base, "schedule base")
    task, health, _ = authority_paths(args.control_dir, args.task_id, create=True)
    with health_lock(health):
        state_authority = os.path.join(task, "task-state-dir")
        expected_state_authority = (task_state + "\n").encode("utf-8")
        if os.path.lexists(state_authority):
            if safe_file(state_authority, "task state directory authority") != expected_state_authority:
                raise HealthError("task state directory authority conflicts with begin")
        request_path = os.path.join(health, "request.json")
        if os.path.lexists(request_path):
            existing, _ = read_json(request_path, "native health request", REQUEST_KEYS)
            validate_request(existing)
            comparable = dict(existing)
            comparable.pop("request_nonce")
            expected = {
                "protocol_version": PROTOCOL_VERSION,
                "task_id": args.task_id,
                "task_state_dir": task_state,
                "project_id": args.project_id,
                "source_thread_id": args.source_thread_id,
                "title": args.title,
                "repo": repo,
                "schedule_base": schedule_base,
            }
            if comparable != expected:
                raise HealthError("begin conflicts with frozen native health request")
            request = existing
        else:
            request = {
                "protocol_version": PROTOCOL_VERSION,
                "task_id": args.task_id,
                "task_state_dir": task_state,
                "project_id": args.project_id,
                "source_thread_id": args.source_thread_id,
                "title": args.title,
                "repo": repo,
                "schedule_base": schedule_base,
                "request_nonce": secrets.token_hex(32),
            }
            publish_exclusive(request_path, canonical_bytes(request))
        publish_or_match(
            state_authority,
            expected_state_authority,
            "task state directory authority",
        )
    print(os.path.join(health, "request.json"))
    return 0


def canonical_worktree(request: dict[str, Any], cwd: str) -> tuple[str, str | None]:
    physical = safe_existing_dir(cwd, "observed cwd")
    try:
        if repo_common(physical) != repo_common(request["repo"]):
            return physical, "wrong_cwd"
        registrations = [
            line.removeprefix("worktree ")
            for line in run_git(request["repo"], "worktree", "list", "--porcelain").splitlines()
            if line.startswith("worktree ")
        ]
        if sum(os.path.realpath(item) == physical for item in registrations) != 1:
            return physical, "wrong_cwd"
        if run_git(physical, "symbolic-ref", "--quiet", "--short", "HEAD", check=False):
            return physical, "wrong_cwd"
        if run_git(physical, "status", "--porcelain", "--untracked-files=all"):
            return physical, "wrong_cwd"
        if run_git(physical, "rev-parse", "--verify", "HEAD^{commit}") != request["schedule_base"]:
            return physical, "wrong_tip"
    except HealthError:
        return physical, "wrong_cwd"
    return physical, None


def observation_values(args: argparse.Namespace, request: dict[str, Any]) -> dict[str, Any]:
    return {
        "provisional_id": args.provisional_id,
        "thread_id": args.thread_id,
        "list_visible": args.list_visible == "true" if args.list_visible is not None else None,
        "observed_title": args.observed_title,
        "bootstrap_state": args.bootstrap_state,
        "task_state": args.task_state,
        "cwd": os.path.realpath(args.cwd) if args.cwd and os.path.isabs(args.cwd) else args.cwd,
        "tip": args.tip,
        "observed_project_id": args.observed_project_id,
        "observed_source_thread_id": args.observed_source_thread_id,
    }


def accepted_replay_matches(receipt: dict[str, Any], args: argparse.Namespace, request: dict[str, Any]) -> bool:
    values = observation_values(args, request)
    return (
        receipt["provisional_id"] == values["provisional_id"]
        and receipt["thread_id"] == values["thread_id"]
        and receipt["list_visible"] == values["list_visible"]
        and receipt["observed_title"] == values["observed_title"]
        and receipt["bootstrap_state"] == values["bootstrap_state"]
        and receipt["task_state"] == values["task_state"]
        and receipt["cwd"] == values["cwd"]
        and receipt["tip"] == values["tip"]
        and receipt["observed_project_id"] == values["observed_project_id"]
        and receipt["observed_source_thread_id"] == values["observed_source_thread_id"]
    )


def validate_receipt(receipt: dict[str, Any], request: dict[str, Any], request_raw: bytes) -> None:
    if set(receipt) != RECEIPT_KEYS or receipt["protocol_version"] != PROTOCOL_VERSION:
        raise HealthError("accepted health receipt schema is invalid")
    if receipt["status"] != "accepted" or receipt["attempt"] not in {1, 2}:
        raise HealthError("accepted health receipt status is invalid")
    for key in (
        "task_id", "task_state_dir", "project_id", "source_thread_id", "title",
        "repo", "schedule_base", "request_nonce",
    ):
        if receipt[key] != request[key]:
            raise HealthError(f"accepted health receipt changes request {key}")
    if receipt["request_digest"] != hashlib.sha256(request_raw).hexdigest():
        raise HealthError("accepted health receipt request digest is invalid")
    if receipt["list_visible"] is not True or receipt["bootstrap_state"] != "completed" or receipt["task_state"] != "idle":
        raise HealthError("accepted health receipt lacks required native health")
    if receipt["observed_title"] != request["title"]:
        raise HealthError("accepted health title is invalid")
    if receipt["observed_project_id"] != request["project_id"]:
        raise HealthError("accepted health project projection is invalid")
    if receipt["observed_source_thread_id"] not in {None, request["source_thread_id"]}:
        raise HealthError("accepted health source projection is invalid")
    strict_text(receipt["provisional_id"], "provisional id")
    strict_text(receipt["thread_id"], "thread id")
    strict_text(receipt["cwd"], "accepted cwd")
    if receipt["tip"] != request["schedule_base"]:
        raise HealthError("accepted health tip is invalid")


def validate_rejected_attempt(
    record: dict[str, Any], request: dict[str, Any], request_raw: bytes, number: int
) -> None:
    if set(record) != REJECTED_ATTEMPT_KEYS or record["protocol_version"] != PROTOCOL_VERSION:
        raise HealthError("rejected native health attempt schema is invalid")
    if record["status"] != "rejected" or record["attempt"] != number:
        raise HealthError("rejected native health attempt status is invalid")
    if record["reason"] not in REJECTION_REASONS:
        raise HealthError("rejected native health reason is invalid")
    for key in (
        "task_id", "task_state_dir", "project_id", "source_thread_id", "title",
        "repo", "schedule_base", "request_nonce",
    ):
        if record[key] != request[key]:
            raise HealthError(f"rejected native health attempt changes request {key}")
    if record["request_digest"] != hashlib.sha256(request_raw).hexdigest():
        raise HealthError("rejected native health attempt request digest is invalid")
    strict_text(record["provisional_id"], "rejected provisional id")
    if record["thread_id"] is not None:
        strict_text(record["thread_id"], "rejected thread id")


def blocked_record(request: dict[str, Any], request_raw: bytes, reason: str) -> dict[str, Any]:
    return {
        "protocol_version": PROTOCOL_VERSION,
        "request_digest": hashlib.sha256(request_raw).hexdigest(),
        "request_nonce": request["request_nonce"],
        "status": "blocked",
        "task_id": request["task_id"],
        "attempts": 2,
        "reason": reason,
    }


def publish_or_validate_blocked(
    path: str, request: dict[str, Any], request_raw: bytes, reason: str
) -> None:
    expected = blocked_record(request, request_raw, reason)
    if os.path.lexists(path):
        actual, _ = read_json(path, "native health blocked receipt", BLOCKED_KEYS)
        if actual != expected:
            raise HealthError("native health blocked receipt conflicts with attempts")
        return
    publish_exclusive(path, canonical_bytes(expected))


def derive_rejection(args: argparse.Namespace, request: dict[str, Any]) -> tuple[str | None, str | None]:
    if args.list_visible is None:
        raise HealthError("structured observation lacks list visibility")
    if args.list_visible == "false":
        if args.bootstrap_state not in {"missing", "failed"} or args.task_state != "failed":
            raise HealthError("unreadable launch requires failed/missing bootstrap and failed task state")
        return "unreadable_identity", args.cwd
    required = {
        "observed title": args.observed_title,
        "bootstrap state": args.bootstrap_state,
        "task state": args.task_state,
        "cwd": args.cwd,
        "tip": args.tip,
    }
    missing = [label for label, value in required.items() if value is None]
    if missing:
        raise HealthError("healthy observation lacks " + ", ".join(missing))
    if not args.thread_id:
        return "unresolved_identity", args.cwd
    if args.observed_title != request["title"]:
        return "wrong_title", args.cwd
    if args.observed_project_id != request["project_id"]:
        return "wrong_project", args.cwd
    if args.observed_source_thread_id is not None and args.observed_source_thread_id != request["source_thread_id"]:
        return "wrong_source", args.cwd
    if args.bootstrap_state != "completed":
        return ("missing_first_turn" if args.bootstrap_state == "missing" else "launch_failed"), args.cwd
    if args.task_state != "idle":
        return "launch_failed", args.cwd
    if args.tip != request["schedule_base"]:
        return "wrong_tip", args.cwd
    try:
        physical, reason = canonical_worktree(request, args.cwd)
    except HealthError:
        return "wrong_cwd", args.cwd
    return reason, physical


def attempt_record(
    request: dict[str, Any], request_raw: bytes, args: argparse.Namespace,
    attempt: int, status: str, cwd: str | None,
) -> dict[str, Any]:
    values = observation_values(args, request)
    values["cwd"] = cwd
    return {
        "protocol_version": PROTOCOL_VERSION,
        "attempt": attempt,
        "request_digest": hashlib.sha256(request_raw).hexdigest(),
        "request_nonce": request["request_nonce"],
        "task_id": request["task_id"],
        "task_state_dir": request["task_state_dir"],
        "project_id": request["project_id"],
        "source_thread_id": request["source_thread_id"],
        "title": request["title"],
        "repo": request["repo"],
        "schedule_base": request["schedule_base"],
        "status": status,
        **values,
    }


def command_observe(args: argparse.Namespace) -> int:
    strict_text(args.task_id, "task id", identity=True)
    strict_text(args.provisional_id, "provisional id")
    request, request_raw, _, health = load_request(args.control_dir, args.task_id)
    with health_lock(health):
        accepted_path = os.path.join(health, "accepted.json")
        if os.path.lexists(accepted_path):
            receipt, _ = read_json(accepted_path, "accepted native health receipt", RECEIPT_KEYS)
            validate_receipt(receipt, request, request_raw)
            if not accepted_replay_matches(receipt, args, request):
                raise HealthError("accepted native health authority cannot be replaced")
            print(accepted_path)
            return 0
        blocked_path = os.path.join(health, "blocked.json")
        attempts = []
        for number in (1, 2):
            path = os.path.join(health, f"attempt-{number}.json")
            if os.path.lexists(path):
                record, _ = read_json(path, f"native health attempt {number}")
                if record.get("status") == "accepted":
                    if set(record) != RECEIPT_KEYS or record.get("attempt") != number:
                        raise HealthError("accepted native health attempt schema is invalid")
                    validate_receipt(record, request, request_raw)
                else:
                    validate_rejected_attempt(record, request, request_raw, number)
                attempts.append((number, record, path))
            elif number == 1 and os.path.lexists(os.path.join(health, "attempt-2.json")):
                raise HealthError("native health attempts are not sequential")
        if attempts and attempts[-1][1].get("status") == "accepted":
            record = attempts[-1][1]
            if set(record) != RECEIPT_KEYS:
                raise HealthError("accepted native health attempt schema is invalid")
            validate_receipt(record, request, request_raw)
            if not accepted_replay_matches(record, args, request):
                raise HealthError("accepted native health attempt cannot be replaced")
            publish_exclusive(accepted_path, canonical_bytes(record))
            print(accepted_path)
            return 0
        reason, cwd = derive_rejection(args, request)
        status = "rejected" if reason else "accepted"
        if attempts and attempts[-1][1].get("status") == "rejected":
            replay = attempt_record(
                request, request_raw, args, attempts[-1][0], status, cwd
            )
            if reason:
                replay["reason"] = reason
            if replay == attempts[-1][1]:
                if len(attempts) == 2:
                    publish_or_validate_blocked(
                        blocked_path, request, request_raw, attempts[-1][1]["reason"]
                    )
                print(f"rejected {reason}", file=sys.stderr)
                return 2
            if attempts[-1][1]["provisional_id"] == args.provisional_id:
                raise HealthError("one provisional task cannot consume two health attempts")
            if len(attempts) == 1:
                if args.previous_archive_receipt is None:
                    raise HealthError("replacement requires the rejected provisional archive receipt")
                archive, archive_raw = read_json(
                    args.previous_archive_receipt,
                    "rejected provisional archive receipt",
                    ARCHIVE_KEYS,
                )
                expected_thread = attempts[0][1]["thread_id"] or attempts[0][1]["provisional_id"]
                if (
                    archive["protocol_version"] != PROTOCOL_VERSION
                    or archive["status"] not in {"archived", "already_archived"}
                    or archive["provisional_id"] != attempts[0][1]["provisional_id"]
                    or archive["thread_id"] != expected_thread
                    or archive["request_digest"] != hashlib.sha256(request_raw).hexdigest()
                    or canonical_bytes(archive) != archive_raw
                ):
                    raise HealthError("rejected provisional archive receipt is invalid")
                publish_or_match(
                    os.path.join(health, "attempt-1-archive.json"),
                    archive_raw,
                    "rejected provisional archive receipt",
                )
        if len(attempts) >= 2:
            publish_or_validate_blocked(
                blocked_path, request, request_raw, attempts[-1][1]["reason"]
            )
            raise HealthError("native child replacement is exhausted")
        if os.path.lexists(blocked_path):
            raise HealthError("native child replacement is already blocked")
        attempt = len(attempts) + 1
        record = attempt_record(request, request_raw, args, attempt, status, cwd)
        if reason:
            record["reason"] = reason
        attempt_path = os.path.join(health, f"attempt-{attempt}.json")
        publish_exclusive(attempt_path, canonical_bytes(record))
        if status == "accepted":
            if set(record) != RECEIPT_KEYS:
                raise HealthError("accepted native health attempt schema is invalid")
            validate_receipt(record, request, request_raw)
            publish_exclusive(accepted_path, canonical_bytes(record))
            print(accepted_path)
            return 0
        if attempt == 2:
            publish_or_validate_blocked(blocked_path, request, request_raw, reason)
        print(f"rejected {reason}", file=sys.stderr)
        return 2


def command_verify_adoption(args: argparse.Namespace) -> int:
    strict_text(args.task_id, "task id", identity=True)
    strict_text(args.thread_id, "thread id")
    request, request_raw, _, health = load_request(args.control_dir, args.task_id)
    task_state = safe_existing_dir(args.task_dir, "task state directory")
    repo = canonical_repo(args.repo)
    worktree = safe_existing_dir(args.worktree, "native child worktree")
    if request["task_state_dir"] != task_state:
        raise HealthError("adoption task-state directory differs from frozen request")
    if request["repo"] != repo:
        raise HealthError("adoption repository differs from frozen request")
    receipt, receipt_raw = read_json(
        os.path.join(health, "accepted.json"), "accepted native health receipt", RECEIPT_KEYS
    )
    validate_receipt(receipt, request, request_raw)
    attempt_raw = safe_file(
        os.path.join(health, f"attempt-{receipt['attempt']}.json"),
        "accepted native health attempt",
    )
    if attempt_raw != receipt_raw:
        raise HealthError("accepted native health receipt lacks its exact durable attempt")
    if receipt["thread_id"] != args.thread_id:
        raise HealthError("adoption thread differs from accepted native health")
    if receipt["cwd"] != worktree:
        raise HealthError("adoption worktree differs from accepted native health")
    current, reason = canonical_worktree(request, worktree)
    if reason is not None or current != receipt["cwd"]:
        raise HealthError("accepted native worktree no longer satisfies health")
    live_parent_tip = resolve_commit(repo, args.live_parent_tip, "live parent tip")
    if subprocess.run(
        ["git", "-C", repo, "merge-base", "--is-ancestor", request["schedule_base"], live_parent_tip],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode != 0:
        raise HealthError("live parent tip does not descend from frozen schedule base")
    print(request["schedule_base"])
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    sub = result.add_subparsers(dest="command", required=True)
    begin = sub.add_parser("begin")
    begin.add_argument("--control-dir", required=True)
    begin.add_argument("--task-dir", required=True)
    begin.add_argument("--task-id", required=True)
    begin.add_argument("--project-id", required=True)
    begin.add_argument("--source-thread-id", required=True)
    begin.add_argument("--title", required=True)
    begin.add_argument("--repo", required=True)
    begin.add_argument("--schedule-base", required=True)
    begin.set_defaults(handler=command_begin)

    observe = sub.add_parser("observe")
    observe.add_argument("--control-dir", required=True)
    observe.add_argument("--task-id", required=True)
    observe.add_argument("--provisional-id", required=True)
    observe.add_argument("--thread-id")
    observe.add_argument("--list-visible", choices=("true", "false"))
    observe.add_argument("--observed-title")
    observe.add_argument("--bootstrap-state", choices=("completed", "missing", "failed"))
    observe.add_argument("--task-state", choices=("idle", "busy", "failed"))
    observe.add_argument("--cwd")
    observe.add_argument("--tip")
    observe.add_argument("--observed-project-id")
    observe.add_argument("--observed-source-thread-id")
    observe.add_argument("--previous-archive-receipt")
    observe.set_defaults(handler=command_observe)

    verify = sub.add_parser("verify-adoption")
    verify.add_argument("--control-dir", required=True)
    verify.add_argument("--task-dir", required=True)
    verify.add_argument("--task-id", required=True)
    verify.add_argument("--thread-id", required=True)
    verify.add_argument("--repo", required=True)
    verify.add_argument("--worktree", required=True)
    verify.add_argument("--live-parent-tip", required=True)
    verify.set_defaults(handler=command_verify_adoption)
    return result


def main() -> int:
    os.umask(0o077)
    args = parser().parse_args()
    try:
        return args.handler(args)
    except HealthError as error:
        print(f"native-task-health: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
