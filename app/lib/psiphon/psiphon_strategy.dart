/// The Psiphon strategy model (build 2065): the connection-method
/// ladder, the ping-tested CDN edge list, and the Conduit pairing
/// parser. Pure data + pure functions, so every ranking and parsing
/// rule is unit-tested without a device.
///
/// The ladder mirrors ralysnd's PsiphonMethods (which the owner
/// runs daily): A fronted, E clean-IP, D direct, C conduit
/// (in-proxy through other users), P personal conduit (a friend's
/// paired station), X upstream proxy. P never joins the automatic
/// ladder — a personal station is used only when picked.

import 'dart:convert';
import 'dart:io';

/// Ladder rung letters, in ralysnd's automatic order.
const psiphonAutoLadder = <String>['A', 'E', 'D', 'C'];

/// Every method the UI offers ('' in settings means Auto).
const psiphonMethods = <String, String>{
  '': 'Auto (ladder)',
  'A': 'CDN fronting',
  'E': 'Clean IP',
  'D': 'Direct (all protocols)',
  'C': 'Conduit (via other users)',
  'P': 'Personal Conduit',
  'X': 'Proxy server',
};

String psiphonMethodName(String method) =>
    psiphonMethods[method] ?? method;

/// The rung order for one connect: a pinned method runs alone;
/// Auto runs the ladder with unavailable rungs dropped (E needs
/// tested edges, P needs a pairing, X needs an upstream) and the
/// remembered winner for this network moved first.
///
/// [bridgeMode] (build 2075, feature item 10) governs the
/// fronted "bridge" rungs (A CDN fronting, E clean IP):
/// 'auto' = today's ladder; 'on' = bridges only (the plain
/// direct rung D never runs — every attempt goes through a
/// fronted or relayed path, C Conduit included); 'off' = no
/// bridges (A and E never run; direct and relayed paths do).
/// A pinned method ignores the policy — an explicit pick is
/// explicit.
List<String> psiphonRungOrder({
  required String method,
  required String lastWinner,
  required bool hasEdges,
  required bool hasPairing,
  required bool hasUpstream,
  String bridgeMode = 'auto',
}) {
  bool available(String rung) {
    switch (rung) {
      case 'E':
        return hasEdges;
      case 'P':
        return hasPairing;
      case 'X':
        return hasUpstream;
      default:
        return true;
    }
  }

  if (method.isNotEmpty) {
    return available(method) ? [method] : const [];
  }
  var order = psiphonAutoLadder.where(available).toList();
  if (bridgeMode == 'on') {
    order = order.where((r) => r != 'D').toList();
  } else if (bridgeMode == 'off') {
    order = order.where((r) => r != 'A' && r != 'E').toList();
  }
  if (order.isEmpty) order = psiphonAutoLadder.where(available).toList();
  if (lastWinner.isNotEmpty && order.contains(lastWinner)) {
    order.remove(lastWinner);
    order.insert(0, lastWinner);
  }
  return order;
}

/// One CDN edge candidate for Psiphon fronting: an address (IP or
/// hostname) plus the SNI to present to it, tagged with the
/// fronting provider its preresolved CIDRs belong to.
class CdnEdge {
  String address;
  String sni;
  String provider; // 'akamai' | 'fastly' | 'custom'
  bool builtin;

  /// Last TCP/TLS probe result: latency ms when reachable.
  int? lastMs;
  bool lastOk;
  int lastTestAtMs;

  /// The IP the last successful probe actually reached (a hostname
  /// entry resolves to this; preresolved CIDRs need the IP itself).
  String? testedIp;

  CdnEdge({
    required this.address,
    required this.sni,
    required this.provider,
    this.builtin = false,
    this.lastMs,
    this.lastOk = false,
    this.lastTestAtMs = 0,
    this.testedIp,
  });

  String get id => '$address|$sni';

