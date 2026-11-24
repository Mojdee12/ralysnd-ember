// Build 2109 — the adjustable delay-test timeout (feature-watch
// 2026-11-12, FlClash 0.9.2). Pins:
//  - the setting: `delayTestTimeoutSec` defaults to 8 — the fixed
//    8 s per request the native side used in every build ≤2108 —
//    persists through JSON (which is also the backup path), and a
//    pre-2109 store reads 8; a corrupt stored value clamps to the
//    offered 3..20 s range and can never break a test;
//  - the bulk budget: at the default 8 s timeout the Test All bulk
//    pass keeps its historic 10000 ms overall budget exactly, and
//    a longer timeout raises the budget so the setting is actually
//    honored in bulk mode instead of being silently capped at 10 s;
//  - the Dart→native contract: `measureDelayEx` and `sandboxTest`
//    carry the configured `timeoutMs` to the native side, and a
//    simulated slow endpoint aborts under a short timeout and
//    completes under a long one — these fail if the setting were
//    ignored at any layer the Dart side controls;
//  - the widget: the V2Ray section shows the "Delay test timeout"
//    chip row after "Test All parallelism", and tapping a chip
//    sets the setting and persists it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/lantern/lantern_controller.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/ui/ember/ember_settings.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

/// Pumps EmberSettings in V2Ray mode (1) with a fresh controller.
/// (Same harness as build2108's widget tests.)
Future<XrayController> pumpSettings(WidgetTester tester) async {
  final core = CoreController(
    () async => throw const CoreUnavailable(CoreProblem.refused, 'test'),
  );
  addTearDown(core.dispose);
  final xray = XrayController();
  addTearDown(xray.dispose);
  final psiphon = PsiphonController();
  addTearDown(psiphon.dispose);
  final lantern = LanternController();
  addTearDown(lantern.dispose);
  final openvpn = OpenVpnController();
  addTearDown(openvpn.dispose);
  final settings = AppSettings()..emberMode = 1;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: EmberSettings(
          core: core,
          xray: xray,
          psiphon: psiphon,
          lantern: lantern,
          openvpn: openvpn,
          settings: settings,
        ),
      ),
    ),
  );
  await tester.pump();
  return xray;
}

