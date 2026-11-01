/// The Psiphon engine's brain: its settings (mode, exit region,
/// upstream proxy, transport limits), their persistence, and the
/// tunnel's on/off state — everything the Ember UI binds to. Mirrors
/// the Xray controller's shape so the shell arbitrates all three
/// engines the same way.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../xray/exit_info.dart';
import 'psiphon_platform.dart';

/// One selectable tunnel transport: the friendly name the UI shows
/// and the protocol value the core's LimitTunnelProtocols takes.
class PsiphonTransport {
  final String label;
  final String value;
  const PsiphonTransport(this.label, this.value);
}

/// The transports the core can be limited to (protocol.go). An empty
/// selection means the core's own automatic choice — its default and
/// the recommended setting.
const psiphonTransports = <PsiphonTransport>[
  PsiphonTransport('SSH', 'SSH'),
  PsiphonTransport('Obfuscated SSH', 'OSSH'),
  PsiphonTransport('TLS Obfuscated SSH', 'TLS-OSSH'),
  PsiphonTransport('Shadowsocks SSH', 'SHADOWSOCKS-OSSH'),
  PsiphonTransport('QUIC', 'QUIC-OSSH'),
  PsiphonTransport('Meek (fronted)', 'FRONTED-MEEK-OSSH'),
  PsiphonTransport('Meek (fronted HTTP)', 'FRONTED-MEEK-HTTP-OSSH'),
  PsiphonTransport('Meek (fronted QUIC)', 'FRONTED-MEEK-QUIC-OSSH'),
  PsiphonTransport('Meek (unfronted)', 'UNFRONTED-MEEK-OSSH'),
  PsiphonTransport('Meek (unfronted HTTPS)', 'UNFRONTED-MEEK-HTTPS-OSSH'),
  PsiphonTransport(
    'Meek (unfronted, session ticket)',
    'UNFRONTED-MEEK-SESSION-TICKET-OSSH',
  ),
  PsiphonTransport('Conjure', 'CONJURE-OSSH'),
];

/// The egress regions the core announced in this app's VM smoke test
/// (AvailableEgressRegions notice, tunnel-core v2.0.42); the live list
/// from the running core replaces it whenever the engine has run.
const psiphonFallbackRegions = <String>[
  'AT', 'AU', 'BE', 'BR', 'CA', 'CH', 'CZ', 'DE', 'DK', 'ES', 'FI',
  'FR', 'GB', 'IE', 'IN', 'IT', 'JP', 'LT', 'NL', 'NO', 'PL', 'RO',
  'RS', 'SE', 'SG', 'US',
];

class PsiphonSettings {
  /// True: the whole device through the TUN bridge. False: the core
  /// only serves its local proxies (proxy-only).
  bool vpnMode = true;

  /// The egress region code ('' = automatic: the core picks).
  String region = '';

  /// An upstream proxy URL (http://[user:pass@]host:port or
  /// socks5://...) Psiphon itself connects through; '' = direct.
  String upstream = '';

  /// LimitTunnelProtocols values; empty = automatic.
  Set<String> protocols = {};

  Map<String, dynamic> toJson() => {
        'vpnMode': vpnMode,
        'region': region,
        'upstream': upstream,
        'protocols': protocols.toList(),
      };

  static PsiphonSettings fromJson(Map<String, dynamic> j) {
    final s = PsiphonSettings();
    s.vpnMode = j['vpnMode'] as bool? ?? true;
    s.region = j['region'] as String? ?? '';
    s.upstream = j['upstream'] as String? ?? '';
    s.protocols = ((j['protocols'] as List?) ?? [])
        .map((e) => e.toString())
        .where((v) => psiphonTransports.any((t) => t.value == v))
        .toSet();
    return s;
  }
}

class PsiphonController extends ChangeNotifier {
  PsiphonSettings settings = PsiphonSettings();
  PsiphonState state = PsiphonState.stopped;
  bool connecting = false;
  int upRate = 0;
  int downRate = 0;
  String? lastError;

  /// The running tunnel's exit IP/country, looked up best-effort
  /// through the tunnel once it is up.
  ExitInfo? exitInfo;
  bool _exitFetching = false;

  /// Set by the shell: stops the other engines so only one tunnel is
  /// ever up. Returns when they are off.
  Future<void> Function()? stopOtherEngine;

  Timer? _poll;
  PsiphonState? _lastSample;
  DateTime? _lastSampleAt;

  /// The regions to offer: the core's own list once known, else the
  /// fallback captured from the core.
  List<String> get regionChoices =>
      state.regions.isNotEmpty ? state.regions : psiphonFallbackRegions;

  // ---- persistence ----------------------------------------------------

  Future<File> _stateFile() async =>
      File('${(await PsiphonPlatform.workDir()).path}/state.json');

