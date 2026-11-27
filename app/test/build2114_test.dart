// Build 2114 — the cumulative "main build". The Dart-side
// pins (the Mozilla set is Go-side and pinned by the core's
// build2114_test.go):
//
//  - Scope B, the defaults reset (defaults-audit-2113.md;
//    owner order — every Ember extra defaults OFF, v2rayNG
//    parity): the four XraySettings toggles, the AppSettings
//    pair and the WarpProfile fragment default OFF, each
//    with a one-time migration that moves a stored ON to
//    OFF exactly once and keeps a value set afterwards.
//  - Scope C1, the Zapret-style desync shapes: three new
//    fragment geometries (z1/z2/z3) and their Lab
//    candidates (af-z1/af-z2/af-z3), TCP-only like every
//    fragment candidate. (The build2107 candidate-list pins
//    were updated to the new shipped set — the assertions
//    still name the exact full list.)
//  - Scope C2, remote/community strategy updates: the
//    strict feed validation (an entry violating any rule
//    is dropped whole), the 'r-' namespace, the registry
//    install (a remembered r- win validates only after
//    install), the candidate gates, the transform, and the
//    store round-trip.
//
// All fixtures use dummy values — the owner's real configs
// and keys never appear in tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/xray/anti_filter.dart';
import 'package:firefox_vpn/xray/dpi_lab.dart';
import 'package:firefox_vpn/xray/dpi_remote.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Profile _profile({String network = 'tcp', String security = 'tls'}) =>
    Profile(
      id: 'lab-2114',
      name: 'Lab 2114',
      protocol: Protocol.vless,
      address: 'nl1.example.net',
      port: 443,
      uuidOrPassword: '00000000-0000-0000-0000-000000000000',
      network: network,
      security: security,
      sni: 'nl1.example.net',
    );

Map<String, dynamic> _feedEntry(
  String id, {
  String label = 'Feed strategy',
  Map<String, dynamic> shape = const {
    'fragment': {
      'lengths': ['2', '3'],
      'delays': ['0'],
    },
  },
}) => {
  'id': id,
  'label': label,
  'detail': 'From the test feed.',
  'shape': shape,
};

