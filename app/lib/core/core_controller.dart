import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_api.dart';
import 'poll_policy.dart';
import 'remote_flags.dart';
import 'models.dart';
import 'ports.dart';
import 'tun_service.dart';

/// Connects to the core, polls its status and accounts, and runs the
/// user's actions. It holds no VPN logic: every decision is the core's.
class CoreController extends ChangeNotifier {
  CoreController(
    this._connect, {
    this.pollInterval = const Duration(seconds: 2),
    this.moveStoppedCore,
    this.retryStoppedCore,
    this.turnOn,
    this.tunService,
  });

  /// Installs and removes the TUN mode's service (Windows); null elsewhere.
  final TunService? tunService;

  /// The TUN service is being installed or removed: Windows may be showing
  /// its administrator prompt.
  bool installingTun = false;
  bool removingTun = false;

  /// Turns the proxy on or off where the app has a switch for the whole
  /// proxy (Android, which has no system proxy); null elsewhere.
  final Future<void> Function(bool on)? turnOn;

  /// Moves a core that could not start to another API port (it edits the
  /// core's config.json, since the core is not there to ask); null where
  /// the app does not start the core.
  final Future<void> Function(int port)? moveStoppedCore;

  /// Lets a core that stopped right after starting start again.
  final Future<void> Function()? retryStoppedCore;

  /// Opens a client; it throws [CoreUnavailable] while there is no core.
  final Future<CoreApi> Function() _connect;
  final Duration pollInterval;

  CoreApi? _api;
  Timer? _timer;

  /// Poll cadence state (build 2050, audit B-H2): until now
  /// this poller ticked every 2 s from app launch, forever —
  /// Mozilla off, another engine on screen, app backgrounded.
  /// Now: 2 s only while foregrounded AND the Mozilla engine
  /// is on stage (the shell says so via [setEngineFocus]) or
  /// the proxy is on; a 30 s heartbeat otherwise. A poll that
  /// changes nothing also skips its notifyListeners, so an
  /// idle app stops rebuilding the shell at poll rate.
  bool _foreground = true;
  bool _engineFocus = false;
  String _lastPollSignature = '';

  /// A quick retry while the core is starting, so the app shows it as soon
  /// as its API answers rather than at the next poll.
  Timer? _quick;
  bool _polling = false;
  int _tick = 0;

  /// Failed reads in a row while the core answered before; the first one
  /// is retried at once instead of showing the core as lost.
  int _failures = 0;

  /// Consecutive non-auth poll errors (build 2116): at
  /// three the core is re-found (see refresh).
  int _apiErrors = 0;

  /// The last pass expiry the poll observed (build 2116):
  /// a change while running is a renewal boundary.
  int _passExpiresAt = 0;

  /// Set by the shell: receives the connect-journal lines
  /// for Mozilla pass boundaries (build 2116, audit
  /// AB-04), which the Diagnostics export carries.
  void Function(String line)? journalLine;

  /// The newest core log entry already mirrored into the
  /// journal (build 2119, audit F-01). Reset when the
  /// core is lost: a re-found core may be a new process
  /// whose entry ids restart at 1.
  int _mirroredCoreLogId = 0;

  /// Whether a core log line belongs in the diagnostics
  /// journal (build 2119): warnings and errors always;
  /// at INFO only the renewal and upstream-failure
  /// journal lines. DEBUG and routine INFO stay on the
  /// Mozilla LogsPage — the journal is the owner's
  /// evidence file, not a second log viewer.
  static bool coreLogLineIsJournalWorthy(LogEntry e) {
    if (e.level == 'WARN' || e.level == 'ERROR') return true;
    if (e.level != 'INFO') return false;
    return e.message.contains('proxy pass renewal') ||
        e.message.contains('upstream failure');
  }

