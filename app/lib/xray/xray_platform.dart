/// The Xray engine's platform seam (PLAN.md §1/§3).
///
/// [XrayPlatform] is the facade the controller talks to; it delegates
/// to the backend for the running platform: [AndroidXrayBackend] (the
/// 'app/android' MethodChannel MainActivity serves — the original
/// implementation) or WindowsXrayBackend in
/// xray_platform_windows.dart (spawns the xray.exe sidecar — since
/// the 2.2.0 parity port, the SAME patched Xray fork Android runs,
/// cross-built for Windows, so finalmask/dialMode/+one configs mean
/// the same thing on both platforms).
/// Both expose identical method meanings and return shapes, so
/// XrayState and the UI never see the difference.
///
/// The method set is Android build 2032's (the parity port): chain
/// underlays on [XrayBackend.setOn], the standalone EmberWarp tunnel
/// ([XrayBackend.setOnWarp]), config rotation, tunnel checks, the
/// extended delay result, endurance, network fingerprint and config
/// validation.

import 'dart:io';

import 'package:flutter/services.dart';

import '../core/android_core.dart';
import 'xray_platform_windows.dart';

class XrayState {
  final bool running;
  final String name;
  final int sinceMs;
  final int upBytes;
  final int downBytes;

  /// Watchdog revivals of a wedged core this session, and the last
  /// watchdog event (empty when the core is healthy). The Windows
  /// backend has no watchdog (it owns the process directly), so it
  /// reports 0/''.
  final int coreRestarts;
  final String coreProblem;

  /// Chain state (build 2029A): a Psiphon underlay is chained
  /// under this session, and the supervisor's last word about it.
  /// On Windows the underlay processes are Dart-owned (the
  /// controller starts them), so the backend reports false/''.
  final bool chainUnderlay;
  final String chainProblem;

  /// The backend's last failure, in words ('' when none). Only the
  /// Windows backend records one; the controller surfaces it so a
  /// failed start/test is diagnosable instead of silent.
  final String lastError;

  /// The loopback SOCKS port the running session actually bound
  /// (0 when stopped or unknown). The Windows backend falls back to
  /// a free port when the configured one is taken (another proxy
  /// client, a leftover core), so this can differ from the setting.
  final int localPort;

  /// A non-failure note about the running session ('' when none) —
  /// the Windows backend records a port fallback here so the taken
  /// port is visible instead of silent.
  final String note;
  const XrayState({
    required this.running,
    required this.name,
    required this.sinceMs,
    required this.upBytes,
    required this.downBytes,
    this.coreRestarts = 0,
    this.coreProblem = '',
    this.chainUnderlay = false,
    this.chainProblem = '',
    this.lastError = '',
    this.localPort = 0,
    this.note = '',
  });
  static const stopped = XrayState(
    running: false,
    name: '',
    sinceMs: 0,
    upBytes: 0,
    downBytes: 0,
  );
}

/// One platform's Xray engine. [setOn]'s [dns]/[ipv6] are the Android
/// TUN builder's inputs; a backend without a TUN layer accepts and
/// documents them as unused (the config JSON already carries DNS).
/// [setOn]'s [tunCapture] is the desktop mode choice (system-wide
/// TUN vs local proxies only); Android's VpnService always captures
/// in VPN mode, so its backend accepts and ignores it. The chain
/// underlay arguments ([underlay] and friends, [warpArgs]) tell the
/// Android service to supervise the underlay it starts; on Windows
/// the controller itself starts the underlay engines (Psiphon /
/// EmberWarp Dart backends), the chain wiring already lives in the
/// config's dialerProxy, and the Windows backend accepts the
/// arguments for contract parity.
abstract class XrayBackend {
  Future<void> setOn({
    required String config,
    required String name,
    required int socksPort,
    required String dns,
    required bool ipv6,
    bool tunCapture = false,
    String underlay = 'none',
    String underlayRegion = '',
    String underlayUpstream = '',
    List<String> underlayProtocols = const [],
    List<String> warpArgs = const [],
  });

  /// Starts the standalone EmberWarp tunnel (build 2030): the
  /// EmberWarp core must ALREADY be running and ready (the
  /// controller starts and health-checks it first); the platform
  /// brings system capture up against the core's SOCKS port with
  /// no Xray process. On Windows that is the TUN bridge pointed at
  /// the EmberWarp session port (or proxy mode, when capture is
  /// off: the session then honestly reports proxy-only through
  /// [XrayState.note]).
  Future<void> setOnWarp({
    required String name,
    required String dns,
    required bool ipv6,
    bool tunCapture = false,
    List<String> warpArgs = const [],
  });

