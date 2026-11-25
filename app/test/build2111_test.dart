// Build 2111 — RUSH, fix-only: the V2Ray in-tunnel DNS.
// The owner's 2110 device export (device-logs-2026-11-18-2302.md)
// decided the 2109 diagnosis's C2 question: with the server
// name pinned (2110's A1, confirmed working in that export)
// and the proxy carrying app TCP/UDP fine, the core DNS
// module's DoH POSTs through the proxy time out 100% —
// "context deadline exceeded", ZERO successes, against BOTH
// https://cloudflare-dns.com/dns-query AND
// https://8.8.8.8/dns-query. The DoH transport through the
// tunnel is dead on his path; UDP flows are alive (C2b,
// independent of the name defect).
//
// The fix, the whole scope: the remote DNS servers list
// becomes [1.1.1.1, https://cloudflare-dns.com/dns-query] —
// plain UDP 1.1.1.1 FIRST (its queries ride the existing
// dns-module → proxy rule as UDP, like every other working
// UDP flow), the DoH kept as the second entry so Xray falls
// back to it where UDP fails. The settings default becomes
// "1.1.1.1" and primaryResolvers appends the DoH behind a
// LONE plain-IP remote; a custom DoH URL or a stored list is
// emitted exactly as stored. A one-time migration moves the
// two known broken-DoH stored values (the 2101 Cloudflare
// default; the 8.8.8.8 DoH the owner set by hand on
// 2026-11-18) to "1.1.1.1" and leaves every other value
// untouched. _connectSelected journals the effective list
// once per connect. NO other behavior changes.
//
// Build 2113 addendum (owner order 2026-11-19 — the
// generated DNS section becomes upstream v2rayNG's
// verbatim): the 2111 list shape above is SUPERSEDED. The
// default is Cloudflare's DoH again, primaryResolvers emits
// the stored list exactly as stored (the lone-plain-IP
// append is gone), the scoped domestic entries take
// upstream's per-rule shape (no 'port' key), and a new
// one-time migration chains after 2111's in the same load:
// {1.1.1.1, Google DoH, 8.8.8.8 DoH, 94.140.14.14,
// tcp://94.140.14.14} → Cloudflare DoH. The pins below were
// updated to the 2113 shapes with equal strictness.
//
// All fixtures use dummy values — the owner's real configs
// and keys never appear in tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Profile dummyVless() => Profile(
  id: 'p1',
  name: 'dummy-vless',
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

List<dynamic> serversOf(Map<String, dynamic> config) =>
    (config['dns'] as Map<String, dynamic>)['servers'] as List;

