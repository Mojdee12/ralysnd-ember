// Build 2116, batch B13 — the open-residual register,
// one row per item (plan §B13):
//   B13-1  2098 F-A3: the chain-exit deferral is consumed
//          at EVERY true session end, not only disconnect().
//   B13-2  2098 F6: the session underlay is persisted, so an
//          adopted session still names its underlay.
//   B13-3  2105-R6: the open battery session's final record
//          is written synchronously at dispose.
//   B13-4  2105-R11: (Go) the failover tried-set keys on the
//          canonical host:port — pinned here, proven in the
//          core's own suite.
//   B13-5  2106-L5: a silent first provider-DNS bootstrap
//          target gets a bounded share of the deadline and
//          is accounted in the journal.
//   B13-6  2107-L1: the Lab stand-down is persisted BEFORE
//          the native start completes.
//   B13-7  2107-L2/L3: Lab descriptions say what the core
//          does (noise is UDP-only here; s2's fingerprint
//          half is inert on KCP).
//   B13-8  2107-L5: the Lab page listens via the sibling
//          ListenableBuilder pattern.
//   B13-9  2107-L6: the Lab offer surfaces independently of
//          the selected profile's card.
//   B13-10 2108-L2: Block QUIC is labelled as what it is —
//          all UDP/443.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/ui/ember/battery_report.dart';
import 'package:firefox_vpn/xray/dpi_lab.dart';
import 'package:firefox_vpn/xray/provider_dns.dart';

String read(String path) => File(path).readAsStringSync();

