#!/usr/bin/env python3
"""Create small, redacted failure excerpts for public GitHub Actions artifacts."""
from __future__ import annotations

import re
import sys
from collections import deque
from pathlib import Path

MAX_OUTPUT_BYTES = 64 * 1024
MAX_SELECTED_LINES = 200

REDACTIONS = (
    (re.compile(r"""(?i)magnet:\?[^\s"'<>]+"""), "<redacted-magnet>"),
    (re.compile(r"""(?i)\b(?:https?|udp)://[^\s"'<>]+"""), "<redacted-url>"),
    (
        re.compile(r"""(?i)(["']?(?:token|authorization|api[_-]?key|password|secret)["']?\s*[:=]\s*["']?)(?:Bearer\s+)?[^\s"',;}]+"""),
        r"\1<redacted>",
    ),
    (re.compile(r"""\b[a-fA-F0-9]{40}\b"""), "<redacted-infohash>"),
    (re.compile(r"""\b[A-Z2-7]{32}\b"""), "<redacted-infohash>"),
    (re.compile(r"""\b(?:\d{1,3}\.){3}\d{1,3}\b"""), "<redacted-ip>"),
    (
        re.compile(r"""(?:/data/(?:user|user_de)/\d+/[^\s"'<>]*|/data/data/[^\s"'<>]*|/storage/emulated/\d+/[^\s"'<>]*|/home/[^\s"'<>]*)"""),
        "<redacted-path>",
    ),
)
RELEVANT = re.compile(
    r"(?i)(error|exception|failed|failure|fatal|assert|expected|actual|timeout|timed out|gradle task|test result|#\d+|\bat\s+\S+)"
)


def sanitize_line(line: str) -> str:
    value = line.rstrip("\r\n")
    for pattern, replacement in REDACTIONS:
        value = pattern.sub(replacement, value)
    return value[:1200]


def sanitize_log(source: Path, destination: Path) -> None:
    selected: deque[str] = deque(maxlen=MAX_SELECTED_LINES)
    fallback: deque[str] = deque(maxlen=40)
    with source.open("r", encoding="utf-8", errors="replace") as stream:
        for raw in stream:
            cleaned = sanitize_line(raw)
            fallback.append(cleaned)
            if RELEVANT.search(cleaned):
                selected.append(cleaned)

    lines = list(selected) if selected else list(fallback)
    header = "[sanitized failure excerpt; URLs, hashes, credentials, IPs and private paths redacted]\n"
    output_lines = [header]
    used = len(header.encode("utf-8"))
    for line in lines:
        candidate = line + "\n"
        size = len(candidate.encode("utf-8"))
        if used + size > MAX_OUTPUT_BYTES:
            break
        output_lines.append(candidate)
        used += size
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("".join(output_lines), encoding="utf-8")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: sanitize_ci_diagnostics.py INPUT_LOG OUTPUT_LOG", file=sys.stderr)
        return 2
    source, destination = map(Path, sys.argv[1:])
    if not source.is_file():
        print("input diagnostic log is missing", file=sys.stderr)
        return 2
    sanitize_log(source, destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
