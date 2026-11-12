/// Data model of the V2Ray (Xray) engine: the configs the user keeps,
/// the subscriptions they came from, and the engine's settings. Ported
/// from the Ralysnd V2Ray client's Kotlin model, extended with
/// Hysteria2, WireGuard and TUIC profiles.

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
  };

  /// Xray-core serves every protocol here except TUIC and AnyTLS,
  /// which it has no outbound for (both verified in the bundled
  /// fork's source, build 2033 for AnyTLS); SOCKS is a native
  /// Xray outbound. Unsupported protocols are parsed, stored and
  /// shareable, and refuse to connect with an explanation.
  bool get supportedByCore =>
      this != Protocol.tuic && this != Protocol.anytls;
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
  bool allowInsecure;

  /// Shadowsocks 2022 / plugin.
  String plugin;

  /// WireGuard.
  String secretKey;
  String peerPublicKey;
  String preSharedKey;
  String localAddress;
  String reserved;
  int mtu;
  int keepAlive;

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
  /// import keeps them, export writes them back — but Ember's
  /// WireGuard carrier (the Xray outbound) cannot apply them:
  /// a profile carrying them runs as plain WireGuard and is
  /// badged as such. '' = the parameter was not present.
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
    this.allowInsecure = false,
    this.plugin = '',
    this.secretKey = '',
    this.peerPublicKey = '',
    this.preSharedKey = '',
    this.localAddress = '',
    this.reserved = '',
    this.mtu = 1420,
    this.keepAlive = 0,
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
    'allowInsecure': allowInsecure,
    'plugin': plugin,
    'secretKey': secretKey,
    'peerPublicKey': peerPublicKey,
    'preSharedKey': preSharedKey,
    'localAddress': localAddress,
    'reserved': reserved,
    'mtu': mtu,
    'keepAlive': keepAlive,
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
  };

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    protocol: Protocol.values.firstWhere(
      (p) => p.name == (j['protocol'] as String? ?? 'vless'),
      orElse: () => Protocol.vless,
    ),
    address: j['address'] as String? ?? '',
    port: (j['port'] as num?)?.toInt() ?? 443,
    uuidOrPassword: j['uuidOrPassword'] as String? ?? '',
    method: j['method'] as String? ?? '',
    username: j['username'] as String? ?? '',
    network: j['network'] as String? ?? 'tcp',
    headerType: j['headerType'] as String? ?? '',
    host: j['host'] as String? ?? '',
    path: j['path'] as String? ?? '',
    serviceName: j['serviceName'] as String? ?? '',
    mode: j['mode'] as String? ?? '',
    security: j['security'] as String? ?? '',
    sni: j['sni'] as String? ?? '',
    alpn: j['alpn'] as String? ?? '',
    fingerprint: j['fingerprint'] as String? ?? '',
    cipherSuites: j['cipherSuites'] as String? ?? '',
    dialMode: j['dialMode'] as String? ?? '',
    finalMask: j['finalMask'] as String? ?? '',
    publicKey: j['publicKey'] as String? ?? '',
    shortId: j['shortId'] as String? ?? '',
    spiderX: j['spiderX'] as String? ?? '',
    flow: j['flow'] as String? ?? '',
    allowInsecure: j['allowInsecure'] as bool? ?? false,
    plugin: j['plugin'] as String? ?? '',
    secretKey: j['secretKey'] as String? ?? '',
    peerPublicKey: j['peerPublicKey'] as String? ?? '',
    preSharedKey: j['preSharedKey'] as String? ?? '',
    localAddress: j['localAddress'] as String? ?? '',
    reserved: j['reserved'] as String? ?? '',
    mtu: (j['mtu'] as num?)?.toInt() ?? 1420,
    keepAlive: (j['keepAlive'] as num?)?.toInt() ?? 0,
    obfs: j['obfs'] as String? ?? '',
    obfsPassword: j['obfsPassword'] as String? ?? '',
    upMbps: (j['upMbps'] as num?)?.toInt() ?? 0,
    downMbps: (j['downMbps'] as num?)?.toInt() ?? 0,
    hyCongestion: j['hyCongestion'] as String? ?? '',
    echConfigList: j['echConfigList'] as String? ?? '',
    awgJc: j['awgJc'] as String? ?? '',
    awgJmin: j['awgJmin'] as String? ?? '',
    awgJmax: j['awgJmax'] as String? ?? '',
    awgS1: j['awgS1'] as String? ?? '',
    awgS2: j['awgS2'] as String? ?? '',
    awgH1: j['awgH1'] as String? ?? '',
    awgH2: j['awgH2'] as String? ?? '',
    awgH3: j['awgH3'] as String? ?? '',
    awgH4: j['awgH4'] as String? ?? '',
    congestionControl: j['congestionControl'] as String? ?? '',
    udpRelayMode: j['udpRelayMode'] as String? ?? '',
    afUnfilter: j['afUnfilter'] as bool? ?? false,
    afEch: j['afEch'] as bool? ?? false,
    afFragment: j['afFragment'] as String? ?? '',
    afMixedSni: j['afMixedSni'] as bool? ?? false,
    afTcpNoise: j['afTcpNoise'] as bool? ?? false,
    subscriptionId: j['subscriptionId'] as String? ?? '',
    delayMs: (j['delayMs'] as num?)?.toInt() ?? -1,
    delayFailed: j['delayFailed'] as bool? ?? false,
    totalDownBytes: (j['totalDown'] as num?)?.toInt() ?? 0,
    totalUpBytes: (j['totalUp'] as num?)?.toInt() ?? 0,
    statsUpdatedMs: (j['statsUpdatedMs'] as num?)?.toInt() ?? 0,
    exitIp: j['exitIp'] as String? ?? '',
    exitCountryCode: j['exitCountryCode'] as String? ?? '',
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
  };

  factory Subscription.fromJson(Map<String, dynamic> j) => Subscription(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    url: j['url'] as String? ?? '',
    uploadBytes: (j['uploadBytes'] as num?)?.toInt() ?? 0,
    downloadBytes: (j['downloadBytes'] as num?)?.toInt() ?? 0,
    totalBytes: (j['totalBytes'] as num?)?.toInt() ?? 0,
    expireEpochSec: (j['expireEpochSec'] as num?)?.toInt() ?? 0,
    lastUpdatedMs: (j['lastUpdatedMs'] as num?)?.toInt() ?? 0,
    profileCount: (j['profileCount'] as num?)?.toInt() ?? 0,
    autoUpdate: j['autoUpdate'] as bool? ?? true,
  );
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

