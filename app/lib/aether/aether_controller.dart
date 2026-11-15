import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../atomic_json_store.dart';
import '../core/poll_policy.dart';
import '../core/android_core.dart';
import 'aether_platform.dart';

/// Owns one Aether slot's state for the UI (build 2032):
/// 'cfwarp' (the standalone WARP page) or 'masque' (the MASQUE /
/// WireGuard / WARP-in-WARP page). Mirrors LanternController's
/// shape: platform state polled while anything runs, failures
/// kept verbatim and shown loudly, and a connect flow that
/// follows ralysnd's rules exactly:
///
///  1. An identity first — registered by the binary's own
///     ladder when the slot has none (never silently replaced).
///  2. The engine runs to its own CONNECTED stage (its data
///     plane validated by the engine itself).
///  3. For WARP, a Cloudflare trace through the tunnel must say
///     warp=on — handshake alone never counts as connected.
///  4. Only then does the device TUN come up against the slot's
///     SOCKS, supervised by the VPN service.
class AetherController extends ChangeNotifier {
  AetherController(this.slot);

  /// 'cfwarp' | 'masque'
  final String slot;

  bool get isWarp => slot == 'cfwarp';
  String get displayName => isWarp ? 'WARP' : 'MASQUE';
  int get socksPort =>
      isWarp ? AetherPlatform.cfwarpSocksPort : AetherPlatform.masqueSocksPort;

  AetherState _engine = const AetherState();
  AetherState get state => _engine;

  AetherOptions options = const AetherOptions();
  bool _optionsLoaded = false;

  bool tunRunning = false;
  int tunSinceMs = 0;
  int upBytes = 0;
  int downBytes = 0;
  int upRate = 0;
  int downRate = 0;

  /// The last Cloudflare trace through the tunnel (ip, loc,
  /// warp, …), from the connect proof or a manual refresh.
  Map<String, String>? exitTrace;

  /// The last endpoint scan's outcome, when one ran this session.
  ({String server, String rtt, DateTime at})? lastScan;

  String? _lastError;

  /// The store's complaint, when it has one (build 2071,
  /// review §5.4): set when a save fails or the saved file
  /// was damaged at load, cleared by the next successful
  /// save. [lastError] reports it after the engine's own
  /// errors, so a failing disk is visible instead of every
  /// change being lost silently, forever.
  String? storeError;

  String? get lastError => _engine.error.isNotEmpty
      ? _engine.error
      : _lastError ?? storeError;

  Future<void> Function()? stopOtherEngine;

  /// Set by the shell: the global tunnel MTU (build 2038, queue 2f) —
  /// the Xray settings value, read at connect time. Defaults to 1500
  /// (the unchanged behaviour) when unwired.
  int Function() tunnelMtu = () => 1500;

  Timer? _poller;
  bool _busy = false;
  bool get connecting => _busy;

  /// Fully up: TUN raised AND the engine at its CONNECTED stage.
  bool get connected => tunRunning && _engine.connected;

  bool get _anyLive => _engine.running || tunRunning || _busy;

  Future<File> _optionsFile() async {
    final filesDir = File(await AndroidCore.dataDir()).parent.path;
    return File('$filesDir/aether_${slot}_options.json');
  }

  /// The shared atomic store for this slot's file (build 2054,
  /// audit F-H8), cached so every write for this file goes
  /// through one serialization chain.
  AtomicJsonStore? _store;

  Future<AtomicJsonStore> _atomicStore() async {
    return _store ??= AtomicJsonStore(await _optionsFile());
  }

  Future<void> load() async {
    if (!_optionsLoaded) {
      _optionsLoaded = true;
      try {
        final store = await _atomicStore();
        final doc = await store.read();
        // Build 2071 (review §5.4): a damaged options file
        // still falls back to the defaults — but it says so
        // on the error surface instead of silently
        // pretending nothing was ever saved.
        if (store.lastReadProblem != null) {
          storeError = storeDamagedMessage;
        }
        if (doc != null) {
          options = AetherOptions.fromJson(doc);
        }
      } catch (_) {
        // A damaged options file falls back to the defaults.
      }
      if (isWarp) {
        // The cfwarp slot's protocol is WireGuard by construction.
        options = options.copyWith(protocol: 'wg');
      }
    }
    await refresh();
  }

