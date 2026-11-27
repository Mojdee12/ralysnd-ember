/// Battery usage report (build 2105): what each engine's
/// sessions cost the battery — as far as Android lets an app
/// know.
///
/// The honest limit, stated on the page itself: Android does
/// not tell an app how much battery IT used (BatteryStats
/// per-uid figures are not exposed to third-party apps without
/// special permissions Ember does not hold). What CAN be
/// measured exactly is the device's battery level when a
/// session started and when it ended. Ember runs one engine
/// at a time, so the drain inside a session's window is
/// attributed to that engine — an estimate: the screen, other
/// apps and the radios share the same window, and the page
/// says so.
///
/// Recording is gated by AppSettings.batteryReportEnabled
/// (default OFF): the shell samples the running engine every
/// few seconds only while the toggle is on, and reads the
/// battery level only at a session's edges. Off, nothing is
/// sampled, read, or stored.
///
/// The level comes from BatteryManager's capacity property
/// through the app/android channel ("batteryStatus" in
/// MainActivity). Where the device does not expose it, the
/// session is still recorded — with unknown levels, shown as
/// such rather than as zero.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../atomic_json_store.dart';
import '../../core/android_core.dart';
import 'ember_theme.dart';

/// One battery reading: [level] is the charge percent
/// (0–100), or null when the device does not expose it.
class BatteryReading {
  const BatteryReading({this.level});

  final int? level;
}

const _channel = MethodChannel('app/android');

/// Reads the current battery level, or a null-level reading
/// when the platform cannot provide one. Never throws.
Future<BatteryReading> readBatteryStatus() async {
  if (Platform.isWindows) {
    // Windows: the laptop's charge from WMI (desktops have
    // no battery — the reading stays level-less, honestly).
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Get-CimInstance Win32_Battery | Select-Object -First 1 '
            '-ExpandProperty EstimatedChargeRemaining',
      ]).timeout(const Duration(seconds: 4));
      final level = int.tryParse('${r.stdout}'.trim());
      if (level != null && level >= 0 && level <= 100) {
        return BatteryReading(level: level);
      }
    } catch (_) {
      // No battery or WMI unavailable — an unknown level.
    }
    return const BatteryReading();
  }
  try {
    // Timed: a channel read that never answers must not hold
    // the sampler's tick (and its toggle-off close) hostage
    // for the process lifetime.
    final r = await _channel
        .invokeMapMethod<String, Object?>('batteryStatus')
        .timeout(const Duration(seconds: 4));
    final level = r?['level'];
    if (level is int && level >= 0 && level <= 100) {
      return BatteryReading(level: level);
    }
    return const BatteryReading();
  } catch (_) {
    // Build 2106 (journey audit F-08): catch ALL, not only
    // Exception — a channel Error (codec/type failure)
    // escaped into the shell's unawaited sampler tick as an
    // unhandled async error instead of a skipped sample.
    // The function's contract is "never throws".
    return const BatteryReading();
  }
}

/// One finished session's battery record.
class BatterySessionRecord {
  BatterySessionRecord({
    required this.engine,
    required this.startMs,
    required this.endMs,
    this.startLevel,
    this.endLevel,
  });

  final String engine;
  final int startMs;
  final int endMs;
  final int? startLevel;
  final int? endLevel;

  int get durationMs => endMs - startMs;

  /// Percent points drained inside the window, or null when
  /// either edge is unknown. Negative (the device charged
  /// during the session) is kept as measured — the summary
  /// decides how to present it.
  int? get drained {
    final s = startLevel, e = endLevel;
    if (s == null || e == null) return null;
    return s - e;
  }

  Map<String, Object?> toJson() => {
    'engine': engine,
    'startMs': startMs,
    'endMs': endMs,
    'startLevel': ?startLevel,
    'endLevel': ?endLevel,
  };

