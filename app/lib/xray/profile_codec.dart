/// A profile back to its share link (export, QR display, copy).

import 'dart:convert';

import 'tls_cert_pin.dart';
import 'vless_encryption.dart';
import 'xray_models.dart';

String _enc(String s) => Uri.encodeComponent(s);

/// The authority part of a share link (build 2057, audit
/// F-M12): an IPv6-literal server must be bracketed, or the
/// export→import round-trip produces an unparseable link — the
/// parser requires brackets for v6. Every codec branch builds
/// its authority through here; the builder already brackets.
String _authorityOf(Profile p) =>
    p.address.contains(':') ? '[${p.address}]:${p.port}' : '${p.address}:${p.port}';

Map<String, String> _transportParams(Profile p) {
  final q = <String, String>{};
  if (p.network != 'tcp') q['type'] = p.network;
  if (p.headerType.isNotEmpty) q['headerType'] = p.headerType;
  // QUIC transport (build 2057, audit §6 codec drop): the
  // standard parameters are `security` (the QUIC security) and
  // `key`, carried in host/path by the model — they are written
  // under their own names, never as host=/path=.
  if (p.network == 'quic') {
    if (p.host.isNotEmpty) q['security'] = p.host;
    if (p.path.isNotEmpty) q['key'] = p.path;
  } else {
    if (p.host.isNotEmpty) q['host'] = p.host;
    if (p.path.isNotEmpty) q['path'] = p.path;
  }
  if (p.serviceName.isNotEmpty) q['serviceName'] = p.serviceName;
  if (p.mode.isNotEmpty) q['mode'] = p.mode;
  if (p.security.isNotEmpty) q['security'] = p.security;
  // Build 2095 (third-pass audit 4b-1): the TLS fields emit
  // whenever they are SET — they used to ride inside the
  // security block, so a VLESS/Trojan profile whose stored
  // security was empty (or not yet normalized) silently
  // lost its SNI/ALPN/fingerprint/pin on share. Only the
  // REALITY set stays gated, on reality itself.
  if (p.sni.isNotEmpty) q['sni'] = p.sni;
  if (p.alpn.isNotEmpty) q['alpn'] = p.alpn;
  if (p.fingerprint.isNotEmpty) q['fp'] = p.fingerprint;
  if (p.cipherSuites.isNotEmpty) q['cs'] = p.cipherSuites;
  if (p.echConfigList.isNotEmpty) q['ech'] = p.echConfigList;
  // TLS certificate pin (build 2047): the stored value
  // round-trips into the link when valid; anything else —
  // including a corrupt stored value — writes nothing, as
  // before (a profile without a pin has no such parameter).
  if (isValidTlsCertPin(p.tlsCertPin)) {
    q['pinnedPeerCertSha256'] = p.tlsCertPin;
  }
  if (p.security == 'reality') {
    if (p.publicKey.isNotEmpty) q['pbk'] = p.publicKey;
    if (p.shortId.isNotEmpty) q['sid'] = p.shortId;
    if (p.spiderX.isNotEmpty) q['spx'] = p.spiderX;
    // REALITY PQ verification (build 2057, audit F-M13).
    if (p.pqv.isNotEmpty) q['pqv'] = p.pqv;
  }
  // No allowInsecure parameter (build 2048): the core removed
  // the feature, so a shared link must not carry it.
  // gRPC authority (build 2057, audit §6 codec drop).
  if (p.network == 'grpc' && p.grpcAuthority.isNotEmpty) {
    q['authority'] = p.grpcAuthority;
  }
  if (p.flow.isNotEmpty) q['flow'] = p.flow;
  // Anti-filter shaping (build 2057, audit §6 codec drop):
  // Ember's own parameters — a client that does not know them
  // ignores the unknown parameters.
  if (p.afUnfilter) q['afUnfilter'] = '1';
  if (p.afEch) q['afEch'] = '1';
  if (p.afMixedSni) q['afMixedSni'] = '1';
  if (p.afTcpNoise) q['afTcpNoise'] = '1';
  if (p.afFragment.isNotEmpty) q['afFragment'] = p.afFragment;
  // The patched core's exact-text fields (build 2030), under
  // the same parameter names PattNG uses: dialMode verbatim,
  // fm = the whole finalmask JSON.
  if (p.dialMode.isNotEmpty) q['dialMode'] = p.dialMode;
  if (p.finalMask.isNotEmpty) q['fm'] = p.finalMask;
  return q;
}

