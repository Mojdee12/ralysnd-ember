package com.ralysnd.ember

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Build 2065 (auto-connect triggers): records that the device
 * booted, in a plain SharedPreferences file the Dart side consumes
 * on its next start ('consumeBootPending' on the app channel).
 *
 * The receiver deliberately does NOT try to start the VPN itself:
 * Android 12+ forbids background foreground-service starts from a
 * boot receiver, and a half-started tunnel with no UI would be
 * worse than none. The honest contract, also stated in the
 * Settings copy: with auto-connect on boot enabled, the tunnel
 * connects as soon as the app next runs after a boot.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_BOOT_PENDING, true)
            .apply()
    }

    companion object {
        const val PREFS = "ember_autoconnect"
        const val KEY_BOOT_PENDING = "bootPending"
    }
}