  Future<void> setOptions(AetherOptions next) async {
    options = next;
    notifyListeners();
    // Build 2054 (audit F-H8): never persist before load, and
    // write atomically through the shared store — the old
    // direct write could tear the file and silently reset the
    // options on the next launch.
    if (!_optionsLoaded) return;
    try {
      final store = await _atomicStore();
      await store.write(options.toJson());
      // Build 2071 (review §5.4): the store's write never
      // throws, so read its outcome — a failure surfaces on
      // the error surface and stays until a save succeeds.
      if (store.lastWriteError != null) {
        if (storeError != storeSaveFailedMessage) {
          storeError = storeSaveFailedMessage;
          notifyListeners();
        }
      } else if (storeError == storeSaveFailedMessage) {
        // A save landed: the save-failure complaint clears.
        // A damaged-at-load complaint is NOT cleared here —
        // it clears on the next clean load, so the notice
        // survives the session that started fresh.
        storeError = null;
        notifyListeners();
      }
    } catch (_) {
      // Persistence is best-effort; the session keeps the choice.
    }
  }

  Future<void> refresh() async {
    final beforeUp = upBytes;
    final beforeDown = downBytes;
    final beforeAt = _lastTick;
    _engine = await AetherPlatform.state(slot);
    final tun = await AetherPlatform.tunState();
    tunRunning = tun['running'] == true;
    tunSinceMs = (tun['sinceMs'] as num?)?.toInt() ?? 0;
    upBytes = (tun['up'] as num?)?.toInt() ?? 0;
    downBytes = (tun['down'] as num?)?.toInt() ?? 0;
    final now = DateTime.now();
    if (beforeAt != null && tunRunning) {
      final dt = now.difference(beforeAt).inMilliseconds / 1000.0;
      if (dt > 0) {
        upRate = ((upBytes - beforeUp) / dt).round().clamp(0, 1 << 62);
        downRate = ((downBytes - beforeDown) / dt).round().clamp(0, 1 << 62);
      }
    } else {
      upRate = 0;
      downRate = 0;
    }
    _lastTick = now;
    _syncPoller();
    notifyListeners();
  }

