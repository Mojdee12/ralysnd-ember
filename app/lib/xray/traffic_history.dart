/// Traffic history (build 2105): the time series behind the
/// Traffic history chart. The per-profile totals the list shows
/// were always kept (Profile.totalUpBytes/totalDownBytes); this
/// store keeps WHEN the bytes moved, as hourly buckets per
/// profile, so the chart can show a day, a week, or a month.
///
/// Recording is gated by XraySettings.trafficHistoryEnabled
/// (default OFF): the stats poll calls [record] only while the
/// toggle is on, and this store is never even loaded while it is
/// off — off, the accounting behaves exactly as before.
///
/// Storage is one JSON document (traffic-history.json in the
/// data dir) written through the shared atomic store, in the
/// same debounced rhythm as the profile stats themselves:
/// [record] only marks the store dirty; the controller's stats
/// flush points call [flush]. Buckets older than the retention
/// window (90 days) are dropped at load and at flush, so the
/// file stays bounded (at most ~2,160 buckets per profile).

import 'dart:io';

import '../atomic_json_store.dart';

/// One hour of one profile's traffic. [hourMs] is the hour's
/// start (epoch milliseconds, local hour boundary).
class TrafficBucket {
  TrafficBucket(this.hourMs, this.up, this.down);

  final int hourMs;
  int up;
  int down;

  int get total => up + down;
}

/// How far back the chart can reach: hourly buckets are kept
/// for 90 days.
const trafficHistoryRetentionMs = 90 * 24 * 60 * 60 * 1000;

int hourStartMs(int nowMs) {
  final t = DateTime.fromMillisecondsSinceEpoch(nowMs);
  return DateTime(t.year, t.month, t.day, t.hour).millisecondsSinceEpoch;
}

class TrafficHistoryStore {
  TrafficHistoryStore({this.file});

  final File? file;
  AtomicJsonStore? _store;

  /// profileId → buckets, ascending by hour.
  final Map<String, List<TrafficBucket>> _byProfile = {};
  bool _dirty = false;

  bool get dirty => _dirty;

  static Future<TrafficHistoryStore> load(String dataDir) async {
    final store = TrafficHistoryStore(
      file: File('$dataDir${Platform.pathSeparator}traffic-history.json'),
    );
    store._store = AtomicJsonStore(store.file!);
    final j = await store._store!.read();
    if (j != null) store.decode(j.cast<String, Object?>());
    return store;
  }

  /// The tolerant reader (the settings-store doctrine): only
  /// well-formed [hourMs, up, down] triples survive; anything
  /// else is dropped, never trusted into the chart.
  void decode(Map<String, Object?> j) {
    final profiles = j['profiles'];
    if (profiles is! Map) return;
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - trafficHistoryRetentionMs;
    profiles.forEach((key, value) {
      if (key is! String || value is! List) return;
      final buckets = <TrafficBucket>[];
      for (final raw in value) {
        if (raw is List && raw.length == 3) {
          final hour = raw[0], up = raw[1], down = raw[2];
          if (hour is int && up is int && down is int && hour >= cutoff) {
            buckets.add(TrafficBucket(hour, up, down));
          }
        }
      }
      buckets.sort((a, b) => a.hourMs.compareTo(b.hourMs));
      if (buckets.isNotEmpty) _byProfile[key] = buckets;
    });
  }

  Map<String, Object?> toJson() => {
    'v': 1,
    'profiles': {
      for (final e in _byProfile.entries)
        e.key: [
          for (final b in e.value) [b.hourMs, b.up, b.down],
        ],
    },
  };

