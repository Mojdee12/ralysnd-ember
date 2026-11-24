/// The sing-box sidecar's config for one profile (build
/// 2075). sing-box serves the protocols the vendored Xray
/// core cannot: TUIC v5, AnyTLS (build 2089), Snell and
/// NaiveProxy as outbounds, Tailscale and OpenConnect as
/// endpoints — and, since build 2116, the Hysteria2
/// profiles the Xray core cannot serve whole (an mport
/// port-hopping range or gecko obfs; see
/// [Profile.hy2SidecarServed]). The generated config is deliberately minimal — one mixed (SOCKS+HTTP)
/// inbound on loopback, one target — because the Xray
/// tunnel owns everything else (TUN, routing, DNS, stats):
/// the tunnel's proxy outbound is a plain SOCKS outbound
/// aimed at [singBoxListenPort], and the sidecar is only
/// the dialer, the DNSTT underlay's role one level up.
///
/// Every shape here was validated against the real
/// sing-box 1.14.4 binary during development (`sing-box
/// check`): TUIC, Snell v4, Naive and the Tailscale
/// endpoint accepted as written; the OpenConnect endpoint
/// takes its port inside the `server` string ("host:443")
/// — a separate server_port field is rejected. AnyTLS
/// (build 2089): the minimal outbound, +alpn and +utls
/// fingerprint all accepted; an unknown fingerprint is
/// rejected at load ("unknown uTLS fingerprint"), so the
/// emitter only passes one from [singBoxUtlsFingerprints]
/// and drops any other stored value instead of breaking
/// the sidecar start.
///
/// Build 2126 (feature pick 3): Shadowsocks joins the
/// sidecar — but only a profile whose stored plugin is
/// `shadow-tls` and only while the ShadowTLS fronting
/// setting is on (the controller diverts it; see
/// XrayController.shadowTlsServed). The emitted pair is a
/// shadowsocks outbound detoured through a shadowtls
/// outbound — the composition sing-box's own source
/// defines (protocol/shadowtls/outbound.go: the shadowtls
/// outbound dials its own server and ignores the requested
/// destination, so the SS outbound dials THROUGH it via
/// `detour`). TLS is REQUIRED on the shadowtls outbound
/// (the core refuses a config without it), version 0 would
/// default to 1 (so the version is always emitted), and
/// the whole shape passed `sing-box check` against the
/// real 1.14.4 binary, classic and 2022 ciphers alike.
/// ShadowTLS is TCP-only in the core (its ListenPacket
/// returns ErrInvalid): a fronted session cannot relay
/// UDP, which the connect path journals.

import 'sni_spoof.dart';
import 'xray_models.dart';

/// The sidecar's local mixed-inbound port (mirrored in
/// Kotlin: SingBoxCore.PORT).
const singBoxListenPort = 20862;

/// The tag of the ShadowTLS front outbound (build 2126):
/// a fronted Shadowsocks outbound detours through it.
const shadowTlsOutboundTag = 'shadowtls-out';

/// The uTLS fingerprints sing-box 1.14.4 accepts (build
/// 2089 — each one passed `sing-box check` against the
/// vendored 1.14.4 binary; an unlisted value is rejected
/// at config load, so the emitter allowlists here).
const singBoxUtlsFingerprints = <String>{
  'chrome',
  'firefox',
  'safari',
  'ios',
  'android',
  'edge',
  '360',
  'qq',
  'random',
  'randomized',
};

