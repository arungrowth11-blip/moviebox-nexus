import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// GitHub App OAuth configuration is public application metadata, not a secret.
/// The app's client secret, private key, and any PAT must never be shipped in
/// the APK. Configure the public client ID and a dedicated private repository
/// with --dart-define at release build time.
class GitHubDiagnosticsUploader {
  GitHubDiagnosticsUploader({
    http.Client? client,
    FlutterSecureStorage? storage,
    String? clientId,
    String? repository,
  }) : _client = client ?? http.Client(),
       _storage = storage ?? const FlutterSecureStorage(),
       _clientId =
           clientId ??
           const String.fromEnvironment('MOVIEBOX_GITHUB_APP_CLIENT_ID'),
       _repository =
           repository ??
           const String.fromEnvironment('MOVIEBOX_DIAGNOSTICS_REPOSITORY');

  static const String _deviceCodeUrl = 'https://github.com/login/device/code';
  static const String _tokenUrl = 'https://github.com/login/oauth/access_token';
  static const String _apiVersion = '2022-11-28';
  static const int _maxReportBytes = 256 * 1024;
  static const String _accessTokenKey = 'moviebox.github.access_token';
  static const String _refreshTokenKey = 'moviebox.github.refresh_token';
  static const String _accessExpiryKey = 'moviebox.github.access_expiry_ms';
  static const String _uploadedReportIdsKey =
      'moviebox.github.uploaded_report_ids';

  final http.Client _client;
  final FlutterSecureStorage _storage;
  final String _clientId;
  final String _repository;

  bool get isConfigured =>
      _clientId.trim().isNotEmpty &&
      RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(_repository.trim());

  Future<bool> get hasStoredAuthorization async =>
      (await _storage.read(key: _refreshTokenKey)) != null ||
      (await _storage.read(key: _accessTokenKey)) != null;

  Future<GitHubDeviceFlowChallenge> beginAuthorization() async {
    _requireConfiguration();
    final response = await _client
        .post(
          Uri.parse(_deviceCodeUrl),
          headers: const {'Accept': 'application/json'},
          body: {'client_id': _clientId, 'scope': 'offline_access'},
        )
        .timeout(const Duration(seconds: 20));
    final payload = _decodeResponse(response);
    if (response.statusCode != 200) {
      throw StateError('GitHub did not start device authorization.');
    }

    final deviceCode = payload['device_code']?.toString();
    final userCode = payload['user_code']?.toString();
    final verificationUriText = payload['verification_uri']?.toString();
    final verificationUri = Uri.tryParse(verificationUriText ?? '');
    final expiresIn = _asPositiveInt(payload['expires_in'], fallback: 900);
    final interval = _asPositiveInt(payload['interval'], fallback: 5);

    if (deviceCode == null ||
        deviceCode.isEmpty ||
        userCode == null ||
        userCode.isEmpty ||
        verificationUri == null ||
        verificationUri.scheme != 'https' ||
        verificationUri.host != 'github.com' ||
        verificationUri.path != '/login/device') {
      throw StateError(
        'GitHub returned an invalid device authorization response.',
      );
    }

    final opened = await launchUrl(
      verificationUri,
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      throw StateError(
        'Could not open github.com/login/device in the browser.',
      );
    }

    return GitHubDeviceFlowChallenge(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: verificationUri,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      intervalSeconds: interval,
    );
  }

  /// Polls GitHub after the user confirms the browser authorization. Tokens
  /// are held in encrypted platform storage and never written to diagnostics.
  Future<void> completeAuthorization(
    GitHubDeviceFlowChallenge challenge,
  ) async {
    _requireConfiguration();
    var intervalSeconds = challenge.intervalSeconds;

    while (DateTime.now().isBefore(challenge.expiresAt)) {
      await Future<void>.delayed(Duration(seconds: intervalSeconds));
      if (!DateTime.now().isBefore(challenge.expiresAt)) break;

      final response = await _client
          .post(
            Uri.parse(_tokenUrl),
            headers: const {'Accept': 'application/json'},
            body: {
              'client_id': _clientId,
              'device_code': challenge.deviceCode,
              'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
            },
          )
          .timeout(const Duration(seconds: 20));
      final payload = _decodeResponse(response);
      final error = payload['error']?.toString();

      if (response.statusCode == 200 && payload['access_token'] is String) {
        await _storeTokenResponse(payload);
        return;
      }
      if (error == 'authorization_pending') continue;
      if (error == 'slow_down') {
        intervalSeconds += 5;
        continue;
      }
      if (error == 'access_denied') {
        throw StateError('GitHub authorization was denied.');
      }
      if (error == 'expired_token' || error == 'token_expired') {
        throw StateError(
          'GitHub device code expired; start authorization again.',
        );
      }
      throw StateError('GitHub device authorization failed.');
    }

    throw TimeoutException('GitHub device authorization expired.');
  }

