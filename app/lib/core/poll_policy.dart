/// Poll cadence policy (build 2050, audit §3 battery).
///
/// Every engine controller polls its native side every 2 s
/// while its session runs — and until this build it did so at
/// full rate forever: app backgrounded, screen off, another
/// engine on screen. The decisions here are pure so the
/// contract is unit-tested, and every controller applies the
/// same numbers:
///
/// - foreground: the live 2 s cadence the UI rates need;
/// - backgrounded: a 30 s heartbeat — sessions stay supervised
///   (drop detection, auto-reconnect, stats catch-up all still
///   run, just slower), and the accumulated traffic deltas are
///   read whole on the next tick, so no totals are ever lost.
library;

/// The poll period for an engine session poller.
Duration enginePollPeriod({required bool foreground}) => foreground
    ? const Duration(seconds: 2)
    : const Duration(seconds: 30);

/// The poll period for the Mozilla core poller, which runs
/// even with no session: fast only while the app is foregrounded
/// AND the Mozilla engine is the one on stage (or on); a 30 s
/// heartbeat otherwise (audit B-H2 — it previously ticked at
/// 2 s from app launch, forever, whatever was on screen).
Duration corePollPeriod({required bool foreground, required bool active}) =>
    (foreground && active)
    ? const Duration(seconds: 2)
    : const Duration(seconds: 30);

/// The wait before the next exit-IP lookup after [failures]
/// consecutive failures (build 2050, audit B-H3): 5 s, 15 s,
/// 45 s, then a 2-minute cap. Until this build a failed lookup
/// retried at the full 2 s poll cadence forever — up to two
/// sequential 6 s-timeout requests per attempt — keeping the
/// radio hot on exactly the broken networks where it fails.
Duration exitRetryDelay(int failures) {
  if (failures <= 1) return const Duration(seconds: 5);
  if (failures == 2) return const Duration(seconds: 15);
  if (failures == 3) return const Duration(seconds: 45);
  return const Duration(seconds: 120);
}
