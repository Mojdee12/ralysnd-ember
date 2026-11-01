package com.ralysnd.ember

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.IpPrefix
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import lantern.io.libbox.Notification as LibboxNotification
import lantern.io.libbox.TunOptions
import lantern.io.mobile.Mobile
import lantern.io.utils.FlutterEvent
import lantern.io.utils.FlutterEventEmitter
import lantern.io.utils.Opts

/**
 * The Lantern engine's service. The core is Lantern v10's Radiance
 * stack (radiance + its sing-box fork), shipped as a gomobile AAR
 * (libs/lantern.aar, built from the getlantern/lantern monorepo's
 * own recipe) and bound with the core's `novpn` tag: the box has no
 * TUN inbound, only the mixed SOCKS/HTTP inbound on 127.0.0.1:1080.
 * So — exactly like the Xray and Psiphon engines — this service
 * builds the TUN itself and bridges it to the core's SOCKS with the
 * shared libtunlink helper, while the core runs in this process and
 * calls back into the platform half in LanternPlatform.kt (the
 * libbox PlatformInterface: interface monitor, local DNS, socket
 * protection).
 *
 * Free plan only: no account, no user config, the core picks the
 * server. Radiance is set up once per process (its own contract);
 * later starts reuse it.
 *
 * 2012: the start path is self-diagnosing after the 2011 build
 * failed on-device leaving only session headers in this service's
 * log. Every setup phase logs begin/ok, a watchdog heartbeats the
 * current phase every 5s while a blocking native call is in
 * flight, the previous run's core crash log is folded into this
 * log at session start, an uncaught-exception handler records
 * deaths on foreign threads, and all failure branches log a
 * concrete reason (see BUILD-LOG-2.md, build 2012).
 *
 * 2015: this service runs in its own process (:lantern) — the
 * 2014 build still died inside Opts()/native init with the whole
 * process vanishing, and three Go runtimes (Mozilla, Psiphon,
 * Lantern) shared the main process. Consequences, all handled
 * below: state is published to lantern-state.json for the UI
 * process to read (the statics stay, but only this process reads
 * them now), a pending-start marker lets the next start name a
 * previous silent process death in the log, a stop in a process
 * that never loaded the core no longer touches the binding, and
 * the core itself was rebound against the same x/mobile version
 * as the proven Mozilla core (see BUILD-LOG-2.md, build 2015).
 *
 * Per-app routing reuses the Mozilla service's stored choice
 * (CoreService's prefs), so one app-routing setting governs all
 * four engines.
 */
class LanternVpnService : VpnService(), LanternPlatformImpl {

    override val platformContext: Context get() = this

    private val worker = Executors.newSingleThreadExecutor()
    private val stopper = Executors.newSingleThreadExecutor()

    /** The state/helper watch loops live on their own thread: they
     * run for the whole session and must never starve [worker]
     * (which carries starts and core-requested restarts). */
    private val watcher = Executors.newSingleThreadExecutor()
    private val stopping = AtomicBoolean(false)

    private var tunProcess: Process? = null
    private var tunPfd: ParcelFileDescriptor? = null
    private var serverSocket: LocalServerSocket? = null

    /** The TUN the core asked for via openTun, if it ever does (the
     * novpn box never does; kept so the callback stays honest). */
    private var coreTunPfd: ParcelFileDescriptor? = null

