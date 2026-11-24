/// Build 2058 gates — grouped Medium/Low sweep part 1 (audit §5/§6
/// appearance groups + comment-claims): shared-widget tap targets
/// and micro-type floors, fallback member-row affordance, map
/// micro-type, pause-strip wrap + Ember sheet, unified Home top
/// spacers, rounded settings-row splashes, account-card chevron,
/// and the NOT-A-FINDING pins for items the audit described that
/// the current tree already handles.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/ui/ember/map_widgets.dart';

String _read(String path) => File(path).readAsStringSync();

String _dart(String path) => _read('lib/$path');

/// The source of one class, from its `class X` line to the next
/// top-level `class ` line.
String _classBody(String src, String marker) {
  final start = src.indexOf(marker);
  assert(start >= 0, 'missing $marker');
  final next = src.indexOf('\nclass ', start + marker.length);
  return next < 0 ? src.substring(start) : src.substring(start, next);
}

void main() {
  group('tap targets are 44 dp (audit §5 shared widgets)', () {
    testWidgets('MapActionPill keeps a 24 px visual in a 48 px hit area',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: MapActionPill(
                icon: Icons.add_rounded,
                label: 'Add',
                onTap: null,
              ),
            ),
          ),
        ),
      );
      final size = tester.getSize(find.byType(MapActionPill));
      // Build 2074 (UI audit item 4): hit area raised 44 → 48 dp.
      expect(size.height, 48);
    });

    // Build 2083 (owner order, 2026-11-15): the hit area is
    // 36 px, not 2058's 44 — the rail's gaps read too large
    // on his phone. The 30 px glass is unchanged.
    // PIN UPDATED by build 2137 (visual review V-09): the
    // hit area grew 36 → 39 px (the reconciled maximum
    // under the review's ≤+3 px glass-gap bound and the
    // owner's 2083 rail order); the glass stays 30 px.
    testWidgets('MapEngineChip keeps a 30 px glass in a 39 px hit area',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MapEngineChip(
                name: 'V2Ray',
                active: false,
                highlight: true,
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      final size = tester.getSize(find.byType(MapEngineChip));
      expect(size.height, 39);
      expect(size.width, 128);
    });

    // Build 2092 (UI audit item 22): the toggle's vertical
    // padding went 9 → 11, so the hit area is the full
    // 48 dp — this pin follows the audit fix (was 44).
    testWidgets('EmberToggle keeps a 26 px knob in a 48 px hit area',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: EmberToggle(value: true, onChanged: (_) {}),
            ),
          ),
        ),
      );
      final size = tester.getSize(find.byType(EmberToggle));
      expect(size.height, 48);
      expect(size.width, 50);
    });

    testWidgets('MapBarCell label is 10 px, not 8 px micro-type',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: MapBarCell(label: 'Down', value: '1.2 MB/s'),
            ),
          ),
        ),
      );
      final text = tester.widget<Text>(find.text('DOWN'));
      // Build 2074 (UI audit item 23): bar labels raised 9.5 → 11.
      // Build 2083 (owner order, 2026-11-15): 11 → 10, the
      // bottom bar's type read too large on his phone.
      expect(text.style?.fontSize, 10);
    });

    // Build 2092 (UI audit item 57): the member row's floor
    // rose 44 → 48 dp — this pin follows the audit fix.
    test('fallback member row: bordered, chevron, 48 dp tall', () {
      final body = _classBody(
        _dart('ui/ember/ember_servers.dart'),
        'class _FallbackMemberRow',
      );
      expect(body, contains('BoxConstraints(minHeight: 48)'));
      expect(body, contains('chevron_right_rounded'));
      expect(body, contains('Border.all(color: MapUi.line)'));
    });

    test('power switch hit area is padded to 44 dp (source pin)', () {
      final body = _classBody(
        _dart('ui/ember/map_widgets.dart'),
        'class _PowerSwitch',
      );
      expect(body, contains('EdgeInsets.symmetric(vertical: 7)'));
    });
  });

  // Build 2092 (UI audit item 52): the micro-type floor rose
  // from 9.5 to 11 sp — the group and its pins follow.
  group('micro-type floored at 11 px (2092 item 52)', () {
    test('no 7.5/8/8.5/9.5 px info text left in the shared widgets', () {
      final widgets = _dart('ui/ember/map_widgets.dart');
      expect(widgets, isNot(contains('fontSize: 7.5')));
      expect(widgets, isNot(contains('fontSize: 8,')));
      expect(widgets, isNot(contains('fontSize: 8.5')));
      expect(widgets, isNot(contains('fontSize: 9.5')));
      // PIN UPDATED by build 2138 (visual review V-06): the
      // floor is the scale's micro step now — the literal
      // became the named constant; the floor stands.
      expect(widgets, contains('fontSize: Ember.fontMicro'));
      // PIN UPDATED by build 2144 (reskin): the two
      // blue-steel label colours are neutralised to the
      // samples' grey ramp at the same elements (steel
      // label #A8A8AE; lifted micro labels #8E8E93).
      expect(widgets, contains('Color(0xFFA8A8AE)'));
      expect(widgets, contains('Color(0xFF8E8E93)'));
    });

    test('profile-row ACTIVE pill and map labels floored at 11 px', () {
      final servers = _dart('ui/ember/ember_servers.dart');
      expect(servers, isNot(contains('fontSize: 8.5')));
      final map = _dart('ui/ember/world_map.dart');
      // PIN UPDATED by build 2137 (visual review V-22):
      // the plain 'fontSize: 11' lived in WorldMapPainter,
      // deleted as dead code; the live painter's label is
      // the px(11) below and the floor assertions stand.
      expect(map, contains('fontSize: px(11)'));
      expect(map, isNot(contains('fontSize: 9.5')));
      expect(map, isNot(contains('fontSize: px(9.5)')));
      expect(map, isNot(contains('fontSize: 8.5')));
      expect(map, isNot(contains('fontSize: px(8.5)')));
    });
  });

  group('Home top spacers unified (audit §6 appearance lows)', () {
    test('every engine home starts its cards at the shared capped spacer',
        () {
      const homes = [
        'ui/ember/ember_home.dart',
        'ui/ember/aether_pages.dart',
        'ui/ember/lantern_pages.dart',
        'ui/ember/openvpn_pages.dart',
        'ui/ember/wireguard_pages.dart',
      ];
      var capped = 0;
      for (final path in homes) {
        final src = _dart(path);
        if (path == 'ui/ember/ember_home.dart') {
          // PIN UPDATED by the R1 home-fidelity round
          // (2026-11-23): the one 'height: 170' in this file
          // is the connected hero's composition drop (pro3),
          // mid-list and state-gated — not a top spacer; the
          // top of every home stays the shared helper below.
          expect('height: 170'.allMatches(src).length, 1,
              reason: 'only the R1 connected-hero drop may use 170');
        } else {
          expect(src, isNot(contains('height: 170')),
              reason: '$path still has a 170 px spacer');
        }
        expect(src, isNot(contains('height: 118')),
            reason: '$path still has a 118 px spacer');
        expect(src, isNot(contains('SizedBox(height: 150)')),
            reason: '$path still has the fixed 150 px spacer');
        capped += 'emberHomeTopGap('.allMatches(src).length;
      }
      // Build 2074 (UI audit item 3): the fixed 150 px spacer is
      // now a capped fraction — min(150, 18% of the viewport) —
      // in all seven homes: V2Ray + Psiphon (ember_home) + WARP +
      // MASQUE (aether_pages) + Lantern + OpenVPN + WG.
      // Build 2092 (UI audit item 39): the seven per-page copies
      // of the formula became ONE shared helper,
      // emberHomeTopGap (22% capped at 120, defined once in
      // map_widgets) — the pin counts its call sites instead.
      expect(capped, 7);
      expect(
        _dart('ui/ember/map_widgets.dart'),
        contains('double emberHomeTopGap(double pageHeight)'),
      );
    });
  });

  group('pause strip + settings rows + account card', () {
    test('pause strip wraps instead of overflowing (source pin)', () {
      final shell = _dart('ui/ember/ember_shell.dart');
      expect(shell, contains("Paused · resumes in"));
      expect(shell, contains('Flexible('));
      expect(shell, contains("Text('Pause connection'"));
    });

    test('all four settings rows round their splash (source pin)', () {
      final settings = _dart('ui/ember/ember_settings.dart');
      expect(
        'borderRadius: BorderRadius.circular(14),'.allMatches(settings).length,
        4,
      );
    });

    test('inactive account card carries a chevron affordance', () {
      final body = _classBody(
        _dart('ui/ember/ember_accounts.dart'),
        'class _AccountCard',
      );
      expect(body, contains('chevron_right_rounded'));
      // PIN UPDATED by build 2098 (post-2097 audit L24):
      // the chevron now shows only when the card is
      // actually tappable — a turned-off account's card
      // takes no tap and no longer wears one.
      expect(
        body,
        contains(
          // PIN UPDATED by build 2145: same gate, same
          // chevron — the card's recomposition nests the
          // gate deeper, so the continuation line's
          // indentation moved (18 → 24 spaces).
          'if (!account.active &&\n'
          '                        (account.needsSignIn || account.enabled))',
        ),
      );
    });
  });

  group('NOT-A-FINDING pins (audit items already handled)', () {
    test('map badge is clamped inside the canvas (source pin)', () {
      final map = _dart('ui/ember/world_map.dart');
      expect(
        map,
        contains('center.dx.clamp(half + 4, screenWidth - half - 4)'),
      );
    });

    test('ACTIVE tag sits inside its card, cannot reach the row above', () {
      final servers = _dart('ui/ember/ember_servers.dart');
      // Build 2074 (UI audit item 26): the badge no longer
      // overhangs at all — it sits inside the card at top: 6
      // (at top: -7 it overlapped the row above and clipped at
      // scroll edges). The 8/9 px gap paddings below stay
      // pinned as belt-and-braces.
      expect(servers, contains('top: 6,'));
      expect(servers, isNot(contains('top: -7,')));
      // PIN UPDATED by batch 4 (fidelity rollout): the
      // belt-and-braces 'bottom: 9' gap padding this pin held
      // was retired by batch 2 — the profile rows became
      // contiguous hairlines and the row's own padding
      // carries the rhythm, so the 9 dp inter-row gap no
      // longer exists to pin. The placement rule itself
      // (the tag inside its row) is unchanged and stays
      // pinned by the top: 6 / bottom: 10 expects around
      // this note.
      // PIN UPDATED by build 2145 (composition rebuild):
      // the row's left tick (build 2144's active treatment,
      // kept) insets at top: 10 / bottom: 10 — the pre-2144
      // badge's bottom: 8 is gone with that badge. The
      // placement rule is unchanged: both marks sit inside
      // the row (label top: 6 above, tick insets here).
      expect(servers, contains('bottom: 10,'));
    });

    test('_SortPill no longer exists; _SubCard is a glass card', () {
      final lib = Directory('lib');
      var foundSortPill = false;
      for (final f in lib.listSync(recursive: true)) {
        if (f is File && f.path.endsWith('.dart')) {
          if (f.readAsStringSync().contains('_SortPill')) {
            foundSortPill = true;
          }
        }
      }
      expect(foundSortPill, isFalse);
      final accounts = _dart('ui/ember/ember_accounts.dart');
      // PIN UPDATED by build 2145 (composition rebuild):
      // _SubCard still returns its glass card (MapGlass);
      // _AccountCard's GlassCard was retired for the
      // sample's hairline panel (build2145_test pins the
      // MANAGE composition). The non-finding stands: the
      // cards are the designed containers of their build.
      // PIN RE-POINTED by the 2145 UI-review fix round (A2):
      // the skills review retired _SubCard's glass too — the
      // subscription now renders as the Servers page's open
      // editorial block (a DecoratedBox hairline block), so
      // the designed container this pin guards is that block.
      expect(accounts, contains('return DecoratedBox('));
    });

    test('AWG "runs as plain WireGuard" comment already corrected', () {
      final wgConf = _dart('xray/wg_conf.dart');
      expect(wgConf, contains('was stale; corrected here'));
    });
  });
}
