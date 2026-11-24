/// Build 2047 gates, host side: per-config TLS certificate pinning
/// (feature-watch 2026-11-04, Xray-core pinnedPeerCertSha256).
/// The bundled core (patterniha/xray-core @ 12fd84e = XTLS v26.11.1)
/// runs a TLS settings `pinnedPeerCertSha256` value — comma-separated
/// SHA-256 hashes, each 64 hex characters (colons allowed), each
/// decoding to 32 bytes — but the app dropped it: the parser ignored
/// the link parameter, the builder never emitted it, and the share
/// link never carried it. These tests pin the Dart side of the
/// contract: the validator mirrors the core's own rule (a value the
/// core accepts must be storable, a value it would refuse must never
/// reach the emitted config), the parser keeps a valid value from
/// links and raw core JSON and ignores an invalid one without losing
/// the profile, the builder emits the value verbatim, the share
/// link round-trips the value, and the subscription-refresh
/// identity strips a user-added pin so a pinned profile still
/// matches its refreshed self. Build 2048 removed the
/// `allowInsecure` toggle and field outright (the core removed the
/// feature and refuses the whole config when the key is set), so
/// the two tests that used to pin the old behaviour now assert the
/// key is never emitted, with or without a pin. The editor's save-time refusal of an
/// invalid value is UI and is not host-testable without a device,
/// so the tests pin the validator the editor calls. Only a device
/// test — pin a real server cert, connect, confirm traffic flows,
/// then pin a wrong hash and confirm the connect is refused —
/// proves the pinned path against a real server.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/tls_cert_pin.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

/// A valid pin: 64 hex characters. [char] picks the digit so two
/// pins can be told apart.
String pinValue({String char = 'a'}) => char * 64;

/// The same pin in the OpenSSL colon-separated form the core
/// strips before decoding.
String colonPinValue({String char = 'a'}) {
  final hex = pinValue(char: char);
  final parts = <String>[];
  for (var i = 0; i < hex.length; i += 2) {
    parts.add(hex.substring(i, i + 2));
  }
  return parts.join(':');
}

Profile tlsProfile(
  String id,
  String address, {
  Protocol protocol = Protocol.vless,
  String? tlsCertPin,
}) =>
    Profile(
      id: id,
      protocol: protocol,
      name: 'a',
      address: address,
      port: 443,
      uuidOrPassword: protocol == Protocol.trojan
          ? 'secret'
          : '11111111-1111-1111-1111-111111111111',
      security: 'tls',
      tlsCertPin: tlsCertPin ?? '',
    );

Map<String, dynamic> tlsOf(Profile p) {
  final cfg = decode(buildTunnelConfig(p, XraySettings()));
  final outbounds = cfg['outbounds'] as List;
  final proxy = outbounds.first as Map<String, dynamic>;
  final stream = proxy['streamSettings'] as Map<String, dynamic>;
  return stream['tlsSettings'] as Map<String, dynamic>;
}

Map<String, dynamic> testTlsOf(Profile p) {
  final cfg = decode(buildTestConfig(p, XraySettings()));
  final outbounds = cfg['outbounds'] as List;
  final proxy = outbounds.first as Map<String, dynamic>;
  final stream = proxy['streamSettings'] as Map<String, dynamic>;
  return stream['tlsSettings'] as Map<String, dynamic>;
}

