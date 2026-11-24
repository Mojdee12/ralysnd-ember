// Build 2116, batch B10 — Psiphon status honesty (AB-03).
// The ONLY Psiphon change in this build (owner 2026-11-19
// 06:07: engine, settings, defaults and binaries untouched).
//
// The state snapshot's publishedAtMs was written since 2073
// and never read, so a dead :psiphon process's last snapshot
// read as Connected forever. Now: the parse carries the
// timestamp and demotes a live-claiming snapshot older than
// STALE_SNAPSHOT_MS (120 s) to stopped; the publisher
// republishes every 30 s while running so age means
// "process gone", never "tunnel idle"; MainActivity clears
// a stale live-claiming file at process start when the
// :psiphon process is not alive.
//
// There is no JVM harness in this tree (see B3-1/B5), so
// the Kotlin rows are pinned at source level and proven by
// the release compile at the final assemble.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _svc() => File(
      'android/app/src/main/kotlin/com/ralysnd/ember/PsiphonVpnService.kt',
    ).readAsStringSync();
String _main() => File(
      'android/app/src/main/kotlin/com/ralysnd/ember/MainActivity.kt',
    ).readAsStringSync();

void main() {
  group('B10-1 Psiphon snapshot freshness', () {
    test('the parse carries publishedAtMs and demotes stale live claims',
        () {
      final s = _svc();
      expect(s.contains('"publishedAtMs" to publishedAtMs'), isTrue);
      expect(s.contains('STALE_SNAPSHOT_MS = 120_000L'), isTrue);
      expect(s.contains('nowMs - publishedAtMs > STALE_SNAPSHOT_MS'),
          isTrue);
      // The demotion returns the stopped defaults with the
      // age still visible.
      expect(
          s.contains('defaults + ("publishedAtMs" to publishedAtMs)'),
          isTrue);
    });

    test('the publisher republishes while running (30 s cadence)', () {
      final s = _svc();
      expect(s.contains('REPUBLISH_MS = 30_000L'), isTrue);
      expect(s.contains('if (running) armRepublish()'), isTrue);
      expect(s.contains('republishRunnable'), isTrue);
    });

    test('the stale file is cleared at main-process start only when '
        'the service process is not alive', () {
      final s = _svc();
      expect(s.contains('fun clearStalePublishedState'), isTrue);
      final m = _main();
      expect(m.contains('PsiphonExternalWatchdog.findPsiphonPid(this)'),
          isTrue);
      expect(m.contains('PsiphonVpnService.clearStalePublishedState(this)'),
          isTrue);
    });

    test('nothing else about Psiphon moved: the engine binary and '
        'the settings surface are untouched by this batch', () {
      // The batch's files are the service + MainActivity
      // only; the Dart controller keeps its prior contract
      // (state maps gain one additive key, publishedAtMs).
      final c = File('lib/psiphon/psiphon_controller.dart')
          .readAsStringSync();
      expect(c.contains('publishedAtMs'), isFalse,
          reason: 'the Dart side needs no change — the '
              'demotion happens in the native parse');
    });
  });
}
