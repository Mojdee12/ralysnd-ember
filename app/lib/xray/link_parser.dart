/// Parses share links and subscription bodies (port of the Ralysnd
/// client's Kotlin LinkParser, extended with hysteria2 / wireguard /
/// tuic links and the kcp / quic transports).

import 'dart:convert';

import 'xray_models.dart';

int _counter = 0;

/// The first JSON object of a list value, or null.
Map<String, dynamic>? _firstMap(dynamic list) {
  if (list is List && list.isNotEmpty && list.first is Map) {
    return (list.first as Map).cast<String, dynamic>();
  }
  return null;
}

String newProfileId() =>
    'p${DateTime.now().millisecondsSinceEpoch}-${_counter++}';

/// Base64 in any flavour the wild uses; null when it will not decode.
String? b64decode(String text) {
  var s = text.trim().replaceAll(RegExp(r'\s+'), '');
  s = s.replaceAll('-', '+').replaceAll('_', '/');
  while (s.length % 4 != 0) {
    s += '=';
  }
  try {
    return utf8.decode(base64.decode(s));
  } catch (_) {
    return null;
  }
}

/// UUIDs for profiles parsed without one.
String _fallbackName(Profile p, int position) {
  if (p.name.isNotEmpty) return p.name;
  return p.address.isEmpty ? '${p.protocol.label} ${position + 1}' : p.address;
}

/// Every parseable link in [text], in order; unparseable lines skipped.
List<Profile> parseLinks(String text) {
  final out = <Profile>[];
  for (var part in text.split(RegExp(r'[\r\n]'))) {
    part = part.trim();
    if (part.isEmpty) continue;
    final profile = parseLink(part);
    if (profile != null) out.add(profile);
  }
  for (var i = 0; i < out.length; i++) {
    out[i].name = _fallbackName(out[i], i);
  }
  return out;
}

Profile? parseLink(String rawLink) {
  final link = rawLink.trim();
  if (link.startsWith('vless://')) return _vless(link);
  if (link.startsWith('vmess://')) return _vmess(link);
  if (link.startsWith('trojan://')) return _trojan(link);
  if (link.startsWith('ss://')) return _shadowsocks(link);
  if (link.startsWith('hysteria2://') || link.startsWith('hy2://')) {
    return _hysteria2(link);
  }
  if (link.startsWith('wireguard://') || link.startsWith('wg://')) {
    return _wireguard(link);
  }
  if (link.startsWith('tuic://')) return _tuic(link);
  if (link.startsWith('anytls://')) return _anytls(link);
  if (link.startsWith('socks://') || link.startsWith('socks5://')) {
    return _socks(link);
  }
  return null;
}

/// Parses a full subscription body (raw, base64 or a config-JSON array).
List<Profile> parseSubscription(String body) {
  // The subscription may be a JSON config array, a raw link list, or
  // either of those base64-encoded.
  for (final variant in [body, if (b64decode(body) != null) b64decode(body)!]) {
    final asConfig = _parseConfigJson(variant);
    if (asConfig != null) return asConfig;
    final links = parseLinks(variant);
    if (links.isNotEmpty) return links;
    // A fully-encoded body that itself decoded to more base64: one
    // more level, no deeper.
    final inner = b64decode(variant);
    if (inner != null && inner != variant) {
      final links2 = parseLinks(inner);
      if (links2.isNotEmpty) return links2;
    }
  }
  return const [];
}

/// Xray JSON config exports (an object with outbounds, or an array of
/// such objects): the first proxy outbound of each becomes a profile.
List<Profile>? _parseConfigJson(String body) {
  final trimmed = body.trim();
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return null;
  try {
    final dynamic doc = jsonDecode(trimmed);
    final docs = doc is List ? doc : [doc];
    final out = <Profile>[];
    for (final d in docs) {
      if (d is! Map<String, dynamic>) continue;
      final profile = _outboundToProfile(d);
      if (profile != null) out.add(profile);
    }
    return out.isEmpty ? null : out;
  } catch (_) {
    return null;
  }
}

