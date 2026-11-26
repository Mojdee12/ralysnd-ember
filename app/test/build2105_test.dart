// Build 2105 — the feature build (owner picks 2026-11-18):
// the four Mozilla/armanlife features (browser sign-in
// fallback offer, HTTP/1.1 transport, IP-version choice,
// same-location fast failover), the traffic history chart,
// smart groups, provider DNS for server hostnames, and the
// battery usage report. Every feature ships behind a
// default-OFF toggle (standing rule 2026-11-18 01:43); the
// pins below hold both halves of that: the feature works
// when on, and the pre-2105 behaviour is bit-for-bit when
// off. Core-side behaviour (h1 session, resolver policy,
// FailedFast) is pinned by the Go tests in src2/core.
//
// All fixtures use dummy values.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/models.dart';
import 'package:firefox_vpn/ui/ember/battery_report.dart';
import 'package:firefox_vpn/ui/signin_dialog.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/provider_dns.dart';
import 'package:firefox_vpn/xray/smart_groups.dart';
import 'package:firefox_vpn/xray/traffic_history.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Profile vlessProfile({
  String id = 'p1',
  String name = 'test-config',
  String address = 'free.example.net',
  int delayMs = -1,
}) => Profile(
  id: id,
  name: name,
  protocol: Protocol.vless,
  address: address,
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  network: 'tcp',
  security: 'reality',
  sni: 'www.example.com',
  fingerprint: 'ios',
  flow: 'xtls-rprx-vision',
  publicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  shortId: '01ab',
  delayMs: delayMs,
);

