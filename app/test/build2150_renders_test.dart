/// Build 2150 — renders for every surface the engine
/// appearance audit fixes touched (E49-01…E49-20). Real
/// screens at the owner's device size (411x915), PNGs
/// under test/screenshots/ember2150-*.png:
///
///   flutter test --update-goldens test/build2150_renders_test.dart
///
/// (a) subscriptions — the quota figure at 44 (E49-01),
///     no ✕ (E49-03), settled frost (E49-14);
/// (b) servers rows — result statuses on their own line,
///     the name never ellipsised (E49-02), a >400 ms ping
///     in red (E49-16), the speed line in words (E49-20);
/// (c) servers group head — title full width, controls
///     on their own row (E49-02);
/// (d) mozilla locations in the shell — BACK only, no ✕
///     (E49-03);
/// (e) pushed V2Ray page — BACK pill, 'V2RAY ENGINE'
///     whole, no bottom QR/Add bar (E49-03/04/13);
/// (f) psiphon regions — settled ground under the rows
///     (E49-05);
/// (g) dpi lab — one-line 44 pt title, first result
///     higher (E49-06);
/// (h) regionhop tiles — exit line one line, ping once,
///     'Tunnel up' only on the connected tile
///     (E49-07/08);
/// (i) profile editor mid-scroll — content settles under
///     the AppBar scrim (E49-09);
/// (j) daily report — left-aligned heading title
///     (E49-10);
/// (k) dns presets — left-aligned title, short band
///     (E49-10/14);
/// (l) home, disconnected — one row of engine chips
///     (E49-12);
/// (m) wireguard configurations — settled frost
///     (E49-14);
/// (n) a stock confirm dialog — hairline panel language
///     (E49-15).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide appBuildNumber;
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/ui/app.dart';
import 'package:firefox_vpn/ui/ember/daily_report_page.dart';
import 'package:firefox_vpn/ui/ember/dns_presets_page.dart';
import 'package:firefox_vpn/ui/ember/dpi_lab_page.dart';
import 'package:firefox_vpn/ui/ember/ember_accounts.dart';
import 'package:firefox_vpn/ui/ember/ember_dialogs.dart';
import 'package:firefox_vpn/ui/ember/ember_servers.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/ui/ember/profile_editor.dart';
import 'package:firefox_vpn/ui/ember/psiphon_pages.dart';
import 'package:firefox_vpn/ui/ember/regionhop_page.dart';
import 'package:firefox_vpn/xray/dpi_lab.dart';
import 'package:firefox_vpn/xray/problem_report.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

import 'widget_test.dart' as wt;

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

/// The 2148/2149 harness's shell pump: 411x915, the
/// platform channel mocked idle, FakeApi for the Mozilla
/// core.
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

Subscription _trafficSub() {
  final now = DateTime.now();
  return Subscription(
    id: 'sub1',
    name: 'My Panel With A Long Name',
    url: 'https://panel.example.net/sub/rayan',
    uploadBytes: 12 << 30,
    downloadBytes: 30 << 30,
    totalBytes: 100 << 30,
    expireEpochSec:
        now.add(const Duration(days: 21)).millisecondsSinceEpoch ~/ 1000,
    lastUpdatedMs: now.subtract(const Duration(hours: 3)).millisecondsSinceEpoch,
    profileCount: 24,
  );
}

/// The batch5 fake panel, copied: three active locations
/// with measured exits (the audit's own fixture values).
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
    'de':
        '{"ok":true,"latencyMs":96,"ip":"46.101.96.161","google":"ok","detail":""}',
    'nl':
        '{"ok":true,"latencyMs":121,"ip":"142.93.135.10","google":"ok","detail":""}',
    'us':
        '{"ok":true,"latencyMs":148,"ip":"157.245.7.59","google":"ok","detail":""}',
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
      } else if (path.startsWith('/p/tunnels/') && path.endsWith('/test')) {
        final name = path.split('/')[3];
        res.statusCode = 200;
        res.headers.contentType = ContentType.json;
        res.write(
          _probes[name] ??
              '{"ok":false,"latencyMs":0,"ip":"","google":"","detail":""}',
        );
      } else {
        res.statusCode = 404;
      }
      await res.close();
    } catch (_) {
      try {
        await res.close();
      } catch (_) {}
    }
  }
}

