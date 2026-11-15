// Build 2062 — feature queue #2: LAN proxy sharing for the
// V2Ray/Xray tunnel. Sharing off (the default) is byte-identical
// to every earlier build; sharing on listens on 0.0.0.0 with
// optional username/password auth on both inbounds, and the
// app's own probes + the tun2socks bridge authenticate with
// the same credentials.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/lantern/lantern_controller.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/ui/ember/ember_settings.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/diagnostics.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Profile wsProfile() => Profile(
  id: 'p',
  protocol: Protocol.vless,
  name: 't',
  address: 'node.example.com',
  port: 443,
  uuidOrPassword: '11111111-1111-1111-1111-111111111111',
  security: 'tls',
  network: 'ws',
  host: 'cdn.example.com',
  path: '/ws',
  sni: 'cdn.example.com',
);

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

List<Map<String, dynamic>> inboundsOf(XraySettings s) {
  final cfg = decode(buildTunnelConfig(wsProfile(), s));
  return (cfg['inbounds'] as List).cast<Map<String, dynamic>>();
}

Map<String, dynamic> inbound(List<Map<String, dynamic>> inbounds, String tag) =>
    inbounds.firstWhere((i) => i['tag'] == tag);

/// Pumps EmberSettings in V2Ray mode (1) with a fresh controller.
Future<XrayController> pumpSettings(WidgetTester tester) async {
  final core = CoreController(
    () async => throw const CoreUnavailable(CoreProblem.refused, 'test'),
  );
  addTearDown(core.dispose);
  final xray = XrayController();
  addTearDown(xray.dispose);
  final psiphon = PsiphonController();
  addTearDown(psiphon.dispose);
  final lantern = LanternController();
  addTearDown(lantern.dispose);
  final openvpn = OpenVpnController();
  addTearDown(openvpn.dispose);
  final settings = AppSettings()..emberMode = 1;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: EmberSettings(
          core: core,
          xray: xray,
          psiphon: psiphon,
          lantern: lantern,
          openvpn: openvpn,
          settings: settings,
        ),
      ),
    ),
  );
  await tester.pump();
  return xray;
}