  static BatterySessionRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final engine = raw['engine'];
    final start = raw['startMs'];
    final end = raw['endMs'];
    if (engine is! String || engine.isEmpty) return null;
    if (start is! int || end is! int || end < start) return null;
    final s = raw['startLevel'], e = raw['endLevel'];
    return BatterySessionRecord(
      engine: engine,
      startMs: start,
      endMs: end,
      startLevel: s is int && s >= 0 && s <= 100 ? s : null,
      endLevel: e is int && e >= 0 && e <= 100 ? e : null,
    );
  }
}

/// The stored records (battery-log.json in the data dir),
/// capped so the file stays small: the newest 500 sessions.
class BatteryLog {
  BatteryLog({this.file});

  final File? file;
  AtomicJsonStore? _store;
  final List<BatterySessionRecord> records = [];

  static Future<BatteryLog> load(String dataDir) async {
    final log = BatteryLog(
      file: File('$dataDir${Platform.pathSeparator}battery-log.json'),
    );
    log._store = AtomicJsonStore(log.file!);
    final j = await log._store!.read();
    if (j != null) log.decode(j.cast<String, Object?>());
    return log;
  }

  static BatteryLog? _shared;
  static Future<BatteryLog>? _sharedLoading;

  /// The app's ONE log instance: battery-log.json in the files
  /// dir (the core data dir's parent — the same root the xray
  /// store hangs its directory off). Shared between the shell's
  /// sampler and the report page (build 2105, verification
  /// iteration 1): two instances of one file meant a Clear on
  /// the page was silently undone by the shell's next write,
  /// and the page never saw sessions recorded after it opened.
  static Future<BatteryLog> loadDefault() {
    final shared = _shared;
    if (shared != null) return Future.value(shared);
    return _sharedLoading ??= () async {
      try {
        final coreDir = await AndroidCore.dataDir();
        final log = await load(File(coreDir).parent.path);
        _shared = log;
        return log;
      } catch (_) {
        // A failed load is not cached (the traffic-history
        // rule): one transient channel error must not disable
        // the report for the whole process.
        _sharedLoading = null;
        rethrow;
      }
    }();
  }

  void decode(Map<String, Object?> j) {
    final raw = j['sessions'];
    if (raw is! List) return;
    records
      ..clear()
      ..addAll([
        for (final r in raw)
          if (BatterySessionRecord.fromJson(r) case final rec?) rec,
      ]);
  }

  Map<String, Object?> toJson() => {
    'v': 1,
    'sessions': [for (final r in records) r.toJson()],
  };

  Future<void> add(BatterySessionRecord record) async {
    records.add(record);
    if (records.length > 500) {
      records.removeRange(0, records.length - 500);
    }
    final f = file;
    if (f == null) return;
    _store ??= AtomicJsonStore(f);
    await _store!.write(toJson());
  }

  /// Build 2116 (B13-3, 2105-R6): the teardown twin of
  /// [add] — the same record, written SYNCHRONOUSLY with
  /// the store's own tmp + flush + rename shape. The
  /// shell's dispose cannot await the async write, and
  /// the final session record was losable whenever the
  /// process died before the rename landed. Only the
  /// dispose path uses this; it is the last writer by
  /// construction (the sampler's timers are already
  /// cancelled when it runs).
  void addSync(BatterySessionRecord record) {
    records.add(record);
    if (records.length > 500) {
      records.removeRange(0, records.length - 500);
    }
    final f = file;
    if (f == null) return;
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(toJson()), flush: true);
    tmp.renameSync(f.path);
  }

  Future<void> clear() async {
    records.clear();
    final f = file;
    if (f == null) return;
    _store ??= AtomicJsonStore(f);
    await _store!.write(toJson());
  }
}

/// The session-edge tracker the shell's sampler drives: feed
/// it the currently-running engine's label (null when none)
/// and the current reading; it emits a finished record through
/// [onSession] when a session ends or hands over to another
/// engine. Pure and synchronous — the sampler owns the clock
/// reads and the channel reads.
class BatterySessionTracker {
  BatterySessionTracker({required this.onSession});

