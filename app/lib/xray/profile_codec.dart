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
  if (p.security.isNotEmpty) {
    q['security'] = p.security;
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
    if (p.publicKey.isNotEmpty) q['pbk'] = p.publicKey;
    if (p.shortId.isNotEmpty) q['sid'] = p.shortId;
    if (p.spiderX.isNotEmpty) q['spx'] = p.spiderX;
    // REALITY PQ verification (build 2057, audit F-M13).
    if (p.security == 'reality' && p.pqv.isNotEmpty) {
      q['pqv'] = p.pqv;
    }
    // No allowInsecure parameter (build 2048): the core removed
    // the feature, so a shared link must not carry it.
  }
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
        'scy': p.scy.isNotEmpty ? p.scy : 'auto',
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
        if (p.network == 'grpc' && p.mode.isNotEmpty) 'mode': p.mode,
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
      final cred = base64.encode(utf8.encode('${p.method}:${p.uuidOrPassword}'))
          .replaceAll('=', '');
      final plugin = p.plugin.isNotEmpty ? '?plugin=${_enc(p.plugin)}' : '';
      return 'ss://$cred@${_authorityOf(p)}$plugin#$name';
    case Protocol.hysteria2:
      final q = <String, String>{};
      if (p.sni.isNotEmpty) q['sni'] = p.sni;
      if (p.obfs.isNotEmpty) {
        q['obfs'] = p.obfs;
        if (p.obfsPassword.isNotEmpty) q['obfs-password'] = p.obfsPassword;
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
      if (p.awgH1.isNotEmpty) q['h1'] = p.awgH1;
      if (p.awgH2.isNotEmpty) q['h2'] = p.awgH2;
      if (p.awgH3.isNotEmpty) q['h3'] = p.awgH3;
      if (p.awgH4.isNotEmpty) q['h4'] = p.awgH4;
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
        final cred = base64
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
  }
}

/// The subscription-refresh identity of a profile (build 2047):
/// its share link without the display name — and without a
/// user-added certificate pin. The pin is the user's local edit,
/// like the label and the star, not part of the provider's
/// identity: if it stayed in the identity, a pinned subscription
/// profile would never match its refreshed self, and the refresh
/// would drop its pin, totals, star and label together. A profile
/// without a pin is identical to [profileToLink] minus the name.
String profileIdentityLink(Profile p) {
  final link = profileToLink(p).split('#').first;
  if (!isValidTlsCertPin(p.tlsCertPin)) return link;
  // Query-param links (vless/trojan): drop the pin parameter.
  // Hysteria2 pins ride `pinSHA256` (build 2053) — dropped the
  // same way, so a user-added pin never breaks refresh identity.
  final q = link.indexOf('?');
  if (q >= 0) {
    final kept = link
        .substring(q + 1)
        .split('&')
        .where(
          (e) =>
              !e.startsWith('pinnedPeerCertSha256=') &&
              !e.startsWith('pinSHA256='),
        )
        .toList();
    return kept.isEmpty
        ? link.substring(0, q)
        : '${link.substring(0, q)}?${kept.join('&')}';
  }
  // VMess links carry the pin inside the base64 JSON: decode,
  // drop the key, re-encode. The JSON is Ember's own encoding,
  // so the re-encoded form matches the fresh profile's link
  // exactly (same key order, same values).
  if (link.startsWith('vmess://')) {
    try {
      final j = (jsonDecode(
        utf8.decode(base64.decode(link.substring('vmess://'.length))),
      ) as Map)
          .cast<String, dynamic>();
      j.remove('pinnedPeerCertSha256');
      return 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
    } catch (_) {
      return link;
    }
  }
  return link;
}
