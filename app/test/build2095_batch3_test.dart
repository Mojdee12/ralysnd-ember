/// Build 2095, batch 3 — import + subscription management
/// (V2Ray journey audit rows #1, #3, #4, #5, #6, #7, #8,
/// #9, #10, #11, #24, #26; third-pass audit 4c-3).
///
/// Pinned here:
/// - #1: a pasted subscription BODY (base64 blob) imports
///   through parseSubscription — it used to add 0 silently.
/// - #8: lines nothing could read are reported in the
///   import result, and the result SnackBar carries them.
/// - #11: a duplicated feed is stable across refreshes
///   identity — duplicates no longer grow on every refresh.
/// - 4c-3: a refresh WITHOUT the userinfo header keeps the
///   stored quota/expiry instead of zeroing them.
/// - #7: update-all returns its counts.
/// - #4: editSubscription edits in place and refreshes.
/// - #3: deleteSubscription disconnects first when the
///   live tunnel's profile belongs to it (Dim-8 pin 8-3).
/// - #5: the auto-update cadence is a live periodic timer,
///   not a load-only call.
/// - #10: a restore reports skipped/damaged entries.
/// - #6/#9/#24/#26: source pins for the QR routing, the CF
///   create path, the copy-URL menu item and the up-front
///   certificate pin field.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/sub_fetcher.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

const _vlessLink =
    'vless://11111111-1111-1111-1111-111111111111@node.example.com:443'
    '?encryption=none&security=tls&type=ws#Node%20One';
const _vlessLink2 =
    'vless://22222222-2222-2222-2222-222222222222@two.example.com:443'
    '?encryption=none&security=tls&type=ws#Node%20Two';

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

