package com.ralysnd.ember

import android.content.Context
import android.net.ConnectivityManager
import android.net.DnsResolver
import android.net.LinkAddress
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.CancellationSignal
import android.os.Process
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.net.Inet6Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.UnknownHostException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import lantern.io.libbox.ConnectionOwner
import lantern.io.libbox.ExchangeContext
import lantern.io.libbox.InterfaceUpdateListener
import lantern.io.libbox.LocalDNSTransport
import lantern.io.libbox.NetworkInterfaceIterator
import lantern.io.libbox.StringIterator
import lantern.io.libbox.WIFIState

/**
 * The platform half of the Lantern engine: the libbox PlatformInterface
 * the Radiance core calls back into (adapted from the official Lantern
 * Android client's wrapper, minus its app singletons), a compact
 * default-network monitor, and a LocalDNSTransport that resolves
 * through the OS resolver on the default network. Implemented by
 * LanternVpnService; kept in this file so the service stays readable.
 *
 * Ember ships the core's `novpn` variant: the box has no TUN inbound,
 * only the mixed SOCKS/HTTP inbound on 127.0.0.1:1080, so OpenTun is
 * never called in practice — the service builds the TUN itself and
 * bridges it with libtunlink, like the other engines.
 *
 * 2012 hardening (the 2011 silent-death fix): every implementation of
 * a Go callback in this file must NEVER throw. Upstream's own shipped
 * bug classes (their AGENTS.md #4 and the readWIFIState comment in
 * their PlatformInterfaceWrapper) document why: a Kotlin throw out of
 * a gomobile callback whose Go signature has no error return leaves a
 * pending JNI exception the Go side cannot observe or clear, which
 * aborts the process (SIGABRT) with no Kotlin log and no Go crash
 * file — the process simply vanishes. Callbacks that DO have an error
 * return may throw an Exception (never an Error). The resolver
 * therefore completes its ExchangeContext with an error code instead
 * of throwing, and the monitor notifies the core's listener from a
 * dedicated executor, like upstream, never synchronously.
 */

/** Diagnostics hook: LanternVpnService installs its log writer here
 * so failures inside platform callbacks land in lantern-service.log
 * (this file has no logger of its own). */
@Volatile
var lanternPlatformLog: ((String) -> Unit)? = null

internal fun platformLog(line: String) {
    try {
        lanternPlatformLog?.invoke(line)
    } catch (t: Throwable) {
        // Logging must never break a callback.
    }
}
object LanternNetworkMonitor {
    @Volatile
    var defaultNetwork: Network? = null
        private set

    @Volatile
    private var listener: InterfaceUpdateListener? = null

    @Volatile
    private var callback: ConnectivityManager.NetworkCallback? = null

    private val executor = Executors.newSingleThreadExecutor()

    fun start(context: Context) {
        if (callback != null) return
        val cm = context.getSystemService(ConnectivityManager::class.java)
        try {
            defaultNetwork = cm.activeNetwork
        } catch (t: Throwable) {
            platformLog("network monitor: activeNetwork read failed: $t")
        }
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                defaultNetwork = network
                pushUpdate(context, network)
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                if (network == defaultNetwork) pushUpdate(context, network)
            }

