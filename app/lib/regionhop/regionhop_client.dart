/// RegionHop panel client (build 2139, leg 1): the small
/// HTTP client for the owner's own regionhop panel (the
/// Psiphon-exit manager running on his server), plus the
/// pure parsers for its payloads and for the bridge
/// credentials block. See regionhop_page.dart for the UI
/// and ~/workspace/regionhop-study/EMBER-INTEGRATION.md
/// for the panel API this speaks to.
///
/// Panel facts that shape this code (panel v1.28.0):
///  - Every route lives under a random path prefix; the
///    stored panel URL includes it. A wrong prefix is a
///    plain 404.
///  - Login is `POST <prefix>/login` with one form field,
///    `password`. Success is a 303 carrying the
///    `psi_session` cookie; a wrong password is a 200
///    login page with NO cookie — failure is detected by
///    the missing cookie, never by status.
///  - The panel locks an IP out for 5 minutes after 5
///    failed logins, so this client NEVER auto-retries a
///    login: one attempt per call, and on session expiry
///    exactly one re-login + one retry.
///  - The status payload's keys are CAPITALIZED (the
///    panel's row struct has no json tags); the probe
///    payload's keys are lowercase (it has them).
///
/// Build 2141 hardens the status fetch only: a 30 s
/// timeout, exactly one retry of the idempotent status
/// GET after a transport failure, and the failure kept in
/// sanitized form (class, exception type, OS error code)
/// on the thrown exception so the page can journal
/// exactly what the transport did. Login, the probe and
/// start/stop keep their 2139 shapes.
///
/// Build 2142: every request carries a browser-like
/// header set (see [regionHopBrowserUserAgent]) — on the
/// owner's carrier path the app's login flows and his
/// browser's identical URL fetch pass, while the bare
/// dart:io fingerprint's status requests hang to the
/// timeout — and the status fetch measures its phase
/// timings (open / response headers / body) so the page
/// can journal where a fetch spent its time.
///
/// Build 2143: the panel serves TLS now (the carrier
/// DPI-dropped the plain-HTTP status exchange on the
/// direct path — proven by the paired tests in the
/// build2143 record). The baked endpoint is self-signed,
/// so for that endpoint ONLY — https, the baked host and
/// port — every client is built on a [SecurityContext]
/// trusting the panel's embedded public certificate
/// (see [regionHopSecurityContextFor]). Any other base
/// URL keeps the plain default client, and there is no
/// badCertificateCallback anywhere: a wrong certificate
/// fails the handshake like any other TLS error.
///
/// The session cookie lives only in this object's memory.
/// Neither the password nor the cookie is ever logged,
/// journaled or persisted from here.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../xray/xray_models.dart';
import 'regionhop_defaults.dart';

/// The distinct failure states the page can show. Each
/// carries the plain-English line the design fixes for it;
/// none of them is ever silent.
enum RegionHopErrorKind { unreachable, notFound, loginFailed, lockout, badResponse }

class RegionHopException implements Exception {
  const RegionHopException(this.kind, this.message, {this.transport});

  final RegionHopErrorKind kind;
  final String message;

  /// The sanitized transport failure behind an
  /// [RegionHopErrorKind.unreachable] (build 2141); null
  /// for every other kind. Never the raw exception — its
  /// message embeds the panel's address.
  final RegionHopTransportFailure? transport;

  @override
  String toString() => message;
}

/// A transport failure in sanitized form (build 2141):
/// the coarse class, the exception's runtime type name,
/// and — for a [SocketException] — the OS error code
/// (111 refused, 104 reset, 110 timed out, 101 network
/// unreachable). That is all a journal line may carry:
/// the raw exception's message embeds the panel's
/// address, so it is never kept.
class RegionHopTransportFailure {
  const RegionHopTransportFailure({
    required this.clazz,
    required this.type,
    this.osErrorCode,
  });

  /// 'timeout' | 'socket' | 'http'.
  final String clazz;

  /// The exception's runtime type name ('TimeoutException',
  /// 'SocketException', 'HttpException').
  final String type;

  /// `SocketException.osError.errorCode`; null for the
  /// other classes and when the OS reported none.
  final int? osErrorCode;

