/// Build 2091 gates — the MLM Psiphon transplant (merged
/// with the service-reachability-checks passenger from the
/// 06:50 cron run; that run's own tests live in
/// build2091_test.dart).
///
/// The owner's order was the MLM (ralysnd) app's Psiphon,
/// implemented COMPLETELY from its source after analysis
/// (mlm-psiphon-full-analysis.md). Pinned here:
///   1. The artifacts: the byte-exact MLM AAR (sha256
///      426c0fda…), MLM's 493-line server_entries.txt, and
///      the badvpn libtun2socks.so (arm64, sha256
///      692dd830…) staged in jniLibs — the same hashes the
///      2088 package carried, re-verified at landing.
///   2. The identity set: MLM's propagation channel,
///      sponsor and client version, the anti-hijack DNS trio,
///      the fronting provider IDs, the protocol families.
///   3. The ladder: MLM's order and budgets, the region
///      phase (25 s) in front of it, the +8 s timer grace,
///      the per-rung data roots, the tactics override on
///      A/E/D only, and the winner memory's key pattern.
///   4. The protection stack: TUN raised before the core
///      starts, setVpnMode(false) always, protect() on
///      every core socket, own package disallowed.
///   5. The quality gate: six streams, 768 KB, the 0.9
///      Mbit/s floor, at most three draws per rung, and the
///      replay-state drop between draws.
///   6. The contract changes: proxy mode waits for the
///      core's onConnected like VPN mode (the §9.4 success
///      definition), the Dart-side sidecar config write is
///      gone, and the sidecar is out of the start path and
///      the APK.
/// What only the owner's phone can prove — a tunnel on his
/// network, and whether the library wedge (risk R1) fires
/// — is NOT claimed here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/sha256.dart';

String src(String rel) => File(rel).readAsStringSync();
String kotlinSrc(String name) => src(
      'android/app/src/main/kotlin/com/ralysnd/ember/$name',
    );
String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

