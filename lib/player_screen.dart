import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';
import 'package:moviebox_nexus/src/diagnostics/github_diagnostics_uploader.dart';
import 'package:moviebox_nexus/src/player/media3_startup_policy.dart';

const Color _movieBoxRed = Color(0xFFE50914);
const Color _movieBoxCyan = Color(0xFF20DDF2);
const Color _playerSurface = Color(0xFF11131C);

/// Resolve a safe format hint before BetterPlayer inspects a network URL.
/// better_player_plus 1.4.1 can fail when its Android extension resolver sees
/// an extensionless source. Known adaptive formats remain explicit; extensionless
/// URLs use the plugin's generic data source rather than unsafe inference.
BetterPlayerVideoFormat? mediaFormatHintForUrl(String rawUrl) {
  final path = Uri.tryParse(rawUrl)?.path.toLowerCase() ?? '';
  if (path.endsWith('.m3u8')) return BetterPlayerVideoFormat.hls;
  if (path.endsWith('.mpd')) return BetterPlayerVideoFormat.dash;
  if (path.endsWith('.ism') || path.endsWith('.isml')) {
    return BetterPlayerVideoFormat.ss;
  }
  final lastSegment = path.split('/').last;
  final extensionSeparator = lastSegment.lastIndexOf('.');
  if (extensionSeparator <= 0 || extensionSeparator == lastSegment.length - 1) {
    return BetterPlayerVideoFormat.other;
  }
  return null;
}

/// In-app dual-engine playback:
/// 1) Media3/ExoPlayer via Better Player Plus for adaptive HLS/DASH, headers,
///    quality selection, subtitles and audio tracks.
/// 2) Embedded LibVLC fallback for additional containers/codecs supported by
///    the device's bundled LibVLC runtime.
///
/// No generic player can bypass a commercial service's DRM/license checks.
/// Torrent/magnet sources must first be resolved to an HTTP media URL.
class PlayerScreen extends StatefulWidget {
  final String title;
  final String url;
  final int initialMs;
  final Future<void> Function(int) onSave;
  final VoidCallback? onNext;
  final Map<String, String> headers;
  final bool isLive;
  final bool autoPlay;
  final ValueChanged<Duration>? onPrepared;
  final ValueChanged<BetterPlayerController>? onMedia3ControllerReady;

