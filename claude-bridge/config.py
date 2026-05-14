import os

AUTHORIZED_SENDERS = [
    "+1XXXXXXXXXX",       # your phone number
    "you@example.com",    # or your iMessage email
]
SMS_PREFERRED = [
    # "+1XXXXXXXXXX",     # add numbers here that should prefer SMS over iMessage
]
DEFAULT_WORKDIR = os.path.expanduser("~/projects")
CHAT_DB_PATH = os.path.expanduser("~/Library/Messages/chat.db")
POLL_INTERVAL = 2
ALLOWED_TOOLS = [
    "Read",
    "Bash(git *)",
    "Bash(ls *)",
    "Bash(ls)",
    "Bash(find *)",
    "Bash(grep *)",
    "Bash(cat *)",
    "Bash(head *)",
    "Bash(tail *)",
    "Bash(wc *)",
    "Bash(pwd)",
    "Bash(which *)",
    "Bash(echo *)",
]
