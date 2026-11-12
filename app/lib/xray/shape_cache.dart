/// The winning-shape cache (build 2029A, after the
/// Alan-RIP-Dpi audit's winner caching): remembers, per
/// profile AND per network, which connection shape last
/// proved itself — where "proved" means it survived the
/// endurance qualification (real requests at connect, +2.5 s
/// and +5.4 s on one keep-alive connection), not merely that
/// it answered once. Connect fast-resumes the cached shape
/// without re-running the funnel; the watchdog persists a new
/// winner here when a rotation proves out.
///
/// The network fingerprint is the connectivity type plus a
/// hash of the carrier / Wi-Fi identity: a shape that wins on
/// home Wi-Fi says nothing about the SIM's filter, and the
/// cache must not carry the verdict across.
///
/// Storage is deliberately forgiving (the device-state rule):
/// a corrupt entry is skipped, never fatal, and a win older
/// than [maxAgeMs] is treated as absent — filters change, and
/// a stale winner must not pin a profile to a dead shape.

class ShapeWin {
  const ShapeWin({
    required this.shapeId,
    required this.verifiedMs,
    required this.rttMs,
  });

  final String shapeId;

  /// When the shape last proved itself (epoch ms).
  final int verifiedMs;

  /// The delay measured when it won (ms).
  final int rttMs;

  Map<String, dynamic> toJson() => {
    'shape': shapeId,
    'at': verifiedMs,
    'rtt': rttMs,
  };

  /// Null for anything that is not a well-formed win — a
  /// corrupt entry reads as "no win", never as a crash.
  static ShapeWin? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final shape = raw['shape'];
    final at = raw['at'];
    final rtt = raw['rtt'];
    if (shape is! String || shape.isEmpty) return null;
    if (at is! num || rtt is! num) return null;
    return ShapeWin(
      shapeId: shape,
      verifiedMs: at.toInt(),
      rttMs: rtt.toInt(),
    );
  }
}

class WinningShapeCache {
  WinningShapeCache([Map<String, ShapeWin>? wins])
    : _wins = wins ?? <String, ShapeWin>{};

  final Map<String, ShapeWin> _wins;

  /// A win is trusted for a week.
  static const maxAgeMs = 7 * 24 * 3600 * 1000;

  static String keyOf(String profileId, String networkFingerprint) =>
      '$profileId|$networkFingerprint';

  int get length => _wins.length;

  /// The cached winner for (profile, network), or null when
  /// there is none, it is stale, or the fingerprint is unknown
  /// (an unknown network never inherits another network's win).
  ShapeWin? lookup(
    String profileId,
    String networkFingerprint, {
    int? nowMs,
  }) {
    if (networkFingerprint.isEmpty) return null;
    final win = _wins[keyOf(profileId, networkFingerprint)];
    if (win == null) return null;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (now - win.verifiedMs > maxAgeMs) return null;
    return win;
  }

  void record(
    String profileId,
    String networkFingerprint,
    String shapeId,
    int rttMs, {
    int? nowMs,
  }) {
    if (networkFingerprint.isEmpty) return;
    _wins[keyOf(profileId, networkFingerprint)] = ShapeWin(
      shapeId: shapeId,
      verifiedMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      rttMs: rttMs,
    );
  }

  void forget(String profileId, String networkFingerprint) {
    _wins.remove(keyOf(profileId, networkFingerprint));
  }

  Map<String, dynamic> toJson() => {
    for (final e in _wins.entries) e.key: e.value.toJson(),
  };

  /// Reads a stored cache document. Every entry is validated
  /// on its own; corrupt entries are dropped, and a wholly
  /// corrupt document reads as an empty cache.
  factory WinningShapeCache.fromJson(Object? raw) {
    final wins = <String, ShapeWin>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        final win = ShapeWin.fromJson(e.value);
        if (win != null && e.key is String) wins[e.key as String] = win;
      }
    }
    return WinningShapeCache(wins);
  }
}

/// A small deterministic hash (FNV-1a 32) for fingerprint
/// material that should not be stored verbatim (carrier and
/// network names): stable across runs, no crypto dependency.
String fingerprintHash(String material) {
  var hash = 0x811c9dc5;
  for (final unit in material.codeUnits) {
    hash ^= unit & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// The network fingerprint the cache keys on, from the
/// platform's {type, operator} reading: connectivity type +
/// hashed operator/network identity. '' when the platform
/// could not say (the cache then simply does not engage).
String networkFingerprintOf(Map<String, String>? platform) {
  if (platform == null) return '';
  final type = platform['type'] ?? '';
  if (type.isEmpty || type == 'none') return '';
  final identity = platform['operator'] ?? '';
  return identity.isEmpty ? type : '$type:${fingerprintHash(identity)}';
}
