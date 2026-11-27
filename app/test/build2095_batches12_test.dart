/// Build 2095 — journey-audit batches 1 (session truth) and
/// 2 (app lock). The regression pins for the defects the two
/// 2026-11-17 journey audits ranked highest:
///
/// * #1 a chip tap navigated only — the running engine kept
///   the tunnel while the new screen read "Not connected"
///   and its power button connected a second engine.
/// * #2 the WireGuard power button fell through to a V2Ray
///   connect.
/// * #10/#11/#12 the bottom bar presented stale values as
///   live facts (Mozilla location/exit IP after disconnect,
///   a stored delay-test result labelled LATENCY, the
///   REQUESTED Psiphon region shown as the exit region).
/// * #3 the QS tile showed INACTIVE while another engine
///   ran and started Mozilla over it, bypassing arbitration.
/// * #25 every toggle mapped a VPN-permission denial to the
///   generic start-failed line.
/// * #26 the Psiphon toggle swallowed the controller's
///   plain-language failure reasons.
/// * #4 one unlock lasted the process's life — no re-lock.
/// * #5 shortcuts, .ovpn imports, auto-connect, pause
///   resumes and notification actions executed behind the
///   lock page.
/// * #45 the PIN pad had no attempt backoff and the lock
///   page did not opt into the overlay guard.
/// * #22 a notification Rotate tap on a group-less profile
///   silently did nothing.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/ui/ember/app_lock.dart';
import 'package:firefox_vpn/ui/ember/ember_shell.dart';

String _read(String path) => File(path).readAsStringSync();
String _dart(String path) => _read('lib/$path');
String _kt(String path) =>
    _read('android/app/src/main/kotlin/com/ralysnd/ember/$path');

