import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';

const Color _movieBoxRed = Color(0xFFE50914);
const Color _movieBoxCyan = Color(0xFF20DDF2);
const Color _playerSurface = Color(0xFF11131C);

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

  const PlayerScreen({
    super.key,
    required this.title,
    required this.url,
    this.initialMs = 0,
    required this.onSave,
    this.onNext,
    this.headers = const <String, String>{},
    this.isLive = false,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  BetterPlayerController? _media3;
  VlcPlayerController? _vlc;
  Timer? _saveTimer;
  Timer? _media3Watchdog;
  bool _usingVlc = false;
  bool _loading = true;
  bool _controlsVisible = true;
  bool _disposed = false;
  bool _nextCalled = false;
  bool _vlcInitStarted = false;
  String? _error;
  String _engineLabel = 'Media3 / ExoPlayer';
  int _pendingPositionMs = 0;
  int _lastSavedMs = 0;
  final FocusNode _focusNode = FocusNode(debugLabel: 'MovieBoxPlayer');

  @override
  void initState() {
    super.initState();
    _pendingPositionMs = widget.initialMs;
    unawaited(SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    _startMedia3();
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_savePosition());
    });
  }

  BetterPlayerVideoFormat? _formatHint() {
    final path = Uri.tryParse(widget.url)?.path.toLowerCase() ?? '';
    if (path.endsWith('.m3u8')) return BetterPlayerVideoFormat.hls;
    if (path.endsWith('.mpd')) return BetterPlayerVideoFormat.dash;
    if (path.endsWith('.ism') || path.endsWith('.isml')) {
      return BetterPlayerVideoFormat.ss;
    }
    return null;
  }

  bool get _isLive => widget.isLive;

  void _startMedia3() {
    if (_disposed || !mounted) return;
    _media3Watchdog?.cancel();
    _usingVlc = false;
    _loading = true;
    _error = null;
    _engineLabel = 'Media3 / ExoPlayer';
    _nextCalled = false;

    final dataSource = BetterPlayerDataSource.network(
      widget.url,
      headers: widget.headers.isEmpty ? null : widget.headers,
      liveStream: _isLive,
      useAsmsTracks: true,
      useAsmsAudioTracks: true,
      useAsmsSubtitles: true,
      videoFormat: _formatHint(),
      bufferingConfiguration: const BetterPlayerBufferingConfiguration(
        minBufferMs: 15000,
        maxBufferMs: 50000,
        bufferForPlaybackMs: 1500,
        bufferForPlaybackAfterRebufferMs: 3000,
      ),
      notificationConfiguration:
          const BetterPlayerNotificationConfiguration(showNotification: false),
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

    final configuration = BetterPlayerConfiguration(
      autoPlay: true,
      startAt: Duration(milliseconds: _pendingPositionMs),
      aspectRatio: 16 / 9,
      fit: BoxFit.contain,
      allowedScreenSleep: false,
      fullScreenByDefault: false,
      autoDetectFullscreenDeviceOrientation: true,
      handleLifecycle: true,
      autoDispose: false,
      controlsConfiguration: controls,
      eventListener: _onMedia3Event,
      errorBuilder: (context, message) => _errorPanel(
        message ?? 'Media3 could not load this source.',
        onRetry: () => _switchToVlc('Media3 reported a playback error'),
      ),
    );

    try {
      _media3?.dispose(forceDispose: true);
      _media3 = BetterPlayerController(
        configuration,
        betterPlayerDataSource: dataSource,
      );
      if (mounted) setState(() {});
      _media3Watchdog = Timer(const Duration(seconds: 35), () {
        if (mounted && !_disposed && !_usingVlc && _loading) {
          unawaited(_switchToVlc('Media3 initialization timed out'));
        }
      });
    } catch (error) {
      unawaited(_switchToVlc('Media3 setup failed: $error'));
    }
  }

  void _onMedia3Event(BetterPlayerEvent event) {
    if (!mounted || _disposed) return;
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.initialized:
        _media3Watchdog?.cancel();
        setState(() {
          _loading = false;
          _error = null;
          _engineLabel = 'Media3 / ExoPlayer';
        });
        break;
      case BetterPlayerEventType.exception:
        final details = event.parameters?.toString() ?? 'Unsupported stream or network error';
        unawaited(_switchToVlc('Media3 error: $details'));
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

  Future<void> _switchToVlc([String reason = 'Media3 fallback']) async {
    if (!mounted || _disposed || _usingVlc || _vlcInitStarted) return;
    _media3Watchdog?.cancel();

    final unsupportedVlcHeaders = widget.headers.keys.where((key) {
      final normalized = key.toLowerCase();
      return normalized != 'user-agent' && normalized != 'referer';
    }).toList();
    if (unsupportedVlcHeaders.isNotEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'This stream requires custom HTTP headers (${unsupportedVlcHeaders.join(', ')}). '
              'Media3 could not play it, and this VLC plugin version cannot forward those headers.';
        });
      }
      return;
    }

    _vlcInitStarted = true;
    final media3Value = _media3?.videoPlayerController?.value;
    if (media3Value != null && media3Value.isInitialized) {
      _pendingPositionMs = media3Value.position.inMilliseconds;
    }

    final oldMedia3 = _media3;
    _media3 = null;
    oldMedia3?.dispose(forceDispose: true);

    setState(() {
      _usingVlc = true;
      _loading = true;
      _error = null;
      _engineLabel = 'VLC compatibility engine';
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
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Media3 and VLC could not start this stream: $error';
      });
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
      setState(() {
        _loading = false;
        _error = value.errorDescription.isEmpty
            ? 'VLC could not decode or open this stream.'
            : value.errorDescription;
      });
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
      if (value == null || !value.isInitialized) return;
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
    if (controller == null || !controller.value.isInitialized || _isLive) return;
    final duration = controller.value.duration;
    if (duration <= Duration.zero) return;
    final target = controller.value.position + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > duration ? duration : target);
    await controller.seekTo(clamped);
    if (mounted) setState(() => _controlsVisible = true);
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
                  leading: const Icon(Icons.closed_caption_disabled, color: Colors.white),
                  title: const Text('Off', style: TextStyle(color: Colors.white)),
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
                  title: Text(entry.value, style: const TextStyle(color: Colors.white)),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Track list unavailable: $error')),
      );
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
              title: Text('Playback speed', style: TextStyle(color: _movieBoxCyan)),
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
      if (controller != null && value != null && value.isInitialized && !_isLive) {
        final delta = key == LogicalKeyboardKey.arrowLeft ? -10 : 10;
        final target = value.position + Duration(seconds: delta);
        final duration = value.duration;
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
          unawaited(controller.play());
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  String _timeText(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Widget _errorPanel(String message, {VoidCallback? onRetry}) {
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
            const Icon(Icons.error_outline, color: Colors.orangeAccent, size: 48),
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
              label: const Text('Retry playback'),
              style: FilledButton.styleFrom(backgroundColor: _movieBoxRed),
            ),
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
                        Text(_timeText(value.position),
                            style: const TextStyle(color: Colors.white)),
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
                        Text(_timeText(value.duration),
                            style: const TextStyle(color: Colors.white)),
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
                        value.isPlaying ? Icons.pause_circle : Icons.play_circle,
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

  @override
  void dispose() {
    // Capture the last position synchronously before the disposed guard is set.
    unawaited(_savePosition());
    _disposed = true;
    _saveTimer?.cancel();
    _media3Watchdog?.cancel();
    _media3?.dispose(forceDispose: true);

    final vlc = _vlc;
    if (vlc != null) {
      vlc.removeListener(_onVlcChanged);
      unawaited(vlc.stop());
      unawaited(vlc.dispose());
    }

    _focusNode.dispose();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    unawaited(SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]));
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
              if (_loading)
                const Align(
                  alignment: Alignment.center,
                  child: CircularProgressIndicator(color: _movieBoxCyan),
                ),
              if (_error != null)
                _errorPanel(_error!, onRetry: _retryCurrentEngine),
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
