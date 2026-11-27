/// The Windows twin of Android's SubprocessCore (build 2072):
/// the shared lifecycle for a tunnel helper that ships as a
/// standalone executable in a sidecar folder beside the app
/// (scripts/fetch-windows-sidecars.ps1 stages them;
/// scripts/build-windows.ps1 copies each folder next to the
/// app). One backend per helper, with the same semantics the
/// Kotlin lifecycle pins:
///
/// - The child PID is written to a pid file at spawn; orphans
///   from a previous app life are reaped by exact executable
///   path (core/orphan_cleanup.dart) before the next spawn —
///   never a name-only kill, so a user's own same-named core
///   from another install is left alone.
/// - stdout and stderr are drained SEPARATELY into SEPARATE
///   log files in the helper's work dir and are never merged:
///   a helper's readiness and failure words live on a specific
///   stream. Both files flush per line and rotate past
///   512 KB (checked every 200 lines).
/// - A waiter owns unexpected exit: stage becomes "error" and
///   the error names the exit code and the last stderr line,
///   so a start failure surfaces as a plain error plus a log
///   line, never as a silent dead port.
/// - Readiness is per-helper ([tcpProbe]): a TCP listener is
///   probed by connecting to it (and the spawned process must
///   still be alive afterwards — a stale listener must not be
///   blessed); a UDP forwarder has no handshake to probe, so
///   readiness is a liveness window (the process must survive
///   its own argument parsing and listener bind).
/// - With a TCP probe, start waits for the helper's port to
///   be free first (up to 3 s): the orphan kill is
///   fire-and-forget, and spawning onto a still-held port
///   would let the probe bless a FOREIGN listener while our
///   process dies on bind.
///
/// Stop kills the child process (helpers spawn no children of
/// their own). The facades (sidecar_platform.dart,
/// dnstt_platform.dart, wstunnel_platform.dart,
/// olcrtc_platform.dart) dispatch here on Windows, exactly as
/// warp_platform.dart dispatches to its Windows backend.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/core_api.dart';
import '../core/orphan_cleanup.dart';

/// The state shape every subprocess facade publishes.
class SubprocessSnapshot {
  final bool available;
  final bool running;
  final bool ready;

  /// idle | starting | ready | error
  final String stage;
  final String error;
  final String logTail;

  const SubprocessSnapshot({
    this.available = false,
    this.running = false,
    this.ready = false,
    this.stage = 'idle',
    this.error = '',
    this.logTail = '',
  });
}

class WindowsSubprocessCore {
  WindowsSubprocessCore({
    required this.sidecarFolder,
    required this.exeName,
    required this.dirName,
    required this.port,
    required this.tcpProbe,
    required this.label,
    this.probeTimeoutMs = 20000,
  });

  /// The folder beside the app executable holding the binary.
  final String sidecarFolder;

  /// The executable's file name inside [sidecarFolder].
  final String exeName;

  /// The per-helper directory under the app data dir (logs +
  /// pid file), named exactly as Android's filesDir child.
  final String dirName;

  /// The fixed loopback port the helper listens on.
  final int port;

  /// True: readiness = the TCP listener accepts. False:
  /// readiness = the process survives the startup window.
  final bool tcpProbe;

  /// Short human name for errors ("DNSTT client").
  final String label;

  /// How long the readiness probe waits for the TCP listener
  /// (OLCRTC passes 120 s — its SOCKS listener opens only
  /// after its WebRTC link is up).
  final int probeTimeoutMs;

  bool _running = false;
  bool _ready = false;
  String _stage = 'idle';
  String _error = '';
  Process? _process;
  bool _exited = false;
  int _generation = 0;
  final List<String> _stderrTail = [];

  String get _exePath {
    final sep = Platform.pathSeparator;
    final dir = File(Platform.resolvedExecutable).parent.path;
    return '$dir$sep$sidecarFolder$sep$exeName';
  }

  bool get _available => File(_exePath).existsSync();

  Future<Directory> workDir() async {
    final dir = Directory(
      '${CoreLocator.dataDir(const [])}${Platform.pathSeparator}$dirName',
    );
    await dir.create(recursive: true);
    return dir;
  }

  File _pidFile(Directory dir) => File('${dir.path}/core.pid');

  String get _logTail => _stderrTail.join('\n');

  SubprocessSnapshot snapshot() => SubprocessSnapshot(
        available: _available,
        running: _running,
        ready: _ready,
        stage: _stage,
        error: _error,
        logTail: _logTail,
      );