  /// Replaces the running core's config and respawns ONLY the
  /// core subprocess (build 2029A, watchdog shape rotation): the
  /// TUN interface and its bridge are untouched. False when no
  /// session is running to rotate.
  Future<bool> rotateConfig(String config);

  Future<void> stop();

  Future<XrayState> state();

  /// A single through-tunnel connectivity probe of the RUNNING
  /// session (ms), or -1 when it does not answer.
  Future<int> tunnelCheck(int socksPort);

  /// The real through-tunnel delay (ms) of a test config, or -1.
  Future<int> measureDelay(String testConfig);

  /// The extended delay result: {'ms': int, 'error': String} —
  /// the failure in words when ms is -1.
  Future<Map<String, dynamic>> measureDelayEx(String testConfig);

  /// The endurance qualification of a test config (build 2029A):
  /// {'p0': ms, 'p1': ms, 'p2': ms, 'held': 1} with -1 for a probe
  /// that failed; null when the test could not run.
  Future<Map<String, int>?> endurance(String testConfig);

  /// The through-tunnel download rate (bytes/s) of a test config,
  /// or -1.
  Future<int> speedTest(String testConfig);

  /// The device network's fingerprint (build 2032, the anti-filter
  /// shape cache's key): best-effort map, null when unavailable.
  Future<Map<String, String>?> networkFingerprint();

  /// Validates a config against the core: an error string, or
  /// null when the core accepts it / validation is unavailable.
  Future<String?> validateConfig(String config);

  /// The running core's "proxy" outbound counters since the previous
  /// read (the query resets them, so each result is a delta):
  /// {'up': n, 'down': n} in bytes. Best-effort: null on any failure.
  Future<Map<String, int>?> trafficStats(int apiPort);

  /// The exit IP/country of the tunnel running on [socksPort], asked
  /// through the tunnel itself. Best-effort: null on any failure.
  Future<Map<String, String>?> exitInfo(int socksPort);

  /// The engine's working folder: profiles' state file, the running
  /// config, logs and geo data all live here.
  Future<Directory> workDir();
}

/// The Android backend: the same 'app/android' channel MainActivity
/// serves (XrayVpnService / XrayTester on the Kotlin side).
class AndroidXrayBackend implements XrayBackend {
  static const _channel = MethodChannel('app/android');

  @override
  Future<void> setOn({
    required String config,
    required String name,
    required int socksPort,
    required String dns,
    required bool ipv6,
    bool tunCapture = false,
    String underlay = 'none',
    String underlayRegion = '',
    String underlayUpstream = '',
    List<String> underlayProtocols = const [],
    List<String> warpArgs = const [],
  }) => _channel.invokeMethod('xraySetOn', {
    'on': true,
    'config': config,
    'name': name,
    'socksPort': socksPort,
    'dns': dns,
    'ipv6': ipv6,
    'underlay': underlay,
    'underlayRegion': underlayRegion,
    'underlayUpstream': underlayUpstream,
    'underlayProtocols': underlayProtocols,
    'warpArgs': warpArgs,
  });

  @override
  Future<void> setOnWarp({
    required String name,
    required String dns,
    required bool ipv6,
    bool tunCapture = false,
    List<String> warpArgs = const [],
  }) => _channel.invokeMethod('xraySetOnWarp', {
    'on': true,
    'name': name,
    'dns': dns,
    'ipv6': ipv6,
    'warpArgs': warpArgs,
  });

