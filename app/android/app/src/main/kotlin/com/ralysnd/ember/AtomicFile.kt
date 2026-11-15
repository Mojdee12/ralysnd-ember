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
        val tmp = File(file.parentFile, "${file.name}.tmp")
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
}
