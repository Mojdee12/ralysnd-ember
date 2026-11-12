import 'dart:io';

import 'package:flutter/services.dart';

import 'openvpn_platform_windows.dart';

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
    this.downBytes = 0,
    this.exitIp = '',
    this.exitCountry = '',
    this.exitCode = '',
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
    exitIp: (m['exitIp'] as String?) ?? '',
    exitCountry: (m['exitCountry'] as String?) ?? '',
    exitCode: (m['exitCode'] as String?) ?? '',
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
  final String exitIp;
  final String exitCountry;

  /// The exit's ISO country code, for the map pin.
  final String exitCode;

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

  /// The Windows backend (the openvpn.exe sidecar, driven in
  /// Dart with the same contract).
  static final WindowsOpenVpnBackend _windows = WindowsOpenVpnBackend();
  static bool get _isWindows => Platform.isWindows;

  static Future<void> setOn({
    required String profileId,
    required String name,
    required String config,
    String credKey = '',
    String user = '',
    String pass = '',
    bool needsCreds = false,
  }) {
    if (_isWindows) {
      return _windows.setOn(
        profileId: profileId,
        name: name,
        config: config,
        credKey: credKey,
        user: user,
        pass: pass,
        needsCreds: needsCreds,
      );
    }
    return _channel.invokeMethod<void>('openVpnSetOn', {
    'on': true,
    'profileId': profileId,
    'name': name,
    'config': config,
    'credKey': credKey,
    'user': user,
    'pass': pass,
      'needsCreds': needsCreds,
    });
  }

  static Future<void> stop() {
    if (_isWindows) return _windows.stop();
    return _channel.invokeMethod<void>('openVpnStop');
  }

  static Future<OpenVpnState> state() async {
    if (_isWindows) return _windows.state();
    final m = await _channel.invokeMapMethod<dynamic, dynamic>('openVpnState');
    return m == null ? const OpenVpnState() : OpenVpnState.fromMap(m);
  }

  /// "" when the core accepts the profile, else an error code.
  static Future<String> validate(String config) async {
    if (_isWindows) return _windows.validate(config);
    return await _channel.invokeMethod<String>('openVpnValidate', {
          'config': config,
        }) ??
        'CORE_UNAVAILABLE';
  }

  /// Measures the profile's first remote. Pre-tunnel endpoint
  /// responsiveness only — see OpenVpnProbe on the Kotlin side.
  static Future<OvpnPing> ping({
    required String host,
    required int port,
    required String proto,
    required bool authenticatedControl,
  }) async {
    if (_isWindows) {
      return _windows.ping(
        host: host,
        port: port,
        proto: proto,
        authenticatedControl: authenticatedControl,
      );
    }
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
    if (_isWindows) return _windows.pickFile();
    final m = await _channel.invokeMapMethod<dynamic, dynamic>(
      'openVpnPickFile',
    );
    if (m == null) return null;
    return {
      'name': (m['name'] as String?) ?? 'profile.ovpn',
      'content': (m['content'] as String?) ?? '',
    };
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
  ) async {
    if (_isWindows) return _windows.saveCredentials(key, user, pass);
    return await _channel.invokeMethod<bool>('openVpnSaveCredentials', {
          'key': key,
          'user': user,
          'pass': pass,
        }) ??
        false;
  }

  /// True only when a stored entry exists AND decrypts on
  /// this device (build 2027 verified semantics).
  static Future<bool> hasCredentials(String key) async {
    if (_isWindows) return _windows.hasCredentials(key);
    return await _channel.invokeMethod<bool>('openVpnHasCredentials', {
          'key': key,
        }) ??
        false;
  }

  /// 'none' | 'ok' | 'unreadable' — what the vault can prove
  /// about an entry (build 2027). 'unreadable' = a payload
  /// exists but cannot be decrypted on this device; the UI
  /// must say so instead of claiming a saved account.
  static Future<String> credentialStatus(String key) async {
    if (_isWindows) return _windows.credentialStatus(key);
    return await _channel.invokeMethod<String>('openVpnCredentialStatus', {
          'key': key,
        }) ??
        'none';
  }

  static Future<void> deleteCredentials(String key) {
    if (_isWindows) return _windows.deleteCredentials(key);
    return _channel.invokeMethod<void>('openVpnDeleteCredentials', {
      'key': key,
    });
  }
}
