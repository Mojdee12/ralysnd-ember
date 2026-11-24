/// The DPI Strategy Lab (build 2107; design:
/// ~/workspace/ember-app/dpi-lab-design.md).
///
/// On a filtered network, whether a V2Ray config connects at
/// all can depend on how its TLS handshake is shaped — the
/// per-profile anti-filter layer (anti_filter.dart) and the
/// watchdog shapes (shapes.dart) exist because of exactly
/// that. Until this build the only way a shape was discovered
/// was reactively: a live session stalled and the watchdog
/// escalated. The Lab is the proactive form, after DPIMech
/// 0.3.0's Strategy Lab: a wizard tests candidate strategies
/// against real requests on the CURRENT network, confirms
/// each one that actually carries traffic, and remembers a
/// strategy per network so later connects on that network
/// dial it first — the confirmed winner, or (build 2115) a
/// strategy the owner picks by hand from the results that
/// answered.
///
/// Everything here rides machinery the app already ships:
/// - a candidate is a pure [Profile] copy transform over the
///   shaping layer — the stored profile is never mutated, and
///   the config builder executes every transform end-to-end
///   (no dead toggles);
/// - the probe is the delay test's own throwaway core
///   ([buildTestConfig] + the platform measure), and the
///   confirmation is the endurance qualification a shape must
///   pass at connect time (three keep-alive requests at
///   0 / +2.5 s / +5.4 s) — a candidate that answers once and
///   then freezes is reported as exactly that, never as a win;
/// - the network identity is the winning-shape cache's
///   fingerprint (connectivity type + hashed operator), so a
///   Lab win and a shape win describe the same network.
///
/// The whole feature is gated by XraySettings.dpiLabEnabled
/// (default OFF): off, nothing here is consulted by any
/// connect path.
///
/// Build 2120 (owner orders 2026-11-19 20:38 / 20:43):
/// - the sweep's subset is the owner's to pick: a run tests
///   the candidates he has ticked (the persisted EXCLUDED
///   set below; empty = all, today's behaviour);
/// - every measured result is saved per config
///   ([DpiLabResultBook]) and shown with its age on the
///   next visit — a re-run updates only the rows it tests;
/// - the Zapret set is completed with the two split
///   geometries a static finalmask can still honestly
///   express (z4 delayed multisplit, z5 dense multisplit).
///   The full zapret ENGINE is deliberately NOT here:
///   nfqws desyncs by forging raw packets — fake packets
///   with forged TTL/checksum/sequence (its badsum, badseq
///   and autottl fooling), out-of-order (disorder) segment
///   delivery, sequence overlap, payload in the SYN — all
///   below the stream layer this app shapes, and on
///   Android behind root (nfqws needs NFQUEUE + iptables;
///   an app cannot packet-intercept even its own core's
///   server dials). What a config CAN express is the
///   fragmenter: in-order records, absolute lengths,
///   per-segment delays. The z1–z5 geometries are that
///   expressible set, labelled as geometries — never as
///   an "engine".

import 'anti_filter.dart';
import 'config_builder.dart';
import 'shape_cache.dart';
import 'shapes.dart';
import 'tls_cert_pin.dart';
import 'xray_models.dart';
import 'zapret_args.dart';

/// The quick probe's per-candidate budget (ms): the native
/// delay tester gives up on a candidate within this window.
const dpiLabQuickBudgetMs = 8000;

/// One candidate strategy: an id, the picker/result label,
/// what it changes in plain words, and whether it needs a TLS
/// profile (the shaping layer reshapes TLS only — REALITY and
/// plain streams are never reshaped, the anti-filter layer's
/// own rule). Build 2135 (audit A34-01): that rule binds the
/// CONFIG-layer candidates; the Zapret engine's byte-level
/// modes shape the raw TCP stream below the config layer and
/// never parse TLS semantics, so they carry [tcpByteLevel]
/// and are offered on non-TLS TCP profiles too.
class DpiLabCandidate {
  const DpiLabCandidate(
    this.id,
    this.label,
    this.detail, {
    this.tlsOnly = false,
    this.tcpByteLevel = false,
  });

  final String id;
  final String label;
  final String detail;
  final bool tlsOnly;

  /// The mechanism is a raw-TCP byte-level operation —
  /// ordinary socket segmentation of the byte stream (split
  /// at an offset, segments sent out of order, one byte sent
  /// as urgent data) that never parses TLS semantics. Such a
  /// candidate is offered on non-TLS TCP profiles as well as
  /// TLS ones (the UDP exclusion still applies: there is no
  /// TCP stream to segment). Only the Zapret engine's
  /// split / disorder / OOB modes qualify; its TLS record
  /// split (which rewrites TLS record structure) and its
  /// fake first segment (a synthesized ClientHello) parse
  /// TLS semantics and stay [tlsOnly] without this flag, as
  /// does every config-layer fragment candidate (the
  /// shaping layer emits nothing for a non-TLS profile, so
  /// those would grade the baseline — a dead probe).
  final bool tcpByteLevel;
}

