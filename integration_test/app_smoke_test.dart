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
