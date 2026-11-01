/// The WARP+ engine's brain: its settings (connection mode,
/// endpoint scan, cfon country, endpoint override), their
/// persistence, and the tunnel's on/off state — everything the
/// Ember UI binds to. Mirrors the Psiphon controller's shape so the
/// shell arbitrates all five engines the same way.
///
/// The engine is bepass-org/warp-plus (pinned v1.2.6) running as a
/// subprocess: it self-registers an anonymous Cloudflare WARP
/// identity on first connect and keeps it in its own files dir —
/// no account, no key, nothing to enter. Session traffic comes from
/// the service's per-UID counters (approximate, like the Xray
/// engine's), so rates and totals are shown; the core itself
/// exposes no counters.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/android_core.dart';
import '../xray/exit_info.dart';
import 'warp_platform.dart';

/// How warp-plus reaches WARP; the values are the service's mode
/// strings (its --gool / --cfon flags; standard = neither).
enum WarpMode {
  standard('standard'),
  gool('gool'),
  cfon('cfon');

  const WarpMode(this.wire);
  final String wire;

  static WarpMode fromWire(String w) => WarpMode.values.firstWhere(
        (m) => m.wire == w,
        orElse: () => WarpMode.standard,
      );
}

/// The exit countries warp-plus's built-in Psiphon accepts
/// (psiphon/p.go Countries in the pinned source).
const warpCfonCountries = <String>[
  'AT', 'AU', 'BE', 'BG', 'CA', 'CH', 'CZ', 'DE', 'DK', 'EE', 'ES',
  'FI', 'FR', 'GB', 'HR', 'HU', 'IE', 'IN', 'IT', 'JP', 'LV', 'NL',
  'NO', 'PL', 'PT', 'RO', 'RS', 'SE', 'SG', 'SK', 'US',
];

class WarpSettings {
  /// Standard, WARP-in-WARP (gool) or Psiphon-chained (cfon).
  WarpMode mode = WarpMode.standard;

  /// Probe WARP endpoints first and connect to the fastest.
  bool scan = false;

  /// The exit country for cfon mode (the binary requires one).
  String country = 'DE';

  /// A fixed WARP endpoint (host:port); '' = the binary picks a
  /// random one (or the scan's winner).
  String endpoint = '';

  Map<String, dynamic> toJson() => {
        'mode': mode.wire,
        'scan': scan,
        'country': country,
        'endpoint': endpoint,
      };

  static WarpSettings fromJson(Map<String, dynamic> j) {
    final s = WarpSettings();
    s.mode = WarpMode.fromWire(j['mode'] as String? ?? 'standard');
    s.scan = j['scan'] as bool? ?? false;
    final country = j['country'] as String? ?? 'DE';
    s.country = warpCfonCountries.contains(country) ? country : 'DE';
    s.endpoint = j['endpoint'] as String? ?? '';
    return s;
  }
}

class WarpController extends ChangeNotifier {
  WarpSettings settings = WarpSettings();
  WarpState state = WarpState.stopped;
  bool connecting = false;
  int upRate = 0;
  int downRate = 0;
  String? lastError;

  /// The running tunnel's exit IP/country, looked up best-effort
  /// through the tunnel once it is up.
  ExitInfo? exitInfo;
  bool _exitFetching = false;

  /// Set by the shell: stops the other engines so only one tunnel is
  /// ever up. Returns when they are off.
  Future<void> Function()? stopOtherEngine;

  Timer? _poll;
  WarpState? _lastSample;
  DateTime? _lastSampleAt;

  // ---- persistence ----------------------------------------------------

  Future<File> _stateFile() async {
    final coreDir = await AndroidCore.dataDir();
    final filesDir = File(coreDir).parent;
    return File('${filesDir.path}/warp/state.json');
  }

  Future<Directory> workDir() async {
    final coreDir = await AndroidCore.dataDir();
    return Directory('${File(coreDir).parent.path}/warp');
  }