String _query(Map<String, String> q) => q.entries
    .map((e) => '${_enc(e.key)}=${_enc(e.value)}')
    .join('&');

String profileToLink(Profile p) {
  final name = _enc(p.name);
  switch (p.protocol) {
    case Protocol.vless:
      final q = _transportParams(p);
      // VLESS Encryption (build 2046): the stored value
      // round-trips into the link when valid; anything else —
      // including a corrupt stored value — writes
      // 'encryption=none', as before.
      q['encryption'] = isValidVlessEncryption(p.vlessEncryption)
          ? p.vlessEncryption
          : 'none';
      final qs = _query(q);
      return 'vless://${_enc(p.uuidOrPassword)}@${_authorityOf(p)}?$qs#$name';
    case Protocol.trojan:
      final qs = _query(_transportParams(p));
      return 'trojan://${_enc(p.uuidOrPassword)}@${_authorityOf(p)}?$qs#$name';
    case Protocol.vmess:
      final j = <String, dynamic>{
        'v': '2',
        'ps': p.name,
        'add': p.address,
        'port': p.port.toString(),
        'id': p.uuidOrPassword,
        // VMess aid/scy (build 2057, audit §6 codec drop): the
        // stored values, not the old hardcoded '0'/'auto' — a
        // non-zero alterId or a non-auto cipher survives sharing.
        'aid': p.aid.toString(),
        // Build 2095 (audit 4b-2): scy verbatim — the old
        // '' -> 'auto' transform rewrote the stored value
        // on every share.
        'scy': p.scy,
        'net': p.network,
        'type': p.headerType,
        'host': p.host,
        'path': p.network == 'grpc' ? p.serviceName : p.path,
        'tls': p.security,
        'sni': p.sni,
        'alpn': p.alpn,
        'fp': p.fingerprint,
        if (p.cipherSuites.isNotEmpty) 'cs': p.cipherSuites,
        // VMess gRPC mode + ECH (build 2057, audit §6 codec
        // drops): the mode re-imports as gun without this, and
        // the ECH list was never written for VMess.
        // Build 2095 (audit 4b-2): mode unconditional (the
        // reader no longer gates it on grpc either), plus
        // the fields the JSON never carried: gRPC authority,
        // the REALITY set and flow.
        if (p.mode.isNotEmpty) 'mode': p.mode,
        if (p.grpcAuthority.isNotEmpty) 'authority': p.grpcAuthority,
        if (p.publicKey.isNotEmpty) 'pbk': p.publicKey,
        if (p.shortId.isNotEmpty) 'sid': p.shortId,
        if (p.spiderX.isNotEmpty) 'spx': p.spiderX,
        if (p.pqv.isNotEmpty) 'pqv': p.pqv,
        if (p.flow.isNotEmpty) 'flow': p.flow,
        if (p.echConfigList.isNotEmpty) 'ech': p.echConfigList,
        // Anti-filter shaping (build 2057, audit §6 codec drop).
        if (p.afUnfilter) 'afUnfilter': true,
        if (p.afEch) 'afEch': true,
        if (p.afMixedSni) 'afMixedSni': true,
        if (p.afTcpNoise) 'afTcpNoise': true,
        if (p.afFragment.isNotEmpty) 'afFragment': p.afFragment,
        // TLS certificate pin (build 2047): the core's own field
        // name, written only when valid (see _transportParams).
        if (isValidTlsCertPin(p.tlsCertPin))
          'pinnedPeerCertSha256': p.tlsCertPin,
        if (p.dialMode.isNotEmpty) 'dialMode': p.dialMode,
        if (p.finalMask.isNotEmpty) 'fm': p.finalMask,
      };
      return 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
    case Protocol.shadowsocks:
      // Build 2095 (fourth-pass audit 3.6): SIP002
      // userinfo is base64URL — the standard alphabet's
      // '+'/'/' break strict parsers in other clients.
      final cred = base64Url
          .encode(utf8.encode('${p.method}:${p.uuidOrPassword}'))
          .replaceAll('=', '');
      final plugin = p.plugin.isNotEmpty ? '?plugin=${_enc(p.plugin)}' : '';
      return 'ss://$cred@${_authorityOf(p)}$plugin#$name';
    case Protocol.hysteria2:
      final q = <String, String>{};
      if (p.sni.isNotEmpty) q['sni'] = p.sni;
      if (p.obfs.isNotEmpty) q['obfs'] = p.obfs;
      // Build 2095 (audit 4b-3): the obfs password emits on
      // its own — it used to ride inside the obfs-type
      // block, so a profile with a password but no type
      // lost the password on share.
      if (p.obfsPassword.isNotEmpty) q['obfs-password'] = p.obfsPassword;
      // Build 2126 (D1): the gecko packet-size band rides
      // the link in the 3x-ui camelCase params, so a
      // shared profile keeps its band.
      if (p.geckoMinPacketSize > 0) {
        q['geckoMinPacketSize'] = '${p.geckoMinPacketSize}';
      }
      if (p.geckoMaxPacketSize > 0) {
        q['geckoMaxPacketSize'] = '${p.geckoMaxPacketSize}';
      }
      // Build 2095 (audit 4b-3): ALPN and the uTLS
      // fingerprint ride the link (a fingerprint that is a
      // certificate pin rides as pinSHA256 below instead).
      if (p.alpn.isNotEmpty) q['alpn'] = p.alpn;
      if (p.fingerprint.isNotEmpty &&
          !isValidTlsCertPin(p.fingerprint)) {
        q['fp'] = p.fingerprint;
      }
      // Bandwidth (build 2053, audit F-H6): the `up`/`down`
      // parameters are the standard Hy2 link fields — the
      // parser has read them since the first Hy2 import, but
      // the export never wrote them, so a shared profile lost
      // its bandwidth declaration. Only positive values are
      // exported; a zero means "undeclared", as before.
      if (p.upMbps > 0) q['up'] = '${p.upMbps}';
      if (p.downMbps > 0) q['down'] = '${p.downMbps}';
      // Certificate pin (build 2053, audit F-H5): exported
      // under the standard Hy2 parameter name `pinSHA256` so
      // other clients read it; the value is the profile's
      // tlsCertPin, with the legacy `fingerprint` pin honoured
      // the same way the builder honours it — a pre-2053
      // profile must not lose its pin on share.
      final hyPin = isValidTlsCertPin(p.tlsCertPin)
          ? p.tlsCertPin
          : (isValidTlsCertPin(p.fingerprint) ? p.fingerprint : '');
      if (hyPin.isNotEmpty) q['pinSHA256'] = hyPin;
      if (p.echConfigList.isNotEmpty) q['ech'] = p.echConfigList;
      if (hyCongestionChoices.contains(p.hyCongestion) &&
          p.hyCongestion.isNotEmpty) {
        q['congestion'] = p.hyCongestion;
      }
      final qs = _query(q);
      return 'hysteria2://${_enc(p.uuidOrPassword)}@${_authorityOf(p)}${qs.isEmpty ? '' : '?$qs'}#$name';
    case Protocol.wireguard:
      final q = <String, String>{};
      if (p.peerPublicKey.isNotEmpty) q['publickey'] = p.peerPublicKey;
      if (p.preSharedKey.isNotEmpty) q['presharedkey'] = p.preSharedKey;
      if (p.localAddress.isNotEmpty) q['address'] = p.localAddress;
      if (p.reserved.isNotEmpty) q['reserved'] = p.reserved;
      q['mtu'] = p.mtu.toString();
      // Persistent keepalive (build 2057, audit §6 codec drop):
      // the parser has read it since the first WireGuard import,
      // but the export never wrote it.
      if (p.keepAlive > 0) q['keepalive'] = p.keepAlive.toString();
      // The .conf's split-tunnel list and DNS (build 2057,
      // audit §6 WG .conf divergences): Ember's own parameter
      // names, read back by the parser.
      if (p.wgAllowedIPs.isNotEmpty) q['allowedips'] = p.wgAllowedIPs;
      if (p.wgDns.isNotEmpty) q['dns'] = p.wgDns;
      // The stored AmneziaWG parameters (build 2033) ride the
      // export so a client that can apply them receives them
      // intact; Ember's own parser reads them back the same way.
      if (p.awgJc.isNotEmpty) q['jc'] = p.awgJc;
      if (p.awgJmin.isNotEmpty) q['jmin'] = p.awgJmin;
      if (p.awgJmax.isNotEmpty) q['jmax'] = p.awgJmax;
      if (p.awgS1.isNotEmpty) q['s1'] = p.awgS1;
      if (p.awgS2.isNotEmpty) q['s2'] = p.awgS2;
      if (p.awgS3.isNotEmpty) q['s3'] = p.awgS3;
      if (p.awgS4.isNotEmpty) q['s4'] = p.awgS4;
      if (p.awgH1.isNotEmpty) q['h1'] = p.awgH1;
      if (p.awgH2.isNotEmpty) q['h2'] = p.awgH2;
      if (p.awgH3.isNotEmpty) q['h3'] = p.awgH3;
      if (p.awgH4.isNotEmpty) q['h4'] = p.awgH4;
      // Build 2098 (Item A): the signature family rides
      // the share link too, URL-encoded by _query.
      if (p.awgI1.isNotEmpty) q['i1'] = p.awgI1;
      if (p.awgI2.isNotEmpty) q['i2'] = p.awgI2;
      if (p.awgI3.isNotEmpty) q['i3'] = p.awgI3;
      if (p.awgI4.isNotEmpty) q['i4'] = p.awgI4;
      if (p.awgI5.isNotEmpty) q['i5'] = p.awgI5;
      if (p.awgJ1.isNotEmpty) q['j1'] = p.awgJ1;
      if (p.awgJ2.isNotEmpty) q['j2'] = p.awgJ2;
      if (p.awgJ3.isNotEmpty) q['j3'] = p.awgJ3;
      final qs = _query(q);
      return 'wireguard://${_enc(p.secretKey)}@${_authorityOf(p)}?$qs#$name';
    case Protocol.anytls:
      final q = <String, String>{'security': 'tls'};
      if (p.sni.isNotEmpty) q['sni'] = p.sni;
      if (p.alpn.isNotEmpty) q['alpn'] = p.alpn;
      if (p.fingerprint.isNotEmpty) q['fp'] = p.fingerprint;
      final qs = _query(q);
      return 'anytls://${_enc(p.uuidOrPassword)}@${_authorityOf(p)}?$qs#$name';
    case Protocol.tuic:
      final q = <String, String>{};
      if (p.congestionControl.isNotEmpty) {
        q['congestion_control'] = p.congestionControl;
      }
      if (p.udpRelayMode.isNotEmpty) q['udp_relay_mode'] = p.udpRelayMode;
      if (p.sni.isNotEmpty) q['sni'] = p.sni;
      // ALPN (build 2057, audit §6 codec drop): the parser has
      // read it since the first TUIC import, but the export never
      // wrote it.
      if (p.alpn.isNotEmpty) q['alpn'] = p.alpn;
      final qs = _query(q);
      final cred = p.method.isNotEmpty
          ? '${_enc(p.uuidOrPassword)}:${_enc(p.method)}'
          : _enc(p.uuidOrPassword);
      return 'tuic://$cred@${_authorityOf(p)}${qs.isEmpty ? '' : '?$qs'}#$name';
    case Protocol.socks:
      // With credentials: SIP002-style base64 userinfo, the form the
      // parser prefers, so export -> import is stable. A
      // password-only profile (build 2057, audit §6 codec drop)
      // used to export bare — dropping the password — because
      // the old code required a non-empty username; the base64
      // form carries `:password` fine. Without credentials: the
      // bare host:port form.
      if (p.username.isNotEmpty || p.uuidOrPassword.isNotEmpty) {
        // Build 2095 (audit 3.6): base64URL userinfo,
        // like the ss branch.
        final cred = base64Url
            .encode(utf8.encode('${p.username}:${p.uuidOrPassword}'))
            .replaceAll('=', '');
        return 'socks://$cred@${_authorityOf(p)}#$name';
      }
      return 'socks://${_authorityOf(p)}#$name';
    case Protocol.http:
      // HTTP proxy (build 2057, audit §6 codec drop): the same
      // userinfo@authority shape as SOCKS, under the http scheme.
      if (p.username.isNotEmpty || p.uuidOrPassword.isNotEmpty) {
        final cred =
            '${_enc(p.username)}:${_enc(p.uuidOrPassword)}';
        return 'http://$cred@${_authorityOf(p)}#$name';
      }
      return 'http://${_authorityOf(p)}#$name';
    case Protocol.naive:
      // NaiveProxy (build 2075): the project's own link form,
      // the same one the parser reads.
      final q = <String, String>{};
      if (p.sni.isNotEmpty) q['sni'] = p.sni;
      final qs = _query(q);
      final cred = p.uuidOrPassword.isNotEmpty
          ? '${_enc(p.username)}:${_enc(p.uuidOrPassword)}'
          : _enc(p.username);
      return 'naive+https://$cred@${_authorityOf(p)}${qs.isEmpty ? '' : '?$qs'}#$name';
    case Protocol.snell:
      // Snell (build 2075): the panel form the parser reads.
      final q = <String, String>{'version': '${p.snellVersion}'};
      if (p.obfs.isNotEmpty) q['obfs'] = p.obfs;
      if (p.obfsPassword.isNotEmpty) q['obfs-host'] = p.obfsPassword;
      return 'snell://${_enc(p.uuidOrPassword)}@${_authorityOf(p)}?${_query(q)}#$name';
    case Protocol.mieru:
      // Mieru (build 2075): the URI form the parser reads.
      final q = <String, String>{};
      // Build 2095 (audit 4b-4): the parser accepts only
      // tcp/udp — clamp the export to the same set instead
      // of writing a transport the reader would drop.
      if (p.network == 'tcp' || p.network == 'udp') {
        q['transport'] = p.network;
      }
      final qs = _query(q);
      final cred = p.uuidOrPassword.isNotEmpty
          ? '${_enc(p.username)}:${_enc(p.uuidOrPassword)}'
          : _enc(p.username);
      return 'mieru://$cred@${_authorityOf(p)}${qs.isEmpty ? '' : '?$qs'}#$name';
    case Protocol.tailscale:
      // Tailscale (build 2075): no cross-app link standard
      // exists; this form round-trips through Ember's own
      // parser (the auth key as userinfo, 'tailnet' as the
      // placeholder host — the endpoint needs no server).
      return 'tailscale://${_enc(p.tailscaleAuthKey)}@tailnet#$name';
    case Protocol.openconnect:
      // OpenConnect (build 2075): the userinfo@authority
      // shape, round-tripped by Ember's parser.
      final cred = p.uuidOrPassword.isNotEmpty
          ? '${_enc(p.username)}:${_enc(p.uuidOrPassword)}'
          : _enc(p.username);
      return 'openconnect://$cred@${_authorityOf(p)}#$name';
    case Protocol.sudoku:
      // Sudoku (build 2127, H2): Ember's own round-trip
      // form — the key as userinfo, the tuning as query
      // params under the core's own option names; read
      // back by the parser's _sudoku.
      final o = p.sudokuOpts;
      final q = <String, String>{};
      if (o['aeadMethod'] is String && (o['aeadMethod'] as String).isNotEmpty) {
        q['aead_method'] = o['aeadMethod'] as String;
      }
      if (o['paddingMin'] is num) {
        q['padding_min'] = '${(o['paddingMin'] as num).toInt()}';
      }
      if (o['paddingMax'] is num) {
        q['padding_max'] = '${(o['paddingMax'] as num).toInt()}';
      }
      if (o['tableType'] is String && (o['tableType'] as String).isNotEmpty) {
        q['table_type'] = o['tableType'] as String;
      }
      if (o['pureDownlink'] is bool) {
        q['pure_downlink'] = (o['pureDownlink'] as bool) ? '1' : '0';
      }
      if (o['customTable'] is String &&
          (o['customTable'] as String).isNotEmpty) {
        q['custom_table'] = o['customTable'] as String;
      }
      if (o['httpMask'] == true) {
        q['http_mask'] = '1';
        if (o['httpMaskMode'] is String &&
            (o['httpMaskMode'] as String).isNotEmpty) {
          q['http_mask_mode'] = o['httpMaskMode'] as String;
        }
        if (o['httpMaskHost'] is String &&
            (o['httpMaskHost'] as String).isNotEmpty) {
          q['http_mask_host'] = o['httpMaskHost'] as String;
        }
        if (o['httpMaskPathRoot'] is String &&
            (o['httpMaskPathRoot'] as String).isNotEmpty) {
          q['http_mask_path'] = o['httpMaskPathRoot'] as String;
        }
      }
      final qs = _query(q);
      return 'sudoku://${_enc(p.uuidOrPassword)}@${_authorityOf(p)}'
          '${qs.isEmpty ? '' : '?$qs'}#$name';
  }
}

