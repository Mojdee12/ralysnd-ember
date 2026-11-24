/// Build 2147 — fix item #23 (owner device verdict 2026-11-24
/// on shipped 2146, with screenshot): the shell header's
/// 9-chip engine rail tower (brand panel + a 128 dp column of
/// stacked chips, ~410 dp tall) sat on EVERY engine page and
/// pushed the page's own composition halfway down the screen.
/// The approved pro6 engine-page samples use a slim header.
///
/// The fix (appearance/layout only): on non-Home tabs the
/// header is the Home-R1 language — the same brand line as
/// Home, plus ONE horizontal, scrollable row of the same nine
/// MapEngineChips (same order, same tap behaviour). One-tap
/// engine switching stays reachable from every engine page
/// and from Settings (build 2092 items 34/60), and the
/// Settings chip keeps its close behaviour on the Settings
/// tab. Home is unchanged.
///
/// This test renders an engine page (Lantern's servers tab)
/// in the full shell and asserts: the header is slim (no
/// 9-chip column, no brand panel), and all 8 engine chips +
/// Settings are present and tappable.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide appBuildNumber;
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/ui/app.dart';
import 'package:firefox_vpn/ui/ember/map_widgets.dart';

import 'widget_test.dart' as wt;

String _read(String path) => File(path).readAsStringSync();

/// The screenshots harness's font loading (mirrors
/// build2121_test.dart): real Roboto + Material Icons, so the
/// measurements carry real phone metrics.
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

/// Pumps the full shell on a 411x915 logical surface at 2x,
/// exactly as build2121_test.dart's harness does.
Future<CoreController> _pumpShell(WidgetTester tester) async {
  wt.stillMotion(tester);
  tester.view.physicalSize = const Size(822, 1830);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
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
    () async => wt.FakeApi(),
    pollInterval: const Duration(hours: 1),
  );
  await tester.pumpWidget(VpnApp(core: core, settings: AppSettings()));
  core.start();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 600)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return core;
}

Finder _chip(String name) => find.widgetWithText(MapEngineChip, name);

/// Drags the header's chip row until [name]'s chip centre is
/// inside the 411 dp viewport. (scrollUntilVisible's implicit
/// scrollable lookup trips over the shell's many Scrollables;
/// the header's SingleChildScrollView is the first in the
/// tree — the header sits above the pages' IndexedStack.)
Future<void> _revealChip(WidgetTester tester, String name) async {
  for (var i = 0; i < 12; i++) {
    final rect = tester.getRect(_chip(name));
    if (rect.center.dx >= 0 && rect.center.dx <= 411) return;
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      Offset(rect.center.dx > 411 ? -260 : 260, 0),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  setUpAll(_loadRealFonts);

  test('source: the non-Home header is the slim brand line + chip row', () {
    final shell = _read('lib/ui/ember/ember_shell.dart');
    final start = shell.indexOf('Widget _header()');
    final end = shell.indexOf('Widget build(', start);
    final header = shell.substring(start, end);
    expect(header, contains('scrollDirection: Axis.horizontal'));
    expect(header, contains('SingleChildScrollView'));
    expect(header, contains('_homeHeader()'));
    expect(header, isNot(contains('MapBrandPanel(')));
    expect(header, isNot(contains('Wrap(spacing: 6, runSpacing: 0')));
    expect(shell, isNot(contains('compactRail')));
  });

  testWidgets('engine page (Lantern): slim header, all nine chips tappable', (
    tester,
  ) async {
    final core = await _pumpShell(tester);

    // Lantern mode from the Home switcher, then its servers
    // tab — an engine page under the shell header.
    await tester.tap(find.text('Lantern'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Locations'));
    await tester.pumpAndSettle();

    // All nine chips are in the header: 8 engines + Settings.
    expect(find.byType(MapEngineChip), findsNWidgets(9));
    // The old tower's brand panel is gone from the header.
    expect(find.byType(MapBrandPanel), findsNothing);

    // Slim: every chip shares one row (tops within 2 dp —
    // no stacked column), and the whole header (brand line
    // top to chip bottom) is a fraction of the old ~410 dp.
    final wordmark = find.text('EMBER');
    expect(wordmark, findsOneWidget);
    final headerTop = tester.getTopLeft(wordmark).dy;
    var minTop = double.infinity;
    var maxTop = double.negativeInfinity;
    var maxBottom = double.negativeInfinity;
    for (final e in find.byType(MapEngineChip).evaluate()) {
      final rect = tester.getRect(find.byWidget(e.widget));
      minTop = rect.top < minTop ? rect.top : minTop;
      maxTop = rect.top > maxTop ? rect.top : maxTop;
      maxBottom = rect.bottom > maxBottom ? rect.bottom : maxBottom;
    }
    expect(
      maxTop - minTop,
      lessThan(2),
      reason: 'the nine chips form ONE row, not a column',
    );
    expect(
      maxBottom - headerTop,
      lessThan(130),
      reason: 'header height is slim (was ~410 dp with the tower)',
    );
    expect(tester.takeException(), isNull);

    // Every engine chip is tappable and switches the mode
    // (the tapped chip becomes the highlighted one). Each
    // tap targets a non-current engine, so the shell stays
    // on the servers tab under the same slim header.
    const order = [
      'V2Ray',
      'Psiphon',
      'OpenVPN',
      'WireGuard',
      'WARP',
      'MASQUE',
      'Mozilla',
      'Lantern',
    ];
    for (final name in order) {
      await _revealChip(tester, name);
      await tester.pumpAndSettle();
      await tester.tap(_chip(name));
      await tester.pumpAndSettle();
      expect(
        tester.widget<MapEngineChip>(_chip(name)).highlight,
        isTrue,
        reason: 'tapping $name switches the engine mode',
      );
      expect(find.byType(MapEngineChip), findsNWidgets(9));
    }

    // The Settings chip opens Settings; on the Settings tab
    // it becomes the close chip and tapping it goes Home
    // (build 2092 item 34 behaviour, preserved).
    await _revealChip(tester, 'Settings');
    await tester.pumpAndSettle();
    await tester.tap(_chip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(MapEngineChip), findsNWidgets(9));
    expect(
      find.descendant(
        of: _chip('Settings'),
        matching: find.byIcon(Icons.close_rounded),
      ),
      findsOneWidget,
      reason: 'on the Settings tab the chip is the close control',
    );
    await tester.tap(_chip('Settings'));
    await tester.pumpAndSettle();
    expect(
      find.byType(MapEngineChip),
      findsNothing,
      reason: 'the close chip returns to the Home tab (no rail there)',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });
}
