// Build 2066 — the 2065 Psiphon regression fix (owner report
// 2026-11-14: «کرش میده سایفون» on mobile data). The pasted device
// logs proved: (1) the TUN/tunlink bridge was raised before the
// Psiphon core had any tunnel and sprayed SOCKS UDP ASSOCIATE at
// the core's CONNECT-only SOCKS — hundreds of identical accept
// errors, every TCP failing, the phone blackholed; (2) nothing
// bounded the blackhole: the only teardown watch (F-M4) waits for
// diagnostic SILENCE, which a live core cycling candidates never
// gives. The 2066 fix ported ralysnd's device-proven contract:
// badvpn tun2socks (TCP via SOCKS CONNECT, UDP via the core's
// udpgw intercept), the TUN raised only after connected, a 90 s
// tunnel-loss bound, log dedupe, and edge-result invalidation on
// network change.
//
// Build 2089 REWRITE of this file: the provider those bridge
// pins described is gone. The AAR core (whose SOCKS was
// CONNECT-only and which owned the udpgw intercept) was
// replaced by the hiddify-sing-box sidecar, whose SOCKS is a
// full sing-box inbound that serves UDP ASSOCIATE properly —
// the 2066 defect's premise no longer exists, and badvpn's
// udpgw peer died with the AAR. So the bridge is libtunlink
// again (the Xray/Lantern subprocess shape), and the pins
// below assert the 2089 shape. What did NOT change — and is
// still pinned here — is 2066's other half: the TUN rises
// only after a proven tunnel, the 90 s tunnel-loss bound,
// bridge death ending the session, log dedupe, and edge
// invalidation. The notice-silence guard is gone with the
// notices themselves: liveness is the connect probe's now,
// and the connect bound is a plain deadline (also pinned).
//
// Build 2091 REWRITE of this file: the provider is the AAR
// core AGAIN (the MLM transplant, owner's order). The bridge
// is badvpn tun2socks in-process again, the TUN is raised
// BEFORE the core starts (MLM §2 item 2 — the 2066
// "TUN-after-connected" premise is inverted by design: the
// core's NetworkMonitor must never see tun0 appear), and
// connected is the core's onConnected callback gated by the
// quality gate (the probe is retired). The pins below assert
// the 2091 shape; the 2089 sidecar shape is pinned ABSENT
// (a sidecar that quietly came back would resurrect the
// 2090 no-connect). Log dedupe and edge invalidation are
// untouched by the transplant and still pinned here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

