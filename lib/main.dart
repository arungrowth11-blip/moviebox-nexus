// MovieBox Nexus OS — hardened source baseline
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'player_screen.dart';

const _bg = Color(0xFF0A0B10);
const _panel = Color(0xFF141724);
const _cyan = Color(0xFF00E5FF);
const _red = Color(0xFFE50914);
const _muted = Color(0xFF9E9EA7);
const _textPri = Color(0xFFFFFFFF);

const _cinemeta = 'https://v3-cinemeta.strem.io';
const _streamingCatalogs =
    'https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club';

/// Public, community-maintained IPTV-org lists. These are free-to-air
/// candidates; individual broadcasters may still geoblock or take streams offline.
const List<MapEntry<String, String>> liveTvPlaylistSources = [
  // Health-ranked sources first; raw lists remain available as fallback candidates.
  MapEntry(
    'Verified India',
    'https://dearbulut.github.io/iptv/playlists/country/in.m3u',
  ),
  MapEntry(
    'Verified Global',
    'https://dearbulut.github.io/iptv/playlists/online.m3u',
  ),
  // Curated free-to-air sources only; paid/encrypted services are excluded.
  MapEntry(
    'Curated Free TV',
    'https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8',
  ),
  MapEntry('India', 'https://iptv-org.github.io/iptv/countries/in.m3u'),
  MapEntry('Hindi', 'https://iptv-org.github.io/iptv/languages/hin.m3u'),
  MapEntry('Bengali', 'https://iptv-org.github.io/iptv/languages/ben.m3u'),
  MapEntry('Punjabi', 'https://iptv-org.github.io/iptv/languages/pan.m3u'),
  MapEntry('Tamil', 'https://iptv-org.github.io/iptv/languages/tam.m3u'),
  MapEntry('Telugu', 'https://iptv-org.github.io/iptv/languages/tel.m3u'),
  MapEntry('Malayalam', 'https://iptv-org.github.io/iptv/languages/mal.m3u'),
  MapEntry('South Asia', 'https://iptv-org.github.io/iptv/regions/sas.m3u'),
  MapEntry('Asia', 'https://iptv-org.github.io/iptv/regions/asia.m3u'),
  MapEntry('Asia Pacific', 'https://iptv-org.github.io/iptv/regions/apac.m3u'),
  MapEntry('News', 'https://iptv-org.github.io/iptv/categories/news.m3u'),
  MapEntry('Public', 'https://iptv-org.github.io/iptv/categories/public.m3u'),
  MapEntry(
    'Entertainment',
    'https://iptv-org.github.io/iptv/categories/entertainment.m3u',
  ),
  MapEntry('Movies', 'https://iptv-org.github.io/iptv/categories/movies.m3u'),
  MapEntry('Sports', 'https://iptv-org.github.io/iptv/categories/sports.m3u'),
  MapEntry('Kids', 'https://iptv-org.github.io/iptv/categories/kids.m3u'),
];

class LiveTvSourceProbeResult {
  final Map<String, String>? working;
  final List<Map<String, String>> failed;

  const LiveTvSourceProbeResult({required this.working, required this.failed});
}

/// Persistent per-feed quarantine. Failed URLs are hidden temporarily, then
/// actively re-probed after expiry; the registry survives app restarts.
class LiveTvHealthRegistry {
  static const String _storageKey = 'moviebox_live_tv_health_v1';
  static const int _maxEntries = 128;
  final Map<String, _LiveTvHealthEntry> _entries =
      <String, _LiveTvHealthEntry>{};

  Future<void> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      _entries.clear();
      for (final item in decoded.entries) {
        final url = item.key.toString();
        if (url.isEmpty || item.value is! Map) continue;
        final record = Map<String, dynamic>.from(item.value as Map);
        final untilMs = record['untilMs'];
        final channelValue = record['channel'];
        if (untilMs is! num || channelValue is! Map) continue;
        final channel = <String, String>{
          for (final field in channelValue.entries)
            field.key.toString(): field.value.toString(),
          'url': url,
        };
        _entries[url] = _LiveTvHealthEntry(
          channel,
          DateTime.fromMillisecondsSinceEpoch(untilMs.toInt()),
        );
      }
      _trim();
    } catch (_) {
      _entries.clear();
    }
  }

  bool isQuarantined(String url) => _entries.containsKey(url);

  List<Map<String, String>> dueForRecheck({DateTime? now, int limit = 6}) {
    final current = now ?? DateTime.now();
    final due =
        _entries.values
            .where((entry) => !entry.unhealthyUntil.isAfter(current))
            .toList()
          ..sort((a, b) => a.unhealthyUntil.compareTo(b.unhealthyUntil));
    return due
        .take(limit)
        .map((entry) => Map<String, String>.from(entry.channel))
        .toList();
  }

  Future<void> quarantine(
    Iterable<Map<String, String>> channels, {
    Duration duration = const Duration(minutes: 20),
  }) async {
    final until = DateTime.now().add(duration);
    for (final channel in channels) {
      final url = (channel['url'] ?? '').trim();
      if (url.isEmpty) continue;
      _entries[url] = _LiveTvHealthEntry(
        Map<String, String>.from(channel),
        until,
      );
    }
    _trim();
    await _persist();
  }

  Future<void> markHealthy(String url) async {
    if (_entries.remove(url) != null) await _persist();
  }

  void _trim() {
    if (_entries.length <= _maxEntries) return;
    final oldest = _entries.entries.toList()
      ..sort(
        (a, b) => a.value.unhealthyUntil.compareTo(b.value.unhealthyUntil),
      );
    for (final entry in oldest.take(_entries.length - _maxEntries)) {
      _entries.remove(entry.key);
    }
  }

  Future<void> _persist() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final payload = <String, dynamic>{
        for (final entry in _entries.entries)
          entry.key: <String, dynamic>{
            'untilMs': entry.value.unhealthyUntil.millisecondsSinceEpoch,
            'channel': entry.value.channel,
          },
      };
      await preferences.setString(_storageKey, jsonEncode(payload));
    } catch (_) {
      // Health checks must never prevent Live TV playback if storage is full
      // or temporarily unavailable.
    }
  }
}

class _LiveTvHealthEntry {
  final Map<String, String> channel;
  final DateTime unhealthyUntil;

  const _LiveTvHealthEntry(this.channel, this.unhealthyUntil);
}

bool shouldUseCachedLiveTvData({
  required bool cacheExists,
  required int parsedChannelCount,
  required bool forceRefresh,
}) => cacheExists && parsedChannelCount > 0 && !forceRefresh;

/// Parses common M3U playlists, tolerating CRLF, BOM, blank lines and
/// EXTVLCOPT/EXTGRP directives between EXTINF and the stream URL.
List<Map<String, String>> parseM3uPlaylist(String body) {
  final channels = <Map<String, String>>[];
  var name = '';
  var id = '';
  var logo = '';
  var group = '';
  var country = '';
  var language = '';
  var userAgent = '';
  var referrer = '';
  var healthScore = '';
  final lines = body.replaceFirst('\uFEFF', '').split(RegExp(r'\r?\n'));
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTINF:')) {
      final comma = line.lastIndexOf(',');
      name = comma >= 0 && comma + 1 < line.length
          ? line.substring(comma + 1).trim()
          : '';
      id = RegExp(r'tvg-id="([^"]*)"').firstMatch(line)?.group(1) ?? '';
      logo = RegExp(r'tvg-logo="([^"]*)"').firstMatch(line)?.group(1) ?? '';
      group = RegExp(r'group-title="([^"]*)"').firstMatch(line)?.group(1) ?? '';
      country =
          RegExp(r'tvg-country="([^"]*)"').firstMatch(line)?.group(1) ?? '';
      language =
          RegExp(r'tvg-language="([^"]*)"').firstMatch(line)?.group(1) ?? '';
      healthScore =
          RegExp(r'nexus-score="([0-9.]+)"').firstMatch(line)?.group(1) ?? '';
      continue;
    }
    if (line.startsWith('#EXTVLCOPT:')) {
      final option = line.substring('#EXTVLCOPT:'.length);
      final separator = option.indexOf('=');
      if (separator > 0) {
        final key = option.substring(0, separator).trim().toLowerCase();
        final value = option.substring(separator + 1).trim();
        if (key == 'http-user-agent' && value.isNotEmpty) userAgent = value;
        if ((key == 'http-referrer' || key == 'http-referer') &&
            value.isNotEmpty) {
          referrer = value;
        }
      }
      continue;
    }
    if (line.startsWith('#EXTHTTP:')) {
      try {
        final decoded = jsonDecode(line.substring('#EXTHTTP:'.length).trim());
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final key = entry.key.toString().toLowerCase();
            final value = entry.value.toString().trim();
            if (value.isEmpty) continue;
            if (key == 'user-agent') userAgent = value;
            if (key == 'referer' || key == 'referrer') referrer = value;
          }
        }
      } catch (_) {}
      continue;
    }
    if (line.startsWith('#')) continue;
    final uri = Uri.tryParse(line);
    if (uri == null ||
        !uri.hasScheme ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      continue;
    }
    final lowerGroup = group.toLowerCase();
    final lowerName = name.toLowerCase();
    final restricted =
        lowerGroup.contains('xxx') ||
        lowerGroup.contains('adult') ||
        lowerName.contains('xxx') ||
        lowerName.contains('18+') ||
        lowerName.contains('adult only');
    if (name.isNotEmpty && !restricted) {
      channels.add({
        'id': normalizeIptvChannelId(id),
        'sourceId': id,
        'name': name,
        'url': uri.toString(),
        'logo': logo,
        'group': group.isEmpty ? 'Other' : group,
        'country': countryCodeFromChannelId(id, explicitCountry: country),
        'countryRaw': country.trim(),
        'language': language,
        'userAgent': userAgent,
        'referrer': referrer,
        if (healthScore.isNotEmpty) 'healthScore': healthScore,
      });
    }
    name = '';
    id = '';
    logo = '';
    group = '';
    country = '';
    language = '';
    userAgent = '';
    referrer = '';
    healthScore = '';
  }
  return channels;
}

/// Combines independently maintained public M3U feeds without discarding
/// alternate URLs for the same channel. Exact duplicate stream URLs are removed.
List<Map<String, String>> mergeLiveTvPlaylists(
  Map<String, String> sourceBodies,
) {
  final byUrl = <String, Map<String, String>>{};
  for (final source in sourceBodies.entries) {
    for (final channel in parseM3uPlaylist(source.value)) {
      final url = (channel['url'] ?? '').trim();
      if (url.isEmpty) continue;
      final incoming = <String, String>{...channel, 'source': source.key};
      final existing = byUrl[url];
      if (existing == null) {
        byUrl[url] = incoming;
        continue;
      }
      final existingScore =
          double.tryParse(existing['healthScore'] ?? '') ?? -1;
      final incomingScore =
          double.tryParse(incoming['healthScore'] ?? '') ?? -1;
      if (incomingScore > existingScore) {
        byUrl[url] = <String, String>{...existing, ...incoming};
      }
    }
  }
  return byUrl.values.toList();
}

/// Extracts a two-letter broadcast country code from an explicit field or
/// the iptv-org channel ID suffix (for example, BBCNews.uk -> UK).
/// IPTV channel ID suffixes are sometimes country TLDs rather than ISO codes.
String normalizeCountryCode(String raw) {
  final code = raw.trim().toUpperCase();
  // IPTV sources often use these two-letter placeholders for unassigned data.
  if (code == 'XX' || code == 'ZZ' || code == 'UN') return '';
  const aliases = <String, String>{'UK': 'GB', 'EL': 'GR'};
  return aliases[code] ?? code;
}

/// iptv-org playlist IDs can contain a quality/feed suffix (e.g. BBCOne.uk@HD).
/// The channels API uses the base ID (BBCOne.uk), so normalize before joining.
String normalizeIptvChannelId(String rawId) =>
    rawId.trim().split('@').first.trim();

String countryCodeFromChannelId(String id, {String explicitCountry = ''}) {
  final explicit = normalizeCountryCode(explicitCountry);
  if (RegExp(r'^[A-Z]{2}$').hasMatch(explicit)) return explicit;
  final baseId = normalizeIptvChannelId(id);
  final match = RegExp(
    r'\.([a-z]{2})$',
    caseSensitive: false,
  ).firstMatch(baseId);
  return match == null ? '' : normalizeCountryCode(match.group(1)!);
}

