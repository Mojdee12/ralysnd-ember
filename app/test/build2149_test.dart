// Build 2149 — the fix build for the full audit of 2148.
// Per-item evidence for the items with pure or harnessable
// seams:
//  - A43-01/A43-08 RegionHop: the login-failure classifier
//    reads the panel's own body lines (all locales), and a
//    credential failure blocks the client for its lifetime
//    — proven against a loopback fake panel by COUNTING
//    login POSTs (the app must never be able to lock the
//    owner out of his own panel by polling).
//  - A43-24/A43-25: duplicate relay lines are a parse
//    error (first wins); an out-of-grammar location name
//    is a FormatException.
//  - A43-03: the settings secrets scrub is pure; the
//    vault migration round-trips through a mocked
//    Keystore channel (pre-2149 plaintext store → vault →
//    scrubbed file → restored on next load), and a vault
//    failure keeps the plaintext store (lossless).
//  - A43-07/A43-17: the Sudoku config maps the Xray log
//    level through the sing-box vocabulary; the sing-box
//    pre-flight rejects out-of-range ports (Tailscale
//    exempt).
//  - A43-11: a deletion retains the profile's data; the
//    bin's Restore re-adds it at once; Purge drops it.
//  - A43-29: the app-lock PIN hash is salted + stretched
//    (v2), verifies round-trip, and a legacy hash still
//    verifies and migrates.
//  - A48-06: the sweep's miss accounting is per-network,
//    the selected profile is exempt, and the cut uses the
//    one configurable threshold.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/regionhop/regionhop_client.dart';
import 'package:firefox_vpn/ui/ember/app_lock.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/dns_presets.dart';
import 'package:firefox_vpn/xray/iran_features_2147.dart';
import 'package:firefox_vpn/xray/problem_report.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/singbox_config.dart';
import 'package:firefox_vpn/xray/sudoku_config.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('A43-08 — the login failure is read from the panel body', () {
    test('the lockout line (en) classifies as lockout', () {
      final e = regionHopLoginFailure(
        '<html><body>Too many attempts, try again later.</body></html>',
        everLoggedIn: false,
      );
      expect(e.kind, RegionHopErrorKind.lockout);
    });

    test('the lockout line (fa) classifies as lockout', () {
      final e = regionHopLoginFailure(
        '<html><body>${regionHopLockoutLines[1]}</body></html>',
        everLoggedIn: false,
      );
      expect(e.kind, RegionHopErrorKind.lockout);
    });

    test('the wrong-password line (en) classifies as loginFailed '
        'even after a previous login', () {
      final e = regionHopLoginFailure(
        '<html><body>Incorrect password.</body></html>',
        everLoggedIn: true,
      );
      expect(e.kind, RegionHopErrorKind.loginFailed);
    });

    test('an unmarked body falls back to the legacy heuristic', () {
      expect(
        regionHopLoginFailure('<html></html>', everLoggedIn: true).kind,
        RegionHopErrorKind.lockout,
      );
      expect(
        regionHopLoginFailure('<html></html>', everLoggedIn: false).kind,
        RegionHopErrorKind.loginFailed,
      );
    });
  });

  group('A43-01 — a credential failure blocks the client', () {
    late HttpServer server;
    var loginPosts = 0;
    HttpOverrides? savedOverrides;

    setUp(() async {
      // The build2139/2141 precedent: real loopback HTTP
      // needs the test binding's mock HttpClient removed.
      savedOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      loginPosts = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final res = req.response;
        if (req.uri.path == '/p/login' && req.method == 'GET') {
          res.statusCode = 200;
          res.write('<html><body>login</body></html>');
        } else if (req.uri.path == '/p/login' && req.method == 'POST') {
          loginPosts++;
          await utf8.decoder.bind(req).join();
          res.statusCode = 200;
          res.write('<html><body>Incorrect password.</body></html>');
        } else if (req.uri.path == '/p/tunnels-status') {
          res.statusCode = 303;
          res.headers.set('location', '/p/login');
        } else {
          res.statusCode = 404;
        }
        await res.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      HttpOverrides.global = savedOverrides;
    });

    test('three login attempts + a status fetch make ONE login POST',
        () async {
      final client = RegionHopClient(
        panelUrl: 'http://127.0.0.1:${server.port}/p',
        password: 'wrong',
      );
      for (var i = 0; i < 3; i++) {
        await expectLater(
          client.login(),
          throwsA(
            isA<RegionHopException>().having(
              (e) => e.kind,
              'kind',
              RegionHopErrorKind.loginFailed,
            ),
          ),
        );
      }
      await expectLater(
        client.fetchStatus(),
        throwsA(isA<RegionHopException>()),
      );
      expect(loginPosts, 1);
    });
  });

  group('A43-24/A43-25 — relay + status parsing', () {
    test('a duplicate relay line is an error and the first wins', () {
      final block = parseRegionHopRelays(
        'de 26000 rh-de firstpass\n'
        'de 26001 rh-de secondpass\n'
        'nl 26002 rh-nl nlpass',
      );
      expect(block.relays['de']!.port, 26000);
      expect(block.relays['de']!.password, 'firstpass');
      expect(block.relays['nl']!.port, 26002);
      expect(
        block.errors,
        contains(predicate<String>((e) => e.contains('Line 2'))),
      );
    });

    test('an out-of-grammar location name is a bad response', () {
      expect(
        () => parseRegionHopStatus(
          '[{"Name":"Bad Name!","Region":"X","SocksPort":19000,'
          '"Status":"active","StatusClass":"active","ExitIP":"",'
          '"ExitRegion":"","ExitFlagURL":""}]',
        ),
        throwsFormatException,
      );
    });
  });

  group('A43-03 — settings secrets leave the plaintext store', () {
    test('scrubSettingsSecrets blanks exactly the secret keys', () {
      final scrubbed = scrubSettingsSecrets({
        'regionHopPanelPassword': 'pw',
        'regionHopRelays': 'de 26000 rh-de secret',
        'lanSharePass': 'lan',
        'deviceHwid': 'hwid',
        'theme': 'dark',
      });
      expect(scrubbed['regionHopPanelPassword'], '');
      expect(scrubbed['regionHopRelays'], '');
      expect(scrubbed['lanSharePass'], '');
      expect(scrubbed['deviceHwid'], '');
      expect(scrubbed['theme'], 'dark');
      expect(vaultSettingsSecretKeys, hasLength(4));
      expect(
        vaultKeyForSettingsSecret('deviceHwid'),
        'xray_settings_deviceHwid',
      );
    });

    group('the vault migration', () {
      late Directory tempDir;
      late Map<String, String> vault;
      var vaultOk = true;

      File stateFile() => File('${tempDir.path}/xray/state.json');

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp('ember2149-vault-');
        vault = {};
        vaultOk = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('app/android'), (
              call,
            ) async {
              switch (call.method) {
                case 'dataDir':
                  return '${tempDir.path}/core';
                case 'secretStore':
                  if (!vaultOk) return false;
                  final args = call.arguments as Map;
                  vault[args['key'] as String] = args['value'] as String;
                  return true;
                case 'secretLoad':
                  final args = call.arguments as Map;
                  return vault[args['key'] as String];
                case 'secretDelete':
                  final args = call.arguments as Map;
                  vault.remove(args['key'] as String);
                  return null;
                default:
                  return null;
              }
            });
      });

      tearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('app/android'),
              null,
            );
        await tempDir.delete(recursive: true);
      });

      Future<void> seedPlaintextStore() async {
        final settings = XraySettings()
          ..regionHopPanelPassword = 'panel-pw'
          ..deviceHwid = 'hwid-1'
          ..lanSharePass = 'lan-pw'
          ..regionHopRelays = 'de 26000 rh-de relay-pw';
        await stateFile().parent.create(recursive: true);
        await stateFile().writeAsString(
          jsonEncode({
            'profiles': <Object?>[],
            'subscriptions': <Object?>[],
            'settings': settings.toJson(),
            'selectedProfileId': '',
          }),
        );
      }

      test('a pre-2149 store migrates: doc wins on load, the '
          'file is rewritten scrubbed, the vault holds the '
          'secrets, and the next load restores from the vault',
          () async {
        await seedPlaintextStore();
        final c1 = XrayController();
        await c1.load();
        expect(c1.settings.regionHopPanelPassword, 'panel-pw');
        expect(c1.settings.deviceHwid, 'hwid-1');
        // load()'s migration save already ran (awaited).
        final onDisk =
            jsonDecode(await stateFile().readAsString())
                as Map<String, dynamic>;
        final diskSettings = onDisk['settings'] as Map<String, dynamic>;
        expect(diskSettings['regionHopPanelPassword'], '');
        expect(diskSettings['deviceHwid'], '');
        expect(diskSettings['lanSharePass'], '');
        expect(diskSettings['regionHopRelays'], '');
        expect(vault['xray_settings_regionHopPanelPassword'], 'panel-pw');
        expect(vault['xray_settings_deviceHwid'], 'hwid-1');
        expect(vault['xray_settings_lanSharePass'], 'lan-pw');
        expect(
          vault['xray_settings_regionHopRelays'],
          'de 26000 rh-de relay-pw',
        );
        // load() fires unawaited refresh tails; let them
        // land before disposing (a tail's notifyListeners
        // on a disposed controller is a debug assert).
        await Future<void>.delayed(const Duration(milliseconds: 100));
        c1.dispose();

        final c2 = XrayController();
        await c2.load();
        expect(c2.settings.regionHopPanelPassword, 'panel-pw');
        expect(c2.settings.deviceHwid, 'hwid-1');
        expect(c2.settings.lanSharePass, 'lan-pw');
        expect(c2.settings.regionHopRelays, 'de 26000 rh-de relay-pw');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        c2.dispose();
      });

      test('a vault failure keeps the plaintext store (lossless)',
          () async {
        vaultOk = false;
        final c = XrayController();
        await c.load(); // an empty store; establishes the store path
        c.settings.regionHopPanelPassword = 'panel-pw';
        await c.save();
        final onDisk =
            jsonDecode(await stateFile().readAsString())
                as Map<String, dynamic>;
        expect(
          (onDisk['settings'] as Map)['regionHopPanelPassword'],
          'panel-pw',
        );
        expect(vault, isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        c.dispose();
      });
    });
  });

  group('A43-07/A43-17 — sing-box seams', () {
    test('the Sudoku config speaks the sing-box log vocabulary', () {
      final p = Profile(
        id: 's1',
        name: 'Sudoku',
        protocol: Protocol.sudoku,
        address: 'su.example.net',
        port: 443,
      );
      expect(buildSudokuConfig(p, logLevel: 'warning')['log']['level'],
          'warn');
      expect(buildSudokuConfig(p, logLevel: 'error')['log']['level'],
          'error');
      expect(buildSudokuConfig(p)['log']['level'], 'warn');
    });

    test('the pre-flight rejects out-of-range ports, Tailscale exempt',
        () {
      final tuic = Profile(
        id: 't1',
        name: 'TUIC',
        protocol: Protocol.tuic,
        address: 'tu.example.net',
        port: 0,
        uuidOrPassword: 'uuid',
      );
      expect(singBoxConfigError(tuic), contains('port'));
      tuic.port = 65536;
      expect(singBoxConfigError(tuic), contains('port'));
      tuic.port = 443;
      expect(singBoxConfigError(tuic), isNull);
      final ts = Profile(
        id: 'ts1',
        name: 'TS',
        protocol: Protocol.tailscale,
        address: '',
        port: 0,
      );
      ts.tailscaleAuthKey = 'tskey-x';
      expect(singBoxConfigError(ts), isNull);
    });
  });

  group('A43-11 — the recycle bin restores for real', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ember2149-bin-');
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

    test('delete retains data; restore re-adds at once; purge drops it',
        () async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final sub = Subscription(
        id: 'sub1',
        name: 'Panel',
        url: 'https://panel.example.net/sub/x',
      );
      final p = Profile(
        id: 'p1',
        name: 'Frankfurt · Reality',
        protocol: Protocol.vless,
        address: 'de1.example.net',
        port: 443,
        uuidOrPassword: 'uuid-1',
        subscriptionId: 'sub1',
      );
      xray.profiles = [p];
      xray.subscriptions = [sub];

      await xray.deleteProfile(p);
      expect(xray.profiles, isEmpty);
      final key = profileTombstoneKey(p);
      expect(sub.deletedProfileKeys, contains(key));
      expect(sub.deletedProfileData[key], isNotNull);
      final entry = xray.deletedProfiles.single;
      expect(entry.restorableNow, isTrue);
      expect(entry.label, 'Frankfurt · Reality');

      await xray.restoreDeletedProfile(sub, key);
      expect(xray.profiles.single.name, 'Frankfurt · Reality');
      expect(xray.profiles.single.uuidOrPassword, 'uuid-1');
      expect(sub.deletedProfileKeys, isNot(contains(key)));
      expect(sub.deletedProfileData, isEmpty);

      // Delete again, then purge: the data goes with it
      // and the restore falls back to the legacy
      // un-tombstone (nothing re-added).
      await xray.deleteProfile(xray.profiles.single);
      expect(sub.deletedProfileData[key], isNotNull);
      await xray.purgeDeletedProfile(sub, key);
      expect(sub.deletedProfileData, isEmpty);
      expect(xray.profiles, isEmpty);
    });
  });

  group('A43-29 — the app-lock PIN hash', () {
    AppSettings settingsWith(String hash) =>
        AppSettings()..appLockPinHash = hash;

    test('the v2 form is salted, stretched and verifies', () {
      final a = pinHashOf('1234');
      final b = pinHashOf('1234');
      expect(a, startsWith('v2:$pinHashIterations:'));
      expect(a, isNot(b)); // a fresh salt per store
      final s = settingsWith(a);
      expect(pinMatches(s, '1234'), isTrue);
      expect(pinMatches(s, '1235'), isFalse);
      expect(storedPinHashIsLegacy(s), isFalse);
    });

    test('a legacy hash verifies and migrates losslessly', () {
      final s = settingsWith(legacyPinHashOf('9876'));
      expect(storedPinHashIsLegacy(s), isTrue);
      expect(pinMatches(s, '9876'), isTrue);
      expect(pinMatches(s, '9877'), isFalse);
      upgradeLegacyPinHash(s, '9876');
      expect(s.appLockPinHash, startsWith('v2:'));
      expect(pinMatches(s, '9876'), isTrue);
    });

    test('a malformed v2 record never matches and never throws', () {
      expect(pinMatches(settingsWith('v2:x:y:z'), '1234'), isFalse);
      expect(pinMatches(settingsWith('v2:10000:zz:aa'), '1234'), isFalse);
      expect(pinMatches(settingsWith(''), '1234'), isFalse);
    });
  });

  group('A48-06 — sweep miss accounting', () {
    test('same network increments; a new network restarts at 1', () {
      final same = sweepMissOutcome(
        currentMisses: 2,
        recordedNetwork: 'wifi:Home',
        network: 'wifi:Home',
        isSelected: false,
        threshold: 3,
      );
      expect(same.misses, 3);
      expect(same.cut, isTrue);
      final moved = sweepMissOutcome(
        currentMisses: 2,
        recordedNetwork: 'wifi:Home',
        network: 'cell:IR',
        isSelected: false,
        threshold: 3,
      );
      expect(moved.misses, 1);
      expect(moved.network, 'cell:IR');
      expect(moved.cut, isFalse);
    });

    test('the selected profile is never counted and never cut', () {
      final outcome = sweepMissOutcome(
        currentMisses: 9,
        recordedNetwork: 'wifi:Home',
        network: 'wifi:Home',
        isSelected: true,
        threshold: 3,
      );
      expect(outcome.misses, 9);
      expect(outcome.network, 'wifi:Home');
      expect(outcome.cut, isFalse);
    });
  });

  group('expansion 4 — daily problem report', () {
    ProblemEvent ev(String type, int atMs, {String name = 'P'}) =>
        ProblemEvent(
          atMs: atMs,
          type: type,
          engine: 'V2Ray',
          profileName: name,
          shape: 'VLESS · tcp+reality',
          stage: 'connect',
          reason: 'the connect attempt failed',
        );

    test('per-type recording, day aggregation, digest shape', () {
      final now = DateTime.now();
      final t0 = DateTime(
        now.year,
        now.month,
        now.day,
        9,
        0,
      ).millisecondsSinceEpoch;
      final j = ProblemJournal();
      j.record(ev(ProblemTypes.connectFailure, t0));
      j.record(ev(ProblemTypes.connectFailure, t0 + 60000));
      j.record(ev(ProblemTypes.dnsFailure, t0 + 120000));
      j.record(
        ev(
          ProblemTypes.connectFailure,
          t0 - 24 * 3600 * 1000,
        ),
      );
      final counts = j.countsForDay(now);
      expect(counts[ProblemTypes.connectFailure], 2);
      expect(counts[ProblemTypes.dnsFailure], 1);
      expect(j.countForDay(now), 3);
      final digest = j.digestText(now);
      expect(digest.split('\n').first,
          startsWith('Ember daily problem report — '));
      expect(digest, contains('Connect failure: 2'));
      expect(digest, contains('DNS resolution failure: 1'));
      expect(digest, contains('— events —'));
      expect(digest, contains('09:00 · P (VLESS · tcp+reality)'));
    });

    test('retention: the rolling 7 days prune on record', () {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final j = ProblemJournal();
      j.record(ev(ProblemTypes.connectFailure, nowMs - 8 * 86400000));
      j.record(ev(ProblemTypes.connectFailure, nowMs - 6 * 86400000));
      j.record(ev(ProblemTypes.dnsFailure, nowMs));
      expect(j.events.length, 2);
      expect(
        j.events.map((e) => e.type),
        [ProblemTypes.connectFailure, ProblemTypes.dnsFailure],
      );
    });

    test('problemCodeOf extracts only a clean code token', () {
      expect(problemCodeOf('Bad state: start-failed: x'), 'start-failed');
      expect(problemCodeOf('Bad state: underlay-failed'), 'underlay-failed');
      expect(problemCodeOf('PlatformException(err, host 1.2.3.4)'), '');
      expect(problemCodeOf(''), '');
    });

    test('privacy: serialization carries no endpoint, no '
        'credential, no forbidden keys', () async {
      final tmp = await Directory.systemTemp.createTemp('ember2149prv-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('app/android'), (
        call,
      ) async {
        if (call.method == 'dataDir') return '${tmp.path}/core';
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('app/android'),
          null,
        ),
      );
      final c = XrayController();
      await c.load();
      await c.setProblemReportEnabled(true);
      final p = Profile(
        id: 'sec',
        name: 'Named Config',
        protocol: Protocol.trojan,
        address: 'secret.address.example',
        port: 443,
        uuidOrPassword: 'SECRET-PW-123',
        security: 'tls',
        network: 'ws',
        sni: 'secret.sni.example',
        host: 'secret.sni.example',
        path: '/secret-path',
      );
      c.recordProblem(
        type: ProblemTypes.connectFailure,
        profile: p,
        stage: 'connect',
        reason: 'the connect attempt failed',
      );
      expect(c.problemJournal.events.length, 1);
      final serialized = jsonEncode(c.problemJournal.toJson());
      final digest = c.problemJournal.digestText(DateTime.now());
      for (final secret in [
        'secret.address.example',
        'SECRET-PW-123',
        'secret.sni.example',
        '/secret-path',
        'trojan://',
      ]) {
        expect(serialized, isNot(contains(secret)), reason: secret);
        expect(digest, isNot(contains(secret)), reason: secret);
      }
      final eventJson =
          ((c.problemJournal.toJson()['events'] as List).single as Map);
      expect(
        eventJson.keys.toSet(),
        {
          'atMs',
          'type',
          'engine',
          'profileName',
          'shape',
          'stage',
          'reason',
        },
      );
      // The journal file landed beside the store.
      final f = File('${tmp.path}/xray/problem_report.json');
      var landed = false;
      for (var i = 0; i < 40 && !landed; i++) {
        landed = await f.exists();
        if (!landed) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      expect(landed, isTrue);
      c.dispose();
      // After dispose, recording is a silent no-op.
      c.recordProblem(
        type: ProblemTypes.connectFailure,
        reason: 'the connect attempt failed',
      );
      expect(c.problemJournal.events.length, 1);
    });

    test('toggle OFF records nothing and writes no file', () async {
      final tmp = await Directory.systemTemp.createTemp('ember2149off-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('app/android'), (
        call,
      ) async {
        if (call.method == 'dataDir') return '${tmp.path}/core';
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('app/android'),
          null,
        ),
      );
      final c = XrayController();
      await c.load();
      expect(c.problemReportOn, isFalse);
      c.recordProblem(
        type: ProblemTypes.connectFailure,
        reason: 'the connect attempt failed',
      );
      expect(c.problemJournal.events, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        await File('${tmp.path}/xray/problem_report.json').exists(),
        isFalse,
      );
      c.dispose();
    });

    test('the feature adds no timer of its own (pin)', () {
      final src = File(
        'lib/xray/problem_report.dart',
      ).readAsStringSync();
      expect(src, isNot(contains('Timer')));
      final page = File(
        'lib/ui/ember/daily_report_page.dart',
      ).readAsStringSync();
      expect(page, isNot(contains('Timer')));
      expect(page, isNot(contains('HttpClient')));
    });
  });

  group('expansion 3 — D1: adoption without proof', () {
    test('a session whose proof never lands is ADOPTED '
        'unverified, never torn down', () async {
      final tmp = await Directory.systemTemp.createTemp('ember2149d1-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      var running = false;
      var stops = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('app/android'), (
        call,
      ) async {
        switch (call.method) {
          case 'dataDir':
            return '${tmp.path}/core';
          case 'xraySetOn':
            running = true;
            return null;
          case 'xrayStop':
            stops++;
            running = false;
            return null;
          case 'xrayState':
            return <String, Object?>{
              'running': running,
              'name': 'N',
              'sinceMs': running ? 1000 : 0,
              'up': 0,
              'down': 0,
              'coreRestarts': 0,
              'coreProblem': '',
              'chainUnderlay': false,
              'chainProblem': '',
              'awg': false,
              'awgConfig': '',
              'rotationGen': 0,
              'killSwitchHeld': false,
              'paused': false,
              'userStopped': false,
            };
          case 'xrayExitInfo':
            return null; // the proof never lands
          case 'xrayTunnelCheck':
            return -1; // and no tunnel check carries either
          default:
            return null;
        }
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('app/android'),
          null,
        ),
      );
      final c = XrayController();
      await c.load();
      final p = Profile(
        id: 'd1',
        name: 'Slow first byte',
        protocol: Protocol.vless,
        address: '203.0.113.10',
        port: 443,
        security: 'reality',
        network: 'tcp',
      );
      c.profiles = [p];
      c.selectedProfileId = 'd1';
      // Pre-2149 this connect threw StateError('no-traffic')
      // after ~12 s and stopped the tunnel. D1: it adopts.
      await c.connect();
      expect(c.state.running, isTrue);
      expect(c.state.verified, isFalse);
      expect(c.connectedProfileId, 'd1');
      expect(stops, 0, reason: 'no teardown for a slow proof');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      c.dispose();
    });
  });

  group('expansion 3 — D2: pin-miss path + D3: allowInsecure', () {
    Map<String, dynamic> decodeCfg(String s) =>
        (jsonDecode(s) as Map).cast<String, dynamic>();
    Map<String, dynamic> proxyOutbound(Map<String, dynamic> cfg) =>
        (cfg['outbounds'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((o) => o['tag'] == 'proxy');

    test('D2 builder: the miss marker stamps UseIP with NO '
        'hosts entry; the domain stays the dialed address', () {
      final p = Profile(
        id: 'd2',
        name: 'Hostname',
        protocol: Protocol.vless,
        address: 'free.example.net',
        port: 443,
        security: 'reality',
        network: 'tcp',
      );
      final cfg = decodeCfg(
        buildTunnelConfig(
          p,
          XraySettings(),
          serverHostPins: const {
            'free.example.net': <String>[],
          },
        ),
      );
      final proxy = proxyOutbound(cfg);
      final sock =
          (proxy['streamSettings'] as Map<String, dynamic>)['sockopt']
              as Map<String, dynamic>;
      expect(sock['domainStrategy'], 'UseIP');
      expect(sock['happyEyeballs'], isNotNull);
      final hosts =
          (cfg['dns'] as Map<String, dynamic>)['hosts']
              as Map<String, dynamic>;
      expect(hosts.containsKey('free.example.net'), isFalse);
      final vnext =
          (proxy['settings'] as Map<String, dynamic>)['vnext'] as List;
      expect((vnext.first as Map)['address'], 'free.example.net');
    });

    test('D3: trojan/vless links honour allowInsecure; the '
        'default stays unset', () {
      final t = parseLink(
        'trojan://pw@203.0.113.10:443?security=tls&allowInsecure=1#T',
      );
      expect(t, isNotNull);
      expect(t!.allowInsecure, isTrue);
      final t0 = parseLink(
        'trojan://pw@203.0.113.10:443?security=tls#T',
      );
      expect(t0!.allowInsecure, isFalse);
      final v = parseLink(
        'vless://11111111-2222-3333-4444-555555555555'
        '@203.0.113.10:443?security=tls&insecure=1#V',
      );
      expect(v!.allowInsecure, isTrue);
      final h = parseLink(
        'hysteria2://pw@203.0.113.10:443?insecure=1#H',
      );
      expect(h!.allowInsecure, isTrue);
    });

    test('D3: the flag round-trips the store and the share '
        'link, and the builder emits it only when set', () {
      final p = Profile(
        id: 'd3',
        name: 'SelfSigned',
        protocol: Protocol.trojan,
        address: '203.0.113.10',
        port: 443,
        uuidOrPassword: 'pw',
        security: 'tls',
        network: 'tcp',
        allowInsecure: true,
      );
      final back = Profile.fromJson(p.toJson());
      expect(back.allowInsecure, isTrue);
      expect(profileToLink(p), contains('allowInsecure=1'));
      final cfg = decodeCfg(buildTunnelConfig(p, XraySettings()));
      final tls =
          (proxyOutbound(cfg)['streamSettings']
                  as Map<String, dynamic>)['tlsSettings']
              as Map<String, dynamic>;
      expect(tls['allowInsecure'], isTrue);
      final plain = Profile(
        id: 'd3b',
        name: 'Plain',
        protocol: Protocol.trojan,
        address: '203.0.113.10',
        port: 443,
        uuidOrPassword: 'pw',
        security: 'tls',
        network: 'tcp',
      );
      final cfg2 = decodeCfg(buildTunnelConfig(plain, XraySettings()));
      final tls2 =
          (proxyOutbound(cfg2)['streamSettings']
                  as Map<String, dynamic>)['tlsSettings']
              as Map<String, dynamic>;
      expect(tls2.containsKey('allowInsecure'), isFalse);
      expect(profileToLink(plain), isNot(contains('allowInsecure')));
    });

    test('D4: the fingerprint migration clears nothing', () {
      final profiles = [
        Profile(
          id: 'd4',
          name: 'Explicit chrome',
          protocol: Protocol.vless,
          address: '203.0.113.10',
          port: 443,
          security: 'reality',
          fingerprint: 'chrome',
        ),
      ];
      expect(clearParserDefaultFingerprints(profiles), 0);
      expect(profiles.single.fingerprint, 'chrome');
    });
  });

  group('expansion 2 — per-config node test + DNS list', () {
    test('the speed trio round-trips the profile JSON; '
        'old JSON defaults to never-measured', () {
      final p = Profile(
        id: 'x',
        protocol: Protocol.vless,
        lastSpeedBps: 5242880,
        lastSpeedUpBps: 1048576,
        speedTestedAtMs: 1760000000000,
      );
      final back = Profile.fromJson(p.toJson());
      expect(back.lastSpeedBps, 5242880);
      expect(back.lastSpeedUpBps, 1048576);
      expect(back.speedTestedAtMs, 1760000000000);
      final old = Profile.fromJson({'id': 'x', 'protocol': 'vless'});
      expect(old.lastSpeedUpBps, -1);
      expect(old.speedTestedAtMs, 0);
    });

    test('dnsServersOfConfigJson reads strings and scoped '
        'maps in order; garbage yields none', () {
      final config = jsonEncode({
        'dns': {
          'servers': [
            'fakedns',
            {'address': 'https://dns.example/dns-query', 'domains': ['x']},
            '8.8.8.8',
            {'noAddress': true},
            42,
          ],
        },
      });
      expect(
        dnsServersOfConfigJson(config),
        ['fakedns', 'https://dns.example/dns-query', '8.8.8.8'],
      );
      expect(dnsServersOfConfigJson('not json'), isEmpty);
      expect(dnsServersOfConfigJson('{}'), isEmpty);
    });

    test('the DNS list derives from a REAL generated config', () {
      final p = Profile(
        id: 'dns1',
        name: 'DNS probe',
        protocol: Protocol.vless,
        address: '203.0.113.10',
        port: 443,
        security: 'reality',
        network: 'tcp',
      );
      final settings = XraySettings();
      final servers = dnsServersOfConfigJson(
        buildTunnelConfig(p, settings),
      );
      // The generated config's own primary resolvers lead
      // the list — the derivation shows the config's
      // truth, whatever the settings' defaults are.
      expect(servers, isNotEmpty);
      expect(servers.first, primaryResolvers(settings).first);
    });

    test('testSpeed stamps delay + down + up + timestamp '
        'and persists the trio in the stats sidecar', () async {
      final tmp = await Directory.systemTemp.createTemp('ember2149speed-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('app/android'), (
        call,
      ) async {
        switch (call.method) {
          case 'dataDir':
            return '${tmp.path}/core';
          case 'xrayMeasureDelayEx':
            return <String, Object?>{
              'ms': 86,
              'ip': '203.0.113.9',
              'countryCode': 'DE',
            };
          case 'xraySpeedTest':
            return 5242880;
          case 'xraySpeedTestUp':
            return 1048576;
          default:
            return null;
        }
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('app/android'),
          null,
        ),
      );
      final c = XrayController();
      await c.load();
      final p = Profile(
        id: 'speed1',
        name: 'Speed probe',
        protocol: Protocol.vless,
        address: '203.0.113.10',
        port: 443,
        security: 'reality',
        network: 'tcp',
      );
      c.profiles = [p];
      final down = await c.testSpeed(p);
      expect(down, 5242880);
      expect(p.delayMs, 86);
      expect(p.delayFailed, isFalse);
      expect(p.exitIp, '203.0.113.9');
      expect(p.lastSpeedBps, 5242880);
      expect(p.lastSpeedUpBps, 1048576);
      expect(p.speedTestedAtMs, greaterThan(0));
      // The sidecar write is chained; wait for the file.
      final statsFile = File('${tmp.path}/xray/stats.json');
      Map<String, dynamic>? entry;
      for (var i = 0; i < 50 && entry == null; i++) {
        if (await statsFile.exists()) {
          final decoded = jsonDecode(await statsFile.readAsString());
          final byId = (decoded as Map<String, dynamic>)['profiles'];
          if (byId is Map<String, dynamic> && byId['speed1'] is Map) {
            entry = byId['speed1'] as Map<String, dynamic>;
          }
        }
        if (entry == null) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      expect(entry, isNotNull);
      expect(entry!['lastSpeedBps'], 5242880);
      expect(entry['lastSpeedUpBps'], 1048576);
      expect(entry['speedTestedAtMs'], p.speedTestedAtMs);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      c.dispose();
    });

    test('the stats overlay restores the speed trio onto '
        'a store that predates it', () async {
      final tmp = await Directory.systemTemp.createTemp('ember2149ov-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('app/android'), (
        call,
      ) async {
        if (call.method == 'dataDir') return '${tmp.path}/core';
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('app/android'),
          null,
        ),
      );
      final dir = Directory('${tmp.path}/xray');
      await dir.create(recursive: true);
      final p = Profile(
        id: 'ov1',
        name: 'Overlay probe',
        protocol: Protocol.vless,
        address: '203.0.113.10',
        port: 443,
      );
      // Seed a REAL store through a first controller, so
      // the document shape is the store's own.
      final seed = XrayController();
      await seed.load();
      seed.profiles = [p];
      seed.selectedProfileId = 'ov1';
      await seed.save();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      seed.dispose();
      final statsFile = File('${dir.path}/stats.json');
      await statsFile.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'profiles': {
            'ov1': {
              'delayMs': 42,
              'delayFailed': false,
              'delayStage': 'core',
              'totalDown': 0,
              'totalUp': 0,
              'statsUpdatedMs': 0,
              'exitIp': '',
              'exitCountryCode': '',
              'lastSpeedBps': 777,
              'lastSpeedUpBps': 555,
              'speedTestedAtMs': 1760000000000,
            },
          },
        }),
      );
      // The overlay only wins when the sidecar is at
      // least as fresh as the store.
      await statsFile.setLastModified(DateTime.now().add(
        const Duration(minutes: 1),
      ));
      final c = XrayController();
      await c.load();
      final loaded = c.profiles.single;
      expect(loaded.lastSpeedBps, 777);
      expect(loaded.lastSpeedUpBps, 555);
      expect(loaded.speedTestedAtMs, 1760000000000);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      c.dispose();
    });
  });

  group('expansion 5 — DNS preset catalogue', () {
    test('catalogue contents are exact — Global', () {
      expect(dnsPresetsGlobal.map((p) => p.name).toList(), [
        'Cloudflare',
        'Google',
        'Quad9',
        'AdGuard',
        'Control D',
      ]);
      final byName = {for (final p in dnsPresetsGlobal) p.name: p};
      void check(
        String name,
        String primary,
        String secondary,
        String? doh,
      ) {
        final p = byName[name]!;
        expect(p.primary, primary, reason: name);
        expect(p.secondary, secondary, reason: name);
        expect(p.doh, doh, reason: name);
      }

      check(
        'Cloudflare',
        '1.1.1.1',
        '1.0.0.1',
        'https://cloudflare-dns.com/dns-query',
      );
      check('Google', '8.8.8.8', '8.8.4.4', 'https://dns.google/dns-query');
      check(
        'Quad9',
        '9.9.9.9',
        '149.112.112.112',
        'https://dns.quad9.net/dns-query',
      );
      check(
        'AdGuard',
        '94.140.14.14',
        '94.140.15.15',
        'https://dns.adguard-dns.com/dns-query',
      );
      check('Control D', '76.76.2.0', '76.76.10.0', null);
    });

    test('catalogue contents are exact — Iran (verified 2026-11-25)', () {
      expect(dnsPresetsIran.map((p) => p.name).toList(), [
        'Shecan',
        'Electro',
        '403.online',
        'RadarGame',
        'Begzar',
      ]);
      final byName = {for (final p in dnsPresetsIran) p.name: p};
      void check(
        String name,
        String primary,
        String secondary,
        String? doh,
      ) {
        final p = byName[name]!;
        expect(p.primary, primary, reason: name);
        expect(p.secondary, secondary, reason: name);
        expect(p.doh, doh, reason: name);
      }

      // Shecan's pair + its officially published free DoH.
      check(
        'Shecan',
        '185.51.200.2',
        '178.22.122.100',
        'https://free.shecan.ir/dns-query',
      );
      check('Electro', '78.157.42.100', '78.157.42.101', null);
      check('403.online', '10.202.10.202', '10.202.10.102', null);
      check('RadarGame', '10.202.10.10', '10.202.10.11', null);
      // begzar.ir's own headline pair — the secondary is
      // 185.55.225.25 (the brief's 185.55.226.25 appears
      // in no source and is not shipped).
      check('Begzar', '185.55.226.26', '185.55.225.25', null);
    });

    test('fill values: DoH URL for remote when published, the '
        'plain pair otherwise; the primary for local', () {
      final byName = {for (final p in allDnsPresets) p.name: p};
      expect(
        byName['Cloudflare']!.remoteValue,
        'https://cloudflare-dns.com/dns-query',
      );
      expect(byName['Shecan']!.remoteValue, 'https://free.shecan.ir/dns-query');
      expect(byName['Electro']!.remoteValue, '78.157.42.100,78.157.42.101');
      expect(byName['403.online']!.remoteValue, '10.202.10.202,10.202.10.102');
      expect(byName['Control D']!.remoteValue, '76.76.2.0,76.76.10.0');
      expect(byName['Cloudflare']!.localValue, '1.1.1.1');
      expect(byName['RadarGame']!.localValue, '10.202.10.10');
      expect(byName['Begzar']!.localValue, '185.55.226.26');
    });

    test('dnsPresetNameFor labels plain addresses, DoH URLs, '
        '+one and tcp:// spellings — and nothing else', () {
      expect(dnsPresetNameFor('1.1.1.1'), 'Cloudflare');
      expect(dnsPresetNameFor('1.0.0.1'), 'Cloudflare');
      expect(dnsPresetNameFor('8.8.4.4'), 'Google');
      expect(dnsPresetNameFor('185.55.225.25'), 'Begzar');
      expect(dnsPresetNameFor('10.202.10.11'), 'RadarGame');
      expect(dnsPresetNameFor('https://cloudflare-dns.com/dns-query'),
          'Cloudflare');
      expect(dnsPresetNameFor('https+one://dns.google/dns-query'), 'Google');
      expect(dnsPresetNameFor('https://dns.quad9.net/dns-query'), 'Quad9');
      expect(
        dnsPresetNameFor('https://dns.adguard-dns.com/dns-query'),
        'AdGuard',
      );
      expect(dnsPresetNameFor('https://free.shecan.ir/dns-query'), 'Shecan');
      expect(dnsPresetNameFor('tcp://1.1.1.1'), 'Cloudflare');
      expect(dnsPresetNameFor('tcp://78.157.42.101'), 'Electro');
      expect(dnsPresetNameFor('fakedns'), isNull);
      expect(dnsPresetNameFor('localhost'), isNull);
      expect(dnsPresetNameFor('203.0.113.9'), isNull);
      expect(dnsPresetNameFor('https://dns.example/dns-query'), isNull);
      expect(dnsPresetNameFor(''), isNull);
    });

    test('defaults untouched: a fresh install and an upgrade '
        'both keep the shipped DNS values verbatim', () {
      final fresh = XraySettings();
      expect(fresh.remoteDns, 'https://cloudflare-dns.com/dns-query');
      expect(fresh.localDns, '1.1.1.1');
      expect(fresh.fallbackDns, 'https://dns.quad9.net/dns-query');
      // Upgrade path: a stored document with no DNS keys
      // (every pre-2149 document) loads the same defaults —
      // the catalogue applies nothing on its own.
      final upgraded = XraySettings.fromJson(const {});
      expect(upgraded.remoteDns, fresh.remoteDns);
      expect(upgraded.localDns, fresh.localDns);
      expect(upgraded.fallbackDns, fresh.fallbackDns);
      // The generated primary is the shipped default and
      // the matcher names it — the label is display only.
      expect(primaryResolvers(fresh), [
        'https://cloudflare-dns.com/dns-query',
      ]);
      expect(
        dnsPresetNameFor(primaryResolvers(fresh).single),
        'Cloudflare',
      );
    });
  });

  group('expansion 2 refinement — per-DNS pings through the config', () {
    // The mock panel for this group: records every channel
    // call; the DNS ping answers by rule — 1.1.1.1 answers
    // in 37 ms, 8.8.8.8 never answers, the Cloudflare DoH
    // answers in 96 ms, anything else in 88 ms.
    Future<(XrayController, Profile, List<MethodCall>)> rig(
      Directory tmp,
    ) async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('app/android'), (
        call,
      ) async {
        calls.add(call);
        switch (call.method) {
          case 'dataDir':
            return '${tmp.path}/core';
          case 'xrayDnsPing':
            final servers =
                (call.arguments as Map)['servers'] as List<Object?>;
            return <String, Object?>{
              'ok': 1,
              'error': '',
              'results': <String, Object?>{
                for (final s in servers)
                  s as String: s.contains('1.1.1.1')
                      ? 37
                      : s.contains('8.8.8.8')
                      ? -1
                      : s.contains('cloudflare')
                      ? 96
                      : 88,
              },
            };
          default:
            return null;
        }
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('app/android'),
          null,
        ),
      );
      final c = XrayController();
      await c.load();
      final p = Profile(
        id: 'dnsping1',
        name: 'DNS ping probe',
        protocol: Protocol.vless,
        address: '203.0.113.10',
        port: 443,
        security: 'reality',
        network: 'tcp',
      );
      c.profiles = [p];
      return (c, p, calls);
    }

    test('fan-out: one instance call, one result per listed '
        'server, mixed outcomes, stamped + persisted', () async {
      final tmp = await Directory.systemTemp.createTemp('ember2149dns-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final (c, p, calls) = await rig(tmp);
      c.settings.remoteDns = '1.1.1.1,8.8.8.8';
      // The exact list the test-instance config carries —
      // the fan-out's contract is against THIS list.
      final listed = dnsServersOfConfigJson(
        buildTestConfig(p, c.settings),
      );
      expect(listed, containsAll(['1.1.1.1', '8.8.8.8']));
      final results = await c.testDnsPings(p);
      // One native call, instance mode, carrying every
      // probed server (fakedns/localhost are never asked).
      final pings = calls.where((x) => x.method == 'xrayDnsPing').toList();
      expect(pings, hasLength(1));
      final args = pings.single.arguments as Map;
      expect(args['mode'], 'config');
      final probed = (args['servers'] as List).cast<String>();
      expect(
        probed,
        listed.where((s) => s != 'fakedns' && s != 'localhost').toList(),
      );
      // One result per listed server, mixed success/failure.
      expect(results.keys.toSet(), listed.toSet());
      expect(results['1.1.1.1'], 37);
      expect(results['8.8.8.8'], -1);
      if (listed.contains('fakedns')) expect(results['fakedns'], -2);
      // Stamped on the profile with a fresh timestamp.
      expect(p.dnsPingMs, results);
      expect(p.dnsPingAtMs, greaterThan(0));
      // Isolation: the active session was never touched —
      // no start/stop/rotate call of any kind, state and
      // selection exactly as before.
      expect(
        calls.map((x) => x.method),
        isNot(anyOf(contains('xraySetOn'), contains('xrayStop'))),
      );
      expect(c.state.running, isFalse);
      expect(c.selectedProfileId, isEmpty);
      // Persistence: the profile JSON round-trips the map.
      final back = Profile.fromJson(p.toJson());
      expect(back.dnsPingMs, results);
      expect(back.dnsPingAtMs, p.dnsPingAtMs);
      // And the stats sidecar carries both fields.
      final statsFile = File('${tmp.path}/xray/stats.json');
      Map<String, dynamic>? entry;
      for (var i = 0; i < 50 && entry == null; i++) {
        if (await statsFile.exists()) {
          final decoded = jsonDecode(await statsFile.readAsString());
          final byId = (decoded as Map<String, dynamic>)['profiles'];
          if (byId is Map<String, dynamic> && byId['dnsping1'] is Map) {
            entry = byId['dnsping1'] as Map<String, dynamic>;
          }
        }
        if (entry == null) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      expect(entry, isNotNull);
      expect(entry!['dnsPingAtMs'], p.dnsPingAtMs);
      expect(
        (entry['dnsPingMs'] as Map)['1.1.1.1'],
        37,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      c.dispose();
    });

    test('live path: the connected config is probed through '
        'its own tunnel port, never an instance', () async {
      final tmp = await Directory.systemTemp.createTemp('ember2149live-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final (c, p, calls) = await rig(tmp);
      c.settings.remoteDns = '1.1.1.1,8.8.8.8';
      c.state = const XrayState(
        running: true,
        name: 'DNS ping probe',
        sinceMs: 0,
        upBytes: 0,
        downBytes: 0,
      );
      c.selectedProfileId = p.id;
      final results = await c.testDnsPings(p);
      final pings = calls.where((x) => x.method == 'xrayDnsPing').toList();
      expect(pings, hasLength(1));
      final args = pings.single.arguments as Map;
      expect(args['mode'], 'port');
      expect(args['socksPort'], c.settings.socksPort);
      expect(results['1.1.1.1'], 37);
      expect(results['8.8.8.8'], -1);
      expect(p.dnsPingAtMs, greaterThan(0));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      c.dispose();
    });

    test('preset transport: direct when down, the live port '
        'when a tunnel is up', () async {
      final tmp = await Directory.systemTemp.createTemp('ember2149pre-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final (c, p, calls) = await rig(tmp);
      final down = await c.testPresetDns(['1.1.1.1']);
      expect(down, {'1.1.1.1': 37});
      c.state = const XrayState(
        running: true,
        name: 'x',
        sinceMs: 0,
        upBytes: 0,
        downBytes: 0,
      );
      final up = await c.testPresetDns(['1.1.1.1']);
      expect(up, {'1.1.1.1': 37});
      final modes = calls
          .where((x) => x.method == 'xrayDnsPing')
          .map((x) => (x.arguments as Map)['mode'])
          .toList();
      expect(modes, ['direct', 'port']);
      // Session-only: nothing was stamped anywhere.
      expect(p.dnsPingAtMs, 0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      c.dispose();
    });

    test('the stored ping map reads tolerantly', () {
      final p = Profile.fromJson({
        'id': 'x',
        'protocol': 'vless',
        'dnsPingMs': {'a': 'junk', 'b': 12, 'c': double.infinity},
        'dnsPingAtMs': 42,
      });
      expect(p.dnsPingMs, {'b': 12});
      expect(p.dnsPingAtMs, 42);
      final bare = Profile.fromJson({'id': 'x', 'protocol': 'vless'});
      expect(bare.dnsPingMs, isEmpty);
      expect(bare.dnsPingAtMs, 0);
    });
  });
}
