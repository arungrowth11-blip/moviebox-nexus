package com.moviebox.nexus

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val torrentExecutor = Executors.newSingleThreadExecutor()
    @Volatile private var torrentEngine: EmbeddedTorrentEngine? = null

    private fun engine(): EmbeddedTorrentEngine {
        val existing = torrentEngine
        if (existing != null) return existing
        return synchronized(this) {
            torrentEngine ?: EmbeddedTorrentEngine(applicationContext).also { torrentEngine = it }
        }
    }

    private fun normalizeTestPeerEndpoint(raw: String?): String? {
        val value = raw?.trim().orEmpty()
        val match = Regex("""^([0-9]{1,3}(?:\.[0-9]{1,3}){3}):([0-9]{1,5})$""").matchEntire(value)
            ?: return null
        val octets = match.groupValues[1].split(".").mapNotNull { it.toIntOrNull() }
        val port = match.groupValues[2].toIntOrNull() ?: return null
        if (octets.size != 4 || octets.any { it !in 0..255 } || port !in 1..65535) return null
        return value
    }

    private fun handleStartPlayback(
        call: MethodCall,
        result: MethodChannel.Result,
        testPeerEndpoint: String? = null
    ) {
        val infoHash = call.argument<String>("infoHash")
        val title = call.argument<String>("title") ?: "MovieBox Nexus stream"
        val fileIdx = call.argument<Number>("fileIdx")?.toInt()?.takeIf { it >= 0 }
        val trackers = call.argument<List<String>>("trackers") ?: emptyList()
        val normalizedHash = infoHash?.trim().orEmpty()
        val validHash = Regex("^(?:[a-fA-F0-9]{40}|[a-zA-Z2-7]{32})$").matches(normalizedHash)
        if (!validHash) {
            result.error("INVALID_INFO_HASH", "A valid 40-character hex or 32-character base32 infoHash is required.", null)
            return
        }
        torrentExecutor.execute {
            try {
                val url = engine().startPlayback(
                    normalizedHash,
                    title,
                    fileIdx,
                    trackers,
                    testPeerEndpoint
                )
                runOnUiThread { result.success(url) }
            } catch (error: Throwable) {
                runOnUiThread {
                    result.error("TORRENT_PLAYBACK_FAILED", error.message ?: "Torrent playback failed.", null)
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "moviebox_nexus/torrent"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> torrentExecutor.execute {
                    try {
                        engine().initialize()
                        runOnUiThread { result.success(true) }
                    } catch (error: Throwable) {
                        runOnUiThread {
                            result.error("TORRENT_INIT_FAILED", error.message ?: "Torrent engine initialization failed.", null)
                        }
                    }
                }
                "startPlayback" -> handleStartPlayback(call, result)
                "startPlaybackWithPeerForTest" -> {
                    if ((applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) == 0) {
                        result.error("TEST_ONLY_METHOD", "The controlled peer hook is available only in debug builds.", null)
                    } else {
                        val peer = normalizeTestPeerEndpoint(call.argument<String>("peerEndpoint"))
                        if (peer == null) {
                            result.error("INVALID_TEST_PEER", "A valid IPv4 host:port endpoint is required.", null)
                        } else {
                            handleStartPlayback(call, result, peer)
                        }
                    }
                }
                "stopPlayback" -> torrentExecutor.execute {
                    try {
                        torrentEngine?.stopPlayback()
                        runOnUiThread { result.success(true) }
                    } catch (error: Throwable) {
                        runOnUiThread { result.error("TORRENT_STOP_FAILED", error.message, null) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        if (isFinishing) {
            torrentExecutor.execute {
                try {
                    torrentEngine?.close()
                    torrentEngine = null
                } finally {
                    torrentExecutor.shutdown()
                }
            }
        }
        super.onDestroy()
    }
}
