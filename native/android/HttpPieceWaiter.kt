package com.moviebox.nexus

import com.frostwire.jlibtorrent.Priority
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.min

/**
 * Deterministic piece-wait seam shared by the loopback HTTP engine and JVM tests.
 * The production adapter supplies libtorrent's havePiece(), a monotonic clock,
 * and Thread.sleep(); tests inject a fake clock and piece-availability function.
 */
internal class HttpPieceWaiter(
    private val hasPiece: (Int) -> Boolean,
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000L },
    private val sleepMs: (Long) -> Unit = { Thread.sleep(it) }
) {
    fun await(
        pieceIndex: Int,
        timeoutMs: Long,
        isCancelled: () -> Boolean,
        beforeReadDelayMs: Long = 80L,
        pollIntervalMs: Long = 200L
    ): Boolean {
        require(pieceIndex >= 0) { "pieceIndex must be non-negative" }
        require(timeoutMs >= 0L) { "timeoutMs must be non-negative" }
        require(beforeReadDelayMs >= 0L) { "beforeReadDelayMs must be non-negative" }
        require(pollIntervalMs > 0L) { "pollIntervalMs must be positive" }

        val deadline = nowMs() + timeoutMs
        while (true) {
            if (isCancelled()) return false
            if (hasPiece(pieceIndex)) {
                if (beforeReadDelayMs > 0L) sleepMs(beforeReadDelayMs)
                return !isCancelled()
            }
            val remaining = deadline - nowMs()
            if (remaining <= 0L) return false
            sleepMs(min(pollIntervalMs, remaining))
        }
    }
}

internal data class TorrentDiskReadResult(
    val success: Boolean,
    val bytesRead: Int,
    val error: String
)

/**
 * Waits for libtorrent's asynchronous READ_PIECE alert before the loopback server
 * reads the sparse local file. Keys are playback-token + swarm + piece scoped.
 */
internal class TorrentDiskReadBarrier {
    private class PendingRead {
        val completed = CountDownLatch(1)
        @Volatile var result: TorrentDiskReadResult? = null
    }

    private val pending = ConcurrentHashMap<String, PendingRead>()
    private val ready = ConcurrentHashMap.newKeySet<String>()

    fun await(
        key: String,
        timeoutMs: Long,
        isCancelled: () -> Boolean,
        startRead: () -> Unit
    ): TorrentDiskReadResult? {
        require(key.isNotBlank()) { "Disk-read key must not be blank." }
        require(timeoutMs > 0L) { "Disk-read timeout must be positive." }
        if (ready.contains(key)) return TorrentDiskReadResult(true, 1, "")

        val candidate = PendingRead()
        val existing = pending.putIfAbsent(key, candidate)
        val selected = existing ?: candidate
        if (existing == null) {
            try {
                startRead()
            } catch (error: Throwable) {
                complete(key, false, 0, error.message ?: error.javaClass.simpleName)
            }
        }

        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        while (true) {
            if (isCancelled()) return null
            val remaining = deadline - System.nanoTime()
            if (remaining <= 0L) return null
            val slice = min(remaining, TimeUnit.MILLISECONDS.toNanos(200L))
            if (selected.completed.await(slice, TimeUnit.NANOSECONDS)) {
                return selected.result
            }
        }
    }

    fun complete(key: String, success: Boolean, bytesRead: Int, error: String = ""): Boolean {
        val entry = pending.remove(key) ?: return false
        val result = TorrentDiskReadResult(success && bytesRead > 0, bytesRead, error)
        entry.result = result
        if (result.success) ready.add(key)
        entry.completed.countDown()
        return true
    }

    fun isReady(key: String): Boolean = ready.contains(key)
    fun pendingCount(): Int = pending.size
    fun readyCount(): Int = ready.size
}

internal enum class HttpPieceDecision {
    READY,
    RETRY,
    ABORT,
    CANCELLED
}

/** Pure HTTP policy: no Android, socket, or libtorrent dependencies. */
internal data class HttpByteRange(
    val start: Long,
    val end: Long,
    val partial: Boolean
)

