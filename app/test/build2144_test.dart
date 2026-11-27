// Build 2144 — FULL-APP RESKIN (scope:
// build2144-progress.md). Appearance and layout ONLY:
// the approved pro3/pro5/pro6/pro7 samples' design
// language (near-black ground, ember orange sole
// accent, huge light hero numerals, tracked uppercase
// micro-labels, hairline panels) applied to the theme
// tokens and every Android-reachable surface. No
// engine, connection, DNS, default or string changes.
// These tests pin the token layer the reskin stands
// on, so a later build cannot silently drift the
// palette back.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/ui/ember/ember_theme.dart';

String _src(String rel) => File('lib/$rel').readAsStringSync();

void main() {
  group('build 2144 — reskin tokens', () {
    test('pubspec carries 2.2.0+2148', () {
      expect(File('pubspec.yaml').readAsStringSync(),
          contains('version: 2.2.0+2156'));
    });

    test('ground is the samples near-black #050607', () {
      expect(Ember.bg, const Color(0xFF050607));
      expect(Ember.surface, const Color(0xFF0C0D10));
      expect(Ember.field, const Color(0xFF0A0B0D));
    });

    test('sole accent is the samples ember orange #FF7A29', () {
      expect(Ember.orange, const Color(0xFFFF7A29));
      // The old orange is gone from the whole lib tree.
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is File && f.path.endsWith('.dart')) {
          expect(f.readAsStringSync().contains('FF7A1A'), isFalse,
              reason: '${f.path} still carries the retired orange');
        }
      }
    });

    test('accent gradient is flattened to the single orange', () {
      expect(Ember.gradient.colors,
          const [Color(0xFFFF7A29), Color(0xFFFF7A29)]);
    });

    test('hero type steps exist above the frozen six-step scale', () {
      expect(Ember.fontHero, 54);
      expect(Ember.fontNumeral, 100);
      expect(Ember.hero.fontWeight, FontWeight.w300);
      expect(Ember.numeral.fontWeight, FontWeight.w200);
      // The frozen V-06 steps are untouched.
      expect(Ember.fontMicro, 11);
      expect(Ember.fontSmall, 12.5);
      expect(Ember.fontBody, 13.5);
      expect(Ember.fontTitle, 15);
      expect(Ember.fontHeadline, 17);
      expect(Ember.fontDisplay, 21);
    });

    test('micro-labels are tracked uppercase orange/neutral', () {
      expect(Ember.microLabelOrange.color, Ember.orange);
      expect(Ember.microLabelOrange.letterSpacing, 2.2);
      expect(Ember.microLabel.letterSpacing, 2.2);
    });

    test('map chrome is neutral charcoal, no blue tints', () {
      expect(MapUi.card, const Color(0xFF101216));
      expect(MapUi.cardSoft, const Color(0xFF17191E));
      expect(MapUi.text, const Color(0xFFF5F5F4));
      expect(MapUi.dim, const Color(0xFF9A9AA0));
      expect(MapUi.baseTop, const Color(0xFF07080A));
      expect(MapUi.baseBottom, const Color(0xFF050607));
    });

    test('primary button is a flat full pill', () {
      final theme = _src('ui/ember/ember_theme.dart');
      expect(theme, contains('BorderRadius.circular(999)'));
      // The one gradient token is the flat orange pair
      // (the runtime pin above covers Ember.gradient;
      // this pins the source literal too).
      expect(
        theme,
        contains('colors: [Color(0xFFFF7A29), Color(0xFFFF7A29)]'),
      );
    });

    test('shell carries the pro3 control bar; home the connected hero', () {
      expect(_src('ui/ember/ember_shell.dart'),
          contains('class _ShellControlBar'));
      expect(_src('ui/ember/ember_home.dart'),
          contains('class _ConnectedHero'));
    });

    test('no blue-tinted literals survive in the ember UI tree', () {
      const banned = [
        '93A8BE', '54687F', 'D9E4F2', '7E93A8', '8FA3BC', //
        '1E3147', '16222F', '80A7D8', '4B6B94', '121F31',
        '182636', '0B1320', '52759C', '142234',
      ];
      for (final f in Directory('lib/ui/ember')
          .listSync(recursive: true)) {
        if (f is File && f.path.endsWith('.dart')) {
          final body = f.readAsStringSync();
          for (final hex in banned) {
            expect(body.contains(hex), isFalse,
                reason: '${f.path} still carries banned tint $hex');
          }
        }
      }
    });
  });
}
