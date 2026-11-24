// Fidelity rollout batch 3 renders (owner order 2026-11-23:
// the same strictness as Home R1/R2/R3 + batch 2 on every
// screen). These pump the REAL V2Ray full page (V2RayPage),
// the REAL Mozilla account surface (EmberAccounts, Mozilla
// mode) and the REAL Lantern servers view (LanternServersView)
// at the owner's device size — 411x915 logical (POCO X6 Pro).
// Iteration captures, not regression goldens:
//
//   flutter test --update-goldens test/batch3_render_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/core/models.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/lantern/lantern_controller.dart';
import 'package:firefox_vpn/ui/ember/ember_accounts.dart';
import 'package:firefox_vpn/ui/ember/ember_servers.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/ui/ember/lantern_pages.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

import 'widget_test.dart' as wt;

/// The owner's phone: 411x915 logical.
void _device(WidgetTester tester) {
  tester.view.physicalSize = const Size(822, 1830);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

CoreController _deadCore() {
  final core = CoreController(
    () async => throw const CoreUnavailable(CoreProblem.refused, 'shots'),
  );
  addTearDown(core.dispose);
  return core;
}

/// The screenshots harness's sample state, verbatim: six
/// configs across two subscriptions, a spread of delays,
/// the Frankfurt config selected.
XrayController _sampleXray() {
  final xray = XrayController();
  addTearDown(xray.dispose);
  final now = DateTime.now();
  xray.profiles = [
    Profile(
      id: 'p1',
      name: 'Frankfurt · Reality',
      protocol: Protocol.vless,
      address: 'de1.example.net',
      port: 443,
      security: 'reality',
      network: 'tcp',
      delayMs: 86,
      subscriptionId: 'sub1',
    ),
    Profile(
      id: 'p2',
      name: 'Amsterdam · XHTTP',
      protocol: Protocol.vless,
      address: 'nl2.example.net',
      port: 443,
      security: 'tls',
      network: 'xhttp',
      delayMs: 132,
      subscriptionId: 'sub1',
    ),
    Profile(
      id: 'p3',
      name: 'Istanbul · Hysteria2',
      protocol: Protocol.hysteria2,
      address: 'tr1.example.net',
      port: 443,
      delayMs: 64,
      subscriptionId: 'sub1',
    ),
    Profile(
      id: 'p4',
      name: 'London · Trojan',
      protocol: Protocol.trojan,
      address: 'uk1.example.net',
      port: 443,
      security: 'tls',
      delayMs: 210,
      subscriptionId: 'sub2',
    ),
    Profile(
      id: 'p5',
      name: 'Tokyo · Shadowsocks',
      protocol: Protocol.shadowsocks,
      address: 'jp3.example.net',
      port: 8388,
      method: 'aes-256-gcm',
      delayMs: 318,
      subscriptionId: 'sub2',
    ),
    Profile(
      id: 'p6',
      name: 'Warsaw · VMess',
      protocol: Protocol.vmess,
      address: 'pl1.example.net',
      port: 443,
      security: 'tls',
      network: 'ws',
      subscriptionId: 'sub2',
    ),
  ];
  xray.selectedProfileId = 'p1';
  xray.subscriptions = [
    Subscription(
      id: 'sub1',
      name: 'My Panel',
      url: 'https://panel.example.net/sub/rayan',
      uploadBytes: 12 << 30,
      downloadBytes: 30 << 30,
      totalBytes: 100 << 30,
      expireEpochSec:
          now.add(const Duration(days: 21)).millisecondsSinceEpoch ~/ 1000,
      lastUpdatedMs: now
          .subtract(const Duration(hours: 3))
          .millisecondsSinceEpoch,
      profileCount: 24,
    ),
    Subscription(
      id: 'sub2',
      name: 'Backup Provider',
      url: 'https://backup.example.net/link/token',
      uploadBytes: 9 << 30,
      downloadBytes: 31 << 30,
      totalBytes: 50 << 30,
      expireEpochSec:
          now.add(const Duration(days: 6)).millisecondsSinceEpoch ~/ 1000,
      lastUpdatedMs: now
          .subtract(const Duration(days: 1))
          .millisecondsSinceEpoch,
      profileCount: 9,
    ),
  ];
  return xray;
}

/// A page on the app's own ground, composed exactly as the
/// screenshots harness composes the tab surfaces: the banded
/// backdrop inside a Scaffold body over Ember.bg.
Widget _ground(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Ember.bg,
  ),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    backgroundColor: Ember.bg,
    body: EmberBackground(banded: true, child: SafeArea(child: child)),
  ),
);

