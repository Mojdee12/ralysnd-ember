// Build 2116, batch B1 — Mozilla: honest status, poller
// error counting, renewal journaling, routing-lists
// surfacing; plus the two test gaps the batch closes
// (2105-R5 widget PUT-payload, 2105-R9 provider-DNS UDP
// deadline).
//
// - B1-1: a running session no test has confirmed reads
//   "Connected — not answering" past its window
//   (CoreController.runningUnconfirmed + the shell word).
// - B1-3 (Dart half): pass boundaries produce a journal
//   line with the session age and the new countdown
//   (CoreStatus.passBoundaryLine).
// - B1-4 (Dart half): with routing on and the lists
//   missing, the Mozilla section shows the state + Retry.
// - R5: the Mozilla section's controls write the config
//   fields they claim to (the PUT payload is asserted,
//   not the source shape).
// - R9: the provider-DNS UDP deadline is ABSOLUTE under
//   a junk-datagram flood (loopback), and a well-behaved
//   loopback resolver still answers.
//
// All fixtures use dummy values.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/core/models.dart';
import 'package:firefox_vpn/lantern/lantern_controller.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/ui/ember/ember_settings.dart';
import 'package:firefox_vpn/ui/ember/map_widgets.dart';
import 'package:firefox_vpn/xray/provider_dns.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';

/// An in-memory core API: settings in a map, saves
/// captured, routing lists absent.
class FakeApi extends CoreApi {
  FakeApi() : super(CoreEndpoint(Uri.parse('http://127.0.0.1:9'), 't'));

  Map<String, Object?> config = {
    'routing': {'enabled': false},
    'dns': {
      'servers': ['1.1.1.1'],
      'ip_version': 'auto',
    },
    'proxy': {'transport': 'h3', 'fast_failover': false},
  };
  Map<String, Object?>? saved;
  int updateCalls = 0;

  static Map<String, Object?> copy(Map<String, Object?> m) =>
      jsonDecode(jsonEncode(m)) as Map<String, Object?>;

  @override
  Future<Map<String, Object?>> settings() async => copy(config);

  @override
  Future<void> saveSettings(Map<String, Object?> c) async {
    saved = copy(c);
    config = copy(c);
  }

  // A live core for the controller's polling: without
  // these, refresh() fails against the test binding's
  // mock HTTP (400), the controller counts the core lost
  // and _require() starts throwing into later edits.
  @override
  Future<CoreStatus> status() async => CoreStatus.fromJson({
    'state': {'phase': 'stopped', 'message': ''},
    'system_proxy_supported': false,
    'selection': '',
    'accounts': {'total': 1, 'ready': 1},
  });

  @override
  Future<AccountList> accounts() async =>
      AccountList.fromJson({'accounts': const []});

  @override
  Future<RoutingInfo> routing() async =>
      RoutingInfo.fromJson({'enabled': true, 'files': const [], 'sources': const []});

  @override
  Future<RoutingInfo> updateRoutingLists() async {
    updateCalls++;
    return routing();
  }
}

CoreStatus mozStatus({
  required DateTime startedAt,
  required int passExpiresAt,
  Map<String, Object?>? lastTest,
}) => CoreStatus.fromJson({
  'state': {'phase': 'running', 'message': ''},
  'system_proxy_supported': false,
  'selection': '',
  'proxy': {
    'listen': '127.0.0.1:10810',
    'started_at': startedAt.toUtc().toIso8601String(),
  },
  'last_test': ?lastTest,
  'pass_expires_at': passExpiresAt,
  'accounts': {'total': 1, 'ready': 1},
});

