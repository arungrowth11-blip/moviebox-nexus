#!/usr/bin/env python3
"""Patch better_player_plus for reliable embedded-torrent HTTP playback.

Media3's stock DefaultHttpDataSource read timeout is 8 seconds. MovieBox's
loopback torrent bridge waits for a verified full piece before committing HTTP
headers, so the plugin's read timeout must exceed that bounded wait. This script
sets a torrent-only 120-second read timeout and installs a bounded HTTP 503 retry policy for opaque
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

MOVIEBOX_TORRENT_READ_TIMEOUT_MS = 120_000
REQUIRED_METADATA_WAIT_MS = 65_000
REQUIRED_FIRST_PIECE_WAIT_MS = 45_000
MOVIEBOX_TORRENT_STREAM_HEADER = "X-MovieBox-Torrent-Stream"

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
    """Install a torrent-only read timeout and strip its internal marker header."""
    object_pattern = re.compile(
        r"^(internal\s+)?object DataSourceUtils\s*\{",
        re.MULTILINE,
    )
    object_match = object_pattern.search(source)
    if object_match is None:
        raise SystemExit("Could not locate DataSourceUtils object; refusing an unsafe plugin patch.")

    timeout_decl = re.compile(
        r"^[ \t]*private const val MOVIEBOX_TORRENT_READ_TIMEOUT_MS\s*=\s*[0-9][0-9_]*[ \t]*$",
        re.MULTILINE,
    )
    marker_decl = re.compile(
        r'^[ \t]*private const val MOVIEBOX_TORRENT_STREAM_HEADER\s*=\s*"[^"]+"[ \t]*$',
        re.MULTILINE,
    )
    timeout_declarations = list(timeout_decl.finditer(source))
    marker_declarations = list(marker_decl.finditer(source))
    if len(timeout_declarations) > 1 or len(marker_declarations) > 1:
        raise SystemExit("Duplicate MovieBox torrent HTTP configuration declarations found.")

    timeout_line = f"    private const val MOVIEBOX_TORRENT_READ_TIMEOUT_MS = {MOVIEBOX_TORRENT_READ_TIMEOUT_MS}"
    marker_line = (
        f'    private const val MOVIEBOX_TORRENT_STREAM_HEADER = "{MOVIEBOX_TORRENT_STREAM_HEADER}"'
    )
    if timeout_declarations:
        source = timeout_decl.sub(timeout_line, source, count=1)
    else:
        source = source[:object_match.end()] + "\n" + timeout_line + source[object_match.end():]
    if marker_declarations:
        source = marker_decl.sub(marker_line, source, count=1)
    else:
        refreshed_object = object_pattern.search(source)
        assert refreshed_object is not None
        source = source[:refreshed_object.end()] + "\n" + marker_line + source[refreshed_object.end():]

    helper_signature = "private fun isMovieBoxTorrentStream(headers: Map<String, String>?): Boolean"
    if helper_signature not in source:
        refreshed_object = object_pattern.search(source)
        assert refreshed_object is not None
        helper = """
    private fun isMovieBoxTorrentStream(headers: Map<String, String>?): Boolean =
        headers?.entries?.any { entry ->
            entry.key.equals(MOVIEBOX_TORRENT_STREAM_HEADER, ignoreCase = true) &&
                entry.value.equals("true", ignoreCase = true)
        } == true
