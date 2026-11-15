package com.ralysnd.ember

/**
 * The DNSTT client (build 2072): David Fifield's dnstt-client,
 * built from the vendored source in ~/workspace/ember-app/
 * engines/dnstt (see BUILD-RECIPE.md there) and staged in
 * jniLibs as libdnstt.so.
 *
 * The client is a plain TCP port forward through a DNS tunnel
 * (like `ssh -L`) — it is NOT a SOCKS proxy. Ember runs it as
 * the V2Ray chain underlay: the Xray outbound is a SOCKS
 * outbound aimed at [PORT], and the SOCKS bytes traverse the
 * tunnel to the owner's server, where dnstt-server forwards
 * them to the SOCKS proxy its own upstream argument names.
 * The client's resolver traffic leaves the app UID, which the
 * VPN service excludes from the TUN (addDisallowedApplication),
 * so the tunnel never loops into itself.
 *
 * Command line (built on the Dart side, dnstt_args.dart):
 *   libdnstt.so (-doh URL | -dot ADDR | -udp ADDR)
 *       -pubkey HEX64 DOMAIN 127.0.0.1:20860
 * All of the client's diagnostics go to stderr (Go's log
 * package); the base class drains stdout/stderr separately.
 */
object DnsttCore : SubprocessCore(
    libName = "libdnstt.so",
    dirName = "dnstt",
    port = 20860,
    tcpProbe = true,
    label = "DNSTT client",
) {
    /** The fixed local listen port (mirrored in Dart:
     *  dnsttListenPort in dnstt_args.dart). */
    const val PORT = 20860
}
