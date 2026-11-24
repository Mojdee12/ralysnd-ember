// Build 2075 — the in-app updater (curated feature #5 / full-review
// §9 item 2, feed-exists branch): Ember checks its own GitHub
// Releases feed, downloads the APK with progress, and hands it to
// the system installer. The feed is Mojdee12/ralysnd-ember — the
// repo that actually publishes the builds (its v2074 release, saved
// as test/fixtures/github_release_latest.json, carries the APK;
// Mojdee12/ralysnd-ember-releases holds no release — its latest
// endpoint answers 404, verified 2026-11-15 — so the updater must
// never point there). The inherited upstream checker stays off on
// Android (build 2071). In tests the current build is 2071, so the
// v2074 fixture reads as a newer build.
// Build 2106 (journey audit F-09): the current build's ONLY
// source is now the package's own versionCode — the APP_BUILD
// define fallback is gone (its compiled-in default named 2071
// forever). The harness therefore supplies the platform's
// answer directly (updaterIn sets packageBuild = 2071, which
// resolvePackageBuild then keeps), exactly what the device
// channel returns on a real 2071 install.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/lantern/lantern_controller.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/ui/ember/ember_settings.dart';
import 'package:firefox_vpn/ui/ember/ember_updater.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();
String manifestSrc() =>
    File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

/// The real v2074 release payload (GitHub API, 2026-11-15).
Map<String, dynamic> fixture() => jsonDecode(
      File(
        'test/fixtures/github_release_latest.json',
      ).readAsStringSync(),
    ) as Map<String, dynamic>;

String fixtureJson() =>
    File('test/fixtures/github_release_latest.json').readAsStringSync();

Future<EmberUpdater> updaterIn(
  Directory dir, {
  Future<String> Function(Uri url)? fetcher,
}) async {
  final settings = await AppSettings.load(dir.path);
  // Build 2106 (F-09): the platform's appBuildNumber answer,
  // supplied directly — the tests' current build is 2071.
  return EmberUpdater(settings: settings, dataDir: dir.path, fetcher: fetcher)
    ..packageBuild = 2071;
}

/// A loopback server answering every GET with [bytes]; returns the
/// server (close in tearDown) and the URL to fetch them from.
Future<(HttpServer, String)> serveBytes(List<int> bytes) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    req.response.headers.contentLength = bytes.length;
    req.response.add(bytes);
    await req.response.close();
  });
  return (server, 'http://127.0.0.1:${server.port}/RalysndEmber2.apk');
}

