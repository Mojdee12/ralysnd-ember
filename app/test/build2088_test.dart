/// Build 2088 gates — the Psiphon wedge, round two.
///
/// Build 2087's F1–F3 got a NEGATIVE device verdict
/// (2026-11-16 03:49 Tehran): the heartbeat fired ONCE, the
/// data-root wipe ran, and the hang frontier did not move —
/// psiphon.log still ends at "stopping Psiphon library", and
/// the in-process watchdog's `psiphon:start-wedged` record
/// NEVER landed although ~28 s passed. Two theories died
/// with that paste: the stale data root (the wipe ran; the
/// wedge did not care), and self-instrumentation (a process
/// wedged this hard cannot write its own record).
///
/// This build moves the net OUTSIDE the wedged process:
///   1. An external watchdog: the Dart connect path arms a
///      25 s deadline per attempt (psiphon_watchdog.dart —
///      the decision pinned below); on firing, the MAIN
///      process finds the :psiphon pid, writes
///      `psiphon:external-watchdog` + a /proc thread dump to
///      crash.log, kills the process, and publishes the
///      wedged state the connect path fails fast on. The
///      discriminator is the newly published startReturned
///      flag: the watchdog fires only while the start call
///      itself is still inside the library — a healthy but
///      slow establishment (start returned, ladder budgets
///      running) never fires it.
///   2. F4 warm-up: before the start sequence, one trivial
///      native call (Psi.getBuildInfo) on a sacrificial
///      thread with a 5 s bound — `psiphon:warmup-returned`
///      vs `psiphon:warmup-wedged` separates a library that
///      cannot be entered from a start that wedges later.
///   3. Cold-process stop-skip: a stop is issued only for a
///      library that actually started in this process
///      (libraryStartedInProcess, set only after a start
///      call returns); cold starts and cold stops breadcrumb
///      `psiphon:stop-skipped-cold`. The bounded stop for
///      in-process restarts is unchanged.
/// What only the owner's phone can prove — which of the new
/// breadcrumbs his next start produces, and whether Psiphon
/// then connects — is NOT claimed here.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_platform.dart';
import 'package:firefox_vpn/psiphon/psiphon_watchdog.dart';

String _kt(String name) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$name')
        .readAsStringSync();

String _dart(String path) => File('lib/$path').readAsStringSync();