String _normalizeChannelName(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// Secondary join key for playlist display names carrying quality/language
/// suffixes, e.g. "3ABN English (720p)" -> "3abn". Exact names are always
/// preferred; canonical collisions are marked ambiguous rather than guessed.
String _normalizeChannelMatchName(String value) {
  var normalized =
      _normalizeChannelName(value.replaceAll(RegExp(r'\([^)]*\)'), ' '))
          .replaceAll(
            RegExp(
              r'\b(?:2160p?|1080p?|720p?|576p?|480p?|360p?|4k|8k|hd|fhd|uhd|sd|hevc|h265|h264|avc|aac)\b',
            ),
            ' ',
          )
          .trim();
  const trailingLanguages = <String>{
    'english',
    'french',
    'hindi',
    'arabic',
    'russian',
    'ukrainian',
    'spanish',
    'portuguese',
    'german',
    'italian',
    'turkish',
    'chinese',
    'korean',
    'japanese',
    'bengali',
    'urdu',
    'tamil',
    'telugu',
    'punjabi',
    'malayalam',
  };
  while (normalized.isNotEmpty) {
    final lastWord = normalized.split(' ').last;
    if (!trailingLanguages.contains(lastWord)) break;
    normalized = normalized
        .substring(0, normalized.length - lastWord.length)
        .trim();
  }
  return normalized;
}

String _countryCodeFromName(String value, Map<String, dynamic> countries) {
  final normalized = _normalizeChannelName(value);
  if (normalized.isEmpty) return '';
  final upper = normalizeCountryCode(value);
  if (RegExp(r'^[A-Z]{2}$').hasMatch(upper)) return upper;
  for (final entry in countries.entries) {
    if (entry.value is! Map) continue;
    final item = Map<String, dynamic>.from(entry.value as Map);
    if (_normalizeChannelName((item['name'] ?? '').toString()) == normalized) {
      return entry.key.toString().toUpperCase();
    }
  }
  return '';
}

/// Pure channel filter: kept separate so country/category behavior can be tested
/// without rendering the Live TV screen.
List<Map<String, String>> filterLiveTvChannels(
  List<Map<String, String>> channels, {
  String countryCode = '*',
  String categoryId = '*',
  String query = '',
}) {
  final q = query.trim().toLowerCase();
  return channels
      .where((channel) {
        final categories = (channel['categoryIds'] ?? '').split('|');
        final searchable = [
          channel['name'] ?? '',
          channel['group'] ?? '',
          channel['countryName'] ?? '',
          channel['countryCode'] ?? '',
          channel['language'] ?? '',
          channel['categoryNames'] ?? '',
        ].join(' ').toLowerCase();
        return (countryCode == '*' ||
                (channel['countryCode'] ?? '') == countryCode) &&
            (categoryId == '*' || categories.contains(categoryId)) &&
            (q.isEmpty || searchable.contains(q));
      })
      .toList(growable: false);
}

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
  final Map<String, String> headers;
  final int? seeders;
  final int? fileIdx;
  final List<String> trackers;

  StreamLink({
    this.url,
    this.infoHash,
    this.title = '',
    this.addonName = '',
    this.badge = '',
    this.headers = const <String, String>{},
    this.seeders,
    this.fileIdx,
    this.trackers = const <String>[],
  });

  bool get isDirect => url != null && url!.startsWith('http');
  bool get isTorrent => infoHash != null;

  int get score {
    final s = '$title ${url ?? ''}'.toLowerCase();
    var quality = 0;
    if (s.contains('2160') || s.contains('4k')) {
      quality += 40;
    } else if (s.contains('1080')) {
      quality += 30;
    } else if (s.contains('720')) {
      quality += 15;
    }
    if (s.contains('hindi') || s.contains('dual')) quality += 20;

    if (isDirect) {
      // Direct adaptive HTTP is always ahead of a P2P magnet. HLS and DASH
      // get an extra preference because the player can adapt bitrate.
      final adaptive = s.contains('.m3u8') || s.contains('hls')
          ? 2000
          : s.contains('.mpd') || s.contains('dash')
          ? 1500
          : 500;
      return 100000 + adaptive + quality;
    }

    // When no direct source exists, swarm size is a stronger predictor of
    // startup than advertised resolution. Cap it to keep corrupted metadata
    // from overwhelming the ranking.
    return (seeders ?? 0).clamp(0, 500).toInt() * 100 + quality;
  }
}

class OttBrand {
  final String name;
  final String shortId;
  final String fallbackGenre;
  final Color color;
  final bool hasCatalog;

  const OttBrand({
    required this.name,
    required this.shortId,
    required this.color,
    required this.fallbackGenre,
    this.hasCatalog = false,
  });
}

// Home-screen shortcuts are limited to catalogs declared by the default
// Streaming Catalogs instance. OTT Hubs discovers any additional configured
// provider catalogs dynamically from each addon's manifest.
const List<OttBrand> _brands = [
  OttBrand(
    name: 'NETFLIX',
    shortId: 'nfx',
    color: Color(0xFFE50914),
    fallbackGenre: 'Thriller',
    hasCatalog: true,
  ),
  OttBrand(
    name: 'PRIME VIDEO',
    shortId: 'amp',
    color: Color(0xFF00A8E1),
    fallbackGenre: 'Action',
    hasCatalog: true,
  ),
  OttBrand(
    name: 'DISNEY+ HOTSTAR',
    shortId: 'dnp',
    color: Color(0xFF113CCF),
    fallbackGenre: 'Adventure',
    hasCatalog: true,
  ),
  OttBrand(
    name: 'HBO MAX',
    shortId: 'hbm',
    color: Color(0xFF991EEB),
    fallbackGenre: 'Drama',
    hasCatalog: true,
  ),
  OttBrand(
    name: 'APPLE TV+',
    shortId: 'atp',
    color: Color(0xFFE2E8F0),
    fallbackGenre: 'Sci-Fi',
    hasCatalog: true,
  ),
  OttBrand(
    name: 'SONYLIV',
    shortId: 'sonyliv',
    color: Color(0xFF0057B7),
    fallbackGenre: 'Comedy',
  ),
  OttBrand(
    name: 'ZEE5',
    shortId: 'zee',
    color: Color(0xFF8230C6),
    fallbackGenre: 'Mystery',
  ),
  OttBrand(
    name: 'JIOHOTSTAR',
    shortId: 'jhs',
    color: Color(0xFFE5005C),
    fallbackGenre: 'Action',
  ),
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
    'Streaming Catalogs':
        'https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club/manifest.json',
    'IndiaStreams': 'https://indiastreams.rdata.in/manifest.json',
  };

  Future<bool> isAlive(String manifestUrl) async {
    try {
      final r = await _client
          .get(Uri.parse(manifestUrl))
          .timeout(const Duration(seconds: 6));
      return r.statusCode == 200 && jsonDecode(r.body) is Map;
    } catch (_) {
      return false;
    }
  }

  Future<List<ManagedAddon>> sync(
    List<ManagedAddon> current,
    SharedPreferences prefs,
  ) async {
    // Keep configured addons even when temporarily unreachable. Network failures
    // must never silently erase a user's configuration.
    final merged = <String, ManagedAddon>{};
    for (final addon in current) {
      if (addon.manifestUrl.trim().isNotEmpty)
        merged[addon.manifestUrl] = addon;
    }
    final disabled = (prefs.getStringList('disabled_addons') ?? <String>[])
        .toSet();
    for (final entry in _seedAddons.entries) {
      if (!disabled.contains(entry.value)) {
        merged.putIfAbsent(
          entry.value,
          () => ManagedAddon(
            name: entry.key,
            manifestUrl: entry.value,
            baseUrl: entry.value.replaceFirst(RegExp(r'/manifest\.json$'), ''),
          ),
        );
      }
    }
    final retained = merged.values.toList();
    await prefs.setStringList(
      'managed_addons',
      retained.map((a) => jsonEncode(a.toJson())).toList(),
    );
    return retained;
  }

  void close() => _client.close();
}

class AddonCatalog {
  final String addonName;
  final String catalogName;
  final String id;
  final String baseUrl;
  final Set<String> types;

  AddonCatalog({
    required this.addonName,
    required this.catalogName,
    required this.id,
    required this.baseUrl,
    Set<String>? types,
  }) : types = types ?? <String>{};
}

class CatalogEngine {
  final http.Client _client = http.Client();

