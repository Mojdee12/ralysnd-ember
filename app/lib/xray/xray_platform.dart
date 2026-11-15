/// The Dart side of the Xray engine's platform calls (the same
/// 'app/android' channel MainActivity serves).

import 'package:flutter/services.dart';

import 'awg_uapi.dart';

class XrayState {
  final bool running;
  final String name;
  final int sinceMs;
  final int upBytes;
  final int downBytes;

  /// Watchdog revivals of a wedged core this session, and the last
  /// watchdog event (empty when the core is healthy).
  final int coreRestarts;
  final String coreProblem;

  /// Chain state (build 2029A): a Psiphon underlay is chained
  /// under this session, and the ChainSupervisor's last word
  /// about it (a revival, or the reason the session was torn
  /// down). Empty when the underlay is healthy or absent.
  final bool chainUnderlay;
  final String chainProblem;

  /// AmneziaWG session state (build 2040, queue 2h): the live
  /// tunnel is the userspace device (no Xray core, no SOCKS
  /// port), and the handshake/transfer figures parsed out of
  /// its UAPI dump — the handshake age is what proves the
  /// obfuscated tunnel carries traffic. -1/0 when this is not
  /// an AWG session, or the peer never answered.
  final bool awg;
  final int awgHandshakeAgeSec;
  final int awgRxBytes;
  final int awgTxBytes;

  /// Rotation generation (build 2054, audit F-H2): the native
  /// rotate counter, advanced exactly once per successful
  /// rotateCore. A proof loop must see it advance before
  /// believing a tunnelCheck after a rotate — otherwise the
  /// still-running OLD core answers the probe.
  final int rotationGen;

  /// Kill switch (build 2063, feature queue #3): the native
  /// service is holding a dead session's TUN as a blackhole —
  /// traffic is blocked, not direct — while the reconnect
  /// waits or the budget is spent. False in every earlier
  /// build and whenever no hold is active.
  final bool killSwitchHeld;

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
    this.awg = false,
    this.awgHandshakeAgeSec = -1,
    this.awgRxBytes = 0,
    this.awgTxBytes = 0,
    this.rotationGen = 0,
    this.killSwitchHeld = false,
  });
  static const stopped = XrayState(
    running: false,
    name: '',
    sinceMs: 0,
    upBytes: 0,
    downBytes: 0,
  );
}

class XrayPlatform {
  static const _channel = MethodChannel('app/android');