/// The shipped candidate set, in probe order: the watchdog's
/// proven escalation shapes first (s1–s3 reuse shapes.dart's
/// ids and transforms), then the remaining anti-filter
/// variants. s0 is the baseline — the profile exactly as
/// stored, which may itself carry the user's own shaping.
const dpiLabCandidates = <DpiLabCandidate>[
  DpiLabCandidate(
    's0',
    'Stock',
    'The config exactly as stored — the baseline a connect dials today.',
  ),
  DpiLabCandidate(
    's1',
    'TLS fragment (F12)',
    'The ClientHello in 75-byte records, 15 ms apart.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    's2',
    'Unsafe fingerprint + cipher suites',
    // Build 2116 (B13-7, 2107-L3): the unsafe-fingerprint
    // half is inert on KCP transports (there is no TLS
    // fingerprint for it to set there) — say so.
    'The unfilter cipher-suite order with the unsafe '
        'fingerprint. The fingerprint half does nothing on '
        'KCP transports.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    's3',
    'dialMode urgent byte (oob.0)',
    'An urgent byte appended to the first write.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-mirage',
    'Mirage ClientHello split',
    'A zero-length record, a 104-byte record, then 1-byte records.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-f1',
    'Fragment: first byte alone',
    'The first ClientHello byte travels in its own record.',
    tlsOnly: true,
  ),
  // Build 2126 (D9): the rest of the editor's F-family
  // fragment shapes as probe candidates — data rows over
  // the same shaping layer (shape ids f2…f15 in
  // anti_filter.dart), under the Lab's master toggle.
  DpiLabCandidate(
    'af-f2',
    'Fragment F2: first two bytes, then rest',
    'The first two ClientHello bytes each travel in their '
        'own record, then the rest goes whole.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-f3',
    'Fragment F3: small head, big tail',
    'A 5-byte first record, then the remainder in one '
        'large record.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-f6',
    'Fragment F6: many medium cuts',
    'The ClientHello cut into a run of 64-byte records.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-f7',
    'Fragment F7: progressive cuts',
    'Records grow as they go — 10, 50, 100, then 200 '
        'bytes each.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-f8',
    'Fragment F8: record-pair chop',
    'The head of the ClientHello cut two bytes at a time.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-f9',
    'Fragment F9: SNI-length probe',
    'Even 24-byte records across the name region.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-f13',
    'Fragment F13: slow drip',
    '8-byte records sent 50 ms apart, so the hello '
        'arrives as a slow drip.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-f14',
    'Fragment F14: big first record',
    'A 512-byte first record, then a 64-byte one.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-f15',
    'Fragment F15: two-record split',
    'The hello split into two 100-byte records.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-z1',
    'Zapret multisplit',
    'Zapret-style desync: the ClientHello cut at 2, 5, 10 '
        'and 18 bytes, so no single record boundary reveals '
        'the whole name.',
    tlsOnly: true,
  ),
  // Build 2126 (D7): the multisplit with randomized
  // geometry — each segment's length and the pause are
  // drawn per connection from a band around the Z1 cuts,
  // so no two connections share the same cut pattern.
  DpiLabCandidate(
    'af-z1r',
    'Zapret multisplit, randomized',
    'Zapret-style desync with per-connection random cut '
        'positions around the multisplit geometry — the '
        'pattern changes every time it connects.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-z2',
    'Zapret split, fine records',
    'Zapret-style desync: cuts at 1, 3 and 7 bytes, then '
        'the rest travels whole.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-z3',
    'Zapret feint, then splits',
    'A zero-length first record — the fragmenter\'s '
        'stand-in for Zapret\'s fake first packet — then '
        'splits at 2 and 104 bytes.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-z4',
    'Zapret multisplit, delayed',
    'Zapret-style desync: the multisplit cuts at 2, 5, 10 '
        'and 18 bytes, with a 10 ms pause between segments '
        'so each cut leaves as its own TCP segment instead '
        'of merging into one write.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-z5',
    'Zapret multisplit, dense cuts',
    'Zapret-style desync: cuts repeated across the whole '
        'name — at 1, 3, 6, 10, 15, 21, 28 and 36 bytes — '
        'so no small reassembly window holds the whole SNI.',
    tlsOnly: true,
  ),
  // Build 2127 (H1): the REAL Zapret desync engine —
  // ciadpi (ByeDPI) as a local proxy the server dial is
  // chained through (zapret_args.dart). Unlike the af-z*
  // geometries above, these shape the actual TCP stream
  // below the config layer: SNI-relative segment cuts,
  // TLS record splits, disorder, out-of-band bytes, and
  // a fake first segment with a decoy SNI at a dying
  // TTL. What stays out of reach without root — the
  // nfqws engine's forged packets (bad checksum, sequence
  // overlap, RST injection, IP fragmentation, QUIC
  // CRYPTO splitting) — is not claimed here or anywhere.
  // Build 2135 (audit A34-01): the split is per mechanism
  // — split / disorder / OOB are raw segment operations
  // (tcpByteLevel: offered on non-TLS TCP profiles too);
  // the TLS record split and the fake first segment work
  // on TLS semantics and stay TLS-only.
  DpiLabCandidate(
    'zap-split',
    'Zapret engine: SNI multisplit',
    'The Zapret desync engine (ciadpi) as a local proxy: '
        'the server dial crosses it, and it cuts the '
        'ClientHello into segments at SNI+2 and SNI+5.',
    tlsOnly: true,
    tcpByteLevel: true,
  ),
  DpiLabCandidate(
    'zap-tlsrec',
    'Zapret engine: TLS record split',
    'The Zapret engine splits the ClientHello into '
        'separate TLS records inside the SNI (at SNI+3) — '
        'valid TLS layering the filter cannot join.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'zap-fake',
    'Zapret engine: fake first packet',
    'The Zapret engine sends a fake first segment '
        'carrying a decoy name (www.google.com) with a '
        'dying TTL, then the real handshake — the filter '
        'reads the decoy, the segment never arrives.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'zap-disorder',
    'Zapret engine: disorder',
    'The Zapret engine sends the segment under the SNI '
        'cut last; the stack restores the order, the '
        'filter\'s window closes first.',
    tlsOnly: true,
    tcpByteLevel: true,
  ),
  DpiLabCandidate(
    'zap-oob',
    'Zapret engine: out-of-band byte',
    'The Zapret engine sends one byte at the SNI cut '
        'as TCP urgent (out-of-band) data, which stream '
        'reassemblers on the path drop.',
    tlsOnly: true,
    tcpByteLevel: true,
  ),
  DpiLabCandidate(
    'zap-disoob',
    'Zapret engine: disorder + OOB',
    'The Zapret engine combines disorder with the '
        'out-of-band byte at the SNI cut.',
    tlsOnly: true,
    tcpByteLevel: true,
  ),
  DpiLabCandidate(
    'af-mixed-sni',
    'Mixed-case SNI',
    'The server name sent in MiXeD case, which byte-exact filters miss.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-ech',
    'ECH',
    'Encrypted ClientHello, using Cloudflare\'s public ECH keys.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-unfilter',
    'Unfilter shape',
    'The unfilter fingerprint, cipher order and hello mask together.',
    tlsOnly: true,
  ),
  DpiLabCandidate(
    'af-tcp-noise',
    'TCP noise',
    // Build 2116 (B13-7, 2107-L2): the old text implied
    // every connection; in this core the freedom noise
    // packets fire only for UDP destinations.
    'Freedom noise packets ahead of UDP traffic — in this '
        'core they are sent only for UDP destinations, so a '
        'TCP profile sees no change from this strategy.',
  ),
];

/// The candidate stored under [id], or null. Built-ins are
/// consulted first, then the installed remote strategies
/// (build 2114).
DpiLabCandidate? dpiLabCandidateById(String id) {
  for (final c in dpiLabCandidates) {
    if (c.id == id) return c;
  }
  return _dpiRemoteStrategies[id]?.candidate;
}

/// One remote (community-feed) strategy (build 2114;
/// dpi_remote.dart parses and strictly validates the feed
/// into these). A remote strategy is DATA: it can only
/// recombine the shaping layer's existing mechanisms — a
/// fragment geometry of its own (installed into
/// anti_filter's remote shape registry under the candidate
/// id), the unfilter / ECH / mixed-SNI / TCP-noise switches,
/// and the watchdog's dialMode preset. It can never name a
/// mechanism the shipped layer does not already have.
class DpiRemoteStrategy {
  const DpiRemoteStrategy({
    required this.candidate,
    this.fragment,
    this.unfilter = false,
    this.ech = false,
    this.mixedSni = false,
    this.tcpNoise = false,
    this.dialMode = '',
  });