  Future<String> uploadReport({
    required String reportId,
    required String reportJson,
  }) async {
    _requireConfiguration();
    if (!RegExp(r'^failure-\d+-[0-9a-fA-F-]{36}\.json$').hasMatch(reportId)) {
      throw StateError('Invalid local diagnostic report identifier.');
    }

    final encoded = utf8.encode(reportJson);
    if (encoded.isEmpty || encoded.length > _maxReportBytes) {
      throw StateError(
        'Diagnostic report is empty or exceeds the safe size limit.',
      );
    }
    _validateSanitizedReport(reportJson);

    final uploadedIds = await _readUploadedReportIds();
    if (uploadedIds.contains(reportId)) return _privateBlobUrl(reportId);

    final accessToken = await _getAccessToken();
    await _requirePrivateDestination(accessToken);
    final path = 'playback-diagnostics/$reportId';
    final response = await _client
        .put(
          Uri.https('api.github.com', '/repos/$_repository/contents/$path'),
          headers: {
            'Accept': 'application/vnd.github+json',
            'Authorization': 'Bearer $accessToken',
            'Content-Type': 'application/json',
            'X-GitHub-Api-Version': _apiVersion,
            'User-Agent': 'MovieBox-Nexus-Private-Diagnostics',
          },
          body: jsonEncode({
            'message': 'Add sanitized MovieBox playback diagnostic',
            'content': base64Encode(encoded),
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 401) {
      throw StateError(
        'GitHub authorization expired or was revoked; reconnect the app.',
      );
    }
    if (response.statusCode == 403 || response.statusCode == 404) {
      throw StateError(
        'GitHub denied this upload. Install the MovieBox GitHub App on the '
        'selected private repository and grant Contents: write.',
      );
    }
    if (response.statusCode != 201 && response.statusCode != 200) {
      throw StateError('GitHub did not accept the private diagnostic upload.');
    }

    await _rememberUploadedReport(reportId);
    final payload = _decodeResponse(response);
    final htmlUrl = payload['content'] is Map
        ? (payload['content'] as Map)['html_url']?.toString()
        : null;
    if (htmlUrl != null && Uri.tryParse(htmlUrl)?.host == 'github.com') {
      return htmlUrl;
    }
    return _privateBlobUrl(reportId);
  }

  Future<void> disconnect() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
    await _storage.delete(key: _accessExpiryKey);
  }

  Future<void> _requirePrivateDestination(String accessToken) async {
    final response = await _client
        .get(
          Uri.https('api.github.com', '/repos/$_repository'),
          headers: {
            'Accept': 'application/vnd.github+json',
            'Authorization': 'Bearer $accessToken',
            'X-GitHub-Api-Version': _apiVersion,
            'User-Agent': 'MovieBox-Nexus-Private-Diagnostics',
          },
        )
        .timeout(const Duration(seconds: 20));
    final metadata = _decodeResponse(response);
    if (response.statusCode != 200 || metadata['private'] != true) {
      throw StateError(
        'The diagnostics destination must be an existing private repository '
        'that this GitHub App can access.',
      );
    }
  }

  Future<List<String>> _readUploadedReportIds() async {
    final stored = await _storage.read(key: _uploadedReportIdsKey);
    if (stored == null) return <String>[];
    try {
      final decoded = jsonDecode(stored);
      if (decoded is List) {
        return decoded.whereType<String>().take(20).toList();
      }
    } on FormatException {
      // Treat corrupted idempotency state as empty; never block a safe retry.
    }
    return <String>[];
  }

  Future<void> _rememberUploadedReport(String reportId) async {
    final ids = await _readUploadedReportIds();
    ids.remove(reportId);
    ids.add(reportId);
    await _storage.write(
      key: _uploadedReportIdsKey,
      value: jsonEncode(ids.take(20).toList()),
    );
  }

  String _privateBlobUrl(String reportId) =>
      'https://github.com/$_repository/blob/HEAD/playback-diagnostics/$reportId';

  Future<String> _getAccessToken() async {
    final accessToken = await _storage.read(key: _accessTokenKey);
    final expiryText = await _storage.read(key: _accessExpiryKey);
    final expiry = int.tryParse(expiryText ?? '');
    final now = DateTime.now().millisecondsSinceEpoch;

    if (accessToken != null && (expiry == null || now < expiry - 60000)) {
      return accessToken;
    }

    final refreshToken = await _storage.read(key: _refreshTokenKey);
    if (refreshToken == null) {
      throw StateError('Connect the private diagnostics GitHub App first.');
    }

    final response = await _client
        .post(
          Uri.parse(_tokenUrl),
          headers: const {'Accept': 'application/json'},
          body: {
            'client_id': _clientId,
            'grant_type': 'refresh_token',
            'refresh_token': refreshToken,
          },
        )
        .timeout(const Duration(seconds: 20));
    final payload = _decodeResponse(response);
    if (response.statusCode != 200 || payload['access_token'] is! String) {
      await disconnect();
      throw StateError(
        'GitHub refresh token expired; authorize the app again.',
      );
    }

    await _storeTokenResponse(payload, retainRefreshToken: refreshToken);
    return payload['access_token'] as String;
  }

  Future<void> _storeTokenResponse(
    Map<String, dynamic> payload, {
    String? retainRefreshToken,
  }) async {
    final accessToken = payload['access_token']?.toString();
    if (accessToken == null || accessToken.isEmpty) {
      throw StateError('GitHub did not return an access token.');
    }
    final refreshToken =
        payload['refresh_token']?.toString() ?? retainRefreshToken;
    final expiresIn = _asPositiveInt(payload['expires_in'], fallback: 28800);
    await _storage.write(key: _accessTokenKey, value: accessToken);
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await _storage.write(key: _refreshTokenKey, value: refreshToken);
    }
    await _storage.write(
      key: _accessExpiryKey,
      value: DateTime.now()
          .add(Duration(seconds: expiresIn))
          .millisecondsSinceEpoch
          .toString(),
    );
  }

