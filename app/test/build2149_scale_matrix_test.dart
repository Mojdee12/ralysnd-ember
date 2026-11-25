// Build 2149 (audit A48-07): the scale-matrix cells the
// 2147 matrix lacked — the surfaces that shipped
// code-only in 2147/2148: the Quarantine / SNI scan /
// Diagnosis pages, the profile editor, the chain
// builder, the logs page and the recycle bin.
//
// Same discipline as build2147_scale_matrix_test.dart:
// one testWidgets per tuple, real fonts, no FittedBox or
// clamped scaler to make a red cell green. Tuples: the
// owner's phone shape 411×915 at text scales 1.0 and 1.3,
// plus the narrow 360dp at 2.0.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/lantern/lantern_controller.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/ui/ember/chain_builder_page.dart';
import 'package:firefox_vpn/ui/ember/ember_logs_page.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/ui/ember/iran_pages_2147.dart';
import 'package:firefox_vpn/ui/ember/profile_editor.dart';
import 'package:firefox_vpn/ui/ember/recycle_bin_page.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
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
  bool quarantined = false,
  String quarantineReason = '',
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
  quarantined: quarantined,
  quarantineReason: quarantineReason,
  subscriptionId: subscriptionId,
);

XrayController _sampleXray() {
  final xray = XrayController();
  addTearDown(xray.dispose);
  final deleted = _profile(
    id: 'gone1',
    name: 'Deleted · Reality',
    subscriptionId: 'sub1',
  );
  xray.profiles = [
    _profile(id: 'p1', name: 'Frankfurt · Reality', subscriptionId: 'sub1'),
    _profile(
      id: 'q1',
      name: 'Stale · XHTTP',
      quarantined: true,
      quarantineReason: 'Ping sweep: no answer in 3 consecutive sweeps',
      subscriptionId: 'sub1',
    ),
  ];
  xray.selectedProfileId = 'p1';
  xray.subscriptions = [
    Subscription(
      id: 'sub1',
      name: 'My Panel With A Long Name',
      url: 'https://panel.example.net/sub/rayan',
      profileCount: 24,
      deletedProfileKeys: [profileTombstoneKey(deleted)],
      deletedProfileData: {
        profileTombstoneKey(deleted): deleted.toJson(),
      },
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
    'quarantine': () => QuarantinePage2147(xray: _sampleXray()),
    'sni scan': () => const SniScanPage2147(),
    'diagnosis': () => DiagnosisPage2147(xray: _sampleXray()),
    'profile editor': () => ProfileEditorPage(
      xray: _sampleXray(),
      existing: _profile(id: 'p1', name: 'Frankfurt · Reality'),
    ),
    'chain builder': () => ChainBuilderPage(
      xray: _sampleXray(),
      settings: AppSettings(),
    ),
    'logs': () {
      final psiphon = PsiphonController();
      addTearDown(psiphon.dispose);
      final lantern = LanternController();
      addTearDown(lantern.dispose);
      final openvpn = OpenVpnController();
      addTearDown(openvpn.dispose);
      return EmberLogsPage(
        core: _deadCore(),
        xray: _sampleXray(),
        psiphon: psiphon,
        lantern: lantern,
        openvpn: openvpn,
      );
    },
    'recycle bin': () => RecycleBinPage(xray: _sampleXray()),
  };

  for (final entry in surfaces.entries) {
    for (final (width, height, scale) in [
      (411.0, 915.0, 1.0),
      (411.0, 915.0, 1.3),
      (360.0, 800.0, 2.0),
    ]) {
      testWidgets(
        'matrix2149: ${entry.key} at ${width.toInt()}x${height.toInt()}, '
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
