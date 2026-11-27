/// Offline IP → country lookup (build 2129, leg 6, delta
/// §6(c)/(d)): a pure-Dart reader for the compact range
/// tables vendored from the LML release, themselves derived
/// from v2fly/geoip release 202610050438 (CC BY-SA 4.0 —
/// credit in the licences page and
/// assets/licenses/geoip-notice.txt; the tables'
/// provenance is pinned by SHA-256 in
/// assets/geoip/build-info.json, verified against the
/// vendored files at adoption time).
///
/// Format (reversed from LML's GeoCountry reader and
/// cross-checked against the data): an 8-byte header —
/// big-endian magic (0x4C473401 for v4, 0x4C473601 for v6)
/// and a big-endian int32 range count (362,108 v4 /
/// 348,691 v6, matching build-info.json) — then that many
/// fixed-size records, sorted by start and
/// non-overlapping: start address, end address, and a
/// 2-byte ASCII country code. 10 bytes per v4 record,
/// 34 per v6 record; the file length is exactly
/// 8 + count × record size.
///
/// Role in the app: a FALLBACK for the country fields
/// only. The online exit lookups (Cloudflare trace for
/// Xray/Psiphon, ipwho.is for the home quality card)
/// stay primary and are unchanged when they work; when
/// one fails, or answers without a country, the country
/// is filled from here once the exit IP is known. City
/// and ISP never come from this table — it has none.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../xray/exit_info.dart';

/// One parsed pair of range tables. Immutable; lookups
/// binary-search the raw record bytes in place, so a
/// lookup costs no materialisation of the 700k ranges.
class GeoCountryDb {
  GeoCountryDb._(this._v4, this._v6);

  final _GeoTable? _v4;
  final _GeoTable? _v6;

  /// Parses both families independently: a corrupt v4
  /// table never costs the v6 lookups. Null when NEITHER
  /// family parses.
  static GeoCountryDb? tryParse({Uint8List? v4, Uint8List? v6}) {
    final t4 = v4 == null ? null : _GeoTable.tryParse(v4, isV6: false);
    final t6 = v6 == null ? null : _GeoTable.tryParse(v6, isV6: true);
    if (t4 == null && t6 == null) return null;
    return GeoCountryDb._(t4, t6);
  }

  /// Range counts per family (0 when that family failed
  /// to parse) — the build-info cross-check reads these.
  int get v4Ranges => _v4?.count ?? 0;
  int get v6Ranges => _v6?.count ?? 0;

  /// The 2-letter country code for [ip], or null when the
  /// address does not parse, its family has no table, or
  /// no range covers it (a miss falls back to the online
  /// path, exactly as before this table existed).
  String? lookup(String ip) {
    final addr = InternetAddress.tryParse(ip.trim());
    if (addr == null) return null;
    final table = addr.type == InternetAddressType.IPv6 ? _v6 : _v4;
    if (table == null) return null;
    return table.lookup(addr.rawAddress);
  }
}

class _GeoTable {
  _GeoTable._(this.bytes, this.count, this.addrLen);

  final Uint8List bytes;
  final int count;
  final int addrLen;

  int get recordSize => addrLen * 2 + 2;

  static _GeoTable? tryParse(Uint8List bytes, {required bool isV6}) {
    final addrLen = isV6 ? 16 : 4;
    final recordSize = addrLen * 2 + 2;
    if (bytes.length < 8) return null;
    final header = ByteData.sublistView(bytes, 0, 8);
    final magic = header.getInt32(0);
    if (magic != (isV6 ? 0x4C473601 : 0x4C473401)) return null;
    final count = header.getInt32(4);
    if (count <= 0 || count > 500000) return null;
    if (bytes.length != 8 + count * recordSize) return null;
    return _GeoTable._(bytes, count, addrLen);
  }

  int _compareAt(int record, int offset, Uint8List ip) {
    final base = 8 + record * recordSize + offset;
    for (var i = 0; i < addrLen; i++) {
      final a = ip[i];
      final b = bytes[base + i];
      if (a != b) return a < b ? -1 : 1;
    }
    return 0;
  }

  /// LML's search, mirrored: the last range whose start
  /// is ≤ the address, then a check that the address is
  /// ≤ that range's end.
  String? lookup(Uint8List ip) {
    if (ip.length != addrLen) return null;
    var lo = 0;
    var hi = count - 1;
    var found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      // _compareAt answers ip-vs-record: negative means
      // the address sits BELOW this range's start.
      if (_compareAt(mid, 0, ip) < 0) {
        hi = mid - 1;
      } else {
        lo = mid + 1;
        found = mid;
      }
    }
    if (found < 0) return null;
    // Above the found range's end: a miss.
    if (_compareAt(found, addrLen, ip) > 0) return null;
    final ccAt = 8 + found * recordSize + addrLen * 2;
    final a = bytes[ccAt];
    final b = bytes[ccAt + 1];
    if (a < 0x41 || a > 0x5A || b < 0x41 || b > 0x5A) return null;
    return String.fromCharCodes([a, b]);
  }
}

/// The app-wide loader: reads the two vendored assets
/// once, caches the parsed tables, and answers lookups.
/// Any failure (assets missing, a table corrupt) leaves
/// lookups answering null — the pre-2129 behaviour.
class GeoCountry {
  GeoCountry._();

  static Future<GeoCountryDb?>? _loading;
  static GeoCountryDb? _db;

  /// Loads (once) and returns the tables, or null when
  /// they cannot be read.
  static Future<GeoCountryDb?> load() {
    if (_db != null) return Future.value(_db);
    return _loading ??= () async {
      try {
        final v4 = await rootBundle.load('assets/geoip/countries-v4.bin');
        final v6 = await rootBundle.load('assets/geoip/countries-v6.bin');
        _db = GeoCountryDb.tryParse(
          v4: v4.buffer.asUint8List(v4.offsetInBytes, v4.lengthInBytes),
          v6: v6.buffer.asUint8List(v6.offsetInBytes, v6.lengthInBytes),
        );
      } catch (_) {
        _db = null;
      }
      return _db;
    }();
  }

  /// The country code for [ip] from the offline tables,
  /// or null on a miss / unavailable tables.
  static Future<String?> lookupCountryCode(String ip) async {
    final db = await load();
    return db?.lookup(ip);
  }
}

/// Fills [info]'s country from [lookup] when — and only
/// when — the online answer carried none: an online
/// country is always preferred, verbatim. The English
/// name is left empty on purpose: [ExitInfo.displayName]
/// already resolves a bare code through the built-in
/// name table.
ExitInfo fillCountryOffline(
  ExitInfo info,
  String? Function(String ip) lookup,
) {
  if (info.countryCode.isNotEmpty || info.ip.isEmpty) return info;
  final code = lookup(info.ip);
  if (code == null || code.isEmpty) return info;
  return ExitInfo(ip: info.ip, countryCode: code, countryEn: info.countryEn);
}

/// [fillCountryOffline] over the vendored tables: the
/// wiring the Xray and Psiphon exit lookups use after
/// their online probe answers without a country (or,
/// for the home quality card, does not answer at all).
Future<ExitInfo> exitInfoWithOfflineCountry(ExitInfo info) async {
  if (info.countryCode.isNotEmpty || info.ip.isEmpty) return info;
  final db = await GeoCountry.load();
  if (db == null) return info;
  return fillCountryOffline(info, db.lookup);
}
