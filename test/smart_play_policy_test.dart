import 'package:flutter_test/flutter_test.dart';
import 'package:moviebox_nexus/main.dart';

void main() {
  test(
    'torrent fallback excludes direct URLs and prioritizes healthier swarms',
    () {
      final ranked = rankTorrentPlaybackCandidates(<StreamLink>[
        StreamLink(
          url: 'https://media.example.test/movie.m3u8',
          title: 'Direct HLS 4K',
        ),
        StreamLink(
          infoHash: '0000000000000000000000000000000000000001',
          title: '4K UHD',
          seeders: 0,
        ),
        StreamLink(
          infoHash: '0000000000000000000000000000000000000002',
          title: '1080p',
          seeders: 4,
        ),
        StreamLink(
          infoHash: '0000000000000000000000000000000000000003',
          title: '720p',
          seeders: 9,
        ),
      ]);

      expect(ranked.map((stream) => stream.infoHash).toList(), <String?>[
        '0000000000000000000000000000000000000003',
        '0000000000000000000000000000000000000002',
        '0000000000000000000000000000000000000001',
      ]);
    },
  );

  test('torrent fallback preserves unknown-seeder candidates', () {
    final ranked = rankTorrentPlaybackCandidates(<StreamLink>[
      StreamLink(
        infoHash: '0000000000000000000000000000000000000011',
        title: 'Unknown swarm',
      ),
    ]);

    expect(ranked, hasLength(1));
    expect(ranked.single.seeders, isNull);
  });
  test(
    'same-infohash addon results pool trackers without merging different files',
    () {
      const hash = '0000000000000000000000000000000000000001';
      final merged = mergeStreamCandidates(<StreamLink>[
        StreamLink(
          infoHash: hash,
          title: 'Movie 1080p Hindi',
          addonName: 'Addon A',
          seeders: 4,
          fileIdx: 0,
          trackers: <String>['udp://tracker-a.example:80/announce'],
        ),
        StreamLink(
          infoHash: hash.toUpperCase(),
          title: 'Movie 1080p',
          addonName: 'Addon B',
          seeders: 9,
          fileIdx: 0,
          trackers: <String>['udp://tracker-b.example:80/announce'],
        ),
        StreamLink(
          infoHash: hash,
          title: 'Movie sample file',
          addonName: 'Addon C',
          seeders: 6,
          fileIdx: 1,
          trackers: <String>['https://tracker-c.example/announce'],
        ),
      ]);

      expect(merged, hasLength(2));
      expect(merged.first.fileIdx, 0);
      expect(merged.first.seeders, 9);
      expect(merged.first.addonName, 'Addon A + Addon B + Addon C');
      expect(merged.first.trackers, <String>[
        'udp://tracker-a.example:80/announce',
        'udp://tracker-b.example:80/announce',
        'https://tracker-c.example/announce',
      ]);
      expect(merged.last.fileIdx, 1);
      expect(merged.last.trackers, merged.first.trackers);
    },
  );

  test('torrent infohash canonicalization accepts BTIH hex and base32', () {
    expect(
      canonicalTorrentInfoHash('0000000000000000000000000000000000000001'),
      '0000000000000000000000000000000000000001',
    );
    expect(
      canonicalTorrentInfoHash('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'),
      '0000000000000000000000000000000000000000',
    );
    expect(
      canonicalTorrentInfoHash('urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'),
      '0000000000000000000000000000000000000000',
    );
  });

  test('direct source de-duplication remains separate from torrent swarms', () {
    final merged = mergeStreamCandidates(<StreamLink>[
      StreamLink(
        url: 'https://media.example.test/movie.m3u8',
        title: 'Direct HLS',
        addonName: 'Addon A',
      ),
      StreamLink(
        url: 'https://media.example.test/movie.m3u8',
        title: 'Duplicate direct HLS',
        addonName: 'Addon B',
      ),
      StreamLink(
        infoHash: '0000000000000000000000000000000000000001',
        title: 'Torrent',
        addonName: 'Addon C',
      ),
    ]);

    expect(merged, hasLength(2));
    expect(merged.first.isDirect, isTrue);
    expect(merged.last.isTorrent, isTrue);
  });
}
