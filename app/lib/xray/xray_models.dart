/// Data model of the V2Ray (Xray) engine: the configs the user keeps,
/// the subscriptions they came from, and the engine's settings. Ported
/// from the Ralysnd V2Ray client's Kotlin model, extended with
/// Hysteria2, WireGuard and TUIC profiles.

import 'dart:convert';

import 'dns_hosts.dart';
import 'profile_validation.dart';
import 'smart_groups.dart';
import 'sni_spoof.dart';
import 'zapret_args.dart';

enum Protocol {
  vless,
  vmess,
  trojan,
  shadowsocks,
  wireguard,
  hysteria2,
  tuic,
  socks,
  anytls,
  // An HTTP proxy (build 2057, audit §6 codec drop): Xray has a
  // native HTTP outbound, so http:// links parse into a real
  // profile instead of being silently skipped from subscriptions.
  http,
  // The sing-box sidecar protocols (build 2075): the vendored
  // Xray core has no outbound for these, but the sing-box
  // sidecar engine (libsingbox.so, SubprocessCore pattern)
  // speaks them — TUIC v5, Snell and NaiveProxy as outbounds,
  // Tailscale and OpenConnect as endpoints. See
  // [ProtocolSidecar.servedBySidecar].
  snell,
  naive,
  tailscale,
  openconnect,
  // Mieru (build 2075): sing-box has no Mieru outbound
  // (verified against sing-box 1.14.4 by config check), so
  // Mieru rides its own upstream client binary
  // (libmieru.so) as a second sidecar.
  mieru,
  // Sudoku (build 2127, H2): Hiddify's protocol — present
  // only in Hiddify's sing-box fork, and only under its
  // with_sudoku build tag — so it rides a third sidecar
  // binary built from that fork (libsudokubox.so), behind
  // the sudokuEnabled Settings switch.
  sudoku,
  // SSH (build 2147, feature #6): the sing-box sidecar has a
  // native ssh outbound (verified compiled into libsingbox.so,
  // sing-box v1.14.4 option/ssh.go) — TCP-only, noted wherever
  // the type is offered. Served only while the sidecarSshEnabled
  // settings gate is on (see XrayController.sshServed).
  ssh,
}

extension ProtocolLabel on Protocol {
  String get label => switch (this) {
    Protocol.vless => 'VLESS',
    Protocol.vmess => 'VMess',
    Protocol.trojan => 'Trojan',
    Protocol.shadowsocks => 'Shadowsocks',
    Protocol.wireguard => 'WireGuard',
    Protocol.hysteria2 => 'Hysteria2',
    Protocol.tuic => 'TUIC',
    Protocol.socks => 'SOCKS5',
    Protocol.anytls => 'AnyTLS',
    Protocol.http => 'HTTP',
    Protocol.snell => 'Snell',
    Protocol.naive => 'NaiveProxy',
    Protocol.tailscale => 'Tailscale',
    Protocol.openconnect => 'OpenConnect',
    Protocol.mieru => 'Mieru',
    Protocol.sudoku => 'Sudoku',
    Protocol.ssh => 'SSH',
  };

  /// Xray-core serves every protocol here except TUIC and AnyTLS,
  /// which it has no outbound for (both verified in the bundled
  /// fork's source, build 2033 for AnyTLS); SOCKS is a native
  /// Xray outbound. Unsupported protocols are parsed, stored and
  /// shareable, and refuse to connect with an explanation.
  /// True when the vendored Xray core itself has an outbound
  /// for this protocol. An explicit list (build 2075 fix):
  /// the old definition — "everything except TUIC and
  /// AnyTLS" — silently claimed core support for the five
  /// sidecar protocols the moment they joined the enum,
  /// though buildOutbound returns null for every one of
  /// them. The list below is exactly buildOutbound's switch.
  bool get supportedByCore =>
      this == Protocol.vless ||
      this == Protocol.vmess ||
      this == Protocol.trojan ||
      this == Protocol.shadowsocks ||
      this == Protocol.wireguard ||
      this == Protocol.hysteria2 ||
      this == Protocol.socks ||
      this == Protocol.http;
}

/// Which engine actually carries a protocol (build 2075).
extension ProtocolSidecar on Protocol {
  /// True when the sing-box sidecar engine serves this
  /// protocol: TUIC v5 (the Xray core never grew a TUIC
  /// outbound — the sidecar is what makes TUIC connectable
  /// at all), AnyTLS (build 2089: sing-box 1.14.4 has an
  /// anytls outbound, verified by `sing-box check` against
  /// the vendored binary), Snell, NaiveProxy, Tailscale,
  /// OpenConnect.
  bool get servedBySingBox =>
      this == Protocol.tuic ||
      this == Protocol.anytls ||
      this == Protocol.snell ||
      this == Protocol.naive ||
      this == Protocol.tailscale ||
      this == Protocol.openconnect;

  /// True when the Mieru sidecar client serves this protocol.
  bool get servedByMieru => this == Protocol.mieru;

  /// True when the protocol is SSH (build 2147, feature #6):
  /// the sing-box sidecar carries it, behind the
  /// sidecarSshEnabled Settings switch — the Sudoku shape:
  /// whether a given profile is ACTUALLY served is a settings
  /// decision too — see XrayController.sshServed.
  bool get servedBySsh => this == Protocol.ssh;

  /// True when the Sudoku sidecar (build 2127, H2: the
  /// Hiddify-fork binary) serves this protocol. Whether a
  /// given profile is ACTUALLY served is a settings
  /// decision too — see XrayController.sudokuServed.
  bool get servedBySudokuBox => this == Protocol.sudoku;

  /// True when a sidecar engine (not the Xray core) carries
  /// this profile's session: the connect path starts the
  /// sidecar first and the tunnel's proxy outbound becomes a
  /// plain SOCKS outbound aimed at the sidecar's local port.
  bool get servedBySidecar => servedBySingBox || servedByMieru;

  /// True when SOME engine in the app can connect this
  /// protocol today: the Xray core, or a 2075 sidecar —
  /// and, since build 2089, AnyTLS through the sing-box
  /// sidecar. No parsed protocol is unserved anymore.
  /// Sudoku counts as served (build 2127): its engine is
  /// in the app, behind its Settings switch — the switch
  /// being off is refused in plain words at connect, not
  /// by pretending the protocol is unknown.
  bool get connectable =>
      supportedByCore || servedBySidecar || servedBySudokuBox || servedBySsh;
}

/// The Hysteria2 congestion-control values Ember stores and
/// the patched core honours (build 2036, Iran-priority queue
/// 2d). '' is the core default (BBR standard). The builder,
/// the link parser and the share codec all check membership
/// here, so a value outside this set can never reach the core
/// or a shared link.
const hyCongestionChoices = <String>{
  '',
  'reno',
  'bbr-standard',
  'bbr-conservative',
  'bbr-aggressive',
};

/// Tolerant stored-value readers (build 2054, audit F-M16):
/// the established `is`-check pattern (WarpProfile._str/_bool
/// and the 2043/2050/2051 fields) generalised to all three
/// fromJson factories. A bare `as String?` throws on a
/// wrong-typed stored value (an int where a string belongs),
/// and that throw used to abort the whole settings load —
/// skipping selectedProfileId/warpProfile/cfGoodIps/shapeCache
/// and letting the next save persist defaults over the user's
/// settings. A wrong-typed value now reads as the fallback,
/// never a throw. The `id` fields stay strict casts: an entry
/// without a string id is unidentifiable, and _decodeList
/// drops it on its own instead of taking the store down.
String _storedStr(Map<String, dynamic> j, String key, String fallback) {
  final v = j[key];
  return v is String ? v : fallback;
}

bool _storedBool(Map<String, dynamic> j, String key, bool fallback) {
  final v = j[key];
  return v is bool ? v : fallback;
}

/// A stored string→int map (build 2149: the per-server
/// DNS ping results on a profile). Tolerant like every
/// reader here: a non-map value reads as empty, non-num
/// entries drop, non-finite numbers drop — never a throw.
Map<String, int> _storedIntMap(Map<String, dynamic> j, String key) {
  final v = j[key];
  if (v is! Map) return const {};
  return {
    for (final e in v.entries)
      if (e.key is String && e.value is num && (e.value as num).isFinite)
        e.key as String: (e.value as num).toInt(),
  };
}

int _storedInt(Map<String, dynamic> j, String key, int fallback) {
  final v = j[key];
  // Build 2098 (post-2097 audit M12): a JSON number can
  // itself decode non-finite (1e999 -> Infinity) — the
  // same throw as the string form below, on the numeric
  // branch. Non-finite numbers take the fallback.
  if (v is num) return v.isFinite ? v.toInt() : fallback;
  // Build 2096 (post-2095 audit M16): a synced or
  // restored document may carry a number as a string
  // ("port": "51820"); parse it instead of silently
  // taking the fallback (which pointed the profile at
  // :443). The subscription-JSON route got this pin in
  // build 2095; the store route did not.
  if (v is String) {
    final t = v.trim();
    // Build 2097 (post-2096 audit L-f): a stringified
    // double ("51820.0" — a synced document whose writer
    // emitted a float) parses too; build 2096's int-only
    // parse fell back to 443 for it, silently re-pointing
    // the profile.
    // Build 2098 (post-2097 audit M12): 'Infinity' and
    // 'NaN' also parse as doubles — but they are not finite
    // and .toInt() on them THROWS UnsupportedError; in the
    // Xray settings load that throw landed mid-document and
    // the fingerprint-migration save then persisted the
    // partial state over the store. Non-finite parses take
    // the fallback instead.
    final asInt = int.tryParse(t);
    if (asInt != null) return asInt;
    final asDouble = double.tryParse(t);
    if (asDouble != null && asDouble.isFinite) return asDouble.toInt();
    return fallback;
  }
  return fallback;
}

/// Names come from third parties (link fragments, VMess
/// `ps`, Clash names, the profile-title header) and from
/// the user's own renames, and are interpolated into the
/// UI and the diagnostics log. Control characters — line
/// breaks, bidi overrides, zero-width marks — become
/// spaces; the result is capped so a hostile name cannot
/// dominate a list row. Defined here (and re-exported by
/// profile_validation.dart) so the model itself can
/// sanitize [Profile.localName] at read time (build
/// 2096, post-2095 audit M5).
String sanitizeProfileName(String raw) {
  final buf = StringBuffer();
  for (final unit in raw.codeUnits) {
    final isControl =
        unit < 0x20 ||
        (unit >= 0x7F && unit <= 0x9F) ||
        unit == 0xFEFF ||
        (unit >= 0x202A && unit <= 0x202E) ||
        (unit >= 0x2066 && unit <= 0x2069) ||
        unit == 0x200B ||
        unit == 0x200E ||
        unit == 0x200F;
    buf.write(isControl ? ' ' : String.fromCharCode(unit));
  }
  var out = buf.toString().trim();
  if (out.length > 120) out = out.substring(0, 120).trim();
  return out;
}

/// A parsed Shadowsocks `shadow-tls` plugin (build 2126,
/// feature pick 3). The SIP002 plugin string a link carries
/// is `shadow-tls;host=…;password=…;version=3` —
/// semicolon-separated options after
/// the plugin name. [host] is the camouflage TLS server name
/// the front handshakes with; [password] is the ShadowTLS
/// password (NOT the Shadowsocks password — the server holds
/// both); [version] is 1, 2 or 3.
class ShadowTlsPlugin {
  const ShadowTlsPlugin({
    required this.host,
    required this.password,
    required this.version,
  });

  final String host;
  final String password;
  final int version;
}

/// Parses the verbatim SIP002 [plugin] string stored on a
/// Shadowsocks profile as a shadow-tls plugin, or null when
/// it is not one the sing-box sidecar can front: a different
/// plugin name, or a version outside 1–3 (a future version
/// stays on the unapplied-plugin path rather than being
/// fronted with a grammar this build cannot prove). An
/// absent version means 3 — the shadow-tls plugin's own
/// current default. Host/password completeness is NOT
/// judged here; singBoxConfigError reports a missing piece
/// in plain language at connect time.
ShadowTlsPlugin? parseShadowTlsPlugin(String plugin) {
  final segments = plugin.split(';').map((e) => e.trim()).toList();
  if (segments.isEmpty || segments.first.toLowerCase() != 'shadow-tls') {
    return null;
  }
  String opt(String key) {
    for (final seg in segments.skip(1)) {
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      if (seg.substring(0, eq).trim().toLowerCase() != key) continue;
      var value = seg.substring(eq + 1).trim();
      try {
        value = Uri.decodeComponent(value);
      } catch (_) {
        // Keep the raw value — a literal % in a password is
        // legal and must not cost the parse.
      }
      return value;
    }
    return '';
  }

  var version = 3;
  final versionText = opt('version');
  if (versionText.isNotEmpty) {
    final parsed = int.tryParse(versionText);
    if (parsed == null || parsed < 1 || parsed > 3) return null;
    version = parsed;
  }
  return ShadowTlsPlugin(
    host: opt('host'),
    password: opt('password'),
    version: version,
  );
}

class Profile {
  String id;
  String name;
  Protocol protocol;
  String address;
  int port;

  /// Protocol credentials: uuid (vless/vmess/tuic), password
  /// (trojan/hysteria2) or method+password (shadowsocks). For SOCKS
  /// profiles this holds the password and [username] the user.
  String uuidOrPassword;
  String method;

  /// SOCKS outbound username ('' = no-auth proxy).
  String username;

  /// Transport: tcp, ws, grpc, httpupgrade, xhttp, http, kcp, quic.
  String network;
  String headerType;
  String host;
  String path;
  String serviceName;
  String mode;

  /// XHTTP `extra` (build 2116, audit G-02): the link's or
  /// source config's extra xhttpSettings object (downloadSettings,
  /// xmux, padding…) as JSON text. Stored verbatim as carried;
  /// the builder decodes it and merges it into xhttpSettings,
  /// ignoring a value that is not a JSON object — a malformed
  /// extra must never break a connect. '' = none.
  String xhttpExtra;

  /// WebSocket early data (build 2116, audit G-03): the link's
  /// `ed` parameter, emitted as wsSettings `maxEarlyData` with
  /// the `Sec-WebSocket-Protocol` early-data header name. 0 =
  /// the link carried none, nothing is emitted.
  int wsEarlyData;

  /// Extra per-transport headers (build 2116, audit G-17) for
  /// the ws / httpupgrade / http transports, as a JSON object
  /// text (header name → value). The Host header is NOT in
  /// here — it lives in [host]; the JSON-config import splits
  /// it out, and the builder merges it back. Stored verbatim;
  /// the builder ignores a value that is not a JSON object.
  /// '' = none.
  String transportHeaders;

  /// Security: "", tls, reality.
  String security;
  String sni;
  String alpn;
  String fingerprint;

  /// TLS cipher suites offered to the server, colon-separated
  /// IANA names (build 2029A, stock Xray PR #6450 semantics —
  /// the same field the anti-filter unfilter shape sets).
  /// Only meaningful with TLS security, and the core honours
  /// it only alongside the "unsafe" fingerprint, which the
  /// editor enforces. '' = the core default.
  String cipherSuites;

  /// The patched core's first-flight desync mode (build 2030,
  /// patterniha/xray-core @ f990395): exact text the core reads
  /// as written — never trimmed or case-folded. The "oob."
  /// family appends one urgent byte per leading write
  /// ("oob.0" appends 0x00 to the first write; "_" in the list
  /// is a passthrough slot). '' = off. Stock Xray has no such
  /// field and silently ignores it in a config; only the
  /// patched core honours it.
  String dialMode;

  /// Finalmask JSON for this profile's stream (build 2030,
  /// patched core): the whole finalmask object as JSON text,
  /// e.g. {"tcp":[{"type":"merge","settings":{"times":3,
  /// "delayMs":8,"maxBytes":2048}}]}. '' = none. PattNG keeps
  /// the same whole-JSON field on its profiles.
  String finalMask;
  String publicKey;
  String shortId;
  String spiderX;
  String flow;

  /// REALITY post-quantum verification (build 2057, audit
  /// F-M13): the `pqv` link parameter — the ML-DSA-65 public
  /// key the core verifies the handshake against
  /// (`mldsa65Verify` in the core's realitySettings). '' = the
  /// server does not require PQ verification, as before.
  String pqv;

  /// VMess (build 2057, audit §6 codec drops): the link's `aid`
  /// and `scy` — the builder used to hardcode `alterId: 0,
  /// security: 'auto'`, so a non-zero-alterId server failed
  /// silently and a non-auto cipher was never honoured. 0 / ''
  /// = the old defaults, so a profile stored by an older build
  /// upgrades unchanged.
  int aid;
  String scy;

  /// gRPC authority (build 2057, audit §6 codec drops): the
  /// `:authority` the core sends on the gRPC handshake
  /// (`grpcSettings.authority`). '' = the core default (the
  /// server name), as before.
  String grpcAuthority;

  /// VLESS Encryption (build 2046): the post-quantum-encrypted
  /// VLESS user string the link carried, e.g.
  /// `mlkem768x25519plus.native.0rtt.<key>` — parsed from the
  /// `encryption` parameter of vless:// links, emitted verbatim
  /// into the outbound user's `encryption` field, and round-tripped
  /// by share links. The bundled core (XTLS v26.11.1) runs it; ''
  /// = no VLESS encryption, the builder emits 'none' as before.
  /// Only a value passing [isValidVlessEncryption] is ever stored
  /// from a link or the editor, and the builder re-validates at
  /// emit time, so a corrupt store can never break a connect.
  String vlessEncryption;

  bool get hasVlessEncryption => vlessEncryption.isNotEmpty;

  /// TLS certificate pin (build 2047): the SHA-256 hash(es) of the
  /// server certificate the core must see, as the bundled core's
  /// tlsSettings `pinnedPeerCertSha256` — comma-separated 64-hex-char
  /// values, colons allowed (the core's own format; see
  /// tls_cert_pin.dart). The core checks the leaf cert first, then
  /// any CA in the chain, so pinning an intermediate/CA also works.
  /// Only a value passing [isValidTlsCertPin] is ever stored from a
  /// link or the editor, and the builder re-validates at emit time,
  /// so a corrupt store can never break a connect. '' = no pinning,
  /// the core's normal chain verification. Only meaningful with TLS
  /// security. (Build 2149, diagnosis D3: allowInsecure is
  /// honoured again as the link's own flag — see
  /// [allowInsecure]; the pin remains the stronger option
  /// when a link carries one.)
  String tlsCertPin;

  bool get hasTlsCertPin => tlsCertPin.isNotEmpty;

  /// SSH credentials (build 2147, feature #6 — Protocol.ssh
  /// profiles only): the sidecar's ssh outbound authenticates
  /// with [sshPassword] or [sshPrivateKey] (+ its passphrase);
  /// [sshHostKeyPin] optionally pins the host key (the sing-box
  /// `host_key` list — a full OpenSSH-format key line). All
  /// empty = the profile cannot authenticate and the connect
  /// path says so. [sshUser] defaults to 'root' at build time
  /// when empty.
  String sshUser;
  String sshPassword;
  String sshPrivateKey;
  String sshPrivateKeyPassphrase;
  String sshHostKeyPin;

  /// XDNS FinalMask (build 2147, feature #7): when
  /// [xdnsDomain] is set on an mKCP-carried profile, the
  /// builder appends an xdns UDP finalmask — DNS-tunnelled
  /// transport via [xdnsResolver] (udp://host:53; the carrier
  /// default 8.8.8.8 at build time when empty). Empty domain =
  /// no mask, byte-identical configs.
  String xdnsDomain;
  String xdnsResolver;

  /// XICMP FinalMask (build 2147, feature #8): when on, the
  /// builder appends an xicmp UDP finalmask (ICMP-echo proxied
  /// transport, mKCP-carried profiles). [xicmpDgram] selects
  /// the datagram form. Off = no mask. Device risk recorded in
  /// build2147-design.md: the client core opening ICMP sockets
  /// under Android's sandbox is device-provable only.
  bool xicmpEnabled;
  bool xicmpDgram;

  /// WireGuard fallback endpoints (build 2147, feature #10):
  /// a comma-separated ordered list of host:port endpoints
  /// tried after the profile's own address:port when the WG
  /// handshake times out. Empty = single-endpoint behaviour,
  /// byte-identical.
  String wgFallbackEndpoints;

  /// Dead-config quarantine (build 2147, features #20 + #21a):
  /// [quarantineStrikes] counts consecutive handshake failures
  /// on [quarantineNetwork] (the network fingerprint at the
  /// last failure); at the sweep/quarantine threshold the
  /// profile is [quarantined] — disabled and listed in the
  /// quarantine surface with [quarantineReason], restorable,
  /// never deleted. All defaults = never counted, never cut.
  int quarantineStrikes;
  String quarantineNetwork;
  String quarantineReason;
  bool quarantined;

  /// Shadowsocks 2022 / plugin.
  String plugin;

  /// True when this profile's Shadowsocks plugin can never be
  /// applied (build 2057, audit F-M11): the bundled core has no
  /// plugin support, so an `obfs-local` link imports cleanly and
  /// would connect WITHOUT the plugin and fail the handshake
  /// with no hint. The profile is badged in the UI and the
  /// connect path journals the fact — the same honesty TUIC and
  /// AnyTLS get, short of refusing a protocol the core DOES
  /// serve.
  bool get hasUnsupportedPlugin =>
      protocol == Protocol.shadowsocks && plugin.isNotEmpty;

  /// The profile's ShadowTLS front (build 2126, feature
  /// pick 3): the parsed `shadow-tls` plugin when the stored
  /// SIP002 plugin string is one, else null. Parsed at read
  /// time from [plugin] — no new stored fields. Whether the
  /// front is APPLIED is a settings decision (the ShadowTLS
  /// fronting toggle): the sing-box sidecar serves such a
  /// profile while the toggle is on (see
  /// XrayController.shadowTlsServed); while it is off the
  /// plugin stays unapplied, exactly as before.
  ShadowTlsPlugin? get shadowTlsPlugin =>
      protocol == Protocol.shadowsocks
      ? parseShadowTlsPlugin(plugin)
      : null;

