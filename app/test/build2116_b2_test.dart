// Build 2116, batch B2 — Xray: data-plane proof + config
// emission defects (audit AB-01, G-01, G-02, G-03, G-16,
// G-17, D-partial #26/#47).
//
// - B2-1: a plain Xray session is adopted only after the
//   carries proof (exit lookup inside a 12 s window, then
//   one tunnel check as the verdict) — "Connected" no
//   longer means merely "the VPN service is running".
// - B2-2: a Hysteria2 mport profile is served by the
//   sing-box sidecar, whose outbound carries server_ports.
// - B2-3: XHTTP `extra` is stored and merged into
//   xhttpSettings (the VMess xmux shape included).
// - B2-4: WS `ed` lands as maxEarlyData.
// - B2-5: TCP header camouflage beyond http is emitted;
//   a type the core cannot emit is flagged, not silent.
// - B2-6: per-transport headers maps survive import and
//   are emitted whole.
// - B2-7: a gecko-obfs Hy2 profile is served by the
//   sidecar, which applies the obfs.
//
// All fixtures use dummy values.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/singbox_config.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Map<String, dynamic> streamOf(Profile p) {
  final config = decode(buildTunnelConfig(p, XraySettings()));
  final out = (config['outbounds'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((o) => o['tag'] == 'proxy');
  return out['streamSettings'] as Map<String, dynamic>;
}

Profile vless({String network = 'tcp', String headerType = ''}) => Profile(
  id: 'p1',
  protocol: Protocol.vless,
  address: '203.0.113.10',
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  network: network,
  headerType: headerType,
  security: 'tls',
  sni: 'example.com',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('B2-3 XHTTP extra (G-02, folds D #47)', () {
    test('a link extra lands whole in xhttpSettings', () {
      final extra = Uri.encodeComponent(
        '{"xmux":{"maxConcurrency":8},'
        '"downloadSettings":{"address":"dl.example.net","port":443}}',
      );
      final p = parseLink(
        'vless://00000000-0000-4000-8000-000000000000@203.0.113.10:443'
        '?security=tls&type=xhttp&path=%2Fapi&mode=auto&extra=$extra#x',
      );
      expect(p, isNotNull);
      expect(p!.xhttpExtra, contains('xmux'));
      final x = streamOf(p)['xhttpSettings'] as Map<String, dynamic>;
      expect(x['xmux'], {'maxConcurrency': 8});
      expect(x['downloadSettings'], {
        'address': 'dl.example.net',
        'port': 443,
      });
      expect(x['path'], '/api');
      expect(x['mode'], 'auto');
    });

    test('the VMess xmux shape (#47) rides the same merge', () {
      final p = vless(network: 'xhttp')
        ..xhttpExtra = '{"xmux":{"maxConnections":4}}';
      final x = streamOf(p)['xhttpSettings'] as Map<String, dynamic>;
      expect(x['xmux'], {'maxConnections': 4});
    });

    test('a malformed extra is ignored, never fatal', () {
      final p = vless(network: 'xhttp')..xhttpExtra = '{not json';
      final x = streamOf(p)['xhttpSettings'] as Map<String, dynamic>;
      expect(x['path'], '/');
      expect(x.containsKey('xmux'), isFalse);
    });

    test('a raw JSON config carrying extra keeps it', () {
      final body = jsonEncode({
        'outbounds': [
          {
            'protocol': 'vless',
            'tag': 'proxy',
            'settings': {
              'vnext': [
                {
                  'address': '203.0.113.10',
                  'port': 443,
                  'users': [
                    {'id': '00000000-0000-4000-8000-000000000000'},
                  ],
                },
              ],
            },
            'streamSettings': {
              'network': 'xhttp',
              'security': 'tls',
              'xhttpSettings': {
                'path': '/api',
                'extra': {
                  'scMaxEachPostBytes': 1000000,
                },
              },
            },
          },
        ],
      });
      final profiles = parseSubscription(body);
      expect(profiles, hasLength(1));
      expect(profiles.single.xhttpExtra, contains('scMaxEachPostBytes'));
    });
  });

  group('B2-4 WS early data (G-03)', () {
    test('ed=2048 lands as maxEarlyData with its header name', () {
      final p = parseLink(
        'vless://00000000-0000-4000-8000-000000000000@203.0.113.10:443'
        '?security=tls&type=ws&path=%2Fws&host=cdn.example.net&ed=2048#x',
      );
      expect(p, isNotNull);
      expect(p!.wsEarlyData, 2048);
      final ws = streamOf(p)['wsSettings'] as Map<String, dynamic>;
      expect(ws['maxEarlyData'], 2048);
      expect(ws['earlyDataHeaderName'], 'Sec-WebSocket-Protocol');
    });

    test('no ed, no early-data keys', () {
      final ws = streamOf(vless(network: 'ws'))['wsSettings']
          as Map<String, dynamic>;
      expect(ws.containsKey('maxEarlyData'), isFalse);
    });
  });

  group('B2-5 TCP header camouflage (G-16)', () {
    test('srtp is emitted as a bare header block', () {
      final s = streamOf(vless(headerType: 'srtp'));
      expect(s['tcpSettings'], {
        'header': {'type': 'srtp'},
      });
    });

    test('wechat maps to the core name wechat-video', () {
      final s = streamOf(vless(headerType: 'wechat'));
      expect((s['tcpSettings'] as Map)['header'], {'type': 'wechat-video'});
    });

    test('an unemittable type is flagged and not emitted', () {
      final p = vless(headerType: 'bogus-type');
      expect(p.hasUnappliedTcpHeader, isTrue);
      expect(streamOf(p).containsKey('tcpSettings'), isFalse);
    });

    test('http keeps its request template', () {
      final s = streamOf(vless(headerType: 'http'));
      final header = (s['tcpSettings'] as Map)['header'] as Map;
      expect(header['type'], 'http');
      expect(header.containsKey('request'), isTrue);
    });
  });

  group('B2-6 per-transport headers (G-17)', () {
    test('a raw JSON ws headers map survives import whole', () {
      final body = jsonEncode({
        'outbounds': [
          {
            'protocol': 'vless',
            'tag': 'proxy',
            'settings': {
              'vnext': [
                {
                  'address': '203.0.113.10',
                  'port': 443,
                  'users': [
                    {'id': '00000000-0000-4000-8000-000000000000'},
                  ],
                },
              ],
            },
            'streamSettings': {
              'network': 'ws',
              'security': 'tls',
              'wsSettings': {
                'path': '/ws',
                'headers': {
                  'Host': 'cdn.example.net',
                  'X-Forwarded-Host': 'front.example.net',
                  'User-Agent': 'Mozilla/5.0',
                },
              },
            },
          },
        ],
      });
      final profiles = parseSubscription(body);
      expect(profiles, hasLength(1));
      final p = profiles.single;
      expect(p.host, 'cdn.example.net');
      final headers = streamOf(p)['wsSettings']['headers']
          as Map<String, dynamic>;
      expect(headers['Host'], 'cdn.example.net');
      expect(headers['X-Forwarded-Host'], 'front.example.net');
      expect(headers['User-Agent'], 'Mozilla/5.0');
    });
  });

  group('B2-2/B2-7 Hy2 sidecar diversion (G-01, D #26)', () {
    Profile hy2({String mport = '', String obfs = ''}) => Profile(
      id: 'h1',
      protocol: Protocol.hysteria2,
      address: '203.0.113.20',
      port: 443,
      uuidOrPassword: 'dummy-password',
      security: 'tls',
      sni: 'example.com',
      hyMport: mport,
      obfs: obfs,
      obfsPassword: 'dummy-obfs-password',
    );

    test('server_ports normalisation', () {
      expect(singBoxServerPorts('443,8443'), ['443:443', '8443:8443']);
      expect(singBoxServerPorts('10000-20000'), ['10000:20000']);
      expect(singBoxServerPorts('10000:20000'), ['10000:20000']);
      expect(singBoxServerPorts('junk,0,99999,80'), ['80:80']);
      expect(singBoxServerPorts(''), isEmpty);
    });

    test('an mport profile is sidecar-served with its range', () {
      final p = hy2(mport: '10000-20000');
      expect(p.hy2SidecarServed, isTrue);
      expect(p.servedBySidecar, isTrue);
      expect(p.hasIgnoredPortHopping, isFalse);
      expect(singBoxConfigError(p), isNull);
      final config = buildSingBoxConfig(p);
      final out = (config['outbounds'] as List).single
          as Map<String, dynamic>;
      expect(out['type'], 'hysteria2');
      expect(out['server_ports'], ['10000:20000']);
      expect(out['hop_interval'], '30s');
    });

    test('a gecko profile is sidecar-served with its obfs', () {
      final p = hy2(obfs: 'gecko');
      expect(p.hy2SidecarServed, isTrue);
      expect(p.hasUnappliedObfs, isFalse);
      final config = buildSingBoxConfig(p);
      final out = (config['outbounds'] as List).single
          as Map<String, dynamic>;
      expect(out['obfs'], {
        'type': 'gecko',
        'password': 'dummy-obfs-password',
      });
    });

    test('an unknown obfs stays unapplied and Xray-served', () {
      final p = hy2(obfs: 'mystery');
      expect(p.hasUnappliedObfs, isTrue);
      expect(p.servedBySidecar, isFalse);
    });

    test('plain and salamander Hy2 stay on the Xray core', () {
      expect(hy2().servedBySidecar, isFalse);
      expect(hy2(obfs: 'salamander').servedBySidecar, isFalse);
    });
  });

  group('B2-1 data-plane proof (AB-01)', () {
    test('XrayState.withVerified stamps only the flag', () {
      const s = XrayState(
        running: true,
        name: 'p',
        sinceMs: 4242,
        upBytes: 10,
        downBytes: 20,
      );
      final v = s.withVerified(true);
      expect(v.verified, isTrue);
      expect(v.running, isTrue);
      expect(v.sinceMs, 4242);
      expect(v.upBytes, 10);
      expect(v.downBytes, 20);
      expect(s.verified, isFalse);
    });

    group('the carries verdict', () {
      late XrayController controller;
      var exitLands = false;
      var checkMs = -1;
      var stateRunning = true;

      setUp(() {
        controller = XrayController();
        controller.state = const XrayState(
          running: true,
          name: 'p',
          sinceMs: 4242,
          upBytes: 0,
          downBytes: 0,
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('app/android'), (
              call,
            ) async {
              switch (call.method) {
                case 'xrayState':
                  return {
                    'running': stateRunning,
                    'name': 'p',
                    'sinceMs': 4242,
                    'up': 0,
                    'down': 0,
                  };
                case 'xrayExitInfo':
                  return exitLands
                      ? {'ip': '203.0.113.99', 'countryCode': 'NL'}
                      : null;
                case 'xrayTunnelCheck':
                  return checkMs;
                default:
                  return null;
              }
            });
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('app/android'), null);
      });

      test('an exit lookup inside the window proves the session', () async {
        exitLands = true;
        stateRunning = true;
        expect(await controller.awaitXrayCarries(() {}), isTrue);
      });

      test(
        'a tunnel check carries it when the exit lookup never lands',
        () async {
          exitLands = false;
          checkMs = 42;
          stateRunning = true;
          expect(await controller.awaitXrayCarries(() {}), isTrue);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test(
        'nothing carrying inside the window fails the proof',
        () async {
          exitLands = false;
          checkMs = -1;
          stateRunning = true;
          expect(await controller.awaitXrayCarries(() {}), isFalse);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test('a session that stops mid-proof fails at once', () async {
        exitLands = false;
        stateRunning = false;
        expect(await controller.awaitXrayCarries(() {}), isFalse);
      });
    });

    test('the proof gates adoption in _connectSelected (pins)', () {
      // PIN SUPERSEDED by build 2149 (owner order
      // 2026-11-25, diagnosis D1): the adoption GATE is
      // removed — the gate tore down slow-first-byte
      // sessions (the CF-fronted WS+TLS class) that
      // v2rayNG/Karing adopt on core-up. The proof is
      // demoted to the adopted-session surfacing (2119
      // F-02): adoption stamps the session UNVERIFIED and
      // the background proof upgrades it. The carries
      // machinery itself is unchanged (the verdict tests
      // above stand); what this pin now guards is the
      // gate's ABSENCE and the unverified adoption.
      final src = File('lib/xray/xray_controller.dart').readAsStringSync();
      final start = src.indexOf('Future<void> _connectSelected() async {');
      final end = src.indexOf(
        'Future<void> disconnect({bool consumeChainExit = true}) async {',
      );
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final segment = src.substring(start, end);
      expect(segment, contains('p.protocol != Protocol.wireguard'));
      expect(segment, isNot(contains("throw StateError('no-traffic')")));
      expect(segment, isNot(contains('awaitXrayCarries(checkAlive)')));
      expect(segment, contains('_proofVerifiedSinceMs = 0'));
      expect(segment, contains('state = state.withVerified(false);'));
      final adoptAt = segment.indexOf('_connectedProfileId = p.id;');
      final unverifiedAt = segment.indexOf(
        'state = state.withVerified(false);',
      );
      expect(unverifiedAt, greaterThanOrEqualTo(0));
      expect(adoptAt, greaterThan(unverifiedAt));
    });
  });
}
