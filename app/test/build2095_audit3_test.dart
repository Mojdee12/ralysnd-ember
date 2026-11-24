/// Build 2095, third-pass audit — the Dim-8 pins for the
/// audit-3 fix groups (Dims 1/2/4/5/6) that the journey
/// batches did not already cover:
///
/// - 2.5: updateSubscription refuses while a connect is
///   in flight on one of the subscription's profiles, and
///   a subscription deleted mid-fetch is not resurrected.
/// - 5-1: a failed fetch journals the subscription's host,
///   never the full bearer URL.
/// - 8-5a: a refresh does not duplicate a node the store
///   already holds as a loose profile.
/// - 8-5b: the auto-update sweep refreshes stale opted-in
///   subscriptions only (test seam).
/// - 4a-1: exportBackup is built from memory — an unsaved
///   edit rides the export.
/// - 4a-2/4a-3: a restore clears the connected-profile
///   claim and reports its bounded transforms as notes.
/// - 4c-1/4c-2/4c-4: refresh carry-over — the user's
///   shaping fills only empties, a user pin is kept only
///   when set, TCP-ping results survive.
/// - 6-3/7-8: the shape cache prunes expired wins and
///   forgets a deleted profile on every network.
/// - 8-3 (second half): deleteProfile disconnects first
///   when the profile is the live session.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/shape_cache.dart';
import 'package:firefox_vpn/xray/sub_fetcher.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

Profile _profile(
  String id,
  String name, {
  String address = 'node.example.com',
  String uuid = '11111111-1111-1111-1111-111111111111',
}) => Profile(
  id: id,
  protocol: Protocol.vless,
  name: name,
  address: address,
  port: 443,
  uuidOrPassword: uuid,
);

XrayController _controllerWith(Future<SubResult> Function(String url) fetch) {
  final c = XrayController();
  c.subscriptionFetcher =
      (
        url, {
        certPin = '',
        hwid = '',
        headers = const {},
        fallbackUrl = '',
        hosts = const {},
      }) => fetch(url);
  return c;
}