/// Pumps EmberSettings in V2Ray mode (1) with fresh controllers
/// (same shape as the build2063 helper).
Future<void> pumpSettings(WidgetTester tester) async {
  final core = CoreController(
    () async => throw const CoreUnavailable(CoreProblem.refused, 'test'),
  );
  addTearDown(core.dispose);
  final xray = XrayController();
  addTearDown(xray.dispose);
  final psiphon = PsiphonController();
  addTearDown(psiphon.dispose);
  final lantern = LanternController();
  addTearDown(lantern.dispose);
  final openvpn = OpenVpnController();
  addTearDown(openvpn.dispose);
  final settings = AppSettings()..emberMode = 1;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: EmberSettings(
          core: core,
          xray: xray,
          psiphon: psiphon,
          lantern: lantern,
          openvpn: openvpn,
          settings: settings,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ember2075_');
    EmberUpdater.instance = null;
    // This file contains testWidgets, so the test binding
    // installs its mock HttpClient (400 for everything) over
    // the whole file — the download() tests serve REAL bytes
    // from a loopback server and need the real client.
    HttpOverrides.global = null;
  });
  tearDown(() {
    EmberUpdater.instance = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app/android'),
          null,
        );
    dir.deleteSync(recursive: true);
  });

  group('release tags name builds', () {
    test('plain and v-prefixed build tags', () {
      expect(buildFromReleaseTag('v2075'), 2075);
      expect(buildFromReleaseTag('2075'), 2075);
      expect(buildFromReleaseTag('V2075'), 2075);
      expect(buildFromReleaseTag('v2.2.0+2075'), 2075);
      expect(buildFromReleaseTag('  v2075  '), 2075);
    });

    test('version tags and garbage are not build tags', () {
      expect(buildFromReleaseTag('v1.2.3'), isNull);
      expect(buildFromReleaseTag('v2074-rc1'), isNull);
      expect(buildFromReleaseTag(''), isNull);
      expect(buildFromReleaseTag('v'), isNull);
      expect(buildFromReleaseTag('latest'), isNull);
    });
  });

  group('the feed payload', () {
    test('the real v2074 release parses', () {
      final release = parseLatestRelease(fixture());
      expect(release, isNotNull);
      expect(release!.tag, 'v2074');
      expect(release.build, 2074);
      expect(release.name, 'Ralysnd Ember 2.2.0 — build 2074');
      expect(
        release.apkUrl,
        'https://github.com/Mojdee12/ralysnd-ember/releases/download/v2074/RalysndEmber2.apk',
      );
      expect(release.apkSize, 111647899);
      expect(release.isNewerThan(2071), isTrue);
      expect(release.isNewerThan(2074), isFalse);
      expect(release.isNewerThan(2075), isFalse);
    });

    test('unusable payloads are no update, never a crash', () {
      expect(parseLatestRelease(null), isNull);
      expect(parseLatestRelease('v2074'), isNull);
      expect(parseLatestRelease({'tag_name': 'v2074'}), isNull);
      expect(
        parseLatestRelease({'tag_name': 'v2074', 'assets': []}),
        isNull,
      );
      expect(
        parseLatestRelease({
          'tag_name': 'v2074',
          'assets': [
            {'name': 'SomethingElse.zip', 'browser_download_url': 'https://x/y'},
          ],
        }),
        isNull,
      );
      expect(parseLatestRelease({'tag_name': 'v1.2.3', 'assets': []}), isNull);
      expect(
        parseLatestRelease({
          'tag_name': 'v2074',
          'assets': [
            {'name': 'RalysndEmber2.apk'},
          ],
        }),
        isNull,
      );
    });

    test('the feed is the repo that actually publishes the builds', () {
      // The -releases repo holds no release (its /releases/latest
      // answers 404); the source repo's Releases is the live feed.
      expect(
        emberUpdateFeedUrl,
        'https://api.github.com/repos/Mojdee12/ralysnd-ember/releases/latest',
      );
      expect(emberUpdateFeedUrl, isNot(contains('ralysnd-ember-releases')));
      expect(emberUpdateAssetName, 'RalysndEmber2.apk');
    });
  });

  group('the 24 h auto-check throttle', () {
    test('due on first run, due after 25 h, held inside 24 h', () async {
      final u = await updaterIn(dir);
      expect(u.autoCheckDue(DateTime.now()), isTrue);
      final now = DateTime.now();
      u.settings.update(
        lastEmberUpdateCheckMs:
            now.millisecondsSinceEpoch - const Duration(hours: 25).inMilliseconds,
      );
      expect(u.autoCheckDue(now), isTrue);
      u.settings.update(
        lastEmberUpdateCheckMs:
            now.millisecondsSinceEpoch - const Duration(hours: 1).inMilliseconds,
      );
      expect(u.autoCheckDue(now), isFalse);
    });

    test('a completed look stamps the throttle, and it persists', () async {
      final u = await updaterIn(dir, fetcher: (_) async => fixtureJson());
      await u.check(manual: true);
      expect(u.state, EmberUpdateState.available);
      expect(u.settings.lastEmberUpdateCheckMs, greaterThan(0));
      // The stamp reaches the disk (a restart 23 h later stays silent).
      final file = File('${dir.path}/app-settings.json');
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      var landed = false;
      while (!landed && DateTime.now().isBefore(deadline)) {
        try {
          final doc =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          landed = (doc['ember_update_checked_ms'] as int? ?? 0) > 0;
        } catch (_) {
          landed = false;
        }
        if (!landed) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      }
      expect(landed, isTrue);
      final reloaded = await AppSettings.load(dir.path);
      expect(reloaded.lastEmberUpdateCheckMs, greaterThan(0));
      // A fresh updater on the reloaded settings stays silent
      // inside the 24 h window.
      final u2 = EmberUpdater(settings: reloaded, dataDir: dir.path);
      expect(u2.autoCheckDue(DateTime.now()), isFalse);
    });
  });

  group('check()', () {
    test('a newer build is available', () async {
      final u = await updaterIn(dir, fetcher: (_) async => fixtureJson());
      await u.check(manual: true);
      expect(u.state, EmberUpdateState.available);
      expect(u.release!.build, 2074);
      expect(u.errorText, isEmpty);
    });

    test('the current build is up to date', () async {
      final same = fixture()
        ..['tag_name'] = 'v2071'
        ..['name'] = 'Ralysnd Ember 2.2.0 — build 2071';
      final u = await updaterIn(dir, fetcher: (_) async => jsonEncode(same));
      await u.check(manual: true);
      expect(u.state, EmberUpdateState.upToDate);
      expect(u.release!.build, 2071);
    });

    test('a payload with no usable release is a plain sentence', () async {
      final u = await updaterIn(dir, fetcher: (_) async => '{}');
      await u.check(manual: true);
      expect(u.state, EmberUpdateState.error);
      expect(u.errorText, contains('No update information'));
    });

    test('no network is a plain sentence, never raw exception text', () async {
      final u = await updaterIn(
        dir,
        fetcher: (_) async => throw const SocketException('closed'),
      );
      await u.check(manual: true);
      expect(u.state, EmberUpdateState.error);
      expect(u.errorText, contains('Could not reach GitHub'));
      expect(u.errorText, isNot(contains('SocketException')));
      expect(u.errorText, isNot(contains('closed')));
    });

    test('a manual check runs inside the throttle, an auto one does not',
        () async {
      var calls = 0;
      final u = await updaterIn(
        dir,
        fetcher: (_) async {
          calls++;
          return fixtureJson();
        },
      );
      await u.check(manual: true);
      expect(calls, 1);
      // Inside the 24 h window: a silent auto-check does nothing.
      await u.check(manual: false);
      expect(calls, 1);
      expect(u.state, EmberUpdateState.available);
      // A manual check runs again.
      await u.check(manual: true);
      expect(calls, 2);
    });

    test('a check already in flight is not started twice', () async {
      var calls = 0;
      final u = await updaterIn(
        dir,
        fetcher: (_) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return fixtureJson();
        },
      );
      final first = u.check(manual: true);
      await u.check(manual: true);
      await first;
      expect(calls, 1);
    });
  });

  group('download()', () {
    // Build 2125 SUPERSESSION (recorded, not silent): the
    // A25-49 URL policy refuses non-GitHub addresses, so
    // these behavioural tests — which serve bytes from a
    // local test server — now run through the updater's
    // urlPolicyOverride test seam. The policy itself is
    // pinned functionally in build2125_test.dart. The
    // A25-09 changes also land here: the part file is
    // tag-scoped, and a short download KEEPS its part as
    // resume state instead of deleting it.
    test('a complete download lands as a file with the feed size', () async {
      final bytes = List<int>.generate(4096, (i) => i % 251);
      final (server, url) = await serveBytes(bytes);
      addTearDown(() => server.close(force: true));
      final feed = fixture()
        ..['tag_name'] = 'v2099'
        ..['assets'] = [
          {
            'name': 'RalysndEmber2.apk',
            'browser_download_url': url,
            'size': bytes.length,
          },
        ];
      final u = await updaterIn(dir, fetcher: (_) async => jsonEncode(feed));
      u.urlPolicyOverride = (_) => true;
      // Build 2129 (leg 6): the signing-cert check runs through its seam here, like the URL policy above.
      u.certCheckOverride = (_) async => true;
      await u.check(manual: true);
      expect(u.state, EmberUpdateState.available);
      await u.download();
      expect(u.state, EmberUpdateState.downloaded);
      expect(u.progress, 1);
      final file = File(u.downloadedPath!);
      expect(file.existsSync(), isTrue);
      expect(file.path, endsWith('RalysndEmber2-v2099.apk'));
      expect(file.lengthSync(), bytes.length);
      expect(file.readAsBytesSync(), bytes);
      expect(
          File('${dir.path}/updates/RalysndEmber2-v2099.apk.part')
              .existsSync(),
          isFalse);
    });

    test('a short download is incomplete, never installable', () async {
      final bytes = List<int>.generate(1024, (i) => i % 251);
      final (server, url) = await serveBytes(bytes);
      addTearDown(() => server.close(force: true));
      final feed = fixture()
        ..['tag_name'] = 'v2099'
        ..['assets'] = [
          {
            'name': 'RalysndEmber2.apk',
            'browser_download_url': url,
            'size': bytes.length + 10,
          },
        ];
      final u = await updaterIn(dir, fetcher: (_) async => jsonEncode(feed));
      u.urlPolicyOverride = (_) => true;
      await u.check(manual: true);
      await u.download();
      expect(u.state, EmberUpdateState.error);
      expect(u.errorText, contains('incomplete'));
      expect(u.downloadedPath, isNull);
      // Build 2125 (A25-09): the part is KEPT — it is the
      // resume state the next download() continues from.
      final part =
          File('${dir.path}/updates/RalysndEmber2-v2099.apk.part');
      expect(part.existsSync(), isTrue);
      expect(part.lengthSync(), bytes.length);
      expect(File('${dir.path}/updates/RalysndEmber2-v2099.apk').existsSync(),
          isFalse);
    });

    test('an interrupted download resumes from its part', () async {
      // Build 2125 (A25-09): the second download() sends a
      // Range for the bytes already on disk and appends
      // only the remainder.
      final bytes = List<int>.generate(4096, (i) => i % 251);
      final half = bytes.length ~/ 2;
      final ranges = <String?>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var served = 0;
      server.listen((request) async {
        served++;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        ranges.add(range);
        if (served == 1) {
          // First attempt: a clean stream of only half
          // the feed's promised size — the download ends
          // incomplete with the part kept.
          request.response.headers.contentLength = half;
          request.response.add(bytes.sublist(0, half));
          await request.response.close();
          return;
        }
        var start = 0;
        if (range != null && range.startsWith('bytes=')) {
          start = int.parse(range.substring(6).split('-').first);
        }
        request.response.statusCode = HttpStatus.partialContent;
        // Build 2126 supersession (A26-24): the updater now
        // verifies a 206 against its Content-Range before
        // appending — a 206 must carry one (RFC 9110), so
        // the fixture sends it, like the real CDN does.
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${bytes.length - 1}/${bytes.length}',
        );
        request.response.headers.contentLength = bytes.length - start;
        request.response.add(bytes.sublist(start));
        await request.response.close();
      });
      final url =
          'http://${server.address.host}:${server.port}/RalysndEmber2.apk';
      final feed = fixture()
        ..['tag_name'] = 'v2099'
        ..['assets'] = [
          {
            'name': 'RalysndEmber2.apk',
            'browser_download_url': url,
            'size': bytes.length,
          },
        ];
      final u = await updaterIn(dir, fetcher: (_) async => jsonEncode(feed));
      u.urlPolicyOverride = (_) => true;
      // Build 2129 (leg 6): the signing-cert check runs through its seam here, like the URL policy above.
      u.certCheckOverride = (_) async => true;
      await u.check(manual: true);
      await u.download();
      expect(u.state, EmberUpdateState.error);
      expect(u.errorText, contains('incomplete'));
      final part =
          File('${dir.path}/updates/RalysndEmber2-v2099.apk.part');
      expect(part.existsSync(), isTrue);
      expect(part.lengthSync(), half);
      await u.download();
      expect(u.state, EmberUpdateState.downloaded);
      expect(ranges.last, 'bytes=$half-');
      final file = File(u.downloadedPath!);
      expect(file.readAsBytesSync(), bytes);
      expect(part.existsSync(), isFalse);
    });

    test('a failed download is a plain sentence', () async {
      final u = await updaterIn(
        dir,
        fetcher: (_) async => jsonEncode(
          fixture()
            ..['tag_name'] = 'v2099'
            ..['assets'] = [
              {
                'name': 'RalysndEmber2.apk',
                // Nothing listens here: the download fails at connect.
                'browser_download_url': 'http://127.0.0.1:1/RalysndEmber2.apk',
                'size': 100,
              },
            ],
        ),
      );
      // The override keeps this test on its original
      // subject — the connect failure — not the A25-49
      // policy refusal.
      u.urlPolicyOverride = (_) => true;
      await u.check(manual: true);
      await u.download();
      expect(u.state, EmberUpdateState.error);
      expect(u.errorText, isNotEmpty);
      expect(u.errorText, isNot(contains('SocketException')));
    });
  });

  group('install()', () {
    test('an installer that cannot open is a plain sentence', () async {
      final u = await updaterIn(dir);
      final apk = File('${dir.path}/RalysndEmber2-v2099.apk')
        ..writeAsBytesSync([0, 1, 2, 3]);
      u.downloadedPath = apk.path;
      u.state = EmberUpdateState.downloaded;
      // No platform handler: the channel call throws, and the
      // updater must turn that into a sentence, not a crash.
      await u.install();
      expect(u.state, EmberUpdateState.error);
      expect(u.errorText, contains('could not open the installer'));
      expect(u.errorText, contains('kept'));
    });

    test('an install the platform refuses (false) is an error too', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('app/android'),
        (MethodCall call) async {
          if (call.method == 'installApk') return false;
          return null;
        },
      );
      final u = await updaterIn(dir);
      final apk = File('${dir.path}/RalysndEmber2-v2099.apk')
        ..writeAsBytesSync([0, 1, 2, 3]);
      u.downloadedPath = apk.path;
      u.state = EmberUpdateState.downloaded;
      await u.install();
      expect(u.state, EmberUpdateState.error);
      expect(u.errorText, contains('could not open the installer'));
    });
  });

  group('wiring pins (build 2075)', () {
    test('runAndroid starts the Ember updater, not the upstream one',
        () {
      final main = dartSrc('main.dart');
      expect(main, contains('EmberUpdater.start(settings, dataDir)'));
      expect(main, contains('The upstream checker stays off'));
    });

    test('the upstream checker still refuses Android', () {
      expect(
        dartSrc('core/updates.dart'),
        contains('if (Platform.isAndroid) return;'),
      );
    });

    test('Settings carries the App updates panel', () {
      final settings = dartSrc('ui/ember/ember_settings.dart');
      expect(settings, contains('const _AppUpdatesPanel()'));
      expect(settings, contains("title: 'App updates'"));
      expect(settings, contains("label: 'Check for updates'"));
      // Build 2125 (A25-09): the label is a ternary now —
      // 'Resume download' while a kept part exists.
      expect(settings, contains("? 'Resume download'"));
      expect(settings, contains(": 'Download (' +"));
      // Build 2092 (item 29): the Install label is guarded —
      // it reads 'Opening…' and disables while the installer
      // intent is in flight. The pin follows the label's new
      // shape; the button and its wiring are unchanged.
      // Build 2125 re-point (A25-48): the non-busy label is
      // itself a ternary on the verification state.
      expect(settings, contains("? 'Opening…'"));
      expect(settings, contains(": 'Install — UNVERIFIED'"));
      expect(settings, contains('AndroidCore.canInstallPackages()'));
      expect(settings, contains('AndroidCore.openInstallSettings()'));
    });

    test('the throttle field rides the settings store', () {
      final models = dartSrc('app_settings.dart');
      expect(models, contains('lastEmberUpdateCheckMs'));
      expect(models, contains("'ember_update_checked_ms'"));
    });

    test('the manifest allows installs and serves the APK', () {
      final manifest = manifestSrc();
      expect(manifest, contains('REQUEST_INSTALL_PACKAGES'));
      expect(manifest, contains('FileProvider'));
      expect(manifest, contains('ember_file_paths'));
      final paths = File(
        'android/app/src/main/res/xml/ember_file_paths.xml',
      ).readAsStringSync();
      expect(paths, contains('files-path'));
      // Build 2095 (third-pass audit 5-8): the provider
      // paths were narrowed to the updates folder only —
      // the cache root (and the whole files root) are no
      // longer exposable; the pin asserts the narrowing.
      // Build 2099 (pin updated, reason named): the folder
      // is core/updates/, not updates/ — the updater writes
      // into <dataDir>/updates and dataDir is files/core,
      // so the 2095 spelling pointed at a folder nothing
      // writes to and install crashed on 2096/2097/2098
      // (owner crash log). The relational pin lives in
      // build2099_test.dart.
      expect(paths, contains('path="core/updates/"'));
      expect(paths.contains('cache-path'), isFalse);
    });

    test('MainActivity hands the APK to the system installer', () {
      final kt = ktSrc('MainActivity.kt');
      expect(kt, contains('"installApk"'));
      expect(kt, contains('"canInstallPackages"'));
      expect(kt, contains('"openInstallSettings"'));
      expect(kt, contains('FileProvider'));
      expect(kt, contains('FLAG_GRANT_READ_URI_PERMISSION'));
      expect(kt, contains('application/vnd.android.package-archive'));
    });
  });

  group('the App updates panel (widget)', () {
    testWidgets('shows the available build and its Download action',
        (tester) async {
      // The setup does real file IO (AppSettings.load, the
      // save inside check) — inside a testWidgets body that
      // IO runs in the FakeAsync zone and never completes,
      // so it runs under runAsync instead. (The test hung
      // the full 10 minutes in the first 2075 suite run
      // before this was understood.)
      final u = await tester.runAsync(() async {
        final created =
            await updaterIn(dir, fetcher: (_) async => fixtureJson());
        await created.check(manual: true);
        return created;
      });
      expect(u, isNotNull);
      expect(u!.state, EmberUpdateState.available);
      EmberUpdater.instance = u;
      await pumpSettings(tester);
      // The settings page is a lazy ListView and the panel
      // sits below the V2Ray section. Drive the scroll
      // position directly (a drag dies on a text field that
      // captures it mid-list), in steps, because the sliver
      // extent estimate shrinks as real panels build. Panel
      // titles render uppercased by MapSettingsPanel.
      final scrollable =
          tester.state<ScrollableState>(find.byType(Scrollable).first);
      // Build 2095 harness repair: the settings list grew
      // (sniffing/budget/chain rows), and the extent
      // estimate now collapses faster than the panel
      // arrives — 3000 px jumps teleported PAST the panel
      // without ever building it. Fine steps build every
      // child on the way down.
      for (var i = 0;
          i < 60 && find.text('APP UPDATES').evaluate().isEmpty;
          i++) {
        final pos = scrollable.position;
        pos.jumpTo((pos.pixels + 500).clamp(0.0, pos.maxScrollExtent));
        await tester.pump();
      }
      expect(find.text('APP UPDATES'), findsOneWidget);
      expect(find.textContaining('Build 2074 is available'), findsOneWidget);
      expect(find.textContaining('Download ('), findsOneWidget);
    });

    testWidgets('hidden entirely where no updater runs', (tester) async {
      EmberUpdater.instance = null;
      await pumpSettings(tester);
      // Panel titles render uppercased (MapSettingsPanel).
      expect(find.text('APP UPDATES'), findsNothing);
    });
  });
}
