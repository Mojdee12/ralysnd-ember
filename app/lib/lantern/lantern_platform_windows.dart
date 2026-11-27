/// The Lantern engine on Windows (W3, full-parity build):
/// the radiance daemon (lanternd.exe, built with the
/// `novpn` tag — scripts/fetch-windows-sidecars.ps1) serves
/// a mixed SOCKS/HTTP inbound on 127.0.0.1:12080 instead of
/// owning a TUN, and Ember captures through its own TUN
/// bridge exactly as it does for Psiphon. The daemon's
/// control API lives on a Windows named pipe Dart cannot
/// dial, so a thin Go bridge (lantern-bridge.exe, built
/// from win-work/lantern-bridge over radiance's own IPC
/// client) re-serves it as JSON lines on stdio.
///
/// The published state follows the Android contract
/// (lantern_platform.dart): "connected" is the daemon's own
/// VPN status, never a local guess; traffic counters are
/// the daemon usage totals' delta since the connect (its
/// ThisMonth counters only move forward). The kill switch
/// keeps Ember's TUN bridge up on the dead SOCKS port when
/// the daemon dies unexpectedly — Android's hold shape.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/android_core.dart';
import '../core/core_api.dart';
import '../core/tun_bridge.dart';
import 'lantern_platform.dart';

abstract final class WindowsLanternBackend {
  /// The daemon's mixed inbound (RADIANCE_SOCKS_ADDRESS).
  static const socksPort = 12080;

  static Process? _daemon;
  static Process? _bridgeProc;
  static StreamSubscription<String>? _bridgeLines;
  static final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  static int _nextId = 0;
  static bool _bridgeUp = false;

  static bool _sessionOn = false;
  static bool _connecting = false;
  static bool _killSwitch = false;
  static bool _killSwitchHeld = false;
  static TunBridge? _tun;
  static int _sinceMs = 0;
  static String? _lastError;
  static String _privateResult = '';
  static bool _smartRouting = false;
  static ({int up, int down})? _usageBase;
  static List<Map<String, dynamic>> _servers = const [];
  static Map<String, dynamic>? _selected;
  static String _vpnStatus = 'disconnected';
  static DateTime _serversAt = DateTime.fromMillisecondsSinceEpoch(0);
  static IOSink? _logSink;

  static String get _exeDir => File(Platform.resolvedExecutable).parent.path;
  static String get _daemonExe =>
      '$_exeDir${Platform.pathSeparator}lantern'
      '${Platform.pathSeparator}lanternd.exe';
  static String get _bridgeExe =>
      '$_exeDir${Platform.pathSeparator}lantern'
      '${Platform.pathSeparator}lantern-bridge.exe';

  /// The daemon's data root: <dataDir>/lantern, with its
  /// logs in the logs/ child the controller's readLogs
  /// already reads (<filesDir>/lantern/logs).
  static Directory get _workDir =>
      Directory('${CoreLocator.dataDir(const [])}/lantern');
  static File get _logFile => File('${_workDir.path}/lantern-host.log');

  static bool get _available =>
      File(_daemonExe).existsSync() && File(_bridgeExe).existsSync();

  static void _log(String line) {
    try {
      _logSink ??= _logFile.openWrite(mode: FileMode.append);
      _logSink!.writeln(
        '[${DateTime.now().toIso8601String()}] [lantern-host] $line',
      );
      unawaited(_logSink!.flush());
    } catch (_) {
      // The record is best-effort at the edges.
    }
  }

  // ---- the bridge (stdio JSON lines) ----------------------

