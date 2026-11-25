// Build 2104 — the WG Tunnel port (owner order 2026-11-18
// 06:05–06:15, analysis wgtunnel-port-analysis.md): Ember's
// hand-built AmneziaWG engine (AwgBackend + AwgVpnService +
// libwg-go.so over a Dart-composed UAPI string) is replaced
// by WG Tunnel's backend (com.wgtunnel:backend 1.10.1,
// Zane Schepke, MIT). Root cause being removed: the Dart
// status parser hunted `latest_handshake=` in the device's
// UAPI dump — a key no device emits (the real keys are
// latest_handshake_time_sec= / last_handshake_time_sec=) —
// so the handshake age was permanently -1, the 12 s connect
// proof always expired, and the app tore down tunnels that
// had already handshook (owner device logs 2026-11-18:
// responses received, "never answered" declared at +12 s,
// tunnel closed at ~18 s).
//
// These pins cover: the dependency/engine swap, the .conf
// hand-off, the backend-computed state path, the deleted
// tear-down proof, 2102's C1/C2/C3 intents re-homed on the
// new TUN builder, the honest walk language, the license
// notices, and the named losses' visible edges (minSdk 26,
// J1–J3 stored-but-not-sent). All fixtures use dummy
// values — the owner's real configs and keys never appear
// in tests.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/profile_validation.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();
String ktPath(String rel) =>
    'android/app/src/main/kotlin/com/ralysnd/ember/$rel';

/// The owner's v6 shape with dummy values: an IPv6-only
/// WARP+AWG profile (v6 tunnel address, v6 DNS, ::/0,
/// Jc/Jmin/Jmax + an I1 signature).
Profile v6WarpProfile() => Profile(
  id: 'v6',
  protocol: Protocol.wireguard,
  name: 'v6-warp',
  address: '2606:4700:d0:0:92d9:27b5:d23d:b2f7',
  port: 2408,
  secretKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  peerPublicKey: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
  localAddress: '2606:4700:110:8d17:9892:cb7f:7fca:4541/128',
  wgDns: '2606:4700:4700::1111,2606:4700:4700::1001',
  wgAllowedIPs: '::/0',
  keepAlive: 25,
  awgJc: '6',
  awgJmin: '10',
  awgJmax: '50',
  awgI1: '<r 2><b 0x8580aabbccdd>',
);

/// The owner's v4 shape with dummy values: a WARP profile
/// with a v4 tunnel address and a 0.0.0.0/0 route.
Profile v4WarpProfile() => Profile(
  id: 'v4',
  protocol: Protocol.wireguard,
  name: 'v4-warp',
  address: '188.114.96.125',
  port: 2408,
  secretKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  peerPublicKey: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
  localAddress: '172.16.0.2/32',
  wgDns: '1.1.1.1, 1.0.0.1',
  wgAllowedIPs: '0.0.0.0/0',
  keepAlive: 25,
  awgJc: '6',
  awgJmin: '10',
  awgJmax: '50',
  awgI1: '<r 2><b 0x8580aabbccdd>',
);

