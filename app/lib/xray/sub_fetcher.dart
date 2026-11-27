/// Fetches subscription bodies and parses the traffic/expiry headers
/// (port of the Ralysnd client's Kotlin SubFetcher).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'iran_features_2147.dart';
import 'link_parser.dart';
import 'profile_validation.dart';
import 'sha256.dart';
import 'xray_models.dart';

class SubResult {
  final List<Profile> profiles;
  final int uploadBytes;
  final int downloadBytes;
  final int totalBytes;
  final int expireEpochSec;
  final String? suggestedName;

  /// True when the primary URL failed and the subscription's
  /// fallback URL served the body instead (build 2050).
  final bool usedFallback;

  /// Build 2147 (features #18/#21b): the distinct link
  /// schemes in the body that NO engine in Ember serves —
  /// they were skipped at parse, and the refresh journals
  /// them by name instead of dropping them in silence.
  final List<String> unsupportedSchemes;
  const SubResult({
    required this.profiles,
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    this.totalBytes = 0,
    this.expireEpochSec = 0,
    this.suggestedName,
    this.usedFallback = false,
    this.unsupportedSchemes = const [],
  });
}

/// Why a subscription fetch failed (build 2050, audit C-2):
/// until now every failure — a 403, a dead DNS name, a
/// self-signed certificate, an unparseable body — collapsed
/// into one generic "Update failed" at all four call sites,
/// and the real exception was discarded unlogged. The kinds
/// below are what the UI now shows, each with its own words.
enum SubFetchErrorKind {
  http,
  certificate,
  dns,
  timeout,
  network,
  format,
  invalidUrl,
}

/// A subscription fetch failure with a user-ready, specific
/// message. [certSha256] carries the SHA-256 of the
/// certificate the server presented when [kind] is
/// [SubFetchErrorKind.certificate], so the add sheet can offer
/// "trust this certificate" and retry with it pinned.
class SubFetchException implements Exception {
  final SubFetchErrorKind kind;
  final String message;
  final int? statusCode;
  final String? certSha256;
  final Object? cause;
  const SubFetchException({
    required this.kind,
    required this.message,
    this.statusCode,
    this.certSha256,
    this.cause,
  });

  @override
  String toString() => message;
}

/// The shape of a body that parsed to zero profiles (build
/// 2050, audit F-H12): panels answer different formats by path
/// and User-Agent, and "no profiles" never told the user WHICH
/// format came back. Detection is pure and unit-tested.
enum SubBodyFormat { empty, html, clash, singBox, jsonUnknown, unknown }

/// Classifies a body [parseSubscription] could not read.
SubBodyFormat detectSubBodyFormat(String body) {
  final t = body.trim();
  if (t.isEmpty) return SubBodyFormat.empty;
  if (t.startsWith('<')) return SubBodyFormat.html;
  // Clash YAML is served bare: a top-level `proxies:` list is
  // its unmistakable marker.
  if (RegExp(r'(^|\n)proxies\s*:').hasMatch(t) || t.contains('mixed-port:')) {
    return SubBodyFormat.clash;
  }
  if (t.startsWith('{') || t.startsWith('[')) {
    try {
      final doc = jsonDecode(t);
      final maps = <Map>[
        if (doc is Map) doc,
        if (doc is List) ...doc.whereType<Map>(),
      ];
      for (final m in maps) {
        final outs = m['outbounds'];
        // sing-box names the kind `type`; Xray JSON uses
        // `protocol` — and Xray JSON never reaches this
        // detector, because the parser reads it first.
        if (outs is List &&
            outs.any(
              (o) =>
                  o is Map &&
                  o.containsKey('type') &&
                  !o.containsKey('protocol'),
            )) {
          return SubBodyFormat.singBox;
        }
      }
    } catch (_) {
      // Not JSON at all; the generic word below covers it.
    }
    return SubBodyFormat.jsonUnknown;
  }
  return SubBodyFormat.unknown;
}

