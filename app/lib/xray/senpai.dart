/// The Senpai scanner's Dart side (build 2129, Leg 3):
/// the request model for the vendored SenPaiScanner bridge
/// binary (see SenpaiCore.kt for the wire contract), the
/// polled state/rows, and the import of top results into
/// the Xray profile store.
///
/// The scanner is a DPI Lab tool: it is reachable only
/// inside the Lab (XraySettings.dpiLabEnabled) behind its
/// own default-OFF toggle (XraySettings.senpaiEnabled).
/// Nothing here runs unless the owner turns both on and
/// presses Start.
///
/// Import honesty (delta §3(c)): the scanner embeds its
/// own Xray, a different version from Ember's — a result
/// the scanner measured is a CANDIDATE, not a verdict.
/// Imported candidates land as ordinary profiles through
/// the existing link import path (a picked template
/// profile re-addressed to the scanned endpoint, serialized
/// back to a share link and fed to importLinks), and the
/// page runs Ember's own testDelay over them before any
/// is presented as working. Importing never connects.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../atomic_json_store.dart';
import 'senpai_defaults.dart';

/// The scan request, with LML's own UI defaults and the
/// bridge's bounds (ScannerBridge.normalize): count
/// 1..20000, workers 1..200, timeoutMs 1000..60000, ports
/// 1..6 unique, topN 0..20000, speedKb 128..10240,
/// minSpeed 0..1000.
class SenpaiRequest {
  SenpaiRequest({
    this.count = 1000,
    this.workers = 50,
    this.timeoutMs = 5000,
    this.ports = const [443],
    this.targets = '',
    this.gentle = false,
    this.requireWS = false,
    this.neighborScan = false,
    this.directOnly = false,
    this.topN = 20,
    this.speedKb = 512,
    this.minSpeed = 0,
    this.antiDpiEnabled = false,
    this.finalmask = '',
    this.fingerprint = '',
    this.alpn = '',
    this.cipherSuites = '',
  });

  int count;
  int workers;
  int timeoutMs;
  List<int> ports;
  String targets;
  bool gentle;
  bool requireWS;
  bool neighborScan;
  bool directOnly;
  int topN;

  /// The direct-speed sample size, in KiB (the wire field
  /// is speedSize, in bytes).
  int speedKb;
  double minSpeed;

  bool antiDpiEnabled;

  /// Empty = the bridge defaults (senpai_defaults.dart).
  String finalmask;
  String fingerprint;
  String alpn;
  String cipherSuites;

  static int _clamp(int v, int lo, int hi) =>
      v < lo ? lo : (v > hi ? hi : v);

  /// The normalized request map for [action]
  /// ('scan' | 'resume' | 'speed'), shaped exactly as the
  /// bridge expects: bounds clamped the way LML's
  /// normalize clamps them, ports deduplicated, the
  /// anti-DPI defaults substituted for empty fields, and
  /// speedSize in bytes.
  Map<String, dynamic> toWire(String action) {
    final seen = <int>{};
    final wirePorts = <int>[
      for (final p in ports)
        if (p >= 1 && p <= 65535 && seen.add(p)) p,
    ];
    return {
      'action': action,
      'count': _clamp(count, 1, 20000),
      'workers': _clamp(workers, 1, 200),
      'timeoutMs': _clamp(timeoutMs, 1000, 60000),
      'ports': wirePorts.isEmpty ? const [443] : wirePorts,
      'targets': targets,
      'gentle': gentle,
      'requireWS': requireWS,
      'neighborScan': neighborScan,
      'directOnly': directOnly,
      'speedSize': _clamp(speedKb, 128, 10240) * 1024,
      'minSpeed': minSpeed < 0
          ? 0.0
          : (minSpeed > 1000 ? 1000.0 : minSpeed),
      'topN': _clamp(topN, 0, 20000),
      'antiDpi': {
        'enabled': antiDpiEnabled,
        'finalmask':
            finalmask.trim().isEmpty ? senpaiDefaultFinalmask : finalmask.trim(),
        'fingerprint':
            fingerprint.trim().isEmpty ? 'unsafe' : fingerprint.trim(),
        'alpn': alpn.trim().isEmpty ? 'http/1.1' : alpn.trim(),
        'cipherSuites': cipherSuites.trim().isEmpty
            ? senpaiDefaultCipherSuites
            : cipherSuites.trim(),
      },
    };
  }

