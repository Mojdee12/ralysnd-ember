/// Exit-IP quality check (build 2075, feature item 19):
/// what the wider internet thinks of the address the
/// tunnel exits from — datacenter/hosting, flagged proxy,
/// or a residential/mobile address — with the source named
/// on the card, because the verdict is only ever as good
/// as that source's database.
///
/// Source: ipwho.is over HTTPS (build 2095, third-pass
/// audit 5-7 — the previous source, ip-api.com, was
/// CLEARTEXT http: a verdict about the exit's identity
/// travelled unencrypted and could be forged by the
/// carrier or any on-path party; a security verdict must
/// never rest on a cleartext answer). ipwho.is reports
/// ip/country/asn/org but NO proxy/hosting flags — those
/// verdicts are honestly "unknown" now ([ExitQuality.flagsKnown]
/// is false), never invented.
/// The lookup rides the tunnel itself — the request goes
/// through the tunnel's local HTTP proxy inbound — so the
/// answer describes the EXIT, not the device's own line.
/// The score is a plain summary of the flags, not a
/// reputation oracle: 100 minus 40 for a hosting/datacenter
/// address, minus 30 for a proxy flag; a mobile-carrier
/// address is reported as a flag, not scored up or down.

import 'dart:convert';
import 'dart:io';

import '../xray/exit_info.dart' show englishCountryNames;
import 'geo_country.dart';

class ExitQuality {
  final String ip;
  final String country;
  final String countryCode;
  final String city;
  final String isp;
  final String asName;
  final bool hosting;
  final bool proxy;
  final bool mobile;

  /// Whether the source reported proxy/hosting flags at
  /// all (build 2095, audit 5-7): false means the flags
  /// are UNKNOWN — the score and label must not pretend
  /// otherwise.
  final bool flagsKnown;

  const ExitQuality({
    required this.ip,
    this.country = '',
    this.countryCode = '',
    this.city = '',
    this.isp = '',
    this.asName = '',
    this.hosting = false,
    this.proxy = false,
    this.mobile = false,
    this.flagsKnown = true,
  });

  /// 0..100 summary of the flags (see the file header).
  int get score {
    var v = 100;
    if (hosting) v -= 40;
    if (proxy) v -= 30;
    return v < 0 ? 0 : v;
  }

  /// Plain-language flags, worst first.
  List<String> get flags => [
    if (!flagsKnown)
      'Proxy and hosting flags are not reported by this source',
    if (proxy) 'Flagged as a proxy',
    if (hosting) 'Datacenter / hosting address',
    if (mobile) 'Mobile carrier address',
    if (flagsKnown && !proxy && !hosting && !mobile)
      'No proxy or hosting flags',
  ];

  /// One-word quality label for the score.
  String get label {
    // Build 2095 (audit 5-7): unknown flags are unrated,
    // never "Clean".
    if (!flagsKnown) return 'Unrated';
    final v = score;
    if (v >= 80) return 'Clean';
    if (v >= 50) return 'Datacenter';
    return 'Flagged';
  }
}

/// Parses one ipwho.is JSON response (build 2095, audit
/// 5-7). Null when the response is not a successful
/// lookup. The source reports no proxy/hosting flags, so
/// the result is [ExitQuality.flagsKnown] = false.
ExitQuality? parseExitQuality(Map<String, dynamic> j) {
  if (j['success'] != true) return null;
  final ip = j['ip'] as String? ?? '';
  if (ip.isEmpty) return null;
  final conn = j['connection'];
  final connMap = conn is Map
      ? conn.cast<String, dynamic>()
      : const <String, dynamic>{};
  final asn = connMap['asn'];
  final org = connMap['org'] as String? ?? '';
  return ExitQuality(
    ip: ip,
    country: j['country'] as String? ?? '',
    countryCode: j['country_code'] as String? ?? '',
    city: j['city'] as String? ?? '',
    isp: connMap['isp'] as String? ?? org,
    asName: asn == null ? org : 'AS$asn $org'.trim(),
    flagsKnown: false,
  );
}

