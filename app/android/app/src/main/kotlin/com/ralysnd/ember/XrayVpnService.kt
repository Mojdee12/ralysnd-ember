package com.ralysnd.ember

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.Network
import android.net.TrafficStats
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The V2Ray (Xray) engine's VPN service. Unlike the Mozilla engine (a
 * gomobile AAR whose core runs in this process), the Xray core runs as a
 * plain executable subprocess (jniLibs/libxray.so) with a SOCKS5 inbound,
 * and a second helper subprocess (jniLibs/libtunlink.so, the tun2socks
 * engine) bridges this service's TUN device to that SOCKS5 inbound.
 *
 * The TUN fd cannot be handed to a child by number on Android (children
 * of ProcessBuilder do not inherit arbitrary fds), so the helper connects
 * to a unix socket this service listens on and receives the fd over it
 * (SCM_RIGHTS through LocalSocket.setFileDescriptorsForSend).
 *
 * The whole app is disallowed from its own VPN, so the subprocesses'
 * outbound sockets (same UID) reach the internet directly instead of
 * looping into the TUN — the same trick the Mozilla service uses.
 * Per-app routing reuses the Mozilla service's stored choice
 * (CoreService's prefs), so one app-routing setting governs both engines.
 */
class XrayVpnService : VpnService() {

    private val worker = Executors.newSingleThreadExecutor()
    private val stopping = AtomicBoolean(false)

    /**
     * The core lifecycle lock (build 2054, audit F-H1): ONE
     * monitor over restartCore + rotateCore + stopProcesses.
     * Before it, restartCore was callable concurrently from
     * the watchdog worker and the rotate thread, and the
     * `rotating` flag suppressed checks but not an in-flight
     * restart — two libxray.so could spawn on 10808, one
     * dying bind-in-use while xrayProcess pointed at the
     * dead one. Java monitors are re-entrant, so restartCore
     * failing into fail() -> stopProcesses() on the same
     * thread does not deadlock.
     *
     * Stop paths run on a daemon thread (ACTION_STOP /
     * onRevoke below), never the main thread: a restart can
     * hold this lock for ~20 s (kill + port-free + spawn +
     * port wait), and blocking the main thread that long is
     * an ANR. onDestroy keeps the direct call — the service
     * is going away anyway.
     */
    private val coreLock = Any()

    @Volatile
    private var xrayProcess: Process? = null
    @Volatile
    private var tunProcess: Process? = null
    private var tunPfd: ParcelFileDescriptor? = null
    private var serverSocket: LocalServerSocket? = null

    // Kept so the watchdog can respawn a wedged core in place.
    private var sessionConfig = ""

    // Kill switch (build 2063, feature queue #3): when true,
    // an unexpected session death holds the TUN as a blackhole
    // instead of tearing it down — traffic blocks until the
    // reconnect lands or the user disconnects. Set per session
    // from the start intent; a manual stop always releases it.
    private var killSwitch = false
    private var sessionPort = 10808

    // Chain session state (build 2029A): when the session is
    // chained, the Psiphon underlay was started proxy-only by
    // the Dart side before this service; this service
    // SUPERVISES it (ChainSupervisor, in watchProcesses) and
    // reaps it when the session ends — an unreaped underlay
    // would leave its SOCKS port bound and its core running
    // with nothing above it.
    private var sessionUnderlay = "none"
    private var sessionDns = "1.1.1.1"
    // The session's tunnel MTU (build 2038, queue 2f), kept so a
    // respawned underlay restarts with the same value.
    private var sessionMtu = MTU
    private var sessionUnderlayRegion = ""
    private var sessionUnderlayUpstream = ""
    private var sessionUnderlayProtocols: List<String> = emptyList()
    private var chainFails = 0
    private var chainRespawns = 0
    private var chainGraceUntilMs = 0L

    // DNSTT + wstunnel session state (build 2072): the DNSTT
    // underlay's command line, kept so the ChainSupervisor can
    // respawn the client exactly as the session started it; and
    // the WireGuard-over-WebSocket flag + the wstunnel client's
    // command line, supervised and reaped the same way (a WG
    // session whose forwarder died is a blackhole, so its
    // supervision is fail-closed like the standalone engines).
    private var sessionDnsttArgs: List<String> = emptyList()
    private var sessionWgWstunnel = false
    private var sessionWstunnelArgs: List<String> = emptyList()
    private var wstunnelFails = 0
    private var wstunnelRespawns = 0

    // EmberWarp session state (build 2030): the warp core's
    // command line, kept so the ChainSupervisor can respawn the
    // underlay exactly as the session started it; and the
    // standalone flag — a WARP session runs NO Xray process:
    // the tunlink bridge feeds the warp core's SOCKS directly.
    private var sessionWarpArgs: List<String> = emptyList()
    private var sessionWarpMode = false

    // The generic SOCKS-engine tunnel (build 2032): TUN against an
    // AetherCore slot's local SOCKS (WARP / MASQUE pages).
    private var sessionSocksMode = false
    private var sessionSocksEngine = ""
    private var socksFails = 0
    private var warpFails = 0

    // The AmneziaWG tunnel (build 2040, queue 2h): NO Xray
    // process and NO tunlink bridge — the userspace device in
    // libwg-go.so reads/writes the TUN fd directly. The fd
    // belongs to the device once handed over (see
    // startAwgTunnel), so tunPfd stays null for this mode and
    // stopProcesses turns the device off instead of closing it.
    // The mode flag + device handle live in the companion (like
    // `running`) so MainActivity's xrayState can report them.
    private var awgFails = 0

    /** True while a shape rotation respawns the core: the
     * watch loop must not read the mid-rotation process state
     * as a death. */
    @Volatile
    private var rotating = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Build 2068: the start net, same shape as
        // PsiphonVpnService's — the whole command body runs in
        // onStartCommandGuarded below; a Throwable escaping it
        // (an Error in an extras read, a startInForeground
        // refusal, a worker hand-off) is recorded in xray.log
        // and crash.log and the service stops gracefully,
        // instead of an uncaught main-thread death the owner
        // can only report as "the app crashed".
        return try {
            onStartCommandGuarded(intent, flags, startId)
        } catch (e: Throwable) {
            CrashLog.appendToFile(
                File(workDir(this), "xray.log"),
                "XrayVpnService.onStartCommand",
                e,
            )
            CrashLog.append(this, "XrayVpnService.onStartCommand", e)
            stopSelf()
            START_NOT_STICKY
        }
    }

    private fun onStartCommandGuarded(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                // Off the main thread: stopProcesses takes
                // coreLock, which a restart can hold for ~20 s.
                Thread { stopTunnel() }.apply {
                    isDaemon = true
                    name = "xray-stop"
                }.start()
                return START_NOT_STICKY
            }
            ACTION_ROTATE -> {
                val config = intent.getStringExtra(EXTRA_CONFIG) ?: ""
                if (config.isNotEmpty()) {
                    // NOT on `worker`: the watch loop occupies it
                    // for the session's whole life.
                    Thread {
                        // Build 2070 (review §5.1): the rotate
                        // thread's net. rotateCore records its own
                        // failures; an Error escaping it (or thrown
                        // before its internal try) used to die
                        // uncaught on this thread and take the
                        // process with it. Record-only: a failed
                        // rotation leaves the running core as it
                        // is, and the watch loop keeps supervising
                        // the session.
                        try {
                            rotateCore(config)
                        } catch (e: Throwable) {
                            CrashLog.append(
                                this,
                                "XrayVpnService.rotateCore",
                                e,
                            )
                        }
                    }.apply {
                        isDaemon = true
                        name = "xray-rotate"
                    }.start()
                }
                return START_STICKY
            }
            ACTION_START -> {
                // Build 2068 breadcrumb (control trail).
                CrashLog.breadcrumb(this, "xray:onStartCommand-start")
                val config = intent.getStringExtra(EXTRA_CONFIG) ?: ""
                val name = intent.getStringExtra(EXTRA_NAME) ?: ""
                val socksPort = intent.getIntExtra(EXTRA_SOCKS_PORT, 10808)
                val dns = intent.getStringExtra(EXTRA_DNS) ?: "1.1.1.1"
                val ipv6 = intent.getBooleanExtra(EXTRA_IPV6, true)
                val mtu = clampMtu(intent.getIntExtra(EXTRA_MTU, MTU))
                val underlay = intent.getStringExtra(EXTRA_UNDERLAY) ?: "none"
                val underlayRegion = intent.getStringExtra(EXTRA_UNDERLAY_REGION) ?: ""
                val underlayUpstream = intent.getStringExtra(EXTRA_UNDERLAY_UPSTREAM) ?: ""
                val underlayProtocols =
                    intent.getStringArrayListExtra(EXTRA_UNDERLAY_PROTOCOLS) ?: arrayListOf()
                val warpArgs =
                    intent.getStringArrayListExtra(EXTRA_WARP_ARGS) ?: arrayListOf()
                // DNSTT + wstunnel (build 2072).
                val dnsttArgs =
                    intent.getStringArrayListExtra(EXTRA_DNSTT_ARGS) ?: arrayListOf()
                val wgWstunnel = intent.getBooleanExtra(EXTRA_WG_WSTUNNEL, false)
                val wstunnelArgs =
                    intent.getStringArrayListExtra(EXTRA_WSTUNNEL_ARGS) ?: arrayListOf()
                // LAN sharing (build 2062): the SOCKS
                // credentials for the tun2socks bridge.
                val socksUser = intent.getStringExtra(EXTRA_SOCKS_USER) ?: ""
                val socksPass = intent.getStringExtra(EXTRA_SOCKS_PASS) ?: ""
                // Kill switch (build 2063, feature queue #3).
                killSwitch = intent.getBooleanExtra(EXTRA_KILL_SWITCH, false)
                if (config.isEmpty()) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                startInForeground(name)
                worker.execute {
                    // Build 2070 (review §5.1): the async start
                    // net — see startFailed.
                    try {
                        startTunnel(
                            config, name, socksPort, dns, ipv6, mtu,
                            underlay, underlayRegion, underlayUpstream,
                            underlayProtocols, warpArgs,
                            socksUser, socksPass,
                            dnsttArgs, wgWstunnel, wstunnelArgs,
                        )
                    } catch (e: Throwable) {
                        startFailed("XrayVpnService.startTunnel", e)
                    }
                }
                return START_STICKY
            }
            ACTION_START_WARP -> {
                // Standalone WARP (build 2030): the EmberWarp
                // core was started and health-checked by the
                // Dart side first (like a chain underlay); this
                // service brings the TUN up against its SOCKS
                // port and supervises + reaps it.
                val name = intent.getStringExtra(EXTRA_NAME) ?: ""
                val dns = intent.getStringExtra(EXTRA_DNS) ?: "1.1.1.1"
                val ipv6 = intent.getBooleanExtra(EXTRA_IPV6, true)
                val mtu = clampMtu(intent.getIntExtra(EXTRA_MTU, MTU))
                val warpArgs =
                    intent.getStringArrayListExtra(EXTRA_WARP_ARGS) ?: arrayListOf()
                // Kill switch (build 2063, feature queue #3).
                killSwitch = intent.getBooleanExtra(EXTRA_KILL_SWITCH, false)
                startInForeground(name)
                worker.execute {
                    // Build 2070 (review §5.1): the async start
                    // net — see startFailed.
                    try {
                        startWarpTunnel(name, dns, ipv6, mtu, warpArgs)
                    } catch (e: Throwable) {
                        startFailed("XrayVpnService.startWarpTunnel", e)
                    }
                }
                return START_STICKY
            }
            ACTION_START_SOCKS -> {
                // Aether engines (build 2032): the AetherCore
                // slot was started and stage-proven by the Dart
                // side; this service brings the TUN up against
                // its SOCKS port and supervises the slot.
                val name = intent.getStringExtra(EXTRA_NAME) ?: ""
                val dns = intent.getStringExtra(EXTRA_DNS) ?: "1.1.1.1"
                val ipv6 = intent.getBooleanExtra(EXTRA_IPV6, true)
                val mtu = clampMtu(intent.getIntExtra(EXTRA_MTU, MTU))
                val socksPort = intent.getIntExtra(EXTRA_SOCKS_PORT, 0)
                val engine = intent.getStringExtra(EXTRA_ENGINE) ?: ""
                // Kill switch (build 2063, feature queue #3).
                killSwitch = intent.getBooleanExtra(EXTRA_KILL_SWITCH, false)
                if (socksPort <= 0 || engine.isEmpty()) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                startInForeground(name)
                worker.execute {
                    // Build 2070 (review §5.1): the async start
                    // net — see startFailed.
                    try {
                        startSocksTunnel(name, dns, ipv6, mtu, socksPort, engine)
                    } catch (e: Throwable) {
                        startFailed("XrayVpnService.startSocksTunnel", e)
                    }
                }
                return START_STICKY
            }
            ACTION_START_AWG -> {
                // AmneziaWG (build 2040, queue 2h): the Dart
                // side built the UAPI settings string from the
                // profile (keys + the Jc/Jmin/Jmax/S1/S2/H1–H4
                // the config carried); this service brings the
                // TUN up and hands its fd to the userspace
                // device in libwg-go.so — no Xray, no bridge.
                val name = intent.getStringExtra(EXTRA_NAME) ?: ""
                val settings = intent.getStringExtra(EXTRA_AWG_SETTINGS) ?: ""
                val addresses = intent.getStringExtra(EXTRA_AWG_ADDRESSES) ?: ""
                // Kill switch (build 2063): AmneziaWG owns its
                // TUN fd through the userspace device, so there
                // is no fd to hold — an AWG session never holds.
                killSwitch = false
                val dns = intent.getStringExtra(EXTRA_DNS) ?: "1.1.1.1"
                val ipv6 = intent.getBooleanExtra(EXTRA_IPV6, true)
                val mtu = clampMtu(intent.getIntExtra(EXTRA_MTU, MTU))
                if (settings.isEmpty()) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                startInForeground(name)
                worker.execute {
                    // Build 2070 (review §5.1): the async start
                    // net — see startFailed.
                    try {
                        startAwgTunnel(name, settings, addresses, dns, ipv6, mtu)
                    } catch (e: Throwable) {
                        startFailed("XrayVpnService.startAwgTunnel", e)
                    }
                }
                return START_STICKY
            }
            else -> {
                // Restarted by the system without an intent: there is no
                // config to run, so do not linger as a dead VPN.
                stopSelf()
                return START_NOT_STICKY
            }
        }
    }

    override fun onRevoke() {
        // Same reason as ACTION_STOP: off the main thread.
        Thread { stopTunnel() }.apply {
            isDaemon = true
            name = "xray-stop"
        }.start()
    }

    override fun onDestroy() {
        stopUnderlay()
        stopProcesses()
        // Kill switch (build 2063): the service itself is dying
        // (Android killed it) — the TUN dies with it, so no
        // hold survives this; the flag clears with the service.
        blackholeHeld = false
        // Build 2060 (grouped sweep): the single-thread worker
        // executor outlived the service — shut it down so its
        // thread (and anything queued on it) does not linger
        // after the service is gone. Queued tasks still run to
        // completion; nothing new can be submitted afterwards.
        worker.shutdown()
        super.onDestroy()
    }

    private fun startTunnel(
        configJson: String,
        name: String,
        socksPort: Int,
        dns: String,
        ipv6: Boolean,
        mtu: Int,
        underlay: String = "none",
        underlayRegion: String = "",
        underlayUpstream: String = "",
        underlayProtocols: List<String> = emptyList(),
        warpArgs: List<String> = emptyList(),
        // LAN sharing (build 2062): the SOCKS credentials for
        // the tun2socks bridge ('' = noauth).
        socksUser: String = "",
        socksPass: String = "",
        // DNSTT underlay + WireGuard-over-WebSocket
        // (build 2072).
        dnsttArgs: List<String> = emptyList(),
        wgWstunnel: Boolean = false,
        wstunnelArgs: List<String> = emptyList(),
    ) {
        // Build 2068 breadcrumb (control trail): the worker
        // reached the tunnel builder.
        CrashLog.breadcrumb(this, "xray:startTunnel-entered")
        stopping.set(false)
        sessionConfig = configJson
        sessionPort = socksPort
        sessionDns = dns
        sessionMtu = mtu
        sessionUnderlay = underlay
        sessionUnderlayRegion = underlayRegion
        sessionUnderlayUpstream = underlayUpstream
        sessionUnderlayProtocols = underlayProtocols
        sessionWarpArgs = warpArgs
        sessionDnsttArgs = dnsttArgs
        sessionWgWstunnel = wgWstunnel
        sessionWstunnelArgs = wstunnelArgs
        wstunnelFails = 0
        wstunnelRespawns = 0
        sessionWarpMode = false
        sessionSocksMode = false
        chainFails = 0
        chainRespawns = 0
        chainGraceUntilMs = System.currentTimeMillis() + 45_000
        chainUnderlay = underlay != "none"
        chainProblem = ""
        coreRestarts = 0
        coreProblem = ""
        try {
            val dir = workDir(this)
            dir.mkdirs()
            // Build 2054 (audit F-M6): tmp + fsync + rename,
            // so a kill mid-write never leaves a torn config
            // for the core to choke on.
            val configFile = File(dir, "config.json")
            AtomicFile.writeText(configFile, configJson)

            // A core leaked by an earlier service instance would hold
            // the SOCKS port and answer in the new core's place.
            sweepOrphans()
            // Build 2049: the sweep's kills are fire-and-forget
            // signals — wait (bounded) until the port is actually
            // free, so the checks below can only be answered by
            // the core spawned here. Build 2054 (audit Q-1): a
            // timeout FAILS the start instead of spawning blind
            // on the busy port — the old blind respawn let a
            // stale listener bless the new session.
            if (!ProcessKill.waitPortFree(socksPort, 3000)) {
                Log.e(TAG, "SOCKS port $socksPort still busy 3 s after the orphan sweep; not starting on it")
                fail()
                return
            }

            // 1. The Xray core subprocess.
            val xrayLog = File(dir, "xray.log")
            rotateLogIfLarge(xrayLog)
            xrayProcess = ProcessBuilder(
                libPath("libxray.so"), "run", "-c", configFile.absolutePath,
            )
                .directory(dir)
                .redirectErrorStream(true)
                .redirectOutput(ProcessBuilder.Redirect.appendTo(xrayLog))
                .start()
            if (!waitForPort(socksPort, 15000)) {
                Log.e(TAG, "xray did not open its SOCKS port")
                fail()
                return
            }
            // The port answering is not enough: it must be OUR core
            // answering (a stale listener satisfies waitForPort too).
            val spawned = xrayProcess
            if (spawned == null || !spawned.isAlive || !probeSocks(socksPort)) {
                Log.e(TAG, "xray SOCKS port answered but the spawned core is not serving it")
                fail()
                return
            }

            // 2. The VPN interface.
            if (prepare(this) != null) {
                Log.w(TAG, "the VPN has no permission")
                fail()
                return
            }
            val builder = Builder()
                .setSession(getString(R.string.app_name))
                .setMtu(mtu)
                .addAddress("10.10.14.1", 30)
                .addRoute("0.0.0.0", 0)
                .addDnsServer(dns)
            if (ipv6) {
                builder.addAddress("fdfe:dcba:9876::1", 126)
                builder.addRoute("::", 0)
            }
            applyApps(builder)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
            // Kill switch (build 2063): a held blackhole's fd
            // is closed only AFTER the new TUN is up — closing
            // it first would open a direct-traffic window.
            val heldPfd = if (blackholeHeld) tunPfd else null
            val pfd = builder.establish()
            if (pfd == null) {
                Log.e(TAG, "establish() returned null")
                fail()
                return
            }
            tunPfd = pfd
            if (heldPfd != null) {
                blackholeHeld = false
                try {
                    heldPfd.close()
                } catch (e: Exception) {
                    // Already closed.
                }
            }

            // 3. The fd listener the helper connects to — it receives
            //    the same socket string below (see createFdListener
            //    for the namespace both sides agree on).
            val socketFile = File(dir, "tun.sock")
            socketFile.delete()
            val server = createFdListener(socketFile)
            serverSocket = server

            // 4. The tun2socks helper subprocess.
            // LAN sharing (build 2062): with credentials the bridge
            // authenticates to the password-protected SOCKS inbound
            // — userinfo is percent-encoded (URLEncoder's '+' becomes
            // %20) so any password survives the URL. Without them,
            // today's plain URL.
            val proxyUrl = if (socksUser.isNotEmpty() && socksPass.isNotEmpty()) {
                val encUser = java.net.URLEncoder.encode(socksUser, "UTF-8")
                    .replace("+", "%20")
                val encPass = java.net.URLEncoder.encode(socksPass, "UTF-8")
                    .replace("+", "%20")
                "socks5://$encUser:$encPass@127.0.0.1:$socksPort"
            } else {
                "socks5://127.0.0.1:$socksPort"
            }
            val tunLog = File(dir, "tunlink.log")
            rotateLogPerSession(tunLog)
            tunProcess = ProcessBuilder(
                libPath("libtunlink.so"),
                "-socket", socketFile.absolutePath,
                "-proxy", proxyUrl,
                "-mtu", mtu.toString(),
                "-loglevel", "warn",
            )
                .directory(dir)
                .redirectErrorStream(true)
                .redirectOutput(ProcessBuilder.Redirect.appendTo(tunLog))
                .start()

            // 5. Hand the TUN fd over (blocking accept with a timeout set
            //    by the socket's soTimeout through a watcher thread).
            val accepted = acceptWithTimeout(server, 15000)
            if (accepted == null) {
                Log.e(TAG, "the helper did not connect for the TUN fd")
                fail()
                return
            }
            accepted.use { socket ->
                socket.setFileDescriptorsForSend(arrayOf(pfd.fileDescriptor))
                socket.outputStream.write(1)
                socket.outputStream.flush()
            }
            server.close()
            serverSocket = null

            running = true
            profileName = name
            startedAtMs = System.currentTimeMillis()
            val uid = android.os.Process.myUid()
            baseTx = TrafficStats.getUidTxBytes(uid)
            baseRx = TrafficStats.getUidRxBytes(uid)
            updateNotification(name)
            watchProcesses()
        } catch (e: Throwable) {
            // Build 2070 (review §5.1): Throwable + crash.log
            // (was Exception + logcat) — an Error from a native
            // call inside the start is recorded, then the same
            // fail() the Exception path always ran.
            CrashLog.append(this, "XrayVpnService.startTunnel", e)
            Log.e(TAG, "the V2Ray tunnel did not start", e)
            fail()
        }
    }

    /**
     * The standalone WARP tunnel (build 2030): startTunnel's
     * TUN half with NO Xray process — the tunlink bridge dials
     * the EmberWarp core's SOCKS port directly (dossier Q2:
     * standalone dials direct; the service's UID exclusion is
     * what keeps the core's own egress out of the tunnel). The
     * core was started and readiness-proven by the Dart side
     * before this intent; the watch loop supervises it and
     * every stop path reaps it (stopUnderlay).
     */
    private fun startWarpTunnel(
        name: String,
        dns: String,
        ipv6: Boolean,
        mtu: Int,
        warpArgs: List<String>,
    ) {
        stopping.set(false)
        xrayProcess = null // No Xray in this mode; watch loop keys off it.
        sessionConfig = ""
        sessionPort = EmberWarpCore.SOCKS_PORT
        sessionDns = dns
        sessionMtu = mtu
        sessionUnderlay = "none"
        sessionWarpArgs = warpArgs
        sessionDnsttArgs = emptyList()
        sessionWgWstunnel = false
        sessionWstunnelArgs = emptyList()
        sessionWarpMode = true
        sessionSocksMode = false
        warpFails = 0
        chainUnderlay = false
        chainProblem = ""
        coreRestarts = 0
        coreProblem = ""
        try {
            val dir = workDir(this)
            dir.mkdirs()
            sweepOrphans()
            if (!EmberWarpCore.running || !EmberWarpCore.ready) {
                Log.e(TAG, "the EmberWarp core is not ready for the tunnel")
                fail()
                return
            }
            if (prepare(this) != null) {
                Log.w(TAG, "the VPN has no permission")
                fail()
                return
            }
            val builder = Builder()
                .setSession(getString(R.string.app_name))
                .setMtu(mtu)
                .addAddress("10.10.14.1", 30)
                .addRoute("0.0.0.0", 0)
                .addDnsServer(dns)
            if (ipv6) {
                builder.addAddress("fdfe:dcba:9876::1", 126)
                builder.addRoute("::", 0)
            }
            applyApps(builder)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }
            // Kill switch (build 2063): a held blackhole's fd
            // is closed only AFTER the new TUN is up — closing
            // it first would open a direct-traffic window.
            val heldPfd = if (blackholeHeld) tunPfd else null
            val pfd = builder.establish()
            if (pfd == null) {
                Log.e(TAG, "establish() returned null (warp)")
                fail()
                return
            }
            tunPfd = pfd
            if (heldPfd != null) {
                blackholeHeld = false
                try {
                    heldPfd.close()
                } catch (e: Exception) {
                    // Already closed.
                }
            }
            val socketFile = File(dir, "tun.sock")
            socketFile.delete()
            val server = createFdListener(socketFile)
            serverSocket = server
            val tunLog = File(dir, "tunlink.log")
            rotateLogPerSession(tunLog)
            tunProcess = ProcessBuilder(
                libPath("libtunlink.so"),
                "-socket", socketFile.absolutePath,
                "-proxy", "socks5://127.0.0.1:${EmberWarpCore.SOCKS_PORT}",
                "-mtu", mtu.toString(),
                "-loglevel", "warn",
            )
                .directory(dir)
                .redirectErrorStream(true)
                .redirectOutput(ProcessBuilder.Redirect.appendTo(tunLog))
                .start()
            val accepted = acceptWithTimeout(server, 15000)
            if (accepted == null) {
                Log.e(TAG, "the helper did not connect for the TUN fd (warp)")
                fail()
                return
            }
            accepted.use { socket ->
                socket.setFileDescriptorsForSend(arrayOf(pfd.fileDescriptor))
                socket.outputStream.write(1)
                socket.outputStream.flush()
            }
            server.close()
            serverSocket = null
            running = true
            profileName = name
            startedAtMs = System.currentTimeMillis()
            val uid = android.os.Process.myUid()
            baseTx = TrafficStats.getUidTxBytes(uid)
            baseRx = TrafficStats.getUidRxBytes(uid)
            updateNotification(name)
            watchProcesses()
        } catch (e: Throwable) {
            // Build 2070 (review §5.1): as in startTunnel above.
            CrashLog.append(this, "XrayVpnService.startWarpTunnel", e)
            Log.e(TAG, "the WARP tunnel did not start", e)
            fail()
        }
    }

    /**
     * The Aether-engine tunnel (build 2032): startWarpTunnel's TUN
     * half generalized to any local SOCKS port owned by an
     * [AetherCore] slot. The slot was started and stage-proven
     * (stage CONNECTED) by the Dart side; here a real SOCKS
     * greeting must also answer before the TUN comes up. The
     * watch loop supervises the slot (AetherCore state + greeting)
     * and every stop path reaps it (stopUnderlay) — the binary
     * self-reconnects inside a session, but a dead slot must
     * never leave a blackholing "Connected".
     */
    private fun startSocksTunnel(
        name: String,
        dns: String,
        ipv6: Boolean,
        mtu: Int,
        socksPort: Int,
        engine: String,
    ) {
        stopping.set(false)
        xrayProcess = null // No Xray in this mode; watch loop keys off it.
        sessionConfig = ""
        sessionPort = socksPort
        sessionDns = dns
        sessionMtu = mtu
        sessionUnderlay = "none"
        sessionDnsttArgs = emptyList()
        sessionWgWstunnel = false
        sessionWstunnelArgs = emptyList()
        sessionWarpMode = false
        sessionSocksMode = true
        sessionSocksEngine = engine
        socksFails = 0
        chainUnderlay = false
        chainProblem = ""
        coreRestarts = 0
        coreProblem = ""
        try {
            val dir = workDir(this)
            dir.mkdirs()
            sweepOrphans()
            val slot = AetherCore.slot(engine)
            if (!slot.running ||
                slot.stage != AetherStage.CONNECTED ||
                !probeSocks(socksPort)
            ) {
                Log.e(TAG, "the $engine engine is not ready for the tunnel")
                fail()
                return
            }
            if (prepare(this) != null) {
                Log.w(TAG, "the VPN has no permission")
                fail()
                return
            }
            val builder = Builder()
                .setSession(getString(R.string.app_name))
                .setMtu(mtu)
                .addAddress("10.10.14.1", 30)
                .addRoute("0.0.0.0", 0)
                .addDnsServer(dns)
            if (ipv6) {
                builder.addAddress("fdfe:dcba:9876::1", 126)
                builder.addRoute("::", 0)
            }
            applyApps(builder)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }
            // Kill switch (build 2063): a held blackhole's fd
            // is closed only AFTER the new TUN is up — closing
            // it first would open a direct-traffic window.
            val heldPfd = if (blackholeHeld) tunPfd else null
            val pfd = builder.establish()
            if (pfd == null) {
                Log.e(TAG, "establish() returned null (socks)")
                fail()
                return
            }
            tunPfd = pfd
            if (heldPfd != null) {
                blackholeHeld = false
                try {
                    heldPfd.close()
                } catch (e: Exception) {
                    // Already closed.
                }
            }
            val socketFile = File(dir, "tun.sock")
            socketFile.delete()
            val server = createFdListener(socketFile)
            serverSocket = server
            val tunLog = File(dir, "tunlink.log")
            rotateLogPerSession(tunLog)
            tunProcess = ProcessBuilder(
                libPath("libtunlink.so"),
                "-socket", socketFile.absolutePath,
                "-proxy", "socks5://127.0.0.1:$socksPort",
                "-mtu", mtu.toString(),
                "-loglevel", "warn",
            )
                .directory(dir)
                .redirectErrorStream(true)
                .redirectOutput(ProcessBuilder.Redirect.appendTo(tunLog))
                .start()
            val accepted = acceptWithTimeout(server, 15000)
            if (accepted == null) {
                Log.e(TAG, "the helper did not connect for the TUN fd (socks)")
                fail()
                return
            }
            accepted.use { socket ->
                socket.setFileDescriptorsForSend(arrayOf(pfd.fileDescriptor))
                socket.outputStream.write(1)
                socket.outputStream.flush()
            }
            server.close()
            serverSocket = null
            running = true
            profileName = name
            startedAtMs = System.currentTimeMillis()
            val uid = android.os.Process.myUid()
            baseTx = TrafficStats.getUidTxBytes(uid)
            baseRx = TrafficStats.getUidRxBytes(uid)
            updateNotification(name)
            watchProcesses()
        } catch (e: Throwable) {
            // Build 2070 (review §5.1): as in startTunnel above.
            CrashLog.append(this, "XrayVpnService.startSocksTunnel", e)
            Log.e(TAG, "the SOCKS-engine tunnel did not start", e)
            fail()
        }
    }

    /**
     * The AmneziaWG tunnel (build 2040, queue 2h): the TUN
     * interface goes to the userspace device in libwg-go.so,
     * which owns the fd from here on — there is no Xray core
     * and no tunlink bridge, so the usual SOCKS-port readiness
     * does not apply. Proof that the tunnel carries traffic is
     * the device's handshake (the Dart side polls it through
     * xrayState's awgConfig dump): a handshake only completes
     * when the peer answers with the right keys AND the right
     * obfuscation values.
     *
     * The tunnel addresses come from the profile ([addresses],
     * "ip/prefix" comma-separated, as the .conf carried them);
     * when the profile has none, the fixed Xray-path addresses
     * are used — the device only moves packets, the kernel
     * only needs an address on the interface.
     */
    /** The AWG network-change callback (build 2065, item 8),
     *  registered only while an AmneziaWG session runs. */
    private var awgNetCallback: ConnectivityManager.NetworkCallback? = null

    /** UDP socket recovery for the AWG path: when the default
     *  network changes under a running AmneziaWG session (Wi-Fi
     *  to mobile, a new gateway), wg-go's bound sockets go stale
     *  and handshakes silently die. Re-applying the session's own
     *  UAPI config through AwgBackend.setConfig makes the device
     *  rebind and re-handshake on the new network — the recovery
     *  hook the bundled engine exposes (AwgBackend.setConfig was
     *  wired but never called before this build). Best effort:
     *  a failure is logged, never fatal — the session's own
     *  handshake retries remain the fallback. */
    private fun registerAwgNetworkCallback() {
        if (awgNetCallback != null) return
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (!awgMode || awgHandle <= 0) return
                val text = awgSettingsText
                if (text.isEmpty()) return
                worker.execute {
                    if (!awgMode || awgHandle <= 0) return@execute
                    val rc = AwgBackend.setConfig(awgHandle, text)
                    // The rebound sockets are new fds: protect
                    // them again or they would loop into the
                    // tunnel.
                    val v4 = AwgBackend.getSocketV4(awgHandle)
                    val v6 = AwgBackend.getSocketV6(awgHandle)
                    if (v4 >= 0) protect(v4)
                    if (v6 >= 0) protect(v6)
                    Log.i(
                        TAG,
                        "AWG socket recovery: config re-applied " +
                            "on network change (rc=$rc)",
                    )
                }
            }
        }
        try {
            cm.registerDefaultNetworkCallback(callback)
            awgNetCallback = callback
        } catch (e: Exception) {
            Log.w(TAG, "AWG network callback not registered: $e")
        }
    }

    private fun unregisterAwgNetworkCallback() {
        val callback = awgNetCallback ?: return
        awgNetCallback = null
        try {
            getSystemService(ConnectivityManager::class.java)
                ?.unregisterNetworkCallback(callback)
        } catch (e: Exception) {
            // Already gone.
        }
    }

    private fun startAwgTunnel(
        name: String,
        settings: String,
        addresses: String,
        dns: String,
        ipv6: Boolean,
        mtu: Int,
    ) {
        stopping.set(false)
        xrayProcess = null // No Xray in this mode; watch loop keys off it.
        tunProcess = null // No tunlink bridge either: the device owns the fd.
        sessionConfig = ""
        sessionPort = 0
        sessionDns = dns
        sessionMtu = mtu
        sessionUnderlay = "none"
        sessionDnsttArgs = emptyList()
        sessionWgWstunnel = false
        sessionWstunnelArgs = emptyList()
        sessionWarpMode = false
        sessionSocksMode = false
        awgMode = true
        awgFails = 0
        chainUnderlay = false
        chainProblem = ""
        coreRestarts = 0
        coreProblem = ""
        var fd = -1
        try {
            val dir = workDir(this)
            dir.mkdirs()
            sweepOrphans()
            if (!AwgBackend.ensureLoaded()) {
                Log.e(TAG, "libwg-go.so is not available for the AWG tunnel")
                fail()
                return
            }
            if (prepare(this) != null) {
                Log.w(TAG, "the VPN has no permission")
                fail()
                return
            }
            val builder = Builder()
                .setSession(getString(R.string.app_name))
                .setMtu(mtu)
            // Build 2059 (audit §6 engine low): the ::/0 route is
            // only added when a v6 address was actually assigned —
            // a v4-only profile with IPv6 on used to get the route
            // with no v6 address (v6 blackhole, fail-closed).
            var added = 0
            var hasV6 = false
            for (entry in addresses.split(",")) {
                val parts = entry.trim().split("/")
                if (parts.size != 2) continue
                val ip = parts[0].trim()
                val prefix = parts[1].trim().toIntOrNull() ?: continue
                if (ip.isEmpty() || prefix < 0) continue
                try {
                    builder.addAddress(ip, prefix)
                    if (ip.contains(":")) hasV6 = true
                    added++
                } catch (e: IllegalArgumentException) {
                    // Not an address the builder accepts: skip it.
                }
            }
            if (added == 0) {
                builder.addAddress("10.10.14.1", 30)
                if (ipv6) {
                    builder.addAddress("fdfe:dcba:9876::1", 126)
                    hasV6 = true
                }
            }
            builder.addRoute("0.0.0.0", 0)
            builder.addDnsServer(dns)
            if (ipv6 && hasV6) builder.addRoute("::", 0)
            applyApps(builder)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }
            val pfd = builder.establish()
            if (pfd == null) {
                Log.e(TAG, "establish() returned null (awg)")
                fail()
                return
            }
            // Kill switch (build 2063): a held blackhole is
            // replaced by this establish — close its fd only
            // now that the new TUN is up, never before.
            if (blackholeHeld) {
                blackholeHeld = false
                try {
                    tunPfd?.close()
                } catch (e: Exception) {
                    // Already closed.
                }
                tunPfd = null
            }
            // The fd now belongs to the device: detach it so the
            // ParcelFileDescriptor must not close it, and keep
            // tunPfd null so stopProcesses does not either — the
            // device closes it in turnOff. On a failed start
            // the fd is closed here instead.
            fd = pfd.detachFd()
            tunPfd = null
            val handle = AwgBackend.turnOn(fd, settings)
            if (handle <= 0) {
                Log.e(TAG, "the AWG device did not start")
                try {
                    // The fd is a raw int here: adopt it into a
                    // ParcelFileDescriptor just to close it
                    // (Os.close takes a FileDescriptor, not an int).
                    ParcelFileDescriptor.adoptFd(fd).close()
                } catch (e: Exception) {
                    // Already closed.
                }
                fd = -1
                fail()
                return
            }
            fd = -1 // Owned by the device now.
            awgHandle = handle
            awgSettingsText = settings
            registerAwgNetworkCallback()
            // The device's own UDP sockets must not loop back
            // into the tunnel: protect them as soon as they
            // exist (they appear with the first handshake
            // initiation, so poll briefly). At most one
            // initiation is lost unprotected; WireGuard
            // retransmits it, and the 12 s proof deadline
            // tolerates that.
            val protectDeadline = System.currentTimeMillis() + 3000
            var protected = false
            while (System.currentTimeMillis() < protectDeadline) {
                val v4 = AwgBackend.getSocketV4(handle)
                val v6 = AwgBackend.getSocketV6(handle)
                if (v4 >= 0) {
                    protect(v4)
                    protected = true
                }
                if (v6 >= 0) {
                    protect(v6)
                    protected = true
                }
                if (protected) break
                Thread.sleep(50)
            }
            if (!protected) {
                Log.w(TAG, "no AWG socket appeared to protect")
            }
            running = true
            profileName = name
            startedAtMs = System.currentTimeMillis()
            val uid = android.os.Process.myUid()
            baseTx = TrafficStats.getUidTxBytes(uid)
            baseRx = TrafficStats.getUidRxBytes(uid)
            updateNotification(name)
            watchProcesses()
        } catch (e: Throwable) {
            // Build 2070 (review §5.1): as in startTunnel above —
            // the fd cleanup below now also runs for an Error
            // from the userspace-device calls, not only for
            // Exceptions.
            CrashLog.append(this, "XrayVpnService.startAwgTunnel", e)
            Log.e(TAG, "the AWG tunnel did not start", e)
            if (fd >= 0) {
                try {
                    ParcelFileDescriptor.adoptFd(fd).close()
                } catch (ignored: Exception) {
                }
                fd = -1
            }
            fail()
        }
    }

    /** Which apps use the VPN: the same stored choice as the Mozilla engine's. */
    private fun applyApps(builder: Builder) {
        fun each(packages: Set<String>, add: (String) -> Unit) {
            for (pkg in packages) {
                try {
                    add(pkg)
                } catch (e: PackageManager.NameNotFoundException) {
                    // Uninstalled since.
                }
            }
        }
        if (CoreService.appMode(this) == CoreService.MODE_INCLUDE) {
            var added = 0
            each(CoreService.appSet(this, CoreService.ONLY) - packageName) {
                builder.addAllowedApplication(it)
                added++
            }
            if (added > 0) return
        }
        builder.addDisallowedApplication(packageName)
        each(CoreService.appSet(this, CoreService.BYPASS) - packageName) {
            builder.addDisallowedApplication(it)
        }
    }

    /**
     * Ends the tunnel when either subprocess dies on its own, and
     * respawns the core when it stays alive but stops answering its
     * SOCKS port. A wedged listener is the silent killer: the process
     * list looks healthy while every new flow times out connecting
     * to 127.0.0.1 (build 2024 on-device, tunlink logged exactly
     * those timeouts while the UI showed connected).
     */
    private fun watchProcesses() {
        worker.execute {
            var probeFails = 0
            var tick = 0
            while (!stopping.get() && running) {
                // Build 2055 (audit B-H5): the loop ticks at 5 s,
                // not 1 s — every probe below is already a
                // modulo-5 check, so each now runs once per
                // tick instead of every fifth 1 s tick. The
                // three-failure budgets stay ~15 s, and a dead
                // process is noticed within 5 s. Nothing
                // visible moves: notifications already re-post
                // only on change.
                tick++
                val x = xrayProcess
                val t = tunProcess
                if (!rotating) {
                    if (x != null && !x.isAlive) {
                        Log.e(TAG, "xray exited (${x.exitValue()})")
                        onSessionDied("the V2Ray core exited (${x.exitValue()})")
                        return@execute
                    }
                    if (t != null && !t.isAlive) {
                        Log.e(TAG, "tunlink exited (${t.exitValue()})")
                        onSessionDied("the tunnel bridge exited (${t.exitValue()})")
                        return@execute
                    }
                    // A real greeting every tick (~5 s): process
                    // liveness alone does not prove the inbound.
                    if (x != null) {
                        if (probeSocks(sessionPort)) {
                            probeFails = 0
                        } else if (++probeFails >= 3) {
                            probeFails = 0
                            if (!restartCore()) return@execute
                        }
                    }
                    // The ChainSupervisor (build 2029A, gener-
                    // alized in 2030): every ~5 s the underlay
                    // must be alive, connected AND answering its
                    // SOCKS port — Psiphon by its service state,
                    // EmberWarp by its core state (running +
                    // data-plane ready). Three failed checks
                    // respawn it while tun0 stays open (flows
                    // stall, they do not reroute); a revival
                    // budget of 3 bounds the loop, after which
                    // the session is torn down cleanly rather
                    // than left "Connected" over a dead chain.
                    if (chainUnderlay &&
                        System.currentTimeMillis() > chainGraceUntilMs
                    ) {
                        val healthy = when (sessionUnderlay) {
                            "warp" -> EmberWarpCore.running &&
                                EmberWarpCore.ready &&
                                probeSocks(EmberWarpCore.SOCKS_PORT)
                            // DNSTT (build 2072): the client is
                            // a plain port forward, not a SOCKS
                            // server — the health proof is the
                            // process, its readiness flag, and
                            // its TCP listener accepting. The
                            // tunnel above it is proven by the
                            // Xray core's own traffic checks.
                            "dnstt" -> DnsttCore.running &&
                                DnsttCore.ready &&
                                probeTcp(DnsttCore.PORT)
                            // Build 2073: the Psiphon service runs
                            // in its own process — its state is the
                            // published snapshot, not the companion
                            // statics (which live in :psiphon). The
                            // SOCKS probe below stays the live proof.
                            else -> PsiphonVpnService.publishedRunning(this@XrayVpnService) &&
                                PsiphonVpnService.publishedConnected(this@XrayVpnService) &&
                                probeSocks(PsiphonConstants.SOCKS_PORT)
                        }
                        if (healthy) {
                            chainFails = 0
                        } else if (++chainFails >= 3) {
                            chainFails = 0
                            if (!respawnUnderlay()) return@execute
                        }
                    }
                    // wstunnel supervision (build 2072): a
                    // WireGuard session whose forwarder died is
                    // a blackhole — the WG outbound dials a dead
                    // loopback port — so a dead forwarder is
                    // respawned within a budget of 3, after
                    // which the session is torn down cleanly
                    // (fail-closed, same rule as the chain).
                    if (sessionWgWstunnel) {
                        val healthy = WstunnelCore.running &&
                            WstunnelCore.ready
                        if (healthy) {
                            wstunnelFails = 0
                        } else if (++wstunnelFails >= 3) {
                            wstunnelFails = 0
                            if (!respawnWstunnel()) return@execute
                        }
                    }
                    // Standalone WARP supervision (build 2030):
                    // there is no Xray above the core — if it
                    // dies, the tunnel is a blackhole, so the
                    // session ends (fail-closed) instead of
                    // showing Connected over nothing.
                    if (sessionWarpMode) {
                        val healthy = EmberWarpCore.running &&
                            EmberWarpCore.ready
                        if (healthy) {
                            warpFails = 0
                        } else if (++warpFails >= 3) {
                            coreProblem =
                                "the EmberWarp core stopped; the WARP " +
                                    "session was closed"
                            Log.e(TAG, "standalone warp core unhealthy")
                            onSessionDied(coreProblem)
                            return@execute
                        }
                    }
                    // Aether-engine supervision (build 2032): the
                    // slot must be running, CONNECTED and answering
                    // its SOCKS port; three failed checks close the
                    // session (fail-closed, same rule as WARP).
                    if (sessionSocksMode) {
                        val slot = AetherCore.slot(sessionSocksEngine)
                        val healthy = slot.running &&
                            slot.stage == AetherStage.CONNECTED &&
                            probeSocks(sessionPort)
                        if (healthy) {
                            socksFails = 0
                        } else if (++socksFails >= 3) {
                            coreProblem =
                                "the engine stopped answering; the " +
                                    "session was closed"
                            Log.e(TAG, "aether slot $sessionSocksEngine unhealthy")
                            onSessionDied(coreProblem)
                            return@execute
                        }
                    }
                    // AmneziaWG supervision (build 2040): there is
                    // no core process and no SOCKS port to probe —
                    // the device itself is the session. A dump
                    // that stops answering means the native device
                    // is gone (its process died with it); three
                    // failed checks close the session rather than
                    // showing Connected over nothing. A stale
                    // handshake alone does NOT close it: an idle
                    // WireGuard peer legitimately goes quiet, and
                    // the handshake age is the UI's signal, not a
                    // death sentence.
                    if (awgMode) {
                        if (AwgBackend.getConfig(awgHandle) != null) {
                            awgFails = 0
                        } else if (++awgFails >= 3) {
                            coreProblem =
                                "the AmneziaWG engine stopped; the " +
                                    "session was closed"
                            Log.e(TAG, "awg device unhealthy")
                            onSessionDied(coreProblem)
                            return@execute
                        }
                    }
                }
                try {
                    Thread.sleep(5000)
                } catch (e: InterruptedException) {
                    return@execute
                }
            }
        }
    }

    /**
     * Respawns the Psiphon underlay in place (build 2029A):
     * tun0 and the Xray core stay exactly as they are; only the
     * underlay core restarts, with the parameters the session
     * was chained with. Returns false when the revival budget
     * is spent — the session is then torn down (fail()) so the
     * UI never shows a blackholing "Connected".
     */
    private fun respawnUnderlay(): Boolean {
        val label = when (sessionUnderlay) {
            "warp" -> "Warp"
            "dnstt" -> "DNSTT"
            else -> "Psiphon"
        }
        if (chainRespawns >= 3) {
            chainProblem =
                "the $label underlay died and could not be revived — " +
                    "the chained session was stopped"
            Log.e(TAG, "chain underlay revival budget exhausted")
            stopUnderlay()
            fail()
            return false
        }
        chainRespawns++
        chainProblem =
            "the $label underlay stopped answering; restarted it " +
                "(try $chainRespawns of 3)"
        Log.w(TAG, "chain underlay unhealthy; respawning (try $chainRespawns)")
        if (sessionUnderlay == "warp") {
            // The warp core respawns with the session's exact
            // command line; its readiness completes async and
            // the grace window covers the re-scan.
            EmberWarpCore.restart(this, sessionWarpArgs, EmberWarpCore.SOCKS_PORT)
            chainGraceUntilMs = System.currentTimeMillis() + 90_000
            return true
        }
        if (sessionUnderlay == "dnstt") {
            // Build 2072: the DNSTT client respawns with the
            // session's exact command line; its listener is
            // back within moments and the tunnel session
            // re-forms on the next stream — the grace window
            // covers both.
            DnsttCore.restart(this, sessionDnsttArgs)
            chainGraceUntilMs = System.currentTimeMillis() + 30_000
            return true
        }
        try {
            PsiphonVpnService.stop(this)
        } catch (e: Exception) {
            // Already gone.
        }
        // Build 2054 (audit F-M5): stop() is an async service
        // intent — the old fixed 600 ms sleep was a guess, and
        // a busy main thread could leave two gomobile cores on
        // 11808. Wait, bounded (~4 s), on observable state:
        // the service reports not-running AND its SOCKS port
        // answers nothing. A stuck underlay fails the respawn
        // (the session is torn down loudly) instead of
        // starting a second core on the same port.
        if (!waitUnderlayStopped(4000)) {
            chainProblem =
                "the Psiphon underlay did not stop in time; the " +
                    "chained session was stopped instead of " +
                    "starting a second core on its port"
            Log.e(TAG, "psiphon underlay stop timed out; not respawning")
            stopUnderlay()
            fail()
            return false
        }
        PsiphonVpnService.start(
            this,
            false,
            sessionUnderlayRegion,
            sessionUnderlayUpstream,
            sessionUnderlayProtocols,
            sessionDns,
            sessionMtu,
        )
        chainGraceUntilMs = System.currentTimeMillis() + 45_000
        return true
    }

    /**
     * Bounded wait for the Psiphon underlay to be observably
     * gone (build 2054, audit F-M5): the service reports
     * not-running AND its SOCKS port answers nothing. Either
     * signal alone is not enough — the flag flips before the
     * listener closes, and the port can be briefly quiet
     * while the core is still shutting down.
     */
    private fun waitUnderlayStopped(timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            // Build 2073: "not running" is the published snapshot
            // (the Psiphon service's own process reports its stop
            // there); the port check beside it is unchanged.
            if (!PsiphonVpnService.publishedRunning(this) &&
                ProcessKill.waitPortFree(PsiphonConstants.SOCKS_PORT, 200)
            ) return true
            try {
                Thread.sleep(100)
            } catch (e: InterruptedException) {
                return false
            }
        }
        return !PsiphonVpnService.publishedRunning(this) &&
            ProcessKill.waitPortFree(PsiphonConstants.SOCKS_PORT, 200)
    }

    /** Revives the session's wstunnel forwarder (build 2072):
     *  same budget shape as the chain revival — three tries,
     *  then the session is torn down loudly rather than left
     *  "Connected" over a dead loopback port. */
    private fun respawnWstunnel(): Boolean {
        if (wstunnelRespawns >= 3) {
            chainProblem =
                "the wstunnel forwarder died and could not be " +
                    "revived — the WireGuard session was stopped"
            Log.e(TAG, "wstunnel revival budget exhausted")
            stopUnderlay()
            fail()
            return false
        }
        wstunnelRespawns++
        chainProblem =
            "the wstunnel forwarder stopped; restarted it " +
                "(try $wstunnelRespawns of 3)"
        Log.w(TAG, "wstunnel unhealthy; respawning (try $wstunnelRespawns)")
        WstunnelCore.restart(this, sessionWstunnelArgs)
        return true
    }

    /** Reaps the underlay this session owns (build 2029A;
     *  generalized in 2030: a Warp underlay core and a
     *  standalone WARP session's core are reaped on every stop
     *  path too — an unreaped core would hold its port and its
     *  identity with nothing above it). */
    private fun stopUnderlay() {
        val wasChain = chainUnderlay
        chainUnderlay = false
        if (sessionSocksMode) {
            try {
                AetherCore.slot(sessionSocksEngine).stop()
            } catch (e: Exception) {
                // Already gone.
            }
            sessionSocksMode = false
        }
        if (sessionUnderlay == "warp" || sessionWarpMode) {
            try {
                EmberWarpCore.stop()
            } catch (e: Exception) {
                // Already gone.
            }
        }
        // Build 2072: the DNSTT underlay client and the
        // session's wstunnel forwarder are reaped on every stop
        // path too — an unreaped helper would hold its loopback
        // port with nothing above it.
        if (sessionUnderlay == "dnstt") {
            try {
                DnsttCore.stop()
            } catch (e: Exception) {
                // Already gone.
            }
        }
        if (sessionWgWstunnel) {
            sessionWgWstunnel = false
            try {
                WstunnelCore.stop()
            } catch (e: Exception) {
                // Already gone.
            }
        }
        if (!wasChain || sessionUnderlay != "psiphon") return
        try {
            PsiphonVpnService.stop(this)
        } catch (e: Exception) {
            // Already gone.
        }
    }

    /**
     * Shape rotation (build 2029A): swap the running core's
     * config and respawn ONLY the core subprocess. The TUN
     * interface, its fd and the tunlink bridge are untouched —
     * the bridge dials the SOCKS port per flow, so flows
     * recover on the new core by themselves.
     */
    private fun rotateCore(newConfig: String) {
        // Build 2054 (audit F-H1): under the core lifecycle
        // lock — a watchdog restart and a rotation can no
        // longer interleave two spawns on the same port.
        synchronized(coreLock) {
            if (!running || stopping.get()) return
            // A session with no Xray process (standalone WARP, Aether
            // SOCKS) has nothing to rotate: spawning a core here would
            // leave a stray process listening on the session's ports.
            // (Build 2039, seamless server switch.)
            if (xrayProcess == null) {
                Log.w(TAG, "rotate refused: no Xray process in this session")
                return
            }
            rotating = true
            try {
                sessionConfig = newConfig
                val dir = workDir(this)
                // Build 2054 (audit F-M6): atomic write.
                AtomicFile.writeText(File(dir, "config.json"), newConfig)
                // An intentional rotation (server switch, shape change)
                // is not a crash: it must not consume the watchdog's
                // restart budget or flash the "core stopped answering"
                // message. (Build 2039.)
                if (restartCore(counted = false)) {
                    // Build 2054 (audit F-H2): the rotation
                    // generation advances ONLY once the new core
                    // is serving — the Dart side waits for it
                    // before believing any tunnelCheck, so a
                    // proof can never pass on the old core.
                    rotationGen++
                }
            } catch (e: Throwable) {
                // Build 2070 (review §5.1): Throwable + crash.log
                // (was Exception + logcat), same reasoning as the
                // start bodies.
                CrashLog.append(this, "XrayVpnService.rotateCore", e)
                Log.e(TAG, "config rotation failed", e)
            } finally {
                rotating = false
            }
        }
    }

    /** True when [file] parses as a JSON object (build 2054,
     *  audit F-M6): a torn write is caught here, never fed to
     *  a respawned core. */
    private fun isValidConfigJson(file: File): Boolean = try {
        file.readText().isNotBlank() &&
            org.json.JSONObject(file.readText()).length() >= 0
    } catch (e: Exception) {
        false
    }

    /** One real SOCKS5 greeting against the core's inbound. */
    /** A plain TCP connect probe (build 2072): proves a
     *  loopback listener accepts, for helpers whose listener is
     *  not a SOCKS server (the DNSTT port forward). */
    private fun probeTcp(port: Int): Boolean =
        try {
            Socket().use { s ->
                s.connect(InetSocketAddress("127.0.0.1", port), 1500)
            }
            true
        } catch (e: Exception) {
            false
        }

    private fun probeSocks(port: Int): Boolean =
        try {
            Socket().use { s ->
                s.connect(InetSocketAddress("127.0.0.1", port), 1500)
                s.soTimeout = 1500
                s.getOutputStream().write(byteArrayOf(5, 1, 0))
                val resp = ByteArray(2)
                var read = 0
                while (read < 2) {
                    val n = s.getInputStream().read(resp, read, 2 - read)
                    if (n < 0) return false
                    read += n
                }
                resp[0].toInt() == 5 && resp[1].toInt() == 0
            }
        } catch (e: Exception) {
            false
        }

    /**
     * Kills and respawns the Xray subprocess with the session config.
     * The TUN and the bridge stay up; the bridge dials the SOCKS port
     * per flow, so new flows recover on their own. Returns false when
     * the session was torn down instead (respawn failed, or the
     * restart budget ran out and the failure went loud).
     *
     * Build 2054 (audit F-H1): under the core lifecycle lock —
     * a watchdog restart and a rotation can no longer
     * interleave two spawns on the same port.
     */
    private fun restartCore(counted: Boolean = true): Boolean =
        synchronized(coreLock) { restartCoreLocked(counted) }

    private fun restartCoreLocked(counted: Boolean = true): Boolean {
        // The watchdog's crash budget (build 2024): a core that
        // keeps dying is failed loudly instead of respawned
        // forever. Intentional rotations (build 2039) skip the
        // budget and the message — a server switch is not a crash.
        if (counted) {
            if (coreRestarts >= 5) {
                coreProblem = "the V2Ray core stopped answering and could not be revived"
                Log.e(TAG, "core restart budget exhausted")
                fail()
                return false
            }
            coreRestarts++
            coreProblem = "the V2Ray core stopped answering; restarted it (try $coreRestarts of 5)"
            Log.e(TAG, "xray alive but not answering on $sessionPort; restarting core (try $coreRestarts)")
        }
        xrayProcess?.let { ProcessKill.kill(it) }
        xrayProcess = null
        // Build 2049: verify the SOCKS port is actually free
        // before respawning. kill() now confirms the old core's
        // death, but a core leaked by an earlier service
        // instance can hold the port too — and while anything
        // still listens there, the new core dies on bind-in-use
        // AND the waitForPort/probeSocks checks below are
        // answered by the stale listener, blessing the corpse.
        // Build 2054 (audit Q-1): a timeout FAILS the restart
        // instead of spawning blind — the old "respawning
        // anyway" let a stale listener bless the new session,
        // and the BUILD-LOG wording overstated the fix.
        if (!ProcessKill.waitPortFree(sessionPort, 4000)) {
            coreProblem =
                "the old V2Ray core did not release its port in " +
                    "time; the session was stopped instead of " +
                    "respawning on a busy port"
            Log.e(TAG, "SOCKS port $sessionPort still busy 4 s after the old core was killed; not respawning")
            fail()
            return false
        }
        val dir = workDir(this)
        val configFile = File(dir, "config.json")
        if (!configFile.exists()) {
            AtomicFile.writeText(configFile, sessionConfig)
        } else if (!isValidConfigJson(configFile)) {
            // Build 2054 (audit F-M6): a torn-but-present file
            // must never be fed to a respawned core — the old
            // code rewrote only when the file was MISSING, so a
            // torn file made the respawned core reject the
            // config and fail() the session the restart was
            // saving. Rewrite from the in-memory session config.
            Log.w(TAG, "session config.json is torn; rewriting from memory")
            AtomicFile.writeText(configFile, sessionConfig)
        }
        val xrayLog = File(dir, "xray.log")
        rotateLogIfLarge(xrayLog)
        val spawned = try {
            ProcessBuilder(
                libPath("libxray.so"), "run", "-c", configFile.absolutePath,
            )
                .directory(dir)
                .redirectErrorStream(true)
                .redirectOutput(ProcessBuilder.Redirect.appendTo(xrayLog))
                .start()
        } catch (e: Exception) {
            Log.e(TAG, "xray respawn failed", e)
            fail()
            return false
        }
        xrayProcess = spawned
        if (!waitForPort(sessionPort, 15000) || !spawned.isAlive || !probeSocks(sessionPort)) {
            Log.e(TAG, "restarted xray is not serving its SOCKS port")
            fail()
            return false
        }
        coreProblem = ""
        return true
    }

    /**
     * Kills libxray/libtunlink processes of this app that this
     * instance did not spawn (leaked when a service instance died
     * without its stop path running). Skipped while this instance
     * has a live tracked process. Best effort throughout.
     *
     * Build 2054 (audit F-M1): the sweep now waits, bounded
     * (3 s), for every pid it killed to vanish from /proc
     * before returning. The sweep's SIGKILLs used to be
     * fire-and-forget, so a start could race a still-dying
     * orphan on the same port. A port-free wait is the wrong
     * shape here for the warp/socks/AWG starts — those sessions
     * bind no new SOCKS port (the live engine already owns
     * it, so it would never read "free") — the pid vanishing
     * is the observable state that the sweep actually landed.
     * startTunnel keeps its own port-free wait on top (Q-1).
     */
    private fun sweepOrphans() {
        if (xrayProcess?.isAlive == true || tunProcess?.isAlive == true) return
        val killed = mutableListOf<Int>()
        try {
            val entries = File("/proc").listFiles() ?: return
            for (entry in entries) {
                val pid = entry.name.toIntOrNull() ?: continue
                if (pid == android.os.Process.myPid()) continue
                val cmd = try {
                    File(entry, "cmdline").readBytes().toString(Charsets.UTF_8)
                } catch (e: Exception) {
                    continue
                }
                if (!cmd.contains("libxray.so") && !cmd.contains("libtunlink.so")) continue
                if (!cmd.contains(packageName)) continue
                Log.w(TAG, "killing orphaned core process $pid")
                try {
                    android.os.Process.killProcess(pid)
                    killed.add(pid)
                } catch (e: Exception) {
                    // Already gone.
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "orphan sweep failed", e)
        }
        if (killed.isEmpty()) return
        val deadline = System.currentTimeMillis() + 3000
        while (System.currentTimeMillis() < deadline) {
            if (killed.none { File("/proc", it.toString()).exists() }) return
            try {
                Thread.sleep(50)
            } catch (e: InterruptedException) {
                return
            }
        }
        Log.w(TAG, "orphan sweep: ${killed.size} pid(s) still present after 3 s")
    }

    /**
     * The listener the helper dials for the TUN fd. The original bug:
     * this listener binds in the ABSTRACT namespace
     * (LocalSocketAddress(String) defaults to it) while the helper
     * dialed the same string as an on-disk filesystem path — no file
     * ever exists in the abstract namespace, so every dial got ENOENT
     * ("no such file or directory") and every V2Ray connection died
     * at startup. The public SDK offers no filesystem-namespace bind
     * for a LocalServerSocket (LocalServerSocket has no bind(), and
     * android.system.UnixSocketAddress is not public API), so both
     * sides now agree on the abstract name instead: the listener
     * keeps the path string as its abstract name, and the helper —
     * which retries for ~10 s — dials the filesystem path first and
     * then the abstract name (the same string, leading NUL byte).
     * The name embeds the app's private files dir, so it cannot
     * collide with another app's socket.
     */
    private fun createFdListener(socketFile: File): LocalServerSocket =
        LocalServerSocket(socketFile.absolutePath)

    private fun acceptWithTimeout(server: LocalServerSocket, timeoutMs: Long): LocalSocket? {
        var result: LocalSocket? = null
        val t = Thread {
            try {
                result = server.accept()
            } catch (e: Exception) {
                // Closed by the timeout thread below.
            }
        }
        t.start()
        t.join(timeoutMs)
        if (t.isAlive) {
            try {
                server.close()
            } catch (e: Exception) {
                // Already closed.
            }
            t.join(1000)
            return null
        }
        return result
    }

    private fun waitForPort(port: Int, timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val x = xrayProcess
            if (x != null && !x.isAlive) return false
            try {
                Socket().use { s ->
                    s.connect(InetSocketAddress("127.0.0.1", port), 300)
                    return true
                }
            } catch (e: Exception) {
                try {
                    Thread.sleep(120)
                } catch (ie: InterruptedException) {
                    return false
                }
            }
        }
        return false
    }

    /**
     * Kill switch (build 2063, feature queue #3): holds a dead
     * session's TUN as a blackhole. The core and the bridge are
     * stopped, but the interface stays up with nobody reading
     * it — the kernel queues then drops packets, so traffic
     * blocks instead of going direct — until the reconnect
     * establishes a new TUN (which closes this fd only after
     * the new one is up) or the user disconnects (ACTION_STOP
     * still tears everything down). The service stays in the
     * foreground with the blocked notice; `running` goes false
     * so the Dart poll sees the drop and schedules the retry.
     * Only called when a TUN exists to hold (never in AWG
     * mode — the userspace device owns that fd).
     */
    private fun holdBlackhole(reason: String) {
        stopUnderlay()
        stopProcesses(keepTun = true)
        running = false
        blackholeHeld = true
        coreProblem = reason
        Log.i(TAG, "kill switch holding the TUN as a blackhole: $reason")
        updateNotification(profileName, blocked = true)
    }

    /**
     * Kill switch (build 2063): an unexpected mid-session death
     * holds the blackhole when the switch is on and a TUN exists
     * to hold; otherwise the session tears down as before. A
     * manual stop never comes through here.
     */
    private fun onSessionDied(reason: String) {
        if (killSwitch && tunPfd != null) {
            holdBlackhole(reason)
            return
        }
        stopTunnel()
    }

    /**
     * Build 2070 (review §5.1): the async start net's landing.
     * The four start bodies run on the worker AFTER this
     * service's onStartCommand net (build 2068) has returned,
     * and each body's prologue — plain field writes and class
     * references like EmberWarpCore.SOCKS_PORT — sits outside
     * its internal try: an Error there (a class-init failure
     * above all) escaped uncaught on the worker thread and took
     * the process down, the Psiphon class in a second engine.
     * A start that escapes its body lands here instead:
     * recorded into xray.log and crash.log, then the service's
     * own [fail] — the same teardown the body's failure path
     * has always run. The success path is untouched: this runs
     * only for a throwable nothing inside the body caught.
     */
    private fun startFailed(where: String, e: Throwable) {
        CrashLog.appendToFile(File(workDir(this), "xray.log"), where, e)
        CrashLog.append(this, where, e)
        try {
            fail()
        } catch (e2: Throwable) {
            CrashLog.append(this, "$where.fail", e2)
        }
    }

    private fun fail() {
        // Kill switch (build 2063): a failed start, or a dead
        // session, with a TUN already up holds the blackhole
        // instead of tearing down — traffic blocks until the
        // reconnect lands or the user disconnects. No TUN yet
        // tears down exactly as before.
        if (killSwitch && tunPfd != null) {
            holdBlackhole(coreProblem.ifEmpty { "the tunnel failed" })
            return
        }
        stopUnderlay()
        stopProcesses()
        running = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun stopTunnel() {
        stopping.set(true)
        stopUnderlay()
        stopProcesses()
        running = false
        // A manual stop releases a kill-switch hold (build
        // 2063): the TUN is closed above, so the flag must go
        // with it — otherwise the UI would report a blackhole
        // that no longer exists.
        blackholeHeld = false
        profileName = ""
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun stopProcesses(keepTun: Boolean = false) {
        // Build 2054 (audit F-H1): under the core lifecycle
        // lock, with restartCore/rotateCore — a stop can no
        // longer race a spawn and leave the new core untracked.
        synchronized(coreLock) {
            stopProcessesLocked(keepTun)
        }
    }

    private fun stopProcessesLocked(keepTun: Boolean = false) {
        try {
            serverSocket?.close()
        } catch (e: Exception) {
            // Already closed.
        }
        serverSocket = null
        // A filesystem-namespace listener leaves its socket file
        // behind on close; remove it so no stale path lingers (the
        // next start deletes before binding anyway).
        try {
            File(workDir(this), "tun.sock").delete()
        } catch (e: Exception) {
            // Best effort only.
        }
        // The AmneziaWG device first (build 2040): it owns the
        // TUN fd, so turning it off closes the interface; the
        // tunPfd close below is a no-op for this mode (null).
        unregisterAwgNetworkCallback()
        awgSettingsText = ""
        if (awgMode && awgHandle > 0) {
            AwgBackend.turnOff(awgHandle)
        }
        awgHandle = -1
        awgMode = false
        // The bridge first, so no new flows start while the core goes.
        tunProcess?.let { ProcessKill.kill(it) }
        tunProcess = null
        xrayProcess?.let { ProcessKill.kill(it) }
        xrayProcess = null
        // The TUN fd: closed on a real stop, kept on a
        // kill-switch hold (build 2063) — the held interface
        // is what blocks traffic until the reconnect lands.
        if (!keepTun) {
            try {
                tunPfd?.close()
            } catch (e: Exception) {
                // Already closed.
            }
            tunPfd = null
        }
    }

    private fun libPath(name: String): String =
        File(applicationInfo.nativeLibraryDir, name).absolutePath

    /**
     * Build 2057 (audit F-M7): xray.log / tunlink.log grew without
     * bound — every other engine rotates at 512 KB. Past 1 MB the
     * file is renamed to .old before a process appends to it, so a
     * failing node's weeks of warn-level logging cannot eat phone
     * storage. Called at every start/restart append site, never on
     * a live process: rotation happens before the spawn, so no log
     * line is ever lost to a concurrent writer.
     */
    /**
     * Build 2067 (log hygiene): rotate [file] at every session
     * start — the previous file becomes <name>.old — so a log
     * viewer can never present a previous session's flood as the
     * current session's (the psiphon.log lesson of the 2066
     * device report). Used for tunlink.log at each bridge start;
     * xray.log keeps the size-based [rotateLogIfLarge] rule.
     */
    private fun rotateLogPerSession(file: File) {
        try {
            if (file.exists()) {
                val old = File(file.parentFile, "${file.name}.old")
                if (old.exists()) old.delete()
                file.renameTo(old)
            }
        } catch (e: Exception) {
            // Logging must never break the tunnel.
        }
    }

    private fun rotateLogIfLarge(file: File) {
        try {
            if (file.exists() && file.length() > 1024 * 1024) {
                file.renameTo(File(file.parentFile, "${file.name}.old"))
            }
        } catch (e: Exception) {
            // Logging must never break the tunnel.
        }
    }

    private fun startInForeground(name: String) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, getString(R.string.notification_channel), NotificationManager.IMPORTANCE_LOW)
                    .apply { setShowBadge(false) },
            )
        }
        val notification = notification(name)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(name: String, blocked: Boolean = false) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(name, blocked))
    }

    private fun notification(name: String, blocked: Boolean = false): Notification {
        val open = PendingIntent.getActivity(
            this, 10, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 11, Intent(this, XrayVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        // Kill switch (build 2063): while the blackhole is
        // held the notification says so — a stale "V2Ray · name"
        // over a dead tunnel would be a lie.
        val text = if (blocked) "Kill switch active — traffic blocked"
            else if (name.isEmpty()) getString(R.string.notification_connecting) else "V2Ray · $name"
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
        const val ACTION_START = "com.ralysnd.ember.XRAY_START"
        const val ACTION_STOP = "com.ralysnd.ember.XRAY_STOP"
        const val ACTION_ROTATE = "com.ralysnd.ember.XRAY_ROTATE"
        const val ACTION_START_WARP = "com.ralysnd.ember.XRAY_START_WARP"
        const val ACTION_START_SOCKS = "com.ralysnd.ember.XRAY_START_SOCKS"
        const val ACTION_START_AWG = "com.ralysnd.ember.XRAY_START_AWG"
        private const val EXTRA_CONFIG = "config"
        private const val EXTRA_AWG_SETTINGS = "awgSettings"
        private const val EXTRA_AWG_ADDRESSES = "awgAddresses"
        private const val EXTRA_NAME = "name"
        private const val EXTRA_SOCKS_PORT = "socksPort"
        // LAN sharing (build 2062, feature queue #2): the SOCKS
        // credentials the tun2socks bridge presents to the
        // password-protected inbound ('' = noauth).
        private const val EXTRA_SOCKS_USER = "socksUser"
        private const val EXTRA_SOCKS_PASS = "socksPass"
        // Kill switch (build 2063, feature queue #3).
        private const val EXTRA_KILL_SWITCH = "killSwitch"
        private const val EXTRA_DNS = "dns"
        private const val EXTRA_IPV6 = "ipv6"
        private const val EXTRA_UNDERLAY = "underlay"
        private const val EXTRA_UNDERLAY_REGION = "underlayRegion"
        private const val EXTRA_UNDERLAY_UPSTREAM = "underlayUpstream"
        private const val EXTRA_UNDERLAY_PROTOCOLS = "underlayProtocols"
        private const val EXTRA_WARP_ARGS = "warpArgs"
        // DNSTT + wstunnel (build 2072).
        private const val EXTRA_DNSTT_ARGS = "dnsttArgs"
        private const val EXTRA_WG_WSTUNNEL = "wgWstunnel"
        private const val EXTRA_WSTUNNEL_ARGS = "wstunnelArgs"
        private const val EXTRA_ENGINE = "engine"
        private const val EXTRA_MTU = "mtu"

        private const val CHANNEL = "xray_status"
        private const val NOTIFICATION_ID = 2
        private const val TAG = "XrayVpnService"
        private const val MTU = 1500

        /** Clamps a tunnel MTU to the offered range (build 2038,
         *  queue 2f): 1280 is the IPv6 minimum MTU (the floor),
         *  1500 the default ceiling. A corrupt or out-of-range
         *  value clamps instead of breaking a connect. */
        private fun clampMtu(mtu: Int) = mtu.coerceIn(1280, 1500)

        @Volatile
        var running = false
            private set

        /**
         * Kill switch (build 2063): true while the service is
         * holding a dead session's TUN as a blackhole — the
         * interface is up with nobody reading it, so traffic
         * blocks instead of going direct. Cleared when a new
         * TUN is established or the user disconnects.
         */
        @Volatile
        var blackholeHeld = false
            internal set

        /** In-place core restarts this session (watchdog revivals). */
        @Volatile
        var coreRestarts = 0
            internal set

        /**
         * Rotation generation (build 2054, audit F-H2):
         * incremented exactly once per successful rotateCore —
         * never for a watchdog restart of the same config — so
         * the Dart side can tell a proof answered by the NEW
         * core from one answered by the old core still serving
         * while the rotate thread works. Reported in xrayState.
         */
        @Volatile
        var rotationGen = 0
            internal set

        /** The last watchdog event, for the UI; empty when healthy. */
        @Volatile
        var coreProblem = ""
            internal set

        /** An underlay (Psiphon, or EmberWarp since build
         * 2030) is chained under the live session. */
        @Volatile
        var chainUnderlay = false
            internal set

        /** The ChainSupervisor's last word, for the UI and the
         * diagnostics journal; survives the session's end so the
         * reason a chained session stopped stays readable. */
        @Volatile
        var chainProblem = ""
            internal set

        @Volatile
        var profileName = ""
            private set

        @Volatile
        var startedAtMs = 0L
            private set

        /** The AmneziaWG session (build 2040, queue 2h): whether
         *  the live tunnel is the userspace device (no Xray
         *  core to rotate, no SOCKS port to probe), and its
         *  device handle for the backend calls. */
        @Volatile
        var awgMode = false
            internal set

        @Volatile
        var awgHandle = -1
            internal set

        /** The running AWG session's UAPI settings text (build
         *  2065, item 8): kept so a network change can re-apply
         *  the SAME config — wg-go rebinds its UDP sockets to the
         *  new network on a setConfig, which is the engine's own
         *  socket-recovery hook. */
        @Volatile
        var awgSettingsText = ""
            internal set

        /** The running device's UAPI dump for the UI's handshake
         *  proof, '' when this is not an AWG session or the
         *  device is gone. */
        fun awgConfigDump(): String {
            if (!awgMode || awgHandle <= 0) return ""
            return AwgBackend.getConfig(awgHandle) ?: ""
        }

        @Volatile
        private var baseTx = -1L

        @Volatile
        private var baseRx = -1L

        /** The Xray mode's files: config, logs, the fd socket. */
        fun workDir(context: Context): File = File(context.filesDir, "xray")

        /** Session traffic of this app's UID since the tunnel started (approximate). */
        fun sessionTraffic(): Pair<Long, Long> {
            if (!running) return 0L to 0L
            val uid = android.os.Process.myUid()
            val tx = TrafficStats.getUidTxBytes(uid)
            val rx = TrafficStats.getUidRxBytes(uid)
            val up = if (tx < 0 || baseTx < 0) 0 else (tx - baseTx).coerceAtLeast(0)
            val down = if (rx < 0 || baseRx < 0) 0 else (rx - baseRx).coerceAtLeast(0)
            return up to down
        }

        fun start(
            context: Context,
            configJson: String,
            name: String,
            socksPort: Int,
            dns: String,
            ipv6: Boolean,
            mtu: Int = 1500,
            underlay: String = "none",
            underlayRegion: String = "",
            underlayUpstream: String = "",
            underlayProtocols: List<String> = emptyList(),
            warpArgs: List<String> = emptyList(),
            // LAN sharing (build 2062): the SOCKS credentials
            // for the tun2socks bridge ('' = noauth).
            socksUser: String = "",
            socksPass: String = "",
            // Kill switch (build 2063, feature queue #3).
            killSwitch: Boolean = false,
            // DNSTT underlay + WireGuard-over-WebSocket
            // (build 2072): the helpers' command lines, kept
            // by the service for supervision + respawn.
            dnsttArgs: List<String> = emptyList(),
            wgWstunnel: Boolean = false,
            wstunnelArgs: List<String> = emptyList(),
        ) {
            val intent = Intent(context, XrayVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_CONFIG, configJson)
                putExtra(EXTRA_NAME, name)
                putExtra(EXTRA_SOCKS_PORT, socksPort)
                putExtra(EXTRA_SOCKS_USER, socksUser)
                putExtra(EXTRA_SOCKS_PASS, socksPass)
                putExtra(EXTRA_KILL_SWITCH, killSwitch)
                putExtra(EXTRA_DNS, dns)
                putExtra(EXTRA_IPV6, ipv6)
                putExtra(EXTRA_MTU, clampMtu(mtu))
                putExtra(EXTRA_UNDERLAY, underlay)
                putExtra(EXTRA_UNDERLAY_REGION, underlayRegion)
                putExtra(EXTRA_UNDERLAY_UPSTREAM, underlayUpstream)
                putStringArrayListExtra(
                    EXTRA_UNDERLAY_PROTOCOLS,
                    ArrayList(underlayProtocols),
                )
                putStringArrayListExtra(EXTRA_WARP_ARGS, ArrayList(warpArgs))
                putStringArrayListExtra(EXTRA_DNSTT_ARGS, ArrayList(dnsttArgs))
                putExtra(EXTRA_WG_WSTUNNEL, wgWstunnel)
                putStringArrayListExtra(
                    EXTRA_WSTUNNEL_ARGS,
                    ArrayList(wstunnelArgs),
                )
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Starts the standalone WARP tunnel (build 2030): the
         *  EmberWarp core is already running (the Dart side
         *  started and readiness-checked it); the service
         *  brings the TUN up against its SOCKS port. */
        fun startWarp(
            context: Context,
            name: String,
            dns: String,
            ipv6: Boolean,
            warpArgs: List<String>,
            mtu: Int = 1500,
            // Kill switch (build 2063, feature queue #3).
            killSwitch: Boolean = false,
        ) {
            val intent = Intent(context, XrayVpnService::class.java).apply {
                action = ACTION_START_WARP
                putExtra(EXTRA_NAME, name)
                putExtra(EXTRA_DNS, dns)
                putExtra(EXTRA_IPV6, ipv6)
                putExtra(EXTRA_MTU, clampMtu(mtu))
                putExtra(EXTRA_KILL_SWITCH, killSwitch)
                putStringArrayListExtra(EXTRA_WARP_ARGS, ArrayList(warpArgs))
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Starts the TUN for an AetherCore slot (build 2032):
         *  the slot is already running and stage-proven. */
        fun startSocks(
            context: Context,
            name: String,
            dns: String,
            ipv6: Boolean,
            socksPort: Int,
            engine: String,
            mtu: Int = 1500,
            // Kill switch (build 2063, feature queue #3).
            killSwitch: Boolean = false,
        ) {
            val intent = Intent(context, XrayVpnService::class.java).apply {
                action = ACTION_START_SOCKS
                putExtra(EXTRA_NAME, name)
                putExtra(EXTRA_DNS, dns)
                putExtra(EXTRA_IPV6, ipv6)
                putExtra(EXTRA_SOCKS_PORT, socksPort)
                putExtra(EXTRA_ENGINE, engine)
                putExtra(EXTRA_MTU, clampMtu(mtu))
                putExtra(EXTRA_KILL_SWITCH, killSwitch)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Starts the AmneziaWG tunnel (build 2040, queue 2h):
         *  [settings] is the UAPI string the Dart side built
         *  from the profile; [addresses] is the profile's
         *  tunnel addresses ("ip/prefix" comma-separated). */
        fun startAwg(
            context: Context,
            name: String,
            settings: String,
            addresses: String,
            dns: String,
            ipv6: Boolean,
            mtu: Int = 1500,
        ) {
            val intent = Intent(context, XrayVpnService::class.java).apply {
                action = ACTION_START_AWG
                putExtra(EXTRA_NAME, name)
                putExtra(EXTRA_AWG_SETTINGS, settings)
                putExtra(EXTRA_AWG_ADDRESSES, addresses)
                putExtra(EXTRA_DNS, dns)
                putExtra(EXTRA_IPV6, ipv6)
                putExtra(EXTRA_MTU, clampMtu(mtu))
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Asks the live service to rotate its core config (build 2029A). */
        fun rotate(context: Context, configJson: String) {
            val intent = Intent(context, XrayVpnService::class.java).apply {
                action = ACTION_ROTATE
                putExtra(EXTRA_CONFIG, configJson)
            }
            try {
                context.startService(intent)
            } catch (e: Exception) {
                // Not running: nothing to rotate.
            }
        }

        fun stop(context: Context) {
            // Direct service intent: onStartCommand stops everything; a
            // plain stopService races the worker's startup sequence.
            val intent = Intent(context, XrayVpnService::class.java).setAction(ACTION_STOP)
            try {
                context.startService(intent)
            } catch (e: Exception) {
                // Not running (or background-start limits): make sure.
                context.stopService(Intent(context, XrayVpnService::class.java))
            }
        }
    }
}