Profile? _outboundToProfile(Map<String, dynamic> config) {
  final outbounds = config['outbounds'];
  if (outbounds is! List) return null;
  for (final o in outbounds) {
    if (o is! Map<String, dynamic>) continue;
    final protocol = o['protocol'] as String?;
    final settings = (o['settings'] as Map?)?.cast<String, dynamic>() ?? {};
    final stream = (o['streamSettings'] as Map?)?.cast<String, dynamic>() ?? {};
    Profile base(Protocol p) {
      final profile = Profile(id: newProfileId(), protocol: p);
      profile.network = stream['network'] as String? ?? 'tcp';
      profile.security = stream['security'] as String? ?? '';
      final tls = (stream['tlsSettings'] as Map?)?.cast<String, dynamic>();
      if (tls != null) {
        profile.sni = tls['serverName'] as String? ?? '';
        profile.alpn = (tls['alpn'] as List?)?.join(',') ?? '';
        profile.allowInsecure = tls['allowInsecure'] as bool? ?? false;
        profile.fingerprint = tls['fingerprint'] as String? ?? '';
      }
      final reality = (stream['realitySettings'] as Map?)?.cast<String, dynamic>();
      if (reality != null) {
        profile.sni = reality['serverName'] as String? ?? '';
        profile.fingerprint = reality['fingerprint'] as String? ?? '';
        profile.publicKey = reality['publicKey'] as String? ?? '';
        profile.shortId = reality['shortId'] as String? ?? '';
        profile.spiderX = reality['spiderX'] as String? ?? '';
      }
      final ws = (stream['wsSettings'] as Map?)?.cast<String, dynamic>();
      if (ws != null) {
        profile.path = ws['path'] as String? ?? '';
        profile.host = (ws['headers'] as Map?)?['Host'] as String? ?? '';
      }
      final grpc = (stream['grpcSettings'] as Map?)?.cast<String, dynamic>();
      if (grpc != null) {
        profile.serviceName = grpc['serviceName'] as String? ?? '';
        profile.mode = (grpc['multiMode'] as bool? ?? false) ? 'multi' : 'gun';
      }
      return profile;
    }

    switch (protocol) {
      case 'vless':
      case 'vmess':
        final vnext = _firstMap(settings['vnext']);
        if (vnext == null) continue;
        final user = _firstMap(vnext['users']);
        final profile = base(protocol == 'vless' ? Protocol.vless : Protocol.vmess);
        profile.address = vnext['address'] as String? ?? '';
        profile.port = (vnext['port'] as num?)?.toInt() ?? 443;
        profile.uuidOrPassword = user?['id'] as String? ?? '';
        profile.flow = user?['flow'] as String? ?? '';
        return profile;
      case 'trojan':
      case 'shadowsocks':
        final server = _firstMap(settings['servers']);
        if (server == null) continue;
        final profile =
            base(protocol == 'trojan' ? Protocol.trojan : Protocol.shadowsocks);
        profile.address = server['address'] as String? ?? '';
        profile.port = (server['port'] as num?)?.toInt() ?? 443;
        profile.uuidOrPassword = server['password'] as String? ?? '';
        profile.method = server['method'] as String? ?? '';
        return profile;
      case 'socks':
        final server = _firstMap(settings['servers']);
        if (server == null) continue;
        final profile = base(Protocol.socks);
        profile.address = server['address'] as String? ?? '';
        profile.port = (server['port'] as num?)?.toInt() ?? 1080;
        final user = _firstMap(server['users']);
        profile.username = user?['user'] as String? ?? '';
        profile.uuidOrPassword = user?['pass'] as String? ?? '';
        return profile;
    }
  }
  return null;
}

class _Authority {
  final String host;
  final int port;
  final String userInfo;
  final String query;
  final String name;
  const _Authority(this.host, this.port, this.userInfo, this.query, this.name);
}

