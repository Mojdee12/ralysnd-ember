/// Build 2094 gates: subscription adding in the V2Ray section
/// (owner report 2026-11-17: "why can't a subscription be added
/// in V2Ray? there's no tab for it at all").
///
/// Root causes pinned here:
/// 1. importLinksAsync routed Clash YAML and Lantern links but
///    let an http(s) subscription URL fall through to the link
///    parser, which reads http(s) lines as proxy links or
///    nothing — a pasted subscription link silently added 0
///    configs. Subscription URLs now route to addSubscription.
/// 2. The Servers Import sheet offered Paste / Manual / CF
///    clean IP only; the add-subscription sheet existed but was
///    reachable solely from the Accounts tab. The sheet now
///    carries an Add subscription entry opening the same form.
///
/// Fetch inspection fixes pinned here too: the wait for a
/// subscription server's response headers is bounded (it was
/// not — a tarpit server hung the add flow forever), and two
/// subscriptions added in one millisecond no longer share an
/// id (the second refresh wiped the first one's profiles).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/ui/ember/ember_servers.dart';
import 'package:firefox_vpn/xray/sub_fetcher.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

const _vlessLink =
    'vless://11111111-1111-1111-1111-111111111111@node.example.com:443'
    '?encryption=none&security=tls&type=ws#Node%20One';

Profile _profile(
  String id,
  String name, {
  String address = 'node.example.com',
  String uuid = '11111111-1111-1111-1111-111111111111',
}) => Profile(
  id: id,
  protocol: Protocol.vless,
  name: name,
  address: address,
  port: 443,
  uuidOrPassword: uuid,
);

/// A controller whose subscription fetcher is [fetch].
XrayController _controllerWith(Future<SubResult> Function(String url) fetch) {
  final c = XrayController();
  c.subscriptionFetcher = (
    url, {
    certPin = '',
    hwid = '',
    headers = const {},
    fallbackUrl = '',
    hosts = const {},
  }) => fetch(url);
  return c;
}

