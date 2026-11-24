// Build 2129, leg 4 — Aether MiM (MASQUE-in-MASQUE) pins.
//
// mim joins the protocol sets end to end: WarpProfile's
// stored pick list, warp_args' MASQUE-family arg shape, the
// Aether engine's options + pages, and AetherCore's env
// mapping (AETHER_PROTOCOL=mim verbatim, the MASQUE env
// family, and a pinned peer naming the OUTER hop through
// AETHER_MIM_OUTER_PEER — all verified against the shipped
// libaether.so's own strings, never LML's binary).
//
// Default-off shape: the default protocol stays masque on
// both models; mim exists only when the user picks it.
// gool-classic stays unoffered.

library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/aether/aether_platform.dart';
import 'package:firefox_vpn/xray/warp_args.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String _src(String path) => File(path).readAsStringSync();

void main() {
  group('WarpProfile protocol set', () {
    test('the default protocol is unchanged: masque', () {
      expect(WarpProfile().protocol, 'masque');
    });

    test('mim round-trips through the profile JSON', () {
      final w = WarpProfile()..protocol = 'mim';
      final back = WarpProfile.fromJson(w.toJson());
      expect(back.protocol, 'mim');
    });

    test('gool-classic is still not offered (falls back)', () {
      expect(
        WarpProfile.fromJson({'protocol': 'gool-classic'}).protocol,
        'masque',
      );
    });

    test('an unknown protocol still falls back to masque', () {
      expect(WarpProfile.fromJson({'protocol': 'nope'}).protocol, 'masque');
    });
  });

  group('warp_args for mim', () {
    test('passes --protocol mim with the MASQUE-family shape', () {
      final w = WarpProfile()..protocol = 'mim';
      final args = buildWarpArgs(w);
      expect(args, containsAllInOrder(['--protocol', 'mim']));
      // MASQUE family: the SNI and the H2 carrier are passed,
      // exactly as for masque/gool.
      expect(args, containsAllInOrder(['--masque-sni', w.masqueSni]));
      expect(args, contains('--h2'));
      // fragment defaults OFF (the 2114 reset) — no flag.
      expect(args, isNot(contains('--fragment')));
    });

    test('fragment on adds --fragment for mim, as for masque', () {
      final w = WarpProfile()
        ..protocol = 'mim'
        ..fragment = true;
      expect(buildWarpArgs(w), contains('--fragment'));
    });

    test('the wg arg shape is untouched (no MASQUE family)', () {
      final w = WarpProfile()..protocol = 'wg';
      final args = buildWarpArgs(w);
      expect(args, containsAllInOrder(['--protocol', 'wg']));
      expect(args, isNot(contains('--masque-sni')));
    });

    test('the register kind passes mim through to the binary', () {
      final w = WarpProfile()..protocol = 'mim';
      expect(warpRegisterKind(w), 'mim');
    });
  });

  group('AetherOptions protocol set', () {
    test('the default protocol is unchanged: masque', () {
      expect(const AetherOptions().protocol, 'masque');
    });

    test('mim round-trips through the options JSON', () {
      final back = AetherOptions.fromJson(
        const AetherOptions(protocol: 'mim').toJson(),
      );
      expect(back.protocol, 'mim');
    });
  });

  group('wiring pins (source)', () {
    test('AetherCore maps the MASQUE env family + outer peer for mim', () {
      final kt = _src(
        'android/app/src/main/kotlin/com/ralysnd/ember/AetherCore.kt',
      );
      expect(kt, contains('AETHER_MIM_OUTER_PEER'));
      expect(kt, contains('o.protocol == "mim") env["AETHER_MIM_OUTER_PEER"]'));
      // mim rides the carrier ladder's auto resolution.
      expect(kt, contains('options.protocol == "mim"'));
      // mim's identity is the MASQUE family's (ensureIdentity).
      expect(kt, contains('protocol == "mim"'));
    });

    test('the Dart connect flow walks the ladder for mim', () {
      final c = _src('lib/aether/aether_controller.dart');
      expect(c, contains("options.protocol == 'mim'"));
    });

    test('both Aether protocol pickers offer mim', () {
      final p = _src('lib/ui/ember/aether_pages.dart');
      expect("'masque', 'wg', 'gool', 'mim'".allMatches(p).length, 2);
      expect(p, contains("'mim' => 'MASQUE in MASQUE'"));
      // The keepalive row stays hidden for mim on both pages
      // (AETHER_WG_KEEPALIVE is never written for it).
      expect("o.protocol != 'mim'".allMatches(p).length, 2);
    });

    test('the EmberWarp settings picker offers mim', () {
      final p = _src('lib/ui/ember/warp_settings_page.dart');
      expect(p, contains("('mim', 'MiM (MASQUE over MASQUE)')"));
    });
  });
}
