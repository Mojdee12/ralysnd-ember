// Build 2137 — Stage 4 batch 1: the visual review's
// remaining findings, severity order (scope frozen in
// build2137-progress.md). This file pins what this build
// actually changed:
//
//  1. V-01 (Medium): token unification — Ember.text/dim/
//     card/cardSoft alias the MapUi navy ramp; two new
//     opaque MapUi tokens (card = the glass composite made
//     solid, cardSoft one lift above).
//  2. V2Ray #9: the fallback group card moved out of the
//     header panel into the list as its own first card.
//  3. V2Ray #6: the Connected strip wears the selected
//     row's wash + ember rim when connected-and-proven.
//  4. V2Ray #7 / V-19: profile-row meta capped at 2 lines
//     (totals keep the line; else TCP + speed combine).
//  5. V2Ray #10: a fully-filtered subscription keeps its
//     card head, subtitled "No configs match".
//  6. V-03: Ember.gradient stops are the approved spec's
//     #FF8533 → #E65116 (flat Ember.orange untouched).
//  7. V-05: EmberToggle OFF word #EDF2F8 (≈5.9:1).
//  8. V-09 rail leg: engine-chip tap box 36 → 39 px (the
//     reconciled maximum under the review's own ≤+3 px
//     glass-gap bound and the owner's 2083 rail order).
//  9. V-22: dead WorldMapPainter deleted.
// 10. V-27: app-lock page on EmberBackground + MapGlass.
// 11. V-28: welcome hero is EmberShieldMark.
// 12. V-10: spec amended — σ10 recorded as shipped.
// 13. V-11: the bottom-bar 10/10.5 sp exception recorded
//     in the theme (owner order 2083).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/ui/ember/ember_theme.dart';

String _src(String rel) => File('lib/$rel').readAsStringSync();

