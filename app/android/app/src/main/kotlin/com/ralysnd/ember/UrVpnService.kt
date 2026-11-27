package com.ralysnd.ember

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.TrafficStats
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import com.bringyour.sdk.ConnectLocation
import com.bringyour.sdk.ConnectLocationId
import com.bringyour.sdk.ConnectedProviderLocationChangeListener
import com.bringyour.sdk.DeviceLocal
import com.bringyour.sdk.IoLoop
import com.bringyour.sdk.IoLoopDoneCallback
import com.bringyour.sdk.NetworkSpaceUpdate
import com.bringyour.sdk.Sdk
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

/**
 * The URnetwork engine host (build 2156).
 *
 * Drives the URnetwork SDK (com.bringyour.sdk, vendor AAR
 * v2026.11.22, MPL-2.0) in-process: the SDK's DeviceLocal
 * API — Ember's VpnService establishes the TUN and hands
 * the SDK a DUPLICATE of its fd through Sdk.newIoLoop,
 * which pumps packets inside the core (the hev lesson: a
 * core may close the fd it is handed; the original stays
 * ours — it is also the kill-switch hold).
 *
 * The vendor AAR is shaded so its gomobile runtime
 * coexists with Ember's other Go cores: classes go/ ->
 * ur/, libgojni.so -> liburcore.so, and the six shared
 * Java_go_* JNI exports renamed to Java_ur_* with rebuilt
 * hash tables (the build-2007 Psiphon fix, re-applied —
 * build2156-progress.md). The vendor's ConnectViewController
 * is NEVER used: its Connect() forces ProvideModePublic
 * (the phone would become an exit for strangers). The
 * provide mode is pinned to None on the device AND the
 * local state before any connect.
 *
 * The service runs in its OWN process (:urnetwork,
 * manifest), mirroring the :lantern / :psiphon precedent:
 * two gomobile Go runtimes in one process are unsupported,
 * and Mozilla's already lives in the main process. All
 * main-process interaction is intent- and file-based: the
 * service publishes a JSON state snapshot to
 * filesDir/urnetwork/urnetwork_state.json on every change,
 * and MainActivity's ur* channels read it through
 * [UrStateStore.publishedState].
 *
 * Auth: no login UI. The Dart side exchanges the owner's
 * URnetwork API key (build 2154, SecretStore vault) for a
 * client JWT at the auth-client endpoint and caches it in
 * the vault; the JWT arrives here as a start-intent extra
 * and is held in memory only — never written to disk,
 * never logged. The service journal (service.log) carries
 * lifecycle lines: stages and location names only.
 */
object UrStateStore {
    const val STATE_FILE = "urnetwork_state.json"

    /** A live-claiming snapshot older than this reads as
     *  stopped — the :urnetwork process is gone. */
    const val STALE_SNAPSHOT_MS = 120_000L

    private const val REPUBLISH_MS = 30_000L

    fun workDir(context: Context): File = File(context.filesDir, "urnetwork")

    @Volatile
    var running = false
        internal set(value) {
            field = value
            publish()
        }

    /** The SDK device's own connected verdict (its
     *  connected-provider list is non-empty), polled by
     *  the service — never a local guess. */
    @Volatile
    var connected = false
        internal set(value) {
            field = value
            publish()
        }

    @Volatile
    var killSwitchHeld = false
        internal set(value) {
            field = value
            publish()
        }

    /** idle | starting | up | error */
    @Volatile
    var stage: String = "idle"
        internal set(value) {
            field = value
            publish()
        }

    @Volatile
    var exitCity: String = ""
        internal set(value) {
            field = value
            publish()
        }

    @Volatile
    var exitCountry: String = ""
        internal set(value) {
            field = value
            publish()
        }

    @Volatile
    var exitCode: String = ""
        internal set(value) {
            field = value
            publish()
        }

    @Volatile
    var exitRegion: String = ""
        internal set(value) {
            field = value
            publish()
        }

    /** Providers in the device's connected window. */
    @Volatile
    var providers: Int = 0
        internal set(value) {
            field = value
            publish()
        }

