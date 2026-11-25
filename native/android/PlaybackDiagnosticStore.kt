package com.moviebox.nexus

import java.io.File
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

    fun save(privateFilesDir: File, contents: String, nowMs: Long = System.currentTimeMillis()): File {
        val bytes = contents.toByteArray(Charsets.UTF_8)
        require(bytes.size.toLong() <= MAX_REPORT_BYTES) {
            "Playback diagnostic report exceeds the bounded size limit."
        }

        val directory = File(privateFilesDir, DIRECTORY_NAME)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IOException("Could not create the private playback diagnostics directory.")
        }
        prune(directory, nowMs)

        val report = File(directory, "$FILE_PREFIX$nowMs-${UUID.randomUUID()}.json")
        report.writeBytes(bytes)
        report.setLastModified(nowMs)
        prune(directory, nowMs)
        return report
    }

    /** Deletes expired reports and then keeps only the newest [MAX_REPORTS]. */
    fun prune(directory: File, nowMs: Long = System.currentTimeMillis()): Int {
        val reports = directory.listFiles { file ->
            file.isFile && file.name.startsWith(FILE_PREFIX) && file.extension == "json"
        }?.sortedByDescending { it.lastModified() } ?: return 0

        var deleted = 0
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
}
