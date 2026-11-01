/// A profile back to its share link (export, QR display, copy).

import 'dart:convert';

import 'xray_models.dart';

String _enc(String s) => Uri.encodeComponent(s);

Map<String, String> _transportParams(Profile p) {
  final q = <String, String>{};
  if (p.network != 'tcp') q['type'] = p.network;
  if (p.headerType.isNotEmpty) q['headerType'] = p.headerType;
  if (p.host.isNotEmpty) q['host'] = p.host;
  if (p.path.isNotEmpty) q['path'] = p.path;
  if (p.serviceName.isNotEmpty) q['serviceName'] = p.serviceName;
  if (p.mode.isNotEmpty) q['mode'] = p.mode;
  if (p.security.isNotEmpty) {
    q['security'] = p.security;
    if (p.sni.isNotEmpty) q['sni'] = p.sni;
    if (p.alpn.isNotEmpty) q['alpn'] = p.alpn;
    if (p.fingerprint.isNotEmpty) q['fp'] = p.fingerprint;
    if (p.publicKey.isNotEmpty) q['pbk'] = p.publicKey;
    if (p.shortId.isNotEmpty) q['sid'] = p.shortId;
    if (p.spiderX.isNotEmpty) q['spx'] = p.spiderX;
    if (p.allowInsecure) q['allowInsecure'] = '1';
  }
  if (p.flow.isNotEmpty) q['flow'] = p.flow;
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
      q.putIfAbsent('encryption', () => 'none');
      final qs = _query(q);
      return 'vless://${_enc(p.uuidOrPassword)}@${p.address}:${p.port}?$qs#$name';
    case Protocol.trojan:
      final qs = _query(_transportParams(p));
      return 'trojan://${_enc(p.uuidOrPassword)}@${p.address}:${p.port}?$qs#$name';
    case Protocol.vmess:
      final j = <String, dynamic>{
        'v': '2',
        'ps': p.name,
        'add': p.address,
        'port': p.port.toString(),
        'id': p.uuidOrPassword,
        'aid': '0',
        'scy': 'auto',
        'net': p.network,
        'type': p.headerType,
        'host': p.host,
        'path': p.network == 'grpc' ? p.serviceName : p.path,
        'tls': p.security,
        'sni': p.sni,
        'alpn': p.alpn,
        'fp': p.fingerprint,
      };
      return 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
    case Protocol.shadowsocks:
      final cred = base64.encode(utf8.encode('${p.method}:${p.uuidOrPassword}'))
          .replaceAll('=', '');
      final plugin = p.plugin.isNotEmpty ? '?plugin=${_enc(p.plugin)}' : '';
      return 'ss://$cred@${p.address}:${p.port}$plugin#$name';
    case Protocol.hysteria2:
      final q = <String, String>{};
      if (p.sni.isNotEmpty) q['sni'] = p.sni;
      if (p.obfs.isNotEmpty) {
        q['obfs'] = p.obfs;
        if (p.obfsPassword.isNotEmpty) q['obfs-password'] = p.obfsPassword;
      }
      if (p.allowInsecure) q['insecure'] = '1';
      final qs = _query(q);
      return 'hysteria2://${_enc(p.uuidOrPassword)}@${p.address}:${p.port}${qs.isEmpty ? '' : '?$qs'}#$name';
    case Protocol.wireguard:
      final q = <String, String>{};
      if (p.peerPublicKey.isNotEmpty) q['publickey'] = p.peerPublicKey;
      if (p.preSharedKey.isNotEmpty) q['presharedkey'] = p.preSharedKey;
      if (p.localAddress.isNotEmpty) q['address'] = p.localAddress;
      if (p.reserved.isNotEmpty) q['reserved'] = p.reserved;
      q['mtu'] = p.mtu.toString();
      final qs = _query(q);
      return 'wireguard://${_enc(p.secretKey)}@${p.address}:${p.port}?$qs#$name';
    case Protocol.tuic:
      final q = <String, String>{};
      if (p.congestionControl.isNotEmpty) {
        q['congestion_control'] = p.congestionControl;
      }
      if (p.udpRelayMode.isNotEmpty) q['udp_relay_mode'] = p.udpRelayMode;
      if (p.sni.isNotEmpty) q['sni'] = p.sni;
      if (p.allowInsecure) q['allow_insecure'] = '1';
      final qs = _query(q);
      final cred = p.method.isNotEmpty
          ? '${_enc(p.uuidOrPassword)}:${_enc(p.method)}'
          : _enc(p.uuidOrPassword);
      return 'tuic://$cred@${p.address}:${p.port}${qs.isEmpty ? '' : '?$qs'}#$name';
    case Protocol.socks:
      // With credentials: SIP002-style base64 userinfo, the form the
      // parser prefers, so export -> import is stable. Without: the
      // bare host:port form.
      if (p.username.isNotEmpty) {
        final cred = base64
            .encode(utf8.encode('${p.username}:${p.uuidOrPassword}'))
            .replaceAll('=', '');
        return 'socks://$cred@${p.address}:${p.port}#$name';
      }
      return 'socks://${p.address}:${p.port}#$name';
  }
}
