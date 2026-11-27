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
/// The method set is Android build 2157's (the W1 sync): the 2032
/// parity contract (chain underlays on [XrayBackend.setOn], the
/// standalone EmberWarp tunnel, config rotation, tunnel checks, the
/// extended delay result, endurance, network fingerprint, config
/// validation) plus everything Android gained 2039→2157 — the
/// AmneziaWG leg ([XrayBackend.setOnAwg]), LAN-sharing SOCKS
/// credentials, the kill switch flag, the DNSTT/wstunnel/OLCRTC
/// underlay argument lists, the tunnel-bridge choice, upload speed,
/// the sandbox test, the service check and the per-server DNS ping
/// family. Where a backend has no such machinery its implementation
/// says so honestly (see the Windows backend's notes): nothing here
/// fakes a result.

import 'dart:io';

import 'package:flutter/services.dart';

import '../core/android_core.dart';
import '../core/system_ui_flight.dart';
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

  /// AmneziaWG session state (Android build 2040): the live
  /// tunnel is the WG Tunnel backend's device (no Xray core, no
  /// SOCKS port), and the handshake/transfer figures the native
  /// side computes from the backend's own ActiveConfig (build
  /// 2104). The handshake age is display only: it never gates a
  /// connect or tears a session down. -1/0 when this is not an
  /// AWG session, or the peer has not answered yet. On Windows
  /// the engine is the AmneziaWG client's per-tunnel service
  /// (W2): the same fields are reported from the service's
  /// state and its UAPI pipe, and a failed start is recorded
  /// in [awgProblemSeq]/[coreProblem] so the controller's
  /// fallback walk proceeds exactly as it does for an Android
  /// start failure.
  final bool awg;
  final int awgHandshakeAgeSec;
  final int awgRxBytes;
  final int awgTxBytes;

  /// The AWG engine's problem sequence (Android build 2104):
  /// incremented every time a NEW problem is recorded, even when
  /// its text is identical to the previous one — the connect walk
  /// compares sequences, not strings.
  final int awgProblemSeq;

  /// The WG Tunnel engine's notification-stop sequence (Android
  /// build 2106). Always 0 on Windows (no such notification).
  final int awgUserStopSeq;

  /// Rotation generation (Android build 2054): advanced exactly
  /// once per successful rotate. A proof loop must see it advance
  /// before believing a tunnelCheck after a rotate — otherwise
  /// the still-running OLD core answers the probe. The Windows
  /// backend counts its own successful rotates.
  final int rotationGen;

  /// Kill switch (Android build 2063): the native service is
  /// holding a dead session's TUN as a blackhole while the
  /// reconnect waits. The Windows kill switch is W4 scope; the
  /// backend reports false.
  final bool killSwitchHeld;

  /// Paused (Android build 2081): the tunnel was stopped from its
  /// own notification Pause action. Always false on Windows.
  final bool paused;

  /// Stopped by the user (Android build 2087): the last stop
  /// arrived through the native stop action, so the poll must end
  /// the auto-reconnect expectation. Always false on Windows (the
  /// Dart side owns every stop there).
  final bool userStopped;

  /// A tunnel is still registered with the WG Tunnel backend
  /// (Android build 2110). Always false on Windows.
  final bool awgTunnelPresent;

  /// Data-plane proof (Android build 2116, audit AB-01): a plain
  /// Xray session is adopted only after a request has actually
  /// carried through the tunnel. The platform knows nothing of
  /// the proof; the controller stamps this onto the sample for
  /// the session it verified (matched by [sinceMs]), so
  /// "Connected" in the UI means traffic flowed, not merely that
  /// the service is running. False for every sample the platform
  /// returns directly.
  final bool verified;

  /// The backend's last failure, in words ('' when none). Only the
  /// Windows backend records one; the controller surfaces it so a
  /// failed start/test is diagnosable instead of silent.
  final String lastError;

  /// The loopback SOCKS port the running session actually bound
  /// (0 when stopped or unknown). The Windows backend falls back
  /// to a free port when the configured one is taken (another
  /// proxy client, a leftover core), so this can differ from the
  /// setting. Android reports 0 (its service owns the port).
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
    this.awg = false,
    this.awgHandshakeAgeSec = -1,
    this.awgRxBytes = 0,
    this.awgTxBytes = 0,
    this.awgProblemSeq = 0,
    this.awgUserStopSeq = 0,
    this.rotationGen = 0,
    this.killSwitchHeld = false,
    this.paused = false,
    this.userStopped = false,
    this.awgTunnelPresent = false,
    this.verified = false,
    this.lastError = '',
    this.localPort = 0,
    this.note = '',
  });

  /// A copy of this sample with the data-plane proof flag set
  /// (Android build 2116, audit AB-01) — the controller stamps
  /// the session it verified; every other field is the backend
  /// sample's own.
  XrayState withVerified(bool value) => XrayState(
    running: running,
    name: name,
    sinceMs: sinceMs,
    upBytes: upBytes,
    downBytes: downBytes,
    coreRestarts: coreRestarts,
    coreProblem: coreProblem,
    chainUnderlay: chainUnderlay,
    chainProblem: chainProblem,
    awg: awg,
    awgHandshakeAgeSec: awgHandshakeAgeSec,
    awgRxBytes: awgRxBytes,
    awgTxBytes: awgTxBytes,
    awgProblemSeq: awgProblemSeq,
    awgUserStopSeq: awgUserStopSeq,
    rotationGen: rotationGen,
    killSwitchHeld: killSwitchHeld,
    paused: paused,
    userStopped: userStopped,
    awgTunnelPresent: awgTunnelPresent,
    verified: value,
    lastError: lastError,
    localPort: localPort,
    note: note,
  );
  static const stopped = XrayState(
    running: false,
    name: '',
    sinceMs: 0,
    upBytes: 0,
    downBytes: 0,
  );
}

