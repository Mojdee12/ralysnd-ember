/// Build 2147 (Iran features) — the pure decision logic for
/// the feature set, kept side-effect-free so every rule is
/// unit-testable without a controller: default subscriptions
/// (#21b), unsupported-scheme detection (#18/#21b), the MTU
/// black-hole walk (#2), the typed FinalMask shapes (#7/#8),
/// WireGuard fallback candidates (#10), import-safety
/// warnings (#18), quarantine strike accounting (#20/#21a),
/// the SNI scan list + ranking (#4) and the guided-diagnosis
/// remedy map (#16). The wiring (settings gates, controller,
/// UI) lives elsewhere; every gate is DEFAULT OFF in
/// [XraySettings], so none of this runs for a store that
/// never opts in.
library;

import 'dart:convert';

import 'xray_models.dart';

// ---------------------------------------------------------------- #21b

/// The built-in default subscriptions (owner order
/// 2026-11-24, both URLs verbatim): seeded once on first run
/// into the V2Ray tab, riding the existing subscription
/// auto-update machinery with auto-update ENABLED, removable
/// like any other subscription. Source #2 carries junk
/// localhost entries and unsupported-scheme links by design —
/// the ping sweep (#21a) + quarantine clear the dead ones and
/// the import path flags the unsupported schemes; there is
/// deliberately NO per-source special-case code.
const List<({String name, String url})> kDefaultSubscriptions2147 = [
  (name: 'Default source 1', url: 'https://sub.darkpx.workers.dev/all'),
  (name: 'Default source 2', url: 'https://www.ermao.net/sub/v2ray/ermao.net'),
];

// ---------------------------------------------------------------- #18

/// Link schemes some engine in the app can parse and serve
/// (mirrors link_parser's dispatch — the parser stays the
/// authority; this set exists so import surfaces can NAME
/// what was skipped and why).
const Set<String> kSupportedLinkSchemes = {
  'vless',
  'vmess',
  'trojan',
  'ss',
  'hysteria2',
  'hy2',
  'wireguard',
  'wg',
  'tuic',
  'naive+https',
  'naive',
  'snell',
  'mieru',
  'tailscale',
  'openconnect',
  'sudoku',
  'anytls',
  'socks',
  'socks5',
  'http',
  'https',
  'ssh',
};

/// The scheme of a share link, lower-cased, or null when the
/// line carries no `scheme://` prefix at all (a remark, a
/// Clash fragment, base64 debris — not a link).
String? linkSchemeOf(String line) {
  final m = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*)://').firstMatch(line.trim());
  return m?.group(1)?.toLowerCase();
}

/// True when [line] is a share link whose scheme NO engine
/// in the app serves — the #18/#21b skip-and-flag class
/// (e.g. hysteria v1, brook, juicity). Lines that are not
/// links at all return false (they are debris, not schemes).
bool isUnsupportedSchemeLink(String line) {
  final scheme = linkSchemeOf(line);
  return scheme != null && !kSupportedLinkSchemes.contains(scheme);
}

/// The distinct unsupported schemes present in a
/// subscription body (build 2147 #18/#21b refresh-side
/// flagging): scans the body's lines and, when the body is a
/// base64 blob (the common subscription form), its decoded
/// text as well. Pure string work; the parser stays the
/// authority on what actually imported.
List<String> unsupportedSchemesInBody(String body) {
  final found = <String>{};
  void scan(String text) {
    for (final line in text.split(RegExp(r'[\r\n]'))) {
      if (isUnsupportedSchemeLink(line)) {
        found.add(linkSchemeOf(line)!);
      }
    }
  }

  scan(body);
  if (found.isEmpty && !body.contains('://')) {
    try {
      var b64 = body.trim().replaceAll(RegExp(r'\s'), '');
      b64 = b64.replaceAll('-', '+').replaceAll('_', '/');
      while (b64.length % 4 != 0) {
        b64 += '=';
      }
      scan(utf8.decode(base64.decode(b64)));
    } catch (_) {
      // Not a base64 body — the plain scan above stands.
    }
  }
  return found.toList()..sort();
}