/// Splits `scheme://userinfo@host:port?query#name` — by hand, because
/// ss SIP002 userinfo carries base64 with characters Uri cannot hold.
_Authority? _authority(String link, String scheme) {
  final rest = link.substring(scheme.length + 3);
  if (rest.isEmpty) return null;
  var fragment = '';
  var main = rest;
  final hash = rest.indexOf('#');
  if (hash >= 0) {
    fragment = rest.substring(hash + 1);
    main = rest.substring(0, hash);
  }
  var query = '';
  final q = main.indexOf('?');
  if (q >= 0) {
    query = main.substring(q + 1);
    main = main.substring(0, q);
  }
  final at = main.lastIndexOf('@');
  if (at < 0) return null;
  final userInfo = main.substring(0, at);
  final hostPort = main.substring(at + 1);
  String host;
  int port;
  if (hostPort.startsWith('[')) {
    final close = hostPort.indexOf(']');
    if (close < 0) return null;
    host = hostPort.substring(1, close);
    // A path may follow the port (host]:8443/?…) — the port
    // is the digit run up to it (build 2033).
    final rest = hostPort.length > close + 1
        ? hostPort.substring(close + 2).split('/').first
        : '';
    port = int.tryParse(rest) ?? 443;
  } else {
    // Strip any path (host:8443/?…): several link families —
    // AnyTLS conventionally, TUIC often — carry one, and the
    // pre-2033 parse read "8443/" as the port and silently
    // fell back to 443.
    final authority = hostPort.split('/').first;
    final colon = authority.lastIndexOf(':');
    if (colon < 0) return null;
    host = authority.substring(0, colon);
    port = int.tryParse(authority.substring(colon + 1)) ?? 443;
  }
  return _Authority(
    host,
    port,
    _percentDecode(userInfo),
    query,
    _percentDecode(fragment),
  );
}

String _percentDecode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

Map<String, String> _queryParams(String query) {
  final out = <String, String>{};
  for (final pair in query.split('&')) {
    if (pair.isEmpty) continue;
    final eq = pair.indexOf('=');
    if (eq < 0) {
      out[_percentDecode(pair)] = '';
    } else {
      out[_percentDecode(pair.substring(0, eq))] =
          _percentDecode(pair.substring(eq + 1));
    }
  }
  return out;
}

void _applyTransport(Profile p, Map<String, String> q) {
  p.network = q['type'] ?? q['net'] ?? p.network;
  p.headerType = q['headerType'] ?? p.headerType;
  p.host = q['host'] ?? p.host;
  p.path = q['path'] ?? p.path;
  p.serviceName = q['serviceName'] ?? p.serviceName;
  p.mode = q['mode'] ?? p.mode;
  p.security = q['security'] ?? p.security;
  if (p.security == 'none') p.security = '';
  p.sni = q['sni'] ?? q['peer'] ?? p.sni;
  // The ECH config list (build 2033), under the parameter
  // name Xray's own link import reads into the TLS settings.
  p.echConfigList = q['ech'] ?? p.echConfigList;
  p.alpn = (q['alpn'] ?? '').replaceAll(r'\,', ',');
  if (p.alpn.isEmpty) p.alpn = q['alpn'] ?? p.alpn;
  p.fingerprint = q['fp'] ?? p.fingerprint;
  p.cipherSuites = q['cs'] ?? p.cipherSuites;
  // Exact-text core fields (build 2030): copied as written —
  // never trimmed or case-folded (PattNG's EXACT preset rule;
  // the core reads them verbatim).
  p.dialMode = q['dialMode'] ?? p.dialMode;
  p.finalMask = q['fm'] ?? p.finalMask;
  p.publicKey = q['pbk'] ?? p.publicKey;
  p.shortId = q['sid'] ?? p.shortId;
  p.spiderX = q['spx'] ?? p.spiderX;
  p.flow = q['flow'] ?? p.flow;
  p.allowInsecure = q['allowInsecure'] == '1' ||
      q['allowInsecure'] == 'true' ||
      q['insecure'] == '1' ||
      q['insecure'] == 'true';
}

Profile? _vless(String link) {
  final a = _authority(link, 'vless');
  if (a == null || a.host.isEmpty) return null;
  final p = Profile(
    id: newProfileId(),
    protocol: Protocol.vless,
    name: a.name,
    address: a.host,
    port: a.port,
    uuidOrPassword: a.userInfo,
  );
  _applyTransport(p, _queryParams(a.query));
  final q = _queryParams(a.query);
  if (q['encryption'] != null && q['encryption'] != 'none') {
    // Xray "encryption" values other than none are not interoperable
    // here; keep the link rather than silently drop it.
  }
  if (p.security == 'reality' && p.fingerprint.isEmpty) {
    p.fingerprint = 'chrome';
  }
  if (p.security == 'tls' && p.fingerprint.isEmpty) p.fingerprint = 'chrome';
  return p;
}