  /// The candidate as the Lab lists and remembers it; its
  /// id is in the 'r-' namespace (dpi_remote.dart mints it),
  /// which no built-in uses.
  final DpiLabCandidate candidate;

  /// The strategy's own fragment geometry, or null. When
  /// set, [Profile.afFragment] carries the candidate id and
  /// anti_filter's remote registry resolves it.
  final AfFragmentShape? fragment;

  final bool unfilter;
  final bool ech;
  final bool mixedSni;
  final bool tcpNoise;

  /// '' or the watchdog's dialMode preset ('oob.0') — the
  /// only non-empty value validation accepts.
  final String dialMode;

  /// Whether the strategy's ONLY shaping is TCP-bound (a
  /// fragment geometry, the unfilter mask, or the urgent
  /// byte) with no TCP noise — the _dpiLabTcpOnlyCandidates
  /// rule, derived from the spec: on a UDP transport such a
  /// strategy cannot shape the dial at all.
  bool get tcpOnlyShape =>
      !tcpNoise && (fragment != null || unfilter || dialMode.isNotEmpty);
}

/// The installed remote strategies, keyed by candidate id.
/// Replaced wholesale by [installDpiRemoteStrategies] — on
/// store load (BEFORE the Lab memory is parsed: a remembered
/// win names its candidate, and DpiLabWin.fromJson validates
/// the id against this registry) and on a feed refresh.
final Map<String, DpiRemoteStrategy> _dpiRemoteStrategies = {};

/// The installed remote strategies, in install order.
List<DpiRemoteStrategy> get dpiRemoteStrategies =>
    List.unmodifiable(_dpiRemoteStrategies.values);

/// Installs [strategies] as the remote candidate set
/// (build 2114): replaces the registry and the fragment
/// shapes anti_filter resolves for them. A strategy whose
/// id collides with a built-in candidate is dropped — a
/// feed can never shadow a shipped strategy. Returns the
/// installed set.
List<DpiRemoteStrategy> installDpiRemoteStrategies(
  List<DpiRemoteStrategy> strategies,
) {
  _dpiRemoteStrategies.clear();
  final shapes = <String, AfFragmentShape>{};
  for (final s in strategies) {
    if (dpiLabCandidates.any((c) => c.id == s.candidate.id)) continue;
    _dpiRemoteStrategies[s.candidate.id] = s;
    final f = s.fragment;
    if (f != null) shapes[s.candidate.id] = f;
  }
  afInstallRemoteShapes(shapes);
  return dpiRemoteStrategies;
}

/// Whether the Lab can honestly grade [p]: the Xray core must
/// serve the protocol (a test config measures the core's own
/// outbound — a sidecar profile's test measures through its
/// sidecar, where no shaping transform reaches the dialer),
/// and the profile must not be WireGuard (its shipped path is
/// the WG Tunnel walk, not the Xray outbound a probe grades)
/// or Hysteria2 (it builds its own stream settings and the
/// shaping layer never touches it).
bool dpiLabEligible(Profile p) =>
    p.protocol.supportedByCore &&
    p.protocol != Protocol.wireguard &&
    p.protocol != Protocol.hysteria2 &&
    // QUIC is a removed transport in the shipped core
    // (build 2107, verification iteration 3): every test
    // config for a quic profile fails at core load, so a
    // discovery run could only ever grade "blocked" — the
    // Lab does not offer a run that cannot discover anything.
    p.network != 'quic';

/// The candidates whose ONLY shaping rides a TCP-only
/// mechanism, so on a UDP transport (in practice KCP — QUIC
/// profiles are not Lab-eligible at all, see dpiLabEligible)
/// they cannot shape the dial at all — probing them there
/// would grade the baseline again and could crown a
/// duplicate on timing variance (build 2107, verification
/// iteration 1):
/// - the fragment candidates (s1, af-mirage, af-f1): their
///   shaping is the stream's `finalmask` under the `tcp` key
///   (anti_filter.dart), and the core's UDP mask path never
///   reads the `tcp` list;
/// - af-unfilter: on UDP its fingerprint + cipher suites
///   duplicate s2 (both candidates now carry a stored
///   certificate pin into the built config, so the pin does
///   not separate them either), and its remaining delta —
///   the tlshello mask — is the same inert `tcp` finalmask
///   (iteration 2, proven against the patched core's source);
/// - s3: dialMode `oob.0` flags a write as TCP urgent data;
///   the patched core applies it only to TCP destinations
///   ("UDP is left as is" — dialmode_oob.go / system_dialer),
///   so on UDP it is a proven no-op (iteration 2).
const _dpiLabTcpOnlyCandidates = {
  's1',
  'af-mirage',
  'af-f1',
  // Build 2126 (D9): the F-family probes are TCP
  // ClientHello shaping like F1.
  'af-f2',
  'af-f3',
  'af-f6',
  'af-f7',
  'af-f8',
  'af-f9',
  'af-f13',
  'af-f14',
  'af-f15',
  'af-z1',
  // Build 2126 (D7).
  'af-z1r',
  'af-z2',
  'af-z3',
  'af-z4',
  'af-z5',
  'af-unfilter',
  's3',
  // Build 2127 (H1): the zap candidates desync the TCP
  // stream itself — on a UDP transport there is no TCP
  // stream for the proxy to shape.
  'zap-split',
  'zap-tlsrec',
  'zap-fake',
  'zap-disorder',
  'zap-oob',
  'zap-disoob',
};

/// The candidates worth probing for [p], in probe order: the
/// full set for a TLS profile; for any other eligible profile
/// the transport-level subset (stock + TCP noise) plus —
/// build 2135, audit A34-01 — the Zapret engine's byte-level
/// modes (see [DpiLabCandidate.tcpByteLevel]), which shape
/// the raw TCP stream below the config layer and so are not
/// bound by the shaping layer's TLS-only rule. This function
/// is the ONE gate: the Lab's offer list and the connect-time
/// applicability check ([dpiLabCandidateApplies]) both read
/// it, so the two can never disagree.
///
/// The TLS set is offered only where the builder actually
/// runs the shaping layer: a core protocol that builds TLS
/// stream settings (VLESS / VMess / Trojan). Shadowsocks,
/// SOCKS and HTTP profiles are normalised to no-security by
/// the profile sanitiser, so this is defence in depth — but
/// an unsanitised in-memory profile must not be offered dead
/// probes either (verification iteration 1).
List<DpiLabCandidate> dpiLabCandidatesFor(Profile p) {
  final tlsShaped =
      p.security == 'tls' &&
      (p.protocol == Protocol.vless ||
          p.protocol == Protocol.vmess ||
          p.protocol == Protocol.trojan);
  final udpTransport = p.network == 'quic' || p.network == 'kcp';
  // Mixed-case SNI is inert when the effective server name
  // is an IP literal (applyAntiFilter's own guard) — the
  // candidate would grade the normalised baseline and could
  // be crowned on variance, then applied at connect as the
  // NORMALISED profile, silently discarding the user's own
  // stock shaping (build 2107, verification iteration 3).
  final sniIsIp = _dpiLabIsIpLiteral(p.sni.isEmpty ? p.address : p.sni);
  return [
    for (final c in dpiLabCandidates)
      if ((!c.tlsOnly || tlsShaped || c.tcpByteLevel) &&
          !(udpTransport && _dpiLabTcpOnlyCandidates.contains(c.id)) &&
          !(sniIsIp && c.id == 'af-mixed-sni'))
        c,
    // The installed remote strategies (build 2114) ride the
    // same gates, with their own derived flags: a TLS-layer
    // strategy is offered only where the shaping layer runs,
    // a TCP-only shape is skipped on UDP transports, and a
    // mixed-SNI strategy is inert against an IP literal.
    for (final s in _dpiRemoteStrategies.values)
      if ((!s.candidate.tlsOnly || tlsShaped) &&
          !(udpTransport && s.tcpOnlyShape) &&
          !(sniIsIp && s.mixedSni))
        s.candidate,
  ];
}

