// Build 2080 — the EmberWarp fix build (diagnosis:
// ~/workspace/ember-app/emberwarp-iran-exit-diagnosis-2026-11-15.md).
//
// Both owner-reported defects traced to one root cause:
// Ember gated the Aether cores on SIGNALS (a stage log line,
// a SOCKS greeting) where ralysnd demands a real
// THROUGH-PROXY DATA PROOF.
//   1. MASQUE standalone "connected" with an Iranian exit —
//      a hollow CONNECTED: the listening line fired (possibly
//      for gool's random registration listener), the data
//      plane retried forever behind it on lines that could
//      not demote the stage, and the slot validated nothing
//      before the TUN rose.
//   2. EmberWarp as V2Ray underlay never connected — Xray
//      first, the core spawned late by a Dart poll, a 45 s
//      supervisor grace against a cold scan that must
//      validate through the exit-node, and a supervisor that
//      respawned (killed) the core mid-scan. Plus: nobody
//      provisioned the identity on the chain path.
//
// These pins prove the wiring of every fix. What only the
// owner's phone can prove — a MASQUE session now egressing
// through WARP on his filtered line, and a chained session
// surviving its cold scan — is NOT claimed here.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/warp_args.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

int occurrences(String haystack, String needle) =>
    haystack.split(needle).length - 1;

/// The text of one function in a source file: from [start]
/// up to (not including) the next occurrence of [end].
String region(String src, String start, String end) {
  final a = src.indexOf(start);
  expect(a, greaterThanOrEqualTo(0), reason: '$start is present');
  final b = src.indexOf(end, a);
  expect(b, greaterThan(a), reason: '$end follows $start');
  return src.substring(a, b);
}