  Map<String, dynamic> toJson() => {
        'address': address,
        'sni': sni,
        'provider': provider,
        'builtin': builtin,
        'lastMs': lastMs,
        'lastOk': lastOk,
        'lastTestAtMs': lastTestAtMs,
        'testedIp': testedIp,
      };

  // Build 2066 (device-state gate): field-defensive like
  // PsiphonSettings.fromJson — a wrong-typed value degrades that
  // field instead of throwing (an entry with no usable address
  // is dropped by the caller's isNotEmpty filter).
  static CdnEdge fromJson(Map<String, dynamic> j) => CdnEdge(
        address: j['address'] is String ? j['address'] as String : '',
        sni: j['sni'] is String ? j['sni'] as String : '',
        provider:
            j['provider'] is String ? j['provider'] as String : 'custom',
        builtin: j['builtin'] is bool ? j['builtin'] as bool : false,
        lastMs: j['lastMs'] is num ? (j['lastMs'] as num).toInt() : null,
        lastOk: j['lastOk'] is bool ? j['lastOk'] as bool : false,
        lastTestAtMs:
            j['lastTestAtMs'] is num ? (j['lastTestAtMs'] as num).toInt() : 0,
        testedIp: j['testedIp'] is String ? j['testedIp'] as String : null,
      );
}

/// The built-in edge candidates: Shir o Khorshid's baked-in Akamai
/// edge IPs (their CDN override set) with an Akamai SNI, and the
/// Fastly front hostnames from ralysnd's PsiphonCleanIps plus
/// pypi.org (Shir's Fastly dial target). User entries extend this
/// list; DNS-derived neighbours join at test time, not in storage.
List<CdnEdge> builtinCdnEdges() {
  const akamaiIps = [
    '23.215.0.206',
    '23.215.0.203',
    '23.212.250.91',
    '23.212.250.78',
    '23.12.147.13',
    '23.12.147.29',
    '23.73.207.8',
    '23.73.207.15',
    '92.123.102.43',
  ];
  return [
    for (final ip in akamaiIps)
      CdnEdge(
        address: ip,
        sni: 'a1014.dscg.akamai.net',
        provider: 'akamai',
        builtin: true,
      ),
    CdnEdge(
      address: 'j.sni.global.fastly.net',
      sni: 'j.sni.global.fastly.net',
      provider: 'fastly',
      builtin: true,
    ),
    CdnEdge(
      address: 'k.sni.global.fastly.net',
      sni: 'k.sni.global.fastly.net',
      provider: 'fastly',
      builtin: true,
    ),
    CdnEdge(
      address: 'l.sni.global.fastly.net',
      sni: 'l.sni.global.fastly.net',
      provider: 'fastly',
      builtin: true,
    ),
    CdnEdge(
      address: 'm.sni.global.fastly.net',
      sni: 'm.sni.global.fastly.net',
      provider: 'fastly',
      builtin: true,
    ),
    CdnEdge(address: 'pypi.org', sni: 'pypi.org', provider: 'fastly', builtin: true),
  ];
}

/// Sort order for display and for feeding the core: reachable
/// edges first, fastest first; untested next; failed last. The
/// input order breaks ties (stable for equal keys in practice —
/// Dart's sort is not stable, so the index is the final key).
List<CdnEdge> rankCdnEdges(List<CdnEdge> edges) {
  final indexed = edges.asMap().entries.toList();
  int key(CdnEdge e) {
    if (e.lastOk && e.lastMs != null) return 0;
    if (e.lastTestAtMs == 0) return 1;
    return 2;
  }

  indexed.sort((a, b) {
    final ka = key(a.value), kb = key(b.value);
    if (ka != kb) return ka - kb;
    if (ka == 0) {
      final d = (a.value.lastMs ?? 1 << 30) - (b.value.lastMs ?? 1 << 30);
      if (d != 0) return d;
    }
    return a.key - b.key;
  });
  return indexed.map((e) => e.value).toList();
}

