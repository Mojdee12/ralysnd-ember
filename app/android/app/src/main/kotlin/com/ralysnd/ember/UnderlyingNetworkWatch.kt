package com.ralysnd.ember

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Build 2123 (audit P-06 / E-03): underlying-network tracking
 * for the TUN engines that never got Mozilla's fix.
 *
 * Mozilla's CoreService has watched the best non-VPN network
 * since its own blackhole bug ("the VPN stayed on the Wi-Fi
 * that was gone, and apps said 'Waiting for network'"):
 * `setUnderlyingNetworks` re-points the TUN at the live
 * network, and a change signal lets the core re-dial at once
 * instead of stalling on sockets bound to a dead path.
 * Xray, Lantern and OpenVPN had neither — a Wi-Fi↔mobile
 * switch blackholed a "Connected" session indefinitely,
 * and Xray's native health probe is loopback-only, so
 * nothing ever noticed.
 *
 * This is that callback, shared: it mirrors CoreService's
 * watchNetwork() semantics exactly (best-matching NOT_VPN
 * request on Android 12+, default-network callback below;
 * VPN-transport networks ignored; a change is a different
 * network than the current one, or any network after a
 * loss). The service supplies [onChanged] — Xray rotates
 * its core so outbounds re-dial on the new path; Lantern
 * and OpenVPN rely on setUnderlyingNetworks plus their
 * stacks' own re-dial/reconnect, which is what their cores
 * are built to do once the TUN points at a live network.
 *
 * CoreService keeps its own inline copy — untouched; this
 * helper exists so the other three services share one
 * implementation instead of three near-copies.
 */
class UnderlyingNetworkWatch(
    private val service: VpnService,
    private val tag: String,
    private val onChanged: () -> Unit,
) {
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var current: Network? = null
    private var lost = false

    /** Registers the callback (idempotent). Never throws. */
    fun start() {
        if (callback != null) return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // This VPN's own network is no underlying one.
                val cm = service.getSystemService(
                    ConnectivityManager::class.java,
                )
                val caps = try {
                    cm?.getNetworkCapabilities(network)
                } catch (e: Exception) {
                    null
                }
                if (caps?.hasTransport(
                        NetworkCapabilities.TRANSPORT_VPN,
                    ) == true
                ) {
                    return
                }
                val changed = (current != null && current != network) ||
                    (current == null && lost)
                current = network
                lost = false
                try {
                    service.setUnderlyingNetworks(arrayOf(network))
                } catch (e: Exception) {
                    Log.w(tag, "setUnderlyingNetworks failed", e)
                }
                if (changed) {
                    try {
                        onChanged()
                    } catch (e: Throwable) {
                        Log.w(tag, "network-change handler failed", e)
                    }
                }
            }

            override fun onLost(network: Network) {
                if (network != current) return
                current = null
                lost = true
                try {
                    service.setUnderlyingNetworks(null)
                } catch (e: Exception) {
                    Log.w(tag, "setUnderlyingNetworks(null) failed", e)
                }
            }
        }
        try {
            val connectivity = service.getSystemService(
                ConnectivityManager::class.java,
            ) ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val request = NetworkRequest.Builder()
                    .addCapability(
                        NetworkCapabilities.NET_CAPABILITY_INTERNET,
                    )
                    .addCapability(
                        NetworkCapabilities.NET_CAPABILITY_NOT_VPN,
                    )
                    .build()
                connectivity.registerBestMatchingNetworkCallback(
                    request,
                    cb,
                    Handler(Looper.getMainLooper()),
                )
            } else {
                connectivity.registerDefaultNetworkCallback(cb)
            }
            callback = cb
        } catch (e: Exception) {
            Log.w(tag, "watching the network failed", e)
        }
    }

    /** Unregisters the callback if registered. Never throws. */
    fun stop() {
        val cb = callback ?: return
        callback = null
        current = null
        lost = false
        try {
            service.getSystemService(ConnectivityManager::class.java)
                ?.unregisterNetworkCallback(cb)
        } catch (e: Exception) {
            // Already gone — nothing to do.
        }
    }
}
