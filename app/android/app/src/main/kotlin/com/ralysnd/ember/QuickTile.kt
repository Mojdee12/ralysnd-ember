package com.ralysnd.ember

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log

/** The Quick Settings tile: turns the VPN on or off without the app. */
class QuickTile : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        show()
    }

    override fun onClick() {
        super.onClick()
        if (ConnectWidget.appLockEnabled(this)) {
            // Build 2096 (post-2095 audit M8): the app-lock
            // marker gates the tile exactly like the home
            // widget — build 2095 checked it only in
            // ConnectWidget, so the tile started (and
            // stopped) the VPN behind the PIN.
            openApp()
        } else if (CoreService.on) {
            CoreService.turnOff(this)
        } else if (anotherEngineUp()) {
            // Build 2095 (whole-app journey audit #3): another
            // engine holds the tunnel. Starting Mozilla here
            // would bypass the shell's single-tunnel
            // arbitration — open the app instead, where the
            // shell governs which engine runs.
            openApp()
        } else if (CoreService.usesVpn(this) && VpnService.prepare(this) != null) {
            // The VPN permission is asked in the app.
            openApp()
        } else {
            try {
                CoreService.turnOn(this)
            } catch (e: Exception) {
                // Android refused to start the service from here: the app
                // opens, and its button turns it on.
                Log.w("QuickTile", "starting the service failed; opening the app", e)
                openApp()
            }
        }
        show()
    }

    /**
     * Build 2095 (audit #3): true when a VPN transport is up
     * that is NOT Mozilla's — Xray, Psiphon, Lantern, OpenVPN
     * or an Aether slot holds the device tunnel. The tile
     * used to read CoreService.on only, so it showed INACTIVE
     * while another engine carried the device's traffic.
     */
    private fun anotherEngineUp(): Boolean {
        if (CoreService.on) return false
        val cm = getSystemService(ConnectivityManager::class.java) ?: return false
        // Build 2125 (audit A25-47 / P-51): ALL networks are
        // checked, as the widget's vpnTransportUp does — the
        // active-network-only check read "no other engine"
        // during a handover while the VPN transport was up
        // on a non-active network, and a tile tap could then
        // start Mozilla over the live tunnel.
        return cm.allNetworks.any { network ->
            cm.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }
    }

    private fun show() {
        val tile = qsTile ?: return
        val other = anotherEngineUp()
        // A VPN is on (Mozilla's or another engine's) = ACTIVE;
        // the tile never claims "off" while a tunnel runs.
        tile.state = if (CoreService.on || other) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = when {
                CoreService.on -> "Mozilla"
                other -> "Another engine is on"
                else -> null
            }
        }
        tile.updateTile()
    }

    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(intent)
        }
    }

    companion object {
        /** Asks the system to show the tile's state again. */
        fun refresh(context: Context) {
            TileService.requestListeningState(context, ComponentName(context, QuickTile::class.java))
        }
    }
}
