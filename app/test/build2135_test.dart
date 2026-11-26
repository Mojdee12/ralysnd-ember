// Build 2135 — the audit-2134 fix build (owner: «تو بیلد
// بعدی مشکلاتم حل کن»). Scope frozen to the audit findings:
//
//  - A34-01 (the owner's live problem): the DPI Lab had NO
//    applicable strategy for non-TLS profiles — every
//    shaping candidate was flagged tlsOnly, so his
//    Cloudflare VLESS·HTTP port-80 configs could only ever
//    dial stock and no remembered winner ever applied. The
//    split is now per mechanism: the Zapret engine's
//    byte-level modes (split / disorder / OOB — raw TCP
//    segment operations that never parse TLS semantics)
//    are offered on non-TLS TCP profiles; the TLS-parsing
//    candidates (the engine's TLS record split and fake
//    first segment, and every config-layer fragment — the
//    shaping layer emits nothing for a non-TLS profile)
//    stay TLS-only. BOTH gates read the one function
//    (dpiLabCandidatesFor), so the Lab offer and the
//    connect-time applicability check cannot disagree.
//    The TLS profile's candidate set is byte-for-byte
//    2134's.
//  - A34-02: the "Provider DNS … carries no DNS" warning
//    no longer fires for literal-IP profiles (the literal
//    early-out runs first) and is journaled at most once
//    per connect for a profile.
//  - A34-03: Zapret + Sudoku helpers join the process-
//    birth orphan reaper in EmberApplication.
//  - A34-04: the OLCRTC 110 s readiness wait observes
//    cancellation — a disconnect aborts it promptly and
//    stops the client (no orphan).
//  - A34-05: the 12 s data-plane proof takes ONE
//    confirmation re-check after a ~5 s grace when bytes
//    actually came back during the window (slow-but-alive
//    servers); zero downlink keeps the old verdict
//    exactly. The 2116 honesty rule is untouched: nothing
//    is stamped Connected without a passing live check.
//
// A26-02 (owner-waived pin exception) and A26-06
// (sidecar DNS — the DNS law) are deliberately NOT
// touched; A26-22 / A26-23 stay parked (trust-model /
// platform limits — see build2135-progress.md).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/dpi_lab.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/zapret_args.dart';

String _src(String rel) => File('lib/$rel').readAsStringSync();
String _kotlin(String rel) => File(
  'android/app/src/main/kotlin/com/ralysnd/ember/$rel',
).readAsStringSync();

/// The segment of [source] from [start] to the next [end]
/// marker (or EOF) — the shape the tree's source pins use
/// to scope a claim to one function. Throws (rather than
/// expect) so it can run at group-declaration time, where
/// the source segments are computed.
String _segment(String source, String start, [String? end]) {
  final at = source.indexOf(start);
  if (at < 0) throw StateError('marker not found: $start');
  final rest = source.substring(at);
  if (end == null) return rest;
  final cut = rest.indexOf(end, start.length);
  return cut < 0 ? rest : rest.substring(0, cut);
}

/// The owner's failing shape: VLESS, no security, raw TCP,
/// port 80, a hostname address (his Cloudflare CUSTOM
/// profiles from the 2026-11-22 export).
Profile _cfPlain({String network = 'tcp'}) => Profile(
  id: 'cf1',
  protocol: Protocol.vless,
  name: 'CF plain',
  address: 'gw.example.net',
  port: 80,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  network: network,
  security: '',
  sni: '',
);

Profile _tls({String network = 'tcp'}) => Profile(
  id: 't1',
  protocol: Protocol.vless,
  name: 'TLS',
  address: 'nl1.example.net',
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  network: network,
  security: 'tls',
  sni: 'nl1.example.net',
);

/// The byte-level engine modes A34-01 unflags, in probe
/// order.
const _byteLevel = ['zap-split', 'zap-disorder', 'zap-oob', 'zap-disoob'];

