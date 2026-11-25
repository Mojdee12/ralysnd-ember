/// Daily problem report (build 2149, owner expansion 4):
/// a STRUCTURED problem journal — problem events recorded
/// all day, persisted across restarts, pruned to a rolling
/// 7 days — and the day's digest the owner can read and
/// share. It EXTENDS the diagnostics story (the free-text
/// journal in diagnostics.dart stays the narrative log);
/// this is the countable, per-type record a bug hunt
/// starts from: the D1 adoption gate, for example, would
/// have surfaced here as a day of 'proof unverified'
/// events instead of a mystery.
///
/// PRIVACY, BY CONSTRUCTION: an event carries a timestamp,
/// a type, an engine label, a profile NAME, a
/// protocol/transport SHAPE, a stage and a plain reason.
/// There is no field for an address, a host, an SNI, a
/// path, a link or a credential, and the recording call
/// sites pass only constant reason strings or sanitized
/// error codes — so nothing in this file's output can
/// contain a server endpoint or a secret. A test scans the
/// serialized journal and the share text for forbidden
/// keys and planted secret values.
///
/// The whole feature is gated by
/// XraySettings.dailyProblemReport (DEFAULT OFF, the
/// features law): off means no recording, no file, no
/// digest, no badge. Nothing here touches the network;
/// the only way data leaves the device is the
/// user-initiated share sheet.
library;

import 'xray_models.dart';

/// The event taxonomy. Values are the stored strings —
/// renaming one orphans stored events, so they are frozen.
abstract final class ProblemTypes {
  static const String connectFailure = 'connectFailure';
  static const String proofUnverified = 'proofUnverified';
  static const String dnsFailure = 'dnsFailure';
  static const String handshakeTimeout = 'handshakeTimeout';
  static const String coreStartFailure = 'coreStartFailure';
  static const String previousSessionCrash = 'previousSessionCrash';
  static const String importRejection = 'importRejection';
  static const String sidecarFailure = 'sidecarFailure';
  static const String regionHopLockout = 'regionHopLockout';

  static const List<String> all = [
    connectFailure,
    proofUnverified,
    dnsFailure,
    handshakeTimeout,
    coreStartFailure,
    previousSessionCrash,
    importRejection,
    sidecarFailure,
    regionHopLockout,
  ];

  /// The plain-language label the report and the share
  /// text use for a type.
  static String label(String type) => switch (type) {
    connectFailure => 'Connect failure',
    proofUnverified => 'Adopted without proof',
    dnsFailure => 'DNS resolution failure',
    handshakeTimeout => 'Handshake timeout',
    coreStartFailure => 'Core start failure',
    previousSessionCrash => 'Previous session ended abruptly',
    importRejection => 'Import rejected',
    sidecarFailure => 'Sidecar start failure',
    regionHopLockout => 'RegionHop panel lockout',
    _ => type,
  };
}

/// One recorded problem. See the library doc for the
/// privacy contract — the field set IS the contract.
class ProblemEvent {
  const ProblemEvent({
    required this.atMs,
    required this.type,
    required this.engine,
    required this.profileName,
    required this.shape,
    required this.stage,
    required this.reason,
  });

  final int atMs;
  final String type;

  /// 'V2Ray' | 'WireGuard' | 'RegionHop' | 'Import' | …
  final String engine;

  /// The profile's display name ('' when not applicable).
  final String profileName;

  /// Protocol/transport shape, e.g. 'Trojan · ws+tls'.
  final String shape;
  final String stage;
  final String reason;

  Map<String, dynamic> toJson() => {
    'atMs': atMs,
    'type': type,
    'engine': engine,
    'profileName': profileName,
    'shape': shape,
    'stage': stage,
    'reason': reason,
  };

  factory ProblemEvent.fromJson(Map<dynamic, dynamic> j) => ProblemEvent(
    atMs: j['atMs'] is num ? (j['atMs'] as num).toInt() : 0,
    type: j['type'] as String? ?? '',
    engine: j['engine'] as String? ?? '',
    profileName: j['profileName'] as String? ?? '',
    shape: j['shape'] as String? ?? '',
    stage: j['stage'] as String? ?? '',
    reason: j['reason'] as String? ?? '',
  );

  /// 'HH:mm' in local time, the report list's time column.
  String get timeLabel {
    final t = DateTime.fromMillisecondsSinceEpoch(atMs);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }
}

/// Extracts the machine code from a connect error's text
/// ('Bad state: start-failed: …' → 'start-failed'). Only a
/// leading lowercase token of letters/digits/dashes
/// qualifies; anything else yields '' — the recorded
/// reason is built from the code alone, never from the
/// raw error text (which can carry a host or a path).
String problemCodeOf(String errorText) {
  var t = errorText.trim();
  if (t.startsWith('Bad state: ')) t = t.substring(11).trim();
  final token = t.split(RegExp(r'[:\s]')).first;
  return RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(token) ? token : '';
}