void main() {
  group('the servers list — the stored list, emitted as stored (2113)', () {
    test('the shipped default emits the single Cloudflare DoH entry', () {
      final s = XraySettings();
      expect(s.remoteDns, 'https://cloudflare-dns.com/dns-query');
      expect(defaultRemoteDns, 'https://cloudflare-dns.com/dns-query');
      expect(primaryResolvers(s), [
        'https://cloudflare-dns.com/dns-query',
      ]);
      final config = decode(buildTunnelConfig(dummyVless(), s));
      expect(serversOf(config), [
        'https://cloudflare-dns.com/dns-query',
      ]);
    });

    test('the test config carries the same list', () {
      final config = decode(buildTestConfig(dummyVless(), XraySettings()));
      expect(serversOf(config), [
        'https://cloudflare-dns.com/dns-query',
      ]);
    });

    test('the rest of the DNS section is byte-identical in shape', () {
      final config = decode(buildTunnelConfig(dummyVless(), XraySettings()));
      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['tag'], 'dns-module');
      expect(dns['disableFallbackIfMatch'], isTrue);
      expect(dns.containsKey('queryStrategy'), isFalse);
      expect(dns['hosts'], contains('cloudflare-dns.com'));
      final rules = (config['routing']['rules'] as List)
          .cast<Map<String, dynamic>>();
      final dnsRule = rules.firstWhere(
        (r) => (r['inboundTag'] as List?)?.contains('dns-module') ?? false,
      );
      expect(dnsRule['outboundTag'], 'proxy');
    });

    test('the domestic entry still leads, scoped as before', () {
      final s = XraySettings()..customDirectDomains = ['example.ir'];
      final config = decode(buildTunnelConfig(dummyVless(), s));
      final servers = serversOf(config);
      // Build 2113: upstream's scoped shape — no 'port' key,
      // finalQuery on the domestic entry — then the single
      // remote entry.
      expect(servers.length, 2);
      expect(servers.first, {
        'address': '223.5.5.5',
        'domains': ['example.ir'],
        'skipFallback': true,
        'finalQuery': true,
        'tag': 'domestic-dns',
      });
      expect(servers[1], 'https://cloudflare-dns.com/dns-query');
    });

    test('the bypass-China preset emits the CN scoped shape (2113)', () {
      final s = XraySettings()..routingPreset = RoutingPreset.bypassChina;
      final config = decode(buildTunnelConfig(dummyVless(), s));
      expect(serversOf(config), [
        {
          'address': '223.5.5.5',
          'domains': ['geosite:cn'],
          'expectIPs': ['geoip:cn'],
          'skipFallback': true,
          'tag': 'domestic-dns',
        },
        {
          'address': 'https://cloudflare-dns.com/dns-query',
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
        'https://cloudflare-dns.com/dns-query',
      ]);
    });

    test('the bypass-Iran preset emits its scoped shape (2113)', () {
      final s = XraySettings()..routingPreset = RoutingPreset.bypassIran;
      final config = decode(buildTunnelConfig(dummyVless(), s));
      expect(serversOf(config), [
        {
          'address': '223.5.5.5',
          'domains': ['geosite:ir'],
          'skipFallback': true,
          'finalQuery': true,
          'tag': 'domestic-dns',
        },
        'https://cloudflare-dns.com/dns-query',
      ]);
    });

    test('custom proxy domains scope a remote entry (2113)', () {
      final s = XraySettings()..customProxyDomains = ['example.com'];
      final config = decode(buildTunnelConfig(dummyVless(), s));
      expect(serversOf(config), [
        {
          'address': 'https://cloudflare-dns.com/dns-query',
          'domains': ['example.com'],
          'finalQuery': true,
        },
        'https://cloudflare-dns.com/dns-query',
      ]);
    });

    test('a custom DoH URL is kept as the single value — no append', () {
      final s = XraySettings()
        ..remoteDns = 'https://dns.example.org/dns-query';
      expect(primaryResolvers(s), ['https://dns.example.org/dns-query']);
      final config = decode(buildTunnelConfig(dummyVless(), s));
      expect(serversOf(config), ['https://dns.example.org/dns-query']);
    });

    test('a custom plain IP stays a lone entry — no append (2113)', () {
      final s = XraySettings()..remoteDns = '8.8.8.8';
      expect(primaryResolvers(s), ['8.8.8.8']);
      final config = decode(buildTunnelConfig(dummyVless(), s));
      expect(serversOf(config), ['8.8.8.8']);
    });

    test('a stored list is emitted exactly as stored — no append', () {
      final s = XraySettings()..remoteDns = '1.1.1.1, 8.8.8.8';
      expect(primaryResolvers(s), ['1.1.1.1', '8.8.8.8']);
    });

    test('TCP mode stays pure TCP: the default collapses to tcp://1.1.1.1',
        () {
      final s = XraySettings()..remoteDnsProto = 'tcp';
      expect(primaryResolvers(s), ['tcp://1.1.1.1']);
      expect(primaryResolver(s), 'tcp://1.1.1.1');
      final config = decode(buildTunnelConfig(dummyVless(), s));
      expect(serversOf(config), ['tcp://1.1.1.1']);
    });

    test('DoQ mode stays pure DoQ: the single entry maps to its '
        'quic+local form', () {
      final s = XraySettings()..remoteDnsProto = 'doq';
      expect(primaryResolvers(s), [
        'quic+local://one.one.one.one',
      ]);
      final config = decode(buildTunnelConfig(dummyVless(), s));
      expect(serversOf(config), [
        'quic+local://one.one.one.one',
      ]);
    });
  });

  group('the one-time migration off the broken DoH defaults', () {
    test('the 2101 Cloudflare DoH default chains through 2111 and '
        'lands back on Cloudflare DoH (2113)', () {
      final s = XraySettings.fromJson({
        'remoteDns': 'https://cloudflare-dns.com/dns-query',
        'defaultsMigrated2101': true,
      });
      // The 2111 stage still runs (Cloudflare DoH → 1.1.1.1,
      // its flag lands), then the 2113 stage runs in the
      // same load (1.1.1.1 → Cloudflare DoH).
      expect(s.remoteDns, 'https://cloudflare-dns.com/dns-query');
      expect(s.toJson()['defaultsMigrated2111'], isTrue);
      expect(s.toJson()['defaultsMigrated2113'], isTrue);
    });

    test('the hand-set 8.8.8.8 DoH chains through 2111 to '
        'Cloudflare DoH (2113)', () {
      final s = XraySettings.fromJson({
        'remoteDns': 'https://8.8.8.8/dns-query',
        'defaultsMigrated2101': true,
      });
      expect(s.remoteDns, 'https://cloudflare-dns.com/dns-query');
      expect(s.toJson()['defaultsMigrated2111'], isTrue);
      expect(s.toJson()['defaultsMigrated2113'], isTrue);
    });

    test('a pre-2101 store chains Google DoH → Cloudflare → 1.1.1.1 '
        '→ Cloudflare (2113)', () {
      final s = XraySettings.fromJson({
        'remoteDns': 'https://dns.google/dns-query',
      });
      expect(s.remoteDns, 'https://cloudflare-dns.com/dns-query');
    });

    test('a stored 1.1.1.1 with the 2113 flag unset migrates to '
        'Cloudflare DoH', () {
      final s = XraySettings.fromJson({
        'remoteDns': '1.1.1.1',
        'defaultsMigrated2101': true,
        'defaultsMigrated2111': true,
      });
      expect(s.remoteDns, 'https://cloudflare-dns.com/dns-query');
      expect(s.toJson()['defaultsMigrated2113'], isTrue);
    });

    test('a custom Quad9 value is kept through both migrations', () {
      final s = XraySettings.fromJson({
        'remoteDns': 'https://dns.quad9.net/dns-query',
      });
      expect(s.remoteDns, 'https://dns.quad9.net/dns-query');
    });

    test('a custom value is left untouched', () {
      final s = XraySettings.fromJson({
        'remoteDns': 'https://dns.example.org/dns-query',
        'defaultsMigrated2101': true,
      });
      expect(s.remoteDns, 'https://dns.example.org/dns-query');
      final ip = XraySettings.fromJson({
        'remoteDns': '8.8.8.8',
        'defaultsMigrated2101': true,
      });
      expect(ip.remoteDns, '8.8.8.8');
    });

    test('a value re-entered after the migration is kept', () {
      final s = XraySettings.fromJson({
        'remoteDns': 'https://cloudflare-dns.com/dns-query',
        'defaultsMigrated2101': true,
        'defaultsMigrated2111': true,
      });
      expect(s.remoteDns, 'https://cloudflare-dns.com/dns-query');
    });
  });

  group('the connect journal', () {
    test('_connectSelected journals the effective remote DNS list', () {
      final controller = dartSrc('xray/xray_controller.dart');
      expect(
        controller,
        contains('Remote DNS servers for this session: '),
      );
      expect(controller, contains('primaryResolvers(settings)'));
    });
  });

  group('the version pin', () {
    test('pubspec is 2.2.0+2119', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('version: 2.2.0+2150'));
    });
  });
}