/** Pure HTTP policy: no Android, socket, or libtorrent dependencies. */
internal object HttpRangePolicy {
    // Do not reject a torrent startup before a normal full piece can be verified.
    const val FIRST_RESPONSE_PIECE_WAIT_MS = 45_000L
    const val STREAM_PIECE_WAIT_MS = 180_000L
    // Keep a larger verified-piece window in flight so libtorrent can
    // schedule useful blocks across multiple connected peers instead of
    // starving high-bandwidth or higher-latency links with a 1 MiB window.
    // Default to the former 16-piece window until live swarm measurements exist.
    const val PREFETCH_PIECES = 15
    const val PREFETCH_DEADLINE_STEP_MS = 1_000
    const val RETRY_AFTER_SECONDS = 1
    const val BASE_PREFETCH_WINDOW_PIECES = PREFETCH_PIECES + 1
    const val MAX_PREFETCH_WINDOW_BYTES = 64L * 1024L * 1024L
    const val MAX_PREFETCH_LOOK_AHEAD_PIECES = 63

    /**
     * Size the sliding request window from this torrent's measured swarm state.
     *
     * Libtorrent still chooses the actual peer/block assignments. This policy
     * only keeps enough consecutive pieces eligible so several peers can serve
     * different blocks without building an unbounded mobile cache backlog.
     */
    fun adaptiveLookAheadPieces(
        pieceLengthBytes: Int,
        connectedSources: Int,
        downloadRateBytesPerSecond: Long
    ): Int {
        require(pieceLengthBytes > 0) { "pieceLengthBytes must be positive" }

        val peerAllowance = connectedSources.coerceIn(0, 32).toLong() * 512L * 1024L
        val rateAllowance = downloadRateBytesPerSecond
            .coerceAtLeast(0L)
            .coerceAtMost(16L * 1024L * 1024L) * 2L
        // Keep the baseline at sixteen pieces regardless of this torrent's
        // piece size. A fixed 16 MiB baseline silently expands a 256 KiB torrent
        // to 64 pieces before any peer or throughput evidence exists.
        val baseWindowBytes = BASE_PREFETCH_WINDOW_PIECES.toLong() * pieceLengthBytes.toLong()
        val targetBytes = (baseWindowBytes + peerAllowance + rateAllowance)
            .coerceAtMost(MAX_PREFETCH_WINDOW_BYTES)
        val piecesInWindow = (targetBytes + pieceLengthBytes - 1L) / pieceLengthBytes
        return (piecesInWindow - 1L)
            .coerceIn(0L, MAX_PREFETCH_LOOK_AHEAD_PIECES.toLong())
            .toInt()
    }

    fun playbackWindow(
        currentPiece: Int,
        firstPiece: Int,
        lastPiece: Int,
        lookAheadPieces: Int
    ): List<Int> {
        if (firstPiece < 0 || lastPiece < firstPiece || currentPiece !in firstPiece..lastPiece) {
            return emptyList()
        }
        require(lookAheadPieces >= 0) { "lookAheadPieces must be non-negative" }
        val windowEnd = min(lastPiece.toLong(), currentPiece.toLong() + lookAheadPieces).toInt()
        return (currentPiece..windowEnd).toList()
    }

    fun deadlineForWindowOffset(offset: Int): Int {
        require(offset >= 0) { "offset must be non-negative" }
        return offset * PREFETCH_DEADLINE_STEP_MS
    }

    fun shouldWaitForFirstPiece(method: String): Boolean =
        method.equals("GET", ignoreCase = true)

    fun beforeHeaders(
        pieceReady: Boolean,
        cancelled: Boolean,
        localMediaReadable: Boolean = true
    ): HttpPieceDecision =
        when {
            cancelled -> HttpPieceDecision.CANCELLED
            pieceReady && localMediaReadable -> HttpPieceDecision.READY
            else -> HttpPieceDecision.RETRY
        }

    fun afterHeaders(pieceReady: Boolean, cancelled: Boolean): HttpPieceDecision =
        when {
            cancelled -> HttpPieceDecision.CANCELLED
            pieceReady -> HttpPieceDecision.READY
            else -> HttpPieceDecision.ABORT
        }

