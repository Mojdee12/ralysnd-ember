/// Build 2096 — post-2095 audit, batch A: the validation
/// module stops flattening values it should preserve or
/// fail closed on.
///
/// H1 Mieru `udp` flipped to `tcp` by the network
/// whitelist; H2 AWG range values digit-stripped
/// ("5-10" → "510"); M1 REALITY-over-QUIC/KCP silently
/// rewritten at the boundary (moved to emit time); M2
/// vision flow stripped on the `raw` TCP alias; M3 Snell
/// v5 admitted though sing-box 1.14.4 refuses it; M5
/// localName bypassed the name sanitizer; M16 string
/// ports in store documents fell back to 443; L26 an
/// unknown security value was downgraded to plaintext;
/// L27 an all-dropped AllowedIPs list silently reverted
/// to the full-tunnel default.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/mieru_config.dart';
import 'package:firefox_vpn/xray/profile_validation.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Profile _p({
  Protocol protocol = Protocol.vless,
  String network = 'tcp',
  String security = 'tls',
}) => Profile(
  id: 'x',
  protocol: protocol,
  name: 'n',
  address: 'h.example.com',
  port: 443,
  uuidOrPassword: 'u',
  network: network,
  security: security,
);

void main() {
  group('H1 — Mieru transport survives the boundary', () {
    test('a mieru:// link with transport=udp keeps udp end to end', () {
      final p = parseLink(
        'mieru://user:pass@mi.example.com:2023?transport=udp#M',
      )!;
      expect(p.network, 'udp');
      final cfg = buildMieruConfig(p);
      final servers =
          ((cfg['profiles'] as List).single as Map)['servers'] as List;
      final binding =
          ((servers.single as Map)['portBindings'] as List).single as Map;
      expect(binding['protocol'], 'UDP');
    });

    test('sanitize, store round-trip and copy() all keep udp', () {
      final p = _p(protocol: Protocol.mieru, network: 'udp');
      sanitizeImportedProfile(p);
      expect(p.network, 'udp');
      final restored = Profile.fromJson(p.toJson());
      expect(restored.network, 'udp');
      expect(restored.copy().network, 'udp');
    });

    test('a non-Mieru profile still gets the Xray whitelist', () {
      final p = _p(network: 'udp');
      sanitizeImportedProfile(p);
      expect(p.network, 'tcp');
    });
  });

  group('H2 — AWG ranges are preserved, injection is not', () {
    test('a documented range survives sanitize and reaches the hand-off', () {
      final p = _p(protocol: Protocol.wireguard)
        ..awgH1 = '5-10'
        ..awgJc = '7';
      sanitizeImportedProfile(p);
      expect(p.awgH1, '5-10');
      expect(p.awgJc, '7');
      p.secretKey = 'aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGxvaGU=';
      p.peerPublicKey = 'aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGxvaGU=';
      // Build 2104: the hand-off is the .conf text now.
      expect(wgConfFromProfile(p).contains('H1 = 5-10'), isTrue);
    });

    test('a reversed range is ordered, junk reduces safely', () {
      expect(sanitizeAwgParam('10-5'), '5-10');
      expect(sanitizeAwgParam('5\n6'), '56');
      expect(sanitizeAwgParam('abc'), '');
      expect(sanitizeAwgParam('5-10-15'), '5');
      final injected = sanitizeAwgParam('5\nallowed_ip=0.0.0.0/0');
      expect(injected.contains('\n'), isFalse);
      expect(injected.contains('='), isFalse);
    });
  });

  group('M1/M2/L26 — security and flow honesty', () {
    test('REALITY over QUIC stays REALITY on the profile', () {
      final p = _p(network: 'quic', security: 'reality');
      sanitizeImportedProfile(p);
      expect(p.security, 'reality');
      expect(p.hasRealityTransportMismatch, isTrue);
      final tcp = _p(network: 'tcp', security: 'reality');
      expect(tcp.hasRealityTransportMismatch, isFalse);
    });

    test('vision flow survives on the raw TCP alias', () {
      final p = parseLink(
        'vless://11111111-1111-1111-1111-111111111111@h.example.com:443'
        '?type=raw&security=reality&flow=xtls-rprx-vision#N',
      )!;
      expect(p.network, 'raw');
      expect(p.flow, 'xtls-rprx-vision');
    });

    test('an unknown security value fails closed to tls, never plaintext', () {
      final p = _p(security: 'weird');
      sanitizeImportedProfile(p);
      expect(p.security, 'tls');
      final plain = _p(security: '');
      sanitizeImportedProfile(plain);
      expect(plain.security, '');
      final none = _p(security: 'none');
      sanitizeImportedProfile(none);
      expect(none.security, 'none');
    });
  });

  group('M3 — Snell v5 clamps to the core maximum', () {
    test('sanitize and link import both cap at 4', () {
      final p = _p(protocol: Protocol.snell)..snellVersion = 5;
      sanitizeImportedProfile(p);
      expect(p.snellVersion, 4);
      final linked = parseLink('snell://psk@h.example.com:443?version=5#S')!;
      expect(linked.snellVersion, 4);
    });
  });

  group('M5/M16 — the store read path', () {
    test('localName loses control characters at fromJson', () {
      final j = _p().toJson();
      j['localName'] = 'evil\nname\u202Espoof';
      final restored = Profile.fromJson(j);
      expect(restored.localName.contains('\n'), isFalse);
      expect(restored.localName.contains('\u202E'), isFalse);
      expect(restored.displayName, restored.localName);
    });

    test('a string port in a stored document is parsed, not defaulted', () {
      final j = _p().toJson();
      j['port'] = '51820';
      expect(Profile.fromJson(j).port, 51820);
      j['port'] = 'banana';
      expect(Profile.fromJson(j).port, 443);
    });
  });

  group('L27 — AllowedIPs hygiene never hides a full-tunnel revert', () {
    test('all-dropped entries become the explicit full-tunnel list', () {
      final p = _p(protocol: Protocol.wireguard)
        ..wgAllowedIPs = '10.0.0.0/8 10.1.0.0/16';
      sanitizeImportedProfile(p);
      expect(p.wgAllowedIPs, '0.0.0.0/0, ::/0');
    });

    test('a clean split list is untouched', () {
      final p = _p(protocol: Protocol.wireguard)
        ..wgAllowedIPs = '10.0.0.0/8, 192.168.0.0/16';
      sanitizeImportedProfile(p);
      expect(p.wgAllowedIPs, '10.0.0.0/8,192.168.0.0/16');
    });
  });
}