  /// This failure in journal vocabulary: class, type and
  /// numeric tokens only.
  String get journalTokens =>
      osErrorCode == null ? '$clazz $type' : '$clazz $type os $osErrorCode';
}

/// The coarse transport class of a caught error
/// ('timeout' | 'socket' | 'http'), or null for anything
/// the client does not map to the unreachable state.
/// Shared by the sanitized failure capture (build 2141)
/// and the phase timings (build 2142).
String? _transportClassOf(Object error) {
  if (error is SocketException) return 'socket';
  if (error is TimeoutException) return 'timeout';
  if (error is HttpException) return 'http';
  return null;
}

/// Maps a caught transport error to the unreachable
/// state, keeping its sanitized shape (build 2141).
RegionHopException _transportFailure(Object error) {
  final clazz = _transportClassOf(error);
  if (clazz == null) return _unreachable;
  return RegionHopException(
    RegionHopErrorKind.unreachable,
    _unreachable.message,
    transport: RegionHopTransportFailure(
      clazz: clazz,
      type: error.runtimeType.toString(),
      osErrorCode: error is SocketException
          ? error.osError?.errorCode
          : null,
    ),
  );
}

/// The User-Agent every panel request carries (build
/// 2142): a current mobile Chrome, matching the owner's
/// phone. The panel does not care what it says — his
/// carrier path does: the browser's requests pass where
/// the bare `Dart/3.x (dart:io)` default's status
/// requests hang until the timeout (see the file
/// comment). The remaining browser-like headers
/// (`Accept`, `Accept-Language`) are set beside it in
/// _request.
const regionHopBrowserUserAgent =
    'Mozilla/5.0 (Linux; Android 16; POCO X6 Pro 5G) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/131.0.0.0 Mobile Safari/537.36';

/// Whether [baseUrl] is the baked panel endpoint over
/// TLS (build 2143): https, with the baked default's
/// host and port. The comparison derives from
/// [RegionHopDefaults.panelUrl] itself, so it tracks
/// the baked endpoint exactly and matches nothing else —
/// a user-entered URL on another host or port, an http
/// URL, or a loopback test fake never qualifies.
bool regionHopUsesPinnedContext(String baseUrl) {
  final uri = Uri.tryParse(baseUrl.trim());
  final baked = Uri.tryParse(RegionHopDefaults.panelUrl);
  if (uri == null || baked == null) return false;
  return uri.scheme == 'https' &&
      uri.host == baked.host &&
      uri.port == baked.port;
}

SecurityContext? _pinnedPanelContext;

/// The certificate-pinned [SecurityContext] for the
/// baked https panel endpoint (build 2143), or null for
/// every other base URL — the caller then builds the
/// plain default client exactly as before. The context
/// trusts the panel's embedded public certificate and
/// is built once and cached: every client for the baked
/// endpoint shares it.
SecurityContext? regionHopSecurityContextFor(String baseUrl) {
  if (!regionHopUsesPinnedContext(baseUrl)) return null;
  return _pinnedPanelContext ??= SecurityContext()
    ..setTrustedCertificatesBytes(
      utf8.encode(RegionHopDefaults.panelCertificatePem),
    );
}

/// The HTTP client factory every panel request goes
/// through (build 2143): pinned for the baked https
/// endpoint, the plain default for everything else.
HttpClient regionHopHttpClientFor(String baseUrl) {
  final context = regionHopSecurityContextFor(baseUrl);
  return context == null ? HttpClient() : HttpClient(context: context);
}

/// The status fetch's phase timings (build 2142): how
/// long each stage of the decisive status request took,
/// recorded by _request into a sink the fetch owns. A
/// completed phase keeps its milliseconds; a phase the
/// transport killed keeps the failure's coarse class
/// instead; a phase never reached stays null. Like the
/// transport failure, this is journal vocabulary —
/// numbers and class tokens only, never an address.
class RegionHopPhaseTimings {
  int? openMs;
  String? openFailure;
  int? headersMs;
  String? headersFailure;
  int? bodyMs;
  String? bodyFailure;

  /// Whether the status request was attempted at all
  /// (a login failure inside the fetch never reaches
  /// it, and reports nothing).
  bool get started => openMs != null || openFailure != null;

  static String _render(int? ms, String? failure) =>
      ms != null ? '$ms' : failure ?? '-';