/// One platform's Xray engine. [setOn]'s [dns]/[ipv6]/[mtu] are
/// the Android TUN builder's inputs; a backend without a TUN
/// layer of that shape accepts and documents them as unused (the
/// config JSON already carries DNS). The chain underlay arguments
/// ([underlay] and friends, [warpArgs], [dnsttArgs], [wstunnelArgs],
/// [olcrtcArgs]) tell the Android service to supervise the underlay
/// it starts; on Windows the controller itself starts the underlay
/// engines (Psiphon / EmberWarp Dart backends), the chain wiring
/// already lives in the config's dialerProxy, and the Windows
/// backend accepts the arguments for contract parity.
abstract class XrayBackend {
  Future<void> setOn({
    required String config,
    required String name,
    required int socksPort,
    required String dns,
    required bool ipv6,
    required int mtu,
    bool tunCapture = false,
    String underlay = 'none',
    String underlayRegion = '',
    String underlayUpstream = '',
    List<String> underlayProtocols = const [],
    List<String> warpArgs = const [],
    // LAN sharing (Android build 2062): the SOCKS credentials the
    // tun2socks bridge must present to the core's
    // password-protected SOCKS inbound. ''/'' is noauth.
    String socksUser = '',
    String socksPass = '',
    // Kill switch (Android build 2063).
    bool killSwitch = false,
    // DNSTT underlay + WireGuard over WebSocket (Android build
    // 2072) and the OLCRTC underlay (build 2134): the helpers'
    // command lines, for supervision + respawn on Android.
    List<String> dnsttArgs = const [],
    bool wgWstunnel = false,
    List<String> wstunnelArgs = const [],
    List<String> olcrtcArgs = const [],
    // Tunnel bridge (Android build 2155): 'hev' or 'tunlink'.
    String bridge = 'hev',
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
    required int mtu,
    bool tunCapture = false,
    List<String> warpArgs = const [],
    // Kill switch (Android build 2063).
    bool killSwitch = false,
  });