void main() {
  group('fix 2 — the foreign-SOCKS guard (AetherCore.kt)', () {
    test('a listening line for another port cannot classify', () {
      final kt = ktSrc('AetherCore.kt');
      final handle = region(kt, 'private fun handleLine', '@Synchronized');
      // The guard itself: the parsed listener address must
      // end with THIS slot's port.
      expect(handle, contains('detail.socks.endsWith(":\$socksPort")'));
      expect(handle, contains('val foreignSocks'));
      // And classification is skipped for a foreign line —
      // the old code classified ANY listening line CONNECTED.
      expect(
        handle,
        contains('if (foreignSocks) null'),
        reason: 'a foreign listening line yields no stage',
      );
    });
  });

  group('fix 3 — data-aware demotion (AetherCore.kt)', () {
    test('the parser names data-plane retry and proof lines', () {
      final kt = ktSrc('AetherCore.kt');
      expect(kt, contains('fun isDataPlaneRetry'));
      expect(
        kt,
        contains('found no data-plane endpoint.*trying next profile'),
      );
      expect(kt, contains('no usable masque gateway found'));
      expect(kt, contains('no usable.*endpoint found'));
      expect(kt, contains('fun isDataPlaneProof'));
      expect(kt, contains('masque tunnel validated'));
    });

    test('a retry line after CONNECTED withdraws readiness', () {
      final kt = ktSrc('AetherCore.kt');
      // The demotion flag and the readiness every consumer
      // must read.
      expect(kt, contains('var dataPlaneStale'));
      expect(kt, contains('fun isConnected(): Boolean'));
      expect(kt, contains('!dataPlaneStale'));
      final handle = region(kt, 'private fun handleLine', '@Synchronized');
      expect(handle, contains('stage == AetherStage.CONNECTED &&'));
      expect(handle, contains('AetherStageParser.isDataPlaneRetry(line)'));
      expect(handle, contains('dataPlaneStale = true'));
      // …and the core's own proof clears it again.
      expect(handle, contains('AetherStageParser.isDataPlaneProof(line)'));
      expect(handle, contains('dataPlaneStale = false'));
      // The state map reports the demotion-aware verdict, not
      // the bare stage.
      expect(kt, contains('"connected" to isConnected()'));
      expect(kt, contains('"dataPlaneStale" to dataPlaneStale'));
    });

    test('the VPN service gates and watches through isConnected()', () {
      final kt = ktSrc('XrayVpnService.kt');
      // startSocksTunnel's pre-TUN gate + the sessionSocksMode
      // watchdog: exactly the two readiness reads.
      expect(occurrences(kt, 'slot.isConnected()'), 2);
      expect(kt, contains('if (!slot.isConnected() || !probeSocks(socksPort))'));
      // The old bare-stage reads are gone from both spots.
      expect(
        kt,
        isNot(contains('slot.stage != AetherStage.CONNECTED')),
      );
      expect(
        kt,
        isNot(contains('slot.stage == AetherStage.CONNECTED')),
      );
    });
  });

  group('fix 1 — the MASQUE data-plane gate', () {
    test('the native probe runs ralysnd’s four transfers', () {
      final kt = ktSrc('AetherCore.kt');
      expect(kt, contains('fun dataProbe(): Map<String, Any>'));
      // HTTP + HTTPS generate_204 endpoint sets.
      expect(kt, contains('http://www.gstatic.com/generate_204'));
      expect(kt, contains('https://www.gstatic.com/generate_204'));
      expect(kt, contains('https://www.google.com/generate_204'));
      // The exact-byte download (the length is the check).
      expect(kt, contains('DATA_PROBE_DOWN_BYTES = 65_536'));
      expect(kt, contains('https://httpbin.org/bytes/'));
      expect(kt, contains('__down?bytes='));
      // The echoed upload (an acknowledgement, not a write).
      expect(kt, contains('DATA_PROBE_UP_BYTES = 16_384'));
      expect(kt, contains('ember-transfer-check:'));
      expect(kt, contains('https://httpbin.org/post'));
      expect(kt, contains('body.contains(payload)'));
      // One 45 s ceiling for the whole probe.
      expect(kt, contains('DATA_PROBE_TOTAL_MS = 45_000L'));
      // A passed probe is itself revalidation evidence.
      final probe = region(kt, 'fun dataProbe()', 'private fun probeRequest');
      expect(probe, contains('dataPlaneStale = false'));
    });

    test('the platform channel carries the probe', () {
      expect(ktSrc('MainActivity.kt'), contains('"aetherDataProbe"'));
      expect(ktSrc('MainActivity.kt'), contains('slot.dataProbe()'));
      final platform = dartSrc('aether/aether_platform.dart');
      expect(platform, contains('static Future<Map<String, dynamic>?> dataProbe'));
      expect(platform, contains("'aetherDataProbe'"));
    });

    test('connect() proves warp=on AND data before the TUN', () {
      final dart = dartSrc('aether/aether_controller.dart');
      final connect = region(
        dart,
        'Future<void> connect() async',
        'Future<void> _awaitEngineConnected',
      );
      // Both slots now check the trace (MASQUE used to fetch
      // it unchecked, for display only).
      // PIN UPDATED by build 2096 (post-2095 audit M22):
      // the proof waits take the connect generation so a
      // mid-wait disconnect aborts them.
      expect(connect, contains('await _awaitWarpProof(gen);'));
      expect(
        connect,
        isNot(contains('exitTrace = await AetherPlatform.trace(slot)')),
        reason: 'the unchecked display-only trace fetch is gone',
      );
      // The data proof runs for MASQUE…
      expect(connect, contains('await _awaitDataProof(gen);'));
      // …and both proofs complete BEFORE the TUN is raised.
      final tunAt = connect.indexOf('AetherPlatform.setTun');
      expect(connect.indexOf('await _awaitWarpProof(gen);'), lessThan(tunAt));
      expect(connect.indexOf('await _awaitDataProof(gen);'), lessThan(tunAt));
      // The failure is plain language, and it throws (the
      // caller tears down; no TUN, no CONNECTED).
      expect(dart, contains('real data did not pass through it'));
      expect(dart, contains('the connection was not started'));
    });
  });

  group('fix 4 — the underlay chain timing', () {
    test('the service spawns the chain core at session start', () {
      final kt = ktSrc('XrayVpnService.kt');
      // Build 2110 (wg-start diagnosis, defect 4): the spawn
      // sequence moved into spawnCoreLocked, which
      // startTunnel runs under coreLock at session start —
      // the ordering this pin exists for (chain core before
      // the Xray core) is the helper's internal order.
      expect(kt, contains('spawnCoreLocked('));
      final spawn = kt.indexOf(
        'EmberWarpCore.start(\n                this, warpArgs, EmberWarpCore.SOCKS_PORT,',
      );
      expect(spawn, greaterThan(kt.indexOf('private fun spawnCoreLocked(')));
      // …before the Xray core is even spawned, so the scan
      // starts with the session, not after a Dart poll.
      expect(spawn, lessThan(kt.indexOf('xray did not open its SOCKS port')));
      expect(kt, contains('if (underlay == "warp" && warpArgs.isNotEmpty())'));
    });

    test('the initial warp grace matches the chained scan budget', () {
      final kt = ktSrc('XrayVpnService.kt');
      expect(kt, contains('WARP_CHAIN_INITIAL_GRACE_MS = 150_000L'));
      expect(
        kt,
        contains('if (underlay == "warp") WARP_CHAIN_INITIAL_GRACE_MS'),
      );
      // The core side of the same budget.
      final core = ktSrc('EmberWarpCore.kt');
      expect(core, contains('CHAIN_GREETING_WAIT_MS = 150_000L'));
      expect(core, contains('GREETING_WAIT_MS = 45_000L'));
      expect(core, contains('args.contains("--upstream")'));
      expect(core, contains('greetingWaitMs: Long'));
      // The per-read timeout follows the wait, not the old
      // 45 s cap that would have cut a chained scan short.
      expect(core, contains('.coerceIn(1, greetingWaitMs)'));
    });

    test('the supervisor never respawns a core in its first scan', () {
      final core = ktSrc('EmberWarpCore.kt');
      expect(core, contains('fun scanInProgress(): Boolean'));
      final scan = region(core, 'fun scanInProgress()', 'fun binary');
      expect(scan, contains('stage == "starting"'));
      expect(scan, contains('!ready'));
      final kt = ktSrc('XrayVpnService.kt');
      // Supervisor health exemption + the respawn guard.
      expect(occurrences(kt, 'EmberWarpCore.scanInProgress()'), 2);
      expect(kt, contains('EmberWarpCore.scanInProgress() ||'));
      expect(kt, contains('still in its first scan; not respawning'));
    });

    test('Dart never restarts a running core from the wait', () {
      final dart = dartSrc('xray/xray_controller.dart');
      // Build 2099 (pin repair, reason named): the region end
      // marker names disconnect's start; build 2098's I2-A3
      // gave disconnect a {consumeChainExit} parameter, so the
      // pre-2099 marker 'Future<void> disconnect() async' no
      // longer exists in the source — the pin was stale in the
      // shipped 2098 tree, not broken by 2099.
      final wait = region(
        dart,
        'Future<bool> _awaitWarpReady(',
        'Future<void> disconnect({',
      );
      // The old respawn-on-running-but-not-ready condition is
      // gone; spawning happens only when nothing runs.
      expect(wait, isNot(contains('!(before.running && before.ready)')));
      expect(wait, contains('if (!before.running) {'));
      expect(wait, contains('already starting; waiting for'));
    });

    test('the chain provisions a missing identity first, directly', () {
      final dart = dartSrc('xray/xray_controller.dart');
      expect(dart, contains('Future<void> _provisionWarpIdentityForChain()'));
      final provision = region(
        dart,
        'Future<void> _provisionWarpIdentityForChain()',
        'Future<bool> _awaitWarpReady(',
      );
      // Same store, settled identity: it checks presence,
      // runs DIRECT on the probe port (no upstream), stops,
      // and refuses the session when registration failed.
      expect(provision, contains('before.identityPresent'));
      expect(provision, contains('port: warpProbePort'));
      expect(provision, contains('await WarpPlatform.stop();'));
      expect(provision, contains("throw StateError('underlay-failed')"));
      // In connect(), provisioning completes before the
      // session (and its native core spawn) starts.
      // Build 2087: the region start is connect()'s current
      // signature — it gained the groupWalk parameter when
      // manual connects stopped walking the fallback group
      // (owner's selection fix); the ordering pins below are
      // unchanged.
      final connect = region(
        dart,
        'Future<void> connect({bool groupWalk = false}) async',
        'Future<void> disconnect({',
      );
      final provisionAt = connect.indexOf('_provisionWarpIdentityForChain();');
      expect(provisionAt, greaterThan(0));
      expect(
        provisionAt,
        lessThan(connect.indexOf('XrayPlatform.setOn(')),
      );
      // The chained readiness wait carries the chain budget.
      expect(connect, contains('wait: const Duration(seconds: 150)'));
    });
  });

  group('no-silent-removal — the chain shapes are unchanged', () {
    test('chained args still bind 20850 with the exit upstream', () {
      final args = buildWarpArgs(
        WarpProfile(),
        upstream: 'socks5://127.0.0.1:$warpExitPort',
      );
      expect(args, contains('127.0.0.1:$warpSessionPort'));
      expect(args, contains('--upstream'));
      expect(args, contains('socks5://127.0.0.1:$warpExitPort'));
    });

    test('a probe-port run is direct (no upstream)', () {
      final args = buildWarpArgs(WarpProfile(), port: warpProbePort);
      expect(args, contains('127.0.0.1:$warpProbePort'));
      expect(args, isNot(contains('--upstream')));
    });
  });
}