  String toWireJson(String action) => jsonEncode(toWire(action));

  /// The 'speed' action's wire form (LML's shape): the
  /// direct-speed test runs over the previous scan's top
  /// candidates, carried in the request, with targets
  /// blanked and directOnly off.
  String speedWireJson(List<SenpaiRow> candidates) {
    final wire = toWire('speed');
    wire['targets'] = '';
    wire['directOnly'] = false;
    wire['candidates'] = [
      for (final r in candidates) {'ip': r.ip, 'port': r.port},
    ];
    return jsonEncode(wire);
  }

  Map<String, dynamic> toJson() => toWire('scan')..remove('action');

  static SenpaiRequest fromJson(Map<String, dynamic> j) {
    int num_(Object? v, int d) => v is num ? v.toInt() : d;
    bool flag(Object? v) => v is bool ? v : false;
    String str(Object? v) => v is String ? v : '';
    final anti = j['antiDpi'];
    final antiMap =
        anti is Map ? anti.cast<String, dynamic>() : const <String, dynamic>{};
    final portsRaw = j['ports'];
    return SenpaiRequest(
      count: num_(j['count'], 1000),
      workers: num_(j['workers'], 50),
      timeoutMs: num_(j['timeoutMs'], 5000),
      ports: portsRaw is List
          ? [
              for (final p in portsRaw)
                if (p is num) p.toInt(),
            ]
          : const [443],
      targets: str(j['targets']),
      gentle: flag(j['gentle']),
      requireWS: flag(j['requireWS']),
      neighborScan: flag(j['neighborScan']),
      directOnly: flag(j['directOnly']),
      topN: num_(j['topN'], 20),
      speedKb: num_(j['speedSize'], 512 * 1024) ~/ 1024,
      minSpeed: (j['minSpeed'] as num?)?.toDouble() ?? 0,
      antiDpiEnabled: flag(antiMap['enabled']),
      // The stored form keeps the owner's own text, not the
      // substituted defaults: a wire round-trip carries the
      // defaults, so map them back to empty.
      finalmask: str(antiMap['finalmask']) == senpaiDefaultFinalmask
          ? ''
          : str(antiMap['finalmask']),
      fingerprint: str(antiMap['fingerprint']) == 'unsafe'
          ? ''
          : str(antiMap['fingerprint']),
      alpn: str(antiMap['alpn']) == 'http/1.1' ? '' : str(antiMap['alpn']),
      cipherSuites:
          str(antiMap['cipherSuites']) == senpaiDefaultCipherSuites
              ? ''
              : str(antiMap['cipherSuites']),
    );
  }
}

/// One scanner result row (an answering endpoint and its
/// measurements).
class SenpaiRow {
  const SenpaiRow({
    required this.ip,
    required this.port,
    required this.latencyMs,
    required this.jitterMs,
    required this.loss,
    required this.colo,
    required this.speedTested,
    required this.speedOk,
    required this.bytesPerSecond,
  });

  final String ip;
  final int port;
  final int latencyMs;
  final int jitterMs;
  final double loss;
  final String colo;
  final bool speedTested;
  final bool speedOk;
  final double bytesPerSecond;

  String get endpoint =>
      ip.contains(':') ? '[$ip]:$port' : '$ip:$port';

  double get mbps => bytesPerSecond * 8 / 1000000;

