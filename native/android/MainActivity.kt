package com.moviebox.nexus

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
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
                "startPlayback" -> {
                    val infoHash = call.argument<String>("infoHash")
                    val title = call.argument<String>("title") ?: "MovieBox Nexus stream"
                    val fileIdx = call.argument<Number>("fileIdx")?.toInt()
                        ?.takeIf { it >= 0 }
                    val normalizedHash = infoHash?.trim().orEmpty()
                    val validHash = Regex("^(?:[a-fA-F0-9]{40}|[a-zA-Z2-7]{32})$").matches(normalizedHash)
                    if (!validHash) {
                        result.error("INVALID_INFO_HASH", "A valid 40-character hex or 32-character base32 infoHash is required.", null)
                    } else {
                        torrentExecutor.execute {
                            try {
                                val url = engine().startPlayback(infoHash, title, fileIdx)
                                runOnUiThread { result.success(url) }
                            } catch (error: Throwable) {
                                runOnUiThread {
                                    result.error("TORRENT_PLAYBACK_FAILED", error.message ?: "Torrent playback failed.", null)
                                }
                            }
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
