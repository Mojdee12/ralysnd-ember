package com.ralysnd.ember

import android.Manifest
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

    /** The same wait for the V2Ray engine's VPN permission. */
    private var pendingXrayOn: Result? = null

    /** The Xray start to run once the permission is given. */
    private var pendingXrayStart: (() -> Unit)? = null

    /** The same wait for the Psiphon engine's VPN permission. */
    private var pendingPsiphonOn: Result? = null

    /** The Psiphon start to run once the permission is given. */
    private var pendingPsiphonStart: (() -> Unit)? = null

    /** The same wait for the Lantern engine's VPN permission. */
    private var pendingLanternOn: Result? = null

    /** The Lantern start to run once the permission is given. */
    private var pendingLanternStart: (() -> Unit)? = null

    /** The same wait for the WARP+ engine's VPN permission. */
    private var pendingWarpOn: Result? = null

    /** The WARP+ start to run once the permission is given. */
    private var pendingWarpStart: (() -> Unit)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app/android").setMethodCallHandler { call, result ->
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
                        // The first time, Android asks the user to allow the
                        // VPN; proxy mode needs no VPN.
                        val consent = if (CoreService.usesVpn(this)) VpnService.prepare(this) else null
                        if (consent == null) {
                            turnOn(result)
                        } else {
                            pendingOn?.error("vpn_denied", "superseded", null)
                            pendingOn = result
                            startActivityForResult(consent, VPN_REQUEST)
                        }
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
                        askForNotifications()
                        val start = {
                            XrayVpnService.start(
                                this,
                                call.argument<String>("config") ?: "",
                                call.argument<String>("name") ?: "",
                                call.argument<Int>("socksPort") ?: 10808,
                                call.argument<String>("dns") ?: "1.1.1.1",
                                call.argument<Boolean>("ipv6") ?: true,
                            )
                        }
                        val consent = VpnService.prepare(this)
                        if (consent == null) {
                            start()
                            result.success(null)
                        } else {
                            pendingXrayOn?.error("vpn_denied", "superseded", null)
                            pendingXrayOn = result
                            pendingXrayStart = start
                            startActivityForResult(consent, VPN_REQUEST)
                        }
                    }
                }
                "xrayStop" -> {
                    XrayVpnService.stop(this)
                    result.success(null)
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
                        ),
                    )
                }
                "xrayMeasureDelay" -> {
                    val config = call.argument<String>("config") ?: ""
                    inBackground(result) { XrayTester.measureDelay(this, config) }
                }
                "xraySpeedTest" -> {
                    val config = call.argument<String>("config") ?: ""
                    inBackground(result) { XrayTester.speedTest(this, config) }
                }
                "xrayExitInfo" -> {
                    // Best-effort: the exit IP/country of the running
                    // V2Ray tunnel, asked through the tunnel itself.
                    val port = call.argument<Int>("socksPort") ?: 10808
                    inBackground(result) { XrayTester.exitInfo(port) }
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
                        askForNotifications()
                        val start = {
                            PsiphonVpnService.start(
                                this,
                                call.argument<Boolean>("vpnMode") ?: true,
                                call.argument<String>("region") ?: "",
                                call.argument<String>("upstream") ?: "",
                                call.argument<List<String>>("protocols") ?: emptyList(),
                                call.argument<String>("dns") ?: "1.1.1.1",
                            )
                        }
                        val vpnMode = call.argument<Boolean>("vpnMode") ?: true
                        val consent = if (vpnMode) VpnService.prepare(this) else null
                        if (consent == null) {
                            start()
                            result.success(null)
                        } else {
                            pendingPsiphonOn?.error("vpn_denied", "superseded", null)
                            pendingPsiphonOn = result
                            pendingPsiphonStart = start
                            startActivityForResult(consent, VPN_REQUEST)
                        }
                    }
                }
                "psiphonStop" -> {
                    PsiphonVpnService.stop(this)
                    result.success(null)
                }
                "psiphonState" -> {
                    result.success(
                        mapOf(
                            "running" to PsiphonVpnService.running,
                            "connected" to PsiphonVpnService.connected,
                            "vpnMode" to PsiphonVpnService.isVpnMode,
                            "sinceMs" to PsiphonVpnService.startedAtMs,
                            "up" to PsiphonVpnService.totalUp,
                            "down" to PsiphonVpnService.totalDown,
                            "region" to PsiphonVpnService.egressRegion,
                            "clientAddress" to PsiphonVpnService.clientAddress,
                            "regions" to PsiphonVpnService.availableRegions,
                        ),
                    )
                }
                "psiphonExitInfo" -> {
                    // Best-effort: the exit IP/country of the running
                    // Psiphon tunnel, asked through its SOCKS proxy.
                    inBackground(result) { XrayTester.exitInfo(PsiphonConstants.SOCKS_PORT) }
                }
                // The Lantern engine (LanternVpnService.kt): always
                // VPN mode (the core is the novpn build; the service
                // bridges its own TUN), so it asks for the VPN
                // permission like the others.
                "lanternSetOn" -> {
                    if (call.argument<Boolean>("on") != true) {
                        LanternVpnService.stop(this)
                        result.success(null)
                    } else {
                        askForNotifications()
                        val start = {
                            LanternVpnService.start(
                                this,
                                call.argument<String>("dns") ?: "1.1.1.1",
                            )
                        }
                        val consent = VpnService.prepare(this)
                        if (consent == null) {
                            start()
                            result.success(null)
                        } else {
                            pendingLanternOn?.error("vpn_denied", "superseded", null)
                            pendingLanternOn = result
                            pendingLanternStart = start
                            startActivityForResult(consent, VPN_REQUEST)
                        }
                    }
                }
                "lanternStop" -> {
                    LanternVpnService.stop(this)
                    result.success(null)
                }
                "lanternState" -> {
                    // 2015: the service lives in its own process
                    // (:lantern); its statics are no longer visible
                    // here. It publishes its state to a file instead.
                    result.success(LanternVpnService.readPublishedState(this))
                }
                "lanternExitInfo" -> {
                    // Best-effort: the exit IP/country of the running
                    // Lantern tunnel, asked through its SOCKS proxy.
                    inBackground(result) { XrayTester.exitInfo(LanternVpnService.SOCKS_PORT) }
                }
                // The WARP+ engine (WarpVpnService.kt): always VPN
                // mode (the service bridges its own TUN to the core's
                // SOCKS proxy), so it asks for the VPN permission like
                // the others.
                "warpSetOn" -> {
                    if (call.argument<Boolean>("on") != true) {
                        WarpVpnService.stop(this)
                        result.success(null)
                    } else {
                        askForNotifications()
                        val start = {
                            WarpVpnService.start(
                                this,
                                call.argument<String>("mode") ?: WarpVpnService.MODE_STANDARD,
                                call.argument<Boolean>("scan") ?: false,
                                call.argument<String>("country") ?: "DE",
                                call.argument<String>("endpoint") ?: "",
                                call.argument<String>("dns") ?: "1.1.1.1",
                            )
                        }
                        val consent = VpnService.prepare(this)
                        if (consent == null) {
                            start()
                            result.success(null)
                        } else {
                            pendingWarpOn?.error("vpn_denied", "superseded", null)
                            pendingWarpOn = result
                            pendingWarpStart = start
                            startActivityForResult(consent, VPN_REQUEST)
                        }
                    }
                }
                "warpStop" -> {
                    WarpVpnService.stop(this)
                    result.success(null)
                }
                "warpState" -> {
                    val (up, down) = WarpVpnService.sessionTraffic()
                    result.success(
                        mapOf(
                            "running" to WarpVpnService.running,
                            "starting" to WarpVpnService.starting,
                            "connected" to WarpVpnService.connected,
                            "failed" to WarpVpnService.failed,
                            "failure" to WarpVpnService.failureMessage,
                            "mode" to WarpVpnService.modeName,
                            "sinceMs" to WarpVpnService.startedAtMs,
                            "up" to up,
                            "down" to down,
                        ),
                    )
                }
                "warpExitInfo" -> {
                    // Best-effort: the exit IP/country of the running
                    // WARP tunnel, asked through its SOCKS proxy.
                    inBackground(result) { XrayTester.exitInfo(WarpVpnService.SOCKS_PORT) }
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

    private fun turnOn(result: Result) {
        try {
            CoreService.turnOn(this)
            result.success(null)
        } catch (e: Exception) {
            result.error("start_failed", e.message, null)
        }
    }

    @Deprecated("The VPN permission is asked with startActivityForResult.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_REQUEST) return
        pendingWarpOn?.let { pending ->
            val start = pendingWarpStart
            pendingWarpOn = null
            pendingWarpStart = null
            if (resultCode == RESULT_OK) {
                start?.invoke()
                pending.success(null)
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
                start?.invoke()
                pending.success(null)
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
                start?.invoke()
                pending.success(null)
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
                start?.invoke()
                pending.success(null)
            } else {
                pending.error("vpn_denied", "the VPN was not allowed", null)
            }
            return
        }
        val result = pendingOn ?: return
        pendingOn = null
        if (resultCode == RESULT_OK) turnOn(result) else result.error("vpn_denied", "the VPN was not allowed", null)
    }

    override fun onDestroy() {
        // Off, nothing needs the core once the UI is gone.
        if (isFinishing && !CoreService.on) CoreService.stopCore()
        super.onDestroy()
    }

    companion object {
        private const val VPN_REQUEST = 7
    }

    /** The service's notification needs this on Android 13 and later. */
    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }
}
