// Build 2129 — leg 6 (app-level): updater signing-cert
// verification + path-strict initial URL, and the offline
// GeoIP country tables (delta §6). Pins:
//  A1 the initial-URL path shape (own repo's release asset
//     only) layered over the unchanged host allowlist;
//  A2 the cert-check ORDER (digest → cert → install
//     offered) and the mismatch/unreadable discard, via the
//     certCheckOverride seam AND via the real platform
//     channel answers;
//  A3 the Kotlin handler's shape (archive read, signing
//     flags, both channel methods);
//  B1 the vendored tables' provenance (SHA-256 vs
//     build-info.json) and record counts;
//  B2 boundary lookups on the REAL data (first/last/
//     just-outside, v4 + v6), miss → null;
//  B3 the online-preferred fill rule and the consumer
//     wiring.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/net/geo_country.dart';
import 'package:firefox_vpn/ui/ember/ember_updater.dart';
import 'package:firefox_vpn/xray/exit_info.dart';
import 'package:firefox_vpn/xray/sha256.dart';

String src(String rel) => File(rel).readAsStringSync();

Future<EmberUpdater> updaterIn(
  Directory dir, {
  required Future<String> Function(Uri url) fetcher,
}) async {
  final settings = await AppSettings.load(dir.path);
  return EmberUpdater(settings: settings, dataDir: dir.path, fetcher: fetcher)
    ..packageBuild = 2071;
}

Future<(HttpServer, String)> serveBytes(List<int> bytes) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    req.response.headers.contentLength = bytes.length;
    req.response.add(bytes);
    await req.response.close();
  });
  return (server, 'http://127.0.0.1:${server.port}/RalysndEmber2.apk');
}

