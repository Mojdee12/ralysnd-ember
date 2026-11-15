package com.ralysnd.ember

import android.content.Context
import android.os.Build
import java.io.File
import java.io.FileOutputStream
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Build 2068: the crash recorder.
 *
 * Two blind fix rounds (2066's bridge, 2067's start guard) failed
 * to stop the owner's fresh-install Psiphon tap-crash, and both
 * times the evidence on the phone was the same: no log at all.
 * The start handoff's remaining throwables are either
 * [java.lang.Error]s — which the 2067 guards, catching only
 * Exception, let straight through — or natives that leave no
 * trace anywhere Ember looks. This file exists so the NEXT
 * failure records itself:
 *
 *  - [install] puts a default uncaught-exception handler in
 *    place as early as the process allows (EmberApplication's
 *    attachBaseContext). On an uncaught throwable it appends
 *    one record (timestamp, build, thread, throwable class,
 *    message, full stack) to filesDir/crash.log with plain
 *    synchronous file IO, then CHAINS to the handler it
 *    replaced — the system still kills the app exactly as
 *    before; the death just stops being silent.
 *  - [append] is the same record for throwables a guard DID
 *    catch (the 2067 start branches, askForNotifications, the
 *    VPN services' onStartCommand nets): a handled fatal leaves
 *    the same evidence an unhandled one does.
 *
 * The file is bounded: past ~256 KB it rotates to
 * crash.log.old. Every write is wrapped so a recorder failure
 * can never mask the crash it was recording, and [install]
 * itself can never break app start.
 */
object CrashLog {

    const val FILE_NAME = "crash.log"
    private const val OLD_NAME = "crash.log.old"
    private const val MAX_BYTES = 256L * 1024L

    @Volatile
    private var filesDir: File? = null

    @Volatile
    private var versionLabel: String = "unknown"

    @Volatile
    private var installed = false

    /**
     * Remembers where crash.log lives and (once per process)
     * installs the chaining uncaught-exception handler. Safe to
     * call from every component; later calls only refresh the
     * remembered directory/label.
     */
    fun install(context: Context) {
        try {
            val app = context.applicationContext ?: context
            filesDir = app.filesDir
            versionLabel = versionLabelOf(app)
            synchronized(this) {
                if (installed) return
                installed = true
                val previous = Thread.getDefaultUncaughtExceptionHandler()
                Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
                    try {
                        appendRecord("uncaught", thread.name, throwable)
                    } catch (_: Throwable) {
                        // The record is best-effort; the chain
                        // below is the behaviour that must hold.
                    }
                    if (previous != null) {
                        previous.uncaughtException(thread, throwable)
                    } else {
                        // No system handler to chain to (cannot
                        // happen on Android — the runtime installs
                        // one before app code runs): keep the
                        // system's observable behaviour, a dead
                        // process, rather than limping on.
                        android.os.Process.killProcess(android.os.Process.myPid())
                    }
                }
            }
        } catch (_: Throwable) {
            // A recorder that can break app start is worse than
            // no recorder.
        }
    }

    /**
     * Appends one record to filesDir/crash.log for a throwable
     * a guard caught. Never throws.
     */
    fun append(context: Context, where: String, throwable: Throwable) {
        try {
            if (filesDir == null) install(context)
            appendRecord(where, Thread.currentThread().name, throwable)
        } catch (_: Throwable) {
            // Evidence is best-effort; the caller's own handling
            // (the channel error, the graceful stop) must proceed.
        }
    }

    /**
     * Appends ONE breadcrumb line (timestamp + [tag]) to
     * crash.log, synchronously, before the caller takes its
     * next step. Breadcrumbs are the trail that survives the
     * deaths this recorder otherwise cannot see: a native
     * abort (a .so load/init failure in this process) runs no
     * Java handler at all, but every breadcrumb written before
     * it is already on disk, interleaved with any crash record
     * in the one file the owner pastes. The build tags every
     * stage boundary of the Psiphon start path (the engine
     * that dies on the owner's phone) `psiphon:<step>`, plus a
     * coarse Xray trail as the healthy control — the LAST
     * breadcrumb before a death names the dying step.
     * Cheap by construction: one small append, no UI, no
     * behaviour change, never throws.
     */
    fun breadcrumb(context: Context, tag: String) {
        try {
            if (filesDir == null) install(context)
            val dir = filesDir ?: return
            appendBounded(File(dir, FILE_NAME), formatBreadcrumb(timestampNow(), tag))
        } catch (_: Throwable) {
            // A breadcrumb must never become a failure of its
            // own; the trail is evidence, not behaviour.
        }
    }

    /** One breadcrumb line, exactly as it lands in the file. Pure. */
    fun formatBreadcrumb(timestamp: String, tag: String): String =
        "$timestamp [breadcrumb] $tag\n"

    /**
     * Appends one record to an explicit file — the VPN services'
     * nets write straight into their own session log (e.g. the
     * psiphon workDir's psiphon.log), which the owner already
     * reads, in addition to crash.log. Plain synchronous IO,
     * same bounded rotation. Never throws.
     */
    fun appendToFile(file: File, where: String, throwable: Throwable) {
        try {
            val record = formatRecord(
                timestampNow(),
                versionLabel,
                where,
                Thread.currentThread().name,
                throwable,
            )
            appendBounded(file, record)
        } catch (_: Throwable) {
            // As in [append]: best-effort only.
        }
    }

    private fun appendRecord(where: String, threadName: String, throwable: Throwable) {
        val dir = filesDir ?: return
        val record = formatRecord(
            timestampNow(),
            versionLabel,
            where,
            threadName,
            throwable,
        )
        appendBounded(File(dir, FILE_NAME), record)
    }

    /**
     * One record, exactly as it lands in the file. Pure (no
     * Android, no IO) so the shape is host-testable: header
     * lines naming when/what/where, then the throwable's own
     * full stack trace, cause chain included.
     */
    fun formatRecord(
        timestamp: String,
        version: String,
        where: String,
        threadName: String,
        throwable: Throwable,
    ): String {
        val writer = StringWriter()
        val printer = PrintWriter(writer)
        throwable.printStackTrace(printer)
        printer.flush()
        val stack = writer.toString()
        return buildString {
            append("==== ember crash record ====\n")
            append("time: ").append(timestamp).append('\n')
            append("build: ").append(version).append('\n')
            append("where: ").append(where).append('\n')
            append("thread: ").append(threadName).append('\n')
            append("throwable: ").append(throwable.javaClass.name)
            append(": ").append(throwable.message).append('\n')
            append(stack)
            if (!stack.endsWith("\n")) append('\n')
        }
    }

    /**
     * Appends [text] to [file], rotating the file to
     * "<name>.old" first when it has reached the size bound, so
     * crash.log stays bounded no matter how often a broken
     * build dies. Plain synchronous IO — deliberately no
     * executor, channel, or buffered writer that could itself
     * fail silently or lose the record when the process dies
     * right after.
     */
    fun appendBounded(file: File, text: String) {
        synchronized(this) {
            file.parentFile?.mkdirs()
            if (file.exists() && file.length() >= MAX_BYTES) {
                val old = File(file.parentFile, file.name + ".old")
                try {
                    if (old.exists()) old.delete()
                    file.renameTo(old)
                } catch (_: Throwable) {
                    // A failed rotation must not lose the record
                    // being written; appending past the bound
                    // once is the lesser evil.
                }
            }
            FileOutputStream(file, true).use { out ->
                out.write(text.toByteArray(Charsets.UTF_8))
                out.flush()
            }
        }
    }

    private fun timestampNow(): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS Z", Locale.US).format(Date())

    private fun versionLabelOf(context: Context): String {
        return try {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toLong()
            }
            "${info.versionName} ($code)"
        } catch (_: Throwable) {
            "unknown"
        }
    }
}
