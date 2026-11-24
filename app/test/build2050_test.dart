/// Build 2050 gates, host side: the owner's four tasks plus
/// audit C-1, each pinned where it is host-provable.
///
/// 1. Subscription add (audit C-2/C-3, F-H11/F-H12/F-H13):
///    the fetcher distinguishes failure classes and surfaces
///    specific messages; a self-signed panel certificate is
///    rejected WITH its SHA-256 fingerprint, and accepted
///    when that exact fingerprint is pinned for that
///    subscription; Clash/sing-box bodies are named, not
///    "no profiles"; HWID/custom headers ride; a fallback
///    URL serves when the primary fails; custom DNS hosts
///    (build 2041) steer the dial.
/// 2. File import: the WireGuard .conf parse contract the
///    new pickers feed (incl. AmneziaWG preservation), and
///    source pins for the native picker plumbing.
/// 3. Battery: the poll-policy schedule (audit B-H1..B-H4,
///    B-M1) and the XrayTester one-process stats pin.
/// 4. Fallback collapsed + V2Ray appearance: source pins for
///    the collapsed-by-default card and the action bar.
/// 5. AmneziaWG (audit C-1): the UAPI key contract — keys
///    reach amneziawg-go as 64-char lowercase hex decoding
///    to exactly 32 bytes, never as base64.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/core/poll_policy.dart';
import 'package:firefox_vpn/xray/sha256.dart';
import 'package:firefox_vpn/xray/sub_fetcher.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

const _vlessLink =
    'vless://11111111-1111-1111-1111-111111111111@node.example.com:443'
    '?encryption=none&security=tls&type=ws#Node%20One';

/// The self-signed fixture's DER SHA-256 (openssl, verified
/// when the fixture was generated 2026-11-14).
const _fixtureCertSha256 =
    'e28007a7486566f9ef1e409e7d1cdc73a279cebb22b0928aeb068289955f41f5';

Future<HttpServer> _serve(
  void Function(HttpRequest) handler, {
  bool secure = false,
}) async {
  final HttpServer server;
  if (secure) {
    final ctx = SecurityContext()
      ..useCertificateChain('test/fixtures/sub_tls_cert.pem')
      ..usePrivateKey('test/fixtures/sub_tls_key.pem');
    server = await HttpServer.bindSecure('127.0.0.1', 0, ctx);
  } else {
    server = await HttpServer.bind('127.0.0.1', 0);
  }
  server.listen((req) {
    handler(req);
    req.response.close();
  });
  return server;
}

void _respond(HttpRequest req, String body, {int status = 200}) {
  req.response.statusCode = status;
  req.response.write(body);
}