// ---------------------------------------------------------------- #2

/// The PMTU black-hole walk's candidate sizes, descending:
/// the classic ladder from the design (1500 → 1280).
const List<int> kMtuWalkCandidates = [1500, 1472, 1400, 1380, 1280];

/// The walk's verdict from per-size answer flags (same order
/// as [kMtuWalkCandidates]): the FIRST size that answered
/// wins; when nothing answered, null (the manual value
/// rules, as with the gate off).
int? pickMtuFromWalk(List<bool> answered) {
  for (var i = 0; i < kMtuWalkCandidates.length; i++) {
    if (i < answered.length && answered[i]) return kMtuWalkCandidates[i];
  }
  return null;
}

// ---------------------------------------------------------------- #7/#8

/// The typed XDNS finalmask entry for [p] (build 2147 #7),
/// or null when the profile carries no XDNS domain. Schema
/// pinned from the vendored Xray source
/// (infra/conf/transport_finalmask.go) + the XTLS FinalMask
/// docs: a UDP mask, mKCP-carried profiles only (the caller
/// checks the network).
Map<String, dynamic>? xdnsFinalMask(Profile p) {
  final domain = p.xdnsDomain.trim();
  if (domain.isEmpty) return null;
  final resolver = p.xdnsResolver.trim().isEmpty
      ? 'udp://8.8.8.8:53'
      : p.xdnsResolver.trim();
  return {
    'type': 'xdns',
    'settings': {
      'domains': [
        {
          'names': [domain],
          'lenLimit': 255,
          'labelLimit': 63,
          'types': [16],
          'edns0': 0,
        },
      ],
      'resolvers': [
        {
          'addrs': [resolver],
        },
      ],
      'extraPoll': 0,
    },
  };
}

/// The typed XICMP finalmask entry for [p] (build 2147 #8),
/// or null when the profile has not opted in. Schema pinned
/// from the same sources: `{dgram, ips}` with plain IPs.
Map<String, dynamic>? xicmpFinalMask(Profile p) {
  if (!p.xicmpEnabled) return null;
  return {
    'type': 'xicmp',
    'settings': {'dgram': p.xicmpDgram, 'ips': [p.address]},
  };
}

// ---------------------------------------------------------------- #10

/// One parsed fallback endpoint from a profile's
/// comma-separated [Profile.wgFallbackEndpoints] list.
typedef WgEndpoint = ({String host, int port});

/// Parses the fallback list; malformed entries are skipped,
/// never fatal (the editor validates before save, the
/// connect path tolerates a corrupt store).
List<WgEndpoint> parseWgFallbackEndpoints(String raw) {
  final out = <WgEndpoint>[];
  for (final part in raw.split(',')) {
    final e = part.trim();
    if (e.isEmpty) continue;
    final cut = e.lastIndexOf(':');
    if (cut <= 0 || cut == e.length - 1) continue;
    final port = int.tryParse(e.substring(cut + 1));
    if (port == null || port <= 0 || port > 65535) continue;
    out.add((host: e.substring(0, cut), port: port));
  }
  return out;
}

/// The connect-walk candidates for a WireGuard profile: the
/// profile itself first, then one copy per fallback endpoint
/// with the endpoint rewritten (build 2147 #10). With an
/// empty fallback list this is exactly `[p]` — today's
/// behaviour.
List<Profile> wgConnectCandidates(Profile p) {
  final out = <Profile>[p];
  for (final e in parseWgFallbackEndpoints(p.wgFallbackEndpoints)) {
    final copy = p.copy();
    copy.address = e.host;
    copy.port = e.port;
    out.add(copy);
  }
  return out;
}

// ---------------------------------------------------------------- #18