/// Whether [host] is an IP literal (IPv4, or an IPv6 form —
/// a colon or a bracketed literal), mirroring the
/// anti-filter layer's _isIpLiteral guard.
bool _dpiLabIsIpLiteral(String host) {
  var h = host.trim();
  if (h.startsWith('[')) return true;
  if (h.contains(':')) return true;
  // One trailing dot (a fully-qualified spelling of the same
  // address) must not smuggle an IPv4 literal past the check
  // (iteration 4; the anti-filter helper shares this blind
  // spot, and the Lab's exclusion is the conservative side).
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  return RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h);
}

/// Whether candidate [candidateId] can be applied to [p] —
/// the memory-application gate: a strategy remembered from a
/// TLS profile must never land on a profile it cannot shape.
bool dpiLabCandidateApplies(String candidateId, Profile p) =>
    dpiLabEligible(p) && dpiLabCandidatesFor(p).any((c) => c.id == candidateId);

/// [p] with its shaping layer cleared: the neutral base every
/// non-stock candidate starts from, so candidates are mutually
/// exclusive strategies rather than accumulations. The
/// profile's server, transport and credentials are untouched.
///
/// The direct spellings of the same layer are cleared too
/// (build 2107, verification iteration 1): a stored
/// fingerprint / cipher-suite pair IS candidate s2's payload,
/// a stored dialMode IS s3's, a stored finalMask is a second
/// spelling of the fragment mechanism, and a stored ECH config
/// list would ride every candidate — left in place, two
/// candidates could build byte-identical configs and the Lab
/// would crown whichever passed first on timing variance.
Profile _dpiLabNormalised(Profile p) => p.copy()
  ..afUnfilter = false
  ..afEch = false
  ..afFragment = ''
  ..afMixedSni = false
  ..afTcpNoise = false
  // A pin-shaped fingerprint is not a uTLS name — it is a
  // certificate pin the builder re-emits as
  // pinnedPeerCertSha256 (build 2057). Clearing it would
  // silently strip a security pin from every candidate, so
  // it is preserved verbatim (build 2107, verification
  // iteration 2); candidate s2, whose shape overwrites the
  // field, carries the pin in tlsCertPin instead (see
  // profileWithCandidate).
  ..fingerprint = isValidTlsCertPin(p.fingerprint) ? p.fingerprint : ''
  ..cipherSuites = ''
  ..dialMode = ''
  ..finalMask = ''
  ..echConfigList = '';

/// A copy of [p] dialed as candidate [candidateId] — the one
/// transform both the probe and the connect path use, so what
/// the Lab measured is exactly what a connect dials. 's0' (and
/// an unknown id) returns [p] itself: the stock strategy is
/// the stored profile, unmodified. The s1–s3 candidates ARE
/// the watchdog shapes, applied by shapes.dart's own
/// transform over the normalised base.
Profile profileWithCandidate(Profile p, String candidateId) {
  switch (candidateId) {
    case 's1':
      return profileWithShape(_dpiLabNormalised(p), shapeFragment);
    case 's2':
      final shaped = profileWithShape(_dpiLabNormalised(p), shapeUnsafeCiphers);
      // The shape overwrites the fingerprint field with
      // 'unsafe', which would silently strip a certificate
      // pin stored IN that field (every other candidate
      // preserves it — build 2107, verification iteration
      // 3). Carry the pin in its dedicated field instead, so
      // s2's built config keeps pinnedPeerCertSha256 like
      // the rest of the set; a win remembered for a week
      // must not be a silent pinning downgrade.
      // The guard tests VALIDITY, not emptiness (iteration
      // 4): the builder treats an invalid tlsCertPin as
      // absent and falls back to the fingerprint pin, so an
      // invalid stored value must not block the carry.
      if (isValidTlsCertPin(p.fingerprint) &&
          !isValidTlsCertPin(shaped.tlsCertPin)) {
        shaped.tlsCertPin = p.fingerprint;
      }
      return shaped;
    case 's3':
      return profileWithShape(_dpiLabNormalised(p), shapeDialMode);
    case 'af-mirage':
      return _dpiLabNormalised(p)..afFragment = 'mirage';
    case 'af-f1':
      return _dpiLabNormalised(p)..afFragment = 'f1';
    // Build 2126 (D9): the F-family probes.
    case 'af-f2':
      return _dpiLabNormalised(p)..afFragment = 'f2';
    case 'af-f3':
      return _dpiLabNormalised(p)..afFragment = 'f3';
    case 'af-f6':
      return _dpiLabNormalised(p)..afFragment = 'f6';
    case 'af-f7':
      return _dpiLabNormalised(p)..afFragment = 'f7';
    case 'af-f8':
      return _dpiLabNormalised(p)..afFragment = 'f8';
    case 'af-f9':
      return _dpiLabNormalised(p)..afFragment = 'f9';
    case 'af-f13':
      return _dpiLabNormalised(p)..afFragment = 'f13';
    case 'af-f14':
      return _dpiLabNormalised(p)..afFragment = 'f14';
    case 'af-f15':
      return _dpiLabNormalised(p)..afFragment = 'f15';
    case 'af-z1':
      return _dpiLabNormalised(p)..afFragment = 'z1';
    // Build 2126 (D7): the randomized multisplit.
    case 'af-z1r':
      return _dpiLabNormalised(p)..afFragment = 'z1r';
    case 'af-z2':
      return _dpiLabNormalised(p)..afFragment = 'z2';
    case 'af-z3':
      return _dpiLabNormalised(p)..afFragment = 'z3';
    case 'af-z4':
      return _dpiLabNormalised(p)..afFragment = 'z4';
    case 'af-z5':
      return _dpiLabNormalised(p)..afFragment = 'z5';
    // Build 2127 (H1): a zap candidate shapes nothing in
    // the config — it marks the copy to dial through the
    // desync proxy (the builders chain the proxy outbound
    // on the marker; the sweep and the connect start the
    // proxy itself via their hooks/session starts).
    case 'zap-split':
    case 'zap-tlsrec':
    case 'zap-fake':
    case 'zap-disorder':
    case 'zap-oob':
    case 'zap-disoob':
      return _dpiLabNormalised(p)..zapretStrategy = candidateId;
    case 'af-mixed-sni':
      return _dpiLabNormalised(p)..afMixedSni = true;
    case 'af-ech':
      return _dpiLabNormalised(p)..afEch = true;
    case 'af-unfilter':
      return _dpiLabNormalised(p)..afUnfilter = true;
    case 'af-tcp-noise':
      return _dpiLabNormalised(p)..afTcpNoise = true;
    default:
      // A remote strategy (build 2114): its validated spec
      // recombined over the normalised base — the fragment
      // geometry rides afFragment under the strategy's own
      // 'r-' id (anti_filter's remote registry resolves it),
      // the switches map to the shaping layer's own fields.
      final remote = _dpiRemoteStrategies[candidateId];
      if (remote != null) {
        final shaped = _dpiLabNormalised(p);
        if (remote.fragment != null) shaped.afFragment = candidateId;
        if (remote.unfilter) shaped.afUnfilter = true;
        if (remote.ech) shaped.afEch = true;
        if (remote.mixedSni) shaped.afMixedSni = true;
        if (remote.tcpNoise) shaped.afTcpNoise = true;
        if (remote.dialMode.isNotEmpty) shaped.dialMode = remote.dialMode;
        return shaped;
      }
      return p;
  }
}

