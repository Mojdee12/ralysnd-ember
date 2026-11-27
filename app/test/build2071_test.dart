// Build 2071 — fix round 2 from the full review
// (full-review-2026-11-15.md §9 items 2 and 8; §3.3, §1.5,
// §5.4, §5.2, §5.5). Owner's order: fix all the app's
// problems under the standing no-regression rule — nothing
// that works may break; no per-round delivery. Psiphon is
// parked by his order: its engine/stack are untouched (the
// Psiphon CONTROLLER's store wiring below is the shared
// §5.4 fix every store-backed controller received, not a
// Psiphon engine change).
//
// Item 2 (§3.3): the inherited update checker ran on
// Android every 5 days against the upstream repo
// (armanlife/firefox-vpn-client) and could offer a foreign
// "Firefox-VPN" update, while appBuildNumber sat hardcoded
// at '2031' — 38 builds stale in the brand panel. The
// checker now never starts on Android (the runAndroid call
// is gone AND Updates.start refuses the platform), the
// desktop entry keeps its behaviour, and the build number
// comes from the build itself (--dart-define=APP_BUILD,
// alongside APP_VERSION). No update UI or feed was
// invented — self-update stays decision-gated.
//
// Item 8a (§1.5): two engines shared the label 'WARP'.
// The shell's standalone Aether engine (cfwarp slot) keeps
// 'WARP'; the EmberWarp core (home card, V2Ray underlay,
// standalone session) now surfaces under its own name,
// 'EmberWarp', everywhere — card title, settings title,
// session/notification name, scanner text.
//
// Item 8b (§1.5/§8.1): the warp-plus engine was deleted in
// build 2023, but its whole legacy string family (18 keys)
// still shipped in every locale. All 18 had zero callers;
// they are removed from every ARB and the generated
// localizations.
//
// Item 8c (§5.4): a failing on-disk store was swallowed
// forever — every change lost silently, corrupt stores
// loaded silently empty. AtomicJsonStore now records its
// outcomes (lastWriteError / lastReadProblem) and each
// store-backed controller (Xray, Psiphon, OpenVPN, Aether)
// surfaces them on its existing lastError surface via a
// storeError that persists until the next successful save
// (a damaged-at-load notice persists until the next clean
// load). Healthy-store behaviour is unchanged.
//
// Item 8d (§5.2/§5.5): OpenVpnVault saves and XrayTester's
// config writes now go through AtomicFile (flush + fsync
// before the rename), and the dead widgets WorldMapPanel
// and EmberAppBar are removed (the batch14 pin updates
// are recorded in BUILD-LOG-2.md).
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/atomic_json_store.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

