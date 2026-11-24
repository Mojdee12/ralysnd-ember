// Build 2060 — grouped Medium/Low sweep, part 3 (final push to the 80% floor).
// Settings invisibility (mux/fragment/sub refresh rows), fallback-cooldown
// persistence, §7 2049 wording vs the _dnsSection gate, housekeeping
// (Xray worker shutdown, Psiphon onDestroy tunnel stop, OpenVPN session
// guard already present, XrayTester validateConfig orphan reap).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Profile wsProfile() => Profile(
      id: 'p',
      protocol: Protocol.vless,
      name: 't',
      address: 'node.example.com',
      port: 443,
      uuidOrPassword: '11111111-1111-1111-1111-111111111111',
      security: 'tls',
      network: 'ws',
      host: 'cdn.example.com',
      path: '/ws',
      sni: 'cdn.example.com',
    );

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String ktSrc(String rel) => File(
      'android/app/src/main/kotlin/com/ralysnd/ember/$rel',
    ).readAsStringSync();

List<String> dnsServers(XraySettings s) {
  final cfg = decode(buildTunnelConfig(wsProfile(), s));
  return (cfg['dns']['servers'] as List).map((e) => '$e').toList();
}

void main() {
  group('Settings invisibility (build 2060)', () {
    test('mux / fragment / subscription-refresh rows exist in Settings', () {
      final settings = dartSrc('ui/ember/ember_settings.dart');
      for (final label in const [
        'Mux concurrency',
        'Fragment packets',
        'Fragment length',
        'Fragment interval',
        'Subscription refresh',
      ]) {
        expect(settings, contains(label), reason: 'missing row: $label');
      }
      // The rows write the model fields they display.
      expect(settings, contains('s.muxConcurrency = n'));
      expect(settings, contains("s.fragmentPackets = p"));
      expect(settings, contains('s.fragmentLength = n'));
      expect(settings, contains('s.fragmentInterval = n'));
      expect(settings, contains('s.subAutoUpdateHours = n'));
    });

    test('mux/fragment rows only show with their toggle on', () {
      final settings = dartSrc('ui/ember/ember_settings.dart');
      expect(settings, contains('if (s.muxEnabled)'));
      expect(settings, contains('if (s.fragmentEnabled)'));
    });
  });

  group('Fallback-cooldown persistence (build 2060)', () {
    test('XraySettings round-trips fallbackFailedAtMs', () {
      final s = XraySettings()
        ..fallbackFailedAtMs = {
          'p1': 1794650000000,
          'p2': 1794650001000,
        };
      final restored = XraySettings.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      expect(restored.fallbackFailedAtMs, {
        'p1': 1794650000000,
        'p2': 1794650001000,
      });
    });

    test('fromJson ignores non-numeric cooldown entries', () {
      final s = XraySettings.fromJson({
        'fallbackFailedAtMs': {'p1': 1794650000000, 'p2': 'junk'},
      });
      expect(s.fallbackFailedAtMs, {'p1': 1794650000000});
    });

    test('controller writes the cooldown through to settings', () {
      final controller = dartSrc('xray/xray_controller.dart');
      expect(controller, contains('settings.fallbackFailedAtMs[profileId]'));
      expect(controller, contains('_hydrateCooldowns()'));
      expect(controller, contains('settings.fallbackFailedAtMs.removeWhere'));
    });
  });

  group('2049 wording vs _dnsSection gate (build 2060; the gate '
      'itself removed in build 2101)', () {
    // Build 2101 (owner order 2026-11-18): the built-in
    // fallback this group policed the wording of is REMOVED —
    // the pins flip to the removal, in every shape the old
    // gate used to cover.
    test('default shape carries NO built-in TCP fallback (2101)', () {
      expect(dnsServers(XraySettings()), isNot(contains('tcp://9.9.9.9')));
      // Build 2113: the default list is the single Cloudflare
      // DoH entry (the 2111 UDP-first pair is gone); the
      // policed point stands — no tcp://9.9.9.9 anywhere.
      expect(dnsServers(XraySettings()), [
        'https://cloudflare-dns.com/dns-query',
      ]);
    });

    test('fakeDNS on changes nothing about that (2101)', () {
      final s = XraySettings()..fakeDns = true;
      expect(dnsServers(s), isNot(contains('tcp://9.9.9.9')));
    });

    test('DoQ transport changes nothing about that (2101)', () {
      final s = XraySettings()..remoteDnsProto = 'doq';
      expect(dnsServers(s), isNot(contains('tcp://9.9.9.9')));
    });

    test('the comment records the removal and its order', () {
      final builder = dartSrc('xray/config_builder.dart');
      expect(builder, contains('REMOVED in build 2101'));
      expect(builder, contains('disableFallbackIfMatch'));
    });
  });

  group('Housekeeping (build 2060)', () {
    test('XrayVpnService.onDestroy shuts the worker executor down', () {
      final kt = ktSrc('XrayVpnService.kt');
      final destroy = kt.indexOf('override fun onDestroy()');
      expect(destroy, isNot(-1));
      final block = kt.substring(destroy, kt.indexOf('super.onDestroy()', destroy));
      expect(block, contains('worker.shutdown()'));
    });

    test('PsiphonVpnService.onDestroy stops the tunnel, not just processes', () {
      final kt = ktSrc('PsiphonVpnService.kt');
      final destroy = kt.indexOf('override fun onDestroy()');
      expect(destroy, isNot(-1));
      final block = kt.substring(destroy, kt.indexOf('super.onDestroy()', destroy));
      // Build 2091: the stop goes through stopProcesses() —
      // bridge first, then the core, then the TUN fd — and the
      // ladder scheduler is shut down. stopTunnel() itself is
      // the session teardown; onDestroy reaches the core stop
      // through stopProcesses, not a bare process kill.
      expect(block, contains('stopProcesses()'));
      expect(block, contains('ladderScheduler.shutdownNow()'));
      final stop = kt.substring(kt.indexOf('private fun stopProcesses()'));
      expect(stop, contains('Tun2SocksManager.stop()'));
      expect(stop, contains('stopPsiphonCore()'));
      expect(stop, contains('tunPfd?.close()'));
    });

    test('OpenVpnService.stopTunnel guards the null session', () {
      expect(
        ktSrc('OpenVpnService.kt'),
        contains('val s = session ?: return'),
      );
    });

    test('XrayTester.validateConfig reaps the -test process on every path', () {
      final kt = ktSrc('XrayTester.kt');
      final start = kt.indexOf('fun validateConfig');
      expect(start, isNot(-1));
      final body = kt.substring(start, kt.indexOf('fun tunnelCheck', start));
      expect(body, contains('finally'));
      expect(body, contains('proc?.destroyForcibly()'));
      // The wait comes before the read, so a hung core cannot wedge
      // the stdout read and strand the process. (Needle includes
      // bufferedReader() so the comment above, which names readText,
      // does not match first.)
      expect(
        body.indexOf('waitFor(15'),
        lessThan(body.indexOf('bufferedReader().readText()')),
      );
    });
  });
}
