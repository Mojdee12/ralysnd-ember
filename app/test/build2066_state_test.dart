// Build 2066 — device-state gate (skill: device_state_delivery_gate).
// A phone upgrading from 2065 carries a persisted Psiphon store:
// ladder winner memory, probe-tested CDN edges, a paired Conduit
// compartment, chain settings. 2066 must load that state intact,
// degrade corrupt/partial state field-by-field to defaults, and
// never let damaged state break the Psiphon connect path. The
// matrix: (A) carried-over 2065 state, (B) corrupt/partial state,
// (C) empty state. Harness mirrors build2054's seeded-store group.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_strategy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('device-state gate — Psiphon store', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ember2066-state-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('app/android'),
        (call) async {
          switch (call.method) {
            case 'dataDir':
              return '${tempDir.path}/core';
            case 'psiphonState':
              return <String, Object?>{
                'running': false,
                'connected': false,
                'vpnMode': true,
                'sinceMs': 0,
                'up': 0,
                'down': 0,
                'region': '',
                'clientAddress': '',
                'regions': <String>[],
              };
            default:
              return null;
          }
        },
      );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'), null);
      await tempDir.delete(recursive: true);
    });

    Future<File> seedStore(Object? doc) async {
      final file = File('${tempDir.path}/psiphon/state.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(doc is String ? doc : jsonEncode(doc));
      return file;
    }

    /// A complete 2065-shaped settings document, as the 2065
    /// build would have persisted it after real use: winner
    /// memory for one network, a pairing, probe results on two
    /// edges (one built-in, one custom), and a 'beastMode' key
    /// — kept in the fixture on purpose: build 2069 withdrew
    /// Beast Mode, so a carried-over store's key is now an
    /// UNKNOWN key, and this gate proves the loader ignores it
    /// and still loads everything else intact.
    Map<String, dynamic> state2065() => {
          'settings': {
            'vpnMode': true,
            'region': 'NL',
            'upstream': '',
            'protocols': ['SSN', 'OSSH'],
            'method': 'A',
            'lastMethodByNetwork': {'wifi:HomeNet': 'E'},
            'lastMethod': 'D',
            'compartmentId': 'A' * 43,
            'compartmentName': 'friend station',
            'beastMode': false,
            'cdnFronting': true,
            'disableTimeouts': false,
            'cdnEdges': [
              {
                'address': '23.215.0.206',
                'sni': 'a1014.dscg.akamai.net',
                'provider': 'akamai',
                'builtin': true,
                'lastMs': 42,
                'lastOk': true,
                'lastTestAtMs': 1700000000000,
                'testedIp': '23.215.0.206',
              },
              {
                'address': 'edge.example.net',
                'sni': 'pypi.org',
                'provider': 'fastly',
                'builtin': false,
                'lastMs': 87,
                'lastOk': true,
                'lastTestAtMs': 1700000000000,
                'testedIp': '151.101.0.223',
              },
            ],
            'edgeAutoUse': true,
            'pinnedEdgeId': '',
            'edgesTestedAtMs': 1700000000000,
          },
        };

    test('A: carried-over 2065 state loads intact and drives '
        'the ladder', () async {
      await seedStore(state2065());
      final c = PsiphonController();
      addTearDown(c.dispose);
      await c.load();
      final s = c.settings;
      expect(s.method, 'A');
      expect(s.region, 'NL');
      expect(s.winnerFor('wifi:HomeNet'), 'E');
      expect(s.compartmentId, 'A' * 43);
      expect(s.edgesTestedAtMs, 1700000000000);
      // The stored built-in keeps its probe result (not reset by
      // the built-in merge); the custom entry survives; missing
      // built-ins are appended exactly once.
      final stored = s.cdnEdges
          .where((e) => e.address == '23.215.0.206')
          .toList();
      expect(stored, hasLength(1));
      expect(stored.single.lastMs, 42);
      expect(s.cdnEdges.where((e) => !e.builtin), hasLength(1));
      expect(s.cdnEdges, hasLength(2 + builtinCdnEdges().length - 1));
      // The loaded state actually drives a connect plan: winner
      // first, stored edges feed the core.
      final order = psiphonRungOrder(
        method: '',
        lastWinner: s.winnerFor('wifi:HomeNet'),
        hasEdges: true,
        hasPairing: s.compartmentId.isNotEmpty,
        hasUpstream: s.upstream.isNotEmpty,
      );
      expect(order.first, 'E');
      final forCore = cdnEdgesForCore(
        s.cdnEdges,
        autoUse: true,
        pinnedId: s.pinnedEdgeId,
      );
      expect(forCore.akamai, contains('23.215.0.206'));
      expect(forCore.fastly, contains('151.101.0.223'));
    });

    test('A: a save after load round-trips the carried state', () async {
      await seedStore(state2065());
      final c = PsiphonController();
      addTearDown(c.dispose);
      await c.load();
      await c.updateSettings(c.settings);
      final saved = jsonDecode(
        await File('${tempDir.path}/psiphon/state.json').readAsString(),
      ) as Map<String, dynamic>;
      final c2 = PsiphonController();
      addTearDown(c2.dispose);
      await c2.load();
      expect(c2.settings.method, 'A');
      expect(c2.settings.winnerFor('wifi:HomeNet'), 'E');
      expect(c2.settings.edgesTestedAtMs, 1700000000000);
      expect((saved['settings'] as Map)['method'], 'A');
      // Build 2069: the withdrawn Beast key is not written
      // back — a re-save drops it for good.
      expect((saved['settings'] as Map).containsKey('beastMode'), isFalse);
    });

    test('B: a non-map settings value degrades to defaults', () async {
      await seedStore({'settings': 'garbage'});
      final c = PsiphonController();
      addTearDown(c.dispose);
      await c.load();
      expect(c.settings.method, '');
      expect(c.settings.vpnMode, isTrue);
      expect(c.settings.cdnEdges, hasLength(builtinCdnEdges().length));
    });

    test('B: a store torn mid-edge-list degrades to defaults '
        'and quarantines', () async {
      await seedStore('{"settings": {"cdnEdges": [{"address": "23.');
      final c = PsiphonController();
      addTearDown(c.dispose);
      await c.load();
      expect(c.settings.method, '');
      expect(c.settings.cdnEdges, hasLength(builtinCdnEdges().length));
      expect(
        await File('${tempDir.path}/psiphon/state.json.corrupt').exists(),
        isTrue,
      );
    });

    test('B: wrong-typed fields degrade individually; valid '
        'neighbours survive', () {
      final s = PsiphonSettings.fromJson({
        'vpnMode': 'yes',
        'region': 'NL',
        'beastMode': 1,
        'edgesTestedAtMs': 'soon',
        'protocols': 'SSH',
        'lastMethodByNetwork': [1, 2],
        'cdnEdges': [
          {'address': 42, 'sni': 'x.example.net'},
          {
            'address': '1.2.3.4',
            'sni': 's.example.net',
            'lastMs': 'fast',
            'lastOk': 'yes',
          },
        ],
      });
      expect(s.vpnMode, isTrue, reason: 'default, not a throw');
      expect(s.region, 'NL', reason: 'the valid field survives');
      // The fixture's 'beastMode': 1 needs no assertion any
      // more: since 2069 the key is unknown to the model, and
      // reaching this line at all proves it was ignored
      // without throwing or disturbing its neighbours.
      expect(s.edgesTestedAtMs, 0);
      expect(s.protocols, isEmpty);
      expect(s.lastMethodByNetwork, isEmpty);
      expect(s.cdnEdges, hasLength(1));
      expect(s.cdnEdges.single.address, '1.2.3.4');
      expect(s.cdnEdges.single.lastMs, isNull);
      expect(s.cdnEdges.single.lastOk, isFalse);
    });

    test('B: an unknown persisted method falls back to Auto '
        'instead of a bogus rung', () {
      expect(PsiphonSettings.fromJson({'method': 'Z'}).method, '');
      expect(PsiphonSettings.fromJson({'method': 'P'}).method, 'P');
      expect(PsiphonSettings.fromJson({'method': ''}).method, '');
    });

    test('B: an unknown winner-memory rung is ignored by the '
        'ladder, never dialed', () {
      final s = PsiphonSettings.fromJson({
        'lastMethodByNetwork': {'mobile:IR-MCI': 'Z'},
      });
      final order = psiphonRungOrder(
        method: s.method,
        lastWinner: s.winnerFor('mobile:IR-MCI'),
        hasEdges: false,
        hasPairing: false,
        hasUpstream: false,
      );
      expect(order, ['A', 'D', 'C']);
    });

    test('C: no store at all loads defaults plus built-ins', () async {
      final c = PsiphonController();
      addTearDown(c.dispose);
      await c.load();
      expect(c.settings.method, '');
      expect(c.settings.cdnEdges, hasLength(builtinCdnEdges().length));
    });
  });
}
