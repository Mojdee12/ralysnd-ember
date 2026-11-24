// Build 2103 — the V2Ray v2rayNG-alignment + naming fix
// build (owner reports 2026-11-18 05:35–05:49, diagnosis
// v2ray-2101-partial-and-naming-diagnosis.md): on 2101 the
// tunnel connected but only Telegram + YouTube worked (the
// same configs work fully in v2rayNG), and panel configs
// displayed their server address instead of a name. Every
// row of the diagnosis's 9-row deviation table is closed
// here: D1/E1 IPv6 blackhole (default OFF + migration +
// the AWG decoupling), D2/E2 dns-module → proxy rule,
// D3/E3 sniffQuic default OFF, D4 freedom sockopt stamp
// removed, D5 comma-list remote DNS + enableParallelQuery,
// D6 aligned (no change — v2rayNG's default resolve
// method "1" leaves the domain in the outbound), N1 the
// JSON route reads remarks/tag, N2 no route stores the
// address as a name any more + the stored-name heal.
//
// All fixtures use dummy values — the owner's real
// configs and keys never appear in tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/sub_fetcher.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Map<String, dynamic> outboundByTag(Map<String, dynamic> config, String tag) =>
    (config['outbounds'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((o) => o['tag'] == tag);

List<Map<String, dynamic>> rulesOf(Map<String, dynamic> config) =>
    (config['routing']['rules'] as List).cast<Map<String, dynamic>>();

/// The owner's acceptance shape: a VLESS+REALITY profile
/// addressed by HOSTNAME, fp=ios (the fugui sample's
/// shape, dummy values).
Profile hostnameVless() => Profile(
  id: 'p1',
  name: 'hostname-vless',
  protocol: Protocol.vless,
  address: 'free.example.net',
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  network: 'tcp',
  security: 'reality',
  sni: 'www.example.com',
  fingerprint: 'ios',
  flow: 'xtls-rprx-vision',
  publicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  shortId: '01ab',
);

void main() {
  group('journey 1 — the fugui shape under the aligned defaults', () {
    test('DNS-module queries are pinned to the proxy by rule (E2)', () {
      final config = decode(buildTunnelConfig(hostnameVless(), XraySettings()));
      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['tag'], 'dns-module');
      final rules = rulesOf(config);
      final dnsModuleAt = rules.indexWhere(
        (r) => (r['inboundTag'] as List?)?.contains('dns-module') ?? false,
      );
      final dnsRedirectAt = rules.indexWhere((r) => r['port'] == '53');
      expect(dnsModuleAt, greaterThanOrEqualTo(0),
          reason: 'the rule v2rayNG emits exists — DNS no '
              'longer falls through to the first outbound');
      expect(rules[dnsModuleAt]['outboundTag'], 'proxy');
      // Build 2113: upstream APPENDS the dns-module rule
      // after every preset rule — it is LAST — and there is
      // no port-53 redirect under default settings (that
      // rule exists only with fakeDNS on).
      expect(dnsModuleAt, rules.length - 1,
          reason: 'the dns-module rule is last, upstream\u2019s '
              'position');
      expect(dnsRedirectAt, -1);
    });

    test('the REALITY half of the shape survives generation (M2)', () {
      final config = decode(buildTunnelConfig(hostnameVless(), XraySettings()));
      final proxy = outboundByTag(config, 'proxy');
      final vnext = (proxy['settings']['vnext'] as List).first
          as Map<String, dynamic>;
      final user = (vnext['users'] as List).first as Map<String, dynamic>;
      expect(user['flow'], 'xtls-rprx-vision');
      final stream = proxy['streamSettings'] as Map<String, dynamic>;
      expect(stream['security'], 'reality');
      final reality = stream['realitySettings'] as Map<String, dynamic>;
      expect(reality['serverName'], 'www.example.com');
      expect(reality['fingerprint'], 'ios',
          reason: 'the fugui shape\'s fp=ios reaches the '
              'handshake as-is');
      expect(reality['publicKey'],
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
      expect(reality['shortId'], '01ab');
    });

    test('rule order with direct domains: domestic first, '
        'dns-module last, no port-53 (M2)', () {
      final s = XraySettings()..customDirectDomains = ['example.ir'];
      final config = decode(buildTunnelConfig(hostnameVless(), s));
      final rules = rulesOf(config);
      int at(bool Function(Map<String, dynamic>) test) =>
          rules.indexWhere(test);
      final domesticAt = at(
          (r) => (r['inboundTag'] as List?)?.contains('domestic-dns') ?? false);
      final dnsModuleAt = at(
          (r) => (r['inboundTag'] as List?)?.contains('dns-module') ?? false);
      final redirectAt = at((r) => r['port'] == '53');
      expect(domesticAt, greaterThanOrEqualTo(0));
      expect(rules[domesticAt]['outboundTag'], 'direct');
      expect(rules[dnsModuleAt]['outboundTag'], 'proxy');
      // Build 2113: upstream brackets the posture's rules —
      // the domestic rule is inserted first and the
      // dns-module rule appended last; the port-53 redirect
      // exists only with fakeDNS on, so it is absent here
      // (an api stats rule may precede all of these — the
      // relative order is the pin).
      expect(domesticAt, lessThan(dnsModuleAt),
          reason: 'v2rayNG\'s order: the domestic rule leads '
              'and the dns-module rule closes the list');
      expect(dnsModuleAt, rules.length - 1);
      expect(redirectAt, -1);
    });

    test('the server domain stays in the outbound (D6 parity)', () {
      final config = decode(buildTunnelConfig(hostnameVless(), XraySettings()));
      final proxy = outboundByTag(config, 'proxy');
      final vnext = (proxy['settings']['vnext'] as List).first
          as Map<String, dynamic>;
      expect(vnext['address'], 'free.example.net',
          reason: 'v2rayNG\'s default resolve method ("1") '
              'leaves the domain in the outbound for the '
              'core\'s DNS section to resolve — no pre-resolution, '
              'no sockopt pin');
    });

    test('no IPv6 blackhole under the new defaults (E1)', () {
      final s = XraySettings();
      expect(s.ipv6Route, isFalse,
          reason: 'v2rayNG parity: PREF_IPV6_ENABLED '
              'defaults off, and its TUN then carries no '
              'IPv6 address or route at all');
      // The service still honours an explicit ON — the
      // gate itself is untouched, only the default moved.
      final kt = ktSrc('XrayVpnService.kt');
      expect(kt, contains('if (ipv6) {'));
      expect(kt, contains('builder.addRoute("::", 0)'));
    });

    test('the default sniffing set is v2rayNG\'s: http + tls (E3)', () {
      final config = decode(buildTunnelConfig(hostnameVless(), XraySettings()));
      final inbound = (config['inbounds'] as List).first
          as Map<String, dynamic>;
      expect(
        (inbound['sniffing'] as Map<String, dynamic>)['destOverride'],
        ['http', 'tls'],
        reason: 'QUIC sniffing was an Ember extra ON by '
            'default; it is opt-in now',
      );
    });

    test('the direct outbound carries the upstream sockopt '
        'stamp (D4, restored in 2113)', () {
      final decoded = decode(buildTunnelConfig(hostnameVless(), XraySettings()));
      final direct = outboundByTag(decoded, 'direct');
      // Build 2113: the premise is REVERSED — upstream's
      // #5656 removed the freedom SETTINGS field, but its
      // generated config still carries the template's
      // streamSettings.sockopt stamp (UseIP + happyEyeballs,
      // no prioritizeIPv6 key), and the outbound carries NO
      // 'settings' key.
      expect(direct, {
        'tag': 'direct',
        'protocol': 'freedom',
        'streamSettings': {
          'network': 'tcp',
          'sockopt': {
            'domainStrategy': 'UseIP',
            'happyEyeballs': {
              'maxConcurrentTry': 4,
              'tryDelayMs': 250,
              'interleave': 2,
            },
          },
        },
      });
      expect(direct.containsKey('settings'), isFalse);
    });

    test('the 2101 DNS shape survives intact', () {
      final config = decode(buildTunnelConfig(hostnameVless(), XraySettings()));
      final dns = config['dns'] as Map<String, dynamic>;
      // Build 2113: the servers list is the single Cloudflare
      // DoH entry; every other element of the 2101 shape is
      // untouched.
      expect(dns['servers'], [
        'https://cloudflare-dns.com/dns-query',
      ]);
      expect(dns.containsKey('queryStrategy'), isFalse);
      expect(dns['disableFallbackIfMatch'], isTrue);
      expect(dns.containsKey('enableParallelQuery'), isFalse,
          reason: 'one remote entry plus the domestic count '
              'of one totals two — v2rayNG emits the flag only '
              'above two');
    });
  });

  group('D5 — the remote DNS is a comma list, as in v2rayNG', () {
    test('two stored entries both land in the section', () {
      final s = XraySettings()
        ..remoteDns =
            'https://dns.google/dns-query, https://dns.quad9.net/dns-query';
      final config = decode(buildTunnelConfig(hostnameVless(), s));
      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['servers'], [
        'https://dns.google/dns-query',
        'https://dns.quad9.net/dns-query',
      ]);
      // Build 2113 (upstream's count): primaries (2) plus
      // the domestic list's one entry exceed two, so the
      // flag is emitted.
      expect(dns['enableParallelQuery'], isTrue);
    });

    test('above two real servers the section races them', () {
      final s = XraySettings()
        ..remoteDns =
            'https://dns.google/dns-query, https://dns.quad9.net/dns-query'
        ..customDirectDomains = ['example.ir'];
      final config = decode(buildTunnelConfig(hostnameVless(), s));
      final dns = config['dns'] as Map<String, dynamic>;
      // Scoped domestic + two primaries = three real servers.
      expect((dns['servers'] as List).length, 3);
      expect(dns['enableParallelQuery'], isTrue);
    });

    test('each list entry is mapped through the transport', () {
      final s = XraySettings()
        ..remoteDnsProto = 'tcp'
        ..remoteDns =
            'https://dns.google/dns-query, https://cloudflare-dns.com/dns-query';
      expect(primaryResolvers(s), ['tcp://8.8.8.8', 'tcp://1.1.1.1']);
    });

    test('duplicate spellings of one resolver collapse (L1)', () {
      final s = XraySettings()
        ..remoteDnsProto = 'tcp'
        ..remoteDns =
            'https://dns.google/dns-query, https://dns.google/resolve';
      expect(primaryResolvers(s), ['tcp://8.8.8.8'],
          reason: 'two stored URLs for one provider map to '
              'the same resolver under the transport — the '
              'list carries it once, as v2rayNG\'s does');
    });

    test('the user fallback does not inflate the parallel '
        'count (L1)', () {
      // Build 2113 premise: with ONE stored primary the
      // upstream count (primaries + the domestic list's one
      // entry) is exactly two — if the emitted fallback
      // counted, the total would exceed two and the flag
      // would appear. It must not.
      final s = XraySettings()
        ..remoteDns = 'https://dns.google/dns-query'
        ..dnsFallback = true
        ..fallbackDns = 'https://cloudflare-dns.com/dns-query';
      final config = decode(buildTunnelConfig(hostnameVless(), s));
      final dns = config['dns'] as Map<String, dynamic>;
      // Two servers are EMITTED (the fallback is an explicit
      // user choice and stays), but v2rayNG's parallel-query
      // count is primaries+domestic only: two, not above two.
      expect((dns['servers'] as List).length, 2);
      expect(dns.containsKey('enableParallelQuery'), isFalse);
    });
  });

  group('E1/E3 — the one-time defaults migration', () {
    test('a pre-2103 store moves both toggles OFF once', () {
      final s = XraySettings.fromJson({
        'ipv6Route': true,
        'sniffQuic': true,
      });
      expect(s.ipv6Route, isFalse);
      expect(s.sniffQuic, isFalse);
      expect(s.defaultsMigrated2103, isTrue);
    });

    test('a deliberate re-enable afterwards is kept', () {
      final s = XraySettings.fromJson({
        'ipv6Route': true,
        'sniffQuic': true,
        'defaultsMigrated2103': true,
      });
      expect(s.ipv6Route, isTrue);
      expect(s.sniffQuic, isTrue);
    });

    test('a fresh install starts already migrated (H1)', () {
      // No stored document exists, so nothing may migrate —
      // and the flag must START true, or the first session's
      // own saves would write false and make the store look
      // pre-2103 (verification iteration 1, H1).
      final fresh = XraySettings();
      expect(fresh.defaultsMigrated2103, isTrue);
      expect(fresh.defaultsJustMigrated2103, isFalse);
      // The H1 scenario end to end: the user turns IPv6
      // routing ON in the very first session; after a
      // restart the value is still theirs.
      fresh.ipv6Route = true;
      final restored = XraySettings.fromJson(fresh.toJson());
      expect(restored.ipv6Route, isTrue);
      expect(restored.defaultsMigrated2103, isTrue);
    });

    test('the migration flags itself for immediate persist (H1)', () {
      final migrated = XraySettings.fromJson({'ipv6Route': true});
      expect(migrated.defaultsJustMigrated2103, isTrue,
          reason: 'load() saves at once when this is set, '
              'like the fingerprint migration');
      final kept = XraySettings.fromJson({
        'ipv6Route': true,
        'defaultsMigrated2103': true,
      });
      expect(kept.defaultsJustMigrated2103, isFalse);
    });
  });

  group('journey 5 — a v6-only AWG profile keeps ::/0 (E1 decoupling)', () {
    // The owner's 2102 shape with a DUMMY key: v6 /128
    // address, ::/0-only AllowedIPs.
    const v6Conf = '''
[Interface]
Address = 2606:4700:110:8d17:9892:cb7f:7fca:4541/128
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
DNS = 2606:4700:4700::1111, 2606:4700:4700::1001
Jc = 6
Jmin = 10
Jmax = 50

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
Endpoint = [2606:4700:d0:0:92d9:27b5:d23d:b2f7]:2408
AllowedIPs = ::/0
PersistentKeepalive = 25
''';

    test('the profile-derived gate is true for the v6 shape', () {
      final r = parseWgConf(v6Conf, baseName: 'v6', idFor: () => 'id1');
      expect(r.ok, isTrue, reason: r.error);
      final p = r.profiles.single;
      expect(profileHasIpv6(p), isTrue,
          reason: 'the flag the controller now passes to '
              'setOnAwg — the service\'s (ipv6 && hasV6) '
              'gate then adds the ::/0 route even though '
              'the Settings toggle defaults OFF');
      expect(profileHasIpv4(p), isFalse);
    });

    test('a v4 profile\'s gate stays false, as in 2102', () {
      final p = Profile(
        id: 'v4',
        protocol: Protocol.wireguard,
        localAddress: '172.16.0.2/32',
        wgAllowedIPs: '0.0.0.0/0',
      );
      expect(profileHasIpv6(p), isFalse);
      expect(profileHasIpv4(p), isTrue);
    });

    test('a dual-stack profile\'s gate is true (L5)', () {
      final p = Profile(
        id: 'dual',
        protocol: Protocol.wireguard,
        localAddress: '172.16.0.2/32, 2606:4700:110::2/128',
        wgAllowedIPs: '0.0.0.0/0, ::/0',
      );
      expect(profileHasIpv6(p), isTrue);
      expect(profileHasIpv4(p), isTrue);
    });

    test('an AllowedIPs-only v6 footprint does not promise '
        'the route (L2)', () {
      final p = Profile(
        id: 'v4addr',
        protocol: Protocol.wireguard,
        localAddress: '172.16.0.2/32',
        wgAllowedIPs: '0.0.0.0/0, ::/0',
      );
      expect(profileHasIpv6(p), isFalse,
          reason: 'the flag gates only the AllowedIPs '
              'default — a v4-address profile has no v6 '
              'source address to send from, and the helper '
              'does not claim a v6 footprint for it (its '
              'explicit ::/0 AllowedIPs entry still routes '
              'via the backend builder, per its own list)');
    });

    test('the wiring: controller passes the profile gate; the '
        'engine gate consumes it', () {
      final controller = dartSrc('xray/xray_controller.dart');
      expect(controller, contains('ipv6: profileHasIpv6(p)'));
      // Build 2104: the service gate is deleted with the
      // service — the flag now gates the ::/0 half of the
      // AllowedIPs default in WgTunnelEngine's hand-off
      // (the route itself derives from the Config's
      // AllowedIPs in the backend's TUN builder).
      final awg = ktSrc('WgTunnelEngine.kt');
      expect(awg, contains('if (ipv6) "::/0" else null'));
    });
  });

  group('journey 2 — a panel JSON subscription lands its names (N1)', () {
    const panelBody = '''
[
  {
    "remarks": "Panel NL-1",
    "outbounds": [
      {
        "tag": "proxy",
        "protocol": "vless",
        "settings": {
          "vnext": [
            {
              "address": "nl.example.net",
              "port": 443,
              "users": [
                {
                  "id": "00000000-0000-4000-8000-000000000000",
                  "flow": "xtls-rprx-vision",
                  "encryption": "none"
                }
              ]
            }
          ]
        },
        "streamSettings": {
          "network": "tcp",
          "security": "reality",
          "realitySettings": {
            "serverName": "www.example.com",
            "fingerprint": "ios",
            "publicKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "shortId": "01ab"
          }
        }
      },
      {"tag": "direct", "protocol": "freedom"},
      {"tag": "block", "protocol": "blackhole"}
    ]
  }
]
''';

    test('remarks becomes the profile name', () {
      final profiles = parseSubscription(panelBody);
      expect(profiles.length, 1);
      expect(profiles.single.name, 'Panel NL-1',
          reason: 'the field panels actually carry the '
              'name in — never read before 2103');
      expect(profiles.single.address, 'nl.example.net');
    });

    test('without remarks, the outbound tag names it', () {
      // A distinctive tag (L5): "proxy" would also pass if
      // the capture were a hardcoded constant — "out-1"
      // only passes if the producing outbound's own tag
      // is really read.
      final body = panelBody
          .replaceAll('"remarks": "Panel NL-1",', '')
          .replaceAll('"tag": "proxy",', '"tag": "out-1",');
      final profiles = parseSubscription(body);
      expect(profiles.single.name, 'out-1',
          reason: 'the producing outbound\'s tag is the '
              'second resort, ahead of the positional form');
    });

    test('a control-only remarks still lands a name (L3)', () {
      final body = panelBody.replaceAll(
          '"remarks": "Panel NL-1"', '"remarks": "\\u200b\\u200b"');
      final profiles = parseSubscription(body);
      expect(profiles.single.name, 'VLESS 1',
          reason: 'the sanitizer strips the zero-width '
              'remarks to empty — the positional fallback, '
              'applied after sanitizing, still names the '
              'profile instead of birthing a blank title');
    });

    test('with neither, the positional name — never blank', () {
      final body = panelBody
          .replaceAll('"remarks": "Panel NL-1",', '')
          .replaceAll('"tag": "proxy",', '');
      final profiles = parseSubscription(body);
      expect(profiles.single.name, 'VLESS 1',
          reason: 'a JSON-route profile can no longer be '
              'born with an empty name');
    });

    test('journey 4 — a refresh re-parse keeps the healed name', () {
      final first = parseSubscription(panelBody).single;
      final refreshed = parseSubscription(panelBody).single;
      expect(refreshed.name, first.name);
      expect(refreshed.name, 'Panel NL-1',
          reason: 'the merge carries totals/star/localName '
              'only — the fresh parse\'s name is the name, '
              'so a healed name survives every refresh. '
              'The full controller-level refresh is pinned '
              'in the iteration-1 group below (L4)');
    });
  });

  group('journey 3 — remark-less links store no address (N2)', () {
    test('a link without a fragment takes the positional name', () {
      final profiles = parseLinks(
        'vless://00000000-0000-4000-8000-000000000000@203.0.113.10:443'
        '?encryption=none&security=none&type=tcp',
      );
      expect(profiles.length, 1);
      expect(profiles.single.name, 'VLESS 1');
      expect(profiles.single.name, isNot(profiles.single.address),
          reason: 'builds ≤2102 stored the address itself '
              'here — the value that then rode share links '
              'and re-derived on every refresh');
    });

    test('a link WITH a remark keeps it verbatim', () {
      final profiles = parseLinks(
        'vless://00000000-0000-4000-8000-000000000000@203.0.113.10:443'
        '?encryption=none&security=none&type=tcp#My%20Server',
      );
      expect(profiles.single.name, 'My Server');
    });

    test('a control-only remark still lands a name (L3)', () {
      final profiles = parseLinks(
        'vless://00000000-0000-4000-8000-000000000000@203.0.113.10:443'
        '?encryption=none&security=none&type=tcp#%E2%80%8B',
      );
      expect(profiles.single.name, 'VLESS 1',
          reason: 'the fragment decodes to a zero-width '
              'space, which the sanitizer strips to empty — '
              'the post-sanitize positional fallback names '
              'the profile instead of storing a blank');
    });
  });

  group('N2 — the stored-name heal', () {
    test('only the provably manufactured population is healed', () {
      final manufactured = Profile(
        id: 'a',
        protocol: Protocol.vless,
        name: '203.0.113.10',
        address: '203.0.113.10',
      );
      final renamed = Profile(
        id: 'b',
        protocol: Protocol.trojan,
        name: '203.0.113.11',
        address: '203.0.113.11',
        localName: 'Mine',
      );
      final providerNamed = Profile(
        id: 'c',
        protocol: Protocol.vmess,
        name: 'Real Name',
        address: '203.0.113.12',
      );
      final healed = healAddressDerivedNames(
        [manufactured, renamed, providerNamed],
      );
      expect(healed, 1);
      expect(manufactured.name, 'VLESS 1');
      expect(renamed.name, '203.0.113.11',
          reason: 'a user label (localName, the 2045 '
              'split) takes the profile out of the heal\'s '
              'population — a rename is never clobbered');
      expect(providerNamed.name, 'Real Name');
    });

    test('a nameless profile renders by address, stores none', () {
      final p = Profile(
        id: 'x',
        protocol: Protocol.vless,
        address: '203.0.113.20',
      );
      expect(p.name, '');
      expect(p.displayName, '203.0.113.20',
          reason: 'the address fallback is render-time '
              'only since 2103 — the stored field stays '
              'honest for share links and dedupe');
    });
  });

  group('iteration 1 — controller seams (L4 real refresh, '
      'M1 duplicate, H2/M1 seeds)', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    late Directory tempDir;
    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ember2103-');
      await Directory('${tempDir.path}/xray').create(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('app/android'),
        (call) async {
          if (call.method == 'dataDir') return '${tempDir.path}/core';
          return null;
        },
      );
    });
    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'), null);
      await tempDir.delete(recursive: true);
    });

    const refreshBody = '''
[
  {
    "remarks": "Panel NL-1",
    "outbounds": [
      {
        "tag": "proxy",
        "protocol": "vless",
        "settings": {
          "vnext": [
            {
              "address": "nl.example.net",
              "port": 443,
              "users": [
                {
                  "id": "00000000-0000-4000-8000-000000000000",
                  "flow": "xtls-rprx-vision",
                  "encryption": "none"
                }
              ]
            }
          ]
        },
        "streamSettings": {"network": "tcp", "security": "none"}
      },
      {"tag": "direct", "protocol": "freedom"}
    ]
  }
]
''';

    test('journey 4 (real) — a refresh through '
        'updateSubscription heals the name and keeps the '
        'label (L4)', () async {
      final c = XrayController();
      c.subscriptionFetcher = (
        url, {
        certPin = '',
        hwid = '',
        headers = const {},
        fallbackUrl = '',
        hosts = const {},
      }) async =>
          SubResult(profiles: parseSubscription(refreshBody));
      final sub = await c.addSubscription('https://panel.example/sub/abc');
      final stored =
          c.profiles.singleWhere((p) => p.subscriptionId == sub.id);
      expect(stored.name, 'Panel NL-1');
      // The pre-2103 stored state for this very profile —
      // address stored as the name — plus a user label.
      stored.name = stored.address;
      stored.localName = 'Mine';
      await c.updateSubscription(sub);
      final refreshed =
          c.profiles.singleWhere((p) => p.subscriptionId == sub.id);
      expect(refreshed.name, 'Panel NL-1',
          reason: 'the merge takes the fresh parse\'s name — '
              'a refresh heals an address-named profile');
      expect(refreshed.localName, 'Mine',
          reason: 'the user label carries over the refresh '
              '(the 2045 split, never clobbered)');
      expect(
        c.profiles.where((p) => p.subscriptionId == sub.id).length,
        1,
        reason: 'the refresh replaces, never duplicates',
      );
    });

    test('duplicating a nameless profile stores no '
        'manufactured name (M1)', () async {
      final c = XrayController();
      final p = Profile(
        id: 'n1',
        protocol: Protocol.vless,
        address: '203.0.113.30',
        port: 443,
      );
      c.profiles.add(p);
      await c.duplicateProfile(p);
      final copy = c.profiles.firstWhere((e) => e.id != 'n1');
      expect(copy.name, '',
          reason: 'before the fix the copy was born named '
              '"<address> (2)" from the render fallback');
      expect(copy.displayName, '203.0.113.30',
          reason: 'it still RENDERS by address');
    });

    test('duplicating a named profile keeps the 2045 '
        'suffix rule (M1)', () async {
      final c = XrayController();
      final p = Profile(
        id: 'n2',
        protocol: Protocol.vless,
        name: 'Real Name',
        address: '203.0.113.31',
        port: 443,
      );
      c.profiles.add(p);
      await c.duplicateProfile(p);
      final copy = c.profiles.firstWhere((e) => e.id != 'n2');
      expect(copy.name, 'Real Name (2)');
    });

    test('the editor and the rename dialog seed from the '
        'stored name, never displayName (H2/M1)', () {
      final editor = dartSrc('ui/ember/profile_editor.dart');
      expect(
        editor,
        contains("_field('name', "
            '_p.localName.isNotEmpty ? _p.localName : _p.name)'),
      );
      final servers = dartSrc('ui/ember/ember_servers.dart');
      expect(
        servers,
        contains('text: profile.localName.isNotEmpty'),
        reason: 'the positive pin (iteration 2): the dialog '
            'seeds from the stored editable name',
      );
      expect(
        servers,
        isNot(contains(
            'TextEditingController(text: profile.displayName)')),
        reason: 'an untouched rename of a nameless config '
            'would otherwise store its address as the label',
      );
    });
  });
}
