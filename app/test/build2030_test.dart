/// Build 2030 gates, host side: the patched core's fields
/// (dialMode / finalmask / +one surfacing, watchdog Shape
/// #4), the EmberWarp profile + argv + chain config shape,
/// the Item-4 DNS policies and protected share links, and
/// the device-state matrix additions (corrupt warp profile,
/// corrupt underlay values, chain over Warp with empty
/// state). The OpenVPN lifecycle repair is native-side; its
/// evidence is the bridge build + the dex/packaging gates.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/shapes.dart';
import 'package:firefox_vpn/xray/shared_link.dart';
import 'package:firefox_vpn/xray/warp_args.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Profile tlsProfile() => Profile(
  id: 'p1',
  name: 't',
  protocol: Protocol.vless,
  address: 'example.com',
  port: 443,
  uuidOrPassword: 'b831381d-6324-4d53-ad4f-8cda48b30811',
  security: 'tls',
  sni: 'example.com',
  fingerprint: 'chrome',
);

Map<String, dynamic> decode(String config) =>
    (jsonDecode(config) as Map).cast<String, dynamic>();

Map<String, dynamic> outboundByTag(Map<String, dynamic> c, String tag) =>
    (c['outbounds'] as List)
        .cast<Map>()
        .map((e) => e.cast<String, dynamic>())
        .firstWhere((o) => o['tag'] == tag);