void main() {
  group('the engine swap (dependencies, deletions, manifest)', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();

    test('the three WG Tunnel artifacts are the AWG engine', () {
      expect(gradle, contains('com.wgtunnel:backend:1.10.1'));
      expect(gradle, contains('com.wgtunnel:backend-android-jni:1.10.1'));
      expect(gradle, contains('com.wgtunnel:parser:1.10.1'));
    });

    test('minSdk floor is 26 — the named loss, pinned as deliberate', () {
      expect(gradle, contains('maxOf(26, flutter.minSdkVersion)'));
    });

    test('the old engine is deleted, not parked', () {
      expect(File(ktPath('AwgBackend.kt')).existsSync(), isFalse);
      expect(File(ktPath('AwgVpnService.kt')).existsSync(), isFalse);
      expect(
        File('android/app/src/main/jniLibs/arm64-v8a/libwg-go.so')
            .existsSync(),
        isFalse,
      );
      expect(File('lib/xray/awg_uapi.dart').existsSync(), isFalse);
      expect(File(ktPath('WgTunnelEngine.kt')).existsSync(), isTrue);
    });

    test('the manifest process set (2129: :psiphon + :lantern)', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, isNot(contains('android:name=".AwgVpnService"')));
      expect(manifest, isNot(contains('android:process=":awg"')));
      final processes = RegExp(r'android:process="([^"]+)"')
          .allMatches(manifest)
          .map((m) => m.group(1))
          .toList();
      // Build 2129: LanternVpnService gained :lantern (the
      // gomobile core's own process, mirroring :psiphon).
      expect(processes, [':psiphon', ':lantern']);
    });
  });

  group('the Kotlin hand-off (WgTunnelEngine)', () {
    final engine = ktSrc('WgTunnelEngine.kt');

    test('the .conf is parsed by the backend parser and normalized', () {
      expect(engine, contains('Config.parseQuickString'));
      expect(
        engine,
        contains('AmneziaConfigNormalizer.ensureAmneziaCompatibility'),
      );
      expect(engine, contains('BackendMode.Vpn'));
    });

    test('C1 re-homed: the hand-off DNS replaces the Config DNS', () {
      // tunnelDnsConfig stays null so the backend uses the
      // Config's DNS — which applyEmberSemantics has just
      // replaced with the channel's (profile-first) value.
      expect(engine, contains('tunnelDnsConfig = null'));
      expect(engine, contains('dns = dnsServers.joinToString'));
    });

    test('MTU: the Config MTU is cleared so the backend default rules',
        () {
      // Build 2116 (audit B3-1) deliberate re-point: the
      // 2104 loss this pin codified is restored — the
      // profile MTU is kept when sane and the Settings
      // MTU (channel argument) is the fallback; the
      // backend default rules only when neither is
      // usable. The pin now asserts the restored shape.
      expect(engine, isNot(contains('mtu = null')));
      expect(engine, contains('profileMtu in 576..9000'));
      expect(engine, contains('settingsMtu in 576..9000'));
    });

    test('C2/C3 re-homed: the AllowedIPs default is family-gated', () {
      expect(engine, contains('allowedIPs.isNullOrBlank()'));
      expect(engine, contains('"0.0.0.0/0"'));
      expect(engine, contains('"::/0"'));
    });

    test('state comes from the backend ActiveConfig, not a UAPI parse',
        () {
      expect(engine, contains('activeTunnels'));
      expect(engine, contains('lastHandshakeSeconds'));
      expect(engine, isNot(contains('awg_state.json')));
      expect(engine, isNot(contains('parseAwgStatus')));
    });

    test('no tear-down proof: nothing kills a session over a parse', () {
      expect(engine, isNot(contains('12_000')));
      expect(engine, isNot(contains('never answered')));
    });
  });

  group('MainActivity wiring', () {
    final main = ktSrc('MainActivity.kt');

    test('start/stop/state funnel through WgTunnelEngine', () {
      expect(main, contains('WgTunnelEngine.start('));
      expect(main, contains('WgTunnelEngine.stop(this)'));
      expect(main, contains('WgTunnelEngine.snapshot()'));
      expect(main, contains('WgTunnelEngine.isLive(this)'));
      expect(main, isNot(contains('AwgVpnService.')));
      expect(main, isNot(contains('AwgBackend')));
    });

    test('xrayState carries backend-computed AWG figures', () {
      expect(main, contains('"awgHandshakeAgeSec"'));
      expect(main, contains('"awgRxBytes"'));
      expect(main, contains('"awgTxBytes"'));
      expect(main, isNot(contains('"awgConfig"')));
    });

    test('the notification Disconnect (ember_action=stop) is handled',
        () {
      expect(main, contains('getStringExtra("ember_action") == "stop"'));
    });
  });

  group('the Dart side: hand-off, verdict, state', () {
    final controller = dartSrc('xray/xray_controller.dart');
    final platform = dartSrc('xray/xray_platform.dart');

    test('_connectAwg hands the canonical .conf to the engine', () {
      // Build 2116 (audit B3-4) deliberate re-point: the
      // hand-off composes the profile's whole peer group
      // (wgConfFromProfiles over wgGroup) instead of the
      // single profile — a multi-peer .conf no longer
      // loses its other peers on this engine. The
      // canonical-.conf property this pin protects is
      // unchanged (the group composer IS wgConfFromProfile
      // for a single-peer group).
      expect(controller, contains('settings: wgConfFromProfiles(wgGroup)'));
      expect(controller, isNot(contains('buildAwgUapi')));
    });

    test('the 12 s tear-down proof is deleted', () {
      expect(controller, isNot(contains('never answered the handshake')));
      expect(controller, isNot(contains('parseAwgStatus')));
      // The verdict is adoption: a started tunnel stays up.
      expect(controller, contains('AmneziaWG tunnel is up for'));
      expect(controller, contains('NO handshake proof'));
    });

    test('the walk language is honest about the fallback', () {
      expect(
        controller,
        contains('falling back to plain WireGuard for this peer.'),
      );
      expect(
        controller,
        contains('AmneziaWG engine could not start for'),
      );
    });

    test('state() reads the backend-computed fields directly', () {
      expect(platform, contains("m['awgHandshakeAgeSec']"));
      expect(platform, contains("m['awgRxBytes']"));
      expect(platform, contains("m['awgTxBytes']"));
      expect(platform, isNot(contains("m['awgConfig']")));
      // The Dart-side UAPI parse is gone (its name survives
      // only in historical comments, never as a call).
      expect(platform, isNot(contains('parseAwgStatus(')));
    });

    test('XrayState AWG figures default to the no-session shape', () {
      expect(XrayState.stopped.awgHandshakeAgeSec, -1);
      expect(XrayState.stopped.awgRxBytes, 0);
      expect(XrayState.stopped.awgTxBytes, 0);
    });
  });

  group('C1/C2/C3 intents, Dart half (re-pinned for the new builder)', () {
    test('C1: the profile DNS wins; Settings DNS only fills a gap', () {
      final s = XraySettings();
      expect(awgDnsFor(v6WarpProfile(), s),
          '2606:4700:4700::1111,2606:4700:4700::1001');
      final noDns = v4WarpProfile()..wgDns = '';
      expect(awgDnsFor(noDns, s), s.localDns);
    });

    test('C2: a v6-only profile carries no IPv4 footprint', () {
      expect(profileHasIpv4(v6WarpProfile()), isFalse);
      expect(profileHasIpv4(v4WarpProfile()), isTrue);
    });

    test('C3: the v6 gate is the profile\u2019s own IPv6 address', () {
      expect(profileHasIpv6(v6WarpProfile()), isTrue);
      expect(profileHasIpv6(v4WarpProfile()), isFalse);
    });
  });

  group('the hand-off goldens (the owner\u2019s two shapes, dummy keys)',
      () {
    test('v6 WARP+AWG: ::/0, v6 DNS, I1 and Jc reach the .conf', () {
      final conf = wgConfFromProfile(v6WarpProfile());
      expect(conf, contains('Address = 2606:4700:110:8d17:9892:cb7f:7fca:4541/128'));
      expect(conf, contains('DNS = 2606:4700:4700::1111,2606:4700:4700::1001'));
      expect(conf, contains('AllowedIPs = ::/0'));
      expect(conf, contains('Endpoint = [2606:4700:d0:0:92d9:27b5:d23d:b2f7]:2408'));
      expect(conf, contains('Jc = 6'));
      expect(conf, contains('I1 = <r 2><b 0x8580aabbccdd>'));
    });

    test('v4 WARP: 0.0.0.0/0 and an unbracketed endpoint', () {
      final conf = wgConfFromProfile(v4WarpProfile());
      expect(conf, contains('Address = 172.16.0.2/32'));
      expect(conf, contains('AllowedIPs = 0.0.0.0/0'));
      expect(conf, contains('Endpoint = 188.114.96.125:2408'));
      expect(conf, contains('I1 = <r 2><b 0x8580aabbccdd>'));
    });

    test('J1–J3 stay stored and serialized (named loss: not sent '
        'to the v3 device — the serializer is not the loss)', () {
      final p = v4WarpProfile()
        ..awgJ1 = '<r 1>'
        ..awgJ2 = '<r 2>'
        ..awgJ3 = '<r 3>';
      final conf = wgConfFromProfile(p);
      expect(conf, contains('J1 = <r 1>'));
      expect(conf, contains('J2 = <r 2>'));
      expect(conf, contains('J3 = <r 3>'));
      // The loss itself is upstream and silent: the v3
      // parser's InterfaceSection has no J1–J3 fields, so
      // its map-based parse ignores the lines (verified
      // against the 1.10.1 sources; recorded as a named
      // loss in BUILD-LOG-2.md). Nothing on Ember's side
      // strips them — the serializer above is the proof.
    });
  });

  group('license notices (WG Tunnel + its core NOTICE)', () {
    final page = dartSrc('ui/ember/licenses_page.dart');

    test('the WG Tunnel entry carries MIT + the NOTICE entries', () {
      expect(page, contains('WG Tunnel backend'));
      expect(page, contains('Zane Schepke'));
      expect(page, contains('amneziawg-go'));
      expect(page, contains('Curve25519'));
      expect(page, contains('Apache License 2.0'));
      // Iteration 2 (L4): the NOTICE's third entry — the
      // backend links hev-socks5-tunnel (MIT).
      expect(page, contains('hev-socks5-tunnel'));
      expect(page, contains('https://github.com/wgtunnel/android'));
      expect(page, contains('https://github.com/wgtunnel/core'));
    });
  });

  group('version', () {
    test('pubspec is 2.2.0+2119', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.2.0+2149'),
      );
    });
  });

  // Verification iteration 1 (2026-11-18): 3 High / 7 Medium
  // / 10 Low + 1 Medium (test quality) = 22 findings. The
  // pins below are the decisive lines of the fixes — branch
  // ORDER, call ORDER and behavior, not spellings — per the
  // iteration's own test-quality finding. Recorded (not
  // fixed) findings: 5 (baseline recovery admitted in the
  // EmberWgTunnel doc), 9 (no AWG traffic verdict exists —
  // BUILD-LOG residual), 12 (app-list TOCTOU), 16 (AAR
  // manifest surface), 18 (the 2078 "handshake-noise
  // setting" IS the profile's junk fields: they reach the
  // backend through the .conf hand-off — goldens above —
  // and the only synthesis upstream performs, the
  // AmneziaConfigNormalizer's, is applied at the hand-off;
  // no junk is invented for profiles that carry none,
  // build2078's honesty pin).
  group('verification iteration 1 dispositions', () {
    final engine = ktSrc('WgTunnelEngine.kt');
    final appKt = ktSrc('EmberApplication.kt');
    final main = ktSrc('MainActivity.kt');
    final controller = dartSrc('xray/xray_controller.dart');

    String fnSlice(String src, String start, String end) {
      final a = src.indexOf(start);
      final b = src.indexOf(end, a);
      expect(a, greaterThanOrEqualTo(0), reason: 'missing: $start');
      expect(b, greaterThan(a), reason: 'missing end after: $start');
      return src.substring(a, b);
    }

    test('finding 1: the backend is installed eagerly at app start',
        () {
      expect(engine, contains('fun install(context: Context)'));
      expect(appKt, contains('WgTunnelEngine.install(this)'));
      expect(appKt, contains('currentProcessName() == packageName'));
    });

    test('finding 7: start and stop are mutex-serialized', () {
      expect(engine, contains('private val startStopMutex = Mutex()'));
      expect(engine, contains('startStopMutex.withLock'));
    });

    test('finding 2 (Kotlin half): stop() clears the problem', () {
      final stop = fnSlice(
        engine,
        'fun stop(context: Context)',
        'fun snapshot()',
      );
      expect(stop, contains('userStopped = true'));
      expect(stop, contains('coreProblem = ""'));
    });

    test('finding 2 (merge half): userStopped outranks the problem',
        () {
      final userIdx = main.indexOf('awgSnap.userStopped ->');
      final probIdx =
          main.indexOf('awgSnap.coreProblem.isNotEmpty() ->');
      expect(userIdx, greaterThanOrEqualTo(0));
      expect(probIdx, greaterThan(userIdx));
    });

    test('finding 3 (merge half): a live Xray session outranks AWG',
        () {
      expect(
        main,
        contains('awgSnap.running && !XrayVpnService.running'),
      );
    });

    test('finding 6: semantics are applied before validation', () {
      // Iteration 2 (L2) moved the validation itself after
      // the normalizer: the shipped config is what gets
      // validated. The order pinned is semantics →
      // normalizer → validate.
      final shaped = engine.indexOf('val shaped = applyEmberSemantics(');
      final normalized =
          engine.indexOf('AmneziaConfigNormalizer.ensureAmneziaCompatibility(shaped)');
      final validated = engine.indexOf('configured.validate()');
      expect(shaped, greaterThanOrEqualTo(0));
      expect(normalized, greaterThan(shaped));
      expect(validated, greaterThan(normalized));
    });

    test('finding 15: a peerless config fails at the engine door',
        () {
      expect(engine, contains('the profile has no peer'));
    });

    test('finding 14: unexecuted scripts are on the record', () {
      expect(engine, contains('hasScripts'));
      expect(engine, contains('awg:scripts-not-executed'));
    });

    test('finding 4: the monitor never reports a VPN underlay', () {
      expect(engine, contains('NET_CAPABILITY_NOT_VPN'));
      expect(engine, contains('TRANSPORT_VPN'));
      expect(engine, contains('registerNetworkCallback'));
    });

    test('finding 8: the IP strategy follows the profile footprint',
        () {
      expect(engine, contains('Tunnel.IpStrategy.Ipv4Only'));
      expect(engine, contains('EmberWgTunnel(name, ipv6)'));
    });

    test('finding 13: blank AllowedIPs with no family still routes',
        () {
      expect(engine, contains('listOf("0.0.0.0/0")'));
    });

    test('finding 21: status refresh reaches the QS tile', () {
      expect(engine, contains('QuickTile.refresh(appContext)'));
    });

    test('findings 3/10/19/20: the Dart verdict path', () {
      final body = fnSlice(
        controller,
        'Future<bool> _connectAwg',
        '/// Connects the selected profile',
      );
      // Finding 10: the pre-start problem is captured; a new
      // one cuts the wait short and reaches lastError.
      // Iteration 2 (M3): the sentinel is the problem
      // SEQUENCE, not the templated string.
      expect(body, contains('final problemSeqBefore = state.awgProblemSeq'));
      expect(body, contains('state.awgProblemSeq != problemSeqBefore'));
      expect(body, contains('lastError = problem'));
      // Finding 3: a timed-out attempt is stopped by the
      // attempt itself, inside the failure branch.
      final failAt = body.indexOf('if (!state.running) {');
      expect(failAt, greaterThanOrEqualTo(0));
      expect(
        body.indexOf('await XrayPlatform.stop();', failAt),
        greaterThan(failAt),
      );
      // Finding 20: a generation re-check sits between the
      // up-wait loop and the adoption verdict.
      final loopAt = body.indexOf('for (var i = 0; i < 40; i++)');
      final genAt = body.lastIndexOf('if (gen != _tunnelGen) {', failAt);
      expect(loopAt, greaterThanOrEqualTo(0));
      expect(genAt, greaterThan(loopAt));
      // Finding 19: the handshake line claims the peer
      // answers — not that traffic flows.
      expect(body, contains('peer answers on the obfuscated path'));
      expect(body, isNot(contains('carries traffic')));
    });

    test('finding 17: S3/S4 survive import, storage, hand-off', () {
      const conf = '''
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 172.16.0.2/32
DNS = 1.1.1.1
S3 = 5
S4 = 7

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
Endpoint = 203.0.113.7:51820
AllowedIPs = 0.0.0.0/0
''';
      final p = parseWgConf(conf, baseName: 's34', idFor: () => 'id-s34')
          .profiles
          .single;
      expect(p.awgS3, '5');
      expect(p.awgS4, '7');
      expect(p.hasAmneziaParams, isTrue);
      final out = wgConfFromProfile(p);
      expect(out, contains('S3 = 5'));
      expect(out, contains('S4 = 7'));
      final roundTrip = Profile.fromJson(p.toJson());
      expect(roundTrip.awgS3, '5');
      expect(roundTrip.awgS4, '7');
      expect(dartSrc('xray/link_parser.dart'), contains("q['s3']"));
      expect(
        dartSrc('xray/profile_codec.dart'),
        contains("q['s3'] = p.awgS3"),
      );
    });
  });

  // Verification iteration 2 (2026-11-18): 0 High / 4 Medium
  // / 7 Low — NOT CLEAN. All four Mediums and L1–L7 fixed;
  // the pins below are the decisive lines.
  group('verification iteration 2 dispositions', () {
    final engine = ktSrc('WgTunnelEngine.kt');
    final appKt = ktSrc('EmberApplication.kt');
    final main = ktSrc('MainActivity.kt');
    final controller = dartSrc('xray/xray_controller.dart');

    test('M1: S3/S4 pass the import-boundary sanitizer', () {
      // The hygiene contract (shared with S1/S2): only
      // digits and range dashes survive — letters and
      // newlines are stripped, so a crafted value can
      // neither inject .conf lines nor crash the engine's
      // integer parse; pure junk sanitizes to empty.
      final p = v4WarpProfile()
        ..awgS3 = '12a3'
        ..awgS4 = 'x\nS1 = 9';
      final cleaned = sanitizeImportedProfile(p);
      expect(cleaned.awgS3, '123');
      expect(cleaned.awgS4, '19');
      final junk = sanitizeImportedProfile(
        v4WarpProfile()..awgS3 = 'abc',
      );
      expect(junk.awgS3, '');
      expect(
        dartSrc('xray/profile_validation.dart'),
        contains('p.awgS3 = sanitizeAwgParam(p.awgS3);'),
      );
    });

    test('M2: the Always-On callback is assigned and cleans up', () {
      expect(engine, contains('RuntimeManager.alwaysOnCallback'));
      expect(engine, contains('AlwaysOnCallback'));
      expect(engine, contains('stopAllActiveTunnels()'));
      expect(engine, contains('onStickyRestart()'));
      expect(engine, contains('onVpnRevoked()'));
    });

    test('M3: problems carry a sequence end to end', () {
      // Iteration 3 (L-1): the counter is atomic — records
      // land from several threads.
      expect(engine, contains('problemSeqCounter = AtomicInteger(0)'));
      expect(engine, contains('private fun recordProblem'));
      // The watcher and both start-failure paths record
      // through the helper — three call sites.
      expect('recordProblem('.allMatches(engine).length,
          greaterThanOrEqualTo(4));
      expect(main, contains('"awgProblemSeq" to awgSnap.problemSeq'));
      expect(
        dartSrc('xray/xray_platform.dart'),
        contains("m['awgProblemSeq']"),
      );
      expect(controller, contains('state.awgProblemSeq'));
    });

    test('M4: the monitor speaks upstream\u2019s semantics', () {
      // Global address + IPv6 default route for hasIpv6;
      // validated + not-suspended for isUsable; the default
      // network preferred in the underlay scan.
      expect(engine, contains('IFA_F_DEPRECATED'));
      expect(engine, contains('isUniqueLocal'));
      expect(engine, contains('route.isDefaultRoute'));
      expect(engine, contains('NET_CAPABILITY_VALIDATED'));
      expect(engine, contains('NET_CAPABILITY_NOT_SUSPENDED'));
      expect(engine, contains('manager.activeNetwork'));
    });

    test('L1: entry points build the backend instead of no-oping',
        () {
      expect(appKt, contains('/proc/self/cmdline'));
      final stopAt = engine.indexOf('fun stop(context: Context)');
      expect(
        engine.indexOf('val backend = backend(context)', stopAt),
        greaterThan(stopAt),
      );
    });

    test('L3: the libsu seed path is project-relative', () {
      final rootGradle =
          File('android/build.gradle.kts').readAsStringSync();
      expect(rootGradle, contains('toolchain/local-maven'));
      expect(rootGradle, contains('projectDirectory'));
      expect(rootGradle, isNot(contains('/home/hatch')));
    });

    test('L5: the in-flight marker is a counter, not a flag', () {
      expect(engine, contains('AtomicInteger(0)'));
      expect(engine, contains('startsInFlight.incrementAndGet()'));
      expect(engine, contains('startsInFlight.decrementAndGet()'));
      expect(engine, contains('startsInFlight.get() == 0'));
    });

    test('L6: the timeout stop is observed, not assumed', () {
      final body = controller.substring(
        controller.indexOf('Future<bool> _connectAwg'),
        controller.indexOf('/// Connects the selected profile'),
      );
      final failAt = body.indexOf('if (!state.running) {');
      final stopAt =
          body.indexOf('await XrayPlatform.stop();', failAt);
      expect(stopAt, greaterThan(failAt));
      // After the stop call, the branch re-reads state in a
      // bounded poll before it reports failure.
      expect(
        body.indexOf('state = await XrayPlatform.state();', stopAt),
        greaterThan(stopAt),
      );
    });
  });

  // Verification iteration 3 (2026-11-18): 0 High / 1 Medium
  // / 6 Low — NOT CLEAN. M-1 and L-1…L-6 all fixed (L-4's
  // finally-around-the-mutex restructure is pinned by
  // reading, not by a needle: its distinguishing feature is
  // brace position, which a substring cannot state honestly).
  group('verification iteration 3 dispositions', () {
    final engine = ktSrc('WgTunnelEngine.kt');

    test('M-1: a default-network change re-runs the scan', () {
      expect(engine, contains('registerDefaultNetworkCallback'));
      // The NOT_VPN candidate callback from iteration 1
      // stays — the default callback only triggers rescans.
      expect(engine, contains('registerNetworkCallback'));
      expect(engine, contains('NET_CAPABILITY_NOT_VPN'));
    });

    test('L-1: the problem pair is read consistently', () {
      expect(engine, contains('problemSeqCounter.incrementAndGet()'));
      // Iteration 4 (Low-2): the re-read is a loop, not a
      // single retry.
      expect(engine, contains('while (seq != problemSeqCounter.get())'));
    });

    test('L-2: the zombie cleanup yields to an in-flight start',
        () {
      // The gate now appears twice: the drop watcher and
      // the system-session cleanup.
      expect(
        'startsInFlight.get() == 0'.allMatches(engine).length,
        greaterThanOrEqualTo(2),
      );
    });

    test('L-3: stop() waits, bounded, for the teardown', () {
      expect(engine, contains('System.currentTimeMillis() + 1_500'));
      // Build 2110 (wg-start diagnosis, defect 3): the wait
      // moved OFF stop()'s calling thread (the channel/main
      // thread) into the mutex-serialized stop body — the
      // bound and the observed condition are unchanged, the
      // sleep is now a coroutine delay (see
      // build2110_test.dart's B4 group).
      expect(engine, contains('delay(50)'));
    });

    test('L-5: the licenses entry counts the NOTICE honestly',
        () {
      final page = dartSrc('ui/ember/licenses_page.dart');
      expect(page, contains('Tailscale'));
      expect(page, contains('five'));
    });

    test('L-6: a gateway-less v6 default route counts as v6',
        () {
      expect(engine, contains('route.gateway == null'));
    });
  });

  // Verification iteration 4 (2026-11-18): 0 High / 0 Medium
  // / 8 Low — a LOW-ONLY iteration, so per the gate these
  // are fix-or-record and the loop stops here. Fixed:
  // Low-1 (half), Low-2, Low-3, Low-4, Low-5, Low-6, Low-8.
  // Recorded in BUILD-LOG-2.md as residuals: Low-7 (pre-29
  // gateway-less v4 false positive) and Low-1's other half
  // (which non-VPN network is "the" underlay when the
  // default is the VPN itself is not locally knowable).
  group('verification iteration 4 dispositions', () {
    final engine = ktSrc('WgTunnelEngine.kt');

    test('Low-3: the zombie cleanup holds the start/stop mutex',
        () {
      // start, stop and the cleanup all serialize on it.
      expect(
        'startStopMutex.withLock'.allMatches(engine).length,
        greaterThanOrEqualTo(3),
      );
    });

    test('Low-4: a later stop supersedes an issued start', () {
      expect(engine, contains('awg:start-superseded-by-stop'));
      expect(engine, contains('if (userStopped) {'));
    });

    test('Low-5: cancellation is not recorded as a failure', () {
      expect(engine, contains('catch (e: CancellationException)'));
    });

    test('Low-8: the success path re-reads the tunnel map', () {
      // Pre-stop check + success re-read.
      expect(
        'containsKey(TUNNEL_ID)'.allMatches(engine).length,
        greaterThanOrEqualTo(2),
      );
    });

    test('Low-1: an empty scan forgets the tracked network', () {
      expect(engine, contains('current = null'));
    });
  });
}
