// Build 2115, Scope B — the DPI Strategy Lab full sweep and
// manual selection (owner's order 2026-11-19 05:42:
// «dpi strategy میخوام کامل همهرو پینگ بگیره هر کدوم خواستم
// انتخاب کنم»).
//
// What is pinned here:
//  - the sweep: discovery measures EVERY candidate to its
//    own result — built-ins, the Zapret shapes and installed
//    remote r- strategies — even after one confirms; the
//    only early exit left is the owner's own cancel;
//  - the remember gate (dpiLabCanRemember): a confirmed
//    result files on either path; an answered-but-unconfirmed
//    result (freezes / unconfirmed) files only as the owner's
//    manual pick; a blocked result never files;
//  - a manual pick persists through DpiLabMemory exactly
//    like a win (including an r- id, validated against the
//    installed registry), while a freezes result is never
//    the run's winner and never auto-rememberable — it is
//    filed only by hand, under its honest verdict.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/dpi_lab.dart';
import 'package:firefox_vpn/xray/dpi_remote.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Profile _profile() => Profile(
  id: 'lab-2115',
  name: 'Lab 2115',
  protocol: Protocol.vless,
  address: 'nl1.example.net',
  port: 443,
  uuidOrPassword: '00000000-0000-0000-0000-000000000000',
  network: 'tcp',
  security: 'tls',
  sni: 'nl1.example.net',
);

/// Queue-driven probers in the build 2107 pattern: each
/// measure consumes one queued answer (-1 past the queue);
/// endurance consumes one queued hold map per ANSWERED
/// candidate (null past the queue).
({DpiLabMeasure measure, DpiLabEndure endure, List<String> probed}) _probers(
  List<int> measures,
  List<Map<String, int>?> holds,
) {
  final probed = <String>[];
  var mi = 0;
  var hi = 0;
  return (
    measure: (config) async {
      probed.add(config);
      final ms = mi < measures.length ? measures[mi++] : -1;
      return {'ms': ms, 'ip': '', 'countryCode': ms >= 0 ? 'NL' : ''};
    },
    endure: (config) async => hi < holds.length ? holds[hi++] : null,
    probed: probed,
  );
}

DpiLabResult _result(String id, DpiLabVerdict verdict, {int ms = 120}) =>
    DpiLabResult(
      candidate: dpiLabCandidateById(id)!,
      verdict: verdict,
      ms: verdict == DpiLabVerdict.blocked ? -1 : ms,
      exitCountry: 'NL',
    );

String _src(String rel) => File('lib/$rel').readAsStringSync();