void main() {
  group('B1-3 pass boundary lines (AB-04)', () {
    final now = DateTime.now();
    final expiry = now.millisecondsSinceEpoch ~/ 1000 + 600;

    test('the session start lines with age and countdown', () {
      final s = mozStatus(
        startedAt: now.subtract(const Duration(minutes: 2)),
        passExpiresAt: expiry,
      );
      final line = s.passBoundaryLine(0, now);
      expect(line, isNotNull);
      expect(line, contains('session age 2 min'));
      expect(line, contains('pass expires in'));
    });

    test('a renewal landing lines as renewed', () {
      final s = mozStatus(
        startedAt: now.subtract(const Duration(minutes: 9)),
        passExpiresAt: expiry,
      );
      final line = s.passBoundaryLine(expiry - 600, now);
      expect(line, contains('pass renewed'));
      expect(line, contains('session age 9 min'));
    });

    test('no movement, no line', () {
      final s = mozStatus(startedAt: now, passExpiresAt: expiry);
      expect(s.passBoundaryLine(expiry, now), isNull);
    });
  });

  group('B1-1 runningUnconfirmed (AB-02)', () {
    CoreController controllerFor(CoreStatus status) {
      final api = FakeApi();
      final c = CoreController(() async => api, pollInterval: const Duration(hours: 1));
      addTearDown(c.dispose);
      c.status = status;
      return c;
    }

    test('running, untested, past the window: unconfirmed', () {
      final c = controllerFor(
        mozStatus(
          startedAt: DateTime.now().subtract(const Duration(minutes: 3)),
          passExpiresAt: 0,
        ),
      );
      expect(c.runningUnconfirmed, isTrue);
    });

    test('running, untested, inside the window: not yet', () {
      final c = controllerFor(
        mozStatus(startedAt: DateTime.now(), passExpiresAt: 0),
      );
      expect(c.runningUnconfirmed, isFalse);
    });

    test('running and confirmed by a passing test: confirmed', () {
      final started = DateTime.now().subtract(const Duration(minutes: 3));
      final c = controllerFor(
        mozStatus(
          startedAt: started,
          passExpiresAt: 0,
          lastTest: {
            'at': DateTime.now().toUtc().toIso8601String(),
            'ok': true,
            'http_status': 204,
          },
        ),
      );
      expect(c.runningUnconfirmed, isFalse);
    });

    test('the shell word exists (pin)', () {
      final shell = File('lib/ui/ember/ember_shell.dart').readAsStringSync();
      expect(shell, contains("'Connected — not answering'"));
      expect(shell, contains('core.runningUnconfirmed'));
      expect(shell, contains("core.journalLine = "));
    });

    test('the poller counts API errors into _lost (pin)', () {
      final src = File('lib/core/core_controller.dart').readAsStringSync();
      expect(src, contains('_apiErrors >= 3'));
      expect(src, contains('CoreProblem.notAnswering'));
    });
  });

  group('R5 + B1-4 — the Mozilla section writes what it shows', () {
    testWidgets('routing, ip_version and fast_failover PUT payloads', (
      tester,
    ) async {
      final api = FakeApi();
      final core = CoreController(
        () async => api,
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(core.dispose);
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final xray = XrayController();
      addTearDown(xray.dispose);
      final psiphon = PsiphonController();
      addTearDown(psiphon.dispose);
      final lantern = LanternController();
      addTearDown(lantern.dispose);
      final openvpn = OpenVpnController();
      addTearDown(openvpn.dispose);
      // Resolve the controller's API endpoint first:
      // CoreController._require() throws until the factory
      // has run once (a refresh does it; the fake's status
      // call fails harmlessly afterwards).
      await tester.runAsync(() => core.refresh());
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: EmberSettings(
              core: core,
              xray: xray,
              psiphon: psiphon,
              lantern: lantern,
              openvpn: openvpn,
              settings: AppSettings()..emberMode = 0,
            ),
          ),
        ),
      );
      // Wait for the section's load: the row renders at once
      // but its toggle stays disabled (null value) until the
      // core's answer lands.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        final toggles = find.descendant(
          of: find.ancestor(
            of: find.text('Smart routing'),
            matching: find.byType(MapSettingRow),
          ),
          matching: find.byType(MapToggle),
        );
        if (toggles.evaluate().isNotEmpty &&
            tester.widget<MapToggle>(toggles).onChanged != null) {
          break;
        }
      }
      expect(find.text('Smart routing'), findsOneWidget);

      // Smart routing ON → routing.enabled true in the PUT,
      // and the missing-lists state surfaces (B1-4).
      final routingRow = find.ancestor(
        of: find.text('Smart routing'),
        matching: find.byType(MapSettingRow),
      );
      await tester.ensureVisible(routingRow);
      await tester.pump();
      await tester.tap(
        find.descendant(of: routingRow, matching: find.byType(MapToggle)),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (api.saved != null) break;
      }
      expect(api.saved, isNotNull);
      expect((api.saved!['routing'] as Map)['enabled'], isTrue);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.text('Routing lists').evaluate().isNotEmpty) break;
      }
      expect(find.text('Routing lists'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      // IP version → dns.ip_version in the PUT.
      api.saved = null;
      await tester.ensureVisible(find.text('V6 first'));
      await tester.pump();
      await tester.tap(find.text('V6 first'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (api.saved != null) break;
      }
      expect((api.saved!['dns'] as Map)['ip_version'], 'ipv6_first');

      // Fast failover → proxy.fast_failover in the PUT.
      api.saved = null;
      final ffRow = find.ancestor(
        of: find.text('Fast failover'),
        matching: find.byType(MapSettingRow),
      );
      await tester.ensureVisible(ffRow);
      // The previous edit's busy flag must clear before
      // this toggle answers.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        final t = find.descendant(of: ffRow, matching: find.byType(MapToggle));
        if (t.evaluate().isNotEmpty &&
            tester.widget<MapToggle>(t).onChanged != null) {
          break;
        }
      }
      await tester.tap(
        find.descendant(of: ffRow, matching: find.byType(MapToggle)),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (api.saved != null) break;
      }
      expect((api.saved!['proxy'] as Map)['fast_failover'], isTrue);
    });
  });

  group('R9 — provider DNS UDP deadline (2105-R9)', () {
    // Both tests below need working loopback UDP. Some
    // sandboxes block UDP sends outright ('Operation not
    // permitted'); there the resolver can only ever answer
    // [] and the tests would pass vacuously or fail
    // spuriously — skip honestly instead.
    Future<bool> loopbackUdpWorks() async {
      RawDatagramSocket? a;
      RawDatagramSocket? b;
      try {
        a = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
        b = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
        final got = Completer<bool>();
        b.listen((event) {
          if (event == RawSocketEvent.read && !got.isCompleted) {
            got.complete(b!.receive() != null);
          }
        });
        a.send(const [1], InternetAddress.loopbackIPv4, b.port);
        return await got.future.timeout(
          const Duration(milliseconds: 400),
          onTimeout: () => false,
        );
      } catch (_) {
        return false;
      } finally {
        a?.close();
        b?.close();
      }
    }


    test(
      'a junk flood cannot stretch the shared deadline',
      () async {
        if (!await loopbackUdpWorks()) {
          markTestSkipped('loopback UDP is blocked in this environment');
          return;
        }
        final server = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(server.close);
        final sprayers = <Timer>[];
        addTearDown(() {
          for (final t in sprayers) {
            t.cancel();
          }
        });
        server.listen((event) {
          if (event != RawSocketEvent.read) return;
          final dg = server.receive();
          if (dg == null) return;
          // Spray junk (wrong IDs) at the asker for 3 s:
          // a per-gap timer would keep resetting and hold
          // the resolution open well past its deadline.
          final junk = Uint8List.fromList(List.filled(24, 0xAB));
          final t = Timer.periodic(const Duration(milliseconds: 40), (_) {
            server.send(junk, dg.address, dg.port);
          });
          sprayers.add(t);
          Timer(const Duration(seconds: 3), t.cancel);
        });
        final sw = Stopwatch()..start();
        final answers = await resolveViaProviderDns(
          'example.com',
          '127.0.0.1:${server.port}',
          timeout: const Duration(milliseconds: 700),
        );
        sw.stop();
        expect(answers, isEmpty);
        expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('a well-behaved loopback resolver answers', () async {
      if (!await loopbackUdpWorks()) {
        markTestSkipped('loopback UDP is blocked in this environment');
        return;
      }
      final server = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(server.close);
      server.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = server.receive();
        if (dg == null) return;
        final q = dg.data;
        if (q.length < 12) return;
        final qtype = (q[q.length - 4] << 8) | q[q.length - 3];
        final resp = BytesBuilder()
          ..add(q.sublist(0, q.length)); // header + question echo
        final bytes = resp.toBytes();
        bytes[2] |= 0x80; // QR
        bytes[3] |= 0x80; // RA
        if (qtype == 1) {
          bytes[6] = 0;
          bytes[7] = 1; // ANCOUNT 1
          final full = BytesBuilder()
            ..add(bytes)
            ..add([
              0xC0, 0x0C, // name pointer to the question
              0, 1, // A
              0, 1, // IN
              0, 0, 0, 60, // TTL
              0, 4, // RDLENGTH
              203, 0, 113, 7,
            ]);
          server.send(full.toBytes(), dg.address, dg.port);
        } else {
          server.send(bytes, dg.address, dg.port);
        }
      });
      final answers = await resolveViaProviderDns(
        'example.com',
        '127.0.0.1:${server.port}',
        timeout: const Duration(seconds: 3),
      );
      expect(answers, contains('203.0.113.7'));
    });
  });
}
