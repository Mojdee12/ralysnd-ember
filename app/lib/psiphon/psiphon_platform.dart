/// The Psiphon engine's platform seam: [PsiphonBackend] is what a
/// platform provides, [AndroidPsiphonBackend] drives the Kotlin
/// service over the 'app/android' channel, and
/// [WindowsPsiphonBackend] (psiphon_platform_windows.dart) hosts
/// the MLM ladder over the tunnel-core ConsoleClient child
/// process. [PsiphonPlatform] keeps the static surface the
/// controller uses (Android build 2157's contract: the full
/// strategy-ladder argument set and state) and adds
/// [PsiphonPlatform.workDir], the engine's folder on this
/// platform (the Xray seam's shape, so both engines resolve
/// their paths the same way).

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

  /// The ladder rung that connected (build 2065; "" when none).
  final String method;

  /// The last start wedged inside the core library and the
  /// host gave up on it (build 2087, diagnosis F1/F3). The
  /// connect path fails fast on this instead of waiting out a
  /// session that can never connect.
  final bool wedged;

  /// Whether the host's current start call has RETURNED from
  /// the core library (build 2088). False while the call is
  /// still inside the library — the wedge frontier. The
  /// external watchdog fires only on a start that is still
  /// inside past its deadline; a returned start whose
  /// establishment is merely slow never fires it. Defaults
  /// to true (nothing outstanding).
  final bool startReturned;

  /// Build 2125 (audit A25-04 / plan S-4): the kill-switch
  /// hold is in place — the session died unexpectedly and
  /// its TUN is held as a blackhole (traffic blocked, never
  /// direct) until the user disconnects or reconnects.
  final bool killSwitchHeld;

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
    this.method = '',
    this.wedged = false,
    this.startReturned = true,
    this.killSwitchHeld = false,
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
    required int mtu,
    bool ipv6,
    List<String> rungs,
    String compartment,
    List<String> cleanAkamai,
    List<String> cleanFastly,
    bool disableTimeouts,
    bool cdnFront,
    bool killSwitch,
    bool shiroBootstrap,
    bool strongMode,
  });

  Future<void> stop();

  Future<PsiphonState> state();

  /// The external watchdog's firing (build 2088): record the
  /// wedged start's evidence, kill it, publish the wedge.
  /// Best-effort: the returned map says what was found/killed;
  /// null when the call itself failed.
  Future<Map<String, dynamic>?> externalWatchdog();

  /// The exit IP/country of the running tunnel, asked through
  /// the tunnel itself. Best-effort: null on any failure.
  Future<Map<String, String>?> exitInfo();

  /// The engine's folder (settings, the core's data root, logs).
  Future<Directory> workDir();
}

/// Android: the Kotlin PsiphonVpnService over the app channel
/// (build 2157's argument set, forwarded whole).
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
    bool ipv6 = true,
    List<String> rungs = const [],
    String compartment = '',
    List<String> cleanAkamai = const [],
    List<String> cleanFastly = const [],
    bool disableTimeouts = false,
    bool cdnFront = false,
    bool killSwitch = false,
    bool shiroBootstrap = false,
    bool strongMode = false,
  }) =>
      _channel.invokeMethod('psiphonSetOn', {
        'on': true,
        'vpnMode': vpnMode,
        'region': region,
        'upstream': upstream,
        'protocols': protocols,
        'dns': dns,
        'mtu': mtu,
        'ipv6': ipv6,
        'rungs': rungs,
        'compartment': compartment,
        'cleanAkamai': cleanAkamai,
        'cleanFastly': cleanFastly,
        'disableTimeouts': disableTimeouts,
        'cdnFront': cdnFront,
        'killSwitch': killSwitch,
        'shiroBootstrap': shiroBootstrap,
        'strongMode': strongMode,
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
      method: m['method'] as String? ?? '',
      wedged: m['wedged'] as bool? ?? false,
      startReturned: m['startReturned'] as bool? ?? true,
      killSwitchHeld: m['killSwitchHeld'] as bool? ?? false,
    );
  }

  @override
  Future<Map<String, dynamic>?> externalWatchdog() async {
    try {
      return await _channel.invokeMapMethod<String, dynamic>(
        'psiphonExternalWatchdog',
      );
    } catch (_) {
      return null;
    }
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

  /// Historical: the AAR core's local HTTP proxy port. The MLM
  /// host (build 2091) configures no local HTTP proxy on
  /// Android; the Windows ConsoleClient host configures its
  /// pair port as before (its exit-IP lookup rides it), so
  /// the constant stays as the record of the port pair.
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
    bool ipv6 = true,
    List<String> rungs = const [],
    String compartment = '',
    List<String> cleanAkamai = const [],
    List<String> cleanFastly = const [],
    bool disableTimeouts = false,
    bool cdnFront = false,
    bool killSwitch = false,
    bool shiroBootstrap = false,
    bool strongMode = false,
  }) =>
      backend.setOn(
        vpnMode: vpnMode,
        region: region,
        upstream: upstream,
        protocols: protocols,
        dns: dns,
        mtu: mtu,
        ipv6: ipv6,
        rungs: rungs,
        compartment: compartment,
        cleanAkamai: cleanAkamai,
        cleanFastly: cleanFastly,
        disableTimeouts: disableTimeouts,
        cdnFront: cdnFront,
        killSwitch: killSwitch,
        shiroBootstrap: shiroBootstrap,
        strongMode: strongMode,
      );

  static Future<void> stop() => backend.stop();

  static Future<PsiphonState> state() => backend.state();

  static Future<Map<String, dynamic>?> externalWatchdog() =>
      backend.externalWatchdog();

  static Future<Map<String, String>?> exitInfo() => backend.exitInfo();

  static Future<Directory> workDir() => backend.workDir();
}
