// Build 2102 — regression/journey coverage for the
// WireGuard IPv6 fix (wg-ipv6-import-diagnosis.md): import
// from every surface (I1 share/open-with intake routing,
// I2 general paste import, the WireGuard section's own
// paste + file journeys) and the AWG connect fixes for
// IPv6-only profiles (C1 profile DNS, C2 IPv4 route gate,
// C3 IPv6-route toggle). Behavioural wherever the surface
// allows; the shell-private intent consumer and the Kotlin
// TUN builder use the standing source-pin exception, as in
// earlier batches.
//
// The v6 fixture carries a DUMMY private key — the owner's
// real key never appears in tests. Every other field keeps
// the failing config's exact shape: bracketed v6 endpoint,
// /128 interface address, IPv6 DNS, ::/0-only AllowedIPs,
// Jc/Jmin/Jmax + an I1 DSL line.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/ui/ember/wireguard_pages.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

const _dummyKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

const _v6Conf = '''
[Interface]
Address = 2606:4700:110:8d17:9892:cb7f:7fca:4541/128
PrivateKey = $_dummyKey
DNS = 2606:4700:4700::1111, 2606:4700:4700::1001
Jc = 6
Jmin = 10
Jmax = 50
I1 = <r 2><b 0x858000010001000000000001020304050607080900000100010001000100000105a0004aabbccdd>

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
Endpoint = [2606:4700:d0:0:92d9:27b5:d23d:b2f7]:2408
AllowedIPs = ::/0
PersistentKeepalive = 25
''';

/// The owner's working v4 WARP shape (warpscouttest.conf),
/// dummy key: the no-regression fixture.
const _v4Conf = '''
[Interface]
Address = 172.16.0.2/32
PrivateKey = $_dummyKey
DNS = 1.1.1.1, 1.0.0.1
Jc = 6
Jmin = 10
Jmax = 50
I1 = <r 2><b 0x858000010001000000000001020304050607080900000100010001000100000105a0004aabbccdd>

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
Endpoint = 188.114.96.125:2408
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
''';

const _ovpnText = '''
client
dev tun
proto udp
remote vpn.example.com 1194
''';

void _mockAndroid(Map<String, Object? Function(MethodCall)> handlers) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('app/android'),
          (call) async {
    final h = handlers[call.method];
    if (h != null) return h(call);
    return null;
  });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), null);
  });
}

Profile _v6Profile() =>
    parseWgConf(_v6Conf, baseName: 'v6', idFor: () => 'id-v6').profiles.single;

