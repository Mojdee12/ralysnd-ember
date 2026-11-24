// Build 2116, batch B3 — WireGuard: MTU restored,
// scripts/unknown keys round-tripped, multi-peer hand-off,
// route-coverage honesty, exit verification.
//
// - B3-1: the Kotlin engine no longer nulls the profile
//   MTU; the Settings MTU channel argument is read.
// - B3-3: unmodelled .conf keys (the AWG v3 device family)
//   are preserved and re-emitted, not silently dropped.
// - B3-4: a peer group hands the engine every peer.
// - B3-5: interface scripts round-trip verbatim (never
//   executed).
// - B3-7: route coverage is computed off the effective
//   AllowedIPs and names the uncovered family.
// - B3-8: after adoption the WG session's exit is
//   measured once and stamped; failure stamps unverified;
//   nothing gates on it.
//
// All fixtures use dummy values.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

const _key = 'YAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=';
const _peer = 'HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=';
const _peer2 = 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=';

Profile wg({
  String localAddress = '10.0.0.2/32',
  String allowedIPs = '0.0.0.0/0',
}) => Profile(
  id: 'w1',
  protocol: Protocol.wireguard,
  address: '203.0.113.10',
  port: 51820,
  secretKey: _key,
  peerPublicKey: _peer,
  localAddress: localAddress,
  wgAllowedIPs: allowedIPs,
);

