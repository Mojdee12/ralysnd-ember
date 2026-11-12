/// Stage A generator tests (build 2026): the anti-filter
/// catalogue's integrity, the mixed-case SNI transform, the
/// generator precedence rules (ECH over unfilter, explicit
/// shape over the default mask, no shaping for non-TLS), and
/// the shaped-config shapes the profile editor's core-checked
/// save relies on. Live `xray run -test` results for every
/// shipped variant are recorded in BUILD-LOG-2.md (build 2026)
/// — these tests pin the DART side of that contract.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/xray/anti_filter.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Profile tlsProfile({
  String security = 'tls',
  String sni = 'cdn.example.com',
  String address = 'cdn.example.com',
  String network = 'ws',
  String host = 'cdn.example.com',
  String alpn = '',
}) {
  return Profile(
    id: 'p1',
    name: 'test',
    protocol: Protocol.vless,
    address: address,
    port: 443,
    uuidOrPassword: '00000000-0000-4000-8000-000000000000',
    network: network,
    host: host,
    security: security,
    sni: sni,
    alpn: alpn,
  );
}

void main() {
  group('fragment catalogue', () {
    test('ids are unique and F4/F5 are absent', () {
      final ids = afFragmentShapes.map((s) => s.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(ids, isNot(contains('f4')));
      expect(ids, isNot(contains('f5')));
      expect(afShapeById(''), isNull);
      expect(afShapeById('nope'), isNull);
      expect(afShapeById('f3')?.lengths, ['5', '1']);
    });

    test('every shape entry is a tlshello fragment mask', () {
      for (final shape in afFragmentShapes) {
        final e = shape.entry();
        expect(e['type'], 'fragment', reason: shape.id);
        final settings = e['settings'] as Map<String, dynamic>;
        expect(settings['packets'], 'tlshello', reason: shape.id);
        expect(settings['lengths'], shape.lengths, reason: shape.id);
        expect(settings['delays'], shape.delays, reason: shape.id);
      }
    });
  });

  group('mixCaseSni', () {
    test('changes only letter case, deterministically per seed', () {
      final mixed = mixCaseSni('cdn.example.com', rng: Random(42));
      expect(mixed.toLowerCase(), 'cdn.example.com');
      expect(mixed, isNot('cdn.example.com')); // seed 42 flips some
      expect(mixCaseSni('cdn.example.com', rng: Random(42)), mixed);
    });

    test('digits and dots pass through untouched', () {
      final mixed = mixCaseSni('a1.b2', rng: Random(7));
      expect(mixed[1], '1');
      expect(mixed[2], '.');
      expect(mixed[4], '2');
      expect(mixed[3].toLowerCase(), 'b'); // a letter: case may flip
    });
  });

  group('applyAntiFilter precedence', () {
    Map<String, dynamic> baseStream() => <String, dynamic>{
          'network': 'ws',
          'security': 'tls',
          'tlsSettings': <String, dynamic>{
            'serverName': 'cdn.example.com',
            'fingerprint': 'chrome',
          },
          'wsSettings': <String, dynamic>{
            'headers': <String, dynamic>{'Host': 'cdn.example.com'},
          },
        };

    test('no shaping flags = no-op', () {
      final stream = baseStream();
      applyAntiFilter(stream, tlsProfile());
      expect(stream.containsKey('finalmask'), isFalse);
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      expect(tls.containsKey('echConfigList'), isFalse);
      expect(tls.containsKey('cipherSuites'), isFalse);
    });

    test('unfilter adds ciphers, unsafe fingerprint and default mask', () {
      final stream = baseStream();
      final p = tlsProfile()..afUnfilter = true;
      applyAntiFilter(stream, p);
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      expect(tls['cipherSuites'], afUnfilterCipherSuites);
      expect(tls['fingerprint'], 'unsafe');
      expect((stream['finalmask'] as Map)['tcp'], afUnfilterFinalmask());
    });

    test('ECH beats unfilter and suppresses the mask', () {
      final stream = baseStream();
      final p = tlsProfile()
        ..afUnfilter = true
        ..afEch = true
        ..afFragment = 'f3';
      applyAntiFilter(stream, p);
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      expect(tls['echConfigList'], afEchConfigList);
      expect(tls.containsKey('cipherSuites'), isFalse);
      expect(stream.containsKey('finalmask'), isFalse);
    });

    test('an explicit shape replaces the default mask', () {
      final stream = baseStream();
      final p = tlsProfile()
        ..afUnfilter = true
        ..afFragment = 'f7';
      applyAntiFilter(stream, p);
      final mask = (stream['finalmask'] as Map)['tcp'] as List<dynamic>;
      expect(mask.length, 1);
      expect((mask.single as Map)['type'], 'fragment');
      expect(
        ((mask.single as Map)['settings'] as Map)['lengths'],
        ['32'],
      );
    });

    test('mixed-case SNI rewrites SNI and the ws Host together', () {
      final stream = baseStream();
      final p = tlsProfile()..afMixedSni = true;
      applyAntiFilter(stream, p, rng: Random(42));
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      final mixed = tls['serverName'] as String;
      expect(mixed.toLowerCase(), 'cdn.example.com');
      expect(mixed, isNot('cdn.example.com'));
      final ws = stream['wsSettings'] as Map<String, dynamic>;
      expect((ws['headers'] as Map)['Host'], mixed);
    });

    test('non-TLS security is never shaped', () {
      for (final security in ['reality', '']) {
        final stream = baseStream()..['security'] = security;
        final p = tlsProfile(security: security)
          ..afUnfilter = true
          ..afEch = true
          ..afFragment = 'f3'
          ..afMixedSni = true;
        applyAntiFilter(stream, p);
        expect(stream.containsKey('finalmask'), isFalse, reason: security);
        final tls = stream['tlsSettings'] as Map<String, dynamic>;
        expect(tls.containsKey('echConfigList'), isFalse, reason: security);
      }
    });

    test('IP-literal SNI is never case-mangled', () {
      final stream = baseStream();
      (stream['tlsSettings'] as Map<String, dynamic>)['serverName'] =
          '203.0.113.7';
      final p = tlsProfile(sni: '203.0.113.7', address: '203.0.113.7')
        ..afMixedSni = true;
      applyAntiFilter(stream, p, rng: Random(42));
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      expect(tls['serverName'], '203.0.113.7');
    });

    test('profile ALPN wins over the transport defaults', () {
      final stream = baseStream();
      // The real builder places the profile's ALPN in the
      // stream before applyAntiFilter runs.
      (stream['tlsSettings'] as Map<String, dynamic>)['alpn'] = ['h2'];
      final p = tlsProfile(alpn: 'h2')..afUnfilter = true;
      applyAntiFilter(stream, p);
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      expect(tls['alpn'], ['h2']);
    });
  });

  group('shaped test configs', () {
    Map<String, dynamic> decode(Profile p) =>
        jsonDecode(buildTestConfig(p, XraySettings())) as Map<String, dynamic>;

    Map<String, dynamic> proxyOutbound(Map<String, dynamic> cfg) =>
        (cfg['outbounds'] as List<dynamic>)
            .firstWhere((o) => (o as Map)['tag'] == 'proxy')
            as Map<String, dynamic>;

    test('unfilter lands in the built config', () {
      final p = tlsProfile()..afUnfilter = true;
      final out = proxyOutbound(decode(p));
      final stream = out['streamSettings'] as Map<String, dynamic>;
      expect(stream['finalmask'], isNotNull);
      expect(
        (stream['tlsSettings'] as Map)['cipherSuites'],
        afUnfilterCipherSuites,
      );
    });

    test('ECH lands in the built config without a mask', () {
      final p = tlsProfile()..afEch = true;
      final stream =
          proxyOutbound(decode(p))['streamSettings'] as Map<String, dynamic>;
      expect((stream['tlsSettings'] as Map)['echConfigList'], afEchConfigList);
      expect(stream.containsKey('finalmask'), isFalse);
    });

    test('TCP-noise-only adds a noises-only fragment outbound', () {
      final p = tlsProfile()..afTcpNoise = true;
      final cfg = decode(p);
      final frag = (cfg['outbounds'] as List<dynamic>)
          .firstWhere((o) => (o as Map)['tag'] == 'frag')
          as Map<String, dynamic>;
      final settings = frag['settings'] as Map<String, dynamic>;
      expect(settings['noises'], isNotNull);
      // Noise alone must never silently fragment packets.
      expect(settings.containsKey('fragment'), isFalse);
    });
  });
}
