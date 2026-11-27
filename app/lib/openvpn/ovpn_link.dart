/// ovpn:// link import (build 2157, feature pick 1).
///
/// .ovpn FILES have been importable since the OpenVPN
/// engine landed (picker, paste, "Open with Ember"); what
/// was missing is the LINK form. Two shapes exist in the
/// wild and both are read here:
///
/// - the official OpenVPN form (openvpn3's webauth doc):
///   `openvpn://import-profile/https://server/profile.ovpn`
///   — the profile is FETCHED from the embedded https URL
///   (an Access Server one-time-token URL is the common
///   case). The `?url=` spelling of the same form is read
///   too. https only: the spec demands certificate
///   checking, and this app never fetches a profile over
///   cleartext from a link tap.
/// - the payload form (Hiddify 5.9.15's `ovpn://` links):
///   the .ovpn text itself rides the link, either as one
///   base64 block or URL-encoded / raw text.
///
/// A `#name` fragment, when present, names the profile.
/// Parsing is pure; the fetch is the only impure part and
/// is capped at the file intake's 256 KB.
library;

import 'dart:convert';
import 'dart:io';

/// The largest profile a link fetch may return — the
/// .ovpn file intake's cap (build 2085), applied to the
/// link form too.
const ovpnLinkFetchCapBytes = 256 * 1024;

/// What an ovpn:// link carries: the profile text itself,
/// or an https URL to fetch it from.
sealed class OvpnLinkPayload {
  const OvpnLinkPayload(this.name);

  /// The profile name from the link's `#name` fragment
  /// ('' when the link carries none).
  final String name;
}

class OvpnLinkText extends OvpnLinkPayload {
  const OvpnLinkText(this.text, super.name);

  final String text;
}

class OvpnLinkFetch extends OvpnLinkPayload {
  const OvpnLinkFetch(this.url, super.name);

  final String url;
}

/// True when [link] is an ovpn:// or openvpn:// link —
/// the routing gate the shell's deep-link intake checks
/// before the generic link parser can claim it.
bool isOvpnLink(String link) {
  final l = link.trim().toLowerCase();
  return l.startsWith('ovpn://') || l.startsWith('openvpn://');
}

/// The routing gate for profile TEXT (the scan intake's
/// isWgConfText shape): an .ovpn carries a `remote` line
/// and a `client` or `dev` directive. Deliberately a
/// routing test only — importProfile and the core remain
/// the real validators.
bool isOvpnProfileText(String text) {
  var remote = false;
  var client = false;
  for (final raw in text.split('\n')) {
    final line = raw.trim().toLowerCase();
    if (line.startsWith('remote ')) remote = true;
    if (line == 'client' || line.startsWith('dev ')) client = true;
    if (remote && client) return true;
  }
  return false;
}

String _fragmentName(String fragment) {
  if (fragment.isEmpty) return '';
  try {
    return Uri.decodeComponent(fragment).trim();
  } catch (_) {
    return fragment.trim();
  }
}

String? _tryBase64Text(String candidate) {
  final compact = candidate.replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty || compact.length % 4 == 1) return null;
  if (!RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(compact)) return null;
  var b64 = compact.replaceAll('-', '+').replaceAll('_', '/');
  while (b64.length % 4 != 0) {
    b64 += '=';
  }
  try {
    return utf8.decode(base64Decode(b64));
  } catch (_) {
    return null;
  }
}

/// Parses an ovpn:// / openvpn:// link into its payload,
/// or null when the link carries nothing importable (the
/// caller says so in plain words). See the library doc
/// for the two shapes.
OvpnLinkPayload? parseOvpnLink(String link) {
  final t = link.trim();
  final lower = t.toLowerCase();
  final String body;
  if (lower.startsWith('openvpn://')) {
    body = t.substring('openvpn://'.length);
  } else if (lower.startsWith('ovpn://')) {
    body = t.substring('ovpn://'.length);
  } else {
    return null;
  }
  if (body.isEmpty) return null;
  final bodyLower = body.toLowerCase();

  // The official form: import-profile/<https URL> or
  // import-profile?url=<encoded https URL>, with an
  // optional #name on the end.
  if (bodyLower.startsWith('import-profile')) {
    var rest = body.substring('import-profile'.length);
    var name = '';
    final hash = rest.indexOf('#');
    if (hash >= 0) {
      name = _fragmentName(rest.substring(hash + 1));
      rest = rest.substring(0, hash);
    }
    String? url;
    if (rest.startsWith('/')) {
      url = rest.substring(1);
    } else if (rest.toLowerCase().startsWith('?url=')) {
      final encoded = rest.substring(5);
      try {
        url = Uri.decodeComponent(encoded);
      } catch (_) {
        url = null;
      }
    }
    if (url == null || !url.toLowerCase().startsWith('https://')) {
      return null;
    }
    return OvpnLinkFetch(url, name);
  }

  // A bare profile URL under the scheme:
  // ovpn://https://server/profile.ovpn#Name.
  if (bodyLower.startsWith('https://')) {
    var name = '';
    var url = body;
    final hash = body.indexOf('#');
    if (hash >= 0) {
      name = _fragmentName(body.substring(hash + 1));
      url = body.substring(0, hash);
    }
    return OvpnLinkFetch(url, name);
  }

  // The payload form: the profile text itself — base64,
  // URL-encoded, or raw. The full body is tried first (a
  // raw profile's own '#' comment lines are not a name
  // fragment); the fragment-stripped form second, which
  // is where a payload link's #name lives.
  var name = '';
  var stripped = body;
  final hash = body.lastIndexOf('#');
  if (hash >= 0) {
    name = _fragmentName(body.substring(hash + 1));
    stripped = body.substring(0, hash);
  }
  for (final candidate in [body, stripped]) {
    final fromB64 = _tryBase64Text(candidate);
    if (fromB64 != null && isOvpnProfileText(fromB64)) {
      return OvpnLinkText(fromB64, candidate == stripped ? name : '');
    }
    String? decoded;
    try {
      decoded = Uri.decodeComponent(candidate);
    } catch (_) {
      decoded = null;
    }
    if (decoded != null && isOvpnProfileText(decoded)) {
      return OvpnLinkText(decoded, candidate == stripped ? name : '');
    }
    if (isOvpnProfileText(candidate)) {
      return OvpnLinkText(candidate, candidate == stripped ? name : '');
    }
  }
  return null;
}

/// Downloads the profile an [OvpnLinkFetch] names. Null
/// on any failure (non-https, non-200, oversize, network)
/// — the caller reports one plain sentence for all of
/// them. The body is size-capped as it arrives, so a
/// hostile URL cannot stream without bound.
Future<String?> fetchOvpnProfileText(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https') return null;
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(uri);
    req.headers.set(HttpHeaders.userAgentHeader, 'RalysndEmber');
    final res = await req.close();
    if (res.statusCode != 200) return null;
    final bytes = <int>[];
    await for (final chunk in res.timeout(const Duration(seconds: 20))) {
      bytes.addAll(chunk);
      if (bytes.length > ovpnLinkFetchCapBytes) return null;
    }
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