    /** The location this session was asked for ("" name =
     *  Best Available), echoed for display. */
    @Volatile
    var reqName: String = ""
        internal set(value) {
            field = value
            publish()
        }

    @Volatile
    var reqCode: String = ""
        internal set(value) {
            field = value
            publish()
        }

    @Volatile
    var startedAtMs: Long = 0L
        internal set(value) {
            field = value
            publish()
        }

    @Volatile
    var serviceError: String? = null
        internal set(value) {
            field = value
            publish()
        }

    @Volatile
    private var baseTx = -1L

    @Volatile
    private var baseRx = -1L

    fun markTrafficBase() {
        val uid = android.os.Process.myUid()
        baseTx = TrafficStats.getUidTxBytes(uid)
        baseRx = TrafficStats.getUidRxBytes(uid)
    }

    /** Session traffic of this app's UID since the tunnel
     *  started (approximate) — the Lantern accounting,
     *  unchanged. */
    fun sessionTraffic(): Pair<Long, Long> {
        if (!running) return 0L to 0L
        val uid = android.os.Process.myUid()
        val tx = TrafficStats.getUidTxBytes(uid)
        val rx = TrafficStats.getUidRxBytes(uid)
        val up = if (tx < 0 || baseTx < 0) 0 else (tx - baseTx).coerceAtLeast(0)
        val down = if (rx < 0 || baseRx < 0) 0 else (rx - baseRx).coerceAtLeast(0)
        return up to down
    }

    // -- publishing (service process side) --

    @Volatile
    private var appContext: Context? = null

    private val publishLock = Any()

    private val republishHandler =
        android.os.Handler(android.os.Looper.getMainLooper())

    @Volatile
    private var republishArmed = false

    private val republishRunnable = object : Runnable {
        override fun run() {
            if (!running) {
                republishArmed = false
                return
            }
            publish()
            republishHandler.postDelayed(this, REPUBLISH_MS)
        }
    }

    fun bindAppContext(context: Context) {
        appContext = context.applicationContext ?: context
    }

    private fun armRepublish() {
        if (republishArmed) return
        republishArmed = true
        republishHandler.postDelayed(republishRunnable, REPUBLISH_MS)
    }

    private fun publish() {
        try {
            val context = appContext ?: return
            synchronized(publishLock) {
                val traffic = sessionTraffic()
                val json = JSONObject()
                    .put("running", running)
                    .put("connected", connected)
                    .put("killSwitchHeld", killSwitchHeld)
                    .put("stage", stage)
                    .put("exitCity", exitCity)
                    .put("exitCountry", exitCountry)
                    .put("exitCode", exitCode)
                    .put("exitRegion", exitRegion)
                    .put("providers", providers)
                    .put("reqName", reqName)
                    .put("reqCode", reqCode)
                    .put("sinceMs", startedAtMs)
                    .put("up", traffic.first)
                    .put("down", traffic.second)
                    .apply {
                        serviceError?.let { put("error", it) }
                    }
                    .put("publishedAtMs", System.currentTimeMillis())
                AtomicFile.writeText(
                    File(workDir(context), STATE_FILE),
                    json.toString(),
                )
            }
            if (running) armRepublish()
        } catch (_: Throwable) {
            // Best-effort: state publishing is evidence
            // plumbing, never behaviour.
        }
    }

    /** Forces a snapshot now (traffic counters move without
     *  a state change to trigger one). */
    fun republish() = publish()

    // -- reading (any process) --