void main() {
  group('build 2135 — source pins', () {
    test('pubspec is build 2135', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.2.0+2155'),
      );
    });
  });

  // ---- A34-01 ------------------------------------------------------------

  group('A34-01 — the byte-level / TLS-parsing candidate split', () {
    test('the flags sit on exactly the byte-level engine modes', () {
      for (final id in _byteLevel) {
        expect(
          dpiLabCandidateById(id)?.tcpByteLevel,
          isTrue,
          reason: '$id is a raw segment operation',
        );
      }
      // The TLS-parsing engine modes: no flag.
      expect(dpiLabCandidateById('zap-tlsrec')?.tcpByteLevel, isFalse);
      expect(dpiLabCandidateById('zap-fake')?.tcpByteLevel, isFalse);
      // Every config-layer candidate: no flag (the shaping
      // layer emits nothing for a non-TLS profile, so any
      // of these would be a dead probe there).
      for (final id in [
        's1',
        's2',
        's3',
        'af-mirage',
        'af-f1',
        'af-z1',
        'af-z1r',
        'af-z5',
        'af-mixed-sni',
        'af-ech',
        'af-unfilter',
      ]) {
        expect(
          dpiLabCandidateById(id)?.tcpByteLevel,
          isFalse,
          reason: '$id is config-layer shaping',
        );
      }
      // Stock and TCP noise were never TLS-gated at all.
      expect(dpiLabCandidateById('s0')?.tlsOnly, isFalse);
      expect(dpiLabCandidateById('af-tcp-noise')?.tlsOnly, isFalse);
    });

    test('a non-TLS TCP profile is offered the byte-level set', () {
      expect(dpiLabCandidatesFor(_cfPlain()).map((c) => c.id), [
        's0',
        'zap-split',
        'zap-disorder',
        'zap-oob',
        'zap-disoob',
        'af-tcp-noise',
      ]);
    });

    test('the TLS-parsing and config-layer candidates stay out', () {
      final ids = dpiLabCandidatesFor(_cfPlain()).map((c) => c.id).toSet();
      for (final id in [
        'zap-tlsrec',
        'zap-fake',
        's1',
        's2',
        's3',
        'af-mirage',
        'af-f1',
        'af-f15',
        'af-z1',
        'af-z1r',
        'af-z5',
        'af-mixed-sni',
        'af-ech',
        'af-unfilter',
      ]) {
        expect(ids, isNot(contains(id)), reason: id);
      }
    });

    test('a TLS profile sees exactly the 2134 candidate set', () {
      expect(dpiLabCandidatesFor(_tls()).map((c) => c.id), [
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

    test('the byte-level modes stay TCP-only: UDP offers none', () {
      // Non-TLS over KCP: back to stock + noise, exactly
      // 2134 — there is no TCP stream to segment.
      expect(dpiLabCandidatesFor(_cfPlain(network: 'kcp')).map((c) => c.id), [
        's0',
        'af-tcp-noise',
      ]);
      // TLS over KCP: no zap candidate of either family.
      final tlsKcp = dpiLabCandidatesFor(
        _tls(network: 'kcp'),
      ).map((c) => c.id).toSet();
      for (final id in zapretCandidateIds) {
        expect(tlsKcp, isNot(contains(id)), reason: id);
      }
    });

    test('both gates agree — applies() is the offer list', () {
      // The Lab offer (dpiLabCandidatesFor) and the
      // connect-time remembered-strategy check
      // (dpiLabCandidateApplies, the journal's "does not
      // apply" path) must never disagree, for any
      // candidate, on any profile class.
      final profiles = [_cfPlain(), _tls(), _cfPlain(network: 'kcp')];
      for (final p in profiles) {
        final offered = dpiLabCandidatesFor(p).map((c) => c.id).toSet();
        for (final c in dpiLabCandidates) {
          expect(
            dpiLabCandidateApplies(c.id, p),
            offered.contains(c.id),
            reason: '${c.id} on ${p.security}/${p.network}',
          );
        }
      }
      // The owner's case, spelled out: a remembered
      // byte-level win now APPLIES to his plain CF profile;
      // the TLS-parsing wins still do not.
      expect(dpiLabCandidateApplies('zap-disorder', _cfPlain()), isTrue);
      expect(dpiLabCandidateApplies('zap-split', _cfPlain()), isTrue);
      expect(dpiLabCandidateApplies('zap-tlsrec', _cfPlain()), isFalse);
      expect(dpiLabCandidateApplies('zap-fake', _cfPlain()), isFalse);
      expect(dpiLabCandidateApplies('af-z1', _cfPlain()), isFalse);
    });

    test('a newly-offered candidate transforms the dial copy', () {
      final plain = _cfPlain();
      final marked = profileWithCandidate(plain, 'zap-oob');
      expect(marked.zapretStrategy, 'zap-oob');
      // The stored profile is never mutated by a transform.
      expect(plain.zapretStrategy, isEmpty);
    });

    test('a remote strategy can never claim byte-level reach', () {
      // The feed parser constructs candidates with tlsOnly
      // only — tcpByteLevel is a shipped-code fact, never
      // feed data.
      final remote = _src('xray/dpi_remote.dart');
      expect(remote, isNot(contains('tcpByteLevel')));
    });
  });

  // ---- A34-02 ------------------------------------------------------------

  group('A34-02 — Provider DNS warning scope', () {
    final seg = _segment(
      _src('xray/xray_controller.dart'),
      'Future<Map<String, List<String>>> _providerDnsPins',
      'Build 2110 (fugui-hostname diagnosis C1)',
    );

    test('the literal-IP early-out runs before the no-DNS warning', () {
      // Build 2139 (A34-02 re-fix): the check is the
      // isLiteralServerHost helper, which also recognises
      // the bracketed and host:port address forms a bare
      // tryParse missed.
      final literal = seg.indexOf('isLiteralServerHost(host)');
      final warning = seg.indexOf('carries no DNS');
      expect(literal, isNonNegative);
      expect(warning, isNonNegative);
      expect(literal, lessThan(warning));
    });

    test('the journal line is guarded by the once-per-episode set', () {
      // Build 2139 (A34-02 re-fix) supersedes the 2135
      // single-slot, generation-keyed stamp: the owner's
      // journal still showed the line twice per connect
      // (the slot was evicted by interleaved profiles and
      // the generation advances inside one episode). The
      // cap is now a Set.add first-wins guard, cleared at
      // the two connect-episode entries.
      final guard = seg.indexOf('_providerDnsNoDnsWarned.add(p.id)');
      final warning = seg.indexOf('carries no DNS');
      expect(guard, isNonNegative);
      expect(guard, lessThan(warning));
      final all = _src('xray/xray_controller.dart');
      expect('_providerDnsNoDnsWarned.clear()'.allMatches(all).length, 2);
      expect(all, isNot(contains('_providerDnsNoDnsWarnKey')));
    });

    test('the notice field is still set on the no-DNS path', () {
      expect(seg, contains('Provider DNS did not pin'));
    });
  });

  // ---- A34-03 ------------------------------------------------------------

  group('A34-03 — birth reaper covers Zapret + Sudoku', () {
    test('EmberApplication reaps both 2127 families', () {
      final app = _kotlin('EmberApplication.kt');
      expect(app, contains('ZapretCore.reapOrphan(this)'));
      expect(app, contains('SudokuBoxCore.reapOrphan(this)'));
      // Same list as the established families (the reaper
      // block, main process only).
      final singbox = app.indexOf('SingBoxCore.reapOrphan(this)');
      expect(app.indexOf('ZapretCore.reapOrphan(this)'), greaterThan(singbox));
      expect(
        app.indexOf('SudokuBoxCore.reapOrphan(this)'),
        greaterThan(singbox),
      );
    });

    test('both cores inherit the shared reaper', () {
      expect(_kotlin('ZapretCore.kt'), contains(': SubprocessCore('));
      expect(_kotlin('SudokuBoxCore.kt'), contains(': SubprocessCore('));
      expect(_kotlin('SubprocessCore.kt'), contains('fun reapOrphan'));
    });
  });

  // ---- A34-04 ------------------------------------------------------------

  group('A34-04 — OLCRTC wait observes cancellation', () {
    final seg = _segment(
      _src('xray/xray_controller.dart'),
      'Future<List<String>> _startOlcrtcUnderlay',
      'Future<void> _startWstunnel',
    );

    test('the wait takes the caller cancellation check', () {
      expect(seg, contains('void Function() checkAlive'));
      final controller = _src('xray/xray_controller.dart');
      expect(controller, contains('_startOlcrtcUnderlay(checkAlive)'));
    });

    test('cancellation is polled before the readiness read', () {
      final cancel = seg.indexOf('checkAlive();');
      final ready = seg.indexOf('if (st.ready)');
      expect(cancel, isNonNegative);
      expect(ready, isNonNegative);
      expect(cancel, lessThan(ready));
    });

    test('a cancelled wait stops the client — no orphan', () {
      final onCancel = seg.indexOf('on _ConnectCancelled');
      expect(onCancel, isNonNegative);
      final stop = seg.indexOf('OlcrtcPlatform.stop()', onCancel);
      expect(stop, greaterThan(onCancel));
    });
  });

  // ---- A34-05 ------------------------------------------------------------

  group('A34-05 — proof grace re-check', () {
    final controller = _src('xray/xray_controller.dart');
    final seg = _segment(
      controller,
      'Future<bool> awaitXrayCarries',
      'Future<void> _connectSelected',
    );

    test('the grace keys on bytes actually coming back', () {
      expect(controller, contains('Future<bool> _proofSawDownlink()'));
      expect(seg, contains('await _proofSawDownlink()'));
      // The consumed stats delta is handed to the
      // accounting poll's hold, not dropped.
      expect(controller, contains('void _holdStatsDelta('));
    });

    test('the fresh proof (re-proof) path is untouched', () {
      // A26-01's live re-proof stays a single tunnel check:
      // the grace lives only in the 12 s connect-time path,
      // after the freshProof early return.
      final fresh = seg.indexOf('if (freshProof)');
      final grace = seg.indexOf('_proofSawDownlink()');
      expect(fresh, isNonNegative);
      expect(grace, greaterThan(fresh));
    });

    test('one re-check after the grace, same live check', () {
      expect(seg, contains('Duration(seconds: 5)'));
      expect(seg, contains('recheckMs'));
      // The grace block sits AFTER the first verdict check.
      final verdict = seg.indexOf('if (ms >= 0) return true;');
      final grace = seg.indexOf('_proofSawDownlink()');
      expect(verdict, isNonNegative);
      expect(grace, greaterThan(verdict));
    });

    test('the WireGuard leg takes the same grace', () {
      expect(controller, contains('The WireGuard proof window closed'));
      // Exactly two call sites: the Xray proof and the WG
      // leg's proof.
      expect('await _proofSawDownlink()'.allMatches(controller).length, 2);
    });

    test('the honesty rule stands: no proof, no Connected', () {
      // PIN SUPERSEDED by build 2149 (owner order
      // 2026-11-25, diagnosis D1): the rule's FORM
      // changed, not its honesty — a proof-less session
      // is no longer refused (the 2116 gate tore down
      // slow-first-byte sessions v2rayNG/Karing adopt);
      // it is adopted UNVERIFIED and only the background
      // proof may stamp it verified. The gate's throw and
      // its journal line are gone; the unverified
      // adoption and its journal line stand in their
      // place.
      expect(controller, isNot(contains("throw StateError('no-traffic')")));
      expect(controller, isNot(contains('carried no traffic')));
      expect(controller, contains('this session is marked '));
      expect(controller, contains('verified only when traffic lands'));
      expect(controller, contains('state = state.withVerified(false);'));
    });
  });
}
