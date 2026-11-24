/// Remote DPI Lab strategies (build 2114; owner pick:
/// "Remote / community DPI strategy updates" — DPIMech
/// 0.3.0/0.4.0's over-the-air strategy list).
///
/// New evasion strategies arrive from a community feed as
/// DATA, without an app update. The trust shape is narrow
/// on purpose:
///
/// - a feed entry can only recombine the shaping layer's
///   existing mechanisms (a fragment geometry, the
///   unfilter / ECH / mixed-SNI / TCP-noise switches, the
///   watchdog's dialMode preset) — it names nothing the
///   shipped code does not already implement, and every
///   value is range-checked here before it is installed;
/// - entries live in the 'r-' id namespace, so a feed can
///   never shadow a shipped candidate or fragment shape;
/// - an entry that violates any rule is dropped whole —
///   never repaired, never partially applied;
/// - installed strategies join the Lab's candidate set and
///   are consulted exactly like the shipped ones, which
///   means they apply only while the Lab master toggle
///   (XraySettings.dpiLabEnabled) is on.
///
/// The feed document and the store document share one
/// shape: {"version": 1, "strategies": [ … ]}. The store
/// carries the installed set so a restart (and a backup
/// restore) keeps it; the controller installs it BEFORE
/// parsing the Lab memory, whose win validation consults
/// the registry.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'anti_filter.dart';
import 'dpi_lab.dart';

/// The community strategy feed: the project repository's
/// own list, so a strategy update is a data commit, not a
/// release. Nothing is fetched until the user taps Check
/// for updates on the Lab page.
const dpiStrategyFeedUrl =
    'https://raw.githubusercontent.com/Mojdee12/ralysnd-ember/main/dpi-strategies.json';

/// The feed body cap: the whole strategy space is a few
/// kilobytes; anything larger is not a strategy list.
const dpiStrategyFeedMaxBytes = 256 * 1024;

/// At most this many strategies install from one document.
const dpiStrategyMaxCount = 32;

final _bareIdPattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,39}$');
final _lengthPattern = RegExp(r'^\d{1,5}(-\d{1,5})?$');
// Build 2126 (D7): delays accept the same Int32Range
// form lengths already did — the core resolves a range
// per segment (crypto.RandBetween), so a feed strategy
// can ship randomized geometry.
final _delayPattern = RegExp(r'^\d{1,5}(-\d{1,5})?$');
final _maxSplitPattern = RegExp(r'^\d{1,3}$');

/// A feed failure with a user-ready message (the sub_fetcher
/// rule: never a raw exception for the UI to swallow).
class DpiStrategyFeedException implements Exception {
  const DpiStrategyFeedException(this.message);

  final String message;

  @override
  String toString() => message;
}

bool _cleanText(String s, int max) =>
    s.length <= max &&
    !s.codeUnits.any((u) => u < 0x20 || u == 0x7F);

/// One fragment segment length: a byte count ('300') or a
/// range ('100-200'), each end within the ClientHello's
/// plausible span.
bool _validLength(String s) {
  if (!_lengthPattern.hasMatch(s)) return false;
  final parts = s.split('-');
  final lo = int.parse(parts[0]);
  final hi = parts.length == 2 ? int.parse(parts[1]) : lo;
  return lo <= 8192 && hi <= 8192 && lo <= hi;
}

bool _validDelay(String s) {
  if (!_delayPattern.hasMatch(s)) return false;
  final parts = s.split('-');
  final lo = int.parse(parts[0]);
  final hi = parts.length == 2 ? int.parse(parts[1]) : lo;
  return lo <= 10000 && hi <= 10000 && lo <= hi;
}