"""
        source = source[:refreshed_object.end()] + helper + source[refreshed_object.end():]
    elif (
        "entry.key.equals(MOVIEBOX_TORRENT_STREAM_HEADER, ignoreCase = true)" not in source
        or 'entry.value.equals("true", ignoreCase = true)' not in source
    ):
        raise SystemExit("Existing torrent-stream marker helper has an unexpected implementation.")

    original_setter = re.compile(
        r"\.setReadTimeoutMs\(\s*(?:"
        r"DefaultHttpDataSource\.DEFAULT_READ_TIMEOUT_MILLIS|"
        r"MOVIEBOX_TORRENT_READ_TIMEOUT_MS"
        r")\s*\)"
    )
    conditional_setter = """.setReadTimeoutMs(
                if (isMovieBoxTorrentStream(headers)) MOVIEBOX_TORRENT_READ_TIMEOUT_MS
                else DefaultHttpDataSource.DEFAULT_READ_TIMEOUT_MILLIS
            )"""
    conditional_marker = "if (isMovieBoxTorrentStream(headers)) MOVIEBOX_TORRENT_READ_TIMEOUT_MS"
    if conditional_marker not in source:
        source, replaced = original_setter.subn(conditional_setter, source)
        if replaced != 1:
            relevant = [
                line for line in source.splitlines()
                if "ReadTimeout" in line or "DEFAULT_READ_TIMEOUT" in line
            ]
            raise SystemExit(
                "Could not safely patch exactly one DataSourceUtils read-timeout setter. "
                f"Observed timeout lines: {relevant!r}"
            )
    elif (
        "else DefaultHttpDataSource.DEFAULT_READ_TIMEOUT_MILLIS" not in source
        or ".setReadTimeoutMs(" not in source
    ):
        raise SystemExit("Existing torrent-aware Media3 read-timeout setter is incomplete.")

    assignment = "notNullHeaders[entry.key] = entry.value"
    filtered_assignment = """if (!entry.key.equals(MOVIEBOX_TORRENT_STREAM_HEADER, ignoreCase = true)) {
                    notNullHeaders[entry.key] = entry.value
                }"""
    filter_marker = "entry.key.equals(MOVIEBOX_TORRENT_STREAM_HEADER, ignoreCase = true)"
    if filter_marker not in source:
        if source.count(assignment) != 1:
            raise SystemExit(
                "Could not safely locate the single DataSourceUtils request-header copy loop."
            )
        source = source.replace(assignment, filtered_assignment, 1)
    elif assignment not in source:
        raise SystemExit("Torrent marker header filter exists but request headers are not copied as expected.")

    if (
        timeout_line not in source
        or marker_line not in source
        or helper_signature not in source
        or conditional_marker not in source
        or "else DefaultHttpDataSource.DEFAULT_READ_TIMEOUT_MILLIS" not in source
        or filter_marker not in source
    ):
        raise SystemExit("Torrent-only Media3 read-timeout installation is incomplete.")
    return source


def patch_better_player(source: str) -> str:
    if "MovieBox503RetryPolicy" in source:
        if "setLoadErrorHandlingPolicy(MovieBox503RetryPolicy())" not in source:
            raise SystemExit(
                "Retry policy class exists but is not installed on the progressive source."
            )
        return source

    package_match = re.search(r"^package [^\n]+\n", source, re.MULTILINE)
    if package_match is None:
        raise SystemExit("BetterPlayer.kt has no Kotlin package declaration.")
    import_text = "".join(item + "\n" for item in IMPORTS if item not in source)
    source = source[:package_match.end()] + import_text + source[package_match.end():]

    class_match = re.search(
        r"^(?:internal\s+)?class BetterPlayer\s*\(",
        source,
        re.MULTILINE,
    )
    if class_match is None:
        raise SystemExit("Could not locate BetterPlayer class declaration.")
    source = source[:class_match.start()] + POLICY_CLASS + "\n" + source[class_match.start():]

    factory_pattern = re.compile(
        r"(C\.CONTENT_TYPE_OTHER\s*->\s*ProgressiveMediaSource\.Factory\([\s\S]*?\)\.apply\s*\{)",
        re.MULTILINE,
    )
    source, count = factory_pattern.subn(
        r"\1\n                setLoadErrorHandlingPolicy(MovieBox503RetryPolicy())",
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
    """Exercise original, global-timeout, partial-cache, and unknown source layouts."""
    fixture = """package uz.shs.better_player_plus

import androidx.media3.datasource.DefaultHttpDataSource

