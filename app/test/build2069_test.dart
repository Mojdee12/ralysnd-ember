// Build 2069 — the TRANSPLANT build: ralysnd's complete
// Psiphon stack replaced Ember's rebuilt core, by the
// owner's direct order. Its pins fingerprinted the
// transplanted AAR (libpgjni.so size + CRC-32, classes.jar),
// the v2.0.39 HostService adaptation, the stock-field
// config parity, and the Beast withdrawal.
//
// Build 2089 REWRITE of this file: the transplant did not
// survive the owner's phone either. His verdict on 2088 —
// and his report that ralysnd's own app crashes the same
// way on the same phone — closed the AAR line entirely:
// the fault sits at the old-core-vs-Android-16 layer, so
// build 2089 replaces the provider with the
// hiddify-sing-box sidecar (libpsiphonbox.so; PsiphonBoxCore)
// and DELETES libs/psiphon.aar. The AAR fingerprint pins
// are therefore replaced by removal pins — an AAR that
// quietly came back would resurrect the wedge — and the
// still-living parts of 2069's brief (Beast honesty, the
// start-phase log flushing, the Throwable-wide start
// catch) are re-pinned against the new service shape.
//
// Build 2091 REWRITE of this file: the owner ordered the
// COMPLETE MLM implementation, from its source — and the
// complete implementation was never what Ember ran (2069
// took the AAR with an adapted host; 2089/2090 replaced it
// with the sidecar). The AAR is RESTORED, byte-exact, and
// MLM's host is ported verbatim into the service. The
// removal pins flip back to presence pins (an AAR that
// quietly went missing would resurrect the sidecar's
// no-connect), the config parity group points at the
// Kotlin builder again, and the start-phase / start-catch
// pins point at onConnected / failAndStop /
// startPsiphonTunnel. The still-living parts (Beast
// honesty, the start-phase log flushing) are re-pinned
// against the new service shape, unchanged in substance.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/psiphon/psiphon_controller.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

/// The source from one marker to the next.
String segmentOf(String source, String from, String to) {
  final start = source.indexOf(from);
  expect(start, isNonNegative, reason: '"$from" exists');
  final end = source.indexOf(to, start);
  expect(end, isNonNegative, reason: '"$to" bounds "$from"');
  return source.substring(start, end);
}