void main() {
  setUpAll(_loadRealFonts);

  testWidgets('render (a): subscriptions — figure at 44, no ✕', (
    tester,
  ) async {
    wt.stillMotion(tester);
    _device(tester);
    final xray = XrayController();
    addTearDown(xray.dispose);
    xray.subscriptions = [_trafficSub()];
    await tester.pumpWidget(
      _ground(
        EmberAccounts(core: _deadCore(), xray: xray, v2ray: true),
      ),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2150-subscriptions.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (b): servers rows — status lines, red band', (
    tester,
  ) async {
    wt.stillMotion(tester);
    _device(tester);
    final xray = XrayController();
    addTearDown(xray.dispose);
    xray.profiles = [
      Profile(
        id: 'p1',
        name: 'Senpai-Germany-Frankfurt-Reality-01',
        protocol: Protocol.vless,
        address: 'de1.example.net',
        port: 443,
        security: 'reality',
        network: 'tcp',
        delayMs: 86,
        lastSpeedBps: 5242880,
        lastSpeedUpBps: 1048576,
        speedTestedAtMs: DateTime(2026, 11, 12, 10, 30).millisecondsSinceEpoch,
      ),
      Profile(
        id: 'p2',
        name: 'Senpai-Netherlands-Amsterdam-Vision',
        protocol: Protocol.vless,
        address: 'nl2.example.net',
        port: 443,
        security: 'tls',
        network: 'tcp',
        delayMs: 640,
      ),
      Profile(
        id: 'p3',
        name: 'Senpai-UnitedStates-NewYork-Hysteria',
        protocol: Protocol.vless,
        address: 'us3.example.net',
        port: 443,
        security: 'tls',
        network: 'tcp',
        delayFailed: true,
      ),
    ];
    xray.selectedProfileId = 'p1';
    await tester.pumpWidget(
      _ground(
        EmberServers(
          core: _deadCore(),
          xray: xray,
          v2ray: true,
          onOpenAccounts: () {},
        ),
      ),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2150-servers-rows.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (c): group head — title full width', (tester) async {
    wt.stillMotion(tester);
    _device(tester);
    final xray = XrayController();
    addTearDown(xray.dispose);
    xray.profiles = [
      Profile(
        id: 'p1',
        name: 'Senpai-Germany-Frankfurt-Reality-01',
        protocol: Protocol.vless,
        address: 'de1.example.net',
        port: 443,
        security: 'reality',
        network: 'tcp',
        delayMs: 86,
        subscriptionId: 'sub1',
      ),
    ];
    xray.selectedProfileId = 'p1';
    xray.subscriptions = [_trafficSub()];
    await tester.pumpWidget(
      _ground(
        EmberServers(
          core: _deadCore(),
          xray: xray,
          v2ray: true,
          onOpenAccounts: () {},
        ),
      ),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2150-group-head.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (d): mozilla locations — BACK only', (tester) async {
    final core = await _pumpShell(tester, fakeOn: false);
    await tester.tap(find.byTooltip('Locations'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(VpnApp),
      matchesGoldenFile('screenshots/ember2150-locations.png'),
    );
    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });

  testWidgets('render (e): pushed V2Ray page — BACK pill, whole title', (
    tester,
  ) async {
    wt.stillMotion(tester);
    _device(tester);
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
      ),
    ];
    xray.selectedProfileId = 'p1';
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Ember.bg,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: V2RayPage(xray: xray),
      ),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2150-v2ray-page.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (f): psiphon regions — settled ground', (
    tester,
  ) async {
    wt.stillMotion(tester);
    _device(tester);
    final psiphon = PsiphonController();
    addTearDown(psiphon.dispose);
    await tester.pumpWidget(_ground(PsiphonRegionsView(psiphon: psiphon)));
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2150-psiphon.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (g): dpi lab — one-line title', (tester) async {
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
      _ground(DpiLabPage(xray: xray, initialProfileId: 'p1')),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2150-dpi-lab.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (h): regionhop tiles — decluttered', (tester) async {
    wt.stillMotion(tester);
    _device(tester);
    final panel = _FakePanel();
    // The bind runs on real IO (the batch5 harness's own
    // lesson: binding inside the fake zone can stall).
    await tester.runAsync(panel.start);
    addTearDown(panel.stop);
    final prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevOverrides);
    final xray = XrayController();
    addTearDown(xray.dispose);
    xray.settings
      ..regionHopPanelUrl = panel.base
      ..regionHopPanelPassword = 'right'
      ..regionHopRelays = 'de 26000 rh-de pw\\nnl 26001 rh-nl pw\\nus 26002 rh-us pw';
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
      verified: true,
    );
    await tester.pumpWidget(_ground(RegionHopPage(xray: xray)));
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
    for (final check in find.text('Check').evaluate().toList()) {
      await tester.tap(find.byWidget(check.widget));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2150-regionhop.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (i): profile editor — scrolled under the bar', (
    tester,
  ) async {
    wt.stillMotion(tester);
    _device(tester);
    final xray = XrayController();
    addTearDown(xray.dispose);
    final profile = Profile(
      id: 'p1',
      name: 'Frankfurt · Reality',
      protocol: Protocol.vless,
      address: '203.0.113.10',
      port: 443,
      security: 'reality',
      network: 'tcp',
      delayMs: 86,
    );
    xray.profiles = [profile];
    xray.selectedProfileId = 'p1';
    await tester.pumpWidget(
      _ground(ProfileEditorPage(xray: xray, existing: profile)),
    );
    await _settle(tester);
    // Scroll deep so form content passes under the
    // AppBar's title zone — the E49-09 collision state.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2150-editor-scrolled.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (j): daily report — app-dialect title', (
    tester,
  ) async {
    wt.stillMotion(tester);
    _device(tester);
    final xray = XrayController();
    addTearDown(xray.dispose);
    final now = DateTime.now();
    int at(int h, int m) =>
        DateTime(now.year, now.month, now.day, h, m).millisecondsSinceEpoch;
    xray.problemJournal.record(
      ProblemEvent(
        atMs: at(7, 3),
        type: ProblemTypes.proofUnverified,
        engine: 'V2Ray',
        profileName: 'Frankfurt · Reality',
        shape: 'VLESS · tcp+reality',
        stage: 'adoption',
        reason: 'connected before any proof traffic landed',
      ),
    );
    xray.problemJournal.record(
      ProblemEvent(
        atMs: at(8, 15),
        type: ProblemTypes.connectFailure,
        engine: 'V2Ray',
        profileName: 'Specimen · CF Trojan',
        shape: 'Trojan · ws+tls',
        stage: 'connect',
        reason: 'the connect attempt failed (underlay-failed)',
      ),
    );
    await tester.pumpWidget(_ground(DailyReportPage(xray: xray)));
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2150-daily-report.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (k): dns presets — app-dialect title', (
    tester,
  ) async {
    wt.stillMotion(tester);
    _device(tester);
    await tester.pumpWidget(
      _ground(
        const DnsPresetsPage(
          target: DnsPresetTarget.remote,
          currentValue: 'https://cloudflare-dns.com/dns-query',
        ),
      ),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2150-dns-presets.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (l): home disconnected — one chip row', (
    tester,
  ) async {
    final core = await _pumpShell(tester, fakeOn: false);
    await _settle(tester);
    await expectLater(
      find.byType(VpnApp),
      matchesGoldenFile('screenshots/ember2150-home-switcher.png'),
    );
    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });

  testWidgets('render (m): wireguard configurations — settled frost', (
    tester,
  ) async {
    final core = await _pumpShell(tester, mode: 5, fakeOn: false);
    await tester.tap(find.byTooltip('Locations'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(VpnApp),
      matchesGoldenFile('screenshots/ember2150-wireguard.png'),
    );
    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });

  testWidgets('render (n): confirm dialog — hairline panel', (
    tester,
  ) async {
    wt.stillMotion(tester);
    _device(tester);
    await tester.pumpWidget(
      _ground(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showEmberConfirm(
                context,
                title: 'Remove this config?',
                message:
                    'The config is removed from this device. '
                    'A subscription refresh can bring it back.',
                confirmLabel: 'Remove',
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2150-dialog.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
