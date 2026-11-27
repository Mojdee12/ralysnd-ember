/// The Psiphon engine on Windows: the Psiphon tunnel-core
/// ConsoleClient — v2.0.42, the exact release the Android AAR
/// wraps — shipped as the psiphon\psiphon-core.exe sidecar and
/// driven as a child process. (Psiphon is GPLv3, like the
/// Mozilla core this app already ships; the sidecar is a
/// separate unmodified program.)
///
/// Android build 2157 hosts the core in PsiphonVpnService: the
/// MLM strategy ladder (A fronted / E clean-IP / D direct /
/// C in-proxy / P personal / X upstream), the per-rung config
/// overrides, the server-quality gate, winner attribution and
/// the kill-switch hold. This backend is that host, ported to
/// Dart over the child process — same ladder order and budgets
/// (PsiphonConstants), same config keys (buildPsiphonConfig's
/// twin), same published state contract. The core announces
/// everything as JSON notices **on stderr** — the
/// ConsoleClient's notice writer defaults to os.Stderr — and
/// they map onto the session exactly as the MobileLibrary
/// callbacks do on Android:
///
///   Tunnels {count}            count 0 = connecting, >= 1 = connected
///   ListeningSocksProxyPort    the core is up (running)
///   AvailableEgressRegions     state.regions
///   ClientRegion               state.region
///   ClientAddress              state.clientAddress
///   BytesTransferred {sent, received}   deltas, accumulated here
///
/// VPN mode: the core only serves its local proxies, so once a
/// tunnel passes the quality gate, the bundled TUN bridge
/// (core/tun_bridge.dart) points the system TUN at the SOCKS
/// port, with psiphon-core.exe itself kept outside the TUN. If
/// the bridge cannot start, the connect fails — the engine
/// never silently runs proxy-only when VPN mode was asked.
///
/// Inputs Android's MLM host carries but does not consume are
/// carried here the same way and logged as parked, never
/// faked: the protocols multi-select (the ladder owns protocol
/// selection), disableTimeouts and cdnFront (fork-core levers),
/// the TUN dns (the core's anti-hijack resolver trio is in the
/// config instead), the mtu and the ipv6 flag (the Windows TUN
/// bridge sizes and captures as it does for every engine).
///
/// Stopping kills the child process (the Windows way; the
/// core's datastore is crash-tolerant). A hard app kill can
/// orphan the core holding its ports — so the first start of a
/// run reaps leftover copies of THIS app's sidecar by exact
/// path (core/orphan_cleanup.dart), and if the local proxy
/// ports are still taken, the session moves to the first free
/// port pair, the config regenerated on it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/core_api.dart';
import '../core/orphan_cleanup.dart';
import '../core/ports.dart';
import '../core/tun_bridge.dart';
import 'psiphon_bootstrap.dart';
import 'psiphon_platform.dart';

// ---------------------------------------------------------------------
// The server-quality gate (PsiphonQuality.kt, ported).
// ---------------------------------------------------------------------

/// The quality gate's verdict for one drawn server.
class PsiphonQualityResult {
  final double mbit;
  final int okStreams;
  final int bytes;
  final int ms;
  const PsiphonQualityResult(this.mbit, this.okStreams, this.bytes, this.ms);
}

abstract final class PsiphonQuality {
  static const streams = 6;
  static const bytes = 768 * 1024;
  static const minGoodMbit = 0.9;
  static const maxServerAttempts = 3;
  static const _host = 'speed.cloudflare.com';
  static const _port = 80;

  /// Downloads [bytes] over [streams] parallel SOCKS5 streams
  /// through the tunnel at [socksPort] and reports the aggregate
  /// rate — the Kotlin measure, field for field.
  static Future<PsiphonQualityResult> measure(
    int socksPort, {
    int streamCount = streams,
    int totalBytes = bytes,
    int timeoutMs = 12000,
  }) async {
    final each = totalBytes ~/ streamCount < 65536
        ? 65536
        : totalBytes ~/ streamCount;
    final sw = Stopwatch()..start();
    final deadline = sw.elapsedMilliseconds + timeoutMs;
    final got = await Future.wait([
      for (var i = 0; i < streamCount; i++)
        _one(socksPort, each, () => deadline - sw.elapsedMilliseconds),
    ]);
    final ms = sw.elapsedMilliseconds;
    final total = got.fold<int>(0, (a, b) => a + b);
    final secs = ms / 1000.0 < 0.001 ? 0.001 : ms / 1000.0;
    final mbit = ((total * 8 / 1e6) / secs * 100).round() / 100.0;
    return PsiphonQualityResult(
      mbit,
      got.where((g) => g > 0).length,
      total,
      ms,
    );
  }

  static Future<int> _one(
    int socksPort,
    int want,
    int Function() leftMs,
  ) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        '127.0.0.1',
        socksPort,
        timeout: const Duration(seconds: 3),
      );
      final reader = _SocketReader(socket);
      socket.add([5, 1, 0]);
      await socket.flush();
      if (await reader.byte() != 5 || await reader.byte() != 0) return 0;
      final name = _host.codeUnits;
      socket.add([
        5, 1, 0, 3, name.length, ...name, (_port >> 8) & 0xff, _port & 0xff,
      ]);
      await socket.flush();
      if (await reader.byte() != 5 || await reader.byte() != 0) return 0;
      await reader.byte(); // reserved
      final atyp = await reader.byte();
      final skip = switch (atyp) {
        1 => 4,
        4 => 16,
        3 => await reader.byte(),
        _ => -1,
      };
      if (skip < 0) return 0;
      for (var i = 0; i < skip + 2; i++) {
        if (await reader.byte() < 0) return 0;
      }
      socket.add(
        'GET /__down?bytes=$want HTTP/1.1\r\n'
                'Host: $_host\r\n'
                'User-Agent: ralysnd-ember-tunnel-check\r\n'
                'Connection: close\r\n\r\n'
            .codeUnits,
      );
      await socket.flush();
      if (!await _skipHead(reader)) return 0;
      var got = 0;
      while (got < want) {
        if (leftMs() <= 0) break;
        final chunk = await reader.take(want - got);
        if (chunk.isEmpty) break;
        got += chunk.length;
      }
      return got;
    } catch (_) {
      return 0;
    } finally {
      try {
        socket?.destroy();
      } catch (_) {}
    }
  }

  static Future<bool> _skipHead(_SocketReader reader) async {
    var state = 0;
    var seen = 0;
    while (seen < 16 * 1024) {
      final b = await reader.byte();
      if (b < 0) return false;
      seen++;
      if (b == 13 && (state == 0 || state == 2)) {
        state++;
      } else if (b == 10 && state == 1) {
        state = 2;
      } else if (b == 10 && state == 3) {
        return true;
      } else {
        state = 0;
      }
    }
    return false;
  }
}