  static String _shapeOf(int? ms, String? failure) =>
      ms != null ? 'ok' : failure ?? '-';

  /// This attempt in journal tokens:
  /// `open=312 headers=timeout body=-`.
  String get journalTokens =>
      'open=${_render(openMs, openFailure)} '
      'headers=${_render(headersMs, headersFailure)} '
      'body=${_render(bodyMs, bodyFailure)}';

  /// The attempt's outcome pattern (which phases
  /// completed, which failed how, which never ran) —
  /// the journal's transition signature, so a steady
  /// failure episode journals its phases once even
  /// though the numbers differ every poll.
  String get shape =>
      '${_shapeOf(openMs, openFailure)}/'
      '${_shapeOf(headersMs, headersFailure)}/'
      '${_shapeOf(bodyMs, bodyFailure)}';
}

const _unreachable = RegionHopException(
  RegionHopErrorKind.unreachable,
  'Panel unreachable — check the server and the panel URL.',
);
const _notFound = RegionHopException(
  RegionHopErrorKind.notFound,
  'Panel not found at this address — paste the full panel '
      'URL, including its path.',
);
const _loginFailed = RegionHopException(
  RegionHopErrorKind.loginFailed,
  'Panel login failed — check the password.',
);
const _lockout = RegionHopException(
  RegionHopErrorKind.lockout,
  'Too many failed logins — the panel locks for 5 minutes. '
      'Wait, then try once.',
);
const _badResponse = RegionHopException(
  RegionHopErrorKind.badResponse,
  'The panel answered in an unexpected way.',
);

/// One location row from `GET <prefix>/tunnels-status`.
class RegionHopLocation {
  const RegionHopLocation({
    required this.name,
    required this.region,
    required this.socksPort,
    required this.status,
    required this.statusClass,
    required this.exitRegion,
  });

  /// Location name (`^[a-z0-9][a-z0-9-]{1,30}$` panel-side).
  final String name;

  /// The configured egress label, `"<code> - <country>"`.
  final String region;

  /// The tunnel's loopback SOCKS port on the server.
  final int socksPort;

  /// The real state: `active` = tunnel established,
  /// otherwise the panel's class or systemd's state
  /// verbatim (`inactive`, `failed`, `activating`, …).
  final String status;

  /// The panel's collapsed class: active / connecting /
  /// inactive / unknown.
  final String statusClass;

  /// The label of the region the tunnel actually landed
  /// on ('' until connected).
  final String exitRegion;

  bool get isActive => status == 'active';

  bool get isConnecting =>
      statusClass == 'connecting' || status == 'activating';

  /// The leading code token of [exitRegion] ('' if none).
  String get exitCode => regionHopExitCode(exitRegion);

  /// The status chip's label for this row.
  String get chipLabel => regionHopChipLabel(status, statusClass);
}

/// One probe result from
/// `GET <prefix>/tunnels/<name>/test?mode=…` — the only
/// source of a location's exit IP.
class RegionHopProbe {
  const RegionHopProbe({
    required this.ok,
    required this.latencyMs,
    required this.ip,
    required this.google,
    required this.detail,
  });

  final bool ok;
  final int latencyMs;

  /// The exit address as seen through the tunnel
  /// ('' unless [ok]).
  final String ip;
  final String google;
  final String detail;
}

/// One bridge credentials line: the GOST relay the phone
/// connects to for a location.
class RegionHopRelay {
  const RegionHopRelay({
    required this.name,
    required this.port,
    required this.user,
    required this.password,
  });

  final String name;
  final int port;
  final String user;
  final String password;
}

/// The outcome of parsing a credentials block: the valid
/// lines by location name, plus one plain-English problem
/// per malformed line (with its line number).
class RegionHopRelayBlock {
  const RegionHopRelayBlock(this.relays, this.errors);

  final Map<String, RegionHopRelay> relays;
  final List<String> errors;
}

/// The relay port mirrors the tunnel's loopback SOCKS
/// port at a fixed offset (the bridge's port plan).
int regionHopRelayPortFor(int socksPort) => socksPort + 7000;