Profile? _trojan(String link) {
  final a = _authority(link, 'trojan');
  if (a == null || a.host.isEmpty) return null;
  final p = Profile(
    id: newProfileId(),
    protocol: Protocol.trojan,
    name: a.name,
    address: a.host,
    port: a.port,
    uuidOrPassword: a.userInfo,
    security: 'tls',
  );
  _applyTransport(p, _queryParams(a.query));
  if (p.security.isEmpty) p.security = 'tls';
  return p;
}

Profile? _hysteria2(String link) {
  final scheme = link.startsWith('hy2://') ? 'hy2' : 'hysteria2';
  final a = _authority(link, scheme);
  if (a == null || a.host.isEmpty) return null;
  final q = _queryParams(a.query);
  final p = Profile(
    id: newProfileId(),
    protocol: Protocol.hysteria2,
    name: a.name,
    address: a.host,
    port: a.port,
    uuidOrPassword: a.userInfo,
    security: 'tls',
    sni: q['sni'] ?? q['peer'] ?? '',
    alpn: 'h3',
  );
  p.obfs = q['obfs'] ?? '';
  p.obfsPassword = q['obfs-password'] ?? q['obfsPassword'] ?? '';
  p.upMbps = int.tryParse(q['up'] ?? '') ?? 0;
  p.downMbps = int.tryParse(q['down'] ?? '') ?? 0;
  p.allowInsecure = q['insecure'] == '1' || q['insecure'] == 'true';
  p.fingerprint = q['pinSHA256'] ?? '';
  // ECH for the QUIC handshake (build 2033): the parameter
  // carries the echConfigList text itself (a base64 list or a
  // "domain+resolver" query form); stored verbatim and handed
  // to the core's TLS settings by the builder.
  p.echConfigList = q['ech'] ?? '';
  // Congestion control (build 2036): Ember's own parameter —
  // no standard hy2 link field exists for it — so an export
  // round-trips the choice; other clients ignore the unknown
  // parameter. Only the values the core honours are kept.
  final cc = q['congestion'] ?? '';
  p.hyCongestion = hyCongestionChoices.contains(cc) ? cc : '';
  return p;
}

/// AnyTLS links (build 2033), the sing-box / mihomo shape:
/// anytls://password@host:port/?security=tls&sni=…&fp=…#name.
/// Parsed and stored like TUIC — the bundled Xray core has no
/// AnyTLS outbound (verified in its source), so the profile is
/// badged unsupported and refuses to connect rather than
/// pretending. The userinfo is the password; there is no
/// username in the standard form.
Profile? _anytls(String link) {
  final a = _authority(link, 'anytls');
  if (a == null || a.host.isEmpty) return null;
  final q = _queryParams(a.query);
  final p = Profile(
    id: newProfileId(),
    protocol: Protocol.anytls,
    name: a.name,
    address: a.host,
    port: a.port,
    uuidOrPassword: a.userInfo,
    security: 'tls',
  );
  p.sni = q['sni'] ?? q['peer'] ?? '';
  p.alpn = (q['alpn'] ?? '').replaceAll(r'\,', ',');
  p.fingerprint = q['fp'] ?? '';
  p.allowInsecure =
      q['insecure'] == '1' ||
      q['insecure'] == 'true' ||
      q['allowInsecure'] == '1' ||
      q['allowInsecure'] == 'true';
  return p;
}

Profile? _wireguard(String link) {
  final scheme = link.startsWith('wg://') ? 'wg' : 'wireguard';
  final a = _authority(link, scheme);
  if (a == null || a.host.isEmpty) return null;
  final q = _queryParams(a.query);
  final p = Profile(
    id: newProfileId(),
    protocol: Protocol.wireguard,
    name: a.name,
    address: a.host,
    port: a.port,
    secretKey: a.userInfo,
  );
  p.peerPublicKey = q['publickey'] ?? q['publicKey'] ?? '';
  p.preSharedKey = q['presharedkey'] ?? q['preSharedKey'] ?? '';
  p.localAddress = q['address'] ?? '';
  p.reserved = q['reserved'] ?? '';
  p.mtu = int.tryParse(q['mtu'] ?? '') ?? 1420;
  p.keepAlive = int.tryParse(q['keepalive'] ?? '') ?? 0;
  // AmneziaWG parameters (build 2033): preserved verbatim so
  // an export writes them back; the carrier cannot apply
  // them (the profile is badged as running plain WireGuard).
  p.awgJc = q['jc'] ?? '';
  p.awgJmin = q['jmin'] ?? '';
  p.awgJmax = q['jmax'] ?? '';
  p.awgS1 = q['s1'] ?? '';
  p.awgS2 = q['s2'] ?? '';
  p.awgH1 = q['h1'] ?? '';
  p.awgH2 = q['h2'] ?? '';
  p.awgH3 = q['h3'] ?? '';
  p.awgH4 = q['h4'] ?? '';
  return p;
}

