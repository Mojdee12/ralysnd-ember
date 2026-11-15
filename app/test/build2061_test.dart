// Build 2061 — feature queue #1: sandbox config test.
// One throwaway core proves delay + hold + exit in a single
// run on a genuinely free port, without touching the live
// tunnel; the result is a verdict sheet on the servers list
// and in the profile editor.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/ui/ember/sandbox_test_sheet.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/sandbox_test.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Profile wsProfile() => Profile(
  id: 'p',
  protocol: Protocol.vless,
  name: 't',
  address: 'node.example.com',
  port: 443,
  uuidOrPassword: '11111111-1111-1111-1111-111111111111',
  security: 'tls',
  network: 'ws',
  host: 'cdn.example.com',
  path: '/ws',
  sni: 'cdn.example.com',
);

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String ktSrc(String rel) => File(
  'android/app/src/main/kotlin/com/ralysnd/ember/$rel',
).readAsStringSync();

void main() {
  group('SandboxTestResult.fromMap', () {
    test('a full map parses, and works needs ok + hold', () {
      final r = SandboxTestResult.fromMap({
        'ok': 1,
        'ms': 212,
        'p0': 210,
        'p1': 238,
        'p2': 251,
        'held': 1,
        'ip': '203.0.113.7',
        'countryCode': 'DE',
        'country': 'Germany',
        'error': '',
      });
      expect(r.ok, isTrue);
      expect(r.delayMs, 212);
      expect(r.held, isTrue);
      expect(r.heldProbes, 3);
      expect(r.exitIp, '203.0.113.7');
      expect(r.countryCode, 'DE');
      expect(r.country, 'Germany');
      expect(r.verdict, SandboxVerdict.works);
      expect(r.title, 'Sandbox test passed');
    });

    test('ok without hold is unstable, not failed', () {
      final r = SandboxTestResult.fromMap({
        'ok': 1,
        'ms': 190,
        'p0': 190,
        'p1': -1,
        'p2': -1,
        'held': 0,
        'ip': '203.0.113.7',
        'countryCode': 'DE',
        'country': 'Germany',
        'error': '',
      });
      expect(r.verdict, SandboxVerdict.unstable);
      expect(r.heldProbes, 1);
      expect(r.title, 'Unstable connection');
      expect(r.detail, contains('did not hold'));
    });

    test('a failed map grades failed and keeps the plain words', () {
      final r = SandboxTestResult.fromMap({
        'ok': 0,
        'ms': -1,
        'p0': -1,
        'p1': -1,
        'p2': -1,
        'held': 0,
        'ip': '',
        'countryCode': '',
        'country': '',
        'error': 'the config did not answer through the tunnel',
      });
      expect(r.verdict, SandboxVerdict.failed);
      expect(r.title, 'Sandbox test failed');
      expect(r.detail, 'the config did not answer through the tunnel');
    });

    test('missing keys and wrong types fall back, never throw', () {
      final r = SandboxTestResult.fromMap({
        'ok': 'yes',
        'ms': 'fast',
        'held': 'maybe',
      });
      expect(r.ok, isFalse);
      expect(r.delayMs, -1);
      expect(r.held, isFalse);
      expect(r.exitIp, '');
      expect(r.error, '');
      expect(r.verdict, SandboxVerdict.failed);
      expect(SandboxTestResult.fromMap({}).verdict, SandboxVerdict.failed);
    });

    test('the failed factory carries the error', () {
      final r = SandboxTestResult.failed('no free port for the sandbox test');
      expect(r.verdict, SandboxVerdict.failed);
      expect(r.detail, 'no free port for the sandbox test');
      expect(r.heldProbes, 0);
    });
  });

  group('sandbox test config shape', () {
    test('SOCKS-only on port 0, no stats API, no TUN', () {
      final cfg = decode(buildTestConfig(wsProfile(), XraySettings()));
      final inbounds = cfg['inbounds'] as List;
      expect(inbounds, hasLength(1));
      final socks = inbounds.first as Map<String, dynamic>;
      expect(socks['protocol'], 'socks');
      expect(socks['listen'], '127.0.0.1');
      expect(socks['port'], 0);
      expect((socks['settings'] as Map)['auth'], 'noauth');
      expect(cfg.containsKey('stats'), isFalse);
      expect(cfg.containsKey('policy'), isFalse);
      expect(cfg.containsKey('api'), isFalse);
    });
  });

  group('Kotlin sandbox test', () {
    test('sandboxTest runs one instance and deletes its temp config', () {
      final src = ktSrc('XrayTester.kt');
      expect(src, contains('fun sandboxTest('));
      // One startInstance call inside sandboxTest: delay, hold
      // and exit all run against the same core.
      final body = src.split('fun sandboxTest(').last.split('\n    /**').first;
      expect('startInstance'.allMatches(body), hasLength(1));
      expect(body, contains('enduranceOnPort(port)'));
      expect(body, contains('exitInfo(port)'));
      expect(body, contains('configFile.delete()'));
    });

    test('the port is bind-probed free before use', () {
      final src = ktSrc('XrayTester.kt');
      expect(src, contains('fun takeFreePort('));
      expect(src, contains('ServerSocket(p).use'));
      for (final fn in ['measureDelay', 'measureDelayEx', 'speedTest']) {
        final body = src.split('fun $fn(').last.split('\n    }').first;
        expect(body, contains('takeFreePort()'), reason: fn);
      }
      final endurance = src.split('fun endurance(').last.split('\n    }').first;
      expect(endurance, contains('takeFreePort()'));
    });

    test('endurance shares its hold check with the sandbox test', () {
      final src = ktSrc('XrayTester.kt');
      expect(src, contains('private fun enduranceOnPort(port: Int)'));
      expect(src, contains('return enduranceOnPort(port)'));
    });

    test('the channel handler exists', () {
      final src = ktSrc('MainActivity.kt');
      expect(src, contains('"xraySandboxTest"'));
      expect(src, contains('XrayTester.sandboxTest(this, config)'));
    });
  });

  group('Dart wiring', () {
    test('the platform call names the sandbox channel', () {
      final src = dartSrc('xray/xray_platform.dart');
      expect(src, contains("'xraySandboxTest'"));
      expect(src, contains('static Future<Map<String, dynamic>> sandboxTest'));
    });

    test('the controller runs the sandbox test and stores the result', () {
      final src = dartSrc('xray/xray_controller.dart');
      expect(src, contains('Future<SandboxTestResult> sandboxTest(Profile p)'));
      expect(src, contains('XrayPlatform.sandboxTest(buildTestConfig(p, settings))'));
      expect(src, contains('p.delayMs = r.delayMs;'));
      expect(src, contains("p.exitIp = r.exitIp;"));
    });

    test('the servers menu offers the sandbox test first', () {
      final src = dartSrc('ui/ember/ember_servers.dart');
      expect(src, contains("value: 'sandbox'"));
      expect(src, contains("child: Text('Sandbox test')"));
      expect(src, contains('case \'sandbox\':'));
      expect(src, contains('xray.sandboxTest(profile)'));
      expect(src, contains('showSandboxTestSheet('));
      // The menu item sits above the plain delay test in the
      // same profile-row menu.
      final sandboxAt = src.indexOf("value: 'sandbox'");
      expect(sandboxAt, greaterThanOrEqualTo(0));
      final delayAfter = src.indexOf("value: 'delay'", sandboxAt);
      expect(delayAfter, greaterThan(sandboxAt));
    });

    test('the editor Test this node runs the sandbox test', () {
      final src = dartSrc('ui/ember/profile_editor.dart');
      expect(src, contains('widget.xray.sandboxTest(_p)'));
      expect(src, contains('showSandboxTestSheet('));
      expect(src, isNot(contains('widget.xray.testDelay(_p)')));
    });
  });

  group('SandboxTestSheet widget', () {
    Future<void> pumpSheet(
      WidgetTester tester,
      SandboxTestResult result, {
      Future<void> Function()? onConnect,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SandboxTestSheet(
              profile: wsProfile(),
              result: result,
              onConnect: onConnect,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a passing test shows verdict, delay, hold and exit', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        SandboxTestResult.fromMap({
          'ok': 1,
          'ms': 212,
          'p0': 210,
          'p1': 238,
          'p2': 251,
          'held': 1,
          'ip': '203.0.113.7',
          'countryCode': 'DE',
          'country': 'Germany',
          'error': '',
        }),
        onConnect: () async {},
      );
      expect(find.text('Sandbox test passed'), findsOneWidget);
      expect(find.text('212 ms'), findsOneWidget);
      expect(find.text('3/3 probes'), findsOneWidget);
      expect(find.text('203.0.113.7'), findsOneWidget);
      expect(find.text('Germany'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
    });

    testWidgets('a failed test shows the error and no Connect', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        SandboxTestResult.failed('the config did not answer through the tunnel'),
        onConnect: () async {},
      );
      expect(find.text('Sandbox test failed'), findsOneWidget);
      expect(
        find.text('the config did not answer through the tunnel'),
        findsOneWidget,
      );
      expect(find.text('Connect'), findsNothing);
      expect(find.text('Close'), findsOneWidget);
    });

    testWidgets('an unstable test keeps Connect', (tester) async {
      await pumpSheet(
        tester,
        SandboxTestResult.fromMap({
          'ok': 1,
          'ms': 190,
          'p0': 190,
          'p1': -1,
          'p2': -1,
          'held': 0,
          'ip': '',
          'countryCode': '',
          'country': '',
          'error': '',
        }),
        onConnect: () async {},
      );
      expect(find.text('Unstable connection'), findsOneWidget);
      expect(find.text('1/3 probes'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);
    });
  });
}
