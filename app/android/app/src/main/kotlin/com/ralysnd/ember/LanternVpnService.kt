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
import dalvik.system.DexClassLoader
import java.io.File
import java.io.FileOutputStream
import java.lang.reflect.InvocationTargetException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

/**
 * The Lantern engine host (build 2129 — the gomobile swap).
 *
 * Up to 2128 this service drove the radiance CLI daemon
 * (liblantern.so) as a subprocess behind a TUN bridge helper.
 * That binary's integration surface is flags and stdout only:
 * no server selection, no private-server API — the two things
 * the owner ordered. The CLI daemon is gone. In its place the
 * service drives the OFFICIAL Lantern client's gomobile
 * library (liblantern_gojni.so — the official v10.0.5-beta.1
 * APK's libgojni.so, byte-identical, renamed; trust gate in
 * build2129-phase0.md) in-process, through the official Java
 * bindings (lantern.io.mobile.Mobile) and Ember's own libbox
 * PlatformInterface bridge (LanternEngine, in
 * android/lantern-plugin-src).
 *
 * Packaging: the bindings and the bridge ship as dex assets
 * (lantern-plugin.dex / lantern-bridge.dex), copied to
 * app-private read-only storage and loaded with a child-first
 * DexClassLoader — a compile-time AAR would collide with the
 * Mozilla core.aar's go.* classes in the main dex (the LML
 * plugin-dex pattern, REPORT §4.1).
 *
 * The service runs in its OWN process (:lantern, manifest),
 * mirroring the :psiphon precedent (build 2073): two gomobile
 * Go runtimes in one process are unsupported, and Mozilla's
 * already lives in the main process. All main-process
 * interaction is intent- and file-based: the service publishes
 * a JSON state snapshot to filesDir/lantern/lantern_state.json
 * on every change (the Psiphon published-state pattern), and
 * MainActivity's lantern* channels read it through
 * [LanternStateStore.publishedState].
 *
 * Dropped with the CLI shape (build 2129 leg report): the
 * subprocess half, the settings-file smart-routing write
 * (the real API now forces smart routing off at bridge
 * init), the warm/cold ladder, the SOCKS data-plane gate,
 * the fd handoff for Lantern, and the WARP-leg
 * control-plane bootstrap with its list channels. Kept:
 * TrafficStats UID-delta traffic accounting, the kill-switch
 * hold (the bridge creates the TUN in openTun, so the service
 * holds a duplicate of its fd — see holdKillSwitch), and the
 * diagnostics log access (the core's logDir files under
 * filesDir/lantern/logs).
 */
object LanternStateStore {
    const val STATE_FILE = "lantern_state.json"

    /** Build 2116 (B10-1) pattern, Psiphon shape: a
     *  live-claiming snapshot older than this reads as
     *  stopped — the :lantern process is gone. */
    const val STALE_SNAPSHOT_MS = 120_000L

    private const val REPUBLISH_MS = 30_000L

    fun workDir(context: Context): File = File(context.filesDir, "lantern")

    fun logDir(context: Context): File = File(workDir(context), "logs")

    @Volatile
    var running = false
        internal set(value) {
            field = value
            publish()
        }

    /** The core's own connected verdict (Mobile.isVPNConnected
     *  polled by the service) — never a local guess. */
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

    /** The selected server's tag, from the core's
     *  getSelectedServerJSON — "" while none. */
    @Volatile
    var selectedTag: String = ""
        internal set(value) {
            field = value
            publish()
        }

    /** Servers in the core's current list; -1 until the
     *  first list lands. */
    @Volatile
    var servers: Int = -1
        internal set(value) {
            field = value
            publish()
        }

    /** The core's list, verbatim JSON (the bridge's filtered
     *  [{tag, city, country, countryCode}] array). */
    @Volatile
    var serversJson: String = "[]"
        internal set(value) {
            field = value
            publish()
        }

    @Volatile
    var smartRouting: Boolean = false
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

