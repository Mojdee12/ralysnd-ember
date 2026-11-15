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
import ca.psiphon.PsiphonTunnel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The Psiphon engine's service. Unlike the Xray engine (plain
 * subprocesses), the Psiphon tunnel core is a gomobile library
 * (libs/psiphon.aar) that runs in this process, driven through
 * Psiphon's own PsiphonTunnel host wrapper with this service as
 * its HostService. Build 2069: the AAR is ralysnd's complete
 * Psiphon stack transplanted byte-exact — the stock tunnel-core
 * v2.0.39 wrapper plus libpgjni.so (gomobile runtime renamed
 * go -> pg so it can live beside the Mozilla core's) — replacing
 * Ember's rebuilt v2.0.42 + fork-patch AAR wholesale. This host
 * is adapted to the v2.0.39 wrapper interface: identical to the
 * old one except v2.0.42's extra onAccessToken (never used
 * here), and — ralysnd parity — there is NO loadLibrary
 * override: the wrapper's default loads "pgjni" itself.
 *
 * Two modes, chosen at start:
 *  - VPN mode: once the core has a tunnel, this service establishes
 *    the TUN device and badvpn tun2socks (Psiphon Inc's own bridge,
 *    via ca.psiphon.Tun2SocksJniLoader — the bridge the official
 *    client and ralysnd use) routes it: TCP to the core's SOCKS
 *    proxy (CONNECT only), UDP to the core's own UDP gateway
 *    intercept. Build 2066 replaced the generic libtunlink bridge
 *    here: it forwards UDP as SOCKS UDP ASSOCIATE, which the
 *    Psiphon SOCKS rejects per packet — the 2065 device regression
 *    (log flood + blackhole). The core runs with setVpnMode(true),
 *    so every socket it opens is handed back here (bindToDevice)
 *    and protected from the VPN — and the whole app is disallowed
 *    from its own TUN, so nothing loops.
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
    private var tunPfd: ParcelFileDescriptor? = null

    /** The badvpn tun2socks thread (build 2066): runTun2Socks
     *  blocks on it until terminated. Watched like the old tunlink
     *  process was: its death ends the session. */
    private var bridgeThread: Thread? = null

    /** When the TUN was raised (0 = not raised) and when the core
     *  last reported connected: the anchors of the tunnel-loss
     *  deadline in watchHelper (build 2066). */
    private var tunUpAtMs = 0L

    @Volatile
    private var lastConnectedMs = 0L

    /** Set by onExiting when the in-process core stops on its own
     *  (build 2057, audit F-M4): the watcher's death signal. Only
     *  honoured while a session is up — a stop we asked for sets
     *  `stopping` first, so its onExiting is not a teardown. */
    @Volatile
    private var coreExited = false

    // ---- Build 2065: the strategy ladder -------------------------
    //
    // When the start intent carries a rung list, startTunnel tries
    // each rung's config in order with the rung's budget until one
    // connects (ralysnd's PsiphonMethods ladder, ported): A fronted,
    // E clean-IP, D direct, C conduit, P personal conduit, X upstream
    // proxy. The winning rung is published as [activeMethod] so the
    // Dart side can remember it per network and try it first next
    // time. An empty rung list keeps the pre-2065 single-attempt
    // behaviour exactly (the Xray underlay call site relies on it).

    /** True while the ladder loop (not the watcher) owns the core:
     *  onExiting from a rung we stopped ourselves must not arm the
     *  watcher's coreExited teardown. */
    @Volatile
    private var ladderActive = false

    /** Set by onExiting during a ladder attempt: this attempt's core
     *  died before connecting, so the attempt can end early. */
    @Volatile
    private var attemptExited = false

    private var ladderRungs: List<String> = emptyList()
    private var ladderRegion = ""
    private var ladderUpstream = ""
    private var ladderProtocols: List<String> = emptyList()
    private var ladderCompartment = ""
    private var ladderCleanAkamai: List<String> = emptyList()
    private var ladderCleanFastly: List<String> = emptyList()
    private var ladderDisableTimeouts = false
    private var ladderCdnFront = false

    /** When the current watch started, and when the core last spoke
     *  (a diagnostic notice): the silence half of the liveness
     *  deadline in watchHelper (build 2057, audit F-M4). */
    private var watchStartedAtMs = 0L

    @Volatile
    private var lastNoticeMs = 0L

    /** The config JSON handed to the core, built at start. */
    @Volatile
    private var configJson = ""

    private val logLock = Any()

    /** The session's buffered log writer (build 2055, audit
     *  B-M4): held open for the session, flushed on a 2 s
     *  timer or 8 KB — never open+write+close per notice.
     *  Exception: the start phase flushes synchronously, per
     *  line (build 2069, [logStartPhaseSync]). */
    private var logWriter: java.io.BufferedWriter? = null
    private var logBytesSinceFlush = 0
    private var logLastFlushMs = 0L

    /** Build 2069: start-phase synchronous flushing. From
     *  openLog until the session connects, fails, or stops,
     *  every log line reaches disk as it is written; the 2055
     *  buffered policy (8 KB / 2 s) resumes afterwards. The
     *  2068 device evidence is why this exists: the owner's
     *  whole start path provably completed, yet psiphon.log
     *  read 0 bytes in the viewer — the buffered session
     *  header simply never flushed, so a start that RAN was
     *  indistinguishable from a start that never ran. With
     *  this flag, no start-phase failure can hide behind the
     *  buffer again. This is a permanent diagnostics property
     *  of the log, not scaffolding. */
    @Volatile
    private var logStartPhaseSync = false

    /** Consecutive-duplicate collapse for the session log (build
     *  2066): the last line written and how many times it has
     *  repeated since. A core or bridge warning that fires per
     *  packet must not be able to flood the file (the 2065 device
     *  log carried hundreds of identical SOCKS accept errors). */
    private var lastLogLine: String? = null
    private var logRepeatCount = 0

    override fun onCreate() {
        super.onCreate()
        // Build 2073: the state setters publish through the
        // application context of THIS process (the service runs
        // in :psiphon now — see the companion's state block);
        // capture it before any state can change.
        bindAppContext(this)
        // Build 2068 breadcrumb: the service exists (the trail's
        // step 6 — see CrashLog).
        CrashLog.breadcrumb(this, "psiphon:service-onCreate")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                // Build 2068 breadcrumb: the start command landed
                // (the trail's step 7).
                CrashLog.breadcrumb(this, "psiphon:onStartCommand-start")
                // Build 2068: the start net. Everything in this
                // branch runs on the main thread BEFORE openLog —
                // the exact stretch where the owner's crash left
                // psiphon.log empty. A Throwable here (the eager
                // legacy buildConfig, startInForeground, the
                // worker hand-off) used to propagate out of
                // onStartCommand and take the process down with
                // no trace in any log the owner can read. Now it
                // is recorded — straight into psiphon.log by plain
                // file append (openLog has not run yet, so the
                // session writer does not exist), and into
                // crash.log — and the service stops gracefully.
                try {
                    val vpnMode = intent.getBooleanExtra(EXTRA_VPN_MODE, true)
                    val region = intent.getStringExtra(EXTRA_REGION) ?: ""
                    val upstream = intent.getStringExtra(EXTRA_UPSTREAM) ?: ""
                    val protocols = intent.getStringArrayListExtra(EXTRA_PROTOCOLS) ?: arrayListOf()
                    val dns = intent.getStringExtra(EXTRA_DNS) ?: "1.1.1.1"
                    val mtu = clampMtu(intent.getIntExtra(EXTRA_MTU, MTU))
                    // Build 2057 (audit F-M4): IPv6 capture is opt-in
                    // through this extra (XraySettings.ipv6Route); the
                    // default keeps the old capture-everything behaviour
                    // until the Dart side passes its value.
                    val ipv6 = intent.getBooleanExtra(EXTRA_IPV6, true)
                    // Build 2065: the ladder inputs. Empty rungs = the
                    // legacy single attempt (configJson built eagerly,
                    // as before); with rungs, each attempt builds its
                    // own config inside startTunnel.
                    ladderRungs = intent.getStringArrayListExtra(EXTRA_RUNGS) ?: arrayListOf()
                    ladderRegion = region
                    ladderUpstream = upstream
                    ladderProtocols = protocols
                    ladderCompartment = intent.getStringExtra(EXTRA_COMPARTMENT) ?: ""
                    ladderCleanAkamai = intent.getStringArrayListExtra(EXTRA_CLEAN_AKAMAI) ?: arrayListOf()
                    ladderCleanFastly = intent.getStringArrayListExtra(EXTRA_CLEAN_FASTLY) ?: arrayListOf()
                    ladderDisableTimeouts = intent.getBooleanExtra(EXTRA_DISABLE_TIMEOUTS, false)
                    ladderCdnFront = intent.getBooleanExtra(EXTRA_CDN_FRONT, false)
                    activeMethod = ""
                    configJson = if (ladderRungs.isEmpty()) {
                        buildConfig(region, upstream, protocols, null, 0)
                    } else {
                        ""
                    }
                    startInForeground()
                    // Build 2068 breadcrumb: foreground start
                    // survived (the trail's step 8).
                    CrashLog.breadcrumb(this, "psiphon:startInForeground-returned")
                    worker.execute { startTunnel(vpnMode, dns, mtu, ipv6) }
                    return START_STICKY
                } catch (e: Throwable) {
                    CrashLog.appendToFile(
                        File(workDir(this), "psiphon.log"),
                        "PsiphonVpnService.onStartCommand",
                        e,
                    )
                    CrashLog.append(this, "PsiphonVpnService.onStartCommand", e)
                    try {
                        stopTunnel()
                    } catch (_: Throwable) {
                        // The net itself must never throw.
                    }
                    stopSelf()
                    return START_NOT_STICKY
                }
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
        // Build 2060 (grouped sweep): onDestroy only stopped the
        // processes — the tunnel itself (tunnel?.stop()) was never
        // called, so a service destroyed while connected left the
        // Psiphon tunnel running. stopTunnel() stops the tunnel
        // AND the processes, so it is the whole teardown here.
        stopTunnel()
        super.onDestroy()
    }

    /** One ladder rung: its per-attempt budget and the config fields
     *  that make it different (ralysnd PsiphonMethods, verified
     *  against the shipped core's field strings). */
    private data class RungSpec(
        val budgetSeconds: Int,
        val poolSize: Int,
        val latencyMultiplier: Double,
    )

    private fun rungSpec(rung: String): RungSpec = when (rung) {
        "A" -> RungSpec(60, 12, 2.0)
        "E" -> RungSpec(45, 8, 1.5)
        "D" -> RungSpec(45, 16, 0.0)
        "C" -> RungSpec(75, 16, 3.0)
        "P" -> RungSpec(90, 16, 3.0)
        "X" -> RungSpec(45, 16, 0.0)
        else -> RungSpec(45, 16, 0.0)
    }

    /** Encodes one server-list URL the way the core expects:
     *  {URL: base64(url, NO_WRAP), OnlyAfterAttempts, SkipVerify}. */
    private fun serverListUrl(url: String, onlyAfterAttempts: Int, skipVerify: Boolean): JSONObject {
        val o = JSONObject()
        o.put("URL", android.util.Base64.encodeToString(url.toByteArray(), android.util.Base64.NO_WRAP))
        o.put("OnlyAfterAttempts", onlyAfterAttempts)
        o.put("SkipVerify", skipVerify)
        return o
    }

    /** The production-shaped tunnel-core config (see PsiphonConstants).
     *
     *  Build 2065: [rung] null = the legacy single config (plus the
     *  new common fields: live server lists, anti-hijack DNS,
     *  diagnostics). A rung letter applies that rung's strategy on
     *  top. A user-pinned protocol list (the transports multi-select)
     *  outranks every rung's own protocol limits — an explicit user
     *  choice is never silently overridden by the ladder. */
    private fun buildConfig(
        region: String,
        upstream: String,
        protocols: List<String>,
        rung: String?,
        budgetSeconds: Int,
    ): String {
        val dir = workDir(this)
        dir.mkdirs()
        val cfg = JSONObject()
        cfg.put("ClientVersion", PsiphonConstants.CLIENT_VERSION)
        cfg.put("PropagationChannelId", PsiphonConstants.PROPAGATION_CHANNEL_ID)
        cfg.put("SponsorId", PsiphonConstants.SPONSOR_ID)
        cfg.put("RemoteServerListSignaturePublicKey", PsiphonConstants.REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY)
        cfg.put("ServerEntrySignaturePublicKey", PsiphonConstants.SERVER_ENTRY_SIGNATURE_PUBLIC_KEY)
        // Build 2069: NO AdditionalParameters blob. The blob
        // (decrypted in psiphon-fresh-install-diff.md) carries
        // a DIFFERENT channel's (mjr4-p23r-puwl) server-list
        // URLs and silently overrides the explicit official
        // iohq-waa4-q4dt lists configured below — Ember's
        // visible server-list settings were dead letter while
        // it was set. ralysnd sends no blob; with it gone, the
        // explicit lists below (byte-identical to ralysnd's
        // official set) are authoritative.
        cfg.put("DataRootDirectory", dir.absolutePath)
        cfg.put("LocalSocksProxyPort", PsiphonConstants.SOCKS_PORT)
        cfg.put("LocalHttpProxyPort", PsiphonConstants.HTTP_PORT)
        cfg.put("EmitDiagnosticNotices", true)
        cfg.put("EmitDiagnosticNetworkParameters", true)
        cfg.put("EmitServerAlerts", true)
        cfg.put("EmitBytesTransferred", true)
        cfg.put("EgressRegion", region)
        if (upstream.isNotEmpty()) cfg.put("UpstreamProxyURL", upstream)
        if (protocols.isNotEmpty()) cfg.put("LimitTunnelProtocols", JSONArray(protocols))

        // Server-list freshness (report gap #6): fetch the live
        // signed lists instead of relying only on the embedded 400.
        val rsl = JSONArray()
        for ((url, attempts, skip) in PsiphonConstants.REMOTE_SERVER_LIST_URLS) {
            rsl.put(serverListUrl(url, attempts, skip))
        }
        cfg.put("RemoteServerListURLs", rsl)
        val osl = JSONArray()
        for ((url, attempts, skip) in PsiphonConstants.OBFUSCATED_SERVER_LIST_ROOT_URLS) {
            osl.put(serverListUrl(url, attempts, skip))
        }
        cfg.put("ObfuscatedServerListRootURLs", osl)
        cfg.put("ExchangeObfuscationKey", PsiphonConstants.EXCHANGE_OBFUSCATION_KEY)
        cfg.put(
            "RemoteServerListDownloadFilename",
            File(dir, "remote_server_list").absolutePath,
        )
        val oslDir = File(dir, "osl")
        oslDir.mkdirs()
        cfg.put("ObfuscatedServerListDownloadDirectory", oslDir.absolutePath)

        // Anti-DNS-hijack resolvers (report gap #7).
        cfg.put(
            "DNSResolverPreferredAlternateServers",
            JSONArray(PsiphonConstants.DNS_PREFERRED_ALTERNATE_SERVERS),
        )
        cfg.put("DNSResolverPreferAlternateServerProbability", 1.0)
        cfg.put("DNSResolverAttemptsPerPreferredServer", 2)

        cfg.put("DeviceRegion", "IR")
        // Build 2069: NO AggressiveEstablishment here. That
        // field is the rebuilt fork core's Beast Mode patch,
        // not a stock-core field; 2069 transplants ralysnd's
        // complete stock Psiphon stack (v2.0.39) in place of
        // the rebuilt core and Beast is withdrawn with it
        // (toggle, setting, channel key, and this emission all
        // removed — never a dead control). It returns only on
        // a device-proven core.
        if (ladderDisableTimeouts) cfg.put("NetworkLatencyMultiplierLambda", 0.1)

        if (rung == null) {
            cfg.put("EstablishTunnelTimeoutSeconds", 120)
            cfg.put("ConnectionWorkerPoolSize", 12)
            return cfg.toString()
        }

        val spec = rungSpec(rung)
        cfg.put(
            "EstablishTunnelTimeoutSeconds",
            if (budgetSeconds > 0) budgetSeconds else spec.budgetSeconds,
        )
        cfg.put("ConnectionWorkerPoolSize", spec.poolSize)
        if (spec.latencyMultiplier > 0) {
            cfg.put("NetworkLatencyMultiplier", spec.latencyMultiplier)
        }
        val userPinned = protocols.isNotEmpty()
        when (rung) {
            "A" -> {
                if (!userPinned) {
                    // Build 2069 (transplant): stock protocol
                    // names ONLY. The fork core's
                    // FRONTED-MEEK-CDN-* names do not exist in
                    // ralysnd's v2.0.39 binary (0 occurrences in
                    // its string table); naming unknown protocols
                    // in a limit risks the stock core's config
                    // validation (ralysnd's own warning).
                    cfg.put("InitialLimitTunnelProtocols", JSONArray(PsiphonConstants.FRONTED_PROTOCOLS))
                    cfg.put("InitialLimitTunnelProtocolsCandidateCount", 30)
                    cfg.put("LimitTunnelProtocols", JSONArray(PsiphonConstants.FRONTED_PROTOCOLS))
                }
                cfg.put("DisableTactics", true)
                cfg.put("InproxyEnabled", false)
                cfg.put("InproxyAllowClient", false)
                // Build 2069: the tested edges steer the
                // fronted rung the way ralysnd steers its own —
                // as preresolved provider CIDRs (the clean-IP
                // mechanism), NOT the fork core's dial
                // overrides / CDN scan spec, which the stock
                // binary does not contain at all.
                if (ladderCdnFront) putPreresolvedCidrs(cfg)
            }
            "E" -> {
                putPreresolvedCidrs(cfg)
                if (!userPinned) {
                    cfg.put(
                        "InitialLimitTunnelProtocols",
                        JSONArray(listOf("FRONTED-MEEK-OSSH")),
                    )
                    cfg.put("InitialLimitTunnelProtocolsCandidateCount", 30)
                    cfg.put(
                        "LimitTunnelProtocols",
                        JSONArray(listOf("FRONTED-MEEK-OSSH")),
                    )
                }
                cfg.put("DisableTactics", true)
                cfg.put("InproxyEnabled", false)
                cfg.put("InproxyAllowClient", false)
            }
            "D" -> {
                cfg.put("DisableTactics", true)
                cfg.put("InproxyEnabled", false)
                cfg.put("InproxyAllowClient", false)
            }
            "C" -> {
                // Flags only, exactly as ralysnd ships it: the
                // INPROXY-WEBRTC protocol names are runtime-assembled
                // by the core; naming them in a limit risks failing
                // the whole config validation.
                cfg.put("InproxyEnabled", true)
                cfg.put("InproxyAllowClient", true)
                cfg.put("InproxySkipAwaitFullyConnected", true)
            }
            "P" -> {
                cfg.put("InproxyEnabled", true)
                cfg.put("InproxyAllowClient", true)
                if (ladderCompartment.isNotEmpty()) {
                    cfg.put("InproxyClientPersonalCompartmentID", ladderCompartment)
                }
            }
            "X" -> {
                if (!userPinned) {
                    cfg.put("LimitTunnelProtocols", JSONArray(PsiphonConstants.CHAINABLE_PROTOCOLS))
                }
                cfg.put("InproxyEnabled", false)
                cfg.put("InproxyAllowClient", false)
            }
        }
        return cfg.toString()
    }

    /** The clean-IP steering both fronted rungs use (build
     *  2069, ralysnd parity): the owner's ping-tested edge
     *  addresses, keyed by fronting provider, as preresolved
     *  CIDRs the core prefers at probability 1.0 — the stock
     *  v2.0.39 field ralysnd's own clean-IP rung uses
     *  (DNSResolverPreresolvedIPAddressCIDRs, present in the
     *  transplanted binary's string table).
     *
     *  This replaces build 2065's applyCdnFronting, which fed
     *  the fork core its FrontedMeekDialOverrides /
     *  FrontedMeekCDNScanSpec / FrontedMeekCDNScanUseBuiltInSpec
     *  inputs. NONE of those fields exist in the stock binary
     *  (0 occurrences each), so on the transplanted core they
     *  would be dead letters at best. Per-edge SNI pinning was
     *  a fork-core capability and is withdrawn with that core;
     *  what survives — and what ralysnd proves on the owner's
     *  phone — is steering fronted dials to tested edge
     *  addresses by provider. */
    private fun putPreresolvedCidrs(cfg: JSONObject) {
        val cidrs = JSONObject()
        fun addCidrs(provider: String, ips: List<String>) {
            if (ips.isEmpty()) return
            val arr = JSONArray()
            for (ip in ips) arr.put(if (ip.contains(':')) "$ip/128" else "$ip/32")
            cidrs.put(provider, arr)
        }
        addCidrs(PsiphonConstants.FRONTING_PROVIDER_AKAMAI, ladderCleanAkamai)
        addCidrs(PsiphonConstants.FRONTING_PROVIDER_FASTLY, ladderCleanFastly)
        if (cidrs.length() > 0) {
            cfg.put("DNSResolverPreresolvedIPAddressCIDRs", cidrs)
            cfg.put("DNSResolverPreresolvedIPAddressProbability", 1.0)
        }
    }

    private fun startTunnel(vpnMode: Boolean, dns: String, mtu: Int, ipv6: Boolean) {
        // Build 2068 breadcrumb: the worker reached the tunnel
        // builder (the trail's step 9).
        CrashLog.breadcrumb(this, "psiphon:startTunnel-entered")
        stopping.set(false)
        coreExited = false
        lastNoticeMs = System.currentTimeMillis()
        try {
            val dir = workDir(this)
            dir.mkdirs()
            openLog(dir)

            bridgeLogSink = { line -> logLine(line) }

            val entries = assets.open(PsiphonConstants.EMBEDDED_SERVERS_ASSET)
                .bufferedReader().use { it.readText() }

            if (ladderRungs.isEmpty()) {
                startCoreOnce(vpnMode, entries)
                logLine("psiphon core started (vpnMode=$vpnMode)")
            } else if (!runLadder(vpnMode, entries)) {
                Log.e(TAG, "psiphon ladder exhausted without a connection")
                logLine("psiphon ladder exhausted without a connection")
                fail()
                return
            }

            if (!vpnMode) {
                updateNotification()
                // Build 2057 (audit F-M4): proxy-only mode had no
                // watcher at all — a dead core sat "running" with
                // no TUN and no teardown. Watch it the same way.
                watchHelper()
                return
            }

            // Build 2066 (owner-reported 2065 regression): the TUN
            // is raised only once the core HAS a tunnel. The legacy
            // path used to bridge as soon as the SOCKS listener
            // opened — on a hostile carrier that is minutes before
            // any tunnel exists (or never), and the whole phone sat
            // behind a dead proxy while the bridge sprayed it. The
            // ladder path already returns only on a win; the legacy
            // path now waits for the same signal, bounded at
            // CONNECT_WAIT_MS. ralysnd's contract is the same:
            // routing activates from the connected callback, never
            // before.
            if (ladderRungs.isEmpty() && !waitForConnected(CONNECT_WAIT_MS)) {
                Log.e(TAG, "psiphon core did not connect in time")
                logLine("psiphon core did not connect in time; not raising the TUN")
                fail()
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
                .setMtu(mtu)
                .addAddress("10.10.15.1", 30)
                .addRoute("0.0.0.0", 0)
                .addDnsServer(dns)
            // Build 2057 (audit F-M4): the v6 address + ::/0 route
            // are added only when the caller asked for IPv6
            // (XraySettings.ipv6Route, threaded through the start
            // intent) — the old code captured all IPv6
            // unconditionally, with no opt-out, while the Xray
            // engine honours ipv6Route.
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
            tunUpAtMs = System.currentTimeMillis()
            lastConnectedMs = tunUpAtMs

            // Build 2066: badvpn tun2socks bridges the TUN (see
            // startBridge) — TCP via the core's SOCKS CONNECT, UDP
            // via the core's udpgw intercept. The generic libtunlink
            // helper is NOT used for Psiphon any more: its UDP path
            // is SOCKS UDP ASSOCIATE, which this core's SOCKS
            // rejects per packet (the 2065 flood).
            if (!startBridge(pfd, mtu)) {
                Log.e(TAG, "the Psiphon bridge did not start")
                logLine("psiphon bridge did not start")
                fail()
                return
            }
            updateNotification()
            watchHelper()
        } catch (e: Throwable) {
            // Build 2069: widened from Exception. A
            // java.lang.Error out of core start — linkage or
            // class-init failure inside newPsiphonTunnel's
            // library load is the shape the 2068 evidence
            // points at — previously escaped this catch
            // entirely and took the worker (and, on the main
            // thread's view of it, the session) down
            // unrecorded. Now it is written to crash.log
            // first, then the session fails the ordinary way.
            CrashLog.append(this, "PsiphonVpnService.startTunnel", e)
            Log.e(TAG, "the Psiphon tunnel did not start", e)
            logLine("start failed: ${e.message}")
            fail()
        }
    }

    /** Waits until the core reports a tunnel (onConnected), the
     *  core dies, or the bound passes (build 2066). The legacy
     *  single-attempt path gates the TUN raise on this; the ladder
     *  path already returns only on a win. */
    private fun waitForConnected(timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (stopping.get()) return false
            if (connected) return true
            if (coreExited) return false
            try {
                Thread.sleep(250)
            } catch (e: InterruptedException) {
                return false
            }
        }
        return connected
    }

    /**
     * Starts the TUN bridge (build 2066): badvpn tun2socks — the
     * bridge Psiphon's own client family ships — on a dedicated
     * thread; runTun2Socks blocks there until terminated. TCP goes
     * to the core's SOCKS (CONNECT only, all it supports); UDP goes
     * to the core's UDP gateway intercept at [UDPGW_SERVER_ADDRESS]
     * (the core carries the udpgw protocol through the tunnel and
     * the server forwards it) — never SOCKS UDP ASSOCIATE, which
     * the Psiphon SOCKS rejects per packet. DNS follows the same
     * path (transparent DNS on). The bridge is IPv4-only, exactly
     * as ralysnd runs it; IPv6 stays captured by the TUN (the F-M4
     * contract above) and is dropped inside the bridge instead of
     * being sprayed at a proxy that cannot take it.
     *
     * Address plan (ralysnd's, which is load-bearing): the TUN
     * interface itself is 10.10.15.1/30; lwIP answers on the router
     * address [TUN_ROUTER_ADDRESS] — passing the interface address
     * instead makes lwIP silently drop every packet. The MTU must
     * be the interface's own MTU.
     *
     * Single-instance discipline (ralysnd's abort fix): tun2socks
     * keeps its lwIP state in file-scope globals, so a second
     * run() entered before the previous one unwinds aborts the
     * process. The previous thread is joined with a grace period;
     * if it is still alive the start is refused and the session
     * fails cleanly instead of crashing.
     */
    private fun startBridge(pfd: ParcelFileDescriptor, mtu: Int): Boolean {
        synchronized(bridgeLock) {
            val previous = lastBridgeThread
            if (previous != null && previous.isAlive) {
                try {
                    previous.join(BRIDGE_EXIT_GRACE_MS)
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
                if (previous.isAlive) {
                    logLine(
                        "psiphon bridge: previous instance still shutting down; " +
                            "refusing a second start",
                    )
                    return false
                }
            }
            // runTun2Socks takes ownership of the fd it is given
            // and closes it on exit: hand it a duplicate, so the
            // service keeps its own descriptor for the interface.
            val duplicated = try {
                pfd.dup()
            } catch (e: Exception) {
                logLine("psiphon bridge: could not dup the TUN fd: ${e.message}")
                return false
            }
            try {
                ca.psiphon.Tun2SocksJniLoader.initializeLogger(
                    "com.ralysnd.ember.PsiphonTun2SocksLog", "logTun2Socks",
                )
            } catch (e: Throwable) {
                // Logger wiring is diagnostic only — never block
                // the tunnel on it.
            }
            val thread = Thread({
                try {
                    ca.psiphon.Tun2SocksJniLoader.runTun2Socks(
                        duplicated.detachFd(),
                        mtu,
                        TUN_ROUTER_ADDRESS,
                        TUN_NETMASK,
                        null, // IPv4-only bridge (ralysnd parity)
                        "127.0.0.1:${PsiphonConstants.SOCKS_PORT}",
                        UDPGW_SERVER_ADDRESS,
                        1, // transparent DNS through udpgw
                        0, // udpgw carries all UDP, not just DNS
                    )
                } catch (e: Throwable) {
                    logLine("psiphon bridge crashed: ${e.message}")
                } finally {
                    logLine("psiphon bridge exited")
                }
            }, "psiphon-tun2socks")
            bridgeThread = thread
            lastBridgeThread = thread
            thread.start()
            return true
        }
    }

    /** Terminates the bridge and waits (bounded) for the native
     *  run() to unwind, so a later start never overlaps it. */
    private fun stopBridge() {
        val thread = synchronized(bridgeLock) {
            val t = bridgeThread
            bridgeThread = null
            t
        } ?: return
        try {
            ca.psiphon.Tun2SocksJniLoader.terminateTun2Socks()
        } catch (e: Throwable) {
            // Already terminated.
        }
        if (thread !== Thread.currentThread()) {
            try {
                thread.join(BRIDGE_EXIT_GRACE_MS)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
    }

    /** Creates and starts one core instance with the current
     *  [configJson]. The caller owns watching/bridging it. */
    private fun startCoreOnce(vpnMode: Boolean, entries: String) {
        val t = PsiphonTunnel.newPsiphonTunnel(this)
        tunnel = t
        t.setVpnMode(vpnMode)
        running = true
        isVpnMode = vpnMode
        startedAtMs = System.currentTimeMillis()
        totalUp = 0
        totalDown = 0
        t.startTunneling(entries)
    }

    /**
     * The strategy ladder (build 2065): try each rung's config in
     * order until one connects. A picked exit region gets one short
     * first phase on the first rung (25 s, ralysnd's region phase —
     * EgressRegion is a hard server filter; an unfiltered retry
     * follows, so preferring a country can never make a connect
     * impossible, only slower). Returns true with the winning core
     * running; the caller bridges/watches it as usual.
     */
    private fun runLadder(vpnMode: Boolean, entries: String): Boolean {
        ladderActive = true
        try {
            val phases = mutableListOf<Triple<String, String, Int>>()
            if (ladderRegion.isNotEmpty()) {
                phases.add(Triple(ladderRungs.first(), ladderRegion, 25))
            }
            for (rung in ladderRungs) phases.add(Triple(rung, "", 0))
            for ((rung, region, budgetOverride) in phases) {
                if (stopping.get()) return false
                configJson = buildConfig(
                    region, ladderUpstream, ladderProtocols, rung, budgetOverride,
                )
                attemptExited = false
                connected = false
                startCoreOnce(vpnMode, entries)
                logLine(
                    "psiphon ladder: trying method $rung" +
                        if (region.isNotEmpty()) " (region $region)" else "",
                )
                val budgetMs =
                    (if (budgetOverride > 0) budgetOverride else rungSpec(rung).budgetSeconds) * 1000L
                val deadline = System.currentTimeMillis() + budgetMs
                var won = false
                while (System.currentTimeMillis() < deadline) {
                    if (stopping.get()) return false
                    if (connected) {
                        won = true
                        break
                    }
                    if (attemptExited) break
                    try {
                        Thread.sleep(250)
                    } catch (e: InterruptedException) {
                        return false
                    }
                }
                if (won) {
                    activeMethod = rung
                    logLine("psiphon ladder: method $rung connected")
                    return true
                }
                logLine("psiphon ladder: method $rung did not connect")
                try {
                    tunnel?.stop()
                } catch (e: Exception) {
                    // Already stopped.
                }
                tunnel = null
                connected = false
                // Let the stopped core release its local listeners
                // before the next attempt binds them again.
                try {
                    Thread.sleep(600)
                } catch (e: InterruptedException) {
                    return false
                }
            }
            return false
        } finally {
            ladderActive = false
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
            watchStartedAtMs = System.currentTimeMillis()
            while (!stopping.get() && running) {
                val bridge = bridgeThread
                if (bridge != null && !bridge.isAlive) {
                    Log.e(TAG, "psiphon bridge exited")
                    logLine("psiphon bridge exited; tearing the session down")
                    stopTunnel()
                    return@execute
                }
                // Build 2066: the tunnel-loss bound. The silence
                // deadline below can never fire while a live core
                // keeps cycling candidates — it keeps emitting
                // notices, so lastNoticeMs keeps moving — yet with
                // the TUN up and no tunnel behind it the phone is
                // blackholed for exactly as long as the core cares
                // to keep trying (the 2065 device session). The
                // bound is on connected-ness itself: TUN up with no
                // tunnel for TUNNEL_LOSS_MS ends the session,
                // whatever the core is saying. Normal server
                // rotations re-connect in seconds; 90 s of
                // continuous down is a dead session, not a rotation.
                if (connected) {
                    lastConnectedMs = System.currentTimeMillis()
                } else if (tunUpAtMs > 0 &&
                    System.currentTimeMillis() - maxOf(tunUpAtMs, lastConnectedMs) >
                    TUNNEL_LOSS_MS
                ) {
                    Log.e(TAG, "psiphon tunnel down ${TUNNEL_LOSS_MS / 1000}s with the TUN up; tearing down")
                    logLine(
                        "psiphon tunnel lost and not back in " +
                            "${TUNNEL_LOSS_MS / 1000}s; tearing the session down",
                    )
                    stopTunnel()
                    return@execute
                }
                // Build 2057 (audit F-M4): the in-process core was
                // never death-watched — only the tunlink helper was.
                // A core that exits on its own says so through
                // onExiting; a core that dies silently says nothing
                // at all. After a 3-minute grace (server discovery
                // on a filtered network is slow) plus 60 s of total
                // diagnostic silence with no connection, the core is
                // dead, not slow — tear the session down instead of
                // sitting TUN-up with connected=false indefinitely.
                // The silence half matters: a live-but-slow core
                // keeps emitting notices while it tries servers.
                // Device note: the exact notice cadence of a live
                // core on the owner's network is unproven on host —
                // if a healthy connect is ever torn down here, the
                // grace/silence pair is the knob, not the teardown.
                if (coreExited) {
                    Log.e(TAG, "psiphon core exited on its own")
                    logLine("psiphon core exited; tearing the session down")
                    stopTunnel()
                    return@execute
                }
                if (!connected) {
                    val now = System.currentTimeMillis()
                    if (now - watchStartedAtMs > CONNECT_DEADLINE_MS &&
                        now - lastNoticeMs > NOTICE_SILENCE_MS
                    ) {
                        Log.e(TAG, "psiphon core silent ${NOTICE_SILENCE_MS / 1000}s with no connection; tearing down")
                        logLine("psiphon core never connected and went silent; tearing the session down")
                        stopTunnel()
                        return@execute
                    }
                }
                try {
                    // Build 2055 (audit B-H5): 5 s, not 1 s — the
                    // only work here is a liveness check, and a
                    // dead bridge is noticed within 5 s.
                    Thread.sleep(5000)
                } catch (e: InterruptedException) {
                    return@execute
                }
            }
        }
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
        // Build 2069: the start phase ends in failure.
        logStartPhaseSync = false
        stopProcesses()
        running = false
        connected = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun stopTunnel() {
        stopping.set(true)
        // Build 2069: the start phase ends in a stop.
        logStartPhaseSync = false
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
        synchronized(logLock) { closeLogLocked() }
        // Build 2066: the bridge is a thread running native code,
        // not a process: terminate it and wait for the unwind
        // before the TUN fd goes away (a run() still touching its
        // lwIP globals during the next start aborts the process —
        // the single-instance discipline in startBridge).
        stopBridge()
        bridgeLogSink = null
        tunUpAtMs = 0
        try {
            tunPfd?.close()
        } catch (e: Exception) {
            // Already closed.
        }
        tunPfd = null
    }

    // ---- the core's log ------------------------------------------------

    private fun openLog(dir: File) {
        synchronized(logLock) {
            try {
                val f = File(dir, "psiphon.log")
                // Build 2067 (log hygiene, promised after the
                // 2066 device report): rotate at EVERY session
                // start, not only past 512 KB. The old
                // append-across-sessions shape let a previous
                // build's flood sit above the new session header
                // in the log viewer, and the owner read a stale
                // 2065 flood as 2066's current failure. The
                // previous session stays on disk as
                // psiphon.log.old; the live file now holds
                // exactly one session.
                val old = File(dir, "psiphon.log.old")
                if (f.exists()) {
                    if (old.exists()) old.delete()
                    f.renameTo(old)
                }
                // Build 2055 (audit B-M4): one buffered writer for
                // the session, flushed on a 2 s timer or 8 KB —
                // never open+write+close per diagnostic notice.
                closeLogLocked()
                logWriter = FileOutputStream(f, true).bufferedWriter()
                logBytesSinceFlush = 0
                logLastFlushMs = System.currentTimeMillis()
                lastLogLine = null
                logRepeatCount = 0
                logWriter?.write("\n==== psiphon session ${System.currentTimeMillis()} ====\n")
                // Build 2069: the start phase begins here, and
                // the header hits disk NOW — not whenever 8 KB
                // or a later line happens to flush it (the 2068
                // empty-log evidence). writeLogRawLocked keeps
                // flushing per line while logStartPhaseSync
                // holds; onConnected/fail/stopTunnel clear it
                // and the buffered policy resumes.
                logStartPhaseSync = true
                try {
                    logWriter?.flush()
                } catch (_: Exception) {
                    // Logging must never break the tunnel.
                }
                logBytesSinceFlush = 0
                logLastFlushMs = System.currentTimeMillis()
            } catch (e: Exception) {
                // Logging must never break the tunnel.
            }
        }
        // Build 2068 breadcrumb: the session log is open — the
        // last of the start trail's steps (step 10). A crash
        // paste whose trail ends earlier names its step by the
        // absence of this line; one that ends here died inside
        // the core start that follows.
        CrashLog.breadcrumb(this, "psiphon:openLog-completed")
    }

    private fun logLine(line: String) {
        synchronized(logLock) {
            // Build 2066: consecutive duplicates collapse into one
            // summary line ("(the previous line repeated N times)")
            // instead of one file line each. The 2065 device log
            // carried hundreds of identical core warnings in
            // seconds — file growth and a choked log viewer are a
            // defect of their own, independent of the warning's
            // cause. Every 100 repeats an interim summary is
            // written, so a still-flooding session stays visibly
            // alive in the log instead of going silent.
            if (line == lastLogLine) {
                logRepeatCount++
                if (logRepeatCount >= 100) {
                    writeLogRawLocked("(the previous line repeated 100 times)")
                    logRepeatCount = 0
                }
                return
            }
            flushLogRepeatLocked()
            lastLogLine = line
            writeLogRawLocked(line)
        }
    }

    /** Writes a pending repeat summary, if any. Callers hold
     *  [logLock]. */
    private fun flushLogRepeatLocked() {
        if (logRepeatCount > 0 && lastLogLine != null) {
            writeLogRawLocked("(the previous line repeated $logRepeatCount times)")
            logRepeatCount = 0
        }
    }

    /** One raw line into the session log. Callers hold [logLock]. */
    private fun writeLogRawLocked(line: String) {
        try {
            val w = logWriter
            if (w == null) {
                // The log was never opened (a notice before
                // start): the old one-shot write, not a crash.
                File(workDir(this), "psiphon.log").appendText(line + "\n")
                return
            }
            w.write(line)
            w.newLine()
            logBytesSinceFlush += line.length + 1
            val now = System.currentTimeMillis()
            // Build 2069: during the start phase
            // (logStartPhaseSync) every line flushes — a
            // failure between openLog and connected must be
            // visible in the file even if nothing ever writes
            // again. After the start phase the 2055 policy
            // (8 KB / 2 s) applies unchanged.
            if (logStartPhaseSync || logBytesSinceFlush >= 8192 || now - logLastFlushMs >= 2000) {
                w.flush()
                logBytesSinceFlush = 0
                logLastFlushMs = now
            }
        } catch (e: Exception) {
            // As above.
        }
    }

    /** Flushes and closes the session log writer, if open. */
    private fun closeLogLocked() {
        flushLogRepeatLocked()
        lastLogLine = null
        try {
            logWriter?.flush()
        } catch (_: Exception) {
        }
        try {
            logWriter?.close()
        } catch (_: Exception) {
        }
        logWriter = null
        logBytesSinceFlush = 0
        logStartPhaseSync = false
    }

    // ---- PsiphonTunnel.HostService --------------------------------------

    override fun getContext(): Context = this

    override fun getPsiphonConfig(): String = configJson

    // Build 2069 (transplant): NO loadLibrary override here —
    // ralysnd has none either. The transplanted wrapper is
    // ralysnd's own renamed AAR: its HostService default method
    // receives the renamed argument "pgjni" from the wrapper
    // and loads libpgjni.so itself, and its pg.Seq static init
    // asks for the same name. (Pre-2069 this service overrode
    // the callback to force "psiphoncore", the rebuilt AAR's
    // lib; that lib and that AAR are gone.)

    override fun bindToDevice(fileDescriptor: Long) {
        // Only meaningful while this service holds the VPN; the core
        // calls it for every socket it opens in VPN mode.
        if (!protect(fileDescriptor.toInt())) {
            throw Exception("protect($fileDescriptor) failed")
        }
    }

    override fun onDiagnosticMessage(message: String) {
        lastNoticeMs = System.currentTimeMillis()
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
        // Build 2069: the start phase is over — the session
        // log returns to the buffered policy.
        logStartPhaseSync = false
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
        // Build 2057 (audit F-M4): the core's own death signal.
        // A stop we asked for sets `stopping` first, so only an
        // unasked exit arms the watcher's teardown.
        // Build 2065: during the ladder, an exit belongs to the
        // attempt that just failed (very often one we stopped
        // ourselves at its budget) — it ends that attempt, never
        // the session.
        if (ladderActive) {
            attemptExited = true
        } else if (!stopping.get()) {
            coreExited = true
        }
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
        private const val EXTRA_MTU = "mtu"
        // Build 2057 (audit F-M4): capture IPv6 in the TUN only
        // when true (XraySettings.ipv6Route); false leaves the v6
        // address and the ::/0 route out entirely.
        private const val EXTRA_IPV6 = "ipv6"

        // Build 2065: the strategy ladder inputs.
        private const val EXTRA_RUNGS = "rungs"
        private const val EXTRA_COMPARTMENT = "compartment"
        private const val EXTRA_CLEAN_AKAMAI = "cleanAkamai"
        private const val EXTRA_CLEAN_FASTLY = "cleanFastly"
        private const val EXTRA_DISABLE_TIMEOUTS = "disableTimeouts"
        private const val EXTRA_CDN_FRONT = "cdnFront"

        // Build 2057 (audit F-M4): the core-liveness deadline —
        // 3 min grace for server discovery, then 60 s of total
        // diagnostic silence with no connection means dead.
        private const val CONNECT_DEADLINE_MS = 180000L
        private const val NOTICE_SILENCE_MS = 60000L

        private const val CHANNEL = "psiphon_status"
        private const val NOTIFICATION_ID = 3
        private const val TAG = "PsiphonVpnService"
        private const val MTU = 1500

        // Build 2066 (the badvpn bridge + blackhole bounds): the
        // legacy path's connected-wait before the TUN may be
        // raised; the post-connect tunnel-loss bound; and the
        // native bridge's unwind grace (ralysnd's
        // NATIVE_EXIT_GRACE_MS).
        private const val CONNECT_WAIT_MS = 120000L
        private const val TUNNEL_LOSS_MS = 90000L
        private const val BRIDGE_EXIT_GRACE_MS = 5000L

        // The bridge's address plan: the TUN interface is
        // 10.10.15.1/30; lwIP answers on the /30's other host
        // address. The core's UDP gateway intercept address —
        // UDPInterceptUdpgwServerAddress in the tunnel core.
        private const val TUN_ROUTER_ADDRESS = "10.10.15.2"
        private const val TUN_NETMASK = "255.255.255.252"
        private const val UDPGW_SERVER_ADDRESS = "127.0.0.1:7300"

        /** Guards the bridge's single-instance discipline; the
         *  last bridge thread is remembered across service
         *  instances because the native globals outlive them. */
        private val bridgeLock = Any()

        @Volatile
        private var lastBridgeThread: Thread? = null

        /** Where the native bridge's log lines go: the running
         *  service points this at its session log (the dedupe
         *  there applies); null outside a session. */
        @Volatile
        var bridgeLogSink: ((String) -> Unit)? = null

        /** Clamps a tunnel MTU to the offered range (build 2038,
         *  queue 2f): 1280 is the IPv6 minimum MTU (the floor),
         *  1500 the default ceiling. A corrupt or out-of-range
         *  value clamps instead of breaking a connect. */
        private fun clampMtu(mtu: Int) = mtu.coerceIn(1280, 1500)

        // Build 2073: the published state file. Since this build
        // the service runs in its own process (:psiphon — see the
        // manifest), so the main process can no longer read the
        // companion statics below: they live in the service's
        // process only. Every mutation of a state field republishes
        // a JSON snapshot of all ten fields to
        // workDir/psiphon_state.json (atomic write), and the main
        // process — MainActivity's psiphonState channel and
        // XrayVpnService's chain checks — reads that file through
        // publishedState()/publishedRunning()/publishedConnected().
        // filesDir is shared by all of the app's processes, which
        // makes the file the same class of channel as psiphon.log
        // and crash.log. Publishing is best-effort and can never
        // break a state change: a failed write leaves the previous
        // snapshot, exactly what a reader would have seen a moment
        // earlier.
        private const val STATE_FILE = "psiphon_state.json"

        /** Serializes snapshot writes (the setters fire from the
         *  worker, the core's callback threads, and the main
         *  thread of the service's process). */
        private val statePublishLock = Any()

        /** The application context of the service's process,
         *  captured in onCreate before any state can change;
         *  publishing is skipped until it exists. */
        @Volatile
        private var appContext: Context? = null

        /** Called by the service's onCreate: gives the setters
         *  below the context they publish through. */
        fun bindAppContext(context: Context) {
            appContext = context.applicationContext ?: context
        }

        @Volatile
        var running = false
            private set(value) {
                field = value
                publishState()
            }

        @Volatile
        var connected = false
            private set(value) {
                field = value
                publishState()
            }

        @Volatile
        var isVpnMode = true
            private set(value) {
                field = value
                publishState()
            }

        @Volatile
        var startedAtMs = 0L
            private set(value) {
                field = value
                publishState()
            }

        @Volatile
        var totalUp = 0L
            private set(value) {
                field = value
                publishState()
            }

        @Volatile
        var totalDown = 0L
            private set(value) {
                field = value
                publishState()
            }

        @Volatile
        var egressRegion = ""
            private set(value) {
                field = value
                publishState()
            }

        @Volatile
        var clientAddress = ""
            private set(value) {
                field = value
                publishState()
            }

        @Volatile
        var availableRegions: List<String> = emptyList()
            private set(value) {
                field = value
                publishState()
            }

        /** Build 2065: the ladder rung that connected ("" when the
         *  legacy single attempt is running or nothing won yet).
         *  The Dart side persists it as the network's winner memory. */
        @Volatile
        var activeMethod: String = ""
            internal set(value) {
                field = value
                publishState()
            }

        /**
         * Build 2073: snapshots all ten state fields to the
         * published state file. Runs on every state mutation (see
         * the setters above); cheap by construction — one small
         * JSON document, one atomic rename — and fully guarded:
         * state publishing is evidence plumbing, never behaviour,
         * so a failure here must not reach the caller that changed
         * the state.
         */
        private fun publishState() {
            try {
                val context = appContext ?: return
                synchronized(statePublishLock) {
                    val json = JSONObject()
                        .put("running", running)
                        .put("connected", connected)
                        .put("vpnMode", isVpnMode)
                        .put("sinceMs", startedAtMs)
                        .put("up", totalUp)
                        .put("down", totalDown)
                        .put("region", egressRegion)
                        .put("clientAddress", clientAddress)
                        .put("regions", JSONArray(availableRegions))
                        .put("method", activeMethod)
                        .put("publishedAtMs", System.currentTimeMillis())
                    AtomicFile.writeText(File(workDir(context), STATE_FILE), json.toString())
                }
            } catch (_: Throwable) {
                // Best-effort: the previous snapshot stays in
                // place (AtomicFile never tears), which is the
                // state a reader would have seen a moment ago.
            }
        }

        /**
         * Build 2073: the main process's view of the state above —
         * the published snapshot, in exactly the map shape
         * MainActivity's psiphonState channel has always returned.
         * A missing or unreadable file (the service has never run
         * in this install, or died before its first state change)
         * reads as the stopped defaults, the same values the
         * companion statics themselves start from.
         */
        fun publishedState(context: Context): Map<String, Any?> {
            val defaults: Map<String, Any?> = mapOf(
                "running" to false,
                "connected" to false,
                "vpnMode" to true,
                "sinceMs" to 0L,
                "up" to 0L,
                "down" to 0L,
                "region" to "",
                "clientAddress" to "",
                "regions" to emptyList<String>(),
                "method" to "",
            )
            return try {
                val file = File(workDir(context), STATE_FILE)
                if (!file.isFile) return defaults
                val json = JSONObject(file.readText())
                mapOf(
                    "running" to json.optBoolean("running", false),
                    "connected" to json.optBoolean("connected", false),
                    "vpnMode" to json.optBoolean("vpnMode", true),
                    "sinceMs" to json.optLong("sinceMs", 0L),
                    "up" to json.optLong("up", 0L),
                    "down" to json.optLong("down", 0L),
                    "region" to json.optString("region", ""),
                    "clientAddress" to json.optString("clientAddress", ""),
                    "regions" to json.optJSONArray("regions").toStringList(),
                    "method" to json.optString("method", ""),
                )
            } catch (_: Throwable) {
                defaults
            }
        }

        /** The published snapshot's running flag (build 2073):
         *  XrayVpnService's chain checks read this instead of the
         *  companion static, which lives in the :psiphon process. */
        fun publishedRunning(context: Context): Boolean =
            publishedState(context)["running"] == true

        /** The published snapshot's connected flag (build 2073). */
        fun publishedConnected(context: Context): Boolean =
            publishedState(context)["connected"] == true

        private fun JSONArray?.toStringList(): List<String> {
            val array = this ?: return emptyList()
            return List(array.length()) { index -> array.optString(index, "") }
        }

        /** The Psiphon mode's files: core data root and logs. */
        fun workDir(context: Context): File = File(context.filesDir, "psiphon")

        fun start(
            context: Context,
            vpnMode: Boolean,
            region: String,
            upstream: String,
            protocols: List<String>,
            dns: String,
            mtu: Int = 1500,
            // Build 2057 (audit F-M4): default true keeps the old
            // capture-everything behaviour for callers that do not
            // pass it yet (MainActivity reads the Dart 'ipv6' value
            // and passes it here).
            ipv6: Boolean = true,
            // Build 2065: ladder inputs; the defaults reproduce the
            // pre-2065 single-attempt start exactly.
            rungs: List<String> = emptyList(),
            compartment: String = "",
            cleanAkamai: List<String> = emptyList(),
            cleanFastly: List<String> = emptyList(),
            disableTimeouts: Boolean = false,
            cdnFront: Boolean = false,
        ) {
            val intent = Intent(context, PsiphonVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_VPN_MODE, vpnMode)
                putExtra(EXTRA_REGION, region)
                putExtra(EXTRA_UPSTREAM, upstream)
                putStringArrayListExtra(EXTRA_PROTOCOLS, ArrayList(protocols))
                putExtra(EXTRA_DNS, dns)
                putExtra(EXTRA_MTU, clampMtu(mtu))
                putExtra(EXTRA_IPV6, ipv6)
                putStringArrayListExtra(EXTRA_RUNGS, ArrayList(rungs))
                putExtra(EXTRA_COMPARTMENT, compartment)
                putStringArrayListExtra(EXTRA_CLEAN_AKAMAI, ArrayList(cleanAkamai))
                putStringArrayListExtra(EXTRA_CLEAN_FASTLY, ArrayList(cleanFastly))
                putExtra(EXTRA_DISABLE_TIMEOUTS, disableTimeouts)
                putExtra(EXTRA_CDN_FRONT, cdnFront)
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

/**
 * The badvpn logger's callback target (build 2066). The native
 * side calls [logTun2Socks] on this class BY NAME (wired in
 * startBridge via Tun2SocksJniLoader.initializeLogger), so the
 * class and method names are a native contract — do not rename.
 * Lines route into the running service's session log.
 */
object PsiphonTun2SocksLog {
    @JvmStatic
    fun logTun2Socks(level: String?, channel: String?, msg: String?) {
        val line = "tun2socks ${level ?: ""} ${channel ?: ""}: ${msg ?: ""}".trim()
        PsiphonVpnService.bridgeLogSink?.invoke(line)
    }
}
