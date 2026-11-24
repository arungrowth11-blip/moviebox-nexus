# MovieBox Nexus — Engineering Instructions

## Mission and safety
Build a reliable Flutter Android/Android TV media client. Priorities: user safety, lawful source handling, playback reliability, data integrity, reproducibility, then feature velocity.
- Work only on the requested branch. Never rewrite or force-push shared history.
- Do not merge, publish an APK, change signing credentials, or deploy without explicit approval.
- Never add secrets, signing keys, private URLs, or personal data to source control.
- Treat addon manifests, playlists, stream metadata, subtitles, and remote responses as untrusted input.
- Do not bypass DRM, provider authentication, paywalls, or access controls. A torrent hash is not a playable HTTP stream; only support lawful content and authorized resolvers.

## Architecture constraints
- Preserve the current Media3/ExoPlayer primary path and LibVLC compatibility fallback unless a measured defect justifies a change.
- Keep player lifecycle, resume persistence, torrent engine lifecycle, cache lifecycle, and addon resolution boundaries explicit.
- Handle cancellation, disposal, activity pause/resume, timeouts, retries, and stale async callbacks.
- Do not silently retry forever. Use bounded retries, backoff, cancellation, and visible diagnostic states.
- Avoid changing unrelated UI/catalog behavior during playback fixes.

## Required engineering loop
1. Reproduce the defect with a deterministic test or a documented device/network scenario.
2. Add a failing regression test before the implementation.
3. Make the smallest isolated change.
4. Run `flutter pub get`, `dart format --set-exit-if-changed lib test`, `flutter analyze`, and `flutter test`.
5. For release candidates, also run `flutter build apk --release`, verify APK signature, and perform emulator plus physical-device playback, seek, background/resume, and exit checks.
6. Review the complete diff and report exactly which checks ran and which did not.

## Evidence standard
- A green unit test or APK build is not proof of real-world playback on every codec, device, provider, or network.
- Never report a playback fix as verified without the corresponding integration/device evidence.
- Prefer structured diagnostics with redacted URLs/headers; never log credentials or full authorization headers.
