// Build 2142 — ONE leg (scope: build2142-progress.md):
// make the RegionHop client's HTTP requests
// browser-like, and journal the status fetch's phase
// timings. The evidence chain: panel + server
// exonerated (curl answers in 0.2–3.8 s; the owner's
// phone BROWSER fetched the exact /tunnels-status URL
// and returned the full JSON twice, incl. a paired
// same-minute test), while the app's login succeeds and
// its status requests hang to the 30 s timeout — a
// silent drop of the app's request flows on his carrier
// path. Prime suspect: the dart:io fingerprint (default
// `User-Agent: Dart/3.x (dart:io)`, minimal headers).
//
// This build: every panel request carries a mobile
// Chrome User-Agent + Accept + Accept-Language, and the
// status fetch measures open / headers / body phase
// timings, journaled (through the page's journal) on a
// fetch failure and on the first success after one —
// numbers and phase tokens only.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/regionhop/regionhop_client.dart';
import 'package:firefox_vpn/ui/ember/regionhop_page.dart';

String _src(String rel) => File('lib/$rel').readAsStringSync();

const _statusPayload = '''
[
  {"Name":"de","Region":"DE - Germany","SocksPort":19000,
   "Status":"active","StatusClass":"active",
   "ExitIP":"","ExitRegion":"DE - Germany","ExitFlagURL":""},
  {"Name":"nl","Region":"NL - Netherlands","SocksPort":19001,
   "Status":"inactive","StatusClass":"inactive",
   "ExitIP":"","ExitRegion":"","ExitFlagURL":""}
]
''';

/// One request the fake panel received, with the header
/// values this build is about.
class _RecordedRequest {
  const _RecordedRequest(
    this.method,
    this.path,
    this.userAgent,
    this.accept,
    this.acceptLanguage,
  );

  final String method;
  final String path;
  final String? userAgent;
  final String? accept;
  final String? acceptLanguage;
}

/// A fake regionhop panel on loopback (the build2139/
/// 2141 precedent) that records the headers of every
/// request and can hang the status response's headers
/// past the client's timeout.
class _FakePanel {
  HttpServer? _server;
  final List<_RecordedRequest> requests = [];
  bool hangStatusHeaders = false;
  Duration statusHang = const Duration(seconds: 3);

  String get base => 'http://127.0.0.1:${_server!.port}/p';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> stop() async => _server?.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    requests.add(
      _RecordedRequest(
        req.method,
        path,
        req.headers.value('user-agent'),
        req.headers.value('accept'),
        req.headers.value('accept-language'),
      ),
    );
    try {
      if (path == '/p/login' && req.method == 'GET') {
        res.statusCode = 200;
        res.write('<html><body>login</body></html>');
      } else if (path == '/p/login' && req.method == 'POST') {
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
        final cookie = req.headers.value('cookie') ?? '';
        if (!cookie.contains('psi_session=')) {
          res.statusCode = 303;
          res.headers.set('location', '/p/login');
        } else {
          if (hangStatusHeaders) {
            // The response's headers never arrive inside
            // the client's timeout window: the fetch must
            // die in the headers phase.
            await Future<void>.delayed(statusHang);
          }
          res.statusCode = 200;
          res.headers.contentType = ContentType.json;
          res.write(_statusPayload);
        }
      } else if (path == '/p/tunnels/de/test') {
        res.statusCode = 200;
        res.headers.contentType = ContentType.json;
        res.write(
          '{"ok":true,"latencyMs":42,"ip":"203.0.113.7",'
          '"google":"ok","detail":""}',
        );
      } else if (path == '/p/tunnels/de/restart' ||
          path == '/p/tunnels/de/stop') {
        res.statusCode = 303;
        res.headers.set('location', '/p/');
      } else {
        res.statusCode = 404;
      }
      await res.close();
    } on Object {
      // A client that timed out is gone by the time a
      // hung answer is written; the fake panel does not
      // care.
    }
  }
}

