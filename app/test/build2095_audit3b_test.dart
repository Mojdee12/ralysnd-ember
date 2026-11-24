/// Build 2095, third-pass audit Dim 8 (second file) —
/// the widget/flow pins:
///
/// - 8-2: importScannedCode routes each scanned shape to
///   its own importer (config link / subscription URL /
///   http proxy link / WireGuard conf body).
/// - 8-8: the profile editor refuses a bad port with the
///   stored profile untouched, and an open→save round
///   trip preserves the batch-7 fields (TCP header type,
///   XHTTP mode, QUIC security/key).
/// - 8-10: the OpenVPN AUTH_FAILED recovery deletes the
///   saved vault pair before re-prompting (behavioral,
///   over the mocked platform channel).
/// - 2.1 (OpenVPN): a disconnect during connect's
///   validation window cancels the connect — setOn is
///   never reached.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/ui/ember/openvpn_pages.dart';
import 'package:firefox_vpn/ui/ember/profile_editor.dart';
import 'package:firefox_vpn/ui/ember/qr_pages.dart';
import 'package:firefox_vpn/xray/sub_fetcher.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Widget _app(Widget home) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('importScannedCode routing (audit 8-2)', () {
    XrayController controllerWithFetcher(List<String> fetched) {
      final c = XrayController();
      c.subscriptionFetcher =
          (
            url, {
            certPin = '',
            hwid = '',
            headers = const {},
            fallbackUrl = '',
            hosts = const {},
          }) async {
            fetched.add(url);
            return SubResult(
              profiles: [
                Profile(
                  id: 'fromsub',
                  protocol: Protocol.vless,
                  name: 'Sub Node',
                  address: 'sub.example.com',
                  port: 443,
                  uuidOrPassword: '33333333-3333-3333-3333-333333333333',
                ),
              ],
            );
          };
      return c;
    }

    Future<void> scan(
      WidgetTester tester,
      XrayController xray,
      String code,
    ) async {
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => importScannedCode(context, xray, code),
                child: const Text('scan'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('scan'));
      await tester.pumpAndSettle();
    }

    testWidgets('a config link imports as a profile', (tester) async {
      final fetched = <String>[];
      final xray = controllerWithFetcher(fetched);
      addTearDown(xray.dispose);
      await scan(
        tester,
        xray,
        'vless://11111111-1111-1111-1111-111111111111@node.example.com:443'
        '?encryption=none&security=tls#Node',
      );
      expect(xray.profiles, hasLength(1));
      expect(xray.subscriptions, isEmpty);
      expect(fetched, isEmpty);
    });

    testWidgets('a subscription URL goes to the fetcher', (tester) async {
      final fetched = <String>[];
      final xray = controllerWithFetcher(fetched);
      addTearDown(xray.dispose);
      await scan(tester, xray, 'https://panel.example.com/sub/abcdef');
      expect(fetched, ['https://panel.example.com/sub/abcdef']);
      expect(xray.subscriptions, hasLength(1));
      expect(xray.profiles, hasLength(1));
    });

    testWidgets('an http proxy link imports as a profile, not a subscription',
        (tester) async {
      final fetched = <String>[];
      final xray = controllerWithFetcher(fetched);
      addTearDown(xray.dispose);
      await scan(tester, xray, 'http://user:pass@proxy.example.com:8080#P');
      expect(xray.profiles, hasLength(1));
      expect(xray.profiles.single.protocol, Protocol.http);
      expect(xray.subscriptions, isEmpty);
      expect(fetched, isEmpty);
    });

    testWidgets('a WireGuard conf body routes to the WG importer',
        (tester) async {
      final fetched = <String>[];
      final xray = controllerWithFetcher(fetched);
      addTearDown(xray.dispose);
      const conf = '''
[Interface]
PrivateKey = aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGxvaGU=
Address = 10.0.0.2/32
[Peer]
PublicKey = aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGxvaGU=
Endpoint = wg.example.com:51820
AllowedIPs = 0.0.0.0/0
''';
      await scan(tester, xray, conf);
      // The WG importer asks for a name first (its own
      // dialog); confirming it completes the import.
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      expect(xray.profiles, hasLength(1));
      expect(xray.profiles.single.protocol, Protocol.wireguard);
    });
  });

  group('profile editor (audit 8-8)', () {
    Future<void> pumpEditor(WidgetTester tester, XrayController xray,
        Profile p) async {
      await tester.pumpWidget(
        _app(ProfileEditorPage(xray: xray, existing: p)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('open→save preserves the TCP header type', (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final tcp = Profile(
        id: 'e1',
        protocol: Protocol.vless,
        name: 'tcp',
        address: 'a.example.com',
        port: 443,
        uuidOrPassword: '11111111-1111-1111-1111-111111111111',
        network: 'tcp',
        headerType: 'http',
        security: 'tls',
      );
      xray.profiles.add(tcp);
      await pumpEditor(tester, xray, tcp);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(xray.profiles.single.headerType, 'http');
    });

    testWidgets('open→save preserves the XHTTP mode', (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final xhttp = Profile(
        id: 'e2',
        protocol: Protocol.vless,
        name: 'xh',
        address: 'b.example.com',
        port: 443,
        uuidOrPassword: '22222222-2222-2222-2222-222222222222',
        network: 'xhttp',
        mode: 'packet-up',
        security: 'tls',
      );
      xray.profiles.add(xhttp);
      await pumpEditor(tester, xray, xhttp);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(xray.profiles.single.mode, 'packet-up');
    });

    testWidgets('open→save preserves the QUIC security/key', (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final quic = Profile(
        id: 'e3',
        protocol: Protocol.vless,
        name: 'q',
        address: 'c.example.com',
        port: 443,
        uuidOrPassword: '33333333-3333-3333-3333-333333333333',
        network: 'quic',
        host: 'quic-security',
        path: 'quic-key',
        security: 'tls',
      );
      xray.profiles.add(quic);
      await pumpEditor(tester, xray, quic);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(xray.profiles.single.host, 'quic-security');
      expect(xray.profiles.single.path, 'quic-key');
    });

    testWidgets('a bad port is refused and the stored profile is untouched',
        (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final p = Profile(
        id: 'e9',
        protocol: Protocol.vless,
        name: 'keep',
        address: 'a.example.com',
        port: 443,
        uuidOrPassword: '11111111-1111-1111-1111-111111111111',
        security: 'tls',
      );
      xray.profiles.add(p);
      await pumpEditor(tester, xray, p);
      final portField = find.widgetWithText(TextField, 'Port').first;
      await tester.ensureVisible(portField);
      await tester.enterText(portField, '99999');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      // The editor stays open with its message; the store
      // keeps the old port.
      expect(find.byType(ProfileEditorPage), findsOneWidget);
      expect(xray.profiles.single.port, 443);
    });
  });

  group('OpenVPN flows (audit 8-10 + 2.1)', () {
    const cfgA = '''
client
dev tun
proto udp
remote alpha.example.com 1194
auth-user-pass
''';

    late Directory tempDir;
    final channelCalls = <String>[];
    var stateMap = <String, Object?>{};
    var credStatus = 'ok';
    Completer<void>? validateGate;

    Map<String, Object?> stateFor({
      bool running = false,
      String phase = 'idle',
      String? error,
    }) => <String, Object?>{
      'available': true,
      'running': running,
      'connected': running,
      'phase': phase,
      'profileId': running ? 'user-a' : '',
      'profileName': '',
      'sinceMs': 0,
      'up': 0,
      'down': 0,
      'exitIp': '',
      'exitCountry': '',
      'exitCode': '',
      'error': error,
      'logTail': <String>[],
      'lastExitReason': '',
      'lastStage': '',
      'lastException': '',
    };

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ovpn2095b');
      channelCalls.clear();
      stateMap = stateFor();
      credStatus = 'ok';
      validateGate = null;
      final dir = Directory('${tempDir.path}/openvpn');
      await dir.create(recursive: true);
      await File('${dir.path}/state.json').writeAsString(
        jsonEncode({
          'selectedId': 'user-a',
          'profiles': [
            {'id': 'user-a', 'name': 'Alpha', 'config': cfgA},
          ],
        }),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'), (
            call,
          ) async {
            channelCalls.add(call.method);
            switch (call.method) {
              case 'dataDir':
                return '${tempDir.path}/core';
              case 'openVpnState':
                return stateMap;
              case 'openVpnStop':
                stateMap = stateFor();
                return null;
              case 'openVpnCredentialStatus':
                return credStatus;
              case 'openVpnValidate':
                await validateGate?.future;
                return '';
              case 'openVpnSetOn':
                stateMap = stateFor(phase: 'error', error: 'AUTH_FAILED');
                return null;
              case 'openVpnDeleteCredentials':
                credStatus = 'none';
                return null;
              default:
                return null;
            }
          });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'), null);
      await tempDir.delete(recursive: true);
    });

    testWidgets('AUTH_FAILED recovery deletes the vault pair, then prompts',
        (tester) async {
      final c = OpenVpnController();
      addTearDown(c.dispose);
      // Real file IO cannot complete inside the widget
      // test's fake-async zone — load for real first.
      await tester.runAsync(() => c.load());
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => connectOpenVpnWithPrompt(context, c),
                child: const Text('connect'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('connect'));
      await tester.pumpAndSettle();
      expect(find.text('The server rejected the saved password'),
          findsOneWidget);
      await tester.tap(find.text('Re-enter'));
      await tester.pumpAndSettle();
      expect(
        channelCalls,
        contains('openVpnDeleteCredentials'),
        reason: 'the rejected pair leaves the vault before re-entry',
      );
      // The recursion now hits credentials-required and the
      // prompt opens (the pair is gone from the vault).
      expect(find.text('Alpha'), findsWidgets);
    });

    test('a disconnect during validation cancels the connect (audit 2.1)',
        () async {
      final c = OpenVpnController();
      addTearDown(c.dispose);
      await c.load();
      validateGate = Completer<void>();
      Object? connectError;
      final connectFuture = c.connect().then<void>(
        (_) {},
        onError: (Object e) => connectError = e,
      );
      // Let the connect reach the gated validation.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(channelCalls, contains('openVpnValidate'));
      await c.disconnect();
      validateGate!.complete();
      await connectFuture;
      expect(connectError, isNull, reason: 'a cancelled connect is quiet');
      expect(
        channelCalls,
        isNot(contains('openVpnSetOn')),
        reason: 'the cancelled attempt never starts the tunnel',
      );
    });
  });
}
