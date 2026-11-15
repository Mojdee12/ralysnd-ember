/// Build 2057 gates, host side — audit Batch 13 remainders
/// (F-M3, F-M21) + the F-M15 editor-save gate.
///
/// Items 1–8 of the Batch 13 brief (F-M10, F-M11, F-M12, F-M13,
/// F-M15 pure-function gates, F-M2, the §6 codec drops, WG
/// .conf honesty) are implemented and gated in
/// test/build2057_test.dart (37 tests, green); this file covers
/// only what that file does not:
///
/// - F-M3: the stall watchdog stands down while a handover
///   countdown is pending (zero rotateConfig calls), and every
///   fallback-group member a retry tries counts against the
///   auto-reconnect episode budget.
/// - F-M21: refresh carry spends one old profile per new
///   profile — two old profiles sharing one identity link keep
///   their own totals/star/label/pin.
/// - F-M15 (editor half): the editor refuses to save a TLS
///   profile whose fingerprint is a pin-shaped hex string
///   (widget test; the pure-function gate lives in
///   build2057_test.dart).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/ui/ember/profile_editor.dart';
import 'package:firefox_vpn/xray/sub_fetcher.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

const _pin64 =
    'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';

Profile _vless({String id = 'w1'}) => Profile(
  id: id,
  protocol: Protocol.vless,
  name: 'Node',
  address: 'node.example.com',
  port: 443,
  uuidOrPassword: '11111111-1111-1111-1111-111111111111',
  security: 'tls',
  sni: 'node.example.com',
);

