/// Build 2096 — post-2095 audit, batch B: the generation /
/// arbitration discipline reaches the paths around the
/// Xray main path. Behavioral tests over the mocked
/// 'app/android' channel (the build-2095 batch-6 harness
/// pattern), not source pins — except H6, whose hooks are
/// private shell methods with no widget harness (the
/// audit-3 8-6/8-7 gap, still parked); those are pinned
/// the way build 2095 pinned its native surfaces.
///
/// - H3: the WireGuard peer-fallback walk died after
///   every successful leg (the leg's own gen bump was
///   never absorbed on the success path), so a silent
///   first peer never fell through.
/// - H4: _connectAwg had no generation re-check — a
///   disconnect in its pre-start window was overtaken.
/// - H5: Lantern's setOn fired before the first gen
///   check; a disconnect during arbitration resurrected
///   the core.
/// - H6: stop hooks ignored the connecting window for
///   OpenVPN / Lantern / Xray; _engineConnecting(4)
///   never read OpenVPN's busy flag.
/// - M22: Aether's proof waits never re-checked the
///   generation — a mid-wait disconnect left the engine
///   burning minutes proxy-only.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/aether/aether_controller.dart';
import 'package:firefox_vpn/aether/aether_platform.dart';
import 'package:firefox_vpn/lantern/lantern_controller.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

const _key = 'aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGxvaGU=';

