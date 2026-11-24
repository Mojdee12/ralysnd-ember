package com.ralysnd.ember

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.File
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import kotlin.concurrent.thread

/**
 * The Senpai scanner (build 2129, Leg 3): matinsenpai's
 * SenPaiScanner (MIT, github.com/matinsenpai/senpaiscanner)
 * as the LML bridge binary — `libsenpai_lml.so`
 * (34,297,928 B, sha256 4ca1a8d9…), vendored byte-exact
 * from the LML APK extract. It embeds its own Xray core
 * and discovers working endpoints (public IP sources,
 * neighbour scan, anti-DPI probes with real Xray), which
 * is the one thing Ember's own probers do not do.
 *
 * Why this is not a [SubprocessCore] subclass: the bridge
 * protocol is a JSON-lines conversation — the request is
 * written to the child's STDIN and events stream back on
 * its STDOUT — while SubprocessCore's contract fixes stdin
 * to /dev/null and treats stdout as a log. Everything else
 * follows the SubprocessCore pattern exactly: binary from
 * nativeLibraryDir, per-engine work dir, pid file written
 * at spawn, recorded orphan reaped at the next start, the
 * streams drained on separate threads into separate files
 * (stderr is evidence here too — LML discards it to
 * /dev/null; Ember keeps it), exit owned by a waiter.
 *
 * The wire contract (from the LML host, ScanManager):
 * spawn with NO arguments, CWD = the work dir, HOME =
 * filesDir. Write ONE request JSON line to stdin:
 * {action: "scan"|"resume"|"speed", count, workers,
 * timeoutMs, ports[], targets, gentle, requireWS,
 * neighborScan, directOnly, speedSize, minSpeed, topN,
 * antiDpi{enabled, finalmask, fingerprint, alpn,
 * cipherSuites}} (the Dart side builds it — senpai.dart).
 * Events arrive as JSON lines on stdout: {type:"phase",
 * phase}, {type:"stats", tested, total, healthy},
 * {type:"results", rows[{ip, port, latency, jitter, loss,
 * colo}]}, {type:"direct-speed", ip, port, success,
 * bytesPerSecond, latency, done, total}, {type:"error",
 * code}, {type:"done", failed, cancelled}. Writing
 * {"stop":true} asks the scanner to save its state and
 * exit; the resumable state lands in
 * filesDir/senpai-resume/scan-state.json (the binary's
 * own ../senpai-resume path, relative to this work dir).
 *
 * Execution host (delta §3(c) decision): the scanner runs
 * in the app process, driven over the same MethodChannel
 * pattern as every other Lab sidecar (Zapret & friends) —
 * no new foreground service. A scan therefore lives and
 * dies with the app process; it never dies SILENTLY: the
 * exit waiter flips the stage to error, the state file
 * survives, and the page offers Resume. The pid-file
 * orphan contract keeps a killed app's scanner from
 * leaking into the next launch.
 */
object SenpaiCore {
    const val LIB_NAME = "libsenpai_lml.so"

    /** The child's CWD under filesDir — its parentage is
     *  load-bearing: the binary writes its resumable state
     *  to ../senpai-resume/scan-state.json. */
    const val DIR_NAME = "senpai-work"

    /** Rows kept in memory (LML's MAX_ROWS). */
    private const val MAX_ROWS = 20000

    /** Rows returned per state call (the page imports the
     *  top of the list; the full set stays in the state
     *  file / export on the Dart side's request). */
    private const val STATE_ROW_CAP = 300

    @Volatile
    var running: Boolean = false
        private set

    /** idle | starting | running | done | error */
    @Volatile
    var stage: String = "idle"
        private set

    @Volatile
    var lastError: String = ""
        private set

    @Volatile
    private var tested = 0

    @Volatile
    private var total = 0

    @Volatile
    private var healthy = 0

    @Volatile
    private var phase = 0

    @Volatile
    private var cancelled = false

    private var process: Process? = null
    private var commands: BufferedWriter? = null

