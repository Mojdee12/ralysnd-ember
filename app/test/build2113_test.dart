// Build 2113 — FIX-ONLY: the V2Ray DNS carriage becomes
// upstream v2rayNG's own, verbatim (owner order 2026-11-19,
// «dns همون باشه»). The full generated-config diff against
// upstream 2dust/v2rayNG @ ef06bac lives in
// v2rayng-config-diff-2112.md; its verdict: Ember hijacked
// ALL app port-53 traffic into the core DNS module, whose
// dispatched upstreams are device-proven 100% dead on the
// owner's fugui server (2110 export) while raw flows through
// the same proxy live — and v2rayNG's default shape has no
// hijack at all, so app DNS rides the tunnel as ordinary
// traffic there and browsing never depends on the module's
// dispatch. Build 2111 changed only the module's upstream
// VALUES (the [1.1.1.1 UDP, DoH] hybrid); the verdict was
// unchanged. This build adopts the carriage:
//
// - the port-53 redirect and the dns-out outbound are
//   emitted ONLY when fakeDNS is on (the one Ember feature
//   whose answers exist only inside the module);
// - dns.servers is built by upstream's configureDns
//   algorithm: CN-mode scoped entries, per-rule scoped
//   entries (no 'port' field), the plain remote list last;
// - the 2111 hybrid is reverted — the settings default is
//   v2rayNG's Cloudflare DoH again, primaryResolvers emits
//   the stored list as-is, and a one-time migration moves
//   the 2111 default and the owner's fight-night resolver
//   values back to the DoH default;
// - dns.hosts is upstream's 15-entry table verbatim (the
//   googleapis.cn redirect as a string, AAAA values in),
//   block-list domains answer 127.0.0.1, a single-answer
//   pin is a plain string, user hosts are plain strings;
// - the dns-module → proxy rule moves to the END of the
//   rule list (upstream's position);
// - the freedom outbound carries upstream's sockopt
//   (UseIP + happyEyeballs), so direct domain dials resolve
//   through the module instead of the dead system resolver;
// - the server-name stamp's happyEyeballs is completed to
//   upstream's full shape.
//
// All fixtures use dummy values — the owner's real configs
// and keys never appear in tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

/// The fugui shape: VLESS + Reality, hostname server,
/// fingerprint ios, no flow.
Profile fuguiShape() => Profile(
  id: 'p1',
  name: 'dummy-fugui',
  protocol: Protocol.vless,
  address: 'free.example.net',
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  network: 'tcp',
  security: 'reality',
  sni: 'www.example.com',
  fingerprint: 'ios',
  publicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  shortId: '01ab',
);

Map<String, dynamic> dnsOf(Map<String, dynamic> config) =>
    config['dns'] as Map<String, dynamic>;

List<dynamic> serversOf(Map<String, dynamic> config) =>
    dnsOf(config)['servers'] as List;

Map<String, dynamic> hostsOf(Map<String, dynamic> config) =>
    dnsOf(config)['hosts'] as Map<String, dynamic>;

List<dynamic> rulesOf(Map<String, dynamic> config) =>
    (config['routing'] as Map<String, dynamic>)['rules'] as List;

Map<String, dynamic> outboundOf(
  Map<String, dynamic> config,
  String tag,
) => (config['outbounds'] as List)
    .cast<Map<String, dynamic>>()
    .firstWhere((o) => o['tag'] == tag);

const doh = 'https://cloudflare-dns.com/dns-query';