  final void Function(BatterySessionRecord) onSession;

  String? _engine;
  int _startMs = 0;
  int? _startLevel;

  bool get hasOpenSession => _engine != null;

  void note({
    required String? engine,
    required int nowMs,
    required BatteryReading reading,
  }) {
    if (engine == _engine) {
      // Same engine still running (or still nothing running).
      // An unknown start level stays unknown: backfilling it
      // from a later mid-session reading would store a guess
      // as a measured edge and understate the session's drain
      // by everything spent before that reading.
      return;
    }
    _close(nowMs, reading.level);
    if (engine != null) {
      _engine = engine;
      _startMs = nowMs;
      _startLevel = reading.level;
    }
  }

  /// Closes any open session (app teardown): the end level is
  /// unknown rather than guessed.
  void closeOpen(int nowMs) => _close(nowMs, null);

  /// Build 2116 (B13-3): closes any open session and
  /// RETURNS its record instead of emitting it, so the
  /// caller can persist it synchronously (the shell's
  /// dispose path — see BatteryLog.addSync). Returns null
  /// when nothing reportable was open.
  BatterySessionRecord? takeOpen(int nowMs) {
    BatterySessionRecord? taken;
    _captureOverride = (r) => taken = r;
    try {
      _close(nowMs, null);
    } finally {
      _captureOverride = null;
    }
    return taken;
  }

  /// Build 2116 (B13-3): when set, _close delivers the
  /// record here instead of [onSession] (takeOpen's
  /// capture). Null in all normal operation.
  void Function(BatterySessionRecord)? _captureOverride;

  void _close(int nowMs, int? endLevel) {
    final engine = _engine;
    if (engine == null) return;
    _engine = null;
    // Sessions shorter than 30 s are sampler noise (a toggle
    // bounce, a chain's intermediate step) — not reported.
    if (nowMs - _startMs < 30000) return;
    final record = BatterySessionRecord(
      engine: engine,
      startMs: _startMs,
      endMs: nowMs,
      startLevel: _startLevel,
      endLevel: endLevel,
    );
    (_captureOverride ?? onSession)(record);
  }
}

/// One engine's aggregated row on the report page.
class BatteryEngineSummary {
  BatteryEngineSummary({
    required this.engine,
    required this.sessions,
    required this.totalMs,
    required this.drainedPct,
    required this.measuredSessions,
    required this.measuredMs,
  });

  final String engine;
  final int sessions;
  final int totalMs;

  /// Sum of the measured sessions' drain (can be ≤ 0 when the
  /// device mostly charged during them).
  final int drainedPct;

  /// Sessions with both battery edges known.
  final int measuredSessions;

  /// The measured sessions' total duration — the only honest
  /// denominator for a drain rate.
  final int measuredMs;

  /// Percent per connected hour over MEASURED time, or null
  /// when nothing was measured. (Dividing measured drain by
  /// time that includes unmeasured sessions understates the
  /// rate by exactly the unmeasured share.)
  double? get pctPerHour {
    if (measuredSessions == 0 || measuredMs <= 0) return null;
    return drainedPct / (measuredMs / 3600000);
  }
}

List<BatteryEngineSummary> batteryEngineSummaries(
  List<BatterySessionRecord> records,
) {
  final byEngine = <String, List<BatterySessionRecord>>{};
  for (final r in records) {
    byEngine.putIfAbsent(r.engine, () => []).add(r);
  }
  final out = [
    for (final e in byEngine.entries)
      BatteryEngineSummary(
        engine: e.key,
        sessions: e.value.length,
        totalMs: e.value.fold(0, (sum, r) => sum + r.durationMs),
        drainedPct: e.value.fold(0, (sum, r) => sum + (r.drained ?? 0)),
        measuredSessions: e.value.where((r) => r.drained != null).length,
        measuredMs: e.value.fold(
          0,
          (sum, r) => sum + (r.drained != null ? r.durationMs : 0),
        ),
      ),
  ];
  out.sort((a, b) => b.totalMs.compareTo(a.totalMs));
  return out;
}