void main() {
  group('V-01 token unification', () {
    test('Ember text tiers alias the MapUi ramp', () {
      expect(Ember.text, MapUi.text);
      // PIN UPDATED by build 2144 (reskin): the text ramp is
      // the samples' neutral white/grey now, not the navy one.
      expect(Ember.text, const Color(0xFFF5F5F4));
      expect(Ember.dim, MapUi.dim);
      expect(Ember.dim, const Color(0xFF9A9AA0));
    });

    test('Ember card pair aliases the new opaque MapUi tokens', () {
      expect(Ember.card, MapUi.card);
      // PIN UPDATED by build 2144 (reskin): neutral charcoal
      // pair (#101216 / #17191E) replaces the navy pair.
      expect(MapUi.card, const Color(0xFF101216));
      expect(Ember.cardSoft, MapUi.cardSoft);
      expect(MapUi.cardSoft, const Color(0xFF17191E));
    });

    test('the retired graphite values are gone from the tokens', () {
      final theme = _src('ui/ember/ember_theme.dart');
      expect(theme, isNot(contains('static const card = Color(0xFF1C1D23)')));
      expect(theme, isNot(contains('static const text = Color(0xFFF4F1EA)')));
      expect(theme, isNot(contains('static const dim = Color(0xFFA5A2AC)')));
    });
  });

  group('V-03 gradient stops (approved spec)', () {
    // PIN UPDATED by build 2144 (reskin): the approved
    // samples' primary surfaces are FLAT #FF7A29 — the
    // gradient token flattens to the single accent.
    test('Ember.gradient is the flat reskin accent', () {
      expect(Ember.gradient.colors, const [
        Color(0xFFFF7A29),
        Color(0xFFFF7A29),
      ]);
    });

    test('the flat orange token is the reskin accent', () {
      expect(Ember.orange, const Color(0xFFFF7A29));
    });
  });

  group('V-05 toggle OFF word', () {
    test('the OFF word is the near-white, not the old 2.66:1 slate', () {
      final theme = _src('ui/ember/ember_theme.dart');
      expect(theme, contains('const Color(0xFFEDF2F8)'));
      expect(theme, isNot(contains('const Color(0xFF22262D)')));
    });
  });

  group('V-09 rail chip tap box', () {
    test('the box is 39 px with the glass still 128x30', () {
      final widgets = _src('ui/ember/map_widgets.dart');
      final chip = widgets.substring(
        widgets.indexOf('class MapEngineChip'),
        widgets.indexOf('class MapEngineChip') + 6000,
      );
      expect(chip, contains('height: 39,'));
      expect(chip, contains('height: 30,'));
      expect(chip, contains('width: 128,'));
    });
  });

  group('V-22 dead painter', () {
    test('WorldMapPainter is deleted; MapActorsPainter stays', () {
      final map = _src('ui/ember/world_map.dart');
      expect(map, isNot(contains('class WorldMapPainter')));
      expect(map, contains('class MapActorsPainter'));
    });
  });

  group('V2Ray tab items (#6/#7/#9/#10)', () {
    final servers = _src('ui/ember/ember_servers.dart');

    test('#6: the strip upgrades only when connected-and-proven', () {
      // PIN UPDATED by build 2144 (reskin): the strip is
      // a flat hairline row now (no gradient wash), but
      // the proof gate itself is byte-identical — the
      // state word still only claims 'Connected' when
      // the session is verified (or WireGuard), and an
      // unproven tunnel still reads 'Connected — not
      // answering'.
      expect(
        servers,
        contains(
          'final proven = xray.state.verified || '
          'p?.protocol == Protocol.wireguard;',
        ),
      );
      expect(servers, contains("'Connected — not answering'"));
      expect(
        servers,
        contains('border: Border(bottom: BorderSide(color: MapUi.line))'),
      );
    });

    test('#7: the row meta combines TCP + speed on one line', () {
      expect(servers, contains("].join(' · '),"));
      expect(servers, contains('else if (profile.lastSpeedBps >= 0 ||'));
    });

    test('#9: the fallback card is a list item, not header content', () {
      expect(servers, contains('class _ServersFallbackItem'));
      expect(servers, contains('class _FallbackCardShell'));
      expect(
        servers.split('items.add(const _ServersFallbackItem());').length - 1,
        2, // both list builders (grouped + by-country)
      );
      expect(
        servers.split('_FallbackGroupCard(xray: xray)').length - 1,
        1, // instantiated only inside the shell
      );
    });

    test('#10: a fully-hidden subscription keeps its card head', () {
      expect(servers, contains('members.isEmpty && storeMembers.isEmpty'));
      expect(servers.split("'No configs match'").length - 1, 2);
      expect(
        servers,
        contains('pingEnabled: members.isNotEmpty && !xray.scanRunning'),
      );
    });
  });

  group('V-27 app lock ground', () {
    test('the lock page floats bare on EmberBackground', () {
      final lock = _src('ui/ember/app_lock.dart');
      expect(lock, contains('body: EmberBackground('));
      // PIN UPDATED by build 2144 (reskin): the lock
      // pad's MapGlass panel is retired in the pro6
      // app-lock sample's language — the pad floats bare
      // on the background. (The settings page's own
      // MapGlass panels are a different construction and
      // remain.)
      expect(lock, isNot(contains('child: MapGlass(')));
    });
  });

  group('V-28 welcome hero mark', () {
    test('the welcome page wears EmberShieldMark, not the stock icon', () {
      final welcome = _src('ui/welcome_page.dart');
      expect(welcome, contains('const EmberShieldMark(size: 56)'));
      expect(welcome, isNot(contains('Icons.shield_rounded')));
    });
  });

  group('V-10 / V-11 records', () {
    test('V-11: the bottom-bar type exception is recorded in the theme', () {
      final theme = _src('ui/ember/ember_theme.dart');
      expect(theme, contains('Type-floor exception (owner order, build 2083'));
    });

    test('V-10: the spec sheet records sigma-10 as shipped', () {
      final spec = File(
        '../../../your_files/ember-mobile-design/gemini-mobile-spec.md',
      );
      expect(spec.existsSync(), isTrue);
      expect(
        spec.readAsStringSync(),
        contains('σ10 is the accepted production value'),
      );
    });
  });

  test('pubspec is 2.2.0+2147', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('version: 2.2.0+2147'),
    );
  });
}
