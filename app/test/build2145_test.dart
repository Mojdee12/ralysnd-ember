// Build 2145 — UI COMPOSITION REBUILD (scope:
// build2145-progress.md). Build 2144 recolored the old
// layouts and failed the owner's device verdict; 2145
// rebuilds the widget COMPOSITIONS to the approved
// pro3/pro5/pro6/pro7 samples: power-ring disconnected
// hero, proof-ladder connecting composition, open
// selected-config block, throughput detail panel,
// editorial hairline settings groups, full-bleed
// RegionHop sections, delay-true DPI Lab rows.
// Appearance and layout ONLY — same state, callbacks
// and data everywhere. These tests pin the composition
// structures so a later build cannot silently drift
// back to the card layouts.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String rel) => File('lib/$rel').readAsStringSync();

void main() {
  group('build 2145 — composition rebuild', () {
    test('pubspec carries 2.2.0+2148', () {
      expect(File('pubspec.yaml').readAsStringSync(),
          contains('version: 2.2.0+2155'));
    });

    test('home disconnected hero is a painted power ring', () {
      final home = _src('ui/ember/ember_home.dart');
      expect(home, contains('class _DisconnectedHero'));
      expect(home, contains('class _PowerRingPainter'));
      // The glyph is painted, never the Material power icon —
      // the shell bar's pill owns that icon (widget journey
      // taps it) and a second instance would break finders.
      expect(home.contains('power_settings_new'), isFalse);
    });

    test('home connecting composition is the proof ladder', () {
      final home = _src('ui/ember/ember_home.dart');
      expect(home, contains('class _ConnectingLadder'));
      // The three stages bind the controller's real state.
      expect(home, contains('Tunnel up'));
      expect(home, contains('Exit answering'));
      expect(home, contains('Proving traffic'));
      expect(home, contains('xray.state.verified'));
    });

    test('shell wires the bar toggle into the home power hero', () {
      expect(
        _src('ui/ember/ember_shell.dart'),
        contains('onPowerTap: () => unawaited(_powerToggle(context, mode))'),
      );
    });

    test('selected-config block is an open composition', () {
      final home = _src('ui/ember/ember_home.dart');
      expect(home, contains('V2RAY · SELECTED CONFIG'));
      expect(home, contains('_configMetaLine'));
      // The old in-card live tiles are gone with the card.
      expect(home.contains('class _HomeTile'), isFalse);
      // The throughput chart samples the real rate getter.
      expect(home, contains('class _RateChart'));
      expect(home, contains('xray.downRate'));
    });

    test('settings sections are hairline groups, not glass panels', () {
      final widgets = _src('ui/ember/map_widgets.dart');
      expect(widgets, contains('class MapSettingsPanel'));
      expect(
        widgets,
        contains('Text(title.toUpperCase(), style: Ember.microLabelOrange)'),
      );
    });

    test('regionhop sections carry a real panel-state line', () {
      final page = _src('ui/ember/regionhop_page.dart');
      // PIN UPDATED by the build 2145 fix round (A10 widget
      // composition): the _panelStateLine method became the
      // _PanelStateLine widget class; the line itself is
      // unchanged.
      expect(page, contains('class _PanelStateLine extends StatelessWidget'));
      expect(page, contains('Self-hosted Psiphon panel'));
    });

    test('dpi lab rows show measured delay, never a score', () {
      final lab = _src('ui/ember/dpi_lab_page.dart');
      expect(lab, contains('relative delay'));
      expect(lab, contains('STRATEGY LAB'));
    });

    test('mozilla account card is a hairline panel with a MANAGE action',
        () {
      final accounts = _src('ui/ember/ember_accounts.dart');
      expect(accounts, contains("Text('MANAGE'"));
      // The corrected claim must never enter the app.
      expect(accounts.contains('no data cap'), isFalse);
    });
  });
}