/// Parses one feed entry into a strategy, or null when ANY
/// rule is violated — the entry is dropped whole.
DpiRemoteStrategy? _parseDpiRemoteStrategy(Object? raw) {
  if (raw is! Map) return null;
  final id = raw['id'];
  if (id is! String || !_bareIdPattern.hasMatch(id)) return null;
  final label = raw['label'];
  if (label is! String || label.isEmpty || !_cleanText(label, 60)) {
    return null;
  }
  final detailRaw = raw['detail'];
  if (detailRaw != null &&
      (detailRaw is! String || !_cleanText(detailRaw, 160))) {
    return null;
  }
  final detail = detailRaw is String ? detailRaw : '';
  final shape = raw['shape'];
  if (shape is! Map) return null;
  const shapeKeys = {
    'fragment',
    'unfilter',
    'ech',
    'mixedSni',
    'tcpNoise',
    'dialMode',
  };
  for (final k in shape.keys) {
    if (!shapeKeys.contains(k)) return null;
  }

  AfFragmentShape? fragment;
  final fragRaw = shape['fragment'];
  if (fragRaw != null) {
    if (fragRaw is! Map) return null;
    for (final k in fragRaw.keys) {
      if (k != 'lengths' && k != 'delays' && k != 'maxSplit') return null;
    }
    final lengthsRaw = fragRaw['lengths'];
    final delaysRaw = fragRaw['delays'];
    if (lengthsRaw is! List ||
        lengthsRaw.isEmpty ||
        lengthsRaw.length > 8 ||
        delaysRaw is! List ||
        delaysRaw.isEmpty ||
        delaysRaw.length > 8) {
      return null;
    }
    final lengths = <String>[];
    for (final l in lengthsRaw) {
      if (l is! String || !_validLength(l)) return null;
      lengths.add(l);
    }
    final delays = <String>[];
    for (final d in delaysRaw) {
      if (d is! String || !_validDelay(d)) return null;
      delays.add(d);
    }
    var maxSplit = '';
    final msRaw = fragRaw['maxSplit'];
    if (msRaw != null) {
      if (msRaw is! String) return null;
      if (msRaw.isNotEmpty &&
          (!_maxSplitPattern.hasMatch(msRaw) || int.parse(msRaw) > 64)) {
        return null;
      }
      maxSplit = msRaw;
    }
    fragment = AfFragmentShape(
      'r-$id',
      label,
      lengths,
      delays,
      maxSplit: maxSplit,
    );
  }

  bool flag(String key) {
    final v = shape[key];
    return v == true;
  }

  // A switch that is present but not a boolean invalidates
  // the entry — silently coercing a hostile "yes" would be
  // a repair, and repairs are not this parser's job.
  for (final k in ['unfilter', 'ech', 'mixedSni', 'tcpNoise']) {
    final v = shape[k];
    if (v != null && v is! bool) return null;
  }
  final unfilter = flag('unfilter');
  final ech = flag('ech');
  final mixedSni = flag('mixedSni');
  final tcpNoise = flag('tcpNoise');

  var dialMode = '';
  final dmRaw = shape['dialMode'];
  if (dmRaw != null) {
    // The watchdog's preset is the only dial mode a feed
    // may name (shapes.dart's watchdogDialModePreset).
    if (dmRaw is! String || (dmRaw.isNotEmpty && dmRaw != 'oob.0')) {
      return null;
    }
    dialMode = dmRaw;
  }

  // ECH and the unfilter shape are mutually exclusive in
  // the shaping layer (ECH suppresses the unfilter mask);
  // an entry claiming both is incoherent.
  if (ech && unfilter) return null;
  // An entry must shape SOMETHING.
  if (fragment == null &&
      !unfilter &&
      !ech &&
      !mixedSni &&
      !tcpNoise &&
      dialMode.isEmpty) {
    return null;
  }

  // TLS-only is DERIVED, never feed-claimed: a strategy
  // whose shaping lives in the TLS layer (or is the
  // dialMode escalation, which the shipped set also marks
  // TLS-only) is offered only where the shaping layer runs.
  final tlsOnly =
      fragment != null || unfilter || ech || mixedSni || dialMode.isNotEmpty;
  return DpiRemoteStrategy(
    candidate: DpiLabCandidate('r-$id', label, detail, tlsOnly: tlsOnly),
    fragment: fragment,
    unfilter: unfilter,
    ech: ech,
    mixedSni: mixedSni,
    tcpNoise: tcpNoise,
    dialMode: dialMode,
  );
}

/// The strategies a feed/store document carries: every
/// entry validated on its own, invalid ones dropped,
/// duplicate ids keep the first, the count capped.
List<DpiRemoteStrategy> parseDpiStrategiesJson(Object? doc) {
  if (doc is! Map) return const [];
  final list = doc['strategies'];
  if (list is! List) return const [];
  final out = <DpiRemoteStrategy>[];
  final seen = <String>{};
  for (final raw in list) {
    if (out.length >= dpiStrategyMaxCount) break;
    final s = _parseDpiRemoteStrategy(raw);
    if (s == null || !seen.add(s.candidate.id)) continue;
    out.add(s);
  }
  return out;
}

/// The store/feed document for [strategies] — the canonical
/// re-serialisation of what validation accepted, so what is
/// persisted is exactly what was installed.
Map<String, dynamic> dpiRemoteStrategiesToJson(
  List<DpiRemoteStrategy> strategies,
) => {
  'version': 1,
  'strategies': [
    for (final s in strategies)
      {
        'id': s.candidate.id.substring(2),
        'label': s.candidate.label,
        'detail': s.candidate.detail,
        'shape': {
          if (s.fragment != null)
            'fragment': {
              'lengths': s.fragment!.lengths,
              'delays': s.fragment!.delays,
              if (s.fragment!.maxSplit.isNotEmpty)
                'maxSplit': s.fragment!.maxSplit,
            },
          if (s.unfilter) 'unfilter': true,
          if (s.ech) 'ech': true,
          if (s.mixedSni) 'mixedSni': true,
          if (s.tcpNoise) 'tcpNoise': true,
          if (s.dialMode.isNotEmpty) 'dialMode': s.dialMode,
        },
      },
  ],
};

