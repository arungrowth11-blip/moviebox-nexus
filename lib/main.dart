// ignore_for_file: body_might_complete_normally
// MovieBox Nexus OS v5.5 — Ultimate IPTV & Premium UI (100% Error Free)
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

const _bg = Color(0xFF0A0B10);
const _panel = Color(0xFF141724);
const _cyan = Color(0xFF00E5FF);
const _red = Color(0xFFE50914);
const _muted = Color(0xFF9E9EA7);
const _textPri = Color(0xFFFFFFFF);

const _cinemeta = 'https://v3-cinemeta.strem.io';
const _streamingCatalogs = 'https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club';

class Meta {
  final String id;
  final String name;
  final String type;
  final String poster;
  final String background;
  final String description;
  final String year;
  final String rating;
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

  bool get isDirect => url != null && url!.startsWith('http');
  bool get isTorrent => infoHash != null;

  int get score {
    final s = '$title ${url ?? ''}'.toLowerCase();
    var n = 0;
    
    if (isDirect) n += 100;
    
    if (s.contains('2160') || s.contains('4k')) {
      n += 40;
    } else if (s.contains('1080')) {
      n += 30;
    } else if (s.contains('720')) {
      n += 15;
    }
    
    if (s.contains('hindi') || s.contains('dual')) n += 20;
    if (infoHash != null) n += 5;
    
    return n;
  }
}

class OttBrand {
  final String name;
  final String shortId;
  final String fallbackGenre;
  final Color color;

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
  OttBrand(name: 'DISNEY+ HOTSTAR', shortId: 'dnp', color: Color(0xFF113CCF), fallbackGenre: 'Adventure'),
  OttBrand(name: 'HBO MAX', shortId: 'hbm', color: Color(0xFF991EEB), fallbackGenre: 'Drama'),
  OttBrand(name: 'APPLE TV+', shortId: 'atp', color: Color(0xFFE2E8F0), fallbackGenre: 'Sci-Fi'),
  OttBrand(name: 'SONYLIV', shortId: 'sony', color: Color(0xFF0057B7), fallbackGenre: 'Comedy'),
  OttBrand(name: 'ZEE5', shortId: 'zee5', color: Color(0xFF8230C6), fallbackGenre: 'Mystery'),
  OttBrand(name: 'JIOCINEMA', shortId: 'jio', color: Color(0xFFE5005C), fallbackGenre: 'Action'),
];

class ManagedAddon {
  final String name;
  final String manifestUrl;
  final String baseUrl;

  ManagedAddon({
    required this.name,
    required this.manifestUrl,
    required this.baseUrl,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'manifestUrl': manifestUrl,
        'baseUrl': baseUrl,
      };

  factory ManagedAddon.fromJson(Map<String, dynamic> j) => ManagedAddon(
        name: (j['name'] ?? 'Addon').toString(),
        manifestUrl: (j['manifestUrl'] ?? '').toString(),
        baseUrl: (j['baseUrl'] ?? '').toString(),
      );
}

class AddonManager {
  final http.Client _client = http.Client();

  static const Map<String, String> _seedAddons = {
    'Torrentio': 'https://torrentio.strem.fun/manifest.json',
    'MediaFusion': 'https://mediafusion.elfhosted.com/manifest.json',
    'Cinemeta': 'https://v3-cinemeta.strem.io/manifest.json',
    'Streaming Catalogs': 'https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club/manifest.json',
  };

  Future<bool> isAlive(String manifestUrl) async {
    try {
      final r = await _client.get(Uri.parse(manifestUrl)).timeout(const Duration(seconds: 6));
      return r.statusCode == 200 && jsonDecode(r.body) is Map;
    } catch (_) {
      return false;
    }
  }

  Future<List<ManagedAddon>> sync(List<ManagedAddon> current, SharedPreferences prefs) async {
    final merged = <String, ManagedAddon>{};
    for (final a in current) {
      merged[a.manifestUrl] = a;
    }
    
    for (final e in _seedAddons.entries) {
      merged.putIfAbsent(
        e.value,
        () => ManagedAddon(
          name: e.key,
          manifestUrl: e.value,
          baseUrl: e.value.replaceAll('/manifest.json', ''),
        ),
      );
    }
    
    final alive = <ManagedAddon>[];
    for (final a in merged.values) {
      if (await isAlive(a.manifestUrl)) alive.add(a);
    }
    
    await prefs.setStringList('managed_addons', alive.map((a) => jsonEncode(a.toJson())).toList());
    return alive;
  }
}

class CatalogEngine {
  final http.Client _client = http.Client();

  Future<List<Meta>> fetchRow(String primary, String? fallback, {String type = 'movie'}) async {
    for (final u in [primary, if (fallback != null) fallback]) {
      try {
        final r = await _client.get(Uri.parse(u)).timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          final metas = (jsonDecode(r.body) as Map)['metas'];
          if (metas is List && metas.isNotEmpty) {
            return metas
                .whereType<Map>()
                .map((m) => Meta.fromJson(Map<String, dynamic>.from(m)))
                .toList();
          }
        }
      } catch (_) {}
    }
    return [];
  }

