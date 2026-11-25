package com.ralysnd.ember

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.LinkProperties
import android.net.RouteInfo
import android.os.Build
import android.system.OsConstants
import android.util.Log
import co.touchlab.kermit.LogWriter
import co.touchlab.kermit.Logger
import co.touchlab.kermit.Severity
import co.touchlab.kermit.platformLogWriter
import com.wgtunnel.backend.AndroidApplicationProvider
import com.wgtunnel.backend.Tunnel
import com.wgtunnel.backend.TunnelBackend
import com.wgtunnel.backend.model.BackendMode
import com.wgtunnel.backend.model.KillSwitchConfig
import com.wgtunnel.backend.service.AlwaysOnCallback
import com.wgtunnel.backend.service.RuntimeManager
import com.wgtunnel.backend.state.BackendStatus
import com.wgtunnel.backend.system.NetworkMonitor
import com.wgtunnel.backend.system.NetworkSnapshot
import com.wgtunnel.parser.AmneziaConfigNormalizer
import com.wgtunnel.parser.Config
import java.io.File
import java.net.Inet6Address
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The WireGuard / AmneziaWG engine (build 2104): WG Tunnel's
 * backend (github.com/wgtunnel/core, MIT — see the licenses
 * page), replacing the hand-built bridge of builds 2040–2103
 * (AwgBackend + AwgVpnService over a CGO/JNI shim on
 * amneziawg-go v1.0.4, in a dedicated :awg process).
 *
 * Why the replacement (wgtunnel-port-analysis.md, and the
 * owner's device export of 2026-11-18): the old path judged
 * a session by parsing the device's UAPI dump in Dart for a
 * handshake key no device emits (`latest_handshake=`), so
 * the 12 s connect proof ALWAYS expired and the app tore
 * down tunnels that had already completed their handshake.
 * The v1.0.4 device also could not perform the I1 signature
 * shape the composer emitted. Here the state contract is
 * owned end-to-end by one project: the backend's own parser
 * reads its own device's dump (`last_handshake_time_sec`),
 * the ActiveConfigMonitor publishes it into the backend
 * status this file reads, and handshake age is DISPLAY ONLY
 * — a started tunnel is never killed by a state-parse miss
 * or a stale handshake (WG Tunnel semantics; WireGuard's
 * own retransmission is left to run).
 *
 * Shape: everything lives in the MAIN process, like WG
 * Tunnel itself. The backend's own VpnService (declared by
 * the backend artifact, not a foreground service) builds
 * the TUN from the parser Config — routes derive from the
 * peers' AllowedIPs, DNS servers are family-filtered, the
 * MTU is the backend default (1280) — and its
 * VpnCompanionService (specialUse foreground service)
 * carries the persistent notification, which Ember's
 * application provider below builds in Ember's shape. The
 * :awg process, its published state file and the 15 s
 * stale-snapshot death rule are gone (named losses, see
 * BUILD-LOG-2.md).
 *
 * The channel contract is unchanged: MainActivity's
 * awgSetOn hands this object the profile's canonical .conf
 * text (wgConfFromProfile), the C1-resolved DNS, and the
 * profile's IPv4/IPv6 footprint flags; xrayState reads the
 * session back through [snapshot].
 */
object WgTunnelEngine {
    private const val TAG = "WgTunnelEngine"

    /** The one tunnel Ember runs on this backend at a time. */
    const val TUNNEL_ID = 1

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** Serializes start/stop (verification iteration 1,
     *  finding 7): both are launched coroutines, and without
     *  an order a stop can land after the start that follows
     *  it — the backend silently accepts a duplicate start,
     *  so a race here would report success for the NEW
     *  profile while the OLD tunnel keeps running. */
    private val startStopMutex = Mutex()

    @Volatile
    private var backendRef: TunnelBackend? = null

    @Volatile
    private var sessionName = ""

    @Volatile
    private var startedAtMs = 0L

    /** The last stop arrived through a stop path (the app's
     *  own stop, or the notification's Disconnect) rather
     *  than a drop or a failure — the Dart poll ends the
     *  auto-reconnect expectation on it. Mirrors the old
     *  service's ACTION_STOP funnel: every stop in this
     *  object marks it, every start clears it. */
    @Volatile
    var userStopped = false
        private set

    /** The last start failure / unexpected-stop reason, ''
     *  when healthy — surfaced as xrayState's coreProblem. */
    @Volatile
    var coreProblem = ""
        private set

    /** Build 2127 (H4, audit A26-03): the kill-switch
     *  hold for this engine — the library's own lockdown
     *  (TunnelBackend.setKillSwitch), raised by the drop
     *  watcher when a session whose start carried the
     *  switch dies unexpectedly; released by any user
     *  stop or fresh start (disableKillSwitch). */
    @Volatile
    var killSwitchHeld = false
        private set

    /** The live session's kill-switch flag and address
     *  families, taken at start: the watcher reads them
     *  when the drop lands, which may be long after. */
    @Volatile
    private var sessionKillSwitch = false

    @Volatile
    private var sessionDualStack = false

    /** Monotonic count of recorded problems (verification
     *  iteration 2, M3): Dart's connect wait compares this
     *  sequence, not the problem text — engine failures are
     *  templated, so a repeat failure reproduces the same
     *  string, and a text sentinel cannot tell the new
     *  failure from the stale one. An AtomicInteger
     *  (iteration 3, L-1): records land from several
     *  threads (the status collector, the revoke callback,
     *  the start coroutine), and a plain ++ could lose an
     *  increment to a race. */
    private val problemSeqCounter = AtomicInteger(0)

    /** The current problem sequence (see above). */
    val problemSeq: Int get() = problemSeqCounter.get()

    /** Monotonic count of NOTIFICATION stops (build 2106,
     *  verification iteration 2, M-1): [stop] is a single
     *  funnel — the app's own stops and the notification's
     *  Disconnect both land there and both mark
     *  [userStopped] — so the flag alone cannot tell Dart
     *  WHO stopped a session. This sequence can: only the
     *  notification entry points advance it (see
     *  [stopFromNotification]). Dart's peer walk snapshots
     *  it before tearing down a silent AmneziaWG leg and
     *  re-reads it after its own stop: an advance means the
     *  user stopped the session mid-teardown, and the walk
     *  ends instead of reconnecting the plain leg over the
     *  user's Disconnect. */
    private val userStopSeqCounter = AtomicInteger(0)

    /** The current notification-stop sequence (see above). */
    val userStopSeq: Int get() = userStopSeqCounter.get()

    /** The notification Disconnect's entry point: records
     *  the stop as the user's own (the sequence above),
     *  then runs the common stop funnel. */
    fun stopFromNotification(context: Context) {
        userStopSeqCounter.incrementAndGet()
        stop(context)
    }

