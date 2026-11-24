/// Clash YAML subscription import (build 2075, feature
/// item 21). Panels and aggregators increasingly serve
/// Clash-format subscriptions (`proxies:` documents); until
/// this build Ember decoded them as a link list and found
/// nothing. The parser uses the real `yaml` package (it was
/// already in the offline pub cache) and maps the common
/// Clash proxy entry types onto profiles with the same
/// field conventions as the link parsers:
///
///   ss / vmess / vless / trojan / hysteria2 / tuic /
///   wireguard / snell / mieru / socks5 / http
///
/// Entries of any other type, and entries missing their
/// server, are counted as skipped — never half-imported.
/// The import is reachable wherever a subscription body is
/// parsed (parseSubscription routes here when the body
/// looks like a Clash document) and from the manual
/// import path.

import 'package:yaml/yaml.dart';

import 'profile_validation.dart';
import 'xray_models.dart';

/// Cheap shape test used by parseSubscription: a Clash
/// document carries a top-level `proxies:` list.
bool looksLikeClashYaml(String text) {
  final t = text.trimLeft();
  if (t.startsWith('proxies:')) return true;
  return RegExp(r'^proxies:\s*$', multiLine: true).hasMatch(t) ||
      RegExp(r'^proxies:\s*\n\s*-', multiLine: true).hasMatch(t);
}

class ClashImportResult {
  final List<Profile> profiles;
  final int skipped;
  const ClashImportResult(this.profiles, this.skipped);
}

/// Build 2095 (fourth-pass audit 1.2): the conversion
/// carries a node budget. package:yaml represents an
/// alias as a SHARED node, and the old conversion
/// deep-copied it at every occurrence — nested anchors
/// expanded exponentially (a few-KB body demanding
/// gigabytes) and a recursive anchor recursed forever.
/// Every visit spends from one budget; past it the
/// conversion aborts and the document imports as empty.
class _PlainBudget {
  int nodes = 200000;
}

dynamic _plain(dynamic v, _PlainBudget budget) {
  if (--budget.nodes < 0) {
    throw StateError('clash-document-too-large');
  }
  if (v is YamlMap) {
    return <String, dynamic>{
      for (final e in v.entries) e.key.toString(): _plain(e.value, budget),
    };
  }
  if (v is YamlList) return [for (final e in v) _plain(e, budget)];
  return v;
}

String _s(Map<String, dynamic> m, String key) =>
    m[key]?.toString().trim() ?? '';

int _i(Map<String, dynamic> m, String key, [int fallback = 0]) {
  final v = m[key];
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? fallback;
}

/// "100 Mbps" / "100" → 100 (Hysteria2 bandwidth fields).
int _mbps(dynamic v) {
  if (v is num) return v.toInt();
  final digits = RegExp(r'\d+').firstMatch(v?.toString() ?? '');
  if (digits == null) return 0;
  final run = digits.group(0)!;
  // Build 2095 (fourth-pass audit 1.3): a digit run past
  // int64 made int.parse throw and the blanket catch
  // emptied the whole import; the value is a bandwidth,
  // so an absurd run reads as the sanitize ceiling.
  if (run.length > 9) return 100000;
  return int.tryParse(run) ?? 0;
}

String _joinList(dynamic v) {
  if (v is List) return v.map((e) => e.toString()).join(',');
  return v?.toString() ?? '';
}

/// Applies the transport options Clash entries share
/// (ws-opts / grpc-opts / h2-opts / http-opts) to [p].
void _applyClashTransport(Profile p, Map<String, dynamic> e) {
  final network = _s(e, 'network');
  if (network.isNotEmpty) p.network = network;
  final ws = e['ws-opts'];
  if (ws is Map) {
    final m = ws.cast<String, dynamic>();
    p.path = _s(m, 'path');
    final headers = m['headers'];
    if (headers is Map) {
      p.host = headers.cast<String, dynamic>()['Host']?.toString() ?? '';
    }
  }
  final grpc = e['grpc-opts'];
  if (grpc is Map) {
    p.serviceName =
        grpc.cast<String, dynamic>()['grpc-service-name']?.toString() ?? '';
  }
  // Build 2095 (fourth-pass audit 3.3): h2-opts and
  // http-opts ride too — the header comment always
  // claimed h2-opts; without them an h2 profile pointed
  // at the right server with the default path and failed
  // looking like a working import.
  final h2 = e['h2-opts'];
  if (h2 is Map) {
    final m = h2.cast<String, dynamic>();
    if (_s(m, 'path').isNotEmpty) p.path = _s(m, 'path');
    final host = m['host'];
    if (host is List && host.isNotEmpty) {
      p.host = host.first.toString();
    } else if (_s(m, 'host').isNotEmpty) {
      p.host = _s(m, 'host');
    }
  }
  final http = e['http-opts'];
  if (http is Map) {
    final m = http.cast<String, dynamic>();
    if (_s(m, 'path').isNotEmpty) p.path = _s(m, 'path');
    final headers = m['headers'];
    if (headers is Map) {
      final host = headers.cast<String, dynamic>()['Host'];
      if (host is List && host.isNotEmpty) {
        p.host = host.first.toString();
      } else if (host != null) {
        p.host = host.toString();
      }
    }
  }
}

