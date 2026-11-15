/// The DNSTT client's command line (build 2072), built from
/// the Xray settings. Pure and testable; the native side
/// (DnsttCore.kt) only spawns what it is given.
///
/// dnstt-client (Fifield's dnstt, vendored in
/// ~/workspace/ember-app/engines/dnstt):
///   dnstt-client (-doh URL | -dot ADDR | -udp ADDR)
///       -pubkey HEX64 DOMAIN LISTENADDR
///
/// The client is a plain TCP port forward through a DNS
/// tunnel — NOT a SOCKS proxy. The tunnel's far end is fixed
/// by dnstt-server's own upstream argument on the server, so
/// the working deployment points the server at a SOCKS proxy
/// there; Ember's underlay outbound is a SOCKS outbound aimed
/// at the local listener, and the SOCKS bytes land on that
/// server-side proxy.

import 'xray_models.dart';

/// The fixed local listen port (mirrored in Kotlin:
/// DnsttCore.PORT).
const dnsttListenPort = 20860;

/// The fixed local listen address the client is spawned with.
const dnsttListenAddr = '127.0.0.1:$dnsttListenPort';

/// True when the DNSTT fields are complete enough to spawn:
/// a resolver, a tunnel domain, and a 64-hex-digit server
/// public key (the client's own requirement — it refuses to
/// start without one).
bool dnsttConfigured(XraySettings s) {
  if (s.dnsttResolver.trim().isEmpty) return false;
  if (s.dnsttDomain.trim().isEmpty) return false;
  return isDnsttPubkey(s.dnsttPubkey);
}

/// A dnstt server public key is 32 bytes as 64 hex digits.
bool isDnsttPubkey(String v) {
  final t = v.trim();
  if (t.length != 64) return false;
  return RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(t);
}

/// The client command line for the settings' resolver
/// transport: 'doh' (default), 'dot' or 'udp'.
List<String> buildDnsttArgs(XraySettings s) {
  final transport = switch (s.dnsttResolverType) {
    'dot' => '-dot',
    'udp' => '-udp',
    _ => '-doh',
  };
  return [
    transport,
    s.dnsttResolver.trim(),
    '-pubkey',
    s.dnsttPubkey.trim(),
    s.dnsttDomain.trim(),
    dnsttListenAddr,
  ];
}
