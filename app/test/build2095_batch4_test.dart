/// Build 2095, batch 4 — wrong-slot/settings (whole-app
/// journey audit #6, #13, #14).
///
/// - #6: the Settings row in WARP/MASQUE mode opens the
///   on-screen Aether slot's own options page, and the CF
///   scanner's endpoint tile writes the slot it names
///   (AetherOptions.peer from an Aether entry; the EmberWarp
///   tile is labelled EmberWarp).
/// - #13: Mozilla settings never fabricate values on a core
///   read failure, edit/setMode errors surface, and the
///   transport (H2/H3) choice exists in the Ember section.
/// - #14: a failed location pick is said out loud, and the
///   Recommended row (empty selection) exists in the list.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/aether/aether_controller.dart';
import 'package:firefox_vpn/ui/ember/aether_pages.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('source pins', () {
    test('the WARP section opens the slot it names', () {
      final dart = _read('lib/ui/ember/ember_settings.dart');
      expect(dart, contains('AetherOptionsPage(controller: c, xray: xray)'));
      final pages = _read('lib/ui/ember/aether_pages.dart');
      expect(pages, contains('class AetherOptionsPage'));
      expect(pages, contains('aether: controller'));
      // The options page edits through the home pages' store.
      expect(pages, contains('controller.setOptions('));
    });

    test('the CF scanner writes the slot its tile names', () {
      final dart = _read('lib/ui/ember/cf_scanner_page.dart');
      expect(dart, contains("pop('aether')"));
      expect(dart, contains('aether.options.copyWith(peer:'));
      expect(dart, contains('As the EmberWarp gateway'));
      expect(dart, contains('Pins the EmberWarp gateway to'));
    });

    test('Mozilla settings: no fabrication, errors surface, transport', () {
      final dart = _read('lib/ui/ember/ember_settings.dart');
      final section = dart.substring(dart.indexOf('class _MozillaSection'));
      // The fabrication is gone: the catch records failure
      // and nulls the values instead of inventing them.
      expect(section, contains('_loadFailed = true'));
      expect(section, isNot(contains('_routing = false;')));
      expect(section, contains('Could not be read from the core'));
      // Edit and mode errors reach a SnackBar.
      expect(section, contains('The core did not accept that change'));
      expect(section, contains('The connection mode did not change'));
      // The transport choice writes proxy.transport.
      expect(section, contains("proxy['transport'] = v"));
    });

    test('location pick surfaces failures and offers Recommended', () {
      final dart = _read('lib/ui/ember/ember_servers.dart');
      expect(dart, contains('The location did not change'));
      expect(dart, contains("onTap: () => _pick('')"));
      expect(dart, contains('l.recommendedLocation'));
    });
  });

  group('AetherOptionsPage', () {
    testWidgets('the WARP slot page shows its own controls', (tester) async {
      final warp = AetherController('cfwarp');
      final xray = XrayController();
      addTearDown(xray.dispose);
      await tester.pumpWidget(
        MaterialApp(home: AetherOptionsPage(controller: warp, xray: xray)),
      );
      await tester.pump();
      expect(find.text('WARP options'), findsOneWidget);
      expect(find.text('Scan profile'), findsOneWidget);
      expect(find.text('Address family'), findsOneWidget);
      expect(find.text('Clean-IP scanner'), findsOneWidget);
      expect(find.text('EmberWarp profile'), findsOneWidget);
    });

    testWidgets('the MASQUE slot page shows protocol + transport', (
      tester,
    ) async {
      final masque = AetherController('masque');
      final xray = XrayController();
      addTearDown(xray.dispose);
      await tester.pumpWidget(
        MaterialApp(home: AetherOptionsPage(controller: masque, xray: xray)),
      );
      await tester.pump();
      expect(find.text('MASQUE options'), findsOneWidget);
      expect(find.text('Protocol'), findsOneWidget);
      expect(find.text('Transport'), findsOneWidget);
      expect(find.text('Fragment the HTTP/2 handshake'), findsOneWidget);
    });
  });
}
