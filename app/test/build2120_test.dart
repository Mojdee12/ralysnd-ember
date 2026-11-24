// Build 2120 — the DPI Strategy Lab round (owner orders
// 2026-11-19 20:38 / 20:43):
//
//  1. Sweep subset selection: before a run the owner ticks
//     WHICH strategies the sweep tests; default = all
//     (today's behaviour); the selection persists. Stored
//     as the EXCLUDED set, so a strategy that ships later
//     is tested by default — an untick is the only way a
//     strategy leaves the sweep.
//  2. Per-config Lab result persistence: verdict + delay +
//     timestamp (+ exit, endurance probes and the network
//     the evidence was measured on) stored per config; the
//     Lab opens showing the saved rows with their age; a
//     re-run updates only the rows it re-tests. The
//     winning-shape cache and the per-network Lab memory
//     are untouched.
//  3. Zapret: the full nfqws engine (fake packets with
//     forged TTL/checksum, disorder, sequence overlap)
//     needs raw-packet forging — root on Android — and is
//     NOT implemented (see the feasibility note in
//     dpi_lab.dart). The expressible remainder ships as
//     two ordinary strategies: z4 (multisplit with delays,
//     so the cuts leave as separate segments) and z5
//     (dense multisplit across the whole name). The three
//     shipped Zapret strategies (af-z1/z2/z3, device-
//     confirmed 2026-11-19 20:43) are pinned BYTE-EXACT
//     below — those pins were written and run against the
//     pristine 2119 tree BEFORE any 2120 change.
//
// All fixtures use dummy values.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/anti_filter.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/dpi_lab.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Profile _profile({String network = 'tcp', String security = 'tls'}) =>
    Profile(
      id: 'lab-2120',
      name: 'Lab 2120',
      protocol: Protocol.vless,
      address: 'nl1.example.net',
      port: 443,
      uuidOrPassword: '00000000-0000-0000-0000-000000000000',
      network: network,
      security: security,
      sni: 'nl1.example.net',
    );

