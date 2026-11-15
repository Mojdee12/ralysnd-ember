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
    }

    /** This process's name ("com.ralysnd.ember" for the main
     *  process, "com.ralysnd.ember:psiphon" for the Psiphon
     *  service's), or "unknown" when the platform won't say. */
    private fun currentProcessName(): String {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                getProcessName() ?: "unknown"
            } else {
                val manager =
                    getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                manager?.runningAppProcesses
                    ?.firstOrNull { it.pid == Process.myPid() }
                    ?.processName ?: "unknown"
            }
        } catch (_: Throwable) {
            "unknown"
        }
    }
}
