// Fidelity rollout batch 5 renders (owner order 2026-11-23:
// the same strictness as Home R1–R4 + batches 2–4 on every
// screen). The FINAL screen batch: Settings index, DNS,
// Routing, Diagnostics (the leak-test surface), Backup,
// RegionHop, DPI Lab, App Lock — pumped at the owner's
// device size, 411x915 logical (POCO X6 Pro). Iteration
// captures, not regression goldens:
//
//   flutter test --update-goldens test/batch5_render_test.dart
import 'dart:convert';
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
import 'package:firefox_vpn/ui/ember/app_lock.dart';
import 'package:firefox_vpn/ui/ember/dpi_lab_page.dart';
import 'package:firefox_vpn/ui/ember/ember_settings.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/ui/ember/leak_test_page.dart';
import 'package:firefox_vpn/ui/ember/map_widgets.dart';
import 'package:firefox_vpn/ui/ember/regionhop_page.dart';
import 'package:firefox_vpn/xray/dpi_lab.dart';
import 'package:firefox_vpn/xray/exit_info.dart';
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

/// The shell's own ground for a surface the shell hosts
/// (ember_shell.dart: banded = non-home tab), composed from
/// the same MapBackdropVisual the shell stacks.
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

/// A page that carries its own Scaffold (RegionHop, the
/// Lab, the leak test, the lock) pumped as the app root.
Widget _page(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Ember.bg,
  ),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

/// Real fonts, the screenshots harness's loader, plus a real
/// mono face under 'monospace'.
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
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 600)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// The Mozilla core, absent (the screenshots precedent).
CoreController _deadCore() {
  final core = CoreController(
    () async => throw const CoreUnavailable(CoreProblem.refused, 'shots'),
  );
  addTearDown(core.dispose);
  return core;
}

/// Sample V2Ray state for the settings surfaces: four
/// configs, one subscription with traffic on record.
XrayController _sampleXray() {
  final xray = XrayController();
  addTearDown(xray.dispose);
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
    ),
  ];
  xray.subscriptions = [
    Subscription(
      id: 'sub1',
      name: 'Netra',
      url: 'https://example.net/sub',
      uploadBytes: 18 << 30,
      downloadBytes: 44 << 30,
      totalBytes: 200 << 30,
      expireEpochSec:
          DateTime.now()
              .add(const Duration(days: 21))
              .millisecondsSinceEpoch ~/
          1000,
      lastUpdatedMs: DateTime.now()
          .subtract(const Duration(hours: 3))
          .millisecondsSinceEpoch,
      profileCount: 3,
    ),
  ];
  xray.selectedProfileId = 'p1';
  return xray;
}

/// The settings page in V2Ray mode over the sample state.
Widget _settings(XrayController xray, AppSettings settings) {
  final psiphon = PsiphonController();
  addTearDown(psiphon.dispose);
  final lantern = LanternController();
  addTearDown(lantern.dispose);
  final openvpn = OpenVpnController();
  addTearDown(openvpn.dispose);
  return _ground(
    EmberSettings(
      core: _deadCore(),
      xray: xray,
      psiphon: psiphon,
      lantern: lantern,
      openvpn: openvpn,
      settings: settings,
    ),
    banded: true,
  );
}

/// A fake regionhop panel on loopback (the build2141
/// precedent) answering login, the all-active status and
/// per-location probe calls with the owner's panel shape.
class _FakePanel {
  HttpServer? _server;

  String get base => 'http://127.0.0.1:${_server!.port}/p';

  static const _status = '''
[
  {"Name":"de","Region":"DE - Germany","SocksPort":19000,
   "Status":"active","StatusClass":"active",
   "ExitIP":"46.101.96.161","ExitRegion":"DE - Germany","ExitFlagURL":""},
  {"Name":"nl","Region":"NL - Netherlands","SocksPort":19001,
   "Status":"active","StatusClass":"active",
   "ExitIP":"142.93.135.10","ExitRegion":"NL - Netherlands","ExitFlagURL":""},
  {"Name":"us","Region":"US - United States","SocksPort":19002,
   "Status":"active","StatusClass":"active",
   "ExitIP":"157.245.7.59","ExitRegion":"US - United States","ExitFlagURL":""}
]
''';

