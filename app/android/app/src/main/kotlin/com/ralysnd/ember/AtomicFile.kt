package com.ralysnd.ember

import java.io.File
import java.io.FileOutputStream

/**
 * Atomic small-file writes (build 2054, audit F-M6): write
 * to a sibling temp file, flush + fsync, then rename over
 * the target. A reader can never meet a half-written
 * document, and a kill mid-write leaves the previous good
 * file in place instead of a torn one.
 *
 * Used for the Kotlin session config.json (XrayVpnService)
 * and the Dart-side Mozilla core config.json (via the same
 * shape on the Dart side — see AtomicJsonStore).
 */
object AtomicFile {
    /** Writes [text] to [file] atomically (tmp + sync + rename). */
    fun writeText(file: File, text: String) {
        writeBytes(file, text.toByteArray(Charsets.UTF_8))
    }

    /** Writes [bytes] to [file] atomically (tmp + sync + rename). */
    fun writeBytes(file: File, bytes: ByteArray) {
        // Build 2125 (audit A25-01 / P-07): the temp name is
        // PER-WRITER (pid + thread). Up to 2124 every writer
        // shared one "<name>.tmp", so two processes writing
        // the same target concurrently (the engine-claim
        // marker above all) truncated and renamed each
        // other's temp file — the rename could land the
        // other writer's bytes, or fail outright. The rename
        // itself stays atomic; only the scratch name is now
        // private to this write.
        val tmp = File(
            file.parentFile,
            "${file.name}.${android.os.Process.myPid()}." +
                "${Thread.currentThread().id}.tmp",
        )
        FileOutputStream(tmp).use { out ->
            out.write(bytes)
            out.flush()
            out.fd.sync()
        }
        // Same directory, so the rename is atomic on the
        // device's filesystem; it replaces any previous file.
        if (!tmp.renameTo(file)) {
            // renameTo's boolean is the only signal on old
            // APIs — a false here means the new bytes never
            // landed; the old file (if any) is untouched.
            tmp.delete()
            throw java.io.IOException("atomic rename failed for ${file.name}")
        }
    }

    /**
     * Build 2126 (audit A26-29): deletes orphaned temp
     * files in [dir] — a process killed between the write
     * above and its rename leaves `<name>.<pid>.<tid>.tmp`
     * behind forever, and nothing ever cleaned them up.
     * Conservative by construction: a candidate must carry
     * a FOREIGN pid (a live writer in this process is
     * untouchable) AND be over an hour old (a live writer
     * in another process — the :psiphon process writes
     * through this same shape — finishes in milliseconds;
     * the age bound is what makes a foreign pid safe to
     * reap). Best effort; never throws.
     */
    fun sweepOrphans(dir: File) {
        try {
            val mine = android.os.Process.myPid().toString()
            val cutoff = System.currentTimeMillis() - 60 * 60 * 1000
            val pattern = Regex("""^.+\.(\d+)\.\d+\.tmp$""")
            dir.listFiles()?.forEach { f ->
                val m = pattern.matchEntire(f.name) ?: return@forEach
                if (m.groupValues[1] != mine && f.lastModified() < cutoff) {
                    f.delete()
                }
            }
        } catch (e: Exception) {
            // A failed sweep changes nothing.
        }
    }
}
