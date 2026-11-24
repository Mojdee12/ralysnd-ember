/// Build 2046 gates, host side: VLESS Encryption (mlkem768) end to
/// end (feature-watch 2026-11-05, Xray-core / 3x-ui link format).
/// The bundled core (patterniha/xray-core @ 12fd84e = XTLS v26.11.1)
/// runs an outbound VLESS user's `encryption` value of the form
/// `mlkem768x25519plus.<mode>.<rtt>.<key parts>` — but the app
/// dropped it: the parser ignored the link parameter, the builder
/// hardcoded 'none', and the share-link codec forced
/// 'encryption=none'. These tests pin the Dart side of the
/// contract: the validator mirrors the core's own rule (mode, RTT
/// and key-part shape — a value the core accepts must be storable,
/// a value it would refuse must never reach the emitted config),
/// the parser keeps a valid value from links and raw core JSON and
/// ignores an invalid one without losing the profile, the builder
/// emits the value verbatim (and 'none' for anything else, so a
/// corrupt store can never break a connect), and the share link
/// round-trips the value. The editor's save-time refusal of an
/// invalid value is UI and is not host-testable without a device,
/// so the tests pin the validator the editor calls. Only a device
/// test — import a real mlkem768 link, connect, confirm traffic
/// flows — proves the encrypted path against a real server.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/vless_encryption.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

/// A valid client encryption value: the scheme, a mode, an RTT,
/// and a base64url key of [keyBytes] bytes (32 = a seed, 1184 = a
/// ML-KEM-768 public key — the two sizes the core accepts).
String encValue({
  String mode = 'native',
  String rtt = '0rtt',
  int keyBytes = 32,
  String prefix = '',
}) {
  // base64url WITHOUT padding, as the core's RawURLEncoding reads
  // it (Dart's base64Url.encode pads; strip the '=' tail).
  final key = base64Url.encode(List.filled(keyBytes, 7)).replaceAll('=', '');
  final tail = prefix.isEmpty ? key : '$prefix.$key';
  return 'mlkem768x25519plus.$mode.$rtt.$tail';
}

Profile vless(String id, String address, {String? vlessEncryption}) =>
    Profile(
      id: id,
      protocol: Protocol.vless,
      name: 'a',
      address: address,
      port: 443,
      uuidOrPassword: '11111111-1111-1111-1111-111111111111',
      vlessEncryption: vlessEncryption ?? '',
    );

Map<String, dynamic> vlessUserOf(Profile p) {
  final cfg = decode(buildTunnelConfig(p, XraySettings()));
  final outbounds = cfg['outbounds'] as List;
  final proxy = outbounds.first as Map<String, dynamic>;
  final settings = proxy['settings'] as Map<String, dynamic>;
  final vnext = (settings['vnext'] as List).first as Map<String, dynamic>;
  return (vnext['users'] as List).first as Map<String, dynamic>;
}