  /// True when this Hysteria2 profile's obfs type is one
  /// no engine in the app applies (build 2095, fourth-pass
  /// audit 3.5): `salamander` is built as a finalmask on
  /// the Xray path, and build 2116 (audit G-01/G-02 rows
  /// B2-2/B2-7) routes `gecko` profiles to the sing-box
  /// sidecar, which applies it. Anything else would
  /// connect WITHOUT obfuscation and fail the handshake
  /// unexplained. Badged and journaled like the
  /// Shadowsocks plugin case.
  bool get hasUnappliedObfs =>
      protocol == Protocol.hysteria2 &&
      obfs.isNotEmpty &&
      obfs != 'salamander' &&
      obfs != 'gecko';

  /// True when the sing-box sidecar serves this Hysteria2
  /// profile instead of the Xray core (build 2116, audit
  /// B2-2/B2-7): the bundled Xray core has no port-hopping
  /// field and no gecko obfs, the sidecar has both — so a
  /// profile carrying an `mport` range or gecko obfs is
  /// served by the sidecar and both are really applied.
  bool get hy2SidecarServed =>
      protocol == Protocol.hysteria2 && (hyMport.isNotEmpty || obfs == 'gecko');

  /// The profile-level sidecar truth: the protocol's own
  /// sidecar routing ([ProtocolSidecar.servedBySidecar])
  /// plus the per-profile Hysteria2 diversion above. The
  /// connect path, the pin machinery and the test paths
  /// decide from THIS, never from the protocol alone.
  bool get servedBySidecar => protocol.servedBySidecar || hy2SidecarServed;

  /// True when this profile pairs REALITY with a
  /// transport the core cannot load it on (QUIC/KCP).
  /// The profile keeps the security its source carried;
  /// the config builder substitutes TLS at emit time and
  /// the connect path journals the substitution (build
  /// 2096, post-2095 audit M1 — build 2095's import
  /// boundary rewrote the stored value silently instead).
  bool get hasRealityTransportMismatch =>
      security == 'reality' && (network == 'quic' || network == 'kcp');

  /// True when the source config carried Hysteria2 port
  /// hopping no engine applies. Build 2116 (audit B2-2):
  /// an mport profile is served by the sing-box sidecar,
  /// which applies the hopping — so this is now always
  /// false for Hysteria2, and the getter survives only so
  /// the honesty surface has one place that would light
  /// up again if a future protocol stored hopping it
  /// could not apply.
  bool get hasIgnoredPortHopping =>
      protocol == Protocol.hysteria2 && hyMport.isNotEmpty && !hy2SidecarServed;

  /// The TCP header-camouflage types the bundled core
  /// accepts on a plain TCP stream (build 2116, audit
  /// G-16), keyed by the value a link stores: the same
  /// registry the KCP/QUIC paths already emit raw into
  /// this core. `wechat` is the link spelling of the
  /// core's `wechat-video` header.
  static const tcpHeaderCamouflage = <String, String>{
    'srtp': 'srtp',
    'utp': 'utp',
    'dtls': 'dtls',
    'wireguard': 'wireguard',
    'wechat': 'wechat-video',
    'wechat-video': 'wechat-video',
  };

  /// The core header type for this profile's stored
  /// [headerType] on a TCP stream, or null when there is
  /// nothing to emit (empty, `http` — which has its own
  /// request template — or a type the core cannot emit).
  String? get tcpHeaderType =>
      network == 'tcp' ? tcpHeaderCamouflage[headerType] : null;

  /// True when a TCP profile carries a header-camouflage
  /// type the core cannot emit (build 2116, audit G-16):
  /// before this build it was silently ignored and the
  /// profile ran as plain TCP with no hint; now the
  /// connect path journals it, like the other honesty
  /// cases.
  bool get hasUnappliedTcpHeader =>
      network == 'tcp' &&
      headerType.isNotEmpty &&
      headerType != 'http' &&
      !tcpHeaderCamouflage.containsKey(headerType);

  /// WireGuard.
  String secretKey;
  String peerPublicKey;
  String preSharedKey;
  String localAddress;
  String reserved;
  int mtu;
  int keepAlive;

  /// The .conf's per-peer AllowedIPs and [Interface] DNS (build
  /// 2057, audit §6 WG .conf divergences): the builder applies
  /// the AllowedIPs list to the outbound (a split-tunnel conf no
  /// longer silently becomes full-tunnel); the DNS is stored and
  /// shown, but the tunnel's DNS always comes from Settings —
  /// the builder cannot take a per-profile TUN DNS, so the
  /// editor says so instead of pretending otherwise.
  String wgAllowedIPs;
  String wgDns;

  /// The .conf's interface scripts (build 2116, audit
  /// C2-19): PreUp/PostUp/PreDown/PostDown, stored and
  /// re-exported verbatim. They are NEVER executed —
  /// neither engine runs interface scripts (the WG Tunnel
  /// backend is started with scripts disabled) — carrying
  /// them is round-trip fidelity, not a feature.
  String wgPreUp;
  String wgPostUp;
  String wgPreDown;
  String wgPostDown;

  /// .conf keys the app does not model (build 2116, audit
  /// W-03): a JSON object {"i": {…}, "p": {…}} holding the
  /// unrecognised [Interface] / first-[Peer] keys a .conf
  /// carried — the AmneziaWG v3 device keys (timing
  /// controls, content padding, header protection) above
  /// all — stored verbatim and re-emitted by
  /// [wgConfFromProfile], so the engine hand-off and the
  /// export carry them instead of silently dropping them.
  /// '' = none.
  String wgExtraKeys;

  /// Hysteria2.
  String obfs;
  String obfsPassword;
  /// Hysteria2 port-hopping range from the source link
  /// or Clash entry (build 2095, fourth-pass audit 3.4).
  /// Builds ≤2115 carried it so the drop was VISIBLE —
  /// the Xray core does not apply port hopping; build
  /// 2116 (audit B2-2) serves an mport profile through
  /// the sing-box sidecar, which applies it for real
  /// (see [hy2SidecarServed]).
  String hyMport;

  /// Hysteria2 gecko obfs packet-size band (build 2126,
  /// D1): carried from the share link's gecko packet-size
  /// params (3x-ui link format); 0 = unset. The sidecar
  /// emits them into the gecko obfs block only while the
  /// geckoPacketSizes setting is on — off, a gecko
  /// profile's config is byte-identical to build 2125.
  int geckoMinPacketSize;
  int geckoMaxPacketSize;
  int upMbps;
  int downMbps;

  /// Hysteria2 congestion control (build 2036, Iran-priority
  /// queue 2d): the QUIC congestion control the core runs for
  /// this profile's Hysteria2 handshake — '' = the core default
  /// (BBR standard, today's behaviour), 'reno' = the transport
  /// default without BBR, 'bbr-standard' / 'bbr-conservative' /
  /// 'bbr-aggressive' = BBR with that profile. The patched core
  /// honours exactly these values (its QuicParamsConfig); any
  /// other stored value is dropped by the builder, never sent.
  String hyCongestion;

  /// Build 2095 (V2Ray journey audit #27): the per-profile
  /// mux override — '' inherits the global mux setting,
  /// 'on' forces mux for this profile, 'off' forbids it.
  /// Only the mux-eligible protocols (vless/vmess/trojan/
  /// shadowsocks) honour it; the builder decides.
  String muxOverride;

  /// ECH (Encrypted Client Hello) config list for this profile's
  /// TLS handshake (build 2033), as the core's tlsSettings
  /// `echConfigList` text: either a base64 ECHConfigList or a
  /// query form like "cloudflare-ech.com+udp://1.1.1.1".
  /// '' = ECH off. Parsed from the `ech` parameter of share
  /// links (the name Xray's own link import uses), and emitted
  /// by the Hysteria2 outbound — whose handshake is where a
  /// filtered network reads the SNI — and by plain TLS streams
  /// when set and the anti-filter ECH shape is not.
  String echConfigList;

  /// AmneziaWG obfuscation parameters (build 2033), stored
  /// verbatim as the .conf / link carried them (values may be
  /// ranges like "5-10", so they stay strings): Jc, Jmin, Jmax,
  /// S1, S2, H1, H2, H3, H4. They are PRESERVED on the profile —
  /// import keeps them, export writes them back — and since
  /// build 2040 (queue 2h) they are APPLIED by the AmneziaWG
  /// engine (build 2104: WG Tunnel's amneziawg-go backend),
  /// which runs a profile carrying them obfuscated; a peer
  /// the obfuscated engine cannot start for falls back to
  /// plain WireGuard through Xray. '' = the parameter was
  /// not present.
  String awgJc;
  String awgJmin;
  String awgJmax;
  String awgS1;
  String awgS2;
  // Build 2104 (verification iteration 1, finding 17):
  // S3/S4 complete the AmneziaWG 2.0 padding set — the WG
  // Tunnel v3 parser and engine carry them, and builds
  // ≤2103 silently dropped them at import.
  String awgS3;
  String awgS4;
  String awgH1;
  String awgH2;
  String awgH3;
  String awgH4;

  /// AmneziaWG 2.0 signature parameters (build 2098, Item
  /// A): I1–I5 (special junk packets sent before the
  /// handshake initiation) and J1–J3 (controlled junk),
  /// stored verbatim as the .conf carried them — each is a
  /// DSL string ("<r 2><b 0x…>"), not a number. Builds up
  /// to 2097 DROPPED them at import: the parser ignored
  /// the keys and no field existed, so a config whose
  /// obfuscation is exactly these packets (the owner's
  /// WARP template) ran its AWG attempt without its
  /// signature packet. [wgConfFromProfile] writes them
  /// back. Build 2104: I1–I5 survive the engine swap — the
  /// WG Tunnel parser carries them in .conf form and its
  /// amneziawg-go v3 device runs them; J1–J3 stay stored
  /// and exported, but the v3 parameter set has no slot
  /// for them, so the backend never receives them — a
  /// named loss, recorded in BUILD-LOG-2.md. '' = not
  /// present.
  String awgI1;
  String awgI2;
  String awgI3;
  String awgI4;
  String awgI5;
  String awgJ1;
  String awgJ2;
  String awgJ3;

  /// True when this profile carries any AmneziaWG parameter.
  /// This is the storage/export truth — every parameter the
  /// .conf carried, J1–J3 included (they round-trip through
  /// import, the store and .conf export verbatim). It is NOT
  /// the engine-routing truth since build 2106: see
  /// [hasSupportedAmneziaParams].
  bool get hasAmneziaParams =>
      awgJc.isNotEmpty ||
      awgJmin.isNotEmpty ||
      awgJmax.isNotEmpty ||
      awgS1.isNotEmpty ||
      awgS2.isNotEmpty ||
      awgS3.isNotEmpty ||
      awgS4.isNotEmpty ||
      awgH1.isNotEmpty ||
      awgH2.isNotEmpty ||
      awgH3.isNotEmpty ||
      awgH4.isNotEmpty ||
      awgI1.isNotEmpty ||
      awgI2.isNotEmpty ||
      awgI3.isNotEmpty ||
      awgI4.isNotEmpty ||
      awgI5.isNotEmpty ||
      awgJ1.isNotEmpty ||
      awgJ2.isNotEmpty ||
      awgJ3.isNotEmpty;

  /// True when this profile carries J1–J3 — the AmneziaWG
  /// parameters the WG Tunnel backend has NO slot for (build
  /// 2104 named loss): its parser silently discards them, so
  /// they never reach the device. They stay stored and
  /// exported (other clients can use them), but nothing in
  /// the app may present them as applied obfuscation (build
  /// 2106, journey audit F-05).
  bool get hasUnsupportedJParams =>
      awgJ1.isNotEmpty || awgJ2.isNotEmpty || awgJ3.isNotEmpty;

  /// True when this profile carries at least one AmneziaWG
  /// parameter the WG Tunnel engine actually runs (Jc, Jmin,
  /// Jmax, S1–S4, H1–H4, I1–I5 — everything except J1–J3).
  /// THIS is the routing/labelling truth since build 2106
  /// (journey audit F-05): a profile whose only Amnezia
  /// parameters are J1–J3 takes the plain WireGuard path and
  /// is labelled WireGuard, because the obfuscated engine
  /// would apply exactly nothing for it.
  bool get hasSupportedAmneziaParams =>
      awgJc.isNotEmpty ||
      awgJmin.isNotEmpty ||
      awgJmax.isNotEmpty ||
      awgS1.isNotEmpty ||
      awgS2.isNotEmpty ||
      awgS3.isNotEmpty ||
      awgS4.isNotEmpty ||
      awgH1.isNotEmpty ||
      awgH2.isNotEmpty ||
      awgH3.isNotEmpty ||
      awgH4.isNotEmpty ||
      awgI1.isNotEmpty ||
      awgI2.isNotEmpty ||
      awgI3.isNotEmpty ||
      awgI4.isNotEmpty ||
      awgI5.isNotEmpty;

  /// True when this profile's AmneziaWG parameters rewrite
  /// the WireGuard handshake ITSELF (build 2110,
  /// wg-start diagnosis D1): a non-zero S1/S2 prepends random
  /// bytes to an initiation/response datagram, and an Hx
  /// outside its standard value replaces that message's type
  /// field — the engine rules wg_probe.dart's header records.
  /// A server that is not an AmneziaWG server (a vanilla
  /// WireGuard endpoint — Cloudflare WARP above all) silently
  /// drops such datagrams: the TUN comes up and no handshake
  /// ever completes. Junk (Jc/Jmin/Jmax) and the I1–I5
  /// signatures travel as SEPARATE datagrams a vanilla server
  /// simply ignores, so they do NOT count as shaping. S3/S4
  /// shape the cookie/keepalive messages, which only exist
  /// after a handshake — they cannot block the initiation,
  /// so they do not count either. Values are strings and may
  /// be ranges ("5-10"): shaping means the value CAN produce
  /// a non-zero / non-standard outcome; an unparseable
  /// non-empty value counts as shaping (conservative — the
  /// de-shaped retry it gates is harmless to a genuine
  /// AmneziaWG profile only in that it runs after the shaped
  /// attempt already failed to be answered).
  bool get hasInitiationShaping {
    bool sShapes(String v) {
      final t = v.trim();
      if (t.isEmpty) return false;
      final single = int.tryParse(t);
      if (single != null) return single > 0;
      final parts = t.split('-');
      if (parts.length == 2) {
        final hi = int.tryParse(parts[1].trim());
        if (hi != null) return hi > 0;
      }
      return true;
    }

    bool hShapes(String v, int standard) {
      final t = v.trim();
      if (t.isEmpty) return false;
      final single = int.tryParse(t);
      if (single != null) return single != standard;
      final parts = t.split('-');
      if (parts.length == 2) {
        final lo = int.tryParse(parts[0].trim());
        final hi = int.tryParse(parts[1].trim());
        if (lo != null && hi != null) return !(lo == standard && hi == standard);
      }
      return true;
    }

    return sShapes(awgS1) ||
        sShapes(awgS2) ||
        hShapes(awgH1, 1) ||
        hShapes(awgH2, 2) ||
        hShapes(awgH3, 3) ||
        hShapes(awgH4, 4);
  }

  /// A copy with the initiation shaping neutralized (build
  /// 2110): S1–S4 zeroed, H1–H4 at their standard WireGuard
  /// type values — the handshake is byte-for-byte vanilla
  /// WireGuard. Junk (Jc/Jmin/Jmax) and the I1–I5 signatures
  /// are KEPT: they ride separate datagrams and cannot block
  /// a handshake. The stored profile is never rewritten —
  /// this copy exists only for one connect attempt.
  Profile copyWithoutInitiationShaping() {
    final c = copy();
    c.awgS1 = '0';
    c.awgS2 = '0';
    c.awgS3 = '0';
    c.awgS4 = '0';
    c.awgH1 = '1';
    c.awgH2 = '2';
    c.awgH3 = '3';
    c.awgH4 = '4';
    return c;
  }

  /// TUIC.
  String congestionControl;
  String udpRelayMode;

  /// TUIC extras (build 2116, audit G-21/S-01): carried
  /// from the link into the sing-box outbound — the only
  /// engine that serves TUIC. [tuicAllowInsecure] is the
  /// link's own allow_insecure flag: the Xray core removed
  /// allowInsecure outright (build 2048) and Ember never
  /// emits it there, but sing-box honours the flag, and
  /// dropping it silently broke links that depend on it.
  bool zeroRttHandshake;
  String tuicHeartbeat;
  bool udpOverStream;
  bool disableSni;
  bool tuicAllowInsecure;

  /// The link's own allowInsecure flag for TLS profiles
  /// (build 2149, diagnosis D3): builds 2048–2148 dropped
  /// it at parse on the claim that the core refuses the
  /// key — so a TLS profile whose origin presents a
  /// self-signed or wrong-name certificate (the links
  /// that carry allowInsecure=1) could NEVER connect in
  /// Ember while v2rayNG, which parses and emits the
  /// flag, connected. Now parsed, stored, and emitted
  /// (tlsSettings.allowInsecure) exactly as v2rayNG does
  /// — ONLY when the link/profile sets it; the default
  /// stays false (full verification), and a config whose
  /// profile never set it stays byte-identical.
  bool allowInsecure;

  /// NaiveProxy extra link parameters (build 2116, audit
  /// S-02) as JSON text: every query parameter the parser
  /// does not consume (padding, insecure_concurrency,
  /// quic, …), stored verbatim so an import no longer
  /// drops them silently. The sing-box emitter applies
  /// the subset sing-box supports; the rest is journaled
  /// at connect ([hasUnappliedNaivePadding]).
  String naiveExtraParams;

  /// The decoded [naiveExtraParams] map ({} when absent
  /// or malformed).
  Map<String, String> get naiveExtras {
    if (naiveExtraParams.isEmpty) return const {};
    try {
      final decoded = jsonDecode(naiveExtraParams);
      if (decoded is Map) {
        return {
          for (final e in decoded.entries)
            e.key.toString(): e.value.toString(),
        };
      }
    } catch (_) {
      // A corrupt store reads as no extras.
    }
    return const {};
  }

  /// True when the profile carries a NaiveProxy padding
  /// parameter sing-box cannot apply (its naive outbound
  /// has no padding option — verified against the
  /// vendored 1.14.4 option set): journaled at connect
  /// instead of dropped silently (build 2116, S-02).
  bool get hasUnappliedNaivePadding =>
      protocol == Protocol.naive && naiveExtras.containsKey('padding');

  /// Build 2157 (feature pick 2): why this proxy is NOT
  /// secure — its traffic crosses the network path in a
  /// form anyone on that path can read — or null when it
  /// is not. The set is the plain shapes: an HTTP or
  /// SOCKS proxy without a TLS wrap (the proxy leg itself
  /// is cleartext, credentials included), and Shadowsocks
  /// with the 'none' method (no cipher at all). Protocols
  /// with their own cryptography (VMess, Trojan, TUIC,
  /// Hysteria2, WireGuard…) are never in this set, and a
  /// TLS-wrapped HTTP/SOCKS proxy is not either. The
  /// config list's "Not secure" badge reads this; it is
  /// display-only — nothing about the profile or its
  /// connect changes.
  String? get insecureProxyReason {
    if (protocol == Protocol.http && security != 'tls') {
      return 'an HTTP proxy with no encryption';
    }
    if (protocol == Protocol.socks && security != 'tls') {
      return 'a SOCKS proxy with no encryption';
    }
    if (protocol == Protocol.shadowsocks &&
        (method.isEmpty || method.toLowerCase() == 'none')) {
      return 'Shadowsocks with the "none" method — no encryption';
    }
    return null;
  }

  /// True when the config list marks this profile
  /// "Not secure" (see [insecureProxyReason]).
  bool get isInsecureProxy => insecureProxyReason != null;

  /// Sudoku options (build 2127, H2) as JSON text: the
  /// protocol's tuning (aeadMethod, paddingMin/Max,
  /// tableType, pureDownlink, customTable, httpMask…)
  /// stored as one object, the naiveExtraParams shape.
  /// The key itself rides [uuidOrPassword]. The emitter
  /// (sudoku_config.dart) applies the subset it knows;
  /// '' = the core's defaults for everything.
  String sudokuOptions;

  /// Build 2127 (H1): the DPI Lab zap candidate this
  /// copy dials through ('' = none). RUNTIME ONLY — set
  /// by profileWithCandidate on the exact copy the
  /// config builders read, never persisted (absent from
  /// toJson/fromJson, so Profile.copy drops it): the
  /// stored profile never carries a desync proxy, the
  /// Lab's remembered win re-derives it per connect.
  String zapretStrategy;

  /// The decoded [sudokuOptions] map ({} when absent
  /// or malformed).
  Map<String, dynamic> get sudokuOpts {
    if (sudokuOptions.isEmpty) return const {};
    try {
      final decoded = jsonDecode(sudokuOptions);
      if (decoded is Map) {
        return {for (final e in decoded.entries) e.key.toString(): e.value};
      }
    } catch (_) {
      // A corrupt store reads as no options.
    }
    return const {};
  }

  /// Snell (build 2075): the protocol version. sing-box
  /// 1.14.4 accepts version 4 (its version-5 shape was
  /// rejected by config check during development), so 4 is
  /// the only value the editor offers; the psk rides
  /// [uuidOrPassword] and the optional obfs rides
  /// [obfs]/[obfsPassword] (type / host) like Hysteria2's.
  int snellVersion;

  /// Tailscale (build 2075): the tailnet auth key the
  /// sing-box endpoint logs in with (tskey-auth-…). Stored
  /// on the profile like a WireGuard secret key — profiles
  /// are the app's credential store. '' = the endpoint
  /// cannot log in and the connect says so plainly.
  String tailscaleAuthKey;

  /// The last raw TCP-connect probe result (build 2075,
  /// feature item 14): milliseconds to open a TCP connection
  /// to this profile's endpoint, -1 unknown. A reachability
  /// signal only — it says nothing about the handshake or
  /// the exit, and the UI labels it that way.
  int tcpPingMs;

  /// Build 2095 (V2Ray journey audit, batch 8): the last
  /// speed test's rate (bytes/s, -1 = never measured). The
  /// result used to live only in a SnackBar — the row now
  /// shows it until a newer test replaces it.
  int lastSpeedBps;

  /// Build 2149 (owner expansion 2 — Karing-style node
  /// diagnostics): the last full node test's UPLOAD rate
  /// (bytes/s, -1 = never measured) and when that test ran
  /// (epoch ms, 0 = never). [lastSpeedBps] is the same
  /// test's download rate. All three persist with the
  /// profile (store + stats sidecar) like the delay does.
  int lastSpeedUpBps;
  int speedTestedAtMs;

