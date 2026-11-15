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
import android.net.NetworkCapabilities
import android.net.TrafficStats
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.BufferedWriter
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStreamWriter
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.security.SecureRandom
import java.security.cert.X509Certificate
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The Lantern engine host (build 2024): the lanternproxy binary
 * (radiance, `novpn` build) as a SUBPROCESS, never an in-process
 * library — two gomobile Go runtimes in one process are
 * unsupported upstream, which is what killed the 2009–2018 AAR
 * route.
 *
 * [LanternCore] owns the process and its stdout contract (the
 * shape MLM's published driver speaks); stdout and stderr are
 * drained on SEPARATE threads into separate logs — readiness is
 * judged only from the stdout contract and the SOCKS port, so a
 * healthy core is never killed for stderr noise or stdout
 * silence between contract events.
 *
 * The VPN half mirrors XrayVpnService: the TUN fd is handed to
 * libtunlink.so (tun2socks) over a unix socket the service
 * listens on; the bridge's exit is the core's local SOCKS5
 * (127.0.0.1:20840). Loop prevention is the shared per-app
 * routing ([applyApps]): Ember's own package stays out of its
 * own TUN, so the core's direct sockets (config fetch, server
 * dials) never re-enter the tunnel.
 */
object LanternCore {
    const val SOCKS_PORT = 20840
    const val HTTP_PORT = 20841

    /**
     * Build 2052 (diagnosis Causes 1 + 5): ralysnd's Lantern
     * budgets, ported verbatim. A kept list listens in seconds
     * (20 s is for the one slow case — the Iran rule-set
     * download); a first list gets 20 s direct, then the WARP
     * leg on the running core's stdin, 240 s total, and the
     * data-path proof gets 45 s before the TUN goes up. The old
     * 45 s kill-everything budget strangled every cold start
     * before the first fetch could land.
     */
    const val WARM_LISTEN_MS = 20_000L
    const val COLD_DIRECT_MS = 20_000L
    const val COLD_GIVEUP_MS = 240_000L
    const val DATA_TIMEOUT_MS = 45_000L

    /** idle | starting | fetching | up | error */
    @Volatile var stage: String = "idle"
        private set
    @Volatile var servers: Int = -1
        private set
    @Volatile var exitCity: String = ""
        private set
    @Volatile var exitCountry: String = ""
        private set
    @Volatile var exitCode: String = ""
        private set
    @Volatile var exhausted: Boolean = false
        private set
    @Volatile var lastError: String? = null
        private set
    @Volatile var listening: Boolean = false
        private set

    /** Fired (from the waiter thread) when the process dies on its own. */
    @Volatile var onCoreExit: ((Int) -> Unit)? = null

    private var process: Process? = null
    private var stdin: BufferedWriter? = null
    private var stopping = false
    private val stdoutTail = ArrayDeque<String>()
    private val stderrTail = ArrayDeque<String>()

    fun workDir(context: Context): File = File(context.filesDir, "lantern")

    fun dataDir(context: Context): File = File(workDir(context), "v10")

    fun binary(context: Context): File =
        File(context.applicationInfo.nativeLibraryDir, "liblantern.so")

    fun isAlive(): Boolean = process?.isAlive == true

    fun stdoutTail(): List<String> = synchronized(stdoutTail) { stdoutTail.toList() }

    fun stderrTail(): List<String> = synchronized(stderrTail) { stderrTail.toList() }

