// MovieBox Nexus OS v5.2 — Final Build-Safe
// Paste this file at repo ROOT as main.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

// ============================================================
// CONSTANTS
// ============================================================
const _bg = Color(0xFF05060A);
const _panel = Color(0xFF10131E);
const _cyan = Color(0xFF00E5FF);
const _red = Color(0xFFE50914);
const _purple = Color(0xFFB388FF);
const _muted = Color(0xFF8E8E9A);
const _textPri = Color(0xFFF5F5F7);

const _cinemeta = 'https://v3-cinemeta.strem.io';
const _streamingCatalogs =
    'https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club';
const _appleIndiaRss =
    'https://rss.applemarketingtools.com/api/v2/in/movies/top-movies/30/movies.json';
const _stremioAddonsApi = 'https://stremio-addons.net/api/v0/addons';

// ============================================================
// MODELS
// ============================================================
class Meta {
  final String id, name, type;
  final String poster, background, description, year, rating;
  final List<String> genres;

  Meta({
    required this.id,
    required this.name,
    required this.type,
    this.poster = '',
    this.background = '',
    this.description = '',
    this.year = '',
    this.rating = '',
    this.genres = const [],
  });

  factory Meta.fromJson(Map<String, dynamic> j) {
    final rawId = (j['id'] ?? '').toString();
    final rawYear = (j['releaseInfo'] ?? j['year'] ?? '').toString();
    final genresRaw = j['genres'];
    return Meta(
      id: rawId,
      name: (j['name'] ?? 'Untitled').toString(),
      type: (j['type'] ?? 'movie').toString(),
      poster: (j['poster'] ?? '').toString(),
      background: (j['background'] ?? j['poster'] ?? '').toString(),
      description: (j['description'] ?? '').toString(),
      year: rawYear.length > 4 ? rawYear.substring(0, 4) : rawYear,
      rating: (j['imdbRating'] ?? '').toString(),
      genres: genresRaw is List
          ? genresRaw.map((e) => e.toString()).toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'poster': poster,
        'background': background,
        'description': description,
        'year': year,
        'rating': rating,
        'genres': genres,
      };
}

class StreamLink {
  final String? url;
  final String? infoHash;
  final String title;
  final String addonName;
  final String badge;

  StreamLink({
    this.url,
    this.infoHash,
    this.title = '',
    this.addonName = '',
    this.badge = '',
  });

  int get score {
    final s = '$title ${url ?? ''}'.toLowerCase();
    var n = 0;
    if (url != null && url!.startsWith('http')) n += 50;
    if (s.contains('2160') || s.contains('4k')) {
      n += 40;
    } else if (s.contains('1080')) {
      n += 30;
    } else if (s.contains('720')) {
      n += 15;
    }
    if (s.contains('hindi') || s.contains('dual') || s.contains('multi')) n += 20;
    if (s.contains('hdr') || s.contains('dolby')) n += 10;
    if (s.contains('cam') || s.contains('telesync')) n -= 50;
    if (infoHash != null) n += 5;
    return n;
  }

  bool get isDirect => url != null && url!.startsWith('http');
}

class OttBrand {
  final String name;
  final String shortId;
  final Color color;
  final String fallbackGenre;

  const OttBrand({
    required this.name,
    required this.shortId,
    required this.color,
    required this.fallbackGenre,
  });
}

const List<OttBrand> _brands = [
  OttBrand(name: 'NETFLIX', shortId: 'nfx', color: Color(0xFFE50914), fallbackGenre: 'Thriller'),
  OttBrand(name: 'PRIME VIDEO', shortId: 'amp', color: Color(0xFF00A8E1), fallbackGenre: 'Action'),
  OttBrand(name: 'APPLE TV+', shortId: 'atp', color: Color(0xFFE2E8F0), fallbackGenre: 'Sci-Fi'),
  OttBrand(name: 'DISNEY+ HOTSTAR', shortId: 'dnp', color: Color(0xFF113CCF), fallbackGenre: 'Adventure'),
  OttBrand(name: 'HBO MAX', shortId: 'hbm', color: Color(0xFF991EEB), fallbackGenre: 'Drama'),
  OttBrand(name: 'HULU & FX', shortId: 'hlu', color: Color(0xFF1CE783), fallbackGenre: 'Comedy'),
  OttBrand(name: 'DESI / INDIAN', shortId: 'jhs', color: Color(0xFFFF9933), fallbackGenre: 'Mystery'),
];

class CatalogRowSpec {
  final String title;
  final String primaryUrl;
  final String? fallbackUrl;
  final String type;
  final Color accent;
  final bool showRanks;

  CatalogRowSpec({
    required this.title,
    required this.primaryUrl,
    this.fallbackUrl,
    this.type = 'movie',
    this.accent = _cyan,
    this.showRanks = false,
  });
}

// ============================================================
// SELF-HEALING ADDON MANAGER
// ============================================================
class ManagedAddon {
  final String name;
  final String manifestUrl;
  final String baseUrl;
  final bool isBuiltIn;

  ManagedAddon({
    required this.name,
    required this.manifestUrl,
    required this.baseUrl,
    this.isBuiltIn = false,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'manifestUrl': manifestUrl,
        'baseUrl': baseUrl,
        'isBuiltIn': isBuiltIn,
      };

  factory ManagedAddon.fromJson(Map<String, dynamic> j) => ManagedAddon(
        name: (j['name'] ?? 'Addon').toString(),
        manifestUrl: (j['manifestUrl'] ?? '').toString(),
        baseUrl: (j['baseUrl'] ?? '').toString(),
        isBuiltIn: j['isBuiltIn'] == true,
      );
}

class AddonManager {
  final http.Client _client = http.Client();

  static const Map<String, String> _seedAddons = {
    'Torrentio': 'https://torrentio.strem.fun/manifest.json',
    'Torrentio Lite': 'https://torrentio.strem.fun/lite/manifest.json',
    'Comet': 'https://comet.feels.legal/manifest.json',
    'MediaFusion': 'https://mediafusion.elfhosted.com/manifest.json',
    'Cinemeta': 'https://v3-cinemeta.strem.io/manifest.json',
    'Streaming Catalogs':
        'https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club/manifest.json',
    'ThePirateBay+': 'https://thepiratebay-plus.strem.fun/manifest.json',
    'Public Domain Movies': 'https://publicdomainmovies.strem.io/manifest.json',
    'USA TV': 'https://848b3516657c-usatv.baby-beamup.club/manifest.json',
    'FTV Channels': 'https://ftv-stremio.surge.sh/manifest.json',
  };

