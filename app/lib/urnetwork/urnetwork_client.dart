/// URnetwork source client (build 2154): the small HTTP
/// client for the URnetwork operator API
/// (https://api.bringyour.com), the pure parsers for its
/// payloads, the account record the app keeps per
/// URnetwork account, and the managed-profile builders
/// that turn an account's hosted proxies into ordinary
/// Ember profiles.
///
/// The contract was pinned firsthand from
/// https://ur.io/docs-md/api.md and the OpenAPI spec at
/// https://ur.io/openapi.yml (see
/// ~/workspace/ember-app/build2154-progress.md for the
/// full record). The shapes that shape this code:
///
///  - Auth is one long-lived `urn_` API key per account,
///    sent as `Authorization: Bearer <key>`. The key
///    lives ONLY in the SecretStore vault (see
///    [urNetworkVaultKey]); it is never written to the
///    settings document, never journaled, and never
///    appears in any message this file produces — the
///    parsers and the client speak about accounts by
///    label and proxies by country, never by credential.
///  - `GET /network/proxies` lists the account's hosted
///    proxies and is EMPTY until one is created. Each row
///    carries a `proxy_client` (host, ports, auth token,
///    and — when the plan issued one — a full WireGuard
///    config as text in `wg_config.config`).
///  - Creation is `POST /network/auth-client` with a
///    `proxy_config` (there is no POST /network/proxies).
///    Refusals (proxy cap, create rate, plan limits)
///    answer HTTP 200 WITH an `error` object in the body,
///    so every answer's body is checked, not just its
///    status.
///  - A unique-exit proxy's row carries its `exit`
///    (country code, region, city) — the only location
///    the list ever reports. A plain proxy's country is
///    the one chosen at creation, which the account
///    record keeps per proxy id.
///  - `GET /subscription/balance` carries the top-level
///    byte totals plus one entry per active balance
///    (the daily credit, a Pro balance, …), each with
///    its own start/remaining byte counts.
///
/// The per-proxy `auth_token` is a proxy credential of
/// exactly the class every profile's password already
/// is: it lives in the managed profiles it belongs to.
/// The account API key never does.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../regionhop/regionhop_client.dart' show regionHopBrowserUserAgent;
import '../xray/exit_info.dart' show englishCountryNames;
import '../xray/wg_conf.dart' show parseWgConf;
import '../xray/xray_models.dart';

/// The API origin every URnetwork call goes to.
const urNetworkApiBase = 'https://api.bringyour.com';

/// The SecretStore vault key holding [accountId]'s API
/// key. Raw-key pattern, like 'sync_github_token': the
/// settings-secret vault prefix is for XraySettings
/// fields, and an account key is not one — it never
/// enters the settings document at all.
String urNetworkVaultKey(String accountId) =>
    'urnetwork_api_key_$accountId';

/// The managed-profile id prefix every URnetwork profile
/// carries: `urnetwork-<accountId>-<proxyId>-<kind>`.
/// Account ids are minted dash-free (see
/// [urNewAccountId]), so the segments parse back
/// unambiguously.
const urProfileIdPrefix = 'urnetwork-';

/// Mints an account id: dash-free, so it can ride inside
/// a managed profile id (see [urProfileIdPrefix]).
String urNewAccountId(int nowMs, int ordinal) =>
    'u${nowMs.toRadixString(36)}x$ordinal';

/// The managed profile id for one proxy endpoint kind.
String urProfileId(String accountId, String proxyId, String kind) =>
    '$urProfileIdPrefix$accountId-$proxyId-$kind';

/// Whether [id] belongs to the URnetwork source.
bool isUrProfileId(String id) => id.startsWith(urProfileIdPrefix);

/// The account id inside a managed profile [id]
/// ('' when [id] is not one).
String urAccountIdOfProfileId(String id) {
  if (!isUrProfileId(id)) return '';
  final rest = id.substring(urProfileIdPrefix.length);
  final dash = rest.indexOf('-');
  return dash < 0 ? rest : rest.substring(0, dash);
}

/// The English name for an ISO country code (the code
/// itself when the table does not know it).
String urCountryName(String code) =>
    englishCountryNames[code.toUpperCase()] ?? code.toUpperCase();