internal object DataSourceUtils {
    fun getDataSourceFactory(
        userAgent: String?,
        headers: Map<String, String>?
    ): DataSource.Factory {
        val dataSourceFactory = DefaultHttpDataSource.Factory()
            .setReadTimeoutMs(DefaultHttpDataSource.DEFAULT_READ_TIMEOUT_MILLIS)
        if (headers != null) {
            val notNullHeaders = mutableMapOf<String, String>()
            headers.forEach { entry ->
                notNullHeaders[entry.key] = entry.value
            }
            dataSourceFactory.setDefaultRequestProperties(notNullHeaders)
        }
        return dataSourceFactory
    }
}
"""
    patched = patch_data_source_utils(fixture)
    assert f"private const val MOVIEBOX_TORRENT_READ_TIMEOUT_MS = {MOVIEBOX_TORRENT_READ_TIMEOUT_MS}" in patched
    assert f'private const val MOVIEBOX_TORRENT_STREAM_HEADER = "{MOVIEBOX_TORRENT_STREAM_HEADER}"' in patched
    assert "if (isMovieBoxTorrentStream(headers)) MOVIEBOX_TORRENT_READ_TIMEOUT_MS" in patched
    assert "else DefaultHttpDataSource.DEFAULT_READ_TIMEOUT_MILLIS" in patched
    assert "entry.key.equals(MOVIEBOX_TORRENT_STREAM_HEADER, ignoreCase = true)" in patched
    assert patch_data_source_utils(patched) == patched

    # Repair the previous global 60-second cache patch and make it torrent-only.
    legacy_global = fixture.replace(
        "internal object DataSourceUtils {",
        "internal object DataSourceUtils {\n"
        "    private const val MOVIEBOX_TORRENT_READ_TIMEOUT_MS = 60_000",
    ).replace(
        ".setReadTimeoutMs(DefaultHttpDataSource.DEFAULT_READ_TIMEOUT_MILLIS)",
        ".setReadTimeoutMs(MOVIEBOX_TORRENT_READ_TIMEOUT_MS)",
    )
    repaired = patch_data_source_utils(legacy_global)
    assert f"private const val MOVIEBOX_TORRENT_READ_TIMEOUT_MS = {MOVIEBOX_TORRENT_READ_TIMEOUT_MS}" in repaired
    assert "if (isMovieBoxTorrentStream(headers)) MOVIEBOX_TORRENT_READ_TIMEOUT_MS" in repaired
    assert patch_data_source_utils(repaired) == repaired

    bad_fixture = fixture.replace(
        ".setReadTimeoutMs(DefaultHttpDataSource.DEFAULT_READ_TIMEOUT_MILLIS)",
        ".setReadTimeoutMs(8_000)",
    )
    try:
        patch_data_source_utils(bad_fixture)
    except SystemExit:
        pass
    else:
        raise AssertionError("Unexpected DataSourceUtils layout must fail closed.")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-root", help="Resolved better_player_plus package root (for tests)")
    args = parser.parse_args()

    if MOVIEBOX_TORRENT_READ_TIMEOUT_MS <= (
        REQUIRED_METADATA_WAIT_MS + REQUIRED_FIRST_PIECE_WAIT_MS
    ):
        raise SystemExit(
            "Torrent read timeout must exceed the metadata wait plus first verified-piece wait."
        )
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

    # Validate both transformations before writing either plugin file.
    if "setLoadErrorHandlingPolicy(MovieBox503RetryPolicy())" not in patched_better_player:
        raise SystemExit("Bounded Media3 503 policy installation verification failed.")
    if (
        f"private const val MOVIEBOX_TORRENT_READ_TIMEOUT_MS = {MOVIEBOX_TORRENT_READ_TIMEOUT_MS}" not in patched_data_source
        or f'private const val MOVIEBOX_TORRENT_STREAM_HEADER = "{MOVIEBOX_TORRENT_STREAM_HEADER}"' not in patched_data_source
        or "if (isMovieBoxTorrentStream(headers)) MOVIEBOX_TORRENT_READ_TIMEOUT_MS" not in patched_data_source
        or "else DefaultHttpDataSource.DEFAULT_READ_TIMEOUT_MILLIS" not in patched_data_source
        or "entry.key.equals(MOVIEBOX_TORRENT_STREAM_HEADER, ignoreCase = true)" not in patched_data_source
    ):
        raise SystemExit("Torrent-only Media3 read-timeout installation verification failed.")

    if patched_better_player != better_player_original:
        better_player_path.write_text(patched_better_player, encoding="utf-8")
    if patched_data_source != data_source_original:
        data_source_path.write_text(patched_data_source, encoding="utf-8")

    print(f"Installed bounded Media3 503 retry policy in {better_player_path}")
    print(
        f"Installed torrent-only {MOVIEBOX_TORRENT_READ_TIMEOUT_MS}ms Media3 HTTP read timeout "
        f"in {data_source_path}; ordinary HTTP retains the stock timeout."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
