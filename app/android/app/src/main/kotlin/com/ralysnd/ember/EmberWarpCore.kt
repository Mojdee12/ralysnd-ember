package com.ralysnd.ember

import android.content.Context
import java.io.File
import java.io.RandomAccessFile
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.concurrent.thread

/**
 * The EmberWarp core (build 2030): a Cloudflare WARP client
 * engine run as a subprocess, after the patterniha/Aether
 * design (AGPL-3.0; the full license text and the source link
 * ship in Settings → Info / Open Source Licenses). The binary
 * is staged in jniLibs as libemberwarp.so and run from the
 * native library directory, like the Lantern core.
 *
 * Spawn contract (from the RE dossier, §2/§7):
 * - Identity lives in noBackupFilesDir/emberwarp and is
 *   pointed at with ABSOLUTE env paths (AETHER_CONFIG,
 *   AETHER_MASQUE_CONFIG, AETHER_WG_CONFIG); CWD and HOME are
 *   the identity dir, TMPDIR the cache dir, SSL_CERT_DIR the
 *   platform CA stores (the core verifies TLS itself).
 * - The command line ALWAYS carries protocol+scan+ip (the
 *   core prompts interactively on stdin when a value is
 *   missing — stdin is /dev/null here, so a missing value
 *   would hang or fail, never prompt).
 * - AETHER_REPROVISION=0 on every normal run: when Cloudflare
 *   refuses a saved identity the core must NOT silently
 *   re-register (dossier risk: a silent renewal burns the
 *   account's registration budget and hides the refusal). The
 *   only renewal path is the explicit Renew action below.
 * - Readiness is a SINGLE-socket SOCKS greeting wait (up to
 *   45 s direct; a chained run, whose scan must validate
 *   through the session's exit-node, gets 150 s — build
 *   2080): the listener binds early but only answers once a
 *   gateway has passed a real data-plane check, and a 500 ms
 *   poll loop would queue dead greetings ahead of the real
 *   connection. A sibling thread watches the process and
 *   closes the socket if the core dies mid-wait. Build 2087
 *   (analysis A1): the greeting CONNECT is retried until the
 *   deadline while the process lives — a loopback connect to
 *   a not-yet-bound port is refused instantly, and the old
 *   one-shot attempt latched "error" in milliseconds on the
 *   chain path's registration run, whose bind follows the
 *   Cloudflare registration round-trips. A refused connect
 *   sends nothing, so the single-greeting rule is kept:
 *   exactly one greeting is ever written, on the one connect
 *   that succeeds.
 * - The child PID is written to a pid file at spawn; the next
 *   start kills a recorded orphan deterministically (no /proc
 *   scan — hidepid makes that unreliable on Android 10+).
 */
object EmberWarpCore {
    /** The session SOCKS listen port (dossier Q6 range). */
    const val SOCKS_PORT = 20850

    /** The chain mode's inline exit listener (Xray side). */
    const val EXIT_PORT = 20851

    /** Probe / renewal runs listen here, never on the session port. */
    const val PROBE_PORT = 20853

    /** The exit port paired with a probe run. */
    const val PROBE_EXIT_PORT = 20854

    /** The greeting wait for a direct run: the core's own
     *  readiness contract (the listener answers only after a
     *  gateway carried a real check). */
    const val GREETING_WAIT_MS = 45_000L

    /** The greeting wait for a CHAINED run (build 2080): the
     *  scan's every check must additionally ride the Xray
     *  session's exit-node — a full proxied hop with its own
     *  handshake on a filtered line — before it can pass, so
     *  a cold chained scan gets three direct budgets. The
     *  VPN service's initial chain grace is sized to match
     *  (XrayVpnService.WARP_CHAIN_INITIAL_GRACE_MS). */
    const val CHAIN_GREETING_WAIT_MS = 150_000L

    /** The core's own words for "this identity is refused":
     *  the tunnel handshakes but carries nothing until the
     *  identity is replaced. Detection of this line is the
     *  ONLY thing that raises the Renew prompt (dossier Q1). */
    const val REFUSAL_LINE =
        "the tunnel will handshake but carry no traffic"

    @Volatile
    var running: Boolean = false
        private set

    /** The data-plane gate passed: the SOCKS greeting was
     *  answered, which the core only does after a gateway
     *  carried a real check. */
    @Volatile
    var ready: Boolean = false
        private set

    /** idle | starting | ready | error | refused */
    @Volatile
    var stage: String = "idle"
        private set

    @Volatile
    var lastError: String = ""
        private set

