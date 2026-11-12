/// The EmberWarp core's platform seam (build 2030 contract).
///
/// On Android this is the 'app/android' channel MainActivity
/// serves (EmberWarpCore.kt owns the subprocess). On Windows the
/// backend is pure Dart (warp_platform_windows.dart): it spawns
/// the SAME Rust aether binary, built as the aether.exe sidecar,
/// and owns the identical contract — identity directory,
/// AETHER_REPROVISION=0, the SOCKS-greeting readiness wait, the
/// refusal-line watch, renewal into staging + settle.

import 'dart:io';

import 'package:flutter/services.dart';

import 'warp_platform_windows.dart';

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
  static final WindowsWarpBackend _windows = WindowsWarpBackend();

  /// Spawns the core with [args]. Returns once the process
  /// exists; readiness completes asynchronously — poll [state]
  /// until [WarpCoreState.ready] (the native wait is a single
  /// SOCKS greeting, up to 45 s).
  static Future<bool> start(List<String> args, {int port = 20850}) async {
    if (Platform.isWindows) return _windows.start(args, port: port);
    try {
      final v = await _channel.invokeMethod<bool>('warpStart', {
        'args': args,
        'port': port,
      });
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stop() async {
    if (Platform.isWindows) return _windows.stop();
    try {
      await _channel.invokeMethod('warpStop');
    } catch (_) {
      // Already gone.
    }
  }

  static Future<WarpCoreState> state() async {
    if (Platform.isWindows) return _windows.state();
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('warpState');
      if (m == null) return const WarpCoreState();
      return WarpCoreState(
        available: m['available'] as bool? ?? false,
        running: m['running'] as bool? ?? false,
        ready: m['ready'] as bool? ?? false,
        stage: m['stage'] as String? ?? 'idle',
        identityPresent: m['identityPresent'] as bool? ?? false,
        renewNeeded: m['renewNeeded'] as bool? ?? false,
        error: m['error'] as String? ?? '',
        logTail: m['logTail'] as String? ?? '',
      );
    } catch (_) {
      return const WarpCoreState();
    }
  }

  /// The ONLY identity renewal path (dossier Q1): registers a
  /// fresh identity ([kind] = masque | wg | gool) into staging
  /// and settles it over the live one. Blocking (up to
  /// ~2 minutes); true when a new identity landed.
  static Future<bool> renew(String kind) async {
    if (Platform.isWindows) return _windows.renew(kind);
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
    if (Platform.isWindows) return _windows.resetIdentity();
    try {
      await _channel.invokeMethod('warpResetIdentity');
    } catch (_) {
      // Nothing to reset.
    }
  }

  /// Finishes an interrupted renewal settle, if one is staged.
  static Future<void> settle() async {
    if (Platform.isWindows) return _windows.settle();
    try {
      await _channel.invokeMethod('warpSettle');
    } catch (_) {
      // Nothing staged.
    }
  }
}