/// True when [host] is a loopback, RFC1918, link-local or
/// unspecified address (name or literal) — an endpoint that
/// cannot be a public server, the import-safety flag class.
/// Hostnames are matched on the obvious local names only;
/// no DNS is consulted at import.
bool isLocalEndpoint(String host) {
  final h = host.trim().toLowerCase();
  if (h.isEmpty) return false;
  if (h == 'localhost' || h.endsWith('.local') || h.endsWith('.lan')) {
    return true;
  }
  final ip = _ipv4Parts(h);
  if (ip == null) return h == '::1' || h.startsWith('fe80:');
  if (ip[0] == 127 || ip[0] == 10 || ip[0] == 0) return true;
  if (ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31) return true;
  if (ip[0] == 192 && ip[1] == 168) return true;
  if (ip[0] == 169 && ip[1] == 254) return true;
  if (ip[0] == 100 && ip[1] >= 64 && ip[1] <= 127) return true; // CGNAT
  return false;
}

List<int>? _ipv4Parts(String h) {
  final parts = h.split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final part in parts) {
    final v = int.tryParse(part);
    if (v == null || v < 0 || v > 255) return null;
    out.add(v);
  }
  return out;
}

/// Hosts widely used as DNS-carriage / captive traps in the
/// owner's threat model: a config pointing AT a public DNS
/// resolver's bare IP is the known carriage shape (the
/// resolver is the transport, not a proxy server).
const Set<String> kDnsCarriageTrapHosts = {
  '8.8.8.8',
  '8.8.4.4',
  '1.1.1.1',
  '1.0.0.1',
  '9.9.9.9',
  '208.67.222.222',
  '208.67.220.220',
};

/// The import-safety warnings for one parsed profile
/// (build 2147 #18 — warn, never block): local endpoint,
/// DNS-carriage trap endpoint. Empty list = nothing to say.
List<String> importSafetyWarnings(Profile p) {
  final out = <String>[];
  if (isLocalEndpoint(p.address)) {
    out.add(
      '${p.name}: endpoint ${p.address} is a local/private '
      'address — it cannot be a public server.',
    );
  } else if (kDnsCarriageTrapHosts.contains(p.address.trim())) {
    out.add(
      '${p.name}: endpoint ${p.address} is a public DNS '
      'resolver address — a known DNS-carriage trap shape.',
    );
  }
  return out;
}

/// Link-payload warnings for one raw link (build 2147 #18):
/// query parameters outside the protocol's known set often
/// carry HWID / tracking payloads from panel generators.
/// Conservative: only the known tracker-shaped keys are
/// named.
List<String> linkPayloadWarnings(String link) {
  final out = <String>[];
  final q = link.indexOf('?');
  if (q < 0) return out;
  var query = link.substring(q + 1);
  final hash = query.indexOf('#');
  if (hash >= 0) query = query.substring(0, hash);
  const trackerKeys = {'hwid', 'deviceid', 'device_id', 'imei', 'idfa', 'gaid'};
  for (final pair in query.split('&')) {
    final key = pair.split('=').first.trim().toLowerCase();
    if (trackerKeys.contains(key)) {
      out.add(
        'A link carries a "$key" parameter — a device '
        'identifier payload; it was not imported into any field.',
      );
      break;
    }
  }
  return out;
}

// ---------------------------------------------------------------- #20/#21a

/// The quarantine strike accounting (build 2147 #20 + #21a):
/// a failure on a NEW network restarts the count at 1 (the
/// strikes are per-network by design); a failure on the SAME
/// network increments. Returns the new (strikes, network).
({int strikes, String network}) nextQuarantineStrikes(
  Profile p,
  String network,
) {
  if (p.quarantineNetwork != network) return (strikes: 1, network: network);
  return (strikes: p.quarantineStrikes + 1, network: network);
}

/// Whether [p] should be auto-cut by the ping sweep: it did
/// not answer the latest sweep AND its consecutive-sweep
/// strike count reached [threshold] (settings, default 3).
bool sweepShouldCut({
  required int consecutiveMisses,
  required int threshold,
}) => consecutiveMisses >= (threshold < 1 ? 1 : threshold);

// ---------------------------------------------------------------- #4

