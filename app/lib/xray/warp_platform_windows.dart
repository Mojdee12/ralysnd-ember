/// The EmberWarp core on Windows (build 2030 contract, ported
/// from EmberWarpCore.kt): the SAME Rust aether binary Android
/// stages as libemberwarp.so, built for Windows as the
/// `aether\aether.exe` sidecar (scripts/fetch-windows-sidecars.ps1
/// builds it from the same source tree). This class owns, in
/// Dart, everything the Kotlin object owns on Android:
///
/// - the subprocess spawn with the AETHER_* environment and the
///   identity directory (AETHER_REPROVISION=0 — normal connects
///   never re-register),
/// - the single-socket SOCKS-greeting readiness wait (45 s),
/// - the log tail watch for the identity-refusal line (the ONLY
///   thing that raises the Renew prompt),
/// - the PID-file orphan reaper,
/// - renewal: a `--register <kind>` run into the staging
///   directory, settled over the live identity only when the
///   staged set is complete (the `ready` marker).

import 'dart:async';
import 'dart:io';

import '../core/core_api.dart';
import 'warp_platform.dart';

class WindowsWarpBackend {
  Process? _process;
  bool _running = false;
  bool _ready = false;
  String _stage = 'idle';
  bool _renewNeeded = false;
  String _lastError = '';
  int _logOffset = 0;
  Timer? _logTimer;

  /// The core's own words for "this identity is refused"
  /// (EmberWarpCore.kt's REFUSAL_LINE).
  static const refusalLine = 'the tunnel will handshake but carry no traffic';

  static String get _coreExe {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    return '$dir${sep}aether${sep}aether.exe';
  }

  static String get _dataRoot => CoreLocator.dataDir(const []);

  Directory get _identityDir => Directory('$_dataRoot/emberwarp');
  Directory get _stagingDir => Directory('$_dataRoot/emberwarp-renewal');
  Directory get _workDir => Directory('$_dataRoot/emberwarp-work');
  File get _logFile => File('${_workDir.path}/warp.log');
  File get _pidFile => File('${_workDir.path}/core.pid');

  bool get _available => File(_coreExe).existsSync();

  bool get _identityPresent {
    final files = _identityDir.listSync();
    return files.any((f) => f is File && f.lengthSync() > 0);
  }

  Future<void> _appendLog(String line) async {
    try {
      await _workDir.create(recursive: true);
      await _logFile.writeAsString('$line\n', mode: FileMode.append);
    } catch (_) {
      // Logging must never break the engine.
    }
  }

  Map<String, String> _envFor(Directory dir) => {
    ...Platform.environment,
    'AETHER_CONFIG': '${dir.path}/aether.toml',
    'AETHER_MASQUE_CONFIG': '${dir.path}/masque.toml',
    'AETHER_WG_CONFIG': '${dir.path}/wg.toml',
    'AETHER_REPROVISION': '0',
    'HOME': dir.path,
    'TMPDIR': _workDir.path,
  };

  Future<void> settle() async {
    final staging = _stagingDir;
    final marker = File('${staging.path}/ready');
    if (!marker.existsSync()) return;
    final live = _identityDir;
    await live.create(recursive: true);
    for (final f in staging.listSync()) {
      if (f is File && !f.path.endsWith('${Platform.pathSeparator}ready')) {
        final target = File('${live.path}/${f.uri.pathSegments.last}');
        try {
          try {
            await f.rename(target.path);
          } catch (_) {
            await f.copy(target.path);
            await f.delete();
          }
        } catch (_) {
          // A file that will not move stays staged; the next
          // start retries.
        }
      }
    }
    await marker.delete();
    _renewNeeded = false;
    await _appendLog('emberwarp: renewed identity settled');
  }

