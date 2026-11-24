// Build 2116, batch B6 (platform/lifecycle) — proving tests.
//
// B6-1 (AB-10): a platform start() whose channel call throws
// no longer reads as an idle core with an empty error — the
// exception surfaces through state(). B6-2 (AB-11): the four
// unguarded state() reads degrade to stopped instead of
// throwing into refresh(). B6-3 (AB-13): the six torn-write
// sites route through the atomic writers. B6-4 (AB-12):
// subscription auto-update stamps attempts, backs off, and
// counts its failures for the page notice. B6-5 (AB-14): a
// pending stats flush is scheduled on the cadence. B6-6
// (AB-09): a post-up Lantern error line demotes "up". B6-7
// (L-01): the Lantern -smart choice persists — SUPERSEDED
// by build 2128, which removes the -smart option entirely
// (smart routing off, always); the group now pins the
// migration: a stored key loads cleanly and is dropped
// on the next persist.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/aether/aether_platform.dart';
import 'package:firefox_vpn/lantern/lantern_controller.dart';
import 'package:firefox_vpn/lantern/lantern_platform.dart';
import 'package:firefox_vpn/openvpn/openvpn_platform.dart';
import 'package:firefox_vpn/xray/dnstt_platform.dart';
import 'package:firefox_vpn/xray/sidecar_platform.dart';
import 'package:firefox_vpn/xray/warp_platform.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

void _mockAndroidChannel(
  Map<String, Object? Function(MethodCall)> handlers,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('app/android'), (
        call,
      ) async {
        final h = handlers[call.method];
        if (h != null) return h(call);
        return null;
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), null);
  });
}

