/// Build 2049 gates, host side: auto-reconnect takes over when
/// adaptive failover gives up (the named 2042 follow-up). The gap
/// was verified in code, not assumed: `_adaptiveTick` switched a
/// live-but-silent tunnel up to 3 times, then posted a give-up
/// notice and returned — the dead tunnel stayed up and the user
/// had to reconnect by hand, even with auto-reconnect ON (the
/// 2042 machinery only fires when the poll sees the tunnel DOWN).
/// These tests pin the Dart side of the contract: the pure
/// handover decision — when a failover give-up hands the session
/// to the auto-reconnect episode, when it stays a notice, and
/// when a retry already in flight owns the recovery. The timer +
/// connect dispatch live in XrayController and are not
/// host-testable without a device or a core.

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/reconnect_policy.dart';

void main() {
  group('Failover handover decision (build 2049)', () {
    test('hands over for a fresh expected episode, setting on', () {
      expect(
        failoverHandover(
          retryPending: false,
          sessionExpected: true,
          enabled: true,
          attemptsMade: 0,
          maxAttempts: 5,
        ),
        FailoverHandover.handOver,
      );
    });

    test('stays a notice when the setting is off', () {
      expect(
        failoverHandover(
          retryPending: false,
          sessionExpected: true,
          enabled: false,
          attemptsMade: 0,
          maxAttempts: 5,
        ),
        FailoverHandover.noticeOnly,
      );
    });

    test('stays a notice when the session is not expected', () {
      // A manual disconnect clears the expectation: the give-up
      // must never resurrect a session the user ended.
      expect(
        failoverHandover(
          retryPending: false,
          sessionExpected: false,
          enabled: true,
          attemptsMade: 0,
          maxAttempts: 5,
        ),
        FailoverHandover.noticeOnly,
      );
    });

    test('stays a notice when the attempt budget is spent', () {
      expect(
        failoverHandover(
          retryPending: false,
          sessionExpected: true,
          enabled: true,
          attemptsMade: 5,
          maxAttempts: 5,
        ),
        FailoverHandover.noticeOnly,
      );
    });

    test('hands over while budget remains', () {
      expect(
        failoverHandover(
          retryPending: false,
          sessionExpected: true,
          enabled: true,
          attemptsMade: 4,
          maxAttempts: 5,
        ),
        FailoverHandover.handOver,
      );
    });

    test('a pending retry owns the recovery, even if policy allows', () {
      // No second countdown: the episode in flight retries.
      expect(
        failoverHandover(
          retryPending: true,
          sessionExpected: true,
          enabled: true,
          attemptsMade: 0,
          maxAttempts: 5,
        ),
        FailoverHandover.retryAlreadyPending,
      );
    });

    test('a pending retry beats the setting check too', () {
      expect(
        failoverHandover(
          retryPending: true,
          sessionExpected: true,
          enabled: false,
          attemptsMade: 0,
          maxAttempts: 5,
        ),
        FailoverHandover.retryAlreadyPending,
      );
    });
  });
}
