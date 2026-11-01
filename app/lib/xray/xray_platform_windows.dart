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
///   speed-test URL and windows, the same Cloudflare trace → ip-api
///   fallback chain. One transport difference, forced by dart:io:
///   Java's Proxy.Type.SOCKS has no equivalent — HttpClient's
///   findProxy accepts only DIRECT and PROXY (a "SOCKS" line throws
///   "Invalid proxy configuration" on every request, which is why
///   the delay test could never answer on Windows). The requests
///   therefore go through the core's HTTP inbound with a PROXY line:
///   the running tunnel config already carries one, and the
///   throwaway test instances get one injected next to their SOCKS
///   inbound (the second port of each test pair). The measured time
///   is the same: a request through the tunnel to the target and
///   back. The target list adds the standard connectivity-check
///   fallbacks (Cloudflare, Microsoft) to the Android tester's
///   Google pair, since a filtered network may not reach Google
///   even through a healthy tunnel.
///
/// Mode note: [setOn]'s [tunCapture] chooses the mode. Off is proxy
/// mode — the tunnel exists as the config's SOCKS/HTTP inbounds on
/// loopback, like the Android proxy mode. On (the default) adds
/// system-wide capture: the bundled ember-tun-bridge helper holds a
/// session with the installed TUN service (the tree's own privileged
/// service, core/internal/tunapi) that routes the whole system into
/// the config's SOCKS inbound, xray.exe itself kept outside the TUN
/// (see M1-AUDIT.md for why the bridge, not Xray's native TUN
/// inbound: the adapter needs an elevated process, and the only
/// sanctioned elevation channel in the tree is that service, whose
/// protocol forwards TUN→SOCKS). A failed bridge fails the connect:
/// the app never shows connected while traffic would leak direct.
/// [setOn]'s dns/ipv6 are the Android TUN builder's inputs and are
/// unused here. A hard kill of the app can orphan xray.exe (Windows
/// has no parent-death signal and Dart cannot create a job object);
/// the bridge is not orphaned — its stdin pipe closes with the app,
/// which takes the TUN down. Graceful exits go through [stop]. The
/// limits are recorded in M1-AUDIT.md.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/core_api.dart';
import '../core/tun_bridge.dart';
import 'xray_platform.dart';

class WindowsXrayBackend implements XrayBackend {
  Process? _process;
  TunBridge? _bridge;
  String _name = '';
  int _sinceMs = 0;
  int _apiPort = 0;
  int _up = 0;
  int _down = 0;

  /// The HTTP inbound port of the running tunnel config, read from
  /// the config at [setOn]: the test/exit requests ride it (see the
  /// library doc for why not SOCKS). 0 = unknown.
  int _httpPort = 0;

  /// The last start/test failure, in words, for [state] — the UI
  /// shows it and it is also written to xray.log.
  String _lastError = '';

  /// Consecutive throwaway-instance start failures; two in a row
  /// (or one instant exit) raise the firewall/antivirus guidance.
  int _startFailures = 0;

  /// Shown when the sidecar dies at once or will not start at all:
  /// the usual cause on a real PC is a security product, and a
  /// silent -1 left that undiagnosable.
  static const firewallGuidance =
      'xray.exe exited immediately or could not start. Windows '
      'Firewall or antivirus may be blocking it — allow xray.exe '
      'in Windows Security / your antivirus, then try again.';

  /// The sidecars (scripts/fetch-windows-sidecars.ps1, copied into the
  /// app folder by scripts/build-windows.ps1): `xray\xray.exe` beside
  /// the app, with its wintun.dll next to it for the TUN spike.
  static String get _xrayExe {
    final sep = Platform.pathSeparator;
    final dir = File(Platform.resolvedExecutable).parent.path;
    return '$dir${sep}xray${sep}xray.exe';
  }

  /// The folder holding xray.exe and its geo data files.
  static String get _xrayDir {
    final sep = Platform.pathSeparator;
    final dir = File(Platform.resolvedExecutable).parent.path;
    return '$dir${sep}xray';
  }

  /// The spawn environment for the core: the geo files resolve from
  /// the sidecar folder whatever the working directory is (the test
  /// instances run from a subfolder, and a config naming geoip: /
  /// geosite: categories must not depend on copied files).
  static Map<String, String> get _xrayEnv => {'XRAY_LOCATION_ASSET': _xrayDir};

  /// The last [maxChars] characters of a log file, for error text.
  static Future<String> _logTail(String path, {int maxChars = 700}) async {
    try {
      final text = await File(path).readAsString();
      final trimmed = text.trimRight();
      return trimmed.length <= maxChars
          ? trimmed
          : trimmed.substring(trimmed.length - maxChars);
    } catch (_) {
      return '';
    }
  }