/// A minimal buffered reader over a socket's byte stream (the
/// quality gate speaks SOCKS5 by hand, as PsiphonQuality.kt
/// does).
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

  Future<void> _awaitData() async {
    while (_buf.isEmpty && !_eof) {
      _waiter = Completer<void>();
      await _waiter!.future;
    }
  }

  /// One byte, or -1 at EOF.
  Future<int> byte() async {
    await _awaitData();
    if (_buf.isEmpty) return -1;
    return _buf.removeAt(0);
  }

  /// Up to [n] bytes (fewer at EOF; empty only at EOF).
  Future<List<int>> take(int n) async {
    await _awaitData();
    if (_buf.isEmpty) return const [];
    final count = _buf.length < n ? _buf.length : n;
    final out = _buf.sublist(0, count);
    _buf.removeRange(0, count);
    return out;
  }

  Future<void> close() async {
    try {
      await _sub.cancel();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------
// The ladder (PsiphonVpnService's PsiphonStrategy + ladder builder).
// ---------------------------------------------------------------------

/// One rung of the ladder: a name, the protocols it prefers
/// (winner attribution), its own data root when it has one,
/// and the upstream it rides when it is one.
class PsiphonRung {
  final String name;
  final List<String> preferredProtocols;
  final String? dataRootName;
  final String? upstream;

  const PsiphonRung(
    this.name, {
    this.preferredProtocols = const [],
    this.dataRootName,
    this.upstream,
  });

  String get label => PsiphonConstants.methodLabel(name);
  int get timeoutSeconds => PsiphonConstants.methodSeconds(name);
}

/// Splits the upstream field into individual proxy URLs
/// (PsiphonVpnService.parseUpstreams' input shape: entries
/// separated by whitespace, commas or semicolons).
List<String> parsePsiphonUpstreams(String raw) => raw
    .split(RegExp(r'[\s,;]+'))
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

// ---------------------------------------------------------------------
// The Windows host (PsiphonVpnService's host role, in Dart).
// ---------------------------------------------------------------------

class WindowsPsiphonBackend implements PsiphonBackend {
  Process? _proc;
  IOSink? _logSink;
  TunBridge? _bridge;
  bool _bridgeDown = false;

  // Session inputs (the service's in* fields).
  bool _inVpnMode = true;
  String _inRegion = '';
  String _inUpstream = '';
  String _inCompartment = '';
  List<String> _inCleanAkamai = const [];
  List<String> _inCleanFastly = const [];
  bool _inKillSwitch = false;
  bool _inShiroBootstrap = false;
  bool _inStrongMode = false;

  // Published state (the service's state() fields).
  bool _running = false;
  bool _connected = false;
  bool _wedged = false;
  bool _startReturned = true;
  bool _killSwitchHeld = false;
  int _sinceMs = 0;
  int _up = 0;
  int _down = 0;
  String _region = '';
  String _clientAddress = '';
  List<String> _regions = [];
  String _activeMethod = '';

  // The ladder session.
  List<PsiphonRung> _sessionLadder = [];
  int _ladderIndex = 0;
  int _ladderAttempts = 0;
  bool _regionPhase = false;
  bool _ladderActive = false;
  Timer? _ladderTimer;
  bool _sessionHasUpstream = false;
  bool _routingActivated = false;
  bool _stopping = false;

  /// Bumped by every setOn/stop so an async continuation from
  /// a dead session (a quality redraw, a restart pause) can
  /// tell it no longer owns the machine.
  int _sessionGen = 0;

  /// Set around a deliberate core kill (a ladder restart, the
  /// quality redraw, a teardown): the exit handler must not
  /// read those as the core dying on its own.
  bool _expectedExit = false;

  // The quality gate.
  bool _qualityDone = false;
  int _qualityAttempts = 1;
  int _qualityGen = 0;

  // Attribution (2 s after connect, one-shot per connect).
  String _activeTunnelProtocol = '';
  bool _inproxyInUse = false;
  bool _attributionPending = false;

  String _lastError = '';
  int _socksPort = PsiphonPlatform.socksPort;
  int _httpPort = PsiphonPlatform.httpPort;
  bool _bindFailed = false;
  bool _cleanedUp = false;
  DateTime? _spawnedAt;
  Directory? _dir;

  /// Said when the local proxy ports cannot be had: the usual
  /// cause is another proxy client holding them.
  static const portsBusyMessage =
      "Psiphon's local ports 11808/11809 are already in use by "
      'another program (for example v2rayN or another proxy app). '
      'Close it and try again.';

  /// Shown when the sidecar dies at once or will not start at
  /// all: the usual cause on a real PC is a security product.
  static const firewallGuidance =
      'psiphon-core.exe exited immediately or could not start. '
      'Windows Firewall or antivirus may be blocking it — allow '
      'psiphon-core.exe in Windows Security / your antivirus, '
      'then try again.';

  static String get _coreExe {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    return '$dir${sep}psiphon${sep}psiphon-core.exe';
  }

  @override
  Future<Directory> workDir() async =>
      Directory('${CoreLocator.dataDir(const [])}/psiphon');

  // ---- session start -------------------------------------------------

  @override
  Future<void> setOn({
    required bool vpnMode,
    required String region,
    required String upstream,
    required List<String> protocols,
    required String dns,
    required int mtu,
    bool ipv6 = true,
    List<String> rungs = const [],
    String compartment = '',
    List<String> cleanAkamai = const [],
    List<String> cleanFastly = const [],
    bool disableTimeouts = false,
    bool cdnFront = false,
    bool killSwitch = false,
    bool shiroBootstrap = false,
    bool strongMode = false,
  }) async {
    // A fresh start over a kill-switch hold: the held bridge
    // is the dead session's blackhole; stop it and clear the
    // hold before this start builds its own (the service's
    // onStartCommand does the same with its held TUN).
    if (_killSwitchHeld) {
      _killSwitchHeld = false;
      final held = _bridge;
      _bridge = null;
      _bridgeDown = false;
      if (held != null) await held.stop();
    }
    if (_running || _proc != null) await stop();
    if (!File(_coreExe).existsSync()) {
      throw StateError('psiphon-core-missing: $_coreExe');
    }
    _sessionGen++;
    _stopping = false;
    _inVpnMode = vpnMode;
    _inRegion = region;
    _inUpstream = upstream;
    _inCompartment = compartment;
    _inCleanAkamai = cleanAkamai;
    _inCleanFastly = cleanFastly;
    _inKillSwitch = killSwitch;
    _inShiroBootstrap = shiroBootstrap;
    _inStrongMode = strongMode;

    final dir = await workDir();
    _dir = dir;
    await dir.create(recursive: true);
    await _openLog(dir);
    _resetRun();
    // Reap a previous run's orphaned sidecar first: it may be
    // the very thing holding the local proxy ports.
    await _ensureCleaned();
    // Port selection: the platform pair when it can bind, else
    // the first free pair above it (same +1 spacing).
    if (!await isFree(_socksPort) || !await isFree(_httpPort)) {
      var found = false;
      for (var k = 1; k <= 60; k++) {
        final s = PsiphonPlatform.socksPort + k;
        if (await isFree(s) && await isFree(s + 1)) {
          _socksPort = s;
          _httpPort = s + 1;
          found = true;
          break;
        }
      }
      if (!found) {
        _lastError = portsBusyMessage;
        _logLine(_lastError);
        await _closeLog();
        throw StateError(_lastError);
      }
      _logLine(
        'psiphon ports ${PsiphonPlatform.socksPort}/'
        '${PsiphonPlatform.httpPort} are busy, using $_socksPort/'
        '$_httpPort for this session',
      );
    }
    // The entries asset and the Shiro fronting specs are read
    // before the ladder is built (the clean-IP rung and the
    // fronted-region set both feed on them).
    await _ensureEntries();
    await _loadShiroCidrs();

    _sessionLadder = _buildSessionLadder(rungs);
    _sessionHasUpstream = _sessionLadder.any((r) => r.upstream != null);
    _ladderIndex = 0;
    _ladderAttempts = 0;
    _regionPhase = _inRegion.isNotEmpty;
    _qualityDone = false;
    _qualityAttempts = 1;
    // The prepare gate: a pinned method with nothing to run
    // fails BEFORE anything starts, with the reason in plain
    // words (preparePsiphonLadder).
    final pinned = rungs.length == 1 ? rungs.single : null;
    if (_sessionLadder.isEmpty && pinned != null) {
      final sentence = switch (pinned) {
        'E' =>
          'There is no clean IP yet — open Psiphon settings → '
              'CDN edges and run Test all.',
        'P' => 'No Conduit pairing link yet — add one in Psiphon settings.',
        _ => 'No Psiphon method is available with the current settings.',
      };
      if (pinned == 'E' || pinned == 'P') {
        _logLine('psiphon failed: $sentence');
        _lastError = sentence;
        await _closeLog();
        throw StateError(sentence);
      }
      // A pinned X with no upstream leaves an empty ladder:
      // the service still makes one base-config attempt (its
      // ladder timer simply never arms). Fall through.
    }
    if (protocols.isNotEmpty || disableTimeouts || cdnFront) {
      // Carried inputs the MLM host does not consume, named
      // rather than silently dropped (the service's parked
      // inputs — the ladder owns protocol selection now).
      _logLine(
        'parked inputs noted: '
        '${protocols.isNotEmpty ? 'protocols ' : ''}'
        '${disableTimeouts ? 'disableTimeouts ' : ''}'
        '${cdnFront ? 'cdnFront' : ''}'
        '(the ladder owns protocol selection; the TUN dns/mtu/ipv6 '
        'are the bridge\u2019s, as on every Windows engine)',
      );
    }
    _logLine(
      'psiphon ladder: ${_sessionLadder.length} '
      '${_sessionLadder.length == 1 ? 'method' : 'methods'}'
      '${_regionPhase ? ' — region phase first: $_inRegion, '
          '${PsiphonConstants.regionPhaseTimeoutSeconds}s' : ''}'
      '${_sessionHasUpstream ? ' — chained through a proxy' : ''}',
    );
    _running = true;
    _startReturned = false;
    await _startAttempt();
  }

  void _resetRun() {
    _connected = false;
    _wedged = false;
    _sinceMs = 0;
    _up = 0;
    _down = 0;
    _region = '';
    _clientAddress = '';
    _regions = [];
    _activeMethod = '';
    _activeTunnelProtocol = '';
    _inproxyInUse = false;
    _routingActivated = false;
    _ladderActive = false;
    _expectedExit = false;
    _lastError = '';
    _socksPort = PsiphonPlatform.socksPort;
    _httpPort = PsiphonPlatform.httpPort;
    _bindFailed = false;
  }

  // ---- the ladder ----------------------------------------------------

  /// The host's winner memory (PsiphonMethods' file twin):
  /// which rung carried the last tunnel, per mode — the direct
  /// and upstream-fed ladders are different ladders.
  File get _strategyFile => File('${_dir!.path}/psiphon_strategy.json');

  String? _remembered({required bool chained}) {
    try {
      final f = _strategyFile;
      if (!f.existsSync()) return null;
      final doc = jsonDecode(f.readAsStringSync());
      if (doc is! Map) return null;
      final v = doc[chained ? 'psiphon_last_rung_chained' : 'psiphon_last_rung'];
      if (v is String && PsiphonConstants.ladderOrder.contains(v)) return v;
    } catch (_) {
      // A damaged memory reads as no memory.
    }
    return null;
  }

  void _remember({required bool chained, required String name}) {
    if (!PsiphonConstants.ladderOrder.contains(name)) return;
    try {
      var doc = <String, dynamic>{};
      final f = _strategyFile;
      if (f.existsSync()) {
        final old = jsonDecode(f.readAsStringSync());
        if (old is Map) doc = old.cast<String, dynamic>();
      }
      doc[chained ? 'psiphon_last_rung_chained' : 'psiphon_last_rung'] = name;
      f.writeAsStringSync(jsonEncode(doc));
    } catch (_) {
      // Memory is best-effort; the session stands without it.
    }
  }

  /// The clean-IP rung's feed: the owner's tested edges as
  /// preresolved /32s per provider, unioned with the Shiro
  /// bootstrap's preresolved CIDRs when that set is on
  /// (PsiphonVpnService.cleanCidrs). Null when there is
  /// nothing to feed — the rung then does not exist.
  Map<String, List<String>>? _cleanCidrs() {
    final out = <String, List<String>>{};
    void add(String provider, List<String> ips) {
      if (ips.isEmpty) return;
      final list = out.putIfAbsent(provider, () => []);
      for (final ip in ips) {
        final cidr = ip.contains('/') ? ip : '$ip/32';
        if (!list.contains(cidr)) list.add(cidr);
      }
    }

    add(PsiphonConstants.frontingProviderAkamai, _inCleanAkamai);
    add(PsiphonConstants.frontingProviderFastly, _inCleanFastly);
    _shiroCidrs.forEach(add);
    return out.isEmpty ? null : out;
  }

  PsiphonRung? _rungFor(String name) {
    switch (name) {
      case 'A':
        return const PsiphonRung(
          'A',
          preferredProtocols: PsiphonConstants.frontedProtocols,
        );
      case 'E':
        if (_cleanCidrs() == null) return null;
        return const PsiphonRung(
          'E',
          preferredProtocols: ['FRONTED-MEEK-OSSH'],
          dataRootName: 'psiphon-clean',
        );
      case 'D':
        return const PsiphonRung(
          'D',
          preferredProtocols: PsiphonConstants.directProtocols,
        );
      case 'C':
        return const PsiphonRung('C');
      case 'P':
        if (_inCompartment.isEmpty) return null;
        return const PsiphonRung('P');
      default:
        return null;
    }
  }

  /// The session's ladder (buildSessionLadder): X rungs ride
  /// in front when an upstream is set; a pinned method runs
  /// alone; Auto runs the ladder minus P, with the remembered
  /// winner for this mode moved to the front.
  List<PsiphonRung> _buildSessionLadder(List<String> inRungs) {
    final upstreamRungs = [
      for (final url in parsePsiphonUpstreams(_inUpstream))
        PsiphonRung(
          'X',
          preferredProtocols: PsiphonConstants.directProtocols,
          dataRootName: 'psiphon-upstream',
          upstream: url,
        ),
    ];
    if (inRungs.length == 1) {
      final only = inRungs.single;
      if (only == 'X') return upstreamRungs;
      final single = _rungFor(only);
      return single != null ? [single] : const [];
    }
    final membership = inRungs.isEmpty
        ? PsiphonConstants.ladderOrder.toSet()
        : inRungs.toSet();
    final auto = <PsiphonRung>[
      for (final name in PsiphonConstants.ladderOrder)
        if (membership.contains(name) && name != 'P')
          if (_rungFor(name) case final rung?) rung,
    ];
    final remembered = _remembered(chained: upstreamRungs.isNotEmpty);
    if (remembered != null) {
      final i = auto.indexWhere((r) => r.name == remembered);
      if (i > 0) auto.insert(0, auto.removeAt(i));
    }
    if (upstreamRungs.isNotEmpty &&
        (inRungs.isEmpty || inRungs.contains('X'))) {
      return [...upstreamRungs, ...auto];
    }
    return auto;
  }

  // ---- the config (buildPsiphonConfig's twin) ------------------------

  Directory _dataRootFor(PsiphonRung? rung) {
    final dir = _dir!;
    if (rung?.dataRootName != null) {
      return Directory('${dir.path}/${rung!.dataRootName}');
    }
    return Directory('${dir.path}/data');
  }

  /// Builds the current attempt's config through the pure
  /// builder below and writes its log lines.
  Map<String, dynamic> _buildConfig() {
    final rung = _sessionLadder.elementAtOrNull(_ladderIndex);
    final root = _dataRootFor(rung);
    root.createSync(recursive: true);
    Directory('${root.path}/psiphon_osl').createSync(recursive: true);
    final built = buildPsiphonSessionConfig(
      shiro: _inShiroBootstrap,
      strongMode: _inStrongMode,
      dataRootPath: root.path,
      socksPort: _socksPort,
      httpPort: _httpPort,
      rung: rung,
      regionPhase: _regionPhase,
      region: _inRegion,
      regionFronted: _frontedRegions.contains(_inRegion.toUpperCase()),
      cleanCidrs: _cleanCidrs(),
      shiroCidrs: _shiroCidrs,
      compartment: _inCompartment,
    );
    for (final line in built.logs) {
      _logLine(line);
    }
    return built.config;
  }

  // ---- attempts --------------------------------------------------------

  /// Starts the core on the current rung (startPsiphonTunnel).
  /// The TUN bridge stays up across rungs — only the core is
  /// torn down and restarted; the SOCKS port is fixed for the
  /// session, so a restart only breaks in-flight sockets.
  Future<void> _startAttempt() async {
    final gen = _sessionGen;
    _activeTunnelProtocol = '';
    _inproxyInUse = false;
    try {
      final config = _buildConfig();
      final dir = _dir!;
      final configFile = File('${dir.path}/psiphon.config');
      await configFile.writeAsString(jsonEncode(config), flush: true);
      final entries = _inShiroBootstrap
          ? File('${dir.path}/server_list_shiro.dat')
          : File('${dir.path}/server_entries.txt');
      Process proc;
      try {
        proc = await Process.start(
          _coreExe,
          ['-config', configFile.path, '-serverList', entries.path],
          workingDirectory: dir.path,
        );
      } catch (e) {
        _failAndStop('Psiphon could not start: $e');
        return;
      }
      if (gen != _sessionGen || _stopping) {
        // The session moved on while the spawn was in flight.
        proc.kill();
        return;
      }
      _proc = proc;
      _spawnedAt = DateTime.now();
      _expectedExit = false;
      _startReturned = true;
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLine, onError: (_) {});
      proc.stdout.transform(utf8.decoder).listen(
            (s) => _logSink?.write(s),
            onError: (_) {},
          );
      unawaited(
        proc.exitCode.then((code) => _onProcExit(proc, code)),
      );
      final rung = _sessionLadder.elementAtOrNull(_ladderIndex);
      _logLine(
        'psiphon tunnel starting'
        '${rung != null ? ' — method ${_ladderIndex + 1}/${_sessionLadder.length}: ${rung.label}, up to ${_rungSeconds(rung)}s' : ''}',
      );
      _armLadderTimer();
    } catch (e) {
      // Nothing is armed at this point, so no timer will ever
      // fire: fail here instead of sitting on "connecting"
      // forever with no tunnel behind it (MLM's note, kept).
      _failAndStop('Psiphon could not start: $e');
    }
  }

  /// The seconds the current attempt may take: the region
  /// phase's short budget while it runs, else the rung's.
  int _rungSeconds(PsiphonRung rung) =>
      _regionPhase && _inRegion.isNotEmpty
          ? PsiphonConstants.regionPhaseTimeoutSeconds
          : rung.timeoutSeconds;

  /// Arms the current rung's escalation timer: its budget
  /// plus a grace for the core's own timeout to fire first.
  void _armLadderTimer() {
    _ladderTimer?.cancel();
    _ladderActive = true;
    if (_stopping || !_running) return;
    final rung = _sessionLadder.elementAtOrNull(_ladderIndex);
    if (rung == null) return;
    final seconds = _rungSeconds(rung) + PsiphonConstants.ladderGraceSeconds;
    final gen = _sessionGen;
    _ladderTimer = Timer(Duration(seconds: seconds), () {
      if (gen != _sessionGen) return;
      _escalate('no tunnel in ${_rungSeconds(rung)}s (method budget + grace)');
    });
  }

  /// Moves the session to the next rung, or ends it
  /// (escalateLadder). The ladder-active flag is the one-shot
  /// latch per attempt: a timer and a core exit racing the
  /// same dead rung escalate ONCE, and the next attempt
  /// re-arms it. A failed region phase is not counted: the
  /// flag clears and the same rung restarts unfiltered.
  /// Wrap-around — every rung has had its turn — is the
  /// session's failure, with MLM's sentence.
  void _escalate(String reason) {
    if (_stopping || !_running) return;
    if (!_ladderActive) return;
    _ladderActive = false;
    _ladderTimer?.cancel();
    if (_regionPhase && _inRegion.isNotEmpty) {
      _regionPhase = false;
      _logLine(
        'preferred country $_inRegion did not connect ($reason) — '
        'continuing with all countries from method '
        '${_sessionLadder.elementAtOrNull(_ladderIndex)?.name ?? '?'}',
      );
      unawaited(_restartCoreInline());
      return;
    }
    final failed = _sessionLadder.elementAtOrNull(_ladderIndex);
    _ladderAttempts++;
    if (_ladderAttempts >= _sessionLadder.length) {
      _logLine(
        'all ${_sessionLadder.length} strategies exhausted — the '
        'carrier is blocking every available path',
      );
      _ladderIndex = 0;
      _ladderAttempts = 0;
      _regionPhase = false;
      _failAndStop('Could not connect on this carrier. Try Wi-Fi or another SIM.');
      return;
    }
    _ladderIndex = (_ladderIndex + 1) % _sessionLadder.length;
    // A new rung draws its own servers.
    _qualityAttempts = 1;
    final next = _sessionLadder.elementAtOrNull(_ladderIndex);
    _logLine(
      'strategy ${failed?.name ?? '?'} timed out ($reason) — escalating to '
      '${next?.name}: ${next?.label}',
    );
    unawaited(_restartCoreInline());
  }

  /// Restarts the core on the (new) current rung: stop
  /// inline, a beat, start.
  Future<void> _restartCoreInline() async {
    final gen = _sessionGen;
    await _killCore();
    await Future<void>.delayed(
      const Duration(milliseconds: PsiphonConstants.rungRestartPauseMs),
    );
    if (gen != _sessionGen || _stopping || !_running) return;
    await _startAttempt();
  }

  /// Kills the current core process and waits briefly for it
  /// to actually exit, so the next spawn does not race the
  /// old one's port release.
  Future<void> _killCore() async {
    final proc = _proc;
    _proc = null;
    if (proc == null) return;
    _expectedExit = true;
    proc.kill();
    try {
      await proc.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {
      // Already gone, or not waiting longer.
    }
  }

  // ---- the core's notices ------------------------------------------------

  /// Watches core output for a bind failure of the local
  /// proxies, so the run can fail fast with the specific
  /// ports-busy message instead of a rung-length timeout.
  void _scanForBindFailure(String text) {
    if (_bindFailed || _connected) return;
    if (text.contains('already in use') ||
        text.contains('Only one usage of each socket address')) {
      _bindFailed = true;
      _failAndStop(portsBusyMessage);
    }
  }

  /// One stderr line from the core: a JSON notice, tee'd to
  /// the session log (the controller's log viewer reads
  /// psiphon.log, as on Android). Non-notice stderr text (a Go
  /// panic dump, say) is logged the same way.
  void _onLine(String line) {
    _logSink?.writeln(line);
    _scanForBindFailure(line);
    Map<String, dynamic> notice;
    try {
      notice = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final data = (notice['data'] as Map?)?.cast<String, dynamic>() ?? {};
    switch (notice['noticeType']) {
      case 'ListeningSocksProxyPort':
        final port = (data['port'] as num?)?.toInt() ?? 0;
        if (port != 0 && port != _socksPort) {
          _logLine(
            'psiphon SOCKS listener on unexpected port $port '
            '(the chain dials $_socksPort)',
          );
        }
      case 'ListeningHttpProxyPort':
        // Evidence only (the service's note, kept).
        _logLine(
          'psiphon HTTP proxy listening on ${data['port']} (noted)',
        );
      case 'Tunnels':
        final count = (data['count'] as num?)?.toInt() ?? 0;
        if (count >= 1 && !_connected) {
          _onConnected();
        } else if (count == 0 && _connected) {
          // The core dropped its tunnel and is re-establishing
          // on its own; the published state follows it, and
          // routing (once up) stays pointed at the SOCKS port.
          _connected = false;
        }
      case 'ActiveTunnel':
        final protocol = data['protocol'] as String? ?? '';
        if (protocol.isNotEmpty) _activeTunnelProtocol = protocol;
      case 'AvailableEgressRegions':
        _regions = ((data['regions'] as List?) ?? [])
            .map((e) => e.toString())
            .toList();
      case 'ClientRegion':
        _region = data['region'] as String? ?? '';
      case 'ClientAddress':
        _clientAddress = data['address'] as String? ?? '';
      case 'BytesTransferred':
        _up += (data['sent'] as num?)?.toInt() ?? 0;
        _down += (data['received'] as num?)?.toInt() ?? 0;
      default:
        // In-proxy evidence for winner attribution, whatever
        // exact notice shape carries it.
        if ((notice['noticeType'] as String? ?? '').contains('Inproxy') &&
            data['inUse'] == true) {
          _inproxyInUse = true;
        }
    }
  }

  /// The core has a tunnel (onConnected). Attribution is
  /// scheduled first; proxy mode is connected NOW (the SOCKS
  /// is the product); VPN mode runs the quality gate before
  /// anyone's traffic is routed through the drawn server —
  /// except through an upstream rung, where the proxy is the
  /// narrow part and every server measures the same.
  void _onConnected() {
    _logLine('psiphon tunnel connected');
    _scheduleAttribution();
    if (!_inVpnMode) {
      _logLine('psiphon SOCKS proxy ready at 127.0.0.1:$_socksPort');
      _connected = true;
      if (_sinceMs == 0) {
        _sinceMs = DateTime.now().millisecondsSinceEpoch;
      }
      _ladderActive = false;
      _ladderTimer?.cancel();
      return;
    }
    if (_routingActivated && _bridge != null && !_bridgeDown) {
      _logLine('psiphon reconnected — the TUN bridge is still routing, nothing to do');
      _connected = true;
      return;
    }
    final rung = _sessionLadder.elementAtOrNull(_ladderIndex);
    if (!_qualityDone && rung != null && rung.upstream == null) {
      final gen = ++_qualityGen;
      final viaRegion = _regionPhase;
      unawaited(_qualityCheck(gen, viaRegion));
      return;
    }
    unawaited(_activateRouting());
  }

  /// The server-quality gate (psiphonQualityCheck): measure
  /// the drawn server BEFORE routing; a slow one is rejected
  /// — the core stops, its replay state drops (the same
  /// server would otherwise be redrawn at once), and the
  /// same rung draws again, at most
  /// [PsiphonQuality.maxServerAttempts] draws. A measurement
  /// that moved no byte at all is NOT "slow" (the dead-path
  /// case — routing goes ahead and the session's own loss
  /// handling judges).
  Future<void> _qualityCheck(int gen, bool viaRegion) async {
    final session = _sessionGen;
    if (_stopping || !_running || gen != _qualityGen) return;
    final rung = _sessionLadder.elementAtOrNull(_ladderIndex);
    final result = await PsiphonQuality.measure(_socksPort);
    _logLine(
      'psiphon capacity: ${result.mbit} Mbit/s with '
      '${PsiphonQuality.streams} streams (${result.okStreams} brought '
      'bytes, ${result.bytes} bytes in ${result.ms} ms) — server '
      '$_qualityAttempts of ${PsiphonQuality.maxServerAttempts}',
    );
    if (_stopping || !_running || gen != _qualityGen || session != _sessionGen) {
      return;
    }
    final slow =
        result.okStreams > 0 && result.mbit < PsiphonQuality.minGoodMbit;
    if (slow && _qualityAttempts < PsiphonQuality.maxServerAttempts) {
      _qualityAttempts++;
      _logLine(
        'slow server (${result.mbit} Mbit/s) — drawing another, '
        '$_qualityAttempts of ${PsiphonQuality.maxServerAttempts}',
      );
      await _killCore();
      await Future<void>.delayed(
        const Duration(milliseconds: PsiphonConstants.rungRestartPauseMs),
      );
      if (_stopping || !_running || session != _sessionGen) return;
      _dropReplayState(rung);
      // The same country again when that is where the first
      // server came from.
      if (viaRegion && _inRegion.isNotEmpty) _regionPhase = true;
      await _startAttempt();
      return;
    }
    if (slow) {
      _logLine(
        'after $_qualityAttempts servers the best this line gave was '
        '${result.mbit} Mbit/s — keeping it',
      );
    }
    _qualityDone = true;
    await _activateRouting();
  }

  /// Drops the tunnel-core datastore under a data root, so a
  /// redraw does not replay the same server at once. The
  /// downloaded server list lives OUTSIDE the datastore and
  /// survives.
  void _dropReplayState(PsiphonRung? rung) {
    final root = _dataRootFor(rung);
    final candidates = [
      Directory('${root.path}/ca.psiphon.PsiphonTunnel.tunnel-core/datastore'),
      Directory('${root.path}/datastore'),
    ];
    for (final candidate in candidates) {
      try {
        if (candidate.existsSync()) {
          candidate.deleteSync(recursive: true);
          _logLine("dropped the core's replay state (${candidate.path})");
          return;
        }
      } catch (e) {
        _logLine('could not drop the replay state: $e');
      }
    }
  }

  /// The TUN bridge onto Psiphon's port: the device is
  /// routed, and only now is it CONNECTED.
  Future<void> _activateRouting() async {
    final session = _sessionGen;
    final sink = _logSink;
    if (sink == null || _dir == null) {
      _failAndStop('VPN interface missing');
      return;
    }
    TunBridge bridge;
    try {
      bridge = await TunBridge.start(
        socksPort: _socksPort,
        skipProgram: 'psiphon-core.exe',
        log: sink,
        logDir: _dir!,
      );
    } catch (e) {
      _failAndStop('Could not start whole-device routing: $e');
      return;
    }
    if (session != _sessionGen || _stopping || !_running) {
      await bridge.stop();
      return;
    }
    _bridge = bridge;
    _bridgeDown = false;
    _routingActivated = true;
    _ladderActive = false;
    _ladderTimer?.cancel();
    _connected = true;
    if (_sinceMs == 0) {
      _sinceMs = DateTime.now().millisecondsSinceEpoch;
    }
    _logLine(
      'whole-device routing active via the TUN bridge → 127.0.0.1:$_socksPort',
    );
    unawaited(
      bridge.down.then((_) {
        _bridgeDown = true;
        // The TUN ended under a live session: with the
        // interface itself gone there is nothing to hold —
        // the session ends rather than leaking traffic
        // direct under a "connected" claim.
        if (identical(_bridge, bridge) && _running && !_stopping) {
          _failAndStop('whole-device routing stopped');
        }
      }),
    );
  }

  // ---- winner attribution (scheduleLadderAttribution) -------------------

  /// Names the rung that carried the tunnel, 2 s after
  /// connect — deferred because the core's ActiveTunnel
  /// notice lands after the tunnel itself. One-shot per
  /// connect.
  void _scheduleAttribution() {
    if (_attributionPending) return;
    _attributionPending = true;
    final session = _sessionGen;
    Timer(const Duration(seconds: 2), () {
      _attributionPending = false;
      if (session != _sessionGen || _stopping || !_connected) return;
      _recordWinner(_resolveWinner());
    });
  }

  /// MLM's precedence, in order: an upstream rung is
  /// remembered as X; an INPROXY protocol is rung C; a
  /// protocol exactly one rung prefers names that rung; a
  /// protocol the active rung prefers names it; any rung's
  /// preference; the broker evidence; the active rung.
  String _resolveWinner() {
    final active = _sessionLadder.elementAtOrNull(_ladderIndex);
    if (active == null) return '';
    if (active.upstream != null) return 'X';
    final protocol = _activeTunnelProtocol;
    if (protocol.startsWith('INPROXY')) return 'C';
    if (protocol.isNotEmpty) {
      final matches = _sessionLadder
          .where((r) => r.preferredProtocols.contains(protocol))
          .toList();
      if (matches.length == 1) return matches.first.name;
      if (active.preferredProtocols.contains(protocol)) return active.name;
      if (matches.isNotEmpty) return matches.first.name;
    }
    if (_inproxyInUse) return 'C';
    return active.name;
  }

  /// Persists the winner by name for this mode and publishes
  /// it as the session's method.
  void _recordWinner(String name) {
    if (name.isEmpty) return;
    _remember(chained: _sessionHasUpstream, name: name);
    _activeMethod = name;
    _logLine('ladder winner: method $name (${PsiphonConstants.methodLabel(name)})');
  }

  // ---- core exit, failure, the kill-switch hold --------------------------

  /// The core process exited. A deliberate kill (a ladder
  /// restart, the quality redraw, a teardown) is marked
  /// expected and never lands here as a death. An exit while
  /// an attempt is in flight is that rung's definitive death
  /// signal — escalate now instead of waiting out the timer's
  /// grace (onExiting). An established session's exit ends
  /// the session here (through the kill-switch consult).
  void _onProcExit(Process proc, int code) {
    if (!identical(_proc, proc)) return;
    _proc = null;
    if (_expectedExit) {
      _expectedExit = false;
      return;
    }
    if (_stopping || !_running) return;
    final instant = _spawnedAt != null &&
        DateTime.now().difference(_spawnedAt!) < const Duration(seconds: 2);
    if (_lastError.isEmpty) {
      _lastError = instant
          ? 'psiphon-core.exe exited at once (code $code). $firewallGuidance'
          : 'psiphon-core.exe exited (code $code)';
    }
    _logLine(
      '[ember] psiphon-core exited (code $code)'
      '${instant ? ' — within 2s of start' : ''}',
    );
    if (_ladderActive) {
      _escalate('core exited');
      return;
    }
    _failAndStop(_lastError);
  }

  /// Whether this session's unexpected death may be held as
  /// a blackhole: TUN mode, the switch on, routing was up,
  /// and the bridge itself still lives (its SOCKS target is
  /// dead now, so everything it forwards drops).
  bool _canHoldKillSwitch() =>
      _inVpnMode &&
      _inKillSwitch &&
      _routingActivated &&
      _bridge != null &&
      !_bridgeDown;

  /// Kill switch (build 2125, A25-04 / S-4): a LIVE session
  /// died unexpectedly with the switch on. The core stops,
  /// but the TUN bridge is NOT stopped — it keeps forwarding
  /// into a dead SOCKS port, so traffic BLOCKS instead of
  /// going direct, until the user disconnects (stop tears
  /// everything down as always) or a fresh start replaces
  /// the held bridge. The published state says the session
  /// is down AND held.
  void _holdKillSwitch(String reason) {
    _ladderActive = false;
    _ladderTimer?.cancel();
    _logLine(
      'psiphon failed: $reason — kill switch holding the '
      'tunnel; traffic is blocked, not direct',
    );
    unawaited(_killCore());
    _routingActivated = false;
    _connected = false;
    _killSwitchHeld = true;
    _running = false;
    unawaited(_closeLog());
  }

  /// Ends the session with a reason: the reason lands in the
  /// session log the error surface quotes, and the teardown
  /// is the ordinary stop. An ESTABLISHED session's failure
  /// consults the kill switch first.
  void _failAndStop(String reason) {
    if (_routingActivated && _canHoldKillSwitch()) {
      _holdKillSwitch(reason);
      return;
    }
    _ladderActive = false;
    _ladderTimer?.cancel();
    _logLine('psiphon failed: $reason');
    if (_lastError.isEmpty) _lastError = reason;
    unawaited(stop());
  }

  @override
  Future<void> stop() async {
    _stopping = true;
    _sessionGen++;
    _ladderActive = false;
    _ladderTimer?.cancel();
    await _killCore();
    final bridge = _bridge;
    _bridge = null;
    _bridgeDown = false;
    if (bridge != null) await bridge.stop();
    _running = false;
    _connected = false;
    _killSwitchHeld = false;
    _wedged = false;
    _routingActivated = false;
    await _closeLog();
  }

  /// The external watchdog's firing (build 2088): the
  /// decision lives in the controller (psiphon_watchdog.dart);
  /// the acting is here — the attempt's evidence goes to
  /// crash.log, the wedged core is killed, the bridge comes
  /// down with it (the process that owned the TUN is gone),
  /// and the wedge is published for the connect path to fail
  /// fast on.
  @override
  Future<Map<String, dynamic>?> externalWatchdog() async {
    try {
      final dir = _dir ?? await workDir();
      final buf = StringBuffer()
        ..writeln(
          '==== psiphon external watchdog '
          '(${DateTime.now().toIso8601String()}) ====',
        )
        ..writeln(
          'the start attempt was still inside its start past '
          'the watchdog deadline, or the core never reported '
          'running; the core process was killed from outside. '
          'The session log tail follows.',
        );
      try {
        final log = File('${dir.path}/psiphon.log');
        if (await log.exists()) {
          final bytes = await log.readAsBytes();
          final tail = bytes.length > 32 * 1024
              ? bytes.sublist(bytes.length - 32 * 1024)
              : bytes;
          buf.writeln('—— psiphon.log ——');
          buf.writeln(utf8.decode(tail, allowMalformed: true));
        }
      } catch (_) {
        // Evidence is best-effort.
      }
      await File('${dir.parent.path}/crash.log').writeAsString(
        buf.toString(),
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Evidence only; the firing proceeds regardless.
    }
    final hadProc = _proc != null;
    _sessionGen++;
    _ladderActive = false;
    _ladderTimer?.cancel();
    await _killCore();
    final bridge = _bridge;
    _bridge = null;
    _bridgeDown = false;
    if (bridge != null) await bridge.stop();
    _routingActivated = false;
    _connected = false;
    _running = false;
    _wedged = true;
    await _closeLog();
    return {'killed': hadProc};
  }

  @override
  Future<PsiphonState> state() async {
    return PsiphonState(
      running: _running,
      connected: _connected,
      vpnMode: _inVpnMode,
      sinceMs: _sinceMs,
      upBytes: _up,
      downBytes: _down,
      region: _region,
      clientAddress: _clientAddress,
      regions: _regions,
      method: _activeMethod,
      wedged: _wedged,
      startReturned: _startReturned,
      killSwitchHeld: _killSwitchHeld,
    );
  }

  // ---- exit info ---------------------------------------------------------

  @override
  Future<Map<String, String>?> exitInfo() async {
    if (!_connected) return null;
    // A whole GET through the tunnel's own HTTP proxy (dart:io's
    // PROXY line — its findProxy has no SOCKS form).
    try {
      final text = await _httpGetText(
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

  Future<String?> _httpGetText(String url) async {
    const timeout = Duration(seconds: 6);
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'PROXY 127.0.0.1:$_httpPort';
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      return await response.transform(utf8.decoder).join().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  // ---- the session log ---------------------------------------------------

  void _logLine(String line) {
    _logSink?.writeln('[ember] $line');
  }

  Future<void> _openLog(Directory dir) async {
    await _closeLog();
    final file = File('${dir.path}/psiphon.log');
    try {
      // Keep the session log bounded across runs: past ~1 MB
      // the previous log rotates to psiphon.log.old.
      if (await file.exists() && await file.length() > 1024 * 1024) {
        final old = File('${dir.path}/psiphon.log.old');
        if (await old.exists()) await old.delete();
        await file.rename(old.path);
      }
    } catch (_) {
      // Rotation is housekeeping; the log proceeds regardless.
    }
    final sink = file.openWrite(mode: FileMode.append);
    _logSink = sink;
    sink.writeln(
      '--- psiphon-core start ${DateTime.now().toIso8601String()} ---',
    );
  }

  Future<void> _closeLog() async {
    final sink = _logSink;
    _logSink = null;
    try {
      await sink?.flush();
      await sink?.close();
    } catch (_) {
      // The log is best-effort.
    }
  }

  /// Reaps psiphon-core.exe processes orphaned by a previous,
  /// hard-killed app run — only copies of THIS app's sidecar
  /// (exact path match) and only while this backend holds no
  /// live process of its own. Once per app run; best-effort.
  Future<void> _ensureCleaned() async {
    if (_cleanedUp || _proc != null) return;
    _cleanedUp = true;
    final killed = await killOrphanedSidecars(
      exePath: _coreExe,
      processName: 'psiphon-core.exe',
    );
    for (final pid in killed) {
      _logLine(
        'killed orphaned psiphon-core.exe (pid $pid) left over '
        'from a previous run',
      );
    }
  }

  // ---- bundled entries, fronted regions, Shiro CIDRs ----------------------

  String _entriesText = '';
  Set<String> _frontedRegions = {};
  bool _frontedRegionsShiro = false;
  Map<String, List<String>> _shiroCidrs = {};

  /// Extracts the bundled server entries the ConsoleClient
  /// wants as a file path (the same files Android's host
  /// feeds its core: the MLM set, or the Shiro set when that
  /// bootstrap is on), and parses the fronted-region set from
  /// whichever set is in play.
  Future<void> _ensureEntries() async {
    final dir = _dir!;
    Future<File> extract(String asset, String name) async {
      final file = File('${dir.path}/$name');
      final data = await rootBundle.load(asset);
      if (!await file.exists() || await file.length() != data.lengthInBytes) {
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      return file;
    }

    final mlm = await extract(
      PsiphonConstants.serverEntriesAsset,
      'server_entries.txt',
    );
    await extract(
      PsiphonConstants.shiroServerEntriesAsset,
      'server_list_shiro.dat',
    );
    final active = _inShiroBootstrap
        ? File('${dir.path}/server_list_shiro.dat')
        : mlm;
    _entriesText = await active.readAsString();
    if (_frontedRegionsShiro != _inShiroBootstrap || _frontedRegions.isEmpty) {
      _frontedRegions = _parseFrontedRegions(_entriesText);
      _frontedRegionsShiro = _inShiroBootstrap;
      _logLine(
        'countries with a fronted server: '
        '${(_frontedRegions.toList()..sort()).join(',')}',
      );
    }
  }

  /// The fronted regions of the bundled entries (frontedRegions):
  /// a region qualifies when one of its entries advertises a
  /// FRONTED-MEEK protocol. Entries are hex lines whose decoded
  /// form is a prefix plus the entry JSON. Any parse failure
  /// reads as "no fronted regions" — the region phase then
  /// drops the fronted limit, the safe read.
  Set<String> _parseFrontedRegions(String text) {
    final regions = <String>{};
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.length < 32) continue;
      try {
        final decoded = utf8.decode(_hexToBytes(trimmed));
        final jsonStart = decoded.indexOf('{');
        if (jsonStart < 0) continue;
        final entry = jsonDecode(decoded.substring(jsonStart));
        if (entry is! Map) continue;
        final caps = entry['capabilities'];
        if (caps is! List) continue;
        final fronted = caps.any(
          (c) => c.toString().startsWith('FRONTED-MEEK'),
        );
        if (fronted) {
          final region = (entry['region'] as String? ?? '').toUpperCase();
          if (region.isNotEmpty) regions.add(region);
        }
      } catch (_) {
        continue;
      }
    }
    return regions;
  }

  List<int> _hexToBytes(String hex) {
    final out = List<int>.filled(hex.length ~/ 2, 0);
    for (var i = 0; i + 1 < hex.length; i += 2) {
      out[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return out;
  }

  /// The Shiro fronting overrides as preresolved CIDRs
  /// (shiroPreresolvedCidrs): from the public
  /// shiro-fronting-default.json, ONLY the entries whose dial
  /// addresses are IPv4 literals, keyed under the Akamai
  /// provider id. Empty unless the Shiro bootstrap is on; any
  /// parse failure reads as empty.
  Future<void> _loadShiroCidrs() async {
    _shiroCidrs = {};
    if (!_inShiroBootstrap) return;
    try {
      final text = await rootBundle.loadString(
        PsiphonConstants.shiroFrontingAsset,
      );
      final specs = jsonDecode(text);
      if (specs is! List) return;
      final ips = <String>[];
      final v4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
      for (final spec in specs) {
        if (spec is! Map) continue;
        final dials = spec['DialAddresses'];
        if (dials is! List) continue;
        for (final d in dials) {
          final addr = d.toString().trim();
          if (v4.hasMatch(addr)) ips.add('$addr/32');
        }
      }
      if (ips.isNotEmpty) {
        _shiroCidrs = {PsiphonConstants.frontingProviderAkamai: ips};
        _logLine(
          'shiro fronting overrides: ${ips.length} edge IPs '
          'mapped to preresolved CIDRs',
        );
      }
    } catch (_) {
      // Empty is the safe read.
    }
  }
}

// ---------------------------------------------------------------------
// The config builder (buildPsiphonConfig + PsiphonStrategy.configure,
// as pure functions so the contract is test-pinned).
// ---------------------------------------------------------------------

/// The tactics override (A/E/D rungs): the downloaded tactics
/// must not rewrite the rung — Iran tactics once silently
/// replaced rung A's protocol list with INPROXY-WEBRTC.
/// In-proxy is also switched off: tactics had left it enabled
/// on a rung that never asked for it.
void applyPsiphonTacticsOverride(Map<String, dynamic> config) {
  config['DisableTactics'] = true;
  config['InproxyEnabled'] = false;
  config['InproxyAllowClient'] = false;
}

/// A proxy URL with any userinfo masked.
String maskedPsiphonProxy(String url) {
  final at = url.indexOf('@');
  if (at < 0) return url;
  final scheme = url.indexOf('://');
  if (scheme < 0 || scheme > at) return url;
  return '${url.substring(0, scheme + 3)}•••${url.substring(at)}';
}

/// One rung's config overrides (PsiphonStrategy.configure).
void applyPsiphonRung(
  PsiphonRung rung,
  Map<String, dynamic> config, {
  required Map<String, List<String>>? cleanCidrs,
  required Map<String, List<String>> shiroCidrs,
  required String compartment,
}) {
  switch (rung.name) {
    case 'A':
      config['InitialLimitTunnelProtocols'] =
          PsiphonConstants.frontedProtocols;
      config['InitialLimitTunnelProtocolsCandidateCount'] = 30;
      config['LimitTunnelProtocols'] = PsiphonConstants.frontedProtocols;
      config['ConnectionWorkerPoolSize'] = 12;
      config['NetworkLatencyMultiplier'] = 2.0;
      if (shiroCidrs.isNotEmpty) {
        config['DNSResolverPreresolvedIPAddressCIDRs'] = shiroCidrs;
        config['DNSResolverPreferPreresolvedIPAddressProbability'] = 1.0;
      }
      applyPsiphonTacticsOverride(config);
    case 'E':
      if (cleanCidrs == null) return;
      final count = cleanCidrs.values.fold<int>(0, (a, l) => a + l.length);
      config['InitialLimitTunnelProtocols'] = ['FRONTED-MEEK-OSSH'];
      config['InitialLimitTunnelProtocolsCandidateCount'] = count;
      config['LimitTunnelProtocols'] = ['FRONTED-MEEK-OSSH'];
      config['DNSResolverPreresolvedIPAddressCIDRs'] = cleanCidrs;
      config['DNSResolverPreferPreresolvedIPAddressProbability'] = 1.0;
      config['ConnectionWorkerPoolSize'] = 8;
      config['NetworkLatencyMultiplier'] = 1.5;
      applyPsiphonTacticsOverride(config);
    case 'D':
      config['ConnectionWorkerPoolSize'] = 16;
      applyPsiphonTacticsOverride(config);
    case 'C':
      // No tactics override: the broker specs arrive via
      // tactics, and the rung's whole point is in-proxy.
      config['InproxyEnabled'] = true;
      config['InproxyAllowClient'] = true;
      config['InproxySkipAwaitFullyConnectedTunnel'] = true;
      config['ConnectionWorkerPoolSize'] = 16;
      config['NetworkLatencyMultiplier'] = 3.0;
    case 'P':
      config['InproxyEnabled'] = true;
      config['InproxyAllowClient'] = true;
      config['InproxyClientPersonalCompartmentID'] = compartment;
      config['NetworkLatencyMultiplier'] = 3.0;
    case 'X':
      config['UpstreamProxyURL'] = rung.upstream;
      config['LimitTunnelProtocols'] = PsiphonConstants.chainableProtocols;
      config['ConnectionWorkerPoolSize'] = 16;
      config['InproxyEnabled'] = false;
      config['InproxyAllowClient'] = false;
  }
}

/// The core's config for one attempt: the base (identity set
/// chosen whole — MLM or Shiro), the current rung's overrides
/// and its establish budget, and the preferred-country phase
/// on top when it is running. Returns the config and the log
/// lines the host speaks for it.
({Map<String, dynamic> config, List<String> logs}) buildPsiphonSessionConfig({
  required bool shiro,
  required bool strongMode,
  required String dataRootPath,
  required int socksPort,
  required int httpPort,
  required PsiphonRung? rung,
  required bool regionPhase,
  required String region,
  required bool regionFronted,
  required Map<String, List<String>>? cleanCidrs,
  required Map<String, List<String>> shiroCidrs,
  required String compartment,
}) {
  final logs = <String>[];
  final config = <String, dynamic>{
    'PropagationChannelId': shiro
        ? PsiphonConstants.shiroPropagationChannelId
        : PsiphonConstants.propagationChannelId,
    'SponsorId':
        shiro ? PsiphonConstants.shiroSponsorId : PsiphonConstants.sponsorId,
    'EgressRegion': '',
    'EstablishTunnelTimeoutSeconds': 120,
    // The ConsoleClient's own key is DataRootDirectory;
    // DataDirectory rides along for the AAR-shaped readers of
    // this file (the core ignores keys it does not know).
    'DataDirectory': dataRootPath,
    'DataRootDirectory': dataRootPath,
    'ClientVersion': shiro
        ? PsiphonConstants.shiroClientVersion
        : PsiphonConstants.clientVersion,
    'TunnelProtocol': '',
    // Fetch Psiphon's server list instead of living on the
    // bundled entries alone.
    'RemoteServerListURLs': psiphonUrlList(
      shiro
          ? PsiphonConstants.shiroRemoteServerListUrls
          : PsiphonConstants.remoteServerListUrls,
    ),
    'RemoteServerListDownloadFilename':
        '$dataRootPath/psiphon_remote_server_list',
    'ObfuscatedServerListRootURLs': psiphonUrlList(
      shiro
          ? PsiphonConstants.shiroObfuscatedServerListRootUrls
          : PsiphonConstants.obfuscatedServerListRootUrls,
    ),
    'ObfuscatedServerListDownloadDirectory': '$dataRootPath/psiphon_osl',
    'LocalSocksProxyPort': socksPort,
    'LocalHttpProxyPort': httpPort,
    'RemoteServerListSignaturePublicKey': shiro
        ? PsiphonConstants.shiroRemoteServerListSignaturePublicKey
        : PsiphonConstants.remoteServerListSignaturePublicKey,
    'ServerEntrySignaturePublicKey': shiro
        ? PsiphonConstants.shiroServerEntrySignaturePublicKey
        : PsiphonConstants.serverEntrySignaturePublicKey,
    'ExchangeObfuscationKey': shiro
        ? PsiphonConstants.shiroExchangeObfuscationKey
        : PsiphonConstants.exchangeObfuscationKey,
    // Required for the byte counters to ever fire.
    'EmitBytesTransferred': true,
    // Iran-specific tactics are downloaded for this device
    // region (the MLM host's fixed value).
    'DeviceRegion': 'IR',
    'ConnectionWorkerPoolSize': 12,
    // The core's own words are this engine's evidence.
    'EmitDiagnosticNotices': true,
    'EmitDiagnosticNetworkParameters': true,
    'EmitServerAlerts': true,
    // The anti-hijack DNS trio: preferred alternates at
    // probability 1.0, 2 attempts per preferred server.
    'DNSResolverPreferredAlternateServers':
        PsiphonConstants.dnsPreferredAlternateServers,
    'DNSResolverPreferAlternateServerProbability': 1.0,
    'DNSResolverAttemptsPerPreferredServer': 2,
    if (shiro) ...{
      'UseIndistinguishableTLS': PsiphonConstants.shiroUseIndistinguishableTls,
      'FrontedMeekCDNScanUseBuiltInSpec':
          PsiphonConstants.shiroFrontedMeekCdnScanUseBuiltInSpec,
      'TunnelPoolSize': PsiphonConstants.shiroTunnelPoolSize,
    },
    if (strongMode) 'AggressiveEstablishment': true,
  };

  // The current rung's overrides, and its own establish
  // budget, so a dead rung is abandoned quickly instead of
  // burning the full two minutes.
  if (rung != null) {
    applyPsiphonRung(
      rung,
      config,
      cleanCidrs: cleanCidrs,
      shiroCidrs: shiroCidrs,
      compartment: compartment,
    );
    config['EstablishTunnelTimeoutSeconds'] = rung.timeoutSeconds;
    logs.add(
      'strategy (${rung.name}): ${rung.label} — ${rung.timeoutSeconds}s budget'
      '${rung.upstream != null ? ' — through ${maskedPsiphonProxy(rung.upstream!)}' : ''}'
      '${rung.name == 'E' ? ' — clean IPs ${config['DNSResolverPreresolvedIPAddressCIDRs']}' : ''}',
    );
  }

  // The preferred-country attempt, in front of the ladder and
  // only once. Applied AFTER the rung so it owns the establish
  // timeout; the rung's fronted limit is KEPT when the country
  // has a fronted server in the bundled entries and dropped
  // when it does not.
  if (regionPhase && region.isNotEmpty) {
    config['EgressRegion'] = region;
    config['EstablishTunnelTimeoutSeconds'] =
        PsiphonConstants.regionPhaseTimeoutSeconds;
    if (!regionFronted) {
      config.remove('InitialLimitTunnelProtocols');
      config.remove('InitialLimitTunnelProtocolsCandidateCount');
      config.remove('LimitTunnelProtocols');
    }
    logs.add(
      'preferred country $region, '
      '${regionFronted ? 'fronted servers exist there — keeping the fronted limit' : 'no fronted server there — all protocols'}'
      ' — ${PsiphonConstants.regionPhaseTimeoutSeconds}s before the ladder',
    );
  }
  if (shiro) {
    logs.add(
      'bootstrap: Shiro public set — its identity, its '
      'embedded entries and its fronting overrides',
    );
  }
  if (strongMode) logs.add('strong mode on: AggressiveEstablishment');
  logs.add(
    'psiphon DNS: ${PsiphonConstants.dnsPreferredAlternateServers.length} '
    "public resolvers on non-standard ports preferred over the operator's",
  );
  return (config: config, logs: logs);
}