  /// Build 2149 (owner refinement of expansion 2 — the
  /// Karing-style per-DNS rows he asked for after seeing
  /// Karing's list): the last per-server DNS ping THROUGH
  /// this config — server entry (exactly as the generated
  /// config lists it) → latency ms; -1 = asked, no answer;
  /// -2 = not probed (fakedns / localhost / an unsupported
  /// scheme). Empty = never run. [dnsPingAtMs] is when the
  /// run happened (epoch ms, 0 = never). Persists with the
  /// profile (store + stats sidecar) like the speed trio.
  Map<String, int> dnsPingMs;
  int dnsPingAtMs;

  /// True when the last TCP probe ran and the endpoint did
  /// not answer (tcpPingMs stayed -1).
  bool tcpPingFailed;

  /// Anti-filter shaping (build 2026, Stage A of the MLM port):
  /// per-profile options that reshape this profile's TLS
  /// ClientHello in the generated config (see anti_filter.dart).
  /// All default off/absent, so a profile stored by an older
  /// build upgrades unchanged. Only meaningful with TLS security;
  /// [afTcpNoise] rides the freedom chain and applies to any
  /// transport.
  bool afUnfilter;
  bool afEch;
  String afFragment;
  bool afMixedSni;
  bool afTcpNoise;

  /// True when any anti-filter option is set: the shaped config
  /// is then validated by the core before it may be saved/applied.
  bool get hasShaping =>
      afUnfilter || afEch || afFragment.isNotEmpty || afMixedSni || afTcpNoise;

  String subscriptionId;

  /// The last real delay test result (milliseconds), -1 unknown.
  int delayMs;

  /// True when the last delay test ran and failed (delayMs stayed
  /// -1): the row then shows "Failed" instead of a blank ping slot.
  /// False when never tested or when the last test succeeded.
  bool delayFailed;

  /// Which stage produced the current delay result (build 2101,
  /// settings-dns-2099-diagnosis.md D4): '' = no result / cleared
  /// to pending, 'core' = the real throwaway-core test ran (its
  /// success or failure is in [delayMs]/[delayFailed]),
  /// 'sidecar-busy' = the test could not run because a live
  /// session owns the sidecar slot — a distinct outcome, NOT a
  /// failure (delayFailed stays false). Before 2101 every stage's
  /// failure collapsed into the same bare -1 and the funnel's
  /// cheap stages could kill a profile without recording where.
  String delayStage;

  /// Cumulative traffic this profile has carried, counted from the
  /// Xray core's own statistics (the "proxy" outbound counters, read
  /// through the core's local stats API and reset on each read) and
  /// attributed to the profile while it was the connected one.
  int totalDownBytes;
  int totalUpBytes;

  /// When the totals above last grew (epoch ms), 0 = never.
  int statsUpdatedMs;

  /// The exit identity the last delay test observed through
  /// this profile (build 2032, the v2go fold-in): the delay
  /// test's throwaway core also asks Cloudflare's trace where
  /// it exits, so the list can show the exit without a full
  /// connect. '' = never observed.
  String exitIp;
  String exitCountryCode;

  /// Starred by the user (build 2044): a favorite config, shown
  /// in the Favorites section at the top of the server list.
  /// Pure display state — it never reaches the core config, a
  /// share link or a delay test. Survives subscription refresh
  /// (carried in updateSubscription); a duplicate is born
  /// unstarred.
  bool starred;

  /// The user's own label for this profile (build 2045): a rename
  /// the editor stores apart from the provider's name, so a
  /// subscription refresh — which recreates the profile from the
  /// link — cannot wipe it. '' = no label, the server name shows.
  /// Pure display state — it never reaches the core config, a
  /// share link or a delay test. Survives subscription refresh
  /// (carried in updateSubscription next to the star); a
  /// duplicate is born with its own name and no label.
  String localName;

  /// The name the user sees: their own label when one is set,
  /// otherwise the server's name. The server name ([name]) stays
  /// the name the share link, the country grouping and the
  /// diagnostics use.
  /// Build 2103 (diagnosis N2): a genuinely nameless profile
  /// (name never arrived and none was assigned) falls back
  /// to its address HERE, at render time only — the stored
  /// [name] is never the address again (the pre-2103 import
  /// fallback stored it, which poisoned share links and
  /// dedupe; see healAddressDerivedNames).
  String get displayName => localName.isNotEmpty
      ? localName
      : (name.isNotEmpty ? name : address);

  Profile({
    required this.id,
    this.name = '',
    required this.protocol,
    this.address = '',
    this.port = 443,
    this.uuidOrPassword = '',
    this.method = '',
    this.username = '',
    this.network = 'tcp',
    this.headerType = '',
    this.host = '',
    this.path = '',
    this.serviceName = '',
    this.mode = '',
    this.xhttpExtra = '',
    this.wsEarlyData = 0,
    this.transportHeaders = '',
    this.security = '',
    this.sni = '',
    this.alpn = '',
    this.fingerprint = '',
    this.cipherSuites = '',
    this.dialMode = '',
    this.finalMask = '',
    this.publicKey = '',
    this.shortId = '',
    this.spiderX = '',
    this.flow = '',
    this.pqv = '',
    this.aid = 0,
    this.scy = '',
    this.grpcAuthority = '',
    this.vlessEncryption = '',
    this.tlsCertPin = '',
    this.sshUser = '',
    this.sshPassword = '',
    this.sshPrivateKey = '',
    this.sshPrivateKeyPassphrase = '',
    this.sshHostKeyPin = '',
    this.xdnsDomain = '',
    this.xdnsResolver = '',
    this.xicmpEnabled = false,
    this.xicmpDgram = false,
    this.wgFallbackEndpoints = '',
    this.quarantineStrikes = 0,
    this.quarantineNetwork = '',
    this.quarantineReason = '',
    this.quarantined = false,
    this.plugin = '',
    this.secretKey = '',
    this.peerPublicKey = '',
    this.preSharedKey = '',
    this.localAddress = '',
    this.reserved = '',
    this.mtu = 1420,
    this.keepAlive = 0,
    this.wgAllowedIPs = '',
    this.wgDns = '',
    this.wgPreUp = '',
    this.wgPostUp = '',
    this.wgPreDown = '',
    this.wgPostDown = '',
    this.wgExtraKeys = '',
    this.obfs = '',
    this.hyMport = '',
    this.geckoMinPacketSize = 0,
    this.geckoMaxPacketSize = 0,
    this.obfsPassword = '',
    this.upMbps = 0,
    this.downMbps = 0,
    this.hyCongestion = '',
    this.muxOverride = '',
    this.echConfigList = '',
    this.awgJc = '',
    this.awgJmin = '',
    this.awgJmax = '',
    this.awgS1 = '',
    this.awgS2 = '',
    this.awgS3 = '',
    this.awgS4 = '',
    this.awgH1 = '',
    this.awgH2 = '',
    this.awgH3 = '',
    this.awgH4 = '',
    this.awgI1 = '',
    this.awgI2 = '',
    this.awgI3 = '',
    this.awgI4 = '',
    this.awgI5 = '',
    this.awgJ1 = '',
    this.awgJ2 = '',
    this.awgJ3 = '',
    this.congestionControl = '',
    this.udpRelayMode = '',
    this.zeroRttHandshake = false,
    this.tuicHeartbeat = '',
    this.udpOverStream = false,
    this.disableSni = false,
    this.tuicAllowInsecure = false,
    this.allowInsecure = false,
    this.naiveExtraParams = '',
    this.sudokuOptions = '',
    this.zapretStrategy = '',
    this.snellVersion = 4,
    this.tailscaleAuthKey = '',
    this.tcpPingMs = -1,
    this.lastSpeedBps = -1,
    this.lastSpeedUpBps = -1,
    this.speedTestedAtMs = 0,
    this.dnsPingMs = const {},
    this.dnsPingAtMs = 0,
    this.tcpPingFailed = false,
    this.afUnfilter = false,
    this.afEch = false,
    this.afFragment = '',
    this.afMixedSni = false,
    this.afTcpNoise = false,
    this.subscriptionId = '',
    this.delayMs = -1,
    this.delayFailed = false,
    this.delayStage = '',
    this.totalDownBytes = 0,
    this.totalUpBytes = 0,
    this.statsUpdatedMs = 0,
    this.exitIp = '',
    this.exitCountryCode = '',
    this.starred = false,
    this.localName = '',
  });

  Profile copy() => Profile.fromJson(toJson());

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'protocol': protocol.name,
    'address': address,
    'port': port,
    'uuidOrPassword': uuidOrPassword,
    'method': method,
    'username': username,
    'network': network,
    'headerType': headerType,
    'host': host,
    'path': path,
    'serviceName': serviceName,
    'mode': mode,
    'xhttpExtra': xhttpExtra,
    'wsEarlyData': wsEarlyData,
    'transportHeaders': transportHeaders,
    'security': security,
    'sni': sni,
    'alpn': alpn,
    'fingerprint': fingerprint,
    'cipherSuites': cipherSuites,
    'dialMode': dialMode,
    'finalMask': finalMask,
    'publicKey': publicKey,
    'shortId': shortId,
    'spiderX': spiderX,
    'flow': flow,
    'pqv': pqv,
    'aid': aid,
    'scy': scy,
    'grpcAuthority': grpcAuthority,
    'vlessEncryption': vlessEncryption,
    'tlsCertPin': tlsCertPin,
    'sshUser': sshUser,
    'sshPassword': sshPassword,
    'sshPrivateKey': sshPrivateKey,
    'sshPrivateKeyPassphrase': sshPrivateKeyPassphrase,
    'sshHostKeyPin': sshHostKeyPin,
    'xdnsDomain': xdnsDomain,
    'xdnsResolver': xdnsResolver,
    'xicmpEnabled': xicmpEnabled,
    'xicmpDgram': xicmpDgram,
    'wgFallbackEndpoints': wgFallbackEndpoints,
    'quarantineStrikes': quarantineStrikes,
    'quarantineNetwork': quarantineNetwork,
    'quarantineReason': quarantineReason,
    'quarantined': quarantined,
    'plugin': plugin,
    'secretKey': secretKey,
    'peerPublicKey': peerPublicKey,
    'preSharedKey': preSharedKey,
    'localAddress': localAddress,
    'reserved': reserved,
    'mtu': mtu,
    'keepAlive': keepAlive,
    'wgAllowedIPs': wgAllowedIPs,
    'wgDns': wgDns,
    'wgPreUp': wgPreUp,
    'wgPostUp': wgPostUp,
    'wgPreDown': wgPreDown,
    'wgPostDown': wgPostDown,
    'wgExtraKeys': wgExtraKeys,
    'obfs': obfs,
    'hyMport': hyMport,
    'geckoMinPacketSize': geckoMinPacketSize,
    'geckoMaxPacketSize': geckoMaxPacketSize,
    'obfsPassword': obfsPassword,
    'upMbps': upMbps,
    'downMbps': downMbps,
    'hyCongestion': hyCongestion,
    'muxOverride': muxOverride,
    'echConfigList': echConfigList,
    'awgJc': awgJc,
    'awgJmin': awgJmin,
    'awgJmax': awgJmax,
    'awgS1': awgS1,
    'awgS2': awgS2,
    'awgS3': awgS3,
    'awgS4': awgS4,
    'awgH1': awgH1,
    'awgH2': awgH2,
    'awgH3': awgH3,
    'awgH4': awgH4,
    'awgI1': awgI1,
    'awgI2': awgI2,
    'awgI3': awgI3,
    'awgI4': awgI4,
    'awgI5': awgI5,
    'awgJ1': awgJ1,
    'awgJ2': awgJ2,
    'awgJ3': awgJ3,
    'congestionControl': congestionControl,
    'udpRelayMode': udpRelayMode,
    'zeroRttHandshake': zeroRttHandshake,
    'tuicHeartbeat': tuicHeartbeat,
    'udpOverStream': udpOverStream,
    'disableSni': disableSni,
    'tuicAllowInsecure': tuicAllowInsecure,
    'allowInsecure': allowInsecure,
    'naiveExtraParams': naiveExtraParams,
    'sudokuOptions': sudokuOptions,
    'snellVersion': snellVersion,
    'tailscaleAuthKey': tailscaleAuthKey,
    'tcpPingMs': tcpPingMs,
    'lastSpeedBps': lastSpeedBps,
    'lastSpeedUpBps': lastSpeedUpBps,
    'speedTestedAtMs': speedTestedAtMs,
    'dnsPingMs': dnsPingMs,
    'dnsPingAtMs': dnsPingAtMs,
    'tcpPingFailed': tcpPingFailed,
    'afUnfilter': afUnfilter,
    'afEch': afEch,
    'afFragment': afFragment,
    'afMixedSni': afMixedSni,
    'afTcpNoise': afTcpNoise,
    'subscriptionId': subscriptionId,
    'delayMs': delayMs,
    'delayFailed': delayFailed,
    'delayStage': delayStage,
    'totalDown': totalDownBytes,
    'totalUp': totalUpBytes,
    'statsUpdatedMs': statsUpdatedMs,
    'exitIp': exitIp,
    'exitCountryCode': exitCountryCode,
    'starred': starred,
    'localName': localName,
  };

  factory Profile.fromJson(Map<String, dynamic> j) =>
      sanitizeImportedProfile(Profile(
    id: j['id'] as String,
    name: _storedStr(j, 'name', ''),
    protocol: Protocol.values.firstWhere(
      (p) => p.name == _storedStr(j, 'protocol', 'vless'),
      orElse: () => Protocol.vless,
    ),
    address: _storedStr(j, 'address', ''),
    port: _storedInt(j, 'port', 443),
    uuidOrPassword: _storedStr(j, 'uuidOrPassword', ''),
    method: _storedStr(j, 'method', ''),
    username: _storedStr(j, 'username', ''),
    network: _storedStr(j, 'network', 'tcp'),
    headerType: _storedStr(j, 'headerType', ''),
    host: _storedStr(j, 'host', ''),
    path: _storedStr(j, 'path', ''),
    serviceName: _storedStr(j, 'serviceName', ''),
    mode: _storedStr(j, 'mode', ''),
    // Build 2116 (audit G-02/G-03/G-17): tolerant reads —
    // a profile stored by an older build has none of these.
    xhttpExtra: _storedStr(j, 'xhttpExtra', ''),
    wsEarlyData: _storedInt(j, 'wsEarlyData', 0),
    transportHeaders: _storedStr(j, 'transportHeaders', ''),
    security: _storedStr(j, 'security', ''),
    sni: _storedStr(j, 'sni', ''),
    alpn: _storedStr(j, 'alpn', ''),
    fingerprint: _storedStr(j, 'fingerprint', ''),
    cipherSuites: _storedStr(j, 'cipherSuites', ''),
    dialMode: _storedStr(j, 'dialMode', ''),
    finalMask: _storedStr(j, 'finalMask', ''),
    publicKey: _storedStr(j, 'publicKey', ''),
    shortId: _storedStr(j, 'shortId', ''),
    spiderX: _storedStr(j, 'spiderX', ''),
    flow: _storedStr(j, 'flow', ''),
    // Build 2057: the `is`-check read for the new fields — a
    // wrong-typed stored value reads as the default, never throws.
    pqv: _storedStr(j, 'pqv', ''),
    aid: _storedInt(j, 'aid', 0),
    scy: _storedStr(j, 'scy', ''),
    grpcAuthority: _storedStr(j, 'grpcAuthority', ''),
    // Build 2046: the `is`-check read (the 2043 lesson) — a
    // non-string stored value reads as no encryption, never throws.
    vlessEncryption: _storedStr(j, 'vlessEncryption', ''),
    // Build 2047: same `is`-check read for the certificate pin.
    tlsCertPin: _storedStr(j, 'tlsCertPin', ''),
    sshUser: _storedStr(j, 'sshUser', ''),
    sshPassword: _storedStr(j, 'sshPassword', ''),
    sshPrivateKey: _storedStr(j, 'sshPrivateKey', ''),
    sshPrivateKeyPassphrase: _storedStr(j, 'sshPrivateKeyPassphrase', ''),
    sshHostKeyPin: _storedStr(j, 'sshHostKeyPin', ''),
    xdnsDomain: _storedStr(j, 'xdnsDomain', ''),
    xdnsResolver: _storedStr(j, 'xdnsResolver', ''),
    xicmpEnabled: _storedBool(j, 'xicmpEnabled', false),
    xicmpDgram: _storedBool(j, 'xicmpDgram', false),
    wgFallbackEndpoints: _storedStr(j, 'wgFallbackEndpoints', ''),
    quarantineStrikes: _storedInt(j, 'quarantineStrikes', 0),
    quarantineNetwork: _storedStr(j, 'quarantineNetwork', ''),
    quarantineReason: _storedStr(j, 'quarantineReason', ''),
    quarantined: _storedBool(j, 'quarantined', false),
    plugin: _storedStr(j, 'plugin', ''),
    secretKey: _storedStr(j, 'secretKey', ''),
    peerPublicKey: _storedStr(j, 'peerPublicKey', ''),
    preSharedKey: _storedStr(j, 'preSharedKey', ''),
    localAddress: _storedStr(j, 'localAddress', ''),
    reserved: _storedStr(j, 'reserved', ''),
    mtu: _storedInt(j, 'mtu', 1420),
    keepAlive: _storedInt(j, 'keepAlive', 0),
    wgAllowedIPs: _storedStr(j, 'wgAllowedIPs', ''),
    wgDns: _storedStr(j, 'wgDns', ''),
    wgPreUp: _storedStr(j, 'wgPreUp', ''),
    wgPostUp: _storedStr(j, 'wgPostUp', ''),
    wgPreDown: _storedStr(j, 'wgPreDown', ''),
    wgPostDown: _storedStr(j, 'wgPostDown', ''),
    wgExtraKeys: _storedStr(j, 'wgExtraKeys', ''),
    obfs: _storedStr(j, 'obfs', ''),
        hyMport: _storedStr(j, 'hyMport', ''),
        geckoMinPacketSize: _storedInt(j, 'geckoMinPacketSize', 0),
        geckoMaxPacketSize: _storedInt(j, 'geckoMaxPacketSize', 0),
    obfsPassword: _storedStr(j, 'obfsPassword', ''),
    upMbps: _storedInt(j, 'upMbps', 0),
    downMbps: _storedInt(j, 'downMbps', 0),
    hyCongestion: _storedStr(j, 'hyCongestion', ''),
    muxOverride: _storedStr(j, 'muxOverride', ''),
    echConfigList: _storedStr(j, 'echConfigList', ''),
    awgJc: _storedStr(j, 'awgJc', ''),
    awgJmin: _storedStr(j, 'awgJmin', ''),
    awgJmax: _storedStr(j, 'awgJmax', ''),
    awgS1: _storedStr(j, 'awgS1', ''),
    awgS2: _storedStr(j, 'awgS2', ''),
    awgS3: _storedStr(j, 'awgS3', ''),
    awgS4: _storedStr(j, 'awgS4', ''),
    awgH1: _storedStr(j, 'awgH1', ''),
    awgH2: _storedStr(j, 'awgH2', ''),
    awgH3: _storedStr(j, 'awgH3', ''),
    awgH4: _storedStr(j, 'awgH4', ''),
    awgI1: _storedStr(j, 'awgI1', ''),
    awgI2: _storedStr(j, 'awgI2', ''),
    awgI3: _storedStr(j, 'awgI3', ''),
    awgI4: _storedStr(j, 'awgI4', ''),
    awgI5: _storedStr(j, 'awgI5', ''),
    awgJ1: _storedStr(j, 'awgJ1', ''),
    awgJ2: _storedStr(j, 'awgJ2', ''),
    awgJ3: _storedStr(j, 'awgJ3', ''),
    congestionControl: _storedStr(j, 'congestionControl', ''),
    zeroRttHandshake: _storedBool(j, 'zeroRttHandshake', false),
    tuicHeartbeat: _storedStr(j, 'tuicHeartbeat', ''),
    udpOverStream: _storedBool(j, 'udpOverStream', false),
    disableSni: _storedBool(j, 'disableSni', false),
    tuicAllowInsecure: _storedBool(j, 'tuicAllowInsecure', false),
    allowInsecure: _storedBool(j, 'allowInsecure', false),
    naiveExtraParams: _storedStr(j, 'naiveExtraParams', ''),
    sudokuOptions: _storedStr(j, 'sudokuOptions', ''),
    udpRelayMode: _storedStr(j, 'udpRelayMode', ''),
    // Build 2075 sidecar fields: `is`-check reads like every
    // field added after 2043 — a wrong-typed stored value
    // reads as the default, never throws.
    snellVersion: _storedInt(j, 'snellVersion', 4),
    tailscaleAuthKey: _storedStr(j, 'tailscaleAuthKey', ''),
    tcpPingMs: _storedInt(j, 'tcpPingMs', -1),
    lastSpeedBps: _storedInt(j, 'lastSpeedBps', -1),
    lastSpeedUpBps: _storedInt(j, 'lastSpeedUpBps', -1),
    speedTestedAtMs: _storedInt(j, 'speedTestedAtMs', 0),
    dnsPingMs: _storedIntMap(j, 'dnsPingMs'),
    dnsPingAtMs: _storedInt(j, 'dnsPingAtMs', 0),
    tcpPingFailed: _storedBool(j, 'tcpPingFailed', false),
    afUnfilter: _storedBool(j, 'afUnfilter', false),
    afEch: _storedBool(j, 'afEch', false),
    afFragment: _storedStr(j, 'afFragment', ''),
    afMixedSni: _storedBool(j, 'afMixedSni', false),
    afTcpNoise: _storedBool(j, 'afTcpNoise', false),
    subscriptionId: _storedStr(j, 'subscriptionId', ''),
    delayMs: _storedInt(j, 'delayMs', -1),
    delayFailed: _storedBool(j, 'delayFailed', false),
    delayStage: _storedStr(j, 'delayStage', ''),
    totalDownBytes: _storedInt(j, 'totalDown', 0),
    totalUpBytes: _storedInt(j, 'totalUp', 0),
    statsUpdatedMs: _storedInt(j, 'statsUpdatedMs', 0),
    exitIp: _storedStr(j, 'exitIp', ''),
    exitCountryCode: _storedStr(j, 'exitCountryCode', ''),
    // Build 2043's lesson: a bare `as bool?` throws on a
    // non-bool stored value, so a corrupt store must read
    // as unstarred instead of crashing the load. The same
    // `is`-check read guards the label (build 2045).
    starred: _storedBool(j, 'starred', false),
    // Build 2096 (post-2095 audit M5): localName is the
    // name actually displayed, and it bypassed the name
    // sanitizer entirely (raw read here, raw writes in
    // rename/editor) — a restored or renamed profile
    // could carry control/bidi characters into every
    // list. Sanitize at this read choke point; the write
    // paths sanitize too.
    localName: sanitizeProfileName(_storedStr(j, 'localName', '')),
  ));
}