  /// Starts the AmneziaWG tunnel (Android build 2040): [settings]
  /// is the profile's canonical .conf text, which the Android
  /// side parses with the WG Tunnel backend's own parser.
  /// Windows has no WG Tunnel engine in W1: the backend records
  /// the refusal as a new AWG problem (sequence advanced,
  /// [XrayState.coreProblem] worded) and returns, so the
  /// controller's walk falls back to the plain Xray WireGuard leg
  /// exactly as it does for an Android engine start failure —
  /// the Amnezia parameters are then not applied, and the
  /// profile's own diagnostics say so.
  Future<void> setOnAwg({
    required String settings,
    required String name,
    required String addresses,
    required String dns,
    required bool ipv6,
    required bool ipv4,
    required int mtu,
    bool killSwitch = false,
  });

  /// Replaces the running core's config and respawns ONLY the
  /// core subprocess (build 2029A, watchdog shape rotation): the
  /// TUN interface and its bridge are untouched. False when no
  /// session is running to rotate. The facade layers the
  /// rotation-generation proof (Android build 2054) over this raw
  /// accept: see [XrayPlatform.rotateConfig].
  Future<bool> rotateConfig(String config);

  Future<void> stop();

  Future<XrayState> state();

  /// A single through-tunnel connectivity probe of the RUNNING
  /// session (ms), or -1 when it does not answer. [socksUser]/
  /// [socksPass] are the LAN-sharing credentials for a
  /// password-protected SOCKS inbound (Android build 2062).
  Future<int> tunnelCheck(
    int socksPort, {
    String socksUser = '',
    String socksPass = '',
  });

  /// The real through-tunnel delay (ms) of a test config, or -1.
  /// (The facade no longer exposes this since Android build 2095
  /// — [measureDelayEx] is the only live path; the backends keep
  /// it as their own building block.)
  Future<int> measureDelay(String testConfig);

  /// The extended delay result plus the exit identity observed
  /// through the same throwaway core (Android build 2032):
  /// {'ms', 'error'} on the Windows backend's port of the tester,
  /// {'ms', 'ip', 'countryCode'} from the Android tester — the
  /// controller reads the keys it needs. [rounds]/[budgetMs]/
  /// [timeoutMs] are Android build 2109's knobs (the bulk
  /// Test-All pass asks for one round under a budget; the
  /// `delayTestTimeoutSec` setting, 8000 by default).
  Future<Map<String, dynamic>> measureDelayEx(
    String testConfig, {
    int rounds = 2,
    int budgetMs = 0,
    int timeoutMs = 8000,
  });

  /// The endurance qualification of a test config (build 2029A):
  /// {'p0': ms, 'p1': ms, 'p2': ms, 'held': 1} with -1 for a probe
  /// that failed; null when the test could not run.
  Future<Map<String, int>?> endurance(String testConfig);

  /// The through-tunnel download rate (bytes/s) of a test config,
  /// or -1.
  Future<int> speedTest(String testConfig);

  /// The through-tunnel UPLOAD rate (bytes/s) of a test config,
  /// or -1 (Android build 2149): the download test's mirror.
  Future<int> speedTestUp(String testConfig);

  /// The sandbox config test (Android build 2061): ONE throwaway
  /// core proves the config end to end — delay, hold, exit
  /// identity — on a free port, without touching the live tunnel.
  /// Never null: a failure returns a failed map
  /// ({'ok': 0, 'error': words}), so the caller always has words.
  Future<Map<String, dynamic>> sandboxTest(
    String testConfig, {
    int timeoutMs = 8000,
  });

  /// The proxied service reachability check (Android build 2091):
  /// ONE throwaway core asks each host in [hosts] for a real HTTPS
  /// HEAD through the config. Never null; the map is
  /// {'ok': 1/0, 'error': '', 'results': {host: {...}}}.
  Future<Map<String, dynamic>> serviceCheck(
    String testConfig,
    List<String> hosts,
  );