    @Synchronized
    fun start(
        context: Context,
        smart: Boolean = false,
    ) {
        if (isAlive()) return
        val bin = binary(context)
        check(bin.exists()) { "liblantern.so missing from nativeLibraryDir" }
        val data = dataDir(context).apply { mkdirs() }
        val tmp = File(context.cacheDir, "lantern-tmp").apply { mkdirs() }
        val dns = systemDns(context)
        val args = mutableListOf(
            bin.absolutePath,
            "-socks", "127.0.0.1:$SOCKS_PORT",
            "-http", "127.0.0.1:$HTTP_PORT",
            "-configdir", data.absolutePath,
            "-control",
            // Build 2064: NO -version flag, ever. Ember used to
            // pass its OWN app version (2.2.0-<build>) here; the
            // core adopts it as its reported client version, and
            // Lantern's config service rejects it as a too-old
            // client (HTTP 400 "bad client factors: version
            // 2.2.0-2061 too old", owner's device log 2026-11-14)
            // — no config, no connect. ralysnd's working
            // LanternProcess passes no version at all, so the
            // core reports its own built-in Lantern version and
            // is accepted.
            "-sysdns", dns.joinToString(","),
        )
        // Build 2032: ralysnd's start flags — smart routing, the
        // core's own smart server choice. Build 2052 (diagnosis
        // Cause 2): the fetchvia/clientip start-flag bootstrap is
        // DELETED — it was never device-proven (ralysnd never
        // relies on it) and it cost a core restart per attempt.
        // The bootstrap leg now rides the RUNNING core's stdin
        // (`via HOST:PORT`, see sendVia), one process throughout.
        if (smart) args += "-smart"
        // The resolver for what the rules send direct — the
        // first non-bracketed (IPv4) entry when there is one,
        // ralysnd's rule.
        dns.firstOrNull { !it.startsWith("[") }?.let { args += listOf("-localdns", it) }
            ?: dns.firstOrNull()?.let { args += listOf("-localdns", it) }
        stage = "starting"
        servers = -1
        exitCity = ""; exitCountry = ""; exitCode = ""
        exhausted = false
        lastError = null
        listening = false
        stopping = false
        synchronized(stdoutTail) { stdoutTail.clear() }
        synchronized(stderrTail) { stderrTail.clear() }
        val stdoutLog = File(workDir(context), "lantern-stdout.log")
        val stderrLog = File(workDir(context), "lantern-stderr.log")
        val pb = ProcessBuilder(args)
            .directory(data)
            .redirectErrorStream(false)
        pb.environment()["TMPDIR"] = tmp.absolutePath
        // Radiance anchors a few relative paths at HOME; ralysnd
        // points it at the config dir's parent (filesDir/lantern),
        // not filesDir — one line, removes a class of
        // relative-path surprises (diagnosis minor item).
        pb.environment()["HOME"] = workDir(context).absolutePath
        val p = pb.start()
        process = p
        stdin = BufferedWriter(OutputStreamWriter(p.outputStream))
        Thread { drain(p.inputStream.bufferedReader(), stdoutLog, isStdout = true) }
            .apply { isDaemon = true; name = "lantern-stdout" }.start()
        Thread { drain(p.errorStream.bufferedReader(), stderrLog, isStdout = false) }
            .apply { isDaemon = true; name = "lantern-stderr" }.start()
        Thread {
            val code = runCatching { p.waitFor() }.getOrDefault(-1)
            val unexpected = synchronized(this@LanternCore) {
                val wasStopping = stopping
                if (process === p) {
                    process = null
                    stdin = null
                }
                !wasStopping
            }
            if (unexpected) {
                if (stage != "error") {
                    stage = "error"
                    lastError = "Lantern core exited (code $code)"
                }
                onCoreExit?.invoke(code)
            }
        }.apply { isDaemon = true; name = "lantern-waiter" }.start()
    }

