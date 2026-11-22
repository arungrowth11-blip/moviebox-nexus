import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moviebox_nexus/player_screen.dart';

void main() {
  group('mediaFormatHintForUrl', () {
    test('uses explicit hints for HLS and DASH paths', () {
      expect(
        mediaFormatHintForUrl('https://cdn.example/live/master.m3u8?token=abc'),
        BetterPlayerVideoFormat.hls,
      );
      expect(
        mediaFormatHintForUrl('https://cdn.example/movie/manifest.mpd'),
        BetterPlayerVideoFormat.dash,
      );
    });

    test('uses a generic format for extensionless provider URLs', () {
      expect(
        mediaFormatHintForUrl('https://play.example-provider.com/watch?id=123'),
        BetterPlayerVideoFormat.other,
      );
      expect(
        mediaFormatHintForUrl('http://127.0.0.1:8765/stream/opaque-token'),
        BetterPlayerVideoFormat.other,
      );
    });

    test(
      'leaves known file extensions to BetterPlayer native format detection',
      () {
        expect(
          mediaFormatHintForUrl('https://cdn.example/video.mp4?signature=abc'),
          isNull,
        );
      },
    );
  });
}
