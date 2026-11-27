/// Build 2156 — the URnetwork ENGINE.
///
/// URnetwork joins the engine board (mode 8): the vendor
/// SDK (com.bringyour.sdk, AAR v2026.11.22, MPL-2.0) runs
/// its DeviceLocal core in a dedicated :urnetwork process
/// behind Ember's own VpnService, shaded so its gomobile
/// runtime coexists with the other Go cores (go/ -> ur/,
/// libgojni.so -> liburcore.so, the six shared Java_go_*
/// JNI exports renamed to Java_ur_* with rebuilt hash
/// tables — the build-2007 Psiphon fix, re-applied).
///
/// The owner's UX ruling: ONE Best Available connect is
/// the primary action; a country pick exists for when he
/// wants a specific country. Auth reuses the build-2154
/// accounts (vault keys); the auth-client exchange mints
/// a 30-day client JWT, cached in the vault and
/// re-exchanged only when stale, because every exchange
/// mints a new client on the account. Providing is pinned
/// OFF (the vendor ConnectViewController is never used).
///
/// These tests pin the wiring and the auth/cache logic.
/// The behavioural proof is the owner's device acceptance;
/// nothing here claims the SDK carries traffic.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/urnetwork/ur_engine_controller.dart';
import 'package:firefox_vpn/urnetwork/ur_platform.dart';
import 'package:firefox_vpn/urnetwork/urnetwork_client.dart';

const _fixtureKey = 'urn_FIXTURE KEY 0000';

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String kotlinSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

