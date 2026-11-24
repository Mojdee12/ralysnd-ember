package com.ralysnd.ember

/**
 * The sing-box sidecar engine (build 2075): the protocol
 * workhorse for the profiles the vendored Xray core cannot
 * speak — TUIC v5, Snell, NaiveProxy (outbounds) and the
 * Tailscale / OpenConnect endpoints. Built from the pinned
 * upstream source in ~/workspace/ember-app/engines/singbox
 * (see PROVENANCE.md there) and staged in jniLibs as
 * libsingbox.so.
 *
 * Shape: sing-box runs ONE mixed (SOCKS+HTTP) inbound on
 * [PORT] and the profile's outbound/endpoint; the Xray
 * tunnel config's proxy outbound is a plain SOCKS outbound
 * aimed at that port, so the TUN, kill switch, routing,
 * stats and per-config accounting all stay Xray's — the
 * sidecar is a dialer, exactly like the DNSTT underlay's
 * role in the chain (build 2072). The Dart side writes the
 * generated config to filesDir/singbox/config.json and
 * passes `run -c <path>`; readiness is the mixed listener
 * accepting on [PORT].
 */
object SingBoxCore : SubprocessCore(
    libName = "libsingbox.so",
    dirName = "singbox",
    port = 20862,
    tcpProbe = true,
    label = "sing-box engine",
) {
    /** The fixed local mixed-inbound port (mirrored in
     *  Dart: singBoxListenPort in singbox_config.dart). */
    const val PORT = 20862
}