/// Plain-language reason this profile cannot be served by
/// the sing-box sidecar, or null when the config can be
/// built. Checked before any process starts, so the user
/// hears the real reason instead of a dead tunnel.
String? singBoxConfigError(Profile p) {
  switch (p.protocol) {
    case Protocol.tuic:
      if (p.uuidOrPassword.isEmpty) return 'This TUIC config has no UUID.';
      if (p.address.isEmpty) return 'This TUIC config has no server.';
      return null;
    case Protocol.anytls:
      if (p.uuidOrPassword.isEmpty) {
        return 'This AnyTLS config has no password.';
      }
      if (p.address.isEmpty) return 'This AnyTLS config has no server.';
      return null;
    case Protocol.snell:
      if (p.uuidOrPassword.isEmpty) return 'This Snell config has no key (PSK).';
      if (p.address.isEmpty) return 'This Snell config has no server.';
      return null;
    case Protocol.naive:
      if (p.address.isEmpty) return 'This NaiveProxy config has no server.';
      return null;
    case Protocol.shadowsocks:
      // Build 2126: only a shadow-tls profile is ever
      // diverted here (see the file header); anything else
      // reaching this case is a routing bug, reported like
      // any unservable profile rather than silently built.
      final st = p.shadowTlsPlugin;
      if (st == null) {
        return 'This Shadowsocks config has no ShadowTLS plugin.';
      }
      if (p.address.isEmpty) return 'This Shadowsocks config has no server.';
      if (p.method.isEmpty) return 'This Shadowsocks config has no method.';
      if (st.host.isEmpty) {
        return 'This ShadowTLS config has no handshake host '
            '(the plugin\'s host= value).';
      }
      if (st.version >= 2 && st.password.isEmpty) {
        return 'This ShadowTLS config has no password '
            '(the plugin\'s password= value).';
      }
      return null;
    case Protocol.hysteria2:
      // Build 2116 (audit B2-2/B2-7): only the profiles
      // [Profile.hy2SidecarServed] diverts here (an mport
      // range or gecko obfs — the two shapes the Xray core
      // cannot apply) ever reach this case.
      if (p.address.isEmpty) return 'This Hysteria2 config has no server.';
      return null;
    case Protocol.tailscale:
      if (p.tailscaleAuthKey.isEmpty) {
        return 'This Tailscale config has no auth key. Add one in the editor.';
      }
      return null;
    case Protocol.openconnect:
      if (p.address.isEmpty) return 'This OpenConnect config has no server.';
      if (p.username.isEmpty) {
        return 'This OpenConnect config has no username.';
      }
      return null;
    case Protocol.ssh:
      // Build 2147 (feature #6): the ssh outbound needs a
      // server and SOME credential — a password or a
      // private key (sing-box v1.14.4 option/ssh.go).
      if (p.address.isEmpty) return 'This SSH config has no server.';
      if (p.sshPassword.isEmpty && p.sshPrivateKey.isEmpty) {
        return 'This SSH config has no credential. Add a password '
            'or a private key in the editor.';
      }
      return null;
    default:
      return '${p.protocol.label} is not a sing-box protocol.';
  }
}

/// Whether [value] is a base64 ECHConfigList (the form
/// sing-box's `ech.config` takes) rather than the Xray
/// core's query form ("name+udp://…"), which has no
/// sing-box equivalent and stays Xray-only. The query
/// form always carries a '.' (the server name) and a
/// resolver URL; a base64 list is alphabet-only.
bool _isBase64EchList(String value) =>
    !value.contains('://') &&
    RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(value.trim());

Map<String, dynamic> _tlsBlock(Profile p, {List<String>? defaultAlpn}) {
  final alpn = p.alpn
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  return {
    'enabled': true,
    'server_name': p.sni.isNotEmpty ? p.sni : p.address,
    if (alpn.isNotEmpty)
      'alpn': alpn
    else if (defaultAlpn != null)
      'alpn': defaultAlpn,
    // Build 2116 (audit G-19): ECH was fully wired on the
    // Xray path and silently absent here. sing-box takes
    // the base64 ECHConfigList form; the query form stays
    // Xray-only (see _isBase64EchList).
    if (p.echConfigList.isNotEmpty && _isBase64EchList(p.echConfigList))
      'ech': {
        'enabled': true,
        'config': [p.echConfigList.trim()],
      },
    // Build 2116 (audit S-01): the TUIC link's own
    // allow_insecure, honoured by sing-box (the Xray core
    // removed the flag in build 2048 — this block is the
    // sidecar's, and only a TUIC profile can carry it).
    if (p.tuicAllowInsecure) 'insecure': true,
    // Build 2116 (audit G-21): the TUIC link's disable_sni.
    if (p.disableSni) 'disable_sni': true,
  };
}

