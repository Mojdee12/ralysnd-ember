/// Build 2056 gates — audit Batches 9+10+11 (+ the §5 extras in the
/// same files): Settings per-engine sections + Ember pushed
/// scaffolds, chevron + subtitle + resolution order, the A-H3
/// button unification, radar child caching, scrollable sheets,
/// solid OpenVPN dialogs, the WG chip row + Delete confirmation,
/// WARP spacer gating, the Psiphon scroll cue, glyph arrows ->
/// icons, unified log viewers, QR guidance, the bottom-bar
/// displayName, and the Info + per-app pages.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/aether/aether_controller.dart';
import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/lantern/lantern_controller.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/ui/ember/ember_format.dart';
import 'package:firefox_vpn/ui/ember/ember_settings.dart';
import 'package:firefox_vpn/ui/ember/psiphon_pages.dart';
import 'package:firefox_vpn/ui/ember/qr_pages.dart';
import 'package:firefox_vpn/ui/ember/wireguard_pages.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String _read(String path) => File(path).readAsStringSync();

String _dart(String path) => _read('lib/$path');

Profile _wg(String id, String name) => Profile(
  id: id,
  protocol: Protocol.wireguard,
  name: name,
  address: '10.0.0.1',
  port: 51820,
  uuidOrPassword: '',
  security: '',
  sni: '',
);

