/// The Dart side of the build-2075 sidecar engines'
/// platform calls (the same 'app/android' channel
/// MainActivity serves; the native sides are
/// SingBoxCore.kt, MieruCore.kt and DnsCryptCore.kt, all on
/// the 2072 SubprocessCore lifecycle). One state shape for
/// all three — the native `state()` maps are identical.

import 'dart:io';

import 'package:flutter/services.dart';

import 'subprocess_windows.dart';

class SidecarState {
  final bool available;
  final bool running;

  /// The helper's local listener accepts connections.
  final bool ready;

  /// idle | starting | ready | error
  final String stage;
  final String error;
  final String logTail;

  const SidecarState({
    this.available = false,
    this.running = false,
    this.ready = false,
    this.stage = 'idle',
    this.error = '',
    this.logTail = '',
  });
}

/// The Windows backend's snapshot in this file's state shape
/// (subprocess_windows.dart — the SubprocessCore lifecycle
/// driven from Dart, as warp_platform.dart's backend does).
SidecarState _stateFromSnapshot(SubprocessSnapshot s) => SidecarState(
      available: s.available,
      running: s.running,
      ready: s.ready,
      stage: s.stage,
      error: s.error,
      logTail: s.logTail,
    );

SidecarState _stateFrom(Map<String, dynamic>? m) {
  if (m == null) return const SidecarState();
  return SidecarState(
    available: m['available'] as bool? ?? false,
    running: m['running'] as bool? ?? false,
    ready: m['ready'] as bool? ?? false,
    stage: m['stage'] as String? ?? 'idle',
    error: m['error'] as String? ?? '',
    logTail: m['logTail'] as String? ?? '',
  );
}

/// Build 2116 (AB-10): a start() whose channel call threw
/// used to read exactly like a core that declined — false,
/// then an idle state with an empty error, and the connect
/// waited out its full budget before reporting a generic
/// sentence. The exception text is kept per engine and
/// surfaces through state() (the surface every caller
/// already reads after a failed start) whenever the core
/// itself reports no error and is not running.
SidecarState _withStartError(SidecarState s, String startError) {
  if (s.running || s.error.isNotEmpty || startError.isEmpty) return s;
  return SidecarState(
    available: s.available,
    running: s.running,
    ready: s.ready,
    stage: s.stage == 'idle' ? 'error' : s.stage,
    error: startError,
    logTail: s.logTail,
  );
}

/// The sing-box engine: TUIC / Snell / NaiveProxy outbounds
/// and the Tailscale / OpenConnect endpoints. The caller
/// writes the generated config (singbox_config.dart) into
/// filesDir/singbox/config.json first, then starts the
/// engine with `run -c <path>`.
class SingBoxPlatform {
  static const _channel = MethodChannel('app/android');

  /// The last start() channel failure's text (build 2116,
  /// AB-10) — see [_withStartError].
  static String lastStartError = '';

