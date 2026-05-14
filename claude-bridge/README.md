# Claude Bridge

Control [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [Codex](https://openai.com/index/introducing-codex/) from your phone via iMessage. Text a command, get a response — no laptop screen required.

```
You (iMessage)  -->  macOS Messages DB  -->  bridge.py  -->  Claude Code CLI
                                                         |
                                                         -->  Codex CLI
```

## Why

Sometimes you're away from your desk but want to kick off a task, check on a project, or ask your agent a quick question. Claude Bridge polls your Mac's iMessage database, forwards your texts to the agent CLI, and sends the response back as a text.

## Requirements

- **macOS** (uses the Messages app and AppleScript)
- **Python 3.10+**
- **Claude Code CLI** (`claude`) installed and in your PATH
- **Codex CLI** (`codex`) installed and in your PATH *(optional — only if you want to use `/codex`)*
- **Full Disk Access** granted to your terminal app (System Settings > Privacy & Security > Full Disk Access) — needed to read `~/Library/Messages/chat.db`

## Setup

### 1. Configure your phone number

Open `config.py` and add your phone number and/or iMessage email to `AUTHORIZED_SENDERS`. Only messages from these senders are processed — everything else is ignored.

```python
AUTHORIZED_SENDERS = [
    "+15551234567",       # your phone number (with country code)
    "you@example.com",    # or your iMessage email
]
```

### 2. Set your default working directory

All `/project` commands resolve subfolders relative to this path. For example, if `DEFAULT_WORKDIR` is `~/projects` and you send `/project my-app`, the agent runs in `~/projects/my-app`.

```python
DEFAULT_WORKDIR = os.path.expanduser("~/projects")
```

### 3. SMS vs iMessage preference (optional)

If a recipient's number doesn't support iMessage (e.g. an Android phone), add it to `SMS_PREFERRED` so the bridge tries SMS first:

```python
SMS_PREFERRED = [
    "+15559876543",
]
```

### 4. Allowed tools (optional)

`ALLOWED_TOOLS` controls which Claude Code tools the agent can use without prompting. The defaults are read-only operations. Add more if you want the agent to edit files, run builds, etc.

```python
ALLOWED_TOOLS = [
    "Read",
    "Bash(git *)",
    "Bash(ls *)",
    # add "Edit", "Write", etc. for write access
]
```

### 5. Run it

```bash
python bridge.py
```

The bridge prints a startup message and begins polling. Send a text from your phone to get started.

## Commands

Send these as iMessages from your authorized phone:

| Command | What it does |
| :--- | :--- |
| `/project <subfolder>` | Start a new agent session in `DEFAULT_WORKDIR/<subfolder>` |
| `/status` | Show current agent, project, session ID, and uptime |
| `/exit` | End the current session (prints session ID for resuming later) |
| `/resume <session-id>` | Resume a previous session by ID |
| `/claude` | Switch to Claude Code as the active agent |
| `/codex` | Switch to Codex as the active agent |
| `/kill` | Shut down the bridge process |
| *(any other text)* | Forwarded to the active agent as a prompt |

## Usage Example

```
You:     /project my-app
Bridge:  Claude session started in ~/projects/my-app
         Session ID: a1b2c3d4-...

You:     what files are in the src directory?
Bridge:  The src directory contains:
         - main.py
         - utils.py
         - config.py

You:     /codex
Bridge:  Switched to Codex in ~/projects/my-app

You:     /status
Bridge:  Agent: Codex
         Project: ~/projects/my-app
         Session ID: e5f6g7h8-...
         Uptime: 3m

You:     /exit
Bridge:  Session ended. Session ID: e5f6g7h8-...
         Send /resume e5f6g7h8-... to resume later.
```

## How It Works

1. **Polls** the macOS Messages SQLite database (`~/Library/Messages/chat.db`) every 2 seconds for new messages from authorized senders
2. **Parses** incoming text as either a `/command` or a plain message
3. **Forwards** plain messages to the active agent CLI (`claude` or `codex`) as a prompt
4. **Sends** the agent's response back via iMessage (using AppleScript)
5. **Queues** messages that arrive while the agent is busy and processes them in order

Image attachments sent via iMessage are detected and passed to the agent as `[Image: /path/to/file]` references.

## Notes

- The bridge runs in **`acceptEdits`** permission mode for Claude Code — the agent can read and edit files but will not run arbitrary commands beyond what's in `ALLOWED_TOOLS`.
- Sessions persist across messages. The agent remembers context from earlier in the conversation. Use `/exit` + `/resume` to pause and pick up later.
- Only one message is processed at a time. If you send multiple messages while the agent is thinking, they're queued and processed in order.
- No external dependencies — stdlib only (sqlite3, subprocess, threading, etc.).

## License

MIT