/// Finds an editor field by its visible label (the editor's
/// labels are wrapping Text widgets in the decoration's `label`
/// slot — see build2053_test.dart).
Finder _field(String label) => find.byWidgetPredicate(
  (w) =>
      w is TextField &&
      w.decoration?.label is Text &&
      (w.decoration!.label as Text).data == label,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('F-M3 handover vs the stall watchdog', () {
    final rotateCalls = <String>[];
    late XrayController c;

    setUp(() {
      rotateCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            (call) async {
              if (call.method == 'xrayRotateConfig') {
                rotateCalls.add(call.method);
                return false;
              }
              if (call.method == 'xrayTunnelCheck') return -1;
              return null;
            },
          );
      c = XrayController();
      c.profiles = [_vless()];
      c.select(c.profiles.single);
    });

    tearDown(() {
      c.testEndHandoverCountdown();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            null,
          );
    });

    XrayState sample({required int up, required int down, int ageMs = 20000}) {
      final now = DateTime.now().millisecondsSinceEpoch;
      return XrayState(
        running: true,
        name: 'Node',
        sinceMs: now - ageMs,
        upBytes: up,
        downBytes: down,
      );
    }

    /// Drives the freeze signature to escalation: seed the
    /// bases, wait out the 6 s stall window, then feed two
    /// stalled samples (two failed probes escalate).
    Future<void> driveStall() async {
      await c.testWatchdogTick(sample(up: 1000, down: 5000));
      await Future<void>.delayed(const Duration(seconds: 7));
      await c.testWatchdogTick(sample(up: 2000, down: 5000));
      await c.testWatchdogTick(sample(up: 3000, down: 5000));
    }

    test('a stalled tunnel without a handover escalates (control arm)',
        () async {
      await driveStall();
      expect(
        rotateCalls,
        hasLength(1),
        reason: 'the control arm must prove the stall WOULD rotate',
      );
    });

    test('handover pending + stall sample => zero rotateConfig calls',
        () async {
      c.testBeginHandoverCountdown();
      expect(c.testHasPendingRetry, isTrue);
      await driveStall();
      expect(rotateCalls, isEmpty);
    });
  });

  group('F-M3 group members count against the episode budget', () {
    test('a retry that walked three group members charges four attempts',
        () {
      final c = XrayController();
      c.settings.reconnectMaxAttempts = 5;
      // Retry 1 tries the profile + 3 group members: 1 + 3
      // charged, not 1 — the UI's "attempt 1 of 5" counted
      // only the first try.
      c.testNoteFailedRetry(triesConsumed: 4);
      expect(c.testReconnectAttempts, 4);
      expect(c.testHasPendingRetry, isTrue);
      c.testEndHandoverCountdown();
      // Retry 2 spends the budget: 4 + 1 + 3 = 8 >= 5, so the
      // episode gives up instead of running a third retry.
      c.testNoteFailedRetry(triesConsumed: 4);
      expect(c.testReconnectAttempts, 0);
      expect(c.testHasPendingRetry, isFalse);
      expect(c.reconnectNotice, contains('gave up'));
    });

    test('a retry with no group walk charges exactly one attempt', () {
      final c = XrayController();
      c.settings.reconnectMaxAttempts = 5;
      c.testNoteFailedRetry(triesConsumed: 1);
      expect(c.testReconnectAttempts, 1);
      expect(c.testHasPendingRetry, isTrue);
      c.testEndHandoverCountdown();
    });

    test('five single-try retries spend a budget of five', () {
      final c = XrayController();
      c.settings.reconnectMaxAttempts = 5;
      for (var i = 0; i < 4; i++) {
        c.testNoteFailedRetry(triesConsumed: 1);
        expect(c.testHasPendingRetry, isTrue);
        c.testEndHandoverCountdown();
      }
      expect(c.testReconnectAttempts, 4);
      c.testNoteFailedRetry(triesConsumed: 1);
      expect(c.testReconnectAttempts, 0);
      expect(c.testHasPendingRetry, isFalse);
      expect(c.reconnectNotice, contains('gave up'));
    });
  });

  group('F-M21 duplicate-carry fix', () {
    test('two old profiles sharing one identity link keep their own carry',
        () async {
      final c = XrayController();
      var fresh = 0;
      Profile freshProfile() {
        fresh++;
        return Profile(
          id: 'fresh-$fresh',
          protocol: Protocol.vless,
          name: 'Node',
          address: 'node.example.com',
          port: 443,
          uuidOrPassword: '11111111-1111-1111-1111-111111111111',
          security: 'tls',
        );
      }

      // Both fetches return the same server twice — the
      // duplicate a subscription really serves.
      c.subscriptionFetcher = (
        url, {
        certPin = '',
        hwid = '',
        headers = const {},
        fallbackUrl = '',
        hosts = const {},
      }) async {
        return SubResult(profiles: [freshProfile(), freshProfile()]);
      };
      final sub = await c.addSubscription('https://panel.example/sub/abc');
      expect(c.profiles, hasLength(2));

      // The two old profiles share one identity link but carry
      // different user data.
      final old1 = c.profiles[0];
      final old2 = c.profiles[1];
      old1
        ..totalDownBytes = 1000
        ..totalUpBytes = 10
        ..starred = true
        ..localName = 'Alpha'
        ..tlsCertPin = _pin64
        ..delayMs = 42;
      old2
        ..totalDownBytes = 2000
        ..totalUpBytes = 20
        ..starred = false
        ..localName = 'Beta'
        ..delayMs = 77;

      await c.updateSubscription(sub);
      expect(c.profiles, hasLength(2));
      final n1 = c.profiles.firstWhere((p) => p.id == old1.id);
      final n2 = c.profiles.firstWhere((p) => p.id == old2.id);
      expect(n1.totalDownBytes, 1000);
      expect(n1.totalUpBytes, 10);
      expect(n1.starred, isTrue);
      expect(n1.localName, 'Alpha');
      expect(n1.tlsCertPin, _pin64);
      expect(n1.delayMs, 42);
      // Before the fix the second duplicate re-carried the
      // FIRST old profile's totals/star/label/pin.
      expect(n2.totalDownBytes, 2000);
      expect(n2.totalUpBytes, 20);
      expect(n2.starred, isFalse);
      expect(n2.localName, 'Beta');
      expect(n2.tlsCertPin, isEmpty);
      expect(n2.delayMs, 77);
    });
  });

  group('F-M15 editor save refusal', () {
    testWidgets('a pin-shaped fingerprint on a TLS profile is refused',
        (tester) async {
      final xray = XrayController();
      final existing = _vless(id: 'f15')..fingerprint = _pin64;
      xray.profiles.add(existing);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ProfileEditorPage(xray: xray, existing: existing),
        ),
      );
      await tester.pumpAndSettle();
      // The body is a lazily-built ListView: the Security
      // section is not in the tree until it is scrolled into
      // view. Drag the list itself (scrollUntilVisible cannot
      // disambiguate the page's several vertical Scrollables —
      // the multiline fields are scrollable too).
      for (var i = 0;
          i < 10 && _field('Fingerprint (uTLS)').evaluate().isEmpty;
          i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -500));
        await tester.pumpAndSettle();
      }
      // The fingerprint field still shows the pin — the editor
      // does not silently rewrite it.
      expect(
        (_field('Fingerprint (uTLS)').evaluate().single.widget as TextField)
            .controller
            ?.text,
        _pin64,
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      // The save is refused in plain language, and the profile
      // is unchanged. (The text must be matched exactly: the
      // pin field's own label also contains "Certificate pin".)
      expect(
        find.text(
          'Fingerprint looks like a certificate pin (64 hex '
          'characters) — put it in the Certificate pin field '
          'instead.',
        ),
        findsOneWidget,
      );
      expect(xray.profiles, hasLength(1));
      expect(xray.profiles.single.fingerprint, _pin64);
      expect(xray.profiles.single.tlsCertPin, isEmpty);
    });
  });
}