class Subscription {
  String id;
  String name;
  String url;
  int uploadBytes;
  int downloadBytes;
  int totalBytes;
  int expireEpochSec;
  int lastUpdatedMs;
  int profileCount;
  bool autoUpdate;

  /// The SHA-256 (lowercase hex) of the one server certificate
  /// this subscription's fetch may trust even when the system
  /// chain rejects it — a self-signed panel certificate, pinned
  /// per-subscription after the user's explicit confirmation
  /// (build 2050, audit C-3). '' = ordinary chain verification.
  /// Scoped to this subscription's host only; nothing global
  /// ever trusts it.
  String certPin;

  /// A device id some panels require as the `x-hwid` request
  /// header (build 2050, audit F-H13). '' = header not sent.
  String hwid;

  /// A second URL tried once when the primary fails with a
  /// network error, a timeout, or a 5xx (build 2050, F-H13).
  String fallbackUrl;

  /// The provider's own DNS resolver for this subscription's
  /// server hostnames (build 2105, provider DNS): a DoH URL
  /// (https://…) or a plain resolver address (an IP, or a host
  /// the system resolver can find). '' = none. Only used when
  /// XraySettings.providerDnsEnabled is on: at connect, the
  /// selected profile's server hostname is resolved through
  /// this resolver and the answer is pinned into the config's
  /// hosts map (see provider_dns.dart). Set by the user in the
  /// subscription editor — providers do not publish a DNS in
  /// any format this build parses, so nothing fills it in
  /// automatically.
  String dns;

  /// Arbitrary extra request headers this panel requires,
  /// sent on every fetch and refresh (build 2051, F-H13
  /// remainder — the map 2050 left out: HWID and the
  /// fallback URL shipped then, but a panel asking for any
  /// other header had no field to put it in). {} = none.
  /// `User-Agent` can never appear here: the app fixes its
  /// own UA (see [parseCustomHeaders] in sub_fetcher.dart).
  Map<String, String> customHeaders;

  /// Build 2096 (post-2095 audit L29): identity keys of
  /// profiles the user deleted individually from this
  /// subscription. A refresh filters them out — build
  /// 2095 resurrected a deliberately deleted profile on
  /// every refresh because deletion left no trace the
  /// merge could honour.
  List<String> deletedProfileKeys;

  /// Build 2129 (leg 6 / Xray recycle bin): tombstone keys
  /// the user PERMANENTLY deleted from the recycle bin.
  /// They block refresh resurrection exactly like
  /// [deletedProfileKeys] (the refresh filter reads both)
  /// but no longer appear in the bin — purging is the
  /// point of no return the bin's Restore is not.
  List<String> purgedProfileKeys;

  /// Build 2149 (audit A43-11): the deleted profiles' own
  /// data, by tombstone key — recorded at deletion time
  /// alongside the key. Up to 2148 the tombstone kept
  /// only the identity key, so the bin's Restore could
  /// only un-tombstone and wait for a refresh (a dead
  /// subscription meant the config never came back, and
  /// a hand-deleted loose profile was gone for good).
  /// With the data kept, Restore re-adds the profile
  /// itself, immediately. Keys deleted before this build
  /// have no entry here and keep the legacy behaviour.
  Map<String, Map<String, dynamic>> deletedProfileData;

  /// Build 2116 (AB-12): the last auto-update ATTEMPT,
  /// success or failure (lastUpdatedMs only moves on
  /// success). A failed attempt used to leave no trace, so
  /// the sweep retried every 30-minute tick forever and
  /// said nothing.
  int lastAttemptMs;

  /// Build 2116 (AB-12): consecutive failed auto-update
  /// attempts — drives the retry backoff
  /// ([subAutoUpdateBackoffMs]) and the V2Ray page's
  /// could-not-refresh notice. A success resets it.
  int failedAttempts;

  /// Build 2133 (V2Ray full tab): the last completed
  /// per-subscription ping on the V2Ray tab — when it ran
  /// (epoch ms, 0 = never), the fastest profile it found
  /// ('' = none answered) and its delay (-1 = none). The
  /// collapsed subscription card renders its "Best:" /
  /// "Last ping:" summary from these; they are written
  /// only by a completed (not cancelled) scoped ping.
  int lastPingMs;
  String bestPingName;
  int bestPingMs;

  Subscription({
    required this.id,
    this.name = '',
    this.url = '',
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    this.totalBytes = 0,
    this.expireEpochSec = 0,
    this.lastUpdatedMs = 0,
    this.lastAttemptMs = 0,
    this.failedAttempts = 0,
    this.lastPingMs = 0,
    this.bestPingName = '',
    this.bestPingMs = -1,
    this.profileCount = 0,
    this.autoUpdate = true,
    this.certPin = '',
    this.hwid = '',
    this.fallbackUrl = '',
    this.dns = '',
    this.customHeaders = const {},
    this.deletedProfileKeys = const [],
    this.purgedProfileKeys = const [],
    this.deletedProfileData = const {},
  });

  int get usedBytes => uploadBytes + downloadBytes;

  int get remainingBytes => totalBytes > 0 ? totalBytes - usedBytes : -1;

  double get usedFraction =>
      totalBytes > 0 ? (usedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  int get remainingDays {
    if (expireEpochSec <= 0) return -1;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final d = (expireEpochSec - now) / 86400;
    // Build 2096 (post-2095 audit L4): floor, not ceil —
    // ceil reported 4 days for 3.2 remaining, so the
    // <=3-day low warning (quotaLow) fired a day late.
    return d < 0 ? 0 : d.floor();
  }

  /// Build 2095 (feature 10 — subscription health): alive /
  /// tested / dead from the latest delay data of [profiles]
  /// (this subscription's configs). Dead means: at least one
  /// config was tested and every tested one failed.
  ({int alive, int tested, bool dead}) healthOf(List<Profile> profiles) {
    final alive = profiles.where((p) => p.delayMs >= 0).length;
    final tested =
        profiles.where((p) => p.delayMs >= 0 || p.delayFailed).length;
    return (alive: alive, tested: tested, dead: tested > 0 && alive == 0);
  }

  /// Build 2095 (feature 3 — subscription quota bar): the
  /// low-quota warning state. True when the panel reports a
  /// total and at most a tenth of it remains, or the expiry
  /// is within three days.
  bool get quotaLow {
    if (totalBytes > 0 && remainingBytes >= 0) {
      if (remainingBytes / totalBytes <= 0.10) return true;
    }
    final days = remainingDays;
    return days >= 0 && days <= 3;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'uploadBytes': uploadBytes,
    'downloadBytes': downloadBytes,
    'totalBytes': totalBytes,
    'expireEpochSec': expireEpochSec,
    'lastUpdatedMs': lastUpdatedMs,
    'lastAttemptMs': lastAttemptMs,
    'failedAttempts': failedAttempts,
    'lastPingMs': lastPingMs,
    'bestPingName': bestPingName,
    'bestPingMs': bestPingMs,
    'profileCount': profileCount,
    'autoUpdate': autoUpdate,
    'certPin': certPin,
    'hwid': hwid,
    'fallbackUrl': fallbackUrl,
    'dns': dns,
    'customHeaders': customHeaders,
    'deletedProfileKeys': deletedProfileKeys,
    'purgedProfileKeys': purgedProfileKeys,
    'deletedProfileData': deletedProfileData,
  };

  factory Subscription.fromJson(Map<String, dynamic> j) => Subscription(
    id: j['id'] as String,
    name: _storedStr(j, 'name', ''),
    url: _storedStr(j, 'url', ''),
    uploadBytes: _storedInt(j, 'uploadBytes', 0),
    downloadBytes: _storedInt(j, 'downloadBytes', 0),
    totalBytes: _storedInt(j, 'totalBytes', 0),
    expireEpochSec: _storedInt(j, 'expireEpochSec', 0),
    lastUpdatedMs: _storedInt(j, 'lastUpdatedMs', 0),
    lastAttemptMs: _storedInt(j, 'lastAttemptMs', 0),
    failedAttempts: _storedInt(j, 'failedAttempts', 0),
    // Build 2133: the per-subscription ping summary; a
    // pre-2133 record has no key and loads as never pinged.
    lastPingMs: _storedInt(j, 'lastPingMs', 0),
    bestPingName: _storedStr(j, 'bestPingName', ''),
    bestPingMs: _storedInt(j, 'bestPingMs', -1),
    profileCount: _storedInt(j, 'profileCount', 0),
    autoUpdate: _storedBool(j, 'autoUpdate', true),
    // Build 2050: `is`-check reads, like the rest of the store —
    // a wrong-typed legacy value yields '', never a throw.
    certPin: _storedStr(j, 'certPin', ''),
    hwid: _storedStr(j, 'hwid', ''),
    fallbackUrl: _storedStr(j, 'fallbackUrl', ''),
    dns: _storedStr(j, 'dns', ''),
    // Build 2051: the same tolerance for the headers map — a
    // wrong-typed or partly-bad stored value yields the good
    // string entries only, never a throw; a 2050-era record
    // (no key) loads with no headers.
    customHeaders: _stringMap(j['customHeaders']),
    // Build 2096 (audit L29): the deletion tombstones,
    // read with the same tolerance as the rest of the
    // store.
    deletedProfileKeys: j['deletedProfileKeys'] is List
        ? (j['deletedProfileKeys'] as List)
              .whereType<String>()
              .toList()
        : const [],
    // Build 2129: the purged set, read with the same
    // tolerance; a pre-2129 record has no key and loads
    // with none purged.
    purgedProfileKeys: j['purgedProfileKeys'] is List
        ? (j['purgedProfileKeys'] as List)
              .whereType<String>()
              .toList()
        : const [],
    // Build 2149 (audit A43-11): the tombstones' retained
    // profile data, read with the same tolerance — only
    // map-shaped entries survive; a pre-2149 record has
    // no key and loads with none.
    deletedProfileData: j['deletedProfileData'] is Map
        ? {
            for (final e in (j['deletedProfileData'] as Map).entries)
              if (e.value is Map)
                e.key.toString(): (e.value as Map)
                    .cast<String, dynamic>(),
          }
        : const {},
  );
}

/// Reads a stored string map tolerantly (build 2051): only
/// String→String entries survive; anything else yields {}.
/// Tolerant Map<String, int> reader (build 2147, the
/// _stringMap shape): a wrong-typed value reads as empty.
Map<String, int> _intMap(Object? v) {
  if (v is! Map) return {};
  return {
    for (final e in v.entries)
      if (e.value is num) e.key.toString(): (e.value as num).toInt(),
  };
}

Map<String, String> _stringMap(Object? v) {
  if (v is! Map) return {};
  final out = <String, String>{};
  for (final e in v.entries) {
    if (e.key is String && e.value is String)
      out[e.key as String] = e.value as String;
  }
  return out;
}

/// Build 2116 (AB-12): how long a subscription's automatic
/// refresh waits after [failedAttempts] consecutive
/// failures — 30 minutes doubling per failure, capped at
/// 24 hours. Manual refresh is never gated by this.
int subAutoUpdateBackoffMs(int failedAttempts) {
  if (failedAttempts <= 0) return 0;
  var ms = 30 * 60 * 1000;
  const cap = 24 * 3600 * 1000;
  for (var i = 1; i < failedAttempts && ms < cap; i++) {
    ms *= 2;
  }
  return ms > cap ? cap : ms;
}

/// The user's routing preset for the Xray tunnel.
enum RoutingPreset { global, bypassLan, bypassIran, bypassChina, directAll }

extension RoutingPresetLabel on RoutingPreset {
  String get name => switch (this) {
    RoutingPreset.global => 'global',
    RoutingPreset.bypassLan => 'bypass-lan',
    RoutingPreset.bypassIran => 'bypass-iran',
    RoutingPreset.bypassChina => 'bypass-china',
    RoutingPreset.directAll => 'direct-all',
  };
}

/// The loopback ports other Ember engines already own (build
/// 2057, audit F-M2): a user-editable Xray port must never land
/// on one of these, or the core refuses the config at connect
/// and the failure surfaces only as a generic start failure.
/// Psiphon 11808/11809, the delay-test range 11080–11260, the
/// Lantern/Aether/Warp ports 20810, 20840/41, 20850–20854, 20870.
/// Build 2149 (audit A43-16): the helper-listen block joins —
/// dnstt 20860, wstunnel 20861, sing-box 20862, Mieru 20863,
/// Zapret 20864, Sudoku 20865, OLCRTC 20866 — plus the
/// DNSCrypt proxy's 20530; all were assignable to an Xray
/// port before this build and collided the same way.
const _xrayReservedPorts = <int>{
  11808,
  11809,
  20530,
  20810,
  20840,
  20841,
  20850,
  20851,
  20852,
  20853,
  20854,
  20860,
  20861,
  20862,
  20863,
  20864,
  20865,
  20866,
  20870,
};

bool _isReservedXrayPort(int port) =>
    _xrayReservedPorts.contains(port) || (port >= 11080 && port <= 11260);

/// The user-facing validation for the two editable Xray ports
/// (build 2057, audit F-M2): range, distinctness, the reserved
/// set above, and the stats-API overflow — the stats port is
/// `socksPort + 5000`, so a SOCKS port above 60535 would push
/// it past 65535. Returns the named problem, or null when the
/// pair is usable. Used by the Settings input (which refuses
/// the save with this message), by [XraySettings.fromJson]
/// (which sanitises a stored pair to the defaults instead), and
/// by the connect path's defence-in-depth check.
String? validateXrayPorts({required int socksPort, required int httpPort}) {
  if (socksPort < 1 || socksPort > 65535) {
    return 'SOCKS port must be between 1 and 65535.';
  }
  if (httpPort < 1 || httpPort > 65535) {
    return 'HTTP port must be between 1 and 65535.';
  }
  if (socksPort == httpPort) {
    return 'SOCKS and HTTP ports must be different.';
  }
  if (socksPort > 60535) {
    return 'SOCKS port must be 60535 or below — the stats port '
        'is SOCKS + 5000 and must stay below 65536.';
  }
  if (_isReservedXrayPort(socksPort)) {
    return 'SOCKS port $socksPort is already used by another '
        'engine — pick a different one.';
  }
  if (_isReservedXrayPort(httpPort)) {
    return 'HTTP port $httpPort is already used by another '
        'engine — pick a different one.';
  }
  if (httpPort == socksPort + 5000) {
    return 'HTTP port must not be the stats port '
        '(SOCKS + 5000 = ${socksPort + 5000}).';
  }
  return null;
}

/// The uTLS fingerprints the rotation (build 2065, item 13)
/// cycles through — the values the bundled core's uTLS accepts
/// for a TLS outbound. 'random' is deliberately not in the set:
/// the core's randomized fingerprint needs a seed profile name
/// and repeats badly; four real browser fingerprints rotate
/// better.
const tlsFingerprintRotationSet = <String>[
  'chrome',
  'firefox',
  'safari',
  'ios',
];

/// The fingerprint a connect should use for [profile] under the
/// rotation setting: the profile's own explicit value always
/// wins; rotation only fills an empty one, and only when on.
String effectiveFingerprint(
  Profile profile,
  XraySettings settings, {
  required int rotationIndex,
}) {
  if (profile.fingerprint.isNotEmpty) return profile.fingerprint;
  if (!settings.rotateTlsFingerprint) return '';
  return tlsFingerprintRotationSet[
      rotationIndex % tlsFingerprintRotationSet.length];
}

/// The one-time fingerprint migration (build 2070, review §4
/// row 7): clears the 'chrome' the VLESS link parser used to
/// manufacture (builds ≤2069) for tls/reality profiles whose
/// link carried no fp parameter. The fill made imported
/// profiles indistinguishable from user-pinned ones, so the
/// rotation above could never apply to them.
///
/// The scope is exactly the population the parser could have
/// filled — VLESS profiles with tls or reality security whose
/// fingerprint is 'chrome'; every other profile is untouched.
/// The honest edge, stated plainly: a 'chrome' that arrived via
/// an explicit fp=chrome link parameter, or that the owner
/// typed into the editor on such a profile, is indistinguishable
/// from the fill and is cleared too. The consequence is bounded
/// — with rotation off, empty means core-default to the builder
/// (the shape hand-created profiles always had), and because
/// the migration runs once (XraySettings
/// .fingerprintDefaultMigrated), a 'chrome' set afterwards is
/// kept forever. Returns how many profiles were cleared.
///
/// Build 2149 (diagnosis D4) — THE CLEARING IS RETIRED. The
/// honest edge above turned out to be the population that
/// matters: VLESS tls/reality profiles whose links carried
/// an EXPLICIT fp=chrome lost it to this migration, and on
/// stricter networks the resulting core-default ClientHello
/// is DPI-killed where Chrome uTLS passed. Stored data can
/// no longer distinguish an explicit 'chrome' from the old
/// parser fill — there is no marker, and there never was —
/// so from 2149 the migration clears NOTHING: every stored
/// fingerprint is left exactly as-is. The function and its
/// one-time flag stay (the call sites and the flag's
/// lifecycle are unchanged; the flag still flips once, so
/// the migration era is closed), and the return is always
/// 0. A profile whose owner wants rotation instead of a
/// stored 'chrome' clears the field in the editor — a
/// human decision, not a migration's guess.
int clearParserDefaultFingerprints(List<Profile> profiles) {
  return 0;
}

/// Build 2103 (diagnosis N2): the one-time heal for names
/// the pre-2103 import fallback manufactured. Until 2102,
/// a remark-less import stored the server ADDRESS as the
/// profile's name (_fallbackName's address branch, the
/// Clash route's substitution, the editor's empty-name
/// save) — a stored value that then poisoned share links,
/// dedupe reports and renames, and that no refresh could
/// heal for a profile whose provider still serves no
/// remark. The scope is exactly the population those
/// writers could have produced: a stored name EXACTLY
/// equal to the profile's own address, with no user label
/// ([Profile.localName] empty — since build 2045 a user's
/// rename lives there, never in [Profile.name], so a
/// deliberate rename cannot be in this population). Each
/// healed profile takes the positional form the import
/// routes now assign (protocol label + position), the
/// position being its index in the store list. The honest edge,
/// stated plainly: a provider remark that is itself
/// exactly the bare address is indistinguishable from the
/// manufactured value and is renamed too — the address
/// still shows as the row's subtitle, and the next
/// subscription refresh restores provider remarks
/// verbatim. Returns how many profiles were healed.
int healAddressDerivedNames(List<Profile> profiles) {
  var healed = 0;
  for (var i = 0; i < profiles.length; i++) {
    final p = profiles[i];
    if (p.localName.isEmpty &&
        p.address.isNotEmpty &&
        p.name == p.address) {
      p.name = '${p.protocol.label} ${i + 1}';
      healed++;
    }
  }
  return healed;
}

/// The one-line warning for an Xray-hosted session
/// (V2Ray / standalone WARP) whose TUN does not capture
/// IPv6, or null when it does (build 2123, audit C-01 —
/// the wgUncoveredFamilyNote pattern applied to the main
/// path). With "IPv6 route" off — the owner's ordered
/// v2rayNG default, kept — the TUN carries no IPv6
/// address or route. Build 2151 (TUN/IPv6 audit §1b):
/// the wording is corrected to what Android actually
/// does with that shape — a family the VPN adds nothing
/// of is BLOCKED for the captured apps (the platform
/// contract of VpnService.Builder), it does not leak
/// onto the physical link; the pre-2151 line claimed the
/// opposite ("keeps your current IP address") and
/// steered diagnosis toward a leak that cannot happen.
/// The default does NOT change; what is journaled at
/// every adoption is the fact, stated accurately.
String? ipv6UncoveredSessionNote(XraySettings settings) {
  if (settings.ipv6Route) return null;
  return 'This tunnel carries no IPv6 — the "IPv6 route" '
      'setting is off (the v2rayNG default), so Android '
      'blocks IPv6 for the apps in the tunnel and they '
      'fall back to IPv4 through it. Turn the setting on '
      'to capture IPv6.';
}

class XraySettings {
  XraySettings();

  bool enableUdp = true;
  String localDns = '1.1.1.1';

  /// The resolver proxied traffic uses, reached through the tunnel.
  /// 2005–2100 the default was dns.google's DoH; build 2101 adopted
  /// v2rayNG's value (Cloudflare's DoH) on the owner's order
  /// (2026-11-18). Build 2111 moved the default to Cloudflare's
  /// plain resolver, 1.1.1.1 (the 2110 export had proved the DoH
  /// POST through the tunnel dead on the owner's path). Build
  /// 2113 REVERTS the 2111 move on the owner's order (2026-11-19,
  /// «dns همون باشه» — the DNS is v2rayNG's own): the full-config
  /// diff against upstream v2rayNG @ ef06bac
  /// (v2rayng-config-diff-2112.md) showed the defect was never
  /// the resolver VALUE but the CARRIAGE — Ember hijacked all
  /// app DNS into the core module whose dispatched upstreams die
  /// on his server, while v2rayNG's default shape carries app
  /// DNS as ordinary tunnel traffic and uses this DoH string as
  /// the module's unscoped upstream. The default is v2rayNG's
  /// DNS_PROXY again, and the builder emits the stored list
  /// as-is (no appended fallback). A stored 2111-era default is
  /// migrated once (see [XraySettings.fromJson]).
  String remoteDns = 'https://cloudflare-dns.com/dns-query';

