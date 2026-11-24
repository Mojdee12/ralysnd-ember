/// Build 2029A: cipherSuites + unsafe surfacing, ECH via a
/// dedicated outbound, the chain config shape, the watchdog
/// shapes, the winning-shape cache, and the guided
/// diagnostics staging — plus the device-state matrix for the
/// new state surfaces (carried-over, corrupt and empty state
/// must degrade, never crash).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/xray/anti_filter.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/diagnostics.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/shape_cache.dart';
import 'package:firefox_vpn/xray/shapes.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Profile tlsProfile({
  String security = 'tls',
  String network = 'ws',
  String fingerprint = 'chrome',
  String cipherSuites = '',
  String alpn = '',
  bool afEch = false,
}) {
  return Profile(
    id: 'p1',
    name: 'test',
    protocol: Protocol.vless,
    address: 'cdn.example.com',
    port: 443,
    uuidOrPassword: '00000000-0000-4000-8000-000000000000',
    network: network,
    host: 'cdn.example.com',
    security: security,
    sni: 'cdn.example.com',
    fingerprint: fingerprint,
    cipherSuites: cipherSuites,
    alpn: alpn,
    afEch: afEch,
  );
}

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Map<String, dynamic> outboundByTag(Map<String, dynamic> config, String tag) =>
    (config['outbounds'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((o) => o['tag'] == tag);

void main() {
  group('cipherSuites (stock core surfacing)', () {
    test('the config carries the suites on the TLS settings', () {
      final p = tlsProfile(
        fingerprint: 'unsafe',
        cipherSuites: 'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256',
      );
      final config = decode(buildTestConfig(p, XraySettings()));
      final tls = outboundByTag(config, 'proxy')['streamSettings']
          ['tlsSettings'];
      expect(tls['cipherSuites'], 'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256');
      expect(tls['fingerprint'], 'unsafe');
    });

    test('no suites, no key', () {
      final config = decode(buildTestConfig(tlsProfile(), XraySettings()));
      final tls = outboundByTag(config, 'proxy')['streamSettings']
          ['tlsSettings'];
      expect(tls.containsKey('cipherSuites'), isFalse);
    });

    test('the share link round-trips cs', () {
      final p = tlsProfile(
        fingerprint: 'unsafe',
        cipherSuites: 'TLS_A:TLS_B',
      );
      final link = profileToLink(p);
      expect(link, contains('cs=TLS_A%3ATLS_B'));
      final back = parseLinks(link).single;
      expect(back.cipherSuites, 'TLS_A:TLS_B');
      expect(back.fingerprint, 'unsafe');
    });

    test('the store round-trips cs', () {
      final p = tlsProfile(cipherSuites: 'TLS_A');
      final back = Profile.fromJson(p.toJson());
      expect(back.cipherSuites, 'TLS_A');
    });
  });

  group('TlsSettingsCheck', () {
    test('cs without unsafe is a finding', () {
      final findings = tlsSettingsCheck(tlsProfile(cipherSuites: 'TLS_A'));
      expect(findings, hasLength(1));
      expect(findings.single, contains('unsafe'));
    });

    test('cs with unsafe is clean', () {
      final findings = tlsSettingsCheck(
        tlsProfile(fingerprint: 'unsafe', cipherSuites: 'TLS_A'),
      );
      expect(findings, isEmpty);
    });

    test('ws with a non-http/1.1 ALPN is a finding', () {
      final findings = tlsSettingsCheck(tlsProfile(alpn: 'h2'));
      expect(findings.single, contains('http/1.1'));
    });

    test('ws with http/1.1 offered is clean', () {
      expect(tlsSettingsCheck(tlsProfile(alpn: 'h2,http/1.1')), isEmpty);
      expect(tlsSettingsCheck(tlsProfile(alpn: '')), isEmpty);
    });

    test('non-TLS profiles are never checked', () {
      expect(
        tlsSettingsCheck(tlsProfile(security: 'reality', cipherSuites: 'X')),
        isEmpty,
      );
    });
  });

  group('ECH via a dedicated outbound', () {
    test('the test config routes the lookup through ech-out', () {
      final p = tlsProfile(afEch: true);
      final config = decode(buildTestConfig(p, XraySettings()));
      final tls = outboundByTag(config, 'proxy')['streamSettings']
          ['tlsSettings'];
      expect(tls['echConfigList'], afEchConfigList);
      expect(tls['echSockopt'], {'dialerProxy': 'ech-out'});
      expect(outboundByTag(config, 'ech-out')['protocol'], 'freedom');
    });

    test('chained, the lookup rides the underlay instead', () {
      final p = tlsProfile(afEch: true);
      final config = decode(
        buildTunnelConfig(p, XraySettings(), psiphonUnderlay: true),
      );
      final tls = outboundByTag(config, 'proxy')['streamSettings']
          ['tlsSettings'];
      expect(tls['echSockopt'], {'dialerProxy': 'psiphon-underlay'});
      final tags = (config['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .map((o) => o['tag'])
          .toList();
      expect(tags, isNot(contains('ech-out')));
      expect(tags, contains('psiphon-underlay'));
    });

    test('no ECH shape, no echSockopt and no ech-out', () {
      final config = decode(buildTestConfig(tlsProfile(), XraySettings()));
      final tags = (config['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .map((o) => o['tag'])
          .toList();
      expect(tags, isNot(contains('ech-out')));
    });
  });

  group('chain config shape', () {
    test('the proxy dials through the underlay outbound', () {
      final config = decode(
        buildTunnelConfig(tlsProfile(), XraySettings(), psiphonUnderlay: true),
      );
      final proxy = outboundByTag(config, 'proxy');
      expect(
        proxy['streamSettings']['sockopt']['dialerProxy'],
        'psiphon-underlay',
      );
      final underlay = outboundByTag(config, 'psiphon-underlay');
      expect(underlay['protocol'], 'socks');
      expect(
        underlay['settings']['servers'][0],
        {'address': '127.0.0.1', 'port': 11808},
      );
    });

    test('unchained configs have no underlay anywhere', () {
      final config = decode(buildTunnelConfig(tlsProfile(), XraySettings()));
      final tags = (config['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .map((o) => o['tag'])
          .toList();
      expect(tags, isNot(contains('psiphon-underlay')));
      final proxy = outboundByTag(config, 'proxy');
      // Build 2049: the proxy sockopt carried the IPv4-only
      // server-dial strategy — REMOVED in build 2101 by the
      // owner's order (full v2rayNG adoption; see
      // build2101_test.dart). An unchained config has neither
      // a dialerProxy nor a domainStrategy in it now.
      final sockopt = proxy['streamSettings']['sockopt'] as Map;
      expect(sockopt['dialerProxy'], isNull);
      expect(sockopt['domainStrategy'], isNull);
    });

    test('with the fragment chain, the fragment outbound is chained', () {
      final s = XraySettings()..fragmentEnabled = true;
      final config = decode(
        buildTunnelConfig(tlsProfile(), s, psiphonUnderlay: true),
      );
      final proxy = outboundByTag(config, 'proxy');
      expect(proxy['streamSettings']['sockopt']['dialerProxy'], 'frag');
      final frag = outboundByTag(config, 'frag');
      expect(
        frag['streamSettings']['sockopt']['dialerProxy'],
        'psiphon-underlay',
      );
    });
  });

  group('watchdog shapes', () {
    test('TLS profiles have three shapes, others only stock', () {
      // Superseded by build 2030: the dialMode shape (s3)
      // joined the ladder with the patched core — see
      // build2030_test.dart ('watchdog Shape #4').
      expect(shapesFor(tlsProfile()), ['s0', 's1', 's2', 's3']);
      expect(shapesFor(tlsProfile(security: 'reality')), ['s0']);
      expect(shapesFor(tlsProfile(security: '')), ['s0']);
    });

    test('s1 forces the F12 fragment on a copy', () {
      final p = tlsProfile();
      final shaped = profileWithShape(p, 's1');
      expect(shaped.afFragment, 'f12');
      expect(shaped.id, p.id);
      expect(p.afFragment, ''); // The original is untouched.
    });

    test('s2 forces unsafe + the unfilter cipher order', () {
      final shaped = profileWithShape(tlsProfile(), 's2');
      expect(shaped.fingerprint, 'unsafe');
      expect(shaped.cipherSuites, afUnfilterCipherSuites);
    });

    test('s0 is the profile itself', () {
      final p = tlsProfile();
      expect(identical(profileWithShape(p, 's0'), p), isTrue);
    });
  });

  group('WinningShapeCache', () {
    test('record then lookup on the same network', () {
      final cache = WinningShapeCache();
      cache.record('p1', 'wifi:abcd', 's1', 120, nowMs: 1000);
      final win = cache.lookup('p1', 'wifi:abcd', nowMs: 2000);
      expect(win?.shapeId, 's1');
      expect(win?.rttMs, 120);
    });

    test('a win does not cross networks', () {
      final cache = WinningShapeCache();
      cache.record('p1', 'wifi:abcd', 's1', 120, nowMs: 1000);
      expect(cache.lookup('p1', 'cellular:ef01', nowMs: 2000), isNull);
    });

    test('a stale win is ignored', () {
      final cache = WinningShapeCache();
      cache.record('p1', 'wifi:abcd', 's1', 120, nowMs: 1000);
      expect(
        cache.lookup(
          'p1',
          'wifi:abcd',
          nowMs: 1000 + WinningShapeCache.maxAgeMs + 1,
        ),
        isNull,
      );
    });

    test('an unknown network never engages the cache', () {
      final cache = WinningShapeCache();
      cache.record('p1', '', 's1', 120, nowMs: 1000);
      expect(cache.length, 0);
      expect(cache.lookup('p1', '', nowMs: 2000), isNull);
    });

    test('the fingerprint helper hashes the operator', () {
      expect(
        networkFingerprintOf({'type': 'wifi', 'operator': 'HomeNet'}),
        startsWith('wifi:'),
      );
      expect(networkFingerprintOf({'type': 'none', 'operator': 'x'}), '');
      expect(networkFingerprintOf(null), '');
      expect(networkFingerprintOf({'type': 'cellular', 'operator': ''}),
          'cellular');
    });
  });

  group('device-state matrix: corrupt and carried-over state', () {
    test('a corrupt shape-cache document reads as empty', () {
      for (final raw in [null, 'junk', 42, ['x'], {'a': 'b'}]) {
        expect(WinningShapeCache.fromJson(raw).length, 0);
      }
    });

    test('corrupt entries are dropped, good ones kept', () {
      final cache = WinningShapeCache.fromJson({
        'p1|wifi:x': {'shape': 's1', 'at': 5, 'rtt': 90},
        'p2|wifi:x': {'shape': 7, 'at': 5, 'rtt': 90},
        'p3|wifi:x': {'shape': 's2', 'at': 'soon', 'rtt': 90},
        'p4|wifi:x': 'garbage',
        'p5|wifi:x': {'at': 5, 'rtt': 90},
      });
      expect(cache.length, 1);
      expect(cache.lookup('p1', 'wifi:x', nowMs: 10)?.shapeId, 's1');
    });

    test('an unknown underlay value in settings reads as none', () {
      // The chain toggled by a store the build does not know:
      // no phantom underlay may engage. (In 2029A 'warp' was
      // such an unknown value; build 2030 made it a real
      // underlay, so the unknown probe uses another string —
      // the corrupt-value coverage lives in build2030_test.)
      expect(XraySettings.fromJson({'underlay': 'warp'}).underlay, 'warp');
      expect(
        XraySettings.fromJson({'underlay': 'warp-plus'}).underlay,
        'none',
      );
      expect(XraySettings.fromJson({'underlay': 'psiphon'}).underlay,
          'psiphon');
      expect(XraySettings.fromJson({}).underlay, 'none');
      expect(XraySettings.fromJson({'underlay': 42}).underlay, 'none');
    });

    test('a 2028-era profile store reads with defaults', () {
      // No cipherSuites key (pre-2029 store): the field
      // defaults empty instead of failing the whole load.
      final j = tlsProfile().toJson()..remove('cipherSuites');
      expect(Profile.fromJson(j).cipherSuites, '');
    });

    test('diagnostics against a broken profile: every stage says so', () async {
      final checker = ConnectionChecker(
        tcp: (_, _) async => -1,
        tls: (_, _, _) async => false,
        delay: (_) async => -1,
      );
      final stages = await checker.checkProfile(tlsProfile());
      expect(stages, hasLength(3));
      expect(stages.every((s) => !s.ok), isTrue);
      expect(stages[0].detail, contains('blocked'));
      expect(stages[1].detail, contains('reset'));
      expect(stages[2].detail, contains('no real request'));
    });

    test('diagnostics on a dead tunnel stops at the port stage', () async {
      final checker = ConnectionChecker(
        socksOpen: (_) async => false,
        socksDomain: (_) async => 42,
      );
      final stages = await checker.checkLive(socksPort: 10808);
      expect(stages, hasLength(1));
      expect(stages.single.ok, isFalse);
    });

    test('diagnostics on a healthy tunnel walks all stages', () async {
      final checker = ConnectionChecker(
        socksOpen: (_) async => true,
        socksDomain: (_) async => 42,
        exit: (_) async => {'ip': '203.0.113.7', 'countryCode': 'NL'},
      );
      final stages = await checker.checkLive(socksPort: 10808);
      expect(stages, hasLength(3));
      expect(stages.every((s) => s.ok), isTrue);
      expect(stages[2].detail, contains('203.0.113.7'));
    });

    test('the journal tolerates a throwing sink', () {
      final journal = DiagnosticsJournal(
        sink: (_) => throw StateError('disk gone'),
      );
      journal.add('check', 'a line', ok: true);
      expect(journal.entries, hasLength(1));
      expect(journal.entries.single.line, contains('a line'));
    });
  });
}
