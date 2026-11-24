package com.ralysnd.ember

import android.content.Context
import android.content.Intent
import java.util.UUID

/**
 * Build 2095 (third-pass audit 5-9): MainActivity is
 * exported, and its command extras (ember_action=rotate,
 * the shortcut-connect profile id) were forgeable by any
 * app on the phone — a crafted intent could rotate the
 * user's server or connect a profile with no tap from
 * him. Every legitimate sender (the published launcher
 * shortcuts, the notification actions) now stamps a
 * per-install nonce kept in private SharedPreferences;
 * MainActivity honours the extras only with the stamp.
 * The nonce never leaves the app: the senders and the
 * check are all in this process's code.
 */
object EmberIntentNonce {
    private const val PREFS = "ember_intents"
    private const val KEY = "nonce"
    const val EXTRA = "ember_nonce"

    fun get(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(KEY, null)?.let { return it }
        val fresh = UUID.randomUUID().toString()
        prefs.edit().putString(KEY, fresh).apply()
        return fresh
    }

    /** Stamps [intent] as one of the app's own. */
    fun stamp(context: Context, intent: Intent): Intent =
        intent.putExtra(EXTRA, get(context))

    /** True when [intent] carries this install's stamp. */
    fun matches(context: Context, intent: Intent?): Boolean {
        if (intent == null) return false
        val carried = intent.getStringExtra(EXTRA) ?: return false
        return carried == get(context)
    }
}
