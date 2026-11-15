/// Small real-network probes shared by the Psiphon CDN edge list,
/// the Cloudflare clean-IP scanner and the filtering diagnostics
/// (build 2065). Every probe is an actual TCP connect and, where a
/// name is involved, an actual TLS handshake with that SNI — apps
/// cannot send ICMP echo, so "ping" in this app always means a
/// TCP/TLS handshake latency, measured in milliseconds. A probe
/// that cannot complete reports failure honestly; nothing here
/// fabricates a number.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class ProbeResult {
  final bool ok;

  /// Round-trip latency of the probe, when [ok].
  final int? ms;

  /// The address the probe actually reached (after DNS resolution
  /// of a hostname input), when known.
  final String? ip;

  const ProbeResult(this.ok, this.ms, [this.ip]);

  static const failed = ProbeResult(false, null);
}

/// True when [address] is already an IP literal (v4 or v6).
bool isIpLiteral(String address) =>
    InternetAddress.tryParse(address) != null;

/// Resolves [address] to its first IP (or returns it unchanged when
/// it already is one). Null when resolution fails.
Future<String?> resolveFirstIp(String address) async {
  if (isIpLiteral(address)) return address;
  try {
    final found = await InternetAddress.lookup(address)
        .timeout(const Duration(seconds: 4));
    if (found.isEmpty) return null;
    return found.first.address;
  } catch (_) {
    return null;
  }
}

/// All IPs [address] resolves to (for DNS-neighbour candidates).
Future<List<String>> resolveAllIps(String address) async {
  if (isIpLiteral(address)) return [address];
  try {
    final found = await InternetAddress.lookup(address)
        .timeout(const Duration(seconds: 4));
    return found.map((a) => a.address).toList();
  } catch (_) {
    return const [];
  }
}

/// TCP connect + TLS handshake with [sni] against [address]:443.
/// The latency covers connect + handshake: the honest "ping" an app
/// can measure on a candidate fronting edge.
Future<ProbeResult> tlsProbe(
  String address,
  String sni, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final ip = await resolveFirstIp(address);
  if (ip == null) return ProbeResult.failed;
  final sw = Stopwatch()..start();
  Socket? raw;
  SecureSocket? tls;
  try {
    raw = await Socket.connect(ip, 443, timeout: timeout);
    tls = await SecureSocket.secure(
      raw,
      host: sni.isEmpty ? address : sni,
    ).timeout(timeout);
    await tls.first.timeout(timeout);
    sw.stop();
    return ProbeResult(true, sw.elapsedMilliseconds, ip);
  } catch (_) {
    return ProbeResult(false, null, ip);
  } finally {
    try {
      await tls?.close();
    } catch (_) {}
    try {
      raw?.destroy();
    } catch (_) {}
  }
}

/// A bare TCP connect latency to [address]:[port].
Future<ProbeResult> tcpProbe(
  String address,
  int port, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final ip = await resolveFirstIp(address);
  if (ip == null) return ProbeResult.failed;
  final sw = Stopwatch()..start();
  Socket? raw;
  try {
    raw = await Socket.connect(ip, port, timeout: timeout);
    sw.stop();
    return ProbeResult(true, sw.elapsedMilliseconds, ip);
  } catch (_) {
    return ProbeResult(false, null, ip);
  } finally {
    try {
      raw?.destroy();
    } catch (_) {}
  }
}

/// Builds a minimal DNS A-query packet for [domain] (one question,
/// recursion desired). Pure and unit-testable.
Uint8List buildDnsQuery(String domain, int id) {
  final labels = domain.split('.').where((l) => l.isNotEmpty).toList();
  var qnameLen = 1;
  for (final l in labels) {
    qnameLen += 1 + l.length;
  }
  final out = Uint8List(12 + qnameLen + 4);
  final bd = ByteData.sublistView(out);
  bd.setUint16(0, id & 0xffff);
  bd.setUint16(2, 0x0100); // RD
  bd.setUint16(4, 1); // QDCOUNT
  var p = 12;
  for (final l in labels) {
    out[p++] = l.length;
    out.setRange(p, p + l.length, l.codeUnits);
    p += l.length;
  }
  out[p++] = 0;
  bd.setUint16(p, 1); // A
  bd.setUint16(p + 2, 1); // IN
  return out;
}

/// Parses the first A answer out of a DNS response packet; null
/// when the packet carries none (or is not a response at all).
String? parseFirstAAnswer(Uint8List packet) {
  if (packet.length < 12) return null;
  final bd = ByteData.sublistView(packet);
  final qd = bd.getUint16(4);
  final an = bd.getUint16(6);
  if (an == 0) return null;
  var p = 12;
  int skipName() {
    var i = p;
    while (i < packet.length) {
      final len = packet[i];
      if (len == 0) return i + 1;
      if (len & 0xc0 == 0xc0) return i + 2;
      i += 1 + len;
    }
    return i;
  }

  for (var q = 0; q < qd; q++) {
    p = skipName();
    p += 4;
  }
  for (var a = 0; a < an; a++) {
    p = skipName();
    if (p + 10 > packet.length) return null;
    final type = bd.getUint16(p);
    final rdlen = bd.getUint16(p + 8);
    p += 10;
    if (type == 1 && rdlen == 4 && p + 4 <= packet.length) {
      return '${packet[p]}.${packet[p + 1]}.${packet[p + 2]}.${packet[p + 3]}';
    }
    p += rdlen;
  }
  return null;
}

/// Sends one real DNS A query for [domain] to [server]:53 over UDP
/// and waits briefly for the answer. Used by the filtering probe:
/// a resolver that never answers (or answers with a bogon) is
/// visible exactly here.
Future<ProbeResult> udpDnsProbe(
  String server,
  String domain, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final sw = Stopwatch()..start();
  RawDatagramSocket? sock;
  try {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final id = Random().nextInt(0xffff);
    final query = buildDnsQuery(domain, id);
    sock.send(query, InternetAddress(server), 53);
    await for (final event in sock.timeout(timeout)) {
      if (event == RawSocketEvent.read) {
        final dg = sock.receive();
        if (dg == null) continue;
        final ip = parseFirstAAnswer(dg.data);
        sw.stop();
        if (ip != null) return ProbeResult(true, sw.elapsedMilliseconds, ip);
        return ProbeResult(false, null, null);
      }
    }
    return ProbeResult.failed;
  } catch (_) {
    return ProbeResult.failed;
  } finally {
    sock?.close();
  }
}
