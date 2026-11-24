// Build 2064 — Lantern "version too old" fix. Ember's
// LanternVpnService used to compute Ember's OWN app version
// ("${info.versionName}-${info.versionCode}", e.g. 2.2.0-2061)
// and pass it to the Lantern core as the -version flag. The
// core adopts that as RADIANCE_VERSION, Lantern's config
// service rejects it as a too-old client (HTTP 400 "bad client
// factors: version 2.2.0-2061 too old" — owner's device log,
// 2026-11-14), the config fetch fails, and connect dies with
// "no config to connect with". ralysnd's working LanternProcess
// passes NO version at all, so the byte-identical liblantern.so
// reports its own built-in Lantern version and is accepted.
// These pins fail on the pre-fix code shape and pass after.
//
// SUPERSEDED in build 2129 (leg 1, the gomobile swap): there
// is no CLI and no flag list any more. The 2064 lesson
// survives in its new form, re-pinned below: the bridge's
// Opts carries the OFFICIAL client's own version string
// ("10.0.5-beta.1", copied from LML's initialize — the core's
// config service accepts exactly its own client), and
// Ember's app version is never computed or passed anywhere
// in the Lantern path.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

void main() {
  final kt = ktSrc('LanternVpnService.kt');
  final bridge = File(
    'android/lantern-plugin-src/com/ralysnd/ember/lanternplugin/LanternEngine.java',
  ).readAsStringSync();

  group('build 2064 (as superseded by 2129) — Lantern never '
      'receives Ember\'s app version', () {
    test('no -version argument anywhere in the Lantern service', () {
      expect(kt.contains('"-version"'), isFalse,
          reason: 'the Lantern core must never be handed a -version flag');
    });

    test('no RADIANCE_VERSION is set for the Lantern core', () {
      expect(kt.contains('RADIANCE_VERSION'), isFalse);
      expect(bridge.contains('RADIANCE_VERSION'), isFalse);
    });

    test('no app versionName/versionCode computation feeds Lantern', () {
      expect(kt.contains('versionName'), isFalse);
      expect(kt.contains('versionCode'), isFalse);
      expect(kt.contains('getPackageInfo'), isFalse);
      expect(bridge.contains('versionName'), isFalse);
      expect(bridge.contains('getPackageInfo'), isFalse);
    });

    test('the Opts app version is the official client\'s, exactly', () {
      expect(bridge.contains('opts.setAppVersion("10.0.5-beta.1")'), isTrue);
    });

    test('there is no CLI args list left to carry a version', () {
      expect(kt.contains('"-socks"'), isFalse);
      expect(kt.contains('"-configdir"'), isFalse);
      expect(kt.contains('object LanternCore'), isFalse);
    });

    test('the deleted start-flag bootstrap stays deleted', () {
      expect(kt.contains('"-fetchvia"'), isFalse);
      expect(kt.contains('"-clientip"'), isFalse);
      expect(kt.contains('fun sendVia'), isFalse);
    });
  });
}
