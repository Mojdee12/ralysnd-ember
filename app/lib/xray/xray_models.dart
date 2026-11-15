/// Data model of the V2Ray (Xray) engine: the configs the user keeps,
/// the subscriptions they came from, and the engine's settings. Ported
/// from the Ralysnd V2Ray client's Kotlin model, extended with
/// Hysteria2, WireGuard and TUIC profiles.

import 'dns_hosts.dart';

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
  };

  /// Xray-core serves every protocol here except TUIC and AnyTLS,
  /// which it has no outbound for (both verified in the bundled
  /// fork's source, build 2033 for AnyTLS); SOCKS is a native
  /// Xray outbound. Unsupported protocols are parsed, stored and
  /// shareable, and refuse to connect with an explanation.
  bool get supportedByCore => this != Protocol.tuic && this != Protocol.anytls;
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

int _storedInt(Map<String, dynamic> j, String key, int fallback) {
  final v = j[key];
  return v is num ? v.toInt() : fallback;
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
  /// security. The core removed `allowInsecure` outright (build
  /// 2048 dropped the toggle and the field entirely) and names the
  /// pin as its replacement — Ember never emits that key.
  String tlsCertPin;

  bool get hasTlsCertPin => tlsCertPin.isNotEmpty;

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

  /// Hysteria2.
  String obfs;
  String obfsPassword;
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
  /// engine (libwg-go.so), which runs a profile carrying them
  /// obfuscated; a peer the obfuscated tunnel cannot reach
  /// falls back to plain WireGuard through Xray. '' = the
  /// parameter was not present.
  String awgJc;
  String awgJmin;
  String awgJmax;
  String awgS1;
  String awgS2;
  String awgH1;
  String awgH2;
  String awgH3;
  String awgH4;

  /// True when this profile carries any AmneziaWG parameter.
  bool get hasAmneziaParams =>
      awgJc.isNotEmpty ||
      awgJmin.isNotEmpty ||
      awgJmax.isNotEmpty ||
      awgS1.isNotEmpty ||
      awgS2.isNotEmpty ||
      awgH1.isNotEmpty ||
      awgH2.isNotEmpty ||
      awgH3.isNotEmpty ||
      awgH4.isNotEmpty;

  /// TUIC.
  String congestionControl;
  String udpRelayMode;

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
  String get displayName => localName.isNotEmpty ? localName : name;

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
    this.obfs = '',
    this.obfsPassword = '',
    this.upMbps = 0,
    this.downMbps = 0,
    this.hyCongestion = '',
    this.echConfigList = '',
    this.awgJc = '',
    this.awgJmin = '',
    this.awgJmax = '',
    this.awgS1 = '',
    this.awgS2 = '',
    this.awgH1 = '',
    this.awgH2 = '',
    this.awgH3 = '',
    this.awgH4 = '',
    this.congestionControl = '',
    this.udpRelayMode = '',
    this.afUnfilter = false,
    this.afEch = false,
    this.afFragment = '',
    this.afMixedSni = false,
    this.afTcpNoise = false,
    this.subscriptionId = '',
    this.delayMs = -1,
    this.delayFailed = false,
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
    'obfs': obfs,
    'obfsPassword': obfsPassword,
    'upMbps': upMbps,
    'downMbps': downMbps,
    'hyCongestion': hyCongestion,
    'echConfigList': echConfigList,
    'awgJc': awgJc,
    'awgJmin': awgJmin,
    'awgJmax': awgJmax,
    'awgS1': awgS1,
    'awgS2': awgS2,
    'awgH1': awgH1,
    'awgH2': awgH2,
    'awgH3': awgH3,
    'awgH4': awgH4,
    'congestionControl': congestionControl,
    'udpRelayMode': udpRelayMode,
    'afUnfilter': afUnfilter,
    'afEch': afEch,
    'afFragment': afFragment,
    'afMixedSni': afMixedSni,
    'afTcpNoise': afTcpNoise,
    'subscriptionId': subscriptionId,
    'delayMs': delayMs,
    'delayFailed': delayFailed,
    'totalDown': totalDownBytes,
    'totalUp': totalUpBytes,
    'statsUpdatedMs': statsUpdatedMs,
    'exitIp': exitIp,
    'exitCountryCode': exitCountryCode,
    'starred': starred,
    'localName': localName,
  };

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
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
    obfs: _storedStr(j, 'obfs', ''),
    obfsPassword: _storedStr(j, 'obfsPassword', ''),
    upMbps: _storedInt(j, 'upMbps', 0),
    downMbps: _storedInt(j, 'downMbps', 0),
    hyCongestion: _storedStr(j, 'hyCongestion', ''),
    echConfigList: _storedStr(j, 'echConfigList', ''),
    awgJc: _storedStr(j, 'awgJc', ''),
    awgJmin: _storedStr(j, 'awgJmin', ''),
    awgJmax: _storedStr(j, 'awgJmax', ''),
    awgS1: _storedStr(j, 'awgS1', ''),
    awgS2: _storedStr(j, 'awgS2', ''),
    awgH1: _storedStr(j, 'awgH1', ''),
    awgH2: _storedStr(j, 'awgH2', ''),
    awgH3: _storedStr(j, 'awgH3', ''),
    awgH4: _storedStr(j, 'awgH4', ''),
    congestionControl: _storedStr(j, 'congestionControl', ''),
    udpRelayMode: _storedStr(j, 'udpRelayMode', ''),
    afUnfilter: _storedBool(j, 'afUnfilter', false),
    afEch: _storedBool(j, 'afEch', false),
    afFragment: _storedStr(j, 'afFragment', ''),
    afMixedSni: _storedBool(j, 'afMixedSni', false),
    afTcpNoise: _storedBool(j, 'afTcpNoise', false),
    subscriptionId: _storedStr(j, 'subscriptionId', ''),
    delayMs: _storedInt(j, 'delayMs', -1),
    delayFailed: _storedBool(j, 'delayFailed', false),
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
    localName: _storedStr(j, 'localName', ''),
  );
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

  /// Arbitrary extra request headers this panel requires,
  /// sent on every fetch and refresh (build 2051, F-H13
  /// remainder — the map 2050 left out: HWID and the
  /// fallback URL shipped then, but a panel asking for any
  /// other header had no field to put it in). {} = none.
  /// `User-Agent` can never appear here: the app fixes its
  /// own UA (see [parseCustomHeaders] in sub_fetcher.dart).
  Map<String, String> customHeaders;

  Subscription({
    required this.id,
    this.name = '',
    this.url = '',
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    this.totalBytes = 0,
    this.expireEpochSec = 0,
    this.lastUpdatedMs = 0,
    this.profileCount = 0,
    this.autoUpdate = true,
    this.certPin = '',
    this.hwid = '',
    this.fallbackUrl = '',
    this.customHeaders = const {},
  });

  int get usedBytes => uploadBytes + downloadBytes;

  int get remainingBytes => totalBytes > 0 ? totalBytes - usedBytes : -1;

  double get usedFraction =>
      totalBytes > 0 ? (usedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  int get remainingDays {
    if (expireEpochSec <= 0) return -1;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final d = (expireEpochSec - now) / 86400;
    return d < 0 ? 0 : d.ceil();
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
    'profileCount': profileCount,
    'autoUpdate': autoUpdate,
    'certPin': certPin,
    'hwid': hwid,
    'fallbackUrl': fallbackUrl,
    'customHeaders': customHeaders,
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
    profileCount: _storedInt(j, 'profileCount', 0),
    autoUpdate: _storedBool(j, 'autoUpdate', true),
    // Build 2050: `is`-check reads, like the rest of the store —
    // a wrong-typed legacy value yields '', never a throw.
    certPin: _storedStr(j, 'certPin', ''),
    hwid: _storedStr(j, 'hwid', ''),
    fallbackUrl: _storedStr(j, 'fallbackUrl', ''),
    // Build 2051: the same tolerance for the headers map — a
    // wrong-typed or partly-bad stored value yields the good
    // string entries only, never a throw; a 2050-era record
    // (no key) loads with no headers.
    customHeaders: _stringMap(j['customHeaders']),
  );
}