    @Volatile
    private var appContext: Context? = null

    /** ip|port -> row JSON (insertion-ordered). */
    private val rows = LinkedHashMap<String, JSONObject>()

    private val stderrTail = mutableListOf<String>()

    fun binary(context: Context): File =
        File(context.applicationInfo.nativeLibraryDir, LIB_NAME)

    fun workDir(context: Context): File =
        File(context.filesDir, DIR_NAME).apply { mkdirs() }

    fun stateFile(context: Context): File =
        File(context.filesDir, "senpai-resume/scan-state.json")

    private fun stdoutLog(context: Context): File =
        File(workDir(context), "senpai-stdout.log")

    private fun stderrLog(context: Context): File =
        File(workDir(context), "senpai-stderr.log")

    private fun pidFile(context: Context): File =
        File(workDir(context), "core.pid")

    /** SubprocessCore's orphan contract, same shape: kill
     *  a recorded pid only when its cmdline still names
     *  this binary. */
    internal fun reapOrphan(context: Context) {
        val file = pidFile(context)
        try {
            val pid = file.readText().trim().toIntOrNull() ?: return
            val cmdline = File("/proc/$pid/cmdline")
            if (cmdline.exists() && cmdline.readText().contains(LIB_NAME)) {
                android.os.Process.killProcess(pid)
            }
        } catch (_: Exception) {
            // No orphan, or it is already gone.
        } finally {
            file.delete()
        }
    }

    /**
     * Starts a scan: [requestJson] is the full request line
     * built by the Dart side (senpai.dart). Returns true
     * when the process spawned and the request was written;
     * progress and results then stream into [state].
     */
    @Synchronized
    fun start(context: Context, requestJson: String): Boolean {
        appContext = context.applicationContext
        stopLocked(killNow = true)
        reapOrphan(context)
        val bin = binary(context)
        if (!bin.exists()) {
            stage = "error"
            lastError = "the Senpai scanner is missing"
            return false
        }
        val request = try {
            JSONObject(requestJson)
        } catch (e: Exception) {
            stage = "error"
            lastError = "the scan request is not valid JSON"
            return false
        }
        val action = request.optString("action")
        if (action !in listOf("scan", "resume", "speed")) {
            stage = "error"
            lastError = "the scan request has no valid action"
            return false
        }
        if (action == "scan") {
            synchronized(rows) { rows.clear() }
            tested = 0
            total = 0
            healthy = 0
        }
        cancelled = false
        phase = 0
        lastError = ""
        val dir = workDir(context)
        synchronized(stderrTail) { stderrTail.clear() }
        try {
            val pb = ProcessBuilder(listOf(bin.absolutePath))
            pb.directory(dir)
            pb.redirectErrorStream(false)
            // LML sets HOME to filesDir; the binary's state
            // path is CWD-relative, but HOME is kept faithful
            // to the proven host.
            pb.environment()["HOME"] = context.filesDir.absolutePath
            val p = pb.start()
            process = p
            running = true
            stage = "starting"
            try {
                val pid = p.javaClass.getMethod("pid").invoke(p) as? Long
                if (pid != null) AtomicFile.writeText(pidFile(context), pid.toString())
            } catch (_: Throwable) {
                // Best-effort bookkeeping only.
            }
            val writer = BufferedWriter(
                OutputStreamWriter(p.outputStream, Charsets.UTF_8),
            )
            commands = writer
            writer.write(requestJson)
            writer.write("\n")
            writer.flush()
            drainEvents(p, context)
            drainStderr(p, context)
            watchExit(p, context)
            return true
        } catch (e: Exception) {
            running = false
            stage = "error"
            lastError = "the Senpai scanner could not start: ${e.message}"
            return false
        }
    }

