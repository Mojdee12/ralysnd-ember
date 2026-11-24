import 'package:flutter/services.dart';

import '../core/system_ui_flight.dart';

/// The OpenVPN engine's state, as OpenVpnService and OpenVpnCore
/// report it on the bridge (build 2025).
class OpenVpnState {
  const OpenVpnState({
    this.available = false,
    this.running = false,
    this.connected = false,
    this.phase = 'idle',
    this.profileId = '',
    this.profileName = '',
    this.sinceMs = 0,
    this.upBytes = 0,
    this.countersReported = false,
    this.downBytes = 0,
    this.exitIp = '',
    this.exitCountry = '',
    this.exitCode = '',
    this.ipv6Captured = false,
    this.killSwitchHeld = false,
    this.error,
    this.logTail = const [],
    this.lastStage = '',
    this.lastUnclean = false,
    this.lastExitReason = '',
    this.lastException = '',
  });

  factory OpenVpnState.fromMap(Map<dynamic, dynamic> m) => OpenVpnState(
    available: m['available'] == true,
    running: m['running'] == true,
    connected: m['connected'] == true,
    phase: (m['phase'] as String?) ?? 'idle',
    profileId: (m['profileId'] as String?) ?? '',
    profileName: (m['profileName'] as String?) ?? '',
    sinceMs: (m['sinceMs'] as num?)?.toInt() ?? 0,
    upBytes: (m['up'] as num?)?.toInt() ?? 0,
    downBytes: (m['down'] as num?)?.toInt() ?? 0,
    // Build 2096 (post-2095 audit M19): whether the core
    // actually reported counters — absent keys used to
    // default to 0 and read as "no traffic".
    countersReported: m['up'] is num && m['down'] is num,
    exitIp: (m['exitIp'] as String?) ?? '',
    exitCountry: (m['exitCountry'] as String?) ?? '',
    exitCode: (m['exitCode'] as String?) ?? '',
    // Build 2125 (audit A25-25 / P-04 remainder): the
    // session's IPv6 capture verdict from the TUN builder.
    ipv6Captured: m['ipv6Captured'] == true,
    // Build 2125 (audit A25-04): the kill-switch hold flag.
    killSwitchHeld: m['killSwitchHeld'] == true,
    error: m['error'] as String?,
    logTail:
        (m['logTail'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    lastStage: (m['lastStage'] as String?) ?? '',
    lastUnclean: m['lastUnclean'] == true,
    lastExitReason: (m['lastExitReason'] as String?) ?? '',
    lastException: (m['lastException'] as String?) ?? '',
  );

  /// False when the native core library is missing/unloadable.
  final bool available;

  /// The VPN service is up (any phase past idle).
  final bool running;

  /// The tunnel carried a real request end-to-end (the service
  /// only reports connected after its through-tunnel proof).
  final bool connected;

  /// idle | connecting | verifying | connected | reconnecting | error
  final String phase;
  final String profileId;
  final String profileName;
  final int sinceMs;
  final int upBytes;
  final int downBytes;

  /// Build 2096 (audit M19): false when the core's state
  /// carried no counter keys at all — the zeros above are
  /// then placeholders, not measurements.
  final bool countersReported;
  final String exitIp;
  final String exitCountry;

  /// The exit's ISO country code, for the map pin.
  final String exitCode;

  /// Build 2125 (audit A25-25 / P-04 remainder): whether
  /// the live session's TUN captured IPv6. False on a
  /// v4-only session — that family's traffic then stays
  /// outside the tunnel, which the OpenVPN page now says
  /// out loud instead of leaking silently.
  final bool ipv6Captured;

  /// Build 2125 (audit A25-04): the kill-switch hold is
  /// in place — the session ended unexpectedly and its
  /// TUN is held as a blackhole until the user
  /// disconnects or reconnects.
  final bool killSwitchHeld;

  /// The last failure, verbatim from the platform.
  final String? error;

  /// Build 2026 crash visibility: the previous session's final
  /// breadcrumb stage (e.g. "connect_enter"), whether that
  /// session ended without a clean stop, and the system's own
  /// exit-reason text when the last process died badly. All
  /// empty on a device that never ran a session.
  final String lastStage;
  final bool lastUnclean;
  final String lastExitReason;

  /// Build 2028: the exception text of the last session's
  /// terminate / run_exception breadcrumb, when there is one
  /// — the death naming itself on the diagnostics card, not
  /// only in a file. Empty when the trail holds no exception.
  final String lastException;
  final List<String> logTail;

  bool get starting =>
      phase == 'connecting' || phase == 'verifying' || phase == 'reconnecting';

  String get phaseLabel => switch (phase) {
    'connecting' => 'Connecting…',
    'verifying' => 'Verifying the tunnel…',
    'connected' => 'Connected',
    'reconnecting' => 'Reconnecting…',
    'error' => 'Failed',
    _ => running ? 'Connecting…' : 'Not connected',
  };

  /// "203.0.113.7 · Netherlands" style line when the exit is known.
  String get exitLine {
    if (exitIp.isEmpty) return exitCountry;
    if (exitCountry.isEmpty) return exitIp;
    return '$exitIp · $exitCountry';
  }
}

/// One latency measurement of a profile's first remote.
class OvpnPing {
  const OvpnPing({required this.ms, required this.method, this.error});

  /// Round-trip milliseconds; -1 when no measurement was made.
  final int ms;

  /// TCP_CONNECT | OPENVPN_UDP_RESET | UNSUPPORTED_CONTROL_AUTH
  /// | NO_ADDRESS | NO_RESPONSE — what was actually measured.
  final String method;
  final String? error;

  bool get measured => ms >= 0;

  factory OvpnPing.fromMap(Map<dynamic, dynamic> m) => OvpnPing(
    ms: (m['ms'] as num?)?.toInt() ?? -1,
    method: (m['method'] as String?) ?? 'NO_RESPONSE',
    error: m['error'] as String?,
  );
}

/// The platform-channel surface of the OpenVPN engine
/// (MainActivity's openVpn* cases).
class OpenVpnPlatform {
  static const _channel = MethodChannel('app/android');

  static Future<void> setOn({
    required String profileId,
    required String name,
    required String config,
    String credKey = '',
    String user = '',
    String pass = '',
    bool needsCreds = false,
    // Build 2125 (audit A25-04): the kill switch.
    bool killSwitch = false,
  }) => _channel.invokeMethod<void>('openVpnSetOn', {
    'on': true,
    'profileId': profileId,
    'name': name,
    'config': config,
    'credKey': credKey,
    'user': user,
    'pass': pass,
    'needsCreds': needsCreds,
    'killSwitch': killSwitch,
  });

  static Future<void> stop() => _channel.invokeMethod<void>('openVpnStop');

  static Future<OpenVpnState> state() async {
    // Build 2116 (AB-11): catch→stopped, like the rest of
    // the platform family — a thrown state read froze the
    // OpenVPN card on its last state.
    try {
      final m = await _channel.invokeMapMethod<dynamic, dynamic>(
        'openVpnState',
      );
      return m == null ? const OpenVpnState() : OpenVpnState.fromMap(m);
    } catch (_) {
      return const OpenVpnState();
    }
  }

  /// "" when the core accepts the profile, else an error code.
  static Future<String> validate(String config) async =>
      await _channel.invokeMethod<String>('openVpnValidate', {
        'config': config,
      }) ??
      'CORE_UNAVAILABLE';

  /// Measures the profile's first remote. Pre-tunnel endpoint
  /// responsiveness only — see OpenVpnProbe on the Kotlin side.
  static Future<OvpnPing> ping({
    required String host,
    required int port,
    required String proto,
    required bool authenticatedControl,
  }) async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>('openVpnPing', {
      'host': host,
      'port': port,
      'proto': proto,
      'authenticatedControl': authenticatedControl,
    });
    return m == null
        ? const OvpnPing(ms: -1, method: 'NO_RESPONSE')
        : OvpnPing.fromMap(m);
  }

  /// The system file picker for one .ovpn file; null on cancel.
  static Future<Map<String, String>?> pickFile() async {
    // Build 2097 (IMP-1): a system-UI flight — the app
    // lock must not re-lock (and dispose the page) over it.
    SystemUiFlight.begin();
    try {
      final m = await _channel.invokeMapMethod<dynamic, dynamic>(
        'openVpnPickFile',
      );
      if (m == null) return null;
      return {
        'name': (m['name'] as String?) ?? 'profile.ovpn',
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
      // Build 2098 (post-2097 audit M8): the same IMP-3
      // conversion the Xray route has had since build 2097 —
      // a platform with no picker handler must surface the
      // named "picker unavailable" failure, not a raw
      // MissingPluginException escaping the import helper.
      throw PlatformException(
        code: 'pick_unavailable',
        message: 'Could not read that file',
      );
    } finally {
      SystemUiFlight.end();
    }
  }

  /// Saves credentials; true only when the platform wrote
  /// the entry AND read it back decrypted (build 2027 — a
  /// save the connect flow would never see is not a save).
  /// A platform failure throws, like any channel error; the
  /// caller must surface it.
  static Future<bool> saveCredentials(
    String key,
    String user,
    String pass,
  ) async =>
      await _channel.invokeMethod<bool>('openVpnSaveCredentials', {
        'key': key,
        'user': user,
        'pass': pass,
      }) ??
      false;

  /// True only when a stored entry exists AND decrypts on
  /// this device (build 2027 verified semantics).
  static Future<bool> hasCredentials(String key) async =>
      await _channel.invokeMethod<bool>('openVpnHasCredentials', {
        'key': key,
      }) ??
      false;

  /// 'none' | 'ok' | 'unreadable' — what the vault can prove
  /// about an entry (build 2027). 'unreadable' = a payload
  /// exists but cannot be decrypted on this device; the UI
  /// must say so instead of claiming a saved account.
  static Future<String> credentialStatus(String key) async =>
      await _channel.invokeMethod<String>('openVpnCredentialStatus', {
        'key': key,
      }) ??
      'none';

  static Future<void> deleteCredentials(String key) =>
      _channel.invokeMethod<void>('openVpnDeleteCredentials', {'key': key});
}
