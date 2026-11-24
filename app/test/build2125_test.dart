// Build 2125 gates — the audit fix build (owner order
// 2026-11-20 19:05: «به جز ۳ همرو اصلاح کن»): every
// finding of the full audit of 2124 (register A25-01…
// A25-59) fixed EXCEPT A25-03 (the pre-tunnel hostname
// pin — the owner's decision, untouched and unpinned
// here beyond its exclusion).
//
// Dispositions pinned below: LANDED 52, PARTIAL 3
// (A25-04 kill switch: Psiphon/Lantern/OpenVPN legs
// landed, Mozilla + WG-Tunnel legs parked; A25-14:
// surfacing landed, the windows parked; A25-16:
// surfacing landed, the sing-box dns section parked),
// PARKED 3 (A25-10, A25-57, A25-59 — trust-model /
// platform reasons, recorded in build2125-progress.md).
//
// Behavioural wherever the surface allows; source-shape
// pins for the native (Kotlin) changes, which no Dart
// test can execute. What only the owner's phone can
// prove (the kill-switch holds on device, pause/stop
// behaviour, claim arbitration under contention) is NOT
// claimed here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/ui/ember/ember_sync.dart';
import 'package:firefox_vpn/ui/ember/ember_updater.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/dpi_lab.dart';
import 'package:firefox_vpn/xray/dpi_remote.dart';
import 'package:firefox_vpn/xray/shape_cache.dart';
import 'package:firefox_vpn/xray/traffic_history.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/wg_probe.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String _kt(String name) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$name')
        .readAsStringSync();

String _dart(String rel) => File('lib/$rel').readAsStringSync();

String _region(String src, String from, String to) {
  final a = src.indexOf(from);
  if (a < 0) throw StateError('region start "$from" not found');
  final b = src.indexOf(to, a);
  if (b < 0) throw StateError('region end "$to" not found');
  return src.substring(a, b);
}

