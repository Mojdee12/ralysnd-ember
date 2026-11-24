package com.ralysnd.ember

import android.content.Context
import android.os.SystemClock
import android.util.Log
import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.InputStreamReader
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
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
 * fallback. Build 2083 replaces the 2074 single-carrier
 * memory with ralysnd's carrier ladder: with transport
 * "auto" (now the default), one connect walks H3 → H2 →
 * H2+fragment → H2+semi-python+fragment → H2+semi-python+
 * tlshello (MasqueRung), each rung a real engine run proven
 * by the warp trace and the data proof before any TUN, the
 * winner remembered per network (MasqueCarrier). AETHER_IP
 * resolves per network (AetherFamily, the CfFamily port)
 * and AETHER_MASQUE_H2_FRAGMENT is always written. Budgets
 * are ralysnd's own: 35 s per rung, 180 s total for all six
 * rungs.
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
        Regex("""wireguard tunnel validated""", RegexOption.IGNORE_CASE) to AetherStage.VALIDATE,
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

    private val DATA_PLANE_RETRY_RES: List<Regex> = listOf(
        Regex("""found no data-plane endpoint.*trying next profile""", RegexOption.IGNORE_CASE),
        Regex("""no usable masque gateway found""", RegexOption.IGNORE_CASE),
        Regex("""no usable.*endpoint found""", RegexOption.IGNORE_CASE),
    )

    /**
     * Build 2080: a data-plane retry line — the core had a
     * tunnel and is hunting for another profile because its
     * data plane failed. Before CONNECTED these are ordinary
     * scan progress; after CONNECTED they withdraw readiness
     * (AetherSlot's demotion), because the stage machine
     * itself cannot: these lines classify SCAN, which ranks
     * below CONNECTED and is not a regression signal.
     */
    fun isDataPlaneRetry(line: String): Boolean =
        DATA_PLANE_RETRY_RES.any { it.containsMatchIn(line) }

    private val DATA_PLANE_PROOF_RES: List<Regex> = listOf(
        Regex("""masque tunnel validated""", RegexOption.IGNORE_CASE),
        // Build 2116 (B5-8): the WireGuard engine's own
        // end-to-end confirmation ("wireguard tunnel
        // validated (end-to-end data confirmed)") — the
        // same class of evidence as the MASQUE line; it was
        // missing here, so a WG run's validation was never
        // recorded as proof.
        Regex("""wireguard tunnel validated""", RegexOption.IGNORE_CASE),
        Regex("""cached (gateway|endpoint) .* still works""", RegexOption.IGNORE_CASE),
    )

    private val RTT_MS_RE =
        Regex("""rtt\s+(\d+)\s*ms""", RegexOption.IGNORE_CASE)

    /** The endpoint RTT a line reports, in ms (build 2116,
     *  B5-9 — the data probe scales its read budget to the
     *  measured path). */
    fun rttMs(line: String): Int? =
        RTT_MS_RE.find(line)?.groupValues?.get(1)?.toIntOrNull()

    private val IDENTITY_REFUSAL_RES: List<Regex> = listOf(
        Regex("""CERTIFICATE_AND_PRIVATE_KEY_MISMATCH"""),
        Regex("""refused identity""", RegexOption.IGNORE_CASE),
        Regex("""identity needs a certificate""", RegexOption.IGNORE_CASE),
    )

    /** Build 2116 (B5-3): the engine refused the stored
     *  identity itself — a cert/key mismatch or a
     *  deregistered device — as opposed to a network
     *  failure on the way to it. */
    fun isIdentityRefusal(line: String): Boolean =
        IDENTITY_REFUSAL_RES.any { it.containsMatchIn(line) }

    /**
     * Build 2080: the core's own word that its data plane
     * carried real traffic again — clears a data-plane
     * demotion taken by an earlier retry line.
     */
    fun isDataPlaneProof(line: String): Boolean =
        DATA_PLANE_PROOF_RES.any { it.containsMatchIn(line) }

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
 * One MASQUE carrier: how a MASQUE-carried run reaches
 * Cloudflare. Port of ralysnd's AetherCarrier (build 2083).
 *
 * MASQUE — and gool, which since Aether 2.3.0 carries its
 * WireGuard hop inside a MASQUE tunnel, and mim (build
 * 2129), whose two hops are both MASQUE on the same carrier
 * (the binary's own rule) — rides either HTTP/3
 * (QUIC, UDP 443) or HTTP/2 (TCP 443). Which one a line lets
 * through is a property of the line: a carrier that drops
 * QUIC needs H2, and on Irancell-type lines that read the
 * server name from one TCP packet H2 needs its ClientHello
 * split as well (the core's fragment, at its default sizes).
 * The last two rungs are PattNG's for those filters (Aether
 * 2.4.0 takes them): the semi-python ClientHello with the
 * fragment, and the same ClientHello dialled out through a
 * local Xray that cuts it into TLS records ([AetherXrayExit],
 * tlshello).
 */
enum class MasqueRung(
    val key: String,
    val transport: String,
    val fragment: Boolean,
    val label: String,
    val tls: AetherTls = AetherTls.CHROME,
    val tlsHelloExit: Boolean = false,
) {
    H3("h3", "h3", false, "HTTP/3"),
    H2("h2", "h2", false, "HTTP/2"),
    H2_FRAGMENT("h2frag", "h2", true, "HTTP/2 + fragment"),
    H2_SEMI_PYTHON("h2semipy", "h2", true, "HTTP/2 + semi-python + fragment", AetherTls.SEMI_PYTHON),
    H2_TLSHELLO("h2tlshello", "h2", false, "HTTP/2 + semi-python + tlshello", AetherTls.SEMI_PYTHON, tlsHelloExit = true);

    /** [o] riding this carrier: its transport, fragment, ClientHello and exit. */
    fun applyTo(o: AetherRunOptions): AetherRunOptions =
        o.copy(
            transport = transport,
            fragment = fragment,
            tls = tls,
            tlsHelloExit = tlsHelloExit,
        )

    companion object {
        fun byKey(key: String?): MasqueRung? =
            values().firstOrNull { it.key == key }

        /** The order to try on a network: what worked there last first, then the rest as listed. */
        fun ladder(remembered: MasqueRung?): List<MasqueRung> =
            (listOfNotNull(remembered) + values()).distinct()
    }
}

/**
 * Per network (hashed key, never an SSID): the carrier rung
 * that last carried data there. Port of ralysnd's
 * AetherCarrierMemory, on the prefs the 2074 MasqueCarrier
 * kept — a value stored by builds 2074–2082 is a bare "h3" or
 * "h2", which ARE the first two rung keys, so an old memory
 * resolves as that rung unchanged.
 *
 * Build 2083 supersedes the 2074 learning rule: the winner
 * is no longer read off the core's "Accepted … via HTTP/2"
 * line (an accepted gateway whose data plane then failed
 * taught the wrong carrier, and a pinned-H3 session never
 * learned at all). The ladder in [AetherSlot.connectMasque]
 * remembers a rung only after it carried real data (the
 * warp trace + data proof), and forgets a remembered rung
 * the first time it fails.
 */
object MasqueCarrier {
    const val AUTO = "auto"
    private const val PREFS = "masque_carrier"

    /** The rung that last carried data on this network, or null when none is remembered. */
    fun rememberedRung(context: Context): MasqueRung? =
        MasqueRung.byKey(
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(AetherNetworkKey.key(context), null),
        )

    /** [rung] carried data on this network: start from it next time. */
    fun remember(context: Context, rung: MasqueRung) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(AetherNetworkKey.key(context), rung.key).apply()
    }

    /** What this network remembered is tested again next time. */
    fun forget(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .remove(AetherNetworkKey.key(context)).apply()
    }
}

