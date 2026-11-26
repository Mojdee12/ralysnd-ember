/// The Dart side of the Xray engine's platform calls (the same
/// 'app/android' channel MainActivity serves).

import 'package:flutter/services.dart';

import '../core/system_ui_flight.dart';

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
  /// tunnel is the WG Tunnel backend's device (no Xray core,
  /// no SOCKS port), and the handshake/transfer figures the
  /// Kotlin side computes from the backend's own ActiveConfig
  /// (build 2104 — builds 2040–2103 parsed them here out of a
  /// raw UAPI dump, the parse that never matched the device's
  /// keys). The handshake age is display only since 2104: it
  /// never gates a connect or tears a session down. -1/0 when
  /// this is not an AWG session, or the peer has not answered
  /// yet.
  final bool awg;
  final int awgHandshakeAgeSec;
  final int awgRxBytes;
  final int awgTxBytes;

  /// Build 2104 (verification iteration 2, M3): the AWG
  /// engine's problem sequence — incremented on the Kotlin
  /// side every time a NEW problem is recorded, even when
  /// its text is identical to the previous one. _connectAwg
  /// compares sequences, not strings: a repeated identical
  /// start failure is a new event, not a stale echo.
  final int awgProblemSeq;

  /// Build 2106 (verification iteration 2, M-1): the WG
  /// Tunnel engine's notification-stop sequence, advanced
  /// ONLY by a stop that arrived through the tunnel
  /// notification's Disconnect (the native stop funnel
  /// marks every stop as a user stop, the app's own stops
  /// included, so [userStopped] alone cannot say WHO
  /// stopped a session). The peer walk compares it across
  /// its own teardown stop of a silent AWG leg: an advance
  /// means the user stopped the session mid-teardown.
  final int awgUserStopSeq;

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

  /// Paused (build 2081, verification V-8): the tunnel was
  /// stopped from its own notification Pause action while the
  /// service stays foreground with a Resume action — a held
  /// session, not a drop, so the poll must not treat it as an
  /// unexpected disconnect. False whenever no pause is held.
  final bool paused;

  /// Stopped by the user (build 2087, analysis A2): the last
  /// stop arrived through the native ACTION_STOP — the
  /// notification's Disconnect, or the app's own stop — so
  /// the poll must end the auto-reconnect expectation instead
  /// of treating the stop as an unexpected drop. Cleared
  /// natively by any fresh start.
  final bool userStopped;

  /// Build 2110 (wg-start diagnosis, defect 2): a tunnel is
  /// still REGISTERED with the WG Tunnel backend — the
  /// merged [running] flag flips false before the backend
  /// releases the VPN slot, so the engine-switch funnel
  /// (_awaitPreviousEngineDown) polls this to observe the
  /// previous engine fully down before starting the next.
  /// False whenever the backend holds no tunnel entry.
  final bool awgTunnelPresent;

  /// Data-plane proof (build 2116, audit AB-01): a plain
  /// Xray session is adopted only after a request has
  /// actually carried through the tunnel (the connect
  /// path's carries proof — the same pattern the WireGuard
  /// leg always had). The native state knows nothing of
  /// the proof; the controller stamps this onto the sample
  /// for the session it verified (matched by [sinceMs]),
  /// so "Connected" in the UI means traffic flowed, not
  /// merely that the VPN service is running. False for
  /// every sample the platform returns directly.
  final bool verified;

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
  });

  /// A copy of this sample with the data-plane proof flag
  /// set (build 2116, audit AB-01) — the controller stamps
  /// the session it verified; every other field is the
  /// native sample's own.
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
  );
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
  /// Build 2095 (V2Ray journey audit #20): the system share
  /// sheet for text — a backup used to leave the app ONLY
  /// through the clipboard.
  static Future<void> shareText(String text, {String title = ''}) async {
    // Build 2098 (post-2097 audit L8): the share sheet is a
    // system-UI flight like the pickers — build 2097's IMP-1
    // coverage missed this call, so sharing a backup could
    // re-lock the app over the sheet and dispose the page
    // that launched it.
    SystemUiFlight.begin();
    try {
      await _channel.invokeMethod('shareText', {
        'text': text,
        'title': title,
      });
    } finally {
      SystemUiFlight.end();
    }
  }

  /// Build 2095 (V2Ray journey audit #19): saves [content]
  /// as a document the user places (ACTION_CREATE_DOCUMENT).
  /// True when the file was written; false on cancel or
  /// failure — a backup used to exist only as clipboard text.
  /// Null when the call never reached a dialog at all
  /// (build 2098 verification V-5): a 'busy' answer means a
  /// save is already open — the first save will complete
  /// and report for itself, so the caller must not report
  /// anything (as a boolean, busy was indistinguishable
  /// from a user cancel and the Settings backup dialog
  /// popped itself with a spurious "Save cancelled" while
  /// the real save was still open).
  static Future<bool?> saveTextFile(String name, String content) async {
    // Build 2097 (IMP-1): a system-UI flight — the app
    // lock must not re-lock (and dispose the page) over it.
    SystemUiFlight.begin();
    try {
      final v = await _channel.invokeMethod<bool>('saveTextFile', {
        'name': name,
        'content': content,
      });
      return v ?? false;
    } on PlatformException catch (e) {
      // Build 2098 (post-2097 audit M9): a 'busy' answer
      // means a save dialog is already open (a double tap) —
      // this call is a no-op (see the return contract above).
      if (e.code == 'busy') return null;
      rethrow;
    } finally {
      SystemUiFlight.end();
    }
  }

  /// Build 2095 (feature 6): picks an image from the
  /// gallery and returns a cache-file PATH for the QR
  /// decoder; null when the pick was cancelled.
  static Future<String?> pickImageFile() async {
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

  static Future<Map<String, String>?> pickTextFile() async {
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
      // Build 2098 (post-2097 audit M9): the native side now
      // answers 'busy' when a pick is already open instead of
      // superseding it — the first pick is still open and
      // will deliver, so this call is a benign no-op, exactly
      // like a cancel.
      if (e.code == 'busy') return null;
      rethrow;
    } on MissingPluginException {
      // Build 2097 (IMP-3): no native handler (a platform
      // without the picker) must read as a FAILED pick —
      // the callers' PlatformException catch shows the
      // named message — not as a cancelled pick (null,
      // silent) and not as an uncaught error escaping the
      // import helper. pickImageFile above has guarded its
      // channel since 2095; the text picker never did.
      throw PlatformException(
        code: 'pick_unavailable',
        message: 'Could not read that file',
      );
    } finally {
      SystemUiFlight.end();
    }
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
    // OLCRTC underlay (build 2134): the client's argument
    // list rides along for supervision + respawn, like
    // dnsttArgs above.
    List<String> olcrtcArgs = const [],
    // Tunnel bridge (build 2155, the 2153 swap):
    // XraySettings.v2rayBridge — 'hev' (hev-socks5-tunnel,
    // in-process) or 'tunlink' (the legacy subprocess).
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

  /// Starts the AmneziaWG tunnel (build 2040, queue 2h).
  /// Build 2104: the engine is WG Tunnel's backend —
  /// [settings] is the profile's canonical .conf text
  /// (wgConfFromProfile), which the Kotlin side parses with
  /// the backend's own parser into the Config the backend
  /// runs (builds 2040–2103 sent a hand-composed UAPI string
  /// to a hand-built bridge instead). [addresses] rides
  /// along for signature stability; the Config carries the
  /// addresses now. [dns] is the tunnel's DNS
  /// (comma-separated when the profile carries several;
  /// build 2102, diagnosis C1 — the profile's own .conf DNS,
  /// or the Settings local DNS) and replaces the Config's
  /// DNS line on the Kotlin side. [ipv4]/[ipv6] say whether
  /// the profile carries that family at all (build 2102,
  /// diagnosis C2): they gate the full-tunnel AllowedIPs
  /// default for a peer that carries none — the routes
  /// themselves derive from the Config's AllowedIPs in the
  /// backend's TUN builder. [mtu] is the Settings tunnel
  /// MTU: since build 2116 (audit B3-1) the Kotlin side
  /// reads it as the fallback when the profile carries no
  /// usable MTU of its own (2104–2115 dropped it unread).
  static Future<void> setOnAwg({
    required String settings,
    required String name,
    required String addresses,
    required String dns,
    required bool ipv6,
    required bool ipv4,
    required int mtu,
    // Build 2127 (H4): the kill switch (the WG library's
    // lockdown on an unexpected drop).
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
    // Build 2116 (AB-11): catch→stopped — a thrown state
    // read escaped into refresh() and froze the card.
    try {
      return await _state();
    } catch (_) {
      return XrayState.stopped;
    }
  }

  static Future<XrayState> _state() async {
    final m = await _channel.invokeMapMethod<String, dynamic>('xrayState');
    if (m == null) return XrayState.stopped;
    final awg = m['awg'] as bool? ?? false;
    // The handshake/transfer figures are computed by the
    // Kotlin side from the backend's own ActiveConfig (build
    // 2104); a non-AWG session has none. Builds 2040–2103
    // parsed a raw UAPI dump here (parseAwgStatus) — the
    // parse that hunted a key no device emits and blinded
    // the connect proof; both are deleted.
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

  /// The real through-tunnel delay plus the exit identity
  /// observed through the same throwaway core (build 2032):
  /// {'ms', 'ip', 'countryCode'} — ip/countryCode '' when
  /// unobserved. (Build 2095, third-pass audit 7-7: the
  /// older measureDelay wrapper and its Kotlin branch are
  /// deleted — this Ex form is the only live path.)
  /// [timeoutMs] (build 2109): the per-request timeout the
  /// native side gives one request — the
  /// `delayTestTimeoutSec` setting, 8000 when the caller does
  /// not pass it (the fixed value of every build ≤2108).
  static Future<Map<String, dynamic>> measureDelayEx(
    String testConfig, {
    int rounds = 2,
    int budgetMs = 0,
    int timeoutMs = 8000,
  }) async {
    // Build 2101 (S5): the bulk Test-All pass asks for one
    // request round under a ~10 s overall budget (see
    // XrayTester.measureDelayEx); the defaults keep the
    // single-profile test's behavior exactly as before.
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

  /// The through-tunnel download rate (bytes/s) of a test config, or -1.
  static Future<int> speedTest(String testConfig) async {
    final v = await _channel.invokeMethod<int>('xraySpeedTest', {
      'config': testConfig,
    });
    return v ?? -1;
  }

  /// The through-tunnel UPLOAD rate (bytes/s) of a test
  /// config, or -1 (build 2149): the download test's
  /// mirror — a throwaway core instance POSTs generated
  /// bytes to the Cloudflare speed endpoint's upload
  /// path for the same window. The figure is the bytes
  /// the proxied connection accepted per second, the
  /// honest measure available without a cooperating
  /// server-side counter.
  static Future<int> speedTestUp(String testConfig) async {
    final v = await _channel.invokeMethod<int>('xraySpeedTestUp', {
      'config': testConfig,
    });
    return v ?? -1;
  }

  /// The sandbox config test (build 2061, feature queue #1):
  /// ONE throwaway core proves the config end to end — delay,
  /// hold, exit identity — on a free port, without touching the
  /// live tunnel. Never null: a channel failure returns a failed
  /// map, so the caller always has words for what happened.
  /// [timeoutMs] (build 2109): the per-request timeout of the
  /// sandbox's delay rounds — the `delayTestTimeoutSec`
  /// setting, 8000 when the caller does not pass it (the fixed
  /// value of every build ≤2108). The endurance hold inside the
  /// sandbox keeps its own fixed schedule.
  static Future<Map<String, dynamic>> sandboxTest(
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

  /// The proxied service reachability check (build 2091):
  /// ONE throwaway core asks each host in [hosts] for a real
  /// HTTPS HEAD through the config, on a free port, without
  /// touching the live tunnel — the same discipline as
  /// [sandboxTest]. Never null: a channel failure returns a
  /// failed map, so the caller always has words for what
  /// happened.
  static Future<Map<String, dynamic>> serviceCheck(
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

  /// Per-server DNS ping (build 2149, owner refinement of
  /// expansion 2 — Karing-style per-DNS rows): every server
  /// in [servers] is asked one real DNS query and timed
  /// individually. The result maps each requested server to
  /// its latency in ms; -1 = asked, no answer; -2 = not a
  /// probed kind (an unsupported scheme). Never throws: a
  /// channel failure fails every server at -1, so the caller
  /// always has a complete map to stamp.
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

  /// Through a throwaway instance of [testConfig] — the
  /// sandbox discipline; the live tunnel is never touched.
  static Future<Map<String, int>> dnsPing(
    String testConfig,
    List<String> servers, {
    int timeoutMs = 5000,
  }) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'xrayDnsPing',
        {
          'mode': 'config',
          'config': testConfig,
          'servers': servers,
          'timeoutMs': timeoutMs,
        },
      );
      return _dnsPingResults(m, servers);
    } catch (_) {
      return {for (final s in servers) s: -1};
    }
  }

  /// Through an already-running tunnel's SOCKS port (the
  /// connected config's own tunnel). [socksUser]/[socksPass]
  /// are the LAN-sharing credentials for that inbound.
  static Future<Map<String, int>> dnsPingViaPort(
    int socksPort,
    List<String> servers, {
    String socksUser = '',
    String socksPass = '',
    int timeoutMs = 5000,
  }) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'xrayDnsPing',
        {
          'mode': 'port',
          'socksPort': socksPort,
          'socksUser': socksUser,
          'socksPass': socksPass,
          'servers': servers,
          'timeoutMs': timeoutMs,
        },
      );
      return _dnsPingResults(m, servers);
    } catch (_) {
      return {for (final s in servers) s: -1};
    }
  }

  /// With no tunnel at all (the preset picker's Test all
  /// while disconnected): the same questions asked directly
  /// from the device.
  static Future<Map<String, int>> dnsPingDirect(
    List<String> servers, {
    int timeoutMs = 5000,
  }) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'xrayDnsPing',
        {'mode': 'direct', 'servers': servers, 'timeoutMs': timeoutMs},
      );
      return _dnsPingResults(m, servers);
    } catch (_) {
      return {for (final s in servers) s: -1};
    }
  }

  /// The running core's "proxy" outbound counters since the previous
  /// read (the native side reads the CUMULATIVE counters through
  /// the core's stats API and converts against its remembered
  /// baseline — build 2125; nothing is reset): {'up': n, 'down': n}
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
