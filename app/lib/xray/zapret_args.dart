// The Zapret (ciadpi) desync proxy's command lines (build
// 2127, H1), one per DPI Lab zap candidate. Pure and
// testable; the native side (ZapretCore.kt) only spawns
// what it is given.
//
// The engine is ciadpi — ByeDPI (hufrea/ByeDPI) at the
// pinned commit in engines/byedpi/PROVENANCE.md — a
// userspace SOCKS5 proxy that desyncs the FIRST bytes of
// each TCP stream with ordinary socket calls (segment
// splits at SNI-relative positions, TLS record splits,
// disorder, out-of-band bytes, and a fake first segment
// sent with a dying TTL). It needs no root, no NFQUEUE,
// no raw sockets: everything the nfqws engine does below
// the stream layer (bad-checksum fakes, sequence overlap
// on the real stream, RST injection, IP fragmentation,
// QUIC CRYPTO-frame splitting) stays out of reach on
// Android and is NOT claimed by these candidates.
//
// Two flags are never emitted: `-I`/`--conn-ip` (a
// host-test-only bind dodge) and `-Y`/`--drop-sack`
// (SO_ATTACH_FILTER) — see the provenance file.

/// The fixed local listen port (mirrored in Kotlin:
/// ZapretCore.PORT; 20864 verified free against every
/// other engine's port).
const zapretListenPort = 20864;

/// The zap candidate ids, in Lab probe order.
const zapretCandidateIds = <String>[
  'zap-split',
  'zap-tlsrec',
  'zap-fake',
  'zap-disorder',
  'zap-oob',
  'zap-disoob',
];

/// True when [candidateId] is a zap candidate — its probe
/// and its connect both need the proxy running.
bool isZapretCandidate(String candidateId) =>
    zapretCandidateIds.contains(candidateId);

/// Short plain labels for the strategies (build 2157,
/// feature pick 4): the Settings hop picker's chips and
/// the connect journal's name for a hand-picked hop. The
/// DPI Lab's candidate list carries the long labels; these
/// are the same six strategies in picker-sized words.
const zapretStrategyLabels = <String, String>{
  'zap-split': 'SNI split',
  'zap-tlsrec': 'TLS record split',
  'zap-fake': 'Fake first packet',
  'zap-disorder': 'Disorder',
  'zap-oob': 'OOB byte',
  'zap-disoob': 'Disorder + OOB',
};

/// The desync flags per candidate (the shapes proven
/// against a live ClientHello on the host — see the
/// build 2127 progress file's H1 host-proof record).
const _zapretFlags = <String, List<String>>{
  // SNI-relative multisplit: segments end at SNI+2 and
  // SNI+5, so the name crosses three segments.
  'zap-split': ['--split', '2+s', '--split', '5+s'],
  // One TLS record boundary inside the SNI (at SNI+3):
  // the handshake stays valid TLS, the DPI loses the
  // name across records.
  'zap-tlsrec': ['--tlsrec', '3+s'],
  // A fake first segment carrying a decoy SNI, sent
  // with TTL 4 — the DPI reads the decoy and lets go;
  // the segment dies before the server, the real one
  // follows intact.
  'zap-fake': [
    '--fake',
    '-1',
    '--fake-sni',
    'www.google.com',
    '--ttl',
    '4',
  ],
  // The segment under the split is sent last (with a
  // dying TTL; the stack re-sends it in order once the
  // peer reports the gap).
  'zap-disorder': ['--disorder', '2+s'],
  // The byte at the split rides as TCP urgent (OOB)
  // data — most DPI parsers drop it from the stream
  // they reassemble; the server discards it too.
  'zap-oob': ['--oob', '2+s'],
  // Disorder and OOB combined.
  'zap-disoob': ['--disoob', '2+s'],
};

/// The full command line for [candidateId]: loopback
/// SOCKS on [zapretListenPort] plus the candidate's
/// desync flags. Throws for a non-zap id — callers gate
/// on [isZapretCandidate].
List<String> buildZapretArgs(String candidateId) {
  final flags = _zapretFlags[candidateId];
  if (flags == null) {
    throw ArgumentError('not a zap candidate: $candidateId');
  }
  return ['-i', '127.0.0.1', '-p', '$zapretListenPort', ...flags];
}