/// The user-facing words for a body that held no readable
/// profiles — naming the format when one is recognizable.
String emptyBodyMessage(SubBodyFormat format) => switch (format) {
  SubBodyFormat.empty => 'The subscription server answered with an empty body.',
  SubBodyFormat.html =>
    'The server returned a web page, not a subscription — '
        'the link may be expired or need a sign-in. Check the link.',
  SubBodyFormat.clash =>
    'The server returned a Clash config. Ember reads link '
        'subscriptions — use the panel\u2019s subscription (/sub/) '
        'link instead of the Clash one.',
  SubBodyFormat.singBox =>
    'The server returned a sing-box config. Ember reads link '
        'subscriptions — use the panel\u2019s subscription (/sub/) '
        'link instead of the sing-box one.',
  SubBodyFormat.jsonUnknown =>
    'The server returned JSON Ember cannot read as a '
        'subscription — use the panel\u2019s subscription (/sub/) link.',
  SubBodyFormat.unknown => 'The subscription held no configs Ember can read.',
};

/// Maps a raw fetch failure to a typed, user-ready exception
/// (build 2050, audit C-2). Pure and unit-tested; the fetcher
/// routes every throw through here.
SubFetchException classifyFetchError(
  Object e, {
  required String host,
  String? certSha256,
}) {
  if (e is SubFetchException) return e;
  if (e is HandshakeException ||
      e is CertificateException ||
      e is TlsException) {
    return SubFetchException(
      kind: SubFetchErrorKind.certificate,
      message:
          'The certificate of $host is not trusted — it is '
          'self-signed, expired, or issued for another name.',
      certSha256: certSha256,
      cause: e,
    );
  }
  if (e is TimeoutException) {
    return SubFetchException(
      kind: SubFetchErrorKind.timeout,
      message: 'The server at $host took too long to answer.',
      cause: e,
    );
  }
  if (e is SocketException) {
    final m = e.message.toLowerCase();
    if (m.contains('failed host lookup') ||
        m.contains('name or service not known') ||
        m.contains('nodename nor servname') ||
        m.contains('temporary failure in name resolution') ||
        m.contains('no address associated')) {
      return SubFetchException(
        kind: SubFetchErrorKind.dns,
        message:
            'Could not resolve $host on this network — check '
            'the address, or pin the host under Settings \u2192 '
            'Custom DNS hosts.',
        cause: e,
      );
    }
    return SubFetchException(
      kind: SubFetchErrorKind.network,
      message: 'Could not reach $host: ${e.message}',
      cause: e,
    );
  }
  if (e is HttpException) {
    return SubFetchException(
      kind: SubFetchErrorKind.network,
      message: 'Fetch from $host failed: ${e.message}',
      cause: e,
    );
  }
  return SubFetchException(
    kind: SubFetchErrorKind.network,
    message: 'Subscription fetch failed: $e',
    cause: e,
  );
}

/// The words a call site shows for a failed subscription
/// operation (build 2050, audit C-2): the fetcher's specific
/// message when there is one, [fallback] otherwise.
String subFetchErrorText(Object e, {required String fallback}) =>
    e is SubFetchException ? e.message : fallback;