  Future<void> _reapOrphan() async {
    try {
      if (!_pidFile.existsSync()) return;
      final pid = int.tryParse((await _pidFile.readAsString()).trim());
      if (pid == null) return;
      // The Windows counterpart of the /proc cmdline check:
      // tasklist confirms the pid is our sidecar before killing.
      final result = await Process.run('tasklist', [
        '/FI',
        'PID eq $pid',
        '/FO',
        'CSV',
        '/NH',
      ]);
      if ('${result.stdout}'.contains('aether.exe')) {
        await Process.run('taskkill', ['/PID', '$pid', '/F']);
        await _appendLog('emberwarp: reaped orphan core pid $pid');
      }
    } catch (_) {
      // No orphan, or it is already gone.
    } finally {
      try {
        await _pidFile.delete();
      } catch (_) {}
    }
  }

  Future<bool> start(List<String> args, {int port = 20850}) async {
    await stop();
    await settle();
    await _reapOrphan();
    if (!_available) {
      _stage = 'error';
      _lastError = 'the EmberWarp core is missing';
      return false;
    }
    final idDir = _identityDir;
    await idDir.create(recursive: true);
    await _workDir.create(recursive: true);
    final log = _logFile;
    if (log.existsSync() && log.lengthSync() > 512 * 1024) {
      await log.delete();
    }
    _logOffset = log.existsSync() ? log.lengthSync() : 0;
    try {
      final p = await Process.start(
        _coreExe,
        args,
        workingDirectory: idDir.path,
        environment: _envFor(idDir),
      );
      _process = p;
      _running = true;
      _ready = false;
      _stage = 'starting';
      _lastError = '';
      try {
        await _pidFile.writeAsString('${p.pid}');
      } catch (_) {}
      final sink = log.openWrite(mode: FileMode.append);
      p.stdout.listen(sink.add, onError: (_) {});
      p.stderr.listen(sink.add, onError: (_) {});
      unawaited(
        p.exitCode.then((_) async {
          if (identical(_process, p)) {
            _process = null;
            _running = false;
            _ready = false;
            if (_stage == 'starting' || _stage == 'ready') {
              _stage = _renewNeeded ? 'refused' : 'error';
              if (_lastError.isEmpty) {
                _lastError = 'the EmberWarp core stopped';
              }
            }
          }
          await sink.flush();
          await sink.close();
        }),
      );
      unawaited(_watchReadiness(p, port));
      _watchLog(p);
      return true;
    } catch (e) {
      _running = false;
      _stage = 'error';
      _lastError = 'the EmberWarp core could not start: $e';
      return false;
    }
  }

