package com.ralysnd.ember

import android.content.Context
import android.os.SystemClock
import android.util.Log
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * The ralysnd Aether engine (build 2032): the owner's own Rust binary
 * (jniLibs/libaether.so — MASQUE / WireGuard / WARP-in-WARP over
 * Cloudflare), taken AS IT IS from the ralysnd app and driven the way
 * ralysnd drives it: spawned from nativeLibraryDir with an AETHER_*
 * environment, its stdout parsed into a stage vocabulary, one local
 * SOCKS5 per engine slot.
 *
 * Two slots share this file, exactly as in ralysnd:
 *  - "cfwarp": the standalone WARP page — protocol wg, SOCKS 20870,
 *    its own data dir and identity, connect proven by a Cloudflare
 *    trace through the tunnel (warp=on), never by handshake alone.
 *  - "masque": the Aether page — SOCKS 20810, protocols masque / wg /
 *    gool (WARP-in-WARP), its own data dir and identities.
 *
 * The stage parser, the env mapping and the registration ladder are
 * ports of ralysnd's AetherStage / AetherOptions / AetherRegister
 * (which mirror the desktop aether-manager); labels are English —
 * Ember is English-only. Build 2074 ports the two remaining
 * ralysnd registration rungs: the semi-python ClientHello rung
 * (AetherTls env table, fragmented) and the tlshello (Xray-exit)
 * rung (AetherXrayExit: a local Xray subprocess whose freedom
 * outbound cuts the ClientHello into TLS records with the
 * tlshello-0-len finalmask). The rung winner is remembered PER
 * NETWORK (AetherRegisterMemory, hashed key, never an SSID),
 * with the old per-slot "rung-<slot>" pref kept as a read
 * fallback. MasqueCarrier learns h3 vs h2 per network from the
 * core's own "Accepted … via HTTP/2" line when the transport
 * is "auto". Budgets are ralysnd's own: 35 s per rung, 180 s
 * total for all six rungs.
 *
 * Process management mirrors EmberWarpCore: pid-file orphan reaping,
 * identity in noBackupFilesDir, log ring in memory + tail on state.
 */

enum class AetherStage {
    IDLE, STARTING, IDENTITY, QUICKCHECK, SCAN, SELECTED, HANDSHAKE,
    TUNNEL, VALIDATE, CONNECTED, RECONNECTING, STOPPED, FAILED, CRASHED;

    /** Position on the happy path; -1 when not on it. Log lines do
     *  not always arrive in causal order, so a stage may only move
     *  BACKWARD via an explicit regression signal. */
    val progressRank: Int
        get() = when (this) {
            STARTING -> 0
            IDENTITY -> 1
            QUICKCHECK -> 2
            SCAN -> 3
            SELECTED -> 4
            HANDSHAKE -> 5
            TUNNEL -> 6
            VALIDATE -> 7
            CONNECTED -> 8
            else -> -1
        }

    val isRegression: Boolean
        get() = this == RECONNECTING || this == FAILED ||
            this == CRASHED || this == STOPPED

    fun label(): String = when (this) {
        IDLE -> "Off"
        STARTING -> "Starting the engine"
        IDENTITY -> "Identity"
        QUICKCHECK -> "Checking the previous server"
        SCAN -> "Scanning for a server"
        SELECTED -> "Server selected"
        HANDSHAKE -> "Handshake"
        TUNNEL -> "Establishing the tunnel"
        VALIDATE -> "Validating data flow"
        CONNECTED -> "Connected"
        RECONNECTING -> "Dropped — reconnecting"
        STOPPED -> "Stopped"
        FAILED -> "Failed"
        CRASHED -> "Engine crashed"
    }
}

data class AetherDetail(
    val server: String? = null,
    val rtt: String? = null,
    val profile: String? = null,
    val socks: String? = null,
)

