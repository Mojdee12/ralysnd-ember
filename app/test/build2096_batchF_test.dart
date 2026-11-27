// Build 2096 — batch F tests: features.
// L3 (watchdog mid-escalation switch), L4 (remainingDays
// floor), L8 (offer pins), L9 (health denominator),
// L10 (preset candidates), L11 (channel invalidation),
// L14 (pairing collector), M17/M19/M25/L15/L16/L21
// (units + pins for UI-bound branches).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/lantern/lantern_platform.dart';
import 'package:firefox_vpn/openvpn/openvpn_platform.dart';
import 'package:firefox_vpn/ui/ember/ember_updater.dart';
import 'package:firefox_vpn/ui/ember/pairing.dart';
import 'package:firefox_vpn/ui/ember/quick_presets.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

Profile _p(String id, {int delayMs = -1, bool delayFailed = false}) =>
    Profile(
      id: id,
      protocol: Protocol.vless,
      name: id,
      address: 'a.example.com',
      port: 443,
      uuidOrPassword: '11111111-1111-1111-1111-111111111111',
      delayMs: delayMs,
      delayFailed: delayFailed,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('L4 — remainingDays floor semantics', () {
    test('3.2 days remaining reads 3 and flags low', () {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final sub = Subscription(
        id: 's',
        expireEpochSec: nowSec + (3.2 * 86400).round(),
      );
      expect(sub.remainingDays, 3);
      expect(sub.quotaLow, isTrue,
          reason: 'at most 72 h + a fraction remains — '
              'the warning must fire');
      final sub2 = Subscription(
        id: 's',
        expireEpochSec: nowSec + (10.9 * 86400).round(),
      );
      expect(sub2.remainingDays, 10);
      expect(sub2.quotaLow, isFalse);
    });

    test('M17 premise: quotaLow computes true for an '
        'expiry-only subscription', () {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final sub = Subscription(
        id: 's',
        totalBytes: 0,
        expireEpochSec: nowSec + 2 * 86400,
      );
      expect(sub.quotaLow, isTrue,
          reason: 'the model knew — the 2095 UI dropped it');
    });
  });

  group('L9 — subscription health counts', () {
    test('healthOf separates tested from total', () {
      final sub = Subscription(id: 's');
      final h = sub.healthOf([
        _p('a', delayMs: 50),
        _p('b', delayMs: 80),
        _p('c', delayFailed: true),
        _p('d'),
        _p('e'),
      ]);
      expect(h.alive, 2);
      expect(h.tested, 3);
      expect(h.dead, isFalse);
    });
  });

  group('M19 — counters reported, not defaulted', () {
    test('Lantern/OpenVPN states flag absent counters', () {
      final l = LanternState.fromMap(const {'running': true});
      expect(l.countersReported, isFalse);
      expect(l.upBytes, 0);
      final l2 = LanternState.fromMap(const {'up': 5, 'down': 7});
      expect(l2.countersReported, isTrue);
      final o = OpenVpnState.fromMap(const {'running': true});
      expect(o.countersReported, isFalse);
      final o2 = OpenVpnState.fromMap(const {'up': 1, 'down': 2});
      expect(o2.countersReported, isTrue);
    });

    test('the shell budget reads null for unmeasured '
        'engines (pin)', () {
      final shell = File('lib/ui/ember/ember_shell.dart').readAsStringSync();
      expect(shell, contains('_lantern.state.countersReported'));
      expect(shell, contains('_openvpn.state.countersReported'));
      expect(shell, contains('_budgetUnmeasurableNoted'));
    });
  });

  group('M25 — budget warn flag resets on ok (pin)', () {
    test('the ok branch resets _budgetWarned', () {
      final shell = File('lib/ui/ember/ember_shell.dart').readAsStringSync();
      final tick = shell.substring(shell.indexOf('void _budgetTick'));
      final okBranch = tick.substring(tick.indexOf('case BudgetVerdict.ok:'));
      expect(okBranch, contains('_budgetWarned = false;'));
    });
  });

  group('L10 — quick preset candidates', () {
    test('fastestCandidates orders measured best-first', () {
      final pool = [
        _p('slow', delayMs: 300),
        _p('unmeasured'),
        _p('fast', delayMs: 40),
        _p('mid', delayMs: 120),
      ];
      expect(
        fastestCandidates(pool).map((p) => p.id),
        ['fast', 'mid', 'slow'],
      );
    });

    test('randomCandidates prefers the alive pool', () {
      final pool = [
        _p('a', delayMs: 10),
        _p('b', delayMs: 20),
        _p('dead', delayFailed: true),
      ];
      final picks = randomCandidates(pool, Random(7));
      expect(picks.map((p) => p.id).toSet(), {'a', 'b'});
    });

    test('presetFailureText is plain, never raw', () {
      expect(
        presetFailureText(StateError('wg-all-peers-failed')),
        contains('No peer'),
      );
      expect(
        presetFailureText(StateError('some raw internal detail')),
        isNot(contains('raw internal')),
      );
      expect(
        presetFailureText(Exception('boom')),
        contains('could not start'),
      );
    });
  });

  group('L11 — update channel invalidation', () {
    test('a channel switch drops the fetched release',
        () async {
      final settings = AppSettings();
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
      // Build 2106 (journey audit F-09): the package build
      // number is the comparison's only source now (no
      // define fallback) — the harness supplies the
      // platform's answer, as updaterIn does in the 2075
      // tests.
      final u = EmberUpdater(
        settings: settings,
        dataDir: '/tmp',
        fetcher: (_) async => releaseJson,
      )..packageBuild = 2071;
      addTearDown(u.dispose);
      await u.check(manual: true);
      expect(u.state, EmberUpdateState.available);
      expect(u.release, isNotNull);
      settings.update(updateChannel: 'beta');
      u.noteChannelChanged();
      expect(u.release, isNull,
          reason: 'the stable release must not stay on '
              'offer on the beta channel');
      expect(u.state, EmberUpdateState.idle);
      // Switching back and re-checking works normally.
      settings.update(updateChannel: 'stable');
      u.noteChannelChanged();
      await u.check(manual: true);
      expect(u.state, EmberUpdateState.available);
    });
  });

  group('L14 — pairing collector foreign chunks', () {
    String chunk(int index, int total, String part) =>
        'EMBERPAIR/$index/$total/$part';

    test('a foreign total is detectable and resettable', () {
      final c = PairingCollector();
      expect(c.add(chunk(1, 3, 'aaa')), isTrue);
      expect(c.add(chunk(1, 5, 'xxx')), isFalse);
      expect(c.isForeignChunk(chunk(2, 5, 'yyy')), isTrue);
      expect(c.received, 1,
          reason: 'the foreign chunk did not poison the set');
      c.reset();
      expect(c.received, 0);
      expect(c.total, isNull);
      expect(c.add(chunk(1, 5, 'xxx')), isTrue,
          reason: 'after reset the other transfer collects');
    });

    test('the gallery route exists on the receive page '
        '(pin, L15)', () {
      final src = File('lib/ui/ember/pairing.dart').readAsStringSync();
      expect(src, contains('decodeQrValuesFromImageFile'));
      expect(src, contains("'From gallery'"));
      expect(src, contains("'Start over'"));
    });
  });

  group('L16 — QR gallery helper (pin)', () {
    test('the helper disposes its controller and the '
        'scan page uses it', () {
      final src = File('lib/ui/ember/qr_pages.dart').readAsStringSync();
      expect(src, contains('decodeQrValuesFromImageFile'));
      expect(src, contains('await controller.dispose();'));
    });
  });

  group('L8 — offers from every catch branch (pin)', () {
    test('eleven offer sites: both branches of every '
        'toggle', () {
      final shell = File('lib/ui/ember/ember_shell.dart').readAsStringSync();
      // Build 2156 re-point: 11 -> 13 — the URnetwork
      // toggle adds its two branches like every toggle.
      expect('_offerAlternative(context'.allMatches(shell).length, 13);
    });
  });

  group('L21 — editor caps (pin)', () {
    test('aid and bandwidth carry the module maxima', () {
      final src = File('lib/ui/ember/profile_editor.dart').readAsStringSync();
      expect(src, contains("check('aid', 'Alter ID', min: 0, max: 65535)"));
      expect(src, contains("check('upMbps', 'Upload speed', min: 0, max: 100000)"));
      expect(
        src,
        contains("check('downMbps', 'Download speed', min: 0, max: 100000)"),
      );
    });
  });

  group('L3 — the watchdog honours an OFF landing '
      'mid-escalation', () {
    test('no rotate after the switch flips during a probe',
        () async {
      var rotateCalls = 0;
      var probeCalls = 0;
      Completer<void>? probeGate;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'),
              (call) async {
        switch (call.method) {
          case 'xrayTunnelCheck':
            probeCalls++;
            if (probeCalls == 2) {
              probeGate = Completer<void>();
              await probeGate!.future;
            }
            return -1;
          case 'xrayRotateConfig':
            rotateCalls++;
            return true;
          case 'xrayState':
            return <String, dynamic>{
              'running': true,
              'name': 't',
              'sinceMs': 0,
              'upBytes': 0,
              'downBytes': 0,
              'rotationGen': 99,
            };
          default:
            return null;
        }
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel('app/android'), null);
      });

      final c = XrayController();
      final profile = _p('wd');
      c.profiles.add(profile);
      c.selectedProfileId = profile.id;
      // Build 2114: the watchdog defaults OFF now (defaults
      // reset) — this test grades its mid-escalation OFF
      // landing, so the setup turns it ON explicitly.
      c.settings.stallWatchdog = true;
      XrayState sample(int up, int down) => XrayState(
            running: true,
            name: 't',
            sinceMs: DateTime.now().millisecondsSinceEpoch - 60000,
            upBytes: up,
            downBytes: down,
          );

      await c.testWatchdogTick(sample(100, 100)); // bases
      await Future<void>.delayed(const Duration(milliseconds: 6200));
      await c.testWatchdogTick(sample(200, 100)); // probe 1 fails
      expect(probeCalls, 1);
      final tick3 = c.testWatchdogTick(sample(300, 100));
      // The second probe is in flight; flip the switch off.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      c.settings.stallWatchdog = false;
      probeGate!.complete();
      await tick3;
      expect(rotateCalls, 0,
          reason: 'the escalation stood down — the OFF '
              'landing mid-probe was honoured');

      // Control: with the switch back ON, the same stall
      // escalates — the setup really can rotate.
      c.settings.stallWatchdog = true;
      await c.testWatchdogTick(sample(400, 100)); // probe 3 fails (1)
      await c.testWatchdogTick(sample(500, 100)); // probe 4 fails (2)
      expect(rotateCalls, greaterThan(0),
          reason: 'control: the stall escalates while ON');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
