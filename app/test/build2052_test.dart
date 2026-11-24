import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/lantern/lantern_controller.dart';

/// Build 2052 — the Lantern connect fix (owner-reported,
/// Critical-class; diagnosis
/// ~/workspace/ember-app/lantern-connect-diagnosis-2026-11-14.md).
///
/// The 2052 suite pinned the CLI daemon's connect ladder:
/// the warm/cold budgets, the stdin `via` WARP-leg bootstrap,
/// the kept-config parser, the stdout listening contract, and
/// the carriesWarm data-plane proof before the TUN raise.
///
/// SUPERSEDED in build 2129 (leg 1, the gomobile swap): the
/// CLI daemon, its stdout contract, its stdin, its kept
/// config and the SOCKS port the proof ran through are all
/// gone — the gomobile core fetches its list in-process,
/// creates its own TUN through Ember's PlatformInterface
/// bridge, and reports connected through its own
/// isVPNConnected(). The ladder-era pins are re-pointed here
/// to the supersession itself (the mechanisms must stay
/// deleted) plus the one surviving shape: a single generous
/// connect budget with a plain give-up message, because a
/// first list fetch on a filtered network can still take
/// minutes and is still needed only once.
void main() {
  group('Lantern connect budget (2129 form of the 2052 ladder)', () {
    test('one budget: four minutes for the first list', () {
      expect(lanternConnectBudget, const Duration(seconds: 240));
    });

    test('the give-up message names the four minutes and the once-only list',
        () {
      final m = lanternGiveUpMessage();
      expect(m, contains('four minutes'));
      expect(m, contains('only once'));
      // No WARP-leg claim: the leg died with the CLI stdin.
      expect(m, isNot(contains('WARP')));
    });
  });

  group('Supersession pins: the 2052 mechanisms stay deleted', () {
    String read(String path) => File(path).readAsStringSync();

    test('no ladder, no stdin via, no kept-config parser, no SOCKS proof', () {
      final kt = read(
        'android/app/src/main/kotlin/com/ralysnd/ember/LanternVpnService.kt',
      );
      expect(kt, isNot(contains('WARM_LISTEN_MS')));
      expect(kt, isNot(contains('COLD_GIVEUP_MS')));
      expect(kt, isNot(contains('fun sendVia')));
      expect(kt, isNot(contains('fun carriesWarm(')));
      expect(kt, isNot(contains('keptConfig')));
      expect(kt, isNot(contains('ProcessBuilder')));
      expect(kt, isNot(contains('body.startsWith("listening")')));
    });

    test('MainActivity exposes no via channels', () {
      final kt = read(
        'android/app/src/main/kotlin/com/ralysnd/ember/MainActivity.kt',
      );
      expect(kt, isNot(contains('"lanternVia"')));
      expect(kt, isNot(contains('"lanternViaDirect"')));
      expect(kt, isNot(contains('LanternCore')));
    });

    test('the Dart side drives no ladder and no leg', () {
      final c = read('lib/lantern/lantern_controller.dart');
      expect(c, isNot(contains('hasKeptConfig')));
      expect(c, isNot(contains('lanternColdBudget')));
      expect(c, isNot(contains('LanternPlatform.via(')));
      expect(c, isNot(contains('viaWarpLeg')));
      expect(c, contains('lanternConnectBudget'));
      expect(c, contains('lanternGiveUpMessage()'));
      final p = read('lib/lantern/lantern_platform.dart');
      expect(p, isNot(contains("'lanternVia'")));
    });
  });
}