  Future<void> _watchReadiness(Process p, int port) async {
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(seconds: 10),
      );
      // SOCKS5 greeting: VER=5, one method, no-auth. The core
      // answers only after a gateway carried a real check.
      socket.add([5, 1, 0]);
      await socket.flush();
      final reply = <int>[];
      await for (final chunk in socket.timeout(
        Duration(
          milliseconds: deadline
              .difference(DateTime.now())
              .inMilliseconds
              .clamp(1, 45000),
        ),
      )) {
        reply.addAll(chunk);
        if (reply.length >= 2) break;
        if (DateTime.now().isAfter(deadline)) break;
      }
      socket.destroy();
      if (reply.length >= 2 && reply[0] == 5 && identical(_process, p)) {
        _ready = true;
        _stage = 'ready';
        return;
      }
    } catch (_) {
      // Falls through to the not-ready marking below.
    }
    if (identical(_process, p) && !_ready) {
      _stage = _renewNeeded ? 'refused' : 'error';
      if (_lastError.isEmpty) {
        _lastError = 'the EmberWarp core did not answer in time';
      }
    }
  }

  void _watchLog(Process p) {
    _logTimer?.cancel();
    _logTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!identical(_process, p)) {
        _logTimer?.cancel();
        return;
      }
      try {
        final file = _logFile;
        if (!file.existsSync() || file.lengthSync() <= _logOffset) return;
        final text = file.readAsStringSync();
        final fresh = text.substring(
          _logOffset.clamp(0, text.length),
        );
        if (fresh.contains(refusalLine)) {
          _renewNeeded = true;
          if (_stage == 'ready' || _stage == 'starting') {
            _stage = 'refused';
          }
          _lastError =
              'Cloudflare refused the saved WARP identity — renew the key to reconnect';
        }
        _logOffset = file.lengthSync();
      } catch (_) {
        // The next tick retries.
      }
    });
  }

  Future<void> stop() async {
    _logTimer?.cancel();
    final p = _process;
    _process = null;
    _running = false;
    _ready = false;
    if (_stage == 'starting' || _stage == 'ready') _stage = 'idle';
    if (p != null) {
      p.kill();
      try {
        await p.exitCode.timeout(const Duration(milliseconds: 400));
      } on TimeoutException {
        p.kill(ProcessSignal.sigkill);
      }
    }
    try {
      await _pidFile.delete();
    } catch (_) {}
  }

  /// The ONLY identity renewal path: registers a FRESH identity
  /// into staging and settles it over the live one. Blocking
  /// (up to ~2 minutes); true when a new identity landed.
  Future<bool> renew(String kind) async {
    await stop();
    if (!_available) return false;
    final staging = _stagingDir;
    await staging.create(recursive: true);
    for (final f in staging.listSync()) {
      try {
        await f.delete(recursive: true);
      } catch (_) {}
    }
    await _workDir.create(recursive: true);
    try {
      final env = _envFor(staging)..remove('AETHER_REPROVISION');
      final p = await Process.start(
        _coreExe,
        ['--register', kind],
        workingDirectory: staging.path,
        environment: env,
      );
      final sink = _logFile.openWrite(mode: FileMode.append);
      p.stdout.listen(sink.add, onError: (_) {});
      p.stderr.listen(sink.add, onError: (_) {});
      final deadline = DateTime.now().add(const Duration(seconds: 120));
      var done = false;
      while (DateTime.now().isBefore(deadline)) {
        var exited = false;
        unawaited(p.exitCode.then((_) => exited = true));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (exited) {
          done = true;
          break;
        }
        try {
          if (_logFile.existsSync() &&
              _logFile.readAsStringSync().contains('identities ready:')) {
            done = true;
            p.kill();
            break;
          }
        } catch (_) {}
      }
      p.kill();
      await sink.flush();
      await sink.close();
      final staged = staging
          .listSync()
          .any((f) => f is File && f.lengthSync() > 0);
      if (done && staged) {
        await File('${staging.path}/ready').writeAsString('ready');
        await settle();
        await _appendLog('emberwarp: identity renewed');
        return true;
      }
      await _appendLog('emberwarp: renewal did not complete');
      return false;
    } catch (e) {
      await _appendLog('emberwarp: renewal failed: $e');
      return false;
    }
  }

  Future<void> resetIdentity() async {
    await stop();
    for (final dir in [_identityDir, _stagingDir]) {
      if (dir.existsSync()) {
        for (final f in dir.listSync()) {
          try {
            await f.delete(recursive: true);
          } catch (_) {}
        }
      }
    }
    _renewNeeded = false;
    _stage = 'idle';
    _lastError = '';
    await _appendLog('emberwarp: identity reset by the user');
  }

  String get _logTail {
    try {
      final f = _logFile;
      if (!f.existsSync()) return '';
      final lines = f.readAsLinesSync();
      return lines.skip(lines.length > 40 ? lines.length - 40 : 0).join('\n');
    } catch (_) {
      return '';
    }
  }

  WarpCoreState state() => WarpCoreState(
    available: _available,
    running: _running,
    ready: _ready,
    stage: _stage,
    identityPresent: _identityDir.existsSync() && _identityPresent,
    renewNeeded: _renewNeeded,
    error: _lastError,
    logTail: _logTail,
  );
}