    /**
     * The main process's view of the state above — the
     * published snapshot, in the map shape MainActivity's
     * urState channel returns. A missing, unreadable or
     * stale snapshot reads as the stopped defaults.
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

    internal fun parsePublishedState(
        text: String?,
        nowMs: Long = System.currentTimeMillis(),
    ): Map<String, Any?> {
        val defaults: Map<String, Any?> = mapOf(
            "running" to false,
            "connected" to false,
            "killSwitchHeld" to false,
            "stage" to "idle",
            "exitCity" to "",
            "exitCountry" to "",
            "exitCode" to "",
            "exitRegion" to "",
            "providers" to 0,
            "reqName" to "",
            "reqCode" to "",
            "sinceMs" to 0L,
            "up" to 0L,
            "down" to 0L,
            "error" to null,
        )
        if (text == null) return defaults
        return try {
            val json = JSONObject(text)
            val claimsLive = json.optBoolean("running", false) ||
                json.optBoolean("connected", false)
            val publishedAtMs = json.optLong("publishedAtMs", 0L)
            if (claimsLive && nowMs - publishedAtMs > STALE_SNAPSHOT_MS) {
                return defaults
            }
            mapOf(
                "running" to json.optBoolean("running", false),
                "connected" to json.optBoolean("connected", false),
                "killSwitchHeld" to json.optBoolean("killSwitchHeld", false),
                "stage" to json.optString("stage", "idle"),
                "exitCity" to json.optString("exitCity", ""),
                "exitCountry" to json.optString("exitCountry", ""),
                "exitCode" to json.optString("exitCode", ""),
                "exitRegion" to json.optString("exitRegion", ""),
                "providers" to json.optInt("providers", 0),
                "reqName" to json.optString("reqName", ""),
                "reqCode" to json.optString("reqCode", ""),
                "sinceMs" to json.optLong("sinceMs", 0L),
                "up" to json.optLong("up", 0L),
                "down" to json.optLong("down", 0L),
                "error" to json.optString("error", "").ifEmpty { null },
            )
        } catch (_: Throwable) {
            defaults
        }
    }
}

/** The service's own journal: lifecycle lines (stages and
 *  location names only — never a credential) at
 *  filesDir/urnetwork/service.log, read by the engine's
 *  log page. Appends are best-effort and capped. */
object UrJournal {
    private const val FILE_NAME = "service.log"
    private const val MAX_BYTES = 256 * 1024

    private val lock = Any()
    private val format = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)

    fun log(context: Context, line: String) {
        try {
            synchronized(lock) {
                val dir = UrStateStore.workDir(context)
                dir.mkdirs()
                val file = File(dir, FILE_NAME)
                if (file.exists() && file.length() > MAX_BYTES) {
                    file.writeText("")
                }
                file.appendText("${format.format(Date())} $line\n")
            }
        } catch (_: Throwable) {
            // The journal is evidence plumbing, never behaviour.
        }
    }
}

class UrVpnService : VpnService() {

    private val worker = Executors.newSingleThreadExecutor()
    private val stopping = AtomicBoolean(false)

    /** The underlying-network watch, as in the other
     *  engines — the SDK re-dials per connection once the
     *  TUN points at a live network. */
    private val underlyingWatch =
        UnderlyingNetworkWatch(this, "UrVpnService") {
            CrashLog.breadcrumb(this, "urnetwork:underlying-network-changed")
        }

    /** Our half of the TUN: the io loop pumps a DUPLICATE;
     *  this original stays open for the session's life —
     *  and past an unexpected death when the kill switch
     *  holds it as a blackhole. */
    private var tunPfd: ParcelFileDescriptor? = null

    @Volatile
    private var device: DeviceLocal? = null

    @Volatile
    private var ioLoop: IoLoop? = null

    /** Kept reachable for the session's life: the SDK calls
     *  back into it when the connected window changes. */
    @Volatile
    private var locationsListener: ConnectedProviderLocationChangeListener? = null

    @Volatile
    private var inKillSwitch = false