    /** The only writer of a non-empty [coreProblem], so the
     *  sequence above always advances with the text. */
    private fun recordProblem(message: String) {
        coreProblem = message
        problemSeqCounter.incrementAndGet()
    }

    @Volatile
    private var sessionActive = false

    /** Starts currently in flight (verification iteration
     *  2, L5): a counter, not a flag — with a flag, the
     *  first of two overlapping starts cleared it in its
     *  finally while the second was still queued on the
     *  start/stop mutex, opening a window in which the drop
     *  watcher could publish a spurious problem. start()
     *  increments it synchronously, its coroutine decrements
     *  it in the finally; the watcher gates on zero. */
    private val startsInFlight = AtomicInteger(0)

    /** Builds the backend eagerly (verification iteration
     *  1, finding 1): TunnelBackend's constructor is the
     *  only place BackendRuntime.install runs, and the
     *  backend's own services (its START_STICKY companion
     *  service, its persistent VpnService) dereference that
     *  runtime when the SYSTEM restarts them — in a fresh
     *  process where a lazy, Dart-driven first build would
     *  not have happened yet, they would crash instead of
     *  restoring. Upstream WG Tunnel constructs its backend
     *  as an eager app-start singleton for the same reason;
     *  EmberApplication.onCreate calls this (main process
     *  only). Idempotent — the lazy path below stays as the
     *  fallback for any caller that arrives first. */
    fun install(context: Context) {
        backend(context)
    }

    /** The backend, built once per process: the provider,
     *  the network monitor and the backend itself (whose
     *  init installs BackendRuntime for its services). Also
     *  starts the unexpected-drop watcher and points the
     *  backend's logger at awg.log, the file the diagnostics
     *  bundle exports — the successor of the old bridge's
     *  setLogFile (the awg-stderr.log panic capture has no
     *  equivalent here; named loss). */
    @Synchronized
    private fun backend(context: Context): TunnelBackend {
        backendRef?.let { return it }
        val appContext = context.applicationContext ?: context
        installBackendLogFile(appContext)
        val provider = EmberWgApplicationProvider(appContext)
        val created = TunnelBackend(
            scope,
            provider,
            EmberNetworkMonitor(appContext),
        )
        backendRef = created
        // Build 2104 (verification iteration 2, M2): the
        // system's session requests — sticky restarts and
        // Always-On triggers — land on this callback;
        // upstream assigns its own in its Application class
        // for the same reason.
        RuntimeManager.alwaysOnCallback = emberAlwaysOnCallback
        // Build 2116 (B7-1, AB-08): the resurrection
        // reconcile. The backend restores its tunnels at
        // process start with no Dart involvement — the one
        // start path that bypasses every funnel above. The
        // first status that shows a restored tunnel is
        // arbitrated against the claim: the slot is free (or
        // already WireGuard's) → the restored session claims
        // it, and the Dart shell adopts it on foreground;
        // another engine owns the slot → the restored
        // tunnels stand down instead of fighting it for the
        // route. Bounded: no restored tunnel within the
        // window means there is nothing to arbitrate.
        scope.launch {
            val restored = withTimeoutOrNull(15_000) {
                created.status.first { it.activeTunnels.isNotEmpty() }
            } ?: return@launch
            val owner = EngineClaim.owner(appContext)
            if (owner == null || owner == EngineClaim.WIREGUARD) {
                EngineClaim.claim(appContext, EngineClaim.WIREGUARD)
            } else {
                CrashLog.breadcrumb(
                    appContext,
                    "engine-claim: restored WG tunnel stood down; " +
                        "the slot belongs to $owner",
                )
                runCatching { created.stopAllActiveTunnels() }
                    .onFailure {
                        Log.w(TAG, "restored-tunnel stand-down failed", it)
                    }
            }
        }
        scope.launch {
            created.status.collect { status ->
                if (sessionActive && startsInFlight.get() == 0 &&
                    !status.activeTunnels.containsKey(TUNNEL_ID)
                ) {
                    // The tunnel vanished without our stop:
                    // a revoke, or the backend's own teardown.
                    sessionActive = false
                    if (!userStopped) {
                        // Build 2127 (H4): the kill switch —
                        // raise the library's lockdown (its
                        // kill-switch VpnService blocks
                        // everything outside the allowed set,
                        // here empty) so the drop blackholes
                        // instead of going direct, until the
                        // user's own stop or a fresh start
                        // disables it.
                        var holdRaised = false
                        if (sessionKillSwitch) {
                            val held = runCatching {
                                created.setKillSwitch(
                                    KillSwitchConfig(
                                        emptySet(),
                                        metered = false,
                                        dualStack = sessionDualStack,
                                    ),
                                )
                            }.getOrNull()?.isSuccess == true
                            if (held) {
                                killSwitchHeld = true
                                holdRaised = true
                            } else {
                                Log.w(
                                    TAG,
                                    "the kill-switch lockdown " +
                                        "could not be raised",
                                )
                            }
                        }
                        recordProblem(
                            "the AmneziaWG engine stopped; " +
                                "the session was closed",
                        )
                        // Build 2149 (audit A43-19): when no
                        // lockdown holds the slot for this
                        // dead session, the engine claim goes
                        // back — every other post-claim exit
                        // releases it (build 2126, A26-18);
                        // this collector was the one path
                        // that kept it forever. A raised hold
                        // keeps the claim: the lockdown IS
                        // WireGuard still owning the slot.
                        if (!holdRaised) {
                            EngineClaim.release(
                                appContext, EngineClaim.WIREGUARD,
                            )
                        }
                    }
                }
            }
        }
        return created
    }

    /** The backend's system-session callback (iteration 2,
     *  M2). Ember keeps profiles and session intent on the
     *  Dart side, so a companion service the system restarts
     *  after process death has no session here to restore:
     *  left alone it would sit in the foreground forever
     *  with its "connecting" notification, and Ember's stop
     *  could not dismiss it (a backend stop with no active
     *  tunnel is a no-op — only stopAllActiveTunnels
     *  destroys the runtime). So a restart / Always-On
     *  request that finds no live tunnel shuts the runtime
     *  down; when the user reopens the app, Dart re-drives
     *  the session from its own state. A revoke, by
     *  contrast, is a live-session event: the backend tears
     *  its own tunnels down, and Ember's half is the
     *  bookkeeping that keeps state() honest. */
    private val emberAlwaysOnCallback = object : AlwaysOnCallback {
        override fun alwaysOnTriggered() = onSystemSessionRequest()

        override fun onStickyRestart() = onSystemSessionRequest()

        override fun onVpnRevoked() {
            if (sessionActive && !userStopped) {
                sessionActive = false
                recordProblem(
                    "the VPN permission was revoked; " +
                        "the session was closed",
                )
            }
        }

        private fun onSystemSessionRequest() {
            val backend = backendRef ?: return
            scope.launch {
                // Serialized with start/stop, and not while
                // a start is in flight (iteration 3, L-2;
                // iteration 4, Low-3): holding the mutex
                // while checking makes the guarantee exact
                // for every start already issued — it has
                // either registered its tunnel (the map is
                // non-empty and this is a no-op) or it has
                // not begun its locked body (the counter is
                // non-zero and this stands down). A start
                // issued only AFTER this cleanup is a new
                // user action, not a race.
                startStopMutex.withLock {
                if (startsInFlight.get() == 0 &&
                    backend.status.value.activeTunnels.isEmpty()
                ) {
                    runCatching { backend.stopAllActiveTunnels() }
                        .onFailure {
                            Log.w(TAG, "runtime shutdown failed", it)
                        }
                }
                }
            }
        }
    }