/// Pumps EmberSettings in [mode] (0 Mozilla, 5 WireGuard, 6 WARP,
/// 7 MASQUE) with fresh controllers.
Future<void> _pumpSettings(
  WidgetTester tester,
  int mode, {
  AetherController? warp,
  AetherController? masque,
}) async {
  final core = CoreController(
    () async => throw const CoreUnavailable(CoreProblem.refused, 'test'),
  );
  addTearDown(core.dispose);
  final xray = XrayController();
  addTearDown(xray.dispose);
  final psiphon = PsiphonController();
  addTearDown(psiphon.dispose);
  final lantern = LanternController();
  addTearDown(lantern.dispose);
  final openvpn = OpenVpnController();
  addTearDown(openvpn.dispose);
  final settings = AppSettings()..emberMode = mode;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: EmberSettings(
          core: core,
          xray: xray,
          psiphon: psiphon,
          lantern: lantern,
          openvpn: openvpn,
          settings: settings,
          warp: warp,
          masque: masque,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('A-H5 per-engine Settings sections', () {
    test('source: WG + WARP/MASQUE dispatch, no Mozilla fallthrough', () {
      final dart = _dart('ui/ember/ember_settings.dart');
      expect(dart, contains('else if (wgMode)'));
      expect(dart, contains('_WireGuardSection(xray: xray)'));
      expect(dart, contains('else if (warpMode)'));
      expect(dart, contains("name: 'WARP'"));
      expect(dart, contains('else if (masqueMode)'));
      expect(dart, contains("name: 'MASQUE'"));
      expect(dart, contains('_WarpSection(xray: xray,'));
      // The old fallthrough: modes 5-7 silently got Mozilla's
      // section. The final else still serves mode 0 (Mozilla
      // itself) — so the pin is the ordering: the WG/WARP/MASQUE
      // branches come before that final else.
      final wgAt = dart.indexOf('else if (wgMode)');
      final warpAt = dart.indexOf('else if (warpMode)');
      final masqueAt = dart.indexOf('else if (masqueMode)');
      final mozAt = dart.indexOf('else\n          _MozillaSection');
      expect(wgAt, greaterThan(0));
      expect(warpAt, greaterThan(wgAt));
      expect(masqueAt, greaterThan(warpAt));
      expect(mozAt, greaterThan(masqueAt));
    });

    testWidgets('mode matrix: each engine shows its own section', (
      tester,
    ) async {
      // Mozilla (mode 0) still shows its own controls.
      await _pumpSettings(tester, 0);
      expect(find.text('Smart routing'), findsOneWidget);
      expect(find.text('WireGuard'), findsNothing);
      expect(find.text('WARP'), findsNothing);

      // WireGuard (mode 5): its own section, no Mozilla controls.
      await _pumpSettings(tester, 5);
      expect(find.text('WireGuard'), findsOneWidget);
      expect(find.text('No config selected'), findsOneWidget);
      expect(find.text('Smart routing'), findsNothing);

      // WARP (mode 6) and MASQUE (mode 7): their own sections.
      final warp = AetherController('cfwarp');
      addTearDown(warp.dispose);
      await _pumpSettings(tester, 6, warp: warp);
      expect(find.text('WARP'), findsOneWidget);
      expect(find.text('Disconnected'), findsOneWidget);
      expect(find.text('Smart routing'), findsNothing);

      final masque = AetherController('masque');
      addTearDown(masque.dispose);
      await _pumpSettings(tester, 7, masque: masque);
      expect(find.text('MASQUE'), findsOneWidget);
      expect(find.text('Smart routing'), findsNothing);
    });

    testWidgets('WG section row opens the configurations panel', (
      tester,
    ) async {
      await _pumpSettings(tester, 5);
      await tester.tap(find.text('WireGuard'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('WireGuard configurations'), findsOneWidget);
    });
  });

  group('A-H6 Ember-treated pushed scaffolds', () {
    test('source: no stock empty AppBar push; the helper carries a title',
        () {
      final dart = _dart('ui/ember/ember_settings.dart');
      expect(dart, isNot(contains('appBar: AppBar(),')));
      // Build 2058: `dart format` splits the long
      // _emberPageRoute(...) calls across lines, so pin the
      // helper + its title arguments separately instead of
      // the single-line call form.
      expect(dart, contains('_emberPageRoute('));
      expect(dart, contains('l.allSettings,'));
      expect(dart, contains('l.languageRow,'));
      expect(dart, contains('title: Text(title, style: Ember.heading),'));
      expect(dart, contains('body: EmberBackground(child: child),'));
    });
  });

  group('Batch 9 Settings truthfulness', () {
    test('chevrons point right in the LTR app', () {
      expect(
        _dart('ui/ember/ember_settings.dart'),
        isNot(contains('chevron_left_rounded')),
      );
      expect(
        _dart('ui/ember/psiphon_pages.dart'),
        isNot(contains('chevron_left_rounded')),
      );
    });

    test('MapSettingRow subtitles allow three lines', () {
      expect(
        _dart('ui/ember/map_widgets.dart'),
        contains('Build 2056 (audit Batch 9): the _XraySection'),
      );
      expect(_dart('ui/ember/map_widgets.dart'), contains('maxLines: 3,'));
    });

    test('Resolution order names the 2049 built-in fallback', () {
      final dart = _dart('ui/ember/ember_settings.dart');
      expect(dart, contains('(built-in fallback)'));
      expect(
        dart,
        contains(
          "tcpFormOf('https://dns.quad9.net/dns-query')",
        ),
      );
      expect(
        dart,
        contains('!s.dnsGroup && !s.dnsFallback && !s.adBlockDoh'),
      );
    });
  });

  group('A-H3 one button language', () {
    test('source: no stock buttons on the engine pages', () {
      for (final path in [
        'ui/ember/aether_pages.dart',
        'ui/ember/lantern_pages.dart',
        'ui/ember/openvpn_pages.dart',
        'ui/ember/wireguard_pages.dart',
      ]) {
        final dart = _dart(path);
        expect(dart, isNot(contains('OutlinedButton.icon(')), reason: path);
        expect(dart, isNot(contains('FilledButton(')), reason: path);
        expect(dart, contains('MapActionPill('), reason: path);
      }
      // The Fresh-list buttons keep their orange accent.
      expect(
        _dart('ui/ember/lantern_pages.dart'),
        contains('primary: true,'),
      );
    });

    test('source: settings-dialog primaries are EmberButtons', () {
      final dart = _dart('ui/ember/ember_settings.dart');
      expect(dart, contains('EmberButton('));
      expect(
        dart,
        isNot(contains('OutlinedButton')),
      );
      // Every Save in the _TextRow family is a primary now.
      expect(
        dart,
        contains('EmberButton(\n              label: l.saveAction,'),
      );
    });
  });

  group('Batch 10 radar + sheets + dialogs', () {
    test('radar: the centre column is the AnimatedBuilder child', () {
      final dart = _dart('ui/ember/aether_pages.dart');
      expect(dart, contains('builder: (context, child) => CustomPaint('));
      expect(dart, contains('child: child,'));
    });

    test('sheets scroll: add-sub (already), paste, CF targets', () {
      expect(
        _dart('ui/ember/ember_accounts.dart'),
        contains('SingleChildScrollView('),
      );
      expect(_dart('ui/ember/qr_pages.dart'), contains('SingleChildScrollView('));
      expect(
        _dart('ui/ember/cf_scanner_page.dart'),
        contains('SingleChildScrollView('),
      );
    });

    test('OpenVPN dialogs use the solid surface', () {
      final dart = _dart('ui/ember/openvpn_pages.dart');
      expect(dart, isNot(contains('MapUi.panelFill')));
      expect(dart, contains('backgroundColor: Ember.surface,'));
    });

    testWidgets('paste sheet at 360x640 with keyboard: Import reachable',
        (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      // The sheet pre-fills from the clipboard on open: answer
      // that channel, or the open awaits a reply that never comes.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async => null,
          );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetViewInsets();
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showPasteSheet(context, xray),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Import'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Batch 11 engine pages', () {
    test('WARP/MASQUE spacers gate on the card rendering', () {
      final dart = _dart('ui/ember/aether_pages.dart');
      expect(dart, contains('if (_hasExit(warp))'));
      expect(dart, contains('if (_hasExit(masque))'));
      expect(dart, contains('if (warp.state.log.isNotEmpty)'));
      expect(dart, contains('if (masque.state.log.isNotEmpty)'));
    });

    test('glyph arrows are gone from the UI strings', () {
      for (final path in [
        'ui/ember/aether_pages.dart',
        'ui/ember/lantern_pages.dart',
        'ui/ember/psiphon_pages.dart',
        'ui/ember/wireguard_pages.dart',
      ]) {
        expect(_dart(path), isNot(contains('↓ \${')), reason: path);
      }
      final p = _wg('wg1', 'wg-test');
      p.totalDownBytes = 1024;
      p.totalUpBytes = 2048;
      final totals = fmtProfileTotals(p);
      expect(totals, isNot(contains('↓')));
      expect(totals, isNot(contains('↑')));
      expect(totals, contains('Down 1.0 KB'));
      expect(totals, contains('Up 2.0 KB'));
    });

    test('log viewers are one-system cards with a Copy label', () {
      for (final path in [
        'ui/ember/lantern_pages.dart',
        'ui/ember/openvpn_pages.dart',
      ]) {
        final dart = _dart(path);
        expect(dart, contains('GlassCard('), reason: path);
        expect(dart, contains('label: Text(l.copyAll,'), reason: path);
        expect(
          dart,
          isNot(contains('label: Text(l.logsCopied,')),
          reason: path,
        );
      }
      // Build 2074 (UI audit item 5): the Psiphon pages moved to
      // MapGlass directly — same one-card-system intent, new
      // widget name.
      final psiphon = _dart('ui/ember/psiphon_pages.dart');
      expect(psiphon, contains('MapGlass('), reason: 'psiphon_pages');
      expect(
        psiphon,
        contains('label: Text(l.copyAll,'),
        reason: 'psiphon_pages',
      );
      expect(
        psiphon,
        isNot(contains('label: Text(l.logsCopied,')),
        reason: 'psiphon_pages',
      );
    });

    testWidgets('Psiphon region panel lays out in full in the page scroll', (
      tester,
    ) async {
      final psiphon = PsiphonController();
      addTearDown(psiphon.dispose);
      // Build 2074 (UI audit item 26): the panel no longer caps
      // itself at 180 dp with a nested scroller and a "more
      // regions below" cue — it lays out in full and the PAGE
      // scrolls it (both real usages sit inside a ListView).
      // Pump it the way the app does: inside a ListView.
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ListView(
              children: [
                PsiphonRegionsPanel(psiphon: psiphon, compact: true),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('More regions below — scroll'), findsNothing);
      // The last region's pill is reachable by scrolling — the
      // full grid is laid out, not capped.
      await tester.scrollUntilVisible(
        find.text(regionName(psiphon.regionChoices.last)),
        120,
      );
      expect(
        find.text(regionName(psiphon.regionChoices.last)),
        findsOneWidget,
      );
    });

    testWidgets('WG Delete asks first; Cancel keeps the config', (
      tester,
    ) async {
      // Sync creation: the testWidgets body runs under fake async,
      // so awaiting real IO (createTemp) never completes — the
      // 2054/2055 pattern creates its temp dir in setUp instead.
      final tempDir = Directory.systemTemp.createTempSync('ember2056-wg-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            (call) async {
              if (call.method == 'dataDir') return '${tempDir.path}/core';
              return null;
            },
          );
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('app/android'),
              null,
            );
        await tempDir.delete(recursive: true);
      });
      final xray = XrayController();
      addTearDown(xray.dispose);
      xray.profiles = [_wg('wg1', 'wg-test')];
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: WireGuardServersView(xray: xray)),
        ),
      );
      await tester.pump();
      expect(find.text('wg-test'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Delete wg-test?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(xray.profiles, hasLength(1));
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Delete').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(xray.profiles, isEmpty);
    });

    test('QR scanner gives guidance: hint text + torch toggle', () {
      final dart = _dart('ui/ember/qr_pages.dart');
      expect(dart, contains('Point the camera at a QR code'));
      expect(dart, contains('toggleTorch()'));
      expect(dart, contains("label: _torch ? 'Torch off' : 'Torch on',"));
    });

    test('WG home name + group header use the new anatomy', () {
      final dart = _dart('ui/ember/wireguard_pages.dart');
      expect(dart, contains('wgSelected.displayName'));
      expect(dart, contains("peers · fallback on'"));
      expect(dart, contains('letterSpacing: 1.6,'));
    });
  });

  group('§5 extras in the same files', () {
    test('bottom bar feeds displayName, not the raw stored name', () {
      final shell = _dart('ui/ember/ember_shell.dart');
      expect(
        shell,
        contains("value: p?.displayName ?? (on ? 'Running' : '—')"),
      );
      expect(shell, contains("value: wg?.displayName ?? (on ? 'Running'"));
    });

    test('Info page is Ember-treated', () {
      final dart = _dart('ui/ember/ember_info.dart');
      expect(dart, contains('EmberBackground('));
      expect(dart, isNot(contains('AppBar(title: Text(l.infoRow))')));
    });

    test('per-app page: Ember field, ellipsis, empty state', () {
      final dart = _dart('ui/bypass_apps_page.dart');
      expect(dart, contains('EmberBackground('));
      expect(dart, contains('emberField('));
      expect(dart, contains('No apps match'));
      expect(dart, contains('overflow: TextOverflow.ellipsis,'));
    });

    test('OpenVPN instruction wall is two lines', () {
      final dart = _dart('ui/ember/openvpn_pages.dart');
      // The wall text is split across Dart string literals, so the
      // pin checks the fragments, not one cross-line substring.
      expect(dart, contains('Long-press a '));
      expect(dart, contains('profile to manage its saved credentials.'));
      expect(
        dart,
        isNot(contains('If a profile asks for a username and password')),
      );
    });

    test('_TextRow: wider value, chevron affordance, ellipsizing chip', () {
      final settings = _dart('ui/ember/ember_settings.dart');
      expect(settings, contains('initial.length > 40'));
      expect(
        _dart('ui/ember/map_widgets.dart'),
        contains('overflow: TextOverflow.ellipsis,'),
      );
    });
  });
}
