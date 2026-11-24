/// The Dart side of the EmberWarp core's platform calls
/// (build 2030; the same 'app/android' channel MainActivity
/// serves). The native side (EmberWarpCore.kt) owns the
/// subprocess, the identity directory in noBackupFilesDir,
/// the single-socket readiness wait and the PID-file reaper;
/// this side owns the profile and the command line
/// (warp_args.dart).

import 'package:flutter/services.dart';

class WarpCoreState {
  final bool available;
  final bool running;

  /// The data-plane gate passed: the core answers its SOCKS
  /// greeting, which it only does after a gateway carried a
  /// real check.
  final bool ready;

  /// idle | starting | ready | error | refused
  final String stage;

  /// A saved WARP identity exists on this device.
  final bool identityPresent;

  /// Cloudflare refused the saved identity (the core's fatal
  /// log line was seen): only an explicit Renew fixes it.
  final bool renewNeeded;
  final String error;
  final String logTail;

  const WarpCoreState({
    this.available = false,
    this.running = false,
    this.ready = false,
    this.stage = 'idle',
    this.identityPresent = false,
    this.renewNeeded = false,
    this.error = '',
    this.logTail = '',
  });
}

class WarpPlatform {
  static const _channel = MethodChannel('app/android');

  /// The last start() channel failure's text (build 2116,
  /// AB-10): start() keeps its bool contract, but the
  /// exception is no longer swallowed — state() surfaces
  /// it when the core reports no error of its own.
  static String lastStartError = '';

  /// Spawns the core with [args]. Returns once the process
  /// exists; readiness completes asynchronously — poll [state]
  /// until [WarpCoreState.ready] (the native wait is a single
  /// SOCKS greeting, up to 45 s). [greetingWaitMs] overrides
  /// the native readiness budget (build 2087): the chain
  /// path's identity-registration run passes the chain grace
  /// (150 s), because registration precedes its first scan.
  static Future<bool> start(
    List<String> args, {
    int port = 20850,
    int? greetingWaitMs,
  }) async {
    try {
      final v = await _channel.invokeMethod<bool>('warpStart', {
        'args': args,
        'port': port,
        if (greetingWaitMs != null) 'greetingWaitMs': greetingWaitMs,
      });
      if (v == true) lastStartError = '';
      return v ?? false;
    } catch (e) {
      lastStartError = '$e';
      return false;
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('warpStop');
    } catch (_) {
      // Already gone.
    }
  }

  static Future<WarpCoreState> state() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('warpState');
      if (m == null) return const WarpCoreState();
      final s = WarpCoreState(
        available: m['available'] as bool? ?? false,
        running: m['running'] as bool? ?? false,
        ready: m['ready'] as bool? ?? false,
        stage: m['stage'] as String? ?? 'idle',
        identityPresent: m['identityPresent'] as bool? ?? false,
        renewNeeded: m['renewNeeded'] as bool? ?? false,
        error: m['error'] as String? ?? '',
        logTail: m['logTail'] as String? ?? '',
      );
      // Build 2116 (AB-10): surface a swallowed start
      // failure the core never got to report.
      if (!s.running && s.error.isEmpty && lastStartError.isNotEmpty) {
        return WarpCoreState(
          available: s.available,
          running: s.running,
          ready: s.ready,
          stage: s.stage == 'idle' ? 'error' : s.stage,
          identityPresent: s.identityPresent,
          renewNeeded: s.renewNeeded,
          error: lastStartError,
          logTail: s.logTail,
        );
      }
      return s;
    } catch (e) {
      return WarpCoreState(stage: 'error', error: '$e');
    }
  }

  /// The ONLY identity renewal path (dossier Q1): registers a
  /// fresh identity ([kind] = masque | wg | gool) into staging
  /// and settles it over the live one. Blocking on the native
  /// side (up to ~2 minutes); true when a new identity landed.
  static Future<bool> renew(String kind) async {
    try {
      final v = await _channel.invokeMethod<bool>('warpRenew', {
        'kind': kind,
      });
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Explicit identity wipe: the next connect registers fresh
  /// because nothing is saved.
  static Future<void> resetIdentity() async {
    try {
      await _channel.invokeMethod('warpResetIdentity');
    } catch (_) {
      // Nothing to reset.
    }
  }

  /// Finishes an interrupted renewal settle, if one is staged.
  static Future<void> settle() async {
    try {
      await _channel.invokeMethod('warpSettle');
    } catch (_) {
      // Nothing staged.
    }
  }
}