object AetherStageParser {
    private val STAGE_RULES: List<Pair<Regex, AetherStage>> = listOf(
        Regex("""no (warp|masque) identity found|provisioning dedicated""", RegexOption.IGNORE_CASE) to AetherStage.IDENTITY,
        Regex("""enrolling masque key""", RegexOption.IGNORE_CASE) to AetherStage.IDENTITY,
        Regex("""loaded existing (warp|masque) identity""", RegexOption.IGNORE_CASE) to AetherStage.IDENTITY,
        Regex("""identity ready: device=(\S+)""", RegexOption.IGNORE_CASE) to AetherStage.IDENTITY,
        Regex("""verifying cached gateway|verifying cached wireguard endpoint""", RegexOption.IGNORE_CASE) to AetherStage.QUICKCHECK,
        Regex("""cached (gateway|endpoint) .* still works""", RegexOption.IGNORE_CASE) to AetherStage.QUICKCHECK,
        Regex("""cached (gateway|endpoint) .* no longer works""", RegexOption.IGNORE_CASE) to AetherStage.SCAN,
        Regex("""candidate ok (\S+):(\d+)""", RegexOption.IGNORE_CASE) to AetherStage.SCAN,
        Regex("""hunting for a working masque gateway""", RegexOption.IGNORE_CASE) to AetherStage.SCAN,
        Regex("""hunting for a working wireguard endpoint""", RegexOption.IGNORE_CASE) to AetherStage.SCAN,
        Regex("""selected masque gateway (\S+):(\d+)""", RegexOption.IGNORE_CASE) to AetherStage.SELECTED,
        Regex("""selected wireguard endpoint (\S+):(\d+)""", RegexOption.IGNORE_CASE) to AetherStage.SELECTED,
        Regex("""using forced peer""", RegexOption.IGNORE_CASE) to AetherStage.SELECTED,
        Regex("""using cloudflare edge""", RegexOption.IGNORE_CASE) to AetherStage.SELECTED,
        Regex("""confirming wireguard handshake""", RegexOption.IGNORE_CASE) to AetherStage.HANDSHAKE,
        Regex("""handshake successful""", RegexOption.IGNORE_CASE) to AetherStage.HANDSHAKE,
        Regex("""establishing outer warp tunnel""", RegexOption.IGNORE_CASE) to AetherStage.HANDSHAKE,
        Regex("""establishing inner warp tunnel""", RegexOption.IGNORE_CASE) to AetherStage.HANDSHAKE,
        Regex("""masque transport: http/3""", RegexOption.IGNORE_CASE) to AetherStage.TUNNEL,
        Regex("""masque transport: http/2""", RegexOption.IGNORE_CASE) to AetherStage.TUNNEL,
        Regex("""validating masque data-plane""", RegexOption.IGNORE_CASE) to AetherStage.VALIDATE,
        Regex("""masque tunnel validated""", RegexOption.IGNORE_CASE) to AetherStage.VALIDATE,
        Regex("""inner endpoint tunneled through outer warp""", RegexOption.IGNORE_CASE) to AetherStage.HANDSHAKE,
        Regex("""socks5 (server )?listening on""", RegexOption.IGNORE_CASE) to AetherStage.CONNECTED,
        Regex("""tunnel (closed|ended|exited).*(reconnect)""", RegexOption.IGNORE_CASE) to AetherStage.RECONNECTING,
        Regex("""no usable masque gateway found""", RegexOption.IGNORE_CASE) to AetherStage.SCAN,
        Regex("""found no data-plane endpoint.*trying next profile""", RegexOption.IGNORE_CASE) to AetherStage.SCAN,
        Regex("""prober: no clean endpoint found|no clean endpoint found""", RegexOption.IGNORE_CASE) to AetherStage.FAILED,
        Regex("""handshake failed""", RegexOption.IGNORE_CASE) to AetherStage.FAILED,
        // The WireGuard watchdog lines: neither contains "reconnect",
        // and missing them left the UI green through a stale cycle.
        Regex("""no valid data from peer|tunnel considered dead|wireguard tunnel stale""", RegexOption.IGNORE_CASE) to AetherStage.RECONNECTING,
        Regex("""no usable.*endpoint found""", RegexOption.IGNORE_CASE) to AetherStage.SCAN,
        Regex("""last known-good .* no longer responds|rescanning|scanning fresh""", RegexOption.IGNORE_CASE) to AetherStage.SCAN,
        Regex("""tunnel (closed|ended|exited)""", RegexOption.IGNORE_CASE) to AetherStage.RECONNECTING,
    )

    private val NOISE_RE =
        Regex("""\] (junk(\[\d+\]|_after\[\d+\])? sent|signature i\d sent|sending \d+ junk|obfuscation pre-handshake complete|verify recv \d+ bytes|recv \d+ bytes (from|type=)|tls verification: )""")

    fun isNoise(line: String): Boolean = NOISE_RE.containsMatchIn(line)

    private val PROBE_FAIL_RE =
        Regex("""\b(?:h2 )?probe \S+ -> (.+)$""", RegexOption.IGNORE_CASE)

    fun probeFailureReason(line: String): String? =
        PROBE_FAIL_RE.find(line)?.groupValues?.get(1)?.trim()?.take(80)

    fun classify(line: String): AetherStage? {
        for ((re, stage) in STAGE_RULES) {
            if (re.containsMatchIn(line)) return stage
        }
        return null
    }

    fun extractDetail(line: String): AetherDetail {
        val selected = Regex(
            """selected (?:MASQUE gateway|WireGuard endpoint) (\S+?):(\d+)(?:.*rtt ([^)]+))?""",
            RegexOption.IGNORE_CASE,
        ).find(line)
        if (selected != null) {
            val rtt = selected.groupValues[3].ifEmpty { null }
            return AetherDetail(
                server = "${selected.groupValues[1]}:${selected.groupValues[2]}",
                rtt = rtt,
            )
        }
        val edge = Regex("""using cloudflare edge (\S+)""", RegexOption.IGNORE_CASE).find(line)
        if (edge != null) return AetherDetail(server = edge.groupValues[1])
        val prof = Regex(
            """obfuscation profile: (\S+)|aethernoize (?:primary )?profile: (\S+)""",
            RegexOption.IGNORE_CASE,
        ).find(line)
        if (prof != null) {
            return AetherDetail(
                profile = prof.groupValues[1].ifEmpty { prof.groupValues[2] },
            )
        }
        val socks = Regex("""socks5 (?:server )?listening on (\S+)""", RegexOption.IGNORE_CASE).find(line)
        if (socks != null) return AetherDetail(socks = socks.groupValues[1])
        return AetherDetail()
    }

    fun isPanicLine(line: String): Boolean =
        Regex("""panicked at|stack backtrace|RUST_BACKTRACE""", RegexOption.IGNORE_CASE)
            .containsMatchIn(line)
}