    /** Asks the scanner to stop and save its state; a
     *  watchdog escalates to a kill after 20 s (LML's
     *  stop discipline). */
    @Synchronized
    fun stop() {
        val p = process ?: return
        try {
            commands?.let {
                it.write("{\"stop\":true}\n")
                it.flush()
            }
        } catch (_: Exception) {
            // The pipe is gone; the watchdog below still fires.
        }
        val gen = p
        thread(isDaemon = true, name = "senpai-stop-watchdog") {
            try {
                Thread.sleep(20_000)
            } catch (_: InterruptedException) {
                return@thread
            }
            synchronized(this@SenpaiCore) {
                if (process === gen && gen.isAlive) {
                    ProcessKill.kill(gen)
                }
            }
        }
    }

    @Synchronized
    private fun stopLocked(killNow: Boolean) {
        val p = process
        process = null
        commands = null
        running = false
        if (stage == "starting" || stage == "running") stage = "idle"
        if (killNow && p != null && p.isAlive) {
            ProcessKill.kill(p)
        }
        appContext?.let {
            try {
                pidFile(it).delete()
            } catch (_: Exception) {
            }
        }
    }

    private fun drainEvents(p: Process, context: Context) {
        thread(isDaemon = true, name = "senpai-stdout") {
            val logFile = stdoutLog(context)
            try {
                if (logFile.length() > 512 * 1024) logFile.delete()
            } catch (_: Exception) {
            }
            try {
                val reader = BufferedReader(
                    InputStreamReader(p.inputStream, Charsets.UTF_8),
                )
                FileOutputStream(logFile, true).bufferedWriter().use { out ->
                    while (true) {
                        val line = reader.readLine() ?: break
                        try {
                            out.write(line)
                            out.newLine()
                            out.flush()
                        } catch (_: Exception) {
                            // The log must never kill the drain.
                        }
                        // LML drops oversize events outright.
                        if (line.length > 150_000) continue
                        try {
                            onEvent(JSONObject(line))
                        } catch (_: Exception) {
                            // A non-JSON line is log noise, not
                            // a protocol failure.
                        }
                    }
                }
            } catch (_: Exception) {
                // Stream closed with the process.
            }
        }
    }

    private fun drainStderr(p: Process, context: Context) {
        thread(isDaemon = true, name = "senpai-stderr") {
            val logFile = stderrLog(context)
            try {
                val reader = BufferedReader(
                    InputStreamReader(p.errorStream, Charsets.UTF_8),
                )
                FileOutputStream(logFile, true).bufferedWriter().use { out ->
                    while (true) {
                        val line = reader.readLine() ?: break
                        synchronized(stderrTail) {
                            stderrTail.add(line)
                            while (stderrTail.size > 20) stderrTail.removeAt(0)
                        }
                        try {
                            out.write(line)
                            out.newLine()
                            out.flush()
                        } catch (_: Exception) {
                        }
                    }
                }
            } catch (_: Exception) {
                // Stream closed with the process.
            }
        }
    }

    private fun watchExit(p: Process, context: Context) {
        thread(isDaemon = true, name = "senpai-waiter") {
            val code = runCatching { p.waitFor() }.getOrDefault(-1)
            synchronized(this@SenpaiCore) {
                if (process !== p) return@thread // A newer spawn owns the state.
                process = null
                commands = null
                running = false
                try {
                    pidFile(context).delete()
                } catch (_: Exception) {
                }
                if (stage != "done" && stage != "idle") {
                    // Exited without a done event: an
                    // interruption, never a silent one — the
                    // stage says so and the state file (when
                    // the scanner managed to save one) makes
                    // the run resumable.
                    stage = "error"
                    val tail = synchronized(stderrTail) {
                        stderrTail.lastOrNull() ?: ""
                    }
                    lastError =
                        "the Senpai scanner exited (code $code)" +
                            if (tail.isNotEmpty()) ": $tail" else ""
                }
            }
        }
    }

