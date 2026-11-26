package com.ralysnd.ember

import android.Manifest
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ActivityNotFoundException
import android.content.DialogInterface
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import android.net.Uri
import android.net.VpnService
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result

/**
 * The Flutter UI. Channel "app/android": dataDir, startCore (with the proxy
 * off), setOn, isRunning, openUrl. The UI talks to the core itself through
 * its HTTP API on loopback, as on the desktop.
 */
class MainActivity : FlutterActivity() {
    /** Waits for the user's answer to the VPN permission. */
    private var pendingOn: Result? = null

    /** The Mozilla start to run once the permission is given (build 2070). */
    private var pendingOnStart: (() -> Unit)? = null

    /** The same wait for the V2Ray engine's VPN permission. */
    private var pendingXrayOn: Result? = null

    /** The Xray start to run once the permission is given. */
    private var pendingXrayStart: (() -> Unit)? = null

    /** The same wait for the AmneziaWG engine's VPN permission (build 2040). */
    private var pendingAwgOn: Result? = null

    /** The AmneziaWG start to run once the permission is given. */
    private var pendingAwgStart: (() -> Unit)? = null

    /** The same wait for the Psiphon engine's VPN permission. */
    private var pendingPsiphonOn: Result? = null

    /** The Psiphon start to run once the permission is given. */
    private var pendingPsiphonStart: (() -> Unit)? = null

    /** The same wait for the Lantern engine's VPN permission. */
    private var pendingLanternOn: Result? = null

    /** The Lantern start to run once the permission is given. */
    private var pendingLanternStart: (() -> Unit)? = null

    /** The same wait for the OpenVPN engine's VPN permission. */
    private var pendingOpenVpnOn: Result? = null

    /** The OpenVPN start to run once the permission is given. */
    private var pendingOpenVpnStart: (() -> Unit)? = null

    /** The same wait for the standalone WARP session's permission. */
    private var pendingWarpOn: Result? = null

    /** The standalone WARP start to run once permission is given. */
    private var pendingWarpStart: (() -> Unit)? = null

    /** The result waiting for the .ovpn file picker's answer. */
    private var pendingPick: Result? = null

    /** The result waiting for the generic text-file picker's
     *  answer (build 2050: WireGuard .conf import rides the same
     *  machinery the OpenVPN picker built). */
    private var pendingTextPick: Result? = null

    /** The result + payload waiting for the document
     *  creator's answer (build 2095: backup save-to-file). */
    // Build 2095 (feature 6): gallery image pick for QR
    // decode — the picked image is copied to the cache dir
    // and its PATH returned (the decoder needs a file).
    private var pendingImagePick: Result? = null

    private var pendingSave: Result? = null
    private var pendingSaveContent: String = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        // Build 2068: belt and braces — EmberApplication has
        // already installed the crash recorder by now (it runs
        // before any component); this idempotent re-install only
        // confirms it on a path that is itself exercised in
        // review, so the recorder's presence never rests on one
        // line in one file.
        CrashLog.install(this)
        holdPhoneUpright(resources.configuration)
        super.onCreate(savedInstanceState)
        // Build 2116 (B10-1): a Psiphon state snapshot that
        // claims a live session while the :psiphon process
        // is not alive and the snapshot is past the
        // staleness bound is a dead process's leavings —
        // delete it, so nothing downstream can adopt it.
        // The read side (parsePublishedState) already
        // demotes such a snapshot; this keeps the file
        // itself honest. Both guards must hold, so a live
        // process's fresh snapshot is never touched.
        try {
            if (PsiphonExternalWatchdog.findPsiphonPid(this) == null) {
                PsiphonVpnService.clearStalePublishedState(this)
            }
        } catch (_: Throwable) {
            // Hygiene only — never a start failure.
        }
        // Build 2075: the notification's Switch-server action
        // may be what launched the app.
        // Build 2095 (audit 5-9): the rotate extra is
        // honoured only with this install's nonce stamp.
        if (intent?.getStringExtra("ember_action") == "rotate" &&
            EmberIntentNonce.matches(this, intent)
        ) {
            pendingNotificationRotate = true
        }
        // Build 2104: the WG Tunnel companion notification's
        // Disconnect may be what launched the app — a
        // nonce-stamped stop, performed here in Kotlin (the
        // old AWG service's ACTION_STOP funnelled through
        // WgTunnelEngine.stop; it needs no Dart round-trip,
        // and the engine records it as a user stop).
        // Build 2106 (verification iteration 2, M-1): via
        // stopFromNotification, so the stop advances the
        // user-stop sequence Dart's peer walk watches.
        if (intent?.getStringExtra("ember_action") == "stop" &&
            EmberIntentNonce.matches(this, intent)
        ) {
            WgTunnelEngine.stopFromNotification(this)
        }
        // Build 2085 (audit F-H15): an .ovpn file opened with /
        // shared to Ember may be what launched the app — read it
        // now (the granting app's URI permission is tied to this
        // launch) and flush it to Dart once the channel exists.
        // Build 2095 (audit #38): a config-scheme VIEW is a
        // deep link, never an .ovpn file read.
        val deepLink = extractDeepLink(intent)
        if (deepLink != null) {
            pendingDeepLink = deepLink
        } else {
            extractOvpnIntent(intent)?.let { pendingOvpnFile = it }
        }
        // Build 2093: a launcher-shortcut tap may be what launched
        // the app — hold the profile id until the channel exists.
        LauncherShortcuts.extractProfileIdChecked(this, intent)?.let {
            pendingShortcutProfileId = it
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Build 2075 (feature item 12): the V2Ray
        // notification's Switch-server action. Forwarded to
        // Dart, which owns the fallback group and performs
        // the same switch as the in-app control.
        if (intent.getStringExtra("ember_action") == "rotate" &&
            EmberIntentNonce.matches(this, intent)
        ) {
            val ch = appChannel
            if (ch != null) {
                runOnUiThread { ch.invokeMethod("notificationRotate", null) }
            } else {
                pendingNotificationRotate = true
            }
        }
        // Build 2104: the companion notification's Disconnect
        // while the app is already running — the same
        // Kotlin-side stop as the cold-start case above.
        // Build 2106 (M-1): stopFromNotification, as there.
        if (intent.getStringExtra("ember_action") == "stop" &&
            EmberIntentNonce.matches(this, intent)
        ) {
            WgTunnelEngine.stopFromNotification(this)
        }
        // Build 2095 (audit #38): a config link while the app
        // is already running.
        val deepLink = extractDeepLink(intent)
        if (deepLink != null) {
            val ch = appChannel
            if (ch != null) {
                runOnUiThread {
                    ch.invokeMethod("deepLink", mapOf("link" to deepLink))
                }
            } else {
                pendingDeepLink = deepLink
            }
            return
        }
        // Build 2085 (audit F-H15): the same .ovpn intake
        // while the app is already running.
        extractOvpnIntent(intent)?.let { file ->
            val ch = appChannel
            if (ch != null) {
                runOnUiThread { ch.invokeMethod("openOvpnFile", file) }
            } else {
                pendingOvpnFile = file
            }
        }
        // Build 2093: the same launcher-shortcut tap while the
        // app is already running.
        // Build 2095 (audit 5-9): nonce-checked, as in onCreate.
        LauncherShortcuts.extractProfileIdChecked(this, intent)?.let { id ->
            val ch = appChannel
            if (ch != null) {
                runOnUiThread {
                    ch.invokeMethod("shortcutConnect", mapOf("profileId" to id))
                }
            } else {
                pendingShortcutProfileId = id
            }
        }
    }

    /** Build 2075: a rotate request that arrived before the
     *  app channel existed; flushed in configureFlutterEngine. */
    private var pendingNotificationRotate = false

    /** Build 2085 (audit F-H15): an .ovpn file that arrived
     *  before the app channel existed; flushed in
     *  configureFlutterEngine, like the rotate request. */
    private var pendingOvpnFile: Map<String, String>? = null

    /** Build 2093: a launcher-shortcut tap that arrived before
     *  the app channel existed; flushed in configureFlutterEngine,
     *  like the rotate request. */
    private var pendingShortcutProfileId: String? = null

