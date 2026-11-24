package com.moviebox.nexus

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.view.WindowManager
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
            "moviebox_nexus/display"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setKeepScreenOn" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "moviebox_nexus/external_player"
        ).setMethodCallHandler { call, result ->
            if (call.method != "openVlc") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val rawUrl = call.argument<String>("url")?.trim().orEmpty()
            val uri = runCatching { Uri.parse(rawUrl) }.getOrNull()
            if (uri == null || uri.host.isNullOrBlank() || uri.scheme !in setOf("http", "https")) {
                result.error("INVALID_MEDIA_URL", "Only valid HTTP or HTTPS media URLs can be opened in VLC.", null)
                return@setMethodCallHandler
            }
            val title = call.argument<String>("title")?.takeIf { it.isNotBlank() } ?: "MovieBox Nexus"
            val positionMs = call.argument<Number>("positionMs")?.toLong()?.coerceAtLeast(0L) ?: 0L
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setPackage("org.videolan.vlc")
                setDataAndType(uri, "video/*")
                putExtra("title", title)
                putExtra(Intent.EXTRA_TITLE, title)
                putExtra("from_start", positionMs <= 0L)
                if (positionMs > 0L) putExtra("position", positionMs)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            try {
                startActivity(intent)
                result.success(true)
            } catch (_: ActivityNotFoundException) {
                result.error("VLC_NOT_INSTALLED", "VLC for Android is not installed or its media activity is unavailable.", null)
            } catch (error: Exception) {
                result.error("VLC_OPEN_FAILED", error.message ?: "Could not hand the stream to VLC.", null)
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "moviebox_nexus/torrent"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "cleanupCache" -> torrentExecutor.execute {
                    try {
                        engine().cleanupCache()
                        runOnUiThread { result.success(true) }
                    } catch (error: Throwable) {
                        runOnUiThread {
                            result.error("TORRENT_CACHE_CLEANUP_FAILED", error.message, null)
                        }
                    }
                }
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
                "getStatus" -> torrentExecutor.execute {
                    val snapshot = runCatching {
                        torrentEngine?.statusSnapshot() ?: mapOf("active" to false)
                    }.getOrElse { error ->
                        mapOf(
                            "active" to false,
                            "lastError" to (error.message ?: "Torrent diagnostics unavailable.")
                        )
                    }
                    runOnUiThread { result.success(snapshot) }
                }
                "pausePlayback" -> torrentExecutor.execute {
                    try {
                        torrentEngine?.pausePlayback()
                        runOnUiThread { result.success(true) }
                    } catch (error: Throwable) {
                        runOnUiThread { result.error("TORRENT_PAUSE_FAILED", error.message, null) }
                    }
                }
                "resumePlayback" -> torrentExecutor.execute {
                    try {
                        torrentEngine?.resumePlayback()
                        runOnUiThread { result.success(true) }
                    } catch (error: Throwable) {
                        runOnUiThread { result.error("TORRENT_RESUME_FAILED", error.message, null) }
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
