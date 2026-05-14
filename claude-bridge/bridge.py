import json
import os
import signal
import sqlite3
import subprocess
import tempfile
import threading
import time
import uuid
from collections import deque

from config import (
    ALLOWED_TOOLS,
    AUTHORIZED_SENDERS,
    CHAT_DB_PATH,
    DEFAULT_WORKDIR,
    POLL_INTERVAL,
    SMS_PREFERRED,
)


# --- iMessage Reader ---


def get_last_rowid(db_path):
    with sqlite3.connect(db_path) as conn:
        row = conn.execute("SELECT MAX(ROWID) FROM message").fetchone()
    return row[0] or 0


def poll_new_messages(db_path, senders, last_rowid):
    placeholders = ",".join("?" for _ in senders)
    with sqlite3.connect(db_path) as conn:
        cursor = conn.execute(
            f"""
            SELECT m.ROWID, m.text, h.id
            FROM message m
            JOIN handle h ON m.handle_id = h.ROWID
            WHERE h.id IN ({placeholders})
              AND m.is_from_me = 0
              AND m.ROWID > ?
            ORDER BY m.ROWID ASC
            """,
            (*senders, last_rowid),
        )
        raw_messages = cursor.fetchall()

        results = []
        for rowid, text, sender in raw_messages:
            attachments = conn.execute(
                """
                SELECT a.filename, a.mime_type
                FROM attachment a
                JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
                WHERE maj.message_id = ?
                  AND a.mime_type LIKE 'image/%'
                  AND a.filename IS NOT NULL
                """,
                (rowid,),
            ).fetchall()

            image_tags = []
            for filename, mime_type in attachments:
                path = os.path.expanduser(filename)
                if os.path.exists(path):
                    image_tags.append(f"[Image: {path}]")

            if image_tags:
                parts = image_tags
                if text:
                    parts.append(text)
                combined = " ".join(parts)
            elif text:
                combined = text
            else:
                continue

            results.append((rowid, combined, sender))

    return results


# --- iMessage Sender ---


def _build_send_script(prefer_sms):
    if prefer_sms:
        return '''
        on run argv
            set targetId to item 1 of argv
            set msg to item 2 of argv
            tell application "Messages"
                try
                    send msg to chat id ("SMS;-;" & targetId)
                    return "sent via SMS"
                end try
                try
                    send msg to chat id ("iMessage;-;" & targetId)
                    return "sent via iMessage"
                end try
                try
                    send msg to buddy targetId of (1st service whose service type = SMS)
                    return "sent via SMS buddy"
                end try
                try
                    send msg to buddy targetId of (1st service whose service type = iMessage)
                    return "sent via iMessage buddy"
                end try
                error "Could not send to: " & targetId
            end tell
        end run
        '''
    return '''
    on run argv
        set targetId to item 1 of argv
        set msg to item 2 of argv
        tell application "Messages"
            try
                send msg to chat id ("iMessage;-;" & targetId)
                return "sent via iMessage"
            end try
            try
                send msg to buddy targetId of (1st service whose service type = iMessage)
                return "sent via iMessage buddy"
            end try
            try
                send msg to chat id ("SMS;-;" & targetId)
                return "sent via SMS"
            end try
            try
                send msg to buddy targetId of (1st service whose service type = SMS)
                return "sent via SMS buddy"
            end try
            error "Could not send to: " & targetId
        end tell
    end run
    '''


def send_imessage(recipient, text, retries=2):
    script = _build_send_script(recipient in SMS_PREFERRED)
    for attempt in range(1, retries + 1):
        try:
            result = subprocess.run(
                ["osascript", "-e", script, recipient, text],
                capture_output=True,
                text=True,
                timeout=30,
            )
            if result.returncode == 0:
                method = result.stdout.strip()
                print(f"[SEND OK] to {recipient} ({method})")
                return True
            print(f"[SEND ERROR] attempt {attempt}: {result.stderr.strip()}")
        except subprocess.TimeoutExpired:
            print(f"[SEND ERROR] attempt {attempt}: osascript timed out")
        except Exception as e:
            print(f"[SEND ERROR] attempt {attempt}: {e}")
        if attempt < retries:
            time.sleep(2)
    print(f"[SEND FAILED] giving up after {retries} attempts to {recipient}")
    return False


