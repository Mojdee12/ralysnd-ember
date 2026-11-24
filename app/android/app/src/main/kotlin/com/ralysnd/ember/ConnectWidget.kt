package com.ralysnd.ember

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.util.Log
import android.widget.RemoteViews

/**
 * The home-screen widget: one round button showing the
 * ACTUAL tunnel state and acting within its scope.
 *
 * Build 2095 (feature 5 + third-pass audit 7-1): the
 * upstream widget read and drove CoreService (Mozilla)
 * only — it showed OFF while any other engine carried the
 * tunnel, and its tap started Mozilla natively, bypassing
 * the app's single-tunnel arbitration and the app lock.
 * Now:
 *  - state: Mozilla's own state when Mozilla runs; any
 *    other engine's live VPN transport reads as CONNECTED;
 *  - tap: Mozilla up → stop Mozilla (its own scope, like
 *    the QS tile); another engine up → open the app (the
 *    widget never toggles another engine natively); a PIN
 *    lock set → open the app (the lock gates the tap);
 *    otherwise → start Mozilla, the widget's engine.
 */
class ConnectWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val shown = current(context)
        synchronized(Companion) { last = shown }
        manager.updateAppWidget(ids, views(context, shown))
    }

    /**
     * The button's tap. Not exported (unlike the provider, which receives
     * the system's broadcasts), so other apps cannot turn the VPN on or off.
     */
    class Toggle : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_TOGGLE) return
            when {
                // App lock set: the tap only opens the app —
                // the PIN gates any connect (feature 5).
                appLockEnabled(context) -> openApp(context)
                CoreService.on -> CoreService.turnOff(context)
                // Another engine holds the tunnel: never
                // start Mozilla over it (arbitration) — the
                // app owns switching.
                vpnTransportUp(context) -> openApp(context)
                CoreService.usesVpn(context) && VpnService.prepare(context) != null -> {
                    // The VPN permission is asked in the app.
                    openApp(context)
                }
                else -> {
                    try {
                        CoreService.turnOn(context)
                    } catch (e: Exception) {
                        // Android refused to start the service from here: the app
                        // opens, and its button turns it on.
                        Log.w(TAG, "starting the service failed; opening the app", e)
                        openApp(context)
                    }
                }
            }
            updateAll(context)
        }

        private fun openApp(context: Context) {
            try {
                context.startActivity(appIntent(context).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (e: Exception) {
                Log.w(TAG, "opening the app failed", e)
            }
        }
    }

    /** What the button shows; [needsApp]: a tap opens the app (no VPN permission). */
    private data class Shown(val state: Int, val needsApp: Boolean)

    companion object {
        private const val TAG = "ConnectWidget"
        // Build 2095: renamed from the upstream
        // com.arman.firefoxvpn.* to the app's own prefix.
        private const val ACTION_TOGGLE = "com.ralysnd.ember.WIDGET_TOGGLE"

        private const val OFF = 0
        private const val CONNECTING = 1
        private const val CONNECTED = 2

        /** What the widgets show now, so unchanged states are not sent again. */
        private var last: Shown? = null

        /** True while any network carries the VPN transport. */
        fun vpnTransportUp(context: Context): Boolean {
            val cm = context.getSystemService(ConnectivityManager::class.java)
                ?: return false
            return try {
                cm.allNetworks.any { network ->
                    cm.getNetworkCapabilities(network)
                        ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
                }
            } catch (e: Exception) {
                false
            }
        }

        /** The app-lock marker Dart maintains (channel
         * "setWidgetLock" in MainActivity). */
        fun appLockEnabled(context: Context): Boolean =
            context.getSharedPreferences("ember_widget", Context.MODE_PRIVATE)
                .getBoolean("lock_enabled", false)

        /**
         * Shows the current state on every widget. Cheap when nothing
         * changed, so CoreService may call it on every poll.
         */
        fun updateAll(context: Context) {
            val app = context.applicationContext
            val shown = current(app)
            synchronized(this) {
                if (shown == last) return
                last = shown
            }
            try {
                val manager = AppWidgetManager.getInstance(app) ?: return
                val ids = manager.getAppWidgetIds(ComponentName(app, ConnectWidget::class.java))
                if (ids.isNotEmpty()) manager.updateAppWidget(ids, views(app, shown))
            } catch (e: Exception) {
                Log.w(TAG, "updating the widgets failed", e)
            }
        }

        private fun current(context: Context): Shown {
            val state = when {
                CoreService.on && CoreService.connected -> CONNECTED
                CoreService.on -> CONNECTING
                // Build 2095 (audit 7-1): another engine's
                // tunnel is a connection, not "off".
                vpnTransportUp(context) -> CONNECTED
                else -> OFF
            }
            // Asked only while off: a tap then turns it on.
            val needsApp = state == OFF && CoreService.usesVpn(context) && VpnService.prepare(context) != null
            return Shown(state, needsApp)
        }

        private fun views(context: Context, shown: Shown): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_connect)
            views.setImageViewResource(
                R.id.widget_button,
                when (shown.state) {
                    CONNECTED -> R.drawable.widget_button_on
                    CONNECTING -> R.drawable.widget_button_connecting
                    else -> R.drawable.widget_button_off
                },
            )
            views.setContentDescription(
                R.id.widget_button,
                context.getString(if (shown.state == OFF) R.string.widget_connect else R.string.widget_disconnect),
            )
            // Without the VPN permission the tap opens the app directly (an
            // activity started from a broadcast may be blocked); otherwise
            // it toggles in the background.
            val tap = if (shown.needsApp) {
                PendingIntent.getActivity(
                    context, 0, appIntent(context),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            } else {
                PendingIntent.getBroadcast(
                    context, 0, Intent(context, Toggle::class.java).setAction(ACTION_TOGGLE),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            }
            views.setOnClickPendingIntent(R.id.widget_button, tap)
            return views
        }

        private fun appIntent(context: Context) =
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }
}
