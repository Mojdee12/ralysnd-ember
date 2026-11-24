// Build 2100 — owner order 2026-11-18 00:57: fix OpenVPN
// completely + WireGuard, one cumulative build. Contents:
// (W-OVPN) the OpenVPN compressionMode="yes" one-liner — the
// code-proven fix for 2099's COMPRESS_ERROR (see
// openvpn-compress-2099-diagnosis.md Q4: empty = COMPRESS_NO
// rejects stub-typed sessions; "yes" = COMPRESS_YES negotiates
// real LZO end-to-end).
// (W-WG1) stderr capture — C-level dup2 onto fd 2 (jni.c
// nativeRedirectStderr) + debug.SetTraceback("all") in the
// bridge init, so a device-goroutine panic lands its full
// stack in files/xray/awg-stderr.log. Host-proven: Go-level
// os.Stderr reassignment does NOT capture a goroutine panic;
// only dup2 does (wg-2100-isolation-design.md §1.4).
// (W-WG2) :awg process isolation — the AWG VpnService moves
// out of the main process into AwgVpnService
// (android:process=":awg"), Psiphon shape (build 2073): all
// interaction intent- + file-based (published state snapshot).
// These pins are source-level on purpose, like 2099's: the
// failures they guard were all "the pieces were individually
// right and jointly wrong".
//
// DIVERGENCE NOTE (recorded in build2100-progress.md): the
// cron design doc §2 proposes a plain bound Service
// (AwgCoreService) + AIDL instead of moving the VpnService,
// and its §3 pin (i) demands NO BIND_VPN_SERVICE on :awg.
// That pin does NOT apply to the implemented Psiphon shape —
// PsiphonVpnService proves a VpnService can live in its own
// process and establish its own TUN + protect() its own
// sockets — so the pin below asserts the POSITIVE shape
// (AwgVpnService IS a VpnService with BIND_VPN_SERVICE,
// process :awg). The verification loop must examine this
// divergence deliberately.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();
String goSrc(String rel) =>
    File('../../awg-spike/$rel').readAsStringSync();
String jniSrc() => File('../../awg-spike/jni.c').readAsStringSync();