  /// Appends a backend note to the main xray.log, so a failure is
  /// diagnosable from the app's Logs page.
  Future<void> _noteToLog(String line) async {
    try {
      final dir = await workDir();
      await dir.create(recursive: true);
      final sink = File('${dir.path}/xray.log').openWrite(mode: FileMode.append);
      sink.writeln(line);
      await sink.flush();
      await sink.close();
    } catch (_) {
      // Best-effort only.
    }
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
    bool tunCapture = false,
  }) async {
    final dir = await workDir();
    await dir.create(recursive: true);
    await stop();
    _lastError = '';
    // The config's HTTP inbound port, for the exit-info requests
    // (they ride the HTTP proxy — see the library doc). Falls back
    // to the builder's usual socks+1 pairing when unparsable.
    _httpPort = socksPort + 1;
    try {
      final doc = jsonDecode(config) as Map<String, dynamic>;
      for (final inbound in (doc['inbounds'] as List? ?? const [])) {
        if (inbound is Map && inbound['protocol'] == 'http') {
          _httpPort = (inbound['port'] as num).toInt();
        }
      }
    } catch (_) {
      // The fallback above stands.
    }
    final configFile = File('${dir.path}/config.json');
    await configFile.writeAsString(config, flush: true);
    final logFile = File('${dir.path}/xray.log');
    final sink = logFile.openWrite(mode: FileMode.append);
    sink.writeln('--- xray start ${DateTime.now().toIso8601String()} ---');
    Process p;
    try {
      p = await Process.start(
        _xrayExe,
        ['run', '-c', configFile.path],
        workingDirectory: dir.path,
        environment: _xrayEnv,
      );
    } catch (e) {
      _lastError = 'could not start xray.exe: $e. $firewallGuidance';
      sink.writeln('[ember] $_lastError');
      await sink.flush();
      await sink.close();
      throw StateError(_lastError);
    }
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
    // The core must really be serving before the connect counts as
    // up — in BOTH modes. A core that died on its config (or was
    // killed at spawn) otherwise still showed "connected" in proxy
    // mode while nothing listened, and the failure stayed silent.
    try {
      await _waitForSocks(p, socksPort);
    } on StateError catch (e) {
      final tail = await _logTail(logFile.path);
      _lastError = e.message == 'xray-exited'
          ? 'the xray core exited at start. $firewallGuidance'
              '${tail.isEmpty ? '' : '\nCore log:\n$tail'}'
          : 'the xray core did not start listening on port $socksPort.'
              '${tail.isEmpty ? '' : '\nCore log:\n$tail'}';
      await stop();
      throw StateError(_lastError);
    }
    if (!tunCapture) return;
    // System-wide capture: the SOCKS inbound is verified serving
    // (above) before the TUN points the system at it.
    try {
      _bridge = await TunBridge.start(
        socksPort: socksPort,
        skipProgram: 'xray.exe',
        log: sink,
      );
    } catch (e) {
      _lastError = 'system-wide capture (TUN) failed: $e';
      await stop();
      throw StateError(_lastError);
    }
    final bridge = _bridge!;
    unawaited(bridge.down.then((_) {
      // The TUN ended under a live core: tear the run down so the
      // state goes stopped instead of leaking traffic direct.
      if (identical(_bridge, bridge) && _process != null) {
        unawaited(stop());
      }
    }));
  }

  /// Waits until the fresh core accepts on its SOCKS port (10 s),
  /// failing when the process exits first.
  Future<void> _waitForSocks(Process p, int socksPort) async {
    for (var i = 0; i < 40; i++) {
      if (!identical(_process, p)) throw StateError('xray-exited');
      try {
        final socket = await Socket.connect(
          '127.0.0.1',
          socksPort,
          timeout: const Duration(milliseconds: 500),
        );
        await socket.close();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    throw StateError('xray-no-listen');
  }

  @override
  Future<void> stop() async {
    final bridge = _bridge;
    _bridge = null;
    if (bridge != null) await bridge.stop();
    final p = _process;
    _process = null;
    _name = '';
    _sinceMs = 0;
    _httpPort = 0;
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
      lastError: _lastError,
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

  /// An HTTP client whose traffic goes through the core's HTTP
  /// proxy on 127.0.0.1:[httpPort] — dart:io's PROXY line, the only
  /// proxy form findProxy implements (see the library doc). The
  /// target host name travels in the request/CONNECT, so it
  /// resolves at the exit.
  static HttpClient _viaProxy(int httpPort, Duration timeout) =>
      HttpClient()
        ..connectionTimeout = timeout
        ..findProxy = (_) => 'PROXY 127.0.0.1:$httpPort';

  /// Starts a throwaway instance of [configJson] on [port] and waits
  /// for its SOCKS port. The config is decoded, not string-patched:
  /// the SOCKS inbound takes [port], and an HTTP inbound is added
  /// on port+1 (the pair's second port) for the timed requests.
  /// The process, or null on failure — with the failure recorded in
  /// [_lastError] and copied into the main xray.log.
  Future<Process?> _startInstance(String configJson, int port) async {
    final dir = Directory('${(await workDir()).path}/test');
    await dir.create(recursive: true);
    final configFile = File('${dir.path}/config-$port.json');
    String config;
    try {
      final doc = jsonDecode(configJson) as Map<String, dynamic>;
      final inbounds = (doc['inbounds'] as List).cast<dynamic>();
      for (final inbound in inbounds) {
        if (inbound is Map && inbound['protocol'] == 'socks') {
          inbound['port'] = port;
        }
      }
      inbounds.add({
        'tag': 'http',
        'listen': '127.0.0.1',
        'port': port + 1,
        'protocol': 'http',
        'settings': {'allowTransparent': false},
      });
      config = jsonEncode(doc);
    } catch (_) {
      // A config that does not decode keeps the historical string
      // substitution for its `"port": 0` SOCKS inbound.
      config = configJson
          .replaceAll('"port": 0', '"port": $port')
          .replaceAll('"port":0', '"port":$port');
    }
    await configFile.writeAsString(config, flush: true);
    final logPath = '${dir.path}/test-$port.log';
    final sink = File(logPath).openWrite(mode: FileMode.append);
    final startedAt = DateTime.now();
    Process p;
    try {
      p = await Process.start(
        _xrayExe,
        ['run', '-c', configFile.path],
        workingDirectory: dir.path,
        environment: _xrayEnv,
      );
    } catch (e) {
      await sink.close();
      await _instanceFailed(port, logPath, startedAt, 'spawn: $e');
      return null;
    }
    p.stdout.listen(sink.add, onError: (_) {});
    p.stderr.listen(sink.add, onError: (_) {});
    unawaited(p.exitCode.then((_) async {
      await sink.flush();
      await sink.close();
    }));
    if (await _waitForPort(p, port, const Duration(seconds: 12))) {
      _startFailures = 0;
      return p;
    }
    await _kill(p);
    // Let the exit handler flush the instance log before reading it.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await _instanceFailed(port, logPath, startedAt, 'no-listen');
    return null;
  }

  /// Records a throwaway instance's failed start: the instance
  /// log's tail goes into the main xray.log and [_lastError]; an
  /// instant exit, or the second failure in a row, adds the
  /// firewall/antivirus guidance.
  Future<void> _instanceFailed(
    int port,
    String logPath,
    DateTime startedAt,
    String why,
  ) async {
    _startFailures++;
    final instant =
        DateTime.now().difference(startedAt) < const Duration(seconds: 1);
    final tail = await _logTail(logPath, maxChars: 500);
    final guidance = (instant || _startFailures >= 2)
        ? ' $firewallGuidance'
        : '';
    _lastError = 'the delay-test core failed to start ($why).$guidance';
    await _noteToLog(
      '[ember] test instance on $port failed ($why): '
      '${tail.isEmpty ? '(no core output)' : tail}$guidance',
    );
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
        final ms = await _timeRequest(port + 1);
        if (ms >= 0 && (best < 0 || ms < best)) best = ms;
      }
      return best;
    } finally {
      await _kill(proc);
    }
  }

  /// The connectivity-check targets, in order: the Android tester's
  /// Google pair plus the standard Cloudflare and Microsoft checks.
  /// A filtered network may block one provider's endpoints outright
  /// even through a healthy tunnel; the first target that answers
  /// wins.
  static const _delayTargets = [
    'http://www.gstatic.com/generate_204',
    'https://www.google.com/generate_204',
    'http://cp.cloudflare.com/generate_204',
    'https://cp.cloudflare.com/generate_204',
    'http://www.msftconnecttest.com/connecttest.txt',
  ];

  /// Times a connectivity-check request through the tunnel via the
  /// HTTP proxy on [httpPort]: the clock stops when the response
  /// arrives, which is what HttpURLConnection's responseCode waits
  /// for on Android.
  Future<int> _timeRequest(int httpPort) async {
    for (final url in _delayTargets) {
      final client = _viaProxy(httpPort, const Duration(seconds: 8));
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
    final client = _viaProxy(port + 1, const Duration(seconds: 8));
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
    // The requests ride the running config's HTTP inbound (recorded
    // at setOn); [socksPort] is the Android-shaped parameter, kept
    // for the fallback pairing when no port was recorded.
    final httpPort = _httpPort != 0 ? _httpPort : socksPort + 1;
    try {
      final text = await _httpGetText(
        httpPort,
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
        httpPort,
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
  Future<String?> _httpGetText(int httpPort, String url) async {
    const timeout = Duration(seconds: 6);
    final client = _viaProxy(httpPort, timeout);
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