  /// Per-server DNS ping (Android build 2149): every server in
  /// [servers] is asked one real DNS query and timed individually,
  /// through a throwaway instance of [testConfig]. The result maps
  /// each requested server to its latency in ms; -1 = asked, no
  /// answer; -2 = not a probed kind. Never throws.
  Future<Map<String, int>> dnsPing(
    String testConfig,
    List<String> servers, {
    int timeoutMs = 5000,
  });

  /// [dnsPing] through an already-running tunnel's SOCKS port.
  Future<Map<String, int>> dnsPingViaPort(
    int socksPort,
    List<String> servers, {
    String socksUser = '',
    String socksPass = '',
    int timeoutMs = 5000,
  });

  /// [dnsPing] with no tunnel at all: the same questions asked
  /// directly from the device.
  Future<Map<String, int>> dnsPingDirect(
    List<String> servers, {
    int timeoutMs = 5000,
  });

  /// The device network's fingerprint (build 2032, the anti-filter
  /// shape cache's key): best-effort map, null when unavailable.
  Future<Map<String, String>?> networkFingerprint();

  /// Validates a config against the core: an error string, or
  /// null when the core accepts it / validation is unavailable.
  Future<String?> validateConfig(String config);

  /// The running core's "proxy" outbound counters since the
  /// previous read (the query resets them, so each result is a
  /// delta): {'up': n, 'down': n} in bytes. Best-effort: null on
  /// any failure.
  Future<Map<String, int>?> trafficStats(int apiPort);

  /// The exit IP/country of the tunnel running on [socksPort],
  /// asked through the tunnel itself. Best-effort: null on any
  /// failure. [socksUser]/[socksPass] are the LAN-sharing
  /// credentials (Android build 2062).
  Future<Map<String, String>?> exitInfo(
    int socksPort, {
    String socksUser = '',
    String socksPass = '',
  });

  /// The engine's working folder: profiles' state file, the
  /// running config, logs and geo data all live here.
  Future<Directory> workDir();
}

/// The Android backend: the same 'app/android' channel MainActivity
/// serves (XrayVpnService / XrayTester on the Kotlin side), at
/// Android build 2157's contract.
class AndroidXrayBackend implements XrayBackend {
  static const _channel = MethodChannel('app/android');

  @override
  Future<void> setOn({
    required String config,
    required String name,
    required int socksPort,
    required String dns,
    required bool ipv6,
    required int mtu,
    bool tunCapture = false,
    String underlay = 'none',
    String underlayRegion = '',
    String underlayUpstream = '',
    List<String> underlayProtocols = const [],
    List<String> warpArgs = const [],
    String socksUser = '',
    String socksPass = '',
    bool killSwitch = false,
    List<String> dnsttArgs = const [],
    bool wgWstunnel = false,
    List<String> wstunnelArgs = const [],
    List<String> olcrtcArgs = const [],
    String bridge = 'hev',
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
    'olcrtcArgs': olcrtcArgs,
    'bridge': bridge,
  });

