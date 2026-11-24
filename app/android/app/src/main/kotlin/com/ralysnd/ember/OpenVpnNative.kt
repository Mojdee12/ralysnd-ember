package com.ralysnd.ember

import android.content.Context

/**
 * The OpenVPN engine's native face (build 2025): the OpenVPN 3
 * core, rebuilt from the pinned upstream source behind Ember's
 * own JNI bridge (~/workspace/ember-app/openvpn/src/bridge.cpp,
 * libemberopenvpn.so). The contract is a session-handle design:
 * [evaluate] checks a profile without connecting, [create]
 * hands out a handle, [run] blocks on the session until it
 * ends, [stop]/[release] end and free it.
 *
 * While [run] blocks, the core drives the TUN through the
 * callback object (the service's session): configureTun /
 * addAddress / addRoute / addDns / addSearchDomain /
 * establishTun build the VpnService interface, and
 * onCoreEvent / onCoreTraffic / onCoreLog report back. Native
 * results are fixed error codes ("" = success). Build 2099:
 * [run] may append "\n" + the core's own Status message and
 * onCoreEvent carries the Event's info string as its third
 * argument — in both cases scrubbed by the bridge with the
 * same secret-marker discipline as its log lines before
 * crossing, since a core message can quote profile text and
 * a profile may carry inline secrets. The service splits
 * [run]'s result at the first newline: code left, detail
 * right.
 *
 * The callback methods on the session must keep these exact
 * names and signatures: the bridge resolves them by name.
 */
object OpenVpnNative {
    private var checked: Boolean? = null

    /** True when the library loads and speaks API version 2. */
    @Synchronized
    fun available(context: Context): Boolean {
        checked?.let { return it }
        val ok = try {
            System.loadLibrary("emberopenvpn")
            apiVersion() == 2
        } catch (_: LinkageError) {
            false
        } catch (_: Exception) {
            false
        }
        checked = ok
        return ok
    }

    external fun apiVersion(): Int

    /** "" when the core accepts the profile, else an error code. */
    external fun evaluate(config: String): String

    /** A session handle, or 0 when the core cannot start. */
    external fun create(): Long

    /**
     * Runs the session on the calling thread until it ends.
     * "" when it ended without an error (a user stop included),
     * else an error code — or, build 2099, the code + "\n" +
     * the core's scrubbed Status message when it carried one
     * (see the header). Build 2030: NEED_CREDS is one of the
     * codes — the core ended the session asking for credentials
     * because its own copy was purged (a pushed auth-nocache);
     * the service answers by re-running with the pair it holds.
     */
    external fun run(
        handle: Long,
        config: String,
        username: String,
        password: String,
        callback: Any,
    ): String

    external fun stop(handle: Long)
    external fun release(handle: Long)

    /**
     * Arms the native crash-breadcrumb file (build 2026): the
     * bridge appends one raw-write line per connect stage, so
     * a session that kills the process still names the stage
     * it died in. See OpenVpnTrace.
     */
    external fun setBreadcrumbFile(path: String)
}