    /** Whether a session is live on the backend right now
     *  (the rotate guard's question): a tunnel object exists
     *  and is not Down. Deliberately conservative
     *  (verification iteration 1, finding 11): Starting and
     *  Stopping count as live — the guard's job is to refuse
     *  a core rotation while ANY AWG session exists or is on
     *  its way, so a transitioning tunnel must block it too.
     *  After a process recreation the eager install
     *  (EmberApplication) has rebuilt the backend before any
     *  caller can ask, so the status read is the backend's
     *  own restored view. */
    fun isLive(context: Context): Boolean {
        // Built lazily if somehow missing (iteration 2,
        // L1): the eager install makes this a formality, but
        // an entry point that silently answers "not live"
        // for a not-yet-built backend is a wrong answer, not
        // a safe one.
        val backend = backend(context)
        val active = backend.status.value.activeTunnels[TUNNEL_ID]
            ?: return false
        return active.transportState != Tunnel.State.Down
    }

    /**
     * Starts the AmneziaWG tunnel for [name] from the
     * profile's canonical .conf text. [dnsCsv] is the
     * C1-resolved DNS (build 2102: the profile's own .conf
     * DNS when it carries one, else the Settings local DNS);
     * when non-empty it replaces the parsed config's DNS
     * line wholesale — the same value the old service put
     * on its TUN — and when empty the profile's own DNS
     * line (already the C1 winner in that case) stands.
     * [ipv4]/[ipv6] are the profile's footprint flags (builds
     * 2102/2103), used only for the full-tunnel AllowedIPs
     * default below. Asynchronous: the outcome lands in
     * [snapshot] (sessionActive / coreProblem), exactly as
     * the old intent-based start landed in the published
     * state file.
     */
    fun start(
        context: Context,
        name: String,
        confText: String,
        dnsCsv: String,
        ipv4: Boolean,
        ipv6: Boolean,
        settingsMtu: Int = 0,
        // Build 2127 (H4): the global kill switch, read
        // by the drop watcher if this session dies.
        killSwitch: Boolean = false,
    ) {
        val appContext = context.applicationContext ?: context
        CrashLog.breadcrumb(appContext, "awg:start-invoked")
        sessionKillSwitch = killSwitch
        sessionDualStack = ipv4 && ipv6
        killSwitchHeld = false
        // Build 2125 (audit A25-46 / P-50): the VPN-slot
        // claim no longer happens HERE. Up to 2124 this
        // synchronous claim displaced the previous owner
        // before the config was even parsed — a WG start
        // with an invalid config killed the running session
        // and then failed validation, leaving nothing up.
        // The claim now sits inside the serialized body,
        // after validation has passed and the start is
        // committed (see below).
        userStopped = false
        coreProblem = ""
        sessionName = name
        startsInFlight.incrementAndGet()
        scope.launch {
            // Serialized with stop() (finding 7): the whole
            // start completes — or fails — before a queued
            // stop runs, and vice versa. The decrement sits
            // in a finally AROUND the mutex (iteration 3,
            // L-4): a coroutine cancelled while queued never
            // enters the locked body, and the counter must
            // still balance or the drop watcher stays
            // disabled for the process lifetime.
            try {
            startStopMutex.withLock {
            try {
                rotateBackendLog(appContext)
                val parsed = Config.parseQuickString(confText)
                // Ember's semantics FIRST, validation LAST
                // (verification iteration 1, finding 6;
                // iteration 2, L2): the config that ships is
                // the one to validate — a junk profile MTU
                // must not fail a start whose MTU is sanitised
                // by the semantics pass anyway (build 2116),
                // and the C1 replacement DNS (Settings
                // free text, which the TUN builder will
                // consume) is validated rather than the
                // profile's discarded DNS line; the validation
                // itself sits after the normalizer below, so
                // it judges the final shipped config. The
                // parser itself is lenient (unknown keys are
                // ignored — that is where J1–J3 go).
                val shaped = applyEmberSemantics(
                    appContext, parsed, dnsCsv, ipv4, ipv6, settingsMtu,
                )
                if (shaped.peers.isEmpty()) {
                    // Config.validate() never requires a peer;
                    // a peerless config would bring up a
                    // route-less TUN and report it running
                    // (finding 15). Ember's importers reject
                    // such confs already — this is the gate
                    // at the engine door.
                    throw IllegalArgumentException(
                        "the profile has no peer",
                    )
                }
                // WG Tunnel's own import treatment: when a
                // config carries the I1–I5 signature family,
                // fill any missing base Amnezia parameters
                // with the standard defaults (a no-op for
                // configs that carry their own).
                val configured =
                    AmneziaConfigNormalizer.ensureAmneziaCompatibility(shaped)
                // Validation LAST (verification iteration 2,
                // L2): the config that is actually shipped —
                // semantics applied AND the normalizer's
                // defaults filled — is the one validated.
                configured.validate()
                if (configured.`interface`.hasScripts) {
                    // scriptsEnabled=false: PreUp/PostUp are
                    // not executed — parity with builds
                    // ≤2103, whose UAPI path had no scripts
                    // either — but not silently (finding 14):
                    // the drop is on the record.
                    CrashLog.breadcrumb(
                        appContext, "awg:scripts-not-executed",
                    )
                    Log.w(
                        TAG,
                        "config carries PreUp/PostUp scripts; " +
                            "not executed (scriptsEnabled=false)",
                    )
                }
                // A stop issued after this start wins
                // (iteration 4, Low-4): the stop's own
                // teardown may already have run as a no-op —
                // nothing was registered yet — so without
                // this re-check the start would bring a
                // tunnel up behind a completed stop,
                // inverting the user's Disconnect. (start()
                // cleared the flag synchronously when it was
                // issued, so a true here is always a LATER
                // stop.)
                if (userStopped) {
                    sessionActive = false
                    CrashLog.breadcrumb(
                        appContext, "awg:start-superseded-by-stop",
                    )
                    return@withLock
                }
                // Build 2125 (audit A25-46 / P-50): the
                // start is committed — the config parsed,
                // shaped and validated, and no stop
                // superseded it. Only NOW does the start
                // claim the VPN slot (build 2116, B7-1)
                // and displace the previous owner: a start
                // that failed anywhere above leaves the
                // running session untouched.
                EngineClaim.claim(appContext, EngineClaim.WIREGUARD)
                val backend = backend(appContext)
                // A previous session with our id must be gone
                // before the start: the backend treats a
                // duplicate-id start as a silent SUCCESS
                // (upstream TunnelBackend logs "already
                // running" and returns), which would report
                // this profile started while the old tunnel
                // keeps running — so the pre-stop here is
                // load-bearing, and the start/stop mutex is
                // what makes it race-free.
                if (backend.status.value.activeTunnels
                        .containsKey(TUNNEL_ID)
                ) {
                    backend.stop(TUNNEL_ID)
                    // Build 2110 (wg-start diagnosis, defect
                    // 2): WAIT, bounded, for the dying tunnel
                    // to actually leave before starting over
                    // it — the stop above is asynchronous, and
                    // a start issued while the old entry still
                    // stands is either swallowed as a
                    // duplicate or revoked with the old
                    // tunnel's VPN slot. If it is still not
                    // down when the bound expires, fail FAST
                    // with a distinct problem instead of
                    // starting into the dying tunnel.
                    val stopDeadlineMs =
                        System.currentTimeMillis() + 2_000
                    while (System.currentTimeMillis() <
                        stopDeadlineMs
                    ) {
                        val active = backend.status.value
                            .activeTunnels[TUNNEL_ID]
                        if (active == null ||
                            active.transportState ==
                            Tunnel.State.Down
                        ) {
                            break
                        }
                        delay(50)
                    }
                    val lingering = backend.status.value
                        .activeTunnels[TUNNEL_ID]
                    if (lingering != null &&
                        lingering.transportState !=
                        Tunnel.State.Down
                    ) {
                        sessionActive = false
                        recordProblem(
                            "the previous tunnel is still " +
                                "stopping; this start was " +
                                "refused — try again in a " +
                                "moment",
                        )
                        CrashLog.breadcrumb(
                            appContext,
                            "awg:start-refused-previous-stopping",
                        )
                        Log.w(
                            TAG,
                            "AWG start refused: the previous " +
                                "tunnel is still stopping",
                        )
                        // Build 2126 (audit A26-18): this
                        // start already claimed at the
                        // commit point above and now starts
                        // nothing — release the marker here
                        // (owner-checked), like every other
                        // post-claim failure exit below.
                        EngineClaim.release(
                            appContext, EngineClaim.WIREGUARD,
                        )
                        return@withLock
                    }
                }
                // Build 2127 (H4): a fresh start releases
                // any previous session's lockdown before
                // its own tunnel comes up (a no-op when no
                // lockdown is in place).
                runCatching { backend.disableKillSwitch() }
                    .onFailure {
                        Log.w(TAG, "kill-switch release failed", it)
                    }
                val result = backend.start(
                    EmberWgTunnel(name, ipv6),
                    BackendMode.Vpn(configured),
                    // Null: the backend uses the Config's own
                    // DNS (already the C1 value, see
                    // applyEmberSemantics) — WG Tunnel's
                    // fake-DNS mode is not Ember's shape.
                    tunnelDnsConfig = null,
                )
                if (result.isSuccess) {
                    // A tunnel revoked in the resume gap
                    // (iteration 4, Low-8): the status
                    // emission fired while sessionActive was
                    // still false, so the watcher stayed
                    // silent — re-read the map here, and let
                    // a vanished tunnel record its drop
                    // instead of a false "connected".
                    if (backend.status.value.activeTunnels
                            .containsKey(TUNNEL_ID)
                    ) {
                        sessionActive = true
                        startedAtMs = System.currentTimeMillis()
                        coreProblem = ""
                        CrashLog.breadcrumb(appContext, "awg:connected")
                    } else {
                        sessionActive = false
                        // Build 2126 (A26-18): claimed but
                        // never adopted — release the marker
                        // (owner-checked: a revoking engine's
                        // own claim is untouched).
                        EngineClaim.release(
                            appContext, EngineClaim.WIREGUARD,
                        )
                        // Build 2110 (wg-start diagnosis,
                        // defect 2): name the revocation on
                        // the record — the start reported
                        // success but the tunnel vanished in
                        // the resume gap, which is the VPN
                        // slot being revoked (another engine
                        // or the system took it), not the
                        // engine stopping on its own.
                        CrashLog.breadcrumb(
                            appContext,
                            "awg:start-revoked-in-resume-gap",
                        )
                        Log.w(
                            TAG,
                            "AWG start reported success but " +
                                "the tunnel vanished before " +
                                "it could be adopted — the " +
                                "VPN slot was revoked",
                        )
                        recordProblem(
                            "the AmneziaWG engine stopped; " +
                                "the session was closed",
                        )
                    }
                } else {
                    sessionActive = false
                    // Build 2126 (A26-18): post-claim
                    // failure — release the marker.
                    EngineClaim.release(
                        appContext, EngineClaim.WIREGUARD,
                    )
                    val cause = result.exceptionOrNull()
                    recordProblem(
                        "the AmneziaWG engine could not start" +
                            (cause?.message?.let { ": $it" } ?: ""),
                    )
                    CrashLog.breadcrumb(appContext, "awg:start-failed")
                    Log.e(TAG, "AWG start failed", cause)
                }
            } catch (e: CancellationException) {
                // Not a failure (iteration 4, Low-5): a
                // cancelled start records nothing and stays
                // cancelled.
                sessionActive = false
                // Build 2126 (A26-18): a start cancelled
                // after claiming releases the marker too
                // (owner-checked; a superseding stop's own
                // release is unaffected).
                EngineClaim.release(
                    appContext, EngineClaim.WIREGUARD,
                )
                throw e
            } catch (e: Throwable) {
                sessionActive = false
                // Build 2126 (A26-18): post-claim failure —
                // release the marker.
                EngineClaim.release(
                    appContext, EngineClaim.WIREGUARD,
                )
                recordProblem(
                    "the AmneziaWG engine could not start: ${e.message}",
                )
                CrashLog.breadcrumb(appContext, "awg:start-failed")
                CrashLog.append(appContext, "WgTunnelEngine.start", e)
                Log.e(TAG, "AWG start failed", e)
            }
            }
            } finally {
                startsInFlight.decrementAndGet()
            }
        }
    }