void main() {
  group('Zapret regression pins — af-z1/z2/z3 byte-exact (pre-change)', () {
    // The generated test config's finalmask for each shipped
    // Zapret candidate, as a canonical JSON string, plus the
    // whole-config length as a tripwire: ANY change to what
    // these three candidates generate trips this group.
    const expectedFinalmask = {
      'af-z1':
          '{"tcp":[{"type":"fragment","settings":{"packets":"tlshello",'
          '"lengths":["2","3","5","8"],"delays":["0"]}}]}',
      'af-z2':
          '{"tcp":[{"type":"fragment","settings":{"packets":"tlshello",'
          '"lengths":["1","2","4"],"delays":["0"]}}]}',
      'af-z3':
          '{"tcp":[{"type":"fragment","settings":{"packets":"tlshello",'
          '"lengths":["0","2","104","1"],"delays":["0"],"maxSplit":"0"}}]}',
    };
    // Build 2125 SUPERSESSION (recorded, not silent):
    // A25-33 emits the config COMPACT (the pretty encoding
    // cost ~45% more bytes on every test/connect for zero
    // readers). The shape pins below (finalmask JSON,
    // decoded structure) are unchanged and still exact;
    // the lengths now pin the compact encoding of the
    // identical documents (was 3588/3565/3623 pretty).
    const expectedConfigLength = {'af-z1': 2025, 'af-z2': 2021, 'af-z3': 2042};

    for (final id in ['af-z1', 'af-z2', 'af-z3']) {
      test('$id generates exactly the shipped config shape', () {
        final config = buildTestConfig(
          profileWithCandidate(_profile(), id),
          XraySettings(),
        );
        expect(config.length, expectedConfigLength[id], reason: id);
        final doc = jsonDecode(config) as Map<String, dynamic>;
        final outbound = (doc['outbounds'] as List).first as Map;
        final stream = outbound['streamSettings'] as Map;
        expect(jsonEncode(stream['finalmask']), expectedFinalmask[id],
            reason: id);
      });
    }

    test('the shipped Zapret shapes themselves are unchanged', () {
      expect(afShapeById('z1')?.lengths, ['2', '3', '5', '8']);
      expect(afShapeById('z1')?.delays, ['0']);
      expect(afShapeById('z2')?.lengths, ['1', '2', '4']);
      expect(afShapeById('z2')?.delays, ['0']);
      expect(afShapeById('z3')?.lengths, ['0', '2', '104', '1']);
      expect(afShapeById('z3')?.delays, ['0']);
      expect(afShapeById('z3')?.maxSplit, '0');
    });
  });

  group('Item 3 — the expressible Zapret remainder (z4 / z5)', () {
    test('the two new geometries are shipped with exact values', () {
      expect(afShapeById('z4')?.lengths, ['2', '3', '5', '8']);
      expect(afShapeById('z4')?.delays, ['10']);
      expect(afShapeById('z5')?.lengths, ['1', '2', '3', '4', '5', '6', '7', '8']);
      expect(afShapeById('z5')?.delays, ['0']);
    });

    test('the candidates exist, are TLS-only, and transform', () {
      for (final (cid, fid) in [('af-z4', 'z4'), ('af-z5', 'z5')]) {
        final c = dpiLabCandidateById(cid);
        expect(c, isNotNull, reason: cid);
        expect(c!.tlsOnly, isTrue, reason: cid);
        expect(c.label, contains('Zapret'), reason: cid);
        final shaped = profileWithCandidate(_profile(), cid);
        expect(shaped.afFragment, fid, reason: cid);
      }
    });

    test('the built configs carry the exact new finalmasks', () {
      final s = XraySettings();
      String finalmaskOf(String cid) {
        final doc =
            jsonDecode(
                  buildTestConfig(profileWithCandidate(_profile(), cid), s),
                )
                as Map<String, dynamic>;
        final stream =
            ((doc['outbounds'] as List).first as Map)['streamSettings']
                as Map;
        return jsonEncode(stream['finalmask']);
      }

      expect(
        finalmaskOf('af-z4'),
        '{"tcp":[{"type":"fragment","settings":{"packets":"tlshello",'
        '"lengths":["2","3","5","8"],"delays":["10"]}}]}',
      );
      expect(
        finalmaskOf('af-z5'),
        '{"tcp":[{"type":"fragment","settings":{"packets":"tlshello",'
        '"lengths":["1","2","3","4","5","6","7","8"],"delays":["0"]}}]}',
      );
    });

    test('the new candidates stay off UDP transports, like z1–z3', () {
      final ids = dpiLabCandidatesFor(
        _profile(network: 'kcp'),
      ).map((c) => c.id);
      expect(ids, isNot(contains('af-z4')));
      expect(ids, isNot(contains('af-z5')));
    });

    test('the full candidate order is pinned — nothing moved or dropped', () {
      // The shipped set in probe order, with z4/z5 appended
      // after z3 (2114's placement rule: new strategies
      // never reorder the proven ones).
      // Build 2126 supersession (D7 + D9): the F-family
      // probes join after af-f1 and the randomized
      // multisplit after af-z1 — the proven order of the
      // original fifteen is untouched.
      // Build 2127 supersession (H1): the six Zapret
      // engine candidates join after af-z5.
      expect(dpiLabCandidatesFor(_profile()).map((c) => c.id), [
        's0',
        's1',
        's2',
        's3',
        'af-mirage',
        'af-f1',
        'af-f2',
        'af-f3',
        'af-f6',
        'af-f7',
        'af-f8',
        'af-f9',
        'af-f13',
        'af-f14',
        'af-f15',
        'af-z1',
        'af-z1r',
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
        'af-mixed-sni',
        'af-ech',
        'af-unfilter',
        'af-tcp-noise',
      ]);
    });
  });
  group('Item 1 — sweep subset selection', () {
    test('the exclusion set round-trips; garbage reads as empty', () {
      final encoded = dpiLabSelectionToJson({'af-z1', 's0', 'af-ech'});
      expect(encoded, ['af-ech', 'af-z1', 's0']); // sorted, stable
      expect(dpiLabSelectionFromJson(encoded), {'af-z1', 's0', 'af-ech'});
      expect(dpiLabSelectionFromJson(null), isEmpty);
      expect(dpiLabSelectionFromJson('junk'), isEmpty);
      expect(dpiLabSelectionFromJson([1, '', 's2', 's2']), {'s2'});
    });

    Future<Map<String, dynamic>> okMeasure(String _) async =>
        {'ms': 120, 'ip': '203.0.113.7', 'countryCode': 'NL'};
    Future<Map<String, int>?> okEndure(String _) async =>
        {'p0': 10, 'p1': 11, 'p2': 12, 'held': 1};

    test('the runner probes only the ticked subset', () async {
      var probes = 0;
      final results = await runDpiLabDiscovery(
        profile: _profile(),
        settings: XraySettings(),
        measure: (c) async {
          probes++;
          return okMeasure(c);
        },
        endure: okEndure,
        excludeIds: {'s0', 'af-z1', 'af-z4'},
      );
      final all = dpiLabCandidatesFor(_profile()).length;
      expect(results.length, all - 3);
      expect(probes, all - 3);
      expect(
        results.map((r) => r.candidate.id),
        isNot(contains(anyOf('s0', 'af-z1', 'af-z4'))),
      );
    });

    test('the default (no exclusion) is still the full sweep', () async {
      final results = await runDpiLabDiscovery(
        profile: _profile(),
        settings: XraySettings(),
        measure: okMeasure,
        endure: okEndure,
      );
      expect(results.length, dpiLabCandidatesFor(_profile()).length);
    });

    test('excluding everything probes nothing', () async {
      var probes = 0;
      final results = await runDpiLabDiscovery(
        profile: _profile(),
        settings: XraySettings(),
        measure: (c) async {
          probes++;
          return okMeasure(c);
        },
        endure: okEndure,
        excludeIds: dpiLabCandidatesFor(_profile()).map((c) => c.id).toSet(),
      );
      expect(results, isEmpty);
      expect(probes, 0);
    });
  });
  group('Item 2 — per-config result persistence', () {
    DpiLabResult result(String cid, DpiLabVerdict v, {int ms = 100}) =>
        DpiLabResult(
          candidate: dpiLabCandidateById(cid)!,
          verdict: v,
          ms: ms,
          exitCountry: 'NL',
          p0: 1,
          p1: 2,
          p2: 3,
        );

    test('record, lookup, and in-place update of one row only', () {
      final book = DpiLabResultBook();
      book.record(
        'p1',
        result('af-z1', DpiLabVerdict.works),
        measuredMs: 1000,
        networkFp: 'wifi:aa',
      );
      book.record(
        'p1',
        result('s0', DpiLabVerdict.blocked, ms: -1),
        measuredMs: 1000,
        networkFp: 'wifi:aa',
      );
      expect(book.resultCount, 2);
      // A re-run re-tests af-z1 only: its row is replaced,
      // the s0 row keeps its original stamp.
      book.record(
        'p1',
        result('af-z1', DpiLabVerdict.freezes, ms: 90),
        measuredMs: 2000,
        networkFp: 'wifi:bb',
      );
      expect(book.resultCount, 2);
      final z1 = book.lookup('p1', 'af-z1')!;
      expect(z1.verdict, DpiLabVerdict.freezes);
      expect(z1.ms, 90);
      expect(z1.measuredMs, 2000);
      expect(z1.networkFp, 'wifi:bb');
      final s0 = book.lookup('p1', 's0')!;
      expect(s0.verdict, DpiLabVerdict.blocked);
      expect(s0.measuredMs, 1000);
      // Another config's book is independent.
      expect(book.forProfile('p2'), isEmpty);
    });

    test('the book round-trips through JSON with every field', () {
      final book = DpiLabResultBook();
      book.record(
        'p1',
        result('af-z5', DpiLabVerdict.unconfirmed, ms: 77),
        measuredMs: 424242,
        networkFp: 'cellular:cc',
      );
      final back = DpiLabResultBook.fromJson(
        jsonDecode(jsonEncode(book.toJson())),
      );
      final row = back.lookup('p1', 'af-z5')!;
      expect(row.verdict, DpiLabVerdict.unconfirmed);
      expect(row.ms, 77);
      expect(row.exitCountry, 'NL');
      expect(row.p0, 1);
      expect(row.p1, 2);
      expect(row.p2, 3);
      expect(row.measuredMs, 424242);
      expect(row.networkFp, 'cellular:cc');
      // And it reconstructs the result the pick machinery eats.
      final r = row.toResult()!;
      expect(r.candidate.id, 'af-z5');
      expect(r.verdict, DpiLabVerdict.unconfirmed);
      expect(dpiLabCanRemember(r, manual: true), isTrue);
    });

    test('corrupt entries are dropped, never fatal', () {
      final book = DpiLabResultBook.fromJson({
        'p1': {
          'af-z1': {'v': 'works', 'ms': 5, 'at': 10, 'net': 'wifi:x'},
          'nope': {'v': 'works', 'ms': 5, 'at': 10},
          's0': {'v': 'sideways', 'ms': 5, 'at': 10},
          's1': {'v': 'works', 'ms': 5},
          's2': 'garbage',
        },
        '': {'s0': {'v': 'works', 'ms': 1, 'at': 1}},
        'p2': 'garbage',
      });
      expect(book.profileCount, 1);
      expect(book.resultCount, 1);
      expect(book.lookup('p1', 'af-z1')?.verdict, DpiLabVerdict.works);
      expect(DpiLabResultBook.fromJson('junk').resultCount, 0);
    });

    test('a remote strategy row validates only while installed', () {
      final remote = DpiRemoteStrategy(
        candidate: const DpiLabCandidate(
          'r-zap2',
          'Feed Zapret 2',
          '',
          tlsOnly: true,
        ),
        fragment: const AfFragmentShape('r-zap2', 'Feed Zapret 2', [
          '2',
        ], ['0']),
      );
      installDpiRemoteStrategies([remote]);
      try {
        final book = DpiLabResultBook();
        book.record(
          'p1',
          result('r-zap2', DpiLabVerdict.works),
          measuredMs: 5,
          networkFp: 'wifi:x',
        );
        final back = DpiLabResultBook.fromJson(book.toJson());
        expect(back.lookup('p1', 'r-zap2')?.verdict, DpiLabVerdict.works);
      } finally {
        installDpiRemoteStrategies(const []);
      }
      // Uninstalled, the same document reads as no row.
      final book = DpiLabResultBook.fromJson({
        'p1': {
          'r-zap2': {'v': 'works', 'ms': 5, 'at': 5},
        },
      });
      expect(book.resultCount, 0);
    });

    test('pruneProfiles drops deleted configs; the cap holds', () {
      final book = DpiLabResultBook();
      for (var i = 0; i < 70; i++) {
        book.record(
          'p$i',
          result('s0', DpiLabVerdict.works),
          measuredMs: 1000 + i,
          networkFp: 'wifi:x',
        );
      }
      expect(book.profileCount, DpiLabResultBook.maxProfiles);
      // The most recently recorded book survives the cap.
      expect(book.lookup('p69', 's0'), isNotNull);
      book.pruneProfiles({'p69'});
      expect(book.profileCount, 1);
      expect(book.lookup('p69', 's0'), isNotNull);
    });
  });

  group('Items 1+2 — wiring source pins', () {
    String read(String path) => File(path).readAsStringSync();

    test('the controller persists and wires both pieces', () {
      final c = read('lib/xray/xray_controller.dart');
      expect(c, contains("'dpiLabResults': dpiLabResults.toJson()"));
      expect(c, contains("'dpiLabSweepExcluded': dpiLabSelectionToJson("));
      expect(c, contains('excludeIds: dpiLabSweepExcluded'));
      expect(c, contains('dpiLabResults.record('));
      expect(c, contains('setDpiLabCandidateExcluded'));
      expect(c, contains('DpiLabResultBook.fromJson'));
      expect(c, contains('dpiLabSelectionFromJson'));
    });

    test('the page renders ticks and saved rows', () {
      final p = read('lib/ui/ember/dpi_lab_page.dart');
      expect(p, contains('setDpiLabCandidateExcluded'));
      expect(p, contains('dpiLabSavedFor'));
      expect(p, contains('Not in this run'));
      expect(p, contains('Saved '));
    });

    test('no candidate is labelled an engine', () {
      // The header documents why the zapret ENGINE is not
      // implemented; the shipped candidates must stay
      // honest geometries, never an "engine" product claim.
      // Build 2127 supersession (H1, the owner's order):
      // the engine IS implemented now — the six zap-*
      // candidates are backed by the bundled ciadpi
      // binary and are honestly labelled as the engine.
      // Every config-layer candidate (s*/af-*) must still
      // never claim to be one.
      for (final c in dpiLabCandidates) {
        if (c.id.startsWith('zap-')) {
          expect(c.label, contains('Zapret engine'), reason: c.id);
        } else {
          expect(c.label.toLowerCase(), isNot(contains('engine')),
              reason: c.id);
          expect(c.detail.toLowerCase(), isNot(contains('engine')),
              reason: c.id);
        }
      }
      expect(dpiLabCandidateById('af-z4'), isNotNull);
      expect(dpiLabCandidateById('af-z5'), isNotNull);
    });
  });
}