void main() {
  final service = ktSrc('PsiphonVpnService.kt');

  group('2091 provider shape: the AAR core is back, the '
      'bridge is the in-process badvpn manager', () {
    test('the AAR is back, the badvpn bridge is in-process, '
        'the udpgw is the manager\u2019s', () {
      expect(service.contains('PsiphonTunnel'), isTrue);
      expect(service.contains('psi.Psi'), isFalse);
      // The JNI loader is referenced by the bridge manager,
      // not the service — the native side loads it.
      final manager = ktSrc('Tun2SocksManager.kt');
      expect(manager.contains('Tun2SocksJniLoader'), isTrue);
      expect(service.contains('startTunneling'), isTrue);
      expect(
        File('android/app/libs/psiphon.aar').existsSync(),
        isTrue,
      );
      expect(
        File(
          'android/app/src/main/java/ca/psiphon/Tun2SocksJniLoader.java',
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          'android/app/src/main/jniLibs/arm64-v8a/libtun2socks.so',
        ).existsSync(),
        isTrue,
      );
      // The udpgw peer lives in the manager, not the service.
      expect(manager.contains('7300'), isTrue);
    });

    test('the provider is the AAR library again, driven by '
        'the MLM host', () {
      expect(service.contains('PsiphonBoxCore.start('), isFalse);
      expect(service.contains('PsiphonBoxCore.startArgs(this)'), isFalse);
      expect(service.contains('PsiphonBoxCore.configFile(this)'), isFalse);
      expect(
        service.contains('PROVIDER_TAG = "provider-aar-mlm"'),
        isTrue,
      );
      expect(service.contains('PsiphonBoxCore.stop()'), isFalse);
      expect(service.contains('stopPsiphonCore()'), isTrue);
      expect(
        service.contains('PsiphonTunnel.newPsiphonTunnel(this)'),
        isTrue,
      );
    });

    test('the bridge is the in-process badvpn manager, '
        'handed the TUN fd directly', () {
      expect(service.contains('libtunlink.so'), isFalse);
      expect(service.contains('tunProcess'), isFalse);
      expect(service.contains('LocalServerSocket'), isFalse);
      expect(service.contains('Tun2SocksManager.start('), isTrue);
      expect(service.contains('Tun2SocksManager.stop()'), isTrue);
      expect(
        service.contains('setFileDescriptorsForSend'),
        isFalse,
      );
    });

    test('stop discipline is the detached library stop '
        '(build 2091: no bridge process to kill)', () {
      expect(service.contains('ProcessKill.kill'), isFalse);
      final stop = service.indexOf('private fun stopProcesses()');
      expect(stop, isNot(-1));
      final body = service.substring(stop, stop + 1200);
      expect(body.contains('Tun2SocksManager.stop()'), isTrue);
      expect(body.contains('stopPsiphonCore()'), isTrue);
      expect(body.contains('PsiphonBoxCore.stop()'), isFalse);
    });

    test('connected is the core\u2019s onConnected callback, '
        'gated by the quality gate', () {
      expect(service.contains('probeTunnelOnce()'), isFalse);
      expect(service.contains('socksConnectProbe'), isFalse);
      expect(service.contains('PROBE_TARGETS'), isFalse);
      expect(service.contains('PROBE_FAILURES_TO_DROP = 3'), isFalse);
      expect(service.contains('override fun onConnected()'), isTrue);
      expect(service.contains('psiphonQualityCheck('), isTrue);
    });
  });

  group('2065 defect: the TUN was raised before any tunnel '
      'existed and nothing bounded the blackhole (build 2091: '
      'the premise is inverted — TUN first, by design)', () {
    test('the TUN is raised BEFORE the core starts', () {
      // Build 2091: MLM §2 item 2 — the core's
      // NetworkMonitor must never see tun0 appear, so the
      // TUN exists before the library call. The 2065
      // "wait for connected first" premise is inverted by
      // design, and the blackhole is bounded by the ladder
      // timer + the bridge watcher instead.
      expect(service.contains('waitForConnected(CONNECT_WAIT_MS)'), isFalse);
      expect(service.contains('CONNECT_WAIT_MS'), isFalse);
      final establish = service.indexOf('builder.establish()');
      expect(establish, isNot(-1));
      final start = service.indexOf('startPsiphonTunnel()', establish);
      expect(start, greaterThan(establish));
      // ...and the bridge watcher starts only after the
      // core is started.
      expect(service.indexOf('watchBridge()', start), greaterThan(start));
    });

    test('a dead rung is escalated by its timer; a dead '
        'bridge tears the session down', () {
      // Build 2091: there is no 90 s TUN-loss deadline and
      // no plain connect deadline — the bound is the ladder
      // timer (rung budget + 8 s grace) for a rung that
      // never connects, and the bridge watcher for a bridge
      // that dies under a live TUN.
      expect(service.contains('TUNNEL_LOSS_MS'), isFalse);
      expect(service.contains('maxOf(tunUpAtMs, lastConnectedMs)'), isFalse);
      expect(
        service.contains('psiphon bridge exited; tearing the session down'),
        isTrue,
      );
      expect(service.contains('CONNECT_DEADLINE_MS'), isFalse);
      expect(service.contains('NOTICE_SILENCE_MS'), isFalse);
      expect(service.contains('armLadderTimer()'), isTrue);
      expect(service.contains('escalateLadder('), isTrue);
    });

    test('bridge death ends the session (watcher)', () {
      expect(service.contains('private fun watchBridge()'), isTrue);
      expect(
        service.contains('bridgeStarted && !Tun2SocksManager.isRunning'),
        isTrue,
      );
      final watch = service.indexOf('private fun watchBridge()');
      // Build 2125 re-point (A25-04): the watcher first
      // asks the kill-switch question (hold vs teardown),
      // which pushed stopTunnel() past the old 800-char
      // window. The contract is unchanged for the
      // switch-off case this pin guards.
      final body = service.substring(watch, watch + 1600);
      expect(body.contains('stopTunnel()'), isTrue);
      expect(body.contains('holdKillSwitch('), isTrue);
    });

    test('provider death ends the session (watcher)', () {
      // Build 2091: the provider is the in-process library,
      // so its death is onExiting — escalate while the
      // ladder is live, stop after an established session —
      // and a wedged start is killed from outside by the
      // external watchdog (its discriminator is
      // startReturned).
      expect(service.contains('providerExited'), isFalse);
      expect(service.contains('psiphon sidecar exited'), isFalse);
      expect(service.contains('override fun onExiting()'), isTrue);
      final exiting = service.indexOf('override fun onExiting()');
      final body = service.substring(exiting, exiting + 600);
      expect(body.contains('escalateLadder('), isTrue);
      expect(body.contains('stopTunnel()'), isTrue);
      expect(service.contains('startReturned'), isTrue);
    });
  });

  group('2065 defect: hundreds of identical log lines in '
      'seconds (file growth, choked log viewer) (kept)', () {
    test('consecutive duplicates collapse with a counter', () {
      expect(service.contains('line == lastLogLine'), isTrue);
      expect(service.contains('logRepeatCount++'), isTrue);
      expect(service.contains('repeated 100 times'), isTrue);
      expect(service.contains('flushLogRepeatLocked()'), isTrue);
      // The summary is flushed when the log closes, so a flood
      // that ends the session still leaves its count behind.
      final close = service.indexOf('private fun closeLogLocked()');
      expect(
        service
            .substring(close, close + 200)
            .contains('flushLogRepeatLocked()'),
        isTrue,
      );
    });

    test('the bridge logs into psiphon.log, through the '
        'service (build 2091: it is in-process again)', () {
      expect(service.contains('File(dir, "tunlink.log")'), isFalse);
      expect(service.contains('rotateLogPerSession(tunLog)'), isFalse);
      expect(
        service.contains(
            'Tun2SocksManager.logger = { line -> logLine(line) }'),
        isTrue,
      );
      expect(service.contains('object PsiphonTun2SocksLog'), isFalse);
    });
  });

  group('2065 defect (rung-config audit): edge results from '
      'another network fed to the core at probability 1.0', () {
    test('the controller can invalidate edge results', () {
      final controller = dartSrc('psiphon/psiphon_controller.dart');
      expect(controller.contains('Future<void> invalidateEdgeResults()'),
          isTrue);
      expect(controller.contains('settings.edgesTestedAtMs = 0'), isTrue);
    });

    test('a network change invalidates them', () {
      final shell = dartSrc('ui/ember/ember_shell.dart');
      expect(shell.contains('_psiphon.invalidateEdgeResults()'), isTrue);
    });
  });
}
