/// System-wide capture on Windows for engines that only expose a
/// local SOCKS proxy (Xray in TUN mode, Psiphon in VPN mode).
///
/// The bundled ember-tun-bridge helper (core/cmd/ember-tun-bridge)
/// holds a session with the installed TUN service
/// (core/internal/tunapi — the same privileged service the Mozilla
/// core's TUN mode uses): the service creates the adapter, routes
/// the system through it, and forwards everything to the engine's
/// SOCKS proxy, keeping the engine's own process outside the tunnel
/// so it cannot loop into itself. The helper holds the session only
/// while it runs; the backends keep its stdin open and close it to
/// stop, and when the app process dies the pipe closes with it and
/// the helper takes the TUN down — the service itself also drops
/// the session if the helper dies any other way.
///
/// The helper's stdout is a line protocol: `UP <adapter> ...` once
/// the TUN is routed (printed only after the service answered the
/// open and route requests, so UP is the service's confirmation
/// that the session is established — the parameters ride the line),
/// `DOWN <reason>` when a running session ends by itself,
/// `ERROR <code> <message>` when the start fails. Its first run may
/// install the TUN service (the installer's own administrator
/// prompt), so the start timeout is generous.
///
/// Every start attempt is recorded in tunlink.log in the engine's
/// folder (the file the app's log pages show next to the engine
/// log): the attempt header, the helper's stage diagnostics and
/// session parameters, and the outcome — success or failure. An
/// empty tunlink.log after a TUN connect attempt is impossible.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class TunBridgeException implements Exception {
  TunBridgeException(this.message);
  final String message;
  @override
  String toString() => message;
}

class TunBridge {
  TunBridge._(this._proc, this._tunlink);

  final Process _proc;

  /// This attempt's tunlink.log sink, closed by [stop].
  IOSink? _tunlink;
  bool _up = false;
  String? downReason;
  final _down = Completer<void>();

  /// The helper beside the app's core binaries.
  static String get exePath {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    return '$dir${sep}core${sep}ember-tun-bridge.exe';
  }

  bool get up => _up && downReason == null;

  /// Fires when the session ends by itself (or the helper exits).
  Future<void> get down => _down.future;

  /// Starts the helper forwarding the system to the SOCKS proxy at
  /// [socksPort]; [skipProgram] is the engine executable the service
  /// must keep outside the TUN (xray.exe, psiphon-core.exe).
  /// Diagnostics from the helper go to [log] and to tunlink.log in
  /// [logDir]. Throws [TunBridgeException] when the TUN does not
  /// come up — the caller must fail the connect rather than run
  /// uncaptured.
  static Future<TunBridge> start({
    required int socksPort,
    required String skipProgram,
    required IOSink log,
    required Directory logDir,
  }) async {
    final exe = exePath;
    IOSink? tunlink;
    Future<void> closeTunlink() async {
      final sink = tunlink;
      tunlink = null;
      try {
        await sink?.flush();
        await sink?.close();
      } catch (_) {
        // The record is best-effort at the edges.
      }
    }

    try {
      await logDir.create(recursive: true);
      final sink = File('${logDir.path}/tunlink.log')
          .openWrite(mode: FileMode.append);
      tunlink = sink;
      sink.writeln(
        '[tun-bridge] --- start ${DateTime.now().toIso8601String()} '
        'proxy=127.0.0.1:$socksPort skip=$skipProgram exe=$exe ---',
      );
    } catch (_) {
      tunlink = null; // The caller's log still carries the attempt.
    }
    if (!File(exe).existsSync()) {
      tunlink?.writeln('[tun-bridge] start failed: helper missing');
      await closeTunlink();
      throw TunBridgeException('tun-bridge-missing: $exe');
    }
    Process proc;
    try {
      proc = await Process.start(exe, [
        '-proxy',
        '127.0.0.1:$socksPort',
        '-skip',
        skipProgram,
      ]);
    } catch (e) {
      tunlink?.writeln('[tun-bridge] start failed: spawn: $e');
      await closeTunlink();
      throw TunBridgeException('tun-bridge-start: $e');
    }
    final bridge = TunBridge._(proc, tunlink);
    void writeLog(String s) {
      try {
        log.write(s);
      } catch (_) {
        // The caller's sink may close when its own process ends.
      }
      try {
        tunlink?.write(s);
      } catch (_) {
        // Same.
      }
    }

    proc.stderr
        .transform(utf8.decoder)
        .listen((s) => writeLog('[tun-bridge] $s'), onError: (_) {});

    final ready = Completer<TunBridge>();
    final lines = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      writeLog('[tun-bridge] $line\n');
      if (line.startsWith('UP ')) {
        // The line carries the session parameters (adapter, index,
        // proxy, service version, protocol) — it is the attempt's
        // success record in both logs.
        bridge._up = true;
        if (!ready.isCompleted) ready.complete(bridge);
      } else if (line.startsWith('ERROR ')) {
        if (!ready.isCompleted) {
          ready.completeError(TunBridgeException(line.substring(6)));
        } else {
          bridge._finish(line.substring(6));
        }
      } else if (line.startsWith('DOWN')) {
        bridge._finish(line.length > 5 ? line.substring(5) : 'down');
      }
    }, onError: (_) {});
    unawaited(lines.asFuture<void>().catchError((_) {}));
    unawaited(proc.exitCode.then((code) {
      bridge._finish('helper-exited-$code');
      if (!ready.isCompleted) {
        ready.completeError(
          TunBridgeException(bridge.downReason ?? 'helper-exited-$code'),
        );
      }
    }));

    try {
      // Installing the service (first ever TUN use) waits on the
      // user at an administrator prompt; allow for that.
      return await ready.future.timeout(const Duration(seconds: 150));
    } on TunBridgeException catch (e) {
      writeLog('[tun-bridge] start failed: ${e.message}\n');
      await bridge.stop();
      rethrow;
    } on TimeoutException {
      writeLog('[tun-bridge] start failed: no UP in 150s\n');
      await bridge.stop();
      throw TunBridgeException('tun-bridge-timeout: no UP in 150s');
    }
  }

  void _finish(String reason) {
    downReason ??= reason;
    if (!_down.isCompleted) _down.complete();
  }

  /// Closes the helper's stdin: it closes the session politely and
  /// exits. Kills it if it lingers.
  Future<void> stop() async {
    try {
      await _proc.stdin.close();
    } catch (_) {
      // Already gone.
    }
    try {
      await _proc.exitCode.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      _proc.kill();
      try {
        await _proc.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        // Nothing more to wait for.
      }
    }
    _finish('stopped');
    final sink = _tunlink;
    _tunlink = null;
    try {
      sink?.writeln(
        '[tun-bridge] --- stop ${DateTime.now().toIso8601String()} ---',
      );
      await sink?.flush();
      await sink?.close();
    } catch (_) {
      // The record is best-effort at the edges.
    }
  }
}