  /// Adds one poll's deltas to the profile's current hour
  /// bucket. Zero deltas record nothing.
  void record(String profileId, int up, int down, int nowMs) {
    // Build 2106 (journey audit F-07): the negative clamp
    // lives at the TOP, for both branches — builds ≤2105
    // clamped only when CREATING a bucket, so a negative
    // delta added into an existing same-hour bucket could
    // drive it (and the chart/totals) negative. Both
    // producers clamp today, so this was latent; the
    // function's own contract no longer depends on them.
    if (up < 0) up = 0;
    if (down < 0) down = 0;
    if (profileId.isEmpty || (up <= 0 && down <= 0)) return;
    final hour = hourStartMs(nowMs);
    final buckets = _byProfile.putIfAbsent(profileId, () => []);
    if (buckets.isNotEmpty && buckets.last.hourMs == hour) {
      buckets.last.up += up;
      buckets.last.down += down;
    } else {
      buckets.add(TrafficBucket(hour, up, down));
    }
    _dirty = true;
  }

  /// Build 2125 (audit A25-48): drops the histories of
  /// profiles that no longer exist. Up to 2124 pruning was
  /// age-only (90 days), so a deleted profile lingered in
  /// the chart's profile picker for months. Mirrors the
  /// Lab result-book's pruneProfiles; the controller calls
  /// it when the store loads.
  void pruneProfiles(Set<String> liveProfileIds) {
    final before = _byProfile.length;
    _byProfile.removeWhere((id, _) => !liveProfileIds.contains(id));
    if (_byProfile.length != before) _dirty = true;
  }

  List<TrafficBucket> bucketsFor(String profileId) =>
      List.unmodifiable(_byProfile[profileId] ?? const []);

  /// Every profile that has any history, for the chart's
  /// profile picker.
  List<String> get profileIds => _byProfile.keys.toList()..sort();

  ({int up, int down}) totalsFor(String profileId, int sinceMs) {
    var up = 0, down = 0;
    for (final b in _byProfile[profileId] ?? const <TrafficBucket>[]) {
      if (b.hourMs >= sinceMs) {
        up += b.up;
        down += b.down;
      }
    }
    return (up: up, down: down);
  }

  /// Writes the document when dirty, dropping buckets past the
  /// retention window first. Called from the controller's stats
  /// flush points, never from [record] itself.
  Future<void> flush() async {
    if (!_dirty) return;
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - trafficHistoryRetentionMs;
    _byProfile.removeWhere((_, buckets) {
      buckets.removeWhere((b) => b.hourMs < cutoff);
      return buckets.isEmpty;
    });
    final f = file;
    if (f == null) return;
    _store ??= AtomicJsonStore(f);
    await _store!.write(toJson());
    // The dirty flag clears only on a landed write (build 2105,
    // verification iteration 1): AtomicJsonStore.write never
    // throws — it records lastWriteError — so a failed flush
    // must stay dirty or the tail is silently lost.
    _dirty = _store!.lastWriteError != null;
  }
}

/// One bar of the chart: a time window's summed traffic.
class TrafficBar {
  TrafficBar(this.startMs, this.up, this.down);

  final int startMs;
  int up;
  int down;

  int get total => up + down;
}

/// Sums [buckets] into [count] consecutive windows of
/// [windowMs] ending at the current window (the last bar is the
/// still-open window that contains [nowMs], aligned back by
/// whole windows). Windows with no traffic yield zero bars, so
/// the chart's time axis never compresses.
List<TrafficBar> trafficBars(
  List<TrafficBucket> buckets, {
  required int nowMs,
  required int windowMs,
  required int count,
}) {
  final lastStart = bucketsEpochAlign(nowMs, windowMs);
  final firstStart = lastStart - windowMs * (count - 1);
  final bars = List.generate(
    count,
    (i) => TrafficBar(firstStart + windowMs * i, 0, 0),
  );
  for (final b in buckets) {
    final idx = (b.hourMs - firstStart) ~/ windowMs;
    if (idx >= 0 && idx < count) {
      bars[idx].up += b.up;
      bars[idx].down += b.down;
    }
  }
  return bars;
}

/// Aligns [ms] down to a whole multiple of [windowMs] from the
/// local day's start, so day-sized windows begin at midnight
/// and hour-sized ones on the hour.
int bucketsEpochAlign(int ms, int windowMs) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final dayStart = DateTime(t.year, t.month, t.day).millisecondsSinceEpoch;
  return dayStart + ((ms - dayStart) ~/ windowMs) * windowMs;
}
