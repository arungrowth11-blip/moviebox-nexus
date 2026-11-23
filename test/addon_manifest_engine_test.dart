import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:moviebox_nexus/main.dart' as app;
import 'package:moviebox_nexus/src/addons/stremio_manifest.dart';

const id = 'tt1234567';
Map<String, dynamic> qaManifest({List<String> resources = const ['stream']}) =>
    {
      'id': 'org.moviebox.qa',
      'name': 'MovieBox QA Addon',
      'types': ['movie'],
      'idPrefixes': ['tt'],
      'resources': resources,
      'catalogs': [
        {'type': 'movie', 'id': 'popular', 'name': 'Popular'},
      ],
    };
Future<void> sendJson(
  HttpResponse response,
  Object value, {
  int status = 200,
}) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(value));
  await response.close();
}

void main() {
  test(
    'fresh manifest cache and seven-day stale fallback are enforced',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      DateTime now = DateTime.utc(2026, 11, 18);
      var manifestRequests = 0;
      var streamRequests = 0;
      var status = HttpStatus.ok;
      server.listen((request) async {
        if (request.uri.path == '/manifest.json') {
          manifestRequests++;
          if (status != HttpStatus.ok) {
            await sendJson(request.response, {
              'error': 'unavailable',
            }, status: status);
          } else {
            await sendJson(request.response, qaManifest());
          }
        } else if (request.uri.path == '/stream/movie/$id.json') {
          streamRequests++;
          await sendJson(request.response, {'streams': <Object>[]});
        } else {
          await sendJson(request.response, {
            'error': 'unexpected',
          }, status: HttpStatus.notFound);
        }
      });
      final engine = app.CatalogEngine(clock: () => now);
      final addon = app.ManagedAddon(
        name: 'Configured addon',
        manifestUrl: 'http://127.0.0.1:${server.port}/manifest.json',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      try {
        await engine.resolveStreams('movie', id, [addon]);
        now = now.add(const Duration(minutes: 5));
        await engine.resolveStreams('movie', id, [addon]);
        expect(
          manifestRequests,
          1,
          reason: 'Fresh manifest is reused inside the 15-minute TTL.',
        );
        status = HttpStatus.serviceUnavailable;
        now = now.add(const Duration(minutes: 11));
        await engine.resolveStreams('movie', id, [addon]);
        expect(manifestRequests, 2);
        expect(
          streamRequests,
          3,
          reason:
              'Last known-good manifest remains usable inside the seven-day stale window.',
        );
        now = now.add(const Duration(days: 8));
        await engine.resolveStreams('movie', id, [addon]);
        expect(manifestRequests, 3);
        expect(
          streamRequests,
          3,
          reason: 'Expired stale data must not route a provider request.',
        );
      } finally {
        engine.close();
        await server.close(force: true);
      }
    },
  );

  test('simultaneous resolutions coalesce one manifest HTTP request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final manifestArrived = Completer<void>();
    final releaseManifest = Completer<void>();
    var manifestRequests = 0;
    var streamRequests = 0;
    server.listen((request) async {
      if (request.uri.path == '/manifest.json') {
        manifestRequests++;
        if (!manifestArrived.isCompleted) manifestArrived.complete();
        await releaseManifest.future;
        await sendJson(request.response, qaManifest());
      } else if (request.uri.path == '/stream/movie/$id.json') {
        streamRequests++;
        await sendJson(request.response, {'streams': <Object>[]});
      } else {
        await sendJson(request.response, {
          'error': 'unexpected',
        }, status: HttpStatus.notFound);
      }
    });
    final engine = app.CatalogEngine();
    final addon = app.ManagedAddon(
      name: 'Concurrent addon',
      manifestUrl: 'http://127.0.0.1:${server.port}/manifest.json',
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
    try {
      final first = engine.resolveStreams('movie', id, [addon]);
      final second = engine.resolveStreams('movie', id, [addon]);
      await manifestArrived.future.timeout(const Duration(seconds: 3));
      expect(manifestRequests, 1);
      releaseManifest.complete();
      await Future.wait([first, second]).timeout(const Duration(seconds: 5));
      expect(manifestRequests, 1);
      expect(streamRequests, 2);
    } finally {
      if (!releaseManifest.isCompleted) releaseManifest.complete();
      engine.close();
      await server.close(force: true);
    }
  });

  test(
    'fast addon emits partial results before the slow manifest completes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final slowArrived = Completer<void>();
      final releaseSlow = Completer<void>();
      server.listen((request) async {
        final path = request.uri.path;
        if (path == '/slow/manifest.json') {
          if (!slowArrived.isCompleted) slowArrived.complete();
          await releaseSlow.future;
          await sendJson(request.response, qaManifest());
        } else if (path == '/fast/manifest.json') {
          await sendJson(request.response, qaManifest());
        } else if (path == '/fast/stream/movie/$id.json') {
          await sendJson(request.response, {
            'streams': [
              {'title': 'Fast result', 'url': 'https://media.example/fast.mp4'},
            ],
          });
        } else if (path == '/slow/stream/movie/$id.json') {
          await sendJson(request.response, {
            'streams': [
              {'title': 'Slow result', 'url': 'https://media.example/slow.mp4'},
            ],
          });
        } else {
          await sendJson(request.response, {
            'error': 'unexpected',
          }, status: HttpStatus.notFound);
        }
      });
      final engine = app.CatalogEngine();
      final firstUpdate = Completer<List<app.StreamLink>>();
      final addons = [
        app.ManagedAddon(
          name: 'Slow addon',
          manifestUrl: 'http://127.0.0.1:${server.port}/slow/manifest.json',
          baseUrl: 'http://127.0.0.1:${server.port}/slow',
        ),
        app.ManagedAddon(
          name: 'Fast addon',
          manifestUrl: 'http://127.0.0.1:${server.port}/fast/manifest.json',
          baseUrl: 'http://127.0.0.1:${server.port}/fast',
        ),
      ];
      try {
        final allFuture = engine.resolveStreams(
          'movie',
          id,
          addons,
          onUpdate: (streams) {
            if (!firstUpdate.isCompleted) firstUpdate.complete(streams);
          },
        );
        await slowArrived.future.timeout(const Duration(seconds: 3));
        final partial = await firstUpdate.future.timeout(
          const Duration(seconds: 3),
        );
        expect(partial.map((stream) => stream.addonName), ['Fast addon']);
        releaseSlow.complete();
        final all = await allFuture.timeout(const Duration(seconds: 5));
        expect(all.map((stream) => stream.addonName).toSet(), {
          'Fast addon',
          'Slow addon',
        });
      } finally {
        if (!releaseSlow.isCompleted) releaseSlow.complete();
        engine.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'stream proxy headers support nested and direct Stremio proxyHeaders maps',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/manifest.json') {
          await sendJson(request.response, qaManifest());
        } else if (request.uri.path == '/stream/movie/$id.json') {
          await sendJson(request.response, {
            'streams': [
              {
                'title': 'Nested headers',
                'url': 'https://media.example/nested.mp4',
                'behaviorHints': {
                  'proxyHeaders': {
                    'request': {
                      'Referer': 'https://nested.example/',
                      'User-Agent': 'Nested-UA',
                    },
                  },
                },
              },
              {
                'title': 'Direct headers',
                'url': 'https://media.example/direct.mp4',
                'behaviorHints': {
                  'proxyHeaders': {
                    'Referer': 'https://direct.example/',
                    'User-Agent': 'Direct-UA',
                  },
                },
              },
            ],
          });
        } else {
          await sendJson(
            request.response,
            {'error': 'unexpected'},
            status: HttpStatus.notFound,
          );
        }
      });
      final engine = app.CatalogEngine();
      final addon = app.ManagedAddon(
        name: 'Header compatibility addon',
        manifestUrl: 'http://127.0.0.1:${server.port}/manifest.json',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      try {
        final streams = await engine.resolveStreams('movie', id, [addon]);
        expect(streams, hasLength(2));
        final nested = streams.singleWhere((s) => s.title == 'Nested headers');
        final direct = streams.singleWhere((s) => s.title == 'Direct headers');
        expect(nested.headers['Referer'], 'https://nested.example/');
        expect(nested.headers['User-Agent'], 'Nested-UA');
        expect(direct.headers['Referer'], 'https://direct.example/');
        expect(direct.headers['User-Agent'], 'Direct-UA');
      } finally {
        engine.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'configured manifest path and query token reach the catalog HTTP endpoint',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requested = <Uri>[];
      server.listen((request) async {
        requested.add(request.uri);
        if (request.uri.path == '/config/user-token/manifest.json') {
          await sendJson(request.response, qaManifest(resources: ['catalog']));
        } else if (request.uri.path ==
            '/config/user-token/catalog/movie/popular.json') {
          await sendJson(request.response, {
            'metas': [
              {'id': id, 'type': 'movie', 'name': 'Manifest-routed film'},
            ],
          });
        } else {
          await sendJson(request.response, {
            'error': 'unexpected',
          }, status: HttpStatus.notFound);
        }
      });
      final manifestUrl =
          'http://127.0.0.1:${server.port}/config/user-token/manifest.json?api_key=qa-token';
      final engine = app.CatalogEngine();
      final addon = app.ManagedAddon(
        name: 'Catalog addon',
        manifestUrl: manifestUrl,
        baseUrl: 'http://127.0.0.1:${server.port}/config/user-token',
      );
      try {
        final catalogs = await engine.fetchAddonCatalogs(addon);
        expect(catalogs, hasLength(1));
        expect(catalogs.single.manifestUrl, manifestUrl);
        final route = StremioAddonManifest.resourceUri(
          catalogs.single.manifestUrl,
          resource: 'catalog',
          type: 'movie',
          id: catalogs.single.id,
        );
        final metas = await engine.fetchRow(route.toString(), null);
        expect(metas.single.id, id);
        expect(metas.single.name, 'Manifest-routed film');
        expect(
          requested.map((uri) => uri.path),
          contains('/config/user-token/catalog/movie/popular.json'),
        );
        expect(requested.last.queryParameters['api_key'], 'qa-token');
      } finally {
        engine.close();
        await server.close(force: true);
      }
    },
  );
}