Profile _wg(String id, String address, String peerKey, {String awgJc = ''}) =>
    Profile(
      id: id,
      protocol: Protocol.wireguard,
      name: id,
      address: address,
      port: 51820,
      secretKey: _key,
      peerPublicKey: peerKey,
      localAddress: '172.16.0.2/32',
      awgJc: awgJc,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final calls = <String>[];

  // Xray native state, driven by the test.
  var xRunning = false;
  var xAwg = false;
  var xPeer = '';

  Map<String, Object?> xrayStateMap() => <String, Object?>{
    'running': xRunning,
    'name': 'N',
    'sinceMs': 1000,
    'up': 0,
    'down': 0,
    'coreRestarts': 0,
    'coreProblem': '',
    'chainUnderlay': false,
    'chainProblem': '',
    'awg': xAwg,
    'awgConfig': '',
    'rotationGen': 0,
    'killSwitchHeld': false,
    'paused': false,
    'userStopped': false,
  };

  void installHandler(Future<Object?> Function(MethodCall) extra) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'),
            (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'dataDir':
          return '${tempDir.path}/core';
        case 'xrayState':
          return xrayStateMap();
        case 'xraySetOn':
          final config = (call.arguments as Map)['config'] as String;
          xPeer = config.contains('198.51.100.2')
              ? 'peer2'
              : config.contains('198.51.100.1')
              ? 'peer1'
              : '';
          xRunning = true;
          xAwg = false;
          return null;
        case 'awgSetOn':
          xRunning = true;
          xAwg = true;
          return null;
        case 'xrayStop':
          xRunning = false;
          xAwg = false;
          return null;
        case 'xrayTunnelCheck':
          return -1; // nothing carries unless exit info says so
        case 'xrayExitInfo':
          return xPeer == 'peer2'
              ? <String, String>{
                  'ip': '203.0.113.9',
                  'countryCode': 'NL',
                  'country': 'Netherlands',
                }
              : null;
        default:
          return extra(call);
      }
    });
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ember2096b');
    await Directory('${tempDir.path}/xray').create(recursive: true);
    calls.clear();
    xRunning = false;
    xAwg = false;
    xPeer = '';
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('H3 — the WireGuard peer walk reaches the next peer', () {
    test(
      'a silent first peer falls through to the carrying second peer',
      () async {
        installHandler((_) async => null);
        final c = XrayController();
        // No dispose(): the session poll timer outlives
        // it (the app never disposes this controller) and
        // a tick after dispose throws in ChangeNotifier.
        addTearDown(() async {
          await c.disconnect();
        });
        final peer1 = _wg('peer1', '198.51.100.1', _key);
        final peer2 = _wg('peer2', '198.51.100.2', _key);
        c.profiles.addAll([peer1, peer2]);
        c.selectedProfileId = peer1.id;

        // On the build-2095 code this returned silently
        // after peer1's leg: peer2 was never attempted and
        // no error was thrown.
        await c.connectWireGuardWithFallback(peer1).timeout(
          const Duration(seconds: 90),
        );
        final setOns = calls.where((m) => m == 'xraySetOn').length;
        expect(setOns, 2, reason: 'both peers were attempted');
        expect(c.selectedProfileId, peer2.id);
        expect(c.state.running, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'a single silent peer ends in wg-all-peers-failed, not silence',
      () async {
        installHandler((_) async => null);
        final c = XrayController();
        // No dispose(): the session poll timer outlives
        // it (the app never disposes this controller) and
        // a tick after dispose throws in ChangeNotifier.
        addTearDown(() async {
          await c.disconnect();
        });
        final peer1 = _wg('peer1', '198.51.100.1', _key);
        c.profiles.add(peer1);
        c.selectedProfileId = peer1.id;
        await expectLater(
          c.connectWireGuardWithFallback(peer1),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'wg-all-peers-failed',
            ),
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  group('H4 — a disconnect during the AWG attempt ends the walk', () {
    test('the plain leg never starts after the disconnect', () async {
      installHandler((_) async => null);
      final c = XrayController();
      addTearDown(() async {
        await c.disconnect();
      });
      final awg = _wg('awg1', '198.51.100.1', _key, awgJc: '5');
      c.profiles.add(awg);
      c.selectedProfileId = awg.id;

      Object? walkError;
      final walk = c
          .connectWireGuardWithFallback(awg)
          .then((_) {}, onError: (Object e) { walkError = e; });
      // Wait until the AWG attempt is in its handshake
      // poll (the mock never lets it handshake).
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!calls.contains('awgSetOn')) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the AWG attempt never started');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await c.disconnect();
      await walk.timeout(const Duration(seconds: 15));

      expect(walkError, isNull);
      expect(
        calls.where((m) => m == 'xraySetOn'),
        isEmpty,
        reason: 'no plain-WireGuard leg may start after a disconnect',
      );
      expect(calls.where((m) => m == 'awgSetOn').length, 1);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('H5 — Lantern never starts after a disconnect in arbitration', () {
    test('setOn is not called when the stop lands first', () async {
      final gate = Completer<void>();
      var lanternRunning = false;
      installHandler((call) async {
        switch (call.method) {
          case 'lanternState':
            return <String, Object?>{
              'available': true,
              'running': lanternRunning,
              'coreRunning': lanternRunning,
              'connected': false,
              'keptServers': 3,
              'keptMasque': 0,
            };
          case 'lanternSetOn':
            lanternRunning = true;
            return null;
          case 'lanternStop':
            lanternRunning = false;
            return null;
        }
        return null;
      });
      final c = LanternController();
      addTearDown(c.dispose);
      c.stopOtherEngine = () => gate.future;

      final connectFuture = c.connect();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await c.disconnect();
      gate.complete();
      await connectFuture.timeout(const Duration(seconds: 10));

      expect(
        calls.where((m) => m == 'lanternSetOn'),
        isEmpty,
        reason: 'the core must not start after the user stopped it',
      );
      expect(lanternRunning, isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('M22 — Aether proof waits honour a mid-wait disconnect', () {
    // Build 2115 re-point: the connect's FIRST proof is the
    // data proof now (the trace gate used to run first and
    // kept the data proof from ever running on the owner's
    // phone). The scenario is unchanged — a disconnect lands
    // while the connect sits in its first proof — but the
    // proof it sits in is the data proof, gated here, and
    // the assertion flips to the proof that must now never
    // run: the trace.
    test('the WARP proof never runs and no error surfaces', () async {
      var engineRunning = false;
      var probeCalls = 0;
      var traceCalls = 0;
      final probeGate = Completer<void>();
      installHandler((call) async {
        switch (call.method) {
          case 'aetherState':
            return <String, Object?>{
              'engine': 'cfwarp',
              'running': engineRunning,
              'stage': engineRunning ? 'connected' : 'idle',
              'connected': engineRunning,
              'identity': true,
              'error': '',
            };
          case 'aetherStart':
            engineRunning = true;
            return true;
          case 'aetherStop':
            engineRunning = false;
            return null;
          case 'aetherTrace':
            traceCalls++;
            return <String, String>{'warp': 'off', 'ip': '203.0.113.1'};
          case 'aetherDataProbe':
            probeCalls++;
            await probeGate.future;
            return <String, Object?>{'ok': true};
        }
        return null;
      });
      final c = AetherController('cfwarp');
      addTearDown(c.dispose);
      c.options = const AetherOptions(protocol: 'wg');

      Object? connectError;
      final connectFuture = c
          .connect()
          .then((_) {}, onError: (Object e) { connectError = e; });
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (probeCalls == 0) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the data proof never ran');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await c.disconnect();
      probeGate.complete();
      await connectFuture.timeout(const Duration(seconds: 15));

      expect(connectError, isNull);
      expect(
        traceCalls,
        0,
        reason: 'a superseded connect stops at the proof it was in',
      );
      expect(c.lastError, isNull);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('H6 — shell stop hooks cover the connecting window (pins)', () {
    test('the hooks and the OpenVPN connecting case read the busy flags', () {
      final shell = File('lib/ui/ember/ember_shell.dart').readAsStringSync();
      expect(shell.contains('_lantern.connecting'), isTrue);
      expect(shell.contains('_openvpn.connecting'), isTrue);
      expect(
        shell
            .split('if (_xray.state.running || _xray.connecting)')
            .length -
            1,
        greaterThanOrEqualTo(6),
        reason: 'every Xray stop hook covers the connecting window',
      );
    });
  });
}
