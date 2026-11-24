package com.moviebox.nexus

import android.content.Context
import android.util.Log
import android.webkit.MimeTypeMap
import com.frostwire.jlibtorrent.Priority
import com.frostwire.jlibtorrent.SessionManager
import com.frostwire.jlibtorrent.TorrentFlags
import com.frostwire.jlibtorrent.TorrentHandle
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.RandomAccessFile
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.net.URLEncoder
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * One in-process libtorrent session and a localhost HTTP byte-range endpoint.
 *
 * Selected media files download sequentially. HTTP ranges are served only after
 * libtorrent reports each backing piece as complete, so the player never reads
 * the sparse/preallocated zero-filled areas of an incomplete file.
 */
internal class DeferredTorrentCleanupTask(
    private val awaitStartup: () -> Unit,
    private val awaitReaders: () -> Unit,
    private val cleanup: () -> Boolean,
    private val retryDelayMs: Long = 250L
) {
    fun run() {
        var interrupted = false
        fun awaitUninterruptibly(action: () -> Unit) {
            while (true) {
                try {
                    action()
                    return
                } catch (_: InterruptedException) {
                    // Keep the cleanup obligation alive even if shutdown interrupts this worker.
                    interrupted = true
                }
            }
        }

        try {
            awaitUninterruptibly(awaitStartup)
            awaitUninterruptibly(awaitReaders)
            while (true) {
                var cleaned = false
                try {
                    cleaned = cleanup()
                } catch (_: InterruptedException) {
                    interrupted = true
                }
                if (cleaned) return
                awaitUninterruptibly { Thread.sleep(retryDelayMs) }
            }
        } finally {
            if (interrupted) Thread.currentThread().interrupt()
        }
    }
}

