/// Small display formatters for the Ember UI (sizes, rates, timers).

import '../../xray/xray_models.dart';

/// A profile's cumulative per-config traffic: one fully-English LTR
/// string with Latin digits and Latin unit letters —
/// "↓ 35.8 MB · ↑ 3.4 MB" (2006: the user rejected the Persian unit
/// words, and the mixed-direction rendering scrambled the line).
/// Call sites wrap it in an LTR [Directionality] so bidi can never
/// reorder it.
String fmtProfileTotals(Profile p) =>
    '↓ ${fmtBytes(p.totalDownBytes)} · ↑ ${fmtBytes(p.totalUpBytes)}';

/// Whether a profile has any counted traffic to show.
bool profileHasTotals(Profile p) =>
    p.totalDownBytes > 0 || p.totalUpBytes > 0;

String fmtBytes(int bytes) {
  if (bytes < 0) return '—';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024.0;
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[i]}';
}

String fmtGigabytes(int bytes) {
  if (bytes < 0) return '—';
  final gb = bytes / (1024 * 1024 * 1024);
  return gb >= 100 ? gb.toStringAsFixed(0) : gb.toStringAsFixed(1);
}

String fmtRate(int bytesPerSec) => '${fmtBytes(bytesPerSec)}/s';

String fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// Every displayed number in the app uses Latin digits (the user's
/// standing rule): this normalizes a value to a string whose digits
/// are 0-9, converting any Persian (۰-۹) or Arabic-Indic (٠-٩) digits
/// it may already contain and using '.' as the decimal separator.
String latDigits(Object value) {
  const fa = '۰۱۲۳۴۵۶۷۸۹';
  const ar = '٠١٢٣٤٥٦٧٨٩';
  var out = value.toString();
  for (var i = 0; i < 10; i++) {
    out = out.replaceAll(fa[i], '$i').replaceAll(ar[i], '$i');
  }
  return out.replaceAll('٫', '.');
}

/// Byte counts, fully English like every other display in the app
/// (2006): Latin digits and Latin unit letters. Kept as a separate
/// name for the call sites that adopted it in 2005; it is [fmtBytes].
String fmtBytesLocal(int bytes) => fmtBytes(bytes);
