import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/l10n/app_localizations_en.dart';
import 'package:firefox_vpn/net/exit_quality.dart';
import 'package:firefox_vpn/ui/ember/ember_sync.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

/// Build 2082 — final-verification §4 remainders V-2, V-3,
/// V-6, V-7 (final-verification-2026-11-15.md §4). The last
/// four closable remainders; F-M15 (the hyPinSha256 field
/// migration), F-H15 (the .ovpn VIEW/SEND intent filter) and
/// the C-1 Go-side IpcSet test stay open for later runs, and
/// F-H11 reopens only on owner evidence of a poisoned-name
/// case the hosts pin cannot cover.

String _read(String path) => File(path).readAsStringSync();

Profile _base(Protocol protocol) => Profile(
  id: 't1',
  protocol: protocol,
  name: 'Test',
  address: '1.2.3.4',
  port: 443,
  uuidOrPassword: '11111111-1111-1111-1111-111111111111',
);

void main() {
  // This file contains a testWidgets, so the test binding
  // installs its mock HttpClient (400 for everything) over
  // the whole file — the sync tests serve REAL bytes from a
  // loopback server and need the real client (the build2075
  // precedent for the updater download tests).
  setUp(() {
    HttpOverrides.global = null;
  });

  group('V-2 one stock OutlinedButton left on an engine page', () {
    test('source: no OutlinedButton remains on the engine pages', () {
      for (final path in [
        'lib/ui/ember/aether_pages.dart',
        'lib/ui/ember/lantern_pages.dart',
        'lib/ui/ember/openvpn_pages.dart',
        'lib/ui/ember/wireguard_pages.dart',
      ]) {
        expect(_read(path), isNot(contains('OutlinedButton')), reason: path);
      }
    });

    test('source: the credentials sheet removes with a MapActionPill', () {
      final dart = _read('lib/ui/ember/openvpn_pages.dart');
      expect(dart, contains("label: 'Remove saved'"));
      expect(dart, contains('Icons.delete_outline_rounded'));
      expect(dart, contains('deleteCredentials(profile.credKey)'));
    });
  });

  group('V-3 mux toggle gives no protocol scoping', () {
    test('builder: mux is emitted only for the four mux protocols', () {
      final s = XraySettings()..muxEnabled = true;
      for (final protocol in [
        Protocol.vless,
        Protocol.vmess,
        Protocol.trojan,
        Protocol.shadowsocks,
      ]) {
        final p = _base(protocol);
        if (protocol == Protocol.shadowsocks) p.method = 'aes-256-gcm';
        final out = buildOutbound(p, s);
        expect(out, isNotNull, reason: '$protocol builds');
        expect(
          (out!['mux'] as Map?)?['enabled'],
          isTrue,
          reason: '$protocol carries mux',
        );
        expect((out['mux'] as Map)['concurrency'], 8);
      }
      // Same toggle, same settings — the protocols the core
      // cannot mux stay mux-free, so the toggle never lies.
      for (final protocol in [
        Protocol.hysteria2,
        Protocol.wireguard,
        Protocol.socks,
      ]) {
        final p = _base(protocol);
        if (protocol == Protocol.wireguard) {
          p.secretKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
          p.peerPublicKey = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=';
        }
        final out = buildOutbound(p, s);
        expect(out, isNotNull, reason: '$protocol builds');
        expect(out!.containsKey('mux'), isFalse, reason: '$protocol');
      }
    });

    test('builder: mux off means no mux block anywhere', () {
      final s = XraySettings()..muxEnabled = false;
      final out = buildOutbound(_base(Protocol.vless), s);
      expect(out, isNotNull);
      expect(out!.containsKey('mux'), isFalse);
    });

    test('subtitle: the mux row names the protocols it applies to', () {
      final sub = AppLocalizationsEn().muxSub;
      for (final name in ['VLESS', 'VMess', 'Trojan', 'Shadowsocks']) {
        expect(sub, contains(name));
      }
      expect(_read('lib/l10n/app_en.arb'), contains(sub));
    });
  });

  group('V-7 exit-IP quality has no cache', () {
    test('cache: a fresh verdict is reused for the same exit IP', () {
      var now = DateTime(2026, 11, 15, 18, 0);
      final cache = ExitQualityCache(clock: () => now);
      final q = ExitQuality(
        ip: '185.1.2.3',
        country: 'Germany',
        hosting: true,
      );
      expect(cache.lookup('185.1.2.3'), isNull);
      cache.store(q);
      expect(cache.lookup('185.1.2.3'), same(q));
      expect(cache.age('185.1.2.3'), Duration.zero);
      now = now.add(const Duration(minutes: 3));
      expect(cache.lookup('185.1.2.3'), same(q));
      expect(cache.age('185.1.2.3'), const Duration(minutes: 3));
    });

    test('cache: another exit IP, an expired verdict, clear', () {
      var now = DateTime(2026, 11, 15, 18, 0);
      final cache = ExitQualityCache(clock: () => now);
      cache.store(const ExitQuality(ip: '185.1.2.3'));
      // A server switch lands on a different exit: refetch.
      expect(cache.lookup('203.0.113.9'), isNull);
      expect(cache.age('203.0.113.9'), isNull);
      // Inside the 10-minute window it is still fresh.
      now = now.add(const Duration(minutes: 9, seconds: 59));
      expect(cache.lookup('185.1.2.3'), isNotNull);
      // At the TTL boundary it is gone.
      now = now.add(const Duration(seconds: 1));
      expect(cache.lookup('185.1.2.3'), isNull);
      expect(cache.age('185.1.2.3'), isNull);
      cache.store(const ExitQuality(ip: '185.1.2.3'));
      cache.clear();
      expect(cache.lookup('185.1.2.3'), isNull);
    });

    test('age label: words only, Latin digits', () {
      expect(qualityAgeLabel(Duration.zero), 'checked just now');
      expect(
        qualityAgeLabel(const Duration(seconds: 59)),
        'checked just now',
      );
      expect(
        qualityAgeLabel(const Duration(minutes: 3)),
        'checked 3 min ago',
      );
      expect(
        qualityAgeLabel(const Duration(minutes: 90)),
        'checked 1 h ago',
      );
      expect(
        qualityAgeLabel(const Duration(hours: 2, minutes: 30)),
        'checked 2 h ago',
      );
    });

    test('source: the Home card reads the cache and can force a refresh', () {
      final dart = _read('lib/ui/ember/ember_home.dart');
      expect(dart, contains('exitQualityCache.lookup'));
      expect(dart, contains('exitQualityCache.store'));
      expect(dart, contains('_checkQuality(force: true)'));
      expect(dart, contains('qualityAgeLabel'));
      expect(dart, contains('_fromCache'));
    });
  });

  group('V-6 no test pins syncPush/syncPull/SyncPage', () {
    late _FakeGithub fake;

    setUp(() async {
      fake = await _FakeGithub.bind();
    });

    tearDown(() async {
      await fake.close();
    });

    AppSettings settingsWithToken({String gistId = ''}) {
      final s = AppSettings();
      s.update(syncGithubToken: 'tok-1', syncGistId: gistId);
      return s;
    }

    test('push creates a gist and stores its id', () async {
      fake.routes['POST /gists'] = (201, '{"id": "gist-1"}');
      final settings = settingsWithToken();
      const backup = '{"profiles":[],"settings":{}}';
      final id = await syncPush(
        settings: settings,
        backupJson: backup,
        password: 'hunter2',
        apiBase: fake.base,
      );
      expect(id, 'gist-1');
      expect(settings.syncGistId, 'gist-1');
      expect(settings.syncLastMs, greaterThan(0));
      expect(fake.requests, hasLength(1));
      final req = fake.requests.single;
      expect(req['method'], 'POST');
      expect(req['path'], '/gists');
      expect(req['auth'], 'Bearer tok-1');
      final body = jsonDecode(req['body'] as String) as Map<String, dynamic>;
      expect(body['description'], contains('Ralysnd Ember'));
      expect(body['public'], isFalse);
      final content =
          (body['files'] as Map)['ember-backup.json']['content'] as String;
      expect(content, contains('ralysnd-ember-sync'));
      expect(content, isNot(contains('profiles')));
      expect(unsealBackup(content, 'hunter2'), backup);
    });

    test('push updates the existing gist', () async {
      fake.routes['PATCH /gists/gist-1'] = (200, '{"id": "gist-1"}');
      final settings = settingsWithToken(gistId: 'gist-1');
      final id = await syncPush(
        settings: settings,
        backupJson: '{"profiles":[]}',
        password: 'hunter2',
        apiBase: fake.base,
      );
      expect(id, 'gist-1');
      expect(fake.requests.single['method'], 'PATCH');
      expect(fake.requests.single['path'], '/gists/gist-1');
    });

    test('push without a token fails before any request', () async {
      final settings = AppSettings();
      await expectLater(
        syncPush(
          settings: settings,
          backupJson: '{}',
          password: 'hunter2',
          apiBase: fake.base,
        ),
        throwsA(
          isA<SyncException>().having(
            (e) => e.message,
            'message',
            contains('Paste a GitHub token first.'),
          ),
        ),
      );
      expect(fake.requests, isEmpty);
    });

    test('push maps a rejected token to its message', () async {
      fake.routes['POST /gists'] = (401, '{}');
      final settings = settingsWithToken();
      await expectLater(
        syncPush(
          settings: settings,
          backupJson: '{}',
          password: 'hunter2',
          apiBase: fake.base,
        ),
        throwsA(
          isA<SyncException>().having(
            (e) => e.message,
            'message',
            contains('GitHub rejected the token'),
          ),
        ),
      );
    });

    test('pull returns the unsealed backup', () async {
      const backup = '{"profiles":[{"name":"one"}],"settings":{}}';
      final sealed = sealBackup(backup, 'hunter2');
      fake.routes['GET /gists/gist-1'] = (
        200,
        jsonEncode({
          'files': {
            'ember-backup.json': {'content': sealed},
          },
        }),
      );
      final settings = settingsWithToken(gistId: 'gist-1');
      final before = settings.syncLastMs;
      final out = await syncPull(
        settings: settings,
        password: 'hunter2',
        apiBase: fake.base,
      );
      expect(out, backup);
      expect(settings.syncLastMs, greaterThanOrEqualTo(before));
      expect(fake.requests.single['path'], '/gists/gist-1');
    });

    test('pull without a gist id fails before any request', () async {
      final settings = settingsWithToken();
      await expectLater(
        syncPull(
          settings: settings,
          password: 'hunter2',
          apiBase: fake.base,
        ),
        throwsA(
          isA<SyncException>().having(
            (e) => e.message,
            'message',
            contains('No sync gist is set'),
          ),
        ),
      );
      expect(fake.requests, isEmpty);
    });

    test('pull with the wrong password names the password', () async {
      final sealed = sealBackup('{"profiles":[]}', 'hunter2');
      fake.routes['GET /gists/gist-1'] = (
        200,
        jsonEncode({
          'files': {
            'ember-backup.json': {'content': sealed},
          },
        }),
      );
      final settings = settingsWithToken(gistId: 'gist-1');
      await expectLater(
        syncPull(
          settings: settings,
          password: 'wrong',
          apiBase: fake.base,
        ),
        throwsA(
          isA<SyncException>().having(
            (e) => e.message,
            'message',
            contains('password is wrong'),
          ),
        ),
      );
    });

    test('pull maps a missing gist to its message', () async {
      fake.routes['GET /gists/gist-1'] = (404, '{}');
      final settings = settingsWithToken(gistId: 'gist-1');
      await expectLater(
        syncPull(
          settings: settings,
          password: 'hunter2',
          apiBase: fake.base,
        ),
        throwsA(
          isA<SyncException>().having(
            (e) => e.message,
            'message',
            contains('not found'),
          ),
        ),
      );
    });

    testWidgets('SyncPage renders its token, gist and password fields', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SyncPage(settings: AppSettings(), xray: XrayController()),
        ),
      );
      await tester.pump();
      expect(find.text('Sync via GitHub'), findsOneWidget);
      expect(find.text('GitHub token (gist scope)'), findsOneWidget);
      expect(find.text('Gist id (set by the first push)'), findsOneWidget);
      expect(find.text('Sync password'), findsOneWidget);
      expect(find.text('Push to GitHub'), findsOneWidget);
      expect(find.text('Pull from GitHub'), findsOneWidget);
    });
  });
}

/// A GitHub API on loopback: [routes] maps "METHOD /path" to
/// a status and a body; every request is recorded with its
/// method, path, body and Authorization header, so the tests
/// can assert what the sync transport actually sent.
class _FakeGithub {
  _FakeGithub(this.server);

  final HttpServer server;
  final List<Map<String, String>> requests = [];
  final Map<String, (int, String)> routes = {};

  static Future<_FakeGithub> bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeGithub(server);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      fake.requests.add({
        'method': req.method,
        'path': req.uri.path,
        'body': body,
        'auth': req.headers.value('authorization') ?? '',
      });
      final (status, payload) =
          fake.routes['${req.method} ${req.uri.path}'] ?? (404, '');
      req.response.statusCode = status;
      if (payload.isNotEmpty) req.response.write(payload);
      await req.response.close();
    });
    return fake;
  }

  Uri get base => Uri.parse('http://127.0.0.1:${server.port}');

  Future<void> close() => server.close(force: true);
}
