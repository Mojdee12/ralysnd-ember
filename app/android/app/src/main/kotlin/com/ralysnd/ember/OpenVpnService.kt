package com.ralysnd.ember

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL
import java.security.SecureRandom
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * The OpenVPN engine host (build 2025).
 *
 * The OpenVPN 3 core wants its own TUN: it drives the
 * VpnService.Builder itself through the session callbacks
 * (configureTun / addAddress / addRoute / addDns /
 * addSearchDomain / establishTun, the bridge contract in
 * OpenVpnNative.kt) and protects its own transport sockets the
 * same way. So unlike Xray/Lantern there is no separate
 * tun2socks bridge — this service IS the core's platform.
 *
 * [OpenVpnCore] holds the session state the UI polls. Two
 * disciplines are inherited from the engines before it:
 *
 *  - LOUD failure: every failure lands in [OpenVpnCore.error]
 *    as a stage + reason, and the core's (scrubbed) log lines
 *    are kept in a ring buffer and an on-disk log the UI shows.
 *  - No fake "connected": the core's CONNECTED event only
 *    means the handshake finished. The phase becomes
 *    "connected" after a real request has crossed the tunnel
 *    and named the exit (the same proof the Lantern engine
 *    demands of its proxy); three failed tries end the session
 *    with NO_DATA instead.
 *
 * Ember's own package deliberately rides this tunnel (the
 * core's transport sockets are protected individually, so
 * nothing loops): the through-tunnel proof above is only
 * honest if the app's own request really crosses. The stored
 * per-app routing choice still applies to every other app.
 */
/**
 * The OpenVPN session breadcrumb trail (build 2026).
 *
 * The 2025 build died on the owner's phone at the Connect tap
 * with no log anyone could read — the process was gone, and
 * with it every in-memory buffer. So each connect now leaves a
 * stage trail in app storage (openvpn/breadcrumbs.log): the
 * service rotates the file at each connect and appends one
 * line per stage transition, and the native bridge appends
 * its own stages to the same file with raw write() calls that
 * survive even a native death. On the next launch the UI reads
 * the last session's final stage; a session whose trail stops
 * mid-flight is surfaced as "ended unexpectedly at stage X"
 * instead of vanishing.
 */
object OpenVpnTrace {
    fun file(context: Context): File =
        File(context.filesDir, "openvpn").apply { mkdirs() }
            .resolve("breadcrumbs.log")

    /** Starts a fresh trail for a new connect attempt. */
    @Synchronized
    fun begin(context: Context, profile: String) {
        try {
            file(context).delete()
        } catch (_: Exception) {
        }
        mark(context, "connect_tapped", profile)
    }

    @Synchronized
    fun mark(context: Context, stage: String, detail: String = "") {
        try {
            FileOutputStream(file(context), true).bufferedWriter().use {
                it.write("${System.currentTimeMillis()} $stage $detail")
                it.newLine()
            }
        } catch (_: Exception) {
            // The trail is evidence, never a reason to fail.
        }
    }

    /**
     * The last session's (final stage, ended-uncleanly). Only
     * stages after the last connect_tapped count — standalone
     * profile validations also leave markers and must not make
     * a finished session look dead.
     */
    fun lastSession(context: Context): Pair<String, Boolean> {
        val lines = try {
            file(context).readLines().filter { it.isNotBlank() }
        } catch (_: Exception) {
            return "" to false
        }
        fun stageOf(line: String): String =
            line.split(' ').getOrNull(1) ?: ""
        val start = lines.indexOfLast { stageOf(it) == "connect_tapped" }
        if (start < 0) return "" to false
        val session = lines.subList(start, lines.size)
        val ended = session.any {
            stageOf(it) == "session_end" || stageOf(it) == "clean_stop"
        }
        return stageOf(session.last()) to !ended
    }

    /**
     * The detail text of the last session's terminate /
     * run_exception crumb, or "" when the trail holds none
     * (build 2028 — the diagnostics card shows the exception
     * itself, per the owner's empty-log report: the trail
     * existed but he could not read it anywhere in the app).
     * The file mixes two line shapes — this writer's
     * "<millis> <stage> <detail>" and the native bridge's
     * "<stage> <detail> t=<millis>" — so the stage token is
     * accepted in either of the first two positions and the
     * trailing " t=…" stamp is stripped.
     */
    fun lastException(context: Context): String {
        val lines = try {
            file(context).readLines().filter { it.isNotBlank() }
        } catch (_: Exception) {
            return ""
        }
        fun tokens(line: String): List<String> = line.split(' ')
        val start = lines.indexOfLast {
            val t = tokens(it)
            t.getOrNull(0) == "connect_tapped" || t.getOrNull(1) == "connect_tapped"
        }
        val session = if (start < 0) lines else lines.subList(start, lines.size)
        var found = ""
        for (line in session) {
            val t = tokens(line)
            val stageAt = when {
                t.getOrNull(0) == "terminate" || t.getOrNull(0) == "run_exception" -> 0
                t.getOrNull(1) == "terminate" || t.getOrNull(1) == "run_exception" -> 1
                else -> -1
            }
            if (stageAt >= 0) {
                found = t.drop(stageAt + 1).joinToString(" ")
                    .replace(Regex("""\s*t=\d+\s*$"""), "").trim()
            }
        }
        return found
    }
}

object OpenVpnCore {
    /** idle | connecting | verifying | connected | reconnecting | error */
    @Volatile var phase: String = "idle"

    /**
     * Build 2126 (audit A26-04): latched true the moment
     * a session verifies as connected; cleared when a new
     * session starts and when the session-end hold gate
     * has consumed it. The kill-switch hold reads THIS,
     * not the live [phase]: the core's DISCONNECTED event
     * resets phase to "idle" before the session-end tail
     * runs, so a phase-reading gate silently never fired
     * for remote-initiated disconnects — the common case.
     */
    @Volatile var wasConnected: Boolean = false
    @Volatile var profileId: String = ""
    @Volatile var profileName: String = ""
    @Volatile var error: String? = null
    @Volatile var exitIp: String = ""
    @Volatile var exitCountry: String = ""
    @Volatile var exitCode: String = ""

    /** Session counters, straight from the core (see the Session note). */
    @Volatile var upBytes: Long = 0
    @Volatile var downBytes: Long = 0

    private val logLock = Any()
    private val logRing = ArrayDeque<String>()

    /** The session's buffered log writer (build 2055, audit
     *  B-M4): held open, flushed on a 2 s timer or 8 KB —
     *  never open+write+close per line. The rotation cap is
     *  enforced on the byte counter, not a per-line stat call.
     *  The in-memory ring is the live view; the file is
     *  evidence, and 2 s of staleness on a crash is the
     *  accepted trade. */
    private var logWriter: java.io.BufferedWriter? = null
    private var logBytes = 0L
    private var logBytesSinceFlush = 0
    private var logLastFlushMs = 0L

    fun logTail(): List<String> = synchronized(logLock) { logRing.toList() }

    /** One line for the ring buffer and the on-disk engine log. */
    fun log(context: Context, line: String) {
        synchronized(logLock) {
            logRing.addLast(line)
            while (logRing.size > 60) logRing.removeFirst()
        }
        try {
            synchronized(logLock) {
                var w = logWriter
                if (w == null || logBytes > 512 * 1024) {
                    try { w?.flush() } catch (_: Exception) {}
                    try { w?.close() } catch (_: Exception) {}
                    val file = logFile(context)
                    if (logBytes > 512 * 1024) file.delete()
                    w = FileOutputStream(file, true).bufferedWriter()
                    logWriter = w
                    logBytes = file.length()
                    logBytesSinceFlush = 0
                    logLastFlushMs = System.currentTimeMillis()
                }
                w.write(line)
                w.newLine()
                val n = line.length + 1
                logBytes += n
                logBytesSinceFlush += n
                val now = System.currentTimeMillis()
                if (logBytesSinceFlush >= 8192 || now - logLastFlushMs >= 2000) {
                    w.flush()
                    logBytesSinceFlush = 0
                    logLastFlushMs = now
                }
            }
        } catch (_: Exception) {
            // The log is evidence, not a reason to fail a connect.
        }
    }