    /** The last private-server registration outcome:
     *  "" | "ok|<tag>" | "error|<words>". */
    @Volatile
    var privateResult: String = ""
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
     *  started (approximate) — the pre-2129 accounting,
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
                    .put("selectedTag", selectedTag)
                    .put("servers", servers)
                    .put("serversJson", serversJson)
                    .put("smartRouting", smartRouting)
                    .put("sinceMs", startedAtMs)
                    .put("up", traffic.first)
                    .put("down", traffic.second)
                    .apply {
                        serviceError?.let { put("error", it) }
                    }
                    .put("privateResult", privateResult)
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
     * lanternState channel returns. A missing, unreadable or
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
            "selectedTag" to "",
            "servers" to -1,
            "serversJson" to "[]",
            "smartRouting" to false,
            "sinceMs" to 0L,
            "up" to 0L,
            "down" to 0L,
            "error" to null,
            "privateResult" to "",
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
                "selectedTag" to json.optString("selectedTag", ""),
                "servers" to json.optInt("servers", -1),
                "serversJson" to json.optString("serversJson", "[]"),
                "smartRouting" to json.optBoolean("smartRouting", false),
                "sinceMs" to json.optLong("sinceMs", 0L),
                "up" to json.optLong("up", 0L),
                "down" to json.optLong("down", 0L),
                "error" to json.optString("error", "").ifEmpty { null },
                "privateResult" to json.optString("privateResult", ""),
            )
        } catch (_: Throwable) {
            defaults
        }
    }
}

/**
 * The reflective handle on the plugin dex's LanternEngine —
 * the main app has no compile-time dependency on Lantern
 * code (the LML shape). All calls run on the service's
 * worker; gomobile calls can block on the network.
 */
private class LanternBridge(private val service: VpnService) {
    private var engine: Any? = null

    private fun classLoader(): ClassLoader = sharedClassLoader(service)

    private companion object {
        /** Build 2130: the plugin classloader is a PROCESS-WIDE
         *  SINGLETON, created exactly once per process and
         *  shared by every LanternBridge. Build 2129 cached it
         *  per bridge instance — but the :lantern process
         *  outlives service instances (the info / smart /
         *  private actions stopSelf() when no session runs),
         *  so a second bridge built a SECOND DexClassLoader
         *  over the same dexes, and Android allows a native
         *  library to be loaded by only ONE classloader per
         *  process: go.Seq's loadLibrary then threw
         *  UnsatisfiedLinkError ("already opened by
         *  ClassLoader…") for every later Lantern operation
         *  in that process — Lantern was dead until the
         *  process itself died. The ENGINE deliberately stays
         *  per-bridge: LanternEngine captures its VpnService
         *  and builds the TUN through it in openTun, so each
         *  bridge's engine must belong to its own live
         *  service; loaded through this one loader, the
         *  engine class (and go.Seq) initializes exactly
         *  once no matter how many bridges come and go. The
         *  loader retains no service reference — the
         *  DexClassLoader's parent is the app classloader. */
        @Volatile
        private var sharedLoader: ClassLoader? = null

        @Synchronized
        private fun sharedClassLoader(service: VpnService): ClassLoader {
            sharedLoader?.let { return it }
            val dir = service.getDir("lantern-code", Context.MODE_PRIVATE)
            val paths = mutableListOf<String>()
            for (asset in listOf("lantern-plugin.dex", "lantern-bridge.dex")) {
                val target = File(dir, asset)
                installDex(service, asset, target)
                paths += target.absolutePath
            }
            val created = ChildLoader(
                paths.joinToString(":"),
                service.getDir("lantern-opt", Context.MODE_PRIVATE).absolutePath,
                service.applicationInfo.nativeLibraryDir,
                service.classLoader,
            )
            sharedLoader = created
            return created
        }

        /** Copies one dex asset to app-private read-only storage
         *  (LML's install discipline): tmp file, sync, rename,
         *  read-only. A byte-identical existing copy is kept. */
        private fun installDex(service: VpnService, asset: String, target: File) {
            val bytes = service.assets.open(asset).use { it.readBytes() }
            if (target.isFile && target.readBytes().contentEquals(bytes)) return
            val tmp = File(target.parentFile, "$asset.tmp")
            if (tmp.exists()) tmp.delete()
            FileOutputStream(tmp).use { output ->
                output.write(bytes)
                output.fd.sync()
            }
            if (target.exists()) target.delete()
            check(tmp.renameTo(target)) { "Cannot install Lantern code" }
            if (target.canWrite()) target.setReadOnly()
        }
    }

