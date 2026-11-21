#!/usr/bin/env python3
"""Patch better_player_plus for reliable embedded-torrent HTTP playback.

Media3's stock DefaultHttpDataSource read timeout is 8 seconds. MovieBox's
loopback torrent bridge waits for a verified full piece before committing HTTP
headers, so the plugin's read timeout must exceed that bounded wait. This script
sets it to 60 seconds and installs a bounded HTTP 503 retry policy for opaque
progressive (CONTENT_TYPE_OTHER) streams.

Run after flutter pub get and before Gradle compiles the Android plugin.
Unknown source layouts fail closed instead of silently using default timeouts.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from urllib.parse import urljoin, urlparse

MOVIEBOX_TORRENT_READ_TIMEOUT_MS = 60_000
REQUIRED_FIRST_PIECE_WAIT_MS = 45_000

IMPORTS = (
    "import androidx.media3.common.C",
    "import androidx.media3.datasource.HttpDataSource",
    "import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy",
    "import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy",
)

POLICY_CLASS = """private class MovieBox503RetryPolicy : DefaultLoadErrorHandlingPolicy(3) {
    override fun getRetryDelayMsFor(
        loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo
    ): Long {
        var cause: Throwable? = loadErrorInfo.exception
        var responseCode: Int? = null
        while (cause != null) {
            if (cause is HttpDataSource.InvalidResponseCodeException) {
                responseCode = cause.responseCode
                break
            }
            cause = cause.cause
        }
        if (responseCode == 503) {
            // Two bounded retries, one second apart; the third 503 is fatal.
            return if (loadErrorInfo.errorCount <= 2) 1_000L else C.TIME_UNSET
        }
        return super.getRetryDelayMsFor(loadErrorInfo)
    }
}
"""


def resolve_package_root(package_root: str | None) -> Path:
    if package_root:
        return Path(package_root).resolve()
    config_path = Path(".dart_tool/package_config.json").resolve()
    if not config_path.is_file():
        raise SystemExit("Missing .dart_tool/package_config.json; run flutter pub get first.")
    config = json.loads(config_path.read_text(encoding="utf-8"))
    entry = next(
        (item for item in config.get("packages", []) if item.get("name") == "better_player_plus"),
        None,
    )
    if entry is None:
        raise SystemExit("better_player_plus is not present in package_config.json.")
    root_uri = urljoin(config_path.as_uri(), entry["rootUri"])
    parsed = urlparse(root_uri)
    if parsed.scheme != "file":
        raise SystemExit(f"Unsupported better_player_plus root URI: {root_uri}")
    return Path(parsed.path).resolve()


def patch_data_source_utils(source: str) -> str:
    """Raise Media3's HTTP read timeout above the native first-piece wait."""
    timeout_setting = ".setReadTimeoutMs(DefaultHttpDataSource.DEFAULT_READ_TIMEOUT_MILLIS)"
    patched_setting = ".setReadTimeoutMs(MOVIEBOX_TORRENT_READ_TIMEOUT_MS)"
    marker = "private const val MOVIEBOX_TORRENT_READ_TIMEOUT_MS = 60_000"

    if marker in source:
        if patched_setting not in source:
            raise SystemExit(
                "Torrent read-timeout marker exists but the DataSource factory is not using it."
            )
        return source

    if source.count(timeout_setting) != 1:
        raise SystemExit(
            "Expected exactly one DefaultHttpDataSource default read-timeout setting "
            "in DataSourceUtils.kt; refusing an unsafe plugin patch."
        )
    object_pattern = re.compile(r"^(internal\\s+)?object DataSourceUtils\\s*\\{", re.MULTILINE)
    object_match = object_pattern.search(source)
    if object_match is None:
        raise SystemExit("Could not locate DataSourceUtils object; refusing an unsafe plugin patch.")

    source = (
        source[:object_match.end()]
        + f"\\n    // Must exceed EmbeddedTorrentEngine's 45-second verified-piece wait.\\n"
        + f"    private const val MOVIEBOX_TORRENT_READ_TIMEOUT_MS = {MOVIEBOX_TORRENT_READ_TIMEOUT_MS}\\n"
        + source[object_match.end():]
    )
    source = source.replace(timeout_setting, patched_setting, 1)
    return source


