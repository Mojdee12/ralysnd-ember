/// Build 2048 gates, host side: dropping `allowInsecure` entirely.
///
/// The bundled core (patterniha/xray-core @ 12fd84e = XTLS v26.11.1)
/// removed `allowInsecure` — setting the key makes the core refuse
/// the whole config — so build 2047's toggle was a latent bug: a
/// profile (or the global setting) with it on could not connect at
/// all. Build 2048 removes the toggle from the editor and settings,
/// the field from Profile and XraySettings, and the parameter from
/// the parser and the share-link codec.
///
/// Build 2149 SUPERSESSION (diagnosis D3, owner order): the
/// population the 2048 removal stranded — TLS links whose origin
/// presents a self-signed / wrong-name cert and whose link
/// therefore carries allowInsecure=1 — could never connect in
/// Ember while v2rayNG honours the flag. From 2149 the flag is
/// parsed into Profile.allowInsecure, stored, re-exported on
/// share links, and emitted into the generated config ONLY when
/// set; the default stays secure (the first group below still
/// pins that no config carries the key when the flag is unset).
/// The parser/store/share groups are rewritten to the D3
/// behaviour. OPEN DEVICE QUESTION, recorded plainly: whether
/// the currently bundled core accepts the key again (the 2048
/// refusal finding above) is only provable on device with a
/// self-signed-origin config; the host side pins the ordered
/// parse/store/emit behaviour either way.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

/// True when any map in [node] — at any depth — has [key].
bool containsKeyDeep(Object? node, String key) {
  if (node is Map) {
    if (node.containsKey(key)) return true;
    return node.values.any((v) => containsKeyDeep(v, key));
  }
  if (node is List) return node.any((v) => containsKeyDeep(v, key));
  return false;
}

Profile tlsProfile(String id, String address) => Profile(
  id: id,
  protocol: Protocol.vless,
  name: 't',
  address: address,
  port: 443,
  uuidOrPassword: '11111111-1111-1111-1111-111111111111',
  security: 'tls',
  sni: address,
);

Profile hy2Profile() => Profile(
  id: 'h',
  protocol: Protocol.hysteria2,
  name: 'h',
  address: 'h.example.com',
  port: 443,
  uuidOrPassword: 'pw',
  sni: 'h.example.com',
);