            override fun onLost(network: Network) {
                if (network == defaultNetwork) {
                    defaultNetwork = null
                    executor.execute {
                        try {
                            listener?.updateDefaultInterface("", -1, false, false)
                        } catch (t: Throwable) {
                            // The core is gone or not listening; harmless.
                        }
                    }
                }
            }
        }
        callback = cb
        try {
            cm.registerDefaultNetworkCallback(cb)
        } catch (t: Throwable) {
            callback = null
            platformLog("network monitor: registerDefaultNetworkCallback failed: $t")
        }
    }

    fun stop(context: Context) {
        val cb = callback ?: return
        callback = null
        try {
            context.getSystemService(ConnectivityManager::class.java)
                .unregisterNetworkCallback(cb)
        } catch (e: Exception) {
            // Already unregistered.
        }
    }

    fun setListener(context: Context, l: InterfaceUpdateListener?) {
        listener = l
        val network = defaultNetwork
        if (l != null && network != null) pushUpdate(context, network)
    }

    private fun pushUpdate(context: Context, network: Network) {
        val l = listener ?: return
        // The listener call goes to the core through gomobile and
        // must never run on a system callback thread or re-entrantly
        // inside another platform call: upstream dispatches it from
        // a dedicated single-thread executor for the same reason.
        executor.execute {
            try {
                val cm = context.getSystemService(ConnectivityManager::class.java)
                val props = cm.getLinkProperties(network)
                val caps = cm.getNetworkCapabilities(network)
                val name = props?.interfaceName ?: return@execute
                val index = try {
                    Os.if_nametoindex(name)
                } catch (t: Throwable) {
                    -1
                }
                val expensive = caps != null &&
                    !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                // No public-SDK capability for "constrained" exists
                // (the old constant is hidden API); upstream's own
                // DefaultNetworkMonitor passes false here too.
                val constrained = false
                // A teardown may have replaced or cleared the listener
                // while this update sat queued; don't call into a
                // stale (closed) libbox handler.
                if (listener === l) {
                    l.updateDefaultInterface(name, index, expensive, constrained)
                }
            } catch (t: Throwable) {
                // A network that vanished mid-callback; the next
                // callback carries the new default. Logged because a
                // throw escaping toward gomobile can abort the whole
                // process (see the file header).
                platformLog("network monitor: interface update failed: $t")
            }
        }
    }

    /** The default network, waiting briefly for the monitor to seed
     * it; null when there is none. Never throws: callers on the
     * gomobile boundary must be able to fail soft. */
    fun awaitNetwork(context: Context): Network? {
        defaultNetwork?.let { return it }
        start(context)
        val deadline = System.currentTimeMillis() + 3000
        while (System.currentTimeMillis() < deadline) {
            defaultNetwork?.let { return it }
            try {
                Thread.sleep(50)
            } catch (e: InterruptedException) {
                break
            }
        }
        return try {
            defaultNetwork
                ?: context.getSystemService(ConnectivityManager::class.java).activeNetwork
        } catch (t: Throwable) {
            platformLog("network monitor: no default network: $t")
            null
        }
    }

    /** The default network, or throw. Kept for parity with the
     * original shape; the resolver uses [awaitNetwork] so nothing on
     * the gomobile boundary throws. */
    fun require(context: Context): Network =
        awaitNetwork(context) ?: throw IllegalStateException("no default network")
}

/** A StringIterator over a fixed list (gomobile helper). next()
 * past the end returns "" instead of throwing: these methods have
 * no error return on the Go side, so a throw here is a process
 * abort, not an error (see the file header). */
class LanternStringIterator(private val items: List<String>) : StringIterator {
    private var index = 0
    override fun hasNext(): Boolean = index < items.size
    override fun len(): Int = items.size
    override fun next(): String = if (index < items.size) items[index++] else ""
}

/** A NetworkInterfaceIterator over a fixed list (gomobile helper);
 * next() past the end returns an empty interface instead of
 * throwing, for the same reason as above. */
class LanternInterfaceIterator(
    private val items: List<lantern.io.libbox.NetworkInterface>,
) : NetworkInterfaceIterator {
    private var index = 0
    override fun hasNext(): Boolean = index < items.size
    override fun next(): lantern.io.libbox.NetworkInterface =
        if (index < items.size) items[index++] else lantern.io.libbox.NetworkInterface()
}

/**
 * DNS through the OS resolver on the default network (the official
 * client's LocalResolver, reworked onto latches instead of
 * coroutines, which this app does not otherwise carry).
 *
 * NEVER throws (2012): the pre-2012 version called
 * LanternNetworkMonitor.require() outside any guard and rethrew
 * resolver failures (`failure.get()?.let { throw it }`) across the
 * gomobile boundary. Every failure now completes the ExchangeContext
 * exactly once with an error code — SERVFAIL when the lookup could
 * not even be attempted (no default network, resolver exception,
 * 30s timeout).
 */
class LanternLocalResolver(private val context: Context) : LocalDNSTransport {