  Future<Directory> workDir() => PsiphonPlatform.workDir();

  Future<void> load() async {
    try {
      final file = await _stateFile();
      if (await file.exists()) {
        final doc =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (doc['settings'] is Map) {
          settings = PsiphonSettings.fromJson(
            (doc['settings'] as Map).cast<String, dynamic>(),
          );
        }
      }
    } catch (_) {
      // A damaged store starts with defaults rather than crashing.
    }
    await refreshState();
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final file = await _stateFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'settings': settings.toJson()}));
    } catch (_) {
      // The choice holds in memory until the next successful save.
    }
  }

  /// Stores new settings; a running tunnel keeps its start settings
  /// until the next connect (the core reads them only at start).
  Future<void> updateSettings(PsiphonSettings next) async {
    settings = next;
    await _save();
    notifyListeners();
  }

  // ---- state ------------------------------------------------------------

  Future<void> refreshState() async {
    state = await PsiphonPlatform.state();
    if (state.running) {
      _lastSample = state;
      _lastSampleAt = DateTime.now();
      _startPolling();
      if (state.connected) _fetchExitInfo();
    }
    notifyListeners();
  }

  void _startPolling() {
    _poll ??= Timer.periodic(const Duration(seconds: 2), (_) async {
      final sample = await PsiphonPlatform.state();
      final now = DateTime.now();
      final last = _lastSample;
      final lastAt = _lastSampleAt;
      if (last != null && lastAt != null && sample.running) {
        final dt = now.difference(lastAt).inMilliseconds / 1000.0;
        if (dt > 0) {
          upRate =
              ((sample.upBytes - last.upBytes) / dt).round().clamp(0, 1 << 62);
          downRate = ((sample.downBytes - last.downBytes) / dt)
              .round()
              .clamp(0, 1 << 62);
        }
      }
      _lastSample = sample;
      _lastSampleAt = now;
      state = sample;
      if (sample.running && sample.connected) _fetchExitInfo();
      if (!sample.running) {
        _poll?.cancel();
        _poll = null;
        upRate = 0;
        downRate = 0;
        _lastSample = null;
        _lastSampleAt = null;
        exitInfo = null;
      }
      notifyListeners();
    });
  }

  void _fetchExitInfo() {
    if (_exitFetching || exitInfo != null) return;
    _exitFetching = true;
    PsiphonPlatform.exitInfo().then((m) {
      _exitFetching = false;
      if (m != null && m['ip'] != null && m['ip']!.isNotEmpty) {
        exitInfo = ExitInfo.fromMap(m);
        notifyListeners();
      }
    });
  }

  // ---- connect / disconnect ----------------------------------------------

  Future<void> connect() async {
    connecting = true;
    lastError = null;
    exitInfo = null;
    notifyListeners();
    try {
      // One tunnel at a time: the other engines go off first.
      await stopOtherEngine?.call();
      if (state.running) await disconnect();
      await PsiphonPlatform.setOn(
        vpnMode: settings.vpnMode,
        region: settings.region,
        upstream: settings.upstream.trim(),
        protocols: settings.protocols.toList(),
        dns: '1.1.1.1',
      );
      // The service reports itself once the core is up; a tunnel to a
      // Psiphon server can take a while longer (state.connected).
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        state = await PsiphonPlatform.state();
        if (state.running) break;
      }
      if (!state.running) {
        throw StateError(
          state.lastError.isNotEmpty ? state.lastError : 'start-failed',
        );
      }
      _lastSample = state;
      _lastSampleAt = DateTime.now();
      _startPolling();
    } catch (e) {
      lastError = e.toString();
      rethrow;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    await PsiphonPlatform.stop();
    for (var i = 0; i < 20; i++) {
      state = await PsiphonPlatform.state();
      if (!state.running) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    state = await PsiphonPlatform.state();
    exitInfo = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  // ---- logs ----------------------------------------------------------------

  /// The tails of the Psiphon logs, newest content last.
  Future<String> readLogs() async {
    final dir = await workDir();
    final out = StringBuffer();
    for (final name in ['psiphon.log', 'tunlink.log']) {
      final file = File('${dir.path}/$name');
      out.writeln('—— $name ——');
      try {
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final tail = bytes.length > 64 * 1024
              ? bytes.sublist(bytes.length - 64 * 1024)
              : bytes;
          out.writeln(utf8.decode(tail, allowMalformed: true));
        } else {
          out.writeln('(empty)');
        }
      } catch (e) {
        out.writeln('($e)');
      }
    }
    return out.toString();
  }

  Future<void> clearLogs() async {
    final dir = await workDir();
    for (final name in ['psiphon.log', 'tunlink.log']) {
      try {
        await File('${dir.path}/$name').writeAsString('');
      } catch (_) {
        // Not there yet.
      }
    }
  }
}
