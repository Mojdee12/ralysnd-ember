/// The Windows backend of the Xray engine (PLAN.md §3): the official
/// xray.exe sidecar, driven exactly the way the Android backend drives
/// its subprocess core (XrayVpnService / XrayTester in the Kotlin
/// tree), with the same method meanings and return shapes:
///
/// - [setOn] writes the shared builder's config JSON to the work
///   folder and starts `xray run -c config.json` there (the geo data
///   files the controller installs live in that folder, and the core
///   finds them in its working directory). Output goes to xray.log,
///   where the UI's log page reads it.
/// - [state]'s session counters come from the core's own "proxy"
///   outbound totals (a non-resetting stats query). Android instead
///   reports the app UID's TrafficStats delta, which has no desktop
///   equivalent; the proxy-outbound total is the closest honest
///   measure (it excludes direct/block traffic) — see M1-AUDIT.md.
/// - [trafficStats], [measureDelay], [speedTest] and [exitInfo] are
///   ports of XrayTester.kt: the same `xray api stats` command, the
///   same counters, the same test ports (11080–11260), the same
///   generate_204 targets, the same speed-test URL and windows, the
///   same Cloudflare trace → ip-api fallback chain. Like the Kotlin
///   (HttpURLConnection over a SOCKS Proxy), the HTTP goes through
///   dart:io's own SOCKS support (HttpClient.findProxy), not a
///   hand-rolled handshake.
///
/// Mode note: this is Xray's proxy mode — the tunnel exists as the
/// config's SOCKS/HTTP inbounds on loopback, like the Android proxy
/// mode. [setOn]'s dns/ipv6 are the Android TUN builder's inputs and
/// are unused here; system-wide capture (native TUN inbound or the
/// sing-tun bridge) is the PLAN §3 spike, not this backend. A hard
/// kill of the app can orphan xray.exe (Windows has no parent-death
/// signal and Dart cannot create a job object); graceful exits go
/// through [stop]. Both limits are recorded in M1-AUDIT.md.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/core_api.dart';
import 'xray_platform.dart';

class WindowsXrayBackend implements XrayBackend {
  Process? _process;
  String _name = '';
  int _sinceMs = 0;
  int _apiPort = 0;
  int _up = 0;
  int _down = 0;

  /// The sidecars (scripts/fetch-windows-sidecars.ps1, copied into the
  /// app folder by scripts/build-windows.ps1): `xray\xray.exe` beside
  /// the app, with its wintun.dll next to it for the TUN spike.
  static String get _xrayExe {
    final sep = Platform.pathSeparator;
    final dir = File(Platform.resolvedExecutable).parent.path;
    return '$dir${sep}xray${sep}xray.exe';
  }

  @override
  Future<Directory> workDir() async =>
      Directory('${CoreLocator.dataDir(const [])}/xray');

  // ---- tunnel ---------------------------------------------------------

  @override
  Future<void> setOn({
    required String config,
    required String name,
    required int socksPort,
    required String dns,
    required bool ipv6,
  }) async {
    final dir = await workDir();
    await dir.create(recursive: true);
    await stop();
    final configFile = File('${dir.path}/config.json');
    await configFile.writeAsString(config, flush: true);
    final sink = File('${dir.path}/xray.log')
        .openWrite(mode: FileMode.append);
    final p = await Process.start(
      _xrayExe,
      ['run', '-c', configFile.path],
      workingDirectory: dir.path,
    );
    _process = p;
    _name = name;
    _sinceMs = DateTime.now().millisecondsSinceEpoch;
    _apiPort = socksPort + 5000; // statsApiPort() in config_builder.
    _up = 0;
    _down = 0;
    p.stdout.listen(sink.add, onError: (_) {});
    p.stderr.listen(sink.add, onError: (_) {});
    unawaited(
      p.exitCode.then((_) async {
        if (identical(_process, p)) _process = null;
        await sink.flush();
        await sink.close();
      }),
    );
  }

  @override
  Future<void> stop() async {
    final p = _process;
    _process = null;
    _name = '';
    _sinceMs = 0;
    if (p == null) return;
    p.kill();
    try {
      await p.exitCode.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      p.kill(ProcessSignal.sigkill);
    }
  }

