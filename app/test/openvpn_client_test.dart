/// Build 2028 tests for the generic OpenVPN client (the
/// TunnelBear Accounts flow's replacement; the 2027 originals
/// live in git history as openvpn_accounts_test.dart):
///
///  1. the import sweep (primary flow): an imported profile
///     appears, is selectable, and the connect pre-check
///     honours it per-profile ('none' → credentials-required,
///     'unreadable' → credentials-unreadable, 'ok' → setOn
///     carries needsCreds=true under the profile's own key);
///  2. the connect prompt appears for an auth profile with no
///     stored credentials, and DISMISSING it produces zero
///     native session calls (no setOn, no save);
///  3. accepting the prompt saves (visibly, per profile id)
///     and connects with the typed pair;
///  4. the log bundle reads BOTH files back through the
///     controller path the log page uses — a forced failure
///     (a terminate breadcrumb) is readable in-app (the
///     owner's 2027 "my log is empty" defect);
///  5. the log page renders the trail on screen;
///  6. the Servers view's empty state is honest and no
///     TunnelBear surface exists;
///  7. the per-profile credentials sheet round-trips:
///     none → set+save (visible outcome) → ok → remove;
///  8. the status view shows the last session's exception
///     text from the trail.
///
/// All against a FAKE vault on the app/android channel (the
/// native vault cannot run on a host JVM — its verified
/// round-trip is the shipped saveVerified/status contract
/// these mocks implement).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/core/core_api.dart';
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

class FakeVault {
  final Map<String, String> status = {};
  String saveBehavior = 'ok'; // 'ok' | 'false' | 'throw'
  bool connected = false;
  String lastException = '';
  String lastStage = '';
  final List<MethodCall> calls = [];

  List<MethodCall> callsTo(String method) =>
      calls.where((c) => c.method == method).toList();
}