/**
 * The ClientHello of Aether's own TLS: MASQUE over HTTP/2, the
 * calls to the WARP API and the DoH lookup of the ECH key.
 * Port of ralysnd's AetherTls (Aether 2.4.0 takes each part as
 * an option; the env names are what its cli.rs sets for them).
 * The bundled libaether.so IS 2.4.0 (verified in its strings),
 * so these env vars are live — not a hope. [CHROME] is the
 * core's own and sets nothing. [SEMI_PYTHON] is the handshake
 * PattNG ships for Irancell-type filters that pass Python's
 * ClientHello and drop Chrome's: Python's TLS 1.2 suites in
 * Python's order, its TLS 1.3 order, its groups and signature
 * algorithms, no GREASE, no OCSP or SCT request, one fixed
 * order of extensions.
 */
enum class AetherTls(val key: String, val label: String, val env: Map<String, String>) {
    CHROME("chrome", "Chrome", emptyMap()),
    SEMI_PYTHON(
        "semi-python", "semi-python",
        mapOf(
            "AETHER_TLS_CIPHERS" to "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:" +
                "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:" +
                "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:" +
                "ECDHE-ECDSA-AES256-SHA:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256",
            "AETHER_TLS13_CIPHERS" to "TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256",
            "AETHER_TLS_GROUPS" to "X25519MLKEM768:X25519:P-256:P-384:P-521",
            "AETHER_TLS_SIGALGS" to "mldsa65:mldsa87:mldsa44:ecdsa_secp256r1_sha256:ecdsa_secp384r1_sha384:" +
                "ecdsa_secp521r1_sha512:ed25519:rsa_pss_rsae_sha256:rsa_pss_rsae_sha384:rsa_pss_rsae_sha512:" +
                "rsa_pkcs1_sha256:rsa_pkcs1_sha384:rsa_pkcs1_sha512",
            "AETHER_DISABLE_GREASE" to "1",
            "AETHER_DISABLE_OCSP_STAPLING" to "1",
            "AETHER_DISABLE_SCT" to "1",
            "AETHER_DISABLE_EXTENSION_PERMUTATION" to "1",
        ),
    );

    companion object {
        fun byKey(key: String?): AetherTls = values().firstOrNull { it.key == key } ?: CHROME
    }
}

/**
 * What identifies "this network" across reconnections, so a
 * rung or carrier learned on it is reused — port of ralysnd's
 * CfNetEnv.networkKey, adapted to the APIs Ember already uses
 * (MainActivity.networkInfoMap reads the same three signals):
 * Wi-Fi = the saved-network id + default gateway + DNS
 * servers (a home router keeps both); mobile = the carrier
 * operator name; never an SSID, never a per-connection handle.
 * The raw key is SHA-256-hashed before it is kept, so nothing
 * identifying survives in prefs. Best-effort: any failure
 * yields "unknown" and the memories still work, keyed to it.
 */
object AetherNetworkKey {
    fun key(context: Context): String {
        val raw = runCatching { rawKey(context) }.getOrDefault("unknown")
        return try {
            val digest = java.security.MessageDigest.getInstance("SHA-256")
            digest.digest(raw.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        } catch (_: Exception) {
            "unknown"
        }
    }

    private fun rawKey(context: Context): String {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
            as android.net.ConnectivityManager
        val net = cm.activeNetwork ?: return "offline"
        val caps = cm.getNetworkCapabilities(net)
        if (caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) != true) {
            val operator = runCatching {
                context.getSystemService(android.telephony.TelephonyManager::class.java)
                    ?.networkOperatorName.orEmpty()
            }.getOrDefault("")
            return "cell|$operator"
        }
        val links = cm.getLinkProperties(net)
        val wifiId = runCatching {
            val wifi = context.applicationContext
                .getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
            @Suppress("DEPRECATION")
            wifi.connectionInfo.networkId.takeIf { it >= 0 }?.toString()
        }.getOrNull().orEmpty()
        val gateways = links?.routes
            ?.filter { it.isDefaultRoute && it.gateway?.isLinkLocalAddress != true }
            ?.joinToString { it.gateway?.hostAddress.orEmpty() }
            .orEmpty()
        val dns = links?.dnsServers
            ?.filter { !it.isLinkLocalAddress }
            ?.joinToString { it.hostAddress.orEmpty() }
            .orEmpty()
        return "wifi|$wifiId|$gateways|$dns"
    }
}

/**
 * Per network (hashed key, never an SSID) and per slot: the
 * registration rung that last made an identity there. Port of
 * ralysnd's AetherRegister.RegisterMemory. The legacy per-slot
 * "rung-<slot>" pref (builds 2032–2073) is still read as a
 * fallback in [AetherSlot.ensureIdentity] and cleared with the
 * new memory, so a stored winner from a previous build still
 * resolves and an unknown stored key can never crash the
 * ladder (firstOrNull yields null and the ladder runs in
 * listed order).
 */
object AetherRegisterMemory {
    private const val PREFS = "aether_register"

    private fun slotKey(network: String, slotId: String) = "$network|$slotId"

    fun get(context: Context, network: String, slotId: String): String? =
        runCatching {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(slotKey(network, slotId), null)
        }.getOrNull()

    fun remember(context: Context, network: String, slotId: String, rung: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(slotKey(network, slotId), rung).apply()
    }

    fun forget(context: Context, network: String, slotId: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .remove(slotKey(network, slotId)).apply()
    }
}

/**
 * The MASQUE carrier when the transport is "auto": what
 * connected on this network last time. Port of ralysnd's
 * MasqueCarrier. The core tries HTTP/3 first and falls back
 * to HTTP/2 by itself — but only when started on HTTP/3;
 * started on HTTP/2 it never tries HTTP/3. So the app starts
 * on HTTP/3 unless this network is known to need HTTP/2, in
 * which case it starts there and skips the HTTP/3 timeouts.
 * Learned from the core's own log line ("Accepted <peer> via
 * HTTP/2"), so it records the carrier that really carried the
 * session, not the one that was asked for. Forgotten when a
 * session that started from it fails without ever connecting,
 * and the next connect tries from HTTP/3 again. Per network
 * (the hashed key — never an SSID).
 */
