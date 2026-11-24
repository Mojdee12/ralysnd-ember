/// Build 2083 gates — the MASQUE carrier ladder.
///
/// The owner's build-2079 log (2026-11-15) is the defect:
/// MASQUE started pinned to HTTP/3 (the shipped default),
/// the core's prober scanned 2079 candidates for 45 s, found
/// no gateway, and rescanned the identical H3 scan forever
/// — the core does NOT fall back to HTTP/2 by itself during
/// the gateway hunt, and Ember's 2074 "auto" only ever picked
/// ONE carrier before the connect. In ralysnd (byte-identical
/// core) MASQUE connects on the same phone because the app
/// walks the carrier ladder in one connect.
///
/// This build ports that ladder (masque-scan-diagnosis-
/// 2026-11-15.md is the full record):
///  - MasqueRung (native): H3 → H2 → H2+fragment →
///    H2+semi-python+fragment → H2+semi-python+tlshello,
///    remembered-first; AetherSlot.connectMasque walks it,
///    each rung a real engine run proven by the warp trace
///    and the 2080 data proof before any TUN; a rung fails
///    after ONE full scan cycle (scanCycleFailed) and the
///    walk advances; the winner is remembered per network.
///  - 'auto' is the default transport; a stored unmarked
///    'h3' (the old default, indistinguishable from an
///    explicit pick) migrates to 'auto'; an unmarked 'h2'
///    is marked explicit and honored (migrateMasqueTransport).
///  - AETHER_IP resolves per network (AetherFamily, the
///    CfFamily port); AETHER_MASQUE_H2_FRAGMENT is always
///    written; the Dart connect is bounded by
///    masqueAutoConnectTimeout, the native walk by
///    ladderTotalMs — the same arithmetic.
///
/// These pins prove the wiring and the pure logic. What only
/// the owner's phone can prove — a rung actually carrying
/// MASQUE on his filtered line — is NOT claimed here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/aether/aether_platform.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