const authProfileText = '''
client
dev tun
proto udp
remote vpn.example.com 1194
auth-user-pass
<ca>
-----BEGIN CERTIFICATE-----
MIIBszCCAVmgAwIBAgIUUVWvpAaBfLnDpIO+fKcvkPq+DdAwCgYIKoZIzj0EAwIw
-----END CERTIFICATE-----
</ca>
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late FakeVault vault;
  // The log-bundle tests write into the resolved desktop
  // openvpn dir (CoreLocator resolution bypasses the
  // channel mock on desktop hosts); the real files are
  // backed up in setUp and restored in tearDown.
  final Map<String, String?> logBackup = {};

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ovpn_client_test');
    vault = FakeVault();
    final ovpnDir = Directory('${CoreLocator.dataDir(const [])}/openvpn');
    for (final name in ['breadcrumbs.log', 'openvpn.log']) {
      final f = File('${ovpnDir.path}/$name');
      logBackup[name] = await f.exists() ? await f.readAsString() : null;
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), (
          call,
        ) async {
          vault.calls.add(call);
          final args =
              (call.arguments as Map?)?.cast<String, Object?>() ??
              const <String, Object?>{};
          switch (call.method) {
            case 'dataDir':
              return '${tempDir.path}/core';
            case 'openVpnSetOn':
              vault.connected = true;
              return null;
            case 'openVpnState':
              return <String, Object?>{
                'available': true,
                'running': vault.connected,
                'connected': vault.connected,
                'phase': vault.connected ? 'connected' : 'idle',
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
                'lastStage': vault.lastStage,
                'lastUnclean': vault.lastStage.isNotEmpty,
                'lastException': vault.lastException,
              };
            case 'openVpnCredentialStatus':
              return vault.status[args['key']] ?? 'none';
            case 'openVpnHasCredentials':
              return vault.status[args['key']] == 'ok';
            case 'openVpnSaveCredentials':
              switch (vault.saveBehavior) {
                case 'throw':
                  throw PlatformException(
                    code: 'vault_failed',
                    message: 'keystore blew up',
                  );
                case 'false':
                  return false;
                default:
                  vault.status[args['key'] as String] = 'ok';
                  return true;
              }
            case 'openVpnDeleteCredentials':
              vault.status[args['key'] as String] = 'none';
              return true;
            case 'openVpnValidate':
              return '';
            default:
              return null;
          }
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), null);
    final ovpnDir = Directory('${CoreLocator.dataDir(const [])}/openvpn');
    for (final name in ['breadcrumbs.log', 'openvpn.log']) {
      final f = File('${ovpnDir.path}/$name');
      final backup = logBackup[name];
      if (backup != null) {
        await f.writeAsString(backup);
      } else if (await f.exists()) {
        await f.delete();
      }
    }
    await tempDir.delete(recursive: true);
  });

  Future<OpenVpnController> loadedWithAuthProfile(
    WidgetTester tester, {
    bool autoDispose = true,
  }) async {
    final c = OpenVpnController();
    if (autoDispose) addTearDown(c.dispose);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.runAsync(() => c.load());
    final p = await tester.runAsync(
      () => c.importProfile('Work VPN', authProfileText),
    );
    expect(p, isNotNull);
    return c;
  }

  testWidgets('import sweep: imported profile honoured by the pre-check', (
    tester,
  ) async {
    final c = await loadedWithAuthProfile(tester);
    final imported = c.userProfiles.single;
    expect(imported.needsAuth, isTrue);
    expect(imported.hasInlineCredentials, isFalse);
    expect(imported.credKey, imported.id);
    c.select(imported.id);
    expect(c.selected?.id, imported.id);

    Future<String> connectError() async {
      try {
        await c.connect();
        return '';
      } on StateError catch (e) {
        return e.message;
      }
    }

    vault.status[imported.id] = 'none';
    expect(await tester.runAsync(connectError), 'credentials-required');
    expect(vault.callsTo('openVpnSetOn'), isEmpty);

    vault.status[imported.id] = 'unreadable';
    expect(await tester.runAsync(connectError), 'credentials-unreadable');
    expect(vault.callsTo('openVpnSetOn'), isEmpty);

    vault.status[imported.id] = 'ok';
    expect(await tester.runAsync(connectError), '');
    final setOn = vault.callsTo('openVpnSetOn');
    expect(setOn, hasLength(1));
    final args = (setOn.single.arguments as Map).cast<String, Object?>();
    expect(args['needsCreds'], isTrue);
    expect(args['credKey'], imported.id);
    expect(args['profileId'], imported.id);
  });

  testWidgets('prompt appears; dismissing it makes zero native calls', (
    tester,
  ) async {
    final c = await loadedWithAuthProfile(tester);
    vault.status[c.userProfiles.single.id] = 'none';
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => connectOpenVpnWithPrompt(ctx, c),
              child: const Text('GO'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('GO'));
    await settle(tester);
    // The prompt is up, titled by the profile.
    expect(find.text('Work VPN'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    // Dismiss it.
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(vault.callsTo('openVpnSetOn'), isEmpty);
    expect(vault.callsTo('openVpnSaveCredentials'), isEmpty);
  });

  testWidgets('prompt accept: saves per profile and connects', (tester) async {
    // No autoDispose: a successful connect starts the
    // controller's periodic state poller in the fake zone,
    // and the test must dispose it itself before the
    // pending-timer invariant runs.
    final c = await loadedWithAuthProfile(tester, autoDispose: false);
    final id = c.userProfiles.single.id;
    vault.status[id] = 'none';
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => connectOpenVpnWithPrompt(ctx, c),
              child: const Text('GO'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('GO'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, 'me@example.com');
    await tester.enterText(find.byType(TextField).at(1), 'hunter2');
    await tester.tap(find.text('Connect'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    final saves = vault.callsTo('openVpnSaveCredentials');
    expect(saves, hasLength(1));
    expect(
      (saves.single.arguments as Map).cast<String, Object?>()['key'],
      id,
    );
    final setOn = vault.callsTo('openVpnSetOn');
    expect(setOn, hasLength(1));
    final args = (setOn.single.arguments as Map).cast<String, Object?>();
    expect(args['user'], 'me@example.com');
    expect(args['needsCreds'], isTrue);
    c.dispose();
  });

  testWidgets('log bundle: a forced failure reads back through the UI path', (
    tester,
  ) async {
    final c = OpenVpnController();
    addTearDown(c.dispose);
    await tester.runAsync(() async {
      final dir = Directory('${CoreLocator.dataDir(const [])}/openvpn');
      await dir.create(recursive: true);
      await File('${dir.path}/breadcrumbs.log').writeAsString(
        'connect_tapped Work VPN t=1000\n'
        'run_thread_started tid=42 t=1001\n'
        'terminate std::runtime_error: harness probe t=1002\n',
      );
      await File(
        '${dir.path}/openvpn.log',
      ).writeAsString('connect: Work VPN\n');
    });
    final bundle = await tester.runAsync(() => c.readLogBundle());
    expect(bundle, isNotNull);
    expect(bundle!.trail, contains('run_thread_started'));
    expect(bundle.trail, contains('terminate std::runtime_error'));
    expect(bundle.logs, contains('connect: Work VPN'));
  });

  testWidgets('logs page renders the session trail', (tester) async {
    final c = OpenVpnController();
    addTearDown(c.dispose);
    await tester.runAsync(() async {
      final dir = Directory('${CoreLocator.dataDir(const [])}/openvpn');
      await dir.create(recursive: true);
      await File('${dir.path}/breadcrumbs.log').writeAsString(
        'connect_tapped Work VPN t=1000\n'
        'terminate std::runtime_error: harness probe t=1002\n',
      );
      await File(
        '${dir.path}/openvpn.log',
      ).writeAsString('connect: Work VPN\n');
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: OpenVpnLogsPage(openvpn: c),
      ),
    );
    // The page's future mixes a channel call (fake zone) with
    // real file IO: alternate real-async slices with pumps
    // until it lands.
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await settle(tester);
    expect(find.text('Session trail'), findsOneWidget);
    expect(find.text('Engine log'), findsOneWidget);
    expect(find.textContaining('terminate std::runtime_error'), findsWidgets);
  });

  testWidgets('servers view: honest empty state, no TunnelBear', (
    tester,
  ) async {
    final c = OpenVpnController();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: OpenVpnServersView(openvpn: c)),
      ),
    );
    await settle(tester);
    expect(
      find.textContaining('No profiles yet — import a .ovpn file'),
      findsOneWidget,
    );
    expect(find.textContaining('TunnelBear'), findsNothing);
    expect(find.textContaining('Accounts'), findsNothing);
  });

  testWidgets('credentials sheet: set, save, remove round-trip', (
    tester,
  ) async {
    final c = await loadedWithAuthProfile(tester);
    final id = c.userProfiles.single.id;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: OpenVpnServersView(openvpn: c)),
      ),
    );
    await settle(tester);
    await tester.longPress(find.text('Work VPN'));
    await settle(tester);
    expect(
      find.text('No saved credentials for this profile.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Set credentials'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, 'me@example.com');
    await tester.enterText(find.byType(TextField).at(1), 'hunter2');
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    final saves = vault.callsTo('openVpnSaveCredentials');
    expect(saves, hasLength(1));
    expect((saves.single.arguments as Map).cast<String, Object?>()['key'], id);
    expect(find.textContaining('Credentials saved for Work VPN'), findsWidgets);
    expect(
      find.text('Credentials saved on this device (keystore).'),
      findsOneWidget,
    );
    await tester.tap(find.text('Remove saved'));
    await settle(tester);
    expect(vault.callsTo('openVpnDeleteCredentials'), hasLength(1));
    expect(
      find.text('No saved credentials for this profile.'),
      findsOneWidget,
    );
  });

  testWidgets('status view shows the last session exception', (tester) async {
    vault.lastStage = 'run_thread_started';
    vault.lastException = 'std::runtime_error: harness probe';
    final c = OpenVpnController();
    addTearDown(c.dispose);
    await tester.runAsync(() => c.load());
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: OpenVpnStatusView(openvpn: c)),
      ),
    );
    await settle(tester);
    expect(
      find.textContaining('Last session stage: run_thread_started'),
      findsOneWidget,
    );
    expect(
      find.textContaining('std::runtime_error: harness probe'),
      findsOneWidget,
    );
  });
}