  /// The system file picker for one small text profile file
  /// (a WireGuard `.conf`): `{name, content}`, or null when the
  /// user cancels (build 2050 — the picker machinery the
  /// OpenVPN flow built, generalized in MainActivity). An
  /// unreadable or oversize file throws a [PlatformException]
  /// (`pick_read_failed` / `file-too-large`) — never a silent
  /// null.
  static Future<Map<String, String>?> pickTextFile() async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>('pickTextFile');
    if (m == null) return null;
    return {
      'name': (m['name'] as String?) ?? 'profile.conf',
      'content': (m['content'] as String?) ?? '',
    };
  }

  /// Starts the tunnel. With [underlay] = 'psiphon' the
  /// session is chained (build 2029A): the Psiphon core must
  /// ALREADY be running proxy-only (the controller starts and
  /// health-checks it first); the native side then supervises
  /// it for the session's life and reaps it at the end. The
  /// underlay parameters ride along so the supervisor can
  /// respawn it exactly as it was started.
  static Future<void> setOn({
    required String config,
    required String name,
    required int socksPort,
    required String dns,
    required bool ipv6,
    required int mtu,
    String underlay = 'none',
    String underlayRegion = '',
    String underlayUpstream = '',
    List<String> underlayProtocols = const [],
    List<String> warpArgs = const [],
    // LAN sharing (build 2062, feature queue #2): the SOCKS
    // credentials the tun2socks bridge must present to the
    // core's password-protected SOCKS inbound. ''/'' is the
    // noauth behaviour of every earlier build.
    String socksUser = '',
    String socksPass = '',
    // Kill switch (build 2063, feature queue #3).
    bool killSwitch = false,
    // DNSTT underlay + WireGuard over WebSocket (build 2072):
    // the helpers' command lines ride along so the service
    // can supervise and respawn them exactly as started.
    List<String> dnsttArgs = const [],
    bool wgWstunnel = false,
    List<String> wstunnelArgs = const [],
  }) => _channel.invokeMethod('xraySetOn', {
    'on': true,
    'config': config,
    'name': name,
    'socksPort': socksPort,
    'dns': dns,
    'ipv6': ipv6,
    'mtu': mtu,
    'underlay': underlay,
    'underlayRegion': underlayRegion,
    'underlayUpstream': underlayUpstream,
    'underlayProtocols': underlayProtocols,
    'warpArgs': warpArgs,
    'socksUser': socksUser,
    'socksPass': socksPass,
    'killSwitch': killSwitch,
    'dnsttArgs': dnsttArgs,
    'wgWstunnel': wgWstunnel,
    'wstunnelArgs': wstunnelArgs,
  });

  /// Starts the standalone WARP tunnel (build 2030): the
  /// EmberWarp core must ALREADY be running and ready (the
  /// controller starts and health-checks it first); the
  /// service brings the TUN up against the core's SOCKS port
  /// with no Xray process, supervises the core, and reaps it
  /// when the session ends.
  static Future<void> setOnWarp({
    required String name,
    required String dns,
    required bool ipv6,
    required int mtu,
    List<String> warpArgs = const [],
    // Kill switch (build 2063, feature queue #3).
    bool killSwitch = false,
  }) => _channel.invokeMethod('xraySetOnWarp', {
    'on': true,
    'name': name,
    'dns': dns,
    'ipv6': ipv6,
    'mtu': mtu,
    'warpArgs': warpArgs,
    'killSwitch': killSwitch,
  });

  /// Starts the AmneziaWG tunnel (build 2040, queue 2h): the
  /// service brings the TUN up and hands its fd to the
  /// userspace device in libwg-go.so. [settings] is the UAPI
  /// string (see awg_uapi.dart); [addresses] is the profile's
  /// tunnel addresses ("ip/prefix" comma-separated, '' when the
  /// profile has none — the service then uses its fixed ones).
  static Future<void> setOnAwg({
    required String settings,
    required String name,
    required String addresses,
    required String dns,
    required bool ipv6,
    required int mtu,
  }) => _channel.invokeMethod('awgSetOn', {
    'on': true,
    'settings': settings,
    'name': name,
    'addresses': addresses,
    'dns': dns,
    'ipv6': ipv6,
    'mtu': mtu,
  });

  /// How long [rotateConfig] waits for the rotation
  /// generation to advance before giving up. A healthy rotate
  /// (kill + port-free + spawn + port wait) takes seconds;
  /// the 30 s bound covers the native worst case. Tests
  /// shorten it — it is a seam, not a behaviour.
  static Duration rotateGenerationTimeout = const Duration(seconds: 30);

  /// Replaces the running core's config and respawns ONLY the
  /// core subprocess (build 2029A, watchdog shape rotation):
  /// the TUN interface and its bridge are untouched. False
  /// when no session is running to rotate.
  ///
  /// Build 2054 (audit F-H2): the channel answers when the
  /// rotate is ACCEPTED, not when the new core serves — the
  /// old core answers tunnelCheck until the rotate thread
  /// kills it, so a bare `true` used to bless a switch whose
  /// new core then failed to start. This now waits for the
  /// native rotation generation to advance (a proof the new
  /// core is the one serving) before reporting success, and
  /// returns false when it never advances or the session dies
  /// meanwhile.
  static Future<bool> rotateConfig(String config) async {
    int before = 0;
    try {
      before = (await state()).rotationGen;
    } catch (_) {
      before = 0;
    }
    bool accepted;
    try {
      final v = await _channel.invokeMethod<bool>('xrayRotateConfig', {
        'config': config,
      });
      accepted = v ?? false;
    } catch (_) {
      return false;
    }
    if (!accepted) return false;
    final deadline = DateTime.now().add(rotateGenerationTimeout);
    while (DateTime.now().isBefore(deadline)) {
      XrayState s;
      try {
        s = await state();
      } catch (_) {
        return false;
      }
      if (!s.running) return false;
      if (s.rotationGen > before) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  static Future<void> stop() => _channel.invokeMethod('xrayStop');

  static Future<XrayState> state() async {
    final m = await _channel.invokeMapMethod<String, dynamic>('xrayState');
    if (m == null) return XrayState.stopped;
    final awg = m['awg'] as bool? ?? false;
    // The handshake/transfer figures come out of the device's
    // UAPI dump (build 2040); a non-AWG session has none.
    final awgStatus = awg
        ? parseAwgStatus(
            m['awgConfig'] as String? ?? '',
            nowMs: DateTime.now().millisecondsSinceEpoch,
          )
        : AwgStatus.never;
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
      awg: awg,
      awgHandshakeAgeSec: awgStatus.handshakeAgeSec,
      awgRxBytes: awgStatus.rxBytes,
      awgTxBytes: awgStatus.txBytes,
      rotationGen: (m['rotationGen'] as num?)?.toInt() ?? 0,
      killSwitchHeld: m['killSwitchHeld'] as bool? ?? false,
    );
  }

  /// The endurance qualification of a test config (build
  /// 2029A): three real requests at t=0, +2.5 s and +5.4 s
  /// over ONE keep-alive connection through a throwaway core —
  /// a fresh socket per probe would not notice a session that
  /// freezes seconds after the handshake, which is the
  /// filtered-network failure this exists to catch. Returns
  /// {'p0': ms, 'p1': ms, 'p2': ms, 'held': 1} with -1 for a
  /// probe that failed; null when the test could not run.
  static Future<Map<String, int>?> endurance(String testConfig) async {
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

  /// This network's fingerprint material for the
  /// winning-shape cache: {'type': wifi|cellular|…, 'operator':
  /// name}. Best-effort: null when the platform cannot say.
  static Future<Map<String, String>?> networkFingerprint() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'networkFingerprint',
      );
      if (m == null) return null;
      return m.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return null;
    }
  }

  /// Validates [config] with the bundled core itself
  /// (`xray run -test`): null when the core accepts it, the
  /// core's rejection text otherwise. Used by the profile
  /// editor's save gate for shaped configs (build 2026).
  static Future<String?> validateConfig(String config) async {
    try {
      return await _channel.invokeMethod<String>('xrayValidateConfig', {
        'config': config,
      });
    } catch (e) {
      return 'config validation unavailable: $e';
    }
  }

  /// One real proxied request through the tunnel ALREADY
  /// running on [socksPort] (the live service's SOCKS inbound):
  /// its delay in ms, or -1 when the tunnel does not answer.
  /// The adaptive failover's health probe (build 2026).
  static Future<int> tunnelCheck(
    int socksPort, {
    // LAN sharing (build 2062): the credentials for a
    // password-protected SOCKS inbound; ''/'' is noauth.
    String socksUser = '',
    String socksPass = '',
  }) async {
    try {
      final v = await _channel.invokeMethod<int>('xrayTunnelCheck', {
        'socksPort': socksPort,
        'socksUser': socksUser,
        'socksPass': socksPass,
      });
      return v ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// The real through-tunnel delay (ms) of a test config, or -1.
  static Future<int> measureDelay(String testConfig) async {
    final v = await _channel.invokeMethod<int>('xrayMeasureDelay', {
      'config': testConfig,
    });
    return v ?? -1;
  }

  /// [measureDelay] plus the exit identity observed through the
  /// same throwaway core (build 2032): {'ms', 'ip',
  /// 'countryCode'} — ip/countryCode '' when unobserved.
  static Future<Map<String, dynamic>> measureDelayEx(String testConfig) async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>(
      'xrayMeasureDelayEx',
      {'config': testConfig},
    );
    if (m == null) return const {'ms': -1, 'ip': '', 'countryCode': ''};
    return m.map((k, v) => MapEntry(k.toString(), v));
  }

  /// The through-tunnel download rate (bytes/s) of a test config, or -1.
  static Future<int> speedTest(String testConfig) async {
    final v = await _channel.invokeMethod<int>('xraySpeedTest', {
      'config': testConfig,
    });
    return v ?? -1;
  }

  /// The sandbox config test (build 2061, feature queue #1):
  /// ONE throwaway core proves the config end to end — delay,
  /// hold, exit identity — on a free port, without touching the
  /// live tunnel. Never null: a channel failure returns a failed
  /// map, so the caller always has words for what happened.
  static Future<Map<String, dynamic>> sandboxTest(String testConfig) async {
    try {
      final m = await _channel.invokeMapMethod<dynamic, dynamic>(
        'xraySandboxTest',
        {'config': testConfig},
      );
      if (m == null) {
        return const {'ok': 0, 'error': 'the sandbox test did not answer'};
      }
      return m.map((k, v) => MapEntry(k.toString(), v));
    } catch (e) {
      return {'ok': 0, 'error': 'the sandbox test did not answer: $e'};
    }
  }

  /// The running core's "proxy" outbound counters since the previous
  /// read (the native side reads them through the core's stats API
  /// and resets them, so each result is a delta): {'up': n, 'down': n}
  /// in bytes. Best-effort: null on any failure.
  static Future<Map<String, int>?> trafficStats(int apiPort) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('xrayStats', {
        'apiPort': apiPort,
      });
      if (m == null) return null;
      return {
        'up': (m['up'] as num?)?.toInt() ?? 0,
        'down': (m['down'] as num?)?.toInt() ?? 0,
      };
    } catch (_) {
      return null;
    }
  }

  /// The exit IP/country of the tunnel running on [socksPort], asked
  /// through the tunnel itself. Best-effort: null on any failure.
  static Future<Map<String, String>?> exitInfo(
    int socksPort, {
    // LAN sharing (build 2062): the credentials for a
    // password-protected SOCKS inbound; ''/'' is noauth.
    String socksUser = '',
    String socksPass = '',
  }) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'xrayExitInfo',
        {
          'socksPort': socksPort,
          'socksUser': socksUser,
          'socksPass': socksPass,
        },
      );
      if (m == null) return null;
      return m.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return null;
    }
  }
}