/// Extra request headers a panel may require, one per line
/// as `Name: value` (build 2051, audit F-H13 remainder — the
/// arbitrary custom-headers map 2050 left out: HWID and the
/// fallback URL shipped then; the map itself had no model
/// field or UI). Pure and unit-tested.
///
/// Rules, enforced so a bad line can never silently change
/// what the fetcher sends: blank lines are skipped; the name
/// must be a valid HTTP token; the value must be non-empty;
/// `User-Agent` is rejected — the app fixes its own UA and
/// the fetcher drops a `user-agent` entry anyway, so
/// accepting it here would be a silent lie; a repeated name
/// (case-insensitive) keeps the LAST value; at most 10
/// headers — a panel needs one or two.
({Map<String, String> headers, String? error}) parseCustomHeaders(String text) {
  final headers = <String, String>{};
  final seenNames = <String>{};
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final colon = line.indexOf(':');
    if (colon <= 0) {
      return (
        headers: const {},
        error:
            'Line ${i + 1}: write headers as "Name: value" — '
            'this line has no colon.',
      );
    }
    final name = line.substring(0, colon).trim();
    final value = line.substring(colon + 1).trim();
    if (!RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$").hasMatch(name)) {
      return (
        headers: const {},
        error: 'Line ${i + 1}: "$name" is not a valid header name.',
      );
    }
    if (name.toLowerCase() == 'user-agent') {
      return (
        headers: const {},
        error:
            'Line ${i + 1}: User-Agent is set by the app and '
            'cannot be changed here.',
      );
    }
    if (value.isEmpty) {
      return (
        headers: const {},
        error: 'Line ${i + 1}: "$name" has no value after the colon.',
      );
    }
    if (seenNames.length >= 10 && !seenNames.contains(name.toLowerCase())) {
      return (
        headers: const {},
        error: 'At most 10 extra headers — remove some lines.',
      );
    }
    seenNames.add(name.toLowerCase());
    // A repeated name (any casing) keeps the LAST value and
    // the last spelling — the map holds one entry per header,
    // so the fetcher can never send the same header twice.
    headers.removeWhere((k, _) => k.toLowerCase() == name.toLowerCase());
    headers[name] = value;
  }
  return (headers: headers, error: null);
}

/// The fetch [XrayController] runs for a subscription; a
/// typedef so tests can inject a fake (build 2050, audit
/// F-M20 — the fetcher previously had no seam and no tests).
typedef SubscriptionFetcher = Future<SubResult> Function(
  String url, {
  String certPin,
  String hwid,
  Map<String, String> headers,
  String fallbackUrl,
  Map<String, String> hosts,
});

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

/// Fetches [url] and parses the result.
///
/// Build 2050 (audit C-2/C-3, F-H11/F-H12/F-H13): every failure
/// throws a [SubFetchException] with a specific, user-ready
/// message — never a raw exception for the UI to swallow. The
/// trust knobs are all scoped to THIS subscription:
/// - [certPin]: the SHA-256 of the one certificate to trust
///   for this subscription's host when the system chain rejects
///   it (a self-signed panel cert). Nothing global accepts it.
/// - [hwid]: sent as the `x-hwid` header when non-empty.
/// - [headers]: extra request headers (the fixed User-Agent is
///   the app's and cannot be overridden — panels pick the
///   response format by it).
/// - [hosts]: the user's custom DNS hosts (build 2041) — when
///   the URL's host is pinned there, the connection is made to
///   the pinned address with the name kept for TLS, so a
///   DNS-poisoned name still fetches.
/// - [fallbackUrl]: tried once when the primary fails with a
///   network error, a timeout, a DNS failure, or a 5xx.
/// Build 2147 (feature #1): the active session's local
/// proxy directive for subscription fetches ('SOCKS
/// 127.0.0.1:<port>'), maintained by XrayController while a
/// session is up and the fetchViaTunnel gate is on. '' =
/// direct fetches, as in every earlier build.
String subFetchProxyDirective = '';