/// Looks up [ip] — or the tunnel's own exit when [ip] is
/// null — through the tunnel's HTTP proxy on
/// [httpProxyPort]. Null on any failure (no tunnel, source
/// unreachable, bad response): the card says "could not
/// check" instead of inventing a verdict.
///
/// Build 2129 (leg 6): the OFFLINE range tables
/// (geo_country.dart) back the country fields only. When
/// the online answer arrives without a country, the code
/// is filled locally; when the online lookup fails
/// outright and the exit IP is known ([ip] given), the
/// card still gets its country from the tables — with
/// flagsKnown false, so no quality verdict is invented.
/// When the online lookup works, its answer is used
/// exactly as before.
Future<ExitQuality?> fetchExitQuality({
  required int httpProxyPort,
  String? ip,
  Duration timeout = const Duration(seconds: 12),
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..findProxy = (_) => 'PROXY 127.0.0.1:$httpProxyPort';
  ExitQuality? online;
  try {
    final uri = Uri.parse('https://ipwho.is/${ip ?? ''}');
    final request = await client.getUrl(uri).timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode == 200) {
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        online = parseExitQuality(decoded);
      }
    }
  } catch (_) {
    online = null;
  } finally {
    client.close(force: true);
  }
  if (online != null) {
    if (online.countryCode.isNotEmpty) return online;
    final code = await GeoCountry.lookupCountryCode(online.ip);
    if (code == null) return online;
    return ExitQuality(
      ip: online.ip,
      country: online.country.isNotEmpty
          ? online.country
          : (englishCountryNames[code] ?? ''),
      countryCode: code,
      city: online.city,
      isp: online.isp,
      asName: online.asName,
      flagsKnown: online.flagsKnown,
    );
  }
  // The online lookup failed: with a known exit IP the
  // country still resolves locally. No IP, no answer —
  // the pre-2129 null.
  if (ip == null || ip.isEmpty) return null;
  final code = await GeoCountry.lookupCountryCode(ip);
  if (code == null) return null;
  return ExitQuality(
    ip: ip,
    country: englishCountryNames[code] ?? '',
    countryCode: code,
    flagsKnown: false,
  );
}

/// In-memory cache for the exit-IP quality verdict (build
/// 2082, verification V-7): the feature spec says "cached,
/// on demand", but the card re-fetched on every tap. One
/// ip-api.com lookup per exit IP per [ttl]; a tap inside the
/// window reuses the verdict and the card says how old it
/// is. Keyed by the exit IP the verdict describes, so a
/// server switch (a different exit IP) refetches. The
/// verdict is about the IP, not the profile, so it stays
/// valid across a profile switch that lands on the same exit.
class ExitQualityCache {
  ExitQualityCache({
    this.ttl = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _now;
  ExitQuality? _entry;
  DateTime? _at;

  /// The fresh verdict for [ip], or null when there is none,
  /// it belongs to another IP, or it is older than [ttl].
  ExitQuality? lookup(String ip) {
    final entry = _entry;
    final at = _at;
    if (entry == null || at == null || entry.ip != ip) return null;
    if (_now().difference(at) >= ttl) return null;
    return entry;
  }

  /// How old the fresh verdict for [ip] is, or null when
  /// there is no fresh verdict for it.
  Duration? age(String ip) {
    final at = _at;
    if (lookup(ip) == null || at == null) return null;
    return _now().difference(at);
  }

  void store(ExitQuality quality) {
    _entry = quality;
    _at = _now();
  }

  void clear() {
    _entry = null;
    _at = null;
  }
}

/// The session-wide cache the Home card reads (build 2082):
/// one instance for the app, so the verdict survives leaving
/// the Home tab and coming back. Tests use their own
/// instances; nothing else writes here.
final ExitQualityCache exitQualityCache = ExitQualityCache();

/// "checked just now" / "checked 3 min ago" / "checked 2 h
/// ago" for a cached verdict's age — Latin digits, words
/// only (the ↓/↑ glyph rule: no symbols that can render as
/// tofu boxes).
String qualityAgeLabel(Duration age) {
  if (age.inSeconds < 60) return 'checked just now';
  if (age.inMinutes < 60) {
    final m = age.inMinutes;
    return 'checked $m min ago';
  }
  final h = age.inHours;
  return 'checked $h h ago';
}
