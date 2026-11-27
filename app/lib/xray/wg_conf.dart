import 'dart:convert';

import 'profile_validation.dart';
import 'xray_models.dart';

/// A WireGuard `.conf` parser (build 2032): the standalone
/// WireGuard section's import. A `.conf` carries ONE interface
/// (private key, addresses) and one or more peers; Ember's
/// profile model carries one peer per profile (the Xray
/// WireGuard outbound is built per profile), so each peer
/// becomes its own profile sharing the interface fields. The
/// group key ([wgGroupKey]) keeps the peers of one config
/// together — that group is what the peer-fallback connect
/// walks when an endpoint does not answer.
///
/// AmneziaWG configs parse too, and since build 2040 (queue
/// 2h) their obfuscation fields (Jc/Jmin/Jmax/S1/S2/H1–H4) are
/// APPLIED by the AmneziaWG engine — the result flags them so
/// the page can say plainly that the profile runs obfuscated,
/// never silently, and a peer the obfuscated tunnel cannot
/// reach falls back to plain WireGuard.
class WgConfResult {
  const WgConfResult({
    required this.profiles,
    required this.amnezia,
    required this.error,
  });

  final List<Profile> profiles;

  /// The source carried AmneziaWG obfuscation parameters.
  final bool amnezia;

  /// Why parsing failed ('' when it did not).
  final String error;

  bool get ok => error.isEmpty && profiles.isNotEmpty;
}

/// The peer-group key: peers imported from one .conf share the
/// interface private key and addresses.
String wgGroupKey(Profile p) => '${p.secretKey}|${p.localAddress}';

/// The identity key of a profile for store-wide dedupe (the
/// v2go fold-in): two profiles are the same server when the
/// protocol, the credentials and the endpoint all match — the
/// name is presentation, not identity.
String profileIdentityKey(Profile p) {
  final cred = p.protocol == Protocol.wireguard
      // The pre-shared key and the tunnel address are part of a
      // WireGuard profile's identity: two configs that differ
      // only in them are different configs, and dedupe must not
      // silently drop one (audit, build 2033).
      ? '${p.secretKey}|${p.peerPublicKey}|${p.preSharedKey}|${p.localAddress}'
      : p.protocol == Protocol.shadowsocks
      ? '${p.method}|${p.uuidOrPassword}'
      : p.protocol == Protocol.socks
      ? '${p.username}|${p.uuidOrPassword}'
      : p.uuidOrPassword;
  return '${p.protocol.name}|$cred|${p.address.toLowerCase()}|${p.port}';
}

/// Build 2097 (post-2096 audit C9): the TOMBSTONE key —
/// what a user deletion records on the subscription. It
/// extends the identity key with the transport
/// discriminators (network, security, path, host header,
/// service name, flow): build 2096 tombstoned by the
/// coarse identity alone, so deleting ONE of two
/// same-endpoint variants (same credentials, different
/// transport) tombstoned BOTH forever, and the refresh
/// merge dropped the survivor as "deleted". The identity
/// key itself is unchanged — dedupe and carry matching
/// keep their semantics; only the tombstone narrows.
/// (Stores written by ≤2096 hold identity-format keys;
/// they simply stop matching, so a profile deleted before
/// this build can reappear once after the upgrade if its
/// subscription refreshes — deleting it again records the
/// precise key.)
String profileTombstoneKey(Profile p) =>
    '${profileIdentityKey(p)}|${p.network}|${p.security}|${p.path}|'
    '${p.host}|${p.serviceName}|${p.flow}';

