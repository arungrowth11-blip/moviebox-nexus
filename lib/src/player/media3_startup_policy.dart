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
    required int httpBytesSent,
  }) {
    if (isPlaying || currentPosition > initialPosition + progressThreshold) {
      return Media3StartupDecision.started;
    }
    if (elapsed < startupTimeout) return Media3StartupDecision.wait;
    if (isEmbeddedTorrent && httpBytesSent <= 0) {
      return Media3StartupDecision.noTorrentBytes;
    }
    return Media3StartupDecision.useCompatibilityPlayer;
  }
}