  /// The remote resolver's transport (build 2032): 'doh' (the
  /// [remoteDns] URL as-is) or 'doq' — DNS-over-QUIC to the same
  /// provider (see config_builder's DoQ mapping; the core speaks
  /// ONLY `quic+local` nameservers — build 2053, audit F-H4 —
  /// and `quic+local` is local egress: the query leaves the
  /// device directly, not through the tunnel). 'tcp' (build
  /// 2037, Iran-priority queue 2e) — DNS over TCP to the
  /// provider's pinned IP (see config_builder's TCP mapping;
  /// the core speaks tcp:// nameservers, RFC 7766): it survives
  /// UDP poisoning and needs no hostname or SNI. DoH stays the
  /// default; an unrecognised stored value falls back to DoH in
  /// the builder.
  String remoteDnsProto = 'doh';

  /// The tunnel MTU (build 2038, Iran-priority queue 2f, custom MTU):
  /// the MTU of the Android VPN TUN interface, applied to every
  /// engine's tunnel at connect (V2Ray, WARP, Psiphon, Lantern,
  /// Mozilla) — the interface, the tun2socks bridge and (Mozilla)
  /// the core's stack all use this one value, so they agree. 1500
  /// is the default (unchanged behaviour); 1420 is the
  /// WireGuard-standard value, 1400 a common safe value on filtered
  /// mobile networks, 1280 the IPv6 minimum MTU for paths that
  /// fragment or black-hole full-size tunnel packets. Clamped
  /// 1280..1500 wherever it is read, so a corrupt stored value can
  /// never break a connect. Applies at the next connect; a running
  /// tunnel keeps its start MTU.
  int tunnelMtu = 1500;

  /// Clamps a tunnel MTU to the offered range (see [tunnelMtu]).
  static int clampTunnelMtu(int v) => v < 1280 ? 1280 : (v > 1500 ? 1500 : v);

  /// Test All's real-test parallelism (build 2032, the v2go
  /// fold-in's modest version): how many throwaway cores test at
  /// once in the funnel's real stage. Clamped 1..8 where used.
  /// Build 2101: the default rises 4 → 8 — the stage-3 duration
  /// diagnosis (settings-dns-2099-diagnosis.md, S5) found the
  /// 4-wide stage the dominant cost of a full-list test; the
  /// cores are short-lived, so the wider pool is safe.
  int testAllConcurrency = 8;

  /// The delay-test timeout (build 2109, feature-watch
  /// 2026-11-12, FlClash 0.9.2): the per-request timeout, in
  /// seconds, of the real proxied-request delay test — the
  /// single-profile test, the Test All bulk pass, the DPI Lab
  /// discovery probes and the sandbox config test all wait this
  /// long for one request to answer. Default 8: the fixed 8 s
  /// the request path used in every build ≤2108
  /// (XrayTester.timeRequest's default), so a store that never
  /// set it behaves exactly as before. Choices 3/5/8/10/15/20
  /// in Settings → V2Ray. Clamped 3..20 wherever it is read, so
  /// a corrupt stored value can never break a test. The cheap
  /// funnel pre-checks (3 s TCP/TLS, scan_probes) and the bare
  /// TCP ping (5 s, tcp_ping) are separate measurements with
  /// their own budgets and do NOT follow this setting — see
  /// build2109-progress.md (N1/N3).
  int delayTestTimeoutSec = 8;

  /// Clamps a delay-test timeout to the offered range (see
  /// [delayTestTimeoutSec]).
  static int clampDelayTestTimeoutSec(int v) =>
      v < 3 ? 3 : (v > 20 ? 20 : v);

  /// The clamped timeout in milliseconds — what the delay-test
  /// call sites pass to the native side.
  int get delayTestTimeoutMs =>
      clampDelayTestTimeoutSec(delayTestTimeoutSec) * 1000;

  /// Set once the 2005 remote-DNS default migration has run, so a
  /// user who later re-enters the old value on purpose keeps it.
  bool remoteDnsMigrated = false;

  /// Set once the build-2101 defaults migration has run: a stored
  /// remoteDns still equal to the pre-2101 default (Google DoH)
  /// moves to v2rayNG's Cloudflare DoH, and a stored
  /// testAllConcurrency still equal to the pre-2101 default (4)
  /// moves to 8. Same one-time doctrine as [remoteDnsMigrated] —
  /// a value re-entered on purpose afterwards is kept.
  bool defaultsMigrated2101 = false;

  /// Set once the build-2111 defaults migration has run: a
  /// stored remoteDns still equal to either shipped DoH
  /// default — build 2101's Cloudflare DoH, or the Google-IP
  /// DoH (https://8.8.8.8/dns-query) the owner set by hand
  /// while fighting the dead-DoH defect — moves to the new
  /// plain-IP default (1.1.1.1). Same one-time doctrine as
  /// [defaultsMigrated2101]; any other value is a deliberate
  /// choice and is kept. The in-memory default is TRUE, the
  /// build-2103 doctrine: a fresh install has nothing to
  /// migrate, and [XraySettings.fromJson] reads the stored
  /// value with a FALSE fallback so a pre-2111 store still
  /// migrates exactly once.
  bool defaultsMigrated2111 = true;

  /// Set once the build-2113 defaults migration has run: the
  /// 2111 plain-IP default (1.1.1.1) and the resolver values the
  /// owner cycled through by hand while fighting the dead-DNS
  /// defect on 2026-11-18/19 (the Google and Google-IP DoH URLs
  /// and the AdGuard addresses, all documented in his own
  /// Diagnostics exports of those nights) move back to
  /// v2rayNG's default, Cloudflare's DoH — build 2113 adopts
  /// v2rayNG's generated DNS section verbatim on his order
  /// («dns همون باشه»), and none of those values was ever a
  /// working, deliberate choice. Same one-time doctrine and
  /// in-memory-true / stored-false-fallback shape as
  /// [defaultsMigrated2111]; any other value is kept.
  bool defaultsMigrated2113 = true;

  /// Set once the build-2103 defaults migration has run: a
  /// stored ipv6Route / sniffQuic still true was the shipped
  /// default in every build ≤2102 (both fields are written
  /// on every save, so a stored true cannot be told apart
  /// from a deliberate choice) — both move to the new
  /// v2rayNG-parity defaults (OFF) exactly once. A value the
  /// user sets afterwards is kept, like every migration in
  /// this class.
  ///
  /// The in-memory default is TRUE (build 2103, verification
  /// iteration 1, H1): a settings object that never came
  /// from a stored document — a fresh install — has nothing
  /// to migrate, and starting at false would write false on
  /// the first session's saves, making the store look
  /// pre-2103 and re-firing the migration over a value the
  /// user set in that first session. [XraySettings.fromJson]
  /// reads the stored value with a FALSE fallback, so a
  /// store written before this key existed still migrates
  /// exactly once.
  bool defaultsMigrated2103 = true;

  /// Set once the build-2114 defaults reset has run (owner
  /// order 2026-11-19 — every Ember-added feature defaults
  /// OFF, all defaults = v2rayNG's): adaptiveFailover,
  /// autoReconnect, stallWatchdog and smartDialRacing shipped
  /// default-ON and are written on every save, so a stored
  /// true cannot be told apart from the shipped default —
  /// all four move to OFF exactly once. (remoteDns, the
  /// reset's fifth XraySettings key, already landed in build
  /// 2113 via [defaultsMigrated2113].) Same in-memory-true /
  /// stored-false-fallback doctrine as [defaultsMigrated2103];
  /// a value the user sets afterwards is kept.
  bool defaultsReset2114 = true;

  /// Transient (never serialized): fromJson sets this when
  /// the 2103 migration actually fired during this load, so
  /// XrayController.load persists the migrated store at
  /// once — the same immediate-persist doctrine as the
  /// fingerprint migration (build 2103, verification
  /// iteration 1, H1).
  bool defaultsJustMigrated2103 = false;

  /// Set once the build-2103 address-name heal has run over
  /// the stored profiles (healAddressDerivedNames): profiles
  /// whose stored name is exactly their server address —
  /// the value the pre-2103 import fallback manufactured —
  /// are renamed to the positional form. Runs once, like
  /// [fingerprintDefaultMigrated]; the controller performs
  /// it at store load and persists at once.
  bool addressNameHealed2103 = false;

  /// Set once the 2024 domain-strategy default migration has run
  /// (the old default 'IPIfNonMatch' becomes v2rayNG's 'AsIs'), so
  /// a user who later picks IPIfNonMatch on purpose keeps it.
  bool domainStrategyMigrated = false;

  /// Set once the build-2070 fingerprint migration has run over
  /// the stored profiles (clearParserDefaultFingerprints: the
  /// parser-manufactured 'chrome' on imported VLESS tls/reality
  /// profiles is cleared so uTLS rotation can apply), so a user
  /// who later sets 'chrome' on purpose keeps it. Same one-time
  /// doctrine as the two migrations above; the controller runs
  /// it at store load and persists at once.
  bool fingerprintDefaultMigrated = false;
  int socksPort = 10808;
  int httpPort = 10809;

  /// LAN sharing (build 2062, feature queue #2): when on, the
  /// tunnel's SOCKS + HTTP inbounds listen on 0.0.0.0 instead of
  /// 127.0.0.1, so other devices on the local network can use
  /// the tunnel as a proxy. Default OFF — a stored value is
  /// always respected, and OFF is byte-identical to every
  /// earlier build. Applies at the next connect; a running
  /// tunnel keeps its start listen address.
  bool lanShareEnabled = false;

  /// When on (and [lanShareEnabled]), the shared proxy requires
  /// a username/password ([lanShareUser]/[lanSharePass]) —
  /// SOCKS5 username/password auth and HTTP Basic auth.
  /// Until both are entered, [lanShareAuthReady] is false and
  /// the shared proxy has no login (see the Settings caption).
  bool lanShareAuth = false;
  String lanShareUser = '';
  String lanSharePass = '';

  /// True only when auth is on AND both credentials are
  /// entered — the only state in which the builder emits
  /// password auth. Auth on with empty credentials is noauth,
  /// never a half-configured login.
  bool get lanShareAuthReady =>
      lanShareAuth && lanShareUser.isNotEmpty && lanSharePass.isNotEmpty;
  bool sniffing = true;

  /// Build 2095 (V2Ray journey audit #22): which protocols
  /// the inbound sniffing overrides destinations for. The
  /// builder hardcoded http+tls+quic; each can now be
  /// turned off individually. All default ON, so a default
  /// config is byte-identical to earlier builds.
  /// Build 2103 (diagnosis D3/E3): sniffQuic's default is
  /// now OFF — v2rayNG's template sniffs http+tls only, and
  /// the QUIC override was an Ember extra riding on every
  /// UDP/443 handshake. The toggle stays; the one-time
  /// defaultsMigrated2103 migration below moves a stored
  /// true (indistinguishable from the shipped default) to
  /// OFF once, and a deliberate re-enable is kept.
  bool sniffHttp = true;
  bool sniffTls = true;
  bool sniffQuic = false;

  /// Block QUIC (build 2108, feature-watch 2026-11-18,
  /// DPIMech 0.3.0): when on, the tunnel config's routing
  /// rules send UDP port 443 to the blackhole outbound, so
  /// browsers and YouTube fall back to TCP — on filtered
  /// networks where QUIC is throttled or blocked outright,
  /// the TCP fallback is what carries traffic. The rule is
  /// placed after the DNS-module rule (so the core's own DNS
  /// queries, including DNS-over-QUIC, still reach the proxy)
  /// and before every preset/custom rule (so no preset can
  /// route QUIC around the block). Applies at the next
  /// connect; a running tunnel keeps its start rules. Covers
  /// the V2Ray/Xray engine path ONLY — sidecar-served profiles
  /// included, since their traffic still enters via the Xray
  /// inbounds; Mozilla, WireGuard, WARP, Psiphon, Lantern and
  /// OpenVPN sessions do not go through the Xray routing table.
  /// Default OFF — off, the generated config is byte-identical to 2107's.
  bool blockQuic = false;

  /// ShadowTLS fronting for Shadowsocks (build 2126,
  /// feature pick 3): when on, a Shadowsocks profile whose
  /// stored plugin is `shadow-tls` (see [Profile.shadowTlsPlugin])
  /// is served by the sing-box sidecar instead of the Xray
  /// core, with the front really applied — the sidecar emits
  /// the shadowsocks outbound detoured through a shadowtls
  /// outbound (grammar validated against the vendored
  /// sing-box 1.14.4: `sing-box check` on the emitted shape,
  /// classic and 2022 ciphers). ShadowTLS carries TCP only,
  /// so a fronted session cannot relay UDP — the connect
  /// path journals that. Default OFF — off, every config and
  /// behaviour is byte-identical to 2125's: the profile
  /// stays on the Xray core and its plugin stays unapplied.
  bool shadowTlsFronting = false;

  /// Hysteria2 gecko packet sizes (build 2126, D1): when
  /// on, a gecko-obfs profile's stored packet-size band
  /// ([Profile.geckoMinPacketSize] / [Profile.geckoMaxPacketSize],
  /// from its share link) is emitted into the sing-box
  /// sidecar's obfs block (grammar from sing-box 1.14.4's
  /// Hysteria2ObfsGecko, validated with `sing-box check`).
  /// Default OFF — off, the emitted obfs block is
  /// byte-identical to 2125's (gecko itself already
  /// routes to the sidecar since build 2116; this gates
  /// only the new size fields, so no working gecko
  /// profile changes behaviour).
  bool geckoPacketSizes = false;

  /// Hysteria2 noise decoy (build 2126, D6 — the owner's
  /// pick #13 Hy2 leg): when on, a Hysteria2 profile's
  /// stream gains a finalmask `noise` entry ahead of its
  /// salamander mask — the vendored core emits same-socket
  /// random packets before the first real packet, so a
  /// filter's first read is decoy bytes (grammar from
  /// Xray-core's transport_finalmask.go NoiseMask,
  /// corroborated in the bundled fork's strings).
  /// Default OFF — off, no finalmask entry is added and
  /// the config is byte-identical to 2125's.
  bool hy2NoiseDecoy = false;

  /// Fragment via FinalMask (build 2126, D2): when on,
  /// the global fragment toggle's shaping is emitted as
  /// a finalmask `fragment` entry on the proxy outbound
  /// instead of chaining through the legacy freedom
  /// "frag" outbound (the fork carries the fragment mask
  /// in streamSettings.finalmask.tcp — verified in its
  /// strings and in Xray-core's transport_finalmask.go).
  /// The freedom noises (per-profile TCP noise) still
  /// chain through the frag outbound when a profile asks
  /// for them. Default OFF — off, the fragment chain is
  /// byte-identical to 2125's.
  bool fragmentViaFinalmask = false;

  /// Sidecar TLS fragmentation (build 2126, D8): when
  /// on, the sing-box sidecar's config gains a catch-all
  /// route-options rule with `tls_fragment` — sing-box
  /// 1.14.4's SNI-relative ClientHello fragmentation —
  /// so sidecar-served protocols (TUIC / AnyTLS / Snell /
  /// Naive / diverted Hy2 and ShadowTLS) get ClientHello
  /// shaping on the handshakes the core terminates,
  /// which today receive none (grammar from 1.14.4's
  /// RawRouteOptionsActionOptions, validated with
  /// `sing-box check`). Default OFF — off, the sidecar
  /// config is byte-identical to 2125's.
  bool sidecarTlsFragment = false;

  /// Stop the VPN on device sleep (build 2136, item 1):
  /// when on, a screen-off broadcast reaching the app
  /// process disconnects the active session instead of
  /// holding the tunnel (and its wake paths) through the
  /// night. Default OFF — off, sleep behaviour is
  /// byte-identical to 2135's. Honest limit, stated on the
  /// settings row: the broadcast only reaches a living app
  /// process; a process Android has already reaped holds
  /// no Dart-side session state to stop.
  bool stopVpnOnSleep = false;

  /// Randomized fragment geometry (build 2136, item 8):
  /// when on, the global fragment chain emits its lengths
  /// and delays as ranges centred on the stored fixed
  /// values (the core's Int32Range grammar) instead of the
  /// fixed cuts, so a filter cannot fingerprint one exact
  /// geometry. Default OFF — off, the emitted fragment
  /// block is byte-identical to 2135's.
  bool fragmentRandomGeometry = false;

  /// Auto-fastest fallback group (build 2136, item 14):
  /// when on, a manual connect walks the profile's
  /// fallback group ordered by the best stored delay
  /// result (fastest first) instead of stored order; the
  /// existing proof + failover walk does the rest.
  /// Default OFF — off, group order is byte-identical to
  /// 2135's.
  bool autoFastestGroup = false;

  /// (Build 2136, item 15 — WireGuard peer fallback
  /// addresses — was scoped here and then PARKED with
  /// evidence in build2136-progress.md: the WG walk's
  /// plain leg re-resolves the selected profile by id
  /// from the store, so pinned-address copies are
  /// invisible to it; no field is stored for a feature
  /// that does not exist.)

  /// Per-route SNI spoofing (build 2127, H3): when on,
  /// the sing-box sidecar's route gains one route-options
  /// rule per [sniSpoofRules] entry — a domain (and its
  /// subdomains) whose TLS handshakes are preceded by a
  /// fake ClientHello carrying the rule's decoy SNI
  /// (sing-box 1.14.4's `tls_spoof` route action; the
  /// grammar is the vendored binary's own option struct).
  /// Default OFF — off, or with an empty rule list, the
  /// sidecar config is byte-identical to 2126's.
  bool sniSpoofEnabled = false;

  /// The SNI spoofing rules (build 2127, H3), edited on
  /// the SNI spoofing page; see sni_spoof.dart.
  List<SniSpoofRule> sniSpoofRules = [];

  /// Sudoku engine (build 2127, H2): when on, Sudoku
  /// profiles are served by the Sudoku sidecar (the
  /// Hiddify-fork sing-box binary, libsudokubox.so);
  /// off, a Sudoku profile refuses at connect in plain
  /// words. Default OFF — off, every other profile's
  /// behaviour is byte-identical to 2126's.
  bool sudokuEnabled = false;

  /// Build 2095 (V2Ray journey audit #28): the core log
  /// level the builder writes ('warning' | 'info' |
  /// 'debug'); it hardcoded 'warning', so the logs page
  /// could never show more than warnings.
  String logLevel = 'warning';
  bool fakeDns = false;
  bool muxEnabled = false;
  int muxConcurrency = 8;
  bool fragmentEnabled = false;

  /// Fallback groups (Stage A adaptive failover, build 2026;
  /// group semantics, build 2035, Iran-priority queue item 2a):
  /// while the V2Ray tunnel is up, a health-check loop watches
  /// it; when the tunnel dies — or a manual connect fails — the
  /// engine moves to the next member of the config's fallback
  /// group (its subscription; hand-added configs form one group)
  /// in order, skipping members that failed recently, and says
  /// so. Default ON since build 2035; build 2114 (defaults
  /// reset, owner order 2026-11-19 — every Ember extra defaults
  /// OFF, v2rayNG parity) makes it default OFF, and the
  /// defaultsReset2114 migration below moves a stored true to
  /// OFF once. A value set afterwards is kept.
  bool adaptiveFailover = false;

  /// The chain underlay (build 2029A): 'none', 'psiphon' or
  /// 'warp' (build 2030); 'dnstt' added in build 2072. When
  /// set, a V2Ray session starts the underlay core first and
  /// the Xray outbound dials THROUGH it (dialerProxy) —
  /// V2Ray over Psiphon, over the EmberWarp core, or over a
  /// DNSTT DNS tunnel. Global, not per-profile.
  String underlay = 'none';

  /// The ByeDPI desync hop (build 2157, feature pick 4):
  /// '' = OFF (the default, the features law). Otherwise a
  /// zapret candidate id (zapret_args.dart): every V2Ray
  /// session's dial copy is stamped with it, so the
  /// session chains through the ciadpi (ByeDPI) desync
  /// proxy in front of the proxy server — the chain hop
  /// the DPI Lab's zap candidates proved, picked by hand
  /// here instead of by a Lab run. A settings value, never
  /// a stored profile field (Profile.zapretStrategy stays
  /// runtime-only; the stamp is re-derived per connect,
  /// exactly like the Lab's). Composes with the chain
  /// underlay above via the builder's dialerProxy merge.
  String byedpiHop = '';

  /// The DNSTT underlay's fields (build 2072): the resolver
  /// transport ('doh' | 'dot' | 'udp') and address, the
  /// tunnel domain, and the dnstt-server public key (64 hex
  /// digits). The client is a port forward whose far end is
  /// fixed by the server (see dnstt_args.dart) — these fields
  /// are all the client takes.
  String dnsttResolverType = 'doh';
  String dnsttResolver = '';
  String dnsttDomain = '';
  String dnsttPubkey = '';

  /// The OLCRTC underlay's fields (build 2134): the SFU
  /// provider ('jitsi' | 'telemost' | 'wbstream'), the
  /// transport ('datachannel' | 'vp8channel' |
  /// 'seichannel' | 'videochannel'), the room ID/URL both
  /// peers join, the shared key (64 hex digits), an
  /// optional provider account token, and the resolver
  /// the olcrtc process itself uses to reach the SFU
  /// (an upstream-required field of ITS YAML — not
  /// Ember's DNS settings). The per-transport tuning
  /// values stay strings like the AmneziaWG parameters:
  /// '' = upstream default, omitted from the YAML.
  /// See olcrtc_args.dart.
  String olcrtcProvider = 'jitsi';
  String olcrtcTransport = 'datachannel';
  String olcrtcRoom = '';
  String olcrtcKey = '';
  String olcrtcToken = '';
  String olcrtcDns = '8.8.8.8:53';
  String olcrtcVp8Fps = '';
  String olcrtcVp8Batch = '';
  String olcrtcSeiFps = '';
  String olcrtcSeiBatch = '';
  String olcrtcSeiFrag = '';
  String olcrtcSeiAckMs = '';
  String olcrtcVideoWidth = '';
  String olcrtcVideoHeight = '';
  String olcrtcVideoFps = '';
  String olcrtcVideoCodec = '';
  String olcrtcVideoQrSize = '';
  String olcrtcVideoQrRecovery = '';
  String olcrtcVideoTileModule = '';
  String olcrtcVideoTileRs = '';