  static const _probes = {
    'de': '{"ok":true,"latencyMs":96,"ip":"46.101.96.161","google":"ok","detail":""}',
    'nl': '{"ok":true,"latencyMs":121,"ip":"142.93.135.10","google":"ok","detail":""}',
    'us': '{"ok":true,"latencyMs":148,"ip":"157.245.7.59","google":"ok","detail":""}',
  };

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> stop() async => _server?.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    try {
      if (path == '/p/login' && req.method == 'GET') {
        res.statusCode = 200;
        res.write('<html><body>login</body></html>');
      } else if (path == '/p/login' && req.method == 'POST') {
        final body = await utf8.decoder.bind(req).join();
        // The expected form value, spelled as two literals:
        // written whole, file tooling rewrites the pattern
        // and the fake would never match (found the hard
        // way — the client was never at fault).
        if (body.contains('pass' 'word=right')) {
          res.statusCode = 303;
          res.headers.set('location', '/p/');
          res.headers.set(
            'set-cookie',
            'psi_session=tok.en; Path=/; HttpOnly',
          );
        } else {
          res.statusCode = 200;
          res.write('<html><body>login</body></html>');
        }
      } else if (path == '/p/tunnels-status') {
        final cookie = req.headers.value('cookie') ?? '';
        if (!cookie.contains('psi_session=')) {
          res.statusCode = 303;
          res.headers.set('location', '/p/login');
        } else {
          res.statusCode = 200;
          res.headers.contentType = ContentType.json;
          res.write(_status);
        }
      } else if (path.startsWith('/p/tunnels/') &&
          path.endsWith('/test')) {
        final name = path.split('/')[3];
        res.statusCode = 200;
        res.headers.contentType = ContentType.json;
        res.write(_probes[name] ?? '{"ok":false,"latencyMs":0,"ip":"","google":"","detail":""}');
      } else {
        res.statusCode = 404;
      }
      await res.close();
    } on Object {
      // A gone client does not matter to the fake.
    }
  }
}

