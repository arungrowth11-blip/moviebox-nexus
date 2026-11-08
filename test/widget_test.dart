import 'package:flutter_test/flutter_test.dart';
import 'package:moviebox_nexus/main.dart';

void main() {
  test('M3U parser extracts worldwide metadata and filters adult entries', () {
    const playlist = '\uFEFF#EXTM3U\r\n'
        '#EXTINF:-1 tvg-logo="https://example.com/logo.png" group-title="News" tvg-country="US" tvg-language="English",World News\r\n'
        'https://example.com/live.m3u8\r\n'
        '#EXTINF:-1 group-title="Adult",Adult Channel\r\n'
        'https://example.com/adult.m3u8\r\n';
    final channels = parseM3uPlaylist(playlist);
    expect(channels, hasLength(1));
    expect(channels.single['name'], 'World News');
    expect(channels.single['country'], 'US');
    expect(channels.single['language'], 'English');
    expect(channels.single['group'], 'News');
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
