import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/poll_policy.dart';
import '../aether/aether_platform.dart';
import '../core/android_core.dart';
import 'lantern_platform.dart';

/// Build 2052 (diagnosis Causes 1–2): ralysnd's Lantern budgets,
/// ported verbatim. A kept server list listens in seconds; a first
/// list gets 20 s direct, then the WARP leg on the running core's
/// stdin, 240 s total before giving up — one process throughout,
/// never killed while its first fetch is still in flight.
const lanternWarmBudget = Duration(seconds: 20);
const lanternColdDirectBudget = Duration(seconds: 20);
const lanternColdBudget = Duration(seconds: 240);

/// The give-up words for a cold start that never got its first
/// server list (ralysnd's wording, English — the app is
/// English-only). The list is needed only once: once it lands it
/// is kept, and later connects take seconds.
String lanternGiveUpMessage({required bool warm, required bool viaWarp}) {
  if (warm) {
    return 'Lantern did not open its local proxy in 20 s even with a kept server list. Try again, or tap "Fresh server list".';
  }
  if (viaWarp) {
    return 'Lantern did not get its server list in four minutes, not even through WARP. Try again a little later. It is needed only once: the list is kept, and later connects take seconds.';
  }
  return 'Lantern has to get its server list from its own service the first time, and your internet did not reach it in four minutes. Try again a little later. It is needed only once: the list is kept, and later connects take seconds.';
}

/// Owns the Lantern engine's state for the UI, mirroring
/// PsiphonController: fetches the platform state, polls while
/// the engine runs, derives the per-second rates, and keeps the
/// last failure verbatim so the UI can show it loudly (the
/// core's stdout/stderr tails ride along in the state).
class LanternController extends ChangeNotifier {
  LanternState _state = const LanternState();

  LanternState get state => _state;

  /// The captured platform error of the last failed start, when
  /// the state itself carries none.
  String? _lastError;
  String? get lastError => _state.error ?? _lastError;

  Future<void> Function()? stopOtherEngine;

  /// Set by the shell: the global tunnel MTU (build 2038, queue 2f) —
  /// the Xray settings value, read at connect time. Defaults to 1500
  /// (the unchanged behaviour) when unwired.
  int Function() tunnelMtu = () => 1500;

  /// Set by the shell: the tunnel's DNS (build 2057, audit §6
  /// engine low) — the Xray settings localDns, read at connect
  /// time. The old code hardcoded '1.1.1.1' in the service while
  /// Settings offered a DNS the Lantern tunnel silently ignored.
  /// Defaults to 1.1.1.1 (the unchanged behaviour) when unwired.
  String Function() localDns = () => '1.1.1.1';

  Timer? _poller;
  bool _busy = false;
  bool _startRequested = false;

  bool get connecting => _busy;

  // The last poll's counters, for the per-second rates.
  int _lastUp = 0;
  int _lastDown = 0;
  DateTime? _lastTick;
  int upRate = 0;
  int downRate = 0;

  Future<void> load() async {
    _state = await LanternPlatform.state();
    _syncPoller();
    notifyListeners();
  }

  Future<void> refresh() async {
    final before = _state;
    _state = await LanternPlatform.state();
    _deriveRates(before);
    _syncPoller();
    notifyListeners();
  }

  /// App-foreground state for the poll cadence (build 2050).
  bool _foreground = true;

  /// The shell's lifecycle feed (build 2050): live 2 s poll
  /// only while foregrounded; a 30 s heartbeat otherwise.
  void setForeground(bool fg) {
    if (fg == _foreground) return;
    _foreground = fg;
    if (_poller != null) {
      _poller!.cancel();
      _poller = null;
      _syncPoller();
    }
  }

  void _syncPoller() {
    final want = _state.running || _state.coreRunning || _startRequested;
    if (want && _poller == null) {
      _poller = Timer.periodic(
        enginePollPeriod(foreground: _foreground),
        (_) => refresh(),
      );
    } else if (!want && _poller != null) {
      _poller!.cancel();
      _poller = null;
      upRate = 0;
      downRate = 0;
    }
  }

