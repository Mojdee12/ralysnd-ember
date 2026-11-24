/// Build 2091 gates — proxied service reachability checks
/// (feature-watch 2026-11-16, FlClash 0.9.x): one isolated
/// throwaway core asks six key services for a real HTTPS HEAD
/// through the config, without touching the live tunnel, and the
/// sheet grades each service Reachable / No answer.
/// What only the owner's phone can prove — a real service
/// answering through a real node on his network — is NOT
/// claimed here; the host run proves the shape, the parsing
/// and the wiring, and the device proves the behaviour.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/net/service_check.dart';
import 'package:firefox_vpn/ui/ember/service_check_sheet.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String _dart(String path) => File('lib/$path').readAsStringSync();

String _kt(String name) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$name')
        .readAsStringSync();

/// The text of one function in a source file: from [start]
/// up to (not including) the next occurrence of [end].
String _region(String src, String start, String end) {
  final a = src.indexOf(start);
  expect(a, greaterThanOrEqualTo(0), reason: '$start is present');
  final b = src.indexOf(end, a);
  expect(b, greaterThan(a), reason: '$end follows $start');
  return src.substring(a, b);
}

Profile _member(String id, String name, {int delay = 0}) => Profile(
  id: id,
  protocol: Protocol.vless,
  name: name,
  address: '127.0.0.1',
  port: 1,
  uuidOrPassword: '11111111-1111-1111-1111-111111111111',
  subscriptionId: 'sub1',
)..delayMs = delay;

