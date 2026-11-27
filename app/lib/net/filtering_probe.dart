/// The filtering probe (build 2065, item 6): read-only checks
/// that describe how THIS network treats traffic, in plain
/// verdicts. Nothing here changes any setting — the panel only
/// measures: UDP reachability, DNS poisoning (the system
/// resolver's answers vs a clean DoH answer for the same name),
/// SNI blocking (a TLS handshake carrying each built-in host's
/// own name), and IPv6 presence.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'probe.dart';

/// One check's outcome: a short verdict word plus the plain
/// detail line under it.
class ProbeCheck {
  final String name;
  final String verdict; // OK | Blocked | Different | Present | Absent | Inconclusive
  final String detail;
  const ProbeCheck(this.name, this.verdict, this.detail);
}

/// Hosts the SNI check tries, each with its own name as the SNI:
/// a filtered network typically kills the handshake for the
/// blocked ones while the control host answers.
const sniProbeHosts = <String>[
  'en.wikipedia.org',
  'www.instagram.com',
  'x.com',
  'www.youtube.com',
];

/// Fetches A records for [name] from Google's public DoH JSON
/// API. Returns null when the query itself fails (inconclusive,
/// never "poisoned").
Future<List<String>?> dohAnswers(String name) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 6);
  try {
    final req = await client.getUrl(
      Uri.parse('https://dns.google/resolve?name=$name&type=A'),
    );
    req.headers.set('accept', 'application/dns-json');
    final resp = await req.close().timeout(const Duration(seconds: 6));
    if (resp.statusCode != 200) return null;
    final body = await resp.transform(utf8.decoder).join();
    final j = jsonDecode(body);
    if (j is! Map<String, dynamic>) return null;
    final answers = j['Answer'];
    if (answers is! List) return const [];
    return [
      for (final a in answers)
        if (a is Map && a['data'] is String) a['data'] as String,
    ].where((d) => InternetAddress.tryParse(d) != null).toList();
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Runs every check and returns the verdicts in display order.
/// Bounded: each check carries its own timeout, and the SNI set
/// runs four at a time at most.
Future<List<ProbeCheck>> runFilteringProbe() async {
  final out = <ProbeCheck>[];

  // 1) UDP reachability: a plain DNS query over UDP/53.
  final udp = await udpDnsProbe('8.8.8.8', 'example.com');
  out.add(
    ProbeCheck(
      'UDP traffic',
      udp.ok ? 'OK' : 'Blocked',
      udp.ok
          ? 'A DNS query to 8.8.8.8 over UDP was answered in '
                '${udp.ms} ms.'
          : 'No answer to a UDP DNS query — UDP is filtered or '
                'dropped on this network, so UDP-based tunnels '
                'struggle here.',
    ),
  );

  // 2) DNS poisoning: system answers vs clean DoH answers.
  List<String> system = const [];
  try {
    system = (await InternetAddress.lookup(
      'www.google.com',
    ).timeout(const Duration(seconds: 5))).map((a) => a.address).toList();
  } catch (_) {}
  final clean = await dohAnswers('www.google.com');
  if (clean == null || system.isEmpty) {
    out.add(
      const ProbeCheck(
        'DNS answers',
        'Inconclusive',
        'One of the two lookups failed, so the answers cannot be '
            'compared on this network.',
      ),
    );
  } else {
    final overlap = system.toSet().intersection(clean.toSet());
    out.add(
      ProbeCheck(
        'DNS answers',
        overlap.isNotEmpty ? 'OK' : 'Different',
        overlap.isNotEmpty
            ? 'The system resolver and a clean DoH resolver agree '
                  'on www.google.com.'
            : 'The system resolver answers www.google.com with '
                  'addresses a clean resolver never returns '
                  '(${system.join(', ')}) — DNS is being '
                  'intercepted or poisoned here.',
      ),
    );
  }

  // 3) SNI blocking per built-in host.
  for (final host in sniProbeHosts) {
    final r = await tlsProbe(host, host);
    out.add(
      ProbeCheck(
        'SNI: $host',
        r.ok ? 'OK' : 'Blocked',
        r.ok
            ? 'A TLS handshake naming $host completed in ${r.ms} ms.'
            : 'The TLS handshake naming $host failed — the name '
                  'itself is likely filtered on this network.',
      ),
    );
  }

  // 4) IPv6 presence: an AAAA answer plus a non-loopback v6
  // address on some interface.
  var v6 = false;
  try {
    final ifs = await NetworkInterface.list(
      type: InternetAddressType.IPv6,
      includeLoopback: false,
    ).timeout(const Duration(seconds: 4));
    v6 = ifs.any((i) => i.addresses.isNotEmpty);
  } catch (_) {}
  out.add(
    ProbeCheck(
      'IPv6',
      v6 ? 'Present' : 'Absent',
      v6
          ? 'This device has a routable IPv6 address on this '
              'network.'
          : 'No routable IPv6 address on this network — IPv4 '
              'only, which is what the tunnels assume.',
    ),
  );
  return out;
}
