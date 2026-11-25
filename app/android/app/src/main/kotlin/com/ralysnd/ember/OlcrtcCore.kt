package com.ralysnd.ember

/**
 * The OLCRTC client (build 2134): openlibrecommunity/olcrtc,
 * built from the pinned source in ~/workspace/ember-app/
 * engines/olcrtc (see PROVENANCE.md there) and staged in
 * jniLibs as libolcrtc.so. Build 2149 (audit A43-21): the
 * in-tree inventory of every vendored binary lives at
 * app/PROVENANCE.md in this source tree.
 *
 * The client carries TCP over WebRTC data/video channels
 * disguised as a video call on an SFU service (Jitsi,
 * Telemost, WBStream): both peers join the same room with
 * the same 64-hex key, and the tunnel rides the call.
 * Ember runs it as the V2Ray chain underlay: the client
 * exposes a real SOCKS5 listener on [PORT], and the Xray
 * outbound is a SOCKS outbound aimed at it. The client's
 * own traffic leaves the app UID, which the VPN service
 * excludes from the TUN (addDisallowedApplication), so the
 * call never loops into itself.
 *
 * Command line (the Dart side writes the YAML config —
 * olcrtc_args.dart — and passes its path):
 *   libolcrtc.so <filesDir>/olcrtc/config.yaml
 * The binary takes exactly one argument; there are no
 * flags. Its diagnostics go to stderr (Go's log package);
 * the base class drains stdout/stderr separately.
 *
 * Readiness differs from the other helpers: the client
 * opens its SOCKS listener only AFTER the WebRTC link to
 * the server peer is up (upstream client.go: bringUpLink
 * precedes Listen), so the listener accepting is real
 * link proof — but joining a room and finding the peer
 * can take well over the usual 20 s probe window, hence
 * the 120 s probe timeout.
 */
object OlcrtcCore : SubprocessCore(
    libName = "libolcrtc.so",
    dirName = "olcrtc",
    port = 20866,
    tcpProbe = true,
    label = "OLCRTC client",
    probeTimeoutMs = 120_000,
) {
    /** The fixed local listen port (mirrored in Dart:
     *  olcrtcListenPort in olcrtc_args.dart). */
    const val PORT = 20866
}
