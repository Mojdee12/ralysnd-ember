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

  /// Spawns the client with [args]. Returns once the process
  /// exists; readiness completes asynchronously — poll [state]
  /// until [DnsttState.ready].
  static Future<bool> start(List<String> args) async {
    try {
      final v = await _channel.invokeMethod<bool>('dnsttStart', {
        'args': args,
      });
      return v ?? false;
    } catch (_) {
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
      return DnsttState(
        available: m['available'] as bool? ?? false,
        running: m['running'] as bool? ?? false,
        ready: m['ready'] as bool? ?? false,
        stage: m['stage'] as String? ?? 'idle',
        error: m['error'] as String? ?? '',
        logTail: m['logTail'] as String? ?? '',
      );
    } catch (_) {
      return const DnsttState();
    }
  }
}