/// A mixed native map: three services answered (200, 301,
/// 403 — every status line is an answer), three never did.
Map<String, dynamic> _mixedMap() => {
  'ok': 1,
  'error': '',
  'results': {
    'www.google.com': {'ms': 120, 'status': 200},
    'www.youtube.com': {'ms': 340, 'status': 301},
    'www.instagram.com': {'ms': 210, 'status': 403},
    'www.telegram.org': {'ms': -1, 'status': 0},
    'github.com': {'ms': -1, 'status': 0},
    'x.com': {'ms': -1, 'status': 0},
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ServiceCheckResult.fromMap (pure parsing + grading)', () {
    test('a mixed map parses: any status line is an answer', () {
      final r = ServiceCheckResult.fromMap(_mixedMap());
      expect(r.ok, isTrue);
      expect(r.error, isEmpty);
      expect(r.entries.length, 6);
      expect(r.entries[0].label, 'Google');
      expect(r.entries[0].reachable, isTrue);
      expect(r.entries[0].ms, 120);
      expect(r.entries[0].status, 200);
      // 301 and 403 are answers too — the service replied
      // through the node, whatever it said.
      expect(r.entries[1].reachable, isTrue);
      expect(r.entries[1].status, 301);
      expect(r.entries[2].reachable, isTrue);
      expect(r.entries[2].status, 403);
      expect(r.entries[3].reachable, isFalse);
      expect(r.entries[3].ms, -1);
      expect(r.entries[3].status, 0);
      expect(r.reachableCount, 3);
      expect(r.allReachable, isFalse);
      expect(r.noneReachable, isFalse);
      expect(
        r.summary,
        '3 of 6 services answered through this node.',
      );
    });

    test('all answered → the all-reachable summary', () {
      final m = _mixedMap();
      final results = m['results'] as Map<String, dynamic>;
      for (final entry in results.values) {
        (entry as Map<String, dynamic>)['ms'] = 100;
        entry['status'] = 200;
      }
      final r = ServiceCheckResult.fromMap(m);
      expect(r.allReachable, isTrue);
      expect(
        r.summary,
        'All 6 services answered through this node.',
      );
    });

    test('none answered → the none-reachable summary', () {
      final m = _mixedMap();
      final results = m['results'] as Map<String, dynamic>;
      for (final entry in results.values) {
        (entry as Map<String, dynamic>)['ms'] = -1;
        entry['status'] = 0;
      }
      final r = ServiceCheckResult.fromMap(m);
      expect(r.noneReachable, isTrue);
      expect(r.summary, contains('No service answered'));
    });

    test('ok=0 keeps the error and fails every service', () {
      final r = ServiceCheckResult.fromMap({
        'ok': 0,
        'error': 'the service-check core did not start',
        'results': <String, dynamic>{},
      });
      expect(r.ok, isFalse);
      expect(r.entries.length, 6);
      expect(r.entries.every((e) => !e.reachable), isTrue);
      expect(r.summary, 'the service-check core did not start');
    });

    test('a missing results map fails every service, never throws', () {
      final r = ServiceCheckResult.fromMap({'ok': 1, 'error': ''});
      expect(r.ok, isTrue);
      expect(r.noneReachable, isTrue);
      expect(r.entries.length, 6);
    });

    test('a missing per-host entry fails only that service', () {
      final m = _mixedMap();
      (m['results'] as Map).remove('github.com');
      final r = ServiceCheckResult.fromMap(m);
      expect(r.entries[4].reachable, isFalse);
      expect(r.reachableCount, 3);
    });

    test('wrong-typed values degrade to no answer, never throw', () {
      final r = ServiceCheckResult.fromMap({
        'ok': 1,
        'error': '',
        'results': {
          'www.google.com': {'ms': 'fast', 'status': '200'},
          'www.youtube.com': {'ms': 340, 'status': 301},
          'www.instagram.com': 'not-a-map',
          'www.telegram.org': {'ms': -1, 'status': 0},
          'github.com': {'ms': -1, 'status': 0},
          'x.com': {'ms': -1, 'status': 0},
        },
      });
      // A status that arrives as a string is not an answer:
      // the native side sends numbers, so a string means a
      // broken map, and a broken map must never invent a
      // reachable verdict.
      expect(r.entries[0].reachable, isFalse);
      expect(r.entries[1].reachable, isTrue);
      expect(r.entries[2].reachable, isFalse);
      expect(r.reachableCount, 1);
    });

    test('a status without a real ms is not an answer', () {
      final r = ServiceCheckResult.fromMap({
        'ok': 1,
        'error': '',
        'results': {
          'www.google.com': {'ms': -1, 'status': 200},
          'www.youtube.com': {'ms': 120, 'status': 0},
          'www.instagram.com': {'ms': -1, 'status': 0},
          'www.telegram.org': {'ms': -1, 'status': 0},
          'github.com': {'ms': -1, 'status': 0},
          'x.com': {'ms': -1, 'status': 0},
        },
      });
      expect(r.noneReachable, isTrue);
      expect(r.entries[0].status, 0);
      expect(r.entries[0].ms, -1);
    });

    test('the failed factory names the stage and fails all six', () {
      final r = ServiceCheckResult.failed('no free port');
      expect(r.ok, isFalse);
      expect(r.error, 'no free port');
      expect(r.entries.length, 6);
      expect(r.noneReachable, isTrue);
      expect(r.summary, 'no free port');
    });
  });

  group('the service set (fixed, six, no duplicates)', () {
    test('six targets, unique hosts and labels, in sheet order', () {
      expect(serviceCheckTargets.length, 6);
      final hosts = serviceCheckTargets.map((t) => t.host).toList();
      expect(hosts.toSet().length, 6);
      final labels = serviceCheckTargets.map((t) => t.label).toList();
      expect(labels.toSet().length, 6);
      expect(labels, [
        'Google',
        'YouTube',
        'Instagram',
        'Telegram',
        'GitHub',
        'X',
      ]);
    });

    test('every host is a bare domain — no scheme, port or path', () {
      final domain = RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$');
      for (final t in serviceCheckTargets) {
        expect(t.host, matches(domain), reason: t.host);
        expect(t.host, isNot(contains('://')));
        expect(t.host, isNot(contains(':')));
        expect(t.host, isNot(contains('/')));
      }
      // The delay-test host is the control, not a question:
      // it must not appear here as a seventh service.
      expect(
        serviceCheckTargets.map((t) => t.host),
        isNot(contains('connectivitycheck.gstatic.com')),
      );
    });
  });

  group('XrayController.serviceCheck (channel seam)', () {
    Future<void> mockChannel(
      Future<Map<String, dynamic>> Function(Map<String, dynamic> args) onCall,
    ) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            (call) async {
              if (call.method == 'xrayServiceCheck') {
                return onCall(
                  Map<String, dynamic>.from(call.arguments as Map),
                );
              }
              return null;
            },
          );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('app/android'),
              null,
            );
      });
    }

    test('a mocked native map returns parsed, and stores nothing', () async {
      Map<String, dynamic>? seen;
      await mockChannel((args) async {
        seen = args;
        return _mixedMap();
      });
      final c = XrayController();
      final p = _member('p', 'Node', delay: 42);
      final r = await c.serviceCheck(p);
      expect(r.ok, isTrue);
      expect(r.reachableCount, 3);
      expect(r.entries[0].label, 'Google');
      // The six hosts ride the channel in target order, with
      // a real config string beside them.
      expect(
        seen?['hosts'],
        serviceCheckTargets.map((t) => t.host).toList(),
      );
      expect(seen?['config'], isA<String>());
      expect((seen?['config'] as String).isNotEmpty, isTrue);
      // Reachability is a property of the run, not of the
      // config: the profile is untouched by the check.
      expect(p.delayMs, 42);
      expect(c.isTesting(p.id), isFalse);
    });

    test('a channel throw becomes a failed result with words', () async {
      await mockChannel((_) async {
        throw PlatformException(code: 'boom');
      });
      final c = XrayController();
      final r = await c.serviceCheck(_member('p', 'Node'));
      expect(r.ok, isFalse);
      expect(r.noneReachable, isTrue);
      expect(r.summary, contains('did not answer'));
    });

    test('isTesting is true while the native call is in flight', () async {
      final gate = Completer<Map<String, dynamic>>();
      await mockChannel((_) => gate.future);
      final c = XrayController();
      final p = _member('p', 'Node');
      final fut = c.serviceCheck(p);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.isTesting(p.id), isTrue);
      gate.complete(_mixedMap());
      final r = await fut;
      expect(r.ok, isTrue);
      expect(c.isTesting(p.id), isFalse);
    });
  });

  group('the controller shape (source pins)', () {
    test('serviceCheck rides _testConfigFor and stores nothing', () {
      final ctl = _dart('xray/xray_controller.dart');
      final fn = _region(
        ctl,
        'Future<ServiceCheckResult> serviceCheck(Profile p)',
        'Future<int> testSpeed(Profile p)',
      );
      expect(fn, contains('_testConfigFor(p)'));
      expect(fn, contains('XrayPlatform.serviceCheck('));
      expect(fn, contains('serviceCheckTargets.map((t) => t.host)'));
      // The sandbox test stores delay/exit on the profile;
      // this check must not — a stale verdict must never
      // outlive its run.
      expect(fn, isNot(contains('p.delayMs')));
      expect(fn, isNot(contains('await _save()')));
      // The unserved-protocol refusal, same words as the
      // sandbox test (no parsed protocol is unserved today;
      // the branch is the defence, pinned, not deleted).
      expect(
        fn,
        contains('no engine in the app serves this protocol yet'),
      );
    });

    test('the platform method carries config + hosts', () {
      final plat = _dart('xray/xray_platform.dart');
      final fn = _region(
        plat,
        'static Future<Map<String, dynamic>> serviceCheck(',
        '/// The running core',
      );
      expect(fn, contains("'xrayServiceCheck'"));
      expect(fn, contains("'hosts': hosts"));
      expect(fn, contains('the service check did not answer'));
    });
  });

  group('the native side (Kotlin source pins)', () {
    test('serviceCheck runs one throwaway core, then kills it', () {
      final tester = _kt('XrayTester.kt');
      final fn = _region(
        tester,
        'fun serviceCheck(',
        'private fun probeService(',
      );
      expect(fn, contains('takeFreePort()'));
      expect(fn, contains('startInstance(context, config, port)'));
      expect(fn, contains('kill(proc)'));
      expect(fn, contains('configFile.delete()'));
      // Test cores are noauth: any LAN-sharing credentials
      // left by a live-tunnel probe are cleared first.
      expect(fn, contains('setSocksAuth("", "", port)'));
    });

    test('the probes run four at a time with a bounded join', () {
      final tester = _kt('XrayTester.kt');
      final fn = _region(
        tester,
        'fun serviceCheck(',
        'private fun probeService(',
      );
      expect(fn, contains('newFixedThreadPool(4)'));
      expect(fn, contains('future.get(20,'));
      expect(fn, contains('pool.shutdownNow()'));
    });

    test('each probe is one HTTPS HEAD through the SOCKS', () {
      final tester = _kt('XrayTester.kt');
      final fn = _region(
        tester,
        'private fun probeService(',
        '/** Reads exactly',
      );
      expect(fn, contains('openViaSocks(URL("https://\$host/")'));
      expect(fn, contains('requestMethod = "HEAD"'));
      expect(fn, contains('instanceFollowRedirects = false'));
      expect(fn, contains('connectTimeout = 6000'));
      expect(fn, contains('readTimeout = 6000'));
      expect(fn, contains('conn.responseCode'));
      // A failed probe degrades to -1/0, never throws out of
      // the pool thread.
      expect(fn, contains('mapOf("ms" to -1L, "status" to 0)'));
    });

    test('MainActivity forwards config + hosts to the tester', () {
      final main = _kt('MainActivity.kt');
      final dispatch = _region(
        main,
        '"xrayServiceCheck" -> {',
        '"xrayExitInfo" -> {',
      );
      expect(
        dispatch,
        contains('call.argument<List<Any>>("hosts")'),
      );
      expect(
        dispatch,
        contains('XrayTester.serviceCheck(this, config, hosts)'),
      );
    });
  });

  group('the UI surface (source pins + widget)', () {
    test('the row menu offers Check services beside Sandbox test', () {
      final servers = _dart('ui/ember/ember_servers.dart');
      expect(servers, contains("value: 'services'"));
      expect(servers, contains("child: Text('Check services')"));
      final act = _region(
        servers,
        "case 'services':",
        "case 'delay':",
      );
      expect(act, contains('xray.serviceCheck(profile)'));
      expect(act, contains('showServiceCheckSheet('));
      expect(act, contains('_connectFromTest(context)'));
    });

    Future<void> pumpSheet(
      WidgetTester tester,
      ServiceCheckResult result, {
      Future<void> Function()? onConnect,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ServiceCheckSheet(
              profile: _member('p', 'Node'),
              result: result,
              onConnect: onConnect,
            ),
          ),
        ),
      );
    }

    testWidgets('a mixed run shows all six services + the count', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        ServiceCheckResult.fromMap(_mixedMap()),
        onConnect: () async {},
      );
      expect(find.text('Services through this node'), findsOneWidget);
      for (final label in [
        'Google',
        'YouTube',
        'Instagram',
        'Telegram',
        'GitHub',
        'X',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Reachable'), findsNWidgets(3));
      expect(find.text('No answer'), findsNWidgets(3));
      expect(find.text('120 ms · 200'), findsOneWidget);
      expect(
        find.text('3 of 6 services answered through this node.'),
        findsOneWidget,
      );
      expect(find.text('Connect'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
    });

    testWidgets('a failed run shows the error and no Connect', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        ServiceCheckResult.failed('the service-check core did not start'),
      );
      expect(find.text('No answer'), findsNWidgets(6));
      expect(
        find.text('the service-check core did not start'),
        findsOneWidget,
      );
      expect(find.text('Connect'), findsNothing);
      expect(find.text('Close'), findsOneWidget);
    });
  });
}
