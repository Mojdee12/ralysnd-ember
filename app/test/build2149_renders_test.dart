/// Build 2149 — renders for every appearance surface the
/// build changed (owner expansion 2026-11-25: appearance
/// fixes in the same build, renders as evidence). Real
/// screens at the owner's device size (411x915), PNGs under
/// test/screenshots/ember2149-*.png:
///
///   flutter test --update-goldens test/build2149_renders_test.dart
///
/// (a) full-bar connected pill — DISCONNECT on orange
///     (A48-01);
/// (b) dpi lab — short band, rows under the head, the
///     BEST pill, the explainer prose below the rows
///     (A48-02/A48-03 + the un-held badge decision);
/// (c) wireguard configurations, empty — page composition,
///     no floating card, no ✕ (A48-04);
/// (d) mozilla locations in the shell — no Home arc/pin
///     decoration over the list (A48-05);
/// (e) servers group head — the quota figure at the
///     compact hero step (B3);
/// (f) the sliding switch, ON and OFF (the un-held toggle
///     decision) — the app-lock settings card carries one.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide appBuildNumber;
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/ui/app.dart';
import 'package:firefox_vpn/ui/ember/app_lock.dart';
import 'package:firefox_vpn/ui/ember/daily_report_page.dart';
import 'package:firefox_vpn/ui/ember/dns_presets_page.dart';
import 'package:firefox_vpn/ui/ember/dpi_lab_page.dart';
import 'package:firefox_vpn/ui/ember/profile_editor.dart';
import 'package:firefox_vpn/ui/ember/ember_servers.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/xray/dpi_lab.dart';
import 'package:firefox_vpn/xray/problem_report.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

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

/// The 2148 harness's shell pump: 411x915, the platform
/// channel mocked idle, FakeApi for the Mozilla core.
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