    /** Flushes and closes the session log writer, if open —
     *  called from the service's destroy path. */
    fun closeLog() {
        synchronized(logLock) {
            try { logWriter?.flush() } catch (_: Exception) {}
            try { logWriter?.close() } catch (_: Exception) {}
            logWriter = null
            logBytes = 0
            logBytesSinceFlush = 0
        }
    }

    fun logFile(context: Context): File =
        File(context.filesDir, "openvpn").apply { mkdirs() }
            .resolve("openvpn.log")

    fun resetSession() {
        phase = "idle"
        profileId = ""
        profileName = ""
        error = null
        exitIp = ""
        exitCountry = ""
        exitCode = ""
        upBytes = 0
        downBytes = 0
        synchronized(logLock) { logRing.clear() }
    }
}

/**
 * The single owner of the OpenVPN engine's tun interface
 * (build 2030, defect A). On device, a session established its
 * interface correctly — the tun_applied dump read exactly
 * right — and the NEXT session then died in the core with
 * "TUN Error: cannot acquire tun interface socket"
 * (TUN_IFACE_CREATE): fd acquisition/ownership across
 * consecutive sessions was unreliable, because an interface
 * left open by the previous session (or closed late, after the
 * new one had already asked) makes VpnService.establish return
 * null or throw. This object is the only place that holds an
 * interface: every establish closes whatever a prior session
 * left behind BEFORE asking the system for a new one, and a
 * failed first attempt closes everything and retries once
 * before the session fails with the named TUN_ACQUIRE_FAILED
 * state. Closing the retained original never invalidates the
 * detached descriptor the core drives — the core holds its
 * own dup.
 */
object OpenVpnTun {
    private var current: ParcelFileDescriptor? = null

    /** Deterministically closes any interface a prior session
     *  held. Returns true when one was actually closed. */
    @Synchronized
    fun closePrior(): Boolean {
        val old = current ?: return false
        current = null
        try {
            old.close()
        } catch (_: Exception) {
        }
        return true
    }

    /** Takes ownership of [pfd] (closing any prior one first). */
    @Synchronized
    fun adopt(pfd: ParcelFileDescriptor) {
        val old = current
        current = pfd
        if (old != null && old !== pfd) {
            try {
                old.close()
            } catch (_: Exception) {
            }
        }
    }

    /** Releases the interface at session end / abandon. */
    @Synchronized
    fun release(pfd: ParcelFileDescriptor?) {
        val held = current
        if (held != null && (pfd == null || held === pfd)) current = null
        try {
            pfd?.close()
        } catch (_: Exception) {
        }
    }
}

class OpenVpnService : VpnService() {
    private val worker = Executors.newSingleThreadExecutor()
    private val stopping = AtomicBoolean(false)

    /**
     * Build 2123 (audit P-06 / E-03): underlying-network
     * watch — Mozilla's CoreService pattern, shared via
     * [UnderlyingNetworkWatch]. The watch's
     * setUnderlyingNetworks re-point is the fix here:
     * OpenVPN's own keepalive/reconnect then lands on the
     * live network instead of the dead one; up to 2121 a
     * Wi-Fi↔mobile switch left the session stalled while
     * Connected.
     */
    private val underlyingWatch =
        UnderlyingNetworkWatch(this, "OpenVpnService") {
            OpenVpnTrace.mark(this, "underlying_network_changed")
        }

    @Volatile private var session: Session? = null

    /** Build 2125 (audit A25-04): the Settings kill
     *  switch, carried on the start intent. */
    @Volatile private var inKillSwitch = false

