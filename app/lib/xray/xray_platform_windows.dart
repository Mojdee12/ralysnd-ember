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
/// has no parent-death signal and Dart cannot create a job object),
/// so the first start/test of a run reaps leftover copies of THIS
/// app's sidecar by exact path (core/orphan_cleanup.dart) before
/// probing ports; if the configured SOCKS port is still taken —
/// another proxy client (v2rayN defaults to the same 10808), say —
/// the session falls back to the first free port trio instead of
/// dying on the bind. The bridge is not orphaned by a hard kill —
/// its stdin pipe closes with the app, which takes the TUN down.
/// Graceful exits go through [stop]. The limits are recorded in
/// M1-AUDIT.md.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/core_api.dart';
import '../core/orphan_cleanup.dart';
import '../core/ports.dart';
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

  /// The SOCKS port the live session actually bound (the configured
  /// port, or the fallback [setOn] picked when that was taken).
  int _localPort = 0;

  /// The session note for [state] ('' when there is nothing to
  /// say): the port fallback, and the proxy-mode warning — a
  /// proxy-only session must never read as a full connection.
  String _portNote = '';

  /// One-shot guard for the startup orphan reap ([_ensureCleaned]).
  bool _cleanedUp = false;

  /// The standalone EmberWarp session (build 2030's setOnWarp):
  /// no xray process — capture (or proxy mode) rides the
  /// EmberWarp core's own SOCKS, which the controller started.
  /// 0 = no such session.
  int _warpSinceMs = 0;
  String _warpName = '';

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

  /// Reaps xray.exe processes orphaned by a previous, hard-killed
  /// app run — only copies of THIS app's sidecar (exact path match;
  /// another client's core is never touched) and only while this
  /// backend holds no live process of its own. Runs once per app
  /// run; best-effort, its failures are logged and ignored.
  Future<void> _ensureCleaned() async {
    if (_cleanedUp || _process != null) return;
    _cleanedUp = true;
    final killed = await killOrphanedSidecars(
      exePath: _xrayExe,
      processName: 'xray.exe',
    );
    for (final pid in killed) {
      await _noteToLog(
        '[ember] killed orphaned xray.exe (pid $pid) left over '
        'from a previous run',
      );
    }
  }

  /// Whether the session's whole port trio — SOCKS [socks], its
  /// HTTP companion and the stats-API port — could bind now.
  static Future<bool> _trioFree(int socks, int http, int api) async =>
      await isFree(socks) && await isFree(http) && await isFree(api);

  // ---- tunnel ---------------------------------------------------------

  @override
  Future<void> setOn({
    required String config,
    required String name,
    required int socksPort,
    required String dns,
    required bool ipv6,
    bool tunCapture = false,
    // Chain underlay arguments (build 2032 contract): on Windows
    // the controller starts the underlay engines itself (the
    // Psiphon / EmberWarp Dart backends) and the chain wiring is
    // already inside the config's dialerProxy, so there is
    // nothing left for the backend to supervise.
    String underlay = 'none',
    String underlayRegion = '',
    String underlayUpstream = '',
    List<String> underlayProtocols = const [],
    List<String> warpArgs = const [],
  }) async {
    final dir = await workDir();
    await dir.create(recursive: true);
    // Reap a previous run's orphaned sidecar first: it may be the
    // very thing holding the configured port. Then end any session
    // of this run before probing, so our own listener cannot read
    // as a conflict.
    await _ensureCleaned();
    await stop();
    _lastError = '';
    // The config's inbound ports: SOCKS (the [socksPort] argument,
    // confirmed from the JSON), its HTTP companion (the exit-info
    // requests ride it — see the library doc) and the stats-API
    // port (statsApiPort() in config_builder: SOCKS + 5000).
    Map<String, dynamic>? doc;
    var origSocks = socksPort;
    var origHttp = socksPort + 1;
    var origApi = socksPort + 5000;
    try {
      doc = jsonDecode(config) as Map<String, dynamic>;
      for (final inbound in (doc['inbounds'] as List? ?? const [])) {
        if (inbound is! Map) continue;
        final port = (inbound['port'] as num?)?.toInt();
        if (port == null) continue;
        if (inbound['protocol'] == 'socks') origSocks = port;
        if (inbound['protocol'] == 'http') origHttp = port;
        if (inbound['tag'] == 'api') origApi = port;
      }
    } catch (_) {
      doc = null; // The derived defaults above stand.
    }
    // Port selection: the configured trio when it can bind (the
    // historical path, config written byte-for-byte), else the
    // first trio above it where SOCKS, its HTTP companion (same
    // offset) and SOCKS+5000 are all free — a taken 10808 (another
    // proxy client's default, a leftover core) must not be able to
    // kill every connect.
    var chosen = origSocks;
    var runConfig = config;
    var fallbackNote = '';
    if (!await _trioFree(origSocks, origHttp, origApi)) {
      chosen = -1;
      if (doc != null) {
        for (var k = 1; k <= 60; k++) {
          final cand = origSocks + k;
          final http = cand + (origHttp - origSocks);
          final api = cand + 5000;
          if (http > 65535 || api > 65535) break;
          if (await _trioFree(cand, http, api)) {
            chosen = cand;
            break;
          }
        }
      }
      if (chosen < 0) {
        _lastError = 'the local ports around $origSocks are all in '
            'use by other programs, so the xray core has nowhere to '
            'listen. Close the other proxy app (for example v2rayN) '
            'and try again.';
        await _noteToLog('[ember] $_lastError');
        throw StateError(_lastError);
      }
      for (final inbound in (doc!['inbounds'] as List? ?? const [])) {
        if (inbound is! Map) continue;
        if (inbound['protocol'] == 'socks') inbound['port'] = chosen;
        if (inbound['protocol'] == 'http') {
          inbound['port'] = chosen + (origHttp - origSocks);
        }
        if (inbound['tag'] == 'api') inbound['port'] = chosen + 5000;
      }
      runConfig = jsonEncode(doc);
      fallbackNote = 'Local port $origSocks was busy; this session '
          'runs on $chosen.';
    }
    _localPort = chosen;
    _httpPort = chosen + (origHttp - origSocks);
    final configFile = File('${dir.path}/config.json');
    await configFile.writeAsString(runConfig, flush: true);
    final logFile = File('${dir.path}/xray.log');
    final sink = logFile.openWrite(mode: FileMode.append);
    sink.writeln('--- xray start ${DateTime.now().toIso8601String()} ---');
    if (fallbackNote.isNotEmpty) {
      sink.writeln(
        '[ember] port $origSocks is busy, using $chosen for this '
        'session',
      );
    }
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
    _apiPort = chosen + 5000; // statsApiPort(), on the chosen base.
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
      await _waitForSocks(p, chosen);
    } on StateError catch (e) {
      final tail = await _logTail(logFile.path);
      _lastError = e.message == 'xray-exited'
          ? 'the xray core exited at start. $firewallGuidance'
              '${tail.isEmpty ? '' : '\nCore log:\n$tail'}'
          : 'the xray core did not start listening on port $chosen.'
              '${tail.isEmpty ? '' : '\nCore log:\n$tail'}';
      await stop();
      throw StateError(_lastError);
    }
    // The session's state notes, composed now that the core is
    // verified serving: the port fallback, and — critically — the
    // capture mode. Proxy mode must never read as a full
    // connection: the note is what the page's status bar shows
    // next to the profile name.
    _portNote = [
      if (fallbackNote.isNotEmpty) fallbackNote,
      if (!tunCapture) 'Proxy only — system capture off',
    ].join(' • ');
    if (!tunCapture) {
      sink.writeln(
        '[ember] proxy mode: system-wide capture (TUN) is OFF — '
        'only apps pointed at 127.0.0.1:$chosen use this tunnel; '
        'the rest of the system is not captured',
      );
      return;
    }
    sink.writeln(
      '[ember] TUN mode: starting system-wide capture via the TUN '
      'service (proxy 127.0.0.1:$chosen)',
    );
    // System-wide capture: the SOCKS inbound is verified serving
    // (above) before the TUN points the system at it.
    try {
      _bridge = await TunBridge.start(
        socksPort: chosen,
        skipProgram: 'xray.exe',
        log: sink,
        logDir: dir,
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

  /// The EmberWarp session SOCKS port (warp_args.dart's
  /// warpSessionPort, duplicated here to keep this backend free
  /// of a dependency on the profile layer).
  static const _warpSessionPort = 20850;

  @override
  Future<void> setOnWarp({
    required String name,
    required String dns,
    required bool ipv6,
    bool tunCapture = false,
    List<String> warpArgs = const [],
  }) async {
    await _ensureCleaned();
    await stop();
    _lastError = '';
    _warpName = name;
    _warpSinceMs = DateTime.now().millisecondsSinceEpoch;
    _localPort = _warpSessionPort;
    final dir = await workDir();
    await dir.create(recursive: true);
    final sink = File('${dir.path}/xray.log').openWrite(mode: FileMode.append);
    sink.writeln('--- emberwarp session ${DateTime.now().toIso8601String()} ---');
    if (!tunCapture) {
      _portNote = 'Proxy only — system capture off';
      sink.writeln(
        '[ember] EmberWarp proxy mode: only apps pointed at '
        '127.0.0.1:$_warpSessionPort use this tunnel',
      );
      await sink.flush();
      await sink.close();
      return;
    }
    try {
      _bridge = await TunBridge.start(
        socksPort: _warpSessionPort,
        skipProgram: 'aether.exe',
        log: sink,
        logDir: dir,
      );
    } catch (e) {
      _lastError = 'system-wide capture (TUN) failed: $e';
      _warpSinceMs = 0;
      await sink.flush();
      await sink.close();
      throw StateError(_lastError);
    }
    final bridge = _bridge!;
    unawaited(bridge.down.then((_) {
      if (identical(_bridge, bridge) && _warpSinceMs != 0) {
        unawaited(stop());
      }
    }));
    await sink.flush();
    await sink.close();
  }

  @override
  Future<bool> rotateConfig(String config) async {
    final p = _process;
    if (p == null || _localPort == 0) return false;
    // Rotation must not move the session's ports: the TUN bridge
    // points at the bound SOCKS port. A config that would bind a
    // different one is refused (the controller falls back to a
    // full reconnect for it).
    var socks = 0;
    try {
      final doc = jsonDecode(config) as Map<String, dynamic>;
      for (final inbound in (doc['inbounds'] as List? ?? const [])) {
        if (inbound is Map && inbound['protocol'] == 'socks') {
          socks = (inbound['port'] as num?)?.toInt() ?? 0;
        }
      }
    } catch (_) {
      return false;
    }
    if (socks != _localPort) return false;
    final dir = await workDir();
    final configFile = File('${dir.path}/config.json');
    await configFile.writeAsString(config, flush: true);
    _process = null;
    p.kill();
    try {
      await p.exitCode.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      p.kill(ProcessSignal.sigkill);
    }
    Process np;
    try {
      np = await Process.start(
        _xrayExe,
        ['run', '-c', configFile.path],
        workingDirectory: dir.path,
        environment: _xrayEnv,
      );
    } catch (_) {
      return false;
    }
    _process = np;
    final sink = File(
      '${dir.path}/xray.log',
    ).openWrite(mode: FileMode.append);
    np.stdout.listen(sink.add, onError: (_) {});
    np.stderr.listen(sink.add, onError: (_) {});
    unawaited(
      np.exitCode.then((_) async {
        if (identical(_process, np)) _process = null;
        await sink.flush();
        await sink.close();
      }),
    );
    try {
      await _waitForSocks(np, _localPort);
    } catch (_) {
      return false;
    }
    return true;
  }

  @override
  Future<void> stop() async {
    final bridge = _bridge;
    _bridge = null;
    if (bridge != null) await bridge.stop();
    final p = _process;
    _process = null;
    _warpSinceMs = 0;
    _warpName = '';
    _name = '';
    _sinceMs = 0;
    _httpPort = 0;
    _localPort = 0;
    _portNote = '';
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
    if (_process == null && _warpSinceMs != 0) {
      return XrayState(
        running: true,
        name: _warpName,
        sinceMs: _warpSinceMs,
        upBytes: 0,
        downBytes: 0,
        lastError: _lastError,
        localPort: _localPort,
        note: _portNote,
      );
    }
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
      localPort: _localPort,
      note: _portNote,
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
    // While a session runs, its own API port is the truth: it is
    // the configured port shifted by any fallback [setOn] took,
    // which the caller's settings-derived value cannot know.
    final effective =
        (_process != null && _apiPort != 0) ? _apiPort : apiPort;
    final saved = _apiPort;
    _apiPort = effective;
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

  /// The next test port pair (SOCKS + its injected HTTP companion)
  /// that can actually bind: the blind rotation above hands out
  /// ports another client may already hold, and a throwaway core
  /// that cannot listen reads as an endless "Failed". Falls back
  /// to the unchecked rotation if the whole range is taken.
  static Future<int> _takeTestPort() async {
    var candidate = _nextTestPort;
    for (var i = 0; i < 90; i++) {
      final p = candidate;
      candidate += 2;
      if (candidate > 11260) candidate = 11080;
      if (await isFree(p) && await isFree(p + 1)) {
        _nextTestPort = candidate;
        return p;
      }
    }
    return _takePort();
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
    await _ensureCleaned();
    final port = await _takeTestPort();
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

  @override
  Future<Map<String, dynamic>> measureDelayEx(String testConfig) async {
    final ms = await measureDelay(testConfig);
    if (ms >= 0) return {'ms': ms, 'error': ''};
    return {
      'ms': -1,
      'error': _lastError.isNotEmpty
          ? _lastError
          : 'the test core did not answer through the tunnel',
    };
  }

  @override
  Future<int> tunnelCheck(int socksPort) async {
    // One real request through the RUNNING session (its HTTP
    // inbound — see the library doc for why not SOCKS).
    if (_process == null && _warpSinceMs == 0) return -1;
    if (_httpPort == 0) return -1;
    return _timeRequest(_httpPort);
  }

  @override
  Future<Map<String, int>?> endurance(String testConfig) async {
    // The Android tester's qualification (build 2029A): three
    // probes at t=0, +2.5 s and +5.4 s over ONE keep-alive
    // connection through a throwaway core — a session that
    // freezes seconds after the handshake fails here even when
    // its first probe answered.
    await _ensureCleaned();
    final port = await _takeTestPort();
    final proc = await _startInstance(testConfig, port);
    if (proc == null) return null;
    try {
      final client = _viaProxy(
        port + 1,
        const Duration(seconds: 10),
      );
      final sw = Stopwatch()..start();
      Future<int> probe() async {
        final target = _delayTargets.first;
        final t0 = sw.elapsedMilliseconds;
        try {
          final req = await client
              .getUrl(Uri.parse(target))
              .timeout(const Duration(seconds: 10));
          final resp = await req.close().timeout(
            const Duration(seconds: 10),
          );
          await resp.drain<void>();
          return sw.elapsedMilliseconds - t0;
        } catch (_) {
          return -1;
        }
      }

      final p0 = await probe();
      final wait1 = 2500 - sw.elapsedMilliseconds;
      if (wait1 > 0) {
        await Future<void>.delayed(Duration(milliseconds: wait1));
      }
      final p1 = await probe();
      final wait2 = 5400 - sw.elapsedMilliseconds;
      if (wait2 > 0) {
        await Future<void>.delayed(Duration(milliseconds: wait2));
      }
      final p2 = await probe();
      client.close(force: true);
      return {'p0': p0, 'p1': p1, 'p2': p2, 'held': 1};
    } finally {
      await _kill(proc);
    }
  }

  @override
  Future<Map<String, String>?> networkFingerprint() async {
    // The Windows counterpart of the Android reading
    // ({type, operator}): type from the active network
    // interfaces (ethernet vs wifi cannot be told apart
    // reliably from Dart, so both report 'ethernet'/'wifi' by
    // interface name heuristics — the value only keys the
    // winning-shape cache), operator = the SSID / interface
    // description, hashed by the caller before it is stored.
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        if (iface.addresses.isEmpty) continue;
        final name = iface.name.toLowerCase();
        final wifi =
            name.contains('wi-fi') ||
            name.contains('wifi') ||
            name.contains('wlan') ||
            name.contains('wireless');
        return {
          'type': wifi ? 'wifi' : 'ethernet',
          'operator': iface.name,
        };
      }
    } catch (_) {
      // Best-effort only.
    }
    return null;
  }

  @override
  Future<String?> validateConfig(String config) async {
    // `xray run -test` against a temp copy: the same patched
    // core that will run the config judges it.
    final dir = await workDir();
    await dir.create(recursive: true);
    final file = File('${dir.path}/validate.json');
    try {
      await file.writeAsString(config, flush: true);
      final result = await Process.run(_xrayExe, [
        'run',
        '-test',
        '-c',
        file.path,
      ], workingDirectory: dir.path, environment: _xrayEnv).timeout(
        const Duration(seconds: 15),
      );
      if (result.exitCode == 0) return null;
      final out = '${result.stdout}\n${result.stderr}'.trim();
      return out.isEmpty ? 'the core rejected the config' : out;
    } catch (_) {
      return null; // Validation unavailable: never block a connect.
    } finally {
      try {
        await file.delete();
      } catch (_) {}
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
    await _ensureCleaned();
    final port = await _takeTestPort();
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
        'http://ip-api.com/json/?fields=status,query,country,countryCode,city',
      );
      if (text != null) {
        final doc = jsonDecode(text) as Map<String, dynamic>;
        final ip = doc['query'] as String? ?? '';
        if (ip.isNotEmpty) {
          return {
            'ip': ip,
            'countryCode': doc['countryCode'] as String? ?? '',
            'country': doc['country'] as String? ?? '',
            'city': doc['city'] as String? ?? '',
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
