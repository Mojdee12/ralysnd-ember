// Build 2063 — feature queue #3: real kill switch. When it is on,
// an unexpected drop or a failed (re)connect holds the dead
// session's TUN as a blackhole instead of tearing it down, so
// traffic blocks until the tunnel reconnects or the user
// disconnects. Off by default: sharing off is byte-identical to
// every earlier build. Covers the V2Ray (Xray) and standalone
// WARP tunnels; AmneziaWG sessions cannot hold (the userspace
// device owns their TUN fd) and Psiphon/Lantern run their own
// services, so they are not covered — the Settings copy says so.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/lantern/lantern_controller.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/ui/ember/ember_settings.dart';
import 'package:firefox_vpn/xray/reconnect_policy.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

/// Pumps EmberSettings in V2Ray mode (1) with a fresh controller.
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
  group('Kill switch model (build 2063)', () {
    test('defaults off', () {
      expect(XraySettings().killSwitch, isFalse);
    });

    test('round-trips through JSON', () {
      final s = XraySettings()..killSwitch = true;
      final restored = XraySettings.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      expect(restored.killSwitch, isTrue);
    });

    test('wrong-typed stored value falls back, never throws', () {
      final s = XraySettings.fromJson({'killSwitch': 'yes'});
      expect(s.killSwitch, isFalse);
    });

    test('XrayState reports no hold by default', () {
      expect(XrayState.stopped.killSwitchHeld, isFalse);
    });
  });

  group('Reconnect notice wording (build 2063)', () {
    test('waiting text names the block when held, plain otherwise', () {
      final plain = reconnectWaitingText(
        attempt: 1,
        maxAttempts: 5,
        secondsLeft: 10,
      );
      final blocked = reconnectWaitingText(
        attempt: 1,
        maxAttempts: 5,
        secondsLeft: 10,
        blocked: true,
      );
      expect(plain, contains('Connection dropped'));
      expect(plain, isNot(contains('blocked')));
      expect(blocked, contains('Kill switch on'));
      expect(blocked, contains('traffic is blocked'));
      expect(blocked, contains('10s (attempt 1 of 5)'));
    });

    test('give-up text keeps traffic blocked until disconnect', () {
      final plain = reconnectGaveUpText(maxAttempts: 5);
      final blocked = reconnectGaveUpText(maxAttempts: 5, blocked: true);
      expect(plain, isNot(contains('blocked')));
      expect(blocked, contains('Traffic stays blocked until you disconnect.'));
    });
  });

  group('Dart plumbing (build 2063)', () {
    test('platform state() reads the killSwitchHeld key', () {
      expect(
        dartSrc('xray/xray_platform.dart'),
        contains("killSwitchHeld: m['killSwitchHeld'] as bool? ?? false"),
      );
    });

    test('setOn + setOnWarp carry the killSwitch flag', () {
      final src = dartSrc('xray/xray_platform.dart');
      expect(src, contains("bool killSwitch = false,"));
      expect(src, contains("'killSwitch': killSwitch,"));
    });

    test('controller passes the setting on both start paths', () {
      final src = dartSrc('xray/xray_controller.dart');
      expect(src, contains('killSwitch: settings.killSwitch,'));
      // Once for the V2Ray connect, once for the WARP connect.
      // Build 2127 re-point (H4): 2 -> 3 — the WG Tunnel
      // connect passes the setting to the library kill
      // switch as well.
      expect('killSwitch: settings.killSwitch,'.allMatches(src).length, 3);
    });

    test('reconnect notices read the held flag from the live state', () {
      final src = dartSrc('xray/xray_controller.dart');
      expect(src, contains('blocked: state.killSwitchHeld,'));
      expect('blocked: state.killSwitchHeld,'.allMatches(src).length, 3);
    });

    test('model still documents the AWG / engine scope honestly', () {
      expect(
        dartSrc('xray/xray_models.dart'),
        contains('AmneziaWG sessions cannot hold'),
      );
    });
  });

  group('Kotlin hold (build 2063)', () {
    late String kt;
    setUp(() => kt = ktSrc('XrayVpnService.kt'));

    test('hold keeps the TUN and stops the processes, never stopSelf', () {
      expect(kt, contains('private fun holdBlackhole(reason: String)'));
      expect(kt, contains('stopProcesses(keepTun = true)'));
      expect(kt, contains('blackholeHeld = true'));
      expect(kt, contains('running = false'));
      expect(kt, contains('updateNotification(profileName, blocked = true)'));
      final hold = kt.substring(kt.indexOf('private fun holdBlackhole'));
      final holdEnd = hold.indexOf('\n    }\n');
      final holdBody = hold.substring(0, holdEnd);
      expect(holdBody, isNot(contains('stopSelf()')));
      expect(holdBody, isNot(contains('stopForeground')));
    });

    test('fail() holds instead of tearing down when a TUN exists', () {
      expect(kt, contains('if (killSwitch && tunPfd != null)'));
      expect(kt, contains('holdBlackhole(coreProblem.ifEmpty'));
    });

    test('stopProcesses keeps the TUN fd only on a hold', () {
      expect(kt, contains('private fun stopProcesses(keepTun: Boolean = false)'));
      expect(kt, contains('if (!keepTun) {'));
    });

    test('every watcher death routes through onSessionDied', () {
      expect(kt, contains('private fun onSessionDied(reason: String)'));
      expect(kt, contains('onSessionDied("the V2Ray core exited'));
      expect(kt, contains('onSessionDied("the tunnel bridge exited'));
      expect(kt, contains('onSessionDied(coreProblem)'));
      // The watcher no longer tears down directly on a death.
      final watch = kt.substring(kt.indexOf('private fun watchProcesses()'));
      final watchEnd = watch.indexOf('private fun respawnUnderlay');
      final watchBody = watch.substring(0, watchEnd);
      expect(watchBody, isNot(contains('stopTunnel()')));
    });

    test('a manual stop releases the hold', () {
      final stop = kt.substring(kt.indexOf('private fun stopTunnel()'));
      final stopEnd = stop.indexOf('\n    }\n');
      expect(stop.substring(0, stopEnd), contains('blackholeHeld = false'));
    });

    test('a held fd closes only after the new TUN is up', () {
      // All three TUN start paths + the AWG path.
      // Build 2127 re-point (H5): 3 -> 2 literal copies —
      // the Xray path's hand-off moved into the shared
      // establishTun(), which keeps the same invariant in
      // generic form: the previous TUN is captured before
      // establish() and closed only after the new fd is
      // installed. The warp and socks paths keep theirs.
      expect('val heldPfd = if (blackholeHeld) tunPfd else null'
          .allMatches(kt)
          .length, 2);
      final est = kt.substring(kt.indexOf('private fun establishTun('));
      final estBody = est.substring(0, est.indexOf('\n    }\n'));
      expect(estBody, contains('val heldPfd = tunPfd'));
      expect(
        estBody.indexOf('builder.establish()') <
            estBody.indexOf('heldPfd.close()'),
        isTrue,
        reason: 'the held fd closes only after establish()',
      );
      // Build 2100 (W-WG2, named reason): the AWG path's own
      // `if (blackholeHeld)` hand-off block is gone with the
      // service move — AwgVpnService runs in another process
      // and cannot touch XrayVpnService's companion statics.
      // The hold is released before the AWG start instead: the
      // Dart connect path stops first whenever anything is up
      // OR held (see build2100_test.dart, "a held blackhole is
      // released before the AWG start"). The platform revoke
      // (onRevoke → stopTunnel) remains only as a backstop —
      // never the mechanism, because it is unproven for a
      // same-app establish and its stopForeground(REMOVE)
      // would strip the AWG notification sharing id 2.
      // What this test still pins: the revoke backstop exists,
      // and a manual stop releases the hold.
      expect(kt, contains('override fun onRevoke()'));
      final stop = kt.substring(kt.indexOf('private fun stopTunnel()'));
      expect(stop, contains('blackholeHeld = false'));
      // The close never precedes establish(): the swap sits
      // after the null-check in every start function.
      for (final label in ['returned null")', 'returned null (warp)"',
        'returned null (socks)"']) {
        final i = kt.indexOf(label);
        expect(i, isNot(-1));
        final after = kt.substring(i, i + 900);
        expect(after, contains('heldPfd'));
      }
    });

    test('notification says blocked while held', () {
      expect(kt, contains('"Kill switch active — traffic blocked"'));
    });

    test('start paths carry the flag; the WG session reports its real hold', () {
      expect(kt, contains('EXTRA_KILL_SWITCH'));
      expect(kt, contains('killSwitch = intent.getBooleanExtra(EXTRA_KILL_SWITCH, false)'));
      expect(kt, contains('killSwitch: Boolean = false,'));
      expect(kt, contains('putExtra(EXTRA_KILL_SWITCH, killSwitch)'));
      // Build 2100 (W-WG2, named reason): the AWG branch moved
      // to AwgVpnService.kt — the "never holds" comment moved
      // with it (same wording).
      // Build 2104: the AWG engine holds no TUN of its own in
      // Ember's code at all (the WG Tunnel backend owns it,
      // and Ember runs no kill-switch mode on it) — the
      // observable half is MainActivity's state merge, which
      // reports an AWG session's killSwitchHeld as false.
      // Build 2127 supersession (H4): the WG leg landed —
      // WgTunnelEngine drives the library's own kill switch
      // and MainActivity's merge now reports the snapshot's
      // REAL flag for both AWG state branches.
      expect(
        ktSrc('MainActivity.kt'),
        contains('"killSwitchHeld" to\n                                    awgSnap.killSwitchHeld,'),
      );
      expect(
        'awgSnap.killSwitchHeld'.allMatches(ktSrc('MainActivity.kt')).length,
        2,
      );
    });
  });

  group('MainActivity threading (build 2063)', () {
    test('state reports the hold; all eight starts pass the flag', () {
      final src = ktSrc('MainActivity.kt');
      expect(src, contains('"killSwitchHeld" to XrayVpnService.blackholeHeld'));
      // Build 2125 re-point (A25-04): 3 -> 6 readers — the
      // Lantern and OpenVPN setOn/start paths and the
      // Psiphon start now take the flag too.
      // Build 2127 re-point (H4): 6 -> 8 — the Mozilla
      // setOn mirror and the WG Tunnel setOn take it too.
      // Build 2156 re-point: 8 -> 9 — the URnetwork setOn
      // takes the flag too.
      expect('call.argument<Boolean>("killSwitch") ?: false'
          .allMatches(src)
          .length, 9);
    });
  });

  group('Kill switch Settings panel (build 2063)', () {
    testWidgets('row renders, off hides the scope caption', (tester) async {
      final xray = await pumpSettings(tester);
      expect(xray.settings.killSwitch, isFalse);
      expect(find.text('Kill switch'), findsOneWidget);
      expect(
        find.text(
          'Block all traffic while the tunnel is down, including the auto-reconnect wait.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('AmneziaWG, Psiphon and Lantern are not covered yet.'),
        findsNothing,
      );
    });

    testWidgets('on shows the honest scope caption', (tester) async {
      final xray = await pumpSettings(tester);
      xray.settings.killSwitch = true;
      xray.notifySettingsChanged();
      await tester.pump();
      // Build 2125 re-point (A25-04): the caption is the
      // corrected coverage — Psiphon, Lantern and OpenVPN
      // covered; Mozilla and AmneziaWG not.
      // Build 2127 supersession (H4): both remaining legs
      // landed — the caption now covers every engine and
      // the old exclusion claim is gone.
      expect(
        find.textContaining('This covers every engine'),
        findsOneWidget,
      );
      expect(
        find.textContaining('are not covered'),
        findsNothing,
      );
    });

    test('source: toggle writes the setting and rebuilds', () {
      final src = dartSrc('ui/ember/ember_settings.dart');
      expect(src, contains("label: 'Kill switch',"));
      expect(src, contains('s.killSwitch = v;'));
      expect(src, contains('xray.notifySettingsChanged();'));
    });
  });
}