/// The leading code token of an exit-region label
/// (`"DE - Germany"` → `"DE"`); a label without the
/// separator comes through raw, '' stays ''.
String regionHopExitCode(String exitRegion) {
  final t = exitRegion.trim();
  if (t.isEmpty) return '';
  final dash = t.indexOf(' - ');
  return (dash > 0 ? t.substring(0, dash) : t).trim();
}

/// The status chip's label for a status pair.
String regionHopChipLabel(String status, String statusClass) {
  if (statusClass == 'active' || status == 'active') return 'Active';
  if (statusClass == 'connecting' || status == 'activating') {
    return 'Connecting';
  }
  if (status == 'failed') return 'Failed';
  if (statusClass == 'inactive' || status == 'inactive') return 'Stopped';
  return 'Unknown';
}

/// Parses the panel's status payload (capitalized keys —
/// see the file comment). Throws [FormatException] on a
/// shape the panel would never send.
List<RegionHopLocation> parseRegionHopStatus(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! List) {
    throw const FormatException('status payload is not a list');
  }
  return [for (final row in decoded) _parseRegionHopRow(row)];
}

RegionHopLocation _parseRegionHopRow(Object? row) {
  if (row is! Map) {
    throw const FormatException('status row is not an object');
  }
  String str(String key) => row[key]?.toString() ?? '';
  final rawPort = row['SocksPort'];
  return RegionHopLocation(
    name: str('Name'),
    region: str('Region'),
    socksPort: rawPort is num
        ? rawPort.toInt()
        : int.tryParse(str('SocksPort')) ?? 0,
    status: str('Status'),
    statusClass: str('StatusClass'),
    exitRegion: str('ExitRegion'),
  );
}

/// Parses a probe payload (lowercase keys — see the file
/// comment). Throws [FormatException] on a bad shape.
RegionHopProbe parseRegionHopProbe(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) {
    throw const FormatException('probe payload is not an object');
  }
  final latency = decoded['latencyMs'];
  return RegionHopProbe(
    ok: decoded['ok'] == true,
    latencyMs: latency is num ? latency.toInt() : 0,
    ip: decoded['ip']?.toString() ?? '',
    google: decoded['google']?.toString() ?? '',
    detail: decoded['detail']?.toString() ?? '',
  );
}

/// Parses the bridge credentials block: one line per
/// location, `name port user password`. Blank lines are
/// skipped; a malformed line is reported with its line
/// number and never silently dropped or half-parsed.
RegionHopRelayBlock parseRegionHopRelays(String block) {
  final relays = <String, RegionHopRelay>{};
  final errors = <String>[];
  final lines = block.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length != 4) {
      errors.add('Line ${i + 1}: expected "name port user password".');
      continue;
    }
    final port = int.tryParse(parts[1]);
    if (port == null || port <= 0 || port > 65535) {
      errors.add('Line ${i + 1}: "${parts[1]}" is not a port.');
      continue;
    }
    relays[parts[0]] = RegionHopRelay(
      name: parts[0],
      port: port,
      user: parts[2],
      password: parts[3],
    );
  }
  return RegionHopRelayBlock(relays, errors);
}

/// Why [location] cannot be connected right now, or null
/// when it can. [relay] is the location's parsed
/// credentials line (null = none pasted). The port
/// cross-check is an error state of its own in the
/// design: a relay port that is not the panel's SOCKS
/// port + 7000 means the pasted line is stale.
String? regionHopConnectBlock(
  RegionHopLocation location,
  RegionHopRelay? relay,
) {
  if (relay == null) {
    return 'Bridge not set up for this location — paste its '
        'credentials line.';
  }
  if (relay.port != regionHopRelayPortFor(location.socksPort)) {
    return "Bridge credentials don't match the panel's port "
        'for this location — paste the line from the latest '
        'setup.';
  }
  if (!location.isActive) {
    if (location.isConnecting) return 'Tunnel is still connecting…';
    if (location.status == 'failed') {
      return 'Tunnel failed — Start it to try again.';
    }
    return 'Tunnel is stopped — Start it first.';
  }
  return null;
}

/// The host the relays live on: the panel URL's host (the
/// relays are on the same box as the panel).
String regionHopPanelHost(String panelUrl) =>
    Uri.tryParse(panelUrl.trim())?.host ?? '';

