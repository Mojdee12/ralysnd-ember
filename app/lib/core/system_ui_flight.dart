/// Build 2097 (wg-ovpn-add diagnosis IMP-1): tracks whether
/// a system-UI flow the app itself launched — a file
/// picker, the gallery picker, the document creator — is
/// currently in flight.
///
/// Why: those flows background the app. The app lock's
/// re-lock (build 2095) counts the backgrounding from the
/// lifecycle `paused` event, so a slow browse through the
/// system picker (over the 30 s grace) re-locked the app —
/// and the re-lock DISPOSED the very page whose import was
/// waiting on the pick, whose completion handler then
/// discarded the picked file at its `context.mounted`
/// check. The shell snapshots [inFlight] when the pause
/// lands and does not re-lock for a backgrounding that
/// belongs to a flight.
///
/// The counter is deliberately simple: every platform
/// entry point that launches one of these flows brackets
/// its channel call with [begin]/[end]. Flights never nest
/// in practice (one picker at a time), but the counter
/// keeps an overlap honest anyway.
import 'package:flutter/foundation.dart' show visibleForTesting;

class SystemUiFlight {
  /// The begin time of every outstanding flight, oldest
  /// first. A stack, not a counter with one anchor — the
  /// two single-anchor shapes each failed one direction
  /// (build 2098 verification V-6 and iteration 2):
  /// anchoring to the FIRST begin let a fresh pick inherit
  /// a stranded flight's age and lose its own protection;
  /// re-stamping on EVERY begin let a stranded flight
  /// borrow a later flight's youth forever, so the re-lock
  /// never re-armed in an active session. With the stack,
  /// the stranded question is asked of the NEWEST
  /// outstanding flight: while a fresh flight is genuinely
  /// open it protects the pause; the moment it ends, an
  /// older stranded flight underneath is exposed again.
  /// (Ends are matched to the newest begin — flights never
  /// nest in practice, and a stranded flight's end never
  /// arrives at all.)
  static final List<DateTime> _begins = [];

  static bool get inFlight => _begins.isNotEmpty;

  /// Build 2098 (post-2097 audit L28): a pick whose result
  /// is stranded — the activity was recreated mid-pick and
  /// the platform side never answers (IMP-R, parked) — used
  /// to leak its flight for the rest of the session: the
  /// counter never returned to zero, every later pause
  /// snapshotted "flight", and the app lock never re-armed
  /// again. A real picker session does not run anywhere
  /// near this bound; a stranded one runs forever. Past
  /// the bound the flight is [stranded] and stops
  /// suppressing the re-lock (the stranded pick itself
  /// stays IMP-R's parked loss — this closes only its
  /// lock-suppression side effect).
  static const Duration strandedAfter = Duration(minutes: 10);

  static bool get stranded =>
      _begins.isNotEmpty &&
      DateTime.now().difference(_begins.last) >= strandedAfter;

  /// What the shell snapshots at pause: a live flight
  /// suppresses the re-lock; a finished or stranded one
  /// does not.
  static bool get suppressesRelock => inFlight && !stranded;

  static void begin() {
    _begins.add(DateTime.now());
  }

  static void end() {
    if (_begins.isNotEmpty) _begins.removeLast();
  }

  @visibleForTesting
  static void resetForTest() {
    _begins.clear();
  }

  @visibleForTesting
  static void ageCurrentFlightForTest(Duration age) {
    for (var i = 0; i < _begins.length; i++) {
      _begins[i] = _begins[i].subtract(age);
    }
  }
}
