/// Lantern private-server import for the Xray engine.
///
/// A Lantern private server is a user-run box: a small HTTPS
/// "server manager" plus a sing-box whose data plane is plain
/// Shadowsocks. The invite links the Lantern app consumes
/// (https://lantern.io/private-server?ip=…&port=…&token=…) carry
/// only the manager's address and an access token; the actual
/// proxy credentials come from the manager itself:
///
///   GET https://{ip}:{port}/api/v1/connect-config?token={jwt}
///
/// answers a sing-box client config whose Shadowsocks outbound is
/// the tunnel. This importer performs that one fetch (direct, no
/// tunnel, standard TLS verification) and turns the outbound into
/// an ordinary Ember Shadowsocks profile — from then on the
/// profile uses the Xray engine's existing connect / delay-test /
/// traffic machinery unchanged. No Lantern core is involved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'link_parser.dart';
import 'xray_models.dart';

/// An import failure with a user-facing, English explanation.
class LanternImportException implements Exception {
  final String message;
  const LanternImportException(this.message);

  @override
  String toString() => message;
}

/// One parsed Lantern private-server invite link.
class LanternPrivateServerLink {
  /// Manager host (IP or hostname) — NOT the tunnel endpoint.
  final String ip;

  /// Manager API port.
  final int port;

  /// JWT access token for the manager API.
  final String token;

  /// The link's `name` parameter (may be empty).
  final String name;

  /// The link's `alias` parameter (may be empty).
  final String alias;

  const LanternPrivateServerLink({
    required this.ip,
    required this.port,
    required this.token,
    this.name = '',
    this.alias = '',
  });

  /// Profile name: alias, else name, else "Lantern {ip}".
  String get displayName {
    if (alias.isNotEmpty) return alias;
    if (name.isNotEmpty) return name;
    return 'Lantern $ip';
  }

  Uri get connectConfigUri => Uri(
        scheme: 'https',
        host: ip,
        port: port,
        path: '/api/v1/connect-config',
        queryParameters: {'token': token},
      );
}

final _lanternLinkPattern = RegExp(
  r'(?:https?://lantern\.io/private-server|lantern://private-server|lantern//private-server|lantern\.io/private-server)\?\S+',
  caseSensitive: false,
);

/// Finds a Lantern private-server link anywhere inside [text] (a
/// pasted channel post, a QR payload, one line of a link list) and
/// parses it; null when there is none or it is malformed.
LanternPrivateServerLink? findLanternPrivateServerLink(String text) {
  final match = _lanternLinkPattern.firstMatch(text);
  if (match == null) return null;
  return parseLanternPrivateServerLink(match.group(0)!);
}

bool containsLanternPrivateServerLink(String text) =>
    findLanternPrivateServerLink(text) != null;

/// Parses one invite link in any of the forms the Lantern app
/// accepts: `https://lantern.io/private-server?…`,
/// `lantern://private-server?…`, `lantern//private-server?…`
/// (and a bare `lantern.io/private-server?…`). Returns null when
/// the link is not one of those, or a required parameter (ip,
/// token, a valid port) is missing.
LanternPrivateServerLink? parseLanternPrivateServerLink(String raw) {
  var link = raw.trim();
  final lower = link.toLowerCase();
  const prefixes = [
    'https://lantern.io/private-server',
    'http://lantern.io/private-server',
    'lantern://private-server',
    'lantern//private-server',
    'lantern.io/private-server',
  ];
  String? matched;
  for (final prefix in prefixes) {
    if (lower.startsWith(prefix)) {
      matched = prefix;
      break;
    }
  }
  if (matched == null) return null;
  final rest = link.substring(matched.length);
  if (!rest.startsWith('?')) return null;
  Map<String, String> params;
  try {
    params = Uri.splitQueryString(rest.substring(1));
  } catch (_) {
    return null;
  }
  final ip = (params['ip'] ?? '').trim();
  final token = (params['token'] ?? '').trim();
  if (ip.isEmpty || token.isEmpty) return null;
  var port = 8080;
  final portText = (params['port'] ?? '').trim();
  if (portText.isNotEmpty) {
    final parsed = int.tryParse(portText);
    if (parsed == null || parsed < 1 || parsed > 65535) return null;
    port = parsed;
  }
  return LanternPrivateServerLink(
    ip: ip,
    port: port,
    token: token,
    name: (params['name'] ?? '').trim(),
    alias: (params['alias'] ?? '').trim(),
  );
}

/// The one HTTP call the import needs, abstracted for tests.
typedef LanternHttpGet = Future<({int statusCode, String body})> Function(
  Uri url,
);

Future<({int statusCode, String body})> _directGet(Uri url) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 15);
  client.userAgent = 'RalysndEmber/2.0';
  try {
    final request = await client.getUrl(url);
    final response = await request.close();
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 15));
    return (statusCode: response.statusCode, body: body);
  } finally {
    client.close(force: true);
  }
}