Profile _v4Profile() =>
    parseWgConf(_v4Conf, baseName: 'v4', idFor: () => 'id-v4').profiles.single;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v6 shape — the parser keeps every field', () {
    test('parse: endpoint, address, DNS, AllowedIPs, AWG', () {
      final r = parseWgConf(_v6Conf, baseName: 'v6', idFor: () => 'id1');
      expect(r.ok, isTrue, reason: r.error);
      expect(r.amnezia, isTrue);
      final p = r.profiles.single;
      expect(p.protocol, Protocol.wireguard);
      expect(p.address, '2606:4700:d0:0:92d9:27b5:d23d:b2f7');
      expect(p.port, 2408);
      expect(p.localAddress, '2606:4700:110:8d17:9892:cb7f:7fca:4541/128');
      expect(p.wgDns, '2606:4700:4700::1111,2606:4700:4700::1001');
      expect(p.wgAllowedIPs, '::/0');
      expect(p.keepAlive, 25);
      expect(p.awgJc, '6');
      expect(p.awgJmin, '10');
      expect(p.awgJmax, '50');
      expect(p.awgI1, contains('<r 2>'));
      expect(p.hasAmneziaParams, isTrue);
    });

    test('hand-off: bracketed v6 endpoint, ::/0, keepalive, I1', () {
      // Build 2104: the engine hand-off is the canonical
      // .conf text (wgConfFromProfile); the UAPI composer
      // is deleted with the old bridge.
      final conf = wgConfFromProfile(_v6Profile());
      expect(
        conf,
        contains('Endpoint = [2606:4700:d0:0:92d9:27b5:d23d:b2f7]:2408'),
      );
      expect(conf, contains('AllowedIPs = ::/0'));
      expect(conf, contains('PersistentKeepalive = 25'));
      expect(conf, contains('I1 = '));
    });

    test('JSON + .conf round-trips keep the v6 fields', () {
      final p = _v6Profile();
      final back = Profile.fromJson(p.toJson());
      expect(back.localAddress, p.localAddress);
      expect(back.wgDns, p.wgDns);
      expect(back.wgAllowedIPs, '::/0');
      expect(back.address, p.address);
      expect(back.awgI1, p.awgI1);
      final again = parseWgConf(
        wgConfFromProfile(p),
        baseName: 'rt',
        idFor: () => 'id-rt',
      );
      expect(again.ok, isTrue, reason: again.error);
      expect(again.profiles.single.address, p.address);
      expect(again.profiles.single.wgDns, p.wgDns);
    });

    test('the gate: isWgConfText speaks the parser language', () {
      expect(isWgConfText(_v6Conf), isTrue);
      expect(isWgConfText('[interface]\nPrivateKey = x'), isTrue,
          reason: 'section names are case-insensitive');
      expect(isWgConfText(_ovpnText), isFalse);
      expect(
        isWgConfText('vless://u@h.example:443#x'),
        isFalse,
      );
    });
  });

  group('C1/C2 helpers — DNS choice and the IPv4 footprint', () {
    test('profileHasIpv4 separates the shapes', () {
      expect(profileHasIpv4(_v6Profile()), isFalse,
          reason: 'v6 address + ::/0 only carries no IPv4');
      expect(profileHasIpv4(_v4Profile()), isTrue);
      final allowedOnly = _v6Profile()..wgAllowedIPs = '0.0.0.0/0, ::/0';
      expect(profileHasIpv4(allowedOnly), isTrue,
          reason: 'an IPv4 AllowedIPs entry is an IPv4 footprint');
      final bare = Profile(id: 'b', protocol: Protocol.wireguard, name: 'b');
      expect(profileHasIpv4(bare), isFalse);
    });

    test('awgDnsFor: the profile DNS wins, Settings is the fallback', () {
      final s = XraySettings();
      expect(awgDnsFor(_v6Profile(), s),
          '2606:4700:4700::1111,2606:4700:4700::1001');
      expect(awgDnsFor(_v4Profile(), s), '1.1.1.1,1.0.0.1',
          reason: 'the parser stores the DNS list comma-joined '
              'without spaces');
      final noDns = _v6Profile()..wgDns = '';
      expect(awgDnsFor(noDns, s), s.localDns,
          reason: 'a profile without a DNS line keeps the '
              'pre-2102 Settings behaviour');
      s.localDns = '9.9.9.9';
      expect(awgDnsFor(noDns, s), '9.9.9.9');
    });
  });

  group('I2 — the general paste import routes a .conf', () {
    test('importLinksAsync adds the v6 config with honest counts',
        () async {
      _mockAndroid({});
      final c = XrayController();
      addTearDown(c.dispose);
      final r = await c.importLinksAsync(_v6Conf);
      expect(r.added, 1);
      expect(r.errors, isEmpty);
      expect(r.subscriptions, isEmpty);
      expect(c.profiles, hasLength(1));
      final p = c.profiles.single;
      expect(p.protocol, Protocol.wireguard);
      expect(p.address, '2606:4700:d0:0:92d9:27b5:d23d:b2f7');
      expect(wgProfilesOf(c), hasLength(1),
          reason: 'the profile is visible to the WG section');
    });

    test('a second paste of the same config is a named duplicate',
        () async {
      _mockAndroid({});
      final c = XrayController();
      addTearDown(c.dispose);
      await c.importLinksAsync(_v6Conf);
      final r = await c.importLinksAsync(_v6Conf);
      expect(r.added, 0);
      expect(r.errors.join('\n'), contains('duplicate WireGuard'));
      expect(c.profiles, hasLength(1));
    });

    test('an invalid .conf is named, not read as zero links', () async {
      _mockAndroid({});
      final c = XrayController();
      addTearDown(c.dispose);
      final r = await c.importLinksAsync(
        '[Interface]\nAddress = 2606:4700:110::2/128\n',
      );
      expect(r.added, 0);
      expect(r.errors, hasLength(1));
      expect(r.errors.single, contains('WireGuard'));
      expect(c.profiles, isEmpty);
    });

    test('ordinary links still import (the gate does not swallow)',
        () async {
      _mockAndroid({});
      final c = XrayController();
      addTearDown(c.dispose);
      final r = await c.importLinksAsync(
        'vless://11111111-1111-1111-1111-111111111111@h.example:443#one',
      );
      expect(r.added, 1);
      expect(c.profiles.single.protocol, Protocol.vless);
    });
  });

  group('WG section journeys — paste and file, v6 shape', () {
    test('addWgConfText lands the v6 profile in the store', () async {
      _mockAndroid({});
      final c = XrayController();
      addTearDown(c.dispose);
      final r = await addWgConfText(c, _v6Conf, 'picked-name');
      expect(r.ok, isTrue, reason: r.error);
      expect(c.profiles.single.name, 'picked-name');
      expect(c.profiles.single.wgDns,
          '2606:4700:4700::1111,2606:4700:4700::1001');
    });

    testWidgets('the paste journey: dialog, import, snackbar', (
      tester,
    ) async {
      _mockAndroid({});
      final c = XrayController();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => importWgConfText(ctx, c, _v6Conf),
                child: const Text('go-paste'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go-paste'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Config name'), findsOneWidget,
          reason: 'the journey reaches the name prompt');
      await tester.tap(find.text('Import'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 1));
      expect(c.profiles, hasLength(1));
      expect(c.profiles.single.address,
          '2606:4700:d0:0:92d9:27b5:d23d:b2f7');
      expect(find.textContaining('Imported 1 config'), findsOneWidget);
    });

    testWidgets('the file journey: pick, dialog, import', (tester) async {
      _mockAndroid({
        'pickTextFile': (_) => {'name': 'warp-v6.conf', 'content': _v6Conf},
      });
      final c = XrayController();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => importWgConfFile(ctx, c),
                child: const Text('go-file'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go-file'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Config name'), findsOneWidget,
          reason: 'a completed pick reaches the name prompt '
              'with the file name seeded');
      await tester.tap(find.text('Import'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 1));
      expect(c.profiles, hasLength(1));
      expect(c.profiles.single.name, 'warp-v6',
          reason: 'the file name (sans .conf) names the profile');
      expect(c.profiles.single.wgAllowedIPs, '::/0');
    });
  });

  group('I1 — the share/open-with intake (source pins)', () {
    test('the shell content-routes a .conf before OpenVPN', () {
      final src =
          File('lib/ui/ember/ember_shell.dart').readAsStringSync();
      final gate = src.indexOf('isWgConfText(file.content)');
      final ovpn = src.indexOf(
        'await importOpenVpnText(context, _openvpn, file.name, file.content)',
      );
      expect(gate, greaterThan(-1),
          reason: 'the intake checks the payload content');
      expect(ovpn, greaterThan(-1));
      expect(gate, lessThan(ovpn),
          reason: 'the WG route is decided before the '
              'OpenVPN importer can claim the file');
      final wgBranch = src.substring(gate, ovpn);
      expect(wgBranch, contains('mode = 5'),
          reason: 'a .conf lands on the WireGuard tab');
      expect(wgBranch, contains('importWgConfText'));
    });

    test('every document surface decides by the one gate', () {
      final qr = File('lib/ui/ember/qr_pages.dart').readAsStringSync();
      expect(qr, contains('isWgConfText(code)'),
          reason: 'the scan intake routes by the shared gate');
      expect(qr, isNot(contains("code.contains('[Interface]')")),
          reason: 'the case-sensitive scan gate of builds '
              '≤2101 refused lowercase-header confs the '
              'parser accepts');
      final wg =
          File('lib/ui/ember/wireguard_pages.dart').readAsStringSync();
      expect(wg, isNot(contains("toLowerCase().contains('[interface]')")),
          reason: 'the WG page gates are the shared '
              'isWgConfText, not inline copies');
    });

    test('the manifest offers Ember for .conf files', () {
      final src = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(src, contains(r'android:pathPattern=".*\\.conf"'),
          reason: 'a VIEW filter matches .conf paths, as '
              'it has matched .ovpn since build 2085');
      expect(src, contains(r'android:pathPattern=".*\\.CONF"'));
    });
  });

  group('C1/C2/C3 — the AWG connect wiring (source pins)', () {
    test('the controller passes the profile DNS and IPv4 flag', () {
      final src =
          File('lib/xray/xray_controller.dart').readAsStringSync();
      // Build 2110 (wg-start diagnosis A1): the value handed
      // over is awgDnsFor's, family-guarded — a set the
      // backend would filter to empty is substituted first
      // (see build2110_test.dart's B2 group). awgDnsFor
      // itself is unchanged (the behavior tests above).
      expect(src, contains('awgDnsGuardedFor(p, settings)'));
      expect(src, contains('dns: awgDns,'));
      expect(src, contains('ipv4: profileHasIpv4(p)'));
      final platform =
          File('lib/xray/xray_platform.dart').readAsStringSync();
      expect(platform, contains("'ipv4': ipv4"));
      final main =
          File('android/app/src/main/kotlin/com/ralysnd/ember/MainActivity.kt')
              .readAsStringSync();
      expect(main, contains('call.argument<Boolean>("ipv4") ?: true'));
    });

    test('the engine gates the v4 route and applies the DNS (2104)', () {
      // Build 2104: AwgVpnService and its Builder are deleted.
      // C1/C2/C3 are properties of the WG Tunnel backend's
      // TUN builder now; Ember's half is WgTunnelEngine's
      // hand-off shaping, pinned here in place of the old
      // service pins. The routes derive from the Config's
      // AllowedIPs in the backend builder; the family flags
      // gate only the full-tunnel default for a peer that
      // carries no AllowedIPs of its own.
      final src = File(
        'android/app/src/main/kotlin/com/ralysnd/ember/WgTunnelEngine.kt',
      ).readAsStringSync();
      expect(
        src,
        contains('if (ipv4) "0.0.0.0/0" else null'),
        reason: 'the IPv4 default route is composed only '
            'for a profile that carries IPv4 (C2)',
      );
      expect(
        src,
        contains('if (ipv6) "::/0" else null'),
        reason: 'the ::/0 default gate is the profile flag '
            '(C3). Build 2103 decoupled the flag\'s SOURCE: '
            'it is the profile\'s own IPv6 footprint '
            '(profileHasIpv6), no longer the Xray Settings '
            'toggle — whose default is OFF now — so a '
            'v6-only profile keeps this route under the '
            'new defaults',
      );
      expect(
        src,
        contains('allowedIPs.isNullOrBlank()'),
        reason: 'the defaults apply only to a peer carrying '
            'no AllowedIPs — a peer with a list routes '
            'exactly per it',
      );
      expect(src, contains('dnsCsv.split(",")'),
          reason: 'every resolver in the profile DNS list '
              'is carried (C1)');
      expect(src, contains('dns = dnsServers.joinToString'),
          reason: 'the hand-off DNS replaces the Config '
              'DNS wholesale (C1)');
      expect(src, contains('ipv4: Boolean'),
          reason: 'the flag rides its own channel argument');
    });
  });

  group('v4 shape — no regression', () {
    test('parse + hand-off are the 2101 composition', () {
      final r = parseWgConf(_v4Conf, baseName: 'v4', idFor: () => 'id1');
      expect(r.ok, isTrue, reason: r.error);
      final p = r.profiles.single;
      expect(p.address, '188.114.96.125');
      expect(p.localAddress, '172.16.0.2/32');
      final conf = wgConfFromProfile(p);
      expect(conf, contains('Endpoint = 188.114.96.125:2408'),
          reason: 'an IPv4 endpoint stays unbracketed');
      expect(conf, contains('AllowedIPs = 0.0.0.0/0'));
      expect(profileHasIpv4(p), isTrue,
          reason: 'the v4 profile keeps its IPv4 route');
    });

    test('the v4 config imports through both bulk routes', () async {
      _mockAndroid({});
      final c = XrayController();
      addTearDown(c.dispose);
      final r = await c.importLinksAsync(_v4Conf);
      expect(r.added, 1);
      final r2 = await addWgConfText(c, _v4Conf, 'wg-page-name');
      expect(r2.ok, isTrue, reason: r2.error);
      expect(c.profiles, hasLength(2),
          reason: 'the WG page route has never deduped — '
              'unchanged in 2102');
    });
  });
}