object MasqueCarrier {
    const val AUTO = "auto"
    private const val PREFS = "masque_carrier"
    private val ACCEPTED = Regex("""Accepted \S+ via HTTP/([23])""")

    /** The transport the core is started on for "auto": "h2" where that is what worked, else "h3". */
    fun startOn(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(AetherNetworkKey.key(context), null)
            ?.takeIf { it == "h2" || it == "h3" } ?: "h3"

    /** The core reached a MASQUE gateway and was accepted on it: the session is close, not closed. */
    fun isAccepted(line: String): Boolean = ACCEPTED.containsMatchIn(line)

    /** Feed every core log line of a MASQUE session; remembers the carrier it was accepted on. */
    fun onCoreLog(context: Context, line: String) {
        val v = ACCEPTED.find(line)?.groupValues?.get(1) ?: return
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(AetherNetworkKey.key(context), "h$v").apply()
    }

    /** A MASQUE session failed: what this network remembered is tested again next time. */
    fun forget(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .remove(AetherNetworkKey.key(context)).apply()
    }
}

/**
 * A local Xray that Aether dials out through (AETHER_UPSTREAM),
 * so that its TLS ClientHello leaves the phone cut into TLS
 * records by Xray's tlshello finalmask — PattNG's "exit-node":
 * a freedom outbound with `tlshello-0-len`, behind a loopback
 * SOCKS port. Port of ralysnd's AetherXrayExit, adapted: ralysnd
 * drives its exit through a Messenger service in its own
 * process (AwgHostClient + XrayAetherRegExitService); Ember has
 * no such service, but it already runs throwaway libxray.so
 * subprocesses with a config file (XrayTester.startInstance),
 * so the exit is one of those — same binary, same config
 * shape, same loopback port discipline. Through the exit go
 * the calls to the WARP API and MASQUE over HTTP/2 (both TCP);
 * HTTP/3 never comes here. Every call blocks briefly: never on
 * the main thread.
 */
object AetherXrayExit {
    private const val TAG = "AetherXrayExit"

    @Volatile private var port = 0
    @Volatile private var process: Process? = null

    /** What Aether's `AETHER_UPSTREAM` names for an exit on [port]. */
    fun upstream(port: Int) = "socks5://127.0.0.1:$port"

    /**
     * A SOCKS inbound on [port] and a freedom outbound that cuts
     * the ClientHello into records. The tlshello-0-len finalmask
     * (CfShape.finalMaskTlsHello, ralysnd): an empty first
     * record, 104 bytes, then the rest cut again; the second
     * entry re-wraps the following packet the same way. The
     * vendored core's FragmentMask.Build() accepts this shape:
     * packets "tlshello" → packets 0–1, lengths are Int32Ranges
     * ("0"/"104"/"1" — only the LAST length may not be 0), and
     * the host core binary accepts the whole config under
     * `run -test` (gate, build 2074).
     */
    fun config(port: Int): String = """
        {
          "log": {"loglevel": "warning"},
          "inbounds": [
            {
              "tag": "aether-in",
              "listen": "127.0.0.1",
              "port": $port,
              "protocol": "socks",
              "settings": {"auth": "noauth", "udp": true}
            }
          ],
          "outbounds": [
            {
              "tag": "exit-node",
              "protocol": "freedom",
              "streamSettings": {
                "finalmask": {
                  "tcp": [
                    {
                      "type": "fragment",
                      "settings": {
                        "packets": "tlshello",
                        "lengths": ["0", "104", "1"],
                        "delays": ["0"],
                        "maxSplit": "0"
                      }
                    },
                    {
                      "type": "fragment",
                      "settings": {
                        "packets": "1-1",
                        "lengths": ["114", "1"],
                        "delays": ["1"],
                        "maxSplit": "11"
                      }
                    }
                  ]
                }
              }
            }
          ]
        }
    """.trimIndent()

    /** Starts the exit and returns its SOCKS port, or null when Xray did not start. */
    @Synchronized
    fun start(context: Context): Int? {
        stop(context)
        val p = freePort() ?: return null
        val dir = File(XrayVpnService.workDir(context), "aether-exit").apply { mkdirs() }
        val configFile = File(dir, "exit-$p.json")
        val logFile = File(dir, "exit-$p.log")
        val proc = try {
            AtomicFile.writeText(configFile, config(p))
            ProcessBuilder(
                File(context.applicationInfo.nativeLibraryDir, "libxray.so").absolutePath,
                "run", "-c", configFile.absolutePath,
            )
                .directory(dir)
                .redirectErrorStream(true)
                .redirectOutput(ProcessBuilder.Redirect.appendTo(logFile))
                .start()
        } catch (e: Exception) {
            Log.w(TAG, "the tlshello exit did not start", e)
            return null
        }
        if (!waitForPort(proc, p, 12_000)) {
            ProcessKill.kill(proc)
            Log.w(TAG, "the tlshello exit did not answer on $p")
            return null
        }
        port = p
        process = proc
        return p
    }

