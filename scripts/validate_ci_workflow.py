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

    # Pull-request workflows normally check out GitHub's synthetic merge ref.
    # Verify each job instead checks and records the exact source head SHA.
    for name, block in (
        ("android-release", release),
        ("release-apk-verify", verify),
        ("integration-tests", integration),
    ):
        if block.count("Verify checked-out source commit") != 1:
            raise SystemExit(f"{name} must verify its exact source-head checkout.")
        checkout = block.split("      - name: Checkout repository", 1)[1].split(
            "      - name:", 1
        )[0]
        for token in (
            "repository: ${{ github.event.pull_request.head.repo.full_name || github.repository }}",
            "ref: ${{ github.event.pull_request.head.sha || github.sha }}",
            "persist-credentials: false",
        ):
            if token not in checkout:
                raise SystemExit(f"{name} checkout is missing exact-head control: {token}")
        if "EXPECTED_SOURCE_SHA" not in block or "git rev-parse HEAD" not in block:
            raise SystemExit(f"{name} does not compare the worktree commit to the event source SHA.")

    player_source = Path("lib/player_screen.dart").read_text(encoding="utf-8")
    dispose_start = player_source.find("Future<void> _disposeMedia3Safely")
    dispose_end = player_source.find(
        "Future<void> _startMedia3Serialized", dispose_start
    )
    if dispose_start < 0 or dispose_end <= dispose_start:
        raise SystemExit("Could not inspect the Media3 single-owner disposal method.")
    dispose_method = player_source[dispose_start:dispose_end]
    if "controller.dispose(forceDispose: true)" not in dispose_method:
        raise SystemExit("BetterPlayer wrapper must own and release the native controller.")
    if "nativeController?.dispose()" in dispose_method or "nativeRelease" in dispose_method:
        raise SystemExit("Native VideoPlayerController must not be double-disposed.")

    if "MOVIEBOX_GITHUB_APP_CLIENT_ID" not in release or "MOVIEBOX_DIAGNOSTICS_REPOSITORY" not in release:
        raise SystemExit("Release APK must accept the private diagnostic GitHub App configuration.")
    if "--dart-define" not in release:
        raise SystemExit("Private diagnostics GitHub App values are not compiled into the release APK.")
    if "flutter_secure_storage: ^10.3.4" not in Path("pubspec.yaml").read_text(encoding="utf-8"):
        raise SystemExit("Private diagnostics OAuth tokens must use Android encrypted storage.")

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
        if "if: failure()" not in block or upload_name not in block:
            raise SystemExit(f"{name} must upload diagnostics only after a failed job.")
        if "retention-days: 7" not in block:
            raise SystemExit(f"{name} diagnostics must expire after seven days.")

    for required_file in (
        "native/android/PlaybackDiagnosticStore.kt",
        "native/android-test/PlaybackDiagnosticStoreTest.kt",
        "scripts/sanitize_ci_diagnostics.py",
        "scripts/test_sanitize_ci_diagnostics.py",
        "lib/src/diagnostics/github_diagnostics_uploader.dart",
        "test/github_diagnostics_uploader_test.dart",
        "docs/private-playback-diagnostics-upload.md",
    ):
        if not Path(required_file).is_file():
            raise SystemExit(f"Missing playback diagnostic source/test: {required_file}")

    if "MovieBox-Nexus-OS-APK" not in verify:
        raise SystemExit("release-apk-verify does not consume the release artifact.")
    if 'python3 scripts/sanitize_ci_diagnostics.py "$raw_log" "$sanitized_log"' not in integration:
        raise SystemExit("Integration failures must pass through the CI diagnostic sanitizer.")
    if 'rm -f "$raw_log"' not in integration:
        raise SystemExit("Raw integration logs must be deleted before artifact upload.")
    if "flutter-integration-sanitized.log" not in integration:
        raise SystemExit("Sanitized integration failure excerpt is not retained.")
    if 'find "$diagnostics_dir" -maxdepth 1 -type f' not in verify:
        raise SystemExit("Release diagnostics must enforce a public artifact file allowlist.")
    forbidden_artifact_patterns = (
        'adb logcat -d -v threadtime > "$diagnostics_dir/',
        'adb shell dumpsys activity activities > "$diagnostics_dir/',
        'adb shell dumpsys window windows > "$diagnostics_dir/',
        'cp dist/MovieBox-Nexus-OS.apk "$diagnostics_dir/"',
        'cp "$RUNNER_TEMP/moviebox-local-seed.log" "$diagnostics_dir/"',
        'cp "$RUNNER_TEMP/moviebox-emulator-script.sh" "$diagnostics_dir/"',
        'tee "$diagnostics_dir/flutter-integration.log"',
    )
    if any(pattern in integration + verify for pattern in forbidden_artifact_patterns):
        raise SystemExit("Raw emulator logs, system dumps, scripts, or APK bytes must not enter public failure artifacts.")
    print("CI topology verified: isolated release/integration, gated APK verify, failure-only bounded diagnostics.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
