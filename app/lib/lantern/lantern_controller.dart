import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../aether/aether_platform.dart';
import '../core/android_core.dart';
import '../xray/exit_info.dart';
import 'lantern_platform.dart';

/// Owns the Lantern engine's state for the UI, mirroring
/// PsiphonController: fetches the platform state, polls while
/// the engine runs, derives the per-second rates, and keeps the
/// last failure verbatim so the UI can show it loudly (the
/// core's stdout/stderr tails ride along in the state).
class LanternController extends ChangeNotifier {
  LanternState _state = const LanternState();

  LanternState get state => _state;

  /// Desktop-page compatibility (the 2.1.0 tree's pages read a
  /// fetched exit lookup): the 2032 core reports its exit inside
  /// the state itself, so the lookup is composed from it. Null
  /// until the core names an exit.
  ExitInfo? get exitInfo {
    if (_state.exitCode.isEmpty && _state.exitCountry.isEmpty) return null;
    return ExitInfo(
      ip: '',
      countryCode: _state.exitCode.toUpperCase(),
      countryEn: _state.exitCountry,
      city: _state.exitCity,
    );
  }

  /// The captured platform error of the last failed start, when
  /// the state itself carries none.
  String? _lastError;
  String? get lastError => _state.error ?? _lastError;

  Future<void> Function()? stopOtherEngine;

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

  void _syncPoller() {
    final want = _state.running || _state.coreRunning || _startRequested;
    if (want && _poller == null) {
      _poller = Timer.periodic(const Duration(seconds: 2), (_) => refresh());
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
  /// then waits for the TUN to come up. The core's own config
  /// fetch can take a while on a cold start, so the wait budget
  /// is generous; a dead core fails fast through its error.
  ///
  /// Build 2032 (ralysnd's bootstrap): when the direct start
  /// fails — the config service is name-filtered on some lines
  /// — the start is retried ONCE with the control plane fetched
  /// through the app's WARP leg (the Aether cfwarp slot run
  /// proxy-only), with the leg's exit identity announced so the
  /// config service places this phone where it is. The leg is
  /// stopped as soon as Lantern is up; the fetched list is kept
  /// by the core for next time.
  Future<void> connect() async {
    _busy = true;
    _lastError = null;
    _startRequested = true;
    viaWarpLeg = false;
    notifyListeners();
    try {
      await stopOtherEngine?.call();
      try {
        await _startAndAwait(fetchVia: 0, clientIp: '');
      } catch (directError) {
        final leg = await _startWarpLeg();
        if (leg == null) rethrow;
        viaWarpLeg = true;
        notifyListeners();
        try {
          await _startAndAwait(
            fetchVia: AetherPlatform.cfwarpSocksPort,
            clientIp:
                '${leg['ip'] ?? ''}|${(leg['loc'] ?? '').toUpperCase()}',
          );
        } finally {
          await AetherPlatform.stop('cfwarp');
          viaWarpLeg = false;
        }
      }
    } finally {
      _busy = false;
      _startRequested = false;
      await refresh();
    }
  }

  Future<void> _startAndAwait({
    required int fetchVia,
    required String clientIp,
  }) async {
    await LanternPlatform.setOn(
      on: true,
      smart: smartRouting,
      fetchVia: fetchVia,
      clientIp: clientIp,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await refresh();
      if (_state.running) return;
      if (_state.error != null && !_state.coreRunning) {
        throw StateError(_state.error!);
      }
    }
    throw StateError(_state.error ?? 'start-timeout');
  }

  /// Brings the WARP leg up proxy-only for the bootstrap.
  /// Returns its trace (ip/loc) or null when the leg itself
  /// could not be raised — the caller then keeps the direct
  /// start's own error.
  Future<Map<String, String>?> _startWarpLeg() async {
    try {
      // Make sure the failed direct attempt is fully down first.
      await LanternPlatform.stop();
      final stopDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(stopDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await refresh();
        if (!_state.running && !_state.coreRunning) break;
      }
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
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }
}
