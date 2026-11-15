/// The Cloudflare clean-IP scanner (build 2026, Stage A of the
/// MLM port): finds Cloudflare edge IPs that answer from THIS
/// network, for the user's own Cloudflare-fronted configs.
///
/// The technique is MLM's CfEdge + WorkerRoute, ported:
///
/// - Candidates come from a curated set of Cloudflare edge
///   ranges known to answer from filtered networks, plus a seed
///   list of individually proven IPs (both below, from MLM's
///   published source).
/// - A candidate ANSWERS when a TCP connect succeeds, a TLS
///   handshake with the target host as SNI completes, and the
///   host replies with any HTTP status line to a HEAD request —
///   CfEdge's exact definition of an answering edge.
/// - For a *.workers.dev host, the candidate set also includes
///   the host's own DNS-over-HTTPS-resolved addresses
///   (WorkerRoute's per-IP route health check): a worker's
///   domain may resolve to edges outside the curated ranges.
///
/// Nothing here touches the user's profiles; the scanner page
/// applies a chosen IP to a profile's address explicitly, and
/// only where the protocol allows it (the SNI/Host stay as they
/// are — that is what makes the address swappable at all).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Wide Cloudflare ranges (CfEdge's WIDE set).
const cfWideRanges = <String>[
  '104.16.0.0/14',
  '104.24.0.0/15',
  '172.64.0.0/15',
  '172.67.0.0/16',
];

/// Regional Cloudflare ranges (CfEdge's REGIONAL set).
const cfRegionalRanges = <String>[
  '188.114.96.0/22',
  '104.21.0.0/16',
  '104.27.0.0/16',
];

/// Individually proven seed IPs (CfEdge's seed list).
const cfSeedIps = <String>[
  '104.16.113.28',
  '104.16.179.102',
  '104.17.120.41',
  '104.17.190.119',
  '104.18.127.54',
  '104.18.201.136',
  '104.19.134.67',
  '104.19.212.153',
  '104.24.169.132',
  '104.25.176.145',
  '172.64.82.98',
  '172.65.91.105',
  '172.67.109.119',
  '104.21.234.187',
  '188.114.97.101',
  '188.114.98.150',
];

int _ipv4ToInt(String ip) {
  final parts = ip.split('.').map(int.parse).toList();
  return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
}

String _intToIpv4(int v) =>
    '${(v >> 24) & 0xFF}.${(v >> 16) & 0xFF}.${(v >> 8) & 0xFF}.${v & 0xFF}';

/// (network address, host-bit count) of an IPv4 CIDR.
(int, int) _cidrParts(String cidr) {
  final slash = cidr.indexOf('/');
  final base = _ipv4ToInt(cidr.substring(0, slash));
  final prefix = int.parse(cidr.substring(slash + 1));
  return (base, 32 - prefix);
}

/// True when [ip] lies inside [cidr]. A malformed address is
/// simply outside (this judges strings it did not produce).
bool ipInCidr(String ip, String cidr) {
  try {
    if (ip.split('.').length != 4) return false;
    final (base, hostBits) = _cidrParts(cidr);
    final mask = hostBits == 32 ? 0 : (0xFFFFFFFF << hostBits) & 0xFFFFFFFF;
    return (_ipv4ToInt(ip) & mask) == (base & mask);
  } catch (_) {
    return false;
  }
}

/// A random address inside [cidr] (network/broadcast addresses
/// included in the space are harmless: they simply never
/// answer a probe).
String sampleIpInCidr(String cidr, Random rng) {
  final (base, hostBits) = _cidrParts(cidr);
  final mask = hostBits == 32 ? 0 : (0xFFFFFFFF << hostBits) & 0xFFFFFFFF;
  final span = hostBits == 32 ? 1 : 1 << hostBits;
  return _intToIpv4((base & mask) + rng.nextInt(span));
}