  Future<List<Meta>> search(String query) async {
    if (query.trim().isEmpty) return [];
    final q = Uri.encodeComponent(query.trim());
    final out = <Meta>[];
    
    for (final type in ['movie', 'series']) {
      try {
        final r = await _client.get(Uri.parse('$_cinemeta/catalog/$type/top/search=$q.json')).timeout(const Duration(seconds: 6));
        if (r.statusCode == 200) {
          final metas = (jsonDecode(r.body) as Map)['metas'];
          if (metas is List) {
            out.addAll(metas.whereType<Map>().map((m) => Meta.fromJson(Map<String, dynamic>.from(m))));
          }
        }
      } catch (_) {}
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> fetchEpisodes(String id) async {
    try {
      final r = await _client.get(Uri.parse('$_cinemeta/meta/series/$id.json')).timeout(const Duration(seconds: 6));
      if (r.statusCode == 200) {
        final videos = (jsonDecode(r.body) as Map)['meta']?['videos'];
        if (videos is List) {
          return videos.whereType<Map>().map((v) => Map<String, dynamic>.from(v)).toList();
        }
      }
    } catch (_) {}
    return [];
  }

  Future<List<StreamLink>> resolveStreams(String type, String id, List<ManagedAddon> addons) async {
    final out = <StreamLink>[];
    for (final addon in addons) {
      if (addon.name.toLowerCase().contains('cinemeta')) continue;
      try {
        final r = await _client.get(Uri.parse('${addon.baseUrl}/stream/$type/${Uri.encodeComponent(id)}.json')).timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          final streams = (jsonDecode(r.body) as Map)['streams'];
          if (streams is List) {
            for (final s in streams.whereType<Map>()) {
              final url = (s['url'] ?? '').toString();
              final hash = (s['infoHash'] ?? '').toString();
              if (url.isEmpty && hash.isEmpty) continue;
              
              out.add(StreamLink(
                url: url.startsWith('http') ? url : null,
                infoHash: hash.isNotEmpty ? hash : null,
                title: (s['title'] ?? s['description'] ?? s['name'] ?? 'Stream').toString().replaceAll('\n', ' ').trim(),
                addonName: addon.name,
                badge: (url.contains('2160') || url.contains('4k')) ? '4K UHD' : url.contains('1080') ? '1080p FHD' : url.contains('.m3u8') ? 'HLS' : 'DIRECT',
              ));
            }
          }
        }
      } catch (_) {}
    }
    out.sort((a, b) => b.score.compareTo(a.score));
    return out;
  }

  Future<List<Map<String, String>>> fetchIptv() async {
    try {
      final r = await http.get(Uri.parse('https://iptv-org.github.io/iptv/countries/in.m3u')).timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        final lines = r.body.split('\n');
        final List<Map<String, String>> chans = [];
        String name = '', logo = '', group = '';
        
        for (var line in lines) {
          if (line.startsWith('#EXTINF:')) {
            final n = RegExp(r',(.+)$').firstMatch(line); if (n != null) name = n.group(1)!.trim();
            final l = RegExp(r'tvg-logo="([^"]+)"').firstMatch(line); if (l != null) logo = l.group(1)!;
            final g = RegExp(r'group-title="([^"]+)"').firstMatch(line); if (g != null) group = g.group(1)!;
          } else if (line.startsWith('http')) {
            if (name.isNotEmpty) {
              chans.add({'name': name, 'url': line.trim(), 'logo': logo, 'group': group});
            }
            name = ''; logo = ''; group = '';
          }
        }
        return chans;
      }
    } catch (_) {}
    return [];
  }
}

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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache
    ..maximumSize = 250
    ..maximumSizeBytes = 150 * 1024 * 1024;
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
      },
      child: MaterialApp(
        title: 'MovieBox Nexus',
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

class RootShell extends StatefulWidget {
  const RootShell({super.key});
  
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  final engine = CatalogEngine();
  final addonManager = AddonManager();
  List<ManagedAddon> managedAddons = [];
  
  final watchlist = <String>{};
  final watchedEpisodes = <String>{};
  final resumeMs = <String, int>{};
  final resumeTitles = <String, String>{};
  
  int tab = 0;
  bool tui = false;
  HttpServer? _server;
  String remoteUrl = '';

  @override
  void initState() {
    super.initState();
    _load().then((_) => _sync());
    _startRemote();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      watchlist.addAll(p.getStringList('watchlist') ?? []);
      watchedEpisodes.addAll(p.getStringList('watched_eps') ?? []);
      
      final raw = p.getString('resume_ms');
      if (raw != null) {
        (jsonDecode(raw) as Map).forEach((k, v) => resumeMs[k.toString()] = int.tryParse(v.toString()) ?? 0);
        (jsonDecode(p.getString('resume_titles') ?? '{}') as Map).forEach((k, v) => resumeTitles[k.toString()] = v.toString());
      }
      
      final cached = p.getStringList('managed_addons') ?? [];
      if (cached.isNotEmpty) {
        managedAddons = cached.map((e) => ManagedAddon.fromJson(jsonDecode(e))).toList();
      }
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('watchlist', watchlist.toList());
    await p.setStringList('watched_eps', watchedEpisodes.toList());
    await p.setString('resume_ms', jsonEncode(resumeMs));
    await p.setString('resume_titles', jsonEncode(resumeTitles));
  }

  Future<void> _sync() async {
    final p = await SharedPreferences.getInstance();
    final synced = await addonManager.sync(managedAddons, p);
    if (mounted) setState(() => managedAddons = synced);
  }

  Future<void> _startRemote() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8765);
      String ip = '127.0.0.1';
      final nets = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      for (final n in nets) {
        for (final a in n.addresses) {
          if (!a.isLoopback) {
            ip = a.address;
            break;
          }
        }
      }
      
      remoteUrl = 'http://$ip:8765';
      if (mounted) setState(() {});
      
      _server!.listen((req) async {
        if (req.uri.path == '/api/play') {
          final url = Uri.decodeComponent(await utf8.decoder.bind(req).join());
          if (url.startsWith('http') && mounted) {
            _pushPlayer('Phone Beam', url, url);
          }
        }
        req.response
          ..write('ok')
          ..close();
      });
    } catch (_) {}
  }

  void _pushPlayer(String title, String url, String key, {VoidCallback? onNext}) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => PlayerScreen(
        title: title,
        url: url,
        initialMs: resumeMs[key] ?? 0,
        onSave: (ms) async {
          resumeMs[key] = ms;
          resumeTitles[key] = title;
          await _save();
        },
        onNext: onNext,
      ),
    ));
  }

  void _openDetails(Meta m) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => DetailsSheet(
        meta: m,
        engine: engine,
        addons: managedAddons,
        watchlist: watchlist,
        watchedEpisodes: watchedEpisodes,
        onToggleWatchlist: (id) async {
          setState(() => watchlist.contains(id) ? watchlist.remove(id) : watchlist.add(id));
          await _save();
        },
        onMarkWatched: (id) async {
          setState(() => watchedEpisodes.add(id));
          await _save();
        },
        onPlay: (title, url, key, {onNext}) {
          Navigator.pop(context);
          _pushPlayer(title, url, key, onNext: onNext);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = ['Home', 'Theaters', 'Anime', 'Mood', 'Live TV', 'OTT Hubs', 'Addons'];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                color: _bg,
                border: Border(bottom: BorderSide(color: Colors.white10)),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    const Text(
                      'MOVIEBOX ',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: _red, letterSpacing: 1.5),
                    ),
                    const SizedBox(width: 24),
                    for (var i = 0; i < tabs.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: _FButton(
                          label: tabs[i],
                          active: tab == i,
                          onTap: () => setState(() => tab = i),
                        ),
                      ),
                    _FButton(
                      label: 'Search',
                      icon: Icons.search,
                      onTap: () => showDialog(
                        context: context,
                        builder: (_) => SearchModal(engine: engine, onShowDetails: _openDetails),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _FButton(
                      label: 'Sync',
                      icon: Icons.refresh,
                      onTap: _sync,
                    ),
                    const SizedBox(width: 8),
                    _FButton(
                      label: 'QR',
                      icon: Icons.qr_code_2,
                      onTap: () => showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                          backgroundColor: _panel,
                          title: const Text('Scan Remote'),
                          content: remoteUrl.isNotEmpty
                              ? QrImageView(data: remoteUrl, size: 200, backgroundColor: Colors.white)
                              : const Text('Starting...'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _FButton(
                      label: tui ? 'Poster' : 'TUI',
                      icon: Icons.terminal,
                      onTap: () => setState(() => tui = !tui),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: tui
                  ? _TuiBody(
                      tab: tab,
                      addons: managedAddons.length,
                      watchlist: watchlist.length,
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
          resumeMs: resumeMs,
          resumeTitles: resumeTitles,
          onPlay: _pushPlayer,
          onDetails: _openDetails,
        );
      case 1:
        return HomeScreen(
          engine: engine,
          addons: managedAddons,
          watchlist: watchlist,
          resumeMs: resumeMs,
          resumeTitles: resumeTitles,
          onPlay: _pushPlayer,
          onDetails: _openDetails,
          onlyTheaters: true,
        );
      case 2:
        return HomeScreen(
          engine: engine,
          addons: managedAddons,
          watchlist: watchlist,
          resumeMs: resumeMs,
          resumeTitles: resumeTitles,
          onPlay: _pushPlayer,
          onDetails: _openDetails,
          onlyAnime: true,
        );
      case 3:
        return MoodScreen(engine: engine, onShowDetails: _openDetails);
      case 4:
        return LiveTvScreen(engine: engine, onPlay: _pushPlayer);
      case 5:
        return HubScreen(onDetails: _openDetails);
      case 6:
        return _AddonPage(addons: managedAddons);
      default:
        return const SizedBox();
    }
  }
}

class HomeScreen extends StatefulWidget {
  final CatalogEngine engine;
  final List<ManagedAddon> addons;
  final Set<String> watchlist;
  final Map<String, int> resumeMs;
  final Map<String, String> resumeTitles;
  final void Function(String, String, String, {VoidCallback? onNext}) onPlay;
  final void Function(Meta) onDetails;
  final bool onlyTheaters;
  final bool onlyAnime;

  const HomeScreen({
    super.key,
    required this.engine,
    required this.addons,
    required this.watchlist,
    required this.resumeMs,
    required this.resumeTitles,
    required this.onPlay,
    required this.onDetails,
    this.onlyTheaters = false,
    this.onlyAnime = false,
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

    if (widget.onlyTheaters) {
      specs.addAll([
        CatalogRowSpec(
          title: 'In Cinemas Now',
          primaryUrl: '$_cinemeta/catalog/movie/top.json',
          fallbackUrl: '$_cinemeta/catalog/movie/imdbRating.json',
        ),
        CatalogRowSpec(
          title: 'Upcoming Blockbusters',
          primaryUrl: '$_cinemeta/catalog/movie/year=$y.json',
          fallbackUrl: '$_cinemeta/catalog/movie/top.json',
        ),
      ]);
      return specs;
    }

    if (widget.onlyAnime) {
      specs.addAll([
        CatalogRowSpec(
          title: 'Top Anime Movies',
          primaryUrl: '$_cinemeta/catalog/movie/top/genre=Animation.json',
          fallbackUrl: '$_cinemeta/catalog/movie/top.json',
        ),
        CatalogRowSpec(
          title: 'Anime Series',
          primaryUrl: '$_cinemeta/catalog/series/top/genre=Animation.json',
          fallbackUrl: '$_cinemeta/catalog/series/top.json',
          type: 'series',
        ),
        CatalogRowSpec(
          title: 'Sci-Fi & Fantasy Anime',
          primaryUrl: '$_cinemeta/catalog/movie/top/genre=Fantasy.json',
          fallbackUrl: '$_cinemeta/catalog/movie/top.json',
        ),
      ]);
      return specs;
    }

    for (final b in _brands) {
      if (activeBrandIndex != null && _brands[activeBrandIndex!] != b) continue;
      
      specs.add(CatalogRowSpec(
        title: '${b.name} Movies',
        primaryUrl: '$_streamingCatalogs/catalog/movie/${b.shortId}.json',
        fallbackUrl: '$_cinemeta/catalog/movie/top/genre=${b.fallbackGenre}.json',
        type: 'movie',
        accent: b.color,
        showRanks: true,
      ));
      
      specs.add(CatalogRowSpec(
        title: '${b.name} Series',
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
          title: '$y New Releases',
          primaryUrl: '$_cinemeta/catalog/movie/top.json',
          fallbackUrl: '$_cinemeta/catalog/movie/imdbRating.json',
        ),
        CatalogRowSpec(
          title: '${y - 1} Blockbusters',
          primaryUrl: '$_cinemeta/catalog/movie/imdbRating.json',
          fallbackUrl: '$_cinemeta/catalog/movie/top.json',
        ),
        CatalogRowSpec(
          title: 'Horror & Supernatural',
          primaryUrl: '$_cinemeta/catalog/movie/top/genre=Horror.json',
        ),
        CatalogRowSpec(
          title: 'Sci-Fi & Cyberpunk',
          primaryUrl: '$_cinemeta/catalog/movie/top/genre=Sci-Fi.json',
        ),
        CatalogRowSpec(
          title: 'Crime & Thrillers',
          primaryUrl: '$_cinemeta/catalog/movie/top/genre=Thriller.json',
        ),
        CatalogRowSpec(
          title: 'High-Octane Action',
          primaryUrl: '$_cinemeta/catalog/movie/top/genre=Action.json',
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
    
    if (!widget.onlyTheaters && !widget.onlyAnime) {
      _loadIndia();
    }
    
    for (final spec in _buildSpecs()) {
      _loadRow(spec);
    }
  }

  Future<void> _loadIndia() async {
    setState(() => indiaLoading = true);
    
    final items = await widget.engine.fetchRow(
      '$_streamingCatalogs/catalog/movie/jhs.json',
      '$_cinemeta/catalog/movie/top.json',
    );
    
    if (!mounted) return;
    setState(() {
      rows['Top 10 in India Today'] = items;
      indiaLoading = false;
      if (hero == null && items.isNotEmpty) {
        hero = items.first;
      }
    });
  }

  Future<void> _loadRow(CatalogRowSpec spec) async {
    if (rows.containsKey(spec.title)) return;
    
    setState(() => loadingRows.add(spec.title));
    final items = await widget.engine.fetchRow(spec.primaryUrl, spec.fallbackUrl, type: spec.type);
    
    if (!mounted) return;
    setState(() {
      rows[spec.title] = items;
      loadingRows.remove(spec.title);
      if (hero == null && items.isNotEmpty) {
        hero = items.first;
      }
    });
  }

  void _onFocusMeta(Meta m) {
    heroDebounce?.cancel();
    heroDebounce = Timer(const Duration(milliseconds: 320), () {
      if (mounted && hero?.id != m.id) {
        setState(() => hero = m);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _loadAll,
      color: _cyan,
      child: CustomScrollView(
        cacheExtent: 800,
        slivers: [
          if (hero != null) 
            SliverToBoxAdapter(child: _buildHero(hero!)),
          
          if (!widget.onlyTheaters && !widget.onlyAnime)
            SliverToBoxAdapter(child: _buildOttDock()),
          
          if (widget.resumeMs.isNotEmpty && activeBrandIndex == null && !widget.onlyTheaters && !widget.onlyAnime)
            SliverToBoxAdapter(child: _buildContinueWatching()),
          
          if (!widget.onlyTheaters && !widget.onlyAnime)
            SliverToBoxAdapter(
              child: _buildPosterRow(
                title: 'Top 10 in India Today',
                items: rows['Top 10 in India Today'] ?? [],
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
      height: 380,
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
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
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  _bg.withValues(alpha: 0.7),
                  _bg,
                ],
                stops: const [0.0, 0.6, 1.0],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: _red,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        m.type.toUpperCase(),
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (m.rating.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'IMDb ${m.rating}',
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amber),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  m.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                    color: _textPri,
                    letterSpacing: -0.5,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  m.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _FButton(
                      label: 'Play Now',
                      icon: Icons.play_arrow,
                      primary: true,
                      onTap: () => _smartPlay(m),
                    ),
                    const SizedBox(width: 12),
                    _FButton(
                      label: '+ Watchlist',
                      icon: isFav ? Icons.check : Icons.add,
                      onTap: () => widget.onDetails(m),
                    ),
                    const SizedBox(width: 12),
                    _FButton(
                      label: 'Info',
                      icon: Icons.info_outline,
                      onTap: () => widget.onDetails(m),
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

  Widget _buildOttDock() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'OTT BRAND STUDIO DOCK',
            style: TextStyle(color: _cyan, fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 1.5),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 80,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _brands.length,
              itemBuilder: (_, i) {
                final b = _brands[i];
                final selected = activeBrandIndex == i;
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _BrandTile(
                    brand: b,
                    selected: selected,
                    onTap: () {
                      setState(() => activeBrandIndex = selected ? null : i);
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
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Continue Watching',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _textPri),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 100,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: items.length,
              itemBuilder: (_, i) {
                final key = items[i];
                final title = widget.resumeTitles[key] ?? key;
                final ms = widget.resumeMs[key] ?? 0;
                
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: SizedBox(
                    width: 240,
                    child: _Card(
                      onTap: () => widget.onPlay(title, key, key),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: _textPri, fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Resume from ${_fmt(ms)}',
                              style: const TextStyle(color: _cyan, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
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
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 20,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Text(
                    title,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _textPri),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 260,
              child: items.isEmpty && loading
                  ? const Center(child: CircularProgressIndicator(color: _cyan, strokeWidth: 2))
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final m = items[i];
                        return PosterCard(
                          meta: m,
                          rank: showRanks && i < 10 ? i + 1 : null,
                          accent: accent,
                          onFocus: () => _onFocusMeta(m),
                          onTap: () => widget.onDetails(m),
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
    final streams = await widget.engine.resolveStreams(m.type, m.id, widget.addons);
    if (!mounted) return;
    
    if (streams.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No streams found. Syncing addons...')),
      );
      return;
    }
    
    final best = streams.first;
    if (best.isDirect) {
      widget.onPlay(m.name, best.url!, m.id);
    } else if (best.infoHash != null) {
      final torr = 'http://127.0.0.1:8090/stream?link=${best.infoHash}&index=1&play';
      widget.onPlay('${m.name} (TorrServer)', torr, m.id);
    }
  }

  String _fmt(int ms) {
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class LiveTvScreen extends StatefulWidget {
  final CatalogEngine engine;
  final void Function(String, String, String, {VoidCallback? onNext}) onPlay;
  
  const LiveTvScreen({super.key, required this.engine, required this.onPlay});
  
  @override
  State<LiveTvScreen> createState() => _LiveTvScreenState();
}

class _LiveTvScreenState extends State<LiveTvScreen> {
  List<Map<String, String>> _channels = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.engine.fetchIptv().then((ch) {
      if (mounted) {
        setState(() {
          _channels = ch;
          _loading = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _cyan));
    }
    
    if (_channels.isEmpty) {
      return const Center(child: Text('No live channels found.', style: TextStyle(color: _muted)));
    }
    
    return ListView.builder(
      padding: const EdgeInsets.all(16), 
      itemCount: _channels.length,
      itemBuilder: (_, i) {
        final c = _channels[i];
        return _Card(
          child: ListTile(
            leading: c['logo']!.isNotEmpty 
                ? Image.network(c['logo']!, width: 40, errorBuilder: (_,__,___) => const Icon(Icons.live_tv, color: _red)) 
                : const Icon(Icons.live_tv, color: _red),
            title: Text(c['name']!, style: const TextStyle(color: _textPri, fontWeight: FontWeight.bold)),
            subtitle: Text(c['group']!, style: const TextStyle(color: _cyan, fontSize: 11)),
            trailing: const Icon(Icons.play_circle_fill, color: Colors.greenAccent),
            onTap: () => widget.onPlay(c['name']!, c['url']!, c['url']!),
          ),
        );
      },
    );
  }
}

class HubScreen extends StatelessWidget {
  final void Function(Meta) onDetails;
  
  const HubScreen({super.key, required this.onDetails});
  
  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(20),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 320, 
        mainAxisExtent: 140, 
        crossAxisSpacing: 16, 
        mainAxisSpacing: 16,
      ),
      itemCount: _brands.length,
      itemBuilder: (_, i) {
        final b = _brands[i];
        return _Card(
          borderColor: b.color.withValues(alpha: 0.5),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft, 
                end: Alignment.bottomRight, 
                colors: [b.color.withValues(alpha: 0.2), _panel],
              ),
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  b.name, 
                  style: TextStyle(color: b.color, fontWeight: FontWeight.w900, fontSize: 22, letterSpacing: 1.5),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Top 10 • Originals', 
                  style: TextStyle(color: _muted, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class MoodScreen extends StatefulWidget {
  final CatalogEngine engine;
  final void Function(Meta) onShowDetails;
  
  const MoodScreen({super.key, required this.engine, required this.onShowDetails});
  
  @override
  State<MoodScreen> createState() => _MoodScreenState();
}

class _MoodScreenState extends State<MoodScreen> {
  static const List<List<String>> _moods = [
    ['Mind-Bending Time Travel', 'Sci-Fi', 'Paradoxes, space odysseys'],
    ['Late Night Horror', 'Horror', 'Hauntings, occult'],
    ['Anime & Animation', 'Animation', 'Top anime, Pixar'],
    ['Dark Crime Thrillers', 'Thriller', 'Psychological, detective'],
    ['Adrenaline Action', 'Action', 'Martial arts, espionage'],
    ['Feel-Good Comedy', 'Comedy', 'Rom-coms, family'],
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
      '$_cinemeta/catalog/movie/imdbRating.json',
    );
    
    if (!mounted) return;
    setState(() {
      _results = items;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'AI MOOD & VIBE', 
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: _cyan),
          ),
        ),
        SizedBox(
          height: 140,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _moods.length,
            itemBuilder: (_, i) {
              final m = _moods[i];
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: 260,
                  child: _Card(
                    onTap: () => _load(m[1], m[0]),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            m[0], 
                            style: const TextStyle(color: _red, fontWeight: FontWeight.bold, fontSize: 16), 
                            maxLines: 1, 
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            m[2], 
                            style: const TextStyle(color: _muted, fontSize: 12), 
                            maxLines: 2, 
                            overflow: TextOverflow.ellipsis,
                          ),
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
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
            child: Row(
              children: [
                Text(
                  'Mood: $_currentLabel', 
                  style: const TextStyle(color: _cyan, fontWeight: FontWeight.bold, fontSize: 18),
                ),
                const Spacer(),
                if (_loading) 
                  const SizedBox(
                    width: 20, 
                    height: 20, 
                    child: CircularProgressIndicator(strokeWidth: 2, color: _cyan),
                  ),
              ],
            ),
          ),
        Expanded(
          child: _results.isEmpty
              ? Center(
                  child: Text(
                    _loading ? '' : 'Select a mood to discover', 
                    style: const TextStyle(color: _muted, fontSize: 16),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 150, 
                    mainAxisExtent: 240, 
                    crossAxisSpacing: 12, 
                    mainAxisSpacing: 12,
                  ),
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
          _targetLabel = 'S${firstEp['season']}E${firstEp['episode']} - ${firstEp['name'] ?? ''}';
        });
        _loadStreams(id);
      }
    }
  }

  Future<void> _loadStreams(String id) async {
    setState(() {
      _loadingStreams = true;
      _streams = [];
    });
    
    final streams = await widget.engine.resolveStreams(widget.meta.type, id, widget.addons);
    
    if (!mounted) return;
    setState(() {
      _streams = streams;
      _loadingStreams = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isFav = widget.watchlist.contains(widget.meta.id);
    
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (_, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.all(24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.meta.name,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: _textPri),
                ),
              ),
              _FButton(
                label: isFav ? 'Saved' : '+ WL',
                primary: isFav,
                onTap: () => widget.onToggleWatchlist(widget.meta.id),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            widget.meta.description,
            style: const TextStyle(color: _muted, fontSize: 14, height: 1.5),
          ),
          const Divider(color: Colors.white12, height: 32),
          
          if (widget.meta.type == 'series' && _grouped.isNotEmpty) ...[
            const Text(
              'Seasons',
              style: TextStyle(color: _cyan, fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: (_grouped.keys.toList()..sort()).map((s) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _FButton(
                      label: 'Season $s',
                      active: _season == s,
                      onTap: () => setState(() => _season = s),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 100,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: (_grouped[_season] ?? []).length,
                itemBuilder: (_, i) {
                  final ep = _grouped[_season]![i];
                  final epId = (ep['id'] ?? '').toString();
                  final watched = widget.watchedEpisodes.contains(epId);
                  final selected = _targetId == epId;
                  
                  return Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: SizedBox(
                      width: 220,
                      child: _Card(
                        selected: selected,
                        onTap: () async {
                          await widget.onMarkWatched(epId);
                          setState(() {
                            _targetId = epId;
                            _targetLabel = 'S${ep['season']}E${ep['episode']} - ${ep['name'] ?? ''}';
                          });
                          _loadStreams(epId);
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    'EP ${ep['episode']}',
                                    style: const TextStyle(color: _red, fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                  const Spacer(),
                                  if (watched)
                                    const Icon(Icons.check_circle, color: Colors.greenAccent, size: 16),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                (ep['name'] ?? '').toString(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: _textPri, fontSize: 13, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const Divider(color: Colors.white12, height: 32),
          ],
          
          if (widget.meta.type == 'series' && _loadingMeta)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator(color: _cyan)),
            ),
            
          if (_streams.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _FButton(
                label: 'Auto-Play Best Stream',
                icon: Icons.bolt,
                primary: true,
                onTap: () => _playStream(_streams.first),
              ),
            ),
            
          Text(
            'Available Streams: $_targetLabel',
            style: const TextStyle(color: _cyan, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 12),
          
          if (_loadingStreams)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text('Scanning sources...', style: TextStyle(color: _cyan, fontSize: 14)),
              ),
            )
          else if (_streams.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No streams found. Ensure Torrentio/MediaFusion addons are active.',
                style: TextStyle(color: _muted, fontSize: 14),
              ),
            )
          else
            ..._streams.take(30).map((s) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _Card(
                    onTap: () => _playStream(s),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: _cyan.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  s.badge,
                                  style: const TextStyle(color: _cyan, fontSize: 11, fontWeight: FontWeight.bold),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                s.addonName,
                                style: const TextStyle(color: _red, fontSize: 13, fontWeight: FontWeight.bold),
                              ),
                              const Spacer(),
                              if (s.isDirect)
                                const Text(
                                  'PLAY ▶',
                                  style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
                                )
                              else if (s.isTorrent)
                                const Text(
                                  'VLC/EXTERNAL ▶',
                                  style: TextStyle(color: Colors.amberAccent, fontSize: 12, fontWeight: FontWeight.bold),
                                ),
                            ],
                          ),
                          if (s.title.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              s.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: _textPri, fontSize: 13),
                            ),
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
      widget.onPlay('${widget.meta.name} - $_targetLabel', s.url!, _targetId);
    } else if (s.isTorrent) {
      final magnet = 'magnet:?xt=urn:btih:${s.infoHash}&dn=${Uri.encodeComponent(widget.meta.name)}';
      launchUrl(Uri.parse(magnet), mode: LaunchMode.externalApplication);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Opening External Player (VLC/MX)...')),
      );
    }
  }
}

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
  }

  Future<void> _savePos() async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    
    final ms = c.value.position.inMilliseconds;
    if ((ms - _lastSaved).abs() < 4000) return;
    
    _lastSaved = ms;
    await widget.onSave(ms);
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
    } else if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
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
    await launchUrl(Uri.parse(widget.url), mode: LaunchMode.externalApplication);
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
                        const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 56),
                        const SizedBox(height: 16),
                        const Text(
                          'Playback failed. Stream may use unsupported codec (MKV/AC3).',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white, fontSize: 16),
                        ),
                        const SizedBox(height: 24),
                        _FButton(
                          label: 'Open in External Player (VLC)',
                          primary: true,
                          icon: Icons.open_in_new,
                          onTap: _external,
                        ),
                      ],
                    ),
                  ),
                )
              else
                const Center(child: CircularProgressIndicator(color: _cyan)),
              
              if (_hud && !_error)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(24, 60, 24, 24),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter, 
                        end: Alignment.bottomCenter, 
                        colors: [Colors.transparent, Colors.black.withValues(alpha: 0.95)],
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: _textPri, fontWeight: FontWeight.bold, fontSize: 18),
                        ),
                        const SizedBox(height: 12),
                        if (_initialized && _c != null)
                          VideoProgressIndicator(
                            _c!,
                            allowScrubbing: true,
                            colors: const VideoProgressColors(
                              playedColor: _red,
                              bufferedColor: Colors.white30,
                              backgroundColor: Colors.white10,
                            ),
                          ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _RoundButton(
                              icon: Icons.replay_10,
                              onTap: () => _seek(-15),
                            ),
                            const SizedBox(width: 24),
                            _RoundButton(
                              icon: (_c?.value.isPlaying ?? false) ? Icons.pause : Icons.play_arrow,
                              size: 64,
                              isPrimary: true,
                              onTap: _togglePlay,
                            ),
                            const SizedBox(width: 24),
                            _RoundButton(
                              icon: Icons.forward_10,
                              onTap: () => _seek(15),
                            ),
                            if (widget.onNext != null) ...[
                              const SizedBox(width: 24),
                              _RoundButton(
                                icon: Icons.skip_next,
                                onTap: () => widget.onNext!(),
                              ),
                            ],
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

class SearchModal extends StatefulWidget {
  final CatalogEngine engine;
  final void Function(Meta) onShowDetails;
  
  const SearchModal({
    super.key, 
    required this.engine, 
    required this.onShowDetails,
  });
  
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
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Universal Search', 
                style: TextStyle(color: _cyan, fontWeight: FontWeight.bold, fontSize: 20),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _ctrl,
                style: const TextStyle(color: _textPri, fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Type movie or series name...',
                  hintStyle: const TextStyle(color: _muted),
                  filled: true,
                  fillColor: _bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12), 
                    borderSide: BorderSide.none,
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.search, color: _cyan), 
                    onPressed: _doSearch,
                  ),
                ),
                onSubmitted: (_) => _doSearch(),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _searching
                    ? const Center(child: CircularProgressIndicator(color: _cyan))
                    : _results.isEmpty
                        ? const Center(child: Text('Search for anything', style: TextStyle(color: _muted)))
                        : ListView.builder(
                            itemCount: _results.length,
                            itemBuilder: (_, i) => ListTile(
                              title: Text(
                                _results[i].name, 
                                style: const TextStyle(color: _textPri, fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text(
                                '${_results[i].type.toUpperCase()} · ${_results[i].year}', 
                                style: const TextStyle(color: _muted),
                              ),
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

class _AddonPage extends StatelessWidget {
  final List<ManagedAddon> addons;
  
  const _AddonPage({required this.addons});
  
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Addon Manager', 
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: _cyan),
        ),
        const SizedBox(height: 8),
        const Text(
          'Self-healing engine. Dead addons removed automatically.', 
          style: TextStyle(color: _muted, fontSize: 13),
        ),
        const SizedBox(height: 16),
        ...addons.map((a) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _Card(
                child: ListTile(
                  title: Text(
                    a.name, 
                    style: const TextStyle(color: _textPri, fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  subtitle: Text(
                    a.baseUrl, 
                    maxLines: 1, 
                    overflow: TextOverflow.ellipsis, 
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                ),
              ),
            )),
      ],
    );
  }
}

class _TuiBody extends StatelessWidget {
  final int tab;
  final int addons;
  final int watchlist;
  final VoidCallback onExit;
  
  const _TuiBody({
    required this.tab, 
    required this.addons, 
    required this.watchlist, 
    required this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A0B2E),
      padding: const EdgeInsets.all(24),
      child: DefaultTextStyle(
        style: const TextStyle(fontFamily: 'monospace', color: Color(0xFF00FFCC), fontSize: 14),
        child: ListView(
          children: [
            const Text('MOVIEBOX-TUI v0.1.27 -> v5.5'),
            const Text('===================================='),
            Text('YEAR      : ${DateTime.now().year}'),
            Text('ADDONS    : $addons installed'),
            Text('WATCHLIST : $watchlist titles'),
            Text('TAB       : $tab'),
            const Text('===================================='),
            const Text('> SYSTEM ONLINE'),
            const Text('> RESOLVER: TORRSERVE + TORRENTIO'),
            const Text('> ADDONS: SELF-HEALING ACTIVE'),
            const SizedBox(height: 24),
            _FButton(
              label: '[Q] EXIT TUI MODE', 
              primary: true, 
              onTap: onExit,
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final bool isPrimary;
  final VoidCallback onTap;

  const _RoundButton({
    required this.icon,
    this.size = 48,
    this.isPrimary = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(size / 2),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: isPrimary ? _cyan : Colors.white12,
          shape: BoxShape.circle,
          border: Border.all(color: isPrimary ? _cyan : Colors.white30),
        ),
        child: Icon(
          icon,
          color: isPrimary ? Colors.black : Colors.white,
          size: size * 0.5,
        ),
      ),
    );
  }
}

class _FButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final bool active;
  final bool primary;
  final VoidCallback onTap;

  const _FButton({
    required this.label,
    this.icon,
    this.active = false,
    this.primary = false,
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
        : (widget.primary
            ? _red.withValues(alpha: 0.8)
            : (widget.active ? _cyan.withValues(alpha: 0.15) : _panel));
            
    final fg = _focused
        ? Colors.white
        : (widget.primary
            ? Colors.white
            : (widget.active ? _cyan : _textPri));
            
    final border = _focused
        ? _cyan
        : (widget.primary
            ? _red
            : (widget.active ? _cyan : Colors.white24));

    return InkWell(
      onFocusChange: (f) => setState(() => _focused = f),
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border, width: _focused ? 2 : 1),
          boxShadow: _focused
              ? [BoxShadow(color: _cyan.withValues(alpha: 0.5), blurRadius: 12)]
              : [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, size: 18, color: fg),
              const SizedBox(width: 8),
            ],
            Text(
              widget.label,
              style: TextStyle(
                color: fg,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
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
        : (widget.selected
            ? _red
            : (widget.borderColor ?? Colors.white12));

    return InkWell(
      onFocusChange: (f) => setState(() => _focused = f),
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: border,
            width: _focused || widget.selected ? 2 : 1,
          ),
          boxShadow: _focused
              ? [BoxShadow(color: _cyan.withValues(alpha: 0.3), blurRadius: 16)]
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
      padding: const EdgeInsets.only(right: 12),
      child: InkWell(
        onFocusChange: (f) {
          setState(() => _focused = f);
          if (f) widget.onFocus();
        },
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedScale(
          duration: const Duration(milliseconds: 150),
          scale: _focused ? 1.05 : 1.0,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 150,
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _focused ? _cyan : Colors.transparent,
                width: 3,
              ),
              boxShadow: _focused
                  ? [BoxShadow(color: _cyan.withValues(alpha: 0.4), blurRadius: 20)]
                  : [const BoxShadow(color: Colors.black54, blurRadius: 8)],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  widget.meta.poster.isNotEmpty
                      ? Image.network(
                          widget.meta.poster,
                          fit: BoxFit.cover,
                          cacheWidth: 300,
                          errorBuilder: (_, __, ___) => _fallback(),
                        )
                      : _fallback(),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.8),
                        ],
                        stops: const [0.6, 1.0],
                      ),
                    ),
                  ),
                  if (widget.rank != null)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: widget.accent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '#${widget.rank}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: Text(
                      widget.meta.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fallback() => Container(
        color: _panel,
        child: const Icon(Icons.movie, color: _muted, size: 40),
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
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 180,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              widget.brand.color.withValues(alpha: active ? 0.4 : 0.1),
              _panel,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active ? widget.brand.color : Colors.white12,
            width: active ? 2 : 1,
          ),
          boxShadow: _focused
              ? [BoxShadow(color: widget.brand.color.withValues(alpha: 0.4), blurRadius: 16)]
              : [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              widget.brand.name,
              style: TextStyle(
                color: active ? Colors.white : widget.brand.color,
                fontWeight: FontWeight.w900,
                fontSize: 16,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.brand.fallbackGenre,
              style: const TextStyle(
                color: _muted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
