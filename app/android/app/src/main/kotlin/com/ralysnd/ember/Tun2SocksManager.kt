package com.ralysnd.ember

import android.os.ParcelFileDescriptor
import ca.psiphon.Tun2SocksJniLoader
import java.io.IOException
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.SocketException

/**
 * Whole-device TUN → SOCKS5 routing via badvpn tun2socks (lwIP
 * TCP/IP stack) — a port of the ralysnd (MLM) app's
 * Tun2SocksManager (build 2091, the MLM transplant;
 * mlm-psiphon-full-analysis.md §6). Two adaptations, both forced
 * by the move: MLM's ConnectionLog calls go to [logger], which
 * PsiphonVpnService points at its session log; and the native
 * logger is registered under THIS class's name (the JNI loader's
 * callback contract names the class it must call back into).
 *
 * UDP path: tun2socks opens a SOCKS5 connection to
 * udpgwServerAddress and speaks the udpgw protocol over it. No
 * local udpgw daemon is needed — the Psiphon server intercepts
 * connections to that address (UDPInterceptUdpgwServerAddress in
 * tunnelServer.go) and handles UDP forwarding server-side.
 * udpgwTransparentDNS makes DNS follow the same path.
 */
object Tun2SocksManager {

    /** The session log's sink; the service installs its own. */
    @Volatile
    var logger: (String) -> Unit = {}

    private fun record(line: String) {
        try {
            logger(line)
        } catch (_: Throwable) {
            // Logging must never break the bridge.
        }
    }

    /** Psiphon's convention; the server intercepts this exact address. */
    private const val UDPGW_SERVER_PORT = 7300
    const val VPN_INTERFACE_MTU = 1500
    const val VPN_INTERFACE_IPV4_NETMASK = "255.255.255.0"

    /**
     * How long to wait for a previous native run() to unwind.
     *
     * The native side notices g_terminate on its TCP timer tick
     * (250ms in lwIP's default config) and then tears down the
     * reactor, so exit is normally well under a second. 5s is
     * generous headroom without hanging the caller for an
     * unbounded time.
     */
    private const val NATIVE_EXIT_GRACE_MS = 5_000L

    /**
     * Address plan for the TUN device.
     *
     * Note the asymmetry, which matters: [ipAddress] is what the
     * VPN interface itself gets, while [router] is the address
     * lwIP answers on inside tun2socks and is also used as the DNS
     * resolver. Passing the interface address to runTun2Socks()
     * instead of the router address makes lwIP silently drop
     * every packet.
     */
    data class PrivateAddress(
        val ipAddress: String,
        val subnet: String,
        val prefixLength: Int,
        val router: String,
    )

    @Volatile
    private var tun2SocksThread: Thread? = null

    /**
     * The most recent native thread, kept after [stop] clears
     * [tun2SocksThread].
     *
     * [isRunning] must go false as soon as a stop is requested
     * (the service keys off it), but the native run() call keeps
     * touching its globals until it actually returns. This handle
     * is what [start] joins on to guarantee the two never overlap.
     */
    @Volatile
    private var lastThread: Thread? = null

    @Volatile
    var privateAddress: PrivateAddress = defaultPrivateAddress()
        private set

    private fun defaultPrivateAddress() =
        PrivateAddress("10.0.0.1", "10.0.0.0", 8, "10.0.0.2")

    /**
     * Pick a private range that is not already in use on this
     * device, so the TUN subnet cannot collide with the
     * Wi-Fi/mobile network and blackhole real traffic.
     */
    fun selectPrivateAddress(): PrivateAddress {
        val candidates = linkedMapOf(
            "10" to PrivateAddress("10.0.0.1", "10.0.0.0", 8, "10.0.0.2"),
            "172" to PrivateAddress("172.16.0.1", "172.16.0.0", 12, "172.16.0.2"),
            "192" to PrivateAddress("192.168.0.1", "192.168.0.0", 16, "192.168.0.2"),
            "169" to PrivateAddress("169.254.1.1", "169.254.1.0", 24, "169.254.1.2"),
        )

        val interfaces = try {
            NetworkInterface.getNetworkInterfaces()
        } catch (e: SocketException) {
            null
        }

        if (interfaces != null) {
            for (netInterface in interfaces) {
                for (inetAddress in netInterface.inetAddresses) {
                    if (inetAddress !is Inet4Address) continue
                    val ip = inetAddress.hostAddress ?: continue
                    when {
                        ip.startsWith("10.") -> candidates.remove("10")
                        ip.length >= 6 &&
                            ip.substring(0, 6) >= "172.16" &&
                            ip.substring(0, 6) <= "172.31" -> candidates.remove("172")
                        ip.startsWith("192.168") -> candidates.remove("192")
                    }
                }
            }
        }

        val selected = candidates.values.firstOrNull() ?: defaultPrivateAddress()
        privateAddress = selected
        record("tun2socks address plan: if=${selected.ipAddress}/${selected.prefixLength} router=${selected.router}")
        return selected
    }

    val isRunning: Boolean
        get() = tun2SocksThread != null