void main() {
  group('LAN sharing model (build 2062)', () {
    test('defaults are off, and auth is not ready with empty creds', () {
      final s = XraySettings();
      expect(s.lanShareEnabled, isFalse);
      expect(s.lanShareAuth, isFalse);
      expect(s.lanShareUser, '');
      expect(s.lanSharePass, '');
      expect(s.lanShareAuthReady, isFalse);
    });

    test('round-trips through JSON', () {
      final s = XraySettings()
        ..lanShareEnabled = true
        ..lanShareAuth = true
        ..lanShareUser = 'rayan'
        ..lanSharePass = 's3cret';
      final restored = XraySettings.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      expect(restored.lanShareEnabled, isTrue);
      expect(restored.lanShareAuth, isTrue);
      expect(restored.lanShareUser, 'rayan');
      expect(restored.lanSharePass, 's3cret');
      expect(restored.lanShareAuthReady, isTrue);
    });

    test('auth-ready needs auth on AND both credentials', () {
      final s = XraySettings()
        ..lanShareAuth = true
        ..lanShareUser = 'rayan';
      expect(s.lanShareAuthReady, isFalse);
      s.lanSharePass = 's3cret';
      expect(s.lanShareAuthReady, isTrue);
      s.lanShareAuth = false;
      expect(s.lanShareAuthReady, isFalse);
    });

    test('wrong-typed stored values fall back, never throw', () {
      final s = XraySettings.fromJson({
        'lanShareEnabled': 'yes',
        'lanShareAuth': 1,
        'lanShareUser': 42,
        'lanSharePass': true,
      });
      expect(s.lanShareEnabled, isFalse);
      expect(s.lanShareAuth, isFalse);
      expect(s.lanShareUser, '');
      expect(s.lanSharePass, '');
      expect(s.lanShareAuthReady, isFalse);
    });
  });

  group('LAN sharing builder matrix (build 2062)', () {
    test('sharing off: loopback, noauth, no accounts on both inbounds', () {
      final inbounds = inboundsOf(XraySettings());
      for (final tag in const ['socks', 'http']) {
        final ib = inbound(inbounds, tag);
        expect(ib['listen'], '127.0.0.1');
        expect(ib['settings']['auth'], 'noauth');
        expect(ib['settings'], isNot(contains('accounts')));
      }
    });

    test('sharing on: 0.0.0.0, still noauth without auth', () {
      final s = XraySettings()..lanShareEnabled = true;
      final inbounds = inboundsOf(s);
      for (final tag in const ['socks', 'http']) {
        final ib = inbound(inbounds, tag);
        expect(ib['listen'], '0.0.0.0');
        expect(ib['settings']['auth'], 'noauth');
        expect(ib['settings'], isNot(contains('accounts')));
      }
    });

    test('auth-ready: password + accounts on BOTH inbounds', () {
      final s = XraySettings()
        ..lanShareEnabled = true
        ..lanShareAuth = true
        ..lanShareUser = 'rayan'
        ..lanSharePass = 's3cret';
      final inbounds = inboundsOf(s);
      for (final tag in const ['socks', 'http']) {
        final ib = inbound(inbounds, tag);
        expect(ib['listen'], '0.0.0.0');
        expect(ib['settings']['auth'], 'password');
        expect(ib['settings']['accounts'], [
          {'user': 'rayan', 'pass': 's3cret'},
        ]);
      }
    });

    test('auth on but creds empty: noauth, no accounts', () {
      final s = XraySettings()
        ..lanShareEnabled = true
        ..lanShareAuth = true;
      final inbounds = inboundsOf(s);
      for (final tag in const ['socks', 'http']) {
        final ib = inbound(inbounds, tag);
        expect(ib['settings']['auth'], 'noauth');
        expect(ib['settings'], isNot(contains('accounts')));
      }
    });

    test('auth on with only a username: still noauth', () {
      final s = XraySettings()
        ..lanShareEnabled = true
        ..lanShareAuth = true
        ..lanShareUser = 'rayan';
      expect(inbound(inboundsOf(s), 'socks')['settings']['auth'], 'noauth');
    });

    test('the stats API inbound stays 127.0.0.1 in all cases', () {
      for (final s in [
        XraySettings(),
        XraySettings()..lanShareEnabled = true,
        XraySettings()
          ..lanShareEnabled = true
          ..lanShareAuth = true
          ..lanShareUser = 'rayan'
          ..lanSharePass = 's3cret',
      ]) {
        expect(inbound(inboundsOf(s), 'api')['listen'], '127.0.0.1');
      }
    });

    test('buildTestConfig stays loopback/noauth even with sharing on', () {
      final s = XraySettings()
        ..lanShareEnabled = true
        ..lanShareAuth = true
        ..lanShareUser = 'rayan'
        ..lanSharePass = 's3cret';
      final cfg = decode(buildTestConfig(wsProfile(), s));
      final ib = (cfg['inbounds'] as List).cast<Map<String, dynamic>>().single;
      expect(ib['listen'], '127.0.0.1');
      expect(ib['settings']['auth'], 'noauth');
      expect(ib['settings'], isNot(contains('accounts')));
    });
  });

  group('Dart SOCKS probe auth (build 2062)', () {
    test(
      'authed probe succeeds against an auth-requiring fake server',
      () async {
        final server = await _FakeSocks.start(user: 'rayan', pass: 's3cret');
        addTearDown(server.close);
        final ms = await socksDomainRequestMs(
          server.port,
          user: 'rayan',
          pass: 's3cret',
        );
        expect(ms, greaterThanOrEqualTo(0));
      },
    );

    test('authed probe fails with wrong credentials', () async {
      final server = await _FakeSocks.start(user: 'rayan', pass: 's3cret');
      addTearDown(server.close);
      final ms = await socksDomainRequestMs(
        server.port,
        user: 'rayan',
        pass: 'wrong',
      );
      expect(ms, -1);
    });

    test('authed probe fails against a noauth server', () async {
      final server = await _FakeSocks.start();
      addTearDown(server.close);
      final ms = await socksDomainRequestMs(
        server.port,
        user: 'rayan',
        pass: 's3cret',
      );
      expect(ms, -1);
    });

    test('noauth probe still succeeds against a noauth server', () async {
      final server = await _FakeSocks.start();
      addTearDown(server.close);
      final ms = await socksDomainRequestMs(server.port);
      expect(ms, greaterThanOrEqualTo(0));
    });

    test('noauth probe fails against an auth-requiring server', () async {
      final server = await _FakeSocks.start(user: 'rayan', pass: 's3cret');
      addTearDown(server.close);
      final ms = await socksDomainRequestMs(server.port);
      expect(ms, -1);
    });

    test('ConnectionChecker passes creds to the default domain probe', () {
      final diag = dartSrc('xray/diagnostics.dart');
      expect(
        diag,
        contains('socksDomainRequestMs(p, user: socksUser, pass: socksPass)'),
      );
      expect(diag, contains('String socksUser ='));
      expect(diag, contains('String socksPass ='));
      expect(diag, contains("String listenHost = '127.0.0.1'"));
    });
  });

  group('Controller + platform plumbing (build 2062)', () {
    test('controller derives LAN creds from settings, warp port gets none', () {
      final c = dartSrc('xray/xray_controller.dart');
      expect(c, contains('settings.lanShareAuthReady ? settings.lanShareUser'));
      expect(c, contains('settings.lanShareAuthReady ? settings.lanSharePass'));
      expect(c, contains("socksUser: warpSession ? '' : _lanUser"));
      expect(c, contains("socksPass: warpSession ? '' : _lanPass"));
      expect(c, contains('socksUser: _lanUser'));
      expect(c, contains('socksPass: _lanPass'));
      expect(c, contains('socksUser: _lanUser,'));
      expect(
        c,
        contains(
          "listenHost: settings.lanShareEnabled ? '0.0.0.0' : '127.0.0.1'",
        ),
      );
    });

    test('Dart platform channel carries the credentials', () {
      final p = dartSrc('xray/xray_platform.dart');
      expect(p, contains("String socksUser = ''"));
      expect(p, contains("String socksPass = ''"));
      expect(p, contains("'socksUser': socksUser"));
      expect(p, contains("'socksPass': socksPass"));
      expect(p, contains('tunnelCheck('));
      expect(p, contains('exitInfo('));
    });
  });

  group('Kotlin pins (build 2062)', () {
    test('service builds the tunlink userinfo URL, percent-encoded', () {
      final kt = ktSrc('XrayVpnService.kt');
      expect(kt, contains('EXTRA_SOCKS_USER'));
      expect(kt, contains('EXTRA_SOCKS_PASS'));
      expect(
        kt,
        contains('socks5://\$encUser:\$encPass@127.0.0.1:\$socksPort'),
      );
      expect(kt, contains('URLEncoder.encode(socksUser, "UTF-8")'));
      expect(kt, contains('URLEncoder.encode(socksPass, "UTF-8")'));
      expect(kt, contains('.replace("+", "%20")'));
      // The warp/Psiphon tunlink spawns keep their plain URLs.
      expect(kt, contains('"socks5://127.0.0.1:\${EmberWarpCore.SOCKS_PORT}"'));
      expect(kt, contains('"socks5://127.0.0.1:\$socksPort"'));
    });

    test('tester Authenticator answers only loopback host + stored port', () {
      final kt = ktSrc('XrayTester.kt');
      expect(kt, contains('private object SocksAuth : Authenticator()'));
      expect(kt, contains('requestingHost != "127.0.0.1"'));
      expect(kt, contains('requestingPort != port'));
      expect(kt, contains('Authenticator.setDefault(SocksAuth)'));
      expect(
        kt,
        contains(
          'fun tunnelCheck(port: Int, user: String = "", pass: String = "")',
        ),
      );
      expect(
        kt,
        contains(
          'fun exitInfo(port: Int, user: String = "", pass: String = "")',
        ),
      );
      expect(
        kt,
        contains(
          'private fun timeRequest(port: Int, user: String = "", pass: String = "")',
        ),
      );
      // The sandbox/test cores still call the noauth defaults.
      expect(kt, contains('timeRequest(port)'));
      expect(kt, contains('exitInfo(port)'));
    });

    test('MainActivity threads the credentials on every Xray call', () {
      final kt = ktSrc('MainActivity.kt');
      expect(kt, contains('call.argument<String>("socksUser") ?: ""'));
      expect(kt, contains('call.argument<String>("socksPass") ?: ""'));
      expect(kt, contains('XrayTester.tunnelCheck(port, user, pass)'));
      expect(kt, contains('XrayTester.exitInfo(port, user, pass)'));
      // The setOn path still goes through the VPN-permission flow.
      expect(kt, contains('XrayVpnService.start('));
    });
  });

  group('LAN sharing Settings panel (build 2062)', () {
    testWidgets('panel renders, sharing off hides auth + address rows', (
      tester,
    ) async {
      final xray = await pumpSettings(tester);
      expect(xray.settings.lanShareEnabled, isFalse);
      expect(find.text('LAN SHARING'), findsOneWidget);
      expect(find.text('Share on local network'), findsOneWidget);
      expect(find.text('Require username and password'), findsNothing);
      expect(find.text('Username'), findsNothing);
      expect(find.text('Password'), findsNothing);
      expect(
        find.text('Anyone on your Wi-Fi can use the tunnel.'),
        findsNothing,
      );
    });

    testWidgets('sharing on shows address + auth toggle + open caption', (
      tester,
    ) async {
      final xray = await pumpSettings(tester);
      xray.settings.lanShareEnabled = true;
      xray.notifyListeners();
      await tester.pump(); // mounts the address row, starts lanAddress()
      // lanAddress() is real host I/O, not a fake-async timer,
      // so give it real time, then pump the resolved state in.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();
      expect(find.text('Require username and password'), findsOneWidget);
      expect(
        find.text('Anyone on your Wi-Fi can use the tunnel.'),
        findsOneWidget,
      );
      // Either a real LAN address row or the no-Wi-Fi message.
      final hasAddress = find.textContaining('socks5://').evaluate().isNotEmpty;
      final hasNoWifi = find
          .text('Connect to Wi-Fi to see the address.')
          .evaluate()
          .isNotEmpty;
      expect(hasAddress || hasNoWifi, isTrue);
    });

    testWidgets('auth on shows username/password + incomplete-creds caption', (
      tester,
    ) async {
      final xray = await pumpSettings(tester);
      xray.settings
        ..lanShareEnabled = true
        ..lanShareAuth = true;
      xray.notifyListeners();
      await tester.pump();
      expect(find.text('Username'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(
        find.text(
          'Enter a username and password — until then the shared proxy has no login.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Anyone on your Wi-Fi can use the tunnel.'),
        findsNothing,
      );
    });

    testWidgets('auth on with both creds hides the incomplete caption', (
      tester,
    ) async {
      final xray = await pumpSettings(tester);
      xray.settings
        ..lanShareEnabled = true
        ..lanShareAuth = true
        ..lanShareUser = 'rayan'
        ..lanSharePass = 's3cret';
      xray.notifyListeners();
      await tester.pump();
      expect(
        find.text(
          'Enter a username and password — until then the shared proxy has no login.',
        ),
        findsNothing,
      );
    });

    test('source: panel sits after DNS, _TextRow has obscure, validation refuses empty', () {
      final settings = dartSrc('ui/ember/ember_settings.dart');
      expect(settings, contains("title: 'LAN sharing'"));
      expect(settings, contains('Share on local network'));
      expect(settings, contains('Require username and password'));
      expect(settings, contains('lanAddress()'));
      expect(settings, contains('this.obscure = false'));
      expect(settings, contains('obscureText: obscure'));
      expect(settings, contains("content: Text('Enter a username.')"));
      expect(settings, contains("content: Text('Enter a password.')"));
      // Placement: after the DNS panel, before Custom Rules.
      final lanAt = settings.indexOf("title: 'LAN sharing'");
      final dnsAt = settings.indexOf('title: l.dnsSection');
      final rulesAt = settings.indexOf('title: l.customRules');
      expect(lanAt, greaterThan(dnsAt));
      expect(rulesAt, greaterThan(lanAt));
    });
  });
}

/// A minimal loopback SOCKS5 server for the Dart probe tests:
/// [user]/[pass] set means it demands username/password auth
/// (method 2); null means noauth. Answers CONNECT with success
/// and the generate_204 request with a 204.
class _FakeSocks {
  _FakeSocks._(this.server);

  final ServerSocket server;

  int get port => server.port;

  static Future<_FakeSocks> start({String? user, String? pass}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeSocks._(server);
    unawaited(fake._serve(user: user, pass: pass));
    return fake;
  }

  Future<void> close() async {
    await server.close();
  }

  Future<void> _serve({String? user, String? pass}) async {
    try {
      final socket = await server.first;
      final reader = _ByteReader(socket);
      try {
        final head = await reader.read(2);
        await reader.read(head[1]); // the offered methods
        final wantsAuth = user != null && pass != null;
        if (wantsAuth) {
          // The server insists on username/password auth even
          // when the client offered only noauth: it answers
          // method 2, and the client's CONNECT bytes are then
          // read as the subnegotiation (which fails, as it
          // must) — a reply of [1, 1] is what lets the probe
          // return -1 instead of waiting on a closed socket.
          // (Destroying the socket with no reply would hang
          // the probe: its StreamQueue only resolves on data
          // or a stream error, and a fast close is neither.)
          socket.add(const [5, 2]);
          await socket.flush();
          final sub = await reader.read(2);
          final u = await reader.read(sub[1]);
          final plen = await reader.read(1);
          final p = await reader.read(plen[0]);
          final ok = utf8.decode(u) == user && utf8.decode(p) == pass;
          socket.add([1, ok ? 0 : 1]);
          await socket.flush();
          if (!ok) {
            socket.destroy();
            return;
          }
        } else {
          socket.add(const [5, 0]);
          await socket.flush();
        }
        // CONNECT by domain: ver, cmd, rsv, atyp, len, host, port.
        final cHead = await reader.read(4);
        if (cHead[3] != 3) {
          socket.destroy();
          return;
        }
        final hLen = await reader.read(1);
        await reader.read(hLen[0]);
        await reader.read(2);
        socket.add(const [5, 0, 0, 1, 127, 0, 0, 1, 0, 80]);
        await socket.flush();
        // The HTTP HEAD, up to the blank line.
        final request = <int>[];
        while (true) {
          final b = await reader.read(1);
          request.add(b[0]);
          if (request.length >= 4 &&
              request[request.length - 4] == 13 &&
              request[request.length - 3] == 10 &&
              request[request.length - 2] == 13 &&
              request[request.length - 1] == 10) {
            break;
          }
        }
        socket.add(
          utf8.encode('HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n'),
        );
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      } finally {
        socket.destroy();
      }
    } catch (_) {
      // The client going away mid-handshake is a verdict, not
      // a test failure: the probe side asserts the outcome.
    }
  }
}

/// Exact-byte reader over one socket subscription (a Socket is
/// single-subscription, so repeated `.first` reads would throw).
class _ByteReader {
  _ByteReader(Socket socket) {
    socket.listen(
      (chunk) {
        _buf.addAll(chunk);
        for (final w in List.of(_waiters)) {
          if (_buf.length >= w.$1) {
            _waiters.remove(w);
            final out = _buf.sublist(0, w.$1);
            _buf.removeRange(0, w.$1);
            w.$2.complete(out);
          }
        }
      },
      onError: (Object e) {
        for (final w in _waiters) {
          w.$2.completeError(e);
        }
        _waiters.clear();
      },
    );
  }

  final List<int> _buf = [];
  final List<(int, Completer<List<int>>)> _waiters = [];

  Future<List<int>> read(int n) {
    if (_buf.length >= n) {
      final out = _buf.sublist(0, n);
      _buf.removeRange(0, n);
      return Future.value(out);
    }
    final completer = Completer<List<int>>();
    _waiters.add((n, completer));
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('fake SOCKS read timed out'),
    );
  }
}