  void _deriveRates(LanternState before) {
    final now = DateTime.now();
    final last = _lastTick;
    if (!before.running || !_state.running || last == null) {
      _lastUp = _state.upBytes;
      _lastDown = _state.downBytes;
      _lastTick = now;
      upRate = 0;
      downRate = 0;
      return;
    }
    final dt = now.difference(last).inMilliseconds / 1000.0;
    if (dt > 0) {
      upRate = ((_state.upBytes - _lastUp) / dt).round().clamp(0, 1 << 62);
      downRate = ((_state.downBytes - _lastDown) / dt).round().clamp(
        0,
        1 << 62,
      );
    }
    _lastUp = _state.upBytes;
    _lastDown = _state.downBytes;
    _lastTick = now;
  }

  /// The core's -smart flag (build 2032): the core's own smart
  /// server choice. Session-scoped; off by default, as in
  /// ralysnd's conservative start.
  bool smartRouting = false;

  void setSmartRouting(bool value) {
    smartRouting = value;
    notifyListeners();
  }

  /// True while the current start is the WARP-leg bootstrap
  /// retry (the page can say the control plane rides WARP).
  bool viaWarpLeg = false;

  /// Connects: asks the shell to stop the other engines first,
  /// then waits for the TUN to come up.
  ///
  /// Build 2052 (diagnosis Causes 1–3): the warm/cold split comes
  /// first — a kept server list (now really parsed, Cause 3)
  /// means the core listens in seconds; without one the first
  /// fetch is the slow step, so the core gets ralysnd's ladder:
  /// 20 s direct, then the control plane rerouted through the
  /// WARP leg ON THE RUNNING CORE's stdin (`via`, Cause 2),
  /// 240 s total, one process throughout. The old code killed
  /// the core at 45–60 s and restarted it with an unproven
  /// start flag — every cold connect died the same way, forever.
  /// The data path itself is proven in Kotlin before the TUN
  /// goes up (Cause 5), so "running" here means traffic really
  /// flows.
  Future<void> connect() async {
    _busy = true;
    _lastError = null;
    _startRequested = true;
    viaWarpLeg = false;
    notifyListeners();
    try {
      await stopOtherEngine?.call();
      final warm = (await LanternPlatform.state()).hasKeptConfig;
      await _startAndAwait(warm: warm);
    } finally {
      _busy = false;
      _startRequested = false;
      await refresh();
    }
  }