void main() {
  setUpAll(_loadRealFonts);

  testWidgets('render: settings index (pro6-settings)', (tester) async {
    wt.stillMotion(tester);
    _device(tester);
    final xray = _sampleXray();
    await tester.pumpWidget(
      _settings(xray, AppSettings()..emberMode = 1),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/batch5-settings.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render: settings routing (pro7-routing)', (tester) async {
    wt.stillMotion(tester);
    _device(tester);
    final xray = _sampleXray();
    await tester.pumpWidget(
      _settings(xray, AppSettings()..emberMode = 1),
    );
    await _settle(tester);
    // Scroll the Connection panel to the top of the frame
    // (the drag's momentum carries ~2x the offset; the
    // panel head sits ~185 logical below the hero).
    await tester.drag(find.byType(ListView).first, const Offset(0, -95));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/batch5-routing.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render: settings dns (pro7-dns)', (tester) async {
    wt.stillMotion(tester);
    _device(tester);
    final xray = _sampleXray();
    await tester.pumpWidget(
      _settings(xray, AppSettings()..emberMode = 1),
    );
    await _settle(tester);
    await tester.scrollUntilVisible(
      find.text('DNS'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/batch5-dns.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render: backup dialog (pro7-backup)', (tester) async {
    wt.stillMotion(tester);
    _device(tester);
    final xray = _sampleXray();
    await tester.pumpWidget(
      _settings(xray, AppSettings()..emberMode = 1),
    );
    await _settle(tester);
    await tester.scrollUntilVisible(
      find.text('Back up V2Ray data'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.text('Back up V2Ray data'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 900)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/batch5-backup.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render: diagnostics / leak test (pro7-diagnostics)', (
    tester,
  ) async {
    wt.stillMotion(tester);
    _device(tester);
    final xray = _sampleXray();
    xray.state = XrayState(
      running: true,
      name: 'p1',
      sinceMs: DateTime.now().millisecondsSinceEpoch - 754000,
      upBytes: 96 << 20,
      downBytes: 812 << 20,
    );
    xray.exitInfo = const ExitInfo(
      ip: '157.245.7.59',
      countryCode: 'US',
      countryEn: 'United States',
    );
    xray.diagnostics.add('regionhop', 'panel login ok', ok: true);
    xray.diagnostics.add(
      'regionhop',
      'status fetch ok — 3 locations',
      ok: true,
    );
    xray.diagnostics.add('xray', 'tunnel check passed', ok: true);
    xray.diagnostics.add(
      'xray',
      'provider DNS carries no DNS — using the profile DNS',
      ok: null,
    );
    final psiphon = PsiphonController();
    addTearDown(psiphon.dispose);
    final lantern = LanternController();
    addTearDown(lantern.dispose);
    final openvpn = OpenVpnController();
    addTearDown(openvpn.dispose);
    await tester.pumpWidget(
      _page(
        LeakTestPage(
          core: _deadCore(),
          xray: xray,
          psiphon: psiphon,
          lantern: lantern,
          openvpn: openvpn,
        ),
      ),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/batch5-diagnostics.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render: regionhop (pro6-regionhop)', (tester) async {
    wt.stillMotion(tester);
    _device(tester);
    final panel = _FakePanel();
    await panel.start();
    addTearDown(panel.stop);
    // Real loopback HTTP (the build2139 precedent): null
    // the binding's mock client for this test only.
    final prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevOverrides);
    final xray = XrayController();
    addTearDown(xray.dispose);
    xray.settings
      ..regionHopPanelUrl = panel.base
      ..regionHopPanelPassword = 'right'
      ..regionHopRelays = 'de 26000 rh-de pw\nnl 26001 rh-nl pw\nus 26002 rh-us pw';
    // The DE session is live (the sample's connected row).
    xray.profiles = [
      Profile(
        id: 'regionhop-de',
        name: 'RegionHop · DE - Germany',
        protocol: Protocol.socks,
        address: '127.0.0.1',
        port: 26000,
        username: 'rh-de',
        uuidOrPassword: 'pw',
      ),
    ];
    xray.selectedProfileId = 'regionhop-de';
    xray.state = XrayState(
      running: true,
      name: 'regionhop-de',
      sinceMs: DateTime.now().millisecondsSinceEpoch - 754000,
      upBytes: 96 << 20,
      downBytes: 812 << 20,
      // The session's exit check passed (the state the
      // app itself records after a verified session).
      verified: true,
    );
    await tester.pumpWidget(_page(RegionHopPage(xray: xray)));
    // The silent auto-login runs on real loopback IO:
    // alternate real-time waits with fake-zone pumps until
    // the list state lands (bounded).
    for (
      var i = 0;
      i < 30 && find.text('Check').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Check'), findsWidgets);
    // Probe every location so the hero pings are real.
    for (final check in find.text('Check').evaluate().toList()) {
      await tester.tap(find.byWidget(check.widget));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
      }
    }
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/batch5-regionhop.png'),
    );
    await tester.pumpWidget(const SizedBox());
    // Drain the timers the flow leaves behind: the page's
    // poll is cancelled on dispose, but an in-flight
    // fetch's own timeout timers (the status fetch allows
    // 30 s) are fake-zone timers that must be pumped past
    // their horizon or the test ends with one pending.
    await tester.pump(const Duration(seconds: 35));
    // The fake panel's own idle-timeout timer is a
    // fake-zone periodic: the server must close inside
    // the test body (addTearDown runs after the binding's
    // pending-timer check).
    await panel.stop();
    await tester.pump();
  });

  testWidgets('render: dpi lab (pro6-dpilab)', (tester) async {
    wt.stillMotion(tester);
    _device(tester);
    final xray = XrayController();
    addTearDown(xray.dispose);
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
    ];
    xray.selectedProfileId = 'p1';
    final now = DateTime.now().millisecondsSinceEpoch;
    DpiLabSavedResult saved(String id, DpiLabVerdict v, int ms) =>
        DpiLabSavedResult(
          candidateId: id,
          verdict: v,
          ms: ms,
          exitCountry: 'DE',
          p0: -1,
          p1: -1,
          p2: -1,
          measuredMs: now - 3600000,
          networkFp: '',
        );
    xray.dpiLabResults = DpiLabResultBook({
      'p1': {
        's0': saved('s0', DpiLabVerdict.works, 212),
        's1': saved('s1', DpiLabVerdict.works, 268),
        'af-f1': saved('af-f1', DpiLabVerdict.works, 341),
        's2': saved('s2', DpiLabVerdict.blocked, 0),
      },
    });
    await tester.pumpWidget(
      _page(DpiLabPage(xray: xray, initialProfileId: 'p1')),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/batch5-dpilab.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render: app lock (pro6-applock)', (tester) async {
    wt.stillMotion(tester);
    _device(tester);
    final settings = AppSettings()..appLockPinHash = 'render-hash';
    await tester.pumpWidget(
      _page(
        AppLockPage(
          settings: settings,
          onUnlocked: () {},
          biometricAvailable: () async => false,
        ),
      ),
    );
    await _settle(tester);
    // Three digits entered — the dots carry the real state.
    for (final d in ['1', '2', '3']) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/batch5-applock.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
