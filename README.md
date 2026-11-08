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
- Addons are Stremio-compatible manifest/stream endpoints. Temporarily offline addons are retained instead of silently deleted.
- Torrent hashes are handed to an installed external torrent-capable app. This project does not bundle TorrServer; do not assume a local TorrServer exists.
- IPTV sources may be HTTP; Android cleartext traffic is enabled for compatibility. Prefer trusted HTTPS playlists and addon URLs.
- Stream availability and codec support depend on third-party providers and the Android device.


## Functional revision (November 2026)

- Live TV uses multiple public India/Hindi M3U playlist mirrors, a tolerant parser, search, retry and refresh.
- OTT Hubs now opens provider-specific movie and series catalogs for the five IDs actually declared by the connected Streaming Catalogs manifest (Netflix, Prime Video, Disney+, HBO Max, Apple TV+). SonyLIV, ZEE5 and JioCinema remain visible but are clearly marked as requiring their own catalog addon; generic fallback titles are not mislabeled as provider originals.
- Popular Movies and Popular Series are labeled honestly rather than presenting a global fallback as an India-specific Top 10.
- Direct HTTP(S) streams can play in the built-in player or be sent explicitly to VLC. Raw torrent/magnet results are not sent to Stremio/VLC because they require a debrid/TorrServer resolver to produce a playable HTTP stream.
- Addon stream requests are parallelized with per-addon timeouts and deduplication. Comet is offered as an optional configure-first source; its generated manifest can be added by the user.
