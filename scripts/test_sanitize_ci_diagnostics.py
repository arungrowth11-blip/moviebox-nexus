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
            f"/data/user_de/0/com.moviebox/files/secret.json {base32_hash}"
        )
        safe = sanitize_line(raw)
        for secret in (hex_hash, base32_hash, "provider.example", "private-token", "10.2.3.4", "/data/user_de/"):
            self.assertNotIn(secret, safe)
        self.assertIn("<redacted", safe)

    def test_redacts_lowercase_base32_ipv6_and_android_storage_aliases(self) -> None:
        lower_base32_hash = "c" * 32
        ipv6 = "2001:db8::1"
        raw = (
            f"{lower_base32_hash} {ipv6} "
            "/sdcard/Movies/private.mkv "
            "/mnt/sdcard/Android/data/com.moviebox/cache "
            "/storage/self/primary/Download/private.zip "
            "/storage/ABCD-1234/private.mkv "
            "/data/media/0/DCIM/private.jpg"
        )
        safe = sanitize_line(raw)
        for secret in (
            lower_base32_hash,
            ipv6,
            "/sdcard/",
            "/mnt/sdcard/",
            "/storage/self/primary/",
            "/storage/ABCD-1234/",
            "/data/media/0/",
        ):
            self.assertNotIn(secret, safe)
        self.assertGreaterEqual(safe.count("<redacted-path>"), 5)
        self.assertIn("<redacted-infohash>", safe)
        self.assertIn("<redacted-ip>", safe)

    def test_stack_frames_are_retained_in_sanitized_failure_excerpt(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "raw.log"
            destination = Path(tmp) / "safe.log"
            source.write_text(
                "routine progress line\n"
                "#12 0x0000000000000000 in player_start\n"
                "at com.moviebox.Player.start(Player.kt:42)\n",
                encoding="utf-8",
            )
            sanitize_log(source, destination)
            safe = destination.read_text(encoding="utf-8")
            self.assertIn("#12", safe)
            self.assertIn("at com.moviebox.Player.start(Player.kt:42)", safe)
            self.assertNotIn("routine progress line", safe)

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