/// The managed SOCKS profile a Connect upserts for
/// [location] — an ordinary profile on the existing store
/// shape, so the whole session rides the existing
/// connect machinery (see the design doc §3).
Profile regionHopManagedProfile({
  required RegionHopLocation location,
  required RegionHopRelay relay,
  required String host,
}) {
  return Profile(
    id: 'regionhop-${location.name}',
    name: 'RegionHop · ${location.region}',
    protocol: Protocol.socks,
    address: host,
    port: relay.port,
    username: relay.user,
    uuidOrPassword: relay.password,
  );
}

class _PanelResponse {
  const _PanelResponse(this.statusCode, this.body, this.setCookies, this.location);

  final int statusCode;
  final String body;
  final List<String>? setCookies;
  final String? location;
}

/// The panel API client. One instance per panel
/// URL + password pair; the session cookie is held in
/// memory only.
class RegionHopClient {
  RegionHopClient({
    required String panelUrl,
    required String password,
    this.statusTimeout = const Duration(seconds: 30),
    this.statusRetryDelay = const Duration(seconds: 2),
  }) : _base = _normalizeBase(panelUrl),
       _panelPassword = password;

  final String _base;
  final String _panelPassword;

  /// How long one status fetch may take (build 2141: the
  /// panel's cold status compute measured 2.7 s, and the
  /// old 10 s cap left too little room on a slow path).
  /// A constructor knob so tests can shrink it; production
  /// always uses the 30 s default.
  final Duration statusTimeout;

  /// The pause before the status fetch's single retry
  /// (build 2141). A test seam like [statusTimeout].
  final Duration statusRetryDelay;

  /// Called when a status-fetch attempt fails on the
  /// transport and the fetch is about to retry (build
  /// 2141), so the page can journal the transition. The
  /// failure is sanitized — never the panel URL, a
  /// credential or an address. The client itself still
  /// never journals.
  void Function(RegionHopTransportFailure failure)? onStatusRetry;

  /// Called exactly once per [fetchStatus], at its
  /// conclusion, with the final attempt's phase timings
  /// (build 2142) — and only when the status request was
  /// actually attempted: a login failure inside the
  /// fetch never reaches it and reports nothing. The
  /// timings are journal vocabulary (numbers and class
  /// tokens only). The client itself still never
  /// journals.
  void Function(RegionHopPhaseTimings phases, {required bool ok})?
      onStatusPhases;

  String? _cookie;
  bool _everLoggedIn = false;

  bool get loggedIn => _cookie != null;

