/// Stage A scanner tests (build 2026): the funnel's stage-3
/// ordering (pure ranking — the real tests decide, TCP time
/// only orders the queue) and the Cloudflare candidate
/// sampler's range discipline (every sampled IP inside its
/// curated CIDR, seeds first, deduped).

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/xray/cf_scanner.dart';
import 'package:firefox_vpn/xray/scan_probes.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Profile probe(String id, {Protocol protocol = Protocol.vless}) => Profile(
      id: id,
      name: id,
      protocol: protocol,
      address: '$id.example.com',
      port: 443,
      security: 'tls',
      sni: '$id.example.com',
    );

void main() {
  group('funnelStage3Order', () {
    test('survivors by TCP time, then realtime, then fall-through', () {
      final a = probe('a');
      final b = probe('b');
      final c = probe('c');
      final udp = probe('u', protocol: Protocol.hysteria2);
      final dead = probe('d');
      final ordered = funnelStage3Order(
        survivors: [a, b, c],
        tcpMs: {'a': 300, 'b': 50, 'c': 120},
        realtime: [udp],
        fallThrough: [dead],
      );
      expect(ordered.map((p) => p.id), ['b', 'c', 'a', 'u', 'd']);
    });

    test('a survivor without a TCP time sorts last among survivors', () {
      final a = probe('a');
      final b = probe('b');
      final ordered = funnelStage3Order(
        survivors: [a, b],
        tcpMs: {'b': 90},
        realtime: const [],
        fallThrough: const [],
      );
      expect(ordered.map((p) => p.id), ['b', 'a']);
    });

    test('cheap stages are skipped for UDP-only protocols', () {
      expect(funnelSkipsCheapStages(probe('w', protocol: Protocol.wireguard)),
          isTrue);
      expect(funnelSkipsCheapStages(probe('h', protocol: Protocol.hysteria2)),
          isTrue);
      expect(funnelSkipsCheapStages(probe('v')), isFalse);
    });

    test('the SNI of record: explicit SNI, else Host, else address', () {
      final explicit = probe('x')
        ..sni = 'sni.example.com'
        ..host = 'host.example.com';
      expect(funnelSniOf(explicit), 'sni.example.com');
      final hosted = probe('y')
        ..sni = ''
        ..host = 'host.example.com, other.example.com';
      expect(funnelSniOf(hosted), 'host.example.com');
      final bare = probe('z')
        ..sni = ''
        ..host = '';
      expect(funnelSniOf(bare), 'z.example.com');
    });
  });

  group('cfCandidates', () {
    test('seeds come first, everything deduped', () {
      final out = cfCandidates(Random(1));
      expect(out.sublist(0, cfSeedIps.length), cfSeedIps);
      expect(out.toSet().length, out.length);
    });

    test('extraFirst leads, ahead of the seeds', () {
      final out = cfCandidates(Random(1), extraFirst: ['203.0.113.9']);
      expect(out.first, '203.0.113.9');
    });

    test('every sampled candidate lies inside a curated range', () {
      final ranges = [...cfWideRanges, ...cfRegionalRanges];
      for (final seed in [1, 7, 99]) {
        for (final ip in cfCandidates(Random(seed))) {
          if (cfSeedIps.contains(ip)) continue;
          expect(
            ranges.any((r) => ipInCidr(ip, r)),
            isTrue,
            reason: '$ip (seed $seed) escaped the curated ranges',
          );
        }
      }
    });

    test('ipInCidr edges', () {
      expect(ipInCidr('104.16.0.0', '104.16.0.0/14'), isTrue);
      expect(ipInCidr('104.19.255.255', '104.16.0.0/14'), isTrue);
      expect(ipInCidr('104.20.0.0', '104.16.0.0/14'), isFalse);
      expect(ipInCidr('104.16.0.0', '104.16.0.0/32'), isTrue);
      expect(ipInCidr('104.16.0.1', '104.16.0.0/32'), isFalse);
      expect(ipInCidr('not-an-ip', '104.16.0.0/14'), isFalse);
    });
  });
}
