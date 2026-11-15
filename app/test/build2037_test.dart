/// Build 2037 gates, host side: managed DNS over TCP (Iran-priority
/// queue item 2e, the honest half — DNSCrypt is parked, see the LOG:
/// Xray-core has no DNSCrypt support anywhere in its tree, and it
/// needs a dnscrypt-proxy native binary port). A third resolver
/// transport, TCP: the same provider over plain DNS on TCP port 53
/// at its pinned IP — no hostname, no SNI, and UDP poisoning
/// cannot touch it. The core side was verified in the bundled
/// Xray-core v26.10.29 source before building: app/dns/
/// nameserver.go NewServer handles scheme "tcp" via
/// NewTCPNameServer (remote mode, dialed through the dispatcher);
/// "tls://" (DoT) is NOT in this core's NewServer switch, so TCP
/// is the honest third transport. Live `xray run -test` results
/// for every shipped DNS variant are recorded in BUILD-LOG-2.md
/// (build 2037) — these tests pin the DART side of that contract.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Profile _vless() => Profile(
  id: 'v1',
  protocol: Protocol.vless,
  name: 'v',
  address: 'v.example.com',
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  security: 'tls',
  sni: 'v.example.com',
);

List<dynamic> dnsServersOf(XraySettings s) {
  final cfg = decode(buildTunnelConfig(_vless(), s));
  return (cfg['dns'] as Map<String, dynamic>)['servers'] as List;
}

XraySettings _tcp({String remoteDns = 'https://dns.google/dns-query'}) {
  final s = XraySettings()
    ..remoteDnsProto = 'tcp'
    ..remoteDns = remoteDns;
  return s;
}