void main() {
  group('B13-1 chain-exit deferral (2098 F-A3)', () {
    final xray = read('lib/xray/xray_controller.dart');

    test('consumed at the drop and retry-budget ends too', () {
      expect('_consumePendingChainExit();'.allMatches(xray).length, 4);
      final drop = xray.indexOf('void _onUnexpectedDrop(');
      final retryAt = xray.indexOf('void _noteRetryFailed()', drop);
      final dropBody = xray.substring(drop, retryAt);
      expect('_consumePendingChainExit();'.allMatches(dropBody).length, 2,
          reason: 'both terminal branches of the drop handler');
      final retry = xray.indexOf('void _noteRetryFailed()');
      expect(
        xray.substring(retry, retry + 2000),
        contains('_consumePendingChainExit();'),
      );
    });

    test('the notice-only hand-over does NOT consume it', () {
      final hand = xray.indexOf('void _handOverToReconnect(');
      final body = xray.substring(hand, hand + 1500);
      expect(body, isNot(contains('_consumePendingChainExit();')),
          reason: 'the session is still up — the deferral lives');
    });
  });

  group('B13-2 session underlay persisted (2098 F6)', () {
    final xray = read('lib/xray/xray_controller.dart');

    test('written, restored and cleared with the session id', () {
      expect(xray, contains("'sessionUnderlay': _sessionUnderlay"));
      expect(xray, contains("doc['sessionUnderlay'] is String"));
      // A backup restore never carries a live-session claim.
      final imp = xray.indexOf('Future<BackupRestoreResult?> importBackup(');
      final body = xray.substring(imp, imp + 9000);
      expect(body, contains("_sessionUnderlay = '';"));
    });
  });

  group('B13-3 battery final record (2105-R6)', () {
    test('takeOpen captures the open session; addSync persists it', () async {
      final dir = await Directory.systemTemp.createTemp('ember_b13_');
      addTearDown(() => dir.delete(recursive: true));
      final log = await BatteryLog.load(dir.path);
      BatterySessionRecord? emitted;
      final tracker = BatterySessionTracker(
        onSession: (r) => emitted = r,
      );
      final t0 = DateTime.now().millisecondsSinceEpoch - 60000;
      tracker.note(
        engine: 'V2Ray',
        nowMs: t0,
        reading: const BatteryReading(level: 80),
      );
      expect(tracker.hasOpenSession, isTrue);
      final taken = tracker.takeOpen(t0 + 60000);
      expect(taken, isNotNull);
      expect(taken!.engine, 'V2Ray');
      expect(emitted, isNull,
          reason: 'takeOpen captures instead of emitting');
      // A second take finds nothing open.
      expect(tracker.takeOpen(t0 + 70000), isNull);
      // The synchronous write lands the record on disk at once.
      log.addSync(taken);
      final file = File('${dir.path}/battery-log.json');
      expect(file.existsSync(), isTrue);
      final reloaded = await BatteryLog.load(dir.path);
      expect(reloaded.records.length, 1);
      expect(reloaded.records.single.engine, 'V2Ray');
    });

    test('the shell dispose uses the sync path', () {
      final shell = read('lib/ui/ember/ember_shell.dart');
      expect(shell, contains('_batteryTracker?.takeOpen('));
      expect(shell, contains('_batteryLog?.addSync(batteryRecord)'));
    });
  });

  group('B13-4 canonical tried-set (2105-R11, Go)', () {
    test('the core keys the walk by CanonicalProxyAddr', () {
      final engine = read('../core/internal/service/engine.go');
      expect(engine, contains('proxy.CanonicalProxyAddr(addr)'));
      expect(engine, contains('tried[triedKey(next.Addr)] = true'));
      final selection = read('../core/internal/proxy/selection.go');
      expect(selection, contains('func CanonicalProxyAddr('));
    });
  });

  group('B13-5 provider-DNS shares (2106-L5)', () {
    test('per-target share + journal note are wired', () {
      final dns = read('lib/xray/provider_dns.dart');
      expect(dns, contains('before ~/ remaining'));
      expect(dns, contains('stayed silent for its share'));
      expect(dns, contains('void Function(String note)? onNote'));
      final xray = read('lib/xray/xray_controller.dart');
      expect(
        xray,
        contains("onNote: (note) => diagnostics.add('dns', note"),
      );
    });

    test('a literal still needs no resolution', () async {
      expect(await resolveViaProviderDns('1.2.3.4', '8.8.8.8'), isEmpty);
    });
  });

  group('B13-6 Lab stand-down persisted early (2107-L1)', () {
    test('the dial awaits a save right after arming the stand-down', () {
      final xray = read('lib/xray/xray_controller.dart');
      final at = xray.indexOf('_labDialCandidateId = labDial.candidateId;');
      expect(at, greaterThan(0));
      final after = xray.substring(at, at + 1200);
      expect(after, contains('await _save();'));
    });
  });

  group('B13-7 Lab descriptions (2107-L2/L3)', () {
    test('af-tcp-noise says UDP-only in this core', () {
      final c = dpiLabCandidateById('af-tcp-noise');
      expect(c, isNotNull);
      expect(c!.detail, contains('only for UDP destinations'));
    });

    test('s2 says its fingerprint half is inert on KCP', () {
      final c = dpiLabCandidateById('s2');
      expect(c, isNotNull);
      expect(c!.detail, contains('does nothing on KCP'));
    });
  });

  group('B13-8 Lab page listener pattern (2107-L5)', () {
    test('ListenableBuilder, no manual controller listener', () {
      final page = read('lib/ui/ember/dpi_lab_page.dart');
      expect(page, contains('ListenableBuilder('));
      expect(page, contains('listenable: xray'));
      expect(page, isNot(contains('addListener(_onXrayChanged)')));
      expect(page, isNot(contains('_onXrayChanged')));
    });
  });

  group('B13-9 Lab offer independent of the card (2107-L6)', () {
    test('the offer row is shared and also rendered with no profile', () {
      final home = read('lib/ui/ember/ember_home.dart');
      expect(home, contains('Widget _labOfferRow('));
      expect('_labOfferRow(context, xray)'.allMatches(home).length, 2,
          reason: 'in-card + the independent no-profile surface');
      expect(home, contains('if (p == null &&'));
    });
  });

  group('B13-10 Block QUIC label (2108-L2)', () {
    test('the settings row names all of UDP/443', () {
      final settings = read('lib/ui/ember/ember_settings.dart');
      expect(settings, contains("label: 'Block QUIC (all UDP/443)'"));
      expect(settings, contains('Drops every UDP packet to port 443'));
    });
  });
}