void main() {
  final service = ktSrc('PsiphonVpnService.kt');
  final constants = ktSrc('PsiphonConstants.kt');
  final mainActivity = ktSrc('MainActivity.kt');
  final controller = dartSrc('psiphon/psiphon_controller.dart');
  final platform = dartSrc('psiphon/psiphon_platform.dart');
  final pages = dartSrc('ui/ember/psiphon_pages.dart');

  group('the transplant is RESTORED (build 2091): the AAR '
      'is back, the sidecar is out of the APK', () {
    test('libs/psiphon.aar is staged and wired, and the '
        'sidecar .so is out of the APK', () {
      expect(File('android/app/libs/psiphon.aar').existsSync(),
          isTrue);
      final gradle =
          File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle.contains('libs/psiphon.aar")'), isTrue);
      expect(
        File(
          'android/app/src/main/jniLibs/arm64-v8a/libpsiphonbox.so',
        ).existsSync(),
        isFalse,
      );
    });

    test('the service hosts the library: the wrapper, the '
        'HostService, the callbacks', () {
      expect(service.contains('PsiphonTunnel'), isTrue);
      expect(service.contains('HostService'), isTrue);
      expect(service.contains('override fun getPsiphonConfig()'),
          isTrue);
      expect(service.contains('override fun onConnected()'),
          isTrue);
      expect(service.contains('override fun bindToDevice('),
          isTrue);
      expect(service.contains('loadLibrary'), isFalse);
    });

    test('the recovered wrapper\u2019s silencer -dontwarn '
        'rules are GONE (build 2123: S-1 bundles the classes '
        'they hid)', () {
      // Build 2091: R8 hard-errors on the recovered
      // wrapper's dangling references (f0.a from pg.Seq$Ref
      // — see missing_rules.txt) without these, and MLM's
      // own rules keep the pg/psi packages whole.
      // Build 2123 supersession (recorded, not silent):
      // the three silencers existed only because wf.*,
      // f0.a and w3.z were MISSING — the NoClassDefFoundError
      // behind every failed Psiphon start (plan S-1).
      // wf.jar now bundles them, so the silencer RULES are
      // removed and keeps stand in their place; the pg/psi
      // rules are unchanged. Rule lines only — the proguard
      // comments still name the removed rules historically.
      final proguard =
          File('android/app/proguard-rules.pro').readAsStringSync();
      final rules = proguard
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .join('\n');
      expect(rules.contains('-dontwarn f0.a'), isFalse);
      expect(rules.contains('-dontwarn wf.c'), isFalse);
      expect(rules.contains('-dontwarn w3.z'), isFalse);
      expect(proguard.contains('-keep class pg.**'), isTrue);
      expect(proguard.contains('-keep class psi.**'), isTrue);
      expect(proguard.contains('-dontwarn pg.**'), isTrue);
      expect(proguard.contains('-dontwarn psi.**'), isTrue);
    });
  });

  group('config parity: the config lives in the Kotlin '
      'builder again (build 2091)', () {
    test('the AdditionalParameters blob is gone — from the '
        'emission and from the constants', () {
      expect(service.contains('AdditionalParameters'), isFalse);
      expect(constants.contains('ADDITIONAL_PARAMETERS'), isFalse);
      // The explicit official lists it used to override are
      // still the config's, now in the constants.
      expect(constants.contains('RemoteServerListURLs'), isTrue);
      expect(constants.contains('ObfuscatedServerListRootURLs'), isTrue);
    });

    test('no fork-only fields are emitted anywhere', () {
      expect(constants.contains('AggressiveEstablishment'), isFalse);
      expect(constants.contains('FrontedMeekDialOverrides'), isFalse);
      expect(constants.contains('FrontedMeekCDNScanSpec'), isFalse);
      expect(constants.contains('FRONTED_CDN_PROTOCOLS'), isFalse);
      expect(constants.contains('"FRONTED-MEEK-CDN-OSSH"'), isFalse);
      expect(service.contains('"FRONTED-MEEK-CDN-OSSH"'), isFalse);
    });

    test('the clean-IP steering is BACK on rung E (build '
        '2091: MLM, not a fork slot)', () {
      expect(service.contains('putPreresolvedCidrs'), isFalse);
      expect(
          service.contains('DNSResolverPreresolvedIPAddressCIDRs'),
          isTrue);
    });

    test('the dial-override channel stays gone end to end', () {
      expect(service.contains('EXTRA_EDGE_OVERRIDES'), isFalse);
      expect(service.contains('ladderEdgeOverrides'), isFalse);
      expect(mainActivity.contains('argument<String>("edgeOverrides")'),
          isFalse);
      expect(platform.contains("'edgeOverrides'"), isFalse);
      expect(controller.contains('_edgeOverridesJson'), isFalse);
    });
  });

  group('Beast honesty: no dead toggle survives (kept from '
      '2069)', () {
    test('the UI has no Beast row, and fronting no longer '
        'claims a fork core', () {
      expect(pages.contains("'Beast Mode'"), isFalse);
      expect(pages.contains('settings.beastMode'), isFalse);
      expect(pages.contains('CDN fronting (fork core)'), isFalse);
      expect(pages.contains("'CDN fronting'"), isTrue);
    });

    test('the setting, its persistence, and the channel key '
        'are gone', () {
      expect(controller.contains('bool beastMode'), isFalse);
      expect(controller.contains("'beastMode':"), isFalse);
      expect(platform.contains("'beast':"), isFalse);
      expect(platform.contains('bool beast'), isFalse);
      expect(mainActivity.contains('argument<Boolean>("beast")'), isFalse);
    });

    test('the service carries no beast plumbing', () {
      expect(service.contains('EXTRA_BEAST'), isFalse);
      expect(service.contains('ladderBeast'), isFalse);
    });

    test('a carried-over store with a beastMode key still '
        'loads — the key is simply unknown now', () {
      final s = PsiphonSettings.fromJson({
        'beastMode': false,
        'region': 'NL',
        'cdnFronting': false,
      });
      expect(s.region, 'NL');
      expect(s.cdnFronting, isFalse);
      expect(s.toJson().containsKey('beastMode'), isFalse);
    });
  });

  group('start-phase synchronous flushing: no failure can '
      'hide behind the buffer again (kept from 2069)', () {
    test('the flag exists and is volatile', () {
      expect(
        service.contains(
            '@Volatile\n    private var logStartPhaseSync = false'),
        isTrue,
      );
    });

    test('openLog enters the start phase and flushes the '
        'header immediately', () {
      final openLog = segmentOf(
        service,
        'private fun openLog',
        'private fun logLine',
      );
      expect(openLog.contains('logStartPhaseSync = true'), isTrue);
      expect(
        openLog.indexOf('logStartPhaseSync = true'),
        greaterThan(openLog.indexOf('psiphon session')),
      );
      expect(
        openLog.indexOf('logWriter?.flush()'),
        greaterThan(openLog.indexOf('logStartPhaseSync = true')),
      );
    });

    test('writeLogRawLocked flushes every line while the '
        'flag holds, buffered policy otherwise', () {
      final raw = segmentOf(
        service,
        'private fun writeLogRawLocked',
        'private fun closeLogLocked',
      );
      expect(
        raw.contains('logStartPhaseSync || logBytesSinceFlush >= 8192'),
        isTrue,
      );
    });

    test('connected, fail, and stop each end the start phase',
        () {
      // Build 2091: "connected" is the core's onConnected
      // callback again (was: the probe's first success in
      // 2089–2090); "fail" is failAndStop, which stops the
      // tunnel — and stopTunnel ends the phase itself.
      final connected = segmentOf(
        service,
        'override fun onConnected()',
        'private fun scheduleLadderAttribution',
      );
      expect(connected.contains('logStartPhaseSync = false'), isTrue);
      final failFn = service.substring(
        service.indexOf('private fun failAndStop('),
        // Build 2125 re-point (A25-04): failAndStop first
        // routes an established, kill-switch-on session to
        // the hold; the stopTunnel() call sits just past
        // the old 200-char window.
        service.indexOf('private fun failAndStop(') + 300,
      );
      expect(failFn.contains('stopTunnel()'), isTrue);
      expect(failFn.contains('holdKillSwitch(reason)'), isTrue);
      final stopFn = segmentOf(
        service,
        'private fun stopTunnel()',
        'private fun stopProcesses()',
      );
      expect(stopFn.contains('logStartPhaseSync = false'), isTrue);
    });
  });

  group('startTunnel catch: Throwable, recorded, then fail '
      '(kept from 2069)', () {
    test('the catch is Throwable-wide and records to '
        'crash.log before failing', () {
      final start = segmentOf(
        service,
        'private fun startPsiphonTunnel()',
        'private fun rungSeconds',
      );
      expect(start.contains('catch (e: Throwable)'), isTrue);
      expect(
        start.contains(
            'CrashLog.append(this, "PsiphonVpnService.startPsiphonTunnel", e)'),
        isTrue,
      );
      expect(
        start.indexOf(
            'CrashLog.append(this, "PsiphonVpnService.startPsiphonTunnel", e)'),
        lessThan(start.lastIndexOf('failAndStop(')),
      );
    });
  });
}
