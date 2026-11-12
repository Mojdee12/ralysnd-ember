/// Fetches subscription bodies and parses the traffic/expiry headers
/// (port of the Ralysnd client's Kotlin SubFetcher).

import 'dart:io';

import 'link_parser.dart';
import 'xray_models.dart';

class SubResult {
  final List<Profile> profiles;
  final int uploadBytes;
  final int downloadBytes;
  final int totalBytes;
  final int expireEpochSec;
  final String? suggestedName;
  const SubResult({
    required this.profiles,
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    this.totalBytes = 0,
    this.expireEpochSec = 0,
    this.suggestedName,
  });
}

/// A built-in subscription preset (build 2032): a public feed
/// the user may add with one tap. Presets are VISIBLE and
/// opt-in — nothing here is fetched until the user adds it,
/// and it then lives as an ordinary subscription they can
/// delete. (The pool lesson: a hidden fallback pool silently
/// swapping a user's servers is never acceptable.)
class SubPreset {
  const SubPreset(this.name, this.url, this.note);
  final String name;
  final String url;
  final String note;
}

/// The v2go feeds (Danialsamadi/v2go, GPL-3.0): public configs
/// live-tested hourly by the publisher and republished only
/// while they carry traffic. Third-party servers of unknown
/// operators — useful for circumvention, never for trust.
const v2goPresets = <SubPreset>[
  SubPreset(
    'v2go — All verified',
    'https://raw.githubusercontent.com/Danialsamadi/v2go/main/AllConfigsSub.txt',
    'Every config that passed the publisher\u2019s last hourly live test.',
  ),
  SubPreset(
    'v2go — Cloudflare only',
    'https://raw.githubusercontent.com/Danialsamadi/v2go/main/Splitted-By-Protocol/cloudflare.txt',
    'Only configs whose endpoint is a Cloudflare address.',
  ),
  SubPreset(
    'v2go — VLESS only',
    'https://raw.githubusercontent.com/Danialsamadi/v2go/main/Splitted-By-Protocol/vless.txt',
    'The verified pool, VLESS configs only.',
  ),
  SubPreset(
    'v2go — VMess only',
    'https://raw.githubusercontent.com/Danialsamadi/v2go/main/Splitted-By-Protocol/vmess.txt',
    'The verified pool, VMess configs only.',
  ),
  SubPreset(
    'v2go — Trojan only',
    'https://raw.githubusercontent.com/Danialsamadi/v2go/main/Splitted-By-Protocol/trojan.txt',
    'The verified pool, Trojan configs only.',
  ),
  SubPreset(
    'v2go — Shadowsocks only',
    'https://raw.githubusercontent.com/Danialsamadi/v2go/main/Splitted-By-Protocol/ss.txt',
    'The verified pool, Shadowsocks configs only.',
  ),
  SubPreset(
    'v2go — Hysteria2 only',
    'https://raw.githubusercontent.com/Danialsamadi/v2go/main/Splitted-By-Protocol/hy2.txt',
    'The verified pool, Hysteria2 configs only.',
  ),
];

/// The per-country v2go feed URL for an ISO country code.
String v2goCountryUrl(String countryCode) =>
    'https://raw.githubusercontent.com/Danialsamadi/v2go/main/Splitted-By-Country/${countryCode.toUpperCase()}.txt';

/// Fetches [url] and parses the result; throws on network/parse errors.
Future<SubResult> fetchSubscription(String url) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 20);
  client.userAgent = 'v2rayNG/1.9.5 RalysndEmber/2.0';
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('accept', '*/*');
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }
    final info = _parseUserInfo(response.headers.value('subscription-userinfo'));
    final title = response.headers.value('profile-title');
    final body = await response
        .transform(const SystemEncoding().decoder)
        .join()
        .timeout(const Duration(seconds: 30));
    final profiles = parseSubscription(body);
    if (profiles.isEmpty) {
      throw const FormatException('no profiles in subscription');
    }
    return SubResult(
      profiles: profiles,
      uploadBytes: info.$1,
      downloadBytes: info.$2,
      totalBytes: info.$3,
      expireEpochSec: info.$4,
      suggestedName: _decodeTitle(title),
    );
  } finally {
    client.close(force: true);
  }
}

/// (upload, download, total, expire) from a subscription-userinfo header.
(int, int, int, int) _parseUserInfo(String? header) {
  if (header == null) return (0, 0, 0, 0);
  int get(String key) {
    for (final part in header.split(';')) {
      final eq = part.indexOf('=');
      if (eq > 0 && part.substring(0, eq).trim() == key) {
        return int.tryParse(part.substring(eq + 1).trim()) ?? 0;
      }
    }
    return 0;
  }

  return (get('upload'), get('download'), get('total'), get('expire'));
}

String? _decodeTitle(String? title) {
  if (title == null || title.isEmpty) return null;
  var value = title.trim();
  if (value.toLowerCase().startsWith('base64:')) {
    value = b64decode(value.substring(7)) ?? value;
  }
  return value.isEmpty ? null : value;
}