    override fun onCreate() {
        super.onCreate()
        UrStateStore.bindAppContext(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // The start net, same shape as the other engines' —
        // a Throwable escaping the guarded body is recorded
        // in crash.log and the service stops gracefully.
        return try {
            onStartCommandGuarded(intent)
        } catch (e: Throwable) {
            CrashLog.append(this, "UrVpnService.onStartCommand", e)
            stopSelf()
            START_NOT_STICKY
        }
    }

    private fun onStartCommandGuarded(intent: Intent?): Int {
        underlyingWatch.start()
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel()
                EngineClaim.release(this, EngineClaim.URNETWORK)
                return START_NOT_STICKY
            }
            ACTION_START -> {
                EngineClaim.claim(this, EngineClaim.URNETWORK)
                startInForeground()
                if (UrStateStore.running) return START_STICKY
                stopping.set(false)
                val jwt = intent.getStringExtra(EXTRA_JWT) ?: ""
                val locationId = intent.getStringExtra(EXTRA_LOCATION_ID) ?: ""
                val locationName = intent.getStringExtra(EXTRA_LOCATION_NAME) ?: ""
                val locationCode = intent.getStringExtra(EXTRA_LOCATION_CODE) ?: ""
                val mtu = clampMtu(intent.getIntExtra(EXTRA_MTU, MTU))
                inKillSwitch = intent.getBooleanExtra(EXTRA_KILL_SWITCH, false)
                // A fresh start over a kill-switch hold:
                // close the held TUN and clear the hold
                // before this start establishes its own.
                if (UrStateStore.killSwitchHeld) {
                    UrStateStore.killSwitchHeld = false
                    closeTun()
                }
                if (jwt.isEmpty()) {
                    UrStateStore.serviceError =
                        "No device session was handed to the engine."
                    UrJournal.log(this, "start refused: no session")
                    fail()
                    return START_NOT_STICKY
                }
                worker.execute {
                    try {
                        startTunnel(jwt, locationId, locationName, locationCode, mtu)
                    } catch (e: Throwable) {
                        CrashLog.append(this, "UrVpnService.startTunnel", e)
                        Log.e(TAG, "the URnetwork tunnel did not start", e)
                        if (UrStateStore.serviceError == null) {
                            UrStateStore.serviceError =
                                e.message ?: e.toString()
                        }
                        UrJournal.log(
                            this,
                            "start failed: ${e.message ?: e.toString()}",
                        )
                        fail()
                    }
                }
                return START_STICKY
            }
        }
        return START_NOT_STICKY
    }

    private fun startTunnel(
        jwt: String,
        locationId: String,
        locationName: String,
        locationCode: String,
        mtu: Int,
    ) {
        UrStateStore.serviceError = null
        UrStateStore.stage = "starting"
        UrStateStore.reqName = locationName
        UrStateStore.reqCode = locationCode
        UrJournal.log(
            this,
            "start: ${if (locationId.isEmpty()) "best available" else locationName}",
        )

        // The production network space ("ur.network"/"main";
        // the migration host is what makes its API URLs
        // resolve — the getting-started contract).
        val storageDir = UrStateStore.workDir(this)
        storageDir.mkdirs()
        val manager = Sdk.newNetworkSpaceManager(storageDir.absolutePath)
        val key = Sdk.newNetworkSpaceKey("ur.network", "main")
        val space = manager.updateNetworkSpace(
            key,
            NetworkSpaceUpdate { values ->
                values.migrationHostName = "bringyour.com"
            },
        ) ?: throw IllegalStateException("The network space did not open.")
        space.api.setByJwt(jwt)

        // PROVIDING OFF — the hard pin (class doc): the
        // local state's persisted mode AND the device's
        // live mode, before any connect. The vendor view
        // controllers are never instantiated.
        val localState = space.asyncLocalState.localState
        runCatching { localState.setProvideMode(Sdk.ProvideModeNone) }

        // The device instance id: minted once for the
        // install and reused — a fresh id every launch
        // would add a phantom device entry each time.
        val instanceId = loadOrMintInstanceId()

        val appVersion = try {
            packageManager.getPackageInfo(packageName, 0).versionName ?: ""
        } catch (_: Throwable) {
            ""
        }
        val dev = DeviceLocal(
            space,
            jwt,
            "Ralysnd Ember (Android)",
            "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
            appVersion,
            instanceId,
            false,
        )
        device = dev
        dev.setProvideMode(Sdk.ProvideModeNone)
        // The kill switch: with it on, traffic must stop
        // rather than fall back to local routes.
        dev.setRouteLocal(!inKillSwitch)

        // The connect location: Best Available, or the
        // picked country (the provider-locations row the
        // Dart side chose).
        val location = if (locationId.isEmpty()) {
            val id = ConnectLocationId()
            id.bestAvailable = true
            val loc = ConnectLocation()
            loc.connectLocationId = id
            loc
        } else {
            val loc = ConnectLocation()
            loc.countryLocationId = Sdk.parseId(locationId)
            loc.countryCode = locationCode
            loc.country = locationName
            loc.name = locationName
            loc
        }
        dev.setConnectLocation(location)

        // DNS comes from the device object (its tunnel DNS
        // addresses) into the Builder; dual-stack follows
        // what the device dictates — a v6 address + route
        // only when the device returns v6 DNS.
        val dnsV4 = readStringList { dev.tunnelDnsAddressesIpv4() }
        val dnsV6 = readStringList { dev.tunnelDnsAddressesIpv6() }
        if (dnsV4.isEmpty()) {
            UrJournal.log(this, "device returned no IPv4 DNS; using 1.1.1.1")
        }
        if (!establishTun(dnsV4, dnsV6, mtu)) return

        // Hand the SDK a DUPLICATE of the TUN fd: the io
        // loop takes ownership of the detached duplicate;
        // the original stays ours (kill-switch hold).
        val pfd = tunPfd ?: throw IllegalStateException("The TUN did not establish.")
        val dup = pfd.dup()
        val ioFd = dup.detachFd()
        ioLoop = Sdk.newIoLoop(dev, ioFd, IoLoopDoneCallback {
            // The packet pump ended. An end we did not ask
            // for, mid-session, is a death.
            if (!stopping.get() && UrStateStore.running) {
                onSessionDied("the packet pump stopped")
            }
        })

        val listener = ConnectedProviderLocationChangeListener {
            refreshExit()
        }
        locationsListener = listener
        runCatching { dev.addConnectedProviderLocationChangeListener(listener) }

        UrStateStore.running = true
        UrStateStore.startedAtMs = System.currentTimeMillis()
        UrStateStore.markTrafficBase()
        UrJournal.log(this, "tunnel up; waiting for a provider")
        updateNotification()
        watchStatus()
    }

    private fun readStringList(block: () -> com.bringyour.sdk.StringList): List<String> {
        return try {
            val list = block()
            val out = ArrayList<String>()
            var i = 0L
            while (i < list.len()) {
                val value = list.get(i)
                if (!value.isNullOrEmpty()) out.add(value)
                i++
            }
            out
        } catch (_: Throwable) {
            emptyList()
        }
    }

    /** Builds and establishes the session's TUN (the
     *  XrayVpnService shape). Any previous TUN — the kill
     *  switch's held blackhole — is closed only after the
     *  new one is up. On failure the start fails via
     *  fail(), which holds the new TUN as the blackhole
     *  when the kill switch is on. */
    private fun establishTun(dnsV4: List<String>, dnsV6: List<String>, mtu: Int): Boolean {
        if (prepare(this) != null) {
            Log.w(TAG, "the VPN has no permission")
            UrStateStore.serviceError = "The VPN permission was not granted."
            fail()
            return false
        }
        val builder = Builder()
            .setSession(getString(R.string.app_name))
            .setMtu(mtu)
            .addAddress("10.10.14.1", 30)
            .addRoute("0.0.0.0", 0)
        for (dns in dnsV4) builder.addDnsServer(dns)
        if (dnsV4.isEmpty()) builder.addDnsServer("1.1.1.1")
        if (dnsV6.isNotEmpty()) {
            builder.addAddress("fdfe:dcba:9876::1", 126)
            builder.addRoute("::", 0)
            for (dns in dnsV6) builder.addDnsServer(dns)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }
        val heldPfd = tunPfd
        val pfd = builder.establish()
        if (pfd == null) {
            Log.e(TAG, "establish() returned null")
            UrStateStore.serviceError = "The tunnel could not be established."
            fail()
            return false
        }
        tunPfd = pfd
        if (heldPfd != null) {
            try {
                heldPfd.close()
            } catch (e: Exception) {
                // Already closed.
            }
        }
        return true
    }

    /** The device instance id, persisted in the engine's
     *  work dir (an id string — not a credential). */
    private fun loadOrMintInstanceId(): com.bringyour.sdk.Id {
        val file = File(UrStateStore.workDir(this), "instance_id.txt")
        try {
            if (file.isFile) {
                val text = file.readText().trim()
                if (text.isNotEmpty()) return Sdk.parseId(text)
            }
        } catch (_: Throwable) {
            // Mint below.
        }
        val id = Sdk.newId()
        try {
            AtomicFile.writeText(file, id.string())
        } catch (_: Throwable) {
            // A lost write only means the next start mints
            // again — never a start failure.
        }
        return id
    }

    /**
     * Polls the device's connected-provider list: the
     * connected verdict and the exit identity come only
     * from it. A session that was connected and stops
     * reporting providers, while no stop was requested, is
     * a death: the kill switch decides hold vs teardown.
     */
    private fun watchStatus() {
        worker.execute {
            var wasConnected = false
            var missedPolls = 0
            while (!stopping.get() && UrStateStore.running) {
                val providers = runCatching { device?.connectedProviderLocations }
                val count = try {
                    providers.getOrNull()?.len()?.toInt() ?: 0
                } catch (_: Throwable) {
                    0
                }
                if (count > 0) {
                    missedPolls = 0
                    if (!wasConnected) {
                        wasConnected = true
                        UrStateStore.connected = true
                        UrStateStore.stage = "up"
                        UrJournal.log(this, "connected")
                        updateNotification()
                    }
                    refreshExit()
                } else if (wasConnected) {
                    missedPolls++
                    if (missedPolls >= 2) {
                        onSessionDied("the device stopped reporting providers")
                        return@execute
                    }
                }
                UrStateStore.republish()
                try {
                    Thread.sleep(STATUS_POLL_MS)
                } catch (e: InterruptedException) {
                    return@execute
                }
            }
        }
    }

    /** The exit identity, from the device's first connected
     *  provider location. An unreadable or empty readback
     *  leaves the previous identity in place. */
    private fun refreshExit() {
        val dev = device ?: return
        try {
            val list = dev.connectedProviderLocations
            val count = list.len().toInt()
            UrStateStore.providers = count
            if (count <= 0) return
            val first = list.get(0)
            val city = first.city ?: ""
            val country = first.country ?: ""
            val code = first.countryCode ?: ""
            val region = first.region ?: ""
            if (city.isNotEmpty()) UrStateStore.exitCity = city
            if (country.isNotEmpty()) UrStateStore.exitCountry = country
            if (code.isNotEmpty()) UrStateStore.exitCode = code
            if (region.isNotEmpty()) UrStateStore.exitRegion = region
            UrStateStore.republish()
        } catch (_: Throwable) {
            // The readback is display only.
        }
    }

    private fun fail() {
        closeCore()
        if (inKillSwitch && tunPfd != null) {
            // The kill switch holds the failed TUN as a
            // blackhole until the user disconnects or a
            // fresh start replaces it.
            UrStateStore.killSwitchHeld = true
        } else {
            closeTun()
        }
        UrStateStore.running = false
        UrStateStore.connected = false
        UrStateStore.stage = "error"
        UrStateStore.republish()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * An unexpected mid-session death. With the kill switch
     * on, the TUN stays established and unread (traffic
     * blackholes) and the service stays in the foreground
     * saying so, until the user disconnects or a fresh
     * start replaces it. Otherwise the ordinary teardown.
     * (If the :urnetwork process itself dies, no hold is
     * possible — the TUN closes with the process; that is
     * the gomobile shape's limit, as with Lantern.)
     */
    private fun onSessionDied(reason: String) {
        if (inKillSwitch && tunPfd != null) {
            stopping.set(true)
            CrashLog.breadcrumb(this, "urnetwork:kill-switch-hold ($reason)")
            UrJournal.log(this, "session died; kill switch holding ($reason)")
            closeCore()
            UrStateStore.killSwitchHeld = true
            UrStateStore.running = false
            UrStateStore.connected = false
            UrStateStore.republish()
            updateNotification()
        } else {
            UrJournal.log(this, "session died ($reason)")
            stopTunnel()
        }
    }

    /** Closes the SDK side: the io loop first, then the
     *  device (the binding's close is the CloseAndWait
     *  equivalent the Java API exposes). */
    private fun closeCore() {
        runCatching { ioLoop?.close() }
        ioLoop = null
        locationsListener = null
        runCatching { device?.close() }
        device = null
    }

    private fun closeTun() {
        try {
            tunPfd?.close()
        } catch (e: Exception) {
            // Already closed.
        }
        tunPfd = null
    }

    private fun stopTunnel() {
        stopping.set(true)
        UrStateStore.killSwitchHeld = false
        closeCore()
        closeTun()
        UrStateStore.running = false
        UrStateStore.connected = false
        UrStateStore.stage = "idle"
        UrStateStore.exitCity = ""
        UrStateStore.exitCountry = ""
        UrStateStore.exitCode = ""
        UrStateStore.exitRegion = ""
        UrStateStore.providers = 0
        UrStateStore.republish()
        UrJournal.log(this, "stopped")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onRevoke() {
        stopTunnel()
        super.onRevoke()
    }

    override fun onDestroy() {
        underlyingWatch.stop()
        EngineClaim.release(this, EngineClaim.URNETWORK)
        stopping.set(true)
        closeCore()
        closeTun()
        UrStateStore.running = false
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
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, notification())
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(
            this, 60, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 61, Intent(this, UrVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val exit = when {
            UrStateStore.exitCity.isNotEmpty() && UrStateStore.exitCountry.isNotEmpty() ->
                "${UrStateStore.exitCity}, ${UrStateStore.exitCountry}"
            UrStateStore.exitCountry.isNotEmpty() -> UrStateStore.exitCountry
            else -> ""
        }
        val text = when {
            UrStateStore.killSwitchHeld ->
                "URnetwork · kill switch holding — traffic is blocked"
            UrStateStore.connected && exit.isNotEmpty() -> "URnetwork · $exit"
            UrStateStore.connected -> "URnetwork"
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
        const val ACTION_START = "com.ralysnd.ember.URNETWORK_START"
        const val ACTION_STOP = "com.ralysnd.ember.URNETWORK_STOP"
        private const val EXTRA_JWT = "jwt"
        private const val EXTRA_LOCATION_ID = "locationId"
        private const val EXTRA_LOCATION_NAME = "locationName"
        private const val EXTRA_LOCATION_CODE = "locationCode"
        private const val EXTRA_MTU = "mtu"
        private const val EXTRA_KILL_SWITCH = "killSwitch"

        private const val CHANNEL = "urnetwork_status"
        private const val NOTIFICATION_ID = 6
        private const val TAG = "UrVpnService"
        private const val MTU = 1500
        private const val STATUS_POLL_MS = 3_500L

        /** Clamps a tunnel MTU to the offered range: 1280
         *  floor, 1500 ceiling. */
        private fun clampMtu(mtu: Int) = mtu.coerceIn(1280, 1500)

        fun start(
            context: Context,
            jwt: String,
            locationId: String = "",
            locationName: String = "",
            locationCode: String = "",
            mtu: Int = 1500,
            killSwitch: Boolean = false,
        ) {
            val intent = Intent(context, UrVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_JWT, jwt)
                putExtra(EXTRA_LOCATION_ID, locationId)
                putExtra(EXTRA_LOCATION_NAME, locationName)
                putExtra(EXTRA_LOCATION_CODE, locationCode)
                putExtra(EXTRA_MTU, clampMtu(mtu))
                putExtra(EXTRA_KILL_SWITCH, killSwitch)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, UrVpnService::class.java).apply { action = ACTION_STOP },
            )
        }
    }
}