/// Build 2129 (recycle bin): what a tombstone key can
/// still SAY about the profile it blocks. The tombstone
/// retains no name and no full profile — only the key —
/// so the bin's listing is built from the fields the key
/// itself carries: protocol, server address and port,
/// parsed from the RIGHT (the six transport fields are
/// fixed-position at the tail; the credential in the
/// middle is variable-width — a Shadowsocks identity
/// carries its own '|' — and is never surfaced). Null
/// when the key does not have the tombstone shape (a
/// pre-2097 identity-format key, or a corrupt entry):
/// the bin lists those as an unnamed endpoint rather
/// than guessing.
({String protocol, String address, int port})? parseTombstoneKey(String key) {
  final parts = key.split('|');
  // identity (>= 4 fields: protocol, credential...,
  // address, port) + the 6 transport fields.
  if (parts.length < 10) return null;
  final port = int.tryParse(parts[parts.length - 7]);
  if (port == null) return null;
  return (protocol: parts.first, address: parts[parts.length - 8], port: port);
}

/// Build 2101 (settings-dns-2099-diagnosis.md, S4/I1): the
/// MANUAL-IMPORT dedupe key. The coarse [profileIdentityKey]
/// (protocol + credential + endpoint) collapsed a panel's
/// multi-variant issues of one UUID on one endpoint — same
/// server over tcp/ws/grpc, tls/reality, different SNI — into
/// the first copy, so a batch import "added a few, then stopped"
/// with the rest silently eaten as duplicates. Manual import
/// now dedupes on the tombstone key plus the SNI: only a true
/// duplicate (same credentials, endpoint AND transport shape)
/// collapses. [profileIdentityKey] itself is unchanged — the
/// subscription refresh's carry/loose matching (build 2095
/// audit 8-5a) keeps its coarse semantics by design.
String profileImportKey(Profile p) => '${profileTombstoneKey(p)}|${p.sni}';

/// The WireGuard `.conf` gate (build 2102): every import
/// surface that can receive a whole document — the share /
/// open-with intake, the general paste import, the scan
/// intake and the WireGuard page itself — decides "is this
/// a .conf?" with this one check, in the parser's own
/// language (section names are case-insensitive there, so
/// the check is too). Builds ≤2101 grew the check per
/// surface, and two surfaces never grew one at all: the
/// intent intake forwarded a shared .conf to the OpenVPN
/// importer, and the general paste import read .conf text
/// as zero links (wg-ipv6-import-diagnosis.md, I1/I2).
bool isWgConfText(String text) => text.toLowerCase().contains('[interface]');

/// True when the profile carries any IPv4 footprint: an
/// IPv4 tunnel address or an IPv4 AllowedIPs entry (build
/// 2102, diagnosis C2). The AWG engine captures the IPv4
/// default route only for such a profile — a v6-only
/// profile (IPv6 address, `::/0` only) must not have all
/// its IPv4 traffic captured into a tunnel whose peer
/// cannot carry it. Build 2104: the flag gates the IPv4
/// half of the full-tunnel AllowedIPs default the Kotlin
/// hand-off composes for a peer carrying no AllowedIPs of
/// its own; a peer WITH AllowedIPs routes exactly per its
/// list in the backend's TUN builder — C2's intent as a
/// property of the new builder.
bool profileHasIpv4(Profile p) {
  bool v4Of(String entry) {
    final e = entry.trim();
    return e.isNotEmpty && !e.contains(':');
  }

  return p.localAddress.split(',').any(v4Of) ||
      p.wgAllowedIPs.split(',').any(v4Of);
}

