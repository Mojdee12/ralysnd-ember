// Build 2139 — three legs (scope: build2139-progress.md):
//
//  LEG 1 — RegionHop inside Ember: the settings fields
//  (DEFAULT OFF), the panel client (manual cookie login,
//  never auto-retried; capitalized status keys), the
//  credentials-block parser with its port cross-check,
//  the managed SOCKS profile through the existing
//  outbound builder, the page's row states, and OFF
//  parity (populated-but-off settings change no
//  generated outbound; the connect machinery and the
//  config builder carry no RegionHop references at all).
//
//  LEG 2 — the OLCRTC client patch: the vendored tree's
//  Android interface loader degrades instead of dying
//  when the netlink route dump is denied, and the
//  staged libolcrtc.so carries the patch.
//
//  LEG 3 — the A34-02 re-fix: isLiteralServerHost covers
//  the address forms the 2135 bare parse missed (the
//  once-per-episode set guard itself is pinned in
//  build2135_test.dart, updated for the new mechanism).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/regionhop/regionhop_client.dart';
import 'package:firefox_vpn/ui/ember/regionhop_page.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/provider_dns.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String _src(String rel) => File('lib/$rel').readAsStringSync();

const _statusPayload = '''
[
  {"Name":"de","Region":"DE - Germany","SocksPort":19000,
   "Status":"active","StatusClass":"active",
   "ExitIP":"","ExitRegion":"DE - Germany","ExitFlagURL":""},
  {"Name":"nl","Region":"NL - Netherlands","SocksPort":19001,
   "Status":"inactive","StatusClass":"inactive",
   "ExitIP":"","ExitRegion":"","ExitFlagURL":""},
  {"Name":"us","Region":"US - United States","SocksPort":19002,
   "Status":"failed","StatusClass":"inactive",
   "ExitIP":"","ExitRegion":"","ExitFlagURL":""}
]
''';

/// A fake regionhop panel on loopback: prefix /p, one
/// password ('right'), cookie-gated status, and an
/// optional one-shot session expiry on the first status
/// call.
class _FakePanel {
  HttpServer? _server;
  int loginPosts = 0;
  int statusGets = 0;
  bool expireFirstStatus = false;
  String statusBody = _statusPayload;

  String get base => 'http://127.0.0.1:${_server!.port}/p';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> stop() async => _server?.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    if (path == '/p/login' && req.method == 'GET') {
      res.statusCode = 200;
      res.write('<html><body>login</body></html>');
    } else if (path == '/p/login' && req.method == 'POST') {
      loginPosts++;
      final body = await utf8.decoder.bind(req).join();
      if (body.contains('password=right')) {
        res.statusCode = 303;
        res.headers.set('location', '/p/');
        res.headers.set('set-cookie', 'psi_session=tok.en; Path=/; HttpOnly');
      } else {
        res.statusCode = 200;
        res.write('<html><body>login</body></html>');
      }
    } else if (path == '/p/tunnels-status') {
      statusGets++;
      final cookie = req.headers.value('cookie') ?? '';
      if (!cookie.contains('psi_session=') ||
          (expireFirstStatus && statusGets == 1)) {
        res.statusCode = 303;
        res.headers.set('location', '/p/login');
      } else {
        res.statusCode = 200;
        res.headers.contentType = ContentType.json;
        res.write(statusBody);
      }
    } else {
      res.statusCode = 404;
    }
    await res.close();
  }
}

