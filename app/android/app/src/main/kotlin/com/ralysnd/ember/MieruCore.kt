package com.ralysnd.ember

import android.content.Context
import java.io.File

/**
 * The Mieru client sidecar (build 2075): the official
 * enfein/mieru v3.39.0 android_arm64 binary, vendored in
 * ~/workspace/ember-app/engines/mieru (see PROVENANCE.md
 * there) and staged in jniLibs as libmieru.so. sing-box
 * has no Mieru outbound (verified by config check against
 * sing-box 1.14.4: "unknown outbound type: mieru"), so
 * Mieru rides its own upstream client, like DNSTT does.
 *
 * Lifecycle differs from the other subprocess cores in one
 * step: mieru keeps its configuration in a protobuf store
 * under $HOME/.config/mieru, written by a one-shot
 * `mieru replace config <file>` invocation. SubprocessCore
 * already runs children with HOME=<workDir>, so
 * [startWithConfig] performs that replace first (a failure
 * — an unknown field, a bad port binding — fails the start
 * with mieru's own message as the plain error), then spawns
 * the foreground daemon form, `mieru run`, under the base
 * class's supervision. The daemon serves SOCKS5 on [PORT];
 * the generated client config also pins the management RPC
 * to a high loopback port (28964) so it cannot collide with
 * a separately installed Mieru app's default, and disables
 * mieru's self update check.
 *
 * The config shape was validated against the real binary
 * during development: replace config → start → the SOCKS
 * port opens → stop.
 */
object MieruCore : SubprocessCore(
    libName = "libmieru.so",
    dirName = "mieru",
    port = 20863,
    tcpProbe = true,
    label = "Mieru client",
) {
    /** The fixed local SOCKS5 port (mirrored in Dart:
     *  mieruListenPort in mieru_config.dart). */
    const val PORT = 20863

    /**
     * Writes [configJson] as the client configuration via
     * `replace config`, then starts the daemon. Returns
     * false (with [state]'s error set) when either step
     * fails.
     */
    @Synchronized
    fun startWithConfig(context: Context, configJson: String): Boolean {
        val bin = binary(context)
        if (!bin.exists()) {
            stage = "error"
            lastError = "the Mieru client is missing"
            return false
        }
        val dir = workDir(context)
        val configFile = File(dir, "client-config.json")
        try {
            // Build 2116 (AB-13): atomic — a kill mid-write
            // tore this config and the next start inherited
            // the tear.
            AtomicFile.writeText(configFile, configJson)
            val pb = ProcessBuilder(
                listOf(bin.absolutePath, "replace", "config", configFile.absolutePath),
            )
            pb.directory(dir)
            pb.redirectErrorStream(true)
            val env = pb.environment()
            env["HOME"] = dir.absolutePath
            env["TMPDIR"] = context.cacheDir.absolutePath
            val p = pb.start()
            val out = p.inputStream.bufferedReader().readText().trim()
            val code = p.waitFor()
            if (code != 0) {
                stage = "error"
                lastError = "the Mieru client rejected its config" +
                    if (out.isNotEmpty()) ": ${out.lineSequence().firstOrNull() ?: ""}" else ""
                return false
            }
        } catch (e: Exception) {
            stage = "error"
            lastError = "the Mieru client could not take its config: ${e.message}"
            return false
        }
        return start(context, listOf("run"))
    }
}