/**
 * Which address family the Aether cores scan on this
 * network — port of ralysnd's CfFamily.warpScanFamily +
 * hasIpv6Route (build 2083). The recorded reason is
 * ralysnd's 2026-09-28 incident: a filter left Cloudflare
 * IPv4 carrying nothing on the phone's network, and a
 * v4-only scan then had nothing to find. An explicit
 * "v6"/"both" stands; the default "v4" is resolved per
 * network — "both" whenever an IPv6 route exists, else
 * "v4". The route verdict is remembered for a minute; a
 * verdict taken on the main thread (where the reachability
 * socket is refused) is address-only and never cached.
 */
object AetherFamily {
    private const val CACHE_MS = 60_000L

    @Volatile private var routeAt = 0L
    @Volatile private var route = false

    /** The stored family, resolved for the current network. */
    fun resolve(stored: String?): String {
        if (stored == "v6" || stored == "both") return stored
        return if (hasIpv6RouteCached()) "both" else "v4"
    }

    fun hasIpv6RouteCached(): Boolean {
        val now = System.currentTimeMillis()
        if (now - routeAt <= CACHE_MS) return route
        if (onMainThread()) return hasIpv6Route()
        route = hasIpv6Route()
        routeAt = now
        return route
    }

    private fun onMainThread(): Boolean =
        runCatching {
            android.os.Looper.myLooper() == android.os.Looper.getMainLooper()
        }.getOrDefault(false)

    /** A global IPv6 address on an up interface, and — off
     *  the main thread — a socket that reaches Cloudflare
     *  over it. */
    private fun hasIpv6Route(): Boolean {
        val global = runCatching {
            java.net.NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { it.inetAddresses.toList() }
                .any {
                    it is java.net.Inet6Address &&
                        !it.isLinkLocalAddress && !it.isSiteLocalAddress &&
                        !it.isLoopbackAddress &&
                        (it.address[0].toInt() and 0xfe) != 0xfc
                }
        }.getOrDefault(false)
        if (!global) return false
        // Android refuses a socket on the main thread, and
        // that refusal is not "no IPv6": there the address
        // is all that can be known.
        if (onMainThread()) return true
        return runCatching {
            java.net.Socket().use {
                it.connect(
                    java.net.InetSocketAddress("2606:4700:4700::1111", 443),
                    2_500,
                )
                true
            }
        }.getOrDefault(false)
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
        // Build 2095 (audit 6-4): sweep stale exit logs from
        // earlier runs (kills, crashes) — the dir otherwise
        // grows one log per run without bound.
        try {
            dir.listFiles()?.forEach { f ->
                if (f.name.startsWith("exit-") && f.name.endsWith(".log")) {
                    f.delete()
                }
            }
        } catch (_: Exception) {
        }
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
            // Build 2095 (audit 6-4): a failed start deletes
            // its own log as well.
            try {
                logFile.delete()
            } catch (_: Exception) {
            }
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
            val dir = File(XrayVpnService.workDir(context), "aether-exit")
            File(dir, "exit-$p.json").delete()
            // Build 2095 (third-pass audit 6-4): the exit's
            // log goes too — it used to outlive every run,
            // one file per ephemeral port, forever.
            File(dir, "exit-$p.log").delete()
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
    val protocol: String = "masque",   // masque | wg | gool | mim (build 2129)
    val scan: String = "turbo",        // turbo|balanced|thorough|stealth|ironclad
    val ip: String = "v4",             // v4 | v6 | both (the default is resolved per network, AetherFamily)
    val transport: String = "auto",    // h3 | h2 | auto (masque/gool carrier; auto = the ladder, build 2083)
    val ech: String = "",
    val fragment: Boolean = false,
    val noize: String = "",
    val keepalive: Int = 25,
    val peer: String? = null,
    // Build 2083: the run's ClientHello — set by the carrier
    // ladder's semi-python rungs (MasqueRung); CHROME (nothing
    // set) everywhere else, exactly as in ralysnd.
    val tls: AetherTls = AetherTls.CHROME,
    // Build 2083: dial this run out through the local Xray
    // tlshello exit (AetherXrayExit) — the ladder's last rung.
    val tlsHelloExit: Boolean = false,
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

    // Build 2080: set when the core reports a data-plane
    // retry AFTER having connected. The stage stays CONNECTED
    // (the retry lines classify SCAN, which can never demote
    // it), so readiness is withdrawn here instead — every
    // consumer reads [isConnected], never the bare stage.
    // Clears when the core proves its data plane again (its
    // validation line, or a fresh listener on our own port).
    @Volatile var dataPlaneStale: Boolean = false
        private set

    // Build 2116 (B5-8): when the engine's own validation
    // line ("… tunnel validated (end-to-end data
    // confirmed)") landed in THIS run — elapsedRealtime,
    // 0 = never. The engine confirms its tunnel in-protocol
    // before serving SOCKS; that is stronger evidence than
    // a cold re-probe through third-party endpoints, so
    // dataProbe does not let a re-probe read timeout veto
    // a run carrying a fresh stamp (the 2026-11-19 device
    // case: endpoint RTT 699 ms, engine validated, the
    // ladder's http204 rung timed out and refused a
    // working tunnel). A data-plane retry line after the
    // stamp withdraws it (handleLine), exactly like the
    // demotion above.
    @Volatile var engineValidatedAtMs: Long = 0
        private set

    /** The engine's validation still counts as fresh
     *  evidence for a proof decision. */
    fun engineValidationFresh(): Boolean =
        engineValidatedAtMs > 0 &&
            SystemClock.elapsedRealtime() - engineValidatedAtMs <=
                ENGINE_VALIDATION_FRESH_MS

    // Build 2116 (B5-9): the last endpoint RTT the engine
    // reported this run, in ms — the data probe scales its
    // per-request read budget to the measured path instead
    // of one fixed budget for every network.
    @Volatile var lastRttMs: Int = 0
        private set

    // Build 2116 (B5-3): the engine refused this slot's
    // stored identity (cert/key mismatch or a deregistered
    // device). Surfaced on the state map so the failure
    // can name the Reset path instead of reading as a
    // network problem. Cleared by every start() and by
    // resetIdentity.
    @Volatile var identityRefused: Boolean = false
        private set

    /** Connected means: running, at the CONNECTED stage, and
     *  carrying no data-plane demotion (build 2080). */
    fun isConnected(): Boolean =
        running && stage == AetherStage.CONNECTED && !dataPlaneStale

    // Build 2083: set when one full scan cycle of the current
    // run ended with no gateway (handleLine) — the carrier
    // ladder's advance signal (connectMasque). Reset by every
    // start(); only counts before the run ever connected.
    @Volatile var scanCycleFailed: Boolean = false
        private set

    // Build 2083: the carrier ladder's walk state — a user
    // stop during a walk sets the abort the walk polls, so a
    // disconnect lands promptly instead of after the rung.
    @Volatile private var ladderActive: Boolean = false
    @Volatile private var ladderAbort: Boolean = false

    // Build 2083: the tlshello exit port this run dials out
    // through (AetherXrayExit), 0 when the run has none. The
    // exit is started in start() and stopped with the run.
    @Volatile private var exitPort: Int = 0

    private var process: Process? = null
    @Volatile private var stopping: Boolean = false
    // Whether the running session ever reached CONNECTED —
    // the scan-cycle latch and the data-plane demotion both
    // key off it (a retry line means one thing before the
    // session exists, another after).
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
        if (!mq.isFile) return false
        val text = mq.readText()
        // Build 2116 (B5-3): presence of a BEGIN marker was
        // the whole check — a half-written or truncated
        // identity passed forever and the engine died on it
        // at every start. The MASQUE identity is a matched
        // pair: a COMPLETE certificate block and a COMPLETE
        // private-key block beside the device id. Anything
        // less is not an identity — ensureIdentity replaces
        // it through the registration ladder instead of the
        // run trusting a corpse. (The pair's cryptographic
        // match is the engine's own check — it reports
        // CERTIFICATE_AND_PRIVATE_KEY_MISMATCH, which
        // handleLine records as an identity refusal.)
        return Regex("""(?m)^device_id = "\S+"""").containsMatchIn(text) &&
            text.contains("-----BEGIN CERTIFICATE-----") &&
            text.contains("-----END CERTIFICATE-----") &&
            Regex("""(?m)^key_pem = """).containsMatchIn(text) &&
            text.contains("PRIVATE KEY-----") &&
            text.contains("-----END")
    }

    fun resetIdentity(context: Context) {
        stop()
        identityRefused = false
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
        // Build 2129: mim joins the MASQUE family here — both
        // of its hops are MASQUE and, unlike gool (whose inner
        // WireGuard identity is its own <masque config>-gool
        // .toml that --register gool makes), the binary keeps
        // no separate identity file for mim: the slot's one
        // MASQUE identity (tunnel-masque.toml) is what both
        // hops present, so it is also what identityValid
        // proves and what the register ladder makes.
        val masque = protocol == "masque" || protocol == "gool" ||
            protocol == "mim"
        if (identityValid(context, masque)) return "identity present"
        // Build 2095 (third-pass audit 3-2): a missing engine
        // binary is not a network failure — every register
        // rung used to fail the same way and the caller
        // reported "could not be made on this network",
        // sending the user to debug their network for an
        // install problem.
        if (!binary(context).isFile) {
            return "the engine binary is missing from this install — reinstall the app"
        }
        val which = when (protocol) {
            "wg" -> "wg"
            "gool" -> "gool"
            // Build 2129: the binary accepts --register mim,
            // but what a mim run needs registered is the
            // shared MASQUE identity above — the masque kind
            // is the run whose product identityValid checks.
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
        stopLocked()
        reapOrphan(context)
        val bin = binary(context)
        if (!bin.exists()) {
            stage = AetherStage.FAILED
            lastError = "the Aether core is missing from this build"
            return false
        }
        val dir = dataDir(context)
        // Build 2083: an "auto" transport reaching start()
        // directly (the endpoint scan, or any non-ladder start)
        // runs on the rung this network remembers — the full
        // rung, fragment / ClientHello / exit included — or
        // HTTP/3 when it remembers none. The CONNECT path does
        // not resolve here: it walks every rung in
        // connectMasque until one carries data.
        val ridesMasque = options.protocol == "masque" ||
            options.protocol == "gool" || options.protocol == "mim"
        val effectiveOptions = if (ridesMasque && options.transport == MasqueCarrier.AUTO) {
            (MasqueCarrier.rememberedRung(context) ?: MasqueRung.H3)
                .applyTo(options)
        } else {
            options
        }
        reachedConnected = false
        dataPlaneStale = false
        scanCycleFailed = false
        // Build 2116 (B5-8/B5-9/B5-3): a fresh run carries
        // no validation stamp, no measured RTT and no
        // identity verdict from the last one.
        engineValidatedAtMs = 0
        lastRttMs = 0
        identityRefused = false
        // Build 2083: a tlshello run dials out through the
        // local Xray exit — started before the core, stopped
        // with the run (stopLocked / drain). A failed exit
        // start fails the run; it never falls back to a direct
        // dial, or the rung would be a plain run in disguise
        // (the register ladder's rule for its tlshello rung).
        var upstream: String? = null
        if (effectiveOptions.tlsHelloExit) {
            val p = AetherXrayExit.start(context)
            if (p == null) {
                stage = AetherStage.FAILED
                lastError = "the tlshello exit could not start"
                return false
            }
            exitPort = p
            upstream = AetherXrayExit.upstream(p)
        }
        val env = buildEnv(context, dir, effectiveOptions, upstream)
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
                if (pid != null) AtomicFile.writeText(pidFile(context), pid.toString())
            } catch (_: Throwable) {
            }
            log("engine started (protocol ${options.protocol}, transport ${effectiveOptions.transport}, scan ${options.scan})")
            thread(isDaemon = true, name = "aether-$id-out") { drain(p) }
            return true
        } catch (ex: Exception) {
            stopExit()
            running = false
            stage = AetherStage.FAILED
            lastError = "the engine could not start: ${ex.message}"
            return false
        }
    }