class XraySettings {
  XraySettings();

  bool allowInsecure = false;
  bool enableUdp = true;
  String localDns = '1.1.1.1';

  /// Desktop only (Windows port, kept from the 2.1.0 tree):
  /// capture the whole system through the TUN service (true),
  /// or serve only the local proxies (false — proxy mode). The
  /// Windows backend's mode choice; Android always runs its
  /// VpnService in VPN mode and ignores this.
  bool tunCapture = true;

  /// Set once the 2.0.5 tunCapture migration has run (see fromJson).
  bool tunCaptureMigrated = false;

  /// The resolver proxied traffic uses, reached through the tunnel.
  /// Default aligned with v2rayNG's generated configs (2005): its
  /// remote DNS is dns.google's DoH. Before 2005 the default was
  /// 1.1.1.1's DoH; a stored old default is migrated once (see
  /// [XraySettings.fromJson]).
  String remoteDns = 'https://dns.google/dns-query';

  /// The remote resolver's transport (build 2032): 'doh' (the
  /// [remoteDns] URL as-is) or 'doq' — DNS-over-QUIC to the same
  /// provider (see config_builder's DoQ mapping; the core speaks
  /// quic:// nameservers). 'tcp' (build 2037, Iran-priority queue
  /// 2e) — DNS over TCP to the provider's pinned IP (see
  /// config_builder's TCP mapping; the core speaks tcp://
  /// nameservers, RFC 7766): it survives UDP poisoning and needs
  /// no hostname or SNI. DoH stays the default; an unrecognised
  /// stored value falls back to DoH in the builder.
  String remoteDnsProto = 'doh';

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
  int socksPort = 10808;
  int httpPort = 10809;
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
  /// 'warp' (build 2030). When set, a V2Ray session starts the
  /// underlay core first and the Xray outbound dials THROUGH
  /// it (dialerProxy) — V2Ray over Psiphon, or V2Ray over the
  /// EmberWarp core. Global, not per-profile.
  String underlay = 'none';

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
  bool subUpdateOnLaunch = true;