    companion object {
        /** One shared resolver executor: DnsResolver wants one per
         * query, but threads are not free — a cached pool is the
         * honest middle ground. */
        val resolverExecutor: java.util.concurrent.Executor =
            Executors.newCachedThreadPool()
    }
    override fun raw(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    /** Completes the context at most once; the resolver callback,
     * the timeout path and the failure path all race here. */
    private class Completer(private val ctx: ExchangeContext) {
        private val done = java.util.concurrent.atomic.AtomicBoolean(false)

        fun run(what: String, block: (ExchangeContext) -> Unit) {
            if (!done.compareAndSet(false, true)) return
            try {
                block(ctx)
            } catch (t: Throwable) {
                platformLog("resolver: completing context ($what) failed: $t")
            }
        }
    }

    override fun exchange(ctx: ExchangeContext, message: ByteArray) {
        val out = Completer(ctx)
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                out.run("notimp") { it.errorCode(4) } // pre-Q has no raw resolver API.
                return
            }
            val network = LanternNetworkMonitor.awaitNetwork(context)
            if (network == null) {
                platformLog("resolver: exchange with no default network")
                out.run("no-network") { it.errorCode(3) }
                return
            }
            val latch = CountDownLatch(1)
            val signal = CancellationSignal()
            try {
                ctx.onCancel { signal.cancel() }
            } catch (t: Throwable) {
                // Cancellation wiring is best-effort.
            }
            val callback = object : DnsResolver.Callback<ByteArray> {
                override fun onAnswer(answer: ByteArray, rcode: Int) {
                    if (rcode == 0) {
                        out.run("rawSuccess") { it.rawSuccess(answer) }
                    } else {
                        out.run("rcode") { it.errorCode(rcode) }
                    }
                    latch.countDown()
                }

                override fun onError(error: DnsResolver.DnsException) {
                    val cause = error.cause
                    if (cause is ErrnoException) {
                        out.run("errno") { it.errnoCode(cause.errno) }
                    } else {
                        platformLog("resolver: exchange failed: $error")
                        out.run("error") { it.errorCode(3) }
                    }
                    latch.countDown()
                }
            }
            DnsResolver.getInstance().rawQuery(
                network, message, DnsResolver.FLAG_NO_RETRY,
                resolverExecutor, signal, callback,
            )
            if (!latch.await(30, TimeUnit.SECONDS)) {
                platformLog("resolver: exchange timed out after 30s")
                out.run("timeout") { it.errorCode(3) }
            }
        } catch (t: Throwable) {
            platformLog("resolver: exchange threw: $t")
            out.run("threw") { it.errorCode(3) }
        }
    }

    override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
        val out = Completer(ctx)
        try {
            val net = LanternNetworkMonitor.awaitNetwork(context)
            if (net == null) {
                platformLog("resolver: lookup $domain with no default network")
                out.run("no-network") { it.errorCode(3) }
                return
            }
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                val answer = try {
                    net.getAllByName(domain)
                } catch (e: UnknownHostException) {
                    out.run("nxdomain") { it.errorCode(3) } // NXDOMAIN
                    return
                }
                out.run("success") {
                    it.success(answer.mapNotNull { a -> a.hostAddress }.joinToString("\n"))
                }
                return
            }
            val latch = CountDownLatch(1)
            val signal = CancellationSignal()
            try {
                ctx.onCancel { signal.cancel() }
            } catch (t: Throwable) {
                // Cancellation wiring is best-effort.
            }
            val callback = object : DnsResolver.Callback<Collection<InetAddress>> {
                override fun onAnswer(answer: Collection<InetAddress>, rcode: Int) {
                    if (rcode == 0) {
                        out.run("success") {
                            it.success(
                                answer.mapNotNull { a -> a.hostAddress }.joinToString("\n"),
                            )
                        }
                    } else {
                        out.run("rcode") { it.errorCode(rcode) }
                    }
                    latch.countDown()
                }

                override fun onError(error: DnsResolver.DnsException) {
                    val cause = error.cause
                    if (cause is ErrnoException) {
                        out.run("errno") { it.errnoCode(cause.errno) }
                    } else {
                        platformLog("resolver: lookup $domain failed: $error")
                        out.run("error") { it.errorCode(3) }
                    }
                    latch.countDown()
                }
            }
            val resolver = DnsResolver.getInstance()
            val executor = resolverExecutor
            when {
                network.endsWith("4") -> resolver.query(
                    net, domain, DnsResolver.TYPE_A,
                    DnsResolver.FLAG_NO_RETRY, executor, signal, callback,
                )
                network.endsWith("6") -> resolver.query(
                    net, domain, DnsResolver.TYPE_AAAA,
                    DnsResolver.FLAG_NO_RETRY, executor, signal, callback,
                )
                else -> resolver.query(
                    net, domain, DnsResolver.FLAG_NO_RETRY, executor, signal, callback,
                )
            }
            if (!latch.await(30, TimeUnit.SECONDS)) {
                platformLog("resolver: lookup $domain timed out after 30s")
                out.run("timeout") { it.errorCode(3) }
            }
        } catch (t: Throwable) {
            platformLog("resolver: lookup $domain threw: $t")
            out.run("threw") { it.errorCode(3) }
        }
    }
}

/** The PlatformInterface implementation, mixed into LanternVpnService. */
interface LanternPlatformImpl : lantern.io.utils.PlatformInterface {
    val platformContext: Context