  const PlayerScreen({
    super.key,
    required this.title,
    required this.url,
    this.initialMs = 0,
    required this.onSave,
    this.onNext,
    this.headers = const <String, String>{},
    this.isLive = false,
    this.autoPlay = true,
    this.onPrepared,
    this.onMedia3ControllerReady,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  BetterPlayerController? _media3;
  // Serialize Media3 controller replacement; never overlap native decoders.
  Future<void> _media3Transition = Future<void>.value();
  int _media3Generation = 0;
  VlcPlayerController? _vlc;
  Timer? _saveTimer;
  Timer? _media3Watchdog;
  Timer? _media3PlaybackStartWatchdog;
  Timer? _torrentStatusTimer;
  Timer? _torrentPlaybackStallTimer;
  Timer? _torrentRecoveryResetTimer;
  Timer? _preferredHindiAudioTimer;
  bool _torrentRecoveryInProgress = false;
  bool _torrentPlaybackProgressObserved = false;
  int _torrentRecoveryAttempts = 0;
  bool _torrentFailureDiagnosticCaptured = false;
  String? _lastDiagnosticReportId;
  bool _diagnosticUploadInProgress = false;
  final GitHubDiagnosticsUploader _diagnosticUploader =
      GitHubDiagnosticsUploader();
  Duration _lastTorrentObservedPosition = Duration.zero;
  DateTime _lastTorrentProgressAt = DateTime.now();
  String _torrentStatusMessage = '';
  String _torrentTechnicalLine = '';
  static const MethodChannel _torrentDiagnostics = MethodChannel(
    'moviebox_nexus/torrent',
  );
  static const MethodChannel _externalPlayer = MethodChannel(
    'moviebox_nexus/external_player',
  );
  static const MethodChannel _display = MethodChannel('moviebox_nexus/display');
  bool _usingVlc = false;
  bool _loading = true;
  bool _controlsVisible = true;
  bool _disposed = false;
  bool _nextCalled = false;
  bool _vlcInitStarted = false;
  bool _canOpenExternalVlc = false;
  String? _error;
  String _engineLabel = 'Media3 / ExoPlayer';
  int _pendingPositionMs = 0;
  int _lastSavedMs = 0;
  DateTime _playStartedAt = DateTime.now();
  bool _preparedReported = false;
  bool _media3SetupComplete = false;
  bool _media3InitializedPending = false;
  bool _media3UsesAdaptiveTracks = false;
  bool _preferredHindiAudioApplied = false;
  final FocusNode _focusNode = FocusNode(debugLabel: 'MovieBoxPlayer');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_setPlaybackScreenAwake(true));
    _pendingPositionMs = widget.initialMs;
    unawaited(_uploadLatestDiagnosticIfConnected());
    _startMedia3();
    _startTorrentStatusPolling();
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_savePosition());
    });
  }

  /// Own Media3 lifecycle handling instead of BetterPlayer's internal gate.
  /// BetterPlayerController.play() is ignored unless its private lifecycle
  /// state is resumed. In embedded/loopback playback that state can become
  /// stale during Android activity/orientation transitions, leaving a READY
  /// player permanently paused. Keep the controller's gate open and pause/
  /// resume explicitly from this screen's actual Flutter lifecycle.
  bool _resumeMedia3AfterLifecyclePause = false;

  void _setTorrentBackgroundPaused(bool paused) {
    if (!_isEmbeddedTorrent) return;
    final method = paused ? 'pausePlayback' : 'resumePlayback';
    unawaited(
      _torrentDiagnostics.invokeMethod<void>(method).catchError((Object error) {
        debugPrint('MovieBox torrent background state change failed: $error');
      }),
    );
  }

  Future<void> _setPlaybackScreenAwake(bool enabled) async {
    try {
      await _display.invokeMethod<void>('setKeepScreenOn', <String, Object>{
        'enabled': enabled,
      });
    } on MissingPluginException {
      // Keep playback functional on platforms that do not register Android's
      // display channel (for example, a Flutter desktop test runner).
    } catch (error) {
      debugPrint('MovieBox player screen-awake update failed: $error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_setPlaybackScreenAwake(true));
      _setTorrentBackgroundPaused(false);
      if (_usingVlc) return;
      final controller = _media3;
      if (_resumeMedia3AfterLifecyclePause && controller != null) {
        _resumeMedia3AfterLifecyclePause = false;
        unawaited(() async {
          try {
            await _playMedia3Native(controller, reason: 'app resumed');
          } catch (error) {
            debugPrint('MovieBox Media3 resume failed: $error');
          }
        }());
      }
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_setPlaybackScreenAwake(false));
      _setTorrentBackgroundPaused(true);
      if (_usingVlc) return;
      final controller = _media3;
      _resumeMedia3AfterLifecyclePause = controller?.isPlaying() == true;
      if (_resumeMedia3AfterLifecyclePause && controller != null) {
        unawaited(() async {
          try {
            await controller.pause();
          } catch (error) {
            debugPrint('MovieBox Media3 background pause failed: $error');
          }
        }());
      }
    }
  }

  void _startTorrentStatusPolling() {
    if (!_isEmbeddedTorrent) return;
    _torrentStatusTimer?.cancel();
    unawaited(_refreshTorrentStatus());
    _torrentStatusTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshTorrentStatus()),
    );
  }

  Future<void> _refreshTorrentStatus() async {
    if (!mounted || _disposed || !_isEmbeddedTorrent) return;
    try {
      final snapshot = await _torrentDiagnostics
          .invokeMapMethod<String, dynamic>('getStatus')
          .timeout(const Duration(seconds: 4));
      if (!mounted || snapshot == null) return;
      int number(String key) => (snapshot[key] as num?)?.toInt() ?? 0;
      final active = snapshot['active'] == true;
      final metadataReady = snapshot['metadataReady'] == true;
      final connectedPeers = number('connectedPeers');
      final connectedSeeds = number('connectedSeeds');
      final knownPeers = number('knownPeers');
      final knownSeeds = number('knownSeeds');
      final rate = number('downloadRate');
      final downloaded = number('downloadedBytes');
      final tracker = (snapshot['currentTracker'] ?? '').toString();
      final lastError = (snapshot['lastError'] ?? '').toString();
      final httpBytesSent = number('httpBytesSent');
      final lastHttpStatus = number('lastHttpStatus');
      final lastRangeStart = number('lastHttpRangeStart');
      final lastRangeEnd = number('lastHttpRangeEnd');
      final lastRequestBytesSent = number('lastRequestBytesSent');
      final firstByteAtMs = number('firstByteAtMs');
      final lastPieceIndex = number('lastPieceIndex');
      final lastPieceWaitMs = number('lastPieceWaitMs');
      final lastHttpError = (snapshot['lastHttpError'] ?? '').toString();
      final mediaFileReady = snapshot['mediaFileReady'] == true;
      final backgroundDownloadEnabled =
          snapshot['backgroundDownloadEnabled'] == true;
      final backgroundBudgetBytes = number('backgroundDownloadBudgetBytes');
      final diskReadRequests = number('diskReadRequests');
      final diskReadCompletedPieces = number('diskReadCompletedPieces');
      final diskReadFailures = number('diskReadFailures');
      final diskReadsPending = number('diskReadsPending');
      final lastDiskReadWaitMs = number('lastDiskReadWaitMs');
      final lastDiskReadError = (snapshot['lastDiskReadError'] ?? '')
          .toString();

      String formatRate(int bytesPerSecond) {
        if (bytesPerSecond >= 1024 * 1024) {
          return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MiB/s';
        }
        if (bytesPerSecond >= 1024) {
          return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KiB/s';
        }
        return '${bytesPerSecond} B/s';
      }

      String message;
      if (lastError.isNotEmpty) {
        message = 'Torrent engine: $lastError';
      } else if (!active) {
        message = 'Starting the built-in torrent engine…';
      } else if (!metadataReady) {
        if (connectedPeers > 0) {
          message =
              'Connected to $connectedPeers peers; receiving torrent metadata…';
        } else if (knownPeers > 0) {
          message =
              'Found $knownPeers peers; waiting for a metadata connection…';
        } else {
          message = 'Discovering peers through DHT and public trackers…';
        }
      } else if (diskReadsPending > 0 && diskReadCompletedPieces == 0) {
        message =
            'Metadata ready • first piece received; waiting for local disk read completion…';
      } else if (metadataReady && downloaded > 0 && httpBytesSent == 0) {
        message =
            'Metadata ready • torrent blocks received; waiting for a complete playable piece…';
      } else if (connectedPeers > 0) {
        message =
            'Metadata ready • $connectedPeers connected peers • ${formatRate(rate)}';
      } else if (knownPeers > 0) {
        message = 'Metadata ready • $knownPeers peers discovered • connecting…';
      } else {
        message =
            'Metadata ready • waiting for a reachable peer to send verified video pieces…';
      }

      final technical = <String>[
        if (active) 'Connected: $connectedPeers peers / $connectedSeeds seeds',
        if (active) 'Discovered: $knownPeers peers / $knownSeeds seeds',
        if (active) 'Received (including partial pieces): $downloaded bytes',
        if (tracker.isNotEmpty) 'Last working tracker: $tracker',
        if (lastHttpStatus > 0) 'HTTP: $lastHttpStatus',
        if (lastRangeStart >= 0) 'Last range: $lastRangeStart-$lastRangeEnd',
        if (httpBytesSent > 0) 'Loopback body bytes sent: $httpBytesSent',
        if (lastRequestBytesSent > 0)
          'Last response bytes: $lastRequestBytesSent',
        if (firstByteAtMs > 0) 'First byte timestamp: $firstByteAtMs',
        if (mediaFileReady) 'Local sparse video file: ready',
        if (diskReadRequests > 0)
          'Disk-read ready pieces: $diskReadCompletedPieces/$diskReadRequests (pending $diskReadsPending)',
        if (diskReadFailures > 0) 'Disk-read failures: $diskReadFailures',
        if (lastDiskReadWaitMs > 0)
          'Last disk-read wait: ${lastDiskReadWaitMs}ms',
        if (lastDiskReadError.isNotEmpty) 'Disk-read error: $lastDiskReadError',
        if (metadataReady && backgroundDownloadEnabled)
          'Background movie download: active (up to ${(backgroundBudgetBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB budget)',
        if (metadataReady && !backgroundDownloadEnabled)
          'Download mode: playback window only (movie exceeds safe budget or free-space reserve)',
        if (lastPieceIndex >= 0)
          'Last requested piece: $lastPieceIndex (${lastPieceWaitMs}ms wait)',
        if (number('selectedPieceLengthBytes') > 0)
          'Piece size: ${(number('selectedPieceLengthBytes') / (1024 * 1024)).toStringAsFixed(2)} MiB',
        if (lastHttpError.isNotEmpty) 'HTTP/piece error: $lastHttpError',
      ].join(' • ');
      if (message != _torrentStatusMessage ||
          technical != _torrentTechnicalLine) {
        setState(() {
          _torrentStatusMessage = message;
          _torrentTechnicalLine = technical;
        });
      }
    } catch (error) {
      if (!mounted || _disposed) return;
      const message = 'Checking live peer status…';
      if (message != _torrentStatusMessage) {
        setState(() => _torrentStatusMessage = message);
      }
      debugPrint('MovieBox torrent status poll failed: $error');
    }
  }

  BetterPlayerVideoFormat? _formatHint() => mediaFormatHintForUrl(widget.url);

  bool get _isLive => widget.isLive;

  bool get _canSwitchToVlc {
    final uri = Uri.tryParse(widget.url);
    final supportedUri =
        uri != null &&
        {'http', 'https'}.contains(uri.scheme) &&
        uri.host.isNotEmpty;
    return supportedUri &&
        widget.headers.keys.every((key) {
          final normalized = key.toLowerCase();
          return normalized == 'user-agent' || normalized == 'referer';
        });
  }

  void _handleMedia3Problem(String reason) {
    _media3Watchdog?.cancel();
    _media3PlaybackStartWatchdog?.cancel();
    _torrentPlaybackStallTimer?.cancel();
    unawaited(() async {
      await _captureTorrentFailureDiagnostic(
        'Media3 terminal failure: $reason',
      );
      if (!mounted || _disposed) return;
      await _switchToVlc(reason);
    }());
  }

  void _offerExternalVlc(String reason) {
    final uri = Uri.tryParse(widget.url);
    final supportedUri =
        uri != null &&
        {'http', 'https'}.contains(uri.scheme) &&
        uri.host.isNotEmpty;
    final headersRequired = widget.headers.isNotEmpty;
    final externalVlcAvailable = supportedUri && !headersRequired;
    if (!mounted || _disposed) return;
    setState(() {
      _loading = false;
      _canOpenExternalVlc = externalVlcAvailable;
      _error = headersRequired
          ? 'Media3 and the in-app VLC engine could not play this source. It requires provider HTTP headers that this VLC plugin cannot forward. Choose another source or retry.'
          : externalVlcAvailable
          ? 'Media3 and the in-app VLC engine could not play this source. You can retry or open the same HTTP stream in the VLC app installed on this phone. DRM-protected streams may still be unavailable.'
          : 'Media3 and the in-app VLC engine could not start this source. Retry or choose another source.';
    });
    debugPrint('MovieBox in-app VLC fallback failed: $reason');
  }

  Future<void> _openExternalVlc() async {
    if (!_canOpenExternalVlc || _disposed) return;
    final controller = _media3;
    final position =
        controller?.videoPlayerController?.value.position.inMilliseconds ?? 0;
    try {
      await _externalPlayer.invokeMethod<bool>('openVlc', <String, Object>{
        'url': widget.url,
        'title': widget.title,
        'positionMs': position,
      });
    } on PlatformException catch (error) {
      if (!mounted || _disposed) return;
      setState(() {
        _canOpenExternalVlc = false;
        _error = error.message ?? 'The installed VLC app could not be opened.';
      });
    } catch (error) {
      if (!mounted || _disposed) return;
      setState(() {
        _canOpenExternalVlc = false;
        _error = 'Could not open the installed VLC app: $error';
      });
    }
  }

  Future<void> _captureTorrentFailureDiagnostic(String reason) async {
    if (!_isEmbeddedTorrent || _torrentFailureDiagnosticCaptured) return;
    _torrentFailureDiagnosticCaptured = true;

    final value = _media3?.videoPlayerController?.value;
    final duration = value?.duration;
    final playerSnapshot = <String, Object>{
      if (value != null) 'positionMs': value.position.inMilliseconds,
      if (duration != null) 'durationMs': duration.inMilliseconds,
      if (value != null) 'isPlaying': value.isPlaying,
      if (value != null) 'isBuffering': value.isBuffering,
      'isInitialized': value?.initialized ?? false,
    };

    try {
      final report = await _torrentDiagnostics
          .invokeMapMethod<String, dynamic>('captureFailure', <String, Object>{
            'reason': reason,
            'playerSnapshot': playerSnapshot,
          })
          .timeout(const Duration(seconds: 8));
      if (report?['saved'] == true) {
        final reportId = report?['reportId']?.toString();
        if (reportId != null && reportId.isNotEmpty) {
          _lastDiagnosticReportId = reportId;
          if (mounted) setState(() {});
          unawaited(_uploadDiagnosticIfAlreadyConnected(reportId));
        }
        debugPrint(
          'MovieBox private playback diagnostics saved: '
          '${report?['reportId']} '
          '(retained=${report?['retainedReports']}).',
        );
      } else {
        _torrentFailureDiagnosticCaptured = false;
        debugPrint('MovieBox playback diagnostic save returned no report.');
      }
    } catch (error) {
      _torrentFailureDiagnosticCaptured = false;
      debugPrint('MovieBox could not save playback diagnostics: $error');
    }
  }

  Future<void> _handleMedia3Exception(String reason) async {
    if (!_isEmbeddedTorrent) {
      _handleMedia3Problem(reason);
      return;
    }

    Map<String, dynamic>? snapshot;
    try {
      snapshot = await _torrentDiagnostics
          .invokeMapMethod<String, dynamic>('getStatus')
          .timeout(const Duration(seconds: 4));
    } catch (error) {
      debugPrint('MovieBox torrent failure diagnostics unavailable: $error');
    }

    if (!mounted || _disposed) return;
    await _captureTorrentFailureDiagnostic('Media3 exception: $reason');
    if (!mounted || _disposed) return;
    final bytesSent = (snapshot?['httpBytesSent'] as num?)?.toInt() ?? 0;
    final lastHttpStatus = (snapshot?['lastHttpStatus'] as num?)?.toInt() ?? 0;
    if (snapshot != null &&
        (lastHttpStatus == 200 ||
            lastHttpStatus == 206 ||
            lastHttpStatus == 503 ||
            lastHttpStatus == 504 ||
            bytesSent > 0)) {
      // Keep the embedded torrent source in-app. Reopen the same loopback URL
      // at the last confirmed position so the native bridge can reprioritize it.
      await _recoverEmbeddedTorrentPlayback(reason);
      return;
    }
    if (snapshot == null ||
        !Media3StartupPolicy.canFallbackToCompatibilityPlayer(
          isEmbeddedTorrent: true,
          httpBytesSent: bytesSent,
        )) {
      int number(String key) => (snapshot?[key] as num?)?.toInt() ?? 0;
      final status = number('lastHttpStatus');
      final peers = number('connectedPeers');
      final seeds = number('connectedSeeds');
      final downloaded = number('downloadedBytes');
      final piece = number('lastPieceIndex');
      final pieceWait = number('lastPieceWaitMs');
      final pieceLength = number('selectedPieceLengthBytes');
      final nativeError = (snapshot?['lastHttpError'] ?? '').toString();
      final details = <String>[
        'HTTP: ${status == 0 ? 'no response' : status}',
        'connected peers/seeds: $peers/$seeds',
        'received bytes including partial pieces: $downloaded',
        'loopback body bytes sent: $bytesSent',
        if (piece >= 0) 'requested piece: $piece (${pieceWait}ms wait)',
        if (pieceLength > 0)
          'piece size: ${(pieceLength / (1024 * 1024)).toStringAsFixed(2)} MiB',
        if (nativeError.isNotEmpty) 'torrent error: $nativeError',
      ].join(' • ');
      _media3Watchdog?.cancel();
      _media3PlaybackStartWatchdog?.cancel();
      setState(() {
        _loading = false;
        _torrentStatusMessage = snapshot == null
            ? 'Torrent diagnostics are unavailable; playback engine was not switched.'
            : 'Torrent has not delivered a complete first video piece yet.';
        _torrentTechnicalLine = details;
        _error = snapshot == null
            ? 'Media3 failed while opening the torrent stream, and native diagnostics could not be read. VLC was not started because an alternate decoder cannot fix an unverified or undelivered torrent piece. $reason'
            : 'Torrent transport has not delivered video bytes to the player. VLC was not started because it would request the same incomplete torrent stream. Retry keeps the embedded torrent source active. $details';
      });
      debugPrint(
        'MovieBox torrent transport failure (no VLC fallback): $reason; $details',
      );
      return;
    }

    // A confirmed body delivery with a frozen Media3 clock is a player stall,
    // not proof that VLC is required. Try bounded in-app recovery first.
    await _recoverEmbeddedTorrentPlayback(reason);
  }

  Future<void> _recoverEmbeddedTorrentPlayback(String reason) async {
    if (!mounted ||
        _disposed ||
        !_isEmbeddedTorrent ||
        _torrentRecoveryInProgress) {
      return;
    }
    if (_torrentRecoveryAttempts >= 2) {
      _handleMedia3Problem(
        'Embedded torrent playback remained unstable after two in-app recovery attempts. $reason',
      );
      return;
    }

    _torrentRecoveryInProgress = true;
    _torrentRecoveryAttempts++;
    final currentPosition =
        _media3?.videoPlayerController?.value.position.inMilliseconds ??
        _pendingPositionMs;
    if (currentPosition > 0) _pendingPositionMs = currentPosition;

    _media3Watchdog?.cancel();
    _media3PlaybackStartWatchdog?.cancel();
    _torrentPlaybackStallTimer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _torrentStatusMessage =
          'Recovering torrent playback at ${_timeText(Duration(milliseconds: _pendingPositionMs))}…';
    });
    debugPrint(
      'MovieBox embedded torrent recovery '
      '${_torrentRecoveryAttempts}/2 at ${_pendingPositionMs}ms: $reason',
    );

    await Future<void>.delayed(
      Duration(milliseconds: 700 * _torrentRecoveryAttempts),
    );
    if (!mounted || _disposed) {
      _torrentRecoveryInProgress = false;
      return;
    }
    _torrentRecoveryInProgress = false;
    _startMedia3();
  }

  void _retryPlayback() {
    if (_isEmbeddedTorrent) {
      _torrentFailureDiagnosticCaptured = false;
      final position =
          _media3?.videoPlayerController?.value.position.inMilliseconds;
      if (position != null && position > 0) _pendingPositionMs = position;
      _torrentRecoveryAttempts = 0;
      _torrentRecoveryInProgress = false;
    }
    _startMedia3();
  }

  void _reportPrepared() {
    if (_preparedReported || _disposed) return;
    _preparedReported = true;
    widget.onPrepared?.call(DateTime.now().difference(_playStartedAt));
  }

  bool get _isEmbeddedTorrent {
    final uri = Uri.tryParse(widget.url);
    return uri != null &&
        uri.host == '127.0.0.1' &&
        uri.path.startsWith('/stream/');
  }

  bool get _usesExtendedReadTimeout {
    if (_isEmbeddedTorrent) return true;
    return widget.headers.entries.any(
      (entry) =>
          entry.key.toLowerCase() == 'x-moviebox-torrent-stream' &&
          entry.value.toLowerCase() == 'true',
    );
  }

  /// Play through the native video controller. BetterPlayer's wrapper may
  /// suppress play() when its private lifecycle flag is stale, especially
  /// after a delayed HTTP retry while MovieBox owns lifecycle handling.
  Future<void> _playMedia3Native(
    BetterPlayerController controller, {
    required String reason,
  }) async {
    if (!mounted || _disposed || _usingVlc || !identical(_media3, controller)) {
      return;
    }
    final native = controller.videoPlayerController;
    if (native == null ||
        (native.value.duration == Duration.zero &&
            native.value.size == Size.zero)) {
      return;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.detached) {
      return;
    }
    await native.play();
    debugPrint(
      'MovieBox Media3 native play [$reason]: '
      'isPlaying=${native.value.isPlaying}, position=${native.value.position}',
    );
  }

  void _startMedia3() {
    if (_disposed || !mounted) return;
    final generation = ++_media3Generation;
    final queued = _media3Transition
        .catchError((Object error) {
          debugPrint('MovieBox previous Media3 transition failed: $error');
        })
        .then((_) => _startMedia3Serialized(generation));
    _media3Transition = queued;
    unawaited(queued);
  }

  Future<void> _disposeMedia3Safely(BetterPlayerController controller) async {
    final nativeController = controller.videoPlayerController;
    try {
      await nativeController?.pause();
    } catch (error) {
      debugPrint('MovieBox Media3 pause before release failed: $error');
    }

    // BetterPlayerController owns its VideoPlayerController. Its
    // dispose(forceDispose: true) releases that native controller internally.
    // Disposing nativeController separately here causes a double-dispose race
    // and "A VideoPlayerController was used after being disposed" on exit.
    controller.dispose(forceDispose: true);
  }

  Future<void> _startMedia3Serialized(int generation) async {
    if (_disposed || !mounted || generation != _media3Generation) return;

    final previous = _media3;
    _media3 = null;
    if (mounted) setState(() {});
    if (previous != null) {
      try {
        await _disposeMedia3Safely(previous);
      } catch (error) {
        debugPrint(
          'MovieBox old Media3 controller did not release safely: $error',
        );
        if (mounted && !_disposed && generation == _media3Generation) {
          setState(() {
            _loading = false;
            _error =
                'The previous video decoder did not release safely. '
                'MovieBox stopped the retry rather than starting a second decoder.';
          });
          await _captureTorrentFailureDiagnostic(
            'Media3 replacement stopped because previous controller disposal failed.',
          );
        }
        return;
      }
    }
    if (_disposed || !mounted || generation != _media3Generation) return;
    _preferredHindiAudioTimer?.cancel();
    _preferredHindiAudioApplied = false;
    _media3Watchdog?.cancel();
    _media3PlaybackStartWatchdog?.cancel();
    _torrentPlaybackStallTimer?.cancel();
    _torrentPlaybackProgressObserved = false;
    _vlcInitStarted = false;
    _usingVlc = false;
    _loading = true;
    _error = null;
    _engineLabel = 'Media3 / ExoPlayer';
    _canOpenExternalVlc = false;
    _nextCalled = false;
    _preparedReported = false;
    _media3SetupComplete = false;
    _media3InitializedPending = false;
    _media3UsesAdaptiveTracks = false;
    _playStartedAt = DateTime.now();

    // The loopback torrent server supports HTTP byte ranges. Make the initial
    // Media3 read explicitly request bytes from offset zero instead of relying
    // on a full-body 200 response. Media3 derives and applies a higher-priority
    // Range header for non-zero DataSpec positions, so later seeks stay ranged.
    final hasExplicitRangeHeader = widget.headers.keys.any(
      (key) => key.toLowerCase() == 'range',
    );
    // This private marker configures only Media3's local torrent read timeout.
    // DataSourceUtils strips it before forwarding HTTP request headers.
    final media3Headers = <String, String>{
      ...widget.headers,
      if (_isEmbeddedTorrent && !hasExplicitRangeHeader) 'Range': 'bytes=0-',
      if (_isEmbeddedTorrent) 'X-MovieBox-Torrent-Stream': 'true',
    };
    final formatHint = _formatHint();
    _media3UsesAdaptiveTracks =
        formatHint == BetterPlayerVideoFormat.hls ||
        formatHint == BetterPlayerVideoFormat.dash ||
        formatHint == BetterPlayerVideoFormat.ss;
    final dataSource = BetterPlayerDataSource.network(
      widget.url,
      headers: media3Headers.isEmpty ? null : media3Headers,
      liveStream: _isLive,
      useAsmsTracks: _media3UsesAdaptiveTracks,
      useAsmsAudioTracks: _media3UsesAdaptiveTracks,
      useAsmsSubtitles: _media3UsesAdaptiveTracks,
      videoFormat: formatHint,
      bufferingConfiguration: const BetterPlayerBufferingConfiguration(
        minBufferMs: 15000,
        maxBufferMs: 50000,
        bufferForPlaybackMs: 1500,
        bufferForPlaybackAfterRebufferMs: 3000,
      ),
      notificationConfiguration: const BetterPlayerNotificationConfiguration(
        showNotification: false,
      ),
    );

    final controls = BetterPlayerControlsConfiguration(
      controlBarColor: const Color(0xDD08090D),
      textColor: Colors.white,
      iconsColor: Colors.white,
      progressBarPlayedColor: _movieBoxRed,
      progressBarHandleColor: _movieBoxCyan,
      progressBarBufferedColor: Colors.white54,
      progressBarBackgroundColor: Colors.white24,
      loadingColor: _movieBoxCyan,
      controlsHideTime: const Duration(seconds: 4),
      enableFullscreen: true,
      enableMute: true,
      enableProgressText: true,
      enableProgressBar: !_isLive,
      enableProgressBarDrag: !_isLive,
      enablePlayPause: true,
      enableSkips: !_isLive,
      enableAudioTracks: true,
      enableSubtitles: true,
      enableQualities: true,
      enablePlaybackSpeed: true,
      enablePip: true,
      enableRetry: true,
      forwardSkipTimeInMilliseconds: 10000,
      backwardSkipTimeInMilliseconds: 10000,
    );

    BetterPlayerController? nextController;
    final configuration = BetterPlayerConfiguration(
      // Start only after setupDataSource has completed its initial track setup.
      autoPlay: false,
      startAt: Duration(milliseconds: _pendingPositionMs),
      aspectRatio: 16 / 9,
      fit: BoxFit.contain,
      allowedScreenSleep: false,
      fullScreenByDefault: false,
      autoDetectFullscreenDeviceOrientation: true,
      // Lifecycle is handled by _PlayerScreenState below. BetterPlayer's
      // private lifecycle gate can otherwise silently ignore play() after
      // Android activity/orientation transitions on loopback torrent streams.
      handleLifecycle: false,
      playerVisibilityChangedBehavior: (_) {},
      autoDispose: false,
      controlsConfiguration: controls,
      eventListener: (event) {
        if (_disposed ||
            generation != _media3Generation ||
            nextController == null ||
            !identical(_media3, nextController)) {
          return;
        }
        _onMedia3Event(event);
      },
      errorBuilder: (context, message) => _errorPanel(
        message ?? 'Media3 could not load this source.',
        onRetry: _retryPlayback,
      ),
    );

    try {
      if (_disposed || !mounted || generation != _media3Generation) return;
      nextController = BetterPlayerController(configuration);
      _media3 = nextController;
      if (mounted) setState(() {});
      // Cold start can require 65s for metadata, then three first-piece
      // waits (45s each) with two one-second retry gaps: 202s worst case.
      // The 120s HTTP read timeout covers metadata + one piece attempt;
      // this outer watchdog must cover the bounded retry sequence.
      final watchdogDelay = _isEmbeddedTorrent
          ? const Duration(seconds: 220)
          : const Duration(seconds: 35);
      _media3Watchdog = Timer(watchdogDelay, () {
        if (mounted && !_disposed && !_usingVlc && _loading) {
          if (_isEmbeddedTorrent) {
            unawaited(
              _handleMedia3Exception(
                'Torrent startup timed out after 220 seconds',
              ),
            );
          } else {
            _handleMedia3Problem('Media3 initialization timed out');
          }
        }
      });

      // Wait until BetterPlayer has finished its asynchronous native track
      // setup. Its initialized event can be emitted before this Future settles.
      await nextController.setupDataSource(dataSource);
      if (_disposed ||
          !mounted ||
          generation != _media3Generation ||
          !identical(_media3, nextController)) {
        return;
      }
      _media3SetupComplete = true;
      if (nextController.videoPlayerController?.value.initialized == true ||
          _media3InitializedPending) {
        _completeMedia3Initialization(nextController);
      }
    } catch (error) {
      if (_disposed || generation != _media3Generation) return;
      if (_isEmbeddedTorrent) {
        unawaited(_handleMedia3Exception('Media3 setup failed: $error'));
      } else {
        _handleMedia3Problem('Media3 setup failed: $error');
      }
    }
  }

  void _completeMedia3Initialization(BetterPlayerController controller) {
    if (!mounted ||
        _disposed ||
        !_media3SetupComplete ||
        !identical(_media3, controller) ||
        _preparedReported) {
      return;
    }
    _media3InitializedPending = false;
    _media3Watchdog?.cancel();
    widget.onMedia3ControllerReady?.call(controller);

    if (widget.autoPlay) {
      _startMedia3PlaybackStartWatchdog(controller);
      _startTorrentPlaybackStallWatchdog(controller);
      // Media3 starts only after BetterPlayer setupDataSource has completed.
      unawaited(
        _playMedia3Native(
          controller,
          reason: 'Media3 setup complete',
        ).catchError((Object error) {
          debugPrint('MovieBox Media3 initial native play failed: $error');
        }),
      );
    }

    _preferredHindiAudioApplied = false;
    if (_media3UsesAdaptiveTracks) {
      _schedulePreferredHindiAudio(controller);
    }
    _reportPrepared();
    setState(() {
      _loading = false;
      _error = null;
      _engineLabel = 'Media3 / ExoPlayer';
    });
  }

  void _onMedia3Event(BetterPlayerEvent event) {
    if (!mounted || _disposed) return;
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.initialized:
        // Do not expose the controller or start playback until setupDataSource
        // has completed its asynchronous initial track configuration.
        _media3InitializedPending = true;
        final initializedController = _media3;
        if (initializedController != null && _media3SetupComplete) {
          _completeMedia3Initialization(initializedController);
        }
        break;
      case BetterPlayerEventType.exception:
        final details =
            event.parameters?.toString() ??
            'Unsupported stream or network error';
        debugPrint('MovieBox Media3 exception: $details');
        // BetterPlayer dispatches events while iterating its listener list.
        // Defer fallback/disposal until that iteration has completed.
        scheduleMicrotask(() {
          if (mounted && !_disposed) {
            unawaited(_handleMedia3Exception('Media3 error: $details'));
          }
        });
        break;
      case BetterPlayerEventType.finished:
        if (!_nextCalled && widget.onNext != null) {
          _nextCalled = true;
          widget.onNext!.call();
        }
        break;
      default:
        break;
    }
  }

  void _startTorrentPlaybackStallWatchdog(BetterPlayerController controller) {
    if (!_isEmbeddedTorrent) return;
    _torrentPlaybackStallTimer?.cancel();
    _lastTorrentObservedPosition =
        controller.videoPlayerController?.value.position ?? Duration.zero;
    _lastTorrentProgressAt = DateTime.now();
    _torrentPlaybackProgressObserved = false;

    _torrentPlaybackStallTimer = Timer.periodic(const Duration(seconds: 5), (
      _,
    ) {
      if (!mounted ||
          _disposed ||
          _usingVlc ||
          !identical(_media3, controller)) {
        _torrentPlaybackStallTimer?.cancel();
        return;
      }
      final value = controller.videoPlayerController?.value;
      if (value == null || !value.initialized) return;

      final positionDelta = (value.position - _lastTorrentObservedPosition)
          .inMilliseconds
          .abs();
      if (positionDelta > 250) {
        _lastTorrentObservedPosition = value.position;
        _lastTorrentProgressAt = DateTime.now();
        _torrentPlaybackProgressObserved = true;
        if (_torrentRecoveryResetTimer?.isActive != true) {
          _torrentRecoveryResetTimer = Timer(const Duration(seconds: 30), () {
            if (mounted && !_disposed) _torrentRecoveryAttempts = 0;
          });
        }
        return;
      }

      // Do not treat a user pause as a transport stall. A seek/rebuffer that
      // remains buffering without clock progress is recovered after 35s.
      if (!_torrentPlaybackProgressObserved || !value.isBuffering) {
        if (!value.isBuffering) _lastTorrentProgressAt = DateTime.now();
        return;
      }
      if (DateTime.now().difference(_lastTorrentProgressAt) >=
          Media3StartupPolicy.torrentPlaybackStallTimeout) {
        _lastTorrentProgressAt = DateTime.now();
        unawaited(
          _handleMedia3Exception(
            'Torrent playback/seek remained buffering for '
            '${Media3StartupPolicy.torrentPlaybackStallTimeout.inSeconds}s.',
          ),
        );
      }
    });
  }

  void _startMedia3PlaybackStartWatchdog(BetterPlayerController controller) {
    _media3PlaybackStartWatchdog?.cancel();
    final startedAt = DateTime.now();
    final initialPosition =
        controller.videoPlayerController?.value.position ?? Duration.zero;
    var playRetryAttempted = false;
    var resolving = false;

    late final Timer watchdog;
    watchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted ||
          _disposed ||
          _usingVlc ||
          !identical(_media3, controller)) {
        watchdog.cancel();
        return;
      }
      final value = controller.videoPlayerController?.value;
      if (value == null || !value.initialized) return;
      final elapsed = DateTime.now().difference(startedAt);
      final decision = Media3StartupPolicy.evaluate(
        isPlaying: value.isPlaying,
        initialPosition: initialPosition,
        currentPosition: value.position,
        elapsed: elapsed,
        isEmbeddedTorrent: _isEmbeddedTorrent,
        isLive: _isLive,
        isExtendedReadTimeout: _usesExtendedReadTimeout,
        httpBytesSent: 0,
      );
      if (decision == Media3StartupDecision.started) {
        watchdog.cancel();
        return;
      }
      if (!playRetryAttempted && elapsed >= const Duration(seconds: 4)) {
        playRetryAttempted = true;
        unawaited(
          _playMedia3Native(
            controller,
            reason: 'startup clock retry',
          ).catchError((Object error) {
            debugPrint('MovieBox Media3 playback-start retry failed: $error');
          }),
        );
      }
      final startupTimeout = Media3StartupPolicy.timeoutFor(
        isEmbeddedTorrent: _isEmbeddedTorrent,
        isExtendedReadTimeout: _usesExtendedReadTimeout,
      );
      if (elapsed < startupTimeout || resolving) return;
      resolving = true;
      unawaited(
        _resolveMedia3StartupStall(
          controller,
          watchdog,
          startedAt,
          initialPosition,
        ),
      );
    });
    _media3PlaybackStartWatchdog = watchdog;
  }

  Future<void> _resolveMedia3StartupStall(
    BetterPlayerController controller,
    Timer watchdog,
    DateTime startedAt,
    Duration initialPosition,
  ) async {
    Map<String, dynamic> snapshot = <String, dynamic>{};
    var nativeSnapshotAvailable = false;
    if (_isEmbeddedTorrent) {
      try {
        final result = await _torrentDiagnostics
            .invokeMapMethod<String, dynamic>('getStatus')
            .timeout(const Duration(seconds: 4));
        if (result != null) {
          snapshot = result;
          nativeSnapshotAvailable = true;
        }
      } catch (error) {
        debugPrint('MovieBox first-byte diagnostics unavailable: $error');
      }
    }
    if (!mounted || _disposed || _usingVlc || !identical(_media3, controller)) {
      watchdog.cancel();
      return;
    }
    final value = controller.videoPlayerController?.value;
    if (value == null || !value.initialized) {
      watchdog.cancel();
      return;
    }
    if (_isEmbeddedTorrent && !nativeSnapshotAvailable) {
      watchdog.cancel();
      await _captureTorrentFailureDiagnostic(
        'Media3 startup stalled and native torrent diagnostics could not be read.',
      );
      if (!mounted || _disposed || !identical(_media3, controller)) return;
      setState(() {
        _loading = false;
        _error =
            'The torrent engine diagnostics could not be read. '
            'MovieBox will not guess whether video bytes arrived or switch players without evidence.';
      });
      return;
    }
    final httpBytesSent = (snapshot['httpBytesSent'] as num?)?.toInt() ?? 0;
    final decision = Media3StartupPolicy.evaluate(
      isPlaying: value.isPlaying,
      initialPosition: initialPosition,
      currentPosition: value.position,
      elapsed: DateTime.now().difference(startedAt),
      isEmbeddedTorrent: _isEmbeddedTorrent,
      isLive: _isLive,
      isExtendedReadTimeout: _usesExtendedReadTimeout,
      httpBytesSent: httpBytesSent,
    );
    if (decision == Media3StartupDecision.started) {
      watchdog.cancel();
      return;
    }
    if (decision == Media3StartupDecision.wait) return;
    watchdog.cancel();
    if (decision == Media3StartupDecision.noTorrentBytes) {
      final diagnosticStatus =
          (snapshot['lastHttpStatus'] as num?)?.toInt() ?? 0;
      await _captureTorrentFailureDiagnostic(
        'Media3 startup produced no torrent video bytes; HTTP status=$diagnosticStatus.',
      );
      if (!mounted || _disposed || !identical(_media3, controller)) return;
      int number(String key) => (snapshot[key] as num?)?.toInt() ?? 0;
      final status = number('lastHttpStatus');
      if (status == 503 || status == 504) {
        unawaited(
          _recoverEmbeddedTorrentPlayback(
            'Torrent first-piece HTTP $status retry budget was exhausted.',
          ),
        );
        return;
      }
      final peers = number('connectedPeers');
      final seeds = number('connectedSeeds');
      final knownPeers = number('knownPeers');
      final downloaded = number('downloadedBytes');
      final lastError = (snapshot['lastHttpError'] ?? '').toString();
      final tracker = (snapshot['currentTracker'] ?? '').toString();
      final details = <String>[
        'HTTP status: ${status == 0 ? 'no response' : status}',
        'loopback body bytes sent: 0',
        'torrent downloaded bytes: $downloaded',
        'connected peers/seeds: $peers/$seeds',
        'discovered peers: $knownPeers',
        if (tracker.isNotEmpty) 'tracker: $tracker',
        if (lastError.isNotEmpty) 'last piece/HTTP error: $lastError',
      ].join(' • ');
      debugPrint('MovieBox torrent first-byte failure: $details');
      setState(() {
        _loading = false;
        _torrentStatusMessage =
            'Torrent metadata/player initialized, but no video body bytes were sent.';
        _torrentTechnicalLine = details;
        _error =
            'No playable video bytes have been emitted by this torrent source yet. '
            'Peer counts and HTTP response headers do not prove that the requested video pieces arrived. '
            'Retry after the source or peer connection changes. $details';
      });
      return;
    }
    if (_isEmbeddedTorrent) {
      unawaited(
        _recoverEmbeddedTorrentPlayback(
          'Media3 playback clock stalled after '
          '${Media3StartupPolicy.timeoutFor(isEmbeddedTorrent: true).inSeconds}s; '
          'loopback body bytes sent=$httpBytesSent.',
        ),
      );
    } else {
      _handleMedia3Problem(
        'Media3 initialized but its playback clock did not advance after '
        '${Media3StartupPolicy.timeoutFor(isEmbeddedTorrent: false).inSeconds}s; '
        'trying VLC compatibility playback.',
      );
    }
  }

  /// Switch to the bundled LibVLC engine after a Media3 failure or
  /// when the user explicitly requests the compatibility player.
  Future<void> _switchToVlc([String reason = 'Media3 fallback']) async {
    if (!mounted || _disposed || _usingVlc || _vlcInitStarted) return;
    _media3Watchdog?.cancel();
    _media3PlaybackStartWatchdog?.cancel();

    final unsupportedVlcHeaders = widget.headers.keys.where((key) {
      final normalized = key.toLowerCase();
      return normalized != 'user-agent' && normalized != 'referer';
    }).toList();
    if (unsupportedVlcHeaders.isNotEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error =
              'This stream requires custom HTTP headers (${unsupportedVlcHeaders.join(', ')}). '
              'Media3 could not play it, and this VLC plugin version cannot forward those headers.';
        });
      }
      return;
    }

    _vlcInitStarted = true;
    final transitionGeneration = ++_media3Generation;
    try {
      await _media3Transition.timeout(const Duration(seconds: 12));
    } catch (error) {
      _offerExternalVlc(
        'The previous Media3 session did not settle; VLC was not started on top of it. $error',
      );
      return;
    }
    if (!mounted || _disposed || transitionGeneration != _media3Generation)
      return;
    final media3Value = _media3?.videoPlayerController?.value;
    if (media3Value != null && media3Value.initialized) {
      _pendingPositionMs = media3Value.position.inMilliseconds;
    }

    final oldMedia3 = _media3;
    _media3 = null;
    if (oldMedia3 != null) {
      try {
        await _disposeMedia3Safely(oldMedia3);
      } catch (error) {
        _offerExternalVlc('Media3 did not release its decoder safely: $error');
        return;
      }
    }
    if (!mounted || _disposed || transitionGeneration != _media3Generation)
      return;

    setState(() {
      _usingVlc = true;
      _loading = true;
      _error = null;
      _engineLabel = _isEmbeddedTorrent
          ? 'VLC torrent compatibility fallback'
          : 'VLC compatibility engine';
    });

    try {
      final vlcOptions = VlcPlayerOptions(
        http: VlcHttpOptions(<String>[
          VlcHttpOptions.httpReconnect(true),
          VlcHttpOptions.httpForwardCookies(true),
          if (widget.headers['User-Agent'] != null)
            VlcHttpOptions.httpUserAgent(widget.headers['User-Agent']!),
          if (widget.headers['Referer'] != null)
            VlcHttpOptions.httpReferrer(widget.headers['Referer']!),
        ]),
      );

      final controller = VlcPlayerController.network(
        widget.url,
        autoInitialize: true,
        autoPlay: true,
        hwAcc: HwAcc.auto,
        options: vlcOptions,
      );
      _vlc = controller;
      controller.addListener(_onVlcChanged);
      controller.addOnInitListener(() {
        if (!mounted || _disposed) return;
        if (_pendingPositionMs > 5000 && !_isLive) {
          final position = Duration(milliseconds: _pendingPositionMs);
          _pendingPositionMs = 0;
          unawaited(controller.seekTo(position));
        }
        setState(() {
          _loading = false;
          _error = null;
          _engineLabel = 'VLC compatibility engine';
        });
      });

      // A VLC source can fail after initialization; the listener below surfaces it.
      if (reason.isNotEmpty) {
        debugPrint('MovieBox player fallback: $reason');
      }
      if (mounted) setState(() {});
    } catch (error) {
      _offerExternalVlc(
        _isEmbeddedTorrent
            ? 'VLC could not open this torrent stream: $error. '
                  '$_torrentStatusMessage. $_torrentTechnicalLine. '
                  'Peer count and download rate do not prove that the requested video pieces were delivered.'
            : 'VLC could not start this stream: $error',
      );
    }
  }

  void _onVlcChanged() {
    if (!mounted || _disposed) return;
    final controller = _vlc;
    if (controller == null) return;
    final value = controller.value;

    if (value.isInitialized && _loading) {
      if (_pendingPositionMs > 5000 && !_isLive) {
        final position = Duration(milliseconds: _pendingPositionMs);
        _pendingPositionMs = 0;
        unawaited(controller.seekTo(position));
      }
      setState(() {
        _loading = false;
        _error = null;
      });
    }

    if (value.hasError) {
      final vlcReason = value.errorDescription.isEmpty
          ? 'VLC could not decode or open this stream.'
          : value.errorDescription;
      _offerExternalVlc(
        _isEmbeddedTorrent
            ? '$vlcReason. $_torrentStatusMessage. $_torrentTechnicalLine'
            : vlcReason,
      );
    }

    if (value.isEnded && !_nextCalled && widget.onNext != null) {
      _nextCalled = true;
      widget.onNext!.call();
    }
  }

  Future<void> _savePosition() async {
    if (_disposed) return;
    int position = 0;

    if (_usingVlc) {
      final controller = _vlc;
      if (controller == null || !controller.value.isInitialized) return;
      position = controller.value.position.inMilliseconds;
    } else {
      final value = _media3?.videoPlayerController?.value;
      if (value == null || !value.initialized) return;
      position = value.position.inMilliseconds;
    }

    if (_isLive || (position - _lastSavedMs).abs() < 4000) return;
    _lastSavedMs = position;
    try {
      await widget.onSave(position);
    } catch (error) {
      debugPrint('MovieBox resume save failed: $error');
    }
  }

  Future<void> _toggleVlcPlayback() async {
    final controller = _vlc;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
    if (mounted) setState(() => _controlsVisible = true);
  }

  Future<void> _seekVlc(int seconds) async {
    final controller = _vlc;
    if (controller == null || !controller.value.isInitialized || _isLive)
      return;
    final duration = controller.value.duration;
    if (duration <= Duration.zero) return;
    final target = controller.value.position + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > duration ? duration : target);
    await controller.seekTo(clamped);
    if (mounted) setState(() => _controlsVisible = true);
  }

  void _schedulePreferredHindiAudio(BetterPlayerController controller) {
    if (_disposed || _preferredHindiAudioApplied) return;
    _preferredHindiAudioTimer?.cancel();
    // Preserve the broadcaster's selected/default rendition for live channels.
    if (_isLive) {
      _preferredHindiAudioApplied = true;
      return;
    }

    var attempts = 0;
    _preferredHindiAudioTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (timer) {
        if (_disposed ||
            !mounted ||
            _usingVlc ||
            !identical(_media3, controller)) {
          timer.cancel();
          return;
        }
        attempts++;
        final tracks =
            controller.betterPlayerAsmsAudioTracks ??
            const <BetterPlayerAsmsAudioTrack>[];
        final hindi = tracks.where((track) {
          final language = (track.language ?? '').toLowerCase();
          final label = (track.label ?? '').toLowerCase();
          return language == 'hi' ||
              language == 'hin' ||
              language.startsWith('hi-') ||
              label.contains('hindi') ||
              label.contains('हिंदी');
        }).toList();

        if (hindi.isNotEmpty) {
          try {
            controller.setAudioTrack(hindi.first);
            _preferredHindiAudioApplied = true;
            timer.cancel();
            return;
          } catch (error) {
            debugPrint('MovieBox delayed Hindi audio selection failed: $error');
          }
        }

        // Adaptive manifests may publish alternate audio after the player has
        // raised its initialized event. Keep checking for six seconds, but
        // never override the user's later manual selection.
        if (attempts >= 12) {
          _preferredHindiAudioApplied = true;
          timer.cancel();
        }
      },
    );
  }

  String _audioTrackLabel(BetterPlayerAsmsAudioTrack track) {
    final label = (track.label ?? '').trim();
    final language = (track.language ?? '').trim();
    if (label.isNotEmpty && language.isNotEmpty) return '$label ($language)';
    if (label.isNotEmpty) return label;
    if (language.isNotEmpty) return language.toUpperCase();
    return 'Audio track ${track.id ?? ''}';
  }

  Future<void> _showMedia3AudioTracks() async {
    final controller = _media3;
    if (controller == null) return;
    final tracks =
        controller.betterPlayerAsmsAudioTracks ??
        const <BetterPlayerAsmsAudioTrack>[];
    if (!mounted) return;
    if (tracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This stream exposes only its default audio. Hindi/other audio can be selected only when the source publishes alternate tracks.',
          ),
        ),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _playerSurface,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                'Audio language',
                style: TextStyle(
                  color: _movieBoxCyan,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                'Hindi is preferred automatically when the stream provides it.',
                style: TextStyle(color: Colors.white60),
              ),
            ),
            for (final track in tracks)
              ListTile(
                leading: const Icon(Icons.audiotrack, color: Colors.white70),
                title: Text(
                  _audioTrackLabel(track),
                  style: const TextStyle(color: Colors.white),
                ),
                trailing: controller.betterPlayerAsmsAudioTrack == track
                    ? const Icon(Icons.check, color: _movieBoxCyan)
                    : null,
                onTap: () {
                  _preferredHindiAudioApplied = true;
                  _preferredHindiAudioTimer?.cancel();
                  controller.setAudioTrack(track);
                  Navigator.pop(sheetContext);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showVlcTracks({required bool subtitles}) async {
    final controller = _vlc;
    if (controller == null) return;

    try {
      final tracks = subtitles
          ? await controller.getSpuTracks()
          : await controller.getAudioTracks();
      if (!mounted) return;

      final entries = tracks.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));

      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: _playerSurface,
        builder: (sheetContext) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text(
                  subtitles ? 'Subtitles' : 'Audio tracks',
                  style: const TextStyle(
                    color: _movieBoxCyan,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (subtitles)
                ListTile(
                  leading: const Icon(
                    Icons.closed_caption_disabled,
                    color: Colors.white,
                  ),
                  title: const Text(
                    'Off',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    unawaited(controller.setSpuTrack(-1));
                    Navigator.pop(sheetContext);
                  },
                ),
              for (final entry in entries)
                ListTile(
                  leading: Icon(
                    subtitles ? Icons.subtitles : Icons.audiotrack,
                    color: Colors.white70,
                  ),
                  title: Text(
                    entry.value,
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    if (subtitles) {
                      unawaited(controller.setSpuTrack(entry.key));
                    } else {
                      unawaited(controller.setAudioTrack(entry.key));
                    }
                    Navigator.pop(sheetContext);
                  },
                ),
              if (entries.isEmpty)
                const ListTile(
                  title: Text(
                    'No alternate tracks are available in this stream.',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
            ],
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Track list unavailable: $error')));
    }
  }

  Future<void> _showVlcSpeed() async {
    const speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    final controller = _vlc;
    if (controller == null) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _playerSurface,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'Playback speed',
                style: TextStyle(color: _movieBoxCyan),
              ),
            ),
            for (final speed in speeds)
              ListTile(
                title: Text(
                  '${speed.toStringAsFixed(2)}×',
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  unawaited(controller.setPlaybackSpeed(speed));
                  Navigator.pop(sheetContext);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _retryCurrentEngine() async {
    if (_usingVlc) {
      final old = _vlc;
      _vlc = null;
      old?.removeListener(_onVlcChanged);
      if (old != null) {
        await old.stop();
        await old.dispose();
      }
      _vlcInitStarted = false;
      _pendingPositionMs = 0;
      _startMedia3();
    } else {
      _vlcInitStarted = false;
      if (mounted) {
        setState(() {
          _loading = true;
          _error = null;
        });
      }
      await _media3?.retryDataSource();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      Navigator.maybePop(context);
      return KeyEventResult.handled;
    }

    if (_usingVlc) {
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.gameButtonA) {
        unawaited(_toggleVlcPlayback());
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        unawaited(_seekVlc(-10));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        unawaited(_seekVlc(10));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown) {
        setState(() => _controlsVisible = !_controlsVisible);
        return KeyEventResult.handled;
      }
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final controller = _media3;
      final value = controller?.videoPlayerController?.value;
      if (controller != null &&
          value != null &&
          value.initialized &&
          !_isLive) {
        final delta = key == LogicalKeyboardKey.arrowLeft ? -10 : 10;
        final target = value.position + Duration(seconds: delta);
        final duration = value.duration;
        if (duration == null) return KeyEventResult.handled;
        final clamped = target < Duration.zero
            ? Duration.zero
            : (target > duration ? duration : target);
        unawaited(controller.seekTo(clamped));
        return KeyEventResult.handled;
      }
    } else if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA) {
      final controller = _media3;
      if (controller != null) {
        if (controller.isPlaying() == true) {
          unawaited(controller.pause());
        } else {
          unawaited(_playMedia3Native(controller, reason: 'remote play key'));
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  String _timeText(Duration? value) {
    if (value == null) return '--:--';
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Future<void> _uploadLatestDiagnosticIfConnected() async {
    if (!_diagnosticUploader.isConfigured ||
        !await _diagnosticUploader.hasStoredAuthorization) {
      return;
    }
    try {
      final latest = await _torrentDiagnostics
          .invokeMapMethod<String, dynamic>('readLatestFailureReport')
          .timeout(const Duration(seconds: 8));
      final reportId = latest?['reportId']?.toString();
      final reportJson = latest?['contents']?.toString();
      if (reportId == null || reportJson == null || reportJson.isEmpty) return;
      _lastDiagnosticReportId = reportId;
      await _diagnosticUploader.uploadReport(
        reportId: reportId,
        reportJson: reportJson,
      );
      debugPrint('MovieBox previous private failure report uploaded.');
    } catch (error) {
      debugPrint(
        'MovieBox previous private failure report upload skipped: $error',
      );
    }
  }

  Future<void> _uploadDiagnosticIfAlreadyConnected(String reportId) async {
    if (!_diagnosticUploader.isConfigured ||
        !await _diagnosticUploader.hasStoredAuthorization) {
      return;
    }
    try {
      final reportJson = await _torrentDiagnostics
          .invokeMethod<String>('readFailureReport', <String, Object>{
            'reportId': reportId,
          })
          .timeout(const Duration(seconds: 8));
      if (reportJson == null || reportJson.isEmpty) return;
      await _diagnosticUploader.uploadReport(
        reportId: reportId,
        reportJson: reportJson,
      );
      debugPrint(
        'MovieBox failure report uploaded to the private diagnostics repository.',
      );
    } catch (error) {
      debugPrint(
        'MovieBox automatic private diagnostics upload failed: $error',
      );
    }
  }

  Future<bool> _authorizePrivateDiagnostics() async {
    final challenge = await _diagnosticUploader.beginAuthorization();
    if (!mounted) return false;

    var waiting = false;
    String? authorizationError;
    final authorized = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Connect private GitHub diagnostics'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'GitHub has opened in your browser. Sign in and enter this one-time code:',
              ),
              const SizedBox(height: 12),
              SelectableText(
                challenge.userCode,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                challenge.verificationUri.toString(),
                style: const TextStyle(fontSize: 12),
              ),
              if (authorizationError != null) ...[
                const SizedBox(height: 8),
                Text(
                  authorizationError!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: waiting
                  ? null
                  : () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: waiting
                  ? null
                  : () async {
                      setDialogState(() => waiting = true);
                      try {
                        await _diagnosticUploader.completeAuthorization(
                          challenge,
                        );
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop(true);
                        }
                      } catch (error) {
                        if (dialogContext.mounted) {
                          setDialogState(() {
                            waiting = false;
                            authorizationError = error.toString();
                          });
                        }
                      }
                    },
              child: waiting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('I authorized GitHub'),
            ),
          ],
        ),
      ),
    );
    return authorized == true;
  }

  Future<void> _uploadPrivateDiagnostic() async {
    final reportId = _lastDiagnosticReportId;
    if (reportId == null || _diagnosticUploadInProgress) return;
    if (!_diagnosticUploader.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Private GitHub diagnostics are not configured in this APK.',
          ),
        ),
      );
      return;
    }

    setState(() => _diagnosticUploadInProgress = true);
    try {
      if (!await _diagnosticUploader.hasStoredAuthorization) {
        final authorized = await _authorizePrivateDiagnostics();
        if (!authorized) return;
      }
      final reportJson = await _torrentDiagnostics
          .invokeMethod<String>('readFailureReport', <String, Object>{
            'reportId': reportId,
          })
          .timeout(const Duration(seconds: 8));
      if (reportJson == null || reportJson.isEmpty) {
        throw StateError('The private failure report is no longer available.');
      }
      final uploadedUrl = await _diagnosticUploader.uploadReport(
        reportId: reportId,
        reportJson: reportJson,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Sanitized diagnostic uploaded to the private GitHub repository.',
          ),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () => launchUrl(
              Uri.parse(uploadedUrl),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Private diagnostic upload failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _diagnosticUploadInProgress = false);
    }
  }

  Widget _errorPanel(
    String message, {
    VoidCallback? onRetry,
    VoidCallback? onOpenInVlc,
  }) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 620),
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: _playerSurface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              color: Colors.orangeAccent,
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
            const SizedBox(height: 8),
            const Text(
              'Some streams require a valid source URL, request headers, a compatible codec, or an authorized DRM license.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry in MovieBox'),
              style: FilledButton.styleFrom(backgroundColor: _movieBoxRed),
            ),
            if (_isEmbeddedTorrent && _lastDiagnosticReportId != null) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _diagnosticUploadInProgress
                    ? null
                    : () => unawaited(_uploadPrivateDiagnostic()),
                icon: _diagnosticUploadInProgress
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_upload_outlined),
                label: Text(
                  _diagnosticUploadInProgress
                      ? 'Uploading private diagnostics…'
                      : 'Upload sanitized diagnostics to GitHub',
                ),
              ),
            ],
            if (onOpenInVlc != null) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: onOpenInVlc,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open in installed VLC'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _vlcControls() {
    final controller = _vlc!;
    final value = controller.value;
    final durationMs = value.duration.inMilliseconds;
    final positionMs = value.position.inMilliseconds.clamp(
      0,
      durationMs > 0 ? durationMs : 0,
    );
    final maxValue = durationMs > 0 ? durationMs.toDouble() : 1.0;

    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !_controlsVisible,
        child: AnimatedOpacity(
          opacity: _controlsVisible ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Color(0xAA000000),
                  Colors.transparent,
                  Color(0xDD000000),
                ],
                stops: <double>[0, 0.45, 1],
              ),
            ),
            child: Column(
              children: [
                SafeArea(
                  bottom: false,
                  child: Row(
                    children: [
                      IconButton(
                        autofocus: true,
                        onPressed: () => Navigator.maybePop(context),
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                      ),
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 14),
                        child: Text(
                          'VLC ENGINE',
                          style: TextStyle(
                            color: _movieBoxCyan,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (!_isLive)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      children: [
                        Text(
                          _timeText(value.position),
                          style: const TextStyle(color: Colors.white),
                        ),
                        Expanded(
                          child: Slider(
                            value: positionMs.toDouble().clamp(0.0, maxValue),
                            max: maxValue,
                            activeColor: _movieBoxRed,
                            inactiveColor: Colors.white38,
                            onChanged: durationMs <= 0
                                ? null
                                : (next) => unawaited(
                                    controller.seekTo(
                                      Duration(milliseconds: next.round()),
                                    ),
                                  ),
                          ),
                        ),
                        Text(
                          _timeText(value.duration),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: 'Back 10 seconds',
                      iconSize: 38,
                      onPressed: _isLive ? null : () => _seekVlc(-10),
                      icon: const Icon(Icons.replay_10, color: Colors.white),
                    ),
                    const SizedBox(width: 24),
                    IconButton(
                      tooltip: value.isPlaying ? 'Pause' : 'Play',
                      iconSize: 62,
                      onPressed: _toggleVlcPlayback,
                      icon: Icon(
                        value.isPlaying
                            ? Icons.pause_circle
                            : Icons.play_circle,
                        color: _movieBoxRed,
                      ),
                    ),
                    const SizedBox(width: 24),
                    IconButton(
                      tooltip: 'Forward 10 seconds',
                      iconSize: 38,
                      onPressed: _isLive ? null : () => _seekVlc(10),
                      icon: const Icon(Icons.forward_10, color: Colors.white),
                    ),
                    if (widget.onNext != null)
                      IconButton(
                        tooltip: 'Next episode',
                        iconSize: 36,
                        onPressed: widget.onNext,
                        icon: const Icon(Icons.skip_next, color: Colors.white),
                      ),
                  ],
                ),
                SafeArea(
                  top: false,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: () => _showVlcTracks(subtitles: false),
                        icon: const Icon(Icons.audiotrack),
                        label: const Text('Audio'),
                      ),
                      TextButton.icon(
                        onPressed: () => _showVlcTracks(subtitles: true),
                        icon: const Icon(Icons.subtitles),
                        label: const Text('Subtitles'),
                      ),
                      TextButton.icon(
                        onPressed: _showVlcSpeed,
                        icon: const Icon(Icons.speed),
                        label: const Text('Speed'),
                      ),
                      TextButton.icon(
                        onPressed: _retryCurrentEngine,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
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

  Future<void> _releasePlayerResources() async {
    ++_media3Generation;
    try {
      await _media3Transition.timeout(const Duration(seconds: 12));
    } catch (error) {
      debugPrint(
        'MovieBox Media3 transition did not settle during exit: $error',
      );
      return;
    }

    final media3 = _media3;
    _media3 = null;
    if (media3 != null) {
      try {
        await _disposeMedia3Safely(media3);
      } catch (error) {
        debugPrint('MovieBox Media3 disposal during exit failed: $error');
        return;
      }
    }

    final vlc = _vlc;
    _vlc = null;
    if (vlc != null) {
      try {
        await _releaseVlcSafely(vlc);
      } catch (error) {
        debugPrint('MovieBox VLC disposal during exit failed: $error');
        return;
      }
    }

    if (_isEmbeddedTorrent) {
      try {
        await _torrentDiagnostics
            .invokeMethod<void>('stopPlayback')
            .timeout(const Duration(seconds: 20));
      } catch (error) {
        debugPrint(
          'MovieBox torrent cleanup after player release failed: $error',
        );
      }
    }
  }

  Future<void> _releaseVlcSafely(VlcPlayerController controller) async {
    try {
      controller.removeListener(_onVlcChanged);
    } catch (error) {
      debugPrint('MovieBox VLC listener cleanup failed: $error');
    }

    try {
      if (controller.value.isInitialized) {
        await controller.stop();
      }
    } catch (error) {
      // VLC may report a stale initialized value while native setup is still
      // unwinding. Do not let that prevent the controller from being disposed.
      debugPrint('MovieBox VLC stop during cleanup was skipped: $error');
    }

    try {
      await controller.dispose();
    } catch (error) {
      debugPrint('MovieBox VLC dispose cleanup failed: $error');
    }
  }

  @override
  void dispose() {
    // Capture the last position synchronously before the disposed guard is set.
    unawaited(_savePosition());
    _disposed = true;
    unawaited(_setPlaybackScreenAwake(false));
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _media3Watchdog?.cancel();
    _media3PlaybackStartWatchdog?.cancel();
    _torrentStatusTimer?.cancel();
    _torrentPlaybackStallTimer?.cancel();
    _torrentRecoveryResetTimer?.cancel();
    _preferredHindiAudioTimer?.cancel();
    // Native decoders release before stopPlayback closes the torrent server.
    unawaited(_releasePlayerResources());

    _focusNode.dispose();
    // The route owner restores system bars and the catalog orientation only
    // after Navigator.push completes; do not rotate while the native surface
    // is being torn down.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (_usingVlc) {
              setState(() => _controlsVisible = !_controlsVisible);
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_usingVlc && _vlc != null)
                Center(
                  child: VlcPlayer(
                    controller: _vlc!,
                    aspectRatio: _vlc!.value.aspectRatio > 0
                        ? _vlc!.value.aspectRatio
                        : 16 / 9,
                    placeholder: const Center(
                      child: CircularProgressIndicator(color: _movieBoxCyan),
                    ),
                  ),
                )
              else if (_media3 != null)
                Positioned.fill(child: BetterPlayer(controller: _media3!))
              else
                const Center(
                  child: CircularProgressIndicator(color: _movieBoxCyan),
                ),
              if (_usingVlc && _vlc != null) _vlcControls(),
              if (_loading) ...[
                const Align(
                  alignment: Alignment.center,
                  child: CircularProgressIndicator(color: _movieBoxCyan),
                ),
                if (_isEmbeddedTorrent)
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 72,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _torrentStatusMessage.isEmpty
                                  ? 'Connecting to the real BitTorrent swarm…'
                                  : _torrentStatusMessage,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                                height: 1.35,
                              ),
                            ),
                            if (_torrentTechnicalLine.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                _torrentTechnicalLine,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 10,
                                  height: 1.3,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
              if (_error != null)
                _errorPanel(
                  _error!,
                  onRetry: _retryCurrentEngine,
                  onOpenInVlc: _canOpenExternalVlc ? _openExternalVlc : null,
                ),
              if (!_usingVlc && _media3 != null && _canSwitchToVlc)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 4,
                  right: 58,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: IconButton(
                      tooltip: 'Switch to VLC compatibility player',
                      onPressed: () => unawaited(
                        _switchToVlc('User selected VLC compatibility player'),
                      ),
                      icon: const Icon(
                        Icons.switch_video,
                        color: _movieBoxCyan,
                      ),
                    ),
                  ),
                ),
              if (!_usingVlc && _media3 != null)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 4,
                  right: 10,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: IconButton(
                      tooltip: 'Audio language',
                      onPressed: _showMedia3AudioTracks,
                      icon: const Icon(Icons.audiotrack, color: _movieBoxCyan),
                    ),
                  ),
                ),
              if (!_usingVlc && _media3 != null)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 4,
                  left: 10,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Text(
                        _engineLabel,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
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
