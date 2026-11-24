/// Build 2096 — batches G (lock/settings) and H (imports):
/// M4, M6, M9, L23, L32.
///
///  * M4 — a Lantern private-server config crosses the
///    import boundary like every other profile source.
///  * M6 — paste shapes: a mixed link+body paste imports
///    both halves; a stray 'proxies:' line no longer
///    hijacks a paste of links.
///  * M9/L23 — PIN attempts and the cooldown persist in
///    the settings (a recreated lock page resumes them),
///    and every failed verification counts.
///  * L32 — the settings-damage flag exists to be read
///    (its UI surface is pinned in the settings page by
///    the batch source checks in the full suite).
import 'dart:convert';
import 'dart:io';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/ui/ember/app_lock.dart';
import 'package:firefox_vpn/xray/lantern_import.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String _ssBody({required int port}) => jsonEncode({
      'outbounds': [
        {
          'type': 'shadowsocks',
          'server': '203.0.113.9',
          'server_port': port,
          'method': 'aes-256-gcm',
          'password': 'pw',
        },
      ],
    });

void main() {
  group('M4 — Lantern import crosses the boundary', () {
    test('an out-of-range port is clamped, the name sanitized', () {
      final p = profileFromConnectConfig(
        _ssBody(port: 99999),
        fallbackName: 'Evil\x07Name',
      );
      expect(p.port, 443); // the boundary invalid-port default
      expect(p.name.contains('\x07'), isFalse);
    });

    test('an in-range config passes through unchanged', () {
      final p = profileFromConnectConfig(
        _ssBody(port: 8388),
        fallbackName: 'My server',
      );
      expect(p.port, 8388);
      expect(p.address, '203.0.113.9');
    });
  });

  group('M6 — paste shapes', () {
    test('a mixed link + base64-body paste imports both', () async {
      final c = XrayController();
      const link =
          'vless://11111111-1111-1111-1111-111111111111@h1.example.com:443'
          '?security=tls#One';
      final body = base64Encode(
        utf8.encode(
          'trojan://pw@h2.example.com:443#Two',
        ),
      );
      final r = await c.importLinksAsync('$link\n$body');
      expect(r.added, 2);
      expect(
        c.profiles.map((p) => p.address),
        containsAll(['h1.example.com', 'h2.example.com']),
      );
    });

    test("a stray 'proxies:' line does not hijack a link paste", () async {
      final c = XrayController();
      const paste = 'proxies:\n'
          'vless://11111111-1111-1111-1111-111111111111@h1.example.com:443'
          '?security=tls#One';
      final r = await c.importLinksAsync(paste);
      expect(r.added, 1);
      expect(c.profiles.single.address, 'h1.example.com');
    });

    test('a real Clash document still imports via Clash', () async {
      final c = XrayController();
      const doc = '''
proxies:
  - name: clash-node
    type: ss
    server: 198.51.100.7
    port: 8388
    cipher: aes-256-gcm
    password: pw
''';
      final r = await c.importLinksAsync(doc);
      expect(r.added, 1);
      expect(c.profiles.single.address, '198.51.100.7');
    });
  });

  group('M9/L23 — lock counters persist and count verifications', () {
    test('the counters round-trip through the settings document', () {
      final s = AppSettings();
      s.update(appLockFailedAttempts: 4, appLockCooldownUntilMs: 123456);
      final doc = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
      final s2 = AppSettings()..applyRestoredSettings(doc);
      expect(s2.appLockFailedAttempts, 4);
      expect(s2.appLockCooldownUntilMs, 123456);
    });

    testWidgets('a 6-digit wrong entry counts 3 verifications and '
        'the cooldown survives a page recreation', (tester) async {
      var unlocked = false;
      final s = AppSettings();
      s.update(appLockPinHash: pinHashOf('123456'));
      await tester.pumpWidget(
        MaterialApp(
          home: AppLockPage(settings: s, onUnlocked: () => unlocked = true),
        ),
      );
      await tester.pump();
      for (final d in ['9', '9', '9', '9', '9', '9']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      // Auto-submits at 4 and 5 counted, the length-6
      // failure registered: 3 attempts, cooldown armed
      // and PERSISTED.
      expect(s.appLockFailedAttempts, 3);
      expect(s.appLockCooldownUntilMs, greaterThan(0));
      expect(find.textContaining('Too many wrong PINs'), findsOneWidget);
      expect(unlocked, isFalse);

      // Recreate the page (rotation / process death): the
      // cooldown is still in force.
      await tester.pumpWidget(
        MaterialApp(
          home: AppLockPage(settings: s, onUnlocked: () => unlocked = true),
        ),
      );
      await tester.pump();
      expect(find.textContaining('Too many wrong PINs'), findsOneWidget);
      for (final d in ['1', '2', '3', '4', '5', '6']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      expect(unlocked, isFalse);
    });

    testWidgets('a correct long PIN unlocks and clears the counters',
        (tester) async {
      var unlocked = false;
      final s = AppSettings();
      s.update(appLockPinHash: pinHashOf('123456'));
      await tester.pumpWidget(
        MaterialApp(
          home: AppLockPage(settings: s, onUnlocked: () => unlocked = true),
        ),
      );
      await tester.pump();
      for (final d in ['1', '2', '3', '4', '5', '6']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      expect(unlocked, isTrue);
      // The intermediate length-4/5 checks failed on the
      // way in, but success cleared the counters.
      expect(s.appLockFailedAttempts, 0);
      expect(s.appLockCooldownUntilMs, 0);
    });
  });

  group('L32 — damage flag', () {
    test('a damaged settings file sets storeDamaged on load', () async {
      final dir = await Directory.systemTemp.createTemp('ember2096gh');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/app-settings.json')
          .writeAsString('{not json');
      final s = await AppSettings.load(dir.path);
      expect(s.storeDamaged, isTrue);
    });
  });
}
