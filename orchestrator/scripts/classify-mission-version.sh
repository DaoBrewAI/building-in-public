#!/usr/bin/env bash
# Read-only classifier for legacy 0.2, in-flight Hybrid 0.3, and native 0.4 missions.
set -uo pipefail

MISSION_DIR=""
CONTROL_DIR=""

fail() {
  echo "classify-mission-version: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --mission-dir) [[ "$#" -ge 2 ]] || fail "--mission-dir requires a value"; MISSION_DIR="$2"; shift 2 ;;
    --control-dir) [[ "$#" -ge 2 ]] || fail "--control-dir requires a value"; CONTROL_DIR="$2"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ -n "$MISSION_DIR" && -n "$CONTROL_DIR" ]] || \
  fail "mission and control directories are required"
case "$MISSION_DIR$CONTROL_DIR" in
  *$'\t'*|*$'\n'*|*$'\r'*) fail "paths contain forbidden control characters" ;;
esac
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

exec python3 - "$MISSION_DIR" "$CONTROL_DIR" <<'PY'
from __future__ import print_function

import errno
import os
import re
import signal
import stat
import sys


class UnsafeAuthority(Exception):
    pass


def reject(message):
    raise UnsafeAuthority(message)


def metadata(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_uid,
        value.st_gid,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def same_object(left, right):
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


def open_directory(parent_fd, name, label):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    try:
        descriptor = os.open(name, flags, dir_fd=parent_fd)
    except OSError:
        reject("%s is missing or unsafe" % label)
    value = os.fstat(descriptor)
    if not stat.S_ISDIR(value.st_mode):
        os.close(descriptor)
        reject("%s is not a directory" % label)
    return descriptor, value


def open_absolute_directory(path, label):
    descriptor = os.open(os.sep, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in [item for item in path.split(os.sep) if item]:
            next_descriptor, unused = open_directory(descriptor, component, label)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor, os.fstat(descriptor)
    except Exception:
        os.close(descriptor)
        raise


def optional_regular(parent_fd, name, label, descriptors):
    flags = os.O_RDONLY | os.O_NOFOLLOW
    try:
        descriptor = os.open(name, flags, dir_fd=parent_fd)
    except OSError as error:
        if error.errno == errno.ENOENT:
            return {"name": name, "label": label, "missing": True}
        reject("%s is unsafe" % label)
    value = os.fstat(descriptor)
    if not stat.S_ISREG(value.st_mode):
        os.close(descriptor)
        reject("%s is not a regular file" % label)
    descriptors.append(descriptor)
    return {
        "name": name,
        "label": label,
        "missing": False,
        "fd": descriptor,
        "before": value,
        "data": None,
    }


def optional_directory(parent_fd, name, label, descriptors):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    try:
        descriptor = os.open(name, flags, dir_fd=parent_fd)
    except OSError as error:
        if error.errno == errno.ENOENT:
            return {"name": name, "label": label, "missing": True}
        reject("%s is unsafe" % label)
    value = os.fstat(descriptor)
    if not stat.S_ISDIR(value.st_mode):
        os.close(descriptor)
        reject("%s is not a directory" % label)
    descriptors.append(descriptor)
    return {
        "name": name,
        "label": label,
        "missing": False,
        "fd": descriptor,
        "before": value,
    }


def read_regular(snapshot):
    if snapshot["missing"]:
        return
    descriptor = snapshot["fd"]
    limit = 16 * 1024 * 1024
    chunks = []
    total = 0
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        chunk = os.read(descriptor, min(65536, limit + 1 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        if total > limit:
            reject("%s is too large" % snapshot["label"])
    after = os.fstat(descriptor)
    if metadata(snapshot["before"]) != metadata(after):
        reject("%s changed while being read" % snapshot["label"])
    snapshot["data"] = b"".join(chunks)


def revalidate_entry(parent_fd, snapshot, expected_directory=False):
    try:
        current = os.stat(snapshot["name"], dir_fd=parent_fd, follow_symlinks=False)
    except OSError as error:
        if error.errno == errno.ENOENT and snapshot["missing"]:
            return
        reject("%s changed during classification" % snapshot["label"])
    if snapshot["missing"]:
        reject("%s appeared during classification" % snapshot["label"])
    expected_type = stat.S_ISDIR if expected_directory else stat.S_ISREG
    if not expected_type(current.st_mode):
        reject("%s changed type during classification" % snapshot["label"])
    if metadata(snapshot["before"]) != metadata(current):
        reject("%s changed during classification" % snapshot["label"])


def revalidate_directory(parent_fd, name, opened_stat, label):
    try:
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError:
        reject("%s changed during classification" % label)
    if not stat.S_ISDIR(current.st_mode) or metadata(opened_stat) != metadata(current):
        reject("%s changed during classification" % label)


def decode(snapshot):
    if snapshot["missing"]:
        return None
    try:
        return snapshot["data"].decode("utf-8")
    except UnicodeDecodeError:
        reject("%s is not UTF-8" % snapshot["label"])


def classify(mission_path, control_path):
    for path, label in ((mission_path, "mission directory"),
                        (control_path, "control directory")):
        if not os.path.isabs(path) or os.path.normpath(path) != path:
            reject("%s path is not canonical" % label)

    mission_parent = os.path.dirname(mission_path)
    control_parent = os.path.dirname(control_path)
    mission_hub = os.path.dirname(mission_parent)
    control_hub = os.path.dirname(control_parent)
    mission_slug = os.path.basename(mission_path)
    control_slug = os.path.basename(control_path)
    slug_pattern = re.compile(r"\A[A-Za-z0-9._-]+\Z")
    if (os.path.basename(mission_parent) != "missions" or
            os.path.basename(control_parent) != "control" or
            mission_hub != control_hub or mission_slug != control_slug or
            mission_slug in (".", "..") or not slug_pattern.match(mission_slug)):
        reject("mission and control directories do not share canonical hub topology")

    descriptors = []
    try:
        hub_fd, hub_stat = open_absolute_directory(mission_hub, "mission hub")
        descriptors.append(hub_fd)
        missions_fd, missions_stat = open_directory(hub_fd, "missions", "missions directory")
        descriptors.append(missions_fd)
        control_parent_fd, control_parent_stat = open_directory(
            hub_fd, "control", "control directory")
        descriptors.append(control_parent_fd)
        mission_fd, mission_stat = open_directory(
            missions_fd, mission_slug, "mission directory")
        descriptors.append(mission_fd)
        control_fd, control_stat = open_directory(
            control_parent_fd, control_slug, "mission control directory")
        descriptors.append(control_fd)

        mission_files = {
            "mission": optional_regular(mission_fd, "MISSION.md", "MISSION.md", descriptors),
            "request": optional_regular(mission_fd, "request.md", "request.md", descriptors),
            "session": optional_regular(mission_fd, "session.txt", "session.txt", descriptors),
            "state": optional_regular(mission_fd, "state", "state", descriptors),
        }
        control_files = {
            "version": optional_regular(
                control_fd, "pipeline-version", "pipeline-version", descriptors),
            "dag": optional_regular(
                control_fd, "approved-task-dag.json", "approved task DAG", descriptors),
        }
        tasks = optional_directory(control_fd, "tasks", "task registry", descriptors)

        # Deterministic regression seam: tests stop after every descriptor has
        # been opened, then replace an authority path before reads continue.
        if os.environ.get("ORC_CLASSIFIER_TEST_STOP_AFTER_OPEN") == "1":
            os.kill(os.getppid(), signal.SIGUSR1)
            os.kill(os.getpid(), signal.SIGSTOP)

        for key in ("mission", "session", "state"):
            read_regular(mission_files[key])
        read_regular(control_files["version"])

        for snapshot in mission_files.values():
            revalidate_entry(mission_fd, snapshot)
        for snapshot in control_files.values():
            revalidate_entry(control_fd, snapshot)
        revalidate_entry(control_fd, tasks, expected_directory=True)
        revalidate_directory(hub_fd, "missions", missions_stat, "missions directory")
        revalidate_directory(hub_fd, "control", control_parent_stat, "control directory")
        revalidate_directory(missions_fd, mission_slug, mission_stat, "mission directory")
        revalidate_directory(
            control_parent_fd, control_slug, control_stat, "mission control directory")
        current_hub_fd, current_hub_stat = open_absolute_directory(mission_hub, "mission hub")
        try:
            if not same_object(hub_stat, current_hub_stat):
                reject("mission hub changed during classification")
        finally:
            os.close(current_hub_fd)

        version = decode(control_files["version"])
        mission = decode(mission_files["mission"])
        session = decode(mission_files["session"])
        state = decode(mission_files["state"])
        has_request = not mission_files["request"]["missing"]
        has_dag = not control_files["dag"]["missing"]
        has_tasks = not tasks["missing"]
        if has_dag != has_tasks:
            reject("partial DAG/task registry authority")

        if version is not None:
            if version not in ("0.3.0\n", "0.4.0\n"):
                reject("unsupported pipeline-version")
            valid_versioned_states = {
                "pending", "running", "planned", "executed", "rework",
                "blocked", "review", "accepted", "failed", "cleanup_pending",
                "collected", "complete", "completed", "done",
            }
            if not has_request or mission is None or state is None:
                reject("versioned Hybrid mission authority is incomplete")
            if "Briefs:" not in mission:
                reject("versioned MISSION.md lacks the Hybrid marker")
            if (not state.endswith("\n") or state.count("\n") != 1 or
                    state[:-1] not in valid_versioned_states):
                reject("versioned mission state is malformed or unsupported")
            if session is not None and (
                    re.search(r"(?m)^(?:backend: codex-exec$|worker_pid:)", session) is not None or
                    re.search(r"(?m)^stage:", session) is None):
                reject("versioned session authority contradicts the Hybrid pipeline")
            if version == "0.3.0\n":
                if has_dag or has_tasks:
                    reject("0.3 mission cannot have native DAG/task authority")
                return "hybrid-0.3"
            return "hybrid-0.4"

        if has_dag or has_tasks:
            reject("DAG/task authority exists without pipeline-version")

        legacy_session = (
            session is not None and
            re.search(r"(?m)^(?:backend: codex-exec$|worker_pid:)", session) is not None and
            re.search(r"(?m)^stage:", session) is None
        )
        legacy_pending = (
            mission is not None and state is not None and
            state.rstrip("\n") == "pending" and
            re.search(r"(?m)^Brief:|gpt-5\.6 \(overrideable\)|\.worktrees", mission) is not None and
            not (has_request and "Briefs:" in mission)
        )
        hybrid = (
            has_request and mission is not None and session is not None and
            "Briefs:" in mission and re.search(r"(?m)^stage:", session) is not None
        )
        candidates = set()
        if legacy_session or legacy_pending:
            candidates.add("legacy-0.2")
        if hybrid:
            candidates.add("hybrid-0.3")
        if len(candidates) != 1:
            reject("mission authority is partial or contradictory")
        return candidates.pop()
    finally:
        for descriptor in reversed(descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass


try:
    result = classify(sys.argv[1], sys.argv[2])
except (UnsafeAuthority, OSError) as error:
    print("classify-mission-version: %s" % error, file=sys.stderr)
    sys.exit(1)
print(result)
PY
