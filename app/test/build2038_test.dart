/// Build 2038 gates, host side: custom tunnel MTU (Iran-priority
/// queue item 2f). One global setting — the MTU of the Android VPN
/// TUN interface, applied to every engine's tunnel at connect
/// (V2Ray, WARP, Psiphon, Lantern, Mozilla): the interface, the
/// tun2socks bridge and (Mozilla) the core's stack all use this one
/// value, so they agree. The native side is compiled by the Flutter
/// build (Kotlin) and the core rebind (Go, SetTunMTU with the same
/// 1280..1500 clamp — see core/mobile/tun_mtu_test.go); these tests
/// pin the DART side of that contract: the default, the clamp, and
/// the store round-trip. OpenVPN is out of scope — it already
/// negotiates its own MTU from the server.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

void main() {
  group('Tunnel MTU (queue 2f)', () {
    test('default is 1500 (unchanged behaviour)', () {
      expect(XraySettings().tunnelMtu, 1500);
    });

    test('clamp: the offered range 1280..1500', () {
      expect(XraySettings.clampTunnelMtu(900), 1280);
      expect(XraySettings.clampTunnelMtu(1279), 1280);
      expect(XraySettings.clampTunnelMtu(1280), 1280);
      expect(XraySettings.clampTunnelMtu(1400), 1400);
      expect(XraySettings.clampTunnelMtu(1420), 1420);
      expect(XraySettings.clampTunnelMtu(1500), 1500);
      expect(XraySettings.clampTunnelMtu(9000), 1500);
      expect(XraySettings.clampTunnelMtu(-5), 1280);
    });

    test('fromJson clamps a stored value instead of trusting it', () {
      final low = XraySettings.fromJson({'tunnelMtu': 900});
      expect(low.tunnelMtu, 1280);
      final high = XraySettings.fromJson({'tunnelMtu': 9000});
      expect(high.tunnelMtu, 1500);
      final ok = XraySettings.fromJson({'tunnelMtu': 1400});
      expect(ok.tunnelMtu, 1400);
    });

    test('a missing key reads as the 1500 default', () {
      expect(XraySettings.fromJson({}).tunnelMtu, 1500);
      // A store written before build 2038 has no tunnelMtu key.
      final old = XraySettings.fromJson({
        'remoteDns': 'https://dns.google/dns-query',
        'remoteDnsProto': 'doh',
      });
      expect(old.tunnelMtu, 1500);
      expect(old.remoteDnsProto, 'doh');
    });

    test('toJson round-trip keeps a chosen MTU', () {
      final s = XraySettings()..tunnelMtu = 1420;
      final back = XraySettings.fromJson(decode(jsonEncode(s.toJson())));
      expect(back.tunnelMtu, 1420);
    });

    test('toJson round-trip keeps the default', () {
      final back =
          XraySettings.fromJson(decode(jsonEncode(XraySettings().toJson())));
      expect(back.tunnelMtu, 1500);
    });

    test('settings JSON round-trip leaves the DNS defaults alone', () {
      final s = XraySettings()..tunnelMtu = 1280;
      final back = XraySettings.fromJson(decode(jsonEncode(s.toJson())));
      // Build 2113: the shipped default remote is v2rayNG's
      // Cloudflare DoH (the 2111 plain-IP default is
      // reverted; a fresh store's flags are already migrated,
      // so the round trip leaves the value alone).
      expect(back.remoteDns, 'https://cloudflare-dns.com/dns-query');
      expect(back.remoteDnsProto, 'doh');
      expect(back.tunnelMtu, 1280);
    });
  });
}