    /**
     * True while the native run() has not returned yet, even
     * after [stop].
     *
     * [isRunning] deliberately goes false the moment a stop is
     * requested, so the service reacts at once. That is the wrong
     * question to ask before starting again: the native side
     * keeps touching its file-scope lwIP globals until it
     * actually unwinds, and a second run() entered before then
     * trips ASSERT(!have_netif) and aborts the process.
     */
    val isNativeAlive: Boolean
        get() = lastThread?.isAlive == true

    /**
     * Start routing the whole device through [socksProxyPort].
     *
     * [tunFd] is duplicated internally: runTun2Socks() takes
     * ownership of the fd it is given and closes it on exit, so
     * the caller keeps its original descriptor alive for the
     * whole VPN session and can restart tun2socks across Psiphon
     * rotations without re-establishing the TUN interface.
     *
     * @param mtu the MTU of [tunFd]. It MUST be the value the
     *   interface was built with: lwIP sizes its own buffers and
     *   its TCP MSS from this number, so a mismatch does not
     *   produce a smaller packet, it produces a wrong one.
     */
    @Synchronized
    fun start(
        tunFd: ParcelFileDescriptor,
        socksProxyPort: Int,
        dnsOnlyUdpgw: Boolean = false,
        mtu: Int = VPN_INTERFACE_MTU,
    ): Boolean {
        if (tun2SocksThread != null) {
            record("tun2socks already running")
            return true
        }
        // Refuse to start while a previous native run() is still
        // unwinding. tun2socks.c keeps its lwIP state in
        // file-scope globals, so two concurrent run() calls share
        // one set of globals; the second reaches lwip_init and
        // hits ASSERT(!have_netif) — still 1 from the first run —
        // and aborts the process. stop() used to join and clear
        // the handle regardless, so a fast re-tap could enter
        // start() while run() was still live. The join-or-refuse
        // below is the fix MLM ships; it is kept verbatim.
        val previous = lastThread
        if (previous != null && previous.isAlive) {
            try {
                previous.join(NATIVE_EXIT_GRACE_MS)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            if (previous.isAlive) {
                // Starting now would abort the process. Refusing
                // is recoverable: the caller reports a failed
                // connect and the user can retry.
                record(
                    "tun2socks: previous native instance still shutting down; refusing to start a second one"
                )
                return false
            }
        }
        lastThread = null
        if (socksProxyPort <= 0) {
            record("tun2socks: invalid SOCKS port $socksProxyPort")
            return false
        }

        val socksServerAddress = "127.0.0.1:$socksProxyPort"
        val udpgwServerAddress = "127.0.0.1:$UDPGW_SERVER_PORT"
        val address = privateAddress

        val duplicated = try {
            tunFd.dup()
        } catch (e: IOException) {
            record("tun2socks: could not dup tun fd: ${e.message}")
            return false
        }

        try {
            Tun2SocksJniLoader.initializeLogger(
                "com.ralysnd.ember.Tun2SocksManager",
                "logTun2Socks",
            )
        } catch (e: Throwable) {
            // Logger wiring is diagnostic only — never block the tunnel on it.
            record("tun2socks: logger init failed: ${e.message}")
        }

        val thread = Thread({
            try {
                Tun2SocksJniLoader.runTun2Socks(
                    duplicated.detachFd(),
                    mtu,
                    address.router,
                    VPN_INTERFACE_IPV4_NETMASK,
                    null, // IPv4-only routing
                    socksServerAddress,
                    udpgwServerAddress,
                    1, // transparent DNS through udpgw
                    if (dnsOnlyUdpgw) 1 else 0,
                )
            } catch (e: Throwable) {
                record("tun2socks crashed: ${e.message}")
            } finally {
                record("tun2socks exited")
            }
        }, "tun2socks")
        thread.start()
        tun2SocksThread = thread
        lastThread = thread
        record("tun2socks started → SOCKS $socksServerAddress, udpgw $udpgwServerAddress")
        return true
    }

    /**
     * Signal the native side to shut down and return immediately.
     *
     * Deliberately does NOT join the native thread: the overlap
     * protection lives in [start], which joins [lastThread]
     * before touching the natives — the only place where waiting
     * is actually required and where it is always off the main
     * thread.
     *
     * [isRunning] goes false synchronously here, so the service
     * sees "not routing" the instant the user asks for it.
     */
    @Synchronized
    fun stop() {
        if (tun2SocksThread == null) return
        tun2SocksThread = null
        try {
            Tun2SocksJniLoader.terminateTun2Socks()
        } catch (e: Throwable) {
            record("tun2socks stop error: ${e.message}")
        }
        record("tun2socks stopping (native thread unwinding)")
    }

    /**
     * Called from native code. Signature and name are referenced
     * by initializeLogger() above — keep them in sync.
     */
    @JvmStatic
    fun logTun2Socks(level: String?, channel: String?, msg: String?) {
        // ERROR and WARNING are worth surfacing; the rest is very
        // chatty per-connection noise that would flood the log.
        when (level) {
            "ERROR", "WARNING" -> record("tun2socks $level($channel): $msg")
        }
    }
}
