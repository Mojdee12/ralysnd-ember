/// Build 2148 — owner approval renders (process order
/// 2026-11-24: renders FIRST, his approval, then the build).
/// These pump the REAL screens with sample state at the
/// owner's device size (411x915, POCO X6 Pro) and write PNGs
/// under test/screenshots/ember2148-*.png:
///
///   flutter test --update-goldens test/build2148_renders_test.dart
///
/// (a) servers rows — small health-coloured pings, small red
///     Failed, full server names (FIX 1);
/// (b) mozilla locations as one full page (FIX 2);
/// (c) lantern servers tab — fine halftone ground, BACK
///     header, dark disconnected tray pill (FIX 3/4/5);
/// (d) wireguard servers tab — BACK header (FIX 3);
/// (e) mozilla locations while CONNECTED — orange tray pill
///     (FIX 5);
/// (f/g) home slim-bar pair — connected orange DISCONNECT /
///     disconnected dark CONNECT (FIX 5).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide appBuildNumber;
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/ui/app.dart';
import 'package:firefox_vpn/ui/ember/dpi_lab_page.dart';
import 'package:firefox_vpn/ui/ember/ember_servers.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

import 'widget_test.dart' as wt;

/// The owner's phone: 411x915 logical.
void _device(WidgetTester tester) {
  tester.view.physicalSize = const Size(822, 1830);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

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

  const dir =
      '/home/hatch/workspace/ember-app/toolchain/flutter/bin/cache/artifacts/material_fonts';
  await load('Roboto', [
    '$dir/Roboto-Regular.ttf',
    '$dir/Roboto-Medium.ttf',
    '$dir/Roboto-Bold.ttf',
    '$dir/Roboto-Italic.ttf',
    '$dir/Roboto-BoldItalic.ttf',
  ]);
  await load('MaterialIcons', ['$dir/MaterialIcons-Regular.otf']);
  await load('monospace', const [
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
  ]);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 600)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// A page on the app's own ground (the batch harnesses'
/// composition for tab surfaces).
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

CoreController _deadCore() {
  final core = CoreController(
    () async => throw const CoreUnavailable(CoreProblem.refused, 'shots'),
  );
  addTearDown(core.dispose);
  return core;
}

/// Sample V2Ray state in the owner's shape: long provider
/// names, a spread of delays (fast / mid / slow), one failed
/// config, per-config traffic totals.
XrayController _sampleXray() {
  final xray = XrayController();
  addTearDown(xray.dispose);
  final now = DateTime.now();
  Profile p({
    required String id,
    required String name,
    required Protocol protocol,
    required String address,
    String security = '',
    String network = 'tcp',
    int delayMs = -1,
    bool delayFailed = false,
    String sub = '',
    int up = 0,
    int down = 0,
  }) => Profile(
    id: id,
    name: name,
    protocol: protocol,
    address: address,
    port: 443,
    security: security,
    network: network,
    delayMs: delayMs,
    delayFailed: delayFailed,
    subscriptionId: sub,
    totalUpBytes: up,
    totalDownBytes: down,
  );
  xray.profiles = [
    p(
      id: 'p1',
      name: 'Senpai-Germany-Frankfurt-Reality-01',
      protocol: Protocol.vless,
      address: 'de1.example.net',
      security: 'reality',
      delayMs: 477,
      down: 98 << 20,
      up: 4 << 20,
    ),
    p(
      id: 'p2',
      name: 'Senpai-Netherlands-Amsterdam-Vision',
      protocol: Protocol.vless,
      address: 'nl2.example.net',
      security: 'tls',
      delayFailed: true,
      down: 141 << 10,
      up: 35 << 10,
    ),
    p(
      id: 'p3',
      name: 'Senpai-Germany-Berlin-Trojan',
      protocol: Protocol.trojan,
      address: 'de2.example.net',
      security: 'tls',
      delayMs: 86,
      down: 53 << 30,
      up: 217 << 20,
    ),
    p(
      id: 'p4',
      name: 'Nova-smart-gate-998df6-gw-Domain',
      protocol: Protocol.vless,
      address: 'gw.example.net',
      security: 'tls',
      network: 'ws',
      delayMs: 210,
      sub: 'sub2',
    ),
    p(
      id: 'p5',
      name: 'Tokyo · Shadowsocks',
      protocol: Protocol.shadowsocks,
      address: 'jp3.example.net',
      delayMs: 318,
      sub: 'sub2',
    ),
  ];
  xray.selectedProfileId = 'p1';
  xray.subscriptions = [
    Subscription(
      id: 'sub2',
      name: 'u',
      url: 'https://panel.example.net/sub/rayan',
      profileCount: 95,
      lastUpdatedMs: now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
    ),
  ];
  return xray;
}

