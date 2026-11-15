import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/lantern/lantern_controller.dart';
import 'package:firefox_vpn/lantern/lantern_platform.dart';

/// Build 2052 — the Lantern connect fix (owner-reported,
/// Critical-class; diagnosis
/// ~/workspace/ember-app/lantern-connect-diagnosis-2026-11-14.md).
///
/// The binary was never the problem (byte-identical to ralysnd's
/// working copy); the host integration was: a 45 s kill beat the
/// first config fetch, the bootstrap leg restarted the core with
/// an unproven start flag instead of rerouting the running core's
/// stdin, the kept-config parser read keys radiance never writes,
/// the "listening" contract needed an exact match, and "connected"
/// was declared at TUN-up with no data-plane proof. This suite
/// pins the ladder, the messages, and the native-side shape of
/// every fix — the Kotlin behaviour itself is compiled by the
/// release build (no JVM test harness exists in this tree).
void main() {
  group('Lantern ladder budgets (diagnosis Causes 1–2)', () {
    test('warm: a kept list listens in seconds', () {
      expect(lanternWarmBudget, const Duration(seconds: 20));
    });

    test('cold: 20 s direct, then the leg, 240 s total', () {
      expect(lanternColdDirectBudget, const Duration(seconds: 20));
      expect(lanternColdBudget, const Duration(seconds: 240));
      expect(lanternColdDirectBudget, lessThan(lanternColdBudget));
    });
  });

  group('Lantern give-up messages', () {
    test('warm names the 20 s budget and the kept list', () {
      final m = lanternGiveUpMessage(warm: true, viaWarp: false);
      expect(m, contains('20 s'));
      expect(m, contains('kept server list'));
    });

    test('cold through WARP names the four minutes', () {
      final m = lanternGiveUpMessage(warm: false, viaWarp: true);
      expect(m, contains('four minutes'));
      expect(m, contains('not even through WARP'));
      expect(m, contains('kept'));
    });

    test('cold direct never claims WARP was used', () {
      final m = lanternGiveUpMessage(warm: false, viaWarp: false);
      expect(m, contains('four minutes'));
      expect(m, contains('kept'));
      expect(m, isNot(contains('WARP')));
    });
  });

  group('LanternState.hasKeptConfig (diagnosis Cause 3)', () {
    test('a kept fronted list is warm', () {
      expect(const LanternState(keptServers: 3).hasKeptConfig, isTrue);
    });

    test('a kept masque list is warm', () {
      expect(const LanternState(keptMasque: 1).hasKeptConfig, isTrue);
    });

    test('no readable kept config is cold', () {
      expect(const LanternState().hasKeptConfig, isFalse);
      expect(
        const LanternState(keptServers: 0, keptMasque: 0).hasKeptConfig,
        isFalse,
      );
    });
  });

  group('Source pins: the native Lantern host (diagnosis §5)', () {
    String read(String path) => File(path).readAsStringSync();

    test('the ladder budgets live in LanternCore', () {
      final kt = read(
        'android/app/src/main/kotlin/com/ralysnd/ember/LanternVpnService.kt',
      );
      expect(kt, contains('WARM_LISTEN_MS = 20_000L'));
      expect(kt, contains('COLD_DIRECT_MS = 20_000L'));
      expect(kt, contains('COLD_GIVEUP_MS = 240_000L'));
      expect(kt, contains('DATA_TIMEOUT_MS = 45_000L'));
      expect(kt, contains('waitForCore(budgetMs)'));
    });

    test('the bootstrap rides stdin via, never a restart flag', () {
      final kt = read(
        'android/app/src/main/kotlin/com/ralysnd/ember/LanternVpnService.kt',
      );
      expect(kt, contains('fun sendVia(port: Int)'));
      expect(kt, contains('command("via 127.0.0.1:\$port")'));
      expect(kt, contains('fun sendViaDirect()'));
      expect(kt, contains('command("via direct")'));
      // The unproven start-flag mechanism is deleted, not dormant.
      expect(kt, isNot(contains('"-fetchvia"')));
      expect(kt, isNot(contains('fetchViaPort')));
      expect(kt, isNot(contains('EXTRA_FETCHVIA')));
      expect(kt, isNot(contains('EXTRA_CLIENTIP')));
    });

    test('the kept-config parser reads options/outbounds/endpoints', () {
      final kt = read(
        'android/app/src/main/kotlin/com/ralysnd/ember/LanternVpnService.kt',
      );
      expect(kt, contains('optJSONObject("options")'));
      expect(kt, contains('count("outbounds")'));
      expect(kt, contains('count("endpoints")'));
      expect(kt, contains('optString("server")'));
      expect(kt, isNot(contains('root.has("servers")')));
    });

    test('the listening contract is a prefix match', () {
      final kt = read(
        'android/app/src/main/kotlin/com/ralysnd/ember/LanternVpnService.kt',
      );
      expect(kt, contains('body.startsWith("listening")'));
      expect(kt, isNot(contains('body == "listening"')));
    });

    test('the data-plane proof gates the TUN raise', () {
      final kt = read(
        'android/app/src/main/kotlin/com/ralysnd/ember/LanternVpnService.kt',
      );
      expect(kt, contains('fun carriesWarm('));
      expect(kt, contains('www.youtube.com'));
      expect(kt, contains('www.instagram.com'));
      expect(kt, contains('startHandshake()'));
      expect(kt, contains('carriesWarm(LanternCore.SOCKS_PORT'));
      expect(kt, contains('no server carried any traffic in 45 s'));
    });

    test('HOME points at the config dir parent; DNS is filtered', () {
      final kt = read(
        'android/app/src/main/kotlin/com/ralysnd/ember/LanternVpnService.kt',
      );
      expect(kt, contains('pb.environment()["HOME"] = workDir(context).absolutePath'));
      expect(kt, contains('NET_CAPABILITY_INTERNET'));
      expect(kt, contains('"[\$it]:53"'));
    });

    test('MainActivity exposes via and drops the dead args', () {
      final kt = read(
        'android/app/src/main/kotlin/com/ralysnd/ember/MainActivity.kt',
      );
      expect(kt, contains('"lanternVia"'));
      expect(kt, contains('"lanternViaDirect"'));
      expect(kt, contains('LanternCore.sendVia(port)'));
      expect(kt, contains('LanternCore.sendViaDirect()'));
      expect(kt, isNot(contains('call.argument<Int>("fetchVia")')));
      expect(kt, isNot(contains('call.argument<String>("clientIp")')));
    });

    test('the Dart side drives the ladder, never the restart', () {
      final c = read('lib/lantern/lantern_controller.dart');
      expect(c, contains('hasKeptConfig'));
      expect(c, contains('lanternColdBudget'));
      expect(c, contains('lanternColdDirectBudget'));
      expect(c, contains('LanternPlatform.via('));
      expect(c, contains('viaDirect()'));
      expect(c, contains('lanternGiveUpMessage('));
      expect(c, isNot(contains('fetchVia:')));
      // The leg raise no longer stops Lantern first (disconnect()
      // still stops it — that is the only remaining stop call in
      // the connect path, and it belongs to disconnect()).
      expect(
        c,
        isNot(contains('Make sure the failed direct attempt is fully down')),
      );
      final p = read('lib/lantern/lantern_platform.dart');
      expect(p, contains("'lanternVia'"));
      expect(p, contains("'lanternViaDirect'"));
    });
  });
}
