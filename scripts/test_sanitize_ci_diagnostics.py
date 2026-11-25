#!/usr/bin/env python3
"""Regression tests for the public CI diagnostic sanitizer."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from sanitize_ci_diagnostics import MAX_OUTPUT_BYTES, sanitize_line, sanitize_log


class SanitizerTests(unittest.TestCase):
    def test_redacts_urls_hashes_credentials_ip_and_android_paths(self) -> None:
        hex_hash = "a" * 40
        base32_hash = "B" * 32
        raw = (
            f"magnet:?xt=urn:btih:{hex_hash} https://provider.example/private "
            f"Authorization: Bearer private-token 10.2.3.4 "
            f"/data/user_de/0/com.moviebox/files/secret.json"
        )
        safe = sanitize_line(raw)
        for secret in (hex_hash, base32_hash, "provider.example", "private-token", "10.2.3.4", "/data/user_de/"):
            self.assertNotIn(secret, safe)
        self.assertIn("<redacted", safe)

    def test_sanitized_excerpt_is_bounded_and_contains_only_redacted_failure_lines(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "raw.log"
            destination = Path(tmp) / "safe.log"
            source.write_text(
                ("routine progress line\n" * 5000)
                + ("ERROR https://secret.example/video " + "x" * 1500 + "\n"),
                encoding="utf-8",
            )
            sanitize_log(source, destination)
            data = destination.read_bytes()
            self.assertLessEqual(len(data), MAX_OUTPUT_BYTES)
            text = data.decode("utf-8")
            self.assertIn("ERROR", text)
            self.assertNotIn("secret.example", text)
            self.assertNotIn("routine progress line", text)


if __name__ == "__main__":
    unittest.main()
