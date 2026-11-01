package com.ralysnd.ember

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.LocalServerSocket
import android.net.LocalSocket
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
 * The WARP+ engine's VPN service. Like the Xray engine, the core is a
 * plain executable subprocess (jniLibs/libwarpplus.so — bepass-org/
 * warp-plus, pinned tag v1.2.6, built with its declared Go 1.22.10
 * toolchain) and the same libtunlink helper bridges this service's
 * TUN device to the core's local SOCKS5 proxy (127.0.0.1:8086).
 *
 * warp-plus self-registers an anonymous Cloudflare WARP identity on
 * first run and keeps it in its cache dir — pointed at this engine's
 * own files dir, so the identity survives restarts and no account or
 * key is ever entered. The binary serves its proxy only AFTER its
 * own tunnel connectivity test passes, so "the SOCKS port is open"
 * is this service's connected signal.
 *
 * Modes map 1:1 onto the binary's flags: standard, --gool (WARP in
 * WARP), --cfon --country XX (the binary's OWN embedded Psiphon
 * carries the WARP handshake — separate from Ember's Psiphon mode),
 * and --scan (endpoint scan before connecting), which combines with
 * any mode. The pinned release has no MASQUE option; the protocol
 * is WireGuard.
 *
 * The whole app is disallowed from its own VPN so the subprocesses'
 * sockets reach the internet directly; per-app routing reuses
 * CoreService's stored choice, like the other engines.
 */
class WarpVpnService : VpnService() {

    private val worker = Executors.newSingleThreadExecutor()
    private val stopping = AtomicBoolean(false)

    private var warpProcess: Process? = null
    private var tunProcess: Process? = null
    private var tunPfd: ParcelFileDescriptor? = null
    private var serverSocket: LocalServerSocket? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val mode = intent.getStringExtra(EXTRA_MODE) ?: MODE_STANDARD
                val scan = intent.getBooleanExtra(EXTRA_SCAN, false)
                val country = intent.getStringExtra(EXTRA_COUNTRY) ?: "DE"
                val endpoint = intent.getStringExtra(EXTRA_ENDPOINT) ?: ""
                val dns = intent.getStringExtra(EXTRA_DNS) ?: "1.1.1.1"
                startInForeground(modeLabel(mode, scan))
                worker.execute { startTunnel(mode, scan, country, endpoint, dns) }
                return START_STICKY
            }
            else -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }
    }

    override fun onRevoke() {
        stopTunnel()
    }

    override fun onDestroy() {
        stopProcesses()
        super.onDestroy()
    }

    private fun startTunnel(mode: String, scan: Boolean, country: String, endpoint: String, dns: String) {
        stopping.set(false)
        failed = false
        failureMessage = ""
        connected = false
        starting = true
        try {
            val dir = workDir(this)
            dir.mkdirs()

            // 1. The warp-plus core subprocess. Its identity (the
            //    anonymous WARP registration) lives in <dir>/primary
            //    via --cache-dir, so it persists across restarts.
            val args = mutableListOf(
                libPath("libwarpplus.so"),
                "--bind", "127.0.0.1:$SOCKS_PORT",
                "--cache-dir", dir.absolutePath,
                "--dns", dns,
            )
            if (scan) {
                args += listOf("--scan", "--rtt", "1000ms")
            }
            when (mode) {
                MODE_GOOL -> args += "--gool"
                MODE_CFON -> args += listOf("--cfon", "--country", country)
            }
            if (endpoint.isNotEmpty()) {
                args += listOf("--endpoint", endpoint)
            }
            val warpLog = File(dir, "warp.log")
            warpProcess = ProcessBuilder(args)
                .directory(dir)
                .redirectErrorStream(true)
                .redirectOutput(ProcessBuilder.Redirect.appendTo(warpLog))
                .start()

            // Registration + handshake + the core's own connectivity
            // test all precede the proxy; scanning and the cfon
            // bootstrap take longer still.
            val timeout = if (scan || mode == MODE_CFON) 150_000L else 90_000L
            if (!waitForPort(SOCKS_PORT, timeout)) {
                Log.e(TAG, "warp-plus did not open its SOCKS port")
                if (warpProcess?.isAlive != true) {
                    failed = true
                    failureMessage = "core-exited"
                } else {
                    failed = true
                    failureMessage = "core-timeout"
                }
                fail()
                return
            }
            connected = true

            // 2. The VPN interface (same fd-handoff pattern as the
            //    Xray service; see createFdListener's note there).
            if (prepare(this) != null) {
                Log.w(TAG, "the VPN has no permission")
                fail()
                return
            }
            val builder = Builder()
                .setSession(getString(R.string.app_name))
                .setMtu(MTU)
                .addAddress("10.10.16.1", 30)
                .addRoute("0.0.0.0", 0)
                .addDnsServer(dns)
                .addAddress("fdfe:dcba:9876::1", 126)
                .addRoute("::", 0)
            applyApps(builder)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
            val pfd = builder.establish()
            if (pfd == null) {
                Log.e(TAG, "establish() returned null")
                fail()
                return
            }
            tunPfd = pfd

            // 3. The fd listener the helper connects to.
            val socketFile = File(dir, "tun.sock")
            socketFile.delete()
            val server = LocalServerSocket(socketFile.absolutePath)
            serverSocket = server

            // 4. The tun2socks helper subprocess.
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

            // 5. Hand the TUN fd over.
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
            starting = false
            modeName = modeLabel(mode, scan)
            startedAtMs = System.currentTimeMillis()
            val uid = android.os.Process.myUid()
            baseTx = TrafficStats.getUidTxBytes(uid)
            baseRx = TrafficStats.getUidRxBytes(uid)
            updateNotification(modeName)
            watchProcesses()
        } catch (e: Exception) {
            Log.e(TAG, "the WARP tunnel did not start", e)
            failed = true
            failureMessage = "start-error"
            fail()
        }
    }

    /** Which apps use the VPN: the same stored choice as the other engines'. */
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

    /** Ends the tunnel when either subprocess dies on its own. */
    private fun watchProcesses() {
        worker.execute {
            while (!stopping.get() && running) {
                val w = warpProcess
                val t = tunProcess
                if (w != null && !w.isAlive) {
                    Log.e(TAG, "warp-plus exited (${w.exitValue()})")
                    failed = true
                    failureMessage = "core-exited"
                    stopTunnel()
                    return@execute
                }
                if (t != null && !t.isAlive) {
                    Log.e(TAG, "tunlink exited (${t.exitValue()})")
                    stopTunnel()
                    return@execute
                }
                try {
                    Thread.sleep(1000)
                } catch (e: InterruptedException) {
                    return@execute
                }
            }
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
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val w = warpProcess
            if (w != null && !w.isAlive) return false
            if (stopping.get()) return false
            try {
                Socket().use { s ->
                    s.connect(InetSocketAddress("127.0.0.1", port), 300)
                    return true
                }
            } catch (e: Exception) {
                try {
                    Thread.sleep(150)
                } catch (ie: InterruptedException) {
                    return false
                }
            }
        }
        return false
    }

    private fun fail() {
        stopProcesses()
        running = false
        connected = false
        starting = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun stopTunnel() {
        stopping.set(true)
        stopProcesses()
        running = false
        connected = false
        starting = false
        modeName = ""
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
        // The bridge first, so no new flows start while the core goes.
        tunProcess?.let { kill(it) }
        tunProcess = null
        warpProcess?.let { kill(it) }
        warpProcess = null
        try {
            tunPfd?.close()
        } catch (e: Exception) {
            // Already closed.
        }
        tunPfd = null
    }

    private fun kill(p: Process) {
        try {
            p.destroy()
            if (!waitExit(p, 400)) p.destroyForcibly()
        } catch (e: Exception) {
            // Already gone.
        }
    }

    private fun waitExit(p: Process, timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (!p.isAlive) return true
            try {
                Thread.sleep(30)
            } catch (e: InterruptedException) {
                return !p.isAlive
            }
        }
        return !p.isAlive
    }

    private fun libPath(name: String): String =
        File(applicationInfo.nativeLibraryDir, name).absolutePath

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

    private fun updateNotification(name: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(name))
    }

    private fun notification(name: String): Notification {
        val open = PendingIntent.getActivity(
            this, 50, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 51, Intent(this, WarpVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val text = if (name.isEmpty()) getString(R.string.notification_connecting) else "WARP+ · $name"
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
        const val ACTION_START = "com.ralysnd.ember.WARP_START"
        const val ACTION_STOP = "com.ralysnd.ember.WARP_STOP"
        private const val EXTRA_MODE = "mode"
        private const val EXTRA_SCAN = "scan"
        private const val EXTRA_COUNTRY = "country"
        private const val EXTRA_ENDPOINT = "endpoint"
        private const val EXTRA_DNS = "dns"

        const val MODE_STANDARD = "standard"
        const val MODE_GOOL = "gool"
        const val MODE_CFON = "cfon"

        const val SOCKS_PORT = 8086

        private const val CHANNEL = "warp_status"
        private const val NOTIFICATION_ID = 5
        private const val TAG = "WarpVpnService"
        private const val MTU = 1500

        @Volatile
        var running = false
            private set

        /** The core subprocess is up but has not served its proxy yet
         *  (registration / scan / handshake can take a while). */
        @Volatile
        var starting = false
            private set

        /** The core passed its own connectivity test and serves its proxy. */
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
        var modeName = ""
            private set

        @Volatile
        var startedAtMs = 0L
            private set

        @Volatile
        private var baseTx = -1L

        @Volatile
        private var baseRx = -1L

        /** The WARP mode's files: identity (primary/), logs, the fd socket. */
        fun workDir(context: Context): File = File(context.filesDir, "warp")

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

        fun modeLabel(mode: String, scan: Boolean): String {
            val base = when (mode) {
                MODE_GOOL -> "WARP in WARP"
                MODE_CFON -> "Psiphon chain"
                else -> "WARP"
            }
            return if (scan) "$base · Scan" else base
        }

        fun start(context: Context, mode: String, scan: Boolean, country: String, endpoint: String, dns: String) {
            // A fresh start clears the previous run's failure.
            failed = false
            failureMessage = ""
            val intent = Intent(context, WarpVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_MODE, mode)
                putExtra(EXTRA_SCAN, scan)
                putExtra(EXTRA_COUNTRY, country)
                putExtra(EXTRA_ENDPOINT, endpoint)
                putExtra(EXTRA_DNS, dns)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, WarpVpnService::class.java).setAction(ACTION_STOP)
            try {
                context.startService(intent)
            } catch (e: Exception) {
                context.stopService(Intent(context, WarpVpnService::class.java))
            }
        }
    }
}