    fun statusCode(decision: HttpPieceDecision): Int? =
        when (decision) {
            HttpPieceDecision.READY -> 206
            HttpPieceDecision.RETRY -> 503
            HttpPieceDecision.ABORT,
            HttpPieceDecision.CANCELLED -> null
        }

    fun retryAfterHeader(): String = "Retry-After: $RETRY_AFTER_SECONDS\r\n"

    /**
     * Parse one byte range. Unsupported/malformed Range fields are ignored and
     * return the full representation; syntactically valid but unsatisfiable
     * byte ranges return null so the HTTP layer can answer 416. Multipart ranges
     * are deliberately not partially served: fall back to a full 200 response.
     */
    fun parseRange(header: String?, size: Long): HttpByteRange? {
        if (size <= 0L) return null
        fun fullResponse() = HttpByteRange(0L, size - 1L, partial = false)

        val value = header?.trim().orEmpty()
        if (value.isEmpty() || !value.startsWith("bytes=", ignoreCase = true)) {
            return fullResponse()
        }
        val spec = value.substringAfter('=', "").trim()
        if (spec.contains(',')) return fullResponse()
        val dash = spec.indexOf('-')
        if (dash < 0 || dash != spec.lastIndexOf('-')) return fullResponse()

        val first = spec.substring(0, dash).trim()
        val last = spec.substring(dash + 1).trim()
        if (first.isEmpty() && last.isEmpty()) return fullResponse()

        if (first.isEmpty()) {
            val suffixLength = last.toLongOrNull() ?: return fullResponse()
            if (suffixLength <= 0L) return null
            return HttpByteRange(
                start = (size - suffixLength).coerceAtLeast(0L),
                end = size - 1L,
                partial = true
            )
        }

        val start = first.toLongOrNull() ?: return fullResponse()
        if (start < 0L || start >= size) return null
        val requestedEnd = if (last.isEmpty()) size - 1L else last.toLongOrNull() ?: return fullResponse()
        if (requestedEnd < start) return null
        return HttpByteRange(start, min(requestedEnd, size - 1L), partial = true)
    }

    fun bytesToPieceEnd(
        globalOffset: Long,
        pieceLength: Int,
        remainingBytes: Long,
        maxBufferBytes: Int
    ): Int {
        require(globalOffset >= 0L) { "globalOffset must be non-negative" }
        require(pieceLength > 0) { "pieceLength must be positive" }
        require(remainingBytes > 0L) { "remainingBytes must be positive" }
        require(maxBufferBytes > 0) { "maxBufferBytes must be positive" }
        val pieceRemaining = pieceLength - (globalOffset % pieceLength).toInt()
        return min(min(remainingBytes, pieceRemaining.toLong()), maxBufferBytes.toLong()).toInt()
    }
}


/**
 * Tracks the last piece verified for one sequential HTTP response. The reader
 * may split a piece into bounded buffers without waiting for it more than once.
 */
internal class HttpPieceReadGate {
    private var lastVerifiedPieceIndex: Int? = null

    fun needsWait(pieceIndex: Int): Boolean {
        require(pieceIndex >= 0) { "pieceIndex must be non-negative" }
        return lastVerifiedPieceIndex != pieceIndex
    }

    fun markVerified(pieceIndex: Int) {
        require(pieceIndex >= 0) { "pieceIndex must be non-negative" }
        lastVerifiedPieceIndex = pieceIndex
    }
}


/**
 * Storage policy for temporary torrent media. Stream directories must be
 * direct children of the dedicated cache root. Canonical-path checks prevent
 * cleanup from escaping that root through malformed paths or symlinks.
 */
internal object TorrentStartupCleanupPolicy {
    // Once a stream target exists, HTTP readers may be using its file. The
    // reader-aware stop path must own deletion instead of the startup worker.
    fun shouldDeleteCacheBeforeReaders(targetReady: Boolean): Boolean = !targetReady
}

