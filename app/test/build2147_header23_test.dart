/// Build 2147 — fix item #23 (owner device verdict 2026-11-24
/// on shipped 2146, with screenshot): the shell header's
/// 9-chip engine rail tower sat on EVERY engine page.
///
/// UPDATED by build 2148 (owner navigation ruling 2026-11-24,
/// on device with screenshots — supersedes #23 and the
/// build-2092 rail constraint): the engine pages must not
/// carry an engine selector AT ALL. Engine choice happens on
/// the main (Home) page only; every other tab's header is the
/// slim brand line led by a BACK control that returns to
/// Home. The Settings tab keeps its close-to-Home behaviour
/// through that same control. Home is unchanged.
///
/// This test renders engine pages in the full shell and
/// asserts the new model: no MapEngineChip anywhere off the
/// Home tab, a BACK control (>= 44 dp) at the top of the
/// header, and tapping it lands back on Home.
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

void main() {
  setUpAll(_loadRealFonts);

  test('source: the non-Home header is brand line + BACK, no chips', () {
    final shell = _read('lib/ui/ember/ember_shell.dart');
    final start = shell.indexOf('Widget _header()');
    final end = shell.indexOf('Widget build(', start);
    final header = shell.substring(start, end);
    // The new model: non-Home tabs return the brand line
    // with the back control; no chip construction remains
    // in the header at all.
    expect(header, contains('_homeHeader(backToHome: true)'));
    expect(header, isNot(contains('MapEngineChip(')));
    expect(header, isNot(contains('SingleChildScrollView')));
    expect(header, isNot(contains('MapBrandPanel(')));
    expect(shell, isNot(contains('compactRail')));
    // The back control itself: labelled, >= 48 dp tall,
    // returns to tab 0.
    final homeHeader = shell.substring(
      shell.indexOf('Widget _homeHeader('),
      shell.indexOf('Widget _header()'),
    );
    expect(homeHeader, contains("Text('BACK'"));
    expect(homeHeader, contains('setState(() => _tab = 0)'));
  });

  testWidgets('engine page (Lantern): BACK header, no chip selector', (
    tester,
  ) async {
    final core = await _pumpShell(tester);

    // Lantern mode from the Home switcher, then its servers
    // tab — an engine page under the shell header.
    await tester.tap(find.text('Lantern'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Locations'));
    await tester.pumpAndSettle();

    // No engine selector anywhere on the engine page.
    expect(find.byType(MapEngineChip), findsNothing);
    expect(find.byType(MapBrandPanel), findsNothing);

    // The BACK control is present, obvious and >= 44 dp.
    final back = find.text('BACK');
    expect(back, findsOneWidget);
    final backRect = tester.getRect(
      find.ancestor(of: back, matching: find.byType(InkWell)).first,
    );
    expect(backRect.height, greaterThanOrEqualTo(44));

    // The header stays slim: brand line top to header
    // bottom is a fraction of the old ~410 dp tower and of
    // the 2147 chip-row header (~130 dp incl. the row).
    final headerTop = tester.getTopLeft(find.text('EMBER')).dy;
    expect(backRect.top - headerTop, lessThan(24));
    expect(tester.takeException(), isNull);

    // Tapping BACK lands on the Home tab: the back control
    // is gone and the Home engine switcher is on screen.
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.text('BACK'), findsNothing);
    expect(find.text('WireGuard'), findsWidgets);
    expect(tester.takeException(), isNull);

    // The Settings tab carries the same BACK control, and
    // it keeps the close-to-Home behaviour (build 2092
    // item 34's contract, new control).
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('BACK'), findsOneWidget);
    expect(find.byType(MapEngineChip), findsNothing);
    await tester.tap(find.text('BACK'));
    await tester.pumpAndSettle();
    expect(find.text('BACK'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });
}
