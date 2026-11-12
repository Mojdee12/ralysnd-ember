import 'dart:io';

import 'package:flutter/services.dart';

/// The Lantern engine's state, as the Kotlin LanternVpnService
/// and LanternCore report it on the bridge. Stage values come
/// from the core's stdout contract: idle, starting, fetching,
/// up, error.
class LanternState {
  const LanternState({
    this.available = false,
    this.running = false,
    this.coreRunning = false,
    this.connected = false,
    this.stage = 'idle',
    this.exitCity = '',
    this.exitCountry = '',
    this.exitCode = '',
    this.servers = -1,
    this.keptServers = -1,
    this.keptMasque = -1,
    this.exhausted = false,
    this.sinceMs = 0,
    this.upBytes = 0,
    this.downBytes = 0,
    this.error,
    this.stdoutTail = const [],
    this.stderrTail = const [],
  });

  factory LanternState.fromMap(Map<dynamic, dynamic> m) => LanternState(
    available: m['available'] == true,
    running: m['running'] == true,
    coreRunning: m['coreRunning'] == true,
    connected: m['connected'] == true,
    stage: (m['stage'] as String?) ?? 'idle',
    exitCity: (m['exitCity'] as String?) ?? '',
    exitCountry: (m['exitCountry'] as String?) ?? '',
    exitCode: (m['exitCode'] as String?) ?? '',
    servers: (m['servers'] as num?)?.toInt() ?? -1,
    keptServers: (m['keptServers'] as num?)?.toInt() ?? -1,
    keptMasque: (m['keptMasque'] as num?)?.toInt() ?? -1,
    exhausted: m['exhausted'] == true,
    sinceMs: (m['sinceMs'] as num?)?.toInt() ?? 0,
    upBytes: (m['up'] as num?)?.toInt() ?? 0,
    downBytes: (m['down'] as num?)?.toInt() ?? 0,
    error: m['error'] as String?,
    stdoutTail:
        (m['stdoutTail'] as List?)?.map((e) => e.toString()).toList() ??
        const [],
    stderrTail:
        (m['stderrTail'] as List?)?.map((e) => e.toString()).toList() ??
        const [],
  );

  /// False on builds without the core binary (non-arm64 ABIs).
  final bool available;

  /// The TUN tunnel is up.
  final bool running;

  /// The core subprocess is alive.
  final bool coreRunning;

  /// The core reports the proxy carrying traffic ("proxy ok").
  final bool connected;

  /// idle | starting | fetching | up | error
  final String stage;
  final String exitCity;
  final String exitCountry;

  /// The exit's ISO country code (NL, DE, …), for the map pin.
  final String exitCode;

  /// Servers in the fetched config; -1 until the first list lands.
  final int servers;

  /// The kept (on-disk) config's server counts (build 2032):
  /// fronted / masque, -1 when there is no readable kept
  /// config. A valid kept config means the next start connects
  /// instantly, with no fetch — ralysnd's rule.
  final int keptServers;
  final int keptMasque;

  /// True when a kept config exists to start from instantly.
  bool get hasKeptConfig => keptServers > 0 || keptMasque > 0;

  /// The core reports its free capacity allocation is used up.
  final bool exhausted;
  final int sinceMs;
  final int upBytes;
  final int downBytes;

  /// The last startup/core failure, verbatim from the platform.
  final String? error;
  final List<String> stdoutTail;
  final List<String> stderrTail;

  bool get starting =>
      stage == 'starting' || stage == 'fetching' || (running && !connected);

  /// Short human line for the stage, for the home page and bar.
  String get stageLabel => switch (stage) {
    'starting' => 'Starting the core…',
    'fetching' => 'Fetching the server list…',
    'up' => 'Connected',
    'error' => 'Failed',
    _ => running ? 'Connecting…' : 'Not connected',
  };

  // ---- Windows-tree desktop page compatibility -----------------
  // The desktop Lantern pages were written against the 2.1.0
  // tree's older LanternState shape. These getters keep those
  // pages working against the 2032 state contract unchanged.
  String get serverCountryCode => exitCode;
  String get serverLine => exitLine;
  int? get capAllotted => null;
  int? get capUsed => null;
  bool get failed => stage == 'error' || error != null;
  String get failure => error ?? '';

  /// "City, Country" when the core has named its exit.
  String get exitLine {
    if (exitCity.isNotEmpty && exitCountry.isNotEmpty) {
      return '$exitCity, $exitCountry';
    }
    return exitCountry;
  }
}

/// The platform-channel surface of the Lantern engine
/// (MainActivity's lantern* cases).
/// Why Lantern cannot start on Windows (yet): the engine is
/// Lantern's radiance core compiled as an Android library
/// (liblantern.so) — there is no Windows build of it in this
/// tree. The honest Windows state is therefore a failed state
/// carrying this explanation (never a dead toggle): the page
/// shows it verbatim. The unblock path is a radiance sidecar
/// (getlantern/radiance is Go and cross-platform; a Windows
/// CLI wrapper around it, staged like the other sidecars,
/// would slot in behind this facade unchanged).
const lanternWindowsUnavailable =
    'Lantern is not available on Windows yet: its core ships '
    'only as an Android library in this app. The V2Ray, '
    'Psiphon, WARP and Mozilla engines all work on Windows.';

class LanternPlatform {
  static const _channel = MethodChannel('app/android');

  static bool get _windows => Platform.isWindows;
  static const int socksPort = 20840;
  static const int httpPort = 20841;

  static Future<void> setOn({
    required bool on,
    bool ipv6 = true,
    bool smart = false,
    int fetchVia = 0,
    String clientIp = '',
  }) async {
    if (_windows) throw StateError(lanternWindowsUnavailable);
    return _channel.invokeMethod<void>('lanternSetOn', {
    'on': on,
    'ipv6': ipv6,
    'smart': smart,
    'fetchVia': fetchVia,
    'clientIp': clientIp,
    });
  }

  static Future<void> stop() async {
    if (_windows) return;
    return _channel.invokeMethod<void>('lanternStop');
  }

  static Future<LanternState> state() async {
    if (_windows) {
      return const LanternState(
        stage: 'error',
        error: lanternWindowsUnavailable,
      );
    }
    final m = await _channel.invokeMapMethod<dynamic, dynamic>('lanternState');
    return m == null ? const LanternState() : LanternState.fromMap(m);
  }

  /// Asks the running core to refetch its server list now.
  static Future<bool> fetchList() async {
    if (_windows) return false;
    return await _channel.invokeMethod<bool>('lanternFetchList') ?? false;
  }

  /// Deletes the cached server list so the next start refetches
  /// it. Returns the number of files deleted, or -1 while the
  /// core is running.
  static Future<int> rotateList() async {
    if (_windows) return 0;
    return await _channel.invokeMethod<int>('lanternRotateList') ?? 0;
  }
}
