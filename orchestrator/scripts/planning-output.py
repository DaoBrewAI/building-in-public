#!/usr/bin/env python3
"""Authorize and import one Codex planning/review outcome per native turn."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

from coordinator_lifecycle_lock import (
    LifecycleLockError,
    acquire_lifecycle_lock,
    release_lifecycle_lock,
)


STAGING_NAME = ".orchestrator-planning-output"
AUTHORITY_NAME = "planning-stage-authority.json"
INTENT_NAME = "planning-stage-import-intent.json"
RECEIPT_PREFIX = "planning-stage-receipt-"
MANIFEST_KEYS = {
    "protocol_version",
    "stage",
    "kind",
    "accepted_thread_id",
    "worktree",
    "tip",
    "stage_nonce",
    "artifacts",
}
AUTHORITY_KEYS = {
    "protocol_version",
    "stage",
    "stage_nonce",
    "expected_state",
    "accepted_thread_id",
    "worktree",
    "tip",
}
INTENT_KEYS = {
    *AUTHORITY_KEYS,
    "kind",
    "result_state",
    "artifacts",
    "artifact_sha256",
}
RECEIPT_KEYS = {*INTENT_KEYS, "status"}
PLAN_ARTIFACTS = ["design.md", "plan.md", "plan-review.html", "task-dag.json"]
REVIEW_ARTIFACTS = ["report.md"]
SHA_RE = re.compile(r"[0-9a-f]{40,64}")
NONCE_RE = re.compile(r"[0-9a-f]{64}")
BLOCKED_RE = re.compile(r"BLOCKED-([1-9][0-9]*)\.md")
ALLOWED_EXPECTED_STATES = {
    "plan": {"pending", "running", "blocked", "planned"},
    "review": {"running", "executed", "blocked", "rework", "review"},
}


class ContractError(RuntimeError):
    pass


def run_git(worktree: Path, *arguments: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(worktree), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ContractError(f"Git authority check failed: {detail}")
    return result.stdout


def exact_directory(raw: str, label: str) -> Path:
    path = Path(raw)
    if not path.is_absolute():
        raise ContractError(f"{label} must be absolute")
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise ContractError(f"{label} is missing") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ContractError(f"{label} must be a real directory")
    physical = Path(os.path.realpath(path))
    if physical != path:
        raise ContractError(f"{label} must use its physical path")
    return physical


def stable_regular_bytes(path: Path, label: str) -> tuple[bytes, tuple[int, ...]]:
    try:
        before = path.lstat()
    except FileNotFoundError as error:
        raise ContractError(f"{label} is missing") from error
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise ContractError(f"{label} must be a regular file")
    data = path.read_bytes()
    after = path.lstat()
    snapshot = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
    )
    after_snapshot = (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
    )
    if snapshot != after_snapshot:
        raise ContractError(f"{label} changed while being read")
    return data, snapshot


def exact_scalar(path: Path, label: str) -> str:
    data, _ = stable_regular_bytes(path, label)
    if not data.endswith(b"\n") or data.count(b"\n") != 1 or b"\r" in data or b"\0" in data:
        raise ContractError(f"{label} is not one canonical line")
    try:
        value = data[:-1].decode("utf-8")
    except UnicodeDecodeError as error:
        raise ContractError(f"{label} is not UTF-8") from error
    if not value or "\t" in value:
        raise ContractError(f"{label} is empty or malformed")
    return value


def parse_manifest(staging: Path) -> dict[str, object]:
    raw, _ = stable_regular_bytes(staging / "manifest.json", "planning manifest")
    if not raw.endswith(b"\n") or raw.count(b"\n") != 1:
        raise ContractError("planning manifest must be one canonical JSON line")
    try:
        manifest = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ContractError("planning manifest is invalid JSON") from error
    if not isinstance(manifest, dict) or set(manifest) != MANIFEST_KEYS:
        raise ContractError("planning manifest has a noncanonical schema")
    canonical = (json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if raw != canonical:
        raise ContractError("planning manifest is not canonical JSON")
    if manifest.get("protocol_version") != 1:
        raise ContractError("planning protocol version is unsupported")
    return manifest


def canonical_json(payload: dict[str, object]) -> bytes:
    return (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode()


def parse_canonical_json(path: Path, label: str, keys: set[str]) -> dict[str, object]:
    raw, _ = stable_regular_bytes(path, label)
    if not raw.endswith(b"\n") or raw.count(b"\n") != 1:
        raise ContractError(f"{label} must be one canonical JSON line")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ContractError(f"{label} is invalid JSON") from error
    if not isinstance(payload, dict) or set(payload) != keys:
        raise ContractError(f"{label} has a noncanonical schema")
    if raw != canonical_json(payload):
        raise ContractError(f"{label} is not canonical JSON")
    if payload.get("protocol_version") != 1:
        raise ContractError(f"{label} protocol version is unsupported")
    return payload


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def expected_artifacts(stage: str, kind: str, mission: Path, declared: object) -> tuple[list[str], str]:
    if not isinstance(declared, list) or any(not isinstance(item, str) for item in declared):
        raise ContractError("planning artifacts must be an ordered string list")
    if stage == "plan" and kind == "planned":
        expected = PLAN_ARTIFACTS
        state = "planned"
    elif stage == "review" and kind in {"review", "rework"}:
        expected = REVIEW_ARTIFACTS
        state = kind
    elif kind == "blocked" and stage in {"plan", "review"}:
        existing: list[int] = []
        for candidate in mission.glob("BLOCKED-*.md"):
            if candidate.is_symlink() or not candidate.is_file():
                raise ContractError("existing BLOCKED evidence is unsafe")
            match = BLOCKED_RE.fullmatch(candidate.name)
            if match is None:
                raise ContractError("existing BLOCKED evidence is malformed")
            existing.append(int(match.group(1)))
        existing.sort()
        if existing != list(range(1, len(existing) + 1)):
            raise ContractError("existing BLOCKED sequence is not contiguous")
        expected = [f"BLOCKED-{len(existing) + 1}.md"]
        state = "blocked"
    else:
        raise ContractError("stage and outcome kind are incompatible")
    if declared != expected:
        raise ContractError("artifact list does not match the exact stage schema")
    return expected, state


def verify_worktree(worktree: Path, expected_tip: str, allowed_output_names: set[str]) -> None:
    if SHA_RE.fullmatch(expected_tip) is None:
        raise ContractError("expected planning tip is malformed")
    live_tip = run_git(worktree, "rev-parse", "--verify", "HEAD^{commit}").decode().strip()
    if live_tip != expected_tip:
        raise ContractError("planning worktree moved from its exact stage-entry tip")
    status = run_git(worktree, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    for record in status.split(b"\0"):
        if not record:
            continue
        if len(record) < 4 or record[:2] != b"??" or record[2:3] != b" ":
            raise ContractError("tracked product drift exists in the planning worktree")
        try:
            relative = record[3:].decode("utf-8")
        except UnicodeDecodeError as error:
            raise ContractError("planning worktree status contains a non-UTF-8 path") from error
        if not any(relative.startswith(name + "/") for name in allowed_output_names):
            raise ContractError("untracked output exists outside exact planning staging")


def read_exact_staging(staging: Path, expected: list[str]) -> dict[str, bytes]:
    try:
        metadata = staging.lstat()
    except FileNotFoundError as error:
        raise ContractError("exact planning staging directory is missing") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ContractError("exact planning staging directory is unsafe")
    expected_names = {"manifest.json", *expected}
    actual_names = set(os.listdir(staging))
    if actual_names != expected_names:
        raise ContractError("planning staging contains missing or extra output")
    output: dict[str, bytes] = {}
    for name in expected:
        data, _ = stable_regular_bytes(staging / name, f"planning artifact {name}")
        output[name] = data
    return output


def sync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_synced(path: Path, data: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        written = 0
        while written < len(data):
            written += os.write(descriptor, data[written:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def create_canonical_json(path: Path, payload: dict[str, object], label: str) -> None:
    """Atomically publish a canonical no-clobber authority file."""
    temporary = path.parent / f".{path.name}.tmp.{os.getpid()}.{secrets.token_hex(8)}"
    write_synced(temporary, canonical_json(payload))
    try:
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise ContractError(f"{label} already exists") from error
        sync_directory(path.parent)
    finally:
        if os.path.lexists(temporary):
            temporary.unlink()
            sync_directory(path.parent)


def remove_canonical_json(
    path: Path, payload: dict[str, object], label: str, keys: set[str]
) -> None:
    if parse_canonical_json(path, label, keys) != payload:
        raise ContractError(f"{label} changed before consumption")
    path.unlink()
    sync_directory(path.parent)


def publish_batch(mission: Path, artifacts: dict[str, bytes], state: str) -> None:
    destinations = dict(artifacts)
    destinations["state"] = (state + "\n").encode()
    fail_after_raw = os.environ.get("ORC_PLANNING_OUTPUT_TEST_FAIL_PUBLISH_AFTER", "")
    if fail_after_raw:
        if not fail_after_raw.isdigit() or int(fail_after_raw) <= 0:
            raise ContractError("invalid planning-output test failure injection")
        fail_after = int(fail_after_raw)
    else:
        fail_after = 0
    for name in destinations:
        target = mission / name
        if os.path.lexists(target):
            metadata = target.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                raise ContractError(f"mission destination is unsafe: {name}")
    transaction = Path(tempfile.mkdtemp(prefix=".planning-output-import.", dir=mission))
    incoming = transaction / "incoming"
    backups = transaction / "backups"
    incoming.mkdir(mode=0o700)
    backups.mkdir(mode=0o700)
    for name, data in destinations.items():
        write_synced(incoming / name, data)
    sync_directory(incoming)
    sync_directory(transaction)

    published: list[str] = []
    backed_up: list[str] = []
    try:
        for index, name in enumerate(destinations, start=1):
            target = mission / name
            backup = backups / name
            if os.path.lexists(target):
                metadata = target.lstat()
                if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                    raise ContractError(f"mission destination changed: {name}")
                os.replace(target, backup)
                backed_up.append(name)
            os.replace(incoming / name, target)
            published.append(name)
            sync_directory(mission)
            if fail_after == index:
                raise ContractError("injected planning output publication failure")
        sync_directory(mission)
    except BaseException:
        for name in reversed(published):
            target = mission / name
            if os.path.lexists(target):
                metadata = target.lstat()
                if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                    raise ContractError(f"cannot safely roll back changed mission destination: {name}")
                target.unlink()
        for name in reversed(backed_up):
            backup = backups / name
            if backup.exists():
                os.replace(backup, mission / name)
        sync_directory(mission)
        shutil.rmtree(transaction)
        raise
    shutil.rmtree(transaction)
    sync_directory(mission)


def remove_staging(
    staging: Path, expected: list[str], *, allow_partial: bool, inject_failure: bool
) -> None:
    expected_names = {"manifest.json", *expected}
    if not os.path.lexists(staging):
        if allow_partial:
            return
        raise ContractError("planning staging disappeared before cleanup")
    metadata = staging.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ContractError("planning staging became unsafe before cleanup")
    actual_names = set(os.listdir(staging))
    if (allow_partial and not actual_names.issubset(expected_names)) or (
        not allow_partial and actual_names != expected_names
    ):
        raise ContractError("planning staging changed before cleanup")
    for name in actual_names:
        path = staging / name
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise ContractError("planning staging became unsafe before cleanup")
    fail_after_raw = os.environ.get("ORC_PLANNING_OUTPUT_TEST_FAIL_CLEANUP_AFTER", "")
    if fail_after_raw:
        if not fail_after_raw.isdigit() or int(fail_after_raw) <= 0:
            raise ContractError("invalid planning-output cleanup failure injection")
        fail_after = int(fail_after_raw)
    else:
        fail_after = 0
    for index, name in enumerate(sorted(actual_names), start=1):
        (staging / name).unlink()
        sync_directory(staging)
        if inject_failure and fail_after == index:
            raise ContractError("injected planning output cleanup failure")
    staging.rmdir()
    sync_directory(staging.parent)


def validate_authority(
    authority: dict[str, object],
    arguments: argparse.Namespace,
    thread_id: str,
    worktree: Path,
) -> None:
    if authority["stage"] != arguments.stage:
        raise ContractError("planning stage authority differs from requested stage")
    if authority["accepted_thread_id"] != thread_id:
        raise ContractError("planning stage authority differs from accepted thread")
    if authority["worktree"] != str(worktree):
        raise ContractError("planning stage authority differs from exact worktree")
    if authority["tip"] != arguments.expected_tip:
        raise ContractError("planning stage authority differs from exact tip")
    if not isinstance(authority["stage_nonce"], str) or NONCE_RE.fullmatch(
        authority["stage_nonce"]
    ) is None:
        raise ContractError("planning stage authority nonce is malformed")
    if not isinstance(authority["expected_state"], str) or authority[
        "expected_state"
    ] not in ALLOWED_EXPECTED_STATES[arguments.stage]:
        raise ContractError("planning stage authority expected state is invalid")


def validate_manifest_authority(
    manifest: dict[str, object], authority: dict[str, object]
) -> None:
    for key in ("stage", "stage_nonce", "accepted_thread_id", "worktree", "tip"):
        if manifest[key] != authority[key]:
            raise ContractError(f"planning manifest {key} differs from stage authority")


def validate_intent(
    intent: dict[str, object], authority: dict[str, object], manifest: dict[str, object]
) -> None:
    for key in AUTHORITY_KEYS:
        if intent[key] != authority[key]:
            raise ContractError(f"planning import intent {key} differs from stage authority")
    if (
        intent["kind"] != manifest["kind"]
        or intent["artifacts"] != manifest["artifacts"]
    ):
        raise ContractError("planning import intent differs from the staged outcome")
    validate_outcome_fields(
        authority["stage"],
        intent["kind"],
        intent["artifacts"],
        intent["result_state"],
        intent["artifact_sha256"],
    )


def validate_outcome_fields(
    stage: object,
    kind: object,
    artifacts: object,
    result_state: object,
    hashes: object,
) -> None:
    if not isinstance(stage, str) or not isinstance(kind, str):
        raise ContractError("durable planning outcome stage or kind is malformed")
    if not isinstance(artifacts, list) or any(
        not isinstance(name, str) for name in artifacts
    ):
        raise ContractError("durable planning artifact list is malformed")
    if stage == "plan" and kind == "planned":
        expected_artifact_names = PLAN_ARTIFACTS
        expected_state = "planned"
    elif stage == "review" and kind in {"review", "rework"}:
        expected_artifact_names = REVIEW_ARTIFACTS
        expected_state = kind
    elif stage in {"plan", "review"} and kind == "blocked":
        if len(artifacts) != 1 or BLOCKED_RE.fullmatch(artifacts[0]) is None:
            raise ContractError("durable BLOCKED planning artifact is malformed")
        expected_artifact_names = artifacts
        expected_state = "blocked"
    else:
        raise ContractError("durable planning stage and outcome kind are incompatible")
    if artifacts != expected_artifact_names or result_state != expected_state:
        raise ContractError("durable planning outcome schema is inconsistent")
    if not isinstance(hashes, dict) or set(hashes) != set(artifacts):
        raise ContractError("planning import intent artifact hashes are malformed")
    if any(
        not isinstance(value, str) or NONCE_RE.fullmatch(value) is None
        for value in hashes.values()
    ):
        raise ContractError("planning import intent artifact digest is malformed")


def verify_artifact_hashes(artifacts: dict[str, bytes], hashes: object) -> None:
    if not isinstance(hashes, dict) or {
        name: digest(data) for name, data in artifacts.items()
    } != hashes:
        raise ContractError("planning artifacts differ from the durable import intent")


def verify_published(
    mission: Path, artifact_hashes: object, result_state: object
) -> None:
    if (
        not isinstance(result_state, str)
        or exact_scalar(mission / "state", "mission state") != result_state
    ):
        raise ContractError("mission state differs from the durable planning result")
    if not isinstance(artifact_hashes, dict):
        raise ContractError("durable planning artifact hashes are malformed")
    for name, expected_digest in artifact_hashes.items():
        if not isinstance(name, str) or not isinstance(expected_digest, str):
            raise ContractError("durable planning artifact hashes are malformed")
        data, _ = stable_regular_bytes(mission / name, f"published planning artifact {name}")
        if digest(data) != expected_digest:
            raise ContractError(f"published planning artifact changed: {name}")


def begin_stage(arguments: argparse.Namespace) -> None:
    mission = exact_directory(arguments.mission_dir, "mission directory")
    control = exact_directory(arguments.control_dir, "control directory")
    worktree = exact_directory(arguments.worktree, "planning worktree")
    thread_id = exact_scalar(control / "planning-thread-id", "planning thread authority")
    if arguments.expected_state not in ALLOWED_EXPECTED_STATES[arguments.stage]:
        raise ContractError("requested planning stage expected state is invalid")
    if exact_scalar(mission / "state", "mission state") != arguments.expected_state:
        raise ContractError("mission state differs from requested planning stage entry")
    if SHA_RE.fullmatch(arguments.expected_tip) is None:
        raise ContractError("expected planning tip is malformed")

    authority_path = control / AUTHORITY_NAME
    if os.path.lexists(authority_path):
        authority = parse_canonical_json(
            authority_path, "planning stage authority", AUTHORITY_KEYS
        )
        validate_authority(authority, arguments, thread_id, worktree)
        if authority["expected_state"] != arguments.expected_state:
            raise ContractError("active planning stage has different expected state")
        print(canonical_json(authority).decode(), end="")
        return

    if os.path.lexists(control / INTENT_NAME):
        raise ContractError("planning import intent exists without active stage authority")
    if os.path.lexists(worktree / STAGING_NAME):
        raise ContractError("planning staging exists without active stage authority")
    if any(worktree.glob(STAGING_NAME + ".consumed-*")):
        raise ContractError("unrecovered planning staging tombstone exists")
    verify_worktree(worktree, arguments.expected_tip, set())
    authority: dict[str, object] = {
        "protocol_version": 1,
        "stage": arguments.stage,
        "stage_nonce": secrets.token_hex(32),
        "expected_state": arguments.expected_state,
        "accepted_thread_id": thread_id,
        "worktree": str(worktree),
        "tip": arguments.expected_tip,
    }
    create_canonical_json(authority_path, authority, "planning stage authority")
    print(canonical_json(authority).decode(), end="")


def import_output(arguments: argparse.Namespace) -> None:
    mission = exact_directory(arguments.mission_dir, "mission directory")
    control = exact_directory(arguments.control_dir, "control directory")
    worktree = exact_directory(arguments.worktree, "planning worktree")
    thread_id = exact_scalar(control / "planning-thread-id", "planning thread authority")
    authority_path = control / AUTHORITY_NAME
    authority = parse_canonical_json(
        authority_path, "planning stage authority", AUTHORITY_KEYS
    )
    validate_authority(authority, arguments, thread_id, worktree)
    nonce = authority["stage_nonce"]
    assert isinstance(nonce, str)
    staging = worktree / STAGING_NAME
    tombstone = worktree / f"{STAGING_NAME}.consumed-{nonce}"
    intent_path = control / INTENT_NAME
    receipt_path = control / f"{RECEIPT_PREFIX}{nonce}.json"

    if os.path.lexists(receipt_path):
        receipt = parse_canonical_json(
            receipt_path, "planning stage receipt", RECEIPT_KEYS
        )
        if receipt["status"] != "imported":
            raise ContractError("planning stage receipt status is invalid")
        for key in AUTHORITY_KEYS:
            if receipt[key] != authority[key]:
                raise ContractError(f"planning stage receipt {key} differs from authority")
        validate_outcome_fields(
            receipt["stage"],
            receipt["kind"],
            receipt["artifacts"],
            receipt["result_state"],
            receipt["artifact_sha256"],
        )
        verify_published(mission, receipt["artifact_sha256"], receipt["result_state"])
        if os.path.lexists(staging):
            raise ContractError("fresh planning staging appeared during receipt recovery")
        verify_worktree(worktree, arguments.expected_tip, {tombstone.name})
        remove_staging(
            tombstone,
            list(receipt["artifacts"]),
            allow_partial=True,
            inject_failure=False,
        )
        if os.path.lexists(intent_path):
            intent = parse_canonical_json(
                intent_path, "planning import intent", INTENT_KEYS
            )
            expected_intent = dict(receipt)
            expected_intent.pop("status")
            if intent != expected_intent:
                raise ContractError("planning receipt differs from active import intent")
            remove_canonical_json(
                intent_path, intent, "planning import intent", INTENT_KEYS
            )
        remove_canonical_json(
            authority_path, authority, "planning stage authority", AUTHORITY_KEYS
        )
        print(
            json.dumps(
                {
                    "artifacts": receipt["artifacts"],
                    "kind": receipt["kind"],
                    "recovered": True,
                    "stage": arguments.stage,
                },
                sort_keys=True,
            )
        )
        return

    if os.path.lexists(staging) and os.path.lexists(tombstone):
        raise ContractError("both fresh and consumed planning staging exist")
    output_dir = tombstone if os.path.lexists(tombstone) else staging
    if output_dir.parent != worktree:
        raise ContractError("planning staging is not directly inside the native worktree")
    manifest = parse_manifest(output_dir)
    validate_manifest_authority(manifest, authority)
    kind = manifest["kind"]
    if not isinstance(kind, str):
        raise ContractError("planning outcome kind is malformed")

    if os.path.lexists(intent_path):
        intent = parse_canonical_json(
            intent_path, "planning import intent", INTENT_KEYS
        )
        validate_intent(intent, authority, manifest)
        expected = list(intent["artifacts"])
        state = intent["result_state"]
        if not isinstance(state, str):
            raise ContractError("planning import intent result state is malformed")
    else:
        if output_dir != staging:
            raise ContractError("consumed planning staging has no durable import intent")
        if exact_scalar(mission / "state", "mission state") != authority["expected_state"]:
            raise ContractError("mission state moved after planning stage began")
        expected, state = expected_artifacts(
            arguments.stage, kind, mission, manifest["artifacts"]
        )
        initial_artifacts = read_exact_staging(staging, expected)
        intent = {
            **authority,
            "kind": kind,
            "result_state": state,
            "artifacts": expected,
            "artifact_sha256": {
                name: digest(data) for name, data in initial_artifacts.items()
            },
        }
        create_canonical_json(intent_path, intent, "planning import intent")

    allowed_name = output_dir.name
    verify_worktree(worktree, arguments.expected_tip, {allowed_name})
    artifacts = read_exact_staging(output_dir, expected)
    verify_artifact_hashes(artifacts, intent["artifact_sha256"])
    # Re-run both mutable boundary checks immediately before publication.
    verify_worktree(worktree, arguments.expected_tip, {allowed_name})
    if set(os.listdir(output_dir)) != {"manifest.json", *expected}:
        raise ContractError("planning staging changed before publication")

    current_state = exact_scalar(mission / "state", "mission state")
    if current_state == authority["expected_state"]:
        if output_dir != staging:
            raise ContractError("consumed planning staging precedes mission publication")
        publish_batch(mission, artifacts, state)
    elif current_state == state:
        verify_published(mission, intent["artifact_sha256"], state)
    else:
        raise ContractError("mission state is incompatible with planning import recovery")
    verify_published(mission, intent["artifact_sha256"], state)

    fail_after_publish = os.environ.get("ORC_PLANNING_OUTPUT_TEST_FAIL_AFTER_PUBLISH", "")
    if fail_after_publish:
        if fail_after_publish != "1":
            raise ContractError("invalid planning-output post-publication failure injection")
        raise ContractError("injected planning output post-publication failure")

    if output_dir == staging:
        if os.path.lexists(tombstone):
            raise ContractError("planning staging tombstone already exists")
        os.rename(staging, tombstone)
        sync_directory(worktree)
    receipt = {**intent, "status": "imported"}
    create_canonical_json(receipt_path, receipt, "planning stage receipt")
    remove_staging(
        tombstone,
        expected,
        allow_partial=False,
        inject_failure=True,
    )
    remove_canonical_json(intent_path, intent, "planning import intent", INTENT_KEYS)
    remove_canonical_json(
        authority_path, authority, "planning stage authority", AUTHORITY_KEYS
    )
    print(
        json.dumps(
            {
                "artifacts": expected,
                "kind": kind,
                "recovered": False,
                "stage": arguments.stage,
            },
            sort_keys=True,
        )
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    beginner = subparsers.add_parser("begin")
    beginner.add_argument("--mission-dir", required=True)
    beginner.add_argument("--control-dir", required=True)
    beginner.add_argument("--worktree", required=True)
    beginner.add_argument("--expected-tip", required=True)
    beginner.add_argument("--stage", required=True, choices=("plan", "review"))
    beginner.add_argument("--expected-state", required=True)
    importer = subparsers.add_parser("import")
    importer.add_argument("--mission-dir", required=True)
    importer.add_argument("--control-dir", required=True)
    importer.add_argument("--worktree", required=True)
    importer.add_argument("--expected-tip", required=True)
    importer.add_argument("--stage", required=True, choices=("plan", "review"))
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        control = exact_directory(arguments.control_dir, "control directory")
        lifecycle_descriptor = acquire_lifecycle_lock(control)
        try:
            if arguments.command == "begin":
                begin_stage(arguments)
            elif arguments.command == "import":
                import_output(arguments)
            else:
                raise ContractError("unsupported planning-output operation")
        finally:
            release_lifecycle_lock(lifecycle_descriptor)
    except (ContractError, LifecycleLockError, OSError) as error:
        print(f"planning-output: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