void main() {
  group('SHA-256 (subscription certificate pins)', () {
    test('FIPS vectors', () {
      expect(
        sha256Hex(const []),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        sha256Hex(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        sha256Hex(
          utf8.encode(
            'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
          ),
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('the fixture certificate hashes to its openssl fingerprint', () {
      // Rebuild the DER from the PEM and hash it with the
      // app's own implementation — the same bytes the fetcher
      // hashes off a presented certificate.
      final pem = File('test/fixtures/sub_tls_cert.pem').readAsStringSync();
      final b64 = pem
          .replaceAll('-----BEGIN CERTIFICATE-----', '')
          .replaceAll('-----END CERTIFICATE-----', '')
          .replaceAll(RegExp(r'\s'), '');
      expect(sha256Hex(base64Decode(b64)), _fixtureCertSha256);
    });
  });

  // Build 2104: the C-1 subject — keys hexed for the old
  // bridge's IpcSet parser — is deleted with that bridge.
  // The hand-off is the canonical .conf text now, and the
  // WG Tunnel parser takes the keys in their stored base64
  // form; the property worth pinning is that the serializer
  // carries them VERBATIM (no re-encoding can corrupt a key
  // on its way to the engine) alongside the AWG parameters.
  // A malformed key is rejected by the Kotlin parser at
  // start, surfaced as the engine's problem string — the
  // native half of the old "throws instead of reaching
  // IpcSet" property, proven on device.
  group('AmneziaWG hand-off keys (audit C-1, build 2104 form)', () {
    const zeros = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
    const ones = 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=';

    test('wgConfFromProfile carries the keys verbatim in base64', () {
      final p = Profile(
        id: 'awg',
        protocol: Protocol.wireguard,
        name: 'awg',
        address: '203.0.113.7',
        port: 51820,
        secretKey: ones,
        peerPublicKey: zeros,
        preSharedKey: ones,
        localAddress: '10.0.0.2/32',
        awgJc: '5',
        awgJmin: '40',
        awgJmax: '70',
        awgS1: '15',
        awgS2: '18',
        awgH1: '123456789',
      );
      final conf = wgConfFromProfile(p);
      expect(conf, contains('PrivateKey = $ones'));
      expect(conf, contains('PublicKey = $zeros'));
      expect(conf, contains('PresharedKey = $ones'));
      expect(conf, contains('Jc = 5'));
      expect(conf, contains('Jmin = 40'));
      expect(conf, contains('H1 = 123456789'));
    });
  });

  group('Subscription body formats (audit F-H12)', () {
    test('detection names each shape', () {
      expect(detectSubBodyFormat(''), SubBodyFormat.empty);
      expect(
        detectSubBodyFormat('<html><body>x</body></html>'),
        SubBodyFormat.html,
      );
      expect(
        detectSubBodyFormat('proxies:\n  - name: a\n    type: vless\n'),
        SubBodyFormat.clash,
      );
      expect(
        detectSubBodyFormat('{"outbounds":[{"type":"vless"}]}'),
        SubBodyFormat.singBox,
      );
      expect(
        detectSubBodyFormat('{"foo":1}'),
        SubBodyFormat.jsonUnknown,
      );
      expect(detectSubBodyFormat(_vlessLink), SubBodyFormat.unknown);
    });

    test('empty-body words name Clash and sing-box, never "no profiles"',
        () {
      expect(emptyBodyMessage(SubBodyFormat.clash), contains('Clash'));
      expect(emptyBodyMessage(SubBodyFormat.singBox), contains('sing-box'));
      expect(
        emptyBodyMessage(SubBodyFormat.clash),
        isNot(contains('no profiles')),
      );
    });
  });

  group('Subscription error classification (audit C-2)', () {
    test('each failure class maps to its kind', () {
      expect(
        classifyFetchError(
          const SocketException('Failed host lookup: panel.example'),
          host: 'panel.example',
        ).kind,
        SubFetchErrorKind.dns,
      );
      expect(
        classifyFetchError(
          const SocketException('Connection refused'),
          host: 'panel.example',
        ).kind,
        SubFetchErrorKind.network,
      );
      expect(
        classifyFetchError(TimeoutException('slow'), host: 'panel.example').kind,
        SubFetchErrorKind.timeout,
      );
      expect(
        classifyFetchError(
          const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
          host: 'panel.example',
        ).kind,
        SubFetchErrorKind.certificate,
      );
    });

    test('every classified failure carries its own specific words', () {
      final messages = {
        classifyFetchError(
          const SocketException('Failed host lookup: panel.example'),
          host: 'panel.example',
        ).message,
        classifyFetchError(
          const SocketException('Connection refused'),
          host: 'panel.example',
        ).message,
        classifyFetchError(TimeoutException('slow'), host: 'panel.example').message,
        classifyFetchError(
          const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
          host: 'panel.example',
        ).message,
      };
      expect(messages, hasLength(4));
      expect(messages.every((m) => m.isNotEmpty), isTrue);
    });
  });

  group('Subscription fetch, live on loopback', () {
    test('base64 body parses to profiles', () async {
      final server = await _serve((req) {
        _respond(req, base64Encode(utf8.encode(_vlessLink)));
      });
      addTearDown(server.close);
      final r = await fetchSubscription(
        'http://127.0.0.1:${server.port}/sub',
      );
      expect(r.profiles, hasLength(1));
      expect(r.profiles.single.address, 'node.example.com');
    });

    test('plain body parses; panel headers give name and totals', () async {
      final server = await _serve((req) {
        req.response.headers.set(
          'subscription-userinfo',
          'upload=1024; download=2048; total=107374182400; expire=1893456000',
        );
        req.response.headers.set('profile-title', 'Panel Sub');
        _respond(req, _vlessLink);
      });
      addTearDown(server.close);
      final r = await fetchSubscription(
        'http://127.0.0.1:${server.port}/sub',
      );
      expect(r.profiles, hasLength(1));
      expect(r.suggestedName, 'Panel Sub');
      expect(r.totalBytes, 107374182400);
      expect(r.uploadBytes + r.downloadBytes, 3072);
    });

    test('HTTP 403 surfaces as its own kind with the status', () async {
      final server = await _serve((req) => _respond(req, 'no', status: 403));
      addTearDown(server.close);
      await expectLater(
        fetchSubscription('http://127.0.0.1:${server.port}/sub'),
        throwsA(
          isA<SubFetchException>()
              .having((e) => e.kind, 'kind', SubFetchErrorKind.http)
              .having((e) => e.statusCode, 'status', 403),
        ),
      );
    });

    test('a Clash body is a format error naming Clash', () async {
      final server = await _serve((req) {
        _respond(req, 'proxies:\n  - name: a\n    type: vless\n');
      });
      addTearDown(server.close);
      await expectLater(
        fetchSubscription('http://127.0.0.1:${server.port}/clash'),
        throwsA(
          isA<SubFetchException>()
              .having((e) => e.kind, 'kind', SubFetchErrorKind.format)
              .having((e) => e.message, 'message', contains('Clash')),
        ),
      );
    });

    test('an HTML body is a format error, not "no profiles"', () async {
      final server = await _serve((req) {
        _respond(req, '<html><body>login</body></html>');
      });
      addTearDown(server.close);
      await expectLater(
        fetchSubscription('http://127.0.0.1:${server.port}/sub'),
        throwsA(
          isA<SubFetchException>().having(
            (e) => e.message,
            'message',
            contains('web page'),
          ),
        ),
      );
    });

    test('HWID and custom headers ride; the app UA cannot be overridden',
        () async {
      HttpHeaders? seen;
      final server = await _serve((req) {
        seen = req.headers;
        _respond(req, _vlessLink);
      });
      addTearDown(server.close);
      await fetchSubscription(
        'http://127.0.0.1:${server.port}/sub',
        hwid: 'device-123',
        headers: {'x-custom': 'yes', 'user-agent': 'Fake/1.0'},
      );
      expect(seen!.value('x-hwid'), 'device-123');
      expect(seen!.value('x-custom'), 'yes');
      expect(seen!.value('user-agent'), contains('RalysndEmber'));
    });

    test('the fallback URL serves when the primary refuses', () async {
      final dead = await _serve((_) {});
      final deadPort = dead.port;
      await dead.close(force: true);
      final good = await _serve((req) => _respond(req, _vlessLink));
      addTearDown(good.close);
      final r = await fetchSubscription(
        'http://127.0.0.1:$deadPort/sub',
        fallbackUrl: 'http://127.0.0.1:${good.port}/sub',
      );
      expect(r.usedFallback, isTrue);
      expect(r.profiles, hasLength(1));
    });

    test('custom DNS hosts steer the dial (build 2041 settings)', () async {
      final server = await _serve((req) => _respond(req, _vlessLink));
      addTearDown(server.close);
      final r = await fetchSubscription(
        'http://ember.test:${server.port}/sub',
        hosts: {'ember.test': '127.0.0.1'},
      );
      expect(r.profiles, hasLength(1));
    });

    test('invalid URLs are rejected before any socket', () async {
      await expectLater(
        fetchSubscription('ftp://example.com/sub'),
        throwsA(
          isA<SubFetchException>().having(
            (e) => e.kind,
            'kind',
            SubFetchErrorKind.invalidUrl,
          ),
        ),
      );
      await expectLater(
        fetchSubscription('not a url'),
        throwsA(isA<SubFetchException>()),
      );
    });
  });

  group('Subscription TLS (audit C-3)', () {
    test('a self-signed panel cert fails WITH its fingerprint; the pin '
        'for that subscription then lets it through', () async {
      final server = await _serve(
        (req) => _respond(req, _vlessLink),
        secure: true,
      );
      addTearDown(server.close);
      final url = 'https://127.0.0.1:${server.port}/sub';

      await expectLater(
        fetchSubscription(url),
        throwsA(
          isA<SubFetchException>()
              .having((e) => e.kind, 'kind', SubFetchErrorKind.certificate)
              .having((e) => e.certSha256, 'fingerprint', _fixtureCertSha256),
        ),
      );

      final r = await fetchSubscription(url, certPin: _fixtureCertSha256);
      expect(r.profiles, hasLength(1));

      await expectLater(
        fetchSubscription(url, certPin: 'f' * 64),
        throwsA(
          isA<SubFetchException>().having(
            (e) => e.kind,
            'kind',
            SubFetchErrorKind.certificate,
          ),
        ),
      );
    });
  });

  group('Subscription add flow through the controller seam (F-M20)', () {
    Profile fakeProfile() => Profile(
          id: 'fake1',
          protocol: Protocol.vless,
          name: 'Fake Node',
          address: 'node.example.com',
          port: 443,
          uuidOrPassword: '11111111-1111-1111-1111-111111111111',
        );

    test('a good fetch persists the subscription and its profiles',
        () async {
      final c = XrayController();
      c.subscriptionFetcher = (url,
              {certPin = '',
              hwid = '',
              headers = const {},
              fallbackUrl = '',
              hosts = const {}}) async =>
          SubResult(profiles: [fakeProfile()], suggestedName: 'Panel');
      final sub = await c.addSubscription('https://panel.example/sub/abc');
      expect(sub.name, 'Panel');
      expect(c.subscriptions, hasLength(1));
      expect(c.profilesOf(sub), hasLength(1));
    });

    test('a failed fetch surfaces the typed error and stores nothing',
        () async {
      final c = XrayController();
      c.subscriptionFetcher = (url,
              {certPin = '',
              hwid = '',
              headers = const {},
              fallbackUrl = '',
              hosts = const {}}) async =>
          throw const SubFetchException(
            kind: SubFetchErrorKind.http,
            message: 'The server answered HTTP 403.',
            statusCode: 403,
          );
      await expectLater(
        c.addSubscription('https://panel.example/sub/abc'),
        throwsA(
          isA<SubFetchException>().having(
            (e) => e.message,
            'message',
            contains('403'),
          ),
        ),
      );
      expect(c.subscriptions, isEmpty);
      expect(c.profiles, isEmpty);
    });

    test('the model round-trips the new fields', () {
      final sub = Subscription(
        id: 's1',
        name: 'S',
        url: 'https://x/sub',
        certPin: 'ab' * 32,
        hwid: 'dev',
        fallbackUrl: 'https://y/sub',
      );
      final back = Subscription.fromJson(sub.toJson());
      expect(back.certPin, 'ab' * 32);
      expect(back.hwid, 'dev');
      expect(back.fallbackUrl, 'https://y/sub');
      // A 2049-era record (no new keys) still loads, defaults empty.
      final legacy = Subscription.fromJson({
        'id': 's0',
        'name': 'Old',
        'url': 'https://x/sub',
      });
      expect(legacy.certPin, '');
      expect(legacy.hwid, '');
      expect(legacy.fallbackUrl, '');
    });
  });

  group('WireGuard .conf import contract (Task 2)', () {
    var n = 0;
    String nextId() => 'wg${n++}';

    test('a plain config parses to one selectable profile', () {
      final r = parseWgConf(
        '[Interface]\n'
        'PrivateKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\n'
        'Address = 10.0.0.2/32\n'
        'DNS = 1.1.1.1\n'
        '\n'
        '[Peer]\n'
        'PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
        'Endpoint = 203.0.113.7:51820\n'
        'AllowedIPs = 0.0.0.0/0\n',
        baseName: 'office',
        idFor: nextId,
      );
      expect(r.ok, isTrue);
      expect(r.amnezia, isFalse);
      expect(r.profiles.single.address, '203.0.113.7');
    });

    test('AmneziaWG parameters survive the parse (build 2040)', () {
      final r = parseWgConf(
        '[Interface]\n'
        'PrivateKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\n'
        'Address = 10.0.0.2/32\n'
        'Jc = 5\nJmin = 40\nJmax = 70\nS1 = 15\nS2 = 18\nH1 = 123456789\n'
        '\n'
        '[Peer]\n'
        'PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
        'Endpoint = 203.0.113.7:51820\n'
        'AllowedIPs = 0.0.0.0/0\n',
        baseName: 'awg',
        idFor: nextId,
      );
      expect(r.ok, isTrue);
      expect(r.amnezia, isTrue);
      expect(r.profiles.single.awgJc, '5');
      expect(r.profiles.single.hasAmneziaParams, isTrue);
    });

    test('a non-config file is a clear error, not silence', () {
      final r = parseWgConf(
        'just some text\nwith no sections\n',
        baseName: 'junk',
        idFor: nextId,
      );
      expect(r.ok, isFalse);
      expect(r.error, isNotEmpty);
    });
  });

  group('Poll policy (Task 3, audit B-H1..B-H4)', () {
    test('engine pollers: 2 s foreground, 30 s background', () {
      expect(enginePollPeriod(foreground: true), const Duration(seconds: 2));
      expect(enginePollPeriod(foreground: false), const Duration(seconds: 30));
    });

    test('the Mozilla core poll is 2 s only when foreground and active', () {
      expect(
        corePollPeriod(foreground: true, active: true),
        const Duration(seconds: 2),
      );
      expect(
        corePollPeriod(foreground: true, active: false),
        const Duration(seconds: 30),
      );
      expect(
        corePollPeriod(foreground: false, active: true),
        const Duration(seconds: 30),
      );
      expect(
        corePollPeriod(foreground: false, active: false),
        const Duration(seconds: 30),
      );
    });

    test('exit-IP retries back off 5, 15, 45, then hold at 120 s', () {
      expect(exitRetryDelay(0), const Duration(seconds: 5));
      expect(exitRetryDelay(1), const Duration(seconds: 5));
      expect(exitRetryDelay(2), const Duration(seconds: 15));
      expect(exitRetryDelay(3), const Duration(seconds: 45));
      expect(exitRetryDelay(4), const Duration(seconds: 120));
      expect(exitRetryDelay(9), const Duration(seconds: 120));
    });
  });

  group('Source pins: pickers, stats, fallback, action bar', () {
    String read(String path) => File(path).readAsStringSync();

    test('the native side has the generalized text picker', () {
      final kt = read(
        'android/app/src/main/kotlin/com/ralysnd/ember/MainActivity.kt',
      );
      expect(kt, contains('pickTextFile'));
      expect(kt, contains('PICK_TEXT_REQUEST'));
      expect(kt, contains('file-too-large'));
    });

    test('stats try one statsquery process before the counter() fallback',
        () {
      final kt = read(
        'android/app/src/main/kotlin/com/ralysnd/ember/XrayTester.kt',
      );
      final body = kt.substring(kt.indexOf('fun trafficStats'));
      // Build 2095 (third-pass audit 6-1) changed the
      // contract: the combined call reports whether it
      // RAN, and the two-process fallback runs only when
      // it did not — the pin follows the new shape.
      expect(body, contains('val (both, ranOk) = statsQueryBoth(context, apiPort)'));
      expect(
        body.indexOf('statsQueryBoth(context, apiPort)'),
        lessThan(body.indexOf('counter(context, apiPort')),
      );
      expect(body, contains('if (ranOk) return null'));
      expect(kt, contains('"statsquery"'));
    });

    test('the WireGuard and OpenVPN pages expose file import', () {
      final wg = read('lib/ui/ember/wireguard_pages.dart');
      expect(wg, contains('importWgConfFile'));
      expect(wg, contains('Import file'));
      final ovpn = read('lib/ui/ember/openvpn_pages.dart');
      expect(ovpn, contains('importOpenVpnFile'));
      expect(ovpn, contains('Your own profiles'));
    });

    test('the fallback card starts collapsed; the action bar is segmented',
        () {
      final servers = read('lib/ui/ember/ember_servers.dart');
      expect(servers, contains('bool _open = false'));
      // Build 2133 supersedes the action-bar half of this
      // pin: the owner ordered the Test All action bar off
      // the V2Ray tab (per-subscription ping instead), so
      // the cell class is gone by design.
      expect(servers, isNot(contains('_ActionCell')));
      expect(servers, contains('_PingPill'));
    });

    test('the AWG fallback is surfaced, never silent (audit C-1)', () {
      final c = read('lib/xray/xray_controller.dart');
      expect(c, contains('awgFallbackNotice'));
      final wg = read('lib/ui/ember/wireguard_pages.dart');
      expect(wg, contains('running plain WireGuard'));
    });
  });
}