    private fun drain(
        reader: java.io.BufferedReader,
        logFile: File,
        isStdout: Boolean,
    ) {
        val out = runCatching {
            if (logFile.length() > 512 * 1024) logFile.delete()
            FileOutputStream(logFile, true).bufferedWriter()
        }.getOrNull()
        // Build 2055 (audit B-M4): one buffered writer, flushed
        // on a 2 s timer or 8 KB — never per line. A flush-per-
        // line turned every core log line into a disk sync for
        // the whole session; the in-memory tails above are the
        // live view, the file is evidence, and 2 s of staleness
        // on a crash is the accepted trade.
        var lastFlushMs = System.currentTimeMillis()
        var bytesSinceFlush = 0
        try {
            while (true) {
                val line = reader.readLine() ?: break
                out?.let {
                    runCatching {
                        it.write(line)
                        it.newLine()
                        bytesSinceFlush += line.length + 1
                        val now = System.currentTimeMillis()
                        if (bytesSinceFlush >= 8192 ||
                            now - lastFlushMs >= 2000
                        ) {
                            it.flush()
                            bytesSinceFlush = 0
                            lastFlushMs = now
                        }
                    }
                }
                if (isStdout) {
                    synchronized(stdoutTail) {
                        stdoutTail.addLast(line)
                        while (stdoutTail.size > 40) stdoutTail.removeFirst()
                    }
                    handleContract(line)
                } else {
                    synchronized(stderrTail) {
                        stderrTail.addLast(line)
                        while (stderrTail.size > 40) stderrTail.removeFirst()
                    }
                }
            }
        } catch (_: Exception) {
            // Stream closed by stop(); the waiter thread owns the
            // exit bookkeeping.
        } finally {
            runCatching { out?.close() }
        }
    }

    private fun handleContract(line: String) {
        if (!line.startsWith("[lantern] ")) return
        val body = line.removePrefix("[lantern] ").trim()
        when {
            // Build 2052 (diagnosis Cause 4): prefix match, as
            // ralysnd — the shipped binary's line may carry a
            // suffix, and exact equality never matched it.
            body.startsWith("listening") -> listening = true
            body.startsWith("config cached") || body.startsWith("config fetched") -> {
                Regex("""servers=(\d+)""").find(body)?.let {
                    servers = it.groupValues[1].toIntOrNull() ?: servers
                }
                if (stage == "starting") stage = "fetching"
            }
            body == "proxy ok" -> stage = "up"
            body.startsWith("exit ") -> {
                val parts = body.removePrefix("exit ").split("|")
                if (parts.size == 3) {
                    exitCity = parts[0].trim()
                    exitCountry = parts[1].trim()
                    exitCode = parts[2].trim()
                }
            }
            body == "exhausted" -> exhausted = true
            body.startsWith("error ") -> {
                lastError = body.removePrefix("error ")
                if (stage == "starting" || stage == "fetching") stage = "error"
            }
            // Build 2052: log unmatched contract lines verbatim at
            // debug level, so the shipped binary's real vocabulary
            // stays visible instead of silently dropped.
            else -> Log.d("LanternCore", "unmatched contract line: $body")
        }
    }

    /** One stdin control line ("fetch"). False when no core runs. */
    @Synchronized
    fun command(line: String): Boolean {
        val w = stdin ?: return false
        if (!isAlive()) return false
        return runCatching {
            w.write(line)
            w.newLine()
            w.flush()
            true
        }.getOrDefault(false)
    }

    /**
     * Build 2052 (diagnosis Cause 2): the bootstrap leg rides the
     * RUNNING core's stdin — `via HOST:PORT` reroutes only the
     * control plane (the config fetch) through the leg; server
     * traffic itself is always dialled direct. `via direct`
     * returns the control plane to direct before the leg goes
     * down, so later refreshes never point at a dead port. The
     * shipped binary implements exactly this contract (its stdin
     * `via` strings are in the binary); the old restart-with-a-
     * start-flag path never invoked it.
     */
    fun sendVia(port: Int): Boolean = command("via 127.0.0.1:$port")

    fun sendViaDirect(): Boolean = command("via direct")