/// Bytes in the plain display form the source card and
/// the account rows use ("9.8 TB", "28.4 GB", "512 MB").
/// Latin digits, one decimal under 100.
String urFormatBytes(int bytes) {
  if (bytes < 0) return '—';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024.0;
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[i]}';
}

/// The distinct failure states the page can show. Each
/// carries the plain-English line the UI shows; none of
/// them is ever silent, and none ever carries a key, a
/// token or an address.
enum UrErrorKind { keyRefused, unreachable, badResponse, api }

class UrNetworkException implements Exception {
  const UrNetworkException(this.kind, this.message);

  final UrErrorKind kind;
  final String message;

  @override
  String toString() => message;
}

const _keyRefused = UrNetworkException(
  UrErrorKind.keyRefused,
  'URnetwork refused the API key — check the key for this account.',
);
const _unreachable = UrNetworkException(
  UrErrorKind.unreachable,
  'URnetwork is unreachable — check the connection and try again.',
);
const _badResponse = UrNetworkException(
  UrErrorKind.badResponse,
  'URnetwork answered in an unexpected way.',
);

/// One URnetwork account as the app keeps it. Everything
/// here is metadata — the API key is NOT part of this
/// record (see [urNetworkVaultKey]). The record rides in
/// the settings document as JSON (XraySettings
/// .urNetworkAccounts), so it survives in backups like
/// every other setting; a restored record without its
/// vault key simply fails its next refresh with the
/// key-refused line until the owner pastes the key again.
class UrAccount {
  UrAccount({
    required this.id,
    required this.label,
    this.lastRefreshMs = 0,
    this.lastAttemptMs = 0,
    this.balanceBytes = -1,
    this.balanceStartBytes = -1,
    this.balances = const [],
    this.pro = false,
    this.planName = '',
    this.proxyCountries = const {},
  });

  final String id;

  /// The owner's label ('' = unnamed; the UI falls back
  /// to "Account N").
  String label;

  /// The last successful refresh (epoch ms; 0 = never).
  int lastRefreshMs;

  /// The last refresh ATTEMPT (epoch ms; 0 = never) —
  /// the auto-refresh sweep's backoff stamp.
  int lastAttemptMs;

  /// The last known total remaining bytes (-1 = the
  /// balance was never read or did not answer).
  int balanceBytes;

  /// The last known total start bytes (-1 like above).
  int balanceStartBytes;

  /// The last known per-balance rows.
  List<UrBalanceEntry> balances;

  /// Whether the account held Pro at the last balance
  /// read (or proxy list, whose plan block says the
  /// same).
  bool pro;

  /// The subscription plan name the balance carried
  /// (e.g. "supporter"; '' when unknown).
  String planName;

  /// proxy_id → ISO country code chosen at creation,
  /// for the proxies whose list row carries no exit.
  Map<String, String> proxyCountries;

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'lastRefreshMs': lastRefreshMs,
        'lastAttemptMs': lastAttemptMs,
        'balanceBytes': balanceBytes,
        'balanceStartBytes': balanceStartBytes,
        'balances': [for (final b in balances) b.toJson()],
        'pro': pro,
        'planName': planName,
        'proxyCountries': proxyCountries,
      };

  /// Defensive: a damaged record degrades to what can be
  /// read, never throws — the settings document must
  /// always load.
  static UrAccount? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    int asInt(Object? v, int fallback) =>
        v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? fallback;
    final balances = <UrBalanceEntry>[];
    final rawBalances = raw['balances'];
    if (rawBalances is List) {
      for (final b in rawBalances) {
        final entry = UrBalanceEntry.fromJson(b);
        if (entry != null) balances.add(entry);
      }
    }
    final countries = <String, String>{};
    final rawCountries = raw['proxyCountries'];
    if (rawCountries is Map) {
      for (final e in rawCountries.entries) {
        final v = e.value?.toString() ?? '';
        if (v.isNotEmpty) countries[e.key.toString()] = v;
      }
    }
    return UrAccount(
      id: id,
      label: raw['label']?.toString() ?? '',
      lastRefreshMs: asInt(raw['lastRefreshMs'], 0),
      lastAttemptMs: asInt(raw['lastAttemptMs'], 0),
      balanceBytes: asInt(raw['balanceBytes'], -1),
      balanceStartBytes: asInt(raw['balanceStartBytes'], -1),
      balances: balances,
      pro: raw['pro'] == true,
      planName: raw['planName']?.toString() ?? '',
      proxyCountries: countries,
    );
  }
}