void main() {
  group('build 2083 — the ladder order (native source pins)', () {
    test('MasqueRung lists the five rungs in ralysnd order', () {
      final kt = ktSrc('AetherCore.kt');
      final at = kt.indexOf('enum class MasqueRung');
      expect(at, greaterThan(0), reason: 'MasqueRung is ported');
      final body = kt.substring(at, kt.indexOf('companion object', at));
      final keys = [
        'H3("h3"',
        'H2("h2"',
        'H2_FRAGMENT("h2frag"',
        'H2_SEMI_PYTHON("h2semipy"',
        'H2_TLSHELLO("h2tlshello"',
      ];
      var last = -1;
      for (final k in keys) {
        final i = body.indexOf(k);
        expect(i, greaterThan(last), reason: '$k in ladder order');
        last = i;
      }
      // The rung shapes: only the fragment rungs fragment;
      // the last two carry the semi-python ClientHello; only
      // the last dials through the tlshello exit.
      expect(body.contains('H2_FRAGMENT("h2frag", "h2", true'), isTrue);
      expect(body.contains('AetherTls.SEMI_PYTHON'), isTrue);
      expect(body.contains('tlsHelloExit = true'), isTrue);
    });

    test('the ladder puts the remembered rung first, then the rest', () {
      final kt = ktSrc('AetherCore.kt');
      expect(
        kt.contains('(listOfNotNull(remembered) + values()).distinct()'),
        isTrue,
        reason: 'ladder(remembered) — ralysnd\'s order function',
      );
      expect(kt.contains('fun connectMasque('), isTrue);
      expect(kt.contains('MasqueRung.ladder(remembered)'), isTrue);
      // The winner is remembered only after the proofs, and a
      // remembered rung that fails is forgotten.
      expect(kt.contains('MasqueCarrier.remember(context, rung)'), isTrue);
      expect(
        kt.contains('if (rung == remembered) MasqueCarrier.forget(context)'),
        isTrue,
      );
    });

    test('a rung is proven by the trace and the data proof before any TUN', () {
      final kt = ktSrc('AetherCore.kt');
      final at = kt.indexOf('private fun bringUp(');
      expect(at, greaterThan(0));
      final body = kt.substring(at, kt.indexOf('private fun awaitConnected', at));
      expect(body.contains('awaitConnected(opts.scan)'), isTrue);
      // Build 2116 (B5-1, DELIBERATE RE-POINT): the proof
      // ORDER reversed — the data proof now runs FIRST and
      // the trace is the tri-state warpProofOutcome()
      // (an answered warp=off still fails the rung; a
      // silent trace leaves it standing, exit unverified).
      // The pin's intent is unchanged: both proofs gate
      // the rung before any TUN. awaitWarpProof() is gone
      // by design.
      expect(body.contains('warpProofOutcome()'), isTrue);
      expect(body.contains('dataProbe()'), isTrue);
      expect(
        body.indexOf('dataProbe()'),
        lessThan(body.indexOf('warpProofOutcome()')),
        reason: 'the data proof runs before the trace verdict (2116)',
      );
      // Every failure path stops the engine.
      expect('stopLocked()'.allMatches(body).length, greaterThanOrEqualTo(3));
    });

    test('a rung fails after ONE full scan cycle — the latch', () {
      final kt = ktSrc('AetherCore.kt');
      expect(kt.contains('var scanCycleFailed: Boolean = false'), isTrue);
      expect(
        kt.contains(
          'if (!reachedConnected && AetherStageParser.isDataPlaneRetry(line))',
        ),
        isTrue,
        reason: 'the gateway-failure line latches only before CONNECTED',
      );
      expect(kt.contains('scanCycleFailed = false'), isTrue,
          reason: 'every start() resets the latch');
      expect(kt.contains('if (scanCycleFailed) return false'), isTrue,
          reason: 'awaitConnected advances instead of replaying the scan');
    });

    test('a user stop aborts the walk; internal stops do not', () {
      final kt = ktSrc('AetherCore.kt');
      expect(kt.contains('if (ladderActive) ladderAbort = true'), isTrue);
      expect(kt.contains('private fun stopLocked()'), isTrue);
      expect(kt.contains('if (ladderAbort)'), isTrue,
          reason: 'the walk and its waits poll the abort');
    });
  });

  group('build 2083 — env writing (native source pins)', () {
    test('AETHER_MASQUE_H2_FRAGMENT is always written for masque/gool', () {
      final kt = ktSrc('AetherCore.kt');
      expect(
        kt.contains(
          'env["AETHER_MASQUE_H2_FRAGMENT"] = if (o.fragment) "1" else "0"',
        ),
        isTrue,
        reason: 'ralysnd\'s toEnv rule — never an unset default on an H2 rung',
      );
    });

    test('AETHER_IP resolves per network via AetherFamily', () {
      final kt = ktSrc('AetherCore.kt');
      expect(kt.contains('env["AETHER_IP"] = AetherFamily.resolve(o.ip)'), isTrue);
      expect(kt.contains('object AetherFamily'), isTrue);
      expect(
        kt.contains('if (stored == "v6" || stored == "both") return stored'),
        isTrue,
        reason: 'an explicit v6/both stands (CfFamily\'s rule)',
      );
      expect(kt.contains('if (hasIpv6RouteCached()) "both" else "v4"'), isTrue);
      expect(kt.contains('2606:4700:4700::1111'), isTrue,
          reason: 'the route verdict is measured, not assumed');
    });

    test('the tlshello rung starts the Xray exit and never falls back', () {
      final kt = ktSrc('AetherCore.kt');
      expect(kt.contains('if (effectiveOptions.tlsHelloExit)'), isTrue);
      expect(kt.contains('AetherXrayExit.start(context)'), isTrue);
      expect(kt.contains('env.putAll(o.tls.env)'), isTrue,
          reason: 'the rung\'s ClientHello rides the tunnel run');
      expect(
        kt.contains('if (upstream != null) env["AETHER_UPSTREAM"] = upstream'),
        isTrue,
      );
      expect(kt.contains('private fun stopExit()'), isTrue,
          reason: 'the exit is stopped with the run');
    });

    test('the budgets are ralysnd\'s table, and the walk is bounded', () {
      final kt = ktSrc('AetherCore.kt');
      expect(kt.contains('"turbo" -> 45_000L'), isTrue);
      expect(kt.contains('"balanced" -> 120_000L'), isTrue);
      expect(kt.contains('"thorough" -> 300_000L'), isTrue);
      expect(kt.contains('const val RUNG_HEADROOM_MS = 45_000L'), isTrue);
      expect(kt.contains('const val PROOF_ALLOWANCE_MS = 135_000L'), isTrue);
      expect(kt.contains('fun ladderTotalMs(scan: String): Long'), isTrue);
    });

    test('the channel exposes the ladder with auto as the fallback', () {
      final ma = ktSrc('MainActivity.kt');
      expect(ma.contains('"aetherConnectMasque"'), isTrue);
      expect(ma.contains('slot.connectMasque(this, options)'), isTrue);
      expect(
        ma.contains('call.argument<String>("transport") ?: "auto"'),
        isTrue,
        reason: 'a missing transport argument means auto, not h3',
      );
    });
  });

  group('build 2083 — Dart defaults and the migration', () {
    test('auto is the AetherOptions default, in code and in JSON', () {
      expect(const AetherOptions().transport, 'auto');
      expect(AetherOptions.fromJson(const {}).transport, 'auto');
      expect(const AetherOptions().transportExplicit, isFalse);
    });

    test('an unmarked stored h3 lands on auto (it was the old default)', () {
      final stored = AetherOptions.fromJson(const {'transport': 'h3'});
      final migrated = migrateMasqueTransport(stored);
      expect(migrated.transport, 'auto');
      expect(migrated.transportExplicit, isFalse,
          reason: 'auto is a default, not a pick — nothing is marked');
    });

    test('an unmarked stored h2 is an explicit pick and is honored', () {
      final stored = AetherOptions.fromJson(const {'transport': 'h2'});
      final migrated = migrateMasqueTransport(stored);
      expect(migrated.transport, 'h2');
      expect(migrated.transportExplicit, isTrue,
          reason: 'h2 was never a default — it can only be a pick');
    });

    test('a marked pick stands exactly as stored', () {
      for (final t in ['h3', 'h2', 'auto']) {
        final stored = AetherOptions.fromJson({
          'transport': t,
          'transportExplicit': true,
        });
        expect(identical(migrateMasqueTransport(stored), stored), isTrue,
            reason: 'marked $t is untouched');
      }
    });

    test('auto and fresh installs migrate to themselves', () {
      final stored = AetherOptions.fromJson(const {'transport': 'auto'});
      expect(identical(migrateMasqueTransport(stored), stored), isTrue);
      expect(
        identical(migrateMasqueTransport(const AetherOptions()),
            const AetherOptions()),
        isTrue,
      );
    });

    test('the marker round-trips through JSON and copyWith', () {
      final o = const AetherOptions().copyWith(
        transport: 'h3',
        transportExplicit: true,
      );
      final back = AetherOptions.fromJson(o.toJson());
      expect(back.transport, 'h3');
      expect(back.transportExplicit, isTrue);
    });

    test('the page marks a transport pick explicit', () {
      final page = dartSrc('ui/ember/aether_pages.dart');
      // PIN UPDATED by build 2145: the same copyWith call,
      // re-wrapped multi-line by the WARP page's
      // recomposition format pass.
      expect(
        page.contains(
          'o.copyWith(\n'
          '                                  transport: v,\n'
          '                                  transportExplicit: true,\n'
          '                                )',
        ),
        isTrue,
      );
    });

    test('the controller applies the migration at load', () {
      final c = dartSrc('aether/aether_controller.dart');
      expect(c.contains('migrateMasqueTransport(options)'), isTrue);
      expect(c.contains('AetherPlatform.connectMasque('), isTrue);
      expect(c.contains('masqueAutoConnectTimeout(options.scan)'), isTrue);
      expect(c.contains("options.transport == 'auto'"), isTrue,
          reason: 'only the auto route takes the ladder');
    });
  });

  group('build 2083 — the connect bound', () {
    test('the scan deadline table mirrors the native one', () {
      expect(masqueScanDeadlineMs('turbo'), 45000);
      expect(masqueScanDeadlineMs('balanced'), 120000);
      expect(masqueScanDeadlineMs('thorough'), 300000);
      expect(masqueScanDeadlineMs('stealth'), 180000);
      expect(masqueScanDeadlineMs('ironclad'), 180000);
      expect(masqueScanDeadlineMs('unknown'), 180000);
    });

    test('the Dart backstop covers the whole ladder, plus slack', () {
      // 5 rungs × (45 s scan + 45 s headroom + 135 s proofs)
      // + 60 s of channel slack, for the default turbo scan.
      expect(
        masqueAutoConnectTimeout('turbo'),
        const Duration(milliseconds: 5 * (45000 + 45000 + 135000) + 60000),
      );
      expect(masqueLadderRungCount, 5);
      expect(masqueRungHeadroomMs, 45000);
      expect(masqueProofAllowanceMs, 135000);
    });
  });
}
