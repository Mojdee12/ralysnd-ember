/// The Psiphon engine's platform seam: [PsiphonBackend] is what a
/// platform provides, [AndroidPsiphonBackend] drives the Kotlin
/// service over the 'app/android' channel, and
/// [WindowsPsiphonBackend] (psiphon_platform_windows.dart) runs the
/// tunnel-core ConsoleClient as a child process. [PsiphonPlatform]
/// keeps the static surface the controller has always used and adds
/// [PsiphonPlatform.workDir], the engine's folder on this platform
/// (the Xray seam's shape, so both engines resolve their paths the
/// same way).

import 'dart:io';

import 'package:flutter/services.dart';

import '../core/android_core.dart';
import 'psiphon_platform_windows.dart';

class PsiphonState {
  final bool running;

  /// The core reported a working tunnel (its onConnected).
  final bool connected;
  final bool vpnMode;
  final int sinceMs;
  final int upBytes;
  final int downBytes;

  /// The egress region the core actually landed in ("" while unknown).
  final String region;

  /// The exit address the core reported for itself ("" while unknown).
  final String clientAddress;

  /// The egress regions the core announced this run.
  final List<String> regions;

  /// The backend's last failure, in words ('' when none). Only the
  /// Windows backend records one; it makes a dead core diagnosable
  /// instead of a silent "not connected".
  final String lastError;

  const PsiphonState({
    required this.running,
    required this.connected,
    required this.vpnMode,
    required this.sinceMs,
    required this.upBytes,
    required this.downBytes,
    required this.region,
    required this.clientAddress,
    required this.regions,
    this.lastError = '',
  });

  static const stopped = PsiphonState(
    running: false,
    connected: false,
    vpnMode: true,
    sinceMs: 0,
    upBytes: 0,
    downBytes: 0,
    region: '',
    clientAddress: '',
    regions: [],
  );
}

/// What a platform provides for the Psiphon engine.
abstract interface class PsiphonBackend {
  Future<void> setOn({
    required bool vpnMode,
    required String region,
    required String upstream,
    required List<String> protocols,
    required String dns,
    // The tunnel MTU (Android build 2157 contract): the Android
    // VpnService builder's input. The Windows backend runs
    // proxy-only (no TUN), so it accepts and documents it unused.
    required int mtu,
  });

  Future<void> stop();

  Future<PsiphonState> state();

  /// The exit IP/country of the running tunnel, asked through the
  /// tunnel itself. Best-effort: null on any failure.
  Future<Map<String, String>?> exitInfo();

  /// The engine's folder (settings, the core's data root, logs).
  Future<Directory> workDir();
}

/// Android: the Kotlin PsiphonVpnService over the app channel.
class AndroidPsiphonBackend implements PsiphonBackend {
  static const _channel = MethodChannel('app/android');

  @override
  Future<void> setOn({
    required bool vpnMode,
    required String region,
    required String upstream,
    required List<String> protocols,
    required String dns,
    required int mtu,
  }) => _channel.invokeMethod('psiphonSetOn', {
    'on': true,
    'vpnMode': vpnMode,
    'region': region,
    'upstream': upstream,
    'protocols': protocols,
    'dns': dns,
    'mtu': mtu,
  });

  @override
  Future<void> stop() => _channel.invokeMethod('psiphonStop');

  @override
  Future<PsiphonState> state() async {
    final m = await _channel.invokeMapMethod<String, dynamic>('psiphonState');
    if (m == null) return PsiphonState.stopped;
    return PsiphonState(
      running: m['running'] as bool? ?? false,
      connected: m['connected'] as bool? ?? false,
      vpnMode: m['vpnMode'] as bool? ?? true,
      sinceMs: (m['sinceMs'] as num?)?.toInt() ?? 0,
      upBytes: (m['up'] as num?)?.toInt() ?? 0,
      downBytes: (m['down'] as num?)?.toInt() ?? 0,
      region: m['region'] as String? ?? '',
      clientAddress: m['clientAddress'] as String? ?? '',
      regions: ((m['regions'] as List?) ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  @override
  Future<Map<String, String>?> exitInfo() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'psiphonExitInfo',
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
    return Directory('${File(coreDir).parent.path}/psiphon');
  }
}

abstract final class PsiphonPlatform {
  /// The engine's fixed local proxy ports (PsiphonConstants.kt).
  static const socksPort = 11808;
  static const httpPort = 11809;

  static final PsiphonBackend backend = Platform.isWindows
      ? WindowsPsiphonBackend()
      : AndroidPsiphonBackend();

  static Future<void> setOn({
    required bool vpnMode,
    required String region,
    required String upstream,
    required List<String> protocols,
    required String dns,
    required int mtu,
  }) => backend.setOn(
    vpnMode: vpnMode,
    region: region,
    upstream: upstream,
    protocols: protocols,
    dns: dns,
    mtu: mtu,
  );

  static Future<void> stop() => backend.stop();

  static Future<PsiphonState> state() => backend.state();

  static Future<Map<String, String>?> exitInfo() => backend.exitInfo();

  static Future<Directory> workDir() => backend.workDir();
}