/// The body of one method in a Dart source, from its
/// signature line to the next method at the same indent.
String _methodBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: 'missing: $signature');
  final rest = source.substring(start);
  final next = rest.indexOf('\n  Future<void> _', 10);
  final nextVoid = rest.indexOf('\n  void _', 10);
  var end = rest.length;
  if (next > 0 && next < end) end = next;
  if (nextVoid > 0 && nextVoid < end) end = nextVoid;
  return rest.substring(0, end);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('batch 1 — session truth (source)', () {
    final shell = _dart('ui/ember/ember_shell.dart');

    test('chip tap stops a different running engine', () {
      final body = _methodBody(shell, 'void _chipTap(int m)');
      expect(body, contains('_runningMode'));
      expect(body, contains('_disconnectMode(running)'));
      // The V2Ray/WireGuard sections are one engine: moving
      // between them must not stop it.
      expect(body, contains('_sameXraySection(running, m)'));
    });

    test('power capsule acts on the running engine, not the '
        'selected one', () {
      // Build 2095 (audit-3 2.3): _powerToggle is the
      // serializing wrapper; the behavior lives in Inner.
      final body = _methodBody(
        shell,
        'Future<void> _powerToggleInner(BuildContext context, int m)',
      );
      expect(body, contains('final running = _runningMode;'));
      expect(body, contains('await _disconnectMode(running);'));
    });

    test('WireGuard toggle never falls through to V2Ray', () {
      final body = _methodBody(
        shell,
        'Future<void> _toggleWireGuard(BuildContext context)',
      );
      expect(body, isNot(contains('await _toggleXray(context);')));
      expect(body, contains('Select a WireGuard config first'));
    });

    test('bar: Mozilla LOCATION / EXIT IP gated on `on`', () {
      expect(shell, contains("on && cityCountry.isNotEmpty"));
      // Build 2095 (batch 8, #28): the showPublicIp
      // setting gates the cell too.
      expect(shell, contains("on && showIp && exitIp.isNotEmpty"));
    });

    test('bar: stale delay is labelled LAST TEST, never LATENCY', () {
      expect(shell, contains("'LAST TEST \${latDigits(p.delayMs)}ms"));
      expect(shell, isNot(contains("'LATENCY \${latDigits(p.delayMs)}ms")));
    });

    test('bar: Psiphon EXIT REGION is the landed region, '
        'connected only; rates gate on connected', () {
      expect(shell, contains('on && state.region.isNotEmpty'));
      expect(shell, contains("value: on ? fmtRate(_psiphon.upRate) : '—'"));
      expect(shell, contains("value: on ? fmtRate(_psiphon.downRate) : '—'"));
    });

    test('Psiphon toggle surfaces the controller reason', () {
      final body = _methodBody(
        shell,
        'Future<void> _togglePsiphon(BuildContext context)',
      );
      expect(body, contains('_psiphon.lastError ?? e.message'));
    });

    test('every toggle checks for a VPN-permission denial', () {
      expect(
        'context.mounted && _showVpnDenied(context, e)'.allMatches(shell).length,
        8,
        reason: 'one per engine toggle (Mozilla, Xray, Psiphon, '
            'Lantern, OpenVPN, WireGuard, Aether, URnetwork) '
            '— build 2156 re-point for the UR toggle',
      );
      expect(shell, contains("e.code == 'vpn_denied'"));
      expect(shell, contains('vpnNotAllowed'));
    });

    test('notification Rotate says so when there is no group', () {
      final body = _methodBody(
        shell,
        'Future<void> _notificationRotateInner()',
      );
      expect(body, contains('No other server in this group'));
    });

    test('QS tile: truthful state, no arbitration bypass', () {
      final kt = _kt('QuickTile.kt');
      expect(kt, contains('anotherEngineUp()'));
      expect(kt, contains('TRANSPORT_VPN'));
      // In the other-engine branch the tile opens the app —
      // it never calls turnOn over a live foreign tunnel.
      final branch = kt.substring(kt.indexOf('anotherEngineUp()'));
      expect(branch.substring(0, branch.indexOf('usesVpn')), contains('openApp()'));
      expect(kt, contains('"Another engine is on"'));
    });
  });

  group('batch 2 — app lock (pure decisions)', () {
    test('relockDue: under the grace stays unlocked, at/over re-locks', () {
      final t0 = DateTime(2026, 11, 17, 12);
      expect(
        relockDue(backgroundedAt: t0, resumedAt: t0.add(const Duration(seconds: 29))),
        isFalse,
      );
      expect(
        relockDue(backgroundedAt: t0, resumedAt: t0.add(const Duration(seconds: 30))),
        isTrue,
      );
      expect(
        relockDue(backgroundedAt: t0, resumedAt: t0.add(const Duration(minutes: 5))),
        isTrue,
      );
      expect(
        relockDue(
          backgroundedAt: t0,
          resumedAt: t0.add(const Duration(seconds: 5)),
          grace: const Duration(seconds: 3),
        ),
        isTrue,
      );
    });

    test('lockCooldownSeconds: the backoff schedule', () {
      expect(lockCooldownSeconds(0), 0);
      expect(lockCooldownSeconds(2), 0);
      expect(lockCooldownSeconds(3), 15);
      expect(lockCooldownSeconds(4), 30);
      expect(lockCooldownSeconds(5), 60);
      expect(lockCooldownSeconds(6), 120);
      expect(lockCooldownSeconds(7), 240);
      expect(lockCooldownSeconds(8), 300);
      expect(lockCooldownSeconds(20), 300);
    });
  });

  group('batch 2 — app lock (source)', () {
    final shell = _dart('ui/ember/ember_shell.dart');

    test('lifecycle re-locks after a real backgrounding', () {
      final body = _methodBody(shell, 'void didChangeAppLifecycleState');
      expect(body, contains('AppLifecycleState.paused'));
      expect(body, contains('relockDue('));
      expect(body, contains('_unlocked = false'));
    });

    test('non-UI entry points queue behind the lock', () {
      expect(
        _methodBody(shell, 'Future<void> _connectFromShortcutInner'),
        contains('_pendingShortcutIds.add(profileId)'),
      );
      expect(
        _methodBody(shell, 'Future<void> _importOpenVpnIntent'),
        contains('_pendingOvpnFiles.add(file)'),
      );
      expect(
        _methodBody(shell, 'Future<void> _notificationRotateInner()'),
        contains('_pendingRotate = true'),
      );
      expect(
        _methodBody(shell, 'Future<void> _autoConnectInner()'),
        contains('_pendingAutoConnect = true'),
      );
      expect(shell, contains('_pendingResumeMode = m'));
      // …and the unlock replays them.
      // PIN UPDATED by build 2096 (post-2095 audit L24):
      // the pending slots are per-kind queues now — the
      // replay loops over them.
      final unlock = _methodBody(shell, 'void _onUnlocked()');
      expect(unlock, contains('_connectFromShortcut(id)'));
      expect(unlock, contains('_importOpenVpnIntent(file)'));
      expect(unlock, contains('_notificationRotate()'));
    });

    test('the lock page opts into the overlay guard', () {
      final lock = _dart('ui/ember/app_lock.dart');
      expect(lock, contains('OverlayGuard('));
    });
  });

  group('batch 2 — PIN pad backoff (widget)', () {
    // PIN UPDATED by build 2096 (post-2095 audit L23):
    // every failed VERIFICATION counts — a typed entry's
    // length-4 auto-submit and its confirm are two
    // verifications, so the cooldown (from the 3rd
    // failure) starts during the SECOND wrong entry, not
    // after the third.
    testWidgets('three wrong PINs start a cooldown; the pad '
        'ignores digits during it', (tester) async {
      var unlocked = false;
      final s = AppSettings();
      s.update(appLockPinHash: pinHashOf('1234'));
      await tester.pumpWidget(
        MaterialApp(
          home: AppLockPage(settings: s, onUnlocked: () => unlocked = true),
        ),
      );
      await tester.pump();

      Future<void> wrongPin() async {
        for (final d in ['9', '9', '9', '9']) {
          await tester.tap(find.text(d));
          await tester.pump();
        }
        await tester.tap(find.byIcon(Icons.check_rounded));
        await tester.pump();
      }

      await wrongPin();
      expect(find.textContaining('Too many wrong PINs'), findsNothing);
      await wrongPin();
      expect(find.textContaining('Too many wrong PINs'), findsOneWidget);
      expect(unlocked, isFalse);

      // Digits during the cooldown change nothing and the
      // correct PIN cannot be entered until it lapses.
      for (final d in ['1', '2', '3', '4']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      await tester.tap(find.byIcon(Icons.check_rounded));
      await tester.pump();
      expect(unlocked, isFalse);
      expect(find.textContaining('Too many wrong PINs'), findsOneWidget);
    });
  });
}
