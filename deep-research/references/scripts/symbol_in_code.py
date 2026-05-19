#!/usr/bin/env python3
"""symbol_in_code.py — heuristic check that SYMBOL on FILE:LINE is code, not comment/string.

Usage: symbol_in_code.py <file> <line> <symbol>
Exits 0 if SYMBOL appears as code on that line; 1 if it's in a comment or string literal.

Heuristic-only (not a full lexer). Documented limitations:
- Triple-quoted Python docstrings spanning many lines: may misclassify (over-permissive).
- Long C++ template signatures: may not detect.
- Ambiguous or unknown extensions: defaults to "in code" (over-permissive — over-rejection
  creates more false STALE tags than desired).
"""

import re
import sys
from pathlib import Path


COMMENT_MARKERS = {
    ".py": ["#"],
    ".sh": ["#"],
    ".rb": ["#"],
    ".pl": ["#"],
    ".cpp": ["//"],
    ".hpp": ["//"],
    ".h": ["//"],
    ".c": ["//"],
    ".cc": ["//"],
    ".ts": ["//"],
    ".tsx": ["//"],
    ".js": ["//"],
    ".jsx": ["//"],
    ".swift": ["//"],
    ".kt": ["//"],
    ".java": ["//"],
    ".rs": ["//"],
    ".go": ["//"],
    ".sql": ["--", "//"],
}


def line_is_comment(text: str, ext: str) -> bool:
    """True if the line is a single-line comment (i.e., comment marker before any code)."""
    stripped = text.lstrip()
    for marker in COMMENT_MARKERS.get(ext, []):
        if stripped.startswith(marker):
            return True
    return False


def symbol_in_string_literal(text: str, symbol: str) -> bool:
    """Heuristic: True if SYMBOL appears only inside paired quotes on the line.

    Over-permissive: if SYMBOL appears both inside and outside quotes, returns False
    (treats as code — better to over-verify than over-reject).
    """
    if symbol not in text:
        return False
    spans = []
    for m in re.finditer(r'"[^"\\]*(?:\\.[^"\\]*)*"', text):
        spans.append(m.span())
    for m in re.finditer(r"'[^'\\]*(?:\\.[^'\\]*)*'", text):
        spans.append(m.span())
    sym_positions = [m.start() for m in re.finditer(re.escape(symbol), text)]
    if not sym_positions:
        return False
    for pos in sym_positions:
        in_string = False
        for start, end in spans:
            if start < pos < end:
                in_string = True
                break
        if not in_string:
            return False
    return True


def main() -> int:
    if len(sys.argv) != 4:
        print(f"usage: {sys.argv[0]} <file> <line> <symbol>", file=sys.stderr)
        return 2
    file_path = Path(sys.argv[1])
    line_no = int(sys.argv[2])
    symbol = sys.argv[3]
    if not file_path.exists():
        print(f"file not found: {file_path}", file=sys.stderr)
        return 2
    lines = file_path.read_text(errors="replace").splitlines()
    if line_no < 1 or line_no > len(lines):
        print(
            f"line {line_no} out of range (file has {len(lines)} lines)",
            file=sys.stderr,
        )
        return 2
    text = lines[line_no - 1]
    ext = file_path.suffix.lower()
    if line_is_comment(text, ext):
        return 1
    if symbol_in_string_literal(text, symbol):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