    /** Stops the session (the app's stop paths and the
     *  notification's Disconnect funnel here, as they used
     *  to funnel into the old service's ACTION_STOP). */
    fun stop(context: Context) {
        // Build 2125 (audit A25-46 / P-50): the claim is
        // NOT released here anymore. Up to 2124 the marker
        // was freed synchronously while the actual teardown
        // landed later inside the mutex — another engine
        // could claim the "free" slot and start, and this
        // stop's still-landing teardown then revoked the
        // NEW session's TUN. The release now sits at the
        // end of the serialized body below, after the
        // teardown has been observed down.
        userStopped = true
        sessionActive = false
        // Build 2127 (H4): a user stop releases the
        // kill-switch lockdown (the disable itself runs
        // in the serialized body below).
        killSwitchHeld = false
        // A user stop supersedes any recorded failure
        // (verification iteration 1, finding 2): with this
        // cleared — and the state merge consulting
        // userStopped before the problem branch — a stop
        // after a failed start can never be reported as an
        // unexpected drop that auto-reconnect resurrects.
        coreProblem = ""
        CrashLog.breadcrumb(context, "awg:stop-invoked")
        // Built lazily if somehow missing (iteration 2,
        // L1): a stop that returns early because the backend
        // was never built in this process would leave a
        // live session running behind a "stopped" UI.
        val backend = backend(context)
        scope.launch {
            // Serialized with start() (finding 7).
            startStopMutex.withLock {
                // Build 2127 (H4): the lockdown goes down
                // with the session it held for.
                runCatching { backend.disableKillSwitch() }
                    .onFailure {
                        Log.w(TAG, "kill-switch release failed", it)
                    }
                runCatching { backend.stop(TUNNEL_ID) }
                    .onFailure { Log.w(TAG, "AWG stop failed", it) }
                // Wait, bounded, for the teardown to
                // actually land (verification iteration 3,
                // L-3) — since build 2110 the wait runs HERE,
                // inside the serialized stop body, not on
                // stop()'s calling thread (wg-start
                // diagnosis, defect 3): the channel handlers
                // invoke stop() on the main thread, and the
                // old calling-thread wait blocked it for up
                // to the full bound on every AWG→Xray switch
                // — long enough to matter to the Xray
                // service's foreground-start deadline. The
                // ordering the wait existed for is preserved
                // by the mutex itself: a start queued behind
                // this stop cannot run until the wait has
                // observed the teardown (or the bound has
                // expired), and callers observe the end by
                // polling state, as Dart's connect paths do.
                // The bound matches the backend's own
                // shutdown timeout; with no session (the
                // common dual-stop case) the loop exits on
                // its first check, and a real teardown
                // normally lands in milliseconds.
                val deadlineMs = System.currentTimeMillis() + 1_500
                while (System.currentTimeMillis() < deadlineMs) {
                    val active = backend.status.value
                        .activeTunnels[TUNNEL_ID]
                    // Also wait out an in-flight start
                    // (iteration 4, Low-4): its locked body
                    // either registers the tunnel (this stop
                    // then tears it down) or sees userStopped
                    // and stands down — both land within the
                    // bound in the common case; a start
                    // parked on the consent prompt simply
                    // outlasts the wait, and its own re-check
                    // still honors this stop.
                    if ((active == null ||
                            active.transportState ==
                            Tunnel.State.Down) &&
                        startsInFlight.get() == 0
                    ) {
                        break
                    }
                    delay(50)
                }
                // Build 2125 (audit A25-46 / P-50): the
                // teardown has landed (or the bound expired)
                // — only now is the VPN-slot claim released
                // (build 2116, B7-1; owner-checked), so the
                // marker never reads "free" while this
                // engine's TUN is still up.
                EngineClaim.release(
                    context.applicationContext ?: context,
                    EngineClaim.WIREGUARD,
                )
            }
        }
    }

