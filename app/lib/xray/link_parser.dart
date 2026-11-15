/// Parses share links and subscription bodies (port of the Ralysnd
/// client's Kotlin LinkParser, extended with hysteria2 / wireguard /
/// tuic links and the kcp / quic transports).

import 'dart:convert';

import 'tls_cert_pin.dart';
import 'vless_encryption.dart';
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
  if (link.startsWith('http://') || link.startsWith('https://')) {
    return _http(link);
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
        // tls['allowInsecure'] is ignored (build 2048): the core
        // removed it and refuses the whole config when it is set,
        // so a raw JSON carrying it must still import — pinning
        // is the replacement.
        profile.fingerprint = tls['fingerprint'] as String? ?? '';
        // TLS certificate pin (build 2047): a raw core JSON
        // carrying a valid pin keeps it; anything else reads as
        // no pin, as before.
        final rawPin = tls['pinnedPeerCertSha256'];
        if (rawPin is String && isValidTlsCertPin(rawPin)) {
          profile.tlsCertPin = rawPin;
        }
      }
      final reality = (stream['realitySettings'] as Map?)?.cast<String, dynamic>();
      if (reality != null) {
        profile.sni = reality['serverName'] as String? ?? '';
        profile.fingerprint = reality['fingerprint'] as String? ?? '';
        profile.publicKey = reality['publicKey'] as String? ?? '';
        profile.shortId = reality['shortId'] as String? ?? '';
        profile.spiderX = reality['spiderX'] as String? ?? '';
        // REALITY PQ verification (build 2057, audit F-M13).
        profile.pqv = reality['mldsa65Verify'] as String? ?? '';
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
        // gRPC authority (build 2057, audit §6 codec drop).
        profile.grpcAuthority = grpc['authority'] as String? ?? '';
      }
      // QUIC transport (build 2057, audit §6 codec drop): the
      // core's quicSettings security/key land in host/path,
      // where the builder reads them from.
      final quic = (stream['quicSettings'] as Map?)?.cast<String, dynamic>();
      if (quic != null && profile.network == 'quic') {
        profile.host = quic['security'] as String? ?? profile.host;
        profile.path = quic['key'] as String? ?? profile.path;
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
        // VLESS Encryption (build 2046): a raw core JSON carrying
        // a valid encryption value keeps it; anything else reads
        // as no encryption, as before.
        final rawEncryption = user?['encryption'];
        if (rawEncryption is String &&
            rawEncryption != 'none' &&
            isValidVlessEncryption(rawEncryption)) {
          profile.vlessEncryption = rawEncryption;
        }
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
      case 'http':
        // HTTP outbound (build 2057, audit §6 codec drop): the
        // same server/user shape as SOCKS.
        final server = _firstMap(settings['servers']);
        if (server == null) continue;
        final profile = base(Protocol.http);
        profile.address = server['address'] as String? ?? '';
        profile.port = (server['port'] as num?)?.toInt() ?? 8080;
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
  // For QUIC transport the `security` parameter is the QUIC
  // security (none / aes-128-gcm / chacha20-poly1305), not the
  // stream security — it is read into host/path below (build
  // 2057, audit §6 codec drop), never into p.security.
  if (p.network != 'quic') {
    p.security = q['security'] ?? p.security;
    if (p.security == 'none') p.security = '';
  }
  p.sni = q['sni'] ?? q['peer'] ?? p.sni;
  // The ECH config list (build 2033), under the parameter
  // name Xray's own link import reads into the TLS settings.
  p.echConfigList = q['ech'] ?? p.echConfigList;
  p.alpn = (q['alpn'] ?? '').replaceAll(r'\,', ',');
  if (p.alpn.isEmpty) p.alpn = q['alpn'] ?? p.alpn;
  p.fingerprint = q['fp'] ?? p.fingerprint;
  p.cipherSuites = q['cs'] ?? p.cipherSuites;
  // TLS certificate pin (build 2047): the `pinnedPeerCertSha256`
  // link parameter carries the core's own field name. A valid
  // value is kept verbatim; an invalid one is ignored — the
  // profile still imports, exactly as it did before this build —
  // because a bad link must never cost the user the whole profile.
  final pin = q['pinnedPeerCertSha256'];
  if (pin != null && isValidTlsCertPin(pin)) p.tlsCertPin = pin;
  // Exact-text core fields (build 2030): copied as written —
  // never trimmed or case-folded (PattNG's EXACT preset rule;
  // the core reads them verbatim).
  p.dialMode = q['dialMode'] ?? p.dialMode;
  p.finalMask = q['fm'] ?? p.finalMask;
  p.publicKey = q['pbk'] ?? p.publicKey;
  p.shortId = q['sid'] ?? p.shortId;
  p.spiderX = q['spx'] ?? p.spiderX;
  // REALITY post-quantum verification (build 2057, audit
  // F-M13): the `pqv` parameter carries the ML-DSA-65 key the
  // core verifies against — stored verbatim, emitted as
  // `mldsa65Verify` by the builder.
  p.pqv = q['pqv'] ?? p.pqv;
  // gRPC authority (build 2057, audit §6 codec drop): the
  // `:authority` for the handshake; '' = the core default.
  p.grpcAuthority = q['authority'] ?? p.grpcAuthority;
  // Anti-filter shaping (build 2057, audit §6 codec drop): the
  // af* options ride Ember's own parameters so a shared profile
  // keeps its shaping — a client that does not know them ignores
  // the unknown parameters.
  if (q['afUnfilter'] == '1') p.afUnfilter = true;
  if (q['afEch'] == '1') p.afEch = true;
  if (q['afMixedSni'] == '1') p.afMixedSni = true;
  if (q['afTcpNoise'] == '1') p.afTcpNoise = true;
  p.afFragment = q['afFragment'] ?? p.afFragment;
  // QUIC transport (build 2057, audit §6 codec drop): the
  // standard link parameters are `security` (the QUIC security:
  // none / aes-128-gcm / chacha20-poly1305) and `key` — NOT the
  // stream security. The old code read them from `host`/`path`
  // via the builder and never from the query, so a standard
  // encrypted-QUIC link built as `security: 'none', key: ''`.
  // They land in host/path here because that is where the
  // builder reads them from; the stream `security` stays ''.
  if (p.network == 'quic') {
    p.host = q['security'] ?? p.host;
    p.path = q['key'] ?? p.path;
  }
  p.flow = q['flow'] ?? p.flow;
  // allowInsecure / insecure parameters are ignored (build 2048):
  // the core removed the feature and refuses the whole config
  // when it is set, so a link carrying one must still import —
  // pinning is the replacement.
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
  // VLESS Encryption (build 2046): the `encryption` link parameter
  // carries the mlkem768 string the bundled core runs. A valid
  // value is kept verbatim; 'none' (or an absent parameter) means
  // no encryption, as before. An invalid value is ignored — the
  // profile still imports and connects unencrypted, exactly as it
  // did before this build — because a bad link must never cost the
  // user the whole profile.
  final encryption = q['encryption'];
  if (encryption != null &&
      encryption != 'none' &&
      isValidVlessEncryption(encryption)) {
    p.vlessEncryption = encryption;
  }
  // Build 2070 (review §4 row 7): NO default fingerprint fill.
  // The parser used to manufacture 'chrome' here for tls/reality
  // profiles whose link carried no fp — which made every imported
  // profile read as user-pinned, so the shipped uTLS rotation
  // (build 2065, which only fills an EMPTY field) could never
  // apply to the bulk of real profiles. An absent fp now stays
  // empty: empty already means core-default to the builder, the
  // same shape a hand-created profile has always had, and it is
  // exactly what rotation fills. Profiles stored by earlier
  // builds are repaired once by the fingerprint migration in
  // XraySettings/XrayController (clearParserDefaultFingerprints).
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
  // q['insecure'] is ignored (build 2048) — see _applyTransport:
  // the core removed the feature.
  // The certificate pin (build 2053, audit F-H5): the link's
  // `pinSHA256` parameter is the standard Hy2 name, but the
  // core's only pin field is `pinnedPeerCertSha256` — and the
  // profile's canonical pin field is tlsCertPin (build 2047),
  // so the value lands there, validated, exactly like the TLS
  // profiles' own parameter above. A valid value is kept
  // verbatim; an invalid one is ignored (the profile still
  // imports) because a bad link must never cost the user the
  // whole profile. The pre-2053 storage (`fingerprint`) is NOT
  // written anymore — the builder honours a legacy fingerprint
  // pin at emit time, and the editor migrates it on the next
  // edit — so the overloaded field stops growing new pins.
  final hyPin = q['pinSHA256'] ?? q['pinnedPeerCertSha256'];
  if (hyPin != null && isValidTlsCertPin(hyPin)) p.tlsCertPin = hyPin;
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
  // q['insecure'] / q['allowInsecure'] are ignored (build 2048)
  // — see _applyTransport: the core removed it.
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
  // The .conf's split-tunnel list and DNS (build 2057, audit §6
  // WG .conf divergences): the codec writes them back under
  // Ember's own parameter names, so a shared WireGuard profile
  // keeps them; the builder applies the AllowedIPs list.
  p.wgAllowedIPs = q['allowedips'] ?? q['allowedIPs'] ?? '';
  p.wgDns = q['dns'] ?? '';
  // AmneziaWG parameters (build 2033): preserved verbatim so
  // an export writes them back; since build 2040 they are
  // APPLIED by the AmneziaWG engine when the profile connects
  // through the fallback path — the pre-2040 comment claiming
  // otherwise was stale and is corrected here (audit §7
  // comment-claims class, build 2057).
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
  // q['allow_insecure'] is ignored (build 2048) — see
  // _applyTransport: the core removed the feature.
  return p;
}