/// The text of one function in a source file: from [start]
/// up to (not including) the next occurrence of [end].
String _region(String src, String start, String end) {
  final a = src.indexOf(start);
  expect(a, greaterThanOrEqualTo(0), reason: '$start is present');
  final b = src.indexOf(end, a);
  expect(b, greaterThan(a), reason: '$end follows $start');
  return src.substring(a, b);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PsiphonWatchdog — the external deadline decision', () {
    final t0 = DateTime(2026, 11, 16, 4, 0, 0);

    PsiphonWatchdog armed() => PsiphonWatchdog()..arm(t0);

    bool ev(
      PsiphonWatchdog w,
      Duration age, {
      bool running = true,
      bool connected = false,
      bool wedged = false,
      bool startReturned = false,
    }) =>
        w.evaluate(
          now: t0.add(age),
          running: running,
          connected: connected,
          wedged: wedged,
          startReturned: startReturned,
        );

    test('fires at the deadline while the start call is inside', () {
      final w = armed();
      expect(ev(w, const Duration(seconds: 24)), isFalse);
      expect(ev(w, const Duration(seconds: 25)), isTrue);
      expect(w.fired, isTrue);
      // Exactly once: a second firing would kill the NEXT
      // attempt's fresh process.
      expect(ev(w, const Duration(seconds: 30)), isFalse);
    });

    test('a returned start never fires, however slow the connect', () {
      final w = armed();
      // The ladder's budgets legitimately run for minutes
      // after the start call returned; the watchdog is not
      // a connect timeout and must not become one.
      expect(
        ev(w, const Duration(minutes: 5), startReturned: true),
        isFalse,
      );
    });

    test('a resolved attempt never fires', () {
      final w = armed();
      expect(
        ev(w, const Duration(seconds: 30), connected: true),
        isFalse,
      );
      expect(
        ev(w, const Duration(seconds: 30), wedged: true),
        isFalse,
      );
    });

    test('never reported running: the short window fires', () {
      final w = armed();
      expect(
        ev(w, const Duration(seconds: 7),
            running: false, startReturned: true),
        isFalse,
      );
      expect(
        ev(w, const Duration(seconds: 8),
            running: false, startReturned: true),
        isTrue,
      );
    });

    test('ever-running latches: the short window closes behind it',
        () {
      final w = armed();
      // Running was seen once (5 s): the never-started branch
      // is dead from here, even if the process then vanishes.
      expect(ev(w, const Duration(seconds: 5)), isFalse);
      expect(
        ev(w, const Duration(seconds: 9),
            running: false, startReturned: true),
        isFalse,
      );
      // But a start call that never returned still fires at
      // the deadline, running or not.
      expect(
        ev(w, const Duration(seconds: 26), running: false),
        isTrue,
      );
    });

    test('unarmed and disarmed watchdogs never fire', () {
      final w = PsiphonWatchdog();
      expect(
        w.evaluate(
          now: t0.add(const Duration(minutes: 1)),
          running: true,
          connected: false,
          wedged: false,
          startReturned: false,
        ),
        isFalse,
      );
      final w2 = armed()..disarm();
      expect(ev(w2, const Duration(minutes: 1)), isFalse);
    });
  });

  group('Psiphon — the external watchdog end to end (Dart)', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'), null);
    });

    Map<String, dynamic> stateMap({
      required bool running,
      required bool connected,
      required bool wedged,
      required bool startReturned,
    }) =>
        {
          'running': running,
          'connected': connected,
          'vpnMode': true,
          'sinceMs': 1,
          'up': 0,
          'down': 0,
          'region': '',
          'clientAddress': '',
          'regions': <String>[],
          'method': '',
          'wedged': wedged,
          'startReturned': startReturned,
        };

    test('a start stuck inside the library is fired on, once, '
        'and the published wedge ends the connect', () async {
      final t0 = DateTime(2026, 11, 16, 4, 0, 0);
      var fakeNow = t0;
      var stateCalls = 0;
      var watchdogCalls = 0;
      var wedgedPublished = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'),
              (call) async {
        switch (call.method) {
          case 'psiphonState':
            stateCalls++;
            // The deadline passes while the attempt hangs.
            if (stateCalls >= 2) {
              fakeNow = t0.add(const Duration(seconds: 26));
            }
            return stateMap(
              running: true,
              connected: false,
              wedged: wedgedPublished,
              startReturned: false,
            );
          case 'psiphonExternalWatchdog':
            watchdogCalls++;
            // The native firing publishes the wedge.
            wedgedPublished = true;
            return {'found': true, 'killed': true, 'pid': 4242};
        }
        return null;
      });
      final c = PsiphonController();
      c.nowForWatchdog = () => fakeNow;
      c.settings.edgesTestedAtMs =
          DateTime.now().millisecondsSinceEpoch;
      await expectLater(
        c.connect().timeout(const Duration(seconds: 10)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'start-wedged',
          ),
        ),
      );
      expect(watchdogCalls, 1);
      expect(c.lastError, contains('got stuck while starting'));
      expect(c.connecting, isFalse);
      c.dispose();
    });

    test('a slow connect whose start returned is left alone',
        () async {
      final t0 = DateTime(2026, 11, 16, 4, 0, 0);
      var fakeNow = t0;
      var stateCalls = 0;
      var watchdogCalls = 0;
      var stopped = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'),
              (call) async {
        switch (call.method) {
          case 'psiphonState':
            stateCalls++;
            if (stateCalls >= 2) {
              fakeNow = t0.add(const Duration(minutes: 2));
            }
            return stateMap(
              running: !stopped,
              connected: stateCalls >= 3,
              wedged: false,
              startReturned: true,
            );
          case 'psiphonExternalWatchdog':
            watchdogCalls++;
            return {'found': false, 'killed': false, 'pid': -1};
          case 'psiphonStop':
            stopped = true;
            return null;
        }
        return null;
      });
      final c = PsiphonController();
      c.nowForWatchdog = () => fakeNow;
      c.settings.edgesTestedAtMs =
          DateTime.now().millisecondsSinceEpoch;
      await c.connect().timeout(const Duration(seconds: 10));
      expect(watchdogCalls, 0);
      expect(c.state.connected, isTrue);
      c.dispose();
    });

    test('the platform state parses the startReturned flag', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'),
              (call) async {
        if (call.method == 'psiphonState') {
          return stateMap(
            running: true,
            connected: false,
            wedged: false,
            startReturned: false,
          );
        }
        return null;
      });
      final s = await PsiphonPlatform.state();
      expect(s.startReturned, isFalse);
    });

    test('a snapshot without the flag reads as returned', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'),
              (call) async {
        if (call.method == 'psiphonState') {
          final m = stateMap(
            running: true,
            connected: false,
            wedged: false,
            startReturned: false,
          );
          m.remove('startReturned');
          return m;
        }
        return null;
      });
      // A pre-2088 snapshot must never arm the watchdog.
      final s = await PsiphonPlatform.state();
      expect(s.startReturned, isTrue);
    });
  });

  // Build 2089: F4 (the warm-up probe) and the cold-process
  // stop-skip guarded the frontier of an in-process library
  // — a first call that might never return, and a stop that
  // was itself that call. The library is gone (the provider
  // is a sidecar process), so both are REMOVED with it, and
  // this group pins the removal plus what survives: the
  // published startReturned discriminator, now bracketing
  // the spawn (see build2087_test.dart's retarget pin).
  //
  // Build 2091: the library is BACK (the MLM transplant), so
  // the stop is a library call again — but a DETACHED one on
  // the "psiphon-stop" thread, never the wedged in-process
  // stop the skip guarded. The cold-process skip itself
  // stays gone: stopPsiphonCore() always runs. The warm-up
  // probe stays gone too — the library call to warm no
  // longer exists as a separate first call; the start call
  // itself is bracketed by startReturned.
  group('Psiphon F4 + stop-skip — removed with the library '
      '(build 2089)', () {
    final svc = _kt('PsiphonVpnService.kt');

    test('no warm-up probe remains — there is no library '
        'call to warm', () {
      expect(svc.contains('Psi.getBuildInfo()'), isFalse);
      expect(svc.contains('psiphon-warmup'), isFalse);
      expect(svc.contains('warmUpLibrary'), isFalse);
      expect(svc.contains('WARMUP_BOUND_MS'), isFalse);
      expect(svc.contains('psi.Psi'), isFalse);
    });

    test('no cold stop-skip remains — the stop is a '
        'detached library call, not a process kill (build 2091)', () {
      expect(svc.contains('libraryStartedInProcess'), isFalse);
      expect(svc.contains('stop-skipped-cold'), isFalse);
      expect(svc.contains('stopCoreBounded'), isFalse);
      expect(svc.contains('PsiphonBoxCore.stop()'), isFalse);
      expect(svc.contains('private fun stopPsiphonCore()'), isTrue);
      expect(svc.contains('"psiphon-stop"'), isTrue);
    });

    test('startReturned is published with a safe default', () {
      expect(svc, contains('.put("startReturned", startReturned)'));
      expect(svc, contains('"startReturned" to true'));
      expect(svc, contains('json.optBoolean("startReturned", true)'));
    });
  });

  group('Psiphon — the external watchdog (Kotlin)', () {
    final svc = _kt('PsiphonVpnService.kt');
    final ext = _kt('PsiphonExternalWatchdog.kt');
    final main = _kt('MainActivity.kt');

    test('the channel is wired to the executor', () {
      expect(main, contains('"psiphonExternalWatchdog"'));
      expect(main, contains('PsiphonExternalWatchdog.fire(this)'));
      final platform = _dart('psiphon/psiphon_platform.dart');
      expect(platform, contains("'psiphonExternalWatchdog'"));
    });

    test('record first, then the dump, then the kill', () {
      expect(ext, contains('psiphon:external-watchdog'));
      expect(
        ext.indexOf('psiphon:external-watchdog'),
        lessThan(ext.indexOf('Process.killProcess(pid)')),
      );
      expect(
        ext.indexOf('procDump(pid)'),
        lessThan(ext.indexOf('Process.killProcess(pid)')),
      );
      expect(ext, contains('publishExternalWedged(context)'));
    });

    test('the pid hunt and the /proc dump use same-UID sources', () {
      expect(ext, contains('runningAppProcesses'));
      expect(ext, contains('":psiphon"'));
      expect(ext, contains('File("/proc")'));
      expect(ext, contains('"cmdline"'));
      expect(ext, contains('"wchan"'));
      expect(ext, contains('"comm"'));
    });

    test('the failure publish is terminal and preserves the rest',
        () {
      final publish = _region(
        svc,
        'fun publishExternalWedged',
        'fun start(',
      );
      expect(publish, contains('.put("running", false)'));
      expect(publish, contains('.put("connected", false)'));
      expect(publish, contains('.put("wedged", true)'));
      expect(publish, contains('.put("startReturned", true)'));
      expect(publish, contains('AtomicFile.writeText('));
    });
  });

  group('Psiphon — the controller arms and settles the watchdog',
      () {
    final controller = _dart('psiphon/psiphon_controller.dart');

    test('armed at the start, ticked in the waits, settled after',
        () {
      expect(controller, contains('_watchdog.arm(nowForWatchdog())'));
      expect(controller, contains('PsiphonPlatform.externalWatchdog()'));
      expect(controller, contains('_settleWatchdog();'));
      // A user stop disarms: no firing against an attempt the
      // owner ended himself.
      final disconnect = _region(
        controller,
        'Future<void> disconnect()',
        'Future<String> readLogs()',
      );
      expect(disconnect, contains('_watchdog.disarm()'));
    });
  });
}