void main() {
  group('standing rule — every 2105 toggle defaults OFF', () {
    test('AppSettings: a pre-2105 store grows neither feature', () async {
      final dir = Directory.systemTemp.createTempSync('b2105_');
      try {
        File('${dir.path}/app-settings.json')
            .writeAsStringSync('{"language":"en"}');
        final s = await AppSettings.load(dir.path);
        expect(s.signinBrowserFallbackOffer, isFalse);
        expect(s.batteryReportEnabled, isFalse);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('AppSettings: stored true reads back; update persists', () async {
      final dir = Directory.systemTemp.createTempSync('b2105_');
      try {
        File('${dir.path}/app-settings.json').writeAsStringSync(
          '{"signin_browser_fallback_offer":true,'
          '"battery_report_enabled":true}',
        );
        final s = await AppSettings.load(dir.path);
        expect(s.signinBrowserFallbackOffer, isTrue);
        expect(s.batteryReportEnabled, isTrue);
        // And the update() path writes the keys back out.
        final file = File('${dir.path}/app-settings.json');
        s.update(signinBrowserFallbackOffer: false);
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        var landed = false;
        while (!landed && DateTime.now().isBefore(deadline)) {
          try {
            final doc =
                jsonDecode(await file.readAsString()) as Map<String, dynamic>;
            landed = doc['signin_browser_fallback_offer'] == false;
          } catch (_) {
            landed = false;
          }
          if (!landed) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
        }
        expect(landed, isTrue, reason: 'settings file did not land in 5 s');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('XraySettings: all three toggles off, no rules', () {
      final s = XraySettings.fromJson(const {});
      expect(s.trafficHistoryEnabled, isFalse);
      expect(s.smartGroupsEnabled, isFalse);
      expect(s.providerDnsEnabled, isFalse);
      expect(s.smartGroupRules, isEmpty);
    });

    test('XraySettings: the 2105 keys round-trip', () {
      final s = XraySettings()
        ..trafficHistoryEnabled = true
        ..smartGroupsEnabled = true
        ..providerDnsEnabled = true
        ..smartGroupRules = [
          SmartGroupRule(
            id: 'r1',
            name: 'Fast',
            field: 'latency',
            value: '150',
          ),
        ];
      final back = XraySettings.fromJson(s.toJson());
      expect(back.trafficHistoryEnabled, isTrue);
      expect(back.smartGroupsEnabled, isTrue);
      expect(back.providerDnsEnabled, isTrue);
      expect(back.smartGroupRules.single.label, 'Fast');
    });

    test('XraySettings: a corrupt rule is dropped, never trusted', () {
      final s = XraySettings.fromJson({
        'smartGroupRules': [
          {'id': 'ok', 'field': 'protocol', 'value': 'vless'},
          {'id': '', 'field': 'protocol', 'value': 'vless'},
          {'id': 'x', 'field': 'nonsense', 'value': 'v'},
          'garbage',
        ],
      });
      expect(s.smartGroupRules.map((r) => r.id), ['ok']);
    });
  });

  group('A1 — browser sign-in fallback offer', () {
    test('off never offers, whatever the failure', () {
      for (final code in [
        SignInError.network,
        SignInError.tooManyAttempts,
        '',
      ]) {
        expect(
          signinBrowserFallbackOffered(
            enabled: false,
            failed: true,
            errorCode: code,
          ),
          isFalse,
        );
      }
    });

    test('on offers for the refusal class only', () {
      for (final code in [
        SignInError.network,
        SignInError.tooManyCodes,
        SignInError.timedOut,
        SignInError.unblockCodeRejected,
        SignInError.tooManyAttempts,
        '',
      ]) {
        expect(
          signinBrowserFallbackOffered(
            enabled: true,
            failed: true,
            errorCode: code,
          ),
          isTrue,
          reason: code,
        );
      }
      for (final code in [
        SignInError.wrongCode,
        SignInError.wrongTotp,
        SignInError.noPassword,
      ]) {
        expect(
          signinBrowserFallbackOffered(
            enabled: true,
            failed: true,
            errorCode: code,
          ),
          isFalse,
          reason: code,
        );
      }
    });

    test('a cancelled sign-in is not offered a remedy', () {
      expect(
        signinBrowserFallbackOffered(
          enabled: true,
          failed: false,
          errorCode: SignInError.network,
        ),
        isFalse,
      );
    });

    test('the dialog wires the offer to _startBrowser', () {
      final src = dartSrc('ui/signin_dialog.dart');
      expect(src, contains('Sign in with browser instead'));
      expect(src, contains('signinBrowserFallbackOffered('));
    });
  });

  group('A2/A3/A4 — Mozilla settings wiring', () {
    test('the transport choice is three-way and writes proxy.transport', () {
      final src = dartSrc('ui/ember/ember_settings.dart');
      expect(src, contains("('h1', 'HTTP/1.1', null)"));
      expect(src, contains("proxy['transport'] = v"));
      // The h1 caveat is in the product, not just the log.
      expect(src, contains('may not accept'));
    });

    test('the IP-version control writes dns.ip_version', () {
      final src = dartSrc('ui/ember/ember_settings.dart');
      expect(src, contains("('ipv6_first', 'V6 first', null)"));
      expect(src, contains("dns['ip_version'] = v"));
      expect(src, contains("dns['ip_version']"));
    });

    test('the fast-failover switch writes proxy.fast_failover', () {
      final src = dartSrc('ui/ember/ember_settings.dart');
      expect(src, contains("proxy['fast_failover'] = v"));
      expect(src, contains("proxy['fast_failover'] == true"));
    });
  });

  group('B — traffic history', () {
    test('deltas bucket into the current hour', () {
      final store = TrafficHistoryStore();
      final t = DateTime(2026, 11, 18, 10, 15);
      store.record('p1', 100, 200, t.millisecondsSinceEpoch);
      store.record('p1', 50, 70, t.millisecondsSinceEpoch + 60000);
      final buckets = store.bucketsFor('p1');
      expect(buckets, hasLength(1));
      expect(buckets.single.up, 150);
      expect(buckets.single.down, 270);
      expect(buckets.single.hourMs, hourStartMs(t.millisecondsSinceEpoch));
    });

    test('zero deltas record nothing; a new hour opens a bucket', () {
      final store = TrafficHistoryStore();
      final t = DateTime(2026, 11, 18, 10, 15);
      store.record('p1', 0, 0, t.millisecondsSinceEpoch);
      expect(store.bucketsFor('p1'), isEmpty);
      store.record('p1', 1, 1, t.millisecondsSinceEpoch);
      store.record('p1', 2, 2, t.millisecondsSinceEpoch + 3600000);
      expect(store.bucketsFor('p1'), hasLength(2));
    });

    test('the document round-trips and totals sum a window', () {
      final store = TrafficHistoryStore();
      final now = DateTime.now().millisecondsSinceEpoch;
      store.record('p1', 10, 20, now);
      store.record('p1', 1, 2, now - 25 * 3600000);
      final back = TrafficHistoryStore()..decode(store.toJson());
      expect(back.bucketsFor('p1'), hasLength(2));
      final totals = back.totalsFor('p1', now - 3600000);
      expect(totals.up, 10);
      expect(totals.down, 20);
    });

    test('bars window the buckets without compressing time', () {
      final now = DateTime(2026, 11, 18, 12, 30).millisecondsSinceEpoch;
      final buckets = [
        TrafficBucket(hourStartMs(now), 5, 6),
        TrafficBucket(hourStartMs(now) - 3 * 3600000, 7, 8),
      ];
      final bars = trafficBars(
        buckets,
        nowMs: now,
        windowMs: 3600000,
        count: 24,
      );
      expect(bars, hasLength(24));
      expect(bars.last.total, 11);
      expect(bars[20].total, 15);
      expect(bars.fold<int>(0, (s, b) => s + b.total), 26);
    });
  });

  group('C — smart groups', () {
    SmartGroupRule rule(String field, String value) =>
        SmartGroupRule(id: 'r', field: field, value: value);

    test('protocol matches case-insensitively', () {
      expect(
        smartGroupMatches(rule('protocol', 'VLESS'), vlessProfile()),
        isTrue,
      );
      expect(
        smartGroupMatches(rule('protocol', 'trojan'), vlessProfile()),
        isFalse,
      );
    });

    test('name and address match by containment', () {
      final p = vlessProfile(name: 'NL Fast 01', address: 'nl1.example.net');
      expect(smartGroupMatches(rule('name', 'fast'), p), isTrue);
      expect(smartGroupMatches(rule('address', 'NL1'), p), isTrue);
      expect(smartGroupMatches(rule('name', 'de'), p), isFalse);
    });

    test('subscription matches on the subscription name', () {
      final p = vlessProfile();
      expect(
        smartGroupMatches(
          rule('subscription', 'panel'),
          p,
          subscriptionName: 'My Panel NL',
        ),
        isTrue,
      );
      expect(smartGroupMatches(rule('subscription', 'panel'), p), isFalse);
    });

    test('latency needs a measurement under the limit', () {
      expect(
        smartGroupMatches(rule('latency', '150'), vlessProfile(delayMs: 90)),
        isTrue,
      );
      expect(
        smartGroupMatches(rule('latency', '150'), vlessProfile(delayMs: 400)),
        isFalse,
      );
      // Never measured (delayMs < 0) is not "fast".
      expect(
        smartGroupMatches(rule('latency', '150'), vlessProfile(delayMs: -1)),
        isFalse,
      );
      expect(
        smartGroupMatches(rule('latency', 'abc'), vlessProfile(delayMs: 90)),
        isFalse,
      );
    });

    test('an empty rule value matches nothing', () {
      expect(smartGroupMatches(rule('name', '  '), vlessProfile()), isFalse);
      expect(smartGroupMatches(rule('protocol', ''), vlessProfile()), isFalse);
    });

    test('a name rule matches the name on screen (the rename)', () {
      final p = vlessProfile(name: 'provider-name-42')..localName = 'My Rename';
      expect(smartGroupMatches(rule('name', 'rename'), p), isTrue);
      expect(smartGroupMatches(rule('name', 'provider'), p), isFalse);
    });
  });

  group('D — provider DNS', () {
    test('a query packet is well-formed', () {
      final q = buildDnsQuery(0x1234, 'free.example.net', 1);
      expect(q.length, greaterThan(12));
      expect((q[0] << 8) | q[1], 0x1234);
      expect((q[4] << 8) | q[5], 1); // QDCOUNT
    });

    Uint8List responsePacket(int id, {int answerType = 1, int flags = 0x8180}) {
      final out = BytesBuilder();
      void u16(int v) => out.add([(v >> 8) & 0xFF, v & 0xFF]);
      u16(id);
      u16(flags);
      u16(1); // QD
      u16(1); // AN
      u16(0);
      u16(0);
      // Question: free.example.net A IN
      for (final label in ['free', 'example', 'net']) {
        out.add([label.length, ...label.codeUnits]);
      }
      out.add([0]);
      u16(1);
      u16(1);
      // Answer: pointer to the name, A, IN, TTL 60, 192.0.2.9
      u16(0xC00C);
      u16(answerType);
      u16(1);
      out.add([0, 0, 0, 60]);
      if (answerType == 1) {
        u16(4);
        out.add([192, 0, 2, 9]);
      } else {
        u16(16);
        out.add(List.filled(16, 0)..[15] = 1);
      }
      return out.toBytes();
    }

    test('answers parse; a stray id is not an answer', () {
      expect(parseDnsAnswers(responsePacket(7), 7), ['192.0.2.9']);
      expect(parseDnsAnswers(responsePacket(7), 8), isNull);
      expect(parseDnsAnswers(responsePacket(7, answerType: 28), 7), [
        '0:0:0:0:0:0:0:1',
      ]);
      expect(parseDnsAnswers(Uint8List(3), 7), isNull);
    });

    test('a packet that is not our answer is refused', () {
      // QR clear: a query-shaped packet, not a response.
      expect(parseDnsAnswers(responsePacket(7, flags: 0x0180), 7), isNull);
      // The question must be the one we asked.
      expect(
        parseDnsAnswers(
          responsePacket(7),
          7,
          host: 'free.example.net',
          qtype: 1,
        ),
        ['192.0.2.9'],
      );
      expect(
        parseDnsAnswers(responsePacket(7), 7, host: 'other.example', qtype: 1),
        isNull,
      );
      expect(
        parseDnsAnswers(
          responsePacket(7),
          7,
          host: 'free.example.net',
          qtype: 28,
        ),
        isNull,
      );
      // An error RCODE is an answer with no records, not a stray.
      expect(parseDnsAnswers(responsePacket(7, flags: 0x8183), 7), isEmpty);
    });

    test('a questionless packet is not our answer', () {
      // QDCOUNT=0: nothing to match the question against.
      final out = BytesBuilder();
      void u16(int v) => out.add([(v >> 8) & 0xFF, v & 0xFF]);
      u16(7);
      u16(0x8180);
      u16(0); // QD
      u16(1); // AN
      u16(0);
      u16(0);
      u16(0xC00C);
      u16(1);
      u16(1);
      out.add([0, 0, 0, 60]);
      u16(4);
      out.add([192, 0, 2, 9]);
      expect(
        parseDnsAnswers(out.toBytes(), 7, host: 'free.example.net', qtype: 1),
        isNull,
      );
    });

    test(
      'a live UDP resolver answers both families in one resolution',
      () async {
        // The end-to-end shape parse-level tests cannot see:
        // ONE socket, ONE listen, both questions in flight. (A
        // per-family listen throws on the second family —
        // RawDatagramSocket is single-subscription — and UDP
        // pins never landed at all.)
        final server = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        // Some sandboxes forbid UDP outright (send raises
        // EPERM) or drop datagrams silently. Probe with a real
        // echo exchange: the test is real wherever UDP works;
        // where it cannot run at all, it says so instead of
        // failing — or passing vacuously.
        final echo = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final echoSub = echo.listen((e) {
          if (e != RawSocketEvent.read) return;
          final d = echo.receive();
          if (d != null) echo.send(d.data, d.address, d.port);
        });
        final ping = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        var probeOk = false;
        try {
          ping.send([42], InternetAddress.loopbackIPv4, echo.port);
          await for (final e in ping.timeout(const Duration(seconds: 2))) {
            if (e == RawSocketEvent.read && ping.receive() != null) {
              probeOk = true;
              break;
            }
          }
        } catch (_) {
          probeOk = false;
        }
        ping.close();
        await echoSub.cancel();
        echo.close();
        if (!probeOk) {
          markTestSkipped(
            'UDP loopback does not work in this environment; '
            'live resolution is exercised on device',
          );
          server.close();
          return;
        }
        final seenTypes = <int>[];
        final sub = server.listen((event) {
          if (event != RawSocketEvent.read) return;
          final dg = server.receive();
          if (dg == null) return;
          final q = dg.data;
          final qtype = (q[q.length - 4] << 8) | q[q.length - 3];
          seenTypes.add(qtype);
          final resp = BytesBuilder()..add(q);
          final bytes = resp.toBytes();
          bytes[2] = 0x81;
          bytes[3] = 0x80;
          bytes[6] = 0;
          bytes[7] = 1; // ANCOUNT
          final answer = BytesBuilder()..add(bytes);
          void u16(int v) => answer.add([(v >> 8) & 0xFF, v & 0xFF]);
          u16(0xC00C);
          u16(qtype);
          u16(1);
          answer.add([0, 0, 0, 60]);
          if (qtype == 1) {
            u16(4);
            answer.add([192, 0, 2, 9]);
          } else {
            u16(16);
            answer.add(List.filled(16, 0)..[15] = 1);
          }
          server.send(answer.toBytes(), dg.address, dg.port);
        });
        try {
          final answers = await resolveViaProviderDns(
            'free.example.net',
            '127.0.0.1:${server.port}',
            timeout: const Duration(seconds: 5),
          );
          expect(answers, contains('192.0.2.9'));
          expect(answers, contains('0:0:0:0:0:0:0:1'));
          expect(seenTypes, containsAll(<int>[1, 28]));
        } finally {
          await sub.cancel();
          server.close();
        }
      },
    );

    test('an out-of-range port can never break a connect', () async {
      expect(providerDnsUsable('1.1.1.1:99999'), isFalse);
      expect(providerDnsUsable('1.1.1.1:5353'), isTrue);
      // The resolver returns no pin instead of throwing the
      // ArgumentError a bad port raises at send time.
      expect(
        await resolveViaProviderDns('free.example.net', '127.0.0.1:99999'),
        isEmpty,
      );
      expect(
        await resolveViaProviderDns('free.example.net', '127.0.0.1:-5'),
        isEmpty,
      );
    });

    test('usable values: DoH URL, IP, hostname; junk refused', () {
      expect(providerDnsUsable('https://dns.example/dns-query'), isTrue);
      expect(providerDnsUsable('94.140.14.14'), isTrue);
      expect(providerDnsUsable('dns.example'), isTrue);
      expect(providerDnsUsable(''), isFalse);
      expect(providerDnsUsable('not a dns'), isFalse);
      expect(providerDnsUsable('http://insecure.example/dns'), isFalse);
    });

    test('the pin lands in the config hosts; off leaves no trace', () {
      final on = decode(
        buildTunnelConfig(
          vlessProfile(),
          XraySettings(),
          serverHostPins: const {
            'free.example.net': ['192.0.2.9'],
          },
        ),
      );
      final hosts = (on['dns'] as Map)['hosts'] as Map;
      // Build 2113: a pin with ONE answer emits as a plain
      // string (upstream's shape); several answers emit as
      // a list.
      expect(hosts['free.example.net'], '192.0.2.9');
      // The outbound keeps the hostname (2103 D6).
      final proxy = (on['outbounds'] as List).cast<Map>().firstWhere(
        (o) => o['tag'] == 'proxy',
      );
      expect(proxy['settings']['vnext'][0]['address'], 'free.example.net');

      final off = decode(buildTunnelConfig(vlessProfile(), XraySettings()));
      final offHosts = (off['dns'] as Map)['hosts'] as Map;
      expect(offHosts.containsKey('free.example.net'), isFalse);
    });

    test('a user custom host still wins over the provider pin', () {
      final s = XraySettings()
        ..customDnsHosts = {'free.example.net': '203.0.113.7'};
      final config = decode(
        buildTunnelConfig(
          vlessProfile(),
          s,
          serverHostPins: const {
            'free.example.net': ['192.0.2.9'],
          },
        ),
      );
      final hosts = (config['dns'] as Map)['hosts'] as Map;
      // Build 2113: the user entry emits as a plain string
      // and still wins over the provider pin.
      expect(hosts['free.example.net'], '203.0.113.7');
    });

    test('the subscription carries its DNS through the store', () {
      final sub = Subscription(
        id: 's1',
        name: 'Panel',
        url: 'https://panel.example/sub',
        dns: 'https://dns.example/dns-query',
      );
      final back = Subscription.fromJson(sub.toJson());
      expect(back.dns, 'https://dns.example/dns-query');
      final legacy = Subscription.fromJson({'id': 's2'});
      expect(legacy.dns, '');
    });
  });

  group('E — battery report', () {
    test('the platform side answers batteryStatus', () {
      final kt = ktSrc('MainActivity.kt');
      expect(kt, contains('"batteryStatus"'));
      expect(kt, contains('BATTERY_PROPERTY_CAPACITY'));
    });

    test('a record drains start minus end; unknown edges stay unknown', () {
      final r = BatterySessionRecord(
        engine: 'Mozilla',
        startMs: 0,
        endMs: 3600000,
        startLevel: 80,
        endLevel: 74,
      );
      expect(r.drained, 6);
      final unknown = BatterySessionRecord(
        engine: 'Mozilla',
        startMs: 0,
        endMs: 3600000,
      );
      expect(unknown.drained, isNull);
    });

    test('the tracker opens, hands over, and drops short sessions', () {
      final out = <BatterySessionRecord>[];
      final tracker = BatterySessionTracker(onSession: out.add);
      const t0 = 1000000;
      tracker.note(
        engine: 'Mozilla',
        nowMs: t0,
        reading: const BatteryReading(level: 90),
      );
      tracker.note(
        engine: 'Mozilla',
        nowMs: t0 + 600000,
        reading: const BatteryReading(level: 88),
      );
      expect(out, isEmpty); // still open
      tracker.note(
        engine: 'V2Ray',
        nowMs: t0 + 600000,
        reading: const BatteryReading(level: 88),
      );
      expect(out, hasLength(1));
      expect(out.single.engine, 'Mozilla');
      expect(out.single.drained, 2);
      // A 10-second V2Ray blip is sampler noise: not recorded.
      tracker.note(
        engine: null,
        nowMs: t0 + 610000,
        reading: const BatteryReading(level: 88),
      );
      expect(out, hasLength(1));
    });

    test('an unknown start level stays unknown (no fabricated edge)', () {
      final out = <BatterySessionRecord>[];
      final tracker = BatterySessionTracker(onSession: out.add);
      tracker.note(
        engine: 'Lantern',
        nowMs: 0,
        reading: const BatteryReading(),
      );
      tracker.note(
        engine: 'Lantern',
        nowMs: 60000,
        reading: const BatteryReading(level: 70),
      );
      tracker.note(
        engine: null,
        nowMs: 3600000,
        reading: const BatteryReading(level: 66),
      );
      // The mid-session 70 is not the session's start level:
      // storing it as one would understate the drain by
      // everything spent before that reading.
      expect(out.single.startLevel, isNull);
      expect(out.single.drained, isNull);
    });

    test('summaries aggregate per engine with an honest rate', () {
      final summaries = batteryEngineSummaries([
        BatterySessionRecord(
          engine: 'Mozilla',
          startMs: 0,
          endMs: 3600000,
          startLevel: 90,
          endLevel: 84,
        ),
        BatterySessionRecord(
          engine: 'Mozilla',
          startMs: 7200000,
          endMs: 10800000,
          startLevel: 80,
          endLevel: 78,
        ),
        BatterySessionRecord(engine: 'V2Ray', startMs: 0, endMs: 1800000),
        // Nine unmeasured Mozilla hours: they count toward the
        // connected time but must NOT dilute the drain rate —
        // the rate divides measured drain by measured time.
        BatterySessionRecord(
          engine: 'Mozilla',
          startMs: 20000000,
          endMs: 52400000,
        ),
      ]);
      final moz = summaries.firstWhere((s) => s.engine == 'Mozilla');
      expect(moz.sessions, 3);
      expect(moz.drainedPct, 8);
      expect(moz.pctPerHour, closeTo(4.0, 0.001));
      final v2 = summaries.firstWhere((s) => s.engine == 'V2Ray');
      expect(v2.measuredSessions, 0);
      expect(v2.pctPerHour, isNull);
    });

    test('the log document round-trips and drops corrupt records', () {
      final log = BatteryLog();
      log.decode({
        'sessions': [
          {
            'engine': 'Mozilla',
            'startMs': 0,
            'endMs': 60000,
            'startLevel': 50,
            'endLevel': 49,
          },
          {'engine': '', 'startMs': 0, 'endMs': 1},
          {'engine': 'X', 'startMs': 10, 'endMs': 5},
          'junk',
        ],
      });
      expect(log.records, hasLength(1));
      final back = BatteryLog()..decode(log.toJson());
      expect(back.records.single.engine, 'Mozilla');
    });
  });

  group('version', () {
    test('pubspec is 2.2.0+2119', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.2.0+2155'),
      );
    });
  });
}
