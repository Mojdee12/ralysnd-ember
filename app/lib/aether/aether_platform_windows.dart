/// The Aether engines on Windows (build 2032 contract, ported
/// from AetherCore.kt): the SAME Rust aether binary Android
/// stages as libaether.so, built for Windows as the
/// `aether\aether.exe` sidecar. Everything the Kotlin shim owns
/// is re-implemented here in Dart, faithfully:
///
/// - two slots (cfwarp SOCKS 20870, identity dir `cfwarp`;
///   masque SOCKS 20810, identity dir `aether-ralysnd`), each
///   spawned with the AETHER_* environment of AetherCore's
///   buildEnv, stdin closed, stdout parsed line by line;
/// - the stage vocabulary: AetherStageParser's regex rules,
///   progress ranks and regression signals, ported rule for
///   rule, plus its detail extraction (server / rtt / profile),
///   probe-failure counting and panic detection;
/// - the registration ladder for ensureIdentity (ECH rungs
///   udp → doh → tcp, then plain; 35 s per rung is the binary's
///   own budget inside each --register run, 180 s total here);
/// - identity checks against the same toml files and regexes;
/// - the Cloudflare trace through the slot's SOCKS (a small
///   SOCKS5 client in this file — dart:io has no SOCKS proxy);
/// - system capture via the tree's own TunBridge (the
///   socksTunSetOn counterpart), reported through tunState.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/core_api.dart';
import '../core/tun_bridge.dart';
import 'aether_platform.dart';

enum _Stage {
  idle,
  starting,
  identity,
  quickcheck,
  scan,
  selected,
  handshake,
  tunnel,
  validate,
  connected,
  reconnecting,
  stopped,
  failed,
  crashed,
}

extension on _Stage {
  String get wire => name;
  int get progressRank => switch (this) {
    _Stage.starting => 0,
    _Stage.identity => 1,
    _Stage.quickcheck => 2,
    _Stage.scan => 3,
    _Stage.selected => 4,
    _Stage.handshake => 5,
    _Stage.tunnel => 6,
    _Stage.validate => 7,
    _Stage.connected => 8,
    _ => -1,
  };
  bool get isRegression =>
      this == _Stage.reconnecting ||
      this == _Stage.failed ||
      this == _Stage.crashed ||
      this == _Stage.stopped;
  String get label => switch (this) {
    _Stage.idle => 'Off',
    _Stage.starting => 'Starting the engine',
    _Stage.identity => 'Identity',
    _Stage.quickcheck => 'Checking the previous server',
    _Stage.scan => 'Scanning for a server',
    _Stage.selected => 'Server selected',
    _Stage.handshake => 'Handshake',
    _Stage.tunnel => 'Establishing the tunnel',
    _Stage.validate => 'Validating data flow',
    _Stage.connected => 'Connected',
    _Stage.reconnecting => 'Dropped — reconnecting',
    _Stage.stopped => 'Stopped',
    _Stage.failed => 'Failed',
    _Stage.crashed => 'Engine crashed',
  };
}

class _Rule {
  const _Rule(this.pattern, this.stage);
  final String pattern;
  final _Stage stage;
  RegExp get re => RegExp(pattern, caseSensitive: false);
}