    /** Build 2095 (whole-app journey audit #38): a config
     *  link (vless://…) that cold-started the app; flushed in
     *  configureFlutterEngine, like the rotate request. */
    private var pendingDeepLink: String? = null

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        holdPhoneUpright(newConfig)
    }

    /**
     * A phone stays upright (its layout is made for it); a tablet, whose
     * shorter side is 600 dp or more, turns freely. Asked again when the
     * screen changes, so a foldable follows its folding.
     */
    private fun holdPhoneUpright(config: Configuration) {
        val wanted = if (config.smallestScreenWidthDp < 600) {
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        } else {
            ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
        if (requestedOrientation != wanted) requestedOrientation = wanted
    }

    private var exitReasonCache: String? = null

    /**
     * The system's own record of how the previous process
     * exited (API 30+), reduced to the crash-shaped reasons —
     * the readback that turns a silent native death into a
     * named one in the OpenVPN page's diagnostics.
     */
    private fun lastExitReasonText(): String {
        exitReasonCache?.let { return it }
        val text = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val first = getSystemService(ActivityManager::class.java)
                    ?.getHistoricalProcessExitReasons(packageName, 0, 3)
                    ?.firstOrNull()
                when (first?.reason) {
                    ApplicationExitInfo.REASON_CRASH_NATIVE ->
                        "The previous run died in native code " +
                            "(signal ${first?.status})."
                    ApplicationExitInfo.REASON_CRASH ->
                        "The previous run crashed before it could report."
                    ApplicationExitInfo.REASON_ANR ->
                        "The previous run was killed as unresponsive (ANR)."
                    else -> ""
                }
            } catch (_: Exception) {
                ""
            }
        } else {
            ""
        }
        exitReasonCache = text
        return text
    }

    /** Build 2065: the app channel, kept so the network callback
     *  can push 'networkChanged' events to Dart. */
    private var appChannel: MethodChannel? = null

    /** Build 2136 (item 1): the screen-off receiver behind the
     *  stop-on-sleep setting. Registered in configureFlutterEngine;
     *  it only forwards the broadcast to Dart — the setting and
     *  the disconnect live on the Dart side, so off means the
     *  event is dropped there and nothing changes. */
    private var screenOffReceiver: android.content.BroadcastReceiver? = null

    private fun registerScreenOffReceiver() {
        if (screenOffReceiver != null) return
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(
                context: android.content.Context?,
                intent: Intent?,
            ) {
                if (intent?.action == Intent.ACTION_SCREEN_OFF) {
                    appChannel?.invokeMethod("screenOff", null)
                }
            }
        }
        try {
            registerReceiver(
                receiver,
                android.content.IntentFilter(Intent.ACTION_SCREEN_OFF),
            )
            screenOffReceiver = receiver
        } catch (e: Exception) {
            // A platform that refuses the registration leaves
            // stop-on-sleep inert rather than crashing startup.
        }
    }

    /** Build 2065: the current network's identity, as far as the
     *  platform exposes it without a location permission: the
     *  transport, the carrier/operator name on mobile, and the
     *  Wi-Fi SSID only when Android hands it out (without location
     *  permission it reports "<unknown ssid>", which maps to the
     *  coarse key on the Dart side — per-network winner memory and
     *  the auto-connect triggers share this map). */
    private fun networkInfoMap(): Map<String, String> {
        var transport = "none"
        var ssid = ""
        var operatorName = ""
        try {
            val cm = getSystemService(android.net.ConnectivityManager::class.java)
            val caps = cm?.getNetworkCapabilities(cm.activeNetwork)
            if (caps != null) {
                transport = when {
                    caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                    caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
                    caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                    else -> "other"
                }
            }
            if (transport == "wifi") {
                @Suppress("DEPRECATION")
                val info = getSystemService(android.net.wifi.WifiManager::class.java)?.connectionInfo
                val raw = info?.ssid?.trim('"') ?: ""
                if (raw.isNotEmpty() && raw != "<unknown ssid>") ssid = raw
            }
            if (transport == "mobile") {
                operatorName = getSystemService(android.telephony.TelephonyManager::class.java)
                    ?.networkOperatorName ?: ""
            }
        } catch (e: Exception) {
            // Identity is best-effort; the coarse key still works.
        }
        return mapOf(
            "transport" to transport,
            "ssid" to ssid,
            "operator" to operatorName,
        )
    }

    private var networkCallback: android.net.ConnectivityManager.NetworkCallback? = null

    /** Build 2065: pushes a 'networkChanged' channel event whenever
     *  the default network changes — the auto-connect triggers and
     *  the per-network winner memory key off it on the Dart side. */
    private fun registerNetworkCallback() {
        if (networkCallback != null) return
        val cm = getSystemService(android.net.ConnectivityManager::class.java) ?: return
        val cb = object : android.net.ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: android.net.Network) {
                runOnUiThread { appChannel?.invokeMethod("networkChanged", networkInfoMap()) }
            }

            override fun onLost(network: android.net.Network) {
                runOnUiThread { appChannel?.invokeMethod("networkChanged", networkInfoMap()) }
            }
        }
        networkCallback = cb
        try {
            cm.registerDefaultNetworkCallback(cb)
        } catch (e: Exception) {
            networkCallback = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app/android")
        appChannel = channel
        registerNetworkCallback()
        registerScreenOffReceiver()
        // Build 2075: a notification Switch-server tap that
        // cold-started the app lands here once the channel
        // exists (see onNewIntent).
        if (pendingNotificationRotate) {
            pendingNotificationRotate = false
            channel.invokeMethod("notificationRotate", null)
        }
        // Build 2085 (audit F-H15): a cold-started .ovpn open
        // lands here once the channel exists (see onCreate).
        pendingOvpnFile?.let {
            pendingOvpnFile = null
            channel.invokeMethod("openOvpnFile", it)
        }
        // Build 2093: a cold-started launcher-shortcut tap lands
        // here once the channel exists (see onCreate).
        pendingShortcutProfileId?.let {
            pendingShortcutProfileId = null
            channel.invokeMethod("shortcutConnect", mapOf("profileId" to it))
        }
        // Build 2095 (audit #38): a cold-started config link
        // lands here once the channel exists (see onCreate).
        pendingDeepLink?.let {
            pendingDeepLink = null
            channel.invokeMethod("deepLink", mapOf("link" to it))
        }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "dataDir" -> result.success(CoreService.dataDir(this).absolutePath)
                // Battery usage report (build 2105): the
                // device battery level at a session's edges.
                // BatteryManager's capacity property is the
                // system reading; a device that does not expose
                // it answers -1 and the Dart side records the
                // edge as unknown rather than as a level.
                "batteryStatus" -> {
                    val bm = getSystemService(
                        android.content.Context.BATTERY_SERVICE,
                    ) as android.os.BatteryManager
                    val level = bm.getIntProperty(
                        android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY,
                    )
                    result.success(mapOf("level" to level))
                }
                // Overlay-attack protection (build 2075,
                // feature item 30): while a sensitive screen
                // is showing (config view, QR show/scan,
                // account pages), the window refuses to be
                // obscured by another app's overlay. API 31+;
                // older systems simply have no such switch.
                // Build 2095 (feature 5): the widget reads
                // this marker to gate its tap behind the
                // app lock.
                "setWidgetLock" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    getSharedPreferences("ember_widget", MODE_PRIVATE)
                        .edit().putBoolean("lock_enabled", on).apply()
                    result.success(null)
                }
                "setSecureFlag" -> {
                    // Build 2095 (whole-app journey audit
                    // #45): FLAG_SECURE while the lock page or
                    // a sensitive surface is up — the recents
                    // thumbnail must not keep a snapshot of
                    // unlocked content.
                    val on = call.argument<Boolean>("on") ?: false
                    runOnUiThread {
                        if (on) {
                            window.addFlags(
                                android.view.WindowManager.LayoutParams
                                    .FLAG_SECURE,
                            )
                        } else {
                            window.clearFlags(
                                android.view.WindowManager.LayoutParams
                                    .FLAG_SECURE,
                            )
                        }
                    }
                    result.success(null)
                }
                "setOverlayGuard" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        try {
                            window.setHideOverlayWindows(on)
                        } catch (_: Exception) {
                            // A window that cannot take the flag
                            // must never break the screen.
                        }
                    }
                    result.success(null)
                }
                // Launcher shortcuts (build 2093): the starred
                // profiles as long-press app-icon shortcuts. The
                // publish is best-effort on this side too — a
                // refused publish answers success, never an error
                // into the starring flow.
                "publishShortcuts" -> {
                    @Suppress("UNCHECKED_CAST")
                    val items =
                        (call.argument<List<Any>>("shortcuts") ?: emptyList())
                            .mapNotNull { raw ->
                                val m = raw as? Map<*, *> ?: return@mapNotNull null
                                val id = m["id"] as? String
                                val name = m["name"] as? String
                                if (id.isNullOrBlank() || name.isNullOrBlank()) {
                                    null
                                } else {
                                    id to name
                                }
                            }
                    LauncherShortcuts.publish(this, items)
                    result.success(null)
                }
                "clearShortcuts" -> {
                    LauncherShortcuts.clear(this)
                    result.success(null)
                }
                "startCore" -> {
                    // Build 2095 (audit 3-4): a native start
                    // failure crosses the channel as an error
                    // instead of a silent success.
                    val problem = CoreService.startCore(this, on = false)
                    if (problem != null) {
                        result.error("core_start_failed", problem, null)
                    } else {
                        result.success(null)
                    }
                }
                "setOn" -> {
                    if (call.argument<Boolean>("on") != true) {
                        CoreService.turnOff(this)
                        result.success(null)
                    } else {
                        askForNotifications()
                        // The tunnel MTU (build 2038, queue 2f): the
                        // Dart side mirrors the Settings value into
                        // AndroidCore.tunnelMtu; store it in prefs
                        // before the consent flow, so it survives
                        // the permission round-trip and a later
                        // system restart of the service.
                        CoreService.setTunnelMtu(
                            this,
                            call.argument<Int>("mtu") ?: 1500,
                        )
                        // Build 2127 (H4): the kill switch,
                        // mirrored beside the MTU so the
                        // service's death paths can read it
                        // from prefs (a system restart of the
                        // service keeps it too).
                        CoreService.setKillSwitch(
                            this,
                            call.argument<Boolean>("killSwitch") ?: false,
                        )
                        // The first time, Android asks the user to allow the
                        // VPN; proxy mode needs no VPN. Build 2067: the
                        // prepare + consent launch were guarded with a
                        // guard spelled out inline (Exception-only),
                        // because this branch's start — CoreService
                        // .turnOn — completed the result itself.
                        // Build 2070 (review §9 item 1): turnOn no
                        // longer completes anything (it records and
                        // rethrows since this build), so the branch
                        // takes the shared startVpnGuarded like every
                        // other engine: Throwable-level, crash.log
                        // record, "vpn_start_refused" on refusal.
                        // The one answer that changes shape is a
                        // turnOn failure itself: it used to reply
                        // "start_failed" with the raw message; it
                        // now replies "vpn_start_refused" with the
                        // throwable's simple name, exactly like the
                        // other engines since 2067 — the Dart side
                        // treats both as a generic start failure.
                        startVpnGuarded(
                            result,
                            needsConsent = CoreService.usesVpn(this),
                            park = { parkedResult, parkedStart ->
                                pendingOn?.error("vpn_denied", "superseded", null)
                                pendingOn = parkedResult
                                pendingOnStart = parkedStart
                            },
                            unpark = {
                                pendingOn = null
                                pendingOnStart = null
                            },
                            start = { CoreService.turnOn(this) },
                        )
                    }
                }
                "isRunning" -> result.success(mobile.Mobile.running())
                "connectionMode" -> result.success(CoreService.connectionMode(this))
                "showSpeed" -> result.success(CoreService.showSpeed(this))
                "setShowSpeed" -> {
                    CoreService.setShowSpeed(this, call.argument<Boolean>("on") == true)
                    result.success(null)
                }
                "setConnectionMode" -> {
                    val mode = call.argument<String>("mode") ?: CoreService.MODE_VPN
                    // A running proxy switched to the VPN needs the permission
                    // first; the app turns it off and on again to ask.
                    if (CoreService.on && mode == CoreService.MODE_VPN && VpnService.prepare(this) != null) {
                        result.error("vpn_denied", "the VPN is not allowed yet", null)
                    } else {
                        CoreService.setConnectionMode(this, mode)
                        result.success(null)
                    }
                }
                "installedApps" -> inBackground(result) { installedApps() }
                "appIcon" -> {
                    val pkg = call.argument<String>("package") ?: ""
                    inBackground(result) { appIcon(pkg) }
                }
                "appRouting" -> inBackground(result) {
                    // The page shows the region's apps installed since the
                    // last look checked; the VPN takes them at once.
                    if (CoreService.appMode(this) == CoreService.MODE_EXCLUDE &&
                        CoreService.suggest(this, force = true)
                    ) {
                        CoreService.reconnect(this)
                    }
                    mapOf(
                        "mode" to CoreService.appMode(this),
                        "bypass" to CoreService.appSet(this, CoreService.BYPASS).toList(),
                        "only" to CoreService.appSet(this, CoreService.ONLY).toList(),
                        "declined" to CoreService.appSet(this, CoreService.DECLINED).toList(),
                        "region" to CoreService.regionAppList(),
                    )
                }
                "setAppRouting" -> {
                    fun set(key: String) = (call.argument<List<String>>(key) ?: emptyList()).toSet()
                    CoreService.setAppRouting(
                        this,
                        call.argument<String>("mode") ?: CoreService.MODE_EXCLUDE,
                        mapOf(
                            CoreService.BYPASS to set("bypass"),
                            CoreService.ONLY to set("only"),
                            CoreService.DECLINED to set("declined"),
                        ),
                    )
                    if (call.argument<Boolean>("apply") == true) CoreService.reconnect(this)
                    result.success(null)
                }
                // The V2Ray engine (XrayVpnService.kt): start asks for the
                // VPN permission like setOn does.
                "xraySetOn" -> {
                    if (call.argument<Boolean>("on") != true) {
                        XrayVpnService.stop(this)
                        // Build 2100: an AWG session is stopped
                        // too (before 2100 one stop reaped every
                        // session, because one service ran them
                        // all). Build 2104: the AWG session lives
                        // on the WG Tunnel backend now — the stop
                        // funnels into WgTunnelEngine.
                        WgTunnelEngine.stop(this)
                        result.success(null)
                    } else {
                        // Build 2068: the coarse Xray breadcrumb
                        // trail — the healthy control group next
                        // to Psiphon's fine one (Xray connects on
                        // the owner's phone; its full sequence in
                        // crash.log shows what a working start
                        // looks like beside a truncated one).
                        CrashLog.breadcrumb(this, "xray:handler-entered")
                        askForNotifications()
                        val start = {
                            CrashLog.breadcrumb(this, "xray:start-invoked")
                            XrayVpnService.start(
                                this,
                                call.argument<String>("config") ?: "",
                                call.argument<String>("name") ?: "",
                                call.argument<Int>("socksPort") ?: 10808,
                                call.argument<String>("dns") ?: "1.1.1.1",
                                call.argument<Boolean>("ipv6") ?: true,
                                call.argument<Int>("mtu") ?: 1500,
                                call.argument<String>("underlay") ?: "none",
                                call.argument<String>("underlayRegion") ?: "",
                                call.argument<String>("underlayUpstream") ?: "",
                                call.argument<List<String>>("underlayProtocols")
                                    ?: emptyList(),
                                call.argument<List<String>>("warpArgs")
                                    ?: emptyList(),
                                // LAN sharing (build 2062, feature
                                // queue #2): the SOCKS credentials
                                // the tun2socks bridge presents to
                                // the password-protected inbound.
                                call.argument<String>("socksUser") ?: "",
                                call.argument<String>("socksPass") ?: "",
                                // Kill switch (build 2063, feature
                                // queue #3).
                                call.argument<Boolean>("killSwitch") ?: false,
                                // DNSTT underlay + WireGuard over
                                // WebSocket (build 2072).
                                call.argument<List<String>>("dnsttArgs")
                                    ?: emptyList(),
                                call.argument<Boolean>("wgWstunnel") ?: false,
                                call.argument<List<String>>("wstunnelArgs")
                                    ?: emptyList(),
                                // OLCRTC underlay (build 2134).
                                call.argument<List<String>>("olcrtcArgs")
                                    ?: emptyList(),
                                // Tunnel bridge (build 2155, the
                                // 2153 swap): 'hev' or 'tunlink'.
                                call.argument<String>("bridge") ?: "hev",
                            )
                        }
                        // Build 2067: guarded start handoff
                        // (see startVpnGuarded).
                        startVpnGuarded(
                            result,
                            needsConsent = true,
                            park = { parkedResult, parkedStart ->
                                pendingXrayOn?.error("vpn_denied", "superseded", null)
                                pendingXrayOn = parkedResult
                                pendingXrayStart = parkedStart
                            },
                            unpark = {
                                pendingXrayOn = null
                                pendingXrayStart = null
                            },
                            start = start,
                        )
                    }
                }
                "xrayStop" -> {
                    XrayVpnService.stop(this)
                    // Build 2100: dual stop — the AWG session
                    // stops too. Build 2104: it lives on the WG
                    // Tunnel backend (WgTunnelEngine).
                    WgTunnelEngine.stop(this)
                    result.success(null)
                }
                // The AmneziaWG engine (build 2104: WG Tunnel's
                // backend, WgTunnelEngine): start asks for the
                // VPN permission like xraySetOn does; the
                // backend's own VpnService brings the TUN up —
                // no Xray core, no SOCKS port. The settings
                // argument is the profile's canonical .conf
                // text (build 2104; builds 2040–2103 sent a
                // hand-composed UAPI string to the old bridge).
                "awgSetOn" -> {
                    if (call.argument<Boolean>("on") != true) {
                        // Dual stop, as since build 2100: one
                        // stop reaps every session.
                        WgTunnelEngine.stop(this)
                        XrayVpnService.stop(this)
                        result.success(null)
                    } else {
                        askForNotifications()
                        val start = {
                            WgTunnelEngine.start(
                                this,
                                call.argument<String>("name") ?: "",
                                call.argument<String>("settings") ?: "",
                                call.argument<String>("dns") ?: "1.1.1.1",
                                // Build 2102 (diagnosis C2): the
                                // profile's IPv4 footprint; absent
                                // (a pre-2102 caller) keeps the
                                // historical route capture.
                                call.argument<Boolean>("ipv4") ?: true,
                                call.argument<Boolean>("ipv6") ?: true,
                                // Build 2116 (audit B3-1): the
                                // Settings tunnel MTU — Dart has
                                // sent it since 2059 but no
                                // reader existed; it is the
                                // fallback when the profile
                                // carries no usable MTU.
                                call.argument<Int>("mtu") ?: 0,
                                // Build 2127 (H4): the kill
                                // switch (the library lockdown
                                // on an unexpected drop).
                                call.argument<Boolean>("killSwitch") ?: false,
                            )
                        }
                        // Build 2067: guarded start handoff
                        // (see startVpnGuarded).
                        startVpnGuarded(
                            result,
                            needsConsent = true,
                            park = { parkedResult, parkedStart ->
                                pendingAwgOn?.error("vpn_denied", "superseded", null)
                                pendingAwgOn = parkedResult
                                pendingAwgStart = parkedStart
                            },
                            unpark = {
                                pendingAwgOn = null
                                pendingAwgStart = null
                            },
                            start = start,
                        )
                    }
                }
                "xrayRotateConfig" -> {
                    // Watchdog shape rotation (build 2029A): swap
                    // the live core's config; TUN untouched. An
                    // AmneziaWG session has no core to respawn
                    // (build 2040), so it refuses outright.
                    val config = call.argument<String>("config") ?: ""
                    // Build 2104: the AWG session lives on the
                    // WG Tunnel backend in THIS process — the
                    // guard reads its live status directly (the
                    // :awg published-snapshot staleness rule of
                    // build 2100 is gone with the process).
                    if (config.isNotEmpty() && XrayVpnService.running &&
                        !WgTunnelEngine.isLive(this)
                    ) {
                        XrayVpnService.rotate(this, config)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "xrayState" -> {
                    val (up, down) = XrayVpnService.sessionTraffic()
                    val baseState = mapOf(
                        "running" to XrayVpnService.running,
                        "name" to XrayVpnService.profileName,
                        "sinceMs" to XrayVpnService.startedAtMs,
                        "up" to up,
                        "down" to down,
                        "coreRestarts" to XrayVpnService.coreRestarts,
                        "coreProblem" to XrayVpnService.coreProblem,
                        // Build 2054 (audit F-H2): the rotation
                        // generation — the Dart side waits for
                        // it to advance before believing a
                        // tunnelCheck after a rotate.
                        "rotationGen" to XrayVpnService.rotationGen,
                        "chainUnderlay" to XrayVpnService.chainUnderlay,
                        "chainProblem" to XrayVpnService.chainProblem,
                        // AmneziaWG (build 2104): whether the
                        // live tunnel is the WG Tunnel backend's,
                        // and its handshake age / transfer
                        // counters — computed by WgTunnelEngine
                        // from the backend's own ActiveConfig
                        // (the merge below); the base map is the
                        // not-AWG shape. Builds 2040–2103 shipped
                        // the raw UAPI dump here for Dart to
                        // parse; that parse was the standing
                        // failure (see WgTunnelEngine).
                        "awg" to false,
                        "awgHandshakeAgeSec" to -1,
                        // Build 2104 (iteration 2, M3): the
                        // problem sequence, 0 until the AWG
                        // engine records one (see
                        // WgTunnelEngine.problemSeq).
                        "awgProblemSeq" to 0,
                        // Build 2106 (verification iteration
                        // 2, M-1): the notification-stop
                        // sequence, same treatment (see
                        // WgTunnelEngine.userStopSeq).
                        "awgUserStopSeq" to 0,
                        "awgRxBytes" to 0L,
                        "awgTxBytes" to 0L,
                        // Kill switch (build 2063, feature
                        // queue #3): the service is holding a
                        // dead session's TUN as a blackhole —
                        // traffic is blocked, not direct.
                        "killSwitchHeld" to XrayVpnService.blackholeHeld,
                        // Paused (build 2081, verification
                        // V-8): the tunnel is held from its
                        // notification, not dropped.
                        "paused" to XrayVpnService.paused,
                        // Stopped by the user (build 2087,
                        // analysis A2): the last stop was
                        // the notification's Disconnect (or
                        // the app's own stop) — the Dart poll
                        // ends the reconnect expectation
                        // instead of resurrecting the session.
                        "userStopped" to XrayVpnService.userStopped,
                        // Build 2110 (wg-start diagnosis,
                        // defect 2): a tunnel is still
                        // registered with the WG Tunnel
                        // backend — the engine-switch funnel
                        // polls it to observe the previous
                        // engine fully down (`running` flips
                        // false before the backend releases
                        // the VPN slot). Carried in the base
                        // map so every merge branch reports
                        // it (see WgTunnelEngine.tunnelPresent).
                        "awgTunnelPresent" to
                            WgTunnelEngine.tunnelPresent(),
                    )
                    // Build 2104: the AWG session lives on the
                    // WG Tunnel backend in THIS process — merge
                    // WgTunnelEngine's snapshot over the
                    // Xray-based values. The :awg published-file
                    // machinery of build 2100 (the 15 s stale-
                    // snapshot death rule, the 45 s userStopped
                    // freshness window and their named trade-
                    // offs) is gone with the process: the state
                    // below is read from the backend's own
                    // status, in-process.
                    val awgSnap = WgTunnelEngine.snapshot()
                    when {
                        // Gated on no live Xray session
                        // (verification iteration 1, finding 3):
                        // a late AWG Up must never mask the
                        // Xray session the walk adopted instead.
                        awgSnap.running && !XrayVpnService.running ->
                            result.success(
                                baseState + mapOf(
                                "running" to true,
                                "name" to awgSnap.name,
                                "sinceMs" to awgSnap.sinceMs,
                                "up" to awgSnap.up,
                                "down" to awgSnap.down,
                                "coreRestarts" to 0,
                                "coreProblem" to awgSnap.coreProblem,
                                "awgProblemSeq" to awgSnap.problemSeq,
                                "awgUserStopSeq" to awgSnap.userStopSeq,
                                // An AWG session has no chain
                                // and no pause (as in the 2100
                                // merge); build 2127 (H4) gives
                                // it a real kill-switch hold.
                                "chainUnderlay" to false,
                                "chainProblem" to "",
                                "awg" to true,
                                "awgHandshakeAgeSec" to
                                    awgSnap.handshakeAgeSec,
                                "awgRxBytes" to awgSnap.rxBytes,
                                "awgTxBytes" to awgSnap.txBytes,
                                "killSwitchHeld" to
                                    awgSnap.killSwitchHeld,
                                "paused" to false,
                                "userStopped" to awgSnap.userStopped,
                            ),
                        )
                        // A stopped AWG session's userStopped
                        // comes BEFORE the problem branch
                        // (verification iteration 1, finding 2):
                        // its stop funnelled through
                        // WgTunnelEngine.stop, which also clears
                        // the recorded problem — and with this
                        // order, even a lingering problem string
                        // can never reclassify a user stop as an
                        // unexpected drop that auto-reconnect
                        // would resurrect. No freshness window
                        // is needed in-process. A live Xray
                        // session keeps baseState authoritative.
                        !XrayVpnService.running && awgSnap.userStopped ->
                            result.success(
                                baseState +
                                    mapOf(
                                        "userStopped" to true,
                                        // Build 2106 (M-1): the
                                        // walk re-reads the
                                        // sequence on this
                                        // branch after its own
                                        // teardown stop.
                                        "awgUserStopSeq" to
                                            awgSnap.userStopSeq,
                                    ),
                            )
                        // A failed start or an unexpected stop:
                        // the engine holds the reason. Reported
                        // only while no Xray session is live —
                        // a live Xray session's own state stays
                        // authoritative, exactly as the 2100
                        // death branch guarded its report.
                        !XrayVpnService.running &&
                            awgSnap.coreProblem.isNotEmpty() ->
                            result.success(
                                baseState + mapOf(
                                    "running" to false,
                                    "name" to awgSnap.name,
                                    "sinceMs" to awgSnap.sinceMs,
                                    "coreProblem" to awgSnap.coreProblem,
                                    "awgProblemSeq" to awgSnap.problemSeq,
                                    "awgUserStopSeq" to awgSnap.userStopSeq,
                                    // A start failure or a drop
                                    // is never a user stop.
                                    "userStopped" to false,
                                    // Nor does it inherit a
                                    // paused/chain shape from a
                                    // previous Xray session (the
                                    // build-2100 death-branch
                                    // rule, carried over).
                                    "coreRestarts" to 0,
                                    "chainUnderlay" to false,
                                    "chainProblem" to "",
                                    // Build 2127 (H4): a drop
                                    // that raised the lockdown
                                    // reports it here.
                                    "killSwitchHeld" to
                                        awgSnap.killSwitchHeld,
                                    "paused" to false,
                                ),
                            )
                        else -> result.success(baseState)
                    }
                }
                // The EmberWarp engine (EmberWarpCore.kt, build
                // 2030): a WARP client core as a subprocess. The
                // Dart side owns the profile and builds the
                // command line; this side owns the process, the
                // identity directory and the readiness wait.
                "xraySetOnWarp" -> {
                    if (call.argument<Boolean>("on") != true) {
                        XrayVpnService.stop(this)
                        // Build 2100: dual stop — the AWG
                        // session stops too. Build 2104: it
                        // lives on the WG Tunnel backend.
                        WgTunnelEngine.stop(this)
                        result.success(null)
                    } else {
                        askForNotifications()
                        val start = {
                            XrayVpnService.startWarp(
                                this,
                                // Build 2071 (review §1.5): the
                                // EmberWarp session's fallback name
                                // matches Dart's warpSessionName —
                                // 'WARP' alone names the Aether
                                // engine in this app.
                                call.argument<String>("name") ?: "EmberWarp",
                                call.argument<String>("dns") ?: "1.1.1.1",
                                call.argument<Boolean>("ipv6") ?: true,
                                call.argument<List<String>>("warpArgs")
                                    ?: emptyList(),
                                call.argument<Int>("mtu") ?: 1500,
                                // Kill switch (build 2063, feature
                                // queue #3).
                                call.argument<Boolean>("killSwitch") ?: false,
                            )
                        }
                        // Build 2067: guarded start handoff
                        // (see startVpnGuarded).
                        startVpnGuarded(
                            result,
                            needsConsent = true,
                            park = { parkedResult, parkedStart ->
                                pendingWarpOn?.error("vpn_denied", "superseded", null)
                                pendingWarpOn = parkedResult
                                pendingWarpStart = parkedStart
                            },
                            unpark = {
                                pendingWarpOn = null
                                pendingWarpStart = null
                            },
                            start = start,
                        )
                    }
                }
                "warpStart" -> {
                    val args = call.argument<List<String>>("args") ?: emptyList()
                    val port = call.argument<Int>("port") ?: EmberWarpCore.SOCKS_PORT
                    // Build 2087 (analysis A1): an optional
                    // readiness-budget override — the chain
                    // path's registration run passes the chain
                    // grace; absent means the run's own budget.
                    val greetingWaitMs = call.argument<Int>("greetingWaitMs")
                    inBackground(result) {
                        EmberWarpCore.start(
                            this, args, port,
                            greetingWaitMs?.toLong(),
                        )
                    }
                }
                "warpStop" -> {
                    inBackground(result) {
                        EmberWarpCore.stop()
                        null
                    }
                }
                "warpState" -> {
                    inBackground(result) { EmberWarpCore.state(this) }
                }
                // The DNSTT underlay client (DnsttCore.kt,
                // build 2072): a subprocess port-forward through
                // a DNS tunnel, started by the Xray controller
                // when the chain underlay is DNSTT and reaped by
                // the VPN service's chain supervision.
                "dnsttStart" -> {
                    val args = call.argument<List<String>>("args") ?: emptyList()
                    inBackground(result) { DnsttCore.start(this, args) }
                }
                "dnsttStop" -> {
                    inBackground(result) {
                        DnsttCore.stop()
                        null
                    }
                }
                "dnsttState" -> {
                    inBackground(result) { DnsttCore.state(this) }
                }
                // The OLCRTC underlay client (OlcrtcCore.kt,
                // build 2134): a subprocess carrying TCP over
                // a WebRTC video call, started by the Xray
                // controller when the chain underlay is OLCRTC
                // and reaped by the VPN service's chain
                // supervision.
                "olcrtcStart" -> {
                    val args = call.argument<List<String>>("args") ?: emptyList()
                    inBackground(result) { OlcrtcCore.start(this, args) }
                }
                "olcrtcStop" -> {
                    inBackground(result) {
                        OlcrtcCore.stop()
                        null
                    }
                }
                "olcrtcState" -> {
                    inBackground(result) { OlcrtcCore.state(this) }
                }
                // The wstunnel client (WstunnelCore.kt, build
                // 2072): WireGuard over WebSocket — a UDP
                // forwarder started per WG session when the
                // WireGuard-over-WebSocket option is on.
                "wstunnelStart" -> {
                    val args = call.argument<List<String>>("args") ?: emptyList()
                    inBackground(result) { WstunnelCore.start(this, args) }
                }
                "wstunnelStop" -> {
                    inBackground(result) {
                        WstunnelCore.stop()
                        null
                    }
                }
                "wstunnelState" -> {
                    inBackground(result) { WstunnelCore.state(this) }
                }
                // The sing-box sidecar engine (SingBoxCore.kt,
                // build 2075): TUIC / Snell / NaiveProxy
                // outbounds and the Tailscale / OpenConnect
                // endpoints the Xray core cannot speak. The
                // Dart side writes filesDir/singbox/config.json
                // and passes `run -c <path>`; the Xray tunnel
                // dials its local mixed inbound as a SOCKS
                // proxy outbound.
                "singboxStart" -> {
                    val args = call.argument<List<String>>("args") ?: emptyList()
                    inBackground(result) { SingBoxCore.start(this, args) }
                }
                "singboxStop" -> {
                    inBackground(result) {
                        SingBoxCore.stop()
                        null
                    }
                }
                "singboxState" -> {
                    inBackground(result) { SingBoxCore.state(this) }
                }
                // The Sudoku engine (SudokuBoxCore.kt,
                // build 2127): Hiddify's sing-box fork as
                // its own binary — see that file.
                "sudokuBoxStart" -> {
                    val args = call.argument<List<String>>("args") ?: emptyList()
                    inBackground(result) { SudokuBoxCore.start(this, args) }
                }
                "sudokuBoxStop" -> {
                    inBackground(result) {
                        SudokuBoxCore.stop()
                        null
                    }
                }
                "sudokuBoxState" -> {
                    inBackground(result) { SudokuBoxCore.state(this) }
                }
                // The Zapret desync proxy (ZapretCore.kt,
                // build 2127, H1): ciadpi — a userspace
                // SOCKS5 proxy the DPI Lab's zap candidates
                // and their connects chain through. Start
                // carries the full command line (loopback
                // listen + the candidate's desync flags,
                // built by zapret_args.dart); no config
                // file is involved.
                "zapretStart" -> {
                    val args = call.argument<List<String>>("args") ?: emptyList()
                    inBackground(result) { ZapretCore.start(this, args) }
                }
                "zapretStop" -> {
                    inBackground(result) {
                        ZapretCore.stop()
                        null
                    }
                }
                "zapretState" -> {
                    inBackground(result) { ZapretCore.state(this) }
                }
                // The Senpai scanner (SenpaiCore.kt, build
                // 2129, Leg 3): a JSON-lines bridge — start
                // carries the full request JSON built by
                // senpai.dart; stop asks the scanner to save
                // its resumable state; state is polled.
                "senpaiStart" -> {
                    val request = call.argument<String>("request") ?: ""
                    inBackground(result) { SenpaiCore.start(this, request) }
                }
                "senpaiStop" -> {
                    inBackground(result) {
                        SenpaiCore.stop()
                        null
                    }
                }
                "senpaiState" -> {
                    inBackground(result) { SenpaiCore.state(this) }
                }
                // The Mieru client (MieruCore.kt, build
                // 2075): its own upstream client — sing-box
                // has no Mieru outbound. Start carries the
                // full client config JSON; the core applies
                // it (`replace config`) before spawning the
                // foreground daemon.
                "mieruStart" -> {
                    val config = call.argument<String>("config") ?: ""
                    inBackground(result) {
                        MieruCore.startWithConfig(this, config)
                    }
                }
                "mieruStop" -> {
                    inBackground(result) {
                        MieruCore.stop()
                        null
                    }
                }
                "mieruState" -> {
                    inBackground(result) { MieruCore.state(this) }
                }
                // The DNSCrypt proxy (DnsCryptCore.kt, build
                // 2075): a local encrypted-DNS resolver the
                // Xray DNS settings can select as a transport.
                // The Dart side writes the TOML config and
                // passes `-config <path>`.
                "dnscryptStart" -> {
                    val args = call.argument<List<String>>("args") ?: emptyList()
                    inBackground(result) { DnsCryptCore.start(this, args) }
                }
                "dnscryptStop" -> {
                    inBackground(result) {
                        DnsCryptCore.stop()
                        null
                    }
                }
                "dnscryptState" -> {
                    inBackground(result) { DnsCryptCore.state(this) }
                }
                "warpRenew" -> {
                    // The ONLY identity renewal path (build
                    // 2030, dossier Q1): explicit, user-tapped,
                    // staged + settled. Blocking — background.
                    val kind = call.argument<String>("kind") ?: "masque"
                    inBackground(result) { EmberWarpCore.renew(this, kind) }
                }
                "warpResetIdentity" -> {
                    inBackground(result) {
                        EmberWarpCore.resetIdentity(this)
                        null
                    }
                }
                "warpSettle" -> {
                    inBackground(result) {
                        EmberWarpCore.settle(this)
                        null
                    }
                }
                // The ralysnd Aether engines (AetherCore.kt, build
                // 2032): slots "cfwarp" (standalone WARP, SOCKS
                // 20870) and "masque" (MASQUE / WG / WARP-in-WARP,
                // SOCKS 20810), taken as they are from the ralysnd
                // app. The Dart side owns options + flow; this side
                // owns the process, identity and stage parsing.
                "aetherStart" -> {
                    val slot = AetherCore.slot(
                        call.argument<String>("engine") ?: "masque",
                    )
                    val options = AetherRunOptions(
                        protocol = call.argument<String>("protocol") ?: "masque",
                        scan = call.argument<String>("scan") ?: "turbo",
                        ip = call.argument<String>("ip") ?: "v4",
                        transport = call.argument<String>("transport") ?: "auto",
                        ech = call.argument<String>("ech") ?: "",
                        fragment = call.argument<Boolean>("fragment") ?: false,
                        noize = call.argument<String>("noize") ?: "",
                        keepalive = call.argument<Int>("keepalive") ?: 25,
                        peer = call.argument<String>("peer"),
                    )
                    inBackground(result) { slot.start(this, options) }
                }
                "aetherConnectMasque" -> {
                    // Build 2083: the MASQUE carrier ladder —
                    // ONE call that walks the rungs (engine
                    // start → CONNECTED → warp trace → data
                    // proof per rung) until one carries data.
                    // Blocking for the whole walk (minutes on a
                    // cold first connect): background, like the
                    // registration ladder.
                    val slot = AetherCore.slot(
                        call.argument<String>("engine") ?: "masque",
                    )
                    val options = AetherRunOptions(
                        protocol = call.argument<String>("protocol") ?: "masque",
                        scan = call.argument<String>("scan") ?: "turbo",
                        ip = call.argument<String>("ip") ?: "v4",
                        transport = call.argument<String>("transport") ?: "auto",
                        ech = call.argument<String>("ech") ?: "",
                        fragment = call.argument<Boolean>("fragment") ?: false,
                        noize = call.argument<String>("noize") ?: "",
                        keepalive = call.argument<Int>("keepalive") ?: 25,
                        peer = call.argument<String>("peer"),
                    )
                    inBackground(result) { slot.connectMasque(this, options) }
                }
                "aetherStop" -> {
                    val slot = AetherCore.slot(
                        call.argument<String>("engine") ?: "masque",
                    )
                    inBackground(result) {
                        slot.stop()
                        null
                    }
                }
                "aetherState" -> {
                    val slot = AetherCore.slot(
                        call.argument<String>("engine") ?: "masque",
                    )
                    inBackground(result) { slot.state(this) }
                }
                "aetherEnsureIdentity" -> {
                    // Blocking (the registration ladder): background.
                    val slot = AetherCore.slot(
                        call.argument<String>("engine") ?: "masque",
                    )
                    val protocol = call.argument<String>("protocol") ?: "masque"
                    inBackground(result) { slot.ensureIdentity(this, protocol) }
                }
                "aetherResetIdentity" -> {
                    val slot = AetherCore.slot(
                        call.argument<String>("engine") ?: "masque",
                    )
                    inBackground(result) {
                        slot.resetIdentity(this)
                        null
                    }
                }
                "aetherTrace" -> {
                    // One Cloudflare trace through the slot's
                    // SOCKS (warp=on is the connect proof).
                    val slot = AetherCore.slot(
                        call.argument<String>("engine") ?: "cfwarp",
                    )
                    inBackground(result) { slot.trace() }
                }
                "aetherDataProbe" -> {
                    // Build 2080: real transfers through the
                    // slot's SOCKS (the CfDataProbe port) — the
                    // MASQUE connect's data-plane gate. Blocking
                    // up to ~45 s: background, like the trace.
                    val slot = AetherCore.slot(
                        call.argument<String>("engine") ?: "masque",
                    )
                    inBackground(result) { slot.dataProbe() }
                }
                "socksTunSetOn" -> {
                    // TUN for an Aether slot, VPN consent like
                    // xraySetOnWarp (build 2032).
                    if (call.argument<Boolean>("on") != true) {
                        XrayVpnService.stop(this)
                        // Build 2100: dual stop — the AWG
                        // session stops too. Build 2104: it
                        // lives on the WG Tunnel backend.
                        WgTunnelEngine.stop(this)
                        result.success(null)
                    } else {
                        askForNotifications()
                        val start = {
                            XrayVpnService.startSocks(
                                this,
                                call.argument<String>("name") ?: "WARP",
                                call.argument<String>("dns") ?: "1.1.1.1",
                                call.argument<Boolean>("ipv6") ?: true,
                                call.argument<Int>("socksPort") ?: 0,
                                call.argument<String>("engine") ?: "",
                                call.argument<Int>("mtu") ?: 1500,
                                // Kill switch (build 2063, feature
                                // queue #3).
                                call.argument<Boolean>("killSwitch") ?: false,
                            )
                        }
                        // Build 2067: guarded start handoff
                        // (see startVpnGuarded).
                        startVpnGuarded(
                            result,
                            needsConsent = true,
                            park = { parkedResult, parkedStart ->
                                pendingWarpOn?.error("vpn_denied", "superseded", null)
                                pendingWarpOn = parkedResult
                                pendingWarpStart = parkedStart
                            },
                            unpark = {
                                pendingWarpOn = null
                                pendingWarpStart = null
                            },
                            start = start,
                        )
                    }
                }
                "xrayEndurance" -> {
                    // The endurance qualification (build 2029A):
                    // probes at 0/+2.5/+5.4 s on ONE connection.
                    val config = call.argument<String>("config") ?: ""
                    inBackground(result) { XrayTester.endurance(this, config) }
                }
                "networkFingerprint" -> {
                    // Winning-shape cache key material (build
                    // 2029A): connectivity type + operator name.
                    // Neither needs a permission: the transports
                    // are public, and networkOperatorName is the
                    // connected network's operator (not the SIM
                    // serial family).
                    val cm = getSystemService(android.net.ConnectivityManager::class.java)
                    val caps = cm?.activeNetwork?.let { cm.getNetworkCapabilities(it) }
                    val type = when {
                        caps == null -> "none"
                        caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                        caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                        caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                        else -> "other"
                    }
                    val operator = try {
                        (getSystemService(android.telephony.TelephonyManager::class.java)
                            ?.networkOperatorName ?: "")
                    } catch (e: Exception) {
                        ""
                    }
                    result.success(mapOf("type" to type, "operator" to operator))
                }
                "xrayValidateConfig" -> {
                    val config = call.argument<String>("config") ?: ""
                    inBackground(result) { XrayTester.validateConfig(this, config) }
                }
                "xrayTunnelCheck" -> {
                    // The adaptive failover's health probe: one real
                    // request through the live tunnel's SOCKS port.
                    // LAN sharing (build 2062): the credentials
                    // for a password-protected inbound.
                    val port = call.argument<Int>("socksPort") ?: 10808
                    val user = call.argument<String>("socksUser") ?: ""
                    val pass = call.argument<String>("socksPass") ?: ""
                    inBackground(result) { XrayTester.tunnelCheck(port, user, pass) }
                }
                "xrayMeasureDelayEx" -> {
                    val config = call.argument<String>("config") ?: ""
                    // Build 2101 (S5): rounds/budgetMs ride along
                    // for the bulk Test-All pass; absent args keep
                    // the single-test defaults.
                    // Build 2109: timeoutMs rides along too — the
                    // delay-test timeout setting; absent keeps the
                    // fixed 8000 ms of every build ≤2108.
                    val rounds = call.argument<Int>("rounds") ?: 2
                    val budgetMs = (call.argument<Int>("budgetMs") ?: 0).toLong()
                    val timeoutMs = call.argument<Int>("timeoutMs") ?: 8000
                    inBackground(result) {
                        XrayTester.measureDelayEx(
                            this, config, rounds, budgetMs, timeoutMs,
                        )
                    }
                }
                "xraySpeedTest" -> {
                    val config = call.argument<String>("config") ?: ""
                    inBackground(result) { XrayTester.speedTest(this, config) }
                }
                "xraySpeedTestUp" -> {
                    // Build 2149: the upload mirror of the
                    // download speed test (per-config node
                    // diagnostics).
                    val config = call.argument<String>("config") ?: ""
                    inBackground(result) { XrayTester.speedTestUp(this, config) }
                }
                "xraySandboxTest" -> {
                    // The sandbox config test (build 2061,
                    // feature queue #1): one throwaway core
                    // proves delay + hold + exit on a free
                    // port, without touching the live tunnel.
                    // Build 2109: timeoutMs rides along — the
                    // delay-test timeout setting; absent keeps
                    // the fixed 8000 ms of every build ≤2108.
                    val config = call.argument<String>("config") ?: ""
                    val timeoutMs = call.argument<Int>("timeoutMs") ?: 8000
                    inBackground(result) {
                        XrayTester.sandboxTest(this, config, timeoutMs)
                    }
                }
                "xrayServiceCheck" -> {
                    // The proxied service reachability check
                    // (build 2091): one throwaway core asks
                    // each host for a real HTTPS HEAD through
                    // the config, on a free port, without
                    // touching the live tunnel.
                    val config = call.argument<String>("config") ?: ""
                    @Suppress("UNCHECKED_CAST")
                    val hosts =
                        (call.argument<List<Any>>("hosts") ?: emptyList())
                            .mapNotNull { it as? String }
                    inBackground(result) {
                        XrayTester.serviceCheck(this, config, hosts)
                    }
                }
                "xrayDnsPing" -> {
                    // Per-server DNS ping (build 2149, owner
                    // refinement of expansion 2): every DNS
                    // server a config lists, asked one real
                    // query through the config itself and timed
                    // individually. Three modes on one method:
                    // a config (throwaway instance, the live
                    // tunnel untouched), a live SOCKS port
                    // (the connected config's own tunnel), or
                    // direct (no tunnel — the preset picker's
                    // Test all while disconnected).
                    val mode = call.argument<String>("mode") ?: "config"
                    @Suppress("UNCHECKED_CAST")
                    val servers =
                        (call.argument<List<Any>>("servers") ?: emptyList())
                            .mapNotNull { it as? String }
                    val timeoutMs = call.argument<Int>("timeoutMs") ?: 5000
                    when (mode) {
                        "port" -> {
                            val port = call.argument<Int>("socksPort") ?: 10808
                            val user = call.argument<String>("socksUser") ?: ""
                            val pass = call.argument<String>("socksPass") ?: ""
                            inBackground(result) {
                                XrayTester.dnsPingViaPort(
                                    port, user, pass, servers, timeoutMs,
                                )
                            }
                        }
                        "direct" -> inBackground(result) {
                            XrayTester.dnsPingDirect(servers, timeoutMs)
                        }
                        else -> {
                            val config = call.argument<String>("config") ?: ""
                            inBackground(result) {
                                XrayTester.dnsPingViaConfig(
                                    this, config, servers, timeoutMs,
                                )
                            }
                        }
                    }
                }
                "xrayExitInfo" -> {
                    // Best-effort: the exit IP/country of the running
                    // V2Ray tunnel, asked through the tunnel itself.
                    // LAN sharing (build 2062): the credentials
                    // for a password-protected inbound.
                    val port = call.argument<Int>("socksPort") ?: 10808
                    val user = call.argument<String>("socksUser") ?: ""
                    val pass = call.argument<String>("socksPass") ?: ""
                    inBackground(result) { XrayTester.exitInfo(port, user, pass) }
                }
                "xrayStats" -> {
                    // The running core's per-outbound traffic deltas
                    // (its own stats API), for per-config accounting.
                    val port = call.argument<Int>("apiPort") ?: 0
                    inBackground(result) { XrayTester.trafficStats(this, port) }
                }
                // The Psiphon engine (PsiphonVpnService.kt): its VPN
                // mode asks for the VPN permission like the others;
                // proxy-only mode needs none.
                "psiphonSetOn" -> {
                    if (call.argument<Boolean>("on") != true) {
                        PsiphonVpnService.stop(this)
                        result.success(null)
                    } else {
                        // Build 2068: breadcrumbs down the whole
                        // Psiphon start path (see CrashLog) — the
                        // last one in crash.log names the dying
                        // step, even for a native abort no Java
                        // handler can capture.
                        CrashLog.breadcrumb(this, "psiphon:handler-entered")
                        askForNotifications()
                        CrashLog.breadcrumb(this, "psiphon:notifications-returned")
                        val start = {
                            CrashLog.breadcrumb(this, "psiphon:start-invoked")
                            PsiphonVpnService.start(
                                this,
                                call.argument<Boolean>("vpnMode") ?: true,
                                call.argument<String>("region") ?: "",
                                call.argument<String>("upstream") ?: "",
                                call.argument<List<String>>("protocols") ?: emptyList(),
                                call.argument<String>("dns") ?: "1.1.1.1",
                                call.argument<Int>("mtu") ?: 1500,
                                // Build 2057 (audit F-M4): thread the Dart
                                // 'ipv6' extra — the service defaults to
                                // true (old capture-everything behaviour).
                                call.argument<Boolean>("ipv6") ?: true,
                                // Build 2065: the strategy ladder inputs;
                                // absent = legacy single attempt.
                                call.argument<List<String>>("rungs") ?: emptyList(),
                                call.argument<String>("compartment") ?: "",
                                call.argument<List<String>>("cleanAkamai") ?: emptyList(),
                                call.argument<List<String>>("cleanFastly") ?: emptyList(),
                                call.argument<Boolean>("disableTimeouts") ?: false,
                                // Build 2069: no 'beast' argument —
                                // Beast Mode was withdrawn with the
                                // core transplant (see
                                // PsiphonVpnService.buildConfig);
                                // no 'edgeOverrides' either — the
                                // dial-override channel belonged to
                                // the fork core, and tested edges
                                // now travel as the clean-IP lists.
                                call.argument<Boolean>("cdnFront") ?: false,
                                // Build 2125 (A25-04 / S-4):
                                // the kill switch.
                                call.argument<Boolean>("killSwitch") ?: false,
                                // Build 2129 (Leg 2): the Shiro
                                // bootstrap + strong mode —
                                // absent = false = 2128 behaviour.
                                call.argument<Boolean>("shiroBootstrap") ?: false,
                                call.argument<Boolean>("strongMode") ?: false,
                            )
                            CrashLog.breadcrumb(this, "psiphon:start-returned")
                        }
                        val vpnMode = call.argument<Boolean>("vpnMode") ?: true
                        // Build 2067: the whole start handoff
                        // (prepare, consent round-trip, deferred
                        // or direct service start) runs guarded —
                        // see startVpnGuarded. Proxy-only mode
                        // needs no consent, as before.
                        startVpnGuarded(
                            result,
                            needsConsent = vpnMode,
                            park = { parkedResult, parkedStart ->
                                pendingPsiphonOn?.error("vpn_denied", "superseded", null)
                                pendingPsiphonOn = parkedResult
                                pendingPsiphonStart = parkedStart
                            },
                            unpark = {
                                pendingPsiphonOn = null
                                pendingPsiphonStart = null
                            },
                            start = start,
                            breadcrumbPrefix = "psiphon",
                        )
                    }
                }
                "psiphonStop" -> {
                    PsiphonVpnService.stop(this)
                    result.success(null)
                }
                "psiphonExternalWatchdog" -> {
                    // Build 2088: the main process's wedge net
                    // for the :psiphon process. 2087's device
                    // verdict proved the wedged process cannot
                    // record or end its own wedge (its watchdog
                    // never wrote), so the Dart connect path's
                    // deadline fires THIS: find the process,
                    // dump its threads from /proc into
                    // crash.log, kill it, publish the failure.
                    // See PsiphonExternalWatchdog.
                    inBackground(result) { PsiphonExternalWatchdog.fire(this) }
                }
                // Build 2065: network identity for the per-network
                // winner memory + auto-connect triggers.
                "networkInfo" -> {
                    result.success(networkInfoMap())
                }
                // Build 2065: reads and clears the boot flag
                // BootReceiver recorded.
                "consumeBootPending" -> {
                    val prefs = getSharedPreferences(
                        BootReceiver.PREFS, android.content.Context.MODE_PRIVATE,
                    )
                    val pending = prefs.getBoolean(BootReceiver.KEY_BOOT_PENDING, false)
                    if (pending) {
                        prefs.edit().putBoolean(BootReceiver.KEY_BOOT_PENDING, false).apply()
                    }
                    result.success(pending)
                }
                "psiphonState" -> {
                    // Build 2073: the service runs in its own
                    // process (:psiphon), so its companion statics
                    // live there, not here. The state arrives via
                    // the snapshot the service publishes to its
                    // state file on every change — same map shape
                    // (incl. build 2065's winning ladder rung,
                    // "method") this handler has always returned.
                    result.success(PsiphonVpnService.publishedState(this))
                }
                "psiphonExitInfo" -> {
                    // Best-effort: the exit IP/country of the running
                    // Psiphon tunnel, asked through its SOCKS proxy.
                    inBackground(result) { XrayTester.exitInfo(PsiphonConstants.SOCKS_PORT) }
                }
                // The Lantern engine (LanternVpnService.kt):
                // build 2129 — the official client's gomobile
                // core in the :lantern process; state arrives
                // via the service's published snapshot.
                "lanternSetOn" -> {
                    if (call.argument<Boolean>("on") != true) {
                        LanternVpnService.stop(this)
                        result.success(null)
                    } else {
                        askForNotifications()
                        val start = {
                            LanternVpnService.start(
                                this,
                                call.argument<Boolean>("ipv6") ?: true,
                                call.argument<Int>("mtu") ?: 1500,
                                call.argument<String>("dns") ?: "1.1.1.1",
                                // Build 2125 (A25-04): the
                                // kill switch.
                                call.argument<Boolean>("killSwitch") ?: false,
                                // Build 2129: the picked server
                                // ("" = automatic).
                                call.argument<String>("tag") ?: "",
                                // Build 2149 (audit A43-09):
                                // the pinned private server's
                                // stored identity.
                                call.argument<String>("pinCountry") ?: "",
                                call.argument<String>("pinCode") ?: "",
                                // Build 2149 (audit A43-27):
                                // the stored smart-routing
                                // choice, applied after init.
                                call.argument<Boolean>("smartOn") ?: false,
                            )
                        }
                        // Build 2067: guarded start handoff
                        // (see startVpnGuarded).
                        startVpnGuarded(
                            result,
                            needsConsent = true,
                            park = { parkedResult, parkedStart ->
                                pendingLanternOn?.error("vpn_denied", "superseded", null)
                                pendingLanternOn = parkedResult
                                pendingLanternStart = parkedStart
                            },
                            unpark = {
                                pendingLanternOn = null
                                pendingLanternStart = null
                            },
                            start = start,
                        )
                    }
                }
                "lanternStop" -> {
                    LanternVpnService.stop(this)
                    result.success(null)
                }
                "lanternState" -> {
                    // Build 2129: the service runs in its own
                    // process (:lantern), so its state arrives
                    // via the snapshot it publishes to its state
                    // file on every change (the psiphonState
                    // shape). "available" is answered here: the
                    // renamed gomobile library in nativeLibraryDir.
                    val published = LanternStateStore.publishedState(this)
                    result.success(
                        published + mapOf(
                            "available" to java.io.File(
                                applicationInfo.nativeLibraryDir,
                                "liblantern_gojni.so",
                            ).exists(),
                            // The core counts as running when a
                            // session runs or a snapshot claims
                            // one; the gomobile core has no
                            // separate process to probe.
                            "coreRunning" to (published["running"] == true ||
                                published["connected"] == true),
                        ),
                    )
                }
                "lanternFetchServers" -> {
                    // Build 2129: asks the :lantern process to
                    // initialize the core and publish its server
                    // list (Mobile.getAvailableServers through
                    // the bridge). Replaces the CLI era's list
                    // and control-plane channels, which died
                    // with the subprocess contract they drove.
                    LanternVpnService.fetchInfo(this)
                    result.success(null)
                }
                "lanternSetSmartRouting" -> {
                    LanternVpnService.setSmartRouting(
                        this,
                        call.argument<Boolean>("on") ?: false,
                    )
                    result.success(null)
                }
                "lanternAddPrivateServer" -> {
                    LanternVpnService.addPrivateServer(
                        this,
                        call.argument<String>("ip") ?: "",
                        call.argument<Int>("port") ?: 8080,
                        call.argument<String>("token") ?: "",
                        call.argument<String>("tag") ?: "",
                    )
                    result.success(null)
                }
                "lanternRemovePrivateServer" -> {
                    LanternVpnService.removePrivateServer(
                        this,
                        call.argument<String>("tag") ?: "",
                    )
                    result.success(null)
                }
                "lanternSwitch" -> {
                    // Build 2131: live server switch — the
                    // running :lantern session re-selects the
                    // given tag ("" = automatic) inside the
                    // live tunnel; no TUN rebuild.
                    // Build 2149 (audit A43-09): the pin
                    // identity rides along, as on the start.
                    LanternVpnService.switchServer(
                        this,
                        call.argument<String>("tag") ?: "",
                        call.argument<String>("pinCountry") ?: "",
                        call.argument<String>("pinCode") ?: "",
                    )
                    result.success(null)
                }
                // The OpenVPN engine (OpenVpnService.kt): the
                // OpenVPN 3 core rebuilt from source behind Ember's
                // own JNI bridge; profiles are generic .ovpn text.
                "openVpnSetOn" -> {
                    if (call.argument<Boolean>("on") != true) {
                        OpenVpnService.stop(this)
                        result.success(null)
                    } else {
                        askForNotifications()
                        val start = {
                            OpenVpnService.start(
                                this,
                                call.argument<String>("profileId") ?: "",
                                call.argument<String>("name") ?: "",
                                call.argument<String>("config") ?: "",
                                call.argument<String>("credKey") ?: "",
                                call.argument<String>("user") ?: "",
                                call.argument<String>("pass") ?: "",
                                call.argument<Boolean>("needsCreds") ?: false,
                                // Build 2125 (A25-04): the
                                // kill switch.
                                call.argument<Boolean>("killSwitch") ?: false,
                            )
                        }
                        // Build 2067: guarded start handoff
                        // (see startVpnGuarded).
                        startVpnGuarded(
                            result,
                            needsConsent = true,
                            park = { parkedResult, parkedStart ->
                                pendingOpenVpnOn?.error("vpn_denied", "superseded", null)
                                pendingOpenVpnOn = parkedResult
                                pendingOpenVpnStart = parkedStart
                            },
                            unpark = {
                                pendingOpenVpnOn = null
                                pendingOpenVpnStart = null
                            },
                            start = start,
                        )
                    }
                }
                "openVpnStop" -> {
                    OpenVpnService.stop(this)
                    result.success(null)
                }
                "openVpnState" -> {
                    // Build 2030 (defect C audit): the trail
                    // reads are disk IO — the whole state build
                    // leaves the main thread.
                    inBackground(result) {
                        mapOf(
                            "available" to OpenVpnNative.available(this),
                            "running" to OpenVpnService.running,
                            "connected" to (OpenVpnService.running &&
                                OpenVpnCore.phase == "connected"),
                            "phase" to OpenVpnCore.phase,
                            "profileId" to OpenVpnCore.profileId,
                            "profileName" to OpenVpnCore.profileName,
                            "sinceMs" to OpenVpnService.startedAtMs,
                            "up" to OpenVpnCore.upBytes,
                            "down" to OpenVpnCore.downBytes,
                            "exitIp" to OpenVpnCore.exitIp,
                            "exitCountry" to OpenVpnCore.exitCountry,
                            "exitCode" to OpenVpnCore.exitCode,
                            // Build 2125 (audit A25-25): the
                            // session's IPv6 capture verdict.
                            "ipv6Captured" to (OpenVpnService.running &&
                                OpenVpnService.ipv6Captured),
                            // Build 2125 (A25-04): the
                            // kill-switch hold flag (NOT gated
                            // on running — the hold is exactly
                            // the not-running state).
                            "killSwitchHeld" to OpenVpnService.killSwitchHeld,
                            "error" to OpenVpnCore.error,
                            "logTail" to OpenVpnCore.logTail(),
                            // Build 2026 crash visibility: the
                            // previous session's final breadcrumb
                            // stage (+ whether it ended without a
                            // clean stop) and the system's own
                            // record of how the last process died.
                            "lastStage" to (if (OpenVpnService.running) {
                                ""
                            } else {
                                OpenVpnTrace.lastSession(this).first
                            }),
                            "lastUnclean" to (if (OpenVpnService.running) {
                                false
                            } else {
                                OpenVpnTrace.lastSession(this).second
                            }),
                            // Build 2028: the last session's
                            // exception text, when its trail
                            // holds a terminate / run_exception
                            // crumb — shown on the diagnostics
                            // card, not only in the file.
                            "lastException" to (if (OpenVpnService.running) {
                                ""
                            } else {
                                OpenVpnTrace.lastException(this)
                            }),
                            "lastExitReason" to lastExitReasonText(),
                        )
                    }
                }
                "openVpnValidate" -> {
                    val config = call.argument<String>("config") ?: ""
                    inBackground(result) {
                        if (!OpenVpnNative.available(this)) {
                            "CORE_UNAVAILABLE"
                        } else {
                            OpenVpnNative.setBreadcrumbFile(
                                OpenVpnTrace.file(this).absolutePath,
                            )
                            OpenVpnNative.evaluate(config)
                        }
                    }
                }
                "openVpnPing" -> {
                    val host = call.argument<String>("host") ?: ""
                    val port = call.argument<Int>("port") ?: 443
                    val proto = call.argument<String>("proto") ?: "udp"
                    val authCtl = call.argument<Boolean>("authenticatedControl") ?: false
                    inBackground(result) {
                        OpenVpnProbe.measure(host, port, proto, authCtl)
                    }
                }
                "openVpnPickFile" -> {
                    // Build 2098 (post-2097 audit M9): a second
                    // pick no longer supersedes the first — the
                    // new call answers "busy" (the Dart side
                    // treats it as a benign no-op, like a cancel)
                    // and the pending slot and its future stay
                    // completely untouched, so the first pick's
                    // file can never be delivered to the second
                    // call. Same pattern pickImageFile already
                    // used.
                    if (pendingPick != null) {
                        result.error("busy", "an OpenVPN file pick is already open", null)
                    } else {
                        pendingPick = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                        }
                        try {
                            startActivityForResult(intent, PICK_REQUEST)
                        } catch (e: Exception) {
                            pendingPick = null
                            result.error("pick_failed", e.message, null)
                        }
                    }
                }
                "pickTextFile" -> {
                    // Build 2050: the generic text-file pick (a
                    // WireGuard .conf today). Same contract as the
                    // OpenVPN pick — {name, content} or null on
                    // cancel — on its own request code and result,
                    // so the two flows can never cross answers.
                    // Build 2098 (post-2097 audit M9): no
                    // supersede — a second pick answers "busy"
                    // and leaves the pending slot untouched,
                    // exactly like pickImageFile (see
                    // openVpnPickFile above).
                    if (pendingTextPick != null) {
                        result.error("busy", "a text file pick is already open", null)
                    } else {
                        pendingTextPick = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                        }
                        try {
                            startActivityForResult(intent, PICK_TEXT_REQUEST)
                        } catch (e: Exception) {
                            pendingTextPick = null
                            result.error("pick_failed", e.message, null)
                        }
                    }
                }
                "pickImageFile" -> {
                    if (pendingImagePick != null) {
                        result.error("busy", "an image pick is already open", null)
                    } else {
                        pendingImagePick = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "image/*"
                        }
                        // Build 2098 (post-2097 audit M7): the
                        // launch is guarded like its sibling
                        // pickers — an unguarded throw used to
                        // leave pendingImagePick set with no
                        // result ever delivered, so the Dart
                        // side's SystemUiFlight never ended and
                        // the app never re-locked for the rest
                        // of the session.
                        try {
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, PICK_IMAGE_REQUEST)
                        } catch (e: Exception) {
                            pendingImagePick = null
                            result.error("pick_failed", e.message, null)
                        }
                    }
                }
            "shareText" -> {
                    // Build 2095 (V2Ray journey audit #20):
                    // the system share sheet for the backup
                    // JSON — clipboard was the only way out.
                    val text = call.argument<String>("text") ?: ""
                    val title = call.argument<String>("title") ?: ""
                    val intent = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, text)
                        if (title.isNotEmpty()) {
                            putExtra(Intent.EXTRA_SUBJECT, title)
                        }
                    }
                    try {
                        startActivity(
                            Intent.createChooser(
                                intent,
                                title.ifEmpty { "Share" },
                            ),
                        )
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("share_failed", e.message, null)
                    }
                }
                "saveTextFile" -> {
                    // Build 2095 (V2Ray journey audit #19):
                    // the backup as a real file, placed by
                    // the user through the document creator.
                    // Build 2098 (post-2097 audit M9): no
                    // supersede — a second save answers "busy"
                    // and leaves the pending slot (and its
                    // content) untouched, exactly like
                    // pickImageFile (see openVpnPickFile above).
                    if (pendingSave != null) {
                        result.error("busy", "a file save is already open", null)
                    } else {
                        pendingSave = result
                        pendingSaveContent = call.argument<String>("content") ?: ""
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/json"
                            putExtra(
                                Intent.EXTRA_TITLE,
                                call.argument<String>("name") ?: "ember-backup.json",
                            )
                        }
                        try {
                            startActivityForResult(intent, SAVE_REQUEST)
                        } catch (e: Exception) {
                            pendingSave = null
                            result.error("save_failed", e.message, null)
                        }
                    }
                }
                "openVpnSaveCredentials" -> {
                    val key = call.argument<String>("key") ?: ""
                    val user = call.argument<String>("user") ?: ""
                    val pass = call.argument<String>("pass") ?: ""
                    // Build 2030 (defect C audit): Keystore work
                    // leaves the main thread; the error path is
                    // preserved (inBackgroundErr).
                    inBackgroundErr(result, "vault_failed") {
                        // Build 2027: success means the entry
                        // was written AND read back decrypted —
                        // the UI confirms only a verified save.
                        key.isNotEmpty() &&
                            OpenVpnVault.saveVerified(this, key, user, pass)
                    }
                }
                "openVpnHasCredentials" -> {
                    val key = call.argument<String>("key") ?: ""
                    inBackground(result) {
                        // Build 2027: true only when the stored
                        // entry actually decrypts (see the vault's
                        // status), never for mere file presence.
                        key.isNotEmpty() &&
                            OpenVpnVault.status(this, key) ==
                            OpenVpnVault.CredStatus.OK
                    }
                }
                "openVpnCredentialStatus" -> {
                    val key = call.argument<String>("key") ?: ""
                    inBackground(result) {
                        when (
                            if (key.isEmpty()) {
                                OpenVpnVault.CredStatus.NONE
                            } else {
                                OpenVpnVault.status(this, key)
                            }
                        ) {
                            OpenVpnVault.CredStatus.OK -> "ok"
                            OpenVpnVault.CredStatus.UNREADABLE -> "unreadable"
                            OpenVpnVault.CredStatus.NONE -> "none"
                        }
                    }
                }
                "openVpnDeleteCredentials" -> {
                    val key = call.argument<String>("key") ?: ""
                    inBackground(result) {
                        if (key.isNotEmpty()) OpenVpnVault.delete(this, key)
                        null
                    }
                }
                // Build 2116 (B7-1): the native VPN-slot
                // claim (EngineClaim) — the shell reads the
                // owner on foreground to re-arbitrate, and
                // clears a marker whose engine is not live.
                "engineClaimOwner" -> {
                    result.success(EngineClaim.owner(this))
                }
                "engineClaimClear" -> {
                    EngineClaim.clear(this)
                    result.success(true)
                }
                // Build 2125 (audit A25-17 / P-24): the
                // shell corrects a STALE marker to name the
                // engine its own live-state evidence says is
                // actually running — a rewrite, never a
                // displacement (see EngineClaim.rewrite).
                "engineClaimRewrite" -> {
                    val name = call.argument<String>("name") ?: ""
                    if (name.isNotEmpty()) EngineClaim.rewrite(this, name)
                    result.success(true)
                }
                // Build 2116 (E-7): generic Keystore-backed
                // secrets (the GitHub sync token) — the
                // vault's single-value entries.
                "secretStore" -> {
                    val key = call.argument<String>("key") ?: ""
                    val value = call.argument<String>("value") ?: ""
                    inBackgroundErr(result, "vault_failed") {
                        if (key.isNotEmpty()) {
                            OpenVpnVault.saveSecret(this, key, value)
                        }
                        true
                    }
                }
                "secretLoad" -> {
                    val key = call.argument<String>("key") ?: ""
                    inBackground(result) {
                        if (key.isEmpty()) {
                            null
                        } else {
                            OpenVpnVault.loadSecret(this, key)
                        }
                    }
                }
                "secretDelete" -> {
                    val key = call.argument<String>("key") ?: ""
                    inBackground(result) {
                        if (key.isNotEmpty()) OpenVpnVault.deleteSecret(this, key)
                        null
                    }
                }
                // The phone's main processor type (arm64-v8a, armeabi-v7a, ...).
                "abi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull() ?: "")
                "openUrl" -> {
                    val url = call.argument<String>("url") ?: ""
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                        result.success(true)
                    } catch (e: ActivityNotFoundException) {
                        result.success(false)
                    }
                }
                // Build 2075: the in-app updater's install leg.
                // The Dart side downloads the new APK into the
                // app's own files dir; installing it needs a
                // FileProvider URI (a raw file:// URI is refused
                // on modern Android) and, on Android 8+, the
                // per-app "install unknown apps" grant, which has
                // its own settings page.
                "canInstallPackages" -> {
                    result.success(
                        Build.VERSION.SDK_INT < 26 ||
                            packageManager.canRequestPackageInstalls()
                    )
                }
                "openInstallSettings" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= 26) {
                            startActivity(
                                Intent(
                                    android.provider.Settings
                                        .ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName"),
                                )
                            )
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        CrashLog.append(this, "openInstallSettings", e)
                        result.success(false)
                    }
                }
                // Build 2098 (Item C): the installed package's
                // own versionCode, for the updater. The Dart
                // side used to trust only the APP_BUILD dart
                // define; a build recipe that ever forgot the
                // define would silently compare releases
                // against the stale default (2071) — the
                // package's own number cannot go missing.
                "appBuildNumber" -> {
                    try {
                        val info = packageManager.getPackageInfo(packageName, 0)
                        val code = if (android.os.Build.VERSION.SDK_INT >= 28) {
                            info.longVersionCode
                        } else {
                            @Suppress("DEPRECATION") info.versionCode.toLong()
                        }
                        result.success(code.toInt())
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                // Build 2129 (leg 6, delta §6(b)): signing-cert
                // SHA-256 for the updater's pre-install check.
                // Canonicalisation (BOTH methods, identical):
                // SHA-256 over the DER bytes of the FIRST signer
                // (apkContentsSigners[0] on API 28+, signatures[0]
                // below), lowercase hex. The archive side reads
                // the file WITHOUT installing it
                // (getPackageArchiveInfo); the own side reads the
                // running package. Any failure answers null —
                // the Dart side treats null as "cannot verify"
                // and refuses the download.
                "apkSigningCertSha256" -> {
                    val path = call.argument<String>("path") ?: ""
                    result.success(signingCertSha256(archive = path))
                }
                "ownSigningCertSha256" -> {
                    result.success(signingCertSha256(archive = null))
                }
                "installApk" -> {
                    val path = call.argument<String>("path") ?: ""
                    try {
                        val file = java.io.File(path)
                        if (!file.isFile) {
                            result.error("apk_missing", "the downloaded file is gone", null)
                        } else {
                            val uri = androidx.core.content.FileProvider
                                .getUriForFile(this, "$packageName.fileprovider", file)
                            val intent = Intent(Intent.ACTION_VIEW)
                                .setDataAndType(
                                    uri,
                                    "application/vnd.android.package-archive",
                                )
                                .addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_ACTIVITY_NEW_TASK
                                )
                            startActivity(intent)
                            result.success(true)
                        }
                    } catch (e: Exception) {
                        CrashLog.append(this, "installApk", e)
                        result.error("install_failed", e.javaClass.simpleName, null)
                    }
                }
                // Build 2077 (feature queue #7, biometric half):
                // fingerprint / face unlock for the app lock.
                // No new dependency: the framework BiometricPrompt
                // (API 28+) and BiometricManager (API 29+) — the
                // local_auth plugin is not in the offline pub
                // cache and the Jetpack biometric library is not
                // in the offline Gradle cache, so neither is added.
                // The PIN always stays the fallback: a false
                // answer (cancel, mismatch, lockout, error) only
                // means "use the PIN pad".
                "biometricsAvailable" -> {
                    result.success(canUseBiometrics())
                }
                "biometricAuthenticate" -> {
                    if (Build.VERSION.SDK_INT < 28) {
                        result.success(false)
                    } else {
                        showBiometricPrompt(result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Build 2077: true when a strong biometric is enrolled
     * (fingerprint or face). API 30+ asks for BIOMETRIC_STRONG
     * explicitly; API 29 uses the no-arg check (deprecated in
     * 30); below 29 there is no BiometricManager at all.
     */
    /**
     * Build 2129 (leg 6): the SHA-256 (lowercase hex) of the
     * first signing certificate of an APK — the one at
     * [archive] when given, else this app's own installed
     * package. One canonicalisation for both callers (see the
     * channel handlers): API 28+ reads signingInfo's
     * apkContentsSigners; API 26/27 (minSdk) reads the
     * deprecated signatures array — the same first signer in
     * the same DER form. Null on any failure (missing file,
     * unparseable package, no signer): the updater refuses
     * rather than guesses.
     */
    private fun signingCertSha256(archive: String?): String? {
        return try {
            val flags = if (Build.VERSION.SDK_INT >= 28) {
                PackageManager.GET_SIGNING_CERTIFICATES
            } else {
                @Suppress("DEPRECATION")
                PackageManager.GET_SIGNATURES
            }
            val info = if (archive != null) {
                packageManager.getPackageArchiveInfo(archive, flags)
            } else {
                packageManager.getPackageInfo(packageName, flags)
            } ?: return null
            val certBytes: ByteArray = if (Build.VERSION.SDK_INT >= 28) {
                val signing = info.signingInfo ?: return null
                signing.apkContentsSigners?.firstOrNull()?.toByteArray()
            } else {
                @Suppress("DEPRECATION")
                info.signatures?.firstOrNull()?.toByteArray()
            } ?: return null
            val digest = java.security.MessageDigest
                .getInstance("SHA-256")
                .digest(certBytes)
            digest.joinToString("") { "%02x".format(it) }
        } catch (e: Exception) {
            null
        }
    }

    private fun canUseBiometrics(): Boolean {
        if (Build.VERSION.SDK_INT < 29) return false
        return try {
            val manager = getSystemService(BiometricManager::class.java)
                ?: return false
            if (Build.VERSION.SDK_INT >= 30) {
                manager.canAuthenticate(
                    BiometricManager.Authenticators.BIOMETRIC_STRONG,
                ) == BiometricManager.BIOMETRIC_SUCCESS
            } else {
                @Suppress("DEPRECATION")
                manager.canAuthenticate() ==
                    BiometricManager.BIOMETRIC_SUCCESS
            }
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Build 2077: shows the system biometric prompt and
     * answers the result exactly once. A non-match
     * (onAuthenticationFailed) deliberately does NOT answer —
     * the system prompt stays up for a retry; the negative
     * button ("Use PIN") and any error answer false, and the
     * caller falls back to the PIN pad. The answer-once guard
     * matters because the negative-button listener and
     * onAuthenticationError(ERROR_NEGATIVE_BUTTON) can both
     * fire for one tap.
     */
    private fun showBiometricPrompt(result: Result) {
        var answered = false
        fun answer(value: Boolean) {
            if (!answered) {
                answered = true
                result.success(value)
            }
        }
        try {
            val executor = mainExecutor
            val prompt = BiometricPrompt.Builder(this)
                .setTitle("Unlock Ralysnd Ember")
                .setSubtitle("Use your fingerprint or face")
                .setNegativeButton(
                    "Use PIN",
                    executor,
                    DialogInterface.OnClickListener { _, _ -> answer(false) },
                )
                .build()
            prompt.authenticate(
                CancellationSignal(),
                executor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(
                        authResult: BiometricPrompt.AuthenticationResult,
                    ) {
                        answer(true)
                    }

                    override fun onAuthenticationError(
                        errorCode: Int,
                        errString: CharSequence,
                    ) {
                        answer(false)
                    }

                    override fun onAuthenticationFailed() {
                        // The prompt stays up for a retry; the
                        // result is answered only on success,
                        // error, or the negative button.
                    }
                },
            )
        } catch (e: Exception) {
            CrashLog.append(this, "biometricAuthenticate", e)
            answer(false)
        }
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /** Runs [work] off the UI thread and answers with its value. */
    private fun inBackground(result: Result, work: () -> Any?) {
        worker.execute {
            val value = try {
                work()
            } catch (e: Exception) {
                null
            }
            main.post { result.success(value) }
        }
    }

    /**
     * Like [inBackground] but keeps the error path: a throw
     * becomes result.error with [code] instead of a null success
     * (build 2030 — the OpenVPN vault calls moved off the main
     * thread without losing their failure reporting).
     */
    private fun inBackgroundErr(result: Result, code: String, work: () -> Any?) {
        worker.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error(code, e.message, null) }
            }
        }
    }

    /**
     * The installed apps but this one: package, name, and whether it has a
     * launcher icon (the others are mostly the system's). Packages without
     * code (overlays, resources) use no network and are left out.
     */
    private fun installedApps(): List<Map<String, Any>> {
        val pm = packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val withIcon = pm.queryIntentActivities(launcher, 0)
            .map { it.activityInfo.packageName }
            .toSet()
        @Suppress("DEPRECATION")
        return pm.getInstalledApplications(0)
            .filter { it.packageName != packageName && (it.flags and ApplicationInfo.FLAG_HAS_CODE) != 0 }
            .map {
                mapOf(
                    "package" to it.packageName,
                    "label" to it.loadLabel(pm).toString(),
                    "launcher" to (it.packageName in withIcon),
                )
            }
    }

    /** An app's icon as a small PNG. */
    private fun appIcon(pkg: String): ByteArray {
        val drawable = packageManager.getApplicationIcon(pkg)
        val size = 96
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(Canvas(bitmap))
        return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
    }

    /**
     * Build 2067 (start hardening, Shir o Khorshid's shape): runs
     * one engine's whole VPN start handoff — VpnService.prepare(),
     * the consent activity round-trip, and the direct service
     * start — behind a single guard, so no throw on this path can
     * reach the method-call handler uncaught and kill the
     * process. The reference client treats prepare() itself as
     * throwable (LocalizedActivities catches around it); Ember's
     * handler had no outer try/catch at all, so a start refusal
     * on a fresh install (consent revoked, so the tap takes the
     * never-before-exercised deferred branch) or a HyperOS
     * foreground-service refusal died as an uncaught main-thread
     * exception: app gone at the tap, no Dart error, no log
     * (build 2066 device report — 2066-crash-diagnosis.md). A
     * refusal now completes the call with error code
     * "vpn_start_refused" and the exception's simple name in the
     * message, which the Dart side already surfaces as the
     * engine's lastError / snackbar. When nothing throws,
     * behaviour is exactly the pre-2067 shape: same consent
     * dialog, same parked result, same service start.
     *
     * [park] stores the call's result + start closure in the
     * branch's pending slots (superseding any parked call, as
     * before); [unpark] clears them again when the consent
     * launch itself throws, so a later onActivityResult can
     * never reply to an already-completed result.
     */
    private fun startVpnGuarded(
        result: Result,
        needsConsent: Boolean,
        park: (Result, () -> Unit) -> Unit,
        unpark: () -> Unit,
        start: () -> Unit,
        // Build 2068: when a caller names itself here, the
        // guard drops that engine's prepare() breadcrumb (the
        // Psiphon trail's step 3). Other branches pass nothing
        // and keep their exact pre-2068 behaviour.
        breadcrumbPrefix: String? = null,
    ) {
        try {
            val consent = if (needsConsent) VpnService.prepare(this) else null
            if (breadcrumbPrefix != null) {
                CrashLog.breadcrumb(
                    this,
                    "$breadcrumbPrefix:prepare-returned " +
                        if (consent == null) "consent=not-needed" else "consent=intent",
                )
            }
            if (consent == null) {
                start()
                result.success(null)
            } else {
                park(result, start)
                startActivityForResult(consent, VPN_REQUEST)
            }
        } catch (e: Throwable) {
            // Build 2068: Throwable, not Exception — a
            // java.lang.Error here (ExceptionInInitializerError
            // and its linkage family) walked straight through
            // the 2067 Exception catch and killed the process
            // exactly as the unguarded code had. The caught
            // fatal is recorded in crash.log before the refusal
            // is answered, so a handled death leaves the same
            // evidence an unhandled one does.
            CrashLog.append(this, "startVpnGuarded", e)
            unpark()
            result.error(
                "vpn_start_refused",
                "${e.javaClass.simpleName}: ${e.message}",
                null,
            )
        }
    }

    /**
     * Build 2067: the consent-approved half of [startVpnGuarded] —
     * runs a parked branch's deferred start from onActivityResult
     * behind the same guard, so a foreground-service refusal at
     * that moment also becomes "vpn_start_refused" instead of an
     * uncaught main-thread death.
     */
    private fun runDeferredVpnStart(result: Result, start: (() -> Unit)?) {
        try {
            // Build 2068 breadcrumbs: the deferred start's own
            // pair, so a death inside a consent-approved start
            // shows its step between these two lines (or after
            // the first, with a crash record from the catch).
            CrashLog.breadcrumb(this, "vpn:deferred-start-invoked")
            start?.invoke()
            CrashLog.breadcrumb(this, "vpn:deferred-start-returned")
            result.success(null)
        } catch (e: Throwable) {
            // Build 2068: Throwable + crash.log, as in
            // startVpnGuarded above — an Error in the deferred
            // start was the other half of the 2067 hole.
            CrashLog.append(this, "runDeferredVpnStart", e)
            result.error(
                "vpn_start_refused",
                "${e.javaClass.simpleName}: ${e.message}",
                null,
            )
        }
    }

    @Deprecated("The VPN permission is asked with startActivityForResult.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PICK_REQUEST) {
            val pending = pendingPick
            pendingPick = null
            val uri = data?.data
            if (pending == null) return
            if (resultCode != RESULT_OK || uri == null) {
                pending.success(null)
                return
            }
            // Build 2050: an unreadable or oversize file is an
            // ERROR the UI can name, not a silent null that reads
            // exactly like a cancelled pick (audit F-H15).
            inBackgroundErr(pending, "pick_read_failed") { readPickedProfile(uri) }
            return
        }
        if (requestCode == PICK_IMAGE_REQUEST) {
            val pending = pendingImagePick
            pendingImagePick = null
            val uri = data?.data
            if (pending == null) return
            if (resultCode != RESULT_OK || uri == null) {
                pending.success(null)
                return
            }
            inBackgroundErr(pending, "pick_read_failed") {
                val file = java.io.File(cacheDir, "qr-pick-${System.currentTimeMillis()}.img")
                contentResolver.openInputStream(uri)?.use { input ->
                    file.outputStream().use { output -> input.copyTo(output) }
                } ?: throw IllegalStateException("unreadable")
                file.absolutePath
            }
            return
        }
        if (requestCode == SAVE_REQUEST) {
            val pending = pendingSave
            val content = pendingSaveContent
            pendingSave = null
            pendingSaveContent = ""
            val uri = data?.data
            if (pending == null) return
            if (resultCode != RESULT_OK || uri == null) {
                pending.success(false)
                return
            }
            inBackgroundErr(pending, "save_write_failed") {
                contentResolver.openOutputStream(uri)?.use { out ->
                    out.write(content.toByteArray(Charsets.UTF_8))
                } ?: throw IllegalStateException("no output stream")
                true
            }
            return
        }
        if (requestCode == PICK_TEXT_REQUEST) {
            val pending = pendingTextPick
            pendingTextPick = null
            val uri = data?.data
            if (pending == null) return
            if (resultCode != RESULT_OK || uri == null) {
                pending.success(null)
                return
            }
            inBackgroundErr(pending, "pick_read_failed") { readPickedProfile(uri) }
            return
        }
        if (requestCode != VPN_REQUEST) return
        // Build 2068 breadcrumb: the consent round-trip came
        // back; the raw resultCode (-1 = granted) is the record.
        CrashLog.breadcrumb(this, "vpn:onActivityResult resultCode=$resultCode")
        pendingOpenVpnOn?.let { pending ->
            val start = pendingOpenVpnStart
            pendingOpenVpnOn = null
            pendingOpenVpnStart = null
            if (resultCode == RESULT_OK) {
                runDeferredVpnStart(pending, start)
            } else {
                pending.error("vpn_denied", "the VPN was not allowed", null)
            }
            return
        }
        pendingPsiphonOn?.let { pending ->
            val start = pendingPsiphonStart
            pendingPsiphonOn = null
            pendingPsiphonStart = null
            if (resultCode == RESULT_OK) {
                runDeferredVpnStart(pending, start)
            } else {
                pending.error("vpn_denied", "the VPN was not allowed", null)
            }
            return
        }
        pendingWarpOn?.let { pending ->
            val start = pendingWarpStart
            pendingWarpOn = null
            pendingWarpStart = null
            if (resultCode == RESULT_OK) {
                runDeferredVpnStart(pending, start)
            } else {
                pending.error("vpn_denied", "the VPN was not allowed", null)
            }
            return
        }
        pendingAwgOn?.let { pending ->
            val start = pendingAwgStart
            pendingAwgOn = null
            pendingAwgStart = null
            if (resultCode == RESULT_OK) {
                runDeferredVpnStart(pending, start)
            } else {
                pending.error("vpn_denied", "the VPN was not allowed", null)
            }
            return
        }
        pendingXrayOn?.let { pending ->
            val start = pendingXrayStart
            pendingXrayOn = null
            pendingXrayStart = null
            if (resultCode == RESULT_OK) {
                runDeferredVpnStart(pending, start)
            } else {
                pending.error("vpn_denied", "the VPN was not allowed", null)
            }
            return
        }
        pendingLanternOn?.let { pending ->
            val start = pendingLanternStart
            pendingLanternOn = null
            pendingLanternStart = null
            if (resultCode == RESULT_OK) {
                runDeferredVpnStart(pending, start)
            } else {
                pending.error("vpn_denied", "the VPN was not allowed", null)
            }
            return
        }
        val result = pendingOn ?: return
        val start = pendingOnStart
        pendingOn = null
        pendingOnStart = null
        // Build 2070: the deferred Mozilla start runs behind the
        // shared guard, like the other engines' (build 2067).
        if (resultCode == RESULT_OK) {
            runDeferredVpnStart(result, start)
        } else {
            result.error("vpn_denied", "the VPN was not allowed", null)
        }
    }

    override fun onDestroy() {
        // Build 2136 (item 1): the screen-off receiver dies
        // with the activity that registered it.
        screenOffReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (e: Exception) {
            }
            screenOffReceiver = null
        }
        // Off, nothing needs the core once the UI is gone.
        if (isFinishing && !CoreService.on) CoreService.stopCore()
        super.onDestroy()
    }

    companion object {
        private const val VPN_REQUEST = 7
        private const val PICK_REQUEST = 8
        private const val PICK_TEXT_REQUEST = 9
        private const val PICK_IMAGE_REQUEST = 11
        private const val SAVE_REQUEST = 10
    }

    /**
     * Build 2085 (audit F-H15): the .ovpn intake for VIEW /
     * SEND intents — "Open with Ember" from Files, share-to-Ember
     * from Telegram. Returns {name, content} for a readable
     * profile, {error} for a named failure ("file-too-large" |
     * "unreadable"), null when the intent carries no .ovpn file.
     * The manifest filter is the gate for which intents arrive;
     * the Dart parser, not this function, is what rejects a
     * payload that is not a .ovpn profile — so a shared file
     * whose URI carries no .ovpn name still gets its honest
     * "Import failed" instead of a silent drop.
     */
    /** Build 2095 (whole-app journey audit #38): the config
     *  link of a VIEW intent, or null. Only the app-specific
     *  schemes the manifest declares — a content/file URI is
     *  an .ovpn open, not a link. */
    private fun extractDeepLink(intent: Intent?): String? {
        if (intent == null || intent.action != Intent.ACTION_VIEW) {
            return null
        }
        val data = intent.data ?: return null
        val scheme = data.scheme?.lowercase() ?: return null
        if (scheme !in setOf(
                "vless", "vmess", "trojan", "ss", "wireguard", "wg",
            )
        ) {
            return null
        }
        return data.toString().takeIf { it.isNotBlank() }
    }

    private fun extractOvpnIntent(intent: Intent?): Map<String, String>? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_VIEW -> {
                val uri = intent.data ?: return null
                readOvpnIntentFile(uri)
            }
            Intent.ACTION_SEND -> {
                // A shared file rides EXTRA_STREAM; shared text
                // rides EXTRA_TEXT (a config pasted into a chat).
                val streamUri: Uri? = try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(Intent.EXTRA_STREAM)
                    }
                } catch (_: Exception) {
                    null
                }
                if (streamUri != null) return readOvpnIntentFile(streamUri)
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                    ?.takeIf { it.isNotBlank() } ?: return null
                mapOf("name" to "shared.ovpn", "content" to text)
            }
            else -> null
        }
    }

    /** The intent intake's read: the picker's reader (256 KB
     *  cap, {name, content}), with its named failures mapped
     *  to the {error} shape Dart renders in plain language. */
    private fun readOvpnIntentFile(uri: Uri): Map<String, String> {
        return try {
            readPickedProfile(uri) ?: mapOf("error" to "unreadable")
        } catch (e: IllegalStateException) {
            if (e.message == "file-too-large") mapOf("error" to "file-too-large")
            else mapOf("error" to "unreadable")
        } catch (_: Exception) {
            mapOf("error" to "unreadable")
        }
    }

    /**
     * Reads a picked text profile file (.ovpn / .conf): {name,
     * content}, capped at 256 KB — past the cap it throws
     * IllegalStateException("file-too-large") so the caller can
     * say so, instead of returning a null that reads as a
     * cancelled pick (build 2050).
     */
    private fun readPickedProfile(uri: Uri): Map<String, String>? {
        val name = try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && cursor.moveToFirst()) cursor.getString(idx) else null
            }
        } catch (e: Exception) {
            null
        } ?: "profile.ovpn"
        val bytes = contentResolver.openInputStream(uri)?.use { input ->
            val buffer = java.io.ByteArrayOutputStream()
            val chunk = ByteArray(8192)
            while (true) {
                val n = input.read(chunk)
                if (n < 0) break
                buffer.write(chunk, 0, n)
                // Build 2050: oversize is a named failure, not
                // the silent null it was (indistinguishable from
                // a cancelled pick — audit F-H15).
                if (buffer.size() > 256 * 1024) {
                    throw IllegalStateException("file-too-large")
                }
            }
            buffer.toByteArray()
        } ?: return null
        return mapOf("name" to name, "content" to String(bytes, Charsets.UTF_8))
    }

    /** The service's notification needs this on Android 13 and later. */
    private fun askForNotifications() {
        // Build 2068: this call heads every engine's start
        // branch, BEFORE the 2067 startVpnGuarded guard, and on
        // a fresh install (POST_NOTIFICATIONS not yet granted)
        // its requestPermissions() runs for the first time
        // exactly at the connect tap. A permission-call hiccup
        // must never take down a connect: guarded at Throwable
        // level, recorded in crash.log, and the start proceeds.
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
            }
        } catch (e: Throwable) {
            CrashLog.append(this, "askForNotifications", e)
        }
    }
}
