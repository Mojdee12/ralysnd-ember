package com.ralysnd.ember

import android.content.Context
import android.content.Intent
import java.io.File

/**
 * Build 2116 (B7-1, audit AB-08): the native single-writer
 * claim on the device's ONE Android VPN slot.
 *
 * Single-engine-at-a-time used to be enforced only in Dart
 * (the shell's arbitration), but several start paths never
 * pass through Dart: the QS tile starting Mozilla, an Xray
 * session resumed from its own notification, the WG Tunnel
 * backend resurrecting a tunnel at process start, Psiphon's
 * file-state world. Two engines could transiently both
 * believe they owned the route.
 *
 * The claim is a marker file in filesDir naming the engine
 * that owns the slot. EVERY VpnService start funnel claims
 * through here (each service's onStartCommand, and
 * WgTunnelEngine.start for the library-hosted backend):
 * claiming stops the previous owner when it is a different
 * engine, through that engine's own stop entry point. A
 * service releases the claim on its stop path / onDestroy
 * (release is owner-checked, so a displaced engine's late
 * teardown never clears the new owner's claim).
 *
 * One exception (build 2119, audit F-04): the three session
 * kinds XrayVpnService hosts (xray / warp / aether) never
 * stop each other through here — the stop intent could land
 * after the incoming start and kill it. A kind switch inside
 * that host is torn down by the host's own start path; the
 * claim still moves to the incoming kind.
 *
 * The marker is evidence, not proof of life: a killed
 * process leaves it behind. Readers that act on it (the
 * Dart shell's foreground re-arbitration) verify liveness
 * against the engines' own state before believing it, and
 * clear it when nothing it names is live.
 */
object EngineClaim {
    const val MOZILLA = "mozilla"
    const val XRAY = "xray"
    const val WIREGUARD = "wireguard"
    const val LANTERN = "lantern"
    const val OPENVPN = "openvpn"
    const val PSIPHON = "psiphon"

    // Build 2119 (audit F-04): the two XrayVpnService-hosted
    // session kinds get their own identities. Up to 2118 a
    // standalone-WARP start and an Aether (SOCKS) start both
    // claimed XRAY, so claim() — which displaces only a
    // DIFFERENT owner — never stopped a plain Xray session
    // for an Aether one or the reverse natively; that
    // arbitration rested on the Dart hooks alone. Stopping
    // either still funnels through XrayVpnService.stop: the
    // service is the TUN host for all three kinds.
    const val WARP = "warp"
    const val AETHER = "aether"

    private const val FILE_NAME = "engine_claim"

    private fun file(context: Context) = File(context.filesDir, FILE_NAME)

    // Build 2125 (audit A25-01 / P-07): claim() used to be
    // an unsynchronized read-modify-write — read owner,
    // displace, write marker — executed from the main
    // process, WG coroutines and the :psiphon process at
    // once. Two claimants could both read the same previous
    // owner, both displace, and both write; the marker then
    // named one engine while the other held the TUN, and
    // every later reader acted on the wrong name. The whole
    // read-displace-write (and the check-and-delete of
    // release/clear) now runs under a two-level lock: an
    // in-process monitor (threads) plus an exclusive
    // FileLock on a sibling lock file (processes). The lock
    // is held only for the marker transaction itself —
    // stopEngine's intents are fire-and-forget, so holding
    // it across the displacement cannot deadlock against
    // the displaced engine's own release (which queues
    // briefly behind the lock and then proceeds).
    private val claimMonitor = Any()

    /** Build 2126 (A26-09): the claim-lock fail-open is
     *  journaled at most once per process. */
    @Volatile
    private var lockFailureJournaled = false

    private fun <T> withClaimLock(context: Context, block: () -> T): T {
        synchronized(claimMonitor) {
            val lockFile = File(context.filesDir, "$FILE_NAME.lock")
            java.io.RandomAccessFile(lockFile, "rw").use { raf ->
                val lock = try {
                    raf.channel.lock()
                } catch (e: Exception) {
                    // A lock that cannot be taken must not
                    // break the start the claim rides on: the
                    // transaction proceeds unguarded, exactly
                    // the pre-2125 behaviour, rather than
                    // failing the engine start.
                    // Build 2126 (audit A26-09): the
                    // fail-open is journaled, once per
                    // process — up to 2125 it was silent, so
                    // a device where the lock never works
                    // reverted to the pre-2125 claim race
                    // with no trace anywhere.
                    if (!lockFailureJournaled) {
                        lockFailureJournaled = true
                        CrashLog.breadcrumb(
                            context,
                            "engine_claim_lock_failed_fail_open",
                        )
                    }
                    null
                }
                try {
                    return block()
                } finally {
                    try {
                        lock?.release()
                    } catch (e: Exception) {
                        // Released by the channel close anyway.
                    }
                }
            }
        }
    }

    /** The engine the marker names, or null. Never throws. */
    fun owner(context: Context): String? = try {
        val f = file(context)
        if (f.exists()) f.readText().trim().ifEmpty { null } else null
    } catch (e: Exception) {
        null
    }

