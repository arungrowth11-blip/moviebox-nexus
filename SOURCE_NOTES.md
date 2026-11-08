# Source and changes

Base: user-submitted MovieBox Nexus OS v5.5 DeepSeek `main.dart` (2,591 lines). The submitted Argon Pro file was reviewed as a reference for addon-management behavior.

Changes in this package: removed blanket analyzer suppression; persisted and retained configured addons across network outages; added manifest URL install/remove UI; guarded local preference JSON parsing; closed HTTP clients and remote server on disposal; separated episode selection from watched status; replaced a nonfunctional assumed localhost TorrServer URL with explicit external magnet handoff; improved CI to run format, analyze, tests, and APK build.

Not verified in this environment: Dart formatting, Flutter analysis, widget tests, Android compilation, real device playback, external addon compatibility, IPTV uptime, or torrent client handoff.


Latest CI source correction: CustomScrollView now uses `const ScrollCacheExtent.pixels(800.0)` with the Flutter rendering API instead of passing an integer to `scrollCacheExtent`. CI keeps `--no-fatal-infos`, so informational lint suggestions do not hide or suppress actual errors.


## CI Gradle bootstrap update
- CI installs Gradle 9.3.1 using the official Gradle distribution host first, with alternate mirror fallbacks.
- The Gradle ZIP is verified against the official 9.3.1 binary distribution SHA-256 before extraction.
- During CI only, android/gradlew is routed to that verified local Gradle executable.

## Kotlin artifact repository resilience
- The CI workflow prepends the Google Cloud Storage Asia-Pacific Maven Central mirror and the primary Google Cloud Storage Maven Central mirror before Maven Central in generated Android Gradle Kotlin DSL repository declarations.
- Both plugin-management and project dependency repositories are patched where `mavenCentral()` is declared. Maven Central remains configured as a fallback.
- The purpose is to avoid a failing Maven Central-to-GitHub artifact redirect for Kotlin compiler dependencies. The change does not alter the app's Dart source.

- Retry detection also recognizes Gradle's `Received status code 504` and `Gateway Time-out` wording.

## Global Gradle init-script repository routing
- CI creates a Gradle init script and passes it to every Gradle invocation with `--init-script`.
- The script inserts Maven Central mirrors into plugin-management and dependency-resolution repositories before settings files are evaluated, covering included build logic as well.
- Buildscript repositories are also given the same mirror fallback list.
- CI forces a dependency metadata refresh so a previously cached Maven Central route does not keep selecting the failing GitHub redirect.

## Gradle repository scope correction
- Keep `gradlePluginPortal()` available after the Maven mirrors for plugin marker artifacts such as `org.gradle.kotlin.kotlin-dsl`.
- Add mirrors to each Gradle project's normal `repositories` handler as well as `buildscript.repositories`; this covers Flutter's included Gradle build project dependencies.
- Keep Google Maven repositories available for Android Gradle plugins/artifacts.
- Remove forced `--refresh-dependencies` to avoid unnecessary redownloads; new mirror repositories are inserted ahead of Maven Central.

## Plugin Portal and scoped Flutter build repositories
- Plugin marker resolution retains `gradlePluginPortal()` after Maven mirrors, so Flutter's `org.gradle.kotlin.kotlin-dsl` plugin can resolve.
- Project-level mirror injection is scoped to Flutter's included `flutter/packages/flutter_tools/gradle` build, avoiding conflicts with the main Android project's `FAIL_ON_PROJECT_REPOS` repository policy.
- Buildscript repositories retain mirrors and Google's Maven repository.

## Repository mode conflict correction
- The Gradle init script no longer adds repositories in `beforeProject`.
- Maven mirrors and Google repositories are configured only through `pluginManagement.repositories` and `dependencyResolutionManagement.repositories` inside `beforeSettings`, for the main Android build and included builds.
- The Plugin Portal remains enabled for Gradle plugin marker artifacts.
- This avoids violating Gradle's `PREFER_SETTINGS` repository mode in Android/Flutter builds.


## Installed-app functional fixes