Future<SubResult> fetchSubscription(
  String url, {
  String certPin = '',
  String hwid = '',
  Map<String, String> headers = const {},
  String fallbackUrl = '',
  Map<String, String> hosts = const {},
  Duration responseTimeout = const Duration(seconds: 30),
}) async {
  final uri = _validateSubUrl(url);
  try {
    return await _fetchOnce(
      uri,
      certPin: certPin,
      hwid: hwid,
      headers: headers,
      hosts: hosts,
      responseTimeout: responseTimeout,
    );
  } on SubFetchException catch (e) {
    final fb = fallbackUrl.trim();
    final worthRetry =
        e.kind == SubFetchErrorKind.network ||
        e.kind == SubFetchErrorKind.timeout ||
        e.kind == SubFetchErrorKind.dns ||
        (e.kind == SubFetchErrorKind.http && (e.statusCode ?? 0) >= 500);
    if (fb.isEmpty || !worthRetry || fb == url) rethrow;
    // One attempt on the fallback; ITS error is the fresher
    // truth when it also fails, so it is what propagates.
    final result = await _fetchOnce(
      _validateSubUrl(fb),
      certPin: certPin,
      hwid: hwid,
      headers: headers,
      hosts: hosts,
      responseTimeout: responseTimeout,
    );
    return SubResult(
      profiles: result.profiles,
      uploadBytes: result.uploadBytes,
      downloadBytes: result.downloadBytes,
      totalBytes: result.totalBytes,
      expireEpochSec: result.expireEpochSec,
      suggestedName: result.suggestedName,
      usedFallback: true,
      unsupportedSchemes: result.unsupportedSchemes,
    );
  }
}

/// Scheme + host validation BEFORE any socket opens (audit
/// C-3: the add path previously passed the raw string straight
/// to `Uri.parse`, so a malformed panel URL failed deep inside
/// the client with an unreadable error).
Uri _validateSubUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    throw SubFetchException(
      kind: SubFetchErrorKind.invalidUrl,
      message:
          'That is not a subscription URL — it must start '
          'with http:// or https:// and name a server.',
    );
  }
  return uri;
}

/// True when [text] is a subscription URL rather than a share
/// link (build 2094): an http(s) URL that names a document ON
/// a server — it carries a path (the token usually rides in
/// it) and/or a query. An HTTP-proxy share link
/// (`http://user:pass@host:port`) names the proxy itself and
/// carries neither, so it stays with the link parser, which
/// reads it as a proxy profile. The paste importer routes
/// subscription URLs to the fetcher; before build 2094 they
/// fell through to the link parser and silently added nothing.
bool isSubscriptionUrl(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || uri.host.isEmpty) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  return uri.hasQuery || uri.pathSegments.any((s) => s.isNotEmpty);
}

