/// The 2.0.7 ping auto-sort: after results land, V2Ray configs
/// order themselves fastest-first (measured ascending, then
/// unmeasured, then failed) and Mozilla locations display in the
/// same order. Both sorts are STABLE — equal keys never swap.
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/core/models.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Profile _profile(String id, int delayMs, {bool failed = false}) => Profile(
      id: id,
      name: id,
      protocol: Protocol.vless,
      delayMs: delayMs,
      delayFailed: failed,
    );

Location _location(String code, int pingMs, {String error = ''}) =>
    Location.fromJson({
      'code': code,
      'name': code,
      'ping_ms': pingMs,
      if (error.isNotEmpty) 'ping_error': error,
    });

void main() {
  group('sortedByDelay (V2Ray configs)', () {
    test('measured delays sort ascending', () {
      final out = sortedByDelay([
        _profile('slow', 300),
        _profile('fast', 40),
        _profile('mid', 120),
      ]);
      expect(out.map((p) => p.id), ['fast', 'mid', 'slow']);
    });

    test('unmeasured sink below measured, failed sink last', () {
      final out = sortedByDelay([
        _profile('failed', -1, failed: true),
        _profile('unmeasured', -1),
        _profile('measured', 500),
      ]);
      expect(out.map((p) => p.id), ['measured', 'unmeasured', 'failed']);
    });

    test('a failed profile with no delay still ranks below unmeasured', () {
      expect(delaySortRank(_profile('u', -1)), 1);
      expect(delaySortRank(_profile('f', -1, failed: true)), 2);
      expect(delaySortRank(_profile('m', 0)), 0);
    });

    test('equal delays keep their previous relative order (stable)', () {
      final out = sortedByDelay([
        _profile('a', 100),
        _profile('b', 100),
        _profile('c', 100),
        _profile('d', 50),
      ]);
      expect(out.map((p) => p.id), ['d', 'a', 'b', 'c']);
    });

    test('unmeasured and failed groups are each stable', () {
      final out = sortedByDelay([
        _profile('f1', -1, failed: true),
        _profile('u1', -1),
        _profile('f2', -1, failed: true),
        _profile('u2', -1),
        _profile('m', 10),
      ]);
      expect(out.map((p) => p.id), ['m', 'u1', 'u2', 'f1', 'f2']);
    });

    test('the input list is not modified', () {
      final input = [_profile('b', 200), _profile('a', 10)];
      sortedByDelay(input);
      expect(input.map((p) => p.id), ['b', 'a']);
    });
  });

  group('sortedLocationsByPing (Mozilla servers)', () {
    test('answered locations sort ascending', () {
      final out = sortedLocationsByPing([
        _location('US', 180),
        _location('DE', 24),
        _location('NL', 41),
      ]);
      expect(out.map((l) => l.code), ['DE', 'NL', 'US']);
    });

    test('failed locations sink last, unmeasured in the middle', () {
      final out = sortedLocationsByPing([
        _location('FR', 0, error: 'timeout'),
        _location('JP', 0),
        _location('DE', 90),
      ]);
      expect(out.map((l) => l.code), ['DE', 'JP', 'FR']);
    });

    test('equal pings keep their previous relative order (stable)', () {
      final out = sortedLocationsByPing([
        _location('A', 50),
        _location('B', 50),
        _location('C', 30),
      ]);
      expect(out.map((l) => l.code), ['C', 'A', 'B']);
    });
  });
}
