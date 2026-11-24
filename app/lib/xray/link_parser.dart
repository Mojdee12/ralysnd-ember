/// Parses share links and subscription bodies (port of the Ralysnd
/// client's Kotlin LinkParser, extended with hysteria2 / wireguard /
/// tuic links and the kcp / quic transports).

import 'dart:convert';

import 'clash_import.dart';
import 'tls_cert_pin.dart';
import 'vless_encryption.dart';
import 'profile_validation.dart';
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

/// The name a profile parsed without one is stored under:
/// the positional form (protocol label + position). Build
/// 2103 (diagnosis N2): builds ≤2102 returned the server
/// ADDRESS here whenever one existed, and that value was
/// then a real stored name — it persisted, rode share
/// links as their fragment, and re-derived identically on
/// every refresh, which is why the owner's remark-less
/// configs read as named by their server address. A
/// genuinely nameless profile's stored name is positional
/// now; the address identifies the row at render time
/// only (Profile.displayName), never in the stored field.
String _fallbackName(Profile p, int position) {
  if (p.name.isNotEmpty) return p.name;
  return '${p.protocol.label} ${position + 1}';
}

/// Every parseable link in [text], in order; unparseable lines skipped.
List<Profile> parseLinks(String text) => parseLinksDetailed(text).profiles;

/// Build 2095 (V2Ray journey audit #8): [parseLinks] plus the
/// lines it could not read, so an import can tell the user
/// what was skipped instead of dropping it silently.
///
/// Build 2098 (verification, iteration 2): [skippedRaw]
/// carries the same lines UNtrimmed. The body fall-through
/// in the importer re-parses the skipped lines as one
/// document, and for an indented document (a block-style
/// Clash YAML) the per-line trim destroys the structure
/// before that parse ever sees it — the trimmed join reads
/// as stray keys, not as a document. [skipped] stays
/// trimmed: it is the accounting/reporting form.
({List<Profile> profiles, List<String> skipped, List<String> skippedRaw})
parseLinksDetailed(String text) {
  final out = <Profile>[];
  final skipped = <String>[];
  final skippedRaw = <String>[];
  for (final rawPart in text.split(RegExp(r'[\r\n]'))) {
    final part = rawPart.trim();
    if (part.isEmpty) continue;
    // Build 2101 (settings-dns-2099-diagnosis.md, S4/I2): the
    // per-line parse is fault-isolated — one line whose parser
    // throws must count as skipped and let the batch continue,
    // not abort the whole link stage after the lines before it
    // were already added (the owner's "a few added, the rest
    // not" with the sheet stuck busy and no error shown).
    Profile? profile;
    try {
      profile = parseLink(part);
    } catch (_) {
      profile = null;
    }
    if (profile != null) {
      out.add(profile);
    } else {
      skipped.add(part);
      skippedRaw.add(rawPart);
    }
  }
  for (var i = 0; i < out.length; i++) {
    out[i].name = _fallbackName(out[i], i);
  }
  // Build 2095 (fourth-pass audit 4.1/2.1/1.1): every
  // link-route profile passes the import-boundary
  // validation module, and one paste may not grow the
  // store without bound — past the cap the excess lines
  // count as skipped, like unparseable ones.
  // Build 2101 (S4/I2): the sanitize pass is fault-isolated
  // per profile for the same reason — a sanitizer edge on one
  // profile drops THAT profile into the skipped accounting
  // (by name, like the cap excess below), never the batch.
  final sanitized = <Profile>[];
  for (final profile in out) {
    try {
      sanitizeImportedProfile(profile);
      sanitized.add(profile);
    } catch (_) {
      skipped.add(profile.name);
      skippedRaw.add(profile.name);
    }
  }
  out
    ..clear()
    ..addAll(sanitized);
  // Build 2103 (verification iteration 1, L3): the
  // positional fallback runs once more AFTER sanitizing —
  // a remark made only of characters the sanitizer strips
  // (zero-width / control) survived the pre-sanitize
  // fallback as a non-empty name and was then emptied,
  // birthing a blank-named profile. Only empty names are
  // touched; positions are the batch indexes, as above.
  for (var i = 0; i < out.length; i++) {
    if (out[i].name.isEmpty) out[i].name = _fallbackName(out[i], i);
  }
  if (out.length > kMaxImportedProfiles) {
    // The excess profiles' names stand in for their lines
    // in BOTH lists, keeping the two lists index-aligned.
    final excess = out.skip(kMaxImportedProfiles).map((p) => p.name).toList();
    skipped.addAll(excess);
    skippedRaw.addAll(excess);
    out.removeRange(kMaxImportedProfiles, out.length);
  }
  return (profiles: out, skipped: skipped, skippedRaw: skippedRaw);
}

