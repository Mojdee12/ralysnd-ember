package com.ralysnd.ember

import android.util.Log

/**
 * The AmneziaWG userspace engine (build 2040, Iran-priority
 * queue 2h): a `libwg-go.so` built from
 * `github.com/amnezia-vpn/amneziawg-go` (the AmneziaWG fork of
 * wireguard-go) with a small CGO/JNI bridge, so a profile that
 * carries Jc/Jmin/Jmax/S1/S2/H1–H4 runs with real obfuscation
 * instead of plain WireGuard through Xray (which cannot apply
 * those parameters at all).
 *
 * The bridge's contract (see the Go package in awg-spike/):
 * `wgTurnOn` creates the device on a TUN file descriptor the
 * caller hands over — the fd then belongs to the device, and
 * `wgTurnOff` closes it — and applies the UAPI settings
 * string; `wgGetConfig` returns the device's UAPI dump, from
 * which the handshake age and transfer counters prove the
 * tunnel carries traffic; `wgGetSocketV4/V6` expose the UDP
 * socket fds so the service can `protect()` them before the
 * first handshake packet leaves.
 *
 * Loading is lazy and guarded: a build without the library (or
 * a broken one) reports [available] == false instead of
 * crashing at class load, and the controller then falls back
 * to the plain-WireGuard Xray path.
 */
object AwgBackend {
    private const val TAG = "AwgBackend"

    @Volatile
    var available = false
        private set

    /** Loads libwg-go.so once; false when the library is absent or broken. */
    @Synchronized
    fun ensureLoaded(): Boolean {
        if (available) return true
        return try {
            System.loadLibrary("wg-go")
            available = true
            true
        } catch (e: Throwable) {
            Log.e(TAG, "libwg-go.so did not load", e)
            false
        }
    }

    /** The amneziawg-go version the library was built from, '' when unavailable. */
    fun version(): String =
        if (!ensureLoaded()) "" else runCatching { nativeVersion() }.getOrDefault("")

    /**
     * Starts a device on [tunFd] with [settings] (the UAPI
     * string from the Dart side). The fd now belongs to the
     * device: it must NOT be closed by the caller, and
     * [turnOff] closes it. Returns a handle (> 0), or -1.
     */
    fun turnOn(tunFd: Int, settings: String): Int =
        if (!ensureLoaded()) -1
        else runCatching { nativeTurnOn(tunFd, settings) }.getOrDefault(-1)

    /** Stops the device behind [handle] and closes its TUN fd. No-op for a bad handle. */
    fun turnOff(handle: Int) {
        if (handle <= 0 || !available) return
        runCatching { nativeTurnOff(handle) }
            .onFailure { Log.e(TAG, "wgTurnOff failed", it) }
    }

    /** The device's UAPI dump (peers, latest_handshake, transfer counters), null when gone. */
    fun getConfig(handle: Int): String? =
        if (handle <= 0 || !available) null
        else runCatching { nativeGetConfig(handle) }.getOrNull()
            // The bridge returns "" (not null) for a dead device;
            // callers treat blank as gone, so normalize it here.
            ?.takeIf { it.isNotEmpty() }

    /** Applies further UAPI settings to a running device; 0 ok, negative on error. */
    fun setConfig(handle: Int, settings: String): Int =
        if (handle <= 0 || !available) -1
        else runCatching { nativeSetConfig(handle, settings) }.getOrDefault(-1)

    /** The device's IPv4 UDP socket fd for VpnService.protect(), -1 while none exists. */
    fun getSocketV4(handle: Int): Int =
        if (handle <= 0 || !available) -1
        else runCatching { nativeGetSocketV4(handle) }.getOrDefault(-1)

    /** The device's IPv6 UDP socket fd for VpnService.protect(), -1 while none exists. */
    fun getSocketV6(handle: Int): Int =
        if (handle <= 0 || !available) -1
        else runCatching { nativeGetSocketV6(handle) }.getOrDefault(-1)

    private external fun nativeTurnOn(tunFd: Int, settings: String): Int
    private external fun nativeTurnOff(handle: Int)
    private external fun nativeGetConfig(handle: Int): String?
    private external fun nativeSetConfig(handle: Int, settings: String): Int
    private external fun nativeGetSocketV4(handle: Int): Int
    private external fun nativeGetSocketV6(handle: Int): Int
    private external fun nativeVersion(): String
}
