// Build 2134 (leg 2): automatic per-device HWID headers
// for subscription fetches, Remnawave-style.
//
// Panels that gate a subscription by device ask for an
// `x-hwid` request header. Build 2050 gave every
// subscription a MANUAL hwid field; this leg adds the
// automatic form: one stable random device id, generated
// once and kept in the settings, sent on every fetch —
// but ONLY behind the `subHwidEnabled` switch (default
// OFF, the standing rule). With the switch off, nothing
// here runs and fetches are byte-for-byte build 2133's.
//
// Precedence, deliberately conservative:
// * a subscription's own manual hwid always wins (the
//   automatic id is not sent for that subscription);
// * a header the user already set in the subscription's
//   custom headers is never overwritten.

import 'dart:math';

/// A fresh random UUID v4 — the device id's shape. Stable
/// because it is generated once and persisted, not because
/// it derives from any hardware identifier (the app reads
/// none).
String generateDeviceHwid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 1
  String hex(int i) => b[i].toRadixString(16).padLeft(2, '0');
  final s = StringBuffer();
  for (var i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) s.write('-');
    s.write(hex(i));
  }
  return s.toString();
}

/// The extra headers a fetch gains from the automatic
/// device id — empty unless the feature is on, an id
/// exists, and the subscription carries no manual hwid.
/// `x-device-os` rides along (Remnawave's companion
/// header) unless the user set it themselves.
Map<String, String> autoHwidHeaders({
  required bool enabled,
  required String deviceHwid,
  required String subHwid,
  required Map<String, String> customHeaders,
}) {
  if (!enabled || deviceHwid.isEmpty || subHwid.isNotEmpty) {
    return const {};
  }
  bool has(String name) =>
      customHeaders.keys.any((k) => k.toLowerCase() == name);
  return {
    if (!has('x-hwid')) 'x-hwid': deviceHwid,
    if (!has('x-device-os')) 'x-device-os': 'Android',
  };
}
