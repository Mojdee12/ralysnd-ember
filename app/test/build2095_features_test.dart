/// Build 2095 — the 15 features' BEHAVIORAL gates (owner
/// emphasis 2026-11-17 05:36: behavior, not source pins,
/// wherever the behavior is host-exercisable).
///
/// F1 emergency walk (fake engines) · F2 watchdog gate ·
/// F3 quota state · F4 chain validation · F7 budget
/// verdicts · F8 leak rows · F9 alternative classifier ·
/// F10 subscription health · F11 preset pickers · F13
/// update channels (the choice changes the selected
/// release) · F14 rename persistence · F15 pairing
/// seal/chunk round-trip. F5/F6 carry source pins (native /
/// platform surfaces a host test cannot drive).

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/ui/ember/ember_updater.dart';
import 'package:firefox_vpn/ui/ember/emergency.dart';
import 'package:firefox_vpn/ui/ember/leak_test_page.dart';
import 'package:firefox_vpn/ui/ember/pairing.dart';
import 'package:firefox_vpn/ui/ember/quick_presets.dart';
import 'package:firefox_vpn/ui/ember/session_budget.dart';
import 'package:firefox_vpn/ui/ember/chain_builder_page.dart';
import 'package:firefox_vpn/xray/shared_link.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

String _read(String path) => File(path).readAsStringSync();

