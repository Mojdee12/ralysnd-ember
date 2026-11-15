/// Builds the Xray JSON configurations the core runs: the tunnel config
/// (SOCKS + HTTP inbounds for the tun2socks bridge, preset and custom
/// routing, DNS, sniffing, mux, TLS fragmenting) and the SOCKS-only
/// config the delay/speed tests use. Ported from the Ralysnd client's
/// Kotlin ConfigBuilder and extended for Hysteria2 / WireGuard, the
/// kcp and quic transports, fakeDNS, presets and custom rules.
///
/// TUIC is the one parsed protocol this core cannot serve: Xray-core has
/// no TUIC outbound, so [buildOutbound] returns null for it and the UI
/// marks such profiles instead of pretending to connect them.

import 'dart:convert';

import 'anti_filter.dart';
import 'config_mixins.dart';
import 'dns_hosts.dart';
import 'dnstt_args.dart';
import 'tls_cert_pin.dart';
import 'vless_encryption.dart';
import 'warp_args.dart';
import 'xray_models.dart';

String prettyJson(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);

Map<String, dynamic> _streamSettings(
  Profile p, {
  String fingerprintOverride = '',
}) {
  // Build 2065 (item 13): the rotation override fills an empty
  // profile fingerprint only — a profile's own value (or a
  // pin-shaped value riding in it) is never replaced.
  final fp = p.fingerprint.isEmpty && fingerprintOverride.isNotEmpty
      ? fingerprintOverride
      : p.fingerprint;
  final stream = <String, dynamic>{'network': p.network};
  final security = p.security;
  stream['security'] = security.isEmpty ? 'none' : security;

  if (security == 'tls') {
    // TLS certificate pin (build 2047): emitted verbatim when
    // valid; re-validated here, so a corrupt store can never break
    // a connect (the 2041 lesson). The core removed
    // `allowInsecure` outright — it refuses the whole config when
    // the key is set — so Ember never emits it at all (build
    // 2048 removed the toggle and the field; a valid pin is the
    // core's own replacement for skipping the check).
    final pin = isValidTlsCertPin(p.tlsCertPin) ? p.tlsCertPin : '';
    final tls = <String, dynamic>{
      'serverName': p.sni.isEmpty ? p.address : p.sni,
    };
    final alpn = p.alpn
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (alpn.isNotEmpty) tls['alpn'] = alpn;
    // A SHA-256-shaped `fingerprint` is a certificate pin, not a
    // uTLS name (build 2057, audit F-M15): the core's
    // TLSConfig.Build hard-fails on it, so it is never emitted
    // as a fingerprint — it rides as the pin instead when no pin
    // is stored (the 2053 Hy2 legacy handling, generalised).
    final effectivePin = pin.isNotEmpty
        ? pin
        : (isValidTlsCertPin(p.fingerprint) ? p.fingerprint : '');
    if (effectivePin.isNotEmpty) {
      tls['pinnedPeerCertSha256'] = effectivePin;
    }
    if (fp.isNotEmpty && !isValidTlsCertPin(fp)) {
      tls['fingerprint'] = fp;
    }
    // A stored ECH config list (build 2033, from the link's
    // `ech` parameter) applies as written; the anti-filter ECH
    // shape, when also on, replaces it with its own source in
    // applyAntiFilter below — the shape is the more specific
    // instruction, as with cipher suites.
    if (p.echConfigList.isNotEmpty) tls['echConfigList'] = p.echConfigList;
    // The profile's own cipher suites (build 2029A). The
    // unfilter shape overrides this with its own order when it
    // applies (applyAntiFilter, below) — the shape is the more
    // specific instruction.
    if (p.cipherSuites.isNotEmpty) tls['cipherSuites'] = p.cipherSuites;
    stream['tlsSettings'] = tls;
  } else if (security == 'reality') {
    // A SHA-256-shaped `fingerprint` is a certificate pin, not a
    // uTLS name (build 2057, audit F-M15): the core's
    // TLSConfig.Build hard-fails on it, so a pin-shaped value
    // falls back to 'chrome' here instead of being emitted.
    final realityFp = isValidTlsCertPin(fp)
        ? 'chrome'
        : (fp.isEmpty ? 'chrome' : fp);
    stream['realitySettings'] = {
      'serverName': p.sni,
      'fingerprint': realityFp,
      'publicKey': p.publicKey,
      'shortId': p.shortId,
      'spiderX': p.spiderX.isEmpty ? '/' : p.spiderX,
      // REALITY PQ verification (build 2057, audit F-M13): the
      // core's `mldsa65Verify` — a server that requires it fails
      // the handshake invisibly without this field.
      if (p.pqv.isNotEmpty) 'mldsa65Verify': p.pqv,
    };
  }

  switch (p.network) {
    case 'ws':
      final ws = <String, dynamic>{'path': p.path.isEmpty ? '/' : p.path};
      if (p.host.isNotEmpty) ws['headers'] = {'Host': p.host};
      stream['wsSettings'] = ws;
    case 'grpc':
      stream['grpcSettings'] = {
        'serviceName': p.serviceName,
        'multiMode': p.mode == 'multi',
        'idle_timeout': 60,
        'health_check_timeout': 20,
        // gRPC authority (build 2057, audit §6 codec drop): the
        // `:authority` the core sends on the handshake.
        if (p.grpcAuthority.isNotEmpty) 'authority': p.grpcAuthority,
      };
    case 'http':
    case 'h2':
      final h = <String, dynamic>{};
      if (p.host.isNotEmpty) {
        h['host'] = p.host.split(',').map((e) => e.trim()).toList();
      }
      if (p.path.isNotEmpty) h['path'] = p.path;
      stream['httpSettings'] = h;
    case 'httpupgrade':
      final hu = <String, dynamic>{'path': p.path.isEmpty ? '/' : p.path};
      if (p.host.isNotEmpty) hu['host'] = p.host;
      stream['httpupgradeSettings'] = hu;
    case 'xhttp':
    case 'splithttp':
      final x = <String, dynamic>{
        'path': p.path.isEmpty ? '/' : p.path,
        'mode': p.mode.isEmpty ? 'auto' : p.mode,
      };
      if (p.host.isNotEmpty) x['host'] = p.host;
      stream['xhttpSettings'] = x;
    case 'kcp':
      stream['kcpSettings'] = {
        'mtu': 1350,
        'tti': 50,
        'uplinkCapacity': 12,
        'downlinkCapacity': 100,
        'congestion': false,
        'readBufferSize': 2,
        'writeBufferSize': 2,
        'header': {'type': p.headerType.isEmpty ? 'none' : p.headerType},
        if (p.path.isNotEmpty) 'seed': p.path,
      };
    case 'quic':
      // The QUIC security/key (build 2057, audit §6 codec drop):
      // the parser reads the standard link parameters
      // `security`/`key` into host/path, so they land here. A
      // profile stored before that fix still reads its legacy
      // host/path values the same way.
      stream['quicSettings'] = {
        'security': p.host.isEmpty ? 'none' : p.host,
        'key': p.path,
        'header': {'type': p.headerType.isEmpty ? 'none' : p.headerType},
      };
    case 'tcp':
      if (p.headerType == 'http') {
        final hosts = (p.host.isEmpty ? p.address : p.host)
            .split(',')
            .map((e) => e.trim())
            .toList();
        stream['tcpSettings'] = {
          'header': {
            'type': 'http',
            'request': {
              'version': '1.1',
              'method': 'GET',
              'path': [p.path.isEmpty ? '/' : p.path],
              'headers': {
                'Host': hosts,
                'User-Agent': ['Mozilla/5.0'],
                'Accept-Encoding': ['gzip, deflate'],
                'Connection': ['keep-alive'],
                'Pragma': ['no-cache'],
              },
            },
          },
        };
      }
  }
  // The profile's own finalmask (build 2030, patched core):
  // the whole finalmask object as stored JSON, merged over
  // the transport's own entries per direction — a hysteria
  // profile's built-in salamander udp mask survives unless
  // the profile's JSON names a udp list of its own. Malformed
  // stored JSON is skipped, never fatal (the editor validates
  // before save).
  if (p.finalMask.isNotEmpty) {
    try {
      final fm = jsonDecode(p.finalMask);
      if (fm is Map) {
        final merged = <String, dynamic>{
          ...?(stream['finalmask'] as Map?)?.cast<String, dynamic>(),
        };
        for (final e in fm.entries) {
          merged[e.key.toString()] = e.value;
        }
        stream['finalmask'] = merged;
      }
    } catch (_) {
      // Skipped by design (see above).
    }
  }
  // The stream sockopt, shared by two merged-in entries —
  // never assigned over: the chain wiring below stamps
  // dialerProxy into the same map.
  final sock =
      (stream['sockopt'] as Map?)?.cast<String, dynamic>() ??
      <String, dynamic>{};
  // Build 2049 (owner's device log, 2026-11-14): the proxy
  // server must never be dialed over IPv6. The core's dialer
  // honours the sockopt domainStrategy for the outbound's own
  // destination — the server address — resolving it through
  // the config's DNS with A records only (proven in the
  // bundled fork's source: transport/internet/dialer.go
  // resolves a domain destination via LookupForIP with the
  // strategy's IP option before dialing, USE_IP4 enabling
  // IPv4 and not IPv6; infra/conf/transport_sockopt.go maps
  // 'UseIPv4' to it). Without it the core was free to pick
  // the AAAA answer, and on the owner's carrier that dial
  // EOFs — "websocket: failed to dial to [2606:4700:...]:443
  // > EOF", hundreds of times — while IPv4 flows kept
  // working. An IPv6 LITERAL server address is not a domain,
  // so the strategy never touches it: such profiles dial
  // exactly as before. The TLS serverName/Host stay the
  // stored hostname — only the dialed address is pinned to
  // the A answer.
  sock['domainStrategy'] = 'UseIPv4';
  // The patched core's dialMode (build 2030): exact text.
  // Stock Xray ignores the unknown field; only the patched
  // core honours it.
  if (p.dialMode.isNotEmpty) sock['dialMode'] = p.dialMode;
  stream['sockopt'] = sock;
  // Stage A (2026): the profile's anti-filter shaping, if any —
  // a no-op unless the profile opted in AND its security is TLS.
  applyAntiFilter(stream, p);
  return stream;
}

