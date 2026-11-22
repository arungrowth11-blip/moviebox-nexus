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
    fun playbackPriorityWindowStartsAtSeekPieceAndPrefetchesThreePieces() {
        assertEquals(
            listOf(1979, 1980, 1981, 1982),
            HttpRangePolicy.playbackWindow(
                currentPiece = 1979,
                firstPiece = 1900,
                lastPiece = 2200,
                lookAheadPieces = HttpRangePolicy.PREFETCH_PIECES
            )
        )
        assertEquals(
            listOf(2199, 2200),
            HttpRangePolicy.playbackWindow(
                currentPiece = 2199,
                firstPiece = 1900,
                lastPiece = 2200,
                lookAheadPieces = HttpRangePolicy.PREFETCH_PIECES
            )
        )
        assertTrue(
            HttpRangePolicy.playbackWindow(
                currentPiece = 1899,
                firstPiece = 1900,
                lastPiece = 2200,
                lookAheadPieces = 3
            ).isEmpty()
        )
    }

    @Test
    fun playbackPriorityDeadlinesAreStaggeredAcrossPrefetchWindow() {
        assertEquals(0, HttpRangePolicy.deadlineForWindowOffset(0))
        assertEquals(2_500, HttpRangePolicy.deadlineForWindowOffset(1))
        assertEquals(5_000, HttpRangePolicy.deadlineForWindowOffset(2))
        assertEquals(7_500, HttpRangePolicy.deadlineForWindowOffset(3))
    }

    @Test
    fun bodyPieceWaitBudgetIsLongerThanFirstResponseRetryBudget() {
        assertEquals(45_000L, HttpRangePolicy.FIRST_RESPONSE_PIECE_WAIT_MS)
        assertEquals(180_000L, HttpRangePolicy.STREAM_PIECE_WAIT_MS)
    }

    @Test
    fun headRequestSkipsPieceWait() {
        assertFalse(HttpRangePolicy.shouldWaitForFirstPiece("HEAD"))
        assertTrue(HttpRangePolicy.shouldWaitForFirstPiece("GET"))
        assertTrue(HttpRangePolicy.shouldWaitForFirstPiece("get"))
    }

    @Test
    fun firstPieceBudgetAllowsACompletePieceToArriveAfterFourSeconds() {
        assertEquals(45_000L, HttpRangePolicy.FIRST_RESPONSE_PIECE_WAIT_MS)

        val clock = FakeClock()
        val waiter = HttpPieceWaiter(
            hasPiece = { clock.now >= 12_000L },
            nowMs = { clock.now },
            sleepMs = clock::sleep
        )
        val ready = waiter.await(
            pieceIndex = 0,
            timeoutMs = HttpRangePolicy.FIRST_RESPONSE_PIECE_WAIT_MS,
            isCancelled = { false }
        )

        assertTrue(ready)
        assertEquals(12_080L, clock.now)
        assertEquals(
            HttpPieceDecision.READY,
            HttpRangePolicy.beforeHeaders(pieceReady = ready, cancelled = false)
        )
    }

    @Test
    fun initialPieceTimeoutProducesRetryable503Decision() {
        val decision = HttpRangePolicy.beforeHeaders(pieceReady = false, cancelled = false)
        assertEquals(HttpPieceDecision.RETRY, decision)
        assertEquals(503, HttpRangePolicy.statusCode(decision))
        assertEquals("Retry-After: 1\r\n", HttpRangePolicy.retryAfterHeader())
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
    @Test
    fun closedByteRangeIsParsedExactly() {
        assertEquals(HttpByteRange(10L, 19L, true), HttpRangePolicy.parseRange("bytes=10-19", 100L))
    }

    @Test
    fun openEndedByteRangeExtendsToEndOfFile() {
        assertEquals(HttpByteRange(10L, 99L, true), HttpRangePolicy.parseRange("bytes=10-", 100L))
    }

    @Test
    fun suffixByteRangeSelectsLastBytes() {
        assertEquals(HttpByteRange(68L, 99L, true), HttpRangePolicy.parseRange("bytes=-32", 100L))
        assertEquals(HttpByteRange(0L, 99L, true), HttpRangePolicy.parseRange("bytes=-500", 100L))
    }

    @Test
    fun oversizedRangeEndIsClampedToFileEnd() {
        assertEquals(HttpByteRange(90L, 99L, true), HttpRangePolicy.parseRange("bytes=90-500", 100L))
    }

    @Test
    fun multipartRangesFallBackToFullResponseInsteadOfSilentlyDroppingParts() {
        assertEquals(HttpByteRange(0L, 99L, false), HttpRangePolicy.parseRange("bytes=0-9,20-29", 100L))
    }

    @Test
    fun unsupportedOrMalformedRangeUnitsFallBackToFullResponse() {
        assertEquals(HttpByteRange(0L, 99L, false), HttpRangePolicy.parseRange("items=0-9", 100L))
        assertEquals(HttpByteRange(0L, 99L, false), HttpRangePolicy.parseRange("bytes=abc-def", 100L))
        assertEquals(HttpByteRange(0L, 99L, false), HttpRangePolicy.parseRange("bytes=-", 100L))
    }

    @Test
    fun unsatisfiableByteRangesAreRejected() {
        assertEquals(null, HttpRangePolicy.parseRange("bytes=100-", 100L))
        assertEquals(null, HttpRangePolicy.parseRange("bytes=30-20", 100L))
        assertEquals(null, HttpRangePolicy.parseRange("bytes=-0", 100L))
        assertEquals(null, HttpRangePolicy.parseRange("bytes=0-1", 0L))
    }

}