void main() {
  group('B3-5 scripts round-trip (C2-19)', () {
    const conf = '''
[Interface]
PrivateKey = $_key
Address = 10.0.0.2/32
PreUp = echo pre-up
PostUp = echo post-up
PreDown = echo pre-down
PostDown = echo post-down

[Peer]
PublicKey = $_peer
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0
''';

    test('scripts are stored and re-exported verbatim', () {
      var n = 0;
      final r = parseWgConf(conf, baseName: 's', idFor: () => 's${n++}');
      final p = r.profiles.single;
      expect(p.wgPreUp, 'echo pre-up');
      expect(p.wgPostUp, 'echo post-up');
      expect(p.wgPreDown, 'echo pre-down');
      expect(p.wgPostDown, 'echo post-down');
      final out = wgConfFromProfile(p);
      expect(out, contains('PreUp = echo pre-up'));
      expect(out, contains('PostDown = echo post-down'));
      final stored = Profile.fromJson(p.toJson());
      expect(stored.wgPostUp, 'echo post-up');
    });
  });

  group('B3-3 unmodelled keys preserved (W-03)', () {
    const conf = '''
[Interface]
PrivateKey = $_key
Address = 10.0.0.2/32
Itime = 7
X-Custom-Thing = abc

[Peer]
PublicKey = $_peer
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0
''';

    test('unknown keys land in wgExtraKeys and re-emit', () {
      var n = 0;
      final r = parseWgConf(conf, baseName: 'x', idFor: () => 'x${n++}');
      final p = r.profiles.single;
      final extras = jsonDecode(p.wgExtraKeys) as Map<String, dynamic>;
      expect((extras['i'] as Map)['itime'], '7');
      expect((extras['i'] as Map)['x-custom-thing'], 'abc');
      final out = wgConfFromProfile(p);
      expect(out, contains('itime = 7'));
      expect(out, contains('x-custom-thing = abc'));
    });

    test('a plain conf carries no extras', () {
      var n = 0;
      final r = parseWgConf(
        '[Interface]\nPrivateKey = $_key\nAddress = 10.0.0.2/32\n\n'
        '[Peer]\nPublicKey = $_peer\nEndpoint = 203.0.113.10:51820\n',
        baseName: 'x',
        idFor: () => 'x${n++}',
      );
      expect(r.profiles.single.wgExtraKeys, '');
    });
  });

  group('B3-4 multi-peer hand-off (C2-07 companion)', () {
    const conf = '''
[Interface]
PrivateKey = $_key
Address = 10.0.0.2/32

[Peer]
PublicKey = $_peer
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0

[Peer]
PublicKey = $_peer2
Endpoint = 203.0.113.11:51820
AllowedIPs = 10.0.0.0/8
''';

    test('the group serializer emits every peer', () {
      var n = 0;
      final r = parseWgConf(conf, baseName: 'm', idFor: () => 'm${n++}');
      expect(r.profiles, hasLength(2));
      expect(wgGroupKey(r.profiles[0]), wgGroupKey(r.profiles[1]));
      final text = wgConfFromProfiles(r.profiles);
      expect('[Peer]'.allMatches(text), hasLength(2));
      expect(text, contains('203.0.113.10:51820'));
      expect(text, contains('203.0.113.11:51820'));
      expect(text, contains('AllowedIPs = 10.0.0.0/8'));
      expect('[Interface]'.allMatches(text), hasLength(1));
    });

    test('the AWG hand-off composes the group (pin)', () {
      final src = File('lib/xray/xray_controller.dart').readAsStringSync();
      expect(src, contains('settings: wgConfFromProfiles(wgGroup)'));
    });
  });

  group('B3-7 route coverage (WGX-1/WGX-2)', () {
    test('a v6-only profile leaves IPv4 uncovered', () {
      final p = wg(
        localAddress: 'fd00::2/128',
        allowedIPs: '::/0',
      );
      expect(wgRoutedFamilies(p), (v4: false, v6: true));
      expect(wgUncoveredFamilyNote(p), contains('IPv4 traffic stays'));
      expect(wgUncoveredChipLabel(p), contains('IPv4 stays outside'));
    });

    test('a v4-only profile leaves IPv6 uncovered', () {
      final p = wg();
      expect(wgRoutedFamilies(p), (v4: true, v6: false));
      expect(wgUncoveredFamilyNote(p), contains('IPv6 traffic stays'));
    });

    test('a dual-stack profile has no note', () {
      final p = wg(
        localAddress: '10.0.0.2/32, fd00::2/128',
        allowedIPs: '0.0.0.0/0, ::/0',
      );
      expect(wgRoutedFamilies(p), (v4: true, v6: true));
      expect(wgUncoveredFamilyNote(p), isNull);
      expect(wgUncoveredChipLabel(p), isNull);
    });

    test('a blank AllowedIPs falls back to the footprint default', () {
      final p = wg(localAddress: 'fd00::2/128', allowedIPs: '');
      expect(wgRoutedFamilies(p), (v4: false, v6: true));
    });
  });

  group('B3-8 exit verification (WGX)', () {
    test('the verification is hooked at adoption, never gating (pins)', () {
      final src = File('lib/xray/xray_controller.dart').readAsStringSync();
      expect(src, contains('bool wgExitUnverified = false;'));
      expect(src, contains('unawaited(_verifyWgExit(p, gen));'));
      final verifyAt = src.indexOf('Future<void> _verifyWgExit');
      final verifyEnd = src.indexOf('Future<bool> switchServer', verifyAt);
      final segment = src.substring(verifyAt, verifyEnd);
      expect(segment, contains('XrayPlatform.measureDelayEx'));
      expect(segment, contains("cc == 'IR'"));
      expect(segment, isNot(contains('_stopTunnel')));
    });
  });

  group('B3-1 MTU restored (pins)', () {
    test('the Kotlin engine keeps a usable MTU', () {
      final engine = File(
        'android/app/src/main/kotlin/com/ralysnd/ember/WgTunnelEngine.kt',
      ).readAsStringSync();
      expect(engine, isNot(contains('iface.copy(mtu = null)')));
      expect(engine, contains('profileMtu in 576..9000'));
      final main = File(
        'android/app/src/main/kotlin/com/ralysnd/ember/MainActivity.kt',
      ).readAsStringSync();
      expect(main, contains('call.argument<Int>("mtu")'));
    });
  });
}
