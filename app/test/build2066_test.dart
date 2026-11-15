// Build 2066 — the 2065 Psiphon regression fix (owner report
// 2026-11-14: «کرش میده سایفون» on mobile data). The pasted device
// logs proved: (1) the TUN/tunlink bridge was raised before the
// Psiphon core had any tunnel and sprayed SOCKS UDP ASSOCIATE at
// the core's CONNECT-only SOCKS — hundreds of identical accept
// errors, every TCP failing, the phone blackholed; (2) nothing
// bounded the blackhole: the only teardown watch (F-M4) waits for
// diagnostic SILENCE, which a live core cycling candidates never
// gives. The fix ports ralysnd's device-proven contract: badvpn
// tun2socks (TCP via SOCKS CONNECT, UDP via the core's udpgw
// intercept), the TUN raised only after connected, a 90 s
// tunnel-loss bound, log dedupe, and edge-result invalidation on
// network change. These pins fail on the 2065 code shape and pass
// after.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String javaSrc(String rel) =>
    File('android/app/src/main/java/$rel').readAsStringSync();

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

void main() {
  final service = ktSrc('PsiphonVpnService.kt');

  group('2065 defect: the bridge sprayed SOCKS UDP ASSOCIATE at '
      'the CONNECT-only Psiphon SOCKS (the log flood)', () {
    test('the Psiphon service no longer drives libtunlink', () {
      // The generic helper's UDP path IS UDP ASSOCIATE; it stays
      // correct for the Xray engine (its SOCKS supports it) but
      // must never bridge a Psiphon session again.
      expect(service.contains('libtunlink.so'), isFalse);
      expect(service.contains('tunProcess'), isFalse);
      expect(service.contains('-proxy'), isFalse);
      expect(service.contains('LocalServerSocket'), isFalse);
    });

    test('the bridge is badvpn tun2socks via the JNI loader', () {
      expect(service.contains('Tun2SocksJniLoader.runTun2Socks'), isTrue);
      expect(service.contains('Tun2SocksJniLoader.terminateTun2Socks'),
          isTrue);
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
    });

    test('UDP goes to the core udpgw intercept, DNS transparent, '
        'not DNS-only', () {
      expect(service.contains('UDPGW_SERVER_ADDRESS = "127.0.0.1:7300"'),
          isTrue);
      expect(service.contains('UDPGW_SERVER_ADDRESS,'), isTrue);
      // transparent DNS on (1), dnsOnly off (0) — the Psiphon
      // shape; Tor's dnsOnly shape would drop all non-DNS UDP.
      expect(service.contains('1, // transparent DNS through udpgw'),
          isTrue);
      expect(service.contains('0, // udpgw carries all UDP, not just DNS'),
          isTrue);
    });

    test('the loader class is the upstream contract', () {
      final loader = javaSrc('ca/psiphon/Tun2SocksJniLoader.java');
      expect(loader.contains('package ca.psiphon;'), isTrue);
      expect(loader.contains('class Tun2SocksJniLoader'), isTrue);
      expect(loader.contains('String udpgwServerAddress'), isTrue);
      expect(loader.contains('int udpgwTransparentDNS'), isTrue);
      expect(loader.contains('System.loadLibrary("tun2socks")'), isTrue);
    });

    test('lwIP gets the router address, never the interface '
        'address', () {
      // ralysnd's load-bearing asymmetry: the Builder address is
      // 10.10.15.1; lwIP must be handed 10.10.15.2 or it silently
      // drops every packet.
      expect(service.contains('TUN_ROUTER_ADDRESS = "10.10.15.2"'), isTrue);
      expect(service.contains('addAddress("10.10.15.1", 30)'), isTrue);
      expect(service.contains('runTun2Socks('), isTrue);
      final call = service.indexOf('runTun2Socks(');
      expect(service.substring(call, call + 400).contains('TUN_ROUTER_ADDRESS'),
          isTrue);
    });

    test('single-instance discipline: join the previous bridge '
        'before any new start', () {
      expect(service.contains('lastBridgeThread'), isTrue);
      expect(service.contains('BRIDGE_EXIT_GRACE_MS = 5000L'), isTrue);
      expect(service.contains('previous.join(BRIDGE_EXIT_GRACE_MS)'),
          isTrue);
      expect(service.contains('refusing a second start'), isTrue);
    });

    test('stop discipline replaces the process kill (the F-M1 '
        'shape, for a thread): terminate, then a bounded join', () {
      // Build 2054's F-M1 pin dropped Psiphon from the
      // ProcessKill map because this service owns no process
      // now; the equivalent guarantee lives here.
      expect(service.contains('ProcessKill.kill'), isFalse);
      final stop = service.indexOf('private fun stopBridge()');
      expect(stop, isNot(-1));
      final body = service.substring(stop, stop + 900);
      expect(body.contains('terminateTun2Socks()'), isTrue);
      expect(body.contains('thread.join(BRIDGE_EXIT_GRACE_MS)'), isTrue);
    });
  });

  group('2065 defect: the TUN was raised before any tunnel '
      'existed and nothing bounded the blackhole', () {
    test('the legacy path waits for connected before the TUN', () {
      expect(service.contains('waitForConnected(CONNECT_WAIT_MS)'), isTrue);
      expect(service.contains('CONNECT_WAIT_MS = 120000L'), isTrue);
      final gate = service.indexOf('waitForConnected(CONNECT_WAIT_MS)');
      final establish = service.indexOf('builder.establish()');
      expect(gate, isNot(-1));
      expect(establish, greaterThan(gate));
      // ...and the bridge starts only after the interface exists.
      expect(service.indexOf('startBridge(pfd, mtu)'),
          greaterThan(establish));
    });

    test('a dead tunnel with the TUN up is torn down in 90 s', () {
      expect(service.contains('TUNNEL_LOSS_MS = 90000L'), isTrue);
      expect(service.contains('maxOf(tunUpAtMs, lastConnectedMs)'), isTrue);
      expect(service.contains('tearing the session down'), isTrue);
      // The F-M4 silence watchdog stays as the second guard.
      expect(service.contains('NOTICE_SILENCE_MS'), isTrue);
      expect(service.contains('CONNECT_DEADLINE_MS'), isTrue);
    });

    test('bridge death ends the session (watcher)', () {
      expect(service.contains('bridge != null && !bridge.isAlive'), isTrue);
    });
  });

  group('2065 defect: hundreds of identical log lines in '
      'seconds (file growth, choked log viewer)', () {
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

    test('bridge log lines route into the deduped session log', () {
      expect(service.contains('object PsiphonTun2SocksLog'), isTrue);
      expect(service.contains('bridgeLogSink'), isTrue);
      expect(service.contains('"logTun2Socks"'), isTrue);
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
