package com.ralysnd.ember

/**
 * The Psiphon connection methods and the ladder's memory — a port of
 * the ralysnd (MLM) app's PsiphonMethods (build 2091, the MLM
 * transplant; see mlm-psiphon-full-analysis.md §5/§9). English only,
 * per this app's ruling. The pin itself arrives from the Dart side
 * (the start intent); this object owns the order, the budgets, the
 * labels, and the winner memory.
 *
 *  - **A** domain fronting: ends on a CDN edge, so there is no
 *    Psiphon address to block.
 *  - **E** clean IP: rung A dialled at clean edge addresses found
 *    and proved on this line; only when there are some.
 *  - **D** every protocol, straight to Psiphon's own servers.
 *  - **C** in-proxy: through volunteers' Conduit stations over
 *    WebRTC.
 *  - **P** personal Conduit: only through the station of a pairing
 *    link; only when asked for by name, never part of the automatic
 *    ladder (a friend's station may be off).
 *  - **X** proxy server: Psiphon reaches its servers THROUGH an
 *    HTTP/SOCKS5 proxy, then Psiphon's own ways if no proxy carries.
 */
object PsiphonMethods {

    /** No pin: the ladder, from the rung that last carried a tunnel. */
    const val AUTO = ""

    /** The automatic ladder's order, before the remembered rung is
     *  moved to the front. (P is in the list MLM ships; the ladder
     *  builder filters it out of automatic runs.) */
    val LADDER_ORDER = listOf("A", "E", "D", "C", "P")

    /** Every choice the screen offers, in the order it lists them. */
    val ALL = listOf("A", "E", "D", "C", "P", "X")

    /** Seconds one rung may take before the next one gets its turn.
     *  X: per proxy. */
    fun seconds(name: String): Int = when (name) {
        "A" -> 60
        "E" -> 45
        "D" -> 45
        "C" -> 75
        "P" -> 90
        "X" -> 45
        else -> 45
    }

    fun label(name: String): String = when (name) {
        "A" -> "Domain fronting (CDN)"
        "E" -> "Clean IP"
        "D" -> "All protocols (direct)"
        "C" -> "Relay through other users"
        "P" -> "Personal Conduit"
        "X" -> "Proxy server"
        else -> "Automatic"
    }

    /**
     * Which rung carried the last tunnel, per mode — the direct and
     * upstream-fed ladders are different ladders, so a win in one
     * must never become the first rung of the other. By NAME: an
     * index meant a different rung every time the ladder changed
     * shape, and the clean-IP rung comes and goes with the list.
     * (MLM keys the two modes "plain" and "inside WARP"; Ember's
     * second mode is the upstream-fed ladder — its chain-over-WARP
     * topology is not taken, see PsiphonVpnService.)
     */
    fun remembered(context: android.content.Context, chained: Boolean): String? =
        prefs(context).getString(lastKey(chained), null)?.takeIf { it in LADDER_ORDER }

    fun remember(context: android.content.Context, chained: Boolean, name: String) {
        if (name in LADDER_ORDER) {
            prefs(context).edit().putString(lastKey(chained), name).apply()
        }
    }

    private fun lastKey(chained: Boolean) =
        if (chained) "psiphon_last_rung_chained" else "psiphon_last_rung"

    private fun prefs(context: android.content.Context) =
        context.applicationContext.getSharedPreferences(
            "psiphon_strategy", android.content.Context.MODE_PRIVATE,
        )
}
