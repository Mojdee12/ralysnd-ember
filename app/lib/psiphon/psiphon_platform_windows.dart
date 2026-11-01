/// The Psiphon engine on Windows: the Psiphon tunnel-core
/// ConsoleClient — v2.0.42, the exact release the Android AAR wraps —
/// shipped as the psiphon\psiphon-core.exe sidecar and driven as a
/// child process. (Psiphon is GPLv3, like the Mozilla core this app
/// already ships; the sidecar is a separate unmodified program.)
///
/// The JSON config is PsiphonVpnService.buildConfig's twin: the same
/// keys, the same bootstrap values (psiphon_bootstrap.dart, generated
/// from PsiphonConstants.kt), the same embedded server list (the
/// app's bundled assets/psiphon/embedded_servers.txt, handed over
/// with the ConsoleClient's -serverList flag). The core announces
/// everything as JSON notices **on stderr** — the ConsoleClient's
/// notice writer defaults to os.Stderr and has no stdout mode (the
/// only alternative is its -notices file flag) — and they map onto
/// [PsiphonState] exactly as the MobileLibrary callbacks do on
/// Android:
///
///   Tunnels {count}            count 0 = connecting, >= 1 = connected
///   ListeningSocksProxyPort    the core is up (running)
///   AvailableEgressRegions     state.regions
///   ClientRegion               state.region
///   ClientAddress              state.clientAddress
///   BytesTransferred {sent, received}   deltas, accumulated here —
///                              Android's service sums the same way
///
/// VPN mode: the core only serves its local proxies, so once they
/// listen, the bundled TUN bridge (core/tun_bridge.dart) points the
/// service's system TUN at the SOCKS port, with psiphon-core.exe
/// itself kept outside the TUN. If the bridge cannot start, the
/// connect fails — the engine never silently runs proxy-only when
/// VPN mode was asked. The [dns] setting is Android's TUN DNS; the
/// Windows TUN service answers DNS itself, so it is unused here.
///
/// Stopping kills the child process (the Windows way; the core's
/// datastore is crash-tolerant). A hard app kill can orphan the
/// core holding its ports until it is closed — so the first start
/// of a run reaps leftover copies of THIS app's sidecar by exact
/// path (core/orphan_cleanup.dart), and if the local proxy ports
/// are still taken (another client's defaults collide the same
/// way), the session moves to the first free port pair, the config
/// regenerated on it.
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

/// The ConsoleClient config, key for key PsiphonVpnService's
/// buildConfig (top-level so it can be checked on its own). The
/// ports default to the platform constants; the Windows backend
/// passes its per-session pair when the defaults were taken.
Map<String, dynamic> buildPsiphonConfig({
  required String dataRoot,
  required String region,
  required String upstream,
  required List<String> protocols,
  int socksPort = PsiphonPlatform.socksPort,
  int httpPort = PsiphonPlatform.httpPort,
}) =>
    {
      'ClientVersion': PsiphonBootstrap.clientVersion,
      'PropagationChannelId': PsiphonBootstrap.propagationChannelId,
      'SponsorId': PsiphonBootstrap.sponsorId,
      'RemoteServerListSignaturePublicKey':
          PsiphonBootstrap.remoteServerListSignaturePublicKey,
      'ServerEntrySignaturePublicKey':
          PsiphonBootstrap.serverEntrySignaturePublicKey,
      'AdditionalParameters': PsiphonBootstrap.additionalParameters,
      'DataRootDirectory': dataRoot,
      'LocalSocksProxyPort': socksPort,
      'LocalHttpProxyPort': httpPort,
      'EmitDiagnosticNotices': true,
      'EmitBytesTransferred': true,
      'EgressRegion': region,
      if (upstream.isNotEmpty) 'UpstreamProxyURL': upstream,
      if (protocols.isNotEmpty) 'LimitTunnelProtocols': protocols,
    };

class WindowsPsiphonBackend implements PsiphonBackend {
  Process? _proc;
  IOSink? _logSink;
  TunBridge? _bridge;

  bool _listening = false;
  bool _connected = false;
  bool _vpnMode = true;
  int _sinceMs = 0;
  int _up = 0;
  int _down = 0;
  String _region = '';
  String _clientAddress = '';
  List<String> _regions = [];

  /// The last failure, in words, for [state] — also in psiphon.log.
  String _lastError = '';

  /// The local proxy ports this run uses: the platform constants,
  /// or the fallback pair [setOn] picked when those were taken.
  int _socksPort = PsiphonPlatform.socksPort;
  int _httpPort = PsiphonPlatform.httpPort;

  /// The core reported it could not bind its local proxies.
  bool _bindFailed = false;

  /// One-shot guard for the startup orphan reap.
  bool _cleanedUp = false;

  /// Said when the local proxy ports cannot be had: the usual
  /// cause is another proxy client holding them.
  static const portsBusyMessage =
      "Psiphon's local ports 11808/11809 are already in use by "
      'another program (for example v2rayN or another proxy app). '
      'Close it and try again.';