String _read(String path) => File(path).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseLinksDetailed (audit #8)', () {
    test('unreadable lines are reported, readable ones parse', () {
      final r = parseLinksDetailed('$_vlessLink\nnot a link at all\n');
      expect(r.profiles, hasLength(1));
      expect(r.skipped, ['not a link at all']);
      // The plain entry point keeps its contract.
      expect(parseLinks('$_vlessLink\njunk'), hasLength(1));
    });
  });

  group('subscription body paste (audit #1)', () {
    test('a base64 body imports its configs, no phantom errors', () async {
      final c = _controllerWith((url) async => const SubResult(profiles: []));
      addTearDown(c.dispose);
      final body = base64Encode(utf8.encode('$_vlessLink\n$_vlessLink2'));
      final r = await c.importLinksAsync(body);
      expect(r.added, 2);
      expect(c.profiles, hasLength(2));
      expect(
        r.errors.where((e) => e.contains('could not be read')),
        isEmpty,
        reason: 'the body was consumed — its lines are not "skipped"',
      );
    });

    test('a dead line beside a good link is reported (audit #8)', () async {
      final c = _controllerWith((url) async => const SubResult(profiles: []));
      addTearDown(c.dispose);
      final r = await c.importLinksAsync('$_vlessLink\n%%%garbage%%%');
      expect(r.added, 1);
      expect(
        r.errors.any((e) => e.contains('1 line could not be read')),
        isTrue,
      );
    });
  });

  group('refresh stability + quota (audit #11, audit-3 4c-3)', () {
    // CONFLICT RESOLVED (2095 full suite): journey row
    // #11 asked for within-fetch identity dedupe, but
    // build 2057's F-M21 deliberately KEEPS a feed's
    // duplicate rows — each carries its own totals, star
    // and label, and collapsing them was the data loss
    // F-M21 fixed. The row's premise (duplicates GROW on
    // every refresh) is falsified by F-M21's
    // queue-per-identity merge + usedIds guard, pinned
    // here in its strongest form: add, refresh, refresh —
    // the count never grows and the carries survive.
    test('a duplicated feed is stable across refreshes, carries intact',
        () async {
      var fetchCount = 0;
      final c = _controllerWith((url) async {
        fetchCount++;
        return SubResult(
          profiles: [
            _profile('f$fetchCount-a', 'A'),
            _profile('f$fetchCount-b', 'A again'),
            _profile(
              'f$fetchCount-c',
              'B',
              address: 'two.example.com',
              uuid: '22222222-2222-2222-2222-222222222222',
            ),
          ],
          suggestedName: 'Panel',
        );
      });
      addTearDown(c.dispose);
      final sub = await c.addSubscription('https://panel.example.com/sub/x');
      expect(c.profilesOf(sub), hasLength(3));
      expect(sub.profileCount, 3);
      c.profilesOf(sub).first.totalDownBytes = 777;
      await c.updateSubscription(sub);
      expect(c.profilesOf(sub), hasLength(3));
      await c.updateSubscription(sub);
      expect(c.profilesOf(sub), hasLength(3));
      expect(
        c.profilesOf(sub).map((p) => p.totalDownBytes),
        contains(777),
        reason: 'the duplicate pair keeps its own carry (F-M21)',
      );
    });

    test('a refresh without userinfo keeps the stored quota', () async {
      var withInfo = true;
      final c = _controllerWith(
        (url) async => SubResult(
          profiles: [_profile('a1', 'A')],
          suggestedName: 'Panel',
          uploadBytes: withInfo ? 10 : 0,
          downloadBytes: withInfo ? 20 : 0,
          totalBytes: withInfo ? 1000 : 0,
          expireEpochSec: withInfo ? 2000000000 : 0,
        ),
      );
      addTearDown(c.dispose);
      final sub = await c.addSubscription('https://panel.example.com/sub/x');
      expect(sub.totalBytes, 1000);
      expect(sub.expireEpochSec, 2000000000);
      withInfo = false;
      await c.updateSubscription(sub);
      expect(
        sub.totalBytes,
        1000,
        reason: 'a headerless refresh must not zero the quota (4c-3)',
      );
      expect(sub.expireEpochSec, 2000000000);
      withInfo = true;
      await c.updateSubscription(sub);
      expect(sub.totalBytes, 1000);
    });
  });

  group('update-all counts + edit (audit #7, #4)', () {
    test('updateAllSubscriptions reports updated and failed', () async {
      final c = _controllerWith((url) async {
        if (url.contains('bad')) {
          throw const SubFetchException(
            kind: SubFetchErrorKind.network,
            message: 'boom',
          );
        }
        return SubResult(profiles: [_profile('p$url', 'P')]);
      });
      addTearDown(c.dispose);
      await c.addSubscription('https://good.example.com/sub/1');
      // Seed a second subscription directly (addSubscription
      // would fetch fine; the failure must come at update
      // time, so flip the URL host by hand).
      final bad = Subscription(
        id: 'badsub',
        name: 'Bad',
        url: 'https://bad.example.com/sub/2',
      );
      c.subscriptions.add(bad);
      final r = await c.updateAllSubscriptions();
      expect(r.updated, 1);
      expect(r.failed, 1);
    });

    test('editSubscription edits in place and refreshes', () async {
      final seen = <String>[];
      final c = _controllerWith((url) async {
        seen.add(url);
        return SubResult(
          profiles: [_profile('n${seen.length}', 'N')],
          suggestedName: 'Panel',
        );
      });
      addTearDown(c.dispose);
      final sub = await c.addSubscription('https://old.example.com/sub/1');
      final id = sub.id;
      await c.editSubscription(
        sub,
        name: 'Renamed',
        url: 'https://new.example.com/sub/9',
        hwid: 'hw-1',
      );
      expect(sub.id, id, reason: 'the subscription is edited, not replaced');
      expect(sub.name, 'Renamed');
      expect(sub.url, 'https://new.example.com/sub/9');
      expect(sub.hwid, 'hw-1');
      expect(seen.last, 'https://new.example.com/sub/9');
      expect(c.profilesOf(sub), hasLength(1));
    });
  });

  group('deleteSubscription disconnect guard (audit #3)', () {
    const channel = MethodChannel('app/android');
    final calls = <String>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'dataDir') {
              return Directory.systemTemp.path;
            }
            return null;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('deleting the live subscription disconnects first', () async {
      final c = _controllerWith((url) async => const SubResult(profiles: []));
      addTearDown(c.dispose);
      final sub = Subscription(
        id: 's1',
        name: 'S',
        url: 'https://x.example.com/sub',
      );
      c.subscriptions.add(sub);
      final p = _profile('p1', 'P')..subscriptionId = 's1';
      c.profiles.add(p);
      c.selectedProfileId = 'p1';
      c.state = const XrayState(
        running: true,
        name: 'P',
        sinceMs: 1,
        upBytes: 0,
        downBytes: 0,
      );
      await c.deleteSubscription(sub);
      expect(
        calls,
        contains('xrayStop'),
        reason: 'the tunnel must stop before its config is deleted',
      );
      expect(c.profiles, isEmpty);
      expect(c.subscriptions, isEmpty);
    });

    test('deleting another subscription leaves the tunnel alone', () async {
      final c = _controllerWith((url) async => const SubResult(profiles: []));
      addTearDown(c.dispose);
      final sub = Subscription(
        id: 's2',
        name: 'S2',
        url: 'https://y.example.com/sub',
      );
      c.subscriptions.add(sub);
      final p = _profile('p9', 'Other');
      c.profiles.add(p);
      c.selectedProfileId = 'p9';
      c.state = const XrayState(
        running: true,
        name: 'Other',
        sinceMs: 1,
        upBytes: 0,
        downBytes: 0,
      );
      await c.deleteSubscription(sub);
      expect(calls, isNot(contains('xrayStop')));
      expect(c.profiles, hasLength(1));
    });
  });

  group('restore report (audit #10)', () {
    test('damaged entries are counted, not silently dropped', () async {
      final c = _controllerWith((url) async => const SubResult(profiles: []));
      addTearDown(c.dispose);
      final doc = {
        'profiles': [
          _profile('good', 'Good').toJson(),
          {'id': 42, 'name': 'Bad', 'protocol': 'vless'},
          'a string is not a profile',
        ],
        'subscriptions': [
          {'id': 'ok', 'name': 'Ok', 'url': 'https://x.example.com/s'},
          {'name': 'No id'},
        ],
      };
      final r = await c.importBackup(jsonEncode(doc));
      expect(r, isNotNull);
      expect(r!.profiles, 1);
      expect(r.skippedProfiles, 2);
      expect(r.subscriptions, 1);
      expect(r.skippedSubscriptions, 1);
      expect(r.skipped, 3);
    });
  });

  group('source pins (audit #5, #6, #9, #24, #26)', () {
    test('the cadence is a live periodic timer', () {
      final dart = _read('lib/xray/xray_controller.dart');
      expect(dart, contains('_subAutoTimer'));
      expect(dart, contains('Timer.periodic'));
    });

    test('the QR scan tries the config parser before subscribing', () {
      final dart = _read('lib/ui/ember/qr_pages.dart');
      expect(dart, contains('parseLink(code) != null'));
      expect(dart, contains('isSubscriptionUrl(code)'));
      // The import result carries the per-line notes.
      expect(dart, contains('errorNote'));
    });

    test('the CF scanner can create a config from a clean IP', () {
      final dart = _read('lib/ui/ember/cf_scanner_page.dart');
      expect(dart, contains("pop('create')"));
      expect(dart, contains('Create a new config with this address'));
      final editor = _read('lib/ui/ember/profile_editor.dart');
      expect(editor, contains('widget.draft?.copy()'));
    });

    test('the subscription sheet edits, copies and pins', () {
      final dart = _read('lib/ui/ember/ember_accounts.dart');
      expect(dart, contains('existing: sub'));
      expect(dart, contains("'copyurl'"));
      expect(dart, contains('Copy subscription URL'));
      expect(dart, contains('editSubscription('));
      expect(dart, contains('Certificate pin (SHA-256)'));
      // Update-all shows its counts.
      expect(dart, contains('r.failed == 0'));
    });

    test('sync stamps last-sync only after a successful restore', () {
      final dart = _read('lib/ui/ember/ember_sync.dart');
      final pull = dart.substring(dart.indexOf('Future<String> syncPull'));
      final pullBody = pull.substring(0, pull.indexOf('/// \'2026-11-15'));
      expect(pullBody.contains('syncLastMs:'), isFalse);
      expect(dart, contains('if (restored != null)'));
    });
  });
}
