// Home fidelity round R3 renders (batch 2: the fine-halftone Home backdrop) (owner order 2026-11-23:
// render-first, iterate until the render matches the approved
// pro3/pro5 home samples, nothing ships on these).
//
// These pump the REAL full shell (VpnApp) at the owner's
// device size — 411x915 logical (POCO X6 Pro) — in V2Ray
// mode, once connected and once disconnected, and write PNGs
// under test/screenshots/. They are iteration captures, not
// regression goldens:
//
//   flutter test --update-goldens test/home_r1_render_test.dart
//
// The connected state is seeded the way the device seeds it:
// a real store document (xray/state.json under a mocked
// dataDir) carrying the profiles + selection, and the
// 'app/android' channel answering xrayState / xrayExitInfo.
//
// Known wobble: the connected shot's SESSION counter is a
// live clock — a re-run without --update-goldens can differ
// from the stored capture by the seconds digit alone
// (~0.02% of pixels). The composition is what is pinned.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/ui/app.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

import 'widget_test.dart' as wt;

/// The owner's phone: 411x915 logical.
void _device(WidgetTester tester) {
  tester.view.physicalSize = const Size(822, 1830);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

/// Real fonts, the screenshots harness's loader (Roboto +
/// Material Icons from the SDK artifact).
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
  // The config meta line is set in 'monospace' — register a
  // real mono face under that name so the captures carry it
  // (the device resolves the system monospace).
  await load('monospace', const [
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
  ]);
}

/// The sample store: five configs whose remarks carry their
/// countries (the map pins derive from them), the German one
/// selected, its last delay test at the sample's 38 ms and its
/// lifetime traffic at the sample's 412 GB.
Map<String, dynamic> _storeDoc() {
  Profile p(
    String id,
    String name,
    Protocol proto,
    String addr, {
    int delay = -1,
    int up = 0,
    int down = 0,
  }) => Profile(
    id: id,
    name: name,
    protocol: proto,
    address: addr,
    port: 443,
    security: 'reality',
    network: 'tcp',
    delayMs: delay,
    subscriptionId: 'sub1',
    totalUpBytes: up,
    totalDownBytes: down,
  );
  final profiles = [
    p(
      'p1',
      'Germany · Frankfurt Reality',
      Protocol.vless,
      'de1.example.net',
      delay: 38,
      up: 100 << 30,
      down: 312 << 30,
    ),
    p('p2', 'Netherlands · Amsterdam XHTTP', Protocol.vless, 'nl2.example.net', delay: 64),
    p('p3', 'France · Paris Trojan', Protocol.trojan, 'fr1.example.net', delay: 92),
    p('p4', 'United Kingdom · London VMess', Protocol.vmess, 'uk1.example.net', delay: 121),
    p('p5', 'Turkey · Istanbul Hysteria2', Protocol.hysteria2, 'tr1.example.net', delay: 148),
  ];
  return {
    'profiles': profiles.map((e) => e.toJson()).toList(),
    'subscriptions': [
      Subscription(
        id: 'sub1',
        name: 'My Panel',
        url: 'https://panel.example.net/sub/rayan',
        uploadBytes: 12 << 30,
        downloadBytes: 30 << 30,
        totalBytes: 500 << 30,
        profileCount: 5,
      ).toJson(),
    ],
    'selectedProfileId': 'p1',
    'connectedProfileId': 'p1',
  };
}

/// Seeds the store file and the platform channel, then pumps
/// the real shell in V2Ray mode. Returns the core so the test
/// can dispose it inside the body (the screenshots harness's
/// pattern — its timers must not outlive the test).
Future<CoreController> _pumpShell(
  WidgetTester tester, {
  required bool connected,
}) async {
  wt.stillMotion(tester);
  _device(tester);
  // Sync IO only: real async file work inside the test body's
  // fake-async zone deadlocks (the first run hung both shots).
  final tmp = Directory.systemTemp.createTempSync('ember_r3_');
  addTearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });
  Directory('${tmp.path}/xray').createSync(recursive: true);
  File(
    '${tmp.path}/xray/state.json',
  ).writeAsStringSync(jsonEncode(_storeDoc()));

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

  // The Mozilla core must read OFF for these shots (the
  // FakeApi default is a running Mozilla, which would light
  // the header's PROTECTED state and the connected switcher
  // line in the disconnected shot).
  final core = CoreController(
    () async => wt.FakeApi()..on = false,
    pollInterval: const Duration(hours: 1),
  );
  await tester.pumpWidget(
    VpnApp(core: core, settings: AppSettings()..emberMode = 1),
  );
  core.start();
  // The store load chains platform-channel replies and real
  // file IO from the fake-async zone: each step needs BOTH
  // real time (runAsync) and a pump to deliver its completion.
  // Interleave the two until the chain has run through (store
  // load, backdrop decode, exit lookup, state polls).
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

  testWidgets('render: home connected (pro3)', (tester) async {
    final core = await _pumpShell(tester, connected: true);
    await expectLater(
      find.byType(VpnApp),
      matchesGoldenFile('screenshots/home-r3-connected.png'),
    );
    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });

  testWidgets('render: home disconnected (pro5-off)', (tester) async {
    final core = await _pumpShell(tester, connected: false);
    await expectLater(
      find.byType(VpnApp),
      matchesGoldenFile('screenshots/home-r3-off.png'),
    );
    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });
}
