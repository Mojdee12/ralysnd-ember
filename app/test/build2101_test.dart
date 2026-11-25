// Build 2101 — the V2Ray-section fix build (owner reports
// 2026-11-18 01:38–02:00, diagnosis
// settings-dns-2099-diagnosis.md): (1) the settings section's
// save+notify, (2) DNS defaults become v2rayNG's own — FULL
// adoption by the owner's explicit order («حفاظت ول کن»),
// knowingly removing the build-2049 protections (each removal
// is named in BUILD-LOG-2.md), (3) the hostname-resolution
// journey pin (the fugui acceptance shape), (4) delay-test
// demotion + the distinct sidecar-busy outcome, (5) Test All
// clear-first + the bulk budget shape, (6) import variant
// dedupe + per-line fault isolation + the guarded sheet await.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
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

/// The owner's acceptance shape (2026-11-18): a VLESS+REALITY
/// profile addressed by HOSTNAME — the form that could not
/// resolve through the 2049-shaped DNS chain on his network
/// while the raw-IP form connected at once. Dummy values.
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
  group('item 3 — the hostname journey pin (fugui shape)', () {
    test('the generated config carries no UseIPv4 anywhere', () {
      final config = buildTunnelConfig(hostnameVless(), XraySettings());
      expect(
        config.contains('UseIPv4'),
        isFalse,
        reason:
            'owner order 2026-11-18: the whole pin family is '
            'removed — a hostname-addressed server must resolve '
            'through the v2rayNG-shaped chain, both families',
      );
    });

    test('the DNS section is the v2rayNG-parity shape', () {
      final config = decode(buildTunnelConfig(hostnameVless(), XraySettings()));
      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns.containsKey('queryStrategy'), isFalse);
      expect(dns['disableFallbackIfMatch'], isTrue);
      // Default settings: no direct-routed domains. Build
      // 2113: the remote default is v2rayNG's Cloudflare DoH,
      // emitted as the single stored entry (the 2111 plain-IP
      // default and its appended pair are gone); no other
      // fallback rides.
      expect(dns['servers'], [
        'https://cloudflare-dns.com/dns-query',
      ]);
    });

    test('the proxy outbound carries no sockopt domainStrategy', () {
      final config = decode(buildTunnelConfig(hostnameVless(), XraySettings()));
      final proxy = outboundByTag(config, 'proxy');
      final sockopt =
          (proxy['streamSettings'] as Map?)?['sockopt'] as Map?;
      expect(sockopt?['domainStrategy'], isNull);
    });
  });

  group('item 2 — the domestic/direct resolver (v2rayNG parity)', () {
    test('direct domains scope a domestic entry + routing rule', () {
      final s = XraySettings()..customDirectDomains = ['example.ir'];
      final config = decode(buildTunnelConfig(hostnameVless(), s));
      final dns = config['dns'] as Map<String, dynamic>;
      final servers = dns['servers'] as List;
      // Build 2113: the scoped domestic entry is upstream's
      // exact shape — no 'port' key anywhere — and the single
      // remote entry rides behind it.
      expect(servers.length, 2);
      final domestic = servers.first as Map<String, dynamic>;
      expect(domestic, {
        'address': '223.5.5.5',
        'domains': ['example.ir'],
        'skipFallback': true,
        'finalQuery': true,
        'tag': 'domestic-dns',
      });
      expect(servers[1], 'https://cloudflare-dns.com/dns-query');
      final rules = (config['routing']['rules'] as List)
          .cast<Map<String, dynamic>>();
      // The built config prepends its platform rules (the api
      // stats rule) ahead of _routingRules' own array; within
      // that array the domestic rule leads, as in v2rayNG's
      // generated order. Build 2113: there is NO port-53 DNS
      // redirect under default settings (it exists only with
      // fakeDNS on), and the dns-module rule is LAST.
      final domesticAt = rules.indexWhere(
        (r) => (r['inboundTag'] as List?)?.contains('domestic-dns') ?? false,
      );
      final dnsRedirectAt = rules.indexWhere((r) => r['port'] == '53');
      expect(domesticAt, 1);
      expect(rules[domesticAt]['outboundTag'], 'direct');
      expect(dnsRedirectAt, -1);
      expect(
        (rules.last['inboundTag'] as List?)?.contains('dns-module') ?? false,
        isTrue,
      );
    });

    test('the bypass-Iran preset scopes geosite:ir', () {
      final s = XraySettings()..routingPreset = RoutingPreset.bypassIran;
      expect(directRoutedDomains(s), contains('geosite:ir'));
      final config = decode(buildTunnelConfig(hostnameVless(), s));
      final dns = config['dns'] as Map<String, dynamic>;
      final domestic = (dns['servers'] as List).first as Map<String, dynamic>;
      expect(domestic['domains'], contains('geosite:ir'));
    });

    test('no direct domains: no domestic entry, no rule', () {
      final config = decode(buildTunnelConfig(hostnameVless(), XraySettings()));
      final dns = config['dns'] as Map<String, dynamic>;
      // Build 2113: the single remote entry, no domestic entry.
      expect(dns['servers'], hasLength(1));
      final rules = (config['routing']['rules'] as List)
          .cast<Map<String, dynamic>>();
      expect(
        rules.any((r) => (r['inboundTag'] as List?)?.contains('domestic-dns') ?? false),
        isFalse,
      );
    });
  });

  group('item 2 — defaults and the one-time migration', () {
    test('the shipped defaults are v2rayNG\u2019s', () {
      final s = XraySettings();
      // Build 2113: the shipped remote default is v2rayNG's
      // Cloudflare DoH again (the 2111 plain-IP default is
      // reverted — see build2111_test.dart).
      expect(s.remoteDns, 'https://cloudflare-dns.com/dns-query');
      expect(s.localDns, '1.1.1.1');
      expect(s.fakeDns, isFalse);
      expect(s.testAllConcurrency, 8);
      expect(defaultRemoteDns, 'https://cloudflare-dns.com/dns-query');
      expect(defaultDirectDns, '223.5.5.5');
    });

    test('a stored old default migrates; a custom remote is kept', () {
      final migrated = XraySettings.fromJson({
        'remoteDns': 'https://dns.google/dns-query',
      });
      // Build 2113: the chain runs two steps further in the
      // same load — Google DoH → (2101) Cloudflare DoH →
      // (2111) 1.1.1.1 → (2113) Cloudflare DoH. The earlier
      // stages themselves are unchanged.
      expect(migrated.remoteDns, 'https://cloudflare-dns.com/dns-query');
      expect(migrated.toJson()['defaultsMigrated2101'], isTrue);
      expect(migrated.toJson()['defaultsMigrated2111'], isTrue);
      expect(migrated.toJson()['defaultsMigrated2113'], isTrue);

      final custom = XraySettings.fromJson({
        'remoteDns': 'https://dns.example.org/dns-query',
      });
      expect(custom.remoteDns, 'https://dns.example.org/dns-query');
    });

    test('a pre-2005 store chains through both migrations', () {
      final s = XraySettings.fromJson({
        'remoteDns': 'https://1.1.1.1/dns-query',
      });
      // Build 2113: the chain's end is v2rayNG's Cloudflare
      // DoH (2005 → Google → 2101 Cloudflare → 2111 1.1.1.1
      // → 2113 Cloudflare, all in one load).
      expect(s.remoteDns, 'https://cloudflare-dns.com/dns-query');
    });

    test('a Google value re-entered after the migration is kept', () {
      // Build 2113: "after the migration" now means after
      // EVERY migration in the chain has run — the Google
      // value is in the 2113 migration's own set, so the
      // store must carry all three flags for the re-entered
      // value to be kept.
      final s = XraySettings.fromJson({
        'remoteDns': 'https://dns.google/dns-query',
        'defaultsMigrated2101': true,
        'defaultsMigrated2111': true,
        'defaultsMigrated2113': true,
      });
      expect(s.remoteDns, 'https://dns.google/dns-query');
    });

    test('the stored old concurrency default migrates, others keep', () {
      expect(XraySettings.fromJson({'testAllConcurrency': 4}).testAllConcurrency, 8);
      expect(XraySettings.fromJson({'testAllConcurrency': 3}).testAllConcurrency, 3);
      expect(XraySettings.fromJson({'testAllConcurrency': 6}).testAllConcurrency, 6);
    });
  });

  group('items 4/5 — delay stages', () {
    test('delayStage round-trips through the store', () {
      final p = hostnameVless()..delayStage = 'sidecar-busy';
      expect(Profile.fromJson(p.toJson()).delayStage, 'sidecar-busy');
      expect(hostnameVless().delayStage, '');
      final j = hostnameVless().toJson()..remove('delayStage');
      expect(Profile.fromJson(j).delayStage, '');
    });

    test('the funnel demotes; nothing marks scan-failed anymore', () {
      final c = dartSrc('xray/xray_controller.dart');
      expect(c.contains('_markScanFailed'), isFalse);
      expect(c.contains('testDelay(p, bulk: true)'), isTrue);
      expect(c.contains("p.delayStage = 'sidecar-busy'"), isTrue);
      expect(c.contains("p.delayStage = 'core'"), isTrue);
    });

    test('the bulk tester shape is wired end to end', () {
      final tester = ktSrc('XrayTester.kt');
      expect(tester, contains('rounds: Int = 2'));
      expect(tester, contains('budgetMs: Long = 0'));
      final main = ktSrc('MainActivity.kt');
      expect(main, contains('call.argument<Int>("rounds")'));
      expect(main, contains('call.argument<Int>("budgetMs")'));
      final platform = dartSrc('xray/xray_platform.dart');
      // Build 2109: the channel map carries the delay-test
      // timeout too (the map is now multi-line, so the entries
      // are pinned one by one).
      expect(platform, contains("'rounds': rounds,"));
      expect(platform, contains("'budgetMs': budgetMs,"));
      expect(platform, contains("'timeoutMs': timeoutMs,"));
    });

    test('the servers UI has the distinct sidecar-busy state', () {
      final ui = dartSrc('ui/ember/ember_servers.dart');
      expect(ui, contains("text: 'Sidecar busy'"));
      expect(ui, contains("? 'Sidecar busy'"));
    });
  });

  group('item 6 — import variants and batch isolation', () {
    Profile variant({String sni = '', String network = 'tcp'}) => Profile(
      id: 'x',
      name: 'v',
      protocol: Protocol.vless,
      address: 'srv.example.net',
      port: 443,
      uuidOrPassword: '00000000-0000-4000-8000-000000000000',
      network: network,
      security: 'tls',
      sni: sni,
    );

    test('the import key separates variants the identity key merges', () {
      final a = variant(sni: 'a.example.com');
      final b = variant(sni: 'b.example.com');
      final c = variant(network: 'ws');
      expect(profileIdentityKey(a), profileIdentityKey(b));
      expect(profileImportKey(a), isNot(profileImportKey(b)));
      expect(profileImportKey(a), isNot(profileImportKey(c)));
      expect(profileImportKey(a), profileImportKey(variant(sni: 'a.example.com')));
    });

    test('a batch with a dead line still yields the good profiles', () {
      const uuid = '00000000-0000-4000-8000-000000000000';
      final text = [
        'vless://$uuid@one.example.net:443?security=tls#one',
        'this is not a link at all',
        'vless://$uuid@two.example.net:443?security=tls#two',
      ].join('\n');
      final r = parseLinksDetailed(text);
      expect(r.profiles, hasLength(2));
      expect(r.skipped, hasLength(1));
    });

    test('the parser isolates per line and the sheet await is guarded', () {
      final parser = dartSrc('xray/link_parser.dart');
      expect(parser, contains('profile = parseLink(part);'));
      expect(parser, contains('S4/I2'));
      final qr = dartSrc('ui/ember/qr_pages.dart');
      expect(qr, contains('_runGuardedImport'));
      expect(qr, contains('Could not import that text.'));
    });

    test('manual import dedupes on the import key in every branch', () {
      final c = dartSrc('xray/xray_controller.dart');
      // The subscription-merge path keeps the coarse key by
      // design; the four manual-import sites use the widened
      // one (Clash branch, links branch, both body branches).
      expect('profileImportKey(p)'.allMatches(c).length, greaterThanOrEqualTo(4));
      expect(c, contains('profiles.map(profileImportKey).toSet()'));
    });
  });

  group('item 1 — the settings section saves AND notifies', () {
    test('no bare save remains inside _XraySection; the helper notifies', () {
      final src = dartSrc('ui/ember/ember_settings.dart');
      final start = src.indexOf('class _XraySection');
      final end = src.indexOf('class _LanShareAddresses');
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final section = src.substring(start, end);
      // The helper's own body is the one legitimate bare save.
      final bare = 'await xray.save();'.allMatches(section).length;
      expect(bare, 1, reason: 'only _saveSection itself may call save() bare');
      expect(section, contains('Future<void> _saveSection()'));
      expect(section, contains('xray.notifySettingsChanged();'));
      expect(section, contains('Applies at next connect.'));
    });
  });

  group('item 2 — removal source pins', () {
    test('no UseIPv4 is EMITTED anywhere in the builder', () {
      final b = dartSrc('xray/config_builder.dart');
      expect(b, isNot(contains("'queryStrategy': 'UseIPv4'")));
      expect(b, isNot(contains("'domainStrategy': 'UseIPv4'")));
      expect(b, isNot(contains("sock['domainStrategy'] = 'UseIPv4'")));
      // The built-in fallback's own expression is gone (the
      // Quad9 provider itself stays in the user-choice tables
      // — a user may still pick it as their resolver).
      expect(
        b,
        isNot(contains("tcpFormOf('https://dns.quad9.net/dns-query')")),
      );
      expect(b, contains("'disableFallbackIfMatch': true"));
      expect(b, contains("'skipFallback': true"));
    });

    test('the pubspec carries this build', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      // Updated by build 2110 (the standing per-build pin:
      // it names the build the tree currently ships as).
      expect(pubspec, contains('version: 2.2.0+2150'));
    });
  });
}