void main() {
  setUpAll(_loadRealFonts);

  testWidgets('render (a): full bar connected — DISCONNECT pill', (
    tester,
  ) async {
    final core = await _pumpShell(tester, fakeOn: true);
    await tester.tap(find.byTooltip('Locations'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(VpnApp),
      matchesGoldenFile('screenshots/ember2149-fullbar-connected.png'),
    );
    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });

  testWidgets('render (b): dpi lab — short band, BEST, prose below', (
    tester,
  ) async {
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
      matchesGoldenFile('screenshots/ember2149-dpi-lab.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (c): wireguard configurations — empty page', (
    tester,
  ) async {
    final core = await _pumpShell(tester, mode: 5, fakeOn: false);
    await tester.tap(find.byTooltip('Locations'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(VpnApp),
      matchesGoldenFile('screenshots/ember2149-wireguard-empty.png'),
    );
    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });

  testWidgets('render (d): mozilla locations — no arc over the list', (
    tester,
  ) async {
    final core = await _pumpShell(tester, fakeOn: false);
    await tester.tap(find.byTooltip('Locations'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(VpnApp),
      matchesGoldenFile('screenshots/ember2149-locations-clean.png'),
    );
    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });

  testWidgets('render (e): servers group head — compact quota figure', (
    tester,
  ) async {
    wt.stillMotion(tester);
    _device(tester);
    final xray = XrayController();
    addTearDown(xray.dispose);
    final now = DateTime.now();
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
      Profile(
        id: 'p2',
        name: 'Senpai-Netherlands-Amsterdam-Vision',
        protocol: Protocol.vless,
        address: 'nl2.example.net',
        port: 443,
        security: 'tls',
        network: 'tcp',
        delayMs: 132,
        subscriptionId: 'sub1',
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
      matchesGoldenFile('screenshots/ember2149-servers-group-head.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (g): config row — node-test results line', (
    tester,
  ) async {
    // Expansion 2: the row carries the persisted ↓/↑
    // rates under the name, at the row's small scale.
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
      matchesGoldenFile('screenshots/ember2149-row-speed.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (h): profile diagnostics — results + DNS list', (
    tester,
  ) async {
    // Expansion 2: the editor's Diagnostics section —
    // delay/down/up + tested-at, the generated config's
    // DNS servers, the DNS check action.
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
      lastSpeedBps: 5242880,
      lastSpeedUpBps: 1048576,
      speedTestedAtMs: DateTime(2026, 11, 12, 10, 30).millisecondsSinceEpoch,
    );
    xray.profiles = [profile];
    xray.selectedProfileId = 'p1';
    await tester.pumpWidget(
      _ground(ProfileEditorPage(xray: xray, existing: profile)),
    );
    await _settle(tester);
    await tester.scrollUntilVisible(
      find.text('Diagnostics'),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2149-editor-diagnostics.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (i2): config DNS — per-row pings + verdict', (
    tester,
  ) async {
    // PRIORITY RENDER (owner ask 2026-11-25 ~05:49:
    // «نمونه عکس تست dns ببینم»), refined 06:33 by his
    // Karing screenshot: the per-config DNS surface on a
    // specimen-shaped profile (Trojan + WS + TLS,
    // Cloudflare-fronted) whose settings list THREE
    // resolvers — after Test DNS each row carries its own
    // through-config latency (or Failed), and the overall
    // Check DNS verdict line stays below. Both channels
    // answer through the real controller paths.
    wt.stillMotion(tester);
    _device(tester);
    // Real IO must run inside runAsync under the widget
    // test's fake clock — an awaited createTemp in the
    // test body deadlocks the whole run (found the hard
    // way, 2026-11-25: three renders runs stalled on it).
    late final Directory tmp;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('ember2149dns-');
    });
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('app/android'), (
      call,
    ) async {
      switch (call.method) {
        case 'dataDir':
          return '${tmp.path}/core';
        case 'xrayDnsPing':
          final servers =
              (call.arguments as Map)['servers'] as List<Object?>;
          return <String, Object?>{
            'ok': 1,
            'error': '',
            'results': <String, Object?>{
              for (final s in servers)
                s as String: s.contains('cloudflare')
                    ? 96
                    : s == '8.8.8.8'
                    ? -1
                    : s == '185.51.200.2'
                    ? 132
                    : 88,
            },
          };
        case 'xraySandboxTest':
          return <String, Object?>{
            'ok': 1,
            'ms': 132,
            'p0': 131,
            'p1': 129,
            'p2': 133,
            'held': 1,
            'ip': '203.0.113.9',
            'countryCode': 'DE',
            'country': 'Germany',
            'error': '',
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
    final xray = XrayController();
    addTearDown(xray.dispose);
    // No load(): it deadlocks under the widget-test fake
    // clock (its platform probes never settle there), and
    // the sandbox path needs only settings + profiles —
    // the same shape render (h) uses. The remote list
    // names three resolvers so the generated config's DNS
    // list has three rows to ping.
    xray.settings.remoteDns =
        'https://cloudflare-dns.com/dns-query,8.8.8.8,185.51.200.2';
    final profile = Profile(
      id: 'specimen',
      name: 'Specimen · CF Trojan',
      protocol: Protocol.trojan,
      address: '203.0.113.44',
      port: 443,
      uuidOrPassword: 'specimen-password',
      security: 'tls',
      network: 'ws',
      sni: 'cdn.example.net',
      host: 'cdn.example.net',
      path: '/stream/panel/example',
      fingerprint: 'chrome',
      delayMs: 118,
      lastSpeedBps: 7340032,
      lastSpeedUpBps: 2097152,
      speedTestedAtMs: DateTime(2026, 11, 12, 10, 30).millisecondsSinceEpoch,
    );
    xray.profiles = [profile];
    xray.selectedProfileId = 'specimen';
    await tester.pumpWidget(
      _ground(ProfileEditorPage(xray: xray, existing: profile)),
    );
    await _settle(tester);
    await tester.scrollUntilVisible(
      find.text('Test DNS'),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    // scrollUntilVisible parks the pill at the bottom
    // edge, under the editor's pinned foot bar — the tap
    // would hit the bar. Drag further so the pill sits
    // mid-viewport before tapping (probe-proven).
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -260));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Test DNS'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 900)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // The per-row results landed: an answered ms and a
    // Failed mark, one per listed server.
    expect(find.text('96 ms'), findsOneWidget);
    expect(find.text('132 ms'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    // Freeze the ping stamp before the golden: the flow
    // stamps DateTime.now(), and the caption prints it as
    // an absolute local time — a now-stamped golden could
    // only ever match within its own minute.
    profile.dnsPingAtMs = DateTime(
      2026,
      11,
      12,
      10,
      30,
    ).millisecondsSinceEpoch;
    xray.notifyListeners();
    await tester.pump();
    await tester.tap(find.text('Check DNS'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 900)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('resolves inside the tunnel'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2149-config-dns2.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (j): daily problem report — seeded day', (
    tester,
  ) async {
    // Expansion 4: the Daily problem report page with a
    // realistic day of recorded problems.
    wt.stillMotion(tester);
    _device(tester);
    final xray = XrayController();
    addTearDown(xray.dispose);
    final now = DateTime.now();
    int at(int h, int m) =>
        DateTime(now.year, now.month, now.day, h, m)
            .millisecondsSinceEpoch;
    void seed(
      String type,
      int h,
      int m, {
      String engine = 'V2Ray',
      String name = '',
      String shape = '',
      String stage = '',
      required String reason,
    }) {
      xray.problemJournal.record(
        ProblemEvent(
          atMs: at(h, m),
          type: type,
          engine: engine,
          profileName: name,
          shape: shape,
          stage: stage,
          reason: reason,
        ),
      );
    }

    seed(
      ProblemTypes.coreStartFailure,
      5,
      41,
      name: 'Specimen · CF Trojan',
      shape: 'Trojan · ws+tls',
      stage: 'core start',
      reason: 'the core did not start',
    );
    seed(
      ProblemTypes.proofUnverified,
      7,
      3,
      name: 'Frankfurt · Reality',
      shape: 'VLESS · tcp+reality',
      stage: 'adoption',
      reason: 'connected before any proof traffic landed',
    );
    seed(
      ProblemTypes.dnsFailure,
      7,
      4,
      name: 'Milan · Hostname',
      shape: 'VLESS · ws+tls',
      stage: 'server name lookup',
      reason: 'the on-device lookup failed twice',
    );
    seed(
      ProblemTypes.connectFailure,
      8,
      15,
      name: 'Specimen · CF Trojan',
      shape: 'Trojan · ws+tls',
      stage: 'connect',
      reason: 'the connect attempt failed (underlay-failed)',
    );
    seed(
      ProblemTypes.regionHopLockout,
      9,
      2,
      engine: 'RegionHop',
      stage: 'panel login',
      reason: 'the panel reported too many login attempts',
    );
    await tester.pumpWidget(_ground(DailyReportPage(xray: xray)));
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/ember2149-daily-report.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render (k): DNS presets — Global + Iran, remote', (
    tester,
  ) async {
    // Expansion 5: the full-page preset picker for the
    // remote DNS field — both sections, the shipped
    // default's row carrying SELECTED, the Iran section's
    // anti-sanctions caption.
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
      matchesGoldenFile('screenshots/ember2149-dns-presets.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('picker fill: a tap pops the value the field takes', (
    tester,
  ) async {
    // Expansion 5's fill contract, at the page boundary:
    // the settings rows apply exactly what the page pops.
    wt.stillMotion(tester);
    _device(tester);
    String? poppedRemote = 'unset';
    String? poppedLocal = 'unset';
    await tester.pumpWidget(
      _ground(
        Builder(
          builder: (context) => Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: () async {
                  poppedRemote = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) => const DnsPresetsPage(
                        target: DnsPresetTarget.remote,
                        currentValue: 'https://cloudflare-dns.com/dns-query',
                      ),
                    ),
                  );
                },
                child: const Text('open remote'),
              ),
              TextButton(
                onPressed: () async {
                  poppedLocal = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) => const DnsPresetsPage(
                        target: DnsPresetTarget.local,
                        currentValue: '1.1.1.1',
                      ),
                    ),
                  );
                },
                child: const Text('open local'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('open remote'));
    await tester.pumpAndSettle();
    // Shecan (Iran section, DoH published): the remote
    // field takes the DoH URL.
    await tester.scrollUntilVisible(
      find.text('Shecan'),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.text('Shecan'));
    await tester.pumpAndSettle();
    expect(poppedRemote, 'https://free.shecan.ir/dns-query');
    await tester.tap(find.text('open local'));
    await tester.pumpAndSettle();
    // RadarGame (no DoH): the local field takes the
    // primary address alone.
    await tester.scrollUntilVisible(
      find.text('RadarGame'),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.text('RadarGame'));
    await tester.pumpAndSettle();
    expect(poppedLocal, '10.202.10.10');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('picker test all: per-row pings, session-only', (
    tester,
  ) async {
    // Expansion 5 refinement (the owner's Karing
    // screenshot): Test all probes every preset — no
    // controller is passed, so the probes go direct — and
    // each row shows its own ms or Failed.
    wt.stillMotion(tester);
    _device(tester);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final modes = <Object?>[];
    messenger.setMockMethodCallHandler(const MethodChannel('app/android'), (
      call,
    ) async {
      if (call.method == 'xrayDnsPing') {
        final args = call.arguments as Map;
        modes.add(args['mode']);
        final servers = args['servers'] as List<Object?>;
        return <String, Object?>{
          'ok': 1,
          'error': '',
          'results': <String, Object?>{
            for (final s in servers)
              s as String: s.contains('cloudflare') ? 24 : -1,
          },
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
    await tester.pumpWidget(
      _ground(
        const DnsPresetsPage(
          target: DnsPresetTarget.remote,
          currentValue: 'https://cloudflare-dns.com/dns-query',
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.text('Test all'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(modes, ['direct']);
    expect(find.text('24 ms'), findsOneWidget);
    expect(find.text('Failed'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  for (final on in [true, false]) {
    testWidgets('render (f): sliding switch ${on ? 'ON' : 'OFF'}', (
      tester,
    ) async {
      wt.stillMotion(tester);
      _device(tester);
      final settings = AppSettings()
        ..appLockPinHash = 'render-hash'
        ..appLockBiometric = on;
      await tester.pumpWidget(
        _ground(
          AppLockSettingsPage(
            settings: settings,
            biometricAvailable: () async => true,
          ),
        ),
      );
      await _settle(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          'screenshots/ember2149-toggle-${on ? 'on' : 'off'}.png',
        ),
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
}