  Future<bool> isAlive(String manifestUrl) async {
    if (manifestUrl.isEmpty) return false;
    try {
      final r = await _client
          .get(Uri.parse(manifestUrl))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return false;
      final j = jsonDecode(r.body);
      if (j is! Map) return false;
      return (j['id'] ?? '').toString().isNotEmpty &&
          (j['name'] ?? '').toString().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<List<ManagedAddon>> discoverNewAddons() async {
    final out = <ManagedAddon>[];
    try {
      final r = await _client
          .get(Uri.parse('$_stremioAddonsApi?limit=30&sort_by=stars&order=desc'))
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return out;
      final j = jsonDecode(r.body);
      final addons = j is Map ? j['addons'] : null;
      if (addons is! List) return out;

      for (final a in addons) {
        if (a is! Map) continue;
        final name = (a['name'] ?? '').toString();
        final instances = a['instances'];
        if (instances is! List) continue;

        for (final inst in instances) {
          if (inst is! Map) continue;
          final manifestUrl =
              (inst['manifestUrl'] ?? inst['transportUrl'] ?? '').toString();
          if (!manifestUrl.contains('manifest.json')) continue;
          if (await isAlive(manifestUrl)) {
            final base = manifestUrl.endsWith('/manifest.json')
                ? manifestUrl.substring(
                    0, manifestUrl.length - '/manifest.json'.length)
                : manifestUrl;
            out.add(ManagedAddon(
              name: name,
              manifestUrl: manifestUrl,
              baseUrl: base,
              isBuiltIn: false,
            ));
            break;
          }
        }
        if (out.length >= 15) break;
      }
    } catch (_) {}
    return out;
  }

  Future<List<ManagedAddon>> sync({
    required List<ManagedAddon> current,
    required SharedPreferences prefs,
  }) async {
    final merged = <String, ManagedAddon>{};
    for (final a in current) {
      merged[a.manifestUrl] = a;
    }
    for (final entry in _seedAddons.entries) {
      if (!merged.containsKey(entry.value)) {
        merged[entry.value] = ManagedAddon(
          name: entry.key,
          manifestUrl: entry.value,
          baseUrl: entry.value.replaceAll('/manifest.json', ''),
          isBuiltIn: true,
        );
      }
    }

    final discovered = await discoverNewAddons();
    for (final a in discovered) {
      merged.putIfAbsent(a.manifestUrl, () => a);
    }

    final alive = <ManagedAddon>[];
    for (final a in merged.values) {
      if (await isAlive(a.manifestUrl)) {
        alive.add(a);
      }
    }

    await prefs.setStringList(
        'managed_addons', alive.map((a) => jsonEncode(a.toJson())).toList());

    return alive;
  }

  void close() => _client.close();
}

// ============================================================
// CATALOG ENGINE
// ============================================================
class CatalogEngine {
  final http.Client _client = http.Client();

  Future<List<Meta>> fetchRow(String primary, String? fallback,
      {String type = 'movie'}) async {
    final urls = <String>[primary];
    if (fallback != null) urls.add(fallback);
    for (final u in urls) {
      try {
        final r = await _client
            .get(Uri.parse(u))
            .timeout(const Duration(seconds: 9));
        if (r.statusCode != 200) continue;
        final j = jsonDecode(r.body);
        if (j is! Map) continue;
        final metas = j['metas'];
        if (metas is List && metas.isNotEmpty) {
          return metas
              .whereType<Map>()
              .map((m) => Meta.fromJson(Map<String, dynamic>.from(m)))
              .toList();
        }
      } catch (_) {}
    }
    return [];
  }

  Future<List<Meta>> fetchIndiaTrending() async {
    try {
      final r = await _client
          .get(Uri.parse(_appleIndiaRss))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        final dynamic feed = j is Map ? j['feed'] : null;
        final dynamic resultsRaw = feed is Map ? feed['results'] : null;
        if (resultsRaw is List && resultsRaw.isNotEmpty) {
          final futures = resultsRaw.take(12).map((e) async {
            if (e is! Map) return null;
            final name = (e['name'] ?? '').toString();
            if (name.isEmpty) return null;
            try {
              final sr = await _client
                  .get(Uri.parse(
                      '$_cinemeta/catalog/movie/top/search=${Uri.encodeComponent(name)}.json'))
                  .timeout(const Duration(seconds: 6));
              if (sr.statusCode == 200) {
                final sj = jsonDecode(sr.body);
                final dynamic sm = sj is Map ? sj['metas'] : null;
                if (sm is List && sm.isNotEmpty) {
                  return Meta.fromJson(
                      Map<String, dynamic>.from(sm.first as Map));
                }
              }
            } catch (_) {}
            return null;
          });
          final resolved = await Future.wait(futures);
          final valid = resolved.whereType<Meta>().toList();
          if (valid.isNotEmpty) return valid;
        }
      }
    } catch (_) {}

    try {
      final r = await _client
          .get(Uri.parse('$_streamingCatalogs/catalog/movie/jhs.json'))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        final metas = j is Map ? j['metas'] : null;
        if (metas is List && metas.isNotEmpty) {
          return metas
              .whereType<Map>()
              .map((m) => Meta.fromJson(Map<String, dynamic>.from(m)))
              .toList();
        }
      }
    } catch (_) {}

    return fetchRow('$_cinemeta/catalog/movie/top.json', null);
  }

  Future<List<Meta>> search(String query) async {
    if (query.trim().isEmpty) return [];
    final q = Uri.encodeComponent(query.trim());
    final out = <Meta>[];
    for (final type in ['movie', 'series']) {
      try {
        final r = await _client
            .get(Uri.parse('$_cinemeta/catalog/$type/top/search=$q.json'))
            .timeout(const Duration(seconds: 7));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body);
          final metas = j is Map ? j['metas'] : null;
          if (metas is List) {
            out.addAll(metas
                .whereType<Map>()
                .map((m) => Meta.fromJson(Map<String, dynamic>.from(m))));
          }
        }
      } catch (_) {}
    }
    return out;
  }

  Future<Map<String, dynamic>?> fetchMeta(String type, String id) async {
    for (final host in [_cinemeta, 'https://cinemeta-catalogs.strem.io']) {
      try {
        final r = await _client
            .get(Uri.parse(
                '$host/meta/$type/${Uri.encodeComponent(id)}.json'))
            .timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body);
          final m = j is Map ? j['meta'] : null;
          if (m is Map) return Map<String, dynamic>.from(m);
        }
      } catch (_) {}
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> fetchEpisodes(String seriesId) async {
    final meta = await fetchMeta('series', seriesId);
    if (meta == null) return [];
    final videos = meta['videos'];
    if (videos is! List) return [];
    return videos
        .whereType<Map>()
        .map((v) => Map<String, dynamic>.from(v))
        .toList();
  }

  Future<List<StreamLink>> resolveStreams(
      String type, String id, List<ManagedAddon> addons) async {
    final out = <StreamLink>[];
    for (final addon in addons) {
      final low = addon.name.toLowerCase();
      if (low.contains('cinemeta') || low.contains('streaming catalogs')) {
        continue;
      }
      try {
        final r = await _client
            .get(Uri.parse(
                '${addon.baseUrl}/stream/$type/${Uri.encodeComponent(id)}.json'))
            .timeout(const Duration(seconds: 10));
        if (r.statusCode != 200) continue;
        final j = jsonDecode(r.body);
        final streams = j is Map ? j['streams'] : null;
        if (streams is! List) continue;
        for (final s in streams) {
          if (s is! Map) continue;
          final url = (s['url'] ?? '').toString();
          final hash = (s['infoHash'] ?? '').toString();
          final title =
              (s['title'] ?? s['description'] ?? s['name'] ?? '').toString();
          if (url.isEmpty && hash.isEmpty) continue;
          out.add(StreamLink(
            url: url.startsWith('http') ? url : null,
            infoHash: hash.isNotEmpty ? hash : null,
            title: title.replaceAll('\n', ' ').trim(),
            addonName: addon.name,
            badge: _badgeFor('$title $url'),
          ));
        }
      } catch (_) {}
    }
    out.sort((a, b) => b.score.compareTo(a.score));
    return out;
  }

  String _badgeFor(String text) {
    final t = text.toLowerCase();
    if (t.contains('2160') || t.contains('4k')) return '4K UHD';
    if (t.contains('1080')) return '1080p FHD';
    if (t.contains('720')) return '720p HD';
    if (t.contains('.m3u8')) return 'HLS';
    return 'DIRECT';
  }

  void close() => _client.close();
}

// ============================================================
// MAIN
// ============================================================
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache
    ..maximumSize = 250
    ..maximumSizeBytes = 120 * 1024 * 1024;
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const MovieBoxApp());
}

class MovieBoxApp extends StatelessWidget {
  const MovieBoxApp({super.key});
  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
      },
      child: MaterialApp(
        title: 'MovieBox Nexus OS',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: _bg,
          colorScheme: const ColorScheme.dark(
            primary: _red,
            secondary: _cyan,
            surface: _panel,
          ),
        ),
        home: const RootShell(),
      ),
    );
  }
}

// ============================================================
// ROOT SHELL
// ============================================================
class RootShell extends StatefulWidget {
  const RootShell({super.key});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  final engine = CatalogEngine();
  final addonManager = AddonManager();

  final watchlist = <String>{};
  final watchedEpisodes = <String>{};
  final resumeMs = <String, int>{};
  final resumeTitles = <String, String>{};
  List<ManagedAddon> managedAddons = [];

  HttpServer? _server;
  String remoteUrl = '';
  int tab = 0;
  bool tui = false;
  Timer? _addonRefreshTimer;

  @override
  void initState() {
    super.initState();
    _loadState().then((_) => _syncAddons());
    _startRemote();
    _addonRefreshTimer =
        Timer.periodic(const Duration(hours: 6), (_) => _syncAddons());
  }

  @override
  void dispose() {
    _addonRefreshTimer?.cancel();
    _server?.close(force: true);
    addonManager.close();
    engine.close();
    super.dispose();
  }