    /**
     * Stops the exit if it runs — only the one on [onlyPort]
     * when given, so a late stop of an earlier session cannot
     * end the exit a newer one has started. The process is
     * killed with the shared kill (build 2054, F-M1), so the
     * port is free before any caller respawns on it.
     */
    @Synchronized
    fun stop(context: Context, onlyPort: Int = 0) {
        val p = port
        val proc = process
        if (p == 0 || proc == null || (onlyPort != 0 && onlyPort != p)) return
        port = 0
        process = null
        ProcessKill.kill(proc)
        try {
            File(File(XrayVpnService.workDir(context), "aether-exit"), "exit-$p.json").delete()
        } catch (_: Exception) {
        }
    }

    private fun freePort(): Int? = runCatching {
        java.net.ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1")).use { it.localPort }
    }.getOrNull()

    private fun waitForPort(proc: Process, port: Int, timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (!proc.isAlive) return false
            try {
                java.net.Socket().use { s ->
                    s.connect(java.net.InetSocketAddress("127.0.0.1", port), 300)
                    return true
                }
            } catch (_: Exception) {
                try {
                    Thread.sleep(120)
                } catch (_: InterruptedException) {
                    return false
                }
            }
        }
        return false
    }
}

/** Options for one run — the ralysnd AetherOptions subset Ember's
 *  pages expose. Defaults mirror ralysnd's. */
data class AetherRunOptions(
    val protocol: String = "masque",   // masque | wg | gool
    val scan: String = "turbo",        // turbo|balanced|thorough|stealth|ironclad
    val ip: String = "v4",             // v4 | v6 | both
    val transport: String = "h3",      // h3 | h2 | auto (masque/gool carrier)
    val ech: String = "",
    val fragment: Boolean = false,
    val noize: String = "",
    val keepalive: Int = 25,
    val peer: String? = null,
)

