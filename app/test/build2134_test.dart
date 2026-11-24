// Build 2134 — OLCRTC (the priority leg) + the HWID leg.
//
// OLCRTC carries the V2Ray session's TCP over WebRTC
// data/video channels disguised as a video call (Jitsi /
// Telemost / WBStream): a bundled sidecar binary
// (libolcrtc.so) joins the same room as the user's own
// olcrtc server with the same 64-hex key and exposes a
// local SOCKS5 listener; the Xray config chains through
// it as an underlay, exactly the DNSTT shape. The whole
// feature sits behind the underlay choice — the default
// stays 'none', so with OLCRTC never selected, behavior
// is build 2133's byte for byte.
//
// The HWID leg adds an automatic per-device x-hwid on
// subscription fetches behind subHwidEnabled (default
// OFF); the other optional legs were already shipped in
// earlier builds or dropped with evidence (see
// build2134-progress.md) and are not re-pinned here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/hwid.dart';
import 'package:firefox_vpn/xray/olcrtc_args.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String read(String rel) => File(rel).readAsStringSync();

const kKey =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

XraySettings olcrtcSettings() => XraySettings()
  ..olcrtcProvider = 'jitsi'
  ..olcrtcTransport = 'datachannel'
  ..olcrtcRoom = 'https://meet.jit.si/embertest'
  ..olcrtcKey = kKey;

Profile vless() => Profile(
  id: 'p1',
  protocol: Protocol.vless,
  address: 'example.com',
  port: 443,
  uuidOrPassword: '00000000-0000-0000-0000-000000000000',
  security: 'tls',
);

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

