package com.ralysnd.ember

import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.os.Build
import android.os.Process

/**
 * Build 2068: the application's own class, present for one
 * reason — to install [CrashLog] before anything else in the
 * process can run. attachBaseContext is the earliest point
 * Android gives app code; the uncaught-exception handler is in
 * place from there on, ahead of every activity, service,
 * receiver, and provider in the process.
 *
 * Until this build the manifest resolved to the stock
 * android.app.Application (the packaged 2067 manifest's
 * android:name was literally "android.app.Application"), so
 * this class changes nothing else about startup: it is a plain
 * [Application] whose only work is the recorder install, and
 * [CrashLog.install] is idempotent and failure-proof.
 *
 * Build 2073: PsiphonVpnService now runs in its own process
 * (:psiphon — see the manifest), so this class is instantiated
 * once per process, and onCreate additionally records ONE
 * process-birth breadcrumb naming the process being born. A
 * future crash.log paste then discriminates the two deaths the
 * Psiphon investigation could not tell apart: a birth line for
 * the main process right after a Psiphon attempt means the
 * main process died and was relaunched; its absence (with only
 * the :psiphon birth, or none) means the main process survived.
 */
class EmberApplication : Application() {

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        // `base`, not `this`: this wrapper's own context is not
        // attached until super returns; the base context is
        // fully functional and is what install() needs.
        CrashLog.install(base)
    }

    override fun onCreate() {
        super.onCreate()
        // Idempotent: refreshes the remembered filesDir/label
        // and confirms the handler is installed.
        CrashLog.install(this)
        // Build 2073: one line per process start (see the class
        // doc). CrashLog.breadcrumb timestamps it and can never
        // throw, so the birth record cannot break the birth.
        CrashLog.breadcrumb(this, "process-birth ${currentProcessName()}")
        // Build 2104 (verification iteration 1, finding 1):
        // install the WG Tunnel backend eagerly in the MAIN
        // process. Its constructor is the only place
        // BackendRuntime.install runs, and the backend's own
        // services dereference that runtime when the system
        // restarts them — a lazy Dart-driven first build
        // would leave a fresh process crashing instead of
        // restoring. The :psiphon process never runs the
        // backend and skips this.
        if (currentProcessName() == packageName) {
            WgTunnelEngine.install(this)
            // Build 2125 (audit A25-18 / P-25): reap helper
            // orphans at process birth. Each helper's
            // reapOrphan used to run only from its own
            // start(), so when Android killed the main
            // process mid-session, the orphaned helper kept
            // its loopback listener (and any egress) until
            // that same helper was next started —
            // potentially never. A pid file present at
            // birth in a fresh process is by construction
            // from a previous life. MAIN process only: the
            // :psiphon process must never reap the main
            // process's live helpers. Every reap is
            // failure-proof by design; the runCatching is
            // belt and braces — a sweep must never break a
            // birth.
            runCatching { SingBoxCore.reapOrphan(this) }
            // Build 2135 (audit A34-03): the two
            // SubprocessCore families added in 2127 were
            // missing from this list — their orphans were
            // reaped only at their own next start(), so a
            // killed process left libzapret.so /
            // libsudokubox.so holding 127.0.0.1:20864 /
            // :20865 across restarts.
            runCatching { ZapretCore.reapOrphan(this) }
            runCatching { SudokuBoxCore.reapOrphan(this) }
            runCatching { MieruCore.reapOrphan(this) }
            runCatching { DnsCryptCore.reapOrphan(this) }
            runCatching { DnsttCore.reapOrphan(this) }
            runCatching { OlcrtcCore.reapOrphan(this) }
            runCatching { WstunnelCore.reapOrphan(this) }
            runCatching { EmberWarpCore.reapOrphan(this) }
            runCatching { AetherCore.reapOrphans(this) }
            // Build 2129 (Leg 3): the Senpai scanner — a
            // killed app's scan must not leak into the next
            // launch (its state file makes the run resumable
            // instead; see SenpaiCore).
            runCatching { SenpaiCore.reapOrphan(this) }
        }
    }

    /** This process's name ("com.ralysnd.ember" for the main
     *  process, "com.ralysnd.ember:psiphon" for the Psiphon
     *  service's), or "unknown" when the platform won't say. */
    private fun currentProcessName(): String {
        val named = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                getProcessName()
            } else {
                val manager =
                    getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                manager?.runningAppProcesses
                    ?.firstOrNull { it.pid == Process.myPid() }
                    ?.processName
            }
        } catch (_: Throwable) {
            null
        }
        if (!named.isNullOrEmpty()) return named
        // Build 2104 (verification iteration 2, L1): on API
        // 26/27 — inside the new minSdk — the platform paths
        // above can yield nothing, and an "unknown" here
        // would silently skip the eager backend install the
        // guard in onCreate keys on. /proc/self/cmdline is
        // readable on every API level and always carries the
        // process name as its first NUL-terminated token.
        return try {
            val raw = java.io.File("/proc/self/cmdline").readBytes()
            String(raw, Charsets.UTF_8)
                .split('\u0000')
                .firstOrNull { it.isNotEmpty() } ?: "unknown"
        } catch (_: Throwable) {
            "unknown"
        }
    }
}