/// The subscription-refresh identity of a profile (build 2047):
/// its share link without the display name — and without
/// the user's local edits (a certificate pin, the
/// anti-filter shaping). Those are the user's, like the
/// label and the star, not part of the provider's
/// identity: if they stayed in the identity, an edited
/// subscription profile would never match its refreshed
/// self, and the refresh would drop its pin, shaping,
/// totals, star and label together.
String profileIdentityLink(Profile p) {
  final link = profileToLink(p).split('#').first;
  // Build 2095 (third-pass audit 4c-1): the anti-filter
  // shaping values are the user's local edits too (the
  // editor sets them per profile) — with them in the
  // identity, a shaped profile never matched its refreshed
  // self and the refresh dropped the shaping, the totals
  // and the star together. They are stripped alongside
  // the pin, unconditionally.
  const stripParams = {
    'pinnedPeerCertSha256',
    'pinSHA256',
    'afUnfilter',
    'afEch',
    'afMixedSni',
    'afTcpNoise',
    'afFragment',
    // Build 2096 (post-2095 audit M12): the editor-set
    // Aether options are the user's local edits too —
    // with them in the identity, an edited profile never
    // matched its refreshed self and lost its totals,
    // star and label on the next refresh.
    'cs',
    'dialMode',
    'fm',
  };
  bool keptParam(String e) =>
      !stripParams.contains(e.split('=').first);
  final q = link.indexOf('?');
  if (q >= 0 && !link.startsWith('vmess://')) {
    final kept = link.substring(q + 1).split('&').where(keptParam).toList();
    return kept.isEmpty
        ? link.substring(0, q)
        : '${link.substring(0, q)}?${kept.join('&')}';
  }
  // VMess links carry the fields inside the base64 JSON:
  // decode, drop the keys, re-encode. The JSON is Ember's
  // own encoding, so the re-encoded form matches the fresh
  // profile's link exactly (same key order, same values).
  if (link.startsWith('vmess://')) {
    try {
      final j = (jsonDecode(
        utf8.decode(base64.decode(link.substring('vmess://'.length))),
      ) as Map)
          .cast<String, dynamic>();
      j.remove('pinnedPeerCertSha256');
      // Build 2097 (post-2096 audit C-L5): the provider
      // name is presentation, not identity — the fragment
      // strip above removes it for every other protocol,
      // but the VMess JSON carries it INSIDE the document
      // as 'ps', so a provider-side rename changed the
      // identity and the refresh carry lost the node's
      // totals, star and label.
      j.remove('ps');
      // Build 2096 (audit M12): the VMess JSON route
      // strips the same user-edit fields.
      j.remove('cs');
      j.remove('dialMode');
      j.remove('fm');
      j.remove('afUnfilter');
      j.remove('afEch');
      j.remove('afMixedSni');
      j.remove('afTcpNoise');
      j.remove('afFragment');
      return 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
    } catch (_) {
      return link;
    }
  }
  return link;
}

/// Build 2096 (post-2095 audit M11): the LEGACY VMess
/// identity — the identity link with the fields build
/// 2094's VMess reader dropped (the audit 4b-2 set:
/// mode, authority, pbk, sid, spx, pqv, flow) blanked. A
/// profile stored by 2094 carries those fields empty, so
/// its identity differs from the same node parsed fresh
/// by 2095+; the refresh carry's primary lookup misses
/// and the user's totals/star/label/id are lost on the
/// first refresh. Comparing legacy keys on both sides
/// finds the match. Used only as a fallback when the
/// primary identity lookup misses.
String legacyVmessIdentityLink(Profile p) {
  final c = Profile.fromJson(p.toJson());
  c.mode = '';
  c.grpcAuthority = '';
  c.publicKey = '';
  c.shortId = '';
  c.spiderX = '';
  c.pqv = '';
  c.flow = '';
  return profileIdentityLink(c);
}
