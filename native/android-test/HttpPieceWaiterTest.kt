package com.moviebox.nexus

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HttpPieceWaiterTest {
    private class FakeClock {
        var now = 0L
        fun sleep(durationMs: Long) {
            now += durationMs
        }
    }

    @Test
    fun headRequestSkipsPieceWait() {
        assertFalse(HttpRangePolicy.shouldWaitForFirstPiece("HEAD"))
        assertTrue(HttpRangePolicy.shouldWaitForFirstPiece("GET"))
        assertTrue(HttpRangePolicy.shouldWaitForFirstPiece("get"))
    }

    @Test
    fun initialPieceTimeoutProducesRetryable503Decision() {
        val decision = HttpRangePolicy.beforeHeaders(pieceReady = false, cancelled = false)
        assertEquals(HttpPieceDecision.RETRY, decision)
        assertEquals(503, if (decision == HttpPieceDecision.RETRY) 503 else 206)
        assertEquals(1, HttpRangePolicy.RETRY_AFTER_SECONDS)
    }

    @Test
    fun delayedPieceArrivalAllows206OnlyAfterPieceIsReady() {
        val clock = FakeClock()
        val waiter = HttpPieceWaiter(
            hasPiece = { clock.now >= 200L },
            nowMs = { clock.now },
            sleepMs = clock::sleep
        )
        val ready = waiter.await(
            pieceIndex = 7,
            timeoutMs = 4_000L,
            isCancelled = { false }
        )
        assertTrue(ready)
        assertEquals(280L, clock.now)
        assertEquals(
            HttpPieceDecision.READY,
            HttpRangePolicy.beforeHeaders(pieceReady = ready, cancelled = false)
        )
    }

    @Test
    fun openEndedRangeChunksRemainContiguousAcrossPieceBoundaries() {
        val pieceLength = 256
        val fileOffset = 123L
        var position = 100L
        val end = 900L
        val chunks = mutableListOf<Pair<Long, Int>>()
        while (position <= end) {
            val amount = HttpRangePolicy.bytesToPieceEnd(
                globalOffset = fileOffset + position,
                pieceLength = pieceLength,
                remainingBytes = end - position + 1L,
                maxBufferBytes = 128
            )
            chunks += position to amount
            position += amount
        }
        assertEquals(901L, position)
        assertEquals(801L, chunks.sumOf { it.second.toLong() })
        for (index in 1 until chunks.size) {
            assertEquals(
                chunks[index - 1].first + chunks[index - 1].second,
                chunks[index].first
            )
        }
    }

    @Test
    fun midstreamPieceTimeoutAbortsCommittedBodyInsteadOfSending503() {
        assertEquals(
            HttpPieceDecision.ABORT,
            HttpRangePolicy.afterHeaders(pieceReady = false, cancelled = false)
        )
    }

    @Test
    fun disconnectCancelsWaitPromptly() {
        val clock = FakeClock()
        val waiter = HttpPieceWaiter(
            hasPiece = { false },
            nowMs = { clock.now },
            sleepMs = clock::sleep
        )
        val ready = waiter.await(
            pieceIndex = 12,
            timeoutMs = 45_000L,
            isCancelled = { clock.now >= 200L }
        )
        assertFalse(ready)
        assertEquals(200L, clock.now)
        assertEquals(
            HttpPieceDecision.CANCELLED,
            HttpRangePolicy.afterHeaders(pieceReady = false, cancelled = true)
        )
    }
}