    /** Whether a tunnel is still REGISTERED with the
     *  backend (build 2110): the snapshot-style read behind
     *  xrayState's awgTunnelPresent — the engine-switch
     *  funnel polls it to observe a previous AWG session
     *  fully down. Never builds the backend: a process that
     *  never started AWG has no tunnel by definition. */
    fun tunnelPresent(): Boolean {
        val backend = backendRef ?: return false
        return backend.status.value.activeTunnels
            .containsKey(TUNNEL_ID)
    }

    /** The session as xrayState reports it. Handshake age
     *  and the byte counters come from the backend's own
     *  ActiveConfig (its parser over its device's dump,
     *  published by the ActiveConfigMonitor feature the
     *  tunnel carries) — display and accounting only. */
    fun snapshot(): Snapshot {
        val backend = backendRef
        val active = backend?.status?.value?.activeTunnels?.get(TUNNEL_ID)
        val running = sessionActive && active != null &&
            active.transportState is Tunnel.State.Up
        var rx = 0L
        var tx = 0L
        var handshakeAgeSec = -1L
        val peers = active?.activeConfig?.peers.orEmpty()
        for (peer in peers) {
            rx += peer.rxBytes ?: 0L
            tx += peer.txBytes ?: 0L
        }
        val lastHandshake = peers
            .mapNotNull { it.lastHandshakeSeconds }
            .filter { it > 0 }
            .maxOrNull()
        if (lastHandshake != null) {
            handshakeAgeSec =
                (System.currentTimeMillis() / 1000 - lastHandshake)
                    .coerceAtLeast(0)
        }
        // The problem pair, read consistently (iteration 3,
        // L-1; iteration 4, Low-2): re-read until the
        // sequence is stable across the text read, so the
        // pair can never mix a new text with an old sequence
        // (which would hide the reason from Dart's sequence
        // comparison). Records are rare; the loop runs once
        // in practice.
        var seq: Int
        var problem: String
        do {
            seq = problemSeqCounter.get()
            problem = coreProblem
        } while (seq != problemSeqCounter.get())
        return Snapshot(
            running = running,
            name = sessionName,
            sinceMs = startedAtMs,
            up = tx,
            down = rx,
            coreProblem = problem,
            problemSeq = seq,
            userStopSeq = userStopSeqCounter.get(),
            userStopped = userStopped,
            handshakeAgeSec = handshakeAgeSec,
            rxBytes = rx,
            txBytes = tx,
            killSwitchHeld = killSwitchHeld,
        )
    }

    data class Snapshot(
        val running: Boolean,
        val name: String,
        val sinceMs: Long,
        val up: Long,
        val down: Long,
        val coreProblem: String,
        val problemSeq: Int,
        val userStopSeq: Int,
        val userStopped: Boolean,
        val handshakeAgeSec: Long,
        val rxBytes: Long,
        val txBytes: Long,
        // Build 2127 (H4): the library lockdown is up.
        val killSwitchHeld: Boolean,
    )