Profile? _tuic(String link) {
  final a = _authority(link, 'tuic');
  if (a == null || a.host.isEmpty) return null;
  final cred = a.userInfo;
  final colon = cred.indexOf(':');
  final p = Profile(
    id: newProfileId(),
    protocol: Protocol.tuic,
    name: a.name,
    address: a.host,
    port: a.port,
    uuidOrPassword: colon >= 0 ? cred.substring(0, colon) : cred,
    security: 'tls',
  );
  if (colon >= 0) p.method = cred.substring(colon + 1); // password
  final q = _queryParams(a.query);
  p.congestionControl = q['congestion_control'] ?? '';
  p.udpRelayMode = q['udp_relay_mode'] ?? '';
  p.sni = q['sni'] ?? '';
  p.alpn = (q['alpn'] ?? '').replaceAll(r'\,', ',');
  p.allowInsecure = q['allow_insecure'] == '1' || q['allow_insecure'] == 'true';
  return p;
}

/// SOCKS share links, in the forms the wild uses:
///   socks://base64(user:pass)@host:port#name   (v2rayNG SIP002-style)
///   socks://user:pass@host:port#name
///   socks://host:port#name                     (no auth)
/// Parsed by hand like ss:// — _authority insists on a userinfo part,
/// which the no-auth form does not have.
Profile? _socks(String link) {
  final scheme = link.startsWith('socks5://') ? 'socks5' : 'socks';
  var main = link.substring(scheme.length + 3);
  var name = '';
  final hash = main.indexOf('#');
  if (hash >= 0) {
    name = _percentDecode(main.substring(hash + 1));
    main = main.substring(0, hash);
  }
  final q = main.indexOf('?');
  if (q >= 0) main = main.substring(0, q);
  if (main.endsWith('/')) main = main.substring(0, main.length - 1);
  if (main.isEmpty) return null;

  var user = '';
  var pass = '';
  var hostPort = main;
  final at = main.lastIndexOf('@');
  if (at >= 0) {
    final rawInfo = main.substring(0, at);
    hostPort = main.substring(at + 1);
    // SIP002-style userinfo is base64(user:pass); when the userinfo
    // decodes to a credential pair use the decoding, otherwise the
    // plain percent-decoded text (user:pass or a bare username).
    final decoded = b64decode(rawInfo);
    final cred = (decoded != null && decoded.contains(':'))
        ? decoded
        : _percentDecode(rawInfo);
    final colon = cred.indexOf(':');
    if (colon >= 0) {
      user = cred.substring(0, colon);
      pass = cred.substring(colon + 1);
    } else {
      user = cred;
    }
  }

  String host;
  int port;
  if (hostPort.startsWith('[')) {
    final close = hostPort.indexOf(']');
    if (close < 0) return null;
    host = hostPort.substring(1, close);
    port = hostPort.length > close + 1
        ? int.tryParse(hostPort.substring(close + 2)) ?? 1080
        : 1080;
  } else {
    final colon = hostPort.lastIndexOf(':');
    host = colon >= 0 ? hostPort.substring(0, colon) : hostPort;
    port = colon >= 0
        ? int.tryParse(hostPort.substring(colon + 1)) ?? 1080
        : 1080;
  }
  if (host.isEmpty) return null;
  return Profile(
    id: newProfileId(),
    protocol: Protocol.socks,
    name: name,
    address: host,
    port: port,
    uuidOrPassword: pass,
    username: user,
  );
}

