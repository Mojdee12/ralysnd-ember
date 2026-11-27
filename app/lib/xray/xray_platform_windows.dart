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
import 'dart:typed_data';

import '../core/core_api.dart';
import '../core/orphan_cleanup.dart';
import '../core/ports.dart';
import '../core/tun_bridge.dart';
import 'warp_platform.dart';
import 'xray_platform.dart';

class WindowsXrayBackend implements XrayBackend {
  Process? _process;
  TunBridge? _bridge;

  /// The kill switch (W4): the last setOn/setOnWarp's flag,
  /// and the hold it raises when the session's core dies
  /// unexpectedly in TUN mode — the TUN bridge then stays
  /// UP on the dead SOCKS port (a blackhole: nothing leaves
  /// the PC) until stop() or a new setOn, Android's shape.
  bool _killSwitch = false;
  bool _killSwitchHeld = false;
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

  /// Successful config rotations this run (the facade's
  /// generation proof reads it through [state]).
  int _rotationGen = 0;

  /// The AmneziaWG problem record (see [setOnAwg]): a problem
  /// sequence that advances on every failed start, and its
  /// words. The sequence survives [stop] (the controller's
  /// walk reads it after its own teardown, exactly as on
  /// Android) and resets on the next plain [setOn].
  int _awgProblemSeq = 0;
  String _awgProblem = '';

  /// The live AmneziaWG session (see [setOnAwg]): the tunnel
  /// name (the service is `AmneziaWGTunnel$<name>`), when it
  /// started, and the figures the tunnel service's UAPI pipe
  /// last gave. 0/'' = no session.
  String _awgName = '';
  String _awgTunnelName = '';
  int _awgSinceMs = 0;
  bool _awgSeenRunning = false;
  bool _awgKillSwitch = false;
  int _awgHandshakeAgeSec = -1;
  int _awgRxBytes = 0;
  int _awgTxBytes = 0;
  DateTime? _awgUapiAt;
  bool _awgUapiInFlight = false;

  /// The AmneziaWG client (the fetch script extracts the
  /// pinned MSI beside the app): its tunnel-service commands
  /// install and remove the per-tunnel Windows services.
  static String get _awgExe {
    final sep = Platform.pathSeparator;
    final dir = File(Platform.resolvedExecutable).parent.path;
    return '$dir${sep}wireguard${sep}amneziawg.exe';
  }

