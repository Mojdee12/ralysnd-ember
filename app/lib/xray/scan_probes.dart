/// The cheap stages of the Test All funnel (build 2026, Stage A
/// of the MLM port): before Ember spins up a throwaway Xray core
/// per profile — the expensive, battery-hungry test — a profile
/// first has to answer two cheap questions, the same order MLM's
/// QuickScanner measures in:
///
/// 1. a plain TCP connect to the profile's endpoint (3 s), and
/// 2. for TLS profiles, a TLS handshake carrying the profile's
///    own SNI — a filtered SNI is reset here, before any core is
///    started (MLM's `tlsAnswers` pre-check).
///
/// Only survivors (plus the fall-throughs below) reach stage 3,
/// the real proxied-request test, and the final ranking is by
/// that real test alone.
///
/// Two deliberate deviations from a strict funnel, both about
/// not lying to the user:
///
/// - WireGuard and Hysteria2 are UDP-only: a TCP probe says
///   nothing about them, so they skip both cheap stages and go
///   straight to the real test.
/// - A profile whose ADDRESS IS A DOMAIN that fails stage 1 is
///   NOT failed outright: the probe resolves through the system
///   resolver, which on a filtered network is exactly the
///   poisoned one (the 2024 Problem-1 lesson), so its verdict is
///   untrustworthy. Such profiles fall through to the real test,
///   last in the feed. An IP-literal address has no resolver in
///   the path, so its stage-1 verdict stands. A stage-2 failure
///   always stands: the handshake the probe attempts is the same
///   one the core would attempt, SNI included.

import 'dart:async';
import 'dart:io';

import 'xray_models.dart';

/// The probe budget MLM's funnel uses; a filtered endpoint
/// either answers fast or not at all.
const funnelProbeTimeout = Duration(seconds: 3);

/// True when [address] is an IP literal (v4 or v6), i.e. no DNS
/// resolution stands between the probe and the endpoint.
bool isIpLiteralAddress(String address) =>
    address.contains(':') ||
    RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(address);

/// Protocols whose transport is UDP-only: stages 1–2 do not
/// apply to them.
bool funnelSkipsCheapStages(Profile p) =>
    p.protocol == Protocol.wireguard ||
    p.protocol == Protocol.hysteria2 ||
    // Build 2075: TUIC is UDP-only like Hysteria2, and the
    // endpoint protocols have no plain TCP endpoint to probe
    // (Tailscale has no server at all) — their real test runs
    // through the sidecar instead.
    p.protocol == Protocol.tuic ||
    p.protocol == Protocol.tailscale ||
    p.protocol == Protocol.openconnect;

/// Stage 1: a plain TCP connect to [host]:[port]. The connect
/// time in ms, or -1 when the endpoint does not answer inside
/// [timeout]. [host] may be a domain (system resolution) or an
/// IP literal.
Future<int> tcpProbe(
  String host,
  int port, {
  Duration timeout = funnelProbeTimeout,
}) async {
  final sw = Stopwatch()..start();
  Socket? socket;
  try {
    socket = await Socket.connect(host, port, timeout: timeout);
    return sw.elapsedMilliseconds;
  } catch (_) {
    return -1;
  } finally {
    socket?.destroy();
  }
}

/// Stage 2: a TLS handshake to [host]:[port] presenting
/// [serverName] as the SNI. True when the handshake completes
/// (any certificate is accepted — this measures reachability of
/// the handshake, not trust; the core does its own verification
/// with the profile's settings). False on reset/timeout/error.
Future<bool> tlsSniAnswers(
  String host,
  int port,
  String serverName, {
  Duration timeout = funnelProbeTimeout,
}) async {
  Socket? raw;
  try {
    raw = await Socket.connect(host, port, timeout: timeout);
    final secure = await SecureSocket.secure(
      raw,
      host: serverName,
      onBadCertificate: (_) => true,
    ).timeout(timeout);
    secure.destroy();
    return true;
  } catch (_) {
    raw?.destroy();
    return false;
  }
}

/// The SNI the core will present for [p]: the explicit SNI, else
/// the transport Host, else the address itself.
String funnelSniOf(Profile p) {
  if (p.sni.isNotEmpty) return p.sni;
  if (p.host.isNotEmpty) return p.host.split(',').first.trim();
  return p.address;
}

/// The stage-3 feed order: stage-1/2 survivors by ascending
/// stage-1 TCP time (fastest first — MLM connects its first
/// good answer early), then the UDP-only profiles in list
/// order, then the domain fall-throughs in list order. Pure, so
/// the ordering is unit-testable without sockets.
List<Profile> funnelStage3Order({
  required List<Profile> survivors,
  required Map<String, int> tcpMs,
  required List<Profile> realtime,
  required List<Profile> fallThrough,
}) {
  final ranked = List.of(
    survivors,
  )..sort((a, b) => (tcpMs[a.id] ?? 1 << 30).compareTo(tcpMs[b.id] ?? 1 << 30));
  return [...ranked, ...realtime, ...fallThrough];
}
