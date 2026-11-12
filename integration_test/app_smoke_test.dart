import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/services.dart';
import 'package:moviebox_nexus/player_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:moviebox_nexus/main.dart' as moviebox;


const String _sampleMp4Base64 = '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';


Future<void> _waitUntil(
  bool Function() condition,
  String reason, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < timeout) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  expect(condition(), isTrue, reason: reason);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native torrent bridge registers and all primary tabs remain navigable',
    (tester) async {
      await moviebox.main();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      const torrentChannel = MethodChannel('moviebox_nexus/torrent');
      final initialized = await torrentChannel
          .invokeMethod<bool>('initialize')
          .timeout(const Duration(seconds: 45));
      expect(initialized, isTrue);

      // Exercise the exact method that previously raised MissingPluginException.
      // An invalid hash must be rejected by the native handler before any torrent
      // is downloaded, so this remains a free, deterministic offline smoke test.
      await expectLater(
        torrentChannel.invokeMethod<String>(
          'startPlayback',
          <String, Object>{
            'infoHash': 'not-a-valid-info-hash',
            'title': 'Native bridge smoke test',
          },
        ),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'INVALID_INFO_HASH',
          ),
        ),
      );

      final stopped = await torrentChannel
          .invokeMethod<bool>('stopPlayback')
          .timeout(const Duration(seconds: 10));
      expect(stopped, isTrue);

      // Starting a magnet must return the local player URL immediately; peer
      // discovery and metadata resolution happen off the Flutter/UI thread.
      final startupClock = Stopwatch()..start();
      final pendingUrl = await torrentChannel
          .invokeMethod<String>('startPlayback', <String, Object>{
            'infoHash': '0123456789012345678901234567890123456789',
            'title': 'Emulator startup smoke test',
          })
          .timeout(const Duration(seconds: 8));
      startupClock.stop();
      final pendingUri = Uri.parse(pendingUrl!);
      expect(pendingUri.host, '127.0.0.1');
      expect(pendingUri.path, startsWith('/stream/'));
      expect(startupClock.elapsed, lessThan(const Duration(seconds: 5)));

      final cancelled = await torrentChannel
          .invokeMethod<bool>('stopPlayback')
          .timeout(const Duration(seconds: 10));
      expect(cancelled, isTrue);

      const tabs = <String>[
        'Home',
        'Theaters',
        'Anime',
        'Mood',
        'Live TV',
        'OTT Hubs',
        'Addons',
      ];

      for (final label in tabs) {
        final tab = find.text(label).first;
        expect(tab, findsWidgets, reason: 'The $label tab must be present.');
        await tester.ensureVisible(tab);
        await tester.tap(tab, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text(label), findsWidgets,
            reason: 'The $label tab must remain visible after selection.');

        if (label == 'Live TV') {
          expect(find.text('COUNTRY'), findsOneWidget);
          expect(find.text('CATEGORY'), findsOneWidget);
        }
      }

      // Switching away and back must retain the Live TV screen instance.
      final liveTab = find.text('Live TV').first;
      await tester.ensureVisible(liveTab);
      await tester.tap(liveTab, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('COUNTRY'), findsOneWidget);
      expect(find.text('CATEGORY'), findsOneWidget);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'Media3 prepares a direct MP4 from the local range server',
    (tester) async {
      final videoBytes = base64Decode(_sampleMp4Base64);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        final response = request.response;
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        response.headers.contentType = ContentType('video', 'mp4');

        var start = 0;
        var end = videoBytes.length - 1;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) {
          final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
          if (match != null) {
            start = int.parse(match.group(1)!);
            end = match.group(2)!.isEmpty
                ? videoBytes.length - 1
                : int.parse(match.group(2)!);
            if (start < 0 || start >= videoBytes.length || end < start) {
              response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
              unawaited(response.close());
              return;
            }
            end = end.clamp(0, videoBytes.length - 1).toInt();
            response.statusCode = HttpStatus.partialContent;
            response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${videoBytes.length}',
            );
          }
        }

        final length = end - start + 1;
        response.contentLength = length;
        if (request.method != 'HEAD') {
          response.add(videoBytes.sublist(start, end + 1));
        }
        unawaited(response.close());
      });

      final prepared = Completer<Duration>();
      try {
        await tester.pumpWidget(MaterialApp(
          home: PlayerScreen(
            title: 'Local Media3 QA sample',
            url: 'http://127.0.0.1:${server.port}/smoke.mp4',
            onSave: (_) async {},
            onPrepared: (elapsed) {
              if (!prepared.isCompleted) prepared.complete(elapsed);
            },
          ),
        ));
        final elapsed = await prepared.future.timeout(const Duration(seconds: 30));
        expect(elapsed, lessThan(const Duration(seconds: 30)));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );



  testWidgets(
    'real seeded magnet resolves metadata, streams pieces, serves seek ranges and prepares in Media3',
    (tester) async {
      const infoHash = String.fromEnvironment('MOVIEBOX_TEST_INFO_HASH');
      const peerEndpoint = String.fromEnvironment(
        'MOVIEBOX_TEST_PEER',
        defaultValue: '10.0.2.2:6881',
      );
      const expectedFirstHex = String.fromEnvironment('MOVIEBOX_TEST_FIRST_HEX');
      const expectedSeekHex = String.fromEnvironment('MOVIEBOX_TEST_SEEK_HEX');

      expect(infoHash, matches(RegExp(r'^[a-f0-9]{40}$')));
      expect(peerEndpoint, '10.0.2.2:6881');
      expect(expectedFirstHex, hasLength(32));
      expect(expectedSeekHex, hasLength(32));

      const channel = MethodChannel('moviebox_nexus/torrent');
      await channel.invokeMethod<bool>('initialize').timeout(
        const Duration(seconds: 30),
      );

      final playerUrl = await channel
          .invokeMethod<String>(
            'startPlaybackWithPeerForTest',
            <String, Object>{
              'infoHash': infoHash,
              'title': 'MovieBox Nexus local seeded playback QA',
              'peerEndpoint': peerEndpoint,
            },
          )
          .timeout(const Duration(seconds: 10));

      final uri = Uri.parse(playerUrl!);
      expect(uri.host, '127.0.0.1');
      expect(uri.path, startsWith('/stream/'));

      final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      String hex(List<int> bytes) =>
          bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

      Future<List<int>> fetchRange(int start, int end) async {
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
        final response = await request.close().timeout(
          const Duration(seconds: 75),
          onTimeout: () => throw TimeoutException(
            'Torrent metadata did not resolve in 75 seconds.',
          ),
        );
        expect(response.statusCode, HttpStatus.partialContent);
        expect(
          response.headers.value(HttpHeaders.contentRangeHeader),
          startsWith('bytes $start-$end/'),
        );
        final bytes = await response.fold<List<int>>(
          <int>[],
          (result, chunk) => result..addAll(chunk),
        ).timeout(
          const Duration(seconds: 100),
          onTimeout: () => throw TimeoutException(
            'Torrent piece $start-$end did not arrive in 100 seconds.',
          ),
        );
        expect(bytes, hasLength(end - start + 1));
        return bytes;
      }

      try {
        // This first 206 response is only available after magnet metadata has
        // arrived and a supported video file has been selected.
        final firstRange = await fetchRange(0, 65535);
        expect(hex(firstRange.take(16).toList()), expectedFirstHex);

        // A distant range forces a different torrent piece to be prioritized.
        // This verifies the same byte-range path used when a viewer seeks.
        const seekOffset = 4 * 1024 * 1024;
        final seekRange = await fetchRange(seekOffset, seekOffset + 65535);
        expect(hex(seekRange.take(16).toList()), expectedSeekHex);

        // Finally exercise the actual in-app Media3 player against the URL
        // returned by the magnet bridge—not a separate HTTP test server.
        final prepared = Completer<Duration>();
        final media3Ready = Completer<BetterPlayerController>();
        await tester.pumpWidget(MaterialApp(
          home: PlayerScreen(
            title: 'Seeded torrent end-to-end QA',
            url: uri.toString(),
            onSave: (_) async {},
            onPrepared: (elapsed) {
              if (!prepared.isCompleted) prepared.complete(elapsed);
            },
            onMedia3ControllerReady: (controller) {
              if (!media3Ready.isCompleted) media3Ready.complete(controller);
            },
          ),
        ));
        final elapsed = await prepared.future.timeout(
          const Duration(seconds: 105),
          onTimeout: () => throw TimeoutException(
            'Media3 did not prepare the seeded torrent video within 105 seconds.',
          ),
        );
        expect(elapsed, lessThan(const Duration(seconds: 105)));

        // "initialized" alone is not proof of playback. Confirm a decoded
        // video size, active playback state, and a moving media clock.
        final controller = await media3Ready.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw TimeoutException(
            'Media3 initialized but did not expose its playback controller.',
          ),
        );
        final initialValue = controller.videoPlayerController?.value;
        expect(initialValue, isNotNull);
        expect(initialValue!.size?.width ?? 0, greaterThan(0));
        expect(initialValue.size?.height ?? 0, greaterThan(0));
        expect(initialValue.duration, greaterThan(const Duration(seconds: 30)));

        await _waitUntil(
          () => controller.videoPlayerController?.value.isPlaying == true,
          'Media3 must enter the playing state after initialization.',
          timeout: const Duration(seconds: 20),
        );
        final beforePlayback = controller.videoPlayerController!.value.position;
        await _waitUntil(
          () {
            final position = controller.videoPlayerController?.value.position;
            return position != null &&
                position > beforePlayback + const Duration(milliseconds: 800);
          },
          'Media3 playback clock must advance; a frozen/paused player is not accepted.',
          timeout: const Duration(seconds: 15),
        );

        // Exercise the same Media3 seek operation used by the playback UI.
        // The torrent engine must satisfy data requests at the new position.
        const seekTarget = Duration(seconds: 20);
        await controller.seekTo(seekTarget).timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException(
            'Media3 seek command did not complete within 20 seconds.',
          ),
        );
        await _waitUntil(
          () {
            final position = controller.videoPlayerController?.value.position;
            return position != null &&
                position >= seekTarget - const Duration(seconds: 1) &&
                position <= seekTarget + const Duration(seconds: 4);
          },
          'Media3 must land near the requested 20-second seek target.',
          timeout: const Duration(seconds: 25),
        );
        await _waitUntil(
          () {
            final position = controller.videoPlayerController?.value.position;
            return position != null &&
                position > seekTarget + const Duration(milliseconds: 700);
          },
          'Playback must continue after seeking rather than freezing at the seek target.',
          timeout: const Duration(seconds: 12),
        );
        expect(
          controller.videoPlayerController?.value.isPlaying,
          isTrue,
          reason: 'Media3 must remain in the playing state after seeking.',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        client.close(force: true);
        await channel.invokeMethod<bool>('stopPlayback').timeout(
          const Duration(seconds: 15),
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );

}
