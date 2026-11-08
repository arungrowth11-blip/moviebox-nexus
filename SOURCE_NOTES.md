# Source and changes

Base: user-submitted MovieBox Nexus OS v5.5 DeepSeek `main.dart` (2,591 lines). The submitted Argon Pro file was reviewed as a reference for addon-management behavior.

Changes in this package: removed blanket analyzer suppression; persisted and retained configured addons across network outages; added manifest URL install/remove UI; guarded local preference JSON parsing; closed HTTP clients and remote server on disposal; separated episode selection from watched status; replaced a nonfunctional assumed localhost TorrServer URL with explicit external magnet handoff; improved CI to run format, analyze, tests, and APK build.

Not verified in this environment: Dart formatting, Flutter analysis, widget tests, Android compilation, real device playback, external addon compatibility, IPTV uptime, or torrent client handoff.