String formatBatteryDuration(int ms) {
  final minutes = ms ~/ 60000;
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours h' : '$hours h $rest min';
}

/// The report page: per-engine session counts, connected time
/// and the battery drained inside those windows — with the
/// estimation limit stated at the top, in the product, not
/// buried. Self-loading: it reads the same document the
/// shell's sampler writes.
class BatteryReportPage extends StatefulWidget {
  const BatteryReportPage({super.key});

  @override
  State<BatteryReportPage> createState() => _BatteryReportPageState();
}

class _BatteryReportPageState extends State<BatteryReportPage> {
  BatteryLog? _log;

  @override
  void initState() {
    super.initState();
    BatteryLog.loadDefault().then(
      (log) {
        if (mounted) setState(() => _log = log);
      },
      onError: (_) {
        // An empty log renders the page's no-sessions state
        // instead of Loading forever; the load is retried the
        // next time the page opens (the failure is not cached).
        if (mounted) setState(() => _log = BatteryLog());
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final log = _log;
    final summaries = log == null
        ? const <BatteryEngineSummary>[]
        : batteryEngineSummaries(log.records);
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Ember.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Ember.text,
        title: Text('Battery usage', style: Ember.heading),
      ),
      body: EmberBackground(child: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 16, 24),
        children: [
          Text(
            'Android does not tell an app how much battery the app '
            'itself used. What this report measures is the '
            'device\'s battery level when each session started '
            'and ended — since Ember runs one engine at a time, '
            'that drain is attributed to the engine that was '
            'connected. The screen, other apps and the radios '
            'share the same window, so treat these numbers as an '
            'estimate for comparing engines, not a meter reading.',
            style: Ember.body,
          ),
          const SizedBox(height: 14),
          if (log == null)
            // Build 2116 (AP-17): the shared loading
            // treatment — orange spinner + caption. These
            // were the only two pages with a bare text.
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Center(
                child: Column(
                  children: [
                    const CircularProgressIndicator(color: Ember.orange),
                    const SizedBox(height: 12),
                    Text('Loading…', style: Ember.caption),
                  ],
                ),
              ),
            )
          else if (summaries.isEmpty)
            GlassCard(
              child: Text(
                'No sessions recorded yet. Sessions of 30 seconds '
                'or longer are recorded while this report is on.',
                style: Ember.body,
              ),
            )
          else ...[
            GlassCard(
              child: Column(
                children: [
                  for (var i = 0; i < summaries.length; i++) ...[
                    if (i > 0) const Divider(color: Ember.line, height: 18),
                    _row(summaries[i]),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () async {
                  await log.clear();
                  if (mounted) setState(() {});
                },
                child: const Text('Clear history'),
              ),
            ),
          ],
        ],
      )),
    );
  }

  Widget _row(BatteryEngineSummary s) {
    final perHour = s.pctPerHour;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.battery_std_rounded, size: 18, color: Ember.dim),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.engine, style: Ember.heading.copyWith(fontSize: Ember.fontBody)),
              const SizedBox(height: 2),
              Text(
                '${s.sessions} session${s.sessions == 1 ? '' : 's'} · '
                '${formatBatteryDuration(s.totalMs)} connected',
                style: Ember.body,
              ),
              const SizedBox(height: 2),
              Text(
                s.measuredSessions == 0
                    ? 'Battery level was not readable for these sessions.'
                    : s.drainedPct < 0
                    ? 'Battery gained in these windows: '
                          '+${-s.drainedPct}% (the device was charging)'
                          '${perHour != null ? ' · about +${(-perHour).toStringAsFixed(1)}% per hour' : ''}'
                    : 'Battery drained in these windows: '
                          '${s.drainedPct}%'
                          '${perHour != null ? ' · about ${perHour.toStringAsFixed(1)}% per hour' : ''}',
                style: Ember.body,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
