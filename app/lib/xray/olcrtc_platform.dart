// The Dart side of the OLCRTC client's platform calls
// (build 2134; the same 'app/android' channel MainActivity
// serves). The native side (OlcrtcCore.kt) owns the
// subprocess, the separate stdout/stderr drains and the
// PID-file reaper; this side owns the settings and the
// generated YAML config (olcrtc_args.dart).

import 'dart:io';

import 'package:flutter/services.dart';

import 'subprocess_windows.dart';

class OlcrtcState {
  final bool available;
  final bool running;

  /// The client's local listener accepts connections —
  /// for OLCRTC that also proves the WebRTC link is up
  /// (the listener opens only after the link).
  final bool ready;

  /// idle | starting | ready | error
  final String stage;
  final String error;

  /// The tail of the client's stderr (its only log stream).
  final String logTail;

  const OlcrtcState({
    this.available = false,
    this.running = false,
    this.ready = false,
    this.stage = 'idle',
    this.error = '',
    this.logTail = '',
  });
}

class OlcrtcPlatform {
  static const _channel = MethodChannel('app/android');

  /// The last start() channel failure's text (build 2116,
  /// AB-10) — state() surfaces it when the client reports
  /// no error of its own.
  static String lastStartError = '';

  /// Spawns the client with [args] (one YAML config path).
  /// Returns once the process exists; readiness completes
  /// asynchronously — poll [state] until [OlcrtcState.ready].
  static Future<bool> start(List<String> args) async {
    if (Platform.isWindows) return WindowsSubprocesses.olcrtc.start(args);
    try {
      final v = await _channel.invokeMethod<bool>('olcrtcStart', {
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
    if (Platform.isWindows) return WindowsSubprocesses.olcrtc.stop();
    try {
      await _channel.invokeMethod('olcrtcStop');
    } catch (_) {
      // Already gone.
    }
  }

  static Future<OlcrtcState> state() async {
    if (Platform.isWindows) {
      final s = WindowsSubprocesses.olcrtc.snapshot();
      return OlcrtcState(
        available: s.available,
        running: s.running,
        ready: s.ready,
        stage: s.stage,
        error: s.error,
        logTail: s.logTail,
      );
    }
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('olcrtcState');
      if (m == null) return const OlcrtcState();
      final s = OlcrtcState(
        available: m['available'] as bool? ?? false,
        running: m['running'] as bool? ?? false,
        ready: m['ready'] as bool? ?? false,
        stage: m['stage'] as String? ?? 'idle',
        error: m['error'] as String? ?? '',
        logTail: m['logTail'] as String? ?? '',
      );
      if (!s.running && s.error.isEmpty && lastStartError.isNotEmpty) {
        return OlcrtcState(
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
      return OlcrtcState(stage: 'error', error: '$e');
    }
  }
}
