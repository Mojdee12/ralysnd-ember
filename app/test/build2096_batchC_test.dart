// Build 2096 — batch C tests: emergency mode (H7/H8/L2),
// the smart-alternative classifier (M21), and the shell
// arbitration wraps (M7/M23/M24, pinned — shell-private
// surfaces, the standing exception from audit-3 8-6/8-7).
//
// H7/H8 run the REAL runEmergencyAttempt /
// runEmergencyWalk from emergency.dart against a fake
// engine world — behavioural, not source pins.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/ui/ember/emergency.dart';

class FakeWorld {
  final active = <int, bool>{};
  final toggles = <int>[];
  final disconnects = <int>[];
  bool cancelled = false;
  int section = 1;

  bool engineActive(int m) => active[m] ?? false;

  Future<void> disconnectMode(int m) async {
    disconnects.add(m);
    active[m] = false;
  }
}

void main() {
  group('H7 — the emergency proof credits the Xray section '
      'that actually lit', () {
    test('a WireGuard config connecting under the V2Ray '
        'attempt wins the walk; the WireGuard attempt '
        'never toggles it off', () async {
      final w = FakeWorld();
      Future<void> toggle(int m) async {
        w.toggles.add(m);
        if (m == 1) {
          // The selected profile is a WireGuard config:
          // the Xray engine lights section 5, not 1.
          w.active[5] = true;
        } else if (m == 5) {
          // Toggle semantics: would turn the session OFF.
          w.active[5] = !(w.active[5] ?? false);
        }
      }

      Future<bool> attempt(int m) => runEmergencyAttempt(
            mode: m,
            runningMode: null,
            disconnectMode: w.disconnectMode,
            toggle: toggle,
            engineActive: w.engineActive,
            cancelled: () => w.cancelled,
            onXraySection: (s) => w.section = s,
            togglePollInterval: const Duration(milliseconds: 5),
            proofPollInterval: const Duration(milliseconds: 5),
            proofPolls: 60,
          );

      final winner = await runEmergencyWalk(
        order: emergencyModeOrder,
        attempt: attempt,
        cancelled: () => w.cancelled,
      );
      expect(winner, 1, reason: 'the V2Ray attempt is the winner');
      expect(w.section, 5,
          reason: 'the section that lit is WireGuard');
      expect(w.toggles, [1],
          reason: 'the walk stopped — mode 5 was never '
              'toggled, so the working session survives');
      expect(w.active[5], isTrue);
    });

    test('a plain V2Ray winner reports section 1', () async {
      final w = FakeWorld();
      Future<void> toggle(int m) async {
        w.toggles.add(m);
        if (m == 1) w.active[1] = true;
      }

      final ok = await runEmergencyAttempt(
        mode: 1,
        runningMode: null,
        disconnectMode: w.disconnectMode,
        toggle: toggle,
        engineActive: w.engineActive,
        cancelled: () => w.cancelled,
        onXraySection: (s) => w.section = s,
        togglePollInterval: const Duration(milliseconds: 5),
        proofPollInterval: const Duration(milliseconds: 5),
        proofPolls: 60,
      );
      expect(ok, isTrue);
      expect(w.section, 1);
    });
  });

  group('H8 — Cancel during an in-flight connect', () {
    test('disconnects the mode and no tunnel comes up',
        () async {
      final w = FakeWorld();
      var aborted = false;
      Future<void> toggle(int m) async {
        w.toggles.add(m);
        // A long connect (carrier ladder): completes after
        // ~600 ms and lights the engine — unless a
        // disconnect aborted it first (the controllers'
        // generation guards do exactly this).
        await Future<void>.delayed(
            const Duration(milliseconds: 600));
        if (!aborted) w.active[m] = true;
      }

      Future<void> disconnect(int m) async {
        w.disconnects.add(m);
        aborted = true;
        w.active[m] = false;
      }

      final attemptFuture = runEmergencyAttempt(
        mode: 3,
        runningMode: null,
        disconnectMode: disconnect,
        toggle: toggle,
        engineActive: w.engineActive,
        cancelled: () => w.cancelled,
        onXraySection: (_) {},
        togglePollInterval: const Duration(milliseconds: 20),
        proofPollInterval: const Duration(milliseconds: 5),
        proofPolls: 60,
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      w.cancelled = true; // the user taps Cancel
      final ok = await attemptFuture;
      expect(ok, isFalse);
      expect(w.disconnects, contains(3),
          reason: 'cancel acted on the in-flight connect');
      expect(w.active[3], isNot(true),
          reason: 'no tunnel came up behind the dialog');
    });
  });

  group('L2 — the proof must hold, not flicker', () {
    test('a single-sample flicker does not win', () async {
      final w = FakeWorld();
      var samples = 0;
      bool flicker(int m) {
        samples++;
        return samples == 2; // one true sample, then dark
      }

      final ok = await runEmergencyAttempt(
        mode: 3,
        runningMode: null,
        disconnectMode: w.disconnectMode,
        toggle: (_) async {},
        engineActive: flicker,
        cancelled: () => w.cancelled,
        onXraySection: (_) {},
        togglePollInterval: const Duration(milliseconds: 5),
        proofPollInterval: const Duration(milliseconds: 5),
        proofPolls: 12,
      );
      expect(ok, isFalse);
    });
  });

  group('M21 — smart alternative covers the WireGuard '
      'walk failure code', () {
    test('wg-all-peers-failed offers WARP', () {
      expect(
        alternativeForFailure(5, 'wg-all-peers-failed'),
        (6, 'Try WARP'),
      );
    });

    test('a non-blocking failure still offers nothing', () {
      expect(
        alternativeForFailure(5, 'the config is invalid'),
        isNull,
      );
    });
  });

  group('M7/M23/M24 — shell arbitration (pins)', () {
    final shell = File('lib/ui/ember/ember_shell.dart').readAsStringSync();

    test('rotate refuses while any engine is connecting', () {
      final rotate = shell.substring(
        shell.indexOf('Future<void> _notificationRotateInner'),
        shell.indexOf('Future<void> _notificationRotateInner') + 1600,
      );
      expect(rotate, contains('if (_anyEngineConnecting) return;'));
    });

    test('unlock replay: a queued navigation action owns '
        'the tunnel decision (M23)', () {
      // Updated for L24 (build 2096): the pending slots
      // are queues — the ownership check reads their
      // drained lists.
      expect(
        shell,
        contains(
            'if (shortcuts.isNotEmpty || files.isNotEmpty || '
            'deepLinks.isNotEmpty)'),
      );
      // PIN UPDATED by build 2097 (post-2096 audit C-L4):
      // the rotate replay is suppressed by queued files
      // and deep links too, not only shortcuts — a queued
      // file/deep-link owns the tunnel decision exactly
      // like a queued shortcut.
      expect(
        shell,
        contains(
            'if (rotate && shortcuts.isEmpty && files.isEmpty && '
            'deepLinks.isEmpty)'),
      );
    });

    test('chip-tap stop and the pause entries join the '
        'serialization queue (M24)', () {
      expect(
        shell,
        contains('_serialized(() => _disconnectMode(running))'),
      );
      // PIN UPDATED by build 2097 (post-2096 audit C-L16):
      // the serialized entries now route through the
      // intent-re-evaluating wrappers (_ensureModeOn /
      // _ensureModeOff) instead of calling _toggleForMode
      // directly — the serialization contract is unchanged.
      final serializedToggles =
          '_serialized(() => _ensureMode'.allMatches(shell).length;
      expect(serializedToggles, greaterThanOrEqualTo(3),
          reason: 'unlock resume, pause disconnect, pause '
              'timer and resume-now all serialize');
    });
  });
}