  Future<void> _loadState() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      watchlist.addAll(p.getStringList('watchlist') ?? []);
      watchedEpisodes.addAll(p.getStringList('watched_eps') ?? []);
      final raw = p.getString('resume_ms');
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            resumeMs[k.toString()] = int.tryParse(v.toString()) ?? 0;
          });
        }
      }
      final titles = p.getString('resume_titles');
      if (titles != null) {
        final decoded = jsonDecode(titles);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            resumeTitles[k.toString()] = v.toString();
          });
        }
      }
      final cached = p.getStringList('managed_addons') ?? [];
      if (cached.isNotEmpty) {
        managedAddons = cached
            .map((e) => ManagedAddon.fromJson(jsonDecode(e)))
            .toList();
      }
    });
    return;
  }

  Future<void> _saveState() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('watchlist', watchlist.toList());
    await p.setStringList('watched_eps', watchedEpisodes.toList());
    await p.setString('resume_ms', jsonEncode(resumeMs));
    await p.setString('resume_titles', jsonEncode(resumeTitles));
    return;
  }

  Future<void> _syncAddons() async {
    final p = await SharedPreferences.getInstance();
    final synced = await addonManager.sync(
      current: managedAddons,
      prefs: p,
    );
    if (!mounted) return;
    setState(() => managedAddons = synced);
    return;
  }

  Future<void> _startRemote() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8765);
      String ip = '127.0.0.1';
      try {
        final nets = await NetworkInterface.list(
            type: InternetAddressType.IPv4, includeLoopback: false);
        for (final n in nets) {
          for (final a in n.addresses) {
            if (!a.isLoopback) {
              ip = a.address;
              break;
            }
          }
          if (ip != '127.0.0.1') break;
        }
      } catch (_) {}
      remoteUrl = 'http://$ip:8765';
      if (mounted) setState(() {});
      _server!.listen(_handleRemote);
    } catch (_) {}
    return;
  }

  Future<void> _handleRemote(HttpRequest req) async {
    req.response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..set('Access-Control-Allow-Headers', 'Content-Type');
    if (req.method == 'OPTIONS') {
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }
    try {
      if (req.uri.path == '/api/play' && req.method == 'POST') {
        final body = await utf8.decoder.bind(req).join();
        final j = jsonDecode(body);
        final url = (j is Map ? j['url'] : '').toString();
        if (url.startsWith('http')) {
          if (mounted) _pushPlayer('Phone Beam', url, url);
          req.response.write('ok');
        } else {
          req.response.statusCode = 400;
          req.response.write('HTTP URL required');
        }
      } else if (req.uri.path == '/api/addon' && req.method == 'POST') {
        final url = (await utf8.decoder.bind(req).join()).trim();
        await _installManualAddon(url);
        req.response.write('installed');
      } else {
        req.response.headers.contentType = ContentType.html;
        req.response.write(_remoteHtml());
      }
    } catch (e) {
      req.response.statusCode = 400;
      req.response.write('$e');
    }
    await req.response.close();
    return;
  }

  String _remoteHtml() => '''
<!doctype html><html><head><meta name=viewport content="width=device-width,initial-scale=1">
<title>MovieBox Remote</title>
<style>
body{background:#05060A;color:#eef;font-family:system-ui,sans-serif;padding:22px;max-width:520px;margin:auto}
h2{color:#00E5FF}input,button{box-sizing:border-box;width:100%;padding:14px;margin:8px 0;border-radius:10px;border:1px solid #34445c;background:#10131E;color:#fff;font-size:16px}
button{background:#00E5FF;color:#000;font-weight:700;border:none}
</style></head><body>
<h2>📱 MovieBox TV Remote</h2>
<p>Phone and TV must share Wi-Fi.</p>
<form onsubmit="event.preventDefault();fetch('/api/play',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({url:document.getElementById('u').value})}).then(r=>r.text()).then(alert)">
<input id="u" placeholder="https://…/video.mp4 or master.m3u8"><button>▶ Beam to TV</button></form>
<form onsubmit="event.preventDefault();fetch('/api/addon',{method:'POST',body:document.getElementById('a').value}).then(r=>r.text()).then(alert)">
<input id="a" placeholder="https://…/manifest.json"><button>+ Install Addon</button></form>
</body></html>''';

  Future<void> _installManualAddon(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !['http', 'https'].contains(uri.scheme)) {
      throw Exception('Invalid URL');
    }
    final base = url.endsWith('/manifest.json')
        ? url.substring(0, url.length - '/manifest.json'.length)
        : url;
    final addon = ManagedAddon(
      name: uri.host,
      manifestUrl: url,
      baseUrl: base,
      isBuiltIn: false,
    );
    if (await addonManager.isAlive(url)) {
      managedAddons.add(addon);
      final p = await SharedPreferences.getInstance();
      await p.setStringList('managed_addons',
          managedAddons.map((a) => jsonEncode(a.toJson())).toList());
      if (mounted) setState(() {});
    }
    return;
  }

  void _pushPlayer(String title, String url, String key, {VoidCallback? onNext}) {
    final startMs = resumeMs[key] ?? 0;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        title: title,
        url: url,
        initialMs: startMs,
        onSave: (ms) {
          resumeMs[key] = ms;
          resumeTitles[key] = title;
          _saveState();
        },
        onNext: onNext,
      ),
    ));
  }

  Future<void> _toggleWatchlist(String id) async {
    setState(() {
      if (watchlist.contains(id)) {
        watchlist.remove(id);
      } else {
        watchlist.add(id);
      }
    });
    await _saveState();
    return;
  }

  Future<void> _markWatched(String episodeId) async {
    setState(() => watchedEpisodes.add(episodeId));
    await _saveState();
    return;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              tab: tab,
              tui: tui,
              watchlistCount: watchlist.length,
              addonCount: managedAddons.length,
              onTab: (i) => setState(() => tab = i),
              onTuiToggle: () => setState(() => tui = !tui),
              onRefresh: () => _syncAddons(),
              onSearch: _openSearch,
              onAddons: _openAddons,
              onQr: _openQr,
            ),
            Expanded(
              child: tui
                  ? _TuiBody(
                      tab: tab,
                      addonCount: managedAddons.length,
                      watchlistCount: watchlist.length,
                      onExit: () => setState(() => tui = false),
                    )
                  : _buildBody(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (tab) {
      case 0:
        return HomeScreen(
          engine: engine,
          addons: managedAddons,
          watchlist: watchlist,
          watchedEpisodes: watchedEpisodes,
          resumeMs: resumeMs,
          resumeTitles: resumeTitles,
          onToggleWatchlist: _toggleWatchlist,
          onMarkWatched: _markWatched,
          onPlay: _pushPlayer,
          onShowDetails: _openDetails,
        );
      case 1:
        return HubScreen();
      case 2:
        return MoodScreen(engine: engine, onShowDetails: _openDetails);
      case 3:
        return LiveTvScreen(
          onPlay: (title, url) => _pushPlayer(title, url, url),
        );
      case 4:
        return _AddonPage(
          addons: managedAddons,
          onRemove: (a) async {
            setState(() => managedAddons.remove(a));
            final p = await SharedPreferences.getInstance();
            await p.setStringList('managed_addons',
                managedAddons.map((x) => jsonEncode(x.toJson())).toList());
            return;
          },
          onInstall: () => _openAddons(),
          onRefresh: _syncAddons,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  void _openDetails(Meta m) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        side: BorderSide(color: _red),
      ),
      builder: (_) => DetailsSheet(
        meta: m,
        engine: engine,
        addons: managedAddons,
        watchlist: watchlist,
        watchedEpisodes: watchedEpisodes,
        onToggleWatchlist: _toggleWatchlist,
        onMarkWatched: _markWatched,
        onPlay: (title, url, key, {VoidCallback? onNext}) {
          Navigator.of(context).pop();
          _pushPlayer(title, url, key, onNext: onNext);
        },
      ),
    );
  }

  void _openSearch() {
    showDialog(
      context: context,
      builder: (_) => SearchModal(engine: engine, onShowDetails: _openDetails),
    );
  }

  void _openAddons() {
    showDialog(
      context: context,
      builder: (_) => _AddonStoreModal(
        addons: managedAddons,
        onInstall: (a) async {
          managedAddons.add(a);
          final p = await SharedPreferences.getInstance();
          await p.setStringList('managed_addons',
              managedAddons.map((x) => jsonEncode(x.toJson())).toList());
          if (mounted) setState(() {});
          return;
        },
        onRemove: (a) async {
          setState(() => managedAddons.remove(a));
          final p = await SharedPreferences.getInstance();
          await p.setStringList('managed_addons',
              managedAddons.map((x) => jsonEncode(x.toJson())).toList());
          return;
        },
        onSync: _syncAddons,
      ),
    );
  }

  void _openQr() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _panel,
        title: const Text('📱 Scan to Remote',
            style: TextStyle(color: _cyan, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (remoteUrl.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(8),
                color: Colors.white,
                child: QrImageView(
                    data: remoteUrl, size: 220, backgroundColor: Colors.white),
              ),
            const SizedBox(height: 10),
            SelectableText(
              remoteUrl.isEmpty ? 'Starting server…' : remoteUrl,
              style: const TextStyle(color: _red, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
// ============================================================
// TOP BAR
// ============================================================
class _TopBar extends StatelessWidget {
  final int tab;
  final bool tui;
  final int watchlistCount;
  final int addonCount;
  final ValueChanged<int> onTab;
  final VoidCallback onTuiToggle;
  final VoidCallback onRefresh;
  final VoidCallback onSearch;
  final VoidCallback onAddons;
  final VoidCallback onQr;

  const _TopBar({
    required this.tab,
    required this.tui,
    required this.watchlistCount,
    required this.addonCount,
    required this.onTab,
    required this.onTuiToggle,
    required this.onRefresh,
    required this.onSearch,
    required this.onAddons,
    required this.onQr,
  });

  @override
  Widget build(BuildContext context) {
    final tabs = [
      'Home',
      'OTT Hubs',
      'Mood',
      'Live TV',
      'Addons ($addonCount)'
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: _panel,
        border: Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const Text('MOVIEBOX ',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: _red,
                    letterSpacing: 2)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                  border: Border.all(color: _cyan),
                  borderRadius: BorderRadius.circular(4)),
              child: const Text('NEXUS v5',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: _cyan)),
            ),
            const SizedBox(width: 12),
            for (var i = 0; i < tabs.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _FButton(
                  label: tabs[i],
                  active: tab == i,
                  onTap: () => onTab(i),
                ),
              ),
            const SizedBox(width: 8),
            _FButton(label: 'Search', icon: Icons.search, onTap: onSearch),
            const SizedBox(width: 6),
            _FButton(label: 'Refresh', icon: Icons.refresh, onTap: onRefresh),
            const SizedBox(width: 6),
            _FButton(label: 'Addons', icon: Icons.extension, onTap: onAddons),
            const SizedBox(width: 6),
            _FButton(label: 'QR', icon: Icons.qr_code_2, onTap: onQr),
            const SizedBox(width: 6),
            _FButton(
                label: tui ? 'Poster' : 'TUI',
                icon: Icons.terminal,
                onTap: onTuiToggle),
            const SizedBox(width: 6),
            _FButton(
              label: 'WL $watchlistCount',
              icon: Icons.bookmark_outline,
              onTap: () {},
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// HOME SCREEN
// ============================================================
class HomeScreen extends StatefulWidget {
  final CatalogEngine engine;
  final List<ManagedAddon> addons;
  final Set<String> watchlist;
  final Set<String> watchedEpisodes;
  final Map<String, int> resumeMs;
  final Map<String, String> resumeTitles;
  final Future<void> Function(String) onToggleWatchlist;
  final Future<void> Function(String) onMarkWatched;
  final void Function(String, String, String, {VoidCallback? onNext}) onPlay;
  final void Function(Meta) onShowDetails;

  const HomeScreen({
    super.key,
    required this.engine,
    required this.addons,
    required this.watchlist,
    required this.watchedEpisodes,
    required this.resumeMs,
    required this.resumeTitles,
    required this.onToggleWatchlist,
    required this.onMarkWatched,
    required this.onPlay,
    required this.onShowDetails,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final rows = <String, List<Meta>>{};
  final loadingRows = <String>{};
  Meta? hero;
  Timer? heroDebounce;
  int? activeBrandIndex;
  bool indiaLoading = true;

  int get year => DateTime.now().year;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    heroDebounce?.cancel();
    super.dispose();
  }

  List<CatalogRowSpec> _buildSpecs() {
    final specs = <CatalogRowSpec>[];
    final y = year;

    for (final b in _brands) {
      if (activeBrandIndex != null && _brands[activeBrandIndex!] != b) continue;
      specs.add(CatalogRowSpec(
        title: '🎬 ${b.name} • Movies',
        primaryUrl: '$_streamingCatalogs/catalog/movie/${b.shortId}.json',
        fallbackUrl:
            '$_cinemeta/catalog/movie/top/genre=${b.fallbackGenre}.json',
        type: 'movie',
        accent: b.color,
        showRanks: true,
      ));
      specs.add(CatalogRowSpec(
        title: '📺 ${b.name} • Series',
        primaryUrl: '$_streamingCatalogs/catalog/series/${b.shortId}.json',
        fallbackUrl: '$_cinemeta/catalog/series/top.json',
        type: 'series',
        accent: b.color,
        showRanks: true,
      ));
    }

    if (activeBrandIndex == null) {
      specs.addAll([
        CatalogRowSpec(
          title: '🆕 $y New Releases',
          primaryUrl: '$_cinemeta/catalog/movie/top.json',
          fallbackUrl: '$_cinemeta/catalog/movie/imdbRating.json',
        ),
        CatalogRowSpec(
          title: '🏆 ${y - 1} Blockbusters',
          primaryUrl: '$_cinemeta/catalog/movie/imdbRating.json',
          fallbackUrl: '$_cinemeta/catalog/movie/top.json',
        ),
        CatalogRowSpec(
          title: '👻 Horror & Supernatural',
          primaryUrl: '$_cinemeta/catalog/movie/top/genre=Horror.json',
        ),
        CatalogRowSpec(
          title: '🎨 Animation & Anime',
          primaryUrl: '$_cinemeta/catalog/movie/top/genre=Animation.json',
        ),
        CatalogRowSpec(
          title: '🚀 Sci-Fi & Cyberpunk',
          primaryUrl: '$_cinemeta/catalog/movie/top/genre=Sci-Fi.json',
        ),
        CatalogRowSpec(
          title: '🕵️ Crime & Thrillers',
          primaryUrl: '$_cinemeta/catalog/movie/top/genre=Thriller.json',
        ),
        CatalogRowSpec(
          title: '💥 High-Octane Action',
          primaryUrl: '$_cinemeta/catalog/movie/top/genre=Action.json',
        ),
        CatalogRowSpec(
          title: '🏛️ IMDb Hall of Fame',
          primaryUrl: '$_cinemeta/catalog/movie/imdbRating.json',
        ),
      ]);
    }
    return specs;
  }

  Future<void> _loadAll() async {
    setState(() {
      rows.clear();
      loadingRows.clear();
    });
    _loadIndia();
    for (final spec in _buildSpecs()) {
      _loadRow(spec);
    }
    return;
  }

  Future<void> _loadIndia() async {
    setState(() => indiaLoading = true);
    final items = await widget.engine.fetchIndiaTrending();
    if (!mounted) return;
    setState(() {
      rows['🇮🇳 Top 10 in India Today'] = items;
      indiaLoading = false;
      if (hero == null && items.isNotEmpty) hero = items.first;
    });
    return;
  }

  Future<void> _loadRow(CatalogRowSpec spec) async {
    if (rows.containsKey(spec.title)) return;
    setState(() => loadingRows.add(spec.title));
    final items = await widget.engine.fetchRow(
        spec.primaryUrl, spec.fallbackUrl,
        type: spec.type);
    if (!mounted) return;
    setState(() {
      rows[spec.title] = items;
      loadingRows.remove(spec.title);
      if (hero == null && items.isNotEmpty) hero = items.first;
    });
    return;
  }

  void _onFocusMeta(Meta m) {
    heroDebounce?.cancel();
    heroDebounce = Timer(const Duration(milliseconds: 320), () {
      if (mounted && hero?.id != m.id) setState(() => hero = m);
    });
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _loadAll,
      color: _cyan,
      child: CustomScrollView(
        cacheExtent: 600,
        slivers: [
          if (hero != null) SliverToBoxAdapter(child: _buildHero(hero!)),
          SliverToBoxAdapter(child: _buildOttDock()),
          if (widget.resumeMs.isNotEmpty && activeBrandIndex == null)
            SliverToBoxAdapter(child: _buildContinueWatching()),
          SliverToBoxAdapter(
            child: _buildPosterRow(
              title: '🇮🇳 Top 10 in India Today',
              items: rows['🇮🇳 Top 10 in India Today'] ?? [],
              accent: const Color(0xFFFF9933),
              showRanks: true,
              loading: indiaLoading,
            ),
          ),
          ..._buildSpecs().map((spec) => SliverToBoxAdapter(
                child: _buildPosterRow(
                  title: spec.title,
                  items: rows[spec.title] ?? [],
                  accent: spec.accent,
                  showRanks: spec.showRanks,
                  loading: loadingRows.contains(spec.title),
                ),
              )),
          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }

  Widget _buildHero(Meta m) {
    final isFav = widget.watchlist.contains(m.id);
    return Container(
      height: 280,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 380),
            child: m.background.isNotEmpty
                ? Image.network(
                    m.background,
                    key: ValueKey(m.id),
                    fit: BoxFit.cover,
                    cacheWidth: 1280,
                    errorBuilder: (_, __, ___) => Container(color: _panel),
                  )
                : Container(color: _panel),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerRight,
                end: Alignment.centerLeft,
                colors: [_bg.withOpacity(.05), _bg.withOpacity(.98)],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _pill(m.type.toUpperCase(), _red),
                    if (m.rating.isNotEmpty) _pill('★ ${m.rating}', Colors.amber),
                    if (m.year.isNotEmpty) _pill(m.year, _muted),
                    for (final g in m.genres.take(3)) _pill(g, _purple),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  m.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: _textPri),
                ),
                if (m.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    m.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _FButton(
                      label: '⚡ Smart Auto-Play',
                      primary: true,
                      onTap: () => _smartPlay(m),
                    ),
                    _FButton(
                      label: '🎬 Trailer',
                      icon: Icons.ondemand_video,
                      onTap: () => _openTrailer(m),
                    ),
                    _FButton(
                      label: isFav ? '✓ Watchlist' : '+ Watchlist',
                      icon: isFav ? Icons.check : Icons.add,
                      onTap: () => widget.onToggleWatchlist(m.id),
                    ),
                    _FButton(
                      label: 'More Info',
                      icon: Icons.info_outline,
                      onTap: () => widget.onShowDetails(m),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: c.withOpacity(.18),
          border: Border.all(color: c.withOpacity(.5)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(t,
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.bold, color: c)),
      );

  Widget _buildOttDock() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('🌐 OTT BRAND STUDIO DOCK',
                  style: TextStyle(
                      color: _cyan,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2)),
              const Spacer(),
              if (activeBrandIndex != null)
                _FButton(
                  label: '✕ Show All',
                  compact: true,
                  onTap: () {
                    setState(() => activeBrandIndex = null);
                    _loadAll();
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 72,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _brands.length,
              itemBuilder: (_, i) {
                final b = _brands[i];
                final selected = activeBrandIndex == i;
                return Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: _BrandTile(
                    brand: b,
                    selected: selected,
                    onTap: () {
                      setState(() {
                        activeBrandIndex = selected ? null : i;
                      });
                      _loadAll();
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContinueWatching() {
    final items = widget.resumeMs.keys.toList();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Text('⏱ Continue Watching',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: _textPri)),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 92,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              itemCount: items.length,
              itemBuilder: (_, i) {
                final key = items[i];
                final title = widget.resumeTitles[key] ?? key;
                final ms = widget.resumeMs[key] ?? 0;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: SizedBox(
                    width: 230,
                    child: _Card(
                      onTap: () => widget.onPlay(title, key, key),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: _textPri,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12)),
                            const SizedBox(height: 4),
                            Text('Resume from ${_fmt(ms)}',
                                style: const TextStyle(
                                    color: _cyan, fontSize: 11)),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPosterRow({
    required String title,
    required List<Meta> items,
    Color accent = _cyan,
    bool showRanks = false,
    bool loading = false,
  }) {
    if (items.isEmpty && !loading) return const SizedBox.shrink();
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Container(
                      width: 4,
                      height: 16,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(2))),
                  Expanded(
                    child: Text(title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: _textPri)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 210,
              child: items.isEmpty && loading
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: _cyan, strokeWidth: 2))
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final m = items[i];
                        return PosterCard(
                          meta: m,
                          rank: showRanks && i < 10 ? i + 1 : null,
                          accent: accent,
                          onFocus: () => _onFocusMeta(m),
                          onTap: () => widget.onShowDetails(m),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _smartPlay(Meta m) async {
    final streams =
        await widget.engine.resolveStreams(m.type, m.id, widget.addons);
    if (!mounted) return;
    if (streams.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No streams found — install more addons')));
      return;
    }
    final best = streams.first;
    if (best.isDirect) {
      widget.onPlay(m.name, best.url!, m.id);
    } else if (best.infoHash != null) {
      final torr =
          'http://127.0.0.1:8090/stream?link=${best.infoHash}&index=1&play';
      widget.onPlay('${m.name} (TorrServer)', torr, m.id);
    }
    return;
  }

  Future<void> _openTrailer(Meta m) async {
    final q = Uri.encodeComponent('${m.name} ${m.year} official trailer');
    await launchUrl(Uri.parse('https://www.youtube.com/results?search_query=$q'),
        mode: LaunchMode.externalApplication);
    return;
  }

  String _fmt(int ms) {
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ============================================================
// HUB SCREEN
// ============================================================
class HubScreen extends StatelessWidget {
  const HubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 320,
        mainAxisExtent: 130,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _brands.length + 1,
      itemBuilder: (_, i) {
        if (i == _brands.length) {
          return _Card(
            onTap: () {},
            child: const Center(
              child: Text('🎭 GENRE VAULTS\n(Open Mood Tab)',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: _purple,
                      fontWeight: FontWeight.bold,
                      fontSize: 14)),
            ),
          );
        }
        final b = _brands[i];
        return _Card(
          onTap: () {},
          borderColor: b.color,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(b.name,
                    style: TextStyle(
                        color: b.color,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                        letterSpacing: 1.1)),
                const SizedBox(height: 4),
                Text('${b.fallbackGenre} · Top 10 · Originals',
                    style: const TextStyle(color: _muted, fontSize: 11)),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ============================================================
// MOOD SCREEN
// ============================================================
class MoodScreen extends StatefulWidget {
  final CatalogEngine engine;
  final void Function(Meta) onShowDetails;
  const MoodScreen(
      {super.key, required this.engine, required this.onShowDetails});
  @override
  State<MoodScreen> createState() => _MoodScreenState();
}

class _MoodScreenState extends State<MoodScreen> {
  static const List<List<String>> _moods = [
    [
      '🧠 Mind-Bending Time Travel',
      'Sci-Fi',
      'Paradoxes, space odysseys, alternate realities'
    ],
    [
      '👻 Late Night Supernatural Horror',
      'Horror',
      'Hauntings, occult, survival horror'
    ],
    ['🎨 Animated & Anime Worlds', 'Animation', 'Top anime, Pixar, visual wonders'],
    ['🕵️ Dark Crime Thrillers', 'Thriller', 'Psychological, detective, high stakes'],
    ['💥 Adrenaline Action', 'Action', 'Martial arts, espionage, explosive'],
    ['😂 Feel-Good Comedy', 'Comedy', 'Rom-coms, family, weekend fun'],
  ];

  List<Meta> _results = [];
  String _currentLabel = '';
  bool _loading = false;

  Future<void> _load(String genre, String label) async {
    setState(() {
      _loading = true;
      _currentLabel = label;
      _results = [];
    });
    final items = await widget.engine.fetchRow(
        '$_cinemeta/catalog/movie/top/genre=$genre.json',
        '$_cinemeta/catalog/movie/imdbRating.json');
    if (!mounted) return;
    setState(() {
      _results = items;
      _loading = false;
    });
    return;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('✨ AI MOOD & VIBE DISCOVERY',
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w900, color: _cyan)),
        ),
        SizedBox(
          height: 130,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _moods.length,
            itemBuilder: (_, i) {
              final m = _moods[i];
              return Padding(
                padding: const EdgeInsets.only(right: 10),
                child: SizedBox(
                  width: 250,
                  child: _Card(
                    onTap: () => _load(m[1], m[0]),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(m[0],
                              style: const TextStyle(
                                  color: _red,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 6),
                          Text(m[2],
                              style: const TextStyle(
                                  color: _muted, fontSize: 11),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (_currentLabel.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Text('Mood: $_currentLabel',
                    style: const TextStyle(
                        color: _cyan, fontWeight: FontWeight.bold)),
                const Spacer(),
                if (_loading)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: _cyan)),
              ],
            ),
          ),
        Expanded(
          child: _results.isEmpty
              ? Center(
                  child: Text(_loading ? '' : 'Pick a mood above',
                      style: const TextStyle(color: _muted)))
              : GridView.builder(
                  padding: const EdgeInsets.all(14),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 150, mainAxisExtent: 210),
                  itemCount: _results.length,
                  itemBuilder: (_, i) => PosterCard(
                    meta: _results[i],
                    onFocus: () {},
                    onTap: () => widget.onShowDetails(_results[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

// ============================================================
// LIVE TV SCREEN
// ============================================================
class LiveTvScreen extends StatefulWidget {
  final void Function(String title, String url) onPlay;
  const LiveTvScreen({super.key, required this.onPlay});
  @override
  State<LiveTvScreen> createState() => _LiveTvScreenState();
}

class _LiveTvScreenState extends State<LiveTvScreen> {
  final _ctrl = TextEditingController();

  final List<List<String>> _channels = [
    [
      'Mux HLS Test',
      'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
      'HLS • 1080p test feed'
    ],
    [
      'Apple BipBop',
      'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8',
      'HLS • Multi-bitrate test'
    ],
    [
      'Big Buck Bunny',
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
      'Direct MP4 • Open source film'
    ],
    [
      'Sintel',
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4',
      'Direct MP4 • Open animation'
    ],
    [
      'Tears of Steel',
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4',
      'Direct MP4 • Sci-Fi short'
    ],
  ];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('📡 Live TV & Direct Stream Hub',
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w900, color: _cyan)),
        const SizedBox(height: 4),
        const Text(
            'Paste any .mp4 / .m3u8 URL, or tap a public test channel below.',
            style: TextStyle(color: _muted, fontSize: 12)),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                style: const TextStyle(color: _textPri),
                decoration: InputDecoration(
                  hintText: 'https://…/video.mp4 or master.m3u8',
                  hintStyle: const TextStyle(color: _muted),
                  filled: true,
                  fillColor: _panel,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _FButton(
              label: 'Play URL',
              primary: true,
              icon: Icons.play_arrow,
              onTap: () {
                final u = _ctrl.text.trim();
                if (u.startsWith('http')) widget.onPlay('Custom URL', u);
              },
            ),
          ],
        ),
        const SizedBox(height: 18),
        ..._channels.map((c) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _Card(
                onTap: () => widget.onPlay(c[0], c[1]),
                child: ListTile(
                  leading: const Icon(Icons.live_tv, color: _red),
                  title: Text(c[0],
                      style: const TextStyle(
                          color: _textPri, fontWeight: FontWeight.bold)),
                  subtitle: Text(c[2],
                      style: const TextStyle(color: _cyan, fontSize: 11)),
                  trailing: const Text('▶',
                      style: TextStyle(
                          color: Colors.greenAccent, fontSize: 18)),
                ),
              ),
            )),
      ],
    );
  }
}

// ============================================================
// ADDON PAGE
// ============================================================
class _AddonPage extends StatelessWidget {
  final List<ManagedAddon> addons;
  final Future<void> Function(ManagedAddon) onRemove;
  final VoidCallback onInstall;
  final VoidCallback onRefresh;

  const _AddonPage({
    required this.addons,
    required this.onRemove,
    required this.onInstall,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('🔌 Addon Manager (Auto-Healing)',
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w900, color: _cyan)),
        const SizedBox(height: 4),
        const Text(
            'Dead addons auto-remove, new ones auto-install every 6 hours.',
            style: TextStyle(color: _muted, fontSize: 12)),
        const SizedBox(height: 12),
        Row(
          children: [
            _FButton(
                label: '+ Manual Install',
                primary: true,
                icon: Icons.add,
                onTap: onInstall),
            const SizedBox(width: 8),
            _FButton(
                label: '🔄 Sync Now',
                icon: Icons.refresh,
                onTap: onRefresh),
          ],
        ),
        const SizedBox(height: 12),
        ...addons.map((a) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _Card(
                child: ListTile(
                  title: Text(a.name,
                      style: const TextStyle(
                          color: _textPri, fontWeight: FontWeight.bold)),
                  subtitle: Text(a.baseUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _muted, fontSize: 11)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline,
                        color: Colors.redAccent),
                    onPressed: () => onRemove(a),
                  ),
                ),
              ),
            )),
      ],
    );
  }
}

// ============================================================
// DETAILS SHEET
// ============================================================
class DetailsSheet extends StatefulWidget {
  final Meta meta;
  final CatalogEngine engine;
  final List<ManagedAddon> addons;
  final Set<String> watchlist;
  final Set<String> watchedEpisodes;
  final Future<void> Function(String) onToggleWatchlist;
  final Future<void> Function(String) onMarkWatched;
  final void Function(String, String, String, {VoidCallback? onNext}) onPlay;

  const DetailsSheet({
    super.key,
    required this.meta,
    required this.engine,
    required this.addons,
    required this.watchlist,
    required this.watchedEpisodes,
    required this.onToggleWatchlist,
    required this.onMarkWatched,
    required this.onPlay,
  });

  @override
  State<DetailsSheet> createState() => _DetailsSheetState();
}

class _DetailsSheetState extends State<DetailsSheet> {
  Map<int, List<Map<String, dynamic>>> _grouped = {};
  int? _season;
  String _targetId = '';
  String _targetLabel = '';
  List<StreamLink> _streams = [];
  bool _loadingStreams = false;
  bool _loadingMeta = false;

  @override
  void initState() {
    super.initState();
    if (widget.meta.type == 'series') {
      _loadEpisodes();
    } else {
      _targetId = widget.meta.id;
      _targetLabel = widget.meta.name;
      _loadStreams(widget.meta.id);
    }
  }

  Future<void> _loadEpisodes() async {
    setState(() => _loadingMeta = true);
    final eps = await widget.engine.fetchEpisodes(widget.meta.id);
    final g = <int, List<Map<String, dynamic>>>{};
    for (final e in eps) {
      final s = int.tryParse((e['season'] ?? '1').toString()) ?? 1;
      if (s == 0) continue;
      g.putIfAbsent(s, () => []).add(e);
    }
    if (!mounted) return;
    setState(() {
      _grouped = g;
      _season = g.keys.isEmpty ? null : (g.keys.toList()..sort()).first;
      _loadingMeta = false;
    });
    final firstSeason = _season;
    if (firstSeason != null && g[firstSeason]!.isNotEmpty) {
      final firstEp = g[firstSeason]!.first;
      final id = (firstEp['id'] ?? '').toString();
      if (id.isNotEmpty) {
        setState(() {
          _targetId = id;
          _targetLabel =
              'S${firstEp['season']}E${firstEp['episode']} · ${firstEp['name'] ?? ''}';
        });
        _loadStreams(id);
      }
    }
    return;
  }

  Future<void> _loadStreams(String id) async {
    setState(() {
      _loadingStreams = true;
      _streams = [];
    });
    final streams = await widget.engine
        .resolveStreams(widget.meta.type, id, widget.addons);
    if (!mounted) return;
    setState(() {
      _streams = streams;
      _loadingStreams = false;
    });
    return;
  }

  @override
  Widget build(BuildContext context) {
    final isFav = widget.watchlist.contains(widget.meta.id);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (_, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.all(18),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(widget.meta.name,
                    style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: _textPri)),
              ),
              _FButton(
                label: isFav ? '✓' : '+ WL',
                compact: true,
                onTap: () => widget.onToggleWatchlist(widget.meta.id),
              ),
            ],
          ),
          if (widget.meta.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(widget.meta.description,
                style: const TextStyle(color: _muted, fontSize: 12)),
          ],
          const Divider(color: Colors.white24, height: 20),
          if (widget.meta.type == 'series' && _grouped.isNotEmpty) ...[
            const Text('Seasons',
                style: TextStyle(
                    color: _cyan, fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: (_grouped.keys.toList()..sort()).map((s) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _FButton(
                      label: 'Season $s',
                      active: _season == s,
                      compact: true,
                      onTap: () => setState(() => _season = s),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 90,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: (_grouped[_season] ?? []).length,
                itemBuilder: (_, i) {
                  final ep = _grouped[_season]![i];
                  final epId = (ep['id'] ?? '').toString();
                  final watched = widget.watchedEpisodes.contains(epId);
                  final selected = _targetId == epId;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 200,
                      child: _Card(
                        selected: selected,
                        onTap: () async {
                          await widget.onMarkWatched(epId);
                          setState(() {
                            _targetId = epId;
                            _targetLabel =
                                'S${ep['season']}E${ep['episode']} · ${ep['name'] ?? ''}';
                          });
                          _loadStreams(epId);
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Row(
                                children: [
                                  Text('EP ${ep['episode']}',
                                      style: const TextStyle(
                                          color: _red,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 11)),
                                  const Spacer(),
                                  if (watched)
                                    const Text('✓',
                                        style: TextStyle(
                                            color: Colors.greenAccent,
                                            fontWeight: FontWeight.bold)),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text((ep['name'] ?? '').toString(),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: _textPri,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const Divider(color: Colors.white24, height: 24),
          ],
          if (widget.meta.type == 'series' && _loadingMeta)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child:
                    CircularProgressIndicator(color: _cyan, strokeWidth: 2),
              ),
            ),
          if (_streams.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _FButton(
                label: '⚡ Smart Auto-Play (${_streams.first.badge})',
                primary: true,
                onTap: () => _playStream(_streams.first),
              ),
            ),
          Text('Streams: $_targetLabel',
              style: const TextStyle(
                  color: _cyan, fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(height: 8),
          if (_loadingStreams)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('Resolving streams…',
                  style: TextStyle(color: _cyan, fontSize: 12)),
            )
          else if (_streams.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                  'No streams found. Try Sync in Addons tab.',
                  style: TextStyle(color: _muted, fontSize: 12)),
            )
          else
            ..._streams.take(25).map((s) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _Card(
                    onTap: () => _playStream(s),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _cyan.withOpacity(.15),
                                  border: Border.all(color: _cyan),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(s.badge,
                                    style: const TextStyle(
                                        color: _cyan,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold)),
                              ),
                              const SizedBox(width: 8),
                              Text(s.addonName,
                                  style: const TextStyle(
                                      color: _red,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold)),
                              const Spacer(),
                              if (s.isDirect)
                                const Text('[PLAY ▶]',
                                    style: TextStyle(
                                        color: Colors.greenAccent,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold))
                              else if (s.infoHash != null)
                                InkWell(
                                  onTap: () {
                                    final torr =
                                        'http://127.0.0.1:8090/stream?link=${s.infoHash}&index=1&play';
                                    widget.onPlay(widget.meta.name, torr,
                                        _targetId);
                                  },
                                  child: const Text('[TORRSERVE ▶]',
                                      style: TextStyle(
                                          color: Colors.amberAccent,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold)),
                                ),
                            ],
                          ),
                          if (s.title.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(s.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: _textPri, fontSize: 11)),
                          ],
                        ],
                      ),
                    ),
                  ),
                )),
        ],
      ),
    );
  }

  void _playStream(StreamLink s) {
    if (s.isDirect) {
      widget.onPlay(
          '${widget.meta.name} · $_targetLabel', s.url!, _targetId);
    } else if (s.infoHash != null) {
      final torr =
          'http://127.0.0.1:8090/stream?link=${s.infoHash}&index=1&play';
      widget.onPlay(widget.meta.name, torr, _targetId);
    }
  }
}

// ============================================================
// PLAYER SCREEN
// ============================================================
class PlayerScreen extends StatefulWidget {
  final String title;
  final String url;
  final int initialMs;
  final Future<void> Function(int) onSave;
  final VoidCallback? onNext;

  const PlayerScreen({
    super.key,
    required this.title,
    required this.url,
    this.initialMs = 0,
    required this.onSave,
    this.onNext,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _c;
  bool _initialized = false;
  bool _error = false;
  bool _hud = true;
  Timer? _saveTimer;
  int _lastSaved = 0;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      _c = c;
      await c.initialize();
      if (widget.initialMs > 5000) {
        await c.seekTo(Duration(milliseconds: widget.initialMs));
      }
      await c.play();
      c.addListener(() {
        if (mounted) setState(() {});
      });
      _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _savePos());
      if (mounted) setState(() => _initialized = true);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
    return;
  }

  Future<void> _savePos() async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final ms = c.value.position.inMilliseconds;
    if ((ms - _lastSaved).abs() < 4000) return;
    _lastSaved = ms;
    await widget.onSave(ms);
    return;
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _savePos();
    _c?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.gameButtonA) {
      _togglePlay();
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      _seek(-15);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _seek(15);
    } else if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown) {
      setState(() => _hud = !_hud);
    }
  }

  void _togglePlay() {
    final c = _c;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
    setState(() => _hud = true);
  }

  void _seek(int sec) {
    final c = _c;
    if (c == null) return;
    final target = c.value.position + Duration(seconds: sec);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > c.value.duration ? c.value.duration : target);
    c.seekTo(clamped);
    setState(() => _hud = true);
  }

  Future<void> _external() async {
    await launchUrl(Uri.parse(widget.url),
        mode: LaunchMode.externalApplication);
    return;
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: () => setState(() => _hud = !_hud),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_initialized && _c != null)
                Center(
                  child: AspectRatio(
                    aspectRatio: _c!.value.aspectRatio,
                    child: VideoPlayer(_c!),
                  ),
                )
              else if (_error)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: Colors.amber, size: 44),
                        const SizedBox(height: 12),
                        const Text(
                            'Playback failed. This stream may use an unsupported codec (MKV/AC3/HEVC).',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white)),
                        const SizedBox(height: 16),
                        _FButton(
                          label: 'Open in External Player',
                          primary: true,
                          icon: Icons.open_in_new,
                          onTap: _external,
                        ),
                      ],
                    ),
                  ),
                )
              else
                const Center(
                  child: CircularProgressIndicator(color: _cyan),
                ),
              if (_hud)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 40, 16, 16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withOpacity(.92),
                        ],
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: _textPri,
                                fontWeight: FontWeight.bold)),
                        if (_initialized && _c != null) ...[
                          const SizedBox(height: 4),
                          VideoProgressIndicator(_c!, allowScrubbing: true,
                              colors: const VideoProgressColors(
                                playedColor: _red,
                                bufferedColor: Colors.white30,
                                backgroundColor: Colors.white10,
                              )),
                        ],
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              onPressed: () => _seek(-15),
                              icon: const Icon(Icons.replay_10,
                                  color: _cyan, size: 30),
                            ),
                            IconButton(
                              onPressed: _togglePlay,
                              icon: Icon(
                                (_c?.value.isPlaying ?? false)
                                    ? Icons.pause_circle_filled
                                    : Icons.play_circle_fill,
                                color: _cyan,
                                size: 48,
                              ),
                            ),
                            IconButton(
                              onPressed: () => _seek(15),
                              icon: const Icon(Icons.forward_10,
                                  color: _cyan, size: 30),
                            ),
                            if (widget.onNext != null)
                              IconButton(
                                onPressed: () {
                                  widget.onNext!();
                                },
                                icon: const Icon(Icons.skip_next,
                                    color: _purple, size: 30),
                              ),
                            IconButton(
                              onPressed: _external,
                              icon: const Icon(Icons.open_in_new,
                                  color: _muted, size: 22),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// SEARCH MODAL
// ============================================================
class SearchModal extends StatefulWidget {
  final CatalogEngine engine;
  final void Function(Meta) onShowDetails;
  const SearchModal(
      {super.key, required this.engine, required this.onShowDetails});
  @override
  State<SearchModal> createState() => _SearchModalState();
}

class _SearchModalState extends State<SearchModal> {
  final _ctrl = TextEditingController();
  List<Meta> _results = [];
  bool _searching = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _doSearch() async {
    if (_ctrl.text.trim().isEmpty) return;
    setState(() => _searching = true);
    final items = await widget.engine.search(_ctrl.text);
    if (!mounted) return;
    setState(() {
      _results = items;
      _searching = false;
    });
    return;
  }

  void _append(String s) {
    _ctrl.text += s;
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() {});
  }

  void _backspace() {
    if (_ctrl.text.isEmpty) return;
    _ctrl.text = _ctrl.text.substring(0, _ctrl.text.length - 1);
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _panel,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: _cyan),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('🔍 Universal Search',
                  style: TextStyle(
                      color: _cyan,
                      fontWeight: FontWeight.bold,
                      fontSize: 16)),
              const SizedBox(height: 10),
              TextField(
                controller: _ctrl,
                style: const TextStyle(color: _textPri),
                decoration: InputDecoration(
                  hintText: 'Type or use D-pad keyboard below',
                  hintStyle: const TextStyle(color: _muted),
                  filled: true,
                  fillColor: _bg,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (_) => _doSearch(),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  ...'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
                      .split('')
                      .map((c) => SizedBox(
                            width: 32,
                            height: 32,
                            child: OutlinedButton(
                              onPressed: () => _append(c),
                              style: OutlinedButton.styleFrom(
                                padding: EdgeInsets.zero,
                                side: const BorderSide(color: Colors.white24),
                              ),
                              child: Text(c,
                                  style: const TextStyle(
                                      fontSize: 11, color: _textPri)),
                            ),
                          )),
                  SizedBox(
                    width: 60,
                    height: 32,
                    child: OutlinedButton(
                      onPressed: () => _append(' '),
                      style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.zero),
                      child: const Text('SPC',
                          style:
                              TextStyle(fontSize: 10, color: _textPri)),
                    ),
                  ),
                  SizedBox(
                    width: 60,
                    height: 32,
                    child: OutlinedButton(
                      onPressed: _backspace,
                      style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.zero),
                      child: const Text('⌫',
                          style:
                              TextStyle(fontSize: 12, color: _textPri)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 6),
                  _FButton(
                    label: 'Search',
                    primary: true,
                    onTap: _doSearch,
                  ),
                ],
              ),
              const Divider(color: Colors.white24, height: 20),
              Expanded(
                child: _searching
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: _cyan, strokeWidth: 2))
                    : _results.isEmpty
                        ? const Center(
                            child: Text('No results yet',
                                style: TextStyle(color: _muted)))
                        : ListView.builder(
                            itemCount: _results.length,
                            itemBuilder: (_, i) => ListTile(
                              dense: true,
                              title: Text(_results[i].name,
                                  style: const TextStyle(color: _textPri)),
                              subtitle: Text(
                                  '${_results[i].type} · ${_results[i].year}',
                                  style: const TextStyle(
                                      color: _muted, fontSize: 11)),
                              onTap: () {
                                Navigator.pop(context);
                                widget.onShowDetails(_results[i]);
                              },
                            ),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// ADDON STORE MODAL
// ============================================================
class _AddonStoreModal extends StatefulWidget {
  final List<ManagedAddon> addons;
  final Future<void> Function(ManagedAddon) onInstall;
  final Future<void> Function(ManagedAddon) onRemove;
  final VoidCallback onSync;

  const _AddonStoreModal({
    required this.addons,
    required this.onInstall,
    required this.onRemove,
    required this.onSync,
  });

  @override
  State<_AddonStoreModal> createState() => _AddonStoreModalState();
}

class _AddonStoreModalState extends State<_AddonStoreModal> {
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _panel,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: _red),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('🔌 Addon Store',
                  style: TextStyle(
                      color: _cyan,
                      fontWeight: FontWeight.bold,
                      fontSize: 16)),
              const SizedBox(height: 8),
              const Text(
                  'Seed + discovered addons are auto-managed. Manual add is optional.',
                  style: TextStyle(color: _muted, fontSize: 11)),
              const SizedBox(height: 8),
              Row(
                children: [
                  _FButton(
                    label: '🔄 Sync Now',
                    primary: true,
                    onTap: () {
                      widget.onSync();
                      setState(() {});
                    },
                  ),
                ],
              ),
              const Divider(color: Colors.white24, height: 20),
              const Text('Installed:',
                  style: TextStyle(
                      color: _cyan,
                      fontSize: 11,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Expanded(
                child: ListView(
                  children: widget.addons
                      .map((a) => ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(a.name,
                                style: const TextStyle(
                                    color: _textPri,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12)),
                            subtitle: Text(a.baseUrl,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: _muted, fontSize: 10)),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.redAccent, size: 18),
                              onPressed: () async {
                                await widget.onRemove(a);
                                setState(() {});
                              },
                            ),
                          ))
                      .toList(),
                ),
              ),
              const Divider(color: Colors.white24, height: 16),
              TextField(
                controller: _nameCtrl,
                style: const TextStyle(color: _textPri, fontSize: 12),
                decoration: const InputDecoration(
                  hintText: 'Custom addon name',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _urlCtrl,
                style: const TextStyle(color: _textPri, fontSize: 12),
                decoration: const InputDecoration(
                  hintText: 'https://…/manifest.json',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                  const SizedBox(width: 8),
                  _FButton(
                    label: '+ Install',
                    primary: true,
                    onTap: () async {
                      final url = _urlCtrl.text.trim();
                      final name = _nameCtrl.text.trim();
                      if (url.startsWith('http') && name.isNotEmpty) {
                        final base = url.endsWith('/manifest.json')
                            ? url.substring(
                                0, url.length - '/manifest.json'.length)
                            : url;
                        await widget.onInstall(ManagedAddon(
                          name: name,
                          manifestUrl: url,
                          baseUrl: base,
                        ));
                        _nameCtrl.clear();
                        _urlCtrl.clear();
                        setState(() {});
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// TUI BODY
// ============================================================
class _TuiBody extends StatelessWidget {
  final int tab;
  final int addonCount;
  final int watchlistCount;
  final VoidCallback onExit;

  const _TuiBody({
    required this.tab,
    required this.addonCount,
    required this.watchlistCount,
    required this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A0B2E),
      padding: const EdgeInsets.all(20),
      child: DefaultTextStyle(
        style: const TextStyle(
            fontFamily: 'monospace',
            color: Color(0xFF00FFCC),
            fontSize: 13),
        child: ListView(
          children: [
            const Text('■ MOVIEBOX-TUI v0.1.27 → v5.2'),
            const Text('══════════════════════════════════════'),
            Text('YEAR      : ${DateTime.now().year}'),
            Text('ADDONS    : $addonCount installed'),
            Text('WATCHLIST : $watchlistCount titles'),
            Text('TAB       : $tab'),
            const Text('══════════════════════════════════════'),
            const Text('> SYSTEM ONLINE'),
            const Text('> RESOLVER: TORRSERVE + TORRENTIO'),
            const Text('> ADDONS: SELF-HEALING ACTIVE'),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: onExit,
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF42F5E9),
                  foregroundColor: Colors.black),
              child: const Text('[Q] EXIT TUI MODE'),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// SHARED WIDGETS
// ============================================================
class _FButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final bool active;
  final bool primary;
  final bool compact;
  final VoidCallback onTap;

  const _FButton({
    required this.label,
    this.icon,
    this.active = false,
    this.primary = false,
    this.compact = false,
    required this.onTap,
  });

  @override
  State<_FButton> createState() => _FButtonState();
}

class _FButtonState extends State<_FButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final bg = _focused
        ? _red
        : widget.primary
            ? _red.withOpacity(.2)
            : widget.active
                ? _cyan.withOpacity(.15)
                : _panel;
    final fg = _focused
        ? Colors.white
        : widget.primary
            ? _red
            : widget.active
                ? _cyan
                : _textPri;
    final border = _focused
        ? _cyan
        : widget.primary
            ? _red
            : widget.active
                ? _cyan
                : Colors.white24;

    return InkWell(
      onFocusChange: (f) => setState(() => _focused = f),
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: EdgeInsets.symmetric(
          horizontal: widget.compact ? 8 : 12,
          vertical: widget.compact ? 5 : 8,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border, width: _focused ? 2 : 1),
          boxShadow: _focused
              ? [BoxShadow(color: _cyan.withOpacity(.55), blurRadius: 14)]
              : [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, size: 14, color: fg),
              const SizedBox(width: 5),
            ],
            Text(widget.label,
                style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.bold,
                    fontSize: widget.compact ? 10 : 12)),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final bool selected;
  final Color? borderColor;

  const _Card({
    required this.child,
    this.onTap,
    this.selected = false,
    this.borderColor,
  });

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final border = _focused
        ? _cyan
        : widget.selected
            ? _red
            : (widget.borderColor ?? Colors.white12);
    return InkWell(
      onFocusChange: (f) => setState(() => _focused = f),
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: border, width: _focused || widget.selected ? 2 : 1),
          boxShadow: _focused
              ? [BoxShadow(color: _cyan.withOpacity(.45), blurRadius: 14)]
              : [],
        ),
        child: widget.child,
      ),
    );
  }
}

class PosterCard extends StatefulWidget {
  final Meta meta;
  final int? rank;
  final Color accent;
  final VoidCallback onFocus;
  final VoidCallback onTap;

  const PosterCard({
    super.key,
    required this.meta,
    this.rank,
    this.accent = _cyan,
    required this.onFocus,
    required this.onTap,
  });

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: InkWell(
        onFocusChange: (f) {
          setState(() => _focused = f);
          if (f) widget.onFocus();
        },
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedScale(
          duration: const Duration(milliseconds: 130),
          scale: _focused ? 1.07 : 1.0,
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            width: 130,
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _focused ? _cyan : Colors.white12,
                width: _focused ? 2.5 : 1,
              ),
              boxShadow: _focused
                  ? [BoxShadow(color: _cyan.withOpacity(.5), blurRadius: 18)]
                  : [],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(8)),
                        child: widget.meta.poster.isNotEmpty
                            ? Image.network(
                                widget.meta.poster,
                                fit: BoxFit.cover,
                                cacheWidth: 280,
                                errorBuilder: (_, __, ___) => _fallback(),
                              )
                            : _fallback(),
                      ),
                      if (widget.rank != null)
                        Positioned(
                          top: 6,
                          left: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: widget.accent,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('#${widget.rank}',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 11)),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.meta.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: _textPri,
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(widget.meta.year,
                              style: const TextStyle(
                                  color: _muted, fontSize: 9)),
                          if (widget.meta.rating.isNotEmpty)
                            Text('★ ${widget.meta.rating}',
                                style: const TextStyle(
                                    color: Colors.amber,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fallback() => Container(
        color: _panel,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(6),
        child: Text(widget.meta.name,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: _cyan, fontSize: 10, fontWeight: FontWeight.bold)),
      );
}

class _BrandTile extends StatefulWidget {
  final OttBrand brand;
  final bool selected;
  final VoidCallback onTap;

  const _BrandTile({
    required this.brand,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_BrandTile> createState() => _BrandTileState();
}

class _BrandTileState extends State<_BrandTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = _focused || widget.selected;
    return InkWell(
      onFocusChange: (f) => setState(() => _focused = f),
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 160,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              widget.brand.color.withOpacity(active ? .38 : .15),
              _panel,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: active ? widget.brand.color : Colors.white24,
              width: active ? 2.2 : 1),
          boxShadow: _focused
              ? [
                  BoxShadow(
                      color: widget.brand.color.withOpacity(.5),
                      blurRadius: 16)
                ]
              : [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(widget.brand.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: widget.brand.color,
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                    letterSpacing: 1)),
            const SizedBox(height: 3),
            Text(widget.brand.fallbackGenre,
                style: const TextStyle(color: _muted, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}
