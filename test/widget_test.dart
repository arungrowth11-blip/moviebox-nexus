import 'package:flutter_test/flutter_test.dart';
import 'package:moviebox_nexus/main.dart';

void main() {
  test('M3U parser extracts worldwide metadata and filters adult entries', () {
    const playlist = '\uFEFF#EXTM3U\r\n'
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
    expect(channels.single['language'], 'English');
    expect(channels.single['group'], 'News');
  });

  test('country and category filters combine without fuzzy metadata matching', () {
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
    expect(countryCodeFromChannelId('00sReplay.us@SD'), 'US');
    expect(normalizeIptvChannelId('BBCOne.uk@HD'), 'BBCOne.uk');
    expect(countryCodeFromChannelId('channel.anything', explicitCountry: 'in'), 'IN');
    expect(
      filterLiveTvChannels(channels, countryCode: 'GB', categoryId: 'news'),
      hasLength(1),
    );
    expect(
      filterLiveTvChannels(channels, categoryId: 'news', query: 'ndtv').single['countryCode'],
      'IN',
    );
    expect(filterLiveTvChannels(channels, countryCode: '*', categoryId: '*'), hasLength(3));
  });

  test('IPTV enrichment joins quality-suffixed IDs and unique channel names', () {
    final countries = <String, dynamic>{
      'IN': {'name': 'India', 'flag': '🇮🇳'},
      'GB': {'name': 'United Kingdom', 'flag': '🇬🇧'},
    };
    final categories = <String, dynamic>{
      'news': 'News',
      'sports': 'Sports',
    };
    final enriched = enrichLiveTvChannels(
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
          'id': '',
          'sourceId': '',
          'name': 'NDTV 24x7',
          'url': 'https://example.test/ndtv.m3u8',
          'group': 'News',
          'country': '',
          'language': 'Hindi',
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
          'BBCOne.uk': {'country': 'GB', 'categories': ['news']},
        },
        'channelNames': <String, dynamic>{
          'ndtv 24x7': {'country': 'IN', 'categories': ['news']},
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
    // Duplicate official names are ambiguous; never guess a country.
    expect(enriched[2]['countryName'], 'Country not tagged');
    expect(enriched[2]['countryCode'], '');
  });

  test('smart play ranks direct adaptive streams above P2P magnets', () {
    final hls = StreamLink(
      url: 'https://media.example.test/master.m3u8',
      title: '720p',
    );
    final torrent = StreamLink(
      infoHash: '0123456789012345678901234567890123456789',
      title: '2160p Hindi',
    );
    expect(hls.isDirect, isTrue);
    expect(torrent.isTorrent, isTrue);
    expect(hls.score, greaterThan(torrent.score));
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
}
