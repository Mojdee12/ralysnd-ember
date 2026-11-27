/// The Dart side of the DNSTT client's platform calls
/// (build 2072; the same 'app/android' channel MainActivity
/// serves). The native side (DnsttCore.kt) owns the
/// subprocess, the separate stdout/stderr drains and the
/// PID-file reaper; this side owns the settings and the
/// command line (dnstt_args.dart).

import 'package:flutter/services.dart';

class DnsttState {
  final bool available;
  final bool running;

  /// The client's local listener accepts connections.
  final bool ready;

  /// idle | starting | ready | error
  final String stage;
  final String error;

  /// The tail of the client's stderr (its only log stream).
  final String logTail;

  const DnsttState({
    this.available = false,
    this.running = false,
    this.ready = false,
    this.stage = 'idle',
    this.error = '',
    this.logTail = '',
  });
}

class DnsttPlatform {
  static const _channel = MethodChannel('app/android');

  /// The last start() channel failure's text (build 2116,
  /// AB-10) — state() surfaces it when the client reports
  /// no error of its own.
  static String lastStartError = '';

  /// Spawns the client with [args]. Returns once the process
  /// exists; readiness completes asynchronously — poll [state]
  /// until [DnsttState.ready].
  static Future<bool> start(List<String> args) async {
    try {
      final v = await _channel.invokeMethod<bool>('dnsttStart', {'args': args});
      if (v == true) lastStartError = '';
      return v ?? false;
    } catch (e) {
      lastStartError = '$e';
      return false;
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('dnsttStop');
    } catch (_) {
      // Already gone.
    }
  }

  static Future<DnsttState> state() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('dnsttState');
      if (m == null) return const DnsttState();
      final s = DnsttState(
        available: m['available'] as bool? ?? false,
        running: m['running'] as bool? ?? false,
        ready: m['ready'] as bool? ?? false,
        stage: m['stage'] as String? ?? 'idle',
        error: m['error'] as String? ?? '',
        logTail: m['logTail'] as String? ?? '',
      );
      if (!s.running && s.error.isEmpty && lastStartError.isNotEmpty) {
        return DnsttState(
          available: s.available,
          running: s.running,
          ready: s.ready,
          stage: s.stage == 'idle' ? 'error' : s.stage,
          error: lastStartError,
          logTail: s.logTail,
        );
      }
      return s;
    } catch (e) {
      return DnsttState(stage: 'error', error: '$e');
    }
  }
}