  Map<String, dynamic> toJson() => {
    'allowInsecure': allowInsecure,
    'enableUdp': enableUdp,
    'tunCapture': tunCapture,
    'tunCaptureMigrated': tunCaptureMigrated,
    'localDns': localDns,
    'remoteDns': remoteDns,
    'remoteDnsProto': remoteDnsProto,
    'testAllConcurrency': testAllConcurrency,
    'remoteDnsMigrated': remoteDnsMigrated,
    'domainStrategyMigrated': domainStrategyMigrated,
    'socksPort': socksPort,
    'httpPort': httpPort,
    'sniffing': sniffing,
    'fakeDns': fakeDns,
    'muxEnabled': muxEnabled,
    'muxConcurrency': muxConcurrency,
    'fragmentEnabled': fragmentEnabled,
    'adaptiveFailover': adaptiveFailover,
    'underlay': underlay,
    'adBlockDoh': adBlockDoh,
    'dnsFallback': dnsFallback,
    'fallbackDns': fallbackDns,
    'dnsGroup': dnsGroup,
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
    'subUpdateOnLaunch': subUpdateOnLaunch,
  };

  factory XraySettings.fromJson(Map<String, dynamic> j) {
    final s = XraySettings();
    s.allowInsecure = j['allowInsecure'] as bool? ?? s.allowInsecure;
    s.enableUdp = j['enableUdp'] as bool? ?? s.enableUdp;
    s.tunCapture = j['tunCapture'] as bool? ?? s.tunCapture;
    s.tunCaptureMigrated = j['tunCaptureMigrated'] as bool? ?? false;
    if (!s.tunCaptureMigrated) {
      // One-time 2.0.5 migration (Windows tree): through the
      // broken-capture era (2.0.0–2.0.4) a stored false here left
      // the app "connected" in proxy mode with no system capture
      // and nothing saying so. Turn capture ON once; the flag is
      // persisted on the next save, and the Settings toggle stays
      // fully effective afterwards.
      s.tunCapture = true;
      s.tunCaptureMigrated = true;
    }
    s.localDns = j['localDns'] as String? ?? s.localDns;
    s.remoteDns = j['remoteDns'] as String? ?? s.remoteDns;
    s.remoteDnsProto = j['remoteDnsProto'] as String? ?? s.remoteDnsProto;
    s.testAllConcurrency =
        (j['testAllConcurrency'] as num?)?.toInt() ?? s.testAllConcurrency;
    s.remoteDnsMigrated = j['remoteDnsMigrated'] as bool? ?? false;
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
    s.socksPort = (j['socksPort'] as num?)?.toInt() ?? s.socksPort;
    s.httpPort = (j['httpPort'] as num?)?.toInt() ?? s.httpPort;
    s.sniffing = j['sniffing'] as bool? ?? s.sniffing;
    s.fakeDns = j['fakeDns'] as bool? ?? s.fakeDns;
    s.muxEnabled = j['muxEnabled'] as bool? ?? s.muxEnabled;
    s.muxConcurrency =
        (j['muxConcurrency'] as num?)?.toInt() ?? s.muxConcurrency;
    s.fragmentEnabled = j['fragmentEnabled'] as bool? ?? s.fragmentEnabled;
    s.adaptiveFailover = j['adaptiveFailover'] as bool? ?? s.adaptiveFailover;
    // Only the known underlays survive a store read; anything
    // else (a corrupt or future value) reads as 'none' rather
    // than chaining a session through a phantom underlay. No
    // cast: a corrupt store may hold any type here.
    s.underlay = switch (j['underlay']) {
      'psiphon' => 'psiphon',
      'warp' => 'warp',
      _ => 'none',
    };
    s.adBlockDoh = j['adBlockDoh'] as bool? ?? s.adBlockDoh;
    s.dnsFallback = j['dnsFallback'] as bool? ?? s.dnsFallback;
    s.fallbackDns = j['fallbackDns'] as String? ?? s.fallbackDns;
    s.dnsGroup = j['dnsGroup'] as bool? ?? s.dnsGroup;
    s.fragmentPackets = j['fragmentPackets'] as String? ?? s.fragmentPackets;
    s.fragmentLength =
        (j['fragmentLength'] as num?)?.toInt() ?? s.fragmentLength;
    s.fragmentInterval =
        (j['fragmentInterval'] as num?)?.toInt() ?? s.fragmentInterval;
    s.ipv6Route = j['ipv6Route'] as bool? ?? s.ipv6Route;
    s.domainStrategy = j['domainStrategy'] as String? ?? s.domainStrategy;
    s.domainStrategyMigrated = j['domainStrategyMigrated'] as bool? ?? false;
    if (!s.domainStrategyMigrated) {
      // One-time 2024 migration, same shape as the 2005 remote-DNS
      // one: a stored value equal to the old default was never a
      // deliberate choice, so move it to v2rayNG's 'AsIs'.
      if (s.domainStrategy == 'IPIfNonMatch') {
        s.domainStrategy = 'AsIs';
      }
      s.domainStrategyMigrated = true;
    }
    final preset = j['routingPreset'] as String? ?? '';
    s.routingPreset = RoutingPreset.values.firstWhere(
      (p) => p.name == preset,
      orElse: () => RoutingPreset.global,
    );
    List<String> strings(String key, List<String> fallback) =>
        (j[key] as List?)?.map((e) => e.toString()).toList() ?? fallback;
    s.customDirectDomains = strings('customDirectDomains', []);
    s.customDirectIps = strings('customDirectIps', []);
    s.customBlockDomains = strings('customBlockDomains', []);
    s.customProxyDomains = strings('customProxyDomains', []);
    s.subAutoUpdateHours =
        (j['subAutoUpdateHours'] as num?)?.toInt() ?? s.subAutoUpdateHours;
    s.subUpdateOnLaunch =
        j['subUpdateOnLaunch'] as bool? ?? s.subUpdateOnLaunch;
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
    w.protocol = _pick(
      _str(j, 'protocol', w.protocol),
      const ['masque', 'wg', 'gool'],
      'masque',
    );
    w.transport = _pick(
      _str(j, 'transport', w.transport),
      const ['h2', 'h3'],
      'h2',
    );
    w.scan = _pick(
      _str(j, 'scan', w.scan),
      const ['balanced', 'performance', 'random'],
      'balanced',
    );
    w.ipVersion = _pick(
      _str(j, 'ipVersion', w.ipVersion),
      const ['v4', 'v6', 'dual'],
      'v4',
    );
    w.masqueSni = _str(j, 'masqueSni', w.masqueSni);
    w.fragment = _bool(j, 'fragment', w.fragment);
    w.dns = _str(j, 'dns', w.dns);
    w.exitLoc = _str(j, 'exitLoc', w.exitLoc);
    w.peer = _str(j, 'peer', w.peer);
    w.obfuscation = _pick(
      _str(j, 'obfuscation', w.obfuscation),
      const ['auto', 'off', 'quic', 'http'],
      'auto',
    );
    w.ech = _bool(j, 'ech', w.ech);
    w.echDns = _str(j, 'echDns', w.echDns);
    w.finalMask = _str(j, 'finalMask', w.finalMask);
    w.dialMode = _str(j, 'dialMode', w.dialMode);
    return w;
  }
}

