/// Build 2054 gates — audit Batches 5 (lifecycle races) +
/// 6 (state integrity), plus the Q-1 soft-wait correction.
///
/// - F-H1: one monitor lock over restartCore+rotateCore+
///   stopProcesses (Kotlin); Dart ticks cross-check both busy
///   flags. The native ×100 concurrency race is not host-
///   runnable (no androidTest source set exists); it is pinned
///   here by source assertions on the lock and the guards,
///   the host-feasible form the audit allows for timing gates.
/// - F-H2: the rotate generation — rotateConfig waits for the
///   native generation to advance before reporting success,
///   so a proof can never pass on the old core. Tested
///   behaviourally against a mocked channel: a fake rotation
///   to an invalid config with a healthy old core returns
///   false even though tunnelCheck still answers.
/// - F-H3: the watchdog tick advances once per loop,
///   unconditionally (source pin; the 10 s/15 s timing is a
///   device property of the 1 s loop).
/// - Q-1: a waitPortFree timeout FAILS the restart/start
///   instead of respawning anyway (source pins: the old
///   wording is gone, the fail path is in).
/// - F-M1: the shared kill+waitExit helper everywhere, and the
///   sweep's bounded death wait (source pins).
/// - F-M5: the respawn/stop waits on observable state
///   (source pins; the 4 s timing is a device property).
/// - F-M6: Kotlin config.json tmp+rename + validate-or-rewrite
///   (source pins).
/// - F-H8: seeded-store fault injection per controller
///   (behavioural, temp dir + mocked dataDir).
/// - F-H9 (+F-M14): transactional backup/restore (behavioural).
/// - F-M16: wrong-typed fromJson fuzz per key (behavioural).
/// - F-M18: core config atomic write (behavioural + pin).
/// - F-M19: geo tmp+rename + exact-length compare
///   (behavioural: a truncated geo file is re-installed).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/aether/aether_controller.dart';
import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/atomic_json_store.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

Profile _vless(String id, String address) => Profile(
  id: id,
  protocol: Protocol.vless,
  name: id,
  address: address,
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  security: 'tls',
  sni: address,
);

String _read(String path) => File(path).readAsStringSync();

String _kt(String name) => _read(
  'android/app/src/main/kotlin/com/ralysnd/ember/$name',
);

/// The fake 'app/android' channel for the rotate/backup
/// groups: a running session whose core answers tunnelCheck,
/// and a rotation generation that advances only when the test
/// says the native rotate really landed.
class _FakeAndroid {
  int gen = 1;
  bool running = true;
  bool advanceGenOnRotate = true;
  final calls = <String>[];

  Map<String, Object?> stateMap() => <String, Object?>{
    'running': running,
    'name': 'a',
    'sinceMs': 1,
    'up': 0,
    'down': 0,
    'coreRestarts': 0,
    'coreProblem': '',
    'chainUnderlay': false,
    'chainProblem': '',
    'awg': false,
    'awgConfig': '',
    'rotationGen': gen,
  };