/// The Psiphon core's local SOCKS port (PsiphonConstants.kt
/// on the Kotlin side): the chain underlay's address.
const psiphonSocksPort = 11808;

/// Outbound tags the chain / ECH wiring refers to (build 2029A).
const psiphonUnderlayTag = 'psiphon-underlay';
const echOutboundTag = 'ech-out';

/// The EmberWarp chain tags (build 2030): the underlay
/// outbound (a plain SOCKS hop to the warp core), the inline
/// secondary inbound the core's egress returns through, and
/// the exit-node freedom outbound that really dials — the
/// arrangement patterniha/Aether uses under Xray (dossier Q2),
/// adopted wholesale.
const warpUnderlayTag = 'warp-underlay';
const warpSecondaryTag = 'secondary-socks';
const warpExitTag = 'exit-node';

/// The Warp underlay outbound: the EmberWarp core's local
/// SOCKS, started by the controller before the tunnel config
/// is handed to the service (build 2030).
Map<String, dynamic> _warpUnderlayOutbound() => {
  'tag': warpUnderlayTag,
  'protocol': 'socks',
  'settings': {
    'servers': [
      {'address': '127.0.0.1', 'port': warpSessionPort},
    ],
  },
};

/// The chain's exit node (build 2030): a freedom outbound
/// carrying the WARP profile's finalMask and dialMode — they
/// live here, not on the proxy outbound, because this is the
/// hop that really dials the internet (the warp core's egress
/// arrives through the secondary inbound and leaves through
/// this outbound).
Map<String, dynamic> _warpExitOutbound(WarpProfile w) {
  final stream = <String, dynamic>{'network': 'tcp', 'security': 'none'};
  // Build 2049: the exit node is the hop that really dials for
  // the warp chain, so it carries the same IPv4-only server
  // strategy as the proxy outbound (see _streamSettings).
  final sock = <String, dynamic>{'domainStrategy': 'UseIPv4'};
  if (w.dialMode.isNotEmpty) sock['dialMode'] = w.dialMode;
  stream['sockopt'] = sock;
  if (w.finalMask.isNotEmpty) {
    try {
      final fm = jsonDecode(w.finalMask);
      if (fm is Map) stream['finalmask'] = fm.cast<String, dynamic>();
    } catch (_) {
      // Skipped by design, like the profile finalmask.
    }
  }
  return {
    'tag': warpExitTag,
    'protocol': 'freedom',
    'settings': {'domainStrategy': 'UseIP'},
    'streamSettings': stream,
  };
}

/// The inline secondary inbound (build 2030): the warp core
/// is spawned with --upstream pointing here, so its gateway
/// dials, scans and registration all leave through the
/// exit-node above.
Map<String, dynamic> _warpSecondaryInbound() => {
  'tag': warpSecondaryTag,
  'listen': '127.0.0.1',
  'port': warpExitPort,
  'protocol': 'mixed',
  'settings': {'udp': true},
};

/// The chain underlay outbound: Psiphon's local SOCKS proxy,
/// started proxy-only by the controller before the tunnel
/// config is handed to the service (build 2029A).
Map<String, dynamic> _psiphonUnderlayOutbound() => {
  'tag': psiphonUnderlayTag,
  'protocol': 'socks',
  'settings': {
    'servers': [
      {'address': '127.0.0.1', 'port': psiphonSocksPort},
    ],
  },
};

/// The DNSTT underlay's tag (build 2072).
const dnsttUnderlayTag = 'dnstt-underlay';

/// The DNSTT chain underlay outbound (build 2072): a SOCKS
/// outbound aimed at the dnstt-client's local listener. The
/// client is a plain port forward through a DNS tunnel, NOT a
/// SOCKS server — the SOCKS handshake happens with the proxy
/// dnstt-server forwards to at the server end (see
/// dnstt_args.dart). Started by the controller before the
/// tunnel config is handed to the service.
Map<String, dynamic> _dnsttUnderlayOutbound() => {
  'tag': dnsttUnderlayTag,
  'protocol': 'socks',
  'settings': {
    'servers': [
      {'address': '127.0.0.1', 'port': dnsttListenPort},
    ],
  },
};

