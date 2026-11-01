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