/// A JWT with the given exp (seconds), unsigned-fixture
/// shaped: base64url(header).base64url(payload).sig.
String fixtureJwt(int expSeconds) {
  String b64(Object? json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${b64({'alg': 'none'})}.${b64({'exp': expSeconds, 'pro': true})}.sig';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('build 2156 — the shaded vendor core', () {
    test('the shaded AAR ships in libs, arm64 liburcore only', () {
      final aar = File('android/app/libs/urnetwork.aar');
      expect(aar.existsSync(), isTrue);
      final bytes = aar.readAsBytesSync();
      // ~20 MB on disk: the 60 MB .so deflates to ~19.4 MB
      // (the spike's measured APK delta).
      expect(bytes.length, greaterThan(15 * 1024 * 1024));
      // Zip entry names ride the local headers + central
      // directory in the clear even when entries deflate.
      final text = latin1.decode(bytes, allowInvalid: true);
      expect(text, contains('jni/arm64-v8a/liburcore.so'));
      expect(text, contains('classes.jar'));
      expect(text.contains('libgojni.so'), isFalse);
    });

    test('gradle depends on the AAR and keeps liburcore byte-exact', () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('libs/urnetwork.aar'));
      expect(gradle, contains('keepDebugSymbols += "**/liburcore.so"'));
    });

    test('proguard keeps the SDK and the shaded runtime whole', () {
      final rules = File('android/app/proguard-rules.pro').readAsStringSync();
      expect(rules, contains('-keep class com.bringyour.sdk.** { *; }'));
      expect(rules, contains('-keep class ur.** { *; }'));
    });

    test('the manifest declares UrVpnService in its own process', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('android:name=".UrVpnService"'));
      expect(manifest, contains('android:process=":urnetwork"'));
    });
  });

  group('build 2156 — the Kotlin glue pins', () {
    final service = kotlinSrc('UrVpnService.kt');

    test('providing is pinned None on device AND local state', () {
      expect(
        'setProvideMode(Sdk.ProvideModeNone)'
            .allMatches(service)
            .length,
        greaterThanOrEqualTo(2),
      );
    });

    test('the vendor view controllers are never used', () {
      // The class doc names the trap; the pin is on USE:
      // no construction, no factory call, no import.
      expect(service.contains('ConnectViewController('), isFalse);
      expect(service.contains('newConnectViewController'), isFalse);
      expect(
        service.contains('import com.bringyour.sdk.ConnectViewController'),
        isFalse,
      );
    });

    test('the TUN fd is duplicated before the io loop takes it', () {
      expect(service, contains('pfd.dup()'));
      expect(service, contains('Sdk.newIoLoop'));
      expect(service, contains('detachFd()'));
    });

    test('DNS comes from the device object; route-local follows '
        'the kill switch', () {
      expect(service, contains('tunnelDnsAddressesIpv4'));
      expect(service, contains('tunnelDnsAddressesIpv6'));
      expect(service, contains('setRouteLocal(!inKillSwitch)'));
    });

    test('the production network space is created the documented way',
        () {
      expect(service, contains('Sdk.newNetworkSpaceManager'));
      expect(service, contains('"ur.network", "main"'));
      expect(service, contains('migrationHostName = "bringyour.com"'));
      expect(service, contains('updateNetworkSpace'));
    });

    test('the service claims the slot under the URnetwork name', () {
      expect(service, contains('EngineClaim.URNETWORK'));
      final claim = kotlinSrc('EngineClaim.kt');
      expect(claim, contains('const val URNETWORK = "urnetwork"'));
      expect(claim, contains('UrVpnService.ACTION_STOP'));
    });

    test('MainActivity carries the ur channels and the lib check', () {
      final main = kotlinSrc('MainActivity.kt');
      expect(main, contains('"urSetOn"'));
      expect(main, contains('"urStop"'));
      expect(main, contains('"urState"'));
      expect(main, contains('"liburcore.so"'));
      expect(main, contains('pendingUrOn'));
    });

    test('no credential is journaled by the service', () {
      // The journal takes lifecycle lines only (stages and
      // location names). The pin: no line that mentions
      // the JWT may be a logging line, and the journal's
      // message strings are the expected lifecycle words.
      for (final line in service.split('\n')) {
        if (line.toLowerCase().contains('jwt')) {
          expect(line.contains('UrJournal'), isFalse, reason: line);
          expect(line.contains('Log.'), isFalse, reason: line);
          expect(line.contains('breadcrumb'), isFalse, reason: line);
        }
      }
      expect(service, contains('"start refused: no session"'));
      expect(service, contains('"tunnel up; waiting for a provider"'));
      expect(service, contains('"connected"'));
      expect(service, contains('"stopped"'));
    });
  });

  group('build 2156 — JWT cache policy', () {
    test('urJwtExpiryMs reads the exp claim', () {
      expect(urJwtExpiryMs(fixtureJwt(2000000000)), 2000000000000);
    });

    test('urJwtExpiryMs is null on anything malformed', () {
      expect(urJwtExpiryMs(''), isNull);
      expect(urJwtExpiryMs('a.b'), isNull);
      expect(urJwtExpiryMs('a.!!!.c'), isNull);
      // A well-formed JWT whose payload has no exp claim.
      String b64(Object? json) => base64Url
          .encode(utf8.encode(jsonEncode(json)))
          .replaceAll('=', '');
      final noExp = '${b64({'alg': 'none'})}.${b64({'pro': true})}.sig';
      expect(urJwtExpiryMs(noExp), isNull);
    });

    test('the cache round-trips and refuses garbage', () {
      final session = UrClientSession(
        jwt: fixtureJwt(2000000000),
        clientId: 'client-1',
        expMs: 2000000000000,
      );
      final decoded = decodeUrClientJwtCache(encodeUrClientJwtCache(session));
      expect(decoded?.jwt, session.jwt);
      expect(decoded?.clientId, 'client-1');
      expect(decoded?.expMs, 2000000000000);
      expect(decodeUrClientJwtCache(null), isNull);
      expect(decodeUrClientJwtCache(''), isNull);
      expect(decodeUrClientJwtCache('{"jwt": 42}'), isNull);
      expect(decodeUrClientJwtCache('not json'), isNull);
    });

    test('fresh means a full margin of lifetime remains', () {
      const now = 1700000000000;
      UrClientSession at(int expMs) =>
          UrClientSession(jwt: 'x', clientId: 'c', expMs: expMs);
      expect(
        urClientJwtCacheFresh(at(now + urClientJwtRefreshMarginMs + 1), now),
        isTrue,
      );
      expect(
        urClientJwtCacheFresh(at(now + urClientJwtRefreshMarginMs - 1), now),
        isFalse,
      );
      expect(urClientJwtCacheFresh(at(0), now), isFalse);
      expect(urClientJwtCacheFresh(null, now), isFalse);
    });

    test('the vault keys are per-account and beside the API key', () {
      expect(urNetworkVaultKey('u1'), 'urnetwork_api_key_u1');
      expect(urClientJwtVaultKey('u1'), 'urnetwork_client_jwt_u1');
    });
  });

  group('build 2156 — the exchange', () {
    test('exchange posts NO proxy_config and parses the session', () async {
      String? body;
      Uri? seen;
      final jwt = fixtureJwt(2000000000);
      final client = UrNetworkClient(
        apiKey: _fixtureKey,
        transport: (method, uri, {headers = const {}, jsonBody}) async {
          body = jsonBody;
          seen = uri;
          return UrHttpResponse(
            200,
            jsonEncode({'by_client_jwt': jwt, 'client_id': 'client-9'}),
          );
        },
      );
      final session = await client.exchangeClientSession();
      expect(seen.toString(), 'https://api.bringyour.com/network/auth-client');
      expect(jsonDecode(body!), isEmpty); // no proxy_config, no proxy minted
      expect(session.jwt, jwt);
      expect(session.clientId, 'client-9');
      expect(session.expMs, 2000000000000);
    });

    test('an answer without a JWT is a bad response', () async {
      final client = UrNetworkClient(
        apiKey: _fixtureKey,
        transport: (method, uri, {headers = const {}, jsonBody}) async =>
            UrHttpResponse(200, '{"client_id": "client-9"}'),
      );
      await expectLater(
        client.exchangeClientSession(),
        throwsA(
          isA<UrNetworkException>()
              .having((e) => e.kind, 'kind', UrErrorKind.badResponse),
        ),
      );
    });
  });

  group('build 2156 — session resolution (controller)', () {
    late Map<String, String> vault;
    late List<String> calls;
    late int exchanges;
    late UrEngineController controller;
    final account = UrAccount(id: 'u1x0', label: 'Main');

    UrNetworkClient fakeClient() => UrNetworkClient(
      apiKey: _fixtureKey,
      transport: (method, uri, {headers = const {}, jsonBody}) async {
        calls.add('${uri.path}');
        if (uri.path == '/network/auth-client') {
          exchanges++;
          // A 30-day token minted "now" for the cache tests.
          final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 +
              30 * 24 * 3600;
          return UrHttpResponse(
            200,
            jsonEncode({
              'by_client_jwt': fixtureJwt(exp),
              'client_id': 'client-new-$exchanges',
            }),
          );
        }
        return UrHttpResponse(200, '{}');
      },
    );

    setUp(() {
      vault = {urNetworkVaultKey(account.id): _fixtureKey};
      calls = [];
      exchanges = 0;
      controller = UrEngineController();
      controller.accountsProvider = () => [account];
      controller.clientFactory = (_) => fakeClient();
      controller.secretLoad = (k) async => vault[k];
      controller.secretStore = (k, v) async {
        vault[k] = v;
        return true;
      };
      controller.secretDelete = (k) async {
        vault.remove(k);
      };
    });

    test('a cold cache exchanges once, caches, and reuses', () async {
      final first = await controller.resolveSession(account);
      expect(exchanges, 1);
      expect(first.clientId, 'client-new-1');
      expect(vault[urClientJwtVaultKey(account.id)], isNotNull);
      final second = await controller.resolveSession(account);
      expect(exchanges, 1); // the fresh cache is reused — no new client
      expect(second.jwt, first.jwt);
    });

    test('a stale cache re-exchanges and removes the superseded client',
        () async {
      final stale = UrClientSession(
        jwt: fixtureJwt(1500000000), // long expired
        clientId: 'client-old',
        expMs: 1500000000000,
      );
      vault[urClientJwtVaultKey(account.id)] =
          encodeUrClientJwtCache(stale);
      final session = await controller.resolveSession(account);
      expect(exchanges, 1);
      expect(session.clientId, 'client-new-1');
      expect(calls, contains('/network/remove-client'));
    });

    test('a vault refusal fails the resolve instead of starting '
        'uncached', () async {
      controller.secretStore = (k, v) async => false;
      await expectLater(
        controller.resolveSession(account),
        throwsA(isA<StateError>()),
      );
    });

    test('a missing account key is the key-refused error', () async {
      vault.clear();
      await expectLater(
        controller.resolveSession(account),
        throwsA(
          isA<UrNetworkException>()
              .having((e) => e.kind, 'kind', UrErrorKind.keyRefused),
        ),
      );
    });
  });

  group('build 2156 — connect call shapes (platform)', () {
    late Directory tempDir;
    late Map<String, String> vault;
    late List<MethodCall> channelCalls;
    late Map<String, Object?> stateMap;
    late UrEngineController controller;
    final account = UrAccount(id: 'u1x0', label: 'Main');

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ember2156-');
      vault = {urNetworkVaultKey(account.id): _fixtureKey};
      channelCalls = [];
      stateMap = {'available': true, 'running': false, 'connected': false};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'),
              (call) async {
        channelCalls.add(call);
        switch (call.method) {
          case 'dataDir':
            return '${tempDir.path}/core';
          case 'urState':
            return stateMap;
          case 'urSetOn':
            stateMap = {
              'available': true,
              'running': true,
              'connected': true,
              'stage': 'up',
              'exitCountry': 'United States',
              'exitCode': 'US',
              'up': 10,
              'down': 20,
            };
            return null;
          case 'urStop':
            stateMap = {'available': true, 'running': false};
            return null;
          default:
            return null;
        }
      });
      controller = UrEngineController();
      controller.accountsProvider = () => [account];
      controller.clientFactory = (_) => UrNetworkClient(
        apiKey: _fixtureKey,
        transport: (method, uri, {headers = const {}, jsonBody}) async {
          final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 +
              30 * 24 * 3600;
          return UrHttpResponse(
            200,
            jsonEncode({
              'by_client_jwt': fixtureJwt(exp),
              'client_id': 'client-1',
            }),
          );
        },
      );
      controller.secretLoad = (k) async => vault[k];
      controller.secretStore = (k, v) async {
        vault[k] = v;
        return true;
      };
      controller.secretDelete = (k) async {
        vault.remove(k);
      };
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'), null);
      await controller.disconnect().catchError((_) {});
      controller.dispose();
      for (var i = 0; i < 10; i++) {
        try {
          await tempDir.delete(recursive: true);
          break;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });

    test('Best Available is the default connect shape', () async {
      await controller.connect();
      final setOn = channelCalls.singleWhere((c) => c.method == 'urSetOn');
      final args = setOn.arguments as Map;
      expect(args['on'], isTrue);
      expect(args['locationId'], '');
      expect((args['jwt'] as String), isNotEmpty);
      expect(controller.state.connected, isTrue);
    });

    test('a picked country rides the connect', () async {
      await controller.setLocation(
        const UrCountry(
          locationId: 'loc-de',
          name: 'Germany',
          countryCode: 'DE',
          providerCount: 12,
        ),
      );
      await controller.connect();
      final setOn = channelCalls.singleWhere((c) => c.method == 'urSetOn');
      final args = setOn.arguments as Map;
      expect(args['locationId'], 'loc-de');
      expect(args['locationName'], 'Germany');
      expect(args['locationCode'], 'DE');
    });

    test('no account words the failure and never starts', () async {
      controller.accountsProvider = () => const [];
      await controller.connect();
      expect(controller.lastError, contains('Add a URnetwork account'));
      expect(channelCalls.where((c) => c.method == 'urSetOn'), isEmpty);
    });
  });

  group('build 2156 — shell arbitration (source pins)', () {
    final shell = dartSrc('ui/ember/ember_shell.dart');

    test('mode 8 is labelled and toggled', () {
      expect(shell, contains("8 => 'URnetwork'"));
      expect(shell, contains('return _toggleUr(context);'));
      expect(shell, contains("'URnetwork',"));
      expect(shell, contains('2, 4, 7, 8]'));
    });

    test('starting UR stops the others; starting others stops UR', () {
      expect(shell, contains('_ur.stopOtherEngine = () async'));
      // _stopUr() is called from the xray hook, every other
      // engine's hook, stopXray and _disconnectMode.
      expect('await _stopUr();'.allMatches(shell).length,
          greaterThanOrEqualTo(8));
      expect(shell, contains("case 8:\n          await _stopUr();"));
    });

    test('the claim family maps the native name to mode 8', () {
      expect(shell, contains("'urnetwork': {8}"));
      expect(shell, contains("if (_engineActive(8)) return 'urnetwork';"));
    });

    test('the actors listenable names UR before the MASQUE wildcard',
        () {
      expect(shell, contains('8 => _ur,'));
    });

    test('the stored mode clamp admits 8', () {
      final settings = dartSrc('app_settings.dart');
      expect(settings, contains('v >= 0 && v <= 8 ? v : 0'));
    });
  });

  group('build 2156 — the 2154 source stands untouched', () {
    test('the source feature keeps its endpoints and vault key', () {
      final client = dartSrc('urnetwork/urnetwork_client.dart');
      expect(client, contains("https://api.bringyour.com"));
      expect(client, contains('urnetwork_api_key_'));
      expect(client, contains("'/network/proxies'"));
      // The engine's exchange is an ADDITION on the same
      // endpoint, beside createProxy — not a replacement.
      expect(client, contains('exchangeClientSession'));
      expect(client, contains('createProxy'));
    });

    test('the engine never mints hosted proxies', () {
      final controller = dartSrc('urnetwork/ur_engine_controller.dart');
      expect(controller.contains('createProxy'), isFalse);
      expect(controller, contains('exchangeClientSession'));
    });

    test('UrState parses the published snapshot defensively', () {
      final s = UrState.fromMap({
        'running': true,
        'connected': true,
        'exitCode': 'NL',
        'providers': 3,
        'up': 5,
        'down': 7,
      });
      expect(s.connected, isTrue);
      expect(s.exitCode, 'NL');
      expect(s.providers, 3);
      expect(s.countersReported, isTrue);
      expect(const UrState().connected, isFalse);
    });
  });

  group('build 2156 — version', () {
    test('pubspec carries 2156', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.2.0+2157'),
      );
    });
  });
}
