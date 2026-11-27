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

Future<void> _waitUntil(
  WidgetTester tester,
  Future<bool> Function() condition,
  String reason, {
  Duration timeout = const Duration(seconds: 15),
  Future<String> Function()? diagnostic,
}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < timeout) {
    if (await condition()) return;
    // Query VideoPlayerController.position directly so the assertion reads
    // ExoPlayer's native clock, not the periodically refreshed Dart cache.
    await tester.pump(const Duration(milliseconds: 200));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final details = diagnostic == null ? '' : await diagnostic();
  if (details.isNotEmpty) {
    // This state-only line is safe for the bounded public CI excerpt.
    debugPrint('Media3 CI playback state at wait timeout: $details');
  }
  expect(
    await condition(),
    isTrue,
    reason: details.isEmpty ? reason : '$reason $details',
  );
}

Future<String> _media3Diagnostic(BetterPlayerController controller) async {
  final player = controller.videoPlayerController;
  final value = player?.value;
  final nativePosition = await player?.position;
  return 'Media3 nativePosition=$nativePosition, cachedPosition=${value?.position}, '
      'isPlaying=${value?.isPlaying}, isBuffering=${value?.isBuffering}, '
      'error=${value?.errorDescription}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const displayChannel = MethodChannel('moviebox_nexus/display');

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
        torrentChannel.invokeMethod<String>('startPlayback', <String, Object>{
          'infoHash': 'not-a-valid-info-hash',
          'title': 'Native bridge smoke test',
        }),
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
        expect(
          find.text(label),
          findsWidgets,
          reason: 'The $label tab must remain visible after selection.',
        );

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

  testWidgets('Media3 prepares a real MP4 over the runner HTTP byte-range server', (
    tester,
  ) async {
    const mediaUrl = String.fromEnvironment('MOVIEBOX_TEST_MP4_URL');
    final uri = Uri.tryParse(mediaUrl);
    expect(uri, isNotNull);
    expect(uri!.host, '10.0.2.2');
    expect(uri.path, '/moviebox-ci-video.mp4');

    // Integration-test widget teardown can leave the host lifecycle paused.
    // Restore foreground state before asking Media3 to start playback.
    if (tester.binding.lifecycleState != AppLifecycleState.resumed) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    }

    final prepared = Completer<Duration>();
    final media3Ready = Completer<BetterPlayerController>();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerScreen(
            title: 'MovieBox Nexus real MP4 QA sample',
            url: mediaUrl,
            headers: const <String, String>{'Range': 'bytes=0-'},
            onSave: (_) async {},
            onPrepared: (elapsed) {
              if (!prepared.isCompleted) prepared.complete(elapsed);
            },
            onMedia3ControllerReady: (controller) {
              if (!media3Ready.isCompleted) media3Ready.complete(controller);
            },
          ),
        ),
      );

      await _waitUntil(
        tester,
        () async =>
            await displayChannel.invokeMethod<bool>('isKeepScreenOn') == true,
        'Opening PlayerScreen must set Android FLAG_KEEP_SCREEN_ON.',
        timeout: const Duration(seconds: 5),
      );

      final elapsed = await prepared.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException(
          'Media3 did not prepare the generated MP4 within 30 seconds.',
        ),
      );
      expect(elapsed, lessThan(const Duration(seconds: 30)));

      final controller = await media3Ready.future.timeout(
        const Duration(seconds: 10),
      );
      final initialValue = controller.videoPlayerController?.value;
      expect(initialValue, isNotNull);
      expect(initialValue!.size?.width ?? 0, greaterThan(0));
      expect(initialValue.size?.height ?? 0, greaterThan(0));
      expect(initialValue.duration, greaterThan(const Duration(seconds: 20)));
      debugPrint(
        'MovieBox CI direct Media3 before play: isPlaying=${initialValue.isPlaying}, '
        'isBuffering=${initialValue.isBuffering}, position=${initialValue.position}, '
        'duration=${initialValue.duration}',
      );
      await controller.play().timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException(
          'Media3 play command timed out on the direct MP4.',
        ),
      );

      final beforePlayback =
          await controller.videoPlayerController!.position ?? Duration.zero;
      await _waitUntil(
        tester,
        () async {
          final position = await controller.videoPlayerController?.position;
          return position != null &&
              position > beforePlayback + const Duration(milliseconds: 700);
        },
        'Media3 native playback clock must advance on the direct HTTP source.',
        timeout: const Duration(seconds: 20),
        diagnostic: () => _media3Diagnostic(controller),
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _waitUntil(
        tester,
        () async =>
            await displayChannel.invokeMethod<bool>('isKeepScreenOn') == false,
        'Leaving PlayerScreen must clear Android FLAG_KEEP_SCREEN_ON.',
        timeout: const Duration(seconds: 5),
      );
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets(
    'Media3 retries two bounded HTTP 503 responses and prepares after a 12-second first-byte wait',
    (tester) async {
      const mediaUrl = String.fromEnvironment('MOVIEBOX_TEST_MP4_URL');
      final parsedSourceUri = Uri.tryParse(mediaUrl);
      expect(parsedSourceUri, isNotNull);
      final sourceUri = parsedSourceUri!;
      expect(sourceUri.host, '10.0.2.2');

      // A preceding integration test can leave the host lifecycle paused.
      // BetterPlayer may report initialized/isPlaying while ExoPlayer's clock
      // remains frozen until the test host is explicitly resumed.
      debugPrint(
        'MovieBox CI lifecycle before 503 retry player: ${tester.binding.lifecycleState}',
      );
      if (tester.binding.lifecycleState != AppLifecycleState.resumed) {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
      }

      final upstreamClient = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      final retryStatuses = <int>[];
      var getRequests = 0;
      var torrentMarkerForwarded = false;
      String? successful206ContentRange;
      var successful206BodyBytes = 0;
      final first206BodyBytes = <int>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((incoming) async {
        try {
          if (incoming.headers.value('X-MovieBox-Torrent-Stream') != null) {
            torrentMarkerForwarded = true;
          }
          if (incoming.method == 'GET') {
            getRequests++;
            if (getRequests <= 2) {
              retryStatuses.add(HttpStatus.serviceUnavailable);
              incoming.response.statusCode = HttpStatus.serviceUnavailable;
              incoming.response.headers.set('Retry-After', '1');
              incoming.response.headers.contentLength = 0;
              await incoming.response.close();
              return;
            }
          }

          // Media3's stock HTTP read timeout is 8 seconds. The MovieBox
          // torrent bridge can need longer to verify a complete first piece.
          // This 12-second delayed first-byte response proves the patched
          // 60-second read timeout is actually installed in the Android plugin.
          if (incoming.method == 'GET' && getRequests == 3) {
            await Future<void>.delayed(const Duration(seconds: 12));
          }

          final upstreamRequest = await upstreamClient.openUrl(
            incoming.method,
            sourceUri,
          );
          final range = incoming.headers.value(HttpHeaders.rangeHeader);
          if (range != null) {
            upstreamRequest.headers.set(HttpHeaders.rangeHeader, range);
          }
          final upstreamResponse = await upstreamRequest.close();
          if (incoming.method == 'GET') {
            retryStatuses.add(upstreamResponse.statusCode);
          }
          incoming.response.statusCode = upstreamResponse.statusCode;
          for (final header in <String>[
            'content-type',
            'content-length',
            'content-range',
            'accept-ranges',
            'last-modified',
            'etag',
          ]) {
            final values = upstreamResponse.headers[header];
            if (values != null && values.isNotEmpty) {
              incoming.response.headers.set(header, values);
            }
          }
          if (upstreamResponse.statusCode == HttpStatus.partialContent) {
            successful206ContentRange = upstreamResponse.headers.value(
              HttpHeaders.contentRangeHeader,
            );
          }
          await for (final chunk in upstreamResponse) {
            if (upstreamResponse.statusCode == HttpStatus.partialContent) {
              successful206BodyBytes += chunk.length;
              final remaining = 16 - first206BodyBytes.length;
              if (remaining > 0) {
                first206BodyBytes.addAll(chunk.take(remaining));
              }
            }
            incoming.response.add(chunk);
          }
          await incoming.response.close();
        } catch (error, stack) {
          debugPrint('MovieBox 503 retry proxy error: $error\\n$stack');
          try {
            incoming.response.statusCode = HttpStatus.badGateway;
          } catch (_) {
            // Headers may already have been committed by the upstream pipe.
          }
          try {
            await incoming.response.close();
          } catch (_) {
            // The peer may have disconnected while the upstream body was copied.
          }
        }
      });

      final retryUrl = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.port,
        path: '/retry.mp4',
      ).toString();
      final prepared = Completer<Duration>();
      final media3Ready = Completer<BetterPlayerController>();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              title: 'MovieBox Media3 bounded 503 retry QA',
              url: retryUrl,
              headers: const <String, String>{
                'Range': 'bytes=0-',
                'X-MovieBox-Torrent-Stream': 'true',
              },
              onSave: (_) async {},
              onPrepared: (elapsed) {
                if (!prepared.isCompleted) prepared.complete(elapsed);
              },
              onMedia3ControllerReady: (controller) {
                if (!media3Ready.isCompleted) media3Ready.complete(controller);
              },
            ),
          ),
        );

        await prepared.future.timeout(
          const Duration(seconds: 60),
          onTimeout: () => throw TimeoutException(
            'Media3 did not recover from two HTTP 503 responses within 60 seconds.',
          ),
        );
        final controller = await media3Ready.future.timeout(
          const Duration(seconds: 10),
        );
        final value = controller.videoPlayerController?.value;
        expect(value, isNotNull);
        expect(value!.size?.width ?? 0, greaterThan(0));
        expect(value.size?.height ?? 0, greaterThan(0));
        expect(retryStatuses.take(3).toList(), <int>[
          HttpStatus.serviceUnavailable,
          HttpStatus.serviceUnavailable,
          HttpStatus.partialContent,
        ]);
        expect(successful206ContentRange, startsWith('bytes 0-'));
        expect(successful206BodyBytes, greaterThan(0));
        expect(first206BodyBytes, hasLength(16));
        // Assert the bounded 503 -> 503 -> 206 prepare sequence before playback.
        // Media3 may issue additional range GETs after playback starts to refill its buffer.
        expect(getRequests, 3);

        // The 12-second first-byte delay can outlive an Android lifecycle
        // transition in the emulator test host. Restore the foreground state
        // after prepare, not only before the player is constructed.
        if (tester.binding.lifecycleState != AppLifecycleState.resumed) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pump();
        }

        final nativePlayer = controller.videoPlayerController;
        expect(nativePlayer, isNotNull);
        final nativeController = nativePlayer!;
        debugPrint(
          'Media3 CI playback state after prepare: lifecycle=${tester.binding.lifecycleState}, '
          'isPlaying=${nativeController.value.isPlaying}, '
          'isBuffering=${nativeController.value.isBuffering}, '
          'positionMs=${nativeController.value.position.inMilliseconds}, '
          'durationMs=${nativeController.value.duration?.inMilliseconds}, '
          'videoSize=${nativeController.value.size}',
        );
        expect(nativeController.value.initialized, isTrue);
        expect(nativeController.value.duration, isNotNull);
        expect(
          nativeController.value.duration!.inSeconds,
          greaterThanOrEqualTo(29),
        );
        expect(nativeController.value.errorDescription, isNull);

        // This case isolates the 503 -> 503 -> delayed 206 transport/prepare
        // contract. Native playback clock and byte-range seek are asserted by
        // the real seeded-torrent integration test below, not conflated with
        // this synthetic delayed-HTTP fixture.
        expect(
          torrentMarkerForwarded,
          isFalse,
          reason:
              'The plugin-only torrent timeout marker must never reach the media origin.',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await server.close(force: true);
        upstreamClient.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'real seeded magnet resolves metadata, streams pieces, serves seek ranges and prepares in Media3',
    (tester) async {
      const infoHash = String.fromEnvironment('MOVIEBOX_TEST_INFO_HASH');
      const peerEndpoint = String.fromEnvironment(
        'MOVIEBOX_TEST_PEER',
        defaultValue: '127.0.0.1:6881',
      );
      const expectedFirstHex = String.fromEnvironment(
        'MOVIEBOX_TEST_FIRST_HEX',
      );
      const expectedSeekHex = String.fromEnvironment('MOVIEBOX_TEST_SEEK_HEX');

      expect(infoHash, matches(RegExp(r'^[a-f0-9]{40}$')));
      expect(peerEndpoint, '127.0.0.1:6881');
      expect(expectedFirstHex, hasLength(32));
      expect(expectedSeekHex, hasLength(32));

      const channel = MethodChannel('moviebox_nexus/torrent');
      await channel
          .invokeMethod<bool>('initialize')
          .timeout(const Duration(seconds: 30));

      // Prove the emulator-to-runner TCP tunnel is reachable before asking
      // libtorrent to fetch metadata from the deterministic local seeder.
      final peerProbe = await Socket.connect(
        '127.0.0.1',
        6881,
        timeout: const Duration(seconds: 8),
      );
      await peerProbe.close();

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

      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
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
        if (response.statusCode != HttpStatus.partialContent) {
          final diagnostic = await response.transform(utf8.decoder).join();
          Map<String, dynamic> nativeStatus = <String, dynamic>{};
          try {
            nativeStatus =
                await channel.invokeMapMethod<String, dynamic>('getStatus') ??
                <String, dynamic>{};
          } catch (error) {
            nativeStatus = <String, dynamic>{
              'diagnosticError': error.toString(),
            };
          }
          fail(
            'Torrent range $start-$end returned HTTP ${response.statusCode}: '
            '$diagnostic; nativeStatus=$nativeStatus',
          );
        }
        expect(
          response.headers.value(HttpHeaders.contentRangeHeader),
          startsWith('bytes $start-$end/'),
        );
        final bytes = await response
            .fold<List<int>>(<int>[], (result, chunk) => result..addAll(chunk))
            .timeout(
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

        // A 206 response alone is not sufficient: verify native body-byte delivery.
        final torrentStatus = await channel.invokeMapMethod<String, dynamic>(
          'getStatus',
        );
        expect(torrentStatus?['mediaFileReady'], isTrue);
        expect(
          (torrentStatus?['mediaFileLengthBytes'] as num?)?.toInt() ?? 0,
          (torrentStatus?['selectedMediaFileSizeBytes'] as num?)?.toInt(),
        );
        expect(
          (torrentStatus?['httpRequestCount'] as num?)?.toInt() ?? 0,
          greaterThanOrEqualTo(2),
        );
        expect(
          (torrentStatus?['lastHttpStatus'] as num?)?.toInt(),
          HttpStatus.partialContent,
        );
        expect(
          (torrentStatus?['httpBytesSent'] as num?)?.toInt() ?? 0,
          greaterThanOrEqualTo(firstRange.length + seekRange.length),
        );
        expect(
          (torrentStatus?['diskReadCompletedPieces'] as num?)?.toInt() ?? 0,
          greaterThanOrEqualTo(2),
          reason:
              'Each torrent piece must finish libtorrent disk-read before local HTTP bytes are served.',
        );
        expect((torrentStatus?['diskReadFailures'] as num?)?.toInt() ?? 0, 0);
        expect(
          (torrentStatus?['lastRequestBytesSent'] as num?)?.toInt(),
          seekRange.length,
        );
        expect(
          (torrentStatus?['firstByteAtMs'] as num?)?.toInt() ?? 0,
          greaterThan(0),
        );
        expect(
          (torrentStatus?['lastHttpRangeStart'] as num?)?.toInt(),
          seekOffset,
        );
        expect(
          (torrentStatus?['lastHttpRangeEnd'] as num?)?.toInt(),
          seekOffset + 65535,
        );
        debugPrint('MovieBox native torrent HTTP telemetry: $torrentStatus');

        // Finally exercise the actual in-app Media3 player against the URL
        // returned by the magnet bridge—not a separate HTTP test server.
        // Integration-test teardown can leave the test binding in a non-resumed
        // lifecycle state between widget tests. BetterPlayer deliberately ignores
        // play() unless the host app is resumed, so record and restore the real
        // foreground state before exercising the torrent player.
        debugPrint(
          'MovieBox CI lifecycle before torrent player: ${tester.binding.lifecycleState}',
        );
        if (tester.binding.lifecycleState != AppLifecycleState.resumed) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pump();
        }

        final prepared = Completer<Duration>();
        final media3Ready = Completer<BetterPlayerController>();
        await tester.pumpWidget(
          MaterialApp(
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
          ),
        );
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
        expect(initialValue.duration, greaterThan(const Duration(seconds: 20)));
        debugPrint(
          'MovieBox CI torrent Media3 before play: isPlaying=${initialValue.isPlaying}, '
          'isBuffering=${initialValue.isBuffering}, position=${initialValue.position}, '
          'duration=${initialValue.duration}',
        );
        // The integration-test runner can deliver another paused/hidden
        // lifecycle transition while BetterPlayer/Media3 is preparing its
        // native surface. Reassert foreground after the controller exists so
        // the application's lifecycle owner cannot leave a READY player paused.
        debugPrint(
          'MovieBox CI lifecycle after torrent Media3 prepare: '
          '${tester.binding.lifecycleState}',
        );
        if (tester.binding.lifecycleState != AppLifecycleState.resumed) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pump();
        }
        await controller.videoPlayerController!.play().timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw TimeoutException(
            'Media3 native play command timed out on the torrent stream.',
          ),
        );
        debugPrint(
          'MovieBox CI lifecycle after native play: '
          '${tester.binding.lifecycleState}; '
          'isPlaying=${controller.videoPlayerController!.value.isPlaying}',
        );

        final beforePlayback =
            await controller.videoPlayerController!.position ?? Duration.zero;
        await _waitUntil(
          tester,
          () async {
            final position = await controller.videoPlayerController?.position;
            return position != null &&
                position > beforePlayback + const Duration(milliseconds: 800);
          },
          'Media3 native playback clock must advance; a frozen/paused player is not accepted.',
          timeout: const Duration(seconds: 25),
          diagnostic: () async {
            final player = await _media3Diagnostic(controller);
            try {
              final torrent = await channel
                  .invokeMapMethod<String, dynamic>('getStatus')
                  .timeout(const Duration(seconds: 4));
              return '$player nativeTorrentAfterMedia3Play=$torrent';
            } catch (error) {
              return '$player nativeTorrentAfterMedia3PlayUnavailable=$error';
            }
          },
        );

        // Exercise the same Media3 seek operation used by the playback UI.
        // The torrent engine must satisfy data requests at the new position.
        const seekTarget = Duration(seconds: 20);
        await controller
            .seekTo(seekTarget)
            .timeout(
              const Duration(seconds: 20),
              onTimeout: () => throw TimeoutException(
                'Media3 seek command did not complete within 20 seconds.',
              ),
            );
        await _waitUntil(
          tester,
          () async {
            final position = await controller.videoPlayerController?.position;
            return position != null &&
                position >= seekTarget - const Duration(seconds: 1) &&
                position <= seekTarget + const Duration(seconds: 4);
          },
          'Media3 must land near the requested 20-second seek target.',
          timeout: const Duration(seconds: 25),
          diagnostic: () => _media3Diagnostic(controller),
        );
        await _waitUntil(
          tester,
          () async {
            final position = await controller.videoPlayerController?.position;
            return position != null &&
                position > seekTarget + const Duration(milliseconds: 700);
          },
          'Playback must continue after seeking rather than freezing at the seek target.',
          timeout: const Duration(seconds: 15),
          diagnostic: () async {
            final player = await _media3Diagnostic(controller);
            try {
              final torrent = await channel
                  .invokeMapMethod<String, dynamic>('getStatus')
                  .timeout(const Duration(seconds: 4));
              return '$player nativeTorrentAfterSeek=$torrent';
            } catch (error) {
              return '$player nativeTorrentAfterSeekUnavailable=$error';
            }
          },
        );
        debugPrint(
          'MovieBox CI torrent Media3 after seek: '
          '${await controller.videoPlayerController?.position}, '
          'isPlaying=${controller.videoPlayerController?.value.isPlaying}',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        client.close(force: true);
        await channel
            .invokeMethod<bool>('stopPlayback')
            .timeout(const Duration(seconds: 15));
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
