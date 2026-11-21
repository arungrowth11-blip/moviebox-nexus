package com.moviebox.nexus

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
    const val RETRY_AFTER_SECONDS = 1

    fun shouldWaitForFirstPiece(method: String): Boolean =
        method.equals("GET", ignoreCase = true)

    fun beforeHeaders(pieceReady: Boolean, cancelled: Boolean): HttpPieceDecision =
        when {
            cancelled -> HttpPieceDecision.CANCELLED
            pieceReady -> HttpPieceDecision.READY
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