/// AetherStageParser's STAGE_RULES, in order (first match wins).
const _stageRules = <_Rule>[
  _Rule(r'no (warp|masque) identity found|provisioning dedicated', _Stage.identity),
  _Rule(r'enrolling masque key', _Stage.identity),
  _Rule(r'loaded existing (warp|masque) identity', _Stage.identity),
  _Rule(r'identity ready: device=(\S+)', _Stage.identity),
  _Rule(r'verifying cached gateway|verifying cached wireguard endpoint', _Stage.quickcheck),
  _Rule(r'cached (gateway|endpoint) .* still works', _Stage.quickcheck),
  _Rule(r'cached (gateway|endpoint) .* no longer works', _Stage.scan),
  _Rule(r'candidate ok (\S+):(\d+)', _Stage.scan),
  _Rule(r'hunting for a working masque gateway', _Stage.scan),
  _Rule(r'hunting for a working wireguard endpoint', _Stage.scan),
  _Rule(r'selected masque gateway (\S+):(\d+)', _Stage.selected),
  _Rule(r'selected wireguard endpoint (\S+):(\d+)', _Stage.selected),
  _Rule(r'using forced peer', _Stage.selected),
  _Rule(r'using cloudflare edge', _Stage.selected),
  _Rule(r'confirming wireguard handshake', _Stage.handshake),
  _Rule(r'handshake successful', _Stage.handshake),
  _Rule(r'establishing outer warp tunnel', _Stage.handshake),
  _Rule(r'establishing inner warp tunnel', _Stage.handshake),
  _Rule(r'masque transport: http/3', _Stage.tunnel),
  _Rule(r'masque transport: http/2', _Stage.tunnel),
  _Rule(r'validating masque data-plane', _Stage.validate),
  _Rule(r'masque tunnel validated', _Stage.validate),
  _Rule(r'inner endpoint tunneled through outer warp', _Stage.handshake),
  _Rule(r'socks5 (server )?listening on', _Stage.connected),
  _Rule(r'tunnel (closed|ended|exited).*(reconnect)', _Stage.reconnecting),
  _Rule(r'no usable masque gateway found', _Stage.scan),
  _Rule(r'found no data-plane endpoint.*trying next profile', _Stage.scan),
  _Rule(r'prober: no clean endpoint found|no clean endpoint found', _Stage.failed),
  _Rule(r'handshake failed', _Stage.failed),
  _Rule(r'no valid data from peer|tunnel considered dead|wireguard tunnel stale', _Stage.reconnecting),
  _Rule(r'no usable.*endpoint found', _Stage.scan),
  _Rule(r'last known-good .* no longer responds|rescanning|scanning fresh', _Stage.scan),
  _Rule(r'tunnel (closed|ended|exited)', _Stage.reconnecting),
];

final _noiseRe = RegExp(
  r'\] (junk(\[\d+\]|_after\[\d+\])? sent|signature i\d sent|sending \d+ junk|obfuscation pre-handshake complete|verify recv \d+ bytes|recv \d+ bytes (from|type=)|tls verification: )',
);
final _probeFailRe = RegExp(r'\b(?:h2 )?probe \S+ -> (.+)$', caseSensitive: false);
final _panicRe = RegExp(r'panicked at|stack backtrace|RUST_BACKTRACE', caseSensitive: false);

class _Slot {
  _Slot(this.id, this.socksPort, this.dirName);
  final String id;
  final int socksPort;
  final String dirName;

  Process? process;
  bool running = false;
  bool stopping = false;
  _Stage stage = _Stage.idle;
  String stageLabel = '';
  String server = '';
  String rtt = '';
  String profile = '';
  String lastError = '';
  int startedAtMs = 0;
  final List<String> logRing = [];
  final Map<String, int> probeReasons = {};

  Directory get dir {
    final d = Directory('${CoreLocator.dataDir(const [])}/$dirName');
    d.createSync(recursive: true);
    return d;
  }

  File get pidFile => File('${dir.path}/core.pid');

  void log(String line) {
    logRing.add(line);
    while (logRing.length > 400) logRing.removeAt(0);
  }

  bool get identityPresent {
    final d = dir;
    for (final name in ['tunnel.toml', 'tunnel-masque.toml', 'aether.toml']) {
      final f = File('${d.path}/$name');
      if (f.existsSync() && f.lengthSync() > 0) {
        try {
          if (f.readAsStringSync().contains('device_id')) return true;
        } catch (_) {}
      }
    }
    return false;
  }