  Future<List<Meta>> fetchRow(
    String primary,
    String? fallback, {
    String type = 'movie',
  }) async {
    for (final u in [primary, if (fallback != null) fallback]) {
      try {
        final r = await _client
            .get(Uri.parse(u))
            .timeout(const Duration(seconds: 8));
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

  /// Reads catalog IDs and media types from an addon's own Stremio manifest.
  /// Catalog IDs are addon-defined; never infer them from provider display names.
  Future<List<AddonCatalog>> fetchAddonCatalogs(ManagedAddon addon) async {
    try {
      final response = await _client
          .get(Uri.parse(addon.manifestUrl))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return <AddonCatalog>[];
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return <AddonCatalog>[];
      final manifest = Map<String, dynamic>.from(decoded);
      final resources = manifest['resources'];
      if (resources is List &&
          !resources.any(
            (resource) =>
                resource == 'catalog' ||
                (resource is Map &&
                    (resource['name'] == 'catalog' ||
                        resource['resource'] == 'catalog')),
          )) {
        return <AddonCatalog>[];
      }
      final declaredCatalogs = manifest['catalogs'];
      if (declaredCatalogs is! List) return <AddonCatalog>[];

      final grouped = <String, AddonCatalog>{};
      for (final raw in declaredCatalogs.whereType<Map>()) {
        final item = Map<String, dynamic>.from(raw);
        final type = (item['type'] ?? '').toString().toLowerCase();
        final id = (item['id'] ?? '').toString().trim();
        if (!{'movie', 'series'}.contains(type) || id.isEmpty) continue;
        final name = (item['name'] ?? id).toString().trim();
        final key = '${addon.baseUrl}|$id|$name';
        final catalog = grouped.putIfAbsent(
          key,
          () => AddonCatalog(
            addonName: addon.name,
            catalogName: name.isEmpty ? id : name,
            id: id,
            baseUrl: addon.baseUrl,
          ),
        );
        catalog.types.add(type);
      }
      return grouped.values.toList();
    } catch (_) {
      return <AddonCatalog>[];
    }
  }

  Future<List<Meta>> search(String query) async {
    if (query.trim().isEmpty) return [];
    final q = Uri.encodeComponent(query.trim());
    final out = <Meta>[];

    for (final type in ['movie', 'series']) {
      try {
        final r = await _client
            .get(Uri.parse('$_cinemeta/catalog/$type/top/search=$q.json'))
            .timeout(const Duration(seconds: 6));
        if (r.statusCode == 200) {
          final metas = (jsonDecode(r.body) as Map)['metas'];
          if (metas is List) {
            out.addAll(
              metas.whereType<Map>().map(
                (m) => Meta.fromJson(Map<String, dynamic>.from(m)),
              ),
            );
          }
        }
      } catch (_) {}
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> fetchEpisodes(String id) async {
    try {
      final r = await _client
          .get(Uri.parse('$_cinemeta/meta/series/$id.json'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode == 200) {
        final videos = (jsonDecode(r.body) as Map)['meta']?['videos'];
        if (videos is List) {
          return videos
              .whereType<Map>()
              .map((v) => Map<String, dynamic>.from(v))
              .toList();
        }
      }
    } catch (_) {}
    return [];
  }

  Future<List<StreamLink>> resolveStreams(
    String type,
    String id,
    List<ManagedAddon> addons, {
    void Function(List<StreamLink> streams)? onUpdate,
  }) async {
    final eligible = addons.where((addon) {
      final name = addon.name.toLowerCase();
      return !name.contains('cinemeta') && !name.contains('streaming catalogs');
    }).toList();

    final accumulated = <String, StreamLink>{};
    List<StreamLink> ranked() {
      final streams = accumulated.values.toList()
        ..sort((a, b) => b.score.compareTo(a.score));
      return streams;
    }

    Future<List<StreamLink>> resolveAddon(ManagedAddon addon) async {
      try {
        final endpoint =
            '${addon.baseUrl}/stream/$type/${Uri.encodeComponent(id)}.json';
        final response = await _client
            .get(Uri.parse(endpoint))
            .timeout(const Duration(seconds: 5));
        if (response.statusCode != 200) return <StreamLink>[];
        final decoded = jsonDecode(response.body);
        final rawStreams = decoded is Map ? decoded['streams'] : null;
        if (rawStreams is! List) return <StreamLink>[];
        return rawStreams
            .whereType<Map>()
            .map((raw) {
              final item = Map<String, dynamic>.from(raw);
              final rawUrl = (item['url'] ?? '').toString().trim();
              var rawHash = (item['infoHash'] ?? '').toString().trim();
              final uri = Uri.tryParse(rawUrl);
              if (rawHash.isEmpty && uri?.scheme == 'magnet') {
                final xt = uri?.queryParameters['xt'] ?? '';
                rawHash = xt
                    .replaceFirst(
                      RegExp(r'^urn:btih:', caseSensitive: false),
                      '',
                    )
                    .trim();
              }
              rawHash = rawHash.replaceFirst(
                RegExp(r'^urn:btih:', caseSensitive: false),
                '',
              );
              final rawFileIdx = item['fileIdx'];
              final parsedFileIdx = rawFileIdx is num
                  ? rawFileIdx.toInt()
                  : int.tryParse(rawFileIdx?.toString() ?? '');
              final fileIdx = parsedFileIdx != null && parsedFileIdx >= 0
                  ? parsedFileIdx
                  : null;
              final directUrl =
                  uri != null &&
                      uri.hasScheme &&
                      {'http', 'https'}.contains(uri.scheme) &&
                      uri.host.isNotEmpty
                  ? uri.toString()
                  : null;
              // Preserve tracker hints supplied by Stremio magnets and the
              // addon's "tracker:" sources. Dropping these can strand a valid
              // swarm even though the infoHash itself is correct.
              final trackerCandidates = <String>[
                if (uri?.scheme == 'magnet')
                  ...(uri!.queryParametersAll['tr'] ?? const <String>[]),
                if (item['sources'] is List)
                  ...(item['sources'] as List)
                      .map((value) => value.toString().trim())
                      .where(
                        (value) => value.toLowerCase().startsWith('tracker:'),
                      )
                      .map((value) => value.substring('tracker:'.length)),
              ];
              final trackerUrls = trackerCandidates
                  .map((value) => value.trim())
                  .where((value) {
                    final tracker = Uri.tryParse(value);
                    return tracker != null &&
                        tracker.host.isNotEmpty &&
                        {'udp', 'http', 'https'}.contains(tracker.scheme);
                  })
                  .toSet()
                  .take(16)
                  .toList(growable: false);
              if (directUrl == null && rawHash.isEmpty) return null;
              final title =
                  (item['title'] ??
                          item['description'] ??
                          item['name'] ??
                          'Stream')
                      .toString()
                      .replaceAll('\n', ' ')
                      .trim();
              final behaviorHints = item['behaviorHints'];
              final rawSeeders =
                  item['seeders'] ??
                  (behaviorHints is Map ? behaviorHints['seeders'] : null);
              final titleSeeders = RegExp(
                r'(?:👤|👥)\s*(\d{1,5})',
              ).firstMatch(title);
              final seeders = rawSeeders is num
                  ? rawSeeders.toInt()
                  : int.tryParse(rawSeeders?.toString() ?? '') ??
                        int.tryParse(titleSeeders?.group(1) ?? '');
              final proxyHeaders = behaviorHints is Map
                  ? behaviorHints['proxyHeaders']
                  : null;
              final requestHeaders = proxyHeaders is Map
                  ? proxyHeaders['request']
                  : null;
              final rawHeaders = requestHeaders is Map
                  ? requestHeaders
                  : (item['headers'] is Map
                        ? item['headers']
                        : const <String, dynamic>{});
              final streamHeaders = <String, String>{};
              if (rawHeaders is Map) {
                for (final entry in rawHeaders.entries) {
                  final key = entry.key.toString().trim();
                  final value = entry.value.toString().trim();
                  if (key.isNotEmpty && value.isNotEmpty)
                    streamHeaders[key] = value;
                }
              }
              final probe = '$title ${directUrl ?? ''}'.toLowerCase();
              final badge = probe.contains('2160') || probe.contains('4k')
                  ? '4K UHD'
                  : probe.contains('1080')
                  ? '1080p FHD'
                  : probe.contains('.m3u8') || probe.contains('hls')
                  ? 'HLS'
                  : directUrl != null
                  ? 'DIRECT'
                  : 'TORRENT';
              return StreamLink(
                url: directUrl,
                infoHash: rawHash.isEmpty ? null : rawHash,
                title: title,
                addonName: addon.name,
                badge: badge,
                headers: streamHeaders,
                seeders: seeders,
                fileIdx: fileIdx,
                trackers: trackerUrls,
              );
            })
            .whereType<StreamLink>()
            .toList();
      } catch (_) {
        // One addon timing out or returning malformed JSON must not block the others.
        return <StreamLink>[];
      }
    }

    // Publish each provider's response as soon as it arrives. The user can
    // start a stream from the first usable provider without waiting for the
    // slowest add-on in the parallel fan-out.
    await Future.wait(
      eligible.map((addon) async {
        final streams = await resolveAddon(addon);
        for (final stream in streams) {
          final key =
              stream.url ??
              stream.infoHash ??
              '${stream.addonName}:${stream.title}';
          accumulated.putIfAbsent(key, () => stream);
        }
        if (streams.isNotEmpty) onUpdate?.call(ranked());
      }),
    );

    return ranked();
  }

  /// Fetch the community-maintained best public tracker list. It is
  /// cached for 24 hours so tracker discovery cannot stall every playback start.
  Future<List<String>> fetchSupplementalTrackers({
    bool forceRefresh = false,
  }) async {
    final support = await getApplicationSupportDirectory();
    final cacheFile = File(support.path + '/moviebox-trackers-best.txt');
    try {
      if (!forceRefresh && await cacheFile.exists()) {
        final modified = await cacheFile.lastModified();
        if (DateTime.now().difference(modified) < const Duration(hours: 24)) {
          final cached = _parsePublicTrackers(await cacheFile.readAsString());
          if (cached.isNotEmpty) return cached;
        }
      }
    } catch (_) {}

    const urls = <String>[
      'https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt',
      'https://ngosang.github.io/trackerslist/trackers_best.txt',
      'https://cdn.jsdelivr.net/gh/ngosang/trackerslist@master/trackers_best.txt',
    ];
    for (final url in urls) {
      try {
        final response = await _client
            .get(
              Uri.parse(url),
              headers: const {
                'User-Agent': 'MovieBoxNexus/1.2',
                'Accept': 'text/plain',
              },
            )
            .timeout(const Duration(seconds: 5));
        if (response.statusCode != 200) continue;
        final trackers = _parsePublicTrackers(response.body);
        if (trackers.isEmpty) continue;
        try {
          await cacheFile.parent.create(recursive: true);
          await cacheFile.writeAsString(trackers.join('\n'), flush: true);
        } catch (_) {}
        return trackers;
      } catch (_) {}
    }
    return <String>[];
  }

  List<String> _parsePublicTrackers(String body) {
    final trackers = <String>[];
    final seen = <String>{};
    for (final raw in body.split(RegExp(r'\r?\n'))) {
      final value = raw.trim();
      if (value.isEmpty || value.startsWith('#')) continue;
      final uri = Uri.tryParse(value);
      if (uri == null ||
          uri.host.isEmpty ||
          !{'udp', 'http', 'https'}.contains(uri.scheme) ||
          !seen.add(uri.toString())) {
        continue;
      }
      trackers.add(uri.toString());
      if (trackers.length >= 24) break;
    }
    return trackers;
  }

  /// Bounded GET-range probe for direct URLs. It reads at most the first
  /// response chunk and rejects expired/error HTML endpoints before Smart Play
  /// hands the URL to Media3. Provider headers are preserved.
  Future<bool> probeDirectStream(StreamLink stream) async {
    final rawUrl = stream.url;
    if (!stream.isDirect || rawUrl == null) return false;
    try {
      final request = http.Request('GET', Uri.parse(rawUrl))
        ..headers.addAll(stream.headers)
        ..headers['Range'] = 'bytes=0-1023'
        ..headers.putIfAbsent('Accept', () => '*/*');
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 3));
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.stream.listen((_) {}).cancel();
        return false;
      }
      final contentType = (response.headers['content-type'] ?? '')
          .toLowerCase();
      if (contentType.contains('text/html')) {
        await response.stream.listen((_) {}).cancel();
        return false;
      }
      final firstChunk = await response.stream.first.timeout(
        const Duration(seconds: 2),
        onTimeout: () => <int>[],
      );
      if (firstChunk.isEmpty) return false;
      final prefix = utf8
          .decode(firstChunk.take(512).toList(), allowMalformed: true)
          .trimLeft()
          .toLowerCase();
      if (prefix.startsWith('<!doctype html') ||
          prefix.startsWith('<html') ||
          prefix.startsWith('{"error')) {
        return false;
      }
      if (contentType.contains('mpegurl') ||
          contentType.contains('dash+xml') ||
          contentType.contains('mp2t') ||
          contentType.contains('octet-stream') ||
          contentType.startsWith('video/') ||
          prefix.startsWith('#extm3u') ||
          prefix.contains('<mpd')) {
        return true;
      }
      // Some providers use generic content types but still honor byte ranges.
      return response.statusCode == 206 || response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Match alternate public feeds by official channel ID first, then exact normalized name.
  List<Map<String, String>> liveTvAlternates(
    Map<String, String> selected,
    List<Map<String, String>> allChannels,
  ) {
    final selectedUrl = selected['url'] ?? '';
    final id = (selected['id'] ?? '').trim();
    final name = _normalizeChannelName(selected['name'] ?? '');
    final idMatches = id.isEmpty
        ? <Map<String, String>>[]
        : allChannels.where((item) => (item['id'] ?? '').trim() == id).toList();
    final matches = idMatches.isNotEmpty
        ? idMatches
        : allChannels
              .where(
                (item) =>
                    name.isNotEmpty &&
                    _normalizeChannelName(item['name'] ?? '') == name,
              )
              .toList();
    final ordered = <Map<String, String>>[
      selected,
      ...matches.where((item) => (item['url'] ?? '') != selectedUrl),
    ];
    final seen = <String>{};
    return ordered
        .where((item) {
          final url = item['url'] ?? '';
          return url.isNotEmpty && seen.add(url);
        })
        .take(8)
        .toList();
  }

  Future<List<int>> _readResponsePrefix(
    Stream<List<int>> stream, {
    int maxBytes = 64 * 1024,
  }) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      final remaining = maxBytes - bytes.length;
      if (remaining <= 0) break;
      bytes.addAll(chunk.take(remaining));
      if (bytes.length >= maxBytes) break;
    }
    return bytes;
  }

  /// Validate a Live TV URL at the media level. For HLS this follows a master
  /// playlist to a media playlist, then fetches the first actual segment.
  /// A reachable #EXTM3U manifest alone is not treated as a playable channel.
  Future<bool> _probeLiveTvUrl(
    Uri uri, {
    int depth = 0,
    Map<String, String> headers = const <String, String>{},
  }) async {
    if (depth > 2 || !{'http', 'https'}.contains(uri.scheme)) return false;
    try {
      final request = http.Request('GET', uri)
        ..headers.addAll(headers)
        ..headers['Range'] = 'bytes=0-65535'
        ..headers['Accept'] = '*/*'
        ..headers.putIfAbsent('User-Agent', () => 'MovieBoxNexus/1.2');
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.stream.listen((_) {}).cancel();
        return false;
      }
      final contentType = (response.headers['content-type'] ?? '')
          .toLowerCase();
      if (contentType.contains('text/html')) {
        await response.stream.listen((_) {}).cancel();
        return false;
      }
      final prefix = await _readResponsePrefix(
        response.stream,
      ).timeout(const Duration(seconds: 5));
      if (prefix.isEmpty) return false;

      final text = utf8
          .decode(prefix, allowMalformed: true)
          .replaceFirst('\uFEFF', '')
          .trimLeft();
      final lower = text.toLowerCase();
      if (lower.startsWith('<!doctype html') ||
          lower.startsWith('<html') ||
          lower.startsWith('{"error')) {
        return false;
      }

      final isHls =
          lower.startsWith('#extm3u') || contentType.contains('mpegurl');
      if (!isHls) return true;

      final finalUri = response.request?.url ?? uri;
      final lines = text
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .toList();

      // Master playlists identify video variants using STREAM-INF. Follow the
      // first declared variant before checking its media segment.
      String? variant;
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].toUpperCase().startsWith('#EXT-X-STREAM-INF')) continue;
        for (var j = i + 1; j < lines.length; j++) {
          if (lines[j].isEmpty || lines[j].startsWith('#')) continue;
          variant = lines[j];
          break;
        }
        if (variant != null) break;
      }
      if (variant != null) {
        return await _probeLiveTvUrl(
          finalUri.resolve(variant),
          depth: depth + 1,
          headers: headers,
        );
      }

      // Media playlists contain segment URIs as non-comment lines. For
      // low-latency HLS, fall back to the first PART URI when needed.
      String? segment;
      for (final line in lines) {
        if (line.isNotEmpty && !line.startsWith('#')) {
          segment = line;
          break;
        }
      }
      if (segment == null) {
        for (final line in lines) {
          if (!line.toUpperCase().startsWith('#EXT-X-PART:')) continue;
          final match = RegExp(r'URI="([^"]+)"').firstMatch(line);
          if (match != null) {
            segment = match.group(1);
            break;
          }
        }
      }
      if (segment == null) return false;
      return await _probeLiveTvUrl(
        finalUri.resolve(segment),
        depth: depth + 1,
        headers: headers,
      );
    } catch (_) {
      return false;
    }
  }

  Future<bool> _probeLiveTvSource(Map<String, String> item) async {
    final rawUrl = (item['url'] ?? '').trim();
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasAuthority) return false;
    final headers = <String, String>{
      if ((item['userAgent'] ?? '').isNotEmpty)
        'User-Agent': item['userAgent']!,
      if ((item['referrer'] ?? '').isNotEmpty) 'Referer': item['referrer']!,
    };
    return _probeLiveTvUrl(uri, headers: headers);
  }

  /// Expose one feed probe for the quarantine revalidation worker.
  Future<bool> probeLiveTvSource(Map<String, String> item) =>
      _probeLiveTvSource(item);

  /// Probe up to eight same-channel feeds concurrently. Return both the first
  /// playable source and every failed candidate so the UI can quarantine dead
  /// alternates even when another feed succeeds.
  Future<LiveTvSourceProbeResult> probeLiveTvSources(
    List<Map<String, String>> candidates,
  ) async {
    final bounded = candidates.take(8).toList();
    if (bounded.isEmpty) {
      return const LiveTvSourceProbeResult(
        working: null,
        failed: <Map<String, String>>[],
      );
    }
    final checks = await Future.wait(bounded.map(_probeLiveTvSource));
    final index = checks.indexWhere((isWorking) => isWorking);
    return LiveTvSourceProbeResult(
      working: index < 0 ? null : bounded[index],
      failed: <Map<String, String>>[
        for (var i = 0; i < bounded.length; i++)
          if (!checks[i]) bounded[i],
      ],
    );
  }

  Future<Map<String, String>?> firstWorkingLiveTvSource(
    List<Map<String, String>> candidates,
  ) async => (await probeLiveTvSources(candidates)).working;

  void close() => _client.close();

  /// Cached public IPTV playlist enriched with structured country/category data.
  Future<List<Map<String, String>>> fetchIptv({
    bool forceRefresh = false,
  }) async {
    final support = await getApplicationSupportDirectory();
    final cacheFile = File(support.path + '/live_tv_multi_source_v3.m3u');
    String? cachedBody;
    DateTime? cacheTime;
    try {
      if (await cacheFile.exists()) {
        cachedBody = await cacheFile.readAsString();
        cacheTime = await cacheFile.lastModified();
      }
    } catch (_) {}
    final hasCache = cachedBody != null && cachedBody.isNotEmpty;
    final cachedChannels = hasCache
        ? _uniqueLiveChannels(parseM3uPlaylist(cachedBody))
        : <Map<String, String>>[];
    final isFresh =
        cacheTime != null &&
        DateTime.now().difference(cacheTime) < const Duration(hours: 12);
    if (shouldUseCachedLiveTvData(
      cacheExists: hasCache,
      parsedChannelCount: cachedChannels.length,
      forceRefresh: forceRefresh,
    )) {
      if (!isFresh) unawaited(_refreshIptvPlaylist(cacheFile));
      final metadata = await _loadLiveTvMetadata();
      return enrichLiveTvChannels(cachedChannels, metadata);
    }
    final metadataFuture = _loadLiveTvMetadata(forceRefresh: forceRefresh);
    final channels = await _refreshIptvPlaylist(cacheFile);
    if (channels.isNotEmpty) {
      return enrichLiveTvChannels(channels, await metadataFuture);
    }
    // Preserve a previously parsed list during an upstream outage, never an empty cache.
    if (cachedChannels.isNotEmpty) {
      final metadata = await _loadLiveTvMetadata();
      return enrichLiveTvChannels(cachedChannels, metadata);
    }
    return <Map<String, String>>[];
  }

  Future<List<Map<String, String>>> _refreshIptvPlaylist(File cacheFile) async {
    // Smaller country, language, region and category lists replace the giant index.
    // Each request has its own timeout, so one slow source cannot block the others.
    final responses = await Future.wait<MapEntry<String, String>?>(
      liveTvPlaylistSources.map((source) async {
        try {
          final response = await _client
              .get(
                Uri.parse(source.value),
                headers: const {
                  'User-Agent': 'MovieBoxNexus/1.1',
                  'Accept': '*/*',
                },
              )
              .timeout(const Duration(seconds: 12));
          if (response.statusCode != 200 || response.body.trim().isEmpty)
            return null;
          return MapEntry(source.key, response.body);
        } catch (_) {
          return null;
        }
      }),
    );
    final sourceBodies = <String, String>{
      for (final item in responses.whereType<MapEntry<String, String>>())
        item.key: item.value,
    };
    final merged = mergeLiveTvPlaylists(sourceBodies);
    if (merged.isEmpty) return <Map<String, String>>[];
    try {
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsString(
        sourceBodies.values.join('\n'),
        flush: true,
      );
    } catch (_) {}
    return _uniqueLiveChannels(merged);
  }

  Future<Map<String, dynamic>> _readCachedLiveTvMetadata(File file) async {
    try {
      if (!await file.exists()) return <String, dynamic>{};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['schemaVersion'] >= 2) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _loadLiveTvMetadata({
    bool forceRefresh = false,
  }) async {
    final support = await getApplicationSupportDirectory();
    final metadataFile = File(support.path + '/live_tv_metadata.json');
    try {
      if (!forceRefresh && await metadataFile.exists()) {
        final modified = await metadataFile.lastModified();
        if (DateTime.now().difference(modified) < const Duration(days: 7)) {
          final decoded = jsonDecode(await metadataFile.readAsString());
          // Version the cache so old channel-ID-only indexes (without unique
          // name fallback) are rebuilt immediately after an app upgrade.
          if (decoded is Map && decoded['schemaVersion'] >= 2) {
            final cached = Map<String, dynamic>.from(decoded);
            final cachedChannels = cached['channels'];
            final cachedCountries = cached['countries'];
            // Do not treat a previously cached empty/partial response as fresh:
            // that can freeze every channel as "Country not tagged" for 7 days.
            if (cachedChannels is Map &&
                cachedChannels.isNotEmpty &&
                cachedCountries is Map &&
                cachedCountries.isNotEmpty) {
              return cached;
            }
          }
        }
      }
    } catch (_) {}
    Future<dynamic> readJson(String url) async {
      try {
        final response = await _client
            .get(
              Uri.parse(url),
              headers: const {
                'User-Agent': 'MovieBoxNexus/1.0',
                'Accept': 'application/json',
              },
            )
            .timeout(const Duration(seconds: 18));
        if (response.statusCode != 200) return null;
        return jsonDecode(response.body);
      } catch (_) {
        return null;
      }
    }

    final values = await Future.wait<dynamic>([
      readJson('https://iptv-org.github.io/api/channels.json'),
      readJson('https://iptv-org.github.io/api/countries.json'),
      readJson('https://iptv-org.github.io/api/categories.json'),
    ]);
    final channelIndex = <String, dynamic>{};
    final channelNameIndex = <String, dynamic>{};
    if (values[0] is List) {
      for (final raw in values[0] as List) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final id = normalizeIptvChannelId((item['id'] ?? '').toString());
        if (id.isEmpty || item['is_nsfw'] == true) continue;
        final metadata = <String, dynamic>{
          'country': (item['country'] ?? '').toString().toUpperCase(),
          'categories': item['categories'] is List
              ? (item['categories'] as List).map((v) => v.toString()).toList()
              : <String>[],
        };
        channelIndex[id] = metadata;
        final names = <String>[
          (item['name'] ?? '').toString(),
          if (item['alt_names'] is List)
            ...(item['alt_names'] as List).map((v) => v.toString()),
        ];
        // Collect exact/canonical aliases for this one channel first.
        // Otherwise a primary name and its own language-qualified alt_name can
        // collide with each other and be incorrectly marked ambiguous.
        final keysForChannel = <String>{};
        for (final name in names.toSet()) {
          keysForChannel.add(_normalizeChannelName(name));
          keysForChannel.add(_normalizeChannelMatchName(name));
        }
        keysForChannel.removeWhere((key) => key.isEmpty);
        for (final key in keysForChannel) {
          if (channelNameIndex.containsKey(key)) {
            channelNameIndex[key] = null; // ambiguous across distinct channels
          } else {
            channelNameIndex[key] = metadata;
          }
        }
      }
    }
    final countryIndex = <String, dynamic>{};
    if (values[1] is List) {
      for (final raw in values[1] as List) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final code = (item['code'] ?? '').toString().toUpperCase();
        if (code.isNotEmpty) {
          countryIndex[code] = {
            'name': (item['name'] ?? code).toString(),
            'flag': (item['flag'] ?? '').toString(),
          };
        }
      }
    }
    final categoryIndex = <String, dynamic>{};
    if (values[2] is List) {
      for (final raw in values[2] as List) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final id = (item['id'] ?? '').toString().trim();
        if (id.isNotEmpty) categoryIndex[id] = (item['name'] ?? id).toString();
      }
    }
    // Merge stale data when an upstream JSON endpoint is temporarily
    // unavailable. Never overwrite a good index with an empty response.
    final cached = await _readCachedLiveTvMetadata(metadataFile);
    final cachedChannels = cached['channels'];
    final cachedNames = cached['channelNames'];
    final cachedCountries = cached['countries'];
    final cachedCategories = cached['categories'];
    if (channelIndex.isEmpty && cachedChannels is Map) {
      channelIndex.addAll(Map<String, dynamic>.from(cachedChannels));
    }
    if (channelNameIndex.isEmpty && cachedNames is Map) {
      channelNameIndex.addAll(Map<String, dynamic>.from(cachedNames));
    }
    if (countryIndex.isEmpty && cachedCountries is Map) {
      countryIndex.addAll(Map<String, dynamic>.from(cachedCountries));
    }
    if (categoryIndex.isEmpty && cachedCategories is Map) {
      categoryIndex.addAll(Map<String, dynamic>.from(cachedCategories));
    }
    final metadata = <String, dynamic>{
      'schemaVersion': 3,
      'channels': channelIndex,
      'channelNames': channelNameIndex,
      'countries': countryIndex,
      'categories': categoryIndex,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    // A network outage must not replace a valid cache with empty metadata.
    if (channelIndex.isNotEmpty && countryIndex.isNotEmpty) {
      try {
        await metadataFile.parent.create(recursive: true);
        await metadataFile.writeAsString(jsonEncode(metadata), flush: true);
      } catch (_) {}
    }
    return metadata;
  }

  List<Map<String, String>> enrichLiveTvChannels(
    List<Map<String, String>> channels,
    Map<String, dynamic> metadata,
  ) {
    final channelIndex = metadata['channels'] is Map
        ? Map<String, dynamic>.from(metadata['channels'] as Map)
        : <String, dynamic>{};
    final countryIndex = metadata['countries'] is Map
        ? Map<String, dynamic>.from(metadata['countries'] as Map)
        : <String, dynamic>{};
    final categoryIndex = metadata['categories'] is Map
        ? Map<String, dynamic>.from(metadata['categories'] as Map)
        : <String, dynamic>{};
    final channelNameIndex = metadata['channelNames'] is Map
        ? Map<String, dynamic>.from(metadata['channelNames'] as Map)
        : <String, dynamic>{};
    return channels.map((channel) {
      final id = normalizeIptvChannelId(channel['id'] ?? '');
      final directMeta = channelIndex[id];
      final exactNameKey = _normalizeChannelName(channel['name'] ?? '');
      final canonicalNameKey = _normalizeChannelMatchName(
        channel['name'] ?? '',
      );
      final matchedByName = channelNameIndex.containsKey(exactNameKey)
          ? channelNameIndex[exactNameKey]
          : channelNameIndex[canonicalNameKey];
      // Official playlist IDs do not always match the iptv-org channel
      // index. Use a unique normalized channel-name match as a fallback even
      // when a non-empty source ID exists; ambiguous names remain excluded.
      final channelMetaRaw = directMeta is Map ? directMeta : matchedByName;
      final channelMeta = channelMetaRaw is Map
          ? Map<String, dynamic>.from(channelMetaRaw)
          : <String, dynamic>{};
      final rawCountry =
          (channelMeta['country'] ??
                  channel['countryRaw'] ??
                  channel['country'] ??
                  '')
              .toString()
              .trim();
      final idCountry = countryCodeFromChannelId(
        id,
        explicitCountry: rawCountry,
      );
      final resolvedCountryCode = idCountry.isNotEmpty
          ? idCountry
          : _countryCodeFromName(rawCountry, countryIndex);
      // Keep a selectable, stable key for an explicitly named country even
      // when the public country index is temporarily unavailable.
      final countryCode = resolvedCountryCode.isNotEmpty
          ? resolvedCountryCode
          : rawCountry.isNotEmpty
          ? 'NAME:${_normalizeChannelName(rawCountry).replaceAll(' ', '-')}'
          : '';
      final countryMeta = countryIndex[countryCode] is Map
          ? Map<String, dynamic>.from(countryIndex[countryCode] as Map)
          : <String, dynamic>{};
      final rawCategories = channelMeta['categories'];
      final categoryIds = rawCategories is List
          ? rawCategories
                .map((v) => v.toString())
                .where((v) => v.isNotEmpty)
                .toList()
          : <String>[];
      if (categoryIds.isEmpty && (channel['group'] ?? '').isNotEmpty) {
        categoryIds.add(
          (channel['group'] ?? 'Other').toLowerCase().replaceAll(
            RegExp(r'[^a-z0-9]+'),
            '-',
          ),
        );
      }
      final categoryNames = categoryIds
          .map(
            (id) => (categoryIndex[id] ?? id.replaceAll('-', ' ')).toString(),
          )
          .toList();
      return <String, String>{
        ...channel,
        'country': countryCode,
        'countryCode': countryCode,
        'countryName':
            (countryMeta['name'] ??
                    (countryCode.startsWith('NAME:')
                        ? rawCountry
                        : (countryCode.isEmpty
                              ? 'Country not tagged'
                              : countryCode)))
                .toString(),
        'countryFlag': (countryMeta['flag'] ?? '').toString(),
        'categoryIds': categoryIds.join('|'),
        'categoryNames': categoryNames.join(', '),
      };
    }).toList();
  }

  List<Map<String, String>> _uniqueLiveChannels(
    List<Map<String, String>> channels,
  ) {
    final unique = <String, Map<String, String>>{};
    for (final channel in channels) {
      final url = channel['url'] ?? '';
      if (url.isNotEmpty) unique.putIfAbsent(url, () => channel);
    }
    return unique.values.toList();
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

/// Embedded torrent bridge backed by FrostWire jlibtorrent on Android.
/// The native side exposes a loopback HTTP byte-range stream to the in-app player.
class EmbeddedTorrentService {
  EmbeddedTorrentService._();
  static final EmbeddedTorrentService instance = EmbeddedTorrentService._();
  static const MethodChannel _channel = MethodChannel('moviebox_nexus/torrent');

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    await _channel.invokeMethod<void>('initialize');
    _initialized = true;
  }

  Future<String> startPlayback(
    String infoHash, {
    String title = '',
    int? fileIdx,
    List<String> trackers = const <String>[],
  }) async {
    final hash = infoHash.trim();
    if (!RegExp(r'^(?:[a-fA-F0-9]{40}|[a-zA-Z2-7]{32})$').hasMatch(hash)) {
      throw FormatException('Invalid torrent infoHash.');
    }
    final url = await _channel.invokeMethod<String>(
      'startPlayback',
      <String, Object>{
        'infoHash': hash,
        'title': title.trim().isEmpty ? 'MovieBox Nexus stream' : title.trim(),
        if (fileIdx != null) 'fileIdx': fileIdx,
        if (trackers.isNotEmpty) 'trackers': trackers.take(24).toList(),
      },
    );
    final uri = Uri.tryParse(url ?? '');
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        uri.port <= 0) {
      throw StateError(
        'Built-in torrent engine returned an invalid loopback URL.',
      );
    }
    return uri.toString();
  }

  Future<Map<String, dynamic>> getStatus() async {
    final snapshot = await _channel.invokeMapMethod<String, dynamic>(
      'getStatus',
    );
    return snapshot ?? <String, dynamic>{};
  }

  void dispose() {
    _initialized = false;
    unawaited(
      _channel.invokeMethod<void>('stopPlayback').catchError((Object error) {
        debugPrint('MovieBox torrent stop failed: $error');
      }),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Native torrent startup is lazy; catalog navigation must not wait for it.
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
  final Set<int> _visitedTabs = <int>{0};
  HttpServer? _server;
  String remoteUrl = '';
  String _remoteToken = '';

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

      try {
        final raw = p.getString('resume_ms');
        if (raw != null && raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            decoded.forEach(
              (k, v) =>
                  resumeMs[k.toString()] = int.tryParse(v.toString()) ?? 0,
            );
          }
        }
        final titles = jsonDecode(p.getString('resume_titles') ?? '{}');
        if (titles is Map) {
          titles.forEach((k, v) => resumeTitles[k.toString()] = v.toString());
        }
      } catch (_) {
        // Ignore malformed local resume cache; the app remains usable.
      }

      final cached = p.getStringList('managed_addons') ?? [];
      for (final item in cached) {
        try {
          final decoded = jsonDecode(item);
          if (decoded is Map)
            managedAddons.add(
              ManagedAddon.fromJson(Map<String, dynamic>.from(decoded)),
            );
        } catch (_) {
          // Skip only the damaged entry, not the entire addon list.
        }
      }
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('watchlist', watchlist.toList());
    await p.setStringList('watched_eps', watchedEpisodes.toList());
    await p.setString('resume_ms', jsonEncode(resumeMs));
    await p.setString('resume_titles', jsonEncode(resumeTitles));
    await p.setStringList(
      'managed_addons',
      managedAddons.map((a) => jsonEncode(a.toJson())).toList(),
    );
  }

  Future<void> _sync() async {
    final p = await SharedPreferences.getInstance();
    final synced = await addonManager.sync(managedAddons, p);
    if (mounted) setState(() => managedAddons = synced);
  }

  Future<void> _addAddon(String manifestUrl) async {
    final uri = Uri.tryParse(manifestUrl.trim());
    if (uri == null ||
        !uri.hasScheme ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const FormatException(
        'Valid HTTP/HTTPS manifest URL enter karein.',
      );
    }
    final response = await http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw Exception('Manifest HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map)
      throw const FormatException('Manifest JSON object nahi hai.');
    final manifest = Map<String, dynamic>.from(decoded);
    final name = (manifest['name'] ?? manifest['id'] ?? uri.host).toString();
    final path = uri.path;
    final basePath = path.endsWith('/manifest.json')
        ? path.substring(0, path.length - '/manifest.json'.length)
        : path.substring(
            0,
            path.lastIndexOf('/') < 0 ? 0 : path.lastIndexOf('/'),
          );
    final baseUri = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: basePath,
    );
    final addon = ManagedAddon(
      name: name,
      manifestUrl: uri.toString(),
      baseUrl: baseUri.toString().replaceFirst(RegExp(r'/$'), ''),
    );
    if (managedAddons.any((a) => a.manifestUrl == addon.manifestUrl)) {
      throw const FormatException('Ye addon pehle se installed hai.');
    }
    final prefs = await SharedPreferences.getInstance();
    final disabled = (prefs.getStringList('disabled_addons') ?? <String>[])
        .toSet();
    disabled.remove(addon.manifestUrl);
    await prefs.setStringList('disabled_addons', disabled.toList());
    if (!mounted) return;
    setState(() => managedAddons.add(addon));
    await _save();
  }

  Future<void> _removeAddon(ManagedAddon addon) async {
    final prefs = await SharedPreferences.getInstance();
    if (AddonManager._seedAddons.values.contains(addon.manifestUrl)) {
      final disabled = (prefs.getStringList('disabled_addons') ?? <String>[])
          .toSet();
      disabled.add(addon.manifestUrl);
      await prefs.setStringList('disabled_addons', disabled.toList());
    }
    if (!mounted) return;
    setState(
      () =>
          managedAddons.removeWhere((a) => a.manifestUrl == addon.manifestUrl),
    );
    await _save();
  }

  static const String _remoteHtml = r'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>MovieBox Nexus Remote</title><style>
