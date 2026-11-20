import 'package:flutter_test/flutter_test.dart';
import 'package:moviebox_nexus/src/addons/stremio_manifest.dart';

void main() {
  test(
    'manifest parses string and object resources with scoped capabilities',
    () {
      final manifest = StremioAddonManifest.fromJson({
        'id': 'org.example.addon',
        'name': 'Example Addon',
        'version': '1.2.3',
        'types': ['movie', 'series'],
        'idPrefixes': ['tt'],
        'resources': [
          'catalog',
          'stream',
          {
            'name': 'meta',
            'types': ['movie'],
            'idPrefixes': ['tt'],
          },
        ],
        'catalogs': [
          {'type': 'movie', 'id': 'popular', 'name': 'Popular'},
          {'type': 'series', 'id': 'series', 'name': 'Series'},
        ],
      });

      expect(
        manifest.supportsResource('stream', type: 'movie', id: 'tt1234567'),
        isTrue,
      );
      expect(
        manifest.supportsResource(
          'stream',
          type: 'series',
          id: 'tt1234567:1:2',
        ),
        isTrue,
      );
      expect(
        manifest.supportsResource('stream', type: 'movie', id: 'tmdb:123'),
        isFalse,
      );
      expect(
        manifest.supportsResource('meta', type: 'series', id: 'tt1234567'),
        isFalse,
      );
      expect(
        manifest.supportsResource(
          'catalog',
          type: 'series',
          checkIdPrefix: false,
        ),
        isTrue,
      );
      expect(manifest.catalogs, hasLength(2));
    },
  );

  test('duplicate resource declarations preserve unrestricted dimensions', () {
    final manifest = StremioAddonManifest.fromJson({
      'id': 'org.example.duplicate',
      'name': 'Duplicate Resource Addon',
      'resources': [
        {
          'name': 'stream',
          'types': ['movie'],
          'idPrefixes': ['tt'],
        },
        'stream',
        {
          'name': 'meta',
          'types': ['movie'],
          'idPrefixes': ['tt'],
        },
        {
          'name': 'meta',
          'types': ['movie'],
          'idPrefixes': [],
        },
        {
          'name': 'catalog',
          'types': ['movie'],
          'idPrefixes': ['tt'],
        },
        {
          'name': 'catalog',
          'types': [],
          'idPrefixes': ['tt'],
        },
      ],
    });

    expect(
      manifest.supportsResource('stream', type: 'series', id: 'tmdb:123'),
      isTrue,
    );
    expect(
      manifest.supportsResource('meta', type: 'movie', id: 'tmdb:123'),
      isTrue,
    );
    expect(
      manifest.supportsResource('catalog', type: 'series', id: 'tt1234567'),
      isTrue,
    );
  });

  test(
    'resource URI preserves nested addon path and configured query token',
    () {
      final uri = StremioAddonManifest.resourceUri(
        'https://addon.example/config/user-token/manifest.json?api_key=secret',
        resource: 'stream',
        type: 'series',
        id: 'tt1234567:1:2',
      );

      expect(uri.pathSegments, [
        'config',
        'user-token',
        'stream',
        'series',
        'tt1234567:1:2.json',
      ]);
      expect(uri.queryParameters['api_key'], 'secret');
      expect(uri.host, 'addon.example');
    },
  );

  test('invalid manifest and unsafe manifest URI are rejected', () {
    expect(
      () => StremioAddonManifest.fromJson({'name': 'Missing ID'}),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => StremioAddonManifest.resourceUri(
        'file:///tmp/manifest.json',
        resource: 'stream',
        type: 'movie',
        id: 'tt1234567',
      ),
      throwsFormatException,
    );
  });
}
