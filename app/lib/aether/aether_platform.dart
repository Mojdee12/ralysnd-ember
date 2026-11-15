import 'package:flutter/services.dart';

/// The ralysnd Aether engines (build 2032): the owner's own
/// binary (libaether.so) taken as it is from the ralysnd app,
/// driven by the Kotlin AetherCore shim. Two slots:
///  - cfwarp: standalone WARP (WireGuard protocol), SOCKS 20870;
///  - masque: MASQUE / WireGuard / WARP-in-WARP, SOCKS 20810.
/// Stage names are the binary's own vocabulary, parsed natively
/// (the port of ralysnd's stage parser); nothing here invents
/// state — every field rides from the engine's real output.
class AetherState {
  const AetherState({
    this.engine = '',
    this.running = false,
    this.stage = 'idle',
    this.stageLabel = '',
    this.connected = false,
    this.server = '',
    this.rtt = '',
    this.profile = '',
    this.socksPort = 0,
    this.sinceMs = 0,
    this.error = '',
    this.identity = false,
    this.probeTopReason = '',
    this.log = '',
  });

  factory AetherState.fromMap(Map<dynamic, dynamic> m) => AetherState(
    engine: (m['engine'] as String?) ?? '',
    running: m['running'] == true,
    stage: (m['stage'] as String?) ?? 'idle',
    stageLabel: (m['stageLabel'] as String?) ?? '',
    connected: m['connected'] == true,
    server: (m['server'] as String?) ?? '',
    rtt: (m['rtt'] as String?) ?? '',
    profile: (m['profile'] as String?) ?? '',
    socksPort: (m['socksPort'] as num?)?.toInt() ?? 0,
    sinceMs: (m['sinceMs'] as num?)?.toInt() ?? 0,
    error: (m['error'] as String?) ?? '',
    identity: m['identity'] == true,
    probeTopReason: (m['probeTopReason'] as String?) ?? '',
    log: (m['log'] as String?) ?? '',
  );

  final String engine;
  final bool running;

  /// idle | starting | identity | quickcheck | scan | selected |
  /// handshake | tunnel | validate | connected | reconnecting |
  /// stopped | failed | crashed
  final String stage;
  final String stageLabel;

  /// The engine's own word: its data plane validated / its
  /// SOCKS live (stage CONNECTED in ralysnd's semantics).
  final bool connected;

  /// The endpoint the engine selected ("host:port"), when said.
  final String server;

  /// The scan RTT the engine reported for the selection.
  final String rtt;

  /// The obfuscation profile in force, when the engine said.
  final String profile;
  final int socksPort;
  final int sinceMs;
  final String error;
  final bool identity;

  /// The most common probe-failure reason from the scan.
  final String probeTopReason;
  final String log;

  bool get failed => stage == 'failed' || stage == 'crashed';
}

/// Options for one Aether run — the ralysnd AetherOptions subset
/// Ember's pages expose. Defaults mirror ralysnd's.
class AetherOptions {
  const AetherOptions({
    this.protocol = 'masque',
    this.scan = 'turbo',
    this.ip = 'v4',
    this.transport = 'h3',
    this.fragment = false,
    this.noize = '',
    this.keepalive = 25,
    this.peer,
  });

  /// masque | wg | gool (the cfwarp slot always runs wg)
  final String protocol;

  /// turbo | balanced | thorough | stealth | ironclad
  final String scan;

  /// v4 | v6 | both
  final String ip;

  /// h3 | h2 | auto — the MASQUE carrier transport. 'auto'
  /// starts on the carrier this network remembered (build 2074,
  /// MasqueCarrier) and learns from the core's log lines.
  final String transport;
  final bool fragment;

  /// '' = the engine default (firewall for MASQUE, balanced else)
  final String noize;
  final int keepalive;

  /// A pinned endpoint "host:port" (disables the scan's choice)
  final String? peer;

  Map<String, Object?> toMap(String engine) => {
    'engine': engine,
    'protocol': protocol,
    'scan': scan,
    'ip': ip,
    'transport': transport,
    'fragment': fragment,
    'noize': noize,
    'keepalive': keepalive,
    if (peer != null && peer!.isNotEmpty) 'peer': peer,
  };

