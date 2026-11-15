/// The Dart side of the Psiphon engine's platform calls (the same
/// 'app/android' channel MainActivity serves).

import 'package:flutter/services.dart';

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

class PsiphonPlatform {
  static const _channel = MethodChannel('app/android');

  /// The engine's fixed local proxy ports (PsiphonConstants.kt).
  static const socksPort = 11808;
  static const httpPort = 11809;

  static Future<void> setOn({
    required bool vpnMode,
    required String region,
    required String upstream,
    required List<String> protocols,
    required String dns,
    required int mtu,
    // Build 2057 (audit F-M4): capture IPv6 in the TUN only when
    // true. Optional (default true) so the Xray underlay call site
    // in xray_controller.dart keeps compiling unchanged — it runs
    // proxy-only, where the flag has no effect.
    bool ipv6 = true,
    // Build 2065: the strategy ladder. All optional with the
    // pre-2065 defaults, so the Xray underlay call site keeps its
    // single-attempt behaviour unchanged.
    List<String> rungs = const [],
    String compartment = '',
    List<String> cleanAkamai = const [],
    List<String> cleanFastly = const [],
    bool disableTimeouts = false,
    bool cdnFront = false,
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
      });

  static Future<void> stop() => _channel.invokeMethod('psiphonStop');

  static Future<PsiphonState> state() async {
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
    );
  }

  /// The exit IP/country of the running Psiphon tunnel, asked through
  /// its own SOCKS proxy. Best-effort: null on any failure.
  static Future<Map<String, String>?> exitInfo() async {
    try {
      final m =
          await _channel.invokeMapMethod<String, dynamic>('psiphonExitInfo');
      if (m == null) return null;
      return m.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return null;
    }
  }
}