/// A full-screen page that carries its own Scaffold (the
/// V2RayPage shape): the app shell around it only.
Widget _pageGround(Widget page) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Ember.bg,
  ),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: page,
);

/// Real fonts, the screenshots harness's loader, plus a real
/// mono face under 'monospace' (the rows' meta line).
Future<void> _loadRealFonts() async {
  Future<void> load(String family, List<String> files) async {
    if (!files.every((f) => File(f).existsSync())) return;
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = await File(f).readAsBytes();
      loader.addFont(
        Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)),
      );
    }
    await loader.load();
  }

  final sdkFonts = [
    if (Platform.environment['FLUTTER_ROOT'] != null)
      '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts',
    '/home/hatch/workspace/ember-app/toolchain/flutter/bin/cache/artifacts/material_fonts',
  ];
  for (final dir in sdkFonts) {
    await load('Roboto', [
      '$dir/Roboto-Regular.ttf',
      '$dir/Roboto-Medium.ttf',
      '$dir/Roboto-Bold.ttf',
      '$dir/Roboto-Italic.ttf',
      '$dir/Roboto-BoldItalic.ttf',
    ]);
    await load('MaterialIcons', ['$dir/MaterialIcons-Regular.otf']);
  }
  await load('monospace', const [
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
  ]);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  // Let the backdrop decode finish, then settle a frame.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 600)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// The Lantern sample state: the core's list carrying the
/// owner's private server (Ohio) plus two public rows, the
/// controller in Private mode with the key saved — the
/// owner's real shape, no session running.
LanternController _sampleLantern() {
  final lantern = LanternController();
  addTearDown(lantern.dispose);
  lantern.privateMode = true;
  lantern.privateKey = 'lantern://render-sample-key';
  lantern.privateName = 'rayan';
  lantern.privateCountry = 'United States';
  lantern.privateCode = 'US';
  return lantern;
}

void _mockLanternPlatform() {
  final servers = [
    {
      'tag': 'rayan-ohio',
      'city': 'Ohio',
      'country': 'United States',
      'countryCode': 'US',
      'isLantern': false,
    },
    {
      'tag': 'us-free-1',
      'city': 'New York',
      'country': 'United States',
      'countryCode': 'US',
      'isLantern': true,
    },
    {
      'tag': 'de-free-1',
      'city': 'Frankfurt',
      'country': 'Germany',
      'countryCode': 'DE',
      'isLantern': true,
    },
  ];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('app/android'), (
        call,
      ) async {
        if (call.method == 'lanternState') {
          return {
            'available': true,
            'running': false,
            'coreRunning': false,
            'connected': false,
            'stage': 'idle',
            'servers': 3,
            'serversJson': jsonEncode(servers),
            'smartRouting': false,
          };
        }
        return null;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), null),
  );
}

void main() {
  setUpAll(_loadRealFonts);

  testWidgets('render: v2ray full page (pro6-v2ray)', (tester) async {
    wt.stillMotion(tester);
    _device(tester);
    final xray = _sampleXray();
    await tester.pumpWidget(
      _pageGround(V2RayPage(xray: xray, onOpenAccounts: () {})),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/batch3-v2ray.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render: mozilla accounts (pro6-mozilla)', (tester) async {
    wt.stillMotion(tester);
    _device(tester);
    final core = _deadCore();
    core.accounts = AccountList.fromJson({
      'accounts': [
        {
          'id': 'acc1',
          'name': 'Sample Account',
          'email': 'user@example.net',
          'position': 0,
          'enabled': true,
          'active': true,
          'status': 'ready',
          'usage': {
            'unlimited': false,
            'limit_bytes': 50 << 30,
            'remaining_bytes': 32 << 30,
          },
          'used_percent': 36.0,
          'has_password': true,
        },
      ],
      'switch_threshold_percent': 80.0,
    });
    await tester.pumpWidget(
      _ground(EmberAccounts(core: core, xray: _sampleXray(), v2ray: false)),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/batch3-mozilla.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render: lantern servers (pro6-lantern)', (tester) async {
    wt.stillMotion(tester);
    _device(tester);
    _mockLanternPlatform();
    final lantern = _sampleLantern();
    await tester.pumpWidget(_ground(LanternServersView(lantern: lantern)));
    await tester.runAsync(() => lantern.refresh());
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/batch3-lantern.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