/// A plain-words label for a network fingerprint (the UI
/// never shows the raw key): 'wifi' → 'Wi-Fi', a hashed
/// suffix is shown as-is — it is a hash, not a name.
String dpiLabNetworkLabel(String networkFp) {
  if (networkFp.isEmpty) return 'Unknown network';
  final at = networkFp.indexOf(':');
  final type = at < 0 ? networkFp : networkFp.substring(0, at);
  final suffix = at < 0 ? '' : networkFp.substring(at + 1);
  final base = switch (type) {
    'wifi' => 'Wi-Fi',
    'cellular' => 'Mobile',
    'ethernet' => 'Ethernet',
    _ => 'Network',
  };
  return suffix.isEmpty ? base : '$base · $suffix';
}

/// One network's remembered Lab win: the candidate that was
/// CONFIRMED (endurance-held) there, and the evidence it won
/// with. Stored in the controller's store document beside the
/// shape cache.
class DpiLabWin {
  const DpiLabWin({
    required this.candidateId,
    required this.profileId,
    required this.profileName,
    required this.ms,
    required this.exitCountry,
    required this.verifiedMs,
  });

  final String candidateId;

  /// The profile the evidence was measured on. The win is a
  /// property of the NETWORK, not of this profile — it is
  /// kept as evidence (and shown in the Lab), and application
  /// re-checks the candidate against each dialed profile.
  final String profileId;
  final String profileName;

  /// The winning quick-round delay (ms).
  final int ms;
  final String exitCountry;

  /// When the win was confirmed (epoch ms).
  final int verifiedMs;

  Map<String, dynamic> toJson() => {
    'candidate': candidateId,
    'profile': profileId,
    'name': profileName,
    'ms': ms,
    'cc': exitCountry,
    'at': verifiedMs,
  };

  /// Null for anything that is not a well-formed win — a
  /// corrupt entry reads as "no win", never as a crash (the
  /// shape cache's rule).
  static DpiLabWin? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final candidate = raw['candidate'];
    final profile = raw['profile'];
    final at = raw['at'];
    if (candidate is! String || candidate.isEmpty) return null;
    if (dpiLabCandidateById(candidate) == null) return null;
    // A non-finite number (a stored 1e999 decodes to infinity)
    // must not reach toInt() — it throws, and one corrupt
    // entry would take down the whole memory read (build
    // 2107, verification iteration 1; the same guard the
    // models' _storedInt has carried since build 2098).
    if (at is! num || !at.isFinite) return null;
    final msRaw = raw['ms'];
    return DpiLabWin(
      candidateId: candidate,
      profileId: profile is String ? profile : '',
      profileName: raw['name'] is String ? raw['name'] as String : '',
      ms: msRaw is num && msRaw.isFinite ? msRaw.toInt() : -1,
      exitCountry: raw['cc'] is String ? raw['cc'] as String : '',
      verifiedMs: at.toInt(),
    );
  }
}

/// The per-network Lab memory: network fingerprint → the
/// strategy confirmed there. A win is trusted for as long as
/// a shape-cache win is (a week — filters change, and a stale
/// winner must not pin a profile to a dead strategy).
class DpiLabMemory {
  DpiLabMemory([Map<String, DpiLabWin>? wins])
    : _wins = wins ?? <String, DpiLabWin>{};

  final Map<String, DpiLabWin> _wins;

  static const maxAgeMs = WinningShapeCache.maxAgeMs;

  int get length => _wins.length;

  /// Every remembered win, keyed by network fingerprint (the
  /// Lab page's list). Unmodifiable.
  Map<String, DpiLabWin> get wins => Map.unmodifiable(_wins);

  /// Whether [win] is outside its trust window at [nowMs]:
  /// older than the maximum age, or dated so far in the
  /// future (a clock set wrong when it was recorded, then
  /// corrected) that it would otherwise be trusted for the
  /// skew plus the whole window. A slightly-future win (a
  /// small clock skew) is still fresh — its age clamps to 0.
  static bool _outsideTrust(DpiLabWin win, int nowMs) =>
      win.verifiedMs - nowMs > maxAgeMs || nowMs - win.verifiedMs > maxAgeMs;

  /// The win for [networkFp], or null when there is none, it
  /// is stale (stale wins are evicted on read), or the
  /// fingerprint is unknown — an unknown network never
  /// inherits another network's win.
  DpiLabWin? lookup(String networkFp, {int? nowMs}) {
    if (networkFp.isEmpty) return null;
    final win = _wins[networkFp];
    if (win == null) return null;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (_outsideTrust(win, now)) {
      _wins.remove(networkFp);
      return null;
    }
    return win;
  }

  void record(String networkFp, DpiLabWin win) {
    if (networkFp.isEmpty) return;
    // Prune dead wins on write (the shape cache's hygiene):
    // without it, expired entries accumulate in the persisted
    // document forever. Staleness is judged against the
    // newest clock reference available — the wall clock or
    // the incoming win's own timestamp, whichever is later.
    final now = DateTime.now().millisecondsSinceEpoch;
    final ref = win.verifiedMs > now ? win.verifiedMs : now;
    _wins.removeWhere((_, w) => _outsideTrust(w, ref));
    _wins[networkFp] = win;
  }