void main() {
  group('The validator mirrors the core rule (build 2047)', () {
    test('accepts a single 64-hex pin, any case', () {
      expect(isValidTlsCertPin(pinValue()), isTrue);
      expect(isValidTlsCertPin(pinValue(char: 'F')), isTrue);
      expect(isValidTlsCertPin('0123456789abcdef' * 4), isTrue);
      expect(isValidTlsCertPin('0123456789ABCDEF' * 4), isTrue);
    });

    test('accepts the colon-separated OpenSSL form', () {
      expect(isValidTlsCertPin(colonPinValue()), isTrue);
    });

    test('accepts several comma-separated pins, spaces allowed', () {
      expect(
        isValidTlsCertPin('${pinValue()} , ${pinValue(char: 'b')}'),
        isTrue,
      );
      expect(tlsCertPinCount('${pinValue()},${pinValue(char: 'b')}'), 2);
    });

    test('skips empty parts, as the core does', () {
      expect(
        isValidTlsCertPin('${pinValue()},,${pinValue(char: 'b')}'),
        isTrue,
      );
      expect(
        tlsCertPinCount('${pinValue()},,${pinValue(char: 'b')}'),
        2,
      );
    });

    test('rejects a pin of the wrong length or with non-hex', () {
      expect(isValidTlsCertPin('a' * 63), isFalse);
      expect(isValidTlsCertPin('a' * 65), isFalse);
      expect(isValidTlsCertPin('g' * 64), isFalse);
      expect(isValidTlsCertPin('a' * 32), isFalse);
      expect(isValidTlsCertPin(''), isFalse);
      expect(isValidTlsCertPin(',,,'), isFalse);
      expect(isValidTlsCertPin('   '), isFalse);
    });

    test('rejects a list with one bad entry among good ones', () {
      expect(
        isValidTlsCertPin('${pinValue()},zzzz'),
        isFalse,
      );
      expect(
        isValidTlsCertPin('${pinValue()},${'a' * 63}'),
        isFalse,
      );
    });

  });

  group('The parser keeps a valid pin (build 2047)', () {
    test('a vless link with a valid pin stores it', () {
      final pin = pinValue();
      final p = parseLink(
        'vless://11111111-1111-1111-1111-111111111111@a.example.com:443'
        '?security=tls&pinnedPeerCertSha256=$pin#srv',
      );
      expect(p, isNotNull);
      expect(p!.tlsCertPin, pin);
      expect(p.hasTlsCertPin, isTrue);
    });

    test('a vless link with an invalid pin still imports, unpinned',
        () {
      final p = parseLink(
        'vless://11111111-1111-1111-1111-111111111111@a.example.com:443'
        '?security=tls&pinnedPeerCertSha256=${'a' * 63}#srv',
      );
      expect(p, isNotNull);
      expect(p!.tlsCertPin, isEmpty);
      expect(p.hasTlsCertPin, isFalse);
    });

    test('a trojan link with a valid pin stores it', () {
      final pin = pinValue(char: 'b');
      final p = parseLink(
        'trojan://secret@a.example.com:443'
        '?security=tls&pinnedPeerCertSha256=$pin#srv',
      );
      expect(p, isNotNull);
      expect(p!.tlsCertPin, pin);
    });

    test('a vmess JSON link with a valid pin stores it', () {
      final pin = pinValue();
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
        'pinnedPeerCertSha256': pin,
      };
      final link =
          'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
      final p = parseLink(link);
      expect(p, isNotNull);
      expect(p!.tlsCertPin, pin);
    });

    test('a vmess JSON link with an invalid pin still imports, '
        'unpinned', () {
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
        'pinnedPeerCertSha256': 'not-a-hash',
      };
      final link =
          'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
      final p = parseLink(link);
      expect(p, isNotNull);
      expect(p!.tlsCertPin, isEmpty);
    });

    test('a raw core JSON import keeps a valid pin', () {
      final pin = pinValue();
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
              'tlsSettings': {'pinnedPeerCertSha256': pin},
            },
          },
        ],
      }));
      expect(profiles.length, 1);
      expect(profiles.first.tlsCertPin, pin);
    });

    test('a raw core JSON import drops an invalid pin', () {
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
              'tlsSettings': {'pinnedPeerCertSha256': 'zzz'},
            },
          },
        ],
      }));
      expect(profiles.length, 1);
      expect(profiles.first.tlsCertPin, isEmpty);
    });
  });

  group('The builder emits the pin, or nothing (build 2047)', () {
    test('a pinned TLS profile emits the pin verbatim', () {
      final pin = pinValue();
      final tls = tlsOf(
        tlsProfile('a', 'a.example.com', tlsCertPin: pin),
      );
      expect(tls['pinnedPeerCertSha256'], pin);
      expect(tls['serverName'], 'a.example.com');
    });

    test('a profile without a pin emits no pin key', () {
      final tls = tlsOf(tlsProfile('a', 'a.example.com'));
      expect(tls.containsKey('pinnedPeerCertSha256'), isFalse);
    });

    test('a corrupt stored value emits no pin key, never the bad '
        'value', () {
      // A value the core would refuse must not reach the config:
      // the builder re-validates at emit time (the 2041 lesson).
      final tls = tlsOf(
        tlsProfile('a', 'a.example.com', tlsCertPin: 'not-a-hash'),
      );
      expect(tls.containsKey('pinnedPeerCertSha256'), isFalse);
    });

    test('a valid pin is emitted and no allowInsecure key appears', () {
      // Build 2048: the core removed allowInsecure outright and
      // Ember never emits the key — a pinned profile verifies
      // against the pin instead.
      final cfg = decode(
        buildTunnelConfig(
          tlsProfile('a', 'a.example.com', tlsCertPin: pinValue()),
          XraySettings(),
        ),
      );
      final outbounds = cfg['outbounds'] as List;
      final proxy = outbounds.first as Map<String, dynamic>;
      final stream = proxy['streamSettings'] as Map<String, dynamic>;
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      expect(tls.containsKey('allowInsecure'), isFalse);
      expect(tls['pinnedPeerCertSha256'], pinValue());
    });

    test('without a pin, no allowInsecure key is emitted either', () {
      // Build 2048: the toggle and the field are gone — a profile
      // that used to skip the check now verifies normally.
      final cfg = decode(
        buildTunnelConfig(
          tlsProfile('a', 'a.example.com'),
          XraySettings(),
        ),
      );
      final outbounds = cfg['outbounds'] as List;
      final proxy = outbounds.first as Map<String, dynamic>;
      final stream = proxy['streamSettings'] as Map<String, dynamic>;
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      expect(tls.containsKey('allowInsecure'), isFalse);
      expect(tls.containsKey('pinnedPeerCertSha256'), isFalse);
    });

    test('a non-TLS profile with a stored pin builds no TLS '
        'settings at all', () {
      final p = tlsProfile('a', 'a.example.com', tlsCertPin: pinValue())
        ..security = '';
      final cfg = decode(buildTunnelConfig(p, XraySettings()));
      final outbounds = cfg['outbounds'] as List;
      final proxy = outbounds.first as Map<String, dynamic>;
      final stream = proxy['streamSettings'] as Map<String, dynamic>;
      expect(stream.containsKey('tlsSettings'), isFalse);
    });

    test('the delay-test config carries the pin too', () {
      final tls = testTlsOf(
        tlsProfile('a', 'a.example.com', tlsCertPin: pinValue()),
      );
      expect(tls['pinnedPeerCertSha256'], pinValue());
    });
  });

  group('The share link round-trips the pin (build 2047)', () {
    test('a pinned vless profile shares a link carrying the pin, '
        'and the link parses back to the same pin', () {
      final pin = pinValue();
      final link = profileToLink(
        tlsProfile('a', 'a.example.com', tlsCertPin: pin),
      );
      expect(link.contains('pinnedPeerCertSha256=$pin'), isTrue);
      final back = parseLink(link);
      expect(back, isNotNull);
      expect(back!.tlsCertPin, pin);
    });

    test('a profile without a pin shares a link with no pin '
        'parameter', () {
      final link = profileToLink(tlsProfile('a', 'a.example.com'));
      expect(link.contains('pinnedPeerCertSha256'), isFalse);
      final back = parseLink(link);
      expect(back, isNotNull);
      expect(back!.tlsCertPin, isEmpty);
    });

    test('a pinned vmess profile round-trips through its JSON link',
        () {
      final pin = pinValue();
      final p = tlsProfile(
        'a',
        'a.example.com',
        protocol: Protocol.vmess,
        tlsCertPin: pin,
      );
      final back = parseLink(profileToLink(p));
      expect(back, isNotNull);
      expect(back!.tlsCertPin, pin);
    });

    test('a pinned trojan profile round-trips', () {
      final pin = pinValue(char: 'b');
      final p = tlsProfile(
        'a',
        'a.example.com',
        protocol: Protocol.trojan,
        tlsCertPin: pin,
      );
      final back = parseLink(profileToLink(p));
      expect(back, isNotNull);
      expect(back!.tlsCertPin, pin);
    });
  });

  group('The refresh identity strips a user-added pin (build 2047)',
      () {
    test('a pinned vless profile has the same identity as its '
        'unpinned self', () {
      final pinned = tlsProfile(
        'a',
        'a.example.com',
        tlsCertPin: pinValue(),
      );
      final plain = tlsProfile('a', 'a.example.com');
      expect(profileIdentityLink(pinned), profileIdentityLink(plain));
      expect(
        profileIdentityLink(pinned),
        profileToLink(plain).split('#').first,
      );
    });

    test('a pinned vmess profile has the same identity as its '
        'unpinned self', () {
      final pinned = tlsProfile(
        'a',
        'a.example.com',
        protocol: Protocol.vmess,
        tlsCertPin: pinValue(),
      );
      final plain = tlsProfile(
        'a',
        'a.example.com',
        protocol: Protocol.vmess,
      );
      expect(profileIdentityLink(pinned), profileIdentityLink(plain));
    });

    test('an unpinned profile identity is its link minus the name',
        () {
      final p = tlsProfile('a', 'a.example.com');
      expect(
        profileIdentityLink(p),
        profileToLink(p).split('#').first,
      );
    });
  });

  group('Storage (build 2047)', () {
    test('the pin survives a toJson/fromJson round-trip', () {
      final pin = pinValue();
      final p = tlsProfile('a', 'a.example.com', tlsCertPin: pin);
      final back = Profile.fromJson(p.toJson());
      expect(back.tlsCertPin, pin);
      expect(back.hasTlsCertPin, isTrue);
    });

    test('an old store without the key reads as no pin', () {
      final j = tlsProfile('a', 'a.example.com').toJson()
        ..remove('tlsCertPin');
      expect(Profile.fromJson(j).tlsCertPin, isEmpty);
    });

    test('a non-string stored value reads as no pin, never throws '
        '(the 2043 lesson)', () {
      final j = tlsProfile('a', 'a.example.com').toJson()
        ..['tlsCertPin'] = 42;
      expect(Profile.fromJson(j).tlsCertPin, isEmpty);
    });
  });
}