/// True when the profile's tunnel interface carries an
/// IPv6 address (build 2103). This — not the Xray Settings
/// IPv6-route toggle — is the AWG service's ::/0 gate
/// since 2103: the toggle's default moved to OFF for the
/// Xray TUN (diagnosis D1/E1, v2rayNG parity), and a
/// v6-only WireGuard profile must keep its ::/0 route
/// under that default (the 2102 C3 coupling, decoupled).
///
/// The check is ADDRESSES ONLY (verification iteration 1,
/// L2): AwgVpnService's own hasV6 is derived from the
/// assigned TUN addresses and the Kotlin gate requires
/// `ipv6 && hasV6`, so an AllowedIPs-only v6 footprint
/// (a v4-address profile whose AllowedIPs list ::/0)
/// could never produce the route — counting it here
/// promised a route the service cannot give, for a shape
/// that has no v6 source address to send from anyway.
/// (profileHasIpv4 keeps its AllowedIPs half: its Kotlin
/// consumer, the hasV4 gate on the 0.0.0.0/0 route, is
/// driven by the passed flag itself, not re-derived.)
///
/// Build 2104 addendum: the flag's consumer changed, the
/// definition did not. The WG Tunnel backend derives its
/// routes from the Config's AllowedIPs, so an explicit
/// ::/0 in a profile's AllowedIPs now routes regardless
/// of this flag; the flag gates only the full-tunnel
/// AllowedIPs DEFAULT for a peer carrying none — and for
/// that default the addresses-only rule stays exactly
/// right: a ::/0 default without a v6 source address
/// would capture traffic the interface cannot send.
bool profileHasIpv6(Profile p) {
  bool v6Of(String entry) {
    final e = entry.trim();
    return e.isNotEmpty && e.contains(':');
  }

  return p.localAddress.split(',').any(v6Of);
}

/// The DNS the AWG tunnel is told to use (build 2102,
/// diagnosis C1): the profile's own .conf DNS when it
/// carries one — a v6-only profile's IPv6 resolvers are
/// the only ones reachable inside its tunnel, where the
/// Settings IPv4 local DNS is dropped by the peer — and
/// the Settings local DNS otherwise (the pre-2102
/// behaviour for profiles without a DNS line). The value
/// rides the existing setOnAwg dns argument as the
/// .conf's comma-separated list. Build 2104: the Kotlin
/// hand-off REPLACES the parsed Config's DNS with these
/// entries, and the backend's TUN builder family-filters
/// them into the TUN — C1's intent as a property of the
/// new engine (the profile's DNS wins, exactly as here).
String awgDnsFor(Profile p, XraySettings settings) =>
    p.wgDns.trim().isNotEmpty ? p.wgDns.trim() : settings.localDns;

/// The address families the WG Tunnel backend's TUN
/// builder will derive for [p]'s session (build 2110,
/// wg-start diagnosis A1): the backend computes
/// hasIpv4/hasIpv6 from the tunnel's interface addresses
/// UNION the peers' AllowedIPs — on the EFFECTIVE shape,
/// i.e. after the Kotlin hand-off's family-gated default
/// fills a blank AllowedIPs (0.0.0.0/0 when the profile
/// has an IPv4 footprint, ::/0 when it has an IPv6
/// address, 0.0.0.0/0 when neither). A family's test is
/// the backend's own: an entry containing ':' is IPv6.
({bool v4, bool v6}) awgTunnelFamilies(Profile p) {
  var v4 = false;
  var v6 = false;
  void eat(String entry) {
    final e = entry.trim();
    if (e.isEmpty) return;
    if (e.contains(':')) {
      v6 = true;
    } else {
      v4 = true;
    }
  }

  for (final a in p.localAddress.split(',')) {
    eat(a);
  }
  if (p.wgAllowedIPs.trim().isNotEmpty) {
    for (final a in p.wgAllowedIPs.split(',')) {
      eat(a);
    }
  } else {
    // The hand-off's default, mirrored: the flags it
    // consumes are profileHasIpv4 / profileHasIpv6.
    if (profileHasIpv4(p)) v4 = true;
    if (profileHasIpv6(p)) v6 = true;
    if (!v4 && !v6) v4 = true;
  }
  return (v4: v4, v6: v6);
}

/// The families [p]'s routes actually capture (build
/// 2116, audit WGX-1/WGX-2): read off the EFFECTIVE
/// AllowedIPs — the profile's own list, or the engine's
/// family-gated default when the peer carries none (the
/// same default [awgTunnelFamilies] mirrors). A family
/// with no route is NOT an error — split tunnels are
/// legitimate — but it must never be silent: a v6-only
/// profile leaves every IPv4 destination on the real
/// network (the owner's "WireGuard shows my Iranian IP"
/// report, 2026-11-19), and a v4-only profile does the
/// mirror image for IPv6.
({bool v4, bool v6}) wgRoutedFamilies(Profile p) {
  final allowed = p.wgAllowedIPs
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (allowed.isEmpty) {
    var v4 = profileHasIpv4(p);
    var v6 = profileHasIpv6(p);
    if (!v4 && !v6) v4 = true;
    return (v4: v4, v6: v6);
  }
  return (
    v4: allowed.any((e) => !e.contains(':')),
    v6: allowed.any((e) => e.contains(':')),
  );
}