    /**
     * Build 2052 (diagnosis Cause 5): the data-plane proof,
     * ported from ralysnd's LanternEngine.carriesWarm — a
     * listener is not a connection, and a SOCKS reply is not
     * one either. A FULL TLS handshake through the SOCKS port to
     * two Iran-poisoned hosts (resolved locally each is a
     * sinkhole, so a completed handshake proves the name
     * travelled to the exit and the exit carried it); the second
     * host must answer inside 9 s. The certificate chain is
     * deliberately not validated here — reachability is being
     * tested, not the chain (ralysnd's trust-all probe socket).
     */
    fun carriesWarm(port: Int, budgetMs: Long, cancelled: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + budgetMs
        while (System.currentTimeMillis() < deadline) {
            if (cancelled() || !isAlive()) return false
            val left = deadline - System.currentTimeMillis()
            if (!carriesStream(port, "www.youtube.com", minOf(left, 20_000L), cancelled)) continue
            if (cancelled() || !isAlive()) return false
            val second = minOf(9_000L, maxOf(2_000L, deadline - System.currentTimeMillis()))
            if (carriesStream(port, "www.instagram.com", second, cancelled)) return true
        }
        return false
    }

    private fun carriesStream(port: Int, host: String, timeoutMs: Long, cancelled: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (cancelled()) return false
            if (handshake(port, host, (deadline - System.currentTimeMillis()).coerceIn(1_000L, 12_000L).toInt())) return true
            if (System.currentTimeMillis() + 1_500 >= deadline) break
            try {
                Thread.sleep(1_500)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
        }
        return false
    }