/// The protocol/transport shape an event records for a
/// profile: protocol + network + security, nothing that
/// identifies a server ('Trojan · ws+tls', 'VLESS ·
/// tcp+reality', 'WireGuard').
String problemShapeOf(Profile p) {
  final proto = switch (p.protocol) {
    Protocol.vless => 'VLESS',
    Protocol.vmess => 'VMess',
    Protocol.trojan => 'Trojan',
    Protocol.shadowsocks => 'Shadowsocks',
    Protocol.wireguard => 'WireGuard',
    Protocol.hysteria2 => 'Hysteria2',
    Protocol.tuic => 'TUIC',
    Protocol.anytls => 'AnyTLS',
    _ => p.protocol.name,
  };
  if (p.protocol == Protocol.wireguard) return proto;
  final net = p.network.isEmpty ? 'tcp' : p.network;
  final sec = p.security.isEmpty ? 'none' : p.security;
  return '$proto · $net+$sec';
}

/// The persisted journal: an ordered event list with
/// rolling 7-day retention. Pure data + (de)serialization;
/// the controller owns the file and the gate.
class ProblemJournal {
  ProblemJournal([List<ProblemEvent>? seed])
    : _events = [...?seed] {
    _events.sort((a, b) => a.atMs.compareTo(b.atMs));
  }

  final List<ProblemEvent> _events;

  /// Rolling retention: events older than 7 days are
  /// pruned on load, on record, and on the housekeeping
  /// tick.
  static const int retentionMs = 7 * 24 * 60 * 60 * 1000;

  List<ProblemEvent> get events => List.unmodifiable(_events);
  bool get isEmpty => _events.isEmpty;

  /// Appends [event] and prunes against its own timestamp.
  /// Returns true when the stored set changed beyond the
  /// append (a prune dropped something) — the caller saves
  /// either way; the flag exists for tests.
  bool record(ProblemEvent event) {
    _events.add(event);
    return prune(event.atMs);
  }

  /// Drops events older than the retention window ending
  /// at [nowMs]. Returns true when anything was dropped.
  bool prune(int nowMs) {
    final floor = nowMs - retentionMs;
    final before = _events.length;
    _events.removeWhere((e) => e.atMs < floor);
    return _events.length != before;
  }

  void clear() => _events.clear();

  static bool _sameDay(int atMs, DateTime day) {
    final t = DateTime.fromMillisecondsSinceEpoch(atMs);
    return t.year == day.year && t.month == day.month && t.day == day.day;
  }

  /// The day's events, oldest first.
  List<ProblemEvent> forDay(DateTime day) =>
      _events.where((e) => _sameDay(e.atMs, day)).toList();

  /// The day's counts by type, in taxonomy order, zero
  /// counts omitted.
  Map<String, int> countsForDay(DateTime day) {
    final counts = <String, int>{};
    for (final e in forDay(day)) {
      counts[e.type] = (counts[e.type] ?? 0) + 1;
    }
    return {
      for (final t in ProblemTypes.all)
        if (counts.containsKey(t)) t: counts[t]!,
      for (final t in counts.keys)
        if (!ProblemTypes.all.contains(t)) t: counts[t]!,
    };
  }

  int countForDay(DateTime day) => forDay(day).length;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'events': [for (final e in _events) e.toJson()],
  };

  factory ProblemJournal.fromJson(Map<dynamic, dynamic> j) {
    final raw = j['events'];
    return ProblemJournal([
      if (raw is List)
        for (final e in raw)
          if (e is Map) ProblemEvent.fromJson(e),
    ]);
  }

  /// The share payload: plain text, counts first, then the
  /// day's list. The exact shape is pinned by a test —
  /// change it deliberately, never casually.
  String digestText(DateTime day) {
    String two(int v) => v.toString().padLeft(2, '0');
    final date =
        '${day.year}-${two(day.month)}-${two(day.day)}';
    final counts = countsForDay(day);
    final list = forDay(day);
    final b = StringBuffer()
      ..writeln('Ember daily problem report — $date')
      ..writeln();
    if (list.isEmpty) {
      b.writeln('No problems recorded today.');
      return b.toString().trimRight();
    }
    for (final entry in counts.entries) {
      b.writeln('${ProblemTypes.label(entry.key)}: ${entry.value}');
    }
    b
      ..writeln()
      ..writeln('— events —');
    for (final e in list) {
      final who = e.profileName.isEmpty
          ? e.engine
          : '${e.profileName} (${e.shape})';
      final stage = e.stage.isEmpty ? '' : ' · ${e.stage}';
      b.writeln('${e.timeLabel} · $who$stage · ${e.reason}');
    }
    return b.toString().trimRight();
  }
}