    private fun onEvent(event: JSONObject) {
        when (event.optString("type")) {
            "phase" -> {
                phase = event.optInt("phase")
                if (stage == "starting") stage = "running"
            }
            "stats" -> {
                tested = maxOf(0, event.optInt("tested"))
                total = maxOf(0, event.optInt("total"))
                healthy = maxOf(0, event.optInt("healthy"))
                if (stage == "starting") stage = "running"
            }
            "results" -> {
                val arr = event.optJSONArray("rows") ?: return
                synchronized(rows) {
                    for (i in 0 until arr.length()) {
                        val row = arr.optJSONObject(i) ?: continue
                        val ip = row.optString("ip")
                        val port = row.optInt("port")
                        if (!safeIp(ip) || port !in 1..65535) continue
                        val key = "$ip|$port"
                        if (!rows.containsKey(key) && rows.size >= MAX_ROWS) {
                            continue
                        }
                        rows[key] = row
                    }
                }
                if (stage == "starting") stage = "running"
            }
            "direct-speed" -> {
                val ip = event.optString("ip")
                val port = event.optInt("port")
                if (safeIp(ip) && port in 1..65535) {
                    synchronized(rows) {
                        val key = "$ip|$port"
                        val row = rows[key] ?: JSONObject().apply {
                            put("ip", ip)
                            put("port", port)
                            put("latency", event.optLong("latency"))
                            put("loss", 0.0)
                            put("colo", "")
                            if (rows.size < MAX_ROWS) rows[key] = this
                        }
                        row.put("speedTested", true)
                        row.put("speedOK", event.optBoolean("success", false))
                        row.put(
                            "bytesPerSecond",
                            event.optDouble("bytesPerSecond", 0.0),
                        )
                        if (row.optLong("latency") <= 0) {
                            row.put("latency", event.optLong("latency"))
                        }
                    }
                }
                tested = maxOf(tested, maxOf(0, event.optInt("done")))
                total = maxOf(total, maxOf(0, event.optInt("total")))
            }
            "error" -> {
                stage = "error"
                lastError = when (event.optString("code")) {
                    "resume" -> "the saved scan state is not valid for resume"
                    "targets" -> "no valid public targets, or the list is too large"
                    else -> "the Senpai scanner reported an error"
                }
            }
            "done" -> {
                cancelled = event.optBoolean("cancelled")
                stage = if (event.optBoolean("failed")) "error" else "done"
                if (stage == "error" && lastError.isEmpty()) {
                    lastError = "the Senpai scanner reported a failed run"
                }
            }
        }
    }

    private fun safeIp(ip: String): Boolean =
        ip.length <= 45 && ip.matches(Regex("[0-9A-Fa-f:.]+"))

    /** The state snapshot the Dart page polls. Rows are
     *  sorted the way the page presents them — measured
     *  speed first (fastest first), then latency — and
     *  capped; [rowsTotal] carries the full count. */
    fun state(context: Context): Map<String, Any> {
        val snapshot = synchronized(rows) { rows.values.map { JSONObject(it.toString()) } }
        val sorted = snapshot.sortedWith { a, b ->
            val aSpeed = if (a.optBoolean("speedOK")) a.optDouble("bytesPerSecond") else -1.0
            val bSpeed = if (b.optBoolean("speedOK")) b.optDouble("bytesPerSecond") else -1.0
            if (aSpeed != bSpeed) bSpeed.compareTo(aSpeed)
            else a.optLong("latency", Long.MAX_VALUE)
                .compareTo(b.optLong("latency", Long.MAX_VALUE))
        }
        val outRows = JSONArray()
        for (row in sorted.take(STATE_ROW_CAP)) outRows.put(row)
        return mapOf(
            "available" to binary(context).exists(),
            "running" to running,
            "stage" to stage,
            "error" to lastError,
            "phase" to phase,
            "tested" to tested,
            "total" to total,
            "healthy" to healthy,
            "cancelled" to cancelled,
            "resumable" to stateFile(context).isFile,
            "workDir" to workDir(context).absolutePath,
            "rowsTotal" to snapshot.size,
            "rows" to outRows.toString(),
            "logTail" to synchronized(stderrTail) { stderrTail.joinToString("\n") },
        )
    }
}
