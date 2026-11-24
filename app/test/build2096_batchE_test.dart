// Build 2096 — batch E tests: store / refresh / restore.
// M10 (refresh keeps the sub copy beside a loose twin),
// M11 (VMess legacy carry),
// M12 (identity strip), M13 (restore migration flag),
// M14 (unreadable settings), M15 (string schemaVersion),
// L17 (sweep guard + timer), L20 (delete guards, pins),
// L28 (speed carry), L29 (tombstones), L30 (backup
// version gate), L31 (biometric PIN guard), L33 (partial
// decode), L34 (unified >1 behaviour).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/atomic_json_store.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/sub_fetcher.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ember2096e-');
    await Directory('${tempDir.path}/xray').create(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('app/android'),
      (call) async {
        if (call.method == 'dataDir') return '${tempDir.path}/core';
        return null;
      },
    );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), null);
    await tempDir.delete(recursive: true);
  });

  group('M15 — defensive schemaVersion', () {
    test('storeSchemaVersion parses strings and junk', () {
      expect(storeSchemaVersion({'schemaVersion': 1}), 1);
      expect(storeSchemaVersion({'schemaVersion': '1'}), 1);
      expect(storeSchemaVersion({'schemaVersion': '2'}), 2);
      expect(storeSchemaVersion({'schemaVersion': 'x'}), 1);
      expect(storeSchemaVersion({}), 1);
      expect(storeSchemaVersion({'schemaVersion': 2.0}), 2);
    });

    test('an Xray store with a string version loads its '
        'profiles (and is not overwritten empty)', () async {
      final c1 = _controllerWith((_) async => const SubResult(profiles: []));
      await c1.load();
      final p = parseLink(_vlessLink)!;
      await c1.addProfile(p);
      final file = File('${tempDir.path}/xray/state.json');
      final doc = jsonDecode(await file.readAsString()) as Map;
      doc['schemaVersion'] = '1'; // the foreign/hand-edited shape
      await file.writeAsString(jsonEncode(doc));

      final c2 = _controllerWith((_) async => const SubResult(profiles: []));
      await c2.load();
      expect(c2.profiles, hasLength(1),
          reason: 'the string version must not throw the '
              'load into an empty state');
      final after = await file.readAsString();
      expect(after, contains(p.id),
          reason: 'the load-time migration save must not '
              'overwrite the real store with emptiness');
    });
  });

  group('L34 — unified >1 behaviour (OpenVPN)', () {
    test('a newer document decodes in-session and is '
        'never overwritten', () async {
      const cfg =
          'client\ndev tun\nproto udp\nremote vpn.example.com 1194\n';
      final file = File('${tempDir.path}/openvpn/state.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'schemaVersion': 2,
        'selectedId': 'p1',
        'profiles': [
          {'id': 'p1', 'name': 'Future', 'config': cfg},
        ],
      }));
      final c = OpenVpnController();
      addTearDown(c.dispose);
      await c.load();
      expect(c.userProfiles, hasLength(1),
          reason: 'decode-and-use in-session, like the '
              'Xray/Psiphon stores');
      expect(c.storeError, isNotNull);
      await c.renameProfile('p1', 'Renamed');
      final after = jsonDecode(await file.readAsString()) as Map;
      expect(after['schemaVersion'], 2,
          reason: 'never saved over a newer document');
      expect((after['profiles'] as List), hasLength(1));
      expect(((after['profiles'] as List).single as Map)['name'], 'Future',
          reason: 'the rename save was refused too');
    });
  });

  group('refresh merge — M10 / L28 / L29', () {
    // Corrected in the 2096 verification loop: the
    // audit's M10 scenario is a REFRESH where the
    // subscription already owns the node and a loose twin
    // also exists — build 2095's dedupe dropped the
    // subscription's copy there. A FIRST fetch with only
    // a loose twin keeps the 2095 behaviour (audit 8-5a
    // pin in build2095_audit3_test.dart).
    test('M10: a refresh keeps the subscription copy of a '
        'node that also exists loose', () async {
      final c = _controllerWith(
        (_) async => SubResult(profiles: [parseLink(_vlessLink)!]),
      );
      addTearDown(c.dispose);
      final sub = await c.addSubscription('https://panel.example.com/s');
      final ownedBefore = c.profilesOf(sub).single
        ..starred = true
        ..localName = 'Mine'
        ..totalDownBytes = 555;
      // The user also hand-imports the same node, loose.
      await c.addProfile(parseLink(_vlessLink)!);
      expect(c.profiles, hasLength(2));
      await c.updateSubscription(sub);
      final owned = c.profilesOf(sub);
      expect(owned, hasLength(1),
          reason: 'the subscription copy survives the '
              'refresh despite the loose twin');
      expect(owned.single.id, ownedBefore.id);
      expect(owned.single.starred, isTrue);
      expect(owned.single.localName, 'Mine');
      expect(owned.single.totalDownBytes, 555);
      expect(
        c.profiles.where((p) => p.subscriptionId.isEmpty),
        hasLength(1),
        reason: 'the loose row is untouched',
      );
    });

    test('L28: the last speed result survives a refresh',
        () async {
      var fetches = 0;
      final c = _controllerWith((_) async {
        fetches++;
        return SubResult(profiles: [parseLink(_vlessLink)!]);
      });
      addTearDown(c.dispose);
      final sub = await c.addSubscription('https://panel.example.com/s');
      c.profilesOf(sub).single.lastSpeedBps = 424242;
      await c.updateSubscription(sub);
      expect(fetches, 2);
      expect(c.profilesOf(sub).single.lastSpeedBps, 424242);
    });

    test('L29: an individually deleted profile stays '
        'deleted across refreshes', () async {
      final c = _controllerWith(
        (_) async => SubResult(profiles: [
          parseLink(_vlessLink)!,
          parseLink(_vlessLink2)!,
        ]),
      );
      addTearDown(c.dispose);
      await c.load();
      final sub = await c.addSubscription('https://panel.example.com/s');
      expect(c.profilesOf(sub), hasLength(2));
      final doomed = c.profilesOf(sub).first;
      await c.deleteProfile(doomed);
      expect(c.profilesOf(sub), hasLength(1));
      expect(sub.deletedProfileKeys, isNotEmpty,
          reason: 'the deletion is tombstoned');
      await c.updateSubscription(sub);
      expect(c.profilesOf(sub), hasLength(1),
          reason: 'the refresh does not resurrect it');
      // And the tombstone persisted to the store document.
      final doc = jsonDecode(
        await File('${tempDir.path}/xray/state.json').readAsString(),
      ) as Map;
      final subDoc = (doc['subscriptions'] as List).single as Map;
      expect(subDoc['deletedProfileKeys'], isNotEmpty);
    });
  });

  group('M11 — VMess legacy carry', () {
    test('a 2094-stored VMess profile keeps its carry on '
        'the first 2096 refresh', () async {
      final vmessJson = {
        'v': '2',
        'ps': 'VMess Node',
        'add': 'vmess.example.com',
        'port': '443',
        'id': '33333333-3333-3333-3333-333333333333',
        'aid': '0',
        'scy': 'auto',
        'net': 'tcp',
        'type': '',
        'host': '',
        'path': '',
        'tls': 'tls',
        'sni': 'vmess.example.com',
        'alpn': '',
        'fp': '',
        'pbk': 'PUBKEY',
        'sid': 'ab',
        'spx': '/spx',
        'flow': 'xtls-rprx-vision',
        'mode': 'gun',
        'authority': 'auth.example.com',
        'pqv': 'PQV',
      };
      final link =
          'vmess://${base64Encode(utf8.encode(jsonEncode(vmessJson)))}';
      final fresh = parseLink(link)!;
      expect(fresh.publicKey, 'PUBKEY',
          reason: 'the 2095+ reader lands the 4b-2 fields');
      // The 2094-stored shape: those fields never landed.
      final stored = parseLink(link)!
        ..mode = ''
        ..grpcAuthority = ''
        ..publicKey = ''
        ..shortId = ''
        ..spiderX = ''
        ..pqv = ''
        ..flow = ''
        ..totalDownBytes = 999
        ..starred = true;
      expect(
        profileIdentityLink(stored) == profileIdentityLink(fresh),
        isFalse,
        reason: 'the premise: the identities really differ',
      );
      expect(
        legacyVmessIdentityLink(stored),
        legacyVmessIdentityLink(fresh),
        reason: 'the legacy keys agree',
      );

      var serveFresh = false;
      final c = _controllerWith(
        (_) async => SubResult(
          profiles: serveFresh ? [parseLink(link)!] : [],
        ),
      );
      addTearDown(c.dispose);
      final sub = await c.addSubscription('https://panel.example.com/s');
      stored.subscriptionId = sub.id;
      c.profiles.add(stored);
      serveFresh = true;
      await c.updateSubscription(sub);
      final merged = c.profilesOf(sub);
      expect(merged, hasLength(1));
      expect(merged.single.id, stored.id,
          reason: 'the carry matched — the id survives');
      expect(merged.single.totalDownBytes, 999);
      expect(merged.single.starred, isTrue);
      expect(merged.single.publicKey, 'PUBKEY',
          reason: 'the fresh fields land with the carry');
    });
  });

  group('M12 — identity strips the editor-set Aether fields',
      () {
    test('dialMode / finalMask / cipherSuites are not '
        'identity', () {
      final a = parseLink(_vlessLink)!;
      final b = parseLink(_vlessLink)!
        ..dialMode = 'oob'
        ..finalMask = 'salamander'
        ..cipherSuites = 'TLS_AES_128_GCM_SHA256';
      expect(profileIdentityLink(a), profileIdentityLink(b));
      expect(profileIdentityKey(a), profileIdentityKey(b));
    });
  });

  group('L17 — auto-update sweep', () {
    test('two concurrent sweeps fetch once', () async {
      var fetches = 0;
      final c = _controllerWith((_) async {
        fetches++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return const SubResult(profiles: []);
      });
      addTearDown(c.dispose);
      final sub = await c.addSubscription('https://panel.example.com/s');
      sub.lastUpdatedMs = 0;
      fetches = 0;
      await Future.wait([c.testAutoUpdateStale(), c.testAutoUpdateStale()]);
      expect(fetches, 1,
          reason: 'the second sweep is refused while one runs');
    });

    test('dispose cancels the auto-update timer (pin)', () {
      final src = File('lib/xray/xray_controller.dart').readAsStringSync();
      expect(src, contains('_subAutoTimer?.cancel();'));
      expect(src, contains('if (_sweepRunning) return;'));
    });
  });

  group('L20 — delete guards cover connecting (pins)', () {
    test('the guards read the connecting state', () {
      // PIN UPDATED by build 2097 (post-2096 audit C-L9):
      // both guards now key on the attempt's CAPTURED
      // target (_connectingProfileId / _connectingId),
      // not the live selection, which can drift
      // mid-connect when the user taps another profile.
      // PIN UPDATED by build 2098 (post-2097 audit L14):
      // the selectedProfileId disjunct is GONE — it
      // over-blocked (deleting the selected profile while
      // an unrelated session ran disconnected that
      // session); the live-session and connecting-target
      // conditions remain, and sessionProfile already
      // falls back to the selection when no connected id
      // is recorded.
      // PIN UPDATED by build 2098 (verification F-A2):
      // the switchingProfileId disjunct is BACK — removing
      // the selection condition had also unguarded the
      // seamless-switch TARGET (tracked only in
      // switchingProfileId), and a mid-switch delete let
      // the switch complete onto a removed profile.
      final xray = File('lib/xray/xray_controller.dart').readAsStringSync();
      expect(
        xray,
        contains('(state.running || connecting) &&\n'
            '        (sessionProfile?.id == p.id ||\n'
            '            _connectingProfileId == p.id ||\n'
            '            switchingProfileId == p.id)'),
      );
      final ovpn =
          File('lib/openvpn/openvpn_controller.dart').readAsStringSync();
      expect(ovpn, contains('(_busy && _connectingId == id)'));
    });
  });

  group('L12/L13 — quick-edit rename', () {
    test('rename follows the editor rule and sanitizes',
        () async {
      final c = _controllerWith((_) async => const SubResult(profiles: []));
      addTearDown(c.dispose);
      final p = parseLink(_vlessLink)!;
      await c.addProfile(p);
      await c.renameProfile(p, 'Node One'); // == provider name
      expect(p.localName, '',
          reason: 'a name equal to the provider name is no override');
      await c.renameProfile(p, '  My Node  ');
      expect(p.localName, 'My Node');
    });
  });

  group('L30 — backup version gate', () {
    // Corrected during the 2096 verification loop: the
    // audit refuses a PRESENT-but-wrong version (a string
    // or double slipping past `is int`); a MISSING version
    // is a legacy backup and restores (the build-2054
    // F-H9 pin). The first version of this test refused
    // missing versions too and broke that pin.
    test('a present version must be an int in range; a '
        'missing one is legacy', () async {
      final c = _controllerWith((_) async => const SubResult(profiles: []));
      addTearDown(c.dispose);
      String doc(Object? v) => jsonEncode({
            if (v != null) 'schemaVersion': v,
            'profiles': [],
            'subscriptions': [],
          });
      expect(await c.importBackup(doc('1')), isNull,
          reason: 'a string version is refused');
      expect(await c.importBackup(doc(1.0)), isNull,
          reason: 'a double version is refused');
      expect(await c.importBackup(doc(2)), isNull,
          reason: 'a newer version is refused');
      expect(await c.importBackup(doc(null)), isNotNull,
          reason: 'a legacy backup without a version '
              'restores');
      expect(await c.importBackup(doc(1)), isNotNull,
          reason: 'version 1 restores');
    });
  });

  group('AppSettings — M13 / M14 / L31 / L33', () {
    test('L33: a partial document keeps the app defaults',
        () async {
      final s = AppSettings();
      await s.applyRestoredSettings({});
      expect(s.themeMode, ThemeMode.dark,
          reason: 'an absent theme is dark, not system');
      expect(s.firstRun, isFalse,
          reason: 'an absent welcome_done does not re-arm '
              'the first run');
      final s2 = AppSettings();
      await s2.applyRestoredSettings({'theme': 'bogus'});
      // A PRESENT but unknown value keeps the legacy
      // tolerance (system) — the app_settings_test pin;
      // only the absent key keeps the default.
      expect(s2.themeMode, ThemeMode.system);
    });

    test('L31: biometric restore requires a PIN', () async {
      final s = AppSettings();
      await s.applyRestoredSettings({'app_lock_biometric': true});
      expect(s.appLockBiometric, isFalse,
          reason: 'no PIN — the update() guard applies');
      await s.applyRestoredSettings({
        'app_lock_pin_hash': 'deadbeef',
        'app_lock_biometric': true,
      });
      expect(s.appLockBiometric, isTrue);
      // A later restore without the hash key keeps the
      // live PIN, so biometric may stay on.
      await s.applyRestoredSettings({'app_lock_biometric': true});
      expect(s.appLockBiometric, isTrue);
    });

    test('M13: a restore marks the language migration '
        'applied', () async {
      final dir = await Directory.systemTemp.createTemp('ember2096s-');
      addTearDown(() async => dir.delete(recursive: true));
      final s = AppSettings(
        file: File('${dir.path}/app-settings.json'),
      );
      await s.applyRestoredSettings({'language': 'fa'});
      expect(s.language, 'fa');
      expect(s.emberEnDefaultApplied, isTrue);
      final reloaded = await AppSettings.load(dir.path);
      expect(reloaded.language, 'fa',
          reason: 'the next launch must not reset the '
              'restored language to English');
    });

    test('M14: an unreadable settings file is never '
        'overwritten', () async {
      // The save half is behavioural: with storeUnreadable
      // set (load() sets it when AtomicJsonStore reports
      // 'unreadable' — a filesystem error on an intact
      // file, a state a host test cannot fabricate for a
      // root-run process), every save is refused and the
      // original bytes survive.
      final dir = await Directory.systemTemp.createTemp('ember2096u-');
      addTearDown(() async => dir.delete(recursive: true));
      final file = File('${dir.path}/app-settings.json');
      const original = '{"language":"fa","welcome_done":true}';
      await file.writeAsString(original);
      final s = AppSettings(file: file)..storeUnreadable = true;
      s.update(language: 'en');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await file.readAsString(), original,
          reason: 'the intact original was not overwritten '
              'with defaults');
      expect(s.saveError, isNotNull);
      // The load half: 'unreadable' is handled distinctly
      // from 'damaged' and from absent (pin).
      final src = File('lib/app_settings.dart').readAsStringSync();
      expect(src, contains("store.lastReadProblem == 'unreadable'"));
      expect(src, contains('s.storeUnreadable = true;'));
      expect(src, contains('if (storeUnreadable) {'));
    });
  });
}
