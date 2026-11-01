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

    private var xrayProcess: Process? = null
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
                val config = intent.getStringExtra(EXTRA_CONFIG) ?: ""
                val name = intent.getStringExtra(EXTRA_NAME) ?: ""
                val socksPort = intent.getIntExtra(EXTRA_SOCKS_PORT, 10808)
                val dns = intent.getStringExtra(EXTRA_DNS) ?: "1.1.1.1"
                val ipv6 = intent.getBooleanExtra(EXTRA_IPV6, true)
                if (config.isEmpty()) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                startInForeground(name)
                worker.execute { startTunnel(config, name, socksPort, dns, ipv6) }
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
        stopTunnel()
    }

    override fun onDestroy() {
        stopProcesses()
        super.onDestroy()
    }

    private fun startTunnel(configJson: String, name: String, socksPort: Int, dns: String, ipv6: Boolean) {
        stopping.set(false)
        try {
            val dir = workDir(this)
            dir.mkdirs()
            val configFile = File(dir, "config.json")
            configFile.writeText(configJson)

            // 1. The Xray core subprocess.
            val xrayLog = File(dir, "xray.log")
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

            // 2. The VPN interface.
            if (prepare(this) != null) {
                Log.w(TAG, "the VPN has no permission")
                fail()
                return
            }
            val builder = Builder()
                .setSession(getString(R.string.app_name))
                .setMtu(MTU)
                .addAddress("10.10.14.1", 30)
                .addRoute("0.0.0.0", 0)
                .addDnsServer(dns)
            if (ipv6) {
                builder.addAddress("fdfe:dcba:9876::1", 126)
                builder.addRoute("::", 0)
            }
            applyApps(builder)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
            val pfd = builder.establish()
            if (pfd == null) {
                Log.e(TAG, "establish() returned null")
                fail()
                return
            }
            tunPfd = pfd

            // 3. The fd listener the helper connects to — it receives
            //    the same socket string below (see createFdListener
            //    for the namespace both sides agree on).
            val socketFile = File(dir, "tun.sock")
            socketFile.delete()
            val server = createFdListener(socketFile)
            serverSocket = server

            // 4. The tun2socks helper subprocess.
            val tunLog = File(dir, "tunlink.log")
            tunProcess = ProcessBuilder(
                libPath("libtunlink.so"),
                "-socket", socketFile.absolutePath,
                "-proxy", "socks5://127.0.0.1:$socksPort",
                "-mtu", MTU.toString(),
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
        } catch (e: Exception) {
            Log.e(TAG, "the V2Ray tunnel did not start", e)
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

    /** Ends the tunnel when either subprocess dies on its own. */
    private fun watchProcesses() {
        worker.execute {
            while (!stopping.get() && running) {
                val x = xrayProcess
                val t = tunProcess
                if (x != null && !x.isAlive) {
                    Log.e(TAG, "xray exited (${x.exitValue()})")
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

    private fun fail() {
        stopProcesses()
        running = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun stopTunnel() {
        stopping.set(true)
        stopProcesses()
        running = false
        profileName = ""
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
        // A filesystem-namespace listener leaves its socket file
        // behind on close; remove it so no stale path lingers (the
        // next start deletes before binding anyway).
        try {
            File(workDir(this), "tun.sock").delete()
        } catch (e: Exception) {
            // Best effort only.
        }
        // The bridge first, so no new flows start while the core goes.
        tunProcess?.let { kill(it) }
        tunProcess = null
        xrayProcess?.let { kill(it) }
        xrayProcess = null
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
            this, 10, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 11, Intent(this, XrayVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val text = if (name.isEmpty()) getString(R.string.notification_connecting) else "V2Ray · $name"
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
        private const val EXTRA_CONFIG = "config"
        private const val EXTRA_NAME = "name"
        private const val EXTRA_SOCKS_PORT = "socksPort"
        private const val EXTRA_DNS = "dns"
        private const val EXTRA_IPV6 = "ipv6"

        private const val CHANNEL = "xray_status"
        private const val NOTIFICATION_ID = 2
        private const val TAG = "XrayVpnService"
        private const val MTU = 1500

        @Volatile
        var running = false
            private set

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

        fun start(context: Context, configJson: String, name: String, socksPort: Int, dns: String, ipv6: Boolean) {
            val intent = Intent(context, XrayVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_CONFIG, configJson)
                putExtra(EXTRA_NAME, name)
                putExtra(EXTRA_SOCKS_PORT, socksPort)
                putExtra(EXTRA_DNS, dns)
                putExtra(EXTRA_IPV6, ipv6)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
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