  /// Spawns the helper with [args] (built on the Dart side,
  /// exactly as Android's start receives them). Returns true
  /// when the process started; readiness completes
  /// asynchronously — poll [snapshot].
  Future<bool> start(List<String> args) async {
    await stop();
    final dir = await workDir();
    // Reap a previous life's orphan by exact path (the pid
    // file names it too, but the path match is the guard that
    // keeps a foreign same-named core safe).
    await killOrphanedSidecars(exePath: _exePath, processName: exeName);
    try {
      await _pidFile(dir).delete();
    } catch (_) {
      // No pid file; nothing recorded.
    }
    if (!_available) {
      _stage = 'error';
      _error = 'the $label is missing';
      return false;
    }
    if (tcpProbe && !await _waitPortFree(port, const Duration(seconds: 3))) {
      _stage = 'error';
      _error = "the $label's port $port is still in use";
      return false;
    }
    _stderrTail.clear();
    final generation = ++_generation;
    try {
      final p = await Process.start(
        _exePath,
        args,
        workingDirectory: dir.path,
        environment: {
          'HOME': dir.path,
          'TMPDIR': Directory.systemTemp.path,
        },
      );
      _process = p;
      _exited = false;
      _running = true;
      _ready = false;
      _stage = 'starting';
      _error = '';
      // No stdin on either platform (Android redirects from
      // /dev/null); closing ours is the same statement.
      unawaited(p.stdin.close().catchError((_) => null));
      try {
        await _pidFile(dir).writeAsString('${p.pid}');
      } catch (_) {
        // Best-effort bookkeeping only.
      }
      _drain(p.stdout, File('${dir.path}/$dirName-stdout.log'), false);
      _drain(p.stderr, File('${dir.path}/$dirName-stderr.log'), true);
      _watchExit(p, generation);
      unawaited(_watchReadiness(p, generation));
      return true;
    } catch (e) {
      _running = false;
      _stage = 'error';
      _error = 'the $label could not start: $e';
      return false;
    }
  }

  /// Stop + start with the same arguments (a supervisor's
  /// revival path, as on Android).
  Future<bool> restart(List<String> args) async {
    await stop();
    return start(args);
  }

  Future<void> stop() async {
    final p = _process;
    _process = null;
    _generation++;
    _running = false;
    _ready = false;
    if (_stage == 'starting' || _stage == 'ready') _stage = 'idle';
    if (p != null) {
      try {
        p.kill();
      } catch (_) {
        // Already gone.
      }
    }
    try {
      final dir = await workDir();
      await _pidFile(dir).delete();
    } catch (_) {
      // Nothing recorded.
    }
  }

  /// Records a start failure decided before spawn (the Mieru
  /// config-apply step): the facade's state() then reports it
  /// exactly as Android's core does.
  void recordStartError(String error) {
    _running = false;
    _ready = false;
    _stage = 'error';
    _error = error;
  }

  Future<bool> _waitPortFree(int port, Duration budget) async {
    final deadline = DateTime.now().add(budget);
    while (true) {
      Socket? probe;
      try {
        probe = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(milliseconds: 300),
        );
        // Something answers: the port is held. Wait it out.
        await probe.close();
        if (DateTime.now().isAfter(deadline)) return false;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      } catch (_) {
        return true;
      } finally {
        probe?.destroy();
      }
    }
  }

  void _drain(Stream<List<int>> stream, File logFile, bool isStderr) {
    unawaited(() async {
      IOSink? sink;
      var linesSinceCheck = 0;
      try {
        try {
          if (await logFile.length() > 512 * 1024) await logFile.delete();
        } catch (_) {
          // A fresh log is a nicety, never a blocker.
        }
        var out = logFile.openWrite(mode: FileMode.append);
        sink = out;
        await for (final line
            in stream.transform(utf8.decoder).transform(const LineSplitter())) {
          if (isStderr) {
            _stderrTail.add(line);
            while (_stderrTail.length > 20) {
              _stderrTail.removeAt(0);
            }
          }
          try {
            out.writeln(line);
            await out.flush();
            if (++linesSinceCheck >= 200) {
              linesSinceCheck = 0;
              if (await logFile.length() > 512 * 1024) {
                await out.close();
                await logFile.delete();
                out = logFile.openWrite(mode: FileMode.append);
                sink = out;
              }
            }
          } catch (_) {
            // The log must never kill the drain.
          }
        }
      } catch (_) {
        // Stream closed with the process; nothing to do.
      } finally {
        try {
          await sink?.close();
        } catch (_) {
          // Already closed.
        }
      }
    }());
  }

  void _watchExit(Process p, int generation) {
    unawaited(() async {
      final code = await p.exitCode;
      if (!identical(_process, p) || generation != _generation) return;
      _process = null;
      _exited = true;
      _running = false;
      _ready = false;
      if (_stage != 'idle') {
        _stage = 'error';
        final tail = _stderrTail.isEmpty ? '' : _stderrTail.last;
        _error = 'the $label exited (code $code)' + (tail.isEmpty ? '' : ': $tail');
      }
    }());
  }

  Future<void> _watchReadiness(Process p, int generation) async {
    bool current() => identical(_process, p) && generation == _generation;
    if (tcpProbe) {
      final deadline = DateTime.now().add(Duration(milliseconds: probeTimeoutMs));
      while (DateTime.now().isBefore(deadline)) {
        if (!current() || _exited) return; // watchExit owns the error.
        Socket? probe;
        try {
          probe = await Socket.connect(
            '127.0.0.1',
            port,
            timeout: const Duration(milliseconds: 400),
          );
          await probe.close();
          // The port answering is not enough — the spawned
          // process must still be alive (a stale listener
          // satisfies the probe too); watchExit owns the
          // error when it died.
          if (!current() || _exited) return;
          _ready = true;
          _stage = 'ready';
          return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        } finally {
          probe?.destroy();
        }
      }
      if (current() && !_ready) {
        _stage = 'error';
        _error = 'the $label did not open its listener in time';
      }
    } else {
      // UDP forwarder: no handshake exists to probe. Surviving
      // the startup window means the args parsed and the
      // listener bound — wstunnel dies instantly on either.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (current() && !_exited) {
        _ready = true;
        _stage = 'ready';
      }
    }
  }
}