    /** The refusal line was seen in the core log: the saved
     *  identity is dead and only an explicit Renew fixes it. */
    @Volatile
    var renewNeeded: Boolean = false
        private set

    /** When the current spawn started (build 2080). */
    @Volatile
    var startedAtMs: Long = 0
        private set

    /** The current spawn is a chain run (its argv carries
     *  --upstream: the whole egress rides the Xray session it
     *  serves). Chained cold scans validate through the
     *  exit-node — an extra proxied hop — so the greeting
     *  wait is sized for them (build 2080). */
    @Volatile
    var chainedRun: Boolean = false
        private set

    /**
     * Build 2080: the core is in its FIRST scan — spawned,
     * alive, still in the starting stage, its readiness wait
     * still running. The ChainSupervisor exempts this state:
     * respawning a core mid-scan kills the scan and restarts
     * the very clock the supervisor is measuring (the dead-
     * chain churn of the 2026-11-15 diagnosis). The state is
     * bounded by the greeting wait itself: when that wait
     * concludes, the stage leaves "starting" and supervision
     * applies in full again.
     */
    fun scanInProgress(): Boolean =
        running && !ready && stage == "starting" &&
            (process?.isAlive ?: false)

    private var process: Process? = null
    private var readyThread: Thread? = null
    private var logThread: Thread? = null
    @Volatile
    private var logOffset: Long = 0

    /** The last context a spawn ran with (application context):
     *  lets stop() clear the pid file without a caller context. */
    @Volatile
    private var appContext: Context? = null

    fun binary(context: Context): File =
        File(context.applicationInfo.nativeLibraryDir, "libemberwarp.so")

    fun identityDir(context: Context): File =
        File(context.noBackupFilesDir, "emberwarp").apply { mkdirs() }

    private fun stagingDir(context: Context): File =
        File(context.noBackupFilesDir, "emberwarp-renewal").apply { mkdirs() }

    private fun workDir(context: Context): File =
        File(context.noBackupFilesDir, "emberwarp-work").apply { mkdirs() }

    private fun logFile(context: Context): File =
        File(workDir(context), "warp.log")

    private fun pidFile(context: Context): File =
        File(workDir(context), "core.pid")

    fun identityPresent(context: Context): Boolean =
        identityDir(context).listFiles()?.any { it.isFile && it.length() > 0 }
            ?: false

    /**
     * Finishes an interrupted renewal (dossier Q9): staged
     * identity files with a `ready` marker move over the live
     * ones. Called before every spawn; a no-op unless a
     * renewal completed and was never settled.
     */
    @Synchronized
    fun settle(context: Context) {
        val staging = stagingDir(context)
        val marker = File(staging, "ready")
        if (!marker.exists()) return
        val live = identityDir(context)
        staging.listFiles()?.forEach { f ->
            if (f.isFile && f.name != "ready") {
                val target = File(live, f.name)
                try {
                    if (!f.renameTo(target)) {
                        f.copyTo(target, overwrite = true)
                        f.delete()
                    }
                } catch (_: Exception) {
                    // A file that will not move stays staged;
                    // the next start retries.
                }
            }
        }
        marker.delete()
        renewNeeded = false
        appendLog(context, "emberwarp: renewed identity settled")
    }

    /** Kills a recorded orphan from a previous process life.
     *  Internal (build 2125, audit A25-18): EmberApplication
     *  also calls it at process birth. */
    internal fun reapOrphan(context: Context) {
        val file = pidFile(context)
        try {
            val pid = file.readText().trim().toIntOrNull() ?: return
            val cmdline = File("/proc/$pid/cmdline")
            if (cmdline.exists() &&
                cmdline.readText().contains("libemberwarp.so")
            ) {
                android.os.Process.killProcess(pid)
                appendLog(context, "emberwarp: reaped orphan core pid $pid")
            }
        } catch (_: Exception) {
            // No orphan, or it is already gone.
        } finally {
            file.delete()
        }
    }

    private fun appendLog(context: Context, line: String) {
        try {
            logFile(context).appendText("$line\n")
        } catch (_: Exception) {
        }
    }

