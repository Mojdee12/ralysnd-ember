// Build 2147 (strict-audit F12): the scale-matrix extension —
// Home, the V2Ray page, the DPI Lab, WireGuard, Settings and
// App Lock at the three tuples the audit named:
// 411dp × 1.0, 360dp × 1.3, 360dp × 2.0.
//
// Same discipline as build2145_scale_matrix_test.dart: one
// testWidgets per tuple (an overflow reports only once per
// RenderObject), real fonts, and no FittedBox or clamped
// scaler to make a red cell green — a red cell means the
// layout gets fixed. F6's assertion rides along: the
// RegionHop tile's giant letters must keep a non-empty
// render box at 1.3× and 2.0× (checked in the 2145 matrix's
// tile cells; the letter token itself is pinned in
// build2147_features_test's siblings and the theme).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/aether/aether_controller.dart';
import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/lantern/lantern_controller.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/ui/ember/app_lock.dart';
import 'package:firefox_vpn/ui/ember/dpi_lab_page.dart';
import 'package:firefox_vpn/ui/ember/ember_home.dart';
import 'package:firefox_vpn/ui/ember/ember_servers.dart';
import 'package:firefox_vpn/ui/ember/ember_settings.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/ui/ember/wireguard_pages.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

import 'widget_test.dart' as wt;

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
      id: 'wg1',
      name: 'WG · Berlin',
      protocol: Protocol.wireguard,
      address: 'wg.example.net',
      port: 51820,
      delayMs: 64,
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
  ];
  return xray;
}

Future<void> _expectClean(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(tester.takeException(), isNull);
}

Widget _home() {
  final psiphon = PsiphonController();
  addTearDown(psiphon.dispose);
  final lantern = LanternController();
  addTearDown(lantern.dispose);
  final openvpn = OpenVpnController();
  addTearDown(openvpn.dispose);
  final warp = AetherController('warp');
  addTearDown(warp.dispose);
  final masque = AetherController('masque');
  addTearDown(masque.dispose);
  return EmberHome(
    core: _deadCore(),
    xray: _sampleXray(),
    psiphon: psiphon,
    lantern: lantern,
    openvpn: openvpn,
    warp: warp,
    masque: masque,
    mode: 1,
    onModeChanged: (_) {},
    onOpenServers: () {},
    onOpenAccounts: () {},
    stopOtherEngine: () async {},
  );
}

Widget _settings() {
  final psiphon = PsiphonController();
  addTearDown(psiphon.dispose);
  final lantern = LanternController();
  addTearDown(lantern.dispose);
  final openvpn = OpenVpnController();
  addTearDown(openvpn.dispose);
  return EmberSettings(
    core: _deadCore(),
    xray: _sampleXray(),
    psiphon: psiphon,
    lantern: lantern,
    openvpn: openvpn,
    settings: AppSettings()..emberMode = 1,
  );
}

void main() {
  setUpAll(_loadRealFonts);

  // (surface name, builder) — one testWidgets per tuple, the
  // 2145 discipline (a shared loop would hide overflows).
  final surfaces = <String, Widget Function()>{
    'home': _home,
    'v2ray page': () =>
        V2RayPage(xray: _sampleXray(), onOpenAccounts: () {}),
    'dpi lab': () => DpiLabPage(xray: _sampleXray(), initialProfileId: 'p1'),
    'wireguard': () => WireGuardHomePage(xray: _sampleXray(), onOpenServers: () {}),
    'settings': _settings,
    'app lock': () => AppLockPage(
      settings: AppSettings()..appLockPinHash = 'matrix-hash',
      onUnlocked: () {},
      biometricAvailable: () async => false,
    ),
  };

  for (final entry in surfaces.entries) {
    for (final (width, scale) in [(411.0, 1.0), (360.0, 1.3), (360.0, 2.0)]) {
      testWidgets(
        'matrix2147: ${entry.key} at ${width.toInt()}dp, scale $scale',
        (tester) async {
          wt.stillMotion(tester);
          _surface(tester, width);
          await tester.pumpWidget(_app(entry.value(), scale));
          await _expectClean(tester);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