Map<String, dynamic> feedFor(String url, int size, String digest) => {
  'tag_name': 'v2099',
  'name': 'Build 2099',
  'body': '',
  'assets': [
    {
      'name': 'RalysndEmber2.apk',
      'browser_download_url': url,
      'size': size,
      'digest': 'sha256:$digest',
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ember2129app_');
    EmberUpdater.instance = null;
    HttpOverrides.global = null;
  });
  tearDown(() {
    EmberUpdater.instance = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), null);
    dir.deleteSync(recursive: true);
  });

  group('A1 — path-strict initial URL', () {
    test('the repo\'s own release-asset URL is admitted', () {
      expect(
        emberUpdateInitialUrlAllowed(
          'https://github.com/Mojdee12/ralysnd-ember/releases/download/'
          'v2129/RalysndEmber2.apk',
        ),
        isTrue,
      );
    });

    test('other repos, other files and other paths are refused', () {
      expect(
        emberUpdateInitialUrlAllowed(
          'https://github.com/SomeoneElse/ralysnd-ember/releases/download/'
          'v2129/RalysndEmber2.apk',
        ),
        isFalse,
      );
      expect(
        emberUpdateInitialUrlAllowed(
          'https://github.com/Mojdee12/ralysnd-ember/releases/download/'
          'v2129/OtherApp.apk',
        ),
        isFalse,
      );
      expect(
        emberUpdateInitialUrlAllowed('https://github.com/a/b.apk'),
        isFalse,
      );
      expect(
        emberUpdateInitialUrlAllowed(
          'http://github.com/Mojdee12/ralysnd-ember/releases/download/'
          'v2129/RalysndEmber2.apk',
        ),
        isFalse,
      );
    });

    test('the host allowlist itself is unchanged (hops stay host-only)', () {
      // The 2125 pin stands: emberUpdateUrlAllowed is the
      // per-hop policy and still admits any github.com path;
      // the path rule lives only in the initial check,
      // because redirect targets are signed CDN URLs.
      expect(emberUpdateUrlAllowed('https://github.com/a/b.apk'), isTrue);
      expect(
        emberUpdateInitialUrlAllowed(
          'https://release-assets.githubusercontent.com/some/signed/path',
        ),
        isTrue,
        reason: 'non-github.com hosts keep the host-only rule',
      );
    });
  });

  group('A2 — signing-cert verification', () {
    test('digest pass + cert match offers the download', () async {
      final bytes = List<int>.generate(4096, (i) => i % 251);
      final (server, url) = await serveBytes(bytes);
      addTearDown(() => server.close(force: true));
      final u = await updaterIn(
        dir,
        fetcher: (_) async =>
            jsonEncode(feedFor(url, bytes.length, sha256Hex(bytes))),
      );
      u.urlPolicyOverride = (_) => true;
      var certCalls = 0;
      u.certCheckOverride = (_) async {
        certCalls++;
        return true;
      };
      await u.check(manual: true);
      await u.download();
      expect(u.state, EmberUpdateState.downloaded);
      expect(certCalls, 1);
      expect(File(u.downloadedPath!).existsSync(), isTrue);
    });

    test('digest pass + cert MISMATCH discards, never offers', () async {
      final bytes = List<int>.generate(4096, (i) => i % 251);
      final (server, url) = await serveBytes(bytes);
      addTearDown(() => server.close(force: true));
      final u = await updaterIn(
        dir,
        fetcher: (_) async =>
            jsonEncode(feedFor(url, bytes.length, sha256Hex(bytes))),
      );
      u.urlPolicyOverride = (_) => true;
      u.certCheckOverride = (_) async => false;
      await u.check(manual: true);
      await u.download();
      expect(u.state, EmberUpdateState.error);
      expect(u.errorText, contains('release key'));
      expect(u.downloadedPath, isNull);
      // Neither the finished file nor the part survives.
      expect(
        File('${dir.path}/updates/RalysndEmber2-v2099.apk').existsSync(),
        isFalse,
      );
      expect(
        File('${dir.path}/updates/RalysndEmber2-v2099.apk.part').existsSync(),
        isFalse,
      );
    });

    test('digest mismatch is refused BEFORE the cert check runs', () async {
      final bytes = List<int>.generate(4096, (i) => i % 251);
      final (server, url) = await serveBytes(bytes);
      addTearDown(() => server.close(force: true));
      final u = await updaterIn(
        dir,
        fetcher: (_) async => jsonEncode(
          feedFor(url, bytes.length, sha256Hex([1, 2, 3])),
        ),
      );
      u.urlPolicyOverride = (_) => true;
      var certCalls = 0;
      u.certCheckOverride = (_) async {
        certCalls++;
        return true;
      };
      await u.check(manual: true);
      await u.download();
      expect(u.state, EmberUpdateState.error);
      expect(u.errorText, contains('checksum'));
      expect(certCalls, 0, reason: 'ordering: digest first, cert second');
    });

    test('the real platform path: differing cert hashes discard', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'), (
            call,
          ) async {
            if (call.method == 'ownSigningCertSha256') return 'aabbcc';
            if (call.method == 'apkSigningCertSha256') return 'ddeeff';
            return null;
          });
      final bytes = List<int>.generate(2048, (i) => i % 251);
      final (server, url) = await serveBytes(bytes);
      addTearDown(() => server.close(force: true));
      final u = await updaterIn(
        dir,
        fetcher: (_) async =>
            jsonEncode(feedFor(url, bytes.length, sha256Hex(bytes))),
      );
      u.urlPolicyOverride = (_) => true;
      await u.check(manual: true);
      await u.download();
      expect(u.state, EmberUpdateState.error);
      expect(u.errorText, contains('release key'));
      expect(u.downloadedPath, isNull);
    });

    test('the real platform path: equal hashes (any case) offer', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'), (
            call,
          ) async {
            if (call.method == 'ownSigningCertSha256') return 'AABBCC';
            if (call.method == 'apkSigningCertSha256') return 'aabbcc';
            return null;
          });
      final bytes = List<int>.generate(2048, (i) => i % 251);
      final (server, url) = await serveBytes(bytes);
      addTearDown(() => server.close(force: true));
      final u = await updaterIn(
        dir,
        fetcher: (_) async =>
            jsonEncode(feedFor(url, bytes.length, sha256Hex(bytes))),
      );
      u.urlPolicyOverride = (_) => true;
      await u.check(manual: true);
      await u.download();
      expect(u.state, EmberUpdateState.downloaded);
    });

    test('the real platform path: an unreadable cert discards', () async {
      // No channel handler at all: both cert calls answer
      // null, which the updater must treat as "cannot
      // verify" — a refusal, never a pass.
      final bytes = List<int>.generate(2048, (i) => i % 251);
      final (server, url) = await serveBytes(bytes);
      addTearDown(() => server.close(force: true));
      final u = await updaterIn(
        dir,
        fetcher: (_) async =>
            jsonEncode(feedFor(url, bytes.length, sha256Hex(bytes))),
      );
      u.urlPolicyOverride = (_) => true;
      await u.check(manual: true);
      await u.download();
      expect(u.state, EmberUpdateState.error);
      expect(u.downloadedPath, isNull);
    });
  });

  group('A3 — Kotlin handler shape', () {
    final kt = src(
      'android/app/src/main/kotlin/com/ralysnd/ember/MainActivity.kt',
    );

    test('both channel methods exist', () {
      expect(kt, contains('"apkSigningCertSha256"'));
      expect(kt, contains('"ownSigningCertSha256"'));
    });

    test('the archive is read, not installed, with signing flags', () {
      expect(kt, contains('getPackageArchiveInfo'));
      expect(kt, contains('GET_SIGNING_CERTIFICATES'));
      expect(kt, contains('apkContentsSigners'));
    });

    test('the Dart ordering pin: cert check after the digest check', () {
      final dart = src('lib/ui/ember/ember_updater.dart');
      final digestAt = dart.indexOf('checksum the feed published');
      final certAt = dart.indexOf('_signingCertMatches(part.path)');
      expect(digestAt, greaterThan(0));
      expect(certAt, greaterThan(digestAt));
    });
  });

  group('B — offline GeoIP', () {
    final v4Bytes = File('assets/geoip/countries-v4.bin').readAsBytesSync();
    final v6Bytes = File('assets/geoip/countries-v6.bin').readAsBytesSync();
    final db = GeoCountryDb.tryParse(v4: v4Bytes, v6: v6Bytes)!;

    test('B1: provenance — file hashes match build-info.json', () {
      final info =
          jsonDecode(File('assets/geoip/build-info.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(sha256Hex(v4Bytes), (info['ipv4'] as Map)['sha256']);
      expect(sha256Hex(v6Bytes), (info['ipv6'] as Map)['sha256']);
      expect(db.v4Ranges, (info['ipv4'] as Map)['normalized_ranges']);
      expect(db.v6Ranges, (info['ipv6'] as Map)['normalized_ranges']);
      expect(db.v4Ranges, 362108);
      expect(db.v6Ranges, 348691);
    });

    test('B2: v4 boundary lookups on the real data', () {
      // First range: 1.0.0.0–1.0.0.255 AU.
      expect(db.lookup('1.0.0.0'), 'AU');
      expect(db.lookup('1.0.0.255'), 'AU');
      expect(db.lookup('0.255.255.255'), isNull, reason: 'just below');
      // Second range starts immediately after: CN.
      expect(db.lookup('1.0.1.0'), 'CN');
      expect(db.lookup('1.0.3.255'), 'CN');
      // A mid-table range: 130.176.114.0–130.176.117.255 US.
      expect(db.lookup('130.176.114.0'), 'US');
      expect(db.lookup('130.176.117.255'), 'US');
      // Last range: 223.255.255.0–223.255.255.255 AU.
      expect(db.lookup('223.255.255.255'), 'AU');
      expect(db.lookup('224.0.0.0'), isNull, reason: 'just above the end');
    });

    test('B2: v6 boundary lookups on the real data', () {
      // First range: 2000::–2000:ffff:…:ffff CH.
      expect(db.lookup('2000::'), 'CH');
      expect(
        db.lookup('2000:ffff:ffff:ffff:ffff:ffff:ffff:ffff'),
        'CH',
      );
      expect(db.lookup('::1'), isNull, reason: 'below the first range');
      // Second range: 2001:200:: JP.
      expect(db.lookup('2001:200::'), 'JP');
      // Last range: fec0::–feff:ffff:…:ffff CH.
      expect(db.lookup('fec0::'), 'CH');
      expect(
        db.lookup('feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff'),
        'CH',
      );
      expect(db.lookup('ff00::'), isNull, reason: 'above the last range');
    });

    test('B2: junk input and corrupt tables answer null', () {
      expect(db.lookup('not-an-ip'), isNull);
      expect(db.lookup(''), isNull);
      expect(GeoCountryDb.tryParse(v4: v4Bytes.sublist(0, 100)), isNull);
      final badMagic = [...v4Bytes];
      badMagic[0] = 0;
      expect(
        GeoCountryDb.tryParse(v4: Uint8List.fromList(badMagic)),
        isNull,
      );
    });

    test('B3: the online answer is preferred, verbatim', () {
      const online = ExitInfo(ip: '1.0.0.0', countryCode: 'DE', countryEn: 'Germany');
      final filled = fillCountryOffline(online, (_) => 'AU');
      expect(filled.countryCode, 'DE');
      expect(identical(filled, online), isTrue);
    });

    test('B3: a missing country is filled; a miss changes nothing', () {
      const bare = ExitInfo(ip: '1.0.0.0', countryCode: '', countryEn: '');
      expect(fillCountryOffline(bare, db.lookup).countryCode, 'AU');
      expect(
        identical(fillCountryOffline(bare, (_) => null), bare),
        isTrue,
      );
      const noIp = ExitInfo(ip: '', countryCode: '', countryEn: '');
      expect(identical(fillCountryOffline(noIp, db.lookup), noIp), isTrue);
    });

    test('B3: consumer wiring + asset + credit pins', () {
      expect(
        src('lib/xray/xray_controller.dart'),
        contains('exitInfoWithOfflineCountry'),
      );
      expect(
        src('lib/psiphon/psiphon_controller.dart'),
        contains('exitInfoWithOfflineCountry'),
      );
      expect(
        src('lib/net/exit_quality.dart'),
        contains('GeoCountry.lookupCountryCode'),
      );
      expect(src('pubspec.yaml'), contains('assets/geoip/'));
      final licences = src('lib/ui/ember/licenses_page.dart');
      expect(licences, contains('CC BY-SA 4.0'));
      expect(licences, contains('v2fly/geoip'));
    });
  });
}