/// Normalises a Hysteria2 `mport` value (build 2116,
/// audit B2-2) into sing-box `server_ports` ranges: the
/// link spellings are comma-separated ports and ranges
/// ("443,8443", "10000-20000", "10000:20000"); sing-box
/// wants "low:high" strings. Tokens that do not parse as
/// ports in range are dropped — a partially valid list
/// still hops on the valid ranges.
List<String> singBoxServerPorts(String mport) {
  final out = <String>[];
  for (final raw in mport.split(',')) {
    final token = raw.trim();
    if (token.isEmpty) continue;
    final parts = token.split(RegExp(r'[-:]'));
    if (parts.length == 1) {
      final port = int.tryParse(parts[0].trim());
      if (port != null && port >= 1 && port <= 65535) out.add('$port:$port');
    } else if (parts.length == 2) {
      final lo = int.tryParse(parts[0].trim());
      final hi = int.tryParse(parts[1].trim());
      if (lo != null &&
          hi != null &&
          lo >= 1 &&
          hi <= 65535 &&
          lo <= hi) {
        out.add('$lo:$hi');
      }
    }
  }
  return out;
}

/// The NaiveProxy `insecure_concurrency` extra (build
/// 2116, S-02): a positive int, 0 when absent or invalid.
int _naiveInsecureConcurrency(Profile p) {
  final v = int.tryParse(p.naiveExtras['insecure_concurrency'] ?? '');
  return v != null && v > 0 ? v : 0;
}

bool _naiveTruthy(String? v) =>
    v == '1' || v?.toLowerCase() == 'true' || v?.toLowerCase() == 'yes';

/// The sing-box log level for the app's log-level setting
/// (build 2116, audit S-06): the setting speaks the Xray
/// vocabulary (debug/info/warning/error/none); sing-box
/// wants warn for warning and a disabled log for none.
/// Anything unrecognised keeps today's behaviour, 'warn'.
String singBoxLogLevel(String setting) => switch (setting.trim().toLowerCase()) {
  'debug' => 'debug',
  'info' => 'info',
  'error' => 'error',
  'warn' || 'warning' => 'warn',
  _ => 'warn',
};