  /// Build 2119 (audit F-01): mirror the core's
  /// journal-worthy log lines into the diagnostics
  /// journal through [journalLine]. Up to 2118 the Go
  /// renewal/failure lines lived only on the Mozilla
  /// LogsPage, while the Diagnostics export the owner
  /// pastes carried only the Dart boundary lines — no
  /// single export held both halves of a degradation.
  /// The core's hub keeps 2000 entries, so a poll paused
  /// while the app was backgrounded still catches up;
  /// the first fetch of a process mirrors only the
  /// newest 100 worthy lines (40 up to build 2122), so a
  /// restart does not flood the journal with the core's
  /// buffered history.
  /// Best-effort: a logs read failure never breaks the
  /// poll.
  Future<void> _mirrorCoreLog(CoreApi api) async {
    try {
      final entries = await api.logs(_mirroredCoreLogId);
      if (entries.isEmpty) return;
      final firstFetch = _mirroredCoreLogId == 0;
      var worthy = entries.where(coreLogLineIsJournalWorthy).toList();
      // Build 2123 (audit F-01, gap 2): the first-fetch cap
      // widens from 40 to 100 worthy lines. A core re-found
      // after a loss restarts the mirror at id 0, and a
      // dying core's final WARN/ERROR span can exceed 40 —
      // the cap still bounds a restart flood (the journal
      // ring holds 300), it just no longer cuts the exact
      // span the evidence path exists to keep.
      if (firstFetch && worthy.length > 100) {
        worthy = worthy.sublist(worthy.length - 100);
      }
      for (final e in entries) {
        if (e.id > _mirroredCoreLogId) _mirroredCoreLogId = e.id;
      }
      for (final e in worthy) {
        journalLine?.call('core log [${e.level}] ${e.message}');
      }
    } catch (_) {
      // The journal is evidence, never a reason to fail.
    }
  }

  /// Build 2123 (audit F-01, gap 2): mirror through
  /// whatever API handle the controller currently holds.
  /// The refresh() failure branches call this BEFORE any
  /// _lost(): up to 2122 the mirror ran only after a
  /// successful status() read, so the cycles in which the
  /// core was actually failing — a non-auth API error, an
  /// unreachable core — never mirrored that cycle's core
  /// lines, and the final lines before a loss were the
  /// ones most likely to be skipped.
  Future<void> _mirrorCoreLogIfAny() async {
    final api = _api;
    if (api != null) await _mirrorCoreLog(api);
  }

  bool _disposed = false;

  CoreStatus? status;
  AccountList? accounts;

  /// Why the core cannot be reached; null while it answers.
  CoreUnavailable? unavailable;

  /// The system proxy mode, or the proxy's power, is being changed.
  bool switchingProxy = false;
  bool testing = false;

  /// The latest connection test, ours or the core's automatic one.
  ConnectionTest? get lastTest => _test ?? status?.lastTest;
  ConnectionTest? _test;

  /// Build 2116 (audit AB-02): the proxy is running but no
  /// test has confirmed it, and the session is past its
  /// confirmation window — the first retest cycle (the
  /// 5 s first retest plus a test's own runtime, with
  /// margin). The shell renders "Connected — not
  /// answering" for this state: up to 2115 the bar showed
  /// a bare "Connected" from the phase alone, so a session
  /// that rotted after connecting looked healthy forever.
  bool get runningUnconfirmed {
    final s = status;
    if (s == null || s.state.phase != Phase.running) return false;
    if (s.noNetwork || s.confirmedBy(lastTest)) return false;
    final started = s.proxy?.startedAt;
    if (started == null) return false;
    return DateTime.now().difference(started) > const Duration(seconds: 20);
  }

  /// When the phone may test the connection again (_retestUnconfirmed).
  DateTime? _retestAt;

  /// The wait before the next unconfirmed test: it doubles from 5 seconds
  /// to a minute while tests keep failing, so an unreachable Mozilla is not
  /// asked for a pass every few seconds.
  Duration _retestDelay = _retestFirst;
  static const _retestFirst = Duration(seconds: 5);
  static const _retestMax = Duration(minutes: 1);

  /// What the last poll showed of the connection: a new one (the proxy
  /// started again, the network changed, the phase came back to running)
  /// is tested soon again, not after an old backoff.
  String? _seenConnection;

  /// The last log entry the logs page had read when it was cleared, and
  /// when: the page starts after that entry and leaves out anything logged
  /// before the moment, for as long as the app runs.
  int logsClearedAfter = 0;
  DateTime? logsClearedAt;

  /// The last connection the Connections tab listed when it was cleared:
  /// it lists only later ones, for as long as the app runs.
  int connectionsClearedAfter = 0;

  /// Accounts with an action in progress.
  final Set<String> busyAccounts = {};

  CoreApi? get api => _api;
  bool get connected => _api != null && unavailable == null;

  void start() {
    _timer ??= Timer.periodic(_currentPeriod, (_) => refresh());
    refresh();
  }

  /// The live cadence: fast only while foregrounded and the
  /// Mozilla engine is focused or actually on.
  Duration get _currentPeriod => corePollPeriod(
    foreground: _foreground,
    active:
        _engineFocus ||
        (status?.state.phase == Phase.running) ||
        switchingProxy ||
        testing,
  );