    /** Stops this run's tlshello exit, if it started one. */
    private fun stopExit() {
        val p = exitPort
        if (p == 0) return
        exitPort = 0
        lastContext?.let { AetherXrayExit.stop(it, p) }
    }

    // ── the MASQUE carrier ladder (build 2083, port of
    //    ralysnd's AetherTunEngine.connectWithCarrier) ───────
    //
    // One connect, every carrier: with transport "auto" the
    // rungs of MasqueRung.ladder run in order — the rung this
    // network remembered first — and each rung is a real
    // engine run proven by the warp trace and the 2080 data
    // proof BEFORE the caller raises any TUN. A rung fails
    // after ONE full core scan cycle (scanCycleFailed) and
    // the walk advances; an identical scan is never replayed
    // on the next rung because the carrier itself changed.
    // The winner is remembered per network; a remembered
    // rung that fails is forgotten. The whole walk is
    // bounded by ladderTotalMs, and a user stop aborts it
    // (stop() sets ladderAbort) — no connect can sit in
    // "connecting" forever. Blocking: call off the main
    // thread (MainActivity's inBackground, like the
    // registration ladder). The identity is the caller's
    // step, as in the Dart connect flow.

    /**
     * Walks the carrier ladder for a MASQUE-family [options]
     * whose transport is "auto". Returns the verdict map the
     * platform channel carries: {ok, carrier, label} on
     * success (the engine is left RUNNING, proven — the
     * caller raises the TUN), {ok: false, error} on total
     * failure (the engine is stopped).
     */
    fun connectMasque(context: Context, options: AetherRunOptions): Map<String, Any> {
        lastContext = context.applicationContext
        val remembered = MasqueCarrier.rememberedRung(context)
        ladderActive = true
        ladderAbort = false
        val startedAll = SystemClock.elapsedRealtime()
        var lastDetail = ""
        try {
            for (rung in MasqueRung.ladder(remembered)) {
                if (ladderAbort) {
                    return mapOf("ok" to false, "error" to "the connect was stopped")
                }
                if (SystemClock.elapsedRealtime() - startedAll >
                    ladderTotalMs(options.scan)
                ) {
                    lastDetail = "the ladder's time budget ran out"
                    break
                }
                log(
                    "carrier ladder: trying ${rung.label}" +
                        if (rung == remembered) {
                            " (remembered on this network)"
                        } else {
                            ""
                        },
                )
                val outcome = bringUp(context, rung.applyTo(options))
                if (outcome.error == null) {
                    MasqueCarrier.remember(context, rung)
                    log(
                        "carrier ladder: ${rung.label} carried data" +
                            " — remembered for this network",
                    )
                    return mapOf(
                        "ok" to true,
                        "carrier" to rung.key,
                        "label" to rung.label,
                        // Build 2116 (B5-1): the rung carried
                        // data but no trace verified the exit
                        // — the Dart side stamps the session
                        // "exit unverified" instead of plain
                        // Connected (and persists the stamp,
                        // B5-7).
                        "exitUnverified" to outcome.exitUnverified,
                    )
                }
                lastDetail = "${rung.label}: ${outcome.error}"
                log("carrier ladder: ${rung.label} failed (${outcome.error})")
                // What worked here before does not any more:
                // the next connect tests the ladder again.
                if (rung == remembered) MasqueCarrier.forget(context)
            }
        } catch (e: Exception) {
            lastDetail = "the connect failed: ${e.message}"
        } finally {
            ladderActive = false
        }
        stopLocked()
        val reason = topProbeReason()
        return mapOf(
            "ok" to false,
            "error" to "no MASQUE route worked on this network" +
                (if (reason.isNotEmpty()) {
                    " — most probes failed with: $reason"
                } else {
                    ""
                }) +
                (if (lastDetail.isNotEmpty()) " (last: $lastDetail)" else ""),
        )
    }