void main() {
  group('dialMode + finalMask on the profile', () {
    test('JSON round-trip keeps both verbatim', () {
      final p = tlsProfile()
        ..dialMode = 'oob.0,_,12'
        ..finalMask = '{"tcp":[{"type":"merge"}]}';
      final back = Profile.fromJson(p.toJson());
      expect(back.dialMode, 'oob.0,_,12');
      expect(back.finalMask, '{"tcp":[{"type":"merge"}]}');
      final copy = p.copy();
      expect(copy.dialMode, p.dialMode);
      expect(copy.finalMask, p.finalMask);
    });

    test('old stores without the fields read as empty', () {
      final j = tlsProfile().toJson()
        ..remove('dialMode')
        ..remove('finalMask');
      final back = Profile.fromJson(j);
      expect(back.dialMode, '');
      expect(back.finalMask, '');
    });

    test('share link round-trips dialMode EXACTLY (no trim/fold)', () {
      final p = tlsProfile()
        ..dialMode = 'oob.0,AbC'
        ..finalMask = '{"tcp":[]}';
      final link = profileToLink(p);
      expect(link, contains('dialMode=oob.0%2CAbC'));
      final back = parseLink(link);
      expect(back, isNotNull);
      expect(back!.dialMode, 'oob.0,AbC');
      expect(back.finalMask, '{"tcp":[]}');
    });

    test('vmess JSON round-trips dialMode + fm', () {
      final p = Profile(
        id: 'p2',
        name: 'v',
        protocol: Protocol.vmess,
        address: 'example.com',
        uuidOrPassword: 'b831381d-6324-4d53-ad4f-8cda48b30811',
        dialMode: 'oob.1',
        finalMask: '{"udp":[]}',
      );
      final back = parseLink(profileToLink(p));
      expect(back, isNotNull);
      expect(back!.dialMode, 'oob.1');
      expect(back.finalMask, '{"udp":[]}');
    });
  });

  group('patched-core fields in generated configs', () {
    test('dialMode lands in the proxy sockopt', () {
      final p = tlsProfile()..dialMode = 'oob.0,_,12';
      final c = decode(buildTunnelConfig(p, XraySettings()));
      final proxy = outboundByTag(c, 'proxy');
      final sock = (proxy['streamSettings'] as Map)['sockopt'] as Map;
      expect(sock['dialMode'], 'oob.0,_,12');
    });

    test('with the fragment chain, dialMode rides BOTH hops and '
        'the dialerProxy survives', () {
      final p = tlsProfile()..dialMode = 'oob.0';
      final s = XraySettings()..fragmentEnabled = true;
      final c = decode(buildTunnelConfig(p, s));
      final proxy = outboundByTag(c, 'proxy');
      final pSock = (proxy['streamSettings'] as Map)['sockopt'] as Map;
      expect(pSock['dialMode'], 'oob.0');
      expect(pSock['dialerProxy'], 'frag');
      final frag = outboundByTag(c, 'frag');
      final fSock = (frag['streamSettings'] as Map)['sockopt'] as Map;
      expect(fSock['dialMode'], 'oob.0');
      expect(fSock['tcpNoDelay'], true);
    });

    test('finalMask JSON lands in streamSettings.finalmask', () {
      final p = tlsProfile()
        ..finalMask =
            '{"tcp":[{"type":"merge","settings":'
            '{"times":3,"delayMs":8,"maxBytes":2048}}]}';
      final c = decode(buildTunnelConfig(p, XraySettings()));
      final proxy = outboundByTag(c, 'proxy');
      final fm = (proxy['streamSettings'] as Map)['finalmask'] as Map;
      final tcp = (fm['tcp'] as List).first as Map;
      expect(tcp['type'], 'merge');
      expect((tcp['settings'] as Map)['times'], 3);
    });

    test('malformed finalMask is skipped, never fatal', () {
      final p = tlsProfile()..finalMask = '{not json';
      final c = decode(buildTunnelConfig(p, XraySettings()));
      final proxy = outboundByTag(c, 'proxy');
      expect((proxy['streamSettings'] as Map)['finalmask'], isNull);
    });

    test('the test config carries dialMode too', () {
      final p = tlsProfile()..dialMode = 'oob.0';
      final c = decode(buildTestConfig(p, XraySettings()));
      final proxy = outboundByTag(c, 'proxy');
      final sock = (proxy['streamSettings'] as Map)['sockopt'] as Map;
      expect(sock['dialMode'], 'oob.0');
    });
  });

  group('watchdog Shape #4 (dialMode)', () {
    test('TLS profiles escalate s0→s1→s2→s3', () {
      expect(shapesFor(tlsProfile()), ['s0', 's1', 's2', 's3']);
      final shaped = profileWithShape(tlsProfile(), shapeDialMode);
      expect(shaped.dialMode, 'oob.0');
      expect(shapeLabel(shapeDialMode), contains('dialMode'));
    });

    test('non-TLS profiles stay stock-only', () {
      final p = tlsProfile()..security = 'reality';
      expect(shapesFor(p), ['s0']);
    });
  });

  group('EmberWarp profile + argv', () {
    test('defaults are the dossier defaults', () {
      final w = WarpProfile();
      expect(w.protocol, 'masque');
      expect(w.transport, 'h2');
      expect(w.scan, 'balanced');
      expect(w.ipVersion, 'v4');
      expect(w.fragment, isTrue);
    });

    test('corrupt stored values read as defaults', () {
      final w = WarpProfile.fromJson({
        'protocol': 'bogus',
        'transport': 42,
        'scan': 'ludicrous',
        'ipVersion': 'v9',
        'fragment': 'yes',
        'ech': 1,
      });
      expect(w.protocol, 'masque');
      expect(w.transport, 'h2');
      expect(w.scan, 'balanced');
      expect(w.ipVersion, 'v4');
      expect(w.fragment, isTrue);
      expect(w.ech, isFalse);
    });

    test('argv always carries protocol+scan+ip (never prompts)', () {
      final args = buildWarpArgs(WarpProfile());
      expect(args, containsAllInOrder(['--protocol', 'masque']));
      expect(args, containsAllInOrder(['--scan', 'balanced']));
      expect(args, containsAllInOrder(['--ip', 'v4']));
      expect(args, containsAllInOrder(['--bind', '127.0.0.1:20850']));
    });

    test('H2 default: --h2 + --fragment + SNI; H3 drops both', () {
      final h2 = buildWarpArgs(WarpProfile());
      expect(h2, contains('--h2'));
      expect(h2, contains('--fragment'));
      expect(h2, containsAllInOrder(['--masque-sni', 'www.cloudflare.com']));
      final h3 = buildWarpArgs(WarpProfile()..transport = 'h3');
      expect(h3, isNot(contains('--h2')));
      expect(h3, isNot(contains('--fragment')));
    });

    test('wg carries no MASQUE flags; upstream + peer pass through', () {
      final wg = buildWarpArgs(WarpProfile()..protocol = 'wg');
      expect(wg, isNot(contains('--masque-sni')));
      expect(wg, isNot(contains('--h2')));
      final chained = buildWarpArgs(
        WarpProfile()..peer = '162.159.198.2:4500',
        upstream: 'socks5://127.0.0.1:20851',
      );
      expect(
        chained,
        containsAllInOrder(['--upstream', 'socks5://127.0.0.1:20851']),
      );
      expect(
        chained,
        containsAllInOrder(['--peer', '162.159.198.2:4500']),
      );
    });

    test('ECH on: the lookup resolver is encrypted, never 1.1.1.1', () {
      final args = buildWarpArgs(WarpProfile()..ech = true);
      final i = args.indexOf('--ech-dns');
      expect(i, greaterThan(0));
      expect(args[i + 1], warpDefaultEchDns);
      expect(args.join(' '), isNot(contains('1.1.1.1')));
      final custom = buildWarpArgs(
        WarpProfile()
          ..ech = true
          ..echDns = 'https://dns.quad9.net/dns-query',
      );
      expect(
        custom[custom.indexOf('--ech-dns') + 1],
        'https://dns.quad9.net/dns-query',
      );
    });

    test('ports are the dossier range, never the upstream defaults', () {
      expect(warpSessionPort, 20850);
      expect(warpExitPort, 20851);
      expect(warpProbePort, 20853);
      expect(warpProbeExitPort, 20854);
      for (final p in [
        warpSessionPort,
        warpExitPort,
        warpProbePort,
        warpProbeExitPort,
      ]) {
        expect(p, isNot(1819));
        expect(p, isNot(10819));
      }
    });
  });

  group('chain over Warp config shape', () {
    test('secondary inbound + exit-node + first routing rule', () {
      final w = WarpProfile()
        ..dialMode = 'oob.0'
        ..finalMask = '{"tcp":[{"type":"merge"}]}';
      final c = decode(
        buildTunnelConfig(
          tlsProfile(),
          XraySettings(),
          warpUnderlay: true,
          warp: w,
        ),
      );
      // The underlay outbound points at the core's SOCKS.
      final under = outboundByTag(c, 'warp-underlay');
      expect(under['protocol'], 'socks');
      final server =
          ((under['settings'] as Map)['servers'] as List).first as Map;
      expect(server['address'], '127.0.0.1');
      expect(server['port'], 20850);
      // The exit-node carries the WARP profile's shaping.
      final exit = outboundByTag(c, 'exit-node');
      expect(exit['protocol'], 'freedom');
      final eStream = exit['streamSettings'] as Map;
      expect((eStream['sockopt'] as Map)['dialMode'], 'oob.0');
      expect(
        (((eStream['finalmask'] as Map)['tcp'] as List).first as Map)['type'],
        'merge',
      );
      // The secondary inbound listens on the exit port.
      final inbounds = (c['inbounds'] as List)
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      final secondary = inbounds.firstWhere(
        (i) => i['tag'] == 'secondary-socks',
      );
      expect(secondary['port'], 20851);
      expect(secondary['protocol'], 'mixed');
      // The exit rule is the FIRST routing rule after the api rule.
      final rules = ((c['routing'] as Map)['rules'] as List)
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      expect((rules[0]['inboundTag'] as List), ['api']);
      expect((rules[1]['inboundTag'] as List), ['secondary-socks']);
      expect(rules[1]['outboundTag'], 'exit-node');
      // The proxy dials through the underlay.
      final proxy = outboundByTag(c, 'proxy');
      final sock = (proxy['streamSettings'] as Map)['sockopt'] as Map;
      expect(sock['dialerProxy'], 'warp-underlay');
    });

    test('ECH lookup rides the warp underlay when chained', () {
      final p = tlsProfile()..afEch = true;
      final c = decode(
        buildTunnelConfig(p, XraySettings(), warpUnderlay: true),
      );
      final proxy = outboundByTag(c, 'proxy');
      final tls = (proxy['streamSettings'] as Map)['tlsSettings'] as Map;
      expect((tls['echSockopt'] as Map)['dialerProxy'], 'warp-underlay');
      // No dedicated ech-out outbound is emitted in chain mode.
      expect(
        (c['outbounds'] as List).any(
          (o) => (o as Map)['tag'] == 'ech-out',
        ),
        isFalse,
      );
    });

    test('chain over Warp with EMPTY warp state still builds', () {
      // The device-state rule: a first-run chain (no identity,
      // default profile) must produce a complete config.
      final c = decode(
        buildTunnelConfig(
          tlsProfile(),
          XraySettings(),
          warpUnderlay: true,
          warp: WarpProfile.fromJson({}),
        ),
      );
      expect(outboundByTag(c, 'exit-node')['protocol'], 'freedom');
      expect(outboundByTag(c, 'warp-underlay')['protocol'], 'socks');
    });

    test('no warp pieces leak into an unchained config', () {
      final c = decode(buildTunnelConfig(tlsProfile(), XraySettings()));
      expect(
        (c['outbounds'] as List).any(
          (o) => (o as Map)['tag'] == 'warp-underlay',
        ),
        isFalse,
      );
      expect(
        (c['inbounds'] as List).any(
          (o) => (o as Map)['tag'] == 'secondary-socks',
        ),
        isFalse,
      );
    });
  });

  group('Item 4: DNS policies', () {
    Map<String, dynamic> dnsOf(XraySettings s) =>
        decode(buildTunnelConfig(tlsProfile(), s))['dns']
            as Map<String, dynamic>;

    test('ad-block preset swaps the primary resolver for AdGuard', () {
      final s = XraySettings()..adBlockDoh = true;
      final dns = dnsOf(s);
      expect((dns['servers'] as List).first, adGuardDohUrl);
      expect(
        (dns['hosts'] as Map)['dns.adguard-dns.com'],
        ['94.140.14.14', '94.140.15.15'],
      );
    });

    test('fallback appends AFTER the primary', () {
      final s = XraySettings()
        ..dnsFallback = true
        ..fallbackDns = 'https://dns.quad9.net/dns-query';
      final servers = dnsOf(s)['servers'] as List;
      expect(servers.first, s.remoteDns);
      expect(servers.last, 'https://dns.quad9.net/dns-query');
    });

    test('both on: ad-block wins the primary slot, fallback remains', () {
      final s = XraySettings()
        ..adBlockDoh = true
        ..dnsFallback = true;
      final servers = dnsOf(s)['servers'] as List;
      expect(servers.first, adGuardDohUrl);
      expect(servers, contains(s.fallbackDns));
      expect(servers.length, 2);
    });

    test('fallback equal to the primary is not duplicated', () {
      final s = XraySettings()..dnsFallback = true;
      s.fallbackDns = s.remoteDns;
      final servers = dnsOf(s)['servers'] as List;
      expect(servers.length, 1);
    });

    test('settings round-trip keeps the new fields + warp underlay', () {
      final s = XraySettings()
        ..adBlockDoh = true
        ..dnsFallback = true
        ..underlay = 'warp';
      final back = XraySettings.fromJson(s.toJson());
      expect(back.adBlockDoh, isTrue);
      expect(back.dnsFallback, isTrue);
      expect(back.underlay, 'warp');
    });

    test('a corrupt underlay value reads as none', () {
      final j = XraySettings().toJson()..['underlay'] = 'warp-plus';
      expect(XraySettings.fromJson(j).underlay, 'none');
      final j2 = XraySettings().toJson()..['underlay'] = 42;
      expect(XraySettings.fromJson(j2).underlay, 'none');
    });
  });

  group('protected expiring share links', () {
    const inner = 'vless://abc@example.com:443?security=tls#x';

    test('create → open round-trips the inner link', () {
      final link = createProtectedShareLink(
        inner,
        'pw123',
        ttl: const Duration(hours: 24),
      );
      expect(link, startsWith(protectedSharePrefix));
      final opened = openProtectedShareLink(link, 'pw123');
      expect(opened, isNotNull);
      expect(opened!.link, inner);
      expect(opened.expired, isFalse);
    });

    test('wrong password and tampering both fail closed', () {
      final link = createProtectedShareLink(
        inner,
        'pw123',
        ttl: const Duration(hours: 1),
      );
      expect(openProtectedShareLink(link, 'nope'), isNull);
      final tampered = link.replaceRange(
        link.length - 3,
        link.length - 2,
        link[link.length - 3] == 'A' ? 'B' : 'A',
      );
      expect(openProtectedShareLink(tampered, 'pw123'), isNull);
    });

    test('expiry is advisory: an expired link still opens, flagged', () {
      final t0 = DateTime(2026, 1, 1);
      final link = createProtectedShareLink(
        inner,
        'pw',
        ttl: const Duration(hours: 1),
        now: t0,
      );
      final opened = openProtectedShareLink(
        link,
        'pw',
        now: t0.add(const Duration(hours: 2)),
      );
      expect(opened, isNotNull);
      expect(opened!.expired, isTrue);
      expect(opened.link, inner);
      expect(protectedShareExpiryHint(link), isNotNull);
    });

    test('unlock replaces protected lines inside a mixed paste', () {
      final link = createProtectedShareLink(
        inner,
        'pw',
        ttl: const Duration(days: 1),
      );
      final text = 'ss://aaaa@h:1#plain\n$link\n';
      expect(containsProtectedShare(text), isTrue);
      final out = unlockProtectedShares(text, 'pw');
      expect(out, isNotNull);
      expect(out, contains(inner));
      expect(out, contains('ss://aaaa@h:1#plain'));
      expect(unlockProtectedShares(text, 'bad'), isNull);
    });
  });
}