internal object TorrentCachePolicy {
    const val DIRECTORY_NAME = "moviebox-torrents"

    /**
     * Provision the exact torrent-relative media path before priorities are
     * enabled. Nested directories and a sparse logical file must exist before
     * the first verified piece can be advertised to the player.
     */
    fun ensureSparseMediaFile(
        streamDir: File,
        relativePath: String,
        expectedSizeBytes: Long
    ): File {
        require(expectedSizeBytes > 0L) { "Expected media size must be positive." }
        if (!streamDir.exists() && !streamDir.mkdirs()) {
            throw IOException("Unable to create the torrent storage directory.")
        }
        if (!streamDir.isDirectory) {
            throw IOException("Torrent storage path is not a directory.")
        }

        val canonicalRoot = streamDir.canonicalFile
        val mediaFile = File(canonicalRoot, relativePath).canonicalFile
        if (!mediaFile.path.startsWith(canonicalRoot.path + File.separator)) {
            throw SecurityException("Torrent metadata contains an unsafe media path.")
        }
        val parent = mediaFile.parentFile
            ?: throw IOException("Selected torrent media path has no parent directory.")
        if (!parent.exists() && !parent.mkdirs()) {
            throw IOException("Unable to create a nested torrent media directory.")
        }
        if (!parent.isDirectory) {
            throw IOException("Selected torrent media parent is not a directory.")
        }

        RandomAccessFile(mediaFile, "rw").use { output ->
            if (output.length() != expectedSizeBytes) output.setLength(expectedSizeBytes)
            if (output.length() != expectedSizeBytes) {
                throw IOException("Unable to size the sparse torrent media file.")
            }
        }
        if (!mediaFile.isFile || !mediaFile.canRead()) {
            throw IOException("Selected torrent media file is not readable.")
        }
        return mediaFile
    }

    fun clearRoot(root: File, expectedParent: File): Boolean {
        val canonicalRoot = root.canonicalFile
        val canonicalParent = expectedParent.canonicalFile
        if (canonicalRoot.parentFile != canonicalParent) return false
        return !root.exists() || root.deleteRecursively()
    }

    fun deleteStreamDirectory(streamDir: File, cacheRoot: File): Boolean {
        val canonicalRoot = cacheRoot.canonicalFile
        val canonicalStream = streamDir.canonicalFile
        if (canonicalStream.parentFile != canonicalRoot || canonicalStream == canonicalRoot) {
            return false
        }
        return !streamDir.exists() || streamDir.deleteRecursively()
    }
}


/**
 * Background priority is granted only when the selected movie fits inside a
 * 5–10 GiB budget while leaving at least 2 GiB free for Android and other apps.
 */
internal object TorrentBackgroundDownloadPolicy {
    const val RESERVE_BYTES = 2L * 1024L * 1024L * 1024L
    const val MINIMUM_BUDGET_BYTES = 5L * 1024L * 1024L * 1024L
    const val MAXIMUM_BUDGET_BYTES = 10L * 1024L * 1024L * 1024L

    fun budgetBytes(availableBytes: Long): Long {
        val safeBytes = (availableBytes - RESERVE_BYTES).coerceAtLeast(0L)
        if (safeBytes < MINIMUM_BUDGET_BYTES) return 0L
        return safeBytes.coerceAtMost(MAXIMUM_BUDGET_BYTES)
    }

    fun shouldDownloadWholeFile(fileSizeBytes: Long, budgetBytes: Long): Boolean =
        fileSizeBytes > 0L && budgetBytes >= MINIMUM_BUDGET_BYTES &&
            fileSizeBytes <= budgetBytes
}

/**
 * Only the selected movie is eligible for low-priority background download.
 * The playhead window is promoted to SEVEN. Other files/secondary swarms stay
 * ignored unless their pieces are required for the current read.
 */
internal object TorrentDownloadPriorityPolicy {
    val activePiece: Priority = Priority.SEVEN
    val inactivePiece: Priority = Priority.IGNORE