# --- Agent Runner ---


SYSTEM_PROMPT = (
    "Do not create git worktrees. Work directly on the current branch in the current directory. "
    "Before switching branches, always verify the branch exists with 'git branch --list <name>'. "
    "Never create new branches unless the user explicitly asks you to create one."
)


class AgentSession:
    def __init__(self):
        self.agent = "claude"
        self.session_id = None
        self.codex_thread_id = None
        self.workdir = None
        self.start_time = None
        self._first_run = False

    def start(self, subfolder):
        workdir = os.path.join(DEFAULT_WORKDIR, subfolder)
        if not os.path.isdir(workdir):
            return None, f"Folder not found: {workdir}"
        self.session_id = str(uuid.uuid4())
        self.codex_thread_id = None
        self.workdir = workdir
        self.start_time = time.time()
        self._first_run = True
        return self.session_id, (
            f"{self.agent_label} session started in {workdir}\n"
            f"Session ID: {self.session_id}"
        )

    def run(self, message):
        if not self.session_id:
            return "No active session. Send /project <subfolder> first."

        if self.agent == "codex":
            return self._run_codex(message)
        return self._run_claude(message)

    @property
    def agent_label(self):
        return "Codex" if self.agent == "codex" else "Claude"

    def switch_agent(self, agent):
        if agent not in {"claude", "codex"}:
            return f"Unknown agent: {agent}"
        if agent == self.agent:
            return f"Already using {self.agent_label}."

        old_sid = self.session_id
        old_agent = self.agent_label
        self.agent = agent

        if not self.workdir:
            return f"Switched to {self.agent_label}. Send /project <subfolder> first."

        self.session_id = str(uuid.uuid4())
        self.codex_thread_id = None
        self.start_time = time.time()
        self._first_run = True

        msg = f"Switched to {self.agent_label} in {self.workdir}\nSession ID: {self.session_id}"
        if old_sid:
            msg += f"\nPrevious {old_agent} session ended. ID: {old_sid}"
        return msg

    def _run_claude(self, message):
        cmd = [
            "claude",
            "-p", message,
            "--output-format", "text",
            "--permission-mode", "acceptEdits",
            "--allowedTools", ",".join(ALLOWED_TOOLS),
            "--disallowedTools", "EnterWorktree",
            "--append-system-prompt", SYSTEM_PROMPT,
        ]

        if self._first_run:
            cmd.extend(["--session-id", self.session_id])
            self._first_run = False
        else:
            cmd.extend(["--resume", self.session_id])

        print(f"[CMD] {' '.join(cmd)}")
        print(f"[CWD] {self.workdir}")
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                cwd=self.workdir,
            )
            if result.returncode != 0:
                stderr = result.stderr.strip()
                print(f"[STDERR] {stderr[:500]}")
                return f"Claude error (exit {result.returncode}): {stderr[:500]}"
            return result.stdout.strip() or "(empty response)"
        except FileNotFoundError:
            return "Error: 'claude' command not found. Is Claude Code installed and in PATH?"

    def _run_codex(self, message):
        output_path = None
        try:
            with tempfile.NamedTemporaryFile(delete=False) as output_file:
                output_path = output_file.name

            if self._first_run or not self.codex_thread_id:
                cmd = [
                    "codex",
                    "-a", "never",
                    "exec",
                    "--skip-git-repo-check",
                    "--json",
                    "-s", "workspace-write",
                    "-o", output_path,
                    message,
                ]
            else:
                cmd = [
                    "codex",
                    "-a", "never",
                    "exec",
                    "resume",
                    "--skip-git-repo-check",
                    "--json",
                    "-o", output_path,
                    self.codex_thread_id,
                    message,
                ]

            print(f"[CMD] {' '.join(cmd)}")
            print(f"[CWD] {self.workdir}")
            result = subprocess.run(
                cmd,
                input="",
                capture_output=True,
                text=True,
                cwd=self.workdir,
            )
            self._capture_codex_thread_id(result.stdout)
            if result.returncode != 0:
                stderr = (result.stderr.strip() or result.stdout.strip())[:500]
                print(f"[STDERR] {stderr}")
                return f"Codex error (exit {result.returncode}): {stderr}"

            self._first_run = False
            with open(output_path, "r", encoding="utf-8") as f:
                response = f.read().strip()
            return response or "(empty response)"
        except FileNotFoundError:
            return "Error: 'codex' command not found. Is Codex installed and in PATH?"
        finally:
            if output_path:
                try:
                    os.unlink(output_path)
                except OSError:
                    pass

    def _capture_codex_thread_id(self, stdout):
        for line in stdout.splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            thread_id = event.get("thread_id")
            if thread_id:
                self.codex_thread_id = thread_id

    def resume(self, session_id, workdir=None, agent=None, codex_thread_id=None):
        self.session_id = session_id
        if agent:
            self.agent = agent
        self.codex_thread_id = codex_thread_id
        self.workdir = workdir or self.workdir or DEFAULT_WORKDIR
        self.start_time = time.time()
        self._first_run = False

    def snapshot(self):
        return {
            "agent": self.agent,
            "workdir": self.workdir,
            "codex_thread_id": self.codex_thread_id,
        }

    def status(self):
        if not self.session_id:
            return f"No active session. Current agent: {self.agent_label}."
        uptime = int(time.time() - self.start_time) if self.start_time else 0
        mins = uptime // 60
        status = (
            f"Agent: {self.agent_label}\n"
            f"Project: {self.workdir}\n"
            f"Session ID: {self.session_id}\n"
            f"Uptime: {mins}m"
        )
        if self.codex_thread_id:
            status += f"\nCodex thread ID: {self.codex_thread_id}"
        return status

    def stop(self):
        sid = self.session_id
        self.session_id = None
        self.codex_thread_id = None
        self.workdir = None
        self.start_time = None
        self._first_run = False
        return sid


