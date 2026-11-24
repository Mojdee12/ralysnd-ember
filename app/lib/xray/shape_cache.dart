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
    // Build 2125 (audit A25-05 / P-16): a `1e999` literal in
    // a stored document parses as double.infinity — a num,
    // but toInt() on it throws, and the throw used to abort
    // the whole store load mid-document (the sections after
    // the shape cache never decoded, and the next ordinary
    // save then persisted them empty — a silent wipe of all
    // DPI Lab data). A non-finite entry is corrupt: it reads
    // as "no win", like every other malformed entry.
    if (at is! num || rtt is! num || !at.isFinite || !rtt.isFinite) {
      return null;
    }
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

  /// Build 2125 (audit A25-46): the cache's size bound —
  /// enforced on decode and on record. Up to 2124 the
  /// cache had no cap at all, so a hostile or corrupt
  /// backup could bloat the store without limit. 256
  /// (profile × network) wins is far past any real use;
  /// excess drops oldest-verified first.
  static const maxEntries = 256;

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
    if (now - win.verifiedMs > maxAgeMs) {
      // Build 2095 (third-pass audit 6-3): an expired win
      // is DELETED, not just distrusted — expired entries
      // used to accumulate forever and ride every save.
      _wins.remove(keyOf(profileId, networkFingerprint));
      return null;
    }
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
    // Build 2095 (audit 6-3): recording prunes the expired
    // entries too, so the map stays bounded by live wins.
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    _wins.removeWhere((_, w) => now - w.verifiedMs > maxAgeMs);
    _wins[keyOf(profileId, networkFingerprint)] = ShapeWin(
      shapeId: shapeId,
      verifiedMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      rttMs: rttMs,
    );
    // Build 2125 (A25-46): the size bound, oldest first.
    while (_wins.length > maxEntries) {
      var dropKey = '';
      var dropAt = 1 << 62;
      for (final e in _wins.entries) {
        if (e.value.verifiedMs < dropAt) {
          dropKey = e.key;
          dropAt = e.value.verifiedMs;
        }
      }
      if (dropKey.isEmpty) break;
      _wins.remove(dropKey);
    }
  }

  void forget(String profileId, String networkFingerprint) {
    _wins.remove(keyOf(profileId, networkFingerprint));
  }

  /// Build 2095 (third-pass audit 7-8): forgets a profile
  /// on EVERY network — the delete/prune paths know the
  /// profile, not the networks it won on, and the old
  /// single-network forget was never called from them, so
  /// a deleted profile's wins outlived it in the store.
  void forgetProfile(String profileId) {
    _wins.removeWhere((key, _) => key.startsWith('$profileId|'));
  }

  Map<String, dynamic> toJson() => {
    for (final e in _wins.entries) e.key: e.value.toJson(),
  };

  /// Reads a stored cache document. Every entry is validated
  /// on its own; corrupt entries are dropped, and a wholly
  /// corrupt document reads as an empty cache.
  ///
  /// Build 2125 (audit A25-46): the [maxEntries] bound is
  /// enforced here too — the newest-verified wins are the
  /// ones kept.
  factory WinningShapeCache.fromJson(Object? raw) {
    final wins = <String, ShapeWin>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        final win = ShapeWin.fromJson(e.value);
        if (win != null && e.key is String) wins[e.key as String] = win;
      }
    }
    if (wins.length > maxEntries) {
      final keys = wins.keys.toList()
        ..sort((a, b) => wins[b]!.verifiedMs.compareTo(wins[a]!.verifiedMs));
      for (final k in keys.sublist(maxEntries)) {
        wins.remove(k);
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
