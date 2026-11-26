/// Build 2118 — the appearance fix round (owner order
/// 2026-11-19 15:33), scoped to the Gemini drift items on the
/// seven scored surfaces (appearance-gemini-scores-2116.md).
/// Appearance/layout only; the approved Map Control samples
/// outrank Gemini where they conflict (judgment calls J1–J9 in
/// build2118-progress.md).
///
/// Source pins for the round's root-cause fixes:
///  - the backdrop asset chain: a 3200px WebP (8.9 px/unit,
///    was 2048px/5.7) decoded at cacheWidth 2880 (was 1440) —
///    the portrait cover transform displays ~9.4 px/unit, so
///    the old chain upscaled the dot field 2×+ into blocks;
///  - the bake palette/geometry retune (greyer, finer dots,
///    quieter grid);
///  - the shell header: no Spacer splitting the brand column's
///    width (the "Ralysn..." truncation root cause);
///  - the brand panel at sample size with the luminous rim;
///  - the bottom-bar cell: FittedBox, never wraps;
///  - the server row's latency as bare text (sample 5), not a
///    bordered pill;
///  - the Settings Connection monolith split into three
///    panels, rows untouched;
///  - the DPI Lab's glass-pill actions instead of the solid
///    gradient EmberButton.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

String _between(String text, String from, String to) {
  final a = text.indexOf(from);
  final b = text.indexOf(to, a + from.length);
  expect(a, isNonNegative, reason: 'anchor "$from" not found');
  expect(b, isNonNegative, reason: 'anchor "$to" not found');
  return text.substring(a, b);
}

void main() {
  test('pubspec is 2.2.0+2119', () {
    expect(_read('pubspec.yaml'), contains('version: 2.2.0+2155'));
  });

  test('backdrop asset is a 3200px WebP over 600 KB', () {
    // PIN UPDATED by build 2150 (engine appearance audit
    // E49-19): the coarse map_backdrop.webp was removed
    // (dead since 2148). The asset this pin's facts were
    // always about — the shipped 3200×1600 VP8 bake — is
    // the home asset every surface paints; the same
    // assertions now read it.
    final bytes =
        File('assets/backdrop/map_backdrop_home.webp').readAsBytesSync();
    expect(bytes.length, greaterThan(600000));
    // Lossy VP8: 'VP8 ' chunk at 12, keyframe magic at 23,
    // 14-bit width/height at 26/28.
    expect(String.fromCharCodes(bytes.sublist(12, 16)), 'VP8 ');
    final width = (bytes[26] | (bytes[27] << 8)) & 0x3FFF;
    final height = (bytes[28] | (bytes[29] << 8)) & 0x3FFF;
    expect(width, 3200);
    expect(height, 1600);
  });

  test('bake script carries the retuned dot field', () {
    final bake = _read('tool/bake_backdrop_mobile.py');
    expect(bake, contains('interior = (64, 82, 102)'));
    expect(bake, contains('r_screen = 1.02'));
    expect(bake, contains('int(0.15 * 255)'));
  });

  test('backdrop decode cap matches the asset class', () {
    final widgets = _read('lib/ui/ember/map_widgets.dart');
    expect(widgets, contains('cacheWidth: 2880'));
  });

  test('brand panel: 2118 size/rim superseded by the 2121 restore', () {
    // Build 2121 (owner device verdict 2026-11-19 21:57):
    // the enlarged luminous panel read too big on his phone
    // and reached into the middle of the screen — this
    // round's panel change is reverted to the pre-2118
    // compact footprint. The rest of the round stands.
    final widgets = _read('lib/ui/ember/map_widgets.dart');
    final panel = _between(
      widgets,
      'class MapBrandPanel',
      'class MapEngineChip',
    );
    expect(panel, isNot(contains('luminous: true')));
    // PIN UPDATED by build 2138 (visual review V-06): the
    // brand panel's 13 sp is the scale's body step now.
    expect(panel, contains('fontSize: Ember.fontBody'));
  });

  test('bottom-bar cells scale down instead of wrapping', () {
    final widgets = _read('lib/ui/ember/map_widgets.dart');
    final cell = _between(widgets, 'class MapBarCell', 'class MobileMapBar');
    expect(cell, contains('BoxFit.scaleDown'));
    expect(cell, contains('softWrap: false'));
  });

  test('shell header: 2118 no-Spacer split superseded by 2121', () {
    // Build 2121 (owner device verdict 2026-11-19 21:57):
    // the Spacer is back (weighted 7:2, not 50/50) so the
    // brand hugs the top-left at its compact width and the
    // engine rail stays in the corner like before.
    // PIN UPDATED by build 2147 (fix item #23, owner device
    // verdict 2026-11-24 on shipped 2146): the whole tower —
    // brand panel, Spacer split and stacked rail — is
    // superseded by the slim non-Home header (Home brand line
    // + one horizontal chip row). The pins follow the change.
    // PIN UPDATED by build 2148 (FIX 3, owner order
    // 2026-11-24 on shipped 2147): the chip row is superseded
    // in turn — the non-Home header is the brand line with a
    // BACK control; no engine selector rides it.
    final shell = _read('lib/ui/ember/ember_shell.dart');
    final header = _between(shell, 'Widget _header()', 'Widget build(');
    expect(header, isNot(contains('Spacer(flex: 2)')));
    expect(header, isNot(contains('MapBrandPanel(')));
    expect(header, contains('_homeHeader(backToHome: true)'));
    expect(header, isNot(contains('SingleChildScrollView')));
  });

  test('server latency is bare text, not a bordered pill', () {
    final servers = _read('lib/ui/ember/ember_servers.dart');
    final pill = _between(servers, 'class _PingPill', 'class _ProfileRow');
    expect(pill, isNot(contains('BoxDecoration')));
    expect(pill, contains('FontWeight.w800'));
  });

  test('settings Connection monolith is split into three panels', () {
    final settings = _read('lib/ui/ember/ember_settings.dart');
    expect(settings, contains("title: 'Sniffing'"));
    expect(settings, contains("title: 'Advanced'"));
  });

  test('DPI Lab actions are glass pills, cards flat hairline', () {
    final lab = _read('lib/ui/ember/dpi_lab_page.dart');
    // PIN UPDATED by the build 2145 fix round (A10 widget
    // composition): the _labAction method became the
    // _LabAction widget class; the actions are still the
    // same glass pills.
    expect(lab, contains('_LabAction'));
    expect(lab, isNot(contains('EmberButton(')));
    // PIN UPDATED by build 2144 (reskin): the luminous
    // card rim is retired — the Lab's cards are flat
    // hairline panels in the pro6 editorial language.
    expect(lab, isNot(contains('luminous: true')));
  });
}