  void forget(String networkFp) => _wins.remove(networkFp);

  void clear() => _wins.clear();

  Map<String, dynamic> toJson() => {
    for (final e in _wins.entries) e.key: e.value.toJson(),
  };

  /// Reads a stored memory document. Every entry is validated
  /// on its own; corrupt entries are dropped, and a wholly
  /// corrupt document reads as an empty memory.
  factory DpiLabMemory.fromJson(Object? raw) {
    final wins = <String, DpiLabWin>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        final win = DpiLabWin.fromJson(e.value);
        // An empty-string key (a foreign/corrupt document)
        // names no network: lookup('') can never evict it,
        // so it is dropped here instead of being re-persisted
        // forever (iteration 4).
        if (win != null && e.key is String && (e.key as String).isNotEmpty) {
          wins[e.key as String] = win;
        }
      }
    }
    return DpiLabMemory(wins);
  }
}

/// What one probed candidate proved on this network.
enum DpiLabVerdict {
  /// Answered the quick round AND held the confirmation
  /// round: this strategy carries traffic here.
  works,

  /// Answered the quick round but the session froze inside
  /// the confirmation window — the filtered-network failure
  /// the endurance check exists to catch. Reported honestly;
  /// never remembered as a winner.
  freezes,

  /// Answered the quick round, but the confirmation round
  /// itself could not run (the endurance test failed to
  /// start or threw) — nothing is proven either way about
  /// whether the session would have held. Never remembered
  /// as a winner. (Build 2107, verification iteration 1: this
  /// was originally reported as [freezes], which told the
  /// user the network froze a session no confirmation ever
  /// ran on.)
  unconfirmed,

  /// Never answered the quick round at all.
  blocked,
}

/// One candidate's measured result: the verdict plus the
/// evidence it rests on (quick-round ms, the exit country
/// observed through the same throwaway core, and the three
/// endurance probe times when the confirmation round ran).
class DpiLabResult {
  const DpiLabResult({
    required this.candidate,
    required this.verdict,
    required this.ms,
    required this.exitCountry,
    this.p0 = -1,
    this.p1 = -1,
    this.p2 = -1,
  });

  final DpiLabCandidate candidate;
  final DpiLabVerdict verdict;

  /// The quick round's best delay (ms), -1 when it never
  /// answered.
  final int ms;
  final String exitCountry;

  /// The confirmation round's probes at t=0 / +2.5 s / +5.4 s
  /// (-1 = failed or never ran).
  final int p0;
  final int p1;
  final int p2;
}

/// The run's winner: the first CONFIRMED result, or null —
/// a freezes result is evidence, not a win.
DpiLabResult? dpiLabWinner(List<DpiLabResult> results) {
  for (final r in results) {
    if (r.verdict == DpiLabVerdict.works) return r;
  }
  return null;
}

/// Whether [result] may be filed as a network's remembered
/// strategy. A CONFIRMED result (verdict works) always may —
/// that is the winner path the Lab has had since build 2107.
/// A result that ANSWERED but did not confirm (freezes, or
/// unconfirmed because the confirmation round could not run)
/// may be filed only as the owner's explicit manual pick
/// (build 2115): his tap is his decision, and the record
/// keeps the honest verdict — a manual pick is never
/// re-labelled a win. A blocked result never answered, so
/// there is nothing to file, by hand or otherwise.
bool dpiLabCanRemember(DpiLabResult result, {required bool manual}) {
  return switch (result.verdict) {
    DpiLabVerdict.works => true,
    DpiLabVerdict.freezes || DpiLabVerdict.unconfirmed => manual,
    DpiLabVerdict.blocked => false,
  };
}

/// One SAVED Lab result (build 2120): a measured verdict
/// kept per config, with when and on which network it was
/// measured — so the Lab opens showing what was proven
/// before, with its age, instead of an empty list, and a
/// re-run only has to re-test the rows it means to refresh.
/// A saved result is EVIDENCE, not a win: it never feeds
/// the per-network memory by itself (filing still goes
/// through [dpiLabCanRemember] on an explicit tap), and the
/// page labels it with its age and network — it is never
/// presented as fresh.
class DpiLabSavedResult {
  const DpiLabSavedResult({
    required this.candidateId,
    required this.verdict,
    required this.ms,
    required this.exitCountry,
    required this.p0,
    required this.p1,
    required this.p2,
    required this.measuredMs,
    required this.networkFp,
  });

  final String candidateId;
  final DpiLabVerdict verdict;
  final int ms;
  final String exitCountry;
  final int p0;
  final int p1;
  final int p2;

  /// When the evidence was measured (epoch ms).
  final int measuredMs;

  /// The network fingerprint the evidence was measured on
  /// (the winning-shape cache's identity) — shown as a
  /// label, so a result proven on another network is never
  /// mistaken for this network's.
  final String networkFp;

  factory DpiLabSavedResult.of(
    DpiLabResult r, {
    required int measuredMs,
    required String networkFp,
  }) => DpiLabSavedResult(
    candidateId: r.candidate.id,
    verdict: r.verdict,
    ms: r.ms,
    exitCountry: r.exitCountry,
    p0: r.p0,
    p1: r.p1,
    p2: r.p2,
    measuredMs: measuredMs,
    networkFp: networkFp,
  );

  /// The result in the shape the row / pick machinery
  /// consumes, or null when the candidate no longer exists
  /// (a built-in removed by an update, or a remote strategy
  /// no longer installed).
  DpiLabResult? toResult() {
    final c = dpiLabCandidateById(candidateId);
    if (c == null) return null;
    return DpiLabResult(
      candidate: c,
      verdict: verdict,
      ms: ms,
      exitCountry: exitCountry,
      p0: p0,
      p1: p1,
      p2: p2,
    );
  }

  Map<String, dynamic> toJson() => {
    'v': verdict.name,
    'ms': ms,
    'cc': exitCountry,
    'p0': p0,
    'p1': p1,
    'p2': p2,
    'at': measuredMs,
    'net': networkFp,
  };

  static int _savedInt(Object? raw) =>
      raw is num && raw.isFinite ? raw.toInt() : -1;

  /// Null for anything that is not a well-formed saved
  /// result — the [DpiLabWin.fromJson] rule: a corrupt
  /// entry reads as "never tested", never as a crash. The
  /// candidate id validates against the registry, so the
  /// book must be parsed AFTER the remote strategies are
  /// installed (the controller's load order).
  static DpiLabSavedResult? fromJson(String candidateId, Object? raw) {
    if (raw is! Map) return null;
    if (dpiLabCandidateById(candidateId) == null) return null;
    final v = raw['v'];
    final verdict = v is String
        ? DpiLabVerdict.values.asNameMap()[v]
        : null;
    if (verdict == null) return null;
    final at = raw['at'];
    if (at is! num || !at.isFinite) return null;
    return DpiLabSavedResult(
      candidateId: candidateId,
      verdict: verdict,
      ms: _savedInt(raw['ms']),
      exitCountry: raw['cc'] is String ? raw['cc'] as String : '',
      p0: _savedInt(raw['p0']),
      p1: _savedInt(raw['p1']),
      p2: _savedInt(raw['p2']),
      measuredMs: at.toInt(),
      networkFp: raw['net'] is String ? raw['net'] as String : '',
    );
  }
}

