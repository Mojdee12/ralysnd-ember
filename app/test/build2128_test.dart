// Build 2128 — Lantern full routing (smart routing removed).
//
// The core's -smart flag was never a "smart server choice"
// (its label from build 2032 to 2127): the shipped binary's
// own flag description is "Lantern's smart routing: also
// send the services it lists as safe (Apple, OneDrive)
// direct" — rule-listed destinations bypass the tunnel.
// Proven on device + server 2026-11-21: with smart routing
// on, the owner's browsing never reached his server (only
// Telegram-class traffic went through); the official app
// with Routing Mode OFF Smart carried everything through
// the same server. Worse, the core persists the choice in
// its own settings.json (data dir), the driver only ever
// writes it true, and nothing wrote it back off — one past
// smart start latched the bypass on for every later run.
//
// 2128's fix: the launch path never passes -smart again
// (plumbing removed end-to-end), and the Kotlin host
// merge-writes "smart_routing": false into the core's
// settings.json before every start.
//
// SUPERSEDED in build 2129 (leg 1, the gomobile swap): the
// CLI daemon and its settings.json are gone entirely. What
// survives of 2128's verdict, re-pinned below: no -smart
// anything anywhere; smart routing is forced OFF at every
// core init — now through the core's real API
// (Mobile.setSmartRoutingEnabled(false) in the bridge) —
// and the only way it turns on is the user's own toggle on
// the Lantern page (DEFAULT OFF), backed by the same API.
// The H8 server-mode surface 2128 left untouched is now the
// API registration (addServerManagerInstance), also pinned
// in build2129_lantern_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

void main() {
  final kt = ktSrc('LanternVpnService.kt');
  final mainActivity = ktSrc('MainActivity.kt');
  final platform = dartSrc('lantern/lantern_platform.dart');
  final controller = dartSrc('lantern/lantern_controller.dart');
  final pages = dartSrc('ui/ember/lantern_pages.dart');
  final bridge = File(
    'android/lantern-plugin-src/com/ralysnd/ember/lanternplugin/LanternEngine.java',
  ).readAsStringSync();

  group('build 2128 (as superseded by 2129) — no -smart flag anywhere', () {
    test('no -smart argument is built in the Lantern service', () {
      expect(kt.contains('"-smart"'), isFalse,
          reason: 'the core must never be handed a -smart flag');
      expect(kt.contains('args += "-smart"'), isFalse);
    });

    test('the CLI plumbing is out of the service entirely', () {
      expect(kt.contains('EXTRA_SMART ='), isFalse);
      expect(kt.contains('ProcessBuilder('), isFalse);
      expect(kt.contains('fun forceSmartRoutingOff'), isFalse);
      expect(kt.contains('"settings.json"'), isFalse);
    });

    test('MainActivity passes no smart launch argument for Lantern', () {
      final at = mainActivity.indexOf('lanternSetOn');
      expect(at, greaterThanOrEqualTo(0));
      final region = mainActivity.substring(at, at + 1500);
      expect(region.contains('LanternVpnService.start('), isTrue);
      // The only smart channel is the explicit toggle API.
      expect(mainActivity.contains('lanternSetSmartRouting'), isTrue);
    });
  });

  group('build 2128 verdict, 2129 mechanism — smart routing forced off', () {
    test('the bridge forces it off at init through the real API', () {
      expect(bridge.contains('Mobile.setSmartRoutingEnabled(false)'), isTrue);
    });

    test('the toggle exists, defaults OFF, and rides the API', () {
      expect(controller.contains('bool smartRouting = false;'), isTrue);
      expect(controller.contains('LanternPlatform.setSmartRouting(on)'), isTrue);
      expect(pages.contains("'Smart routing'"), isTrue);
      expect(pages.contains('lantern.smartRouting'), isTrue);
      expect(platform.contains("'lanternSetSmartRouting'"), isTrue);
    });

    test('the old "smart server choice" mislabel stays gone', () {
      expect(pages.contains('Smart server choice'), isFalse);
    });
  });

  group('build 2128 — the H8 server-mode surface, 2129 form', () {
    test('Smart/Private mode buttons stay; registration is the API', () {
      expect(pages.contains('Server mode'), isTrue);
      expect(pages.contains('setPrivateMode'), isTrue);
      expect(controller.contains('privateMode'), isTrue);
      expect(controller.contains('registerLanternPrivateServer'), isFalse);
      expect(controller.contains('LanternPlatform.addPrivateServer('), isTrue);
    });

    test('the backup notes name the server list alone', () {
      final settings = dartSrc('ui/ember/ember_settings.dart');
      final sync = dartSrc('ui/ember/ember_sync.dart');
      expect(settings.contains('the Lantern server list, '), isTrue);
      expect(sync.contains('the Lantern server list, '), isTrue);
      expect(sync.contains('smart-routing choice'), isFalse);
    });
  });
}
