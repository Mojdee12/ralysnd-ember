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
    this.engineValidated = false,
    this.identityRefused = false,
    this.probeTopReason = '',
    this.traceError = '',
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
    engineValidated: m['engineValidated'] == true,
    identityRefused: m['identityRefused'] == true,
    probeTopReason: (m['probeTopReason'] as String?) ?? '',
    traceError: (m['traceError'] as String?) ?? '',
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

  /// Build 2116 (B5-8): the engine validated this run's
  /// tunnel end-to-end and the validation is still fresh —
  /// the native data probe trusts it over a cold re-probe.
  final bool engineValidated;

  /// Build 2116 (B5-3): the engine refused the stored
  /// identity (cert/key mismatch or deregistration) — the
  /// failure surface names the Reset path when this is set.
  final bool identityRefused;

  /// The most common probe-failure reason from the scan.
  final String probeTopReason;

  /// Build 2115: the last trace fetch's failure, in the
  /// native side's own words ('' when the last trace landed).
  /// Before this build a failed trace was an opaque null.
  final String traceError;
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
    this.transport = 'auto',
    this.transportExplicit = false,
    this.ech = '',
    this.fragment = false,
    this.noize = '',
    this.keepalive = 25,
    this.peer,
  });

  /// masque | wg | gool | mim (the cfwarp slot always runs wg)
  final String protocol;

  /// turbo | balanced | thorough | stealth | ironclad
  final String scan;

  /// v4 | v6 | both
  final String ip;

  /// h3 | h2 | auto — the MASQUE carrier transport. 'auto'
  /// (the default since build 2083) walks the carrier ladder
  /// natively in ONE connect (MasqueRung: H3 → H2 → H2+
  /// fragment → H2+semi-python+fragment → H2+semi-python+
  /// tlshello), each rung proven by real data before the
  /// TUN, and remembers the rung that carried data per
  /// network. An explicit 'h3'/'h2' stays a single-carrier
  /// connect and learns nothing.
  final String transport;

  /// Whether [transport] was picked by the user on the page,
  /// as opposed to shipped as a default (build 2083). The
  /// distinction is what the one-time migration below reads:
  /// through build 2082 the shipped default was 'h3', so a
  /// stored 'h3' without this marker cannot be told apart
  /// from the old default.
  final bool transportExplicit;

  /// The ECH setting handed to the engine (AETHER_ECH):
  /// '' = the engine's own default. Build 2116 (A-02):
  /// the Kotlin side has read this argument all along
  /// (AetherRunOptions.ech → buildEnv) — the Dart options
  /// simply never carried or sent it, so it was always ''.
  final String ech;
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
    'ech': ech,
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
    'transportExplicit': transportExplicit,
    'ech': ech,
    'fragment': fragment,
    'noize': noize,
    'keepalive': keepalive,
    if (peer != null) 'peer': peer,
  };

  factory AetherOptions.fromJson(Map<String, dynamic> j) => AetherOptions(
    protocol: (j['protocol'] as String?) ?? 'masque',
    scan: (j['scan'] as String?) ?? 'turbo',
    ip: (j['ip'] as String?) ?? 'v4',
    transport: (j['transport'] as String?) ?? 'auto',
    transportExplicit: j['transportExplicit'] == true,
    ech: (j['ech'] as String?) ?? '',
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
    bool? transportExplicit,
    String? ech,
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
    transportExplicit: transportExplicit ?? this.transportExplicit,
    ech: ech ?? this.ech,
    fragment: fragment ?? this.fragment,
    noize: noize ?? this.noize,
    keepalive: keepalive ?? this.keepalive,
    peer: clearPeer ? null : (peer ?? this.peer),
  );
}

/// Build 2083: the one-time transport migration for stored
/// options (applied by AetherController.load and persisted
/// there). Through build 2082 the shipped MASQUE transport
/// default was 'h3', and the options file cannot tell a
/// stored default from an explicit HTTP/3 pick — so an
/// unmarked 'h3' is read as the old default and lands on
/// 'auto', the new default (whose ladder tries HTTP/3
/// first anyway, and remembers what worked). An unmarked
/// 'h2' can only be an explicit pick — 'h2' was never a
/// default — so it is marked explicit and honored. Anything
/// already marked, and 'auto' itself, stands as stored.
/// Returns the same instance when nothing changes.
AetherOptions migrateMasqueTransport(AetherOptions o) {
  if (o.transportExplicit) return o;
  if (o.transport == 'h3') return o.copyWith(transport: 'auto');
  if (o.transport == 'h2') return o.copyWith(transportExplicit: true);
  return o;
}

