/// Build 2154 — the URnetwork source.
///
/// Contract fixtures are built from the OpenAPI spec's
/// documented shapes (ur.io/openapi.yml, verified
/// firsthand 2026-11-27) plus the live shapes from the
/// owner's authorised account check (empty clients list;
/// daily + Pro balance entries; plan "supporter"). No
/// real account or key exists in these tests — the key
/// used is a fixture string, and the key-handling group
/// proves it never reaches the settings document.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/urnetwork/urnetwork_client.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

const _fixtureKey = 'urn_FIXTURE KEY 0000';

const _wgConf = '''
[Interface]
PrivateKey = YAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 10.8.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=
Endpoint = 203.0.113.7:51820
AllowedIPs = 0.0.0.0/0
''';

Map<String, Object?> _proxyClientRow() => {
      'client_id': 'client-aaa',
      'device_id': 'device-aaa',
      'network_id': 'network-aaa',
      'description': '',
      'device_name': 'proxy',
      'proxy_client': {
        'proxy_id': 'proxy-111',
        'client_id': 'client-aaa',
        'proxy_host': 'proxy1.urnetwork.example',
        'http_proxy_port': 8080,
        'https_proxy_port': 8443,
        'socks_proxy_port': 1080,
        'http_proxy_url': 'http://tok@proxy1.urnetwork.example:8080',
        'https_proxy_url': 'https://tok.proxy1.urnetwork.example:8443',
        'socks_proxy_url': 'socks5://tok@proxy1.urnetwork.example:1080',
        'auth_token': 'tok-abc',
        'wg_config': {
          'wg_proxy_port': 51820,
          'client_private_key': 'YAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=',
          'client_public_key': 'pub',
          'client_ipv4': '10.8.0.2',
          'proxy_public_key': 'HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=',
          'config': _wgConf,
        },
      },
      'exit': {
        'country_code': 'de',
        'region': 'Bavaria',
        'city': 'Munich',
        'state': 'assigned',
      },
      'pro_features': ['socks_proxy', 'wireguard_proxy'],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('contract — proxies list', () {
    test('the live empty shape parses: no proxies, plan pro', () {
      final result = parseUrProxies(
        jsonDecode('{"clients": [], "plan": {"pro": true, '
            '"pro_features_enforced": false}}'),
      );
      expect(result.proxies, isEmpty);
      expect(result.pro, isTrue);
      expect(result.proFeaturesEnforced, isFalse);
    });

    test('a full row parses: ports, token, WG text, exit, features', () {
      final result = parseUrProxies({
        'clients': [_proxyClientRow()],
        'plan': {'pro': true, 'pro_features_enforced': true},
      });
      expect(result.proxies, hasLength(1));
      final p = result.proxies.single;
      expect(p.clientId, 'client-aaa');
      expect(p.proxyId, 'proxy-111');
      expect(p.host, 'proxy1.urnetwork.example');
      expect(p.httpPort, 8080);
      expect(p.httpsPort, 8443);
      expect(p.socksPort, 1080);
      expect(p.authToken, 'tok-abc');
      expect(p.wgConfigText, contains('[Interface]'));
      expect(p.exit?.countryCode, 'de');
      expect(p.exit?.city, 'Munich');
      expect(p.exit?.state, 'assigned');
      expect(p.proFeatures, ['socks_proxy', 'wireguard_proxy']);
    });

    test('rows without a proxy_client are skipped, not fatal', () {
      final result = parseUrProxies({
        'clients': [
          {'client_id': 'plain-client'},
          _proxyClientRow(),
        ],
      });
      expect(result.proxies, hasLength(1));
    });

    test('a non-object payload is a format error, not a crash', () {
      expect(() => parseUrProxies('nope'), throwsFormatException);
    });
  });

  group('contract — balance', () {
    test('the live shape: daily + Pro entries and the totals', () {
      final balance = parseUrBalance({
        'start_balance_byte_count': 32212254720 + 10995116277760,
        'balance_byte_count': 30000000000 + 10000000000000,
        'active_transfer_balances': [
          {
            'balance_id': 'b1',
            'start_balance_byte_count': 32212254720,
            'balance_byte_count': 30000000000,
            'pro': false,
          },
          {
            'balance_id': 'b2',
            'start_balance_byte_count': 10995116277760,
            'balance_byte_count': 10000000000000,
            'pro': true,
          },
        ],
        'current_subscription': {'plan': 'supporter', 'store': 'stripe'},
      });
      expect(balance.planName, 'supporter');
      expect(balance.totalBytes, 30000000000 + 10000000000000);
      expect(balance.entries, hasLength(2));
      expect(balance.entries[0].pro, isFalse);
      expect(balance.entries[1].pro, isTrue);
      expect(balance.entries[1].label, contains('Pro'));
    });

    test('missing fields degrade to omitted rows, never faked', () {
      final balance = parseUrBalance({'current_subscription': {}});
      expect(balance.totalBytes, -1);
      expect(balance.entries, isEmpty);
      expect(balance.planName, '');
      final empty = parseUrBalance(null);
      expect(empty.totalBytes, -1);
    });
  });

  group('contract — countries', () {
    test('only country rows, sorted by name', () {
      final countries = parseUrCountries({
        'locations': [
          {
            'location_id': 'l2',
            'location_type': 'country',
            'name': 'Netherlands',
            'country_code': 'NL',
            'provider_count': 12,
          },
          {
            'location_id': 'l3',
            'location_type': 'city',
            'name': 'Berlin',
            'country_code': 'DE',
            'provider_count': 40,
          },
          {
            'location_id': 'l1',
            'location_type': 'country',
            'name': 'Germany',
            'country_code': 'DE',
            'provider_count': 55,
          },
        ],
      });
      expect(countries.map((c) => c.name), ['Germany', 'Netherlands']);
      expect(countries.first.providerCount, 55);
      expect(countries.first.countryCode, 'DE');
    });
  });

  group('profile building', () {
    final account = UrAccount(id: 'uabcx1', label: '');

    test('one proxy builds socks/http/https/wg with stable ids', () {
      final parsed = parseUrProxies({
        'clients': [_proxyClientRow()],
      });
      final profiles = urProfilesForProxy(
        account: account,
        proxy: parsed.proxies.single,
        multiAccount: false,
        sameCountryOrdinal: 0,
      );
      expect(profiles.map((p) => p.id), [
        'urnetwork-uabcx1-proxy-111-socks',
        'urnetwork-uabcx1-proxy-111-http',
        'urnetwork-uabcx1-proxy-111-https',
        'urnetwork-uabcx1-proxy-111-wg',
      ]);
      final socks = profiles[0];
      expect(socks.protocol, Protocol.socks);
      expect(socks.username, 'tok-abc');
      expect(socks.name, 'UR · Germany · Munich · SOCKS');
      final https = profiles[2];
      expect(https.protocol, Protocol.http);
      expect(https.security, 'tls');
      expect(https.sni, 'proxy1.urnetwork.example');
      final wg = profiles[3];
      expect(wg.protocol, Protocol.wireguard);
      expect(wg.name, 'UR · Germany · Munich · WG');
    });

    test('a proxy without a WG config builds no WG profile', () {
      final row = _proxyClientRow();
      row['proxy_client'] = {
        ...(row['proxy_client'] as Map<String, Object?>),
        'wg_config': null,
      };
      final parsed = parseUrProxies({'clients': [row]});
      final profiles = urProfilesForProxy(
        account: account,
        proxy: parsed.proxies.single,
        multiAccount: false,
        sameCountryOrdinal: 0,
      );
      expect(profiles.map((p) => p.protocol), [
        Protocol.socks,
        Protocol.http,
        Protocol.http,
      ]);
    });

    test('chosen country names a non-unique proxy; ordinals disambiguate', () {
      final row = _proxyClientRow()..remove('exit');
      final parsed = parseUrProxies({'clients': [row]});
      final proxy = parsed.proxies.single;
      final named = UrAccount(
        id: 'uabcx1',
        label: '',
        proxyCountries: {proxy.proxyId: 'nl'},
      );
      expect(urProxyCountryCode(named, proxy), 'nl');
      final profiles = urProfilesForProxy(
        account: named,
        proxy: proxy,
        multiAccount: true,
        sameCountryOrdinal: 2,
      );
      expect(profiles.first.name, startsWith('UR · Netherlands 2'));
    });

    test('profile id helpers round-trip the account id', () {
      expect(
        urAccountIdOfProfileId('urnetwork-uabcx1-proxy-111-socks'),
        'uabcx1',
      );
      expect(isUrProfileId('urnetwork-uabcx1-proxy-111-socks'), isTrue);
      expect(isUrProfileId('regionhop-de'), isFalse);
      expect(urAccountIdOfProfileId('manual-1'), '');
    });
  });

  group('config builder — the HTTPS hop', () {
    test('an http profile with tls security emits TLS stream settings', () {
      final p = Profile(
        id: 'urnetwork-a-b-https',
        protocol: Protocol.http,
        name: 'UR · Germany · HTTPS',
        address: 'proxy1.urnetwork.example',
        port: 8443,
        username: 'tok-abc',
        security: 'tls',
        sni: 'proxy1.urnetwork.example',
      );
      final out = buildOutbound(p, XraySettings())!;
      final stream = out['streamSettings'] as Map;
      expect(stream['security'], 'tls');
      expect(
        (stream['tlsSettings'] as Map)['serverName'],
        'proxy1.urnetwork.example',
      );
    });

    test('a plain http profile keeps the sockopt-only map byte-shape', () {
      final p = Profile(
        id: 'h1',
        protocol: Protocol.http,
        name: 'plain',
        address: 'proxy.example',
        port: 8080,
        username: 'u',
      );
      final out = buildOutbound(p, XraySettings())!;
      expect(out['streamSettings'], {
        'sockopt': <String, dynamic>{},
      });
    });
  });

  group('client — transport seam', () {
    UrNetworkClient clientReturning(int status, String body,
        {void Function(String method, Uri uri, Map<String, String> headers,
                String? jsonBody)?
            onCall}) {
      return UrNetworkClient(
        apiKey: _fixtureKey,
        transport: (method, uri, {headers = const {}, jsonBody}) async {
          onCall?.call(method, uri, headers, jsonBody);
          return UrHttpResponse(status, body);
        },
      );
    }

    test('the key rides only the Authorization header', () async {
      String? auth;
      Uri? seen;
      final client = clientReturning(
        200,
        '{"clients": [], "plan": {"pro": true}}',
        onCall: (method, uri, headers, body) {
          auth = headers['authorization'];
          seen = uri;
        },
      );
      await client.fetchProxies();
      expect(auth, 'Bearer $_fixtureKey');
      expect(seen.toString(), 'https://api.bringyour.com/network/proxies');
    });

    test('401 is the key-refused state', () async {
      final client = clientReturning(401, '{"error": {"message": "no"}}');
      await expectLater(
        client.fetchProxies(),
        throwsA(
          isA<UrNetworkException>()
              .having((e) => e.kind, 'kind', UrErrorKind.keyRefused),
        ),
      );
    });

    test('a 200 refusal surfaces the server message verbatim', () async {
      final client = clientReturning(
        200,
        '{"error": {"client_limit_exceeded": true, '
        '"message": "proxy limit reached"}}',
      );
      await expectLater(
        client.createProxy(countryCode: 'de'),
        throwsA(
          isA<UrNetworkException>()
              .having((e) => e.message, 'message', 'proxy limit reached'),
        ),
      );
    });

    test('create posts the spec body: wg on, country, unique exit', () async {
      String? body;
      final client = clientReturning(
        200,
        jsonEncode({
          'client_id': 'client-bbb',
          'proxy_config_result': {
            'proxy_id': 'proxy-222',
            'client_id': 'client-bbb',
            'proxy_host': 'proxy2.urnetwork.example',
            'socks_proxy_port': 1080,
            'auth_token': 'tok-def',
          },
        }),
        onCall: (method, uri, headers, b) => body = b,
      );
      final proxy = await client.createProxy(
        countryCode: 'DE',
        uniqueExit: true,
      );
      expect(proxy.proxyId, 'proxy-222');
      final sent = jsonDecode(body!) as Map;
      final config = sent['proxy_config'] as Map;
      expect(config['enable_wg'], isTrue);
      expect(config['unique_exit'], isTrue);
      expect(
        (config['initial_device_state'] as Map)['country_code'],
        'de',
      );
    });

    test('a balance failure degrades to null, never a throw', () async {
      final client = clientReturning(500, 'oops');
      expect(await client.fetchBalanceOrNull(), isNull);
    });
  });

  group('controller — accounts, refresh, key handling', () {
    late Directory tempDir;
    late Map<String, String> vault;

    File stateFile() => File('${tempDir.path}/xray/state.json');

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ember2154-');
      vault = {};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'),
              (call) async {
        switch (call.method) {
          case 'dataDir':
            return '${tempDir.path}/core';
          case 'secretStore':
            final args = call.arguments as Map;
            vault[args['key'] as String] = args['value'] as String;
            return true;
          case 'secretLoad':
            final args = call.arguments as Map;
            return vault[args['key'] as String];
          case 'secretDelete':
            final args = call.arguments as Map;
            vault.remove(args['key'] as String);
            return null;
          default:
            return null;
        }
      });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'), null);
      // A controller's chained save can land just after a
      // test's own settle delay; the delete retries rather
      // than flaking on the not-empty race.
      for (var i = 0; i < 10; i++) {
        try {
          await tempDir.delete(recursive: true);
          break;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });

    test('add stores the key in the vault ONLY; refresh builds profiles; '
        'remove deletes both', () async {
      final c = XrayController();
      await c.load();
      final result = parseUrProxies({
        'clients': [_proxyClientRow()],
        'plan': {'pro': true},
      });
      c.urNetworkClientFactory = (key) {
        expect(key, _fixtureKey);
        return _StubUrClient(result);
      };
      final account = await c.addUrNetworkAccount(
        label: 'Main',
        apiKey: _fixtureKey,
      );
      expect(vault[urNetworkVaultKey(account.id)], _fixtureKey);
      // The settings document (what state.json persists)
      // carries the account metadata and NO key.
      final settingsJson = jsonEncode(c.settings.toJson());
      expect(settingsJson.contains(_fixtureKey), isFalse);
      expect(settingsJson.contains('urn_'), isFalse);
      expect(c.urAccounts.single.label, 'Main');

      await c.refreshUrNetworkAccount(account.id);
      expect(c.profiles.map((p) => p.id), [
        'urnetwork-${account.id}-proxy-111-socks',
        'urnetwork-${account.id}-proxy-111-http',
        'urnetwork-${account.id}-proxy-111-https',
        'urnetwork-${account.id}-proxy-111-wg',
      ]);
      expect(c.urAccounts.single.pro, isTrue);
      expect(c.urAccounts.single.lastRefreshMs, greaterThan(0));

      // The persisted file itself: no key anywhere.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final onDisk = await stateFile().readAsString();
      expect(onDisk.contains(_fixtureKey), isFalse);

      await c.removeUrNetworkAccount(account.id);
      expect(c.profiles, isEmpty);
      expect(vault.containsKey(urNetworkVaultKey(account.id)), isFalse);
      expect(c.urAccounts, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      c.dispose();
    });

    test('a refresh replaces atomically and carries volatile fields', () async {
      final c = XrayController();
      await c.load();
      var rows = <Map<String, Object?>>[_proxyClientRow()];
      c.urNetworkClientFactory = (key) => _StubUrClient(
            parseUrProxies({
              'clients': rows,
              'plan': {'pro': true},
            }),
          );
      final account = await c.addUrNetworkAccount(apiKey: _fixtureKey);
      await c.refreshUrNetworkAccount(account.id);
      final socksId = 'urnetwork-${account.id}-proxy-111-socks';
      c.profiles.firstWhere((p) => p.id == socksId).delayMs = 42;

      // The proxy vanishes upstream: its profiles go with
      // it, and a manual profile is never touched.
      c.profiles.add(
        Profile(
          id: 'manual-1',
          protocol: Protocol.vless,
          name: 'mine',
          address: 'v.example',
          port: 443,
        ),
      );
      rows = [];
      await c.refreshUrNetworkAccount(account.id);
      expect(c.profiles.map((p) => p.id), ['manual-1']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      c.dispose();
    });

    test('an empty key is refused before anything is stored', () async {
      final c = XrayController();
      await c.load();
      await expectLater(
        c.addUrNetworkAccount(apiKey: '  '),
        throwsStateError,
      );
      expect(c.urAccounts, isEmpty);
      expect(vault, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      c.dispose();
    });
  });

  group('source hygiene', () {
    test('no credential-shaped string anywhere in lib/', () {
      final libDir = Directory('lib');
      final pattern = RegExp(r'urn_[A-Za-z0-9_\-]{12,}');
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith('.dart')) {
          final text = entity.readAsStringSync();
          expect(
            pattern.hasMatch(text),
            isFalse,
            reason: '${entity.path} carries a credential-shaped string',
          );
        }
      }
    });

    test('the pubspec carries the 2154 build number', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('version: 2.2.0+2155'));
    });
  });
}

/// A client whose answers are fixtures: the transport is
/// never reached because every method the controller
/// uses is overridden.
class _StubUrClient extends UrNetworkClient {
  _StubUrClient(this.result) : super(apiKey: 'stub');

  final UrProxiesResult result;

  @override
  Future<UrProxiesResult> fetchProxies() async => result;

  @override
  Future<UrBalance?> fetchBalanceOrNull() async => null;
}
