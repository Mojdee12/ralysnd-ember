// Build 2106 — fix build for the 2105 journey audit
// (journey-audit-2105.md). Pins for F-01..F-09:
//  F-01 the AWG adoption proof's verdict + walk wiring
//  F-02 the stall watchdog stands down for AWG sessions
//  F-03 notification Switch-server anchors to the session
//  F-04 provider-DNS outcomes are journaled; all bootstrap
//       addresses are tried
//  F-05 J1–J3 no longer route or label as AmneziaWG
//  F-06 the clipboard link import is guarded (== 2101-L1)
//  F-07 traffic history clamps negative deltas at record()
//  F-08 the battery read catches Errors, not only Exceptions
//  F-09 an unresolved package build offers no update

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/ui/ember/battery_report.dart';
import 'package:firefox_vpn/ui/ember/ember_updater.dart';
import 'package:firefox_vpn/xray/fallback_groups.dart';
import 'package:firefox_vpn/xray/traffic_history.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

String _src(String rel) => File('lib/$rel').readAsStringSync();

/// The segment of [source] from [start] to the next [end]
/// marker (or EOF) — the shape the tree's source pins use to
/// scope a claim to one function.
String _segment(String source, String start, [String? end]) {
  final at = source.indexOf(start);
  expect(at, isNonNegative, reason: 'marker not found: $start');
  final rest = source.substring(at);
  if (end == null) return rest;
  final cut = rest.indexOf(end, start.length);
  return cut < 0 ? rest : rest.substring(0, cut);
}