class AetherSlot(
    val id: String,
    val socksPort: Int,
    private val dirName: String,
) {
    @Volatile var running: Boolean = false
        private set
    @Volatile var stage: AetherStage = AetherStage.IDLE
        private set
    @Volatile var stageLabel: String = ""
        private set
    @Volatile var server: String = ""
        private set
    @Volatile var rtt: String = ""
        private set
    @Volatile var profile: String = ""
        private set
    @Volatile var lastError: String = ""
        private set
    @Volatile var startedAtMs: Long = 0
        private set

    private var process: Process? = null
    @Volatile private var stopping: Boolean = false
    // Build 2074 (MasqueCarrier): the protocol of the running
    // session, the carrier an "auto" session started on (null
    // when the transport was picked explicitly), and whether the
    // session ever reached CONNECTED — a failed auto session
    // forgets its carrier in drain().
    @Volatile private var currentProtocol: String = ""
    @Volatile private var autoStartedCarrier: String? = null
    @Volatile private var reachedConnected: Boolean = false
    private val logRing = ArrayDeque<String>()
    private val probeReasons = LinkedHashMap<String, Int>()

    fun dataDir(context: Context): File =
        File(context.noBackupFilesDir, dirName).apply { mkdirs() }

    private fun pidFile(context: Context): File =
        File(dataDir(context), "core.pid")

    private fun log(line: String) {
        synchronized(logRing) {
            logRing.addLast(line)
            while (logRing.size > 400) logRing.removeFirst()
        }
        Log.i(TAG, "[$id] $line")
    }

    fun logTail(maxLines: Int = 60): List<String> =
        synchronized(logRing) { logRing.takeLast(maxLines) }

    private fun binary(context: Context): File =
        File(context.applicationInfo.nativeLibraryDir, "libaether.so")

    fun identityPresent(context: Context): Boolean {
        val dir = dataDir(context)
        return listOf("tunnel.toml", "tunnel-masque.toml", "aether.toml")
            .any { name ->
                val f = File(dir, name)
                f.isFile && f.length() > 0 &&
                    f.readText().contains("device_id")
            }
    }

    private fun identityValid(context: Context, masque: Boolean): Boolean {
        val dir = dataDir(context)
        val wg = File(dir, "tunnel.toml")
        val wgOk = wg.isFile &&
            Regex("""(?m)^device_id = "\S+"""").containsMatchIn(wg.readText()) &&
            Regex("""(?m)^wg_private_key = "\S+"""").containsMatchIn(wg.readText())
        if (!masque) return wgOk
        val mq = File(dir, "tunnel-masque.toml")
        return mq.isFile &&
            Regex("""(?m)^device_id = "\S+"""").containsMatchIn(mq.readText()) &&
            Regex("""(?m)^cert_pem = "{1,3}\s*-----BEGIN""").containsMatchIn(mq.readText())
    }

    fun resetIdentity(context: Context) {
        stop()
        val dir = dataDir(context)
        dir.listFiles()?.forEach { f ->
            if (f.name.endsWith(".toml")) f.delete()
        }
        val network = AetherNetworkKey.key(context)
        AetherRegisterMemory.forget(context, network, id)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().remove("rung-$id").apply()
        log("identity cleared")
    }

    // ── registration ladder (port of ralysnd's AetherRegister,
    //    all six rungs; see the file header) ───────────────────

    private data class Rung(
        val key: String,
        val dns: String?,
        val tls: AetherTls = AetherTls.CHROME,
        val fragment: Boolean = false,
        val tlsHello: Boolean = false,
    )

    private val rungs = listOf(
        Rung("ech-udp", "udp://1.1.1.1"),
        Rung("ech-doh", "https://1.1.1.1/dns-query"),
        Rung("ech-tcp", "tcp://8.8.8.8"),
        Rung("plain", null),
        Rung("semipy", null, tls = AetherTls.SEMI_PYTHON, fragment = true),
        Rung("tlshello", null, tls = AetherTls.SEMI_PYTHON, tlsHello = true),
    )

    /**
     * Blocking: makes sure this slot has an identity for [protocol],
     * registering through the binary's own --register runs when it
     * has none. Returns a human-readable outcome. Budgets are
     * ralysnd's own: 35 s per rung, 180 s total for all six rungs —
     * the total is UNCHANGED from the four-rung ladder, so a line
     * that answers none of them is not kept waiting past the old
     * budget; the last rungs simply get whatever of it is left.
     * The winner is remembered per network ([AetherRegisterMemory]);
     * the legacy per-slot pref is read as a fallback and written
     * alongside, so a winner stored by builds 2032–2073 still
     * resolves and a downgrade still finds the new one.
     */
    fun ensureIdentity(context: Context, protocol: String): String {
        val masque = protocol == "masque" || protocol == "gool"
        if (identityValid(context, masque)) return "identity present"
        val which = when (protocol) {
            "wg" -> "wg"
            "gool" -> "gool"
            else -> "masque"
        }
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val network = AetherNetworkKey.key(context)
        val remembered = AetherRegisterMemory.get(context, network, id)
            ?: prefs.getString("rung-$id", null)
        val ordered = (listOfNotNull(rungs.firstOrNull { it.key == remembered }) + rungs).distinct()
        val started = SystemClock.elapsedRealtime()
        for (rung in ordered) {
            if (SystemClock.elapsedRealtime() - started > 180_000) break
            if (runRegister(context, which, rung)) {
                if (identityValid(context, masque)) {
                    AetherRegisterMemory.remember(context, network, id, rung.key)
                    prefs.edit().putString("rung-$id", rung.key).apply()
                    log("identity made (${rung.key})")
                    return "identity made (${rung.key})"
                }
            }
            if (rung.key == remembered) {
                AetherRegisterMemory.forget(context, network, id)
                prefs.edit().remove("rung-$id").apply()
            }
        }
        return "identity could not be made on this network"
    }

    /**
     * One --register run by [rung]. The tlshello rung dials out
     * through the local Xray exit (started before the run, stopped
     * after — a failed exit start fails the rung, it never falls
     * back to a direct dial, or the rung would be a plain run in
     * disguise). The exit's 12 s port wait sits OUTSIDE the rung's
     * 35 s clock, as in ralysnd — the clock covers the register
     * run itself.
     */
    private fun runRegister(context: Context, which: String, rung: Rung): Boolean {
        if (!rung.tlsHello) return runRegisterAttempt(context, which, rung, null)
        val port = AetherXrayExit.start(context) ?: return false
        try {
            return runRegisterAttempt(context, which, rung, AetherXrayExit.upstream(port))
        } finally {
            AetherXrayExit.stop(context, port)
        }
    }

    private fun runRegisterAttempt(
        context: Context,
        which: String,
        rung: Rung,
        upstream: String?,
    ): Boolean {
        val dir = dataDir(context)
        val bin = binary(context)
        if (!bin.exists()) return false
        val config = File(dir, "tunnel.toml").absolutePath
        val cmd = listOf(bin.absolutePath) +
            listOf(
                "--register", which,
                "--config", config,
                "--wg-config", config,
                "--masque-config", File(dir, "tunnel-masque.toml").absolutePath,
            ) +
            (if (rung.dns != null) listOf("--ech", "auto", "--ech-dns", rung.dns)
            else emptyList()) +
            listOf("--log-level", "info")
        val proc = try {
            ProcessBuilder(cmd).directory(dir).redirectErrorStream(true).apply {
                val env = environment()
                env.keys.filter {
                    it.startsWith("AETHER_") || it.lowercase().endsWith("_proxy")
                }.forEach { env.remove(it) }
                env["RUST_LOG"] = "info"
                env["HOME"] = dir.absolutePath
                env["TMPDIR"] = context.cacheDir.absolutePath
                env["SSL_CERT_DIR"] =
                    "/apex/com.android.conscrypt/cacerts:/system/etc/security/cacerts"
                // The rung's own: its ClientHello, the fragment,
                // and the Xray it dials out through.
                env.putAll(rung.tls.env)
                if (rung.fragment) env["AETHER_MASQUE_H2_FRAGMENT"] = "1"
                if (upstream != null) env["AETHER_UPSTREAM"] = upstream
            }.start()
        } catch (e: Exception) {
            log("register could not start: ${e.message}")
            return false
        }
        val reader = thread(isDaemon = true, name = "aether-$id-register-out") {
            runCatching {
                proc.inputStream.bufferedReader().forEachLine { /* drained */ }
            }
        }
        val deadline = SystemClock.elapsedRealtime() + 35_000
        while (true) {
            if (proc.waitUpTo(250)) break
            if (SystemClock.elapsedRealtime() > deadline) {
                proc.killHard()
                log("register $which (${rung.key}): gave up")
                return false
            }
        }
        reader.join(500)
        val code = runCatching { proc.exitValue() }.getOrDefault(-1)
        if (code != 0) log("register $which (${rung.key}) exited $code")
        return code == 0
    }

    // ── the tunnel process ────────────────────────────────────────

    @Synchronized
    fun start(context: Context, options: AetherRunOptions): Boolean {
        lastContext = context.applicationContext
        stop()
        reapOrphan(context)
        val bin = binary(context)
        if (!bin.exists()) {
            stage = AetherStage.FAILED
            lastError = "the Aether core is missing from this build"
            return false
        }
        val dir = dataDir(context)
        // Build 2074 (MasqueCarrier): an "auto" transport starts
        // on the carrier this network remembered (h2 where that
        // is what worked, else h3); an explicit h3/h2 is used
        // as-is and learns nothing. The resolved carrier is
        // recorded so a session that fails without connecting
        // can forget it in drain().
        val ridesMasque = options.protocol == "masque" || options.protocol == "gool"
        val effectiveOptions = if (ridesMasque && options.transport == MasqueCarrier.AUTO) {
            val startOn = MasqueCarrier.startOn(context)
            autoStartedCarrier = startOn
            options.copy(transport = startOn)
        } else {
            autoStartedCarrier = null
            options
        }
        currentProtocol = options.protocol
        reachedConnected = false
        val env = buildEnv(context, dir, effectiveOptions)
        try {
            val pb = ProcessBuilder(listOf(bin.absolutePath))
            pb.directory(dir)
            pb.redirectErrorStream(true)
            pb.redirectInput(File("/dev/null"))
            val e = pb.environment()
            e.putAll(env)
            val p = pb.start()
            process = p
            running = true
            stopping = false
            stage = AetherStage.STARTING
            stageLabel = AetherStage.STARTING.label()
            server = ""; rtt = ""; profile = ""; lastError = ""
            probeReasons.clear()
            startedAtMs = System.currentTimeMillis()
            try {
                val pid = p.javaClass.getMethod("pid").invoke(p) as? Long
                if (pid != null) pidFile(context).writeText(pid.toString())
            } catch (_: Throwable) {
            }
            log("engine started (protocol ${options.protocol}, transport ${effectiveOptions.transport}, scan ${options.scan})")
            thread(isDaemon = true, name = "aether-$id-out") { drain(p) }
            return true
        } catch (ex: Exception) {
            running = false
            stage = AetherStage.FAILED
            lastError = "the engine could not start: ${ex.message}"
            return false
        }
    }

    private fun buildEnv(
        context: Context,
        dir: File,
        o: AetherRunOptions,
    ): Map<String, String> {
        val env = HashMap<String, String>()
        env["RUST_BACKTRACE"] = "1"
        // Build 2055 (audit B-M4): the prober runs at debug,
        // not trace, outside failure windows — trace logged
        // every probe attempt for the whole session. The stage
        // classifier's failure lines ("no clean endpoint
        // found", "handshake failed") are summary lines at
        // info/warn level, so the FAILED stage still classifies;
        // device check: force a no-clean-endpoint failure and
        // confirm the UI still shows FAILED.
        env["RUST_LOG"] = "info,aether::prober=debug"
        env["AETHER_SOCKS"] = "127.0.0.1:$socksPort"
        env["AETHER_PROTOCOL"] = o.protocol
        env["AETHER_SCAN"] = o.scan
        env["AETHER_IP"] = o.ip
        env["AETHER_QUICK_RECONNECT"] = if (o.peer.isNullOrBlank()) "1" else "0"
        env["AETHER_CONFIG"] = File(dir, "aether.toml").absolutePath
        env["AETHER_NOIZE"] = when {
            o.noize.isNotEmpty() -> o.noize
            o.protocol == "masque" -> "firewall"
            else -> "balanced"
        }
        if (o.protocol == "masque" || o.protocol == "gool") {
            env["AETHER_MASQUE_HTTP2"] = if (o.transport == "h2") "1" else "0"
            if (o.ech.isNotEmpty()) env["AETHER_ECH"] = o.ech
            if (o.fragment) env["AETHER_MASQUE_H2_FRAGMENT"] = "1"
        }
        if (o.protocol == "wg" || o.protocol == "gool") {
            env["AETHER_WG_KEEPALIVE"] = o.keepalive.coerceIn(5, 120).toString()
            // 120 s, not the core's ~12 s: an idle tunnel looks
            // identical to a dead one at 12 s (ralysnd's finding).
            env["AETHER_WG_STALE_SECS"] = "120"
        }
        if (!o.peer.isNullOrBlank()) {
            env["AETHER_PEER"] = o.peer
            env["AETHER_WG_PEER"] = o.peer
        }
        env["HOME"] = dir.absolutePath
        env["TMPDIR"] = context.cacheDir.absolutePath
        env["SSL_CERT_DIR"] =
            "/apex/com.android.conscrypt/cacerts:/system/etc/security/cacerts"
        return env
    }

    private fun drain(p: Process) {
        try {
            BufferedReader(InputStreamReader(p.inputStream, Charsets.UTF_8)).use { r ->
                while (true) {
                    val line = r.readLine() ?: break
                    handleLine(line)
                }
            }
        } catch (_: Exception) {
        }
        val code = runCatching { p.waitFor() }.getOrDefault(-1)
        synchronized(this) {
            if (process === p) {
                process = null
                running = false
                pidFilePath()?.delete()
                if (!stopping) {
                    stage = AetherStage.CRASHED
                    stageLabel = "Engine exited (code $code)"
                    lastError = "the engine exited on its own (code $code)"
                    log("engine exited on its own (code $code)")
                    // Build 2074 (MasqueCarrier): a session that
                    // started on a remembered carrier and died
                    // without ever connecting proves the memory
                    // wrong for this network — forget it so the
                    // next connect tries from HTTP/3 again. A
                    // session that connected, or one the user
                    // stopped, keeps what it learned.
                    val autoCarrier = autoStartedCarrier
                    if (autoCarrier != null && !reachedConnected) {
                        lastContext?.let { MasqueCarrier.forget(it) }
                        log("auto carrier $autoCarrier failed without connecting — forgotten")
                    }
                } else {
                    stage = AetherStage.STOPPED
                    stageLabel = AetherStage.STOPPED.label()
                }
            }
        }
    }

    @Volatile private var lastContext: Context? = null
    private fun pidFilePath(): File? =
        lastContext?.let { pidFile(it) }

    private fun handleLine(line: String) {
        if (AetherStageParser.isNoise(line)) return
        // Build 2074 (MasqueCarrier): learn the carrier from the
        // core's own "Accepted … via HTTP/2" line — the carrier
        // that really carried the session, not the one asked for.
        val ctx = lastContext
        if (ctx != null && (currentProtocol == "masque" || currentProtocol == "gool")) {
            MasqueCarrier.onCoreLog(ctx, line)
        }
        AetherStageParser.probeFailureReason(line)?.let { reason ->
            synchronized(probeReasons) {
                probeReasons[reason] = (probeReasons[reason] ?: 0) + 1
            }
            return
        }
        log(line.take(300))
        if (AetherStageParser.isPanicLine(line)) {
            lastError = "the engine reported a panic — see the log"
        }
        val detail = AetherStageParser.extractDetail(line)
        if (detail.server != null) server = detail.server
        if (detail.rtt != null) rtt = detail.rtt
        if (detail.profile != null) profile = detail.profile
        val next = AetherStageParser.classify(line) ?: return
        val cur = stage
        if (next.isRegression || next.progressRank >= cur.progressRank ||
            cur.progressRank < 0
        ) {
            stage = next
            stageLabel = next.label()
            if (next == AetherStage.CONNECTED) reachedConnected = true
        }
    }

    @Synchronized
    fun stop() {
        val p = process ?: run {
            running = false
            if (stage != AetherStage.FAILED && stage != AetherStage.CRASHED) {
                stage = AetherStage.IDLE
            }
            return
        }
        stopping = true
        process = null
        running = false
        stage = AetherStage.STOPPED
        stageLabel = AetherStage.STOPPED.label()
        p.killHard()
    }

    private fun reapOrphan(context: Context) {
        lastContext = context.applicationContext
        val file = pidFile(context)
        try {
            val pid = file.readText().trim().toIntOrNull() ?: return
            val cmdline = File("/proc/$pid/cmdline")
            if (cmdline.exists() && cmdline.readText().contains("libaether.so")) {
                android.os.Process.killProcess(pid)
                log("reaped orphan core pid $pid")
            }
        } catch (_: Exception) {
        } finally {
            file.delete()
        }
    }

    // ── verification (CfWarp's rule: connected means warp=on
    //    through the tunnel, proven by Cloudflare's trace) ───────

    /** One trace fetch through this slot's SOCKS. Null on failure. */
    fun trace(): Map<String, String>? {
        return try {
            val proxy = Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", socksPort))
            val conn = URL("https://www.cloudflare.com/cdn-cgi/trace")
                .openConnection(proxy) as HttpURLConnection
            conn.connectTimeout = 8_000
            conn.readTimeout = 8_000
            conn.setRequestProperty("User-Agent", "Mozilla/5.0")
            val body = conn.inputStream.bufferedReader().readText()
            val out = LinkedHashMap<String, String>()
            for (line in body.lineSequence()) {
                val i = line.indexOf('=')
                if (i > 0) out[line.substring(0, i).trim()] = line.substring(i + 1).trim()
            }
            out.ifEmpty { null }
        } catch (_: Exception) {
            null
        }
    }

    fun state(context: Context): Map<String, Any> {
        val topReason = synchronized(probeReasons) {
            probeReasons.maxByOrNull { it.value }?.let { "${it.key} ×${it.value}" } ?: ""
        }
        return mapOf(
            "engine" to id,
            "running" to running,
            "stage" to stage.name.lowercase(),
            "stageLabel" to stageLabel,
            "connected" to (running && stage == AetherStage.CONNECTED),
            "server" to server,
            "rtt" to rtt,
            "profile" to profile,
            "socksPort" to socksPort,
            "sinceMs" to startedAtMs,
            "error" to lastError,
            "identity" to identityPresent(context),
            "probeTopReason" to topReason,
            "log" to logTail(60).joinToString("\n"),
        )
    }

    companion object {
        private const val TAG = "AetherCore"
        private const val PREFS = "aether_slots"
    }
}

object AetherCore {
    val cfwarp = AetherSlot("cfwarp", 20870, "cfwarp")
    val masque = AetherSlot("masque", 20810, "aether-ralysnd")

    fun slot(id: String): AetherSlot = when (id) {
        "cfwarp" -> cfwarp
        else -> masque
    }

    fun stopAll() {
        cfwarp.stop()
        masque.stop()
    }
}

// Process helpers — ports of ralysnd's utils (alive / killHard /
// waitUpTo), kept local so the shim has no cross-tree dependency.
internal fun Process.alive(): Boolean =
    try {
        exitValue()
        false
    } catch (_: IllegalThreadStateException) {
        true
    }

internal fun Process.killHard() {
    try {
        destroy()
    } catch (_: Exception) {
    }
    if (!waitUpTo(600)) {
        try {
            destroyForcibly()
        } catch (_: Exception) {
        }
        waitUpTo(1500)
    }
}

internal fun Process.waitUpTo(ms: Long): Boolean =
    try {
        waitFor(ms, TimeUnit.MILLISECONDS)
    } catch (_: Exception) {
        !alive()
    }