void main() {
  group('Scope B — XraySettings defaults reset', () {
    test('fresh defaults are OFF', () {
      final s = XraySettings();
      expect(s.adaptiveFailover, isFalse);
      expect(s.autoReconnect, isFalse);
      expect(s.stallWatchdog, isFalse);
      expect(s.smartDialRacing, isFalse);
    });

    test('a stored ON moves to OFF once (no reset flag)', () {
      final s = XraySettings.fromJson({
        'adaptiveFailover': true,
        'autoReconnect': true,
        'stallWatchdog': true,
        'smartDialRacing': true,
      });
      expect(s.adaptiveFailover, isFalse);
      expect(s.autoReconnect, isFalse);
      expect(s.stallWatchdog, isFalse);
      expect(s.smartDialRacing, isFalse);
      expect(s.toJson()['defaultsReset2114'], isTrue);
    });

    test('a value set after the reset is kept', () {
      final s = XraySettings.fromJson({
        'adaptiveFailover': true,
        'autoReconnect': true,
        'stallWatchdog': true,
        'smartDialRacing': true,
        'defaultsReset2114': true,
      });
      expect(s.adaptiveFailover, isTrue);
      expect(s.autoReconnect, isTrue);
      expect(s.stallWatchdog, isTrue);
      expect(s.smartDialRacing, isTrue);
    });
  });

  group('Scope B — WarpProfile fragment reset', () {
    test('fresh default is OFF', () {
      expect(WarpProfile().fragment, isFalse);
    });

    test('a stored fragment=true moves to OFF once', () {
      final w = WarpProfile.fromJson({'fragment': true});
      expect(w.fragment, isFalse);
      expect(w.toJson()['defaultsReset2114'], isTrue);
    });

    test('fragment set after the reset is kept', () {
      final w = WarpProfile.fromJson({
        'fragment': true,
        'defaultsReset2114': true,
      });
      expect(w.fragment, isTrue);
    });
  });

  group('Scope B — AppSettings pair reset', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('b2114_'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> writeStore(Map<String, dynamic> json) => File(
      '${dir.path}${Platform.pathSeparator}app-settings.json',
    ).writeAsString(jsonEncode(json));

    test('stored ON moves to OFF once', () async {
      await writeStore({'udp_notice': true, 'launcher_shortcuts': true});
      final s = await AppSettings.load(dir.path);
      expect(s.udpNotice, isFalse);
      expect(s.launcherShortcutsEnabled, isFalse);
    });

    test('values set after the reset are kept', () async {
      await writeStore({
        'udp_notice': true,
        'launcher_shortcuts': true,
        'defaults_reset_2114': true,
      });
      final s = await AppSettings.load(dir.path);
      expect(s.udpNotice, isTrue);
      expect(s.launcherShortcutsEnabled, isTrue);
    });
  });

  group('Scope C1 — Zapret desync shapes', () {
    test('the three geometries are shipped', () {
      expect(afShapeById('z1')?.lengths, ['2', '3', '5', '8']);
      expect(afShapeById('z2')?.lengths, ['1', '2', '4']);
      expect(afShapeById('z3')?.lengths, ['0', '2', '104', '1']);
      expect(afShapeById('z3')?.maxSplit, '0');
      for (final id in ['z1', 'z2', 'z3']) {
        final e = afShapeById(id)!.entry();
        expect(e['type'], 'fragment');
        expect((e['settings'] as Map)['packets'], 'tlshello');
      }
    });

    test('the Lab candidates exist, TLS-only, and transform', () {
      for (final (cid, fid) in [
        ('af-z1', 'z1'),
        ('af-z2', 'z2'),
        ('af-z3', 'z3'),
      ]) {
        final c = dpiLabCandidateById(cid);
        expect(c, isNotNull, reason: cid);
        expect(c!.tlsOnly, isTrue, reason: cid);
        final shaped = profileWithCandidate(_profile(), cid);
        expect(shaped.afFragment, fid, reason: cid);
        expect(shaped.afUnfilter, isFalse, reason: cid);
        expect(shaped.afEch, isFalse, reason: cid);
      }
    });

    test('fragment candidates stay off UDP transports', () {
      final ids = dpiLabCandidatesFor(
        _profile(network: 'kcp'),
      ).map((c) => c.id);
      expect(ids, isNot(contains('af-z1')));
      expect(ids, isNot(contains('af-z2')));
      expect(ids, isNot(contains('af-z3')));
      final tlsIds = dpiLabCandidatesFor(_profile()).map((c) => c.id);
      expect(tlsIds, containsAll(['af-z1', 'af-z2', 'af-z3']));
    });
  });

  group('Scope C2 — feed validation', () {
    test('a valid document parses; ids land in the r- namespace', () {
      final strategies = parseDpiStrategiesJson({
        'version': 1,
        'strategies': [
          _feedEntry('multi-2'),
          _feedEntry('noise-only', shape: {'tcpNoise': true}),
        ],
      });
      expect(strategies.map((s) => s.candidate.id), [
        'r-multi-2',
        'r-noise-only',
      ]);
      // TLS-only is derived: a fragment strategy is, a
      // noise-only one is not.
      expect(strategies[0].candidate.tlsOnly, isTrue);
      expect(strategies[1].candidate.tlsOnly, isFalse);
      expect(strategies[0].tcpOnlyShape, isTrue);
      expect(strategies[1].tcpOnlyShape, isFalse);
    });

    test('every rule violation drops the entry whole', () {
      final bad = <Map<String, dynamic>>[
        _feedEntry('Bad_ID'),
        _feedEntry('-leading-dash'),
        _feedEntry('ok1', shape: {'fragment': {'lengths': ['99999'], 'delays': ['0']}}),
        _feedEntry('ok2', shape: {'fragment': {'lengths': ['5-2'], 'delays': ['0']}}),
        _feedEntry('ok3', shape: {'fragment': {'lengths': ['1'], 'delays': ['10001']}}),
        _feedEntry('ok4', shape: {'ech': true, 'unfilter': true}),
        _feedEntry('ok5', shape: {}),
        _feedEntry('ok6', shape: {'dialMode': 'oob.9'}),
        _feedEntry('ok7', shape: {'mystery': true, 'tcpNoise': true}),
        _feedEntry('ok8', shape: {'tcpNoise': 'yes'}),
        _feedEntry('ok9', label: 'bad\u0007label'),
        _feedEntry('ok10', shape: {'fragment': {'lengths': ['1'], 'delays': ['0'], 'bogus': 1}}),
      ];
      final strategies = parseDpiStrategiesJson({'strategies': bad});
      expect(strategies, isEmpty);
    });

    test('duplicates keep the first; a mixed feed keeps the valid', () {
      final strategies = parseDpiStrategiesJson({
        'strategies': [
          _feedEntry('dup', label: 'First'),
          _feedEntry('dup', label: 'Second'),
          _feedEntry('bad id'),
          _feedEntry('fine'),
        ],
      });
      expect(strategies.map((s) => s.candidate.id), ['r-dup', 'r-fine']);
      expect(strategies.first.candidate.label, 'First');
    });

    test('a non-JSON body is a feed failure, not an empty list', () {
      expect(
        () => parseDpiStrategyFeedBody('<html>404</html>'),
        throwsA(isA<DpiStrategyFeedException>()),
      );
      expect(parseDpiStrategyFeedBody('{"strategies": []}'), isEmpty);
    });
  });

  group('Scope C2 — registry, gates and transform', () {
    final feed = {
      'strategies': [
        _feedEntry('multi-2'),
        _feedEntry('noise-only', shape: {'tcpNoise': true}),
      ],
    };

    setUp(() => installDpiRemoteStrategies(parseDpiStrategiesJson(feed)));
    tearDown(() => installDpiRemoteStrategies(const []));

    test('installed strategies resolve as candidates', () {
      expect(dpiLabCandidateById('r-multi-2')?.label, 'Feed strategy');
      expect(dpiLabCandidateById('r-noise-only'), isNotNull);
      expect(dpiRemoteStrategies.length, 2);
    });

    test('a remembered r- win validates only against the registry', () {
      final winJson = {
        'candidate': 'r-multi-2',
        'profile': 'lab-2114',
        'name': 'Lab 2114',
        'ms': 120,
        'cc': 'NL',
        'at': 1000000,
      };
      expect(DpiLabWin.fromJson(winJson)?.candidateId, 'r-multi-2');
      installDpiRemoteStrategies(const []);
      expect(DpiLabWin.fromJson(winJson), isNull);
    });

    test('the candidate gates apply to remote strategies', () {
      final tlsIds = dpiLabCandidatesFor(_profile()).map((c) => c.id);
      expect(tlsIds, containsAll(['r-multi-2', 'r-noise-only']));
      // The fragment strategy is TCP-only-shaped: off KCP.
      final kcpIds = dpiLabCandidatesFor(
        _profile(network: 'kcp'),
      ).map((c) => c.id);
      expect(kcpIds, isNot(contains('r-multi-2')));
      expect(kcpIds, contains('r-noise-only'));
      // The fragment strategy is TLS-only: a plain profile
      // gets the noise strategy but not the fragment one.
      final plainIds = dpiLabCandidatesFor(
        _profile(security: ''),
      ).map((c) => c.id);
      expect(plainIds, isNot(contains('r-multi-2')));
      expect(plainIds, contains('r-noise-only'));
    });

    test('the transform applies the validated spec', () {
      final shaped = profileWithCandidate(_profile(), 'r-multi-2');
      expect(shaped.afFragment, 'r-multi-2');
      // The geometry resolves through anti_filter's remote
      // registry — the config builder can emit it.
      expect(afShapeById('r-multi-2')?.lengths, ['2', '3']);
      final noisy = profileWithCandidate(_profile(), 'r-noise-only');
      expect(noisy.afTcpNoise, isTrue);
      expect(noisy.afFragment, isEmpty);
    });

    test('a feed can never shadow a shipped candidate', () {
      final rogue = DpiRemoteStrategy(
        candidate: const DpiLabCandidate('s1', 'Rogue', 'Shadow attempt.'),
      );
      final installed = installDpiRemoteStrategies([rogue]);
      expect(installed, isEmpty);
      expect(dpiLabCandidateById('s1')?.label, 'TLS fragment (F12)');
    });

    test('version: pubspec is 2.2.0+2119', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.2.0+2157'),
      );
    });

    test('the store round-trip preserves the installed set', () {
      final doc = dpiRemoteStrategiesToJson(dpiRemoteStrategies);
      final restored = dpiRemoteStrategiesFromJson(doc);
      expect(restored.map((s) => s.candidate.id), [
        'r-multi-2',
        'r-noise-only',
      ]);
      expect(restored.first.fragment?.lengths, ['2', '3']);
      expect(restored.last.tcpNoise, isTrue);
      // The persisted form is exactly what a feed carries.
      expect(jsonEncode(doc).contains('r-multi-2'), isFalse);
    });
  });
}
