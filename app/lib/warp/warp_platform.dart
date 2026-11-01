/// The Dart side of the WARP+ engine's platform calls (the same
/// 'app/android' channel MainActivity serves).

import 'package:flutter/services.dart';

class WarpState {
  final bool running;

  /// The core subprocess is up but has not served its proxy yet
  /// (registration / endpoint scan / handshake in progress).
  final bool starting;

  /// The core passed its own connectivity test and serves its proxy.
  final bool connected;

  /// The last start attempt died (the core exited or timed out).
  final bool failed;
  final String failure;

  /// The running mode's display label ("" while off).
  final String mode;
  final int sinceMs;
  final int upBytes;
  final int downBytes;

  const WarpState({
    required this.running,
    required this.starting,
    required this.connected,
    required this.failed,
    required this.failure,
    required this.mode,
    required this.sinceMs,
    required this.upBytes,
    required this.downBytes,
  });

  /// True while the engine is in any way up: starting or running.
  bool get active => running || starting;

  static const stopped = WarpState(
    running: false,
    starting: false,
    connected: false,
    failed: false,
    failure: '',
    mode: '',
    sinceMs: 0,
    upBytes: 0,
    downBytes: 0,
  );
}

class WarpPlatform {
  static const _channel = MethodChannel('app/android');

  /// The engine's fixed local SOCKS port (warp-plus's --bind).
  static const socksPort = 8086;

  static Future<void> setOn({
    required String mode,
    required bool scan,
    required String country,
    required String endpoint,
    required String dns,
  }) =>
      _channel.invokeMethod('warpSetOn', {
        'on': true,
        'mode': mode,
        'scan': scan,
        'country': country,
        'endpoint': endpoint,
        'dns': dns,
      });

  static Future<void> stop() => _channel.invokeMethod('warpStop');

  static Future<WarpState> state() async {
    final m = await _channel.invokeMapMethod<String, dynamic>('warpState');
    if (m == null) return WarpState.stopped;
    return WarpState(
      running: m['running'] as bool? ?? false,
      starting: m['starting'] as bool? ?? false,
      connected: m['connected'] as bool? ?? false,
      failed: m['failed'] as bool? ?? false,
      failure: m['failure'] as String? ?? '',
      mode: m['mode'] as String? ?? '',
      sinceMs: (m['sinceMs'] as num?)?.toInt() ?? 0,
      upBytes: (m['up'] as num?)?.toInt() ?? 0,
      downBytes: (m['down'] as num?)?.toInt() ?? 0,
    );
  }

  /// The exit IP/country of the running WARP tunnel, asked through
  /// its own SOCKS proxy. Best-effort: null on any failure.
  static Future<Map<String, String>?> exitInfo() async {
    try {
      final m =
          await _channel.invokeMapMethod<String, dynamic>('warpExitInfo');
      if (m == null) return null;
      return m.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return null;
    }
  }
}
