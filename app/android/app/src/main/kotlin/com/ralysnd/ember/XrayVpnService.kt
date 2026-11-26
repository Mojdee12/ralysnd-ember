package com.ralysnd.ember

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
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
import java.util.Locale
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
     * Build 2125 (audit A25-02 / P-08): the serial executor
     * for the session actions — Pause, Resume, Stop and
     * onRevoke. Up to 2124 each action spawned its own bare
     * daemon thread with no ordering between them:
     * pauseTunnel() could block on coreLock (held by a
     * restart) while a Stop ran to completion on its own
     * thread, and the Pause thread then woke and published
     * a phantom "Paused" state whose Resume resurrected a
     * session the user had explicitly disconnected. On one
     * serial executor the actions run strictly in arrival
     * order: a Stop queued behind a Pause runs after it and
     * ends the session for real, and a Resume queued behind
     * a Stop sees `paused == false` and no-ops.
     */
    private val actionWorker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "xray-actions").apply { isDaemon = true }
    }

    /**
     * Build 2123 (audit P-06 / E-03): underlying-network
     * watch — Mozilla's CoreService pattern, shared via
     * [UnderlyingNetworkWatch]. A Wi-Fi↔mobile switch used
     * to blackhole a "Connected" Xray session indefinitely:
     * the TUN was never re-pointed and the core's sockets
     * stayed bound to the dead path, while the native
     * health probe (loopback-only) stayed green.
     */
    private val underlyingWatch =
        UnderlyingNetworkWatch(this, "XrayVpnService") {
            onUnderlyingNetworkChanged()
        }

    /**
     * The underlying network changed under a live session:
     * rotate the core on its own config so every outbound
     * re-dials on the new path. rotateCore does not consume
     * the watchdog's restart budget and refuses cleanly for
     * sessions with no Xray process (standalone WARP /
     * Aether) — for those, the watch's setUnderlyingNetworks
     * re-point is the whole fix. Runs the rotation on a
     * daemon thread, like ACTION_ROTATE: rotateCore can
     * hold the core lock for seconds and the callback
     * arrives on the main thread.
     */
    private fun onUnderlyingNetworkChanged() {
        if (!running || stopping.get()) return
        val config = sessionConfig
        if (config.isEmpty()) return
        CrashLog.breadcrumb(this, "xray:underlying-network-changed")
        Thread {
            try {
                rotateCore(config)
            } catch (e: Throwable) {
                CrashLog.append(
                    this,
                    "XrayVpnService.networkRotate",
                    e,
                )
            }
        }.apply {
            isDaemon = true
            name = "xray-netrotate"
        }.start()
    }

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

    /**
     * Build 2098 (verification, iteration 2): the Paused
     * notification's Resume action is pointed when the
     * notification is BUILT (at the app when the lock is
     * on, at this service when off), but nothing rebuilds
     * it while a pause lasts — the periodic speed-line
     * refresh early-returns when paused. A lock toggled
     * mid-pause therefore left the stale action in place
     * for the whole pause: a dead Resume in one direction,
     * an app-open-only Resume in the other. Watch the
     * marker Dart maintains and re-post the notification
     * when it flips. (Held in a field: the preferences
     * keep only a weak reference to listeners.)
     */
    private val lockMarkerListener =
        SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == "lock_enabled" && paused) {
                updateNotification(profileName)
            }
        }

    override fun onCreate() {
        super.onCreate()
        getSharedPreferences("ember_widget", Context.MODE_PRIVATE)
            .registerOnSharedPreferenceChangeListener(lockMarkerListener)
        // Build 2155: the hev bridge's session log sink —
        // its start/stop lines join the service's log.
        HevTunManager.logger = { line -> Log.i(TAG, line) }
    }

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
    // Build 2081 (verification V-8): the IPv6 flag and the LAN
    // SOCKS credentials, kept like the other session args so a
    // notification Resume restarts the session exactly as it
    // started — startTunnel is the only writer, like sessionDns.
    private var sessionIpv6 = true
    private var sessionSocksUser = ""
    private var sessionSocksPass = ""
    // Build 2081 (verification V-8): the notification speed
    // line's sampling state — the last session-traffic sample
    // and when it was taken, and the composed line the
    // notification shows. Written by the watch loop (worker
    // thread), read by notification() from any thread.
    @Volatile
    private var lastSpeedSample: Pair<Long, Long>? = null
    @Volatile
    private var lastSpeedAtMs = 0L
    @Volatile
    private var shownSpeed = ""
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
    // OLCRTC underlay session state (build 2134): the
    // client's argument list (one YAML config path), kept
    // for supervision + respawn like the DNSTT args above.
    private var sessionOlcrtcArgs: List<String> = emptyList()

    // Tunnel bridge session state (build 2155, the 2153
    // bridge swap): which TUN → SOCKS bridge the V2Ray
    // session runs — "hev" (hev-socks5-tunnel, in-process)
    // or "tunlink" (the legacy subprocess). Kept like the
    // other session args so a notification Resume restarts
    // the session on the same bridge, and so the watch loop
    // knows which liveness proof applies. Written only by
    // startTunnel; the WARP / SOCKS starts never touch it
    // (their sessions always carry a bridge subprocess).
    private var sessionBridge = "hev"
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

    // Build 2119 (audit F-04): the EngineClaim identity of
    // the session this service instance is hosting — plain
    // Xray, standalone WARP, or the Aether SOCKS tunnel.
    // Starts set it from the action; the stop path and
    // onDestroy release THIS name (release is owner-checked,
    // so releasing "xray" for an Aether session would leave
    // its marker behind). A system-restarted service that
    // never saw a start defaults to XRAY, the pre-2119
    // behaviour.
    private var claimName: String = EngineClaim.XRAY


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
        // Build 2123 (P-06): the underlying-network watch
        // lives for the service's lifetime (idempotent).
        underlyingWatch.start()
        // Build 2087 (analysis A2): a fresh start clears the
        // user-stop marker — it describes the last stop only
        // until a new session begins.
        when (intent?.action) {
            ACTION_START, ACTION_START_WARP,
            ACTION_START_SOCKS -> userStopped = false
        }
        // Build 2116 (B7-1, AB-08): a start (or a resume,
        // which re-runs the start path) claims the VPN slot
        // through the native single-writer claim — Dart,
        // notification and system-restart starts all pass
        // this funnel, so a natively-resumed Xray session
        // displaces whatever else took the slot meanwhile.
        // Build 2119 (audit F-04): the claim carries the
        // session kind's own identity — a WARP or Aether
        // start now displaces a plain Xray owner natively
        // (and the reverse), instead of every kind claiming
        // XRAY and claim() seeing no difference to act on.
        // A resume re-claims the identity this instance
        // already hosts.
        // Build 2125 (audit A25-13 / P-14): the claim is
        // VALIDATED before it is taken. Up to 2124 every
        // start/resume claimed first — displacing (stopping)
        // the running engine — and only afterwards discovered
        // it had nothing to run: an ACTION_START with an
        // empty config, an ACTION_START_SOCKS with invalid
        // extras, or a Resume that the app lock or the
        // not-paused check turned into a no-op. A no-op no
        // longer kills a healthy session: those actions fall
        // through to their existing branches (which still
        // satisfy the foreground-service deadline and stop
        // on the record) WITHOUT claiming.
        val startClaim = when (intent?.action) {
            ACTION_START ->
                if ((intent.getStringExtra(EXTRA_CONFIG) ?: "").isEmpty()) {
                    null
                } else {
                    EngineClaim.XRAY
                }
            ACTION_START_WARP -> EngineClaim.WARP
            ACTION_START_SOCKS ->
                if (intent.getIntExtra(EXTRA_SOCKS_PORT, 0) <= 0 ||
                    (intent.getStringExtra(EXTRA_ENGINE) ?: "").isEmpty()
                ) {
                    null
                } else {
                    EngineClaim.AETHER
                }
            ACTION_RESUME ->
                if (paused &&
                    sessionConfig.isNotEmpty() &&
                    profileName.isNotEmpty() &&
                    !ConnectWidget.appLockEnabled(this)
                ) {
                    claimName
                } else {
                    null
                }
            else -> null
        }
        if (startClaim != null) {
            claimName = startClaim
            EngineClaim.claim(this, startClaim)
        }
        when (intent?.action) {
            ACTION_STOP -> {
                // Build 2087 (analysis A2): this stop is the
                // user's own (the notification's Disconnect, or
                // the app's stop, which funnels through the same
                // action) — mark it BEFORE the stop runs, so the
                // Dart poll can tell it from an unexpected drop.
                userStopped = true
                // Build 2116 (B7-1): the claim is released.
                // Build 2119 (audit F-04): under the session
                // kind's own identity — releasing XRAY for a
                // WARP/Aether session would leave its marker.
                EngineClaim.release(this, claimName)
                // Off the main thread: stopProcesses takes
                // coreLock, which a restart can hold for ~20 s.
                // Build 2125 (audit A25-02 / P-08): on the
                // serial action executor, not a bare thread —
                // see actionWorker.
                actionWorker.execute { stopTunnel() }
                return START_NOT_STICKY
            }
            ACTION_PAUSE -> {
                // Build 2081 (verification V-8): off the main
                // thread, like ACTION_STOP — pauseTunnel takes
                // coreLock via stopProcesses. Build 2125
                // (A25-02): serialized with Stop/Resume on
                // actionWorker.
                actionWorker.execute { pauseTunnel() }
                return START_STICKY
            }
            ACTION_RESUME -> {
                // Build 2081 (verification V-8): off the main
                // thread — resumeTunnel re-runs the full start
                // path, which can hold coreLock while it sweeps
                // orphans and waits for the port. Build 2125
                // (A25-02): serialized on actionWorker.
                actionWorker.execute { resumeTunnel() }
                return START_STICKY
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
                // OLCRTC underlay (build 2134).
                val olcrtcArgs =
                    intent.getStringArrayListExtra(EXTRA_OLCRTC_ARGS) ?: arrayListOf()
                val wgWstunnel = intent.getBooleanExtra(EXTRA_WG_WSTUNNEL, false)
                val wstunnelArgs =
                    intent.getStringArrayListExtra(EXTRA_WSTUNNEL_ARGS) ?: arrayListOf()
                // LAN sharing (build 2062): the SOCKS
                // credentials for the tun2socks bridge.
                val socksUser = intent.getStringExtra(EXTRA_SOCKS_USER) ?: ""
                val socksPass = intent.getStringExtra(EXTRA_SOCKS_PASS) ?: ""
                // Kill switch (build 2063, feature queue #3).
                killSwitch = intent.getBooleanExtra(EXTRA_KILL_SWITCH, false)
                // Tunnel bridge (build 2155, the 2153 swap):
                // 'hev' or 'tunlink'; an intent from before
                // the swap carries no extra and reads 'hev',
                // the new default.
                val bridge = intent.getStringExtra(EXTRA_BRIDGE) ?: "hev"
                // Build 2110 (wg-start diagnosis, defect 3):
                // the validity check moves BELOW
                // startInForeground. This intent arrived via
                // startForegroundService, which arms a system
                // deadline the moment it is delivered; the old
                // order — stopSelf() first, silently — left
                // that deadline unfulfillable, and the system
                // delivered the crash
                // (ForegroundServiceDidNotStartInTimeException)
                // later, against whatever healthy start was
                // then in flight (the owner's 2026-11-18
                // export: two crashes, each mid-AWG→Xray
                // switch). Going foreground FIRST satisfies
                // the deadline for every delivered intent;
                // the empty-config case then stops, on the
                // record instead of silently.
                startInForeground(name)
                if (config.isEmpty()) {
                    CrashLog.breadcrumb(this, "xray:start-empty-config")
                    Log.w(TAG, "ACTION_START with an empty config; stopping")
                    stopSelf()
                    return START_NOT_STICKY
                }
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
                            olcrtcArgs, bridge,
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
                // Build 2110 (wg-start diagnosis, defect 3):
                // foreground first, validity second — the
                // same armed-deadline reasoning as
                // ACTION_START above.
                startInForeground(name)
                if (socksPort <= 0 || engine.isEmpty()) {
                    CrashLog.breadcrumb(this, "xray:start-socks-invalid")
                    Log.w(TAG, "ACTION_START_SOCKS with invalid extras; stopping")
                    stopSelf()
                    return START_NOT_STICKY
                }
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
            else -> {
                // Restarted by the system without an intent: there is no
                // config to run, so do not linger as a dead VPN.
                stopSelf()
                return START_NOT_STICKY
            }
        }
    }

    override fun onRevoke() {
        // Build 2126 (audit A26-10): a revoke is a stop,
        // not a drop — mark it like ACTION_STOP does, so
        // the pause machinery cannot resurrect a phantom
        // "Paused" state for a session the system ended.
        userStopped = true
        // Same reason as ACTION_STOP: off the main thread.
        // Build 2125 (A25-02): serialized on actionWorker,
        // like the ACTION_STOP it mirrors.
        actionWorker.execute { stopTunnel() }
    }

    override fun onDestroy() {
        // Build 2123 (P-06): the network watch dies with
        // the service.
        underlyingWatch.stop()
        // Build 2116 (B7-1): teardown releases the claim
        // (owner-checked). Build 2119: under the hosted
        // session kind's identity (see the ACTION_STOP path).
        EngineClaim.release(this, claimName)
        getSharedPreferences("ember_widget", Context.MODE_PRIVATE)
            .unregisterOnSharedPreferenceChangeListener(lockMarkerListener)
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
        // Build 2125 (A25-02): the action executor gets the
        // same treatment.
        actionWorker.shutdown()
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
        // OLCRTC underlay (build 2134).
        olcrtcArgs: List<String> = emptyList(),
        // Tunnel bridge (build 2155, the 2153 swap): 'hev'
        // (hev-socks5-tunnel, in-process) or 'tunlink' (the
        // legacy subprocess). Applies to this path only —
        // the WARP / SOCKS starts keep their subprocess.
        bridge: String = "hev",
    ) {
        // Build 2068 breadcrumb (control trail): the worker
        // reached the tunnel builder.
        CrashLog.breadcrumb(this, "xray:startTunnel-entered")
        stopping.set(false)
        // Build 2081 (verification V-8): a fresh start (or a
        // Resume through resumeTunnel) clears any held pause,
        // and the start args a Resume needs are retained here.
        paused = false
        sessionConfig = configJson
        sessionPort = socksPort
        sessionDns = dns
        sessionIpv6 = ipv6
        sessionMtu = mtu
        sessionSocksUser = socksUser
        sessionSocksPass = socksPass
        sessionUnderlay = underlay
        sessionUnderlayRegion = underlayRegion
        sessionUnderlayUpstream = underlayUpstream
        sessionUnderlayProtocols = underlayProtocols
        sessionWarpArgs = warpArgs
        sessionDnsttArgs = dnsttArgs
        sessionWgWstunnel = wgWstunnel
        sessionWstunnelArgs = wstunnelArgs
        sessionOlcrtcArgs = olcrtcArgs
        sessionBridge = bridge
        wstunnelFails = 0
        wstunnelRespawns = 0
        sessionWarpMode = false
        sessionSocksMode = false
        chainFails = 0
        chainRespawns = 0
        // Build 2080: a chained EmberWarp core is spawned by
        // this service (below) and its cold scan must validate
        // through the session's exit-node — the old flat 45 s
        // grace expired mid-scan and the ChainSupervisor then
        // respawned (killed) the still-scanning core. The warp
        // grace matches the core's chained greeting budget
        // (EmberWarpCore.CHAIN_GREETING_WAIT_MS).
        chainGraceUntilMs = System.currentTimeMillis() +
            (if (underlay == "warp") WARP_CHAIN_INITIAL_GRACE_MS
            else if (underlay == "olcrtc") OLCRTC_CHAIN_INITIAL_GRACE_MS
            else 45_000L)
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

            // Build 2110 (wg-start diagnosis, defect 4):
            // stop this instance's OWN tracked processes
            // FIRST. The orphan sweep below is forbidden to
            // touch them (its exclusion), so a previous
            // session's core still tracked here — its stop
            // queued behind a restart's coreLock, or Dart's
            // state running ahead of the service's — survived
            // every sweep and held the SOCKS port against its
            // own successor (the owner's 2026-11-18 export:
            // "SOCKS port 10808 stayed busy after the
            // leftover-core sweep", twice). stopProcesses
            // confirms each death before returning
            // (ProcessKill.kill). keepTun follows the
            // kill-switch hold exactly: a held blackhole's fd
            // survives until the new TUN below replaces it —
            // closing it here would open the direct-traffic
            // window the hold exists to prevent.
            // Build 2127 (H5, audit A26-05): with the kill
            // switch on, the TUN is established FIRST —
            // before the processes below stop and the new
            // core is spawned and proven — so the window
            // between the user's tap (or a switch) and the
            // TUN landing no longer leaks direct: a TUN
            // with no reader is a blackhole, and a failure
            // below lands in fail(), which holds exactly
            // that TUN. The engine's own plumbing is
            // app-UID and disallowed from its own VPN, so
            // the spawn's dials are unaffected. With the
            // switch off, the order is 2126's exactly.
            if (killSwitch) {
                if (!establishTun(dns, ipv6, mtu)) return
                stopProcesses(keepTun = true)
            } else {
                stopProcesses(keepTun = blackholeHeld)
            }
            // Sweep + spawn under coreLock (see
            // spawnCoreLocked): a watchdog restart or a
            // rotation can no longer interleave its own
            // kill/respawn with this fresh spawn.
            val coreSpawned = synchronized(coreLock) {
                spawnCoreLocked(dir, configFile, socksPort, underlay, warpArgs)
            }
            if (!coreSpawned) return

            if (!killSwitch) {
                // 2. The VPN interface (the classic order:
                // after the core is proven).
                if (!establishTun(dns, ipv6, mtu)) return
            }
            val pfd = tunPfd ?: return

            if (bridge == "hev") {
                // 3–5 (build 2155, the 2153 bridge swap): the
                // TUN reader is hev-socks5-tunnel, in-process
                // via JNI — no fd listener, no helper
                // subprocess, no SCM_RIGHTS handoff. The hev
                // config is this same session in hev's YAML:
                // the Builder's address plan and MTU, the
                // core's SOCKS port (TCP + UDP ASSOCIATE),
                // and the LAN credentials when the session
                // carries them (the legacy branch passes the
                // same pair in its proxy URL). The manager
                // dups the fd — hev closes the one it is
                // handed — so the service's pfd stays the
                // session's own, exactly as on the legacy
                // path.
                val hevConfig = File(dir, "hev.yml")
                AtomicFile.writeText(
                    hevConfig,
                    hevConfigYaml(mtu, ipv6, socksPort, socksUser, socksPass),
                )
                if (!HevTunManager.start(hevConfig, pfd)) {
                    Log.e(TAG, "the hev bridge did not start")
                    fail()
                    return
                }
            } else {
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
     * The hev-socks5-tunnel config for a V2Ray session
     * (build 2155, the 2153 bridge swap): the same session
     * the Builder and the core already run, in hev's YAML.
     * The tunnel block mirrors establishTun's address plan
     * exactly — 10.10.14.1 always, the IPv6 address ONLY
     * when the session's IPv6 flag is on (the Builder
     * installs no IPv6 then, and hev must not expect any),
     * and the session MTU, the value the interface itself
     * was built with (the Tun2SocksManager trap: a bridge
     * MTU that differs from the interface's produces wrong
     * packets, not smaller ones). The socks5 block points
     * at the core's inbound with UDP relay in 'udp' mode
     * (SOCKS5 UDP ASSOCIATE — the mode the core speaks;
     * 'tcp' would relay UDP over TCP connections), plus
     * the LAN-sharing credentials when the session carries
     * them, the same pair the legacy branch puts in its
     * proxy URL.
     */
    private fun hevConfigYaml(
        mtu: Int,
        ipv6: Boolean,
        socksPort: Int,
        socksUser: String,
        socksPass: String,
    ): String {
        val sb = StringBuilder()
        sb.append("tunnel:\n")
        sb.append("  mtu: ").append(mtu).append('\n')
        sb.append("  ipv4: 10.10.14.1\n")
        if (ipv6) sb.append("  ipv6: 'fdfe:dcba:9876::1'\n")
        sb.append("socks5:\n")
        sb.append("  address: 127.0.0.1\n")
        sb.append("  port: ").append(socksPort).append('\n')
        sb.append("  udp: 'udp'\n")
        if (socksUser.isNotEmpty() && socksPass.isNotEmpty()) {
            sb.append("  username: '").append(yamlSingleQuoted(socksUser)).append("'\n")
            sb.append("  password: '").append(yamlSingleQuoted(socksPass)).append("'\n")
        }
        sb.append("misc:\n")
        sb.append("  log-level: warn\n")
        return sb.toString()
    }

    /** YAML single-quote escaping: a quote doubles. */
    private fun yamlSingleQuoted(value: String): String =
        value.replace("'", "''")

    /**
     * Builds and establishes the session's TUN (build
     * 2127, H5: factored out of startTunnel — the
     * kill-switch path establishes it before the core
     * spawn, the classic path after; the body is the one
     * 2126 ran inline). Any previous TUN — a live one on
     * a switch, or the kill switch's held blackhole — is
     * closed only after the new one is up: closing it
     * first would open the direct-traffic window both
     * the switch and the hold exist to prevent. On
     * failure the start fails via fail(), which holds
     * the new TUN as the blackhole when the kill switch
     * is on.
     */
    private fun establishTun(dns: String, ipv6: Boolean, mtu: Int): Boolean {
        if (prepare(this) != null) {
            Log.w(TAG, "the VPN has no permission")
            fail()
            return false
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
        val heldPfd = tunPfd
        val pfd = builder.establish()
        if (pfd == null) {
            Log.e(TAG, "establish() returned null")
            fail()
            return false
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
        return true
    }

    /**
     * The fresh-start spawn sequence (build 2110, wg-start
     * diagnosis defect 4), run by [startTunnel] under
     * [coreLock] after it stopped this instance's own tracked
     * processes: sweep the orphans of earlier instances, prove
     * the SOCKS port free, spawn the chained EmberWarp core
     * when the session carries one, spawn the Xray core, and
     * prove the spawned core is the one serving the port.
     * Every failure runs the same fail() the inline sequence
     * ran and returns false; the caller abandons the start.
     */
    private fun spawnCoreLocked(
        dir: File,
        configFile: File,
        socksPort: Int,
        underlay: String,
        warpArgs: List<String>,
    ): Boolean {
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
            fail("the local SOCKS port $socksPort stayed busy after the leftover-core sweep")
            return false
        }

        // Build 2080: the service spawns the chained
        // EmberWarp core ITSELF, here at session start —
        // previously the Dart side spawned it only after
        // its post-start state poll noticed the tunnel,
        // burning the supervisor's grace before the scan
        // even began. The core's scan retries ride the
        // exit-node as soon as the Xray core below is up.
        // A failed session reaps it via fail() →
        // stopUnderlay() like every other stop path.
        if (underlay == "warp" && warpArgs.isNotEmpty()) {
            EmberWarpCore.start(
                this, warpArgs, EmberWarpCore.SOCKS_PORT,
            )
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
            fail("the V2Ray core did not open its local port in time")
            return false
        }
        // The port answering is not enough: it must be OUR core
        // answering (a stale listener satisfies waitForPort too).
        val spawned = xrayProcess
        if (spawned == null || !spawned.isAlive || !probeSocks(socksPort)) {
            Log.e(TAG, "xray SOCKS port answered but the spawned core is not serving it")
            fail("the local port answered but the spawned core is not the one serving it")
            return false
        }
        return true
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
        sessionOlcrtcArgs = emptyList()
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
        sessionOlcrtcArgs = emptyList()
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
            // Build 2080: readiness is the slot's demotion-aware
            // isConnected() — a bare CONNECTED stage can be a
            // hollow session whose data plane is retrying.
            if (!slot.isConnected() || !probeSocks(socksPort)) {
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
            // Build 2125 (audit A25-36 / P-41): the Only
            // set resolved to nothing installed, so the
            // builder falls through to all-apps semantics
            // below (an empty allow-list would tunnel this
            // app too — a loop). The inversion is journaled,
            // never silent.
            CrashLog.breadcrumb(
                this,
                "xray:per-app Only set empty — all apps use the tunnel",
            )
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
            // Build 2081 (verification V-8): the notification
            // speed line measures from this session's start —
            // sessionTraffic() is ~0 here (base captured in the
            // start body just before), so the first tick already
            // has a 5 s rate.
            lastSpeedSample = sessionTraffic()
            lastSpeedAtMs = System.currentTimeMillis()
            shownSpeed = ""
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
                // Build 2081 (verification V-8): the live speed
                // line, sampled every tick (5 s) and re-posted
                // only when the line changed.
                refreshSpeedLine()
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
                    // Build 2155: a hev session has no bridge
                    // subprocess to poll (t is null there, and
                    // only there — the WARP / SOCKS sessions
                    // always carry one) — the bridge's own
                    // running flag is its liveness proof.
                    if (t == null && sessionBridge == "hev" &&
                        !sessionWarpMode && !sessionSocksMode &&
                        !HevTunManager.isRunning
                    ) {
                        Log.e(TAG, "hev bridge stopped")
                        onSessionDied("the tunnel bridge stopped")
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
                            // Build 2080: a core still in its
                            // FIRST scan is exempt — counting
                            // failures against it respawned
                            // (killed) it mid-scan and restarted
                            // the very clock being measured.
                            // The exemption is bounded by the
                            // core's own greeting wait, after
                            // which its stage leaves "starting"
                            // and full supervision applies.
                            "warp" -> EmberWarpCore.scanInProgress() ||
                                (EmberWarpCore.running &&
                                    EmberWarpCore.ready &&
                                    probeSocks(EmberWarpCore.SOCKS_PORT))
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
                            // OLCRTC (build 2134): the client
                            // IS a SOCKS5 server, and its
                            // listener opens only after the
                            // WebRTC link is up — the process,
                            // its readiness flag, and a SOCKS
                            // handshake on its port are the
                            // health proof.
                            "olcrtc" -> OlcrtcCore.running &&
                                OlcrtcCore.ready &&
                                probeSocks(OlcrtcCore.PORT)
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
                        // Build 2080: isConnected() is demotion-
                        // aware — a data-plane retry after
                        // CONNECTED withdraws readiness, so a
                        // hollow session now fails this check and
                        // is closed instead of sitting green.
                        val healthy = slot.isConnected() &&
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
            "olcrtc" -> "OLCRTC"
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
            // Build 2080: never respawn a core still in its
            // first scan — a restart resets the scan to zero.
            // Extend the grace and let the scan finish; the
            // supervisor's exemption normally keeps this path
            // from being reached mid-scan at all.
            if (EmberWarpCore.scanInProgress()) {
                Log.w(TAG, "warp underlay still in its first scan; not respawning")
                chainGraceUntilMs = System.currentTimeMillis() + 30_000
                return true
            }
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
        if (sessionUnderlay == "olcrtc") {
            // Build 2134: the OLCRTC client respawns with
            // the session's config path; it must rejoin the
            // room and re-find its peer before its listener
            // returns, so the grace window is the link
            // budget, not the DNSTT moments.
            OlcrtcCore.restart(this, sessionOlcrtcArgs)
            chainGraceUntilMs = System.currentTimeMillis() +
                OLCRTC_CHAIN_INITIAL_GRACE_MS
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
        // Build 2134: the OLCRTC underlay client is reaped
        // on every stop path too, like DNSTT above.
        if (sessionUnderlay == "olcrtc") {
            try {
                OlcrtcCore.stop()
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

    /** The parent pid of a /proc entry, or -1 when it cannot
     *  be read (build 2110): the sweep's exclusion key. The
     *  first design read the pid off the Process object —
     *  java.lang.Process.pid() is a Java 9 surface that
     *  android.jar does not carry at ANY platform level (the
     *  release build's Kotlin compile proved it:
     *  "Unresolved reference 'pid'"), so the exclusion is by
     *  PARENTAGE instead: a process whose parent is this app
     *  process is this instance's own child — a tracked core
     *  or bridge — and is never an orphan; the dedicated stop
     *  paths own its death. An orphan is exactly a core whose
     *  spawning process died, which reparents it away from
     *  us. An unreadable status (-1) never equals our pid, so
     *  the entry stays sweep-eligible — the pre-2110 default
     *  for anything unidentifiable. */
    private fun ppidOf(entry: File): Int = try {
        File(entry, "status").useLines { lines ->
            lines.firstOrNull { it.startsWith("PPid:") }
                ?.substringAfter(':')
                ?.trim()
                ?.toIntOrNull()
        } ?: -1
    } catch (e: Throwable) {
        -1
    }

    /**
     * Kills libxray/libtunlink processes of this app that this
     * instance did not spawn (leaked when a service instance died
     * without its stop path running). This process's own children
     * are excluded BY PARENTAGE (see ppidOf). Best effort
     * throughout.
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
     *
     * Build 2110 (wg-start diagnosis, defect 4): the exclusion
     * used to be a blanket guard — ANY live tracked process
     * skipped the whole sweep. On a fresh start that guard
     * blinded the sweep to the likeliest port-holder of all:
     * this instance's own still-alive tracked core, whose
     * stop had not landed. startTunnel now stops its tracked
     * processes before sweeping; the sweep itself excludes
     * this process's own children by parentage, so a
     * warp/socks start (whose tracked bridge may legitimately
     * be alive) no longer disables the sweep either.
     */
    private fun sweepOrphans() {
        val myPid = android.os.Process.myPid()
        val killed = mutableListOf<Int>()
        try {
            val entries = File("/proc").listFiles() ?: return
            for (entry in entries) {
                val pid = entry.name.toIntOrNull() ?: continue
                if (pid == myPid) continue
                if (ppidOf(entry) == myPid) continue
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

    // Build 2095 (third-pass audit 3-1): fail() takes the
    // start-failure reason and publishes it as coreProblem —
    // the four start sites below used to fail silently, so
    // the Dart side could only ever say "start-failed".
    private fun fail(reason: String = "") {
        if (reason.isNotEmpty()) coreProblem = reason
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
        // Build 2081 (verification V-8): a full stop clears
        // any held pause and the speed line with it.
        paused = false
        shownSpeed = ""
        lastSpeedSample = null
        lastSpeedAtMs = 0L
        // A manual stop releases a kill-switch hold (build
        // 2063): the TUN is closed above, so the flag must go
        // with it — otherwise the UI would report a blackhole
        // that no longer exists.
        blackholeHeld = false
        profileName = ""
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * Whether this session can be paused and resumed by this
     * service alone (build 2081, verification V-8): a V2Ray
     * core session whose underlay startTunnel can restart by
     * itself — none, or EmberWarp (natively spawned in
     * startTunnel since 2080). Psiphon and DNSTT underlays are
     * started by Dart, and the WG wstunnel forwarder too, so
     * pausing one would reap an underlay Resume cannot
     * restart; those sessions offer no Pause action, and
     * pauseTunnel refuses them. The WARP / SOCKS / AmneziaWG
     * starts keep no retained full arg set to resume from.
     */
    private fun canPauseSession(): Boolean =
        !sessionWarpMode && !sessionSocksMode &&
            !sessionWgWstunnel &&
            !(chainUnderlay &&
                (sessionUnderlay == "psiphon" || sessionUnderlay == "dnstt" ||
                    sessionUnderlay == "olcrtc"))

    /**
     * Pause (build 2081, verification V-8, feature queue #8):
     * stops the core and the TUN like a disconnect, but the
     * service stays foreground with a Paused notification
     * carrying Resume — the session is held, not ended. A
     * deliberate pause releases a kill-switch hold exactly
     * like a manual stop does: traffic goes direct until the
     * user resumes or disconnects. Runs off the main thread
     * (ACTION_PAUSE handler).
     */
    private fun pauseTunnel() {
        if (!running || paused || !canPauseSession()) return
        stopping.set(true)
        stopUnderlay()
        stopProcesses()
        running = false
        blackholeHeld = false
        // Build 2125 (audit A25-02 / P-08): re-check AFTER
        // the coreLock block above. stopProcesses() can
        // block for ~20 s behind a restart; if the user
        // tapped Disconnect in that window, the ACTION_STOP
        // handler has already set userStopped (it does so
        // on the main thread, before queueing the stop on
        // actionWorker behind this pause). Publishing a
        // Paused state now would post a phantom Paused
        // notification whose Resume resurrects the session
        // the user just disconnected — instead the pause
        // lands as a plain down session and the queued
        // Stop completes the teardown.
        if (userStopped) {
            Log.i(TAG, "pause superseded by a user stop; not publishing Paused")
            return
        }
        paused = true
        shownSpeed = ""
        lastSpeedSample = null
        lastSpeedAtMs = 0L
        updateNotification(profileName)
    }

    /**
     * Resume (build 2081, verification V-8): restarts the
     * paused V2Ray session from the retained start args —
     * the same startTunnel a fresh connect runs, so a resume
     * is a fresh session on the same profile, not a half
     * restoration. A failed resume is a failed start: the
     * start's own net records it and the service tears down
     * instead of lingering paused. Runs off the main thread
     * (ACTION_RESUME handler).
     */
    private fun resumeTunnel() {
        // Build 2098 (post-2097 audit M18): the app lock
        // gates Resume — ConnectWidget.appLockEnabled reads
        // the same marker Dart maintains (SharedPreferences
        // "ember_widget", boolean "lock_enabled"). With the
        // lock on, Resume must not restart the tunnel behind
        // the PIN: return without resuming, leaving the
        // paused state and the notification exactly as they
        // are. (Pause and Stop stay ungated — they are the
        // safe direction.) The notification builder is the
        // user-facing half of the gate (verification V-2):
        // while the lock is on it points the Resume action
        // at the app instead of this service, so the tap
        // opens Ember for the unlock rather than landing on
        // this silent return; this check remains as the
        // backstop for a notification posted before the lock
        // was enabled.
        if (ConnectWidget.appLockEnabled(this)) return
        if (!paused) return
        val config = sessionConfig
        val name = profileName
        if (config.isEmpty() || name.isEmpty()) {
            // Nothing retained to resume from (the service was
            // recreated without a session): end the stale
            // pause instead of starting an empty tunnel.
            stopTunnel()
            return
        }
        try {
            startTunnel(
                config, name, sessionPort, sessionDns, sessionIpv6,
                sessionMtu, sessionUnderlay, sessionUnderlayRegion,
                sessionUnderlayUpstream, sessionUnderlayProtocols,
                sessionWarpArgs, sessionSocksUser, sessionSocksPass,
                sessionDnsttArgs, sessionWgWstunnel, sessionWstunnelArgs,
                sessionOlcrtcArgs, sessionBridge,
            )
        } catch (e: Throwable) {
            startFailed("XrayVpnService.resumeTunnel", e)
        }
    }

    /**
     * Samples the session traffic and refreshes the
     * notification's live speed line (build 2081, V-8).
     * Rates come from the UID counters' delta over the tick
     * interval — the same source the Dart side's rates use.
     * A re-post happens only when the line changed (the
     * CoreService pattern: a notification re-posted on every
     * tick would churn the shade for nothing). A tick racing
     * a pause is harmless: the guard returns once the
     * session is down, and notification() renders from the
     * live flags, so a stale post can only ever show the
     * Paused text.
     */
    private fun refreshSpeedLine() {
        if (paused || !running) return
        val now = System.currentTimeMillis()
        val sample = sessionTraffic()
        val last = lastSpeedSample
        val lastAt = lastSpeedAtMs
        if (last != null && lastAt > 0) {
            val dtSec = (now - lastAt) / 1000.0
            if (dtSec > 0) {
                val down = ((sample.second - last.second) / dtSec).toLong().coerceAtLeast(0)
                val up = ((sample.first - last.first) / dtSec).toLong().coerceAtLeast(0)
                val line = "Down ${rateText(down)} · Up ${rateText(up)}"
                if (line != shownSpeed) {
                    shownSpeed = line
                    updateNotification(profileName)
                }
            }
        }
        lastSpeedSample = sample
        lastSpeedAtMs = now
    }

    /** "1.2 MB/s" / "340 KB/s" / "0 B/s" (build 2081, V-8). */
    private fun rateText(bytesPerSec: Long): String = when {
        bytesPerSec >= 1024 * 1024 ->
            String.format(Locale.US, "%.1f MB/s", bytesPerSec / 1048576.0)
        bytesPerSec >= 1024 -> "${bytesPerSec / 1024} KB/s"
        else -> "$bytesPerSec B/s"
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
        // The bridge first, so no new flows start while the core goes.
        // Build 2155: the hev bridge is in-process — its stop
        // quit+joins the tunnel thread synchronously, so it is
        // fully dead before the TUN closes below (hev closes
        // the dup'd fd it was handed; the service's own pfd
        // close is separate). Every stop path funnels through
        // here, which is what makes the single-instance guard
        // hold across engine switches. A no-op in every
        // session that never started hev (legacy bridge, WARP,
        // SOCKS): its running flag is only ever set by a hev
        // start.
        if (HevTunManager.isRunning) HevTunManager.stop()
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
        // Notification actions (build 2075, feature item 12):
        // Disconnect (above, every engine service carries it)
        // plus Switch server here — the one engine with
        // rotation semantics. The action opens the activity
        // with a rotate extra; MainActivity forwards it to
        // Dart, which performs the same switch as the in-app
        // control (the service itself cannot know the next
        // config — the fallback group lives in Dart).
        val rotate = PendingIntent.getActivity(
            this, 12,
            // Build 2095 (audit 5-9): nonce-stamped, like
            // every legitimate command intent.
            EmberIntentNonce.stamp(
                this,
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    .putExtra("ember_action", "rotate"),
            ),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        // Pause / Resume (build 2081, verification V-8): the
        // actions go straight to this service — unlike Rotate,
        // no Dart knowledge is needed (the session restarts
        // from the retained start args). A session that cannot
        // pause (below) never shows the action.
        val pause = PendingIntent.getService(
            this, 13, Intent(this, XrayVpnService::class.java).setAction(ACTION_PAUSE),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val resume = PendingIntent.getService(
            this, 14, Intent(this, XrayVpnService::class.java).setAction(ACTION_RESUME),
            PendingIntent.FLAG_IMMUTABLE,
        )
        // Kill switch (build 2063): while the blackhole is
        // held the notification says so — a stale "V2Ray · name"
        // over a dead tunnel would be a lie.
        // Build 2081 (verification V-8): the live speed line
        // rides the collapsed line beside the name (the
        // CoreService pattern — the speed beside the place),
        // in words, never ↓/↑ glyphs (verification V-1: they
        // render as missing-glyph boxes on this device's font);
        // BigTextStyle carries the same text expanded. A paused
        // session says so instead of naming a dead tunnel.
        // Build 2095 (whole-app journey audit #23): the
        // label names the engine this session actually is —
        // this service also carries the Aether slots' SOCKS
        // tunnels and EmberWarp sessions, and their
        // notifications used to say "V2Ray".
        val engineLabel = when {
            sessionSocksMode -> when (sessionSocksEngine) {
                "masque" -> "MASQUE"
                else -> "WARP"
            }
            sessionWarpMode -> "EmberWarp"
            else -> "V2Ray"
        }
        val text = if (blocked) "Kill switch active — traffic blocked"
            else if (paused) "Paused — $engineLabel · $name"
            else if (name.isEmpty()) getString(R.string.notification_connecting)
            else if (shownSpeed.isEmpty()) "$engineLabel · $name"
            else "$engineLabel · $name  ·  $shownSpeed"
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val withActions = builder
            .setSmallIcon(R.drawable.ic_stat_logo)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        // A paused session offers Resume, not Pause or Switch
        // (there is no core to rotate while paused); a running
        // session that cannot pause offers Disconnect + Switch
        // exactly as before.
        if (paused) {
            // Build 2098 (verification V-2): with the app lock
            // on, Resume must not restart the tunnel behind
            // the PIN — but pointing the action at the gated
            // service made it a permanently dead button for
            // every lock user (the gate reads "lock enabled",
            // never "currently locked", and offered no path
            // forward). Like the home widget and the QS tile,
            // the action then opens the app instead — the
            // user unlocks and resumes there. resumeTunnel
            // keeps its own gate as the backstop for a
            // notification posted before the lock was enabled.
            val resumeAction = if (ConnectWidget.appLockEnabled(this)) open else resume
            withActions.addAction(Notification.Action.Builder(null, getString(R.string.notification_resume), resumeAction).build())
            withActions.addAction(Notification.Action.Builder(null, getString(R.string.notification_stop), stop).build())
        } else {
            if (canPauseSession()) {
                withActions.addAction(Notification.Action.Builder(null, getString(R.string.notification_pause), pause).build())
            }
            withActions.addAction(Notification.Action.Builder(null, getString(R.string.notification_stop), stop).build())
            withActions.addAction(Notification.Action.Builder(null, getString(R.string.notification_rotate), rotate).build())
        }
        return withActions.build()
    }

    companion object {
        const val ACTION_START = "com.ralysnd.ember.XRAY_START"
        const val ACTION_STOP = "com.ralysnd.ember.XRAY_STOP"
        const val ACTION_ROTATE = "com.ralysnd.ember.XRAY_ROTATE"
        const val ACTION_START_WARP = "com.ralysnd.ember.XRAY_START_WARP"
        const val ACTION_START_SOCKS = "com.ralysnd.ember.XRAY_START_SOCKS"
        // Pause / Resume (build 2081, verification V-8): the
        // notification's Pause stops the core and the TUN while
        // the service stays foreground; Resume restarts the
        // same session from the retained start args.
        const val ACTION_PAUSE = "com.ralysnd.ember.XRAY_PAUSE"
        const val ACTION_RESUME = "com.ralysnd.ember.XRAY_RESUME"
        private const val EXTRA_CONFIG = "config"
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
        // OLCRTC underlay (build 2134).
        private const val EXTRA_OLCRTC_ARGS = "olcrtcArgs"
        private const val EXTRA_BRIDGE = "bridge"
        private const val EXTRA_WG_WSTUNNEL = "wgWstunnel"
        private const val EXTRA_WSTUNNEL_ARGS = "wstunnelArgs"
        private const val EXTRA_ENGINE = "engine"
        private const val EXTRA_MTU = "mtu"

        private const val CHANNEL = "xray_status"
        private const val NOTIFICATION_ID = 2
        private const val TAG = "XrayVpnService"
        private const val MTU = 1500

        /** Build 2080: the initial ChainSupervisor grace for a
         *  warp-chained session — sized to the core's chained
         *  greeting budget (EmberWarpCore.CHAIN_GREETING_WAIT_MS,
         *  150 s): a cold chained scan validates through the
         *  exit-node and must be allowed to finish before any
         *  failure is counted against it. */
        private const val WARP_CHAIN_INITIAL_GRACE_MS = 150_000L

        /** Build 2134: the initial ChainSupervisor grace for
         *  an OLCRTC-chained session — the client must join
         *  the SFU room, find its peer and bring the WebRTC
         *  link up before its SOCKS listener even exists, so
         *  the grace matches OlcrtcCore's probe window. */
        private const val OLCRTC_CHAIN_INITIAL_GRACE_MS = 120_000L

        /** Clamps a tunnel MTU to the offered range (build 2038,
         *  queue 2f): 1280 is the IPv6 minimum MTU (the floor),
         *  1500 the default ceiling. A corrupt or out-of-range
         *  value clamps instead of breaking a connect. */
        private fun clampMtu(mtu: Int) = mtu.coerceIn(1280, 1500)

        @Volatile
        var running = false
            private set

        /**
         * Paused (build 2081, verification V-8): the tunnel was
         * stopped from its notification Pause action while the
         * service stays foreground with a Resume action — a held
         * session, not a drop. Reported in xrayState so the Dart
         * poll does not treat it as an unexpected disconnect.
         * Cleared by a fresh start, a resume, or a full stop.
         */
        @Volatile
        var paused = false
            internal set

        /**
         * Stopped by the user (build 2087, analysis A2): the
         * last stop arrived through ACTION_STOP — the
         * notification's Disconnect action, or the app's own
         * stop, which the companion [stop] funnels through the
         * same action — rather than through a drop or a
         * failure. Reported in xrayState so the Dart poll ends
         * the auto-reconnect expectation instead of treating
         * the stop as an unexpected drop and resurrecting a
         * session the user ended. Set in the ACTION_STOP
         * handler, before the stop runs; cleared by any fresh
         * start. Deliberately NOT cleared by stopTunnel — the
         * handler sets it precisely because that stop is about
         * to run, and the poll must still see it afterwards.
         */
        @Volatile
        var userStopped = false
            internal set

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
            // OLCRTC underlay (build 2134): the client's
            // argument list, kept for supervision + respawn.
            olcrtcArgs: List<String> = emptyList(),
            // Tunnel bridge (build 2155, the 2153 swap):
            // 'hev' or 'tunlink' — XraySettings.v2rayBridge
            // via the xraySetOn 'bridge' argument.
            bridge: String = "hev",
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
                putStringArrayListExtra(EXTRA_OLCRTC_ARGS, ArrayList(olcrtcArgs))
                putExtra(EXTRA_BRIDGE, bridge)
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