    /**
     * Spawns the core with [args] (built on the Dart side from
     * the warp profile; always protocol+scan+ip). Returns true
     * when the process started; readiness completes
     * asynchronously — poll [state]. [greetingWaitMs] overrides
     * the readiness budget (build 2087): the chain path's
     * direct identity-registration run on the probe port passes
     * the chain grace (150 s), because registration round-trips
     * precede its first scan; null keeps the run's own budget
     * (45 s direct / 150 s chained).
     */
    @Synchronized
    fun start(
        context: Context,
        args: List<String>,
        port: Int,
        greetingWaitMs: Long? = null,
    ): Boolean {
        appContext = context.applicationContext
        stop()
        settle(context)
        reapOrphan(context)
        val bin = binary(context)
        if (!bin.exists()) {
            stage = "error"
            lastError = "the EmberWarp core is missing"
            return false
        }
        val idDir = identityDir(context)
        val log = logFile(context)
        if (log.exists() && log.length() > 512 * 1024) log.delete()
        logOffset = if (log.exists()) log.length() else 0
        try {
            val pb = ProcessBuilder(listOf(bin.absolutePath) + args)
            pb.directory(idDir)
            pb.redirectErrorStream(true)
            pb.redirectInput(File("/dev/null"))
            pb.redirectOutput(ProcessBuilder.Redirect.appendTo(log))
            val env = pb.environment()
            env["AETHER_CONFIG"] = File(idDir, "aether.toml").absolutePath
            env["AETHER_MASQUE_CONFIG"] =
                File(idDir, "masque.toml").absolutePath
            env["AETHER_WG_CONFIG"] = File(idDir, "wg.toml").absolutePath
            env["AETHER_REPROVISION"] = "0"
            env["HOME"] = idDir.absolutePath
            env["TMPDIR"] = context.cacheDir.absolutePath
            env["SSL_CERT_DIR"] =
                "/apex/com.android.conscrypt/cacerts:" +
                    "/system/etc/security/cacerts"
            val p = pb.start()
            process = p
            running = true
            ready = false
            stage = "starting"
            lastError = ""
            startedAtMs = System.currentTimeMillis()
            chainedRun = args.contains("--upstream")
            try {
                // Process.pid() is a Java 9 surface the Android
                // stubs do not expose to Kotlin; reach it
                // reflectively (the runtime implements it).
                val pid = p.javaClass.getMethod("pid").invoke(p) as? Long
                if (pid != null) AtomicFile.writeText(pidFile(context), pid.toString())
            } catch (_: Throwable) {
                // Best-effort bookkeeping only.
            }
            watchReadiness(
                context, p, port,
                greetingWaitMs
                    ?: if (chainedRun) CHAIN_GREETING_WAIT_MS
                    else GREETING_WAIT_MS,
            )
            watchLog(context, p)
            return true
        } catch (e: Exception) {
            running = false
            stage = "error"
            lastError = "the EmberWarp core could not start: ${e.message}"
            return false
        }
    }