/// The per-config book of saved Lab results (build 2120):
/// profile id → candidate id → the saved evidence. A re-run
/// records over the rows it re-tests and leaves the rest —
/// the whole list is never re-measured from scratch just
/// because one strategy needed a fresh answer. Bounded:
/// at most [maxProfiles] configs keep a book (the one whose
/// newest evidence is oldest is dropped first), and the
/// controller prunes books of deleted profiles.
class DpiLabResultBook {
  DpiLabResultBook([Map<String, Map<String, DpiLabSavedResult>>? byProfile])
    : _byProfile = byProfile ?? <String, Map<String, DpiLabSavedResult>>{};

  final Map<String, Map<String, DpiLabSavedResult>> _byProfile;

  static const maxProfiles = 64;

  int get profileCount => _byProfile.length;

  int get resultCount =>
      _byProfile.values.fold(0, (sum, rows) => sum + rows.length);

  /// The saved rows for [profileId] (unmodifiable; empty
  /// when the config was never tested).
  Map<String, DpiLabSavedResult> forProfile(String profileId) =>
      Map.unmodifiable(_byProfile[profileId] ?? const {});

  DpiLabSavedResult? lookup(String profileId, String candidateId) =>
      _byProfile[profileId]?[candidateId];

  /// Records [result] as [profileId]'s saved evidence for
  /// its candidate, replacing any older row for the same
  /// candidate and leaving every other row untouched.
  void record(
    String profileId,
    DpiLabResult result, {
    required int measuredMs,
    required String networkFp,
  }) {
    if (profileId.isEmpty) return;
    final rows = _byProfile.putIfAbsent(
      profileId,
      () => <String, DpiLabSavedResult>{},
    );
    rows[result.candidate.id] = DpiLabSavedResult.of(
      result,
      measuredMs: measuredMs,
      networkFp: networkFp,
    );
    if (_byProfile.length > maxProfiles) {
      // Drop the book whose newest evidence is oldest —
      // never the profile just recorded.
      var dropId = '';
      var dropAt = measuredMs;
      for (final e in _byProfile.entries) {
        if (e.key == profileId) continue;
        var newest = -1;
        for (final r in e.value.values) {
          if (r.measuredMs > newest) newest = r.measuredMs;
        }
        if (dropId.isEmpty || newest < dropAt) {
          dropId = e.key;
          dropAt = newest;
        }
      }
      if (dropId.isNotEmpty) _byProfile.remove(dropId);
    }
  }

  /// Drops the books of profiles that no longer exist.
  void pruneProfiles(Set<String> liveProfileIds) {
    _byProfile.removeWhere((id, _) => !liveProfileIds.contains(id));
  }

  void clear() => _byProfile.clear();

  Map<String, dynamic> toJson() => {
    for (final e in _byProfile.entries)
      e.key: {
        for (final r in e.value.entries) r.key: r.value.toJson(),
      },
  };

  /// Reads a stored book. Every entry is validated on its
  /// own; corrupt entries are dropped, and a wholly corrupt
  /// document reads as an empty book (the memory's rule).
  ///
  /// Build 2125 (audit A25-46): the [maxProfiles] bound is
  /// enforced on DECODE too — record() capped the live
  /// book, but a hostile or corrupt backup could decode
  /// an unbounded one straight into the store. Excess
  /// books drop by the record() rule: the book whose
  /// newest evidence is oldest goes first.
  factory DpiLabResultBook.fromJson(Object? raw) {
    final out = <String, Map<String, DpiLabSavedResult>>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        final pid = e.key;
        if (pid is! String || pid.isEmpty || e.value is! Map) continue;
        final rows = <String, DpiLabSavedResult>{};
        for (final r in (e.value as Map).entries) {
          if (r.key is! String) continue;
          final saved = DpiLabSavedResult.fromJson(r.key as String, r.value);
          if (saved != null) rows[saved.candidateId] = saved;
        }
        if (rows.isNotEmpty) out[pid] = rows;
      }
    }
    while (out.length > maxProfiles) {
      var dropId = '';
      var dropAt = 1 << 62;
      for (final e in out.entries) {
        var newest = -1;
        for (final r in e.value.values) {
          if (r.measuredMs > newest) newest = r.measuredMs;
        }
        if (newest < dropAt) {
          dropId = e.key;
          dropAt = newest;
        }
      }
      if (dropId.isEmpty) break;
      out.remove(dropId);
    }
    return DpiLabResultBook(out);
  }
}

/// The sweep subset's persisted form (build 2120): the set
/// of candidate ids the owner has UNTICKED. Exclusion is
/// the stored fact (not inclusion) so the default — an
/// empty set, every candidate tested — is also the state
/// of a store that predates the feature, and a strategy
/// that ships later is tested until the owner unticks it.
List<String> dpiLabSelectionToJson(Set<String> excluded) =>
    excluded.toList()..sort();

/// Reads a stored exclusion set: strings only, deduplicated
/// (a set), size-capped; anything else reads as "nothing
/// excluded" — the full sweep, never a broken Lab.
Set<String> dpiLabSelectionFromJson(Object? raw) {
  final out = <String>{};
  if (raw is List) {
    for (final e in raw) {
      if (e is String && e.isNotEmpty) out.add(e);
      if (out.length >= 256) break;
    }
  }
  return out;
}

/// The delay measurement of one test config — the platform
/// measure's shape ({'ms', 'ip', 'countryCode'}). Injected so
/// the runner's orchestration is testable without a platform
/// channel.
typedef DpiLabMeasure = Future<Map<String, dynamic>> Function(String config);

/// The endurance qualification of one test config — the
/// platform endurance's shape ({'p0', 'p1', 'p2', 'held'}),
/// null when the test could not run.
typedef DpiLabEndure = Future<Map<String, int>?> Function(String config);