Profile? parseLink(String rawLink) {
  final parsed = _parseLinkRaw(rawLink);
  // Build 2095 (fourth-pass audit 4.1/2.1): the boundary
  // validation lives HERE, at the single-link choke
  // point, so every route that parses one link — paste,
  // scan, deep link, share — gets the same repairs as
  // the bulk paths.
  return parsed == null ? null : sanitizeImportedProfile(parsed);
}

Profile? _parseLinkRaw(String rawLink) {
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
  // The sidecar protocols (build 2075): naive+https is the
  // NaiveProxy project's own link form; snell and mieru
  // links follow the same authority shape.
  if (link.startsWith('naive+https://') || link.startsWith('naive://')) {
    return _naive(link);
  }
  if (link.startsWith('snell://')) return _snell(link);
  if (link.startsWith('mieru://')) return _mieruLink(link);
  if (link.startsWith('tailscale://')) return _tailscale(link);
  if (link.startsWith('openconnect://')) return _openconnect(link);
  if (link.startsWith('sudoku://')) return _sudoku(link);
  // Build 2147 (feature #6): ssh://user:password@host:port#name
  // — the sing-box sidecar's ssh outbound, behind the
  // sidecarSshEnabled settings gate at connect time.
  if (link.startsWith('ssh://')) return _ssh(link);
  if (link.startsWith('anytls://')) return _anytls(link);
  if (link.startsWith('socks://') || link.startsWith('socks5://')) {
    return _socks(link);
  }
  if (link.startsWith('http://') || link.startsWith('https://')) {
    // Build 2097 (post-2096 audit C-L8): a subscription
    // URL is not an HTTP proxy link. A URL carrying a path
    // beyond the root or a query string is a subscription
    // endpoint (host:port/path?token=…) — parsing it as a
    // proxy discarded the path and added a dead "proxy"
    // pointing at the subscription host. Proxy links are
    // bare authority URLs (optionally user:pass@host:port,
    // optional #name); anything else returns null here and
    // the caller's subscription handling owns it.
    final uri = Uri.tryParse(link);
    if (uri != null &&
        ((uri.path.isNotEmpty && uri.path != '/') || uri.hasQuery)) {
      return null;
    }
    return _http(link);
  }
  return null;
}

/// Parses a full subscription body (raw, base64 or a config-JSON array).
/// [skipClash] (build 2098, post-2097 audit L9): the caller
/// already ran the Clash importer over this exact text and
/// it yielded nothing — do not run the same full parse again
/// on the fall-through.
List<Profile> parseSubscription(String body, {bool skipClash = false}) {
  // The subscription may be a JSON config array, a raw link list, or
  // either of those base64-encoded.
  for (final variant in [body, if (b64decode(body) != null) b64decode(body)!]) {
    final asConfig = _parseConfigJson(variant);
    if (asConfig != null) {
      // Build 2103 (diagnosis N1; ordering per verification
      // iteration 1, L3): sanitize FIRST, then the
      // positional fallback — a remarks/tag made only of
      // characters the sanitizer strips would otherwise
      // survive the fallback as a non-empty name and be
      // emptied afterwards, birthing the blank title over
      // the address subtitle N1 exists to eliminate.
      final out = asConfig.map(sanitizeImportedProfile).toList();
      for (var i = 0; i < out.length; i++) {
        out[i].name = _fallbackName(out[i], i);
      }
      return out;
    }
    // Clash YAML documents (build 2075, feature item 21):
    // a `proxies:` body is not a link list — route it to the
    // Clash importer before the link scan finds nothing.
    if (!skipClash && looksLikeClashYaml(variant)) {
      final clash = parseClashYaml(variant, newProfileId);
      if (clash.profiles.isNotEmpty) return clash.profiles;
    }
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
      // Build 2095 (fourth-pass audit 1.3): per-entry —
      // one mis-typed outbound ("port": "443") skips that
      // entry instead of aborting the whole document
      // behind the generic format message.
      try {
        final profile = _outboundToProfile(d);
        if (profile != null) out.add(profile);
      } catch (_) {
        continue;
      }
    }
    // Build 2103 (diagnosis N1): a profile this route
    // could not name (no remarks, no outbound tag) gets
    // the positional name from parseSubscription, applied
    // after sanitizing (verification iteration 1, L3) —
    // never '' (a blank title over the address subtitle
    // is how the owner's panel configs read as "named by
    // their address").
    return out.isEmpty ? null : out;
  } catch (_) {
    return null;
  }
}