  @override
  Future<void> setOnWarp({
    required String name,
    required String dns,
    required bool ipv6,
    required int mtu,
    bool tunCapture = false,
    List<String> warpArgs = const [],
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

  @override
  Future<void> setOnAwg({
    required String settings,
    required String name,
    required String addresses,
    required String dns,
    required bool ipv6,
    required bool ipv4,
    required int mtu,
    bool killSwitch = false,
  }) => _channel.invokeMethod('awgSetOn', {
    'on': true,
    'settings': settings,
    'name': name,
    'addresses': addresses,
    'dns': dns,
    'ipv6': ipv6,
    'ipv4': ipv4,
    'mtu': mtu,
    'killSwitch': killSwitch,
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
    final awg = m['awg'] as bool? ?? false;
    // The handshake/transfer figures are computed by the Kotlin
    // side from the backend's own ActiveConfig (build 2104); a
    // non-AWG session has none.
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
      awgHandshakeAgeSec: (m['awgHandshakeAgeSec'] as num?)?.toInt() ?? -1,
      awgRxBytes: (m['awgRxBytes'] as num?)?.toInt() ?? 0,
      awgTxBytes: (m['awgTxBytes'] as num?)?.toInt() ?? 0,
      awgProblemSeq: (m['awgProblemSeq'] as num?)?.toInt() ?? 0,
      awgUserStopSeq: (m['awgUserStopSeq'] as num?)?.toInt() ?? 0,
      rotationGen: (m['rotationGen'] as num?)?.toInt() ?? 0,
      killSwitchHeld: m['killSwitchHeld'] as bool? ?? false,
      paused: m['paused'] as bool? ?? false,
      userStopped: m['userStopped'] as bool? ?? false,
      awgTunnelPresent: m['awgTunnelPresent'] as bool? ?? false,
    );
  }

  @override
  Future<int> tunnelCheck(
    int socksPort, {
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

  @override
  Future<int> measureDelay(String testConfig) async {
    final v = await _channel.invokeMethod<int>('xrayMeasureDelay', {
      'config': testConfig,
    });
    return v ?? -1;
  }

  @override
  Future<Map<String, dynamic>> measureDelayEx(
    String testConfig, {
    int rounds = 2,
    int budgetMs = 0,
    int timeoutMs = 8000,
  }) async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>(
      'xrayMeasureDelayEx',
      {
        'config': testConfig,
        'rounds': rounds,
        'budgetMs': budgetMs,
        'timeoutMs': timeoutMs,
      },
    );
    if (m == null) return const {'ms': -1, 'ip': '', 'countryCode': ''};
    return m.map((k, v) => MapEntry(k.toString(), v));
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
  Future<int> speedTestUp(String testConfig) async {
    final v = await _channel.invokeMethod<int>('xraySpeedTestUp', {
      'config': testConfig,
    });
    return v ?? -1;
  }

  @override
  Future<Map<String, dynamic>> sandboxTest(
    String testConfig, {
    int timeoutMs = 8000,
  }) async {
    try {
      final m = await _channel.invokeMapMethod<dynamic, dynamic>(
        'xraySandboxTest',
        {'config': testConfig, 'timeoutMs': timeoutMs},
      );
      if (m == null) {
        return const {'ok': 0, 'error': 'the sandbox test did not answer'};
      }
      return m.map((k, v) => MapEntry(k.toString(), v));
    } catch (e) {
      return {'ok': 0, 'error': 'the sandbox test did not answer: $e'};
    }
  }

  @override
  Future<Map<String, dynamic>> serviceCheck(
    String testConfig,
    List<String> hosts,
  ) async {
    try {
      final m = await _channel.invokeMapMethod<dynamic, dynamic>(
        'xrayServiceCheck',
        {'config': testConfig, 'hosts': hosts},
      );
      if (m == null) {
        return const {'ok': 0, 'error': 'the service check did not answer'};
      }
      return m.map((k, v) => MapEntry(k.toString(), v));
    } catch (e) {
      return {'ok': 0, 'error': 'the service check did not answer: $e'};
    }
  }

  static Map<String, int> _dnsPingResults(
    Map<String, dynamic>? m,
    List<String> servers,
  ) {
    final raw = m?['results'];
    return {
      for (final s in servers)
        s: raw is Map && raw[s] is num ? (raw[s] as num).toInt() : -1,
    };
  }

  @override
  Future<Map<String, int>> dnsPing(
    String testConfig,
    List<String> servers, {
    int timeoutMs = 5000,
  }) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('xrayDnsPing', {
        'mode': 'config',
        'config': testConfig,
        'servers': servers,
        'timeoutMs': timeoutMs,
      });
      return _dnsPingResults(m, servers);
    } catch (_) {
      return {for (final s in servers) s: -1};
    }
  }

  @override
  Future<Map<String, int>> dnsPingViaPort(
    int socksPort,
    List<String> servers, {
    String socksUser = '',
    String socksPass = '',
    int timeoutMs = 5000,
  }) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('xrayDnsPing', {
        'mode': 'port',
        'socksPort': socksPort,
        'socksUser': socksUser,
        'socksPass': socksPass,
        'servers': servers,
        'timeoutMs': timeoutMs,
      });
      return _dnsPingResults(m, servers);
    } catch (_) {
      return {for (final s in servers) s: -1};
    }
  }