    private val probeTrustAll = object : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
        override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
    }

    private val probeTls by lazy {
        SSLContext.getInstance("TLS").apply {
            init(null, arrayOf(probeTrustAll), SecureRandom())
        }.socketFactory
    }

    private fun handshake(port: Int, host: String, timeoutMs: Int): Boolean = try {
        Socket(Proxy.NO_PROXY).use { s ->
            s.connect(InetSocketAddress("127.0.0.1", port), 3_000)
            s.soTimeout = timeoutMs
            val o = s.getOutputStream()
            val i = s.getInputStream()
            o.write(byteArrayOf(5, 1, 0)); o.flush()
            if (i.read() != 5 || i.read() != 0) return false
            val h = host.toByteArray(Charsets.US_ASCII)
            o.write(byteArrayOf(5, 1, 0, 3, h.size.toByte()) + h + byteArrayOf(0x01, 0xBB.toByte())); o.flush()
            if (i.read() != 5 || i.read() != 0) return false
            i.read()
            val skip = when (i.read()) { 1 -> 4; 4 -> 16; 3 -> i.read(); else -> return false }
            repeat(skip + 2) { if (i.read() < 0) return false }
            (probeTls.createSocket(s, host, 443, true) as SSLSocket).use { t ->
                t.sslParameters = t.sslParameters.apply { serverNames = listOf(SNIHostName(host)) }
                t.startHandshake()
                true
            }
        }
    } catch (_: Exception) {
        false
    }

    /**
     * MLM's stop discipline: closing stdin makes the core exit on
     * its own; escalate only if it lingers (1.5 s graceful, then
     * destroy, 1 s, then destroyForcibly — with a bounded wait
     * confirming the death, build 2054 audit F-M1).
     */
    @Synchronized
    fun stop() {
        val p = process ?: return
        stopping = true
        runCatching { stdin?.close() }
        if (!waitExit(p, 1500)) {
            ProcessKill.kill(p, destroyGraceMs = 1000, forcibleWaitMs = 2500)
        }
        if (process === p) {
            process = null
            stdin = null
        }
        listening = false
        if (stage != "error") stage = "idle"
    }

    private fun waitExit(p: Process, ms: Long): Boolean =
        runCatching { p.waitFor(ms, TimeUnit.MILLISECONDS) }.getOrDefault(false)

    /**
     * Fresh server list: forget the cached config so the next
     * start refetches. The device id and secrets are kept (a new
     * identity is not needed to get a new list). Only while the
     * core is stopped. Returns the number of files deleted, or
     * -1 when the core is running.
     */
    fun rotate(context: Context): Int {
        if (isAlive()) return -1
        var deleted = 0
        for (name in listOf("config.json", "config_raw.json", "servers.json", "settings.json")) {
            val f = File(dataDir(context), name)
            if (f.exists() && f.delete()) deleted++
        }
        return deleted
    }

    /**
     * The kept config's contents (build 2052, diagnosis Cause 3):
     * radiance writes the server list under `options` →
     * `outbounds` (fronted) / `endpoints` (masque) — the old code
     * read root-level "servers"/"masque", keys radiance never
     * writes there, so the kept list was always invisible and the
     * host could never tell warm from cold. Ported from ralysnd's
     * LanternEngine.cachedServerCount: an entry counts when it
     * has a non-blank tag AND a server address or a peer with one.
     * Returns (fronted, masque); -1/-1 when there is no readable
     * kept config.
     */
    fun keptConfig(context: Context): Pair<Int, Int> {
        val file = File(dataDir(context), "config.json")
        if (!file.isFile || file.length() == 0L) return -1 to -1
        return try {
            val options = org.json.JSONObject(file.readText()).optJSONObject("options")
                ?: return -1 to -1
            fun count(key: String): Int {
                val a = options.optJSONArray(key) ?: return 0
                var n = 0
                for (i in 0 until a.length()) {
                    val x = a.optJSONObject(i) ?: continue
                    if (x.optString("tag").isBlank()) continue
                    val peers = x.optJSONArray("peers")
                    val hasPeer = peers != null && (0 until peers.length()).any {
                        peers.optJSONObject(it)?.optString("address")?.isNotBlank() == true
                    }
                    if (x.optString("server").isNotBlank() || hasPeer) n++
                }
                return n
            }
            count("outbounds") to count("endpoints")
        } catch (_: Exception) {
            -1 to -1
        }
    }

    /**
     * The phone's current DNS servers on the network the phone is
     * really on — never a VPN's, which is what the active network
     * is while a tunnel is up. Ported from ralysnd's
     * LanternEngine.systemDns (build 2052, diagnosis minor item):
     * only networks with NET_CAPABILITY_INTERNET, link-local IPv6
     * resolvers left out (Go cannot be given a zone), IPv6
     * formatted as `[ip]:53`, and the first network that yields
     * resolvers wins.
     */
    fun systemDns(context: Context): List<String> {
        val out = LinkedHashSet<String>()
        try {
            val cm = context.getSystemService(ConnectivityManager::class.java)
            val nets = runCatching {
                (listOfNotNull(cm.activeNetwork) + cm.allNetworks.toList()).distinct().filter { n ->
                    val caps = cm.getNetworkCapabilities(n) ?: return@filter false
                    !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                        caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                }
            }.getOrDefault(emptyList())
            for (n in nets) {
                val props = runCatching { cm.getLinkProperties(n) }.getOrNull() ?: continue
                for (addr in props.dnsServers) {
                    when (addr) {
                        is java.net.Inet4Address -> addr.hostAddress?.let { out += it }
                        is java.net.Inet6Address ->
                            if (!addr.isLinkLocalAddress && addr.scopeId == 0) {
                                addr.hostAddress?.substringBefore('%')?.let { out += "[$it]:53" }
                            }
                    }
                }
                if (out.isNotEmpty()) break
            }
        } catch (_: Exception) {
        }
        if (out.isEmpty()) {
            out += "8.8.8.8"
            out += "1.1.1.1"
        }
        return out.toList()
    }
}

