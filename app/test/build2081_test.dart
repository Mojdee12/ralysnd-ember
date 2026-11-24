/// Build 2081 gates — the final verification pass's remainders
/// (final-verification-2026-11-15.md §4) taken in the normal pick
/// order: V-1 the Session Traffic line's ↓/↑ glyphs → words;
/// V-9 the desktop Logs traffic line's glyphs → words;
/// V-8 the V2Ray notification's live speed line + Pause/Resume,
/// with the Dart poll treating a pause as a held session;
/// Q-2 the WireGuard outbound's IPv4-only server strategy;
/// V-4 a test pinning fakeDNS default OFF;
/// V-5 a test pinning the TCP ping probe.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/net/tcp_ping.dart';
import 'package:firefox_vpn/ui/ember/ember_format.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

String _read(String path) => File(path).readAsStringSync();
String _dart(String path) => _read('lib/$path');
String _kt(String name) =>
    _read('android/app/src/main/kotlin/com/ralysnd/ember/$name');
String _res(String path) => _read('android/app/src/main/res/$path');

/// The source of one Kotlin function, from its signature line to
/// the next `private fun` at the same indent.
String _ktFun(String src, String marker) {
  final start = src.indexOf(marker);
  assert(start >= 0, 'missing $marker');
  final next = src.indexOf('\n    private fun ', start + marker.length);
  return next < 0 ? src.substring(start) : src.substring(start, next);
}

Map<String, dynamic> _decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Profile _vless() => Profile(
  id: 'v1',
  protocol: Protocol.vless,
  name: 'VLESS Node',
  address: 'node.example.com',
  port: 443,
  uuidOrPassword: '11111111-1111-1111-1111-111111111111',
  security: 'tls',
  sni: 'node.example.com',
  fingerprint: 'chrome',
);