    override fun localDNSTransport(): LocalDNSTransport =
        LanternLocalResolver(platformContext)

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    @androidx.annotation.RequiresApi(Build.VERSION_CODES.Q)
    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        // This method HAS an error return on the Go side, so an
        // Exception is the correct failure channel (upstream throws
        // the same way) — but an Error must never cross: convert it.
        try {
            val cm = platformContext.getSystemService(ConnectivityManager::class.java)
            val uid = cm.getConnectionOwnerUid(
                ipProtocol,
                java.net.InetSocketAddress(sourceAddress, sourcePort),
                java.net.InetSocketAddress(destinationAddress, destinationPort),
            )
            if (uid == Process.INVALID_UID) error("android: connection owner not found")
            val packages = platformContext.packageManager.getPackagesForUid(uid)
            val owner = ConnectionOwner()
            owner.userId = uid
            owner.userName = packages?.firstOrNull() ?: ""
            owner.setAndroidPackageNames(
                LanternStringIterator(packages?.toList() ?: emptyList()),
            )
            return owner
        } catch (e: Exception) {
            throw e
        } catch (t: Throwable) {
            throw RuntimeException("findConnectionOwner failed: $t")
        }
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        try {
            LanternNetworkMonitor.start(platformContext)
            LanternNetworkMonitor.setListener(platformContext, listener)
        } catch (t: Throwable) {
            platformLog("startDefaultInterfaceMonitor failed: $t")
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        try {
            LanternNetworkMonitor.setListener(platformContext, null)
        } catch (t: Throwable) {
            platformLog("closeDefaultInterfaceMonitor failed: $t")
        }
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val out = mutableListOf<lantern.io.libbox.NetworkInterface>()
        try {
            return getInterfacesInto(out)
        } catch (t: Throwable) {
            // Partial results beat a throw across the boundary.
            platformLog("getInterfaces failed mid-enumeration: $t")
            return LanternInterfaceIterator(out)
        }
    }

    private fun getInterfacesInto(
        out: MutableList<lantern.io.libbox.NetworkInterface>,
    ): NetworkInterfaceIterator {
        val cm = platformContext.getSystemService(ConnectivityManager::class.java)
        val jvmInterfaces = try {
            NetworkInterface.getNetworkInterfaces()?.toList() ?: emptyList()
        } catch (e: Exception) {
            emptyList()
        }
        for (network in cm.allNetworks) {
            val props = cm.getLinkProperties(network) ?: continue
            val caps = cm.getNetworkCapabilities(network) ?: continue
            val name = props.interfaceName ?: continue
            val jvm = jvmInterfaces.find { it.name == name }
            try {
                val item = lantern.io.libbox.NetworkInterface()
                item.name = name
                item.dnsServer = LanternStringIterator(
                    props.dnsServers.mapNotNull { it.hostAddress },
                )
                item.type = when {
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ->
                        lantern.io.libbox.Libbox.InterfaceTypeWIFI
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ->
                        lantern.io.libbox.Libbox.InterfaceTypeCellular
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) ->
                        lantern.io.libbox.Libbox.InterfaceTypeEthernet
                    else -> lantern.io.libbox.Libbox.InterfaceTypeOther
                }
                item.index = jvm?.index ?: Os.if_nametoindex(name)
                item.mtu = jvm?.mtu ?: props.mtu.takeIf { it > 0 } ?: 1500
                item.addresses = LanternStringIterator(
                    jvm?.interfaceAddresses?.map { it.toPrefix() }
                        ?: props.linkAddresses.map { it.toPrefix() },
                )
                var flags = 0
                if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                    flags = flags or OsConstants.IFF_UP or OsConstants.IFF_RUNNING
                }
                if (jvm != null) {
                    if (jvm.isLoopback) flags = flags or OsConstants.IFF_LOOPBACK
                    if (jvm.isPointToPoint) flags = flags or OsConstants.IFF_POINTOPOINT
                    if (jvm.supportsMulticast()) flags = flags or OsConstants.IFF_MULTICAST
                } else {
                    flags = flags or OsConstants.IFF_MULTICAST
                }
                item.flags = flags
                item.metered =
                    !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                out.add(item)
            } catch (e: Exception) {
                // An interface that vanished mid-enumeration.
            }
        }
        return LanternInterfaceIterator(out)
    }

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun clearDNSCache() {}

    override fun readWIFIState(): WIFIState? {
        return try {
            @Suppress("DEPRECATION")
            val wifi = platformContext.applicationContext
                .getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
            @Suppress("DEPRECATION")
            val info = wifi.connectionInfo ?: return null
            var ssid = info.ssid ?: return null
            if (ssid == "<unknown ssid>") return WIFIState("", "")
            if (ssid.startsWith("\"") && ssid.endsWith("\"")) {
                ssid = ssid.substring(1, ssid.length - 1)
            }
            WIFIState(ssid, info.bssid ?: "")
        } catch (e: Throwable) {
            null
        }
    }

    override fun systemCertificates(): StringIterator = LanternStringIterator(emptyList())
}

private fun java.net.InterfaceAddress.toPrefix(): String {
    return if (address is Inet6Address) {
        "${Inet6Address.getByAddress(address.address).hostAddress}/$networkPrefixLength"
    } else {
        "${address.hostAddress}/$networkPrefixLength"
    }
}

private fun LinkAddress.toPrefix(): String {
    return if (address is Inet6Address) {
        "${Inet6Address.getByAddress(address.address).hostAddress}/$prefixLength"
    } else {
        "${address.hostAddress}/$prefixLength"
    }
}
