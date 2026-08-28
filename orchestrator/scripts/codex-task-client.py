#!/usr/bin/env python3
"""Launch or resume a visible Orchestrator child through Codex App Server."""

import argparse
import hashlib
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
        self._terminal_status: Optional[str] = None
        self._thread_id: Optional[str] = None
        self._turn_id: Optional[str] = None
        self._emitted_thread = False
        self._emitted_turn = False
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
            raise ProtocolError(f"App Server closed before turn completion (exit={code})")
        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ProtocolError(f"App Server emitted invalid JSON: {exc}") from exc
        if not isinstance(message, dict):
            raise ProtocolError("App Server emitted a non-object message")
        return message

    def set_thread(self, thread_id: str) -> None:
        self._thread_id = thread_id
        if not self._emitted_thread:
            emit({"type": "thread.started", "thread_id": thread_id})
            self._emitted_thread = True

    def set_turn(self, turn_id: str) -> None:
        self._turn_id = turn_id
        if not self._emitted_turn:
            emit({"type": "turn.started", "thread_id": self._thread_id, "turn_id": turn_id})
            self._emitted_turn = True

    def handle_notification(self, message: Dict[str, Any]) -> None:
        method = message.get("method")
        if not isinstance(method, str):
            return
        params = message.get("params") if isinstance(message.get("params"), dict) else {}
        if method == "thread/started":
            thread = params.get("thread") if isinstance(params.get("thread"), dict) else {}
            thread_id = thread.get("id")
            if isinstance(thread_id, str) and thread_id:
                if self._thread_id and thread_id != self._thread_id:
                    raise ProtocolError("App Server started an unexpected thread")
                self.set_thread(thread_id)
            return
        if method == "turn/started":
            turn = params.get("turn") if isinstance(params.get("turn"), dict) else {}
            turn_id = turn.get("id")
            if isinstance(turn_id, str) and turn_id:
                self.set_turn(turn_id)
            return
        if method in ("turn/completed", "turn/failed", "turn/cancelled"):
            turn = params.get("turn") if isinstance(params.get("turn"), dict) else {}
            turn_id = turn.get("id") or params.get("turnId") or self._turn_id
            status = turn.get("status")
            if not isinstance(status, str) or not status:
                status = method.split("/", 1)[1]
            self._terminal_status = status
            emit(
                {
                    "type": method.replace("/", "."),
                    "thread_id": params.get("threadId") or self._thread_id,
                    "turn_id": turn_id,
                    "status": status,
                }
            )
            return
        # Child MCP/tool/token/item notifications stay inside the child thread.
        # Replaying them on stdout duplicates the child transcript into the
        # coordinator tool result and defeats context isolation.
        return

    def wait_for_terminal(self) -> str:
        while self._terminal_status is None:
            self.handle_notification(self.read_message())
        return self._terminal_status

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


def absolute_directory(value: str) -> str:
    path = Path(value)
    if not path.is_absolute() or not path.is_dir():
        raise argparse.ArgumentTypeError(f"directory must exist and be absolute: {value}")
    return str(path.resolve())


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    for operation in ("create", "resume"):
        subparser = subparsers.add_parser(operation)
        subparser.add_argument("--cwd", required=True, type=absolute_directory)
        subparser.add_argument("--task-dir", required=True, type=absolute_directory)
        subparser.add_argument("--model", required=True)
        subparser.add_argument("--effort", required=True)
        subparser.add_argument("--prompt-file", required=True, type=Path)
        subparser.add_argument("--service-tier")
    create = subparsers.choices["create"]
    create.add_argument("--project-id", required=True)
    create.add_argument("--project-root", required=True, type=absolute_directory)
    create.add_argument("--title", required=True)
    resume = subparsers.choices["resume"]
    resume.add_argument("--thread-id", required=True)
    for operation in ("inspect", "archive", "unarchive", "stop"):
        lifecycle = subparsers.add_parser(operation)
        lifecycle.add_argument("--thread-id", required=True)
    subparsers.choices["stop"].add_argument("--turn-id", required=True)
    bind = subparsers.add_parser("bind-project")
    bind.add_argument("--project-root", required=True, type=absolute_directory)
    return parser


def thread_id_from(result: Dict[str, Any], method: str) -> str:
    thread = result.get("thread")
    if not isinstance(thread, dict) or not isinstance(thread.get("id"), str) or not thread["id"]:
        raise ProtocolError(f"{method} returned no thread id")
    return thread["id"]


def turn_id_from(result: Dict[str, Any]) -> str:
    turn = result.get("turn")
    if not isinstance(turn, dict) or not isinstance(turn.get("id"), str) or not turn["id"]:
        raise ProtocolError("turn/start returned no turn id")
    return turn["id"]


