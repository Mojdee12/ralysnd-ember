import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../xray/lantern_import.dart';

/// Build 2129: registration of the owner's Lantern private
/// server through the gomobile core's supported API.
///
/// Up to 2128 (the 2127 H8 fallback) the app fetched the
/// manager config itself and merged an entry into the CLI
/// core's server-list file — no pinning, and a file the core
/// owned rewritten under it. The gomobile core has the official
/// client's own private-server suite, so registration is now
/// one call across the platform channel:
///
///   Mobile.addServerManagerInstance(ip, port, accessToken, tag)
///
/// (gomobile argument order verified in
/// build2129-phase1-delta §1.7 — the radiance layer's order
/// differs; do not confuse them). The core fetches the
/// manager config and performs the trust step itself, the
/// server becomes selectable by its tag, and Private mode
/// connects with connectToServer(tag) — true pinning, the
/// thing H8 could not do. Removal is
/// Mobile.deletePrivateServerByName(tag). The channel calls
/// live in lantern_platform.dart; what remains here is the
/// tag rule and the country lookup for the VIP label.

/// The server tag addServerManagerInstance registers [link]
/// under: the invite's name, else its alias, else the server
/// IP (lantern-core's ParseInviteURL fallback order — the
/// same lanternPrivateTag rule H8 used).
String lanternPrivateTag(LanternPrivateServerLink link) {
  if (link.name.isNotEmpty) return link.name;
  if (link.alias.isNotEmpty) return link.alias;
  return link.ip;
}

/// The server's geolocation, mirroring lantern-core's
/// private-server geo lookup (geo.getiantem.org, redirects
/// NOT followed — a redirect to cleartext must not leak the
/// server IP). Null on any failure; the VIP label then stays
/// plain "VIP" until a later registration lands a country.
/// Display only in 2129: the core keeps its own location for
/// the server it registered.
Future<({String city, String country, String code})?> geolocateLanternServer(
  String ip,
) async {
  if (InternetAddress.tryParse(ip) == null) return null;
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 10);
  client.findProxy = (_) => 'DIRECT';
  try {
    final request = await client.getUrl(
      Uri.parse('https://geo.getiantem.org/lookup/${Uri.encodeComponent(ip)}'),
    );
    request.followRedirects = false;
    final response = await request.close();
    if (response.statusCode != 200) return null;
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 10));
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    final country = decoded['Country'];
    if (country is! Map<String, dynamic>) return null;
    final code = (country['IsoCode'] as String?) ?? '';
    if (code.isEmpty) return null;
    final names = country['Names'];
    final countryName = names is Map ? (names['en'] as String? ?? '') : '';
    var city = '';
    final subs = decoded['Subdivisions'];
    if (subs is List && subs.isNotEmpty) {
      final first = subs.first;
      if (first is Map) {
        final subNames = first['Names'];
        if (subNames is Map) city = (subNames['en'] as String?) ?? '';
      }
    }
    return (city: city, country: countryName, code: code);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
