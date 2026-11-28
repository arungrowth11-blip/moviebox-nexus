package com.moviebox.nexus

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID

/**
 * Bounded, failure-only diagnostic report storage.
 *
 * Reports are written below the app's private files directory. No stream URLs,
 * info-hashes, credentials, or raw logcat output are stored by this class.
 */
internal object PlaybackDiagnosticStore {
    const val DIRECTORY_NAME = "playback-diagnostics"
    const val MAX_REPORTS = 5
    const val MAX_AGE_MS = 7L * 24L * 60L * 60L * 1000L
    const val MAX_REPORT_BYTES = 256L * 1024L
    private const val FILE_PREFIX = "failure-"

    /**
     * Bounded, sanitized summary for an uncaught exception or Android process
     * exit reason. Raw logcat and native tombstone contents are never stored.
     */
    fun processFailureReport(
        category: String,
        threadName: String,
        failureType: String,
        details: String,
        frames: List<String> = emptyList(),
        timestampMs: Long = System.currentTimeMillis()
    ): String {
        fun quote(raw: String): String {
            val safe = PlaybackDiagnosticRedactor.sanitize(raw)
            return "\"" + safe
                .replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\r", "\\r")
                .replace("\n", "\\n")
                .replace("\t", "\\t") + "\""
        }
        val frameJson = frames.take(12).joinToString(",") { quote(it) }
        return "{\"schemaVersion\":1," +
            "\"timestampMs\":" + timestampMs + "," +
            "\"category\":" + quote(category) + "," +
            "\"thread\":" + quote(threadName) + "," +
            "\"failureType\":" + quote(failureType) + "," +
            "\"details\":" + quote(details) + "," +
            "\"frames\":[" + frameJson + "]}"
    }

    fun save(
        privateFilesDir: File,
        contents: String,
        nowMs: Long = System.currentTimeMillis()
    ): File {
        val bytes = contents.toByteArray(Charsets.UTF_8)
        require(bytes.size.toLong() <= MAX_REPORT_BYTES) {
            "Playback diagnostic report exceeds the bounded size limit."
        }

        val directory = File(privateFilesDir, DIRECTORY_NAME)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IOException("Could not create the private playback diagnostics directory.")
        }
        prune(directory, nowMs)

        val id = UUID.randomUUID().toString()
        val temporary = File(directory, ".pending-$id.tmp")
        val report = File(directory, "$FILE_PREFIX$nowMs-$id.json")
        try {
            FileOutputStream(temporary).use { stream ->
                stream.write(bytes)
                stream.fd.sync()
            }
            if (!temporary.renameTo(report)) {
                throw IOException("Could not finalize the private playback diagnostic report.")
            }
            report.setLastModified(nowMs)
            prune(directory, nowMs)
            return report
        } finally {
            if (temporary.exists()) temporary.delete()
        }
    }

    /** Deletes expired reports and then keeps only the newest [MAX_REPORTS]. */
    fun prune(directory: File, nowMs: Long = System.currentTimeMillis()): Int {
        val allFiles = directory.listFiles() ?: return 0
        var deleted = 0
        allFiles.filter { file ->
            file.isFile && file.name.startsWith(".pending-") && file.name.endsWith(".tmp")
        }.forEach { temporary ->
            if (nowMs - temporary.lastModified() > 60L * 60L * 1000L && temporary.delete()) {
                deleted++
            }
        }

        val reports = allFiles.filter { file ->
            file.isFile && file.name.startsWith(FILE_PREFIX) && file.extension == "json"
        }.sortedByDescending { it.lastModified() }

        val fresh = reports.filter { report ->
            val age = (nowMs - report.lastModified()).coerceAtLeast(0L)
            if (age > MAX_AGE_MS) {
                if (report.delete()) deleted++
                false
            } else {
                true
            }
        }
        fresh.drop(MAX_REPORTS).forEach { report ->
            if (report.delete()) deleted++
        }
        return deleted
    }

    /**
     * Read one previously sanitized report from the app-private diagnostics
     * directory. Only generated report IDs are accepted; traversal and
     * arbitrary file reads are rejected.
     */
    fun readReport(privateFilesDir: File, reportName: String): String {
        require(Regex("""^failure-\d+-[0-9a-fA-F-]{36}\.json$""").matches(reportName)) {
            "Invalid private playback diagnostic report identifier."
        }
        val directory = File(privateFilesDir, DIRECTORY_NAME).canonicalFile
        val report = File(directory, reportName).canonicalFile
        require(report.parentFile == directory) {
            "Playback diagnostic report path escaped its private directory."
        }
        if (!report.isFile || report.length() > MAX_REPORT_BYTES) {
            throw IOException("Private playback diagnostic report is unavailable or oversized.")
        }
        return report.readText(Charsets.UTF_8)
    }

    /** Return the newest retained report without exposing the directory path. */
    fun readLatestReport(privateFilesDir: File): Map<String, String>? {
        val directory = File(privateFilesDir, DIRECTORY_NAME).canonicalFile
        val latest = directory.listFiles { file ->
            file.isFile &&
                file.name.startsWith(FILE_PREFIX) &&
                file.extension == "json" &&
                file.length() <= MAX_REPORT_BYTES
        }?.maxByOrNull { it.lastModified() } ?: return null

        return mapOf(
            "reportId" to latest.name,
            "contents" to readReport(privateFilesDir, latest.name)
        )
    }
}

/** Conservative redaction for diagnostic text copied from native/player errors. */
internal object PlaybackDiagnosticRedactor {
    fun sanitize(raw: String): String {
        var value = raw.replace(
            Regex("""(?i)magnet:\?[^\s"'<>]+"""),
            "<redacted-magnet>"
        )
        value = value.replace(
            Regex("""(?i)(?:https?|udp)://[^\s"'<>]+"""),
            "<redacted-url>"
        )
        value = value.replace(Regex("""\b[a-fA-F0-9]{40}\b"""), "<redacted-infohash>")
        value = value.replace(Regex("""(?i)\b[A-Z2-7]{32}\b"""), "<redacted-infohash>")
        value = value.replace(
            Regex("""(?i)\b(token|authorization|api[_-]?key|password|secret)\s*[:=]\s*(?:Bearer\s+)?[^,\s;&]+"""),
            "$1=<redacted>"
        )
        value = value.replace(
            Regex("""(?i)(?<![0-9a-f:])(?:(?:[0-9a-f]{1,4}:){1,7}|:)(?::[0-9a-f]{1,4}){1,7}(?![0-9a-f:])|(?<![0-9a-f:])::(?:[0-9a-f]{1,4}:){0,6}[0-9a-f]{1,4}(?![0-9a-f:])"""),
            "<redacted-ip>"
        )
        value = value.replace(
            Regex("""\b(?:\d{1,3}\.){3}\d{1,3}\b"""),
            "<redacted-ip>"
        )
        value = value.replace(
            Regex("""(?:/data/(?:user|user_de)/\d+/[^\s"'<>]+|/data/data/[^\s"'<>]+|/data/media/\d+/[^\s"'<>]+|/storage/emulated/\d+/[^\s"'<>]+|/storage/self/primary/[^\s"'<>]+|/storage/[A-Fa-f0-9-]{4,}/[^\s"'<>]+|/mnt/sdcard/[^\s"'<>]+|/sdcard/[^\s"'<>]+)"""),
            "<redacted-path>"
        )
        return value.take(320)
    }
}