/// The full sing-box config JSON for [p] (see the file
/// header). Throws nothing; pair with [singBoxConfigError].
/// [logLevel] is the app's log-level setting (build 2116,
/// S-06): the sidecar's log verbosity follows it, mapped
/// by [singBoxLogLevel]; the default preserves the
/// long-standing hard-coded 'warn'.
Map<String, dynamic> buildSingBoxConfig(
  Profile p, {
  String logLevel = 'warning',
  // Build 2126 (D1): emit the profile's gecko packet-size
  // band into the obfs block (the XraySettings toggle of
  // the same name, passed in by the controller). Default
  // false = the 2125 emission, byte-identical.
  bool geckoPacketSizes = false,
  // Build 2126 (D8): add the catch-all route-options
  // tls_fragment rule (the XraySettings toggle of the
  // same name). Default false = the 2125 route section,
  // byte-identical.
  bool sidecarTlsFragment = false,
  // Build 2127 (H3): the per-route SNI spoofing rules
  // (the XraySettings list, passed in by the controller
  // only while its toggle is on). Each becomes a
  // route-options rule ahead of the D8 catch-all.
  // Default empty = no spoof rules, byte-identical.
  List<SniSpoofRule> sniSpoofRules = const [],
}) {
  final outbound = switch (p.protocol) {
    Protocol.tuic => <String, dynamic>{
      'type': 'tuic',
      'tag': 'proxy',
      'server': p.address,
      'server_port': p.port,
      'uuid': p.uuidOrPassword,
      if (p.method.isNotEmpty) 'password': p.method,
      'congestion_control': p.congestionControl.isNotEmpty
          ? p.congestionControl
          : 'bbr',
      'udp_relay_mode': p.udpRelayMode.isNotEmpty ? p.udpRelayMode : 'native',
      // Build 2116 (audit G-21): the link's TUIC extras,
      // emitted only when the link carried them.
      if (p.zeroRttHandshake) 'zero_rtt_handshake': true,
      if (p.tuicHeartbeat.isNotEmpty) 'heartbeat': p.tuicHeartbeat,
      if (p.udpOverStream) 'udp_over_stream': true,
      'tls': _tlsBlock(p, defaultAlpn: const ['h3']),
    },
    // AnyTLS (build 2089): sing-box 1.14.4's anytls
    // outbound — password from the link's userinfo, the
    // shared TLS block (SNI + ALPN), plus the stored
    // fingerprint as a uTLS fingerprint ONLY when it is
    // one sing-box accepts (see the header): an unknown
    // stored value is dropped, never passed through, so
    // a pasted profile can never break the sidecar start.
    Protocol.anytls => <String, dynamic>{
      'type': 'anytls',
      'tag': 'proxy',
      'server': p.address,
      'server_port': p.port,
      'password': p.uuidOrPassword,
      'tls': {
        ..._tlsBlock(p),
        if (singBoxUtlsFingerprints
            .contains(p.fingerprint.trim().toLowerCase()))
          'utls': {
            'enabled': true,
            'fingerprint': p.fingerprint.trim().toLowerCase(),
          },
      },
    },
    Protocol.snell => <String, dynamic>{
      'type': 'snell',
      'tag': 'proxy',
      'server': p.address,
      'server_port': p.port,
      'psk': p.uuidOrPassword,
      'version': p.snellVersion,
      if (p.obfs.isNotEmpty) 'obfs_mode': p.obfs,
      if (p.obfs.isNotEmpty && p.obfsPassword.isNotEmpty)
        'obfs_host': p.obfsPassword,
    },
    // SSH (build 2147, feature #6): sing-box 1.14.4's ssh
    // outbound (option/ssh.go) — TCP-only (the outbound has
    // no ListenPacket), which the editor states. The user
    // defaults to root when the profile names none; the
    // host-key pin rides as the `host_key` list verbatim
    // (an OpenSSH-format key line from the editor).
    Protocol.ssh => <String, dynamic>{
      'type': 'ssh',
      'tag': 'proxy',
      'server': p.address,
      'server_port': p.port,
      'user': p.sshUser.isNotEmpty ? p.sshUser : 'root',
      if (p.sshPassword.isNotEmpty) 'password': p.sshPassword,
      if (p.sshPrivateKey.isNotEmpty)
        'private_key': [p.sshPrivateKey],
      if (p.sshPrivateKey.isNotEmpty && p.sshPrivateKeyPassphrase.isNotEmpty)
        'private_key_passphrase': p.sshPrivateKeyPassphrase,
      if (p.sshHostKeyPin.isNotEmpty) 'host_key': [p.sshHostKeyPin],
    },
    Protocol.naive => <String, dynamic>{
      'type': 'naive',
      'tag': 'proxy',
      'server': p.address,
      'server_port': p.port,
      if (p.username.isNotEmpty) 'username': p.username,
      if (p.uuidOrPassword.isNotEmpty) 'password': p.uuidOrPassword,
      // Build 2116 (audit S-02): the stored extra link
      // parameters sing-box supports (option set verified
      // against the vendored 1.14.4 source). The rest —
      // padding above all — has no sing-box field and is
      // journaled at connect instead (xray_controller).
      if (_naiveInsecureConcurrency(p) > 0)
        'insecure_concurrency': _naiveInsecureConcurrency(p),
      if (_naiveTruthy(p.naiveExtras['quic'])) 'quic': true,
      if (p.sni.isNotEmpty && p.sni != p.address) 'tls': _tlsBlock(p),
    },
    // Hysteria2 (build 2116, audit B2-2/B2-7): only the
    // profiles the Xray core cannot serve whole — an
    // mport range (port hopping: sing-box's server_ports)
    // or gecko obfs — are diverted here; plain and
    // salamander Hy2 stay on the Xray core. The obfs
    // block carries whichever type the profile stores
    // (salamander included: an mport+salamander profile
    // lands here for its hopping and keeps its obfs).
    Protocol.hysteria2 => <String, dynamic>{
      'type': 'hysteria2',
      'tag': 'proxy',
      'server': p.address,
      'server_port': p.port,
      if (singBoxServerPorts(p.hyMport).isNotEmpty) ...{
        'server_ports': singBoxServerPorts(p.hyMport),
        'hop_interval': '30s',
      },
      if (p.uuidOrPassword.isNotEmpty) 'password': p.uuidOrPassword,
      if (p.upMbps > 0) 'up_mbps': p.upMbps,
      if (p.downMbps > 0) 'down_mbps': p.downMbps,
      if (p.obfs.isNotEmpty)
        'obfs': {
          'type': p.obfs,
          'password': p.obfsPassword,
          // Build 2126 (D1): the gecko packet-size band —
          // sing-box 1.14.4 merges these into the obfs
          // object for type gecko (Hysteria2ObfsGecko);
          // emitted only under the geckoPacketSizes
          // setting, so off = the 2125 block exactly.
          if (geckoPacketSizes &&
              p.obfs == 'gecko' &&
              p.geckoMinPacketSize > 0)
            'min_packet_size': p.geckoMinPacketSize,
          if (geckoPacketSizes &&
              p.obfs == 'gecko' &&
              p.geckoMaxPacketSize > 0)
            'max_packet_size': p.geckoMaxPacketSize,
        },
      'tls': _tlsBlock(p, defaultAlpn: const ['h3']),
    },
    // Shadowsocks + ShadowTLS (build 2126, feature pick 3):
    // only a diverted shadow-tls profile reaches this case
    // (the controller gates the diversion on the fronting
    // setting). The SS outbound keeps the route-final tag
    // and detours through the shadowtls outbound below —
    // the front performs the camouflage TLS handshake with
    // the plugin's host as its server name, then the SS
    // bytes ride inside it.
    Protocol.shadowsocks => <String, dynamic>{
      'type': 'shadowsocks',
      'tag': 'proxy',
      'server': p.address,
      'server_port': p.port,
      'method': p.method,
      'password': p.uuidOrPassword,
      // The detour exists only with its target: a profile
      // without a shadow-tls plugin emits a plain SS
      // outbound (never a detour to a missing tag).
      if (p.shadowTlsPlugin != null) 'detour': shadowTlsOutboundTag,
    },
    _ => null,
  };
  // The ShadowTLS front outbound itself (build 2126): the
  // detour target of the shadowsocks case above. Its server
  // is the profile's own endpoint (the front dials it and
  // ignores the requested destination — sing-box source,
  // see the file header); the plugin supplies the version,
  // the ShadowTLS password and the handshake host. TLS must
  // be present and enabled or the core refuses the config,
  // and the version is emitted explicitly because an absent
  // version defaults to 1 in the core, not 3.
  final st = p.protocol == Protocol.shadowsocks ? p.shadowTlsPlugin : null;
  final shadowTlsOutbound = st == null
      ? null
      : <String, dynamic>{
          'type': 'shadowtls',
          'tag': shadowTlsOutboundTag,
          'server': p.address,
          'server_port': p.port,
          'version': st.version,
          if (st.password.isNotEmpty) 'password': st.password,
          'tls': {'enabled': true, 'server_name': st.host},
        };
  final endpoint = switch (p.protocol) {
    Protocol.tailscale => <String, dynamic>{
      'type': 'tailscale',
      'tag': 'proxy',
      'auth_key': p.tailscaleAuthKey,
    },
    Protocol.openconnect => <String, dynamic>{
      'type': 'openconnect',
      'tag': 'proxy',
      'server': '${p.address}:${p.port}',
      if (p.username.isNotEmpty) 'username': p.username,
      if (p.uuidOrPassword.isNotEmpty) 'password': p.uuidOrPassword,
    },
    _ => null,
  };
  return {
    'log': {
      if (logLevel.trim().toLowerCase() == 'none')
        'disabled': true
      else
        'level': singBoxLogLevel(logLevel),
      'timestamp': true,
    },
    'inbounds': [
      {
        'type': 'mixed',
        'tag': 'in',
        'listen': '127.0.0.1',
        'listen_port': singBoxListenPort,
      },
    ],
    if (outbound != null)
      'outbounds': [outbound, ?shadowTlsOutbound],
    if (endpoint != null) 'endpoints': [endpoint],
    'route': {
      // Build 2127 (H3) + build 2126 (D8): the route
      // rules, specific before general — one route-options
      // rule per SNI spoofing rule (domain_suffix match;
      // sing-box 1.14.4's RawRouteOptionsActionOptions
      // carries tls_spoof / tls_spoof_method, the
      // grammar read from the vendored binary's own
      // option struct), then the D8 catch-all
      // tls_fragment rule. Both empty/off, the route
      // section is {'final': 'proxy'} exactly as in 2125.
      if (sidecarTlsFragment ||
          sniSpoofRules.any(
            (r) => r.domain.trim().isNotEmpty && r.spoof.trim().isNotEmpty,
          ))
        'rules': [
          for (final r in sniSpoofRules)
            if (r.domain.trim().isNotEmpty && r.spoof.trim().isNotEmpty)
              {
                'action': 'route-options',
                'domain_suffix': [r.domain.trim()],
                'tls_spoof': r.spoof.trim(),
                if (r.method.isNotEmpty) 'tls_spoof_method': r.method,
              },
          if (sidecarTlsFragment)
            {'action': 'route-options', 'tls_fragment': true},
        ],
      'final': 'proxy',
    },
  };
}