/// Runs discovery for [profile] on the current network:
/// candidates in probe order, sequentially (throwaway cores
/// are never raced), each quick-probed with the delay test's
/// own machinery and — when it answers — confirmation-probed
/// with the endurance check. Build 2115 (owner's order): the
/// run is a FULL SWEEP — it does not stop at the first
/// confirmed winner, and no wall-clock budget truncates it;
/// every candidate ends the run with its own measured result
/// so the owner can compare all of them and pick by hand.
/// The only early exit is [isCancelled] — the owner's own
/// stop. Every finished candidate is reported through
/// [onResult] as it lands. Build 2120: the sweep's subset
/// is the owner's pick — a candidate in [excludeIds] is not
/// probed and produces no result (its saved row, if any,
/// stands); the default empty set is the full sweep every
/// earlier build ran.
///
/// The probers are the only platform touch; everything else
/// here is the pure orchestration the tests pin.
Future<List<DpiLabResult>> runDpiLabDiscovery({
  required Profile profile,
  required XraySettings settings,
  required DpiLabMeasure measure,
  required DpiLabEndure endure,
  void Function(DpiLabResult result)? onResult,
  bool Function()? isCancelled,
  // Build 2110 (fugui-hostname diagnosis C1): the base
  // profile's app-side server-name pins, computed once by
  // the caller — every candidate keeps the base profile's
  // address, so the same pins (and the UseIP stamp) ride
  // every probe config; without them a hostname-form
  // profile would grade every strategy "blocked" on
  // resolution alone.
  Map<String, List<String>> serverHostPins = const {},
  // Build 2120: the owner's unticked candidates (see the
  // doc above). Excluded candidates are skipped entirely —
  // no probe, no result.
  Set<String> excludeIds = const {},
  // Build 2127 (H1): the per-candidate engine hooks for
  // candidates whose shaping lives OUTSIDE the config
  // (the zap candidates: the desync proxy must be running
  // with the candidate's own arguments before its probe,
  // and stops after). prepare returns false when the
  // engine could not start — the candidate grades blocked
  // without a probe. Both null (every pre-2127 caller)
  // leaves the sweep exactly as it was.
  Future<bool> Function(String candidateId)? prepareCandidate,
  Future<void> Function(String candidateId)? releaseCandidate,
}) async {
  final results = <DpiLabResult>[];
  // The runner itself refuses a profile the Lab cannot
  // honestly grade (build 2107, verification iteration 1):
  // shipped callers gate elsewhere, but this pure surface
  // must not grade a WireGuard outbound or a sidecar dialer
  // if a future caller forgets to.
  if (!dpiLabEligible(profile)) return results;
  for (final candidate in dpiLabCandidatesFor(profile)) {
    if (excludeIds.contains(candidate.id)) continue;
    if (isCancelled?.call() ?? false) break;
    final result = await _probeCandidate(
      profile,
      settings,
      candidate,
      measure,
      endure,
      serverHostPins: serverHostPins,
      prepareCandidate: prepareCandidate,
      releaseCandidate: releaseCandidate,
    );
    results.add(result);
    onResult?.call(result);
    // No winner break (build 2115): the sweep continues so
    // every remaining candidate gets its own result too.
  }
  return results;
}

Future<DpiLabResult> _probeCandidate(
  Profile profile,
  XraySettings settings,
  DpiLabCandidate candidate,
  DpiLabMeasure measure,
  DpiLabEndure endure, {
  Map<String, List<String>> serverHostPins = const {},
  Future<bool> Function(String candidateId)? prepareCandidate,
  Future<void> Function(String candidateId)? releaseCandidate,
}) async {
  // Build 2127 (H1): an engine candidate (zap) probes
  // only with its engine up; the release runs whatever
  // the probe's outcome.
  if (prepareCandidate != null && isZapretCandidate(candidate.id)) {
    bool prepared;
    try {
      prepared = await prepareCandidate(candidate.id);
    } catch (_) {
      prepared = false;
    }
    if (!prepared) {
      return DpiLabResult(
        candidate: candidate,
        verdict: DpiLabVerdict.blocked,
        ms: -1,
        exitCountry: '',
      );
    }
    try {
      return await _probeCandidateMeasured(
        profile,
        settings,
        candidate,
        measure,
        endure,
        serverHostPins: serverHostPins,
      );
    } finally {
      try {
        await releaseCandidate?.call(candidate.id);
      } catch (_) {
        // A release failure must not lose the verdict.
      }
    }
  }
  return _probeCandidateMeasured(
    profile,
    settings,
    candidate,
    measure,
    endure,
    serverHostPins: serverHostPins,
  );
}

Future<DpiLabResult> _probeCandidateMeasured(
  Profile profile,
  XraySettings settings,
  DpiLabCandidate candidate,
  DpiLabMeasure measure,
  DpiLabEndure endure, {
  Map<String, List<String>> serverHostPins = const {},
}) async {
  final String config;
  try {
    config = buildTestConfig(
      profileWithCandidate(profile, candidate.id),
      settings,
      serverHostPins: serverHostPins,
    );
  } catch (_) {
    // A config the builder refuses cannot carry traffic; the
    // candidate is graded blocked rather than crashing the run.
    return DpiLabResult(
      candidate: candidate,
      verdict: DpiLabVerdict.blocked,
      ms: -1,
      exitCountry: '',
    );
  }
  // A prober that throws, or answers with a malformed map,
  // grades THIS candidate — it never aborts the run and loses
  // every verdict already gathered (build 2107, verification
  // iteration 1). The platform channel passes its map through
  // verbatim, so the casts are defended, not assumed.
  final Map<String, dynamic> measured;
  try {
    measured = await measure(config);
  } catch (_) {
    return DpiLabResult(
      candidate: candidate,
      verdict: DpiLabVerdict.blocked,
      ms: -1,
      exitCountry: '',
    );
  }
  final msRaw = measured['ms'];
  final ms = msRaw is num && msRaw.isFinite ? msRaw.toInt() : -1;
  if (ms < 0) {
    return DpiLabResult(
      candidate: candidate,
      verdict: DpiLabVerdict.blocked,
      ms: -1,
      exitCountry: '',
    );
  }
  final ccRaw = measured['countryCode'];
  final cc = ccRaw is String ? ccRaw : '';
  Map<String, int>? held;
  try {
    held = await endure(config);
  } catch (_) {
    held = null;
  }
  if (held != null && held['held'] == 1) {
    return DpiLabResult(
      candidate: candidate,
      verdict: DpiLabVerdict.works,
      ms: ms,
      exitCountry: cc,
      p0: held['p0'] ?? -1,
      p1: held['p1'] ?? -1,
      p2: held['p2'] ?? -1,
    );
  }
  if (held == null || !held.containsKey('held')) {
    // The confirmation round itself could not run — the
    // candidate answered, but nothing is proven about whether
    // the session would have held. That is NOT a freeze: a
    // freeze is a confirmation that ran and failed.
    return DpiLabResult(
      candidate: candidate,
      verdict: DpiLabVerdict.unconfirmed,
      ms: ms,
      exitCountry: cc,
      p0: held?['p0'] ?? -1,
      p1: held?['p1'] ?? -1,
      p2: held?['p2'] ?? -1,
    );
  }
  return DpiLabResult(
    candidate: candidate,
    verdict: DpiLabVerdict.freezes,
    ms: ms,
    exitCountry: cc,
    p0: held['p0'] ?? -1,
    p1: held['p1'] ?? -1,
    p2: held['p2'] ?? -1,
  );
}