    fun filePriorities(
        fileCount: Int,
        selectedFileIndex: Int? = null,
        backgroundDownloadEnabled: Boolean = false
    ): Array<Priority> {
        require(fileCount > 0) { "fileCount must be positive" }
        require(selectedFileIndex == null || selectedFileIndex in 0 until fileCount) {
            "Selected torrent file index is outside the file list."
        }
        return Array(fileCount) { index ->
            if (backgroundDownloadEnabled && index == selectedFileIndex) {
                Priority.NORMAL
            } else {
                Priority.IGNORE
            }
        }
    }

    fun idlePiecePriority(
        isPrimarySource: Boolean,
        backgroundDownloadEnabled: Boolean
    ): Priority =
        if (isPrimarySource && backgroundDownloadEnabled) Priority.NORMAL else Priority.IGNORE
}


/**
 * Distinguishes a valid HTTP request-side half-close from a socket read failure.
 * EOF on the request direction does not prove the peer has closed its response
 * direction; only an actual read error should cancel a pending body wait.
 */
internal enum class HttpRequestReadOutcome {
    END_OF_STREAM,
    IO_ERROR
}

internal object HttpRequestReadPolicy {
    fun shouldCancel(outcome: HttpRequestReadOutcome): Boolean =
        outcome == HttpRequestReadOutcome.IO_ERROR
}

/**
 * Cryptographic description of one selected file inside a torrent.
 *
 * v1 hashes are listed only for complete piece spans that lie wholly inside
 * this file. Boundary pieces are intentionally excluded because a v1 piece
 * may also contain bytes from an adjacent file.
 */
internal data class TorrentFileIdentityProof(
    val infoHash: String,
    val fileSize: Long,
    val pieceLength: Int,
    val fileOffset: Long,
    val hasV1: Boolean,
    val v2PiecesRootHex: String?,
    val firstInteriorOffset: Long,
    val interiorPieceHashes: List<String>
)

internal enum class ContentIdentityKind {
    REJECTED,
    V1_INTERIOR_ONLY,
    V2_FULL_FILE
}

internal data class ContentIdentityResult(
    val kind: ContentIdentityKind,
    val verifiedStart: Long = 0L,
    val verifiedEndExclusive: Long = 0L,
    val canonicalChunkBytes: Int = 0,
    val reason: String
) {
    val accepted: Boolean get() = kind != ContentIdentityKind.REJECTED
}

/**
 * Strict identity gate. Names, paths, release labels and file size alone are
 * never accepted as content identity.
 */
internal object ContentIdentityVerifier {
    private const val MIN_V2_PIECE_BYTES = 16 * 1024
    private const val MAX_V1_INTERIOR_PIECES = 65_536