Profile? _vmess(String link) {
  final body = link.substring('vmess://'.length);
  final decoded = b64decode(body);
  if (decoded == null) {
    // Some panels serve vmess as a plain link with a query string.
    final a = _authority(link, 'vmess');
    if (a == null || a.host.isEmpty) return null;
    final p = Profile(
      id: newProfileId(),
      protocol: Protocol.vmess,
      name: a.name,
      address: a.host,
      port: a.port,
      uuidOrPassword: a.userInfo,
    );
    _applyTransport(p, _queryParams(a.query));
    return p;
  }
  try {
    final j = (jsonDecode(decoded) as Map).cast<String, dynamic>();
    final p = Profile(
      id: newProfileId(),
      protocol: Protocol.vmess,
      name: j['ps'] as String? ?? '',
      address: j['add'] as String? ?? '',
      port: _vmessInt(j['port']),
      uuidOrPassword: j['id'] as String? ?? '',
      network: j['net'] as String? ?? 'tcp',
      headerType: j['type'] as String? ?? '',
      host: j['host'] as String? ?? '',
      path: j['path'] as String? ?? '',
      security: j['tls'] as String? ?? '',
      sni: j['sni'] as String? ?? '',
      alpn: j['alpn'] as String? ?? '',
      fingerprint: j['fp'] as String? ?? '',
      cipherSuites: j['cs'] as String? ?? '',
      dialMode: j['dialMode'] as String? ?? '',
      finalMask: j['fm'] as String? ?? '',
    );
    if (p.network == 'grpc') {
      p.serviceName = p.path;
      p.mode = j['mode'] as String? ?? '';
    }
    p.allowInsecure = j['allowInsecure'] == true || j['insecure'] == 1;
    return p.address.isEmpty ? null : p;
  } catch (_) {
    return null;
  }
}

int _vmessInt(dynamic v) {
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? 443;
}

Profile? _shadowsocks(String link) {
  final rest = link.substring('ss://'.length);
  var main = rest;
  var name = '';
  final hash = rest.indexOf('#');
  if (hash >= 0) {
    name = _percentDecode(rest.substring(hash + 1));
    main = rest.substring(0, hash);
  }
  var plugin = '';
  final q = main.indexOf('?');
  if (q >= 0) {
    plugin = _queryParams(main.substring(q + 1))['plugin'] ?? '';
    main = main.substring(0, q);
  }
  String? method;
  String? password;
  String? host;
  int? port;

  bool splitAuthority(String s) {
    final at = s.lastIndexOf('@');
    if (at < 0) return false;
    final cred = s.substring(0, at);
    final hostPort = s.substring(at + 1);
    final colon = hostPort.lastIndexOf(':');
    if (colon < 0) return false;
    final credColon = cred.indexOf(':');
    if (credColon < 0) return false;
    method = cred.substring(0, credColon);
    password = cred.substring(credColon + 1);
    host = hostPort.substring(0, colon).removeSurroundingBrackets();
    port = int.tryParse(hostPort.substring(colon + 1).split('/').first);
    return true;
  }

  bool parsed = false;
  // SIP002: ss://base64(method:password)@host:port — decode userinfo only.
  if (main.contains('@')) {
    final at = main.lastIndexOf('@');
    final userInfo = main.substring(0, at);
    final decoded = b64decode(userInfo);
    if (decoded != null && decoded.contains(':')) {
      parsed = splitAuthority('$decoded@${main.substring(at + 1)}');
    }
    if (!parsed) parsed = splitAuthority(main);
  }
  // Legacy: the whole authority is base64.
  if (!parsed) {
    final decoded = b64decode(main);
    if (decoded != null) parsed = splitAuthority(decoded);
  }
  final m = method;
  final pw = password;
  final h = host;
  final pt = port;
  if (!parsed || m == null || pw == null || h == null || h.isEmpty || pt == null) {
    return null;
  }
  return Profile(
    id: newProfileId(),
    protocol: Protocol.shadowsocks,
    name: name,
    address: h,
    port: pt,
    uuidOrPassword: pw,
    method: m,
    plugin: plugin,
  );
}

extension on String {
  String removeSurroundingBrackets() =>
      startsWith('[') && endsWith(']') ? substring(1, length - 1) : this;
}
