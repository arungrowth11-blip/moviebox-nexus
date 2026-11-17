#!/usr/bin/env python3
"""Install MovieBox's bounded HTTP 503 retry policy in better_player_plus.

The plugin does not currently expose Media3 LoadErrorHandlingPolicy through its
Dart API. Patch the resolved Android plugin source after flutter pub get and
before Gradle compiles it. The patch is deliberately fail-closed: an unknown
plugin source layout stops the build instead of silently using default policy.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from urllib.parse import urljoin, urlparse

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
    entry = next((item for item in config.get("packages", []) if item.get("name") == "better_player_plus"), None)
    if entry is None:
        raise SystemExit("better_player_plus is not present in package_config.json.")
    root_uri = urljoin(config_path.as_uri(), entry["rootUri"])
    parsed = urlparse(root_uri)
    if parsed.scheme != "file":
        raise SystemExit(f"Unsupported better_player_plus root URI: {root_uri}")
    return Path(parsed.path).resolve()


def patch_source(source: str) -> str:
    if "MovieBox503RetryPolicy" in source:
        if "setLoadErrorHandlingPolicy(MovieBox503RetryPolicy())" not in source:
            raise SystemExit("Retry policy class exists but is not installed on the progressive source.")
        return source

    package_match = re.search(r"^package [^\n]+\n", source, re.MULTILINE)
    if package_match is None:
        raise SystemExit("BetterPlayer.kt has no Kotlin package declaration.")
    import_text = "".join(item + "\n" for item in IMPORTS if item not in source)
    source = source[:package_match.end()] + import_text + source[package_match.end():]

    class_match = re.search(r"^(?:internal\\s+)?class BetterPlayer\\s*\\(", source, re.MULTILINE)
    if class_match is None:
        raise SystemExit("Could not locate BetterPlayer class declaration.")
    source = source[:class_match.start()] + POLICY_CLASS + "\n" + source[class_match.start():]

    factory_pattern = re.compile(
        r"(C\\.CONTENT_TYPE_OTHER\\s*->\\s*ProgressiveMediaSource\\.Factory\\([\\s\\S]*?\\)\\.apply\\s*\\{)",
        re.MULTILINE,
    )
    source, count = factory_pattern.subn(
        r"\\1\n                setLoadErrorHandlingPolicy(MovieBox503RetryPolicy())",
        source,
        count=1,
    )
    if count != 1:
        raise SystemExit("Could not safely locate the progressive Media3 source factory; refusing an unpatched build.")
    return source


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-root", help="Resolved better_player_plus package root (for tests)")
    args = parser.parse_args()

    root = resolve_package_root(args.package_root)
    candidates = sorted((root / "android").rglob("BetterPlayer.kt"))
    if len(candidates) != 1:
        raise SystemExit(f"Expected exactly one Android BetterPlayer.kt under {root}; found {len(candidates)}.")
    source_path = candidates[0]
    original = source_path.read_text(encoding="utf-8")
    patched = patch_source(original)
    if patched != original:
        source_path.write_text(patched, encoding="utf-8")
    if "setLoadErrorHandlingPolicy(MovieBox503RetryPolicy())" not in patched:
        raise SystemExit("Bounded Media3 503 policy installation verification failed.")
    print(f"Installed bounded Media3 503 retry policy in {source_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
