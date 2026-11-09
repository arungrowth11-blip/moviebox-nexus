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

    expect(countryCodeFromChannelId('BBCNews.uk'), 'UK');
    expect(countryCodeFromChannelId('BBCOne.uk@HD'), 'UK');
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
