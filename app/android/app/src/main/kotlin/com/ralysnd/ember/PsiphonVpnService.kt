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
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Base64
import android.util.Log
import ca.psiphon.PsiphonTunnel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

/**
 * The Psiphon engine: the tunnel core from the bundled AAR
 * (libs/psiphon.aar) in whole-device VPN mode (its SOCKS bridged
 * into a TUN this service raises FIRST) or in proxy-only mode
 * (its SOCKS on [PsiphonConstants.SOCKS_PORT] is the product —
 * the chain dials it, and so does the exit-IP lookup).
 *
 * Build 2091 — THE MLM TRANSPLANT. The provider is the ralysnd
 * (MLM) app's Psiphon, implemented completely from its source
 * (the owner's order; phase-1 analysis:
 * mlm-psiphon-full-analysis.md, whose §9 is this build's spec):
 *
 *  - the byte-exact AAR MLM ships (psiphontunnel-2.0.39-ns,
 *    sha256 426c0fda…) is the core again, and MLM's 493-entry
 *    server_entries.txt is the bootstrap floor handed to it as
 *    a string at every start. The 2089/2090 sing-box sidecar is
 *    retired from the start path (PsiphonBoxCore and the fork
 *    stay on disk as the documented fallback; libpsiphonbox.so
 *    leaves the APK);
 *  - the host is MLM's, ported: its config builder WITH MLM's
 *    identity set and the anti-hijack DNS trio, the full
 *    escalation ladder (rungs A/E/D/C/P/X with MLM's budgets,
 *    the 25 s region phase in front of it, winner attribution
 *    deferred 2 s past connect, per-mode winner memory), the
 *    tactics override on A/E/D, the server-quality gate before
 *    routing (6 streams, 768 KB, 0.9 Mbit/s floor, at most 3
 *    draws per rung, replay-state drop between draws), and
 *    MLM's badvpn bridge (Tun2SocksManager, ported alongside)
 *    on a collision-free address plan;
 *  - the protection stack the analysis (§2) exists for:
 *    setVpnMode(false) ALWAYS (this service bridges), every
 *    core socket protect()ed through the HostService binding,
 *    the TUN raised BEFORE the core starts (its NetworkMonitor
 *    never sees tun0 appear), this package disallowed from the
 *    TUN in every split mode, the underlying network tracked
 *    and handed to the service, and the TUN's DNS = the lwIP
 *    router + 1.1.1.1 + 8.8.8.8 (the bootstrap-deadlock break);
 *  - connected means the CORE connected and passed the quality
 *    gate — in BOTH modes now (proxy mode's old
 *    success-at-running contract is closed; the SOCKS data
 *    probe of 2089/2090 is retired with the sidecar).
 *
 * The one deliberate deviation from MLM, recorded per §9.2:
 * MLM hosts this core in its main process; Ember keeps it in
 * the :psiphon process (the manifest's android:process),
 * because MLM's own evidence shows the gomobile runtime
 * aborts when a second runtime loads beside it and Ember's
 * 2073 experiment falsified co-residency as the wedge cause —
 * process isolation is also what bounds risk R1 (below).
 *
 * Risk R1 (the analysis §9.5, in substance): the library wedge
 * of builds 2065–2088 may recur at the first library call —
 * the shared v2.0.39 gomobile runtime on the owner's Android
 * 16 phone; MLM's own app crashes there too, and no host
 * variable moved that frontier in 24 builds. No host-level
 * mitigation exists; the bound is the :psiphon isolation plus
 * the external watchdog: a wedged start presents as ONE
 * failed, fully-logged attempt and the app never dies. The
 * escape, if R1 fires, is a sidecar-hardening build (the
 * on-disk fork carrying MLM's semantics in its box config).
 *
 * State is published to a file (see the companion): this
 * service runs in its own process (:psiphon), so its statics
 * are invisible to the main process; the snapshot is the
 * contract, in the shape it has had since build 2073.
 */
class PsiphonVpnService : VpnService(), PsiphonTunnel.HostService {

    private val worker = Executors.newSingleThreadExecutor()

    /** The ladder's scheduler (MLM's shape): one thread,
     *  DiscardPolicy — late work is dropped, not thrown; a
     *  timer that fires a moment after teardown used to crash
     *  MLM's app with RejectedExecutionException (its 1.2.39
     *  crash reports), so the policy is part of the port. */
    private val ladderScheduler: ScheduledExecutorService =
        java.util.concurrent.ScheduledThreadPoolExecutor(
            1, ThreadPoolExecutor.DiscardPolicy(),
        )

    private val stopping = AtomicBoolean(false)

    @Volatile
    private var tunPfd: ParcelFileDescriptor? = null

    /** The bridge has been started for this session (VPN mode). */
    @Volatile
    private var bridgeStarted = false

    // ---- the session's inputs (the start intent, verbatim) --

    @Volatile
    private var inVpnMode = true

    /** Build 2125 (audit A25-04 / plan S-4): the Settings
     *  kill switch, carried on the start intent like the
     *  Xray host's. When a LIVE session dies unexpectedly
     *  with the switch on, the service holds its TUN as a
     *  blackhole (see holdKillSwitch) instead of closing
     *  it — up to 2124 the switch enforced only in
     *  XrayVpnService and a dead Psiphon session silently
     *  returned the device to direct traffic. */
    @Volatile
    private var inKillSwitch = false

    /**
     * Build 2123 (plan §5, audit P-01): true only when THIS
     * service instance claimed the VPN slot — which happens
     * only for a TUN-mode start. A proxy-only (chain underlay)
     * start owns no TUN and must never claim, displace, or
     * release the marker; its stop paths consult this flag so
     * they cannot touch the host session's claim.
     */
    @Volatile
    private var claimedSlot = false

    @Volatile
    private var inRegion = ""

    @Volatile
    private var inUpstream = ""

    @Volatile
    private var inRungs: List<String> = emptyList()

    @Volatile
    private var inCompartment = ""

    @Volatile
    private var inCleanAkamai: List<String> = emptyList()

    @Volatile
    private var inCleanFastly: List<String> = emptyList()

    // Build 2129 (Leg 2): the Shiro bootstrap toggle and the
    // strong-mode toggle. Both DEFAULT OFF; with both off the
    // config builder and the entries hand-off below are the
    // 2128 code path value-for-value.
    @Volatile
    private var inShiroBootstrap = false

    @Volatile
    private var inStrongMode = false

    @Volatile
    private var inMtu = MTU

    // ---- the core + the ladder (MLM's state, ported) --------

    @Volatile
    private var psiphonTunnel: PsiphonTunnel? = null

    @Volatile
    private var sessionLadder: List<PsiphonStrategy> = emptyList()

    @Volatile
    private var ladderIndex = 0

    @Volatile
    private var ladderAttempts = 0

    @Volatile
    private var ladderTimer: ScheduledFuture<*>? = null

    private val ladderActive = AtomicBoolean(false)

    private val attributionPending = AtomicBoolean(false)

    /** Whether this attempt is the short preferred-country
     *  attempt that runs in front of the ladder (MLM's
     *  regionPhase). A failed region phase is NOT a failed
     *  rung: the flag clears and the same rung restarts
     *  unfiltered. */
    @Volatile
    private var regionPhase = false

    /** Whether the session carries upstream candidates (its
     *  ladder is upstream-fed; the winner memory is keyed by
     *  this, as MLM keys its by mode). */
    @Volatile
    private var sessionHasUpstream = false

    /** The protocol of the tunnel that connected, from the
     *  core's ActiveTunnel notice — the attribution input. */
    @Volatile
    private var activeTunnelProtocol = ""

    /** Broker evidence from the notices (attribution's
     *  fallback signal only — it has been seen during a plain
     *  direct tunnel, so it never outranks protocol evidence). */
    @Volatile
    private var inproxyInUse = false

    /** A session whose routing was activated (VPN mode: the
     *  bridge started). MLM's psiphonVpnActivated — the
     *  onExiting guard keys on it: an exit before activation
     *  escalates the ladder; an exit after it, with the
     *  session connected, is a lost tunnel. */
    @Volatile
    private var routingActivated = false

    /** The config the library pulls through getPsiphonConfig()
     *  at every start (the gomobile host contract: the config
     *  is supplied by the host, not by startTunneling). */
    @Volatile
    private var psiphonConfigJson = ""

    // ---- the quality gate's state (MLM's, ported) -----------

    @Volatile
    private var psiphonQualityDone = false

    /** Which server of this rung is being measured, 1-based;
     *  back to 1 on every new rung. */
    @Volatile
    private var psiphonQualityAttempts = 1

    /** A measurement that outlived its connect (a stop, a
     *  newer one) must not act. */
    @Volatile
    private var psiphonQualityGen = 0

    @Volatile
    private var psiphonRungStartedAt = 0L

    /** Server-policy refusals seen in the notices (evidence). */
    @Volatile
    private var policyRefusals = 0

    /** The fronted regions of the bundled entries, parsed
     *  lazily once per process (the region phase's filter).
     *  Build 2129 (Leg 2): the cache is keyed by the bootstrap
     *  in play — the Shiro entries asset has its own region
     *  set, and a cached MLM-set parse must never answer for
     *  a Shiro start (or the reverse). */
    @Volatile
    private var frontedRegionsCache: Set<String>? = null

    @Volatile
    private var frontedRegionsCacheShiro: Boolean? = null

    /** Build 2129 (Leg 2): the parsed Shiro fronting-override
     *  CIDRs (see shiroPreresolvedCidrs); parsed once — the
     *  asset is bundled and immutable. */
    @Volatile
    private var shiroCidrsCache: Map<String, List<String>>? = null

    /** The underlying-network tracker (MLM's §2 item 4). */
    @Volatile
    private var underlyingCallback: ConnectivityManager.NetworkCallback? = null

    // ---- logging (build 2055/2066/2067/2069 discipline) -----

    private val logLock = Any()
    private var logWriter: java.io.BufferedWriter? = null
    private var logBytesSinceFlush = 0

    // Build 2095 (third-pass audit 6-2): the in-session log
    // total + whether the mid-session rotation already ran
    // (the per-session rotation at open caps ACROSS sessions;
    // a single long session was unbounded).
    private var logBytesTotal = 0
    private var logRotatedInSession = false
    private var logLastFlushMs = 0L
    private var lastLogLine: String? = null
    private var logRepeatCount = 0

    /** Build 2069: while the start phase runs, every session
     *  log line flushes to disk synchronously. A start that
     *  wedges or aborts natively can then never take the
     *  session's own record with it: the file on disk ends at
     *  the last step that actually completed. Cleared when
     *  the attempt resolves (the quality gate's pass, fail,
     *  stop). */
    @Volatile
    private var logStartPhaseSync = false

    // ---- the start-wedge instrumentation (build 2087) -------
    //
    // The heartbeat + startInFlight + the startReturned
    // bracket, retargeted per the analysis §9.2: startReturned
    // now brackets the core's startTunneling call (the wedge
    // frontier of 2065–2088), and the external watchdog
    // (PsiphonExternalWatchdog, armed from the Dart connect
    // path) remains the bound if the call never returns.

    /** True while a startTunneling call is being made. The
     *  heartbeat below is gated on it. */
    @Volatile
    private var startInFlight = false

    private val heartbeatHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var heartbeatPosted = false

    private val heartbeatRunnable = object : Runnable {
        override fun run() {
            if (!startInFlight) {
                heartbeatPosted = false
                return
            }
            CrashLog.breadcrumb(this@PsiphonVpnService, "psiphon:heartbeat")
            heartbeatHandler.postDelayed(this, HEARTBEAT_MS)
        }
    }

    /** Posts the heartbeat loop if it is not already running. */
    private fun armHeartbeat() {
        if (heartbeatPosted) return
        heartbeatPosted = true
        heartbeatHandler.postDelayed(heartbeatRunnable, HEARTBEAT_MS)
    }