void main() {
  setUp(() {
    // This file contains a testWidgets, so the test binding
    // installs its mock HttpClient (400 for everything) over
    // the whole file — the fetcher timeout test below serves a
    // real loopback connection and needs the real client (the
    // build 2075 pattern).
    HttpOverrides.global = null;
  });

  group('subscription URL detection (build 2094)', () {
    test('panel URLs with a path or a query are subscriptions', () {
      expect(isSubscriptionUrl('https://panel.example.com/sub/abc123'), isTrue);
      expect(
        isSubscriptionUrl('https://panel.example.com:8443/sub/abc'),
        isTrue,
      );
      expect(isSubscriptionUrl('http://203.0.113.7:2096/sub/abc'), isTrue);
      expect(isSubscriptionUrl('https://panel.example.com/?token=abc'), isTrue);
      expect(
        isSubscriptionUrl('https://panel.example.com/sub/abc#name'),
        isTrue,
      );
    });

    test('HTTP-proxy share links are NOT subscriptions', () {
      // The link parser reads these as proxy profiles; the
      // importer's subscription branch must not claim them.
      expect(isSubscriptionUrl('http://203.0.113.7:8080'), isFalse);
      expect(isSubscriptionUrl('http://user:pass@203.0.113.7:8080'), isFalse);
      expect(isSubscriptionUrl('http://user:pass@203.0.113.7:8080#P'), isFalse);
      expect(isSubscriptionUrl('https://proxy.example.com:443'), isFalse);
    });

    test('share links and junk are NOT subscriptions', () {
      expect(isSubscriptionUrl(_vlessLink), isFalse);
      expect(isSubscriptionUrl('ss://YWVzLTI1Ni1nY206cA@h:8388'), isFalse);
      expect(isSubscriptionUrl('https://panel.example.com'), isFalse);
      expect(isSubscriptionUrl('not a url'), isFalse);
      expect(isSubscriptionUrl(''), isFalse);
    });
  });

  group('paste import routes subscription URLs (build 2094)', () {
    test(
      'a pasted subscription URL adds the subscription and reports it',
      () async {
        final c = _controllerWith(
          (url) async => SubResult(
            // Build 2095: the two nodes are distinct servers
            // (address + credentials) — the refresh dedupe
            // (V2Ray audit #11) collapses identity-duplicate
            // entries, which the old fixture accidentally was.
            profiles: [
              _profile('a1', 'A One'),
              _profile(
                'a2',
                'A Two',
                address: 'two.example.com',
                uuid: '22222222-2222-2222-2222-222222222222',
              ),
            ],
            suggestedName: 'Panel A',
          ),
        );
        addTearDown(c.dispose);
        final r = await c.importLinksAsync('https://panel.example.com/sub/abc');
        expect(r.errors, isEmpty);
        expect(r.added, 2);
        expect(r.subscriptions, hasLength(1));
        expect(r.subscriptions.single.name, 'Panel A');
        expect(r.subscriptions.single.configs, 2);
        expect(c.subscriptions, hasLength(1));
        expect(c.profiles, hasLength(2));
        expect(
          c.profiles.every(
            (p) => p.subscriptionId == c.subscriptions.single.id,
          ),
          isTrue,
        );
      },
    );

    test(
      'mixed paste: a subscription URL plus share links adds both',
      () async {
        // The subscription's node is a DIFFERENT server than
        // the pasted link's: same-identity configs would
        // (correctly) collapse under the importer's
        // store-wide dedupe.
        final c = _controllerWith(
          (url) async => SubResult(
            profiles: [
              _profile(
                'b1',
                'B One',
                address: 'sub.example.com',
                uuid: '22222222-2222-2222-2222-222222222222',
              ),
            ],
          ),
        );
        addTearDown(c.dispose);
        final r = await c.importLinksAsync(
          'https://panel.example.com/sub/abc\n$_vlessLink',
        );
        expect(r.errors, isEmpty);
        expect(r.subscriptions, hasLength(1));
        expect(r.subscriptions.single.configs, 1);
        expect(r.added, 2);
        expect(c.subscriptions, hasLength(1));
        expect(c.profiles, hasLength(2));
      },
    );

    test(
      'a failed subscription fetch surfaces its error, stores nothing',
      () async {
        final c = _controllerWith(
          (url) async => throw const SubFetchException(
            kind: SubFetchErrorKind.http,
            message: 'The server answered HTTP 403 (Forbidden).',
            statusCode: 403,
          ),
        );
        addTearDown(c.dispose);
        final r = await c.importLinksAsync('https://panel.example.com/sub/abc');
        expect(r.added, 0);
        expect(r.subscriptions, isEmpty);
        expect(r.errors, hasLength(1));
        expect(r.errors.single, contains('403'));
        expect(c.subscriptions, isEmpty);
        expect(c.profiles, isEmpty);
      },
    );

    test(
      'two subscription URLs in one paste keep separate ids and profiles',
      () async {
        final c = _controllerWith(
          (url) async => url.contains('a.example')
              ? SubResult(profiles: [_profile('a1', 'A One')])
              : SubResult(profiles: [_profile('b1', 'B One')]),
        );
        addTearDown(c.dispose);
        final r = await c.importLinksAsync(
          'https://a.example/sub/1\nhttps://b.example/sub/2',
        );
        expect(r.errors, isEmpty);
        expect(r.subscriptions, hasLength(2));
        expect(c.subscriptions, hasLength(2));
        // The build 2094 id fix: same-millisecond adds must not
        // share an id — the second refresh would have removed
        // the first subscription's profiles as its own.
        expect(c.subscriptions[0].id, isNot(c.subscriptions[1].id));
        expect(c.profiles, hasLength(2));
        expect(c.profilesOf(c.subscriptions[0]), hasLength(1));
        expect(c.profilesOf(c.subscriptions[1]), hasLength(1));
      },
    );

    test('the same URL pasted twice is fetched once', () async {
      var fetches = 0;
      final c = _controllerWith((url) async {
        fetches++;
        return SubResult(profiles: [_profile('a1', 'A One')]);
      });
      addTearDown(c.dispose);
      final r = await c.importLinksAsync(
        'https://panel.example.com/sub/abc\nhttps://panel.example.com/sub/abc',
      );
      expect(fetches, 1);
      expect(r.subscriptions, hasLength(1));
      expect(c.subscriptions, hasLength(1));
    });

    test(
      'an HTTP-proxy link line stays a proxy profile, fetcher untouched',
      () async {
        var fetches = 0;
        final c = _controllerWith((url) async {
          fetches++;
          return SubResult(profiles: [_profile('x1', 'X')]);
        });
        addTearDown(c.dispose);
        final r = await c.importLinksAsync(
          'http://user:pass@203.0.113.7:8080#My%20Proxy',
        );
        expect(fetches, 0);
        expect(r.subscriptions, isEmpty);
        expect(r.added, 1);
        expect(c.profiles.single.protocol, Protocol.http);
        expect(c.profiles.single.port, 8080);
      },
    );
  });

  group('fetcher response-header timeout (build 2094)', () {
    test(
      'a server that accepts and never answers fails as a timeout',
      () async {
        final server = await HttpServer.bind('127.0.0.1', 0);
        addTearDown(() => server.close(force: true));
        server.listen((_) {
          // Deliberately never respond: the tarpit case.
        });
        await expectLater(
          fetchSubscription(
            'http://127.0.0.1:${server.port}/sub/abc',
            responseTimeout: const Duration(milliseconds: 300),
          ),
          throwsA(
            isA<SubFetchException>().having(
              (e) => e.kind,
              'kind',
              SubFetchErrorKind.timeout,
            ),
          ),
        );
      },
    );
  });

  group('Servers import sheet (build 2094)', () {
    testWidgets('the Import sheet offers Add subscription, opening the form', (
      tester,
    ) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final core = CoreController(
        () async => throw const CoreUnavailable(CoreProblem.refused, 'test'),
      );
      addTearDown(core.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: EmberServers(
              core: core,
              xray: xray,
              v2ray: true,
              onOpenAccounts: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Import'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // All four add paths are on the sheet now.
      expect(find.text('Add subscription'), findsOneWidget);
      expect(find.text('CF clean IP'), findsOneWidget);
      await tester.tap(find.text('Add subscription'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // The shared add-subscription form opened: its URL field.
      expect(find.text('https://…'), findsOneWidget);
    });
  });
}
