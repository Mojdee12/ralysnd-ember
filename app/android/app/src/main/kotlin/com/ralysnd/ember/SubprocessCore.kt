package com.ralysnd.ember

import android.content.Context
import java.io.BufferedReader
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.InputStreamReader
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.concurrent.thread

/**
 * The shared lifecycle for a tunnel helper that ships as a
 * standalone executable staged in jniLibs (build 2072: the
 * DNSTT client and wstunnel). Modelled on EmberWarpCore's
 * spawn contract, with the stream discipline the Lantern core
 * established:
 *
 * - The binary runs from the native library directory; the
 *   child PID is written to a pid file at spawn and a recorded
 *   orphan is reaped deterministically at the next start (no
 *   /proc scan — hidepid makes that unreliable on Android 10+).
 * - stdout and stderr are drained by SEPARATE threads into
 *   SEPARATE files and are never merged: a helper's readiness
 *   and failure words live on a specific stream (dnstt logs
 *   everything to stderr; wstunnel logs to stderr too), and a
 *   merged log once hid exactly that distinction. Both files
 *   flush per line — these helpers are quiet, and the start
 *   phase is exactly when the evidence matters (the buffered
 *   writer lesson of build 2068).
 * - A waiter thread owns unexpected exit: stage becomes
 *   "error" and lastError names the exit code and the last
 *   stderr line, so a start failure surfaces as a plain error
 *   plus a log line, never as a silent dead port.
 * - Readiness is per-helper ([tcpProbe]): a TCP listener is
 *   probed by connecting to it; a UDP forwarder has no
 *   handshake to probe, so readiness is a liveness window —
 *   the process must survive its own argument parsing and
 *   listener bind, which is where wstunnel fails fast.
 *
 * Stop funnels through ProcessKill (the one kill contract).
 */
