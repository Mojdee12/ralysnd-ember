/// Build 2049 gates, host side: the urgent browsing fix from the
/// owner's device logs of 2026-11-14 (audit:
/// ~/workspace/ember-app/v2ray-browse-failure-audit-2026-11-14.md).
///
/// Three causes, three fixes pinned here on the Dart side:
///
/// A. The proxy server was dialed over IPv6 and the dial EOF'd
///    ("websocket: failed to dial to [2606:4700:...]:443 > EOF").
///    Every outbound that dials a server now carries the stream
///    sockopt domainStrategy 'UseIPv4' — the lever the bundled
///    core's dialer honours for the outbound's own destination
///    (transport/internet/dialer.go resolves a domain
///    destination via LookupForIP with the strategy's IP option
///    before dialing) — and the DNS section carries
///    queryStrategy 'UseIPv4', so the core's resolver returns A
///    answers only. The stored hostname stays the address and
///    stays in SNI/Host; IP-literal servers (v4 and v6) are
///    emitted exactly as before.
///
/// B. The default DNS section had exactly ONE server — a DoH
///    through the tunnel — and when its POSTs timed out
///    ("context deadline exceeded" for nearly every name) all
///    browsing stalled. In the shipped default shape a bounded
///    built-in fallback now rides along: DNS-over-TCP to
///    Quad9's pinned IP. Any explicit user DNS choice (custom
///    resolver, ad-block resolver, DNS group, own fallback)
///    leaves the section untouched.
///
/// C. The core restart race (kill/restartCore never confirming
///    port 10808 free) is Kotlin-side and not host-testable
///    here; it is pinned by the service code itself.
///    Build 2110 addendum: the FRESH-start half of that race —
///    startTunnel never calling stopProcesses(), holding no
///    coreLock, and the orphan sweep's blanket live-process
///    guard blinding it to this instance's own tracked core —
///    is now fixed and pinned in build2110_test.dart (the
///    fresh-start source pin this header always lacked).
///
/// The scheduled run's failover-handover half of build 2049 is
/// pinned in build2049_test.dart.
///
/// Build 2101 addendum (owner order 2026-11-18, «حفاظت ول کن» —
/// DNS defaults become v2rayNG's own, FULL adoption): fix A's
/// sockopt domainStrategy pin and the DNS queryStrategy pin,
/// and fix B's built-in Quad9-TCP fallback, are REMOVED —
/// named removals, see BUILD-LOG-2.md 2101. The assertions
/// below were updated to pin the post-removal shape (no
/// strategy emitted anywhere; the default DNS section is
/// v2rayNG's: Cloudflare DoH alone, disableFallbackIfMatch,
/// no queryStrategy) while keeping everything the removal did
/// NOT touch: the hostname stays the address and stays in
/// SNI/Host, IP literals are emitted unchanged, the chain
/// wiring (dialerProxy) and dialMode merging still work, and
/// the user's own fallback / DNS group / ad-block choices
/// behave exactly as before.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Map<String, dynamic> outboundByTag(Map<String, dynamic> cfg, String tag) =>
    (cfg['outbounds'] as List).cast<Map<String, dynamic>>().firstWhere(
      (o) => o['tag'] == tag,
    );

Map<String, dynamic> sockoptOf(Map<String, dynamic> outbound) =>
    ((outbound['streamSettings'] as Map?)?['sockopt'] as Map?)
        ?.cast<String, dynamic>() ??
    <String, dynamic>{};

Profile wsProfile({
  String address = 'node.example.com',
  Protocol protocol = Protocol.vless,
}) => Profile(
  id: 'p',
  protocol: protocol,
  name: 't',
  address: address,
  port: 443,
  uuidOrPassword: protocol == Protocol.trojan
      ? 'secret'
      : '11111111-1111-1111-1111-111111111111',
  security: 'tls',
  network: 'ws',
  host: 'cdn.example.com',
  path: '/ws',
  sni: 'cdn.example.com',
);