/// Reads a stored string map tolerantly (build 2051): only
/// String→String entries survive; anything else yields {}.
Map<String, String> _stringMap(Object? v) {
  if (v is! Map) return {};
  final out = <String, String>{};
  for (final e in v.entries) {
    if (e.key is String && e.value is String)
      out[e.key as String] = e.value as String;
  }
  return out;
}

/// The user's routing preset for the Xray tunnel.
enum RoutingPreset { global, bypassLan, bypassIran, directAll }

extension RoutingPresetLabel on RoutingPreset {
  String get name => switch (this) {
    RoutingPreset.global => 'global',
    RoutingPreset.bypassLan => 'bypass-lan',
    RoutingPreset.bypassIran => 'bypass-iran',
    RoutingPreset.directAll => 'direct-all',
  };
}

/// The loopback ports other Ember engines already own (build
/// 2057, audit F-M2): a user-editable Xray port must never land
/// on one of these, or the core refuses the config at connect
/// and the failure surfaces only as a generic start failure.
/// Psiphon 11808/11809, the delay-test range 11080–11260, the
/// Lantern/Aether/Warp ports 20810, 20840/41, 20850–20854, 20870.
const _xrayReservedPorts = <int>{
  11808,
  11809,
  20810,
  20840,
  20841,
  20850,
  20851,
  20852,
  20853,
  20854,
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
int clearParserDefaultFingerprints(List<Profile> profiles) {
  var cleared = 0;
  for (final p in profiles) {
    if (p.protocol == Protocol.vless &&
        (p.security == 'tls' || p.security == 'reality') &&
        p.fingerprint == 'chrome') {
      p.fingerprint = '';
      cleared++;
    }
  }
  return cleared;
}

class XraySettings {
  XraySettings();

  bool enableUdp = true;
  String localDns = '1.1.1.1';

  /// The resolver proxied traffic uses, reached through the tunnel.
  /// Default aligned with v2rayNG's generated configs (2005): its
  /// remote DNS is dns.google's DoH. Before 2005 the default was
  /// 1.1.1.1's DoH; a stored old default is migrated once (see
  /// [XraySettings.fromJson]).
  String remoteDns = 'https://dns.google/dns-query';

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
  int testAllConcurrency = 4;

  /// Set once the 2005 remote-DNS default migration has run, so a
  /// user who later re-enters the old value on purpose keeps it.
  bool remoteDnsMigrated = false;

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
  /// so. Default ON since build 2035: a stored value (on or off)
  /// is always respected, so only a user who never touched the
  /// setting gets the new default.
  bool adaptiveFailover = true;

  /// The chain underlay (build 2029A): 'none', 'psiphon' or
  /// 'warp' (build 2030); 'dnstt' added in build 2072. When
  /// set, a V2Ray session starts the underlay core first and
  /// the Xray outbound dials THROUGH it (dialerProxy) —
  /// V2Ray over Psiphon, over the EmberWarp core, or over a
  /// DNSTT DNS tunnel. Global, not per-profile.
  String underlay = 'none';

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
  bool autoReconnect = true;

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
  bool ipv6Route = true;

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
  bool subUpdateOnLaunch = true;

  Map<String, dynamic> toJson() => {
    'enableUdp': enableUdp,
    'localDns': localDns,
    'remoteDns': remoteDns,
    'remoteDnsProto': remoteDnsProto,
    'tunnelMtu': tunnelMtu,
    'testAllConcurrency': testAllConcurrency,
    'remoteDnsMigrated': remoteDnsMigrated,
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
    'lanShareEnabled': lanShareEnabled,
    'lanShareAuth': lanShareAuth,
    'lanShareUser': lanShareUser,
    'lanSharePass': lanSharePass,
    'sniffing': sniffing,
    'fakeDns': fakeDns,
    'muxEnabled': muxEnabled,
    'muxConcurrency': muxConcurrency,
    'fragmentEnabled': fragmentEnabled,
    'adaptiveFailover': adaptiveFailover,
    'underlay': underlay,
    'dnsttResolverType': dnsttResolverType,
    'dnsttResolver': dnsttResolver,
    'dnsttDomain': dnsttDomain,
    'dnsttPubkey': dnsttPubkey,
    'wgWstunnel': wgWstunnel,
    'wgWstunnelUrl': wgWstunnelUrl,
    'adBlockDoh': adBlockDoh,
    'dnsFallback': dnsFallback,
    'fallbackDns': fallbackDns,
    'dnsGroup': dnsGroup,
    'customDnsHosts': customDnsHosts,
    'configMixins': configMixins,
    'autoReconnect': autoReconnect,
    'killSwitch': killSwitch,
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
      _ => 'none',
    };
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
    s.wgWstunnel = _storedBool(j, 'wgWstunnel', s.wgWstunnel);
    s.wgWstunnelUrl = _storedStr(j, 'wgWstunnelUrl', s.wgWstunnelUrl);
    s.adBlockDoh = _storedBool(j, 'adBlockDoh', s.adBlockDoh);
    s.dnsFallback = _storedBool(j, 'dnsFallback', s.dnsFallback);
    s.fallbackDns = _storedStr(j, 'fallbackDns', s.fallbackDns);
    s.dnsGroup = _storedBool(j, 'dnsGroup', s.dnsGroup);
    s.autoReconnect = _storedBool(j, 'autoReconnect', s.autoReconnect);
    s.killSwitch = _storedBool(j, 'killSwitch', s.killSwitch);
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

    s.customDirectDomains = strings('customDirectDomains', []);
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
    return s;
  }
}

