// Build 2097 — regression/behavioural coverage for the
// WireGuard/OpenVPN import fix (IMP-1/2/3) and the
// post-2096 audit's 43 findings. Behavioural wherever the
// surface allows (real functions, mocked channels); the
// two shell/page-private surfaces (C-L13, C-L14) use the
// standing source-pin exception, as in earlier batches.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/atomic_json_store.dart';
import 'package:firefox_vpn/core/system_ui_flight.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/ui/ember/ember_shell.dart';
import 'package:firefox_vpn/ui/ember/ember_updater.dart';
import 'package:firefox_vpn/ui/ember/emergency.dart';
import 'package:firefox_vpn/ui/ember/pairing.dart';
import 'package:firefox_vpn/ui/ember/wireguard_pages.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_validation.dart';
import 'package:firefox_vpn/xray/shared_link.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

const _wgConf = '''
[Interface]
PrivateKey = YAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 10.8.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0
''';

const _ovpn = '''
client
dev tun
proto udp
remote vpn.example.com 1194
<ca>
-----BEGIN CERTIFICATE-----
abcd
-----END CERTIFICATE-----
</ca>
''';

void _mockAndroid(Map<String, Object? Function(MethodCall)> handlers) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('app/android'),
          (call) async {
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

  group('IMP-1 — a system-UI flight never re-locks', () {
    test('relockDue honours the flight flag at any age', () {
      final t0 = DateTime(2026, 11, 17, 12);
      expect(
        relockDue(
          backgroundedAt: t0,
          resumedAt: t0.add(const Duration(minutes: 10)),
          systemUiFlight: true,
        ),
        isFalse,
        reason: 'a slow file pick must not re-lock the app '
            'and dispose the importing page',
      );
      expect(
        relockDue(
          backgroundedAt: t0,
          resumedAt: t0.add(const Duration(minutes: 10)),
        ),
        isTrue,
        reason: 'an ordinary backgrounding still re-locks',
      );
      expect(
        relockDue(
          backgroundedAt: t0,
          resumedAt: t0.add(const Duration(seconds: 10)),
        ),
        isFalse,
      );
    });

    test('SystemUiFlight counts nested flights', () {
      expect(SystemUiFlight.inFlight, isFalse);
      SystemUiFlight.begin();
      SystemUiFlight.begin();
      SystemUiFlight.end();
      expect(SystemUiFlight.inFlight, isTrue);
      SystemUiFlight.end();
      expect(SystemUiFlight.inFlight, isFalse);
      SystemUiFlight.end();
      expect(SystemUiFlight.inFlight, isFalse,
          reason: 'an unbalanced end never goes negative');
    });
  });

  group('IMP-3 — a missing picker handler is a failed pick', () {
    test('pickTextFile converts MissingPluginException', () async {
      // No mock handler at all: the channel call raises
      // MissingPluginException, which must surface as the
      // named PlatformException the pages turn into the
      // "could not read that file" message — never as a
      // silent null (cancelled pick).
      await expectLater(
        XrayPlatform.pickTextFile(),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'pick_unavailable')),
      );
      expect(SystemUiFlight.inFlight, isFalse,
          reason: 'the flight bracket closes even on failure');
    });
  });

  group('IMP-2 — WireGuard add completes without a page', () {
    test('addWgConfText lands the profile in the store', () async {
      _mockAndroid({});
      final c = XrayController();
      addTearDown(c.dispose);
      final r = await addWgConfText(c, _wgConf, 'picked-name');
      expect(r.ok, isTrue, reason: r.error);
      expect(c.profiles, hasLength(1));
      expect(c.profiles.single.protocol, Protocol.wireguard);
      expect(c.profiles.single.name, 'picked-name');
      expect(wgProfilesOf(c), hasLength(1),
          reason: 'the profile is visible to the WG section');
    });

    test('a bad conf adds nothing and says why', () async {
      _mockAndroid({});
      final c = XrayController();
      addTearDown(c.dispose);
      final r = await addWgConfText(c, 'not a conf at all', 'x');
      expect(r.ok, isFalse);
      expect(r.error, isNotEmpty);
      expect(c.profiles, isEmpty);
    });
  });

  group('IMP-2/C-L12 — OpenVPN import + store protection', () {
    test('import lands the profile; a validator channel '
        'failure is a named core rejection', () async {
      final tmp = await Directory.systemTemp.createTemp('ember2097');
      addTearDown(() => tmp.delete(recursive: true));
      var validateThrows = false;
      _mockAndroid({
        'dataDir': (_) => '${tmp.path}/files',
        'openVpnValidate': (_) {
          if (validateThrows) {
            throw PlatformException(code: 'boom');
          }
          return '';
        },
      });
      final c = OpenVpnController();
      addTearDown(c.dispose);
      await c.load();
      final p = await c.importProfile('Mine', _ovpn);
      expect(p.name, 'Mine');
      expect(c.userProfiles, hasLength(1),
          reason: 'the imported profile is in the store '
              'the list renders');
      validateThrows = true;
      await expectLater(
        // A different config body: the identical one is
        // (correctly) deduped before validation.
        c.importProfile(
            'Two', _ovpn.replaceAll('vpn.example.com', 'other.example.com')),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('core-rejected:'))),
        reason: 'a dead validator must not escape as a raw '
            'channel error or die silently',
      );
    });

    test('a wrong-shape store file surfaces and is never '
        'overwritten', () async {
      final tmp = await Directory.systemTemp.createTemp('ember2097');
      addTearDown(() => tmp.delete(recursive: true));
      _mockAndroid({
        'dataDir': (_) => '${tmp.path}/files',
        'openVpnValidate': (_) => '',
      });
      final storeFile = File('${tmp.path}/openvpn/state.json');
      await storeFile.parent.create(recursive: true);
      await storeFile.writeAsString('{"profiles": "junk"}');
      final c = OpenVpnController();
      addTearDown(c.dispose);
      await c.load();
      expect(c.storeError, storeDamagedMessage,
          reason: 'the wrong shape is named, not silently '
              'reset (C-L12)');
      await c.importProfile('New', _ovpn);
      expect(await storeFile.readAsString(), '{"profiles": "junk"}',
          reason: 'saves are refused while the damaged '
              'file stands (C-L7)');
    });
  });

  group('N1 — emergency cancel after the toggle disconnects', () {
    test('a cancel in the post-toggle gap unwinds the '
        'engine it just started', () async {
      final active = <int, bool>{};
      final disconnects = <int>[];
      var cancelArmed = false;
      final result = await runEmergencyAttempt(
        mode: 2,
        runningMode: null,
        disconnectMode: (m) async {
          disconnects.add(m);
          active[m] = false;
        },
        toggle: (m) async {
          active[m] = true;
          cancelArmed = true; // the user cancels right here
        },
        engineActive: (m) => active[m] ?? false,
        cancelled: () => cancelArmed,
        onXraySection: (_) {},
        togglePollInterval: const Duration(milliseconds: 1),
        proofPollInterval: const Duration(milliseconds: 1),
        proofPolls: 5,
      );
      expect(result, isFalse);
      expect(disconnects, contains(2),
          reason: 'the started engine is disconnected, '
              'not left running (N1)');
      expect(active[2], isFalse);
    });
  });

  group('validation scoping (C6, L-b, C-L15)', () {
    test('the fail-closed security coercion is scoped to '
        'the stream-security protocols', () {
      final ss = sanitizeImportedProfile(Profile(
        id: 'a',
        protocol: Protocol.shadowsocks,
        name: 'ss',
        security: 'xtls-rprx-vision',
      ));
      expect(ss.security, '',
          reason: 'a stray stream-security value on a '
              'non-TLS protocol is dropped, not rewritten '
              'to tls (C6)');
      final vl = sanitizeImportedProfile(Profile(
        id: 'b',
        protocol: Protocol.vless,
        name: 'vl',
        security: 'xtls-rprx-vision',
      ));
      expect(vl.security, 'tls');
    });

    test('sanitizeSnellVersion is a real clamp', () {
      expect(sanitizeSnellVersion(0), 1);
      expect(sanitizeSnellVersion(-3), 1);
      expect(sanitizeSnellVersion(3), 3);
      expect(sanitizeSnellVersion(9), 4);
    });

    test('a Mieru profile\'s network is case-normalized', () {
      final m = sanitizeImportedProfile(Profile(
        id: 'm',
        protocol: Protocol.mieru,
        name: 'm',
        network: 'UDP',
      ));
      expect(m.network, 'udp');
    });
  });

  group('C-L8 — a subscription URL is not a proxy link', () {
    test('http(s) URLs with a path or query parse to null',
        () {
      expect(
          parseLink('https://sub.example.com:8443/feed?token=x'),
          isNull);
      expect(parseLink('https://example.com/feed'), isNull);
      final http = parseLink('http://127.0.0.1:8080');
      expect(http, isNotNull);
      expect(http!.protocol, Protocol.http);
    });
  });

  group('L-f — stringified numeric fields survive decode', () {
    test('a "51820.0" port string decodes to 51820', () {
      final p = Profile.fromJson({
        'id': 'x',
        'protocol': 'wireguard',
        'name': 'wg',
        'port': '51820.0',
      });
      expect(p.port, 51820);
    });
  });

  group('C9/C5 — tombstones', () {
    test('the tombstone key separates transport variants '
        'of one endpoint', () {
      Profile v({String network = 'tcp'}) => Profile(
            id: 'p',
            protocol: Protocol.vless,
            name: 'n',
            address: 'h.example',
            port: 443,
            uuidOrPassword: 'u',
            network: network,
          );
      expect(profileTombstoneKey(v()), profileTombstoneKey(v()));
      expect(profileTombstoneKey(v(network: 'ws')),
          isNot(profileTombstoneKey(v())),
          reason: 'deleting the tcp variant must not '
              'tombstone the ws variant of the same '
              'endpoint (C9)');
    });

    test('keepOnlyWorking tombstones its victims', () async {
      _mockAndroid({});
      final c = XrayController();
      addTearDown(c.dispose);
      final sub = Subscription(
        id: 's1',
        name: 'S',
        url: 'https://example.com/sub',
      );
      c.subscriptions.add(sub);
      final dead = Profile(
        id: 'dead',
        protocol: Protocol.vless,
        name: 'dead',
        subscriptionId: 's1',
        delayFailed: true,
      );
      final alive = Profile(
        id: 'alive',
        protocol: Protocol.vless,
        name: 'alive',
        subscriptionId: 's1',
      );
      c.profiles.addAll([dead, alive]);
      final removed = await c.keepOnlyWorking();
      expect(removed, 1);
      expect(c.profiles.map((p) => p.id), ['alive']);
      expect(sub.deletedProfileKeys,
          contains(profileTombstoneKey(dead)),
          reason: 'a bulk-pruned subscription profile '
              'stays deleted at the next refresh (C5)');
    });
  });

  group('C-L17 — mixed import accounting', () {
    test('each unread line is reported; each readable '
        'body counts once', () async {
      _mockAndroid({});
      final c = XrayController();
      addTearDown(c.dispose);
      const link =
          'vless://11111111-1111-1111-1111-111111111111@h.example:443#one';
      final vmess = 'vmess://${base64Encode(utf8.encode(jsonEncode({
            'v': '2',
            'ps': 'two',
            'add': 'h2.example',
            'port': '8443',
            'id': '22222222-2222-2222-2222-222222222222',
            'net': 'tcp',
            'tls': '',
          })))}';
      final body = base64Encode(utf8.encode(vmess));
      final r =
          await c.importLinksAsync('$link\n$body\ngarbage-line-2097');
      expect(r.added, 2, reason: 'the link and the body import');
      expect(r.errors.join('\n'), contains('garbage-line-2097'));
      expect(r.errors.join('\n'), isNot(contains('h.example')),
          reason: 'consumed lines are not reported unread');
    });
  });

  group('L-i — pairing chunks carry their transfer', () {
    test('a collector refuses a chunk from another '
        'transfer', () {
      final a = splitPairingPayload(sealPayload('A' * 900, 'pw'));
      final b = splitPairingPayload(sealPayload('B' * 900, 'pw'));
      expect(a.length, greaterThan(1));
      expect(pairingTransferTag('x'), startsWith('t'));
      final collector = PairingCollector();
      expect(collector.add(a.first), isTrue);
      expect(collector.add(b[1]), isFalse,
          reason: 'same shape, different transfer — refused');
      expect(collector.isForeignChunk(b[1]), isTrue);
      for (final chunk in a.skip(1)) {
        expect(collector.add(chunk), isTrue);
      }
      expect(collector.isComplete, isTrue);
    });

    test('legacy untagged chunks still collect', () {
      final collector = PairingCollector();
      expect(collector.add('EMBERPAIR/1/2/aaa'), isTrue);
      expect(collector.add('EMBERPAIR/2/2/bbb'), isTrue);
      expect(collector.isComplete, isTrue);
      expect(collector.assemble(), 'aaabbb');
    });
  });

  group('L-l — a mid-check channel switch discards the '
      'result', () {
    test('check() drops a result fetched for the old '
        'channel', () async {
      final settings = AppSettings();
      settings.updateChannel = 'stable';
      final releaseJson = jsonEncode({
        'tag_name': 'v9999',
        'name': 'Build 9999',
        'body': '',
        'prerelease': false,
        'assets': [
          {
            'name': 'RalysndEmber2.apk',
            'browser_download_url': 'https://example.com/9999.apk',
            'size': 10,
          },
        ],
      });
      late EmberUpdater u;
      u = EmberUpdater(
        settings: settings,
        dataDir: '/tmp',
        fetcher: (_) async {
          // The user switches channel while the fetch is
          // in flight.
          settings.updateChannel = 'beta';
          u.noteChannelChanged();
          return releaseJson;
        },
      );
      addTearDown(u.dispose);
      await u.check(manual: true);
      expect(u.state, EmberUpdateState.idle,
          reason: 'the stable result must not be offered '
              'on the beta channel');
      expect(u.release, isNull);
    });
  });

  group('C8 — a partial backup restores as an overlay', () {
    test('fields the backup omits keep their live values',
        () async {
      final tmp = await Directory.systemTemp.createTemp('ember2097');
      addTearDown(() => tmp.delete(recursive: true));
      final s = await AppSettings.load(tmp.path);
      s.update(updateChannel: 'beta');
      expect(s.updateChannel, 'beta');
      await s.applyRestoredSettings({'language': 'fa'});
      expect(s.language, 'fa');
      expect(s.updateChannel, 'beta',
          reason: 'build 2096 decoded the partial document '
              'standalone and reset every omitted field to '
              'its default (C8)');
    });
  });

  group('C-L13/C-L14 — source pins (page-private surfaces)',
      () {
    test('the rotation toggle never invents OFF', () {
      final src =
          File('lib/ui/ember/ember_accounts.dart').readAsStringSync();
      expect(src, isNot(contains('_enabled = false')),
          reason: 'a failed core read leaves the toggle '
              'unknown, not OFF (C-L13)');
    });

    test('settings PIN verification shares the lock '
        'counters', () {
      final src =
          File('lib/ui/ember/app_lock.dart').readAsStringSync();
      expect(src, contains('_verifyCurrentPin'));
      expect(src, contains('_clearLockCounters'));
      expect(src, contains('lockCooldownSeconds(attempts)'),
          reason: 'change/remove verification counts '
              'failures on the shared schedule (C-L14)');
    });
  });
}