  /// The RegionHop feature's fields (build 2139, leg 1 —
  /// see regionhop_client.dart and regionhop_page.dart):
  /// the owner's own regionhop panel (his server's Psiphon
  /// exits, reached through authenticated GOST relays on
  /// the same box). DEFAULT OFF: with [regionHopEnabled]
  /// false the app never contacts the panel, creates no
  /// profiles and generates byte-identical configs — the
  /// fields are inert storage. The panel password and the
  /// relay credentials are secrets of the same class as
  /// [olcrtcKey]: they live only in this settings store,
  /// are never journaled and never enter a diagnostics
  /// export; the panel session cookie is memory-only and
  /// is not stored here at all.
  bool regionHopEnabled = false;
  String regionHopPanelUrl = '';
  String regionHopPanelPassword = '';
  String regionHopRelays = '';

  /// The URnetwork source's account records (build
  /// 2154): a JSON list of UrAccount metadata (id, label,
  /// balance snapshot, per-proxy chosen countries — see
  /// urnetwork_client.dart). METADATA ONLY: an account's
  /// `urn_` API key is never part of this document — it
  /// lives in the SecretStore vault under
  /// urNetworkVaultKey(accountId), so this field is safe
  /// in backups and exports exactly as stored. '' = no
  /// accounts; the source is inert until the owner adds
  /// one on the URnetwork page.
  String urNetworkAccounts = '';

  /// Build 2134 (leg 2): automatic per-device HWID on
  /// subscription fetches (see hwid.dart). DEFAULT OFF —
  /// with it off, fetches send exactly what build 2133
  /// sent (a subscription's manual hwid and custom headers
  /// only). [deviceHwid] is a random UUID generated once
  /// when the switch is first enabled and kept stable
  /// afterwards; '' until then.
  bool subHwidEnabled = false;
  String deviceHwid = '';

  /// WireGuard over WebSocket (build 2072): when on, a
  /// WireGuard session carried by the V2Ray engine runs its
  /// peer traffic through a wstunnel client to [wgWstunnelUrl]
  /// — the profile's peer endpoint is rewritten to the local
  /// forwarder for the session (see wstunnel_args.dart).
  bool wgWstunnel = false;
  String wgWstunnelUrl = '';

  /// Ad-blocking DNS (build 2030): when on, the tunnel config's
  /// remote resolver is AdGuard's filtering DoH — ads and
  /// trackers fail at resolution. A preset, NOT a geosite.dat
  /// rule set (the plan-check's ruling). Wins over [remoteDns]
  /// for the config's primary resolver while on.
  bool adBlockDoh = false;

  /// DNS fallback policy (build 2030): when on, [fallbackDns]
  /// is appended after the primary resolver in the config's
  /// DNS section, so it answers only when the primary fails to
  /// resolve. It never sees a blocked domain when [adBlockDoh]
  /// is on: the filtering resolver ANSWERS those (with a
  /// null route), it does not fail them.
  bool dnsFallback = false;
  String fallbackDns = 'https://dns.quad9.net/dns-query';

  /// DNS group (build 2033): when on, the tunnel config's DNS
  /// section carries a GROUP of encrypted resolvers — the
  /// primary plus the well-known DoH endpoints in
  /// [dnsGroupMembers] — instead of a single resolver with an
  /// optional fallback. The core works the group in order per
  /// query and sticks to the resolver that answers (its own
  /// server-selection behaviour); every member is an encrypted
  /// resolver reached through the tunnel, so a poisoned local
  /// answer never enters the group. The group supersedes the
  /// single [fallbackDns] while on.
  bool dnsGroup = false;

  /// Custom DNS host entries (build 2041): the user's own
  /// domain-to-IP map, answered by the tunnel's DNS before any
  /// resolver is asked. Pin a name to a known-good IP when the
  /// local network's DNS lies about it (a poisoned answer for a
  /// subscription host, a provider's SNI name, or a local name
  /// like wg.home). Domain keys are stored lower-cased; values
  /// are single IPs. Invalid entries are dropped on load, never
  /// trusted — a corrupt store cannot break a connect. The
  /// builder merges these into the DNS section's hosts map,
  /// where a user entry wins over the built-in resolver pins
  /// for the same domain.
  Map<String, String> customDnsHosts = {};

  /// Traffic history (build 2105): when on, the stats poll's
  /// per-profile deltas are also recorded into hourly history
  /// buckets (traffic_history.dart) behind the Traffic history
  /// chart. Default OFF — off, nothing is recorded and the
  /// accounting behaves exactly as before. The totals the list
  /// shows are NOT gated by this: they were always kept.
  bool trafficHistoryEnabled = false;

  /// Smart groups (build 2105): when on, the profile list also
  /// gathers profiles into the rule-made groups of
  /// [smartGroupRules] (smart_groups.dart). Default OFF — off,
  /// the list is grouped by subscription exactly as before.
  bool smartGroupsEnabled = false;
  List<SmartGroupRule> smartGroupRules = [];

  /// Provider DNS (build 2105): when on, a connect resolves the
  /// selected profile's server hostname through its
  /// subscription's own DNS (Subscription.dns) and pins the
  /// answer into the config's hosts map, instead of leaving
  /// the name to the tunnel DNS chain alone. Default OFF —
  /// off, connects build exactly the 2103 shape. A failed
  /// provider lookup never blocks a connect: the config is
  /// built without the pin, as today.
  bool providerDnsEnabled = false;

  /// DPI Strategy Lab (build 2107): when on, the Lab wizard
  /// (dpi_lab.dart) can test which TLS evasion strategy
  /// carries traffic on the current network, a connect on a
  /// network with a remembered Lab win dials that strategy
  /// first (only when the per-profile shape cache has no win
  /// of its own there), and a failed connect offers the Lab.
  /// Default OFF — off, no connect path consults the Lab's
  /// memory and connects build and dial exactly the 2106
  /// shapes.
  bool dpiLabEnabled = false;

  /// The Senpai scanner (build 2129, Leg 3): a discovery
  /// tool inside the DPI Lab — the vendored SenPaiScanner
  /// binary (see senpai.dart / SenpaiCore.kt). Its own
  /// default-OFF toggle, on top of the Lab's: both must be
  /// on before the scanner page offers a Start button, and
  /// nothing on any connect path ever consults it.
  bool senpaiEnabled = false;

  /// Config mixins (build 2043): the user's own JSON object,
  /// merged into the tunnel config at the end of every build
  /// (see config_mixins.dart). Empty means no mixins — exactly
  /// the old behaviour. Stored as raw text so the user's
  /// formatting survives; parsed at save time (invalid JSON is
  /// refused) and again at build time (an invalid stored value
  /// is skipped, so a corrupt store can never break a connect).
  String configMixins = '';

  /// Auto-reconnect (build 2042, feature-watch 2026-11-12):
  /// when the tunnel drops by itself — the carrier kills it,
  /// the core dies — the app reconnects on its own after
  /// [reconnectDelaySeconds], up to [reconnectMaxAttempts]
  /// tries, through the same engine the session used. A manual
  /// disconnect never reconnects (the controller's expectation
  /// flag, not this setting, decides that). Default ON: on the
  /// networks this app is built for, a dropped tunnel that
  /// waits for a tap is a dropped tunnel. A stored value (on or
  /// off) is always respected, so only a user who never touched
  /// the setting gets the new default. NOT a kill-switch: while
  /// the app waits, the native service is down and traffic is
  /// direct until the reconnect lands. Build 2063 adds the kill
  /// switch as a separate setting ([killSwitch]): when it is on,
  /// the dead session's TUN is held as a blackhole while the
  /// retry waits, so this line holds only while the switch is off.
  /// Build 2114 (defaults reset): default OFF — v2rayNG does not
  /// reconnect a dropped tunnel by itself; the
  /// defaultsReset2114 migration moves a stored true to OFF
  /// once. A value set afterwards is kept.
  bool autoReconnect = false;

  /// Kill switch (build 2063, feature queue #3 — closes audit
  /// F-M8 as a feature): when on, an unexpected drop or a
  /// failed (re)connect holds the dead session's TUN as a
  /// blackhole instead of tearing it down, so all traffic is
  /// blocked until the tunnel reconnects or the user
  /// disconnects. Covers the V2Ray (Xray) and standalone WARP
  /// tunnels; AmneziaWG sessions cannot hold (the userspace
  /// device owns their TUN fd) and Psiphon/Lantern run their
  /// own services, so they are not covered yet — the Settings
  /// copy says so. If Android itself kills the app, no in-app
  /// switch can block; only Android's Always-on VPN can.
  /// Default OFF: a user who never touches it gets exactly
  /// the behaviour of every earlier build.
  bool killSwitch = false;

  /// Build 2095 (feature 2): the stall watchdog's master
  /// switch. The watchdog itself predates this build (2025);
  /// 2095 gives it a user control. Default on until build 2114
  /// (defaults reset): default OFF — no stall watchdog exists
  /// in v2rayNG; the defaultsReset2114 migration moves a
  /// stored true to OFF once. A value set afterwards is kept.
  bool stallWatchdog = false;

  /// DNS cache off (build 2075, feature item 23 — the one
  /// part of the DNS control pack the vendored core honestly
  /// supports): when on, the tunnel config's DNS section
  /// carries `disableCache: true`, so the core re-resolves
  /// instead of serving its in-memory cache. Optimistic
  /// caching and per-resolver timeouts have no field in the
  /// core's DNS schema (checked against the bundled fork)
  /// and are not offered. Default OFF — byte-identical
  /// configs for everyone who never touches it.
  bool dnsCacheDisabled = false;

  /// Dedicated browser proxy port (build 2075, feature item
  /// 17): when on, the tunnel config adds a fixed HTTP
  /// inbound on [browserPort] (loopback only) that exists
  /// purely so a desktop-style browser can be pointed at a
  /// stable address while connected. It is the same tunnel —
  /// no separate routing — and the browser must be configured
  /// by hand; the Settings caption says so. Default OFF.
  bool browserPortEnabled = false;
  int browserPort = 10810;

  /// Local proxy authentication (build 2075, feature item
  /// 24): when on AND both credentials are entered, the
  /// tunnel's loopback SOCKS + HTTP inbounds require this
  /// username/password (SOCKS5 user/pass auth, HTTP Basic).
  /// The LAN-sharing login (build 2062) stays separate and
  /// wins on the shared inbounds while sharing is on. Auth
  /// on with empty credentials is noauth, never a
  /// half-configured login — the same rule as the LAN login.
  bool localProxyAuth = false;
  String localProxyUser = '';
  String localProxyPass = '';

  /// True only when local auth is on AND both credentials
  /// are entered — the only state in which the builder emits
  /// password auth on the loopback inbounds.
  bool get localProxyAuthReady =>
      localProxyAuth && localProxyUser.isNotEmpty && localProxyPass.isNotEmpty;

  /// Country exclusion list (build 2075, feature item 16):
  /// ISO country codes (upper-case) that automatic selection
  /// — keep-fastest pruning and the fallback walk's
  /// auto-picks — must skip. A manual tap on an excluded
  /// config still connects it; the list governs automatic
  /// choices only, and the Settings copy says so.
  List<String> excludedCountries = [];

  /// Smart dial racing (build 2075, feature item 5): when
  /// on, a connect whose first candidate does not answer a
  /// quick TCP probe races the fallback group's next members
  /// in parallel and dials the first that answers, instead
  /// of walking them one slow timeout at a time; every probe
  /// outcome is learned into the per-network winner memory
  /// and the config's TCP ping. Default ON until build 2114
  /// (defaults reset): default OFF — an Ember extra with no
  /// v2rayNG counterpart; the defaultsReset2114 migration
  /// moves a stored true to OFF once. A value set afterwards
  /// is kept.
  bool smartDialRacing = false;

  /// Multi-peer WireGuard (build 2075, feature item 27):
  /// when on, connecting a WireGuard profile whose .conf
  /// group (see wgGroupKey) holds sibling peers emits ALL
  /// the group's peers into the Xray WireGuard outbound
  /// instead of just this profile's peer, so the core can
  /// use any of them. Default OFF — one peer per profile,
  /// every earlier build's behaviour.
  bool wgUseAllPeers = false;

  /// Routing by network type (build 2075, feature item 26):
  /// when on, the active routing preset follows the network
  /// — [routingPresetWifi] on Wi-Fi, [routingPresetMobile]
  /// on mobile data — applied on the connectivity change
  /// events the platform already pushes, and at connect.
  /// Default OFF: one preset everywhere, as before.
  bool routingByNetwork = false;
  RoutingPreset routingPresetWifi = RoutingPreset.global;
  RoutingPreset routingPresetMobile = RoutingPreset.global;

  /// Per-network winner memory (build 2065, item 4): network key
  /// (see NetworkIdentity.key) → the profile id that last
  /// connected AND carried traffic on that network. The shell
  /// preselects it when that network comes back.
  Map<String, String> lastProfileByNetwork = {};

  /// Rotate the uTLS fingerprint per connection (build 2065, item
  /// 13): when on, each new connect of a profile whose own
  /// fingerprint field is empty picks the next value from
  /// [tlsFingerprintRotationSet]. A profile with an explicitly
  /// set fingerprint is never overridden. Default off.
  bool rotateTlsFingerprint = false;

  /// The rotation cursor into [tlsFingerprintRotationSet].
  int tlsFingerprintIndex = 0;

  /// Scheduled subscription health (build 2065, item 12): when on,
  /// the app re-tests every profile with the real delay funnel at
  /// most once per [subHealthIntervalHours] while it runs (never
  /// while a tunnel is up). Default OFF for battery.
  bool subHealthEnabled = false;
  int subHealthIntervalHours = 12;
  int lastSubHealthAtMs = 0;

  // ---- Build 2147 (Iran features) — EVERY gate below is
  // DEFAULT OFF, per the standing law: a store that never
  // sets them behaves byte-identically to build 2146, and
  // the defaults stay v2rayNG's. See build2147-design.md.

  /// Feature #1: subscription / updater / RegionHop fetches
  /// route through the active session's local SOCKS inbound
  /// instead of the direct path.
  bool fetchViaTunnel = false;

  /// Feature #2: PMTU black-hole walk before tunnel start;
  /// the winning size feeds the session's tunnel MTU and is
  /// kept in [autoMtuFound] (0 = nothing discovered yet).
  bool autoMtu = false;
  int autoMtuFound = 0;

  /// Feature #3: the DPI Lab probes its top candidates
  /// concurrently instead of sequentially (inside the Lab's
  /// own dpiLabEnabled gate).
  bool dpiLabRacing = false;

  /// Feature #4: the SNI whitelist scan surface is offered.
  bool sniScanEnabled = false;

  /// Daily problem report (build 2149, owner expansion 4):
  /// the structured problem journal records problem events
  /// and offers the day's digest. DEFAULT OFF (the
  /// features law) — off means no recording, no journal
  /// file, no digest, no badge.
  bool dailyProblemReport = false;

  /// The detailed-logging window (build 2157, feature
  /// pick 3): while [detailedLogUntilMs] is in the future,
  /// the problem journal records even if the daily report
  /// toggle is off, and the core log level is 'debug' —
  /// the pre-window level is kept in
  /// [detailedLogPrevLogLevel] and restored when the
  /// window ends (XrayController.startDetailedLogging).
  /// 0 = no window. Both fields persist so a window armed
  /// before a process death is reconciled on load, never
  /// left with the log level stuck at debug.
  int detailedLogUntilMs = 0;
  String detailedLogPrevLogLevel = '';

  /// Connected-but-blocked alert (build 2151, item D):
  /// when a session is adopted but its background
  /// data-plane proof never lands, the journal says so
  /// plainly — one ✗ line per session — instead of
  /// leaving the user to discover dead traffic. DEFAULT
  /// ON: the owner's explicit exception to the features
  /// law for this one toggle (2026-11-26, «بزار روشن
  /// باشه این فقط»). Off restores build 2150's silence
  /// exactly; nothing else changes either way.
  bool blockedAlert = true;

  /// Tunnel bridge (build 2155 — the 2153 bridge swap,
  /// shipped under the 2155 number): which TUN → SOCKS
  /// bridge the V2Ray path runs. 'hev' is
  /// hev-socks5-tunnel (C + lwIP, in-process, no gVisor —
  /// TCP is not terminated in a userspace stack), the new
  /// default; 'tunlink' is the legacy gVisor subprocess,
  /// kept in the APK as the on-device A/B fallback. The
  /// choice rides xraySetOn's 'bridge' argument into
  /// XrayVpnService and applies at the next connect, like
  /// every session argument. Any other stored value reads
  /// as 'hev' at the service; the field itself round-trips
  /// verbatim.
  String v2rayBridge = 'hev';

  /// Feature #5: subscription group ids whose connect mode is
  /// the core Balancer (observatory + leastPing) instead of a
  /// single picked profile. Per-group opt-in; empty = none.
  List<String> balancerGroupIds = [];

  /// Feature #6: SSH profiles (Protocol.ssh) are offered and
  /// served by the sing-box sidecar.
  bool sidecarSshEnabled = false;

  /// Feature #12: a live session whose downlink bytes do not
  /// move for [stallFailoverSeconds] runs the existing
  /// reconnect / next-in-group sequence. (The 2025 stall
  /// watchdog's own switch is [stallWatchdog]; this is the
  /// failover action layer on top of it.)
  bool stallFailover = false;
  int stallFailoverSeconds = 30;

  /// Feature #13: while connected, the exit is re-checked on
  /// an interval and on network changes; changes are
  /// journaled and badged.
  bool exitMonitorEnabled = false;

  /// Feature #17: periodic real delay tests over favourites
  /// while the app runs; dead favourites are badged.
  bool scheduledTests = false;
  int scheduledTestIntervalMin = 60;
  int lastScheduledTestAtMs = 0;

  /// Feature #18: import-time safety warnings (loopback /
  /// RFC1918 endpoints, DNS-carriage traps, unexpected link
  /// payloads) listed in the import sheet — warn, never block.
  bool importSafetyFilter = false;

  /// Feature #20: per-network handshake-failure counting;
  /// a profile failing [pingSweepFailStrikes]x on one
  /// network is badged and deprioritised (never deleted,
  /// never hidden). Build 2149 (audit A48-06): the strike
  /// threshold is the same configurable one the ping
  /// sweep (#21a) uses — one threshold for both paths.
  bool quarantineEnabled = false;

  /// Feature #21a: the ping sweep's auto-cut — a config not
  /// answering across [pingSweepFailStrikes] consecutive
  /// sweeps is disabled and moved to the quarantine list
  /// (restorable, never hard-deleted).
  bool pingSweepEnabled = false;
  int pingSweepFailStrikes = 3;

  /// Feature #21b: set once the two built-in default
  /// subscriptions have been seeded (they stay removable
  /// like any other subscription afterwards).
  bool defaultSubsSeeded2147 = false;

  /// Feature #21a: profile id → consecutive ping sweeps it
  /// has not answered. Persisted so a restart does not reset
  /// the auto-cut accounting.
  Map<String, int> sweepMissByProfile = {};

  /// Build 2149 (audit A48-06): profile id → the network
  /// fingerprint [sweepMissByProfile]'s count belongs to.
  /// The sweep's misses are per-network, like feature
  /// #20's strikes: a miss on a NEW network restarts the
  /// count at 1 instead of adding to another network's.
  Map<String, String> sweepMissNetworkByProfile = {};

  /// Seconds between an unexpected drop and the next reconnect
  /// try. Clamped 5..120 wherever it is read, so a corrupt
  /// stored value can never spin a tight retry loop or wait
  /// forever.
  int reconnectDelaySeconds = 10;

  /// Reconnect tries per drop before the app gives up and waits
  /// for the user. Clamped 1..20 wherever it is read. Each try
  /// runs the normal connect path, so one try already works the
  /// fallback group (up to 3 members) before it counts as a
  /// failed try.
  int reconnectMaxAttempts = 5;

  /// Clamps a reconnect delay to the offered range (see
  /// [reconnectDelaySeconds]).
  static int clampReconnectDelay(int v) => v < 5 ? 5 : (v > 120 ? 120 : v);

  /// Clamps a reconnect attempt budget to the offered range (see
  /// [reconnectMaxAttempts]).
  static int clampReconnectMaxAttempts(int v) => v < 1 ? 1 : (v > 20 ? 20 : v);

  String fragmentPackets = 'tlshello';
  int fragmentLength = 100;
  int fragmentInterval = 10;

  /// Whether the Xray-side TUN captures IPv6 (the ::/0
  /// route + the ULA address in XrayVpnService). Build
  /// 2103 (diagnosis D1/E1): the default is now OFF —
  /// v2rayNG's PREF_IPV6_ENABLED defaults off too, and
  /// with it off its TUN carries no IPv6 address or route
  /// at all (CoreVpnService.configureNetworkSettings).
  /// Ember's shipped default ON was masked until 2101 by
  /// the DNS UseIPv4 pin; with the pin gone, AAAA answers
  /// sent apps into a tun2socks IPv6 path nothing proves
  /// can carry them — the "only Telegram + YouTube work"
  /// blackhole. The toggle stays for those who want it;
  /// defaultsMigrated2103 moves a stored true (the old
  /// shipped default, indistinguishable from a deliberate
  /// choice) to OFF once. NOTE: this flag no longer feeds
  /// the AWG service — since 2103 that gate is the
  /// profile's own IPv6 footprint (profileHasIpv6), so a
  /// v6-only WireGuard profile keeps its ::/0 route under
  /// the new default (the 2102 C3 coupling, decoupled).
  bool ipv6Route = false;

  /// The routing domain strategy. Default 'AsIs' since 2024 —
  /// v2rayNG's template value; the pre-2024 default IPIfNonMatch
  /// made the router resolve every destination domain through
  /// the DNS section before rule matching, an extra dependency
  /// on the resolver for every connection. Stored old defaults
  /// are migrated once (see [XraySettings.fromJson]).
  String domainStrategy = 'AsIs';
  RoutingPreset routingPreset = RoutingPreset.global;
  List<String> customDirectDomains = [];
  List<String> customDirectIps = [];
  List<String> customBlockDomains = [];
  List<String> customProxyDomains = [];

  /// Subscription auto-update period, hours (0 = only on launch if stale).
  int subAutoUpdateHours = 24;

  /// Fallback cooldowns (build 2060): profile ids → epoch ms of
  /// their last fallback failure. Persisted so a process restart
  /// does not clear the cooldowns; expired entries are pruned on
  /// load (see XrayController._hydrateCooldowns).
  Map<String, int> fallbackFailedAtMs = {};

