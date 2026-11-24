import 'package:flutter_test/flutter_test.dart';
import 'package:moviebox_nexus/src/player/media3_startup_policy.dart';

void main() {
  group('Media3StartupPolicy', () {
    test(
      'does not restart a torrent before its native piece wait can expire',
      () {
        expect(
          Media3StartupPolicy.torrentPlaybackStallTimeout,
          greaterThan(const Duration(seconds: 180)),
        );
        expect(
          Media3StartupPolicy.torrentPlaybackStallTimeout,
          lessThan(const Duration(seconds: 260)),
        );
      },
    );
    test(
      'keeps torrent startup pending while bounded first-piece retries run',
      () {
        expect(
          Media3StartupPolicy.evaluate(
            isPlaying: false,
            initialPosition: Duration.zero,
            currentPosition: Duration.zero,
            elapsed: const Duration(seconds: 120),
            isEmbeddedTorrent: true,
            httpBytesSent: 0,
          ),
          Media3StartupDecision.wait,
        );
      },
    );

    test('uses separate startup budgets for torrent and ordinary streams', () {
      expect(
        Media3StartupPolicy.timeoutFor(isEmbeddedTorrent: true),
        const Duration(seconds: 140),
      );
      expect(
        Media3StartupPolicy.timeoutFor(isEmbeddedTorrent: false),
        const Duration(seconds: 20),
      );
    });

    test('allows extended HTTP reads to finish before decoder fallback', () {
      expect(
        Media3StartupPolicy.timeoutFor(
          isEmbeddedTorrent: false,
          isExtendedReadTimeout: true,
        ),
        const Duration(seconds: 260),
      );
      expect(
        Media3StartupPolicy.evaluate(
          isPlaying: false,
          initialPosition: Duration.zero,
          currentPosition: Duration.zero,
          elapsed: const Duration(seconds: 25),
          isEmbeddedTorrent: false,
          isExtendedReadTimeout: true,
          httpBytesSent: 0,
        ),
        Media3StartupDecision.wait,
      );
    });

    test(
      'does not switch torrent transport failures to VLC before bytes arrive',
      () {
        expect(
          Media3StartupPolicy.canFallbackToCompatibilityPlayer(
            isEmbeddedTorrent: true,
            httpBytesSent: 0,
          ),
          isFalse,
        );
      },
    );

    test('allows VLC compatibility after torrent bytes reach the player', () {
      expect(
        Media3StartupPolicy.canFallbackToCompatibilityPlayer(
          isEmbeddedTorrent: true,
          httpBytesSent: 65536,
        ),
        isTrue,
      );
    });

    test('keeps non-torrent decoder fallback behavior', () {
      expect(
        Media3StartupPolicy.canFallbackToCompatibilityPlayer(
          isEmbeddedTorrent: false,
          httpBytesSent: 0,
        ),
        isTrue,
      );
    });
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

    test(
      'does not accept a frozen VOD clock just because isPlaying is true',
      () {
        expect(
          Media3StartupPolicy.evaluate(
            isPlaying: true,
            initialPosition: Duration.zero,
            currentPosition: Duration.zero,
            elapsed: const Duration(seconds: 3),
            isEmbeddedTorrent: false,
            httpBytesSent: 0,
          ),
          Media3StartupDecision.wait,
        );
        expect(
          Media3StartupPolicy.evaluate(
            isPlaying: true,
            initialPosition: Duration.zero,
            currentPosition: Duration.zero,
            elapsed: const Duration(seconds: 21),
            isEmbeddedTorrent: false,
            httpBytesSent: 0,
          ),
          Media3StartupDecision.useCompatibilityPlayer,
        );
      },
    );

    test('allows an active live controller without a finite media clock', () {
      expect(
        Media3StartupPolicy.evaluate(
          isPlaying: true,
          initialPosition: Duration.zero,
          currentPosition: Duration.zero,
          elapsed: const Duration(seconds: 5),
          isEmbeddedTorrent: false,
          isLive: true,
          httpBytesSent: 0,
        ),
        Media3StartupDecision.started,
      );
    });

    test(
      'reports no torrent first byte rather than switching player blindly',
      () {
        expect(
          Media3StartupPolicy.evaluate(
            isPlaying: false,
            initialPosition: Duration.zero,
            currentPosition: Duration.zero,
            elapsed: const Duration(seconds: 141),
            isEmbeddedTorrent: true,
            httpBytesSent: 0,
          ),
          Media3StartupDecision.noTorrentBytes,
        );
      },
    );

    test(
      'keeps torrent startup pending inside retry budget after bytes arrive',
      () {
        expect(
          Media3StartupPolicy.evaluate(
            isPlaying: false,
            initialPosition: Duration.zero,
            currentPosition: Duration.zero,
            elapsed: const Duration(seconds: 25),
            isEmbeddedTorrent: true,
            httpBytesSent: 65536,
          ),
          Media3StartupDecision.wait,
        );
      },
    );

    test(
      'uses compatibility player when torrent bytes exist but clock is frozen',
      () {
        expect(
          Media3StartupPolicy.evaluate(
            isPlaying: false,
            initialPosition: Duration.zero,
            currentPosition: Duration.zero,
            elapsed:
                Media3StartupPolicy.torrentStartupTimeout +
                const Duration(seconds: 1),
            isEmbeddedTorrent: true,
            httpBytesSent: 65536,
          ),
          Media3StartupDecision.useCompatibilityPlayer,
        );
      },
    );

    test('uses compatibility player for a stalled non-torrent source', () {
      expect(
        Media3StartupPolicy.evaluate(
          isPlaying: false,
          initialPosition: Duration.zero,
          currentPosition: Duration.zero,
          elapsed: const Duration(seconds: 141),
          isEmbeddedTorrent: false,
          httpBytesSent: 0,
        ),
        Media3StartupDecision.useCompatibilityPlayer,
      );
    });
  });
}
