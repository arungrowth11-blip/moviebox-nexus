package com.moviebox.nexus

import android.content.Context
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
import java.net.URLEncoder
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors
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
    @Volatile private var activeTarget: StreamTarget? = null
    @Volatile private var serverSocket: ServerSocket? = null

    private data class StreamTarget(
        val handle: TorrentHandle,
        val file: File,
        val fileSize: Long,
        val fileOffset: Long,
        val pieceLength: Int,
        val token: String
    )

    fun initialize() {
        synchronized(lock) {
            if (session != null) return
            val manager = SessionManager()
            manager.start()
            session = manager
        }
    }

    fun startPlayback(infoHash: String, title: String): String {
        initialize()
        val hashHex = normalizeInfoHash(infoHash)
        stopPlayback()

        val manager = session ?: throw IllegalStateException("Torrent session did not initialize.")
        val saveDir = File(context.filesDir, "moviebox-torrents/$hashHex")
        if (!saveDir.exists() && !saveDir.mkdirs()) {
            throw IllegalStateException("Unable to create the app's torrent cache directory.")
        }

        val encodedTitle = URLEncoder.encode(title.take(160), "UTF-8")
        val trackers = listOf(
            "udp://tracker.opentrackr.org:1337/announce",
            "udp://open.stealth.si:80/announce",
            "udp://open.demonii.com:1337/announce",
            "udp://exodus.desync.com:6969/announce"
        )
        val magnet = buildString {
            append("magnet:?xt=urn:btih:")
            append(hashHex)
            append("&dn=")
            append(encodedTitle)
            trackers.forEach { tracker ->
                append("&tr=")
                append(URLEncoder.encode(tracker, "UTF-8"))
            }
        }

        val flags = TorrentFlags.SEQUENTIAL_DOWNLOAD.or_(TorrentFlags.AUTO_MANAGED)
        manager.download(magnet, saveDir, flags)

        val deadline = System.currentTimeMillis() + METADATA_TIMEOUT_MS
        var handle: TorrentHandle? = null
        var discoveredHandle: TorrentHandle? = null
        var info: com.frostwire.jlibtorrent.TorrentInfo? = null
        while (System.currentTimeMillis() < deadline) {
            val candidate = manager.getTorrentHandles().firstOrNull {
                runCatching {
                    it.infoHash().toHex().equals(hashHex, ignoreCase = true)
                }.getOrDefault(false)
            }
            if (candidate != null) {
                discoveredHandle = candidate
                val candidateInfo = runCatching { candidate.torrentFile() }.getOrNull()
                if (candidateInfo != null && candidateInfo.isValid()) {
                    handle = candidate
                    info = candidateInfo
                    break
                }
            }
            Thread.sleep(350)
        }

        val torrentHandle = handle ?: run {
            discoveredHandle?.let { incomplete -> runCatching { manager.remove(incomplete) } }
            throw IllegalStateException("Torrent metadata was not received. The swarm may have no reachable peers.")
        }
        val torrentInfo = info
            ?: throw IllegalStateException("Torrent metadata is invalid.")
        activeHandle = torrentHandle
        try {
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
        val selected = candidates.maxByOrNull { it.third }
            ?: throw IllegalStateException("This torrent contains no supported video file.")

        // Download only the selected media file; skip samples, subtitles and extras.
        // Keep the whole selected file at normal priority, then boost its opening
        // pieces explicitly. Setting every piece in a large movie to SEVEN makes
        // the opening bytes compete with the entire rest of the file.
        val priorities = Array(storage.numFiles()) { Priority.IGNORE }
        priorities[selected.first] = Priority.NORMAL
        torrentHandle.prioritizeFiles(priorities)

        val selectedFileOffset = storage.fileOffset(selected.first)
        val firstPiece = (selectedFileOffset / torrentInfo.pieceLength()).toInt()
        val lastPiece = ((selectedFileOffset + selected.third - 1L) / torrentInfo.pieceLength()).toInt()
        val piecePriorities = torrentHandle.piecePriorities()
        val startupLastPiece = minOf(lastPiece, firstPiece + STARTUP_PRIORITY_PIECES - 1)
        if (firstPiece >= 0 && startupLastPiece < piecePriorities.size) {
            for (piece in firstPiece..startupLastPiece) {
                piecePriorities[piece] = Priority.SEVEN
            }
            torrentHandle.prioritizePieces(piecePriorities)
            for (piece in firstPiece..startupLastPiece) {
                // Earlier playback bytes receive earlier deadlines. Libtorrent
                // still verifies every piece before the loopback server exposes it.
                runCatching {
                    torrentHandle.setPieceDeadline(
                        piece,
                        (piece - firstPiece) * STARTUP_DEADLINE_STEP_MS
                    )
                }
            }
        }
        // Request peers from DHT immediately rather than relying only on the
        // first periodic DHT announce after the magnet is added.
        runCatching { torrentHandle.forceDHTAnnounce() }

        val canonicalRoot = saveDir.canonicalFile
        val mediaFile = File(saveDir, selected.second).canonicalFile
        if (!mediaFile.path.startsWith(canonicalRoot.path + File.separator)) {
            throw SecurityException("Torrent metadata contains an unsafe file path.")
        }

        val target = StreamTarget(
            handle = torrentHandle,
            file = mediaFile,
            fileSize = selected.third,
            fileOffset = storage.fileOffset(selected.first),
            pieceLength = torrentInfo.pieceLength(),
            token = UUID.randomUUID().toString().replace("-", "")
        )

        // Ensure the player's first HTTP request can be answered before returning the URL.
        if (!waitForPiece(target, 0L, FIRST_PIECE_TIMEOUT_MS)) {
            throw IllegalStateException("No video data arrived. This torrent may have no active seeders.")
        }
        startHttpServer(target)
        activeTarget = target
        return "http://127.0.0.1:${serverSocket?.localPort}/stream/${target.token}"
        } catch (error: Throwable) {
            runCatching { manager.remove(torrentHandle) }
            if (activeHandle == torrentHandle) activeHandle = null
            activeTarget = null
            stopHttpServer()
            throw error
        }
    }

    fun stopPlayback() {
        synchronized(lock) {
            stopHttpServer()
            val oldHandle = activeHandle
            activeHandle = null
            activeTarget = null
            if (oldHandle != null) {
                runCatching { session?.remove(oldHandle) }
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
    }

    private fun startHttpServer(target: StreamTarget) {
        val server = ServerSocket()
        server.reuseAddress = true
        server.bind(java.net.InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 32)
        serverSocket = server
        Thread({
            while (!server.isClosed) {
                try {
                    val socket = server.accept()
                    requestPool.execute { serveRequest(socket, target) }
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

    private fun serveRequest(socket: Socket, target: StreamTarget) {
        socket.use { client ->
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

                if (path != "/stream/${target.token}" || (method != "GET" && method != "HEAD")) {
                    writeSimpleResponse(client, 404, "Not Found")
                    return
                }

                val range = parseRange(headers["range"], target.fileSize)
                if (range == null) {
                    writeSimpleResponse(
                        client, 416, "Range Not Satisfiable",
                        "Content-Range: bytes */${target.fileSize}\r\n"
                    )
                    return
                }
                val (start, end, partial) = range
                if (!waitForPiece(target, start, FIRST_PIECE_TIMEOUT_MS)) {
                    writeSimpleResponse(client, 504, "Gateway Timeout", "Retry-After: 3\r\n")
                    return
                }

                val extension = target.file.extension.lowercase(Locale.US)
                val contentType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                    ?: "application/octet-stream"
                val contentLength = end - start + 1
                val status = if (partial) "206 Partial Content" else "200 OK"
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
                    val buffer = ByteArray(128 * 1024)
                    while (position <= end && !client.isClosed) {
                        if (!waitForPiece(target, position, STREAM_PIECE_TIMEOUT_MS)) {
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
                    }
                }
            } catch (_: Exception) {
                // The player may cancel or replace an HTTP range request while seeking.
            }
        }
    }

    private fun waitForPiece(target: StreamTarget, filePosition: Long, timeoutMs: Long): Boolean {
        val globalOffset = target.fileOffset + filePosition
        val pieceIndex = (globalOffset / target.pieceLength).toInt()
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (runCatching { target.handle.havePiece(pieceIndex) }.getOrDefault(false)) {
                // Allow libtorrent's disk thread to flush the verified piece before reading.
                Thread.sleep(80)
                return true
            }
            Thread.sleep(200)
        }
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
        extraHeaders: String = ""
    ) {
        val body = reason.toByteArray(Charsets.UTF_8)
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
        private const val METADATA_TIMEOUT_MS = 60_000L
        private const val FIRST_PIECE_TIMEOUT_MS = 30_000L
        private const val STREAM_PIECE_TIMEOUT_MS = 45_000L
        private const val MIN_VIDEO_BYTES = 8L * 1024L * 1024L
        private const val STARTUP_PRIORITY_PIECES = 12
        private const val STARTUP_DEADLINE_STEP_MS = 750
    }
}
