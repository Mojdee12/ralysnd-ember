package com.ralysnd.ember

import android.Manifest
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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
    }

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
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "dataDir" -> result.success(CoreService.dataDir(this).absolutePath)
                "startCore" -> {
                    CoreService.startCore(this, on = false)
                    result.success(null)
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
                    result.success(null)
                }
                // The AmneziaWG engine (AwgBackend, build 2040,
                // queue 2h): start asks for the VPN permission
                // like xraySetOn does; the service brings the
                // TUN up and hands its fd to the userspace
                // device — no Xray core, no SOCKS port.
                "awgSetOn" -> {
                    if (call.argument<Boolean>("on") != true) {
                        XrayVpnService.stop(this)
                        result.success(null)
                    } else {
                        askForNotifications()
                        val start = {
                            XrayVpnService.startAwg(
                                this,
                                call.argument<String>("name") ?: "",
                                call.argument<String>("settings") ?: "",
                                call.argument<String>("addresses") ?: "",
                                call.argument<String>("dns") ?: "1.1.1.1",
                                call.argument<Boolean>("ipv6") ?: true,
                                call.argument<Int>("mtu") ?: 1500,
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
                    if (config.isNotEmpty() && XrayVpnService.running &&
                        !XrayVpnService.awgMode
                    ) {
                        XrayVpnService.rotate(this, config)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "xrayState" -> {
                    val (up, down) = XrayVpnService.sessionTraffic()
                    result.success(
                        mapOf(
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
                            // AmneziaWG (build 2040): whether the
                            // live tunnel is the userspace device,
                            // and its UAPI dump — the Dart side
                            // parses the handshake age and transfer
                            // counters out of it.
                            "awg" to XrayVpnService.awgMode,
                            "awgConfig" to XrayVpnService.awgConfigDump(),
                            // Kill switch (build 2063, feature
                            // queue #3): the service is holding a
                            // dead session's TUN as a blackhole —
                            // traffic is blocked, not direct.
                            "killSwitchHeld" to XrayVpnService.blackholeHeld,
                        ),
                    )
                }
                // The EmberWarp engine (EmberWarpCore.kt, build
                // 2030): a WARP client core as a subprocess. The
                // Dart side owns the profile and builds the
                // command line; this side owns the process, the
                // identity directory and the readiness wait.
                "xraySetOnWarp" -> {
                    if (call.argument<Boolean>("on") != true) {
                        XrayVpnService.stop(this)
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
                    inBackground(result) { EmberWarpCore.start(this, args, port) }
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
                        transport = call.argument<String>("transport") ?: "h3",
                        ech = call.argument<String>("ech") ?: "",
                        fragment = call.argument<Boolean>("fragment") ?: false,
                        noize = call.argument<String>("noize") ?: "",
                        keepalive = call.argument<Int>("keepalive") ?: 25,
                        peer = call.argument<String>("peer"),
                    )
                    inBackground(result) { slot.start(this, options) }
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
                "socksTunSetOn" -> {
                    // TUN for an Aether slot, VPN consent like
                    // xraySetOnWarp (build 2032).
                    if (call.argument<Boolean>("on") != true) {
                        XrayVpnService.stop(this)
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
                    inBackground(result) { XrayTester.measureDelayEx(this, config) }
                }
                "xrayMeasureDelay" -> {
                    val config = call.argument<String>("config") ?: ""
                    inBackground(result) { XrayTester.measureDelay(this, config) }
                }
                "xraySpeedTest" -> {
                    val config = call.argument<String>("config") ?: ""
                    inBackground(result) { XrayTester.speedTest(this, config) }
                }
                "xraySandboxTest" -> {
                    // The sandbox config test (build 2061,
                    // feature queue #1): one throwaway core
                    // proves delay + hold + exit on a free
                    // port, without touching the live tunnel.
                    val config = call.argument<String>("config") ?: ""
                    inBackground(result) { XrayTester.sandboxTest(this, config) }
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
                // The Lantern engine (LanternVpnService.kt): the
                // radiance core as a subprocess behind a TUN bridge.
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
                                call.argument<Boolean>("smart") ?: false,
                                call.argument<Int>("mtu") ?: 1500,
                                call.argument<String>("dns") ?: "1.1.1.1",
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
                    val traffic = LanternVpnService.sessionTraffic()
                    result.success(
                        mapOf(
                            "available" to LanternCore.binary(this).exists(),
                            "running" to LanternVpnService.running,
                            "coreRunning" to LanternCore.isAlive(),
                            "connected" to (LanternVpnService.running &&
                                LanternCore.stage == "up"),
                            "stage" to LanternCore.stage,
                            "exitCity" to LanternCore.exitCity,
                            "exitCountry" to LanternCore.exitCountry,
                            "exitCode" to LanternCore.exitCode,
                            "servers" to LanternCore.servers,
                            "keptServers" to LanternCore.keptConfig(this).first,
                            "keptMasque" to LanternCore.keptConfig(this).second,
                            "exhausted" to LanternCore.exhausted,
                            "sinceMs" to LanternVpnService.startedAtMs,
                            "up" to traffic.first,
                            "down" to traffic.second,
                            "error" to (LanternVpnService.serviceError
                                ?: LanternCore.lastError),
                            "stdoutTail" to LanternCore.stdoutTail(),
                            "stderrTail" to LanternCore.stderrTail(),
                        ),
                    )
                }
                "lanternFetchList" -> {
                    result.success(LanternCore.command("fetch"))
                }
                "lanternVia" -> {
                    // Build 2052 (diagnosis Cause 2): reroute the
                    // RUNNING core's control plane through a leg
                    // (`via HOST:PORT` on its stdin). False when no
                    // core runs — the caller keeps waiting directly.
                    val port = call.argument<Int>("port") ?: 0
                    result.success(if (port > 0) LanternCore.sendVia(port) else false)
                }
                "lanternViaDirect" -> {
                    // Build 2052: back to direct before the leg goes
                    // down, so later refreshes never point at a dead
                    // port.
                    result.success(LanternCore.sendViaDirect())
                }
                "lanternRotateList" -> {
                    inBackground(result) { LanternCore.rotate(this) }
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
                    pendingPick?.error("superseded", "a newer pick replaced this one", null)
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
                "pickTextFile" -> {
                    // Build 2050: the generic text-file pick (a
                    // WireGuard .conf today). Same contract as the
                    // OpenVPN pick — {name, content} or null on
                    // cancel — on its own request code and result,
                    // so the two flows can never cross answers.
                    pendingTextPick?.error("superseded", "a newer pick replaced this one", null)
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
                else -> result.notImplemented()
            }
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
        // Off, nothing needs the core once the UI is gone.
        if (isFinishing && !CoreService.on) CoreService.stopCore()
        super.onDestroy()
    }

    companion object {
        private const val VPN_REQUEST = 7
        private const val PICK_REQUEST = 8
        private const val PICK_TEXT_REQUEST = 9
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