    /**
     * Ember's semantics over the parsed config, the
     * successor of the old service's TUN shaping:
     * - DNS: the channel's C1 value wins (see [start]).
     * - MTU: the profile's own value wins when sane
     *   (576..9000), the Settings tunnel MTU is the
     *   fallback, and only when neither is usable does
     *   the backend default (1280) rule — see the
     *   sanitising block in [applyEmberSemantics]
     *   (build 2116, B3; this bullet said "cleared"
     *   from 2104 to 2118, which stopped being true
     *   in 2116).
     * - Per-app routing: CoreService's stored choice, the
     *   same lists the old service applied to its Builder.
     * - AllowedIPs: a peer without any keeps the old
     *   composer's full-tunnel default, family-gated by
     *   the profile's footprint flags — a v6-only profile
     *   gains no 0.0.0.0/0 (build 2102, diagnosis C2) and a
     *   v4-only profile gains no ::/0. A peer WITH
     *   AllowedIPs is untouched: the backend derives the
     *   TUN routes from it, which is what makes C2/C3
     *   properties of the tunnel rather than of our code.
     */
    private fun applyEmberSemantics(
        context: Context,
        config: Config,
        dnsCsv: String,
        ipv4: Boolean,
        ipv6: Boolean,
        settingsMtu: Int = 0,
    ): Config {
        var iface = config.`interface`
        val dnsServers = dnsCsv.split(",")
            .map { it.trim() }
            .filter { it.isNotEmpty() }
        if (dnsServers.isNotEmpty()) {
            iface = iface.copy(dns = dnsServers.joinToString(", "))
        }
        // Build 2116 (audit B3-1): the profile's MTU is no
        // longer discarded (builds 2104–2115 nulled it, so
        // the backend's 1280 default silently overrode both
        // the profile's MTU line and the Settings tunnel
        // MTU). The profile's value wins when sane; the
        // Settings value (the channel argument) is the
        // fallback; only when neither is usable does the
        // backend default rule. Sanitising here keeps the
        // validate-last ordering honest: a junk MTU is
        // replaced before Config.validate() ever sees it.
        val profileMtu = iface.mtu
        // Build 2125 (audit A25-38 / P-42): the MTU range is
        // aligned with every other TUN path in the app
        // (1280–1500, the Lantern clamp's range): up to 2124
        // a stored 576–9000 was honoured verbatim, so a
        // jumbo-MTU profile "connected" while its frames
        // fragmented/blackholed on real paths, with no
        // warning anywhere. Out-of-range values clamp to
        // the range (the stored profile is untouched), and
        // a clamp is journaled.
        val rawMtu = when {
            profileMtu != null && profileMtu in 576..9000 ->
                profileMtu
            settingsMtu in 576..9000 -> settingsMtu
            else -> null
        }
        val clampedMtu = rawMtu?.coerceIn(1280, 1500)
        if (rawMtu != null && clampedMtu != rawMtu) {
            CrashLog.breadcrumb(
                context,
                "wireguard:mtu $rawMtu clamped to $clampedMtu",
            )
        }
        iface = iface.copy(mtu = clampedMtu)
        val (included, excluded) = emberAppLists(context)
        iface = iface.copy(
            includedApplications = included,
            excludedApplications = excluded,
        )
        val peers = config.peers.map { peer ->
            if (peer.allowedIPs.isNullOrBlank()) {
                val defaults = listOfNotNull(
                    if (ipv4) "0.0.0.0/0" else null,
                    if (ipv6) "::/0" else null,
                ).ifEmpty {
                    // A profile with no family footprint at
                    // all (no addresses, no routes): the
                    // historical composer's full-tunnel v4
                    // default, rather than a route-less
                    // tunnel that reports Up and carries
                    // nothing (verification iteration 1,
                    // finding 13).
                    listOf("0.0.0.0/0")
                }
                peer.copy(allowedIPs = defaults.joinToString(", "))
            } else {
                peer
            }
        }
        return config.copy(`interface` = iface, peers = peers)
    }

    /** The per-app lists, mirroring the old service's
     *  applyApps: include mode with a non-empty Only set
     *  wins; otherwise the app itself plus the Bypass set
     *  are excluded. Entries for uninstalled packages are
     *  dropped here — the backend's Builder calls throw on
     *  them, where the old service caught per entry. */
    private fun emberAppLists(context: Context): Pair<List<String>?, List<String>?> {
        fun installed(packages: Set<String>): List<String> =
            packages.filter { pkg ->
                try {
                    context.packageManager.getPackageInfo(pkg, 0)
                    true
                } catch (e: PackageManager.NameNotFoundException) {
                    false
                }
            }
        if (CoreService.appMode(context) == CoreService.MODE_INCLUDE) {
            val only = installed(
                CoreService.appSet(context, CoreService.ONLY) -
                    context.packageName,
            )
            if (only.isNotEmpty()) return only to null
            // Build 2125 (audit A25-36 / P-41): the Only
            // set resolved to nothing installed; the
            // fall-through to excluded-mode (all apps)
            // below is journaled, never silent.
            CrashLog.breadcrumb(
                context,
                "wireguard:per-app Only set empty — all apps use the tunnel",
            )
        }
        val excluded = listOf(context.packageName) + installed(
            CoreService.appSet(context, CoreService.BYPASS) -
                context.packageName,
        )
        return null to excluded
    }

    /** The backend's log file: workDir/awg.log, the file
     *  the diagnostics bundle has always exported for this
     *  engine. Installed once, before the backend exists. */
    private fun installBackendLogFile(context: Context) {
        try {
            val file = File(XrayVpnService.workDir(context), "awg.log")
            Logger.setLogWriters(
                platformLogWriter(),
                AwgLogWriter(file),
            )
        } catch (e: Throwable) {
            Log.w(TAG, "backend log file not installed", e)
        }
    }

    /** Bounds awg.log at session start (1 MiB, one .old
     *  generation) — the bound the old bridge kept. */
    private fun rotateBackendLog(context: Context) {
        try {
            val file = File(XrayVpnService.workDir(context), "awg.log")
            if (!file.exists() || file.length() <= (1 shl 20)) return
            val old = File(XrayVpnService.workDir(context), "awg.log.old")
            if (old.exists()) old.delete()
            file.renameTo(old)
        } catch (e: Exception) {
            Log.w(TAG, "awg.log rotation failed", e)
        }
    }

