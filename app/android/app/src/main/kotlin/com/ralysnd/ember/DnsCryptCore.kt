package com.ralysnd.ember

/**
 * The DNSCrypt proxy sidecar (build 2075): the official
 * dnscrypt-proxy 2.1.20 android_arm64 binary, vendored in
 * ~/workspace/ember-app/engines/dnscrypt (see PROVENANCE.md
 * there) and staged in jniLibs as libdnscrypt.so.
 *
 * The Dart side writes a minimal TOML config into the work
 * dir (a pinned public resolver set, DNSCrypt + DoH) and
 * passes `-config <path>`; the proxy listens on [PORT] for
 * both UDP and TCP DNS. The Xray settings' DNS transport
 * gains a "dnscrypt" choice whose resolver is this local
 * proxy, so encrypted DNS becomes one more transport next
 * to DoH / DoQ / DNS-over-TCP instead of a separate stack.
 * Readiness probes the TCP half of the listener.
 */
object DnsCryptCore : SubprocessCore(
    libName = "libdnscrypt.so",
    dirName = "dnscrypt",
    port = 20530,
    tcpProbe = true,
    label = "DNSCrypt proxy",
) {
    /** The fixed local resolver port (mirrored in Dart:
     *  dnsCryptListenPort in dnscrypt_config.dart). */
    const val PORT = 20530
}