  Future<void> _startAndAwait({required bool warm}) async {
    await LanternPlatform.setOn(
      on: true,
      smart: smartRouting,
      mtu: tunnelMtu(),
      dns: localDns(),
    );
    final started = DateTime.now();
    final total = warm ? lanternWarmBudget : lanternColdBudget;
    var legTried = false;
    var legUp = false;
    try {
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await refresh();
        if (_state.running) return;
        if (_state.error != null && !_state.coreRunning) {
          throw StateError(_state.error!);
        }
        final elapsed = DateTime.now().difference(started);
        if (!warm &&
            !legTried &&
            elapsed >= lanternColdDirectBudget &&
            _state.coreRunning) {
          // One core, one process: the leg rides the running
          // core's stdin. Only the control plane goes through
          // WARP, and only for this first list — Lantern's own
          // servers are dialled directly, then and every time
          // after.
          legTried = true;
          final leg = await _startWarpLeg();
          if (leg != null &&
              await LanternPlatform.via(AetherPlatform.cfwarpSocksPort)) {
            legUp = true;
            viaWarpLeg = true;
            notifyListeners();
          } else if (leg != null) {
            // The core would not take the reroute — the leg is
            // useless to it; take it down again at once.
            await AetherPlatform.stop('cfwarp');
          }
          // No leg at all: patience is the fallback — the core's
          // own fetch loop keeps retrying directly until the
          // 240 s budget ends, which ralysnd shows is often
          // enough on its own.
        }
        if (elapsed >= total) {
          throw StateError(
            lanternGiveUpMessage(warm: warm, viaWarp: legUp),
          );
        }
      }
    } finally {
      if (legUp) {
        // Back to direct before the leg goes down, like ralysnd:
        // later refreshes must not point at a dead port.
        await LanternPlatform.viaDirect();
        await AetherPlatform.stop('cfwarp');
        viaWarpLeg = false;
      }
    }
  }

  /// Brings the WARP leg up proxy-only for the bootstrap.
  /// Returns its trace (ip/loc) or null when the leg itself
  /// could not be raised — the caller then keeps waiting
  /// directly. Build 2052: this NO LONGER stops Lantern — the
  /// old code killed the core it was trying to help; the leg is
  /// raised beside the running core and handed to it over stdin.
  Future<Map<String, String>?> _startWarpLeg() async {
    try {
      var leg = await AetherPlatform.state('cfwarp');
      if (!leg.identity) {
        await AetherPlatform.ensureIdentity('cfwarp', 'wg');
        leg = await AetherPlatform.state('cfwarp');
        if (!leg.identity) return null;
      }
      final started = await AetherPlatform.start(
        'cfwarp',
        const AetherOptions(protocol: 'wg'),
      );
      if (!started) return null;
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        leg = await AetherPlatform.state('cfwarp');
        if (leg.connected) {
          return await AetherPlatform.trace('cfwarp');
        }
        if (leg.failed || !leg.running) return null;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> disconnect() async {
    _busy = true;
    notifyListeners();
    try {
      await LanternPlatform.stop();
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await refresh();
        if (!_state.running && !_state.coreRunning) return;
      }
    } finally {
      _busy = false;
      await refresh();
    }
  }

  /// Asks the running core to refetch its server list.
  Future<bool> fetchList() => LanternPlatform.fetchList();

  /// Forgets the cached server list (core stopped). Returns the
  /// number of cached files deleted, or -1 while running.
  Future<int> rotateList() async {
    final n = await LanternPlatform.rotateList();
    await refresh();
    return n;
  }

  /// The engine's on-disk logs (core stdout/stderr + bridge),
  /// readable even after a failed start — the loud-failure path.
  Future<String> readLogs() async {
    final filesDir = File(await AndroidCore.dataDir()).parent.path;
    final dir = Directory('$filesDir/lantern');
    final out = StringBuffer();
    for (final name in [
      'lantern-stdout.log',
      'lantern-stderr.log',
      'tunlink.log',
    ]) {
      final f = File('${dir.path}/$name');
      out.writeln('══ $name ══');
      if (await f.exists()) {
        final lines = await f.readAsLines();
        out.writeln(
          lines.skip(lines.length > 300 ? lines.length - 300 : 0).join('\n'),
        );
      } else {
        out.writeln('(none yet)');
      }
      out.writeln();
    }
    // Build 2070 (review §3.4): the crash.log section. The
    // recorder's file lives in filesDir itself, and this
    // service's start net has written to it since build 2068 —
    // but this viewer never showed it, so a recorded Lantern
    // start death was invisible on the very page the owner
    // pastes. Same 300-line tail shape as the sections above;
    // decoded leniently because a stack trace must never be
    // the thing that breaks the viewer.
    final crash = File('$filesDir/crash.log');
    out.writeln('══ crash.log ══');
    try {
      if (await crash.exists()) {
        final text = utf8.decode(
          await crash.readAsBytes(),
          allowMalformed: true,
        );
        final lines = text.split('\n');
        out.writeln(
          lines.skip(lines.length > 300 ? lines.length - 300 : 0).join('\n'),
        );
      } else {
        out.writeln('(none yet)');
      }
    } catch (e) {
      out.writeln('($e)');
    }
    out.writeln();
    return out.toString();
  }

  Future<void> clearLogs() async {
    final filesDir = File(await AndroidCore.dataDir()).parent.path;
    final dir = Directory('$filesDir/lantern');
    for (final name in [
      'lantern-stdout.log',
      'lantern-stderr.log',
      'tunlink.log',
    ]) {
      final f = File('${dir.path}/$name');
      if (await f.exists()) await f.delete();
    }
    // Build 2070 (review §3.4): Clear means all of it — the
    // crash.log section above is emptied too. The shared file
    // is truncated, not deleted (the recorder appends to it
    // from every engine; see the Xray controller's clearLogs).
    try {
      await File('$filesDir/crash.log').writeAsString('');
    } catch (_) {
      // Not there yet.
    }
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }
}
