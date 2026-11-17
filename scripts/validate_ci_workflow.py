#!/usr/bin/env python3
"""Fail-closed static assertions for MovieBox's three-job Android CI topology."""
from __future__ import annotations

import re
from pathlib import Path

WORKFLOW = Path(".github/workflows/build.yml")


def job_block(source: str, name: str) -> str:
    pattern = re.compile(
        rf"^  {re.escape(name)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(source)
    if match is None:
        raise SystemExit(f"Missing required CI job: {name}")
    return match.group("body")


def main() -> int:
    source = WORKFLOW.read_text(encoding="utf-8")
    release = job_block(source, "android-release")
    integration = job_block(source, "integration-tests")
    verify = job_block(source, "release-apk-verify")

    if re.search(r"^    needs:", release, re.MULTILINE):
        raise SystemExit("android-release must run independently.")
    if re.search(r"^    needs:", integration, re.MULTILINE):
        raise SystemExit("integration-tests must run independently of the release build.")
    if not re.search(r"^    needs:\s*\[android-release\]", verify, re.MULTILINE):
        raise SystemExit("release-apk-verify must depend on android-release.")
    if "MovieBox-Nexus-OS-APK" not in release:
        raise SystemExit("android-release does not publish the expected APK artifact.")
    if "Download required release APK artifact" not in verify:
        raise SystemExit("release-apk-verify does not have a required artifact download step.")
    download_step = verify.split("      - name: Download required release APK artifact", 1)[1].split(
        "      - name:", 1
    )[0]
    if "continue-on-error: true" in download_step:
        raise SystemExit("Release APK artifact download must be mandatory.")
    if "continue-on-error: true" in integration:
        # The integration job must not tolerate a missing release artifact. The
        # legacy optional-download path is not allowed in the isolated design.
        raise SystemExit("integration-tests still contains an optional artifact failure path.")
    if "Download already-published release APK" in integration:
        raise SystemExit("Release APK download is still coupled to integration-tests.")

    required_verify = (
        "adb install -r",
        "pidof com.moviebox.nexus",
        "am start -W -n com.moviebox.nexus/.MainActivity",
        "Upload release APK verification diagnostics",
        "MovieBox-Release-APK-Verification-Diagnostics",
    )
    for token in required_verify:
        if token not in verify:
            raise SystemExit(f"release-apk-verify is missing required evidence step: {token}")
    for name, block, upload_name in (
        ("integration-tests", integration, "MovieBox-Emulator-Diagnostics"),
        ("release-apk-verify", verify, "MovieBox-Release-APK-Verification-Diagnostics"),
    ):
        if "if: always()" not in block or upload_name not in block:
            raise SystemExit(f"{name} must upload diagnostics with if: always().")

    if "MovieBox-Nexus-OS-APK" not in verify:
        raise SystemExit("release-apk-verify does not consume the release artifact.")
    print("CI topology verified: parallel release/integration, gated APK verify, mandatory artifact, dual diagnostics.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
