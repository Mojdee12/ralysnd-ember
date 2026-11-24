/// Build 2042 gates, host side: Auto-reconnect with configurable
/// delay + attempt limit (feature-watch 2026-11-12). The gap was
/// verified in code, not assumed: when the tunnel dies
/// unexpectedly the native service tears the whole VPN down
/// fail-closed (XrayVpnService.watchProcesses → stopTunnel) and
/// the Dart poll just clears state — nothing retries a dead
/// session. These tests pin the Dart side of the contract:
/// settings defaults, clamps and round-trip (a corrupt store can
/// never spin a tight retry loop or wait forever), and the pure
/// retry decision + home-card wording (the timer + connect
/// dispatch live in XrayController and are not host-testable
/// without a device or a core).

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/reconnect_policy.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

void main() {
  group('Auto-reconnect settings (build 2042)', () {
    test('defaults are off (build 2114), 10 s, 5 attempts', () {
      // Build 2114 (defaults reset): auto-reconnect is an
      // Ember extra — default OFF, v2rayNG parity. The
      // delay/attempts defaults are unchanged.
      final s = XraySettings();
      expect(s.autoReconnect, isFalse);
      expect(s.reconnectDelaySeconds, 10);
      expect(s.reconnectMaxAttempts, 5);
    });

    test('an old store without the keys reads the defaults', () {
      final s = XraySettings.fromJson({});
      expect(s.autoReconnect, isFalse);
      expect(s.reconnectDelaySeconds, 10);
      expect(s.reconnectMaxAttempts, 5);
    });

    test('round-trip keeps a deliberate choice', () {
      final s = XraySettings()
        ..autoReconnect = false
        ..reconnectDelaySeconds = 30
        ..reconnectMaxAttempts = 3;
      final back = XraySettings.fromJson(s.toJson());
      expect(back.autoReconnect, isFalse);
      expect(back.reconnectDelaySeconds, 30);
      expect(back.reconnectMaxAttempts, 3);
    });

    test('clamps hold on load: delay 5..120, attempts 1..20', () {
      expect(
        XraySettings.fromJson({'reconnectDelaySeconds': 1})
            .reconnectDelaySeconds,
        5,
      );
      expect(
        XraySettings.fromJson({'reconnectDelaySeconds': 999})
            .reconnectDelaySeconds,
        120,
      );
      expect(
        XraySettings.fromJson({'reconnectMaxAttempts': 0})
            .reconnectMaxAttempts,
        1,
      );
      expect(
        XraySettings.fromJson({'reconnectMaxAttempts': 99})
            .reconnectMaxAttempts,
        20,
      );
      expect(XraySettings.clampReconnectDelay(4), 5);
      expect(XraySettings.clampReconnectDelay(121), 120);
      expect(XraySettings.clampReconnectMaxAttempts(0), 1);
      expect(XraySettings.clampReconnectMaxAttempts(21), 20);
    });

    test('a stored off stays off — no silent re-enable', () {
      expect(
        XraySettings.fromJson({'autoReconnect': false}).autoReconnect,
        isFalse,
      );
    });
  });

  group('Auto-reconnect policy (build 2042)', () {
    test('fires only for an expected session, enabled, budget left', () {
      expect(
        shouldAutoReconnect(
          sessionExpected: true,
          enabled: true,
          attemptsMade: 0,
          maxAttempts: 5,
        ),
        isTrue,
      );
      // A manual disconnect clears the expectation: never retry.
      expect(
        shouldAutoReconnect(
          sessionExpected: false,
          enabled: true,
          attemptsMade: 0,
          maxAttempts: 5,
        ),
        isFalse,
      );
      // The setting off means no retry even for a real drop.
      expect(
        shouldAutoReconnect(
          sessionExpected: true,
          enabled: false,
          attemptsMade: 0,
          maxAttempts: 5,
        ),
        isFalse,
      );
      // A spent budget stops the loop instead of flapping forever.
      expect(
        shouldAutoReconnect(
          sessionExpected: true,
          enabled: true,
          attemptsMade: 5,
          maxAttempts: 5,
        ),
        isFalse,
      );
      expect(
        shouldAutoReconnect(
          sessionExpected: true,
          enabled: true,
          attemptsMade: 4,
          maxAttempts: 5,
        ),
        isTrue,
      );
    });

    test('waiting text names the attempt, the budget and the countdown',
        () {
      final t = reconnectWaitingText(
        attempt: 2,
        maxAttempts: 5,
        secondsLeft: 7,
      );
      expect(t, contains('2 of 5'));
      expect(t, contains('7s'));
      expect(t, contains('reconnecting'));
    });

    test('give-up text names the budget and points at a manual connect',
        () {
      final t = reconnectGaveUpText(maxAttempts: 5);
      expect(t, contains('5 attempts'));
      expect(t, contains('tap Connect'));
    });
  });
}
