package com.ralysnd.ember

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build

/**
 * Launcher shortcuts for one-tap connect (build 2093,
 * feature-watch 2026-11-16, FlClash 0.9.x): long-press the app
 * icon to connect straight to a starred config. The Dart side
 * owns which profiles become shortcuts (the starred set, at most
 * four, in list order); this side owns the ShortcutManager calls.
 * Everything here is best-effort — a launcher that refuses the
 * publish (API < 25, a rate limit) never throws into the caller,
 * and a shortcut that cannot connect is never published.
 */
object LauncherShortcuts {
    /** The intent action a shortcut tap carries. */
    const val ACTION_CONNECT = "com.ralysnd.ember.action.CONNECT_SHORTCUT"

    /** The tapped shortcut's profile id. */
    const val EXTRA_PROFILE_ID = "ember_profile_id"

    /** Android shows at most 5 dynamic shortcuts; Ember publishes 4. */
    const val MAX_SHORTCUTS = 4

    /**
     * The starred profiles as dynamic shortcuts. [items] are
     * (profile id, display name) pairs; the profile id is the
     * shortcut id (unique per profile by construction, short
     * enough to need no prefix), and the tap carries it as an
     * extra — the id is only the manager's key.
     */
    fun publish(context: Context, items: List<Pair<String, String>>) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return
        try {
            val manager =
                context.getSystemService(ShortcutManager::class.java) ?: return
            val infos = items
                .filter { (id, name) -> id.isNotBlank() && name.isNotBlank() }
                .distinctBy { (id, _) -> id }
                .take(MAX_SHORTCUTS)
                .mapIndexed { rank, (id, name) ->
                    val intent = Intent(context, MainActivity::class.java)
                        .setAction(ACTION_CONNECT)
                        .putExtra(EXTRA_PROFILE_ID, id)
                    // Build 2095 (audit 5-9): stamp the
                    // intent as the app's own.
                    EmberIntentNonce.stamp(context, intent)
                        .addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_CLEAR_TOP,
                        )
                    ShortcutInfo.Builder(context, id)
                        .setShortLabel(name)
                        .setLongLabel("Connect to $name")
                        .setIcon(
                            Icon.createWithResource(
                                context,
                                R.mipmap.ic_launcher,
                            ),
                        )
                        .setIntent(intent)
                        .setRank(rank)
                        .build()
                }
            manager.dynamicShortcuts = infos
        } catch (_: Exception) {
            // A refused publish must never break starring or connecting.
        }
    }

    /** Removes every Ember dynamic shortcut (shortcuts switched off). */
    fun clear(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return
        try {
            context.getSystemService(ShortcutManager::class.java)
                ?.removeAllDynamicShortcuts()
        } catch (_: Exception) {
            // Clearing is best-effort too.
        }
    }

    /** The profile id a shortcut tap carries, or null. */
    fun extractProfileId(intent: Intent?): String? {
        if (intent?.action != ACTION_CONNECT) return null
        return intent.getStringExtra(EXTRA_PROFILE_ID)
            ?.takeIf { it.isNotBlank() }
    }

    /**
     * Build 2095 (audit 5-9): the nonce-checked read
     * MainActivity uses — an unstamped intent (another
     * app's forgery) yields nothing.
     */
    fun extractProfileIdChecked(context: Context, intent: Intent?): String? {
        if (!EmberIntentNonce.matches(context, intent)) return null
        return extractProfileId(intent)
    }
}
