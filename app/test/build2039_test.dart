/// Build 2039 gates, host side: seamless server switch
/// (Iran-priority queue item 2g) — change servers WITHOUT
/// dropping the VPN. The rotate mechanism itself is the one the
/// watchdog's shape rotation has used since 2029A (respawn ONLY
/// the Xray subprocess; the TUN and its bridge stay up), so these
/// tests pin the DART side of the new contract: when a session
/// may rotate, that a stopped controller never attempts a switch,
/// and that the rotated config keeps the tunnel's ports while
/// actually changing the exit. The live rotate + probe path is
/// proven by the host xray run-test of both configs (see
/// BUILD-LOG-2.md, build 2039) and by the shape rotation's
/// device history; there is no emulator on this VM.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Profile vless(String id, String address) => Profile(
  id: id,
  protocol: Protocol.vless,
  name: id,
  address: address,
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  security: 'tls',
  sni: address,
);

/// The port of the inbound tagged [tag] in a tunnel config.
int inboundPort(Map<String, dynamic> config, String tag) {
  final inbounds = config['inbounds'] as List<dynamic>;
  final found = inbounds.firstWhere(
    (e) => (e as Map<String, dynamic>)['tag'] == tag,
    orElse: () => <String, dynamic>{},
  );
  return (found as Map<String, dynamic>)['port'] as int? ?? -1;
}

/// The address of the first ("proxy") outbound's first server.
String proxyAddress(Map<String, dynamic> config) {
  final outbounds = config['outbounds'] as List<dynamic>;
  final proxy = outbounds.first as Map<String, dynamic>;
  final settings = proxy['settings'] as Map<String, dynamic>;
  final vnext = settings['vnext'] as List<dynamic>;
  return (vnext.first as Map<String, dynamic>)['address'] as String;
}

void main() {
  group('Seamless switch eligibility (queue 2g)', () {
    test('a plain running Xray session may rotate', () {
      expect(
        XrayController.seamlessSwitchAllowed(
          running: true,
          warpSession: false,
          underlay: 'none',
        ),
        isTrue,
      );
    });

    test('a stopped session may not rotate', () {
      expect(
        XrayController.seamlessSwitchAllowed(
          running: false,
          warpSession: false,
          underlay: 'none',
        ),
        isFalse,
      );
    });

    test('a standalone WARP session may not rotate', () {
      expect(
        XrayController.seamlessSwitchAllowed(
          running: true,
          warpSession: true,
          underlay: 'none',
        ),
        isFalse,
      );
    });

    test('a chained session may not rotate', () {
      expect(
        XrayController.seamlessSwitchAllowed(
          running: true,
          warpSession: false,
          underlay: 'psiphon',
        ),
        isFalse,
      );
      expect(
        XrayController.seamlessSwitchAllowed(
          running: true,
          warpSession: false,
          underlay: 'warp',
        ),
        isFalse,
      );
    });
  });

  group('Switch state on a fresh controller', () {
    test('no switch notice, nothing switching', () {
      final c = XrayController();
      expect(c.switchNotice, '');
      expect(c.switchingProfileId, isNull);
    });

    test('switchServer on a stopped tunnel returns false, changes nothing', () async {
      final c = XrayController();
      final a = vless('a', 'a.example.com');
      final b = vless('b', 'b.example.com');
      c.profiles = [a, b];
      c.selectedProfileId = 'a';
      expect(await c.switchServer(b), isFalse);
      expect(c.selectedProfileId, 'a');
      expect(c.switchingProfileId, isNull);
      expect(c.switchNotice, '');
    });

    test('select on a stopped tunnel only selects', () {
      final c = XrayController();
      final a = vless('a', 'a.example.com');
      final b = vless('b', 'b.example.com');
      c.profiles = [a, b];
      c.selectedProfileId = 'a';
      c.select(b);
      expect(c.selectedProfileId, 'b');
      expect(c.switchingProfileId, isNull);
    });
  });

  group('The rotated config (queue 2g)', () {
    test('two profiles keep the same SOCKS and API ports', () {
      final a = buildTunnelConfig(vless('a', 'a.example.com'), XraySettings());
      final b = buildTunnelConfig(vless('b', 'b.example.com'), XraySettings());
      final ca = decode(a);
      final cb = decode(b);
      expect(inboundPort(ca, 'socks'), inboundPort(cb, 'socks'));
      expect(inboundPort(ca, 'socks'), isNot(-1));
      expect(inboundPort(ca, 'api'), inboundPort(cb, 'api'));
      expect(inboundPort(ca, 'api'), isNot(-1));
      // The API port is the stats port the poller keeps reading.
      expect(inboundPort(ca, 'api'), statsApiPort(XraySettings()));
    });

    test('two profiles actually change the exit', () {
      final a = buildTunnelConfig(vless('a', 'a.example.com'), XraySettings());
      final b = buildTunnelConfig(vless('b', 'b.example.com'), XraySettings());
      expect(proxyAddress(decode(a)), 'a.example.com');
      expect(proxyAddress(decode(b)), 'b.example.com');
    });

    test('the rotated config still carries the stats API', () {
      final config = decode(
        buildTunnelConfig(vless('a', 'a.example.com'), XraySettings()),
      );
      final api = config['api'] as Map<String, dynamic>;
      expect(api['tag'], 'api');
      expect(api['services'], contains('StatsService'));
      expect(config.containsKey('stats'), isTrue);
    });
  });
}