/// The edges the core should use right now, per provider: the
/// pinned edge alone when the user pinned one and automatic use is
/// off; otherwise the fastest [perProvider] reachable edges from
/// the last test (built-ins first when nothing was ever tested —
/// the connect path refreshes stale results before dialing).
({List<String> akamai, List<String> fastly}) cdnEdgesForCore(
  List<CdnEdge> edges, {
  required bool autoUse,
  required String pinnedId,
  int perProvider = 3,
}) {
  List<String> pick(String provider, List<CdnEdge> pool) {
    final ranked = rankCdnEdges(
      pool.where((e) => e.provider == provider).toList(),
    );
    final tested = ranked.where((e) => e.lastOk).toList();
    // Preresolved CIDRs take IP literals only: a hostname entry
    // contributes its probed IP, never the name itself.
    final chosen = (tested.isNotEmpty ? tested : ranked)
        .map((e) => e.testedIp ?? e.address)
        .where((a) => InternetAddress.tryParse(a) != null)
        .take(perProvider)
        .toList();
    return chosen;
  }

  if (!autoUse && pinnedId.isNotEmpty) {
    final pinned = edges.where((e) => e.id == pinnedId).toList();
    if (pinned.isNotEmpty) {
      final p = pinned.first;
      final ip = p.testedIp ?? p.address;
      if (InternetAddress.tryParse(ip) == null) {
        return (akamai: const [], fastly: const []);
      }
      return (
        akamai: p.provider == 'akamai' ? [ip] : const [],
        fastly: p.provider == 'fastly' ? [ip] : const [],
      );
    }
  }
  return (akamai: pick('akamai', edges), fastly: pick('fastly', edges));
}

/// A parsed Conduit personal-pairing (PsiphonPairing's rules, the
/// same parser as ralysnd's): a `psiphon://pair/<token>` link, a
/// bare token, or a bare 43-char compartment id.
class ConduitPairing {
  final String id;
  final String name;
  const ConduitPairing(this.id, this.name);
}

final _compartmentRe = RegExp(r'^[A-Za-z0-9+/]{43}$');
final _linkRe = RegExp(r'(?:^psiphon://pair/|/pair/)([A-Za-z0-9_-]+)');
final _bareTokenRe = RegExp(r'^[A-Za-z0-9_-]{16,}$');

List<int>? _b64decode(String s) {
  var clean = s.trim().replaceAll(RegExp(r'=$'), '');
  clean = clean.replaceAll('-', '+').replaceAll('_', '/');
  if (clean.isEmpty || clean.length % 4 == 1) return null;
  while (clean.length % 4 != 0) {
    clean += '=';
  }
  try {
    return base64Decode(clean);
  } catch (_) {
    return null;
  }
}

/// Parses a pairing link/token/id; null when it is none of those
/// (the caller shows the "not a pairing link" message).
ConduitPairing? parseConduitPairing(String text) {
  final raw = text.trim();
  if (raw.isEmpty) return null;
  if (_compartmentRe.hasMatch(raw)) {
    final bytes = _b64decode(raw);
    if (bytes != null && bytes.length == 32) return ConduitPairing(raw, '');
    return null;
  }
  final token = _linkRe.firstMatch(raw)?.group(1) ??
      (_bareTokenRe.hasMatch(raw) ? raw : null);
  if (token == null) return null;
  final payloadBytes = _b64decode(token);
  if (payloadBytes == null) return null;
  try {
    final payload = jsonDecode(utf8.decode(payloadBytes));
    if (payload is! Map) return null;
    final data = payload['data'];
    if (data is! Map) return null;
    final id = (data['id'] as String? ?? '').trim();
    if (payload['v'] != '1' ||
        !_compartmentRe.hasMatch(id) ||
        (_b64decode(id)?.length ?? 0) != 32) {
      return null;
    }
    var name = (data['name'] as String? ?? '');
    if (name.length > 60) name = name.substring(0, 60);
    return ConduitPairing(id, name);
  } catch (_) {
    return null;
  }
}