/// The per-helper Windows backends, one per Android
/// SubprocessCore object, with its exact port/probe contract.
abstract final class WindowsSubprocesses {
  static final singbox = WindowsSubprocessCore(
    sidecarFolder: 'singbox',
    exeName: 'sing-box.exe',
    dirName: 'singbox',
    port: 20862,
    tcpProbe: true,
    label: 'sing-box engine',
  );

  static final sudokubox = WindowsSubprocessCore(
    sidecarFolder: 'sudokubox',
    exeName: 'sudokubox.exe',
    dirName: 'sudokubox',
    port: 20865,
    tcpProbe: true,
    label: 'Sudoku engine',
  );

  static final zapret = WindowsSubprocessCore(
    sidecarFolder: 'zapret',
    exeName: 'ciadpi.exe',
    dirName: 'zapret',
    port: 20864,
    tcpProbe: true,
    label: 'Zapret desync proxy',
  );

  static final mieru = WindowsSubprocessCore(
    sidecarFolder: 'mieru',
    exeName: 'mieru.exe',
    dirName: 'mieru',
    port: 20863,
    tcpProbe: true,
    label: 'Mieru client',
  );

  static final dnscrypt = WindowsSubprocessCore(
    sidecarFolder: 'dnscrypt',
    exeName: 'dnscrypt-proxy.exe',
    dirName: 'dnscrypt',
    port: 20530,
    tcpProbe: true,
    label: 'DNSCrypt proxy',
  );

  static final dnstt = WindowsSubprocessCore(
    sidecarFolder: 'dnstt',
    exeName: 'dnstt-client.exe',
    dirName: 'dnstt',
    port: 20860,
    tcpProbe: true,
    label: 'DNSTT client',
  );

  static final wstunnel = WindowsSubprocessCore(
    sidecarFolder: 'wstunnel',
    exeName: 'wstunnel.exe',
    dirName: 'wstunnel',
    port: 20861,
    tcpProbe: false,
    label: 'wstunnel client',
  );

  static final olcrtc = WindowsSubprocessCore(
    sidecarFolder: 'olcrtc',
    exeName: 'olcrtc.exe',
    dirName: 'olcrtc',
    port: 20866,
    tcpProbe: true,
    label: 'OLCRTC client',
    probeTimeoutMs: 120000,
  );

  /// Mieru's start carries the whole client config JSON
  /// (MieruCore.startWithConfig): the config is written
  /// atomically into the work dir, applied with
  /// `mieru replace config <file>` (which must exit 0), and
  /// only then is the daemon spawned with `run`.
  static Future<bool> startMieru(String configJson) async {
    final core = mieru;
    await core.stop();
    if (!core._available) {
      core.recordStartError('the Mieru client is missing');
      return false;
    }
    final dir = await core.workDir();
    final configFile = File('${dir.path}/client-config.json');
    try {
      final tmp = File('${configFile.path}.tmp');
      await tmp.writeAsString(configJson, flush: true);
      await tmp.rename(configFile.path);
      final result = await Process.run(
        core._exePath,
        ['replace', 'config', configFile.path],
        workingDirectory: dir.path,
        environment: {'HOME': dir.path, 'TMPDIR': Directory.systemTemp.path},
      ).timeout(const Duration(seconds: 30));
      if (result.exitCode != 0) {
        final out = ('${result.stdout}${result.stderr}').trim();
        core.recordStartError(
          'the Mieru client rejected its config' +
              (out.isEmpty ? '' : ': ${out.split('\n').first}'),
        );
        return false;
      }
    } catch (e) {
      core.recordStartError('the Mieru client could not take its config: $e');
      return false;
    }
    return core.start(['run']);
  }
}