/// A channel handler that throws, the way a dead platform
/// side does — the empty-map mock answers null instead,
/// which is a successful call, not a failure.
Object? _boom(MethodCall call) =>
    throw PlatformException(code: 'boom', message: 'channel exploded');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('B6-1 start failures surface through state()', () {
    test('sing-box: a thrown start lands in state().error', () async {
      _mockAndroidChannel({'singboxStart': _boom, 'singboxState': _boom});
      expect(await SingBoxPlatform.start(const ['run']), isFalse);
      expect(SingBoxPlatform.lastStartError, contains('channel exploded'));
      final st = await SingBoxPlatform.state();
      expect(st.stage, 'error');
      expect(st.error, contains('channel exploded'));
      SingBoxPlatform.lastStartError = '';
    });

    test('dnstt: a thrown state read is an error-stage state', () async {
      _mockAndroidChannel({'dnsttState': _boom});
      final st = await DnsttPlatform.state();
      expect(st.stage, 'error');
      expect(st.error, isNotEmpty);
      expect(st.running, isFalse);
    });

    test('warp: a thrown start lands in state().error', () async {
      _mockAndroidChannel({'warpStart': _boom, 'warpState': _boom});
      expect(await WarpPlatform.start(const []), isFalse);
      final st = await WarpPlatform.state();
      expect(st.stage, 'error');
      expect(st.error, contains('channel exploded'));
      WarpPlatform.lastStartError = '';
    });
  });

  group('B6-2 state() reads degrade to stopped', () {
    test('aether, lantern, openvpn, xray never throw', () async {
      _mockAndroidChannel({
        'aetherState': _boom,
        'lanternState': _boom,
        'openVpnState': _boom,
        'xrayState': _boom,
      });
      expect((await AetherPlatform.state('masque')).running, isFalse);
      expect((await LanternPlatform.state()).running, isFalse);
      expect((await OpenVpnPlatform.state()).running, isFalse);
      expect((await XrayPlatform.state()).running, isFalse);
    });
  });

  group('B6-3 atomic writes (pins)', () {
    test('the six sites use the atomic writers', () {
      final controller = File(
        'lib/xray/xray_controller.dart',
      ).readAsStringSync();
      expect(controller, contains('AtomicJsonStore.writeText'));
      String kt(String f) => File(
        'android/app/src/main/kotlin/com/ralysnd/ember/$f',
      ).readAsStringSync();
      expect(kt('MieruCore.kt'), contains('AtomicFile.writeText(configFile'));
      expect(
        kt('AetherCore.kt'),
        contains('AtomicFile.writeText(pidFile(context)'),
      );
      expect(
        kt('EmberWarpCore.kt'),
        contains('AtomicFile.writeText(pidFile(context)'),
      );
      expect(
        kt('SubprocessCore.kt'),
        contains('AtomicFile.writeText(pidFile(context)'),
      );
      // And the plain writes at those sites are gone.
      expect(kt('MieruCore.kt'), isNot(contains('configFile.writeText(')));
    });
  });

  group('B6-4 subscription backoff + stamps', () {
    test('the backoff doubles from 30 min and caps at 24 h', () {
      expect(subAutoUpdateBackoffMs(0), 0);
      expect(subAutoUpdateBackoffMs(1), 30 * 60 * 1000);
      expect(subAutoUpdateBackoffMs(2), 60 * 60 * 1000);
      expect(subAutoUpdateBackoffMs(3), 2 * 3600 * 1000);
      expect(subAutoUpdateBackoffMs(20), 24 * 3600 * 1000);
    });

    test('the attempt stamps round-trip through the store JSON', () {
      final sub = Subscription(
        id: 's1',
        lastAttemptMs: 123,
        failedAttempts: 2,
      );
      final back = Subscription.fromJson(sub.toJson());
      expect(back.lastAttemptMs, 123);
      expect(back.failedAttempts, 2);
      // A pre-2116 document has neither key.
      final legacy = Subscription.fromJson(const {'id': 's0'});
      expect(legacy.lastAttemptMs, 0);
      expect(legacy.failedAttempts, 0);
    });

    test('the sweep stamps, counts and backs off (pins)', () {
      final src = File('lib/xray/xray_controller.dart').readAsStringSync();
      expect(src, contains('sub.lastAttemptMs = now'));
      expect(src, contains('sub.failedAttempts += 1'));
      expect(src, contains('subAutoUpdateBackoffMs(sub.failedAttempts)'));
      expect(src, contains('int get subAutoRefreshFailing'));
      final page = File('lib/ui/ember/ember_servers.dart').readAsStringSync();
      expect(page, contains('subAutoRefreshFailing'));
      expect(page, contains('could not refresh'));
    });
  });

  group('B6-5 stats flush cadence (pins)', () {
    test('the first pending consume schedules the flush', () {
      final src = File('lib/xray/xray_controller.dart').readAsStringSync();
      expect(src, contains('_scheduleStatsFlush()'));
      expect(src, contains('Timer(const Duration(seconds: 30)'));
    });
  });

  group('B6-6 Lantern demotion (pin)', () {
    test('a connected session the core stops reporting is '
        'demoted, never latched (2129 form)', () {
      // The 2116 bug class: "up" latched over a dead core.
      // The CLI stdout contract that carried it is gone in
      // 2129; the gomobile shape's equivalent is the status
      // poll — two consecutive missed isVPNConnected polls
      // route the session through the death path.
      final src = File(
        'android/app/src/main/kotlin/com/ralysnd/ember/LanternVpnService.kt',
      ).readAsStringSync();
      expect(src, contains('missedPolls >= 2'));
      expect(src, contains('onSessionDied'));
      expect(src, isNot(contains('body.startsWith("error ")')));
    });
  });

  group('B6-7 Lantern smartRouting persistence (2129 form)', () {
    // History: pre-2128 the key was the CLI's -smart choice;
    // 2128 removed the option and the key was dropped on
    // persist. Build 2129 makes the key LIVE again in a new
    // meaning: it persists the user's smart-routing toggle
    // (the real API setting, DEFAULT OFF — an absent key
    // loads as off, and the core is forced off at every init
    // regardless; a stored ON is the user's own choice,
    // re-applied through the toggle path).
    test('a stored smartRouting key loads and persists as '
        'the toggle choice', () async {
      final tmp = await Directory.systemTemp.createTemp('ember2129b6');
      addTearDown(() => tmp.delete(recursive: true));
      final coreDir = await Directory('${tmp.path}/core').create();
      _mockAndroidChannel({
        'dataDir': (_) => coreDir.path,
        'lanternState': (_) => null,
      });
      final optionsFile = File('${tmp.path}/lantern_options.json');
      await optionsFile.writeAsString(
        '{"smartRouting": true, "privateMode": true, '
        '"privateKey": "lantern://k"}',
      );
      final first = LanternController();
      addTearDown(first.dispose);
      await first.load();
      expect(first.privateMode, isTrue);
      expect(first.privateKey, 'lantern://k');
      expect(first.smartRouting, isTrue);
      await first.setPrivateMode(false);
      final doc =
          jsonDecode(await optionsFile.readAsString())
              as Map<String, dynamic>;
      expect(doc['smartRouting'], isTrue);
      expect(doc['privateMode'], isFalse);
      expect(doc['privateKey'], 'lantern://k');
      final second = LanternController();
      addTearDown(second.dispose);
      await second.load();
      expect(second.privateMode, isFalse);
      expect(second.privateKey, 'lantern://k');
      expect(second.smartRouting, isTrue);
    });

    test('an absent smartRouting key defaults OFF', () async {
      final tmp = await Directory.systemTemp.createTemp('ember2129b6b');
      addTearDown(() => tmp.delete(recursive: true));
      final coreDir = await Directory('${tmp.path}/core').create();
      _mockAndroidChannel({
        'dataDir': (_) => coreDir.path,
        'lanternState': (_) => null,
      });
      final c = LanternController();
      addTearDown(c.dispose);
      await c.load();
      expect(c.smartRouting, isFalse);
      expect(c.selectedTag, '');
    });
  });
}