    /**
     * Claims the slot for [engine]: a different previous
     * owner is stopped through its own stop entry point,
     * then the marker is written. Returns the previous
     * owner (null when the slot was free or already ours).
     * Never throws — a claim failure must not break the
     * start it rides on; the start proceeds and the Dart
     * re-arbitration remains as the backstop.
     */
    fun claim(context: Context, engine: String): String? {
        // Build 2126 (audit A26-29): a claim is a natural,
        // infrequent housekeeping moment — reap any
        // AtomicFile temp orphans in filesDir while here.
        AtomicFile.sweepOrphans(context.filesDir)
        var prev: String? = null
        try {
            // Build 2125 (audit A25-01 / P-07): the read,
            // the displacement and the marker write are one
            // locked transaction (see withClaimLock) — no
            // second claimant can interleave between them.
            withClaimLock(context) {
                prev = owner(context)
                val previous = prev
                if (previous != null && previous != engine) {
                    if (isXrayHosted(previous) && isXrayHosted(engine)) {
                    // Build 2119 (audit F-04): both kinds are
                    // hosted by XrayVpnService itself. Stopping
                    // the "previous owner" would send that same
                    // service a STOP intent, which Android can
                    // deliver AFTER the start that is claiming
                    // here — tearing down the session that just
                    // started. The host's own start path is the
                    // teardown for a kind switch: it overwrites
                    // the session state, sweeps the old core
                    // processes, and the platform revokes the
                    // old TUN when the new one establishes. The
                    // claim still moves to the incoming kind, so
                    // every other engine now displaces — and
                    // reads — the true owner by name.
                        CrashLog.breadcrumb(
                            context,
                            "engine-claim: $engine takes the xray-hosted " +
                                "slot from $previous",
                        )
                    } else {
                        stopEngine(context, previous)
                        CrashLog.breadcrumb(
                            context,
                            "engine-claim: $engine displaced $previous",
                        )
                    }
                }
                AtomicFile.writeText(file(context), engine)
            }
        } catch (e: Exception) {
            CrashLog.append(context, "EngineClaim.claim", e)
        }
        return prev
    }

    /** The session kinds XrayVpnService hosts (build 2119). */
    private fun isXrayHosted(engine: String): Boolean =
        engine == XRAY || engine == WARP || engine == AETHER

    /** Releases the claim when [engine] still owns it. */
    fun release(context: Context, engine: String) {
        try {
            // Build 2125 (audit A25-01 / P-07): the
            // owner-check and the delete are one locked
            // transaction, like claim() — an interleaved
            // claim can no longer be deleted by a late
            // release meant for the previous owner.
            withClaimLock(context) {
                if (owner(context) == engine) file(context).delete()
            }
        } catch (e: Exception) {
            // Best effort: a stale marker is cleaned up by
            // the next claim or the shell's re-arbitration.
        }
    }

    /** Clears the marker unconditionally (stale-marker
     *  cleanup by the shell's re-arbitration). */
    fun clear(context: Context) {
        try {
            withClaimLock(context) {
                file(context).delete()
            }
        } catch (e: Exception) {
            // Best effort, as in release.
        }
    }

    /**
     * Build 2125 (audit A25-17 / P-24): rewrites the marker
     * to name [engine] WITHOUT displacing anyone — the
     * shell's re-arbitration uses it when its own live-state
     * evidence says [engine] is the session actually running
     * while the marker names a different (stale) engine.
     * Correcting the record must never stop anything: the
     * engine being named is already live, and the engine
     * being un-named is already gone (that is what makes the
     * marker stale). Locked like claim(), so the correction
     * cannot interleave with a real claim.
     */
    fun rewrite(context: Context, engine: String) {
        try {
            withClaimLock(context) {
                AtomicFile.writeText(file(context), engine)
            }
            CrashLog.breadcrumb(
                context,
                "engine-claim: marker corrected to $engine",
            )
        } catch (e: Exception) {
            CrashLog.append(context, "EngineClaim.rewrite", e)
        }
    }

    /** Stops [engine] through its own stop entry point —
     *  the same funnels the UI and notifications use. */
    private fun stopEngine(context: Context, engine: String) {
        when (engine) {
            MOZILLA -> CoreService.turnOff(context)
            XRAY -> XrayVpnService.stop(context)
            WARP -> XrayVpnService.stop(context)
            AETHER -> XrayVpnService.stop(context)
            WIREGUARD -> WgTunnelEngine.stop(context)
            LANTERN -> stopByIntent(
                context,
                Intent(context, LanternVpnService::class.java)
                    .setAction(LanternVpnService.ACTION_STOP),
            )
            OPENVPN -> stopByIntent(
                context,
                Intent(context, OpenVpnService::class.java)
                    .setAction(OpenVpnService.ACTION_STOP),
            )
            PSIPHON -> stopByIntent(
                context,
                Intent(context, PsiphonVpnService::class.java)
                    .setAction(PsiphonVpnService.ACTION_STOP),
            )
        }
    }

    /** The XrayVpnService.stop shape: the service's own
     *  ACTION_STOP intent, with a plain stopService as the
     *  fallback when the platform refuses the start. */
    private fun stopByIntent(context: Context, intent: Intent) {
        try {
            context.startService(intent)
        } catch (e: Exception) {
            try {
                context.stopService(intent)
            } catch (e2: Exception) {
                // Nothing more to do: the claimant's own
                // TUN establishment revokes the loser's
                // interface at the platform level.
            }
        }
    }
}