    /** Appends the backend's log lines to awg.log. Writes
     *  are best-effort and serialized; a logging failure
     *  must never reach the engine. */
    private class AwgLogWriter(private val file: File) : LogWriter() {
        override fun log(
            severity: Severity,
            message: String,
            tag: String,
            throwable: Throwable?,
        ) {
            try {
                val line = buildString {
                    append(severity.name).append(' ').append(tag)
                    append(": ").append(message).append('\n')
                    if (throwable != null) {
                        append(throwable.toString()).append('\n')
                    }
                }
                synchronized(file) { file.appendText(line) }
            } catch (_: Throwable) {
                // Evidence plumbing, never behaviour.
            }
        }
    }
}

/** The one tunnel Ember runs on the WG Tunnel backend:
 *  metered off, no scripts, the ActiveConfigMonitor the
 *  state reads ride on. No Recovery feature is DECLARED —
 *  Ember's own peer walk and reconnect supervision stay in
 *  charge of candidate selection and session adoption, as
 *  they are for every other engine. Admitted delta
 *  (verification iteration 1, finding 5): the backend
 *  nevertheless runs its baseline TunnelRecovery for every
 *  tunnel — endpoint re-resolution and, for dynamic
 *  endpoints, a synthesized IPv6 fallback — regardless of
 *  the declared feature set. That is the upstream engine's
 *  designed behavior and the port adopts it; it acts only
 *  inside a live session (it never starts one, and its
 *  bounce follows a sustained handshake failure). The IP
 *  strategy follows the profile's own IPv6 footprint —
 *  upstream derives it from a per-tunnel preference flag
 *  Ember does not carry; the footprint flags are the
 *  honest local equivalent (finding 8). */
private class EmberWgTunnel(
    override val name: String,
    ipv6Preferred: Boolean,
) : Tunnel {
    override val id: Int = WgTunnelEngine.TUNNEL_ID
    override val isMetered: Boolean = false
    override val scriptsEnabled: Boolean = false
    override val ipStrategy: Tunnel.IpStrategy =
        if (ipv6Preferred) {
            Tunnel.IpStrategy.PreferIpv6(recoveryEnabled = false)
        } else {
            Tunnel.IpStrategy.Ipv4Only
        }
    override val features: Set<Tunnel.Feature> =
        setOf(Tunnel.Feature.ActiveConfigMonitor(intervalSeconds = 1))

    override fun updateState(state: Tunnel.State) = Unit
}

/** The backend's network monitor: the current NON-VPN
 *  network's identity, IPv6 footprint and usability,
 *  republished on every change. The VPN exclusion is the
 *  point (verification iteration 1, finding 4): once
 *  Ember's own full-tunnel VPN is up it IS the platform's
 *  default network, and feeding it back as the "underlay"
 *  would have the backend resolve peer endpoints and key
 *  its address-family decisions through its own tunnel.
 *  The callback request asks for NOT_VPN networks only,
 *  the initial value is a scan with the same filter, and
 *  snapshotFor refuses a VPN transport as a last guard. */
private class EmberNetworkMonitor(context: Context) : NetworkMonitor {
    private val cm =
        context.getSystemService(ConnectivityManager::class.java)

    private val _networkState = MutableStateFlow<NetworkSnapshot?>(null)
    override val networkState: StateFlow<NetworkSnapshot?> =
        _networkState.asStateFlow()

    @Volatile
    private var current: Network? = null

    init {
        _networkState.value = scanForUnderlay()
        try {
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            cm?.registerNetworkCallback(
                request,
                object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        // Adopt a newly available network as
                        // the underlay only when it is the
                        // system's default (or nothing is
                        // tracked yet): on a Wi-Fi+cellular
                        // device the non-default network is
                        // not the path traffic takes
                        // (verification iteration 2, M4).
                        val active = try {
                            cm?.activeNetwork
                        } catch (e: Exception) {
                            null
                        }
                        if (current == null || network == active) {
                            current = network
                            _networkState.value = snapshotFor(network)
                        }
                    }

                    override fun onCapabilitiesChanged(
                        network: Network,
                        capabilities: NetworkCapabilities,
                    ) {
                        if (network == current) {
                            _networkState.value = snapshotFor(network)
                        }
                    }

                    override fun onLinkPropertiesChanged(
                        network: Network,
                        properties: LinkProperties,
                    ) {
                        if (network == current) {
                            _networkState.value = snapshotFor(network)
                        }
                    }

                    override fun onLost(network: Network) {
                        if (network == current) {
                            current = null
                            _networkState.value = scanForUnderlay()
                        }
                    }
                },
            )
        } catch (e: Exception) {
            Log.w("EmberNetworkMonitor", "callback not registered: $e")
        }
        // The default network's own changes (verification
        // iteration 3, M-1): the NOT_VPN callback above
        // cannot see the default move between two networks
        // that both stay up (Wi-Fi losing internet while
        // still associated; the system switching to mobile
        // data). A default change re-runs the underlay scan,
        // which prefers the new default — and its VPN filter
        // keeps Ember's own tunnel (itself a default while
        // up) from ever becoming the answer.
        try {
            cm?.registerDefaultNetworkCallback(
                object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        _networkState.value = scanForUnderlay()
                    }

                    override fun onLost(network: Network) {
                        _networkState.value = scanForUnderlay()
                    }
                },
            )
        } catch (e: Exception) {
            Log.w(
                "EmberNetworkMonitor",
                "default callback not registered: $e",
            )
        }
    }

    /** A non-VPN network with Internet capability, or null
     *  when none exists (e.g. the only path is the VPN).
     *  The system's default network is considered first
     *  (iteration 2, M4): the snapshot should describe the
     *  path traffic actually takes, not whichever network
     *  allNetworks happens to list first. */
    private fun scanForUnderlay(): NetworkSnapshot? {
        val manager = cm ?: return null
        val networks = try {
            manager.allNetworks.toList()
        } catch (e: Exception) {
            emptyList()
        }
        val active = try {
            manager.activeNetwork
        } catch (e: Exception) {
            null
        }
        val ordered = listOfNotNull(active) +
            networks.filter { it != active }
        val underlay = ordered.firstOrNull { network ->
            val caps = try {
                manager.getNetworkCapabilities(network)
            } catch (e: Exception) {
                null
            }
            caps != null &&
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                caps.hasCapability(
                    NetworkCapabilities.NET_CAPABILITY_INTERNET,
                )
        }
        if (underlay == null) {
            // No candidate: forget the tracked network too
            // (iteration 4, Low-1) — a stale `current` would
            // keep the NOT_VPN callback republishing for a
            // network the scan no longer believes in.
            current = null
            return null
        }
        current = underlay
        return snapshotFor(underlay)
    }

    private fun snapshotFor(network: Network?): NetworkSnapshot? {
        if (network == null || cm == null) return null
        val caps = try {
            cm.getNetworkCapabilities(network)
        } catch (e: Exception) {
            null
        }
        if (caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true) {
            return null
        }
        val props = try {
            cm.getLinkProperties(network)
        } catch (e: Exception) {
            null
        }
        // IPv6 support in upstream WG Tunnel's monitor
        // semantics (verification iteration 2, M4): a GLOBAL
        // address — not link-local, loopback, multicast,
        // site-local or unique-local, and not deprecated /
        // tentative / DAD-failed — AND an IPv6 default
        // route. A ULA-only or route-less network cannot
        // reach a public AAAA; reporting it as v6-capable
        // would send PreferIpv6 bootstraps at unreachable
        // endpoints. Null when nothing could be read, which
        // is not the same as "no IPv6".
        val hasIpv6 = props?.let { lp ->
            val hasGlobalIpv6 = lp.linkAddresses.any { la ->
                val addr = la.address
                addr is Inet6Address &&
                    !addr.isLinkLocalAddress &&
                    !addr.isLoopbackAddress &&
                    !addr.isMulticastAddress &&
                    !addr.isSiteLocalAddress &&
                    !isUniqueLocal(addr) &&
                    la.flags and UNUSABLE_ADDRESS_FLAGS == 0
            }
            val hasIpv6DefaultRoute = lp.routes.any { route ->
                route.isDefaultRoute && routeFamilyIsV6(route)
            }
            hasGlobalIpv6 && hasIpv6DefaultRoute
        }
        // Usable in upstream's sense: Internet, validated,
        // and not suspended (the suspension capability
        // exists from API 28; below it the check passes).
        val usable = caps != null &&
            caps.hasCapability(
                NetworkCapabilities.NET_CAPABILITY_INTERNET,
            ) &&
            caps.hasCapability(
                NetworkCapabilities.NET_CAPABILITY_VALIDATED,
            ) &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.P ||
                caps.hasCapability(
                    NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED,
                ))
        return NetworkSnapshot(
            key = network.toString(),
            hasIpv6 = hasIpv6,
            isUsable = usable,
            network = network,
        )
    }

    private fun isUniqueLocal(addr: Inet6Address): Boolean =
        (addr.address[0].toInt() and 0xfe) == 0xfc

    /** RouteInfo.getDestination exists from API 29; below
     *  it the gateway carries the family. A gateway-less
     *  default route (a directly connected ::/0) reads a
     *  null gateway — counted as v6 (iteration 3, L-6):
     *  the caller's other conjunct already requires a
     *  global v6 address on this network, so the default
     *  route being family-tested is the v6 one. */
    private fun routeFamilyIsV6(route: RouteInfo): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            route.destination.address is Inet6Address
        } else {
            route.gateway == null || route.gateway is Inet6Address
        }

    companion object {
        /** Upstream's unusable-address flags: deprecated,
         *  tentative and DAD-failed addresses do not make a
         *  network IPv6-capable. */
        private val UNUSABLE_ADDRESS_FLAGS =
            OsConstants.IFA_F_DEPRECATED or
                OsConstants.IFA_F_TENTATIVE or
                OsConstants.IFA_F_DADFAILED
    }
}