  /// Build 2126 (audit A26-26): DEFAULT OFF — up to 2125
  /// this shipped ON with no v2rayNG-parity grounding,
  /// the one remaining unexplained ON default against
  /// the owner's defaults law. Stored ON values are
  /// forced OFF once by the defaultsReset2126 migration
  /// in fromJson (a stored ON was the shipped default,
  /// not a discernible choice); a value set afterwards
  /// is kept.
  bool subUpdateOnLaunch = false;

  /// The one-time A26-26 migration stamp (the
  /// defaultsReset2125 pattern).
  bool defaultsReset2126 = false;

  /// Build 2133 (V2Ray full tab): the loose ("Manual
  /// configs") group's last completed per-group ping
  /// summary — the mirror of Subscription's lastPingMs /
  /// bestPingName / bestPingMs for the one group that is
  /// not a subscription. 0 / '' / -1 = never pinged.
  int looseLastPingMs = 0;
  String looseBestPingName = '';
  int looseBestPingMs = -1;

  Map<String, dynamic> toJson() => {
    'enableUdp': enableUdp,
    'localDns': localDns,
    'remoteDns': remoteDns,
    'remoteDnsProto': remoteDnsProto,
    'tunnelMtu': tunnelMtu,
    'testAllConcurrency': testAllConcurrency,
    'delayTestTimeoutSec': delayTestTimeoutSec,
    'remoteDnsMigrated': remoteDnsMigrated,
    'defaultsMigrated2101': defaultsMigrated2101,
    'defaultsMigrated2111': defaultsMigrated2111,
    'defaultsMigrated2113': defaultsMigrated2113,
    'defaultsMigrated2103': defaultsMigrated2103,
    'defaultsReset2114': defaultsReset2114,
    'addressNameHealed2103': addressNameHealed2103,
    'domainStrategyMigrated': domainStrategyMigrated,
    'fingerprintDefaultMigrated': fingerprintDefaultMigrated,
    'socksPort': socksPort,
    'httpPort': httpPort,
    'lastProfileByNetwork': lastProfileByNetwork,
    'rotateTlsFingerprint': rotateTlsFingerprint,
    'tlsFingerprintIndex': tlsFingerprintIndex,
    'subHealthEnabled': subHealthEnabled,
    'subHealthIntervalHours': subHealthIntervalHours,
    'lastSubHealthAtMs': lastSubHealthAtMs,
    'fetchViaTunnel': fetchViaTunnel,
    'autoMtu': autoMtu,
    'autoMtuFound': autoMtuFound,
    'dpiLabRacing': dpiLabRacing,
    'sniScanEnabled': sniScanEnabled,
    'dailyProblemReport': dailyProblemReport,
    'detailedLogUntilMs': detailedLogUntilMs,
    'detailedLogPrevLogLevel': detailedLogPrevLogLevel,
    'blockedAlert': blockedAlert,
    'v2rayBridge': v2rayBridge,
    'balancerGroupIds': balancerGroupIds,
    'sidecarSshEnabled': sidecarSshEnabled,
    'stallFailover': stallFailover,
    'stallFailoverSeconds': stallFailoverSeconds,
    'exitMonitorEnabled': exitMonitorEnabled,
    'scheduledTests': scheduledTests,
    'scheduledTestIntervalMin': scheduledTestIntervalMin,
    'lastScheduledTestAtMs': lastScheduledTestAtMs,
    'importSafetyFilter': importSafetyFilter,
    'quarantineEnabled': quarantineEnabled,
    'pingSweepEnabled': pingSweepEnabled,
    'pingSweepFailStrikes': pingSweepFailStrikes,
    'defaultSubsSeeded2147': defaultSubsSeeded2147,
    'sweepMissByProfile': sweepMissByProfile,
    'sweepMissNetworkByProfile': sweepMissNetworkByProfile,
    'lanShareEnabled': lanShareEnabled,
    'lanShareAuth': lanShareAuth,
    'lanShareUser': lanShareUser,
    'lanSharePass': lanSharePass,
    'sniffing': sniffing,
    'sniffHttp': sniffHttp,
    'sniffTls': sniffTls,
    'sniffQuic': sniffQuic,
    'blockQuic': blockQuic,
    'shadowTlsFronting': shadowTlsFronting,
    'geckoPacketSizes': geckoPacketSizes,
    'hy2NoiseDecoy': hy2NoiseDecoy,
    'fragmentViaFinalmask': fragmentViaFinalmask,
    'sidecarTlsFragment': sidecarTlsFragment,
    'stopVpnOnSleep': stopVpnOnSleep,
    'fragmentRandomGeometry': fragmentRandomGeometry,
    'autoFastestGroup': autoFastestGroup,
    'sniSpoofEnabled': sniSpoofEnabled,
    'sniSpoofRules': [for (final r in sniSpoofRules) r.toJson()],
    'sudokuEnabled': sudokuEnabled,
    'logLevel': logLevel,
    'fakeDns': fakeDns,
    'muxEnabled': muxEnabled,
    'muxConcurrency': muxConcurrency,
    'fragmentEnabled': fragmentEnabled,
    'adaptiveFailover': adaptiveFailover,
    'underlay': underlay,
    'byedpiHop': byedpiHop,
    'dnsttResolverType': dnsttResolverType,
    'dnsttResolver': dnsttResolver,
    'dnsttDomain': dnsttDomain,
    'dnsttPubkey': dnsttPubkey,
    'olcrtcProvider': olcrtcProvider,
    'olcrtcTransport': olcrtcTransport,
    'olcrtcRoom': olcrtcRoom,
    'olcrtcKey': olcrtcKey,
    'olcrtcToken': olcrtcToken,
    'olcrtcDns': olcrtcDns,
    'olcrtcVp8Fps': olcrtcVp8Fps,
    'olcrtcVp8Batch': olcrtcVp8Batch,
    'olcrtcSeiFps': olcrtcSeiFps,
    'olcrtcSeiBatch': olcrtcSeiBatch,
    'olcrtcSeiFrag': olcrtcSeiFrag,
    'olcrtcSeiAckMs': olcrtcSeiAckMs,
    'olcrtcVideoWidth': olcrtcVideoWidth,
    'olcrtcVideoHeight': olcrtcVideoHeight,
    'olcrtcVideoFps': olcrtcVideoFps,
    'olcrtcVideoCodec': olcrtcVideoCodec,
    'olcrtcVideoQrSize': olcrtcVideoQrSize,
    'olcrtcVideoQrRecovery': olcrtcVideoQrRecovery,
    'olcrtcVideoTileModule': olcrtcVideoTileModule,
    'olcrtcVideoTileRs': olcrtcVideoTileRs,
    'regionHopEnabled': regionHopEnabled,
    'regionHopPanelUrl': regionHopPanelUrl,
    'regionHopPanelPassword': regionHopPanelPassword,
    'regionHopRelays': regionHopRelays,
    'urNetworkAccounts': urNetworkAccounts,
    'subHwidEnabled': subHwidEnabled,
    'deviceHwid': deviceHwid,
    'wgWstunnel': wgWstunnel,
    'wgWstunnelUrl': wgWstunnelUrl,
    'adBlockDoh': adBlockDoh,
    'dnsFallback': dnsFallback,
    'fallbackDns': fallbackDns,
    'dnsGroup': dnsGroup,
    'customDnsHosts': customDnsHosts,
    'trafficHistoryEnabled': trafficHistoryEnabled,
    'smartGroupsEnabled': smartGroupsEnabled,
    'smartGroupRules': [for (final r in smartGroupRules) r.toJson()],
    'providerDnsEnabled': providerDnsEnabled,
    'dpiLabEnabled': dpiLabEnabled,
    'senpaiEnabled': senpaiEnabled,
    'configMixins': configMixins,
    'autoReconnect': autoReconnect,
    'killSwitch': killSwitch,
    'stallWatchdog': stallWatchdog,
    'dnsCacheDisabled': dnsCacheDisabled,
    'browserPortEnabled': browserPortEnabled,
    'browserPort': browserPort,
    'localProxyAuth': localProxyAuth,
    'localProxyUser': localProxyUser,
    'localProxyPass': localProxyPass,
    'excludedCountries': excludedCountries,
    'smartDialRacing': smartDialRacing,
    'wgUseAllPeers': wgUseAllPeers,
    'routingByNetwork': routingByNetwork,
    'routingPresetWifi': routingPresetWifi.name,
    'routingPresetMobile': routingPresetMobile.name,
    'reconnectDelaySeconds': reconnectDelaySeconds,
    'reconnectMaxAttempts': reconnectMaxAttempts,
    'fragmentPackets': fragmentPackets,
    'fragmentLength': fragmentLength,
    'fragmentInterval': fragmentInterval,
    'ipv6Route': ipv6Route,
    'domainStrategy': domainStrategy,
    'routingPreset': routingPreset.name,
    'customDirectDomains': customDirectDomains,
    'customDirectIps': customDirectIps,
    'customBlockDomains': customBlockDomains,
    'customProxyDomains': customProxyDomains,
    'subAutoUpdateHours': subAutoUpdateHours,
    'fallbackFailedAtMs': fallbackFailedAtMs,
    'subUpdateOnLaunch': subUpdateOnLaunch,
    'looseLastPingMs': looseLastPingMs,
    'looseBestPingName': looseBestPingName,
    'looseBestPingMs': looseBestPingMs,
    'defaultsReset2126': defaultsReset2126,
  };