def patch_better_player(source: str) -> str:
    if "MovieBox503RetryPolicy" in source:
        if "setLoadErrorHandlingPolicy(MovieBox503RetryPolicy())" not in source:
            raise SystemExit(
                "Retry policy class exists but is not installed on the progressive source."
            )
        return source

    package_match = re.search(r"^package [^\\n]+\\n", source, re.MULTILINE)
    if package_match is None:
        raise SystemExit("BetterPlayer.kt has no Kotlin package declaration.")
    import_text = "".join(item + "\\n" for item in IMPORTS if item not in source)
    source = source[:package_match.end()] + import_text + source[package_match.end():]

    class_match = re.search(
        r"^(?:internal\\s+)?class BetterPlayer\\s*\\(",
        source,
        re.MULTILINE,
    )
    if class_match is None:
        raise SystemExit("Could not locate BetterPlayer class declaration.")
    source = source[:class_match.start()] + POLICY_CLASS + "\\n" + source[class_match.start():]

    factory_pattern = re.compile(
        r"(C\\.CONTENT_TYPE_OTHER\\s*->\\s*ProgressiveMediaSource\\.Factory\\([\\s\\S]*?\\)\\.apply\\s*\\{)",
        re.MULTILINE,
    )
    source, count = factory_pattern.subn(
        r"\\1\\n                setLoadErrorHandlingPolicy(MovieBox503RetryPolicy())",
        source,
        count=1,
    )
    if count != 1:
        raise SystemExit(
            "Could not safely locate the progressive Media3 source factory; "
            "refusing an unpatched build."
        )
    return source


def self_test() -> None:
    """Fail fast if the plugin source patch stops matching its expected API."""
    fixture = """package uz.shs.better_player_plus

import androidx.media3.datasource.DefaultHttpDataSource

internal object DataSourceUtils {
    fun source() = DefaultHttpDataSource.Factory()
        .setReadTimeoutMs(DefaultHttpDataSource.DEFAULT_READ_TIMEOUT_MILLIS)
}
"""
    patched = patch_data_source_utils(fixture)
    assert f"private const val MOVIEBOX_TORRENT_READ_TIMEOUT_MS = {MOVIEBOX_TORRENT_READ_TIMEOUT_MS}" in patched
    assert ".setReadTimeoutMs(MOVIEBOX_TORRENT_READ_TIMEOUT_MS)" in patched
    assert patch_data_source_utils(patched) == patched
    try:
        patch_data_source_utils(fixture.replace(
            ".setReadTimeoutMs(DefaultHttpDataSource.DEFAULT_READ_TIMEOUT_MILLIS)",
            ".setReadTimeoutMs(8_000)",
        ))
    except SystemExit:
        pass
    else:
        raise AssertionError("Unexpected DataSourceUtils layout must fail closed.")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-root", help="Resolved better_player_plus package root (for tests)")
    args = parser.parse_args()

    if MOVIEBOX_TORRENT_READ_TIMEOUT_MS <= REQUIRED_FIRST_PIECE_WAIT_MS:
        raise SystemExit("Media3 read timeout must exceed the native first-piece wait.")
    self_test()

    root = resolve_package_root(args.package_root)
    android_root = root / "android"
    better_player_files = sorted(android_root.rglob("BetterPlayer.kt"))
    data_source_files = sorted(android_root.rglob("DataSourceUtils.kt"))
    if len(better_player_files) != 1:
        raise SystemExit(
            f"Expected exactly one Android BetterPlayer.kt under {root}; "
            f"found {len(better_player_files)}."
        )
    if len(data_source_files) != 1:
        raise SystemExit(
            f"Expected exactly one Android DataSourceUtils.kt under {root}; "
            f"found {len(data_source_files)}."
        )

    better_player_path = better_player_files[0]
    data_source_path = data_source_files[0]
    better_player_original = better_player_path.read_text(encoding="utf-8")
    data_source_original = data_source_path.read_text(encoding="utf-8")
    patched_better_player = patch_better_player(better_player_original)
    patched_data_source = patch_data_source_utils(data_source_original)

    # Write both plugin files only after both transformations validate.
    if patched_better_player != better_player_original:
        better_player_path.write_text(patched_better_player, encoding="utf-8")
    if patched_data_source != data_source_original:
        data_source_path.write_text(patched_data_source, encoding="utf-8")

    if "setLoadErrorHandlingPolicy(MovieBox503RetryPolicy())" not in patched_better_player:
        raise SystemExit("Bounded Media3 503 policy installation verification failed.")
    if (
        "private const val MOVIEBOX_TORRENT_READ_TIMEOUT_MS = 60_000" not in patched_data_source
        or ".setReadTimeoutMs(MOVIEBOX_TORRENT_READ_TIMEOUT_MS)" not in patched_data_source
    ):
        raise SystemExit("Media3 torrent HTTP read-timeout installation verification failed.")

    print(f"Installed bounded Media3 503 retry policy in {better_player_path}")
    print(
        f"Installed {MOVIEBOX_TORRENT_READ_TIMEOUT_MS}ms Media3 HTTP read timeout "
        f"in {data_source_path} (native piece wait: {REQUIRED_FIRST_PIECE_WAIT_MS}ms)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