    /** The single-socket greeting wait + liveness sibling.
     *  [greetingWaitMs] is the core's own readiness contract:
     *  45 s for a direct run; a chained run's scan must also
     *  traverse the session's exit-node before any gateway
     *  check can pass, so it gets the chain budget (build
     *  2080). Build 2087 (analysis A1): the connect phase
     *  retries until the deadline while the process lives —
     *  "error" latches only on process death or deadline
     *  expiry, never on the first refusal. */
    private fun watchReadiness(
        context: Context,
        p: Process,
        port: Int,
        greetingWaitMs: Long,
    ) {
        readyThread = thread(isDaemon = true, name = "emberwarp-ready") {
            val deadline = System.currentTimeMillis() + greetingWaitMs
            var socket: Socket? = null
            // The liveness sibling: a dead core closes the
            // socket so the greeting read cannot hang past it.
            val watcher = thread(isDaemon = true, name = "emberwarp-live") {
                while (p.isAlive) {
                    try {
                        Thread.sleep(250)
                    } catch (_: InterruptedException) {
                        return@thread
                    }
                }
                try {
                    socket?.close()
                } catch (_: Exception) {
                }
            }
            try {
                // Build 2087 (analysis A1): the greeting connect
                // is retried until the deadline while the process
                // lives. A loopback connect to a port with no
                // listener yet is refused instantly (RST) — the
                // 10 s connect timeout governs a silent peer, not
                // a refusal — so the old single attempt latched
                // "error" within milliseconds whenever the core
                // was still provisioning or binding, above all
                // the chain path's direct registration run, whose
                // bind follows the Cloudflare round-trips. A
                // refused connect sends no greeting, so retrying
                // it cannot queue dead greetings ahead of the
                // real connection: the single greeting below is
                // still the only one ever written.
                var greeted: Socket? = null
                while (greeted == null) {
                    if (!p.isAlive) break
                    if (System.currentTimeMillis() >= deadline) break
                    val candidate = Socket()
                    socket = candidate
                    try {
                        candidate.connect(
                            InetSocketAddress("127.0.0.1", port),
                            10_000,
                        )
                        greeted = candidate
                    } catch (e: Exception) {
                        try {
                            candidate.close()
                        } catch (_: Exception) {
                        }
                        if (socket === candidate) socket = null
                        if (!p.isAlive) break
                        try {
                            Thread.sleep(250)
                        } catch (_: InterruptedException) {
                            break
                        }
                    }
                }
                val s = greeted
                if (s == null) {
                    // The budget ran out with no listener, or the
                    // core died trying: the terminal word matches
                    // the read path's — a live core that never
                    // answered is a timeout; a dead one stopped.
                    if (process === p && !ready) {
                        stage = if (renewNeeded) "refused" else "error"
                        if (lastError.isEmpty()) {
                            lastError = if (p.isAlive) {
                                "the EmberWarp core did not answer in time"
                            } else {
                                "the EmberWarp core stopped before it was ready"
                            }
                        }
                    }
                } else {
                    // SOCKS5 greeting: VER=5, one method, no-auth.
                    s.getOutputStream().write(byteArrayOf(5, 1, 0))
                    s.getOutputStream().flush()
                    while (System.currentTimeMillis() < deadline) {
                        // Build 2080: the read may block for the
                        // whole remaining wait — the liveness
                        // sibling closes this socket if the core
                        // dies, so a long read cannot hang past it.
                        // (The old 45 s cap would have timed the
                        // read out mid-scan on a chained run.)
                        val remaining =
                            (deadline - System.currentTimeMillis())
                                .coerceIn(1, greetingWaitMs)
                        s.soTimeout = remaining.toInt()
                        val reply = ByteArray(2)
                        var read = 0
                        while (read < 2) {
                            val n = s.getInputStream().read(reply, read, 2 - read)
                            if (n < 0) break
                            read += n
                        }
                        if (read == 2 && reply[0].toInt() == 5) {
                            ready = true
                            stage = "ready"
                            break
                        }
                        if (read < 2) break
                    }
                    if (!ready && process === p) {
                        stage = if (renewNeeded) "refused" else "error"
                        if (lastError.isEmpty()) {
                            lastError =
                                "the EmberWarp core did not answer in time"
                        }
                    }
                }
            } catch (e: Exception) {
                if (process === p && !ready) {
                    stage = if (renewNeeded) "refused" else "error"
                    if (lastError.isEmpty()) {
                        lastError =
                            "the EmberWarp core stopped before it was ready"
                    }
                }
            } finally {
                try {
                    socket?.close()
                } catch (_: Exception) {
                }
                watcher.interrupt()
            }
        }
    }

    /** Tails the core log for the refusal line (the Renew
     *  trigger) while this process lives. Build 2055 (audit
     *  B-M4): the tail reads only the NEW bytes via
     *  RandomAccessFile from the tracked offset — the old form
     *  re-read the whole log (up to 512 KB) every 500 ms to
     *  look for one line. The read starts one refusal-length
     *  back, so a line straddling a chunk boundary is still
     *  seen whole. */
    private fun watchLog(context: Context, p: Process) {
        logThread = thread(isDaemon = true, name = "emberwarp-log") {
            val file = logFile(context)
            while (p.isAlive) {
                try {
                    // Build 2095 (audit 6-2): warp.log is
                    // appended by the core process itself;
                    // cap it periodically from here (the
                    // append handle re-seeks to the end, and
                    // the watch offset restarts with the
                    // truncation).
                    if (file.exists() && file.length() > 1024 * 1024) {
                        file.writeText("")
                        logOffset = 0
                    }
                    if (file.exists() && file.length() > logOffset) {
                        RandomAccessFile(file, "r").use { raf ->
                            val start = (logOffset - REFUSAL_LINE.length)
                                .coerceAtLeast(0)
                            raf.seek(start)
                            val size = (file.length() - start).toInt()
                            val bytes = ByteArray(size)
                            var read = 0
                            while (read < size) {
                                val n = raf.read(bytes, read, size - read)
                                if (n < 0) break
                                read += n
                            }
                            if (String(bytes, 0, read, Charsets.UTF_8)
                                    .contains(REFUSAL_LINE)
                            ) {
                                renewNeeded = true
                                if (stage == "ready" || stage == "starting") {
                                    stage = "refused"
                                }
                                lastError =
                                    "Cloudflare refused the saved WARP " +
                                        "identity — renew the key to reconnect"
                            }
                        }
                        logOffset = file.length()
                    }
                    Thread.sleep(500)
                } catch (_: InterruptedException) {
                    return@thread
                } catch (_: Exception) {
                    try {
                        Thread.sleep(500)
                    } catch (_: InterruptedException) {
                        return@thread
                    }
                }
            }
        }
    }

