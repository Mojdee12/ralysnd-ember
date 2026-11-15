/// Regression test for the build-2025 on-device verdict
/// "country selection does not work at all" (build 2026),
/// retargeted in build 2028: the bundled TunnelBear list is
/// gone (owner's ruling — a generic client), so selection is
/// driven end to end with the REAL OpenVpnController over
/// two IMPORTED profiles seeded in the on-disk store —
/// selection must register visibly, nothing may throw, and
/// no native validate/connect work may happen on tap (fix
/// contract, 2026). The connect half is covered by the
/// native breadcrumbs + exit-reason machinery (a Dart test
/// cannot reproduce a device-only native death).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/ui/ember/openvpn_pages.dart';

/// Bounded pumps instead of pumpAndSettle: the Ember pages
/// carry perpetual background animations, so "settle" never
/// arrives — that is a property of the design, not a hang.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _cfgA = '''
client
dev tun
proto udp
remote alpha.example.com 1194
auth-user-pass
''';

const _cfgB = '''
client
dev tun
proto tcp
remote beta.example.com 443
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final channelCalls = <String>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ovpn_tap_test');
    channelCalls.clear();
    // Seed the profile store the controller loads from:
    // filesDir/openvpn/state.json (dataDir is filesDir/core).
    final dir = Directory('${tempDir.path}/openvpn');
    await dir.create(recursive: true);
    await File('${dir.path}/state.json').writeAsString(
      jsonEncode({
        'selectedId': 'user-a',
        'profiles': [
          {'id': 'user-a', 'name': 'Alpha', 'config': _cfgA},
          {'id': 'user-b', 'name': 'Beta', 'config': _cfgB},
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
              return <String, Object?>{
                'available': true,
                'running': false,
                'connected': false,
                'phase': 'idle',
                'profileId': '',
                'profileName': '',
                'sinceMs': 0,
                'up': 0,
                'down': 0,
                'exitIp': '',
                'exitCountry': '',
                'exitCode': '',
                'error': null,
                'logTail': <String>[],
                'lastExitReason': '',
                'lastStage': '',
                'lastException': '',
              };
            case 'openVpnCredentialStatus':
              return 'none';
            case 'openVpnHasCredentials':
              return false;
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

  testWidgets('tapping an imported profile selects it, never throws', (
    tester,
  ) async {
    final controller = OpenVpnController();
    addTearDown(controller.dispose);
    // Real file IO must run outside the fake-async zone.
    await tester.runAsync(() => controller.load());
    expect(
      controller.userProfiles.map((p) => p.name),
      ['Alpha', 'Beta'],
      reason: 'the seeded imported profiles must load whole',
    );
    expect(controller.selectedId, 'user-a');

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: OpenVpnServersView(openvpn: controller)),
      ),
    );
    await settle(tester);

    // The generic-client surface: no TunnelBear anywhere.
    expect(find.textContaining('TunnelBear'), findsNothing);

    await tester.tap(find.text('Beta'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(controller.selectedId, 'user-b');
    expect(controller.selected?.id, 'user-b');

    // A second tap moves the selection back.
    await tester.tap(find.text('Alpha'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(controller.selectedId, 'user-a');

    // The tap path must not validate or connect natively:
    // selection is a pure state change (fix contract, 2026).
    expect(channelCalls.where((m) => m == 'openVpnValidate'), isEmpty);
    expect(channelCalls.where((m) => m == 'openVpnSetOn'), isEmpty);
  });
}