void main() {
  group('browser-like requests against a fake panel', () {
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

    test('every panel request carries the browser header '
        'set', () async {
      final client = RegionHopClient(
        panelUrl: panel.base,
        password: 'right',
      );
      await client.login();
      final rows = await client.fetchStatus();
      expect(rows, hasLength(2));
      final probe = await client.probe('de');
      expect(probe.ok, isTrue);
      await client.restart('de');
      await client.stop('de');

      // Login probe + login POST, status, probe,
      // restart, stop — six requests, all browser-like.
      expect(panel.requests, hasLength(6));
      expect(
        panel.requests.map((r) => '${r.method} ${r.path}'),
        [
          'GET /p/login',
          'POST /p/login',
          'GET /p/tunnels-status',
          'GET /p/tunnels/de/test',
          'POST /p/tunnels/de/restart',
          'POST /p/tunnels/de/stop',
        ],
      );
      for (final r in panel.requests) {
        expect(
          r.userAgent,
          regionHopBrowserUserAgent,
          reason: '${r.method} ${r.path} user-agent',
        );
        expect(r.accept, '*/*', reason: '${r.method} ${r.path} accept');
        expect(
          r.acceptLanguage,
          'en-US,en;q=0.9',
          reason: '${r.method} ${r.path} accept-language',
        );
      }
      // The whole point: the dart:io default is gone.
      expect(regionHopBrowserUserAgent, contains('Chrome/'));
      expect(regionHopBrowserUserAgent, isNot(contains('dart:io')));
    });

    test('a hung-headers status fetch journals '
        'headers=timeout with a numeric open phase', () async {
      panel.hangStatusHeaders = true;
      final lines = <(String, bool?)>[];
      final journal = RegionHopJournal(
        (text, {ok}) => lines.add((text, ok)),
      );
      final client = RegionHopClient(
        panelUrl: panel.base,
        password: 'right',
        statusTimeout: const Duration(milliseconds: 800),
        statusRetryDelay: const Duration(milliseconds: 50),
      )
        ..onStatusRetry = journal.fetchRetrying
        ..onStatusPhases = journal.fetchPhases;
      await expectLater(
        client.fetchStatus(),
        throwsA(
          isA<RegionHopException>().having(
            (e) => e.kind,
            'kind',
            RegionHopErrorKind.unreachable,
          ),
        ),
      );
      final phasesLines = lines
          .where((l) => l.$1.contains('status fetch phases'))
          .toList();
      // Both attempts hung in the same phase, but the
      // phases journal on the transition — exactly once.
      expect(phasesLines, hasLength(1));
      expect(phasesLines.single.$2, isFalse);
      expect(phasesLines.single.$1, contains('headers=timeout'));
      expect(
        RegExp(r'open=\d+').hasMatch(phasesLines.single.$1),
        isTrue,
      );
      expect(phasesLines.single.$1, contains('body=-'));
      // The 2141 retry transition still journals.
      expect(
        lines.where((l) => l.$1.contains('retrying')),
        hasLength(1),
      );
    });

    test('an ordinary success journals no phase line; a '
        'failure then a success journals the recovery '
        'once', () async {
      final lines = <(String, bool?)>[];
      final journal = RegionHopJournal(
        (text, {ok}) => lines.add((text, ok)),
      );
      final client = RegionHopClient(
        panelUrl: panel.base,
        password: 'right',
        statusTimeout: const Duration(milliseconds: 800),
        statusRetryDelay: const Duration(milliseconds: 50),
      )
        ..onStatusRetry = journal.fetchRetrying
        ..onStatusPhases = journal.fetchPhases;

      // Ordinary success: rows parsed, no phase line.
      final rows = await client.fetchStatus();
      expect(rows, hasLength(2));
      expect(
        lines.where((l) => l.$1.contains('status fetch phases')),
        isEmpty,
      );

      // Failure: the phases journal (once).
      panel.hangStatusHeaders = true;
      await expectLater(
        client.fetchStatus(),
        throwsA(isA<RegionHopException>()),
      );
      var phasesLines = lines
          .where((l) => l.$1.contains('status fetch phases'))
          .toList();
      expect(phasesLines, hasLength(1));
      expect(phasesLines.single.$2, isFalse);

      // First success after the failure: the recovery
      // phases journal, exactly once.
      panel.hangStatusHeaders = false;
      final recovered = await client.fetchStatus();
      expect(recovered, hasLength(2));
      phasesLines = lines
          .where((l) => l.$1.contains('status fetch phases'))
          .toList();
      expect(phasesLines, hasLength(2));
      expect(phasesLines.last.$2, isTrue);
      expect(
        RegExp(
          r'open=\d+ headers=\d+ body=\d+',
        ).hasMatch(phasesLines.last.$1),
        isTrue,
      );

      // A further ordinary success adds nothing.
      await client.fetchStatus();
      expect(
        lines.where((l) => l.$1.contains('status fetch phases')),
        hasLength(2),
      );
    });

    test('the phase lines keep the journal vocabulary', () async {
      panel.hangStatusHeaders = true;
      final lines = <(String, bool?)>[];
      final journal = RegionHopJournal(
        (text, {ok}) => lines.add((text, ok)),
      );
      final client = RegionHopClient(
        panelUrl: panel.base,
        password: 'right',
        statusTimeout: const Duration(milliseconds: 800),
        statusRetryDelay: const Duration(milliseconds: 50),
      )
        ..onStatusRetry = journal.fetchRetrying
        ..onStatusPhases = journal.fetchPhases;
      journal.loginOk();
      await expectLater(
        client.fetchStatus(),
        throwsA(isA<RegionHopException>()),
      );
      journal.fetchFailed(
        RegionHopErrorKind.unreachable,
        const RegionHopTransportFailure(
          clazz: 'timeout',
          type: 'TimeoutException',
        ),
      );
      panel.hangStatusHeaders = false;
      await client.fetchStatus();
      journal.fetchOk(2);
      expect(lines, isNotEmpty);
      final all = lines.map((l) => l.$1).join('\n');
      // Numbers and phase tokens only: no slot a URL,
      // path prefix, password, cookie, address — or the
      // browser UA itself — could travel in.
      expect(all, isNot(contains('://')));
      expect(all, isNot(contains('password')));
      expect(all, isNot(contains('psi_session')));
      expect(all, isNot(contains('rh-')));
      expect(all, isNot(contains(regionHopBrowserUserAgent)));
      expect(all, isNot(contains('127.0.0.1')));
      expect(RegExp(r'\d+\.\d+\.\d+\.\d+').hasMatch(all), isFalse);
    });
  });

  group('the journal — phase transitions (unit)', () {
    RegionHopPhaseTimings timings({
      int? open,
      String? openFail,
      int? headers,
      String? headersFail,
      int? body,
      String? bodyFail,
    }) => RegionHopPhaseTimings()
      ..openMs = open
      ..openFailure = openFail
      ..headersMs = headers
      ..headersFailure = headersFail
      ..bodyMs = body
      ..bodyFailure = bodyFail;

    test('the tokens render numbers, failure classes and '
        'unreached phases', () {
      expect(
        timings(open: 312, headersFail: 'timeout').journalTokens,
        'open=312 headers=timeout body=-',
      );
      expect(
        timings(open: 5, headers: 120, body: 30).journalTokens,
        'open=5 headers=120 body=30',
      );
      expect(
        timings(openFail: 'socket').journalTokens,
        'open=socket headers=- body=-',
      );
      expect(
        timings(open: 312, headersFail: 'timeout').shape,
        'ok/timeout/-',
      );
    });

    test('a steady failure shape journals once; a new '
        'shape is a new transition', () {
      final lines = <(String, bool?)>[];
      final journal = RegionHopJournal(
        (text, {ok}) => lines.add((text, ok)),
      );
      journal.fetchPhases(
        timings(open: 300, headersFail: 'timeout'),
        ok: false,
      );
      journal.fetchPhases(
        timings(open: 999, headersFail: 'timeout'),
        ok: false,
      ); // same shape, new numbers: silent
      journal.fetchPhases(timings(openFail: 'socket'), ok: false);
      expect(lines, hasLength(2));
      expect(lines[0].$1, contains('headers=timeout'));
      expect(lines[1].$1, contains('open=socket'));
    });

    test('a fresh login re-arms the phase lines', () {
      final lines = <(String, bool?)>[];
      final journal = RegionHopJournal(
        (text, {ok}) => lines.add((text, ok)),
      );
      journal.fetchPhases(
        timings(open: 300, headersFail: 'timeout'),
        ok: false,
      );
      journal.loginOk();
      journal.fetchPhases(
        timings(open: 300, headersFail: 'timeout'),
        ok: false,
      );
      expect(
        lines.where((l) => l.$1.contains('status fetch phases')),
        hasLength(2),
      );
    });
  });

  group('source pins', () {
    test('the client carries the browser header set; the '
        'journal stays on the page', () {
      final client = _src('regionhop/regionhop_client.dart');
      expect(client, contains('regionHopBrowserUserAgent'));
      expect(client, contains('HttpHeaders.userAgentHeader'));
      expect(client, contains('HttpHeaders.acceptHeader'));
      expect(client, contains('HttpHeaders.acceptLanguageHeader'));
      expect(client, contains('onStatusPhases'));
      expect(client, contains('RegionHopPhaseTimings'));
      // Still no journaling from the client (2139/2140 pins).
      expect(client, isNot(contains('diagnostics')));
      expect(client, isNot(contains('RegionHopJournal')));
      final page = _src('ui/ember/regionhop_page.dart');
      expect(page, contains('onStatusPhases = _journal.fetchPhases'));
    });

    test('pubspec is 2.2.0+2148', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.2.0+2150'),
      );
    });
  });
}