void main() {
  group('OLCRTC key + configured checks', () {
    test('a key is exactly 64 hex digits', () {
      expect(isOlcrtcKey(kKey), isTrue);
      expect(isOlcrtcKey(kKey.toUpperCase()), isTrue);
      expect(isOlcrtcKey(' $kKey '), isTrue);
      expect(isOlcrtcKey(kKey.substring(0, 63)), isFalse);
      expect(isOlcrtcKey('${kKey}0'), isFalse);
      expect(isOlcrtcKey('g${kKey.substring(1)}'), isFalse);
      expect(isOlcrtcKey(''), isFalse);
    });

    test('configured needs provider, transport, room and key', () {
      expect(olcrtcConfigured(olcrtcSettings()), isTrue);
      expect(olcrtcConfigured(XraySettings()), isFalse);
      expect(olcrtcConfigured(olcrtcSettings()..olcrtcRoom = ' '), isFalse);
      expect(olcrtcConfigured(olcrtcSettings()..olcrtcKey = 'zz'), isFalse);
      expect(
        olcrtcConfigured(olcrtcSettings()..olcrtcProvider = 'zoom'),
        isFalse,
      );
      expect(
        olcrtcConfigured(olcrtcSettings()..olcrtcTransport = 'smoke'),
        isFalse,
      );
      expect(
        olcrtcConfigured(olcrtcSettings()..olcrtcProvider = 'telemost'),
        isTrue,
      );
    });
  });

  group('OLCRTC YAML (upstream strict schema)', () {
    test('the minimal datachannel config is exact', () {
      expect(
        buildOlcrtcYaml(olcrtcSettings()),
        'mode: cnc\n'
        'auth:\n'
        '  provider: jitsi\n'
        'room:\n'
        '  id: "https://meet.jit.si/embertest"\n'
        'crypto:\n'
        '  key: "$kKey"\n'
        'net:\n'
        '  transport: datachannel\n'
        '  dns: "8.8.8.8:53"\n'
        'socks:\n'
        '  host: "127.0.0.1"\n'
        '  port: 20866\n',
      );
    });

    test('the token rides only when set', () {
      expect(buildOlcrtcYaml(olcrtcSettings()), isNot(contains('token:')));
      final withToken = buildOlcrtcYaml(olcrtcSettings()..olcrtcToken = 't k');
      expect(withToken, contains('  token: "t k"\n'));
    });

    test('the vp8 block carries only parseable integers', () {
      final s = olcrtcSettings()
        ..olcrtcTransport = 'vp8channel'
        ..olcrtcVp8Fps = '30'
        ..olcrtcVp8Batch = 'abc';
      final yaml = buildOlcrtcYaml(s);
      expect(yaml, contains('vp8:\n  fps: 30\n'));
      expect(yaml, isNot(contains('batch_size')));
      // No values at all: no block header either.
      final bare = buildOlcrtcYaml(
        olcrtcSettings()..olcrtcTransport = 'vp8channel',
      );
      expect(bare, isNot(contains('vp8:')));
    });

    test('the sei block maps all four fields', () {
      final s = olcrtcSettings()
        ..olcrtcTransport = 'seichannel'
        ..olcrtcSeiFps = '20'
        ..olcrtcSeiBatch = '4'
        ..olcrtcSeiFrag = '1200'
        ..olcrtcSeiAckMs = '250';
      expect(
        buildOlcrtcYaml(s),
        contains(
          'sei:\n'
          '  fps: 20\n'
          '  batch_size: 4\n'
          '  fragment_size: 1200\n'
          '  ack_timeout_ms: 250\n',
        ),
      );
    });

    test('the video block whitelists codec and recovery', () {
      final s = olcrtcSettings()
        ..olcrtcTransport = 'videochannel'
        ..olcrtcVideoWidth = '640'
        ..olcrtcVideoCodec = 'tile'
        ..olcrtcVideoQrRecovery = 'extreme';
      final yaml = buildOlcrtcYaml(s);
      expect(yaml, contains('video:\n  width: 640\n  codec: tile\n'));
      expect(yaml, isNot(contains('qr_recovery')));
      final ok = buildOlcrtcYaml(
        olcrtcSettings()
          ..olcrtcTransport = 'videochannel'
          ..olcrtcVideoCodec = 'webm'
          ..olcrtcVideoQrRecovery = 'high',
      );
      expect(ok, contains('  qr_recovery: high\n'));
      expect(ok, isNot(contains('codec:')));
    });

    test('quotes and backslashes in the room are escaped', () {
      final yaml = buildOlcrtcYaml(olcrtcSettings()..olcrtcRoom = 'a"b\\c');
      expect(yaml, contains('  id: "a\\"b\\\\c"\n'));
    });
  });

  group('olcrtc:// share links', () {
    test('the full form parses (payload, room, key, comment)', () {
      final link = parseOlcrtcLink(
        'olcrtc://Jitsi?vp8channel<vp8-fps=30&vp8-batch=2>'
        '@room42#$kKey\$my server',
      );
      expect(link, isNotNull);
      expect(link!.provider, 'jitsi');
      expect(link.transport, 'vp8channel');
      expect(link.params, {'vp8-fps': '30', 'vp8-batch': '2'});
      expect(link.room, 'room42');
      expect(link.key, kKey);
      expect(link.comment, 'my server');
    });

    test('the bare form parses and percent-decodes the room', () {
      final link = parseOlcrtcLink(
        'olcrtc://telemost?datachannel@https%3A%2F%2Ftelemost.example%2Fr1'
        '#$kKey',
      );
      expect(link, isNotNull);
      expect(link!.params, isEmpty);
      expect(link.room, 'https://telemost.example/r1');
      expect(link.comment, '');
    });

    test('malformed links are refused', () {
      expect(parseOlcrtcLink(''), isNull);
      expect(parseOlcrtcLink('http://jitsi?datachannel@r#$kKey'), isNull);
      expect(parseOlcrtcLink('olcrtc://zoom?datachannel@r#$kKey'), isNull);
      expect(parseOlcrtcLink('olcrtc://jitsi?smoke@r#$kKey'), isNull);
      expect(parseOlcrtcLink('olcrtc://jitsi?datachannel@r#short'), isNull);
      expect(parseOlcrtcLink('olcrtc://jitsi?datachannel@#$kKey'), isNull);
      expect(parseOlcrtcLink('olcrtc://jitsi?datachannel'), isNull);
    });

    test('build and parse round-trip with parameters', () {
      final s = olcrtcSettings()
        ..olcrtcTransport = 'seichannel'
        ..olcrtcSeiFps = '15'
        ..olcrtcSeiAckMs = '300'
        ..olcrtcRoom = 'room9';
      final built = buildOlcrtcLink(s, comment: 'home');
      final back = parseOlcrtcLink(built);
      expect(back, isNotNull);
      expect(back!.provider, 'jitsi');
      expect(back.transport, 'seichannel');
      expect(back.room, 'room9');
      expect(back.key, kKey);
      expect(back.comment, 'home');
      expect(back.params, {'fps': '15', 'ack-ms': '300'});
    });

    test('applyOlcrtcLinkParams lands the URI keys on the fields', () {
      final s = XraySettings();
      applyOlcrtcLinkParams(
        s,
        OlcrtcLink(
          provider: 'wbstream',
          transport: 'videochannel',
          params: const {'video-w': '320', 'video-codec': 'tile'},
          room: 'r',
          key: kKey,
        ),
      );
      expect(s.olcrtcVideoWidth, '320');
      expect(s.olcrtcVideoCodec, 'tile');
      expect(s.olcrtcVideoHeight, '');
    });
  });

  group('OLCRTC settings storage', () {
    test('defaults keep the underlay off and the form empty', () {
      final s = XraySettings();
      expect(s.underlay, 'none');
      expect(s.olcrtcProvider, 'jitsi');
      expect(s.olcrtcTransport, 'datachannel');
      expect(s.olcrtcRoom, '');
      expect(s.olcrtcKey, '');
      expect(s.olcrtcDns, '8.8.8.8:53');
    });

    test('the underlay and the OLCRTC fields round-trip', () {
      final s = olcrtcSettings()
        ..underlay = 'olcrtc'
        ..olcrtcSeiFrag = '900';
      final back = XraySettings.fromJson(s.toJson());
      expect(back.underlay, 'olcrtc');
      expect(back.olcrtcRoom, 'https://meet.jit.si/embertest');
      expect(back.olcrtcKey, kKey);
      expect(back.olcrtcSeiFrag, '900');
    });

    test('an unknown stored underlay falls back to none', () {
      final j = XraySettings().toJson()..['underlay'] = 'olcrtc2';
      expect(XraySettings.fromJson(j).underlay, 'none');
    });
  });

  group('OLCRTC chain config', () {
    test('the underlay outbound is emitted and the proxy chains', () {
      final cfg = decode(
        buildTunnelConfig(vless(), XraySettings(), olcrtcUnderlay: true),
      );
      final outbounds = (cfg['outbounds'] as List)
          .cast<Map<String, dynamic>>();
      final under = outbounds.firstWhere((o) => o['tag'] == olcrtcUnderlayTag);
      expect(under['protocol'], 'socks');
      final server = ((under['settings'] as Map)['servers'] as List).first;
      expect(server, {'address': '127.0.0.1', 'port': olcrtcListenPort});
      final proxy = outbounds.firstWhere((o) => o['tag'] == 'proxy');
      expect(
        proxy['streamSettings']['sockopt']['dialerProxy'],
        olcrtcUnderlayTag,
      );
    });

    test('without the flag there is no OLCRTC anywhere', () {
      final cfg = decode(buildTunnelConfig(vless(), XraySettings()));
      final tags = (cfg['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .map((o) => o['tag']);
      expect(tags, isNot(contains(olcrtcUnderlayTag)));
    });
  });

  group('HWID leg', () {
    test('generated device ids are UUID v4 shaped and unique', () {
      final a = generateDeviceHwid();
      final b = generateDeviceHwid();
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(a),
        isTrue,
      );
      expect(a, isNot(b));
    });

    test('off, unminted or manually-set means no extra headers', () {
      expect(
        autoHwidHeaders(
          enabled: false,
          deviceHwid: 'dev',
          subHwid: '',
          customHeaders: const {},
        ),
        isEmpty,
      );
      expect(
        autoHwidHeaders(
          enabled: true,
          deviceHwid: '',
          subHwid: '',
          customHeaders: const {},
        ),
        isEmpty,
      );
      expect(
        autoHwidHeaders(
          enabled: true,
          deviceHwid: 'dev',
          subHwid: 'manual',
          customHeaders: const {},
        ),
        isEmpty,
      );
    });

    test('enabled sends the device id plus the OS companion', () {
      expect(
        autoHwidHeaders(
          enabled: true,
          deviceHwid: 'dev',
          subHwid: '',
          customHeaders: const {},
        ),
        {'x-hwid': 'dev', 'x-device-os': 'Android'},
      );
    });

    test('the user\'s own headers are never overwritten', () {
      // Their x-device-os (any case) suppresses the companion.
      expect(
        autoHwidHeaders(
          enabled: true,
          deviceHwid: 'dev',
          subHwid: '',
          customHeaders: const {'X-Device-OS': 'iOS'},
        ),
        {'x-hwid': 'dev'},
      );
      // Their own x-hwid header suppresses the device id;
      // the companion still rides.
      expect(
        autoHwidHeaders(
          enabled: true,
          deviceHwid: 'dev',
          subHwid: '',
          customHeaders: const {'X-HWID': 'mine'},
        ),
        {'x-device-os': 'Android'},
      );
    });

    test('the HWID settings default off and round-trip', () {
      final s = XraySettings();
      expect(s.subHwidEnabled, isFalse);
      expect(s.deviceHwid, '');
      final back = XraySettings.fromJson(
        (XraySettings()
              ..subHwidEnabled = true
              ..deviceHwid = 'dev-id')
            .toJson(),
      );
      expect(back.subHwidEnabled, isTrue);
      expect(back.deviceHwid, 'dev-id');
    });
  });

  group('source pins', () {
    test('pubspec is build 2134', () {
      expect(read('pubspec.yaml'), contains('version: 2.2.0+2148'));
    });

    test('the Kotlin helper is staged on the mirrored port', () {
      final kt = read(
        'android/app/src/main/kotlin/com/ralysnd/ember/OlcrtcCore.kt',
      );
      expect(kt, contains('"libolcrtc.so"'));
      expect(kt, contains('port = 20866'));
      expect(kt, contains('probeTimeoutMs = 120_000'));
      final svc = read(
        'android/app/src/main/kotlin/com/ralysnd/ember/XrayVpnService.kt',
      );
      expect(svc, contains('EXTRA_OLCRTC_ARGS'));
      expect(svc, contains('OLCRTC_CHAIN_INITIAL_GRACE_MS = 120_000L'));
      final main = read(
        'android/app/src/main/kotlin/com/ralysnd/ember/MainActivity.kt',
      );
      expect(main, contains('"olcrtcStart"'));
      expect(main, contains('"olcrtcArgs"'));
    });

    test('the sidecar binary is staged in jniLibs', () {
      final f = File(
        'android/app/src/main/jniLibs/arm64-v8a/libolcrtc.so',
      );
      expect(f.existsSync(), isTrue);
      // The pinned upstream build is ~33 MB; a stub or a
      // truncated copy fails this floor.
      expect(f.lengthSync(), greaterThan(30 * 1024 * 1024));
    });

    test('the controller starts OLCRTC only when selected', () {
      final c = read('lib/xray/xray_controller.dart');
      expect(c, contains('_startOlcrtcUnderlay'));
      expect(c, contains("StateError('olcrtc-not-configured')"));
      expect(c, contains("settings.underlay == 'olcrtc'"));
    });
  });
}
