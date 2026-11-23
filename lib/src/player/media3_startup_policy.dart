/// Decisions for a Media3 player that reports initialized but never starts.
enum Media3StartupDecision {
  wait,
  started,
  noTorrentBytes,
  useCompatibilityPlayer,
}

/// Keeps initialization separate from actual playback readiness.
///
/// For embedded torrents, the loopback server's body-byte counter distinguishes
/// a transport/peer stall from a decoder/player stall.
class Media3StartupPolicy {
  static const Duration startupTimeout = Duration(seconds: 20);
  // Three 45-second first-piece attempts plus bounded retry gaps and cleanup margin.
  static const Duration torrentStartupTimeout = Duration(seconds: 140);
  // Must outlive the plugin's 240s extended HTTP read timeout plus cleanup.
  static const Duration extendedReadStartupTimeout = Duration(seconds: 260);
  static const Duration torrentPlaybackStallTimeout = Duration(seconds: 35);

  static Duration timeoutFor({
    required bool isEmbeddedTorrent,
    bool isExtendedReadTimeout = false,
  }) {
    if (isExtendedReadTimeout) return extendedReadStartupTimeout;
    return isEmbeddedTorrent ? torrentStartupTimeout : startupTimeout;
  }
  static const Duration progressThreshold = Duration(milliseconds: 700);

  /// A different decoder cannot repair a torrent transport that has emitted no
  /// video bytes. Keep embedded torrent failures on the Media3 retry path.
  static bool canFallbackToCompatibilityPlayer({
    required bool isEmbeddedTorrent,
    required int httpBytesSent,
  }) {
    return !isEmbeddedTorrent || httpBytesSent > 0;
  }

  static Media3StartupDecision evaluate({
    required bool isPlaying,
    required Duration initialPosition,
    required Duration currentPosition,
    required Duration elapsed,
    required bool isEmbeddedTorrent,
    bool isLive = false,
    bool isExtendedReadTimeout = false,
    required int httpBytesSent,
  }) {
    // A VOD/torrent controller can report isPlaying=true while its native
    // decoder clock is stuck at 0:00. Only actual position movement proves
    // progress for finite media. Live feeds may not expose a stable timeline,
    // so their active playing state remains the startup signal.
    if (currentPosition > initialPosition + progressThreshold ||
        (isLive && isPlaying)) {
      return Media3StartupDecision.started;
    }
    if (elapsed < timeoutFor(
      isEmbeddedTorrent: isEmbeddedTorrent,
      isExtendedReadTimeout: isExtendedReadTimeout,
    )) {
      return Media3StartupDecision.wait;
    }
    if (isEmbeddedTorrent && httpBytesSent <= 0) {
      return Media3StartupDecision.noTorrentBytes;
    }
    return Media3StartupDecision.useCompatibilityPlayer;
  }
}