- Replaced the single-source, strict-line-start IPTV parser with multi-source M3U loading and a tolerant parser; added an automated parser test.
- Made OTT Hub cards interactive. Only the five catalog IDs declared by the connected Streaming Catalogs manifest are queried; unsupported providers do not receive generic genre fallback results.
- Corrected misleading India Top 10 label to Popular Movies and added Popular Series.
- Stream resolution now queries compatible addons concurrently, times out each request, and removes duplicate results.
- Direct HTTP(S) URLs have an explicit VLC intent path (`org.videolan.vlc`) and retain in-app playback. Android package visibility is declared in the manifest patch.
- Raw infoHash/magnet streams no longer launch Stremio automatically. They are reported as requiring a debrid or TorrServer resolver; VLC cannot turn a magnet hash into a playable HTTP stream by itself.
- Player initialization has a bounded timeout and VLC fallback.
- Added an optional Comet configure link. It is not auto-installed because its public instance may require a debrid configuration/account.

## Verification boundary

This source revision was statically inspected and its YAML/ZIP structure is validated. Flutter/Dart SDK is not installed in the authoring environment, so `flutter analyze`, `flutter test`, and `flutter build apk --release` must still run in GitHub Actions. Public IPTV streams can be geo-blocked, offline, or changed by their operators; the UI now supports retry and alternate playlist sources but cannot guarantee every channel remains live.


## In-app dual-engine player candidate (2026-11-08)
- Primary: Better Player Plus 1.4.1 (Media3/ExoPlayer) for Android adaptive playback,
  HLS/DASH track/quality selection, audio/subtitle selection, playback speed and
  HTTP request headers. Version 1.4.1 is compatible with Flutter 3.41+ and AGP
  before/after the Kotlin DSL transition.
- Fallback: flutter_vlc_player 7.4.4 embeds LibVLC inside MovieBox; it does not
  launch the external VLC app. It supports Android 5.0/API 21+ and adds wider
  container/codec compatibility, audio/subtitle track menus and speed controls.
- VLC fallback maps User-Agent and Referer to VLC HTTP options. The legacy
  flutter_vlc_player API does not expose arbitrary HTTP headers; sources needing
  custom Authorization/Cookie headers should remain on Media3 or need a newer
  header-capable VLC plugin with Android minSdk 29.
- This player does not claim universal playback: codec availability depends on
  the device/native decoders, source validity, HTTP access and server behaviour.
  Commercial OTT Widevine/PlayReady DRM requires the provider's authorized
  license/session and device certification; generic third-party stream links
  cannot bypass it. Torrent/magnet links need a TorrServer/debrid HTTP resolver.
- Source-level checks only were performed in this environment. Flutter/Dart SDK
  is not installed here; `flutter pub get`, `flutter analyze`, release APK build,
  and playback testing on an Android TV and Android phone remain mandatory.


## In-app dual-engine player candidate (2026-11-08)
- Primary engine: Better Player Plus 1.4.1 / Android Media3 (ExoPlayer). It supports
  HTTP headers, HLS/DASH, adaptive quality, embedded audio/subtitle tracks,
  playback speed, seek controls, and buffering configuration.
- Fallback engine: flutter_vlc_player 7.4.4 embeds LibVLC inside MovieBox. It does
  not launch the external VLC app. It supports Android 5.0/API 21+ and adds
  broader container/codec compatibility plus audio/subtitle track controls.
- Stremio `behaviorHints.proxyHeaders.request` is carried from stream resolution
  into the Media3 source. VLC fallback maps User-Agent and Referer to VLC HTTP
  options. If Media3 fails and the source needs other custom headers, the app
  reports that limitation instead of silently dropping the headers.
- No generic player can guarantee every codec: playback still depends on the
  Android device's hardware/software decoders, stream format, server response,
  bandwidth, and valid source URL. Widevine/PlayReady protected commercial OTT
  playback requires the provider's authorized license/session and device
  certification. Magnet/infoHash sources require a TorrServer/debrid HTTP
  resolver before any media player can play them.
- The external VLC-app action was removed from stream cards; direct streams are
  routed to the in-app player only.
- Source-level and package API checks were performed. This environment has no
  Flutter/Dart SDK, so `flutter pub get`, `flutter analyze`, APK compilation,
  and real-device playback remain unverified and are mandatory release gates.

- The candidate's Dart/Flutter SDK constraints now reflect Better Player Plus 1.4.1
  (Dart >=3.11 / Flutter >=3.41); CI uses Flutter stable 3.47.9.
- The Android CI scaffold adds the documented `lib/**/libc++_shared.so` pick-first
  packaging rule for the LibVLC native runtime, while retaining Android API 21
  compatibility from flutter_vlc_player 7.4.3+.