    private fun invoke(name: String, types: Array<Class<*>>, vararg args: Any?): Any? {
        val target = engine ?: throw IllegalStateException("Lantern is not initialized")
        try {
            return target.javaClass.getMethod(name, *types).invoke(target, *args)
        } catch (e: InvocationTargetException) {
            val cause = e.cause
            if (cause is Exception) throw cause
            throw IllegalStateException("Lantern native operation failed", cause)
        }
    }

    /** Loads the bridge class and runs its initialize()
     *  (idempotent inside the bridge). */
    @Synchronized
    fun initialize() {
        if (engine == null) {
            val cls = classLoader().loadClass(
                "com.ralysnd.ember.lanternplugin.LanternEngine",
            )
            engine = cls.getConstructor(VpnService::class.java)
                .newInstance(service)
        }
        invoke("initialize", emptyArray())
    }

    fun setSession(ipv6: Boolean, mtu: Int, dns: String) {
        invoke(
            "setSession",
            arrayOf(Boolean::class.java, Int::class.java, String::class.java),
            ipv6, mtu, dns,
        )
    }

    fun servers(): String =
        invoke("servers", emptyArray()) as? String ?: "[]"

    fun connect(tag: String) {
        invoke("connect", arrayOf(String::class.java), tag)
    }

    fun connected(): Boolean =
        invoke("connected", emptyArray()) as? Boolean ?: false

    fun selectedServer(): String =
        invoke("selectedServer", emptyArray()) as? String ?: ""

    fun smartRouting(): Boolean =
        invoke("smartRouting", emptyArray()) as? Boolean ?: false

    fun setSmartRouting(on: Boolean) {
        invoke("setSmartRouting", arrayOf(Boolean::class.java), on)
    }

    fun addPrivateServer(ip: String, port: String, token: String, tag: String) {
        invoke(
            "addPrivateServer",
            arrayOf(
                String::class.java, String::class.java,
                String::class.java, String::class.java,
            ),
            ip, port, token, tag,
        )
    }

    fun deletePrivateServer(tag: String) {
        invoke("deletePrivateServer", arrayOf(String::class.java), tag)
    }

    fun privateServerEvent(): String =
        invoke("privateServerEvent", emptyArray()) as? String ?: ""

    fun dupTunFd(): ParcelFileDescriptor? =
        invoke("dupTunFd", emptyArray()) as? ParcelFileDescriptor

    @Synchronized
    fun close() {
        val current = engine
        engine = null
        if (current != null) {
            try {
                current.javaClass.getMethod("close").invoke(current)
            } catch (_: Throwable) {
                // Closing is best-effort; the process is the
                // core's container either way.
            }
        }
    }

    /** Child-first for the plugin's own packages, so the
     *  bindings' go.* never resolves to the main dex's
     *  Mozilla copies (LML's ChildLoader, verbatim shape). */
    private class ChildLoader(
        dexPath: String,
        optimizedDirectory: String,
        librarySearchPath: String?,
        parent: ClassLoader,
    ) : DexClassLoader(dexPath, optimizedDirectory, librarySearchPath, parent) {
        override fun loadClass(name: String, resolve: Boolean): Class<*> {
            if (name.startsWith("go.") || name.startsWith("lantern.io.") ||
                name.startsWith("com.ralysnd.ember.lanternplugin.")
            ) {
                findLoadedClass(name)?.let {
                    if (resolve) resolveClass(it)
                    return it
                }
                try {
                    val found = findClass(name)
                    if (resolve) resolveClass(found)
                    return found
                } catch (_: ClassNotFoundException) {
                    // Fall through to the parent.
                }
            }
            return super.loadClass(name, resolve)
        }
    }
}

class LanternVpnService : VpnService() {
    private val worker = Executors.newSingleThreadExecutor()
    private val stopping = AtomicBoolean(false)
    private val bridge = LanternBridge(this)