    /** Build 2125 (A25-04): the TUN a kill-switch hold is
     *  keeping open (the session that owned it is gone;
     *  OpenVpnTun still holds the same object). */
    @Volatile private var heldTunPfd: ParcelFileDescriptor? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Build 2070 (review §5.1): the start net — the last
        // engine service without one (the 2068 round named this
        // gap and left it, because the start is a multi-step
        // state machine; the net does not touch the state
        // machine, it wraps the command that launches it). The
        // whole body runs in onStartCommandGuarded below; a
        // Throwable escaping it (startInForeground's refusal
        // above all — it runs on the main thread before any
        // session exists) is recorded in crash.log and in the
        // service's own breadcrumb trail, and the service stops
        // gracefully, instead of an uncaught main-thread death.
        return try {
            onStartCommandGuarded(intent, flags, startId)
        } catch (e: Throwable) {
            CrashLog.append(this, "OpenVpnService.onStartCommand", e)
            OpenVpnTrace.mark(this, "start_command_failed", e.javaClass.simpleName)
            stopSelf()
            START_NOT_STICKY
        }
    }

    private fun onStartCommandGuarded(intent: Intent?, flags: Int, startId: Int): Int {
        // Build 2123 (P-06): the underlying-network watch
        // lives for the service's lifetime (idempotent).
        underlyingWatch.start()
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel()
                // Build 2116 (B7-1): the claim is released.
                EngineClaim.release(this, EngineClaim.OPENVPN)
                return START_NOT_STICKY
            }
            ACTION_START -> {
                // Build 2116 (B7-1, AB-08): claim the VPN
                // slot through the native single-writer
                // claim, displacing any other engine.
                EngineClaim.claim(this, EngineClaim.OPENVPN)
                startInForeground()
                if (running) return START_STICKY
                stopping.set(false)
                val profileId = intent.getStringExtra(EXTRA_PROFILE_ID) ?: ""
                val name = intent.getStringExtra(EXTRA_NAME) ?: ""
                val config = intent.getStringExtra(EXTRA_CONFIG) ?: ""
                val credKey = intent.getStringExtra(EXTRA_CRED_KEY) ?: ""
                val user = intent.getStringExtra(EXTRA_USER) ?: ""
                val pass = intent.getStringExtra(EXTRA_PASS) ?: ""
                val needsCreds = intent.getBooleanExtra(EXTRA_NEEDS_CREDS, false)
                // Build 2125 (A25-04): the kill switch.
                inKillSwitch = intent.getBooleanExtra(EXTRA_KILL_SWITCH, false)
                if (killSwitchHeld) {
                    // A fresh start over a hold: release
                    // the held TUN first (the new session's
                    // establish would close it anyway —
                    // this keeps the flag honest).
                    releaseHeldTun()
                }
                worker.execute {
                    try {
                        startTunnel(profileId, name, config, credKey, user, pass, needsCreds)
                    } catch (e: Throwable) {
                        // Build 2070 (review §5.1): Throwable +
                        // crash.log (was Exception + logcat). The
                        // session loop inside already catches
                        // LinkageError for the known native-missing
                        // case; any OTHER Error on this worker
                        // (vault/keystore class-init, a
                        // NoClassDefFoundError) escaped uncaught
                        // and took the process down. The recorded
                        // failure takes the same error-state +
                        // fail() path the Exception always took.
                        CrashLog.append(
                            this,
                            "OpenVpnService.startTunnel",
                            e,
                        )
                        Log.e(TAG, "the OpenVPN tunnel did not start", e)
                        if (OpenVpnCore.error == null) {
                            OpenVpnCore.error = "START_FAILED: ${e.message ?: e}"
                        }
                        OpenVpnCore.phase = "error"
                        fail()
                    }
                }
                return START_STICKY
            }
        }
        return START_NOT_STICKY
    }

    private fun startTunnel(
        profileId: String,
        name: String,
        config: String,
        credKey: String,
        user: String,
        pass: String,
        needsCreds: Boolean,
    ) {
        OpenVpnCore.resetSession()
        OpenVpnCore.profileId = profileId
        OpenVpnCore.profileName = name
        OpenVpnTrace.begin(this, name)
        OpenVpnCore.log(this, "connect: profile \"$name\"")
        if (!OpenVpnNative.available(this)) {
            throw IllegalStateException("CORE_UNAVAILABLE: the OpenVPN core library is missing")
        }
        OpenVpnNative.setBreadcrumbFile(OpenVpnTrace.file(this).absolutePath)
        // Credentials: the one-shot pair from the prompt wins;
        // otherwise the vault entry for this profile.
        var username = user
        var password = pass
        if (username.isEmpty() && credKey.isNotEmpty()) {
            OpenVpnVault.load(this, credKey)?.let { (u, p) ->
                username = u
                password = p
            }
        }
        // Build 2027 defence in depth: a profile that needs
        // credentials must NEVER reach the native core with an
        // empty pair. Build 2026 degraded silently here — an
        // undecryptable vault entry read as "no credentials"
        // and the session started empty (the connect deaths
        // under investigation). Fail loudly instead, naming
        // whether an entry exists but cannot be read.
        if (needsCreds && username.isEmpty() && password.isEmpty()) {
            val status = if (credKey.isEmpty()) {
                OpenVpnVault.CredStatus.NONE
            } else {
                OpenVpnVault.status(this, credKey)
            }
            OpenVpnTrace.mark(this, "vault_blocked", status.name)
            if (status == OpenVpnVault.CredStatus.UNREADABLE) {
                throw IllegalStateException(
                    "CREDENTIALS_UNREADABLE: the saved credentials could not " +
                        "be read on this device — clear them from the " +
                        "profile and connect again to re-enter them",
                )
            }
            throw IllegalStateException(
                "CREDENTIALS_MISSING: this profile needs credentials — " +
                    "enter them when you connect",
            )
        }
        OpenVpnTrace.mark(this, "vault_read_ok")
        if (prepare(this) != null) {
            throw IllegalStateException("the VPN has no permission")
        }
        val s = Session(profileId, config, username, password)
        session = s
        OpenVpnCore.phase = "connecting"
        // Build 2126 (A26-04): a new session starts with
        // no connected evidence.
        OpenVpnCore.wasConnected = false
        running = true
        startedAtMs = System.currentTimeMillis()
        updateNotification()
        // The connect deadline: a server that never answers must
        // not leave the page on "connecting" for good.
        // Build 2099 (V1): the deadline applies only until the
        // core reports CONNECTED. Once the session enters the
        // "verifying" phase it is exempt: the verify window's
        // worst case is ~76 s (3 attempts x ~24 s of probes +
        // sleeps), which alone exceeds the 75 s deadline
        // measured from before the handshake, so firing here
        // would kill the very counter cross-check the verify
        // phase ends with. Verification is bounded by its own
        // probe loop, which always terminates in verified or
        // NO_DATA. The deadline stays fully in force for the
        // pre-CONNECTED phases (evaluate/handshake/auth),
        // which is what it exists for.
        Thread {
            try {
                Thread.sleep(CONNECT_DEADLINE_MS)
            } catch (_: InterruptedException) {
                return@Thread
            }
            if (session === s && running &&
                OpenVpnCore.phase != "connected" &&
                OpenVpnCore.phase != "verifying"
            ) {
                s.timeOut()
            }
        }.apply { isDaemon = true; setName("openvpn-deadline") }.start()
        s.run()
        // run() returned: the session is over, one way or another.
        s.done.await(1, TimeUnit.SECONDS)
        if (session === s) {
            session = null
            running = false
            if (killSwitchHeld) {
                // Build 2125 (A25-04): the kill-switch
                // hold — the service STAYS foreground with
                // the held TUN until the user disconnects
                // (stopTunnel releases it) or a fresh start
                // replaces it.
                updateNotification()
            } else {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
    }

    /** Build 2125 (A25-04): release a kill-switch-held TUN. */
    private fun releaseHeldTun() {
        val held = heldTunPfd
        heldTunPfd = null
        killSwitchHeld = false
        if (held != null) OpenVpnTun.release(held)
    }

    private fun fail() {
        running = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun stopTunnel() {
        OpenVpnTrace.mark(this, "clean_stop")
        stopping.set(true)
        if (session == null && killSwitchHeld) {
            // Build 2125 (A25-04): stopping a kill-switch
            // hold — no session is left to stop; releasing
            // the held TUN is the whole stop.
            releaseHeldTun()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }
        // The native stop is thread-safe and returns at once;
        // the grace/abandon bookkeeping runs on its own thread,
        // never on the main thread (ANR) and never on the worker
        // the session itself occupies (deadlock).
        val s = session ?: return
        s.stop()
        Thread {
            if (!s.done.await(STOP_GRACE_MS, TimeUnit.MILLISECONDS) && session === s) {
                // The core did not let go: free the state at
                // once and close its TUN from here; the stuck
                // thread cleans up after itself when it returns.
                s.abandon()
                session = null
                running = false
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }.apply { isDaemon = true; name = "openvpn-stop-grace" }.start()
    }

    override fun onRevoke() {
        stopTunnel()
        super.onRevoke()
    }

    override fun onDestroy() {
        // Build 2125 (A25-04): a kill-switch-held TUN is
        // released with the service.
        releaseHeldTun()
        // Build 2123 (P-06): the network watch dies with
        // the service.
        underlyingWatch.stop()
        // Build 2116 (B7-1): teardown releases the claim
        // (owner-checked).
        EngineClaim.release(this, EngineClaim.OPENVPN)
        stopping.set(true)
        // The native stop leaves the main thread (build 2030,
        // defect C audit): onDestroy runs there, and no native
        // lifecycle call may block it. stopTunnel already
        // threads its grace/abandon bookkeeping; this was the
        // one direct call left.
        val s = session
        if (s != null) {
            Thread { s.stop() }
                .apply { isDaemon = true; name = "openvpn-destroy-stop" }
                .start()
        }
        running = false
        worker.shutdownNow()
        // Build 2055 (audit B-M4): flush the buffered engine log
        // so the session's last lines reach disk on destroy.
        OpenVpnCore.closeLog()
        super.onDestroy()
    }

    /**
     * One connection. Implements the bridge's callback contract
     * (the method names and signatures are resolved by the
     * native side — do not rename them). The blocking
     * OpenVpnNative.run call owns the calling thread; every
     * callback arrives on it.
     */
    private inner class Session(
        val profileId: String,
        val config: String,
        val username: String,
        val password: String,
    ) {
        private val stopped = AtomicBoolean(false)
        private val handle = AtomicLong(0)
        val done = CountDownLatch(1)

        @Volatile private var timedOut = false
        @Volatile private var terminal: String? = null

        private var builder: Builder? = null
        private var retainedTun: ParcelFileDescriptor? = null
        private var dnsAdded = false
        private var rerouteV4 = false
        private val verifyGeneration = java.util.concurrent.atomic.AtomicInteger()

        // ---- build 2030: session-lifecycle repair ----

        /**
         * Consecutive socket_protect failures (defect C). The
         * core asks the service to protect every socket it
         * opens; on device, a session degenerated into protect
         * failing on EVERY remote and the core retried forever
         * against a dead service state. Three in a row end the
         * session with the named SOCKET_PROTECT_FAILED state
         * and a reset service instead.
         */
        private val protectFailures =
            java.util.concurrent.atomic.AtomicInteger(0)

        /**
         * How many times THIS session has re-run the core with
         * the held pair after a NEED_CREDS ending (defect B).
         * The pair (the constructor vals) is held for the
         * whole session lifetime — core-initiated reconnects
         * and renegotiation included — and released only when
         * the session object dies. The budget resets on every
         * CONNECTED event: the pair's job is to answer
         * re-requests, not to retry forever.
         */
        private val credsResupplies =
            java.util.concurrent.atomic.AtomicInteger(0)

        // What the core asked us to apply to the Builder, kept
        // verbatim (build 2029A instrumentation): at
        // tun_establish the whole set is written to the session
        // trail and the engine log, so ONE device attempt shows
        // exactly which addresses/routes/DNS/MTU the interface
        // was established with — the 2028 sessions proved the
        // control plane (TLS, PUSH, ASSIGN_IP, establish) while
        // no user traffic crossed, and the applied builder
        // state was the one thing nobody could see.
        private val appliedAddresses = mutableListOf<String>()
        private val appliedRoutes = mutableListOf<String>()
        private val appliedDns = mutableListOf<String>()
        private val appliedDomains = mutableListOf<String>()
        @Volatile private var appliedMtu: Int = 0

        fun timeOut() {
            timedOut = true
            if (terminal == null) terminal = "CONNECT_DEADLINE"
            stop()
        }

        fun stop() {
            stopped.set(true)
            if (running && OpenVpnCore.phase != "error") {
                OpenVpnCore.phase = "idle"
            }
            handle.get().takeIf { it != 0L }?.let { runCatching { OpenVpnNative.stop(it) } }
        }

        /** The core thread did not let go: close its TUN from here. */
        fun abandon() {
            stopped.set(true)
            handle.get().takeIf { it != 0L }?.let { runCatching { OpenVpnNative.stop(it) } }
            synchronized(this) {
                OpenVpnTun.release(retainedTun)
                retainedTun = null
            }
        }

        fun run() {
            try {
                val validation = OpenVpnNative.evaluate(config)
                if (validation.isNotEmpty()) {
                    terminal = validation
                    return
                }
                // Build 2030 (defect B): the session holds its
                // pair for its whole lifetime and answers the
                // core's credential re-requests. A server that
                // pushes auth-nocache makes the core purge the
                // pair after the first authentication (the
                // engine log's "Clearing credentials"), so a
                // core-initiated reconnect after a keepalive
                // timeout dies with NEED_CREDS even though the
                // pair was handed over correctly. run() now
                // reports that ending distinctly (bridge), and
                // this loop re-runs the session with a FRESH
                // handle and the same held pair; the budget
                // resets on every CONNECTED (onCoreEvent). The
                // pair is released only when this session object
                // dies — never mid-session.
                while (true) {
                    val id = OpenVpnNative.create()
                    check(id != 0L) { "CORE_UNAVAILABLE" }
                    handle.set(id)
                    if (stopped.get()) OpenVpnNative.stop(id)
                    val rawResult = try {
                        OpenVpnNative.run(id, config, username, password, this)
                    } finally {
                        handle.getAndSet(0).takeIf { it != 0L }?.let {
                            runCatching { OpenVpnNative.release(it) }
                        }
                    }
                    // Build 2099 (B6): run() returns the CODE
                    // alone, or "CODE\n<detail>" when the core's
                    // Status carried a message — the bridge now
                    // forwards that message scrubbed instead of
                    // dropping it at the JNI boundary (diagnosis
                    // §3). Split at the FIRST newline: the left
                    // side drives every existing code path
                    // (NEED_CREDS resupply included); the right
                    // side is the core's own words, routed to
                    // the trail and the engine log at once and
                    // preserved in the terminal error below as
                    // "CODE: <detail>" (B7) instead of being
                    // replaced by the bare code.
                    val error = rawResult.substringBefore('\n')
                    val detail = rawResult.substringAfter('\n', "").trim()
                    if (detail.isNotEmpty()) {
                        OpenVpnTrace.mark(
                            this@OpenVpnService,
                            "core_error_detail",
                            "$error: $detail",
                        )
                        OpenVpnCore.log(
                            this@OpenVpnService,
                            "core error detail: $error: $detail",
                        )
                    }
                    val resupply = error == "NEED_CREDS" &&
                        !stopped.get() &&
                        username.isNotEmpty() &&
                        credsResupplies.get() < MAX_CREDS_RESUPPLY
                    if (!resupply) {
                        if (terminal == null && error.isNotEmpty()) {
                            // Build 2099 (B7): the code stays
                            // the prefix, the detail rides
                            // after it — never discarded.
                            terminal = if (detail.isNotEmpty()) {
                                "$error: $detail"
                            } else {
                                error
                            }
                        }
                        break
                    }
                    val attempt = credsResupplies.incrementAndGet()
                    terminal = null
                    OpenVpnTrace.mark(
                        this@OpenVpnService,
                        "creds_resupplied",
                        "attempt=$attempt",
                    )
                    OpenVpnCore.log(
                        this@OpenVpnService,
                        "credentials re-supplied for a core reconnect " +
                            "(attempt $attempt)",
                    )
                }
            } catch (e: Exception) {
                // Build 2099 (B7): the catch-all used to
                // collapse every exception to the bare
                // CONNECTION_FAILED code, discarding the one
                // text that named the failure (diagnosis §3,
                // layer 3). The exception's message now rides
                // after the code as its detail, the same
                // "CODE: <detail>" shape as the run() result.
                if (terminal == null) {
                    val message = e.message?.takeIf { it.isNotBlank() }
                    terminal = if (message != null) {
                        "CONNECTION_FAILED: $message"
                    } else {
                        "CONNECTION_FAILED"
                    }
                }
            } catch (_: LinkageError) {
                if (terminal == null) terminal = "CORE_UNAVAILABLE"
            } finally {
                handle.getAndSet(0).takeIf { it != 0L }?.let {
                    runCatching { OpenVpnNative.release(it) }
                }
                synchronized(this) {
                    // Build 2125 (audit A25-04): the kill
                    // switch. A session that was CONNECTED
                    // (or mid-reconnect from connected) and
                    // ends WITHOUT the user stopping keeps
                    // its TUN: the service retains the
                    // original descriptor precisely so this
                    // is possible — the core drove a detached
                    // dup, so the interface stays up as a
                    // blackhole on the retained one. The
                    // service tail in startTunnel sees the
                    // flag and stays foreground instead of
                    // stopping. A user stop (stopped), a
                    // connect-phase failure (never
                    // connected), and the abandon path all
                    // release as before.
                    // Build 2126 (audit A26-04): the gate
                    // reads the was-connected LATCH, not the
                    // live phase — the DISCONNECTED event
                    // handler has usually already reset the
                    // phase to "idle" by the time this tail
                    // runs, which is why the 2125 gate never
                    // fired for remote-initiated disconnects.
                    val hold = inKillSwitch && !stopped.get() &&
                        retainedTun != null &&
                        OpenVpnCore.wasConnected
                    // The latch is per-session evidence; it
                    // has now decided this session's ending,
                    // whichever way it went.
                    OpenVpnCore.wasConnected = false
                    if (hold) {
                        heldTunPfd = retainedTun
                        retainedTun = null
                        killSwitchHeld = true
                        OpenVpnTrace.mark(
                            this@OpenVpnService,
                            "kill_switch_hold",
                            terminal ?: "session ended",
                        )
                    } else {
                        OpenVpnTun.release(retainedTun)
                        retainedTun = null
                    }
                }
                OpenVpnTrace.mark(
                    this@OpenVpnService,
                    "session_end",
                    terminal ?: "clean",
                )
                // A terminal reason becomes the shown failure
                // unless the user was already stopping (a stop
                // that races a core error is a stop, not a
                // failure) — a deadline timeout still counts.
                if (terminal != null && (!stopped.get() || timedOut)) {
                    OpenVpnCore.error = terminal
                    OpenVpnCore.phase = "error"
                    OpenVpnCore.log(this@OpenVpnService, "failed: $terminal")
                } else if (terminal == null && !stopped.get() &&
                    OpenVpnCore.phase != "error"
                ) {
                    OpenVpnCore.phase = "idle"
                }
                // Build 2055 (audit B-M4): the session's last
                // line is written — flush the buffered log now.
                // onDestroy also closes it; a later log reopens
                // it lazily.
                OpenVpnCore.closeLog()
                done.countDown()
            }
        }

        // ---- the bridge contract (called from native) ----

        fun configureTun(operation: String, value: Int): Boolean = runCatching {
            when (operation) {
                "new" -> {
                    // Build 2099 (V3): a new Builder starts
                    // empty, so the applied TUN state must too.
                    // These lists/fields only ever appended, so
                    // without this a core-initiated TUN rebuild
                    // inside one session (reconnect/re-push)
                    // left the previous incarnation's entries
                    // behind — a stale IPv6 address kept B3's
                    // ::/0 decision true on a now IPv4-only
                    // interface, and a stale appliedMtu kept
                    // B4's default from applying. The core's
                    // callbacks (mtu/addAddress/addRoute/addDns/
                    // addSearchDomain) replay after this point
                    // and repopulate the state before
                    // establishTun reads it.
                    appliedAddresses.clear()
                    // Build 2125 (A25-25): a new session's
                    // builder state — the family verdict goes
                    // with it.
                    OpenVpnService.ipv6Captured = false
                    appliedRoutes.clear()
                    appliedDns.clear()
                    appliedDomains.clear()
                    appliedMtu = 0
                    dnsAdded = false
                    rerouteV4 = false
                    builder = Builder()
                        .setSession(getString(R.string.app_name))
                        .setBlocking(false)
                    true
                }
                "mtu" -> {
                    appliedMtu = value.coerceIn(576, 9000)
                    builder?.setMtu(appliedMtu)
                    true
                }
                "protect" -> protectSocket(value)
                else -> false
            }
        }.getOrDefault(false)

        fun addAddress(address: String, prefix: Int): Boolean = runCatching {
            builder?.addAddress(address, prefix)
            appliedAddresses += "$address/$prefix"
            true
        }.getOrDefault(false)

        fun addRoute(address: String, prefix: Int): Boolean = runCatching {
            if (address == "0.0.0.0" && prefix == 0) rerouteV4 = true
            builder?.addRoute(address, prefix)
            appliedRoutes += "$address/$prefix"
            true
        }.getOrDefault(false)

        fun addDns(address: String, ignored: Int): Boolean = runCatching {
            builder?.addDnsServer(address)
            dnsAdded = true
            appliedDns += address
            true
        }.getOrDefault(false)

        fun addSearchDomain(domain: String, ignored: Int): Boolean = runCatching {
            builder?.addSearchDomain(domain)
            appliedDomains += domain
            true
        }.getOrDefault(false)

        fun establishTun(): Int {
            if (stopped.get()) return -1
            val b = builder ?: return -1
            val appsSummary = applyApps(b)
            // Capture IPv6 when the session actually carries
            // it. Build 2029A added the ::/0 route ALWAYS (MLM
            // parity, so a def1 profile could not leak v6 to
            // the physical link); build 2099 makes it
            // conditional: on an IPv4-only session (no IPv6
            // address applied by addAddress above — the same
            // appliedAddresses state the tun_applied dump
            // prints) the captured ::/0 blackholes every
            // v6-first attempt, Ember's own data proof
            // included, into a tunnel with no v6 transport
            // (openvpn-nodata-diagnosis.md cause 2). The route
            // is added only when an IPv6 address was applied.
            val ipv6Applied = appliedAddresses.any { it.contains(':') }
            // Build 2125 (audit A25-25 / P-04 remainder):
            // publish the family verdict for the state map
            // (see the companion's ipv6Captured).
            OpenVpnService.ipv6Captured = ipv6Applied
            if (ipv6Applied) {
                runCatching { b.addRoute("::", 0) }
                appliedRoutes += "::/0 (capture)"
            } else {
                OpenVpnCore.log(
                    this@OpenVpnService,
                    "tun: no IPv6 address applied; not capturing ::/0",
                )
            }
            if (!dnsAdded) {
                // No DNS came through the core: name resolution
                // would silently use the physical network's.
                runCatching { b.addDnsServer("1.1.1.1") }
                appliedDns += "1.1.1.1 (fallback)"
                OpenVpnCore.log(this@OpenVpnService, "tun: no DNS from the server; using 1.1.1.1")
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) b.setMetered(false)
            // Build 2099: a default MTU when the core never
            // named one. tun_builder_set_mtu fires only when
            // the profile or the PUSH carries tun-mtu, so a
            // profile without one left appliedMtu at 0 and
            // Builder.setMtu was never called — the interface
            // MTU was an uncontrolled platform default while
            // the core's session math assumed 1500 and mssfix
            // stayed disabled (diagnosis §1/cause 3). Apply
            // 1400 in that case and record it in appliedMtu,
            // so the dump below and every later log line state
            // the MTU the interface really got.
            if (appliedMtu == 0) {
                appliedMtu = 1400
                runCatching { b.setMtu(appliedMtu) }
                OpenVpnCore.log(
                    this@OpenVpnService,
                    "tun: no MTU from the core; applying default 1400",
                )
            }
            // The applied-state dump (build 2029A): one trail
            // line + one log line carrying everything the
            // interface is about to be established with. The
            // per-app summary rides along — a session where only
            // this app is allowed on the tunnel looks exactly
            // like "connected, but nothing loads" from the
            // browser, and this line names that state outright.
            val dump = "addr=[${appliedAddresses.joinToString(",")}] " +
                "routes=[${appliedRoutes.joinToString(",")}] " +
                "dns=[${appliedDns.joinToString(",")}] " +
                "domains=[${appliedDomains.joinToString(",")}] " +
                "mtu=$appliedMtu rerouteV4=$rerouteV4 $appsSummary"
            OpenVpnTrace.mark(this@OpenVpnService, "tun_applied", dump)
            OpenVpnCore.log(this@OpenVpnService, "tun applied: $dump")
            // Single-owner acquisition (build 2030, defect A):
            // close whatever a prior session left BEFORE asking
            // for a new interface; a failed first attempt
            // closes everything and retries ONCE; a second
            // failure ends the session with the named
            // TUN_ACQUIRE_FAILED state instead of the core's
            // opaque TUN_IFACE_CREATE death. The dup is part of
            // the acquisition — it used to sit outside the
            // guarded establish, so a throw there killed the
            // session the same opaque way.
            if (OpenVpnTun.closePrior()) {
                OpenVpnTrace.mark(this@OpenVpnService, "tun_prior_closed")
            }
            synchronized(this) { retainedTun = null }
            for (attempt in 1..2) {
                val tun = try {
                    b.establish()
                } catch (_: Exception) {
                    null
                }
                var fd = -1
                if (tun != null) {
                    fd = try {
                        ParcelFileDescriptor.dup(tun.fileDescriptor).detachFd()
                    } catch (_: Exception) {
                        -1
                    }
                }
                if (tun != null && fd >= 0) {
                    OpenVpnTun.adopt(tun)
                    synchronized(this) { retainedTun = tun }
                    OpenVpnTrace.mark(
                        this@OpenVpnService,
                        "tun_acquire",
                        "ok attempt=$attempt",
                    )
                    OpenVpnCore.log(
                        this@OpenVpnService,
                        "tun: interface up (attempt $attempt)",
                    )
                    return fd
                }
                if (tun != null) {
                    try {
                        tun.close()
                    } catch (_: Exception) {
                    }
                    OpenVpnTrace.mark(
                        this@OpenVpnService,
                        "tun_acquire",
                        "dup_failed attempt=$attempt",
                    )
                } else {
                    OpenVpnTrace.mark(
                        this@OpenVpnService,
                        "tun_acquire",
                        "fail attempt=$attempt",
                    )
                }
                OpenVpnTun.closePrior()
                if (stopped.get()) return -1
            }
            if (terminal == null) terminal = "TUN_ACQUIRE_FAILED"
            OpenVpnCore.log(
                this@OpenVpnService,
                "tun: could not acquire an interface after 2 attempts",
            )
            return -1
        }

        /**
         * The core's transport-socket protection (build 2030,
         * defect C). The VpnService call itself is inherited;
         * what is new is the accounting. On device a session
         * degenerated into protect failing on EVERY remote
         * while the core retried forever against the dead
         * state; three consecutive failures now end the
         * session with the named SOCKET_PROTECT_FAILED state,
         * drop the interface the sick session held, and stop
         * the core — the next connect starts from a reset
         * service instead of inheriting the loop.
         */
        private fun protectSocket(fd: Int): Boolean {
            val ok = try {
                protect(fd)
            } catch (_: Exception) {
                false
            }
            if (ok) {
                protectFailures.set(0)
                return true
            }
            val n = protectFailures.incrementAndGet()
            OpenVpnTrace.mark(
                this@OpenVpnService,
                "socket_protect_fail",
                "consecutive=$n",
            )
            if (n >= MAX_PROTECT_FAILURES && terminal == null) {
                terminal = "SOCKET_PROTECT_FAILED"
                OpenVpnCore.log(
                    this@OpenVpnService,
                    "socket protection failed $n times in a row; " +
                        "ending the session",
                )
                OpenVpnTun.closePrior()
                handle.get().takeIf { it != 0L }?.let {
                    runCatching { OpenVpnNative.stop(it) }
                }
            }
            return false
        }

        /**
         * The stored per-app choice, as the other engines apply
         * it. Returns a one-line summary for the tun_applied
         * dump (build 2029A): the mode and the packages it put
         * on the builder, so the trail shows the effective
         * routing the session actually got.
         */
        private fun applyApps(b: Builder): String {
            fun each(packages: Set<String>, add: (String) -> Unit) {
                for (pkg in packages) {
                    try {
                        add(pkg)
                    } catch (e: PackageManager.NameNotFoundException) {
                        // Uninstalled since.
                    }
                }
            }
            if (CoreService.appMode(this@OpenVpnService) == CoreService.MODE_INCLUDE) {
                val chosen = CoreService.appSet(this@OpenVpnService, CoreService.ONLY)
                var added = 0
                // Ember itself is added on purpose (see the file
                // header): the through-tunnel proof must ride the
                // tunnel it proves.
                each(chosen + packageName) {
                    b.addAllowedApplication(it)
                    added++
                }
                if (added > 0) {
                    return "apps: mode=include allowed=[${(chosen + packageName).joinToString(",")}]"
                }
            }
            // Excluded mode: our own package is NOT disallowed
            // (again the header's reason); the bypass set is.
            val bypass = CoreService.appSet(this@OpenVpnService, CoreService.BYPASS) - packageName
            each(bypass) {
                b.addDisallowedApplication(it)
            }
            return "apps: mode=exclude disallowed=[${bypass.joinToString(",")}]"
        }

        // Build 2099 (B6): the third parameter is the core
        // Event's info string, forwarded scrubbed by the
        // bridge. This exact signature is the JNI contract:
        // the bridge resolves it as
        // "(Ljava/lang/String;ZLjava/lang/String;)V" — do not
        // change it. Before, the bridge dropped info at the
        // boundary (diagnosis §3, layer 1), so a config-load
        // rejection surfaced as a bare code with the core's
        // own words destroyed.
        fun onCoreEvent(name: String, error: Boolean, info: String) {
            if (stopped.get() && name != "DISCONNECTED") return
            OpenVpnCore.log(
                this@OpenVpnService,
                "core event: $name${if (error) " (error)" else ""}" +
                    (if (info.isNotEmpty()) " — $info" else ""),
            )
            if (error && info.isNotEmpty()) {
                OpenVpnTrace.mark(
                    this@OpenVpnService,
                    "core_event_error",
                    "$name: $info",
                )
            }
            when {
                // Build 2099 (B7): with an error detail the
                // code stays as the prefix and the core's
                // words ride after it, here and in the
                // unrecognized-error mapping below.
                name == "AUTH_FAILED" -> terminal =
                    if (error && info.isNotEmpty()) {
                        "AUTH_FAILED: $info"
                    } else {
                        "AUTH_FAILED"
                    }
                // The core asked for credentials (build 2030,
                // defect B): NOT terminal at the event any
                // more. The core purged its own copy of the
                // pair (a pushed auth-nocache — the engine
                // log's "Clearing credentials") and asks again
                // on a core-initiated reconnect; run() ends
                // with the distinct NEED_CREDS result and the
                // session loop answers by re-running with the
                // pair the service still holds. It becomes
                // terminal only when the loop's budget is
                // exhausted or no pair is held — run() decides.
                name == "NEED_CREDS" ->
                    OpenVpnTrace.mark(this@OpenVpnService, "creds_requested")
                error -> {
                    // The code mapping is unchanged (build
                    // 2030): recognized names keep their name,
                    // the acquire failure maps to the manager's
                    // named state, anything else collapses to
                    // CONNECTION_FAILED — an already-set
                    // terminal still wins in the two collapsing
                    // cases. Build 2099 (B7): the collapse no
                    // longer discards the surfaced text — with
                    // an info detail the terminal becomes
                    // "CODE: <detail>", the code (or the
                    // preserved terminal's own code prefix, so
                    // details never stack) as prefix.
                    val code = when (name) {
                        "CERT_VERIFY_FAIL", "TLS_VERSION_MIN",
                        "CONNECTION_TIMEOUT", "NETWORK_UNREACHABLE" -> name
                        "TUN_IFACE_CREATE" -> terminal ?: "TUN_ACQUIRE_FAILED"
                        else -> terminal ?: "CONNECTION_FAILED"
                    }
                    terminal = if (info.isNotEmpty()) {
                        "${code.substringBefore(':').trim()}: $info"
                    } else {
                        code
                    }
                }
                name == "CONNECTED" -> {
                    terminal = null
                    credsResupplies.set(0)
                    OpenVpnTrace.mark(this@OpenVpnService, "core_connected")
                    OpenVpnCore.phase = "verifying"
                    updateNotification()
                    val generation = verifyGeneration.incrementAndGet()
                    Thread { verifyThroughTunnel(generation) }
                        .apply { isDaemon = true; setName("openvpn-verify") }.start()
                }
                name == "RECONNECTING" || name == "PAUSE" ||
                    name == "RESOLVE" || name == "WAIT" || name == "CONNECTING" -> {
                    if (OpenVpnCore.phase != "connected") {
                        OpenVpnCore.phase = "connecting"
                    } else {
                        OpenVpnCore.phase = "reconnecting"
                    }
                }
                name == "DISCONNECTED" -> {
                    if (OpenVpnCore.phase != "error") OpenVpnCore.phase = "idle"
                }
            }
        }

        /**
         * The core counts from the TUN device's frame (the
         * inversion ovpncli.cpp documents): bytesOut is what the
         * device sent toward the server, bytesIn what arrived
         * from it.
         */
        fun onCoreTraffic(bytesOut: Long, bytesIn: Long) {
            if (stopped.get()) return
            OpenVpnCore.upBytes = bytesOut.coerceAtLeast(0)
            OpenVpnCore.downBytes = bytesIn.coerceAtLeast(0)
        }

        fun onCoreLog(line: String) {
            OpenVpnCore.log(this@OpenVpnService, line)
        }

        /**
         * A real request across the tunnel — the definition of
         * "connected". This app rides its own tunnel (header),
         * so a plain HTTPS request goes through it; the answer
         * also names the exit. Three tries over ~20 s.
         *
         * Build 2099 hardening (diagnosis cause 4): the proof
         * used to be a single HTTPS GET to a single host and
         * the core's byte counters were never consulted, so a
         * tunnel carrying real traffic could be torn down as
         * NO_DATA because that one request failed (its DNS,
         * that exit's route to that host, a stalled TLS
         * flight). Each attempt now tries two independent
         * targets — the Cloudflare trace (which also names
         * the exit) and Google's generate_204 — and ANY
         * target proving traffic crosses verifies the
         * session. The core's counters are snapshotted on
         * entry; NO_DATA is declared only when every probe
         * failed AND downBytes has not moved meaningfully
         * by the end of the window (Build 2099, V2 — see the
         * counter cross-check at the end of this function).
         * A session whose counters moved past the threshold
         * is verified, never torn down.
         */
        private fun verifyThroughTunnel(generation: Int) {
            val upAtStart = OpenVpnCore.upBytes
            val downAtStart = OpenVpnCore.downBytes
            // Build 2099 (V2): the counter cross-check's
            // baseline. It starts as the entry snapshot (the
            // fallback if only one attempt's worth of window
            // ever runs) and is re-snapshotted after the FIRST
            // failed attempt below, so attempt 1's own
            // through-tunnel DNS — downstream frames the
            // probes themselves caused — no longer counts as
            // evidence the data plane is alive.
            var upCounterBaseline = upAtStart
            var downCounterBaseline = downAtStart
            repeat(3) { attempt ->
                if (stopped.get() || verifyGeneration.get() != generation) return
                val exit = probeExit()
                if (exit != null) {
                    if (stopped.get() || verifyGeneration.get() != generation) return
                    OpenVpnCore.exitIp = exit.first
                    OpenVpnCore.exitCountry = exit.second
                    OpenVpnCore.exitCode = exit.third
                    OpenVpnCore.phase = "connected"
                    OpenVpnCore.wasConnected = true
                    OpenVpnTrace.mark(this@OpenVpnService, "verified")
                    OpenVpnCore.log(
                        this@OpenVpnService,
                        "verified: exit ${exit.first} ${exit.second}",
                    )
                    updateNotification()
                    return
                }
                if (probeGenerate204()) {
                    if (stopped.get() || verifyGeneration.get() != generation) return
                    OpenVpnCore.phase = "connected"
                    OpenVpnCore.wasConnected = true
                    OpenVpnTrace.mark(
                        this@OpenVpnService,
                        "verified",
                        "via=generate_204",
                    )
                    OpenVpnCore.log(
                        this@OpenVpnService,
                        "verified: traffic crossed " +
                            "(generate_204 answered through the tunnel)",
                    )
                    updateNotification()
                    return
                }
                // Build 2099 (V2): both probes just failed on
                // the first attempt — re-snapshot the counters
                // now, so everything the first attempt itself
                // moved (its tunnel DNS above all) is excluded
                // from the cross-check at the end of the window.
                if (attempt == 0) {
                    upCounterBaseline = OpenVpnCore.upBytes
                    downCounterBaseline = OpenVpnCore.downBytes
                }
                if (attempt < 2) {
                    try {
                        Thread.sleep(2000)
                    } catch (_: InterruptedException) {
                        return
                    }
                }
            }
            if (stopped.get() || verifyGeneration.get() != generation) return
            // Build 2099: the counter cross-check rides the
            // same probe window (no extra wait). Downstream
            // movement since the snapshot is the data plane
            // proving itself even when both probe targets
            // failed — verify instead of tearing down.
            // Build 2099 (V2): the movement must exceed
            // COUNTER_VERIFY_THRESHOLD_BYTES past the
            // re-snapshot (or past the entry snapshot when
            // that is the baseline): the probes' own DNS and
            // other small downstream chatter grow downBytes
            // by a few hundred bytes even on a path where
            // real traffic blackholes, so any-growth was
            // enough to fake-verify such a session.
            val downNow = OpenVpnCore.downBytes
            val downDelta = downNow - downCounterBaseline
            if (downDelta > COUNTER_VERIFY_THRESHOLD_BYTES) {
                OpenVpnCore.phase = "connected"
                    OpenVpnCore.wasConnected = true
                OpenVpnTrace.mark(this@OpenVpnService, "verified", "via=counters")
                OpenVpnCore.log(
                    this@OpenVpnService,
                    "verified: probes failed but the core's counters " +
                        "moved (down +$downDelta B past the " +
                        "counter baseline, threshold " +
                        "${COUNTER_VERIFY_THRESHOLD_BYTES} B, " +
                        "up +${OpenVpnCore.upBytes - upCounterBaseline} B); " +
                        "session kept — bytes are crossing even " +
                        "though both probe targets failed",
                )
                updateNotification()
                return
            }
            terminal = "NO_DATA"
            OpenVpnCore.log(this@OpenVpnService, "failed: NO_DATA (handshake ok, no traffic)")
            handle.get().takeIf { it != 0L }?.let { runCatching { OpenVpnNative.stop(it) } }
        }

        /**
         * Build 2099: the second, independent probe target —
         * true when Google's generate_204 answers HTTP 204
         * through the tunnel. It names no exit (the
         * Cloudflare trace remains the exit-naming probe);
         * its job is only to prove traffic crosses, so one
         * host's failure can no longer condemn a live tunnel.
         */
        private fun probeGenerate204(): Boolean {
            try {
                val conn = URL("https://www.google.com/generate_204")
                    .openConnection() as HttpURLConnection
                conn.connectTimeout = 6000
                conn.readTimeout = 6000
                conn.setRequestProperty("User-Agent", "RalysndEmber")
                val ok = conn.responseCode == 204
                conn.disconnect()
                return ok
            } catch (_: Exception) {
                // No answer through the tunnel.
            }
            return false
        }

        /** (ip, country name, country code) through the tunnel, or null. */
        private fun probeExit(): Triple<String, String, String>? {
            // Build 2087 (analysis A5) — the former second attempt
            // (http://ip-api.com/...) is REMOVED, named per the
            // no-silent-removal rule: since build 2084 the app's
            // network security config permits cleartext only for
            // the two gstatic probe hosts, so the platform refused
            // that request in-process every time, and ip-api.com
            // offers no free HTTPS endpoint to switch it to. The
            // HTTPS trace below yields the same ip + country
            // code. (Build 2099: it is no longer the only probe
            // target — probeGenerate204 is the second,
            // independent one; the trace stays the exit-naming
            // probe.)
            try {
                val conn = URL("https://www.cloudflare.com/cdn-cgi/trace")
                    .openConnection() as HttpURLConnection
                conn.connectTimeout = 6000
                conn.readTimeout = 6000
                conn.setRequestProperty("User-Agent", "RalysndEmber")
                val text = conn.inputStream.bufferedReader().readText()
                var ip = ""
                var loc = ""
                for (line in text.lineSequence()) {
                    when {
                        line.startsWith("ip=") -> ip = line.substring(3).trim()
                        line.startsWith("loc=") -> loc = line.substring(4).trim()
                    }
                }
                if (ip.isNotEmpty()) return Triple(ip, loc, loc)
            } catch (_: Exception) {
                // No answer through the tunnel.
            }
            return null
        }
    }

    // Notifications.

    private fun startInForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, getString(R.string.notification_channel), NotificationManager.IMPORTANCE_LOW)
                    .apply { setShowBadge(false) },
            )
        }
        val notification = notification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification() {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification())
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(
            this, 50, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 51, Intent(this, OpenVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val name = OpenVpnCore.profileName
        val text = when {
            // Build 2125 (A25-04): the held state names
            // itself on the notification.
            killSwitchHeld ->
                "OpenVPN · kill switch holding — traffic is blocked"
            running && OpenVpnCore.phase == "connected" && OpenVpnCore.exitCountry.isNotEmpty() ->
                "OpenVPN · $name · ${OpenVpnCore.exitCountry}"
            running && OpenVpnCore.phase == "connected" -> "OpenVPN · $name"
            else -> getString(R.string.notification_connecting)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_logo)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, getString(R.string.notification_stop), stop).build())
            .build()
    }

    companion object {
        const val ACTION_START = "com.ralysnd.ember.OPENVPN_START"
        const val ACTION_STOP = "com.ralysnd.ember.OPENVPN_STOP"
        private const val EXTRA_PROFILE_ID = "profileId"
        private const val EXTRA_NAME = "name"
        private const val EXTRA_CONFIG = "config"
        private const val EXTRA_CRED_KEY = "credKey"
        private const val EXTRA_USER = "user"
        private const val EXTRA_PASS = "pass"
        private const val EXTRA_NEEDS_CREDS = "needsCreds"
        // Build 2125 (A25-04): the kill switch.
        private const val EXTRA_KILL_SWITCH = "killSwitch"

        private const val CHANNEL = "openvpn_status"
        private const val NOTIFICATION_ID = 5
        private const val TAG = "OpenVpnService"

        /** Handshake plus the data proof on a slow network, and no longer. */
        private const val CONNECT_DEADLINE_MS = 75_000L

        /** Build 2099 (V2): downstream growth past the
         *  verify window's counter baseline that counts as
         *  the data plane proving itself — more than any
         *  plausible DNS chatter, less than one TLS flight. */
        private const val COUNTER_VERIFY_THRESHOLD_BYTES = 1024L
        private const val STOP_GRACE_MS = 5_000L

        /** Protect failures in a row that end the session with
         *  SOCKET_PROTECT_FAILED (build 2030, defect C). */
        private const val MAX_PROTECT_FAILURES = 3

        /** NEED_CREDS re-runs with the held pair tolerated
         *  between CONNECTED events (build 2030, defect B). */
        private const val MAX_CREDS_RESUPPLY = 3

        @Volatile
        var running = false
            private set

        /**
         * Build 2125 (audit A25-25 / P-04 remainder): whether
         * the live session's TUN actually captured IPv6 (an
         * IPv6 address was applied and ::/0 routed). Set by
         * the TUN builder at establish, cleared when a new
         * session's builder state resets. Published in the
         * state map so the Dart side can journal/surface the
         * uncovered family — up to 2124 a v4-only OpenVPN
         * session leaked IPv6 silently, the last engine
         * family with no surfacing (Xray journals its note
         * since 2123, WireGuard since 2116).
         */
        @Volatile
        var ipv6Captured = false

        /** Build 2125 (audit A25-04): the kill-switch hold
         *  is in place — a connected session ended
         *  unexpectedly and its TUN is held as a blackhole
         *  until the user disconnects or a fresh start
         *  replaces it. */
        @Volatile
        var killSwitchHeld = false

        @Volatile
        var startedAtMs = 0L
            private set

        fun start(
            context: Context,
            profileId: String,
            name: String,
            config: String,
            credKey: String,
            username: String,
            password: String,
            needsCreds: Boolean,
            // Build 2125 (A25-04): the kill switch.
            killSwitch: Boolean = false,
        ) {
            val intent = Intent(context, OpenVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_PROFILE_ID, profileId)
                putExtra(EXTRA_NAME, name)
                putExtra(EXTRA_CONFIG, config)
                putExtra(EXTRA_CRED_KEY, credKey)
                putExtra(EXTRA_USER, username)
                putExtra(EXTRA_KILL_SWITCH, killSwitch)
                putExtra(EXTRA_PASS, password)
                putExtra(EXTRA_NEEDS_CREDS, needsCreds)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, OpenVpnService::class.java).apply { action = ACTION_STOP },
            )
        }
    }
}

