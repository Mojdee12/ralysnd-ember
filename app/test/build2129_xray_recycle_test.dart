// Build 2129 — leg 6 / Xray recycle bin (delta §7(b)1):
// the restore surface over the 2096/2097 deletion
// tombstones. The tombstone retains ONLY its identity
// key — no name, no full profile — so the shipped
// semantics are pinned as what the data supports:
//  C1 the bin lists tombstoned profiles with the
//     endpoint fields parsed out of the key itself;
//  C2 restore = un-tombstone: the profile returns at
//     the subscription's NEXT refresh, not before;
//  C3 an unrestored entry stays deleted across
//     refreshes (the pre-2129 behaviour, preserved);
//  C4 purge removes the entry from the bin while the
//     profile STAYS deleted across refreshes;
//  C5 deletions still tombstone exactly as before
//     (nothing auto-restores, nothing changes hands).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/sub_fetcher.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

const _vlessLink =
    'vless://11111111-1111-1111-1111-111111111111@node.example.com:443'
    '?encryption=none&security=tls&type=ws#Node%20One';
const _vlessLink2 =
    'vless://22222222-2222-2222-2222-222222222222@two.example.com:443'
    '?encryption=none&security=tls&type=ws#Node%20Two';

XrayController _controllerWith(Future<SubResult> Function(String) fetch) {
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

Future<SubResult> _twoProfiles(String _) async => SubResult(
  profiles: [parseLink(_vlessLink)!, parseLink(_vlessLink2)!],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ember2129bin-');
    await Directory('${tempDir.path}/xray').create(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), (
          call,
        ) async {
          if (call.method == 'dataDir') return '${tempDir.path}/core';
          return null;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), null);
    await tempDir.delete(recursive: true);
  });

  Future<(XrayController, Subscription)> seeded() async {
    final c = _controllerWith(_twoProfiles);
    addTearDown(c.dispose);
    await c.load();
    final sub = await c.addSubscription('https://panel.example.com/s');
    expect(c.profilesOf(sub), hasLength(2));
    return (c, sub);
  }

  group('C1 — the bin lists what the tombstone retains', () {
    test('endpoint fields parse out of a real tombstone key', () {
      final p = parseLink(_vlessLink)!;
      final parsed = parseTombstoneKey(profileTombstoneKey(p));
      expect(parsed, isNotNull);
      expect(parsed!.protocol, 'vless');
      expect(parsed.address, 'node.example.com');
      expect(parsed.port, 443);
    });

    test('a shadowsocks key (pipe inside the credential) still parses', () {
      final p = Profile(
        id: 'ss',
        protocol: Protocol.shadowsocks,
        name: 'ss',
        address: 'ss.example.com',
        port: 8388,
        method: 'aes-256-gcm',
        uuidOrPassword: 'p@ss|word',
      );
      final parsed = parseTombstoneKey(profileTombstoneKey(p));
      expect(parsed, isNotNull);
      expect(parsed!.address, 'ss.example.com');
      expect(parsed.port, 8388);
    });

    test('a pre-tombstone identity key does not parse', () {
      expect(parseTombstoneKey('vless|uuid|host.example|443'), isNull);
      expect(parseTombstoneKey(''), isNull);
    });

    test('a deleted profile appears in the bin with its endpoint label', () async {
      final (c, sub) = await seeded();
      final doomed = c.profilesOf(sub).first;
      await c.deleteProfile(doomed);
      expect(c.deletedProfileCount, 1);
      final entry = c.deletedProfiles.single;
      expect(entry.subscription.id, sub.id);
      // PIN UPDATED by build 2149 (audit A43-11): the
      // tombstone retains the profile's own JSON now, so
      // the bin entry is labelled with the retained NAME
      // (the endpoint key remains the fallback for
      // pre-2149 tombstones) and restores immediately.
      expect(entry.label, 'Node One');
      expect(entry.restorableNow, isTrue);
    });
  });

  group('C2/C3 — restore round-trip; unrestored stays deleted', () {
    test('restore un-tombstones; the NEXT refresh brings it back', () async {
      final (c, sub) = await seeded();
      final doomed = c.profilesOf(sub).first;
      await c.deleteProfile(doomed);
      await c.updateSubscription(sub);
      expect(c.profilesOf(sub), hasLength(1),
          reason: 'C3: unrestored, the refresh must not resurrect it');

      final entry = c.deletedProfiles.single;
      await c.restoreDeletedProfile(entry.subscription, entry.key);
      expect(c.deletedProfileCount, 0);
      // BEHAVIOUR CHANGED by build 2149 (audit A43-11):
      // restore is REAL now — the tombstone retained the
      // profile's JSON, so the profile is back at once,
      // no refresh needed.
      expect(c.profilesOf(sub), hasLength(2),
          reason: 'restore re-adds the retained profile immediately');
      await c.updateSubscription(sub);
      expect(c.profilesOf(sub), hasLength(2),
          reason: 'the refresh after a restore neither duplicates '
              'nor re-deletes it');
    });

    test('the bin state persists across a store reload', () async {
      final (c, sub) = await seeded();
      await c.deleteProfile(c.profilesOf(sub).first);
      final doc = jsonDecode(
        await File('${tempDir.path}/xray/state.json').readAsString(),
      ) as Map;
      final subDoc = (doc['subscriptions'] as List).single as Map;
      expect(subDoc['deletedProfileKeys'], hasLength(1));

      final c2 = _controllerWith(_twoProfiles);
      addTearDown(c2.dispose);
      await c2.load();
      expect(c2.deletedProfileCount, 1);
    });
  });

  group('C4 — purge', () {
    test('purge leaves the bin but the profile stays deleted', () async {
      final (c, sub) = await seeded();
      await c.deleteProfile(c.profilesOf(sub).first);
      final entry = c.deletedProfiles.single;
      await c.purgeDeletedProfile(entry.subscription, entry.key);
      expect(c.deletedProfileCount, 0, reason: 'gone from the bin');
      expect(sub.purgedProfileKeys, contains(entry.key));
      await c.updateSubscription(sub);
      expect(c.profilesOf(sub), hasLength(1),
          reason: 'purging must not un-delete the profile');
    });
  });

  group('C5 — wiring pins', () {
    test('the servers list carries the Recently deleted entry', () {
      final servers = File(
        'lib/ui/ember/ember_servers.dart',
      ).readAsStringSync();
      expect(servers, contains('_ServersRecycleBinItem'));
      expect(servers, contains('Recently deleted'));
      expect(servers, contains('RecycleBinPage'));
      final page = File(
        'lib/ui/ember/recycle_bin_page.dart',
      ).readAsStringSync();
      expect(page, contains('restoreDeletedProfile'));
      expect(page, contains('purgeDeletedProfile'));
    });
  });
}