Subscription _sub(String id, String url) =>
    Subscription(id: id, name: 'S', url: url);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('updateSubscription guards (audit 2.5)', () {
    test('refuses while a connect is in flight on its profile', () async {
      final c = _controllerWith((url) async => const SubResult(profiles: []));
      addTearDown(c.dispose);
      final sub = _sub('s1', 'https://x.example.com/sub');
      c.subscriptions.add(sub);
      final p = _profile('p1', 'P')..subscriptionId = 's1';
      c.profiles.add(p);
      c.selectedProfileId = 'p1';
      c.connecting = true;
      await expectLater(
        c.updateSubscription(sub),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('connection is starting'),
          ),
        ),
      );
    });

    test('a subscription deleted mid-fetch is not resurrected', () async {
      late XrayController c;
      c = _controllerWith((url) async {
        // The user deletes the subscription while the
        // fetch is in flight.
        c.subscriptions.clear();
        return SubResult(profiles: [_profile('n1', 'Fetched')]);
      });
      addTearDown(c.dispose);
      final sub = _sub('s1', 'https://x.example.com/sub');
      c.subscriptions.add(sub);
      await c.updateSubscription(sub);
      expect(c.profiles, isEmpty, reason: 'no orphan profiles');
      expect(c.subscriptions, isEmpty);
    });
  });

  group('diagnostics host-only (audit 5-1)', () {
    test('a failed fetch never journals the full URL', () async {
      final c = _controllerWith((url) async => throw Exception('boom'));
      addTearDown(c.dispose);
      final sub = _sub('s1', 'https://secret.example.com/path?token=ABC123')
        ..name = '';
      c.subscriptions.add(sub);
      await expectLater(c.updateSubscription(sub), throwsA(anything));
      final lines = c.diagnostics.entries.map((e) => e.text).join('\n');
      expect(lines, contains('secret.example.com'));
      expect(lines, isNot(contains('token=ABC123')));
      expect(lines, isNot(contains('/path')));
    });
  });

  group('refresh store-wide dedupe (audit 8-5a)', () {
    test('a fetched node identical to a loose profile is not duplicated',
        () async {
      final fetched = _profile('new-id', 'Fetched');
      final c = _controllerWith(
        (url) async => SubResult(profiles: [fetched]),
      );
      addTearDown(c.dispose);
      final sub = _sub('s1', 'https://x.example.com/sub');
      c.subscriptions.add(sub);
      c.profiles.add(_profile('loose', 'Loose'));
      await c.updateSubscription(sub);
      expect(c.profiles, hasLength(1));
      expect(c.profiles.single.id, 'loose');
      expect(sub.profileCount, 0);
    });
  });

  group('auto-update sweep (audit 8-5b)', () {
    test('refreshes stale opted-in subs, skips fresh and opted-out',
        () async {
      var fetches = 0;
      final c = _controllerWith((url) async {
        fetches++;
        return const SubResult(profiles: []);
      });
      addTearDown(c.dispose);
      final now = DateTime.now().millisecondsSinceEpoch;
      final stale = _sub('stale', 'https://a.example.com/s')
        ..lastUpdatedMs = now - 48 * 3600 * 1000;
      final fresh = _sub('fresh', 'https://b.example.com/s')
        ..lastUpdatedMs = now;
      final optedOut = _sub('off', 'https://c.example.com/s')
        ..autoUpdate = false
        ..lastUpdatedMs = 0;
      c.subscriptions.addAll([stale, fresh, optedOut]);
      await c.testAutoUpdateStale();
      expect(fetches, 1);
    });
  });

  group('backup fidelity (audit 4a)', () {
    test('export is built from memory, not the disk copy', () async {
      final c = _controllerWith((url) async => const SubResult(profiles: []));
      addTearDown(c.dispose);
      c.profiles.add(_profile('p1', 'InMemory'));
      final text = await c.exportBackup();
      final doc = jsonDecode(text!) as Map<String, dynamic>;
      final profiles = doc['profiles'] as List;
      expect(profiles, hasLength(1));
      expect((profiles.single as Map)['name'], 'InMemory');
    });

    test('restore clears the session claim and notes transforms', () async {
      final c = _controllerWith((url) async => const SubResult(profiles: []));
      addTearDown(c.dispose);
      final backup = jsonEncode({
        'schemaVersion': 1,
        'profiles': [
          {
            ..._profile('x1', 'X').toJson(),
            'protocol': 'someFutureProtocol',
          },
        ],
        'subscriptions': [],
        'settings': {'tunnelMtu': 99999},
        'warpProfile': {},
        'selectedProfileId': 'x1',
      });
      final result = await c.importBackup(backup);
      expect(result, isNotNull);
      expect(
        result!.notes.join(' '),
        contains('read as VLESS'),
      );
      expect(result.notes.join(' '), contains('MTU was clamped'));
      // The restored profile carries no live-session claim:
      // a save now must persist an empty connected id.
      final exported = jsonDecode((await c.exportBackup())!) as Map;
      expect(exported['connectedProfileId'], '');
    });
  });

  group('refresh carry-over (audit 4c)', () {
    test('shaping fills empties, pin keeps only when set, TCP ping carries',
        () async {
      final fetched = _profile('new', 'N')
        ..afFragment = 'provider-frag'
        ..tlsCertPin = 'provider-pin';
      final c = _controllerWith(
        (url) async => SubResult(profiles: [fetched]),
      );
      addTearDown(c.dispose);
      final sub = _sub('s1', 'https://x.example.com/sub');
      c.subscriptions.add(sub);
      final old = _profile('old', 'N')
        ..subscriptionId = 's1'
        ..afFragment = 'user-frag'
        ..afTcpNoise = true
        ..tcpPingMs = 321
        ..tcpPingFailed = false;
      c.profiles.add(old);
      await c.updateSubscription(sub);
      final merged = c.profiles.single;
      // The provider's fresh value wins where it carries one.
      expect(merged.afFragment, 'provider-frag');
      // The user's value fills the empty field.
      expect(merged.afTcpNoise, isTrue);
      // The provider's pin survives (the old profile had none).
      expect(merged.tlsCertPin, 'provider-pin');
      expect(merged.tcpPingMs, 321);
    });

    test('a user pin is kept over the provider value when set', () async {
      final fetched = _profile('new', 'N')..tlsCertPin = 'provider-pin';
      final c = _controllerWith(
        (url) async => SubResult(profiles: [fetched]),
      );
      addTearDown(c.dispose);
      final sub = _sub('s1', 'https://x.example.com/sub');
      c.subscriptions.add(sub);
      final old = _profile('old', 'N')
        ..subscriptionId = 's1'
        ..tlsCertPin = 'user-pin';
      c.profiles.add(old);
      await c.updateSubscription(sub);
      expect(c.profiles.single.tlsCertPin, 'user-pin');
    });
  });

  group('shape cache pruning (audit 6-3 / 7-8)', () {
    test('expired wins are deleted on lookup and pruned on record', () {
      final cache = WinningShapeCache();
      const week = WinningShapeCache.maxAgeMs;
      cache.record('p1', 'net-a', 'shapeX', 100, nowMs: 1000);
      expect(
        cache.lookup('p1', 'net-a', nowMs: 1000 + week + 1),
        isNull,
      );
      expect(cache.length, 0, reason: 'the expired entry is deleted');
      cache.record('p2', 'net-a', 'shapeY', 100, nowMs: 1000);
      cache.record('p3', 'net-a', 'shapeZ', 100, nowMs: 1000 + week + 1);
      expect(cache.length, 1, reason: 'record pruned the expired win');
    });

    test('forgetProfile removes every network of the profile', () {
      final cache = WinningShapeCache();
      cache.record('p1', 'net-a', 's', 1, nowMs: 10);
      cache.record('p1', 'net-b', 's', 1, nowMs: 10);
      cache.record('p2', 'net-a', 's', 1, nowMs: 10);
      cache.forgetProfile('p1');
      expect(cache.length, 1);
      expect(cache.lookup('p2', 'net-a', nowMs: 10), isNotNull);
    });
  });

  group('deleteProfile disconnect guard (audit 8-3)', () {
    const channel = MethodChannel('app/android');
    final calls = <String>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'dataDir') return Directory.systemTemp.path;
            return null;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('deleting the live profile disconnects first', () async {
      final c = _controllerWith((url) async => const SubResult(profiles: []));
      addTearDown(c.dispose);
      final p = _profile('p1', 'P');
      c.profiles.add(p);
      c.selectedProfileId = 'p1';
      c.state = const XrayState(
        running: true,
        name: 'P',
        sinceMs: 1,
        upBytes: 0,
        downBytes: 0,
      );
      await c.deleteProfile(p);
      expect(calls, contains('xrayStop'));
      expect(c.profiles, isEmpty);
    });
  });
}
