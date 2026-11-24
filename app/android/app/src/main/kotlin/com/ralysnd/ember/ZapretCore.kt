package com.ralysnd.ember

/**
 * The Zapret desync proxy (build 2127, H1): ciadpi —
 * ByeDPI (hufrea/ByeDPI) at the pinned commit in
 * engines/byedpi/ (see PROVENANCE.md there) — a
 * userspace SOCKS5 proxy that desyncs the first bytes
 * of each TCP stream with ordinary socket calls:
 * segment splits at SNI-relative positions, TLS record
 * splits, disorder, out-of-band bytes, and a fake
 * first segment sent with a dying TTL. No root, no
 * NFQUEUE, no raw sockets — the packet-level nfqws
 * techniques (bad-checksum fakes, sequence overlap,
 * RST injection, IP fragmentation, QUIC CRYPTO
 * splitting) stay root-bound on Android and are not
 * attempted anywhere in this app.
 *
 * It exists for the DPI Strategy Lab: a zap candidate's
 * probe and its connect both chain the Xray outbound
 * through this proxy on [PORT] (the `_chainThroughUnderlay`
 * shape, psiphon/dnstt precedent), so what the Lab
 * measures is exactly what a connect dials. Unlike the
 * config-file sidecars it takes its whole command line
 * as args — the Dart side builds them per candidate
 * (zapret_args.dart: loopback listen + the candidate's
 * desync flags; `-I` and `-Y` are never emitted).
 * Staged in jniLibs as libzapret.so.
 */
object ZapretCore : SubprocessCore(
    libName = "libzapret.so",
    dirName = "zapret",
    port = 20864,
    tcpProbe = true,
    label = "Zapret desync proxy",
) {
    /** The fixed local SOCKS listen port (mirrored in
     *  Dart: zapretListenPort in zapret_args.dart). */
    const val PORT = 20864
}
