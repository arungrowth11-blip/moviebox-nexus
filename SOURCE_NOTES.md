# Engineering notes — canonical

This file records the current source-of-truth architecture and verification boundary. Historical troubleshooting logs and superseded design candidates are intentionally not kept here; use Git history and pull-request diffs when historical detail is needed.

## Main branch

- Flutter Android app for mobile and Android TV.
- Seven retained sections: Home, Theaters, Anime, Mood, Live TV, OTT Hubs and Addons.
- Stremio-compatible manifest/catalog/stream discovery.
- Media3/ExoPlayer with embedded LibVLC compatibility fallback.
- Resume playback, Live TV M3U parsing/search/refresh and persisted app preferences.
- On `main`, raw torrent/infoHash results are not yet handled by the newer embedded FrostWire engine. Do not describe that candidate feature as shipped until the corresponding PR stack is integrated and verified.

## Active implementation stack

| PR | Branch | Scope | Dependency |
|---|---|---|---|
| #8 | `feat/frostwire-jlibtorrent-bridge` | FrostWire jlibtorrent Android bridge, local HTTP byte-range server, bounded torrent piece prioritization, retained tabs and integration workflow | `main` |
| #9 | `feat/hybrid-addon-registry` | Manifest-aware Stremio resolver, capability validation, caching and parallel provider resolution | PR #8 |
| #10 | `fix/http-half-close-piece-wait` | Treat request-side HTTP EOF as half-close; retain bounded wait for requested torrent pieces | PR #9 |
| #11 | `fix/player-reliability-20261122` | Media3/VLC fallback, display lifecycle, torrent playback/cache lifecycle and regression coverage | PR #9 |
| #12 | `fix/torrent-cache-lifecycle-20261123` | Cache cleanup race-safety changes; merged into PR #11 | PR #11 |

PR #10 and PR #11 are separate branches based on PR #9. Before integration, reconcile PR #10's HTTP half-close/piece-wait changes with PR #11 so the final stack contains both sets of required fixes. Do not assume one contains the other.

## Release gates

A release candidate is not verified solely because an APK compiles or launches. Require:

1. Dart formatting, static analysis and Flutter tests.
2. Native Android/JVM tests.
3. Release APK build and signature verification.
4. Exact-candidate emulator integration tests, including HTTP 503 retry and seeded-torrent playback.
5. Physical Android phone and TV checks for first frame, long playback, seek, audio/subtitles, Live TV, back/exit, background/resume and temporary-cache cleanup.
6. Confirm the tested APK was built from the exact candidate commit being considered for release.

## Known verification issue at the time of this note

The PR #12 merged head's workflow run #350 built and signed a release APK, installed/launched it in the emulator, and passed the native JVM, Dart formatting, analysis and Flutter test steps. Its seeded-torrent/Media3 integration job failed: 3 of 4 integration tests passed; the HTTP 503 retry / 12-second first-byte wait test failed with expected `true`, actual `false`.

The PR #11 head's workflow run #353 reported `action_required`; this is not a passing result. Re-check current GitHub Actions before treating either result as current.

## Technical constraints

- Torrent availability depends on reachable peers/seeds and correct piece scheduling.
- HTTP byte-range support and socket lifecycle must remain correct during seek, cancellation and player exit.
- LibVLC fallback cannot necessarily forward arbitrary provider headers; preserve Media3 for sources requiring unsupported VLC headers.
- Live HLS streams may not expose a finite VOD-style playback clock.
- DRM-protected commercial streams require authorized provider sessions and licenses.

## Build commands

```sh
flutter pub get
dart format --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --release
```