  Map<String, dynamic> toJson() => {
    'protocol': protocol,
    'scan': scan,
    'ip': ip,
    'transport': transport,
    'fragment': fragment,
    'noize': noize,
    'keepalive': keepalive,
    if (peer != null) 'peer': peer,
  };

  factory AetherOptions.fromJson(Map<String, dynamic> j) => AetherOptions(
    protocol: (j['protocol'] as String?) ?? 'masque',
    scan: (j['scan'] as String?) ?? 'turbo',
    ip: (j['ip'] as String?) ?? 'v4',
    transport: (j['transport'] as String?) ?? 'h3',
    fragment: j['fragment'] == true,
    noize: (j['noize'] as String?) ?? '',
    keepalive: (j['keepalive'] as num?)?.toInt() ?? 25,
    peer: j['peer'] as String?,
  );

  AetherOptions copyWith({
    String? protocol,
    String? scan,
    String? ip,
    String? transport,
    bool? fragment,
    String? noize,
    int? keepalive,
    String? peer,
    bool clearPeer = false,
  }) => AetherOptions(
    protocol: protocol ?? this.protocol,
    scan: scan ?? this.scan,
    ip: ip ?? this.ip,
    transport: transport ?? this.transport,
    fragment: fragment ?? this.fragment,
    noize: noize ?? this.noize,
    keepalive: keepalive ?? this.keepalive,
    peer: clearPeer ? null : (peer ?? this.peer),
  );
}

/// The platform-channel surface of the Aether engines
/// (MainActivity's aether* and socksTun* cases).
class AetherPlatform {
  static const _channel = MethodChannel('app/android');

  static const int cfwarpSocksPort = 20870;
  static const int masqueSocksPort = 20810;

  static Future<bool> start(String engine, AetherOptions options) async =>
      await _channel.invokeMethod<bool>(
        'aetherStart',
        options.toMap(engine),
      ) ??
      false;

  static Future<void> stop(String engine) =>
      _channel.invokeMethod<void>('aetherStop', {'engine': engine});

  static Future<AetherState> state(String engine) async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>(
      'aetherState',
      {'engine': engine},
    );
    return m == null ? const AetherState() : AetherState.fromMap(m);
  }

  /// Blocking on the platform side (the registration ladder):
  /// makes an identity when the slot has none. Returns the
  /// platform's outcome line.
  static Future<String> ensureIdentity(String engine, String protocol) async =>
      await _channel.invokeMethod<String>('aetherEnsureIdentity', {
        'engine': engine,
        'protocol': protocol,
      }) ??
      '';

  static Future<void> resetIdentity(String engine) =>
      _channel.invokeMethod<void>('aetherResetIdentity', {'engine': engine});

  /// One Cloudflare trace through the slot's SOCKS (the cfwarp
  /// connect proof and both pages' exit card). Null on failure.
  static Future<Map<String, String>?> trace(String engine) async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>(
      'aetherTrace',
      {'engine': engine},
    );
    if (m == null) return null;
    return m.map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  /// Raises (or drops) the device TUN against a slot's SOCKS —
  /// the generic XrayVpnService SOCKS mode, VPN consent included.
  static Future<void> setTun({
    required bool on,
    required String name,
    required int socksPort,
    required String engine,
    required int mtu,
    String dns = '1.1.1.1',
    bool ipv6 = true,
  }) => _channel.invokeMethod<void>('socksTunSetOn', {
    'on': on,
    'name': name,
    'dns': dns,
    'ipv6': ipv6,
    'mtu': mtu,
    'socksPort': socksPort,
    'engine': engine,
  });

  /// The TUN service's session state (shared with the V2Ray
  /// engine's bridge reads: running, name, sinceMs, up, down).
  static Future<Map<String, dynamic>> tunState() async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>('xrayState');
    if (m == null) return const {};
    return m.map((k, v) => MapEntry(k.toString(), v));
  }
}