/// The full shell (the header test's pump): 411x915, the
/// xray platform channel mocked idle.
Future<CoreController> _pumpShell(
  WidgetTester tester, {
  int mode = 0,
  bool fakeOn = true,
}) async {
  wt.stillMotion(tester);
  _device(tester);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(const MethodChannel('app/android'), (
    call,
  ) async {
    if (call.method == 'lanternState') {
      // The batch3 sample fleet: the owner's private server
      // plus two public rows.
      return {
        'available': true,
        'running': false,
        'coreRunning': false,
        'connected': false,
        'stage': 'idle',
        'servers': 3,
        'serversJson': jsonEncode([
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
        ]),
        'smartRouting': false,
      };
    }
    if (call.method == 'xrayState') {
      return <String, Object?>{
        'running': false,
        'name': '',
        'sinceMs': 0,
        'up': 0,
        'down': 0,
        'coreRestarts': 0,
        'coreProblem': '',
        'chainUnderlay': false,
        'chainProblem': '',
        'awg': false,
        'awgConfig': '',
        'rotationGen': 0,
      };
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(
      const MethodChannel('app/android'),
      null,
    ),
  );
  final core = CoreController(
    () async => wt.FakeApi()..on = fakeOn,
    pollInterval: const Duration(hours: 1),
  );
  await tester.pumpWidget(
    VpnApp(core: core, settings: AppSettings()..emberMode = mode),
  );
  core.start();
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
  }
  return core;
}

/// The home_r1 harness's seeded shell: a store file with
/// real profiles, the platform channel answering a running
/// (or idle) Xray session — V2Ray mode Home, connected or
/// not, for the slim-bar pair.
Future<CoreController> _pumpHomeShell(
  WidgetTester tester, {
  required bool connected,
}) async {
  wt.stillMotion(tester);
  _device(tester);
  final tmp = Directory.systemTemp.createTempSync('ember_2148_');
  addTearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });
  Directory('${tmp.path}/xray').createSync(recursive: true);
  Profile prof(String id, String name, int delay) => Profile(
    id: id,
    name: name,
    protocol: Protocol.vless,
    address: 'de1.example.net',
    port: 443,
    security: 'reality',
    network: 'tcp',
    delayMs: delay,
    subscriptionId: 'sub1',
  );
  File('${tmp.path}/xray/state.json').writeAsStringSync(
    jsonEncode({
      'profiles': [
        prof('p1', 'Germany · Frankfurt Reality', 38).toJson(),
        prof('p2', 'Netherlands · Amsterdam XHTTP', 64).toJson(),
      ],
      'subscriptions': [
        Subscription(
          id: 'sub1',
          name: 'My Panel',
          url: 'https://panel.example.net/sub/rayan',
          profileCount: 2,
        ).toJson(),
      ],
      'selectedProfileId': 'p1',
      'connectedProfileId': 'p1',
    }),
  );
  final sinceMs = DateTime.now().millisecondsSinceEpoch - 161000;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(const MethodChannel('app/android'), (
    call,
  ) async {
    switch (call.method) {
      case 'dataDir':
        return '${tmp.path}/core';
      case 'xrayState':
        return <String, Object?>{
          'running': connected,
          'name': connected ? 'Germany · Frankfurt Reality' : '',
          'sinceMs': connected ? sinceMs : 0,
          'up': 1234567,
          'down': 7654321,
          'coreRestarts': 0,
          'coreProblem': '',
          'chainUnderlay': false,
          'chainProblem': '',
          'awg': false,
          'awgConfig': '',
          'rotationGen': 0,
        };
      case 'xrayExitInfo':
        return <String, String>{
          'ip': '72.56.106.210',
          'countryCode': 'DE',
          'country': 'Germany',
        };
      default:
        return null;
    }
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(
      const MethodChannel('app/android'),
      null,
    ),
  );
  final core = CoreController(
    () async => wt.FakeApi()..on = false,
    pollInterval: const Duration(hours: 1),
  );
  await tester.pumpWidget(
    VpnApp(core: core, settings: AppSettings()..emberMode = 1),
  );
  core.start();
  for (var i = 0; i < 14; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
  }
  return core;
}