  static Future<bool> start(List<String> args) async {
    if (Platform.isWindows) return WindowsSubprocesses.singbox.start(args);
    try {
      final v = await _channel.invokeMethod<bool>('singboxStart', {
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
    if (Platform.isWindows) return WindowsSubprocesses.singbox.stop();
    try {
      await _channel.invokeMethod('singboxStop');
    } catch (_) {
      // Already gone.
    }
  }

  static Future<SidecarState> state() async {
    if (Platform.isWindows) {
      return _stateFromSnapshot(WindowsSubprocesses.singbox.snapshot());
    }
    try {
      return _withStartError(
        _stateFrom(
          await _channel.invokeMapMethod<String, dynamic>('singboxState'),
        ),
        lastStartError,
      );
    } catch (e) {
      return SidecarState(stage: 'error', error: '$e');
    }
  }
}

/// The Sudoku engine (build 2127, H2): Hiddify's sing-box
/// fork as its own binary (libsudokubox.so) — the official
/// sing-box sidecar above stays untouched for the profiles
/// it serves. The caller writes the generated config
/// (sudoku_config.dart) into filesDir/sudokubox/config.json
/// first, then starts the engine with `run -c <path>`.
class SudokuBoxPlatform {
  static const _channel = MethodChannel('app/android');

  /// The last start() channel failure's text (build 2116,
  /// AB-10) — see [_withStartError].
  static String lastStartError = '';

  static Future<bool> start(List<String> args) async {
    if (Platform.isWindows) return WindowsSubprocesses.sudokubox.start(args);
    try {
      final v = await _channel.invokeMethod<bool>('sudokuBoxStart', {
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
    if (Platform.isWindows) return WindowsSubprocesses.sudokubox.stop();
    try {
      await _channel.invokeMethod('sudokuBoxStop');
    } catch (_) {
      // Already gone.
    }
  }

  static Future<SidecarState> state() async {
    if (Platform.isWindows) {
      return _stateFromSnapshot(WindowsSubprocesses.sudokubox.snapshot());
    }
    try {
      return _withStartError(
        _stateFrom(
          await _channel.invokeMapMethod<String, dynamic>('sudokuBoxState'),
        ),
        lastStartError,
      );
    } catch (e) {
      return SidecarState(stage: 'error', error: '$e');
    }
  }
}

/// The Zapret desync proxy (build 2127, H1): ciadpi, a
/// userspace SOCKS5 proxy on loopback. Start carries the
/// full command line (zapret_args.dart — listen flags
/// plus the candidate's desync flags); there is no
/// config file. Used by the DPI Lab's zap candidates
/// and by a connect whose applied Lab win is one.
class ZapretPlatform {
  static const _channel = MethodChannel('app/android');

  /// The last start() channel failure's text (build 2116,
  /// AB-10) — see [_withStartError].
  static String lastStartError = '';

  static Future<bool> start(List<String> args) async {
    if (Platform.isWindows) return WindowsSubprocesses.zapret.start(args);
    try {
      final v = await _channel.invokeMethod<bool>('zapretStart', {
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
    if (Platform.isWindows) return WindowsSubprocesses.zapret.stop();
    try {
      await _channel.invokeMethod('zapretStop');
    } catch (_) {
      // Already gone.
    }
  }

  static Future<SidecarState> state() async {
    if (Platform.isWindows) {
      return _stateFromSnapshot(WindowsSubprocesses.zapret.snapshot());
    }
    try {
      return _withStartError(
        _stateFrom(
          await _channel.invokeMapMethod<String, dynamic>('zapretState'),
        ),
        lastStartError,
      );
    } catch (e) {
      return SidecarState(stage: 'error', error: '$e');
    }
  }
}

/// The Mieru client: start carries the whole client config
/// JSON (mieru_config.dart); the native core applies it
/// (`replace config`) before spawning the daemon.
class MieruPlatform {
  static const _channel = MethodChannel('app/android');

  /// The last start() channel failure's text (build 2116,
  /// AB-10) — see [_withStartError].
  static String lastStartError = '';

  static Future<bool> start(String configJson) async {
    if (Platform.isWindows) return WindowsSubprocesses.startMieru(configJson);
    try {
      final v = await _channel.invokeMethod<bool>('mieruStart', {
        'config': configJson,
      });
      if (v == true) lastStartError = '';
      return v ?? false;
    } catch (e) {
      lastStartError = '$e';
      return false;
    }
  }

  static Future<void> stop() async {
    if (Platform.isWindows) return WindowsSubprocesses.mieru.stop();
    try {
      await _channel.invokeMethod('mieruStop');
    } catch (_) {
      // Already gone.
    }
  }

  static Future<SidecarState> state() async {
    if (Platform.isWindows) {
      return _stateFromSnapshot(WindowsSubprocesses.mieru.snapshot());
    }
    try {
      return _withStartError(
        _stateFrom(
          await _channel.invokeMapMethod<String, dynamic>('mieruState'),
        ),
        lastStartError,
      );
    } catch (e) {
      return SidecarState(stage: 'error', error: '$e');
    }
  }
}

/// The DNSCrypt proxy: the caller writes the generated TOML
/// (dnscrypt_config.dart) into filesDir/dnscrypt/ first,
/// then starts the proxy with `-config <path>`.
class DnsCryptPlatform {
  static const _channel = MethodChannel('app/android');

  /// The last start() channel failure's text (build 2116,
  /// AB-10) — see [_withStartError].
  static String lastStartError = '';

  static Future<bool> start(List<String> args) async {
    if (Platform.isWindows) return WindowsSubprocesses.dnscrypt.start(args);
    try {
      final v = await _channel.invokeMethod<bool>('dnscryptStart', {
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
    if (Platform.isWindows) return WindowsSubprocesses.dnscrypt.stop();
    try {
      await _channel.invokeMethod('dnscryptStop');
    } catch (_) {
      // Already gone.
    }
  }

  static Future<SidecarState> state() async {
    if (Platform.isWindows) {
      return _stateFromSnapshot(WindowsSubprocesses.dnscrypt.snapshot());
    }
    try {
      return _withStartError(
        _stateFrom(
          await _channel.invokeMapMethod<String, dynamic>('dnscryptState'),
        ),
        lastStartError,
      );
    } catch (e) {
      return SidecarState(stage: 'error', error: '$e');
    }
  }
}
