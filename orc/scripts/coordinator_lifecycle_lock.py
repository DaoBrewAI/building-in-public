#!/usr/bin/env python3
"""One advisory lock for every coordinator mutation in a mission control root."""

from __future__ import annotations

import argparse
import fcntl
import os
import re
import stat
import sys
import time
from pathlib import Path
from typing import Union


LOCK_NAME = ".coordinator-lifecycle.lock"
PARTICIPANT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")


class LifecycleLockError(RuntimeError):
    """The shared coordinator lifecycle lock is unavailable or unsafe."""


def _exact_control_directory(raw: Union[str, os.PathLike[str]]) -> Path:
    path = Path(raw)
    if not path.is_absolute():
        raise LifecycleLockError("control directory must be absolute")
    try:
        metadata = path.lstat()
    except OSError as error:
        raise LifecycleLockError(f"control directory is unavailable: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise LifecycleLockError("control directory must be a real directory")
    physical = Path(os.path.realpath(path))
    if physical != path:
        raise LifecycleLockError("control directory must use its exact physical path")
    return physical


def _validate_lock(descriptor: int, path: Path) -> None:
    try:
        opened = os.fstat(descriptor)
        current = os.lstat(path)
    except OSError as error:
        raise LifecycleLockError(f"cannot validate coordinator lifecycle lock: {error}") from error
    if (
        not stat.S_ISREG(opened.st_mode)
        or stat.S_ISLNK(current.st_mode)
        or not stat.S_ISREG(current.st_mode)
        or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)
        or opened.st_nlink != 1
        or current.st_nlink != 1
        or opened.st_uid != os.geteuid()
        or stat.S_IMODE(opened.st_mode) & 0o077
    ):
        raise LifecycleLockError("coordinator lifecycle lock is unsafe")


def ensure_lock_file(control: Path) -> Path:
    path = control / LOCK_NAME
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        raise LifecycleLockError(f"cannot open coordinator lifecycle lock: {error}") from error
    try:
        _validate_lock(descriptor, path)
    finally:
        os.close(descriptor)
    return path


def _test_hook() -> None:
    raw_directory = os.environ.get("ORC_COORDINATOR_LIFECYCLE_TEST_HOOK_DIR")
    participant = os.environ.get("ORC_COORDINATOR_LIFECYCLE_TEST_PARTICIPANT")
    if not raw_directory and not participant:
        return
    if not raw_directory or not participant or PARTICIPANT_RE.fullmatch(participant) is None:
        raise LifecycleLockError("coordinator lifecycle test hook is malformed")
    directory = _exact_control_directory(raw_directory)
    entered = directory / f"entered-{participant}"
    continued = directory / f"continue-{participant}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(entered, flags, 0o600)
        try:
            os.write(descriptor, b"entered\n")
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        directory_descriptor = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except OSError as error:
        raise LifecycleLockError(f"coordinator lifecycle test hook failed: {error}") from error
    deadline = time.monotonic() + 30
    while not os.path.lexists(continued):
        if time.monotonic() >= deadline:
            raise LifecycleLockError("coordinator lifecycle test hook timed out")
        time.sleep(0.01)
    try:
        metadata = continued.lstat()
    except OSError as error:
        raise LifecycleLockError(f"coordinator lifecycle continuation is unavailable: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise LifecycleLockError("coordinator lifecycle continuation is unsafe")


def acquire_lifecycle_lock(control: Path) -> int:
    control = _exact_control_directory(control)
    path = ensure_lock_file(control)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise LifecycleLockError(f"cannot open coordinator lifecycle lock: {error}") from error
    try:
        _validate_lock(descriptor, path)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        _validate_lock(descriptor, path)
        _test_hook()
    except BaseException:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)
        raise
    return descriptor


def release_lifecycle_lock(descriptor: int) -> None:
    try:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
    finally:
        os.close(descriptor)


def acquire_inherited_descriptor(path: Path, descriptor: int) -> None:
    if not path.is_absolute() or path.name != LOCK_NAME:
        raise LifecycleLockError("coordinator lifecycle lock path is invalid")
    control = _exact_control_directory(path.parent)
    if path != control / LOCK_NAME:
        raise LifecycleLockError("coordinator lifecycle lock path is not exact")
    _validate_lock(descriptor, path)
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    try:
        _validate_lock(descriptor, path)
        _test_hook()
    except BaseException:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    prepare = subparsers.add_parser("prepare")
    prepare.add_argument("--control-dir", required=True)
    acquire = subparsers.add_parser("acquire-fd")
    acquire.add_argument("--lock-file", required=True)
    acquire.add_argument("--fd", required=True, type=int)
    arguments = parser.parse_args()
    try:
        if arguments.operation == "prepare":
            control = _exact_control_directory(arguments.control_dir)
            print(ensure_lock_file(control))
        elif arguments.operation == "acquire-fd":
            acquire_inherited_descriptor(Path(arguments.lock_file), arguments.fd)
        else:
            raise LifecycleLockError("unsupported lifecycle lock operation")
    except (LifecycleLockError, OSError, ValueError) as error:
        print(f"coordinator-lifecycle-lock: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
