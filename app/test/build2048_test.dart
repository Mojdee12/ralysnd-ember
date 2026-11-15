/// Build 2048 gates, host side: dropping `allowInsecure` entirely.
///
/// The bundled core (patterniha/xray-core @ 12fd84e = XTLS v26.11.1)
/// removed `allowInsecure` — setting the key makes the core refuse
/// the whole config — so build 2047's toggle was a latent bug: a
/// profile (or the global setting) with it on could not connect at
/// all. Build 2048 removes the toggle from the editor and settings,
/// the field from Profile and XraySettings, and the parameter from
/// the parser and the share-link codec. These tests pin the Dart
/// side of that removal: no emitted config — tunnel or delay-test,
/// any TLS protocol — ever carries the key; links and raw core JSON
/// carrying the parameter still import and build clean; share links
/// never carry it; and stored data from older builds (a profile or
/// settings JSON with the key set) still loads, the key simply
/// ignored. The editor change itself is UI and is not host-testable
/// without a device.
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
  group('The builder never emits allowInsecure (build 2048)', () {
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

  group('The parser ignores the parameter (build 2048)', () {
    test('a vless link with allowInsecure=1 imports and builds clean',
        () {
      final p = parseLink(
        'vless://11111111-1111-1111-1111-111111111111@a.example.com:443'
        '?security=tls&allowInsecure=1#srv',
      );
      expect(p, isNotNull);
      final cfg = decode(buildTunnelConfig(p!, XraySettings()));
      expect(containsKeyDeep(cfg, 'allowInsecure'), isFalse);
    });

    test('a trojan link with insecure=1 imports and builds clean', () {
      final p = parseLink(
        'trojan://secret@a.example.com:443?security=tls&insecure=1#srv',
      );
      expect(p, isNotNull);
      final cfg = decode(buildTunnelConfig(p!, XraySettings()));
      expect(containsKeyDeep(cfg, 'allowInsecure'), isFalse);
    });

    test('a hysteria2 link with insecure=1 imports and builds clean',
        () {
      final p = parseLink('hysteria2://pw@h.example.com:443?insecure=1#h');
      expect(p, isNotNull);
      final cfg = decode(buildTunnelConfig(p!, XraySettings()));
      expect(containsKeyDeep(cfg, 'allowInsecure'), isFalse);
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

    test('a vmess JSON with allowInsecure/insecure still imports', () {
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
      final cfg = decode(buildTunnelConfig(p!, XraySettings()));
      expect(containsKeyDeep(cfg, 'allowInsecure'), isFalse);
    });

    test('a raw core JSON with tlsSettings.allowInsecure still '
        'imports', () {
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
      final cfg = decode(buildTunnelConfig(profiles.first, XraySettings()));
      expect(containsKeyDeep(cfg, 'allowInsecure'), isFalse);
    });
  });

  group(
    'Share links never carry it, and old stores still load (build 2048)',
    () {
      test('a link rebuilt from an insecure=1 import drops the '
          'parameter', () {
        final p = parseLink(
          'vless://11111111-1111-1111-1111-111111111111@a.example.com:443'
          '?security=tls&allowInsecure=1#srv',
        )!;
        final link = profileToLink(p);
        expect(link, isNot(contains('allowInsecure')));
        expect(link, isNot(contains('insecure')));
        final back = parseLink(link);
        expect(back, isNotNull);
        final cfg = decode(buildTunnelConfig(back!, XraySettings()));
        expect(containsKeyDeep(cfg, 'allowInsecure'), isFalse);
      });

      test('a stored profile JSON with the key still loads and builds '
          'clean', () {
        final stored = tlsProfile('a', 'a.example.com').toJson()
          ..['allowInsecure'] = true;
        final p = Profile.fromJson(stored);
        expect(p.name, 't');
        expect(p.address, 'a.example.com');
        expect(p.toJson().containsKey('allowInsecure'), isFalse);
        final cfg = decode(buildTunnelConfig(p, XraySettings()));
        expect(containsKeyDeep(cfg, 'allowInsecure'), isFalse);
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
