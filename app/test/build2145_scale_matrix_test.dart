// Build 2145 (UI-review fix A4): the device × text-scale
// matrix for the scale-sensitive compositions.
//
// The golden set pins exactly one surface (390×844, scale
// 1.0); the recomposed app carries figures whose layout a
// FittedBox used to absorb (hero numerals, the 230 dp ring,
// the giant RegionHop letters — the FittedBoxes themselves
// were retired by fix A9). Per the widget_golden_a11y skill:
// one testWidgets per device × scale tuple (each RenderObject
// reports its overflow only once, so a shared loop would hide
// all but the first), real fonts loaded (the harness font is
// wider than Roboto and would cry wolf), and NO FittedBox /
// clamped scaler anywhere to make a red cell green — a red
// cell means the layout gets fixed.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/aether/aether_controller.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/regionhop/regionhop_client.dart';
import 'package:firefox_vpn/ui/ember/aether_pages.dart';
import 'package:firefox_vpn/ui/ember/ember_accounts.dart';
import 'package:firefox_vpn/ui/ember/ember_servers.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/ui/ember/regionhop_page.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

import 'widget_test.dart' as wt;

/// The same real-font loading the screenshot harness uses
/// (screenshots_test.dart): Roboto + Material Icons from the
/// SDK's material_fonts artifact, so text metrics are the
/// phone's, not the harness's same-width boxes.
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
}

void _surface(WidgetTester tester, double widthDp) {
  tester.view.physicalSize = Size(widthDp * 2, 1688);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

/// The page under test on the app's banded ground, with the
/// ambient text scaler replaced by [scale] — the builder
/// override is how a test sets the scale the widgets read.
Widget _app(Widget child, double scale) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Ember.bg,
  ),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, c) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(scale)),
    child: c!,
  ),
  home: Scaffold(
    backgroundColor: Ember.bg,
    body: EmberBackground(banded: true, child: SafeArea(child: child)),
  ),
);

CoreController _deadCore() {
  final core = CoreController(
    () async => throw const CoreUnavailable(CoreProblem.refused, 'matrix'),
  );
  addTearDown(core.dispose);
  return core;
}

/// Sample state in the screenshot harness's shape: two
/// subscriptions with traffic figures (the group-head numeral
/// + bar), a selected profile inside a 3-member subscription
/// (the fallback-group header), measured delays.
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
  ];
  xray.selectedProfileId = 'p1';
  xray.subscriptions = [
    Subscription(
      id: 'sub1',
      name: 'My Panel With A Long Name',
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

Future<void> _expectClean(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(tester.takeException(), isNull);
}

void _noop() {}

Widget _tile() => const RegionHopLocationTile(
  location: RegionHopLocation(
    name: 'de',
    region: 'de - Germany',
    socksPort: 19000,
    status: 'active',
    statusClass: 'active',
    exitRegion: 'de - Germany',
  ),
  relay: RegionHopRelay(name: 'de', port: 26000, user: 'rh-de', password: 'x'),
  probe: null,
  sessionHere: false,
  sessionVerified: false,
  stale: false,
  connectBusy: false,
  probing: false,
  acting: false,
  onCheck: _noop,
  onStart: _noop,
  onStop: _noop,
  onConnect: _noop,
  onDisconnect: _noop,
);

void main() {
  setUpAll(_loadRealFonts);

  testWidgets('matrix: servers at 360dp, text scale 1.3', (tester) async {
    wt.stillMotion(tester);
    _surface(tester, 360);
    await tester.pumpWidget(
      _app(
        EmberServers(
          core: _deadCore(),
          xray: _sampleXray(),
          v2ray: true,
          onOpenAccounts: () {},
        ),
        1.3,
      ),
    );
    await _expectClean(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('matrix: servers at 360dp, text scale 2.0', (tester) async {
    wt.stillMotion(tester);
    _surface(tester, 360);
    await tester.pumpWidget(
      _app(
        EmberServers(
          core: _deadCore(),
          xray: _sampleXray(),
          v2ray: true,
          onOpenAccounts: () {},
        ),
        2.0,
      ),
    );
    await _expectClean(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('matrix: servers at 320dp, text scale 1.3', (tester) async {
    wt.stillMotion(tester);
    _surface(tester, 320);
    await tester.pumpWidget(
      _app(
        EmberServers(
          core: _deadCore(),
          xray: _sampleXray(),
          v2ray: true,
          onOpenAccounts: () {},
        ),
        1.3,
      ),
    );
    await _expectClean(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('matrix: subscriptions at 360dp, text scale 2.0', (
    tester,
  ) async {
    wt.stillMotion(tester);
    _surface(tester, 360);
    await tester.pumpWidget(
      _app(
        EmberAccounts(core: _deadCore(), xray: _sampleXray(), v2ray: true),
        2.0,
      ),
    );
    await _expectClean(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('matrix: regionhop tile at 360dp, text scale 2.0', (
    tester,
  ) async {
    wt.stillMotion(tester);
    _surface(tester, 360);
    await tester.pumpWidget(_app(_tile(), 2.0));
    await _expectClean(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('matrix: regionhop page at 360dp, text scale 1.3', (
    tester,
  ) async {
    wt.stillMotion(tester);
    _surface(tester, 360);
    final xray = XrayController();
    addTearDown(xray.dispose);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Ember.bg,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, c) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: c!,
        ),
        home: RegionHopPage(xray: xray),
      ),
    );
    await _expectClean(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('matrix: masque home at 360dp, text scale 1.3', (tester) async {
    wt.stillMotion(tester);
    _surface(tester, 360);
    final masque = AetherController('masque');
    addTearDown(masque.dispose);
    await tester.pumpWidget(_app(MasqueHomePage(masque: masque), 1.3));
    await _expectClean(tester);
    await tester.pumpWidget(const SizedBox());
  });

}