  static Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    final proc = _bridgeProc;
    if (proc == null || !_bridgeUp) {
      throw StateError('lantern bridge is not running');
    }
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    proc.stdin.writeln(
      jsonEncode({'id': id, 'method': method, 'params': params}),
    );
    await proc.stdin.flush();
    return completer.future.timeout(
      const Duration(seconds: 35),
      onTimeout: () {
        _pending.remove(id);
        throw StateError('lantern bridge did not answer $method');
      },
    );
  }

  static void _onBridgeLine(String line) {
    Map<String, dynamic> doc;
    try {
      doc = (jsonDecode(line) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final id = (doc['id'] as num?)?.toInt() ?? 0;
    final completer = _pending.remove(id);
    if (completer == null) return;
    if (doc['ok'] == true) {
      final result = doc['result'];
      completer.complete(
        result is Map ? result.cast<String, dynamic>() : <String, dynamic>{},
      );
    } else {
      completer.completeError(
        StateError((doc['error'] as String?) ?? 'lantern bridge error'),
      );
    }
  }

  static void _bridgeDown(String why) {
    _bridgeUp = false;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError(why));
    }
    _pending.clear();
  }

  // ---- process management ---------------------------------

  static Future<void> _reapStale(File pidFile, String image) async {
    try {
      if (!await pidFile.exists()) return;
      final pid = int.tryParse((await pidFile.readAsString()).trim());
      if (pid != null) {
        final r = await Process.run('tasklist', [
          '/FI',
          'PID eq $pid',
          '/FO',
          'CSV',
          '/NH',
        ]);
        if ('${r.stdout}'.contains(image)) {
          await Process.run('taskkill', ['/PID', '$pid', '/F']);
        }
      }
      await pidFile.delete();
    } catch (_) {
      // A stale pid file must never block a start.
    }
  }

  static Future<void> _ensureUp() async {
    if (_daemon != null && _bridgeUp) return;
    if (!_available) {
      throw StateError(
        'The Lantern core is not in this build '
        '(lanternd.exe / lantern-bridge.exe missing).',
      );
    }
    await _workDir.create(recursive: true);
    await Directory('${_workDir.path}/logs').create(recursive: true);
    final daemonPid = File('${_workDir.path}/lanternd.pid');
    final bridgePid = File('${_workDir.path}/bridge.pid');
    if (_daemon == null) {
      await _reapStale(daemonPid, 'lanternd.exe');
      _log('starting lanternd (novpn, socks 127.0.0.1:$socksPort)');
      final proc = await Process.start(
        _daemonExe,
        [
          'run',
          '--data-path',
          _workDir.path,
          '--log-path',
          '${_workDir.path}/logs',
        ],
        environment: {'RADIANCE_SOCKS_ADDRESS': '127.0.0.1:$socksPort'},
      );
      _daemon = proc;
      await daemonPid.writeAsString('${proc.pid}', flush: true);
      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) => _log('lanternd: $l'));
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) => _log('lanternd! $l'));
      unawaited(
        proc.exitCode.then((code) {
          if (identical(_daemon, proc)) {
            _daemon = null;
            _onDaemonExit(code);
          }
        }),
      );
    }
    if (_bridgeProc == null) {
      await _reapStale(bridgePid, 'lantern-bridge.exe');
      final proc = await Process.start(_bridgeExe, const []);
      _bridgeProc = proc;
      await bridgePid.writeAsString('${proc.pid}', flush: true);
      _bridgeUp = true;
      _bridgeLines = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onBridgeLine);
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) => _log('bridge! $l'));
      unawaited(
        proc.exitCode.then((code) {
          if (identical(_bridgeProc, proc)) {
            _bridgeProc = null;
            _bridgeDown('lantern bridge exited ($code)');
          }
        }),
      );
    }
    // The daemon's pipe comes up asynchronously; the first
    // answered status call is the readiness proof.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      try {
        final s = await _call('status');
        _vpnStatus = (s['vpnStatus'] as String?) ?? 'disconnected';
        return;
      } catch (_) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('The Lantern daemon did not come up.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
  }

  static void _onDaemonExit(int code) {
    _log('lanternd exited ($code)');
    if (!_sessionOn) return;
    // An unexpected death mid-session: the kill switch
    // holds Ember's TUN on the dead SOCKS (blackhole);
    // without it the bridge comes down and traffic returns
    // to the direct path, Android's shape both ways.
    if (_killSwitch && _tun != null) {
      _killSwitchHeld = true;
      _lastError = 'The Lantern core stopped unexpectedly.';
    } else {
      unawaited(_stopTun());
      _sessionOn = false;
      _lastError = 'The Lantern core stopped unexpectedly.';
    }
  }

  static Future<void> _stopTun() async {
    final tun = _tun;
    _tun = null;
    try {
      await tun?.stop();
    } catch (_) {}
  }

  static Future<void> _killProcesses() async {
    try {
      await _call('quit');
    } catch (_) {}
    await _bridgeLines?.cancel();
    _bridgeLines = null;
    _bridgeDown('lantern host stopped');
    final bridge = _bridgeProc;
    _bridgeProc = null;
    bridge?.kill();
    final daemon = _daemon;
    _daemon = null;
    daemon?.kill();
  }

  // ---- the facade contract --------------------------------

  static Future<void> setOn({
    required bool on,
    bool ipv6 = true,
    required int mtu,
    String dns = '1.1.1.1',
    bool killSwitch = false,
    String tag = '',
    String pinCountry = '',
    String pinCode = '',
    bool smartOn = false,
  }) async {
    if (!on) return stop();
    _killSwitch = killSwitch;
    _killSwitchHeld = false;
    _lastError = null;
    _sessionOn = true;
    _connecting = true;
    _sinceMs = DateTime.now().millisecondsSinceEpoch;
    // The start runs in the background (daemon boot + the
    // daemon's own connect can take a while); state()
    // reports the progress, as Android's service model does.
    unawaited(_start(tag: tag, smartOn: smartOn));
  }

  static Future<void> _start({
    required String tag,
    required bool smartOn,
  }) async {
    try {
      await _ensureUp();
      try {
        final s = await _call('smartRouting', {'on': smartOn});
        _smartRouting = s['smartRouting'] == true;
      } catch (e) {
        _log('smart routing apply failed: $e');
      }
      try {
        final u = await _call('usage');
        _usageBase = (
          up: (u['up'] as num?)?.toInt() ?? 0,
          down: (u['down'] as num?)?.toInt() ?? 0,
        );
      } catch (_) {
        _usageBase = null;
      }
      await _call('connect', {'tag': tag});
      // Wait for the daemon's own connected verdict before
      // raising Ember's TUN onto its SOCKS inbound.
      final deadline = DateTime.now().add(const Duration(seconds: 180));
      while (true) {
        if (!_sessionOn) return; // stopped meanwhile
        final s = await _call('status');
        _vpnStatus = (s['vpnStatus'] as String?) ?? 'disconnected';
        final sel = s['selected'];
        _selected = sel is Map ? sel.cast<String, dynamic>() : null;
        if (_vpnStatus == 'connected') break;
        if (_vpnStatus == 'error') {
          throw StateError('The Lantern core could not connect.');
        }
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('The Lantern core did not connect in time.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      await _refreshServers();
      final sink = _logSink ??= _logFile.openWrite(mode: FileMode.append);
      _tun = await TunBridge.start(
        socksPort: socksPort,
        skipProgram: 'lanternd.exe',
        log: sink,
        logDir: _workDir,
      );
      _connecting = false;
      _log('connected; TUN bridge up on 127.0.0.1:$socksPort');
    } catch (e) {
      _connecting = false;
      _sessionOn = false;
      _lastError = e is StateError ? e.message : '$e';
      _log('start failed: $_lastError');
      try {
        await _call('disconnect');
      } catch (_) {}
    }
  }

  static Future<void> stop() async {
    _sessionOn = false;
    _connecting = false;
    _killSwitchHeld = false;
    await _stopTun();
    try {
      if (_bridgeUp) await _call('disconnect');
    } catch (_) {}
    await _killProcesses();
    _vpnStatus = 'disconnected';
    _selected = null;
    _usageBase = null;
  }

  static Future<void> _refreshServers() async {
    try {
      final r = await _call('servers');
      final list = r['servers'];
      if (list is List) {
        _servers = [
          for (final e in list)
            if (e is Map) e.cast<String, dynamic>(),
        ];
        _serversAt = DateTime.now();
      }
    } catch (_) {
      // The last list stays; the picker keeps its entries.
    }
  }

  static Future<LanternState> state() async {
    if (!_available) return const LanternState();
    if (_sessionOn && _bridgeUp) {
      try {
        final s = await _call('status');
        _vpnStatus = (s['vpnStatus'] as String?) ?? _vpnStatus;
        final sel = s['selected'];
        if (sel is Map) _selected = sel.cast<String, dynamic>();
      } catch (_) {}
      if (DateTime.now().difference(_serversAt) >
          const Duration(seconds: 30)) {
        unawaited(_refreshServers());
      }
    }
    var up = 0;
    var down = 0;
    var counters = false;
    if (_sessionOn && _bridgeUp && _usageBase != null) {
      try {
        final u = await _call('usage');
        final bu = (u['up'] as num?)?.toInt() ?? 0;
        final bd = (u['down'] as num?)?.toInt() ?? 0;
        up = bu > _usageBase!.up ? bu - _usageBase!.up : 0;
        down = bd > _usageBase!.down ? bd - _usageBase!.down : 0;
        counters = true;
      } catch (_) {}
    }
    final connected =
        _sessionOn && _vpnStatus == 'connected' && _tun != null;
    final stage = _killSwitchHeld
        ? 'error'
        : _lastError != null && !_sessionOn
        ? 'error'
        : connected
        ? 'up'
        : _sessionOn
        ? 'starting'
        : 'idle';
    return LanternState(
      available: true,
      running: _sessionOn,
      coreRunning: _daemon != null,
      connected: connected,
      killSwitchHeld: _killSwitchHeld,
      stage: stage,
      exitCity: (_selected?['city'] as String?) ?? '',
      exitCountry: (_selected?['country'] as String?) ?? '',
      exitCode: (_selected?['countryCode'] as String?) ?? '',
      selectedTag: (_selected?['tag'] as String?) ?? '',
      servers: _servers.isEmpty ? -1 : _servers.length,
      serversJson: jsonEncode([
        for (final s in _servers)
          {
            'tag': s['tag'] ?? '',
            'city': s['city'] ?? '',
            'country': s['country'] ?? '',
            'countryCode': s['countryCode'] ?? '',
            'isLantern': s['isLantern'] == true,
          },
      ]),
      smartRouting: _smartRouting,
      privateResult: _privateResult,
      sinceMs: _sessionOn ? _sinceMs : 0,
      upBytes: up,
      downBytes: down,
      countersReported: counters,
      error: _sessionOn ? null : _lastError,
    );
  }

  static Future<void> fetchServers() async {
    await _ensureUp();
    try {
      await _call('updateConfig');
    } catch (_) {}
    await _refreshServers();
  }

  static Future<void> setSmartRouting(bool on) async {
    _smartRouting = on;
    if (_bridgeUp) {
      try {
        final s = await _call('smartRouting', {'on': on});
        _smartRouting = s['smartRouting'] == true;
      } catch (e) {
        _log('smart routing set failed: $e');
      }
    }
  }

  static Future<void> addPrivateServer({
    required String ip,
    required int port,
    required String token,
    required String tag,
  }) async {
    try {
      await _ensureUp();
      await _call('addPrivate', {
        'tag': tag,
        'ip': ip,
        'port': port,
        'token': token,
      });
      _privateResult = 'ok|$tag';
      await _refreshServers();
    } catch (e) {
      _privateResult = 'error|${e is StateError ? e.message : e}';
      rethrow;
    }
  }

  static Future<void> removePrivateServer(String tag) async {
    await _ensureUp();
    await _call('removeServers', {
      'tags': [tag],
    });
    await _refreshServers();
  }

  static Future<void> switchServer(
    String tag, {
    String pinCountry = '',
    String pinCode = '',
  }) async {
    await _ensureUp();
    if (_sessionOn) {
      // A live switch re-runs the daemon's connect against
      // the new tag (the daemon's SelectServer + connect is
      // its own live-switch path); Ember's TUN bridge keeps
      // forwarding to the same SOCKS inbound throughout.
      await _call('connect', {'tag': tag});
    } else {
      await _call('select', {'tag': tag});
    }
  }
}
