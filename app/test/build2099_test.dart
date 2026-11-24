// Build 2099 — owner order 2026-11-17 23:21: fix OpenVPN
// completely + WireGuard, one cumulative build. Contents:
// (A) the updater install crash (FileProvider path), (B) the
// OpenVPN data plane (real LZO, compression default, IPv6
// capture, MTU default, probe hardening, core-error
// surfacing), (C) WireGuard/AWG containment + instrumentation
// (breadcrumbs, bridge log file, recover(), stage markers).
// These pins are source-level on purpose: the failures they
// guard were all "the pieces were individually right and
// jointly wrong" — exactly what a relational pin catches.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

void main() {
  group('A — updater FileProvider path matches the download dir', () {
    test('the XML files-path equals dataDir-child + updater-child', () {
      final xml = File(
        'android/app/src/main/res/xml/ember_file_paths.xml',
      ).readAsStringSync();
      final xmlMatch = RegExp(
        r'<files-path[^>]*path="([^"]+)"',
      ).firstMatch(xml);
      expect(xmlMatch, isNotNull, reason: 'ember_file_paths.xml files-path');
      final xmlPath = xmlMatch!.group(1)!;

      // The Kotlin half of the download path: CoreService.dataDir
      // is File(filesDir, "<child>").
      final core = ktSrc('CoreService.kt');
      final coreMatch = RegExp(
        r'File\(context\.filesDir,\s*"([^"]+)"\)',
      ).firstMatch(core);
      expect(coreMatch, isNotNull, reason: 'CoreService.dataDir child');
      final coreChild = coreMatch!.group(1)!;

      // The Dart half: the updater downloads into
      // Directory('$dataDir<sep>updates') — the child name is
      // read out of ember_updater.dart, not restated here, so
      // renaming either side breaks this pin instead of the
      // owner's install.
      final updater = dartSrc('ui/ember/ember_updater.dart');
      final updMatch = RegExp(
        r"Directory\('\$dataDir\$\{Platform\.pathSeparator\}([A-Za-z0-9_]+)'\)",
      ).firstMatch(updater);
      expect(updMatch, isNotNull, reason: 'updater download child');
      final updChild = updMatch!.group(1)!;

      expect(
        xmlPath,
        '$coreChild/$updChild/',
        reason:
            'FileProvider must expose exactly the folder the updater '
            'downloads into (files/$coreChild/$updChild/); anything '
            'else throws in getUriForFile at install time, as it did '
            'on builds 2096-2098.',
      );
    });
  });

  group('B — OpenVPN service fixes', () {
    test('the core event callback carries the scrubbed info string', () {
      final svc = ktSrc('OpenVpnService.kt');
      // The bridge looks this exact shape up by JNI signature
      // (Ljava/lang/String;ZLjava/lang/String;)V; a 2-arg
      // remnant would fail the lookup and break every session.
      expect(
        svc,
        contains('fun onCoreEvent(name: String, error: Boolean, info: String)'),
      );
      // B7: the catch-all keeps the exception's own words.
      expect(svc, contains('CONNECTION_FAILED: \$message'));
    });

    test('IPv6 capture is conditional and the MTU has a default', () {
      final svc = ktSrc('OpenVpnService.kt');
      // B3: ::/0 only when an IPv6 address was actually applied.
      expect(
        svc,
        contains("val ipv6Applied = appliedAddresses.any { it.contains(':') }"),
      );
      // B4: no tun-mtu anywhere -> 1400 applied, not platform chance.
      expect(svc, contains('appliedMtu = 1400'));
    });

    test('the NO_DATA verdict is two-target and counter-checked', () {
      final svc = ktSrc('OpenVpnService.kt');
      // B5: a second independent probe target exists, and the
      // verdict snapshots the core's byte counters on entry.
      expect(svc, contains('probeGenerate204'));
      expect(svc, contains('www.google.com/generate_204'));
      expect(svc, contains('downAtStart'));
      // Verification-loop V2 (build 2099): the counter rule
      // itself — a re-snapshot after the first failed attempt
      // (so the probes' own tunnel DNS no longer counts) and a
      // threshold strictly greater than DNS chatter. A bare
      // "counters moved at all" comparison must not come back.
      expect(svc, contains('downCounterBaseline'));
      expect(
        svc,
        contains('downDelta > COUNTER_VERIFY_THRESHOLD_BYTES'),
      );
    });

    test('the Dart connect poll does not expire during verifying', () {
      // Verification-loop V8 (build 2099): the native V1 fix
      // lets the verify window outlive the old connect
      // deadline; the Dart poll has its own 90 s budget and
      // must extend it while the session phase is verifying,
      // or a session that is about to verify surfaces a
      // spurious connect-timeout.
      final controller = dartSrc('openvpn/openvpn_controller.dart');
      expect(controller, contains('verifyingSince'));
      expect(controller, contains("_state.phase == 'verifying'"));
    });
  });

  group('C — WireGuard/AWG instrumentation', () {
    // Build 2100 (W-WG2, named reason): the AWG path moved out
    // of XrayVpnService.kt into AwgVpnService.kt (:awg process).
    // The strings are the same 2099 breadcrumbs; only the file
    // changed. The 2099 pins are relocated, not weakened.
    test('the AWG path writes breadcrumbs around its native calls', () {
      // Build 2104: the path is WgTunnelEngine.start — the
      // breadcrumb pair wraps the backend start the way the
      // 2099 pair wrapped turnOn: invoked before it, and the
      // outcome (connected / start-failed) right after, so a
      // traceless death still localizes to the last stage in
      // the next diagnostics export.
      final engine = ktSrc('WgTunnelEngine.kt');
      expect(engine, contains('awg:start-invoked'));
      expect(engine, contains('awg:connected'));
      expect(engine, contains('awg:start-failed'));
      expect(engine, contains('awg:stop-invoked'));
      final invoked = engine.indexOf('awg:start-invoked');
      final start = engine.indexOf('backend.start(');
      expect(invoked, lessThan(start),
          reason: 'the stage marker precedes the native start');
    });

    test('the engine log file is wired end to end', () {
      // Build 2104: the bridge's setLogFile is gone with the
      // bridge; the backend's logger is pointed at the same
      // file by WgTunnelEngine's kermit writer, installed
      // before the backend is constructed.
      final engine = ktSrc('WgTunnelEngine.kt');
      expect(engine, contains('Logger.setLogWriters'));
      expect(engine, contains('AwgLogWriter'));
      expect(engine, contains('"awg.log"'));
      // C2: the diagnostics bundle reads (and Clear empties)
      // awg.log from the same workDir group as xray.log.
      final controller = dartSrc('xray/xray_controller.dart');
      expect(controller, contains("'awg.log'"));
    });
  });
}
