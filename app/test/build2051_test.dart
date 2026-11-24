/// Build 2051 gates, host side: audit F-H13 remainder — the
/// arbitrary per-subscription custom-headers map that build
/// 2050 left out (HWID + fallback URL shipped then; a panel
/// asking for any other header had no model field, no UI, and
/// no path from the stored subscription to the fetcher).
///
/// The gate that would have caught the original defect: the
/// controller-seam test asserting a subscription added WITH
/// headers sends exactly those headers on the add AND on
/// every later refresh — stored-but-never-sent is the bug
/// this batch exists to kill.
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/sub_fetcher.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

void main() {
  group('parseCustomHeaders (audit F-H13 remainder)', () {
    test('valid lines parse; values may contain colons', () {
      final r = parseCustomHeaders(
        'X-Panel-Key: abc:def\nAuthorization: Bearer token-1',
      );
      expect(r.error, isNull);
      expect(r.headers, {
        'X-Panel-Key': 'abc:def',
        'Authorization': 'Bearer token-1',
      });
    });

    test('blank lines are skipped; empty text is no headers', () {
      final r = parseCustomHeaders('\n  \nX-A: 1\n\n');
      expect(r.error, isNull);
      expect(r.headers, {'X-A': '1'});
      expect(parseCustomHeaders('').headers, isEmpty);
      expect(parseCustomHeaders('   \n').headers, isEmpty);
    });

    test('a line without a colon names its line number', () {
      final r = parseCustomHeaders('X-A: 1\njust-a-word\nX-B: 2');
      expect(r.error, contains('Line 2'));
      expect(r.error, contains('Name: value'));
      expect(r.headers, isEmpty);
    });

    test('an invalid header name is rejected by line', () {
      final r = parseCustomHeaders('Bad Name: x');
      expect(r.error, contains('Line 1'));
      expect(r.error, contains('Bad Name'));
    });

    test('an empty value is rejected by line', () {
      final r = parseCustomHeaders('X-A:   ');
      expect(r.error, contains('Line 1'));
      expect(r.error, contains('X-A'));
    });

    test('User-Agent is rejected — the app fixes its own UA', () {
      for (final spelling in ['User-Agent', 'user-agent', 'USER-AGENT']) {
        final r = parseCustomHeaders('$spelling: Fake/1.0');
        expect(r.error, contains('User-Agent'));
        expect(r.headers, isEmpty);
      }
    });

    test('a repeated name keeps the last value and spelling', () {
      final r = parseCustomHeaders('X-A: first\nx-a: second');
      expect(r.error, isNull);
      expect(r.headers, {'x-a': 'second'});
    });

    test('more than 10 headers is rejected', () {
      final text = List.generate(11, (i) => 'X-H$i: v').join('\n');
      final r = parseCustomHeaders(text);
      expect(r.error, contains('10'));
      expect(parseCustomHeaders(
        List.generate(10, (i) => 'X-H$i: v').join('\n'),
      ).headers, hasLength(10));
    });

  });

  group('Subscription customHeaders persistence', () {
    test('round-trips through toJson/fromJson', () {
      final sub = Subscription(
        id: 's1',
        name: 'S',
        url: 'https://x/sub',
        customHeaders: {'X-Panel-Key': 'k', 'X-Region': 'eu'},
      );
      final back = Subscription.fromJson(sub.toJson());
      expect(back.customHeaders, {'X-Panel-Key': 'k', 'X-Region': 'eu'});
    });

    test('a 2050-era record (no key) loads with no headers', () {
      final legacy = Subscription.fromJson({
        'id': 's0',
        'name': 'Old',
        'url': 'https://x/sub',
      });
      expect(legacy.customHeaders, isEmpty);
    });

    test('a wrong-typed stored value yields no headers, never a throw',
        () {
      final badType = Subscription.fromJson({
        'id': 's0',
        'url': 'https://x/sub',
        'customHeaders': 'not-a-map',
      });
      expect(badType.customHeaders, isEmpty);
      // A partly-bad map keeps only its good string entries.
      final partlyBad = Subscription.fromJson({
        'id': 's0',
        'url': 'https://x/sub',
        'customHeaders': {'X-A': '1', 'X-B': 42, 7: 'x'},
      });
      expect(partlyBad.customHeaders, {'X-A': '1'});
    });
  });

  group('Custom headers reach the fetcher (controller seam)', () {
    Profile fakeProfile() => Profile(
          id: 'fake1',
          protocol: Protocol.vless,
          name: 'Fake Node',
          address: 'node.example.com',
          port: 443,
          uuidOrPassword: '11111111-1111-1111-1111-111111111111',
        );

    test('add sends the stored headers; refresh sends them again',
        () async {
      final seen = <Map<String, String>>[];
      final c = XrayController();
      c.subscriptionFetcher = (url,
              {certPin = '',
              hwid = '',
              headers = const {},
              fallbackUrl = '',
              hosts = const {}}) async {
        seen.add(Map.of(headers));
        return SubResult(profiles: [fakeProfile()]);
      };
      final sub = await c.addSubscription(
        'https://panel.example/sub/abc',
        customHeaders: {'X-Panel-Key': 'k', 'X-Region': 'eu'},
      );
      expect(seen, hasLength(1));
      expect(seen.single, {'X-Panel-Key': 'k', 'X-Region': 'eu'});
      // The stored subscription still carries them, and the
      // refresh — the path a panel actually hits daily — sends
      // the same map, not an empty one.
      expect(sub.customHeaders, {'X-Panel-Key': 'k', 'X-Region': 'eu'});
      await c.updateSubscription(sub);
      expect(seen, hasLength(2));
      expect(seen[1], {'X-Panel-Key': 'k', 'X-Region': 'eu'});
    });

    test('a subscription without headers sends an empty map', () async {
      final seen = <Map<String, String>>[];
      final c = XrayController();
      c.subscriptionFetcher = (url,
              {certPin = '',
              hwid = '',
              headers = const {},
              fallbackUrl = '',
              hosts = const {}}) async {
        seen.add(Map.of(headers));
        return SubResult(profiles: [fakeProfile()]);
      };
      await c.addSubscription('https://panel.example/sub/abc');
      expect(seen.single, isEmpty);
    });
  });
}
