// Build 2107 — the DPI Strategy Lab (dpi-lab-design.md).
// Pins:
//  - the candidate set: order, labels, TLS gating, and the
//    eligibility rule (core-served only; no WireGuard, no
//    Hysteria2, no sidecar protocols);
//  - the transforms: s0 is the stored profile itself, every
//    other candidate starts from the normalised shaping
//    layer, s1–s3 ARE the watchdog shapes, and the stored
//    profile is never mutated;
//  - the memory: JSON round-trip, corrupt entries dropped,
//    stale wins evicted, unknown networks inherit nothing;
//  - the runner: probe order, first-confirmed-wins, a
//    freezes verdict never wins, cancel stops the run, and
//    every verdict reaches onResult (build 2115: the sweep
//    no longer stops at the winner or at a run budget —
//    see build2115_dpi_test.dart);
//  - the settings gate: dpiLabEnabled defaults OFF and a
//    pre-2107 store keeps it off;
//  - the wiring: the connect/switch fast paths consult the
//    Lab only under the toggle and only on a shape-cache
//    miss, and the config builder never hears of the Lab.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/anti_filter.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/dpi_lab.dart';
import 'package:firefox_vpn/xray/shapes.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String _src(String rel) => File('lib/$rel').readAsStringSync();

/// The segment of [source] from [start] to the next [end]
/// marker (or EOF) — the shape the tree's source pins use to
/// scope a claim to one function.
String _segment(String source, String start, [String? end]) {
  final at = source.indexOf(start);
  expect(at, isNonNegative, reason: 'marker not found: $start');
  final rest = source.substring(at);
  if (end == null) return rest;
  final cut = rest.indexOf(end, start.length);
  return cut < 0 ? rest : rest.substring(0, cut);
}

Profile _profile({
  Protocol protocol = Protocol.vless,
  String security = 'tls',
}) => Profile(
  id: 'lab-test',
  name: 'Lab test',
  protocol: protocol,
  address: 'nl1.example.net',
  port: 443,
  uuidOrPassword: '00000000-0000-0000-0000-000000000000',
  network: 'tcp',
  security: security,
  sni: 'nl1.example.net',
);

