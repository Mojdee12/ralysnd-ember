/// Auto-reconnect policy (build 2042, feature-watch 2026-11-12).
///
/// The gap: when the tunnel dies unexpectedly the native service
/// tears the whole VPN down fail-closed and the Dart poll just
/// clears state — the user must reconnect by hand, and until he
/// does traffic goes direct. Adaptive failover (2026/2035) only
/// covers a live-but-silent tunnel. This file is the pure, unit-
/// testable half of the fix: when a retry may fire, and the exact
/// words the home card shows while it waits or after it gives up.
/// The timer + connect dispatch live in [XrayController].
///
/// A retry is NOT a kill-switch: the native service is down while
/// the app waits, so traffic is direct until the reconnect lands.
/// Nothing here claims otherwise. Build 2063 qualifies this: when
/// the kill switch is on, the dead session's TUN is held as a
/// blackhole while the retry waits — the waiting text then says
/// traffic is blocked (see [reconnectWaitingText]'s [blocked]
/// flag). The policy itself is unchanged; only the native side
/// holds instead of tearing down.

/// The wait before a retry attempt (build 2057, audit B-M5):
/// the base delay doubles per attempt — 10 s, 20 s, 40 s, 80 s
/// — capped at 80 s, so a flapping server no longer gets five
/// full engine starts at a constant rate. Pure, so the schedule
/// is unit-testable without a tunnel. [attempt] is 1-based.
int reconnectDelayForAttempt({required int baseSeconds, required int attempt}) {
  var delay = baseSeconds < 1 ? 1 : baseSeconds;
  for (var i = 1; i < attempt; i++) {
    delay *= 2;
    if (delay >= 80) return 80;
  }
  return delay > 80 ? 80 : delay;
}

/// True only when a retry may be scheduled: a session was up that
/// nobody disconnected ([sessionExpected]), the setting is on, and
/// the attempt budget is not spent.
bool shouldAutoReconnect({
  required bool sessionExpected,
  required bool enabled,
  required int attemptsMade,
  required int maxAttempts,
}) => sessionExpected && enabled && attemptsMade < maxAttempts;

/// The home-card line while the next retry is counting down.
/// [attempt] is 1-based (the try about to happen). With
/// [blocked] (kill switch on, build 2063) the native service is
/// holding the dead session's TUN as a blackhole, so the line
/// says traffic is blocked instead of merely naming the wait.
String reconnectWaitingText({
  required int attempt,
  required int maxAttempts,
  required int secondsLeft,
  bool blocked = false,
}) =>
    (blocked
        ? 'Kill switch on — traffic is blocked. Reconnecting in '
        : 'Connection dropped — reconnecting in ') +
    '${secondsLeft}s (attempt $attempt of $maxAttempts).';

/// The home-card line once the budget is spent. The user
/// reconnects by hand from here. With [blocked] the blackhole
/// is still held: traffic stays blocked until the user
/// disconnects, so the line says so instead of leaving a dead
/// card over an offline phone.
String reconnectGaveUpText({required int maxAttempts, bool blocked = false}) =>
    'Auto-reconnect gave up after $maxAttempts attempts — '
        'tap Connect to try again.' +
    (blocked ? ' Traffic stays blocked until you disconnect.' : '');

/// What adaptive failover's give-up does next (build 2049).
enum FailoverHandover {
  /// Hand the session to the auto-reconnect episode: schedule
  /// the countdown and retry through the same entry point.
  handOver,

  /// The give-up stays a notice; the user reconnects by hand.
  noticeOnly,

  /// A retry is already counting down: do nothing, the episode
  /// in flight owns the recovery.
  retryAlreadyPending,
}

/// The failover give-up decision (build 2049): adaptive
/// failover gave up on a live-but-silent tunnel. Hand over to
/// the auto-reconnect episode when no retry is already pending
/// and the 2042 policy allows it — the session is still
/// expected, the setting is on, the budget is not spent (a
/// fresh episode, so the budget is checked from zero).
/// Otherwise the give-up stays a notice and the user reconnects
/// by hand.
FailoverHandover failoverHandover({
  required bool retryPending,
  required bool sessionExpected,
  required bool enabled,
  required int attemptsMade,
  required int maxAttempts,
}) {
  if (retryPending) return FailoverHandover.retryAlreadyPending;
  if (!shouldAutoReconnect(
    sessionExpected: sessionExpected,
    enabled: enabled,
    attemptsMade: attemptsMade,
    maxAttempts: maxAttempts,
  )) {
    return FailoverHandover.noticeOnly;
  }
  return FailoverHandover.handOver;
}