internal class EmbeddedTorrentEngine(private val context: Context) {
    private val lock = Any()
    private val requestPool = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "moviebox-torrent-http").apply { isDaemon = true }
    }
    private val activeHttpSockets = CopyOnWriteArraySet<Socket>()
    private val deferredCleanupHashes = ConcurrentHashMap.newKeySet<String>()
    private val cleanupExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "moviebox-torrent-cleanup").apply { isDaemon = true }
    }
    private val torrentCacheRoot = File(context.cacheDir, TorrentCachePolicy.DIRECTORY_NAME)

    @Volatile private var session: SessionManager? = null
    @Volatile private var activeHandle: TorrentHandle? = null
    @Volatile private var activePending: PendingStream? = null
    @Volatile private var startupTask: Future<*>? = null
    @Volatile private var serverSocket: ServerSocket? = null
    @Volatile private var playbackPaused = false
    private val startupExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "moviebox-torrent-startup").apply { isDaemon = true }
    }

    private data class StreamTarget(
        val handle: TorrentHandle,
        val file: File,
        val fileSize: Long,
        val fileOffset: Long,
        val pieceLength: Int,
        val firstPiece: Int,
        val lastPiece: Int,
        val token: String
    )

    private class PendingStream(
        val token: String,
        val infoHash: String,
        val storageDir: File
    ) {
        val ready = CountDownLatch(1)
        val startupStarted = AtomicBoolean(false)
        val startupFinished = CountDownLatch(1)
        val activeReaders = AtomicLong(0L)
        val httpRequestCount = AtomicLong(0L)
        val httpBytesSent = AtomicLong(0L)
        val requestGeneration = AtomicLong(0L)
        val priorityLock = Any()
        val prioritizedPieces = linkedSetOf<Int>()
        @Volatile var target: StreamTarget? = null
        @Volatile var error: String? = null
        @Volatile var lastHttpStatus = 0
        @Volatile var lastHttpRangeStart = -1L
        @Volatile var lastHttpRangeEnd = -1L
        @Volatile var lastRequestBytesSent = 0L
        @Volatile var firstByteAtMs = 0L
        @Volatile var lastPieceIndex = -1
        @Volatile var lastPieceWaitMs = 0L
        @Volatile var lastHttpError = ""
        @Volatile var cancelled = false
    }

    fun cleanupCache() {
        synchronized(lock) {
            // Never remove the currently active stream while an Activity/Flutter
            // engine is being recreated. An abandoned previous-process stream has
            // no in-memory PendingStream and is safe to sweep here.
            // A stopped stream may still have readers closing on the deferred
            // cleanup worker. Never sweep its directory during Activity/engine recreation.
            val currentClean = if (activePending == null && deferredCleanupHashes.isEmpty()) {
                TorrentCachePolicy.clearRoot(torrentCacheRoot, context.cacheDir)
            } else {
                true
            }
            val legacyRoot = File(context.filesDir, TorrentCachePolicy.DIRECTORY_NAME)
            val legacyClean = TorrentCachePolicy.clearRoot(legacyRoot, context.filesDir)
            if (!currentClean || !legacyClean) {
                Log.w(TAG, "One or more stale torrent cache directories could not be fully removed.")
            }
        }
    }

    fun initialize() {
        synchronized(lock) {
            if (session != null) return
            cleanupCache()
            val manager = SessionManager()
            manager.start()
            session = manager
        }
    }

    /**
     * Returns a loopback URL immediately. Magnet metadata discovery runs on a
     * dedicated worker; the HTTP endpoint waits for the selected file to become
     * ready. This keeps Flutter responsive and lets the player show buffering
     * while peers and metadata are being discovered.
     */
    fun pausePlayback() {
        synchronized(lock) {
            playbackPaused = true
            val pending = activePending ?: return
            val handle = activeHandle ?: session?.getTorrentHandles()?.firstOrNull {
                runCatching { it.infoHash().toHex().equals(pending.infoHash, ignoreCase = true) }
                    .getOrDefault(false)
            }
            if (handle != null) {
                runCatching {
                    // Auto-managed torrents may be resumed automatically by libtorrent.
                    handle.unsetFlags(TorrentFlags.AUTO_MANAGED)
                    handle.pause()
                }.onFailure { error ->
                    Log.w(TAG, "Could not pause torrent while app is backgrounded", error)
                }
            }
        }
    }

    fun resumePlayback() {
        synchronized(lock) {
            playbackPaused = false
            val pending = activePending ?: return
            val handle = activeHandle ?: session?.getTorrentHandles()?.firstOrNull {
                runCatching { it.infoHash().toHex().equals(pending.infoHash, ignoreCase = true) }
                    .getOrDefault(false)
            }
            if (handle != null) {
                runCatching {
                    handle.unsetFlags(TorrentFlags.AUTO_MANAGED)
                    handle.resume()
                }.onFailure { error ->
                    Log.w(TAG, "Could not resume torrent after app foregrounded", error)
                }
            }
        }
    }

    fun startPlayback(
        infoHash: String,
        title: String,
        fileIdx: Int?,
        suppliedTrackers: List<String> = emptyList(),
        testPeerEndpoint: String? = null
    ): String {
        initialize()
        val hashHex = normalizeInfoHash(infoHash)
        stopPlayback()
        check(hashHex !in deferredCleanupHashes) {
            "Previous playback for this torrent is still closing its readers; retry playback shortly."
        }
        playbackPaused = false

        val manager = session ?: throw IllegalStateException("Torrent session did not initialize.")
        val saveDir = File(torrentCacheRoot, hashHex)
        if (saveDir.exists() && !TorrentCachePolicy.deleteStreamDirectory(saveDir, torrentCacheRoot)) {
            throw IllegalStateException("Unable to clear stale temporary torrent data.")
        }
        if (!saveDir.exists() && !saveDir.mkdirs()) {
            throw IllegalStateException("Unable to create the app's torrent cache directory.")
        }

        val pending = PendingStream(
            token = UUID.randomUUID().toString().replace("-", ""),
            infoHash = hashHex,
            storageDir = saveDir
        )
        startHttpServer(pending)
        activePending = pending
        val port = serverSocket?.localPort
            ?: throw IllegalStateException("Unable to start the local torrent stream server.")

        startupTask = startupExecutor.submit {
            if (!pending.startupStarted.compareAndSet(false, true) ||
                Thread.currentThread().isInterrupted || activePending !== pending
            ) {
                pending.ready.countDown()
                pending.startupFinished.countDown()
                return@submit
            }
            var discoveredHandle: TorrentHandle? = null
            try {
                val encodedTitle = URLEncoder.encode(title.take(160), "UTF-8")
                val defaultTrackers = listOf(
                    "udp://tracker.opentrackr.org:1337/announce",
                    "udp://open.stealth.si:80/announce",
                    "udp://open.demonii.com:1337/announce",
                    "udp://exodus.desync.com:6969/announce"
                )
                val trackers = (suppliedTrackers + defaultTrackers)
                    .map { it.trim() }
                    .filter { isSafeTracker(it) }
                    .distinct()
                    .take(32)
                val magnet = buildString {
                    append("magnet:?xt=urn:btih:")
                    append(hashHex)
                    append("&dn=")
                    append(encodedTitle)
                    trackers.forEach { tracker ->
                        append("&tr=")
                        append(URLEncoder.encode(tracker, "UTF-8"))
                    }
                    // Debug-only CI hook: x.pe supplies a direct peer endpoint,
                    // so metadata and pieces can be tested without public trackers
                    // or an unpredictable Internet swarm.
                    if (testPeerEndpoint != null) {
                        append("&x.pe=")
                        // BEP 9 defines x.pe as a literal host:port token. libtorrent parses
                        // this value directly as an endpoint and does not URL-decode it;
                        // encoding the colon makes the peer silently disappear.
                        append(testPeerEndpoint)
                    }
                }

                // Keep libtorrent auto-managed but do not force sequential mode:
                // first-frame startup and distant seeks explicitly reprioritize
                // the viewer's requested piece via piecePriority/deadlines below.
                val flags = TorrentFlags.AUTO_MANAGED
                manager.download(magnet, saveDir, flags)

                val deadline = System.currentTimeMillis() + METADATA_TIMEOUT_MS
                var torrentHandle: TorrentHandle? = null
                var torrentInfo: com.frostwire.jlibtorrent.TorrentInfo? = null
                var dhtAnnounced = false
                while (System.currentTimeMillis() < deadline) {
                    if (Thread.currentThread().isInterrupted || activePending !== pending) {
                        throw InterruptedException("Torrent startup was cancelled.")
                    }
                    val candidate = manager.getTorrentHandles().firstOrNull {
                        runCatching {
                            it.infoHash().toHex().equals(hashHex, ignoreCase = true)
                        }.getOrDefault(false)
                    }
                    if (candidate != null) {
                        discoveredHandle = candidate
                        if (!dhtAnnounced) {
                            runCatching { candidate.forceDHTAnnounce() }
                            dhtAnnounced = true
                        }
                        val candidateInfo = runCatching { candidate.torrentFile() }.getOrNull()
                        if (candidateInfo != null && candidateInfo.isValid()) {
                            torrentHandle = candidate
                            torrentInfo = candidateInfo
                            break
                        }
                    }
                    Thread.sleep(350)
                }

                val handle = torrentHandle
                    ?: throw IllegalStateException(
                        "Torrent metadata was not received. The swarm may have no reachable peers."
                    )
                val info = torrentInfo
                    ?: throw IllegalStateException("Torrent metadata is invalid.")
                val target = prepareStreamTarget(handle, info, saveDir, fileIdx, pending.token)

                synchronized(lock) {
                    if (Thread.currentThread().isInterrupted || activePending !== pending) {
                        runCatching { manager.remove(handle) }
                        return@submit
                    }
                    if (playbackPaused) {
                        runCatching {
                            handle.unsetFlags(TorrentFlags.AUTO_MANAGED)
                            handle.pause()
                        }.onFailure { error ->
                            Log.w(TAG, "Could not keep torrent paused during startup", error)
                        }
                    }
                    activeHandle = handle
                    pending.target = target
                }
            } catch (error: Throwable) {
                discoveredHandle?.let { runCatching { manager.remove(it) } }
                if (activePending === pending && error !is InterruptedException) {
                    val failure = "${error.javaClass.simpleName}: ${error.message ?: "No error message."}".take(512)
                    pending.error = failure
                    Log.e(TAG, "Torrent startup failed for $hashHex: $failure", error)
                }
            } finally {
                try {
                    pending.ready.countDown()
                    // Failed or cancelled startups never become playable. Do not
                    // retain partial pieces or a preallocated media file.
                    if (pending.target == null || activePending !== pending) {
                        val removed = runCatching {
                            TorrentCachePolicy.deleteStreamDirectory(saveDir, torrentCacheRoot)
                        }.getOrDefault(false)
                        if (!removed) {
                            Log.w(TAG, "Could not remove failed/cancelled torrent cache: " + saveDir.name)
                        }
                    }
                } finally {
                    pending.startupFinished.countDown()
                }
            }
        }

        return "http://127.0.0.1:$port/stream/${pending.token}"
    }

    private fun prepareStreamTarget(
        torrentHandle: TorrentHandle,
        torrentInfo: com.frostwire.jlibtorrent.TorrentInfo,
        saveDir: File,
        fileIdx: Int?,
        token: String
    ): StreamTarget {
        val storage = torrentInfo.files()
        val videoExtensions = setOf(
            "mp4", "mkv", "m4v", "mov", "avi", "webm", "ts",
            "mpeg", "mpg", "wmv", "flv", "ogv", "m2ts"
        )
        val candidates = (0 until storage.numFiles()).mapNotNull { index ->
            val relativePath = storage.filePath(index)
            val extension = relativePath.substringAfterLast('.', "").lowercase(Locale.US)
            val size = storage.fileSize(index)
            if (size < MIN_VIDEO_BYTES || extension !in videoExtensions) {
                null
            } else {
                Triple(index, relativePath, size)
            }
        }
        val selected = if (fileIdx != null) {
            candidates.firstOrNull { it.first == fileIdx }
                ?: throw IllegalStateException(
                    "Add-on selected video file index $fileIdx, but that file is not a supported video."
                )
        } else {
            candidates.maxByOrNull { it.third }
                ?: throw IllegalStateException("This torrent contains no supported video file.")
        }

        // Start with every file ignored. The player activates only the current
        // byte-range piece and a small look-ahead window as it reads.
        torrentHandle.prioritizeFiles(
            TorrentDownloadPriorityPolicy.filePriorities(storage.numFiles())
        )

        val selectedFileOffset = storage.fileOffset(selected.first)
        val firstPiece = (selectedFileOffset / torrentInfo.pieceLength()).toInt()
        val lastPiece = ((selectedFileOffset + selected.third - 1L) / torrentInfo.pieceLength()).toInt()
        val canonicalRoot = saveDir.canonicalFile
        val mediaFile = File(saveDir, selected.second).canonicalFile
        if (!mediaFile.path.startsWith(canonicalRoot.path + File.separator)) {
            throw SecurityException("Torrent metadata contains an unsafe file path.")
        }
        return StreamTarget(
            handle = torrentHandle,
            file = mediaFile,
            fileSize = selected.third,
            fileOffset = selectedFileOffset,
            pieceLength = torrentInfo.pieceLength(),
            firstPiece = firstPiece,
            lastPiece = lastPiece,
            token = token
        )
    }

    /**
     * Lightweight live diagnostics for the currently starting/playing torrent.
     * Counts come from libtorrent's local session state, not provider metadata.
     */
    fun statusSnapshot(): Map<String, Any> {
        val pending = activePending ?: return mapOf("active" to false)
        val handle = activeHandle ?: session?.getTorrentHandles()?.firstOrNull {
            runCatching { it.infoHash().toHex().equals(pending.infoHash, ignoreCase = true) }
                .getOrDefault(false)
        }
        if (handle == null) {
            return mapOf(
                "active" to true, "metadataReady" to false,
                "connectedPeers" to 0, "connectedSeeds" to 0,
                "knownPeers" to 0, "knownSeeds" to 0,
                "downloadRate" to 0, "downloadedBytes" to 0L,
                "currentTracker" to "", "lastError" to (pending.error ?: "")
            ) + httpDiagnostics(pending)
        }
        // Include in-flight blocks: default counters can stay at zero until a full piece completes.
        val status = runCatching {
            handle.status(TorrentHandle.QUERY_ACCURATE_DOWNLOAD_COUNTERS)
        }.getOrNull()
        if (status == null) {
            return mapOf(
                "active" to true, "metadataReady" to (pending.target != null),
                "connectedPeers" to 0, "connectedSeeds" to 0,
                "knownPeers" to 0, "knownSeeds" to 0,
                "downloadRate" to 0, "downloadedBytes" to 0L,
                "currentTracker" to "",
                "lastError" to (pending.error ?: "Torrent status is temporarily unavailable.")
            ) + httpDiagnostics(pending)
        }
        return mapOf(
            "active" to true,
            "metadataReady" to (pending.target != null),
            "connectedPeers" to status.numPeers(),
            "connectedSeeds" to status.numSeeds(),
            "knownPeers" to status.listPeers(),
            "knownSeeds" to status.listSeeds(),
            "downloadRate" to status.downloadRate(),
            "downloadedBytes" to status.totalDone(),
            "currentTracker" to status.currentTracker(),
            "lastError" to (pending.error ?: "")
        ) + httpDiagnostics(pending)
    }

    private fun httpDiagnostics(pending: PendingStream): Map<String, Any> = mapOf(
        "httpRequestCount" to pending.httpRequestCount.get(),
        "httpBytesSent" to pending.httpBytesSent.get(),
        "lastHttpStatus" to pending.lastHttpStatus,
        "lastHttpRangeStart" to pending.lastHttpRangeStart,
        "lastHttpRangeEnd" to pending.lastHttpRangeEnd,
        "lastRequestBytesSent" to pending.lastRequestBytesSent,
        "firstByteAtMs" to pending.firstByteAtMs,
        "lastPieceIndex" to pending.lastPieceIndex,
        "lastPieceWaitMs" to pending.lastPieceWaitMs,
        "lastHttpError" to pending.lastHttpError,
        "selectedPieceLengthBytes" to (pending.target?.pieceLength ?: 0)
    )

    fun stopPlayback() {
        val (pending, oldHandle) = synchronized(lock) {
            val stopped = activePending
            val previousHandle = activeHandle
            // Publish the pending cleanup before clearing activePending so initialize()
            // cannot race in and delete this stream's cache while readers are closing.
            stopped?.let { deferredCleanupHashes.add(it.infoHash) }
            activeHandle = null
            activePending = null
            startupTask?.cancel(true)
            startupTask = null
            stopped?.error = "Playback was stopped."
            stopped?.cancelled = true
            stopped?.ready?.countDown()
            if (stopped != null && !stopped.startupStarted.get()) {
                // A queued Future cancelled before execution never reaches its finally block.
                stopped.startupFinished.countDown()
            }
            stopHttpServer()
            activeHttpSockets.toList().forEach { socket -> runCatching { socket.close() } }
            stopped to previousHandle
        }

        // Wait outside the engine lock so startup and HTTP workers can finish their cleanup.
        val startupSettled = pending == null || runCatching {
            pending.startupFinished.await(5, TimeUnit.SECONDS)
        }.getOrDefault(false)
        val readersSettled = waitForHttpReadersToClose(pending)
        val managerForCleanup = session
        if (!startupSettled || !readersSettled) {
            Log.w(TAG, "Deferring torrent cleanup until workers settle: startupSettled=$startupSettled readersSettled=$readersSettled")
            deferTorrentCleanup(managerForCleanup, pending, oldHandle)
            return
        }

        if (!removeTorrentAndCache(managerForCleanup, pending, oldHandle)) {
            Log.w(TAG, "Torrent cleanup did not complete; retrying asynchronously.")
            deferTorrentCleanup(managerForCleanup, pending, oldHandle)
            return
        }
        pending?.let { deferredCleanupHashes.remove(it.infoHash) }
    }

    fun close() {
        stopPlayback()
        val old = session
        session = null
        requestPool.shutdownNow()
        startupExecutor.shutdownNow()
        if (old != null) {
            val stopSession = {
                runCatching { old.stop() }
                    .onFailure { error -> Log.w(TAG, "Torrent session shutdown failed: ${error.message}") }
            }
            if (deferredCleanupHashes.isNotEmpty()) {
                // The single-thread cleanup executor runs this only after queued stream
                // cleanup has removed handles and cache data from the still-live session.
                cleanupExecutor.execute { stopSession() }
            } else {
                Thread({ stopSession() }, "moviebox-torrent-shutdown").apply {
                    isDaemon = true
                    start()
                }
            }
        }
    }

    private fun startHttpServer(pending: PendingStream) {
        val server = ServerSocket()
        server.reuseAddress = true
        server.bind(java.net.InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 32)
        serverSocket = server
        Thread({
            while (!server.isClosed) {
                try {
                    val socket = server.accept()
                    // Serialize reader registration with stopPlayback's cancellation
                    // and socket-close section. This prevents cleanup from seeing zero
                    // readers while an accepted socket is not yet registered.
                    val registered = synchronized(lock) {
                        if (pending.cancelled || activePending !== pending) {
                            false
                        } else {
                            pending.activeReaders.incrementAndGet()
                            activeHttpSockets.add(socket)
                            true
                        }
                    }
                    if (!registered) {
                        runCatching { socket.close() }
                        continue
                    }
                    try {
                        requestPool.execute {
                            try {
                                serveRequest(socket, pending)
                            } finally {
                                pending.activeReaders.decrementAndGet()
                                activeHttpSockets.remove(socket)
                            }
                        }
                    } catch (error: Exception) {
                        pending.activeReaders.decrementAndGet()
                        activeHttpSockets.remove(socket)
                        runCatching { socket.close() }
                        Log.w(TAG, "Could not schedule torrent HTTP reader", error)
                    }
                } catch (_: Exception) {
                    // Closing the server socket is the normal way to leave this loop.
                }
            }
        }, "moviebox-torrent-loopback").apply {
            isDaemon = true
            start()
        }
    }

    private fun stopHttpServer() {
        runCatching { serverSocket?.close() }
        serverSocket = null
    }

    private fun waitForHttpReadersToClose(pending: PendingStream?, timeoutMs: Long = 2_000L): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while ((pending?.activeReaders?.get() ?: 0L) > 0L && System.currentTimeMillis() < deadline) {
            try {
                Thread.sleep(20L)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
        }
        return (pending?.activeReaders?.get() ?: 0L) == 0L
    }

    private fun removeTorrentAndCache(
        manager: SessionManager?,
        pending: PendingStream?,
        oldHandle: TorrentHandle?
    ): Boolean {
        if (pending != null) {
            var handlesRemoved = true
            if (manager != null) {
                val matchingHandles = runCatching {
                    manager.getTorrentHandles().filter {
                        it.infoHash().toHex().equals(pending.infoHash, ignoreCase = true)
                    }
                }.getOrElse { error ->
                    Log.w(TAG, "Could not inspect stopped torrent handles: ${error.message}")
                    return false
                }
                matchingHandles.forEach { handle ->
                    if (runCatching { manager.remove(handle) }.isFailure) handlesRemoved = false
                }
                val handleRemains = runCatching {
                    manager.getTorrentHandles().any {
                        it.infoHash().toHex().equals(pending.infoHash, ignoreCase = true)
                    }
                }.getOrElse { true }
                if (handleRemains) handlesRemoved = false
            }

            val cacheRemoved = runCatching {
                TorrentCachePolicy.deleteStreamDirectory(pending.storageDir, torrentCacheRoot)
            }.getOrDefault(false)
            if (!handlesRemoved) {
                // Never delete files while libtorrent may still own/open the torrent.
                Log.w(TAG, "Torrent handle removal is not yet confirmed: " + pending.infoHash)
                return false
            }
            if (!cacheRemoved) {
                Log.w(TAG, "Could not remove stopped torrent cache: " + pending.storageDir.name)
            } else {
                Log.i(TAG, "Removed temporary torrent cache: " + pending.storageDir.name)
            }
            return cacheRemoved
        }

        if (oldHandle != null && manager != null) {
            return runCatching { manager.remove(oldHandle); true }.getOrDefault(false)
        }
        return true
    }

    private fun deferTorrentCleanup(
        manager: SessionManager?,
        pending: PendingStream?,
        oldHandle: TorrentHandle?
    ) {
        pending?.let { deferredCleanupHashes.add(it.infoHash) }
        cleanupExecutor.execute {
            var cleaned = false
            try {
                // Retain the PendingStream/handle until startup and every reader
                // belonging to this stream have actually exited. Retry failed native
                // handle/cache removal instead of silently dropping the cleanup obligation.
                DeferredTorrentCleanupTask(
                    awaitStartup = { pending?.startupFinished?.await() },
                    awaitReaders = {
                        if (pending != null) {
                            while (pending.activeReaders.get() > 0L) Thread.sleep(50L)
                        } else {
                            while (activeHttpSockets.isNotEmpty()) Thread.sleep(50L)
                        }
                    },
                    cleanup = { removeTorrentAndCache(manager, pending, oldHandle) }
                ).run()
                cleaned = true
            } catch (error: Exception) {
                Log.e(TAG, "Deferred torrent cleanup worker failed; cleanup remains blocked.", error)
            } finally {
                if (cleaned) pending?.let { deferredCleanupHashes.remove(it.infoHash) }
            }
        }
    }

    private fun serveRequest(socket: Socket, pending: PendingStream) {
        socket.use { client ->
            if (pending.cancelled || activePending !== pending) return@use
            val requestCancelled = AtomicBoolean(false)
            var requestedRange = "none"
            try {
                client.soTimeout = 15_000
                val reader = BufferedReader(InputStreamReader(client.getInputStream(), Charsets.US_ASCII))
                val requestLine = reader.readLine() ?: return
                val requestParts = requestLine.split(' ')
                if (requestParts.size < 2) {
                    writeSimpleResponse(client, 400, "Bad Request")
                    return
                }
                val method = requestParts[0].uppercase(Locale.US)
                val path = requestParts[1].substringBefore('?')
                val headers = HashMap<String, String>()
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.isEmpty()) break
                    val separator = line.indexOf(':')
                    if (separator > 0) {
                        headers[line.substring(0, separator).trim().lowercase(Locale.US)] =
                            line.substring(separator + 1).trim()
                    }
                }
                // HTTP is full-duplex. EOF on the request-input direction is a
                // valid half-close: the player may have finished sending its GET
                // request while it is still waiting to receive the response body.
                // Only an actual socket read error cancels a pending piece wait.
                client.soTimeout = 250
                Thread({
                    while (!requestCancelled.get() && !client.isClosed) {
                        try {
                            if (reader.readLine() == null) {
                                if (HttpRequestReadPolicy.shouldCancel(
                                        HttpRequestReadOutcome.END_OF_STREAM
                                    )
                                ) {
                                    requestCancelled.set(true)
                                }
                                break
                            }
                        } catch (_: java.net.SocketTimeoutException) {
                            // No pipelined request data; continue watching.
                        } catch (_: Exception) {
                            if (HttpRequestReadPolicy.shouldCancel(
                                    HttpRequestReadOutcome.IO_ERROR
                                )
                            ) {
                                requestCancelled.set(true)
                            }
                            break
                        }
                    }
                }, "moviebox-torrent-http-disconnect").apply {
                    isDaemon = true
                    start()
                }

                requestedRange = headers["range"] ?: "none"
                pending.httpRequestCount.incrementAndGet()
                pending.lastRequestBytesSent = 0L
                pending.lastHttpError = ""
                Log.i(TAG, "HTTP request method=$method range=$requestedRange")

                if (path != "/stream/${pending.token}" || (method != "GET" && method != "HEAD")) {
                    writeSimpleResponse(client, 404, "Not Found")
                    return
                }

                // A newer GET (normally a user seek) supersedes the old progressive
                // response and its obsolete piece priorities.
                val requestGeneration = if (method == "GET") {
                    pending.requestGeneration.incrementAndGet()
                } else {
                    -1L
                }
                val isRequestCancelled = {
                    requestCancelled.get() ||
                        pending.cancelled ||
                        activePending !== pending ||
                        Thread.currentThread().isInterrupted ||
                        (method == "GET" && pending.requestGeneration.get() != requestGeneration)
                }

                val metadataDeadline = System.currentTimeMillis() +
                    METADATA_TIMEOUT_MS + HTTP_METADATA_GRACE_MS
                var metadataReady = pending.ready.count == 0L
                while (!metadataReady && System.currentTimeMillis() < metadataDeadline) {
                    if (isRequestCancelled()) return
                    metadataReady = pending.ready.await(250, TimeUnit.MILLISECONDS)
                }
                metadataReady = metadataReady || pending.ready.count == 0L
                if (!metadataReady) {
                    pending.lastHttpStatus = 504
                    pending.lastHttpError = "Timed out waiting for torrent metadata."
                    writeSimpleResponse(client, 504, "Gateway Timeout", "Retry-After: 3\r\n")
                    return
                }
                val target = pending.target
                if (target == null) {
                    val startupError = pending.error ?: "Metadata discovery or video selection produced no stream target."
                    pending.lastHttpStatus = 502
                    pending.lastHttpError = startupError
                    Log.e(TAG, "Returning HTTP 502 for ${pending.infoHash}: $startupError")
                    writeSimpleResponse(
                        client,
                        502,
                        "Bad Gateway",
                        bodyText = "Torrent startup failed: $startupError"
                    )
                    return
                }

                val range = parseRange(headers["range"], target.fileSize)
                if (range == null) {
                    pending.lastHttpStatus = 416
                    pending.lastHttpError = "Requested byte range is outside the selected video file."
                    writeSimpleResponse(
                        client, 416, "Range Not Satisfiable",
                        "Content-Range: bytes */${target.fileSize}\r\n"
                    )
                    return
                }
                val (start, end, partial) = range
                pending.lastHttpRangeStart = start
                pending.lastHttpRangeEnd = end
                val pieceReadGate = HttpPieceReadGate()
                val firstPieceIndex =
                    ((target.fileOffset + start) / target.pieceLength).toInt()

                // HEAD is metadata-only and must never wait for a torrent piece.
                // For GET, keep the HTTP status uncommitted until the first requested
                // piece is verified and flushed by libtorrent. This prevents a 206
                // response followed by an empty body when the swarm is still starting.
                if (HttpRangePolicy.shouldWaitForFirstPiece(method) && !waitForPiece(
                        pending,
                        target,
                        start,
                        HttpRangePolicy.FIRST_RESPONSE_PIECE_WAIT_MS,
                        requestGeneration,
                        isRequestCancelled
                    )
                ) {
                    when (HttpRangePolicy.beforeHeaders(
                        pieceReady = false,
                        cancelled = isRequestCancelled()
                    )) {
                        HttpPieceDecision.CANCELLED -> return
                        HttpPieceDecision.RETRY -> Unit
                        else -> return
                    }
                    pending.lastHttpStatus =
                        HttpRangePolicy.statusCode(HttpPieceDecision.RETRY) ?: return
                    pending.lastHttpError =
                        "First requested torrent piece was unavailable before HTTP headers."
                    Log.w(
                        TAG,
                        "Returning HTTP 503 before committing stream headers; " +
                            "range=$requestedRange timeoutMs=${HttpRangePolicy.FIRST_RESPONSE_PIECE_WAIT_MS}"
                    )
                    writeSimpleResponse(
                        client,
                        503,
                        "Service Unavailable",
                        HttpRangePolicy.retryAfterHeader(),
                        "First requested torrent piece is not ready. Retry shortly."
                    )
                    return
                }

                if (HttpRangePolicy.shouldWaitForFirstPiece(method)) {
                    pieceReadGate.markVerified(firstPieceIndex)
                }

                val extension = target.file.extension.lowercase(Locale.US)
                val contentType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                    ?: "application/octet-stream"
                val contentLength = end - start + 1
                val status = if (partial) "206 Partial Content" else "200 OK"
                pending.lastHttpStatus = if (partial) 206 else 200
                Log.i(
                    TAG,
                    "HTTP response status=$status contentType=$contentType length=$contentLength " +
                        "fileSize=${target.fileSize} pieceLength=${target.pieceLength}"
                )
                val responseHeaders = buildString {
                    append("HTTP/1.1 ").append(status).append("\r\n")
                    append("Content-Type: ").append(contentType).append("\r\n")
                    append("Accept-Ranges: bytes\r\n")
                    append("Content-Length: ").append(contentLength).append("\r\n")
                    append("Connection: close\r\n")
                    if (partial) {
                        append("Content-Range: bytes ").append(start).append('-').append(end)
                            .append('/').append(target.fileSize).append("\r\n")
                    }
                    append("Access-Control-Allow-Origin: *\r\n\r\n")
                }
                val output = client.getOutputStream()
                output.write(responseHeaders.toByteArray(Charsets.US_ASCII))
                output.flush()
                if (method == "HEAD") return

                RandomAccessFile(target.file, "r").use { media ->
                    var position = start
                    var bytesSent = 0L
                    // GET already passed the pre-header piece gate above.
                    // Wait only when entering a new torrent piece. Multiple 128 KiB
                    // reads inside a verified piece must not repeat an 80 ms delay
                    // or reset the libtorrent playback-priority window.
                    val buffer = ByteArray(128 * 1024)
                    while (position <= end && !client.isClosed) {
                        val globalOffset = target.fileOffset + position
                        val pieceIndex = (globalOffset / target.pieceLength).toInt()
                        if (pieceReadGate.needsWait(pieceIndex)) {
                            if (!waitForPiece(
                                    pending,
                                    target,
                                    position,
                                    STREAM_PIECE_TIMEOUT_MS,
                                    requestGeneration,
                                    isRequestCancelled
                                )
                            ) {
                                when (HttpRangePolicy.afterHeaders(
                                    pieceReady = false,
                                    cancelled = isRequestCancelled()
                                )) {
                                    HttpPieceDecision.CANCELLED -> return
                                    HttpPieceDecision.ABORT ->
                                        throw java.net.SocketTimeoutException("Torrent piece is not available yet.")
                                    else -> return
                                }
                            }
                            pieceReadGate.markVerified(pieceIndex)
                        }
                        val amount = HttpRangePolicy.bytesToPieceEnd(
                            globalOffset = globalOffset,
                            pieceLength = target.pieceLength,
                            remainingBytes = end - position + 1,
                            maxBufferBytes = buffer.size
                        )
                        media.seek(position)
                        media.readFully(buffer, 0, amount)
                        output.write(buffer, 0, amount)
                        output.flush()
                        position += amount
                        bytesSent += amount
                        pending.httpBytesSent.addAndGet(amount.toLong())
                        pending.lastRequestBytesSent = bytesSent
                        if (pending.firstByteAtMs == 0L) {
                            pending.firstByteAtMs = System.currentTimeMillis()
                        }
                        pending.lastHttpError = ""
                    }
                    Log.i(TAG, "HTTP response complete bytes=$bytesSent expected=$contentLength")
                }
            } catch (error: Exception) {
                // A timeout after headers are flushed cannot be converted to a new
                // HTTP status. Abort the body and retain byte-count evidence.
                pending.lastHttpError =
                    "${error.javaClass.simpleName}: ${error.message ?: "No error message."}".take(512)
                if (error is java.net.SocketException) {
                    Log.w(TAG, "HTTP client disconnected/cancelled: ${error.message}")
                } else if (error is java.net.SocketTimeoutException && pending.lastHttpStatus in 200..206) {
                    Log.e(
                        TAG,
                        "HTTP body aborted after committed status=${pending.lastHttpStatus}; " +
                            "bodyBytesSent=${pending.lastRequestBytesSent}; " +
                            "range=$requestedRange; detail=${pending.lastHttpError}",
                        error
                    )
                } else {
                    Log.e(
                        TAG,
                        "HTTP stream request failed: ${error.javaClass.simpleName}: ${error.message}",
                        error
                    )
                }
            } finally {
                requestCancelled.set(true)
            }
        }
    }

    private fun waitForPiece(
        pending: PendingStream,
        target: StreamTarget,
        filePosition: Long,
        timeoutMs: Long,
        requestGeneration: Long,
        isRequestCancelled: () -> Boolean
    ): Boolean {
        val globalOffset = target.fileOffset + filePosition
        val pieceIndex = (globalOffset / target.pieceLength).toInt()
        val waitStartedAt = System.currentTimeMillis()
        pending.lastPieceIndex = pieceIndex
        if (!prioritizePlaybackWindow(pending, target, pieceIndex, requestGeneration, isRequestCancelled)) {
            return false
        }

        val waiter = HttpPieceWaiter(
            hasPiece = { index ->
                runCatching { target.handle.havePiece(index) }.getOrDefault(false)
            }
        )
        val available = waiter.await(
            pieceIndex = pieceIndex,
            timeoutMs = timeoutMs,
            isCancelled = isRequestCancelled
        )
        pending.lastPieceWaitMs = System.currentTimeMillis() - waitStartedAt
        if (!available && !isRequestCancelled() && !pending.cancelled && activePending === pending) {
            pending.lastHttpError =
                "Timed out waiting for torrent piece=$pieceIndex at filePosition=$filePosition after ${pending.lastPieceWaitMs}ms."
            Log.w(
                TAG,
                "Timed out waiting for torrent piece=$pieceIndex filePosition=$filePosition timeoutMs=$timeoutMs"
            )
        } else if (!available) {
            pending.lastHttpError = "Piece wait cancelled for piece=$pieceIndex."
        }
        return available
    }

    /**
     * Keep the current piece urgent and prefetch a contiguous forward window.
     * A seek clears old deadlines and lowers obsolete pieces so they cannot
     * starve the newly requested position.
     */
    private fun prioritizePlaybackWindow(
        pending: PendingStream,
        target: StreamTarget,
        currentPiece: Int,
        requestGeneration: Long,
        isRequestCancelled: () -> Boolean
    ): Boolean {
        synchronized(pending.priorityLock) {
            if (isRequestCancelled() || pending.requestGeneration.get() != requestGeneration) {
                return false
            }
            val window = HttpRangePolicy.playbackWindow(
                currentPiece = currentPiece,
                firstPiece = target.firstPiece,
                lastPiece = target.lastPiece,
                lookAheadPieces = HttpRangePolicy.PREFETCH_PIECES
            )
            if (window.isEmpty()) return false
            val wanted = window.toSet()

            pending.prioritizedPieces.filterNot { it in wanted }.forEach { stalePiece ->
                runCatching { target.handle.resetPieceDeadline(stalePiece) }
                runCatching {
                    target.handle.piecePriority(
                        stalePiece,
                        TorrentDownloadPriorityPolicy.inactivePiece
                    )
                }
            }
            pending.prioritizedPieces.clear()
            window.forEachIndexed { offset, piece ->
                if (runCatching { target.handle.havePiece(piece) }.getOrDefault(false)) {
                    runCatching { target.handle.resetPieceDeadline(piece) }
                } else {
                    runCatching {
                        target.handle.piecePriority(
                            piece,
                            TorrentDownloadPriorityPolicy.activePiece
                        )
                    }
                    runCatching {
                        target.handle.setPieceDeadline(
                            piece,
                            HttpRangePolicy.deadlineForWindowOffset(offset)
                        )
                    }
                    pending.prioritizedPieces.add(piece)
                }
            }
            return !isRequestCancelled()
        }
    }

    private fun parseRange(header: String?, size: Long): HttpByteRange? =
        HttpRangePolicy.parseRange(header, size)

    private fun writeSimpleResponse(
        socket: Socket,
        status: Int,
        reason: String,
        extraHeaders: String = "",
        bodyText: String = reason
    ) {
        val body = bodyText.toByteArray(Charsets.UTF_8)
        val header = "HTTP/1.1 $status $reason\r\n$extraHeaders" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "Content-Length: ${body.size}\r\nConnection: close\r\n\r\n"
        runCatching {
            socket.getOutputStream().apply {
                write(header.toByteArray(Charsets.US_ASCII))
                write(body)
                flush()
            }
        }
    }

    private fun isSafeTracker(value: String): Boolean {
        val parsed = runCatching { URI(value) }.getOrNull() ?: return false
        return parsed.scheme?.lowercase(Locale.US) in setOf("udp", "http", "https") &&
            !parsed.host.isNullOrBlank() &&
            (parsed.port == -1 || parsed.port in 1..65535)
    }

    private fun normalizeInfoHash(input: String): String {
        val value = input.trim()
        if (value.matches(Regex("^[0-9a-fA-F]{40}$"))) return value.lowercase(Locale.US)
        if (!value.matches(Regex("^[a-zA-Z2-7]{32}$"))) {
            throw IllegalArgumentException("Invalid BitTorrent info hash.")
        }
        val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var buffer = 0
        var bits = 0
        val bytes = ArrayList<Byte>(20)
        value.uppercase(Locale.US).forEach { character ->
            val digit = alphabet.indexOf(character)
            if (digit < 0) throw IllegalArgumentException("Invalid base32 info hash.")
            buffer = (buffer shl 5) or digit
            bits += 5
            if (bits >= 8) {
                bits -= 8
                bytes.add(((buffer shr bits) and 0xff).toByte())
            }
        }
        if (bytes.size != 20) throw IllegalArgumentException("Invalid base32 info hash length.")
        return bytes.joinToString("") { "%02x".format(Locale.US, it.toInt() and 0xff) }
    }

    companion object {
        private const val TAG = "MovieBoxTorrent"
        private const val METADATA_TIMEOUT_MS = 60_000L
        private const val HTTP_METADATA_GRACE_MS = 5_000L
        private const val STREAM_PIECE_TIMEOUT_MS = HttpRangePolicy.STREAM_PIECE_WAIT_MS
        private const val MIN_VIDEO_BYTES = 8L * 1024L * 1024L

    }
}
