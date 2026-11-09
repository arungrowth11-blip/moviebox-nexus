import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:moviebox_nexus/player_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:moviebox_nexus/main.dart' as moviebox;


const String _sampleMp4Base64 = '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';

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
          final match = RegExp(r'^bytes=(\\d+)-(\\d*)$').firstMatch(range);
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
            end = end.clamp(0, videoBytes.length - 1);
            response.statusCode = HttpStatus.partialContent;
            response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/\\${videoBytes.length}',
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

}