/**
 * The per-server latency probe for .ovpn remotes. What it
 * measures is endpoint responsiveness BEFORE any tunnel exists,
 * and the method string says which: for TCP profiles, the TCP
 * handshake's round trip; for UDP profiles without tls-auth /
 * tls-crypt, one OpenVPN control-channel reset — the server
 * answers only if an OpenVPN endpoint is really there — and
 * its round trip. Profiles whose control channel is
 * authenticated (tls-auth/tls-crypt) cannot be probed this way:
 * the result says UNSUPPORTED instead of inventing a number.
 */
object OpenVpnProbe {
    private const val REPLY_MS = 3500

    /** {ms (Long, -1 on failure), method, error?} */
    fun measure(host: String, port: Int, proto: String, authenticatedControl: Boolean): Map<String, Any?> {
        val tcp = proto.lowercase().startsWith("tcp")
        if (tcp) {
            return try {
                val address = InetAddress.getAllByName(host).firstOrNull()
                    ?: return result(-1, "TCP_CONNECT", "NO_ADDRESS")
                val start = System.nanoTime()
                Socket().use { it.connect(InetSocketAddress(address, port), REPLY_MS) }
                result(elapsedMs(start), "TCP_CONNECT", null)
            } catch (_: Exception) {
                result(-1, "TCP_CONNECT", "NO_RESPONSE")
            }
        }
        if (authenticatedControl) {
            return result(-1, "OPENVPN_UDP_RESET", "UNSUPPORTED_CONTROL_AUTH")
        }
        return try {
            val address = InetAddress.getAllByName(host)
                .firstOrNull { it is java.net.Inet4Address }
                ?: InetAddress.getAllByName(host).firstOrNull()
                ?: return result(-1, "OPENVPN_UDP_RESET", "NO_ADDRESS")
            val session = ByteArray(8).also { SecureRandom().nextBytes(it) }
            // P_CONTROL_HARD_RESET_CLIENT_V2 (opcode 7): the
            // opcode/key byte, our session id, an empty ack
            // array and packet id 0.
            val request = byteArrayOf(0x38) + session + byteArrayOf(0, 0, 0, 0, 0)
            DatagramSocket().use { socket ->
                socket.soTimeout = REPLY_MS
                val start = System.nanoTime()
                socket.send(DatagramPacket(request, request.size, address, port))
                val buffer = ByteArray(2048)
                val reply = DatagramPacket(buffer, buffer.size)
                socket.receive(reply)
                val data = reply.data.copyOfRange(0, reply.length)
                if (acceptsReset(data, session)) {
                    result(elapsedMs(start), "OPENVPN_UDP_RESET", null)
                } else {
                    result(-1, "OPENVPN_UDP_RESET", "NO_RESPONSE")
                }
            }
        } catch (_: Exception) {
            result(-1, "OPENVPN_UDP_RESET", "NO_RESPONSE")
        }
    }

    /**
     * A genuine server reset (P_CONTROL_HARD_RESET_SERVER_V2,
     * first byte 0x40): it acknowledges our packet 0 and carries
     * our session id as its remote session.
     */
    private fun acceptsReset(packet: ByteArray, session: ByteArray): Boolean {
        if (packet.size < 26 || packet[0].toInt() and 0xff != 0x40) return false
        val count = packet[9].toInt() and 0xff
        if (count !in 1..32 || packet.size < 10 + count * 4 + 12) return false
        val ackedZero = (0 until count).any { i ->
            (0 until 4).all { packet[10 + i * 4 + it] == 0.toByte() }
        }
        if (!ackedZero) return false
        val offset = 10 + count * 4
        return packet.copyOfRange(offset, offset + 8).contentEquals(session)
    }

    private fun elapsedMs(startNanos: Long): Long =
        ((System.nanoTime() - startNanos) / 1_000_000).coerceAtLeast(1)

    private fun result(ms: Long, method: String, error: String?): Map<String, Any?> =
        mapOf("ms" to ms, "method" to method, "error" to error)
}
