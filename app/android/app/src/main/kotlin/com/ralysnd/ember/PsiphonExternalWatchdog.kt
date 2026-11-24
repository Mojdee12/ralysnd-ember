package com.ralysnd.ember

import android.app.ActivityManager
import android.content.Context
import android.os.Process
import java.io.File

/**
 * Build 2088: the Psiphon external watchdog — the wedge net
 * that lives OUTSIDE the process it watches.
 *
 * Build 2087 put the wedge instrumentation inside the
 * :psiphon process (heartbeat + watchdog + bounded stops),
 * and the owner's phone answered the question that design
 * left open: on a wedged start the heartbeat fired once and
 * the watchdog's `psiphon:start-wedged` record NEVER landed,
 * although ~28 s passed. A process wedged hard enough cannot
 * be trusted to report — or end — its own wedge. So the
 * recording and the killing move here, to the main process:
 *
 * The Dart connect path arms a deadline per attempt (see
 * psiphon_watchdog.dart for the decision). When it fires,
 * this object: (a) finds the :psiphon pid, (b) writes the
 * `psiphon:external-watchdog` breadcrumb plus a /proc thread
 * dump to crash.log — every task's comm, state and wchan,
 * the closest thing to a tombstone readable from outside —
 * (c) kills the process (same UID, so the kill is ours to
 * make), and (d) publishes the terminal wedged snapshot the
 * connect path fails fast on.
 *
 * Everything here is best-effort and guarded: the watchdog
 * is evidence + a bound, never a new failure mode. What it
 * cannot do is prove WHY the library wedged — the dump it
 * leaves is the evidence the next diagnosis reads.
 */
object PsiphonExternalWatchdog {

    /** Runs one firing. Returns what happened for the
     *  caller's log: whether the process was found and
     *  whether the kill was delivered. */
    fun fire(context: Context): Map<String, Any?> {
        CrashLog.breadcrumb(context, "psiphon:external-watchdog")
        val pid = findPsiphonPid(context)
        val dump = StringBuilder()
        dump.append("==== psiphon external watchdog ====\n")
        dump.append("time: ").append(System.currentTimeMillis()).append('\n')
        if (pid == null) {
            dump.append("process: not found (already gone)\n")
        } else {
            dump.append("pid: ").append(pid).append('\n')
            dump.append(procDump(pid))
        }
        try {
            CrashLog.appendBounded(
                File(context.filesDir, CrashLog.FILE_NAME),
                dump.toString(),
            )
        } catch (_: Throwable) {
            // The kill + publish below still proceed.
        }
        var killed = false
        if (pid != null) {
            try {
                Process.killProcess(pid)
                killed = true
            } catch (_: Throwable) {
                // Already gone between the find and the kill.
            }
        }
        PsiphonVpnService.publishExternalWedged(context)
        return mapOf(
            "found" to (pid != null),
            "killed" to killed,
            "pid" to (pid ?: -1),
        )
    }

    /** The :psiphon process's pid, or null. ActivityManager
     *  first (it reports this app's own processes, which is
     *  exactly the one process we may kill); a /proc cmdline
     *  scan as the fallback (same UID, so readable). */
    internal fun findPsiphonPid(context: Context): Int? {
        val name = context.packageName + ":psiphon"
        try {
            val am = context.getSystemService(ActivityManager::class.java)
            val processes = am?.runningAppProcesses
            if (processes != null) {
                for (p in processes) {
                    if (p.processName == name) return p.pid
                }
            }
        } catch (_: Throwable) {
            // Fall through to the /proc scan.
        }
        try {
            val procRoot = File("/proc")
            val entries = procRoot.listFiles() ?: return null
            for (entry in entries) {
                val pid = entry.name.toIntOrNull() ?: continue
                try {
                    val raw = File(entry, "cmdline").readBytes()
                    val cmd = String(raw, Charsets.UTF_8)
                        .trim { it <= ' ' || it == '\u0000' }
                    if (cmd == name) return pid
                } catch (_: Throwable) {
                    // Not readable / already gone; keep scanning.
                }
            }
        } catch (_: Throwable) {
            // No scan possible; the caller records "not found".
        }
        return null
    }

    /** Every thread of [pid] from /proc: comm, state, wchan.
     *  Best-effort per task — a thread that exits mid-dump
     *  simply leaves a partial line out. Bounded: at most
     *  [MAX_TASKS] tasks and [MAX_CHARS] characters, so the
     *  record can never flood crash.log. */
    private fun procDump(pid: Int): String {
        val out = StringBuilder()
        try {
            val stat = File("/proc/$pid/stat").readText()
            out.append("process state: ").append(statState(stat) ?: "?").append('\n')
        } catch (_: Throwable) {
            out.append("process state: unreadable\n")
        }
        val taskRoot = File("/proc/$pid/task")
        val tasks = try {
            taskRoot.listFiles()?.sortedBy { it.name } ?: emptyList()
        } catch (_: Throwable) {
            emptyList()
        }
        var count = 0
        for (task in tasks) {
            if (count >= MAX_TASKS || out.length >= MAX_CHARS) break
            val tid = task.name
            val comm = try {
                File(task, "comm").readText().trim()
            } catch (_: Throwable) {
                "?"
            }
            val state = try {
                statState(File(task, "stat").readText()) ?: "?"
            } catch (_: Throwable) {
                "?"
            }
            val wchan = try {
                File(task, "wchan").readText().trim().ifEmpty { "-" }
            } catch (_: Throwable) {
                "?"
            }
            out.append("task ").append(tid)
                .append(" comm=").append(comm)
                .append(" state=").append(state)
                .append(" wchan=").append(wchan)
                .append('\n')
            count++
        }
        if (tasks.isEmpty()) out.append("tasks: unreadable\n")
        return out.toString()
    }

    /** The state letter of a /proc stat line: the first
     *  field after the closing parenthesis of comm (comm
     *  itself may contain spaces and parentheses). */
    private fun statState(stat: String): String? {
        val close = stat.lastIndexOf(')')
        if (close < 0 || close + 2 >= stat.length) return null
        return stat.substring(close + 2).split(' ').firstOrNull()
    }

    private const val MAX_TASKS = 80
    private const val MAX_CHARS = 6000
}