    /** Build 2123 (P-06): the underlying-network watch, as
     *  before the swap — the gomobile core re-dials per
     *  connection once the TUN points at a live network. */
    private val underlyingWatch =
        UnderlyingNetworkWatch(this, "LanternVpnService") {
            CrashLog.breadcrumb(
                this,
                "lantern:underlying-network-changed",
            )
        }

    /** The kill-switch hold's TUN duplicate (build 2129,
     *  kept from 2127 H4/H5): taken from the bridge once the
     *  session is connected; while it stays open and unread,
     *  a dead session's traffic blackholes instead of going
     *  direct. */
    private var tunDup: ParcelFileDescriptor? = null

    @Volatile
    private var inKillSwitch = false

    @Volatile
    private var sessionTag: String = ""

    override fun onCreate() {
        super.onCreate()
        LanternStateStore.bindAppContext(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Build 2068: the start net, same shape as the other
        // engines' — a Throwable escaping the guarded body is
        // recorded in crash.log and the service stops
        // gracefully.
        return try {
            onStartCommandGuarded(intent, flags, startId)
        } catch (e: Throwable) {
            CrashLog.append(this, "LanternVpnService.onStartCommand", e)
            stopSelf()
            START_NOT_STICKY
        }
    }

    private fun onStartCommandGuarded(intent: Intent?, flags: Int, startId: Int): Int {
        underlyingWatch.start()
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel()
                EngineClaim.release(this, EngineClaim.LANTERN)
                return START_NOT_STICKY
            }
            ACTION_START -> {
                EngineClaim.claim(this, EngineClaim.LANTERN)
                startInForeground()
                if (LanternStateStore.running) return START_STICKY
                stopping.set(false)
                val ipv6 = intent.getBooleanExtra(EXTRA_IPV6, true)
                val mtu = clampMtu(intent.getIntExtra(EXTRA_MTU, MTU))
                val dns = intent.getStringExtra(EXTRA_DNS)
                    ?.takeIf { it.isNotBlank() } ?: "1.1.1.1"
                val tag = intent.getStringExtra(EXTRA_TAG) ?: ""
                inKillSwitch = intent.getBooleanExtra(EXTRA_KILL_SWITCH, false)
                // A fresh start over a kill-switch hold:
                // close the held duplicate and clear the hold
                // before this start establishes its own.
                if (LanternStateStore.killSwitchHeld) {
                    LanternStateStore.killSwitchHeld = false
                    closeTunDup()
                }
                worker.execute {
                    try {
                        startTunnel(tag, ipv6, mtu, dns)
                    } catch (e: Throwable) {
                        CrashLog.append(
                            this,
                            "LanternVpnService.startTunnel",
                            e,
                        )
                        Log.e(TAG, "the Lantern tunnel did not start", e)
                        if (LanternStateStore.serviceError == null) {
                            LanternStateStore.serviceError =
                                e.message ?: e.toString()
                        }
                        fail()
                    }
                }
                return START_STICKY
            }
            ACTION_INFO -> {
                // The picker's list fetch: initialize the core
                // (no VPN) and publish its server list. The
                // service stops itself afterwards when no
                // session runs.
                worker.execute {
                    try {
                        bridge.initialize()
                        refreshServers()
                        LanternStateStore.smartRouting = bridge.smartRouting()
                        LanternStateStore.republish()
                    } catch (e: Throwable) {
                        CrashLog.append(this, "LanternVpnService.info", e)
                        if (LanternStateStore.serviceError == null) {
                            LanternStateStore.serviceError =
                                e.message ?: e.toString()
                        }
                        LanternStateStore.republish()
                    } finally {
                        if (!LanternStateStore.running) stopSelf()
                    }
                }
                return START_NOT_STICKY
            }
            ACTION_SET_SMART -> {
                val on = intent.getBooleanExtra(EXTRA_SMART_ON, false)
                worker.execute {
                    try {
                        bridge.initialize()
                        bridge.setSmartRouting(on)
                        LanternStateStore.smartRouting = bridge.smartRouting()
                    } catch (e: Throwable) {
                        CrashLog.append(this, "LanternVpnService.setSmart", e)
                    } finally {
                        LanternStateStore.republish()
                        if (!LanternStateStore.running) stopSelf()
                    }
                }
                return START_NOT_STICKY
            }
            ACTION_SWITCH -> {
                // Build 2131: live server switch. A running
                // session re-selects inside the live tunnel —
                // the core switches via SelectServer, no TUN
                // rebuild. When no session runs there is
                // nothing to switch; the intent is ignored
                // (the Dart side only sends it while running).
                if (!LanternStateStore.running) return START_NOT_STICKY
                val newTag = intent.getStringExtra(EXTRA_TAG) ?: ""
                worker.execute {
                    try {
                        sessionTag = newTag
                        bridge.connect(newTag)
                        applySelectedServer()
                    } catch (e: Throwable) {
                        CrashLog.append(this, "LanternVpnService.switch", e)
                        if (LanternStateStore.serviceError == null) {
                            LanternStateStore.serviceError =
                                e.message ?: e.toString()
                        }
                    } finally {
                        LanternStateStore.republish()
                    }
                }
                return START_STICKY
            }
            ACTION_ADD_PRIVATE -> {
                val ip = intent.getStringExtra(EXTRA_IP) ?: ""
                val port = intent.getIntExtra(EXTRA_PORT, 8080)
                val token = intent.getStringExtra(EXTRA_TOKEN) ?: ""
                val tag = intent.getStringExtra(EXTRA_TAG) ?: ""
                worker.execute {
                    try {
                        registerPrivate(ip, port, token, tag)
                    } catch (e: Throwable) {
                        CrashLog.append(this, "LanternVpnService.addPrivate", e)
                        LanternStateStore.privateResult =
                            "error|Adding your private server failed: " +
                            (e.message ?: e.toString())
                    } finally {
                        LanternStateStore.republish()
                        if (!LanternStateStore.running) stopSelf()
                    }
                }
                return START_NOT_STICKY
            }
            ACTION_REMOVE_PRIVATE -> {
                val tag = intent.getStringExtra(EXTRA_TAG) ?: ""
                worker.execute {
                    try {
                        bridge.initialize()
                        bridge.deletePrivateServer(tag)
                    } catch (e: Throwable) {
                        CrashLog.append(this, "LanternVpnService.removePrivate", e)
                    } finally {
                        LanternStateStore.republish()
                        if (!LanternStateStore.running) stopSelf()
                    }
                }
                return START_NOT_STICKY
            }
        }
        return START_NOT_STICKY
    }

    /**
     * Registers the private server through the bridge and
     * waits for the core's listener verdict: an onError
     * event fails the registration in plain words; silence
     * past the budget reads as registered (the API is
     * fire-and-forget on success in the official client too —
     * the connect that follows is the real proof).
     */
    private fun registerPrivate(ip: String, port: Int, token: String, tag: String) {
        bridge.initialize()
        // Gomobile order (delta §1.7): ip, port-as-string,
        // accessToken, tag.
        //
        // Build 2132: the core PERSISTS private servers
        // across sessions, and radiance refuses a second
        // add of a stored tag ("server \"<tag>\" already
        // exists"). Re-adding OURS is idempotent by intent —
        // the stored entry is exactly what the pinned
        // connect needs — so that one failure reads as
        // success here. A different key for the same server
        // never reaches this path over a stale entry:
        // setPrivateKey in Dart removes the old registration
        // first, so a stored entry under our tag always
        // carries the current key's config.
        try {
            bridge.addPrivateServer(ip, port.toString(), token, tag)
        } catch (e: Throwable) {
            if (!isAlreadyRegistered(e, tag)) throw e
        }
        val deadline = System.currentTimeMillis() + PRIVATE_EVENT_WAIT_MS
        while (System.currentTimeMillis() < deadline) {
            val event = bridge.privateServerEvent()
            if (event.startsWith("error|")) {
                // The same already-registered verdict can
                // also arrive as a listener error event.
                if (isAlreadyRegistered(event.removePrefix("error|"), tag)) {
                    break
                }
                LanternStateStore.privateResult =
                    "error|Your server could not be added: " +
                    event.removePrefix("error|")
                return
            }
            if (event.startsWith("event|")) break
            Thread.sleep(250)
        }
        LanternStateStore.privateResult = "ok|$tag"
    }

    /**
     * True when [text] is the core's "this tag is already
     * stored" verdict for [tag] (build 2132) — the one
     * addPrivateServer failure that means the registration
     * we wanted is already in place.
     */
    private fun isAlreadyRegistered(text: String, tag: String): Boolean =
        tag.isNotEmpty() &&
            text.contains("already exists") &&
            text.contains(tag)

    /** The same check over a throwable's whole cause chain. */
    private fun isAlreadyRegistered(e: Throwable, tag: String): Boolean {
        val chain = StringBuilder()
        var cur: Throwable? = e
        while (cur != null) {
            chain.append(cur.message ?: cur.toString()).append('\n')
            cur = cur.cause
        }
        return isAlreadyRegistered(chain.toString(), tag)
    }

    private fun refreshServers() {
        val json = bridge.servers()
        LanternStateStore.serversJson = json
        LanternStateStore.servers = try {
            JSONArray(json).length()
        } catch (_: Throwable) {
            -1
        }
    }

    private fun startTunnel(tag: String, ipv6: Boolean, mtu: Int, dns: String) {
        LanternStateStore.serviceError = null
        LanternStateStore.stage = "starting"
        sessionTag = tag
        bridge.initialize()
        bridge.setSession(ipv6, mtu, dns)
        LanternStateStore.smartRouting = bridge.smartRouting()
        // The list rides along: the picker is populated by
        // the time the session is up (best-effort — a list
        // failure never blocks the connect).
        runCatching { refreshServers() }
        bridge.connect(tag)
        LanternStateStore.running = true
        LanternStateStore.startedAtMs = System.currentTimeMillis()
        LanternStateStore.markTrafficBase()
        updateNotification()
        watchStatus()
    }

    /**
     * Polls the core's own connected verdict (LML's 3.5 s
     * checkStatus shape): connected display comes only from
     * Mobile.isVPNConnected(), the exit identity from
     * getSelectedServerJSON(). A connected session that the
     * core stops reporting, while no stop was requested, is
     * a death: the kill switch decides hold vs teardown.
     */
    private fun watchStatus() {
        worker.execute {
            var wasConnected = false
            var missedPolls = 0
            while (!stopping.get() && LanternStateStore.running) {
                val connected = runCatching { bridge.connected() }
                    .getOrDefault(false)
                if (connected) {
                    missedPolls = 0
                    if (!wasConnected) {
                        wasConnected = true
                        LanternStateStore.connected = true
                        LanternStateStore.stage = "up"
                        // The kill-switch duplicate: taken
                        // once the bridge has a TUN to dup.
                        if (tunDup == null) {
                            tunDup = runCatching { bridge.dupTunFd() }
                                .getOrNull()
                        }
                        updateNotification()
                    }
                    applySelectedServer()
                } else if (wasConnected) {
                    missedPolls++
                    if (missedPolls >= 2) {
                        onSessionDied("the Lantern core stopped reporting a connection")
                        return@execute
                    }
                }
                LanternStateStore.republish()
                try {
                    Thread.sleep(STATUS_POLL_MS)
                } catch (e: InterruptedException) {
                    return@execute
                }
            }
        }
    }

    /** The selected server's identity, from the core's own
     *  JSON: {tag, location{city, country, country_code}} —
     *  the getAvailableServers entry shape. Unparseable or
     *  empty reads leave the previous identity in place. */
    private fun applySelectedServer() {
        // Build 2131: in a PINNED session the core's
        // SelectedServer JSON prefers its auto-selected
        // server, which misreports the exit (the owner's
        // 2130 verdict: pinned to his private server, the
        // exit showed a free public one). Resolve the exit
        // identity from the full server list by the session
        // tag instead; automatic sessions keep the core's
        // own readback below.
        val pinned = sessionTag
        if (pinned.isNotEmpty()) {
            val listJson = runCatching { bridge.servers() }.getOrDefault("")
            if (listJson.isNotBlank()) {
                try {
                    val raw = JSONArray(listJson)
                    for (i in 0 until raw.length()) {
                        val entry = raw.optJSONObject(i) ?: continue
                        if (entry.optString("tag", "") != pinned) continue
                        LanternStateStore.selectedTag = pinned
                        val city = entry.optString("city", "")
                        val country = entry.optString("country", "")
                        val code = entry.optString("countryCode", "")
                        if (city.isNotEmpty()) LanternStateStore.exitCity = city
                        if (country.isNotEmpty()) {
                            LanternStateStore.exitCountry = country
                        }
                        if (code.isNotEmpty()) LanternStateStore.exitCode = code
                        return
                    }
                } catch (_: Throwable) {
                    // The list readback is display only.
                }
            }
            return
        }
        val raw = runCatching { bridge.selectedServer() }.getOrDefault("")
        if (raw.isBlank()) return
        try {
            val json = JSONObject(raw)
            val tag = json.optString("tag", "")
            if (tag.isNotEmpty()) LanternStateStore.selectedTag = tag
            val location = json.optJSONObject("location") ?: json
            val city = location.optString("city", "")
            val country = location.optString("country", "")
            val code = location.optString("country_code", "")
            if (city.isNotEmpty()) LanternStateStore.exitCity = city
            if (country.isNotEmpty()) LanternStateStore.exitCountry = country
            if (code.isNotEmpty()) LanternStateStore.exitCode = code
        } catch (_: Throwable) {
            // The readback is display only.
        }
    }

    private fun fail() {
        runCatching { bridge.close() }
        LanternStateStore.running = false
        LanternStateStore.connected = false
        LanternStateStore.stage = "error"
        LanternStateStore.republish()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * An unexpected mid-session death. With the kill switch
     * on and a TUN duplicate held, the duplicate stays open
     * (traffic blackholes) and the service stays in the
     * foreground saying so, until the user disconnects or a
     * fresh start replaces it. Otherwise the ordinary
     * teardown. (If the :lantern process itself dies, no hold
     * is possible — the TUN closes with the process; that is
     * the gomobile shape's limit, recorded in the leg report.)
     */
    private fun onSessionDied(reason: String) {
        if (inKillSwitch && tunDup != null) {
            stopping.set(true)
            CrashLog.breadcrumb(this, "lantern:kill-switch-hold ($reason)")
            LanternStateStore.killSwitchHeld = true
            LanternStateStore.running = false
            LanternStateStore.connected = false
            LanternStateStore.republish()
            updateNotification()
        } else {
            stopTunnel()
        }
    }

    private fun closeTunDup() {
        try {
            tunDup?.close()
        } catch (e: Exception) {
            // Already closed.
        }
        tunDup = null
    }

    private fun stopTunnel() {
        stopping.set(true)
        // A manual stop releases a kill-switch hold.
        LanternStateStore.killSwitchHeld = false
        closeTunDup()
        runCatching { bridge.close() }
        LanternStateStore.running = false
        LanternStateStore.connected = false
        LanternStateStore.stage = "idle"
        LanternStateStore.exitCity = ""
        LanternStateStore.exitCountry = ""
        LanternStateStore.exitCode = ""
        LanternStateStore.selectedTag = ""
        LanternStateStore.republish()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onRevoke() {
        stopTunnel()
        super.onRevoke()
    }

    override fun onDestroy() {
        underlyingWatch.stop()
        EngineClaim.release(this, EngineClaim.LANTERN)
        stopping.set(true)
        closeTunDup()
        runCatching { bridge.close() }
        LanternStateStore.running = false
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
            this, 40, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 41, Intent(this, LanternVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val exit = when {
            LanternStateStore.exitCity.isNotEmpty() && LanternStateStore.exitCountry.isNotEmpty() ->
                "${LanternStateStore.exitCity}, ${LanternStateStore.exitCountry}"
            LanternStateStore.exitCountry.isNotEmpty() -> LanternStateStore.exitCountry
            else -> ""
        }
        val text = when {
            LanternStateStore.killSwitchHeld ->
                "Lantern · kill switch holding — traffic is blocked"
            LanternStateStore.connected && exit.isNotEmpty() -> "Lantern · $exit"
            LanternStateStore.connected -> "Lantern"
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
        const val ACTION_INFO = "com.ralysnd.ember.LANTERN_INFO"
        const val ACTION_SET_SMART = "com.ralysnd.ember.LANTERN_SET_SMART"
        const val ACTION_ADD_PRIVATE = "com.ralysnd.ember.LANTERN_ADD_PRIVATE"
        const val ACTION_REMOVE_PRIVATE = "com.ralysnd.ember.LANTERN_REMOVE_PRIVATE"
        // Build 2131: live server switch on a running session.
        const val ACTION_SWITCH = "com.ralysnd.ember.LANTERN_SWITCH"
        private const val EXTRA_IPV6 = "ipv6"
        private const val EXTRA_MTU = "mtu"
        private const val EXTRA_DNS = "dns"
        private const val EXTRA_TAG = "tag"
        private const val EXTRA_SMART_ON = "smart"
        private const val EXTRA_IP = "ip"
        private const val EXTRA_PORT = "port"
        private const val EXTRA_TOKEN = "token"
        // Build 2125 (A25-04): the kill switch.
        private const val EXTRA_KILL_SWITCH = "killSwitch"

        private const val CHANNEL = "lantern_status"
        private const val NOTIFICATION_ID = 4
        private const val TAG = "LanternVpnService"
        private const val MTU = 1500
        private const val STATUS_POLL_MS = 3_500L
        private const val PRIVATE_EVENT_WAIT_MS = 20_000L

        /** Clamps a tunnel MTU to the offered range (build
         *  2038): 1280 floor, 1500 ceiling. */
        private fun clampMtu(mtu: Int) = mtu.coerceIn(1280, 1500)

        fun start(
            context: Context,
            ipv6: Boolean,
            mtu: Int = 1500,
            dns: String = "1.1.1.1",
            killSwitch: Boolean = false,
            tag: String = "",
        ) {
            val intent = Intent(context, LanternVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_IPV6, ipv6)
                putExtra(EXTRA_MTU, clampMtu(mtu))
                putExtra(EXTRA_DNS, dns)
                putExtra(EXTRA_KILL_SWITCH, killSwitch)
                putExtra(EXTRA_TAG, tag)
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

        /** Asks the :lantern process to initialize the core
         *  and publish its server list (no VPN session). */
        fun fetchInfo(context: Context) {
            context.startService(
                Intent(context, LanternVpnService::class.java).apply { action = ACTION_INFO },
            )
        }

        fun setSmartRouting(context: Context, on: Boolean) {
            context.startService(
                Intent(context, LanternVpnService::class.java).apply {
                    action = ACTION_SET_SMART
                    putExtra(EXTRA_SMART_ON, on)
                },
            )
        }

        fun addPrivateServer(
            context: Context,
            ip: String,
            port: Int,
            token: String,
            tag: String,
        ) {
            context.startService(
                Intent(context, LanternVpnService::class.java).apply {
                    action = ACTION_ADD_PRIVATE
                    putExtra(EXTRA_IP, ip)
                    putExtra(EXTRA_PORT, port)
                    putExtra(EXTRA_TOKEN, token)
                    putExtra(EXTRA_TAG, tag)
                },
            )
        }

        /** Build 2131: asks the running session to switch to
         *  [tag] ("" = automatic) inside the live tunnel. */
        fun switchServer(context: Context, tag: String) {
            context.startService(
                Intent(context, LanternVpnService::class.java).apply {
                    action = ACTION_SWITCH
                    putExtra(EXTRA_TAG, tag)
                },
            )
        }

        fun removePrivateServer(context: Context, tag: String) {
            context.startService(
                Intent(context, LanternVpnService::class.java).apply {
                    action = ACTION_REMOVE_PRIVATE
                    putExtra(EXTRA_TAG, tag)
                },
            )
        }
    }
}
