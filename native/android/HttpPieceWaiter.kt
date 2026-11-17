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
internal object HttpRangePolicy {
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