void main() {
  group('DNS over TCP (queue 2e)', () {
    test('tcpFormOf maps the pinned providers to their first pinned IP', () {
      expect(tcpFormOf('https://dns.google/dns-query'), 'tcp://8.8.8.8');
      expect(
        tcpFormOf('https://cloudflare-dns.com/dns-query'),
        'tcp://1.1.1.1',
      );
      expect(
        tcpFormOf('https://1dot1dot1dot1.cloudflare-dns.com/dns-query'),
        'tcp://1.1.1.1',
      );
      expect(
        tcpFormOf('https://dns.quad9.net/dns-query'),
        'tcp://9.9.9.9',
      );
      expect(
        tcpFormOf('https://dns.adguard-dns.com/dns-query'),
        'tcp://94.140.14.14',
      );
      expect(
        tcpFormOf('https://dns.alidns.com/dns-query'),
        'tcp://223.5.5.5',
      );
      expect(
        tcpFormOf('https://doh.dns.sb/dns-query'),
        'tcp://185.222.222.222',
      );
    });

    test('tcpFormOf: IP URLs, unknown hosts, +one, idempotence, garbage', () {
      expect(tcpFormOf('https://1.1.1.1/dns-query'), 'tcp://1.1.1.1');
      expect(tcpFormOf('https://1.0.0.1/dns-query'), 'tcp://1.0.0.1');
      expect(
        tcpFormOf('https://dns.example.org/dns-query'),
        'tcp://dns.example.org',
      );
      expect(
        tcpFormOf('https+one://dns.google/dns-query'),
        'tcp://8.8.8.8',
      );
      expect(tcpFormOf('tcp://8.8.8.8'), 'tcp://8.8.8.8');
      expect(tcpFormOf('not a url'), 'not a url');
    });

    test('primaryResolver honours the TCP transport, including ad-block', () {
      expect(primaryResolver(_tcp()), 'tcp://8.8.8.8');
      expect(
        primaryResolver(
          _tcp(remoteDns: 'https://cloudflare-dns.com/dns-query'),
        ),
        'tcp://1.1.1.1',
      );
      final ad = _tcp()..adBlockDoh = true;
      expect(primaryResolver(ad), 'tcp://94.140.14.14');
    });

    test('primaryResolver: an unknown stored proto falls back to DoH', () {
      final s = XraySettings()..remoteDnsProto = 'tls';
      expect(primaryResolver(s), 'https://dns.google/dns-query');
      s.remoteDnsProto = 'doh';
      expect(primaryResolver(s), 'https://dns.google/dns-query');
      s.remoteDnsProto = 'doq';
      expect(primaryResolver(s), 'quic+local://dns.google');
    });

    test('DNS section in TCP mode: tcp:// primary, pins kept', () {
      final servers = dnsServersOf(_tcp());
      // Build 2049: the built-in fallback adds Quad9 over TCP
      // in the default shape (see build2049_fix_test.dart).
      expect(servers, ['tcp://8.8.8.8', 'tcp://9.9.9.9']);
      final cfg = decode(buildTunnelConfig(_vless(), _tcp()));
      final dns = cfg['dns'] as Map<String, dynamic>;
      expect(dns['tag'], 'dns-in');
      expect(
        (dns['hosts'] as Map<String, dynamic>)['dns.google'],
        ['8.8.8.8', '8.8.4.4'],
      );
    });

    test('DNS group in TCP mode: members mapped, primary deduped', () {
      final s = _tcp()..dnsGroup = true;
      expect(dnsServersOf(s), [
        'tcp://8.8.8.8',
        'tcp://1.1.1.1',
        'tcp://9.9.9.9',
      ]);
      final cloudflare = _tcp(
        remoteDns: 'https://cloudflare-dns.com/dns-query',
      )..dnsGroup = true;
      expect(dnsServersOf(cloudflare), [
        'tcp://1.1.1.1',
        'tcp://8.8.8.8',
        'tcp://9.9.9.9',
      ]);
    });

    test('fallback in TCP mode: mapped and appended, same-provider dropped', () {
      final s = _tcp()..dnsFallback = true;
      expect(dnsServersOf(s), ['tcp://8.8.8.8', 'tcp://9.9.9.9']);
      final same = _tcp()..dnsFallback = true
        ..fallbackDns = 'https://dns.google/dns-query';
      expect(dnsServersOf(same), ['tcp://8.8.8.8']);
    });

    test('fakeDNS still rides first under the TCP transport', () {
      final s = _tcp()..fakeDns = true;
      // Build 2049: the built-in TCP fallback follows (see
      // build2049_fix_test.dart).
      expect(dnsServersOf(s), ['fakedns', 'tcp://8.8.8.8', 'tcp://9.9.9.9']);
    });

    test('settings: the TCP choice round-trips; old JSON defaults to DoH', () {
      final s = XraySettings()..remoteDnsProto = 'tcp';
      final back = XraySettings.fromJson(s.toJson());
      expect(back.remoteDnsProto, 'tcp');
      expect(primaryResolver(back), 'tcp://8.8.8.8');
      final old = XraySettings.fromJson({'remoteDns': 'https://dns.google/dns-query'});
      expect(old.remoteDnsProto, 'doh');
    });

    test('DoH/DoQ regression: nothing changes when TCP is not chosen', () {
      // Build 2049 amended this shape: the default config now
      // also carries the built-in TCP fallback after the
      // primary (see build2049_fix_test.dart); the DoH/DoQ
      // primary mapping itself is unchanged.
      expect(dnsServersOf(XraySettings()), [
        'https://dns.google/dns-query',
        'tcp://9.9.9.9',
      ]);
      final doq = XraySettings()..remoteDnsProto = 'doq';
      expect(dnsServersOf(doq), ['quic+local://dns.google', 'tcp://9.9.9.9']);
      final doqGroup = XraySettings()
        ..remoteDnsProto = 'doq'
        ..dnsGroup = true;
      expect(dnsServersOf(doqGroup), [
        'quic+local://dns.google',
        'quic+local://one.one.one.one',
        'quic+local://dns.quad9.net',
      ]);
    });
  });
}
