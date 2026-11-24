/// Build 2148 FIX 6 — OFF-state config-generation comparison
/// harness. This file is dropped IDENTICALLY into the
/// audit-snapshot-2146 and audit-snapshot-2147 trees and run
/// in each; it dumps the generated core configs for a
/// representative fixture set under DEFAULT settings (every
/// 2147 toggle OFF) to fix6_dump_2148.txt in the package root.
/// The two dumps must be byte-identical.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/singbox_config.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

void main() {
  test('fix6 dump', () {
    final s = XraySettings();
    final out = StringBuffer();
    void dump(String label, Object? value) {
      out.writeln('===== $label');
      out.writeln(value is String ? value : jsonEncode(value));
    }

    dump('settings-defaults', s.toJson());

    // Fugui-style: VLESS + Reality over a HOSTNAME, fp=ios —
    // the owner's acceptance shape.
    final fugui = Profile(
      id: 'fx1',
      name: 'Fugui style',
      protocol: Protocol.vless,
      address: 'free.example.lol',
      port: 443,
      uuidOrPassword: '11111111-2222-3333-4444-555555555555',
      security: 'reality',
      network: 'tcp',
      sni: 'www.microsoft.com',
      fingerprint: 'ios',
      publicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      shortId: 'ab12',
      flow: 'xtls-rprx-vision',
    );
    dump('vless-reality-host', buildTunnelConfig(fugui, s));

    // The same profile parsed from its share link (the
    // import path a real fugui config takes).
    const fuguiLink =
        'vless://11111111-2222-3333-4444-555555555555@free.example.lol:443'
        '?security=reality&sni=www.microsoft.com&fp=ios'
        '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=ab12'
        '&flow=xtls-rprx-vision&type=tcp#Fugui%20style';
    final parsed = parseLink(fuguiLink);
    dump('fugui-parsed-profile', parsed?.toJson());
    if (parsed != null) {
      dump('fugui-parsed-config', buildTunnelConfig(parsed, s));
    }

    final vlessIp = Profile(
      id: 'fx2',
      name: 'VLESS IP',
      protocol: Protocol.vless,
      address: '203.0.113.10',
      port: 8443,
      uuidOrPassword: '11111111-2222-3333-4444-555555555555',
      security: 'reality',
      network: 'tcp',
      sni: 'cdn.example.com',
      fingerprint: 'chrome',
      publicKey: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
      flow: 'xtls-rprx-vision',
    );
    dump('vless-reality-ip', buildTunnelConfig(vlessIp, s));

    final vmess = Profile(
      id: 'fx3',
      name: 'VMess WS',
      protocol: Protocol.vmess,
      address: 'vm.example.net',
      port: 443,
      uuidOrPassword: '11111111-2222-3333-4444-555555555555',
      security: 'tls',
      network: 'ws',
      host: 'vm.example.net',
      path: '/ray',
      sni: 'vm.example.net',
    );
    dump('vmess-ws-tls', buildTunnelConfig(vmess, s));

    final trojan = Profile(
      id: 'fx4',
      name: 'Trojan',
      protocol: Protocol.trojan,
      address: 'tj.example.net',
      port: 443,
      uuidOrPassword: 'secret-password',
      security: 'tls',
      network: 'tcp',
      sni: 'tj.example.net',
    );
    dump('trojan-tls', buildTunnelConfig(trojan, s));

    final ss = Profile(
      id: 'fx5',
      name: 'SS',
      protocol: Protocol.shadowsocks,
      address: 'ss.example.net',
      port: 8388,
      uuidOrPassword: 'ss-password',
      method: 'aes-256-gcm',
    );
    dump('shadowsocks', buildTunnelConfig(ss, s));

    final hy2 = Profile(
      id: 'fx6',
      name: 'Hy2',
      protocol: Protocol.hysteria2,
      address: 'hy.example.net',
      port: 443,
      uuidOrPassword: 'hy-password',
      security: 'tls',
      sni: 'hy.example.net',
    );
    dump('hy2-singbox', jsonEncode(buildSingBoxConfig(hy2)));
    dump(
      'hy2-tunnel-sidecar',
      buildTunnelConfig(hy2, s, sidecarSocksPort: 20850),
    );

    File('fix6_dump_2148.txt').writeAsStringSync(out.toString());
  });
}
