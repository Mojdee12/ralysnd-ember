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
  socks
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
      };

  /// Xray-core serves every protocol here except TUIC, which it has
  /// no outbound for; SOCKS is a native Xray outbound.
  bool get supportedByCore => this != Protocol.tuic;
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

  /// TUIC.
  String congestionControl;
  String udpRelayMode;

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
    this.congestionControl = '',
    this.udpRelayMode = '',
    this.subscriptionId = '',
    this.delayMs = -1,
    this.delayFailed = false,
    this.totalDownBytes = 0,
    this.totalUpBytes = 0,
    this.statsUpdatedMs = 0,
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
        'congestionControl': congestionControl,
        'udpRelayMode': udpRelayMode,
        'subscriptionId': subscriptionId,
        'delayMs': delayMs,
        'delayFailed': delayFailed,
        'totalDown': totalDownBytes,
        'totalUp': totalUpBytes,
        'statsUpdatedMs': statsUpdatedMs,
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
        congestionControl: j['congestionControl'] as String? ?? '',
        udpRelayMode: j['udpRelayMode'] as String? ?? '',
        subscriptionId: j['subscriptionId'] as String? ?? '',
        delayMs: (j['delayMs'] as num?)?.toInt() ?? -1,
        delayFailed: j['delayFailed'] as bool? ?? false,
        totalDownBytes: (j['totalDown'] as num?)?.toInt() ?? 0,
        totalUpBytes: (j['totalUp'] as num?)?.toInt() ?? 0,
        statsUpdatedMs: (j['statsUpdatedMs'] as num?)?.toInt() ?? 0,
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

  /// The resolver proxied traffic uses, reached through the tunnel.
  /// Default aligned with v2rayNG's generated configs (2005): its
  /// remote DNS is dns.google's DoH. Before 2005 the default was
  /// 1.1.1.1's DoH; a stored old default is migrated once (see
  /// [XraySettings.fromJson]).
  String remoteDns = 'https://dns.google/dns-query';

  /// Set once the 2005 remote-DNS default migration has run, so a
  /// user who later re-enters the old value on purpose keeps it.
  bool remoteDnsMigrated = false;
  int socksPort = 10808;
  int httpPort = 10809;
  bool sniffing = true;
  bool fakeDns = false;
  bool muxEnabled = false;
  int muxConcurrency = 8;
  bool fragmentEnabled = false;
  String fragmentPackets = 'tlshello';
  int fragmentLength = 100;
  int fragmentInterval = 10;
  bool ipv6Route = true;
  String domainStrategy = 'IPIfNonMatch';
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
        'localDns': localDns,
        'remoteDns': remoteDns,
        'remoteDnsMigrated': remoteDnsMigrated,
        'socksPort': socksPort,
        'httpPort': httpPort,
        'sniffing': sniffing,
        'fakeDns': fakeDns,
        'muxEnabled': muxEnabled,
        'muxConcurrency': muxConcurrency,
        'fragmentEnabled': fragmentEnabled,
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
    s.localDns = j['localDns'] as String? ?? s.localDns;
    s.remoteDns = j['remoteDns'] as String? ?? s.remoteDns;
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
    s.muxConcurrency = (j['muxConcurrency'] as num?)?.toInt() ?? s.muxConcurrency;
    s.fragmentEnabled = j['fragmentEnabled'] as bool? ?? s.fragmentEnabled;
    s.fragmentPackets = j['fragmentPackets'] as String? ?? s.fragmentPackets;
    s.fragmentLength = (j['fragmentLength'] as num?)?.toInt() ?? s.fragmentLength;
    s.fragmentInterval = (j['fragmentInterval'] as num?)?.toInt() ?? s.fragmentInterval;
    s.ipv6Route = j['ipv6Route'] as bool? ?? s.ipv6Route;
    s.domainStrategy = j['domainStrategy'] as String? ?? s.domainStrategy;
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
    s.subAutoUpdateHours = (j['subAutoUpdateHours'] as num?)?.toInt() ?? s.subAutoUpdateHours;
    s.subUpdateOnLaunch = j['subUpdateOnLaunch'] as bool? ?? s.subUpdateOnLaunch;
    return s;
  }
}