  @override
  Future<XrayState> state() async {
    if (_process == null) return XrayState.stopped;
    final up = await _counter(
      'outbound>>>proxy>>>traffic>>>uplink',
      reset: false,
    );
    final down = await _counter(
      'outbound>>>proxy>>>traffic>>>downlink',
      reset: false,
    );
    if (up != null && down != null) {
      _up = up;
      _down = down;
    }
    return XrayState(
      running: true,
      name: _name,
      sinceMs: _sinceMs,
      upBytes: _up,
      downBytes: _down,
    );
  }

  // ---- stats ------------------------------------------------------------

  /// One counter from the running core's StatsService, through the
  /// core binary's own `api stats` command — the Android tester's
  /// exact query, including its 5 s patience and the reply's missing
  /// "value" for a zero counter. Null when the query fails.
  Future<int?> _counter(String name, {required bool reset}) async {
    final port = _apiPort;
    if (port == 0) return null;
    try {
      final p = await Process.start(_xrayExe, [
        'api',
        'stats',
        '--server=127.0.0.1:$port',
        '-name',
        name,
        if (reset) '-reset',
      ]);
      final out = await p.stdout.transform(utf8.decoder).join().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          p.kill(ProcessSignal.sigkill);
          return '';
        },
      );
      final code = await p.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          p.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      if (code != 0) return null;
      final m = RegExp(r'"value"\s*:\s*(\d+)').firstMatch(out);
      return m == null ? 0 : int.parse(m.group(1)!);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, int>?> trafficStats(int apiPort) async {
    final saved = _apiPort;
    _apiPort = apiPort;
    try {
      final up = await _counter(
        'outbound>>>proxy>>>traffic>>>uplink',
        reset: true,
      );
      if (up == null) return null;
      final down = await _counter(
        'outbound>>>proxy>>>traffic>>>downlink',
        reset: true,
      );
      if (down == null) return null;
      return {'up': up, 'down': down};
    } finally {
      _apiPort = saved;
    }
  }

  // ---- tests (XrayTester.kt, ported) ------------------------------------

  static int _nextTestPort = 11080;

  static int _takePort() {
    final p = _nextTestPort;
    _nextTestPort += 2;
    if (_nextTestPort > 11260) _nextTestPort = 11080;
    return p;
  }

  /// An HTTP client whose traffic goes through the SOCKS proxy on
  /// 127.0.0.1:[socksPort] (dart:io's SOCKS support; the request's
  /// host name is sent to the proxy, so it resolves at the exit).
  static HttpClient _viaSocks(int socksPort, Duration timeout) =>
      HttpClient()
        ..connectionTimeout = timeout
        ..findProxy = (_) => 'SOCKS 127.0.0.1:$socksPort';

  /// Starts a throwaway instance of [configJson] (its `"port": 0`
  /// substituted, as the Dart builder writes it) and waits for its
  /// SOCKS port. The process, or null on failure.
  Future<Process?> _startInstance(String configJson, int port) async {
    final dir = Directory('${(await workDir()).path}/test');
    await dir.create(recursive: true);
    final configFile = File('${dir.path}/config-$port.json');
    final config = configJson
        .replaceAll('"port": 0', '"port": $port')
        .replaceAll('"port":0', '"port":$port');
    await configFile.writeAsString(config, flush: true);
    final sink = File('${dir.path}/test-$port.log')
        .openWrite(mode: FileMode.append);
    Process p;
    try {
      p = await Process.start(
        _xrayExe,
        ['run', '-c', configFile.path],
        workingDirectory: dir.path,
      );
    } catch (_) {
      await sink.close();
      return null;
    }
    p.stdout.listen(sink.add, onError: (_) {});
    p.stderr.listen(sink.add, onError: (_) {});
    unawaited(p.exitCode.then((_) async {
      await sink.flush();
      await sink.close();
    }));
    if (await _waitForPort(p, port, const Duration(seconds: 12))) return p;
    await _kill(p);
    return null;
  }

  Future<bool> _waitForPort(Process p, int port, Duration timeout) async {
    var exited = false;
    unawaited(p.exitCode.then((_) => exited = true));
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (exited) return false;
      try {
        final s = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(milliseconds: 300),
        );
        await s.close();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
    return false;
  }