/// Fetches the manager's connect-config for [link] and maps it to a
/// Shadowsocks profile. Throws [LanternImportException] with a
/// clear message on any network, TLS, token or shape failure.
Future<Profile> fetchLanternPrivateServerProfile(
  LanternPrivateServerLink link, {
  LanternHttpGet? get,
}) async {
  final transport = get ?? _directGet;
  final ({int statusCode, String body}) response;
  try {
    response = await transport(link.connectConfigUri)
        .timeout(const Duration(seconds: 15));
  } on TimeoutException {
    throw LanternImportException(
      'The Lantern server at ${link.ip} did not answer in time. '
      'Check your connection and try again.',
    );
  } on HandshakeException {
    throw LanternImportException(
      'TLS handshake with the Lantern server at ${link.ip}:${link.port} '
      'failed, so the config could not be fetched securely.',
    );
  } on TlsException {
    throw LanternImportException(
      'TLS handshake with the Lantern server at ${link.ip}:${link.port} '
      'failed, so the config could not be fetched securely.',
    );
  } on SocketException catch (e) {
    throw LanternImportException(
      'Could not reach the Lantern server at ${link.ip}:${link.port}'
      '${e.message.isEmpty ? '' : ' (${e.message})'}. '
      'Check your connection and try again.',
    );
  } on HttpException catch (e) {
    throw LanternImportException(
      'Could not fetch the config from the Lantern server at '
      '${link.ip}:${link.port}: ${e.message}',
    );
  }
  if (response.statusCode == 401 || response.statusCode == 403) {
    throw LanternImportException(
      'The server rejected this link\'s access token '
      '(HTTP ${response.statusCode}). These links expire — get a '
      'fresh one and try again.',
    );
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw LanternImportException(
      'The Lantern server answered HTTP ${response.statusCode}; '
      'no config was imported.',
    );
  }
  return profileFromConnectConfig(
    response.body,
    fallbackName: link.displayName,
  );
}

/// Maps a manager connect-config body (sing-box client config JSON)
/// to a Shadowsocks [Profile]: the first Shadowsocks outbound wins.
/// Throws [LanternImportException] when the body is not the
/// documented shape or carries no Shadowsocks outbound.
Profile profileFromConnectConfig(
  String body, {
  required String fallbackName,
}) {
  final dynamic doc;
  try {
    doc = jsonDecode(body);
  } catch (_) {
    throw const LanternImportException(
      'The Lantern server returned a response that was not valid '
      'JSON; no config was imported.',
    );
  }
  if (doc is! Map<String, dynamic>) {
    throw const LanternImportException(
      'The Lantern server returned an unexpected response; '
      'no config was imported.',
    );
  }
  final outbounds = doc['outbounds'];
  if (outbounds is! List) {
    throw const LanternImportException(
      'The Lantern server response has no outbounds; '
      'no config was imported.',
    );
  }
  var sawShadowsocks = false;
  for (final raw in outbounds) {
    if (raw is! Map) continue;
    final outbound = raw.cast<String, dynamic>();
    if (outbound['type'] == 'shadowsocks') {
      sawShadowsocks = true;
      final profile = _singBoxShadowsocks(outbound, fallbackName);
      if (profile != null) return profile;
    } else if (outbound['protocol'] == 'shadowsocks') {
      // Xray-shaped outbound, tolerated for robustness.
      sawShadowsocks = true;
      final profile = _xrayShadowsocks(outbound, fallbackName);
      if (profile != null) return profile;
    }
  }
  if (sawShadowsocks) {
    throw const LanternImportException(
      'The Shadowsocks config from this Lantern server is '
      'incomplete (missing server, method or password); '
      'nothing was imported.',
    );
  }
  throw const LanternImportException(
    'This Lantern server did not return a Shadowsocks config, so '
    'it cannot be imported into the V2Ray engine.',
  );
}

Profile? _singBoxShadowsocks(
  Map<String, dynamic> outbound,
  String fallbackName,
) {
  final server = outbound['server'] as String? ?? '';
  final port = (outbound['server_port'] as num?)?.toInt() ?? 0;
  final method = outbound['method'] as String? ?? '';
  final password = outbound['password'] as String? ?? '';
  if (server.isEmpty || port < 1 || method.isEmpty || password.isEmpty) {
    return null;
  }
  return Profile(
    id: newProfileId(),
    protocol: Protocol.shadowsocks,
    name: fallbackName,
    address: server,
    port: port,
    uuidOrPassword: password,
    method: method,
  );
}

Profile? _xrayShadowsocks(
  Map<String, dynamic> outbound,
  String fallbackName,
) {
  final settings = (outbound['settings'] as Map?)?.cast<String, dynamic>();
  final servers = settings?['servers'];
  if (servers is! List || servers.isEmpty || servers.first is! Map) {
    return null;
  }
  final server = (servers.first as Map).cast<String, dynamic>();
  final address = server['address'] as String? ?? '';
  final port = (server['port'] as num?)?.toInt() ?? 0;
  final method = server['method'] as String? ?? '';
  final password = server['password'] as String? ?? '';
  if (address.isEmpty || port < 1 || method.isEmpty || password.isEmpty) {
    return null;
  }
  return Profile(
    id: newProfileId(),
    protocol: Protocol.shadowsocks,
    name: fallbackName,
    address: address,
    port: port,
    uuidOrPassword: password,
    method: method,
  );
}
