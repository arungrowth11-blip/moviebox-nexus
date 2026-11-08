# MovieBox Nexus OS

Flutter Android TV + mobile starter assembled from the submitted DeepSeek source, with selected reliability fixes and a reproducible GitHub Actions workflow.

## Build
1. Install Flutter stable and Android SDK.
2. Run `flutter pub get`.
3. Run `dart format lib test`.
4. Run `flutter analyze`.
5. Run `flutter test`.
6. Run `flutter build apk --release`.

GitHub Actions runs formatting, analysis, tests, and release APK packaging. A successful workflow is the acceptance gate; source inspection alone is not a build guarantee.

## Important runtime notes
- The seven tabs are retained: Home, Theaters, Anime, Mood, Live TV, OTT Hubs, Addons.
- The QR remote serves an actual local web control page and uses a per-session token for its play endpoint.
- Addons are Stremio-compatible manifest/stream endpoints. Temporarily offline addons are retained instead of silently deleted.
- Torrent hashes are handed to an installed external torrent-capable app. This project does not bundle TorrServer; do not assume a local TorrServer exists.
- IPTV sources may be HTTP; Android cleartext traffic is enabled for compatibility. Prefer trusted HTTPS playlists and addon URLs.
- Stream availability and codec support depend on third-party providers and the Android device.
