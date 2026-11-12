/// The WARP+ engine on Windows: bepass-org/warp-plus (pinned
/// v1.2.6, the same release Android stages as libwarpplus.so —
/// its source is in this workspace and it ships official
/// Windows builds) as the `warp\warp-plus.exe` sidecar.
///
/// The contract mirrors WarpVpnService.kt: argv is
/// `--bind 127.0.0.1:8086 --cache-dir <identity> --dns <dns>`
/// plus `--scan --rtt 1000ms`, `--gool`, or
/// `--cfon --country XX`, and `--endpoint <ep>` when pinned.
/// The identity persists in the cache dir across restarts
/// (warp-plus self-registers; no key is ever entered). The
/// service reports running once the core serves its SOCKS,
/// and connected once a Cloudflare trace THROUGH the tunnel
/// answers warp=on — the same proof the Android side uses.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/core_api.dart';
import 'warp_platform.dart';

class WindowsWarpBackend {
  Process? _process;
  bool _starting = false;
  bool _connected = false;
  bool _failed = false;
  String _failure = '';
  String _mode = '';
  int _sinceMs = 0;
  Timer? _proofTimer;

  static const socksPort = WarpPlatform.socksPort;

  static String get _coreExe {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    return '$dir${sep}warp${sep}warp-plus.exe';
  }

  Directory get _workDir {
    final d = Directory('${CoreLocator.dataDir(const [])}/warp');
    d.createSync(recursive: true);
    return d;
  }

  Future<void> setOn({
    required String mode,
    required bool scan,
    required String country,
    required String endpoint,
    required String dns,
  }) async {
    await stop();
    if (!File(_coreExe).existsSync()) {
      _failed = true;
      _failure = 'warp-plus.exe is missing from this build';
      throw StateError(_failure);
    }
    final dir = _workDir;
    final cache = Directory('${dir.path}/identity');
    await cache.create(recursive: true);
    final args = <String>[
      '--bind',
      '127.0.0.1:$socksPort',
      '--cache-dir',
      cache.path,
      '--dns',
      dns,
      if (scan) ...['--scan', '--rtt', '1000ms'],
      if (mode == 'gool') '--gool',
      if (mode == 'cfon') ...['--cfon', '--country', country],
      if (endpoint.isNotEmpty) ...['--endpoint', endpoint],
    ];
    final sink = File('${dir.path}/warp.log').openWrite(
      mode: FileMode.append,
    );
    sink.writeln('--- warp-plus start ${DateTime.now().toIso8601String()} ---');
    try {
      final p = await Process.start(
        _coreExe,
        args,
        workingDirectory: dir.path,
      );
      _process = p;
      _starting = true;
      _connected = false;
      _failed = false;
      _failure = '';
      _mode = mode;
      _sinceMs = DateTime.now().millisecondsSinceEpoch;
      p.stdout.listen(sink.add, onError: (_) {});
      p.stderr.listen(sink.add, onError: (_) {});
      unawaited(
        p.exitCode.then((code) async {
          if (identical(_process, p)) {
            _process = null;
            _starting = false;
            _connected = false;
            _failed = true;
            _failure = 'warp-plus exited (code $code) — see warp.log';
          }
          await sink.flush();
          await sink.close();
        }),
      );
      _proofTimer?.cancel();
      _proofTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
        if (_process == null || _connected) return;
        final trace = await _trace();
        if (trace != null &&
            (trace['warp'] == 'on' || trace['warp'] == 'plus')) {
          _connected = true;
          _starting = false;
        }
      });
    } catch (e) {
      _failed = true;
      _failure = 'warp-plus could not start: $e';
      throw StateError(_failure);
    }
  }

  Future<void> stop() async {
    _proofTimer?.cancel();
    final p = _process;
    _process = null;
    _starting = false;
    _connected = false;
    _mode = '';
    _sinceMs = 0;
    if (p != null) {
      p.kill();
      try {
        await p.exitCode.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        p.kill(ProcessSignal.sigkill);
      }
    }
  }

  Future<WarpState> state() async {
    final running = _process != null;
    return WarpState(
      running: running && (_starting || _connected),
      starting: running && _starting && !_connected,
      connected: running && _connected,
      failed: _failed,
      failure: _failure,
      mode: running ? _mode : '',
      sinceMs: running ? _sinceMs : 0,
      upBytes: 0,
      downBytes: 0,
    );
  }

  /// A Cloudflare trace through the tunnel's SOCKS, parsed to
  /// the exit-info shape ({ip, countryCode, country, city}).
  Future<Map<String, String>?> exitInfo() async {
    final trace = await _trace();
    if (trace == null) return null;
    final ip = trace['ip'] ?? '';
    if (ip.isEmpty) return null;
    return {
      'ip': ip,
      'countryCode': (trace['loc'] ?? '').toUpperCase(),
      'country': '',
      'city': '',
    };
  }

  Future<Map<String, String>?> _trace() async {
    try {
      final body = await _socksHttpGet(
        'www.cloudflare.com',
        '/cdn-cgi/trace',
      );
      if (body == null) return null;
      final out = <String, String>{};
      for (final line in body.split('\n')) {
        final i = line.indexOf('=');
        if (i > 0) {
          out[line.substring(0, i).trim()] = line.substring(i + 1).trim();
        }
      }
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  /// A minimal SOCKS5 client: CONNECT to [host]:80 through the
  /// warp SOCKS and one plain HTTP/1.1 GET (the trace endpoint
  /// answers over HTTP; no TLS needed for a liveness proof).
  Future<String?> _socksHttpGet(String host, String path) async {
    final socket = await Socket.connect(
      '127.0.0.1',
      socksPort,
      timeout: const Duration(seconds: 6),
    );
    final buffer = <int>[];
    Completer<void>? waiter;
    final sub = socket.listen((chunk) {
      buffer.addAll(chunk);
      final w = waiter;
      if (w != null && !w.isCompleted) w.complete();
    });
    Future<void> need(int n) async {
      while (buffer.length < n) {
        waiter = Completer<void>();
        await waiter!.future.timeout(const Duration(seconds: 6));
      }
    }

    try {
      socket.add([5, 1, 0]);
      await socket.flush();
      await need(2);
      if (buffer[0] != 5 || buffer[1] != 0) return null;
      buffer.clear();
      final hostBytes = utf8.encode(host);
      socket.add([5, 1, 0, 3, hostBytes.length, ...hostBytes, 0, 80]);
      await socket.flush();
      await need(4);
      if (buffer[0] != 5 || buffer[1] != 0) return null;
      buffer.clear();
      socket.write(
        'GET $path HTTP/1.1\r\nHost: $host\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n',
      );
      await socket.flush();
      final deadline = DateTime.now().add(const Duration(seconds: 6));
      while (DateTime.now().isBefore(deadline)) {
        final text = utf8.decode(buffer, allowMalformed: true);
        if (text.contains('\r\n\r\n') &&
            (text.contains('warp=') || buffer.length > 200)) {
          final split = text.indexOf('\r\n\r\n');
          return text.substring(split + 4);
        }
        waiter = Completer<void>();
        try {
          await waiter!.future.timeout(const Duration(seconds: 1));
        } on TimeoutException {
          // Re-check the buffer on the next loop.
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      await sub.cancel();
      socket.destroy();
    }
  }
}