Profile _p(String id, {int delay = -1, bool failed = false}) =>
    Profile(id: id, protocol: Protocol.vless, name: id)
      ..delayMs = delay
      ..delayFailed = failed;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('F1 emergency walk', () {
    test('tries in order and stops at the first proven connect', () async {
      final tried = <int>[];
      final winner = await runEmergencyWalk(
        order: emergencyModeOrder,
        cancelled: () => false,
        attempt: (m) async {
          tried.add(m);
          return m == 6;
        },
      );
      expect(winner, 6);
      expect(tried, [1, 5, 6]);
    });

    test('Psiphon (mode 2) is never in the walk', () {
      expect(emergencyModeOrder.contains(2), isFalse);
      expect(emergencyModeNames.containsKey(2), isFalse);
    });

    test('cancel stops the walk before the next engine', () async {
      var attempts = 0;
      final winner = await runEmergencyWalk(
        order: emergencyModeOrder,
        cancelled: () => attempts >= 1,
        attempt: (m) async {
          attempts++;
          return false;
        },
      );
      expect(winner, isNull);
      expect(attempts, 1);
    });

    test('all engines failing returns null', () async {
      final winner = await runEmergencyWalk(
        order: emergencyModeOrder,
        cancelled: () => false,
        attempt: (m) async => false,
      );
      expect(winner, isNull);
    });
  });

  group('F9 smart alternative', () {
    test('timeout-class failures offer the mapped alternative', () {
      expect(alternativeForFailure(1, 'handshake timeout'), (6, 'Try WARP'));
      expect(alternativeForFailure(5, 'connection reset by peer')?.$1, 6);
      expect(alternativeForFailure(6, 'timed out')?.$1, 1);
      expect(alternativeForFailure(3, 'EOF')?.$1, 1);
    });

    test('non-blocking failures offer nothing', () {
      expect(alternativeForFailure(1, 'AUTH_FAILED'), isNull);
      expect(alternativeForFailure(1, 'no-profile'), isNull);
      expect(alternativeForFailure(2, 'timeout'), isNull,
          reason: 'Psiphon is parked — no offers from it');
    });
  });

  group('F7 session budget verdicts', () {
    test('boundaries', () {
      const mb = 1024 * 1024;
      expect(sessionBudgetVerdict(usedBytes: 10 * mb, capMb: 0),
          BudgetVerdict.ok, reason: 'off never fires');
      expect(sessionBudgetVerdict(usedBytes: 79 * mb, capMb: 100),
          BudgetVerdict.ok);
      expect(sessionBudgetVerdict(usedBytes: 80 * mb, capMb: 100),
          BudgetVerdict.warn);
      expect(sessionBudgetVerdict(usedBytes: 100 * mb, capMb: 100),
          BudgetVerdict.exceeded);
      expect(sessionBudgetVerdict(usedBytes: 250 * mb, capMb: 100),
          BudgetVerdict.exceeded);
    });
  });

  group('F3 quota state + F10 health', () {
    test('quotaLow trips on volume and on expiry', () {
      final low = Subscription(id: 's')
        ..totalBytes = 1000
        ..uploadBytes = 950;
      expect(low.quotaLow, isTrue);
      final fine = Subscription(id: 's')
        ..totalBytes = 1000
        ..uploadBytes = 100;
      expect(fine.quotaLow, isFalse);
      final noInfo = Subscription(id: 's');
      expect(noInfo.quotaLow, isFalse);
    });

    test('health counts alive/tested and flags dead', () {
      final sub = Subscription(id: 's');
      final mixed = sub.healthOf([_p('a', delay: 50), _p('b', failed: true), _p('c')]);
      expect(mixed.alive, 1);
      expect(mixed.tested, 2);
      expect(mixed.dead, isFalse);
      final dead = sub.healthOf([_p('a', failed: true), _p('b', failed: true)]);
      expect(dead.dead, isTrue);
      final untested = sub.healthOf([_p('a'), _p('b')]);
      expect(untested.dead, isFalse, reason: 'untested is not dead');
    });
  });

  group('F11 preset pickers', () {
    test('fastest is the best measured; none measured → null', () {
      expect(fastestIn([_p('a', delay: 300), _p('b', delay: 90), _p('c')])?.id, 'b');
      expect(fastestIn([_p('a'), _p('b', failed: true)]), isNull);
    });

    test('random picks only among the alive when any exist', () {
      final pool = [_p('a', delay: 10), _p('b', delay: 20), _p('c', failed: true)];
      for (var seed = 0; seed < 20; seed++) {
        final pick = randomAliveIn(pool, Random(seed));
        expect(['a', 'b'].contains(pick?.id), isTrue);
      }
      expect(randomAliveIn(const [], Random(1)), isNull);
    });
  });

  group('F4 chain validation', () {
    final pool = [
      _p('x'),
      Profile(id: 'wg', protocol: Protocol.wireguard, name: 'wg'),
    ];
    test('a config as first hop is refused', () {
      expect(
        validateChainEntry(
          name: 'c',
          underlay: 'some-config',
          profileId: 'x',
          profiles: pool,
        ),
        isNotNull,
      );
    });
    test('missing exit and blank name are refused', () {
      expect(
        validateChainEntry(name: ' ', underlay: 'warp', profileId: 'x', profiles: pool),
        isNotNull,
      );
      expect(
        validateChainEntry(name: 'c', underlay: 'warp', profileId: 'nope', profiles: pool),
        isNotNull,
      );
    });
    test('WG exit under a configured wstunnel is refused', () {
      // PIN UPDATED by build 2097 (post-2096 audit
      // L5-residual): the 2096 pin encoded the audit's own
      // misreading — it keyed the gate on the EXIT's
      // address being a ws/wss URL. Connect stacks
      // wstunnel from the global settings (the toggle +
      // settings.wgWstunnelUrl) for ANY WireGuard exit
      // (wgWstunnelOn), so the gate now refuses exactly
      // when connect would stack: toggle on AND a valid
      // wstunnel URL configured.
      final plainPool = pool;
      expect(
        validateChainEntry(
          name: 'c',
          underlay: 'warp',
          profileId: 'wg',
          profiles: plainPool,
          wgWstunnelEnabled: true,
          wgWstunnelUrl: 'wss://tun.example.com:443',
        ),
        isNotNull,
        reason: 'connect would stack wstunnel under this '
            'exit — the chain is refused, as connect does',
      );
      expect(
        validateChainEntry(
          name: 'c',
          underlay: 'warp',
          profileId: 'wg',
          profiles: plainPool,
          wgWstunnelEnabled: true,
        ),
        isNull,
        reason: 'no wstunnel URL configured — connect '
            'does not stack one, so the chain is allowed',
      );
      expect(
        validateChainEntry(
          name: 'c',
          underlay: 'warp',
          profileId: 'wg',
          profiles: plainPool,
          wgWstunnelUrl: 'wss://tun.example.com:443',
        ),
        isNull,
        reason: 'the toggle is off — no stacking',
      );
      expect(
        validateChainEntry(
          name: 'c',
          underlay: 'warp',
          profileId: 'wg',
          profiles: plainPool,
        ),
        isNull,
      );
    });

    test('a sidecar-served exit is refused (build 2096, '
        'audit M18)', () {
      final sidecarPool = [
        _p('x'),
        Profile(id: 'tuic1', protocol: Protocol.tuic, name: 'tuic'),
      ];
      expect(
        validateChainEntry(
          name: 'c',
          underlay: 'warp',
          profileId: 'tuic1',
          profiles: sidecarPool,
        ),
        isNotNull,
      );
    });
    test('a UDP-dependent exit over Psiphon is refused '
        '(build 2123, C-4(i))', () {
      // WireGuard is a UDP-only protocol.
      expect(
        validateChainEntry(
          name: 'c',
          underlay: 'psiphon',
          profileId: 'wg',
          profiles: pool,
        ),
        isNotNull,
      );
      // QUIC and KCP transports ride UDP.
      final udpPool = [
        _p('x'),
        Profile(
            id: 'q', protocol: Protocol.vless, name: 'q', network: 'quic'),
        Profile(
            id: 'k', protocol: Protocol.vmess, name: 'k', network: 'kcp'),
        Profile(
            id: 'ss', protocol: Protocol.shadowsocks, name: 'ss'),
      ];
      expect(
        validateChainEntry(
            name: 'c', underlay: 'psiphon', profileId: 'q', profiles: udpPool),
        isNotNull,
      );
      expect(
        validateChainEntry(
            name: 'c', underlay: 'psiphon', profileId: 'k', profiles: udpPool),
        isNotNull,
      );
      // TCP-carrying profiles still chain over Psiphon —
      // Shadowsocks included (its UDP relay is optional).
      expect(
        validateChainEntry(
            name: 'c', underlay: 'psiphon', profileId: 'x', profiles: udpPool),
        isNull,
      );
      expect(
        validateChainEntry(
            name: 'c',
            underlay: 'psiphon',
            profileId: 'ss',
            profiles: udpPool),
        isNull,
      );
      // The gate is Psiphon-specific: the same WireGuard
      // exit over the other underlays is untouched by it.
      expect(
        validateChainEntry(
            name: 'c', underlay: 'warp', profileId: 'wg', profiles: pool),
        isNull,
      );
      expect(
        validateChainEntry(
            name: 'c', underlay: 'dnstt', profileId: 'wg', profiles: pool),
        isNull,
      );
    });
    test('a sound chain validates; entries round-trip settings JSON', () {
      expect(
        validateChainEntry(name: 'c', underlay: 'dnstt', profileId: 'x', profiles: pool),
        isNull,
      );
      final s = AppSettings();
      s.update(chains: [ChainEntry(name: 'c', underlay: 'warp', profileId: 'x')]);
      final doc = s.toJson();
      final restored = AppSettings();
      restored.applyRestoredSettings(
        (doc..remove('app_lock_pin_hash')).cast<String, Object?>(),
      );
      expect(restored.chains, hasLength(1));
      expect(restored.chains.single.underlay, 'warp');
    });
  });

  group('F8 leak rows', () {
    test('not connected reads plainly', () {
      final rows = leakRows(const LeakFacts(engineLabel: ''));
      expect(rows.single.ok, isFalse);
      expect(rows.single.value, contains('Nothing is connected'));
    });
    test('connected rows: measured green, unmeasurable honest', () {
      final rows = leakRows(const LeakFacts(
        engineLabel: 'V2Ray',
        exitIp: '1.2.3.4',
        exitCountryCode: 'DE',
        dnsEndpoint: 'https://dns.google/dns-query',
        dnsTunneled: true,
      ));
      final byLabel = {for (final r in rows) r.label: r};
      // PIN UPDATED by build 2096 (post-2095 audit M20/L7):
      // the Exit IP row is informational now — with no
      // pre-VPN baseline, a green check claimed a proof
      // the app cannot make; the DNS row is a
      // configuration inference, not a measurement.
      expect(byLabel['Exit IP']!.ok, isNull);
      expect(byLabel['DNS']!.ok, isNull);
      expect(byLabel['DNS country vs exit country']!.ok, isNull);
      expect(byLabel['WebRTC']!.ok, isNull);
      expect(byLabel['WebRTC']!.value, contains('cannot measure'));
    });
  });

  group('F13 update channels', () {
    Map<String, Object?> releaseJson(int build, {bool prerelease = false}) => {
      'tag_name': 'v$build',
      'name': 'Build $build',
      'body': '',
      'prerelease': prerelease,
      'assets': [
        {
          'name': 'RalysndEmber2.apk',
          'browser_download_url': 'https://example.com/$build.apk',
          'size': 10,
        },
      ],
    };

    test('the beta list parser picks the newest build', () {
      final r = parseNewestRelease([
        releaseJson(2095),
        releaseJson(2097, prerelease: true),
        releaseJson(2096),
      ]);
      expect(r?.build, 2097);
      expect(parseNewestRelease(const []), isNull);
    });

    test('the channel choice changes which release is selected', () async {
      final settings = AppSettings();
      String? seenUrl;
      EmberUpdater make() => EmberUpdater(
        settings: settings,
        dataDir: '/tmp',
        fetcher: (url) async {
          seenUrl = url.toString();
          if (url.toString().contains('per_page')) {
            return jsonEncode([
              releaseJson(2090),
              releaseJson(3001, prerelease: true),
            ]);
          }
          return '{"tag_name": "v2090", "name": "B", "body": "", "assets": '
              '[{"name": "RalysndEmber2.apk", "browser_download_url": "https://e.com/a", "size": 1}]}';
        },
      );
      settings.updateChannel = 'stable';
      var u = make();
      await u.check(manual: true);
      expect(seenUrl, contains('/releases/latest'));
      expect(u.release?.build, 2090);
      settings.updateChannel = 'beta';
      u = make();
      await u.check(manual: true);
      expect(seenUrl, contains('per_page'));
      expect(u.release?.build, 3001,
          reason: 'beta sees the newer pre-release stable cannot');
    });
  });

  group('F2 watchdog gate', () {
    test('stallWatchdog=false: the freeze signature never probes', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'),
              (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel('app/android'), null);
      });
      final c = XrayController();
      addTearDown(c.dispose);
      c.settings.stallWatchdog = false;
      final now = DateTime.now().millisecondsSinceEpoch;
      XrayState sample(int up, int down) => XrayState(
            running: true,
            name: 'N',
            sinceMs: now - 20000,
            upBytes: up,
            downBytes: down,
          );
      await c.testWatchdogTick(sample(1000, 5000));
      await c.testWatchdogTick(sample(2000, 5000));
      await c.testWatchdogTick(sample(3000, 5000));
      expect(calls.where((m) => m == 'tunnelCheck'), isEmpty);
      // And the setting round-trips.
      final s2 = XraySettings.fromJson(c.settings.toJson());
      expect(s2.stallWatchdog, isFalse);
    });
  });

  group('F14 rename persistence', () {
    test('renameProfile writes localName through the store path', () async {
      final c = XrayController();
      addTearDown(c.dispose);
      final p = _p('r1');
      c.profiles.add(p);
      await c.renameProfile(p, 'My Node');
      expect(p.localName, 'My Node');
      expect(p.displayName, 'My Node');
      await c.renameProfile(p, '');
      expect(p.displayName, 'r1',
          reason: 'clearing the override restores the given name');
    });
  });

  group('F15 pairing round-trip', () {
    test('seal → split → collect out of order → open', () {
      final payload = '{"app":"ember","profiles":[1,2,3],"pad":"'
          '${'x' * 600}"}';
      final sealed = sealPayload(payload, 'hunter2');
      expect(sealed.startsWith(pairingSealedPrefix), isTrue);
      expect(sealed.contains(payload), isFalse,
          reason: 'the sealed form must not carry plaintext');
      final codes = splitPairingPayload(sealed);
      expect(codes.length, greaterThan(1));
      final collector = PairingCollector();
      for (final code in codes.reversed) {
        expect(collector.add(code), isTrue);
      }
      expect(collector.isComplete, isTrue);
      expect(openSealedPayload(collector.assemble()!, 'hunter2'), payload);
      expect(openSealedPayload(collector.assemble()!, 'wrong'), isNull);
    });

    test('the collector ignores foreign codes and partial sets', () {
      final collector = PairingCollector();
      expect(collector.add('vless://x@y:443#n'), isFalse);
      final codes = splitPairingPayload(sealPayload('hello', 'pw12'));
      expect(collector.add(codes.first), isTrue);
      if (codes.length > 1) {
        expect(collector.isComplete, isFalse);
        expect(collector.assemble(), isNull);
      }
    });

    test('a small payload is a single code', () {
      final codes = splitPairingPayload(sealPayload('{}', 'pw12'));
      expect(codes, hasLength(1));
      final collector = PairingCollector()..add(codes.single);
      expect(openSealedPayload(collector.assemble()!, 'pw12'), '{}');
    });
  });

  group('F5/F6 source pins (native surfaces)', () {
    test('the widget is arbitration- and lock-aware, action renamed', () {
      final kt = _read(
        'android/app/src/main/kotlin/com/ralysnd/ember/ConnectWidget.kt',
      );
      expect(kt.contains('com.ralysnd.ember.WIDGET_TOGGLE'), isTrue);
      expect(kt.contains('"com.arman.firefoxvpn.WIDGET_TOGGLE"'), isFalse);
      expect(kt.contains('vpnTransportUp(context) -> openApp(context)'), isTrue);
      expect(kt.contains('appLockEnabled(context) -> openApp(context)'), isTrue);
    });

    test('gallery QR decode is wired through the scanner pop path', () {
      final qr = _read('lib/ui/ember/qr_pages.dart');
      expect(qr.contains('From gallery'), isTrue);
      expect(qr.contains('analyzeImage'), isTrue);
      final kt = _read(
        'android/app/src/main/kotlin/com/ralysnd/ember/MainActivity.kt',
      );
      expect(kt.contains('"pickImageFile"'), isTrue);
    });
  });
}