  bool identityValid(bool masque) {
    final d = dir;
    bool has(String file, String pattern) {
      final f = File('${d.path}/$file');
      if (!f.existsSync()) return false;
      try {
        return RegExp(pattern, multiLine: true).hasMatch(f.readAsStringSync());
      } catch (_) {
        return false;
      }
    }

    final wgOk =
        has('tunnel.toml', r'^device_id = "\S+"') &&
        has('tunnel.toml', r'^wg_private_key = "\S+"');
    if (!masque) return wgOk;
    return has('tunnel-masque.toml', r'^device_id = "\S+"') &&
        has('tunnel-masque.toml', r'^cert_pem = "{1,3}\s*-----BEGIN');
  }
}

class WindowsAetherBackend {
  final _slots = <String, _Slot>{
    'cfwarp': _Slot('cfwarp', AetherPlatform.cfwarpSocksPort, 'cfwarp'),
    'masque': _Slot('masque', AetherPlatform.masqueSocksPort, 'aether-ralysnd'),
  };

  TunBridge? _bridge;
  String _tunName = '';
  int _tunSinceMs = 0;

  static String get _coreExe {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    return '$dir${sep}aether${sep}aether.exe';
  }

  _Slot _slot(String engine) => _slots[engine] ?? _slots['masque']!;

  Map<String, String> _buildEnv(_Slot slot, Directory dir, AetherOptions o) {
    final env = <String, String>{
      ...Platform.environment,
      'RUST_BACKTRACE': '1',
      'RUST_LOG': 'info,aether::prober=trace',
      'AETHER_SOCKS': '127.0.0.1:${slot.socksPort}',
      'AETHER_PROTOCOL': o.protocol,
      'AETHER_SCAN': o.scan,
      'AETHER_IP': o.ip,
      'AETHER_QUICK_RECONNECT': (o.peer == null || o.peer!.isEmpty) ? '1' : '0',
      'AETHER_CONFIG': '${dir.path}/aether.toml',
      'AETHER_NOIZE': o.noize.isNotEmpty
          ? o.noize
          : (o.protocol == 'masque' ? 'firewall' : 'balanced'),
      'HOME': dir.path,
      'TMPDIR': dir.path,
    };
    if (o.protocol == 'masque' || o.protocol == 'gool') {
      env['AETHER_MASQUE_HTTP2'] = o.transport == 'h2' ? '1' : '0';
      if (o.fragment) env['AETHER_MASQUE_H2_FRAGMENT'] = '1';
    }
    if (o.protocol == 'wg' || o.protocol == 'gool') {
      env['AETHER_WG_KEEPALIVE'] =
          '${o.keepalive.clamp(5, 120)}';
      env['AETHER_WG_STALE_SECS'] = '120';
    }
    if (o.peer != null && o.peer!.isNotEmpty) {
      env['AETHER_PEER'] = o.peer!;
      env['AETHER_WG_PEER'] = o.peer!;
    }
    return env;
  }

  Future<bool> start(String engine, AetherOptions options) async {
    final slot = _slot(engine);
    await stop(engine);
    await _reapOrphan(slot);
    if (!File(_coreExe).existsSync()) {
      slot.stage = _Stage.failed;
      slot.lastError = 'the Aether core is missing from this build';
      return false;
    }
    final dir = slot.dir;
    try {
      final p = await Process.start(
        _coreExe,
        const [],
        workingDirectory: dir.path,
        environment: _buildEnv(slot, dir, options),
      );
      slot.process = p;
      slot.running = true;
      slot.stopping = false;
      slot.stage = _Stage.starting;
      slot.stageLabel = _Stage.starting.label;
      slot.server = '';
      slot.rtt = '';
      slot.profile = '';
      slot.lastError = '';
      slot.probeReasons.clear();
      slot.startedAtMs = DateTime.now().millisecondsSinceEpoch;
      try {
        await slot.pidFile.writeAsString('${p.pid}');
      } catch (_) {}
      slot.log(
        'engine started (protocol ${options.protocol}, scan ${options.scan})',
      );
      unawaited(_drain(slot, p));
      return true;
    } catch (e) {
      slot.running = false;
      slot.stage = _Stage.failed;
      slot.lastError = 'the engine could not start: $e';
      return false;
    }
  }

