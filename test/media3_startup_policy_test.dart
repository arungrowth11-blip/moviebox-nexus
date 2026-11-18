import 'package:flutter_test/flutter_test.dart';
import 'package:moviebox_nexus/src/player/media3_startup_policy.dart';

void main() {
  group('Media3StartupPolicy', () {
    test('waits while an initialized player remains inside startup budget', () {
      expect(
        Media3StartupPolicy.evaluate(
          isPlaying: false,
          initialPosition: Duration.zero,
          currentPosition: Duration.zero,
          elapsed: const Duration(seconds: 8),
          isEmbeddedTorrent: true,
          httpBytesSent: 0,
        ),
        Media3StartupDecision.wait,
      );
    });

    test('recognizes an actively playing controller', () {
      expect(
        Media3StartupPolicy.evaluate(
          isPlaying: true,
          initialPosition: Duration.zero,
          currentPosition: const Duration(seconds: 1),
          elapsed: const Duration(seconds: 30),
          isEmbeddedTorrent: true,
          httpBytesSent: 0,
        ),
        Media3StartupDecision.started,
      );
    });

    test('recognizes native playback clock progress', () {
      expect(
        Media3StartupPolicy.evaluate(
          isPlaying: false,
          initialPosition: const Duration(seconds: 4),
          currentPosition: const Duration(seconds: 5),
          elapsed: const Duration(seconds: 30),
          isEmbeddedTorrent: false,
          httpBytesSent: 0,
        ),
        Media3StartupDecision.started,
      );
    });

    test('reports no torrent first byte rather than switching player blindly', () {
      expect(
        Media3StartupPolicy.evaluate(
          isPlaying: false,
          initialPosition: Duration.zero,
          currentPosition: Duration.zero,
          elapsed: const Duration(seconds: 25),
          isEmbeddedTorrent: true,
          httpBytesSent: 0,
        ),
        Media3StartupDecision.noTorrentBytes,
      );
    });

    test('uses compatibility player when torrent bytes exist but clock is frozen', () {
      expect(
        Media3StartupPolicy.evaluate(
          isPlaying: false,
          initialPosition: Duration.zero,
          currentPosition: Duration.zero,
          elapsed: const Duration(seconds: 25),
          isEmbeddedTorrent: true,
          httpBytesSent: 65536,
        ),
        Media3StartupDecision.useCompatibilityPlayer,
      );
    });

    test('uses compatibility player for a stalled non-torrent source', () {
      expect(
        Media3StartupPolicy.evaluate(
          isPlaying: false,
          initialPosition: Duration.zero,
          currentPosition: Duration.zero,
          elapsed: const Duration(seconds: 25),
          isEmbeddedTorrent: false,
          httpBytesSent: 0,
        ),
        Media3StartupDecision.useCompatibilityPlayer,
      );
    });
  });
}