Future<SubResult> _fetchOnce(
  Uri uri, {
  required String certPin,
  required String hwid,
  required Map<String, String> headers,
  required Map<String, String> hosts,
  required Duration responseTimeout,
}) async {
  final pin = certPin.replaceAll(':', '').trim().toLowerCase();
  // The fingerprint of the certificate the server presented,
  // captured by the TLS callbacks below — a certificate
  // failure can then offer exactly that cert to trust.
  String? seenCertSha256;

  bool certDecision(X509Certificate cert, String host, int port) {
    final fp = sha256Hex(cert.der);
    seenCertSha256 = fp;
    if (pin.isEmpty) return false;
    // The pin trusts ONE certificate on the subscription's
    // OWN host:port — a redirect elsewhere never inherits it.
    return fp == pin &&
        host.toLowerCase() == uri.host.toLowerCase() &&
        port == uri.port;
  }

  final client = HttpClient();
  // Build 2147 (feature #1): the fetch-via-tunnel seam — the
  // controller sets [subFetchProxyDirective] while a session
  // is up and the gate is on; '' keeps every fetch direct,
  // byte-identical to every earlier build.
  if (subFetchProxyDirective.isNotEmpty) {
    client.findProxy = (_) => subFetchProxyDirective;
  }
  client.connectionTimeout = const Duration(seconds: 20);
  client.userAgent = 'v2rayNG/1.9.5 RalysndEmber/2.0';
  client.badCertificateCallback = certDecision;
  final pinnedIp = hosts[uri.host];
  if (pinnedIp != null && pinnedIp.isNotEmpty) {
    // Build 2041's custom hosts, honoured by the fetcher too
    // (audit F-H11): connect to the pinned address; the name
    // still rides the TLS handshake (SNI + verification), and
    // the certificate pin decision is the same one as above.
    client.connectionFactory = (u, proxyHost, proxyPort) async {
      final target = hosts[u.host] ?? u.host;
      final ip = target == u.host ? u.host : target;
      final socket = await Socket.connect(
        ip,
        u.port,
        timeout: const Duration(seconds: 20),
      );
      if (u.isScheme('https')) {
        final secure = await SecureSocket.secure(
          socket,
          host: u.host,
          onBadCertificate: (cert) => certDecision(cert, u.host, u.port),
        );
        return ConnectionTask.fromSocket(Future.value(secure), () {});
      }
      return ConnectionTask.fromSocket(Future.value(socket), () {});
    };
  }
  try {
    final request = await client.getUrl(uri);
    request.headers.set('accept', '*/*');
    if (hwid.isNotEmpty) request.headers.set('x-hwid', hwid);
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'user-agent') continue;
      request.headers.set(entry.key, entry.value);
    }
    // Build 2094: the wait for the response HEADERS is
    // bounded too — connectionTimeout covers only the socket
    // connect and the 30 s below covers the body, so a server
    // that accepted the connection and then never answered
    // hung the add sheet's spinner forever. A timeout here
    // classifies as the timeout kind, like the others.
    final response = await request.close().timeout(responseTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SubFetchException(
        kind: SubFetchErrorKind.http,
        message:
            'The server answered HTTP ${response.statusCode}'
            '${response.reasonPhrase.isEmpty ? '' : ' (${response.reasonPhrase})'} '
            'for ${uri.host} — the link may be wrong or expired.',
        statusCode: response.statusCode,
      );
    }
    final info = _parseUserInfo(
      response.headers.value('subscription-userinfo'),
    );
    final title = response.headers.value('profile-title');
    // Build 2095 (fourth-pass audit 1.1): the body is
    // byte-capped as it arrives — counted AFTER the
    // client's automatic decompression, so a gzip bomb
    // hits the same bound as a plain oversized body. A
    // feed that turns hostile after being added can no
    // longer OOM the app on every auto-refresh.
    final builder = BytesBuilder(copy: false);
    final bodyClock = Stopwatch()..start();
    // The stream timeout bounds an IDLE body (a server
    // that sends headers and then nothing) — the clock
    // below bounds the total; both survived from the
    // pre-2095 join().timeout() semantics (verification
    // loop catch: the first rewrite checked the clock
    // only when a chunk arrived).
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      // The pre-2095 total bound survives the rewrite: a
      // slow-drip body gets the same 30 s overall, not a
      // fresh window per chunk.
      if (bodyClock.elapsed > const Duration(seconds: 30)) {
        throw const SubFetchException(
          kind: SubFetchErrorKind.timeout,
          message: 'The subscription server took too long to answer.',
        );
      }
      builder.add(chunk);
      if (builder.length > kMaxSubscriptionBodyBytes) {
        throw const SubFetchException(
          kind: SubFetchErrorKind.format,
          message:
              'That subscription is too large to import '
              'safely (over 16 MB of configs).',
        );
      }
    }
    final body = const SystemEncoding().decode(builder.toBytes());
    final profiles = parseSubscription(body);
    if (profiles.isEmpty) {
      throw SubFetchException(
        kind: SubFetchErrorKind.format,
        message: emptyBodyMessage(detectSubBodyFormat(body)),
      );
    }
    return SubResult(
      profiles: profiles,
      uploadBytes: info.$1,
      downloadBytes: info.$2,
      totalBytes: info.$3,
      expireEpochSec: info.$4,
      suggestedName: _decodeTitle(title),
      unsupportedSchemes: unsupportedSchemesInBody(body),
    );
  } on SubFetchException {
    rethrow;
  } catch (e) {
    throw classifyFetchError(e, host: uri.host, certSha256: seenCertSha256);
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
  // Build 2095 (fourth-pass audit 1.5): the title becomes
  // a stored subscription name — strip control characters
  // at this entry point like every other name route.
  final clean = sanitizeProfileName(value);
  return clean.isEmpty ? null : clean;
}