void main() {
  group('the setting — delayTestTimeoutSec', () {
    test('defaults to 8 s: the fixed value of every build ≤2108', () {
      expect(XraySettings().delayTestTimeoutSec, 8);
      expect(XraySettings().delayTestTimeoutMs, 8000);
    });

    test('persists through JSON', () {
      final s = XraySettings()..delayTestTimeoutSec = 15;
      final restored = XraySettings.fromJson(s.toJson());
      expect(restored.delayTestTimeoutSec, 15);
      expect(restored.delayTestTimeoutMs, 15000);
      // The key rides settings.toJson(), which is what the
      // store doc and the backup export carry.
      expect(s.toJson(), containsPair('delayTestTimeoutSec', 15));
    });

    test('a pre-2109 settings document reads 8 s', () {
      final doc = XraySettings().toJson()..remove('delayTestTimeoutSec');
      expect(XraySettings.fromJson(doc).delayTestTimeoutSec, 8);
    });

    test('a corrupt stored value clamps instead of breaking a test', () {
      // Below the offered range clamps up to the 3 s floor.
      var doc = XraySettings().toJson()..['delayTestTimeoutSec'] = 0;
      expect(XraySettings.fromJson(doc).delayTestTimeoutSec, 3);
      // Above the offered range clamps down to the 20 s ceiling.
      doc = XraySettings().toJson()..['delayTestTimeoutSec'] = 99;
      expect(XraySettings.fromJson(doc).delayTestTimeoutSec, 20);
      // A non-numeric value falls back to the 8 s default.
      doc = XraySettings().toJson()..['delayTestTimeoutSec'] = 'yes';
      expect(XraySettings.fromJson(doc).delayTestTimeoutSec, 8);
      // A numeric string (synced/restored document) parses.
      doc = XraySettings().toJson()..['delayTestTimeoutSec'] = '15';
      expect(XraySettings.fromJson(doc).delayTestTimeoutSec, 15);
    });

    test('clampDelayTestTimeoutSec pins the offered range', () {
      expect(XraySettings.clampDelayTestTimeoutSec(2), 3);
      expect(XraySettings.clampDelayTestTimeoutSec(3), 3);
      expect(XraySettings.clampDelayTestTimeoutSec(8), 8);
      expect(XraySettings.clampDelayTestTimeoutSec(20), 20);
      expect(XraySettings.clampDelayTestTimeoutSec(21), 20);
    });
  });

  group('the bulk budget — delayTestBulkBudgetMs', () {
    test('at the default timeout the bulk budget is exactly 10000 ms', () {
      final xray = XrayController();
      addTearDown(xray.dispose);
      expect(xray.delayTestBulkBudgetMs(8000), 10000);
      expect(xray.delayTestBulkBudgetMs(3000), 10000);
    });

    test('a longer timeout raises the budget so it is actually honored', () {
      final xray = XrayController();
      addTearDown(xray.dispose);
      expect(xray.delayTestBulkBudgetMs(15000), 15000);
      expect(xray.delayTestBulkBudgetMs(20000), 20000);
    });
  });

  group('the Dart→native contract — timeoutMs is carried', () {
    // A slow endpoint: answers only when the request is given
    // at least 5 s. The mock native side reads the timeout the
    // Dart side actually sent, so a build that ignored the
    // setting would send the fixed 8000 and could never show
    // the short-timeout abort below.
    var seenMeasureArgs = <String, dynamic>{};
    var seenSandboxArgs = <String, dynamic>{};
    late Future<dynamic> Function(MethodCall) handler;

    setUp(() {
      seenMeasureArgs = {};
      seenSandboxArgs = {};
      handler = (MethodCall call) async {
        final args =
            (call.arguments as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{};
        if (call.method == 'xrayMeasureDelayEx') {
          seenMeasureArgs = args;
          final timeoutMs = args['timeoutMs'] as int? ?? -1;
          if (timeoutMs < 5000) {
            return {'ms': -1, 'ip': '', 'countryCode': ''};
          }
          return {'ms': 120, 'ip': '1.2.3.4', 'countryCode': 'NL'};
        }
        if (call.method == 'xraySandboxTest') {
          seenSandboxArgs = args;
          return {
            'ok': 1,
            'ms': 120,
            'p0': 120,
            'p1': 130,
            'p2': 125,
            'held': 1,
            'ip': '1.2.3.4',
            'countryCode': 'NL',
            'country': 'Netherlands',
            'error': '',
          };
        }
        return null;
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            handler,
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            null,
          );
    });

    test('a short timeout aborts a slow test', () async {
      final r = await XrayPlatform.measureDelayEx('{}', timeoutMs: 3000);
      expect(seenMeasureArgs['timeoutMs'], 3000);
      expect(r['ms'], -1);
    });

    test('a long timeout lets the same slow test complete', () async {
      final r = await XrayPlatform.measureDelayEx('{}', timeoutMs: 15000);
      expect(seenMeasureArgs['timeoutMs'], 15000);
      expect(r['ms'], 120);
      expect(r['ip'], '1.2.3.4');
    });

    test('no timeout passed keeps the fixed 8000 ms of ≤2108', () async {
      final r = await XrayPlatform.measureDelayEx('{}');
      expect(seenMeasureArgs['timeoutMs'], 8000);
      expect(r['ms'], 120);
    });

    test('sandboxTest carries the configured timeout', () async {
      await XrayPlatform.sandboxTest('{}', timeoutMs: 20000);
      expect(seenSandboxArgs['timeoutMs'], 20000);
      await XrayPlatform.sandboxTest('{}');
      expect(seenSandboxArgs['timeoutMs'], 8000);
    });
  });

  group('the widget — the Delay test timeout row', () {
    testWidgets('row renders with its honest subtitle', (tester) async {
      final xray = await pumpSettings(tester);
      expect(xray.settings.delayTestTimeoutSec, 8);
      await tester.ensureVisible(find.text('Delay test timeout'));
      await tester.pump();
      expect(find.text('Delay test timeout'), findsOneWidget);
      expect(
        find.text('How long each test request waits for an answer'),
        findsOneWidget,
      );
      // The row sits directly after Test All parallelism, in the
      // same delay-test family of the V2Ray section.
      expect(find.text('Test All parallelism'), findsOneWidget);
      // Every offered choice is on the row. '3s' and '15s' occur
      // nowhere else on the page; '5s'/'8s'/'10s'/'20s' also
      // appear on the Reconnect delay row, so those are only
      // asserted present.
      expect(find.text('3s'), findsOneWidget);
      expect(find.text('15s'), findsOneWidget);
      for (final label in const ['5s', '8s', '10s', '20s']) {
        expect(find.text(label), findsWidgets);
      }
    });

    testWidgets('tapping a chip sets the setting and persists', (
      tester,
    ) async {
      final xray = await pumpSettings(tester);
      await tester.ensureVisible(find.text('15s'));
      await tester.pump();
      await tester.tap(find.text('15s'));
      await tester.pump();
      expect(xray.settings.delayTestTimeoutSec, 15);
      expect(
        XraySettings.fromJson(xray.settings.toJson()).delayTestTimeoutSec,
        15,
      );
      await tester.tap(find.text('8s'));
      await tester.pump();
      expect(xray.settings.delayTestTimeoutSec, 8);
    });

    test('the row is present in source after Test All parallelism', () {
      // A source pin against silent removal: the widget test
      // above proves the row renders; this pins the placement.
      final src = File(
        'lib/ui/ember/ember_settings.dart',
      ).readAsStringSync();
      final parallelismAt = src.indexOf("label: 'Test All parallelism'");
      final timeoutAt = src.indexOf("label: 'Delay test timeout'");
      expect(parallelismAt, isNonNegative);
      expect(timeoutAt, greaterThan(parallelismAt));
    });
  });
}