/// The account records inside the settings document's
/// JSON string ('' / damaged → no accounts).
List<UrAccount> decodeUrAccounts(String stored) {
  if (stored.trim().isEmpty) return [];
  try {
    final decoded = jsonDecode(stored);
    if (decoded is! List) return [];
    return [
      for (final raw in decoded)
        if (UrAccount.fromJson(raw) case final account?) account,
    ];
  } on FormatException {
    return [];
  }
}

/// The settings-document form of [accounts].
String encodeUrAccounts(List<UrAccount> accounts) =>
    jsonEncode([for (final a in accounts) a.toJson()]);

/// One active balance on an account (the daily credit,
/// a Pro balance, a paid data code…).
class UrBalanceEntry {
  const UrBalanceEntry({
    required this.pro,
    required this.paid,
    required this.startBytes,
    required this.balanceBytes,
    required this.endTime,
  });

  final bool pro;
  final bool paid;
  final int startBytes;
  final int balanceBytes;

  /// When this balance's window ends ('' when the API
  /// did not say).
  final String endTime;

  /// The row's plain label: a Pro balance, a paid data
  /// balance, or the daily credit.
  String get label => pro ? 'Pro' : (paid ? 'Data' : 'Daily');

  Map<String, Object?> toJson() => {
        'pro': pro,
        'paid': paid,
        'startBytes': startBytes,
        'balanceBytes': balanceBytes,
        'endTime': endTime,
      };

  static UrBalanceEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    int asInt(Object? v) =>
        v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? -1;
    return UrBalanceEntry(
      pro: raw['pro'] == true,
      paid: raw['paid'] == true,
      startBytes: asInt(raw['startBytes']),
      balanceBytes: asInt(raw['balanceBytes']),
      endTime: raw['endTime']?.toString() ?? '',
    );
  }
}

/// A parsed `GET /subscription/balance` answer.
class UrBalance {
  const UrBalance({
    required this.totalBytes,
    required this.startBytes,
    required this.entries,
    required this.planName,
    required this.store,
  });

  /// Top-level remaining / initial bytes (-1 when the
  /// answer did not carry them).
  final int totalBytes;
  final int startBytes;
  final List<UrBalanceEntry> entries;

  /// `current_subscription.plan` ('' when absent).
  final String planName;

  /// `current_subscription.store` ('' when absent).
  final String store;

  bool get pro => entries.any((e) => e.pro);
}

/// Parses a balance payload. Defensive throughout: any
/// field may be missing, and a missing total stays -1 —
/// the UI then shows nothing rather than a fake number.
UrBalance parseUrBalance(Object? decoded) {
  // A null payload is the no-answer shape: the empty
  // balance (every figure unknown), not an error.
  if (decoded == null) {
    return const UrBalance(
      totalBytes: -1,
      startBytes: -1,
      entries: [],
      planName: '',
      store: '',
    );
  }
  if (decoded is! Map) throw const FormatException('balance is not an object');
  int asInt(Object? v) =>
      v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? -1;
  final entries = <UrBalanceEntry>[];
  final rawEntries = decoded['active_transfer_balances'];
  if (rawEntries is List) {
    for (final raw in rawEntries) {
      if (raw is! Map) continue;
      entries.add(
        UrBalanceEntry(
          pro: raw['pro'] == true,
          paid: raw['paid'] == true,
          startBytes: asInt(raw['start_balance_byte_count']),
          balanceBytes: asInt(raw['balance_byte_count']),
          endTime: raw['end_time']?.toString() ?? '',
        ),
      );
    }
  }
  var planName = '';
  var store = '';
  final sub = decoded['current_subscription'];
  if (sub is Map) {
    planName = sub['plan']?.toString() ?? '';
    store = sub['store']?.toString() ?? '';
  }
  return UrBalance(
    totalBytes: asInt(decoded['balance_byte_count']),
    startBytes: asInt(decoded['start_balance_byte_count']),
    entries: entries,
    planName: planName,
    store: store,
  );
}