/// HTTP proxy links (build 2057, audit §6 codec drop):
///   http://user:pass@host:port#name
///   http://host:port#name
/// A plain HTTP proxy — the form panels and subscription lists
/// actually serve. `https://` is treated the same way: the
/// scheme names the proxy protocol, not a TLS hop to the proxy.
/// Parsed by hand like [_socks]: the no-auth form has no
/// userinfo, which [_authority] insists on.
Profile? _http(String link) {
  final scheme = link.startsWith('https://') ? 'https' : 'http';
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
    final cred = _percentDecode(main.substring(0, at));
    hostPort = main.substring(at + 1);
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
    // A proxy link without an explicit port is not a proxy
    // link — a bare http(s) URL in a subscription body must
    // stay skipped, not become a profile pointed at port 8080.
    if (hostPort.length <= close + 1 ||
        !hostPort.substring(close + 1).startsWith(':')) {
      return null;
    }
    port = int.tryParse(hostPort.substring(close + 2).split('/').first) ?? 8080;
  } else {
    final colon = hostPort.lastIndexOf(':');
    if (colon < 0) return null;
    host = hostPort.substring(0, colon);
    port = int.tryParse(hostPort.substring(colon + 1).split('/').first) ?? 8080;
  }
  if (host.isEmpty) return null;
  return Profile(
    id: newProfileId(),
    protocol: Protocol.http,
    name: name,
    address: host,
    port: port,
    username: user,
    uuidOrPassword: pass,
  );
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
      // VMess aid/scy/ech (build 2057, audit §6 codec drops):
      // the JSON's own fields — `aid` may be a number or a
      // string in the wild, and an absent one is 0, NOT the
      // port default `_vmessInt` carries. `scy` defaults to
      // 'auto' at build time, so an absent value reads as ''
      // here.
      aid: j['aid'] is num
          ? (j['aid'] as num).toInt()
          : int.tryParse('${j['aid'] ?? ''}') ?? 0,
      scy: j['scy'] as String? ?? '',
      echConfigList: j['ech'] as String? ?? '',
    );
    if (p.network == 'grpc') {
      p.serviceName = p.path;
      p.mode = j['mode'] as String? ?? '';
    }
    // j['allowInsecure'] / j['insecure'] are ignored (build
    // 2048): the core removed the feature — a vmess JSON carrying
    // them must still import.
    // TLS certificate pin (build 2047): the vmess JSON carries
    // the core's own field name; a valid value is kept, anything
    // else reads as no pin, as before.
    final rawPin = j['pinnedPeerCertSha256'];
    if (rawPin is String && isValidTlsCertPin(rawPin)) {
      p.tlsCertPin = rawPin;
    }
    // Anti-filter shaping (build 2057, audit §6 codec drop):
    // the codec writes the af* options into this same JSON, so
    // a shared VMess profile keeps them.
    p.afUnfilter = j['afUnfilter'] == true;
    p.afEch = j['afEch'] == true;
    p.afMixedSni = j['afMixedSni'] == true;
    p.afTcpNoise = j['afTcpNoise'] == true;
    p.afFragment = j['afFragment'] as String? ?? '';
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