void main() {
  setUpAll(_loadRealFonts);

  testWidgets('render (a): servers rows — small pings, full names', (
    tester,
  ) async {
    wt.stillMotion(tester);
    _device(tester);
    await tester.pumpWidget(
      _ground(
        EmberServers(
          core: _deadCore(),
          xray: _sampleXray(),
          v2ray: true,
          onOpenAccounts: () {},
        ),
      ),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2148-servers-rows.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (b): mozilla locations — one full page', (
    tester,
  ) async {
    wt.stillMotion(tester);
    _device(tester);
    final core = CoreController(
      () async => wt.FakeApi(),
      pollInterval: const Duration(hours: 1),
    );
    final xray = XrayController();
    // The picker loads through core.call in initState, which
    // needs the core booted — boot BEFORE the first pump
    // (in the shell the tab mounts long after boot).
    core.start();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pumpWidget(
      _ground(
        EmberServers(
          core: core,
          xray: xray,
          v2ray: false,
          onOpenAccounts: () {},
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
    }
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2148-mozilla-locations.png'),
    );
    await tester.pumpWidget(const SizedBox());
    core.dispose();
    xray.dispose();
  });

  testWidgets('render (c): lantern page — fine map + BACK', (tester) async {
    final core = await _pumpShell(tester, fakeOn: false);
    await tester.tap(find.text('Lantern'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Locations'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(VpnApp),
      matchesGoldenFile('screenshots/ember2148-lantern-page.png'),
    );
    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });

  testWidgets('render (d): wireguard page — BACK header', (tester) async {
    final core = await _pumpShell(tester, fakeOn: false);
    await tester.tap(find.text('WireGuard'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Locations'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(VpnApp),
      matchesGoldenFile('screenshots/ember2148-wireguard-page.png'),
    );
    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });

  testWidgets('render (e): connected — orange tray pill', (tester) async {
    // FakeApi default (on = true) is a running Mozilla: the
    // shell sits Connected, and the Locations tab carries
    // the FULL bar — its pill must be orange now.
    final core = await _pumpShell(tester, fakeOn: true);
    await tester.tap(find.byTooltip('Locations'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(VpnApp),
      matchesGoldenFile('screenshots/ember2148-connected-bar.png'),
    );
    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });

  testWidgets('render (h): dpi lab profile picker — full page', (
    tester,
  ) async {
    // FIX 7 (class 6): the Lab's config picker, formerly a
    // half-height bottom sheet, as the pushed full page it
    // is now. Two eligible profiles so the list reads as a
    // chooser.
    wt.stillMotion(tester);
    _device(tester);
    final xray = XrayController();
    xray.profiles = [
      Profile(
        id: 'p1',
        name: 'CF · VLESS · Reality',
        protocol: Protocol.vless,
        address: 'de1.example.net',
        port: 443,
        security: 'reality',
        network: 'tcp',
        delayMs: 212,
      ),
      Profile(
        id: 'p2',
        name: 'Nova-smart-gate-998df6-gw-Domain',
        protocol: Protocol.vless,
        address: 'gw.example.net',
        port: 443,
        security: 'tls',
        network: 'ws',
        delayMs: 477,
      ),
    ];
    xray.selectedProfileId = 'p1';
    await tester.pumpWidget(
      _ground(DpiLabPage(xray: xray, initialProfileId: 'p1')),
    );
    await _settle(tester);
    await tester.tap(find.text('CF · VLESS · Reality'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2148-lab-picker.png'),
    );
    await tester.pumpWidget(const SizedBox());
    xray.dispose();
  });

  testWidgets('render (f): home connected — orange DISCONNECT', (
    tester,
  ) async {
    final core = await _pumpHomeShell(tester, connected: true);
    await expectLater(
      find.byType(VpnApp),
      matchesGoldenFile('screenshots/ember2148-home-connected.png'),
    );
    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });

  testWidgets('render (g): home disconnected — dark CONNECT', (
    tester,
  ) async {
    final core = await _pumpHomeShell(tester, connected: false);
    await expectLater(
      find.byType(VpnApp),
      matchesGoldenFile('screenshots/ember2148-home-disconnected.png'),
    );
    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });
}
