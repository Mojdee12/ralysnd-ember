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
import 'dart:io' show InternetAddress;

import 'anti_filter.dart';
import 'config_mixins.dart';
import 'dns_hosts.dart';
import 'dnstt_args.dart';
import 'olcrtc_args.dart';
import 'tls_cert_pin.dart';
import 'vless_encryption.dart';
import 'warp_args.dart';
import 'xray_models.dart';
import 'zapret_args.dart';

String prettyJson(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);

/// Build 2125 (audit A25-33 / P-38): the compact emission
/// for CORE-BOUND configs (tunnel, test, sidecar). Up to
/// 2124 every connect/switch/test serialised the full
/// config pretty-printed — roughly a third larger, on the
/// connect path's critical section. Nothing human reads
/// these strings (they are written for the cores and the
/// validator); user-facing exports keep prettyJson.
String compactJson(Object? value) => jsonEncode(value);

/// Decodes a stored JSON-object text (build 2116): the
/// XHTTP `extra` and the per-transport headers a profile
/// carries as JSON text. A value that is not a JSON
/// object reads as null — a corrupt store can never
/// break a connect over it.
Map<String, dynamic>? storedJsonObject(String text) {
  if (text.isEmpty) return null;
  try {
    final v = jsonDecode(text);
    return v is Map ? v.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

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
  // Build 2096 (post-2095 audit M1): REALITY loads only
  // on the TCP-family transports; over QUIC/KCP the core
  // refuses the pairing. The profile keeps the security
  // its source carried (the import boundary no longer
  // rewrites it silently); the substitution to TLS
  // happens HERE, at emit time, and the connect path
  // journals it via Profile.hasRealityTransportMismatch.
  final security = p.hasRealityTransportMismatch ? 'tls' : p.security;
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
      // Extra per-transport headers (build 2116, audit
      // G-17): the source config's headers map beyond Host,
      // which lives in [Profile.host] and is merged back
      // here (and wins — it is the field the editor edits).
      final wsHeaders = <String, dynamic>{
        ...?storedJsonObject(p.transportHeaders),
        if (p.host.isNotEmpty) 'Host': p.host,
      };
      if (wsHeaders.isNotEmpty) ws['headers'] = wsHeaders;
      // WS early data (build 2116, audit G-03): the link's
      // `ed` count, with the header name every Xray WS
      // early-data deployment uses.
      if (p.wsEarlyData > 0) {
        ws['maxEarlyData'] = p.wsEarlyData;
        ws['earlyDataHeaderName'] = 'Sec-WebSocket-Protocol';
      }
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
      // Extra per-transport headers (build 2116, G-17).
      final httpHeaders = storedJsonObject(p.transportHeaders);
      if (httpHeaders != null && httpHeaders.isNotEmpty) {
        h['headers'] = httpHeaders;
      }
      stream['httpSettings'] = h;
    case 'httpupgrade':
      final hu = <String, dynamic>{'path': p.path.isEmpty ? '/' : p.path};
      if (p.host.isNotEmpty) hu['host'] = p.host;
      // Extra per-transport headers (build 2116, G-17).
      final huHeaders = storedJsonObject(p.transportHeaders);
      if (huHeaders != null && huHeaders.isNotEmpty) {
        hu['headers'] = huHeaders;
      }
      stream['httpupgradeSettings'] = hu;
    case 'xhttp':
    case 'splithttp':
      // XHTTP `extra` (build 2116, audit G-02): the stored
      // object merges UNDER the explicit fields — a link's
      // downloadSettings / xmux / padding keys land whole,
      // while path/mode/host stay the profile's own (the
      // fields the editor edits). A value that is not a
      // JSON object is ignored, never fatal.
      final x = <String, dynamic>{
        ...?storedJsonObject(p.xhttpExtra),
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
      } else if (p.tcpHeaderType != null) {
        // TCP header camouflage beyond http (build 2116,
        // audit G-16): the stored types the core accepts
        // (the same registry KCP/QUIC already emit raw),
        // as a bare header block. Builds ≤2115 silently
        // ignored them — the profile ran as plain TCP.
        // A type the core cannot emit stays unemitted
        // and is journaled at connect instead
        // (Profile.hasUnappliedTcpHeader).
        stream['tcpSettings'] = {
          'header': {'type': p.tcpHeaderType},
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
  // Build 2049 stamped the sockopt domainStrategy to the
  // IPv4-only value here (the proxy server must never be
  // dialed over IPv6 —
  // the owner's carrier reset AAAA dials with EOF). REMOVED
  // in build 2101 by the owner's explicit order (2026-11-18,
  // «حفاظت ول کن» — full v2rayNG adoption): v2rayNG puts no
  // such pin on the proxy outbound, and the pin family is
  // what kept hostname-addressed servers resolving through
  // the IPv4-only path at all (the fugui case,
  // vless-reality-config-diagnosis.md §6.1). The server dial
  // now resolves the way v2rayNG's does — the core default,
  // both families. Named removal; see BUILD-LOG-2.md 2101.
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
  // Build 2049 carried the IPv4-only server strategy here too
  // (the exit node is the hop that really dials for the warp
  // chain) — removed in build 2101 with the rest of the pin
  // family, by the owner's order (see _streamSettings).
  final sock = <String, dynamic>{};
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

/// The OLCRTC underlay's tag (build 2134).
const olcrtcUnderlayTag = 'olcrtc-underlay';

/// The OLCRTC chain underlay outbound (build 2134): a
/// SOCKS outbound aimed at the olcrtc client's local
/// listener. Unlike DNSTT's port forward, the client IS a
/// SOCKS5 server — the handshake happens with the client
/// itself, and the bytes ride its WebRTC video-call
/// tunnel to the server peer (see olcrtc_args.dart).
/// Started by the controller before the tunnel config is
/// handed to the service.
Map<String, dynamic> _olcrtcUnderlayOutbound() => {
  'tag': olcrtcUnderlayTag,
  'protocol': 'socks',
  'settings': {
    'servers': [
      {'address': '127.0.0.1', 'port': olcrtcListenPort},
    ],
  },
};

/// The Zapret underlay's tag (build 2127, H1).
const zapretUnderlayTag = 'zapret-underlay';

/// The Zapret chain underlay outbound (build 2127, H1):
/// a SOCKS outbound aimed at the ciadpi desync proxy's
/// loopback listener. Emitted only when the profile
/// copy carries a zap candidate marker
/// (Profile.zapretStrategy — a Lab transform product,
/// never a stored field); the controller starts the
/// proxy before the config is used and stops it with
/// the session.
Map<String, dynamic> _zapretUnderlayOutbound() => {
  'tag': zapretUnderlayTag,
  'protocol': 'socks',
  'settings': {
    'servers': [
      {'address': '127.0.0.1', 'port': zapretListenPort},
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

/// One WireGuard peer entry for the outbound (build 2075:
/// extracted from buildOutbound's inline construction so the
/// multi-peer form — feature item 27 — emits exactly the
/// same shape per peer). The .conf's split-tunnel list rides
/// along (build 2057): an empty list keeps the full-tunnel
/// default.
Map<String, dynamic> wgPeerMap(Profile p) {
  final wgAllowed = p.wgAllowedIPs
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  return {
    'publicKey': p.peerPublicKey,
    // IPv6 peer endpoints must be bracketed or the composed
    // string is unparseable (audit, build 2033).
    'endpoint': p.address.contains(':')
        ? '[${p.address}]:${p.port}'
        : '${p.address}:${p.port}',
    if (p.preSharedKey.isNotEmpty) 'preSharedKey': p.preSharedKey,
    if (p.keepAlive > 0) 'keepAlive': p.keepAlive,
    'allowedIPs': wgAllowed.isEmpty ? ['0.0.0.0/0', '::/0'] : wgAllowed,
  };
}

/// The proxy outbound for a sidecar-served session (build
/// 2075): a plain SOCKS outbound to the sidecar engine's
/// loopback port. Build 2049 stamped the IPv4-only dial
/// strategy here too (belt-and-braces on a loopback literal);
/// build 2101 removes the whole pin family by the owner's
/// order (see _streamSettings), so no streamSettings rides
/// this outbound at all now.
Map<String, dynamic> sidecarProxyOutbound(int port) => {
  'tag': 'proxy',
  'protocol': 'socks',
  'settings': {
    'servers': [
      {'address': '127.0.0.1', 'port': port},
    ],
  },
};

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

  Map<String, dynamic> muxPart() {
    // Build 2095 (V2Ray journey audit #27): the profile's
    // own override wins over the global setting — 'on'
    // forces mux, 'off' forbids it, '' inherits. Eligibility
    // is unchanged.
    final eligible =
        p.protocol == Protocol.vless ||
        p.protocol == Protocol.vmess ||
        p.protocol == Protocol.trojan ||
        p.protocol == Protocol.shadowsocks;
    if (!eligible) return const <String, dynamic>{};
    final on =
        p.muxOverride == 'on' ||
        (p.muxOverride != 'off' && s.muxEnabled);
    return on
        ? {
            'mux': {'enabled': true, 'concurrency': s.muxConcurrency},
          }
        : const <String, dynamic>{};
  }

  switch (p.protocol) {
    case Protocol.tuic:
      return null; // No TUIC outbound exists in Xray-core.
    case Protocol.anytls:
      return null; // No AnyTLS outbound exists in Xray-core
    // (verified in the bundled fork's source, build 2033) —
    // the sing-box sidecar serves it instead (build 2089).
    case Protocol.snell:
    case Protocol.naive:
    case Protocol.mieru:
    case Protocol.tailscale:
    case Protocol.openconnect:
    case Protocol.sudoku:
      // Build 2075: the sidecar protocols never reach this
      // builder — buildTunnelConfig substitutes the sidecar
      // SOCKS outbound, and the test config does the same.
      // Null here is the guard rail, not the path. Build
      // 2127 (H2): Sudoku joins the group — its own fork
      // sidecar serves it, and a connect with the engine
      // off is refused before any config is built.
      return null;
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
      out['protocol'] = 'wireguard';
      out['settings'] = {
        'secretKey': p.secretKey,
        'address': wgAddresses.isEmpty ? ['172.16.0.2/32'] : wgAddresses,
        'peers': [wgPeerMap(p)],
        // Build 2125 (audit A25-38 / P-42): the profile
        // MTU is clamped to the app's TUN range
        // (1280–1500) here, as on the WG Tunnel path — a
        // stored 576–9000 used to pass through verbatim
        // and blackhole jumbo frames silently. The stored
        // profile keeps its value; only the emitted
        // config is clamped.
        'mtu': p.mtu.clamp(1280, 1500),
        'noKernelTun': true,
        if (reserved.length == 3) 'reserved': reserved,
      };
      // Build 2081 (verification Q-2) carried the IPv4-only
      // server strategy here (the WireGuard handler dials its
      // endpoint through this outbound's SocketSettings);
      // build 2101 removes the pin family by the owner's order
      // (see _streamSettings). The sockopt map itself stays —
      // the chain wiring below merges its dialerProxy into it,
      // never over it.
      out['streamSettings'] = <String, dynamic>{
        'sockopt': <String, dynamic>{},
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
        // Build 2049 stamped the IPv4-only server-dial strategy
        // here (Hysteria2 builds its own stream settings);
        // build 2101 removes the pin family by the owner's
        // order (see _streamSettings) — the sockopt map stays,
        // empty, as the chain-merge surface.
        'sockopt': <String, dynamic>{},
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
      // Build 2126 (D6): the noise decoy rides FIRST in
      // the udp mask list, ahead of the salamander obfs,
      // so the core emits its random decoy packets on the
      // socket before the first real (obfuscated) packet —
      // a filter's first read is decoy bytes. Grammar:
      // the fork's finalmask NoiseMask (Xray-core
      // transport_finalmask.go): settings.noise items of
      // {rand: size range, delay: range}.
      final udpMasks = <Map<String, dynamic>>[
        if (s.hy2NoiseDecoy)
          {
            'type': 'noise',
            'settings': {
              'noise': [
                {'rand': '100-300', 'delay': '10-20'},
                {'rand': '100-300', 'delay': '5-15'},
              ],
            },
          },
        if (p.obfs == 'salamander')
          {
            'type': 'salamander',
            'settings': {'password': p.obfsPassword},
          },
      ];
      if (udpMasks.isNotEmpty) finalmask['udp'] = udpMasks;
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
      // here, but its server dial needed the IPv4-only strategy
      // (see _streamSettings) — a sockopt-only stream settings
      // is valid, the core defaults the network to tcp
      // (infra/conf StreamConfig.Build). Build 2101 removes
      // the pin by the owner's order; the (now empty) sockopt
      // map stays as the chain-merge surface.
      // Build 2081: typed dynamic — _chainThroughUnderlay
      // mutates this map when the session is chained, and the
      // untyped literal's inferred value type rejects the
      // stamped sockopt (the same crash the WG case's test
      // caught).
      out['streamSettings'] = <String, dynamic>{
        'sockopt': <String, dynamic>{},
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
      // Build 2101 removes the pin by the owner's order (see
      // _streamSettings); the empty sockopt map stays as the
      // chain-merge surface.
      // Build 2081: typed dynamic, same reason as there.
      out['streamSettings'] = <String, dynamic>{
        'sockopt': <String, dynamic>{},
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
      // Build 2081: typed dynamic, same reason as the
      // shadowsocks case above. Build 2101 removes the 2049
      // IPv4-only pin by the owner's order (see
      // _streamSettings); the empty sockopt map stays as the
      // chain-merge surface.
      out['streamSettings'] = <String, dynamic>{
        'sockopt': <String, dynamic>{},
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
    // Build 2126 (D2): with fragmentViaFinalmask on, the
    // global fragment's shaping moves onto the outbound
    // itself as a finalmask fragment entry and the frag
    // chain is skipped FOR THE FRAGMENT — the freedom
    // noises still chain when the profile asks for them
    // (the frag outbound then carries noises only; see
    // the extraOutbounds sites). Off, this block is the
    // 2125 chain exactly.
    final fragViaMask = s.fragmentViaFinalmask && s.fragmentEnabled;
    if (!fragViaMask || p.afTcpNoise) {
      sock['dialerProxy'] = 'frag';
    }
    stream['sockopt'] = sock;
    if (fragViaMask) {
      final fm =
          (stream['finalmask'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{};
      final tcpMasks = <dynamic>[...(fm['tcp'] as List? ?? const [])];
      tcpMasks.add({
        'type': 'fragment',
        'settings': {
          'packets': s.fragmentPackets,
          'lengths': [_fragmentLengthSpec(s)],
          'delays': [_fragmentDelaySpec(s)],
        },
      });
      fm['tcp'] = tcpMasks;
      stream['finalmask'] = fm;
    }
    out['streamSettings'] = stream;
  }
  return out;
}

/// Build 2136 (item 8): the fragment length string for the
/// settings-level fragment chain. With randomized geometry
/// on, the stored fixed value becomes the centre of a range
/// (half to double, floored at 10) in the core's Int32Range
/// grammar — the core then picks a fresh cut inside the
/// range for every connection, so no single geometry can be
/// fingerprinted. Off, the fixed value is emitted exactly
/// as every build since 2026 has emitted it.
String _fragmentLengthSpec(XraySettings s) => s.fragmentRandomGeometry
    ? '${s.fragmentLength ~/ 2 < 10 ? 10 : s.fragmentLength ~/ 2}'
        '-${s.fragmentLength * 2}'
    : '${s.fragmentLength}';

/// Build 2136 (item 8): the matching delay/interval string —
/// same range treatment around the stored fixed interval.
String _fragmentDelaySpec(XraySettings s) => s.fragmentRandomGeometry
    ? '${s.fragmentInterval ~/ 2 < 1 ? 1 : s.fragmentInterval ~/ 2}'
        '-${s.fragmentInterval * 2}'
    : '${s.fragmentInterval}';

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
        'length': _fragmentLengthSpec(s),
        'interval': _fragmentDelaySpec(s),
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
    // 2049 added the IPv4-only server-dial strategy here;
    // build 2101 removes the pin family by the owner's order
    // (see _streamSettings).
    'sockopt': {
      'tcpNoDelay': true,
      if (dialMode.isNotEmpty) 'dialMode': dialMode,
    },
  },
};

/// The host pins v2rayNG hardcodes into every generated
/// config, adopted VERBATIM in build 2113 (owner order
/// 2026-11-19, «dns همون باشه»; full-config diff in
/// v2rayng-config-diff-2112.md): the entries and their order
/// are upstream's buildDnsHostsFromRoutingRules at ef06bac —
/// the googleapis.cn domain redirect first (a STRING value:
/// the core treats it as an alias, not an address), then the
/// fourteen Android Private-DNS domain tables of AppConfig
/// (DNS_*_DOMAIN / DNS_*_ADDRESSES, AAAA values included).
/// The well-known DoH endpoints resolve to these IPs without
/// asking any resolver, so the remote resolver is reachable
/// before — and independently of — any local DNS. (The
/// pre-2113 Ember table was a smaller IPv4-only subset with
/// two entries upstream does not carry — doh.dns.sb and
/// dns.adguard-dns.com; a custom DoH host outside this table
/// is carried to the proxy server as a domain and resolved
/// server-side, exactly as in v2rayNG.)
const _dnsHostPins = <String, Object>{
  'domain:googleapis.cn': 'googleapis.com',
  'dns.alidns.com': ['223.5.5.5', '223.6.6.6', '2400:3200::1', '2400:3200:baba::1'],
  'dns.sse.cisco.com': [
    '208.67.220.220',
    '208.67.222.222',
    '2620:119:35::35',
    '2620:119:53::53',
  ],
  'dns.umbrella.com': [
    '208.67.220.220',
    '208.67.222.222',
    '2620:119:35::35',
    '2620:119:53::53',
  ],
  'one.one.one.one': [
    '1.1.1.1',
    '1.0.0.1',
    '2606:4700:4700::1111',
    '2606:4700:4700::1001',
  ],
  '1dot1dot1dot1.cloudflare-dns.com': [
    '1.1.1.1',
    '1.0.0.1',
    '2606:4700:4700::1111',
    '2606:4700:4700::1001',
  ],
  'dns.cloudflare.com': [
    '162.159.61.8',
    '172.64.41.8',
    '2a06:98c1:52::8',
    '2803:f800:53::8',
  ],
  'cloudflare-dns.com': [
    '104.16.248.249',
    '104.16.249.249',
    '2606:4700::6810:f8f9',
    '2606:4700::6810:f9f9',
  ],
  'engage.cloudflareclient.com': ['162.159.192.1', '2606:4700:d0::a29f:c001'],
  'doh.pub': ['1.12.12.12', '120.53.53.53'],
  'dot.pub': ['1.12.12.12', '120.53.53.53'],
  'dns.google': [
    '8.8.8.8',
    '8.8.4.4',
    '2001:4860:4860::8888',
    '2001:4860:4860::8844',
  ],
  'dns.quad9.net': [
    '9.9.9.9',
    '149.112.112.112',
    '2620:fe::fe',
    '2620:fe::9',
  ],
  'dns.sb': ['45.11.45.11', '185.222.222.222', '2a09::', '2a11::'],
  'common.dot.dns.yandex.net': [
    '77.88.8.8',
    '77.88.8.1',
    '2a02:6b8::feed:0ff',
    '2a02:6b8:0:1::feed:0ff',
  ],
};

/// AdGuard's filtering DoH (build 2030): the ad-block preset's
/// resolver. Blocked domains are answered with a null route
/// there — resolution-level filtering, no geosite.dat.
const adGuardDohUrl = 'https://dns.adguard-dns.com/dns-query';

/// The shipped default remote resolver (the initializer of
/// XraySettings.remoteDns in xray_models.dart): v2rayNG's
/// DNS_PROXY, Cloudflare's DoH — adopted in build 2101,
/// briefly replaced by the plain-IP 1.1.1.1 in build 2111,
/// and RESTORED in build 2113 on the owner's order
/// (2026-11-19, «dns همون باشه») after the full-config diff
/// (v2rayng-config-diff-2112.md) proved the 2111 change
/// treated a symptom: the dead path was Ember's port-53
/// hijack into the core DNS module, not the DoH value.
const defaultRemoteDns = 'https://cloudflare-dns.com/dns-query';

/// v2rayNG's domestic/direct resolver (AppConfig DNS_DIRECT,
/// AliDNS): in its generated configs it rides as rule-scoped
/// server entries for the direct-routed domains, answered
/// directly instead of through the tunnel (see _dnsSection).
const defaultDirectDns = '223.5.5.5';

/// The domains Ember's routing sends DIRECT — the scope of
/// the domestic DNS entries, mirroring how v2rayNG scopes its
/// domestic servers to its direct-routed domains: the user's
/// own direct list plus the country presets' geosite lists.
/// Kept beside _routingRules' switch so the two never drift:
/// global / directAll / bypassLan route no DOMAINS direct
/// (directAll routes everything, so a scoped resolver would
/// be meaningless there — v2rayNG's shape has no domestic
/// entries without direct domains either).
List<String> directRoutedDomains(XraySettings s) => [
  ...s.customDirectDomains,
  if (s.routingPreset == RoutingPreset.bypassIran) 'geosite:ir',
  if (s.routingPreset == RoutingPreset.bypassChina) 'geosite:cn',
];

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
///   — REVERSED AGAIN in build 2101, by the owner's explicit
///   order (2026-11-18, «حفاظت ول کن» — "drop the protections,
///   fix it"): the DNS defaults become v2rayNG's own, whole.
///   The queryStrategy pin, the built-in Quad9-TCP fallback
///   and the outbound sockopt pin are all removed (named
///   removals, BUILD-LOG-2.md 2101); the remote default is
///   Cloudflare's DoH; the domestic/direct resolver
///   (223.5.5.5) joins as rule-scoped entries with
///   skipFallback, and the section carries
///   disableFallbackIfMatch like v2rayNG's DnsBean. The
///   owner's device evidence for the reversal: a
///   hostname-addressed VLESS+REALITY config whose server
///   name the 2049-shaped chain could not resolve at all
///   (every dns.google DoH query timed out and the fallback
///   answered "record not found") connected the moment its
///   address was replaced by the raw IP — the config was
///   never broken; the resolution chain was.
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
  // Build 2111: a bare IP literal (the new shipped default's
  // form) has no URL host to extract — its DoQ form is the
  // literal under the quic+local scheme, so DoQ mode stays
  // pure DoQ instead of silently emitting a plain-UDP entry.
  final literal = dohUrl.trim();
  if (InternetAddress.tryParse(literal) != null) {
    return 'quic+local://$literal';
  }
  final uri = Uri.tryParse(dohUrl);
  if (uri != null && uri.host.isNotEmpty) return 'quic+local://${uri.host}';
  return dohUrl;
}

/// The config's primary resolver under the transport choice.
/// The DNSCrypt transport's resolver address (build 2075):
/// the local dnscrypt-proxy sidecar (DnsCryptCore) listening
/// on loopback. The core treats a bare IP:port nameserver as
/// a plain DNS server — the encryption happens between the
/// proxy and its upstream resolvers, not between the core
/// and the proxy. The proxy's own upstream traffic leaves
/// under the app UID, which the VPN service excludes from
/// the TUN, so it never loops into the tunnel it serves.
const dnsCryptResolverAddress = '127.0.0.1:20530';

String primaryResolver(XraySettings s) {
  final base = s.adBlockDoh ? adGuardDohUrl : s.remoteDns;
  if (s.remoteDnsProto == 'dnscrypt') return dnsCryptResolverAddress;
  if (s.remoteDnsProto == 'doq') return doqFormOf(base);
  // Build 2111: through resolverUnderTransport, not tcpFormOf
  // directly — a bare-IP base (the new default) has no URL
  // host for tcpFormOf and must still take its tcp:// form.
  if (s.remoteDnsProto == 'tcp') return resolverUnderTransport(base, 'tcp');
  return base;
}

/// The primary resolver(s) as the DNS section emits them
/// (build 2103, diagnosis D5): v2rayNG's getRemoteDnsServers
/// treats the stored remote DNS as a comma-separated LIST
/// of resolvers; Ember's field accepted the list silently
/// but only ever emitted it as one (unresolvable) entry.
/// Each entry is mapped through the transport choice
/// individually, empties dropped, order preserved. The
/// DNSCrypt transport stays a single entry — its resolver
/// is the local sidecar, whose own upstreams are its
/// config's concern, not this field's. A single stored
/// value yields exactly [primaryResolver]. Build 2111
/// appended the Cloudflare DoH behind a lone plain-IP
/// remote (the [1.1.1.1, DoH] hybrid); build 2113 REMOVES
/// that append on the owner's order (2026-11-19): the
/// generated DNS section is v2rayNG's own, and upstream
/// emits the stored list exactly as stored — no append.
List<String> primaryResolvers(XraySettings s) {
  if (s.remoteDnsProto == 'dnscrypt') return [dnsCryptResolverAddress];
  final base = s.adBlockDoh ? adGuardDohUrl : s.remoteDns;
  final rawEntries = <String>[
    for (final raw in base.split(','))
      if (raw.trim().isNotEmpty) raw.trim(),
  ];
  final entries = <String>[];
  for (final entry in rawEntries) {
    final mapped = resolverUnderTransport(entry, s.remoteDnsProto);
    // Build 2103 (verification iteration 1, L1): duplicates
    // after transport mapping (two stored spellings of one
    // resolver) collapse — v2rayNG's list carries each
    // resolver once.
    if (!entries.contains(mapped)) entries.add(mapped);
  }
  return entries.isEmpty ? [primaryResolver(s)] : entries;
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
  // Build 2113: the pins table's values are address lists or
  // (for the googleapis.cn redirect) a plain string; only a
  // list pins a resolver IP.
  if (pins is List && pins.isNotEmpty) return 'tcp://${pins.first}';
  return 'tcp://$host';
}

/// A resolver URL under the transport choice (build 2037): the
/// same mapping the primary goes through, for group members, the
/// fallback, and the Settings display line. DoH passes through;
/// anything unrecognised falls back to DoH, so a stray stored
/// value can never break a connect.
String resolverUnderTransport(String url, String proto) {
  if (proto == 'doq') return doqFormOf(url);
  if (proto == 'tcp') {
    // Build 2111: a bare IP literal has no URL host for
    // tcpFormOf to map, and leaving it bare would emit a
    // plain-UDP nameserver in TCP mode — the build-2037
    // doctrine is that TCP mode stays pure TCP, so the
    // literal takes the tcp:// form directly.
    final literal = url.trim();
    if (InternetAddress.tryParse(literal) != null) return 'tcp://$literal';
    return tcpFormOf(url);
  }
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

/// The domain-bearing routing rules of the active posture,
/// in the order _routingRules emits them, as (domains,
/// outboundTag) pairs. Build 2113: this is the input of
/// _dnsSection's scoped-entry construction — upstream
/// v2rayNG's configureDns projects exactly this list (its
/// CoreConfigContext.routingDomainRules: the enabled,
/// domain-bearing rules of the active ruleset, tags
/// normalized to proxy/direct/block) into scoped DNS server
/// entries. Kept beside _routingRules' emission so the two
/// never drift: custom block list, custom proxy list,
/// custom direct list, then the preset's domain rule.
List<({List<String> domains, String outbound})> dnsDomainRules(
  XraySettings s,
) => [
  if (s.customBlockDomains.isNotEmpty) (domains: s.customBlockDomains, outbound: 'block'),
  if (s.customProxyDomains.isNotEmpty) (domains: s.customProxyDomains, outbound: 'proxy'),
  if (s.customDirectDomains.isNotEmpty) (domains: s.customDirectDomains, outbound: 'direct'),
  if (s.routingPreset == RoutingPreset.bypassIran)
    (domains: const ['geosite:ir'], outbound: 'direct'),
  if (s.routingPreset == RoutingPreset.bypassChina)
    (domains: const ['geosite:cn'], outbound: 'direct'),
];

Map<String, dynamic> _dnsSection(
  XraySettings s,
  Profile p, {
  Map<String, List<String>> serverHostPins = const {},
}) {
  final servers = <dynamic>[];
  if (s.fakeDns) servers.add('fakedns');
  // Build 2030 (the plan-check's split, isolated to this one
  // function): the ad-block preset swaps the primary resolver
  // for AdGuard's filtering DoH. It ANSWERS blocked domains
  // (with a null route) rather than failing them, so the
  // fallback appended after it only ever sees genuine
  // resolution failures of the primary — the two policies
  // cannot fight.
  // Build 2103 (diagnosis D5): the stored remote DNS is a
  // comma-separated list, as in v2rayNG — every entry is
  // emitted, each mapped through the transport. A single
  // value (the default) emits exactly as before.
  final primaries = primaryResolvers(s);
  // Build 2113 (owner order 2026-11-19 — the generated DNS
  // section is v2rayNG's own, verbatim; full-config diff in
  // v2rayng-config-diff-2112.md): the scoped entries are
  // built by upstream's configureDns algorithm at ef06bac
  // (buildDnsCnModeFromRoutingRules, then
  // buildDnsFromRoutingRules), projected from the active
  // posture's domain rules (dnsDomainRules). This replaces
  // the single combined domestic entry builds ≤2112 emitted
  // (which also carried a 'port': 53 upstream never sets).
  final domainRules = dnsDomainRules(s);
  // CN mode: on when a DIRECT rule carries exactly
  // geosite:cn; the scoped domain list is every direct-rule
  // domain matching upstream's cnRegionFilter. The domestic
  // entry carries the domestic-dns tag (its queries leave
  // via the direct outbound — see _routingRules); the
  // remote entry is the same scope without the tag.
  bool isCnDomain(String d) =>
      d.startsWith('geosite:') && (d.endsWith('-cn') || d.endsWith('@cn')) ||
      d == 'geosite:cn';
  final directRuleDomains = <String>[
    for (final r in domainRules)
      if (r.outbound == 'direct') ...r.domains,
  ];
  if (directRuleDomains.contains('geosite:cn')) {
    final cnDomains = directRuleDomains.where(isCnDomain).toList();
    if (cnDomains.isNotEmpty) {
      servers.add(<String, dynamic>{
        'address': defaultDirectDns,
        'domains': cnDomains,
        'expectIPs': ['geoip:cn'],
        'skipFallback': true,
        'tag': 'domestic-dns',
      });
      for (final remote in primaries) {
        servers.add(<String, dynamic>{
          'address': remote,
          'domains': cnDomains,
          'expectIPs': ['geoip:cn'],
          'skipFallback': true,
        });
      }
    }
  }
  // Per-rule scoped entries, in rule order: a direct rule's
  // domains are answered by the domestic resolver
  // (skipFallback, finalQuery on the last — Ember's domestic
  // list is the single defaultDirectDns — and the
  // domestic-dns tag); a proxy rule's domains by the remote
  // list (finalQuery on the last remote entry only); block
  // rules produce no server entry (their domains are
  // answered from hosts instead — see the hosts merge).
  for (final r in domainRules) {
    if (r.outbound == 'direct') {
      servers.add(<String, dynamic>{
        'address': defaultDirectDns,
        'domains': r.domains,
        'skipFallback': true,
        'finalQuery': true,
        'tag': 'domestic-dns',
      });
    } else if (r.outbound != 'block') {
      for (var i = 0; i < primaries.length; i++) {
        servers.add(<String, dynamic>{
          'address': primaries[i],
          'domains': r.domains,
          if (i == primaries.length - 1) 'finalQuery': true,
        });
      }
    }
  }
  // Finally the remote list itself, as plain entries —
  // upstream appends each remote DNS as a bare string after
  // every scoped entry.
  servers.addAll(primaries);
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
      if (!primaries.contains(mapped)) servers.add(mapped);
    }
  }
  // Build 2049's built-in fallback (a Quad9-over-TCP entry
  // appended in the default shape, after the owner's
  // 2026-11-14 log showed the lone DoH's POSTs timing out) is
  // REMOVED in build 2101 by the owner's explicit order
  // (2026-11-18): v2rayNG's default shape carries no fallback
  // server — its safety valves are the scoped domestic
  // entries above and disableFallbackIfMatch. Named removal;
  // see BUILD-LOG-2.md 2101. A user's own fallback (dnsFallback
  // above) and the DNS group are untouched — they were always
  // explicit choices, never the built-in.
  // Build 2041: the user's own host entries merge into the DNS
  // section's hosts map — a user entry wins over the built-in
  // resolver pins for the same domain, and an invalid stored
  // entry never reaches the config (validDnsHosts is the final
  // gate, so a corrupt store cannot break a connect). The
  // single-IP value is emitted as a one-element list, the same
  // shape as the built-in pins, which the core's HostAddress
  // accepts alongside plain strings.
  final hosts = <String, dynamic>{
    // Build 2113 (upstream buildDnsHostsFromRoutingRules):
    // block-rule domains are answered with the loopback
    // address, ahead of every pin — a name the user routes
    // to the blackhole never resolves to a real address in
    // the module's own lookups either.
    for (final r in domainRules)
      if (r.outbound == 'block')
        for (final d in r.domains) d: '127.0.0.1',
    ..._dnsHostPins,
  };
  // Build 2105: the provider-DNS pins the connect path resolved
  // for this profile's server hostname ride here — after the
  // built-in pins, before the user's custom hosts, so an
  // explicit user entry for the same name still wins. Only
  // well-formed pairs are trusted in (the resolver produced
  // them, but the gate is the same one the stored hosts pass).
  for (final entry in serverHostPins.entries) {
    if (entry.value.isEmpty) continue;
    final key = entry.key.trim().toLowerCase();
    if (key.isEmpty) continue;
    final answers = [
      for (final ip in entry.value)
        if (InternetAddress.tryParse(ip) != null) ip,
    ];
    // Build 2113: upstream writes a single resolved address
    // as a plain string and several as a list (its
    // resolveOutboundDomainsToHosts) — the pin takes the
    // same shape here. An all-invalid answer set removes
    // the key, as before.
    if (answers.length == 1) {
      hosts[key] = answers.single;
    } else if (answers.isNotEmpty) {
      hosts[key] = answers;
    } else {
      hosts.remove(key);
    }
  }
  for (final entry in validDnsHosts(s.customDnsHosts).entries) {
    // Build 2113: upstream emits user hosts as plain strings
    // (its PREF_DNS_HOSTS values are single addresses); the
    // core's HostAddress accepts the string form alongside
    // lists (see dns_hosts.dart).
    hosts[entry.key] = entry.value;
  }
  // Build 2113 (upstream configureDns at ef06bac): the
  // DnsBean sets enableParallelQuery when the two server
  // LISTS' sizes — domestic plus remote — exceed two.
  // Ember's domestic list is the single defaultDirectDns,
  // so the count is primaries + 1. The DNS group and the
  // user fallback (Ember extras, both opt-in) are emitted
  // above but do not inflate the count, and the 'fakedns'
  // pseudo-entry is not a server. Absent in the default
  // shape (1 + 1), exactly as in v2rayNG's default.
  final realServerCount = primaries.length + 1;
  return {
    'hosts': hosts,
    'servers': servers,
    // Build 2103 (diagnosis D2/E2): the tag is v2rayNG's
    // own name for its DNS module — _routingRules pins
    // this tag's queries to the proxy outbound with the
    // explicit rule v2rayNG emits, instead of letting
    // them fall through to whatever outbound is first.
    'tag': 'dns-module',
    if (realServerCount > 2) 'enableParallelQuery': true,
    // Build 2075 (feature item 23, the supported subset):
    // the core's DNS config has a real disableCache field —
    // emitted ONLY when the user turns the cache off, so the
    // default shape stays byte-identical to earlier builds.
    if (s.dnsCacheDisabled) 'disableCache': true,
    // Build 2101 (owner order 2026-11-18): v2rayNG's DnsBean
    // flag — a name matched by a scoped (domestic) entry does
    // not fall back to the general chain when that entry
    // fails. And NO queryStrategy: build 2049's 'UseIPv4'
    // pin is removed by the same order (the core default
    // applies, exactly as in v2rayNG — see the reversal note
    // on _dnsSection above). Named removals; BUILD-LOG 2101.
    'disableFallbackIfMatch': true,
  };
}

/// The direct (freedom) outbound. Build 2113 RESTORES the
/// streamSettings sockopt stamp builds ≤2102 carried
/// (domainStrategy UseIP + happyEyeballs), removed in 2103
/// on a misreading: upstream's "Remove freedom.domainStrategy
/// #5656" removed the freedom SETTINGS field, but the
/// generated config at the pinned upstream commit (ef06bac,
/// full-config diff in v2rayng-config-diff-2112.md) still
/// carries the template's streamSettings.sockopt on this
/// outbound — and without it, a domain addressed to the
/// direct outbound is resolved by the core's system dialer,
/// whose pure-Go resolver has no nameservers on Android
/// (the C1 trap of the fugui diagnosis, on the direct path:
/// every direct-routed domain — bypass presets, custom
/// direct lists — silently failed to resolve). With UseIP
/// the core resolves through its own DNS module, as in
/// v2rayNG. The stamp's happyEyeballs is the template's
/// (no prioritizeIPv6 key — upstream's freedom bean leaves
/// it unset), and the streamSettings network is the "tcp"
/// upstream's DTO default serializes. The outbound still
/// carries NO settings object, exactly like the template.
/// (The freedom SETTINGS domainStrategy on the WARP
/// exit-node and ECH outbounds is a different field with
/// its own load-bearing reasons — see their definitions;
/// it is not this stamp.)
Map<String, dynamic> _directOutbound() => {
  'tag': 'direct',
  'protocol': 'freedom',
  'streamSettings': {
    'network': 'tcp',
    'sockopt': {
      'domainStrategy': 'UseIP',
      'happyEyeballs': {'maxConcurrentTry': 4, 'tryDelayMs': 250, 'interleave': 2},
    },
  },
};

/// Rules from the preset + the user's custom lists.
List<Map<String, dynamic>> _routingRules(XraySettings s) {
  final rules = <Map<String, dynamic>>[
    // Build 2113 (owner order 2026-11-19 — the generated DNS
    // posture is v2rayNG's own; v2rayng-config-diff-2112.md):
    // the port-53 redirect into the core DNS module is NO
    // LONGER unconditional. Upstream's local-DNS feature —
    // the only source of this rule and of the dns-out
    // outbound — defaults OFF (its PREF_LOCAL_DNS_ENABLED is
    // never seeded and configureLocalDns gates on == true),
    // so in v2rayNG's default config app DNS packets are
    // ordinary tunnel traffic, answered by the VPN's DNS
    // server from the proxy's egress. Ember's always-on
    // hijack made EVERY app lookup depend on the core
    // module's dispatched upstreams — the path the owner's
    // 2110 export proved 100% dead on his fugui server while
    // raw flows through the same proxy lived, which is why
    // v2rayNG gave him full traffic and Ember gave him
    // nothing but hardcoded-IP apps. The redirect now rides
    // only when fakeDNS is on: fake-IP answers exist only
    // inside the module, so its queries must be intercepted
    // for the feature to work at all (upstream gates its
    // fakedns emission on the same pairing). Off (the
    // default), the rule and the dns-out outbound are both
    // absent, exactly as upstream.
    // Build 2075: the browser-port inbound (when enabled)
    // gets the same DNS redirect as the proxy inbounds.
    if (s.fakeDns)
      {
        'type': 'field',
        'inboundTag': [
          'socks',
          'http',
          if (s.browserPortEnabled) 'browser',
        ],
        'port': '53',
        'network': 'udp',
        'outboundTag': 'dns-out',
      },
  ];
  // Build 2108 (Block QUIC toggle, feature-watch 2026-11-18,
  // DPIMech 0.3.0): UDP port 443 goes to the blackhole
  // outbound, so browsers and YouTube fall back to TCP on
  // networks where QUIC is throttled. The rule sits BEFORE
  // every custom/preset rule below, so no preset (bypassIran,
  // directAll, a custom list) can route QUIC around the
  // block, because first match wins. Build 2113 moves the
  // dns-module rule to the END of the list (upstream's
  // position — see below), so this rule now also precedes
  // it; name resolution is still safe, because the block
  // matches UDP/443 only, while the module's tunneled
  // upstreams are DoH over TCP/443, plain DNS on UDP or
  // TCP/53, or DoT on TCP/853 — and DoQ rides quic+local,
  // a local dial routing never sees. (Upstream lives with
  // the same order: its WHITE preset's UDP/443 block
  // precedes its dns-module rule too.) Off, this block adds
  // nothing.
  if (s.blockQuic) {
    rules.add({
      'type': 'field',
      'port': '443',
      'network': 'udp',
      'outboundTag': 'block',
    });
  }
  // Build 2101: the scoped domestic DNS entries (see
  // _dnsSection) resolve through the DIRECT outbound — the
  // rule v2rayNG puts first in its generated configs
  // ({inboundTag: [domestic-dns], outboundTag: direct}), so it
  // leads here too. Upstream inserts it unconditionally;
  // Ember emits it exactly when the DNS section carries
  // domestic-dns-tagged entries (build 2113: exactly when a
  // direct domain rule exists — the same condition), which
  // is functionally identical: the rule can only match
  // sessions the tagged servers originate.
  if (directRoutedDomains(s).isNotEmpty) {
    rules.insert(0, {
      'type': 'field',
      'inboundTag': ['domestic-dns'],
      'outboundTag': 'direct',
    });
  }
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
    // Build 2095 (V2Ray journey audit #23): the China
    // mirror of the Iran preset — it existed for one
    // country only, so a user in China had to hand-write
    // the rules the Iran preset writes automatically.
    case RoutingPreset.bypassChina:
      rules.add(rule(ips: ['geoip:private', 'geoip:cn']));
      rules.add(rule(domains: ['geosite:cn']));
  }
  // Build 2113: the DNS module's own upstream queries go to
  // the proxy — the explicit rule v2rayNG's configureDns
  // emits for its dns-module tag (build 2103, diagnosis
  // D2/E2) — moved to the END of the list, upstream's
  // position: configureDns APPENDS it after every preset
  // rule (and inserts the domestic-dns rule at index 0), so
  // the two DNS rules bracket the posture's rules exactly as
  // they do in v2rayNG's generated configs. Until 2112
  // Ember carried it first; the position is observable only
  // for a module dispatch whose destination also matches a
  // custom/preset rule, and upstream's semantics — the
  // posture's rules win, the scoped entries are the module's
  // own steering — are the parity target. In the default
  // (global) posture no other rule exists, so the module's
  // queries reach the proxy exactly as before.
  rules.add({
    'type': 'field',
    'inboundTag': ['dns-module'],
    'outboundTag': 'proxy',
  });
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
  //
  // Local proxy authentication (build 2075, feature item
  // 24): with sharing OFF, the loopback inbounds can carry
  // their own login (localProxyAuthReady) — the same
  // password-auth shape, the local credentials. The LAN
  // login keeps precedence whenever sharing is on, exactly
  // as before; with both off the inbounds are byte-identical
  // to every earlier build.
  final listen = s.lanShareEnabled ? '0.0.0.0' : '127.0.0.1';
  final authReady = s.lanShareAuthReady ||
      (!s.lanShareEnabled && s.localProxyAuthReady);
  final authUser = s.lanShareAuthReady ? s.lanShareUser : s.localProxyUser;
  final authPass = s.lanShareAuthReady ? s.lanSharePass : s.localProxyPass;
  Map<String, dynamic> inbound(String tag, String protocol, int port) => {
    'tag': tag,
    'listen': listen,
    'port': port,
    'protocol': protocol,
    'sniffing': {
      'enabled': s.sniffing,
      // Build 2095 (audit #22): the set is the user's —
      // each protocol's sniffing can be turned off in
      // Settings. Build 2103 (diagnosis D3/E3): the
      // default set is v2rayNG's own — http + tls; QUIC
      // sniffing is an opt-in extra now (sniffQuic).
      'destOverride': [
        if (s.sniffHttp) 'http',
        if (s.sniffTls) 'tls',
        if (s.sniffQuic) 'quic',
        if (s.fakeDns) 'fakedns',
      ],
      'metadataOnly': false,
      'routeOnly': false,
    },
    'settings': {
      'auth': authReady ? 'password' : 'noauth',
      if (authReady)
        'accounts': [
          {'user': authUser, 'pass': authPass},
        ],
      'udp': s.enableUdp,
      'allowTransparent': false,
    },
  };
  return [
    inbound('socks', 'socks', s.socksPort),
    inbound('http', 'http', s.httpPort),
    // The dedicated browser port (build 2075, feature item
    // 17): a fixed loopback HTTP inbound that exists only
    // while the option is on, so a browser can be pointed at
    // one stable address. Loopback even when LAN sharing is
    // on — the shared inbounds above are the LAN surface.
    if (s.browserPortEnabled)
      {
        'tag': 'browser',
        'listen': '127.0.0.1',
        'port': s.browserPort,
        'protocol': 'http',
        'sniffing': {
          'enabled': s.sniffing,
          // Build 2095 (audit #22): the set is the user's —
      // each protocol's sniffing can be turned off in
      // Settings. Build 2103: the default set is
      // v2rayNG's http + tls (see the main inbounds).
      'destOverride': [
        if (s.sniffHttp) 'http',
        if (s.sniffTls) 'tls',
        if (s.sniffQuic) 'quic',
        if (s.fakeDns) 'fakedns',
      ],
          'metadataOnly': false,
          'routeOnly': false,
        },
        'settings': {
          'auth': authReady ? 'password' : 'noauth',
          if (authReady)
            'accounts': [
              {'user': authUser, 'pass': authPass},
            ],
          'udp': s.enableUdp,
          'allowTransparent': false,
        },
      },
  ];
}

/// Build 2110 (fugui-hostname diagnosis C1): v2rayNG's
/// resolve method "1" (its default) — when the app resolved
/// the profile's server name itself and handed the answers
/// in through [serverHostPins] (which _dnsSection already
/// merges into the config's hosts), the proxy outbound's
/// sockopt gains domainStrategy "UseIP" + the happyEyeballs
/// block v2rayNG stamps with it. Without the strategy the
/// core's system dialer resolves the name through Go's pure
/// resolver — libxray.so is built CGO_ENABLED=0, so on
/// Android it falls back to 127.0.0.1:53 and the dial fails
/// outright; with it, the core resolves through its own DNS
/// module, where the hosts pin answers instantly. The core
/// applies the CALLING outbound's sockopt before following
/// any dialerProxy, so stamping the proxy outbound alone
/// also covers chained shapes (fragment / underlay hops
/// receive an IP destination). No pin for the name — the
/// on-device lookup returned nothing — means today's shape,
/// byte for byte: this stamp can only ever ride a pin the
/// controller actually computed. The sockopt is MERGED into
/// whatever the outbound already carries (dialerProxy,
/// dialMode, tcpKeepAliveIdle…), never assigned over it.
void _stampServerNameResolve(
  Map<String, dynamic> outbound,
  Profile p,
  Map<String, List<String>> serverHostPins,
) {
  if (serverHostPins.isEmpty) return;
  var host = p.address.trim().toLowerCase();
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  if (host.isEmpty) return;
  final answers = serverHostPins[host];
  if (answers == null || answers.isEmpty) return;
  final streamRaw = outbound['streamSettings'];
  final streamMap = <String, dynamic>{
    if (streamRaw is Map) ...streamRaw.cast<String, dynamic>(),
  };
  final sockRaw = streamMap['sockopt'];
  final sockMap = <String, dynamic>{
    if (sockRaw is Map) ...sockRaw.cast<String, dynamic>(),
  };
  sockMap['domainStrategy'] = 'UseIP';
  // Build 2113: the happyEyeballs block takes upstream's
  // full serialized shape (v2rayng-config-diff-2112.md) —
  // builds 2110–2112 emitted only interleave +
  // prioritizeIPv6; the bean's maxConcurrentTry and
  // tryDelayMs defaults ride in v2rayNG's generated config
  // and now ride here too.
  sockMap['happyEyeballs'] = <String, dynamic>{
    'prioritizeIPv6': false,
    'maxConcurrentTry': 4,
    'tryDelayMs': 250,
    'interleave': 2,
  };
  streamMap['sockopt'] = sockMap;
  outbound['streamSettings'] = streamMap;
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
/// [olcrtcUnderlay] (build 2134): the same chain over the
/// OLCRTC client (see _olcrtcUnderlayOutbound).
///
/// [wgWstunnelPort] (build 2072): when > 0 and the profile is
/// WireGuard, the peer endpoint in the built config points at
/// the local wstunnel forwarder instead of the real endpoint
/// — the stored profile is never rewritten; the forwarder
/// dials the real endpoint from the server side.
///
/// [sidecarSocksPort] (build 2075): when > 0 the profile is
/// served by a sidecar engine (sing-box for TUIC / Snell /
/// NaiveProxy / Tailscale / OpenConnect, the Mieru client
/// for Mieru) that is already running with a SOCKS inbound
/// on that loopback port. The proxy outbound becomes a plain
/// SOCKS outbound aimed at the sidecar; everything else —
/// inbounds, DNS, routing, stats — is the ordinary tunnel
/// config, so the session keeps the TUN, the kill switch,
/// and per-config accounting. The sidecar's own egress
/// leaves under the app UID (excluded from the TUN), the
/// DNSTT doctrine.
///
/// [wgPeerProfiles] (build 2075, feature item 27): when the
/// profile is WireGuard and this list holds more than the
/// profile itself, the outbound's peers are ALL of them —
/// the multi-peer form of a .conf group (see wgGroupKey).
String buildTunnelConfig(
  Profile p,
  XraySettings s, {
  bool psiphonUnderlay = false,
  bool warpUnderlay = false,
  WarpProfile? warp,
  bool dnsttUnderlay = false,
  bool olcrtcUnderlay = false,
  int wgWstunnelPort = 0,
  int sidecarSocksPort = 0,
  List<Profile> wgPeerProfiles = const [],
  Map<String, List<String>> serverHostPins = const {},
}) {
  // Build 2127 (H1): the Zapret desync chain, keyed on
  // the profile copy's runtime marker (see
  // _zapretUnderlayOutbound) — no new parameter, so
  // every existing call site builds zapret-free configs
  // from stored profiles exactly as before.
  final zapretUnderlay = p.zapretStrategy.isNotEmpty;
  final echDialer = p.afEch
      ? (warpUnderlay
            ? warpUnderlayTag
            : psiphonUnderlay
            ? psiphonUnderlayTag
            : dnsttUnderlay
            ? dnsttUnderlayTag
            : olcrtcUnderlay
            ? olcrtcUnderlayTag
            : zapretUnderlay
            ? zapretUnderlayTag
            : echOutboundTag)
      : null;
  final outbound = sidecarSocksPort > 0
      ? sidecarProxyOutbound(sidecarSocksPort)
      : buildOutbound(
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
  // Build 2110 (fugui-hostname diagnosis C1): the v2rayNG
  // resolve-method-"1" stamp — see _stampServerNameResolve.
  _stampServerNameResolve(outbound, p, serverHostPins);
  // Multi-peer WireGuard (build 2075, feature item 27): the
  // session's outbound carries every peer of the profile's
  // .conf group; the stored profiles are never rewritten.
  if (wgPeerProfiles.length > 1 && p.protocol == Protocol.wireguard) {
    final settings = outbound['settings'];
    if (settings is Map<String, dynamic>) {
      settings['peers'] = [
        for (final peerProfile in wgPeerProfiles) wgPeerMap(peerProfile),
      ];
    }
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
    // Build 2113: the dns-out outbound exists only when the
    // port-53 redirect that feeds it does — fakeDNS on (see
    // _routingRules). Upstream's generated config carries no
    // dns-out at all under default settings (its local-DNS
    // feature is off by default); when Ember's local-DNS
    // shape is enabled upstream-side it serializes as a bare
    // {tag, protocol} pair, but Ember's nonIPQuery knob is
    // the feature's own behaviour and stays.
    if (s.fakeDns)
      {
        'tag': 'dns-out',
        'protocol': 'dns',
        'settings': {'nonIPQuery': 'skip'},
      },
    // Build 2126 (D2): in FinalMask mode the fragment
    // half no longer needs the frag outbound — it is
    // emitted only for the noise half then, and omitted
    // entirely when noise is off too.
    if (p.afTcpNoise || (s.fragmentEnabled && !s.fragmentViaFinalmask))
      _fragmentOutbound(
        s,
        noise: p.afTcpNoise,
        fragment: s.fragmentEnabled && !s.fragmentViaFinalmask,
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
  if (olcrtcUnderlay) {
    _chainThroughUnderlay(outbound, extraOutbounds, olcrtcUnderlayTag);
    extraOutbounds.add(_olcrtcUnderlayOutbound());
  }
  if (zapretUnderlay) {
    _chainThroughUnderlay(outbound, extraOutbounds, zapretUnderlayTag);
    extraOutbounds.add(_zapretUnderlayOutbound());
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
    // Build 2095 (audit #28): the stored level, chosen on
    // the logs page; 'warning' remains the default.
    'log': {'loglevel': s.logLevel},
    // The core's own statistics: the per-config traffic totals are
    // read from the "proxy" outbound counters through this local API.
    'stats': <String, dynamic>{},
    'api': {
      'tag': 'api',
      'services': ['StatsService'],
    },
    'dns': _dnsSection(s, p, serverHostPins: serverHostPins),
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
        // Build 2110 (fugui-hostname diagnosis C3): v2rayNG's
        // template also writes the level-0 byte budgets
        // explicitly. Non-causal alignment — Xray's own
        // defaults are already 0 — recorded as such.
        '0': {
          'statsUserUplink': false,
          'statsUserDownlink': false,
          'uplinkOnly': 0,
          'downlinkOnly': 0,
        },
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
    return compactJson(applyConfigMixins(merged, mixins));
  }
  return compactJson(config);
}

/// The test config: one SOCKS inbound on port 0 — the native tester
/// substitutes the real port before starting the throwaway core.
///
/// [sidecarSocksPort] (build 2075): for a sidecar-served
/// profile the outbound is the sidecar SOCKS outbound, so a
/// delay test measures the real path (test core → sidecar →
/// server) while the sidecar runs.
///
/// [serverHostPins] (build 2110, fugui-hostname diagnosis
/// C1): the same app-side server-name resolution as the
/// tunnel config — the answers ride the DNS section's hosts
/// and the outbound carries the UseIP stamp (see
/// _stampServerNameResolve). Empty = today's shape.
String buildTestConfig(
  Profile p,
  XraySettings s, {
  int sidecarSocksPort = 0,
  Map<String, List<String>> serverHostPins = const {},
}) {
  final outbound = sidecarSocksPort > 0
      ? sidecarProxyOutbound(sidecarSocksPort)
      : buildOutbound(
          p,
          s,
          fragment: s.fragmentEnabled || p.afTcpNoise,
          echDialer: p.afEch ? echOutboundTag : null,
        );
  if (outbound == null) {
    throw StateError('protocol not supported by the core: ${p.protocol}');
  }
  _stampServerNameResolve(outbound, p, serverHostPins);
  // Build 2127 (H1): a zap-marked copy probes THROUGH
  // the desync proxy, exactly as its connect would —
  // the Lab measures the chained dial, never a direct
  // one wearing the candidate's name.
  final zapretTestOutbounds = <Map<String, dynamic>>[
    outbound,
    _directOutbound(),
    // Build 2126 (D2): same FinalMask rule as the
    // tunnel config's extra outbounds.
    if (p.afTcpNoise || (s.fragmentEnabled && !s.fragmentViaFinalmask))
      _fragmentOutbound(
        s,
        noise: p.afTcpNoise,
        fragment: s.fragmentEnabled && !s.fragmentViaFinalmask,
        dialMode: p.dialMode,
      ),
    if (p.afEch) _echOutbound(),
    if (p.zapretStrategy.isNotEmpty) _zapretUnderlayOutbound(),
  ];
  if (p.zapretStrategy.isNotEmpty) {
    _chainThroughUnderlay(outbound, zapretTestOutbounds, zapretUnderlayTag);
  }
  return compactJson({
    'log': {'loglevel': 'none'},
    // The same DNS section as the tunnel config (2024): the
    // delay/speed tests must resolve the server's domain through
    // the same path the tunnel uses — v2rayNG's test configs go
    // through its full config manager too. Before, the test
    // config had no DNS section at all, so a profile could pass
    // its delay test and still fail in the tunnel (or the other
    // way round) purely on resolution.
    'dns': _dnsSection(s, p, serverHostPins: serverHostPins),
    'inbounds': [
      {
        'tag': 'socks',
        'listen': '127.0.0.1',
        'port': 0,
        'protocol': 'socks',
        'settings': {'auth': 'noauth', 'udp': false},
      },
    ],
    'outbounds': zapretTestOutbounds,
  });
}