def project_id_for(server: AppServer, project_root: str, requested_id: Optional[str]) -> str:
    root = str(Path(project_root).resolve())
    cursor: Optional[str] = None
    seen_cursors = set()
    matches: List[str] = []
    while True:
        params: Dict[str, Any] = {"limit": 100}
        if cursor is not None:
            params["cursor"] = cursor
        result = server.request("project/list", params)
        data = result.get("data")
        if not isinstance(data, list):
            raise ProtocolError("project/list returned malformed data")
        for project in data:
            if not isinstance(project, dict) or not isinstance(project.get("id"), str):
                continue
            roots = project.get("roots")
            if isinstance(roots, list) and any(
                isinstance(item, dict) and item.get("path") == root for item in roots
            ):
                matches.append(project["id"])
        next_cursor = result.get("nextCursor")
        if next_cursor is None:
            break
        if not isinstance(next_cursor, str) or not next_cursor or next_cursor in seen_cursors:
            raise ProtocolError("project/list returned an invalid pagination cursor")
        seen_cursors.add(next_cursor)
        cursor = next_cursor
    matches = sorted(set(matches))
    if requested_id:
        if matches != [requested_id]:
            raise ProtocolError("requested project id is not bound to the exact project root")
        return requested_id
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        raise ProtocolError("multiple App Server projects match the exact project root")
    key = hashlib.sha256(root.encode("utf-8")).hexdigest()
    created = server.request(
        "project/create",
        {
            "idempotencyKey": f"orchestrator-{key}",
            "name": Path(root).name,
            "roots": [{"path": root}],
            "metadata": {"createdBy": "orchestrator"},
        },
    )
    project = created.get("project")
    if not isinstance(project, dict) or not isinstance(project.get("id"), str):
        raise ProtocolError("project/create returned no project id")
    roots = project.get("roots")
    if not isinstance(roots, list) or not any(
        isinstance(item, dict) and item.get("path") == root for item in roots
    ):
        raise ProtocolError("project/create did not bind the exact project root")
    return project["id"]


def main() -> int:
    args = build_parser().parse_args()
    prompt = ""
    roots: List[str] = []
    if args.operation in ("create", "resume"):
        if not args.prompt_file.is_file():
            raise ProtocolError(f"prompt file is missing: {args.prompt_file}")
        prompt = args.prompt_file.read_text(encoding="utf-8")
        if not prompt:
            raise ProtocolError("prompt file is empty")
        roots = [args.cwd, args.task_dir]
    server = AppServer(resolve_command())
    try:
        server.request(
            "initialize",
            {
                "clientInfo": {"name": "orchestrator", "title": "Orchestrator", "version": "0.5.0"},
                "capabilities": {"experimentalApi": True},
            },
        )
        server.notify("initialized")

        if args.operation == "bind-project":
            project_id = project_id_for(server, args.project_root, None)
            emit({"type": "project.bound", "project_id": project_id, "project_root": args.project_root})
            return 0

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
                "thread/read", {"threadId": args.thread_id, "includeTurns": True}
            )
            emit({"type": "thread.inspected", "thread_id": args.thread_id, "result": read})
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

        if args.operation == "create":
            project_id = project_id_for(server, args.project_root, args.project_id)
            start_params: Dict[str, Any] = {
                "model": args.model,
                "cwd": args.cwd,
                "approvalPolicy": "never",
                "sandbox": "workspace-write",
                "runtimeWorkspaceRoots": roots,
                "threadSource": "orchestrator-child",
                "historyMode": "paginated",
                "serviceName": "orchestrator",
            }
            start_params["projectId"] = project_id
            result = server.request("thread/start", start_params)
            thread_id = thread_id_from(result, "thread/start")
            server.set_thread(thread_id)
            server.request("thread/name/set", {"threadId": thread_id, "name": args.title})
        else:
            result = server.request(
                "thread/resume",
                {
                    "threadId": args.thread_id,
                    "model": args.model,
                    "cwd": args.cwd,
                    "approvalPolicy": "never",
                    "sandbox": "workspace-write",
                    "runtimeWorkspaceRoots": roots,
                },
            )
            thread_id = thread_id_from(result, "thread/resume")
            if thread_id != args.thread_id:
                raise ProtocolError("thread/resume returned a different thread id")
            server.set_thread(thread_id)

        turn_params: Dict[str, Any] = {
            "threadId": thread_id,
            "input": [{"type": "text", "text": prompt}],
            "cwd": args.cwd,
            "model": args.model,
            "effort": args.effort,
            "approvalPolicy": "never",
            "runtimeWorkspaceRoots": roots,
            "sandboxPolicy": {
                "type": "workspaceWrite",
                "writableRoots": [args.task_dir],
                "networkAccess": False,
                "excludeSlashTmp": True,
                "excludeTmpdirEnvVar": True,
            },
        }
        if args.service_tier:
            turn_params["serviceTier"] = args.service_tier
        turn_result = server.request("turn/start", turn_params)
        server.set_turn(turn_id_from(turn_result))
        status = server.wait_for_terminal()
        return 0 if status == "completed" else 1
    finally:
        server.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ProtocolError, UnicodeError) as exc:
        sys.stderr.write(f"codex-task-client: {exc}\n")
        raise SystemExit(1)
