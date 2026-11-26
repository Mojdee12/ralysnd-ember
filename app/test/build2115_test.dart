/// Build 2115 — the WARP/Aether exit-verification fix (the
/// owner's «بد بیلد اصلی اینم اصلاح بشه», after the 2114 main
/// build). The diagnosis (warp-masque-diagnosis.md): the
/// Aether engine validated its tunnel end-to-end and its own
/// exit check confirmed a WARP exit, while the app's trace
/// fetch — HttpURLConnection over a java.net SOCKS proxy,
/// every exception swallowed to null — never landed, and the
/// connect tore the healthy engine down as "the exit could
/// not be verified through the tunnel".
///
/// Behavioral tests over the mocked 'app/android' channel
/// (the build-2095 batch-6 harness pattern):
///  - the data proof runs BEFORE the trace now, and the TUN
///    rises only after both;
///  - a trace that never lands no longer tears the engine
///    down: the session connects with its exit unverified;
///  - an answered warp=off is still fatal (build 2080's
///    gate — the exit is PROVEN not to be WARP);
///  - a failed data proof still tears the engine down, and
///    the trace never runs behind it;
///  - a trace that lands later (Refresh) closes the
///    unverified question.
/// Plus source pins for the native side: the raw-socket
/// transport replaced the java.net SOCKS fetch, and a trace
/// failure is recorded (state's traceError), never swallowed.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/aether/aether_controller.dart';
import 'package:firefox_vpn/aether/aether_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <String>[];
  var engineRunning = false;
  var tunOn = false;
  Future<Map<String, String>?> Function() traceBehavior =
      () async => <String, String>{
        'warp': 'on',
        'ip': '104.28.214.161',
        'loc': 'DE',
      };
  Future<Map<String, dynamic>?> Function() probeBehavior =
      () async => <String, dynamic>{'ok': true, 'detail': 'ok'};

  void installHandler() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), (
          call,
        ) async {
          calls.add(call.method);
          switch (call.method) {
            case 'aetherState':
              return <String, Object?>{
                'engine': 'cfwarp',
                'running': engineRunning,
                'stage': engineRunning ? 'connected' : 'idle',
                'connected': engineRunning,
                'identity': true,
                'error': '',
                'traceError': '',
              };
            case 'xrayState':
              return <String, Object?>{
                'running': tunOn,
                'name': tunOn ? 'WARP' : '',
                'sinceMs': 1000,
                'up': 0,
                'down': 0,
              };
            case 'aetherStart':
              engineRunning = true;
              return true;
            case 'aetherStop':
              engineRunning = false;
              return null;
            case 'aetherTrace':
              return traceBehavior();
            case 'aetherDataProbe':
              return probeBehavior();
            case 'socksTunSetOn':
              tunOn = (call.arguments as Map)['on'] == true;
              return null;
          }
          return null;
        });
  }

  setUp(() {
    calls.clear();
    engineRunning = false;
    tunOn = false;
    traceBehavior = () async => <String, String>{
      'warp': 'on',
      'ip': '104.28.214.161',
      'loc': 'DE',
    };
    probeBehavior =
        () async => <String, dynamic>{'ok': true, 'detail': 'ok'};
    installHandler();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), null);
  });

  AetherController warpController() {
    final c = AetherController('cfwarp');
    c.options = const AetherOptions(protocol: 'wg');
    addTearDown(() async {
      try {
        await c.disconnect();
      } catch (_) {}
      c.dispose();
    });
    return c;
  }

  group('2115 — proof order and verdicts (cfwarp connect)', () {
    test(
      'data proof runs before the trace; a landed warp=on verifies',
      () async {
        var traceCalls = 0;
        traceBehavior = () async {
          traceCalls++;
          if (traceCalls == 1) return null;
          return <String, String>{
            'warp': 'on',
            'ip': '104.28.214.161',
            'loc': 'DE',
          };
        };
        final c = warpController();
        await c.connect().timeout(const Duration(seconds: 30));

        final probeAt = calls.indexOf('aetherDataProbe');
        final traceAt = calls.indexOf('aetherTrace');
        final tunAt = calls.indexOf('socksTunSetOn');
        expect(probeAt, greaterThanOrEqualTo(0));
        expect(traceAt, greaterThan(probeAt),
            reason: 'the data proof is the first proof now');
        expect(tunAt, greaterThan(traceAt),
            reason: 'the TUN rises only after both proofs');
        expect(c.connected, isTrue);
        expect(c.exitUnverified, isFalse);
        expect(c.exitTrace?['ip'], '104.28.214.161');
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'a trace that never lands connects with the exit unverified',
      () async {
        traceBehavior = () async => null;
        final c = warpController();
        c.warpProofBudget = const Duration(milliseconds: 700);
        await c.connect().timeout(const Duration(seconds: 30));

        expect(c.connected, isTrue);
        expect(c.exitUnverified, isTrue);
        expect(c.exitTrace, isNull);
        expect(
          calls.where((m) => m == 'aetherStop'),
          isEmpty,
          reason: 'a proven engine is not torn down over an '
              'unanswered check',
        );
        expect(c.lastError, isNull);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'an answered warp=off is still fatal and tears down',
      () async {
        traceBehavior = () async =>
            <String, String>{'warp': 'off', 'ip': '203.0.113.1'};
        final c = warpController();
        c.warpProofBudget = const Duration(milliseconds: 700);

        Object? error;
        try {
          await c.connect().timeout(const Duration(seconds: 30));
        } catch (e) {
          error = e;
        }
        expect(error, isA<StateError>());
        expect(
          (error as StateError).message,
          contains('not through WARP (warp=off)'),
        );
        expect(c.exitUnverified, isFalse);
        expect(tunOn, isFalse);
        expect(calls.where((m) => m == 'aetherStop'), isNotEmpty);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'a failed data proof tears down and the trace never runs',
      () async {
        probeBehavior = () async =>
            <String, dynamic>{'ok': false, 'detail': 'http204=no'};
        final c = warpController();
        c.dataProofBudget = const Duration(milliseconds: 700);

        Object? error;
        try {
          await c.connect().timeout(const Duration(seconds: 30));
        } catch (e) {
          error = e;
        }
        expect(error, isA<StateError>());
        expect(
          (error as StateError).message,
          contains('real data did not pass'),
        );
        expect(
          calls.where((m) => m == 'aetherTrace'),
          isEmpty,
          reason: 'the trace gate no longer stands in front '
              'of the data proof',
        );
        expect(calls.where((m) => m == 'aetherStop'), isNotEmpty);
        expect(tunOn, isFalse);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'a later landed trace (Refresh) closes the unverified question',
      () async {
        var landed = false;
        traceBehavior = () async => landed
            ? <String, String>{
                'warp': 'on',
                'ip': '104.28.214.163',
                'loc': 'DE',
              }
            : null;
        final c = warpController();
        c.warpProofBudget = const Duration(milliseconds: 700);
        await c.connect().timeout(const Duration(seconds: 30));
        expect(c.exitUnverified, isTrue);

        landed = true;
        await c.refreshTrace();
        expect(c.exitUnverified, isFalse);
        expect(c.exitTrace?['ip'], '104.28.214.163');
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  group('2115 — native verification transport (pins)', () {
    String kt() => File(
      'android/app/src/main/kotlin/com/ralysnd/ember/AetherCore.kt',
    ).readAsStringSync();

    test('the java.net SOCKS fetch is gone; the raw transport exists', () {
      final src = kt();
      expect(src.contains('Proxy.Type.SOCKS'), isFalse);
      expect(src.contains('openConnection'), isFalse);
      expect(src.contains('socksSocket'), isTrue);
      expect(src.contains('SSLSocketFactory'), isTrue);
    });

    test('a trace failure is recorded and surfaced, never swallowed', () {
      final src = kt();
      expect(src.contains('recordTraceError'), isTrue);
      expect(src.contains('"traceError"'), isTrue);
      expect(src.contains('lastTraceError'), isTrue);
    });

    test('the data probe rides the same raw transport', () {
      final src = kt();
      expect(src.contains('probeConnection'), isFalse);
      expect(src.contains('probeRequest'), isTrue);
    });

    test('pubspec is 2.2.0+2119', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('version: 2.2.0+2151'));
    });
  });
}