/// The dedicated outbound the ECH config lookup rides
/// (build 2029A): the core fetches the ECH keys with a DNS
/// query whose socket takes tlsSettings.echSockopt — pointing
/// its dialerProxy here keeps that lookup on a named, direct
/// path under the config's own control instead of the default
/// dialer (whose name resolution is the local network's —
/// exactly the resolver a filtered network poisons).
Map<String, dynamic> _echOutbound() => {
  'tag': echOutboundTag,
  'protocol': 'freedom',
  'settings': {'domainStrategy': 'UseIP'},
};

/// Chains [proxy] through an underlay outbound (build 2029A;
/// generalized in 2030 for the Warp underlay): the proxy
/// outbound's streamSettings.sockopt gains dialerProxy = the
/// underlay tag. When the proxy already dials through a chain
/// outbound (the settings-level TLS fragment chain), THAT
/// outbound is chained instead, so the dial order stays
/// proxy → fragment → underlay → server.
void _chainThroughUnderlay(
  Map<String, dynamic> proxy,
  List<Map<String, dynamic>> outbounds,
  String underlayTag,
) {
  Map<String, dynamic> streamOf(Map<String, dynamic> o) =>
      (o['streamSettings'] as Map?)?.cast<String, dynamic>() ??
      <String, dynamic>{};
  Map<String, dynamic> sockoptOf(Map<String, dynamic> stream) =>
      (stream['sockopt'] as Map?)?.cast<String, dynamic>() ??
      <String, dynamic>{};

  final stream = streamOf(proxy);
  final existing = sockoptOf(stream)['dialerProxy'] as String?;
  if (existing != null) {
    for (final o in outbounds) {
      if (o['tag'] == existing) {
        final os = streamOf(o);
        os['sockopt'] = {...sockoptOf(os), 'dialerProxy': underlayTag};
        o['streamSettings'] = os;
        return;
      }
    }
  }
  stream['sockopt'] = {...sockoptOf(stream), 'dialerProxy': underlayTag};
  proxy['streamSettings'] = stream;
}

void _chainThroughPsiphon(
  Map<String, dynamic> proxy,
  List<Map<String, dynamic>> outbounds,
) => _chainThroughUnderlay(proxy, outbounds, psiphonUnderlayTag);

/// The core's quicParams for a stored Hysteria2 congestion
/// choice (build 2036, queue 2d) plus its client bandwidth
/// (build 2053, audit F-H6): null for the default ('') with no
/// bandwidth, so the emitted config is identical to what older
/// builds produced, and null for anything unrecognised, so a
/// stray stored value can never break a connect — the core
/// rejects an unknown congestion with a config error. The
/// bandwidth rides the same map the congestion does: the
/// bundled core's QuicParamsConfig carries `brutalUp` /
/// `brutalDown` as Bandwidth strings ("N mbps", parsed to
/// bytes/s by infra/conf/transport_method.go Bps), and the
/// hysteria dialer (transport/internet/hysteria/dialer.go)
/// runs Brutal with min(brutalUp, server-advertised down) under
/// the DEFAULT congestion too — no `force-brutal` needed — and
/// sends brutalDown to the server in the auth handshake so the
/// server knows the client's downlink. Values ≤ 0 are simply
/// not emitted (a crafted link with a negative value can never
/// reach the core and break the config the way an unparseable
/// Bandwidth string would).
Map<String, dynamic>? _hyQuicParams(String choice, int upMbps, int downMbps) {
  final params = <String, dynamic>{};
  switch (choice) {
    case 'reno':
      params['congestion'] = 'reno';
    case 'bbr-standard':
      params['congestion'] = 'bbr';
      params['bbrProfile'] = 'standard';
    case 'bbr-conservative':
      params['congestion'] = 'bbr';
      params['bbrProfile'] = 'conservative';
    case 'bbr-aggressive':
      params['congestion'] = 'bbr';
      params['bbrProfile'] = 'aggressive';
    case '':
      break;
    default:
      return null;
  }
  if (upMbps > 0) params['brutalUp'] = '$upMbps mbps';
  if (downMbps > 0) params['brutalDown'] = '$downMbps mbps';
  return params.isEmpty ? null : params;
}