  Future<void> _kill(Process p) async {
    p.kill();
    try {
      await p.exitCode.timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      p.kill(ProcessSignal.sigkill);
    }
  }

  @override
  Future<int> measureDelay(String testConfig) async {
    final port = _takePort();
    final proc = await _startInstance(testConfig, port);
    if (proc == null) return -1;
    try {
      var best = -1;
      for (var i = 0; i < 2; i++) {
        final ms = await _timeRequest(port);
        if (ms >= 0 && (best < 0 || ms < best)) best = ms;
      }
      return best;
    } finally {
      await _kill(proc);
    }
  }

  /// Times a generate_204 request through the tunnel on [port]
  /// (plain HTTP target first, then HTTPS, as the Android tester):
  /// the clock stops when the response arrives, which is what
  /// HttpURLConnection's responseCode waits for.
  Future<int> _timeRequest(int socksPort) async {
    for (final url in [
      'http://www.gstatic.com/generate_204',
      'https://www.google.com/generate_204',
    ]) {
      final client = _viaSocks(socksPort, const Duration(seconds: 8));
      try {
        final started = Stopwatch()..start();
        final request = await client
            .getUrl(Uri.parse(url))
            .timeout(const Duration(seconds: 8));
        request.followRedirects = false;
        final response = await request
            .close()
            .timeout(const Duration(seconds: 8));
        started.stop();
        unawaited(response.drain<void>().catchError((_) {}));
        if (response.statusCode == 204 || response.statusCode == 200) {
          return started.elapsedMilliseconds;
        }
      } catch (_) {
        // Try the next target.
      } finally {
        client.close(force: true);
      }
    }
    return -1;
  }

  @override
  Future<int> speedTest(String testConfig) async {
    final port = _takePort();
    final proc = await _startInstance(testConfig, port);
    if (proc == null) return -1;
    final client = _viaSocks(port, const Duration(seconds: 8));
    try {
      final request = await client
          .getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=50000000'))
          .timeout(const Duration(seconds: 8));
      final started = Stopwatch()..start();
      final response = await request
          .close()
          .timeout(const Duration(seconds: 15));
      var total = 0;
      await for (final chunk in response.timeout(
        const Duration(seconds: 15),
      )) {
        total += chunk.length;
        if (started.elapsed > const Duration(seconds: 8)) break;
      }
      started.stop();
      final seconds = started.elapsedMilliseconds / 1000.0;
      if (seconds <= 0 || total == 0) return -1;
      return (total / seconds).round();
    } catch (_) {
      return -1;
    } finally {
      client.close(force: true);
      await _kill(proc);
    }
  }

  @override
  Future<Map<String, String>?> exitInfo(int socksPort) async {
    try {
      final text = await _httpGetText(
        socksPort,
        'https://www.cloudflare.com/cdn-cgi/trace',
      );
      if (text != null) {
        var ip = '';
        var loc = '';
        for (final line in text.split('\n')) {
          if (line.startsWith('ip=')) ip = line.substring(3).trim();
          if (line.startsWith('loc=')) loc = line.substring(4).trim();
        }
        if (ip.isNotEmpty) return {'ip': ip, 'countryCode': loc};
      }
    } catch (_) {
      // Fall through to ip-api.
    }
    try {
      final text = await _httpGetText(
        socksPort,
        'http://ip-api.com/json/?fields=status,query,country,countryCode',
      );
      if (text != null) {
        final doc = jsonDecode(text) as Map<String, dynamic>;
        final ip = doc['query'] as String? ?? '';
        if (ip.isNotEmpty) {
          return {
            'ip': ip,
            'countryCode': doc['countryCode'] as String? ?? '',
            'country': doc['country'] as String? ?? '',
          };
        }
      }
    } catch (_) {
      // Best-effort only.
    }
    return null;
  }

  /// A whole small GET through the tunnel, as text; null on failure.
  Future<String?> _httpGetText(int socksPort, String url) async {
    const timeout = Duration(seconds: 6);
    final client = _viaSocks(socksPort, timeout);
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      return await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }
}