  void _requireConfiguration() {
    if (!isConfigured) {
      throw StateError(
        'Private diagnostics are not configured in this APK. Set the GitHub '
        'App client ID and private diagnostics repository at release build time.',
      );
    }
  }

  static int _asPositiveInt(Object? value, {required int fallback}) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    return parsed != null && parsed > 0 ? parsed : fallback;
  }

  static Map<String, dynamic> _decodeResponse(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  static void _validateSanitizedReport(String reportJson) {
    final decoded = jsonDecode(reportJson);
    if (decoded is! Map || decoded['schemaVersion'] != 1) {
      throw StateError('Unsupported playback diagnostic report format.');
    }

    // Native storage sanitizes on write. Check again at the upload boundary.
    final forbidden = <RegExp>[
      RegExp(r'(?i)\bmagnet:\?'),
      RegExp(r'(?i)\b(?:https?|udp)://'),
      RegExp(r'\b[a-fA-F0-9]{40}\b'),
      RegExp(r'\b[A-Z2-7]{32}\b', caseSensitive: false),
      RegExp(
        r'(?i)(?:(?:[0-9a-f]{1,4}:){1,7}|:)(?::[0-9a-f]{1,4}){1,7}|::(?:[0-9a-f]{1,4}:){0,6}[0-9a-f]{1,4}',
      ),
      RegExp(
        r'(?i)(?:/data/(?:user|user_de)/\d+/|/data/data/|/data/media/\d+/|/storage/emulated/\d+/|/storage/self/primary/|/storage/[A-Fa-f0-9-]{4,}/|/mnt/sdcard/|/sdcard/)',
      ),
      RegExp(
        r'(?i)\b(?:token|authorization|password|secret|api[_-]?key)\s*[:=]\s*[^\s,;]+',
      ),
    ];
    if (forbidden.any((pattern) => pattern.hasMatch(reportJson))) {
      throw StateError(
        'The diagnostic report still contains private source/device data; upload was blocked.',
      );
    }
  }
}

class GitHubDeviceFlowChallenge {
  const GitHubDeviceFlowChallenge({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresAt,
    required this.intervalSeconds,
  });

  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final DateTime expiresAt;
  final int intervalSeconds;
}