void main() {
  group('transplant artifacts (build 2091)', () {
    test('the MLM AAR is byte-exact', () {
      final bytes = File('android/app/libs/psiphon.aar').readAsBytesSync();
      expect(
        sha256Hex(bytes),
        '426c0fda04a69bb9bba581f65ae9375662c66920effe46b4b51b930816ab87db',
      );
    });

    test('the bundled entries are MLM\'s 493 hex lines', () {
      final lines = File('assets/psiphon/server_entries.txt')
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .toList();
      expect(lines.length, 493);
      for (final line in lines) {
        expect(
          RegExp(r'^[0-9a-f]+$').hasMatch(line.trim()),
          isTrue,
          reason: 'every entry line is hex',
        );
      }
      // One entry decodes to a JSON object with capabilities.
      // Entries are length-prefixed (4 bytes, then the object),
      // so the parse takes everything from the first '{'.
      final first = utf8.decode(
        List<int>.generate(
          lines.first.length ~/ 2,
          (i) => int.parse(lines.first.substring(i * 2, i * 2 + 2), radix: 16),
        ),
      );
      final jsonText = first.substring(first.indexOf('{'));
      final entry = jsonDecode(jsonText) as Map<String, dynamic>;
      expect(entry.containsKey('capabilities'), isTrue);
    });

    test('libtun2socks.so is staged, byte-exact with MLM\'s', () {
      final bytes = File(
        'android/app/src/main/jniLibs/arm64-v8a/libtun2socks.so',
      ).readAsBytesSync();
      expect(
        sha256Hex(bytes),
        '692dd830e817efe45126105ca406cef448b4ffc56d13c4810b40e96f0e05e599',
      );
    });

    test('the sidecar .so is out of the APK', () {
      final dir = Directory('android/app/src/main/jniLibs/arm64-v8a');
      final names = dir.listSync().map((e) => e.path.split('/').last).toSet();
      expect(names.contains('libpsiphonbox.so'), isFalse);
      expect(names.contains('libtun2socks.so'), isTrue);
    });
  });

  group('MLM identity + DNS trio (build 2091)', () {
    final constants = kotlinSrc('PsiphonConstants.kt');

    test('the identity set is MLM\'s, not the official app\'s', () {
      expect(constants.contains('"FFFFFFFFFFFFFFFF"'), isTrue);
      expect(constants.contains('"1111111111111111"'), isTrue);
      expect(constants.contains('CLIENT_VERSION = "1"'), isTrue);
      expect(constants.contains('"92AACC5BABE0944C"'), isFalse);
      expect(constants.contains('"40001BC527D3D099"'), isFalse);
      expect(constants.contains('CLIENT_VERSION = "509"'), isFalse);
    });

    test('the trust keys are unchanged (byte-identical in both apps)', () {
      expect(
        constants.contains(
          'MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+',
        ),
        isTrue,
      );
      expect(
        constants.contains('sHuUVTWaRyh5pZwy4UguSgkwmBe0EHtJJkoF5WrxmvA='),
        isTrue,
      );
      expect(
        constants.contains('DpXzloJk1Hw6aSzmKKky0xcahsEHubch81Mi6K0XMlU='),
        isTrue,
      );
    });

    test('the anti-hijack DNS trio is MLM\'s, on non-standard ports', () {
      expect(constants.contains('"208.67.222.222:5353"'), isTrue);
      expect(constants.contains('"9.9.9.9:9953"'), isTrue);
      expect(constants.contains('"208.67.220.220:5353"'), isTrue);
      expect(
        constants.contains('FRONTING_PROVIDER_AKAMAI = "BACEC04E64813F2B"'),
        isTrue,
      );
      expect(
        constants.contains('FRONTING_PROVIDER_FASTLY = "089D05B86ACE8D3B"'),
        isTrue,
      );
    });

    test('the server-list channel is iohq-waa4-q4dt on both lists', () {
      expect(
        RegExp(r'https://[^\s"]*iohq-waa4-q4dt')
            .allMatches(constants)
            .length,
        8,
      );
    });
  });

  group('the ladder (build 2091)', () {
    final methods = kotlinSrc('PsiphonMethods.kt');
    final svc = kotlinSrc('PsiphonVpnService.kt');

    test('MLM\'s order and budgets', () {
      expect(methods.contains('listOf("A", "E", "D", "C", "P")'), isTrue);
      for (final entry in {
        '"A" -> 60': true,
        '"E" -> 45': true,
        '"D" -> 45': true,
        '"C" -> 75': true,
        '"P" -> 90': true,
        '"X" -> 45': true,
      }.keys) {
        expect(methods.contains(entry), isTrue, reason: entry);
      }
    });

    test('the winner memory is keyed by mode, by rung name', () {
      expect(methods.contains('"psiphon_last_rung_chained"'), isTrue);
      expect(methods.contains('"psiphon_last_rung"'), isTrue);
      expect(svc.contains('PsiphonMethods.remembered(this,'), isTrue);
      expect(svc.contains('PsiphonMethods.remember(this,'), isTrue);
    });

    test('the region phase is 25 s, in front of the ladder', () {
      expect(
        svc.contains('REGION_PHASE_TIMEOUT_SECONDS = 25'),
        isTrue,
      );
      expect(svc.contains('regionPhase = inRegion.isNotEmpty()'), isTrue);
      // A failed region phase is not counted: the flag clears
      // and the same rung restarts unfiltered.
      expect(
        svc.contains('regionPhase = false'),
        isTrue,
      );
    });

    test('the ladder timer is the rung budget plus 8 s grace', () {
      expect(svc.contains('LADDER_GRACE_SECONDS = 8'), isTrue);
      expect(
        svc.contains('rungSeconds(strategy) + LADDER_GRACE_SECONDS'),
        isTrue,
      );
    });

    test('rungs E and X own their data roots', () {
      expect(svc.contains('"psiphon-clean"'), isTrue);
      expect(svc.contains('"psiphon-upstream"'), isTrue);
      expect(svc.contains('"DataRootDirectory"'), isTrue);
    });

    test('tactics are disabled on A/E/D only', () {
      // The override is called from the A, E and D configure
      // blocks — and from no other rung's.
      final calls = 'applyTacticsOverride(config)'.allMatches(svc).length;
      expect(calls, 3);
      expect(svc.contains('config.put("DisableTactics", true)'), isTrue);
    });

    test('attribution is deferred 2 s and precedes onConnected\'s '
        'mode branch', () {
      final onConnected = svc.indexOf('override fun onConnected()');
      final schedule = svc.indexOf('scheduleLadderAttribution()', onConnected);
      expect(schedule, greaterThan(onConnected));
      expect(svc.contains('2, TimeUnit.SECONDS'), isTrue);
    });
  });

  group('the protection stack (build 2091)', () {
    final svc = kotlinSrc('PsiphonVpnService.kt');

    test('the TUN is raised before the core starts', () {
      final startTunnel = svc.indexOf('private fun startTunnel()');
      final establish = svc.indexOf('.establish()', startTunnel);
      final startCore = svc.indexOf('startPsiphonTunnel()', startTunnel);
      expect(establish, greaterThan(startTunnel));
      expect(startCore, greaterThan(establish));
    });

    test('setVpnMode(false) always', () {
      expect(svc.contains('tunnel.setVpnMode(false)'), isTrue);
      expect(svc.contains('setVpnMode(true)'), isFalse);
      expect(svc.contains('setVpnMode(inVpnMode)'), isFalse);
    });

    test('every core socket is protect()ed through the binding', () {
      expect(svc.contains('override fun bindToDevice(fd: Long)'), isTrue);
      expect(svc.contains('protect(fd.toInt())'), isTrue);
      expect(
        svc.contains('throw PsiphonTunnel.Exception('),
        isTrue,
      );
    });

    test('our own package is disallowed from the TUN', () {
      final apply = svc.indexOf('private fun applyApps(');
      expect(
        svc.indexOf('addDisallowedApplication(packageName)', apply),
        greaterThan(apply),
      );
      // INCLUDE mode never puts our package in the allowed set.
      expect(
        svc.contains('CoreService.appSet(this, CoreService.ONLY) - packageName'),
        isTrue,
      );
    });

    test('the TUN DNS is the lwIP router plus the public pair', () {
      expect(svc.contains('.addDnsServer(address.router)'), isTrue);
      expect(svc.contains('.addDnsServer("1.1.1.1")'), isTrue);
      expect(svc.contains('.addDnsServer("8.8.8.8")'), isTrue);
    });

    test('the config reaches the library through getPsiphonConfig', () {
      expect(
        svc.contains('override fun getPsiphonConfig(): String = psiphonConfigJson'),
        isTrue,
      );
      expect(svc.contains('psiphonConfigJson = buildPsiphonConfig()'), isTrue);
    });

    test('the entries are loaded from the MLM asset and handed over', () {
      expect(svc.contains('SERVER_ENTRIES_ASSET'), isTrue);
      expect(svc.contains('tunnel.startTunneling(serverEntries)'), isTrue);
    });
  });

  group('the quality gate (build 2091)', () {
    final quality = kotlinSrc('PsiphonQuality.kt');
    final svc = kotlinSrc('PsiphonVpnService.kt');

    test('six streams, 768 KB, the 0.9 Mbit/s floor, three draws', () {
      expect(quality.contains('STREAMS = 6'), isTrue);
      expect(quality.contains('BYTES = 768 * 1024'), isTrue);
      expect(quality.contains('MIN_GOOD_MBIT = 0.9'), isTrue);
      expect(quality.contains('MAX_SERVER_ATTEMPTS = 3'), isTrue);
    });

    test('the gate runs on the worker before routing activates', () {
      expect(svc.contains('worker.execute { psiphonQualityCheck('), isTrue);
      expect(svc.contains('PsiphonQuality.measure('), isTrue);
      expect(svc.contains('dropReplayState('), isTrue);
      expect(svc.contains('activateRouting()'), isTrue);
      // The gate's pass is the only path that activates routing.
      final gate = svc.indexOf('private fun psiphonQualityCheck(');
      expect(
        svc.indexOf('activateRouting()', gate),
        greaterThan(gate),
      );
    });

    test('upstream rungs skip the gate', () {
      expect(
        svc.contains('rung.upstream == null'),
        isTrue,
      );
    });
  });

  group('the contract changes (build 2091)', () {
    final controller = dartSrc('psiphon/psiphon_controller.dart');
    final platform = dartSrc('psiphon/psiphon_platform.dart');

    test('proxy mode waits for the core\'s onConnected, like VPN mode', () {
      // The old vpnMode gate around the connected wait is gone.
      expect(controller.contains('if (settings.vpnMode) {'), isFalse);
      expect(controller.contains('var connected = false;'), isTrue);
      expect(controller.contains('state.connected'), isTrue);
    });

    test('the Dart-side sidecar config write is gone', () {
      expect(platform.contains('buildPsiphonSidecarConfig('), isFalse);
      expect(platform.contains('psiphonbox'), isFalse);
      expect(platform.contains('config.json'), isFalse);
    });

    test('readLogs no longer lists the sidecar or tunlink logs', () {
      expect(controller.contains("'psiphonbox/"), isFalse);
      expect(controller.contains('psiphonbox-stdout'), isFalse);
      expect(controller.contains("('tunlink.log'"), isFalse);
      expect(controller.contains("'psiphon.log'"), isTrue);
      expect(controller.contains("'crash.log'"), isTrue);
    });

    test('the service no longer calls the sidecar on the start path', () {
      final svc = kotlinSrc('PsiphonVpnService.kt');
      expect(svc.contains('PsiphonBoxCore.start('), isFalse);
      expect(svc.contains('PsiphonBoxCore.stop()'), isFalse);
      expect(svc.contains('PsiphonBoxCore.extractEmbeddedEntries('), isFalse);
      expect(svc.contains('appendBoxEvidence('), isFalse);
      expect(svc.contains('PsiphonTunnel.newPsiphonTunnel(this)'), isTrue);
    });

    test('the bridge is the in-process badvpn manager, not a subprocess', () {
      final svc = kotlinSrc('PsiphonVpnService.kt');
      expect(svc.contains('Tun2SocksManager.start('), isTrue);
      expect(svc.contains('libtunlink.so'), isFalse);
      expect(svc.contains('LocalServerSocket'), isFalse);
      final manager = kotlinSrc('Tun2SocksManager.kt');
      expect(
        manager.contains('"com.ralysnd.ember.Tun2SocksManager"'),
        isTrue,
      );
      expect(manager.contains('7300'), isTrue);
    });
  });

  group('build 2123 — P-01 claim gating (plan §5)', () {
    test('the claim sits after the mode parse and the running refusal, '
        'guarded by the mode', () {
      final svc = kotlinSrc('PsiphonVpnService.kt');
      const claim = 'EngineClaim.claim(this, EngineClaim.PSIPHON)';
      // Exactly one claim call site in the service.
      expect(claim.allMatches(svc).length, 1);
      final claimAt = svc.indexOf(claim);
      final modeAt =
          svc.indexOf('inVpnMode = intent.getBooleanExtra(EXTRA_VPN_MODE');
      final refusalAt = svc.indexOf('psiphon:start-ignored-in-flight');
      expect(modeAt, greaterThanOrEqualTo(0));
      expect(refusalAt, greaterThanOrEqualTo(0));
      // Parse first, refusal second, claim last (plan §5 order).
      expect(claimAt, greaterThan(modeAt));
      expect(claimAt, greaterThan(refusalAt));
      // The claim is directly guarded by the TUN-mode condition.
      final guardAt = svc.lastIndexOf('if (inVpnMode) {', claimAt);
      expect(guardAt, greaterThanOrEqualTo(0));
      expect(claimAt - guardAt, lessThan(600));
      // And it records that this instance owns the slot.
      expect(svc.contains('claimedSlot = true'), isTrue);
      expect(svc.contains('private var claimedSlot = false'), isTrue);
    });

    test('both release sites are claimedSlot-guarded', () {
      final svc = kotlinSrc('PsiphonVpnService.kt');
      const release = 'EngineClaim.release(this, EngineClaim.PSIPHON)';
      expect(release.allMatches(svc).length, 2);
      for (final m in release.allMatches(svc)) {
        final before = svc.substring(
          m.start - 400 < 0 ? 0 : m.start - 400,
          m.start,
        );
        expect(before.contains('if (claimedSlot) {'), isTrue,
            reason: 'release at ${m.start} is not claimedSlot-guarded');
      }
    });

    test('the host side is unchanged: respawn still starts proxy-only',
        () {
      final host = kotlinSrc('XrayVpnService.kt');
      final respawnAt = host.indexOf('private fun respawnUnderlay()');
      final startAt = host.indexOf('PsiphonVpnService.start(', respawnAt);
      expect(respawnAt, greaterThanOrEqualTo(0));
      expect(startAt, greaterThan(respawnAt));
      // vpnMode=false is the second argument of the respawn start.
      final args = host.substring(startAt, startAt + 120);
      expect(args.contains('this,\n            false,'), isTrue);
      expect(host.contains('PsiphonVpnService.stop(this)'), isTrue);
    });

    test('S-3: the TUN captures IPv6 into the blackhole and drops it',
        () {
      final svc = kotlinSrc('PsiphonVpnService.kt');
      expect(
        svc.contains(
            'private const val IPV6_BLACKHOLE = "fd00:6e64:6f63::1"'),
        isTrue,
      );
      expect(svc.contains('.addAddress(IPV6_BLACKHOLE, 128)'), isTrue);
      expect(svc.contains('.addRoute("::", 0)'), isTrue);
      // The v6 lines sit inside the TUN builder (after the v4 plan).
      final v4At = svc.indexOf('.addRoute("0.0.0.0", 0)');
      final v6At = svc.indexOf('.addAddress(IPV6_BLACKHOLE, 128)');
      expect(v6At, greaterThan(v4At));
    });

    test('S-5: the periodic poll evaluates the watchdog while armed',
        () {
      final controller = dartSrc('psiphon/psiphon_controller.dart');
      expect(
        controller.contains(
            'if (_watchdog.armed && sample.running && !sample.connected) {'),
        isTrue,
      );
      final at = controller.indexOf('if (_watchdog.armed');
      expect(
        controller.substring(at, at + 200).contains('_maybeFireWatchdog()'),
        isTrue,
      );
      // The adoption re-arm itself is untouched.
      expect(controller.contains('_watchdog.arm(nowForWatchdog());'),
          isTrue);
    });

    test('wf.jar is wired and the AAR silencer dontwarns are gone', () {
      final gradle = src('android/app/build.gradle.kts');
      expect(gradle.contains('implementation(files("libs/wf.jar"))'),
          isTrue);
      final proguard = src('android/app/proguard-rules.pro');
      // Rule lines only — the file's comments legitimately
      // name the removed rules when explaining the change.
      final ruleLines = proguard
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toList();
      expect(ruleLines.contains('-dontwarn wf.c'), isFalse);
      expect(ruleLines.contains('-dontwarn f0.a'), isFalse);
      expect(ruleLines.contains('-dontwarn w3.z'), isFalse);
      expect(ruleLines.contains('-keep class wf.** { *; }'), isTrue);
      final wfJar = File('android/app/libs/wf.jar');
      expect(wfJar.existsSync(), isTrue);
    });
  });
}
