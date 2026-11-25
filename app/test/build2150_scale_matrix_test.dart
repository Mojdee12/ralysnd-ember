// Build 2150 (engine appearance audit E49-18): the
// scale-matrix cells the 2147/2149 matrices never
// covered — Mozilla Locations, Lantern, Psiphon,
// OpenVPN, WARP and MASQUE, RegionHop, the Accounts /
// Subscriptions page, and the two pages build 2149
// shipped (Daily report, DNS presets). Several of these
// surfaces changed shape in this very build (the ✕
// removals, the Psiphon settled ground, the RegionHop
// tile declutter, the two AppBar titles), so their first
// matrix cells land with the changes they verify.
//
// Same discipline as build2149_scale_matrix_test.dart:
// one testWidgets per tuple, real fonts, no FittedBox or
// clamped scaler to make a red cell green (the Home
// switcher's own scale-down fit is the widget's shipped
// design, not a harness device). Tuples: the owner's
// phone shape 411×915 at text scales 1.0 and 1.3, plus
// the narrow 360dp at 2.0.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/aether/aether_controller.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/lantern/lantern_controller.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/ui/ember/aether_pages.dart';
import 'package:firefox_vpn/ui/ember/daily_report_page.dart';
import 'package:firefox_vpn/ui/ember/dns_presets_page.dart';
import 'package:firefox_vpn/ui/ember/ember_accounts.dart';
import 'package:firefox_vpn/ui/ember/ember_servers.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/ui/ember/lantern_pages.dart';
import 'package:firefox_vpn/ui/ember/openvpn_pages.dart';
import 'package:firefox_vpn/ui/ember/psiphon_pages.dart';
import 'package:firefox_vpn/ui/ember/regionhop_page.dart';
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

void _surface(WidgetTester tester, double widthDp, double heightDp) {
  tester.view.physicalSize = Size(widthDp * 2, heightDp * 2);
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

Profile _profile({
  required String id,
  required String name,
  String subscriptionId = '',
}) => Profile(
  id: id,
  name: name,
  protocol: Protocol.vless,
  address: 'de1.example.net',
  port: 443,
  security: 'reality',
  network: 'tcp',
  delayMs: 86,
  subscriptionId: subscriptionId,
);

XrayController _sampleXray() {
  final xray = XrayController();
  addTearDown(xray.dispose);
  xray.profiles = [
    _profile(id: 'p1', name: 'Frankfurt · Reality', subscriptionId: 'sub1'),
  ];
  xray.selectedProfileId = 'p1';
  xray.subscriptions = [
    Subscription(
      id: 'sub1',
      name: 'My Panel With A Long Name',
      url: 'https://panel.example.net/sub/rayan',
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

void main() {
  setUpAll(_loadRealFonts);

  final surfaces = <String, Widget Function()>{
    'mozilla locations': () => EmberServers(
      core: _deadCore(),
      xray: _sampleXray(),
      v2ray: false,
      onOpenAccounts: () {},
    ),
    'lantern': () {
      final lantern = LanternController();
      addTearDown(lantern.dispose);
      return LanternServersView(lantern: lantern);
    },
    'psiphon regions': () {
      final psiphon = PsiphonController();
      addTearDown(psiphon.dispose);
      return PsiphonRegionsView(psiphon: psiphon);
    },
    'openvpn': () {
      final openvpn = OpenVpnController();
      addTearDown(openvpn.dispose);
      return OpenVpnServersView(openvpn: openvpn);
    },
    'warp endpoints': () =>
        AetherServersView(controller: AetherController('cfwarp')),
    'masque endpoints': () =>
        AetherServersView(controller: AetherController('masque')),
    'regionhop': () => RegionHopPage(xray: _sampleXray()),
    'daily report': () => DailyReportPage(xray: _sampleXray()),
    'dns presets': () => const DnsPresetsPage(
      target: DnsPresetTarget.remote,
      currentValue: '',
    ),
    'subscriptions': () => EmberAccounts(
      core: _deadCore(),
      xray: _sampleXray(),
      v2ray: true,
    ),
    'mozilla accounts': () => EmberAccounts(
      core: _deadCore(),
      xray: _sampleXray(),
      v2ray: false,
    ),
  };

  for (final entry in surfaces.entries) {
    for (final (width, height, scale) in [
      (411.0, 915.0, 1.0),
      (411.0, 915.0, 1.3),
      (360.0, 800.0, 2.0),
    ]) {
      testWidgets(
        'matrix2150: ${entry.key} at ${width.toInt()}x${height.toInt()}, '
        'scale $scale',
        (tester) async {
          wt.stillMotion(tester);
          _surface(tester, width, height);
          await tester.pumpWidget(_app(entry.value(), scale));
          await _expectClean(tester);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