/// The one-line warning for a single-family profile, or
/// null when both families are routed (build 2116): the
/// text names the family that stays outside, at import,
/// on the profile's row and in the connect journal.
String? wgUncoveredFamilyNote(Profile p) {
  final routed = wgRoutedFamilies(p);
  if (routed.v4 == routed.v6) return null;
  return routed.v6
      ? 'IPv6-only profile — IPv4 traffic stays outside '
            'the tunnel and keeps your current IP address.'
      : 'IPv4-only profile — IPv6 traffic stays outside '
            'the tunnel and keeps your current IP address.';
}

/// The same fact as [wgUncoveredFamilyNote], chip-sized
/// for the profile row.
String? wgUncoveredChipLabel(Profile p) {
  final routed = wgRoutedFamilies(p);
  if (routed.v4 == routed.v6) return null;
  return routed.v6
      ? 'IPv6-only — IPv4 stays outside'
      : 'IPv4-only — IPv6 stays outside';
}

/// The DNS handed to the AWG engine, family-guarded
/// (build 2110, wg-start diagnosis A1): awgDnsFor's value,
/// checked against the families the backend will actually
/// install (awgTunnelFamilies). The backend's TUN builder
/// DROPS every DNS server whose family the tunnel does
/// not carry — silently, one log warning — and Ember
/// passes no fake-DNS fallback, so a family mismatch
/// (a v6-only profile whose DNS is the Settings IPv4
/// local DNS; an IPv4 tunnel handed only IPv6 resolvers)
/// leaves the TUN with ZERO resolvers: name-based apps
/// fail while hardcoded-IP apps (Telegram) work — the
/// owner's "connects but only Telegram opens" report.
/// When every entry would be dropped, the family-matching
/// Cloudflare resolver is substituted (1.1.1.1 for an
/// IPv4-carrying tunnel, 2606:4700:4700::1111 for a
/// v6-only one) and the second record field carries the
/// journal line saying so. A DNS set with at least one
/// surviving entry passes through untouched, note null.
(String, String?) awgDnsGuardedFor(Profile p, XraySettings settings) {
  final dns = awgDnsFor(p, settings);
  final entries = dns
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (entries.isEmpty) return (dns, null);
  final fam = awgTunnelFamilies(p);
  bool survives(String e) => e.contains(':') ? fam.v6 : fam.v4;
  if (entries.any(survives)) return (dns, null);
  final substitute = fam.v4 ? '1.1.1.1' : '2606:4700:4700::1111';
  return (
    substitute,
    'The DNS for ${p.name} (${entries.join(', ')}) does not match '
        'this tunnel\'s address families — the engine would drop '
        'every server and leave the tunnel with no resolver at '
        'all. Using $substitute inside the tunnel instead.',
  );
}

/// The TUN DNS for a PLAIN WireGuard session (the Xray
/// core leg), family-guarded (build 2125, audit A25-23 /
/// P-19). The AWG engine leg has had this guard since
/// build 2110 ([awgDnsGuardedFor]); the plain leg handed
/// the Settings local DNS to the TUN builder unguarded,
/// and that builder drops every server whose family the
/// TUN does not carry — the plain TUN always carries
/// IPv4 and carries IPv6 only when the IPv6-route setting
/// is on, so an IPv6-only local DNS with the setting OFF
/// filtered to ZERO resolvers and name resolution died
/// inside a "Connected" session. When every entry would
/// be dropped, 1.1.1.1 (always carried) is substituted
/// and the second record field carries the journal line.
/// A set with at least one surviving entry passes through
/// untouched, note null.
(String, String?) wgPlainTunDnsGuarded(String dns, {required bool ipv6}) {
  final entries = dns
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (entries.isEmpty) return (dns, null);
  bool survives(String e) => e.contains(':') ? ipv6 : true;
  if (entries.any(survives)) return (dns, null);
  return (
    '1.1.1.1',
    'The tunnel DNS (${entries.join(', ')}) is IPv6-only, but '
        'this session\'s TUN carries no IPv6 (the IPv6 route '
        'setting is off) — the engine would drop every server '
        'and leave the tunnel with no resolver at all. Using '
        '1.1.1.1 inside the tunnel instead.',
  );
}