  Future<Object?> handler(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'xrayRotateConfig':
        if (advanceGenOnRotate) gen++;
        return true;
      case 'xrayState':
        return stateMap();
      case 'xrayTunnelCheck':
        return 50;
      case 'xrayTrafficStats':
        return null;
      case 'networkFingerprint':
        return null;
      case 'xrayExitInfo':
        return null;
      case 'xrayStop':
        running = false;
        return null;
      default:
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('F-H2 rotate generation (behavioural)', () {
    late _FakeAndroid fake;
    late Duration savedTimeout;

    setUp(() {
      fake = _FakeAndroid();
      savedTimeout = XrayPlatform.rotateGenerationTimeout;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            fake.handler,
          );
    });

    tearDown(() {
      XrayPlatform.rotateGenerationTimeout = savedTimeout;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            null,
          );
    });

    test('rotateConfig returns true once the generation advances', () async {
      fake.advanceGenOnRotate = true;
      expect(await XrayPlatform.rotateConfig('{}'), isTrue);
      expect(fake.gen, 2);
    });

    test(
      'a rotation the native side never completes returns false, '
      'even though the old core still answers tunnelCheck',
      () async {
        fake.advanceGenOnRotate = false;
        XrayPlatform.rotateGenerationTimeout = const Duration(seconds: 1);
        expect(await XrayPlatform.rotateConfig('{}'), isFalse);
        // The old core answers — the proof must not be allowed
        // to pass on it. (rotateConfig itself refuses first.)
        expect(await XrayPlatform.tunnelCheck(10808), 50);
      },
    );

    test('rotateConfig returns false at once when the channel refuses', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            (call) async => call.method == 'xrayRotateConfig' ? false : null,
          );
      expect(await XrayPlatform.rotateConfig('{}'), isFalse);
    });

    test('rotateConfig returns false when the session dies mid-rotate', () async {
      fake.advanceGenOnRotate = false;
      XrayPlatform.rotateGenerationTimeout = const Duration(seconds: 5);
      // The session dies 300 ms in: the generation wait must
      // notice and give up instead of waiting out the timeout.
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        fake.running = false;
      });
      final stopwatch = Stopwatch()..start();
      expect(await XrayPlatform.rotateConfig('{}'), isFalse);
      expect(stopwatch.elapsed.inSeconds, lessThan(5));
    });
  });

  group('Source pins: Batch 5 lifecycle races', () {
    test('F-H1: one monitor lock over restart+rotate+stop', () {
      final kt = _kt('XrayVpnService.kt');
      expect(kt, contains('private val coreLock = Any()'));
      expect(
        'synchronized(coreLock)'.allMatches(kt).length,
        greaterThanOrEqualTo(3),
        reason:
            'restartCore, rotateCore and stopProcesses must all '
            'take the same lock',
      );
      expect(kt, contains('synchronized(coreLock) { restartCoreLocked'));
      // Stop paths run off the main thread: a restart can hold
      // the lock ~20 s, and blocking the main thread is an ANR.
      expect(kt, contains('name = "xray-stop"'));
    });

    test('F-H1 Dart: the two ticks cross-check both busy flags', () {
      final dart = _read('lib/xray/xray_controller.dart');
      final wd = dart.substring(dart.indexOf('Future<void> _watchdogTick'));
      expect(wd, contains('_adaptiveBusy'));
      final ad = dart.substring(dart.indexOf('Future<void> _adaptiveTick'));
      expect(ad, contains('_wdBusy'));
    });

    test('F-H3: the watchdog tick advances once per loop, always', () {
      final kt = _kt('XrayVpnService.kt');
      // Build 2055 (audit B-H5) supersedes the 1 s cadence this
      // test pinned: the loop now sleeps 5 s and every probe runs
      // once per tick, so the tick % 6 / % 5 moduli are gone. The
      // invariant the pin protects is unchanged — the tick still
      // advances once per loop, unconditionally, and no `++tick %`
      // form can freeze it at 0 again.
      expect(kt, contains('tick++'));
      expect(kt, isNot(contains('++tick % 6')));
      expect(kt, isNot(contains('++tick % 5')));
      expect(kt, isNot(contains('tick % 6 == 0')));
      expect(kt, isNot(contains('tick % 5 == 0')));
      expect(kt, contains('Thread.sleep(5000)'));
    });

    test('Q-1: a port-free timeout FAILS instead of respawning anyway', () {
      final kt = _kt('XrayVpnService.kt');
      expect(kt, isNot(contains('respawning anyway')));
      expect(kt, isNot(contains('restarting anyway')));
      expect(kt, contains('not respawning'));
      expect(kt, contains('the session was stopped instead of'));
      expect(
        kt,
        contains('still busy 3 s after the orphan sweep; not starting on it'),
      );
    });

    test('F-M1: the shared kill helper everywhere', () {
      final kill = _kt('ProcessKill.kt');
      expect(kill, contains('fun kill('));
      expect(kill, contains('fun waitPortFree('));
      expect(kill, contains('waitExit(p, forcibleWaitMs)'));
      // Build 2066 supersedes the Psiphon entry: the service owns
      // no child process any more (the libtunlink helper was the
      // 2065 regression's bridge; the badvpn bridge is an
      // in-process thread). Its stop discipline — terminate +
      // bounded join, the same signal-then-wait shape — is pinned
      // in build2066_test.dart instead.
      for (final entry in {
        'XrayVpnService.kt': 2,
        'LanternVpnService.kt': 2,
        'EmberWarpCore.kt': 1,
        'XrayTester.kt': 1,
      }.entries) {
        expect(
          'ProcessKill.kill'.allMatches(_kt(entry.key)).length,
          greaterThanOrEqualTo(entry.value),
          reason: '${entry.key} must use the shared kill',
        );
      }
      // The old destroy/grace/forcibly-with-no-post-wait pattern
      // is gone from the stop paths.
      expect(_kt('PsiphonVpnService.kt'), isNot(contains('destroyForcibly()')));
      expect(_kt('LanternVpnService.kt'), isNot(contains('p.destroyForcibly()')));
    });

    test('F-M1: the orphan sweep waits for its kills to land', () {
      final kt = _kt('XrayVpnService.kt');
      expect(kt, contains('killed.none { File("/proc"'));
      expect(kt, contains('still present after 3 s'));
    });

    test('F-M5: respawn waits on observable state, not a sleep', () {
      final kt = _kt('XrayVpnService.kt');
      expect(kt, contains('waitUnderlayStopped(4000)'));
      // Updated by build 2073: the waited-on observable state is
      // now the Psiphon service's published snapshot — the
      // companion static lives in the :psiphon process since the
      // own-process fix, so waitUnderlayStopped reads
      // publishedRunning. The F-M5 intent is unchanged: the wait
      // still polls observable state (snapshot + port), never a
      // bare sleep.
      expect(kt, contains('!PsiphonVpnService.publishedRunning(this)'));
      expect(kt, isNot(contains('Thread.sleep(600)')));
      final dart = _read('lib/xray/xray_controller.dart');
      expect(dart, contains('_stopPsiphonUnderlay()'));
      expect(dart, contains('did not stop in time'));
    });

    test('F-M6: Kotlin config writes are atomic + validated on restart', () {
      final kt = _kt('XrayVpnService.kt');
      expect(kt, contains('AtomicFile.writeText(File(dir, "config.json")'));
      expect(kt, contains('isValidConfigJson(configFile)'));
      expect(kt, contains('session config.json is torn; rewriting from memory'));
      expect(_kt('AtomicFile.kt'), contains('fun writeText('));
      expect(_kt('AtomicFile.kt'), contains('fd.sync()'));
    });

    test('F-H2 native: the generation advances only on a served rotate', () {
      final kt = _kt('XrayVpnService.kt');
      expect(kt, contains('var rotationGen = 0'));
      expect(kt, contains('rotationGen++'));
      expect(
        _kt('MainActivity.kt'),
        contains('"rotationGen" to XrayVpnService.rotationGen'),
      );
    });
  });

  group('F-H8 AtomicJsonStore (unit)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ember2054-store-');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('write then read round-trips', () async {
      final store = AtomicJsonStore(File('${tempDir.path}/s.json'));
      await store.write({'a': 1, 'b': 'x'});
      expect(await store.read(), {'a': 1, 'b': 'x'});
      expect(await File('${tempDir.path}/s.json.tmp').exists(), isFalse);
    });

    test('a torn file is quarantined, never silently reset', () async {
      final file = File('${tempDir.path}/s.json');
      await file.writeAsString('{"a": 1, "b": ');
      final store = AtomicJsonStore(file);
      expect(await store.read(), isNull);
      final corrupt = File('${tempDir.path}/s.json.corrupt');
      expect(await corrupt.exists(), isTrue);
      expect(await corrupt.readAsString(), '{"a": 1, "b": ');
      expect(await file.exists(), isFalse);
    });

    test('concurrent writes serialize: the file is always whole', () async {
      final store = AtomicJsonStore(File('${tempDir.path}/s.json'));
      await Future.wait([
        store.write({'n': 1}),
        store.write({'n': 2}),
        store.write({'n': 3}),
      ]);
      final doc = await store.read();
      expect(doc, isNotNull);
      expect(doc!['n'], isIn([1, 2, 3]));
      expect(await File('${tempDir.path}/s.json.tmp').exists(), isFalse);
    });

    test('writeText/writeBytes land atomically with no .tmp left', () async {
      final file = File('${tempDir.path}/g.dat');
      await AtomicJsonStore.writeBytes(file, [1, 2, 3]);
      expect(await file.readAsBytes(), [1, 2, 3]);
      expect(await File('${tempDir.path}/g.dat.tmp').exists(), isFalse);
      await AtomicJsonStore.writeText(file, 'hello');
      expect(await file.readAsString(), 'hello');
    });
  });

  group('F-H8 seeded-store fault injection (behavioural)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ember2054-seed-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            (call) async {
              switch (call.method) {
                case 'dataDir':
                  return '${tempDir.path}/core';
                case 'openVpnState':
                  return <String, Object?>{
                    'available': true,
                    'running': false,
                    'connected': false,
                    'phase': 'idle',
                    'profileId': '',
                    'profileName': '',
                    'sinceMs': 0,
                    'up': 0,
                    'down': 0,
                    'exitIp': '',
                    'exitCountry': '',
                    'exitCode': '',
                    'error': null,
                    'logTail': <String>[],
                    'lastExitReason': '',
                    'lastStage': '',
                    'lastException': '',
                  };
                case 'psiphonState':
                  return <String, Object?>{
                    'running': false,
                    'connected': false,
                    'vpnMode': true,
                    'sinceMs': 0,
                    'up': 0,
                    'down': 0,
                    'region': '',
                    'clientAddress': '',
                    'regions': <String>[],
                  };
                default:
                  return null;
              }
            },
          );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            null,
          );
      await tempDir.delete(recursive: true);
    });

    test('OpenVPN: a torn store is quarantined, not silently emptied', () async {
      final file = File('${tempDir.path}/openvpn/state.json');
      await file.parent.create(recursive: true);
      await file.writeAsString('{"selectedId": "x", "profiles": [');
      final c = OpenVpnController();
      addTearDown(c.dispose);
      await c.load();
      expect(c.userProfiles, isEmpty);
      expect(
        await File('${tempDir.path}/openvpn/state.json.corrupt').exists(),
        isTrue,
      );
      // And the next save does not silently overwrite the
      // quarantine with an empty store: the .corrupt copy
      // still holds the torn bytes.
      expect(
        await File(
          '${tempDir.path}/openvpn/state.json.corrupt',
        ).readAsString(),
        '{"selectedId": "x", "profiles": [',
      );
    });

    test('OpenVPN: one bad entry is skipped, the good ones survive', () async {
      const cfg =
          'client\ndev tun\nproto udp\nremote vpn.example.com 1194\n';
      final file = File('${tempDir.path}/openvpn/state.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'selectedId': 'good-1',
          'profiles': [
            {
              'id': 'good-1',
              'name': 'Good',
              'config': cfg,
            },
            {
              // No config at all: fromJson must not take the
              // whole load down with it.
              'id': 'bad-1',
              'name': 'Bad',
              'config': 42,
            },
            {'id': 'good-2', 'name': 'Also good', 'config': cfg},
          ],
        }),
      );
      final c = OpenVpnController();
      addTearDown(c.dispose);
      await c.load();
      expect(
        c.userProfiles.map((p) => p.id),
        ['good-1', 'good-2'],
        reason: 'the damaged entry is dropped, never the store',
      );
      expect(c.selectedId, 'good-1');
      // A save now persists the survivors, not an empty store.
      c.select('good-2');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final saved =
          jsonDecode(
                await File(
                  '${tempDir.path}/openvpn/state.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(
        (saved['profiles'] as List).map((e) => (e as Map)['id']),
        ['good-1', 'good-2'],
      );
    });

    test('OpenVPN: a save before load never overwrites the store', () async {
      const cfg =
          'client\ndev tun\nproto udp\nremote vpn.example.com 1194\n';
      final file = File('${tempDir.path}/openvpn/state.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'selectedId': 'good-1',
          'profiles': [
            {'id': 'good-1', 'name': 'Good', 'config': cfg},
          ],
        }),
      );
      final c = OpenVpnController();
      addTearDown(c.dispose);
      c.select('good-1');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final kept =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(
        (kept['profiles'] as List).length,
        1,
        reason: 'the pre-load save is skipped, not persisted empty',
      );
    });

    test('Psiphon: a torn store is quarantined, settings reset visibly', () async {
      final file = File('${tempDir.path}/psiphon/state.json');
      await file.parent.create(recursive: true);
      await file.writeAsString('{"settings": {"vpnMode": tru');
      final c = PsiphonController();
      addTearDown(c.dispose);
      await c.load();
      expect(c.settings.vpnMode, isTrue, reason: 'defaults, not a crash');
      expect(
        await File('${tempDir.path}/psiphon/state.json.corrupt').exists(),
        isTrue,
      );
    });

    test('Psiphon: settings survive a load/save round-trip', () async {
      final c = PsiphonController();
      addTearDown(c.dispose);
      await c.load();
      final next = PsiphonSettings()
        ..vpnMode = false
        ..region = 'NL';
      await c.updateSettings(next);
      final saved =
          jsonDecode(
                await File(
                  '${tempDir.path}/psiphon/state.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(saved['settings']['vpnMode'], isFalse);
      expect(saved['settings']['region'], 'NL');
      expect(
        await File('${tempDir.path}/psiphon/state.json.tmp').exists(),
        isFalse,
      );
      final c2 = PsiphonController();
      addTearDown(c2.dispose);
      await c2.load();
      expect(c2.settings.vpnMode, isFalse);
      expect(c2.settings.region, 'NL');
    });

    test('Aether: a torn options file is quarantined, defaults load', () async {
      final file = File('${tempDir.path}/aether_cfwarp_options.json');
      await file.writeAsString('{"protocol": "wg", "scan": ');
      final c = AetherController('cfwarp');
      addTearDown(c.dispose);
      await c.load();
      expect(c.options.protocol, 'wg', reason: 'cfwarp pins wg either way');
      expect(
        await File(
          '${tempDir.path}/aether_cfwarp_options.json.corrupt',
        ).exists(),
        isTrue,
      );
    });

    test('Aether: options survive a load/save round-trip', () async {
      final c = AetherController('masque');
      addTearDown(c.dispose);
      await c.load();
      final next = c.options.copyWith(scan: 'performance');
      await c.setOptions(next);
      final saved =
          jsonDecode(
                await File(
                  '${tempDir.path}/aether_masque_options.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(saved['scan'], 'performance');
      final c2 = AetherController('masque');
      addTearDown(c2.dispose);
      await c2.load();
      expect(c2.options.scan, 'performance');
    });

    test('AppSettings: update persists atomically and reads back', () async {
      final file = File('${tempDir.path}/app-settings.json');
      final s = AppSettings(file: file);
      addTearDown(s.dispose);
      // The 2006 one-time migration resets a stored language
      // to English when emberEnDefaultApplied is false; a
      // post-migration user (flag set) owns the value.
      s.update(language: 'fa', emberMode: 2, emberEnDefaultApplied: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await File('${tempDir.path}/app-settings.json.tmp').exists(), isFalse);
      final back = await AppSettings.load(tempDir.path);
      expect(back.language, 'fa');
      expect(back.emberMode, 2);
    });

    test('AppSettings: a torn file loads defaults, then self-heals', () async {
      final file = File('${tempDir.path}/app-settings.json');
      await file.writeAsString('{"language": "fa", "theme": ');
      final s = await AppSettings.load(tempDir.path);
      addTearDown(s.dispose);
      expect(s.language, 'en', reason: 'torn file reads as defaults');
      s.update(language: 'fa');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final back = await AppSettings.load(tempDir.path);
      expect(back.language, 'fa');
    });
  });

  group('F-H9 transactional backup/restore (behavioural)', () {
    late Directory tempDir;
    late _FakeAndroid fake;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ember2054-backup-');
      fake = _FakeAndroid()..running = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            (call) async {
              if (call.method == 'dataDir') return '${tempDir.path}/core';
              return fake.handler(call);
            },
          );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            null,
          );
      await tempDir.delete(recursive: true);
    });

    XrayController seeded() {
      final c = XrayController();
      c.profiles = [_vless('a', 'a.example.com'), _vless('b', 'b.example.com')];
      c.subscriptions = [
        Subscription(id: 's1', name: 'Sub', url: 'https://sub.example.com/sub'),
      ];
      // Build 2057 (audit F-M2): the marker port is 11880, not
      // 11808 — 11808 is Psiphon's own SOCKS port, so a stored
      // 11808 now sanitises to the defaults on load instead of
      // round-tripping. 11880 is still a non-default marker that
      // survives the validation (not reserved, not the stats
      // port, distinct from the HTTP port).
      c.settings = XraySettings()..socksPort = 11880;
      c.warpProfile = WarpProfile()..protocol = 'wg';
      c.cfGoodIps = ['1.2.3.4'];
      c.shapeCache.record('a', 'fp', 'stock', 100);
      c.selectedProfileId = 'a';
      return c;
    }

    test('round-trip restores everything, including the warp fields', () async {
      final c1 = seeded();
      addTearDown(c1.dispose);
      final exported = await c1.exportBackup();
      final doc = jsonDecode(exported) as Map<String, dynamic>;
      expect(doc['schemaVersion'], XrayController.backupSchemaVersion);
      final c2 = XrayController();
      addTearDown(c2.dispose);
      expect(await c2.importBackup(exported), isTrue);
      expect(c2.profiles.map((p) => p.id), ['a', 'b']);
      expect(c2.subscriptions.map((s) => s.id), ['s1']);
      expect(c2.settings.socksPort, 11880);
      expect(c2.warpProfile.protocol, 'wg');
      expect(c2.cfGoodIps, ['1.2.3.4']);
      expect(c2.shapeCache.lookup('a', 'fp')?.shapeId, 'stock');
      expect(c2.selectedProfileId, 'a');
    });

    test('one bad profile entry is skipped, the good ones restore', () async {
      final c = XrayController();
      addTearDown(c.dispose);
      final doc = {
        'profiles': [
          _vless('good', 'good.example.com').toJson(),
          {'id': 42, 'name': 'Bad', 'protocol': 'vless'},
          {'name': 'No id at all'},
        ],
        'subscriptions': [],
        'selectedProfileId': 'good',
      };
      expect(await c.importBackup(jsonEncode(doc)), isTrue);
      expect(c.profiles.map((p) => p.id), ['good']);
    });

    test('a document that is not a backup returns false, state untouched', () async {
      final c = seeded();
      addTearDown(c.dispose);
      final before = c.profiles.map((p) => p.id).toList();
      expect(await c.importBackup('{"profiles": "nope"}'), isFalse);
      expect(await c.importBackup('not json at all'), isFalse);
      expect(await c.importBackup('{"nope": true}'), isFalse);
      expect(c.profiles.map((p) => p.id), before);
      expect(c.selectedProfileId, 'a');
      expect(c.warpProfile.protocol, 'wg');
    });

    test('a future schema version returns false, state untouched', () async {
      final c = seeded();
      addTearDown(c.dispose);
      final doc = {
        'schemaVersion': 99,
        'profiles': [_vless('x', 'x.example.com').toJson()],
      };
      expect(await c.importBackup(jsonEncode(doc)), isFalse);
      expect(c.profiles.map((p) => p.id), ['a', 'b']);
    });

    test('a legacy backup without a version still restores', () async {
      final c = XrayController();
      addTearDown(c.dispose);
      final doc = {
        'profiles': [_vless('a', 'a.example.com').toJson()],
        'selectedProfileId': 'a',
      };
      expect(await c.importBackup(jsonEncode(doc)), isTrue);
      expect(c.profiles.map((p) => p.id), ['a']);
    });

    test('an invalid backup never disconnects a live tunnel', () async {
      final c = seeded();
      addTearDown(c.dispose);
      c.state = const XrayState(
        running: true,
        name: 'a',
        sinceMs: 1,
        upBytes: 0,
        downBytes: 0,
      );
      expect(await c.importBackup('{"profiles": "nope"}'), isFalse);
      expect(c.state.running, isTrue);
      expect(fake.calls, isNot(contains('xrayStop')));
      expect(c.profiles.map((p) => p.id), ['a', 'b']);
    });

    test('a valid backup disconnects first, then swaps', () async {
      final c = seeded();
      addTearDown(c.dispose);
      c.state = const XrayState(
        running: true,
        name: 'a',
        sinceMs: 1,
        upBytes: 0,
        downBytes: 0,
      );
      final doc = {
        'profiles': [_vless('z', 'z.example.com').toJson()],
        'selectedProfileId': 'z',
      };
      expect(await c.importBackup(jsonEncode(doc)), isTrue);
      expect(fake.calls, contains('xrayStop'));
      expect(c.profiles.map((p) => p.id), ['z']);
    });
  });

  group('F-M16 wrong-typed fromJson fuzz', () {
    const wrongValues = [42, true, 1.5, ['x'], {'a': 1}];

    test('Profile.fromJson never throws on a wrong-typed value', () {
      final good = _vless('a', 'a.example.com').toJson();
      for (final key in good.keys) {
        if (key == 'id') continue; // Strict by design: the
        // entry without a string id is dropped by _decodeList.
        for (final bad in wrongValues) {
          final doc = Map<String, dynamic>.of(good)..[key] = bad;
          expect(
            () => Profile.fromJson(doc),
            returnsNormally,
            reason: 'Profile.$key = $bad must read as a fallback',
          );
        }
      }
      // A document that is wrong-typed everywhere loads with
      // all defaults instead of throwing the store load. The
      // wrong value is a map: wrong for a String, a bool AND
      // a num alike (42 would be a legitimate int).
      final allBad = <String, dynamic>{
        for (final key in good.keys) key: const {'a': 1},
      }..['id'] = 'a';
      final p = Profile.fromJson(allBad);
      expect(p.name, '');
      expect(p.port, 443);
      expect(p.starred, isFalse);
    });

    test('Subscription.fromJson never throws on a wrong-typed value', () {
      final good = Subscription(
        id: 's1',
        name: 'Sub',
        url: 'https://sub.example.com/sub',
      ).toJson();
      for (final key in good.keys) {
        if (key == 'id') continue;
        for (final bad in wrongValues) {
          final doc = Map<String, dynamic>.of(good)..[key] = bad;
          expect(
            () => Subscription.fromJson(doc),
            returnsNormally,
            reason: 'Subscription.$key = $bad must read as a fallback',
          );
        }
      }
    });

    test('XraySettings.fromJson never throws on a wrong-typed value', () {
      final good = XraySettings().toJson();
      for (final key in good.keys) {
        for (final bad in wrongValues) {
          final doc = Map<String, dynamic>.of(good)..[key] = bad;
          expect(
            () => XraySettings.fromJson(doc),
            returnsNormally,
            reason: 'XraySettings.$key = $bad must read as a fallback',
          );
        }
      }
      final s = XraySettings.fromJson(<String, dynamic>{
        for (final key in good.keys) key: const {'a': 1},
      });
      expect(s.enableUdp, isTrue);
      expect(s.socksPort, XraySettings().socksPort);
    });

    test('source pin: no bare casts left in the three factories', () {
      final src = _read('lib/xray/xray_models.dart');
      final profile = src.substring(src.indexOf('factory Profile.fromJson'));
      final profileBody = profile.substring(0, profile.indexOf('\n}\n'));
      // The code shapes only (comments still narrate the old
      // pattern, so the pins match the cast expressions).
      expect(profileBody, isNot(contains(' as String? ??')));
      expect(profileBody, isNot(contains(' as bool? ??')));
      expect(profileBody, isNot(contains(' as num?)?.toInt()')));
    });
  });

  group('F-M19 geo install (behavioural)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ember2054-geo-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            (call) async {
              switch (call.method) {
                case 'dataDir':
                  return '${tempDir.path}/core';
                case 'xrayState':
                  return <String, Object?>{
                    'running': false,
                    'name': '',
                    'sinceMs': 0,
                    'up': 0,
                    'down': 0,
                  };
                default:
                  return null;
              }
            },
          );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            null,
          );
      await tempDir.delete(recursive: true);
    });

    test('a truncated geo file is re-installed at the exact length', () async {
      final dir = Directory('${tempDir.path}/xray');
      await dir.create(recursive: true);
      // The old "> 1 MB" check passed this 5 MB torn file
      // forever; the exact-length compare must not.
      await File(
        '${dir.path}/geoip.dat',
      ).writeAsBytes(List<int>.filled(5000000, 0));
      final c = XrayController();
      addTearDown(c.dispose);
      await c.load();
      expect(
        await File('${dir.path}/geoip.dat').length(),
        16549675,
        reason: 'the torn file is replaced by the whole asset',
      );
      expect(
        await File('${dir.path}/geosite.dat').length(),
        11309380,
        reason: 'the missing file is installed too',
      );
      expect(await File('${dir.path}/geoip.dat.tmp').exists(), isFalse);
      expect(await File('${dir.path}/geosite.dat.tmp').exists(), isFalse);
    });

    test('source pin: exact lengths + atomic write, no >1MB check', () {
      final dart = _read('lib/xray/xray_controller.dart');
      expect(dart, contains("'geoip.dat': 16549675"));
      expect(dart, contains("'geosite.dat': 11309380"));
      expect(dart, contains('AtomicJsonStore.writeBytes('));
      expect(dart, isNot(contains('length() > 1000000')));
    });
  });

  group('F-M18 core config atomic write (behavioural)', () {
    test('setDashboardListen rewrites atomically, keeping other keys', () async {
      final tempDir = await Directory.systemTemp.createTemp('ember2054-core-');
      addTearDown(() => tempDir.delete(recursive: true));
      final file = File('${tempDir.path}/config.json');
      await file.writeAsString(
        jsonEncode({
          'dashboard': {'listen': '127.0.0.1:8080'},
          'token': 'keep-me',
        }),
      );
      await CoreLocator.setDashboardListen(tempDir.path, '127.0.0.1:9090');
      final back =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect((back['dashboard'] as Map)['listen'], '127.0.0.1:9090');
      expect(back['token'], 'keep-me');
      expect(await File('${tempDir.path}/config.json.tmp').exists(), isFalse);
    });

    test('source pin: the write goes through AtomicJsonStore', () {
      expect(
        _read('lib/core/core_api.dart'),
        contains('AtomicJsonStore.writeText('),
      );
    });
  });

  group('Source pins: Batch 6 state integrity', () {
    test('F-H8: one shared AtomicJsonStore for all five Dart stores', () {
      final store = _read('lib/atomic_json_store.dart');
      expect(store, contains('class AtomicJsonStore'));
      expect(store, contains('.corrupt'));
      expect(store, contains('tmp'));
      expect(store, contains('rename('));
      for (final path in [
        'lib/openvpn/openvpn_controller.dart',
        'lib/psiphon/psiphon_controller.dart',
        'lib/aether/aether_controller.dart',
        'lib/app_settings.dart',
        'lib/xray/xray_controller.dart',
      ]) {
        expect(
          _read(path),
          contains('AtomicJsonStore'),
          reason: '$path must use the shared store',
        );
      }
      // The old direct writes are gone from the store-save
      // paths: OpenVPN has no writeAsString left at all, and
      // Psiphon's remaining ones are clearLogs writing log
      // files — not a store — so they stay. Build 2070 raised
      // the count from 1 to 2: clearLogs now also empties the
      // shared crash.log section its viewer displays.
      expect(
        'writeAsString('.allMatches(
          _read('lib/openvpn/openvpn_controller.dart'),
        ).length,
        0,
      );
      expect(
        'writeAsString('.allMatches(
          _read('lib/psiphon/psiphon_controller.dart'),
        ).length,
        2,
      );
      final psi = _read('lib/psiphon/psiphon_controller.dart');
      final psiSave = psi.substring(psi.indexOf('Future<void> _save('));
      // _save writes through the _atomicStore() helper, which
      // is where the AtomicJsonStore is constructed.
      expect(psiSave, contains('_atomicStore()'));
      expect(psi, contains('AtomicJsonStore('));
    });

    test('F-H9: restore decodes into locals, swaps once, disconnects last', () {
      final dart = _read('lib/xray/xray_controller.dart');
      final fn = dart.substring(dart.indexOf('Future<bool> importBackup'));
      expect(fn, contains('newProfiles = _decodeList'));
      expect(fn, contains('newWarpProfile'));
      expect(fn, contains('newCfGoodIps'));
      expect(fn, contains('newShapeCache'));
      expect(fn, contains('schemaVersion'));
      // The disconnect sits AFTER the decode block, not before it.
      expect(
        fn.indexOf('if (state.running) await disconnect();'),
        greaterThan(fn.indexOf('} catch (_) {')),
      );
    });

    test('F-M5 Dart: the underlay stop waits before the restart', () {
      final dart = _read('lib/xray/xray_controller.dart');
      expect(dart, contains('Future<void> _stopPsiphonUnderlay()'));
      expect(dart, contains('Duration(seconds: 4)'));
    });
  });
}