    /**
     * Stops the core: destroy, a short grace, then forcibly.
     * Also clears the pid file so the next start's reaper has
     * nothing stale to chase.
     */
    @Synchronized
    fun stop() {
        val p = process
        process = null
        running = false
        ready = false
        startedAtMs = 0
        chainedRun = false
        if (stage == "starting" || stage == "ready") stage = "idle"
        readyThread?.interrupt()
        logThread?.interrupt()
        if (p != null && p.isAlive) {
            // Build 2054 (audit F-M1): the shared kill — the old
            // destroy + 400 ms + forcibly with NO post-forcible
            // wait could return while the core still held 20850,
            // racing the next start.
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
    fun restart(context: Context, args: List<String>, port: Int): Boolean {
        stop()
        return start(context, args, port)
    }

    /**
     * The ONLY identity renewal path (dossier Q1): registers a
     * FRESH identity into the staging directory, marks it
     * ready, and settles it over the live one. Blocking (up to
     * ~2 minutes) — call off the main thread. Normal connects
     * never do this (AETHER_REPROVISION=0).
     */
    @Synchronized
    fun renew(context: Context, registerKind: String): Boolean {
        stop()
        val bin = binary(context)
        if (!bin.exists()) return false
        val staging = stagingDir(context)
        staging.listFiles()?.forEach { it.delete() }
        val log = logFile(context)
        try {
            val pb = ProcessBuilder(
                listOf(bin.absolutePath, "--register", registerKind),
            )
            pb.directory(staging)
            pb.redirectErrorStream(true)
            pb.redirectInput(File("/dev/null"))
            pb.redirectOutput(ProcessBuilder.Redirect.appendTo(log))
            val env = pb.environment()
            env["AETHER_CONFIG"] =
                File(staging, "aether.toml").absolutePath
            env["AETHER_MASQUE_CONFIG"] =
                File(staging, "masque.toml").absolutePath
            env["AETHER_WG_CONFIG"] =
                File(staging, "wg.toml").absolutePath
            env["HOME"] = staging.absolutePath
            env["TMPDIR"] = context.cacheDir.absolutePath
            env["SSL_CERT_DIR"] =
                "/apex/com.android.conscrypt/cacerts:" +
                    "/system/etc/security/cacerts"
            val p = pb.start()
            val deadline = System.currentTimeMillis() + 120_000
            var done = false
            while (System.currentTimeMillis() < deadline) {
                if (!p.isAlive) {
                    done = true
                    break
                }
                // The core announces the finished set; once it
                // does, the registration is complete even if
                // the process lingers.
                try {
                    if (log.exists() &&
                        log.readText().contains("identities ready:")
                    ) {
                        done = true
                        p.destroy()
                        break
                    }
                } catch (_: Exception) {
                }
                Thread.sleep(500)
            }
            if (p.isAlive) {
                try {
                    p.destroyForcibly()
                } catch (_: Throwable) {
                }
            }
            val staged = staging.listFiles()
                ?.any { it.isFile && it.length() > 0 } ?: false
            if (done && staged) {
                File(staging, "ready").writeText("ready")
                settle(context)
                appendLog(context, "emberwarp: identity renewed")
                return true
            }
            appendLog(context, "emberwarp: renewal did not complete")
            return false
        } catch (e: Exception) {
            appendLog(context, "emberwarp: renewal failed: ${e.message}")
            return false
        }
    }

    /** Explicit identity wipe (Settings-level action): the
     *  next connect registers fresh because nothing is saved. */
    @Synchronized
    fun resetIdentity(context: Context) {
        stop()
        identityDir(context).listFiles()?.forEach { it.delete() }
        stagingDir(context).listFiles()?.forEach { it.delete() }
        renewNeeded = false
        stage = "idle"
        lastError = ""
        appendLog(context, "emberwarp: identity reset by the user")
    }

    fun logTail(context: Context, maxLines: Int = 40): String {
        return try {
            val f = logFile(context)
            if (!f.exists()) "" else f.readLines().takeLast(maxLines)
                .joinToString("\n")
        } catch (_: Exception) {
            ""
        }
    }

    fun state(context: Context): Map<String, Any> = mapOf(
        "available" to binary(context).exists(),
        "running" to running,
        "ready" to ready,
        "scanInProgress" to scanInProgress(),
        "stage" to stage,
        "identityPresent" to identityPresent(context),
        "renewNeeded" to renewNeeded,
        "error" to lastError,
        "logTail" to logTail(context),
    )
}