/// Build 2083: the MASQUE carrier ladder's time arithmetic.
/// The native walk has its own bound (AetherSlot's
/// ladderTotalMs, the same numbers); this is the Dart
/// backstop for the platform call — the native side answers
/// first in every expected case, and the backstop only
/// guards a wedged call, after which the connect tears the
/// engine down. A bound, not an expectation: a dead rung
/// ends at its ~45 s scan-cycle signal natively, so a cold
/// first connect on a filtered line normally resolves in a
/// few minutes.
int masqueScanDeadlineMs(String scan) => switch (scan) {
  'turbo' => 45000,
  'balanced' => 120000,
  'thorough' => 300000,
  'stealth' => 180000,
  'ironclad' => 180000,
  _ => 180000,
};

/// Identity/handshake/validation headroom after a scan.
const int masqueRungHeadroomMs = 45000;

/// Trace + data-proof allowance inside one rung's total.
const int masqueProofAllowanceMs = 135000;

/// The rungs the ladder walks (MasqueRung, native side).
const int masqueLadderRungCount = 5;

/// The Dart backstop for one masque-auto connect: every
/// rung's wait + proofs, plus a minute of channel slack.
Duration masqueAutoConnectTimeout(String scan) => Duration(
  milliseconds:
      masqueLadderRungCount *
          (masqueScanDeadlineMs(scan) +
              masqueRungHeadroomMs +
              masqueProofAllowanceMs) +
      60000,
);

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

  /// Build 2083: the MASQUE carrier ladder — ONE native
  /// call that walks the rungs (engine start → CONNECTED →
  /// warp trace → data proof per rung) until one carries
  /// data, remembering the winner per network. On success
  /// the engine is left running and proven; the caller
  /// raises the TUN. Blocking on the platform side for the
  /// whole walk; the caller bounds it with
  /// [masqueAutoConnectTimeout]. Returns the verdict map
  /// ({ok, carrier, label} or {ok: false, error}); null
  /// when the platform call itself failed.
  static Future<Map<String, dynamic>?> connectMasque(
    String engine,
    AetherOptions options,
  ) async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>(
      'aetherConnectMasque',
      options.toMap(engine),
    );
    if (m == null) return null;
    return m.map((k, v) => MapEntry(k.toString(), v));
  }

  static Future<void> stop(String engine) =>
      _channel.invokeMethod<void>('aetherStop', {'engine': engine});

  static Future<AetherState> state(String engine) async {
    // Build 2116 (AB-11): a channel throw here used to
    // escape into the controller's refresh() — an
    // unhandled async error and a card frozen on its last
    // state. A state read that cannot be answered reads
    // as stopped, the Warp/Sidecar treatment.
    try {
      final m = await _channel.invokeMapMethod<dynamic, dynamic>(
        'aetherState',
        {'engine': engine},
      );
      return m == null ? const AetherState() : AetherState.fromMap(m);
    } catch (_) {
      return const AetherState();
    }
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

  /// Real transfers through the slot's SOCKS (build 2080, the
  /// CfDataProbe port): HTTP 204, HTTPS 204, an exact-byte
  /// download and an echoed upload, all through the tunnel's
  /// own proxy. Returns the native verdict map ({ok, detail,
  /// ms}); null when the platform call itself failed. Blocking
  /// on the platform side (up to ~45 s).
  static Future<Map<String, dynamic>?> dataProbe(String engine) async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>(
      'aetherDataProbe',
      {'engine': engine},
    );
    if (m == null) return null;
    return m.map((k, v) => MapEntry(k.toString(), v));
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
    bool killSwitch = false,
  }) => _channel.invokeMethod<void>('socksTunSetOn', {
    'on': on,
    'name': name,
    'dns': dns,
    'ipv6': ipv6,
    'mtu': mtu,
    'socksPort': socksPort,
    'engine': engine,
    // Build 2097 (post-2096 audit C7): the native handler
    // has read this argument since build 2063 — the Dart
    // side simply never sent it, so the Settings kill
    // switch silently did nothing for the WARP/MASQUE
    // (Aether) tunnels while its copy promised coverage.
    'killSwitch': killSwitch,
  });

  /// The TUN service's session state (shared with the V2Ray
  /// engine's bridge reads: running, name, sinceMs, up, down).
  static Future<Map<String, dynamic>> tunState() async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>('xrayState');
    if (m == null) return const {};
    return m.map((k, v) => MapEntry(k.toString(), v));
  }
}
