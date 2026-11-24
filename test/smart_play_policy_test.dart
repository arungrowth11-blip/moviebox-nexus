import 'package:flutter_test/flutter_test.dart';
import 'package:moviebox_nexus/main.dart';

void main() {
  test('torrent fallback excludes direct URLs and prioritizes healthier swarms', () {
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

    expect(
      ranked.map((stream) => stream.infoHash).toList(),
      <String?>[
        '0000000000000000000000000000000000000003',
        '0000000000000000000000000000000000000002',
        '0000000000000000000000000000000000000001',
      ],
    );
  });

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
}
