package com.ralysnd.ember

import android.util.Log
import java.net.InetSocketAddress
import java.net.Socket

/**
 * The ONE way to kill a child process in this app (build
 * 2054, audit F-M1): destroy, a grace wait, destroyForcibly,
 * then a bounded wait confirming the death. Before this file
 * the pre-2049 pattern survived in five places — destroy with
 * a short grace and NO post-forcible wait — so a caller that
 * respawned on the same port raced a still-dying process
 * (the exact bind race of the 2049 incident, Fix C).
 *
 * Every engine's stop path funnels through [kill]; the only
 * callers that still kill a process directly are the
 * one-shot validation/stats probes in XrayTester, whose
 * processes hold no session port.
 */
object ProcessKill {
    private const val TAG = "ProcessKill"

    /** True once [p] is dead, bounded by [timeoutMs]. */
    fun waitExit(p: Process, timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (!p.isAlive) return true
            try {
                Thread.sleep(30)
            } catch (e: InterruptedException) {
                return !p.isAlive
            }
        }
        return !p.isAlive
    }

    /**
     * Destroy [p], wait [destroyGraceMs] for a clean exit,
     * escalate to destroyForcibly, then wait up to
     * [forcibleWaitMs] for the death to land. Returns only
     * once the process is dead or both waits are spent; a
     * caller that respawns on the same port must treat a
     * still-alive return as "do not respawn" (the port-free
     * wait below is the backstop, not a substitute).
     *
     * destroyForcibly is a Java 9 surface: on API 24–25 the
     * call itself throws, so it is guarded (EmberWarpCore
     * carried this guard before the shared helper existed).
     */
    fun kill(
        p: Process,
        destroyGraceMs: Long = 400,
        forcibleWaitMs: Long = 2500,
    ) {
        try {
            p.destroy()
            if (!waitExit(p, destroyGraceMs)) {
                try {
                    p.destroyForcibly()
                } catch (_: Throwable) {
                    // API 24–25: no destroyForcibly; destroy()
                    // above is all there is.
                }
                // destroyForcibly is only a signal — the process
                // can still be dying (and still holding its
                // ports) when it returns. Confirm the death,
                // bounded, before anyone respawns (build 2049).
                waitExit(p, forcibleWaitMs)
            }
        } catch (e: Exception) {
            // Already gone.
            Log.d(TAG, "kill raced a dead process", e)
        }
    }

    /**
     * True when nothing accepts a connection on
     * 127.0.0.1:[port] before the deadline — the mirror of a
     * waitForPort. Restart paths verify the old core released
     * its port before respawning on it (build 2049, Fix C;
     * build 2054, audit Q-1: a timeout now FAILS the restart
     * instead of spawning blind on the busy port).
     */
    fun waitPortFree(port: Int, timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (true) {
            val inUse = try {
                Socket().use { s ->
                    s.connect(InetSocketAddress("127.0.0.1", port), 200)
                    true
                }
            } catch (e: Exception) {
                false
            }
            if (!inUse) return true
            if (System.currentTimeMillis() >= deadline) return false
            try {
                Thread.sleep(100)
            } catch (ie: InterruptedException) {
                return false
            }
        }
    }
}