  DateTime? _lastTick;

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
    if (_anyLive && _poller == null) {
      _poller = Timer.periodic(
        enginePollPeriod(foreground: _foreground),
        (_) => unawaited(refresh()),
      );
    } else if (!_anyLive && _poller != null) {
      _poller!.cancel();
      _poller = null;
      upRate = 0;
      downRate = 0;
    }
  }

  /// Connects the slot end to end (see the class doc). Throws a
  /// StateError carrying the engine's own words on failure.
  Future<void> connect() async {
    if (_busy) return;
    _busy = true;
    _lastError = null;
    notifyListeners();
    try {
      await stopOtherEngine?.call();
      await refresh();
      // 1. Identity.
      if (!_engine.identity) {
        final outcome = await AetherPlatform.ensureIdentity(
          slot,
          options.protocol,
        );
        await refresh();
        if (!_engine.identity) {
          throw StateError(
            outcome.isNotEmpty
                ? outcome
                : 'a WARP identity could not be made on this network',
          );
        }
      }
      // 2. The engine to its CONNECTED stage.
      final started = await AetherPlatform.start(slot, options);
      if (!started) {
        throw StateError(_engine.error.isNotEmpty
            ? _engine.error
            : 'the engine could not start');
      }
      await _awaitEngineConnected();
      // 3. The WARP proof (and the exit card's trace for MASQUE).
      if (isWarp) {
        await _awaitWarpProof();
      } else {
        exitTrace = await AetherPlatform.trace(slot);
      }
      // 4. The TUN.
      await AetherPlatform.setTun(
        on: true,
        name: displayName,
        socksPort: socksPort,
        engine: slot,
        mtu: tunnelMtu(),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await refresh();
        if (tunRunning) return;
      }
      throw StateError('the VPN tunnel did not come up');
    } catch (e) {
      _lastError = e is StateError ? e.message : '$e';
      await _teardown();
      await refresh();
      rethrow;
    } finally {
      _busy = false;
      _syncPoller();
      notifyListeners();
    }
  }

  Future<void> _awaitEngineConnected() async {
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await refresh();
      if (_engine.connected) return;
      if (_engine.failed) {
        throw StateError(
          _engine.error.isNotEmpty
              ? _engine.error
              : 'the engine failed (${_engine.stageLabel})',
        );
      }
      if (!_engine.running) {
        throw StateError('the engine exited before connecting');
      }
    }
    throw StateError(
      'the engine did not connect in time'
      '${_engine.probeTopReason.isNotEmpty ? ' — most probes failed with: ${_engine.probeTopReason}' : ''}',
    );
  }

  /// CfWarp's rule: connected means warp=on THROUGH the tunnel,
  /// proven by Cloudflare's trace — retried for the budget the
  /// ralysnd engine allows a fresh identity's first proof.
  Future<void> _awaitWarpProof() async {
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    var sawOff = false;
    while (DateTime.now().isBefore(deadline)) {
      final t = await AetherPlatform.trace(slot);
      if (t != null) {
        exitTrace = t;
        if (t['warp'] == 'on' || t['warp'] == 'plus') return;
        if (t['warp'] == 'off') sawOff = true;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw StateError(
      sawOff
          ? 'the tunnel answered, but not through WARP (warp=off)'
          : 'the exit could not be verified through the tunnel',
    );
  }

  Future<void> _teardown() async {
    try {
      await AetherPlatform.setTun(
        on: false,
        name: displayName,
        socksPort: socksPort,
        engine: slot,
        mtu: tunnelMtu(),
      );
    } catch (_) {}
    try {
      await AetherPlatform.stop(slot);
    } catch (_) {}
  }

  Future<void> disconnect() async {
    _busy = true;
    notifyListeners();
    try {
      await _teardown();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await refresh();
        if (!_engine.running && !tunRunning) return;
      }
    } finally {
      _busy = false;
      await refresh();
    }
  }

  /// Runs the engine proxy-only (no TUN) until it has scanned,
  /// chosen and validated an endpoint, then stops it — ralysnd's
  /// endpoint scan. The outcome (the engine's own choice) is
  /// kept in [lastScan]; the user may pin it for later connects.
  Future<void> scanEndpoints() async {
    if (_busy || tunRunning) {
      throw StateError('disconnect before scanning');
    }
    _busy = true;
    _lastError = null;
    notifyListeners();
    try {
      await refresh();
      if (!_engine.identity) {
        final outcome = await AetherPlatform.ensureIdentity(
          slot,
          options.protocol,
        );
        await refresh();
        if (!_engine.identity) {
          throw StateError(
            outcome.isNotEmpty
                ? outcome
                : 'a WARP identity could not be made on this network',
          );
        }
      }
      final started = await AetherPlatform.start(
        slot,
        options.copyWith(clearPeer: true),
      );
      if (!started) throw StateError('the engine could not start');
      await _awaitEngineConnected();
      lastScan = (
        server: _engine.server,
        rtt: _engine.rtt,
        at: DateTime.now(),
      );
      exitTrace = await AetherPlatform.trace(slot);
    } finally {
      try {
        await AetherPlatform.stop(slot);
      } catch (_) {}
      _busy = false;
      await refresh();
    }
  }

  /// Deletes the slot's identity (the next connect registers a
  /// fresh one). Refused silently while connected — the UI
  /// disables it then; ralysnd's engines delete under a stop.
  Future<void> resetIdentity() async {
    await AetherPlatform.resetIdentity(slot);
    exitTrace = null;
    await refresh();
  }

  /// A fresh trace through the live tunnel (the exit card's
  /// refresh action).
  Future<void> refreshTrace() async {
    exitTrace = await AetherPlatform.trace(slot);
    notifyListeners();
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }
}
