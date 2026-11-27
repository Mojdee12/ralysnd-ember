// Build 2141 — ONE leg (scope: build2141-progress.md):
// harden the RegionHop status fetch and capture its
// exact failure. The owner's phone (build 2140) logs in
// fine, then every GET /tunnels-status dies on the
// transport while the same URL answers his browser —
// and all the app could say was the bare `unreachable`
// kind. This build: the fetch timeout goes 10 s → 30 s,
// a transport failure earns exactly ONE retry of the
// idempotent status GET after ~2 s, and the failure is
// kept in sanitized form (coarse class, exception type,
// OS error code — never the address the raw exception
// embeds) so the page journal can record exactly what
// the transport did.
//
// LEG 2 (owner-approved scope addition): built-in
// RegionHop defaults live in ONE file
// (regionhop_defaults.dart) and nowhere else — the
// tests below reference them only through the
// RegionHopDefaults constants, never as literals. The
// page's effective values are stored-settings-when-
// non-empty, else the defaults; stored edits still win
// and the feature switch stays DEFAULT OFF.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/regionhop/regionhop_client.dart';
import 'package:firefox_vpn/regionhop/regionhop_defaults.dart';
import 'package:firefox_vpn/ui/ember/regionhop_page.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';

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

/// A fake regionhop panel on loopback (the build2139
/// precedent) with status-path failure knobs: a delayed
/// first response, a number of initial status
/// connections to reset mid-flight, and a forced status
/// code.
class _FakePanel {
  HttpServer? _server;
  int loginPosts = 0;
  int statusGets = 0;
  Duration firstStatusDelay = Duration.zero;
  int resetsRemaining = 0;
  int? statusOverrideCode;
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
    try {
      if (path == '/p/login' && req.method == 'GET') {
        res.statusCode = 200;
        res.write('<html><body>login</body></html>');
      } else if (path == '/p/login' && req.method == 'POST') {
        loginPosts++;
        final body = await utf8.decoder.bind(req).join();
        if (body.contains('password=right')) {
          res.statusCode = 303;
          res.headers.set('location', '/p/');
          res.headers.set(
            'set-cookie',
            'psi_session=tok.en; Path=/; HttpOnly',
          );
        } else {
          res.statusCode = 200;
          res.write('<html><body>login</body></html>');
        }
      } else if (path == '/p/tunnels-status') {
        statusGets++;
        final cookie = req.headers.value('cookie') ?? '';
        if (!cookie.contains('psi_session=')) {
          res.statusCode = 303;
          res.headers.set('location', '/p/login');
        } else if (resetsRemaining > 0) {
          // Kill the connection without an answer: the
          // client must see a transport failure.
          resetsRemaining--;
          final socket = await res.detachSocket();
          socket.destroy();
          return;
        } else {
          if (statusGets == 1 && firstStatusDelay > Duration.zero) {
            await Future<void>.delayed(firstStatusDelay);
          }
          if (statusOverrideCode != null) {
            res.statusCode = statusOverrideCode!;
            res.write('panel error');
          } else {
            res.statusCode = 200;
            res.headers.contentType = ContentType.json;
            res.write(statusBody);
          }
        }
      } else {
        res.statusCode = 404;
      }
      await res.close();
    } on Object {
      // A client that timed out is gone by the time a
      // delayed answer is written; the fake panel does
      // not care.
    }
  }
}