  static SenpaiRow? fromJson(Map<String, dynamic> j) {
    final ip = j['ip'];
    final port = j['port'];
    if (ip is! String || ip.isEmpty || port is! num) return null;
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    double asDouble(Object? v) => v is num ? v.toDouble() : 0;
    return SenpaiRow(
      ip: ip,
      port: port.toInt(),
      latencyMs: asInt(j['latency']),
      jitterMs: asInt(j['jitter']),
      loss: asDouble(j['loss']),
      colo: j['colo'] is String ? j['colo'] as String : '',
      speedTested: j['speedTested'] == true,
      speedOk: j['speedOK'] == true,
      bytesPerSecond: asDouble(j['bytesPerSecond']),
    );
  }
}

/// The polled scanner state (SenpaiCore.state).
class SenpaiState {
  const SenpaiState({
    required this.available,
    required this.running,
    required this.stage,
    required this.error,
    required this.phase,
    required this.tested,
    required this.total,
    required this.healthy,
    required this.cancelled,
    required this.resumable,
    required this.workDir,
    required this.rowsTotal,
    required this.rows,
  });

  final bool available;
  final bool running;

  /// idle | starting | running | done | error
  final String stage;
  final String error;
  final int phase;
  final int tested;
  final int total;
  final int healthy;
  final bool cancelled;

  /// A saved scan-state.json exists — Resume is possible.
  final bool resumable;
  final String workDir;
  final int rowsTotal;
  final List<SenpaiRow> rows;

  static const idle = SenpaiState(
    available: false,
    running: false,
    stage: 'idle',
    error: '',
    phase: 0,
    tested: 0,
    total: 0,
    healthy: 0,
    cancelled: false,
    resumable: false,
    workDir: '',
    rowsTotal: 0,
    rows: [],
  );

  static SenpaiState fromMap(Map<String, dynamic> m) {
    List<SenpaiRow> rows = const [];
    final raw = m['rows'];
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          rows = [
            for (final e in decoded)
              if (e is Map)
                SenpaiRow.fromJson(e.cast<String, dynamic>()),
          ].whereType<SenpaiRow>().toList();
        }
      } catch (_) {
        rows = const [];
      }
    }
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    return SenpaiState(
      available: m['available'] == true,
      running: m['running'] == true,
      stage: m['stage'] is String ? m['stage'] as String : 'idle',
      error: m['error'] is String ? m['error'] as String : '',
      phase: asInt(m['phase']),
      tested: asInt(m['tested']),
      total: asInt(m['total']),
      healthy: asInt(m['healthy']),
      cancelled: m['cancelled'] == true,
      resumable: m['resumable'] == true,
      workDir: m['workDir'] is String ? m['workDir'] as String : '',
      rowsTotal: asInt(m['rowsTotal']),
      rows: rows,
    );
  }
}

/// The platform channel to SenpaiCore (the shared
/// 'app/android' channel MainActivity serves).
class SenpaiPlatform {
  static const _channel = MethodChannel('app/android');

  static Future<bool> start(String requestJson) async =>
      await _channel.invokeMethod<bool>('senpaiStart', {
        'request': requestJson,
      }) ??
      false;

  static Future<void> stop() => _channel.invokeMethod('senpaiStop');

  static Future<SenpaiState> state() async {
    final m = await _channel.invokeMapMethod<String, dynamic>('senpaiState');
    if (m == null) return SenpaiState.idle;
    return SenpaiState.fromMap(m);
  }
}

/// The last scan request, persisted in the engine work
/// dir (senpai-last-request.json — LML's prefs key
/// 'senpai-last-request' as a file, via the atomic store
/// the delta prescribes). Resume replays it with the
/// action swapped and targets blanked, exactly LML's
/// resume shape.
class SenpaiLastRequest {
  SenpaiLastRequest(this.workDir);

  final String workDir;

  AtomicJsonStore get _store =>
      AtomicJsonStore(File('$workDir/senpai-last-request.json'));

  Future<void> save(SenpaiRequest request) =>
      _store.write(request.toJson());

  Future<SenpaiRequest?> load() async {
    final doc = await _store.read();
    if (doc == null) return null;
    return SenpaiRequest.fromJson(doc);
  }
}