    private val logLock = Any()

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopper.execute { stopTunnel() }
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val dns = intent.getStringExtra(EXTRA_DNS) ?: "1.1.1.1"
                startInForeground()
                worker.execute { startTunnel(dns) }
                return START_STICKY
            }
            else -> {
                // Restarted by the system without an intent: there is
                // no run state to resume, so do not linger.
                stopSelf()
                return START_NOT_STICKY
            }
        }
    }

    override fun onRevoke() {
        stopper.execute { stopTunnel() }
    }

    override fun onDestroy() {
        stopProcesses()
        super.onDestroy()
    }

    // ---- core lifecycle -------------------------------------------------

    /** Which start phase is currently running (2012 diagnostics):
     * written into the log by the phase markers and the watchdog,
     * so a start that dies or wedges names the phase it died in. */
    @Volatile
    private var startPhase = "idle"

    private val watchdogActive = AtomicBoolean(false)

    /** A heartbeat for the start sequence: the native start calls
     * are blocking JNI calls that cannot be interrupted, so while
     * one is in flight this writes a line every 5s naming the phase
     * and the elapsed time. If the lines keep coming, the process
     * is alive and the named phase is stuck; if they stop mid-phase
     * and the next session begins, the process died in that phase. */
    private fun startWatchdog() {
        if (!watchdogActive.compareAndSet(false, true)) return
        val began = System.currentTimeMillis()
        val t = Thread {
            while (watchdogActive.get()) {
                try {
                    Thread.sleep(5000)
                } catch (e: InterruptedException) {
                    return@Thread
                }
                if (!watchdogActive.get()) break
                val elapsed = (System.currentTimeMillis() - began) / 1000
                logLine("still starting: phase=$startPhase, ${elapsed}s elapsed")
            }
        }
        t.isDaemon = true
        t.name = "lantern-start-watchdog"
        t.start()
    }

    private fun startTunnel(dns: String) {
        stopping.set(false)
        failed = false
        failureMessage = ""
        startPhase = "begin"
        // Platform-callback diagnostics land in the same service log.
        lanternPlatformLog = { line -> logLine("platform: $line") }
        try {
            val dir = workDir(this)
            dir.mkdirs()
            openLog(dir)
            logLine("start: log open")
            installUncaughtLogger()

            running = true
            connected = false
            startedAtMs = System.currentTimeMillis()
            serverJson = ""
            dataCapJson = ""
            publishState(this)

            startWatchdog()
            logLine("start: entering core setup")
            setupCore(dir)
            logLine("lantern core setup done; starting VPN")

            // Blocking: the core fetches its config and brings the
            // tunnel up before this returns (or throws). On a
            // censored network the bootstrap can take a while.
            startPhase = "startVPN"
            val vpnBegan = System.currentTimeMillis()
            Mobile.startVPN()
            logLine(
                "startVPN returned after " +
                    "${(System.currentTimeMillis() - vpnBegan) / 1000}s; " +
                    "connected=${try { Mobile.isVPNConnected() } catch (t: Throwable) { "?" }}",
            )
            if (stopping.get()) {
                watchdogActive.set(false)
                return
            }

            // The box's mixed inbound is the bridge's target; wait
            // for it before bridging the TUN to it.
            startPhase = "socksWait"
            if (!waitForPort(SOCKS_PORT, 30000)) {
                Log.e(TAG, "lantern did not open its SOCKS port")
                logLine("start failed in phase socksWait: core did not open its local proxy port within 30s")
                fail("core did not open its local proxy port")
                return
            }
            logLine("lantern SOCKS proxy is up on $SOCKS_PORT")
            startPhase = "tunBridge"

            if (prepare(this) != null) {
                Log.w(TAG, "the VPN has no permission")
                fail("the VPN has no permission")
                return
            }
            val builder = Builder()
                .setSession(getString(R.string.app_name))
                .setMtu(MTU)
                .addAddress("10.10.15.1", 30)
                .addRoute("0.0.0.0", 0)
                .addDnsServer(dns)
                .addAddress("fdfe:dcba:9876::1", 126)
                .addRoute("::", 0)
            applyApps(builder)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
            val pfd = builder.establish()
            if (pfd == null) {
                Log.e(TAG, "establish() returned null")
                fail("establish() returned null")
                return
            }
            tunPfd = pfd

            // The fd listener the helper connects to. Same agreement
            // as the other engines: the listener binds the abstract
            // namespace under this path string, and the helper dials
            // the abstract name with retries.
            val socketFile = File(dir, "tun.sock")
            socketFile.delete()
            val server = LocalServerSocket(socketFile.absolutePath)
            serverSocket = server

            val tunLog = File(dir, "tunlink.log")
            tunProcess = ProcessBuilder(
                libPath("libtunlink.so"),
                "-socket", socketFile.absolutePath,
                "-proxy", "socks5://127.0.0.1:$SOCKS_PORT",
                "-mtu", MTU.toString(),
                "-loglevel", "warn",
            )
                .directory(dir)
                .redirectErrorStream(true)
                .redirectOutput(ProcessBuilder.Redirect.appendTo(tunLog))
                .start()

            val accepted = acceptWithTimeout(server, 15000)
            if (accepted == null) {
                Log.e(TAG, "the helper did not connect for the TUN fd")
                fail("the TUN bridge did not connect")
                return
            }
            accepted.use { socket ->
                socket.setFileDescriptorsForSend(arrayOf(pfd.fileDescriptor))
                socket.outputStream.write(1)
                socket.outputStream.flush()
            }
            server.close()
            serverSocket = null
            startPhase = "up"
            watchdogActive.set(false)
            updateNotification()
            // The start concluded: clear the pending-start marker
            // (2015) so a later start does not mistake this session
            // for a process that died mid-init.
            clearPendingStart(this)
            publishState(this)
            watchLoops()
        } catch (e: Throwable) {
            // Throwable, not Exception (2012): an Error escaping a
            // gomobile call must still be named in the log instead
            // of taking the start down silently.
            Log.e(TAG, "the Lantern tunnel did not start", e)
            logLine("start failed in phase $startPhase: ${e.javaClass.name}: ${e.message}")
            try {
                logLine(Log.getStackTraceString(e).take(3000))
            } catch (t: Throwable) {
                // Logging must never break the failure path.
            }
            watchdogActive.set(false)
            fail(e.message ?: "start failed")
        }
    }

    /** One-time-per-process core setup, in the official client's
     * order: logging, the IPC server (which builds the backend),
     * then Radiance itself. Each call is bracketed with begin/ok
     * lines (2012): the 2011 build died somewhere inside this
     * sequence leaving only the session header, so the phases now
     * name themselves in lantern-service.log. */
    private fun setupCore(dir: File) {
        synchronized(coreLock) {
            if (coreReady) {
                logLine("core setup: already initialized in this process")
                return
            }
            logLine("core setup: buildOpts begin")
            coreLoaded = true
            val opts = buildOpts(dir)
            logLine("core setup: buildOpts ok")
            setupPhase("initLogging") {
                Mobile.initLogging(dir.absolutePath, dir.absolutePath, "info")
            }
            setupPhase("startIPCServer") {
                Mobile.startIPCServer(this, opts)
            }
            setupPhase("setupRadiance") {
                Mobile.setupRadiance(opts, eventEmitter)
            }
            coreReady = true
            logLine("core setup: all phases ok")
        }
    }

    private fun setupPhase(name: String, block: () -> Unit) {
        startPhase = "setup:$name"
        logLine("core setup: $name begin")
        val began = System.currentTimeMillis()
        block()
        logLine("core setup: $name ok (${System.currentTimeMillis() - began} ms)")
    }

    private fun buildOpts(dir: File): Opts {
        val opts = Opts()
        logLine("core setup: Opts constructed")
        opts.dataDir = dir.absolutePath
        opts.logDir = dir.absolutePath
        opts.logLevel = "info"
        opts.deviceid = deviceId()
        opts.appVersion = try {
            packageManager.getPackageInfo(packageName, 0).versionName ?: ""
        } catch (e: Exception) {
            ""
        }
        opts.locale = Locale.getDefault().language
        opts.timeZone = TimeZone.getDefault().id
        // Ember does not phone home for a VPN engine the user picked
        // for privacy; the official client defaults its own way.
        opts.telemetryConsent = false
        // The official client passes "prod" here (its
        // getRadianceEnv()); "" only means "not staging" to the
        // core, but 2012 matches the known-good client exactly.
        opts.env = "prod"
        opts.platform = this
        return opts
    }

    /** A stable anonymous device id for the core's free-plan user,
     * minted once and kept in prefs. */
    private fun deviceId(): String {
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(KEY_DEVICE_ID, null)?.let { return it }
        val id = UUID.randomUUID().toString()
        prefs.edit().putString(KEY_DEVICE_ID, id).apply()
        return id
    }

    private val eventEmitter = object : FlutterEventEmitter {
        override fun sendEvent(event: FlutterEvent?) {
            // SendEvent has no error return on the Go side: nothing
            // may throw out of here (see LanternPlatform.kt header).
            try {
                if (event == null) return
                logLine("core event [${event.type}] ${event.message}")
            } catch (t: Throwable) {
                // Swallow: an event we couldn't log is not worth
                // the process.
            }
        }
    }

    /** Keeps the published state in step with the core (its tunnel
     * state, the server it landed on, the free plan's data cap) and
     * ends the tunnel if the TUN bridge dies on its own. */
    private fun watchLoops() {
        watcher.execute {
            var tick = 0
            while (!stopping.get() && running) {
                val t = tunProcess
                if (t != null && !t.isAlive) {
                    Log.e(TAG, "tunlink exited (${t.exitValue()})")
                    stopper.execute { stopTunnel() }
                    return@execute
                }
                if (tick % 2 == 0) {
                    try {
                        connected = Mobile.isVPNConnected()
                    } catch (e: Throwable) {
                        // A core mid-restart; the next tick retries.
                    }
                    // Also the published-state heartbeat (2015):
                    // its updatedAtMs is how the UI process tells a
                    // live session from a dead service process.
                    publishState(this)
                }
                if (tick % 16 == 0) {
                    serverJson = try {
                        Mobile.getSelectedServerJSON() ?: ""
                    } catch (e: Throwable) {
                        serverJson
                    }
                    dataCapJson = try {
                        Mobile.getDataCapInfo() ?: ""
                    } catch (e: Throwable) {
                        dataCapJson
                    }
                    updateNotification()
                }
                tick++
                try {
                    Thread.sleep(1000)
                } catch (e: InterruptedException) {
                    return@execute
                }
            }
        }
    }

    /** Which apps use the VPN: the same stored choice as the other engines. */
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

    private fun acceptWithTimeout(server: LocalServerSocket, timeoutMs: Long): LocalSocket? {
        var result: LocalSocket? = null
        val t = Thread {
            try {
                result = server.accept()
            } catch (e: Exception) {
                // Closed by the timeout below.
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
        val began = System.currentTimeMillis()
        val deadline = began + timeoutMs
        var lastLog = began
        while (System.currentTimeMillis() < deadline) {
            if (stopping.get()) return false
            try {
                Socket().use { s ->
                    s.connect(InetSocketAddress("127.0.0.1", port), 300)
                    return true
                }
            } catch (e: Exception) {
                val now = System.currentTimeMillis()
                if (now - lastLog >= 5000) {
                    lastLog = now
                    logLine("waiting for the core SOCKS port: ${(now - began) / 1000}s")
                }
                try {
                    Thread.sleep(120)
                } catch (ie: InterruptedException) {
                    return false
                }
            }
        }
        return false
    }

    private fun fail(message: String) {
        watchdogActive.set(false)
        failed = true
        failureMessage = message
        if (coreLoaded) {
            try {
                Mobile.stopVPN()
            } catch (e: Throwable) {
                // Already stopped.
            }
        }
        stopProcesses()
        running = false
        connected = false
        clearPendingStart(this)
        publishState(this)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun stopTunnel() {
        watchdogActive.set(false)
        if (!stopping.compareAndSet(false, true)) {
            // A stop is already under way; still make sure the
            // published state lands.
            running = false
            connected = false
            clearPendingStart(this)
            publishState(this)
            return
        }
        if (coreLoaded) {
            try {
                Mobile.stopVPN()
            } catch (e: Throwable) {
                // Already stopped.
            }
        }
        stopProcesses()
        running = false
        connected = false
        clearPendingStart(this)
        publishState(this)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    @Synchronized
    private fun stopProcesses() {
        try {
            serverSocket?.close()
        } catch (e: Exception) {
            // Already closed.
        }
        serverSocket = null
        try {
            File(workDir(this), "tun.sock").delete()
        } catch (e: Exception) {
            // Best effort only.
        }
        tunProcess?.let { p ->
            try {
                p.destroy()
                val deadline = System.currentTimeMillis() + 400
                while (p.isAlive && System.currentTimeMillis() < deadline) Thread.sleep(30)
                if (p.isAlive) p.destroyForcibly()
            } catch (e: Exception) {
                // Already gone.
            }
        }
        tunProcess = null
        try {
            tunPfd?.close()
        } catch (e: Exception) {
            // Already closed.
        }
        tunPfd = null
        try {
            coreTunPfd?.close()
        } catch (e: Exception) {
            // Already closed.
        }
        coreTunPfd = null
    }

    private fun libPath(name: String): String =
        File(applicationInfo.nativeLibraryDir, name).absolutePath

    // ---- the service's own log ------------------------------------------
    // The core writes its own log to lantern.log in the same dir
    // (its logDir); the service's lines and the core's events go to
    // lantern-service.log beside it.

    private fun openLog(dir: File) {
        synchronized(logLock) {
            try {
                val f = File(dir, "lantern-service.log")
                if (f.length() > 512 * 1024) {
                    f.renameTo(File(dir, "lantern-service.log.old"))
                }
                f.appendText("\n==== lantern session ${System.currentTimeMillis()} ====\n")
                val versionCode = try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        packageManager.getPackageInfo(packageName, 0).longVersionCode
                    } else {
                        @Suppress("DEPRECATION")
                        packageManager.getPackageInfo(packageName, 0).versionCode.toLong()
                    }
                } catch (e: Exception) {
                    -1L
                }
                f.appendText(
                    "device: ${Build.MANUFACTURER} ${Build.MODEL}, " +
                        "sdk ${Build.VERSION.SDK_INT}, app build $versionCode\n",
                )
                // The core's own crash file (radiance installs it as
                // Go's crash output at InitLogging): a Go panic in a
                // detached goroutine lands there and nowhere else.
                // The 2011 log viewer never showed this file, so a
                // crash there was invisible; copy its tail into this
                // log at the next session start, then clear it so it
                // is not copied twice. (Deleting is safe: the core
                // re-opens it at its next InitLogging, and an open
                // handle in a surviving process keeps its own inode.)
                val crash = File(dir, "lantern-crash.log")
                if (crash.exists() && crash.length() > 0) {
                    val bytes = crash.readBytes()
                    val tail = if (bytes.size > 8192) {
                        bytes.copyOfRange(bytes.size - 8192, bytes.size)
                    } else {
                        bytes
                    }
                    f.appendText("---- previous core crash log (lantern-crash.log) ----\n")
                    f.appendText(String(tail, Charsets.UTF_8))
                    f.appendText("\n---- end previous core crash log ----\n")
                    crash.delete()
                }
            } catch (e: Exception) {
                // Logging must never break the tunnel.
            }
        }
    }

    /** A process-wide uncaught-exception logger (2012): an
     * exception on a thread startTunnel doesn't own — the main
     * thread delivering a ConnectivityManager callback is the
     * classic case — otherwise kills the process with no trace in
     * any log we control. The handler appends the stack to
     * lantern-service.log, then delegates so the process still dies
     * the way the system expects. */
    private fun installUncaughtLogger() {
        if (uncaughtInstalled) return
        uncaughtInstalled = true
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                logLine(
                    "UNCAUGHT on thread ${thread.name}: " +
                        "${error.javaClass.name}: ${error.message}",
                )
                logLine(Log.getStackTraceString(error).take(4000))
            } catch (t: Throwable) {
                // The process is dying; nothing more to protect.
            }
            previous?.uncaughtException(thread, error)
        }
    }

    private fun logLine(line: String) {
        synchronized(logLock) {
            try {
                File(workDir(this), "lantern-service.log").appendText(line + "\n")
            } catch (e: Exception) {
                // As above.
            }
        }
    }

    // ---- libbox PlatformInterface: the service-side half ----------------
    // (LanternPlatform.kt carries the rest.)

    override fun autoDetectInterfaceControl(fd: Int) {
        // A gomobile callback: protect() must not throw out of it.
        try {
            protect(fd)
        } catch (t: Throwable) {
            logLine("platform: autoDetectInterfaceControl failed: $t")
        }
    }

    /**
     * The novpn box has no TUN inbound, so this is never called
     * with the shipped core. It stays a real implementation —
     * the official client's translation of TunOptions into a
     * Builder — rather than a stub that would fail mysteriously
     * if a future core asked.
     */
    override fun openTun(options: TunOptions): Int {
        val builder = Builder()
            .setSession(getString(R.string.app_name))
            .setMtu(options.mtu)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }
        val inet4Address = options.inet4Address
        while (inet4Address.hasNext()) {
            val address = inet4Address.next()
            builder.addAddress(address.address(), address.prefix())
        }
        val inet6Address = options.inet6Address
        while (inet6Address.hasNext()) {
            val address = inet6Address.next()
            builder.addAddress(address.address(), address.prefix())
        }
        builder.addDisallowedApplication(packageName)
        if (options.autoRoute) {
            builder.addDnsServer(options.dnsServerAddress.value)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val inet4RouteAddress = options.inet4RouteAddress
                if (inet4RouteAddress.hasNext()) {
                    while (inet4RouteAddress.hasNext()) {
                        builder.addRoute(inet4RouteAddress.next().toIpPrefix())
                    }
                } else if (options.inet4Address.hasNext()) {
                    builder.addRoute("0.0.0.0", 0)
                }
                val inet6RouteAddress = options.inet6RouteAddress
                if (inet6RouteAddress.hasNext()) {
                    while (inet6RouteAddress.hasNext()) {
                        builder.addRoute(inet6RouteAddress.next().toIpPrefix())
                    }
                } else if (options.inet6Address.hasNext()) {
                    builder.addRoute("::", 0)
                }
                val inet4RouteExcludeAddress = options.inet4RouteExcludeAddress
                while (inet4RouteExcludeAddress.hasNext()) {
                    builder.excludeRoute(inet4RouteExcludeAddress.next().toIpPrefix())
                }
                val inet6RouteExcludeAddress = options.inet6RouteExcludeAddress
                while (inet6RouteExcludeAddress.hasNext()) {
                    builder.excludeRoute(inet6RouteExcludeAddress.next().toIpPrefix())
                }
            } else {
                val inet4RouteAddress = options.inet4RouteRange
                if (inet4RouteAddress.hasNext()) {
                    while (inet4RouteAddress.hasNext()) {
                        val address = inet4RouteAddress.next()
                        builder.addRoute(address.address(), address.prefix())
                    }
                }
                val inet6RouteAddress = options.inet6RouteRange
                if (inet6RouteAddress.hasNext()) {
                    while (inet6RouteAddress.hasNext()) {
                        val address = inet6RouteAddress.next()
                        builder.addRoute(address.address(), address.prefix())
                    }
                }
            }
        }
        try {
            coreTunPfd?.close()
        } catch (e: Exception) {
            // Already closed.
        }
        val pfd = builder.establish()
            ?: error("android: the application is not prepared or is revoked")
        coreTunPfd = pfd
        return pfd.fd
    }

    override fun sendNotification(notification: LibboxNotification?) {
        // The foreground notification below carries the status; the
        // box's own notifications are informational only here.
        try {
            if (notification != null) {
                logLine("core notification: ${notification.title} ${notification.body}")
            }
        } catch (t: Throwable) {
            // A gomobile callback: never throw (see LanternPlatform.kt).
        }
    }

    // ---- utils.PlatformInterface extras ----------------------------------

    override fun restartService() {
        // Radiance asks for a tunnel restart (e.g. after a network
        // change): cycle the box; the TUN bridge stays up because
        // the SOCKS port returns with the box.
        worker.execute {
            try {
                Mobile.stopVPN()
                if (!stopping.get() && running) {
                    Mobile.startVPN()
                }
            } catch (e: Throwable) {
                Log.e(TAG, "restartService failed", e)
                logLine("restart failed: ${e.message}")
            }
        }
    }

    override fun postServiceClose() {
        // The box closed under us: the bridge has nothing to talk
        // to, so take the tunnel down. No error return on the Go
        // side: nothing may throw out of here.
        try {
            logLine("postServiceClose: core closed the box")
            if (!stopping.get()) {
                stopper.execute { stopTunnel() }
            }
        } catch (t: Throwable) {
            // Swallow (see above).
        }
    }

    // ---- notification ------------------------------------------------------

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
        try {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification())
        } catch (e: Exception) {
            // Not in the foreground (yet).
        }
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(
            this, 40, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 41, Intent(this, LanternVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_logo)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(if (connected) "Lantern · connected" else "Lantern")
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, getString(R.string.notification_stop), stop).build())
            .build()
    }

    companion object {
        const val ACTION_START = "com.ralysnd.ember.LANTERN_START"
        const val ACTION_STOP = "com.ralysnd.ember.LANTERN_STOP"
        private const val EXTRA_DNS = "dns"

        private const val CHANNEL = "lantern_status"
        private const val NOTIFICATION_ID = 4
        private const val TAG = "LanternVpnService"
        private const val MTU = 1500
        private const val PREFS = "lantern"
        private const val KEY_DEVICE_ID = "device_id"

        /** The novpn core's mixed SOCKS/HTTP inbound port (radiance
         * boxoptions_novpn.go's defaultSocksAddress). */
        const val SOCKS_PORT = 1080

        private val coreLock = Any()

        @Volatile
        private var coreReady = false

        /** True once this process has touched the binding (setupCore
         * entry). A stop that arrives in a process that never set
         * the core up must not call into Mobile: merely loading the
         * library is the expensive, fragile step (2015). */
        @Volatile
        private var coreLoaded = false

        @Volatile
        private var uncaughtInstalled = false

        @Volatile
        var running = false
            private set

        @Volatile
        var connected = false
            private set

        @Volatile
        var failed = false
            private set

        @Volatile
        var failureMessage = ""
            private set

        @Volatile
        var startedAtMs = 0L
            private set

        @Volatile
        var serverJson = ""
            private set

        @Volatile
        var dataCapJson = ""
            private set

        /** The Lantern mode's files: core data root and logs. */
        fun workDir(context: Context): File = File(context.filesDir, "lantern")

        // ---- cross-process state (2015) ------------------------------
        // The service runs in its own process (:lantern, see the
        // manifest), so the UI process cannot read the statics above
        // any more — separate heaps. The service publishes every
        // state change (and a 2s heartbeat while running) to a small
        // JSON file in the shared work dir; MainActivity's
        // lanternState handler reads it back with readPublishedState.

        private const val STATE_FILE = "lantern-state.json"
        private const val PENDING_FILE = "lantern-start-pending.txt"

        /** Snapshot the published state to the state file,
         * atomically (tmp + rename) so a reader never sees a torn
         * file. Best-effort: state publishing must never break the
         * tunnel. */
        fun publishState(context: Context) {
            try {
                val dir = workDir(context)
                dir.mkdirs()
                val json = org.json.JSONObject()
                    .put("running", running)
                    .put("connected", connected)
                    .put("failed", failed)
                    .put("failure", failureMessage)
                    .put("sinceMs", startedAtMs)
                    .put("server", serverJson)
                    .put("dataCap", dataCapJson)
                    .put("updatedAtMs", System.currentTimeMillis())
                    .toString()
                val tmp = File(dir, "$STATE_FILE.tmp")
                tmp.writeText(json)
                tmp.renameTo(File(dir, STATE_FILE))
            } catch (e: Exception) {
                // As above.
            }
        }

        /** The state as the UI process reports it: the published
         * file's contents, or the defaults when no file exists. A
         * file that claims a running session but whose heartbeat
         * (updatedAtMs) is stale means the service process is gone
         * (killed, or died mid-start) — report stopped rather than
         * a phantom session. */
        fun readPublishedState(context: Context): Map<String, Any> {
            var running = false
            var connected = false
            var failed = false
            var failure = ""
            var sinceMs = 0L
            var server = ""
            var dataCap = ""
            try {
                val f = File(workDir(context), STATE_FILE)
                if (f.exists()) {
                    val j = org.json.JSONObject(f.readText())
                    running = j.optBoolean("running")
                    connected = j.optBoolean("connected")
                    failed = j.optBoolean("failed")
                    failure = j.optString("failure")
                    sinceMs = j.optLong("sinceMs")
                    server = j.optString("server")
                    dataCap = j.optString("dataCap")
                    val updatedAt = j.optLong("updatedAtMs")
                    if (running && updatedAt > 0 &&
                        System.currentTimeMillis() - updatedAt > 10_000
                    ) {
                        running = false
                        connected = false
                    }
                }
            } catch (e: Exception) {
                // Corrupt or unreadable state: report the defaults.
            }
            return mapOf(
                "running" to running,
                "connected" to connected,
                "failed" to failed,
                "failure" to failure,
                "sinceMs" to sinceMs,
                "server" to server,
                "dataCap" to dataCap,
            )
        }

        /** The start concluded (up, failed, or stopped): the
         * pending-start marker's job is done. */
        fun clearPendingStart(context: Context) {
            try {
                File(workDir(context), PENDING_FILE).delete()
            } catch (e: Exception) {
                // Diagnostics only.
            }
        }

        fun start(context: Context, dns: String) {
            val dir = workDir(context)
            // Parent-side liveness note (2015): a pending-start
            // marker still on disk means the previous start's
            // service process never concluded — every conclusion
            // path (up, fail, stop) deletes it, so what remains is
            // a process that died silently, in this engine's case
            // inside native init before any logging existed. Name
            // it in the service log before this attempt overwrites
            // the marker.
            try {
                val pending = File(dir, PENDING_FILE)
                if (pending.exists()) {
                    dir.mkdirs()
                    File(dir, "lantern-service.log").appendText(
                        "previous lantern start: core process died " +
                            "during native init (no completion marker)\n",
                    )
                    pending.delete()
                }
                dir.mkdirs()
                pending.writeText(System.currentTimeMillis().toString())
            } catch (e: Exception) {
                // Diagnostics only; never block a start.
            }
            val intent = Intent(context, LanternVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_DNS, dns)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, LanternVpnService::class.java).setAction(ACTION_STOP)
            try {
                context.startService(intent)
            } catch (e: Exception) {
                context.stopService(Intent(context, LanternVpnService::class.java))
            }
        }
    }
}

/** A RoutePrefix from the core as an Android IpPrefix. */
private fun lantern.io.libbox.RoutePrefix.toIpPrefix(): IpPrefix =
    IpPrefix(InetAddress.getByName(address()), prefix())
