/// Build 2095 (feature 1 — emergency mode): the pure walk
/// behind the one-tap "try everything" flow. Engines are
/// tried in [emergencyModeOrder] until one attempt reports
/// a proven connect; the walk stops there, or at cancel.
/// Mode numbers are the shell's: 0 Mozilla, 1 V2Ray,
/// 3 Lantern, 4 OpenVPN, 5 WireGuard, 6 WARP, 7 MASQUE.
/// Psiphon (2) is deliberately absent — its connection
/// work is parked (owner order), so the emergency walk
/// skips it and says so in its UI.

/// The order engines are tried: the config engines with
/// the broadest config pools first, account engines last.
const emergencyModeOrder = [1, 5, 6, 7, 3, 4, 0];

const emergencyModeNames = {
  0: 'Mozilla',
  1: 'V2Ray',
  3: 'Lantern',
  4: 'OpenVPN',
  5: 'WireGuard',
  6: 'WARP',
  7: 'MASQUE',
};

/// Runs [attempt] for each mode in [order] until one
/// returns true. [cancelled] is polled before every
/// attempt. [onTry] fires before each attempt (progress
/// UI). Returns the winning mode, or null.
Future<int?> runEmergencyWalk({
  required List<int> order,
  required Future<bool> Function(int mode) attempt,
  required bool Function() cancelled,
  void Function(int mode)? onTry,
  Future<void> Function(int mode)? disconnectMode,
}) async {
  for (final mode in order) {
    if (cancelled()) return null;
    onTry?.call(mode);
    if (await attempt(mode)) {
      // Build 2098 (post-2097 audit L5, sweep-A R3-b): a
      // cancel that landed while the winning attempt was
      // finishing must not be reported as a win — the
      // winner is re-checked here, and its mode is
      // disconnected rather than left up behind a
      // "Connected via …" the user had cancelled.
      if (cancelled()) {
        if (disconnectMode != null) await disconnectMode(mode);
        return null;
      }
      return mode;
    }
    if (cancelled()) return null;
  }
  return null;
}

/// Build 2096 (post-2095 audit H7/H8/L2): one emergency
/// attempt, as a callback-driven unit so the walk logic
/// is testable without the shell. Behaviour:
///
/// - H7: the Xray engine serves BOTH the V2Ray (1) and
///   WireGuard (5) sections — a WireGuard config selected
///   in the store connects under mode 1's toggle as a
///   mode-5 session. For Xray modes the proof credits
///   either section and reports the lit one through
///   [onXraySection]; build 2095's section-blind proof
///   burned the whole poll on a working WireGuard session
///   and let the later WireGuard attempt toggle it OFF.
/// - H8: the toggle is raced against [cancelled]: a
///   cancel during the in-flight connect calls
///   [disconnectMode] for the mode (the controllers'
///   generation guards abort the attempt) and waits for
///   the toggle to unwind — no tunnel comes up behind
///   the closed dialog.
/// - L2: the proof must HOLD for three consecutive
///   samples, not a single instantaneous read.
Future<bool> runEmergencyAttempt({
  required int mode,
  required int? runningMode,
  required Future<void> Function(int mode) disconnectMode,
  required Future<void> Function(int mode) toggle,
  required bool Function(int mode) engineActive,
  required bool Function() cancelled,
  required void Function(int section) onXraySection,
  Duration togglePollInterval = const Duration(milliseconds: 200),
  Duration proofPollInterval = const Duration(milliseconds: 500),
  int proofPolls = 40,
}) async {
  if (runningMode != null && runningMode != mode) {
    await disconnectMode(runningMode);
  }
  var toggleDone = false;
  final toggleFuture = toggle(mode).then((_) {
    toggleDone = true;
  }, onError: (Object _) {
    // The toggles surface their own errors; the walk
    // judges by the engine's active signal only.
    toggleDone = true;
  });
  while (!toggleDone) {
    if (cancelled()) {
      await disconnectMode(mode);
      await toggleFuture;
      return false;
    }
    await Future<void>.delayed(togglePollInterval);
  }
  await toggleFuture;
  // Build 2097 (post-2096 audit N1): the toggle COMPLETED
  // — a cancel landing in this final gap (or anywhere in
  // the proof window below) must disconnect the mode it
  // just started, not merely stop watching it. Build 2096
  // returned here and in the proof loop without ever
  // calling disconnectMode, so the dialog closed on a
  // tunnel that stayed up and carrying traffic.
  if (cancelled()) {
    await disconnectMode(mode);
    return false;
  }
  bool proof() {
    if (mode == 1 || mode == 5) {
      if (engineActive(5)) {
        onXraySection(5);
        return true;
      }
      if (engineActive(1)) {
        onXraySection(1);
        return true;
      }
      return false;
    }
    return engineActive(mode);
  }

  var held = 0;
  for (var i = 0; i < proofPolls; i++) {
    if (cancelled()) {
      await disconnectMode(mode);
      return false;
    }
    if (proof()) {
      held++;
      if (held >= 3) break;
    } else {
      held = 0;
    }
    await Future<void>.delayed(proofPollInterval);
  }
  if (held >= 3) {
    // Build 2098 (post-2097 audit L5, sweep-A R3-b): the
    // final proof sample is not the last word — a cancel
    // that landed inside the final proof interval is
    // honoured here, with the mode disconnected, instead
    // of the walk declaring a winner the user cancelled.
    if (cancelled()) {
      await disconnectMode(mode);
      return false;
    }
    return true;
  }
  return false;
}

/// Build 2095 (feature 9 — smart alternative): classifies
/// a connect failure as blocking-class (timeout / handshake
/// / DPI signatures) and names the alternative worth one
/// tap. Returns (mode, label) or null when the failure does
/// not look like blocking. Modes are the shell's.
(int, String)? alternativeForFailure(int failedMode, String errorText) {
  final t = errorText.toLowerCase();
  final blocking = t.contains('timeout') ||
      t.contains('timed out') ||
      t.contains('handshake') ||
      t.contains('connection reset') ||
      t.contains('eof') ||
      t.contains('no route') ||
      t.contains('unreachable') ||
      // Build 2096 (post-2095 audit M21): the WireGuard
      // walk's all-peers-failed code names no keyword
      // above, so the WARP offer never fired for exactly
      // the failure it was written for.
      t.contains('wg-all-peers-failed');
  if (!blocking) return null;
  switch (failedMode) {
    case 1: // V2Ray blocked → WARP's Cloudflare edge often passes.
      return (6, 'Try WARP');
    case 5: // WireGuard UDP blocked → WARP (MASQUE/QUIC or WG-obfs).
      return (6, 'Try WARP');
    case 6:
    case 7: // WARP blocked → a V2Ray config (Reality) is the fallback.
      return (1, 'Try a V2Ray config');
    case 3: // Lantern blocked → V2Ray.
      return (1, 'Try a V2Ray config');
    case 4: // OpenVPN blocked → V2Ray.
      return (1, 'Try a V2Ray config');
    case 0: // Mozilla blocked → V2Ray.
      return (1, 'Try a V2Ray config');
    case 8: // URnetwork blocked → V2Ray (build 2156).
      return (1, 'Try a V2Ray config');
    default:
      return null;
  }
}