# --- Command Parser ---


def parse_command(text):
    text = text.strip()
    if not text.startswith("/"):
        return "message", text

    parts = text.split(None, 1)
    cmd = parts[0].lower()
    arg = parts[1] if len(parts) > 1 else ""

    commands = {
        "/project": "project",
        "/resume": "resume",
        "/status": "status",
        "/exit": "exit",
        "/kill": "kill",
        "/claude": "claude",
        "/codex": "codex",
    }
    return commands.get(cmd, "unknown"), arg


# --- Main Bridge ---


class Bridge:
    SENT_CACHE_TTL = 15

    def __init__(self):
        self.session = AgentSession()
        self.running = True
        self.busy = False
        self.message_queue = deque()
        self._lock = threading.Lock()
        self.last_rowid = 0
        self._reply_to = None
        self._sent_cache = {}
        self._session_workdirs = {}

    def _record_sent(self, text):
        self._sent_cache[text] = time.time()
        cutoff = time.time() - self.SENT_CACHE_TTL
        self._sent_cache = {k: v for k, v in self._sent_cache.items() if v > cutoff}

    def _was_sent_by_us(self, text):
        ts = self._sent_cache.get(text)
        if ts and (time.time() - ts) < self.SENT_CACHE_TTL:
            del self._sent_cache[text]
            return True
        return False

    def handle_message(self, text):
        cmd, arg = parse_command(text)

        if cmd == "project":
            if not arg:
                return "Usage: /project <subfolder>"
            if self.session.session_id:
                old_snapshot = self.session.snapshot()
                old_sid = self.session.stop()
                self._session_workdirs[old_sid] = old_snapshot
                self._send_reply(self._reply_to, f"Previous session ended. ID: {old_sid}")
            sid, msg = self.session.start(arg)
            if sid is None:
                return f"❌ {msg}"
            return f"✅ {msg}"

        elif cmd in {"claude", "codex"}:
            old_sid = self.session.session_id if self.session.agent != cmd else None
            old_snapshot = self.session.snapshot() if old_sid else None
            response = self.session.switch_agent(cmd)
            if old_sid and old_sid != self.session.session_id:
                self._session_workdirs[old_sid] = old_snapshot
            if arg:
                response += "\n\n" + self.handle_message(arg)
            return response

        elif cmd == "resume":
            if not arg:
                return "Usage: /resume <session-id>"
            snapshot = self._session_workdirs.get(arg)
            if isinstance(snapshot, dict):
                workdir = snapshot.get("workdir")
                agent = snapshot.get("agent")
                codex_thread_id = snapshot.get("codex_thread_id")
            else:
                workdir = snapshot
                agent = None
                codex_thread_id = None
            self.session.resume(
                arg,
                workdir=workdir,
                agent=agent,
                codex_thread_id=codex_thread_id,
            )
            info = f"✅ Resuming session {arg}"
            info += f"\nAgent: {self.session.agent_label}"
            if workdir:
                info += f"\nProject: {workdir}"
            else:
                info += f"\nProject: {self.session.workdir} (default — use /project first if wrong)"
            return info

        elif cmd == "status":
            status = self.session.status()
            if self.busy:
                status += f"\n⏳ {self.session.agent_label} is currently processing..."
            return status

        elif cmd == "exit":
            snapshot = self.session.snapshot()
            sid = self.session.stop()
            if sid:
                self._session_workdirs[sid] = snapshot
                return f"Session ended. Session ID: {sid}\nSend /resume {sid} to resume later."
            return "No active session."

        elif cmd == "kill":
            snapshot = self.session.snapshot()
            sid = self.session.stop()
            self.running = False
            if sid:
                self._session_workdirs[sid] = snapshot
                return f"Bridge shutting down. Session ID: {sid}"
            return "Bridge shutting down."

        elif cmd == "message":
            if not self.session.session_id:
                return "No active session. Send /project <subfolder> first."
            with self._lock:
                self.busy = True
            try:
                response = self.session.run(arg)
            except Exception as e:
                sid = self.session.session_id
                if sid and self.session.workdir:
                    self._session_workdirs[sid] = self.session.snapshot()
                self.session.stop()
                response = (
                    f"⚠️ {self.session.agent_label} session crashed: {e}\n"
                    f"Session ID: {sid}\n"
                    f"Send /resume {sid} to continue, or /project <name> for fresh start."
                )
            finally:
                with self._lock:
                    self.busy = False
            return response

        elif cmd == "unknown":
            return "Unknown command. Available: /project, /claude, /codex, /resume, /status, /exit, /kill"

        return None

    def _send_reply(self, sender, text):
        self._record_sent(text)
        send_imessage(sender, text)

    def _process_message(self, sender, text):
        self._reply_to = sender
        response = self.handle_message(text)
        if response:
            print(f"[OUT] {response[:100]}")
            self._send_reply(sender, response)
        self._drain_queue()

    def _drain_queue(self):
        while self.message_queue:
            sender, _, text = self.message_queue.popleft()
            self._reply_to = sender
            response = self.handle_message(text)
            if response:
                self._send_reply(sender, response)

    def run(self):
        print(f"Bridge started. Listening for messages from: {', '.join(AUTHORIZED_SENDERS)}")
        print(f"Default workdir: {DEFAULT_WORKDIR}")
        print("Waiting for /project command from phone...")

        self.last_rowid = get_last_rowid(CHAT_DB_PATH)

        while self.running:
            try:
                messages = poll_new_messages(CHAT_DB_PATH, AUTHORIZED_SENDERS, self.last_rowid)
                for rowid, text, sender in messages:
                    self.last_rowid = rowid

                    if self._was_sent_by_us(text):
                        print(f"[SKIP echo] {text[:60]}")
                        continue

                    print(f"[IN from {sender}] {text[:100]}")

                    with self._lock:
                        is_busy = self.busy

                    if is_busy:
                        self.message_queue.append((sender, rowid, text))
                        self._send_reply(sender, f"⏳ {self.session.agent_label} is busy. Your message is queued.")
                        continue

                    thread = threading.Thread(
                        target=self._process_message,
                        args=(sender, text),
                        daemon=True,
                    )
                    thread.start()

                time.sleep(POLL_INTERVAL)
            except KeyboardInterrupt:
                break
            except Exception as e:
                print(f"[ERROR] {e}")
                time.sleep(POLL_INTERVAL)

        print("Bridge stopped.")


def main():
    bridge = Bridge()

    def signal_handler(sig, frame):
        print("\nShutting down...")
        bridge.running = False

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    bridge.run()


if __name__ == "__main__":
    main()