/// A JSON port read that tolerates the string spelling
/// real exporters produce (build 2095, fourth-pass audit
/// 1.3): num, or a numeric String, else [fallback].
int _jsonPort(Object? v, int fallback) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? fallback;
  return fallback;
}

/// Build 2103 (diagnosis N1): the per-config display name
/// a panel JSON document carries — its top-level `remarks`
/// field — is read here, over the outbound-tag name the
/// inner parse captured. Until 2102 NOTHING in the app
/// read `remarks`, so every profile born on this route
/// had name '' and showed as a blank title over its
/// address subtitle — the owner's "configs are named by
/// their server address", unhealable by refresh because
/// every refresh re-parsed through the same route.
Profile? _outboundToProfile(Map<String, dynamic> config) {
  final profile = _profileFromOutbounds(config);
  if (profile == null) return null;
  final remarks = config['remarks'];
  if (remarks is String && remarks.trim().isNotEmpty) {
    profile.name = remarks.trim();
  }
  return profile;
}

Profile? _profileFromOutbounds(Map<String, dynamic> config) {
  final outbounds = config['outbounds'];
  if (outbounds is! List) return null;
  for (final o in outbounds) {
    if (o is! Map<String, dynamic>) continue;
    final protocol = o['protocol'] as String?;
    final settings = (o['settings'] as Map?)?.cast<String, dynamic>() ?? {};
    final stream = (o['streamSettings'] as Map?)?.cast<String, dynamic>() ?? {};
    Profile base(Protocol p) {
      final profile = Profile(id: newProfileId(), protocol: p);
      // Build 2103 (diagnosis N1): the producing outbound's
      // tag is the profile's name of second resort — the
      // wrapper above overrides it with the config's
      // `remarks` when the document carries one, and
      // parseSubscription applies the positional fallback
      // when neither exists.
      final tag = o['tag'];
      if (tag is String && tag.trim().isNotEmpty) {
        profile.name = tag.trim();
      }
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
      // Splits a stream-settings headers map (build 2116,
      // audit G-17): Host lands in [Profile.host] as before;
      // every other entry is kept as JSON in
      // [Profile.transportHeaders] — builds ≤2115 dropped
      // them whole, so a CDN-fronted profile lost the extra
      // headers its server requires.
      void splitHeaders(dynamic raw) {
        if (raw is! Map) return;
        final rest = <String, dynamic>{};
        for (final e in raw.entries) {
          final key = e.key.toString();
          if (key.toLowerCase() == 'host') {
            final v = e.value;
            profile.host = v is List
                ? (v.isEmpty ? '' : v.first.toString())
                : (v?.toString() ?? '');
          } else {
            rest[key] = e.value;
          }
        }
        if (rest.isNotEmpty) profile.transportHeaders = jsonEncode(rest);
      }

      final ws = (stream['wsSettings'] as Map?)?.cast<String, dynamic>();
      if (ws != null) {
        profile.path = ws['path'] as String? ?? '';
        splitHeaders(ws['headers']);
        // WS early data (build 2116, audit G-03).
        final ed = ws['maxEarlyData'];
        if (ed is num && ed > 0) profile.wsEarlyData = ed.toInt();
      }
      final httpupgrade =
          (stream['httpupgradeSettings'] as Map?)?.cast<String, dynamic>();
      if (httpupgrade != null) {
        splitHeaders(httpupgrade['headers']);
      }
      final http = (stream['httpSettings'] as Map?)?.cast<String, dynamic>();
      if (http != null) {
        splitHeaders(http['headers']);
      }
      // XHTTP `extra` (build 2116, audit G-02): a raw core
      // JSON carrying the object keeps it, as JSON text —
      // the same field the link route stores.
      final xhttp = (stream['xhttpSettings'] as Map?)?.cast<String, dynamic>();
      if (xhttp != null) {
        final extraRaw = xhttp['extra'];
        if (extraRaw is Map) {
          profile.xhttpExtra = jsonEncode(extraRaw);
        } else if (extraRaw is String && extraRaw.isNotEmpty) {
          profile.xhttpExtra = extraRaw;
        }
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
        profile.port = _jsonPort(vnext['port'], 443);
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
        profile.port = _jsonPort(server['port'], 443);
        profile.uuidOrPassword = server['password'] as String? ?? '';
        profile.method = server['method'] as String? ?? '';
        return profile;
      case 'socks':
        final server = _firstMap(settings['servers']);
        if (server == null) continue;
        final profile = base(Protocol.socks);
        profile.address = server['address'] as String? ?? '';
        profile.port = _jsonPort(server['port'], 1080);
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
        profile.port = _jsonPort(server['port'], 8080);
        final user = _firstMap(server['users']);
        profile.username = user?['user'] as String? ?? '';
        profile.uuidOrPassword = user?['pass'] as String? ?? '';
        return profile;
      case 'wireguard':
        // Build 2095 (fourth-pass audit 3.7): the JSON
        // route gains the WireGuard outbound — full-config
        // exports from other tools carry it, and the
        // generic format message hid a standard document.
        final profile = base(Protocol.wireguard);
        profile.secretKey = settings['secretKey'] as String? ?? '';
        final addresses = settings['address'];
        if (addresses is List && addresses.isNotEmpty) {
          profile.localAddress = addresses.first.toString();
        }
        profile.mtu = (settings['mtu'] as num?)?.toInt() ?? 1420;
        final reservedList = settings['reserved'];
        if (reservedList is List) {
          profile.reserved = reservedList
              .map((e) => (e as num?)?.toInt().toString() ?? '')
              .join(',');
        }
        final peer = _firstMap(settings['peers']);
        if (peer != null) {
          profile.peerPublicKey = peer['publicKey'] as String? ?? '';
          profile.preSharedKey = peer['preSharedKey'] as String? ?? '';
          profile.keepAlive = (peer['keepAlive'] as num?)?.toInt() ?? 0;
          final endpoint = peer['endpoint'] as String? ?? '';
          final colon = endpoint.lastIndexOf(':');
          if (colon > 0) {
            profile.address = endpoint.substring(0, colon);
            profile.port =
                int.tryParse(endpoint.substring(colon + 1)) ?? 51820;
          } else {
            profile.address = endpoint;
            profile.port = 51820;
          }
          final allowed = peer['allowedIPs'];
          if (allowed is List) {
            profile.wgAllowedIPs = allowed.join(',');
          }
        }
        return profile;
      case 'hysteria':
        // Build 2095 (audit 3.7): the hysteria outbound
        // (version 2 in the bundled core's JSON shape).
        final profile = base(Protocol.hysteria2);
        profile.address = settings['address'] as String? ?? '';
        profile.port = _jsonPort(settings['port'], 443);
        final hs =
            (stream['hysteriaSettings'] as Map?)?.cast<String, dynamic>();
        if (hs != null) {
          profile.uuidOrPassword = hs['auth'] as String? ?? '';
        }
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
  // XHTTP `extra` (build 2116, audit G-02): the parameter
  // carries the extra xhttpSettings object as JSON text —
  // stored verbatim; the builder decodes and merges it,
  // ignoring a value that is not a JSON object, so a bad
  // link can never break a connect over it.
  final extra = q['extra'];
  if (extra != null && extra.isNotEmpty) p.xhttpExtra = extra;
  // WebSocket early data (build 2116, audit G-03): the
  // `ed` parameter — the maxEarlyData byte count. A value
  // that does not parse, or is not positive, is ignored.
  final ed = int.tryParse(q['ed'] ?? '');
  if (ed != null && ed > 0) p.wsEarlyData = ed;
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
    // Build 2095 (audit 4b-3): the link's own ALPN wins;
    // 'h3' is only the default when it carries none.
    alpn: q['alpn'] ?? 'h3',
  );
  // Build 2095 (audit 4b-3): fp lands as the fingerprint —
  // or as the pin when the value is one (the legacy
  // overloaded-field rule, mirrored from the writer).
  final hyFp = q['fp'] ?? '';
  if (hyFp.isNotEmpty) {
    if (isValidTlsCertPin(hyFp)) {
      p.tlsCertPin = hyFp;
    } else {
      p.fingerprint = hyFp;
    }
  }
  p.obfs = q['obfs'] ?? '';
  p.obfsPassword = q['obfs-password'] ?? q['obfsPassword'] ?? '';
  // Build 2095 (fourth-pass audit 3.4): port hopping is
  // carried, not applied — see Profile.hyMport.
  p.hyMport = q['mport'] ?? '';
  // Build 2126 (D1): the gecko packet-size band, under
  // the spellings the link generators use — 3x-ui's
  // camelCase, the hyphenated form, and the plain
  // min/max packet names. Carried always; applied only
  // under the geckoPacketSizes setting (singbox_config).
  int geckoSize(String a, String b, String c) =>
      int.tryParse(q[a] ?? q[b] ?? q[c] ?? '') ?? 0;
  p.geckoMinPacketSize = geckoSize(
    'geckoMinPacketSize',
    'gecko-min-packet-size',
    'minPacketSize',
  );
  p.geckoMaxPacketSize = geckoSize(
    'geckoMaxPacketSize',
    'gecko-max-packet-size',
    'maxPacketSize',
  );
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
/// Parsed and stored like TUIC. The bundled Xray core has no
/// AnyTLS outbound (verified in its source), so the profile
/// connects through the sing-box sidecar instead (build
/// 2089 — sing-box 1.14.4's anytls outbound, verified by
/// `sing-box check`). The userinfo is the password; there is
/// no username in the standard form.
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
  // Build 2116 (audit G-19): ECH, as in _tuic.
  p.echConfigList = q['ech'] ?? '';
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
  p.awgS3 = q['s3'] ?? '';
  p.awgS4 = q['s4'] ?? '';
  p.awgH1 = q['h1'] ?? '';
  p.awgH2 = q['h2'] ?? '';
  p.awgH3 = q['h3'] ?? '';
  p.awgH4 = q['h4'] ?? '';
  // Build 2098 (Item A): the signature family, read back
  // the same way the codec writes it.
  p.awgI1 = q['i1'] ?? '';
  p.awgI2 = q['i2'] ?? '';
  p.awgI3 = q['i3'] ?? '';
  p.awgI4 = q['i4'] ?? '';
  p.awgI5 = q['i5'] ?? '';
  p.awgJ1 = q['j1'] ?? '';
  p.awgJ2 = q['j2'] ?? '';
  p.awgJ3 = q['j3'] ?? '';
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
  // Build 2116 (audit G-19): the ECH parameter, stored
  // verbatim like the other parsers'; the sidecar TLS
  // block emits the base64 form (singbox_config).
  p.echConfigList = q['ech'] ?? '';
  // Build 2116 (audit G-21): the TUIC extras panels
  // publish — carried into the sing-box outbound, the
  // only engine that serves TUIC.
  bool truthy(String? v) =>
      v == '1' || v?.toLowerCase() == 'true' || v?.toLowerCase() == 'yes';
  p.zeroRttHandshake = truthy(
    q['zero_rtt_handshake'] ?? q['zeroRttHandshake'],
  );
  p.tuicHeartbeat = q['heartbeat'] ?? '';
  p.udpOverStream = truthy(q['udp_over_stream'] ?? q['udpOverStream']);
  p.disableSni = truthy(q['disable_sni'] ?? q['disableSni']);
  // Build 2116 (audit S-01): allow_insecure stays ignored
  // for the Xray core (build 2048 removed it there), but
  // TUIC is served by sing-box, which honours the flag —
  // dropping it silently broke links that depend on it.
  // Only the link's own flag is carried, never a default.
  p.tuicAllowInsecure = truthy(
    q['allow_insecure'] ?? q['allowInsecure'] ?? q['insecure'],
  );
  return p;
}

/// NaiveProxy links (build 2075):
///   naive+https://user:pass@host:port#name
/// The project's own share form. Extra query parameters
/// (padding etc.) ride [Profile.naiveExtraParams] since
/// build 2116 (audit S-02): the sing-box emitter applies
/// the subset it supports and the rest is journaled at
/// connect, instead of being dropped silently at import.
Profile? _naive(String link) {
  final a = link.startsWith('naive+https://')
      ? _authority(link, 'naive+https')
      : _authority(link, 'naive');
  if (a == null || a.host.isEmpty) return null;
  final cred = a.userInfo;
  final colon = cred.indexOf(':');
  final p = Profile(
    id: newProfileId(),
    protocol: Protocol.naive,
    name: a.name,
    address: a.host,
    port: a.port,
    username: colon >= 0 ? cred.substring(0, colon) : cred,
    uuidOrPassword: colon >= 0 ? cred.substring(colon + 1) : '',
    security: 'tls',
  );
  final q = _queryParams(a.query);
  p.sni = q['sni'] ?? q['peer'] ?? '';
  // Build 2116 (audit S-02): every parameter the model
  // does not consume is stored verbatim (see the header).
  final extras = {
    for (final e in q.entries)
      if (e.key != 'sni' && e.key != 'peer') e.key: e.value,
  };
  if (extras.isNotEmpty) p.naiveExtraParams = jsonEncode(extras);
  return p;
}

/// Snell links (build 2075), the panel form:
///   snell://psk@host:port?version=4&obfs=http&obfs-host=h#name
Profile? _snell(String link) {
  final a = _authority(link, 'snell');
  if (a == null || a.host.isEmpty) return null;
  final p = Profile(
    id: newProfileId(),
    protocol: Protocol.snell,
    name: a.name,
    address: a.host,
    port: a.port,
    uuidOrPassword: a.userInfo,
  );
  final q = _queryParams(a.query);
  p.snellVersion = int.tryParse(q['version'] ?? '') ?? 4;
  p.obfs = q['obfs'] ?? '';
  p.obfsPassword = q['obfs-host'] ?? q['obfs_host'] ?? '';
  return p;
}

/// Mieru links (build 2075), the panel form:
///   mieru://user:pass@host:port?transport=tcp#name
/// The upstream app itself exchanges full config JSON;
/// this covers the URI form panels emit.
Profile? _mieruLink(String link) {
  final a = _authority(link, 'mieru');
  if (a == null || a.host.isEmpty) return null;
  final cred = a.userInfo;
  final colon = cred.indexOf(':');
  final p = Profile(
    id: newProfileId(),
    protocol: Protocol.mieru,
    name: a.name,
    address: a.host,
    port: a.port,
    username: colon >= 0 ? cred.substring(0, colon) : cred,
    uuidOrPassword: colon >= 0 ? cred.substring(colon + 1) : '',
  );
  final q = _queryParams(a.query);
  final transport = (q['transport'] ?? '').toLowerCase();
  if (transport == 'udp' || transport == 'tcp') p.network = transport;
  return p;
}

/// Tailscale links (build 2075): Ember's own round-trip
/// form — `tailscale://<auth-key>@tailnet#name`. The endpoint
/// needs no server address; the auth key is the credential.
/// Parsed by hand: _authority insists on a host:port, and a
/// tailnet endpoint has neither.
Profile? _tailscale(String link) {
  var rest = link.substring('tailscale://'.length);
  var name = '';
  final hash = rest.indexOf('#');
  if (hash >= 0) {
    name = _percentDecode(rest.substring(hash + 1));
    rest = rest.substring(0, hash);
  }
  final at = rest.lastIndexOf('@');
  if (at < 0) return null;
  final key = _percentDecode(rest.substring(0, at));
  if (key.isEmpty) return null;
  return Profile(
    id: newProfileId(),
    protocol: Protocol.tailscale,
    name: name,
    tailscaleAuthKey: key,
  );
}

/// Sudoku links (build 2127, H2): Ember's own round-trip
/// form — `sudoku://<key>@host:port?aead_method=…#name`,
/// the option query keys mirroring the core's own option
/// names (option/h_sudoku.go). No cross-app link standard
/// for Sudoku exists; the profile editor is the primary
/// entry, this form exists so a Sudoku profile can be
/// shared and re-imported without losing its tuning.
Profile? _sudoku(String link) {
  final a = _authority(link, 'sudoku');
  if (a == null || a.host.isEmpty) return null;
  final q = _queryParams(a.query);
  final opts = <String, dynamic>{};
  final aead = q['aead_method'] ?? '';
  if (aead.isNotEmpty) opts['aeadMethod'] = aead;
  final padMin = int.tryParse(q['padding_min'] ?? '');
  if (padMin != null) opts['paddingMin'] = padMin;
  final padMax = int.tryParse(q['padding_max'] ?? '');
  if (padMax != null) opts['paddingMax'] = padMax;
  final table = q['table_type'] ?? '';
  if (table.isNotEmpty) opts['tableType'] = table;
  final pure = q['pure_downlink'];
  if (pure == '1' || pure == 'true') opts['pureDownlink'] = true;
  if (pure == '0' || pure == 'false') opts['pureDownlink'] = false;
  final customTable = q['custom_table'] ?? '';
  if (customTable.isNotEmpty) opts['customTable'] = customTable;
  if (q['http_mask'] == '1' || q['http_mask'] == 'true') {
    opts['httpMask'] = true;
    final mode = q['http_mask_mode'] ?? '';
    if (mode.isNotEmpty) opts['httpMaskMode'] = mode;
    final host = q['http_mask_host'] ?? '';
    if (host.isNotEmpty) opts['httpMaskHost'] = host;
    final path = q['http_mask_path'] ?? '';
    if (path.isNotEmpty) opts['httpMaskPathRoot'] = path;
  }
  return Profile(
    id: newProfileId(),
    protocol: Protocol.sudoku,
    name: a.name,
    address: a.host,
    port: a.port,
    uuidOrPassword: a.userInfo,
    sudokuOptions: opts.isEmpty ? '' : jsonEncode(opts),
  );
}

/// OpenConnect links (build 2075):
///   openconnect://user:pass@host:port#name
Profile? _openconnect(String link) {
  final a = _authority(link, 'openconnect');
  if (a == null || a.host.isEmpty) return null;
  final cred = a.userInfo;
  final colon = cred.indexOf(':');
  return Profile(
    id: newProfileId(),
    protocol: Protocol.openconnect,
    name: a.name,
    address: a.host,
    port: a.port,
    username: colon >= 0 ? cred.substring(0, colon) : cred,
    uuidOrPassword: colon >= 0 ? cred.substring(colon + 1) : '',
  );
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
/// Build 2147 (feature #6): an ssh:// link — userinfo is
/// user[:password]; the port defaults to 22 when the link
/// carries none (the shared _authority parser requires an
/// explicit port, so the no-port shape is retried with the
/// default appended). A private key cannot ride a link; it
/// is added in the editor.
Profile? _ssh(String link) {
  var a = _authority(link, 'ssh');
  if (a == null) {
    // No userinfo and/or no port: rebuild the authority with
    // the default port and retry once.
    final rest = link.substring('ssh://'.length);
    final hash = rest.indexOf('#');
    final frag = hash >= 0 ? rest.substring(hash) : '';
    var main = hash >= 0 ? rest.substring(0, hash) : rest;
    final q = main.indexOf('?');
    final query = q >= 0 ? main.substring(q) : '';
    if (q >= 0) main = main.substring(0, q);
    final at = main.lastIndexOf('@');
    final hostPart = at >= 0 ? main.substring(at + 1) : main;
    if (!hostPart.contains(':') && !hostPart.startsWith('[')) {
      final rebuilt =
          'ssh://${at >= 0 ? '${main.substring(0, at + 1)}' : ''}'
          '$hostPart:22$query$frag';
      a = _authority(rebuilt, 'ssh');
    }
  }
  if (a == null || a.host.isEmpty) return null;
  final ui = a.userInfo;
  final cut = ui.indexOf(':');
  return Profile(
    id: newProfileId(),
    name: a.name,
    protocol: Protocol.ssh,
    address: a.host,
    port: a.port,
    sshUser: cut >= 0 ? ui.substring(0, cut) : ui,
    sshPassword: cut >= 0 ? ui.substring(cut + 1) : '',
  );
}

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
    }
    // Build 2095 (audit 4b-2): mode reads unconditionally,
    // and the JSON's authority/REALITY/flow fields land —
    // the writer has carried some of these for other
    // protocols; the VMess JSON reader dropped them all.
    p.mode = j['mode'] as String? ?? '';
    p.grpcAuthority = j['authority'] as String? ?? '';
    p.publicKey = j['pbk'] as String? ?? '';
    p.shortId = j['sid'] as String? ?? '';
    p.spiderX = j['spx'] as String? ?? '';
    p.pqv = j['pqv'] as String? ?? '';
    p.flow = j['flow'] as String? ?? '';
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