  static String _normalizeBase(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  Future<_PanelResponse> _request(
    String method,
    String path, {
    Map<String, String>? form,
    bool auth = false,
    Duration timeout = const Duration(seconds: 10),
    RegionHopPhaseTimings? phases,
  }) async {
    // Build 2143: the factory pins the panel's
    // certificate for the baked https endpoint only;
    // every other base URL gets the default client.
    final client = regionHopHttpClientFor(_base)
      ..connectionTimeout = const Duration(seconds: 8)
      // Build 2142: the browser-like header set starts at
      // the client, so no request can fall back to the
      // dart:io default User-Agent.
      ..userAgent = regionHopBrowserUserAgent;
    // Build 2142: one stopwatch for the whole request;
    // each phase's milliseconds come out by subtraction.
    // The sink is reset first: an expiry re-request
    // through _authed reuses it, and it must describe the
    // last request only, never a mix of two.
    if (phases != null) {
      phases
        ..openMs = null
        ..openFailure = null
        ..headersMs = null
        ..headersFailure = null
        ..bodyMs = null
        ..bodyFailure = null;
    }
    final watch = phases == null ? null : (Stopwatch()..start());
    try {
      final HttpClientRequest request;
      try {
        request = await client.openUrl(method, Uri.parse('$_base$path')).timeout(timeout);
      } on TimeoutException catch (e) {
        phases?.openFailure = _transportClassOf(e);
        throw _transportFailure(e);
      } on SocketException catch (e) {
        phases?.openFailure = _transportClassOf(e);
        throw _transportFailure(e);
      } on HttpException catch (e) {
        phases?.openFailure = _transportClassOf(e);
        throw _transportFailure(e);
      }
      phases?.openMs = watch?.elapsedMilliseconds;
      // Redirects are never auto-followed: the login 303
      // carries the cookie, and a 303 to /login on an
      // authed call is the session-expiry signal.
      request.followRedirects = false;
      // Build 2142: the browser-like header set, on every
      // request (the User-Agent is set here too, so the
      // header is right even if a client-level default is
      // ever bypassed).
      request.headers.set(
        HttpHeaders.userAgentHeader,
        regionHopBrowserUserAgent,
      );
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      request.headers.set(
        HttpHeaders.acceptLanguageHeader,
        'en-US,en;q=0.9',
      );
      if (auth && _cookie != null) {
        request.headers.set(HttpHeaders.cookieHeader, _cookie!);
      }
      if (form != null) {
        request.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
        );
        request.write(Uri(queryParameters: form).query);
      }
      final HttpClientResponse response;
      try {
        response = await request.close().timeout(timeout);
      } on TimeoutException catch (e) {
        phases?.headersFailure = _transportClassOf(e);
        throw _transportFailure(e);
      } on SocketException catch (e) {
        phases?.headersFailure = _transportClassOf(e);
        throw _transportFailure(e);
      } on HttpException catch (e) {
        phases?.headersFailure = _transportClassOf(e);
        throw _transportFailure(e);
      }
      if (phases != null) {
        phases.headersMs =
            watch!.elapsedMilliseconds - (phases.openMs ?? 0);
      }
      final setCookies = response.headers[HttpHeaders.setCookieHeader];
      final location = response.headers.value(HttpHeaders.locationHeader);
      final String body;
      try {
        body = await response.transform(utf8.decoder).join().timeout(timeout);
      } on TimeoutException catch (e) {
        phases?.bodyFailure = _transportClassOf(e);
        throw _transportFailure(e);
        // Build 2141: a reset or protocol failure mid-body
        // is the same transport failure as at open/close —
        // before this build it escaped as a raw exception
        // the page could not map to the unreachable state.
      } on SocketException catch (e) {
        phases?.bodyFailure = _transportClassOf(e);
        throw _transportFailure(e);
      } on HttpException catch (e) {
        phases?.bodyFailure = _transportClassOf(e);
        throw _transportFailure(e);
      }
      if (phases != null) {
        phases.bodyMs =
            watch!.elapsedMilliseconds -
            (phases.openMs ?? 0) -
            (phases.headersMs ?? 0);
      }
      return _PanelResponse(response.statusCode, body, setCookies, location);
    } finally {
      client.close(force: true);
    }
  }

  static String? _sessionCookie(List<String>? setCookies) {
    if (setCookies == null) return null;
    for (final header in setCookies) {
      if (header.startsWith('psi_session=')) {
        final end = header.indexOf(';');
        return end < 0 ? header : header.substring(0, end);
      }
    }
    return null;
  }

  /// One login attempt — never retried automatically
  /// (the panel's lockout counts attempts per IP). The
  /// GET first proves host, port and prefix in one shot:
  /// the login page answers 200 at the right address and
  /// 404 anywhere else.
  Future<void> login() async {
    final probe = await _request('GET', '/login');
    if (probe.statusCode != 200) throw _notFound;
    final response = await _request(
      'POST',
      '/login',
      form: {'password': _panelPassword},
    );
    final cookie = _sessionCookie(response.setCookies);
    if (cookie == null) {
      // No cookie: a wrong password — or, when this same
      // password already worked in this client's life,
      // the panel's 5-minute lockout answering instead.
      throw _everLoggedIn ? _lockout : _loginFailed;
    }
    _cookie = cookie;
    _everLoggedIn = true;
  }

  bool _isExpiry(_PanelResponse response, {required bool expectJson}) {
    if (response.statusCode == 303 &&
        (response.location?.contains('/login') ?? false)) {
      return true;
    }
    // HTML where JSON was expected is the login page
    // served in place of the payload.
    if (expectJson &&
        response.statusCode == 200 &&
        response.body.trimLeft().startsWith('<')) {
      return true;
    }
    return false;
  }

