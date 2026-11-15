/// Build 2033 gates, host side: AnyTLS parse/store/badge
/// parity with TUIC, ECH for Hysteria2 (+ the mixed-case SNI
/// trick on its handshake), the DNS group section, AmneziaWG
/// parameter preservation (import → store → export), and the
/// WireGuard load-path fixes (BOM tolerance, inline comments,
/// per-entry store decode). The Kumiho sign-in swap and the
/// engines are native/device-side; their evidence is the
/// packaging gates and the owner's device test.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

void main() {
  group('AnyTLS (#31)', () {
    test('parses, stores and round-trips like TUIC', () {
      final p = parseLink(
        'anytls://secretpw@at.example.com:8443/'
        '?security=tls&sni=at.example.com&fp=chrome&insecure=1#AT%20one',
      );
      expect(p, isNotNull);
      expect(p!.protocol, Protocol.anytls);
      expect(p.protocol.label, 'AnyTLS');
      expect(p.address, 'at.example.com');
      expect(p.port, 8443);
      expect(p.uuidOrPassword, 'secretpw');
      expect(p.sni, 'at.example.com');
      // Build 2048: insecure=1 is ignored — the core removed the
      // feature — so the profile imports without it, and the
      // share link carries no insecure parameter either.
      expect(profileToLink(p), isNot(contains('insecure')));
      // The bundled core has no AnyTLS outbound: parsed,
      // stored and shareable, never connectable.
      expect(p.protocol.supportedByCore, isFalse);
      expect(buildOutbound(p, XraySettings()), isNull);
      final back = parseLink(profileToLink(p));
      expect(back!.protocol, Protocol.anytls);
      expect(back.uuidOrPassword, 'secretpw');
      expect(back.sni, 'at.example.com');
    });
  });

  group('ECH for Hysteria2 (#8) + TLS tricks (#10)', () {
    Profile hy2() => Profile(
      id: 'h1',
      protocol: Protocol.hysteria2,
      name: 'hy2',
      address: 'hy.example.com',
      port: 443,
      uuidOrPassword: 'pw',
      sni: 'Cdn.Example.COM',
    );

    test('the link ech parameter lands on the profile', () {
      final p = parseLink(
        'hysteria2://pw@hy.example.com:443'
        '?ech=cloudflare-ech.com%2Budp%3A%2F%2F1.1.1.1#h',
      );
      expect(p!.echConfigList, 'cloudflare-ech.com+udp://1.1.1.1');
      final back = parseLink(profileToLink(p));
      expect(back!.echConfigList, p.echConfigList);
    });

    test('the outbound carries echConfigList in its TLS settings', () {
      final p = hy2()..echConfigList = 'cloudflare-ech.com+udp://1.1.1.1';
      final out = buildOutbound(p, XraySettings())!;
      final tls = (out['streamSettings'] as Map)['tlsSettings'] as Map;
      expect(tls['echConfigList'], 'cloudflare-ech.com+udp://1.1.1.1');
    });

    test('no ech parameter, no echConfigList key', () {
      final out = buildOutbound(hy2(), XraySettings())!;
      final tls = (out['streamSettings'] as Map)['tlsSettings'] as Map;
      expect(tls.containsKey('echConfigList'), isFalse);
    });

    test('mixed-case SNI reshapes the hysteria server name', () {
      final p = hy2()..afMixedSni = true;
      final out = buildOutbound(p, XraySettings())!;
      final tls = (out['streamSettings'] as Map)['tlsSettings'] as Map;
      final name = tls['serverName'] as String;
      expect(name, isNot('Cdn.Example.COM'));
      expect(name.toLowerCase(), 'cdn.example.com');
    });
  });

  group('DNS group (#12)', () {
    Profile tlsProfile() => Profile(
      id: 't1',
      protocol: Protocol.vless,
      name: 't',
      address: 'v.example.com',
      port: 443,
      uuidOrPassword: '00000000-0000-0000-0000-000000000000',
      security: 'tls',
      sni: 'v.example.com',
    );

    test('group on: primary plus the member resolvers, in order', () {
      final s = XraySettings()..dnsGroup = true;
      final dns = decode(buildTunnelConfig(tlsProfile(), s))['dns'] as Map;
      final servers = (dns['servers'] as List).cast<String>();
      expect(servers.first, s.remoteDns);
      for (final member in dnsGroupMembers) {
        expect(servers, contains(member));
      }
      // No duplicates even though Quad9 is also the fallback.
      expect(servers.toSet().length, servers.length);
    });

    test('group off: the single-fallback behaviour is unchanged', () {
      final s = XraySettings()
        ..dnsFallback = true
        ..fallbackDns = 'https://dns.quad9.net/dns-query';
      final dns = decode(buildTunnelConfig(tlsProfile(), s))['dns'] as Map;
      final servers = (dns['servers'] as List).cast<String>();
      expect(servers, [s.remoteDns, 'https://dns.quad9.net/dns-query']);
    });

    test('the group setting round-trips through settings JSON', () {
      final s = XraySettings()..dnsGroup = true;
      final back = XraySettings.fromJson(s.toJson());
      expect(back.dnsGroup, isTrue);
    });
  });

  group('AmneziaWG preservation (#27)', () {
    const conf = '''
[Interface]
PrivateKey = YAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 10.8.0.2/32
Jc = 5
Jmin = 40
Jmax = 70
S1 = 90
S2 = 110
H1 = 111
H2 = 222
H3 = 333
H4 = 444

[Peer]
PublicKey = HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0
''';

    test('.conf import stores the parameters on the profile', () {
      var n = 0;
      final r = parseWgConf(conf, baseName: 'awg', idFor: () => 'w${n++}');
      expect(r.ok, isTrue);
      final p = r.profiles.single;
      expect(p.hasAmneziaParams, isTrue);
      expect(p.awgJc, '5');
      expect(p.awgJmin, '40');
      expect(p.awgJmax, '70');
      expect(p.awgS1, '90');
      expect(p.awgS2, '110');
      expect(p.awgH1, '111');
      expect(p.awgH4, '444');
    });

    test('the parameters survive store JSON and link export', () {
      var n = 0;
      final p = parseWgConf(
        conf,
        baseName: 'awg',
        idFor: () => 'w${n++}',
      ).profiles.single;
      final stored = Profile.fromJson(p.toJson());
      expect(stored.awgJc, '5');
      expect(stored.awgH3, '333');
      final link = profileToLink(p);
      expect(link, contains('jc=5'));
      expect(link, contains('h4=444'));
      final back = parseLink(link)!;
      expect(back.awgJmin, '40');
      expect(back.awgS2, '110');
    });
  });

  group('WireGuard load-path fixes', () {
    const conf = '''
[Interface]
PrivateKey = YAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 10.8.0.2/32

[Peer]
PublicKey = HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0
''';

    test('a BOM does not hide the [Interface] section', () {
      var n = 0;
      final r = parseWgConf(
        '\uFEFF$conf',
        baseName: 'bom',
        idFor: () => 'b${n++}',
      );
      expect(r.ok, isTrue);
      expect(r.profiles, hasLength(1));
    });

    test('an inline comment after the endpoint keeps the peer', () {
      var n = 0;
      final commented = conf.replaceFirst(
        'Endpoint = 203.0.113.10:51820',
        'Endpoint = 203.0.113.10:51820 # frankfurt',
      );
      final r = parseWgConf(
        commented,
        baseName: 'c',
        idFor: () => 'c${n++}',
      );
      expect(r.ok, isTrue);
      expect(r.profiles.single.port, 51820);
    });
  });

  group('profile store resilience', () {
    test('new fields default cleanly on old stored JSON', () {
      final old = Profile(
        id: 'x',
        protocol: Protocol.hysteria2,
        name: 'old',
        address: 'a.example.com',
        port: 443,
      ).toJson()
        ..remove('echConfigList')
        ..remove('awgJc');
      final p = Profile.fromJson(old);
      expect(p.echConfigList, '');
      expect(p.hasAmneziaParams, isFalse);
    });
  });
}