void main() {
  // This file contains testWidgets, so the test binding
  // installs its mock HttpClient (400 for everything) —
  // the fake-panel group below serves REAL responses
  // from a loopback server and nulls the mock in its own
  // setUp (the build2075 precedent). The widget group
  // keeps the mock: since build 2141 (leg 2) the page
  // opens pre-filled from the built-in defaults and
  // silently attempts a login, and a widget test must
  // never make that attempt against a real network.

  group('LEG 1 — RegionHop settings codec', () {
    test('defaults are OFF and empty', () {
      final s = XraySettings();
      expect(s.regionHopEnabled, isFalse);
      expect(s.regionHopPanelUrl, '');
      expect(s.regionHopPanelPassword, '');
      expect(s.regionHopRelays, '');
    });

    test('the fields round-trip', () {
      final s = XraySettings()
        ..regionHopEnabled = true
        ..regionHopPanelUrl = 'http://panel.example/abc'
        ..regionHopPanelPassword = 'pw'
        ..regionHopRelays = 'de 26000 rh-de secret';
      final back = XraySettings.fromJson(s.toJson());
      expect(back.regionHopEnabled, isTrue);
      expect(back.regionHopPanelUrl, 'http://panel.example/abc');
      expect(back.regionHopPanelPassword, 'pw');
      expect(back.regionHopRelays, 'de 26000 rh-de secret');
    });

    test('a 2138-shaped store (no RegionHop keys) loads the defaults', () {
      final legacy = XraySettings().toJson()
        ..remove('regionHopEnabled')
        ..remove('regionHopPanelUrl')
        ..remove('regionHopPanelPassword')
        ..remove('regionHopRelays');
      final back = XraySettings.fromJson(legacy);
      expect(back.regionHopEnabled, isFalse);
      expect(back.regionHopPanelUrl, '');
      expect(back.regionHopPanelPassword, '');
      expect(back.regionHopRelays, '');
    });
  });

  group('LEG 1 — RegionHop parsers', () {
    test('status parses the CAPITALIZED keys, systemd states verbatim', () {
      final rows = parseRegionHopStatus(_statusPayload);
      expect(rows, hasLength(3));
      expect(rows[0].name, 'de');
      expect(rows[0].region, 'DE - Germany');
      expect(rows[0].socksPort, 19000);
      expect(rows[0].status, 'active');
      expect(rows[0].isActive, isTrue);
      expect(rows[0].exitRegion, 'DE - Germany');
      expect(rows[0].exitCode, 'DE');
      expect(rows[1].status, 'inactive');
      expect(rows[2].status, 'failed');
    });

    test('chip labels map the panel classes', () {
      expect(regionHopChipLabel('active', 'active'), 'Active');
      expect(regionHopChipLabel('connecting', 'connecting'), 'Connecting');
      expect(regionHopChipLabel('activating', 'connecting'), 'Connecting');
      expect(regionHopChipLabel('inactive', 'inactive'), 'Stopped');
      expect(regionHopChipLabel('failed', 'inactive'), 'Failed');
      expect(regionHopChipLabel('unknown', 'unknown'), 'Unknown');
    });

    test('probe parses the lowercase keys', () {
      final probe = parseRegionHopProbe(
        '{"ok":true,"latencyMs":812,"ip":"203.0.113.7",'
        '"google":"ok","detail":""}',
      );
      expect(probe.ok, isTrue);
      expect(probe.latencyMs, 812);
      expect(probe.ip, '203.0.113.7');
    });

    test('the credentials block: blanks skipped, bad lines named', () {
      final block = parseRegionHopRelays(
        'de 26000 rh-de pw1\n'
        '\n'
        'nl 26001 rh-nl\n'
        'us notaport rh-us pw3\n'
        'zz 26003 rh-zz pw4 extra\n',
      );
      expect(block.relays.keys, ['de']);
      expect(block.relays['de']!.port, 26000);
      expect(block.relays['de']!.user, 'rh-de');
      expect(block.relays['de']!.password, 'pw1');
      expect(block.errors, hasLength(3));
      expect(block.errors[0], contains('Line 3'));
      expect(block.errors[1], contains('Line 4'));
      expect(block.errors[2], contains('Line 5'));
    });

    test('connect block: ok, no-creds, mismatch, connecting, stopped, failed',
        () {
      const active = RegionHopLocation(
        name: 'de',
        region: 'DE - Germany',
        socksPort: 19000,
        status: 'active',
        statusClass: 'active',
        exitRegion: 'DE - Germany',
      );
      const relay = RegionHopRelay(
        name: 'de',
        port: 26000,
        user: 'rh-de',
        password: 'pw',
      );
      expect(regionHopRelayPortFor(19000), 26000);
      expect(regionHopConnectBlock(active, relay), isNull);
      expect(
        regionHopConnectBlock(active, null),
        contains('Bridge not set up'),
      );
      expect(
        regionHopConnectBlock(
          active,
          const RegionHopRelay(
            name: 'de',
            port: 26009,
            user: 'rh-de',
            password: 'pw',
          ),
        ),
        contains("don't match the panel's port"),
      );
      const connecting = RegionHopLocation(
        name: 'de',
        region: 'DE - Germany',
        socksPort: 19000,
        status: 'activating',
        statusClass: 'connecting',
        exitRegion: '',
      );
      expect(
        regionHopConnectBlock(connecting, relay),
        'Tunnel is still connecting…',
      );
      const stopped = RegionHopLocation(
        name: 'de',
        region: 'DE - Germany',
        socksPort: 19000,
        status: 'inactive',
        statusClass: 'inactive',
        exitRegion: '',
      );
      expect(
        regionHopConnectBlock(stopped, relay),
        'Tunnel is stopped — Start it first.',
      );
      const failed = RegionHopLocation(
        name: 'de',
        region: 'DE - Germany',
        socksPort: 19000,
        status: 'failed',
        statusClass: 'inactive',
        exitRegion: '',
      );
      expect(
        regionHopConnectBlock(failed, relay),
        'Tunnel failed — Start it to try again.',
      );
    });
  });

  group('LEG 1 — RegionHop client against a fake panel', () {
    late _FakePanel panel;
    HttpOverrides? savedOverrides;

    setUp(() async {
      // Null the binding's mock for this group's real
      // loopback traffic — and RESTORE it in tearDown:
      // the value is process-global, and since build
      // 2141 (leg 2) the widget group below depends on
      // the mock being back (its page silently attempts
      // a login on open and must never reach a network).
      savedOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      panel = _FakePanel();
      await panel.start();
    });
    tearDown(() async {
      await panel.stop();
      HttpOverrides.global = savedOverrides;
    });

    test('login captures the cookie off the 303', () async {
      final client = RegionHopClient(panelUrl: panel.base, password: 'right');
      await client.login();
      expect(client.loggedIn, isTrue);
      expect(panel.loginPosts, 1);
    });

    test('a wrong password fails by the missing cookie, exactly one attempt',
        () async {
      final client = RegionHopClient(panelUrl: panel.base, password: 'nope');
      await expectLater(
        client.login(),
        throwsA(
          isA<RegionHopException>().having(
            (e) => e.kind,
            'kind',
            RegionHopErrorKind.loginFailed,
          ),
        ),
      );
      expect(client.loggedIn, isFalse);
      // The panel locks out after 5 failures per IP — the
      // client must never retry a login on its own.
      expect(panel.loginPosts, 1);
    });

    test('a wrong prefix is the not-found state', () async {
      final client = RegionHopClient(
        panelUrl: 'http://127.0.0.1:${Uri.parse(panel.base).port}/wrong',
        password: 'right',
      );
      await expectLater(
        client.login(),
        throwsA(
          isA<RegionHopException>().having(
            (e) => e.kind,
            'kind',
            RegionHopErrorKind.notFound,
          ),
        ),
      );
    });

    test('fetchStatus returns the parsed rows', () async {
      final client = RegionHopClient(panelUrl: panel.base, password: 'right');
      final rows = await client.fetchStatus();
      expect(rows, hasLength(3));
      expect(rows.first.name, 'de');
      expect(rows.first.isActive, isTrue);
    });

    test('an expired session re-logins exactly once and retries once',
        () async {
      panel.expireFirstStatus = true;
      final client = RegionHopClient(panelUrl: panel.base, password: 'right');
      final rows = await client.fetchStatus();
      expect(rows, hasLength(3));
      expect(panel.loginPosts, 2); // the first login + one re-login
      expect(panel.statusGets, 2); // the expired call + one retry
    });

    test('an unreachable panel is its own state', () async {
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close();
      final client = RegionHopClient(
        panelUrl: 'http://127.0.0.1:$port/p',
        password: 'right',
      );
      await expectLater(
        client.login(),
        throwsA(
          isA<RegionHopException>().having(
            (e) => e.kind,
            'kind',
            RegionHopErrorKind.unreachable,
          ),
        ),
      );
    });
  });

  group('LEG 1 — managed profile and OFF parity', () {
    test('the managed profile is an ordinary SOCKS profile', () {
      const location = RegionHopLocation(
        name: 'de',
        region: 'DE - Germany',
        socksPort: 19000,
        status: 'active',
        statusClass: 'active',
        exitRegion: 'DE - Germany',
      );
      const relay = RegionHopRelay(
        name: 'de',
        port: 26000,
        user: 'rh-de',
        password: 'pw',
      );
      final profile = regionHopManagedProfile(
        location: location,
        relay: relay,
        host: 'panel.example',
      );
      expect(profile.id, 'regionhop-de');
      expect(profile.name, 'RegionHop · DE - Germany');
      expect(profile.protocol, Protocol.socks);
      expect(profile.address, 'panel.example');
      expect(profile.port, 26000);
      expect(profile.username, 'rh-de');
      expect(profile.uuidOrPassword, 'pw');
    });

    test('the managed profile builds a socks outbound with its users', () {
      const location = RegionHopLocation(
        name: 'nl',
        region: 'NL - Netherlands',
        socksPort: 19001,
        status: 'active',
        statusClass: 'active',
        exitRegion: 'NL - Netherlands',
      );
      const relay = RegionHopRelay(
        name: 'nl',
        port: 26001,
        user: 'rh-nl',
        password: 'pw2',
      );
      final profile = regionHopManagedProfile(
        location: location,
        relay: relay,
        host: 'panel.example',
      );
      final out = buildOutbound(profile, XraySettings());
      expect(out, isNotNull);
      expect(out!['protocol'], 'socks');
      final servers = (out['settings'] as Map)['servers'] as List;
      final server = servers.single as Map;
      expect(server['address'], 'panel.example');
      expect(server['port'], 26001);
      final users = server['users'] as List;
      expect((users.single as Map)['user'], 'rh-nl');
      expect((users.single as Map)['pass'], 'pw2');
    });

    test('populated RegionHop fields change no generated outbound', () {
      final vless = Profile(
        id: 'v1',
        name: 'v',
        protocol: Protocol.vless,
        address: 'example.com',
        port: 443,
        uuidOrPassword: '00000000-0000-0000-0000-000000000000',
        security: 'reality',
        sni: 'example.com',
        publicKey: 'pk',
      );
      final plain = jsonEncode(buildOutbound(vless, XraySettings()));
      final populated = jsonEncode(
        buildOutbound(
          vless,
          XraySettings()
            ..regionHopEnabled = true
            ..regionHopPanelUrl = 'http://panel.example/abc'
            ..regionHopPanelPassword = 'pw'
            ..regionHopRelays = 'de 26000 rh-de secret',
        ),
      );
      expect(populated, plain);
    });

    test('leg 1 touched neither the connect machinery nor the builder', () {
      expect(_src('xray/xray_controller.dart').contains('regionHop'), isFalse);
      expect(_src('xray/config_builder.dart').contains('regionHop'), isFalse);
    });

    test('the settings entry is gated on the switch', () {
      final settings = _src('ui/ember/ember_settings.dart');
      expect(settings, contains('RegionHop (server Psiphon exits)'));
      expect(settings, contains('if (s.regionHopEnabled)'));
    });

    test('the nine error states exist with their fixed wording', () {
      final client = _src('regionhop/regionhop_client.dart');
      final page = _src('ui/ember/regionhop_page.dart');
      expect(client, contains('Panel unreachable — check the server'));
      expect(client, contains('Panel not found at this address'));
      expect(client, contains('Panel login failed — check the password.'));
      expect(client, contains('the panel locks for 5 minutes'));
      expect(client, contains('Bridge not set up for this location'));
      expect(client, contains("don't match the panel's port"));
      expect(client, contains('Tunnel is still connecting…'));
      expect(client, contains('Tunnel is stopped — Start it first.'));
      expect(page, contains('The tunnel is up but the relay did not answer'));
    });
  });

  // The widget tests cover RENDERING only. The page's
  // network flow is pinned by the fake-panel client group
  // above (plain tests, real loopback server): inside
  // testWidgets, real-socket IO races the binding's fake
  // clock (the client's own timeouts are fake-zone timers
  // there), which made live-flow widget tests flaky in
  // both directions during this build's development —
  // the codebase's widget-layer precedent (build2121)
  // likewise fakes the network at this layer. The tile
  // is a stateless widget precisely so its states render
  // deterministically here.
  group('LEG 1 — RegionHop page (widget)', () {
    testWidgets('the setup state renders the form and parse errors', (
      tester,
    ) async {
      final xray = XrayController();
      await tester.pumpWidget(MaterialApp(home: RegionHopPage(xray: xray)));
      await tester.pump();
      // Build 2141 (leg 2): the page opens pre-filled
      // from the built-in defaults and silently attempts
      // a login — against the binding's mock HttpClient
      // here, which answers 400, so the attempt settles
      // as the not-found state and the form (with its
      // Connect button back from the busy spinner) is
      // what this test asserts. Pump until the attempt
      // has settled (bounded): the mock's completion is
      // async and a loaded test host needs more than a
      // fixed number of frames.
      for (
        var i = 0;
        i < 40 && find.text('Connect to panel').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Panel URL'), findsOneWidget);
      // The password field's label doubles as its hint
      // (the emberField idiom), so it renders twice.
      expect(find.text('Panel password'), findsWidgets);
      expect(find.text('Bridge credentials'), findsOneWidget);
      expect(find.text('Connect to panel'), findsOneWidget);
      expect(find.textContaining('Nothing here contacts the panel'), findsOneWidget);
      // A malformed credentials line is reported in place.
      await tester.enterText(find.byType(TextField).at(2), 'bogus line');
      await tester.pump();
      expect(
        find.textContaining('Line 1: expected "name port user password".'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tiles render states, exits, reasons and the relay hint', (
      tester,
    ) async {
      const de = RegionHopLocation(
        name: 'de',
        region: 'DE - Germany',
        socksPort: 19000,
        status: 'active',
        statusClass: 'active',
        exitRegion: 'DE - Germany',
      );
      const nl = RegionHopLocation(
        name: 'nl',
        region: 'NL - Netherlands',
        socksPort: 19001,
        status: 'inactive',
        statusClass: 'inactive',
        exitRegion: '',
      );
      const us = RegionHopLocation(
        name: 'us',
        region: 'US - United States',
        socksPort: 19002,
        status: 'active',
        statusClass: 'active',
        exitRegion: 'US - United States',
      );
      const fr = RegionHopLocation(
        name: 'fr',
        region: 'FR - France',
        socksPort: 19003,
        status: 'active',
        statusClass: 'active',
        exitRegion: 'FR - France',
      );
      RegionHopLocationTile tile(
        RegionHopLocation location,
        RegionHopRelay? relay, {
        RegionHopProbe? probe,
        bool sessionHere = false,
        bool sessionVerified = true,
      }) => RegionHopLocationTile(
        location: location,
        relay: relay,
        probe: probe,
        sessionHere: sessionHere,
        sessionVerified: sessionVerified,
        stale: false,
        connectBusy: false,
        probing: false,
        acting: false,
        onCheck: () {},
        onStart: () {},
        onStop: () {},
        onConnect: () {},
        onDisconnect: () {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                tile(
                  de,
                  const RegionHopRelay(
                    name: 'de',
                    port: 26000,
                    user: 'rh-de',
                    password: 'pw',
                  ),
                  probe: const RegionHopProbe(
                    ok: true,
                    latencyMs: 812,
                    ip: '203.0.113.7',
                    google: 'ok',
                    detail: '',
                  ),
                ),
                tile(
                  nl,
                  const RegionHopRelay(
                    name: 'nl',
                    port: 26001,
                    user: 'rh-nl',
                    password: 'pw',
                  ),
                ),
                tile(us, null),
                tile(
                  fr,
                  const RegionHopRelay(
                    name: 'fr',
                    port: 26003,
                    user: 'rh-fr',
                    password: 'pw',
                  ),
                  sessionHere: true,
                  sessionVerified: false,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      // FINDER UPDATED by build 2145 (composition rebuild):
      // the tile now renders the sample's split form — the
      // country code as giant letters and the country name
      // as its own line — instead of one 'DE - Germany'
      // text. Same fixture data, same tile.
      expect(find.text('DE'), findsOneWidget);
      expect(find.text('Germany'), findsOneWidget);
      expect(find.text('Active'), findsWidgets);
      expect(find.text('Stopped'), findsOneWidget);
      expect(
        find.text('Exit DE - Germany · 203.0.113.7 · 812 ms'),
        findsOneWidget,
      );
      expect(find.text('Tunnel is stopped — Start it first.'), findsOneWidget);
      expect(
        find.textContaining('Bridge not set up for this location'),
        findsOneWidget,
      );
      expect(
        find.textContaining('The tunnel is up but the relay did not answer'),
        findsOneWidget,
      );
      expect(find.text('Disconnect'), findsOneWidget);
      // Connect is enabled only on the healthy row.
      // FINDER UPDATED by build 2144 (reskin): Connect is
      // the editorial pill (an InkWell) now, not a
      // TextButton; the gate semantics are the same —
      // onTap null exactly on the blocked rows.
      final connects = tester
          .widgetList<InkWell>(find.widgetWithText(InkWell, 'Connect'))
          .toList();
      expect(connects, hasLength(3));
      expect(connects[0].onTap, isNotNull);
      expect(connects[1].onTap, isNull);
      expect(connects[2].onTap, isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('LEG 3 — isLiteralServerHost', () {
    test('bare and host:port literal forms are literal', () {
      expect(isLiteralServerHost('194.36.55.96'), isTrue);
      expect(isLiteralServerHost('194.36.55.96:443'), isTrue);
      expect(isLiteralServerHost('2001:db8::1'), isTrue);
      expect(isLiteralServerHost('[2001:db8::1]'), isTrue);
      expect(isLiteralServerHost('[2001:db8::1]:443'), isTrue);
      expect(isLiteralServerHost('127.0.0.1:1080'), isTrue);
    });

    test('hostnames are not literal, with or without a port', () {
      expect(isLiteralServerHost('free.fugui.lol'), isFalse);
      expect(isLiteralServerHost('example.com:443'), isFalse);
      expect(isLiteralServerHost(''), isFalse);
      expect(isLiteralServerHost('example.com:https'), isFalse);
    });
  });

  group('LEG 2 — the vendored OLCRTC patch', () {
    test('the Android loader degrades instead of erroring', () {
      final file = File(
        '../../engines/olcrtc/src/internal/protect/'
        'pionnet_android_nocgo.go',
      );
      expect(file.existsSync(), isTrue);
      final source = file.readAsStringSync();
      expect(source, contains('loadInterfacesNetlink'));
      expect(source, contains('fallbackInterfaces'));
      expect(source, contains('olcrtc-fallback'));
    });

    test('the staged libolcrtc.so carries the patch', () {
      final so = File(
        'android/app/src/main/jniLibs/arm64-v8a/libolcrtc.so',
      );
      expect(so.existsSync(), isTrue);
      final text = latin1.decode(so.readAsBytesSync());
      expect(text, contains('olcrtc-fallback'));
    });
  });
}