Profile _wg({String address = '203.0.113.7'}) => Profile(
  id: 'wg1',
  protocol: Protocol.wireguard,
  name: 'WG Node',
  address: address,
  port: 51820,
  secretKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  peerPublicKey: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
  localAddress: '10.66.66.2/32',
  mtu: 1420,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('V-1 Session Traffic glyphs → words', () {
    test('fmtProfileTotals renders Down/Up in words, no glyphs', () {
      final p = _vless()
        ..totalDownBytes = 35840000
        ..totalUpBytes = 3400000;
      final line = fmtProfileTotals(p);
      expect(line, contains('Down'));
      expect(line, contains('Up'));
      expect(line, isNot(contains('↓')));
      expect(line, isNot(contains('↑')));
      // Latin digits, Latin units (the standing rule).
      expect(line, contains('34.2 MB'));
      expect(line, contains('3.2 MB'));
    });

    test('the Session Traffic line uses fmtProfileTotals', () {
      final src = _dart('ui/ember/ember_home.dart');
      expect(src, isNot(contains('↓')));
      expect(src, isNot(contains('↑')));
      // PIN UPDATED by the build 2145 fix round (A10 widget
      // composition): the _summaryLine method became the
      // _SummaryLine widget class; the Traffic line still
      // renders fmtProfileTotals(p) — same verified behavior.
      expect(
        src,
        contains(
            "_SummaryLine(label: 'Traffic', value: fmtProfileTotals(p))"),
      );
    });
  });

  group('V-9 desktop traffic glyphs → words', () {
    test('the Logs traffic line uses words, not glyphs', () {
      final src = _dart('ui/connections_view.dart');
      expect(src, isNot(contains('↓')));
      expect(src, isNot(contains('↑')));
      expect(src, contains('Down '));
      expect(src, contains('formatBytes(c.down)'));
      expect(src, contains('Up '));
      expect(src, contains('formatBytes(c.up)'));
    });
  });

  group('Q-2 WireGuard outbound IPv4-only server strategy '
      '(strategy removed in build 2101 by owner order)', () {
    test('the WG outbound keeps its sockopt map, strategy gone', () {
      final out = buildOutbound(_wg(), XraySettings());
      expect(out, isNotNull);
      expect(out!['protocol'], 'wireguard');
      final stream = out['streamSettings'] as Map;
      // The map itself stays: it is the chain-merge surface
      // (the 2081 crash fix). Only the stamp is removed.
      expect((stream['sockopt'] as Map)['domainStrategy'], isNull);
    });

    test('hostname endpoints keep their hostname; literals untouched', () {
      final host = buildOutbound(
        _wg(address: 'wg.example.com'),
        XraySettings(),
      )!;
      expect(
        (host['settings'] as Map)['peers'][0]['endpoint'],
        'wg.example.com:51820',
      );
      final ip = buildOutbound(_wg(), XraySettings())!;
      final settings = ip['settings'] as Map;
      expect(settings['peers'][0]['endpoint'], '203.0.113.7:51820');
      // The settings half is exactly as before — only the
      // streamSettings was added.
      expect(settings['mtu'], 1420);
      expect(settings['noKernelTun'], isTrue);
      expect(settings['secretKey'], isNotEmpty);
    });

    test('a chained WG session merges dialerProxy into the sockopt', () {
      final cfg = _decode(
        buildTunnelConfig(
          _wg(),
          XraySettings(),
          warpUnderlay: true,
          warp: WarpProfile(),
        ),
      );
      final outbounds = cfg['outbounds'] as List;
      final proxy =
          outbounds.firstWhere((o) => o['tag'] == 'proxy') as Map;
      final sockopt = (proxy['streamSettings'] as Map)['sockopt'] as Map;
      expect(sockopt['domainStrategy'], isNull);
      expect(sockopt['dialerProxy'], 'warp-underlay');
    });

    test('the same merge works for SS/SOCKS/HTTP (2049 literals)', () {
      // Build 2081: the three 2049 sockopt-only literals had
      // the same untyped-map crash as the WG case — a chained
      // connect threw in _chainThroughUnderlay before any
      // tunnel existed.
      final cases = <Profile>[
        Profile(
          id: 'ss1',
          protocol: Protocol.shadowsocks,
          name: 'SS',
          address: '203.0.113.7',
          port: 8388,
          method: 'aes-256-gcm',
          uuidOrPassword: 'password',
        ),
        Profile(
          id: 'sk1',
          protocol: Protocol.socks,
          name: 'SOCKS',
          address: '203.0.113.7',
          port: 1080,
          uuidOrPassword: 'password',
        ),
        Profile(
          id: 'ht1',
          protocol: Protocol.http,
          name: 'HTTP',
          address: '203.0.113.7',
          port: 8080,
          uuidOrPassword: 'password',
        ),
      ];
      for (final p in cases) {
        final cfg = _decode(
          buildTunnelConfig(
            p,
            XraySettings(),
            warpUnderlay: true,
            warp: WarpProfile(),
          ),
        );
        final outbounds = cfg['outbounds'] as List;
        final proxy =
            outbounds.firstWhere((o) => o['tag'] == 'proxy') as Map;
        final sockopt =
            (proxy['streamSettings'] as Map)['sockopt'] as Map;
        expect(
          sockopt['domainStrategy'],
          isNull,
          reason: '${p.protocol}',
        );
        expect(
          sockopt['dialerProxy'],
          'warp-underlay',
          reason: '${p.protocol}',
        );
      }
    });
  });

  group('V-4 fakeDNS default OFF', () {
    test('the setting defaults off', () {
      expect(XraySettings().fakeDns, isFalse);
    });

    test('a default built config carries no fakeDNS anywhere', () {
      final cfg = buildTunnelConfig(_vless(), XraySettings());
      expect(cfg, isNot(contains('fakedns')));
    });

    test('opting in still emits it (control arm)', () {
      final s = XraySettings()..fakeDns = true;
      final cfg = buildTunnelConfig(_vless(), s);
      expect(cfg, contains('fakedns'));
    });
  });

  group('V-5 TCP ping probe', () {
    test('an answering loopback port returns a time', () async {
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(server.close);
      final ms = await probeProfileTcp(
        _vless()
          ..address = '127.0.0.1'
          ..port = server.port,
      );
      expect(ms, greaterThanOrEqualTo(0));
    });

    test('a closed port and an empty address return -1', () async {
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = server.port;
      await server.close();
      final closed = await probeProfileTcp(
        _vless()
          ..address = '127.0.0.1'
          ..port = port,
      );
      expect(closed, -1);
      expect(await probeProfileTcp(_vless()..address = ''), -1);
      expect(await probeProfileTcp(_vless()..port = 0), -1);
    });
  });

  group('V-8 notification Pause/Resume (Kotlin source pins)', () {
    late String kt;
    late String main;
    setUpAll(() {
      kt = _kt('XrayVpnService.kt');
      main = _kt('MainActivity.kt');
    });

    test('Pause/Resume actions exist and run off the main thread', () {
      expect(
        kt,
        contains('ACTION_PAUSE = "com.ralysnd.ember.XRAY_PAUSE"'),
      );
      expect(
        kt,
        contains('ACTION_RESUME = "com.ralysnd.ember.XRAY_RESUME"'),
      );
      expect(kt, contains('ACTION_PAUSE ->'));
      // Build 2125 re-point (A25-02): pause/resume no
      // longer own private threads — they run on the one
      // serial "xray-actions" executor (off the main
      // thread, as this pin exists to prove).
      expect(kt, contains('"xray-actions"'));
      expect(kt, contains('ACTION_RESUME ->'));
    });

    test('pause stops the core and holds the service, never stops it', () {
      final fn = _ktFun(kt, 'private fun pauseTunnel()');
      expect(fn, contains('if (!running || paused || !canPauseSession())'));
      expect(fn, contains('stopping.set(true)'));
      expect(fn, contains('stopUnderlay()'));
      expect(fn, contains('stopProcesses()'));
      expect(fn, contains('running = false'));
      expect(fn, contains('paused = true'));
      expect(fn, contains('updateNotification(profileName)'));
      expect(fn, isNot(contains('stopSelf()')));
      expect(fn, isNot(contains('stopForeground')));
    });

    test('resume restarts the same session from the retained args', () {
      final fn = _ktFun(kt, 'private fun resumeTunnel()');
      expect(fn, contains('if (!paused) return'));
      expect(fn, contains('startTunnel('));
      expect(fn, contains('sessionConfig'));
      expect(fn, contains('sessionIpv6'));
      expect(fn, contains('sessionSocksUser'));
      expect(fn, contains('sessionSocksPass'));
      expect(fn, contains('stopTunnel()'));
      expect(fn, contains('startFailed("XrayVpnService.resumeTunnel"'));
    });

    test('only resumable sessions can pause', () {
      final fn = _ktFun(kt, 'private fun canPauseSession()');
      // Build 2100 (W-WG2, named reason): the !awgMode clause
      // is gone with the service move — AWG sessions live in
      // AwgVpnService, which has no pause path at all (no
      // canPauseSession, no Pause action in its notification),
      // so Xray's gate no longer needs to exclude a mode that
      // cannot reach it. The AWG half of the rule is pinned
      // below, in the moved service.
      expect(
        fn,
        contains('!sessionWarpMode && !sessionSocksMode'),
      );
      expect(fn, contains('!sessionWgWstunnel'));
      expect(fn, contains('sessionUnderlay == "psiphon"'));
      expect(fn, contains('sessionUnderlay == "dnstt"'));
      expect(fn, isNot(contains('awgMode')));
      // Build 2104: the AWG notification is built by
      // WgTunnelEngine's application provider — Disconnect
      // and Switch-server actions only, no Pause (the
      // backend's companion notification has no pause
      // concept, and the state merge reports an AWG
      // session's paused as false).
      final awg = _kt('WgTunnelEngine.kt');
      expect(awg, isNot(contains('fun canPauseSession')));
      expect(awg, isNot(contains('ACTION_PAUSE')));
      expect(awg, isNot(contains('notification_pause')));
      expect(awg, contains('notification_stop'));
      expect(awg, contains('notification_rotate'));
    });

    test('the notification shows the speed line and Pause/Resume', () {
      final fn = _ktFun(kt, 'private fun notification(');
      // Build 2095 (whole-app journey audit #23): the
      // notification names the ACTUAL engine through
      // engineLabel (V2Ray is its default case) — the
      // pin follows the generalized composition.
      expect(fn, contains('else if (paused) "Paused — \$engineLabel · \$name"'));
      expect(fn, contains('else -> "V2Ray"'));
      expect(fn, contains('shownSpeed'));
      expect(fn, contains('BigTextStyle().bigText(text)'));
      expect(fn, contains('notification_pause'));
      expect(fn, contains('notification_resume'));
      expect(fn, contains('ACTION_PAUSE'));
      expect(fn, contains('ACTION_RESUME'));
      // Distinct PendingIntent request codes (10 open, 11 stop,
      // 12 rotate are taken).
      expect(fn, contains('this, 13,'));
      expect(fn, contains('this, 14,'));
    });

    test('the speed line samples and re-posts only on change', () {
      final fn = _ktFun(kt, 'private fun refreshSpeedLine()');
      expect(fn, contains('if (paused || !running) return'));
      expect(fn, contains('sessionTraffic()'));
      expect(fn, contains('rateText(down)'));
      expect(fn, contains('rateText(up)'));
      expect(fn, contains('if (line != shownSpeed)'));
      expect(fn, contains('updateNotification(profileName)'));
      final rate = _ktFun(kt, 'private fun rateText(');
      expect(rate, contains('MB/s'));
      expect(rate, contains('KB/s'));
      expect(rate, contains('B/s'));
    });

    test('the start path retains the resume args and clears a pause', () {
      final fn = _ktFun(kt, 'private fun startTunnel(');
      expect(fn, contains('paused = false'));
      expect(fn, contains('sessionIpv6 = ipv6'));
      expect(fn, contains('sessionSocksUser = socksUser'));
      expect(fn, contains('sessionSocksPass = socksPass'));
      final stop = _ktFun(kt, 'private fun stopTunnel()');
      expect(stop, contains('paused = false'));
      final watch = _ktFun(kt, 'private fun watchProcesses()');
      expect(watch, contains('lastSpeedSample = sessionTraffic()'));
      expect(watch, contains('refreshSpeedLine()'));
    });

    test('Pause/Resume strings exist; the state map reports paused', () {
      final strings = _res('values/strings.xml');
      expect(strings, contains('name="notification_pause">Pause<'));
      expect(strings, contains('name="notification_resume">Resume<'));
      expect(main, contains('"paused" to XrayVpnService.paused'));
    });
  });

  group('V-8 pause is a held session, not a drop (Dart)', () {
    late XrayController c;
    late Map<String, dynamic> sample;

    Map<String, dynamic> stateSample({
      required bool running,
      bool paused = false,
    }) => {
      'running': running,
      'paused': paused,
      'name': running || paused ? 'WG Node' : '',
      'sinceMs': 1000,
      'up': 0,
      'down': 0,
      'coreRestarts': 0,
      'coreProblem': '',
      'chainUnderlay': false,
      'chainProblem': '',
      'awg': false,
      'rotationGen': 0,
      'killSwitchHeld': false,
    };

    setUp(() {
      sample = stateSample(running: false, paused: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            (call) async {
              if (call.method == 'xrayState') return sample;
              return null;
            },
          );
      c = XrayController();
      // Build 2114: auto-reconnect defaults OFF now
      // (defaults reset) — this group grades the reconnect
      // expectation machinery, so the setup turns it on.
      c.settings.autoReconnect = true;
      c.profiles = [_wg()];
      c.select(c.profiles.single);
    });

    tearDown(() {
      c.testEndHandoverCountdown();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            null,
          );
      c.dispose();
    });

    test('XrayState parses paused; missing reads false', () async {
      sample = stateSample(running: false, paused: true);
      expect((await XrayPlatform.state()).paused, isTrue);
      sample = stateSample(running: true)..remove('paused');
      expect((await XrayPlatform.state()).paused, isFalse);
    });

    test('a paused tick schedules no reconnect', () async {
      c.testExpectSession(profileId: 'wg1');
      sample = stateSample(running: false, paused: true);
      await c.testPollTick();
      expect(c.testHasPendingRetry, isFalse);
      expect(c.state.paused, isTrue);
    });

    test('the expectation survives a pause: the next drop retries',
        () async {
      c.testExpectSession(profileId: 'wg1');
      sample = stateSample(running: false, paused: true);
      await c.testPollTick();
      expect(c.testHasPendingRetry, isFalse);
      // The tunnel really drops now: the poll must fire the
      // retry it held back during the pause.
      sample = stateSample(running: false);
      await c.testPollTick();
      expect(c.testHasPendingRetry, isTrue);
    });

    test('refreshState while paused keeps the expectation', () async {
      c.testExpectSession(profileId: 'wg1');
      sample = stateSample(running: false, paused: true);
      await c.refreshState();
      expect(c.state.paused, isTrue);
      sample = stateSample(running: false);
      await c.testPollTick();
      expect(c.testHasPendingRetry, isTrue);
    });

    test('an unpaused drop retries (control arm)', () async {
      c.testExpectSession(profileId: 'wg1');
      sample = stateSample(running: false);
      await c.testPollTick();
      expect(c.testHasPendingRetry, isTrue);
    });
  });
}
