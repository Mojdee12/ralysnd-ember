package com.ralysnd.ember

import android.content.Context
import java.io.File
import java.io.FileOutputStream

/**
 * The Psiphon provider's sidecar (build 2089): a sing-box
 * executable built from Hiddify's fork (hiddify-sing-box
 * @1614c5edb52dd44a4cc079201ba1e790fdfad8a0), whose
 * "psiphon" outbound wraps psiphon-tunnel-core
 * v1.0.11-0.20260126173038-c86a1497a760. It replaces the
 * in-process gomobile AAR (libs/psiphon.aar, removed in
 * this build) whose first library call wedged below the
 * JNI entry on the owner's Android 16 phone across builds
 * 2065–2088. The fork's Android core is built with Go
 * 1.27.3 and -Wl,-z,max-page-size=16384 (16 KB pages) —
 * the first Psiphon artifact built for Android 16. The
 * exact recipe lives in engines/psiphonbox/PROVENANCE.md.
 *
 * Shape: the Dart side generates the config (one loopback
 * SOCKS inbound on the engine's port, one psiphon
 * outbound) into filesDir/psiphonbox/config.json before
 * every start (PsiphonPlatform.setOn); this core runs it
 * with `run -c <path>` from the SubprocessCore lifecycle,
 * and PsiphonVpnService — in whose :psiphon process this
 * object lives, like the service itself — drives the TUN,
 * the published state and the connect probe over the
 * SOCKS. Readiness here is only the box's listener; a
 * working tunnel is the service's data probe, never this
 * flag (the fork outbound accepts SOCKS connections
 * before its tunnel exists and fails them fast).
 */
object PsiphonBoxCore : SubprocessCore(
    libName = "libpsiphonbox.so",
    dirName = "psiphonbox",
    port = PsiphonConstants.SOCKS_PORT,
    tcpProbe = true,
    label = "Psiphon sidecar",
) {
    /** The provider identity the start path breadcrumbs
     *  (build 2089): fork commit + tunnel-core version, so
     *  a crash log names exactly which core ran. */
    const val PROVIDER_ID =
        "hiddify-sing-box@1614c5e + psiphon-tunnel-core " +
            "v1.0.11-0.20260202154140-a3384a551c62 (go1.27.3)"

    /** The config the Dart side writes before each start. */
    fun configFile(context: Context): File =
        File(workDir(context), "config.json")

    /** The spawn arguments for [start]. */
    fun startArgs(context: Context): List<String> =
        listOf("run", "-c", configFile(context).absolutePath)

    /** Build 2090: the extracted embedded server entries —
     *  the file the generated config names in the outbound's
     *  embedded_server_entries_file (fork patch #1; see
     *  engines/psiphonbox/PROVENANCE.md). The service
     *  extracts it from the bundled asset before every
     *  spawn: the fork's import errors the start when the
     *  named file is missing, so the path in the config and
     *  this file are one contract. */
    fun embeddedEntriesFile(context: Context): File =
        File(workDir(context), "embedded_servers.txt")

    /** The asset path of the entries inside the APK
     *  (Flutter's asset layout for assets/psiphon/). */
    const val EMBEDDED_ENTRIES_ASSET =
        "flutter_assets/assets/psiphon/embedded_servers.txt"

    /** Extracts the bundled entries asset to
     *  [embeddedEntriesFile] (tmp + rename, so a reader
     *  never sees a torn file). Re-extracted at every
     *  start: the copy is 1 MB and a fresh copy can never
     *  be a stale one. Returns false with the reason in
     *  [lastError]-style plain text via the exception the
     *  caller logs — extraction failure is a failed start,
     *  never a silent run without the entries floor. */
    fun extractEmbeddedEntries(context: Context): Boolean {
        val target = embeddedEntriesFile(context)
        val tmp = File(workDir(context), "embedded_servers.txt.tmp")
        return try {
            context.assets.open(EMBEDDED_ENTRIES_ASSET).use { input ->
                FileOutputStream(tmp).use { out -> input.copyTo(out) }
            }
            if (tmp.length() == 0L) {
                tmp.delete()
                return false
            }
            if (!tmp.renameTo(target)) {
                tmp.copyTo(target, overwrite = true)
                tmp.delete()
            }
            target.isFile && target.length() > 0L
        } catch (e: Exception) {
            try {
                tmp.delete()
            } catch (_: Exception) {
                // Nothing to clean.
            }
            false
        }
    }

    /** Build 2090: the box's own recent words — the last
     *  [maxLines] lines of its stdout log (the sing-box log
     *  lands there; the tunnel core's notices ride it at
     *  Info since fork patch #2), then its stderr tail,
     *  then the lifecycle's last error when there is one.
     *  This is the evidence the service appends to
     *  psiphon.log when an establishment fails, and it is
     *  deliberately read from the files, not the process:
     *  it must work even when the box has already exited. */
    fun logTail(context: Context, maxLines: Int = 20): String {
        val out = StringBuilder()
        val stdout = tailLines(File(workDir(context), "psiphonbox-stdout.log"), maxLines)
        if (stdout.isNotEmpty()) {
            out.append(stdout)
        }
        val stderr = tailLines(File(workDir(context), "psiphonbox-stderr.log"), 5)
        if (stderr.isNotEmpty()) {
            if (out.isNotEmpty()) out.append('\n')
            out.append(stderr)
        }
        if (lastError.isNotEmpty()) {
            if (out.isNotEmpty()) out.append('\n')
            out.append("sidecar state: ").append(lastError)
        }
        return out.toString()
    }

    /** The last [maxLines] lines of [file] (bounded read:
     *  the last 64 KB), or "" when there is nothing. */
    private fun tailLines(file: File, maxLines: Int): String {
        return try {
            if (!file.isFile) return ""
            val bytes = file.readBytes()
            val tail = if (bytes.size > 64 * 1024) {
                bytes.copyOfRange(bytes.size - 64 * 1024, bytes.size)
            } else {
                bytes
            }
            val lines = String(tail, Charsets.UTF_8)
                .split('\n')
                .map { it.trimEnd() }
                .filter { it.isNotEmpty() }
            lines.takeLast(maxLines).joinToString("\n")
        } catch (e: Exception) {
            ""
        }
    }
}
