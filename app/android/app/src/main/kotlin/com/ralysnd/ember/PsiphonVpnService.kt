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
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import ca.psiphon.PsiphonTunnel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The Psiphon engine's service. Unlike the Xray engine (plain
 * subprocesses), the Psiphon tunnel core is a gomobile library
 * (libs/psiphon.aar, shaded so its runtime can live beside the Mozilla
 * core's) that runs in this process, driven through Psiphon's own
 * PsiphonTunnel host wrapper with this service as its HostService.
 *
 * Two modes, chosen at start:
 *  - VPN mode: the core opens its local SOCKS proxy, this service
 *    establishes the TUN device, and the same libtunlink helper the
 *    Xray engine uses bridges TUN -> SOCKS. The core runs with
 *    setVpnMode(true), so every socket it opens is handed back here
 *    (bindToDevice) and protected from the VPN — and the whole app is
 *    disallowed from its own TUN, so nothing loops.
 *  - Proxy-only mode: no TUN at all; the core just serves its local
 *    SOCKS/HTTP proxies (127.0.0.1:11808 / 11809) for apps that point
 *    at them.
 *
 * Per-app routing reuses the Mozilla service's stored choice
 * (CoreService's prefs), so one app-routing setting governs all three
 * engines.
 */
class PsiphonVpnService : VpnService(), PsiphonTunnel.HostService {

    private val worker = Executors.newSingleThreadExecutor()
    private val stopping = AtomicBoolean(false)

    private var tunnel: PsiphonTunnel? = null
    private var tunProcess: Process? = null
    private var tunPfd: ParcelFileDescriptor? = null
    private var serverSocket: LocalServerSocket? = null

    /** The config JSON handed to the core, built at start. */
    @Volatile
    private var configJson = ""

    private val logLock = Any()

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val vpnMode = intent.getBooleanExtra(EXTRA_VPN_MODE, true)
                val region = intent.getStringExtra(EXTRA_REGION) ?: ""
                val upstream = intent.getStringExtra(EXTRA_UPSTREAM) ?: ""
                val protocols = intent.getStringArrayListExtra(EXTRA_PROTOCOLS) ?: arrayListOf()
                val dns = intent.getStringExtra(EXTRA_DNS) ?: "1.1.1.1"
                configJson = buildConfig(region, upstream, protocols)
                startInForeground()
                worker.execute { startTunnel(vpnMode, dns) }
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
        stopTunnel()
    }

    override fun onDestroy() {
        stopProcesses()
        super.onDestroy()
    }

    /** The production-shaped tunnel-core config (see PsiphonConstants). */
    private fun buildConfig(region: String, upstream: String, protocols: List<String>): String {
        val dir = workDir(this)
        dir.mkdirs()
        val cfg = JSONObject()
        cfg.put("ClientVersion", PsiphonConstants.CLIENT_VERSION)
        cfg.put("PropagationChannelId", PsiphonConstants.PROPAGATION_CHANNEL_ID)
        cfg.put("SponsorId", PsiphonConstants.SPONSOR_ID)
        cfg.put("RemoteServerListSignaturePublicKey", PsiphonConstants.REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY)
        cfg.put("ServerEntrySignaturePublicKey", PsiphonConstants.SERVER_ENTRY_SIGNATURE_PUBLIC_KEY)
        cfg.put("AdditionalParameters", PsiphonConstants.ADDITIONAL_PARAMETERS)
        cfg.put("DataRootDirectory", dir.absolutePath)
        cfg.put("LocalSocksProxyPort", PsiphonConstants.SOCKS_PORT)
        cfg.put("LocalHttpProxyPort", PsiphonConstants.HTTP_PORT)
        cfg.put("EmitDiagnosticNotices", true)
        cfg.put("EmitBytesTransferred", true)
        cfg.put("EgressRegion", region)
        if (upstream.isNotEmpty()) cfg.put("UpstreamProxyURL", upstream)
        if (protocols.isNotEmpty()) cfg.put("LimitTunnelProtocols", JSONArray(protocols))
        return cfg.toString()
    }

    private fun startTunnel(vpnMode: Boolean, dns: String) {
        stopping.set(false)
        try {
            val dir = workDir(this)
            dir.mkdirs()
            openLog(dir)

            val entries = assets.open(PsiphonConstants.EMBEDDED_SERVERS_ASSET)
                .bufferedReader().use { it.readText() }

            val t = PsiphonTunnel.newPsiphonTunnel(this)
            tunnel = t
            t.setVpnMode(vpnMode)
            running = true
            isVpnMode = vpnMode
            startedAtMs = System.currentTimeMillis()
            totalUp = 0
            totalDown = 0
            t.startTunneling(entries)
            logLine("psiphon core started (vpnMode=$vpnMode)")

            if (!vpnMode) {
                updateNotification()
                return
            }

            // The core opens its SOCKS listener as it starts; wait for
            // it before bridging the TUN to it.
            if (!waitForPort(PsiphonConstants.SOCKS_PORT, 20000)) {
                Log.e(TAG, "psiphon did not open its SOCKS port")
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
                fail()
                return
            }
            tunPfd = pfd

            // The fd listener the helper connects to. Same agreement
            // as the Xray service: the listener binds the abstract
            // namespace under this path string, and the helper dials
            // the filesystem path first, then the abstract name.
            val socketFile = File(dir, "tun.sock")
            socketFile.delete()
            val server = LocalServerSocket(socketFile.absolutePath)
            serverSocket = server

            val tunLog = File(dir, "tunlink.log")
            tunProcess = ProcessBuilder(
                libPath("libtunlink.so"),
                "-socket", socketFile.absolutePath,
                "-proxy", "socks5://127.0.0.1:${PsiphonConstants.SOCKS_PORT}",
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
            updateNotification()
            watchHelper()
        } catch (e: Exception) {
            Log.e(TAG, "the Psiphon tunnel did not start", e)
            logLine("start failed: ${e.message}")
            fail()
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

    /** Ends the tunnel if the TUN bridge dies on its own. */
    private fun watchHelper() {
        worker.execute {
            while (!stopping.get() && running) {
                val t = tunProcess
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
            if (stopping.get()) return false
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
        connected = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun stopTunnel() {
        stopping.set(true)
        try {
            tunnel?.stop()
        } catch (e: Exception) {
            // Already stopped.
        }
        tunnel = null
        stopProcesses()
        running = false
        connected = false
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
    }

    private fun libPath(name: String): String =
        File(applicationInfo.nativeLibraryDir, name).absolutePath

    // ---- the core's log ------------------------------------------------

    private fun openLog(dir: File) {
        synchronized(logLock) {
            try {
                val f = File(dir, "psiphon.log")
                if (f.length() > 512 * 1024) {
                    f.renameTo(File(dir, "psiphon.log.old"))
                }
                f.appendText("\n==== psiphon session ${System.currentTimeMillis()} ====\n")
            } catch (e: Exception) {
                // Logging must never break the tunnel.
            }
        }
    }

    private fun logLine(line: String) {
        synchronized(logLock) {
            try {
                File(workDir(this), "psiphon.log").appendText(line + "\n")
            } catch (e: Exception) {
                // As above.
            }
        }
    }

    // ---- PsiphonTunnel.HostService --------------------------------------

    override fun getContext(): Context = this

    override fun getPsiphonConfig(): String = configJson

    /**
     * The wrapper asks for "gojni", the stock gomobile library name —
     * but that name belongs to the Mozilla core's library in this app.
     * The Psiphon AAR here is shaded: its runtime package is pg (not
     * go) and its native library is libpsiphoncore.so, which is what
     * must load (its pg.Seq static init asks for the same name).
     */
    override fun loadLibrary(library: String) {
        System.loadLibrary("psiphoncore")
    }

    override fun bindToDevice(fileDescriptor: Long) {
        // Only meaningful while this service holds the VPN; the core
        // calls it for every socket it opens in VPN mode.
        if (!protect(fileDescriptor.toInt())) {
            throw Exception("protect($fileDescriptor) failed")
        }
    }

    override fun onDiagnosticMessage(message: String) {
        logLine(message)
    }

    override fun onAvailableEgressRegions(regions: List<String>) {
        availableRegions = regions
    }

    override fun onConnecting() {
        connected = false
    }

    override fun onConnected() {
        connected = true
        updateNotification()
    }

    override fun onClientRegion(region: String) {
        egressRegion = region
        updateNotification()
    }

    override fun onClientAddress(address: String) {
        clientAddress = address
    }

    override fun onBytesTransferred(sent: Long, received: Long) {
        // Deltas since the previous call (the core's contract).
        totalUp += sent
        totalDown += received
    }

    override fun onUpstreamProxyError(message: String) {
        logLine("upstream proxy error: $message")
    }

    override fun onExiting() {
        logLine("psiphon core exiting")
    }

    // ---- notification ----------------------------------------------------

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
            this, 20, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 21, Intent(this, PsiphonVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val region = egressRegion
        val text = when {
            !isVpnMode -> "Psiphon · proxy only"
            region.isNotEmpty() -> "Psiphon · $region"
            else -> "Psiphon"
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
        const val ACTION_START = "com.ralysnd.ember.PSIPHON_START"
        const val ACTION_STOP = "com.ralysnd.ember.PSIPHON_STOP"
        private const val EXTRA_VPN_MODE = "vpnMode"
        private const val EXTRA_REGION = "region"
        private const val EXTRA_UPSTREAM = "upstream"
        private const val EXTRA_PROTOCOLS = "protocols"
        private const val EXTRA_DNS = "dns"

        private const val CHANNEL = "psiphon_status"
        private const val NOTIFICATION_ID = 3
        private const val TAG = "PsiphonVpnService"
        private const val MTU = 1500

        @Volatile
        var running = false
            private set

        @Volatile
        var connected = false
            private set

        @Volatile
        var isVpnMode = true
            private set

        @Volatile
        var startedAtMs = 0L
            private set

        @Volatile
        var totalUp = 0L
            private set

        @Volatile
        var totalDown = 0L
            private set

        @Volatile
        var egressRegion = ""
            private set

        @Volatile
        var clientAddress = ""
            private set

        @Volatile
        var availableRegions: List<String> = emptyList()
            private set

        /** The Psiphon mode's files: core data root and logs. */
        fun workDir(context: Context): File = File(context.filesDir, "psiphon")

        fun start(
            context: Context,
            vpnMode: Boolean,
            region: String,
            upstream: String,
            protocols: List<String>,
            dns: String,
        ) {
            val intent = Intent(context, PsiphonVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_VPN_MODE, vpnMode)
                putExtra(EXTRA_REGION, region)
                putExtra(EXTRA_UPSTREAM, upstream)
                putStringArrayListExtra(EXTRA_PROTOCOLS, ArrayList(protocols))
                putExtra(EXTRA_DNS, dns)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, PsiphonVpnService::class.java).setAction(ACTION_STOP)
            try {
                context.startService(intent)
            } catch (e: Exception) {
                context.stopService(Intent(context, PsiphonVpnService::class.java))
            }
        }
    }
}