/// One hosted proxy's exit (unique-exit proxies only).
class UrExit {
  const UrExit({
    required this.countryCode,
    required this.region,
    required this.city,
    required this.state,
    required this.exitId,
  });

  /// Two-letter country code, lower case as the API
  /// sends it ('' when it did not).
  final String countryCode;
  final String region;
  final String city;

  /// assigned | replacing | no_supply ('' when absent).
  final String state;
  final String exitId;
}

/// One hosted proxy from `GET /network/proxies`.
class UrProxy {
  const UrProxy({
    required this.clientId,
    required this.proxyId,
    required this.host,
    required this.httpPort,
    required this.httpsPort,
    required this.socksPort,
    required this.authToken,
    required this.wgConfigText,
    required this.exit,
    required this.proFeatures,
  });

  /// The network client id — the delete/rotate handle.
  final String clientId;

  /// The proxy's own id — the managed-profile id segment.
  final String proxyId;
  final String host;
  final int httpPort;
  final int httpsPort;
  final int socksPort;

  /// The proxy credential (see the file comment: it
  /// lives in the managed profiles, nowhere else).
  final String authToken;

  /// The full WireGuard config text when the plan
  /// issued one ('' when it did not).
  final String wgConfigText;

  /// The exit, for a unique-exit proxy (null otherwise).
  final UrExit? exit;

  /// The Pro features the proxy holds credentials for
  /// ('socks_proxy', 'wireguard_proxy'; may be absent).
  final List<String> proFeatures;
}

/// A parsed `GET /network/proxies` answer.
class UrProxiesResult {
  const UrProxiesResult({
    required this.proxies,
    required this.pro,
    required this.proFeaturesEnforced,
  });

  final List<UrProxy> proxies;

  /// The plan block (null when the answer omitted it).
  final bool? pro;
  final bool? proFeaturesEnforced;
}

