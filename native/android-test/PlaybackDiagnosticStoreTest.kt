package com.moviebox.nexus

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackDiagnosticStoreTest {
    @Test
    fun diagnosticTextRedactsUrlsHashesIpAddressesAndCredentials() {
        val hexHash = "a".repeat(40)
        val base32Hash = "B".repeat(32)
        val raw = "magnet:?xt=urn:btih:$hexHash " +
            "https://provider.example/private/video.m3u8 " +
            "udp://tracker.example:80/announce $base32Hash " +
            "Authorization: Bearer top-secret-token 192.168.1.24"

        val safe = PlaybackDiagnosticRedactor.sanitize(raw)

        assertFalse(safe.contains(hexHash))
        assertFalse(safe.contains(base32Hash))
        assertFalse(safe.contains("provider.example"))
        assertFalse(safe.contains("tracker.example"))
        assertFalse(safe.contains("top-secret-token"))
        assertFalse(safe.contains("192.168.1.24"))
        assertTrue(safe.contains("<redacted"))
    }

    @Test
    fun processFailureReportRedactsPrivateMediaAndNetworkDetails() {
        val report = PlaybackDiagnosticStore.processFailureReport(
            category = "previous_native_crash",
            threadName = "main",
            failureType = "ApplicationExitInfo/REASON_CRASH_NATIVE",
            details = "fault at /data/data/com.moviebox.nexus/cache/file.mkv for https://provider.example/x magnet query",
            frames = listOf("NativePlayer.read(/storage/emulated/0/private.mkv)")
        )
        assertFalse(report.contains("/data/data/"))
        assertFalse(report.contains("/storage/emulated/"))
        assertFalse(report.contains("provider.example"))
        assertTrue(report.contains("<redacted-path>"))
        assertTrue(report.contains("<redacted-url>"))
    }

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
    @Test
    fun diagnosticTextRedactsAllCommonAndroidPrivatePathForms() {
        val raw = listOf(
            "/data/user/0/com.moviebox.nexus/files/private.json",
            "/data/user_de/0/com.moviebox.nexus/files/private.json",
            "/data/data/com.moviebox.nexus/files/private.json",
            "/storage/emulated/0/Android/data/com.moviebox.nexus/files/private.json"
        ).joinToString(" ")

        val safe = PlaybackDiagnosticRedactor.sanitize(raw)

        assertFalse(safe.contains("/data/user/"))
        assertFalse(safe.contains("/data/user_de/"))
        assertFalse(safe.contains("/data/data/"))
        assertFalse(safe.contains("/storage/emulated/"))
        assertEquals(4, Regex("<redacted-path>").findAll(safe).count())
    }

    @Test
    fun reportAtExactByteLimitIsAccepted() {
        val root = Files.createTempDirectory("moviebox-diagnostics-exact-limit").toFile()
        try {
            val contents = "x".repeat(PlaybackDiagnosticStore.MAX_REPORT_BYTES.toInt())
            val saved = PlaybackDiagnosticStore.save(root, contents, 2_000_000_000_000L)

            assertTrue(saved.isFile)
            assertEquals(PlaybackDiagnosticStore.MAX_REPORT_BYTES, saved.length())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun oversizedReportIsRejectedBeforeCreatingDiagnosticFiles() {
        val root = Files.createTempDirectory("moviebox-diagnostics-oversized").toFile()
        try {
            val contents = "x".repeat(PlaybackDiagnosticStore.MAX_REPORT_BYTES.toInt() + 1)
            var rejected = false
            try {
                PlaybackDiagnosticStore.save(root, contents, 2_000_000_000_000L)
            } catch (_: IllegalArgumentException) {
                rejected = true
            }

            assertTrue("Oversized report must be rejected.", rejected)
            assertFalse(File(root, PlaybackDiagnosticStore.DIRECTORY_NAME).exists())
        } finally {
            root.deleteRecursively()
        }
    }
}