/// The built-in plausible-front SNI list for the whitelist
/// scan (build 2147 #4): major CDN / cloud / platform hosts
/// a carrier whitelist is most likely to pass. The scan
/// probes each with a real TLS handshake and ranks the
/// passers; the list is data, not a promise.
const List<String> kSniScanHosts = [
  'www.google.com',
  'www.microsoft.com',
  'www.apple.com',
  'www.amazon.com',
  'www.cloudflare.com',
  'www.facebook.com',
  'www.instagram.com',
  'www.wikipedia.org',
  'www.github.com',
  'www.bing.com',
  'www.yahoo.com',
  'dl.google.com',
  'fonts.gstatic.com',
  'ajax.googleapis.com',
  'storage.googleapis.com',
  'www.youtube.com',
  'i.ytimg.com',
  'www.amazonaws.com',
  's3.amazonaws.com',
  'azure.microsoft.com',
  'cdn.jsdelivr.net',
  'unpkg.com',
  'www.dropbox.com',
  'www.netflix.com',
  'www.twitch.tv',
  'www.reddit.com',
  'www.linkedin.com',
  'www.adobe.com',
  'www.mozilla.org',
  'download.mozilla.org',
];

/// One SNI scan result.
typedef SniScanResult = ({
  String host,
  bool handshakeOk,
  int firstByteMs,
  String note,
});

/// Ranks scan results: passers first, by first-byte time;
/// failures keep their scan order at the tail.
List<SniScanResult> rankSniResults(List<SniScanResult> results) {
  final pass = results.where((r) => r.handshakeOk).toList()
    ..sort((a, b) => a.firstByteMs.compareTo(b.firstByteMs));
  final fail = results.where((r) => !r.handshakeOk).toList();
  return [...pass, ...fail];
}

// ---------------------------------------------------------------- #16

/// One rung of the guided-diagnosis ladder (build 2147 #16).
typedef DiagnosisRung = ({
  String step,
  bool ok,
  String finding,
  String remedy,
});

/// Maps a failed rung to its remedy — the known Iranian
/// carrier signatures and the feature that answers each.
/// Pure data; the page runs the probes and reads this map.
String diagnosisRemedyFor(String rungId) => switch (rungId) {
  'dns' =>
    'DNS does not resolve — try the managed DNS-over-TCP / '
        'DNSCrypt shapes in Settings, or the DPI Lab.',
  'tcp' =>
    'TCP never connects — the endpoint is unreachable or '
        'reset; try another config, or the SNI scan for a '
        'whitelisted front.',
  'tls' =>
    'TLS is reset mid-handshake — the classic SNI filter '
        'signature; run the DPI Lab or enable a scanned SNI front.',
  'firstByte' =>
    'Handshake answers, then freezes — the carrier '
        'handshake-then-freeze signature; run the DPI Lab and '
        'try its winning shape, or lower the tunnel MTU.',
  'bulk' =>
    'Small requests pass but bulk stalls — likely MTU '
        'black-holing; enable Auto MTU discovery or set 1400/1280.',
  _ => 'No specific signature matched — see the session journal.',
};

// ---------------------------------------------------------------- #19

/// The encrypted diagnostics export envelope (build 2147
/// #19): a small JSON wrapper so a future build can refuse
/// foreign files cleanly. The crypto itself lives with the
/// export code (pointycastle AES-GCM + PBKDF2).
const String kDiagExportMagic = 'EMBERDIAG1';

String diagExportEnvelope({
  required String saltB64,
  required String nonceB64,
  required String cipherB64,
}) => jsonEncode({
  'magic': kDiagExportMagic,
  'kdf': 'PBKDF2-HMAC-SHA256',
  'iterations': kDiagKdfIterations,
  'salt': saltB64,
  'nonce': nonceB64,
  'cipher': cipherB64,
});

/// PBKDF2 iteration count for the export key derivation.
const int kDiagKdfIterations = 120000;

/// Parses an envelope produced by [diagExportEnvelope];
/// null when the text is not one.
({String saltB64, String nonceB64, String cipherB64})? parseDiagEnvelope(
  String text,
) {
  try {
    final j = jsonDecode(text);
    if (j is! Map || j['magic'] != kDiagExportMagic) return null;
    return (
      saltB64: j['salt'] as String,
      nonceB64: j['nonce'] as String,
      cipherB64: j['cipher'] as String,
    );
  } catch (_) {
    return null;
  }
}