/** Ember's half of the backend's application contract: the
 *  persistent notification the companion foreground service
 *  carries while a tunnel runs, in the shape the old AWG
 *  service's notification had — same channel, same id (2),
 *  same text rule (the "V2Ray · <name>" line the AWG mode
 *  has always rendered), Disconnect and Switch-server
 *  actions included. Disconnect is a nonce-stamped activity
 *  intent: MainActivity performs the stop (the old service
 *  stop, funnelled through WgTunnelEngine.stop). */
private class EmberWgApplicationProvider(
    private val appContext: Context,
) : AndroidApplicationProvider {
    override val context: Context get() = appContext

    // The same notification id the AWG session has always
    // used (single-engine-at-a-time: it never coexists with
    // the Xray session's notification of the same id).
    override val vpnNotificationId: Int = 2

    // Proxy mode never starts in Ember; the id is unused.
    override val proxyNotificationId: Int = 3

    override val vpnInitNotification: Notification
        get() = buildNotification(null)

    override val proxyInitNotification: Notification
        get() = buildNotification(null)

    override fun createVpnConfigurePendingIntent(
        context: Context,
    ): PendingIntent = PendingIntent.getActivity(
        context,
        10,
        Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE,
    )

    override suspend fun buildVpnPersistentNotification(
        status: BackendStatus,
    ): Notification = buildNotification(status)

    override suspend fun buildProxyPersistentNotification(
        status: BackendStatus,
    ): Notification = buildNotification(status)

    /** The backend calls this when the tunnel status
     *  changes; Ember's Quick Settings tile is the status
     *  surface it feeds (verification iteration 1, finding
     *  21 — the tile exists and has always refreshed this
     *  way for the other engines). */
    override fun refreshStatusUi() {
        QuickTile.refresh(appContext)
    }

    private fun buildNotification(status: BackendStatus?): Notification {
        ensureChannel()
        val active = status?.activeTunnels?.get(WgTunnelEngine.TUNNEL_ID)
        val name = active?.tunnel?.name ?: ""
        // The text rule the AWG session's notification has
        // always used (build 2100's preserved quirk: the
        // engineLabel else-branch — "V2Ray").
        val text = if (name.isEmpty()) {
            appContext.getString(R.string.notification_connecting)
        } else {
            "V2Ray · $name"
        }
        val open = PendingIntent.getActivity(
            appContext,
            10,
            Intent(appContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getActivity(
            appContext,
            11,
            EmberIntentNonce.stamp(
                appContext,
                Intent(appContext, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    .putExtra("ember_action", "stop"),
            ),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val rotate = PendingIntent.getActivity(
            appContext,
            12,
            EmberIntentNonce.stamp(
                appContext,
                Intent(appContext, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    .putExtra("ember_action", "rotate"),
            ),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(appContext, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(appContext)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_logo)
            .setContentTitle(appContext.getString(R.string.app_name))
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(
                Notification.Action.Builder(
                    null,
                    appContext.getString(R.string.notification_stop),
                    stop,
                ).build(),
            )
            .addAction(
                Notification.Action.Builder(
                    null,
                    appContext.getString(R.string.notification_rotate),
                    rotate,
                ).build(),
            )
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager =
            appContext.getSystemService(NotificationManager::class.java)
        manager?.createNotificationChannel(
            NotificationChannel(
                CHANNEL,
                appContext.getString(R.string.notification_channel),
                NotificationManager.IMPORTANCE_LOW,
            ).apply { setShowBadge(false) },
        )
    }

    companion object {
        // The channel every engine's notification shares.
        private const val CHANNEL = "xray_status"
    }
}
