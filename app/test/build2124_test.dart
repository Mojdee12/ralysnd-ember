// Build 2124 gates — the single-issue fix for the owner's
// 2026-11-20 device evidence (build 2123, 15:37 Tehran):
// the Psiphon library CONNECTED on his carrier (GB,
// FRONTED-MEEK-OSSH, ~6 s; "psiphon tunnel connected /
// Tunnels count 1" in the session log) but the app never
// registered it — its own establishment evidence at +60 s
// said "running past 60s with no tunnel", and the owner
// confirmed no connected state and no working traffic.
//
// Root cause (code-proven): watchBridge() queued its
// session-long 5 s loop on the service's single-thread
// worker — the thread that serializes every ladder move.
// The loop never returns while a session lives, so when
// onConnected queued the quality gate on the same worker,
// the gate never ran; the gate is the only path to
// activateRouting(), which holds the app's only
// Tun2SocksManager.start call and sets connected = true.
// Registration and the data path both starved behind the
// watcher, and the ladder's own escalation (also posted
// to the worker) starved with them.
//
// Fix pinned here: the watcher runs on its own daemon
// thread ("psiphon-bridge-watch"); the worker keeps the
// ladder moves it serializes (start, quality gate,
// escalation). What only the owner's phone can prove —
// a standalone Psiphon connect now showing Connected and
// passing traffic — is NOT claimed here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _kt(String name) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$name')
        .readAsStringSync();

String _region(String src, String from, String to) {
  // Called at group-declaration time, where expect() is not
  // available — a missing marker throws instead (the load
  // failure names the region, which is the same evidence).
  final a = src.indexOf(from);
  if (a < 0) throw StateError('region start "$from" not found');
  final b = src.indexOf(to, a);
  if (b < 0) throw StateError('region end "$to" not found');
  return src.substring(a, b);
}

void main() {
  group('build 2124: the bridge watcher leaves the worker', () {
    final svc = _kt('PsiphonVpnService.kt');
    final watch = _region(
      svc,
      'private fun watchBridge()',
      'private fun trackUnderlyingNetwork',
    );

    test('the watch loop is NOT queued on the worker', () {
      expect(watch, isNot(contains('worker.execute')));
    });

    test('the watch runs on its own daemon thread, same 5 s poll, '
        'same bridge-death teardown', () {
      expect(watch, contains('"psiphon-bridge-watch"'));
      expect(watch, contains('isDaemon = true'));
      expect(watch, contains('Thread.sleep(5000)'));
      expect(
        watch,
        contains('bridgeStarted && !Tun2SocksManager.isRunning'),
      );
      expect(
        watch,
        contains('psiphon bridge exited; tearing the session down'),
      );
      expect(watch, contains('stopTunnel()'));
    });

    test('startTunnel still arms the watcher after the core starts', () {
      final start = _region(
        svc,
        'private fun startTunnel()',
        'private fun beginSession()',
      );
      expect(
        start.indexOf('startPsiphonTunnel()'),
        lessThan(start.indexOf('watchBridge()')),
      );
    });
  });

  group('build 2124: the worker keeps the ladder serialization', () {
    final svc = _kt('PsiphonVpnService.kt');

    test('start, quality gate and escalation still queue on the worker',
        () {
      expect(svc, contains('worker.execute { startTunnel() }'));
      expect(svc, contains('worker.execute { psiphonQualityCheck('));
      expect(svc, contains('escalateLadder("no tunnel in'));
    });

    test('activateRouting is still the only tun2socks start and the '
        'place connected is set in VPN mode', () {
      expect('Tun2SocksManager.start('.allMatches(svc).length, 1);
      final routing = _region(
        svc,
        'private fun activateRouting()',
        'private fun psiphonQualityCheck',
      );
      expect(routing, contains('Tun2SocksManager.start('));
      expect(routing, contains('PsiphonConstants.SOCKS_PORT'));
      expect(routing, contains('connected = true'));
    });
  });
}