/// Reads a stored strategy document (the controller's load
/// paths). A corrupt document reads as no strategies.
List<DpiRemoteStrategy> dpiRemoteStrategiesFromJson(Object? raw) =>
    parseDpiStrategiesJson(raw);

/// Fetches the community feed's raw body: https only (the
/// URL is a shipped constant), bounded waits, byte-capped
/// as it arrives (the sub_fetcher discipline).
///
/// Build 2125 (audit A25-55): when a session is up, the
/// caller passes its local HTTP proxy ([proxy], the
/// updater's 2098 pattern) — the feed host is unreachable
/// direct from exactly the networks the Lab exists for.
/// The failure text is a clean user-ready line; raw
/// exception text never reaches the page.
Future<String> fetchDpiStrategyFeedBody({
  String? proxy,
  ({String user, String pass})? proxyCredentials,
}) async {
  final uri = Uri.parse(dpiStrategyFeedUrl);
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 20);
  client.userAgent = 'v2rayNG/1.9.5 RalysndEmber/2.0';
  if (proxy != null) {
    client.findProxy = (_) => 'PROXY $proxy';
    // Build 2126 (audit A26-20): the session proxy's
    // credentials, when its inbound demands them — the
    // updater registers these for its own proxy path
    // (build 2098, V-3); up to 2125 this fetch never
    // did, so behind a password-protected local proxy
    // the feed died on the proxy's 407 while the
    // updater's identical route worked.
    if (proxyCredentials != null) {
      final cut = proxy.lastIndexOf(':');
      final host = cut > 0 ? proxy.substring(0, cut) : proxy;
      final port = cut > 0 ? int.tryParse(proxy.substring(cut + 1)) : null;
      if (port != null) {
        client.addProxyCredentials(
          host,
          port,
          '',
          HttpClientBasicCredentials(
            proxyCredentials.user,
            proxyCredentials.pass,
          ),
        );
      }
    }
  }
  try {
    final request = await client.getUrl(uri);
    request.headers.set('accept', 'application/json');
    final response = await request.close().timeout(
      const Duration(seconds: 30),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DpiStrategyFeedException(
        'The strategy feed answered HTTP ${response.statusCode} '
        '— try again later.',
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(
      const Duration(seconds: 30),
    )) {
      builder.add(chunk);
      if (builder.length > dpiStrategyFeedMaxBytes) {
        throw const DpiStrategyFeedException(
          'The strategy feed is too large to accept safely.',
        );
      }
    }
    return utf8.decode(builder.toBytes());
  } on DpiStrategyFeedException {
    rethrow;
  } catch (_) {
    // Build 2125 (A25-55): a clean line, never the raw
    // exception (socket text named internals and read as
    // a crash, not a network failure).
    throw const DpiStrategyFeedException(
      'Could not reach the strategy feed — check your '
      'connection and try again.',
    );
  } finally {
    client.close(force: true);
  }
}

/// Parses a fetched feed body into validated strategies.
/// A body that is not JSON at all is a feed failure, not an
/// empty list — the user is told the update failed rather
/// than that the feed is empty.
///
/// Build 2125 (audit A25-54): the document's shape and
/// `version` are checked before anything is taken from
/// it — a document from a newer feed format, or one
/// missing its strategy list entirely, is a feed failure,
/// NOT an empty install (an empty install silently
/// uninstalled every community strategy).
List<DpiRemoteStrategy> parseDpiStrategyFeedBody(String body) {
  final Object? doc;
  try {
    doc = jsonDecode(body);
  } catch (_) {
    throw const DpiStrategyFeedException(
      'The strategy feed is not valid JSON.',
    );
  }
  if (doc is! Map) {
    throw const DpiStrategyFeedException(
      'The strategy feed is not a strategy document.',
    );
  }
  final version = doc['version'];
  if (version is num && version > 1) {
    throw DpiStrategyFeedException(
      'The strategy feed uses format version '
      '${version.toInt()}, which this build cannot read — '
      'update the app to receive new strategies.',
    );
  }
  if (doc['strategies'] is! List) {
    throw const DpiStrategyFeedException(
      'The strategy feed is missing its strategy list.',
    );
  }
  return parseDpiStrategiesJson(doc);
}
