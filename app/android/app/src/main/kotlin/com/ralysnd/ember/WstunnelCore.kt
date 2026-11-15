package com.ralysnd.ember

/**
 * The wstunnel client (build 2072): the official erebe/wstunnel
 * v11.1.0 android_arm64 binary, vendored with its release
 * checksum in ~/workspace/ember-app/engines/wstunnel (see
 * PROVENANCE.md there) and staged in jniLibs as libwstunnel.so.
 *
 * It carries WireGuard over WebSocket: the client listens on
 * [PORT] for UDP, and each datagram rides the WebSocket to the
 * wstunnel server, which dials the real WireGuard endpoint
 * (the -L target is dialed by the SERVER, so hostname endpoints
 * work unchanged). Ember points the WG profile's peer endpoint
 * at 127.0.0.1:[PORT] in the built config while a session runs
 * through it.
 *
 * Command line (built on the Dart side, wstunnel_args.dart):
 *   libwstunnel.so client
 *       -L udp://127.0.0.1:20861:<wg-host>:<wg-port>?timeout_sec=0
 *       wss://…
 * timeout_sec=0 disables the default 30 s UDP idle timeout —
 * WireGuard keepalive gaps exceed it (the upstream README's
 * own WireGuard example uses it). Readiness is a liveness
 * window: a UDP forwarder has no handshake to probe, and the
 * WireGuard handshake above it is the end-to-end proof (the
 * same doctrine as WG peer fallback).
 */
object WstunnelCore : SubprocessCore(
    libName = "libwstunnel.so",
    dirName = "wstunnel",
    port = 20861,
    tcpProbe = false,
    label = "wstunnel client",
) {
    /** The fixed local UDP forward port (mirrored in Dart:
     *  wstunnelListenPort in wstunnel_args.dart). */
    const val PORT = 20861
}
