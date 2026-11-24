// Fidelity rollout batch 4 renders (owner order 2026-11-23:
// the same strictness as Home R1/R2/R3 + batches 2/3 on every
// screen). These pump the REAL WireGuard home
// (WireGuardHomePage), the REAL MASQUE home (MasqueHomePage —
// the pro6-warp sample's own flavour: CLOUDFLARE · MASQUE,
// WARP+ over MASQUE · HTTP/3), the REAL Psiphon regions view
// (PsiphonRegionsView) and the REAL OpenVPN home
// (OpenVpnHomePage) at the owner's device size — 411x915
// logical (POCO X6 Pro). Iteration captures, not regression
// goldens:
//
//   flutter test --update-goldens test/batch4_render_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/aether/aether_controller.dart';
import 'package:firefox_vpn/aether/aether_platform.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/openvpn/openvpn_models.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_platform.dart';
import 'package:firefox_vpn/ui/ember/aether_pages.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/ui/ember/map_widgets.dart';
import 'package:firefox_vpn/ui/ember/openvpn_pages.dart';
import 'package:firefox_vpn/ui/ember/psiphon_pages.dart';
import 'package:firefox_vpn/ui/ember/wireguard_pages.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

import 'widget_test.dart' as wt;

/// The owner's phone: 411x915 logical.
void _device(WidgetTester tester) {
  tester.view.physicalSize = const Size(822, 1830);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

/// The shell's own ground for the surface under capture
/// (ember_shell.dart: banded = non-home tab OR a WARP/MASQUE
/// home; faint = the home tab), composed from the same
/// MapBackdropVisual the shell stacks.
Widget _ground(Widget child, {bool banded = false, bool faint = false}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Ember.bg,
      ),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        backgroundColor: Ember.bg,
        body: Stack(
          fit: StackFit.expand,
          children: [
            MapBackdropVisual(banded: banded, faint: faint),
            SafeArea(child: child),
          ],
        ),
      ),
    );

/// Real fonts, the screenshots harness's loader, plus a real
/// mono face under 'monospace' (the data tables' column).
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

/// The pro6-wireguard sample state: the owner's WarpScout
/// shape — an AmneziaWG profile selected and running, its
/// last handshake 41 s ago, the session's transfer totals.
XrayController _sampleWireGuard() {
  final xray = XrayController();
  addTearDown(xray.dispose);
  xray.profiles = [
    Profile(
      id: 'wg1',
      name: 'WarpScout · DE',
      protocol: Protocol.wireguard,
      address: '162.159.192.1',
      port: 2408,
      uuidOrPassword: '',
      security: '',
      sni: '',
      wgAllowedIPs: '0.0.0.0/0, ::/0',
      wgDns: '1.1.1.1',
      mtu: 1280,
      awgJc: '4',
      awgJmin: '40',
      awgJmax: '70',
      awgS1: '15',
      awgS2: '18',
      awgH1: '1234567890',
      awgH2: '2345678901',
      awgH3: '3456789012',
      awgH4: '4567890123',
    ),
  ];
  xray.selectedProfileId = 'wg1';
  xray.awgSession = true;
  xray.state = XrayState(
    running: true,
    name: 'wg1',
    sinceMs: DateTime.now().millisecondsSinceEpoch - 754000,
    upBytes: 96 << 20,
    downBytes: 812 << 20,
    awg: true,
    awgHandshakeAgeSec: 41,
  );
  return xray;
}

/// The pro6-warp sample state: the MASQUE slot connected
/// over HTTP/3, its Cloudflare trace answered — WARP plus,
/// Frankfurt colo, the sample's own exit address.
AetherController _sampleMasque() {
  final masque = AetherController('masque');
  addTearDown(masque.dispose);
  masque.options = const AetherOptions(
    protocol: 'masque',
    transport: 'h3',
    transportExplicit: true,
  );
  return masque;
}