    /** One ladder rung's outcome: [error] null on success
     *  (the engine stays up), else the failure in a few
     *  words (the engine is stopped). [exitUnverified]
     *  marks a success the data proof carried but no trace
     *  ever verified (build 2116, B5-1). */
    private data class RungOutcome(
        val error: String?,
        val exitUnverified: Boolean = false,
    )

    /**
     * One ladder rung: a real engine run on [opts], proven by
     * the 2080 data proof FIRST and the warp trace as its
     * advisory (build 2116, B5-1 — the 2115 verdict rule the
     * Dart flow already applies, brought to the ladder the
     * 2115 build deliberately left): the data proof is the
     * stronger evidence, so it runs first and is the only
     * proof whose failure kills the rung; a trace that lands
     * warp=on verifies the exit, a trace that ANSWERS
     * warp=off is still fatal (the exit is proven not to be
     * WARP), and a trace that never lands leaves the rung
     * standing with its exit unverified instead of tearing
     * down a tunnel that demonstrably carries data.
     * Port of ralysnd's AetherTunEngine.bringUp.
     */
    private fun bringUp(context: Context, opts: AetherRunOptions): RungOutcome {
        if (!start(context, opts)) {
            return RungOutcome(lastError.ifEmpty { "the engine could not start" })
        }
        if (!awaitConnected(opts.scan)) {
            val why = when {
                ladderAbort -> "stopped"
                stage == AetherStage.FAILED ||
                    stage == AetherStage.CRASHED ->
                    lastError.ifEmpty { "the engine failed" }
                scanCycleFailed -> "no gateway found in one scan"
                else -> "no gateway in time"
            }
            stopLocked()
            return RungOutcome(why)
        }
        // The 2080 data proof, ralysnd's per-rung rule: real
        // transfers through the SOCKS, or the rung has not
        // carried anything. One retry — the core may still be
        // settling its chosen gateway in the first seconds
        // after CONNECTED (the 2080 Dart flow's finding).
        var verdict = dataProbe()
        if (verdict["ok"] != true) {
            try {
                Thread.sleep(3_000)
            } catch (_: InterruptedException) {
            }
            if (!ladderAbort && isConnected()) verdict = dataProbe()
        }
        if (verdict["ok"] != true) {
            val detail = verdict["detail"] as? String ?: ""
            stopLocked()
            return RungOutcome(
                "data did not pass (${detail.ifEmpty { "no detail" }})",
            )
        }
        return when (warpProofOutcome()) {
            WarpProof.VERIFIED -> RungOutcome(null)
            WarpProof.SILENT -> RungOutcome(null, exitUnverified = true)
            WarpProof.OFF -> {
                stopLocked()
                RungOutcome("the exit answered, but not through WARP (warp=off)")
            }
        }
    }

    private enum class WarpProof { VERIFIED, OFF, SILENT }

    /**
     * Polls this run to CONNECTED (stage + demotion-aware
     * readiness). Ends early on every shape a rung can die
     * of: the engine failed or exited, a user stop, or ONE
     * full scan cycle with no gateway (scanCycleFailed).
     * The backstop is the scan mode's own deadline plus
     * headroom — ralysnd's awaitSocks budget table.
     */
    private fun awaitConnected(scan: String): Boolean {
        val deadline = SystemClock.elapsedRealtime() + rungBudgetMs(scan)
        while (SystemClock.elapsedRealtime() < deadline) {
            if (ladderAbort) return false
            if (isConnected()) return true
            if (stage == AetherStage.FAILED ||
                stage == AetherStage.CRASHED
            ) {
                return false
            }
            if (!running) return false
            if (scanCycleFailed) return false
            try {
                Thread.sleep(500)
            } catch (_: InterruptedException) {
                return false
            }
        }
        return isConnected()
    }

    /**
     * The warp proof for a rung (build 2116, B5-1): the
     * trace's three honest outcomes — VERIFIED (a trace said
     * warp=on/plus), OFF (a trace ANSWERED warp=off: the
     * exit is proven not to be WARP) and SILENT (no trace
     * ever landed inside the budget, which says something
     * about the trace fetch and nothing about the tunnel
     * the data proof just carried). Retried briefly while
     * a fresh gateway settles, as before.
     */
    private fun warpProofOutcome(): WarpProof {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        var sawOff = false
        while (SystemClock.elapsedRealtime() < deadline) {
            if (ladderAbort) return WarpProof.SILENT
            val t = trace()
            if (t != null) {
                if (t["warp"] == "on" || t["warp"] == "plus") {
                    return WarpProof.VERIFIED
                }
                if (t["warp"] == "off") sawOff = true
            }
            try {
                Thread.sleep(2_000)
            } catch (_: InterruptedException) {
                return WarpProof.SILENT
            }
        }
        return if (sawOff) WarpProof.OFF else WarpProof.SILENT
    }