void main() {
  group('candidates — the shipped set and its order', () {
    test('probe order is the escalation set first, then the variants', () {
      // Build 2126 (D7 + D9): the list grew by the
      // F-family probes (af-f2…af-f15) and the randomized
      // multisplit (af-z1r) — supersession of the 2107
      // pin, order as shipped in dpi_lab.dart.
      // Build 2127 supersession (H1): the six Zapret
      // engine candidates (zap-*) join after af-z5.
      expect(dpiLabCandidates.map((c) => c.id).toList(), [
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
      for (final c in dpiLabCandidates) {
        expect(c.label, isNotEmpty);
        expect(c.detail, isNotEmpty);
        expect(dpiLabCandidateById(c.id), same(c));
      }
      expect(dpiLabCandidateById('nope'), isNull);
    });

    test('a TLS profile gets the full set; others get stock + noise', () {
      // Build 2126: 25 (was 15 before D7 + D9). Build
      // 2127 supersession (H1): 31 — the six real Zapret
      // engine candidates joined the set.
      // Build 2135 supersession (audit A34-01): a non-TLS
      // TCP profile additionally gets the Zapret engine's
      // byte-level modes (split / disorder / OOB — raw
      // segment operations below the config layer); the
      // TLS-parsing engine modes (tlsrec, fake) and every
      // config-layer fragment stay TLS-only. The TLS set
      // itself is unchanged (31, pinned above and in
      // build2120).
      expect(dpiLabCandidatesFor(_profile()).length, 31);
      expect(dpiLabCandidatesFor(_profile(security: '')).map((c) => c.id), [
        's0',
        'zap-split',
        'zap-disorder',
        'zap-oob',
        'zap-disoob',
        'af-tcp-noise',
      ]);
      expect(
        dpiLabCandidatesFor(_profile(security: 'reality')).map((c) => c.id),
        [
          's0',
          'zap-split',
          'zap-disorder',
          'zap-oob',
          'zap-disoob',
          'af-tcp-noise',
        ],
      );
    });
  });

  group('eligibility — what the Lab may honestly grade', () {
    test('core-served TCP protocols are eligible', () {
      for (final proto in [
        Protocol.vless,
        Protocol.vmess,
        Protocol.trojan,
        Protocol.shadowsocks,
        Protocol.socks,
        Protocol.http,
      ]) {
        expect(
          dpiLabEligible(_profile(protocol: proto)),
          isTrue,
          reason: '$proto',
        );
      }
    });

    test('WireGuard, Hysteria2 and sidecar protocols are not', () {
      for (final proto in [
        Protocol.wireguard,
        Protocol.hysteria2,
        Protocol.tuic,
        Protocol.anytls,
        Protocol.snell,
        Protocol.naive,
        Protocol.mieru,
        Protocol.tailscale,
        Protocol.openconnect,
      ]) {
        expect(
          dpiLabEligible(_profile(protocol: proto)),
          isFalse,
          reason: '$proto',
        );
      }
    });

    test('candidate application re-checks eligibility and TLS gating', () {
      final tls = _profile();
      final plain = _profile(security: '');
      expect(dpiLabCandidateApplies('af-ech', tls), isTrue);
      expect(dpiLabCandidateApplies('af-ech', plain), isFalse);
      expect(dpiLabCandidateApplies('af-tcp-noise', plain), isTrue);
      expect(
        dpiLabCandidateApplies('s1', _profile(protocol: Protocol.wireguard)),
        isFalse,
      );
      expect(dpiLabCandidateApplies('bogus', tls), isFalse);
    });
  });

  group('transforms — profileWithCandidate', () {
    test('s0 returns the stored profile itself, shaping and all', () {
      final p = _profile()..afEch = true;
      expect(identical(profileWithCandidate(p, 's0'), p), isTrue);
      expect(identical(profileWithCandidate(p, 'unknown-id'), p), isTrue);
    });

    test('non-stock candidates start from the normalised shaping layer', () {
      final p = _profile()
        ..afEch = true
        ..afUnfilter = true
        ..afFragment = 'f7'
        ..afMixedSni = true
        ..afTcpNoise = true;
      final shaped = profileWithCandidate(p, 'af-f1');
      expect(shaped.afFragment, 'f1');
      expect(shaped.afEch, isFalse);
      expect(shaped.afUnfilter, isFalse);
      expect(shaped.afMixedSni, isFalse);
      expect(shaped.afTcpNoise, isFalse);
      // The stored profile is never mutated.
      expect(p.afEch, isTrue);
      expect(p.afFragment, 'f7');
      expect(p.afTcpNoise, isTrue);
    });

    test('normalisation also clears the direct spellings of the layer', () {
      // Verification iteration 1: a stored fingerprint/cipher
      // pair IS s2's payload and a stored dialMode IS s3's —
      // left in place, s2 and s3 build byte-identical configs
      // and the Lab crowns one on timing variance.
      final p = _profile()
        ..fingerprint = 'unsafe'
        ..cipherSuites = afUnfilterCipherSuites
        ..dialMode = 'oob.0'
        ..finalMask = '{"tcp":[{"type":"fragment"}]}'
        ..echConfigList = 'AAAA-stored';
      final s = XraySettings();
      final s2 = buildTestConfig(profileWithCandidate(p, 's2'), s);
      final s3 = buildTestConfig(profileWithCandidate(p, 's3'), s);
      expect(s2, isNot(s3));
      expect(s3, isNot(contains('cipherSuites')));
      expect(s2, isNot(contains('dialMode')));
      final f1 = profileWithCandidate(p, 'af-f1');
      expect(f1.fingerprint, isEmpty);
      expect(f1.cipherSuites, isEmpty);
      expect(f1.dialMode, isEmpty);
      expect(f1.finalMask, isEmpty);
      expect(f1.echConfigList, isEmpty);
      // The stored profile keeps its own fields.
      expect(p.fingerprint, 'unsafe');
      expect(p.dialMode, 'oob.0');
    });

    test('fragment candidates are not offered on UDP transports', () {
      final quic = _profile()..network = 'quic';
      final ids = dpiLabCandidatesFor(quic).map((c) => c.id).toList();
      expect(ids, isNot(contains('s1')));
      expect(ids, isNot(contains('af-mirage')));
      expect(ids, isNot(contains('af-f1')));
      // Build 2114: the Zapret fragment candidates are
      // TCP-only shapes too — same exclusion.
      expect(ids, isNot(contains('af-z1')));
      expect(ids, isNot(contains('af-z2')));
      expect(ids, isNot(contains('af-z3')));
      // Build 2126 (D7 + D9): the new fragment probes are
      // TCP-only shapes too — same exclusion.
      expect(ids, isNot(contains('af-f2')));
      expect(ids, isNot(contains('af-f15')));
      expect(ids, isNot(contains('af-z1r')));
      expect(ids, contains('s2'));
      expect(ids, contains('af-tcp-noise'));
      final kcp = _profile()..network = 'kcp';
      expect(
        dpiLabCandidatesFor(kcp).map((c) => c.id),
        isNot(contains('af-f1')),
      );
      expect(
        dpiLabCandidatesFor(kcp).map((c) => c.id),
        isNot(contains('af-z1')),
      );
    });

    test('TCP-only candidates are not offered on UDP transports', () {
      // Verification iteration 2, proven against the patched
      // core's source: dialMode oob.0 is applied only to TCP
      // destinations ("UDP is left as is"), and af-unfilter's
      // only delta over s2 is the same inert tcp finalmask.
      // (QUIC profiles are not Lab-eligible at all since
      // iteration 3 — the core removed QUIC — so KCP is the
      // canonical UDP transport here.)
      final kcp = _profile()..network = 'kcp';
      final ids = dpiLabCandidatesFor(kcp).map((c) => c.id).toList();
      expect(ids, isNot(contains('s3')));
      expect(ids, isNot(contains('af-unfilter')));
      expect(ids, ['s0', 's2', 'af-mixed-sni', 'af-ech', 'af-tcp-noise']);
    });

    test('QUIC profiles are not eligible — the core removed QUIC', () {
      final quic = _profile()..network = 'quic';
      expect(dpiLabEligible(quic), isFalse);
      expect(dpiLabCandidateApplies('s0', quic), isFalse);
    });

    test('mixed-case SNI is not offered for an IP-literal server name', () {
      // applyAntiFilter skips IP literals, so the candidate
      // would grade the normalised baseline (iteration 3).
      final byAddress = _profile()..sni = '';
      byAddress.address = '203.0.113.7';
      expect(
        dpiLabCandidatesFor(byAddress).map((c) => c.id),
        isNot(contains('af-mixed-sni')),
      );
      final bySni = _profile()..sni = '198.51.100.9';
      expect(
        dpiLabCandidatesFor(bySni).map((c) => c.id),
        isNot(contains('af-mixed-sni')),
      );
      expect(
        dpiLabCandidatesFor(_profile()).map((c) => c.id),
        contains('af-mixed-sni'),
      );
    });

    test('normalisation preserves a pin-shaped fingerprint', () {
      // A 64-hex fingerprint is a certificate pin, not a
      // uTLS name (build 2057): candidates must not strip it.
      final pin = 'a' * 64;
      final p = _profile()..fingerprint = pin;
      expect(profileWithCandidate(p, 'af-f1').fingerprint, pin);
      expect(profileWithCandidate(p, 'af-tcp-noise').fingerprint, pin);
      final named = _profile()..fingerprint = 'chrome';
      expect(profileWithCandidate(named, 'af-f1').fingerprint, isEmpty);
    });

    test('every candidate\'s built config carries the pin', () {
      // Config-level pin (iteration 3): the pin must reach
      // pinnedPeerCertSha256 for every candidate — including
      // s2, whose shape overwrites the fingerprint field, so
      // the transform carries the pin in tlsCertPin instead.
      final pin = 'b' * 64;
      final p = _profile()..fingerprint = pin;
      final s = XraySettings();
      for (final c in dpiLabCandidatesFor(p)) {
        final config = buildTestConfig(profileWithCandidate(p, c.id), s);
        expect(config, contains('pinnedPeerCertSha256'), reason: c.id);
      }
      expect(profileWithCandidate(p, 's2').tlsCertPin, pin);
    });

    test('s2 carries the pin even over an invalid stored tlsCertPin', () {
      // The builder treats an invalid tlsCertPin as absent
      // and falls back to the fingerprint pin — the carry
      // guard tests validity, not emptiness (iteration 4).
      final pin = 'c' * 64;
      final p = _profile()
        ..fingerprint = pin
        ..tlsCertPin = 'garbage';
      final shaped = profileWithCandidate(p, 's2');
      expect(shaped.tlsCertPin, pin);
      expect(
        buildTestConfig(shaped, XraySettings()),
        contains('pinnedPeerCertSha256'),
      );
      // A VALID stored tlsCertPin is the profile's own pin
      // and is never overwritten.
      final own = _profile()
        ..fingerprint = pin
        ..tlsCertPin = 'd' * 64;
      expect(profileWithCandidate(own, 's2').tlsCertPin, 'd' * 64);
    });

    test('a trailing-dot IPv4 SNI is still an IP literal', () {
      final p = _profile()..sni = '203.0.113.7.';
      expect(
        dpiLabCandidatesFor(p).map((c) => c.id),
        isNot(contains('af-mixed-sni')),
      );
      expect(dpiLabCandidateApplies('af-mixed-sni', p), isFalse);
    });

    test('TLS candidates need a protocol the builder shapes', () {
      // Defence in depth behind the profile sanitiser: a
      // shadowsocks profile carrying security 'tls' in memory
      // gets none of the SHAPING-LAYER candidates — its
      // outbound never runs the shaping layer. Build 2135
      // (audit A34-01): the Zapret engine's byte-level modes
      // are not shaping-layer candidates (they chain the
      // dial through the desync proxy, below the config
      // layer), so they are offered like on any other
      // non-TLS TCP profile.
      final ss = _profile(protocol: Protocol.shadowsocks);
      expect(dpiLabCandidatesFor(ss).map((c) => c.id), [
        's0',
        'zap-split',
        'zap-disorder',
        'zap-oob',
        'zap-disoob',
        'af-tcp-noise',
      ]);
    });

    test('s1–s3 are the watchdog shapes over the normalised base', () {
      final p = _profile()..afEch = true;
      final s1 = profileWithCandidate(p, 's1');
      expect(s1.afFragment, watchdogFragmentShape);
      expect(s1.afEch, isFalse);
      final s2 = profileWithCandidate(p, 's2');
      expect(s2.fingerprint, 'unsafe');
      expect(s2.cipherSuites, afUnfilterCipherSuites);
      final s3 = profileWithCandidate(p, 's3');
      expect(s3.dialMode, watchdogDialModePreset);
      // The same transforms shapes.dart itself would build
      // from a clean profile agree field for field.
      final viaShapes = profileWithShape(_profile(), shapeFragment);
      expect(s1.afFragment, viaShapes.afFragment);
    });

    test('each anti-filter candidate sets exactly its own field', () {
      final p = _profile();
      expect(profileWithCandidate(p, 'af-mirage').afFragment, 'mirage');
      expect(profileWithCandidate(p, 'af-mixed-sni').afMixedSni, isTrue);
      expect(profileWithCandidate(p, 'af-ech').afEch, isTrue);
      expect(profileWithCandidate(p, 'af-unfilter').afUnfilter, isTrue);
      expect(profileWithCandidate(p, 'af-tcp-noise').afTcpNoise, isTrue);
    });

    test('every candidate builds a real test config', () {
      final p = _profile();
      final s = XraySettings();
      for (final c in dpiLabCandidatesFor(p)) {
        final config = buildTestConfig(profileWithCandidate(p, c.id), s);
        expect(config, contains('"outbounds"'), reason: c.id);
      }
      // The ECH candidate's config really carries the ECH
      // shape, and F12's carries its fragment lengths.
      final ech = buildTestConfig(profileWithCandidate(p, 'af-ech'), s);
      expect(ech, contains('echConfigList'));
      final f12 = buildTestConfig(profileWithCandidate(p, 's1'), s);
      expect(f12, contains('"75"'));
      final stock = buildTestConfig(profileWithCandidate(p, 's0'), s);
      expect(stock, isNot(contains('echConfigList')));
    });
  });

  group('memory — DpiLabMemory', () {
    DpiLabWin win({String candidate = 's1', int at = 1000000}) => DpiLabWin(
      candidateId: candidate,
      profileId: 'lab-test',
      profileName: 'Lab test',
      ms: 120,
      exitCountry: 'NL',
      verifiedMs: at,
    );

    test('record + lookup round-trips, keyed by network', () {
      final m = DpiLabMemory();
      expect(m.lookup('wifi:abcd'), isNull);
      m.record('wifi:abcd', win());
      expect(m.lookup('wifi:abcd', nowMs: 1000000)?.candidateId, 's1');
      expect(m.lookup('cellular:abcd', nowMs: 1000000), isNull);
      expect(m.lookup('', nowMs: 1000000), isNull);
      m.record('', win());
      expect(m.length, 1);
    });

    test('JSON round-trips; corrupt entries are dropped, never fatal', () {
      final m = DpiLabMemory()..record('wifi:abcd', win());
      final restored = DpiLabMemory.fromJson(
        jsonDecode(jsonEncode(m.toJson())),
      );
      expect(restored.lookup('wifi:abcd', nowMs: 1000000)?.ms, 120);
      final corrupt = DpiLabMemory.fromJson({
        'wifi:ok': win().toJson(),
        'wifi:bad-candidate': win(candidate: 'nope').toJson(),
        'wifi:not-a-map': 42,
        'wifi:no-time': {'candidate': 's1', 'profile': 'x'},
      });
      expect(corrupt.length, 1);
      expect(corrupt.lookup('wifi:ok', nowMs: 1000000), isNotNull);
      expect(DpiLabMemory.fromJson('garbage').length, 0);
      expect(DpiLabMemory.fromJson(null).length, 0);
    });

    test('a stale win is evicted on read; a fresh one is kept', () {
      final m = DpiLabMemory()..record('wifi:abcd', win(at: 0));
      expect(m.lookup('wifi:abcd', nowMs: DpiLabMemory.maxAgeMs), isNotNull);
      expect(m.lookup('wifi:abcd', nowMs: DpiLabMemory.maxAgeMs + 1), isNull);
      expect(m.length, 0);
    });

    test('an empty-string network key is dropped at load', () {
      // lookup('') can never evict it, so fromJson drops it
      // (iteration 4).
      final m = DpiLabMemory.fromJson({'': win().toJson()});
      expect(m.length, 0);
    });

    test('a non-finite timestamp drops only its own entry', () {
      // A stored 1e999 decodes to double.infinity; its
      // toInt() would throw and take the whole memory read
      // down with it (verification iteration 1).
      final m = DpiLabMemory.fromJson({
        'wifi:ok': win().toJson(),
        'wifi:inf': {'candidate': 's1', 'profile': 'x', 'at': double.infinity},
        'wifi:nan-ms': {
          'candidate': 's1',
          'profile': 'x',
          'at': 1000000,
          'ms': double.nan,
        },
      });
      expect(m.length, 2);
      expect(m.lookup('wifi:ok', nowMs: 1000000), isNotNull);
      expect(m.lookup('wifi:nan-ms', nowMs: 1000000)?.ms, -1);
    });

    test('a far-future win is not trusted; a small skew is', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final m = DpiLabMemory()
        ..record('wifi:future', win(at: now + DpiLabMemory.maxAgeMs + 1000))
        ..record('wifi:skew', win(at: now + 5000));
      expect(m.lookup('wifi:future', nowMs: now), isNull);
      expect(m.lookup('wifi:skew', nowMs: now), isNotNull);
    });

    test('recording a fresh win prunes long-dead ones', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final m = DpiLabMemory()
        ..record('wifi:dead', win(at: 1000))
        ..record('wifi:fresh', win(at: now));
      expect(m.lookup('wifi:fresh', nowMs: now), isNotNull);
      expect(m.wins.containsKey('wifi:dead'), isFalse);
    });

    test('forget and clear empty the memory', () {
      final m = DpiLabMemory()
        ..record('wifi:abcd', win())
        ..record('cellular:abcd', win());
      m.forget('wifi:abcd');
      expect(m.length, 1);
      m.clear();
      expect(m.length, 0);
    });
  });

  group('network labels', () {
    test('fingerprints read as plain network names', () {
      expect(dpiLabNetworkLabel(''), 'Unknown network');
      expect(dpiLabNetworkLabel('wifi'), 'Wi-Fi');
      expect(dpiLabNetworkLabel('wifi:abcd1234'), 'Wi-Fi · abcd1234');
      expect(dpiLabNetworkLabel('cellular'), 'Mobile');
      expect(dpiLabNetworkLabel('cellular:abcd1234'), 'Mobile · abcd1234');
      expect(dpiLabNetworkLabel('ethernet'), 'Ethernet');
    });
  });

  group('runner — runDpiLabDiscovery with fake probers', () {
    // Queue-driven probers: each measure consumes one queued
    // answer; endurance consumes one queued hold map.
    ({DpiLabMeasure measure, DpiLabEndure endure, List<String> probed}) probers(
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

    test('all blocked: every candidate probed, no winner', () async {
      // Build 2114: the candidate set grew to 13 (af-z1..z3);
      // build 2120 grew it to 15 (af-z4..z5).
      final f = probers(List.filled(15, -1), []);
      final results = await runDpiLabDiscovery(
        profile: _profile(),
        settings: XraySettings(),
        measure: f.measure,
        endure: f.endure,
      );
      // Build 2126 supersession (D7 + D9): the sweep now
      // probes 25 candidates (was 15) — the runner count
      // pins in this group moved with the candidate list.
      // Build 2127 supersession (H1): 31 with the Zapret
      // engine candidates.
      expect(results.length, 31);
      expect(results.every((r) => r.verdict == DpiLabVerdict.blocked), isTrue);
      expect(dpiLabWinner(results), isNull);
    });

    test(
      'the first CONFIRMED candidate is the winner; the sweep probes on',
      () async {
        // Build 2115 (owner's order): discovery no longer
        // stops at the winner — every candidate is measured
        // so the owner can compare and pick by hand. The
        // winner is still the FIRST confirmed result.
        final f = probers(
          [-1, 140],
          [
            {'p0': 140, 'p1': 150, 'p2': 145, 'held': 1},
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
        expect(results.length, 31);
        expect(results[0].verdict, DpiLabVerdict.blocked);
        expect(results[1].verdict, DpiLabVerdict.works);
        expect(results[1].candidate.id, 's1');
        expect(results[1].exitCountry, 'NL');
        expect(
          results.skip(2).every((r) => r.verdict == DpiLabVerdict.blocked),
          isTrue,
        );
        expect(dpiLabWinner(results)?.candidate.id, 's1');
        expect(seen, results);
      },
    );

    test(
      'stock confirming is the winner; the sweep still probes the rest',
      () async {
        final f = probers(
          [90],
          [
            {'p0': 90, 'p1': 95, 'p2': 92, 'held': 1},
          ],
        );
        final results = await runDpiLabDiscovery(
          profile: _profile(),
          settings: XraySettings(),
          measure: f.measure,
          endure: f.endure,
        );
        expect(results.length, 31);
        expect(f.probed.length, 31);
        expect(results.first.candidate.id, 's0');
        expect(results.first.verdict, DpiLabVerdict.works);
        expect(dpiLabWinner(results)?.candidate.id, 's0');
      },
    );

    test('answers-then-freezes is not a win; the run moves on', () async {
      final f = probers(
        [100, 110],
        [
          {'p0': 100, 'p1': -1, 'p2': -1, 'held': 0},
          {'p0': 110, 'p1': 115, 'p2': 112, 'held': 1},
        ],
      );
      final results = await runDpiLabDiscovery(
        profile: _profile(),
        settings: XraySettings(),
        measure: f.measure,
        endure: f.endure,
      );
      expect(results.length, 31);
      expect(results[0].verdict, DpiLabVerdict.freezes);
      expect(results[0].p1, -1);
      expect(dpiLabWinner(results)?.candidate.id, 's1');
    });

    test(
      'an endurance that could not run grades unconfirmed, never works',
      () async {
        // Verification iteration 1: this originally graded
        // "freezes" — a claim about the network that no
        // confirmation ever ran to support.
        final f = probers([100, -1, -1, -1, -1, -1, -1, -1, -1, -1], [null]);
        final results = await runDpiLabDiscovery(
          profile: _profile(),
          settings: XraySettings(),
          measure: f.measure,
          endure: f.endure,
        );
        expect(results[0].verdict, DpiLabVerdict.unconfirmed);
        expect(dpiLabWinner(results), isNull);
      },
    );

    test(
      'a held map without a held key is unconfirmed, not a freeze',
      () async {
        final results = await runDpiLabDiscovery(
          profile: _profile(security: ''),
          settings: XraySettings(),
          measure: (config) async => {'ms': 90, 'countryCode': 'NL'},
          endure: (config) async => {'p0': 90},
        );
        expect(results[0].verdict, DpiLabVerdict.unconfirmed);
      },
    );

    test(
      'throwing or malformed probers grade candidates, never abort',
      () async {
        var calls = 0;
        final results = await runDpiLabDiscovery(
          profile: _profile(security: ''),
          settings: XraySettings(),
          measure: (config) async {
            calls++;
            if (calls == 1) throw StateError('channel gone');
            // A wrong-typed ms from the channel must not crash
            // the run's casts.
            return {'ms': 'not-a-number', 'countryCode': 42};
          },
          endure: (config) async => null,
        );
        // Build 2135 supersession (audit A34-01): a non-TLS
        // profile now sweeps six candidates (was two) — the
        // byte-level Zapret engine modes joined the offer.
        expect(results.length, 6);
        expect(
          results.every((r) => r.verdict == DpiLabVerdict.blocked),
          isTrue,
        );
      },
    );

    test('an endurance that throws grades unconfirmed', () async {
      final results = await runDpiLabDiscovery(
        profile: _profile(security: ''),
        settings: XraySettings(),
        measure: (config) async => {'ms': 80, 'countryCode': 'NL'},
        endure: (config) async => throw StateError('core gone'),
      );
      expect(results[0].verdict, DpiLabVerdict.unconfirmed);
      expect(results[0].exitCountry, 'NL');
    });

    test('the runner itself refuses an ineligible profile', () async {
      final results = await runDpiLabDiscovery(
        profile: _profile(protocol: Protocol.wireguard),
        settings: XraySettings(),
        measure: (config) async => {'ms': 50},
        endure: (config) async => {'held': 1},
      );
      expect(results, isEmpty);
    });

    test('cancel stops between candidates', () async {
      final f = probers(List.filled(10, -1), []);
      var calls = 0;
      final results = await runDpiLabDiscovery(
        profile: _profile(),
        settings: XraySettings(),
        measure: f.measure,
        endure: f.endure,
        isCancelled: () => ++calls > 1,
      );
      expect(results.length, 1);
    });

    test(
      'the sweep reaches a winner sitting last — nothing truncates it',
      () async {
        // Build 2115: the wall-clock run budget is gone with
        // the winner break. A strategy that only confirms at
        // the very end of the probe order is still measured —
        // and so is every candidate before it.
        final f = probers(
          // Build 2126 supersession (D7 + D9): the winner
          // sits last of 25 now (was last of 15). Build
          // 2127 (H1): last of 31.
          [...List.filled(30, -1), 140],
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
        expect(results.length, 31);
        expect(results.last.verdict, DpiLabVerdict.works);
        expect(
          dpiLabWinner(results)?.candidate.id,
          results.last.candidate.id,
        );
      },
    );

    test('a non-TLS profile probes its six candidates', () async {
      // Build 2135 supersession (audit A34-01): was two
      // (stock + noise) up to 2134; the byte-level Zapret
      // engine modes joined the non-TLS offer.
      final f = probers([-1, -1], []);
      final results = await runDpiLabDiscovery(
        profile: _profile(security: ''),
        settings: XraySettings(),
        measure: f.measure,
        endure: f.endure,
      );
      expect(results.map((r) => r.candidate.id), [
        's0',
        'zap-split',
        'zap-disorder',
        'zap-oob',
        'zap-disoob',
        'af-tcp-noise',
      ]);
    });
  });

  group('the settings gate', () {
    test('dpiLabEnabled defaults OFF and persists', () {
      final s = XraySettings();
      expect(s.dpiLabEnabled, isFalse);
      s.dpiLabEnabled = true;
      final restored = XraySettings.fromJson(s.toJson());
      expect(restored.dpiLabEnabled, isTrue);
    });

    test('a pre-2107 settings document keeps the Lab off', () {
      final doc = XraySettings().toJson()..remove('dpiLabEnabled');
      expect(XraySettings.fromJson(doc).dpiLabEnabled, isFalse);
    });
  });

  group('wiring — source pins', () {
    test('the Lab dial is gated by the toggle and the applicability check', () {
      final controller = _src('xray/xray_controller.dart');
      final dial = _segment(
        controller,
        '({Profile profile, String candidateId})? _dpiLabDial',
        'Future<List<DpiLabResult>> runDpiLab',
      );
      expect(dial, contains('if (!settings.dpiLabEnabled) return null;'));
      expect(dial, contains('dpiLabCandidateApplies(win.candidateId, p)'));
      expect(dial, contains('profileWithCandidate(p, win.candidateId)'));
    });

    test('a Lab-dialed session stands the shape watchdog down', () {
      // Verification iteration 1: escalating shapes of the
      // stored profile would silently discard the Lab
      // strategy and could record a shape win for a config
      // the Lab never graded.
      final controller = _src('xray/xray_controller.dart');
      final escalate = _segment(
        controller,
        'Future<void> _escalateShape()',
        'void _resetWatchdogBases()',
      );
      expect(
        escalate,
        contains('if (_labDialActive && settings.dpiLabEnabled)'),
      );
      expect(escalate, contains('_resetWatchdogBases();'));
      expect(controller, contains('_labDialActive = true;'));
      // Iteration 2: the stand-down survives an app restart —
      // the candidate is persisted beside connectedProfileId
      // and restored when refreshState adopts the session,
      // and the session-end funnel clears the flag.
      expect(
        controller,
        contains(
          "'labDialCandidate': _labDialActive ? _labDialCandidateId : '',",
        ),
      );
      expect(controller, contains('_storedLabDialCandidate'));
      final stop = _segment(
        controller,
        'Future<void> _stopTunnel()',
        'Future<(String, bool)> _testConfigFor',
      );
      expect(stop, contains('_clearLabDialState();'));
      // Iteration 3: the adoption restore is a one-shot
      // latch that consumes the stored candidate and is
      // gated on the Lab toggle.
      expect(controller, contains('bool _labAdoptionDone = false;'));
      expect(controller, contains('void _clearLabDialState()'));
      // Iteration 4: the latch waits for the store load (the
      // shell fires refreshState concurrently with load()),
      // and a terminally failed attempt clears its Lab-dial
      // state in the catch.
      expect(controller, contains('if (!_labAdoptionDone && _loaded) {'));
      final tailAt = controller.lastIndexOf('lastError = e.toString();');
      expect(tailAt, isNonNegative);
      expect(
        controller.substring(tailAt, tailAt + 700),
        contains('_clearLabDialState();'),
      );
    });

    test('the store guard key set does not name the Lab key alone', () {
      // Verification iteration 1 (F3): dpiLabMemory rides the
      // store document, but a document whose ONLY key is it
      // must still read as foreign to the 2098 guard.
      final controller = _src('xray/xray_controller.dart');
      final keys = _segment(controller, 'const knownStoreKeys', '};');
      expect(keys, isNot(contains('dpiLabMemory')));
      expect(keys, contains('shapeCache'));
    });

    test('the run itself re-checks the gate and refuses overlap', () {
      final controller = _src('xray/xray_controller.dart');
      final run = _segment(
        controller,
        'Future<List<DpiLabResult>> runDpiLab(',
        'Future<List<DpiLabResult>> _runDpiLabGuarded(',
      );
      expect(run, contains('if (!settings.dpiLabEnabled) return const [];'));
      expect(run, contains('if (_dpiLabRunning) return const [];'));
    });

    test('connect and switch consult the Lab only on a shape-cache miss', () {
      final controller = _src('xray/xray_controller.dart');
      final connect = _segment(
        controller,
        'final win = shapeCache.lookup(p.id, networkFp);',
        '// The chain (build 2029A)',
      );
      expect(connect, contains('if (win == null) {'));
      expect(connect, contains('_dpiLabDial(p)'));
      final sw = _segment(
        controller,
        'final win = shapeCache.lookup(next.id, networkFp);',
        'final pins = await _providerDnsPins(dialProfile);',
      );
      expect(sw, contains('if (win == null) {'));
      expect(sw, contains('_dpiLabDial(next)'));
    });

    test('a failed attempt offers the Lab only when it is on and eligible', () {
      final controller = _src('xray/xray_controller.dart');
      final tail = _segment(
        controller,
        'lastError = e.toString();\n      // Build 2107',
        'rethrow;',
      );
      expect(
        tail,
        contains('if (settings.dpiLabEnabled && dpiLabEligible(p)) {'),
      );
      expect(tail, contains('dpiLabOfferProfileId = p.id;'));
    });

    test('a win is filed under the network the run measured', () {
      final controller = _src('xray/xray_controller.dart');
      final run = _segment(
        controller,
        'Future<List<DpiLabResult>> _runDpiLabGuarded(',
        'final results = await runDpiLabDiscovery(',
      );
      expect(run, contains('await refreshNetworkFingerprint();'));
      expect(run, contains('_dpiLabRunFp = networkFp;'));
      final remember = _segment(
        controller,
        'Future<String> rememberDpiLabWin(',
        'Future<void> forgetDpiLabWin(',
      );
      expect(
        remember,
        contains('_dpiLabRunFp.isNotEmpty ? _dpiLabRunFp : networkFp'),
      );
      // Build 2115: the gate is dpiLabCanRemember — its
      // non-manual path still files confirmed wins only (the
      // matrix is pinned in build2115_dpi_test.dart).
      expect(remember, contains('dpiLabCanRemember(result, manual: manual)'));
    });

    test('the memory rides the store document and the backup restore', () {
      final controller = _src('xray/xray_controller.dart');
      expect(controller, contains("'dpiLabMemory': dpiLabMemory.toJson(),"));
      expect(
        controller,
        contains("dpiLabMemory = DpiLabMemory.fromJson(doc['dpiLabMemory']);"),
      );
      expect(
        controller,
        contains(
          "newDpiLabMemory = DpiLabMemory.fromJson(doc['dpiLabMemory']);",
        ),
      );
    });

    test('the config builder never hears of the Lab', () {
      // The Lab acts only through profile copies and the
      // existing builders: with the toggle off there is no
      // Lab state anywhere near config generation.
      expect(_src('xray/config_builder.dart'), isNot(contains('dpiLab')));
      expect(_src('xray/config_builder.dart'), isNot(contains('dpi_lab')));
    });

    test('settings carries the toggle and the page row', () {
      final settings = _src('ui/ember/ember_settings.dart');
      final panel = _segment(
        settings,
        "title: 'DPI Strategy Lab'",
        'DpiLabPage',
      );
      expect(panel, contains('s.dpiLabEnabled = v;'));
      expect(panel, contains('if (s.dpiLabEnabled)'));
    });

    test('home offers the Lab from the failed-connect card', () {
      final home = _src('ui/ember/ember_home.dart');
      final offer = _segment(
        home,
        'xray.settings.dpiLabEnabled &&',
        'if (xray.reconnectNotice.isNotEmpty)',
      );
      expect(offer, contains('xray.dpiLabOfferProfileId.isNotEmpty'));
      // Build 2116 (B13-9): deliberate re-point — the offer
      // row was extracted into the shared _labOfferRow
      // helper (so it can also surface with no selected
      // profile); the card calls the helper, and the helper
      // is what opens the Lab preselected with the failed
      // profile. Intent unchanged.
      expect(offer, contains('_labOfferRow(context, xray)'));
      final helper = home.substring(home.indexOf('Widget _labOfferRow('));
      expect(helper, contains('DpiLabPage('));
      expect(helper, contains('initialProfileId: xray.dpiLabOfferProfileId'));
    });
  });
}
