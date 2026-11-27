/// The Dart side of the wstunnel client's platform calls
/// (build 2072; the same 'app/android' channel MainActivity
/// serves). The native side (WstunnelCore.kt) owns the
/// subprocess, the separate stdout/stderr drains and the
/// PID-file reaper; this side owns the option and the
/// command line (wstunnel_args.dart).

import 'dart:io';

import 'package:flutter/services.dart';

import 'subprocess_windows.dart';

class WstunnelState {
  final bool available;
  final bool running;

  /// The forwarder survived its startup window: its args
  /// parsed and its UDP listener bound. A UDP forwarder has
  /// no handshake to probe — the WireGuard handshake above
  /// it is the end-to-end proof.
  final bool ready;

  /// idle | starting | ready | error
  final String stage;
  final String error;

  /// The tail of the client's stderr (its log stream).
  final String logTail;

  const WstunnelState({
    this.available = false,
    this.running = false,
    this.ready = false,
    this.stage = 'idle',
    this.error = '',
    this.logTail = '',
  });
}

class WstunnelPlatform {
  static const _channel = MethodChannel('app/android');

  /// The last start() channel failure's text (build 2116,
  /// AB-10) — state() surfaces it when the client reports
  /// no error of its own.
  static String lastStartError = '';

  /// Spawns the client with [args]. Returns once the process
  /// exists; readiness completes asynchronously — poll [state]
  /// until [WstunnelState.ready].
  static Future<bool> start(List<String> args) async {
    if (Platform.isWindows) return WindowsSubprocesses.wstunnel.start(args);
    try {
      final v = await _channel.invokeMethod<bool>('wstunnelStart', {
        'args': args,
      });
      if (v == true) lastStartError = '';
      return v ?? false;
    } catch (e) {
      lastStartError = '$e';
      return false;
    }
  }

  static Future<void> stop() async {
    if (Platform.isWindows) return WindowsSubprocesses.wstunnel.stop();
    try {
      await _channel.invokeMethod('wstunnelStop');
    } catch (_) {
      // Already gone.
    }
  }

  static Future<WstunnelState> state() async {
    if (Platform.isWindows) {
      final s = WindowsSubprocesses.wstunnel.snapshot();
      return WstunnelState(
        available: s.available,
        running: s.running,
        ready: s.ready,
        stage: s.stage,
        error: s.error,
        logTail: s.logTail,
      );
    }
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'wstunnelState',
      );
      if (m == null) return const WstunnelState();
      final s = WstunnelState(
        available: m['available'] as bool? ?? false,
        running: m['running'] as bool? ?? false,
        ready: m['ready'] as bool? ?? false,
        stage: m['stage'] as String? ?? 'idle',
        error: m['error'] as String? ?? '',
        logTail: m['logTail'] as String? ?? '',
      );
      if (!s.running && s.error.isEmpty && lastStartError.isNotEmpty) {
        return WstunnelState(
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
      return WstunnelState(stage: 'error', error: '$e');
    }
  }
}