int _asPort(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

UrExit? _parseUrExit(Object? raw) {
  if (raw is! Map) return null;
  return UrExit(
    countryCode: raw['country_code']?.toString() ?? '',
    region: raw['region']?.toString() ?? '',
    city: raw['city']?.toString() ?? '',
    state: raw['state']?.toString() ?? '',
    exitId: raw['exit_id']?.toString() ?? '',
  );
}

/// Parses one `proxy_client` object (shared by the list
/// rows and the create answer's `proxy_config_result`).
UrProxy? parseUrProxyClient(Object? raw, {String fallbackClientId = ''}) {
  if (raw is! Map) return null;
  final proxyId = raw['proxy_id']?.toString() ?? '';
  final host = raw['proxy_host']?.toString() ?? '';
  if (proxyId.isEmpty || host.isEmpty) return null;
  final wg = raw['wg_config'];
  var wgText = '';
  if (wg is Map) wgText = wg['config']?.toString() ?? '';
  return UrProxy(
    clientId: raw['client_id']?.toString() ?? fallbackClientId,
    proxyId: proxyId,
    host: host,
    httpPort: _asPort(raw['http_proxy_port']),
    httpsPort: _asPort(raw['https_proxy_port']),
    socksPort: _asPort(raw['socks_proxy_port']),
    authToken: raw['auth_token']?.toString() ?? '',
    wgConfigText: wgText,
    exit: null,
    proFeatures: const [],
  );
}

/// Parses the proxies payload. Rows without a usable
/// `proxy_client` are skipped (a plain network client
/// rides the same list shape on /network/clients; on
/// /network/proxies every row should carry one, but a
/// row that does not is not a proxy we can build).
UrProxiesResult parseUrProxies(Object? decoded) {
  if (decoded is! Map) {
    throw const FormatException('proxies payload is not an object');
  }
  final proxies = <UrProxy>[];
  final rows = decoded['clients'];
  if (rows is List) {
    for (final row in rows) {
      if (row is! Map) continue;
      final client = parseUrProxyClient(row['proxy_client']);
      if (client == null) continue;
      final features = <String>[];
      final rawFeatures = row['pro_features'];
      if (rawFeatures is List) {
        for (final f in rawFeatures) {
          final name = f?.toString() ?? '';
          if (name.isNotEmpty) features.add(name);
        }
      }
      proxies.add(
        UrProxy(
          clientId: row['client_id']?.toString() ?? client.clientId,
          proxyId: client.proxyId,
          host: client.host,
          httpPort: client.httpPort,
          httpsPort: client.httpsPort,
          socksPort: client.socksPort,
          authToken: client.authToken,
          wgConfigText: client.wgConfigText,
          exit: _parseUrExit(row['exit']),
          proFeatures: features,
        ),
      );
    }
  }
  bool? pro;
  bool? enforced;
  final plan = decoded['plan'];
  if (plan is Map) {
    if (plan['pro'] is bool) pro = plan['pro'] as bool;
    if (plan['pro_features_enforced'] is bool) {
      enforced = plan['pro_features_enforced'] as bool;
    }
  }
  return UrProxiesResult(
    proxies: proxies,
    pro: pro,
    proFeaturesEnforced: enforced,
  );
}

/// One country row of the provider-locations catalogue.
class UrCountry {
  const UrCountry({
    required this.locationId,
    required this.name,
    required this.countryCode,
    required this.providerCount,
  });

  final String locationId;

  /// The catalogue's own country name ("Germany").
  final String name;

  /// ISO code as the catalogue sends it ("DE").
  final String countryCode;
  final int providerCount;
}

/// Parses the locations payload down to its country
/// rows (the create flow picks a country; regions and
/// cities ride the same list and are not offered).
List<UrCountry> parseUrCountries(Object? decoded) {
  if (decoded is! Map) {
    throw const FormatException('locations payload is not an object');
  }
  final countries = <UrCountry>[];
  final rows = decoded['locations'];
  if (rows is List) {
    for (final row in rows) {
      if (row is! Map) continue;
      if (row['location_type']?.toString() != 'country') continue;
      final code = row['country_code']?.toString() ?? '';
      final id = row['location_id']?.toString() ?? '';
      if (code.isEmpty || id.isEmpty) continue;
      countries.add(
        UrCountry(
          locationId: id,
          name: row['country']?.toString().isNotEmpty == true
              ? row['country'].toString()
              : (row['name']?.toString() ?? urCountryName(code)),
          countryCode: code,
          providerCount: _asPort(row['provider_count']),
        ),
      );
    }
  }
  countries.sort((a, b) => a.name.compareTo(b.name));
  return countries;
}

/// The country a proxy's profiles are named for: its
/// exit's country when it has one, else the country
/// chosen at creation, else '' (the profiles then carry
/// the plain "UR · Proxy" name).
String urProxyCountryCode(UrAccount account, UrProxy proxy) {
  final exitCode = proxy.exit?.countryCode ?? '';
  if (exitCode.isNotEmpty) return exitCode;
  return account.proxyCountries[proxy.proxyId] ?? '';
}

/// The display name every profile of one proxy shares
/// before its kind tag: `UR · Germany`, with the exit
/// city when the exit names one, the account label when
/// the owner runs several accounts, and a plain ordinal
/// when one account holds several proxies in one
/// country.
String urProxyBaseName({
  required UrAccount account,
  required UrProxy proxy,
  required bool multiAccount,
  required int sameCountryOrdinal,
}) {
  final code = urProxyCountryCode(account, proxy);
  var name = code.isEmpty ? 'UR · Proxy' : 'UR · ${urCountryName(code)}';
  final city = proxy.exit?.city ?? '';
  if (city.isNotEmpty) name += ' · $city';
  if (multiAccount && account.label.isNotEmpty) {
    name += ' · ${account.label}';
  }
  if (sameCountryOrdinal > 1) name += ' $sameCountryOrdinal';
  return name;
}

/// The managed profiles one proxy becomes: a SOCKS5
/// profile and an HTTP profile on the plain ports the
/// API returns, an HTTPS profile (HTTP over TLS to the
/// proxy) on the HTTPS port, and — when the plan issued
/// a WireGuard config — the WireGuard profile(s) its
/// text parses to. Kinds whose port the API did not
/// return are skipped, never faked.
List<Profile> urProfilesForProxy({
  required UrAccount account,
  required UrProxy proxy,
  required bool multiAccount,
  required int sameCountryOrdinal,
}) {
  final base = urProxyBaseName(
    account: account,
    proxy: proxy,
    multiAccount: multiAccount,
    sameCountryOrdinal: sameCountryOrdinal,
  );
  final profiles = <Profile>[];
  if (proxy.socksPort > 0) {
    profiles.add(
      Profile(
        id: urProfileId(account.id, proxy.proxyId, 'socks'),
        name: '$base · SOCKS',
        protocol: Protocol.socks,
        address: proxy.host,
        port: proxy.socksPort,
        username: proxy.authToken,
        uuidOrPassword: '',
      ),
    );
  }
  if (proxy.httpPort > 0) {
    profiles.add(
      Profile(
        id: urProfileId(account.id, proxy.proxyId, 'http'),
        name: '$base · HTTP',
        protocol: Protocol.http,
        address: proxy.host,
        port: proxy.httpPort,
        username: proxy.authToken,
        uuidOrPassword: '',
      ),
    );
  }
  if (proxy.httpsPort > 0) {
    profiles.add(
      Profile(
        id: urProfileId(account.id, proxy.proxyId, 'https'),
        name: '$base · HTTPS',
        protocol: Protocol.http,
        address: proxy.host,
        port: proxy.httpsPort,
        username: proxy.authToken,
        uuidOrPassword: '',
        security: 'tls',
        sni: proxy.host,
      ),
    );
  }
  if (proxy.wgConfigText.trim().isNotEmpty) {
    var n = 0;
    final parsed = parseWgConf(
      proxy.wgConfigText,
      baseName: base,
      idFor: () {
        n += 1;
        return urProfileId(
          account.id,
          proxy.proxyId,
          n == 1 ? 'wg' : 'wg$n',
        );
      },
    );
    if (parsed.ok) {
      for (var i = 0; i < parsed.profiles.length; i++) {
        final p = parsed.profiles[i];
        p.name = parsed.profiles.length == 1
            ? '$base · WG'
            : '$base · WG ${i + 1}';
        profiles.add(p);
      }
    }
  }
  return profiles;
}

/// One HTTP exchange with the API, as the transport
/// seam returns it. Tests inject a fake transport; the
/// production transport is [_ioUrTransport].
class UrHttpResponse {
  const UrHttpResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

/// The transport seam: one request, headers included
/// (the client builds them — the Authorization header
/// among them — so a test can prove where the key goes
/// and where it never does).
typedef UrTransport = Future<UrHttpResponse> Function(
  String method,
  Uri uri, {
  Map<String, String> headers,
  String? jsonBody,
});

/// The production transport (dart:io, browser-like
/// header set — the carrier lesson the RegionHop client
/// learned: a bare Dart fingerprint hangs on the owner's
/// path where a browser's passes).
Future<UrHttpResponse> _ioUrTransport(
  String method,
  Uri uri, {
  Map<String, String> headers = const {},
  String? jsonBody,
  Duration timeout = const Duration(seconds: 25),
}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent = regionHopBrowserUserAgent;
  try {
    final request = await client.openUrl(method, uri).timeout(timeout);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    if (jsonBody != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonBody);
    }
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    return UrHttpResponse(response.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

/// The URnetwork API client for ONE account. Holds the
/// account's key in memory only, for the client's life.
class UrNetworkClient {
  UrNetworkClient({required String apiKey, UrTransport? transport})
      : _apiKey = apiKey,
        _transport = transport ?? _ioUrTransport;

  final String _apiKey;
  final UrTransport _transport;

  Future<Object?> _request(
    String method,
    String path, {
    Map<String, Object?>? jsonBody,
  }) async {
    final UrHttpResponse response;
    try {
      response = await _transport(
        method,
        Uri.parse('$urNetworkApiBase$path'),
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer $_apiKey',
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.userAgentHeader: regionHopBrowserUserAgent,
        },
        jsonBody: jsonBody == null ? null : jsonEncode(jsonBody),
      );
    } on SocketException {
      throw _unreachable;
    } on TimeoutException {
      throw _unreachable;
    } on HttpException {
      throw _unreachable;
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw _keyRefused;
    }
    // Any other non-200: the API (or something in front
    // of it) answered, just not in a way this client can
    // use — that is the bad-response state, not silence.
    if (response.statusCode != 200) throw _badResponse;
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw _badResponse;
    }
    // Refusals ride a 200 with an error object (see the
    // file comment) — the server's own message is the
    // plain line the UI shows; it never carries the key.
    if (decoded is Map) {
      final error = decoded['error'];
      if (error is Map) {
        final message = error['message']?.toString() ?? '';
        throw UrNetworkException(
          UrErrorKind.api,
          message.isNotEmpty ? message : _badResponse.message,
        );
      }
    }
    return decoded;
  }

  /// The account's hosted proxies and its plan block.
  Future<UrProxiesResult> fetchProxies() async {
    final decoded = await _request('GET', '/network/proxies');
    try {
      return parseUrProxies(decoded);
    } on FormatException {
      throw _badResponse;
    }
  }

  /// The account's balances. A balance that will not
  /// parse degrades to an empty read (the card then
  /// shows no balance) rather than failing the refresh
  /// that asked for it alongside the proxies.
  Future<UrBalance?> fetchBalanceOrNull() async {
    try {
      final decoded = await _request('GET', '/subscription/balance');
      return parseUrBalance(decoded);
    } on FormatException {
      return null;
    } on UrNetworkException {
      return null;
    }
  }

  /// The country catalogue (provider locations, country
  /// rows only).
  Future<List<UrCountry>> fetchCountries() async {
    final decoded = await _request('GET', '/network/provider-locations');
    try {
      return parseUrCountries(decoded);
    } on FormatException {
      throw _badResponse;
    }
  }

  /// Creates one hosted proxy. Exactly one of
  /// [countryCode] / [bestAvailable] picks the location.
  /// WireGuard is always requested (the plan decides
  /// whether a config is issued). Returns the created
  /// proxy as the answer carries it; the caller re-lists
  /// afterwards so the store mirrors the account.
  Future<UrProxy> createProxy({
    String? countryCode,
    bool bestAvailable = false,
    bool uniqueExit = false,
  }) async {
    final state = <String, Object?>{};
    if (bestAvailable) {
      state['location'] = {
        'connect_location_id': {'best_available': true},
      };
    } else if (countryCode != null && countryCode.isNotEmpty) {
      state['country_code'] = countryCode.toLowerCase();
    } else {
      throw ArgumentError('createProxy needs a country or bestAvailable');
    }
    final decoded = await _request(
      'POST',
      '/network/auth-client',
      jsonBody: {
        'proxy_config': {
          'enable_wg': true,
          if (uniqueExit) 'unique_exit': true,
          if (uniqueExit) 'unique_exit_replace': 'auto',
          'initial_device_state': state,
        },
      },
    );
    if (decoded is! Map) throw _badResponse;
    final clientId = decoded['client_id']?.toString() ?? '';
    final proxy = parseUrProxyClient(
      decoded['proxy_config_result'],
      fallbackClientId: clientId,
    );
    if (proxy == null) throw _badResponse;
    final exit = _parseUrExit(
      (decoded['proxy_config_result'] as Map?)?['exit'],
    );
    return UrProxy(
      clientId: proxy.clientId.isEmpty ? clientId : proxy.clientId,
      proxyId: proxy.proxyId,
      host: proxy.host,
      httpPort: proxy.httpPort,
      httpsPort: proxy.httpsPort,
      socksPort: proxy.socksPort,
      authToken: proxy.authToken,
      wgConfigText: proxy.wgConfigText,
      exit: exit,
      proFeatures: proxy.proFeatures,
    );
  }

  /// Removes one hosted proxy from the account.
  Future<void> removeProxy(String clientId) async {
    await _request(
      'POST',
      '/network/remove-client',
      jsonBody: {'client_id': clientId},
    );
  }

  /// Rotates a unique-exit proxy to a new exit; returns
  /// the new exit when the answer carries one.
  Future<UrExit?> rotateExit(String clientId) async {
    final decoded = await _request(
      'POST',
      '/network/proxy/rotate-exit',
      jsonBody: {'client_id': clientId},
    );
    if (decoded is Map) return _parseUrExit(decoded['exit']);
    return null;
  }
}