void main() {
  group('W-OVPN — compressionMode is exactly "yes"', () {
    test('makeConfig sets compressionMode = "yes" and nothing else', () {
      final bridge =
          File('../../openvpn/src/bridge.cpp').readAsStringSync();
      // Anchor on config.compressionMode so the explanatory
      // comment above the line (which quotes the value) is not
      // counted as a second assignment.
      final assignments =
          RegExp(r'config\.compressionMode\s*=\s*"([^"]*)"')
              .allMatches(bridge)
              .map((m) => m.group(1))
              .toList();
      // Exactly one assignment, and it is "yes": empty is
      // COMPRESS_NO (2099's COMPRESS_ERROR) and "asym" keeps
      // stub behaviour (2098's NO_DATA). No other value may
      // creep back in.
      expect(
        assignments,
        ['yes'],
        reason: 'makeConfig compressionMode assignments: $assignments',
      );
    });
  });

  // Build 2104: W-WG1's mechanism is a NAMED LOSS. The
  // dup2 stderr capture existed to catch Go-runtime panics
  // from the hand-built bridge; the bridge is deleted, the
  // WG Tunnel backend's native side is upstream's, and no
  // Ember code redirects stderr any more. The spike sources
  // that proved the mechanism (../../awg-spike) stay on disk
  // as research; they ship nothing. What survives: awg.log
  // itself (now the backend's log, same file, same 1 MiB
  // bound) and the diagnostics bundle's treatment of the
  // historical stderr files on upgraded devices.
  group('W-WG1 — stderr capture (named loss, build 2104)', () {
    test('the capture machinery is deleted, not parked', () {
      expect(
        File(
          'android/app/src/main/kotlin/com/ralysnd/ember/AwgBackend.kt',
        ).existsSync(),
        isFalse,
      );
      expect(
        File(
          'android/app/src/main/kotlin/com/ralysnd/ember/AwgVpnService.kt',
        ).existsSync(),
        isFalse,
      );
      final engine = ktSrc('WgTunnelEngine.kt');
      expect(engine, isNot(contains('redirectStderr')));
      expect(engine, isNot(contains('nativeRedirectStderr')));
    });

    test('awg.log keeps the 1 MiB bound under its new writer', () {
      final engine = ktSrc('WgTunnelEngine.kt');
      expect(engine, contains('1 shl 20'));
      expect(engine, contains('awg.log.old'));
      expect(engine, contains('rotateBackendLog'));
    });

    test('the diagnostics bundle reads and clears awg-stderr.log', () {
      // Extends (does not replace) the 2099 C2 pin: the same
      // two lists that carry awg.log must carry awg-stderr.log.
      final controller = dartSrc('xray/xray_controller.dart');
      final occurrences =
          'awg-stderr.log'.allMatches(controller).length;
      expect(
        occurrences,
        greaterThanOrEqualTo(2),
        reason: 'awg-stderr.log must appear in both readLogs and '
            'clearLogs (found $occurrences)',
      );
      expect(controller, contains("'awg.log'"));
      // Verification iteration 1, L1: the rotation archive is
      // exported by readLogs (a retry after a death moves the
      // panic stack to .old) but never emptied by Clear —
      // rotation archives are evidence, like crash.log.old.
      expect(
        controller,
        contains("'awg-stderr.log', 'awg-stderr.log.old', 'crash.log'"),
        reason: 'readLogs exports the .old rotation archive',
      );
      final clearFn = controller.substring(
        controller.indexOf('Future<void> clearLogs()'),
      );
      final clearListEnd = clearFn.indexOf('])');
      expect(
        clearFn.substring(0, clearListEnd),
        isNot(contains('awg-stderr.log.old')),
        reason: 'Clear leaves the .old rotation archive alone',
      );
    });
  });

  // Build 2104: W-WG2's architecture is retired — the :awg
  // process, its published state file, the 15 s staleness
  // death rule and the 45 s userStopped freshness window
  // are deleted with the engine swap (named losses,
  // BUILD-LOG-2.md). The WG Tunnel backend runs in the main
  // process and its status is read in-process, exactly.
  // The PROPERTIES those mechanisms protected are re-pinned
  // below in their 2104 form; the mechanisms themselves are
  // pinned ABSENT so they cannot creep back.
  group('W-WG2 — :awg isolation (retired by build 2104)', () {
    test('the manifest process set (2129: :psiphon + :lantern)', () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      final processes = RegExp(r'android:process="([^"]+)"')
          .allMatches(manifest)
          .map((m) => m.group(1))
          .toList()
        ..sort();
      // Build 2129: LanternVpnService gained :lantern (the
      // gomobile core's own process, mirroring :psiphon);
      // :awg stays retired.
      expect(processes, [':lantern', ':psiphon']);
      expect(manifest, isNot(contains('android:name=".AwgVpnService"')));
      expect(manifest, contains('android:name=".PsiphonVpnService"'));
    });

    test('XrayVpnService holds no AWG reference any more', () {
      final svc = ktSrc('XrayVpnService.kt');
      expect(svc, isNot(contains('AwgBackend')));
      expect(svc, isNot(contains('startAwgTunnel')));
      expect(svc, isNot(contains('awgMode')));
      expect(svc, isNot(contains('ACTION_START_AWG')));
    });

    test('WgTunnelEngine carries the tunnel + state machinery', () {
      final engine = ktSrc('WgTunnelEngine.kt');
      expect(engine, contains('fun start('));
      expect(engine, contains('fun stop('));
      expect(engine, contains('fun snapshot()'));
      expect(engine, contains('TunnelBackend('));
      // 2099 breadcrumbs, engine form.
      expect(engine, contains('awg:start-invoked'));
      expect(engine, contains('awg:connected'));
      // The unexpected-drop message (the 2099 supervision
      // wording) is produced by the engine's status watcher.
      expect(engine, contains('the AmneziaWG engine stopped; '));
      expect(engine, contains('the session was closed'));
    });

    test('MainActivity merges the engine snapshot (no death rule)', () {
      final main = ktSrc('MainActivity.kt');
      expect(main, contains('WgTunnelEngine.snapshot()'));
      // The published-file machinery is gone from the merge
      // (PsiphonVpnService.publishedState is a different
      // engine's own state and is not this pin's subject).
      expect(main, isNot(contains('AwgVpnService.publishedState')));
      expect(main, isNot(contains('publishedLive')));
      expect(main, isNot(contains('AwgVpnService.')));
      // Dual stop: every Xray stop site also stops the AWG
      // engine.
      expect(main, contains('WgTunnelEngine.stop(this)'));
    });

    test('an AWG core death still surfaces as a failed AWG start', () {
      // Cron addendum A2: what must be preserved across the
      // boundary is the AWG→plain fallback — _connectAwg's
      // caller falls back to the plain-WG leg when AWG fails.
      // That path keys on the state map (running == false +
      // coreProblem), which the death case in MainActivity
      // produces. Pin both ends of the contract.
      final main = ktSrc('MainActivity.kt');
      expect(main, contains('"running" to false'));
      final controller = dartSrc('xray/xray_controller.dart');
      expect(controller, contains('awgFailedFor'));
      expect(controller, contains('awgFallbackNotice'));
    });

    test('the AWG session reports its real hold; it still cannot pause', () {
      // The merge forces the shape for a live AWG session,
      // as the 2100 death/live branches did.
      // Build 2127 supersession (H4): the WG kill-switch
      // leg landed — the merge reports the snapshot's real
      // killSwitchHeld instead of a forced false. Pause
      // stays forced false: the library has no pause.
      final main = ktSrc('MainActivity.kt');
      expect(main, contains('awgSnap.killSwitchHeld'));
      expect(main, contains('"paused" to false,'));
    });

    test('a held blackhole is released before the AWG start', () {
      // Build 2063's hand-off, cross-process (verification
      // iteration 1, H1): 2099 released a held blackhole
      // inside startAwgTunnel after the new TUN was up.
      // AwgVpnService cannot touch XrayVpnService's companion
      // statics across processes, so the release moved to the
      // Dart connect path, where single-engine sequencing
      // already lives: _connectAwg reads a fresh sample and
      // stops first whenever anything is up OR held. The
      // platform revoke (onRevoke → stopTunnel) remains only
      // as a backstop — never the mechanism, because it is
      // unproven for a same-app establish and its
      // stopForeground(REMOVE) would strip the AWG
      // notification sharing id 2.
      final controller = dartSrc('xray/xray_controller.dart');
      final connectAwg = controller.substring(
        controller.indexOf('Future<bool> _connectAwg('),
      );
      expect(
        connectAwg,
        contains('final wasHeld = state.killSwitchHeld;'),
        reason: 'the hold decision reads a fresh sample, not a stale one',
      );
      expect(
        connectAwg,
        contains('if (state.running || wasHeld) await _stopTunnel();'),
        reason: 'the AWG connect stops first when held, not only when running',
      );
      expect(
        connectAwg,
        contains('state = await XrayPlatform.state();'),
        reason: 'the hold decision reads a fresh sample, not a stale one',
      );
      // Verification iteration 2, Low: _stopTunnel only fires
      // the stop intent — in the hold state its wait loop
      // breaks on the first poll — so the release is OBSERVED
      // (bounded, 10 x 200 ms) before the AWG start, not
      // assumed. The fingerprint refresh is not the margin:
      // it normally already ran at controller init.
      expect(
        connectAwg,
        contains('if (!state.killSwitchHeld) break;'),
      );
      expect(
        connectAwg,
        contains('const Duration(milliseconds: 200)'),
      );
      // Verification iteration 3, Low: the poll shape itself
      // is pinned — hold-only guard, bounded 10-iteration
      // loop — and the comment no longer credits the :awg
      // cold start with the ordering (the poll is the
      // mechanism).
      expect(
        connectAwg,
        contains('if (wasHeld) {'),
      );
      expect(
        connectAwg,
        contains('for (var i = 0; i < 10; i++) {'),
      );
      expect(
        connectAwg,
        contains('bounded poll below is the mechanism'),
        reason: 'iteration 4, F2: the comment credits the hold-case poll, qualified',
      );
      expect(
        connectAwg,
        isNot(contains('The :awg cold start leaves')),
        reason: 'the old comment claimed a margin the poll now provides',
      );
      expect(
        connectAwg,
        isNot(contains('fingerprint refresh and')),
        reason: 'the old comment claimed a margin that does not exist',
      );
      // Backstop only: the Xray service still routes a
      // revoke to its stop. (Build 2104: the AWG side's
      // revoke belongs to the backend's own VpnService —
      // upstream code, not pinned here.)
      final xray = ktSrc('XrayVpnService.kt');
      expect(xray, contains('override fun onRevoke()'));
    });

    test('the problem case reports the failure, never a user stop', () {
      // 2104 form of iteration 1's M1: a start failure or an
      // unexpected drop is reported from the engine's own
      // state, with userStopped forced false.
      final main = ktSrc('MainActivity.kt');
      final problem = main.substring(
        main.indexOf('awgSnap.coreProblem.isNotEmpty()'),
      );
      expect(problem, contains('"userStopped" to false'));
      expect(problem, contains('"name" to awgSnap.name'));
      expect(problem, contains('"sinceMs" to awgSnap.sinceMs'));
    });

    test('the rotate guard uses the backend live check', () {
      // 2104 form of iteration 1's M2: in-process state
      // cannot go stale, so the guard reads the backend's
      // status directly.
      final main = ktSrc('MainActivity.kt');
      expect(main, contains('!WgTunnelEngine.isLive(this)'));
      final engine = ktSrc('WgTunnelEngine.kt');
      expect(engine, contains('fun isLive(context: Context): Boolean'));
      expect(engine, contains('transportState != Tunnel.State.Down'));
    });

    test('the session counts as active only after the start lands', () {
      // 2104 form of iteration 1's L2 (running published
      // last): the engine sets sessionActive only in the
      // start's success branch, after backend.start returns.
      final engine = ktSrc('WgTunnelEngine.kt');
      final start = engine.substring(engine.indexOf('fun start('));
      expect(
        start.indexOf('backend.start('),
        lessThan(start.indexOf('sessionActive = true')),
      );
    });

    test('no published snapshot exists to go stale', () {
      // 2104 form of iteration 1's L3: there is no heartbeat
      // stamp at all — liveness is read from the backend's
      // in-process status, so no clock (wall or elapsed)
      // can misdeclare it.
      final engine = ktSrc('WgTunnelEngine.kt');
      expect(engine, isNot(contains('publishedAt')));
      final main = ktSrc('MainActivity.kt');
      expect(main, isNot(contains('publishedAtElapsedMs')));
      expect(main, isNot(contains('45_000')));
    });

    test('a stopped AWG session reports its own user stop', () {
      // 2104 form of iteration 2's Medium: the stop branch
      // reads the engine's own userStopped (its stop funnel
      // sets it, in-process and current — no freshness
      // window), and only when no Xray session is live.
      final main = ktSrc('MainActivity.kt');
      expect(
        main,
        contains('!XrayVpnService.running && awgSnap.userStopped'),
      );
      // Build 2106 (verification iteration 2, M-1): the
      // stopped branch's map also carries the engine's
      // notification-stop sequence — the peer walk re-reads
      // it after its own teardown stop. The userStopped
      // report itself is unchanged. (The map is written
      // multi-line now, so match whitespace-normalized.)
      final stoppedBranch = main
          .substring(
            main.indexOf('awgSnap.userStopped ->'),
            main.indexOf('awgSnap.coreProblem.isNotEmpty() ->'),
          )
          .replaceAll(RegExp(r'\s+'), ' ');
      expect(stoppedBranch, contains('"userStopped" to true'));
      expect(
        stoppedBranch,
        contains('"awgUserStopSeq" to awgSnap.userStopSeq'),
      );
      final engine = ktSrc('WgTunnelEngine.kt');
      expect(engine, contains('userStopped = true'));
    });

    test('the problem case carries no stale pause or chain state', () {
      // 2104 form of iteration 2's Low: the failure report
      // forces the same neutral shape the 2100 death branch
      // forced.
      final main = ktSrc('MainActivity.kt');
      final problem = main.substring(
        main.indexOf('awgSnap.coreProblem.isNotEmpty()'),
      );
      expect(problem, contains('"paused" to false'));
      expect(problem, contains('"coreRestarts" to 0'));
      expect(problem, contains('"chainUnderlay" to false'));
      expect(problem, contains('"chainProblem" to ""'));
    });
  });
}
