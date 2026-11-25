package com.moviebox.nexus

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackDiagnosticStoreTest {
    @Test
    fun expiredReportsAreDeletedAndUnrelatedFilesArePreserved() {
        val root = Files.createTempDirectory("moviebox-diagnostics-expiry").toFile()
        try {
            val directory = File(root, PlaybackDiagnosticStore.DIRECTORY_NAME).apply { mkdirs() }
            val now = 2_000_000_000_000L
            val expired = File(directory, "failure-expired.json").apply {
                writeText("{}")
                setLastModified(now - PlaybackDiagnosticStore.MAX_AGE_MS - 1L)
            }
            val unrelated = File(directory, "keep.txt").apply { writeText("keep") }

            val deleted = PlaybackDiagnosticStore.prune(directory, now)

            assertEquals(1, deleted)
            assertFalse(expired.exists())
            assertTrue(unrelated.exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun onlyFiveNewestFailureReportsAreRetained() {
        val root = Files.createTempDirectory("moviebox-diagnostics-count").toFile()
        try {
            val directory = File(root, PlaybackDiagnosticStore.DIRECTORY_NAME).apply { mkdirs() }
            val now = 2_000_000_000_000L
            val reports = (0 until 7).map { index ->
                File(directory, "failure-$index.json").apply {
                    writeText("{}")
                    setLastModified(now - index * 1_000L)
                }
            }

            val deleted = PlaybackDiagnosticStore.prune(directory, now)

            assertEquals(2, deleted)
            assertTrue(reports.take(5).all { it.exists() })
            assertFalse(reports[5].exists())
            assertFalse(reports[6].exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun savedReportsArePrivateBoundedAndRotated() {
        val root = Files.createTempDirectory("moviebox-diagnostics-save").toFile()
        try {
            val now = 2_000_000_000_000L
            val saved = PlaybackDiagnosticStore.save(root, """{"schemaVersion":1}""", now)

            assertTrue(saved.isFile)
            assertTrue(saved.canonicalPath.startsWith(root.canonicalPath))
            assertEquals("""{"schemaVersion":1}""", saved.readText())
            assertEquals(1, File(root, PlaybackDiagnosticStore.DIRECTORY_NAME).listFiles()!!.size)
        } finally {
            root.deleteRecursively()
        }
    }
}