  String get _awgServiceName => 'AmneziaWGTunnel\$$_awgTunnelName';

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
      final sink = File('${dir.path}/xray.log')
          .openWrite(mode: FileMode.append);
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
    // The Android TUN builder's MTU (build 2157 contract): the
    // Windows TUN service owns its interface MTU, so the value is
    // accepted and unused here — the config carries everything
    // else this backend needs.
    required int mtu,
    bool tunCapture = false,
    // Chain underlay arguments (build 2032 contract): on Windows
    // the controller starts the underlay engines itself (the
    // Psiphon / EmberWarp Dart backends) and the chain wiring is
    // already inside the config's dialerProxy, so there is
    // nothing left for the backend to supervise. The same holds
    // for the 2072/2134 helper legs (dnsttArgs / wstunnelArgs /
    // olcrtcArgs): the controller owns those processes on
    // Windows. socksUser/socksPass are inside the config's
    // inbounds already; bridge names an Android in-process
    // bridge the desktop does not have — accepted for
    // contract parity. killSwitch is live (W4): an
    // unexpected core death in TUN mode holds the TUN
    // bridge on the dead SOCKS port (see _onCoreDied).
    String underlay = 'none',
    String underlayRegion = '',
    String underlayUpstream = '',
    List<String> underlayProtocols = const [],
    List<String> warpArgs = const [],
    String socksUser = '',
    String socksPass = '',
    bool killSwitch = false,
    List<String> dnsttArgs = const [],
    bool wgWstunnel = false,
    List<String> wstunnelArgs = const [],
    List<String> olcrtcArgs = const [],
    String bridge = 'hev',
  }) async {
    final dir = await workDir();
    await dir.create(recursive: true);
    // Reap a previous run's orphaned sidecar first: it may be the
    // very thing holding the configured port. Then end any session
    // of this run before probing, so our own listener cannot read
    // as a conflict.
    await _ensureCleaned();
    await stop();
    _killSwitch = killSwitch;
    _lastError = '';
    _awgProblem = '';
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
        _lastError =
            'the local ports around $origSocks are all in '
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
      fallbackNote =
          'Local port $origSocks was busy; this session '
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
        final unexpected = identical(_process, p);
        if (unexpected) _process = null;
        await sink.flush();
        await sink.close();
        if (unexpected) _onCoreDied('the xray core');
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
    unawaited(
      bridge.down.then((_) {
        // The TUN ended under a live core: tear the run down so the
        // state goes stopped instead of leaking traffic direct.
        if (identical(_bridge, bridge) && _process != null) {
          unawaited(stop());
        }
      }),
    );
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
    // Accepted for contract parity (see setOn's note on MTU);
    // killSwitch is live (W4): state() holds the TUN bridge
    // when the EmberWarp core dies under a live session.
    required int mtu,
    bool tunCapture = false,
    List<String> warpArgs = const [],
    bool killSwitch = false,
  }) async {
    await _ensureCleaned();
    await stop();
    _killSwitch = killSwitch;
    _lastError = '';
    _warpName = name;
    _warpSinceMs = DateTime.now().millisecondsSinceEpoch;
    _localPort = _warpSessionPort;
    final dir = await workDir();
    await dir.create(recursive: true);
    final sink = File('${dir.path}/xray.log').openWrite(mode: FileMode.append);
    sink.writeln(
      '--- emberwarp session ${DateTime.now().toIso8601String()} ---',
    );
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
    unawaited(
      bridge.down.then((_) {
        if (identical(_bridge, bridge) && _warpSinceMs != 0) {
          unawaited(stop());
        }
      }),
    );
    await sink.flush();
    await sink.close();
  }

  @override
  Future<void> setOnAwg({
    required String settings,
    required String name,
    required String addresses,
    required String dns,
    required bool ipv6,
    required bool ipv4,
    required int mtu,
    bool killSwitch = false,
  }) async {
    // The Windows AmneziaWG engine (W2): the official
    // AmneziaWG Windows client (wireguard\amneziawg.exe, the
    // pinned MSI's payload) runs the tunnel as a per-tunnel
    // Windows service — AmneziaWGTunnel$<name> — which is the
    // platform's native shape of Android's WG Tunnel backend:
    // it takes the profile's .conf as-is, Amnezia parameters
    // (Jc/Jmin/Jmax/S1/S2/H1–H4) included, over Wintun.
    //
    // The hand-off transformations are Android's own, applied
    // to the text (buildAwgServiceConfig): the session DNS
    // replaces the config's DNS line, the Settings MTU is the
    // fallback when the profile carries none, and a peer
    // without AllowedIPs gets the family-gated full-tunnel
    // default.
    //
    // Installing or starting the tunnel service needs
    // administrator rights. A failure is recorded exactly the
    // way an Android engine start failure surfaces — a NEW
    // problem (sequence advanced, words in coreProblem) with
    // nothing running — so the controller's walk stops
    // waiting, words the failure as its own kind and falls
    // back to the plain Xray WireGuard leg. Nothing is faked.
    if (_awgTunnelName.isNotEmpty) await _stopAwgSession();
    if (!File(_awgExe).existsSync()) {
      _awgProblemSeq++;
      _awgProblem =
          'the AmneziaWG sidecar (wireguard\\amneziawg.exe) is '
          'missing from this build — this profile continues on '
          'the plain WireGuard leg, without its Amnezia '
          'obfuscation parameters';
      _lastError = _awgProblem;
      await _noteToLog('[ember] awg refused: $_awgProblem');
      return;
    }
    final tunnelName = awgTunnelNameFor(name);
    final dir = await workDir();
    final awgDir = Directory('${dir.path}/awg');
    await awgDir.create(recursive: true);
    final confFile = File('${awgDir.path}/$tunnelName.conf');
    await confFile.writeAsString(
      buildAwgServiceConfig(
        settings,
        dns: dns,
        ipv4: ipv4,
        ipv6: ipv6,
        mtu: mtu,
      ),
      flush: true,
    );
    _awgName = name;
    _awgTunnelName = tunnelName;
    _awgSeenRunning = false;
    _awgKillSwitch = killSwitch;
    _awgHandshakeAgeSec = -1;
    _awgRxBytes = 0;
    _awgTxBytes = 0;
    _awgUapiAt = null;

    // A service left registered by an earlier Ember session
    // starts directly; a fresh one is installed from the
    // config (which also starts it). Either step can refuse
    // without elevation — the words land in the problem.
    final existing = await _awgServiceState();
    String? failure;
    if (existing != null && existing != 'RUNNING') {
      failure = await _runAwg(['sc', 'start', _awgServiceName]);
    }
    if (existing == null || failure != null) {
      failure = await _runAwg([
        _awgExe,
        '/installtunnelservice',
        confFile.path,
      ]);
    }
    if (failure != null) {
      _awgProblemSeq++;
      _awgProblem =
          'AmneziaWG could not start its tunnel service: $failure'
          '${_looksLikeElevation(failure) ? ' Installing or starting '
              'the tunnel service needs administrator rights — run '
              'Ralysnd Ember as administrator and try again.' : ''}';
      _lastError = _awgProblem;
      _awgTunnelName = '';
      _awgName = '';
      await _noteToLog('[ember] awg failed: $_awgProblem');
      return;
    }
    _awgSinceMs = DateTime.now().millisecondsSinceEpoch;
    _awgProblem = '';
    await _noteToLog(
      '[ember] awg tunnel service $_awgServiceName starting '
      'for $name',
    );
  }

  bool _looksLikeElevation(String words) {
    final w = words.toLowerCase();
    return w.contains('access') && w.contains('denied') ||
        w.contains('privilege') ||
        w.contains('elevat') ||
        w.contains('administrator');
  }

  /// Runs one service command; null on success, else its last
  /// meaningful output line (the command's own words).
  Future<String?> _runAwg(List<String> argv) async {
    try {
      final r = await Process.run(
        argv.first,
        argv.sublist(1),
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 30));
      if (r.exitCode == 0) return null;
      final words = [
        (r.stderr as String? ?? '').trim(),
        (r.stdout as String? ?? '').trim(),
      ].where((s) => s.isNotEmpty).join(' ');
      final lines = words
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      return lines.isEmpty
          ? '${argv.first} exited with code ${r.exitCode}'
          : lines.last;
    } on TimeoutException {
      return '${argv.first} did not answer in 30s';
    } catch (e) {
      return '$e';
    }
  }

  /// The tunnel service's SCM state ('RUNNING', 'STOPPED', …),
  /// or null when no such service is registered.
  Future<String?> _awgServiceState() async {
    if (_awgTunnelName.isEmpty) return null;
    try {
      final r = await Process.run(
        'sc',
        ['query', _awgServiceName],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 5));
      if (r.exitCode != 0) return null;
      final out = r.stdout as String? ?? '';
      final m = RegExp(r'STATE\s*:\s*\d+\s+(\w+)').firstMatch(out);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  /// Stops the AWG session's tunnel service (disconnect keeps
  /// the service registered — Android's tunnel stays present
  /// too — so the next connect starts without reinstalling).
  /// A service that refuses to stop is uninstalled instead;
  /// the words land in the log either way, never silently.
  Future<void> _stopAwgSession() async {
    if (_awgTunnelName.isEmpty) return;
    final failure = await _runAwg(['sc', 'stop', _awgServiceName]);
    if (failure != null) {
      final un = await _runAwg([
        _awgExe,
        '/uninstalltunnelservice',
        _awgTunnelName,
      ]);
      await _noteToLog(
        '[ember] awg stop: sc stop said "$failure"'
        '${un == null ? '; the tunnel service was uninstalled' : '; uninstall said "$un"'}',
      );
    }
    _awgName = '';
    _awgTunnelName = '';
    _awgSinceMs = 0;
    _awgSeenRunning = false;
    _awgKillSwitch = false;
    _awgHandshakeAgeSec = -1;
    _awgRxBytes = 0;
    _awgTxBytes = 0;
  }

  /// The tunnel service's UAPI dump, read off its protected
  /// named pipe through PowerShell (the app's established
  /// Windows bridge — the OpenVPN vault rides it too): the
  /// handshake age and transfer counters the adoption proof
  /// and the session display read. Throttled to one read per
  /// few seconds of polling; any failure keeps the last
  /// figures (handshake age -1 = not known yet).
  void _refreshAwgUapi() {
    if (_awgUapiInFlight || _awgTunnelName.isEmpty) return;
    final at = _awgUapiAt;
    if (at != null && DateTime.now().difference(at).inSeconds < 4) return;
    _awgUapiAt = DateTime.now();
    _awgUapiInFlight = true;
    unawaited(() async {
      try {
        final pipe =
            'ProtectedPrefix\\Administrators\\AmneziaWG\\$_awgTunnelName';
        final script = '''
\$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', '$pipe', [System.IO.Pipes.PipeDirection]::InOut)
\$pipe.Connect(1500)
\$w = New-Object System.IO.StreamWriter(\$pipe)
\$w.AutoFlush = \$true
\$w.Write("get=1`n`n")
\$r = New-Object System.IO.StreamReader(\$pipe)
while (\$true) {
  \$line = \$r.ReadLine()
  if (\$line -eq \$null) { break }
  Write-Output \$line
  if (\$line.StartsWith('errno=')) { break }
}
''';
        final r = await Process.run(
          'powershell',
          ['-NoProfile', '-NonInteractive', '-Command', script],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        ).timeout(const Duration(seconds: 6));
        if (r.exitCode != 0) return;
        final figures = parseAwgUapiDump(r.stdout as String? ?? '');
        if (figures == null) return;
        _awgRxBytes = figures.rxBytes;
        _awgTxBytes = figures.txBytes;
        _awgHandshakeAgeSec = figures.handshakeAgeSec;
      } catch (_) {
        // The pipe is best-effort evidence; the session stands.
      } finally {
        _awgUapiInFlight = false;
      }
    }());
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
    final sink = File('${dir.path}/xray.log').openWrite(mode: FileMode.append);
    np.stdout.listen(sink.add, onError: (_) {});
    np.stderr.listen(sink.add, onError: (_) {});
    unawaited(
      np.exitCode.then((_) async {
        final unexpected = identical(_process, np);
        if (unexpected) _process = null;
        await sink.flush();
        await sink.close();
        if (unexpected) _onCoreDied('the xray core');
      }),
    );
    try {
      await _waitForSocks(np, _localPort);
    } catch (_) {
      return false;
    }
    _rotationGen++;
    return true;
  }

  /// An unexpected core death (the exit handlers above
  /// call this only when the exit was not our own stop /
  /// rotation — those detach _process first). With the
  /// kill switch on and the TUN bridge up, the bridge
  /// STAYS up on the dead SOCKS port: the system keeps
  /// capturing into a blackhole, nothing leaks direct,
  /// and state() publishes the hold until stop() or a new
  /// setOn. Without it, the session tears down fully —
  /// Android's two shapes. A session that already
  /// recovered (a new core owns _process) is left alone.
  void _onCoreDied(String what) {
    if (_process != null) return;
    if (_killSwitch && _bridge != null) {
      _killSwitchHeld = true;
      _lastError =
          '$what stopped unexpectedly — the kill switch is '
          'holding your traffic: nothing leaves this PC until '
          'you disconnect or reconnect.';
      unawaited(_noteToLog('[ember] $_lastError'));
      return;
    }
    _lastError = '$what stopped unexpectedly';
    unawaited(_noteToLog('[ember] $_lastError'));
    unawaited(stop());
  }

  @override
  Future<void> stop() async {
    _killSwitchHeld = false;
    if (_awgTunnelName.isNotEmpty) await _stopAwgSession();
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
    if (_process == null && _awgTunnelName.isNotEmpty) {
      final service = await _awgServiceState();
      if (service == 'RUNNING' && _awgSinceMs != 0) {
        _awgSeenRunning = true;
        _refreshAwgUapi();
        return XrayState(
          running: true,
          name: _awgName,
          sinceMs: _awgSinceMs,
          upBytes: _awgTxBytes,
          downBytes: _awgRxBytes,
          awg: true,
          awgHandshakeAgeSec: _awgHandshakeAgeSec,
          awgRxBytes: _awgRxBytes,
          awgTxBytes: _awgTxBytes,
          awgProblemSeq: _awgProblemSeq,
          awgTunnelPresent: true,
          rotationGen: _rotationGen,
          lastError: _lastError,
        );
      }
      if (_awgSinceMs != 0 &&
          (service == null || service == 'STOPPED') &&
          _awgSeenRunning) {
        // The service was up and is gone (or stopped) without
        // our stop: the session died. The words say so —
        // with the kill switch on, Ember never reroutes the
        // traffic anywhere; the tunnel service's own WFP
        // full-tunnel rules held it while it lived.
        _lastError = _awgKillSwitch
            ? 'the AmneziaWG tunnel service stopped unexpectedly '
                '(the kill switch was on; Ember did not reroute '
                'any traffic)'
            : 'the AmneziaWG tunnel service stopped unexpectedly';
        _awgSinceMs = 0;
        _awgSeenRunning = false;
      }
      // Registered but not running: present, not a session.
      return XrayState(
        running: false,
        name: '',
        sinceMs: 0,
        upBytes: 0,
        downBytes: 0,
        awgProblemSeq: _awgProblemSeq,
        awgTunnelPresent: service != null,
        rotationGen: _rotationGen,
        lastError: _lastError,
      );
    }
    if (_killSwitchHeld) {
      return XrayState(
        running: false,
        name: _name.isNotEmpty ? _name : _warpName,
        sinceMs: _sinceMs != 0 ? _sinceMs : _warpSinceMs,
        upBytes: _up,
        downBytes: _down,
        killSwitchHeld: true,
        rotationGen: _rotationGen,
        lastError: _lastError,
        localPort: _localPort,
        note: _portNote,
      );
    }
    if (_process == null && _warpSinceMs != 0) {
      // The kill switch on the EmberWarp session: the core
      // (aether.exe, owned by the warp backend) died while
      // this session's TUN bridge is up — hold the bridge
      // on the dead SOCKS instead of releasing capture.
      if (_killSwitch && _bridge != null) {
        final ws = await WarpPlatform.state();
        if (!ws.running) {
          return XrayState(
            running: false,
            name: _warpName,
            sinceMs: _warpSinceMs,
            upBytes: 0,
            downBytes: 0,
            killSwitchHeld: true,
            rotationGen: _rotationGen,
            lastError:
                'the EmberWarp core stopped unexpectedly — the '
                'kill switch is holding your traffic: nothing '
                'leaves this PC until you disconnect or reconnect.',
            localPort: _localPort,
            note: _portNote,
          );
        }
      }
      return XrayState(
        running: true,
        name: _warpName,
        sinceMs: _warpSinceMs,
        upBytes: 0,
        downBytes: 0,
        rotationGen: _rotationGen,
        lastError: _lastError,
        localPort: _localPort,
        note: _portNote,
      );
    }
    if (_process == null) {
      // A recorded AWG refusal must stay visible on the stopped
      // sample: the controller's walk polls state() for the
      // problem sequence after setOnAwg (see setOnAwg).
      if (_awgProblemSeq > 0 && _awgProblem.isNotEmpty) {
        return XrayState(
          running: false,
          name: '',
          sinceMs: 0,
          upBytes: 0,
          downBytes: 0,
          coreProblem: _awgProblem,
          awgProblemSeq: _awgProblemSeq,
          rotationGen: _rotationGen,
          lastError: _lastError,
        );
      }
      return XrayState.stopped;
    }
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
      rotationGen: _rotationGen,
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
      final out = await p.stdout
          .transform(utf8.decoder)
          .join()
          .timeout(
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
    final effective = (_process != null && _apiPort != 0) ? _apiPort : apiPort;
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
  static HttpClient _viaProxy(int httpPort, Duration timeout) => HttpClient()
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
    unawaited(
      p.exitCode.then((_) async {
        await sink.flush();
        await sink.close();
      }),
    );
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
  Future<int> measureDelay(String testConfig, {int timeoutMs = 8000}) async {
    await _ensureCleaned();
    final port = await _takeTestPort();
    final proc = await _startInstance(testConfig, port);
    if (proc == null) return -1;
    try {
      var best = -1;
      for (var i = 0; i < 2; i++) {
        final ms = await _timeRequest(
          port + 1,
          timeout: Duration(milliseconds: timeoutMs),
        );
        if (ms >= 0 && (best < 0 || ms < best)) best = ms;
      }
      return best;
    } finally {
      await _kill(proc);
    }
  }

  @override
  Future<Map<String, dynamic>> measureDelayEx(
    String testConfig, {
    int rounds = 2,
    int budgetMs = 0,
    int timeoutMs = 8000,
  }) async {
    // The Windows tester measures with its own pair of requests
    // per instance; [rounds] repeats the measurement on fresh
    // instances and keeps the best, [timeoutMs] is the
    // per-request timeout. [budgetMs] is accepted for contract
    // parity — one Windows measurement already fits the bulk
    // pass's ~10 s shape, and a hard mid-measurement cut would
    // only discard answers that arrived.
    var best = -1;
    final tries = rounds < 1 ? 1 : rounds;
    for (var i = 0; i < tries; i++) {
      final ms = await measureDelay(testConfig, timeoutMs: timeoutMs);
      if (ms >= 0 && (best < 0 || ms < best)) best = ms;
    }
    if (best >= 0) return {'ms': best, 'error': ''};
    return {
      'ms': -1,
      'error': _lastError.isNotEmpty
          ? _lastError
          : 'the test core did not answer through the tunnel',
    };
  }

  @override
  Future<int> tunnelCheck(
    int socksPort, {
    // LAN-sharing credentials (Android build 2062): the Windows
    // probe rides the session's HTTP inbound, which carries no
    // separate credential slot in dart:io's PROXY form — accepted
    // for contract parity. A session whose HTTP inbound requires
    // auth the probe cannot present reads -1, never a fake pass.
    String socksUser = '',
    String socksPass = '',
  }) async {
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
      final client = _viaProxy(port + 1, const Duration(seconds: 10));
      final sw = Stopwatch()..start();
      Future<int> probe() async {
        final target = _delayTargets.first;
        final t0 = sw.elapsedMilliseconds;
        try {
          final req = await client
              .getUrl(Uri.parse(target))
              .timeout(const Duration(seconds: 10));
          final resp = await req.close().timeout(const Duration(seconds: 10));
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
      final interfaces = await NetworkInterface.list(includeLoopback: false);
      for (final iface in interfaces) {
        if (iface.addresses.isEmpty) continue;
        final name = iface.name.toLowerCase();
        final wifi =
            name.contains('wi-fi') ||
            name.contains('wifi') ||
            name.contains('wlan') ||
            name.contains('wireless');
        return {'type': wifi ? 'wifi' : 'ethernet', 'operator': iface.name};
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
      final result = await Process.run(
        _xrayExe,
        ['run', '-test', '-c', file.path],
        workingDirectory: dir.path,
        environment: _xrayEnv,
      ).timeout(const Duration(seconds: 15));
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
  Future<int> _timeRequest(
    int httpPort, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    for (final url in _delayTargets) {
      final client = _viaProxy(httpPort, timeout);
      try {
        final started = Stopwatch()..start();
        final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
        request.followRedirects = false;
        final response = await request.close().timeout(timeout);
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
          .getUrl(
            Uri.parse('https://speed.cloudflare.com/__down?bytes=50000000'),
          )
          .timeout(const Duration(seconds: 8));
      final started = Stopwatch()..start();
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      var total = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
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
  Future<int> speedTestUp(String testConfig) async {
    // The download test's mirror (Android build 2149): POST
    // generated bytes to the Cloudflare speed endpoint's upload
    // path through a throwaway core for the same window; the
    // figure is the bytes the proxied connection accepted per
    // second.
    await _ensureCleaned();
    final port = await _takeTestPort();
    final proc = await _startInstance(testConfig, port);
    if (proc == null) return -1;
    final client = _viaProxy(port + 1, const Duration(seconds: 8));
    try {
      final request = await client
          .postUrl(Uri.parse('https://speed.cloudflare.com/__up'))
          .timeout(const Duration(seconds: 8));
      request.headers.contentType = ContentType.binary;
      final chunk = List<int>.filled(65536, 0x61);
      final started = Stopwatch()..start();
      var total = 0;
      while (started.elapsed < const Duration(seconds: 8)) {
        request.add(chunk);
        total += chunk.length;
        await request.flush();
      }
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      await response.drain<void>();
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
  Future<Map<String, dynamic>> sandboxTest(
    String testConfig, {
    int timeoutMs = 8000,
  }) async {
    // The sandbox discipline (Android build 2061) on the Windows
    // tester machinery: ONE throwaway core — a delay probe, a
    // hold probe seconds later over the same instance, and the
    // exit identity observed through it. The live tunnel is
    // never touched.
    await _ensureCleaned();
    final port = await _takeTestPort();
    final proc = await _startInstance(testConfig, port);
    if (proc == null) {
      return {
        'ok': 0,
        'error': _lastError.isNotEmpty
            ? _lastError
            : 'the sandbox test core did not start',
      };
    }
    try {
      final timeout = Duration(milliseconds: timeoutMs);
      final ms = await _timeRequest(port + 1, timeout: timeout);
      if (ms < 0) {
        return {
          'ok': 0,
          'error': _lastError.isNotEmpty
              ? _lastError
              : 'the sandbox test did not answer through the tunnel',
        };
      }
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      final heldMs = await _timeRequest(port + 1, timeout: timeout);
      final exit = await _exitInfoVia(port + 1);
      return {
        'ok': 1,
        'ms': ms,
        'held': heldMs >= 0 ? 1 : 0,
        'ip': exit?['ip'] ?? '',
        'countryCode': exit?['countryCode'] ?? '',
        'country': exit?['country'] ?? '',
        'error': '',
      };
    } finally {
      await _kill(proc);
    }
  }

  @override
  Future<Map<String, dynamic>> serviceCheck(
    String testConfig,
    List<String> hosts,
  ) async {
    // The service check (Android build 2091) on the Windows
    // tester machinery: ONE throwaway core, one real HTTPS HEAD
    // per host through it; a host that does not answer maps to
    // status 0 / ms -1 — never an invented verdict.
    await _ensureCleaned();
    final port = await _takeTestPort();
    final proc = await _startInstance(testConfig, port);
    if (proc == null) {
      return {
        'ok': 0,
        'error': _lastError.isNotEmpty
            ? _lastError
            : 'the service check core did not start',
        'results': <String, dynamic>{},
      };
    }
    try {
      final results = <String, dynamic>{};
      final client = _viaProxy(port + 1, const Duration(seconds: 8));
      try {
        for (final host in hosts) {
          final sw = Stopwatch()..start();
          try {
            final req = await client
                .headUrl(Uri.parse('https://$host/'))
                .timeout(const Duration(seconds: 8));
            final resp = await req.close().timeout(const Duration(seconds: 8));
            await resp.drain<void>();
            sw.stop();
            results[host] = {
              'ms': sw.elapsedMilliseconds,
              'status': resp.statusCode,
            };
          } catch (_) {
            results[host] = {'ms': -1, 'status': 0};
          }
        }
      } finally {
        client.close(force: true);
      }
      return {'ok': 1, 'error': '', 'results': results};
    } finally {
      await _kill(proc);
    }
  }

  /// The exit identity observed through the HTTP proxy on
  /// [httpPort] — [exitInfo]'s body, parameterized so the
  /// sandbox test can ask through its throwaway instance.
  Future<Map<String, String>?> _exitInfoVia(int httpPort) async {
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

  @override
  Future<Map<String, String>?> exitInfo(
    int socksPort, {
    // LAN-sharing credentials (Android build 2062): accepted for
    // contract parity — the Windows probe rides the session's
    // HTTP inbound (see tunnelCheck's note).
    String socksUser = '',
    String socksPass = '',
  }) async {
    // The requests ride the running config's HTTP inbound (recorded
    // at setOn); [socksPort] is the Android-shaped parameter, kept
    // for the fallback pairing when no port was recorded.
    final httpPort = _httpPort != 0 ? _httpPort : socksPort + 1;
    return _exitInfoVia(httpPort);
  }

  // ---- DNS ping (Android build 2149, Windows port) ----------------
  //
  // One real DNS query per server, timed individually, in wire
  // format. Plain servers are asked over UDP directly, or over
  // TCP through a SOCKS5 tunnel (the config/port modes);
  // https:// servers are DoH POSTs (direct, or through the
  // tunnel's HTTP proxy); tls:// (or :853) servers are DoT.
  // quic:// and anything unparsable map to -2 (not a probed
  // kind); a server that does not answer maps to -1. Nothing is
  // invented: a probe that cannot run says -1.

  static int _dnsIdCounter = 0x2a41;

  static int _nextDnsId() {
    _dnsIdCounter = (_dnsIdCounter + 1) & 0xffff;
    return _dnsIdCounter;
  }

  /// A minimal A/IN query for example.com with id [id].
  static Uint8List _dnsQueryBytes(int id) {
    const labels = ['example', 'com'];
    var len = 12 + 1 + 4;
    for (final l in labels) {
      len += 1 + l.length;
    }
    final b = Uint8List(len);
    final d = ByteData.view(b.buffer);
    d.setUint16(0, id);
    d.setUint16(2, 0x0100); // RD
    d.setUint16(4, 1); // QDCOUNT
    var o = 12;
    for (final l in labels) {
      b[o++] = l.length;
      for (final c in l.codeUnits) {
        b[o++] = c;
      }
    }
    b[o++] = 0;
    d.setUint16(o, 1); // QTYPE A
    d.setUint16(o + 2, 1); // QCLASS IN
    return b;
  }

  static bool _dnsResponseOk(List<int> r, int id) =>
      r.length >= 12 && ((r[0] << 8) | r[1]) == id && (r[2] & 0x80) != 0;

  /// Splits a preset server string into its probe kind and
  /// target: 'udp' (plain host[:port]), 'dot' (tls:// or :853),
  /// 'doh' (https:// URL), 'unsupported' (quic://, anything else).
  static ({String kind, String host, int port, Uri? url}) _parseDnsServer(
    String s,
  ) {
    final v = s.trim();
    if (v.startsWith('https://')) {
      return (kind: 'doh', host: '', port: 0, url: Uri.tryParse(v));
    }
    if (v.startsWith('quic://')) {
      return (kind: 'unsupported', host: '', port: 0, url: null);
    }
    var rest = v;
    var dot = false;
    if (rest.startsWith('tls://')) {
      dot = true;
      rest = rest.substring(6);
    }
    var host = rest;
    var port = dot ? 853 : 53;
    final colon = rest.lastIndexOf(':');
    if (colon > 0) {
      final p = int.tryParse(rest.substring(colon + 1));
      if (p != null) {
        host = rest.substring(0, colon);
        port = p;
      }
    }
    if (host.isEmpty) {
      return (kind: 'unsupported', host: '', port: 0, url: null);
    }
    if (port == 853) dot = true;
    return (kind: dot ? 'dot' : 'udp', host: host, port: port, url: null);
  }

  Future<int> _dnsUdpProbe(String host, int port, Duration timeout) async {
    final id = _nextDnsId();
    RawDatagramSocket? sock;
    try {
      final target = (await InternetAddress.lookup(host).timeout(timeout))
          .firstWhere(
            (a) => a.type == InternetAddressType.IPv4,
            orElse: () => throw StateError('no ipv4'),
          );
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final sw = Stopwatch()..start();
      sock.send(_dnsQueryBytes(id), target, port);
      await for (final ev in sock.timeout(timeout)) {
        if (ev == RawSocketEvent.read) {
          final dg = sock.receive();
          if (dg != null && _dnsResponseOk(dg.data, id)) {
            sw.stop();
            return sw.elapsedMilliseconds;
          }
        }
      }
      return -1;
    } catch (_) {
      return -1;
    } finally {
      sock?.close();
    }
  }

  /// A DNS-over-TCP exchange over an already-connected socket
  /// read through [reader] (2-byte length framing).
  Future<int> _dnsTcpProbe(
    _SocketReader reader,
    Socket sink,
    Duration timeout,
  ) async {
    final id = _nextDnsId();
    final q = _dnsQueryBytes(id);
    final framed = Uint8List(q.length + 2);
    ByteData.view(framed.buffer).setUint16(0, q.length);
    framed.setRange(2, framed.length, q);
    final sw = Stopwatch()..start();
    try {
      sink.add(framed);
      await sink.flush().timeout(timeout);
      final head = await reader.read(2, timeout);
      if (head == null) return -1;
      final n = (head[0] << 8) | head[1];
      final body = await reader.read(n, timeout);
      if (body == null) return -1;
      sw.stop();
      return _dnsResponseOk(body, id) ? sw.elapsedMilliseconds : -1;
    } catch (_) {
      return -1;
    }
  }

  Future<int> _dnsDohProbe(HttpClient client, Uri url, Duration timeout) async {
    final id = _nextDnsId();
    final sw = Stopwatch()..start();
    try {
      final req = await client.postUrl(url).timeout(timeout);
      req.headers.set('content-type', 'application/dns-message');
      req.headers.set('accept', 'application/dns-message');
      req.add(_dnsQueryBytes(id));
      final resp = await req.close().timeout(timeout);
      final body = await resp
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(timeout);
      sw.stop();
      return resp.statusCode == 200 && _dnsResponseOk(body, id)
          ? sw.elapsedMilliseconds
          : -1;
    } catch (_) {
      return -1;
    }
  }

  /// Opens a SOCKS5 CONNECT tunnel from 127.0.0.1:[socksPort] to
  /// [host]:[port]; returns the socket and its reader, or null.
  Future<({Socket socket, _SocketReader reader})?> _socksConnect(
    int socksPort,
    String host,
    int port, {
    String user = '',
    String pass = '',
    required Duration timeout,
  }) async {
    Socket? s;
    try {
      s = await Socket.connect('127.0.0.1', socksPort, timeout: timeout);
      final reader = _SocketReader(s);
      final useAuth = user.isNotEmpty;
      s.add(useAuth ? [5, 2, 0, 2] : [5, 1, 0]);
      await s.flush().timeout(timeout);
      final g = await reader.read(2, timeout);
      if (g == null || g[0] != 5) {
        await s.close();
        return null;
      }
      if (g[1] == 2) {
        final u = user.codeUnits, p = pass.codeUnits;
        s.add([1, u.length, ...u, p.length, ...p]);
        await s.flush().timeout(timeout);
        final a = await reader.read(2, timeout);
        if (a == null || a[1] != 0) {
          await s.close();
          return null;
        }
      } else if (g[1] != 0) {
        await s.close();
        return null;
      }
      final ip = InternetAddress.tryParse(host);
      final List<int> addr;
      if (ip != null && ip.type == InternetAddressType.IPv4) {
        addr = [1, ...ip.rawAddress];
      } else {
        final hb = host.codeUnits;
        addr = [3, hb.length, ...hb];
      }
      s.add([5, 1, 0, ...addr, (port >> 8) & 0xff, port & 0xff]);
      await s.flush().timeout(timeout);
      final h = await reader.read(4, timeout);
      if (h == null || h[0] != 5 || h[1] != 0) {
        await s.close();
        return null;
      }
      final atyp = h[3];
      if (atyp == 1) {
        await reader.read(6, timeout);
      } else if (atyp == 4) {
        await reader.read(18, timeout);
      } else if (atyp == 3) {
        final l = await reader.read(1, timeout);
        if (l == null) {
          await s.close();
          return null;
        }
        await reader.read(l[0] + 2, timeout);
      } else {
        await s.close();
        return null;
      }
      return (socket: s, reader: reader);
    } catch (_) {
      try {
        await s?.close();
      } catch (_) {}
      return null;
    }
  }

  /// One server probed directly (no tunnel).
  Future<int> _dnsProbeDirect(
    ({String kind, String host, int port, Uri? url}) t,
    Duration timeout,
  ) async {
    switch (t.kind) {
      case 'doh':
        if (t.url == null) return -2;
        final client = HttpClient()..connectionTimeout = timeout;
        try {
          return await _dnsDohProbe(client, t.url!, timeout);
        } finally {
          client.close(force: true);
        }
      case 'dot':
        try {
          final s = await SecureSocket.connect(
            t.host,
            t.port,
            timeout: timeout,
          );
          final reader = _SocketReader(s);
          try {
            return await _dnsTcpProbe(reader, s, timeout);
          } finally {
            await reader.cancel();
            await s.close();
          }
        } catch (_) {
          return -1;
        }
      case 'udp':
        final udp = await _dnsUdpProbe(t.host, t.port, timeout);
        if (udp >= 0) return udp;
        // TCP fallback, the resolver's own second chance.
        try {
          final s = await Socket.connect(t.host, t.port, timeout: timeout);
          final reader = _SocketReader(s);
          try {
            return await _dnsTcpProbe(reader, s, timeout);
          } finally {
            await reader.cancel();
            await s.close();
          }
        } catch (_) {
          return -1;
        }
      default:
        return -2;
    }
  }

  /// One server probed through the tunnel whose SOCKS is on
  /// [socksPort] and whose HTTP proxy is on [httpPort] (0 = no
  /// HTTP proxy known; DoH then reads -1).
  Future<int> _dnsProbeVia(
    ({String kind, String host, int port, Uri? url}) t,
    int socksPort,
    int httpPort, {
    String user = '',
    String pass = '',
    required Duration timeout,
  }) async {
    switch (t.kind) {
      case 'doh':
        if (t.url == null) return -2;
        if (httpPort == 0) return -1;
        final client = _viaProxy(httpPort, timeout);
        try {
          return await _dnsDohProbe(client, t.url!, timeout);
        } finally {
          client.close(force: true);
        }
      case 'dot':
      case 'udp':
        final conn = await _socksConnect(
          socksPort,
          t.host,
          t.port,
          user: user,
          pass: pass,
          timeout: timeout,
        );
        if (conn == null) return -1;
        try {
          if (t.kind == 'dot') {
            await conn.reader.cancel();
            final secure = await SecureSocket.secure(
              conn.socket,
              host: t.host,
            ).timeout(timeout);
            final reader = _SocketReader(secure);
            try {
              return await _dnsTcpProbe(reader, secure, timeout);
            } finally {
              await reader.cancel();
              await secure.close();
            }
          }
          return await _dnsTcpProbe(conn.reader, conn.socket, timeout);
        } catch (_) {
          return -1;
        } finally {
          try {
            await conn.socket.close();
          } catch (_) {}
        }
      default:
        return -2;
    }
  }

  @override
  Future<Map<String, int>> dnsPingDirect(
    List<String> servers, {
    int timeoutMs = 5000,
  }) async {
    final timeout = Duration(milliseconds: timeoutMs);
    final out = <String, int>{};
    for (final s in servers) {
      out[s] = await _dnsProbeDirect(_parseDnsServer(s), timeout);
    }
    return out;
  }

  @override
  Future<Map<String, int>> dnsPingViaPort(
    int socksPort,
    List<String> servers, {
    String socksUser = '',
    String socksPass = '',
    int timeoutMs = 5000,
  }) async {
    final timeout = Duration(milliseconds: timeoutMs);
    final httpPort = _process != null ? _httpPort : 0;
    final out = <String, int>{};
    for (final s in servers) {
      out[s] = await _dnsProbeVia(
        _parseDnsServer(s),
        socksPort,
        httpPort,
        user: socksUser,
        pass: socksPass,
        timeout: timeout,
      );
    }
    return out;
  }

  @override
  Future<Map<String, int>> dnsPing(
    String testConfig,
    List<String> servers, {
    int timeoutMs = 5000,
  }) async {
    // Through a throwaway instance of the config — the sandbox
    // discipline; the live tunnel is never touched.
    await _ensureCleaned();
    final port = await _takeTestPort();
    final proc = await _startInstance(testConfig, port);
    if (proc == null) return {for (final s in servers) s: -1};
    try {
      final timeout = Duration(milliseconds: timeoutMs);
      final out = <String, int>{};
      for (final s in servers) {
        out[s] = await _dnsProbeVia(
          _parseDnsServer(s),
          port,
          port + 1,
          timeout: timeout,
        );
      }
      return out;
    } finally {
      await _kill(proc);
    }
  }

  /// A whole small GET through the tunnel, as text; null on failure.
  Future<String?> _httpGetText(int httpPort, String url) async {
    const timeout = Duration(seconds: 6);
    final client = _viaProxy(httpPort, timeout);
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      return await response.transform(utf8.decoder).join().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }
}

/// A buffered reader over a [Socket]'s single-subscription
/// stream: the SOCKS5 handshake and the DNS-over-TCP exchange
/// share one socket, and each needs exact-length reads the raw
/// stream does not offer. Bytes are consumed in order; a read
/// that cannot complete before its timeout (or EOF) returns
/// null.
class _SocketReader {
  _SocketReader(Socket socket) {
    _sub = socket.listen(
      (data) {
        _buf.addAll(data);
        _pump();
      },
      onError: (_) {
        _eof = true;
        _pump();
      },
      onDone: () {
        _eof = true;
        _pump();
      },
    );
  }

  late final StreamSubscription<List<int>> _sub;
  final List<int> _buf = [];
  bool _eof = false;
  Completer<void>? _waiter;

  void _pump() {
    final w = _waiter;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<Uint8List?> read(int n, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_buf.length < n) {
      if (_eof) return null;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return null;
      _waiter = Completer<void>();
      try {
        await _waiter!.future.timeout(remaining);
      } on TimeoutException {
        return null;
      }
    }
    final out = Uint8List.fromList(_buf.sublist(0, n));
    _buf.removeRange(0, n);
    return out;
  }

  Future<void> cancel() => _sub.cancel();
}

// ---------------------------------------------------------------------
// AmneziaWG hand-off helpers (pure, so the contract is test-pinned).
// ---------------------------------------------------------------------

/// The tunnel name for a profile: the service is
/// `AmneziaWGTunnel$<name>` and the config file `<name>.conf`,
/// so the name is kept to the characters both accept —
/// letters, digits and `_-.=+` — with anything else folded to
/// `_`, capped at 40 characters. An empty result reads
/// 'ember'.
String awgTunnelNameFor(String profileName) {
  final buf = StringBuffer();
  for (final ch in profileName.trim().split('')) {
    final ok = RegExp(r'^[A-Za-z0-9_\-.=+]$').hasMatch(ch);
    buf.write(ok ? ch : '_');
  }
  var name = buf.toString();
  if (name.length > 40) name = name.substring(0, 40);
  name = name.replaceAll(RegExp(r'^[._]+|[._]+$'), '');
  return name.isEmpty ? 'ember' : name;
}

/// Android's AWG hand-off transformations, applied to the
/// profile's canonical .conf text for the tunnel service
/// (setOnAwg): the session [dns] REPLACES the config's DNS
/// line (build 2102, diagnosis C1); the Settings [mtu] is
/// the fallback when the profile carries no MTU of its own
/// (build 2116, B3-1); a peer carrying no AllowedIPs gets
/// the full-tunnel default gated on the families the profile
/// actually carries (build 2102, C2 / build 2103, D1).
/// Everything else — the Amnezia parameters included — rides
/// verbatim.
String buildAwgServiceConfig(
  String settings, {
  required String dns,
  required bool ipv4,
  required bool ipv6,
  required int mtu,
}) {
  final lines = settings.replaceAll('\r\n', '\n').split('\n');
  final out = <String>[];
  var section = '';
  var ifaceHasDns = false;
  var ifaceHasMtu = false;
  var peerHasAllowed = false;

  void closePeer() {
    if (section == 'peer' && !peerHasAllowed) {
      final defaults = [
        if (ipv4) '0.0.0.0/0',
        if (ipv6) '::/0',
      ];
      if (defaults.isNotEmpty) {
        out.add('AllowedIPs = ${defaults.join(', ')}');
      }
    }
    peerHasAllowed = false;
  }

  void closeInterface() {
    if (section != 'interface') return;
    if (dns.isNotEmpty && !ifaceHasDns) out.add('DNS = $dns');
    if (mtu > 0 && !ifaceHasMtu) out.add('MTU = $mtu');
    ifaceHasDns = false;
    ifaceHasMtu = false;
  }

  for (final raw in lines) {
    final line = raw.trimRight();
    final trimmed = line.trim();
    final header = RegExp(
      r'^\[(interface|peer)\]$',
      caseSensitive: false,
    ).firstMatch(trimmed.toLowerCase());
    if (header != null) {
      closePeer();
      closeInterface();
      section = header.group(1)!;
      out.add(line);
      continue;
    }
    if (section == 'interface') {
      if (RegExp(r'^DNS\s*=', caseSensitive: false).hasMatch(trimmed)) {
        ifaceHasDns = true;
        out.add(dns.isNotEmpty ? 'DNS = $dns' : line);
        continue;
      }
      if (RegExp(r'^MTU\s*=', caseSensitive: false).hasMatch(trimmed)) {
        ifaceHasMtu = true;
        out.add(line);
        continue;
      }
    }
    if (section == 'peer' &&
        RegExp(r'^AllowedIPs\s*=', caseSensitive: false).hasMatch(trimmed)) {
      peerHasAllowed = true;
    }
    out.add(line);
  }
  closePeer();
  closeInterface();
  return out.join('\n');
}

/// The figures one UAPI `get` dump carries (the tunnel
/// service's pipe): the newest handshake across peers and
/// the summed transfer counters.
class AwgUapiFigures {
  final int handshakeAgeSec;
  final int rxBytes;
  final int txBytes;
  const AwgUapiFigures(this.handshakeAgeSec, this.rxBytes, this.txBytes);
}

/// Parses a UAPI dump: per-peer `latest_handshake_time_sec`
/// (the v3 key; `last_handshake_time_sec` on the v1 API),
/// `rx_bytes` and `tx_bytes`. Null when the dump carries no
/// peer at all. A handshake timestamp of 0 reads as "never"
/// (age -1).
AwgUapiFigures? parseAwgUapiDump(String dump, {int? nowSec}) {
  var sawPeer = false;
  var newestHandshake = 0;
  var rx = 0;
  var tx = 0;
  for (final line in dump.split('\n')) {
    final t = line.trim();
    final eq = t.indexOf('=');
    if (eq <= 0) continue;
    final key = t.substring(0, eq);
    final value = int.tryParse(t.substring(eq + 1)) ?? 0;
    switch (key) {
      case 'public_key':
        sawPeer = true;
      case 'latest_handshake_time_sec':
      case 'last_handshake_time_sec':
        if (value > newestHandshake) newestHandshake = value;
      case 'rx_bytes':
        rx += value;
      case 'tx_bytes':
        tx += value;
    }
  }
  if (!sawPeer) return null;
  final now = nowSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return AwgUapiFigures(
    newestHandshake > 0 ? now - newestHandshake : -1,
    rx,
    tx,
  );
}
