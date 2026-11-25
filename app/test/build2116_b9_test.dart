// Build 2116, batch B9 — settings honesty + accessibility.
//
// B9-1: the "two kill switches" claim re-verified — there is
// ONE switch (XraySettings.killSwitch) shown in two sections;
// no AppSettings kill switch exists. The residue landed: the
// WARP/MASQUE row now states its coverage limits like the
// V2Ray row's caption does.
// B9-2: the three auto-connect triggers default OFF, with a
// defaultsReset2116 one-time migration off a stored ON.
// B9-3: localDns re-verified — it feeds the WireGuard /
// Lantern / Psiphon tunnel DNS, not the V2Ray core's DNS;
// the settings row now says so.
// B9-4: `app_lock_enabled` exists nowhere — row closed VOID.
// B9-5: EmberToggle carries switch semantics.
// B9-6: the 16 named IconButtons carry tooltips.

import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';

String _src(String rel) => File(rel).readAsStringSync();

void main() {
  group('B9-2 auto-connect triggers default OFF + migration', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('b9_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('fresh install: all three triggers OFF', () async {
      final s = await AppSettings.load(dir.path);
      expect(s.autoConnectOnBoot, isFalse);
      expect(s.autoConnectOnUntrustedWifi, isFalse);
      expect(s.autoConnectOnNetworkChange, isFalse);
    });

    test('a stored ON from before 2116 migrates OFF exactly once',
        () async {
      File('${dir.path}/app-settings.json').writeAsStringSync(
        jsonEncode({
          'auto_connect_boot': true,
          'auto_connect_untrusted_wifi': true,
          'auto_connect_network_change': true,
        }),
      );
      final s = await AppSettings.load(dir.path);
      expect(s.autoConnectOnBoot, isFalse);
      expect(s.autoConnectOnUntrustedWifi, isFalse);
      expect(s.autoConnectOnNetworkChange, isFalse);
      expect(s.defaultsReset2116, isTrue);
      expect(s.toJson()['defaults_reset_2116'], isTrue);
    });

    test('a trigger set after the migration is kept', () async {
      File('${dir.path}/app-settings.json').writeAsStringSync(
        jsonEncode({
          'auto_connect_boot': true,
          'auto_connect_untrusted_wifi': false,
          'auto_connect_network_change': false,
          'defaults_reset_2116': true,
        }),
      );
      final s = await AppSettings.load(dir.path);
      expect(s.autoConnectOnBoot, isTrue);
      expect(s.autoConnectOnUntrustedWifi, isFalse);
    });
  });

  group('B9-1 / B9-3 / B9-4 / B9-6 source pins', () {
    test('no second kill switch: AppSettings has no killSwitch field',
        () {
      expect(_src('lib/app_settings.dart').contains('killSwitch'),
          isFalse);
      final settings = _src('lib/ui/ember/ember_settings.dart');
      // Both visible rows bind the one XraySettings switch.
      expect('killSwitch'.allMatches(settings).length,
          greaterThanOrEqualTo(4));
      // Build 2125 re-point (A25-04): Psiphon and Lantern
      // ARE covered now — the copy names the two engines
      // that remain uncovered.
      expect(settings.contains('Mozilla and AmneziaWG are not'),
          isTrue);
      expect(settings.contains('Psiphon and Lantern are not covered'),
          isFalse);
    });

    test('B9-3: the localDns row scopes itself honestly', () {
      final settings = _src('lib/ui/ember/ember_settings.dart');
      expect(
          settings.contains(
              'Applies to WireGuard, Lantern and Psiphon'),
          isTrue);
    });

    test('B9-4: app_lock_enabled exists nowhere in lib/', () {
      final hits = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is File && e.path.endsWith('.dart')) {
          if (e.readAsStringSync().contains('app_lock_enabled')) {
            hits.add(e.path);
          }
        }
      }
      expect(hits, isEmpty);
    });

    test('B9-6: the 16 named IconButtons carry tooltips', () {
      final expectations = <String, List<String>>{
        // The OpenVPN four and the dnstt/warp save+refresh
        // buttons already carried tooltips BELOW the audit's
        // 6-line scan window ('Measure latency', 'Rename
        // profile', 'Delete profile', 'Save', 'Refresh') —
        // those shipped labels stand; the other nine sites
        // got theirs in this batch.
        'lib/ui/ember/openvpn_pages.dart': [
          "'Measure latency'",
          "'Saved credentials'",
          "'Rename profile'",
          "'Delete profile'",
        ],
        'lib/ui/ember/automation_pages.dart': [
          "'Move up'",
          "'Move down'",
          "'Remove'",
        ],
        'lib/ui/ember/aether_pages.dart': ["'Close'"],
        'lib/ui/ember/lantern_pages.dart': ["'Close'"],
        // PIN UPDATED by build 2149 (audit A48-04): the
        // WireGuard configurations view's 'Close' button
        // was removed — it duplicated the shell header's
        // BACK; the page has no close button by design now.
        'lib/ui/ember/map_widgets.dart': ["'Close'"],
        'lib/ui/ember/dnstt_settings_page.dart': ["'Save'", "'Refresh'"],
        'lib/ui/ember/warp_settings_page.dart': ["'Save'"],
        'lib/ui/ember/ember_servers.dart': ["'Refresh subscriptions'"],
        'lib/ui/settings_page.dart': ["'Hide password'"],
      };
      expectations.forEach((path, needles) {
        final src = _src(path);
        for (final n in needles) {
          expect(src.contains('tooltip:'), isTrue, reason: path);
          expect(src.contains(n), isTrue, reason: '$path $n');
        }
      });
    });
  });

  group('B9-5 EmberToggle semantics', () {
    testWidgets('the toggle exposes button + toggled semantics',
        (tester) async {
      final handle = tester.ensureSemantics();
      var value = false;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: EmberToggle(
                value: value,
                onChanged: (v) => setState(() => value = v),
              ),
            ),
          ),
        ),
      );
      final node = tester.getSemantics(find.byType(EmberToggle));
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isToggled, ui.Tristate.isFalse);
      await tester.tap(find.byType(EmberToggle));
      await tester.pump();
      final node2 = tester.getSemantics(find.byType(EmberToggle));
      expect(node2.flagsCollection.isToggled, ui.Tristate.isTrue);
      handle.dispose();
    });
  });
}
