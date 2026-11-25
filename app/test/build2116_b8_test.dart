// Build 2116, batch B8 (updater + backup) — proving tests.
//
// B8-1 (AB-07): the updater parses the feed's SHA-256
// digest and verifies the streamed bytes against it; older
// APKs in updates/ are swept. B8-2 (AB-15): a failed
// download never leaves its .part (pin). B8-3 (AB-06): a
// restore overlays the live migration flags — a pre-2114
// backup's deliberate autoReconnect ON restores ON. B8-4
// (AB-16): importBackup runs the fingerprint migration
// under its flag guard (build 2149/D4: the migration is
// retired — restored fingerprints are kept verbatim).
// B8-5 (AB-05): engine sections ride
// the backup document both ways. B8-6 (E-7): the sync
// token migrates from plaintext settings to the Keystore
// vault on load, and the document stops carrying it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/ui/ember/ember_updater.dart';
import 'package:firefox_vpn/xray/sha256.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

void _mockAndroidChannel(
  Map<String, Object? Function(MethodCall)> handlers,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('app/android'), (
        call,
      ) async {
        final h = handlers[call.method];
        if (h != null) return h(call);
        return null;
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), null);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('streaming SHA-256 (B8-1 support)', () {
    test('matches the one-shot hash at every chunking', () {
      // FIPS known-answer, fed in awkward pieces.
      final s = Sha256();
      for (final piece in ['a', 'b', '', 'c']) {
        s.add(utf8.encode(piece));
      }
      expect(
        s.hex(),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      final data = List<int>.generate(100000, (i) => (i * 31 + 7) % 256);
      final expected = sha256Hex(data);
      for (final step in [1, 63, 64, 65, 1000, 65536]) {
        final h = Sha256();
        for (var i = 0; i < data.length; i += step) {
          h.add(data.sublist(i, i + step > data.length ? data.length : i + step));
        }
        expect(h.hex(), expected, reason: 'chunk size $step');
      }
    });
  });

  group('B8-1 feed digest parsing', () {
    Map<String, Object?> feedWith(Object? digest) => {
      'tag_name': 'v2116',
      'name': 'Build 2116',
      'assets': [
        {
          'name': 'RalysndEmber2.apk',
          'browser_download_url': 'https://example.invalid/apk',
          'size': 42,
          'digest': ?digest,
        },
      ],
    };

    test('sha256:-prefixed, bare and absent digests', () {
      expect(
        parseLatestRelease(feedWith('sha256:AB12CD'))!.apkDigest,
        'ab12cd',
      );
      expect(parseLatestRelease(feedWith('AB12CD'))!.apkDigest, 'ab12cd');
      expect(parseLatestRelease(feedWith(null))!.apkDigest, '');
    });

    test('the download verifies, sweeps and cleans up (pins)', () {
      final src = File('lib/ui/ember/ember_updater.dart').readAsStringSync();
      expect(src, contains('hasher.hex() != r.apkDigest'));
      expect(src, contains("startsWith('RalysndEmber2-')"));
      // Build 2125 SUPERSESSION (recorded, not silent):
      // A25-09 retires the B8-2 finally-delete — a leftover
      // .part is resume state now, and its orphan control
      // is check()'s tag-scoped, age-capped sweep (pinned
      // in build2125_test.dart). The finally only closes
      // the download client.
      final fin = src.substring(src.lastIndexOf('} finally {'));
      expect(fin, contains('activeClient?.close(force: true)'));
      expect(fin, isNot(contains('part.delete()')));
    });
  });

  group('B8-3/B8-4/B8-5 restore behaviour', () {
    late Directory tmp;
    late XrayController c;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ember2116b8');
      _mockAndroidChannel({
        'dataDir': (_) => '${tmp.path}/core',
        'xrayState': (_) => {'running': false},
      });
      await Directory('${tmp.path}/core').create(recursive: true);
      c = XrayController();
      addTearDown(c.dispose);
    });
    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('B8-3: a pre-2114 backup with autoReconnect ON restores ON',
        () async {
      // The live settings have lived through the 2114
      // reset (the flag defaults true on a fresh object,
      // and load() sets it on any real store).
      expect(c.settings.defaultsReset2114, isTrue);
      final backup = jsonEncode({
        'profiles': <Object?>[],
        'subscriptions': <Object?>[],
        'settings': {'autoReconnect': true},
      });
      final result = await c.importBackup(backup);
      expect(result, isNotNull);
      expect(c.settings.autoReconnect, isTrue);
    });

    // Build 2149 SUPERSESSION (diagnosis D4): the 2070
    // fingerprint clearing is RETIRED — stored data cannot
    // distinguish an explicit fp=chrome from the old parser
    // fill, so from 2149 nothing is cleared anywhere the
    // migration ran, the restore path included (it is the
    // same migration under the same flag). The pre-2149
    // form of this test expected the restored 'chrome' to
    // be cleared to ''; the D4 behaviour pinned here is
    // the opposite: the value survives verbatim, and the
    // one-time flag still flips (the migration era is
    // closed, not re-run).
    test('B8-4: restored fingerprints are KEPT under the flag (D4)',
        () async {
      final profile = Profile(
        id: 'p1',
        name: 'vless one',
        protocol: Protocol.vless,
        address: 'example.com',
        port: 443,
        security: 'tls',
        fingerprint: 'chrome',
      );
      final backup = jsonEncode({
        'profiles': [profile.toJson()],
        'subscriptions': <Object?>[],
        'settings': <String, Object?>{},
      });
      final result = await c.importBackup(backup);
      expect(result, isNotNull);
      expect(c.profiles.single.fingerprint, 'chrome');
      expect(c.settings.fingerprintDefaultMigrated, isTrue);
    });

    test('B8-5: engine sections ride the document both ways', () async {
      final text = await c.exportBackup(
        engineSections: {
          'openVpnProfiles': [
            {'id': 'o1', 'name': 'vpn'},
          ],
          'psiphonSettings': {'region': 'NL'},
          'aetherOptions': {
            'masque': {'protocol': 'masque'},
          },
        },
      );
      expect(text, isNotNull);
      final doc = jsonDecode(text!) as Map<String, dynamic>;
      expect((doc['engines'] as Map)['version'], 1);
      final result = await c.importBackup(text);
      expect(result, isNotNull);
      expect(result!.engineSections, isNotNull);
      expect(result.engineSections!['psiphonSettings'], {'region': 'NL'});
      expect(
        (result.engineSections!['aetherOptions'] as Map).keys,
        contains('masque'),
      );
    });
  });

  group('B8-6 sync token migration', () {
    test('a plaintext token is sealed and purged on load', () async {
      final tmp = await Directory.systemTemp.createTemp('ember2116b8tok');
      addTearDown(() => tmp.delete(recursive: true));
      final file = File('${tmp.path}/app-settings.json');
      await file.writeAsString(
        jsonEncode({'sync_github_token': 'ghp_secret123'}),
      );
      String? vaultValue;
      _mockAndroidChannel({
        'secretLoad': (_) => vaultValue,
        'secretStore': (call) {
          vaultValue = (call.arguments as Map)['value'] as String;
          return true;
        },
        'secretDelete': (_) => null,
      });
      final s = await AppSettings.load(tmp.path);
      expect(s.syncGithubToken, 'ghp_secret123');
      expect(vaultValue, 'ghp_secret123');
      final rewritten = await file.readAsString();
      expect(rewritten, isNot(contains('ghp_secret123')));
      expect(rewritten, isNot(contains('sync_github_token')));
      // A later load takes the token from the vault.
      final s2 = await AppSettings.load(tmp.path);
      expect(s2.syncGithubToken, 'ghp_secret123');
      // New documents never write the key.
      expect(s.toJson().containsKey('sync_github_token'), isFalse);
    });
  });
}