class LanternVpnService : VpnService() {
    private val worker = Executors.newSingleThreadExecutor()
    private val stopping = AtomicBoolean(false)
    private var tunPfd: ParcelFileDescriptor? = null
    private var tunProcess: Process? = null
    private var serverSocket: LocalServerSocket? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Build 2068: the start net, same shape as the other
        // engines' — the whole command body runs in
        // onStartCommandGuarded below; a Throwable escaping it
        // (startInForeground above all: it runs on the main
        // thread before any core process exists) is recorded in
        // crash.log and the service stops gracefully, instead of
        // an uncaught main-thread death. crash.log only: this
        // service owns no session log file at onStartCommand
        // time (its workDir files are the core's, written once
        // the core starts), so there is no honest second file
        // to append to here.
        return try {
            onStartCommandGuarded(intent, flags, startId)
        } catch (e: Throwable) {
            CrashLog.append(this, "LanternVpnService.onStartCommand", e)
            stopSelf()
            START_NOT_STICKY
        }
    }

    private fun onStartCommandGuarded(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                startInForeground()
                if (running) return START_STICKY
                stopping.set(false)
                val ipv6 = intent.getBooleanExtra(EXTRA_IPV6, true)
                val smart = intent.getBooleanExtra(EXTRA_SMART, false)
                val mtu = clampMtu(intent.getIntExtra(EXTRA_MTU, MTU))
                // The tunnel DNS (build 2057, audit §6 engine
                // low): the Xray settings value via Dart, not the
                // old hardcoded 1.1.1.1 the service used while
                // Settings offered a DNS the tunnel ignored.
                val dns = intent.getStringExtra(EXTRA_DNS)
                    ?.takeIf { it.isNotBlank() } ?: "1.1.1.1"
                worker.execute {
                    try {
                        startTunnel(ipv6, smart, mtu, dns)
                    } catch (e: Throwable) {
                        // Build 2070 (review §5.1): Throwable +
                        // crash.log (was Exception + logcat). The
                        // start runs here, on the worker, after
                        // onStartCommand's own net (build 2068) has
                        // returned — an Error escaping this body
                        // (a class-init failure in the core/bridge
                        // classes above all) was an uncaught worker
                        // death. The recorded failure takes the
                        // same serviceError + fail() path the
                        // Exception always took.
                        CrashLog.append(
                            this,
                            "LanternVpnService.startTunnel",
                            e,
                        )
                        Log.e(TAG, "the Lantern tunnel did not start", e)
                        if (serviceError == null) {
                            serviceError = e.message ?: e.toString()
                        }
                        fail()
                    }
                }
                return START_STICKY
            }
        }
        return START_NOT_STICKY
    }

    private fun startTunnel(
        ipv6: Boolean,
        smart: Boolean = false,
        mtu: Int,
        dns: String = "1.1.1.1",
    ) {
        serviceError = null
        val dir = LanternCore.workDir(this).apply { mkdirs() }
        LanternCore.onCoreExit = { _ ->
            if (running) {
                if (serviceError == null) serviceError = LanternCore.lastError
                stopTunnel()
            }
        }

        // 1. Warm/cold split BEFORE starting (build 2052,
        //    diagnosis Cause 3): a kept list means the core
        //    listens in seconds; without one the first fetch is
        //    the slow step. The core subprocess.
        val kept = LanternCore.keptConfig(this)
        val warm = kept.first > 0 || kept.second > 0
        LanternCore.start(this, smart)

        // 2. Wait for its SOCKS listener before raising the TUN —
        //    bridging into a dead port would blackhole traffic.
        //    Judged from the stdout contract or the port itself,
        //    never from stderr. The budget is ralysnd's ladder:
        //    warm 20 s, cold 240 s total — ONE process, never
        //    killed while its first fetch is still in flight
        //    (diagnosis Cause 1). The Dart side raises the WARP
        //    leg after 20 s of a cold start and reroutes the
        //    control plane through the running core's stdin
        //    (Cause 2); this wait simply outlives that.
        val budgetMs = if (warm) LanternCore.WARM_LISTEN_MS else LanternCore.COLD_GIVEUP_MS
        if (!waitForCore(budgetMs)) {
            throw IllegalStateException(
                LanternCore.lastError
                    ?: if (warm) {
                        "Lantern core did not open 127.0.0.1:${LanternCore.SOCKS_PORT} in 20 s with a kept server list"
                    } else {
                        "Lantern core did not open 127.0.0.1:${LanternCore.SOCKS_PORT} in 240 s — the first server list never arrived"
                    },
            )
        }

        // 2b. The data path decides (build 2052, diagnosis
        //      Cause 5): a listener is not a connection. Only
        //      after a TLS handshake through the SOCKS to two
        //      hosts does the TUN go up; a core whose servers are
        //      all unreachable on this line fails here with its
        //      own words instead of a false "connected".
        if (!LanternCore.carriesWarm(LanternCore.SOCKS_PORT, LanternCore.DATA_TIMEOUT_MS) { stopping.get() }) {
            throw IllegalStateException(
                if (LanternCore.exhausted) {
                    val n = LanternCore.servers
                    if (n > 0) {
                        "None of the $n servers on Lantern's current list answered from your internet. The core fetches a new list by itself; tap \u201CFresh server list\u201D for a new one now."
                    } else {
                        "None of the servers on Lantern's current list answered from your internet. The core fetches a new list by itself; tap \u201CFresh server list\u201D for a new one now."
                    }
                } else {
                    "Lantern core came up but no server carried any traffic in 45 s. Connect again, or tap \u201CFresh server list\u201D."
                },
            )
        }

        // 3. The VPN interface.
        if (prepare(this) != null) {
            throw IllegalStateException("the VPN has no permission")
        }
        val builder = Builder()
            .setSession(getString(R.string.app_name))
            .setMtu(mtu)
            .addAddress("10.10.16.1", 30)
            .addRoute("0.0.0.0", 0)
            .addDnsServer(dns)
        if (ipv6) {
            builder.addAddress("fdfe:dcba:9876::1", 126)
            builder.addRoute("::", 0)
        }
        applyApps(builder)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
        val pfd = builder.establish()
            ?: throw IllegalStateException("establish() returned null")
        tunPfd = pfd

        // 4. The fd listener the helper connects to (see
        //    XrayVpnService.createFdListener for the namespace both
        //    sides agree on: the absolute path string, abstract).
        val socketFile = File(dir, "tun.sock")
        socketFile.delete()
        val server = LocalServerSocket(socketFile.absolutePath)
        serverSocket = server

        // 5. The tun2socks helper subprocess. Build 2067 (log
        // hygiene): the bridge log rotates per session, like
        // Xray's — the previous session becomes tunlink.log.old.
        val tunLog = File(dir, "tunlink.log")
        rotateLogPerSession(tunLog)
        tunProcess = ProcessBuilder(
            libPath("libtunlink.so"),
            "-socket", socketFile.absolutePath,
            "-proxy", "socks5://127.0.0.1:${LanternCore.SOCKS_PORT}",
            "-mtu", mtu.toString(),
            "-loglevel", "warn",
        )
            .directory(dir)
            .redirectErrorStream(true)
            .redirectOutput(ProcessBuilder.Redirect.appendTo(tunLog))
            .start()

        // 6. Hand the TUN fd over.
        val accepted = acceptWithTimeout(server, 15000)
            ?: throw IllegalStateException("the helper did not connect for the TUN fd")
        accepted.use { socket ->
            socket.setFileDescriptorsForSend(arrayOf(pfd.fileDescriptor))
            socket.outputStream.write(1)
            socket.outputStream.flush()
        }
        server.close()
        serverSocket = null

        running = true
        startedAtMs = System.currentTimeMillis()
        val uid = android.os.Process.myUid()
        baseTx = TrafficStats.getUidTxBytes(uid)
        baseRx = TrafficStats.getUidRxBytes(uid)
        updateNotification()
        watchProcesses()
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

    private fun waitForCore(timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (!LanternCore.isAlive()) return false
            if (LanternCore.listening) return true
            try {
                Socket().use { s ->
                    s.connect(InetSocketAddress("127.0.0.1", LanternCore.SOCKS_PORT), 300)
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
        return LanternCore.listening
    }

    /** Ends the tunnel when either subprocess dies on its own. */
    private fun watchProcesses() {
        worker.execute {
            while (!stopping.get() && running) {
                if (!LanternCore.isAlive()) {
                    Log.e(TAG, "lantern core exited")
                    if (serviceError == null) {
                        serviceError = LanternCore.lastError ?: "Lantern core exited"
                    }
                    stopTunnel()
                    return@execute
                }
                val t = tunProcess
                if (t != null && !t.isAlive) {
                    Log.e(TAG, "tunlink exited (${t.exitValue()})")
                    stopTunnel()
                    return@execute
                }
                try {
                    // Build 2055 (audit B-H5): 5 s, not 1 s — the
                    // only work here is a liveness check; the core
                    // has its own exit callback for the fast path.
                    Thread.sleep(5000)
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
                // Closed by the timeout path below.
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
        runCatching { File(LanternCore.workDir(this), "tun.sock").delete() }
        // The bridge first, so no new flows start while the core goes.
        // Build 2054 (audit F-M1): the shared kill — the old
        // destroy + 400 ms + forcibly with NO post-forcible wait
        // could return while the helper still held its port.
        tunProcess?.let { ProcessKill.kill(it) }
        tunProcess = null
        LanternCore.stop()
        try {
            tunPfd?.close()
        } catch (e: Exception) {
            // Already closed.
        }
        tunPfd = null
    }

    /**
     * Build 2067 (log hygiene): rotate [file] at every session
     * start — the previous file becomes <name>.old — so a log
     * viewer can never present a previous session's flood as the
     * current session's (the psiphon.log lesson of the 2066
     * device report). Same helper as XrayVpnService's.
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

    private fun libPath(name: String): String =
        File(applicationInfo.nativeLibraryDir, name).absolutePath

    override fun onRevoke() {
        stopTunnel()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopping.set(true)
        stopProcesses()
        running = false
        worker.shutdownNow()
        super.onDestroy()
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
            this, 40, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 41, Intent(this, LanternVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val exit = when {
            LanternCore.exitCity.isNotEmpty() && LanternCore.exitCountry.isNotEmpty() ->
                "${LanternCore.exitCity}, ${LanternCore.exitCountry}"
            LanternCore.exitCountry.isNotEmpty() -> LanternCore.exitCountry
            else -> ""
        }
        val text = when {
            running && LanternCore.stage == "up" && exit.isNotEmpty() -> "Lantern · $exit"
            running && LanternCore.stage == "up" -> "Lantern"
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
        const val ACTION_START = "com.ralysnd.ember.LANTERN_START"
        const val ACTION_STOP = "com.ralysnd.ember.LANTERN_STOP"
        private const val EXTRA_IPV6 = "ipv6"
        private const val EXTRA_SMART = "smart"
        private const val EXTRA_MTU = "mtu"
        private const val EXTRA_DNS = "dns"

        private const val CHANNEL = "lantern_status"
        private const val NOTIFICATION_ID = 4
        private const val TAG = "LanternVpnService"
        private const val MTU = 1500

        /** Clamps a tunnel MTU to the offered range (build 2038,
         *  queue 2f): 1280 is the IPv6 minimum MTU (the floor),
         *  1500 the default ceiling. A corrupt or out-of-range
         *  value clamps instead of breaking a connect. */
        private fun clampMtu(mtu: Int) = mtu.coerceIn(1280, 1500)

        @Volatile
        var running = false
            private set

        @Volatile
        var startedAtMs = 0L
            private set

        /** Why the last start/stop cycle failed, if it did. */
        @Volatile
        var serviceError: String? = null

        @Volatile
        private var baseTx = -1L

        @Volatile
        private var baseRx = -1L

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
            ipv6: Boolean,
            smart: Boolean = false,
            mtu: Int = 1500,
            dns: String = "1.1.1.1",
        ) {
            val intent = Intent(context, LanternVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_IPV6, ipv6)
                putExtra(EXTRA_SMART, smart)
                putExtra(EXTRA_MTU, clampMtu(mtu))
                putExtra(EXTRA_DNS, dns)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, LanternVpnService::class.java).apply { action = ACTION_STOP },
            )
        }
    }
}