  @override
  Future<Map<String, int>> dnsPingDirect(
    List<String> servers, {
    int timeoutMs = 5000,
  }) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('xrayDnsPing', {
        'mode': 'direct',
        'servers': servers,
        'timeoutMs': timeoutMs,
      });
      return _dnsPingResults(m, servers);
    } catch (_) {
      return {for (final s in servers) s: -1};
    }
  }

  @override
  Future<Map<String, String>?> networkFingerprint() async {
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

  @override
  Future<String?> validateConfig(String config) async {
    try {
      return await _channel.invokeMethod<String>('xrayValidateConfig', {
        'config': config,
      });
    } catch (e) {
      return 'config validation unavailable: $e';
    }
  }

  @override
  Future<Map<String, int>?> trafficStats(int apiPort) async {
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

  @override
  Future<Map<String, String>?> exitInfo(
    int socksPort, {
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

  @override
  Future<Directory> workDir() async {
    final coreDir = await AndroidCore.dataDir();
    return Directory('${File(coreDir).parent.path}/xray');
  }
}

/// The facade the controller and UI call; see the file's doc comment.
class XrayPlatform {
  static XrayBackend? _backend;

  static XrayBackend get backend => _backend ??= Platform.isWindows
      ? WindowsXrayBackend()
      : AndroidXrayBackend();

  static const _channel = MethodChannel('app/android');

  // ---- file / share helpers (not engine calls) -------------------
  //
  // On Android these ride the same 'app/android' channel (the
  // picker machinery MainActivity serves; Android builds 2050/
  // 2095). On Windows the runner serves no file dialog in W1, so
  // the helpers take the honest no-handler shapes Android itself
  // defined for that case: pickTextFile throws the named
  // 'pick_unavailable' PlatformException (callers show "Could not
  // read that file" and the paste/link/QR import routes remain),
  // pickImageFile returns null, saveTextFile returns false (the
  // clipboard export path remains), and shareText copies to the
  // clipboard — the desktop share the 2038 UI always offered.

  /// The system share sheet for text (Android build 2095). On
  /// Windows: copies [text] to the clipboard.
  static Future<void> shareText(String text, {String title = ''}) async {
    if (Platform.isWindows) {
      await Clipboard.setData(ClipboardData(text: text));
      return;
    }
    SystemUiFlight.begin();
    try {
      await _channel.invokeMethod('shareText', {'text': text, 'title': title});
    } finally {
      SystemUiFlight.end();
    }
  }

  /// Saves [content] as a document the user places (Android build
  /// 2095). True when written; false on cancel/failure; null when
  /// a save is already open ('busy'). Windows (W1): false — no
  /// save dialog exists yet; callers keep their clipboard path.
  static Future<bool?> saveTextFile(String name, String content) async {
    if (Platform.isWindows) return false;
    SystemUiFlight.begin();
    try {
      final v = await _channel.invokeMethod<bool>('saveTextFile', {
        'name': name,
        'content': content,
      });
      return v ?? false;
    } on PlatformException catch (e) {
      if (e.code == 'busy') return null;
      rethrow;
    } finally {
      SystemUiFlight.end();
    }
  }

  /// Picks an image from the gallery and returns a cache-file
  /// PATH for the QR decoder; null when the pick was cancelled —
  /// or, on Windows (W1), when no picker exists.
  static Future<String?> pickImageFile() async {
    if (Platform.isWindows) return null;
    SystemUiFlight.begin();
    try {
      return await _channel.invokeMethod<String>('pickImageFile');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    } finally {
      SystemUiFlight.end();
    }
  }

  /// The system file picker for one small text profile file:
  /// `{name, content}`, or null when the user cancels. An
  /// unreadable or oversize file throws a [PlatformException] —
  /// never a silent null. Windows (W1): throws 'pick_unavailable',
  /// the same contract Android build 2097 defined for a platform
  /// without the picker.
  static Future<Map<String, String>?> pickTextFile() async {
    if (Platform.isWindows) {
      throw PlatformException(
        code: 'pick_unavailable',
        message: 'Could not read that file',
      );
    }
    SystemUiFlight.begin();
    try {
      final m = await _channel.invokeMapMethod<dynamic, dynamic>(
        'pickTextFile',
      );
      if (m == null) return null;
      return {
        'name': (m['name'] as String?) ?? 'profile.conf',
        'content': (m['content'] as String?) ?? '',
      };
    } on PlatformException catch (e) {
      if (e.code == 'busy') return null;
      rethrow;
    } on MissingPluginException {
      throw PlatformException(
        code: 'pick_unavailable',
        message: 'Could not read that file',
      );
    } finally {
      SystemUiFlight.end();
    }
  }

  // ---- engine calls ------------------------------------------------

  /// Windows-tree seam: the desktop capture choice
  /// (XraySettings.tunCapture) lives in the app's settings, which
  /// the platform-agnostic controller never reads — Android's
  /// controller therefore calls setOn/setOnWarp without a
  /// tunCapture argument. On Windows the app sets this resolver
  /// once at startup (main.dart) and an unspecified tunCapture
  /// resolves through it, restoring the 2038 behaviour exactly
  /// (the old controller passed the setting on every call). Null
  /// (Android, tests) resolves to false, which the Android
  /// backend ignores.
  static bool Function()? tunCaptureResolver;

  static bool _resolveTunCapture(bool? v) =>
      v ?? tunCaptureResolver?.call() ?? false;

  static Future<void> setOn({
    required String config,
    required String name,
    required int socksPort,
    required String dns,
    required bool ipv6,
    required int mtu,
    bool? tunCapture,
    String underlay = 'none',
    String underlayRegion = '',
    String underlayUpstream = '',
    List<String> underlayProtocols = const [],
    List<String> warpArgs = const [],
    String socksUser = '',
    String socksPass = '',
    bool killSwitch = false,
    List<String> dnsttArgs = const [],
    bool wgWstunnel = false,
    List<String> wstunnelArgs = const [],
    List<String> olcrtcArgs = const [],
    String bridge = 'hev',
  }) => backend.setOn(
    config: config,
    name: name,
    socksPort: socksPort,
    dns: dns,
    ipv6: ipv6,
    mtu: mtu,
    tunCapture: _resolveTunCapture(tunCapture),
    underlay: underlay,
    underlayRegion: underlayRegion,
    underlayUpstream: underlayUpstream,
    underlayProtocols: underlayProtocols,
    warpArgs: warpArgs,
    socksUser: socksUser,
    socksPass: socksPass,
    killSwitch: killSwitch,
    dnsttArgs: dnsttArgs,
    wgWstunnel: wgWstunnel,
    wstunnelArgs: wstunnelArgs,
    olcrtcArgs: olcrtcArgs,
    bridge: bridge,
  );

  static Future<void> setOnWarp({
    required String name,
    required String dns,
    required bool ipv6,
    required int mtu,
    bool? tunCapture,
    List<String> warpArgs = const [],
    bool killSwitch = false,
  }) => backend.setOnWarp(
    name: name,
    dns: dns,
    ipv6: ipv6,
    mtu: mtu,
    tunCapture: _resolveTunCapture(tunCapture),
    warpArgs: warpArgs,
    killSwitch: killSwitch,
  );

  static Future<void> setOnAwg({
    required String settings,
    required String name,
    required String addresses,
    required String dns,
    required bool ipv6,
    required bool ipv4,
    required int mtu,
    bool killSwitch = false,
  }) => backend.setOnAwg(
    settings: settings,
    name: name,
    addresses: addresses,
    dns: dns,
    ipv6: ipv6,
    ipv4: ipv4,
    mtu: mtu,
    killSwitch: killSwitch,
  );

  /// How long [rotateConfig] waits for the rotation generation to
  /// advance before giving up. A healthy rotate (kill + port-free
  /// + spawn + port wait) takes seconds; the 30 s bound covers the
  /// native worst case. Tests shorten it — it is a seam, not a
  /// behaviour.
  static Duration rotateGenerationTimeout = const Duration(seconds: 30);

  /// Replaces the running core's config and respawns ONLY the
  /// core subprocess: the TUN interface and its bridge are
  /// untouched. False when no session is running to rotate.
  ///
  /// Android build 2054 (audit F-H2): the backend answers when the
  /// rotate is ACCEPTED, not when the new core serves — the old
  /// core answers tunnelCheck until the rotate kills it, so a bare
  /// `true` used to bless a switch whose new core then failed to
  /// start. This waits for the backend's rotation generation to
  /// advance (a proof the new core is the one serving) before
  /// reporting success, and returns false when it never advances
  /// or the session dies meanwhile.
  static Future<bool> rotateConfig(String config) async {
    int before = 0;
    try {
      before = (await state()).rotationGen;
    } catch (_) {
      before = 0;
    }
    final accepted = await backend.rotateConfig(config);
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

  static Future<void> stop() => backend.stop();

  static Future<XrayState> state() async {
    // Android build 2116 (AB-11): catch→stopped — a thrown state
    // read escaped into refresh() and froze the card.
    try {
      return await backend.state();
    } catch (_) {
      return XrayState.stopped;
    }
  }

  static Future<int> tunnelCheck(
    int socksPort, {
    String socksUser = '',
    String socksPass = '',
  }) => backend.tunnelCheck(
    socksPort,
    socksUser: socksUser,
    socksPass: socksPass,
  );

  static Future<Map<String, dynamic>> measureDelayEx(
    String testConfig, {
    int rounds = 2,
    int budgetMs = 0,
    int timeoutMs = 8000,
  }) => backend.measureDelayEx(
    testConfig,
    rounds: rounds,
    budgetMs: budgetMs,
    timeoutMs: timeoutMs,
  );

  static Future<Map<String, int>?> endurance(String testConfig) =>
      backend.endurance(testConfig);

  static Future<int> speedTest(String testConfig) =>
      backend.speedTest(testConfig);

  static Future<int> speedTestUp(String testConfig) =>
      backend.speedTestUp(testConfig);

  static Future<Map<String, dynamic>> sandboxTest(
    String testConfig, {
    int timeoutMs = 8000,
  }) => backend.sandboxTest(testConfig, timeoutMs: timeoutMs);

  static Future<Map<String, dynamic>> serviceCheck(
    String testConfig,
    List<String> hosts,
  ) => backend.serviceCheck(testConfig, hosts);

  static Future<Map<String, int>> dnsPing(
    String testConfig,
    List<String> servers, {
    int timeoutMs = 5000,
  }) => backend.dnsPing(testConfig, servers, timeoutMs: timeoutMs);

  static Future<Map<String, int>> dnsPingViaPort(
    int socksPort,
    List<String> servers, {
    String socksUser = '',
    String socksPass = '',
    int timeoutMs = 5000,
  }) => backend.dnsPingViaPort(
    socksPort,
    servers,
    socksUser: socksUser,
    socksPass: socksPass,
    timeoutMs: timeoutMs,
  );

  static Future<Map<String, int>> dnsPingDirect(
    List<String> servers, {
    int timeoutMs = 5000,
  }) => backend.dnsPingDirect(servers, timeoutMs: timeoutMs);

  static Future<Map<String, String>?> networkFingerprint() =>
      backend.networkFingerprint();

  static Future<String?> validateConfig(String config) =>
      backend.validateConfig(config);

  static Future<Map<String, int>?> trafficStats(int apiPort) =>
      backend.trafficStats(apiPort);

  static Future<Map<String, String>?> exitInfo(
    int socksPort, {
    String socksUser = '',
    String socksPass = '',
  }) => backend.exitInfo(socksPort, socksUser: socksUser, socksPass: socksPass);

  static Future<Directory> workDir() => backend.workDir();
}
