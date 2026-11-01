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

import 'xray_models.dart';

String prettyJson(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);

Map<String, dynamic> _streamSettings(Profile p, XraySettings s) {
  final stream = <String, dynamic>{'network': p.network};
  final security = p.security;
  stream['security'] = security.isEmpty ? 'none' : security;

  if (security == 'tls') {
    final tls = <String, dynamic>{
      'serverName': p.sni.isEmpty ? p.address : p.sni,
      'allowInsecure': p.allowInsecure || s.allowInsecure,
    };
    final alpn = p.alpn
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (alpn.isNotEmpty) tls['alpn'] = alpn;
    if (p.fingerprint.isNotEmpty) tls['fingerprint'] = p.fingerprint;
    stream['tlsSettings'] = tls;
  } else if (security == 'reality') {
    stream['realitySettings'] = {
      'serverName': p.sni,
      'fingerprint': p.fingerprint.isEmpty ? 'chrome' : p.fingerprint,
      'publicKey': p.publicKey,
      'shortId': p.shortId,
      'spiderX': p.spiderX.isEmpty ? '/' : p.spiderX,
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
  return stream;
}

/// The proxy outbound for [p], or null when the core cannot serve it.
Map<String, dynamic>? buildOutbound(
  Profile p,
  XraySettings s, {
  bool fragment = false,
}) {
  final out = <String, dynamic>{'tag': 'proxy', 'sendThrough': '0.0.0.0'};

  Map<String, dynamic> muxPart() => s.muxEnabled &&
          (p.protocol == Protocol.vless ||
              p.protocol == Protocol.vmess ||
              p.protocol == Protocol.trojan ||
              p.protocol == Protocol.shadowsocks)
      ? {
          'mux': {'enabled': true, 'concurrency': s.muxConcurrency}
        }
      : const <String, dynamic>{};

  switch (p.protocol) {
    case Protocol.tuic:
      return null; // No TUIC outbound exists in Xray-core.
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
        'peers': [
          {
            'publicKey': p.peerPublicKey,
            'endpoint': '${p.address}:${p.port}',
            if (p.preSharedKey.isNotEmpty) 'preSharedKey': p.preSharedKey,
            if (p.keepAlive > 0) 'keepAlive': p.keepAlive,
            'allowedIPs': ['0.0.0.0/0', '::/0'],
          }
        ],
        'mtu': p.mtu,
        'noKernelTun': true,
        if (reserved.length == 3) 'reserved': reserved,
      };
      return out;
    case Protocol.hysteria2:
      out['protocol'] = 'hysteria';
      out['settings'] = {'version': 2, 'address': p.address, 'port': p.port};
      final stream = <String, dynamic>{
        'network': 'hysteria',
        'security': 'tls',
        'tlsSettings': {
          'serverName': p.sni.isEmpty ? p.address : p.sni,
          'allowInsecure': p.allowInsecure || s.allowInsecure,
          'alpn': ['h3'],
          if (p.fingerprint.isNotEmpty) 'pinSHA256': p.fingerprint,
        },
        'hysteriaSettings': {
          'version': 2,
          'auth': p.uuidOrPassword,
          if (p.upMbps > 0 || p.downMbps > 0)
            'udphop': null, // bandwidth negotiated by the core itself
        },
      };
      stream.removeWhere((k, v) => v == null);
      (stream['hysteriaSettings'] as Map).removeWhere((k, v) => v == null);
      if (p.obfs == 'salamander') {
        stream['finalmask'] = {
          'udp': [
            {
              'type': 'salamander',
              'settings': {'password': p.obfsPassword}
            }
          ]
        };
      }
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
                'encryption': 'none',
                if (p.flow.isNotEmpty) 'flow': p.flow,
                'level': 0,
              }
            ],
          }
        ],
      };
      out['streamSettings'] = _streamSettings(p, s);
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
                'alterId': 0,
                'security': 'auto',
                'level': 0,
              }
            ],
          }
        ],
      };
      out['streamSettings'] = _streamSettings(p, s);
      out.addAll(muxPart());
    case Protocol.trojan:
      out['protocol'] = 'trojan';
      out['settings'] = {
        'servers': [
          {'address': p.address, 'port': p.port, 'password': p.uuidOrPassword, 'level': 0}
        ],
      };
      out['streamSettings'] = _streamSettings(p, s);
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
          }
        ],
      };
      if (p.plugin.isNotEmpty) {
        // obfs/v2ray plugin settings travel in the stream layer; Xray
        // speaks obfs-local style through sockopt only, so the plugin
        // string is kept on the profile but not forced into the config.
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
            if (p.username.isNotEmpty)
              'users': [
                {'user': p.username, 'pass': p.uuidOrPassword}
              ],
          }
        ],
      };
  }

  if (fragment) {
    final stream = (out['streamSettings'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    stream['sockopt'] = {'dialerProxy': 'frag'};
    out['streamSettings'] = stream;
  }
  return out;
}

Map<String, dynamic> _fragmentOutbound(XraySettings s) => {
      'tag': 'frag',
      'protocol': 'freedom',
      'settings': {
        'fragment': {
          'packets': s.fragmentPackets,
          'length': s.fragmentLength.toString(),
          'interval': s.fragmentInterval.toString(),
        },
      },
      'streamSettings': {
        'network': 'tcp',
        'security': 'none',
        'sockopt': {'tcpNoDelay': true},
      },
    };

bool _isIpLiteral(String a) =>
    a.contains(':') || RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(a);

String? _urlHost(String url) {
  final uri = Uri.tryParse(url);
  return (uri == null || uri.host.isEmpty) ? null : uri.host;
}

/// The tunnel's DNS, shaped like v2rayNG's generated configs (2005):
/// the remote resolver — a public DoH by default — answers every
/// name THROUGH the tunnel. The local resolver is no longer a
/// general fallback (in filtered networks it returns poisoned
/// answers for exactly the domains users tunnel for — ChatGPT and
/// Claude from Iran being the reported case); it survives only as a
/// domain-scoped bootstrap for the names that must resolve before
/// the tunnel exists: the proxy server's own domain and the remote
/// DoH's host. Query strategy is v2rayNG's fixed UseIPv4.
Map<String, dynamic> _dnsSection(XraySettings s, Profile p) {
  final servers = <dynamic>[];
  if (s.fakeDns) servers.add('fakedns');
  servers.add(s.remoteDns);
  final bootstrap = <String>[
    if (!_isIpLiteral(p.address)) 'full:${p.address}',
    if (_urlHost(s.remoteDns) case final host?)
      if (!_isIpLiteral(host)) 'full:$host',
  ];
  if (bootstrap.isNotEmpty) {
    servers.add({'address': s.localDns, 'domains': bootstrap});
  }
  return {
    'hosts': <String, dynamic>{},
    'servers': servers,
    'queryStrategy': 'UseIPv4',
    'tag': 'dns-in',
  };
}

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
  }) =>
      {
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
      rules.add({'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'direct'});
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
/// port setting and stays clear of the SOCKS/HTTP pair.
int statsApiPort(XraySettings s) => s.socksPort + 5000;

List<Map<String, dynamic>> _inbounds(XraySettings s) {
  Map<String, dynamic> inbound(String tag, String protocol, int port) => {
        'tag': tag,
        'listen': '127.0.0.1',
        'port': port,
        'protocol': protocol,
        'sniffing': {
          'enabled': s.sniffing,
          // v2rayNG's default set (2005): http + tls + quic, so
          // domain-based handling also sees QUIC handshakes.
          'destOverride': [
            'http',
            'tls',
            'quic',
            if (s.fakeDns) 'fakedns',
          ],
          'metadataOnly': false,
          'routeOnly': false,
        },
        'settings': {
          'auth': 'noauth',
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
String buildTunnelConfig(Profile p, XraySettings s) {
  final outbound = buildOutbound(p, s, fragment: s.fragmentEnabled);
  if (outbound == null) {
    throw StateError('protocol not supported by the core: ${p.protocol}');
  }
  return prettyJson({
    'log': {'loglevel': 'warning'},
    // The core's own statistics: the per-config traffic totals are
    // read from the "proxy" outbound counters through this local API.
    'stats': <String, dynamic>{},
    'api': {
      'tag': 'api',
      'services': ['StatsService'],
    },
    'dns': _dnsSection(s, p),
    if (s.fakeDns) 'fakedns': [
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
    ],
    'outbounds': [
      outbound,
      {'tag': 'direct', 'protocol': 'freedom', 'settings': <String, dynamic>{}},
      {'tag': 'block', 'protocol': 'blackhole', 'settings': {'response': {'type': 'http'}}},
      {'tag': 'dns-out', 'protocol': 'dns', 'settings': {'nonIPQuery': 'skip'}},
      if (s.fragmentEnabled) _fragmentOutbound(s),
    ],
    'routing': {
      'domainStrategy': s.domainStrategy,
      'rules': [
        // The stats API inbound is served by the core itself; this
        // rule must stay ahead of every preset/custom rule.
        {'type': 'field', 'inboundTag': ['api'], 'outboundTag': 'api'},
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
  });
}

/// The test config: one SOCKS inbound on port 0 — the native tester
/// substitutes the real port before starting the throwaway core.
String buildTestConfig(Profile p, XraySettings s) {
  final outbound = buildOutbound(p, s);
  if (outbound == null) {
    throw StateError('protocol not supported by the core: ${p.protocol}');
  }
  return prettyJson({
    'log': {'loglevel': 'none'},
    'inbounds': [
      {
        'tag': 'socks',
        'listen': '127.0.0.1',
        'port': 0,
        'protocol': 'socks',
        'settings': {'auth': 'noauth', 'udp': false},
      }
    ],
    'outbounds': [
      outbound,
      {'tag': 'direct', 'protocol': 'freedom', 'settings': <String, dynamic>{}},
    ],
  });
}