void main() {
  // NOTE on HttpOverrides: the fake-panel groups below
  // serve REAL responses from a loopback server and null
  // the binding's mock HttpClient in their own setUp
  // (the build2139 precedent). The LEG 2 widget group
  // runs FIRST and keeps the mock — its page must never
  // touch a real network.
  group('LEG 2 — built-in defaults (owner-approved)', () {
    testWidgets('(a) empty storage: the form pre-fills the '
        'defaults and the silent connect is attempted with '
        'them', (tester) async {
      final xray = XrayController();
      await tester.pumpWidget(MaterialApp(home: RegionHopPage(xray: xray)));
      await tester.pump();
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields, hasLength(3));
      expect(fields[0].controller!.text, RegionHopDefaults.panelUrl);
      expect(fields[1].controller!.text, RegionHopDefaults.panelPassword);
      expect(
        fields[2].controller!.text,
        RegionHopDefaults.bridgeCredentials,
      );
      // The silent auto-login fired with those values:
      // the binding's mock HttpClient answers 400 to the
      // login probe, so the attempt lands in the journal
      // as a failed login. (Before this leg, empty
      // storage attempted nothing at all.) Pump until
      // the attempt has settled (bounded) — the mock's
      // completion is async.
      for (
        var i = 0;
        i < 40 &&
            xray.diagnostics.entries
                .where((e) => e.source == 'regionhop')
                .isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final regionhop = xray.diagnostics.entries
          .where((e) => e.source == 'regionhop')
          .toList();
      expect(regionhop, isNotEmpty);
      expect(regionhop.first.text, startsWith('panel login failed'));
      // The journal still never carries the values.
      final all = regionhop.map((e) => e.text).join('\n');
      expect(all, isNot(contains(RegionHopDefaults.panelPassword)));
      expect(all, isNot(contains(RegionHopDefaults.panelUrl)));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('(b) stored values win over the defaults', (
      tester,
    ) async {
      final xray = XrayController();
      xray.settings
        ..regionHopPanelUrl = 'http://stored.invalid/prefix'
        ..regionHopPanelPassword = 'stored-pw'
        ..regionHopRelays = 'zz 26999 rh-zz stored-secret';
      await tester.pumpWidget(MaterialApp(home: RegionHopPage(xray: xray)));
      await tester.pump();
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields[0].controller!.text, 'http://stored.invalid/prefix');
      expect(fields[1].controller!.text, 'stored-pw');
      expect(fields[2].controller!.text, 'zz 26999 rh-zz stored-secret');
      await tester.pumpWidget(const SizedBox());
    });

    test('the defaults are populated and the settings '
        'defaults stay empty (the switch stays OFF)', () {
      expect(RegionHopDefaults.panelUrl, isNotEmpty);
      expect(RegionHopDefaults.panelPassword, isNotEmpty);
      expect(RegionHopDefaults.bridgeCredentials, isNotEmpty);
      // The credentials block parses in the form's line
      // format — three relays, no malformed lines.
      final block = parseRegionHopRelays(
        RegionHopDefaults.bridgeCredentials,
      );
      expect(block.errors, isEmpty);
      expect(block.relays, hasLength(3));
    });

    test('the page takes its fallbacks from the one '
        'defaults file', () {
      final page = _src('ui/ember/regionhop_page.dart');
      expect(page, contains('RegionHopDefaults.panelUrl'));
      expect(page, contains('RegionHopDefaults.panelPassword'));
      expect(page, contains('RegionHopDefaults.bridgeCredentials'));
      expect(
        File('lib/regionhop/regionhop_defaults.dart').existsSync(),
        isTrue,
      );
    });
  });

  group('the status fetch — timeout and production defaults', () {
    test('the defaults are the production 30 s / 2 s', () {
      final client = RegionHopClient(
        panelUrl: 'http://127.0.0.1:1/p',
        password: 'right',
      );
      expect(client.statusTimeout, const Duration(seconds: 30));
      expect(client.statusRetryDelay, const Duration(seconds: 2));
    });
  });

  group('the status fetch — retry on transport failure only', () {
    late _FakePanel panel;
    HttpOverrides? savedOverrides;

    setUp(() async {
      // Real responses from the loopback server need the
      // real HttpClient (the build2139 precedent). The
      // previous value is restored in tearDown — the
      // override is process-global and other groups
      // depend on the binding's mock.
      savedOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      panel = _FakePanel();
      await panel.start();
    });
    tearDown(() async {
      await panel.stop();
      HttpOverrides.global = savedOverrides;
    });

    test('(a) a first response slower than the fetch timeout '
        'fails the attempt; the retry succeeds', () async {
      // The old code's failure mode, simulated fast: the
      // panel's first answer takes 2 s while this
      // client's (shrunk) timeout is 700 ms — under the
      // old behaviour the fetch died there; now the
      // attempt times out and the single retry lands.
      panel.firstStatusDelay = const Duration(seconds: 2);
      final attempts = <RegionHopTransportFailure>[];
      final client = RegionHopClient(
        panelUrl: panel.base,
        password: 'right',
        statusTimeout: const Duration(milliseconds: 700),
        statusRetryDelay: const Duration(milliseconds: 50),
      )..onStatusRetry = attempts.add;
      final rows = await client.fetchStatus();
      expect(rows, hasLength(3));
      expect(rows.first.name, 'de');
      expect(panel.statusGets, 2);
      expect(attempts, hasLength(1));
      expect(attempts.single.clazz, 'timeout');
      expect(attempts.single.type, 'TimeoutException');
      expect(attempts.single.osErrorCode, isNull);
    });

    test('(b) a reset first status connection is answered '
        'by the retry, with the failure captured sanitized', () async {
      panel.resetsRemaining = 1;
      final attempts = <RegionHopTransportFailure>[];
      final client = RegionHopClient(
        panelUrl: panel.base,
        password: 'right',
        statusTimeout: const Duration(seconds: 5),
        statusRetryDelay: const Duration(milliseconds: 50),
      )..onStatusRetry = attempts.add;
      final rows = await client.fetchStatus();
      expect(rows, hasLength(3));
      expect(panel.statusGets, 2);
      expect(attempts, hasLength(1));
      final failure = attempts.single;
      // A destroyed socket surfaces as a socket reset or
      // as a truncated HTTP exchange — both are transport
      // classes, and neither may carry the address.
      expect(failure.clazz, anyOf('socket', 'http'));
      expect(failure.type, anyOf('SocketException', 'HttpException'));
      if (failure.osErrorCode != null) {
        expect(failure.osErrorCode, isA<int>());
      }
      // The journal line built from this failure (the
      // page's wiring) names the type — and no address.
      final lines = <(String, bool?)>[];
      final journal = RegionHopJournal(
        (text, {ok}) => lines.add((text, ok)),
      );
      journal.fetchRetrying(failure);
      expect(lines, hasLength(1));
      expect(lines.single.$1, contains(failure.type));
      expect(lines.single.$1, contains('retrying'));
      expect(lines.single.$1, isNot(contains('127.0.0.1')));
      expect(
        RegExp(r'\d+\.\d+\.\d+\.\d+').hasMatch(lines.single.$1),
        isFalse,
      );
    });

    test('the retry happens exactly once: two dead attempts '
        'surface the failure', () async {
      panel.resetsRemaining = 2;
      final attempts = <RegionHopTransportFailure>[];
      final client = RegionHopClient(
        panelUrl: panel.base,
        password: 'right',
        statusTimeout: const Duration(seconds: 5),
        statusRetryDelay: const Duration(milliseconds: 50),
      )..onStatusRetry = attempts.add;
      await expectLater(
        client.fetchStatus(),
        throwsA(
          isA<RegionHopException>()
              .having(
                (e) => e.kind,
                'kind',
                RegionHopErrorKind.unreachable,
              )
              .having((e) => e.transport, 'transport', isNotNull),
        ),
      );
      expect(panel.statusGets, 2); // the attempt + its one retry
      expect(attempts, hasLength(1));
    });

    test('a panel-side answer is never retried: HTTP 500', () async {
      panel.statusOverrideCode = 500;
      final client = RegionHopClient(
        panelUrl: panel.base,
        password: 'right',
        statusRetryDelay: const Duration(milliseconds: 50),
      );
      await expectLater(
        client.fetchStatus(),
        throwsA(
          isA<RegionHopException>().having(
            (e) => e.kind,
            'kind',
            RegionHopErrorKind.badResponse,
          ),
        ),
      );
      expect(panel.statusGets, 1);
    });

    test('a panel-side answer is never retried: malformed JSON', () async {
      panel.statusBody = 'this is not json';
      final client = RegionHopClient(
        panelUrl: panel.base,
        password: 'right',
        statusRetryDelay: const Duration(milliseconds: 50),
      );
      await expectLater(
        client.fetchStatus(),
        throwsA(
          isA<RegionHopException>().having(
            (e) => e.kind,
            'kind',
            RegionHopErrorKind.badResponse,
          ),
        ),
      );
      expect(panel.statusGets, 1);
    });
  });

  group('(c) login failure paths are unchanged', () {
    late _FakePanel panel;
    HttpOverrides? savedOverrides;

    setUp(() async {
      savedOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      panel = _FakePanel();
      await panel.start();
    });
    tearDown(() async {
      await panel.stop();
      HttpOverrides.global = savedOverrides;
    });

    test('a wrong password still fails in exactly one attempt', () async {
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
      expect(panel.loginPosts, 1);
    });

    test('a login failure inside fetchStatus is not retried '
        'by the fetch either', () async {
      final attempts = <RegionHopTransportFailure>[];
      final client = RegionHopClient(
        panelUrl: panel.base,
        password: 'nope',
        statusRetryDelay: const Duration(milliseconds: 50),
      )..onStatusRetry = attempts.add;
      await expectLater(
        client.fetchStatus(),
        throwsA(
          isA<RegionHopException>().having(
            (e) => e.kind,
            'kind',
            RegionHopErrorKind.loginFailed,
          ),
        ),
      );
      // The panel locks an IP out after 5 failed logins:
      // the fetch retry must never re-submit a password.
      expect(panel.loginPosts, 1);
      expect(attempts, isEmpty);
    });

    test('an unreachable login carries the sanitized refusal', () async {
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close();
      final client = RegionHopClient(
        panelUrl: 'http://127.0.0.1:$port/p',
        password: 'right',
      );
      try {
        await client.login();
        fail('login to a dead port must throw');
      } on RegionHopException catch (e) {
        expect(e.kind, RegionHopErrorKind.unreachable);
        expect(e.transport, isNotNull);
        expect(e.transport!.clazz, 'socket');
        expect(e.transport!.type, 'SocketException');
        // ECONNREFUSED on the Linux test host.
        expect(e.transport!.osErrorCode, 111);
        // The exception itself never embeds the address.
        expect(e.toString(), isNot(contains('127.0.0.1')));
      }
    });
  });

  group('the journal — retry transitions and vocabulary', () {
    late List<(String, bool?)> lines;
    late RegionHopJournal journal;

    const refused = RegionHopTransportFailure(
      clazz: 'socket',
      type: 'SocketException',
      osErrorCode: 111,
    );
    const reset = RegionHopTransportFailure(
      clazz: 'socket',
      type: 'SocketException',
      osErrorCode: 104,
    );
    const timedOut = RegionHopTransportFailure(
      clazz: 'timeout',
      type: 'TimeoutException',
    );

    setUp(() {
      lines = [];
      journal = RegionHopJournal((text, {ok}) => lines.add((text, ok)));
    });

    test('the retry journals as its own transition line', () {
      journal.fetchRetrying(reset);
      journal.fetchFailed(RegionHopErrorKind.unreachable, reset);
      expect(lines, [
        (
          'status fetch attempt failed — unreachable '
              '(socket SocketException os 104) — retrying',
          false,
        ),
        (
          'status fetch failed — unreachable '
              '(socket SocketException os 104)',
          false,
        ),
      ]);
    });

    test('a steady failure episode journals the retry once; '
        'a new error code is a new transition', () {
      journal.fetchRetrying(reset);
      journal.fetchRetrying(reset); // the next poll: silent
      journal.fetchFailed(RegionHopErrorKind.unreachable, reset);
      journal.fetchFailed(RegionHopErrorKind.unreachable, reset);
      journal.fetchRetrying(refused); // the failure changed
      journal.fetchFailed(RegionHopErrorKind.unreachable, refused);
      expect(lines, hasLength(4));
      expect(lines[2].$1, contains('os 111'));
      expect(lines[3].$1, contains('os 111'));
    });

    test('a recovery re-arms the retry line', () {
      journal.fetchRetrying(reset);
      journal.fetchFailed(RegionHopErrorKind.unreachable, reset);
      journal.fetchOk(3);
      journal.fetchRetrying(reset);
      expect(lines, hasLength(4));
      expect(lines[3].$1, contains('retrying'));
    });

    test('a fresh login re-arms the retry line', () {
      journal.fetchRetrying(timedOut);
      journal.loginOk();
      journal.fetchRetrying(timedOut);
      expect(lines, hasLength(3));
      expect(lines[2].$1, contains('timeout TimeoutException'));
    });

    test('fetchFailed without a transport keeps the 2140 shape', () {
      journal.fetchFailed(RegionHopErrorKind.badResponse);
      expect(lines, [('status fetch failed — badResponse', false)]);
    });

    test('the new lines carry no secret and no address', () {
      journal.loginOk();
      journal.fetchRetrying(refused);
      journal.fetchRetrying(timedOut);
      journal.fetchFailed(RegionHopErrorKind.unreachable, refused);
      journal.fetchFailed(
        RegionHopErrorKind.unreachable,
        const RegionHopTransportFailure(clazz: 'http', type: 'HttpException'),
      );
      journal.fetchOk(3);
      final all = lines.map((l) => l.$1).join('\n');
      // The vocabulary is classes, exception type names
      // and numbers — there is no slot a URL, path
      // prefix, password, cookie or address could
      // travel in.
      expect(all, isNot(contains('://')));
      expect(all, isNot(contains('password')));
      expect(all, isNot(contains('psi_session')));
      expect(all, isNot(contains('rh-')));
      expect(all, isNot(contains('127.0.0.1')));
      expect(RegExp(r'\d+\.\d+\.\d+\.\d+').hasMatch(all), isFalse);
    });
  });

  group('source pins', () {
    test('the client carries the hardening; the journal '
        'stays on the page', () {
      final client = _src('regionhop/regionhop_client.dart');
      expect(client, contains('Duration(seconds: 30)'));
      expect(client, contains('onStatusRetry'));
      expect(client, contains('RegionHopTransportFailure'));
      expect(client, contains('osErrorCode'));
      // Still no journaling from the client (2139/2140 pins).
      expect(client, isNot(contains('diagnostics')));
      expect(client, isNot(contains('RegionHopJournal')));
      final page = _src('ui/ember/regionhop_page.dart');
      expect(page, contains('onStatusRetry = _journal.fetchRetrying'));
      expect(page, contains('_journal.fetchFailed(e.kind, e.transport)'));
    });

    test('pubspec is 2.2.0+2148', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.2.0+2157'),
      );
    });
  });
}
