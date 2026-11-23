# MovieBox Nexus

Flutter application for Android phones and Android TV.

## Current main-branch scope

- Seven retained app sections: Home, Theaters, Anime, Mood, Live TV, OTT Hubs and Addons.
- Stremio-compatible addon manifest and stream discovery.
- Direct HTTP(S) playback in the in-app player.
- Media3/ExoPlayer primary playback with embedded LibVLC compatibility fallback.
- Resume-position persistence, playback controls, and Live TV playlist parsing/search/refresh.
- Torrent-only addon results are identified as requiring a compatible HTTP resolver on `main`; the newer embedded FrostWire engine remains in the active pull-request stack.

## Development checks

Run from the repository root with the Flutter SDK version required by `pubspec.yaml`:

```sh
flutter pub get
dart format --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --release
```

GitHub Actions also builds and verifies release APK artifacts. A successful build proves packaging and the checks actually run by that workflow; it does not prove playback reliability across every provider, codec, device or network.

## Playback and content limitations

- Stream availability, HTTP headers, codecs, bandwidth and device decoders affect playback.
- Commercial DRM content requires the provider's authorized license/session and device certification.
- Torrent playback requires reachable peers and lawful access to the content. A torrent hash is not itself a playable HTTP media URL.
- Public IPTV playlists can become unavailable, geo-blocked or change without notice. Prefer trusted HTTPS sources.

## Active integration path

The implementation is deliberately kept to one dependency chain:

1. PR #8 — FrostWire embedded torrent engine and retained tabs (based on `main`).
2. PR #9 — manifest-aware hybrid addon resolver (based on PR #8).
3. PR #11 — player lifecycle, torrent streaming and cache reliability (based on PR #9). It now includes the HTTP half-close correction previously proposed in PR #10, plus the cache-lifecycle changes merged from PR #12.

PR #10 is closed as superseded by the code and tests incorporated into PR #11. PR #12 is closed as merged into PR #11. PR #5 and PR #6 are closed as superseded by PR #8.

Do not merge or promote an APK until the exact candidate commit passes formatting, analysis, tests, APK signature verification, emulator integration, and physical-device playback/seek/exit checks.

## Repository

https://github.com/arungrowth11-blip/moviebox-nexus
