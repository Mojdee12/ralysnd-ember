/// Build 2088: the Psiphon external watchdog's decision —
/// when the MAIN process stops waiting on a start attempt
/// and acts on it from outside the :psiphon process.
///
/// Why this exists: build 2087 put the wedge instrumentation
/// inside the :psiphon process (heartbeat + watchdog), and
/// the owner's phone proved a wedged process cannot report
/// its own wedge — the heartbeat fired once, the watchdog's
/// record never landed, and the start hung exactly as
/// before. So the deadline moved out here. This class is
/// the pure decision (host-testable); the acting — finding
/// the process, dumping its /proc threads, killing it,
/// publishing the failure — is the native side's
/// `psiphonExternalWatchdog` channel call.
///
/// The decision is deliberately narrow. It fires only when
/// the attempt is provably stuck at the start frontier:
///  - the start call itself is still inside the library
///    (the state's startReturned flag false) at [deadline] —
///    a healthy start returns in well under a second and
///    its establishment then works through ladder budgets
///    that legitimately run for minutes, so a returned
///    start NEVER fires this, however slow the connect; or
///  - the service never even reported running within
///    [neverStartedWindow] (dead at birth, or exited by
///    the warm-up probe before publishing anything).
/// It fires at most once per attempt, and never once the
/// attempt has resolved — connected, or failed (the wedge
/// flag published, by either process).
///
/// Build 2090 adds a second, RECORD-ONLY decision beside
/// the firing one: [evaluateEstablishment]. The 2089
/// retargeting left establishment unwatched — the spawn
/// returns in milliseconds and `running` publishes at
/// once, so neither firing branch can ever describe a
/// start that spawns fine and then never tunnels (the
/// 2089 device failure). The establishment branch fires
/// once per attempt when the service is running, the
/// start call has returned, and no tunnel exists past
/// [establishmentEvidenceBound]; the caller answers it by
/// dumping the sidecar's log tail into crash.log. It
/// never kills, never publishes, never touches the
/// firing decision — evidence only, because a slow
/// establishment is legitimate and the service's own
/// deadlines own the teardown.
class PsiphonWatchdog {
  /// How long a start call may stay inside the library
  /// before the attempt is declared wedged from outside.
  static const Duration deadline = Duration(seconds: 25);

  /// How long the service gets to report running at all.
  static const Duration neverStartedWindow = Duration(seconds: 8);

  /// Build 2090: how long a returned, running start may
  /// sit without a tunnel before its evidence is dumped
  /// (record-only; see the class doc).
  static const Duration establishmentEvidenceBound =
      Duration(seconds: 60);

  DateTime? _armedAt;
  bool _fired = false;
  bool _everRunning = false;
  bool _establishmentDumped = false;

  /// When the current attempt was armed (null = disarmed).
  DateTime? get armedAt => _armedAt;

  /// Whether a deadline is currently ticking.
  bool get armed => _armedAt != null;

  /// Whether this attempt's firing already happened.
  bool get fired => _fired;

  /// Starts the deadline for a new attempt.
  void arm(DateTime now) {
    _armedAt = now;
    _fired = false;
    _everRunning = false;
    _establishmentDumped = false;
  }

  /// Ends the deadline without firing (the attempt resolved,
  /// or the user stopped it).
  void disarm() {
    _armedAt = null;
  }

  /// Feeds one state sample; returns true exactly once —
  /// at the moment the attempt must be acted on. The
  /// caller then invokes the native firing and re-reads
  /// the state (the firing publishes the wedge, which the
  /// connect path already fails fast on).
  bool evaluate({
    required DateTime now,
    required bool running,
    required bool connected,
    required bool wedged,
    required bool startReturned,
  }) {
    final armedAt = _armedAt;
    if (armedAt == null || _fired) return false;
    if (running) _everRunning = true;
    if (connected || wedged) return false;
    final age = now.difference(armedAt);
    if (!startReturned && age >= deadline) {
      _fired = true;
      return true;
    }
    if (!_everRunning && age >= neverStartedWindow) {
      _fired = true;
      return true;
    }
    return false;
  }

  /// Build 2090: the record-only establishment decision
  /// (see the class doc). Returns true exactly once per
  /// attempt — when the attempt is running, its start
  /// call has returned, it is neither connected nor
  /// wedged, and [establishmentEvidenceBound] has passed
  /// without a tunnel. The caller dumps the sidecar's
  /// log tail to crash.log; nothing else happens.
  bool evaluateEstablishment({
    required DateTime now,
    required bool running,
    required bool connected,
    required bool wedged,
    required bool startReturned,
  }) {
    final armedAt = _armedAt;
    if (armedAt == null || _establishmentDumped) return false;
    if (!running || connected || wedged || !startReturned) {
      return false;
    }
    if (now.difference(armedAt) >= establishmentEvidenceBound) {
      _establishmentDumped = true;
      return true;
    }
    return false;
  }
}
