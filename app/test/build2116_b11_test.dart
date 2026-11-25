// Build 2116, batches B11 (appearance defects AP-01…AP-21
// minus AP-03/AP-20) + B12 (APK size). Every fix is
// defect-repair against the app's own tokens — no redesign.
// AP-03 is executed as B12-1; AP-20 is deferred to the
// Windows project by the plan; B12-2 is VOID (the shipped
// APK contains no second scanner stack — only ML Kit's
// libbarhopper_v3.so; there is no ZXing anywhere in the
// tree or the package).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/ui/widgets.dart' as legacy;

String _src(String rel) => File(rel).readAsStringSync();

void main() {
  group('B11-3 / AP-04 one ping rule (the frozen ≤150 pair)', () {
    test('pingColor and delayColor agree everywhere', () {
      // PIN UPDATED by build 2150 (engine appearance audit
      // E49-16): the 2116 freeze held the top band open —
      // everything above 150 ms was the same yellow, so a
      // 180 ms and a 650 ms answer read identically against
      // the owner's ruling that ping colour follows health
      // (2147 #22). The rule is the three-band scale the
      // _PingPill doc always described: green ≤150, yellow
      // to 400, red beyond. The agreement half of this pin
      // (one function, both shells) is unchanged.
      expect(pingColor(-1), Ember.faint);
      expect(pingColor(0), MapUi.pingGreen);
      expect(pingColor(150), MapUi.pingGreen);
      expect(pingColor(151), MapUi.pingYellow);
      expect(pingColor(200), MapUi.pingYellow,
          reason: 'the 200 ms case that disagreed across shells');
      expect(pingColor(400), MapUi.pingYellow);
      expect(pingColor(401), Ember.red);
      expect(pingColor(2000), Ember.red);
      for (final ms in [-1, 0, 100, 150, 151, 400, 1000, 5000]) {
        expect(legacy.delayColor(ms), pingColor(ms), reason: '$ms');
      }
    });
  });

  group('B12-1 / AP-03 backdrop', () {
    test('the backdrop is a display-class WebP, decoded capped', () {
      // PIN UPDATED by build 2150 (engine appearance audit
      // E49-19): the coarse map_backdrop.webp shipped dead
      // — since 2148 every surface paints the fine home
      // bake and nothing referenced the coarse file. It is
      // REMOVED; the pin now asserts its absence and the
      // home asset's presence. Intent kept: one WebP
      // backdrop, decoded capped, no PNG shipped.
      expect(File('assets/backdrop/map_backdrop.webp').existsSync(),
          isFalse);
      final webp = File('assets/backdrop/map_backdrop_home.webp');
      expect(webp.existsSync(), isTrue);
      expect(webp.lengthSync(), lessThan(1024 * 1024));
      expect(File('assets/backdrop/map_backdrop.png').existsSync(),
          isFalse);
      final w = _src('lib/ui/ember/map_widgets.dart');
      // PIN UPDATED by build 2148 (FIX 4, owner device
      // verdict on 2147): the painter now loads the FINE
      // halftone bake on every surface — the coarse
      // map_backdrop.webp is no longer the backdrop
      // anywhere. Intent kept: a WebP asset, decoded
      // capped, no PNG shipped.
      expect(w.contains('map_backdrop_home.webp'), isTrue);
      // Build 2118 re-point: the 1440 cap was itself half of
      // the coarse-map root cause (portrait cover displays
      // ~9.4 px/unit; the cap fed it 4) — the decode is still
      // capped, now at the display-matched 2880. Intent kept:
      // a WebP asset, decoded capped, no PNG shipped.
      expect(w.contains('cacheWidth: 2880'), isTrue);
    });

    test('B12-2 VOID evidence: no ZXing in tree or pubspec', () {
      expect(_src('pubspec.yaml').contains('zxing'), isFalse);
      expect(
          _src('pubspec.yaml').contains('mobile_scanner'), isTrue);
    });
  });

  group('B11 source pins', () {
    test('AP-01: the eight pushed pages sit on EmberBackground', () {
      for (final f in [
        'lib/ui/ember/battery_report.dart',
        'lib/ui/ember/chain_builder_page.dart',
        'lib/ui/ember/dpi_lab_page.dart',
        'lib/ui/ember/leak_test_page.dart',
        'lib/ui/ember/smart_groups_page.dart',
        'lib/ui/ember/traffic_history_page.dart',
      ]) {
        // PIN UPDATED by build 2147 (strict-audit F1): the
        // Lab page now sits on the BANDED background —
        // its call carries banded: true before child:.
        // PIN UPDATED by build 2149 (audit A48-02): the Lab
        // page's band became the SHORT band — its call
        // carries bandShort: true; the other pages are
        // unchanged.
        expect(
            _src(f).contains('EmberBackground(child: ListView(') ||
                _src(f).contains(
                    'EmberBackground(banded: true, child: ListView(') ||
                _src(f).contains(
                    'EmberBackground(bandShort: true, child: ListView('),
            isTrue,
            reason: f);
        expect(_src(f).contains('backgroundColor: Colors.transparent'),
            isTrue,
            reason: '$f appbar');
      }
      final pairing = _src('lib/ui/ember/pairing.dart');
      expect('EmberBackground(child: ListView('.allMatches(pairing).length,
          2);
    });

    test('AP-02: the Mozilla log route carries the Ember chrome', () {
      expect(_src('lib/ui/logs_page.dart').contains('emberChrome'),
          isTrue);
      expect(
          _src('lib/ui/ember/ember_logs_page.dart')
              .contains('emberChrome: true'),
          isTrue);
    });

    test('AP-05: no home reads the device height for its top gap', () {
      for (final f in [
        'lib/ui/ember/aether_pages.dart',
        'lib/ui/ember/lantern_pages.dart',
        'lib/ui/ember/openvpn_pages.dart',
        'lib/ui/ember/wireguard_pages.dart',
      ]) {
        expect(
            _src(f).contains(
                'emberHomeTopGap(MediaQuery.sizeOf(context).height)'),
            isFalse,
            reason: f);
        expect(
            _src(f).contains('emberHomeTopGap(constraints.maxHeight)'),
            isTrue,
            reason: f);
      }
    });

    test('AP-06/AP-07: legacy page glass + toggles, Android dark', () {
      final w = _src('lib/ui/widgets.dart');
      expect(w.contains('if (emberHosted) return MapGlass'), isTrue);
      final sp = _src('lib/ui/settings_page.dart');
      expect(sp.contains('settingsToggle('), isTrue);
      expect(sp.contains('child: Switch('), isFalse);
      final app = _src('lib/ui/app.dart');
      expect(app.contains('Platform.isAndroid\n            ? true'),
          isTrue);
      // AP-21: the one true orange.
      expect(app.contains('0xFFFF7A18'), isFalse);
      // PIN UPDATED by build 2144 (reskin): the one true
      // orange is the samples' #FF7A29 now.
      expect('0xFFFF7A29'.allMatches(app).length, 2);
    });

    test('AP-08/AP-16: no bare stock field decorations remain', () {
      for (final f in [
        'lib/ui/ember/chain_builder_page.dart',
        'lib/ui/ember/pairing.dart',
        'lib/ui/ember/smart_groups_page.dart',
        'lib/ui/ember/psiphon_pages.dart',
      ]) {
        expect(_src(f).contains('emberField(context,'), isTrue,
            reason: f);
      }
      expect(
          _src('lib/ui/ember/chain_builder_page.dart')
              .contains('border: OutlineInputBorder()'),
          isFalse);
    });

    test('AP-09/AP-10/AP-11/AP-12/AP-13/AP-17/AP-18/AP-19 pins', () {
      // PIN UPDATED by build 2148 (FIX 7, class 6): the
      // Lab's profile picker — the sheet whose Ember.surface
      // this pinned — is a pushed full page now (Ember.bg
      // ground, BACK header); the pin follows the page form.
      expect(
          _src('lib/ui/ember/dpi_lab_page.dart')
              .contains('Choose a config'),
          isTrue);
      expect(_src('lib/ui/ember/qr_pages.dart').contains('alpha: 0.55'),
          isTrue);
      final app = _src('lib/ui/app.dart');
      expect(app.contains('EmberButton('), isTrue);
      expect(app.contains('MapGlass('), isTrue);
      final servers = _src('lib/ui/ember/ember_servers.dart');
      expect(servers.contains('fontSize: 9,'), isFalse);
      expect(servers.contains('fontSize: 9.5'), isFalse);
      expect(
          _src('lib/ui/ember/battery_report.dart')
              .contains("Text('Loading…', style: Ember.body)"),
          isFalse);
      expect(
          _src('lib/ui/ember/traffic_history_page.dart')
              .contains("Text('Loading…', style: Ember.body)"),
          isFalse);
      // Build 2118 re-point: AP-19's quota-aware days-left
      // colour keeps its shape (red when low).
      // SUPERSEDED by the build 2145 fix round (A6): the
      // healthy days-left value is now PLAIN caption colour
      // — green is reserved for status semantics app-wide;
      // red still marks quotaLow. The old green form must
      // not return.
      expect(
          _src('lib/ui/ember/ember_accounts.dart').contains(
              'color: sub.quotaLow ? Ember.red : null'),
          isTrue);
      expect(
          _src('lib/ui/ember/ember_accounts.dart').contains(
              'color: sub.quotaLow ? Ember.red : MapUi.pingGreen'),
          isFalse);
      for (final f in [
        'lib/ui/ember/openvpn_pages.dart',
        'lib/ui/ember/chain_builder_page.dart',
        'lib/ui/ember/smart_groups_page.dart',
      ]) {
        expect(_src(f).contains('EmberEmpty('), isTrue, reason: f);
      }
    });

    test('AP-14: the Psiphon auto label is short in en + fa', () {
      expect(_src('lib/l10n/app_en.arb').contains('"Automatic"'), isTrue);
      expect(
          _src('lib/l10n/app_en.arb').contains('Automatic (fastest)'),
          isFalse);
      // Scoped to the key: other fa strings legitimately
      // use the word elsewhere (mode names, smart pick).
      expect(
          _src('lib/l10n/app_fa.arb')
              .contains('"psiphonRegionAuto": "خودکار"'),
          isTrue);
    });

    test('AP-15: flags — FlagCircle at headers/home, extended set, '
        'es/mx simplified', () {
      final servers = _src('lib/ui/ember/ember_servers.dart');
      expect(servers.contains('countryFlagEmoji'), isFalse);
      expect(servers.contains('FlagCircle(code: flagCode!'), isTrue);
      expect(
          _src('lib/ui/ember/ember_home.dart')
              .contains('countryFlagEmoji'),
          isFalse);
      for (final c in ['pl', 'cz', 'hu', 'ro', 'ua', 'ch', 'gr', 'hr', 'tr', 'in']) {
        expect(File('assets/flags/$c.svg').existsSync(), isTrue,
            reason: c);
      }
      expect(File('assets/flags/es.svg').lengthSync(), lessThan(4096));
      expect(File('assets/flags/mx.svg').lengthSync(), lessThan(4096));
    });
  });

  group('B11 widget smoke', () {
    testWidgets('EmberBackground stacks the backdrop under content',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: EmberBackground(child: Text('content')),
        ),
      );
      expect(find.text('content'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });
  });
}