  /// When the current core process was spawned (instant-exit
  /// detection for the firewall/antivirus guidance).
  DateTime? _spawnedAt;

  /// Shown when the sidecar dies at once or will not start at all:
  /// the usual cause on a real PC is a security product, and a
  /// silent failure left that undiagnosable.
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

  @override
  Future<void> setOn({
    required bool vpnMode,
    required String region,
    required String upstream,
    required List<String> protocols,
    required String dns,
  }) async {
    if (_proc != null) await stop();
    if (!File(_coreExe).existsSync()) {
      throw StateError('psiphon-core-missing: $_coreExe');
    }
    final dir = await workDir();
    await dir.create(recursive: true);
    final dataRoot = Directory('${dir.path}/data');
    await dataRoot.create(recursive: true);

    final sink = File('${dir.path}/psiphon.log')
        .openWrite(mode: FileMode.append);
    _logSink = sink;
    sink.writeln(
      '--- psiphon-core start ${DateTime.now().toIso8601String()} ---',
    );

    _resetRun(vpnMode);
    _lastError = '';
    // Reap a previous run's orphaned sidecar first: it may be the
    // very thing holding the local proxy ports.
    await _ensureCleaned(sink);
    // Port selection: the platform pair when it can bind, else the
    // first free pair above it (same +1 spacing) — a taken 11808
    // must not be able to kill every connect. The config below is
    // generated on the chosen pair, and the TUN bridge and the
    // exit-IP lookup follow it.
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
        sink.writeln('[ember] $_lastError');
        await _closeLog();
        throw StateError(_lastError);
      }
      sink.writeln(
        '[ember] psiphon ports ${PsiphonPlatform.socksPort}/'
        '${PsiphonPlatform.httpPort} are busy, using $_socksPort/'
        '$_httpPort for this session',
      );
    }

    // The embedded server list ships as a Flutter asset (the same
    // file Android's core reads); the ConsoleClient wants a path.
    final serversFile = File('${dir.path}/embedded_servers.txt');
    final asset = await rootBundle.load('assets/psiphon/embedded_servers.txt');
    if (!await serversFile.exists() ||
        await serversFile.length() != asset.lengthInBytes) {
      await serversFile.writeAsBytes(asset.buffer.asUint8List(), flush: true);
    }

    final configFile = File('${dir.path}/psiphon.config');
    await configFile.writeAsString(
      jsonEncode(buildPsiphonConfig(
        dataRoot: dataRoot.path,
        region: region,
        upstream: upstream,
        protocols: protocols,
        socksPort: _socksPort,
        httpPort: _httpPort,
      )),
      flush: true,
    );

    Process proc;
    try {
      proc = await Process.start(
        _coreExe,
        ['-config', configFile.path, '-serverList', serversFile.path],
        workingDirectory: dir.path,
      );
    } catch (e) {
      _lastError = 'could not start psiphon-core.exe: $e. '
          '$firewallGuidance';
      sink.writeln('[ember] $_lastError');
      await _closeLog();
      throw StateError(_lastError);
    }
    _proc = proc;
    _spawnedAt = DateTime.now();
    // The notices live on STDERR (see the library doc): parse that
    // stream line by line. Parsing stdout instead was the 2.0.0–2.0.5
    // defect — the core ran healthily, its notices landed in the log
    // via the old raw tee, and the listener wait timed out on a core
    // that had been up for seconds. Stdout carries nothing in tunnel
    // mode; keep draining it into the log so a stray write can never
    // block the pipe and stays visible.
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onError: (_) {});
    proc.stdout.transform(utf8.decoder).listen((s) {
      sink.write(s);
    }, onError: (_) {});
    unawaited(proc.exitCode.then((code) {
      if (identical(_proc, proc)) {
        _proc = null;
        _listening = false;
        _connected = false;
        // The exit itself is evidence: keep it in the log the UI
        // shows, with the guidance when the core died at once.
        final instant = _spawnedAt != null &&
            DateTime.now().difference(_spawnedAt!) <
                const Duration(seconds: 2);
        if (_lastError.isEmpty) {
          _lastError = instant
              ? 'psiphon-core.exe exited at once (code $code). '
                  '$firewallGuidance'
              : 'psiphon-core.exe exited (code $code)';
        }
        _logSink?.writeln(
          '[ember] psiphon-core exited (code $code)'
          '${instant ? ' — within 2s of start' : ''}',
        );
        unawaited(_closeLog());
      }
    }));

    // The tunnel (and, in VPN mode, the TUN) is only real once the
    // proxies listen; the smoke-proven core binds them in ~a second.
    for (var i = 0; i < 60 && !_listening; i++) {
      if (_proc == null) {
        throw StateError(
          _lastError.isNotEmpty
              ? _lastError
              : 'psiphon-core-exited (see psiphon.log)',
        );
      }
      if (_bindFailed) {
        // The core said its proxies could not bind: fail fast with
        // the specific reason instead of the 15 s timeout below.
        await stop();
        throw StateError(portsBusyMessage);
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!_listening) {
      _lastError = 'psiphon-core started but did not open its local '
          'proxies within 15s — the core\'s own notices in '
          'psiphon.log above show what it was doing (it may still '
          'be retrying servers, or something stopped it binding)';
      sink.writeln('[ember] $_lastError');
      await stop();
      throw StateError(_lastError);
    }
    if (!vpnMode) {
      sink.writeln(
        '[ember] proxy mode: system-wide capture (TUN) is OFF — '
        'only apps pointed at 127.0.0.1:$_socksPort use this '
        'tunnel; the rest of the system is not captured',
      );
    }
    if (vpnMode) {
      try {
        _bridge = await TunBridge.start(
          socksPort: _socksPort,
          skipProgram: 'psiphon-core.exe',
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
        if (identical(_bridge, bridge) && _proc != null) {
          unawaited(stop());
        }
      }));
    }
  }

  void _resetRun(bool vpnMode) {
    _listening = false;
    _connected = false;
    _vpnMode = vpnMode;
    _sinceMs = 0;
    _up = 0;
    _down = 0;
    _region = '';
    _clientAddress = '';
    _regions = [];
    _socksPort = PsiphonPlatform.socksPort;
    _httpPort = PsiphonPlatform.httpPort;
    _bindFailed = false;
  }

  /// Reaps psiphon-core.exe processes orphaned by a previous,
  /// hard-killed app run — only copies of THIS app's sidecar
  /// (exact path match) and only while this backend holds no live
  /// process of its own. Once per app run; best-effort.
  Future<void> _ensureCleaned(IOSink sink) async {
    if (_cleanedUp || _proc != null) return;
    _cleanedUp = true;
    final killed = await killOrphanedSidecars(
      exePath: _coreExe,
      processName: 'psiphon-core.exe',
    );
    for (final pid in killed) {
      sink.writeln(
        '[ember] killed orphaned psiphon-core.exe (pid $pid) left '
        'over from a previous run',
      );
    }
  }

  /// Watches core output for a bind failure of the local proxies,
  /// so the run can fail fast with the specific ports-busy message
  /// instead of the generic 15 s timeout.
  void _scanForBindFailure(String text) {
    if (_bindFailed) return;
    if (text.contains('already in use') ||
        text.contains('Only one usage of each socket address')) {
      _bindFailed = true;
      _lastError = portsBusyMessage;
    }
  }

  /// One stderr line from the core: a JSON notice, tee'd to the log
  /// (the controller's log viewer reads psiphon.log, as on Android).
  /// Non-notice stderr text (a Go panic dump, say) is logged the
  /// same way and simply fails the decode below.
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
        _listening = true;
      case 'Tunnels':
        final count = (data['count'] as num?)?.toInt() ?? 0;
        _connected = count >= 1;
        if (_connected && _sinceMs == 0) {
          _sinceMs = DateTime.now().millisecondsSinceEpoch;
        }
        if (!_connected) _sinceMs = 0;
      case 'AvailableEgressRegions':
        _regions =
            ((data['regions'] as List?) ?? []).map((e) => e.toString()).toList();
      case 'ClientRegion':
        _region = data['region'] as String? ?? '';
      case 'ClientAddress':
        _clientAddress = data['address'] as String? ?? '';
      case 'BytesTransferred':
        _up += (data['sent'] as num?)?.toInt() ?? 0;
        _down += (data['received'] as num?)?.toInt() ?? 0;
    }
  }

  @override
  Future<void> stop() async {
    final bridge = _bridge;
    _bridge = null;
    if (bridge != null) await bridge.stop();
    final proc = _proc;
    _proc = null;
    if (proc != null) {
      proc.kill();
      try {
        await proc.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        // Already gone, or not waiting longer.
      }
    }
    _listening = false;
    _connected = false;
    await _closeLog();
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

  @override
  Future<PsiphonState> state() async {
    if (_proc == null || !_listening) {
      if (_lastError.isEmpty) return PsiphonState.stopped;
      // Stopped, but with the reason attached.
      return PsiphonState(
        running: false,
        connected: false,
        vpnMode: _vpnMode,
        sinceMs: 0,
        upBytes: _up,
        downBytes: _down,
        region: '',
        clientAddress: '',
        regions: const [],
        lastError: _lastError,
      );
    }
    return PsiphonState(
      running: true,
      connected: _connected,
      vpnMode: _vpnMode,
      sinceMs: _sinceMs,
      upBytes: _up,
      downBytes: _down,
      region: _region,
      clientAddress: _clientAddress,
      regions: _regions,
      lastError: _lastError,
    );
  }

  @override
  Future<Map<String, String>?> exitInfo() async {
    if (!_connected) return null;
    // A whole GET through the tunnel's own HTTP proxy (dart:io's
    // PROXY line — its findProxy has no SOCKS form; see the Xray
    // backend's library doc).
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
}