    fun verify(
        primary: TorrentFileIdentityProof,
        candidate: TorrentFileIdentityProof
    ): ContentIdentityResult {
        fun reject(reason: String) = ContentIdentityResult(
            kind = ContentIdentityKind.REJECTED,
            reason = reason
        )

        if (primary.infoHash.isBlank() || candidate.infoHash.isBlank()) {
            return reject("Missing info-hash.")
        }
        if (primary.infoHash.equals(candidate.infoHash, ignoreCase = true)) {
            return reject("Candidate is the same swarm as the primary.")
        }
        if (primary.fileSize <= 0L || candidate.fileSize <= 0L ||
            primary.fileSize != candidate.fileSize
        ) {
            return reject("Selected file sizes are invalid or different.")
        }
        if (primary.pieceLength <= 0 || candidate.pieceLength <= 0 ||
            primary.fileOffset < 0L || candidate.fileOffset < 0L
        ) {
            return reject("Invalid piece length or file offset.")
        }

        val primaryRoot = normalizedRoot(primary.v2PiecesRootHex)
        val candidateRoot = normalizedRoot(candidate.v2PiecesRootHex)
        if (primary.v2PiecesRootHex != null && primaryRoot == null) {
            return reject("Primary v2 pieces root is malformed.")
        }
        if (candidate.v2PiecesRootHex != null && candidateRoot == null) {
            return reject("Candidate v2 pieces root is malformed.")
        }

        // A shared BEP 52 file root proves the complete file bytes. Piece
        // lengths still need a common scheduling unit so native piece spans
        // from every handle map to the same canonical byte interval.
        if (primaryRoot != null && candidateRoot != null) {
            if (primaryRoot != candidateRoot) {
                return reject("BEP 52 file Merkle roots differ.")
            }
            val larger = maxOf(primary.pieceLength, candidate.pieceLength)
            val smaller = minOf(primary.pieceLength, candidate.pieceLength)
            if (!isPowerOfTwo(primary.pieceLength) ||
                !isPowerOfTwo(candidate.pieceLength) ||
                smaller < MIN_V2_PIECE_BYTES ||
                larger % smaller != 0
            ) {
                return reject("v2 piece lengths do not have a safe common scheduling unit.")
            }
            return ContentIdentityResult(
                kind = ContentIdentityKind.V2_FULL_FILE,
                verifiedStart = 0L,
                verifiedEndExclusive = primary.fileSize,
                canonicalChunkBytes = larger,
                reason = "Matching BEP 52 SHA-256 file pieces root and size."
            )
        }

        // v1 hashes cover fixed-size spans in the torrent's concatenated byte
        // stream. The selected files must have the same piece length and phase.
        if (!primary.hasV1 || !candidate.hasV1) {
            return reject("No common v2 root and no v1 hash on both sources.")
        }
        if (primary.pieceLength != candidate.pieceLength) {
            return reject("v1 piece lengths differ.")
        }
        val pieceLength = primary.pieceLength.toLong()
        val primaryPhase = Math.floorMod(primary.fileOffset, pieceLength)
        val candidatePhase = Math.floorMod(candidate.fileOffset, pieceLength)
        if (primaryPhase != candidatePhase) {
            return reject("v1 selected-file piece boundaries are phase-shifted.")
        }

        val firstFull = (pieceLength - primaryPhase) % pieceLength
        val fullPieceCount = if (primary.fileSize <= firstFull) {
            0L
        } else {
            (primary.fileSize - firstFull) / pieceLength
        }
        if (fullPieceCount <= 0L) {
            return reject("No complete interior v1 piece exists to prove identity.")
        }
        if (fullPieceCount > MAX_V1_INTERIOR_PIECES ||
            primary.interiorPieceHashes.size.toLong() != fullPieceCount ||
            candidate.interiorPieceHashes.size.toLong() != fullPieceCount
        ) {
            return reject("v1 interior piece-hash coverage is incomplete or exceeds the verification bound.")
        }
        for (index in 0 until fullPieceCount.toInt()) {
            val a = primary.interiorPieceHashes[index].lowercase()
            val b = candidate.interiorPieceHashes[index].lowercase()
            if (!isSha1(a) || !isSha1(b) || a != b) {
                return reject("v1 interior piece hash mismatch at relative piece $index.")
            }
        }

        val endExclusive = firstFull + fullPieceCount * pieceLength
        return ContentIdentityResult(
            kind = ContentIdentityKind.V1_INTERIOR_ONLY,
            verifiedStart = firstFull,
            verifiedEndExclusive = endExclusive,
            canonicalChunkBytes = primary.pieceLength,
            reason = "All complete aligned v1 interior SHA-1 pieces match; boundary pieces remain primary-only."
        )
    }

    private fun normalizedRoot(value: String?): String? {
        if (value == null) return null
        val root = value.trim().lowercase()
        return root.takeIf { it.length == 64 && it.all { character -> character in "0123456789abcdef" } &&
            it.any { character -> character != '0' } }
    }

    private fun isSha1(value: String): Boolean =
        value.length == 40 && value.all { it in "0123456789abcdef" }

    private fun isPowerOfTwo(value: Int): Boolean =
        value >= MIN_V2_PIECE_BYTES && (value and (value - 1)) == 0
}

internal data class CrossSwarmCandidateMetrics(
    val sourceId: String,
    val healthy: Boolean,
    val goodputBytesPerSecond: Long,
    val queuedBytes: Long = 0L,
    val failurePenalty: Double = 1.0
)