/// The default candidate set: the seeds (proven before, so
/// probed first) plus fresh samples from every curated range.
/// [rng] is injectable so tests can pin the sampling.
List<String> cfCandidates(
  Random rng, {
  int perWide = 6,
  int perRegional = 4,
  List<String> extraFirst = const [],
}) {
  final seen = <String>{};
  final out = <String>[];
  void add(String ip) {
    if (seen.add(ip)) out.add(ip);
  }

  for (final ip in extraFirst) {
    add(ip);
  }
  for (final ip in cfSeedIps) {
    add(ip);
  }
  for (final range in cfWideRanges) {
    for (var i = 0; i < perWide; i++) {
      add(sampleIpInCidr(range, rng));
    }
  }
  for (final range in cfRegionalRanges) {
    for (var i = 0; i < perRegional; i++) {
      add(sampleIpInCidr(range, rng));
    }
  }
  return out;
}

/// One answering edge: the IP and how fast its HTTP status line
/// came back (ms).
class CfProbeResult {
  const CfProbeResult(this.ip, this.ms);
  final String ip;
  final int ms;
}

/// Probes one candidate [ip] for [host] the CfEdge way: TCP
/// connect, TLS handshake with SNI [host], then a HEAD request —
/// any HTTP status line counts as an answer. Returns the time
/// to the status line in ms, or -1 when the edge does not
/// answer inside [timeout] per stage.
Future<int> probeCfEdge(
  String ip,
  String host, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final sw = Stopwatch()..start();
  Socket? raw;
  SecureSocket? secure;
  try {
    raw = await Socket.connect(ip, 443, timeout: timeout);
    secure = await SecureSocket.secure(
      raw,
      host: host,
      onBadCertificate: (_) => true,
    ).timeout(timeout);
    raw = null; // Owned by the secure socket now.
    secure.write('HEAD / HTTP/1.1\r\nHost: $host\r\n'
        'User-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n');
    await secure.flush();
    final first = await secure
        .cast<List<int>>()
        .transform(utf8.decoder)
        .firstWhere((chunk) => chunk.contains('HTTP/'))
        .timeout(timeout);
    return first.isEmpty ? -1 : sw.elapsedMilliseconds;
  } catch (_) {
    return -1;
  } finally {
    secure?.destroy();
    raw?.destroy();
  }
}

/// Resolves [host]'s A records through dns.google's
/// DNS-over-HTTPS (the system resolver is not consulted — on a
/// filtered network its answers are the poisoned ones).
/// Best-effort: an empty list on any failure.
Future<List<String>> resolveViaDoh(String host) async {
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    final uri = Uri.https('dns.google', '/resolve', {
      'name': host,
      'type': 'A',
    });
    final request = await client.getUrl(uri);
    request.headers.set('accept', 'application/dns-json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final doc = jsonDecode(body) as Map<String, dynamic>;
    final answers = (doc['Answer'] as List?) ?? const [];
    return [
      for (final a in answers)
        if (a is Map && a['type'] == 1) a['data'] as String,
    ];
  } catch (_) {
    return const [];
  } finally {
    client?.close(force: true);
  }
}

/// Probes [candidates] for [host] with bounded parallelism,
/// reporting progress as results land. Returns the answering
/// edges fastest-first. Stops early when [cancelled] says so;
/// un-probed candidates are simply absent from the result.
Future<List<CfProbeResult>> scanCfEdges({
  required List<String> candidates,
  required String host,
  int width = 12,
  void Function(int done, int total, List<CfProbeResult> found)? onProgress,
  bool Function()? cancelled,
}) async {
  final found = <CfProbeResult>[];
  var done = 0;
  var index = 0;

  bool stop() => cancelled?.call() ?? false;

  Future<void> worker() async {
    while (index < candidates.length && !stop()) {
      final ip = candidates[index++];
      final ms = await probeCfEdge(ip, host);
      done++;
      if (ms >= 0) {
        found.add(CfProbeResult(ip, ms));
        found.sort((a, b) => a.ms.compareTo(b.ms));
      }
      onProgress?.call(done, candidates.length, List.of(found));
    }
  }

  await Future.wait([for (var i = 0; i < width; i++) worker()]);
  found.sort((a, b) => a.ms.compareTo(b.ms));
  return found;
}