  Future<void> load() async {
    try {
      final file = await _stateFile();
      if (await file.exists()) {
        final doc =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (doc['settings'] is Map) {
          settings = WarpSettings.fromJson(
            (doc['settings'] as Map).cast<String, dynamic>(),
          );
        }
      }
    } catch (_) {
      // A damaged store starts with defaults rather than crashing.
    }
    await refreshState();
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final file = await _stateFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'settings': settings.toJson()}));
    } catch (_) {
      // The choice holds in memory until the next successful save.
    }
  }

  /// Stores new settings; a running tunnel keeps its start settings
  /// until the next connect (the binary reads them only at start).
  Future<void> updateSettings(WarpSettings next) async {
    settings = next;
    await _save();
    notifyListeners();
  }

  // ---- state ------------------------------------------------------------

  Future<void> refreshState() async {
    state = await WarpPlatform.state();
    if (state.active) {
      _lastSample = state;
      _lastSampleAt = DateTime.now();
      _startPolling();
      if (state.connected) _fetchExitInfo();
    }
    notifyListeners();
  }

  void _startPolling() {
    _poll ??= Timer.periodic(const Duration(seconds: 2), (_) async {
      final sample = await WarpPlatform.state();
      final now = DateTime.now();
      final last = _lastSample;
      final lastAt = _lastSampleAt;
      if (last != null && lastAt != null && sample.running) {
        final dt = now.difference(lastAt).inMilliseconds / 1000.0;
        if (dt > 0) {
          upRate =
              ((sample.upBytes - last.upBytes) / dt).round().clamp(0, 1 << 62);
          downRate = ((sample.downBytes - last.downBytes) / dt)
              .round()
              .clamp(0, 1 << 62);
        }
      }
      _lastSample = sample;
      _lastSampleAt = now;
      state = sample;
      if (sample.running && sample.connected) _fetchExitInfo();
      if (!sample.active) {
        _poll?.cancel();
        _poll = null;
        upRate = 0;
        downRate = 0;
        _lastSample = null;
        _lastSampleAt = null;
        exitInfo = null;
      }
      notifyListeners();
    });
  }

  void _fetchExitInfo() {
    if (_exitFetching || exitInfo != null) return;
    _exitFetching = true;
    WarpPlatform.exitInfo().then((m) {
      _exitFetching = false;
      if (m != null && m['ip'] != null && m['ip']!.isNotEmpty) {
        exitInfo = ExitInfo.fromMap(m);
        notifyListeners();
      }
    });
  }

  // ---- connect / disconnect ----------------------------------------------

  Future<void> connect() async {
    connecting = true;
    lastError = null;
    exitInfo = null;
    notifyListeners();
    try {
      // One tunnel at a time: the other engines go off first.
      await stopOtherEngine?.call();
      if (state.active) await disconnect();
      await WarpPlatform.setOn(
        mode: settings.mode.wire,
        scan: settings.scan,
        country: settings.country,
        endpoint: settings.endpoint.trim(),
        dns: '1.1.1.1',
      );
      // The service reports itself once the core serves its proxy;
      // registration, a scan or the cfon bootstrap can take a while,
      // so wait generously — and bail early if the core dies.
      for (var i = 0; i < 360; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        state = await WarpPlatform.state();
        if (state.running) break;
        if (state.failed) throw StateError('start-failed');
      }
      if (!state.running) throw StateError('start-failed');
      _lastSample = state;
      _lastSampleAt = DateTime.now();
      _startPolling();
    } catch (e) {
      lastError = e.toString();
      rethrow;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    await WarpPlatform.stop();
    for (var i = 0; i < 20; i++) {
      state = await WarpPlatform.state();
      if (!state.active) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    state = await WarpPlatform.state();
    exitInfo = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  // ---- logs ----------------------------------------------------------------

  /// The tails of the WARP logs, newest content last.
  Future<String> readLogs() async {
    final dir = await workDir();
    final out = StringBuffer();
    for (final name in ['warp.log', 'tunlink.log']) {
      final file = File('${dir.path}/$name');
      out.writeln('—— $name ——');
      try {
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final tail = bytes.length > 64 * 1024
              ? bytes.sublist(bytes.length - 64 * 1024)
              : bytes;
          out.writeln(utf8.decode(tail, allowMalformed: true));
        } else {
          out.writeln('(empty)');
        }
      } catch (e) {
        out.writeln('($e)');
      }
    }
    return out.toString();
  }

  Future<void> clearLogs() async {
    final dir = await workDir();
    for (final name in ['warp.log', 'tunlink.log']) {
      try {
        await File('${dir.path}/$name').writeAsString('');
      } catch (_) {
        // Not there yet.
      }
    }
  }
}
