import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moviebox_nexus/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('M3U parser extracts worldwide metadata and filters adult entries', () {
    const playlist =
        '\uFEFF#EXTM3U\r\n'
        '#EXTINF:-1 tvg-id="WorldNews.us@HD" tvg-logo="https://example.com/logo.png" group-title="News" tvg-country="US" tvg-language="English",World News\r\n'
        'https://example.com/live.m3u8\r\n'
        '#EXTINF:-1 group-title="Adult",Adult Channel\r\n'
        'https://example.com/adult.m3u8\r\n';
    final channels = parseM3uPlaylist(playlist);
    expect(channels, hasLength(1));
    expect(channels.single['name'], 'World News');
    expect(channels.single['id'], 'WorldNews.us');
    expect(channels.single['sourceId'], 'WorldNews.us@HD');
    expect(normalizeIptvChannelId('WorldNews.us@HD'), 'WorldNews.us');
    expect(channels.single['country'], 'US');
    expect(channels.single['countryRaw'], 'US');
    expect(channels.single['language'], 'English');
    expect(channels.single['group'], 'News');
  });

  test('M3U parser preserves provider headers and health score metadata', () {
    const playlist =
        '#EXTM3U\n'
        '#EXTINF:-1 tvg-id="NDTV.in" nexus-score="93.5",NDTV India\n'
        '#EXTVLCOPT:http-user-agent=MovieBoxLiveTest/1.0\n'
        '#EXTVLCOPT:http-referrer=https://broadcaster.example/\n'
        'https://cdn.example/live.m3u8\n';
    final channel = parseM3uPlaylist(playlist).single;
    expect(channel['healthScore'], '93.5');
    expect(channel['userAgent'], 'MovieBoxLiveTest/1.0');
    expect(channel['referrer'], 'https://broadcaster.example/');
  });

  test(
    'country and category filters combine without fuzzy metadata matching',
    () {
      final channels = <Map<String, String>>[
        {
          'name': 'BBC News',
          'countryCode': 'GB',
          'countryName': 'United Kingdom',
          'categoryIds': 'news|general',
          'categoryNames': 'News, General',
        },
        {
          'name': 'NDTV 24x7',
          'countryCode': 'IN',
          'countryName': 'India',
          'categoryIds': 'news',
          'categoryNames': 'News',
        },
        {
          'name': 'Sports One',
          'countryCode': 'GB',
          'countryName': 'United Kingdom',
          'categoryIds': 'sports',
          'categoryNames': 'Sports',
        },
      ];

      expect(countryCodeFromChannelId('BBCNews.uk'), 'GB');
      expect(countryCodeFromChannelId('BBCOne.uk@HD'), 'GB');
      expect(normalizeCountryCode('uk'), 'GB');
      expect(normalizeCountryCode('XX'), '');
      expect(countryCodeFromChannelId('00sReplay.us@SD'), 'US');
      expect(
        countryCodeFromChannelId('00sReplay.us@SD', explicitCountry: 'XX'),
        'US',
      );
      expect(normalizeIptvChannelId('BBCOne.uk@HD'), 'BBCOne.uk');
      expect(
        countryCodeFromChannelId('channel.anything', explicitCountry: 'in'),
        'IN',
      );
      expect(
        filterLiveTvChannels(channels, countryCode: 'GB', categoryId: 'news'),
        hasLength(1),
      );
      expect(
        filterLiveTvChannels(
          channels,
          categoryId: 'news',
          query: 'ndtv',
        ).single['countryCode'],
        'IN',
      );
      expect(
        filterLiveTvChannels(channels, countryCode: '*', categoryId: '*'),
        hasLength(3),
      );
    },
  );

  test('IPTV enrichment joins quality-suffixed IDs and unique channel names', () {
    final countries = <String, dynamic>{
      'IN': {'name': 'India', 'flag': '🇮🇳'},
      'GB': {'name': 'United Kingdom', 'flag': '🇬🇧'},
      'US': {'name': 'United States', 'flag': '🇺🇸'},
      'UA': {'name': 'Ukraine', 'flag': '🇺🇦'},
    };
    final categories = <String, dynamic>{
      'news': 'News',
      'sports': 'Sports',
      'general': 'General',
      'religious': 'Religious',
    };
    final enriched = CatalogEngine().enrichLiveTvChannels(
      <Map<String, String>>[
        {
          'id': 'BBCOne.uk',
          'sourceId': 'BBCOne.uk@HD',
          'name': 'BBC One',
          'url': 'https://example.test/bbc.m3u8',
          'group': 'General',
          'country': '',
          'language': 'English',
        },
        {
          // A non-empty playlist ID may still not exist in iptv-org's channel index.
          'id': 'NDTV24x7',
          'sourceId': 'NDTV24x7',
          'name': 'NDTV 24x7',
          'url': 'https://example.test/ndtv.m3u8',
          'group': 'News',
          'country': '',
          'countryRaw': '',
          'language': 'Hindi',
        },
        {
          // Preserve and resolve an explicit country name if the ID has no suffix.
          'id': 'LocalNewsFeed',
          'sourceId': 'LocalNewsFeed',
          'name': 'Local News',
          'url': 'https://example.test/local.m3u8',
          'group': 'News',
          'country': '',
          'countryRaw': 'United Kingdom',
          'language': 'English',
        },
        {
          'id': 'IndependentFeed',
          'sourceId': 'IndependentFeed',
          'name': 'Independent TV',
          'url': 'https://example.test/independent.m3u8',
          'group': 'General',
          'country': '',
          'countryRaw': 'United States',
          'language': 'English',
        },
        {
          'id': 'OnePlusOneFeed',
          'sourceId': 'OnePlusOneFeed',
          'name': '1+1 International HD (720p)',
          'url': 'https://example.test/oneplusone.m3u8',
          'group': 'General',
          'country': '',
          'language': '',
        },
        {
          'id': '3ABNFeed',
          'sourceId': '3ABNFeed',
          'name': '3ABN English (720p)',
          'url': 'https://example.test/3abn.m3u8',
          'group': 'Religious',
          'country': '',
          'language': 'English',
        },
        {
          'id': '',
          'sourceId': '',
          'name': 'Shared Name',
          'url': 'https://example.test/shared.m3u8',
          'group': 'General',
          'country': '',
          'language': '',
        },
      ],
      {
        'channels': <String, dynamic>{
          'BBCOne.uk': {
            'country': 'GB',
            'categories': ['news'],
          },
        },
        'channelNames': <String, dynamic>{
          'ndtv 24x7': {
            'country': 'IN',
            'categories': ['news'],
          },
          'local news': {
            'country': 'GB',
            'categories': ['news'],
          },
          '1 1 international': {
            'country': 'UA',
            'categories': ['general'],
          },
          '3abn': {
            'country': 'US',
            'categories': ['religious'],
          },
          'shared name': null,
        },
        'countries': countries,
        'categories': categories,
      },
    );

    expect(enriched[0]['countryName'], 'United Kingdom');
    expect(enriched[0]['countryCode'], 'GB');
    expect(enriched[0]['categoryNames'], 'News');
    expect(enriched[1]['countryName'], 'India');
    expect(enriched[1]['countryCode'], 'IN');
    expect(enriched[1]['categoryNames'], 'News');
    expect(enriched[2]['countryName'], 'United Kingdom');
    expect(enriched[2]['countryCode'], 'GB');
    expect(enriched[3]['countryName'], 'United States');
    expect(enriched[3]['countryCode'], 'US');
    expect(enriched[4]['countryName'], 'Ukraine');
    expect(enriched[4]['countryCode'], 'UA');
    expect(enriched[4]['categoryNames'], 'General');
    expect(enriched[5]['countryName'], 'United States');
    expect(enriched[5]['countryCode'], 'US');
    expect(enriched[5]['categoryNames'], 'Religious');
    // Duplicate official names are ambiguous; never guess a country.
    expect(enriched[6]['countryName'], 'Country not tagged');
    expect(enriched[6]['countryCode'], '');
  });

  test('multiple IPTV feeds are merged while exact duplicate URLs are removed', () {
    final merged = mergeLiveTvPlaylists({
      'India':
          '#EXTM3U\n#EXTINF:-1 tvg-id="NDTV.in" group-title="News",NDTV\nhttps://one.example/ndtv.m3u8\n',
      'Hindi':
          '#EXTM3U\n#EXTINF:-1 tvg-id="NDTV.in" group-title="News",NDTV Hindi\nhttps://one.example/ndtv.m3u8\n#EXTINF:-1 tvg-id="AajTak.in",Aaj Tak\nhttps://two.example/aajtak.m3u8\n',
      'Worldwide':
          '#EXTM3U\n#EXTINF:-1 tvg-id="BBCNews.uk",BBC News\nhttps://bbc.example/live.m3u8\n',
    });
    expect(merged, hasLength(3));
    expect(merged.first['source'], 'India');
    expect(merged.any((item) => item['name'] == 'Aaj Tak'), isTrue);
    expect(merged.any((item) => item['name'] == 'BBC News'), isTrue);
    final ranked = mergeLiveTvPlaylists({
      'Raw':
          '#EXTM3U\n#EXTINF:-1 tvg-id="NDTV.in",NDTV\nhttps://one.example/verified.m3u8\n',
      'Verified':
          '#EXTM3U\n#EXTINF:-1 tvg-id="NDTV.in" nexus-score="94.2",NDTV\nhttps://one.example/verified.m3u8\n',
    });
    expect(ranked, hasLength(1));
    expect(ranked.single['source'], 'Verified');
    expect(ranked.single['healthScore'], '94.2');
  });

  test(
    'Live TV quarantine persists and returns expired feeds for revalidation',
    () async {
      SharedPreferences.setMockInitialValues({});
      final registry = LiveTvHealthRegistry();
      await registry.load();
      const url = 'https://example.test/channel.m3u8';
      final channel = <String, String>{
        'url': url,
        'name': 'Test Channel',
        'userAgent': 'MovieBoxTest/1.0',
      };

      await registry.quarantine([channel], duration: Duration.zero);
      expect(registry.isQuarantined(url), isTrue);
      expect(registry.dueForRecheck(limit: 6), hasLength(1));

      final restored = LiveTvHealthRegistry();
      await restored.load();
      expect(restored.isQuarantined(url), isTrue);
      final due = restored.dueForRecheck(limit: 6);
      expect(due.single['url'], url);
      expect(due.single['userAgent'], 'MovieBoxTest/1.0');

      await restored.markHealthy(url);
      expect(restored.isQuarantined(url), isFalse);
      expect(restored.dueForRecheck(limit: 6), isEmpty);
    },
  );

  test(
    'Live TV failover validates the HLS segment and forwards provider headers',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final baseUrl = 'http://127.0.0.1:' + server.port.toString();
      server.listen((request) async {
        final response = request.response;
        if (request.uri.path == '/dead.m3u8') {
          response.statusCode = HttpStatus.notFound;
          response.headers.contentType = ContentType.html;
          response.write('<html>not found</html>');
        } else if (request.uri.path == '/good.m3u8' ||
            request.uri.path == '/variant.m3u8' ||
            request.uri.path == '/segment.ts') {
          final userAgent = request.headers.value(HttpHeaders.userAgentHeader);
          final referer = request.headers.value(HttpHeaders.refererHeader);
          if (userAgent != 'MovieBoxLiveTest/1.0' ||
              referer != 'https://broadcaster.example/') {
            response.statusCode = HttpStatus.forbidden;
            response.headers.contentType = ContentType.html;
            response.write('<html>required stream headers missing</html>');
          } else if (request.uri.path == '/good.m3u8') {
            response.statusCode = HttpStatus.ok;
            response.headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            );
            response.write(
              '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1280x720\n/variant.m3u8\n',
            );
          } else if (request.uri.path == '/variant.m3u8') {
            response.statusCode = HttpStatus.ok;
            response.headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            );
            response.write(
              '#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:8,\n/segment.ts\n',
            );
          } else {
            response.statusCode = HttpStatus.ok;
            response.headers.contentType = ContentType('video', 'mp2t');
            response.add(List<int>.filled(188, 0x47));
          }
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });
      final engine = CatalogEngine();
      final selected = <String, String>{
        'id': 'NDTV.in',
        'name': 'NDTV',
        'url': baseUrl + '/dead.m3u8',
      };
      final alternate = <String, String>{
        ...parseM3uPlaylist(
          '#EXTM3U\n'
          '#EXTINF:-1 tvg-id="NDTV.in",NDTV Hindi\n'
          '#EXTVLCOPT:http-user-agent=MovieBoxLiveTest/1.0\n'
          '#EXTVLCOPT:http-referrer=https://broadcaster.example/\n'
          '$baseUrl/good.m3u8\n',
        ).single,
        'source': 'Hindi',
      };
      try {
        final candidates = engine.liveTvAlternates(selected, [
          selected,
          alternate,
        ]);
        expect(candidates, hasLength(2));
        final probe = await engine.probeLiveTvSources(candidates);
        final working = probe.working;
        expect(working?['url'], alternate['url']);
        expect(
          probe.failed.map((item) => item['url']),
          contains(selected['url']),
        );
        expect(working?['source'], 'Hindi');
        expect(
          (await engine.firstWorkingLiveTvSource(candidates))?['url'],
          alternate['url'],
        );
        expect(working?['userAgent'], 'MovieBoxLiveTest/1.0');
        expect(working?['referrer'], 'https://broadcaster.example/');
      } finally {
        engine.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'Live TV rejects a reachable HLS manifest when its first segment is offline',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final baseUrl = 'http://127.0.0.1:' + server.port.toString();
      server.listen((request) async {
        final response = request.response;
        if (request.uri.path == '/channel.m3u8') {
          response.statusCode = HttpStatus.ok;
          response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          response.write(
            '#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:8,\n/offline.ts\n',
          );
        } else if (request.uri.path == '/offline.ts') {
          response.statusCode = HttpStatus.forbidden;
          response.headers.contentType = ContentType.html;
          response.write('<html>segment blocked</html>');
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });
      final engine = CatalogEngine();
      try {
        final selected = <String, String>{
          'id': 'TestChannel.in',
          'name': 'Test Channel',
          'url': baseUrl + '/channel.m3u8',
        };
        expect(await engine.firstWorkingLiveTvSource([selected]), isNull);
      } finally {
        engine.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'direct stream probe accepts HLS and rejects blocked HTML endpoints',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final response = request.response;
        if (request.uri.path == '/working.m3u8') {
          response.statusCode = HttpStatus.ok;
          response.headers.contentType = ContentType.text;
          response.write('#EXTM3U\\n#EXT-X-VERSION:3\\n');
        } else if (request.uri.path == '/blocked.m3u8') {
          response.statusCode = HttpStatus.forbidden;
          response.headers.contentType = ContentType.html;
          response.write('<html>blocked</html>');
        } else {
          response.statusCode = HttpStatus.ok;
          response.headers.contentType = ContentType.html;
          response.write('<!doctype html><html>expired link</html>');
        }
        await response.close();
      });
      final engine = CatalogEngine();
      try {
        expect(
          await engine.probeDirectStream(
            StreamLink(
              url: 'http://127.0.0.1:${server.port}/working.m3u8',
              title: 'HLS',
            ),
          ),
          isTrue,
        );
        expect(
          await engine.probeDirectStream(
            StreamLink(
              url: 'http://127.0.0.1:${server.port}/blocked.m3u8',
              title: 'Blocked HLS',
            ),
          ),
          isFalse,
        );
        expect(
          await engine.probeDirectStream(
            StreamLink(
              url: 'http://127.0.0.1:${server.port}/expired',
              title: 'Expired HTML response',
            ),
          ),
          isFalse,
        );
      } finally {
        engine.close();
        await server.close(force: true);
      }
    },
  );

  test('smart play ranks direct adaptive streams above P2P magnets', () {
    final hls = StreamLink(
      url: 'https://media.example.test/master.m3u8',
      title: '720p',
    );
    final torrent = StreamLink(
      infoHash: '0123456789012345678901234567890123456789',
      title: '2160p Hindi',
      seeders: 0,
    );
    final seeded1080 = StreamLink(
      infoHash: '1123456789012345678901234567890123456789',
      title: '1080p Hindi',
      seeders: 6,
    );
    expect(hls.isDirect, isTrue);
    expect(torrent.isTorrent, isTrue);
    expect(hls.score, greaterThan(torrent.score));
    expect(hls.score, greaterThan(seeded1080.score));
    expect(seeded1080.score, greaterThan(torrent.score));
  });

  test('Meta.fromJson safely parses catalog metadata', () {
    final meta = Meta.fromJson({
      'id': 'tt1234567',
      'name': 'Sample Film',
      'type': 'movie',
      'releaseInfo': '2025-10-01',
      'genres': ['Drama', 'Thriller'],
    });

    expect(meta.id, 'tt1234567');
    expect(meta.name, 'Sample Film');
    expect(meta.year, '2025');
    expect(meta.genres, ['Drama', 'Thriller']);
  });

  test('Stremio magnet tracker hints survive stream resolution', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'streams': [
            {
              'name': 'Torrent source',
              'infoHash': '0123456789012345678901234567890123456789',
              'url':
                  'magnet:?xt=urn:btih:0123456789012345678901234567890123456789'
                  '&tr=udp%3A%2F%2Ftracker.example%3A1337%2Fannounce'
                  '&tr=https%3A%2F%2Ftracker2.example%2Fannounce',
              'fileIdx': 2,
              'sources': [
                'tracker:udp://tracker3.example:6969/announce',
                'tracker:udp://tracker.example:1337/announce',
              ],
            },
          ],
        }),
      );
      await request.response.close();
    });

    final engine = CatalogEngine();
    try {
      final streams = await engine.resolveStreams('movie', 'tt1234567', [
        ManagedAddon(
          name: 'QA addon',
          manifestUrl: 'http://127.0.0.1:${server.port}/manifest.json',
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
      ]);

      expect(streams, hasLength(1));
      expect(
        streams.single.infoHash,
        '0123456789012345678901234567890123456789',
      );
      expect(streams.single.fileIdx, 2);
      expect(
        streams.single.trackers,
        containsAll(<String>[
          'udp://tracker.example:1337/announce',
          'https://tracker2.example/announce',
          'udp://tracker3.example:6969/announce',
        ]),
      );
    } finally {
      engine.close();
      await server.close(force: true);
    }
  });

  testWidgets('MovieBox home shell renders before deferred startup work', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MovieBoxApp());

    expect(find.text('MOVIEBOX '), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
  });
}