  /// An authed call with the design's expiry rule:
  /// exactly one silent re-login and exactly one retry,
  /// then the failure surfaces.
  Future<_PanelResponse> _authed(
    String method,
    String path, {
    bool expectJson = false,
    Duration timeout = const Duration(seconds: 10),
    RegionHopPhaseTimings? phases,
  }) async {
    if (_cookie == null) await login();
    var response = await _request(
      method,
      path,
      auth: true,
      timeout: timeout,
      phases: phases,
    );
    if (_isExpiry(response, expectJson: expectJson)) {
      _cookie = null;
      await login();
      response = await _request(
        method,
        path,
        auth: true,
        timeout: timeout,
        phases: phases,
      );
      if (_isExpiry(response, expectJson: expectJson)) throw _loginFailed;
    }
    return response;
  }

  /// The live location list. Build 2141: one fetch may
  /// take [statusTimeout] (was 10 s), and a TRANSPORT
  /// failure earns exactly one retry after
  /// [statusRetryDelay] — the GET is idempotent. A
  /// panel-side answer (bad response, an expiry loop) is
  /// never retried here, and the retry never re-runs a
  /// login beyond the rule inside [_authed]: a login
  /// failure (wrong password, lockout) surfaces as its
  /// own kind, not as unreachable, so it is not retried
  /// either. Build 2142: the final attempt's phase
  /// timings are reported once at the conclusion (see
  /// [onStatusPhases]).
  Future<List<RegionHopLocation>> fetchStatus() async {
    // Build 2142: each attempt measures into its own
    // timings sink; the conclusion reports the FINAL
    // attempt's phases once (see onStatusPhases).
    var phases = RegionHopPhaseTimings();
    try {
      final rows = await _fetchStatusOnce(phases: phases);
      _reportStatusPhases(phases, ok: true);
      return rows;
    } on RegionHopException catch (e) {
      if (e.kind != RegionHopErrorKind.unreachable) {
        _reportStatusPhases(phases, ok: false);
        rethrow;
      }
      final failure = e.transport;
      if (failure != null) onStatusRetry?.call(failure);
      await Future<void>.delayed(statusRetryDelay);
      phases = RegionHopPhaseTimings();
      try {
        final rows = await _fetchStatusOnce(phases: phases);
        _reportStatusPhases(phases, ok: true);
        return rows;
      } on RegionHopException {
        _reportStatusPhases(phases, ok: false);
        rethrow;
      }
    }
  }

  /// The one conclusion report per fetch (build 2142) —
  /// silent when the status request was never attempted
  /// (a login failure inside the fetch).
  void _reportStatusPhases(RegionHopPhaseTimings phases, {required bool ok}) {
    if (!phases.started) return;
    onStatusPhases?.call(phases, ok: ok);
  }

  Future<List<RegionHopLocation>> _fetchStatusOnce({
    RegionHopPhaseTimings? phases,
  }) async {
    final response = await _authed(
      'GET',
      '/tunnels-status',
      expectJson: true,
      timeout: statusTimeout,
      phases: phases,
    );
    if (response.statusCode != 200) throw _badResponse;
    try {
      return parseRegionHopStatus(response.body);
    } on FormatException {
      throw _badResponse;
    }
  }

  /// The exit-IP probe for one location (mode `real` —
  /// the closest to real use). On demand only: the panel
  /// can take ~18 s inside the request.
  Future<RegionHopProbe> probe(String name) async {
    final response = await _authed(
      'GET',
      '/tunnels/${Uri.encodeComponent(name)}/test?mode=real',
      expectJson: true,
      timeout: const Duration(seconds: 25),
    );
    if (response.statusCode != 200) throw _badResponse;
    try {
      return parseRegionHopProbe(response.body);
    } on FormatException {
      throw _badResponse;
    }
  }

  /// Starts a location. The panel has no start endpoint;
  /// its restart starts an inactive unit (see the design
  /// doc §1 for the reboot caveat this inherits).
  Future<void> restart(String name) => _action(name, 'restart');

  /// Stops a location (`systemctl disable --now`).
  Future<void> stop(String name) => _action(name, 'stop');

  Future<void> _action(String name, String action) async {
    final response = await _authed(
      'POST',
      '/tunnels/${Uri.encodeComponent(name)}/$action',
      timeout: const Duration(seconds: 15),
    );
    if (response.statusCode != 303 && response.statusCode != 200) {
      throw _badResponse;
    }
  }
}
