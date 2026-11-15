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
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

void main() {
  final kt = ktSrc('LanternVpnService.kt');

  group('build 2064 — Lantern never receives Ember\'s app version', () {
    test('no -version argument anywhere in the Lantern service', () {
      expect(kt.contains('"-version"'), isFalse,
          reason: 'the Lantern core must never be handed a -version flag');
    });

    test('no RADIANCE_VERSION is set for the Lantern core', () {
      expect(kt.contains('RADIANCE_VERSION'), isFalse);
    });

    test('no app versionName/versionCode computation feeds Lantern', () {
      expect(kt.contains('versionName'), isFalse);
      expect(kt.contains('versionCode'), isFalse);
      expect(kt.contains('getPackageInfo'), isFalse);
    });

    test('LanternCore.start signature carries no version parameter', () {
      final objAt = kt.indexOf('object LanternCore');
      expect(objAt, greaterThanOrEqualTo(0));
      final fnAt = kt.indexOf('fun start(', objAt);
      expect(fnAt, greaterThan(objAt));
      final sigEnd = kt.indexOf(') {', fnAt);
      final sig = kt.substring(fnAt, sigEnd);
      expect(sig.contains('version'), isFalse,
          reason: 'start() must not accept a version: $sig');
      expect(sig.contains('context: Context'), isTrue);
      expect(sig.contains('smart: Boolean'), isTrue);
    });

    test('the core args list has no version entry', () {
      final argsAt = kt.indexOf('mutableListOf(');
      expect(argsAt, greaterThanOrEqualTo(0));
      final argsEnd = kt.indexOf(')', kt.indexOf('"-sysdns"', argsAt));
      // Strip comment lines: the build-2064 note inside the args
      // block explains the removal in prose; only code counts.
      final args = kt
          .substring(argsAt, argsEnd)
          .split('\n')
          .where((l) => !l.trim().startsWith('//'))
          .join('\n');
      expect(args.contains('version'), isFalse,
          reason: 'args list must carry no version entry: $args');
      // The ralysnd-parity flags stay.
      expect(args.contains('"-socks"'), isTrue);
      expect(args.contains('"-http"'), isTrue);
      expect(args.contains('"-configdir"'), isTrue);
      expect(args.contains('"-control"'), isTrue);
      expect(args.contains('"-sysdns"'), isTrue);
    });

    test('the only start call site passes no version', () {
      expect(kt.contains('LanternCore.start(this, smart)'), isTrue);
      expect(kt.contains('LanternCore.start(this, version'), isFalse);
    });

    test('the 2052 stdin via bootstrap is untouched', () {
      // The fix must not resurrect the deleted start-flag
      // bootstrap or disturb the running-core stdin mechanism.
      expect(kt.contains('"-fetchvia"'), isFalse);
      expect(kt.contains('"-clientip"'), isFalse);
      expect(kt.contains('sendVia'), isTrue);
    });
  });
}
