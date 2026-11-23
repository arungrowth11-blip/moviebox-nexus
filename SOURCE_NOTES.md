# Engineering notes — canonical

This file is the current source-of-truth architecture and verification boundary. Historical troubleshooting attempts and superseded designs remain in Git history and pull-request diffs; they are not separate active implementation paths.

## Main branch

- Flutter Android app for mobile and Android TV.
- Seven retained sections: Home, Theaters, Anime, Mood, Live TV, OTT Hubs and Addons.
- Stremio-compatible manifest/catalog/stream discovery.
- Media3/ExoPlayer with embedded LibVLC compatibility fallback.
- Resume playback, Live TV M3U parsing/search/refresh and persisted app preferences.
- On `main`, raw torrent/infoHash results are not yet handled by the newer embedded FrostWire engine. Do not describe that candidate feature as shipped until its integration stack is merged and verified.

## Single active implementation stack

| PR | Branch | Scope | Dependency |
|---|---|---|---|
| #8 | `feat/frostwire-jlibtorrent-bridge` | FrostWire jlibtorrent Android bridge, local HTTP byte-range server, bounded torrent piece prioritization, retained tabs and integration workflow | `main` |
| #9 | `feat/hybrid-addon-registry` | Manifest-aware Stremio resolver, capability validation, caching and parallel provider resolution | PR #8 |
| #11 | `fix/player-reliability-20261122` | Media3/VLC fallback, display lifecycle, torrent playback/cache lifecycle, HTTP half-close handling, addon header compatibility and regression coverage | PR #9 |

The former PR #10 half-close changes were incorporated directly into PR #11. PR #12's cache cleanup race-safety changes were merged into PR #11. PR #10 and #12 are closed; do not maintain separate parallel fixes. PR #5 and #6 are also closed as superseded by PR #8. Their remote branch refs remain in GitHub until an authorized branch-delete operation is available; closing a PR does not delete its source branch.

## Useful external implementation references

- `mesamirh/MovieBox-Tui`: useful reference for Stremio proxy-header parsing, range streaming, DASH relay and player error classification. It is a Rust terminal/Termux client that delegates to external players, not a drop-in Android player. Its nested and direct proxy-header parsing pattern is now covered in PR #11.
- `stremio-native/stream-server` and `stremio-native/stremio-android`: useful architectural references for a Rust/JNI local streaming server and native Android player abstraction. A full port would add a separate Gradle/NDK/Cargo toolchain and is not part of today's Flutter reliability patch.
- `moneytoo/Player` (Just Player): useful Media3 player reference for Android phones/TV and track/codec handling. It is a separate native Android app, not a direct Flutter dependency replacement.

## Release gates

A release candidate is not verified solely because an APK compiles or launches. Require:

1. Dart formatting, static analysis and Flutter tests.
2. Native Android/JVM tests.
3. Release APK build and signature verification.
4. Exact-candidate emulator integration tests, including HTTP 503 retry, delayed first-byte delivery, seeded-torrent playback and byte-range seek.
5. Physical Android phone and TV checks for first frame, sustained playback, seek, audio/subtitles, Live TV, back/exit, background/resume and temporary-cache cleanup.
6. Confirm the tested APK was built from the exact candidate commit being considered for release.

## Verification state

- Earlier workflow run #350 (older PR #12 merged head): native JVM tests, Dart formatting, analysis, Flutter tests, signed release APK packaging and exact APK emulator install/launch passed. The seeded-torrent/Media3 emulator job failed one of four integration tests: after two HTTP 503 responses and a 12-second first-byte delay, Media3 prepared the source but its playback clock did not advance.
- PR #11 subsequently added native-controller playback-start recovery, the HTTP half-close fix, and direct Stremio proxy-header compatibility tests.
- The current PR #11 head is `dbeb362dbb201edb3e4b7083e65b87d4a63f33a0`. Workflow run #360 was created for that exact head and was still pending at the time of this note. Pending is not a pass.
- No physical-device playback verification is recorded here.

## Technical constraints

- Torrent availability depends on reachable peers/seeds and correct piece scheduling.
- HTTP byte-range support and socket lifecycle must remain correct during seek, cancellation and player exit. EOF on the request-input direction is a valid HTTP half-close and must not cancel the response-body wait; actual socket read errors still cancel it.
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