XrayState _awgState({bool running = true, int age = -1, int rx = 0}) =>
    XrayState(
      running: running,
      name: 't',
      sinceMs: 0,
      upBytes: 0,
      downBytes: 0,
      awg: true,
      awgHandshakeAgeSec: age,
      awgRxBytes: rx,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('F-01 — the AWG adoption proof verdict', () {
    test('a completed handshake proves the peer answered', () {
      expect(XrayController.awgPeerCarries(_awgState(age: 3)), isTrue);
      expect(XrayController.awgPeerCarries(_awgState(age: 0)), isTrue);
    });

    test('received bytes prove it even before an age reads', () {
      expect(XrayController.awgPeerCarries(_awgState(rx: 148)), isTrue);
    });

    test('silence does not prove: no handshake, no bytes', () {
      expect(XrayController.awgPeerCarries(_awgState()), isFalse);
    });

    test('a stopped or non-AWG sample never proves', () {
      expect(
        XrayController.awgPeerCarries(_awgState(running: false, age: 3)),
        isFalse,
      );
      const xray = XrayState(
        running: true,
        name: 't',
        sinceMs: 0,
        upBytes: 0,
        downBytes: 0,
        awgHandshakeAgeSec: 3,
        awgRxBytes: 500,
      );
      expect(XrayController.awgPeerCarries(xray), isFalse);
    });

    test('the walk runs the proof and falls back on silence (pin)', () {
      final controller = _src('xray/xray_controller.dart');
      final walk = _segment(
        controller,
        'Future<void> connectWireGuardWithFallback',
        'Future<bool> _connectAwg',
      );
      expect(walk, contains('await _awgAdoptionProof()'));
      expect(
        walk,
        contains('The AmneziaWG peer for \${candidate.name} has '),
      );
      expect(walk, contains('awgFailureWasSilence = !_awgProofDied'));
      // The proof-failure stop is a walk step, not a session
      // end — the deferred chain exit survives it.
      expect(walk, contains('await disconnect(consumeChainExit: false)'));
    });

    test('_connectAwg itself still has NO gate (pin)', () {
      final controller = _src('xray/xray_controller.dart');
      final connect = _segment(
        controller,
        'Future<bool> _connectAwg',
        'Future<bool> switchServer',
      );
      expect(connect, contains('NO handshake proof, and no tear-down'));
    });

    test('a notification stop reads as superseded, never silence (pin)', () {
      // Verification iteration 1, H1: the proof must consult
      // userStopped (the native stop's only Dart-visible
      // trace) and re-check the generation after the awaited
      // refresh, before believing the sample.
      final controller = _src('xray/xray_controller.dart');
      final proof = _segment(
        controller,
        'Future<bool?> _awgAdoptionProof',
        'Future<bool> _connectAwg',
      );
      expect(proof, contains('if (state.userStopped) return null;'));
      expect(proof, contains('await refreshState();'));
      final afterRefresh = proof.substring(proof.indexOf('await refreshState();'));
      expect(afterRefresh, contains('if (gen != _tunnelGen) return null;'));
      // Ordering (verification iteration 2, L-3): the user
      // stop is consulted BEFORE the running check, or a
      // stopped session would read as silence.
      expect(
        proof.indexOf('if (state.userStopped) return null;'),
        lessThan(proof.indexOf('if (!state.running)')),
      );
      // The exit lookup is not a proof signal (L2).
      expect(proof, isNot(contains('exitInfo')));
    });

    test('a notification stop inside the walk\u2019s own teardown '
        'ends the walk (pin)', () {
      // Verification iteration 2, M-1: the walk snapshots
      // the engine's notification-stop sequence before its
      // teardown stop and re-reads it after — userStopped
      // cannot serve (the native funnel marks every stop).
      final controller = _src('xray/xray_controller.dart');
      // Scoped to the walk, in order (verification
      // iteration 3, Low-1): snapshot BEFORE the teardown
      // stop, comparison AFTER it — a whole-file contains
      // would stay green if the snapshot moved.
      final walk = _segment(
        controller,
        'Future<void> connectWireGuardWithFallback',
        'Future<bool> _connectAwg',
      );
      final snapAt = walk.indexOf('final userStopSeqBefore = state.awgUserStopSeq;');
      final stopAt = walk.indexOf('await disconnect(consumeChainExit: false)');
      final checkAt = walk.indexOf('state.awgUserStopSeq != userStopSeqBefore');
      expect(snapAt, greaterThanOrEqualTo(0));
      expect(stopAt, greaterThan(snapAt));
      expect(checkAt, greaterThan(stopAt));
      final platform = _src('xray/xray_platform.dart');
      expect(platform, contains("m['awgUserStopSeq']"));
      // The Kotlin wiring: only the two notification entry
      // points advance the sequence.
      final engine = File(
        'android/app/src/main/kotlin/com/ralysnd/ember/WgTunnelEngine.kt',
      ).readAsStringSync();
      expect(engine, contains('fun stopFromNotification'));
      expect(engine, contains('userStopSeqCounter.incrementAndGet()'));
      final activity = File(
        'android/app/src/main/kotlin/com/ralysnd/ember/MainActivity.kt',
      ).readAsStringSync();
      expect(
        'WgTunnelEngine.stopFromNotification(this)'.allMatches(activity).length,
        2,
      );
      expect(activity, contains('"awgUserStopSeq" to awgSnap.userStopSeq'));
      // The STOPPED branch specifically — the one the walk
      // re-reads after its stop. Its map entry is split
      // across lines in the source, so match on
      // whitespace-normalized text (iteration 3, Low-1).
      final stoppedBranch = _segment(
        activity,
        'awgSnap.userStopped ->',
        'awgSnap.coreProblem.isNotEmpty() ->',
      ).replaceAll(RegExp(r'\s+'), ' ');
      expect(stoppedBranch, contains('"awgUserStopSeq" to awgSnap.userStopSeq'));
    });
  });

  group('F-02 — the stall watchdog stands down for AWG', () {
    test('no SOCKS probe and no rotate on an AWG stall', () async {
      var probeCalls = 0;
      var rotateCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'), (
            call,
          ) async {
            switch (call.method) {
              case 'xrayTunnelCheck':
                probeCalls++;
                return -1;
              case 'xrayRotateConfig':
                rotateCalls++;
                return true;
              default:
                return null;
            }
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('app/android'), null);
      });

      final c = XrayController();
      c.awgSession = true;
      // Build 2114: the watchdog defaults OFF now (defaults
      // reset) — the AWG stand-down must be proven against a
      // LIVE watchdog, so the setup turns it ON explicitly.
      c.settings.stallWatchdog = true;
      XrayState sample(int up, int down) => XrayState(
        running: true,
        name: 't',
        sinceMs: DateTime.now().millisecondsSinceEpoch - 60000,
        upBytes: up,
        downBytes: down,
        awg: true,
      );
      // The freeze signature, three ticks over the stall
      // window: uplink advancing, downlink flat. On builds
      // ≤2105 the second failed probe escalated to a rotate
      // the native side refuses for AWG.
      await c.testWatchdogTick(sample(100, 100));
      await Future<void>.delayed(const Duration(milliseconds: 6200));
      await c.testWatchdogTick(sample(200, 100));
      await c.testWatchdogTick(sample(300, 100));
      expect(probeCalls, 0, reason: 'an AWG session has no SOCKS port');
      expect(rotateCalls, 0, reason: 'nothing may claim a core restart');
    });

    test('the AWG guard precedes the probe in _watchdogTick (pin)', () {
      final controller = _src('xray/xray_controller.dart');
      final tick = _segment(
        controller,
        'Future<void> _watchdogTick',
        'Future<void> _escalateShape',
      );
      final guardAt = tick.indexOf('if (awgSession) return;');
      final probeAt = tick.indexOf('XrayPlatform.tunnelCheck');
      expect(guardAt, isNonNegative);
      expect(probeAt, isNonNegative);
      expect(guardAt, lessThan(probeAt));
    });
  });

  group('F-03 — notification rotate anchors to the session', () {
    test('the handler keys off sessionProfile + the WG peer group (pin)', () {
      final shell = _src('ui/ember/ember_shell.dart');
      final handler = _segment(
        shell,
        'Future<void> _notificationRotateInner',
        'Future<void> _importDeepLink',
      );
      expect(handler, contains('final current = _xray.sessionProfile'));
      expect(handler, contains('nextWgPeer(_xray.profiles, current)'));
      expect(handler, isNot(contains('final current = _xray.selected')));
      // A session with no profile of its own gets feedback,
      // not a silent no-op (verification L4).
      expect(handler, contains('not available for this session'));
    });

    Profile wgPeer(String id, String key, String addr) => Profile(
      id: id,
      protocol: Protocol.wireguard,
      name: id,
      address: '203.0.113.7',
      port: 51820,
      secretKey: key,
      peerPublicKey: 'p-$id',
      localAddress: addr,
    );

    test('nextWgPeer walks the group cyclically, never oscillates', () {
      // One imported .conf = one interface (key + address)
      // with three peers; an unrelated WG profile and a
      // V2Ray profile share the list.
      final a = wgPeer('a', 'k1', '10.0.0.2/32');
      final b = wgPeer('b', 'k1', '10.0.0.2/32');
      final c = wgPeer('c', 'k1', '10.0.0.2/32');
      final other = wgPeer('x', 'k2', '10.0.0.9/32');
      final v = Profile(
        id: 'v',
        protocol: Protocol.vless,
        name: 'v',
        address: 'a.example.com',
        port: 443,
      );
      final all = [a, b, c, other, v];
      expect(wgPeerGroupOf(all, a).map((p) => p.id), ['a', 'b', 'c']);
      expect(nextWgPeer(all, a)?.id, 'b');
      expect(nextWgPeer(all, b)?.id, 'c');
      expect(nextWgPeer(all, c)?.id, 'a'); // wraps, no A↔B trap
      expect(nextWgPeer(all, other), isNull); // alone in its group
    });
  });

  group('F-04 — provider DNS is no longer silent', () {
    test('every applicable outcome is journaled (pin)', () {
      final controller = _src('xray/xray_controller.dart');
      final pins = _segment(
        controller,
        'Future<Map<String, List<String>>> _providerDnsPins',
        'List<Profile> get looseProfiles',
      );
      expect(pins, contains('carries no DNS'));
      expect(pins, contains('returned nothing — connecting without a pin'));
      expect(pins, contains('Provider DNS pinned'));
      expect(pins, contains('providerDnsNotice ='));
    });

    test('the UDP bootstrap tries every resolved address (pin)', () {
      final dns = _src('xray/provider_dns.dart');
      // Build 2116 (B13-5, 2106-L5): deliberate re-point —
      // the walk is index-based now because each target owns
      // a bounded share of the one deadline (a silent first
      // target used to eat the whole budget). Every resolved
      // address is still tried in turn; the share accounting
      // is pinned alongside.
      expect(dns, contains('for (var i = 0; i < addresses.length; i++)'));
      expect(dns, contains('before ~/ remaining'));
      expect(dns, contains('_queryUdpTarget'));
      expect(dns, isNot(contains('final target = addresses.first;')));
    });

    test('the home card renders the pin notice (pin)', () {
      final home = _src('ui/ember/ember_home.dart');
      expect(home, contains('xray.providerDnsNotice.isNotEmpty'));
    });

    test('the adopted-session recompute is latched (pin)', () {
      // Verification iteration 1, M1: without the latch a
      // failed recompute re-ran (and re-journaled) on every
      // refreshState for the life of the session.
      final controller = _src('xray/xray_controller.dart');
      expect(controller, contains('_providerPinsAdoptedFor != _connectedProfileId'));
      expect(controller, contains('_providerPinsAdoptedFor = adopted.id;'));
      // The reset sites, asserted where they live
      // (verification iteration 3, Low-1: a whole-file count
      // also matches the declaration and would stay green
      // if a real site were deleted). refreshState holds
      // TWO: the feature-off release and the not-running
      // branch; _stopTunnel holds the session-end one.
      final refresh = _segment(
        controller,
        'Future<void> refreshState()',
        'Future<void> _pollStats()',
      );
      expect(
        "_providerPinsAdoptedFor = '';".allMatches(refresh).length,
        2,
      );
      final stop = _segment(
        controller,
        'Future<void> _stopTunnel()',
        'void stopTestAll()',
      );
      expect(stop, contains("_providerPinsAdoptedFor = '';"));
    });
  });

  group('F-05 — J1–J3 do not route or label as AmneziaWG', () {
    Profile wg({String jc = '', String j1 = ''}) => Profile(
      id: 'w',
      protocol: Protocol.wireguard,
      name: 'w',
      address: '203.0.113.7',
      port: 51820,
      secretKey: 'k',
      peerPublicKey: 'p',
      awgJc: jc,
      awgJ1: j1,
    );

    test('a J-only profile carries params but none supported', () {
      final p = wg(j1: '<r 2>');
      expect(p.hasAmneziaParams, isTrue); // storage/export truth
      expect(p.hasSupportedAmneziaParams, isFalse); // routing truth
      expect(p.hasUnsupportedJParams, isTrue);
    });

    test('Jc carries supported; Jc+J1 carries both truths', () {
      expect(wg(jc: '6').hasSupportedAmneziaParams, isTrue);
      expect(wg(jc: '6').hasUnsupportedJParams, isFalse);
      final both = wg(jc: '6', j1: '<r 2>');
      expect(both.hasSupportedAmneziaParams, isTrue);
      expect(both.hasUnsupportedJParams, isTrue);
      expect(wg().hasAmneziaParams, isFalse);
    });

    test('a parsed J-only .conf reads the same way', () {
      final r = parseWgConf(
        '[Interface]\n'
        'PrivateKey = aGVsbG8td29ybGQta2V5LWZvci10ZXN0aW5n\n'
        'Address = 10.0.0.2/32\n'
        '\n'
        '[Peer]\n'
        'PublicKey = aGVsbG8td29ybGQta2V5LWZvci10ZXN0aW5n\n'
        'Endpoint = 203.0.113.7:51820\n'
        'J1 = <r 2>\n',
        baseName: 'j',
        idFor: () => 'id-j',
      );
      expect(r.ok, isTrue);
      final p = r.profiles.single;
      expect(p.awgJ1, '<r 2>');
      expect(p.hasSupportedAmneziaParams, isFalse);
      expect(p.hasUnsupportedJParams, isTrue);
    });

    test('routing and labels key on the supported set (pin)', () {
      final controller = _src('xray/xray_controller.dart');
      expect(controller, contains('if (candidate.hasSupportedAmneziaParams)'));
      expect(controller, contains('candidate.hasUnsupportedJParams'));
      final pages = _src('ui/ember/wireguard_pages.dart');
      expect(pages, contains('J1–J3 not supported by this engine — ignored'));
      final settings = _src('ui/ember/ember_settings.dart');
      expect(settings, contains('wgSelected.hasSupportedAmneziaParams'));
    });

    test('the profile editor states the J exception (pin)', () {
      // Verification iteration 1, M2: the editor is where J
      // values are deliberately entered — its blanket
      // "applied by the engine" text must carry the
      // exception. Scoped to the AmneziaWG section itself
      // (verification iteration 2, L-3).
      final editor = _src('ui/ember/profile_editor.dart');
      final section = _segment(
        editor,
        "_section('AmneziaWG'",
        'if (proto == Protocol.tuic)',
      );
      expect(section, contains('J1–J3 are NOT applied'));
    });
  });

  group('F-06 — the clipboard link import is guarded', () {
    test('_importLink wraps both awaits and answers failures (pin)', () {
      final pages = _src('ui/ember/wireguard_pages.dart');
      final fn = _segment(
        pages,
        'Future<void> _importLink',
        'Future<void> _connect',
      );
      expect(fn, contains('Could not read the clipboard'));
      // TWO guarded awaits: the clipboard read and the
      // import itself.
      expect('catch (_)'.allMatches(fn).length, greaterThanOrEqualTo(2));
    });

    test('the sibling _importConf read is guarded too (pin)', () {
      // Verification iteration 1, L7.
      final pages = _src('ui/ember/wireguard_pages.dart');
      final fn = _segment(
        pages,
        'Future<void> _importConf',
        'Future<void> _importLink',
      );
      expect(fn, contains('catch (_)'));
      expect(fn, contains('Could not read the clipboard'));
    });
  });

  group('F-07 — traffic history clamps at record()', () {
    test('a negative delta never drives a bucket negative', () {
      final store = TrafficHistoryStore();
      final t = DateTime(2026, 11, 18, 10, 15).millisecondsSinceEpoch;
      store.record('p', 100, 40, t);
      store.record('p', -60, -50, t + 60000); // same hour
      store.record('p', 10, -5, t + 120000); // same hour
      final buckets = store.bucketsFor('p');
      expect(buckets, hasLength(1));
      expect(buckets.single.up, 110);
      expect(buckets.single.down, 40);
      final totals = store.totalsFor('p', 0);
      expect(totals.up, 110);
      expect(totals.down, 40);
    });
  });

  group('F-08 — the battery read never throws', () {
    void mockBattery(Object error) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'), (
            call,
          ) async {
            if (call.method == 'batteryStatus') throw error;
            return null;
          });
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'), null);
    });

    test('a channel Error is a skipped sample, not a throw', () async {
      mockBattery(StateError('codec blew up'));
      final r = await readBatteryStatus();
      expect(r.level, isNull);
    });

    test('a PlatformException is a skipped sample too', () async {
      mockBattery(PlatformException(code: 'x', message: 'no battery'));
      final r = await readBatteryStatus();
      expect(r.level, isNull);
    });
  });

  group('F-09 — an unresolved package build offers nothing', () {
    test('currentBuild is the package number or null', () {
      final u = EmberUpdater(settings: AppSettings(), dataDir: '');
      expect(u.packageBuild, isNull);
      expect(u.currentBuild, isNull);
      u.packageBuild = 2105;
      expect(u.currentBuild, 2105);
    });

    test('check() consults the comparison only when known (pin)', () {
      final updater = _src('ui/ember/ember_updater.dart');
      expect(updater, contains('final current = currentBuild;'));
      // Build 2125 SUPERSESSION (recorded, not silent):
      // A25-52 splits the unknown case into its own branch
      // BEFORE the comparison — the comparison is still
      // consulted only with a known current build.
      expect(updater, contains('EmberUpdateState.unknownBuild'));
      expect(updater, contains('parsed.isNewerThan(current)'));
      expect(
        updater,
        isNot(contains('int.tryParse(appBuildNumber)')),
      );
    });

    test('check() with an unknown build offers no update; '
        'with a known older build it does', () async {
      final dir = Directory.systemTemp.createTempSync('ember2106_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final releaseJson = jsonEncode({
        'tag_name': 'v9999',
        'name': 'Build 9999',
        'body': '',
        'prerelease': false,
        'assets': [
          {
            'name': 'RalysndEmber2.apk',
            'browser_download_url': 'https://example.com/9999.apk',
            'size': 10,
          },
        ],
      });
      final unknown = EmberUpdater(
        settings: AppSettings(),
        dataDir: dir.path,
        fetcher: (_) async => releaseJson,
      );
      addTearDown(unknown.dispose);
      await unknown.check(manual: true);
      // Build 2125 SUPERSESSION (recorded, not silent):
      // A25-52 — an unresolved build is no longer reported
      // as upToDate (a state that lied); it is unknownBuild.
      // The F-09 contract stands: no update is offered —
      // the state is not available, so the panel shows no
      // Download action for it.
      expect(unknown.state, EmberUpdateState.unknownBuild);
      expect(unknown.state, isNot(EmberUpdateState.available));
      final known = EmberUpdater(
        settings: AppSettings(),
        dataDir: dir.path,
        fetcher: (_) async => releaseJson,
      )..packageBuild = 2071;
      addTearDown(known.dispose);
      await known.check(manual: true);
      expect(known.state, EmberUpdateState.available);
    });
  });
}
