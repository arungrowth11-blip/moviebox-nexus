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
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.min

/**
 * One in-process libtorrent session and a localhost HTTP byte-range endpoint.
 *
 * Selected media files download sequentially. HTTP ranges are served only after
 * libtorrent reports each backing piece as complete, so the player never reads
 * the sparse/preallocated zero-filled areas of an incomplete file.
 */
internal class EmbeddedTorrentEngine(private val context: Context) {
    private val lock = Any()
    private val requestPool = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "moviebox-torrent-http").apply { isDaemon = true }
    }

    @Volatile private var session: SessionManager? = null
    @Volatile private var activeHandle: TorrentHandle? = null
    @Volatile private var activePending: PendingStream? = null
    @Volatile private var startupTask: Future<*>? = null
    @Volatile private var serverSocket: ServerSocket? = null
    private val startupExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "moviebox-torrent-startup").apply { isDaemon = true }
    }

    private data class StreamTarget(
        val handle: TorrentHandle,
        val file: File,
        val fileSize: Long,
        val fileOffset: Long,
        val pieceLength: Int,
        val token: String
    )

    private class PendingStream(
        val token: String,
        val infoHash: String
    ) {
        val ready = CountDownLatch(1)
        val httpRequestCount = AtomicLong(0L)
        val httpBytesSent = AtomicLong(0L)
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

    fun initialize() {
        synchronized(lock) {
            if (session != null) return
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

        val manager = session ?: throw IllegalStateException("Torrent session did not initialize.")
        val saveDir = File(context.filesDir, "moviebox-torrents/$hashHex")
        if (!saveDir.exists() && !saveDir.mkdirs()) {
            throw IllegalStateException("Unable to create the app's torrent cache directory.")
        }

        val pending = PendingStream(
            token = UUID.randomUUID().toString().replace("-", ""),
            infoHash = hashHex
        )
        startHttpServer(pending)
        activePending = pending
        val port = serverSocket?.localPort
            ?: throw IllegalStateException("Unable to start the local torrent stream server.")

        startupTask = startupExecutor.submit {
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
                pending.ready.countDown()
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

        val priorities = Array(storage.numFiles()) { Priority.IGNORE }
        priorities[selected.first] = Priority.NORMAL
        torrentHandle.prioritizeFiles(priorities)

        val selectedFileOffset = storage.fileOffset(selected.first)
        val firstPiece = (selectedFileOffset / torrentInfo.pieceLength()).toInt()
        val lastPiece = ((selectedFileOffset + selected.third - 1L) / torrentInfo.pieceLength()).toInt()
        val startupLastPiece = minOf(lastPiece, firstPiece + STARTUP_PRIORITY_PIECES - 1)
        if (firstPiece >= 0 && firstPiece <= startupLastPiece) {
            for (piece in firstPiece..startupLastPiece) {
                torrentHandle.piecePriority(piece, Priority.SEVEN)
                runCatching {
                    torrentHandle.setPieceDeadline(
                        piece,
                        (piece - firstPiece) * STARTUP_DEADLINE_STEP_MS
                    )
                }
            }
        }

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
        val status = runCatching { handle.status() }.getOrNull()
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
        "lastHttpError" to pending.lastHttpError
    )

    fun stopPlayback() {
        synchronized(lock) {
            val pending = activePending
            activePending = null
            startupTask?.cancel(true)
            startupTask = null
            pending?.error = "Playback was stopped."
            pending?.cancelled = true
            pending?.ready?.countDown()
            stopHttpServer()

            val oldHandle = activeHandle
            activeHandle = null
            if (oldHandle != null) {
                runCatching { session?.remove(oldHandle) }
            } else if (pending != null) {
                session?.getTorrentHandles()?.filter {
                    runCatching {
                        it.infoHash().toHex().equals(pending.infoHash, ignoreCase = true)
                    }.getOrDefault(false)
                }?.forEach { handle -> runCatching { session?.remove(handle) } }
            }
        }
    }

    fun close() {
        stopPlayback()
        val old = session
        session = null
        if (old != null) {
            Thread({ runCatching { old.stop() } }, "moviebox-torrent-shutdown").apply {
                isDaemon = true
                start()
            }
        }
        requestPool.shutdownNow()
        startupExecutor.shutdownNow()
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
                    requestPool.execute { serveRequest(socket, pending) }
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

    private fun serveRequest(socket: Socket, pending: PendingStream) {
        socket.use { client ->
            val requestCancelled = AtomicBoolean(false)
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
                // Watch the request side independently while a piece is pending.
                // HTTP clients close the range socket when seeking/releasing a load;
                // a short read timeout lets us detect that FIN without blocking the
                // stream worker for the full piece deadline.
                client.soTimeout = 250
                val disconnectMonitor = Thread({
                    try {
                        while (!requestCancelled.get() && !client.isClosed) {
                            if (reader.readLine() == null) {
                                requestCancelled.set(true)
                                break
                            }
                        }
                    } catch (_: java.net.SocketTimeoutException) {
                        // No pipelined request data; keep watching for a disconnect.
                        if (!requestCancelled.get() && !client.isClosed) {
                            runCatching { Thread.sleep(25) }
                        }
                    } catch (_: Exception) {
                        requestCancelled.set(true)
                    }
                }, "moviebox-torrent-http-disconnect").apply {
                    isDaemon = true
                    start()
                }

                val requestedRange = headers["range"] ?: "none"
                pending.httpRequestCount.incrementAndGet()
                pending.lastRequestBytesSent = 0L
                pending.lastHttpError = ""
                Log.i(TAG, "HTTP request method=$method range=$requestedRange")

                if (path != "/stream/${pending.token}" || (method != "GET" && method != "HEAD")) {
                    writeSimpleResponse(client, 404, "Not Found")
                    return
                }

                if (!pending.ready.await(METADATA_TIMEOUT_MS + HTTP_METADATA_GRACE_MS, TimeUnit.MILLISECONDS)) {
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

                // HEAD is metadata-only and must never wait for a torrent piece.
                // For GET, keep the HTTP status uncommitted until the first requested
                // piece is verified and flushed by libtorrent. This prevents a 206
                // response followed by an empty body when the swarm is still starting.
                if (method == "GET" && !waitForPiece(
                        pending,
                        target,
                        start,
                        FIRST_RESPONSE_PIECE_WAIT_MS,
                        requestCancelled
                    )
                ) {
                    if (requestCancelled.get() || pending.cancelled || activePending !== pending) return
                    pending.lastHttpStatus = 503
                    pending.lastHttpError =
                        "First requested torrent piece was unavailable before HTTP headers."
                    Log.w(
                        TAG,
                        "Returning HTTP 503 before committing stream headers; " +
                            "range=$requestedRange timeoutMs=$FIRST_RESPONSE_PIECE_WAIT_MS"
                    )
                    writeSimpleResponse(
                        client,
                        503,
                        "Service Unavailable",
                        "Retry-After: 1\r\n",
                        "First requested torrent piece is not ready. Retry shortly."
                    )
                    return
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
                    val buffer = ByteArray(128 * 1024)
                    while (position <= end && !client.isClosed) {
                        if (!waitForPiece(
                                pending,
                                target,
                                position,
                                STREAM_PIECE_TIMEOUT_MS,
                                requestCancelled
                            )
                        ) {
                            throw java.net.SocketTimeoutException("Torrent piece is not available yet.")
                        }
                        val globalOffset = target.fileOffset + position
                        val bytesToPieceEnd = target.pieceLength - (globalOffset % target.pieceLength)
                        val amount = min(min(end - position + 1, bytesToPieceEnd), buffer.size.toLong()).toInt()
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
        requestCancelled: AtomicBoolean
    ): Boolean {
        val globalOffset = target.fileOffset + filePosition
        val pieceIndex = (globalOffset / target.pieceLength).toInt()
        val waitStartedAt = System.currentTimeMillis()
        pending.lastPieceIndex = pieceIndex
        // Each HTTP range (including a user seek) reprioritizes the exact piece
        // being requested so a distant seek is not stuck behind sequential data.
        runCatching { target.handle.piecePriority(pieceIndex, Priority.SEVEN) }
        runCatching { target.handle.setPieceDeadline(pieceIndex, PIECE_REQUEST_DEADLINE_MS) }
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (requestCancelled.get() || pending.cancelled ||
                activePending !== pending || Thread.currentThread().isInterrupted
            ) {
                pending.lastPieceWaitMs = System.currentTimeMillis() - waitStartedAt
                pending.lastHttpError = "Piece wait cancelled for piece=$pieceIndex."
                return false
            }
            if (runCatching { target.handle.havePiece(pieceIndex) }.getOrDefault(false)) {
                // Allow libtorrent's disk thread to flush the verified piece before reading.
                Thread.sleep(80)
                pending.lastPieceWaitMs = System.currentTimeMillis() - waitStartedAt
                return !requestCancelled.get() &&
                    !pending.cancelled &&
                    activePending === pending &&
                    !Thread.currentThread().isInterrupted
            }
            Thread.sleep(minOf(200L, (deadline - System.currentTimeMillis()).coerceAtLeast(1L)))
        }
        pending.lastPieceWaitMs = System.currentTimeMillis() - waitStartedAt
        pending.lastHttpError = "Timed out waiting for torrent piece=$pieceIndex at filePosition=$filePosition after ${pending.lastPieceWaitMs}ms."
        Log.w(
            TAG,
            "Timed out waiting for torrent piece=$pieceIndex filePosition=$filePosition timeoutMs=$timeoutMs"
        )
        return false
    }

    private fun parseRange(header: String?, size: Long): Triple<Long, Long, Boolean>? {
        if (size <= 0L) return null
        if (header.isNullOrBlank()) return Triple(0L, size - 1, false)
        if (!header.startsWith("bytes=", ignoreCase = true)) return null
        val pieces = header.substringAfter('=').substringBefore(',').split('-', limit = 2)
        if (pieces.size != 2) return null
        return try {
            val start: Long
            val end: Long
            if (pieces[0].isBlank()) {
                val suffix = pieces[1].toLong()
                if (suffix <= 0) return null
                start = (size - suffix).coerceAtLeast(0)
                end = size - 1
            } else {
                start = pieces[0].toLong()
                end = if (pieces[1].isBlank()) size - 1 else pieces[1].toLong()
            }
            if (start < 0 || start >= size || end < start) null
            else Triple(start, end.coerceAtMost(size - 1), true)
        } catch (_: NumberFormatException) {
            null
        }
    }

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
        private const val FIRST_RESPONSE_PIECE_WAIT_MS = 4_000L
        private const val STREAM_PIECE_TIMEOUT_MS = 45_000L
        private const val MIN_VIDEO_BYTES = 8L * 1024L * 1024L
        private const val STARTUP_PRIORITY_PIECES = 12
        private const val STARTUP_DEADLINE_STEP_MS = 750
        private const val PIECE_REQUEST_DEADLINE_MS = 0
    }
}