  Future<void> _drain(_Slot slot, Process p) async {
    try {
      await for (final line
          in p.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        _handleLine(slot, line);
      }
    } catch (_) {}
    final code = await p.exitCode;
    if (identical(slot.process, p)) {
      slot.process = null;
      slot.running = false;
      try {
        await slot.pidFile.delete();
      } catch (_) {}
      if (!slot.stopping) {
        slot.stage = _Stage.crashed;
        slot.stageLabel = 'Engine exited (code $code)';
        slot.lastError = 'the engine exited on its own (code $code)';
        slot.log('engine exited on its own (code $code)');
      } else {
        slot.stage = _Stage.stopped;
        slot.stageLabel = _Stage.stopped.label;
      }
    }
  }

  void _handleLine(_Slot slot, String line) {
    if (_noiseRe.hasMatch(line)) return;
    final probe = _probeFailRe.firstMatch(line);
    if (probe != null) {
      final reason = probe.group(1)!.trim();
      final trimmed = reason.length > 80 ? reason.substring(0, 80) : reason;
      slot.probeReasons[trimmed] = (slot.probeReasons[trimmed] ?? 0) + 1;
      return;
    }
    slot.log(line.length > 300 ? line.substring(0, 300) : line);
    if (_panicRe.hasMatch(line)) {
      slot.lastError = 'the engine reported a panic — see the log';
    }
    // Detail extraction (AetherStageParser.extractDetail).
    final selected = RegExp(
      r'selected (?:MASQUE gateway|WireGuard endpoint) (\S+?):(\d+)(?:.*rtt ([^)]+))?',
      caseSensitive: false,
    ).firstMatch(line);
    if (selected != null) {
      slot.server = '${selected.group(1)}:${selected.group(2)}';
      final r = selected.group(3);
      if (r != null && r.isNotEmpty) slot.rtt = r;
    }
    final edge = RegExp(
      r'using cloudflare edge (\S+)',
      caseSensitive: false,
    ).firstMatch(line);
    if (edge != null) slot.server = edge.group(1)!;
    final prof = RegExp(
      r'obfuscation profile: (\S+)|aethernoize (?:primary )?profile: (\S+)',
      caseSensitive: false,
    ).firstMatch(line);
    if (prof != null) {
      slot.profile = prof.group(1) ?? prof.group(2) ?? slot.profile;
    }
    for (final rule in _stageRules) {
      if (rule.re.hasMatch(line)) {
        final next = rule.stage;
        final cur = slot.stage;
        if (next.isRegression || next.progressRank >= cur.progressRank || cur.progressRank < 0) {
          slot.stage = next;
          slot.stageLabel = next.label;
        }
        break;
      }
    }
  }

  Future<void> stop(String engine) async {
    final slot = _slot(engine);
    final p = slot.process;
    if (p == null) {
      slot.running = false;
      if (slot.stage != _Stage.failed && slot.stage != _Stage.crashed) {
        slot.stage = _Stage.idle;
      }
      return;
    }
    slot.stopping = true;
    slot.process = null;
    slot.running = false;
    slot.stage = _Stage.stopped;
    slot.stageLabel = _Stage.stopped.label;
    p.kill();
    try {
      await p.exitCode.timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      p.kill(ProcessSignal.sigkill);
    }
  }