void main() {
  group('Scope B — the full sweep', () {
    test('an early winner does not end the run', () async {
      final f = _probers(
        [90],
        [
          {'p0': 90, 'p1': 95, 'p2': 92, 'held': 1},
        ],
      );
      final seen = <DpiLabResult>[];
      final results = await runDpiLabDiscovery(
        profile: _profile(),
        settings: XraySettings(),
        measure: f.measure,
        endure: f.endure,
        onResult: seen.add,
      );
      // Stock confirmed on the very first probe — and the
      // other candidates were still measured, each with its
      // own result, streamed as it landed. (Build 2126
      // supersession: 25 candidates since D7 + D9, was 15.
      // Build 2127 supersession (H1): 31 with the Zapret
      // engine candidates.)
      expect(results.length, 31);
      expect(f.probed.length, 31);
      expect(seen, results);
      expect(results.first.verdict, DpiLabVerdict.works);
      expect(
        results.skip(1).every((r) => r.verdict == DpiLabVerdict.blocked),
        isTrue,
      );
      expect(dpiLabWinner(results)?.candidate.id, 's0');
    });

    test('a mid-order winner and a later freezer keep their results', () async {
      final f = _probers(
        [-1, 140, 160],
        [
          {'p0': 140, 'p1': 150, 'p2': 145, 'held': 1},
          {'p0': 160, 'p1': -1, 'p2': -1, 'held': 0},
        ],
      );
      final results = await runDpiLabDiscovery(
        profile: _profile(),
        settings: XraySettings(),
        measure: f.measure,
        endure: f.endure,
      );
      expect(results.length, 31);
      expect(results[0].verdict, DpiLabVerdict.blocked);
      expect(results[1].verdict, DpiLabVerdict.works);
      expect(results[1].candidate.id, 's1');
      // The freezer AFTER the winner was still probed and
      // keeps its exact verdict — evidence the owner can
      // pick from, never a win.
      expect(results[2].verdict, DpiLabVerdict.freezes);
      expect(results[2].candidate.id, 's2');
      expect(results[2].ms, 160);
      expect(dpiLabWinner(results)?.candidate.id, 's1');
    });

    test('the Zapret shapes are swept like every other candidate', () async {
      // Build 2127 (H1): the real Zapret engine candidates
      // (zap-*) are swept alongside the config-layer shapes
      // this test was written for.
      final f = _probers(List.filled(31, -1), []);
      final results = await runDpiLabDiscovery(
        profile: _profile(),
        settings: XraySettings(),
        measure: f.measure,
        endure: f.endure,
      );
      expect(
        results.map((r) => r.candidate.id),
        containsAll([
          'af-z1',
          'af-z2',
          'af-z3',
          'af-z4',
          'af-z5',
          'zap-split',
          'zap-tlsrec',
          'zap-fake',
          'zap-disorder',
          'zap-oob',
          'zap-disoob',
        ]),
      );
      expect(results.length, 31);
    });

    group('with a remote strategy installed', () {
      setUp(
        () => installDpiRemoteStrategies(
          parseDpiStrategiesJson({
            'strategies': [
              {
                'id': 'sweep-1',
                'label': 'Feed strategy',
                'detail': 'From the test feed.',
                'shape': {
                  'fragment': {
                    'lengths': ['2', '3'],
                    'delays': ['0'],
                  },
                },
              },
            ],
          }),
        ),
      );
      tearDown(() => installDpiRemoteStrategies(const []));

      test('the r- candidate is measured too — and can win', () async {
        // 31 built-ins blocked (build 2126: was 15 at 25;
        // build 2127 (H1): 31); the remote strategy, last
        // in probe order, answers and holds.
        final f = _probers(
          [...List.filled(31, -1), 140],
          [
            {'p0': 140, 'p1': 150, 'p2': 145, 'held': 1},
          ],
        );
        final results = await runDpiLabDiscovery(
          profile: _profile(),
          settings: XraySettings(),
          measure: f.measure,
          endure: f.endure,
        );
        expect(results.length, 32);
        expect(results.last.candidate.id, 'r-sweep-1');
        expect(results.last.verdict, DpiLabVerdict.works);
        expect(dpiLabWinner(results)?.candidate.id, 'r-sweep-1');
      });
    });

    test('cancel is the one early exit left', () async {
      final f = _probers(List.filled(15, -1), []);
      var calls = 0;
      final results = await runDpiLabDiscovery(
        profile: _profile(),
        settings: XraySettings(),
        measure: f.measure,
        endure: f.endure,
        isCancelled: () => ++calls > 2,
      );
      expect(results.length, 2);
    });
  });

  group('Scope B — the remember gate', () {
    test('the verdict × path matrix', () {
      expect(
        dpiLabCanRemember(_result('s1', DpiLabVerdict.works), manual: false),
        isTrue,
      );
      expect(
        dpiLabCanRemember(_result('s1', DpiLabVerdict.works), manual: true),
        isTrue,
      );
      expect(
        dpiLabCanRemember(_result('s1', DpiLabVerdict.freezes), manual: false),
        isFalse,
      );
      expect(
        dpiLabCanRemember(_result('s1', DpiLabVerdict.freezes), manual: true),
        isTrue,
      );
      expect(
        dpiLabCanRemember(
          _result('s1', DpiLabVerdict.unconfirmed),
          manual: false,
        ),
        isFalse,
      );
      expect(
        dpiLabCanRemember(
          _result('s1', DpiLabVerdict.unconfirmed),
          manual: true,
        ),
        isTrue,
      );
      expect(
        dpiLabCanRemember(_result('s1', DpiLabVerdict.blocked), manual: false),
        isFalse,
      );
      expect(
        dpiLabCanRemember(_result('s1', DpiLabVerdict.blocked), manual: true),
        isFalse,
      );
    });

    test('a freezes result is never the winner', () {
      final results = [
        _result('s0', DpiLabVerdict.freezes),
        _result('s1', DpiLabVerdict.unconfirmed),
        _result('s2', DpiLabVerdict.blocked),
      ];
      expect(dpiLabWinner(results), isNull);
    });
  });

  group('Scope B — a manual pick persists like a win', () {
    DpiLabWin winFor(DpiLabResult r, {required int at}) => DpiLabWin(
      candidateId: r.candidate.id,
      profileId: 'lab-2115',
      profileName: 'Lab 2115',
      ms: r.ms,
      exitCountry: r.exitCountry,
      verifiedMs: at,
    );

    test('a hand-picked freezer files and round-trips', () {
      final pick = _result('af-z1', DpiLabVerdict.freezes, ms: 160);
      expect(dpiLabCanRemember(pick, manual: true), isTrue);
      final memory = DpiLabMemory();
      memory.record('wifi:abcd', winFor(pick, at: 1000000));
      expect(memory.lookup('wifi:abcd', nowMs: 1000000)?.candidateId, 'af-z1');
      // The store round-trip keeps it — same document shape
      // as a confirmed win.
      final restored = DpiLabMemory.fromJson(memory.toJson());
      expect(restored.lookup('wifi:abcd', nowMs: 1000000)?.ms, 160);
    });

    group('with a remote strategy installed', () {
      setUp(
        () => installDpiRemoteStrategies(
          parseDpiStrategiesJson({
            'strategies': [
              {
                'id': 'pick-1',
                'label': 'Feed strategy',
                'detail': 'From the test feed.',
                'shape': {
                  'fragment': {
                    'lengths': ['2', '3'],
                    'delays': ['0'],
                  },
                },
              },
            ],
          }),
        ),
      );
      tearDown(() => installDpiRemoteStrategies(const []));

      test('an r- pick validates against the registry', () {
        final pick = _result('r-pick-1', DpiLabVerdict.unconfirmed, ms: 200);
        expect(dpiLabCanRemember(pick, manual: true), isTrue);
        final memory = DpiLabMemory();
        memory.record('wifi:abcd', winFor(pick, at: 1000000));
        final restored = DpiLabMemory.fromJson(memory.toJson());
        expect(
          restored.lookup('wifi:abcd', nowMs: 1000000)?.candidateId,
          'r-pick-1',
        );
        // Uninstalled, the same stored entry no longer
        // validates — the win reads as no win, never a crash.
        installDpiRemoteStrategies(const []);
        expect(DpiLabMemory.fromJson(memory.toJson()).length, 0);
      });
    });
  });

  group('Scope B — source pins', () {
    test('the runner has no winner break and no run budget', () {
      final lab = _src('xray/dpi_lab.dart');
      expect(lab, isNot(contains('dpiLabRunBudgetMs')));
      final runner = lab.substring(
        lab.indexOf('Future<List<DpiLabResult>> runDpiLabDiscovery'),
        lab.indexOf('Future<DpiLabResult> _probeCandidate'),
      );
      expect(runner, isNot(contains('DpiLabVerdict.works) break')));
      expect(runner, contains('isCancelled'));
    });

    test('the controller files manual picks through the gate', () {
      final controller = _src('xray/xray_controller.dart');
      final remember = controller.substring(
        controller.indexOf('Future<String> rememberDpiLabWin'),
        controller.indexOf('Future<void> forgetDpiLabWin'),
      );
      expect(remember, contains('bool manual = false'));
      expect(remember, contains('dpiLabCanRemember(result, manual: manual)'));
      expect(remember, contains('as your pick'));
    });

    test('the page offers the pick on answered rows', () {
      final page = _src('ui/ember/dpi_lab_page.dart');
      expect(page, contains('_pickManually'));
      expect(page, contains('rememberDpiLabWin(p, r, manual: true)'));
      expect(page, contains("'Use this'"));
      expect(page, contains("'Your pick'"));
      // Blocked rows offer nothing: the affordance is gated
      // on the verdict not being blocked. (Build 2120
      // re-point: the row's effective result is `shown` —
      // the fresh result or the saved one — since the pick
      // is now offered on saved answered rows too.)
      expect(page, contains('shown.verdict != DpiLabVerdict.blocked'));
    });
  });
}
