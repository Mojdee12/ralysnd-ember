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

  /// The last start wedged inside the core library and the
  /// service's process exited over it (build 2087, diagnosis
  /// F1/F3). The connect path fails fast on this instead of
  /// waiting out a session that can never connect.
  final bool wedged;

  /// Whether the service's current start call has RETURNED
  /// from the core library (build 2088). False while the
  /// call is still inside the library — the wedge frontier.
  /// The external watchdog fires only on a start that is
  /// still inside past its deadline; a returned start whose
  /// establishment is merely slow never fires it. Defaults
  /// to true (nothing outstanding) for snapshots written
  /// before build 2088.
  final bool startReturned;

  /// Build 2125 (audit A25-04 / plan S-4): the kill-switch
  /// hold is in place — the session died unexpectedly and
  /// its TUN is held as a blackhole (traffic blocked,
  /// never direct) until the user disconnects or
  /// reconnects.
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

class PsiphonPlatform {
  static const _channel = MethodChannel('app/android');

  /// The engine's fixed local proxy ports (PsiphonConstants.kt).
  static const socksPort = 11808;

  /// Historical: the AAR core's local HTTP proxy port. The
  /// MLM host (build 2091) configures no local HTTP proxy —
  /// the core's local proxies are disabled in its config —
  /// so nothing listens here; the constant stays as the
  /// record of the port pair.
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
    // Build 2125 (audit A25-04 / S-4): the kill switch —
    // optional with the OFF default, so the Xray underlay
    // call site keeps compiling unchanged (a chain
    // underlay owns no TUN and is never held).
    bool killSwitch = false,
    // Build 2129 (Leg 2): the Shiro bootstrap + strong
    // mode — optional with OFF defaults, so the Xray
    // underlay call site keeps its 2128 behaviour.
    bool shiroBootstrap = false,
    bool strongMode = false,
  }) async {
    // Build 2091: the provider is the MLM AAR core again
    // (see PsiphonVpnService) — the 2089/2090 sidecar's
    // config write is retired with it (the Dart-side config
    // builder psiphon_sidecar_config.dart is deleted). The
    // service builds the core's config itself, from the same
    // arguments this call carries across the channel, and the
    // ladder arguments above are read by the service's MLM
    // host. There is nothing to write before the start.
    await _channel.invokeMethod('psiphonSetOn', {
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
  }

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
      wedged: m['wedged'] as bool? ?? false,
      startReturned: m['startReturned'] as bool? ?? true,
      killSwitchHeld: m['killSwitchHeld'] as bool? ?? false,
    );
  }

  /// Build 2088: fires the main process's external watchdog
  /// (see psiphon_watchdog.dart for the decision that leads
  /// here). The native side finds the :psiphon process,
  /// records its /proc thread dump in crash.log, kills it,
  /// and publishes the wedged state this class's [state]
  /// then reports. Best-effort: the returned map says what
  /// was found/killed; null when the call itself failed —
  /// the connect path's own waits remain the backstop.
  static Future<Map<String, dynamic>?> externalWatchdog() async {
    try {
      return await _channel.invokeMapMethod<String, dynamic>(
        'psiphonExternalWatchdog',
      );
    } catch (_) {
      return null;
    }
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