/// The proxy outbound for [p], or null when the core cannot serve it.
///
/// [echDialer]: when the profile's ECH shape is on, the tag
/// the ECH config lookup's socket dials through (build 2029A —
/// [echOutboundTag], or the Psiphon underlay when chained, in
/// which case the lookup rides the underlay tunnel instead of
/// the direct path). Null = no echSockopt is emitted.
Map<String, dynamic>? buildOutbound(
  Profile p,
  XraySettings s, {
  bool fragment = false,
  String? echDialer,
  String fingerprintOverride = '',
}) {
  final out = <String, dynamic>{'tag': 'proxy'};

  Map<String, dynamic> muxPart() =>
      s.muxEnabled &&
          (p.protocol == Protocol.vless ||
              p.protocol == Protocol.vmess ||
              p.protocol == Protocol.trojan ||
              p.protocol == Protocol.shadowsocks)
      ? {
          'mux': {'enabled': true, 'concurrency': s.muxConcurrency},
        }
      : const <String, dynamic>{};

  switch (p.protocol) {
    case Protocol.tuic:
      return null; // No TUIC outbound exists in Xray-core.
    case Protocol.anytls:
      return null; // No AnyTLS outbound exists in Xray-core either
    // (verified in the bundled fork's source, build 2033).
    case Protocol.wireguard:
      final reserved = p.reserved
          .split(',')
          .map((e) => int.tryParse(e.trim()))
          .whereType<int>()
          .toList();
      final wgAddresses = p.localAddress
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      // The .conf's split-tunnel list (build 2057, audit §6 WG
      // .conf divergences): applied to the outbound instead of
      // the old hardcoded full-tunnel — a split-tunnel conf no
      // longer silently becomes full-tunnel. An empty list keeps
      // the old full-tunnel default, as before.
      final wgAllowed = p.wgAllowedIPs
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      out['protocol'] = 'wireguard';
      out['settings'] = {
        'secretKey': p.secretKey,
        'address': wgAddresses.isEmpty ? ['172.16.0.2/32'] : wgAddresses,
        'peers': [
          {
            'publicKey': p.peerPublicKey,
            // IPv6 peer endpoints must be bracketed or the
            // composed string is unparseable (audit, build
            // 2033).
            'endpoint': p.address.contains(':')
                ? '[${p.address}]:${p.port}'
                : '${p.address}:${p.port}',
            if (p.preSharedKey.isNotEmpty) 'preSharedKey': p.preSharedKey,
            if (p.keepAlive > 0) 'keepAlive': p.keepAlive,
            'allowedIPs': wgAllowed.isEmpty ? ['0.0.0.0/0', '::/0'] : wgAllowed,
          },
        ],
        'mtu': p.mtu,
        'noKernelTun': true,
        if (reserved.length == 3) 'reserved': reserved,
      };
      return out;
    case Protocol.hysteria2:
      out['protocol'] = 'hysteria';
      out['settings'] = {'version': 2, 'address': p.address, 'port': p.port};
      // The TLS tricks that apply to a QUIC handshake (build
      // 2033): the mixed-case server name — the same Dart-side
      // reshaping applyAntiFilter does for TCP TLS profiles
      // (Hysteria2 builds its own stream settings, so it is
      // applied here) — and ECH: the core's TLS stack consumes
      // echConfigList generically, the hysteria dialer included
      // (verified in the bundled fork's source).
      final hy2Sni = p.sni.isEmpty ? p.address : p.sni;
      // The certificate pin (build 2053, audit F-H5): the core's
      // TLSConfig has exactly one pin field,
      // `pinnedPeerCertSha256` (infra/conf/transport_security.go)
      // — there is NO `pinSHA256` key anywhere in the core, so
      // the old emission was silently dropped by the conf loader
      // and a pinned profile verified like an unpinned one. The
      // pin lives in p.tlsCertPin (the same field the TLS
      // profiles use, validated by isValidTlsCertPin); a legacy
      // profile that still carries the pin in `fingerprint`
      // (pre-2053 imports) is honoured at emit time so the
      // control is never silently lost, and the editor migrates
      // it into tlsCertPin on the next edit.
      final hyPin = isValidTlsCertPin(p.tlsCertPin)
          ? p.tlsCertPin
          : (isValidTlsCertPin(p.fingerprint) ? p.fingerprint : '');
      final stream = <String, dynamic>{
        'network': 'hysteria',
        'security': 'tls',
        'tlsSettings': {
          'serverName': p.afMixedSni && hy2Sni.isNotEmpty
              ? mixCaseSni(hy2Sni)
              : hy2Sni,
          // No allowInsecure (build 2048): the core removed it
          // outright and refuses the whole config when the key
          // is set — a Hysteria2 profile that used to skip the
          // check now verifies normally, or pins (see above).
          'alpn': ['h3'],
          if (hyPin.isNotEmpty) 'pinnedPeerCertSha256': hyPin,
          if (p.echConfigList.isNotEmpty) 'echConfigList': p.echConfigList,
        },
        'hysteriaSettings': {'version': 2, 'auth': p.uuidOrPassword},
        // Build 2049: Hysteria2 builds its own stream settings,
        // so the IPv4-only server-dial strategy (see
        // _streamSettings) is stamped here too.
        'sockopt': {'domainStrategy': 'UseIPv4'},
      };
      stream.removeWhere((k, v) => v == null);
      (stream['hysteriaSettings'] as Map).removeWhere((k, v) => v == null);
      // Congestion control (build 2036, queue 2d) rides the
      // same finalmask the salamander obfs uses: the patched
      // core reads quicParams from streamSettings.finalmask and
      // hands it to the hysteria dialer ('reno' takes the
      // transport default, 'bbr' + a profile runs BBR with that
      // profile). Both entries merge into one finalmask object;
      // with neither set there is no finalmask key at all, so a
      // default profile's config is unchanged from older builds.
      final finalmask = <String, dynamic>{};
      if (p.obfs == 'salamander') {
        finalmask['udp'] = [
          {
            'type': 'salamander',
            'settings': {'password': p.obfsPassword},
          },
        ];
      }
      final quicParams = _hyQuicParams(p.hyCongestion, p.upMbps, p.downMbps);
      if (quicParams != null) finalmask['quicParams'] = quicParams;
      if (finalmask.isNotEmpty) stream['finalmask'] = finalmask;
      out['streamSettings'] = stream;
      return out;
    case Protocol.vless:
      out['protocol'] = 'vless';
      out['settings'] = {
        'vnext': [
          {
            'address': p.address,
            'port': p.port,
            'users': [
              {
                'id': p.uuidOrPassword,
                // VLESS Encryption (build 2046): the value is
                // emitted verbatim when set and valid; the core
                // REQUIRES the field be present, so anything
                // else — including a corrupt stored value —
                // becomes 'none', exactly the pre-2046 shape.
                'encryption': isValidVlessEncryption(p.vlessEncryption)
                    ? p.vlessEncryption
                    : 'none',
                if (p.flow.isNotEmpty) 'flow': p.flow,
                'level': 0,
              },
            ],
          },
        ],
      };
      out['streamSettings'] = _streamSettings(p, fingerprintOverride: fingerprintOverride);
      out.addAll(muxPart());
    case Protocol.vmess:
      out['protocol'] = 'vmess';
      out['settings'] = {
        'vnext': [
          {
            'address': p.address,
            'port': p.port,
            'users': [
              {
                'id': p.uuidOrPassword,
                // VMess aid/scy (build 2057, audit §6 codec
                // drop): the stored values — the old hardcoded
                // `alterId: 0, security: 'auto'` failed
                // non-zero-alterId servers silently and never
                // honoured a non-auto cipher. 0 / '' keep the
                // old defaults, so older profiles build exactly
                // as before.
                'alterId': p.aid,
                'security': p.scy.isNotEmpty ? p.scy : 'auto',
                'level': 0,
              },
            ],
          },
        ],
      };
      out['streamSettings'] = _streamSettings(p, fingerprintOverride: fingerprintOverride);
      out.addAll(muxPart());
    case Protocol.trojan:
      out['protocol'] = 'trojan';
      out['settings'] = {
        'servers': [
          {
            'address': p.address,
            'port': p.port,
            'password': p.uuidOrPassword,
            'level': 0,
          },
        ],
      };
      out['streamSettings'] = _streamSettings(p, fingerprintOverride: fingerprintOverride);
      out.addAll(muxPart());
    case Protocol.shadowsocks:
      out['protocol'] = 'shadowsocks';
      out['settings'] = {
        'servers': [
          {
            'address': p.address,
            'port': p.port,
            'method': p.method,
            'password': p.uuidOrPassword,
            'uot': s.enableUdp,
            'level': 0,
          },
        ],
      };
      // Build 2049: shadowsocks has no stream layer of its own
      // here, but its server dial needs the same IPv4-only
      // strategy (see _streamSettings). A sockopt-only stream
      // settings is valid — the core defaults the network to
      // tcp (infra/conf StreamConfig.Build).
      out['streamSettings'] = {
        'sockopt': {'domainStrategy': 'UseIPv4'},
      };
      if (p.plugin.isNotEmpty) {
        // The plugin is NOT applied (build 2057, audit F-M11):
        // the bundled core has no plugin support — there is no
        // field in its shadowsocks settings for an obfs-local
        // plugin — so forcing the string into the config would
        // only break the load. The profile is badged in the UI
        // (see hasUnsupportedPlugin) and the connect path
        // journals the fact, so an `obfs-local` link that
        // imports cleanly never fails the handshake silently.
        // Implementing it would mean shipping a plugin runner
        // the core cannot drive — out of scope for a fix build.
      }
      out.addAll(muxPart());
    case Protocol.socks:
      // Xray's native SOCKS outbound: settings.servers with an
      // optional users array (user/pass — different field names from
      // the trojan/shadowsocks "password"). No stream layer.
      out['protocol'] = 'socks';
      out['settings'] = {
        'servers': [
          {
            'address': p.address,
            'port': p.port,
            // A password-only profile still emits its users
            // array (build 2057, audit §6 codec drop): the old
            // username-only guard dropped the password.
            if (p.username.isNotEmpty || p.uuidOrPassword.isNotEmpty)
              'users': [
                {'user': p.username, 'pass': p.uuidOrPassword},
              ],
          },
        ],
      };
      // Build 2049: same IPv4-only server-dial strategy as the
      // shadowsocks case above — a sockopt-only stream settings.
      out['streamSettings'] = {
        'sockopt': {'domainStrategy': 'UseIPv4'},
      };
    case Protocol.http:
      // HTTP proxy outbound (build 2057, audit §6 codec drop):
      // Xray's native HTTP outbound — the same server/user
      // shape as SOCKS, with the same IPv4-only dial strategy.
      out['protocol'] = 'http';
      out['settings'] = {
        'servers': [
          {
            'address': p.address,
            'port': p.port,
            // A password-only profile still emits its users
            // array (build 2057, audit §6 codec drop): the old
            // username-only guard dropped the password.
            if (p.username.isNotEmpty || p.uuidOrPassword.isNotEmpty)
              'users': [
                {'user': p.username, 'pass': p.uuidOrPassword},
              ],
          },
        ],
      };
      out['streamSettings'] = {
        'sockopt': {'domainStrategy': 'UseIPv4'},
      };
  }

  // ECH through the dedicated outbound (build 2029A): only
  // when the ECH shape actually produced an echConfigList on
  // this outbound's TLS settings.
  if (echDialer != null) {
    final stream = (out['streamSettings'] as Map?)?.cast<String, dynamic>();
    final tls = stream?['tlsSettings'];
    if (tls is Map && tls['echConfigList'] != null) {
      tls['echSockopt'] = {'dialerProxy': echDialer};
    }
  }

  if (fragment) {
    final stream =
        (out['streamSettings'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    // Merged, never assigned over (build 2030): the stream may
    // already carry the profile's dialMode in the same map.
    final sock =
        (stream['sockopt'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    sock['dialerProxy'] = 'frag';
    stream['sockopt'] = sock;
    out['streamSettings'] = stream;
  }
  return out;
}

/// The freedom dialer chain behind the global fragment toggle
/// and the per-profile TCP-noise option (build 2026, Stage A).
/// With [noise], the chain also prepends random padding packets
/// to each connection (the freedom "noises"): random 50–100 byte
/// packets, 10–16 ms apart — the values v2rayNG ships for the
/// same feature. The two halves are independent: a noise-only
/// profile chains through a freedom outbound that carries the
/// noises and NO fragment block, so opting into noise alone
/// never silently fragments.
Map<String, dynamic> _fragmentOutbound(
  XraySettings s, {
  bool noise = false,
  bool fragment = true,
  String dialMode = '',
}) => {
  'tag': 'frag',
  'protocol': 'freedom',
  'settings': {
    if (fragment)
      'fragment': {
        'packets': s.fragmentPackets,
        'length': s.fragmentLength.toString(),
        'interval': s.fragmentInterval.toString(),
      },
    if (noise)
      'noises': [
        {'type': 'rand', 'packet': '50-100', 'delay': '10-16'},
      ],
  },
  'streamSettings': {
    'network': 'tcp',
    'security': 'none',
    // The frag hop is the one that really dials when the
    // fragment chain is in play, so the profile's dialMode
    // rides it too (build 2030) — the same text the proxy
    // outbound's own sockopt carries when unchained. Build
    // 2049 adds the IPv4-only server-dial strategy for the
    // same reason: this hop dials the server.
    'sockopt': {
      'tcpNoDelay': true,
      'domainStrategy': 'UseIPv4',
      if (dialMode.isNotEmpty) 'dialMode': dialMode,
    },
  },
};

/// The public-DNS host pins v2rayNG hardcodes into every
/// generated config (its AppConfig DNS_*_ADDRESSES tables): the
/// well-known DoH endpoints resolve to these IPs without asking
/// any resolver, so the remote resolver is reachable before —
/// and independently of — any local DNS.
const _dnsHostPins = <String, List<String>>{
  'dns.google': ['8.8.8.8', '8.8.4.4'],
  'cloudflare-dns.com': ['104.16.248.249', '104.16.249.249'],
  'one.one.one.one': ['1.1.1.1', '1.0.0.1'],
  '1dot1dot1dot1.cloudflare-dns.com': ['1.1.1.1', '1.0.0.1'],
  'dns.quad9.net': ['9.9.9.9', '149.112.112.112'],
  'dns.alidns.com': ['223.5.5.5', '223.6.6.6'],
  'doh.dns.sb': ['185.222.222.222', '45.11.45.11'],
  'dns.adguard-dns.com': ['94.140.14.14', '94.140.15.15'],
};

/// AdGuard's filtering DoH (build 2030): the ad-block preset's
/// resolver. Blocked domains are answered with a null route
/// there — resolution-level filtering, no geosite.dat.
const adGuardDohUrl = 'https://dns.adguard-dns.com/dns-query';

/// The shipped default remote resolver (the initializer of
/// XraySettings.remoteDns in xray_models.dart). Build 2049's
/// built-in DNS fallback engages only while this default is
/// still in place — any explicit user choice replaces it.
const defaultRemoteDns = 'https://dns.google/dns-query';

/// The tunnel's DNS, realigned to v2rayNG's generated configs in
/// 2024 after a side-by-side diff against the current v2rayNG
/// source (the 2005 alignment had drifted from it):
///
/// - The remote resolver — a public DoH by default — answers
///   EVERY name, including the proxy server's own domain. 2005
///   scoped the server domain and the DoH host to the LOCAL
///   resolver as a "bootstrap"; v2rayNG has no such entry — the
///   core resolves the outbound's address through this same DNS
///   section, whose DoH queries are dialed directly to the
///   hosts-pinned endpoint. On a filtered network the local
///   resolver is exactly the poisoned one, so the 2005 scoping
///   sent the most important lookup of all — the server's own
///   address — to the resolver least likely to answer it
///   honestly. That is the plausible mechanism behind "some
///   configs never connect in Ember but work in v2rayNG": the
///   ones whose server domains the local resolver poisons.
/// - No queryStrategy: v2rayNG's DnsBean leaves it null, so the
///   core default (UseIP) applies. (2005's "v2rayNG's fixed
///   UseIPv4" described an older v2rayNG.) — REVERSED in build
///   2049 on the owner's device evidence: with UseIP the core
///   took AAAA answers for the proxy server's own hostname and
///   dialed it over IPv6, which his carrier resets (EOF), and
///   every redial could land there again. The DNS section now
///   carries queryStrategy UseIPv4 (see _dnsSection), so the
///   core's resolver only ever returns A answers — for the
///   server bootstrap and for proxied lookups alike. Literal
///   IPv6 destinations are unaffected (they are never
///   resolved), and the outbound sockopt strategy in
///   _streamSettings pins the server dial itself the same way.
/// - A custom remote-DNS host outside the pins table resolves
///   the way it does in v2rayNG: through the core's own handling
///   of the DoH endpoint, with no local-DNS detour.
/// The DoQ (DNS-over-QUIC) form of a DoH resolver URL (build
/// 2032, corrected in build 2053, audit F-H4): the well-known
/// providers answer QUIC on the same service — but the bundled
/// core dispatches ONLY the `quic+local` scheme
/// (app/dns/nameserver.go NewServer: `quic+local` →
/// NewQUICNameServer; there is NO `quic` case). The 2032 form
/// `quic://<host>` therefore fell through to the classic UDP
/// server against a host literally named `quic://…` — a second
/// route to total DNS failure, and `xray run -test` never
/// instantiates the DNS client, so it validated green. The
/// `+local` half is load-bearing and honest: the QUIC dial is
/// local egress — the query leaves the device directly, NOT
/// through the tunnel — so on a filtered network it may fail
/// where DoH/TCP (tunneled) succeed; the Settings page says so
/// next to the chip, and the 2049 TCP fallback still rides
/// behind the default resolver. A custom DoH URL maps to
/// quic+local://<its host> — the standard DoQ port is implied
/// by the core.
String doqFormOf(String dohUrl) {
  switch (dohUrl) {
    case 'https://dns.google/dns-query':
      return 'quic+local://dns.google';
    case 'https://cloudflare-dns.com/dns-query':
    case 'https://1.1.1.1/dns-query':
    case 'https://1.0.0.1/dns-query':
      return 'quic+local://one.one.one.one';
    case 'https://dns.quad9.net/dns-query':
      return 'quic+local://dns.quad9.net';
    case 'https://dns.adguard-dns.com/dns-query':
      return 'quic+local://dns.adguard-dns.com';
  }
  final uri = Uri.tryParse(dohUrl);
  if (uri != null && uri.host.isNotEmpty) return 'quic+local://${uri.host}';
  return dohUrl;
}

/// The config's primary resolver under the transport choice.
String primaryResolver(XraySettings s) {
  final base = s.adBlockDoh ? adGuardDohUrl : s.remoteDns;
  if (s.remoteDnsProto == 'doq') return doqFormOf(base);
  if (s.remoteDnsProto == 'tcp') return tcpFormOf(base);
  return base;
}

/// The Cloudflare DoH host's pins are its HTTPS frontend IPs,
/// not its resolver — plain DNS on TCP/53 there would go nowhere
/// — so that host maps to the resolver 1.1.1.1 instead. Every
/// other pinned host pins its resolver IP directly.
const _tcpResolverIpOverride = <String, String>{
  'cloudflare-dns.com': '1.1.1.1',
};

/// The DNS-over-TCP form of a DoH resolver URL (build 2037,
/// Iran-priority queue 2e): the well-known providers answer plain
/// DNS on TCP port 53 at their pinned IPs, so the mapping is
/// host-based — a pinned host becomes `tcp://` plus its first
/// pinned IP (no hostname, no SNI, nothing to resolve or
/// filter), and a custom host becomes `tcp://` plus its host,
/// resolved through the tunnel the same way DoQ's generic form
/// is. The core speaks
/// tcp:// nameservers (bundled Xray-core v26.10.29,
/// app/dns/nameserver.go NewServer -> NewTCPNameServer, remote
/// mode dialed through the dispatcher, RFC 7766, port 53
/// default); it does NOT speak tls:// (DoT) — that scheme is
/// absent from this core's NewServer switch — so TCP is the
/// honest third transport. Idempotent on an already-tcp:// URL,
/// and an unparseable input passes through unchanged.
String tcpFormOf(String dohUrl) {
  final uri = Uri.tryParse(dohUrl);
  final host = uri?.host ?? '';
  if (host.isEmpty) return dohUrl;
  final override = _tcpResolverIpOverride[host];
  if (override != null) return 'tcp://$override';
  final pins = _dnsHostPins[host];
  if (pins != null && pins.isNotEmpty) return 'tcp://${pins.first}';
  return 'tcp://$host';
}

/// A resolver URL under the transport choice (build 2037): the
/// same mapping the primary goes through, for group members, the
/// fallback, and the Settings display line. DoH passes through;
/// anything unrecognised falls back to DoH, so a stray stored
/// value can never break a connect.
String resolverUnderTransport(String url, String proto) {
  if (proto == 'doq') return doqFormOf(url);
  if (proto == 'tcp') return tcpFormOf(url);
  return url;
}

/// The DNS group's member resolvers (build 2033), in the
/// order the core works them after the primary: the three
/// well-known public DoH endpoints. Every member is encrypted
/// and reached through the tunnel (the DNS section's hosts
/// pins make the endpoints resolvable before the tunnel DNS
/// exists), so the group's answers never come from the local
/// network's resolver.
const dnsGroupMembers = <String>[
  'https://dns.google/dns-query',
  'https://cloudflare-dns.com/dns-query',
  'https://dns.quad9.net/dns-query',
];

Map<String, dynamic> _dnsSection(XraySettings s, Profile p) {
  final servers = <dynamic>[];
  if (s.fakeDns) servers.add('fakedns');
  // Build 2030 (the plan-check's split, isolated to this one
  // function): the ad-block preset swaps the primary resolver
  // for AdGuard's filtering DoH. It ANSWERS blocked domains
  // (with a null route) rather than failing them, so the
  // fallback appended after it only ever sees genuine
  // resolution failures of the primary — the two policies
  // cannot fight.
  final primary = primaryResolver(s);
  servers.add(primary);
  if (s.dnsGroup) {
    // Build 2033: the group supersedes the single fallback.
    // Members the transport choice transforms (DoQ, and TCP
    // since 2037) are mapped like the primary; duplicates of
    // the primary and repeats are dropped, order preserved.
    for (final member in dnsGroupMembers) {
      final mapped = resolverUnderTransport(member, s.remoteDnsProto);
      if (!servers.contains(mapped)) servers.add(mapped);
    }
  } else {
    // Build 2037: the fallback is mapped through the transport
    // too, so TCP mode stays pure TCP; the comparison is
    // mapped-to-mapped, so a fallback on the same provider as
    // the primary is dropped instead of duplicated (the old
    // raw-to-mapped check could double-add it under DoQ/TCP).
    final fallback = s.fallbackDns.trim();
    if (s.dnsFallback && fallback.isNotEmpty) {
      final mapped = resolverUnderTransport(fallback, s.remoteDnsProto);
      if (mapped != primary) servers.add(mapped);
    }
  }
  // Build 2049: in the shipped default shape the primary above
  // was the ONLY resolver — one DoH through the tunnel — and
  // when its POSTs timed out (the owner's log, 2026-11-14:
  // "context deadline exceeded" for nearly every name, with
  // Google and then identically with Cloudflare) all browsing
  // stalled while IP-direct apps (Telegram, Instagram) kept
  // working. A bounded built-in fallback now rides along whenever
  // there is no DNS group, no user fallback, no ad-block
  // resolver, and the remote resolver is the default one — that
  // is the condition below, and it deliberately does NOT exclude
  // fakeDNS or the transport choice (DoQ/TCP): the fallback is a
  // plain TCP query to a pinned IP, so it rides any resolver
  // shape, and the DoQ path relies on it (its primary is
  // local-egress, so the TCP fallback is the only tunnel-routed
  // answer when the direct query fails). The core works the
  // server list in order, so it answers only when the primary
  // fails. Any explicit user choice — a custom remote resolver,
  // the ad-block resolver, the DNS group, or their own fallback —
  // leaves the section exactly as it was before this build. The
  // fallback's own endpoint is an IP literal from the pins table,
  // so it can never loop back into resolving the proxy server's
  // hostname (the bootstrap above stays as-is).
  if (!s.dnsGroup &&
      !s.dnsFallback &&
      !s.adBlockDoh &&
      s.remoteDns.trim() == defaultRemoteDns) {
    final builtinFallback = tcpFormOf('https://dns.quad9.net/dns-query');
    if (!servers.contains(builtinFallback)) servers.add(builtinFallback);
  }
  // Build 2041: the user's own host entries merge into the DNS
  // section's hosts map — a user entry wins over the built-in
  // resolver pins for the same domain, and an invalid stored
  // entry never reaches the config (validDnsHosts is the final
  // gate, so a corrupt store cannot break a connect). The
  // single-IP value is emitted as a one-element list, the same
  // shape as the built-in pins, which the core's HostAddress
  // accepts alongside plain strings.
  final hosts = <String, List<String>>{..._dnsHostPins};
  for (final entry in validDnsHosts(s.customDnsHosts).entries) {
    hosts[entry.key] = [entry.value];
  }
  return {
    'hosts': hosts,
    'servers': servers,
    'tag': 'dns-in',
    // Build 2049 (see the reversal note on _dnsSection above):
    // the core's resolver returns A answers only, so nothing
    // it resolves — the proxy server's hostname first of all —
    // can be dialed over the owner's broken IPv6 path.
    'queryStrategy': 'UseIPv4',
  };
}

/// v2rayNG's direct (freedom) outbound: it carries the sockopt
/// below in both of its template configs; Ember's was bare until
/// 2024. UseIP + happy eyeballs govern how DIRECT traffic (and
/// the core's own direct dials) resolve and race addresses.
Map<String, dynamic> _directOutbound() => {
  'tag': 'direct',
  'protocol': 'freedom',
  'settings': <String, dynamic>{},
  'streamSettings': {
    'sockopt': {
      'domainStrategy': 'UseIP',
      'happyEyeballs': {'tryDelayMs': 250, 'interleave': 2},
    },
  },
};

/// Rules from the preset + the user's custom lists.
List<Map<String, dynamic>> _routingRules(XraySettings s) {
  final rules = <Map<String, dynamic>>[
    {
      'type': 'field',
      'inboundTag': ['socks', 'http'],
      'port': '53',
      'network': 'udp',
      'outboundTag': 'dns-out',
    },
  ];
  Map<String, dynamic> rule({
    List<String>? domains,
    List<String>? ips,
    String out = 'direct',
  }) => {
    'type': 'field',
    if (domains != null && domains.isNotEmpty) 'domain': domains,
    if (ips != null && ips.isNotEmpty) 'ip': ips,
    'outboundTag': out,
  };

  if (s.customBlockDomains.isNotEmpty) {
    rules.add(rule(domains: s.customBlockDomains, out: 'block'));
  }
  if (s.customProxyDomains.isNotEmpty) {
    rules.add(rule(domains: s.customProxyDomains, out: 'proxy'));
  }
  if (s.customDirectDomains.isNotEmpty) {
    rules.add(rule(domains: s.customDirectDomains));
  }
  if (s.customDirectIps.isNotEmpty) {
    rules.add(rule(ips: s.customDirectIps));
  }
  switch (s.routingPreset) {
    case RoutingPreset.global:
      break; // Everything else falls to the proxy (first outbound).
    case RoutingPreset.directAll:
      rules.add({
        'type': 'field',
        'network': 'tcp,udp',
        'outboundTag': 'direct',
      });
    case RoutingPreset.bypassLan:
      rules.add(rule(ips: ['geoip:private']));
    case RoutingPreset.bypassIran:
      rules.add(rule(ips: ['geoip:private', 'geoip:ir']));
      rules.add(rule(domains: ['geosite:ir']));
  }
  return rules;
}

/// The loopback port of the core's local stats API inbound in the
/// tunnel config. Derived from the SOCKS port so it follows the user's
/// port setting and stays clear of the SOCKS/HTTP pair. The
/// Settings input and [XraySettings.fromJson] both enforce
/// socksPort ≤ 60535 (build 2057, audit F-M2), so the derived
/// port fits in 1–65535; the fallback below is defence in depth
/// for a store written by an older build that bypassed the
/// validation — it lands on the default stats port instead of
/// an out-of-range one the core would refuse.
int statsApiPort(XraySettings s) {
  final p = s.socksPort + 5000;
  return p <= 65535 ? p : 15808;
}

List<Map<String, dynamic>> _inbounds(XraySettings s) {
  // LAN sharing (build 2062, feature queue #2): sharing on
  // listens on 0.0.0.0 so other devices on the local network
  // reach the proxy; off is the 127.0.0.1 of every earlier
  // build. Auth-ready means password auth + accounts on BOTH
  // inbounds (the HTTP inbound tolerates the 'auth' key and
  // needs 'accounts' for Basic auth); anything else is
  // today's noauth with no accounts.
  final listen = s.lanShareEnabled ? '0.0.0.0' : '127.0.0.1';
  Map<String, dynamic> inbound(String tag, String protocol, int port) => {
    'tag': tag,
    'listen': listen,
    'port': port,
    'protocol': protocol,
    'sniffing': {
      'enabled': s.sniffing,
      // v2rayNG's default set (2005): http + tls + quic, so
      // domain-based handling also sees QUIC handshakes.
      'destOverride': ['http', 'tls', 'quic', if (s.fakeDns) 'fakedns'],
      'metadataOnly': false,
      'routeOnly': false,
    },
    'settings': {
      'auth': s.lanShareAuthReady ? 'password' : 'noauth',
      if (s.lanShareAuthReady)
        'accounts': [
          {'user': s.lanShareUser, 'pass': s.lanSharePass},
        ],
      'udp': s.enableUdp,
      'allowTransparent': false,
    },
  };
  return [
    inbound('socks', 'socks', s.socksPort),
    inbound('http', 'http', s.httpPort),
  ];
}

/// The tunnel config: [tunPort] is never used (the TUN side lives in
/// the tun2socks subprocess); both inbounds are always present.
///
/// [psiphonUnderlay] (build 2029A): the session is chained —
/// the Psiphon core is already running proxy-only, and the
/// proxy outbound dials through it (see _chainThroughPsiphon).
/// The ECH lookup, when the profile shapes it, rides the
/// underlay too instead of the direct dedicated outbound.
///
/// [warpUnderlay] (build 2030): the same chain over the
/// EmberWarp core, with the core's egress returning through
/// the inline secondary inbound and leaving through the
/// exit-node (see _warpExitOutbound). [warp] is the warp
/// profile whose finalMask/dialMode the exit-node carries.
///
/// [dnsttUnderlay] (build 2072): the same chain over the
/// DNSTT client (see _dnsttUnderlayOutbound).
///
/// [wgWstunnelPort] (build 2072): when > 0 and the profile is
/// WireGuard, the peer endpoint in the built config points at
/// the local wstunnel forwarder instead of the real endpoint
/// — the stored profile is never rewritten; the forwarder
/// dials the real endpoint from the server side.
String buildTunnelConfig(
  Profile p,
  XraySettings s, {
  bool psiphonUnderlay = false,
  bool warpUnderlay = false,
  WarpProfile? warp,
  bool dnsttUnderlay = false,
  int wgWstunnelPort = 0,
}) {
  final echDialer = p.afEch
      ? (warpUnderlay
            ? warpUnderlayTag
            : psiphonUnderlay
            ? psiphonUnderlayTag
            : dnsttUnderlay
            ? dnsttUnderlayTag
            : echOutboundTag)
      : null;
  final outbound = buildOutbound(
    p,
    s,
    fragment: s.fragmentEnabled || p.afTcpNoise,
    echDialer: echDialer,
    // Build 2065 (item 13): rotation fills an empty fingerprint
    // from the settings cursor; the cursor advances once per
    // user connect in XrayController, not per config build.
    fingerprintOverride: effectiveFingerprint(
      p,
      s,
      rotationIndex: s.tlsFingerprintIndex,
    ),
  );
  if (outbound == null) {
    throw StateError('protocol not supported by the core: ${p.protocol}');
  }
  // WireGuard over WebSocket (build 2072): the session's
  // config points the peer at the local wstunnel forwarder;
  // the stored profile keeps the real endpoint.
  if (wgWstunnelPort > 0 && p.protocol == Protocol.wireguard) {
    final peers = (outbound['settings'] as Map?)?['peers'];
    if (peers is List && peers.isNotEmpty && peers.first is Map) {
      (peers.first as Map)['endpoint'] = '127.0.0.1:$wgWstunnelPort';
    }
  }
  final extraOutbounds = <Map<String, dynamic>>[
    _directOutbound(),
    {
      'tag': 'block',
      'protocol': 'blackhole',
      'settings': {
        'response': {'type': 'http'},
      },
    },
    {
      'tag': 'dns-out',
      'protocol': 'dns',
      'settings': {'nonIPQuery': 'skip'},
    },
    if (s.fragmentEnabled || p.afTcpNoise)
      _fragmentOutbound(
        s,
        noise: p.afTcpNoise,
        fragment: s.fragmentEnabled,
        dialMode: p.dialMode,
      ),
  ];
  if (echDialer == echOutboundTag) extraOutbounds.add(_echOutbound());
  if (psiphonUnderlay) {
    _chainThroughPsiphon(outbound, extraOutbounds);
    extraOutbounds.add(_psiphonUnderlayOutbound());
  }
  if (dnsttUnderlay) {
    _chainThroughUnderlay(outbound, extraOutbounds, dnsttUnderlayTag);
    extraOutbounds.add(_dnsttUnderlayOutbound());
  }
  if (warpUnderlay) {
    _chainThroughUnderlay(outbound, extraOutbounds, warpUnderlayTag);
    extraOutbounds.add(_warpUnderlayOutbound());
    extraOutbounds.add(_warpExitOutbound(warp ?? WarpProfile()));
  }
  // Config mixins (build 2043): the user's own JSON object is
  // merged into the finished config LAST, after every generated
  // section — maps recurse, lists append (the api-first routing
  // rule stays first), scalars replace. The merge runs on a
  // JSON deep copy so nested maps are all Map<String, dynamic>
  // and a mixin value can never throw on assignment. An invalid
  // stored text is skipped, never trusted — a corrupt store
  // cannot break a connect. The test config is deliberately
  // untouched: it is a throwaway shape for measuring one
  // outbound, and a mixin there could break Test All.
  final config = <String, dynamic>{
    'log': {'loglevel': 'warning'},
    // The core's own statistics: the per-config traffic totals are
    // read from the "proxy" outbound counters through this local API.
    'stats': <String, dynamic>{},
    'api': {
      'tag': 'api',
      'services': ['StatsService'],
    },
    'dns': _dnsSection(s, p),
    if (s.fakeDns)
      'fakedns': [
        {'ipPool': '198.18.0.0/15', 'poolSize': 65535},
      ],
    'inbounds': [
      ..._inbounds(s),
      {
        'tag': 'api',
        'listen': '127.0.0.1',
        'port': statsApiPort(s),
        'protocol': 'dokodemo-door',
        'settings': {'address': '127.0.0.1'},
      },
      // The warp chain's return path (build 2030): the core's
      // egress enters here and leaves through the exit-node.
      if (warpUnderlay) _warpSecondaryInbound(),
    ],
    'outbounds': [outbound, ...extraOutbounds],
    'routing': {
      'domainStrategy': s.domainStrategy,
      'rules': [
        // The stats API inbound is served by the core itself; this
        // rule must stay ahead of every preset/custom rule.
        {
          'type': 'field',
          'inboundTag': ['api'],
          'outboundTag': 'api',
        },
        // The warp exit rule is FIRST among the routing rules
        // (build 2030): the secondary inbound's traffic is the
        // underlay core's own egress and must never fall into
        // the preset rules below.
        if (warpUnderlay)
          {
            'type': 'field',
            'inboundTag': [warpSecondaryTag],
            'outboundTag': warpExitTag,
          },
        ..._routingRules(s),
      ],
    },
    'policy': {
      'levels': {
        '0': {'statsUserUplink': false, 'statsUserDownlink': false},
      },
      'system': {
        'statsInboundUplink': false,
        'statsInboundDownlink': false,
        'statsOutboundUplink': true,
        'statsOutboundDownlink': true,
      },
    },
  };
  final mixins = mixinsFromStoredText(s.configMixins);
  if (mixins != null) {
    // A JSON deep copy first: the literal above infers narrower
    // nested map types (Map<String, String>, Map<String, bool>),
    // and a mixin value assigned into one of those would throw.
    // The copy is all Map<String, dynamic>, so the merge is safe.
    final merged = jsonDecode(jsonEncode(config)) as Map<String, dynamic>;
    return prettyJson(applyConfigMixins(merged, mixins));
  }
  return prettyJson(config);
}

/// The test config: one SOCKS inbound on port 0 — the native tester
/// substitutes the real port before starting the throwaway core.
String buildTestConfig(Profile p, XraySettings s) {
  final outbound = buildOutbound(
    p,
    s,
    fragment: s.fragmentEnabled || p.afTcpNoise,
    echDialer: p.afEch ? echOutboundTag : null,
  );
  if (outbound == null) {
    throw StateError('protocol not supported by the core: ${p.protocol}');
  }
  return prettyJson({
    'log': {'loglevel': 'none'},
    // The same DNS section as the tunnel config (2024): the
    // delay/speed tests must resolve the server's domain through
    // the same path the tunnel uses — v2rayNG's test configs go
    // through its full config manager too. Before, the test
    // config had no DNS section at all, so a profile could pass
    // its delay test and still fail in the tunnel (or the other
    // way round) purely on resolution.
    'dns': _dnsSection(s, p),
    'inbounds': [
      {
        'tag': 'socks',
        'listen': '127.0.0.1',
        'port': 0,
        'protocol': 'socks',
        'settings': {'auth': 'noauth', 'udp': false},
      },
    ],
    'outbounds': [
      outbound,
      _directOutbound(),
      if (s.fragmentEnabled || p.afTcpNoise)
        _fragmentOutbound(
          s,
          noise: p.afTcpNoise,
          fragment: s.fragmentEnabled,
          dialMode: p.dialMode,
        ),
      if (p.afEch) _echOutbound(),
    ],
  });
}
