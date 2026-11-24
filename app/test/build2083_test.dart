/// Build 2083 gates — the owner's three device reports on
/// build 2079 (2026-11-15, with screenshot):
/// (1) a VLESS session lit the V2Ray AND WireGuard chips
/// ACTIVE at once — WireGuard is a section over the shared
/// Xray core (build 2032) and both chips read the same bare
/// engine state; the split now follows the session profile's
/// protocol ([xraySectionActive] + XrayController.sessionProfile);
/// (2) the right rail's chip spacing read too large — the
/// chip box is 36 px (glass unchanged at 30) and the rail's
/// run spacing is 3, a 9 px glass-to-glass gap instead of 19;
/// (3) the bottom bar's type read too large — the state word
/// is 10 px, the cell label 10, the cell value 10.5.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/ui/ember/ember_shell.dart';
import 'package:firefox_vpn/ui/ember/map_widgets.dart';

String _dart(String path) => File('lib/$path').readAsStringSync();

void main() {
  group('build 2083 — one Xray session lights exactly one section chip', () {
    test('truth table: idle lights neither section', () {
      for (final wg in [true, false]) {
        expect(
          xraySectionActive(
            running: false,
            connecting: false,
            sessionIsWireGuard: wg,
            wireGuardSection: false,
          ),
          isFalse,
        );
        expect(
          xraySectionActive(
            running: false,
            connecting: false,
            sessionIsWireGuard: wg,
            wireGuardSection: true,
          ),
          isFalse,
        );
      }
    });

    test('truth table: a VLESS session lights V2Ray only', () {
      expect(
        xraySectionActive(
          running: true,
          connecting: false,
          sessionIsWireGuard: false,
          wireGuardSection: false,
        ),
        isTrue,
      );
      expect(
        xraySectionActive(
          running: true,
          connecting: false,
          sessionIsWireGuard: false,
          wireGuardSection: true,
        ),
        isFalse,
      );
    });

    test('truth table: a WireGuard session lights WireGuard only', () {
      expect(
        xraySectionActive(
          running: true,
          connecting: false,
          sessionIsWireGuard: true,
          wireGuardSection: false,
        ),
        isFalse,
      );
      expect(
        xraySectionActive(
          running: true,
          connecting: false,
          sessionIsWireGuard: true,
          wireGuardSection: true,
        ),
        isTrue,
      );
    });

    test('truth table: connecting counts as a session', () {
      expect(
        xraySectionActive(
          running: false,
          connecting: true,
          sessionIsWireGuard: true,
          wireGuardSection: true,
        ),
        isTrue,
      );
      expect(
        xraySectionActive(
          running: false,
          connecting: true,
          sessionIsWireGuard: false,
          wireGuardSection: true,
        ),
        isFalse,
      );
    });

    test('the controller exposes the session profile', () {
      final controller = _dart('xray/xray_controller.dart');
      expect(controller, contains('Profile? get sessionProfile'));
      expect(
        controller,
        contains('_profileById(_connectedProfileId) ?? selected'),
      );
    });

    test('the shell splits the chips and counts both sections', () {
      final shell = _dart('ui/ember/ember_shell.dart');
      expect(shell, contains('wireGuardSection: false'));
      expect(shell, contains('wireGuardSection: true'));
      expect(
        shell,
        contains('_xray.sessionProfile?.protocol == Protocol.wireguard'),
      );
      // Since the split, _anyEngineActive must count case 5
      // explicitly — it was omitted while 5 duplicated 1.
      final anyBody = shell.substring(
        shell.indexOf('bool get _anyEngineActive'),
        shell.indexOf('bool get _anyEngineActive') + 400,
      );
      expect(anyBody, contains('_engineActive(5)'));
    });
  });

  group('build 2083 — rail spacing and bottom-bar type (owner order)', () {
    // Build 2092 (items 34/60): run spacing 3 → 0 — the chip
    // box carries 3+3 dp of slack, so the glass-to-glass gap
    // stays 6 dp. This pin follows the audit fix; the 2083
    // owner's-order spacing history stands above.
    test('the rail wraps with 0 px run spacing (2092)', () {
      final shell = _dart('ui/ember/ember_shell.dart');
      expect(shell, contains('Wrap(spacing: 6, runSpacing: 0'));
    });

    testWidgets('the bottom bar state word is 10 px', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MobileMapBar(
              on: true,
              busy: false,
              onToggle: () {},
              stateWord: 'Connected',
              cells: const [
                (label: 'ACTIVE CONFIG', value: 'Nahan-node'),
                (label: 'EXIT IP', value: '192.124.18.1'),
                (label: 'UP', value: '1.1 MB/s'),
                (label: 'DOWN', value: '2.2 MB/s'),
              ],
              microLine: 'LATENCY 120ms • VLESS',
            ),
          ),
        ),
      );
      final word = tester.widget<Text>(find.text('Connected'));
      expect(word.style?.fontSize, 10);
      final value = tester.widget<Text>(find.text('1.1 MB/s'));
      expect(value.style?.fontSize, 10.5);
    });
  });
}