void _mockAetherPlatform() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('app/android'), (
        call,
      ) async {
        if (call.method == 'aetherState') {
          return {
            'engine': 'masque',
            'running': true,
            'stage': 'connected',
            'stageLabel': 'Connected',
            'connected': true,
            'server': '162.159.193.5:2408',
            'rtt': '38 ms',
            'identity': true,
            'socksPort': 20810,
          };
        }
        if (call.method == 'xrayState') {
          return {
            'running': true,
            'name': 'MASQUE',
            'sinceMs': DateTime.now().millisecondsSinceEpoch - 754000,
            'up': 96 << 20,
            'down': 812 << 20,
          };
        }
        return null;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), null),
  );
}

/// The pro6-psiphon sample state: France picked, the
/// chain-underlay (proxy-only) mode on, the core's region
/// list carrying the sample's six rows.
PsiphonController _samplePsiphon() {
  final psiphon = PsiphonController();
  addTearDown(psiphon.dispose);
  psiphon.settings.region = 'FR';
  psiphon.settings.vpnMode = false;
  psiphon.state = const PsiphonState(
    running: true,
    connected: true,
    vpnMode: false,
    sinceMs: 0,
    upBytes: 0,
    downBytes: 0,
    region: 'FR',
    clientAddress: '',
    regions: ['FR', 'US', 'DE', 'NL', 'JP', 'SG'],
  );
  return psiphon;
}

/// The pro6-openvpn sample state: one imported profile,
/// selected, the core present, no session running.
OpenVpnController _sampleOpenVpn() {
  final openvpn = OpenVpnController();
  addTearDown(openvpn.dispose);
  openvpn.userProfiles = [
    OvpnProfile.parse(
      id: 'p1',
      name: 'office-gateway.ovpn',
      text: [
        'client',
        'dev tun',
        'proto udp',
        'remote vpn.example.net 1194',
        'cipher AES-256-GCM',
        'auth-user-pass',
      ].join('\n'),
    ),
  ];
  openvpn.selectedId = 'p1';
  return openvpn;
}

void _mockOpenVpnPlatform() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('app/android'), (
        call,
      ) async {
        if (call.method == 'openVpnState') {
          return {
            'available': true,
            'running': false,
            'connected': false,
            'phase': 'idle',
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

  testWidgets('render: wireguard home (pro6-wireguard)', (tester) async {
    wt.stillMotion(tester);
    _device(tester);
    final xray = _sampleWireGuard();
    await tester.pumpWidget(
      _ground(
        WireGuardHomePage(xray: xray, onOpenServers: () {}),
        faint: true,
      ),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/batch4-wireguard.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render: masque home (pro6-warp)', (tester) async {
    wt.stillMotion(tester);
    _device(tester);
    _mockAetherPlatform();
    final masque = _sampleMasque();
    await tester.pumpWidget(
      _ground(MasqueHomePage(masque: masque), banded: true, faint: true),
    );
    await tester.runAsync(() => masque.refresh());
    masque.exitTrace = const {
      'ip': '104.28.221.222',
      'loc': 'DE',
      'colo': 'FRA',
      'warp': 'plus',
    };
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/batch4-warp.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render: psiphon regions (pro6-psiphon)', (tester) async {
    wt.stillMotion(tester);
    _device(tester);
    final psiphon = _samplePsiphon();
    await tester.pumpWidget(
      _ground(PsiphonRegionsView(psiphon: psiphon), banded: true),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/batch4-psiphon.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render: openvpn home (pro6-openvpn)', (tester) async {
    wt.stillMotion(tester);
    _device(tester);
    _mockOpenVpnPlatform();
    final openvpn = _sampleOpenVpn();
    await tester.pumpWidget(
      // The page is a plain StatelessWidget — in the app the
      // shell rebuilds it on the controller's notifications;
      // the harness wraps it the same way.
      _ground(
        ListenableBuilder(
          listenable: openvpn,
          builder: (context, _) =>
              OpenVpnHomePage(openvpn: openvpn, onOpenServers: () {}),
        ),
        faint: true,
      ),
    );
    await tester.runAsync(() => openvpn.refresh());
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/batch4-openvpn.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