    private fun buildEnv(
        context: Context,
        dir: File,
        o: AetherRunOptions,
        upstream: String? = null,
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
        // Build 2083: the stored family is resolved per
        // network (AetherFamily, the CfFamily port) — the
        // default "v4" becomes "both" whenever this network
        // has an IPv6 route; an explicit "v6"/"both" stands.
        // This buildEnv serves BOTH slots, so the cfwarp
        // slot's scans resolve the same way — ralysnd applies
        // the identical rule in its single toEnv.
        env["AETHER_IP"] = AetherFamily.resolve(o.ip)
        env["AETHER_QUICK_RECONNECT"] = if (o.peer.isNullOrBlank()) "1" else "0"
        env["AETHER_CONFIG"] = File(dir, "aether.toml").absolutePath
        env["AETHER_NOIZE"] = when {
            o.noize.isNotEmpty() -> o.noize
            o.protocol == "masque" -> "firewall"
            else -> "balanced"
        }
        if (o.protocol == "masque" || o.protocol == "gool" ||
            o.protocol == "mim"
        ) {
            env["AETHER_MASQUE_HTTP2"] = if (o.transport == "h2") "1" else "0"
            if (o.ech.isNotEmpty()) env["AETHER_ECH"] = o.ech
            // Build 2083: always written, "1" or "0" —
            // ralysnd's toEnv rule ("the fragment default
            // differs between its CLI and its env"); an H2
            // rung must never inherit an unset default.
            env["AETHER_MASQUE_H2_FRAGMENT"] = if (o.fragment) "1" else "0"
        }
        // Build 2083: the run's ClientHello (the carrier
        // ladder's semi-python rungs; CHROME sets nothing, as
        // before) and the tlshello exit it dials out through.
        env.putAll(o.tls.env)
        if (upstream != null) env["AETHER_UPSTREAM"] = upstream
        if (o.protocol == "wg" || o.protocol == "gool") {
            env["AETHER_WG_KEEPALIVE"] = o.keepalive.coerceIn(5, 120).toString()
            // 120 s, not the core's ~12 s: an idle tunnel looks
            // identical to a dead one at 12 s (ralysnd's finding).
            env["AETHER_WG_STALE_SECS"] = "120"
        }
        if (!o.peer.isNullOrBlank()) {
            env["AETHER_PEER"] = o.peer
            env["AETHER_WG_PEER"] = o.peer
            // Build 2129: a pinned endpoint on a mim run
            // names the OUTER hop — the binary's own words
            // for AETHER_MIM_OUTER_PEER (--mim-outer) are
            // "the outer hop, the one your network sees".
            // The inner hop is reached through it and stays
            // the core's own scan, exactly as gool's inner
            // WireGuard endpoint is the core's unless
            // AETHER_GOOL_INNER names it (Ember never sets
            // that either — the one Peer field is the outer
            // pin on both nested protocols).
            if (o.protocol == "mim") env["AETHER_MIM_OUTER_PEER"] = o.peer
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
                // The core is gone: its tlshello exit (build
                // 2083) goes with it, if it had one.
                stopExit()
                if (!stopping) {
                    stage = AetherStage.CRASHED
                    stageLabel = "Engine exited (code $code)"
                    lastError = "the engine exited on its own (code $code)"
                    log("engine exited on its own (code $code)")
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
        // Build 2083: one full scan cycle of THIS run ended
        // with no gateway — the carrier ladder's advance
        // signal (awaitConnected reads scanCycleFailed). Only
        // counts before the run ever connected; after
        // CONNECTED the same lines are the 2080 data-plane
        // demotion's business, below.
        if (!reachedConnected && AetherStageParser.isDataPlaneRetry(line)) {
            scanCycleFailed = true
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
        // Build 2116 (B5-9): the measured path RTT, kept
        // numeric for the probe's budget arithmetic.
        AetherStageParser.rttMs(line)?.let { lastRttMs = it }
        // Build 2116 (B5-3): an identity refusal is a
        // verdict about the stored identity, not the
        // network — recorded so the failure surface can
        // name the Reset path.
        if (AetherStageParser.isIdentityRefusal(line)) {
            identityRefused = true
        }
        // Build 2080 (foreign-SOCKS guard, ported from ralysnd's
        // AetherEngine.handleLine): since Aether 2.4.0, gool's
        // first start registers its key through a SOCKS listener
        // of its own on a RANDOM loopback port, which logs the
        // same "socks5 server listening" line before the tunnel
        // is up. A listening line for any port but this slot's
        // own must not set CONNECTED.
        val foreignSocks = detail.socks != null &&
            !detail.socks.endsWith(":$socksPort")
        // Build 2080 (data-aware demotion): a data-plane retry
        // line AFTER CONNECTED withdraws readiness. The stage
        // cannot demote itself (the retry lines classify SCAN,
        // ranked below CONNECTED and not a regression), so
        // without this the UI sat green on a hollow session
        // whose data plane retried forever behind CONNECTED.
        if (stage == AetherStage.CONNECTED &&
            AetherStageParser.isDataPlaneRetry(line)
        ) {
            // Build 2116 (B5-8): a tunnel that re-broke
            // after validating withdraws the validation
            // stamp too — it is no longer fresh evidence
            // for the data probe.
            engineValidatedAtMs = 0
            if (!dataPlaneStale) {
                dataPlaneStale = true
                log(
                    "data-plane retry after CONNECTED — readiness " +
                        "withdrawn until the core revalidates",
                )
            }
        }
        val next = if (foreignSocks) null
            else AetherStageParser.classify(line)
        if (next == null) return
        // The core proved its data plane again — its own
        // validation line, or a fresh listener on OUR port
        // reaching CONNECTED once more: the demotion clears.
        if (next == AetherStage.CONNECTED ||
            AetherStageParser.isDataPlaneProof(line)
        ) {
            dataPlaneStale = false
        }
        // Build 2116 (B5-8): the validation stamp the data
        // probe trusts over a cold re-probe.
        if (AetherStageParser.isDataPlaneProof(line)) {
            engineValidatedAtMs = SystemClock.elapsedRealtime()
        }
        val cur = stage
        if (next.isRegression || next.progressRank >= cur.progressRank ||
            cur.progressRank < 0
        ) {
            stage = next
            stageLabel = next.label()
            if (next == AetherStage.CONNECTED) reachedConnected = true
        }
    }

    /**
     * A user stop. Also aborts a carrier-ladder walk in
     * [connectMasque]: the current rung dies here and the
     * walk reads [ladderAbort] instead of advancing, so a
     * disconnect lands promptly. Internal stops (start(),
     * the ladder's own rung teardown) call [stopLocked]
     * directly and never set the abort.
     */
    @Synchronized
    fun stop() {
        if (ladderActive) ladderAbort = true
        stopLocked()
    }

    @Synchronized
    private fun stopLocked() {
        stopExit()
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
        dataPlaneStale = false
        stage = AetherStage.STOPPED
        stageLabel = AetherStage.STOPPED.label()
        p.killHard()
    }

    // Build 2125 (audit A25-18): internal — EmberApplication
    // calls it at process birth too (see AetherCore.reapOrphans).
    internal fun reapOrphan(context: Context) {
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
    //
    // Build 2115: the whole verification path rides a raw
    // socket through this slot's SOCKS (socksSocket below) —
    // no java.net proxy, no HttpURLConnection. The 2026-11-19
    // diagnosis (warp-masque-diagnosis.md): on the owner's
    // phone the engine validated its tunnel end-to-end and
    // its own exit check confirmed a WARP exit, while this
    // section's HttpURLConnection-over-java.net-SOCKS fetch
    // never landed an answer and swallowed every exception
    // to null, so the connect tore a healthy engine down as
    // "the exit could not be verified". Raw sockets also
    // bypass the platform cleartext policy that denied the
    // probe's plain-HTTP check in build 2083 — that policy
    // binds the platform HTTP stacks, not a socket.

    /** Opens a stream to [host]:[port] through this slot's
     *  SOCKS5 (no-auth, domain-form CONNECT, so the name is
     *  resolved at the far end). [ioTimeoutMs] bounds each
     *  read/write phase once the loopback connect lands.
     *  Throws IOException on any refusal or protocol break —
     *  callers record it (probeErrorText), never swallow it. */
    private fun socksSocket(host: String, port: Int, ioTimeoutMs: Int): Socket {
        val socket = Socket()
        try {
            socket.connect(InetSocketAddress("127.0.0.1", socksPort), 5_000)
            socket.soTimeout = ioTimeoutMs
            val out = socket.getOutputStream()
            val input = socket.getInputStream()
            out.write(byteArrayOf(0x05, 0x01, 0x00))
            out.flush()
            val greeting = readN(input, 2)
            if (greeting.size != 2 ||
                greeting[0] != 0x05.toByte() ||
                greeting[1] != 0x00.toByte()
            ) {
                throw IOException("the SOCKS proxy refused the connection")
            }
            val hostBytes = host.toByteArray(Charsets.US_ASCII)
            val req = ByteArrayOutputStream()
            req.write(0x05)
            req.write(0x01)
            req.write(0x00)
            req.write(0x03)
            req.write(hostBytes.size)
            req.write(hostBytes)
            req.write((port ushr 8) and 0xFF)
            req.write(port and 0xFF)
            out.write(req.toByteArray())
            out.flush()
            val head = readN(input, 4)
            if (head.size != 4 || head[0] != 0x05.toByte()) {
                throw IOException("the SOCKS proxy answered out of protocol")
            }
            if (head[1] != 0x00.toByte()) {
                throw IOException(
                    "the SOCKS proxy refused the tunnel connection " +
                        "(code ${head[1].toInt() and 0xFF})",
                )
            }
            val skip = when (head[3].toInt() and 0xFF) {
                0x01 -> 6
                0x03 -> {
                    val len = readN(input, 1)
                    if (len.size != 1) {
                        throw IOException("the SOCKS answer ended early")
                    }
                    (len[0].toInt() and 0xFF) + 2
                }
                0x04 -> 18
                else -> throw IOException(
                    "the SOCKS proxy answered out of protocol",
                )
            }
            if (readN(input, skip).size != skip) {
                throw IOException("the SOCKS answer ended early")
            }
            return socket
        } catch (e: Exception) {
            try {
                socket.close()
            } catch (_: Exception) {
            }
            throw e
        }
    }

    private class RawHttpResult(
        val status: Int,
        val contentLength: Long,
        val body: ByteArray,
    )

    /** One HTTP/1.1 exchange through the tunnel: SOCKS5 to
     *  [host]:[port], TLS over it when [tls], then the request
     *  and the full answer (headers + body, chunked and
     *  close-delimited forms decoded). The body is capped at
     *  [maxBody] bytes — enough for a caller to judge an
     *  exact-length answer wrong. Throws on transport and
     *  protocol failures; an HTTP error status is a RESULT,
     *  not an exception. */
    private fun rawRequest(
        method: String,
        tls: Boolean,
        host: String,
        port: Int,
        path: String,
        body: ByteArray?,
        contentType: String?,
        ioTimeoutMs: Int,
        maxBody: Int,
    ): RawHttpResult {
        val socket = socksSocket(host, port, ioTimeoutMs)
        try {
            val stream: Socket = if (tls) {
                val tlsSocket =
                    (SSLSocketFactory.getDefault() as SSLSocketFactory)
                        .createSocket(socket, host, port, true) as SSLSocket
                tlsSocket.startHandshake()
                tlsSocket
            } else {
                socket
            }
            val out = stream.getOutputStream()
            val head = StringBuilder()
            head.append(method).append(' ').append(path)
                .append(" HTTP/1.1\r\n")
            head.append("Host: ").append(host).append("\r\n")
            head.append("User-Agent: Mozilla/5.0\r\n")
            head.append("Cache-Control: no-cache\r\n")
            if (contentType != null) {
                head.append("Content-Type: ").append(contentType)
                    .append("\r\n")
            }
            if (body != null) {
                head.append("Content-Length: ").append(body.size)
                    .append("\r\n")
            }
            head.append("Connection: close\r\n\r\n")
            out.write(head.toString().toByteArray(Charsets.US_ASCII))
            if (body != null) out.write(body)
            out.flush()
            return readRawResponse(stream.getInputStream(), maxBody)
        } finally {
            try {
                socket.close()
            } catch (_: Exception) {
            }
        }
    }

    private fun readRawResponse(
        input: InputStream,
        maxBody: Int,
    ): RawHttpResult {
        // Status line + headers, byte at a time to the blank
        // line (headers are small; the body reads in blocks).
        val headBytes = ByteArrayOutputStream()
        var matched = 0 // progress through the CRLFCRLF end mark
        while (headBytes.size() < RAW_HEADER_CAP) {
            val b = input.read()
            if (b < 0) break
            headBytes.write(b)
            matched = when {
                (matched == 0 || matched == 2) && b == 0x0D -> matched + 1
                (matched == 1 || matched == 3) && b == 0x0A -> matched + 1
                b == 0x0D -> 1
                else -> 0
            }
            if (matched == 4) break
        }
        val lines = headBytes.toByteArray()
            .toString(Charsets.ISO_8859_1)
            .split("\r\n")
        val status = lines.firstOrNull()
            ?.split(' ')
            ?.getOrNull(1)
            ?.toIntOrNull()
            ?: throw IOException("the answer through the tunnel was not HTTP")
        var contentLength = -1L
        var chunked = false
        for (line in lines.drop(1)) {
            val i = line.indexOf(':')
            if (i <= 0) continue
            val name = line.substring(0, i).trim().lowercase()
            val value = line.substring(i + 1).trim()
            when (name) {
                "content-length" ->
                    contentLength = value.toLongOrNull() ?: -1L
                "transfer-encoding" ->
                    if (value.lowercase().contains("chunked")) {
                        chunked = true
                    }
            }
        }
        val noBody = status in 100..199 || status == 204 || status == 304
        val body = when {
            noBody -> ByteArray(0)
            chunked -> readChunked(input, maxBody)
            contentLength >= 0 ->
                readN(input, minOf(contentLength, maxBody.toLong()).toInt())
            else -> readToEnd(input, maxBody)
        }
        return RawHttpResult(status, contentLength, body)
    }

    /** Up to [n] bytes (fewer only at end of stream). */
    private fun readN(input: InputStream, n: Int): ByteArray {
        if (n <= 0) return ByteArray(0)
        val buf = ByteArrayOutputStream(n)
        val chunk = ByteArray(8192)
        var left = n
        while (left > 0) {
            val read = input.read(chunk, 0, minOf(chunk.size, left))
            if (read < 0) break
            buf.write(chunk, 0, read)
            left -= read
        }
        return buf.toByteArray()
    }

    /** To end of stream, capped at [maxBody] bytes. */
    private fun readToEnd(input: InputStream, maxBody: Int): ByteArray {
        val buf = ByteArrayOutputStream()
        val chunk = ByteArray(8192)
        while (buf.size() <= maxBody) {
            val want = minOf(chunk.size, maxBody + 1 - buf.size())
            if (want <= 0) break
            val read = input.read(chunk, 0, want)
            if (read < 0) break
            buf.write(chunk, 0, read)
        }
        return buf.toByteArray()
    }

    /** One CRLF-terminated line (the CR is stripped). */
    private fun readChunkLine(input: InputStream): String {
        val buf = ByteArrayOutputStream()
        while (buf.size() < RAW_HEADER_CAP) {
            val b = input.read()
            if (b < 0 || b == 0x0A) break
            if (b != 0x0D) buf.write(b)
        }
        return buf.toByteArray().toString(Charsets.ISO_8859_1)
    }

    /** A chunked body, stored up to [maxBody] bytes (the
     *  stream is still walked to the terminal chunk, so the
     *  framing stays honest for the caller's length check). */
    private fun readChunked(input: InputStream, maxBody: Int): ByteArray {
        val buf = ByteArrayOutputStream()
        while (true) {
            val size = readChunkLine(input)
                .split(';').first().trim().toIntOrNull(16)
                ?: throw IOException(
                    "the answer through the tunnel was malformed",
                )
            if (size == 0) {
                while (readChunkLine(input).isNotEmpty()) {
                    // Trailer lines are discarded.
                }
                break
            }
            var left = size
            while (left > 0) {
                val data = readN(input, minOf(left, 8192))
                if (data.isEmpty()) {
                    throw IOException(
                        "the answer through the tunnel ended early",
                    )
                }
                if (buf.size() < maxBody) {
                    buf.write(
                        data,
                        0,
                        minOf(data.size, maxBody - buf.size()),
                    )
                }
                left -= data.size
            }
            readN(input, 2) // the CRLF after each chunk
            if (buf.size() >= maxBody && maxBody > 0) break
        }
        return buf.toByteArray()
    }

    // Build 2115: the last trace failure, in probeErrorText
    // form. Before this build trace() swallowed every
    // exception to null, so a connect could burn its whole
    // proof budget against a fetch that never landed and
    // report nothing but "could not be verified". A failure
    // is now logged into the slot log on every miss and
    // carried in state() as traceError, the way build 2084
    // taught the data probe to name its own failures.
    @Volatile
    private var lastTraceError: String? = null

    private fun recordTraceError(text: String) {
        lastTraceError = text
        log("trace failed: $text")
    }

    /** One trace fetch through this slot's SOCKS. Null on
     *  failure — with the reason kept in [lastTraceError]. */
    fun trace(): Map<String, String>? {
        return try {
            val resp = rawRequest(
                method = "GET",
                tls = true,
                host = "www.cloudflare.com",
                port = 443,
                path = "/cdn-cgi/trace",
                body = null,
                contentType = null,
                ioTimeoutMs = TRACE_IO_TIMEOUT_MS,
                maxBody = TRACE_MAX_BODY_BYTES,
            )
            if (resp.status != 200) {
                recordTraceError(
                    "the trace endpoint answered HTTP ${resp.status}",
                )
                return null
            }
            val out = LinkedHashMap<String, String>()
            for (line in resp.body.toString(Charsets.UTF_8)
                .lineSequence()) {
                val i = line.indexOf('=')
                if (i > 0) {
                    out[line.substring(0, i).trim()] =
                        line.substring(i + 1).trim()
                }
            }
            if (out.isEmpty()) {
                recordTraceError("the trace answer was empty")
                null
            } else {
                lastTraceError = null
                out
            }
        } catch (e: Exception) {
            recordTraceError(probeErrorText(e))
            null
        }
    }

    // ── data-plane proof (build 2080: the CfDataProbe port) ──
    //
    // Ralysnd never raises a TUN on a log line: its
    // AetherTunEngine demands CfDataProbe.validate() — four
    // bounded application transfers through the tunnel's own
    // SOCKS, each with its answer validated — before openTun.
    // Ember ported the stage machine and dropped that check,
    // so a hollow CONNECTED (listener up, greeting answered,
    // data plane retrying) carried the connect. This is the
    // same recipe through this slot's SOCKS: plain HTTP 204,
    // HTTPS 204 with the TLS handshake completed, a download
    // of exactly DOWN_BYTES (the length is the check, so a
    // block page cannot pass), and an upload the far end
    // echoes back (an acknowledgement, not a socket write).
    // Each check has more than one independent endpoint, so
    // one third-party service being down cannot fail a working
    // tunnel. Blocking (one 45 s ceiling): call off the main
    // thread. Never throws for a network failure — that is a
    // FAILED result, reported in the returned map.

    private val http204Urls = listOf(
        "http://www.gstatic.com/generate_204",
        "http://connectivitycheck.gstatic.com/generate_204",
    )
    private val https204Urls = listOf(
        "https://www.gstatic.com/generate_204",
        "https://www.google.com/generate_204",
    )
    private val downloadUrls = listOf(
        "https://httpbin.org/bytes/$DATA_PROBE_DOWN_BYTES",
        "https://nghttp2.org/httpbin/bytes/$DATA_PROBE_DOWN_BYTES",
        "https://speed.cloudflare.com/__down?bytes=$DATA_PROBE_DOWN_BYTES",
    )
    private val echoUrls = listOf(
        "https://httpbin.org/post",
        "https://postman-echo.com/post",
        "https://nghttp2.org/httpbin/post",
    )

    // Build 2084: the last exception a probe check swallowed,
    // as "ClassName: message" (see probeErrorText). The probe
    // helpers set it on every catch; dataProbe folds it into
    // the fail detail so a platform refusal (the build-2083
    // cleartext denial) names itself instead of surfacing as
    // a bare "http204=no". Reset at each check's entry.
    private var lastProbeError: String? = null

    /** The per-request read budget for one probe transfer
     *  (build 2116, B5-9): ten times the endpoint RTT the
     *  engine measured for this run, bounded — a fixed
     *  budget is wrong in both directions (one dead endpoint
     *  eats the whole probe on a fast path; a slow path's
     *  honest transfers starve on a short one). Falls back
     *  to the standing budget before any RTT is known. */
    private fun probeIoTimeoutMs(): Int {
        val rtt = lastRttMs
        if (rtt <= 0) return PROBE_IO_TIMEOUT_MS
        return (rtt * 10).coerceIn(
            PROBE_IO_TIMEOUT_MIN_MS,
            PROBE_IO_TIMEOUT_MAX_MS,
        )
    }

    fun dataProbe(): Map<String, Any> {
        val started = System.currentTimeMillis()
        val deadline = started + DATA_PROBE_TOTAL_MS
        fun ms() = System.currentTimeMillis() - started
        fun fail(reason: String): Map<String, Any> =
            mapOf("ok" to false, "detail" to reason, "ms" to ms())
        // Build 2116 (B5-8, device-proven on build 2115):
        // when the engine validated THIS run's tunnel
        // end-to-end moments ago, its in-protocol
        // confirmation outranks a cold re-probe through
        // third-party endpoints — a re-probe failure (the
        // device case was a read timeout on a 699 ms path
        // the engine had just proven) is recorded in the
        // detail, never a veto. Without a fresh stamp the
        // probe's word stands exactly as before.
        fun verdict(reason: String): Map<String, Any> =
            if (engineValidationFresh()) {
                dataPlaneStale = false
                log(
                    "data probe failed ($reason) but the engine " +
                        "validated this tunnel end-to-end moments " +
                        "ago — trusting the engine's validation",
                )
                mapOf(
                    "ok" to true,
                    "detail" to "engine-validated (re-check said: $reason)",
                    "ms" to ms(),
                )
            } else {
                fail(reason)
            }
        try {
            if (!probe204(http204Urls, deadline)) {
                return verdict(probeFailDetail("http204=no", lastProbeError))
            }
            if (!probe204(https204Urls, deadline)) {
                return verdict(probeFailDetail("https204=no", lastProbeError))
            }
            val down = probeDownload(deadline)
            if (down != DATA_PROBE_DOWN_BYTES.toLong()) {
                return verdict(probeFailDetail("down=$down", lastProbeError))
            }
            if (!probeUploadEcho(deadline)) {
                return verdict(probeFailDetail("up=0", lastProbeError))
            }
            // Real data just moved through the tunnel: that is
            // stronger evidence than any log line, so a pending
            // data-plane demotion clears here too.
            dataPlaneStale = false
            return mapOf(
                "ok" to true,
                "detail" to "http=204 https=204 down=$down " +
                    "up=$DATA_PROBE_UP_BYTES",
                "ms" to ms(),
            )
        } catch (e: Exception) {
            return verdict("error=${e.javaClass.simpleName}")
        }
    }

    /** One probe request through the SOCKS on the raw
     *  transport (build 2115 — see socksSocket). java.net.URL
     *  only PARSES the constant endpoint here; it never opens
     *  a connection. Redirects are never followed, exactly as
     *  the HttpURLConnection recipe had it. */
    private fun probeRequest(
        method: String,
        url: String,
        body: ByteArray?,
        contentType: String?,
        maxBody: Int,
    ): RawHttpResult {
        val u = URL(url)
        val tls = u.protocol == "https"
        val port = if (u.port >= 0) u.port else u.defaultPort
        val path = u.file.ifEmpty { "/" }
        return rawRequest(
            method = method,
            tls = tls,
            host = u.host,
            port = port,
            path = path,
            body = body,
            contentType = contentType,
            ioTimeoutMs = probeIoTimeoutMs(),
            maxBody = maxBody,
        )
    }

    /** generate_204 through the SOCKS: exactly 204 or failure.
     *  For the HTTPS list a 204 answer means the TLS handshake
     *  completed inside the tunnel on the way there. */
    private fun probe204(urls: List<String>, deadline: Long): Boolean {
        lastProbeError = null
        for (url in urls) {
            if (System.currentTimeMillis() > deadline) break
            try {
                val resp = probeRequest("GET", url, null, null, 0)
                if (resp.status == 204) return true
            } catch (e: Exception) {
                // The next endpoint gets its chance — but the
                // failure is recorded (build 2084), not swallowed.
                lastProbeError = probeErrorText(e)
            }
        }
        return false
    }

    /** Exactly [DATA_PROBE_DOWN_BYTES] bytes or failure — a
     *  block page's body is the wrong length by construction. */
    private fun probeDownload(deadline: Long): Long {
        lastProbeError = null
        for (url in downloadUrls) {
            if (System.currentTimeMillis() > deadline) break
            try {
                val resp = probeRequest(
                    "GET",
                    url,
                    null,
                    null,
                    DATA_PROBE_DOWN_BYTES + 1,
                )
                if (resp.status != 200) continue
                val announced = resp.contentLength
                if (announced >= 0 &&
                    announced != DATA_PROBE_DOWN_BYTES.toLong()
                ) {
                    continue
                }
                val n = resp.body.size.toLong()
                if (n == DATA_PROBE_DOWN_BYTES.toLong()) return n
            } catch (e: Exception) {
                // The next endpoint gets its chance — but the
                // failure is recorded (build 2084), not swallowed.
                lastProbeError = probeErrorText(e)
            }
        }
        return 0L
    }

    /** A [DATA_PROBE_UP_BYTES] upload the far end echoes back
     *  in its JSON answer: the payload appearing in the
     *  response body is the acknowledgement. */
    private fun probeUploadEcho(deadline: Long): Boolean {
        lastProbeError = null
        val payload = "ember-transfer-check:" +
            "x".repeat(DATA_PROBE_UP_BYTES - 21)
        val bytes = payload.toByteArray(Charsets.UTF_8)
        for (url in echoUrls) {
            if (System.currentTimeMillis() > deadline) break
            try {
                val resp = probeRequest(
                    "POST",
                    url,
                    bytes,
                    "text/plain",
                    PROBE_ECHO_MAX_BODY_BYTES,
                )
                if (resp.status != 200) continue
                val body = resp.body.toString(Charsets.UTF_8)
                if (body.contains(payload)) {
                    return true
                }
            } catch (e: Exception) {
                // The next endpoint gets its chance — but the
                // failure is recorded (build 2084), not swallowed.
                lastProbeError = probeErrorText(e)
            }
        }
        return false
    }

    /** The most common probe-failure reason this run, with its count. */
    private fun topProbeReason(): String = synchronized(probeReasons) {
        probeReasons.maxByOrNull { it.value }
            ?.let { "${it.key} ×${it.value}" } ?: ""
    }

    fun state(context: Context): Map<String, Any> {
        return mapOf(
            "engine" to id,
            "running" to running,
            "stage" to stage.name.lowercase(),
            "stageLabel" to stageLabel,
            "connected" to isConnected(),
            "dataPlaneStale" to dataPlaneStale,
            "scanCycleFailed" to scanCycleFailed,
            "server" to server,
            "rtt" to rtt,
            "profile" to profile,
            "socksPort" to socksPort,
            "sinceMs" to startedAtMs,
            "error" to lastError,
            "identity" to identityPresent(context),
            "engineValidated" to engineValidationFresh(),
            "identityRefused" to identityRefused,
            "probeTopReason" to topProbeReason(),
            "traceError" to (lastTraceError ?: ""),
            "log" to logTail(60).joinToString("\n"),
        )
    }

    companion object {
        private const val TAG = "AetherCore"
        private const val PREFS = "aether_slots"

        // The data probe's shape (build 2080, ralysnd's
        // CfDataProbe numbers): a 64 KiB download whose length
        // is the check, a 16 KiB echoed upload, one 45 s
        // ceiling for all four transfers.
        private const val DATA_PROBE_DOWN_BYTES = 65_536
        private const val DATA_PROBE_UP_BYTES = 16_384
        private const val DATA_PROBE_TOTAL_MS = 45_000L

        // Build 2115: the raw verification transport's bounds.
        // The trace's per-phase I/O timeout is 15 s — the
        // diagnosis's floor for the measured carrier RTT (the
        // cached endpoint degraded to 1.27 s on the owner's
        // phone, and one fetch costs several tunnel round
        // trips) — where the old HttpURLConnection fetch
        // allowed 8 s. The probe keeps its 10 s read bound.
        private const val TRACE_IO_TIMEOUT_MS = 15_000
        private const val PROBE_IO_TIMEOUT_MS = 10_000

        // Build 2116 (B5-9): the probe's RTT-scaled read
        // budget bounds — 10× the measured RTT, never
        // below 7.5 s (a fresh gateway's first transfers
        // are slow beyond the scan's RTT) and never above
        // 25 s (one dead endpoint must not eat the probe).
        private const val PROBE_IO_TIMEOUT_MIN_MS = 7_500
        private const val PROBE_IO_TIMEOUT_MAX_MS = 25_000

        // Build 2116 (B5-8): how long the engine's own
        // end-to-end validation stays fresh evidence for
        // the data probe — the connect's proof sequence
        // runs seconds after the validation line, so three
        // minutes is generous without ever reaching across
        // sessions (start() also resets the stamp).
        private const val ENGINE_VALIDATION_FRESH_MS = 180_000L
        private const val TRACE_MAX_BODY_BYTES = 16_384
        private const val PROBE_ECHO_MAX_BODY_BYTES = 1_048_576
        private const val RAW_HEADER_CAP = 32_768

        // The carrier ladder's budgets (build 2083, ralysnd's
        // AetherTunEngine table). The Dart side mirrors this
        // arithmetic for its own backstop timeout
        // (aether_platform.dart: masqueAutoConnectTimeout).

        /** The core's own scan deadlines (its strategy table):
         *  how long one scan can run before the core gives up
         *  on it. */
        fun scanDeadlineMs(scan: String): Long = when (scan) {
            "turbo" -> 45_000L
            "balanced" -> 120_000L
            "thorough" -> 300_000L
            "stealth" -> 180_000L
            "ironclad" -> 180_000L
            else -> 180_000L
        }

        /** Identity, handshake and validation headroom after
         *  a scan (ralysnd's TIMEOUT_HEADROOM_MS). */
        const val RUNG_HEADROOM_MS = 45_000L

        /** Trace + data-proof allowance inside one rung's
         *  total: a 30 s trace wait and two 45 s data probes,
         *  with settle slack. */
        const val PROOF_ALLOWANCE_MS = 135_000L

        /** One rung's wait budget: its scan deadline + headroom. */
        fun rungBudgetMs(scan: String): Long =
            scanDeadlineMs(scan) + RUNG_HEADROOM_MS

        /** Build 2084: one swallowed probe exception, compactly:
         *  the class simple-name plus its message when it has
         *  one ("IOException: Cleartext HTTP traffic to
         *  www.gstatic.com not permitted"). */
        fun probeErrorText(e: Exception): String {
            val msg = e.message?.trim().orEmpty()
            return if (msg.isEmpty()) {
                e.javaClass.simpleName
            } else {
                "${e.javaClass.simpleName}: $msg"
            }
        }

        /** Build 2084: a probe fail detail — the standing reason
         *  token, with the recorded exception appended in
         *  brackets when the check died on one. No exception
         *  (a wrong status code, a short body) leaves the
         *  detail exactly as it was before this build. */
        fun probeFailDetail(reason: String, error: String?): String =
            if (error.isNullOrBlank()) reason else "$reason [$error]"

        /**
         * The whole walk's bound: every rung's wait + proofs.
         * A backstop, not an expectation — a dead rung ends at
         * its ~45 s scan-cycle signal, so a cold first connect
         * on a filtered line normally resolves in a few
         * minutes; what the bound guarantees is that no
         * connect can sit in "connecting" forever.
         */
        fun ladderTotalMs(scan: String): Long =
            MasqueRung.values().size *
                (rungBudgetMs(scan) + PROOF_ALLOWANCE_MS)
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

    /** Build 2125 (audit A25-18): the process-birth orphan
     *  sweep for both slots (EmberApplication calls it). */
    fun reapOrphans(context: Context) {
        cfwarp.reapOrphan(context)
        masque.reapOrphan(context)
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