  factory XraySettings.fromJson(Map<String, dynamic> j) {
    final s = XraySettings();
    s.enableUdp = _storedBool(j, 'enableUdp', s.enableUdp);
    s.localDns = _storedStr(j, 'localDns', s.localDns);
    s.remoteDns = _storedStr(j, 'remoteDns', s.remoteDns);
    s.remoteDnsProto = _storedStr(j, 'remoteDnsProto', s.remoteDnsProto);
    s.tunnelMtu = clampTunnelMtu(_storedInt(j, 'tunnelMtu', s.tunnelMtu));
    s.testAllConcurrency = _storedInt(
      j,
      'testAllConcurrency',
      s.testAllConcurrency,
    );
    // Build 2109: plain stored read, clamped — a pre-2109
    // store carries no such key and keeps the 8 s the request
    // path always used; a corrupt value clamps to 3..20 and
    // can never break a test.
    s.delayTestTimeoutSec = clampDelayTestTimeoutSec(
      _storedInt(j, 'delayTestTimeoutSec', s.delayTestTimeoutSec),
    );
    s.remoteDnsMigrated = _storedBool(j, 'remoteDnsMigrated', false);
    if (!s.remoteDnsMigrated) {
      // One-time 2005 migration: a stored value equal to the pre-2005
      // default was never a deliberate choice, so move it to the
      // v2rayNG-aligned default. The flag is persisted on the next
      // save; the field itself stays fully user-editable.
      if (s.remoteDns == 'https://1.1.1.1/dns-query') {
        s.remoteDns = 'https://dns.google/dns-query';
      }
      s.remoteDnsMigrated = true;
    }
    s.defaultsMigrated2101 = _storedBool(j, 'defaultsMigrated2101', false);
    if (!s.defaultsMigrated2101) {
      // One-time build-2101 migration (owner order 2026-11-18:
      // DNS defaults become v2rayNG's own): a stored value equal
      // to the pre-2101 default was the shipped default, not a
      // deliberate choice, so it moves to the new default. The
      // 2005 migration above runs first, so a pre-2005 store
      // chains 1.1.1.1 DoH → Google DoH → Cloudflare DoH in one
      // load. A stored testAllConcurrency of exactly the old
      // default (4) moves to the new default (8) the same way.
      if (s.remoteDns.trim() == 'https://dns.google/dns-query') {
        s.remoteDns = 'https://cloudflare-dns.com/dns-query';
      }
      if (s.testAllConcurrency == 4) {
        s.testAllConcurrency = 8;
      }
      s.defaultsMigrated2101 = true;
    }
    s.defaultsMigrated2111 = _storedBool(j, 'defaultsMigrated2111', false);
    if (!s.defaultsMigrated2111) {
      // One-time build-2111 migration: a stored value equal to
      // either shipped DoH default was never a working choice
      // on the owner's path — the 2110 export proved the DoH
      // transport through the tunnel dead (100% timeouts,
      // both providers) — so it moves to the new plain-IP
      // default, whose queries ride UDP. Runs after the 2101
      // migration above, so a pre-2101 store chains Google
      // DoH → Cloudflare DoH → 1.1.1.1 in one load. Any other
      // stored value (a custom resolver, a list, the new
      // default itself) is untouched.
      final storedRemote = s.remoteDns.trim();
      if (storedRemote == 'https://cloudflare-dns.com/dns-query' ||
          storedRemote == 'https://8.8.8.8/dns-query') {
        s.remoteDns = '1.1.1.1';
      }
      s.defaultsMigrated2111 = true;
    }
    s.defaultsMigrated2113 = _storedBool(j, 'defaultsMigrated2113', false);
    if (!s.defaultsMigrated2113) {
      // One-time build-2113 migration (owner order 2026-11-19:
      // the DNS configuration is v2rayNG's own, verbatim —
      // v2rayng-config-diff-2112.md): the 2111 plain-IP default
      // and every resolver value the owner cycled through while
      // fighting the dead-DNS defect (his Diagnostics exports
      // of 2026-11-18 23:02 and 2026-11-19 03:18 show the Google
      // DoH, the Google-IP DoH and the AdGuard TCP address tried
      // in desperation, none of them ever working) move back to
      // v2rayNG's default. Runs after the 2111 migration above,
      // so a pre-2111 store chains Cloudflare DoH → 1.1.1.1 →
      // Cloudflare DoH in one load and lands on the same value.
      // Any other stored value is a deliberate choice and kept.
      final storedRemote = s.remoteDns.trim();
      if (storedRemote == '1.1.1.1' ||
          storedRemote == 'https://dns.google/dns-query' ||
          storedRemote == 'https://8.8.8.8/dns-query' ||
          storedRemote == '94.140.14.14' ||
          storedRemote == 'tcp://94.140.14.14') {
        s.remoteDns = 'https://cloudflare-dns.com/dns-query';
      }
      s.defaultsMigrated2113 = true;
    }
    s.socksPort = _storedInt(j, 'socksPort', s.socksPort);
    s.httpPort = _storedInt(j, 'httpPort', s.httpPort);
    s.lanShareEnabled = _storedBool(j, 'lanShareEnabled', s.lanShareEnabled);
    s.lanShareAuth = _storedBool(j, 'lanShareAuth', s.lanShareAuth);
    s.lanShareUser = _storedStr(j, 'lanShareUser', s.lanShareUser);
    s.lanSharePass = _storedStr(j, 'lanSharePass', s.lanSharePass);
    // Build 2057 (audit F-M2): a stored pair that would collide
    // with another engine, with each other, or push the stats
    // port past 65535 sanitises to the defaults instead of
    // breaking every connect with a generic start failure. The
    // Settings input validates with the same function and shows
    // the named message, so a deliberate choice is refused there
    // rather than silently rewritten here.
    if (validateXrayPorts(socksPort: s.socksPort, httpPort: s.httpPort) !=
        null) {
      s.socksPort = 10808;
      s.httpPort = 10809;
    }
    s.sniffing = _storedBool(j, 'sniffing', s.sniffing);
    s.sniffHttp = _storedBool(j, 'sniffHttp', s.sniffHttp);
    s.sniffTls = _storedBool(j, 'sniffTls', s.sniffTls);
    s.sniffQuic = _storedBool(j, 'sniffQuic', s.sniffQuic);
    // Build 2108: plain stored read, default OFF — a
    // pre-2108 store carries no such key and keeps QUIC
    // unblocked, exactly as before.
    s.blockQuic = _storedBool(j, 'blockQuic', s.blockQuic);
    // Build 2126: plain stored read, default OFF — a
    // pre-2126 store carries no such key and keeps every
    // Shadowsocks profile on the Xray core, exactly as before.
    s.shadowTlsFronting = _storedBool(
      j,
      'shadowTlsFronting',
      s.shadowTlsFronting,
    );
    // Build 2126 (D1/D2/D6/D8): plain stored reads,
    // default OFF — pre-2126 stores carry none of these
    // keys and keep 2125 behaviour exactly.
    s.geckoPacketSizes = _storedBool(
      j,
      'geckoPacketSizes',
      s.geckoPacketSizes,
    );
    s.hy2NoiseDecoy = _storedBool(j, 'hy2NoiseDecoy', s.hy2NoiseDecoy);
    s.fragmentViaFinalmask = _storedBool(
      j,
      'fragmentViaFinalmask',
      s.fragmentViaFinalmask,
    );
    s.sidecarTlsFragment = _storedBool(
      j,
      'sidecarTlsFragment',
      s.sidecarTlsFragment,
    );
    // Build 2136: plain stored reads, default OFF — a
    // pre-2136 store carries none of these keys and keeps
    // 2135 behaviour exactly.
    s.stopVpnOnSleep = _storedBool(j, 'stopVpnOnSleep', s.stopVpnOnSleep);
    s.fragmentRandomGeometry = _storedBool(
      j,
      'fragmentRandomGeometry',
      s.fragmentRandomGeometry,
    );
    s.autoFastestGroup = _storedBool(
      j,
      'autoFastestGroup',
      s.autoFastestGroup,
    );
    // Build 2127 (H3): plain stored reads, default OFF —
    // a pre-2127 store carries neither key and keeps
    // 2126 behaviour exactly.
    s.sniSpoofEnabled = _storedBool(j, 'sniSpoofEnabled', s.sniSpoofEnabled);
    final rawSpoofRules = j['sniSpoofRules'];
    if (rawSpoofRules is List) {
      s.sniSpoofRules = [
        for (final raw in rawSpoofRules) ?SniSpoofRule.fromJson(raw),
      ];
    }
    // Build 2127 (H2): plain stored read, default OFF.
    s.sudokuEnabled = _storedBool(j, 'sudokuEnabled', s.sudokuEnabled);
    s.logLevel = _storedStr(j, 'logLevel', s.logLevel);
    s.fakeDns = _storedBool(j, 'fakeDns', s.fakeDns);
    s.muxEnabled = _storedBool(j, 'muxEnabled', s.muxEnabled);
    s.muxConcurrency = _storedInt(j, 'muxConcurrency', s.muxConcurrency);
    s.fragmentEnabled = _storedBool(j, 'fragmentEnabled', s.fragmentEnabled);
    s.adaptiveFailover = _storedBool(j, 'adaptiveFailover', s.adaptiveFailover);
    // Only the known underlays survive a store read; anything
    // else (a corrupt or future value) reads as 'none' rather
    // than chaining a session through a phantom underlay. No
    // cast: a corrupt store may hold any type here.
    s.underlay = switch (j['underlay']) {
      'psiphon' => 'psiphon',
      'warp' => 'warp',
      'dnstt' => 'dnstt',
      'olcrtc' => 'olcrtc',
      _ => 'none',
    };
    // Build 2157 (feature pick 4): only a real zapret
    // candidate survives a store read — anything else
    // reads as OFF rather than stamping a phantom desync
    // strategy onto a session.
    final storedHop = j['byedpiHop'];
    s.byedpiHop = storedHop is String && isZapretCandidate(storedHop)
        ? storedHop
        : '';
    // DNSTT + WireGuard-over-WebSocket fields (build 2072),
    // read field-defensively like every other setting (build
    // 2066): one bad field never discards the whole store.
    s.dnsttResolverType = switch (j['dnsttResolverType']) {
      'dot' => 'dot',
      'udp' => 'udp',
      _ => 'doh',
    };
    s.dnsttResolver = _storedStr(j, 'dnsttResolver', s.dnsttResolver);
    s.dnsttDomain = _storedStr(j, 'dnsttDomain', s.dnsttDomain);
    s.dnsttPubkey = _storedStr(j, 'dnsttPubkey', s.dnsttPubkey);
    // OLCRTC underlay fields (build 2134), read
    // field-defensively like the DNSTT block above; the
    // provider/transport whitelists keep a corrupt store
    // from spawning a config upstream would refuse.
    s.olcrtcProvider = switch (j['olcrtcProvider']) {
      'telemost' => 'telemost',
      'wbstream' => 'wbstream',
      _ => 'jitsi',
    };
    s.olcrtcTransport = switch (j['olcrtcTransport']) {
      'vp8channel' => 'vp8channel',
      'seichannel' => 'seichannel',
      'videochannel' => 'videochannel',
      _ => 'datachannel',
    };
    s.olcrtcRoom = _storedStr(j, 'olcrtcRoom', s.olcrtcRoom);
    s.olcrtcKey = _storedStr(j, 'olcrtcKey', s.olcrtcKey);
    s.olcrtcToken = _storedStr(j, 'olcrtcToken', s.olcrtcToken);
    s.olcrtcDns = _storedStr(j, 'olcrtcDns', s.olcrtcDns);
    s.olcrtcVp8Fps = _storedStr(j, 'olcrtcVp8Fps', s.olcrtcVp8Fps);
    s.olcrtcVp8Batch = _storedStr(j, 'olcrtcVp8Batch', s.olcrtcVp8Batch);
    s.olcrtcSeiFps = _storedStr(j, 'olcrtcSeiFps', s.olcrtcSeiFps);
    s.olcrtcSeiBatch = _storedStr(j, 'olcrtcSeiBatch', s.olcrtcSeiBatch);
    s.olcrtcSeiFrag = _storedStr(j, 'olcrtcSeiFrag', s.olcrtcSeiFrag);
    s.olcrtcSeiAckMs = _storedStr(j, 'olcrtcSeiAckMs', s.olcrtcSeiAckMs);
    s.olcrtcVideoWidth = _storedStr(j, 'olcrtcVideoWidth', s.olcrtcVideoWidth);
    s.olcrtcVideoHeight = _storedStr(
      j,
      'olcrtcVideoHeight',
      s.olcrtcVideoHeight,
    );
    s.olcrtcVideoFps = _storedStr(j, 'olcrtcVideoFps', s.olcrtcVideoFps);
    s.olcrtcVideoCodec = _storedStr(j, 'olcrtcVideoCodec', s.olcrtcVideoCodec);
    s.olcrtcVideoQrSize = _storedStr(
      j,
      'olcrtcVideoQrSize',
      s.olcrtcVideoQrSize,
    );
    s.olcrtcVideoQrRecovery = _storedStr(
      j,
      'olcrtcVideoQrRecovery',
      s.olcrtcVideoQrRecovery,
    );
    s.olcrtcVideoTileModule = _storedStr(
      j,
      'olcrtcVideoTileModule',
      s.olcrtcVideoTileModule,
    );
    s.olcrtcVideoTileRs = _storedStr(j, 'olcrtcVideoTileRs', s.olcrtcVideoTileRs);
    s.regionHopEnabled = _storedBool(j, 'regionHopEnabled', s.regionHopEnabled);
    s.regionHopPanelUrl = _storedStr(j, 'regionHopPanelUrl', s.regionHopPanelUrl);
    s.regionHopPanelPassword = _storedStr(
      j,
      'regionHopPanelPassword',
      s.regionHopPanelPassword,
    );
    s.regionHopRelays = _storedStr(j, 'regionHopRelays', s.regionHopRelays);
    s.urNetworkAccounts = _storedStr(
      j,
      'urNetworkAccounts',
      s.urNetworkAccounts,
    );
    s.subHwidEnabled = _storedBool(j, 'subHwidEnabled', s.subHwidEnabled);
    s.deviceHwid = _storedStr(j, 'deviceHwid', s.deviceHwid);
    s.wgWstunnel = _storedBool(j, 'wgWstunnel', s.wgWstunnel);
    s.wgWstunnelUrl = _storedStr(j, 'wgWstunnelUrl', s.wgWstunnelUrl);
    s.adBlockDoh = _storedBool(j, 'adBlockDoh', s.adBlockDoh);
    s.dnsFallback = _storedBool(j, 'dnsFallback', s.dnsFallback);
    s.fallbackDns = _storedStr(j, 'fallbackDns', s.fallbackDns);
    s.dnsGroup = _storedBool(j, 'dnsGroup', s.dnsGroup);
    s.autoReconnect = _storedBool(j, 'autoReconnect', s.autoReconnect);
    s.killSwitch = _storedBool(j, 'killSwitch', s.killSwitch);
    s.stallWatchdog = _storedBool(j, 'stallWatchdog', s.stallWatchdog);
    // Build 2147 (Iran features): field-defensive reads; an
    // absent key keeps the DEFAULT OFF in-memory value.
    s.fetchViaTunnel = _storedBool(j, 'fetchViaTunnel', s.fetchViaTunnel);
    s.autoMtu = _storedBool(j, 'autoMtu', s.autoMtu);
    s.autoMtuFound = _storedInt(j, 'autoMtuFound', s.autoMtuFound);
    s.dpiLabRacing = _storedBool(j, 'dpiLabRacing', s.dpiLabRacing);
    s.sniScanEnabled = _storedBool(j, 'sniScanEnabled', s.sniScanEnabled);
    s.dailyProblemReport = _storedBool(
      j,
      'dailyProblemReport',
      s.dailyProblemReport,
    );
    // Build 2157 (feature pick 3): the detailed-logging
    // window's persisted state (see the field doc).
    s.detailedLogUntilMs = _storedInt(
      j,
      'detailedLogUntilMs',
      s.detailedLogUntilMs,
    );
    s.detailedLogPrevLogLevel = _storedStr(
      j,
      'detailedLogPrevLogLevel',
      s.detailedLogPrevLogLevel,
    );
    // Build 2151 (item D): an absent key keeps the
    // DEFAULT ON in-memory value (the owner's ordered
    // exception); a stored value is honoured verbatim.
    s.blockedAlert = _storedBool(j, 'blockedAlert', s.blockedAlert);
    // Build 2155 (the 2153 swap): an absent or wrong-typed
    // key keeps the 'hev' default.
    s.v2rayBridge = _storedStr(j, 'v2rayBridge', s.v2rayBridge);
    s.sidecarSshEnabled =
        _storedBool(j, 'sidecarSshEnabled', s.sidecarSshEnabled);
    s.stallFailover = _storedBool(j, 'stallFailover', s.stallFailover);
    s.stallFailoverSeconds =
        _storedInt(j, 'stallFailoverSeconds', s.stallFailoverSeconds);
    s.exitMonitorEnabled =
        _storedBool(j, 'exitMonitorEnabled', s.exitMonitorEnabled);
    s.scheduledTests = _storedBool(j, 'scheduledTests', s.scheduledTests);
    s.scheduledTestIntervalMin =
        _storedInt(j, 'scheduledTestIntervalMin', s.scheduledTestIntervalMin);
    s.lastScheduledTestAtMs =
        _storedInt(j, 'lastScheduledTestAtMs', s.lastScheduledTestAtMs);
    s.importSafetyFilter =
        _storedBool(j, 'importSafetyFilter', s.importSafetyFilter);
    s.quarantineEnabled =
        _storedBool(j, 'quarantineEnabled', s.quarantineEnabled);
    s.pingSweepEnabled =
        _storedBool(j, 'pingSweepEnabled', s.pingSweepEnabled);
    s.pingSweepFailStrikes =
        _storedInt(j, 'pingSweepFailStrikes', s.pingSweepFailStrikes);
    s.defaultSubsSeeded2147 =
        _storedBool(j, 'defaultSubsSeeded2147', s.defaultSubsSeeded2147);

    // Build 2075 settings block: field-defensive reads like
    // the 2072 block above — one bad field never discards
    // the whole store.
    s.dnsCacheDisabled =
        _storedBool(j, 'dnsCacheDisabled', s.dnsCacheDisabled);
    s.browserPortEnabled =
        _storedBool(j, 'browserPortEnabled', s.browserPortEnabled);
    s.browserPort = _storedInt(j, 'browserPort', s.browserPort);
    if (s.browserPort < 1024 || s.browserPort > 65535) s.browserPort = 10810;
    s.localProxyAuth = _storedBool(j, 'localProxyAuth', s.localProxyAuth);
    s.localProxyUser = _storedStr(j, 'localProxyUser', s.localProxyUser);
    s.localProxyPass = _storedStr(j, 'localProxyPass', s.localProxyPass);
    s.smartDialRacing = _storedBool(j, 'smartDialRacing', s.smartDialRacing);
    s.wgUseAllPeers = _storedBool(j, 'wgUseAllPeers', s.wgUseAllPeers);
    s.routingByNetwork =
        _storedBool(j, 'routingByNetwork', s.routingByNetwork);
    s.routingPresetWifi = RoutingPreset.values.firstWhere(
      (p) => p.name == _storedStr(j, 'routingPresetWifi', ''),
      orElse: () => RoutingPreset.global,
    );
    s.routingPresetMobile = RoutingPreset.values.firstWhere(
      (p) => p.name == _storedStr(j, 'routingPresetMobile', ''),
      orElse: () => RoutingPreset.global,
    );
    s.lastProfileByNetwork = _stringMap(j['lastProfileByNetwork']);
    s.rotateTlsFingerprint =
        _storedBool(j, 'rotateTlsFingerprint', s.rotateTlsFingerprint);
    s.tlsFingerprintIndex =
        _storedInt(j, 'tlsFingerprintIndex', s.tlsFingerprintIndex);
    s.subHealthEnabled =
        _storedBool(j, 'subHealthEnabled', s.subHealthEnabled);
    s.subHealthIntervalHours =
        _storedInt(j, 'subHealthIntervalHours', s.subHealthIntervalHours)
            .clamp(1, 168);
    s.lastSubHealthAtMs =
        _storedInt(j, 'lastSubHealthAtMs', s.lastSubHealthAtMs);
    // Config mixins (build 2043): raw JSON-object text. An `is`
    // check, not a cast: a corrupt store may hold any type here,
    // and a non-string reads as "no mixins" rather than throwing
    // the settings load (a bare `as String?` throws on an int).
    final storedMixins = j['configMixins'];
    s.configMixins = storedMixins is String ? storedMixins : s.configMixins;
    s.reconnectDelaySeconds = clampReconnectDelay(
      _storedInt(j, 'reconnectDelaySeconds', s.reconnectDelaySeconds),
    );
    s.reconnectMaxAttempts = clampReconnectMaxAttempts(
      _storedInt(j, 'reconnectMaxAttempts', s.reconnectMaxAttempts),
    );
    // Custom DNS hosts (build 2041): only well-formed
    // domain→IP pairs survive a store read; anything else (a
    // corrupt or hand-edited store) is dropped, never trusted
    // into a config. No cast: a corrupt store may hold any
    // type here.
    final rawHosts = j['customDnsHosts'];
    if (rawHosts is Map) {
      final hosts = <String, String>{};
      rawHosts.forEach((key, value) {
        hosts[key.toString()] = value.toString();
      });
      s.customDnsHosts = validDnsHosts(hosts);
    }
    // Build 2105 feature toggles: plain stored reads, all
    // default OFF, so a pre-2105 store (which carries none of
    // these keys) keeps every feature off.
    s.trafficHistoryEnabled =
        _storedBool(j, 'trafficHistoryEnabled', s.trafficHistoryEnabled);
    s.smartGroupsEnabled =
        _storedBool(j, 'smartGroupsEnabled', s.smartGroupsEnabled);
    s.providerDnsEnabled =
        _storedBool(j, 'providerDnsEnabled', s.providerDnsEnabled);
    s.dpiLabEnabled = _storedBool(j, 'dpiLabEnabled', s.dpiLabEnabled);
    s.senpaiEnabled = _storedBool(j, 'senpaiEnabled', s.senpaiEnabled);
    final rawRules = j['smartGroupRules'];
    if (rawRules is List) {
      s.smartGroupRules = [
        for (final raw in rawRules)
          if (SmartGroupRule.fromJson(raw) case final rule?) rule,
      ];
    }
    s.fragmentPackets = _storedStr(j, 'fragmentPackets', s.fragmentPackets);
    s.fragmentLength = _storedInt(j, 'fragmentLength', s.fragmentLength);
    s.fragmentInterval = _storedInt(j, 'fragmentInterval', s.fragmentInterval);
    s.ipv6Route = _storedBool(j, 'ipv6Route', s.ipv6Route);
    s.domainStrategy = _storedStr(j, 'domainStrategy', s.domainStrategy);
    s.domainStrategyMigrated = _storedBool(j, 'domainStrategyMigrated', false);
    if (!s.domainStrategyMigrated) {
      // One-time 2024 migration, same shape as the 2005 remote-DNS
      // one: a stored value equal to the old default was never a
      // deliberate choice, so move it to v2rayNG's 'AsIs'.
      if (s.domainStrategy == 'IPIfNonMatch') {
        s.domainStrategy = 'AsIs';
      }
      s.domainStrategyMigrated = true;
    }
    s.defaultsMigrated2103 = _storedBool(j, 'defaultsMigrated2103', false);
    if (!s.defaultsMigrated2103) {
      // One-time build-2103 migration (diagnosis D1/D3,
      // owner order 2026-11-18 — V2Ray defaults behave as
      // v2rayNG's, Ember extras OFF): ipv6Route and
      // sniffQuic shipped default-ON in every build ≤2102
      // and are written on every save, so a stored true is
      // the shipped default, not a discernible choice; both
      // move to OFF once. Placed here, after both fields
      // have been read above. The toggles stay in Settings;
      // a value set afterwards is kept. The AWG service no
      // longer reads ipv6Route (2103 decoupling), so this
      // cannot take a v6-only WireGuard profile's ::/0
      // route away.
      s.ipv6Route = false;
      s.sniffQuic = false;
      s.defaultsMigrated2103 = true;
      s.defaultsJustMigrated2103 = true;
    }
    s.defaultsReset2114 = _storedBool(j, 'defaultsReset2114', false);
    if (!s.defaultsReset2114) {
      // One-time build-2114 defaults reset (defaults audit
      // 2026-11-19; owner order — every Ember extra defaults
      // OFF, v2rayNG parity): adaptiveFailover (ON since
      // 2035), autoReconnect (ON since 2042), stallWatchdog
      // (ON since 2025, toggle 2095) and smartDialRacing (ON
      // since 2075) shipped default-ON and are written on
      // every save, so a stored true is the shipped default,
      // not a discernible choice; all four move to OFF once,
      // here, after all four fields have been read above. The
      // toggles stay in Settings; a value set afterwards is
      // kept. (The reset's other keys live elsewhere:
      // remoteDns landed in build 2113, the AppSettings pair
      // and the WarpProfile fragment carry their own flags.)
      s.adaptiveFailover = false;
      s.autoReconnect = false;
      s.stallWatchdog = false;
      s.smartDialRacing = false;
      s.defaultsReset2114 = true;
    }
    // Build 2103: the address-name heal's flag is only READ
    // here — the heal itself rewrites stored PROFILES,
    // which fromJson never sees; XrayController.load
    // performs it (healAddressDerivedNames) and persists
    // at once, like the fingerprint migration below.
    s.addressNameHealed2103 = _storedBool(j, 'addressNameHealed2103', false);
    // Build 2070: the fingerprint migration's flag is only READ
    // here — the migration itself rewrites stored PROFILES,
    // which fromJson never sees; XrayController.load performs it
    // (clearParserDefaultFingerprints) and persists at once.
    s.fingerprintDefaultMigrated =
        _storedBool(j, 'fingerprintDefaultMigrated', false);
    final preset = _storedStr(j, 'routingPreset', '');
    s.routingPreset = RoutingPreset.values.firstWhere(
      (p) => p.name == preset,
      orElse: () => RoutingPreset.global,
    );
    // Build 2054 (audit F-M16): an `is` check, not a cast —
    // a wrong-typed stored value reads as the fallback, never
    // throws the settings load.
    List<String> strings(String key, List<String> fallback) {
      final v = j[key];
      if (v is! List) return fallback;
      return v.map((e) => e.toString()).toList();
    }

    s.balancerGroupIds = strings('balancerGroupIds', []);
    s.sweepMissByProfile = _intMap(j['sweepMissByProfile']);
    s.sweepMissNetworkByProfile = _stringMap(
      j['sweepMissNetworkByProfile'],
    );
    s.customDirectDomains = strings('customDirectDomains', []);
    s.excludedCountries = strings(
      'excludedCountries',
      [],
    ).map((c) => c.toUpperCase()).where((c) => c.length == 2).toList();
    s.customDirectIps = strings('customDirectIps', []);
    s.customBlockDomains = strings('customBlockDomains', []);
    s.customProxyDomains = strings('customProxyDomains', []);
    s.subAutoUpdateHours = _storedInt(
      j,
      'subAutoUpdateHours',
      s.subAutoUpdateHours,
    );
    final cd = j['fallbackFailedAtMs'];
    if (cd is Map) {
      s.fallbackFailedAtMs = {
        for (final e in cd.entries)
          if (e.value is num) e.key.toString(): (e.value as num).toInt(),
      };
    }
    s.subUpdateOnLaunch = _storedBool(
      j,
      'subUpdateOnLaunch',
      s.subUpdateOnLaunch,
    );
    // Build 2126 (audit A26-26) defaults reset, the
    // 2125 pattern: subUpdateOnLaunch shipped default-ON
    // and is written on every save, so a stored ON is the
    // shipped default, not a discernible choice — it
    // moves to OFF exactly once. A value set afterwards
    // is kept.
    s.defaultsReset2126 = j['defaultsReset2126'] == true;
    if (!s.defaultsReset2126) {
      s.subUpdateOnLaunch = false;
      s.defaultsReset2126 = true;
    }
    // Build 2133: the loose group's ping summary; a
    // pre-2133 record has no keys and loads as never pinged.
    s.looseLastPingMs = _storedInt(j, 'looseLastPingMs', s.looseLastPingMs);
    s.looseBestPingName = _storedStr(
      j,
      'looseBestPingName',
      s.looseBestPingName,
    );
    s.looseBestPingMs = _storedInt(j, 'looseBestPingMs', s.looseBestPingMs);
    return s;
  }
}

/// The EmberWarp core's profile (build 2030): one WARP
/// connection profile, shaped after patterniha/Aether's
/// profile model (the RE dossier's field map), v1 subset.
/// Protocols are masque | wg | gool | mim — gool-classic is
/// deliberately not offered (mim joined in build 2129: the
/// Aether binary's own --protocol takes it, verified against
/// the shipped libaether.so's strings). The core is a subprocess; this
/// model only decides its command line (see warp_args.dart)
/// and, in chain mode, the exit-node's finalMask/dialMode.
///
/// Every read is defensive: a corrupt stored value falls back
/// to the field's default instead of throwing — the warp
/// section must open on any carried-over state.
class WarpProfile {
  WarpProfile();

  /// masque | wg | gool | mim.
  String protocol = 'masque';

  /// The MASQUE transport: h2 (HTTP/2 over TCP) or h3 (QUIC).
  /// H2 is the default (dossier Q5: H2 + fragment default,
  /// H2-only scan by default).
  String transport = 'h2';

  /// Gateway scan strategy: balanced | performance | random.
  String scan = 'balanced';

  /// Preferred endpoint family: v4 | v6 | dual.
  String ipVersion = 'v4';

  /// The MASQUE SNI (masque/gool/mim).
  String masqueSni = 'www.cloudflare.com';

  /// H2 first-flight fragmentation (masque over H2). Default
  /// ON until build 2114 (defaults reset): default OFF under
  /// the owner's blanket rule for EmberWarp extras; the
  /// defaultsReset2114 migration in fromJson below moves a
  /// stored true to OFF once. A value set afterwards is kept.
  bool fragment = false;

  /// Set once the build-2114 defaults reset has run on this
  /// profile: a stored fragment=true was the shipped default
  /// in every build ≤2113 (the profile is persisted whole on
  /// every save), so it moves to OFF exactly once. Same
  /// in-memory-true / stored-false-fallback doctrine as
  /// XraySettings' migration flags.
  bool defaultsReset2114 = true;

  /// In-tunnel DNS override ('' = the core default).
  String dns = '';

  /// Preferred exit location, an IATA-ish code ('' = any).
  String exitLoc = '';

  /// A pinned gateway "host:port" ('' = scan for one). A pin
  /// skips the scan on the core side.
  String peer = '';

  /// MASQUE obfuscation: auto | off | quic | http.
  String obfuscation = 'auto';

  /// Encrypted Client Hello for the gateway handshake. When
  /// on, the lookup resolver is ALWAYS an encrypted one (the
  /// dossier's ECH rule: never plain-UDP 1.1.1.1 — it is both
  /// poisonable and, on the owner's carrier, unreachable).
  bool ech = false;

  /// The ECH lookup resolver ('' = the encrypted default).
  String echDns = '';

  /// Chain mode only: the exit-node freedom outbound's
  /// finalmask JSON and dialMode — they live on the exit
  /// because that is the hop that really dials (dossier Q2).
  /// In standalone mode there is no Xray in front, so these
  /// two stay inert by design.
  String finalMask = '';
  String dialMode = '';

  static String _str(Map<String, dynamic> j, String key, String fallback) {
    final v = j[key];
    return v is String ? v : fallback;
  }

  static bool _bool(Map<String, dynamic> j, String key, bool fallback) {
    final v = j[key];
    return v is bool ? v : fallback;
  }

  static String _pick(String v, List<String> allowed, String fallback) =>
      allowed.contains(v) ? v : fallback;

  /// Copies every field from [other] (build 2095, whole-app
  /// journey audit #21): the settings page edits a copy and
  /// commits through this on Save, so an abandoned edit no
  /// longer leaks into the live profile.
  void absorb(WarpProfile other) {
    protocol = other.protocol;
    transport = other.transport;
    scan = other.scan;
    ipVersion = other.ipVersion;
    masqueSni = other.masqueSni;
    fragment = other.fragment;
    defaultsReset2114 = other.defaultsReset2114;
    dns = other.dns;
    exitLoc = other.exitLoc;
    peer = other.peer;
    obfuscation = other.obfuscation;
    ech = other.ech;
    echDns = other.echDns;
    finalMask = other.finalMask;
    dialMode = other.dialMode;
  }

  WarpProfile copy() => WarpProfile.fromJson(toJson());

  Map<String, dynamic> toJson() => {
    'protocol': protocol,
    'transport': transport,
    'scan': scan,
    'ipVersion': ipVersion,
    'masqueSni': masqueSni,
    'fragment': fragment,
    'defaultsReset2114': defaultsReset2114,
    'dns': dns,
    'exitLoc': exitLoc,
    'peer': peer,
    'obfuscation': obfuscation,
    'ech': ech,
    'echDns': echDns,
    'finalMask': finalMask,
    'dialMode': dialMode,
  };

  factory WarpProfile.fromJson(Map<String, dynamic> j) {
    final w = WarpProfile();
    w.protocol = _pick(_str(j, 'protocol', w.protocol), const [
      'masque',
      'wg',
      'gool',
      'mim',
    ], 'masque');
    w.transport = _pick(_str(j, 'transport', w.transport), const [
      'h2',
      'h3',
    ], 'h2');
    w.scan = _pick(_str(j, 'scan', w.scan), const [
      'balanced',
      'performance',
      'random',
    ], 'balanced');
    w.ipVersion = _pick(_str(j, 'ipVersion', w.ipVersion), const [
      'v4',
      'v6',
      'dual',
    ], 'v4');
    w.masqueSni = _str(j, 'masqueSni', w.masqueSni);
    w.fragment = _bool(j, 'fragment', w.fragment);
    w.defaultsReset2114 = _bool(j, 'defaultsReset2114', false);
    if (!w.defaultsReset2114) {
      // Build 2114 defaults reset: the shipped default was
      // true, so a stored true is not a discernible choice.
      w.fragment = false;
      w.defaultsReset2114 = true;
    }
    w.dns = _str(j, 'dns', w.dns);
    w.exitLoc = _str(j, 'exitLoc', w.exitLoc);
    w.peer = _str(j, 'peer', w.peer);
    w.obfuscation = _pick(_str(j, 'obfuscation', w.obfuscation), const [
      'auto',
      'off',
      'quic',
      'http',
    ], 'auto');
    w.ech = _bool(j, 'ech', w.ech);
    w.echDns = _str(j, 'echDns', w.echDns);
    w.finalMask = _str(j, 'finalMask', w.finalMask);
    w.dialMode = _str(j, 'dialMode', w.dialMode);
    return w;
  }
}