/// One Clash proxy entry → a profile, or null when the
/// entry's type is unsupported or it has no server.
Profile? _clashEntryRaw(Map<String, dynamic> e, String id) {
  final type = _s(e, 'type').toLowerCase();
  final server = _s(e, 'server');
  final port = _i(e, 'port');
  Profile base(Protocol protocol) => Profile(
    id: id,
    name: _s(e, 'name'),
    protocol: protocol,
    address: server,
    port: port,
  );
  switch (type) {
    case 'ss':
      final p = base(Protocol.shadowsocks);
      p.method = _s(e, 'cipher');
      p.uuidOrPassword = _s(e, 'password');
      final plugin = _s(e, 'plugin');
      if (plugin.isNotEmpty) p.plugin = plugin;
      return p;
    case 'vmess':
      final p = base(Protocol.vmess);
      p.uuidOrPassword = _s(e, 'uuid');
      p.aid = _i(e, 'alterId');
      p.scy = _s(e, 'cipher');
      if (e['tls'] == true) p.security = 'tls';
      p.sni = _s(e, 'servername');
      _applyClashTransport(p, e);
      return p;
    case 'vless':
      final p = base(Protocol.vless);
      p.uuidOrPassword = _s(e, 'uuid');
      p.flow = _s(e, 'flow');
      final reality = e['reality-opts'];
      if (reality is Map) {
        final m = reality.cast<String, dynamic>();
        p.security = 'reality';
        p.publicKey = _s(m, 'public-key');
        p.shortId = _s(m, 'short-id');
      } else if (e['tls'] == true) {
        p.security = 'tls';
      }
      p.sni = _s(e, 'servername');
      p.alpn = _joinList(e['alpn']);
      _applyClashTransport(p, e);
      return p;
    case 'trojan':
      final p = base(Protocol.trojan);
      p.uuidOrPassword = _s(e, 'password');
      p.security = 'tls';
      p.sni = _s(e, 'sni').isNotEmpty ? _s(e, 'sni') : _s(e, 'servername');
      p.alpn = _joinList(e['alpn']);
      _applyClashTransport(p, e);
      return p;
    case 'hysteria2':
    case 'hy2':
      final p = base(Protocol.hysteria2);
      p.uuidOrPassword = _s(e, 'password');
      p.obfs = _s(e, 'obfs');
      p.obfsPassword = _s(e, 'obfs-password');
      p.upMbps = _mbps(e['up']);
      p.downMbps = _mbps(e['down']);
      // Build 2095 (audit 3.4): the hopping port list is
      // carried like the link route's mport.
      p.hyMport = _joinList(e['ports']);
      p.sni = _s(e, 'sni');
      p.alpn = _joinList(e['alpn']);
      return p;
    case 'tuic':
      final p = base(Protocol.tuic);
      p.uuidOrPassword = _s(e, 'uuid');
      p.method = _s(e, 'password');
      p.congestionControl = _s(e, 'congestion-controller');
      p.udpRelayMode = _s(e, 'udp-relay-mode');
      p.sni = _s(e, 'sni');
      p.alpn = _joinList(e['alpn']);
      return p;
    case 'wireguard':
      final p = base(Protocol.wireguard);
      p.secretKey = _s(e, 'private-key');
      p.peerPublicKey = _s(e, 'public-key');
      p.preSharedKey = _s(e, 'pre-shared-key');
      final ip = _s(e, 'ip');
      final ipv6 = _s(e, 'ipv6');
      p.localAddress = [ip, ipv6].where((x) => x.isNotEmpty).join(',');
      p.mtu = _i(e, 'mtu', 1420);
      final reserved = e['reserved'];
      if (reserved is List) {
        p.reserved = reserved.map((x) => x.toString()).join(',');
      }
      // Build 2095 (fourth-pass audit 3.2): allowed-ips
      // and dns — without them a split-tunnel entry
      // silently became a FULL tunnel (the empty list
      // maps to 0.0.0.0/0 + ::/0 in the builder).
      p.wgAllowedIPs = _joinList(e['allowed-ips']);
      final dns = e['dns'];
      if (dns is List) {
        p.wgDns = dns.map((x) => x.toString()).join(',');
      } else {
        p.wgDns = _s(e, 'dns');
      }
      return p;
    case 'snell':
      final p = base(Protocol.snell);
      p.uuidOrPassword = _s(e, 'psk');
      p.snellVersion = _i(e, 'version', 4);
      final obfs = e['obfs-opts'];
      if (obfs is Map) {
        final m = obfs.cast<String, dynamic>();
        p.obfs = _s(m, 'mode');
        p.obfsPassword = _s(m, 'host');
      }
      return p;
    case 'mieru':
      final p = base(Protocol.mieru);
      p.username = _s(e, 'username');
      p.uuidOrPassword = _s(e, 'password');
      final transport = _s(e, 'transport');
      if (transport.isNotEmpty) p.network = transport.toLowerCase();
      return p;
    case 'socks5':
      final p = base(Protocol.socks);
      p.username = _s(e, 'username');
      p.uuidOrPassword = _s(e, 'password');
      return p;
    case 'http':
      final p = base(Protocol.http);
      p.username = _s(e, 'username');
      p.uuidOrPassword = _s(e, 'password');
      return p;
    default:
      return null;
  }
}