/// The source from one marker to the next.
String segmentOf(String source, String from, String to) {
  final start = source.indexOf(from);
  expect(start, isNonNegative, reason: '"$from" exists');
  final end = source.indexOf(to, start);
  expect(end, isNonNegative, reason: '"$to" bounds "$from"');
  return source.substring(start, end);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('update checker (review §3.3)', () {
    test('runAndroid never starts the checker; desktop still does', () {
      final main = dartSrc('main.dart');
      final android = main.substring(main.indexOf('Future<void> runAndroid()'));
      expect(
        android.contains('Updates.start('),
        isFalse,
        reason: 'the Android entry must not start the checker',
      );
      expect(
        'Updates.start('.allMatches(main).length,
        1,
        reason: 'only the desktop entry starts the checker',
      );
    });

    test('Updates.start refuses Android itself', () {
      final updates = dartSrc('core/updates.dart');
      final body = segmentOf(
        updates,
        'static void start(',
        'static void reset()',
      );
      expect(body.contains('Platform.isAndroid'), isTrue);
      expect(
        body.indexOf('Platform.isAndroid') < body.indexOf('_first = Timer('),
        isTrue,
        reason: 'the platform gate precedes any timer',
      );
    });

    test('the build number derives from the build, not a constant', () {
      final info = dartSrc('app_info.dart');
      final decl = segmentOf(info, 'const appBuildNumber', ';');
      expect(decl.contains('String.fromEnvironment'), isTrue);
      expect(decl.contains("'APP_BUILD'"), isTrue);
      expect(
        decl.contains("= '2031'"),
        isFalse,
        reason:
            'the stale hardcoded build number is gone '
            '(the value survives only in the comment that '
            'records what it replaced)',
      );
      expect(
        File('pubspec.yaml').readAsStringSync().contains(
          // Updated by build 2110 (the standing per-build pin:
          // it names the build the tree currently ships as).
          // Build 2128: re-pointed 2126 → 2128 per that same
          // doctrine (the pin sat stale through 2127, whose
          // pubspec already read +2127 — the test failed on
          // the frozen 2127 tree for that reason alone).
          // Build 2136: re-pointed 2135 → 2136 per the same
          // standing doctrine.
          // Build 2146: re-pointed 2145 → 2146 per the same
          // standing doctrine (all 26 version pins in the
          // suite moved together, as in every prior build).
          'version: 2.2.0+2157',
        ),
        isTrue,
        reason: 'pubspec carries the real build this ships as',
      );
    });
  });

  group('WARP labels (review §1.5)', () {
    test('the EmberWarp session carries its own name', () {
      final xray = dartSrc('xray/xray_controller.dart');
      expect(xray.contains("warpSessionName = 'EmberWarp'"), isTrue);
      final mainActivity = ktSrc('MainActivity.kt');
      final warpBranch = segmentOf(
        mainActivity,
        'XrayVpnService.startWarp(',
        'call.argument<String>("dns")',
      );
      expect(warpBranch.contains('?: "EmberWarp"'), isTrue);
    });

    test('EmberWarp surfaces say EmberWarp', () {
      final home = dartSrc('ui/ember/ember_home.dart');
      expect(home.contains("Text('EmberWarp'"), isTrue);
      expect(home.contains('WARP MASQUE'), isFalse);
      expect(
        home.contains("label: 'EmberWarp'"),
        isTrue,
        reason: 'the underlay chip names the engine it picks',
      );
      final wsp = dartSrc('ui/ember/warp_settings_page.dart');
      expect(wsp.contains("'EmberWarp settings'"), isTrue);
      expect(wsp.contains("'WARP settings'"), isFalse);
      final scanner = dartSrc('ui/ember/cf_scanner_page.dart');
      expect(scanner.contains('EmberWarp gateway pinned'), isTrue);
      expect(scanner.contains('in WARP settings'), isFalse);
    });

    test('the Aether engine keeps the WARP name', () {
      final shell = dartSrc('ui/ember/ember_shell.dart');
      expect(shell.contains("6 => 'WARP'"), isTrue);
      final aether = dartSrc('aether/aether_controller.dart');
      expect(aether.contains("isWarp ? 'WARP' : 'MASQUE'"), isTrue);
      final settings = dartSrc('ui/ember/ember_settings.dart');
      expect(settings.contains("name: 'WARP', controller: warp"), isTrue);
    });
  });

  group('warp-plus ghosts (review §1.5, §8.1)', () {
    const deadKeys = [
      'warpLogs',
      'warpNoAccount',
      'warpMode',
      'warpModeStandard',
      'warpModeGool',
      'warpModeCfon',
      'warpModeStandardHint',
      'warpModeGoolHint',
      'warpModeCfonHint',
      'warpScan',
      'warpScanHint',
      'warpCountry',
      'warpEndpoint',
      'warpEndpointAuto',
      'warpEndpointHint',
      'warpNextConnectHint',
      'warpLocalProxy',
      'warpMasqueNote',
    ];

    test('the dead keys are out of the template ARB', () {
      final arb = File('lib/l10n/app_en.arb').readAsStringSync();
      for (final key in deadKeys) {
        expect(arb.contains('"$key"'), isFalse, reason: '$key removed');
      }
    });

    test('no warp-plus copy ships anywhere in lib/', () {
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith('.dart')) {
          if (entity.readAsStringSync().contains('warp-plus')) {
            offenders.add(entity.path);
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'the removed engine is not described anywhere',
      );
    });
  });

  group('store surfacing — pins (review §5.4)', () {
    test('the store records its outcomes', () {
      final store = dartSrc('atomic_json_store.dart');
      expect(store.contains('Object? lastWriteError'), isTrue);
      expect(store.contains('String? lastReadProblem'), isTrue);
      expect(store.contains('storeSaveFailedMessage'), isTrue);
      expect(store.contains('storeDamagedMessage'), isTrue);
    });

    test('every store-backed controller surfaces storeError', () {
      for (final path in [
        'xray/xray_controller.dart',
        'psiphon/psiphon_controller.dart',
        'openvpn/openvpn_controller.dart',
        'aether/aether_controller.dart',
      ]) {
        final src = dartSrc(path);
        expect(src.contains('String? storeError'), isTrue, reason: path);
        expect(
          src.contains('_lastError ?? storeError'),
          isTrue,
          reason: '$path folds storeError into its error surface',
        );
        expect(src.contains('storeSaveFailedMessage'), isTrue, reason: path);
      }
      for (final path in [
        'psiphon/psiphon_controller.dart',
        'openvpn/openvpn_controller.dart',
        'aether/aether_controller.dart',
      ]) {
        expect(
          dartSrc(path).contains('storeDamagedMessage'),
          isTrue,
          reason: path,
        );
        expect(dartSrc(path).contains('lastReadProblem'), isTrue, reason: path);
      }
      final xray = dartSrc('xray/xray_controller.dart');
      expect(
        xray.contains('The saved data was damaged'),
        isTrue,
        reason: 'the Xray store names its own damage',
      );
      expect(
        xray.contains('lastWriteError'),
        isFalse,
        reason: 'the Xray store is its own writer, not the shared one',
      );
    });
  });

  group('store surfacing — AtomicJsonStore behaviour', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ember2071store');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('round-trip is clean and records no complaint', () async {
      final store = AtomicJsonStore(File('${tmp.path}/s.json'));
      await store.write({'a': 1});
      expect(store.lastWriteError, isNull);
      expect(await store.read(), {'a': 1});
      expect(store.lastReadProblem, isNull);
    });

    test('a missing file is a clean first run, not damage', () async {
      final store = AtomicJsonStore(File('${tmp.path}/none.json'));
      expect(await store.read(), isNull);
      expect(store.lastReadProblem, isNull);
    });

    test('a corrupt file surfaces as damaged and is quarantined', () async {
      final file = File('${tmp.path}/s.json');
      await file.writeAsString('this is not json {');
      final store = AtomicJsonStore(file);
      expect(
        await store.read(),
        isNull,
        reason: 'the load still starts empty — it just says so',
      );
      expect(store.lastReadProblem, 'damaged');
      expect(
        await file.exists(),
        isFalse,
        reason: 'the damaged bytes were moved aside',
      );
      final kept = File('${tmp.path}/s.json.corrupt');
      expect(await kept.exists(), isTrue);
      expect(await kept.readAsString(), 'this is not json {');
    });

    test(
      'a failed write is recorded, then cleared by the next success',
      () async {
        final file = File('${tmp.path}/s.json');
        final store = AtomicJsonStore(file);
        // Block the temp path with a directory: the atomic
        // write cannot land.
        await Directory('${file.path}.tmp').create();
        await store.write({'a': 1});
        expect(
          store.lastWriteError,
          isNotNull,
          reason: 'the failure is recorded, not swallowed',
        );
        await Directory('${file.path}.tmp').delete();
        await store.write({'a': 2});
        expect(
          store.lastWriteError,
          isNull,
          reason: 'the next success clears the record',
        );
        expect(await store.read(), {'a': 2});
      },
    );
  });

  group('store surfacing — Psiphon controller behaviour', () {
    const channel = MethodChannel('app/android');
    late Directory tmp;
    late File stateFile;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ember2071psi');
      // dataDir() names the core dir; the store lives beside
      // it at <parent>/psiphon/state.json.
      final coreDir = Directory('${tmp.path}/core')..createSync();
      stateFile = File('${tmp.path}/psiphon/state.json');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'dataDir') return coreDir.path;
            return null;
          });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('a corrupt store loads empty but says so, and the notice '
        'survives a successful save', () async {
      await stateFile.parent.create(recursive: true);
      await stateFile.writeAsString('garbage{{{');
      final c = PsiphonController();
      await c.load();
      expect(c.storeError, storeDamagedMessage);
      expect(
        c.lastError,
        storeDamagedMessage,
        reason: 'the existing error surface carries it',
      );
      // A successful save must not erase the notice before
      // anyone saw it (build 2071 rule).
      await c.updateSettings(PsiphonSettings());
      expect(
        await stateFile.exists(),
        isTrue,
        reason: 'the save landed on a fresh file',
      );
      expect(c.storeError, storeDamagedMessage);
    });

    test('a failing save surfaces, then clears on the next success', () async {
      final c = PsiphonController();
      await c.load();
      expect(c.storeError, isNull);
      await Directory('${stateFile.path}.tmp').create(recursive: true);
      await c.updateSettings(PsiphonSettings());
      expect(c.storeError, storeSaveFailedMessage);
      expect(c.lastError, storeSaveFailedMessage);
      await Directory('${stateFile.path}.tmp').delete();
      await c.updateSettings(PsiphonSettings());
      expect(
        c.storeError,
        isNull,
        reason: 'persistent-until-next-success, then clear',
      );
      expect(c.lastError, isNull);
    });
  });

  group('atomic writes + dead widgets (review §5.2, §5.5)', () {
    test('the vault saves through AtomicFile', () {
      final vault = ktSrc('OpenVpnVault.kt');
      expect(vault.contains('AtomicFile.writeText(target'), isTrue);
      expect(vault.contains('tmp.writeText'), isFalse);
    });

    test('XrayTester writes its configs atomically', () {
      final tester = ktSrc('XrayTester.kt');
      expect(
        'AtomicFile.writeText(configFile, configJson)'
            .allMatches(tester)
            .length,
        2,
      );
      expect(tester.contains('configFile.writeText'), isFalse);
    });

    test('the dead widgets are gone', () {
      expect(
        dartSrc('ui/ember/world_map.dart').contains('class WorldMapPanel'),
        isFalse,
      );
      expect(
        dartSrc('ui/ember/ember_theme.dart').contains('class EmberAppBar'),
        isFalse,
      );
    });
  });
}