void main() {
  group('The builder emits allowInsecure only when set (2048, '
      'as amended by 2149 D3)', () {
    test('a TLS VLESS tunnel config carries no such key anywhere', () {
      final cfg = decode(
        buildTunnelConfig(tlsProfile('a', 'a.example.com'), XraySettings()),
      );
      expect(containsKeyDeep(cfg, 'allowInsecure'), isFalse);
    });

    test('a TLS Trojan tunnel config carries no such key anywhere', () {
      final p = tlsProfile('a', 'a.example.com')
        ..protocol = Protocol.trojan
        ..uuidOrPassword = 'secret';
      final cfg = decode(buildTunnelConfig(p, XraySettings()));
      expect(containsKeyDeep(cfg, 'allowInsecure'), isFalse);
    });

    test('a Hysteria2 tunnel config carries no such key anywhere', () {
      final cfg = decode(buildTunnelConfig(hy2Profile(), XraySettings()));
      expect(containsKeyDeep(cfg, 'allowInsecure'), isFalse);
    });

    test('the delay-test config carries no such key anywhere', () {
      final cfg = decode(
        buildTestConfig(tlsProfile('a', 'a.example.com'), XraySettings()),
      );
      expect(containsKeyDeep(cfg, 'allowInsecure'), isFalse);
    });

    test('a REALITY profile carries no such key anywhere', () {
      final p = tlsProfile('a', 'a.example.com')
        ..security = 'reality'
        ..publicKey = 'public-key'
        ..shortId = 'short-id';
      final cfg = decode(buildTunnelConfig(p, XraySettings()));
      expect(containsKeyDeep(cfg, 'allowInsecure'), isFalse);
    });
  });

  group('The parser honours the parameter (2149 D3)', () {
    test('a vless link with allowInsecure=1 imports, flags and '
        'builds with the key', () {
      final p = parseLink(
        'vless://11111111-1111-1111-1111-111111111111@a.example.com:443'
        '?security=tls&allowInsecure=1#srv',
      );
      expect(p, isNotNull);
      expect(p!.allowInsecure, isTrue);
      final cfg = decode(buildTunnelConfig(p, XraySettings()));
      expect(containsKeyDeep(cfg, 'allowInsecure'), isTrue);
    });

    test('a trojan link with insecure=1 imports, flags and '
        'builds with the key', () {
      final p = parseLink(
        'trojan://secret@a.example.com:443?security=tls&insecure=1#srv',
      );
      expect(p, isNotNull);
      expect(p!.allowInsecure, isTrue);
      final cfg = decode(buildTunnelConfig(p, XraySettings()));
      expect(containsKeyDeep(cfg, 'allowInsecure'), isTrue);
    });

    test('a hysteria2 link with insecure=1 imports, flags and '
        'builds with the key', () {
      final p = parseLink('hysteria2://pw@h.example.com:443?insecure=1#h');
      expect(p, isNotNull);
      expect(p!.allowInsecure, isTrue);
      final cfg = decode(buildTunnelConfig(p, XraySettings()));
      expect(containsKeyDeep(cfg, 'allowInsecure'), isTrue);
    });

    test('an anytls link with insecure=1 still imports (badged, not '
        'built)', () {
      final p = parseLink(
        'anytls://secretpw@at.example.com:8443/'
        '?security=tls&sni=at.example.com&insecure=1#AT',
      );
      expect(p, isNotNull);
      expect(p!.protocol, Protocol.anytls);
      expect(buildOutbound(p, XraySettings()), isNull);
    });

    test('a tuic link with allow_insecure=1 still imports', () {
      final p = parseLink(
        'tuic://pw:method@tu.example.com:443?allow_insecure=1#t',
      );
      expect(p, isNotNull);
      expect(p!.protocol, Protocol.tuic);
    });

    test('a vmess JSON with allowInsecure/insecure imports and '
        'flags (2149 D3)', () {
      final j = {
        'v': '2',
        'ps': 'srv',
        'add': 'a.example.com',
        'port': '443',
        'id': '11111111-1111-1111-1111-111111111111',
        'aid': '0',
        'net': 'tcp',
        'type': 'none',
        'tls': 'tls',
        'allowInsecure': true,
        'insecure': 1,
      };
      final link = 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
      final p = parseLink(link);
      expect(p, isNotNull);
      expect(p!.allowInsecure, isTrue);
      final cfg = decode(buildTunnelConfig(p, XraySettings()));
      expect(containsKeyDeep(cfg, 'allowInsecure'), isTrue);
    });

    test('a raw core JSON with tlsSettings.allowInsecure imports '
        'and flags (2149 D3)', () {
      final profiles = parseSubscription(jsonEncode({
        'outbounds': [
          {
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'a.example.com',
                  'port': 443,
                  'users': [
                    {
                      'id': '11111111-1111-1111-1111-111111111111',
                      'flow': '',
                    },
                  ],
                },
              ],
            },
            'streamSettings': {
              'network': 'tcp',
              'security': 'tls',
              'tlsSettings': {'allowInsecure': true},
            },
          },
        ],
      }));
      expect(profiles.length, 1);
      expect(profiles.first.allowInsecure, isTrue);
      final cfg = decode(buildTunnelConfig(profiles.first, XraySettings()));
      expect(containsKeyDeep(cfg, 'allowInsecure'), isTrue);
    });
  });

  group(
    'Share links and stores carry it when set (2149 D3)',
    () {
      test('a link rebuilt from an insecure=1 import keeps the '
          'parameter', () {
        final p = parseLink(
          'vless://11111111-1111-1111-1111-111111111111@a.example.com:443'
          '?security=tls&allowInsecure=1#srv',
        )!;
        final link = profileToLink(p);
        expect(link, contains('allowInsecure=1'));
        final back = parseLink(link);
        expect(back, isNotNull);
        expect(back!.allowInsecure, isTrue);
        final cfg = decode(buildTunnelConfig(back, XraySettings()));
        expect(containsKeyDeep(cfg, 'allowInsecure'), isTrue);
      });

      test('a stored profile JSON with the key loads it as the '
          'D3 field', () {
        final stored = tlsProfile('a', 'a.example.com').toJson()
          ..['allowInsecure'] = true;
        final p = Profile.fromJson(stored);
        expect(p.name, 't');
        expect(p.address, 'a.example.com');
        expect(p.allowInsecure, isTrue);
        expect(p.toJson()['allowInsecure'], isTrue);
        final cfg = decode(buildTunnelConfig(p, XraySettings()));
        expect(containsKeyDeep(cfg, 'allowInsecure'), isTrue);
      });

      test('stored settings JSON with the key still loads', () {
        final stored = XraySettings().toJson()..['allowInsecure'] = true;
        final s = XraySettings.fromJson(stored);
        expect(s.enableUdp, isTrue);
        expect(s.toJson().containsKey('allowInsecure'), isFalse);
      });
    },
  );
}