body{margin:0;padding:24px;background:#0a0b10;color:#fff;font:16px Arial;max-width:560px;margin:auto}
main{background:#141724;border:1px solid #263348;border-radius:18px;padding:22px}
h1{font-size:22px;color:#00e5ff}input,button{box-sizing:border-box;width:100%;padding:14px;margin:9px 0;border-radius:10px;border:1px solid #34445c;background:#0a0b10;color:white}
button{background:#b30d1a;border:0;font-weight:bold;cursor:pointer}.hint{color:#9e9ea7;font-size:13px}
</style></head><body><main><h1>MovieBox Nexus Remote</h1>
<p class="hint">Phone and TV must be connected to the same Wi-Fi network.</p>
<form id="play"><label>Stream URL</label><input id="url" type="url" placeholder="https://example.com/video.m3u8" required><button type="submit">Play on TV</button></form>
<p id="status" class="hint">Remote connected.</p></main>
<script>
const token='__TOKEN__';
document.getElementById('play').addEventListener('submit',async e=>{e.preventDefault();const status=document.getElementById('status');status.textContent='Sending…';try{const r=await fetch('/api/play?token='+encodeURIComponent(token),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({url:document.getElementById('url').value})});status.textContent=await r.text();}catch(err){status.textContent='Connection failed: '+err;}});
</script></body></html>''';

  Future<void> _startRemote() async {
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 8765);
      if (!mounted) {
        await server.close(force: true);
        return;
      }
      _server = server;
      String ip = '127.0.0.1';
      final nets = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final n in nets) {
        for (final a in n.addresses) {
          if (!a.isLoopback) {
            ip = a.address;
            break;
          }
        }
      }

      final random = Random.secure();
      _remoteToken = base64Url
          .encode(List<int>.generate(24, (_) => random.nextInt(256)))
          .replaceAll('=', '');
      remoteUrl = 'http://$ip:8765/?token=$_remoteToken';
      if (mounted) setState(() {});

      server.listen((req) async {
        try {
          final suppliedToken =
              req.uri.queryParameters['token'] ??
              req.headers.value('x-moviebox-token') ??
              '';
          if (suppliedToken != _remoteToken || _remoteToken.isEmpty) {
            req.response.statusCode = HttpStatus.forbidden;
            req.response.write('Forbidden');
            await req.response.close();
            return;
          }
          if (req.method == 'GET' && req.uri.path == '/') {
            req.response.headers.contentType = ContentType.html;
            req.response.write(
              _remoteHtml.replaceAll('__TOKEN__', _remoteToken),
            );
          } else if (req.method == 'POST' && req.uri.path == '/api/play') {
            final body = await utf8.decoder.bind(req).join();
            final decoded = jsonDecode(body);
            final url = decoded is Map
                ? (decoded['url'] ?? '').toString().trim()
                : '';
            final target = Uri.tryParse(url);
            if (target == null ||
                !target.hasScheme ||
                !{'http', 'https'}.contains(target.scheme) ||
                target.host.isEmpty) {
              req.response.statusCode = HttpStatus.badRequest;
              req.response.write('Valid HTTP(S) stream URL required');
            } else {
              if (mounted) _pushPlayer('Phone Beam', url, url);
              req.response.write('Playback request accepted');
            }
          } else {
            req.response.statusCode = HttpStatus.notFound;
            req.response.write('Not found');
          }
          await req.response.close();
        } catch (e) {
          req.response.statusCode = HttpStatus.badRequest;
          req.response.write('Invalid request: $e');
          await req.response.close();
        }
      });
    } catch (_) {}
  }

  void _pushPlayer(
    String title,
    String url,
    String key, {
    VoidCallback? onNext,
    Map<String, String>? headers,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
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
          headers: headers ?? const <String, String>{},
        ),
      ),
    );
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
          setState(
            () => watchlist.contains(id)
                ? watchlist.remove(id)
                : watchlist.add(id),
          );
          await _save();
        },
        onMarkWatched: (id) async {
          setState(() => watchedEpisodes.add(id));
          await _save();
        },
        onPlay: (title, url, key, {onNext, headers}) {
          Navigator.pop(context);
          _pushPlayer(
            title,
            url,
            key,
            onNext: onNext,
            headers: headers ?? const <String, String>{},
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _server?.close(force: true);
    EmbeddedTorrentService.instance.dispose();
    engine.close();
    addonManager.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      'Home',
      'Theaters',
      'Anime',
      'Mood',
      'Live TV',
      'OTT Hubs',
      'Addons',
    ];
    const tabIcons = <IconData>[
      Icons.home_rounded,
      Icons.theaters_rounded,
      Icons.animation_rounded,
      Icons.mood_rounded,
      Icons.live_tv_rounded,
      Icons.apps_rounded,
      Icons.extension_rounded,
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: _red,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(width: 12),
                    _FButton(
                      label: 'Search',
                      icon: Icons.search,
                      onTap: () => showDialog(
                        context: context,
                        builder: (_) => SearchModal(
                          engine: engine,
                          onShowDetails: _openDetails,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _FButton(label: 'Sync', icon: Icons.refresh, onTap: _sync),
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
                              ? QrImageView(
                                  data: remoteUrl,
                                  size: 200,
                                  backgroundColor: Colors.white,
                                )
                              : const Text('Starting...'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth >= 360) {
                    return Row(
                      children: [
                        NavigationRail(
                          minWidth: 76,
                          backgroundColor: _panel,
                          selectedIndex: tab,
                          labelType: NavigationRailLabelType.all,
                          onDestinationSelected: (index) => setState(() {
                            tab = index;
                            _visitedTabs.add(index);
                          }),
                          destinations: [
                            for (var i = 0; i < tabs.length; i++)
                              NavigationRailDestination(
                                icon: Icon(tabIcons[i], size: 20),
                                selectedIcon: Icon(
                                  tabIcons[i],
                                  size: 22,
                                  color: _cyan,
                                ),
                                label: Text(
                                  tabs[i],
                                  style: const TextStyle(fontSize: 10),
                                ),
                              ),
                          ],
                        ),
                        const VerticalDivider(width: 1, color: Colors.white12),
                        Expanded(child: _buildBody()),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      SizedBox(
                        height: 52,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (var i = 0; i < tabs.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: _FButton(
                                  label: tabs[i],
                                  active: tab == i,
                                  onTap: () => setState(() {
                                    tab = i;
                                    _visitedTabs.add(i);
                                  }),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Expanded(child: _buildBody()),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    // Preserve already visited tab state while lazily mounting screens.
    return IndexedStack(
      index: tab,
      sizing: StackFit.expand,
      children: List<Widget>.generate(7, (index) {
        return _visitedTabs.contains(index)
            ? _buildTab(index)
            : const SizedBox.shrink();
      }),
    );
  }

  Widget _buildTab(int index) {
    switch (index) {
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
        return HubScreen(
          engine: engine,
          addons: managedAddons.toList(),
          onDetails: _openDetails,
        );
      case 6:
        return _AddonPage(
          addons: managedAddons,
          onAdd: _addAddon,
          onRemove: _removeAddon,
        );
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
  final void Function(
    String,
    String,
    String, {
    VoidCallback? onNext,
    Map<String, String>? headers,
  })
  onPlay;
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
      if (!b.hasCatalog) continue;
      if (activeBrandIndex != null && _brands[activeBrandIndex!] != b) continue;

      specs.add(
        CatalogRowSpec(
          title: '${b.name} Movies',
          primaryUrl: '$_streamingCatalogs/catalog/movie/${b.shortId}.json',
          fallbackUrl: null,
          type: 'movie',
          accent: b.color,
          showRanks: true,
        ),
      );

      specs.add(
        CatalogRowSpec(
          title: '${b.name} Series',
          primaryUrl: '$_streamingCatalogs/catalog/series/${b.shortId}.json',
          fallbackUrl: null,
          type: 'series',
          accent: b.color,
          showRanks: true,
        ),
      );
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
      '$_cinemeta/catalog/movie/top.json',
      '$_cinemeta/catalog/movie/imdbRating.json',
    );

    if (!mounted) return;
    setState(() {
      rows['Popular Movies'] = items;
      indiaLoading = false;
      if (hero == null && items.isNotEmpty) {
        hero = items.first;
      }
    });
    final series = await widget.engine.fetchRow(
      '$_cinemeta/catalog/series/top.json',
      '$_cinemeta/catalog/series/imdbRating.json',
      type: 'series',
    );
    if (mounted) setState(() => rows['Popular Series'] = series);
  }

  Future<void> _loadRow(CatalogRowSpec spec) async {
    if (rows.containsKey(spec.title)) return;

    setState(() => loadingRows.add(spec.title));
    final items = await widget.engine.fetchRow(
      spec.primaryUrl,
      spec.fallbackUrl,
      type: spec.type,
    );

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
        scrollCacheExtent: const ScrollCacheExtent.pixels(800.0),
        slivers: [
          if (hero != null) SliverToBoxAdapter(child: _buildHero(hero!)),

          if (!widget.onlyTheaters && !widget.onlyAnime)
            SliverToBoxAdapter(child: _buildOttDock()),

          if (widget.resumeMs.isNotEmpty &&
              activeBrandIndex == null &&
              !widget.onlyTheaters &&
              !widget.onlyAnime)
            SliverToBoxAdapter(child: _buildContinueWatching()),

          if (!widget.onlyTheaters &&
              !widget.onlyAnime &&
              activeBrandIndex == null)
            SliverToBoxAdapter(
              child: _buildPosterRow(
                title: 'Popular Movies',
                items: rows['Popular Movies'] ?? [],
                accent: const Color(0xFFFF9933),
                showRanks: true,
                loading: indiaLoading,
              ),
            ),

          if (!widget.onlyTheaters &&
              !widget.onlyAnime &&
              activeBrandIndex == null)
            SliverToBoxAdapter(
              child: _buildPosterRow(
                title: 'Popular Series',
                items: rows['Popular Series'] ?? [],
                accent: _cyan,
                showRanks: false,
                loading: indiaLoading,
              ),
            ),
          if (activeBrandIndex != null &&
              !_brands[activeBrandIndex!].hasCatalog)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  '${_brands[activeBrandIndex!].name} catalog is not declared by the connected Streaming Catalogs addon. Add a provider-specific catalog addon; generic fallback content is intentionally not shown.',
                  style: const TextStyle(color: _muted, fontSize: 14),
                ),
              ),
            ),

          ..._buildSpecs().map(
            (spec) => SliverToBoxAdapter(
              child: _buildPosterRow(
                title: spec.title,
                items: rows[spec.title] ?? [],
                accent: spec.accent,
                showRanks: spec.showRanks,
                loading: loadingRows.contains(spec.title),
              ),
            ),
          ),

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
                colors: [Colors.transparent, _bg.withValues(alpha: 0.7), _bg],
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: _red,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        m.type.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (m.rating.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'IMDb ${m.rating}',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.amber,
                          ),
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
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    _FButton(
                      label: 'Play Now',
                      icon: Icons.play_arrow,
                      primary: true,
                      onTap: () => _smartPlay(m),
                    ),
                    _FButton(
                      label: isFav ? 'In Watchlist' : '+ Watchlist',
                      icon: isFav ? Icons.check : Icons.add,
                      onTap: () => widget.onDetails(m),
                    ),
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
            style: TextStyle(
              color: _cyan,
              fontSize: 14,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.5,
            ),
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
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: _textPri,
              ),
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
                              style: const TextStyle(
                                color: _textPri,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Resume from ${_fmt(ms)}',
                              style: const TextStyle(
                                color: _cyan,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
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
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: _textPri,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 260,
              child: items.isEmpty && loading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: _cyan,
                        strokeWidth: 2,
                      ),
                    )
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
    final streams = await widget.engine.resolveStreams(
      m.type,
      m.id,
      widget.addons,
    );
    if (!mounted) return;

    if (streams.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No stream results. Check addon status and configuration.',
          ),
        ),
      );
      return;
    }

    final direct = streams.where((stream) => stream.isDirect).take(8).toList();
    if (direct.isNotEmpty) {
      final checks = await Future.wait(
        direct.map(widget.engine.probeDirectStream),
      );
      final workingIndex = checks.indexWhere((isWorking) => isWorking);
      if (workingIndex >= 0 && mounted) {
        final stream = direct[workingIndex];
        widget.onPlay(m.name, stream.url!, m.id);
        return;
      }
    }
    if (!mounted) return;
    final torrentOnly = streams.every((stream) => stream.isTorrent);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          torrentOnly
              ? 'Sirf magnet/torrent results mile; verified direct HTTP source nahi mila. Movie playback ke liye authorized provider ka direct stream URL chahiye.'
              : 'Koi direct HTTP source abhi reachable nahi hai. Provider refresh karein ya doosra source chunein.',
        ),
        duration: const Duration(seconds: 7),
      ),
    );
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
  final void Function(
    String,
    String,
    String, {
    VoidCallback? onNext,
    Map<String, String>? headers,
  })
  onPlay;
  const LiveTvScreen({super.key, required this.engine, required this.onPlay});
  @override
  State<LiveTvScreen> createState() => _LiveTvScreenState();
}

class _LiveTvScreenState extends State<LiveTvScreen> {
  List<Map<String, String>> _channels = [];
  bool _loading = true;
  bool _refreshing = false;
  String _query = '';
  String _selectedCountry = '*';
  String _selectedCategory = '*';
  String? _error;
  final _search = TextEditingController();
  final LiveTvHealthRegistry _health = LiveTvHealthRegistry();
  late final Future<void> _healthReady;
  String? _checkingChannelUrl;
  Timer? _autoRefreshTimer;
  Timer? _healthRevalidationTimer;
  bool _revalidatingHealth = false;

  @override
  void initState() {
    super.initState();
    _healthReady = _health.load();
    unawaited(
      _healthReady.then((_) async {
        if (!mounted) return;
        setState(() {});
        await _revalidateExpiredFeeds();
      }),
    );
    _load();
    _autoRefreshTimer = Timer.periodic(const Duration(hours: 6), (_) {
      if (mounted && !_loading && !_refreshing) _load(forceRefresh: true);
    });
    _healthRevalidationTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      unawaited(_revalidateExpiredFeeds());
    });
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _healthRevalidationTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// Revalidate a bounded batch of expired quarantines every five minutes.
  /// A recovered feed is restored automatically; a still-dead feed gets a
  /// fresh 20-minute quarantine rather than being retried on every tap.
  Future<void> _revalidateExpiredFeeds() async {
    await _healthReady;
    if (!mounted || _revalidatingHealth) return;
    final due = _health.dueForRecheck(limit: 6);
    if (due.isEmpty) return;
    _revalidatingHealth = true;
    try {
      final checks = await Future.wait(
        due.map(widget.engine.probeLiveTvSource),
      );
      for (var i = 0; i < due.length; i++) {
        final url = due[i]['url'] ?? '';
        if (url.isEmpty) continue;
        if (checks[i]) {
          await _health.markHealthy(url);
        } else {
          await _health.quarantine([due[i]]);
        }
      }
      if (mounted) setState(() {});
    } finally {
      _revalidatingHealth = false;
    }
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final hasChannels = _channels.isNotEmpty;
    if (mounted)
      setState(() {
        _loading = !hasChannels;
        _refreshing = hasChannels;
        _error = null;
      });
    try {
      final channels = await widget.engine.fetchIptv(
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        if (channels.isNotEmpty) _channels = channels;
        _loading = false;
        _refreshing = false;
        _error = _channels.isEmpty
            ? 'Public playlist or channel metadata is unavailable. Check the connection and retry.'
            : null;
        final countryCodes = _channels
            .map((c) => c['countryCode'] ?? '')
            .where((v) => v.isNotEmpty)
            .toSet();
        final categoryIds = _channels
            .expand((c) => (c['categoryIds'] ?? '').split('|'))
            .where((v) => v.isNotEmpty)
            .toSet();
        if (_selectedCountry != '*' && !countryCodes.contains(_selectedCountry))
          _selectedCountry = '*';
        if (_selectedCategory != '*' &&
            !categoryIds.contains(_selectedCategory))
          _selectedCategory = '*';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = _channels.isEmpty
            ? 'Live TV could not load: $error'
            : 'Refresh failed; showing the cached channel list.';
      });
    }
  }

  Future<void> _playChannel(Map<String, String> channel) async {
    if (_checkingChannelUrl != null) return;
    await _healthReady;
    final candidates = widget.engine.liveTvAlternates(channel, _channels);
    if (candidates.isEmpty) return;
    setState(() => _checkingChannelUrl = channel['url']);
    try {
      final probe = await widget.engine.probeLiveTvSources(candidates);
      final working = probe.working;
      // Quarantine every failed alternate, not only when all feeds fail. This
      // prevents a known-dead primary URL from being offered repeatedly.
      await _health.quarantine(probe.failed);
      if (working != null) {
        await _health.markHealthy(working['url'] ?? '');
      }
      if (!mounted) return;
      setState(() => _checkingChannelUrl = null);
      if (working == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Is channel ke public feeds offline/blocked mile. Dead entries 20 minutes ke liye hide ki gayi hain; app unhe background me dobara check karegi.',
            ),
            duration: Duration(seconds: 6),
          ),
        );
        return;
      }
      if ((working['url'] ?? '') != (channel['url'] ?? '')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Primary feed unavailable; alternate ${working['source'] ?? 'public'} feed selected.',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      final headers = <String, String>{
        if ((working['userAgent'] ?? '').isNotEmpty)
          'User-Agent': working['userAgent']!,
        if ((working['referrer'] ?? '').isNotEmpty)
          'Referer': working['referrer']!,
      };
      widget.onPlay(
        working['name'] ?? channel['name'] ?? 'Live TV',
        working['url'] ?? '',
        working['url'] ?? '',
        headers: headers,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _checkingChannelUrl = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Channel health check failed: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final healthyCandidates = _channels.where((channel) {
      return !_health.isQuarantined(channel['url'] ?? '');
    }).toList();
    final countryOptions = <String, String>{};
    final categoryOptions = <String, String>{};
    for (final c in _channels) {
      final code = c['countryCode'] ?? '';
      if (code.isNotEmpty) {
        countryOptions.putIfAbsent(
          code,
          () => (c['countryFlag'] ?? '') + ' ' + (c['countryName'] ?? code),
        );
      }
      final ids = (c['categoryIds'] ?? '').split('|');
      final names = (c['categoryNames'] ?? '').split(', ');
      for (var i = 0; i < ids.length; i++) {
        if (ids[i].isNotEmpty) {
          categoryOptions.putIfAbsent(
            ids[i],
            () => i < names.length && names[i].isNotEmpty ? names[i] : ids[i],
          );
        }
      }
    }
    final sortedCountryOptions = countryOptions.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final sortedCategoryOptions = categoryOptions.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final filtered = filterLiveTvChannels(
      healthyCandidates,
      countryCode: _selectedCountry,
      categoryId: _selectedCategory,
      query: _query,
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: (v) => setState(() => _query = v.trim()),
                  style: const TextStyle(color: _textPri),
                  decoration: InputDecoration(
                    hintText: 'Search live channels worldwide...',
                    prefixIcon: const Icon(Icons.search, color: _cyan),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            onPressed: () {
                              _search.clear();
                              setState(() => _query = '');
                            },
                            icon: const Icon(Icons.close),
                          ),
                    filled: true,
                    fillColor: _panel,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _loading ? null : () => _load(forceRefresh: true),
                icon: const Icon(Icons.refresh, color: _cyan),
                tooltip: 'Refresh channels',
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _selectedCountry,
                  isExpanded: true,
                  dropdownColor: _panel,
                  decoration: const InputDecoration(
                    labelText: 'COUNTRY',
                    labelStyle: TextStyle(color: _muted, fontSize: 12),
                    filled: true,
                    fillColor: _panel,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(borderSide: BorderSide.none),
                  ),
                  style: const TextStyle(color: _textPri, fontSize: 13),
                  items: [
                    const DropdownMenuItem(
                      value: '*',
                      child: Text('All countries'),
                    ),
                    ...sortedCountryOptions.map(
                      (e) => DropdownMenuItem(
                        value: e.key,
                        child: Text(
                          e.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                  onChanged: (v) => setState(() => _selectedCountry = v ?? '*'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _selectedCategory,
                  isExpanded: true,
                  dropdownColor: _panel,
                  decoration: const InputDecoration(
                    labelText: 'CATEGORY',
                    labelStyle: TextStyle(color: _muted, fontSize: 12),
                    filled: true,
                    fillColor: _panel,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(borderSide: BorderSide.none),
                  ),
                  style: const TextStyle(color: _textPri, fontSize: 13),
                  items: [
                    const DropdownMenuItem(
                      value: '*',
                      child: Text('All categories'),
                    ),
                    ...sortedCategoryOptions.map(
                      (e) => DropdownMenuItem(
                        value: e.key,
                        child: Text(
                          e.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                  onChanged: (v) =>
                      setState(() => _selectedCategory = v ?? '*'),
                ),
              ),
            ],
          ),
        ),
        if (_refreshing)
          const LinearProgressIndicator(
            minHeight: 2,
            color: _cyan,
            backgroundColor: _panel,
          ),
        if (_channels.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${filtered.length} of ${healthyCandidates.length} candidate feeds • India + South Asia + Asia + language/category playlists • refresh every 6h; dead feeds rechecked every 5m',
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: _cyan))
              : filtered.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.live_tv, size: 48, color: _muted),
                        const SizedBox(height: 12),
                        Text(
                          _error ??
                              (_channels.isEmpty
                                  ? 'No live channels available.'
                                  : 'No matching channels.'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: _muted),
                        ),
                        if (_channels.isEmpty) ...[
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _load,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry'),
                          ),
                        ],
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => _load(forceRefresh: true),
                  color: _cyan,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final c = filtered[i];
                      final logo = c['logo'] ?? '';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _Card(
                          child: ListTile(
                            leading: logo.isNotEmpty
                                ? Image.network(
                                    logo,
                                    width: 42,
                                    height: 42,
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, __, ___) =>
                                        const Icon(Icons.live_tv, color: _red),
                                  )
                                : const Icon(Icons.live_tv, color: _red),
                            title: Text(
                              c['name'] ?? 'Channel',
                              style: const TextStyle(
                                color: _textPri,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: Text(
                              [
                                (c['categoryNames'] ?? '').isNotEmpty
                                    ? c['categoryNames']!
                                    : (c['group'] ?? 'Other'),
                                if ((c['countryName'] ?? '').isNotEmpty)
                                  (c['countryFlag'] ?? '') +
                                      ' ' +
                                      c['countryName']!,
                                if ((c['language'] ?? '').isNotEmpty)
                                  c['language']!,
                              ].join(' • '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _cyan,
                                fontSize: 11,
                              ),
                            ),
                            trailing: _checkingChannelUrl == (c['url'] ?? '')
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: _cyan,
                                    ),
                                  )
                                : const Icon(
                                    Icons.play_circle_fill,
                                    color: Colors.greenAccent,
                                  ),
                            onTap: () => _playChannel(c),
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class HubScreen extends StatefulWidget {
  final CatalogEngine engine;
  final List<ManagedAddon> addons;
  final void Function(Meta) onDetails;
  const HubScreen({
    super.key,
    required this.engine,
    required this.addons,
    required this.onDetails,
  });
  @override
  State<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends State<HubScreen> {
  AddonCatalog? _selected;
  List<AddonCatalog> _catalogs = [];
  List<Meta> _movies = [];
  List<Meta> _series = [];
  bool _loadingCatalogs = true;
  bool _loading = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _loadCatalogs();
  }

  @override
  void didUpdateWidget(covariant HubScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldManifests =
        oldWidget.addons.map((addon) => addon.manifestUrl).toList()..sort();
    final newManifests =
        widget.addons.map((addon) => addon.manifestUrl).toList()..sort();
    if (oldManifests.join('\\n') != newManifests.join('\\n')) {
      _loadCatalogs();
    }
  }

  Future<void> _loadCatalogs() async {
    if (mounted) {
      setState(() {
        _loadingCatalogs = true;
        _message = null;
      });
    }
    final eligible = widget.addons
        .where((addon) => !addon.name.toLowerCase().contains('cinemeta'))
        .toList();
    final results = await Future.wait(
      eligible.map(widget.engine.fetchAddonCatalogs),
    );
    final merged = <String, AddonCatalog>{};
    for (final list in results) {
      for (final catalog in list) {
        final key = '${catalog.baseUrl}|${catalog.id}|${catalog.catalogName}';
        final existing = merged.putIfAbsent(key, () => catalog);
        existing.types.addAll(catalog.types);
      }
    }
    final catalogs = merged.values.toList()
      ..sort((a, b) {
        final byName = a.catalogName.toLowerCase().compareTo(
          b.catalogName.toLowerCase(),
        );
        return byName != 0
            ? byName
            : a.addonName.toLowerCase().compareTo(b.addonName.toLowerCase());
      });
    if (!mounted) return;
    setState(() {
      _catalogs = catalogs;
      _loadingCatalogs = false;
    });
  }

  Future<void> _openCatalog(AddonCatalog catalog) async {
    setState(() {
      _selected = catalog;
      _loading = true;
      _message = null;
      _movies = [];
      _series = [];
    });
    final base = catalog.baseUrl.replaceFirst(RegExp(r'/+$'), '');
    final encodedId = Uri.encodeComponent(catalog.id);
    final results = await Future.wait([
      catalog.types.contains('movie')
          ? widget.engine.fetchRow('$base/catalog/movie/$encodedId.json', null)
          : Future.value(<Meta>[]),
      catalog.types.contains('series')
          ? widget.engine.fetchRow(
              '$base/catalog/series/$encodedId.json',
              null,
              type: 'series',
            )
          : Future.value(<Meta>[]),
    ]);
    if (!mounted) return;
    setState(() {
      _movies = results[0];
      _series = results[1];
      _loading = false;
      if (_movies.isEmpty && _series.isEmpty) {
        _message =
            'No titles were returned by ${catalog.catalogName} from ${catalog.addonName}. This catalog may require provider/country configuration. Add its configured manifest URL in the Addons tab, then refresh.';
      }
    });
  }

  Future<void> _openStreamingCatalogsSetup() async {
    final uri = Uri.parse(
      'https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club/configure',
    );
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open the catalog setup page.'),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Catalog setup unavailable: $error')),
      );
    }
  }

  Widget _contentRow(String title, List<Meta> items, Color accent) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              title,
              style: TextStyle(
                color: accent,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 250,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: items.length,
              itemBuilder: (_, i) => PosterCard(
                meta: items[i],
                rank: i < 10 ? i + 1 : null,
                accent: accent,
                onFocus: () {},
                onTap: () => widget.onDetails(items[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyCatalogState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.video_library_outlined, color: _cyan, size: 52),
            const SizedBox(height: 14),
            const Text(
              'No OTT catalog feeds are available yet.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _textPri,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'IndiaStreams and configured Stremio catalog addons are read from their manifests. To enable provider-specific catalogs, configure Streaming Catalogs for India, copy its generated manifest URL, and add it in the Addons tab.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted, height: 1.5),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _openStreamingCatalogsSetup,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Configure Streaming Catalogs'),
              style: FilledButton.styleFrom(backgroundColor: _red),
            ),
            TextButton.icon(
              onPressed: _loadCatalogs,
              icon: const Icon(Icons.refresh, color: _cyan),
              label: const Text('Refresh catalogs'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_selected != null) {
      final catalog = _selected!;
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => setState(() {
                    _selected = null;
                    _message = null;
                  }),
                  icon: const Icon(Icons.arrow_back, color: _cyan),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        catalog.catalogName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _cyan,
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        catalog.addonName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => _openCatalog(catalog),
                  icon: const Icon(Icons.refresh, color: _cyan),
                ),
              ],
            ),
          ),
          if (_loading)
            const Expanded(
              child: Center(child: CircularProgressIndicator(color: _cyan)),
            )
          else if (_message != null)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _message!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: _muted, height: 1.5),
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView(
                children: [
                  _contentRow(
                    '${catalog.catalogName} • Movies',
                    _movies,
                    _cyan,
                  ),
                  _contentRow(
                    '${catalog.catalogName} • Series',
                    _series,
                    _textPri,
                  ),
                  const SizedBox(height: 28),
                ],
              ),
            ),
        ],
      );
    }
    if (_loadingCatalogs) {
      return const Center(child: CircularProgressIndicator(color: _cyan));
    }
    if (_catalogs.isEmpty) return _emptyCatalogState();
    return GridView.builder(
      padding: const EdgeInsets.all(20),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 320,
        mainAxisExtent: 140,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: _catalogs.length,
      itemBuilder: (_, i) {
        final catalog = _catalogs[i];
        final types = [
          if (catalog.types.contains('movie')) 'Movies',
          if (catalog.types.contains('series')) 'Series',
        ].join(' & ');
        return _Card(
          borderColor: _cyan.withValues(alpha: 0.42),
          onTap: () => _openCatalog(catalog),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [_cyan.withValues(alpha: 0.12), _panel],
              ),
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  catalog.catalogName.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _cyan,
                    fontWeight: FontWeight.w900,
                    fontSize: 19,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${catalog.addonName} • $types',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
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
      },
    );
  }
}

class MoodScreen extends StatefulWidget {
  final CatalogEngine engine;
  final void Function(Meta) onShowDetails;

  const MoodScreen({
    super.key,
    required this.engine,
    required this.onShowDetails,
  });

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
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: _cyan,
            ),
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
                            style: const TextStyle(
                              color: _red,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
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
                  style: const TextStyle(
                    color: _cyan,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                const Spacer(),
                if (_loading)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _cyan,
                    ),
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
  final void Function(
    String,
    String,
    String, {
    VoidCallback? onNext,
    Map<String, String>? headers,
  })
  onPlay;

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
  bool _smartPlayBusy = false;

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
              'S${firstEp['season']}E${firstEp['episode']} - ${firstEp['name'] ?? ''}';
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

    final streams = await widget.engine.resolveStreams(
      widget.meta.type,
      id,
      widget.addons,
      onUpdate: (partial) {
        if (!mounted) return;
        setState(() => _streams = partial);
      },
    );

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
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: _textPri,
                  ),
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
              style: TextStyle(
                color: _cyan,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
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
            const SizedBox(height: 8),
            if (_targetId.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: widget.watchedEpisodes.contains(_targetId)
                      ? null
                      : () => widget.onMarkWatched(_targetId),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Mark selected episode watched'),
                ),
              ),
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
                        onTap: () {
                          setState(() {
                            _targetId = epId;
                            _targetLabel =
                                'S${ep['season']}E${ep['episode']} - ${ep['name'] ?? ''}';
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
                                    style: const TextStyle(
                                      color: _red,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const Spacer(),
                                  if (watched)
                                    const Icon(
                                      Icons.check_circle,
                                      color: Colors.greenAccent,
                                      size: 16,
                                    ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                (ep['name'] ?? '').toString(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: _textPri,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
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
                label: _smartPlayBusy
                    ? 'Checking fastest available source...'
                    : '⚡ Smart Play • Fastest Valid Source',
                icon: Icons.bolt,
                primary: true,
                onTap: _playBestAvailable,
              ),
            ),

          Text(
            'Available Streams: $_targetLabel',
            style: const TextStyle(
              color: _cyan,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 12),

          if (_loadingStreams)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'Scanning sources...',
                  style: TextStyle(color: _cyan, fontSize: 14),
                ),
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
            ..._streams
                .take(30)
                .map(
                  (s) => Padding(
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
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _cyan.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    s.badge,
                                    style: const TextStyle(
                                      color: _cyan,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  s.addonName,
                                  style: const TextStyle(
                                    color: _red,
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Spacer(),
                                if (s.isDirect) ...[
                                  const Text(
                                    'PLAY IN APP',
                                    style: TextStyle(
                                      color: Colors.greenAccent,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ] else if (s.isTorrent)
                                  Text(
                                    s.seeders == null
                                        ? 'TORRENT • SEEDERS UNREPORTED'
                                        : 'TORRENT • ${s.seeders} REPORTED SEEDERS',
                                    style: TextStyle(
                                      color: s.seeders == 0
                                          ? Colors.orangeAccent
                                          : Colors.greenAccent,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                              ],
                            ),
                            if (s.title.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                s.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: _textPri,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }

  Future<void> _playBestAvailable() async {
    if (_smartPlayBusy || _streams.isEmpty) return;
    setState(() => _smartPlayBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Probe direct HLS/DASH/file URLs concurrently. One dead/expired source
      // must not hold the user behind the other providers' timeout.
      final direct = _streams
          .where((stream) => stream.isDirect)
          .take(6)
          .toList();
      if (direct.isNotEmpty) {
        final checks = await Future.wait(
          direct.map(widget.engine.probeDirectStream),
        );
        final workingIndex = checks.indexWhere((isWorking) => isWorking);
        if (workingIndex >= 0 && mounted) {
          _playStream(direct[workingIndex]);
          return;
        }
      }

      // No verified direct URL: use the healthiest available swarm, ranked by
      // seeders first and then quality. P2P startup remains swarm-dependent.
      final torrents = _streams.where((stream) => stream.isTorrent).toList()
        ..sort((a, b) => b.score.compareTo(a.score));
      final reachableCandidates = torrents
          .where((stream) => stream.seeders == null || stream.seeders! > 0)
          .toList();
      if (reachableCandidates.isNotEmpty && mounted) {
        await _playTorrent(reachableCandidates.first);
        return;
      }
      if (torrents.isNotEmpty && mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'All torrent results report zero seeders. Choose another source; a zero-seeder swarm cannot provide the first video pieces.',
            ),
            duration: Duration(seconds: 8),
          ),
        );
        return;
      }
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'No reachable direct stream or torrent source was found. Try another provider or source.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _smartPlayBusy = false);
    }
  }

  Future<void> _playTorrent(StreamLink stream) async {
    if (stream.seeders == 0) {
      final continueAnyway = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: _panel,
          title: const Text('No seeders reported'),
          content: const Text(
            'This provider reports zero seeders. The player can remain at 00:00 because no peer can send the first video pieces. Choose another source first, or try this swarm anyway.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Choose another source'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Try anyway'),
            ),
          ],
        ),
      );
      if (continueAnyway != true || !mounted) return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Starting torrent playback. If no peers deliver the first pieces, the player will show an error so you can choose another source.',
        ),
        duration: Duration(seconds: 8),
      ),
    );
    try {
      final supplementalTrackers = await widget.engine
          .fetchSupplementalTrackers();
      // Trackerlist's daily health-ranked 20 lead; keep a few add-on hints too.
      final trackers = <String>{
        ...supplementalTrackers.take(20),
        ...stream.trackers.take(4),
      }.toList(growable: false);
      final url = await EmbeddedTorrentService.instance.startPlayback(
        stream.infoHash!,
        title: '${widget.meta.name} - $_targetLabel',
        fileIdx: stream.fileIdx,
        trackers: trackers,
      );
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      widget.onPlay('${widget.meta.name} - $_targetLabel', url, _targetId);
    } catch (error) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Torrent playback failed: $error'),
          duration: const Duration(seconds: 7),
        ),
      );
    }
  }

  void _playStream(StreamLink s) {
    if (s.isDirect) {
      widget.onPlay(
        '${widget.meta.name} - $_targetLabel',
        s.url!,
        _targetId,
        headers: s.headers,
      );
    } else if (s.isTorrent) {
      _playTorrent(s);
    }
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
                style: TextStyle(
                  color: _cyan,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
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
                    ? const Center(
                        child: CircularProgressIndicator(color: _cyan),
                      )
                    : _results.isEmpty
                    ? const Center(
                        child: Text(
                          'Search for anything',
                          style: TextStyle(color: _muted),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _results.length,
                        itemBuilder: (_, i) => ListTile(
                          title: Text(
                            _results[i].name,
                            style: const TextStyle(
                              color: _textPri,
                              fontWeight: FontWeight.bold,
                            ),
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
  final Future<void> Function(String) onAdd;
  final Future<void> Function(ManagedAddon) onRemove;

  const _AddonPage({
    required this.addons,
    required this.onAdd,
    required this.onRemove,
  });

  Future<void> _showAddDialog(BuildContext context) async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _panel,
        title: const Text('Install Stremio-compatible addon'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/manifest.json',
            labelText: 'Manifest URL',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Validate & Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null || url.isEmpty || !context.mounted) return;
    try {
      await onAdd(url);
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Addon installed.')));
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Addon install failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Addon Manager',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: _cyan,
                ),
              ),
            ),
            FilledButton.icon(
              onPressed: () => _showAddDialog(context),
              icon: const Icon(Icons.add),
              label: const Text('Add addon'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Configured addons are retained when temporarily offline. Only compatible Stremio manifest/stream endpoints are supported.',
          style: TextStyle(color: _muted, fontSize: 13),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => launchUrl(
            Uri.parse('https://comet.elfhosted.com/configure'),
            mode: LaunchMode.externalApplication,
          ),
          icon: const Icon(Icons.tune),
          label: const Text('Configure Comet (optional debrid source)'),
        ),
        const Text(
          'Comet public endpoint may require a debrid account. After configuration, copy its generated manifest URL and use Add addon. Do not paste API keys into public chats.',
          style: TextStyle(color: _muted, fontSize: 11),
        ),
        const SizedBox(height: 16),
        if (addons.isEmpty)
          const Text('No addons configured.', style: TextStyle(color: _muted)),
        ...addons.map(
          (a) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _Card(
              child: ListTile(
                title: Text(
                  a.name,
                  style: const TextStyle(
                    color: _textPri,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                subtitle: Text(
                  a.baseUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
                trailing: IconButton(
                  tooltip: 'Remove addon',
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  onPressed: () => onRemove(a),
                ),
              ),
            ),
          ),
        ),
      ],
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
        : (widget.primary ? Colors.white : (widget.active ? _cyan : _textPri));

    final border = _focused
        ? _cyan
        : (widget.primary ? _red : (widget.active ? _cyan : Colors.white24));

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
        : (widget.selected ? _red : (widget.borderColor ?? Colors.white12));

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
                  ? [
                      BoxShadow(
                        color: _cyan.withValues(alpha: 0.4),
                        blurRadius: 20,
                      ),
                    ]
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
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
              ? [
                  BoxShadow(
                    color: widget.brand.color.withValues(alpha: 0.4),
                    blurRadius: 16,
                  ),
                ]
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
              widget.brand.hasCatalog
                  ? 'Movies & Series'
                  : 'Catalog addon required',
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
