import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:moviebox_nexus/main.dart' as moviebox;

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
}
