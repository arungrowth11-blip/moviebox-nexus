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

    expected_signing_sha256 = "6588a39dd9b56035c9ba957e243da9e156437e57aafea9a1acf92877544c9d2f"
    required_signing = (
        "ANDROID_KEYSTORE_BASE64",
        "ANDROID_KEYSTORE_PASSWORD",
        "ANDROID_KEY_ALIAS",
        "ANDROID_KEY_PASSWORD",
        "MOVIEBOX_RELEASE_KEYSTORE",
        "keytool -list -v",
        "PKCS12 store-password inspection",
        "PKCS12 alias inspection",
        "Configured release alias was not found",
        "Safe keytool diagnostics follow",
        'create("movieboxRelease")',
        'storeType = "PKCS12"',
        'signingConfig = signingConfigs.getByName("movieboxRelease")',
        "Verify release APK certificate fingerprint",
        expected_signing_sha256,
    )
    for token in required_signing:
        if token not in release:
            raise SystemExit(f"android-release is missing release-signing control: {token}")
    if expected_signing_sha256 not in verify or "actual_cert_sha256" not in verify:
        raise SystemExit("release-apk-verify does not enforce the pinned release certificate fingerprint.")

    required_verify = (
        "adb install -r",
        "pidof com.moviebox.nexus",
        "adb shell am start -n com.moviebox.nexus/.MainActivity",
        "main_window_block",
        "MainActivity",
        "mDrawState=HAS_DRAWN",
        "Surface: shown=true",
        "isVisible=true",
        "isOnScreen=true",
        "mFocusedApp=",
        "--print-certs",
        "Upload release APK verification diagnostics",
        "MovieBox-Release-APK-Verification-Diagnostics",
    )
    for token in required_verify:
        if token not in verify:
            raise SystemExit(f"release-apk-verify is missing required evidence step: {token}")
    if "id: dart-format" not in release or "steps.dart-format.outcome == 'failure'" not in release:
        raise SystemExit("Dart formatter repair must run only after the formatter gate itself fails.")

    if "firstWindowDrawn=true" in verify:
        raise SystemExit("APK verifier still trusts an unscoped ActivityRecord draw flag.")

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