abstract class SubprocessCore(
    /** The staged executable's file name in jniLibs. */
    val libName: String,
    /** The per-helper directory under filesDir (logs + pid). */
    val dirName: String,
    /** The fixed loopback port the helper listens on. */
    val port: Int,
    /** True: readiness = the TCP listener accepts. False:
     *  readiness = the process survives the startup window. */
    val tcpProbe: Boolean,
    /** Short human name for errors ("DNSTT client"). */
    val label: String,
) {
    @Volatile
    var running: Boolean = false
        protected set

    @Volatile
    var ready: Boolean = false
        protected set

    /** idle | starting | ready | error */
    @Volatile
    var stage: String = "idle"
        protected set

    @Volatile
    var lastError: String = ""
        protected set

    private var process: Process? = null
    private var readyThread: Thread? = null

    @Volatile
    private var appContext: Context? = null

    private val stderrTail = mutableListOf<String>()

    fun binary(context: Context): File =
        File(context.applicationInfo.nativeLibraryDir, libName)

    fun workDir(context: Context): File =
        File(context.filesDir, dirName).apply { mkdirs() }

    private fun stdoutLog(context: Context): File =
        File(workDir(context), "$dirName-stdout.log")

    private fun stderrLog(context: Context): File =
        File(workDir(context), "$dirName-stderr.log")

    private fun pidFile(context: Context): File =
        File(workDir(context), "core.pid")

    protected fun lastStderrLine(): String =
        synchronized(stderrTail) { stderrTail.lastOrNull() ?: "" }

    private fun appendTail(line: String) {
        synchronized(stderrTail) {
            stderrTail.add(line)
            while (stderrTail.size > 20) stderrTail.removeAt(0)
        }
    }

    /** Kills a recorded orphan from a previous process life. */
    private fun reapOrphan(context: Context) {
        val file = pidFile(context)
        try {
            val pid = file.readText().trim().toIntOrNull() ?: return
            val cmdline = File("/proc/$pid/cmdline")
            if (cmdline.exists() && cmdline.readText().contains(libName)) {
                android.os.Process.killProcess(pid)
            }
        } catch (_: Exception) {
            // No orphan, or it is already gone.
        } finally {
            file.delete()
        }
    }

    /**
     * Spawns the helper with [args] (built on the Dart side).
     * Returns true when the process started; readiness
     * completes asynchronously — poll [state].
     */
    @Synchronized
    fun start(context: Context, args: List<String>): Boolean {
        appContext = context.applicationContext
        stop()
        reapOrphan(context)
        val bin = binary(context)
        if (!bin.exists()) {
            stage = "error"
            lastError = "the $label is missing"
            return false
        }
        val dir = workDir(context)
        synchronized(stderrTail) { stderrTail.clear() }
        try {
            val pb = ProcessBuilder(listOf(bin.absolutePath) + args)
            pb.directory(dir)
            // The streams stay separate end to end (class doc).
            pb.redirectErrorStream(false)
            pb.redirectInput(File("/dev/null"))
            val env = pb.environment()
            env["HOME"] = dir.absolutePath
            env["TMPDIR"] = context.cacheDir.absolutePath
            val p = pb.start()
            process = p
            running = true
            ready = false
            stage = "starting"
            lastError = ""
            try {
                val pid = p.javaClass.getMethod("pid").invoke(p) as? Long
                if (pid != null) pidFile(context).writeText(pid.toString())
            } catch (_: Throwable) {
                // Best-effort bookkeeping only.
            }
            drain(p.inputStream, stdoutLog(context), isStderr = false)
            drain(p.errorStream, stderrLog(context), isStderr = true)
            watchExit(p)
            watchReadiness(p)
            return true
        } catch (e: Exception) {
            running = false
            stage = "error"
            lastError = "the $label could not start: ${e.message}"
            return false
        }
    }

    private fun drain(stream: InputStream, logFile: File, isStderr: Boolean) {
        thread(isDaemon = true, name = "$dirName-${if (isStderr) "stderr" else "stdout"}") {
            try {
                if (logFile.length() > 512 * 1024) logFile.delete()
            } catch (_: Exception) {
            }
            val reader = BufferedReader(InputStreamReader(stream, Charsets.UTF_8))
            try {
                val out = FileOutputStream(logFile, true).bufferedWriter()
                try {
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (isStderr) appendTail(line)
                        try {
                            out.write(line)
                            out.newLine()
                            // Per line (class doc): these
                            // helpers are quiet, and start-phase
                            // evidence must reach disk.
                            out.flush()
                        } catch (_: Exception) {
                            // The log must never kill the drain.
                        }
                    }
                } finally {
                    try {
                        out.close()
                    } catch (_: Exception) {
                    }
                }
            } catch (_: Exception) {
                // Stream closed with the process; nothing to do.
            }
        }
    }

    private fun watchExit(p: Process) {
        thread(isDaemon = true, name = "$dirName-waiter") {
            val code = runCatching { p.waitFor() }.getOrDefault(-1)
            synchronized(this@SubprocessCore) {
                if (process !== p) return@thread // A newer spawn owns the state.
                process = null
                running = false
                ready = false
                if (stage != "idle") {
                    stage = "error"
                    val tail = lastStderrLine()
                    lastError =
                        "the $label exited (code $code)" +
                            if (tail.isNotEmpty()) ": $tail" else ""
                }
            }
        }
    }

    private fun watchReadiness(p: Process) {
        readyThread = thread(isDaemon = true, name = "$dirName-ready") {
            if (tcpProbe) {
                val deadline = System.currentTimeMillis() + 20_000
                while (System.currentTimeMillis() < deadline) {
                    if (!p.isAlive) return@thread // watchExit owns the error.
                    try {
                        Socket().use { s ->
                            s.connect(InetSocketAddress("127.0.0.1", port), 400)
                        }
                        markReady(p)
                        return@thread
                    } catch (_: Exception) {
                        try {
                            Thread.sleep(250)
                        } catch (_: InterruptedException) {
                            return@thread
                        }
                    }
                }
                synchronized(this@SubprocessCore) {
                    if (process === p && !ready) {
                        stage = "error"
                        lastError =
                            "the $label did not open its listener in time"
                    }
                }
            } else {
                // UDP forwarder: no handshake exists to probe.
                // Surviving the startup window means the args
                // parsed and the listener bound — wstunnel dies
                // instantly on either failure.
                try {
                    Thread.sleep(900)
                } catch (_: InterruptedException) {
                    return@thread
                }
                if (p.isAlive) markReady(p)
            }
        }
    }

    private fun markReady(p: Process) {
        synchronized(this@SubprocessCore) {
            if (process === p && running) {
                ready = true
                stage = "ready"
            }
        }
    }

    @Synchronized
    fun stop() {
        val p = process
        process = null
        running = false
        ready = false
        if (stage == "starting" || stage == "ready") stage = "idle"
        readyThread?.interrupt()
        if (p != null && p.isAlive) {
            ProcessKill.kill(p)
        }
        appContext?.let {
            try {
                pidFile(it).delete()
            } catch (_: Exception) {
            }
        }
    }

    /** Stop + start with the same arguments (the supervisor's
     *  revival path). */
    @Synchronized
    fun restart(context: Context, args: List<String>): Boolean {
        stop()
        return start(context, args)
    }

    fun state(context: Context): Map<String, Any> = mapOf(
        "available" to binary(context).exists(),
        "running" to running,
        "ready" to ready,
        "stage" to stage,
        "error" to lastError,
        "port" to port,
        "logTail" to synchronized(stderrTail) { stderrTail.joinToString("\n") },
    )
}