    override fun onCreate() {
        super.onCreate()
        // Build 2073: state publishing needs a context from
        // the moment the first field can change.
        bindAppContext(this)
        // The bridge's lines belong in this session's log.
        Tun2SocksManager.logger = { line -> logLine(line) }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Build 2069: the whole dispatch is Throwable-guarded
        // (kept) — a failure anywhere in it is recorded in
        // crash.log first, then the service stops the
        // ordinary way.
        try {
            if (intent?.action == ACTION_STOP) {
                stopTunnel()
                // Build 2116 (B7-1): the claim is released.
                // Build 2123 (plan §5): only when this instance
                // actually claimed it — a proxy-only session's
                // stop must never touch the host's marker.
                // (Release is owner-checked besides; a stale
                // marker left by a killed process is cleared by
                // the shell's re-arbitration, per EngineClaim.)
                if (claimedSlot) {
                    EngineClaim.release(this, EngineClaim.PSIPHON)
                    claimedSlot = false
                }
                return START_NOT_STICKY
            }
            if (intent?.action == ACTION_START) {
                // Build 2123 (plan §5, audit P-01): the extras
                // are parsed FIRST and the claim moved below
                // the already-running refusal, gated on the
                // mode — up to 2121 the claim ran
                // unconditionally at the head of the branch, so
                // a proxy-only chain-underlay start claimed the
                // VPN slot, displaced the very host session
                // that started it, and the host's own claim
                // then displaced the underlay in return
                // (the chained-session ping-pong death), and a
                // refused duplicate start had already displaced
                // the running engine (S-6).
                inVpnMode = intent.getBooleanExtra(EXTRA_VPN_MODE, true)
                // Build 2125 (A25-04 / S-4): the kill
                // switch, read with the other inputs.
                inKillSwitch = intent.getBooleanExtra(EXTRA_KILL_SWITCH, false)
                inRegion = intent.getStringExtra(EXTRA_REGION)?.trim()?.uppercase() ?: ""
                inUpstream = intent.getStringExtra(EXTRA_UPSTREAM) ?: ""
                inRungs = intent.getStringArrayListExtra(EXTRA_RUNGS) ?: emptyList()
                inCompartment = intent.getStringExtra(EXTRA_COMPARTMENT) ?: ""
                inCleanAkamai = intent.getStringArrayListExtra(EXTRA_CLEAN_AKAMAI) ?: emptyList()
                inCleanFastly = intent.getStringArrayListExtra(EXTRA_CLEAN_FASTLY) ?: emptyList()
                // Build 2129 (Leg 2): both default false —
                // an intent from an older build (or the Xray
                // underlay call site, which never sends them)
                // keeps the 2128 behaviour exactly.
                inShiroBootstrap = intent.getBooleanExtra(EXTRA_SHIRO_BOOTSTRAP, false)
                inStrongMode = intent.getBooleanExtra(EXTRA_STRONG_MODE, false)
                inMtu = clampMtu(intent.getIntExtra(EXTRA_MTU, MTU))
                // Carried inputs the MLM host does not consume,
                // named rather than silently dropped (build
                // 2091): the protocols multi-select (the ladder
                // owns protocol selection now — the stored
                // value stays in settings, unused on this path),
                // the dns extra (the TUN's DNS is MLM's trio:
                // the lwIP router + 1.1.1.1 + 8.8.8.8), the
                // ipv6 flag (not consulted: since build 2123
                // the TUN captures v6 unconditionally and
                // drops it — S-3; the flag's sender keeps
                // threading it and it stays inert),
                // and the two parked 2065 flags.
                val protocols = intent.getStringArrayListExtra(EXTRA_PROTOCOLS) ?: emptyList()
                val disableTimeouts = intent.getBooleanExtra(EXTRA_DISABLE_TIMEOUTS, false)
                val cdnFront = intent.getBooleanExtra(EXTRA_CDN_FRONT, false)
                if (running) {
                    // Build 2087: the breadcrumb distinguishes
                    // "the start was refused because a session
                    // is live" from every other start failure.
                    CrashLog.breadcrumb(this, "psiphon:start-ignored-in-flight")
                    Log.w(TAG, "psiphon start ignored: a session is already live")
                    return START_NOT_STICKY
                }
                if (killSwitchHeld) {
                    // Build 2125 (A25-04 / S-4): a fresh
                    // start over a kill-switch hold — the
                    // held TUN is the dead session's
                    // blackhole; close it and clear the hold
                    // before this start establishes its own
                    // interface. (The claim below re-claims
                    // the slot this service never released.)
                    killSwitchHeld = false
                    try {
                        tunPfd?.close()
                    } catch (e: Exception) {
                        // Already closed.
                    }
                    tunPfd = null
                }
                if (inVpnMode) {
                    // Build 2116 (B7-1, AB-08): claim the VPN
                    // slot through the native single-writer
                    // claim, displacing any other engine. (This
                    // service runs in the :psiphon process; the
                    // marker lives in the shared filesDir.)
                    // Build 2123 (plan §5): TUN mode only — a
                    // proxy-only underlay owns no TUN and never
                    // claims.
                    EngineClaim.claim(this, EngineClaim.PSIPHON)
                    claimedSlot = true
                }
                if (protocols.isNotEmpty() || disableTimeouts || cdnFront) {
                    CrashLog.breadcrumb(this, "psiphon:parked-inputs-noted")
                }
                worker.execute { startTunnel() }
            }
        } catch (e: Throwable) {
            CrashLog.append(this, "PsiphonVpnService.onStartCommand", e)
            stopTunnel()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        // Build 2116 (B7-1): teardown releases the claim
        // (owner-checked). Build 2123 (plan §5): only when
        // this instance claimed it — see ACTION_STOP.
        if (claimedSlot) {
            EngineClaim.release(this, EngineClaim.PSIPHON)
            claimedSlot = false
        }
        stopProcesses()
        try {
            ladderScheduler.shutdownNow()
        } catch (_: Throwable) {
            // Already down.
        }
        super.onDestroy()
    }

    /** A system revoke (the user turned the VPN off from
     *  Settings) ends the session like a stop. */
    override fun onRevoke() {
        stopTunnel()
    }

    // ---- the start ------------------------------------------

    private fun startTunnel() {
        // Build 2087: a new attempt clears the previous
        // attempt's wedge record — the flag means "the CURRENT
        // start wedged", and a stale one would fail this
        // attempt at its first state sample.
        wedged = false
        // Build 2088: no start is outstanding until the core's
        // start call is entered (startPsiphonTunnel brackets
        // it); a fresh process must never read as a start
        // still inside the library.
        startReturned = true
        val dir = workDir(this)
        try {
            dir.mkdirs()
        } catch (e: Exception) {
            // The writes below will fail in the open.
        }
        openLog(dir)
        // Build 2087 (F2) — SPENT, kept as the record: the
        // one-time wipe of the core's pre-2087 data roots ran
        // on the owner's phone in build 2087 and its verdict
        // closed the stale-data theory; the marker check stays
        // so the wipe can never run twice, and the transplant
        // keeps the core's data inside this same work dir.
        try {
            val marker = File(dir, "f2-wiped-2087")
            if (!marker.exists()) {
                marker.writeText("f2 wipe already spent in build 2087; no-op in 2091\n")
            }
        } catch (e: Exception) {
            // The marker is bookkeeping; never the start.
        }
        // Build 2068 breadcrumb: the provider this build runs
        // (step 6 of the start trail).
        CrashLog.breadcrumb(this, "psiphon:provider-$PROVIDER_TAG")
        logLine("psiphon provider: $PROVIDER_ID")
        running = true
        isVpnMode = inVpnMode
        egressRegion = inRegion
        startedAtMs = System.currentTimeMillis()
        startInForeground()
        stopping.set(false)
        beginSession()
        // The ladder first, before the TUN exists: a pinned
        // method with nothing to work with fails here without
        // the device ever being routed into a tunnel that
        // cannot come up (MLM's order, kept).
        if (!preparePsiphonLadder()) return
        if (inVpnMode) {
            if (prepare(this) != null) {
                Log.w(TAG, "the VPN has no permission")
                failAndStop("the VPN has no permission")
                return
            }
            // Create the TUN first, then start Psiphon: this
            // stops Psiphon's NetworkMonitor seeing tun0 appear
            // as a network change, which used to cause a
            // 13-second restart loop (MLM's §2 item 2).
            val address = Tun2SocksManager.selectPrivateAddress()
            val builder = Builder()
                .setSession(getString(R.string.app_name))
                .setMtu(inMtu)
                .addAddress(address.ipAddress, address.prefixLength)
                .addRoute("0.0.0.0", 0)
                .addRoute(address.subnet, address.prefixLength)
                // Build 2123 (S-3, audit P-04): IPv6
                // capture-and-drop. MLM's bridge is IPv4-only,
                // so up to 2121 the TUN carried no v6 address
                // or route and the session's IPv6 containment
                // rested entirely on platform behaviour. Now
                // the interface takes a unique-local address
                // (fd00::/8 is never routable on the public
                // internet) plus the ::/0 route, so v6 traffic
                // enters the TUN and dies there: the v4-only
                // lwIP stack behind Tun2SocksManager has no v6
                // egress at all, and its input path drops
                // non-v4 packets. Apps fall back to IPv4 — a
                // connection that works instead of a possible
                // leak. This is MLM's own production pattern
                // for a v4-only gateway (their IPV6_BLACKHOLE,
                // TunnelVpnService.applyTunnelAddresses),
                // adopted verbatim including the address.
                // Safe at every MTU this service allows:
                // clampMtu keeps the TUN at 1280+, IPv6's
                // minimum link MTU — below it the kernel
                // refuses a v6 address and establish() fails.
                .addAddress(IPV6_BLACKHOLE, 128)
                .addRoute("::", 0)
                .addDnsServer(address.router)
                // Strategy A (MLM's, kept verbatim in
                // substance): with only the lwIP router as
                // resolver, every DNS query goes lwIP → udpgw
                // → Psiphon — dead exactly when Psiphon needs
                // to resolve the CDN hostnames FRONTED-MEEK
                // depends on, before any tunnel exists. The
                // public resolvers give it somewhere to go;
                // combined with this package being disallowed
                // from the TUN (applyApps), the core's own
                // queries leave over the carrier link and
                // resolve normally.
                .addDnsServer("1.1.1.1")
                .addDnsServer("8.8.8.8")
            applyApps(builder)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
            val pfd = try {
                builder.establish()
            } catch (e: Throwable) {
                CrashLog.append(this, "PsiphonVpnService.establish", e)
                null
            }
            if (pfd == null) {
                Log.e(TAG, "establish() returned null")
                failAndStop("Android could not establish the VPN interface")
                return
            }
            tunPfd = pfd
            trackUnderlyingNetwork()
            logLine("TUN ready — now starting Psiphon on port ${PsiphonConstants.SOCKS_PORT}")
            // Build 2123 (S-3): the session's evidence that
            // v6 is contained by construction this run.
            logLine("IPv6: captured via $IPV6_BLACKHOLE + ::/0 and dropped (bridge is IPv4-only)")
        }
        startPsiphonTunnel()
        if (inVpnMode) watchBridge()
    }

    /** Resets every per-session ladder/quality field (MLM's
     *  beginPsiphonSession, adapted to this service's inputs). */
    private fun beginSession() {
        ladderIndex = 0
        ladderAttempts = 0
        ladderTimer?.cancel(false)
        ladderTimer = null
        ladderActive.set(true)
        attributionPending.set(false)
        regionPhase = inRegion.isNotEmpty()
        sessionHasUpstream = inUpstream.isNotBlank()
        routingActivated = false
        activeTunnelProtocol = ""
        inproxyInUse = false
        psiphonQualityDone = false
        psiphonQualityAttempts = 1
        psiphonQualityGen++
        psiphonRungStartedAt = 0L
        policyRefusals = 0
        totalUp = 0
        totalDown = 0
        clientAddress = ""
        activeMethod = ""
    }

    // ---- the ladder (MLM's, ported) --------------------------

    /** One rung of the ladder: a name, a budget, the protocols
     *  that prove it for attribution, an optional data root of
     *  its own, an optional upstream, and its config overrides
     *  on top of the base config. */
    private data class PsiphonStrategy(
        val name: String,
        val label: String,
        val timeoutSeconds: Int,
        val preferredProtocols: List<String>,
        val dataRoot: File? = null,
        val upstream: UpstreamCandidate? = null,
        val configure: (JSONObject) -> Unit,
    )

    /** An upstream proxy candidate for rung X. Ember's settings
     *  carry one user proxy (MLM's «پروکسی سرور» custom mode —
     *  its candidates() returns exactly that one); MLM's
     *  measured candidate lists and their re-proving probes
     *  are measurement infrastructure and are not ported
     *  (analysis §9.3). The rung's own attempt is the proof;
     *  its failure is the note. */
    private data class UpstreamCandidate(val url: String, val label: String)

    private fun upstreamCandidates(): List<UpstreamCandidate> {
        val url = inUpstream.trim()
        return if (url.isEmpty()) emptyList()
        else listOf(UpstreamCandidate(url, "custom"))
    }

    /** Builds the session ladder; a pinned method with nothing
     *  to work with fails the session HERE, with the reason —
     *  before any TUN exists (MLM's preparePsiphonLadder). */
    private fun preparePsiphonLadder(): Boolean {
        val pinned = if (inRungs.size == 1) inRungs[0] else PsiphonMethods.AUTO
        val membership = if (inRungs.size > 1) inRungs.toSet() else null
        sessionLadder = try {
            buildSessionLadder(pinned, membership, upstreamCandidates())
        } catch (e: IllegalStateException) {
            failAndStop(e.message ?: "the picked Psiphon method is not available")
            return false
        }
        if (sessionLadder.isEmpty()) {
            failAndStop("No Psiphon method is available for this connection.")
            return false
        }
        logLine(
            "psiphon ladder: " +
                sessionLadder.joinToString(" → ") { "${it.name} (${it.timeoutSeconds}s)" } +
                if (regionPhase) " — region phase first: $inRegion, ${REGION_PHASE_TIMEOUT_SECONDS}s" else "",
        )
        return true
    }

    /**
     * The ladder for this connect (MLM's buildSessionLadder,
     * ported):
     *
     *  - a pinned method (A/E/D/C/P): that rung alone. X is
     *    never pinned alone in MLM — «پروکسی سرور» means the
     *    upstream rungs in front of the automatic ladder;
     *  - automatic: A, E (only with clean addresses), D, C —
     *    with the rung that carried the last tunnel in this
     *    mode moved to the FRONT;
     *  - the upstream rungs ride in front of the automatic
     *    ladder when an upstream is set.
     *
     * The Dart side's rung list is the membership SET (its
     * availability + bridge-mode policy already applied);
     * ordering and remembered-first are the service's, per
     * MLM. MLM's chainMode (its Psiphon-over-WARP topology,
     * which excludes C/P from chained ladders) is not taken —
     * analysis §9.3; Ember's upstream rungs are per-rung, and
     * the direct ladder behind them keeps C, exactly as MLM
     * composes upstream + auto when not WARP-chained.
     *
     * Throws with a sentence for the user when the pinned
     * method has nothing to work with.
     */
    private fun buildSessionLadder(
        pinned: String,
        membership: Set<String>?,
        upstream: List<UpstreamCandidate>,
    ): List<PsiphonStrategy> {
        if (pinned in listOf("A", "E", "D", "C", "P")) {
            return listOf(
                psiphonRung(pinned) ?: throw IllegalStateException(
                    when (pinned) {
                        "E" -> "There is no clean IP yet — open Psiphon settings → CDN edges and run Test all."
                        "P" -> "No Conduit pairing link yet — add one in Psiphon settings."
                        else -> "The picked Psiphon method is not available."
                    },
                ),
            )
        }
        var auto = PsiphonMethods.LADDER_ORDER
            .filter { it != "P" }
            .filter { membership == null || it in membership }
            .mapNotNull { psiphonRung(it) }
        PsiphonMethods.remembered(this, upstream.isNotEmpty())?.let { last ->
            val i = auto.indexOfFirst { it.name == last }
            if (i > 0) auto = listOf(auto[i]) + auto.filterIndexed { k, _ -> k != i }
        }
        val upstreamRungs =
            if (membership == null || "X" in membership) {
                upstream.map { upstreamRung(it) }
            } else {
                emptyList()
            }
        return upstreamRungs + auto
    }

    /** One named rung, or null when it has nothing to work
     *  with on this device yet (MLM's psiphonRung, ported). */
    private fun psiphonRung(name: String): PsiphonStrategy? = when (name) {
        "A" -> PsiphonStrategy(
            name = "A",
            label = PsiphonMethods.label("A"),
            timeoutSeconds = PsiphonMethods.seconds("A"),
            preferredProtocols = PsiphonConstants.FRONTED_PROTOCOLS,
        ) { config ->
            // A hard limit as well as the initial preference,
            // so the rung's whole budget is spent on fronted
            // candidates instead of lapsing back to the direct
            // entries that are null-routed on this carrier.
            // Rung D is where direct protocols get their turn.
            config.put("InitialLimitTunnelProtocols", JSONArray(PsiphonConstants.FRONTED_PROTOCOLS))
            config.put("InitialLimitTunnelProtocolsCandidateCount", 30)
            config.put("LimitTunnelProtocols", JSONArray(PsiphonConstants.FRONTED_PROTOCOLS))
            config.put("ConnectionWorkerPoolSize", 12)
            // CDN paths are legitimately slower than a direct
            // dial; without this Psiphon abandons them as if
            // they were dead.
            config.put("NetworkLatencyMultiplier", 2.0)
            // Build 2129 (Leg 2): in Shiro mode the public
            // fronting overrides ride the fronted rung as
            // preresolved CIDRs (see shiroPreresolvedCidrs).
            // Off, the map is empty and neither key is
            // written — the 2128 rung-A shape.
            val shiroCidrsA = shiroPreresolvedCidrs()
            if (shiroCidrsA.isNotEmpty()) {
                config.put("DNSResolverPreresolvedIPAddressCIDRs", JSONObject().apply {
                    shiroCidrsA.forEach { (provider, list) -> put(provider, JSONArray(list)) }
                })
                config.put("DNSResolverPreresolvedIPAddressProbability", 1.0)
            }
            applyTacticsOverride(config)
        }
        "E" -> {
            val cidrs = cleanCidrs()
            if (cidrs.isEmpty()) {
                null
            } else {
                PsiphonStrategy(
                    name = "E",
                    label = PsiphonMethods.label("E"),
                    timeoutSeconds = PsiphonMethods.seconds("E"),
                    preferredProtocols = listOf("FRONTED-MEEK-OSSH"),
                    dataRoot = File(workDir(this), "psiphon-clean"),
                ) { config ->
                    // Only FRONTED-MEEK-OSSH: the HTTP variant
                    // dials port 80 (the scan measured 443) and
                    // the QUIC one never connected on the
                    // desktop's line.
                    config.put("LimitTunnelProtocols", JSONArray(listOf("FRONTED-MEEK-OSSH")))
                    config.put("InitialLimitTunnelProtocols", JSONArray(listOf("FRONTED-MEEK-OSSH")))
                    config.put("InitialLimitTunnelProtocolsCandidateCount", 30)
                    // Build 2129 (Leg 2): in Shiro mode the
                    // public fronting overrides merge into
                    // the same map (union per provider); off,
                    // the map is exactly the owner's clean IPs.
                    val mergedCidrs = LinkedHashMap<String, List<String>>()
                    cidrs.forEach { (provider, list) -> mergedCidrs[provider] = list }
                    shiroPreresolvedCidrs().forEach { (provider, list) ->
                        mergedCidrs[provider] =
                            ((mergedCidrs[provider] ?: emptyList()) + list).distinct()
                    }
                    config.put("DNSResolverPreresolvedIPAddressCIDRs", JSONObject().apply {
                        mergedCidrs.forEach { (provider, list) -> put(provider, JSONArray(list)) }
                    })
                    config.put("DNSResolverPreresolvedIPAddressProbability", 1.0)
                    config.put("ConnectionWorkerPoolSize", 8)
                    config.put("NetworkLatencyMultiplier", 1.5)
                    applyTacticsOverride(config)
                }
            }
        }
        "D" -> PsiphonStrategy(
            name = "D",
            label = PsiphonMethods.label("D"),
            timeoutSeconds = PsiphonMethods.seconds("D"),
            preferredProtocols = PsiphonConstants.DIRECT_PROTOCOLS,
        ) { config ->
            // No protocol limit at all: Psiphon uses its own
            // full set and its own replay/tactics ordering.
            // This is the rung that wins on a carrier which is
            // not blocking anything, and the safety net if the
            // CDN fronts themselves ever get blocked.
            config.put("ConnectionWorkerPoolSize", 16)
            applyTacticsOverride(config)
        }
        "C" -> PsiphonStrategy(
            name = "C",
            label = PsiphonMethods.label("C"),
            timeoutSeconds = PsiphonMethods.seconds("C"),
            preferredProtocols = emptyList(),
        ) { config ->
            // In-proxy routes through other Psiphon users'
            // devices over WebRTC. Their addresses are
            // residential and on no carrier blocklist — the
            // last resort when every server IP and CDN front
            // is unreachable. Deliberately NOT naming
            // INPROXY-* protocols: those names are assembled
            // at runtime inside the core, so passing one risks
            // failing config validation and killing the rung;
            // the flags below are enough.
            config.put("InproxyEnabled", true)
            config.put("InproxyAllowClient", true)
            config.put("InproxySkipAwaitFullyConnected", true)
            config.put("ConnectionWorkerPoolSize", 16)
            config.put("NetworkLatencyMultiplier", 3.0)
        }
        "P" -> {
            val compartment = inCompartment.trim()
            if (compartment.isEmpty()) {
                null
            } else {
                PsiphonStrategy(
                    name = "P",
                    label = PsiphonMethods.label("P"),
                    timeoutSeconds = PsiphonMethods.seconds("P"),
                    preferredProtocols = emptyList(),
                ) { config ->
                    config.put("InproxyEnabled", true)
                    config.put("InproxyAllowClient", true)
                    config.put("InproxyClientPersonalCompartmentID", compartment)
                    config.put("NetworkLatencyMultiplier", 3.0)
                }
            }
        }
        else -> null
    }

    /** Rung X: Psiphon reaching its servers THROUGH one
     *  upstream proxy (MLM's upstreamRung, ported). TCP
     *  protocols only — a proxy cannot carry the UDP ones. */
    private fun upstreamRung(up: UpstreamCandidate) = PsiphonStrategy(
        name = "X",
        label = PsiphonMethods.label("X") + " " + up.label,
        timeoutSeconds = PsiphonMethods.seconds("X"),
        preferredProtocols = PsiphonConstants.DIRECT_PROTOCOLS,
        dataRoot = File(workDir(this), "psiphon-upstream"),
        upstream = up,
    ) { config ->
        config.put("UpstreamProxyURL", up.url)
        config.put("LimitTunnelProtocols", JSONArray(PsiphonConstants.CHAINABLE_PROTOCOLS))
        config.put("ConnectionWorkerPoolSize", 16)
        config.put("InproxyEnabled", false)
        config.put("InproxyAllowClient", false)
    }

    /** The clean-IP CIDRs for rung E, by fronting provider
     *  (MLM's PsiphonCleanIps.configCidrs shape): the Dart
     *  side's tested edge addresses for Akamai and Fastly,
     *  as /32s. */
    private fun cleanCidrs(): Map<String, List<String>> {
        val out = LinkedHashMap<String, List<String>>()
        val akamai = inCleanAkamai.map { it.trim() }.filter { it.isNotEmpty() }
        val fastly = inCleanFastly.map { it.trim() }.filter { it.isNotEmpty() }
        if (akamai.isNotEmpty()) {
            out[PsiphonConstants.FRONTING_PROVIDER_AKAMAI] = akamai.map { "$it/32" }
        }
        if (fastly.isNotEmpty()) {
            out[PsiphonConstants.FRONTING_PROVIDER_FASTLY] = fastly.map { "$it/32" }
        }
        return out
    }

    /**
     * Take protocol selection back from Psiphon's remote
     * tactics (MLM's applyTacticsOverride, ported).
     *
     * The field log from Iran proved the rung's protocol list
     * was being ignored: rung A asked for the three
     * FRONTED-MEEK protocols, and Psiphon's own
     * CandidateServers notice reported
     * `initialLimitTunnelProtocols: [INPROXY-WEBRTC-*]`
     * instead, followed by 228 WebRTC dials that had no hope
     * on a network where UDP is dead. That is precedence, not
     * a bug in the config: Parameters.Set walks
     * [config, tactics] backwards, so the remotely delivered
     * tactics value wins over anything the app set — and
     * Psiphon's Iran tactics forced in-proxy, silently making
     * every rung the same rung.
     *
     * DisableTactics is the only lever that restores our own
     * ordering. It is applied per rung, from the configure
     * blocks of A, E and D only: rung C must NOT set it (the
     * broker specs in-proxy needs arrive via tactics), P
     * likewise, and X pins in-proxy off itself.
     */
    private fun applyTacticsOverride(config: JSONObject) {
        config.put("DisableTactics", true)
        // With tactics off there are no broker specs, so
        // in-proxy is dead weight here: it would still consume
        // worker slots on WebRTC/ICE that cannot complete.
        // Rung C is where the peer relay gets its turn, with
        // tactics on.
        config.put("InproxyEnabled", false)
        config.put("InproxyAllowClient", false)
        logLine("tactics disabled for this rung — using the app's own protocol order")
    }

    // ---- the config builder (MLM's, ported) ------------------

    /** The core's URL-list encoding: one {URL: base64,
     *  OnlyAfterAttempts, SkipVerify} object per location. */
    private fun psiphonUrlList(
        urls: List<Triple<String, Int, Boolean>>,
    ): JSONArray {
        val out = JSONArray()
        for ((url, onlyAfterAttempts, skipVerify) in urls) {
            out.put(
                JSONObject()
                    .put("URL", Base64.encodeToString(url.toByteArray(), Base64.NO_WRAP))
                    .put("OnlyAfterAttempts", onlyAfterAttempts)
                    .put("SkipVerify", skipVerify),
            )
        }
        return out
    }

    /**
     * The full config for the current attempt (MLM's
     * buildPsiphonConfig, ported): the base config with MLM's
     * identity set, the server-list locations, the anti-hijack
     * DNS trio — then the current rung's overrides, then the
     * region phase on top when it is running. Ember's roots:
     * the core's data lives in this engine's work dir (MLM
     * uses its filesDir; the shape is identical, the root is
     * Ember's per-engine directory). MLM's LAN-sharing keys
     * and its chain-over-WARP UpstreamProxyURL are not taken
     * (analysis §9.1/§9.3).
     */
    private fun buildPsiphonConfig(): String {
        val dir = workDir(this)
        // Build 2129 (Leg 2): the identity set for this start.
        // The Shiro bootstrap toggle (DEFAULT OFF) swaps the
        // WHOLE set — channel, sponsor, client version, both
        // URL lists, both signature keys, the exchange key —
        // plus the entries asset (loadEntries) as one unit;
        // halves are never mixed (the sets were diffed
        // field-by-field in build2129-leg-psiphon.md). Off,
        // every value below is the 2128 MLM set, unchanged.
        val shiro = inShiroBootstrap
        val propagationChannelId =
            if (shiro) PsiphonConstants.SHIRO_PROPAGATION_CHANNEL_ID
            else PsiphonConstants.PROPAGATION_CHANNEL_ID
        val sponsorId =
            if (shiro) PsiphonConstants.SHIRO_SPONSOR_ID
            else PsiphonConstants.SPONSOR_ID
        val clientVersion =
            if (shiro) PsiphonConstants.SHIRO_CLIENT_VERSION
            else PsiphonConstants.CLIENT_VERSION
        val remoteServerListUrls =
            if (shiro) PsiphonConstants.SHIRO_REMOTE_SERVER_LIST_URLS
            else PsiphonConstants.REMOTE_SERVER_LIST_URLS
        val obfuscatedServerListRootUrls =
            if (shiro) PsiphonConstants.SHIRO_OBFUSCATED_SERVER_LIST_ROOT_URLS
            else PsiphonConstants.OBFUSCATED_SERVER_LIST_ROOT_URLS
        val remoteServerListSignaturePublicKey =
            if (shiro) PsiphonConstants.SHIRO_REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY
            else PsiphonConstants.REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY
        val serverEntrySignaturePublicKey =
            if (shiro) PsiphonConstants.SHIRO_SERVER_ENTRY_SIGNATURE_PUBLIC_KEY
            else PsiphonConstants.SERVER_ENTRY_SIGNATURE_PUBLIC_KEY
        val exchangeObfuscationKey =
            if (shiro) PsiphonConstants.SHIRO_EXCHANGE_OBFUSCATION_KEY
            else PsiphonConstants.EXCHANGE_OBFUSCATION_KEY
        val config = JSONObject().apply {
            put("PropagationChannelId", propagationChannelId)
            put("SponsorId", sponsorId)
            put("EgressRegion", "")
            put("EstablishTunnelTimeoutSeconds", 120)
            put("DataDirectory", dir.absolutePath)
            put("ClientVersion", clientVersion)
            put("TunnelProtocol", "")
            // Fetch Psiphon's server list instead of living on
            // the bundled entries alone. Both download
            // locations are required by the core's own
            // validation when the URLs are set, and the OSL
            // directory has to exist before the fetcher writes.
            put("RemoteServerListURLs", psiphonUrlList(remoteServerListUrls))
            put(
                "RemoteServerListDownloadFilename",
                File(dir, "psiphon_remote_server_list").absolutePath,
            )
            put("ObfuscatedServerListRootURLs", psiphonUrlList(obfuscatedServerListRootUrls))
            put(
                "ObfuscatedServerListDownloadDirectory",
                File(dir, "psiphon_osl").apply { mkdirs() }.absolutePath,
            )
            put("LocalSocksProxyPort", PsiphonConstants.SOCKS_PORT)
            put("RemoteServerListSignaturePublicKey", remoteServerListSignaturePublicKey)
            put("ServerEntrySignaturePublicKey", serverEntrySignaturePublicKey)
            put("ExchangeObfuscationKey", exchangeObfuscationKey)
            // Required for onBytesTransferred() to ever fire:
            // the core suppresses the notice without it, and in
            // VPN mode these counters are the session's only
            // traffic source.
            put("EmitBytesTransferred", true)
            // Iran-specific tactics (protocol selection,
            // padding, server prioritisation) are downloaded
            // for this device region.
            put("DeviceRegion", "IR")
            put("ConnectionWorkerPoolSize", 12)
            // The core's own words are this engine's evidence:
            // diagnostics, the network parameters that say WHY
            // a dial worked, and server alerts all on.
            put("EmitDiagnosticNotices", true)
            put("EmitDiagnosticNetworkParameters", true)
            put("EmitServerAlerts", true)
            // The anti-hijack DNS trio (MLM's, with its field
            // evidence): PreferredAlternateServers (the plain
            // Alternate list is only consulted when the system
            // list is EMPTY, which Android's never is),
            // probability 1.0 (the default 0.0 means configured
            // and almost never used), 2 attempts per preferred
            // server (one lost UDP packet must not drop us back
            // to the hijacked resolver).
            put("DNSResolverPreferredAlternateServers", JSONArray(PsiphonConstants.DNS_PREFERRED_ALTERNATE_SERVERS))
            put("DNSResolverPreferAlternateServerProbability", 1.0)
            put("DNSResolverAttemptsPerPreferredServer", 2)
            // Build 2129 (Leg 2): the Shiro partner config's
            // shaping flags, Shiro mode only — with the toggle
            // off none of these keys exist in the config,
            // exactly as in 2128. (The Shiro set's plain
            // DNSResolverAlternateServers list is NOT taken:
            // the preferred-alternate trio above is Ember's
            // field-proven anti-hijack mechanism, and the
            // plain list is only consulted when the system
            // list is empty, which Android's never is.)
            if (shiro) {
                put("UseIndistinguishableTLS", PsiphonConstants.SHIRO_USE_INDISTINGUISHABLE_TLS)
                put("FrontedMeekCDNScanUseBuiltInSpec", PsiphonConstants.SHIRO_FRONTED_MEEK_CDN_SCAN_USE_BUILT_IN_SPEC)
                put("TunnelPoolSize", PsiphonConstants.SHIRO_TUNNEL_POOL_SIZE)
            }
            // Build 2129 (Leg 2): strong mode — LML's Shiro
            // "strong" option (AggressiveEstablishment). A
            // separate DEFAULT-OFF setting, honoured in both
            // bootstrap modes; the key is emitted only when
            // the owner enabled it, so the OFF config shape
            // is the 2128 shape. (Build 2069 withdrew the
            // always-on "Beast Mode" incarnation of this key
            // with the fork core; this is an owner-chosen,
            // default-off option on the stock core, and only
            // a device run can prove how the stock core
            // treats it — see build2129-leg-psiphon.md.)
            if (inStrongMode) {
                put("AggressiveEstablishment", true)
            }
            // Note (MLM's, verified against the binary): there
            // is no "DisableNetworkManager" key in the core —
            // its NetworkMonitor still restarts the tunnel when
            // tun0 appears. That is survivable here: the TUN is
            // raised BEFORE the core starts, tun2socks holds
            // the fd, and the SOCKS port is fixed.
        }

        // The current rung's overrides, and its own establish
        // budget, so a dead rung is abandoned quickly instead
        // of burning the full two minutes.
        val strategy = sessionLadder.getOrNull(ladderIndex)
        if (strategy != null) {
            strategy.configure(config)
            config.put("EstablishTunnelTimeoutSeconds", strategy.timeoutSeconds)
            strategy.dataRoot?.let { root ->
                root.mkdirs()
                config.put("DataRootDirectory", root.absolutePath)
            }
            logLine(
                "strategy ${ladderIndex + 1}/${sessionLadder.size} " +
                    "(${strategy.name}): ${strategy.label} — ${strategy.timeoutSeconds}s budget" +
                    (strategy.upstream?.let { " — through ${maskedProxy(it.url)}" } ?: "") +
                    (if (strategy.name == "E") " — clean IPs ${config.optJSONObject("DNSResolverPreresolvedIPAddressCIDRs")}" else ""),
            )
        }

        // The preferred-country attempt, in front of the ladder
        // and only once. Applied AFTER the rung so it owns the
        // establish timeout: the rung's budget is sized for
        // searching a hostile carrier, and spending it on a
        // country preference would make a wrong choice cost
        // more than the whole ladder. The rung's fronted limit
        // is KEPT when the country has a fronted server in the
        // bundled entries (six countries do) and dropped when
        // it does not — widening for a fronted country was
        // measured actively harmful (MLM's field note).
        if (regionPhase && inRegion.isNotEmpty()) {
            config.put("EgressRegion", inRegion)
            config.put("EstablishTunnelTimeoutSeconds", REGION_PHASE_TIMEOUT_SECONDS)
            val frontedHere = inRegion in frontedRegions()
            if (!frontedHere) {
                config.remove("InitialLimitTunnelProtocols")
                config.remove("InitialLimitTunnelProtocolsCandidateCount")
                config.remove("LimitTunnelProtocols")
            }
            logLine(
                "preferred country $inRegion, " +
                    (if (frontedHere) "fronted servers exist there — keeping the fronted limit"
                    else "no fronted server there — all protocols") +
                    " — ${REGION_PHASE_TIMEOUT_SECONDS}s before the ladder",
            )
        }

        // Build 2129 (Leg 2): the bootstrap in play, stated
        // once per attempt (set names only — never values).
        if (shiro) {
            logLine(
                "bootstrap: Shiro public set — its identity, its " +
                    "embedded entries and its fronting overrides",
            )
        }
        if (inStrongMode) {
            logLine("strong mode on: AggressiveEstablishment")
        }
        // Stated once per attempt so a support log proves the
        // resolver was in play (MLM's line, kept).
        logLine(
            "psiphon DNS: ${PsiphonConstants.DNS_PREFERRED_ALTERNATE_SERVERS.size} public resolvers on " +
                "non-standard ports preferred over the operator's",
        )
        return config.toString()
    }

    /** A proxy URL with any userinfo masked (MLM's masked()). */
    private fun maskedProxy(url: String): String {
        val at = url.indexOf('@')
        if (at < 0) return url
        val scheme = url.indexOf("://")
        if (scheme < 0 || scheme > at) return url
        return url.substring(0, scheme + 3) + "•••" + url.substring(at)
    }

    /** The fronted regions of the bundled entries, parsed
     *  lazily from the asset (MLM's frontedRegions): a region
     *  qualifies when one of its entries advertises a
     *  FRONTED-MEEK protocol. Entries are length-prefixed
     *  JSON (4 bytes, then the object), so the parse takes
     *  everything from the first '{' — and capabilities are
     *  a flat array of protocol NAME strings, with the region
     *  on the entry itself. Any parse failure reads as "no
     *  fronted regions" — the region phase then drops the
     *  protocol limits, the safe direction. */
    private fun frontedRegions(): Set<String> {
        frontedRegionsCache?.let {
            if (frontedRegionsCacheShiro == inShiroBootstrap) return it
        }
        val regions = HashSet<String>()
        try {
            val text = loadEntries()
            for (line in text.split('\n')) {
                val trimmed = line.trim()
                if (trimmed.length < 32) continue
                val decoded = try {
                    String(hexToBytes(trimmed), Charsets.UTF_8)
                } catch (e: Throwable) {
                    continue
                }
                val jsonText = decoded.substringAfter('{', "")
                if (jsonText.isEmpty()) continue
                val entry = try {
                    JSONObject("{$jsonText")
                } catch (e: Exception) {
                    continue
                }
                val caps = entry.optJSONArray("capabilities") ?: continue
                var fronted = false
                for (i in 0 until caps.length()) {
                    if (caps.optString(i).startsWith("FRONTED-MEEK")) {
                        fronted = true
                        break
                    }
                }
                if (fronted) {
                    val region = entry.optString("region")
                    if (region.isNotEmpty()) regions.add(region.uppercase())
                }
            }
        } catch (e: Throwable) {
            // The empty set is the safe read (see above).
        }
        frontedRegionsCache = regions
        frontedRegionsCacheShiro = inShiroBootstrap
        logLine("countries with a fronted server: ${regions.sorted().joinToString(",")}")
        return regions
    }

    private fun hexToBytes(hex: String): ByteArray {
        val out = ByteArray(hex.length / 2)
        var i = 0
        while (i + 1 < hex.length) {
            out[i / 2] = ((Character.digit(hex[i], 16) shl 4) +
                Character.digit(hex[i + 1], 16)).toByte()
            i += 2
        }
        return out
    }

    /** MLM's embedded server entries, from the bundled asset
     *  (its server_entries.txt — 493 hex lines), as the string
     *  the core's startTunneling consumes. Build 2129 (Leg 2):
     *  with the Shiro bootstrap toggle on, the Shiro set's
     *  list (server_list_shiro.dat — 2,434 hex lines) is read
     *  instead. The two assets are format-identical (host-
     *  proven: every line of both hex-decodes to the same
     *  prefix + a ServerEntry JSON), so the hand-off to the
     *  core is the same raw text feed either way — nothing
     *  is stripped or transformed. */
    private fun loadEntries(): String {
        val asset =
            if (inShiroBootstrap) PsiphonConstants.SHIRO_SERVER_ENTRIES_ASSET
            else PsiphonConstants.SERVER_ENTRIES_ASSET
        return try {
            assets.open(asset)
                .bufferedReader().readText().trim()
        } catch (e: Exception) {
            logLine("no server entries in assets: ${e.message}")
            ""
        }
    }

    /** Build 2129 (Leg 2): the Shiro fronting overrides that
     *  fit Ember's existing machinery, as preresolved CIDRs
     *  keyed by fronting provider — the same shape rung E
     *  feeds from the owner's scanned clean IPs. From the
     *  public shiro-fronting-default.json, ONLY the entries
     *  whose dial addresses are IP literals are taken (the
     *  Akamai edge-IP overrides), keyed under Ember's Akamai
     *  provider ID. The two hostname-dial Fastly-class
     *  entries cannot be expressed as CIDRs, and the specs'
     *  SNI / verify-name / ALPN / TLS-profile fields have no
     *  Ember config surface (they belong to the core's
     *  tactics-delivered fronting specs, which the A/E/D
     *  rungs deliberately disable) — both are recorded as
     *  not-taken in build2129-leg-psiphon.md rather than
     *  forced. Empty unless the Shiro bootstrap is on; any
     *  parse failure reads as empty (the rung then behaves
     *  as it did without the overrides). */
    private fun shiroPreresolvedCidrs(): Map<String, List<String>> {
        if (!inShiroBootstrap) return emptyMap()
        shiroCidrsCache?.let { return it }
        val out = LinkedHashMap<String, List<String>>()
        try {
            val text = assets.open(PsiphonConstants.SHIRO_FRONTING_ASSET)
                .bufferedReader().readText()
            val specs = JSONArray(text)
            val ips = ArrayList<String>()
            for (i in 0 until specs.length()) {
                val spec = specs.optJSONObject(i) ?: continue
                val dials = spec.optJSONArray("DialAddresses") ?: continue
                for (j in 0 until dials.length()) {
                    val addr = dials.optString(j).trim()
                    // IPv4 literals only, no ports — a
                    // hostname dial is not a CIDR. (Every
                    // IP-literal dial in the published spec
                    // set is v4.)
                    if (addr.matches(Regex("""\d{1,3}(\.\d{1,3}){3}"""))) {
                        ips.add("$addr/32")
                    }
                }
            }
            if (ips.isNotEmpty()) {
                out[PsiphonConstants.FRONTING_PROVIDER_AKAMAI] = ips
            }
        } catch (e: Throwable) {
            // Empty is the safe read (see above).
        }
        shiroCidrsCache = out
        if (out.isNotEmpty()) {
            logLine(
                "shiro fronting overrides: ${out.values.sumOf { it.size }} edge IPs " +
                    "mapped to preresolved CIDRs",
            )
        }
        return out
    }

    // ---- the core's start/stop (MLM's shapes) ----------------

    /**
     * Starts the core on the current rung (MLM's
     * startPsiphonTunnel, ported). The startReturned bracket
     * wraps the library call: it is the wedge frontier the
     * external watchdog reads (build 2087's instrumentation,
     * retargeted per §9.2 — the "start call" is now
     * startTunneling, whose preamble is where 2065–2088
     * wedged).
     */
    private fun startPsiphonTunnel() {
        try {
            // Clear evidence from any previous rung:
            // attribution must reflect this attempt only.
            activeTunnelProtocol = ""
            inproxyInUse = false
            psiphonRungStartedAt = System.currentTimeMillis()
            val tunnel = PsiphonTunnel.newPsiphonTunnel(this)
            // Always SOCKS mode — in VPN mode we bridge
            // TUN→SOCKS ourselves (MLM's rule, §2 item 1's
            // other half).
            tunnel.setVpnMode(false)
            psiphonTunnel = tunnel
            // The library pulls the config through
            // getPsiphonConfig() when the start lands.
            psiphonConfigJson = buildPsiphonConfig()
            val configJson = psiphonConfigJson
            val serverEntries = loadEntries()
            CrashLog.breadcrumb(
                this,
                "psiphon:entries-${serverEntries.length / 1024}kb-config-${configJson.length}",
            )
            // Fire-and-forget: Psiphon connects asynchronously;
            // onConnected() activates routing (VPN mode) and
            // runs the quality gate before anything is called
            // connected.
            startInFlight = true
            startReturned = false
            armHeartbeat()
            CrashLog.breadcrumb(this, "psiphon:startTunneling-entered")
            try {
                tunnel.startTunneling(serverEntries)
            } finally {
                startReturned = true
                startInFlight = false
            }
            CrashLog.breadcrumb(this, "psiphon:startTunneling-returned")
            val strategy = sessionLadder.getOrNull(ladderIndex)
            logLine(
                "psiphon tunnel starting" +
                    (strategy?.let { " — method ${ladderIndex + 1}/${sessionLadder.size}: ${it.label}, up to ${rungSeconds(it)}s" } ?: ""),
            )
            armLadderTimer()
        } catch (e: Throwable) {
            CrashLog.append(this, "PsiphonVpnService.startPsiphonTunnel", e)
            Log.e(TAG, "psiphon start failed", e)
            // Nothing is armed at this point — the exception
            // happened before armLadderTimer(), so no timer
            // and no onExiting() will ever fire. Without
            // stopping here the service sits on "connecting"
            // forever with a live TUN and no tunnel behind it
            // (MLM's note, kept).
            failAndStop("Psiphon could not start: ${e.message}")
        }
    }

    /** The seconds the current attempt may take: the region
     *  phase's short budget while it runs, else the rung's. */
    private fun rungSeconds(s: PsiphonStrategy): Int =
        if (regionPhase && inRegion.isNotEmpty()) REGION_PHASE_TIMEOUT_SECONDS
        else s.timeoutSeconds

    /** Arms the current rung's escalation timer: its budget
     *  plus a grace for the core's own timeout to fire first
     *  (MLM's armLadderTimer). The timer only POSTS the
     *  escalation to the worker — every ladder move runs on
     *  that one thread, MLM's runOnWorker serialization, so a
     *  timer, an onExiting and a quality redraw can never
     *  start two cores at once. */
    private fun armLadderTimer() {
        ladderTimer?.cancel(false)
        ladderActive.set(true)
        if (stopping.get() || !running) return
        val strategy = sessionLadder.getOrNull(ladderIndex) ?: return
        val seconds = rungSeconds(strategy) + LADDER_GRACE_SECONDS
        ladderTimer = ladderScheduler.schedule(
            {
                worker.execute {
                    escalateLadder("no tunnel in ${rungSeconds(strategy)}s (method budget + grace)")
                }
            },
            seconds.toLong(), TimeUnit.SECONDS,
        )
    }

    /**
     * Moves the session to the next rung, or ends it (MLM's
     * escalateLadder, ported). Runs on the worker. The
     * ladderActive CAS is the one-shot latch per attempt: a
     * timer and an onExiting racing the same dead rung
     * escalate ONCE, and startPsiphonTunnel re-arms it for
     * the next attempt. The TUN stays up across rungs — only
     * the controller is torn down and restarted.
     *
     * A failed region phase is not counted: the flag clears
     * and the same rung restarts unfiltered. Wrap-around —
     * every rung has had its turn — is the session's failure,
     * with MLM's sentence.
     */
    private fun escalateLadder(reason: String) {
        if (stopping.get() || !running) return
        if (!ladderActive.compareAndSet(true, false)) return
        ladderTimer?.cancel(false)
        if (regionPhase && inRegion.isNotEmpty()) {
            regionPhase = false
            logLine(
                "preferred country $inRegion did not connect ($reason) — " +
                    "continuing with all countries from method " +
                    (sessionLadder.getOrNull(ladderIndex)?.name ?: "?"),
            )
            restartCoreInline()
            return
        }
        val failed = sessionLadder.getOrNull(ladderIndex)
        ladderAttempts++
        if (ladderAttempts >= sessionLadder.size) {
            logLine("all ${sessionLadder.size} strategies exhausted — the carrier is blocking every available path")
            ladderIndex = 0
            ladderAttempts = 0
            regionPhase = false
            failAndStop("Could not connect on this carrier. Try Wi-Fi or another SIM.")
            return
        }
        ladderIndex = (ladderIndex + 1) % sessionLadder.size
        // A new rung draws its own servers: the slow-server
        // search starts over with it.
        psiphonQualityAttempts = 1
        val next = sessionLadder.getOrNull(ladderIndex)
        logLine(
            "strategy ${failed?.name ?: "?"} timed out ($reason) — escalating to " +
                "${next?.name}: ${next?.label}",
        )
        restartCoreInline()
    }

    /** Restarts the core on the (new) current rung: stop
     *  inline, a beat, start (MLM's restart shape, on the
     *  worker). The TUN stays up; the bridge, once started,
     *  stays up too — the SOCKS port is fixed, so a restart
     *  only breaks in-flight upstream sockets. */
    private fun restartCoreInline() {
        if (stopping.get() || !running) return
        val tunnel = psiphonTunnel
        psiphonTunnel = null
        if (tunnel != null) {
            try {
                tunnel.stop()
            } catch (e: Throwable) {
                // A stop failure is recorded, never fatal.
                Log.w(TAG, "psiphon core stop failed", e)
            }
        }
        try {
            Thread.sleep(RUNG_RESTART_PAUSE_MS)
        } catch (e: InterruptedException) {
            return
        }
        if (stopping.get() || !running) return
        startPsiphonTunnel()
    }

    /**
     * Stops the core for a teardown: the reference is
     * detached synchronously, the blocking stop() runs on a
     * dedicated thread (MLM's stopPsiphonTunnel shape —
     * stop() blocks until the Go controller unwinds, and the
     * user-stop path reaches here from the main thread, where
     * a synchronous stop froze MLM's UI in its field reports).
     */
    private fun stopPsiphonCore() {
        val tunnel = psiphonTunnel ?: return
        psiphonTunnel = null
        val t = Thread(
            {
                try {
                    tunnel.stop()
                } catch (e: Throwable) {
                    // A stop failure is recorded, never fatal.
                    Log.w(TAG, "psiphon core stop failed", e)
                }
            },
            "psiphon-stop",
        )
        t.isDaemon = true
        t.start()
    }

    /** Whether this session's unexpected death may be
     *  held as a blackhole (build 2125, A25-04 / S-4):
     *  TUN mode, the switch on, and a TUN actually up. */
    private fun canHoldKillSwitch(): Boolean =
        inVpnMode && inKillSwitch && tunPfd != null

    /**
     * Kill switch (build 2125, audit A25-04 / plan S-4 —
     * the hold that slipped in 2123): a LIVE session died
     * unexpectedly with the switch on. The core and the
     * bridge stop, but the TUN is NOT closed — the
     * interface stays up with nobody reading it, so the
     * kernel queues then drops packets: traffic BLOCKS
     * instead of going direct, until the user disconnects
     * (ACTION_STOP tears everything down as always) or a
     * fresh start replaces the held interface. Mirrors
     * XrayVpnService.holdBlackhole. The published state
     * says the session is down AND held: killSwitchHeld
     * is set before running flips, so no snapshot can
     * read "down and not held".
     */
    private fun holdKillSwitch(reason: String) {
        ladderActive.set(false)
        ladderTimer?.cancel(false)
        startInFlight = false
        logStartPhaseSync = false
        logLine(
            "psiphon failed: $reason — kill switch holding " +
                "the tunnel; traffic is blocked, not direct",
        )
        Tun2SocksManager.stop()
        bridgeStarted = false
        routingActivated = false
        stopPsiphonCore()
        stopTrackingUnderlyingNetwork()
        connected = false
        killSwitchHeld = true
        running = false
        updateNotification()
    }

    /** Ends the session with a reason (MLM's failAndStop,
     *  adapted to this service's state contract): the reason
     *  lands in the session log the error surface quotes, and
     *  the teardown is the ordinary stop. Never-established
     *  failures consult no kill switch — there is nothing to
     *  protect yet. Build 2125 (A25-04 / S-4): an ESTABLISHED
     *  session's failure (routing was activated) consults
     *  it — with the switch on, the TUN is held as a
     *  blackhole instead of being closed. */
    private fun failAndStop(reason: String) {
        if (routingActivated && canHoldKillSwitch()) {
            holdKillSwitch(reason)
            return
        }
        ladderActive.set(false)
        logLine("psiphon failed: $reason")
        stopTunnel()
    }

    // ---- the HostService (the core's view of this host) ------
    //
    // MLM's callback set, ported. The load-bearing one is
    // bindToDevice: EVERY socket the core opens — its tunnel
    // dials AND its DNS resolver sockets — arrives here, and
    // protect() is what keeps them off the TUN this service
    // raised (the core would otherwise dial through its own
    // tunnel and loop). It works with setVpnMode(false)
    // because the library calls it for every socket it makes
    // when a HostService is bound (analysis §2 item 1).

    override fun bindToDevice(fd: Long) {
        if (!protect(fd.toInt())) {
            throw PsiphonTunnel.Exception("bindToDevice: VpnService.protect() refused socket $fd")
        }
    }

    override fun getContext(): Context = this

    override fun onListeningSocksProxyPort(port: Int) {
        if (port != PsiphonConstants.SOCKS_PORT) {
            logLine("psiphon SOCKS listener on unexpected port $port (the chain dials ${PsiphonConstants.SOCKS_PORT})")
        }
    }

    override fun onListeningHttpProxyPort(port: Int) {
        // No HTTP listener is configured (MLM's LAN-sharing
        // keys are not taken); a notice here is evidence only.
        logLine("psiphon HTTP proxy listening on $port (not configured; noted)")
    }

    /**
     * The core has a tunnel (MLM's onConnected, ported).
     * Attribution is scheduled FIRST — the ActiveTunnel
     * notice that names the protocol arrives after this
     * callback, and the deferred attribution is the only
     * evidence-based version.
     *
     * Proxy mode: the SOCKS is the product — the session is
     * connected now (this IS the §9.4 contract change:
     * proxy-mode success is core-connected, not
     * process-running). VPN mode: tun2socks keeps running
     * across rotations, so a re-connect needs nothing; the
     * first connect runs the quality gate on the worker and
     * only then activates routing — a slow server never
     * becomes the device's route.
     */
    override fun onConnected() {
        logLine("psiphon tunnel connected")
        // The start attempt resolved.
        startInFlight = false
        // The start phase is over — the session log returns
        // to the buffered policy.
        logStartPhaseSync = false
        scheduleLadderAttribution()
        if (!inVpnMode) {
            logLine("psiphon SOCKS proxy ready at 127.0.0.1:${PsiphonConstants.SOCKS_PORT}")
            connected = true
            ladderActive.set(false)
            updateNotification()
            return
        }
        if (routingActivated && Tun2SocksManager.isRunning) {
            logLine("psiphon reconnected — tun2socks still routing, nothing to do")
            if (!connected) connected = true
            return
        }
        // Before anyone's traffic is routed through it: what
        // this server is worth. Not through an upstream rung
        // (there the proxy is the narrow part, so every server
        // measures the same and the search only repeats whole
        // connects).
        val rung = sessionLadder.getOrNull(ladderIndex)
        if (!psiphonQualityDone && rung != null && rung.upstream == null) {
            val gen = ++psiphonQualityGen
            val viaRegion = regionPhase
            worker.execute { psiphonQualityCheck(gen, viaRegion) }
            return
        }
        activateRouting()
    }

    /** Tun2Socks onto Psiphon's port: the device is routed,
     *  and only now is it CONNECTED (MLM's
     *  activatePsiphonRouting). */
    private fun activateRouting() {
        val pfd = tunPfd
        if (pfd == null) {
            failAndStop("VPN interface missing")
            return
        }
        if (!Tun2SocksManager.start(pfd, PsiphonConstants.SOCKS_PORT, mtu = inMtu)) {
            failAndStop("Could not start whole-device routing")
            return
        }
        bridgeStarted = true
        routingActivated = true
        ladderActive.set(false)
        connected = true
        logLine("whole-device routing active via tun2socks → 127.0.0.1:${PsiphonConstants.SOCKS_PORT}")
        updateNotification()
    }

    /**
     * The server-quality gate (MLM's psiphonQualityCheck,
     * ported): after onConnected, BEFORE anyone's traffic is
     * routed through it, the server that answered is measured
     * (PsiphonQuality). A slow one is rejected — the
     * controller stops, the core's replay state drops (the
     * same server would otherwise be redrawn at once), and
     * the same rung draws again, at most
     * [PsiphonQuality.MAX_SERVER_ATTEMPTS] draws. A
     * measurement that moved no byte at all is NOT "slow"
     * (that is the dead-path case — redialling would only
     * spend ten seconds proving it again; routing goes ahead
     * and the session's own loss handling judges).
     *
     * Runs on the worker: the measurement blocks ~12 s, and
     * the redraw's stop/sleep/start must serialize with the
     * ladder's other moves on that one thread.
     */
    private fun psiphonQualityCheck(gen: Int, viaRegion: Boolean) {
        if (stopping.get() || gen != psiphonQualityGen) return
        val rung = sessionLadder.getOrNull(ladderIndex)
        val result = PsiphonQuality.measure(PsiphonConstants.SOCKS_PORT)
        logLine(
            "psiphon capacity: ${result.mbit} Mbit/s with ${PsiphonQuality.STREAMS} streams " +
                "(${result.okStreams} brought bytes, ${result.bytes} bytes in ${result.ms} ms) — " +
                "server $psiphonQualityAttempts of ${PsiphonQuality.MAX_SERVER_ATTEMPTS}",
        )
        if (stopping.get() || gen != psiphonQualityGen) return
        val slow = result.okStreams > 0 && result.mbit < PsiphonQuality.MIN_GOOD_MBIT
        if (slow && psiphonQualityAttempts < PsiphonQuality.MAX_SERVER_ATTEMPTS) {
            psiphonQualityAttempts++
            logLine(
                "slow server (${result.mbit} Mbit/s) — drawing another, " +
                    "$psiphonQualityAttempts of ${PsiphonQuality.MAX_SERVER_ATTEMPTS}",
            )
            // ORDER IS EVERYTHING HERE: the controller stops
            // (and lets go of its datastore) before the
            // datastore is removed, and the next dial starts
            // on a fresh one.
            val tunnel = psiphonTunnel
            psiphonTunnel = null
            if (tunnel != null) {
                try {
                    tunnel.stop()
                } catch (e: Throwable) {
                    Log.w(TAG, "psiphon core stop failed", e)
                }
            }
            try {
                Thread.sleep(RUNG_RESTART_PAUSE_MS)
            } catch (e: InterruptedException) {
                return
            }
            if (stopping.get() || gen != psiphonQualityGen) return
            dropReplayState(rung?.dataRoot)
            // The same country again when that is where the
            // first server came from.
            if (viaRegion && inRegion.isNotEmpty()) regionPhase = true
            startPsiphonTunnel()
            return
        }
        if (slow) {
            logLine(
                "after $psiphonQualityAttempts servers the best this line gave was " +
                    "${result.mbit} Mbit/s — keeping it",
            )
        }
        psiphonQualityDone = true
        activateRouting()
    }

    /**
     * Drops the tunnel-core datastore under a data root, so
     * a redraw does not replay the same server at once (MLM's
     * dropReplayState, ported; the downloaded server list
     * lives OUTSIDE the datastore and survives, exactly as
     * there). Roots are this engine's: the rung's own root
     * when it has one, else the work dir the base config's
     * DataDirectory names.
     */
    private fun dropReplayState(dataRoot: File?) {
        val root = dataRoot ?: workDir(this)
        val candidates = listOf(
            File(root, "ca.psiphon.PsiphonTunnel.tunnel-core/datastore"),
            File(root, "datastore"),
        )
        for (candidate in candidates) {
            try {
                if (candidate.exists()) {
                    candidate.deleteRecursively()
                    logLine("dropped the core's replay state (${candidate.path})")
                    return
                }
            } catch (e: Exception) {
                logLine("could not drop the replay state: ${e.message}")
            }
        }
    }

    // ---- winner attribution (MLM's, ported) ------------------

    /**
     * Names the rung that carried the tunnel, 2 s after
     * connect — deferred because the core's ActiveTunnel
     * notice lands AFTER the onConnected callback, and
     * crediting the rung before it arrives would name
     * whatever the previous attempt left behind (MLM's
     * scheduleLadderAttribution).
     */
    private fun scheduleLadderAttribution() {
        if (!attributionPending.compareAndSet(false, true)) return
        ladderScheduler.schedule(
            {
                attributionPending.set(false)
                if (stopping.get() || !connected) return@schedule
                recordLadderWinner(resolveWinner())
            },
            2, TimeUnit.SECONDS,
        )
    }

    /** MLM's precedence, in order: an upstream rung is
     *  remembered as X (the PROXY is the win, not the rung);
     *  an INPROXY protocol is rung C whatever the ladder
     *  thought; a protocol exactly one rung prefers names
     *  that rung; a protocol the active rung prefers names
     *  it; any rung's preference; the broker evidence (a
     *  fallback only); the active rung. */
    private fun resolveWinner(): String {
        val active = sessionLadder.getOrNull(ladderIndex) ?: return ""
        if (active.upstream != null) return "X"
        val protocol = activeTunnelProtocol
        if (protocol.startsWith("INPROXY")) return "C"
        if (protocol.isNotEmpty()) {
            val matches = sessionLadder.filter { it.preferredProtocols.contains(protocol) }
            if (matches.size == 1) return matches[0].name
            if (active.preferredProtocols.contains(protocol)) return active.name
            if (matches.isNotEmpty()) return matches[0].name
        }
        if (inproxyInUse) return "C"
        return active.name
    }

    /** Persists the winner by name for this mode and
     *  publishes it as the session's method (the Dart side
     *  reads it for display; ordering is the service's). */
    private fun recordLadderWinner(name: String) {
        if (name.isEmpty()) return
        PsiphonMethods.remember(this, sessionHasUpstream, name)
        activeMethod = name
        logLine("ladder winner: method $name (${PsiphonMethods.label(name)})")
    }

    /**
     * The core exited (MLM's onExiting, ported). Psiphon hit
     * its own establish timeout and shut the controller down
     * — the definitive "this rung is dead" signal, arriving
     * before the timer's grace expires, so escalate now
     * instead of leaving a stalled spinner.
     *
     * Guarded, exactly as in MLM: a user-initiated stop also
     * lands here, and so does a teardown that follows a
     * successful connection. Escalation runs only while an
     * attempt is in flight (ladderActive) and routing was
     * never activated; the exit of an established session is
     * the silent death the field report describes — tun2socks
     * would otherwise keep routing into nothing while the
     * app claims to be connected — so it ends the session
     * here, not on a watchdog tick.
     *
     * (There is no onTunnelLost callback in this AAR; this
     * is the only loss signal. The bridge watcher covers
     * the bridge's own death separately.)
     */
    override fun onExiting() {
        if (stopping.get() || !running) return
        if (!routingActivated && ladderActive.get()) {
            worker.execute {
                escalateLadder("the core gave up on this method")
            }
            return
        }
        if (routingActivated && connected) {
            logLine("psiphon tunnel stopped after an established session")
            stopTunnel()
        }
    }

    override fun onAvailableEgressRegions(regions: List<String>) {
        availableRegions = regions
    }

    override fun onConnecting() {
        logLine("psiphon connecting")
    }

    /** The exit IP of the established tunnel (the published
     *  clientAddress; the AAR-era service set it the same
     *  way). */
    override fun onClientAddress(address: String) {
        if (address.isNotBlank()) {
            clientAddress = address
            logLine("psiphon exit IP: $address")
        }
    }

    override fun onClientRegion(region: String) {
        if (region.isNotBlank()) {
            logLine("psiphon client region: $region")
        }
    }

    /** Which country the established tunnel actually exits
     *  in — earlier and more reliable than any geolocation
     *  lookup, and the display value from here on. */
    override fun onConnectedServerRegion(region: String) {
        if (region.isNotBlank()) {
            egressRegion = region.uppercase()
        }
    }

    override fun onUpstreamProxyError(message: String) {
        logLine("psiphon upstream proxy error: $message")
    }

    /** The core's byte deltas (EmitBytesTransferred makes
     *  this fire at all): the session's traffic counters, in
     *  both modes — the notice only fires for actual tunnel
     *  traffic either way. */
    override fun onBytesTransferred(sent: Long, received: Long) {
        totalUp += sent
        totalDown += received
    }

    override fun onHomepage(url: String) {
        logLine("psiphon homepage: $url")
    }

    /**
     * The core's diagnostic notices (MLM's
     * onDiagnosticMessage, ported): this session's evidence
     * and the attribution inputs. The notices arrive as
     * prefixed strings — "ActiveTunnel: {protocol…}" and
     * "ConnectedServer: {candidateNumber, region,
     * meekResolvedIPAddress…}" — NOT as {noticeType…}
     * envelopes; parsing them as envelopes silently drops
     * every attribution input. ActiveTunnel names the
     * protocol that connected; ConnectedServer names the
     * candidate (and, on rung E, the clean address it came
     * up on — noted in the log; the Dart side's edge store
     * owns persistence); "administratively prohibited" lines
     * are counted as server-policy refusals, one log line per
     * ten; "inproxy: selected broker" is the broker evidence
     * (attribution's fallback signal only). Everything is
     * logged (the session log's dedupe keeps floods to
     * summaries).
     */
    override fun onDiagnosticMessage(message: String) {
        logLine(message)
        // Capture the protocol that actually carried the
        // tunnel. InitialLimitTunnelProtocols is a preference,
        // not a constraint: once the candidate budget is spent
        // Psiphon reverts to its full protocol set, so
        // attributing the win to the active rung was wrong in
        // both of MLM's field logs, and persisting the wrong
        // rung meant the next connect started from a strategy
        // that had not actually worked.
        if (message.startsWith("ActiveTunnel:")) {
            runCatching {
                val protocol = JSONObject(message.substringAfter("ActiveTunnel:").trim())
                    .optString("protocol")
                if (protocol.isNotBlank()) {
                    activeTunnelProtocol = protocol
                }
            }
        }
        // WHICH server, how far down the candidate list, and
        // — on rung E — which clean address carried it: proven
        // by a real tunnel, so that address goes to the top of
        // the list.
        if (message.startsWith("ConnectedServer:")) {
            runCatching {
                val d = JSONObject(message.substringAfter("ConnectedServer:").trim())
                val candidate = if (d.has("candidateNumber")) d.optInt("candidateNumber") else -1
                val region = d.optString("region")
                logLine(
                    "connected server: candidate $candidate" +
                        (if (region.isNotEmpty()) ", region $region" else ""),
                )
                if (sessionLadder.getOrNull(ladderIndex)?.name == "E") {
                    d.optString("meekResolvedIPAddress").replace("\\", "").trim()
                        .takeIf { it.isNotBlank() }?.let { ip ->
                            val ms = (System.currentTimeMillis() - psiphonRungStartedAt)
                                .takeIf { psiphonRungStartedAt > 0 }
                            logLine(
                                "clean IP $ip carried the tunnel" +
                                    (ms?.let { " in ${it}ms" } ?: ""),
                            )
                        }
                }
            }
        }
        // THE SERVER REFUSING A DESTINATION, which is
        // otherwise invisible: `administratively prohibited`
        // is the Psiphon server declining to open a channel —
        // its own policy, not filtering — and to the user a
        // site that simply does not open while everything
        // else does. Counted, not logged per event: a retried
        // destination makes a line per attempt.
        if (message.contains("administratively prohibited", ignoreCase = true)) {
            policyRefusals++
            val n = policyRefusals
            if (n == 1 || n % 10 == 0) {
                logLine(
                    "the Psiphon server refused a destination ($n so far) — its own policy, " +
                        "not filtering; some sites will not open through this server",
                )
            }
        }
        // An in-proxy broker selection is decisive evidence
        // the peer-relay path is in play, regardless of which
        // OSSH variant rides on top of it.
        if (message.contains("inproxy: selected broker")) {
            inproxyInUse = true
        }
    }

    /** The library pulls the config through this host method
     *  at every start (the gomobile contract). */
    override fun getPsiphonConfig(): String = psiphonConfigJson

    // ---- the bridge watcher + the underlying network ----------

    /** Ends the session when the bridge dies on its own
     *  (the native thread exited while the session stands):
     *  a TUN with no bridge behind it is a blackhole. The
     *  ladder's restarts never stop the bridge, so its death
     *  is never a rotation artefact.
     *
     *  Build 2124: the loop runs on its OWN daemon thread,
     *  never on the worker. The worker is the ladder's one
     *  serialization thread — the quality gate, escalations
     *  and redraws all queue there — and this loop lives
     *  for the whole session: queued on the worker (the
     *  pre-2124 shape) it occupied that thread forever, so
     *  when the core connected, the quality check queued
     *  behind it never ran, routing never activated and
     *  the app never registered the tunnel (device evidence
     *  2026-11-20 15:37: the library connected in ~6 s, the
     *  app still showed no tunnel at +60 s and the TUN
     *  blackholed all traffic). The watcher is not a ladder
     *  move — it only reads bridge state and calls
     *  stopTunnel(), which is already entered from many
     *  threads — so a dedicated thread loses no
     *  serialization the design relies on. */
    private fun watchBridge() {
        // Build 2124: dedicated thread — see the note above.
        val watcher = Thread(
            {
                while (!stopping.get() && running) {
                    if (bridgeStarted && !Tun2SocksManager.isRunning &&
                        !Tun2SocksManager.isNativeAlive
                    ) {
                        // Build 2125 (A25-04 / S-4): with
                        // the kill switch on, the bridge's
                        // death holds the TUN as a blackhole
                        // instead of tearing the session
                        // down to direct traffic.
                        if (canHoldKillSwitch()) {
                            holdKillSwitch("the routing bridge exited")
                        } else {
                            Log.e(TAG, "psiphon bridge exited; tearing the session down")
                            logLine("psiphon bridge exited; tearing the session down")
                            stopTunnel()
                        }
                        break
                    }
                    try {
                        Thread.sleep(5000)
                    } catch (e: InterruptedException) {
                        break
                    }
                }
            },
            "psiphon-bridge-watch",
        )
        watcher.isDaemon = true
        watcher.start()
    }

    /** Hands the service the device's real networks as they
     *  come and go (MLM's trackUnderlyingNetwork, ported):
     *  the core's dials follow the underlying network instead
     *  of guessing, and the session is marked unmetered. */
    private fun trackUnderlyingNetwork() {
        if (underlyingCallback != null) return
        val manager = getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                setUnderlyingNetworks(arrayOf(network))
            }

            override fun onLost(network: Network) {
                // null means "work it out yourself" rather
                // than "there is none" — the right answer
                // while a handover is in flight.
                setUnderlyingNetworks(null)
            }
        }
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        runCatching { manager.registerNetworkCallback(request, callback) }
            .onSuccess { underlyingCallback = callback }
            .onFailure { logLine("could not track the underlying network: ${it.message}") }
    }

    private fun stopTrackingUnderlyingNetwork() {
        val callback = underlyingCallback ?: return
        underlyingCallback = null
        val manager = getSystemService(ConnectivityManager::class.java) ?: return
        runCatching { manager.unregisterNetworkCallback(callback) }
    }

    // ---- the stop ----------------------------------------------

    private fun stopTunnel() {
        stopping.set(true)
        // Build 2087: the start attempt is over.
        startInFlight = false
        // Build 2069: the start phase ends in a stop.
        logStartPhaseSync = false
        // Build 2125 (A25-04 / S-4): a manual stop releases
        // a kill-switch hold — stopProcesses below closes
        // the held TUN with the rest.
        killSwitchHeld = false
        ladderActive.set(false)
        ladderTimer?.cancel(false)
        // Build 2087 (F3): publish the stop BEFORE stopping
        // the core — the state file must already say the
        // session is over when the teardown lands.
        running = false
        connected = false
        stopProcesses()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    @Synchronized
    private fun stopProcesses() {
        synchronized(logLock) { closeLogLocked() }
        // The bridge first, so no new flows start while the
        // core goes (build 2054, audit F-M1: the shared kill
        // contract).
        Tun2SocksManager.stop()
        bridgeStarted = false
        stopPsiphonCore()
        stopTrackingUnderlyingNetwork()
        try {
            tunPfd?.close()
        } catch (e: Exception) {
            // Already closed.
        }
        tunPfd = null
    }

    /** Which apps use the VPN: the same stored choice as the
     *  other engines — with this package disallowed in EVERY
     *  mode (MLM's §2 item 3): in INCLUDE mode it is simply
     *  never in the allowed set; every other shape names it
     *  disallowed explicitly. The core's own sockets leave
     *  over the carrier link because of this (and protect()). */
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
            // set resolved to nothing installed; the
            // fall-through to all-apps below is journaled,
            // never silent.
            CrashLog.breadcrumb(
                this,
                "psiphon:per-app Only set empty — all apps use the tunnel",
            )
        }
        builder.addDisallowedApplication(packageName)
        each(CoreService.appSet(this, CoreService.BYPASS) - packageName) {
            builder.addDisallowedApplication(it)
        }
    }

    // ---- the core's log ------------------------------------------------

    private fun openLog(dir: File) {
        synchronized(logLock) {
            try {
                val f = File(dir, "psiphon.log")
                // Build 2067 (log hygiene): rotate at EVERY
                // session start, not only past 512 KB. The
                // previous session stays on disk as
                // psiphon.log.old; the live file now holds
                // exactly one session.
                val old = File(dir, "psiphon.log.old")
                if (f.exists()) {
                    if (old.exists()) old.delete()
                    f.renameTo(old)
                }
                // Build 2055 (audit B-M4): one buffered
                // writer for the session, flushed on a 2 s
                // timer or 8 KB.
                closeLogLocked()
                logWriter = FileOutputStream(f, true).bufferedWriter()
                logBytesSinceFlush = 0
                logBytesTotal = 0
                logRotatedInSession = false
                logLastFlushMs = System.currentTimeMillis()
                lastLogLine = null
                logRepeatCount = 0
                logWriter?.write("\n==== psiphon session ${System.currentTimeMillis()} ====\n")
                // Build 2069: the start phase begins here,
                // and the header hits disk NOW.
                // writeLogRawLocked keeps flushing per line
                // while logStartPhaseSync holds; the quality
                // gate's pass, fail and stopTunnel clear it
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
        // Build 2068 breadcrumb: the session log is open —
        // the last of the start trail's steps (step 10).
        CrashLog.breadcrumb(this, "psiphon:openLog-completed")
    }

    private fun logLine(line: String) {
        synchronized(logLock) {
            // Build 2066: consecutive duplicates collapse
            // into one summary line ("(the previous line
            // repeated N times)") instead of one file line
            // each. Every 100 repeats an interim summary is
            // written, so a still-flooding session stays
            // visibly alive in the log instead of going
            // silent.
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

    /** Writes a pending repeat summary, if any. Callers
     *  hold [logLock]. */
    private fun flushLogRepeatLocked() {
        if (logRepeatCount > 0 && lastLogLine != null) {
            writeLogRawLocked("(the previous line repeated $logRepeatCount times)")
            logRepeatCount = 0
        }
    }

    /** One raw line into the session log. Callers hold
     *  [logLock]. */
    private fun writeLogRawLocked(line: String) {
        try {
            val w = logWriter
            if (w == null) {
                // The log was never opened (a line before
                // start): the old one-shot write, not a
                // crash.
                File(workDir(this), "psiphon.log").appendText(line + "\n")
                return
            }
            w.write(line)
            w.newLine()
            logBytesSinceFlush += line.length + 1
            logBytesTotal += line.length + 1
            // Build 2095 (audit 6-2): one mid-session
            // rotation past 1 MB — the tail (the part
            // diagnostics reads) is what matters, and the
            // file restarts empty rather than growing for
            // the whole session.
            if (!logRotatedInSession && logBytesTotal > 1024 * 1024) {
                logRotatedInSession = true
                try {
                    w.flush()
                    w.close()
                    val f = File(workDir(this), "psiphon.log")
                    f.delete()
                    logWriter = FileOutputStream(f, true).bufferedWriter()
                    logBytesTotal = 0
                    logBytesSinceFlush = 0
                } catch (_: Exception) {
                    // Logging must never break the session.
                }
            }
            val now = System.currentTimeMillis()
            // Build 2069: during the start phase
            // (logStartPhaseSync) every line flushes. After
            // the start phase the 2055 policy (8 KB / 2 s)
            // applies unchanged.
            if (logStartPhaseSync || logBytesSinceFlush >= 8192 || now - logLastFlushMs >= 2000) {
                w.flush()
                logBytesSinceFlush = 0
                logLastFlushMs = now
            }
        } catch (e: Exception) {
            // As above.
        }
    }

    /** Flushes and closes the session log writer, if
     *  open. */
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
            // Build 2125 (A25-04 / S-4): the held state
            // names itself on the notification.
            killSwitchHeld ->
                "Psiphon · kill switch holding — traffic is blocked"
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
        // Build 2057 (audit F-M4): capture IPv6 in the TUN
        // only when true (XraySettings.ipv6Route). Build
        // 2091: the Psiphon TUN is IPv4-only (MLM's bridge),
        // so this flag is carried, not applied — see
        // onStartCommand.
        private const val EXTRA_IPV6 = "ipv6"

        // Build 2065: the strategy ladder inputs. Build
        // 2091: read again — the MLM host owns the ladder
        // (see onStartCommand).
        private const val EXTRA_RUNGS = "rungs"
        private const val EXTRA_COMPARTMENT = "compartment"
        private const val EXTRA_CLEAN_AKAMAI = "cleanAkamai"
        private const val EXTRA_CLEAN_FASTLY = "cleanFastly"
        private const val EXTRA_DISABLE_TIMEOUTS = "disableTimeouts"
        private const val EXTRA_CDN_FRONT = "cdnFront"
        // Build 2125 (A25-04 / S-4): the kill switch.
        private const val EXTRA_KILL_SWITCH = "killSwitch"
        // Build 2129 (Leg 2): the Shiro bootstrap + strong
        // mode toggles (both DEFAULT OFF).
        private const val EXTRA_SHIRO_BOOTSTRAP = "shiroBootstrap"
        private const val EXTRA_STRONG_MODE = "strongMode"

        /** Build 2091: the provider this build runs —
         *  the MLM AAR (its identity), for breadcrumbs. */
        const val PROVIDER_ID =
            "psiphontunnel-2.0.39-ns (MLM AAR 426c0fda) + MLM host"
        private const val PROVIDER_TAG = "provider-aar-mlm"

        /** MLM's region-phase budget: the preferred country
         *  gets one 25 s attempt in front of the ladder. */
        private const val REGION_PHASE_TIMEOUT_SECONDS = 25

        /** The ladder timer's grace past a rung's budget —
         *  the core's own timeout fires first (MLM's +8 s). */
        private const val LADDER_GRACE_SECONDS = 8

        /** The beat between a core stop and the next start
         *  (MLM's 1200 ms). */
        private const val RUNG_RESTART_PAUSE_MS = 1200L

        private const val CHANNEL = "psiphon_status"
        private const val NOTIFICATION_ID = 3
        private const val TAG = "PsiphonVpnService"
        private const val MTU = 1500

        /** Build 2123 (S-3): the IPv6 blackhole address —
         *  a unique-local address used only to take the
         *  ::/0 route so v6 dies inside the TUN instead of
         *  bypassing the session (MLM's IPV6_BLACKHOLE,
         *  verbatim). */
        private const val IPV6_BLACKHOLE = "fd00:6e64:6f63::1"

        // Build 2087 (hang diagnosis F1): the heartbeat's
        // period while a start is in flight.
        private const val HEARTBEAT_MS = 2000L

        /** Clamps a tunnel MTU to the offered range (build
         *  2038, queue 2f): 1280 is the IPv6 minimum MTU
         *  (the floor), 1500 the default ceiling. */
        private fun clampMtu(mtu: Int) = mtu.coerceIn(1280, 1500)

        // Build 2073: the published state file. The service
        // runs in its own process (:psiphon — see the
        // manifest), so the main process cannot read the
        // companion statics below: they live in the
        // service's process only. Every mutation of a state
        // field republishes a JSON snapshot of all fields
        // to workDir/psiphon_state.json (atomic write), and
        // the main process — MainActivity's psiphonState
        // channel and XrayVpnService's chain checks — reads
        // that file through publishedState() /
        // publishedRunning() / publishedConnected().
        // Publishing is best-effort and can never break a
        // state change.
        private const val STATE_FILE = "psiphon_state.json"

        /** Build 2116 (B10-1): how often a running session
         *  republishes its snapshot unchanged, so the
         *  snapshot's age means "the process is gone", never
         *  "the tunnel was idle". */
        private const val REPUBLISH_MS = 30_000L

        /** Build 2116 (B10-1): a live-claiming snapshot older
         *  than this reads as stopped — four missed
         *  republications, so one slow cycle can never
         *  demote a live session. */
        internal const val STALE_SNAPSHOT_MS = 120_000L

        /** Serializes snapshot writes. */
        private val statePublishLock = Any()

        // Build 2116 (B10-1): the republication loop. Armed
        // by every publish while running; each firing
        // republishes (which re-arms nothing — the loop
        // reposts itself) and the loop stops itself at the
        // first firing that finds the session over. The
        // Handler lives in the service's process, so a dead
        // process takes the loop with it — which is exactly
        // what makes the snapshot go stale.
        private val republishHandler = Handler(Looper.getMainLooper())

        @Volatile
        private var republishArmed = false

        private val republishRunnable = object : Runnable {
            override fun run() {
                if (!running) {
                    republishArmed = false
                    return
                }
                publishState()
                republishHandler.postDelayed(this, REPUBLISH_MS)
            }
        }

        private fun armRepublish() {
            if (republishArmed) return
            republishArmed = true
            republishHandler.postDelayed(republishRunnable, REPUBLISH_MS)
        }

        /** The application context of the service's
         *  process, captured in onCreate before any state
         *  can change; publishing is skipped until it
         *  exists. */
        @Volatile
        private var appContext: Context? = null

        /** Called by the service's onCreate: gives the
         *  setters below the context they publish
         *  through. */
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

        /** Build 2125 (audit A25-04 / plan S-4): the
         *  kill-switch hold is in place — the session died
         *  unexpectedly and its TUN is being held as a
         *  blackhole (traffic blocked, never direct) until
         *  the user disconnects or a fresh start replaces
         *  it. Published so the app can say so. */
        @Volatile
        var killSwitchHeld = false
            internal set(value) {
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

        // Build 2091: the traffic counters live again — the
        // AAR core reports byte deltas through
        // onBytesTransferred (EmitBytesTransferred is on in
        // the config). The sidecar era (2089/2090) froze
        // them at 0; that freeze is over.
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

        // Build 2091: live again — the core reports its
        // available egress regions through the callback the
        // sidecar never had.
        @Volatile
        var availableRegions: List<String> = emptyList()
            private set(value) {
                field = value
                publishState()
            }

        /** Build 2065: the ladder rung that connected.
         *  Build 2091: live again — the service's
         *  attribution names it 2 s after connect. */
        @Volatile
        var activeMethod: String = ""
            internal set(value) {
                field = value
                publishState()
            }

        /** Build 2087 (F1): the last start wedged and its
         *  process was ended over it. Published so the
         *  main process can end the connect attempt with a
         *  plain failure instead of waiting out a dead
         *  session; cleared when a new start begins. */
        @Volatile
        var wedged: Boolean = false
            internal set(value) {
                field = value
                publishState()
            }

        /** Build 2088: whether the current start call has
         *  RETURNED from the provider. Build 2091: the
         *  "start call" is the core's startTunneling (see
         *  startPsiphonTunnel) — a healthy call returns in
         *  well under a second and the ladder then works
         *  through budgets that legitimately run for
         *  minutes, so a returned start NEVER arms the
         *  external watchdog, however slow the connect.
         *  Starts true: no start is outstanding in a fresh
         *  process. */
        @Volatile
        var startReturned: Boolean = true
            private set(value) {
                field = value
                publishState()
            }

        /**
         * Build 2073: snapshots all state fields to the
         * published state file. Runs on every state
         * mutation (see the setters above); cheap by
         * construction — one small JSON document, one
         * atomic rename — and fully guarded: state
         * publishing is evidence plumbing, never
         * behaviour, so a failure here must not reach the
         * caller that changed the state.
         */
        private fun publishState() {
            try {
                val context = appContext ?: return
                synchronized(statePublishLock) {
                    val json = JSONObject()
                        .put("running", running)
                        .put("connected", connected)
                        .put("killSwitchHeld", killSwitchHeld)
                        .put("vpnMode", isVpnMode)
                        .put("sinceMs", startedAtMs)
                        .put("up", totalUp)
                        .put("down", totalDown)
                        .put("region", egressRegion)
                        .put("clientAddress", clientAddress)
                        .put("regions", JSONArray(availableRegions))
                        .put("method", activeMethod)
                        .put("wedged", wedged)
                        .put("startReturned", startReturned)
                        .put("publishedAtMs", System.currentTimeMillis())
                    AtomicFile.writeText(File(workDir(context), STATE_FILE), json.toString())
                }
                // Build 2116 (B10-1): keep the snapshot's
                // freshness honest for as long as the
                // session runs.
                if (running) armRepublish()
            } catch (_: Throwable) {
                // Best-effort: the previous snapshot stays
                // in place (AtomicFile never tears), which
                // is the state a reader would have seen a
                // moment ago.
            }
        }

        /**
         * Build 2073: the main process's view of the state
         * above — the published snapshot, in exactly the
         * map shape MainActivity's psiphonState channel
         * has always returned. A missing or unreadable
         * file reads as the stopped defaults.
         */
        fun publishedState(context: Context): Map<String, Any?> {
            val file = File(workDir(context), STATE_FILE)
            if (!file.isFile) return parsePublishedState(null)
            return try {
                parsePublishedState(file.readText())
            } catch (_: Throwable) {
                parsePublishedState(null)
            }
        }

        /**
         * Build 2116 (B10-1): deletes the state file when
         * its RAW contents claim a live session older than
         * the staleness bound. The caller (MainActivity at
         * process start) has already established that the
         * :psiphon process is not alive. The raw read is
         * deliberate: publishedState() demotes a stale
         * snapshot to stopped, which would hide the very
         * claim this clear exists to remove. Best-effort;
         * returns whether a file was deleted.
         */
        fun clearStalePublishedState(context: Context): Boolean {
            return try {
                val file = File(workDir(context), STATE_FILE)
                if (!file.isFile) return false
                val json = JSONObject(file.readText())
                val claimsLive = json.optBoolean("running", false) ||
                    json.optBoolean("connected", false)
                val publishedAtMs = json.optLong("publishedAtMs", 0L)
                if (claimsLive &&
                    System.currentTimeMillis() - publishedAtMs >
                    STALE_SNAPSHOT_MS
                ) {
                    file.delete()
                } else {
                    false
                }
            } catch (_: Throwable) {
                false
            }
        }

        /**
         * Build 2087: the snapshot parse, separated from
         * the file read so the kill-tolerance contract has
         * a name: a truncated or torn snapshot must still
         * read as a sane status — the stopped defaults —
         * never as garbage or an exception.
         */
        internal fun parsePublishedState(
            text: String?,
            nowMs: Long = System.currentTimeMillis(),
        ): Map<String, Any?> {
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
                "wedged" to false,
                // Build 2088: no start outstanding reads as
                // returned, so a pre-2088 snapshot can never
                // arm the external watchdog by itself.
                "startReturned" to true,
                // Build 2125 (A25-04 / S-4).
                "killSwitchHeld" to false,
                "publishedAtMs" to 0L,
            )
            if (text == null) return defaults
            return try {
                val json = JSONObject(text)
                val publishedAtMs = json.optLong("publishedAtMs", 0L)
                val parsed = mapOf<String, Any?>(
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
                    "wedged" to json.optBoolean("wedged", false),
                    "startReturned" to json.optBoolean("startReturned", true),
                    // Build 2125 (A25-04 / S-4): the
                    // kill-switch hold flag.
                    "killSwitchHeld" to json.optBoolean("killSwitchHeld", false),
                    // Build 2116 (B10-1): the timestamp is
                    // carried through at last — it was written
                    // since 2073 and never read, so a dead
                    // :psiphon process's final snapshot read
                    // as Connected forever.
                    "publishedAtMs" to publishedAtMs,
                )
                // Build 2116 (B10-1): a snapshot that claims a
                // live session but has not been refreshed
                // within STALE_SNAPSHOT_MS is a dead process's
                // leavings, not a session — it reads as the
                // stopped defaults (its age stays visible in
                // publishedAtMs). The publisher republishes
                // every REPUBLISH_MS while running (see
                // armRepublish), so a live process — however
                // idle its traffic — never crosses this line;
                // a pre-2116 snapshot has no timestamp and
                // crosses it at once, which is correct: its
                // writer either is gone or republishes under
                // the new build within one cycle.
                val claimsLive = parsed["running"] == true ||
                    parsed["connected"] == true
                if (claimsLive &&
                    nowMs - publishedAtMs > STALE_SNAPSHOT_MS
                ) {
                    defaults + ("publishedAtMs" to publishedAtMs)
                } else {
                    parsed
                }
            } catch (_: Throwable) {
                defaults
            }
        }

        /**
         * Build 2088: the MAIN process's failure publish,
         * used by the external watchdog after it kills a
         * wedged :psiphon process (PsiphonExternalWatchdog).
         * The wedged process cannot publish for itself, so
         * the killer writes the terminal snapshot: not
         * running, not connected, wedged. The session's
         * other fields are preserved from the current
         * snapshot; the write is the same atomic rename the
         * service's own publishing uses. Best-effort like
         * all state publishing here.
         */
        fun publishExternalWedged(context: Context) {
            try {
                val current = publishedState(context)
                synchronized(statePublishLock) {
                    val regions = (current["regions"] as? List<*>)
                        ?.map { it.toString() }
                        ?: emptyList()
                    val json = JSONObject()
                        .put("running", false)
                        .put("connected", false)
                        .put("vpnMode", current["vpnMode"] as? Boolean ?: true)
                        .put("sinceMs", (current["sinceMs"] as? Number)?.toLong() ?: 0L)
                        .put("up", (current["up"] as? Number)?.toLong() ?: 0L)
                        .put("down", (current["down"] as? Number)?.toLong() ?: 0L)
                        .put("region", current["region"] as? String ?: "")
                        .put("clientAddress", current["clientAddress"] as? String ?: "")
                        .put("regions", JSONArray(regions))
                        .put("method", current["method"] as? String ?: "")
                        .put("wedged", true)
                        // The killed process has no start
                        // outstanding any more.
                        .put("startReturned", true)
                        .put("publishedAtMs", System.currentTimeMillis())
                    AtomicFile.writeText(File(workDir(context), STATE_FILE), json.toString())
                }
            } catch (_: Throwable) {
                // Best-effort: the kill already ended the
                // session; a stale snapshot ages out through
                // the readers' own staleness handling.
            }
        }

        /** The published snapshot's running flag (build
         *  2073): XrayVpnService's chain checks read this
         *  instead of the companion static, which lives in
         *  the :psiphon process. */
        fun publishedRunning(context: Context): Boolean =
            publishedState(context)["running"] == true

        /** The published snapshot's connected flag (build
         *  2073). */
        fun publishedConnected(context: Context): Boolean =
            publishedState(context)["connected"] == true

        private fun JSONArray?.toStringList(): List<String> {
            val array = this ?: return emptyList()
            return List(array.length()) { index -> array.optString(index, "") }
        }

        /** The Psiphon mode's files: logs and the published
         *  state. (The sidecar's psiphonbox dir is not read
         *  by this service any more — PsiphonBoxCore stays
         *  on disk as the documented fallback.) */
        fun workDir(context: Context): File = File(context.filesDir, "psiphon")

        fun start(
            context: Context,
            vpnMode: Boolean,
            region: String,
            upstream: String,
            protocols: List<String>,
            dns: String,
            mtu: Int = 1500,
            // Build 2057 (audit F-M4): default true keeps
            // the capture-everything behaviour for callers
            // that do not pass it yet.
            ipv6: Boolean = true,
            // Build 2065: ladder inputs; the defaults
            // reproduce the pre-2065 single-attempt start.
            // Build 2091: read again by the MLM host (see
            // onStartCommand) — the protocols list is the
            // one carried-but-unused input.
            rungs: List<String> = emptyList(),
            compartment: String = "",
            cleanAkamai: List<String> = emptyList(),
            cleanFastly: List<String> = emptyList(),
            disableTimeouts: Boolean = false,
            cdnFront: Boolean = false,
            // Build 2125 (A25-04 / S-4): the kill switch.
            killSwitch: Boolean = false,
            // Build 2129 (Leg 2): Shiro bootstrap + strong
            // mode; defaulted false so existing call sites
            // keep the 2128 behaviour.
            shiroBootstrap: Boolean = false,
            strongMode: Boolean = false,
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
                putExtra(EXTRA_KILL_SWITCH, killSwitch)
                putExtra(EXTRA_SHIRO_BOOTSTRAP, shiroBootstrap)
                putExtra(EXTRA_STRONG_MODE, strongMode)
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