Profile _wgProfile({int mtu = 1420}) {
  final p = Profile(
    id: 'wg2125',
    name: 'WG fixture',
    protocol: Protocol.wireguard,
    address: '188.114.96.125',
    port: 2408,
  );
  p.secretKey = 'YAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=';
  p.peerPublicKey = 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=';
  p.localAddress = '172.16.0.2/32';
  p.mtu = mtu;
  return p;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('A25-05/A25-42: decode integrity + caps', () {
    test('a non-finite shape entry reads as no win, never a throw', () {
      expect(
        ShapeWin.fromJson({'shape': 'z1', 'at': double.infinity, 'rtt': 10}),
        isNull,
      );
      expect(
        ShapeWin.fromJson({'shape': 'z1', 'at': 5, 'rtt': double.nan}),
        isNull,
      );
    });

    test('the shape cache decode is capped at 256, newest kept', () {
      final doc = <String, dynamic>{
        for (var i = 0; i < 300; i++)
          'p$i|net': {'shape': 'z1', 'at': 1000 + i, 'rtt': 10},
      };
      final cache = WinningShapeCache.fromJson(doc);
      expect(cache.length, WinningShapeCache.maxEntries);
      // The newest win (i = 299) survived; the oldest did not.
      expect(cache.lookup('p299', 'net', nowMs: 1000 + 299), isNotNull);
      expect(cache.lookup('p0', 'net', nowMs: 1000), isNull);
    });

    test('the result book decode is capped at 64 profiles', () {
      final candidate = dpiLabCandidates.first;
      final doc = <String, dynamic>{
        for (var i = 0; i < 70; i++)
          'prof$i': {
            candidate.id: {
              'v': DpiLabVerdict.values.first.name,
              'ms': 10,
              'cc': '',
              'p0': 1,
              'p1': 2,
              'p2': 3,
              'at': 1000 + i,
              'net': '',
            },
          },
      };
      final book = DpiLabResultBook.fromJson(doc);
      expect(book.profileCount, DpiLabResultBook.maxProfiles);
      // The book whose newest evidence is newest survives.
      expect(book.forProfile('prof69'), isNotEmpty);
      expect(book.forProfile('prof0'), isEmpty);
    });
  });

  group('A25-26: Psiphon defaults law', () {
    test('the shipped defaults are OFF', () {
      final s = PsiphonSettings();
      expect(s.cdnFronting, isFalse);
      expect(s.edgeAutoUse, isFalse);
    });

    test('a pre-2125 store with both ON is migrated OFF once', () {
      final s = PsiphonSettings.fromJson({
        'cdnFronting': true,
        'edgeAutoUse': true,
      });
      expect(s.cdnFronting, isFalse);
      expect(s.edgeAutoUse, isFalse);
      expect(s.defaultsReset2125, isTrue);
    });

    test('after the migration, the user\'s own ON choices stand', () {
      final s = PsiphonSettings.fromJson({
        'cdnFronting': true,
        'edgeAutoUse': true,
        'defaultsReset2125': true,
      });
      expect(s.cdnFronting, isTrue);
      expect(s.edgeAutoUse, isTrue);
    });
  });

  group('A25-49/A25-54: updater + feed guards (functional)', () {
    test('the update URL allowlist admits only GitHub hosts over https', () {
      expect(
        emberUpdateUrlAllowed('https://github.com/a/b.apk'),
        isTrue,
      );
      expect(
        emberUpdateUrlAllowed(
          'https://objects.githubusercontent.com/x',
        ),
        isTrue,
      );
      expect(
        emberUpdateUrlAllowed('https://release-assets.githubusercontent.com/x'),
        isTrue,
      );
      expect(emberUpdateUrlAllowed('http://github.com/a'), isFalse);
      expect(emberUpdateUrlAllowed('https://evil.com/a'), isFalse);
      expect(
        emberUpdateUrlAllowed('https://github.com.evil.com/a'),
        isFalse,
      );
      expect(
        emberUpdateUrlAllowed('https://notgithubusercontent.com/a'),
        isFalse,
      );
    });

    test('a newer-format DPI feed document is a feed failure', () {
      expect(
        () => parseDpiStrategyFeedBody(
          jsonEncode({'version': 2, 'strategies': []}),
        ),
        throwsA(isA<DpiStrategyFeedException>()),
      );
    });

    test('a DPI feed document without its strategy list fails', () {
      expect(
        () => parseDpiStrategyFeedBody(jsonEncode({'version': 1})),
        throwsA(isA<DpiStrategyFeedException>()),
      );
      expect(
        () => parseDpiStrategyFeedBody(jsonEncode(['not', 'a', 'map'])),
        throwsA(isA<DpiStrategyFeedException>()),
      );
    });

    test('a valid empty DPI feed parses to an empty list', () {
      expect(
        parseDpiStrategyFeedBody(
          jsonEncode({'version': 1, 'strategies': []}),
        ),
        isEmpty,
      );
    });
  });

  group('A25-33/A25-38: emitted configs', () {
    test('the tunnel config is compact and round-trips', () {
      final text = buildTunnelConfig(_wgProfile(), XraySettings());
      expect(text.contains('\n'), isFalse);
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      expect(decoded['outbounds'], isA<List>());
    });

    test('the test config is compact', () {
      final text = buildTestConfig(_wgProfile(), XraySettings());
      expect(text.contains('\n'), isFalse);
    });

    test('the WG outbound MTU is clamped to the TUN range', () {
      int emittedMtu(int mtu) {
        final decoded = jsonDecode(
          buildTunnelConfig(_wgProfile(mtu: mtu), XraySettings()),
        ) as Map<String, dynamic>;
        final outbounds = decoded['outbounds'] as List;
        final wg = outbounds.firstWhere(
          (o) => (o as Map)['protocol'] == 'wireguard',
        ) as Map;
        return (wg['settings'] as Map)['mtu'] as int;
      }

      expect(emittedMtu(9000), 1500);
      expect(emittedMtu(576), 1280);
      expect(emittedMtu(1420), 1420);
    });
  });

  group('A25-23/A25-44: guards + pruning (functional)', () {
    test('the plain-WG DNS guard substitutes only in the uncovered case', () {
      final (dns, note) = wgPlainTunDnsGuarded(
        '2001:4860:4860::8888',
        ipv6: false,
      );
      expect(dns, '1.1.1.1');
      expect(note, isNotNull);
      final (dns2, note2) = wgPlainTunDnsGuarded(
        '2001:4860:4860::8888',
        ipv6: true,
      );
      expect(dns2, '2001:4860:4860::8888');
      expect(note2, isNull);
      final (dns3, _) = wgPlainTunDnsGuarded('1.1.1.1', ipv6: false);
      expect(dns3, '1.1.1.1');
    });

    test('traffic history prunes to live profiles', () {
      final store = TrafficHistoryStore();
      final now = DateTime.now().millisecondsSinceEpoch;
      store.record('live', 10, 20, now);
      store.record('gone', 10, 20, now);
      expect(store.profileIds, containsAll(['live', 'gone']));
      store.pruneProfiles({'live'});
      expect(store.profileIds, ['live']);
    });
  });

  group('A25-32: handshake crypto off the UI isolate', () {
    test('buildWgInitiationOffUi builds a real initiation', () async {
      final init = await buildWgInitiationOffUi(_wgProfile());
      expect(init.datagram, isNotEmpty);
      expect(init.senderIndex, isNonZero);
    });
  });

  group('A25-07: sync restore failures surface (functional)', () {
    setUp(() {
      // The OpenVPN controller's load (which a restore now
      // runs first, A25-41) resolves its store through
      // path_provider — point it at a scratch directory.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async =>
                Directory.systemTemp.createTempSync('b2125').path,
          );
    });

    test('a damaged OpenVPN section is named in the failures', () async {
      final openvpn = OpenVpnController();
      final failed = await applyEngineSections(
        {
          'openVpnProfiles': ['not-a-map-entry'],
        },
        openvpn: openvpn,
      );
      expect(failed, contains('OpenVPN profiles'));
    });

    test('an absent section is not a failure', () async {
      final failed = await applyEngineSections({});
      expect(failed, isEmpty);
    });
  });

  group('native pins: claim layer + threading (A25-01/02/13/46)', () {
    final claim = _kt('EngineClaim.kt');
    final atomic = _kt('AtomicFile.kt');
    final xraySvc = _kt('XrayVpnService.kt');
    final wgEngine = _kt('WgTunnelEngine.kt');

    test('claims serialise under a monitor + a cross-process file lock', () {
      expect(claim, contains('withClaimLock'));
      expect(claim, contains('"\$FILE_NAME.lock"'));
      expect(claim, contains('.channel.lock()'));
      expect(claim, contains('fun rewrite('));
    });

    test('atomic writes use a per-writer temp name', () {
      expect(atomic, contains('Process.myPid()'));
      expect(atomic, contains('currentThread().id'));
    });

    test('pause/stop/resume run on one serial action worker', () {
      expect(xraySvc, contains('actionWorker'));
      expect(xraySvc, contains('"xray-actions"'));
      final pause = _region(
        xraySvc,
        'private fun pauseTunnel()',
        'private fun resumeTunnel()',
      );
      // The userStopped re-check after the core stop is
      // what kills the pause/stop resurrection.
      expect(pause, contains('userStopped'));
    });

    test('the Xray service validates before it claims', () {
      final guarded = _region(
        xraySvc,
        'private fun onStartCommandGuarded',
        'private fun startInForeground',
      );
      expect(guarded, contains('EXTRA_CONFIG'));
      expect(guarded, contains('EngineClaim.claim(this, startClaim)'));
    });

    test('the WG engine claims after validation, releases after teardown',
        () {
      expect(wgEngine, contains('startStopMutex'));
      expect(wgEngine, contains('EngineClaim.claim'));
    });
  });

  group('native pins: kill-switch holds (A25-04)', () {
    test('Psiphon holds its TUN on an unexpected death', () {
      final svc = _kt('PsiphonVpnService.kt');
      expect(svc, contains('fun holdKillSwitch'));
      expect(svc, contains('killSwitchHeld'));
      expect(svc, contains('EXTRA_KILL_SWITCH'));
      // The held TUN is NOT closed by the hold.
      final hold = _region(
        svc,
        'private fun holdKillSwitch',
        'private fun stopProcesses',
      );
      expect(hold, isNot(contains('tunPfd?.close()')));
    });

    test('Lantern routes its death path through the hold decision', () {
      // Build 2129 form: the CLI era's two death paths (core
      // exit + helper exit) are one — the status poll's
      // missed-verdict death — and the hold keeps the TUN
      // DUPLICATE the bridge's openTun made (dupTunFd), not
      // the service's own TUN fd.
      final svc = _kt('LanternVpnService.kt');
      expect(svc, contains('onSessionDied'));
      expect(svc, contains('killSwitchHeld = true'));
      expect(svc, contains('bridge.dupTunFd()'));
      expect(svc, contains('inKillSwitch && tunDup != null'));
    });

    test('OpenVPN holds only a session that was connected', () {
      final svc = _kt('OpenVpnService.kt');
      expect(svc, contains('killSwitchHeld'));
      expect(svc, contains('"kill_switch_hold"'));
      expect(svc, contains('OpenVpnCore.phase == "connected"'));
      expect(svc, contains('fun releaseHeldTun'));
    });

    test('the Settings coverage copy names the real coverage', () {
      final settings = _dart('ui/ember/ember_settings.dart');
      expect(settings, contains('Mozilla and AmneziaWG are not'));
      expect(
        settings,
        isNot(contains('Psiphon and Lantern are not covered')),
      );
    });
  });

  group('native pins: reaping, tile, fall-throughs (A25-18/36/47)', () {
    test('the application reaps every helper family at birth', () {
      final app = _kt('EmberApplication.kt');
      for (final call in [
        'SingBoxCore.reapOrphan(',
        'MieruCore.reapOrphan(',
        'DnsCryptCore.reapOrphan(',
        'DnsttCore.reapOrphan(',
        'WstunnelCore.reapOrphan(',
        'EmberWarpCore.reapOrphan(',
        'AetherCore.reapOrphans(',
      ]) {
        expect(app, contains(call), reason: call);
      }
    });

    test('the QS tile checks all networks for a VPN transport', () {
      final tile = _kt('QuickTile.kt');
      final fn = _region(
        tile,
        'private fun anotherEngineUp()',
        'private fun show()',
      );
      expect(fn, contains('allNetworks'));
      expect(fn, isNot(contains('activeNetwork')));
    });

    test('every TUN builder journals the empty-Only fall-through', () {
      for (final file in [
        'XrayVpnService.kt',
        'CoreService.kt',
        'PsiphonVpnService.kt',
        'WgTunnelEngine.kt',
      ]) {
        expect(
          _kt(file),
          contains('per-app Only set empty'),
          reason: file,
        );
      }
      // Build 2129: Lantern's TUN builder is the plugin-dex
      // bridge (its applyApps moved into openTun); the
      // journal line lives there now (logcat, the bridge's
      // own channel — it cannot reach CrashLog across the
      // classloader boundary at compile time).
      final bridge = File(
        'android/lantern-plugin-src/com/ralysnd/ember/lanternplugin/LanternEngine.java',
      ).readAsStringSync();
      expect(bridge, contains('per-app Only set empty'));
    });

    test('the WG engine clamps MTU to the TUN range and journals it', () {
      final wg = _kt('WgTunnelEngine.kt');
      expect(wg, contains('coerceIn(1280, 1500)'));
      expect(wg, contains('clamped to'));
    });
  });

  group('Dart pins: controller machinery', () {
    final xc = _dart('xray/xray_controller.dart');

    test('A25-06 follow-through: the stats comment tells the new truth', () {
      expect(xc, contains('no longer resets the core'));
    });

    test('A25-11: the verified latch re-proofs on a cadence', () {
      expect(xc, contains('_maybeReproof'));
      expect(xc, contains('_reproofCadenceMs'));
    });

    test('A25-19/20: the sink is a chain; readLogs is freshness-cached', () {
      expect(xc, contains('sinkTail'));
      expect(xc, contains('_readLogsUncached'));
      expect(xc, contains('_logsSignature'));
    });

    test('A25-22: large stores decode off-isolate; geo is awaited at connect',
        () {
      expect(xc, contains('_decodeStoreDocument'));
      expect(xc, contains('compute(_decodeStoreDocument'));
      expect(xc, contains('_ensureGeoInstalled'));
    });

    test('A25-24: subscription refresh carries the editor fields', () {
      expect(xc, contains('p.cipherSuites = old.cipherSuites'));
      expect(xc, contains('p.dialMode = old.dialMode'));
      expect(xc, contains('p.finalMask = old.finalMask'));
    });

    test('A25-27: sidecar supervision checks listener readiness', () {
      expect(xc, contains('_sidecarUnreadyTicks'));
      expect(xc, contains('its listener stopped'));
    });

    test('A25-31: Test All progress notifies are throttled', () {
      expect(xc, contains('_notifyScanProgress'));
      expect(
        '_notifyScanProgress();'.allMatches(xc).length,
        greaterThanOrEqualTo(4),
      );
    });

    test('A25-40: unmatched stats deltas are held, not dropped', () {
      expect(xc, contains('_heldStatsId'));
      expect(xc, contains('_heldStatsUp'));
    });

    test('A25-43: editSubscription rolls back on a failed refresh', () {
      final fn = _region(
        xc,
        'Future<void> editSubscription(',
        'Future<void> deleteSubscription(',
      );
      expect(fn, contains('oldUrl'));
      expect(fn, contains('rethrow'));
    });

    test('A25-14: kill-switch connects journal the uncovered window', () {
      expect(
        xc,
        contains('the connect/switch window is not'),
      );
    });

    test('A25-16: hostname sidecar connects journal the DNS exposure', () {
      expect(xc, contains('sidecar DNS note'));
      expect(xc, contains('compactJson(buildSingBoxConfig'));
    });

    test('A25-54: an empty feed parse never uninstalls the installed set', () {
      final fn = _region(
        xc,
        'Future<String> refreshDpiStrategies()',
        'bool preselectForNetwork(',
      );
      expect(fn, contains('parsed.isEmpty && dpiRemoteStrategies.isNotEmpty'));
      expect(fn, contains('127.0.0.1:\${settings.httpPort}'));
    });
  });

  group('Dart pins: shell, sync, aether, mozilla', () {
    test('A25-29/45: the shell gates its timer and serialises networks', () {
      final shell = _dart('ui/ember/ember_shell.dart');
      expect(shell, contains('_syncBudgetTimer'));
      expect(shell, contains('_networkQueue'));
      expect(shell, contains('_handleNetworkInner'));
    });

    test('A25-17: the shell corrects a stale claim marker', () {
      final shell = _dart('ui/ember/ember_shell.dart');
      expect(shell, contains('_liveClaimName'));
      final core = _dart('core/android_core.dart');
      expect(core, contains('engineClaimRewrite'));
    });

    test('A25-07: applyEngineSections returns its failures', () {
      final sync = _dart('ui/ember/ember_sync.dart');
      expect(sync, contains('Future<List<String>> applyEngineSections'));
      expect(sync, contains("failed.add('Psiphon settings')"));
    });

    test('A25-39: the never-travels notes are complete', () {
      final sync = _dart('ui/ember/ember_sync.dart');
      expect(sync, contains('Aether identity and scan'));
      expect(sync, contains('the battery log and'));
      final settings = _dart('ui/ember/ember_settings.dart');
      // Build 2128 (ordered supersession of the A25-39
      // pin): the Lantern smart-routing choice no longer
      // exists, so the never-travels note names the server
      // list alone; the note's completeness is unchanged.
      expect(settings, contains('the Lantern server list, '));
      expect(settings.contains('smart-routing choice'), isFalse);
    });

    test('A25-28: the Aether controller re-probes its data plane', () {
      final aether = _dart('aether/aether_controller.dart');
      expect(aether, contains('dataPlaneStale'));
      expect(aether, contains('_maybeProbeDataPlane'));
    });

    test('A25-41: restore paths run the load disciplines', () {
      final aether = _dart('aether/aether_controller.dart');
      final fn = _region(
        aether,
        'Future<void> setOptions(',
        'Future<void> refresh()',
      );
      expect(fn, contains('migrateMasqueTransport(next)'));
      final ovpn = _dart('openvpn/openvpn_controller.dart');
      final restore = _region(
        ovpn,
        'Future<void> restoreProfiles(',
        'Future<void> _saveStore()',
      );
      expect(restore, contains('if (!_loaded) await load();'));
    });

    test('A25-12: the Mozilla controller demotes a rotten h1 once', () {
      final core = _dart('core/core_controller.dart');
      expect(core, contains('_demoteH1'));
      expect(core, contains("proxy['transport'] = 'h2'"));
      expect(core, contains('_retestFailures >= 4'));
    });

    test('A25-21: the Mozilla core log mirrors at a reduced cadence', () {
      final core = _dart('core/core_controller.dart');
      expect(core, contains('_tick % 3 == 0'));
    });
  });

  group('Dart pins: updater hardening (A25-08/09/48/50/53/58)', () {
    final up = _dart('ui/ember/ember_updater.dart');

    test('the feed body is byte-capped', () {
      expect(up, contains('emberUpdateFeedMaxBytes'));
    });

    test('install re-verifies the file against the feed digest', () {
      final fn = _region(
        up,
        'Future<void> install()',
        'Android could not open the installer',
      );
      expect(fn, contains('Sha256()'));
      expect(fn, contains('apkDigest'));
    });

    test('downloads resume and can be cancelled', () {
      expect(up, contains('HttpHeaders.rangeHeader'));
      expect(up, contains('void cancelDownload()'));
      expect(up, contains('FileMode.append'));
      // The AB-15 finally-delete is gone: a part is resume state.
      expect(up, isNot(contains('Whatever did not become the')));
    });

    test('the sweep keeps the offered release\'s part', () {
      expect(up, contains('_sweepStaleParts(keepTag: parsed.tag)'));
    });

    test('the completion sweep keeps one previous APK (rollback)', () {
      expect(up, contains('others.sublist(1)'));
    });

    test('a stranded APK is re-offered only after verification', () {
      expect(up, contains('_reofferStrandedApk'));
      final fn = _region(
        up,
        'Future<bool> _reofferStrandedApk',
        'Future<void> download()',
      );
      expect(fn, contains('hasher.hex() != r.apkDigest'));
    });

    test('the settings page marks unverified installs and offers cancel', () {
      final settings = _dart('ui/ember/ember_settings.dart');
      expect(settings, contains('Install — UNVERIFIED'));
      expect(settings, contains('Cancel download'));
      expect(settings, contains('Resume download'));
    });
  });

  group('Dart pins: leak surfacing (A25-15/25/34/35)', () {
    test('Aether TUN starts carry the user DNS/IPv6 choices', () {
      final aether = _dart('aether/aether_controller.dart');
      expect(aether, contains('tunDns'));
      expect(aether, contains('tunIpv6'));
    });

    test('the Leak Test page names the effective resolvers', () {
      final page = _dart('ui/ember/leak_test_page.dart');
      expect(page, contains('primaryResolvers'));
    });

    test('the Block QUIC subtitle states its scope', () {
      final settings = _dart('ui/ember/ember_settings.dart');
      expect(
        settings,
        contains('DNS-over-QUIC, which resolves on the local'),
      );
    });

    test('OpenVPN state carries the IPv6 capture verdict + the hold', () {
      final platform = _dart('openvpn/openvpn_platform.dart');
      expect(platform, contains('ipv6Captured'));
      expect(platform, contains('killSwitchHeld'));
    });

    test('Psiphon + Lantern states carry the kill-switch hold', () {
      final psi = _dart('psiphon/psiphon_platform.dart');
      expect(psi, contains('killSwitchHeld'));
      final lan = _dart('lantern/lantern_platform.dart');
      expect(lan, contains('killSwitchHeld'));
    });
  });
}