/// One Clash proxy entry → a profile (the public entry:
/// the raw per-type mapping plus the cross-type fields
/// build 2095 restored — fourth-pass audit 3.1).
Profile? clashEntryToProfile(Map<String, dynamic> e, String id) {
  final p = _clashEntryRaw(e, id);
  if (p == null) return null;
  // client-fingerprint is set by panels for every TLS
  // type; the raw mapping never read it, so every
  // Clash-imported TLS profile fell back to the core
  // default where the panel intended a pinned one.
  final fp = _s(e, 'client-fingerprint');
  if (fp.isNotEmpty) p.fingerprint = fp;
  // reality-opts also rides vmess and trojan entries in
  // mihomo documents; only the vless branch read it, so
  // a REALITY trojan degraded to plain TLS and failed
  // against its server with no hint why.
  final reality = e['reality-opts'];
  if (reality is Map &&
      (p.protocol == Protocol.vmess || p.protocol == Protocol.trojan)) {
    final m = reality.cast<String, dynamic>();
    p.security = 'reality';
    p.publicKey = _s(m, 'public-key');
    p.shortId = _s(m, 'short-id');
  }
  return sanitizeImportedProfile(p);
}

/// Parses a Clash YAML document. A malformed document, or
/// one without a proxies list, yields an empty result —
/// never a throw.
ClashImportResult parseClashYaml(String text, String Function() newId) {
  try {
    final doc = loadYaml(text);
    if (doc is! YamlMap) return const ClashImportResult([], 0);
    // Build 2095 (audit 1.2): only the proxies subtree is
    // materialized — rules/groups and any other keys,
    // however large or alias-laden, never convert.
    final rawProxies = doc['proxies'];
    if (rawProxies == null) return const ClashImportResult([], 0);
    final proxies = _plain(rawProxies, _PlainBudget());
    if (proxies is! List) return const ClashImportResult([], 0);
    final out = <Profile>[];
    var skipped = 0;
    for (final entry in proxies) {
      if (entry is! Map) {
        skipped++;
        continue;
      }
      // Build 2095 (audit 1.3): per-entry — one poisoned
      // entry skips itself, not the whole document.
      Profile? p;
      try {
        p = clashEntryToProfile(entry.cast<String, dynamic>(), newId());
      } catch (_) {
        p = null;
      }
      if (p == null || p.address.isEmpty) {
        skipped++;
        continue;
      }
      // Build 2103 (diagnosis N2): a nameless entry takes
      // the positional name, never its address — the
      // pre-2103 substitution stored the address as the
      // name, the same manufactured value the link route
      // made (see _fallbackName in link_parser.dart).
      if (p.name.isEmpty) p.name = '${p.protocol.label} ${out.length + 1}';
      out.add(p);
      if (out.length >= kMaxImportedProfiles) break;
    }
    return ClashImportResult(out, skipped);
  } catch (_) {
    return const ClashImportResult([], 0);
  }
}