/// The auto-sort rank of a profile by its last delay test:
/// measured first (0), never-measured next (1), failed last (2).
/// (Windows tree, 2.0.7 — the FROZEN ping auto-sort rule: the
/// desktop V2Ray list orders itself fastest-first after a test
/// run, and these helpers are pinned by delay_sort_test.dart.
/// The Android port kept the same fields on [Profile]; the
/// helpers themselves live here so both the desktop pages and
/// the tests keep the exact 2.1.0 behaviour.)
int delaySortRank(Profile p) =>
    p.delayFailed ? 2 : (p.delayMs >= 0 ? 0 : 1);

/// A STABLE fastest-first ordering of [profiles]: measured delays
/// ascending, then unmeasured profiles, then failed ones; profiles
/// that compare equal keep their previous relative order (Dart's
/// List.sort is not stable, so the original index breaks ties).
/// Returns a new list; the input is not modified.
List<Profile> sortedByDelay(List<Profile> profiles) {
  final decorated = [
    for (var i = 0; i < profiles.length; i++) (i, profiles[i]),
  ];
  decorated.sort((a, b) {
    final ra = delaySortRank(a.$2);
    final rb = delaySortRank(b.$2);
    if (ra != rb) return ra.compareTo(rb);
    if (ra == 0) {
      final byDelay = a.$2.delayMs.compareTo(b.$2.delayMs);
      if (byDelay != 0) return byDelay;
    }
    return a.$1.compareTo(b.$1);
  });
  return [for (final d in decorated) d.$2];
}