void main() {
  group('The validator mirrors the core rule (build 2046)', () {
    test('accepts native/0rtt with a 32-byte key', () {
      expect(isValidVlessEncryption(encValue()), isTrue);
    });

    test('accepts xorpub/1rtt with an 1184-byte key', () {
      expect(
        isValidVlessEncryption(
          encValue(mode: 'xorpub', rtt: '1rtt', keyBytes: 1184),
        ),
        isTrue,
      );
    });

    test('accepts random mode and a short padding prefix', () {
      expect(
        isValidVlessEncryption(
          encValue(mode: 'random', prefix: 'pad'),
        ),
        isTrue,
      );
    });

    test('rejects a wrong scheme, mode, RTT, or too few parts', () {
      final key = base64Url.encode(List.filled(32, 7));
      expect(
        isValidVlessEncryption('mlkem768.native.0rtt.$key'),
        isFalse,
      );
      expect(
        isValidVlessEncryption(
          'mlkem768x25519plus.foo.0rtt.$key',
        ),
        isFalse,
      );
      expect(
        isValidVlessEncryption(
          'mlkem768x25519plus.native.2rtt.$key',
        ),
        isFalse,
      );
      expect(
        isValidVlessEncryption('mlkem768x25519plus.native.0rtt'),
        isFalse,
      );
      expect(isValidVlessEncryption(''), isFalse);
      expect(isValidVlessEncryption('none'), isFalse);
    });

    test('rejects a key part that decodes to the wrong length', () {
      // 16 bytes -> 22 base64url chars (unpadded), long enough to
      // be a key part, but the core only accepts 32 or 1184 bytes.
      final short =
          base64Url.encode(List.filled(16, 7)).replaceAll('=', '');
      expect(short.length, greaterThanOrEqualTo(20));
      expect(
        isValidVlessEncryption(
          'mlkem768x25519plus.native.0rtt.$short',
        ),
        isFalse,
      );
    });

    test('rejects a key part that is not base64url', () {
      expect(
        isValidVlessEncryption(
          'mlkem768x25519plus.native.0rtt.'
          'AAAAAAAAAAAAAAAAAAAAAAAAAAA!AAAAAAAAAAAAAAA',
        ),
        isFalse,
      );
    });

  });

  group('The parser keeps a valid encryption value (build 2046)', () {
    test('a vless link with a valid encryption value stores it', () {
      final value = encValue();
      final p = parseLink(
        'vless://11111111-1111-1111-1111-111111111111@a.example.com:443'
        '?encryption=$value#srv',
      );
      expect(p, isNotNull);
      expect(p!.vlessEncryption, value);
      expect(p.hasVlessEncryption, isTrue);
    });

    test('a vless link with an invalid value still imports, '
        'unencrypted', () {
      final p = parseLink(
        'vless://11111111-1111-1111-1111-111111111111@a.example.com:443'
        '?encryption=mlkem768x25519plus.native.0rtt.nope#srv',
      );
      expect(p, isNotNull);
      expect(p!.vlessEncryption, isEmpty);
      expect(p.hasVlessEncryption, isFalse);
    });

    test('encryption=none stores as no encryption', () {
      final p = parseLink(
        'vless://11111111-1111-1111-1111-111111111111@a.example.com:443'
        '?encryption=none#srv',
      );
      expect(p, isNotNull);
      expect(p!.vlessEncryption, isEmpty);
    });

    test('a raw core JSON import keeps a valid encryption value', () {
      final value = encValue(mode: 'xorpub', keyBytes: 1184);
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
                      'encryption': value,
                      'flow': '',
                    },
                  ],
                },
              ],
            },
            'streamSettings': {'network': 'tcp', 'security': 'tls'},
          },
        ],
      }));
      expect(profiles.length, 1);
      expect(profiles.first.vlessEncryption, value);
    });

    test('a raw core JSON import drops an invalid encryption value', () {
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
                      'encryption': 'mlkem768x25519plus.nope',
                    },
                  ],
                },
              ],
            },
            'streamSettings': {'network': 'tcp'},
          },
        ],
      }));
      expect(profiles.length, 1);
      expect(profiles.first.vlessEncryption, isEmpty);
    });
  });

  group('The builder emits the value, or none (build 2046)', () {
    test('an encrypted profile emits its value verbatim', () {
      final value = encValue();
      final user = vlessUserOf(vless('a', 'a.example.com',
          vlessEncryption: value));
      expect(user['encryption'], value);
      expect(user['id'], '11111111-1111-1111-1111-111111111111');
    });

    test('a profile without encryption still emits none', () {
      final user = vlessUserOf(vless('a', 'a.example.com'));
      expect(user['encryption'], 'none');
    });

    test('a corrupt stored value emits none, never the bad value', () {
      // A value the core would refuse must not reach the config:
      // the builder re-validates at emit time (the 2041 lesson).
      final user = vlessUserOf(vless('a', 'a.example.com',
          vlessEncryption: 'mlkem768x25519plus.native.0rtt.nope'));
      expect(user['encryption'], 'none');
    });
  });

  group('The share link round-trips the value (build 2046)', () {
    test('an encrypted profile shares a link carrying the value, '
        'and the link parses back to the same value', () {
      final value = encValue();
      final link = profileToLink(
        vless('a', 'a.example.com', vlessEncryption: value),
      );
      expect(link.contains('encryption=$value'), isTrue);
      final back = parseLink(link);
      expect(back, isNotNull);
      expect(back!.vlessEncryption, value);
    });

    test('a profile without encryption still writes encryption=none',
        () {
      final link = profileToLink(vless('a', 'a.example.com'));
      expect(link.contains('encryption=none'), isTrue);
      final back = parseLink(link);
      expect(back, isNotNull);
      expect(back!.vlessEncryption, isEmpty);
    });
  });

  group('Storage (build 2046)', () {
    test('the value survives a toJson/fromJson round-trip', () {
      final value = encValue();
      final p = vless('a', 'a.example.com', vlessEncryption: value);
      final back = Profile.fromJson(p.toJson());
      expect(back.vlessEncryption, value);
      expect(back.hasVlessEncryption, isTrue);
    });

    test('an old store without the key reads as no encryption', () {
      final j = vless('a', 'a.example.com').toJson()..remove('vlessEncryption');
      expect(Profile.fromJson(j).vlessEncryption, isEmpty);
    });

    test('a non-string stored value reads as no encryption, '
        'never throws (the 2043 lesson)', () {
      final j = vless('a', 'a.example.com').toJson()
        ..['vlessEncryption'] = 42;
      expect(Profile.fromJson(j).vlessEncryption, isEmpty);
    });
  });
}
