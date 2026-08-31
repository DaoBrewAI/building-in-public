#!/usr/bin/env python3
"""Inspect or clean up an app-native Orchestrator task from Claude Code."""

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import threading
from pathlib import Path
from typing import Any, Dict, List, Optional


LIFECYCLE_METHODS = {
    "archive": "thread/archive",
    "unarchive": "thread/unarchive",
}


class ProtocolError(RuntimeError):
    pass


def emit(payload: Dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, separators=(",", ":"), ensure_ascii=False) + "\n")
    sys.stdout.flush()


def resolve_command() -> List[str]:
    override = os.environ.get("ORC_CODEX_APP_SERVER_COMMAND")
    if override:
        command = shlex.split(override)
        if not command:
            raise ProtocolError("ORC_CODEX_APP_SERVER_COMMAND is empty")
        return command

    binary = os.environ.get("ORC_CODEX_BIN") or shutil.which("codex")
    bundled = Path("/Applications/ChatGPT.app/Contents/Resources/codex")
    if not binary and bundled.is_file():
        binary = str(bundled)
    if not binary:
        raise ProtocolError("Codex binary is unavailable")
    return [binary, "app-server", "--stdio"]


class AppServer:
    def __init__(self, command: List[str]) -> None:
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        if self.process.stdin is None or self.process.stdout is None or self.process.stderr is None:
            raise ProtocolError("could not open App Server stdio")
        self._next_id = 1
        self._stderr_thread = threading.Thread(target=self._forward_stderr, daemon=True)
        self._stderr_thread.start()

    def _forward_stderr(self) -> None:
        assert self.process.stderr is not None
        for line in self.process.stderr:
            sys.stderr.write(line)
            sys.stderr.flush()

    def send(self, payload: Dict[str, Any]) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def notify(self, method: str, params: Optional[Dict[str, Any]] = None) -> None:
        self.send({"method": method, "params": params or {}})

    def request(self, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        request_id = self._next_id
        self._next_id += 1
        self.send({"method": method, "id": request_id, "params": params})
        while True:
            message = self.read_message()
            if message.get("id") != request_id:
                self.handle_notification(message)
                continue
            if "error" in message:
                error = message.get("error") or {}
                raise ProtocolError(f"{method} failed: {error.get('message', error)}")
            result = message.get("result")
            if not isinstance(result, dict):
                raise ProtocolError(f"{method} returned a malformed result")
            return result

    def read_message(self) -> Dict[str, Any]:
        assert self.process.stdout is not None
        line = self.process.stdout.readline()
        if not line:
            code = self.process.poll()
            raise ProtocolError(f"App Server closed before a response (exit={code})")
        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ProtocolError(f"App Server emitted invalid JSON: {exc}") from exc
        if not isinstance(message, dict):
            raise ProtocolError("App Server emitted a non-object message")
        return message

    def handle_notification(self, message: Dict[str, Any]) -> None:
        # Lifecycle calls are request/response only. Ignore unrelated server
        # notifications rather than replaying child activity into this process.
        return

    def close(self) -> None:
        try:
            if self.process.stdin is not None:
                self.process.stdin.close()
        except OSError:
            pass
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    for operation in ("inspect", "archive", "unarchive", "stop"):
        lifecycle = subparsers.add_parser(operation)
        lifecycle.add_argument("--thread-id", required=True)
    subparsers.choices["stop"].add_argument("--turn-id", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    server = AppServer(resolve_command())
    try:
        server.request(
            "initialize",
            {
                "clientInfo": {"name": "orchestrator", "title": "Orchestrator", "version": "0.5.3"},
                "capabilities": {"experimentalApi": True},
            },
        )
        server.notify("initialized")

        if args.operation == "inspect":
            cursor: Optional[str] = None
            seen_cursors = set()
            found = False
            while True:
                params: Dict[str, Any] = {
                    "limit": 100,
                    "archived": None,
                    "sourceKinds": [],
                }
                if cursor is not None:
                    params["cursor"] = cursor
                listed = server.request("thread/list", params)
                data = listed.get("data")
                if not isinstance(data, list):
                    raise ProtocolError("thread/list returned malformed data")
                if any(
                    isinstance(item, dict) and item.get("id") == args.thread_id
                    for item in data
                ):
                    found = True
                    break
                next_cursor = listed.get("nextCursor")
                if next_cursor is None:
                    break
                if not isinstance(next_cursor, str) or not next_cursor or next_cursor in seen_cursors:
                    raise ProtocolError("thread/list returned an invalid pagination cursor")
                seen_cursors.add(next_cursor)
                cursor = next_cursor
            if not found:
                raise ProtocolError("thread/list did not contain the exact thread id")
            read = server.request(
                "thread/read", {"threadId": args.thread_id, "includeTurns": False}
            )
            thread = read.get("thread")
            if not isinstance(thread, dict) or thread.get("id") != args.thread_id:
                raise ProtocolError("thread/read returned a different thread")
            emit(
                {
                    "type": "thread.inspected",
                    "thread_id": args.thread_id,
                    "title": thread.get("name") or thread.get("title"),
                    "cwd": thread.get("cwd"),
                    "status": thread.get("status"),
                    "project_id": thread.get("projectId"),
                }
            )
            return 0
        if args.operation in ("archive", "unarchive"):
            method = LIFECYCLE_METHODS[args.operation]
            result = server.request(method, {"threadId": args.thread_id})
            emit(
                {
                    "type": f"thread.{args.operation}d",
                    "thread_id": args.thread_id,
                    "result": result,
                }
            )
            return 0
        if args.operation == "stop":
            result = server.request(
                "turn/interrupt", {"threadId": args.thread_id, "turnId": args.turn_id}
            )
            emit(
                {
                    "type": "turn.interrupted",
                    "thread_id": args.thread_id,
                    "turn_id": args.turn_id,
                    "result": result,
                }
            )
            return 0

        raise ProtocolError(f"unsupported lifecycle operation: {args.operation}")
    finally:
        server.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ProtocolError, UnicodeError) as exc:
        sys.stderr.write(f"codex-task-client: {exc}\n")
        raise SystemExit(1)