/// The EmberWarp core's profile (build 2030): one WARP
/// connection profile, shaped after patterniha/Aether's
/// profile model (the RE dossier's field map), v1 subset.
/// Protocols are masque | wg | gool — gool-classic and mim are
/// deliberately not offered. The core is a subprocess; this
/// model only decides its command line (see warp_args.dart)
/// and, in chain mode, the exit-node's finalMask/dialMode.
///
/// Every read is defensive: a corrupt stored value falls back
/// to the field's default instead of throwing — the warp
/// section must open on any carried-over state.
class WarpProfile {
  WarpProfile();

  /// masque | wg | gool.
  String protocol = 'masque';

  /// The MASQUE transport: h2 (HTTP/2 over TCP) or h3 (QUIC).
  /// H2 is the default (dossier Q5: H2 + fragment default,
  /// H2-only scan by default).
  String transport = 'h2';

  /// Gateway scan strategy: balanced | performance | random.
  String scan = 'balanced';

  /// Preferred endpoint family: v4 | v6 | dual.
  String ipVersion = 'v4';

  /// The MASQUE SNI (masque/gool).
  String masqueSni = 'www.cloudflare.com';

  /// H2 first-flight fragmentation (masque over H2).
  bool fragment = true;

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

  Map<String, dynamic> toJson() => {
    'protocol': protocol,
    'transport': transport,
    'scan': scan,
    'ipVersion': ipVersion,
    'masqueSni': masqueSni,
    'fragment': fragment,
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