  @override
  Future<bool> rotateConfig(String config) async {
    try {
      final v = await _channel.invokeMethod<bool>('xrayRotateConfig', {
        'config': config,
      });
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() => _channel.invokeMethod('xrayStop');

  @override
  Future<XrayState> state() async {
    final m = await _channel.invokeMapMethod<String, dynamic>('xrayState');
    if (m == null) return XrayState.stopped;
    return XrayState(
      running: m['running'] as bool? ?? false,
      name: m['name'] as String? ?? '',
      sinceMs: (m['sinceMs'] as num?)?.toInt() ?? 0,
      upBytes: (m['up'] as num?)?.toInt() ?? 0,
      downBytes: (m['down'] as num?)?.toInt() ?? 0,
      coreRestarts: (m['coreRestarts'] as num?)?.toInt() ?? 0,
      coreProblem: m['coreProblem'] as String? ?? '',
      chainUnderlay: m['chainUnderlay'] as bool? ?? false,
      chainProblem: m['chainProblem'] as String? ?? '',
    );
  }

  @override
  Future<int> tunnelCheck(int socksPort) async {
    try {
      final v = await _channel.invokeMethod<int>('xrayTunnelCheck', {
        'socksPort': socksPort,
      });
      return v ?? -1;
    } catch (_) {
      return -1;
    }
  }

  @override
  Future<int> measureDelay(String testConfig) async {
    final v = await _channel.invokeMethod<int>('xrayMeasureDelay', {
      'config': testConfig,
    });
    return v ?? -1;
  }

  @override
  Future<Map<String, dynamic>> measureDelayEx(String testConfig) async {
    try {
      final m = await _channel.invokeMapMethod<dynamic, dynamic>(
        'xrayMeasureDelayEx',
        {'config': testConfig},
      );
      if (m == null) return {'ms': -1, 'error': 'no result'};
      return m.map((k, v) => MapEntry(k.toString(), v));
    } catch (e) {
      return {'ms': -1, 'error': '$e'};
    }
  }

  @override
  Future<Map<String, int>?> endurance(String testConfig) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'xrayEndurance',
        {'config': testConfig},
      );
      if (m == null) return null;
      return m.map((k, v) => MapEntry(k, (v as num?)?.toInt() ?? -1));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int> speedTest(String testConfig) async {
    final v = await _channel.invokeMethod<int>('xraySpeedTest', {
      'config': testConfig,
    });
    return v ?? -1;
  }

  @override
  Future<Map<String, String>?> networkFingerprint() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'xrayNetworkFingerprint',
      );
      if (m == null) return null;
      return m.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> validateConfig(String config) async {
    try {
      return await _channel.invokeMethod<String>('xrayValidateConfig', {
        'config': config,
      });
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, int>?> trafficStats(int apiPort) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'xrayStats',
        {'apiPort': apiPort},
      );
      if (m == null) return null;
      return {
        'up': (m['up'] as num?)?.toInt() ?? 0,
        'down': (m['down'] as num?)?.toInt() ?? 0,
      };
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, String>?> exitInfo(int socksPort) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'xrayExitInfo',
        {'socksPort': socksPort},
      );
      if (m == null) return null;
      return m.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Directory> workDir() async {
    final coreDir = await AndroidCore.dataDir();
    return Directory('${File(coreDir).parent.path}/xray');
  }
}

/// The facade the controller and UI call; see the file's doc comment.
class XrayPlatform {
  static XrayBackend? _backend;

  static XrayBackend get backend =>
      _backend ??= Platform.isWindows
          ? WindowsXrayBackend()
          : AndroidXrayBackend();

  static Future<void> setOn({
    required String config,
    required String name,
    required int socksPort,
    required String dns,
    required bool ipv6,
    bool tunCapture = false,
    String underlay = 'none',
    String underlayRegion = '',
    String underlayUpstream = '',
    List<String> underlayProtocols = const [],
    List<String> warpArgs = const [],
  }) => backend.setOn(
    config: config,
    name: name,
    socksPort: socksPort,
    dns: dns,
    ipv6: ipv6,
    tunCapture: tunCapture,
    underlay: underlay,
    underlayRegion: underlayRegion,
    underlayUpstream: underlayUpstream,
    underlayProtocols: underlayProtocols,
    warpArgs: warpArgs,
  );

  static Future<void> setOnWarp({
    required String name,
    required String dns,
    required bool ipv6,
    bool tunCapture = false,
    List<String> warpArgs = const [],
  }) => backend.setOnWarp(
    name: name,
    dns: dns,
    ipv6: ipv6,
    tunCapture: tunCapture,
    warpArgs: warpArgs,
  );

  static Future<bool> rotateConfig(String config) =>
      backend.rotateConfig(config);

  static Future<void> stop() => backend.stop();

  static Future<XrayState> state() => backend.state();

  static Future<int> tunnelCheck(int socksPort) =>
      backend.tunnelCheck(socksPort);

  static Future<int> measureDelay(String testConfig) =>
      backend.measureDelay(testConfig);

  static Future<Map<String, dynamic>> measureDelayEx(String testConfig) =>
      backend.measureDelayEx(testConfig);

  static Future<Map<String, int>?> endurance(String testConfig) =>
      backend.endurance(testConfig);

  static Future<int> speedTest(String testConfig) =>
      backend.speedTest(testConfig);

  static Future<Map<String, String>?> networkFingerprint() =>
      backend.networkFingerprint();

  static Future<String?> validateConfig(String config) =>
      backend.validateConfig(config);

  static Future<Map<String, int>?> trafficStats(int apiPort) =>
      backend.trafficStats(apiPort);

  static Future<Map<String, String>?> exitInfo(int socksPort) =>
      backend.exitInfo(socksPort);

  static Future<Directory> workDir() => backend.workDir();
}