  Future<void> _reapOrphan(_Slot slot) async {
    final file = slot.pidFile;
    try {
      if (!file.existsSync()) return;
      final pid = int.tryParse((await file.readAsString()).trim());
      if (pid == null) return;
      final result = await Process.run('tasklist', [
        '/FI',
        'PID eq $pid',
        '/FO',
        'CSV',
        '/NH',
      ]);
      if ('${result.stdout}'.contains('aether.exe')) {
        await Process.run('taskkill', ['/PID', '$pid', '/F']);
        slot.log('reaped orphan core pid $pid');
      }
    } catch (_) {
      // No orphan, or it is already gone.
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  AetherState state(String engine) {
    final slot = _slot(engine);
    var topReason = '';
    var topCount = 0;
    slot.probeReasons.forEach((k, v) {
      if (v > topCount) {
        topCount = v;
        topReason = k;
      }
    });
    return AetherState(
      engine: slot.id,
      running: slot.running,
      stage: slot.stage.wire,
      stageLabel: slot.stageLabel,
      connected: slot.running && slot.stage == _Stage.connected,
      server: slot.server,
      rtt: slot.rtt,
      profile: slot.profile,
      socksPort: slot.socksPort,
      sinceMs: slot.startedAtMs,
      error: slot.lastError,
      identity: slot.identityPresent,
      probeTopReason: topCount == 0 ? '' : '$topReason ×$topCount',
      log: slot.logRing
          .skip(slot.logRing.length > 60 ? slot.logRing.length - 60 : 0)
          .join('\n'),
    );
  }

  /// The registration ladder (AetherCore.ensureIdentity):
  /// ECH rungs udp → doh → tcp, then plain; a remembered rung
  /// (in a small file beside the identity — the SharedPreferences
  /// counterpart) goes first. 180 s total budget.
  Future<String> ensureIdentity(String engine, String protocol) async {
    final slot = _slot(engine);
    final masque = protocol == 'masque' || protocol == 'gool';
    if (slot.identityValid(masque)) return 'identity present';
    final which = protocol == 'wg'
        ? 'wg'
        : protocol == 'gool'
        ? 'gool'
        : 'masque';
    final rungs = <(String, String?)>[
      ('ech-udp', 'udp://1.1.1.1'),
      ('ech-doh', 'https://1.1.1.1/dns-query'),
      ('ech-tcp', 'tcp://8.8.8.8'),
      ('plain', null),
    ];
    final rungFile = File('${slot.dir.path}/rung.txt');
    String? remembered;
    try {
      remembered = (await rungFile.readAsString()).trim();
    } catch (_) {}
    final ordered = <(String, String?)>[
      if (remembered != null)
        ...rungs.where((r) => r.$1 == remembered),
      ...rungs,
    ].toSet().toList();
    final started = DateTime.now();
    for (final rung in ordered) {
      if (DateTime.now().difference(started).inSeconds > 180) break;
      if (await _runRegister(slot, which, rung)) {
        if (slot.identityValid(masque)) {
          try {
            await rungFile.writeAsString(rung.$1);
          } catch (_) {}
          slot.log('identity made (${rung.$1})');
          return 'identity made (${rung.$1})';
        }
      }
      if (rung.$1 == remembered) {
        try {
          await rungFile.delete();
        } catch (_) {}
      }
    }
    return 'identity could not be made on this network';
  }

  Future<bool> _runRegister(
    _Slot slot,
    String which,
    (String, String?) rung,
  ) async {
    final dir = slot.dir;
    if (!File(_coreExe).existsSync()) return false;
    final config = '${dir.path}/tunnel.toml';
    final args = <String>[
      '--register',
      which,
      '--config',
      config,
      '--wg-config',
      config,
      '--masque-config',
      '${dir.path}/tunnel-masque.toml',
      if (rung.$2 != null) ...['--ech', 'auto', '--ech-dns', rung.$2!],
      '--log-level',
      'info',
    ];
    try {
      final p = await Process.start(
        _coreExe,
        args,
        workingDirectory: dir.path,
        environment: {...Platform.environment, 'HOME': dir.path, 'TMPDIR': dir.path},
      );
      unawaited(
        p.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach(
          (line) => slot.log(line.length > 300 ? line.substring(0, 300) : line),
        ),
      );
      await p.exitCode.timeout(const Duration(seconds: 120));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> resetIdentity(String engine) async {
    final slot = _slot(engine);
    await stop(engine);
    final dir = slot.dir;
    for (final f in dir.listSync()) {
      if (f is File && f.path.endsWith('.toml')) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    slot.log('identity cleared');
  }

  /// One Cloudflare trace through the slot's SOCKS (the connect
  /// proof and the exit card). Null on failure.
  Future<Map<String, String>?> trace(String engine) async {
    final slot = _slot(engine);
    try {
      final body = await _socksHttpGet(
        slot.socksPort,
        'www.cloudflare.com',
        '/cdn-cgi/trace',
      );
      if (body == null) return null;
      final out = <String, String>{};
      for (final line in body.split('\n')) {
        final i = line.indexOf('=');
        if (i > 0) out[line.substring(0, i).trim()] = line.substring(i + 1).trim();
      }
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  /// A minimal SOCKS5 client: CONNECT to [host]:443 through the
  /// proxy on [socksPort], upgrade to TLS, one HTTP/1.1 GET.
  Future<String?> _socksHttpGet(
    int socksPort,
    String host,
    String path,
  ) async {
    final socket = await Socket.connect(
      '127.0.0.1',
      socksPort,
      timeout: const Duration(seconds: 8),
    );
    final buffer = <int>[];
    final completer = <Completer<void>>[];
    late StreamSubscription<List<int>> sub;
    Future<void> need(int n) async {
      while (buffer.length < n) {
        final c = Completer<void>();
        completer.add(c);
        await c.future.timeout(const Duration(seconds: 8));
      }
    }

    sub = socket.listen((chunk) {
      buffer.addAll(chunk);
      for (final c in completer) {
        if (!c.isCompleted) c.complete();
      }
      completer.clear();
    });
    try {
      socket.add([5, 1, 0]);
      await socket.flush();
      await need(2);
      if (buffer[0] != 5 || buffer[1] != 0) return null;
      buffer.clear();
      final hostBytes = utf8.encode(host);
      socket.add([5, 1, 0, 3, hostBytes.length, ...hostBytes, 0, 443]);
      await socket.flush();
      await need(4);
      if (buffer[0] != 5 || buffer[1] != 0) return null;
      await sub.cancel();
      final secure = await SecureSocket.secure(
        socket,
        host: host,
      ).timeout(const Duration(seconds: 8));
      secure.write(
        'GET $path HTTP/1.1\r\nHost: $host\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n',
      );
      await secure.flush();
      final bytes = await secure
          .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk))
          .timeout(const Duration(seconds: 8));
      final text = utf8.decode(bytes, allowMalformed: true);
      final split = text.indexOf('\r\n\r\n');
      return split < 0 ? text : text.substring(split + 4);
    } catch (_) {
      return null;
    } finally {
      try {
        socket.destroy();
      } catch (_) {}
    }
  }

  /// socksTunSetOn's Windows counterpart: system capture via
  /// the tree's TunBridge against the slot's SOCKS.
  Future<void> setTun({
    required bool on,
    required String name,
    required int socksPort,
    required String engine,
  }) async {
    if (!on) {
      final bridge = _bridge;
      _bridge = null;
      _tunSinceMs = 0;
      if (bridge != null) await bridge.stop();
      return;
    }
    final dir = _slot(engine).dir;
    final sink = File('${dir.path}/tun.log').openWrite(mode: FileMode.append);
    _bridge = await TunBridge.start(
      socksPort: socksPort,
      skipProgram: 'aether.exe',
      log: sink,
      logDir: dir,
    );
    _tunName = name;
    _tunSinceMs = DateTime.now().millisecondsSinceEpoch;
    final bridge = _bridge!;
    unawaited(bridge.down.then((_) {
      if (identical(_bridge, bridge)) {
        _bridge = null;
        _tunSinceMs = 0;
      }
    }));
  }

  Map<String, dynamic> tunState() {
    final up = _bridge != null && _tunSinceMs != 0;
    return {
      'running': up,
      'name': up ? _tunName : '',
      'sinceMs': up ? _tunSinceMs : 0,
      'up': 0,
      'down': 0,
    };
  }
}