internal data class CrossSwarmLease(
    val ownerId: String,
    val acquiredAtMs: Long,
    val lastProgressAtMs: Long,
    val backupId: String? = null
)

/**
 * Deterministic macro-scheduler for canonical chunks. It leases at most one
 * source normally and permits one backup only for a stalled critical chunk.
 * libtorrent remains responsible for all peer/block scheduling inside a swarm.
 */
internal class CrossSwarmPieceScheduler(
    private val canonicalChunkBytes: Int,
    private val minimumGoodputBytesPerSecond: Long = 16L * 1024L,
    private val maxFailurePenalty: Double = 8.0
) {
    private val leases = HashMap<Long, CrossSwarmLease>()

    init {
        require(canonicalChunkBytes > 0)
        require(minimumGoodputBytesPerSecond > 0L)
    }

    @Synchronized
    fun assign(
        canonicalChunk: Long,
        nowMs: Long,
        candidates: List<CrossSwarmCandidateMetrics>,
        critical: Boolean,
        stallThresholdMs: Long = 1_200L
    ): List<String> {
        require(canonicalChunk >= 0L)
        require(nowMs >= 0L)
        require(stallThresholdMs >= 0L)
        val viable = candidates.filter { it.sourceId.isNotBlank() && it.healthy }
        if (viable.isEmpty()) {
            leases.remove(canonicalChunk)
            return emptyList()
        }

        val current = leases[canonicalChunk]
        if (current != null && viable.any { it.sourceId == current.ownerId }) {
            val stalled = nowMs - current.lastProgressAtMs >= stallThresholdMs
            if (!critical || !stalled || current.backupId != null) {
                val backupStillViable = current.backupId?.let { id ->
                    viable.any { it.sourceId == id }
                } == true
                return listOfNotNull(
                    current.ownerId,
                    current.backupId.takeIf { backupStillViable }
                )
            }
            val backup = bestCandidate(viable, exclude = setOf(current.ownerId))
            if (backup != null) {
                leases[canonicalChunk] = current.copy(backupId = backup.sourceId)
                return listOf(current.ownerId, backup.sourceId)
            }
            return listOf(current.ownerId)
        }

        val winner = bestCandidate(viable, exclude = emptySet()) ?: return emptyList()
        leases[canonicalChunk] = CrossSwarmLease(
            ownerId = winner.sourceId,
            acquiredAtMs = nowMs,
            lastProgressAtMs = nowMs
        )
        return listOf(winner.sourceId)
    }

    @Synchronized
    fun recordProgress(canonicalChunk: Long, sourceId: String, nowMs: Long) {
        val current = leases[canonicalChunk] ?: return
        if (sourceId == current.ownerId) {
            leases[canonicalChunk] = current.copy(lastProgressAtMs = nowMs)
        } else if (sourceId == current.backupId) {
            // The backup becomes the winner; the old owner is no longer leased.
            leases[canonicalChunk] = CrossSwarmLease(
                ownerId = sourceId,
                acquiredAtMs = current.acquiredAtMs,
                lastProgressAtMs = nowMs
            )
        }
    }

    @Synchronized
    fun complete(canonicalChunk: Long) {
        leases.remove(canonicalChunk)
    }

    @Synchronized
    fun clear() {
        leases.clear()
    }

    @Synchronized
    fun snapshot(): Map<Long, CrossSwarmLease> = leases.toMap()

    private fun bestCandidate(
        candidates: List<CrossSwarmCandidateMetrics>,
        exclude: Set<String>
    ): CrossSwarmCandidateMetrics? = candidates.asSequence()
        .filter { it.sourceId !in exclude }
        .minByOrNull { candidate ->
            val rate = maxOf(
                candidate.goodputBytesPerSecond,
                minimumGoodputBytesPerSecond
            )
            val queued = candidate.queuedBytes.coerceAtLeast(0L)
            val etaSeconds = (queued + canonicalChunkBytes.toLong()) / rate.toDouble()
            val penalty = candidate.failurePenalty
                .coerceIn(1.0, maxFailurePenalty)
            etaSeconds * penalty
        }
}

