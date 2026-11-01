/// The Xray engine's platform seam (PLAN.md §1/§3).
///
/// [XrayPlatform] is the facade the controller talks to; it delegates
/// to the backend for the running platform: [AndroidXrayBackend] (the
/// 'app/android' MethodChannel MainActivity serves — the original
/// implementation, unchanged) or WindowsXrayBackend in
/// xray_platform_windows.dart (spawns the official xray.exe sidecar).
/// Both expose identical method meanings and return shapes, so
/// XrayState and the UI never see the difference.

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
/// in VPN mode, so its backend accepts and ignores it.
abstract class XrayBackend {
  Future<void> setOn({
    required String config,
    required String name,
    required int socksPort,
    required String dns,
    required bool ipv6,
    bool tunCapture = false,
  });

  Future<void> stop();

  Future<XrayState> state();

  /// The real through-tunnel delay (ms) of a test config, or -1.
  Future<int> measureDelay(String testConfig);

  /// The through-tunnel download rate (bytes/s) of a test config,
  /// or -1.
  Future<int> speedTest(String testConfig);

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
  }) =>
      _channel.invokeMethod('xraySetOn', {
        'on': true,
        'config': config,
        'name': name,
        'socksPort': socksPort,
        'dns': dns,
        'ipv6': ipv6,
      });

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
    );
  }

  @override
  Future<int> measureDelay(String testConfig) async {
    final v = await _channel.invokeMethod<int>('xrayMeasureDelay', {
      'config': testConfig,
    });
    return v ?? -1;
  }

  @override
  Future<int> speedTest(String testConfig) async {
    final v = await _channel.invokeMethod<int>('xraySpeedTest', {
      'config': testConfig,
    });
    return v ?? -1;
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
  }) =>
      backend.setOn(
        config: config,
        name: name,
        socksPort: socksPort,
        dns: dns,
        ipv6: ipv6,
        tunCapture: tunCapture,
      );

  static Future<void> stop() => backend.stop();

  static Future<XrayState> state() => backend.state();

  static Future<int> measureDelay(String testConfig) =>
      backend.measureDelay(testConfig);

  static Future<int> speedTest(String testConfig) =>
      backend.speedTest(testConfig);

  static Future<Map<String, int>?> trafficStats(int apiPort) =>
      backend.trafficStats(apiPort);

  static Future<Map<String, String>?> exitInfo(int socksPort) =>
      backend.exitInfo(socksPort);

  static Future<Directory> workDir() => backend.workDir();
}