  void _restartTimer() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = Timer.periodic(_currentPeriod, (_) => refresh());
  }

  /// The shell's lifecycle feed (build 2050).
  void setForeground(bool fg) {
    if (fg == _foreground) return;
    _foreground = fg;
    _restartTimer();
    // Coming back to the foreground refreshes at once — the
    // user must never wait out a heartbeat to see true state.
    if (fg) refresh();
  }

  /// The shell's mode feed (build 2050): Mozilla is the
  /// engine on stage.
  void setEngineFocus(bool focus) {
    if (focus == _engineFocus) return;
    _engineFocus = focus;
    _restartTimer();
  }

  /// Reads the status, and the accounts every third tick (the core reads
  /// them from disk). [accountsToo] reads them now.
  Future<void> refresh({bool accountsToo = false}) async {
    if (_polling || _disposed) return;
    _polling = true;
    try {
      final api = _api ??= await _connect();
      // Flags the app does not carry come from this core.
      RemoteFlags.use(api);
      final next = await api.status();
      final readAccounts = accountsToo || accounts == null || _tick % 3 == 0;
      // Build 2125 (audit A25-21 / P-32): the core-log
      // mirror drops to the accounts cadence (every third
      // tick). Up to 2124 every refresh did TWO sequential
      // loopback round trips — status, then logs — for the
      // whole session. The mirror is cursor-based, so a
      // slower cadence loses no lines (the next mirror
      // reads everything since the cursor); only the
      // mirroring latency grows, and the failure branches
      // below still salvage-mirror unconditionally.
      final mirrorLogs = _tick % 3 == 0;
      _tick++;
      status = next;
      // Build 2116 (audit AB-04): a pass boundary (the
      // session's start, a renewal landing) is journaled
      // with the session age and the new countdown.
      final boundary = next.passBoundaryLine(_passExpiresAt, DateTime.now());
      if (next.passExpiresAt > 0) _passExpiresAt = next.passExpiresAt;
      if (boundary != null) journalLine?.call(boundary);
      // Build 2119 (audit F-01): the core's own journal
      // lines join the same export (see _mirrorCoreLog).
      // Build 2125 (A25-21): at the third-tick cadence —
      // see mirrorLogs above.
      if (mirrorLogs) await _mirrorCoreLog(api);
      // The phone's VPN while on; the computer's proxy, which always runs,
      // in either mode.
      if (turnOn != null || next.systemProxySupported) {
        _retestUnconfirmed(next);
      }
      if (_test != null &&
          next.lastTest?.at != null &&
          _test!.at != null &&
          next.lastTest!.at!.isAfter(_test!.at!)) {
        _test = null;
      }
      if (readAccounts) accounts = await api.accounts();
      unavailable = null;
      _failures = 0;
      _apiErrors = 0;
    } on CoreUnavailable catch (e) {
      // Build 2123 (audit F-01, gap 2): salvage this
      // cycle's core lines before any loss handling — the
      // logs endpoint may still answer on a half-dead
      // connection, and _lost() closes the handle.
      await _mirrorCoreLogIfAny();
      // One failed read while the core answered is tried again at once:
      // Android closes the app's open connections, the one to the core
      // included, when the phone's network goes away.
      if (unavailable == null && status != null && _failures == 0) {
        _failures++;
      } else {
        _lost(e);
      }
    } on CoreApiException catch (e) {
      // Build 2123 (audit F-01, gap 2): same salvage on
      // the API-error paths — a core failing its status
      // read is exactly the core whose lines matter.
      await _mirrorCoreLogIfAny();
      // 401/403: the token changed (another core took the address); find
      // the core again.
      if (e.statusCode == 401 || e.statusCode == 403) {
        _lost(CoreUnavailable(CoreProblem.refused, e.message));
      } else {
        // Build 2116 (audit AB-02): a non-auth API error
        // used to be swallowed whole — the status froze at
        // its last good sample and the shell kept showing
        // a healthy session over a core that was failing
        // every poll. Three in a row are not passing: the
        // core is re-found, like an auth failure.
        _apiErrors++;
        if (_apiErrors >= 3) {
          _apiErrors = 0;
          _lost(CoreUnavailable(CoreProblem.notAnswering, e.message));
        }
      }
    } catch (e) {
      // Build 2123 (audit F-01, gap 2): salvage this
      // cycle's core lines here too.
      await _mirrorCoreLogIfAny();
      // Build 2116 (audit AB-02): an unexpected poll error
      // (a decode failure, a platform throw) takes the
      // same road — counted, and the core is re-found at
      // three — instead of escaping the poll timer and
      // freezing the status the same way.
      _apiErrors++;
      if (_apiErrors >= 3) {
        _apiErrors = 0;
        _lost(CoreUnavailable(CoreProblem.notAnswering, '$e'));
      }
    } finally {
      _polling = false;
      if (!_disposed) {
        // Build 2050 (audit B-H2): a poll whose outcome is
        // identical to the last one does not rebuild the
        // shell. Anything the user can see changing — phase,
        // exit, traffic, a fresh test, accounts, an error —
        // changes the signature and notifies as before.
        final signature = _pollSignature();
        if (signature != _lastPollSignature) {
          _lastPollSignature = signature;
          notifyListeners();
        }
        if ((unavailable?.problem == CoreProblem.starting || _failures > 0) &&
            _timer != null) {
          _quick?.cancel();
          _quick = Timer(const Duration(milliseconds: 250), refresh);
        }
      }
    }
  }

  /// What a poll's outcome looks like to the UI, as one
  /// comparable string (build 2050).
  String _pollSignature() {
    final st = status;
    return [
      st?.state.phase.name ?? 'none',
      st?.state.message ?? '',
      st?.exit?.ipv4 ?? '',
      st?.exitMismatch != null,
      st?.activeAccount?.id ?? '',
      st?.activeAccount?.status ?? '',
      st?.traffic?.up ?? -1,
      st?.traffic?.down ?? -1,
      st?.lastTest?.at?.millisecondsSinceEpoch ?? -1,
      unavailable?.problem.name ?? '',
      accounts?.accounts.length ?? -1,
      // Account state the Accounts tab renders (status/reason
      // flips, usage movement) rides the signature too.
      if (accounts != null)
        for (final a in accounts!.accounts)
          '${a.id}:${a.status}:${a.usedPercent}',
    ].join('|');
  }

  void _lost(CoreUnavailable problem) {
    _failures = 0;
    _mirroredCoreLogId = 0;
    _api?.close();
    _api = null;
    unavailable = problem;
  }

  Future<void> runTest() => _act(() async {
    testing = true;
    notifyListeners();
    try {
      _test = await _require().test();
    } finally {
      testing = false;
      // Any test, the user's too, puts the next unconfirmed one off by the
      // current step, counted from its end: a slow failing test is not
      // followed by another at once.
      _retestAt = DateTime.now().add(
        _retestAt == null ? _retestFirst : _retestDelay ~/ 2,
      );
    }
  });

  Future<void> restartProxy() => _act(() => _require().restartProxy());

  /// Sets the system proxy mode: set (Windows uses the VPN) or clear.
  Future<void> setSystemProxy(String mode) => _act(() async {
    switchingProxy = true;
    notifyListeners();
    try {
      await _require().setSystemProxy(mode);
    } finally {
      switchingProxy = false;
    }
  });

  /// Installs the TUN service, with the system's administrator prompt;
  /// [prompt] is its reason on macOS.
  Future<TunServiceResult> installTunService({String? prompt}) =>
      _tunService(() => tunService!.install(prompt: prompt), installing: true);

  /// Removes the TUN service; [prompt] is the reason macOS' administrator
  /// prompt shows when the service does not run.
  Future<TunServiceResult> removeTunService({String? prompt}) => _tunService(
    () => tunService!.uninstall(prompt: prompt),
    installing: false,
  );

  Future<TunServiceResult> _tunService(
    Future<TunServiceResult> Function() run, {
    required bool installing,
  }) async {
    if (tunService == null) {
      return const TunServiceFailed('the TUN mode is not available here');
    }
    if (installing) {
      installingTun = true;
    } else {
      removingTun = true;
    }
    notifyListeners();
    try {
      return await run();
    } finally {
      installingTun = removingTun = false;
      if (!_disposed) {
        notifyListeners();
        unawaited(refresh());
      }
    }
  }

  /// Turns the proxy on or off ([turnOn] on the phone, the core's API on the
  /// computer) and waits, briefly, until the core reports it.
  int _setOnGen = 0;

  Future<void> setOn(bool on) => _act(() async {
    // Build 2096 (post-2095 audit L25): a generation
    // token — overlapping setOn calls used to clear each
    // other's switching flag, so the UI read "not
    // switching" while a switch was still in flight.
    final gen = ++_setOnGen;
    switchingProxy = true;
    notifyListeners();
    try {
      await (turnOn ?? _require().setPower)(on);
      final api = _require();
      for (var i = 0; i < 20; i++) {
        final next = await api.status();
        // Build 2097 (post-2096 audit C-L2): a superseded
        // setOn stops writing status — its poll used to keep
        // overwriting the newer call's state for up to ~3 s
        // after the user (or an arbitration stop) had
        // already reversed the toggle.
        if (gen != _setOnGen) return;
        status = next;
        if ((next.state.phase == Phase.off) != on) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    } finally {
      if (gen == _setOnGen) switchingProxy = false;
    }
  });

  /// The user is looking (the app came to the front): the core tries the
  /// next connection at once instead of waiting after a failure. At most
  /// every few seconds.
  Future<void> retryNow() async {
    final now = DateTime.now();
    if (_retriedAt != null && now.difference(_retriedAt!) < _retryGap) return;
    _retriedAt = now;
    try {
      await _api?.retry();
    } on Exception {
      // Not answering: the next poll says so.
    }
  }

  DateTime? _retriedAt;
  static const _retryGap = Duration(seconds: 5);

  /// Turns the proxy on by itself, for an app started with the computer.
  Future<void> autoConnect() => _act(() => _require().autoConnect());

  /// Starts downloading [version] of the app (the Windows app's core).
  Future<void> downloadUpdate(String version) =>
      _act(() => _require().downloadUpdate(version));

  /// Installs the downloaded [version]; the app ([pid]) quits once this
  /// returns, and starts again with [args].
  Future<void> installUpdate(String version, int pid, List<String> args) =>
      _act(() => _require().installUpdate(version, pid, args));

  /// The core's config.json as raw JSON.
  Future<Map<String, Object?>> settings() => _require().settings();

  /// Changes the core's config: [edit] changes the raw JSON in place.
  Future<void> editSettings(void Function(Map<String, Object?> config) edit) =>
      _act(() async {
        final api = _require();
        final config = await api.settings();
        edit(config);
        await api.saveSettings(config);
      });

  Future<void> openFolder() => _act(() => _require().openFolder());

  /// A fresh sign-in link to the web dashboard.
  Future<Uri> dashboardLink() => _require().loginLink();

  /// Tries the core again at once, also one that stopped right after
  /// starting.
  Future<void> retry() async {
    await retryStoppedCore?.call();
    await refresh(accountsToo: true);
  }

  /// Moves the core's API to [port]: through the core while it runs, or in
  /// its config.json when it could not start.
  Future<void> setAppPort(int port) async {
    if (_api != null) {
      await editSettings((config) {
        final dashboard = config['dashboard'];
        if (dashboard is Map<String, Object?>) {
          dashboard['listen'] = withPort(
            dashboard['listen'] as String? ?? '',
            port,
          );
        }
      });
      return;
    }
    await moveStoppedCore?.call(port);
    await refresh(accountsToo: true);
  }

  /// Moves the proxy (SOCKS5 and HTTP) to [port]; the core restarts it.
  Future<void> setProxyPort(int port) => editSettings((config) {
    final proxy = config['proxy'];
    if (proxy is Map<String, Object?>) {
      proxy['listen'] = withPort(proxy['listen'] as String? ?? '', port);
    }
  });

  /// Runs a request for a page (servers, logs, routing tools) with the
  /// connection's error handling; errors reach the caller.
  Future<T> call<T>(Future<T> Function(CoreApi api) request) async {
    try {
      return await request(_require());
    } on CoreUnavailable catch (e) {
      _lost(e);
      if (!_disposed) notifyListeners();
      rethrow;
    }
  }

  /// Chooses the location (a country code, `fastest`, or empty for the
  /// recommended one); the proxy restarts on it.
  Future<void> setLocation(String country) =>
      _act(() => _require().setLocation(country));

  /// Stops polling, before the app quits.
  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> activate(Account a) =>
      _account(a.id, () => _require().activateAccount(a.id));

  Future<void> setEnabled(Account a, bool enabled) =>
      _account(a.id, () => _require().setAccountEnabled(a.id, enabled));

  Future<void> refreshQuota(Account a) =>
      _account(a.id, () => _require().refreshAccount(a.id));

  Future<void> remove(Account a) =>
      _account(a.id, () => _require().removeAccount(a.id));

  /// Moves [a] by [delta] places in the priority order.
  Future<void> move(Account a, int delta) {
    final list = [...?accounts?.accounts];
    final from = list.indexWhere((x) => x.id == a.id);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= list.length) return Future.value();
    list.insert(to, list.removeAt(from));
    return _act(() => _require().setAccountOrder([for (final x in list) x.id]));
  }

  Future<void> _account(String id, Future<void> Function() action) async {
    busyAccounts.add(id);
    notifyListeners();
    try {
      await _act(action);
    } finally {
      busyAccounts.remove(id);
      if (!_disposed) notifyListeners();
    }
  }

  /// Runs [action], then reads the status and accounts again. Errors reach
  /// the caller, which shows them.
  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
    } on CoreUnavailable catch (e) {
      _lost(e);
      rethrow;
    } finally {
      if (!_disposed) {
        notifyListeners();
        unawaited(refresh(accountsToo: true));
      }
    }
  }

  /// The home page shows "Connecting" until a test confirms the connection
  /// (CoreStatus.confirmedBy); until then it tests again after 5 seconds,
  /// then less often (up to once a minute) while tests keep failing.
  /// Build 2125 (audit A25-12 / P-13): retests scheduled
  /// for the current unconfirmed connection, and the
  /// connection an h1 demotion already fired for.
  int _retestFailures = 0;
  String? _h1DemotedConnection;

  void _retestUnconfirmed(CoreStatus s) {
    final connection = s.state.phase == Phase.running
        ? '${s.proxy?.startedAt}|${s.networkChangedAt}'
        : null;
    if (connection != _seenConnection) {
      _seenConnection = connection;
      _retestAt = null;
      _retestDelay = _retestFirst;
      _retestFailures = 0;
    }
    if (s.state.phase != Phase.running || testing || switchingProxy) return;
    if (s.noNetwork) return;
    // The core's auto-connect tests by itself.
    if (s.autoConnecting) return;
    if (s.confirmedBy(lastTest)) {
      _retestAt = null;
      _retestDelay = _retestFirst;
      _retestFailures = 0;
      return;
    }
    final now = DateTime.now();
    if (_retestAt != null && now.isBefore(_retestAt!)) return;
    _retestAt = now.add(_retestDelay);
    final doubled = _retestDelay * 2;
    _retestDelay = doubled > _retestMax ? _retestMax : doubled;
    _retestFailures++;
    // Build 2125 (audit A25-12 / P-13): the h1 demotion.
    // h1 is an opt-in transport with a static caveat; up
    // to 2124 a session whose h1 upstream died mid-flight
    // was retested forever on the same dead transport —
    // nothing rebuilt it, retested an alternate, or
    // demoted h1. After four failed retest cycles on an
    // h1 session (the backoff has by then stretched past
    // a minute of continuous failure), the stored
    // transport is demoted to h2 — the value the 2024 pin
    // proved — and the proxy restarts on it, once per
    // connection. A confirmed test at any point resets
    // the count, so a healthy h1 session is never
    // touched; other transports are never demoted.
    if (_retestFailures >= 4 &&
        s.proxy?.transport == 'h1' &&
        connection != null &&
        _h1DemotedConnection != connection) {
      // Build 2126 (audit A26-13): the marker is NOT set
      // here — _demoteH1 consumes it only on success, so
      // a failed demotion is retried on a later cycle
      // instead of never again for this connection.
      unawaited(_demoteH1(connection));
    }
    unawaited(runTest().catchError((Object _) {}));
  }

  /// The A25-12 demotion itself: h1 → h2 in the core's
  /// config, then a proxy restart so the session rebuilds
  /// on the new transport. Best-effort — a failure leaves
  /// the session and the retest backoff exactly as they
  /// were. Build 2126 (audit A26-13): the
  /// once-per-connection marker is consumed only on
  /// success (below), so a failed attempt is retried by
  /// a later retest cycle rather than never.
  Future<void> _demoteH1(String connection) async {
    try {
      await editSettings((config) {
        final proxy = config['proxy'];
        if (proxy is Map<String, Object?> && proxy['transport'] == 'h1') {
          proxy['transport'] = 'h2';
        }
      });
      await restartProxy();
      _h1DemotedConnection = connection;
      _retestAt = null;
      _retestDelay = _retestFirst;
      _retestFailures = 0;
    } catch (_) {
      // The session keeps its transport; nothing here may
      // take a limping session down with it.
    }
  }

  CoreApi _require() {
    final api = _api;
    if (api == null) {
      throw unavailable ?? const CoreUnavailable(CoreProblem.notAnswering);
    }
    return api;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _quick?.cancel();
    _api?.close();
    super.dispose();
  }
}
