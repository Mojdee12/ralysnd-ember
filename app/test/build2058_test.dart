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

    testWidgets('MapEngineChip keeps a 30 px glass in a 44 px hit area',
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
      expect(size.height, 44);
      expect(size.width, 128);
    });

    testWidgets('EmberToggle keeps a 26 px knob in a 44 px hit area',
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
      expect(size.height, 44);
      expect(size.width, 50);
    });

    testWidgets('MapBarCell label is 11 px, not 8 px micro-type',
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
      expect(text.style?.fontSize, 11);
    });

    test('fallback member row: bordered, chevron, 44 dp tall', () {
      final body = _classBody(
        _dart('ui/ember/ember_servers.dart'),
        'class _FallbackMemberRow',
      );
      expect(body, contains('BoxConstraints(minHeight: 44)'));
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

  group('micro-type floored at 9.5 px (audit §5)', () {
    test('no 7.5/8/8.5 px info text left in the shared widgets', () {
      final widgets = _dart('ui/ember/map_widgets.dart');
      expect(widgets, isNot(contains('fontSize: 7.5')));
      expect(widgets, isNot(contains('fontSize: 8,')));
      expect(widgets, isNot(contains('fontSize: 8.5')));
      expect(widgets, contains('fontSize: 9.5'));
      expect(widgets, contains('Color(0xFF7E93A8)'));
      expect(widgets, contains('Color(0xFF93A8BE)'));
    });

    test('profile-row ACTIVE pill and map labels floored at 9.5 px', () {
      final servers = _dart('ui/ember/ember_servers.dart');
      expect(servers, isNot(contains('fontSize: 8.5')));
      final map = _dart('ui/ember/world_map.dart');
      expect(map, contains('fontSize: 9.5'));
      expect(map, contains('fontSize: px(9.5)'));
      expect(map, isNot(contains('fontSize: 8.5')));
      expect(map, isNot(contains('fontSize: px(8.5)')));
    });
  });

  group('Home top spacers unified (audit §6 appearance lows)', () {
    test('every engine home starts its cards at the capped 18% spacer', () {
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
        expect(src, isNot(contains('height: 170')),
            reason: '$path still has a 170 px spacer');
        expect(src, isNot(contains('height: 118')),
            reason: '$path still has a 118 px spacer');
        expect(src, isNot(contains('SizedBox(height: 150)')),
            reason: '$path still has the fixed 150 px spacer');
        capped += 'height * 0.18'.allMatches(src).length;
      }
      // Build 2074 (UI audit item 3): the fixed 150 px spacer is
      // now a capped fraction — min(150, 18% of the viewport) —
      // in all seven homes: V2Ray + Psiphon (ember_home) + WARP +
      // MASQUE (aether_pages) + Lantern + OpenVPN + WG.
      expect(capped, 7);
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
      expect(body, contains('if (!account.active)'));
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
      expect(servers, contains('padding: const EdgeInsets.only(bottom: 9)'));
      expect(servers, contains('bottom: 8,'));
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
      expect(accounts, contains('return GlassCard('));
    });

    test('AWG "runs as plain WireGuard" comment already corrected', () {
      final wgConf = _dart('xray/wg_conf.dart');
      expect(wgConf, contains('was stale; corrected here'));
    });
  });
}
