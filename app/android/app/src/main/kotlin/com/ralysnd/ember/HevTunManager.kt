package com.ralysnd.ember

import android.os.ParcelFileDescriptor
import hev.htproxy.TProxyService
import java.io.File
import java.io.IOException

/**
 * The V2Ray path's TUN → SOCKS5 bridge since build 2155 (the
 * 2153 bridge swap): hev-socks5-tunnel (heiher, C + lwIP, no
 * gVisor), in-process via its own JNI — the shape
 * [Tun2SocksManager] established for the Psiphon path's
 * badvpn bridge, adapted to hev's different native contract:
 *
 *  - hev's start spawns its own pthread and returns at once
 *    (badvpn's run() blocks the calling thread instead), so
 *    there is no manager thread here.
 *  - hev's stop quit+joins that pthread synchronously, so
 *    [stop] returning means the bridge is fully dead — the
 *    single-instance guarantee across engine switches is the
 *    native side's own (its start also refuses while an
 *    instance runs).
 *  - hev closes the TUN fd it is handed on teardown, so
 *    [start] passes a dup: the service keeps its original
 *    descriptor for the session's whole life, exactly like
 *    the badvpn path.
 *
 * The bridge feeds the Xray core's SOCKS inbound (TCP + UDP
 * ASSOCIATE) — the same inbound the tunlink subprocess fed;
 * the legacy tunlink path remains selectable in Settings
 * (XraySettings.v2rayBridge) and is untouched.
 */
object HevTunManager {

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

    /**
     * The bridge's own liveness, straight from the native
     * flag. False before the first start, after a stop, and
     * after the native thread exits on its own — the watch
     * loop's bridge proof for a hev session (which has no
     * bridge subprocess to poll).
     */
    val isRunning: Boolean
        get() = try {
            TProxyService.TProxyIsRunning()
        } catch (_: Throwable) {
            false
        }

    /**
     * Start the bridge against [tunFd], reading [configFile]
     * (the session's hev YAML — see XrayVpnService's
     * hevConfigYaml). [tunFd] is duplicated internally: the
     * native side takes ownership of the fd it is given and
     * closes it on exit, so the caller keeps its original
     * descriptor alive for the whole VPN session.
     *
     * A live instance is stopped first (its stop joins
     * synchronously), so a start can never overlap a previous
     * bridge — the overlap the native side itself refuses.
     */
    @Synchronized
    fun start(configFile: File, tunFd: ParcelFileDescriptor): Boolean {
        if (isRunning) {
            record("hev: previous instance still up; stopping it first")
            stop()
        }
        val duplicated = try {
            tunFd.dup()
        } catch (e: IOException) {
            record("hev: could not dup tun fd: ${e.message}")
            return false
        }
        val fd = duplicated.detachFd()
        val ok = try {
            TProxyService.TProxyStartService(configFile.absolutePath, fd)
        } catch (e: Throwable) {
            record("hev: start failed: ${e.message}")
            false
        }
        if (!ok) {
            // Every native refusal path leaves the fd
            // unconsumed (hev-jni.c: the already-running
            // refusal returns before the fd is stored, and a
            // failed pthread_create frees its bookkeeping
            // without closing) — so the detached dup is ours
            // to close here rather than leak the descriptor.
            try {
                ParcelFileDescriptor.adoptFd(fd).close()
            } catch (_: Throwable) {
                // Already gone.
            }
            record("hev: the native start was refused")
            return false
        }
        record("hev: bridge started")
        return true
    }

    /**
     * Stop the bridge and wait for it: the native stop
     * quit+joins the tunnel thread, so when this returns the
     * bridge is fully dead and the TUN can close safely.
     * A no-op when nothing is running.
     */
    @Synchronized
    fun stop() {
        if (!isRunning) return
        try {
            TProxyService.TProxyStopService()
        } catch (e: Throwable) {
            record("hev: stop error: ${e.message}")
        }
        record("hev: bridge stopped")
    }
}