const _amneziaKeys = {
  'jc',
  'jmin',
  'jmax',
  's1',
  's2',
  's3',
  's4',
  'h1',
  'h2',
  'h3',
  'h4',
  // Build 2098 (Item A): the AWG 2.0 signature family —
  // up to 2097 these keys were not even recognised, so an
  // I1-carrying config imported with its signature packet
  // silently missing.
  'i1',
  'i2',
  'i3',
  'i4',
  'i5',
  'j1',
  'j2',
  'j3',
};

/// Parses [text] as a WireGuard `.conf`. [baseName] names the
/// profiles ("<baseName>" for one peer, "<baseName> · 1/N" for
/// several). [idFor] mints profile ids (the controller passes
/// its own generator; tests pass a counter).
WgConfResult parseWgConf(
  String text, {
  required String baseName,
  required String Function() idFor,
}) {
  final sections = <String, Map<String, String>>{};
  final peers = <Map<String, String>>[];
  Map<String, String>? current;
  var amnezia = false;

  // A byte-order mark (build 2033) must not hide the first
  // section header: files saved by Windows editors often
  // carry one, and the pre-2033 parser then reported
  // "no [Interface] section" for a perfectly good config —
  // one of the shapes of "the WireGuard config won't load".
  final body = text.startsWith('\uFEFF') ? text.substring(1) : text;

  for (final raw in body.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
      continue;
    }
    if (line.startsWith('[') && line.endsWith(']')) {
      final name = line.substring(1, line.length - 1).trim().toLowerCase();
      current = <String, String>{};
      if (name == 'peer') {
        peers.add(current);
      } else {
        sections[name] = current;
      }
      continue;
    }
    final eq = line.indexOf('=');
    if (eq <= 0 || current == null) continue;
    final key = line.substring(0, eq).trim().toLowerCase();
    // A trailing " # …" / " ; …" comment is cut (build 2033):
    // exported configs annotate values ("Endpoint = …:51820
    // # frankfurt"), and an uncut comment made the port parse
    // fail, which silently dropped the whole peer. None of
    // the values this parser reads (keys, endpoints, address
    // lists) can contain a space followed by # or ;, so the
    // cut is safe.
    final value = line
        .substring(eq + 1)
        .split(' #')
        .first
        .split(' ;')
        .first
        .trim();
    if (_amneziaKeys.contains(key)) amnezia = true;
    current[key] = value;
  }

  final iface = sections['interface'];
  if (iface == null) {
    return const WgConfResult(
      profiles: [],
      amnezia: false,
      error: 'no [Interface] section',
    );
  }
  final privateKey = iface['privatekey'] ?? '';
  if (privateKey.isEmpty) {
    return const WgConfResult(
      profiles: [],
      amnezia: false,
      error: 'the [Interface] section has no PrivateKey',
    );
  }
  if (peers.isEmpty) {
    return const WgConfResult(
      profiles: [],
      amnezia: false,
      error: 'no [Peer] section',
    );
  }
  final addresses = (iface['address'] ?? '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .join(',');
  // The .conf's DNS (build 2057, audit §6 WG .conf
  // divergences): stored and shown in the editor — the tunnel's
  // DNS always comes from Settings, so it is never silently
  // substituted for it.
  final dns = (iface['dns'] ?? '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .join(',');
  // MTU (build 2057, audit §6 WG .conf divergences): a conf
  // without MTU used to read 1280 while a link without `mtu`
  // reads 1420 — the two entry points disagreed against the
  // "one MTU" claim. 1420 is the WireGuard-standard value and
  // the link default, so the conf default matches it now.
  final mtu = int.tryParse(iface['mtu'] ?? '') ?? 1420;

  // AmneziaWG parameters (build 2033): they live in the
  // [Interface] section in the standard layout (a few
  // generators repeat them per [Peer]). They are stored on
  // every profile the file produces — import no longer drops
  // them — and since build 2040 they are APPLIED by the
  // AmneziaWG engine when the profile connects through the
  // fallback path (the pre-2040 comment claiming the carrier
  // runs them as plain WireGuard was stale; corrected here,
  // audit §7 comment-claims class, build 2057).
  String awgOf(Map<String, String> peer, String key) =>
      iface[key] ?? peer[key] ?? '';

  // Interface scripts (build 2116, audit C2-19): stored
  // and re-exported verbatim; never executed.
  final preUp = iface['preup'] ?? '';
  final postUp = iface['postup'] ?? '';
  final preDown = iface['predown'] ?? '';
  final postDown = iface['postdown'] ?? '';

  // Unmodelled keys (build 2116, audit W-03): whatever the
  // sections carried that this parser does not consume —
  // the AmneziaWG v3 device keys above all — is preserved
  // verbatim (Profile.wgExtraKeys) instead of silently
  // dropped, and re-emitted by wgConfFromProfile.
  const consumedIface = {
    'privatekey',
    'address',
    'dns',
    'mtu',
    'preup',
    'postup',
    'predown',
    'postdown',
  };
  const consumedPeer = {
    'publickey',
    'presharedkey',
    'endpoint',
    'allowedips',
    'persistentkeepalive',
  };
  Map<String, String> extrasOf(
    Map<String, String> section,
    Set<String> consumed,
  ) => {
    for (final e in section.entries)
      if (!consumed.contains(e.key) && !_amneziaKeys.contains(e.key))
        e.key: e.value,
  };
  final ifaceExtras = extrasOf(iface, consumedIface);
  String extraKeysFor(Map<String, String> peer, {required bool first}) {
    final peerExtras = extrasOf(peer, consumedPeer);
    if (peerExtras.isEmpty && (!first || ifaceExtras.isEmpty)) return '';
    return jsonEncode({
      if (first && ifaceExtras.isNotEmpty) 'i': ifaceExtras,
      if (peerExtras.isNotEmpty) 'p': peerExtras,
    });
  }

  final out = <Profile>[];
  for (var i = 0; i < peers.length; i++) {
    final peer = peers[i];
    final publicKey = peer['publickey'] ?? '';
    final endpoint = peer['endpoint'] ?? '';
    if (publicKey.isEmpty || endpoint.isEmpty) continue;
    final (host, port) = _splitEndpoint(endpoint);
    if (host.isEmpty || port <= 0) continue;
    // The peer's AllowedIPs (build 2057, audit §6 WG .conf
    // divergences): stored verbatim — the builder applies the
    // list to the outbound, so a split-tunnel conf no longer
    // silently becomes full-tunnel.
    final allowedIPs = (peer['allowedips'] ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .join(',');
    out.add(
      Profile(
        id: idFor(),
        name: peers.length == 1
            ? baseName
            : '$baseName · ${i + 1}/${peers.length}',
        protocol: Protocol.wireguard,
        address: host,
        port: port,
        secretKey: privateKey,
        peerPublicKey: publicKey,
        preSharedKey: peer['presharedkey'] ?? '',
        localAddress: addresses,
        mtu: mtu,
        keepAlive: int.tryParse(peer['persistentkeepalive'] ?? '') ?? 0,
        wgAllowedIPs: allowedIPs,
        wgDns: dns,
        wgPreUp: preUp,
        wgPostUp: postUp,
        wgPreDown: preDown,
        wgPostDown: postDown,
        // Each profile carries its own peer's extras; the
        // interface extras ride only on the first profile
        // a file produces (wgConfFromProfiles emits the
        // interface once).
        wgExtraKeys: extraKeysFor(peer, first: out.isEmpty),
        awgJc: awgOf(peer, 'jc'),
        awgJmin: awgOf(peer, 'jmin'),
        awgJmax: awgOf(peer, 'jmax'),
        awgS1: awgOf(peer, 's1'),
        awgS2: awgOf(peer, 's2'),
        awgS3: awgOf(peer, 's3'),
        awgS4: awgOf(peer, 's4'),
        awgH1: awgOf(peer, 'h1'),
        awgH2: awgOf(peer, 'h2'),
        awgH3: awgOf(peer, 'h3'),
        awgH4: awgOf(peer, 'h4'),
        awgI1: awgOf(peer, 'i1'),
        awgI2: awgOf(peer, 'i2'),
        awgI3: awgOf(peer, 'i3'),
        awgI4: awgOf(peer, 'i4'),
        awgI5: awgOf(peer, 'i5'),
        awgJ1: awgOf(peer, 'j1'),
        awgJ2: awgOf(peer, 'j2'),
        awgJ3: awgOf(peer, 'j3'),
      ),
    );
  }
  if (out.isEmpty) {
    return WgConfResult(
      profiles: [],
      amnezia: amnezia,
      error: 'no usable [Peer] (each needs PublicKey and Endpoint)',
    );
  }
  // Build 2095 (fourth-pass audit 4.1/1.4): the .conf
  // route passes the same import-boundary validation —
  // its endpoint splitter rejected port <= 0 but not
  // > 65535, and its AWG values are line-based too.
  for (final profile in out) {
    sanitizeImportedProfile(profile);
  }
  return WgConfResult(profiles: out, amnezia: amnezia, error: '');
}

/// Splits "host:port" and "[v6]:port" endpoints.
(String, int) _splitEndpoint(String endpoint) {
  final e = endpoint.trim();
  if (e.startsWith('[')) {
    final close = e.indexOf(']');
    if (close < 0) return ('', 0);
    final host = e.substring(1, close);
    final rest = e.substring(close + 1);
    if (!rest.startsWith(':')) return ('', 0);
    return (host, int.tryParse(rest.substring(1)) ?? 0);
  }
  final lastColon = e.lastIndexOf(':');
  if (lastColon <= 0) return ('', 0);
  return (
    e.substring(0, lastColon),
    int.tryParse(e.substring(lastColon + 1)) ?? 0,
  );
}

/// Serializes one profile back to `.conf` text (build 2095,
/// whole-app journey audit #33): the inverse of [parseWgConf]
/// for the single-peer case Ember's model carries. A WG
/// profile used to leave the app only as a wireguard:// link;
/// other WireGuard clients want the file. IPv6 endpoints are
/// bracketed, matching the parser's split.
///
/// Build 2104: this serializer is ALSO the AmneziaWG engine
/// hand-off — _connectAwg passes its output as setOnAwg's
/// settings, and the Kotlin side parses it with WG Tunnel's
/// own parser into the Config the backend runs. Every field
/// it writes (Jc/Jmin/Jmax, S1/S2, H1–H4, I1–I5 included)
/// is therefore load-bearing for the live tunnel, not only
/// for export.
/// The unmodelled keys [Profile.wgExtraKeys] carries for
/// one section ('i' = interface, 'p' = peer); empty when
/// the store is blank or malformed.
Map<String, String> _wgExtraSection(Profile p, String section) {
  if (p.wgExtraKeys.isEmpty) return const {};
  try {
    final decoded = jsonDecode(p.wgExtraKeys);
    if (decoded is! Map) return const {};
    final raw = decoded[section];
    if (raw is! Map) return const {};
    return {for (final e in raw.entries) e.key.toString(): e.value.toString()};
  } catch (_) {
    return const {};
  }
}

void _wgPeerSection(StringBuffer b, Profile p) {
  b
    ..writeln('[Peer]')
    ..writeln('PublicKey = ${p.peerPublicKey}');
  if (p.preSharedKey.isNotEmpty) {
    b.writeln('PresharedKey = ${p.preSharedKey}');
  }
  final host = p.address.contains(':') && !p.address.startsWith('[')
      ? '[${p.address}]'
      : p.address;
  b.writeln('Endpoint = $host:${p.port}');
  if (p.wgAllowedIPs.isNotEmpty) {
    b.writeln('AllowedIPs = ${p.wgAllowedIPs}');
  }
  if (p.keepAlive > 0) {
    b.writeln('PersistentKeepalive = ${p.keepAlive}');
  }
  // Unmodelled peer keys ride last (build 2116, W-03).
  for (final e in _wgExtraSection(p, 'p').entries) {
    b.writeln('${e.key} = ${e.value}');
  }
}

String wgConfFromProfile(Profile p) {
  final b = StringBuffer()
    ..writeln('[Interface]')
    ..writeln('PrivateKey = ${p.secretKey}');
  if (p.localAddress.isNotEmpty) {
    b.writeln('Address = ${p.localAddress}');
  }
  if (p.wgDns.isNotEmpty) {
    b.writeln('DNS = ${p.wgDns}');
  }
  if (p.mtu > 0) {
    b.writeln('MTU = ${p.mtu}');
  }
  // Interface scripts (build 2116, audit C2-19): written
  // back verbatim; never executed by either engine.
  if (p.wgPreUp.isNotEmpty) b.writeln('PreUp = ${p.wgPreUp}');
  if (p.wgPostUp.isNotEmpty) b.writeln('PostUp = ${p.wgPostUp}');
  if (p.wgPreDown.isNotEmpty) b.writeln('PreDown = ${p.wgPreDown}');
  if (p.wgPostDown.isNotEmpty) {
    b.writeln('PostDown = ${p.wgPostDown}');
  }
  void awg(String label, String value) {
    if (value.isNotEmpty) b.writeln('$label = $value');
  }

  awg('Jc', p.awgJc);
  awg('Jmin', p.awgJmin);
  awg('Jmax', p.awgJmax);
  awg('S1', p.awgS1);
  awg('S2', p.awgS2);
  awg('S3', p.awgS3);
  awg('S4', p.awgS4);
  awg('H1', p.awgH1);
  awg('H2', p.awgH2);
  awg('H3', p.awgH3);
  awg('H4', p.awgH4);
  // Build 2098 (Item A): the signature family writes back
  // too — export must not silently lose what import kept.
  awg('I1', p.awgI1);
  awg('I2', p.awgI2);
  awg('I3', p.awgI3);
  awg('I4', p.awgI4);
  awg('I5', p.awgI5);
  awg('J1', p.awgJ1);
  awg('J2', p.awgJ2);
  awg('J3', p.awgJ3);
  // Unmodelled interface keys ride last in the section
  // (build 2116, audit W-03).
  for (final e in _wgExtraSection(p, 'i').entries) {
    b.writeln('${e.key} = ${e.value}');
  }
  b.writeln();
  _wgPeerSection(b, p);
  return b.toString();
}

/// The engine hand-off for a whole peer group (build
/// 2116, audit C2-07 companion): one [Interface] — the
/// first profile's — and EVERY peer of the group, in
/// order. Builds up to 2115 handed the WG Tunnel engine
/// only the selected profile's single peer, so a
/// multi-peer .conf silently lost the rest of its peers
/// on the primary WireGuard engine. (The Xray-core path
/// keeps its own group handling, build 2075.)
String wgConfFromProfiles(List<Profile> group) {
  if (group.isEmpty) return '';
  if (group.length == 1) return wgConfFromProfile(group.single);
  final b = StringBuffer(wgConfFromProfile(group.first));
  for (final peer in group.skip(1)) {
    b.writeln();
    _wgPeerSection(b, peer);
  }
  return b.toString();
}