void main() {
  group('IPv4-only server dial (build 2049, fix A — pin removed '
      'in build 2101 by owner order)', () {
    test('WS VLESS tunnel config: no strategy on the proxy outbound, '
        'hostname kept as address, SNI and Host', () {
      final cfg = decode(buildTunnelConfig(wsProfile(), XraySettings()));
      final proxy = outboundByTag(cfg, 'proxy');
      expect(sockoptOf(proxy)['domainStrategy'], isNull);
      final vnext =
          ((proxy['settings'] as Map)['vnext'] as List).first as Map;
      expect(vnext['address'], 'node.example.com');
      final stream = proxy['streamSettings'] as Map;
      expect((stream['tlsSettings'] as Map)['serverName'], 'cdn.example.com');
      expect(
        ((stream['wsSettings'] as Map)['headers'] as Map)['Host'],
        'cdn.example.com',
      );
    });

    test('the delay-test config exercises the same dial path', () {
      final cfg = decode(buildTestConfig(wsProfile(), XraySettings()));
      final proxy = outboundByTag(cfg, 'proxy');
      expect(sockoptOf(proxy)['domainStrategy'], isNull);
    });

    test('Trojan and VMess outbounds carry no strategy (2101)', () {
      for (final proto in [Protocol.trojan, Protocol.vmess]) {
        final out = buildOutbound(wsProfile(protocol: proto), XraySettings());
        expect(out, isNotNull);
        expect(sockoptOf(out!)['domainStrategy'], isNull, reason: '$proto');
      }
    });

    test('Shadowsocks and SOCKS outbounds carry no strategy (2101)', () {
      final ss = Profile(
        id: 's',
        protocol: Protocol.shadowsocks,
        name: 's',
        address: 'ss.example.com',
        port: 8388,
        uuidOrPassword: 'pw',
        method: 'aes-256-gcm',
      );
      final ssOut = buildOutbound(ss, XraySettings());
      expect(sockoptOf(ssOut!)['domainStrategy'], isNull);
      final sk = Profile(
        id: 'k',
        protocol: Protocol.socks,
        name: 'k',
        address: 'socks.example.com',
        port: 1080,
        uuidOrPassword: 'pw',
        username: 'user',
      );
      final skOut = buildOutbound(sk, XraySettings());
      expect(sockoptOf(skOut!)['domainStrategy'], isNull);
    });

    test('Hysteria2 carries no strategy in its own stream settings (2101)', () {
      final hy2 = Profile(
        id: 'h',
        protocol: Protocol.hysteria2,
        name: 'h',
        address: 'h.example.com',
        port: 443,
        uuidOrPassword: 'pw',
        sni: 'h.example.com',
      );
      final cfg = decode(buildTunnelConfig(hy2, XraySettings()));
      expect(
        sockoptOf(outboundByTag(cfg, 'proxy'))['domainStrategy'],
        isNull,
      );
    });

    test('an IPv6-literal server address is emitted unchanged', () {
      final out = buildOutbound(
        wsProfile(address: '2001:db8::10'),
        XraySettings(),
      );
      final vnext = ((out!['settings'] as Map)['vnext'] as List).first as Map;
      expect(vnext['address'], '2001:db8::10');
    });

    test('an IPv4-literal server address is emitted unchanged', () {
      final out = buildOutbound(
        wsProfile(address: '203.0.113.7'),
        XraySettings(),
      );
      final vnext = ((out!['settings'] as Map)['vnext'] as List).first as Map;
      expect(vnext['address'], '203.0.113.7');
    });

    test('fragment chain: the proxy sockopt keeps its dialerProxy '
        'and neither hop carries the strategy (2101)', () {
      final s = XraySettings()..fragmentEnabled = true;
      final cfg = decode(buildTunnelConfig(wsProfile(), s));
      final proxy = outboundByTag(cfg, 'proxy');
      expect(sockoptOf(proxy)['dialerProxy'], 'frag');
      expect(sockoptOf(proxy)['domainStrategy'], isNull);
      expect(
        sockoptOf(outboundByTag(cfg, 'frag'))['domainStrategy'],
        isNull,
      );
    });

    test('Psiphon chain: the dialerProxy survives the removal', () {
      final cfg = decode(
        buildTunnelConfig(wsProfile(), XraySettings(), psiphonUnderlay: true),
      );
      final proxy = outboundByTag(cfg, 'proxy');
      expect(sockoptOf(proxy)['dialerProxy'], 'psiphon-underlay');
      expect(sockoptOf(proxy)['domainStrategy'], isNull);
    });

    test('Warp chain: the exit node carries no strategy and the proxy '
        'keeps its chain wiring (2101)', () {
      final cfg = decode(
        buildTunnelConfig(
          wsProfile(),
          XraySettings(),
          warpUnderlay: true,
          warp: WarpProfile(),
        ),
      );
      final proxy = outboundByTag(cfg, 'proxy');
      expect(sockoptOf(proxy)['dialerProxy'], 'warp-underlay');
      expect(sockoptOf(proxy)['domainStrategy'], isNull);
      expect(
        sockoptOf(outboundByTag(cfg, 'exit-node'))['domainStrategy'],
        isNull,
      );
    });

    test('a stored dialMode still merges into the same sockopt', () {
      final p = wsProfile()..dialMode = 'oob';
      final out = buildOutbound(p, XraySettings());
      expect(sockoptOf(out!)['dialMode'], 'oob');
      expect(sockoptOf(out)['domainStrategy'], isNull);
    });
  });

  group('DNS resilience (build 2049, fix B — built-in fallback '
      'removed in build 2101 by owner order)', () {
    List<dynamic> serversOf(Map<String, dynamic> cfg) =>
        (cfg['dns'] as Map)['servers'] as List;

    test('default settings: v2rayNG\u2019s shape — the single remote entry, '
        'no queryStrategy, disableFallbackIfMatch set', () {
      final cfg = decode(buildTunnelConfig(wsProfile(), XraySettings()));
      // Build 2113: the single entry is v2rayNG's Cloudflare
      // DoH (the 2111 UDP-first pair and its append are gone);
      // the rest of the shape is 2101's.
      expect(serversOf(cfg), [
        'https://cloudflare-dns.com/dns-query',
      ]);
      expect((cfg['dns'] as Map).containsKey('queryStrategy'), isFalse);
      expect((cfg['dns'] as Map)['disableFallbackIfMatch'], isTrue);
    });

    test('the test config carries the same DNS section', () {
      final cfg = decode(buildTestConfig(wsProfile(), XraySettings()));
      expect(serversOf(cfg), [
        'https://cloudflare-dns.com/dns-query',
      ]);
      expect((cfg['dns'] as Map).containsKey('queryStrategy'), isFalse);
    });

    test('a custom remote resolver is left exactly as it was', () {
      final s = XraySettings()
        ..remoteDns = 'https://dns.example.net/dns-query';
      final cfg = decode(buildTunnelConfig(wsProfile(), s));
      expect(serversOf(cfg), ['https://dns.example.net/dns-query']);
    });

    test('the user fallback is the only fallback there is (2101)', () {
      final s = XraySettings()..dnsFallback = true;
      final cfg = decode(buildTunnelConfig(wsProfile(), s));
      // Build 2113: behind the single primary entry, the
      // user's own fallback is still the only ADDED fallback
      // there is.
      expect(serversOf(cfg), [
        'https://cloudflare-dns.com/dns-query',
        'https://dns.quad9.net/dns-query',
      ]);
    });

    test('the DNS group is unchanged apart from the new primary', () {
      final s = XraySettings()..dnsGroup = true;
      final cfg = decode(buildTunnelConfig(wsProfile(), s));
      // Build 2113: the group members follow the single
      // primary; the Cloudflare member dedupes against the
      // primary itself.
      expect(serversOf(cfg), [
        'https://cloudflare-dns.com/dns-query',
        'https://dns.google/dns-query',
        'https://dns.quad9.net/dns-query',
      ]);
    });

    test('the ad-block resolver is unchanged', () {
      final s = XraySettings()..adBlockDoh = true;
      final cfg = decode(buildTunnelConfig(wsProfile(), s));
      expect(serversOf(cfg), [adGuardDohUrl]);
    });

    test('fakeDNS still leads; nothing rides behind the primary (2101)', () {
      final s = XraySettings()..fakeDns = true;
      final cfg = decode(buildTunnelConfig(wsProfile(), s));
      // Build 2113: behind fakeDNS rides the single primary
      // entry; nothing else follows.
      expect(serversOf(cfg), [
        'fakedns',
        'https://cloudflare-dns.com/dns-query',
      ]);
    });

    test('DNS-over-TCP mode: the primary alone, over TCP (2101)', () {
      final s = XraySettings()..remoteDnsProto = 'tcp';
      final cfg = decode(buildTunnelConfig(wsProfile(), s));
      expect(serversOf(cfg), ['tcp://1.1.1.1']);
    });
  });
}