void main() {
  group('the default DNS section is v2rayNG’s own', () {
    test('the settings default and the resolver list', () {
      final s = XraySettings();
      expect(s.remoteDns, doh);
      expect(defaultRemoteDns, doh);
      expect(primaryResolvers(s), [doh]);
    });

    test('a lone plain-IP remote stays lone (the 2111 append is gone)', () {
      final s = XraySettings()..remoteDns = '9.9.9.9';
      expect(primaryResolvers(s), ['9.9.9.9']);
      final config = decode(buildTunnelConfig(fuguiShape(), s));
      expect(serversOf(config), ['9.9.9.9']);
    });

    test('the fugui shape under defaults: one DoH server, no hijack', () {
      final config = decode(buildTunnelConfig(fuguiShape(), XraySettings()));
      expect(serversOf(config), [doh]);
      expect(dnsOf(config)['tag'], 'dns-module');
      expect(dnsOf(config)['disableFallbackIfMatch'], isTrue);
      expect(dnsOf(config).containsKey('enableParallelQuery'), isFalse);
      // No dns-out outbound, and the routing rules are
      // exactly the api rule + the dns-module rule (last).
      expect(
        (config['outbounds'] as List).map((o) => o['tag']),
        ['proxy', 'direct', 'block'],
      );
      expect(rulesOf(config), [
        {
          'type': 'field',
          'inboundTag': ['api'],
          'outboundTag': 'api',
        },
        {
          'type': 'field',
          'inboundTag': ['dns-module'],
          'outboundTag': 'proxy',
        },
      ]);
    });

    test('the test config carries the same servers list', () {
      final config = decode(buildTestConfig(fuguiShape(), XraySettings()));
      expect(serversOf(config), [doh]);
    });

    test('the built-in hosts are upstream’s 15 entries, in order', () {
      final config = decode(buildTunnelConfig(fuguiShape(), XraySettings()));
      final hosts = hostsOf(config);
      expect(hosts.keys.toList(), [
        'domain:googleapis.cn',
        'dns.alidns.com',
        'dns.sse.cisco.com',
        'dns.umbrella.com',
        'one.one.one.one',
        '1dot1dot1dot1.cloudflare-dns.com',
        'dns.cloudflare.com',
        'cloudflare-dns.com',
        'engage.cloudflareclient.com',
        'doh.pub',
        'dot.pub',
        'dns.google',
        'dns.quad9.net',
        'dns.sb',
        'common.dot.dns.yandex.net',
      ]);
      expect(hosts['domain:googleapis.cn'], 'googleapis.com');
      expect(hosts['cloudflare-dns.com'], [
        '104.16.248.249',
        '104.16.249.249',
        '2606:4700::6810:f8f9',
        '2606:4700::6810:f9f9',
      ]);
      expect(hosts['dns.google'], [
        '8.8.8.8',
        '8.8.4.4',
        '2001:4860:4860::8888',
        '2001:4860:4860::8844',
      ]);
      expect(hosts.containsKey('doh.dns.sb'), isFalse);
      expect(hosts.containsKey('dns.adguard-dns.com'), isFalse);
    });
  });

  group('the server-name pin and stamp (upstream shapes)', () {
    test('a single answer pins as a string; the stamp is complete', () {
      final config = decode(
        buildTunnelConfig(
          fuguiShape(),
          XraySettings(),
          serverHostPins: {
            'free.example.net': ['203.0.113.7'],
          },
        ),
      );
      expect(hostsOf(config)['free.example.net'], '203.0.113.7');
      final proxy = outboundOf(config, 'proxy');
      final vnext =
          (proxy['settings'] as Map<String, dynamic>)['vnext'] as List;
      expect(vnext.single['address'], 'free.example.net');
      final sockopt =
          (proxy['streamSettings']
              as Map<String, dynamic>)['sockopt']
              as Map<String, dynamic>;
      expect(sockopt, {
        'domainStrategy': 'UseIP',
        'happyEyeballs': {
          'prioritizeIPv6': false,
          'maxConcurrentTry': 4,
          'tryDelayMs': 250,
          'interleave': 2,
        },
      });
    });

    test('several answers pin as a list', () {
      final config = decode(
        buildTunnelConfig(
          fuguiShape(),
          XraySettings(),
          serverHostPins: {
            'free.example.net': ['203.0.113.7', '203.0.113.8'],
          },
        ),
      );
      expect(hostsOf(config)['free.example.net'], [
        '203.0.113.7',
        '203.0.113.8',
      ]);
    });
  });

  group('the freedom outbound resolves like upstream’s', () {
    test('the direct outbound carries the template sockopt, no settings', () {
      final config = decode(buildTunnelConfig(fuguiShape(), XraySettings()));
      expect(outboundOf(config, 'direct'), {
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
    });
  });

  group('scoped entries — upstream configureDns projected from the rules', () {
    test('bypassChina: CN-mode pair, per-rule entry, plain remote last', () {
      final s = XraySettings()
        ..routingPreset = RoutingPreset.bypassChina;
      final config = decode(buildTunnelConfig(fuguiShape(), s));
      expect(serversOf(config), [
        {
          'address': '223.5.5.5',
          'domains': ['geosite:cn'],
          'expectIPs': ['geoip:cn'],
          'skipFallback': true,
          'tag': 'domestic-dns',
        },
        {
          'address': doh,
          'domains': ['geosite:cn'],
          'expectIPs': ['geoip:cn'],
          'skipFallback': true,
        },
        {
          'address': '223.5.5.5',
          'domains': ['geosite:cn'],
          'skipFallback': true,
          'finalQuery': true,
          'tag': 'domestic-dns',
        },
        doh,
      ]);
      // The domestic-dns rule leads the posture's rules and
      // the dns-module rule closes the list.
      final rules = rulesOf(config);
      expect(rules[1], {
        'type': 'field',
        'inboundTag': ['domestic-dns'],
        'outboundTag': 'direct',
      });
      expect(rules.last, {
        'type': 'field',
        'inboundTag': ['dns-module'],
        'outboundTag': 'proxy',
      });
    });

    test('bypassIran: one domestic entry scoped to geosite:ir', () {
      final s = XraySettings()
        ..routingPreset = RoutingPreset.bypassIran;
      final config = decode(buildTunnelConfig(fuguiShape(), s));
      expect(serversOf(config), [
        {
          'address': '223.5.5.5',
          'domains': ['geosite:ir'],
          'skipFallback': true,
          'finalQuery': true,
          'tag': 'domestic-dns',
        },
        doh,
      ]);
    });

    test('a custom direct domain scopes a domestic entry', () {
      final s = XraySettings()..customDirectDomains = ['example.com'];
      final config = decode(buildTunnelConfig(fuguiShape(), s));
      expect(serversOf(config), [
        {
          'address': '223.5.5.5',
          'domains': ['example.com'],
          'skipFallback': true,
          'finalQuery': true,
          'tag': 'domestic-dns',
        },
        doh,
      ]);
    });

    test('a custom proxy domain scopes a remote entry with finalQuery', () {
      final s = XraySettings()..customProxyDomains = ['example.com'];
      final config = decode(buildTunnelConfig(fuguiShape(), s));
      expect(serversOf(config), [
        {
          'address': doh,
          'domains': ['example.com'],
          'finalQuery': true,
        },
        doh,
      ]);
    });

    test('no scoped entry carries a port (upstream never sets one)', () {
      final s = XraySettings()
        ..routingPreset = RoutingPreset.bypassChina;
      final config = decode(buildTunnelConfig(fuguiShape(), s));
      for (final entry in serversOf(config)) {
        if (entry is Map) expect(entry.containsKey('port'), isFalse);
      }
    });

    test('block-list domains answer 127.0.0.1 from hosts, no server entry', () {
      final s = XraySettings()..customBlockDomains = ['bad.example'];
      final config = decode(buildTunnelConfig(fuguiShape(), s));
      expect(hostsOf(config)['bad.example'], '127.0.0.1');
      expect(serversOf(config), [doh]);
    });

    test('two stored remotes switch parallel query on; the fallback does not', () {
      final two = XraySettings()
        ..remoteDns = 'https://dns.google/dns-query, $doh';
      final configTwo = decode(buildTunnelConfig(fuguiShape(), two));
      expect(dnsOf(configTwo)['enableParallelQuery'], isTrue);
      expect(serversOf(configTwo), [
        'https://dns.google/dns-query',
        doh,
      ]);

      final withFallback = XraySettings()..dnsFallback = true;
      final configFb = decode(buildTunnelConfig(fuguiShape(), withFallback));
      expect(dnsOf(configFb).containsKey('enableParallelQuery'), isFalse);
    });
  });

  group('fakeDNS keeps its interception (the gate)', () {
    test('fakeDns on: dns-out and the port-53 rule return', () {
      final s = XraySettings()..fakeDns = true;
      final config = decode(buildTunnelConfig(fuguiShape(), s));
      expect(serversOf(config).first, 'fakedns');
      expect(outboundOf(config, 'dns-out'), {
        'tag': 'dns-out',
        'protocol': 'dns',
        'settings': {'nonIPQuery': 'skip'},
      });
      final redirect = rulesOf(config)
          .cast<Map<String, dynamic>>()
          .where((r) => r['outboundTag'] == 'dns-out')
          .toList();
      expect(redirect, hasLength(1));
      expect(redirect.single['port'], '53');
      expect(redirect.single['network'], 'udp');
    });
  });

  group('user hosts ride as plain strings', () {
    test('a custom host emits as a string and wins over the table', () {
      final s = XraySettings()
        ..customDnsHosts = {'my.example': '10.0.0.1'};
      final config = decode(buildTunnelConfig(fuguiShape(), s));
      expect(hostsOf(config)['my.example'], '10.0.0.1');
    });
  });

  group('the one-time 2113 migration', () {
    test('the 2111 default moves back to v2rayNG’s DoH', () {
      final s = XraySettings.fromJson({'remoteDns': '1.1.1.1'});
      expect(s.remoteDns, doh);
      expect(s.defaultsMigrated2113, isTrue);
      expect(s.toJson()['defaultsMigrated2113'], isTrue);
    });

    test('the fight-night values move too', () {
      for (final value in [
        'https://dns.google/dns-query',
        'https://8.8.8.8/dns-query',
        '94.140.14.14',
        'tcp://94.140.14.14',
      ]) {
        final s = XraySettings.fromJson({'remoteDns': value});
        expect(s.remoteDns, doh, reason: value);
      }
    });

    test('a custom resolver is kept', () {
      final s = XraySettings.fromJson({
        'remoteDns': 'https://dns.quad9.net/dns-query',
      });
      expect(s.remoteDns, 'https://dns.quad9.net/dns-query');
    });

    test('a value re-entered after the migration is kept', () {
      final s = XraySettings.fromJson({
        'remoteDns': '1.1.1.1',
        'defaultsMigrated2113': true,
      });
      expect(s.remoteDns, '1.1.1.1');
    });
  });

  group('version', () {
    test('pubspec is 2.2.0+2119', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.2.0+2147'),
      );
    });
  });
}
